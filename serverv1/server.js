const { Server: WebSocketServer } = require('ws');
const grpc = require('@grpc/grpc-js');
const protoLoader = require('@grpc/proto-loader');
const https = require('https');
const path = require('path');
const { OggOpusWriter } = require('./ogg_opus');
const { langName, transCode } = require('./lang_map');

const API_KEY = process.env.GOOGLE_API_KEY || 'AIzaSyCTN5gvTBRAFmCiU_jFu1mV2N16fEeurCM';
const PORT = process.env.PORT || 8080;

process.on('uncaughtException', (err) => console.error('UNCAUGHT:', err.message));
process.on('unhandledRejection', (err) => console.error('UNHANDLED:', err));

// ---- Google STT V1 ----
const PROTO_PATH = path.join(__dirname, 'google/cloud/speech/v1/cloud_speech.proto');
let speechClient = null;

function getSpeechClient() {
  if (speechClient) return speechClient;
  const pkg = protoLoader.loadSync(PROTO_PATH, {
    keepCase: false, longs: String, enums: String, defaults: true, oneofs: true,
  });
  const proto = grpc.loadPackageDefinition(pkg).google.cloud.speech.v1;
  const endpoint = process.env.STT_ENDPOINT || 'speech.googleapis.com:443';
  speechClient = new proto.Speech(endpoint, grpc.credentials.createSsl());
  console.log('STT endpoint:', endpoint);
  return speechClient;
}

// ---- Translation ----
function translateText(text, targetLang) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), 8000);
    const body = JSON.stringify({ q: text, target: targetLang, format: 'text' });
    const req = https.request({
      hostname: 'translation.googleapis.com',
      path: `/language/translate/v2?key=${API_KEY}`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 8000,
    }, (res) => {
      let d = '';
      res.on('data', (c) => d += c);
      res.on('end', () => {
        clearTimeout(timer);
        try {
          const j = JSON.parse(d);
          if (j.error) return reject(new Error(j.error.message));
          resolve(j.data.translations[0].translatedText);
        } catch (e) { reject(e); }
      });
    });
    req.on('error', (e) => { clearTimeout(timer); reject(e); });
    req.on('timeout', () => req.destroy());
    req.write(body);
    req.end();
  });
}

// ---- Language detection ----
function detectDirection(text, langA, langB) {
  const hasCJK = /[\u4e00-\u9fff\u3400-\u4dbf]/.test(text);
  const hasJP = /[\u3040-\u309f\u30a0-\u30ff]/.test(text);
  const hasKR = /[\uac00-\ud7af]/.test(text);
  const hasCyrillic = /[\u0400-\u04ff]/.test(text);
  const hasArabic = /[\u0600-\u06ff]/.test(text);
  const hasThai = /[\u0e00-\u0e7f]/.test(text);
  const hasHindi = /[\u0900-\u097f]/.test(text);

  let s = 'latin';
  if (hasJP) s = 'ja'; else if (hasKR) s = 'ko'; else if (hasCJK) s = 'zh';
  else if (hasCyrillic) s = 'ru'; else if (hasArabic) s = 'ar';
  else if (hasThai) s = 'th'; else if (hasHindi) s = 'hi';

  const aB = langA.split('-')[0].toLowerCase();
  const bB = langB.split('-')[0].toLowerCase();
  const latin = ['en', 'fr', 'de', 'es', 'pt', 'it', 'vi'];
  const mA = s === 'latin' ? latin.includes(aB) : aB === s;
  const mB = s === 'latin' ? latin.includes(bB) : bB === s;
  if (mB && !mA) return { spoken: langB, target: langA };
  return { spoken: langA, target: langB };
}

// ---- Session ----
let sid = 0;

class Session {
  constructor(ws) {
    this.id = ++sid;
    this.ws = ws;
    this.active = false;
    this.langA = 'en-US';
    this.langB = 'zh-CN';
    this.stream = null;
    this.streamVer = 0;
    this.oggWriter = null;
    this.audioQueue = [];
    this.lastInterimTranslated = '';
    this.silenceTimer = null;
    this._retryCount = 0;
    // Interim translation: track in-flight request to avoid piling up
    this._interimTranslating = false;
    this._pendingInterimText = null;
  }

  log(m) { console.log(`[${this.id}] ${m}`); }

  start(langA, langB) {
    this.langA = langA;
    this.langB = langB;
    this.active = true;
    this._openStream();
  }

  _openStream() {
    if (!this.active) return;
    const ver = ++this.streamVer;

    const meta = new grpc.Metadata();
    meta.add('x-goog-api-key', API_KEY);

    let s;
    try { s = getSpeechClient().streamingRecognize(meta); }
    catch (e) { this.log('gRPC fail: ' + e.message); return; }
    this.stream = s;

    // OGG_OPUS encoding: send OGG headers first, then wrap each Opus frame
    s.write({
      streamingConfig: {
        config: {
          encoding: 'OGG_OPUS',
          sampleRateHertz: 16000,
          languageCode: this.langA,
          alternativeLanguageCodes: [this.langB],
          enableAutomaticPunctuation: true,
        },
        interimResults: true,
        singleUtterance: false,
      },
    });

    // Create OGG writer and send headers
    this.oggWriter = new OggOpusWriter(16000, 1);
    const headers = this.oggWriter.getHeaders();
    try { s.write({ audioContent: headers }); } catch (_) {}

    // Flush queued audio
    while (this.audioQueue.length > 0) {
      const buf = this.audioQueue.shift();
      try { s.write({ audioContent: buf }); } catch (_) { break; }
    }

    s.on('data', (resp) => {
      if (ver !== this.streamVer || !this.active) return;
      this._onResponse(resp);
    });

    s.on('error', (err) => {
      if (ver !== this.streamVer) return;
      this.log('gRPC err: ' + err.message);
      this.stream = null;
      this._retryCount++;
      const delay = Math.min(1000 * this._retryCount, 10000);
      if (this.active && this._retryCount < 10) {
        setTimeout(() => this._openStream(), delay);
      } else if (this._retryCount >= 10) {
        this.log('Too many retries, giving up');
      }
    });

    s.on('end', () => {
      if (ver !== this.streamVer) return;
      this.log('gRPC end');
      this.stream = null;
      if (this.active) setTimeout(() => this._openStream(), 300);
    });

    this.log(`Stream #${ver}: ${this.langA} <-> ${this.langB} [OGG_OPUS]`);
  }

  _onResponse(resp) {
    if (!resp.results || !resp.results.length) return;

    const text = resp.results
      .filter(r => r.alternatives && r.alternatives.length)
      .map(r => r.alternatives[0].transcript)
      .join(' ').trim();
    if (!text) return;

    this._retryCount = 0;
    const last = resp.results[resp.results.length - 1];
    const isFinal = last.isFinal;
    const detectedLang = last.languageCode || '';

    if (!isFinal) {
      // Send interim text immediately
      this._send({ type: 'interim', text, lang: detectedLang });
      // Translate every interim (non-blocking, skip if previous still in flight)
      this._translateInterim(text);
      return;
    }

    this.log(`Final [${detectedLang}]: "${text.substring(0, 50)}"`);
    this._translateFinal(text, detectedLang);
  }

  async _translateInterim(text) {
    if (!this.active) return;
    // If already translating, queue the latest text
    if (this._interimTranslating) {
      this._pendingInterimText = text;
      return;
    }
    this._interimTranslating = true;
    try {
      const dir = detectDirection(text, this.langA, this.langB);
      const translated = await translateText(text, transCode(dir.target));
      if (!this.active) return;
      this.lastInterimTranslated = translated;
      this._send({ type: 'interim_translation', text, translated });
    } catch (_) {}
    this._interimTranslating = false;

    // If there's a newer pending interim, translate it now
    if (this._pendingInterimText && this.active) {
      const pending = this._pendingInterimText;
      this._pendingInterimText = null;
      this._translateInterim(pending);
    }
  }

  async _translateFinal(text, detectedLang) {
    if (!this.active) return;
    const dir = detectDirection(text, this.langA, this.langB);
    let translated;
    try {
      translated = await translateText(text, transCode(dir.target));
    } catch (e) {
      this.log('Translate err: ' + e.message);
      translated = this.lastInterimTranslated || '[error]';
    }
    this.lastInterimTranslated = '';
    this._pendingInterimText = null;
    this._send({
      type: 'final', text, translated,
      spokenLang: langName(dir.spoken),
      translatedLang: langName(dir.target),
      detectedLang,
    });
    this._scheduleSilenceRestart();
  }

  _scheduleSilenceRestart() {
    if (this.silenceTimer) clearTimeout(this.silenceTimer);
    this.silenceTimer = setTimeout(() => {
      if (this.active) { this.log('Silence restart'); this._restart(); }
    }, 5000);
  }

  _restart() {
    if (!this.active) return;
    if (this.silenceTimer) { clearTimeout(this.silenceTimer); this.silenceTimer = null; }
    const old = this.stream;
    this.stream = null;
    this.oggWriter = null;
    this.audioQueue = [];
    if (old) try { old.end(); } catch (_) {}
    setTimeout(() => { if (this.active) this._openStream(); }, 100);
  }

  audio(data) {
    if (!this.active) return;
    if (this.silenceTimer) { clearTimeout(this.silenceTimer); this.silenceTimer = null; }

    // Wrap raw Opus frame in OGG page (no decoding!)
    let oggPage;
    try {
      if (this.oggWriter) {
        oggPage = this.oggWriter.wrapFrame(data);
      } else { return; }
    } catch (_) { return; }

    if (this.stream) {
      try { this.stream.write({ audioContent: oggPage }); }
      catch (_) { this.audioQueue.push(oggPage); }
    } else {
      this.audioQueue.push(oggPage);
      const total = this.audioQueue.reduce((s, b) => s + b.length, 0);
      while (total > 64000 && this.audioQueue.length > 1) this.audioQueue.shift();
    }
  }

  stop() {
    this.active = false;
    this.streamVer++;
    if (this.silenceTimer) clearTimeout(this.silenceTimer);
    if (this.stream) try { this.stream.end(); } catch (_) {}
    this.stream = null;
    this.oggWriter = null;
    this.audioQueue = [];
    this.log('Stopped');
  }

  _send(msg) {
    try { if (this.ws.readyState === 1) this.ws.send(JSON.stringify(msg)); } catch (_) {}
  }
}

// ---- Server ----
const wss = new WebSocketServer({ port: PORT });
wss.on('connection', (ws) => {
  console.log('Client connected');
  let session = null;
  ws.on('message', (data, isBinary) => {
    if (isBinary) { if (session) session.audio(data); return; }
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'start') {
        if (session) session.stop();
        session = new Session(ws);
        session.start(msg.langA || 'en-US', msg.langB || 'zh-CN');
      } else if (msg.type === 'stop') {
        if (session) { session.stop(); session = null; }
      }
    } catch (e) { console.error('Parse:', e.message); }
  });
  ws.on('close', () => { if (session) { session.stop(); session = null; } console.log('Disconnected'); });
  ws.on('error', () => { if (session) { session.stop(); session = null; } });
});
console.log(`Translate relay V1 [OGG_OPUS] on port ${PORT}`);
