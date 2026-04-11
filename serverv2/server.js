const { Server: WebSocketServer } = require('ws');
const grpc = require('@grpc/grpc-js');
const protoLoader = require('@grpc/proto-loader');
const { GoogleAuth } = require('google-auth-library');
const https = require('https');
const path = require('path');
const OpusScript = require('opusscript');
const { toV2Lang, langName, transCode } = require('./lang_map');

const API_KEY = process.env.GOOGLE_API_KEY || 'AIzaSyCTN5gvTBRAFmCiU_jFu1mV2N16fEeurCM';
const PORT = process.env.PORT || 8080;
const PROJECT_ID = 'gen-lang-client-0479219937';
const SA_PATH = path.join(__dirname, 'service-account.json');

process.env.GOOGLE_APPLICATION_CREDENTIALS = SA_PATH;
process.on('uncaughtException', (err) => console.error('UNCAUGHT:', err.message));
process.on('unhandledRejection', (err) => console.error('UNHANDLED:', err));

// ---- V2 STT Client (Service Account auth) ----
const PROTO_PATH = path.join(__dirname, 'google/cloud/speech/v2/cloud_speech.proto');
let speechProto = null;
let googleAuth = null;
let cachedToken = null;

async function initSpeechClient() {
  const pkg = protoLoader.loadSync(PROTO_PATH, {
    keepCase: true, longs: String, enums: String, defaults: true, oneofs: true,
    includeDirs: [__dirname],
  });
  speechProto = grpc.loadPackageDefinition(pkg).google.cloud.speech.v2;
  googleAuth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
  cachedToken = await googleAuth.getAccessToken();
  console.log('V2 Speech ready (chirp_3), token obtained');

  // Refresh token every 45 minutes
  setInterval(async () => {
    try {
      cachedToken = await googleAuth.getAccessToken();
      console.log('Token refreshed');
    } catch (e) { console.error('Token refresh err:', e.message); }
  }, 45 * 60 * 1000);
}

function createSpeechClient() {
  const callCreds = grpc.credentials.createFromMetadataGenerator((_, cb) => {
    const meta = new grpc.Metadata();
    meta.add('authorization', 'Bearer ' + cachedToken);
    cb(null, meta);
  });
  const creds = grpc.credentials.combineChannelCredentials(grpc.credentials.createSsl(), callCreds);
  const region = process.env.STT_REGION || 'asia-northeast1';
  console.log('STT region:', region);
  return new speechProto.Speech(`${region}-speech.googleapis.com:443`, creds);
}

// ---- Translation (API Key) ----
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

// ---- Session (V2 chirp_3) ----
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
    this.decoder = null;
    this.audioQueue = [];
    this.interimTimer = null;
    this.lastInterimTranslated = '';
    this.silenceTimer = null;
    this._retryCount = 0;
  }

  log(m) { console.log(`[${this.id}] ${m}`); }

  start(langA, langB) {
    this.langA = langA;
    this.langB = langB;
    this.active = true;
    try { this.decoder = new OpusScript(16000, 1, OpusScript.Application.VOIP); } catch (e) {
      this.log('Opus decoder fail: ' + e.message);
    }
    this._openStream();
  }

  _openStream() {
    if (!this.active || !speechProto) return;
    const ver = ++this.streamVer;

    const client = createSpeechClient();

    // V2 requires x-goog-request-params
    const region = process.env.STT_REGION || 'asia-northeast1';
    const recognizer = `projects/${PROJECT_ID}/locations/${region}/recognizers/_`;
    const meta = new grpc.Metadata();
    meta.add('x-goog-request-params', `recognizer=${recognizer}`);

    let s;
    try { s = client.streamingRecognize(meta); }
    catch (e) { this.log('Create fail: ' + e.message); return; }
    this.stream = s;

    const v2A = toV2Lang(this.langA);
    const v2B = toV2Lang(this.langB);

    // V2 chirp_3 config (per docs: interim_results only, no VAD)
    s.write({
      streaming_config: {
        config: {
          explicit_decoding_config: {
            encoding: 'LINEAR16',
            sample_rate_hertz: 16000,
            audio_channel_count: 1,
          },
          model: process.env.STT_MODEL || 'chirp_3',
          language_codes: [v2A, v2B],
          features: {
            enable_automatic_punctuation: true,
            enable_word_time_offsets: true,
          },
        },
        streaming_features: {
          interim_results: true,
        },
      },
      recognizer: recognizer,
    });

    // Flush queued audio
    while (this.audioQueue.length > 0) {
      const buf = this.audioQueue.shift();
      try { s.write({ audio: buf }); } catch (_) { break; }
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
        this.log('Too many retries');
      }
    });

    s.on('end', () => {
      if (ver !== this.streamVer) return;
      this.log('gRPC end');
      this.stream = null;
      if (this.active) setTimeout(() => this._openStream(), 300);
    });

    this.log(`V2 #${ver}: [${v2A}, ${v2B}] model=chirp_3`);
  }

  _onResponse(resp) {
    const results = resp.results || [];
    if (!results.length) return;

    const text = results
      .filter(r => r.alternatives && r.alternatives.length)
      .map(r => r.alternatives[0].transcript)
      .join(' ').trim();
    if (!text) return;

    this._retryCount = 0;
    const last = results[results.length - 1];
    const isFinal = !!last.is_final;
    const detectedLang = last.language_code || '';

    this.log(isFinal ? `FINAL [${detectedLang}]: "${text.substring(0, 40)}"` : `interim: "${text.substring(0, 40)}"`);

    if (!isFinal) {
      this._send({ type: 'interim', text, lang: detectedLang });
      if (this.interimTimer) clearTimeout(this.interimTimer);
      this.interimTimer = setTimeout(() => this._translateInterim(text), 150);
      return;
    }

    if (this.interimTimer) { clearTimeout(this.interimTimer); this.interimTimer = null; }
    this._translateFinal(text, detectedLang);
  }

  async _translateInterim(text) {
    if (!this.active) return;
    try {
      const dir = detectDirection(text, this.langA, this.langB);
      const translated = await translateText(text, transCode(dir.target));
      if (!this.active) return;
      this.lastInterimTranslated = translated;
      this._send({ type: 'interim_translation', text, translated });
    } catch (_) {}
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
    this.audioQueue = [];
    if (old) try { old.end(); } catch (_) {}
    setTimeout(() => { if (this.active) this._openStream(); }, 100);
  }

  audio(data) {
    if (!this.active) return;
    if (this.silenceTimer) { clearTimeout(this.silenceTimer); this.silenceTimer = null; }

    let pcm;
    try {
      if (this.decoder) {
        const decoded = this.decoder.decode(data, 320);
        pcm = Buffer.from(decoded.buffer, decoded.byteOffset, decoded.byteLength);
      } else { pcm = data; }
    } catch (_) { return; }

    if (this.stream) {
      try { this.stream.write({ audio: pcm }); }
      catch (_) { this.audioQueue.push(pcm); }
    } else {
      this.audioQueue.push(pcm);
      const total = this.audioQueue.reduce((s, b) => s + b.length, 0);
      while (total > 64000 && this.audioQueue.length > 1) this.audioQueue.shift();
    }
  }

  stop() {
    this.active = false;
    this.streamVer++;
    if (this.interimTimer) clearTimeout(this.interimTimer);
    if (this.silenceTimer) clearTimeout(this.silenceTimer);
    if (this.stream) try { this.stream.end(); } catch (_) {}
    this.stream = null;
    this.decoder = null;
    this.audioQueue = [];
    this.log('Stopped');
  }

  _send(msg) {
    try { if (this.ws.readyState === 1) this.ws.send(JSON.stringify(msg)); } catch (_) {}
  }
}

// ---- Server ----
async function main() {
  await initSpeechClient();

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

  console.log(`Translate relay V2 (chirp_3) on port ${PORT}`);
}

main().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
