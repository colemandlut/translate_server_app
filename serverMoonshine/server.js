const { Server: WebSocketServer } = require('ws');
const https = require('https');
const http = require('http');
const OpusScript = require('opusscript');

// WebRTC VAD (WASM)
let fvadModule = null;
async function initFvad() {
  const mod = await import('@echogarden/fvad-wasm');
  fvadModule = await mod.default();
  console.log('WebRTC VAD (fvad-wasm) loaded');
}

function createVad() {
  if (!fvadModule) return null;
  const ptr = fvadModule._fvad_new();
  fvadModule._fvad_set_sample_rate(ptr, 16000);
  fvadModule._fvad_set_mode(ptr, 3); // mode 3 = most aggressive (least false positives)
  return {
    isVoice(pcmInt16Array) {
      const byteLen = pcmInt16Array.length * 2;
      const bufPtr = fvadModule._malloc(byteLen);
      fvadModule.HEAP16.set(pcmInt16Array, bufPtr >> 1);
      const result = fvadModule._fvad_process(ptr, bufPtr, pcmInt16Array.length);
      fvadModule._free(bufPtr);
      return result === 1;
    },
    free() { fvadModule._fvad_free(ptr); }
  };
}

const GOOGLE_API_KEY = process.env.GOOGLE_API_KEY || 'AIzaSyCTN5gvTBRAFmCiU_jFu1mV2N16fEeurCM';
const PORT = process.env.PORT || 8081;
const MOONSHINE_URL = process.env.MOONSHINE_URL || 'http://localhost:8091';

const SILENCE_THRESHOLD = 200;
const SILENCE_DURATION = 800;
const MIN_SPEECH_DURATION = 300;
const MAX_SPEECH_DURATION = 15000;
const INTERIM_INTERVAL = parseInt(process.env.INTERIM_INTERVAL || '200');

process.on('uncaughtException', (err) => console.error('UNCAUGHT:', err.message));
process.on('unhandledRejection', (err) => console.error('UNHANDLED:', err));

// Moonshine Python loads en/ja/zh; langA/langB may be e.g. zh-CN or en-US.
// Keep only the ones Moonshine actually has so we don't filter out everything.
const MOONSHINE_LANGS = new Set(['en', 'ja', 'zh']);
function langsCsv(langA, langB) {
  const out = [];
  for (const l of [langA, langB]) {
    if (!l) continue;
    const base = l.split('-')[0].toLowerCase();
    if (MOONSHINE_LANGS.has(base) && !out.includes(base)) out.push(base);
  }
  return out.join(',');
}

// ---- Moonshine API (local Python server; responds with detected language) ----
function transcribeAudio(wavBuffer, langA, langB) {
  return new Promise((resolve, reject) => {
    const url = new URL(MOONSHINE_URL);
    const useHttps = url.protocol === 'https:';
    const transport = useHttps ? https : http;

    const boundary = '----FormBoundary' + Date.now() + Math.random();
    const parts = [];
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n`);
    parts.push(wavBuffer);
    parts.push('\r\n');
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\nverbose_json\r\n`);
    const csv = langsCsv(langA, langB);
    if (csv) {
      parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="languages"\r\n\r\n${csv}\r\n`);
    }
    parts.push(`--${boundary}--\r\n`);

    const body = Buffer.concat(parts.map(p => typeof p === 'string' ? Buffer.from(p) : p));
    const timeout = 30000;
    const timer = setTimeout(() => reject(new Error('Moonshine timeout')), timeout);

    const req = transport.request({
      hostname: url.hostname,
      port: url.port || (useHttps ? 443 : 80),
      path: '/v1/audio/transcriptions',
      method: 'POST',
      headers: {
        'Content-Type': `multipart/form-data; boundary=${boundary}`,
        'Content-Length': body.length,
      },
      timeout,
    }, (res) => {
      let d = '';
      res.on('data', (c) => d += c);
      res.on('end', () => {
        clearTimeout(timer);
        try {
          const j = JSON.parse(d);
          if (j.error) return reject(new Error(j.error.message || JSON.stringify(j.error)));
          resolve({
            text: (j.text || '').trim(),
            language: j.language || '',
          });
        } catch (e) { reject(new Error('Parse: ' + d.substring(0, 200))); }
      });
    });
    req.on('error', (e) => { clearTimeout(timer); reject(e); });
    req.on('timeout', () => req.destroy());
    req.write(body);
    req.end();
  });
}

// ---- Google Translation ----
function translateText(text, targetLang) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), 8000);
    const body = JSON.stringify({ q: text, target: targetLang, format: 'text' });
    const req = https.request({
      hostname: 'translation.googleapis.com',
      path: `/language/translate/v2?key=${GOOGLE_API_KEY}`,
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

// ---- Hallucination filter (en/ja/zh; Moonshine distills Whisper so many of
// Whisper's common false positives persist across languages) ----
const HALLUCINATION_PATTERNS = [
  // English
  'thank you', 'thanks for watching', 'thanks for listening',
  'please subscribe', 'like and subscribe', 'see you next time',
  'goodbye', 'bye bye', 'bye-bye', 'the end',
  'subtitles', 'copyright',
  'music', '♪', '...', 'you', 'yeah', 'okay', 'ok',
  "i don't know", 'hmm', 'uh', 'um', 'oh',
  'so', 'whole', 'well', 'right',
  // Japanese
  'ご視聴ありがとうございました', 'チャンネル登録',
  'ありがとうございました', 'ありがとうございます',
  'お疲れ様でした', 'それでは', 'では',
  'はい', 'ではでは', 'じゃあ',
  // Chinese
  '谢谢', '谢谢观看', '感谢收看', '请订阅',
];

// Detect obvious n-gram repetition ("X X X X" or "A B C A B C A B C").
// Moonshine v1 on mismatched language often loops a phrase; this catches it.
function hasHighRepetition(text) {
  const tokens = text.toLowerCase().replace(/[.,!?。、！？…]/g, '').split(/\s+/).filter(Boolean);
  if (tokens.length < 6) return false;
  const counts = new Map();
  for (const t of tokens) counts.set(t, (counts.get(t) || 0) + 1);
  const maxCount = Math.max(...counts.values());
  return maxCount / tokens.length > 0.35; // any token > 35% of all tokens = loop
}

function isHallucination(text) {
  const stripped = text.trim()
    .replace(/^[-–—*#•「」『』\s]+/, '')
    .replace(/[.,!?。、！？…\s]+$/g, '')
    .trim();
  const lower = stripped.toLowerCase();
  if (HALLUCINATION_PATTERNS.some(p => lower === p || stripped === p)) return true;
  if (stripped.length < 2) return true;
  if (hasHighRepetition(stripped)) return true;
  return false;
}

// Moonshine server returns detected language ("en", "ja", or "zh") or "".
// Map to the spoken-direction given the user's langA/langB selection.
function detectDirection(detectedLang, langA, langB) {
  const det = (detectedLang || '').toLowerCase();
  const aB = langA.split('-')[0].toLowerCase();
  const bB = langB.split('-')[0].toLowerCase();
  if (det && det === bB) return { spoken: langB, target: langA };
  if (det && det === aB) return { spoken: langA, target: langB };
  // Fallback: treat langA as spoken
  return { spoken: langA, target: langB };
}

const LANG_NAMES = {
  'zh-cn': '中文 (简体)', 'zh-tw': '中文 (繁體)', 'en-us': 'English',
  'ja-jp': '日本語', 'ko-kr': '한국어', 'fr-fr': 'Français',
  'de-de': 'Deutsch', 'es-es': 'Español', 'pt-br': 'Português',
  'ru-ru': 'Русский', 'ar-sa': 'العربية', 'hi-in': 'हिन्दी',
};
function langName(c) { return LANG_NAMES[c.toLowerCase()] || c; }
function transCode(c) { return c.toLowerCase() === 'zh-tw' ? 'zh-TW' : c.split('-')[0]; }

function buildWav(pcmBuffers, sampleRate) {
  const pcm = Buffer.concat(pcmBuffers);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4);
  h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(sampleRate, 24); h.writeUInt32LE(sampleRate * 2, 28);
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
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
    this.decoder = null;
    this._vad = null;

    this._allBuffers = [];
    this._isSpeaking = false;
    this._speechStartTime = 0;
    this._silenceStartTime = 0;
    this._interimTimer = null;
    this._interimBusy = false;
    this._lastInterimText = '';
    this._consecutiveHallucinations = 0;
    this._vadPaused = false;
    this._vadPauseTimer = null;
  }

  log(m) { console.log(`[${this.id}] ${m}`); }

  start(langA, langB) {
    this.langA = langA;
    this.langB = langB;
    this.active = true;
    this._vad = createVad();
    try { this.decoder = new OpusScript(16000, 1, OpusScript.Application.VOIP); } catch (e) {
      this.log('Opus fail: ' + e.message);
    }
    this.log(`Started: ${langA} <-> ${langB} [Moonshine]`);
  }

  audio(data) {
    if (!this.active || !this.decoder) return;

    if (this._consecutiveHallucinations >= 3 && !this._vadPaused) {
      this._vadPaused = true;
      this._resetVAD();
      this.log(`VAD paused (${this._consecutiveHallucinations} hallucinations)`);
      if (this._vadPauseTimer) clearTimeout(this._vadPauseTimer);
      this._vadPauseTimer = setTimeout(() => {
        this._vadPaused = false;
        this._consecutiveHallucinations = 0;
        this.log('VAD resumed');
      }, 3000);
      return;
    }
    if (this._vadPaused) return;

    let pcm;
    try {
      const decoded = this.decoder.decode(data, 320);
      pcm = Buffer.from(decoded.buffer, decoded.byteOffset, decoded.byteLength);
    } catch (_) { return; }

    let voiceFrames = 0;
    const samples = new Int16Array(pcm.buffer, pcm.byteOffset, pcm.length / 2);
    if (this._vad) {
      for (let i = 0; i + 160 <= samples.length; i += 160) {
        const frame = samples.subarray(i, i + 160);
        if (this._vad.isVoice(frame)) voiceFrames++;
      }
    }
    const isSpeech = voiceFrames > 0;
    const now = Date.now();

    if (isSpeech) {
      if (!this._isSpeaking) {
        this._isSpeaking = true;
        this._speechStartTime = now;
        this._silenceStartTime = 0;
        this._lastInterimText = '';
        this._startInterimPolling();
      }
      this._allBuffers.push(pcm);
      this._silenceStartTime = 0;

      if (now - this._speechStartTime > MAX_SPEECH_DURATION) {
        this.log('Max duration, force final');
        this._doFinal();
      }
    } else {
      if (this._isSpeaking) {
        this._allBuffers.push(pcm);
        if (!this._silenceStartTime) {
          this._silenceStartTime = now;
        } else if (now - this._silenceStartTime >= SILENCE_DURATION) {
          if (now - this._speechStartTime >= MIN_SPEECH_DURATION) {
            this._doFinal();
          } else {
            this._resetVAD();
          }
        }
      }
    }
  }

  _startInterimPolling() {
    this._stopInterimPolling();
    this._interimTimer = setInterval(() => {
      if (!this._isSpeaking || this._interimBusy || this._allBuffers.length < 50) return;
      this._doInterim();
    }, INTERIM_INTERVAL);
  }

  _stopInterimPolling() {
    if (this._interimTimer) { clearInterval(this._interimTimer); this._interimTimer = null; }
  }

  async _doInterim() {
    if (this._interimBusy || this._allBuffers.length === 0) return;
    this._interimBusy = true;

    try {
      const wav = buildWav([...this._allBuffers], 16000);
      const t0 = Date.now();
      const result = await transcribeAudio(wav, this.langA, this.langB);
      const ms = Date.now() - t0;

      const text = result.text;
      if (text && text.length >= 2 && text !== this._lastInterimText) {
        if (isHallucination(text)) {
          this._consecutiveHallucinations++;
          this.log(`interim SKIP hallucination #${this._consecutiveHallucinations} (${ms}ms): "${text.substring(0, 40)}"`);
          this._interimBusy = false;
          return;
        }
        this._consecutiveHallucinations = 0;
        this._lastInterimText = text;
        this.log(`interim [${result.language}] (${ms}ms): "${text.substring(0, 40)}"`);
        this._send({ type: 'interim', text, lang: result.language });

        try {
          const dir = detectDirection(result.language, this.langA, this.langB);
          const translated = await translateText(text, transCode(dir.target));
          if (this.active && this._isSpeaking) {
            this._send({ type: 'interim_translation', text, translated });
          }
        } catch (_) {}
      }
    } catch (e) {
      this.log('Interim err: ' + e.message);
    }

    this._interimBusy = false;
  }

  async _doFinal() {
    if (!this.active || this._finalizing) return;
    this._finalizing = true;
    this._stopInterimPolling();
    const buffers = this._allBuffers;
    this._resetVAD();

    if (buffers.length < 10) { this._finalizing = false; return; }

    const durationMs = buffers.length * 20;
    this.log(`Final transcribing ${durationMs}ms...`);

    try {
      const wav = buildWav(buffers, 16000);
      const t0 = Date.now();
      const result = await transcribeAudio(wav, this.langA, this.langB);
      const ms = Date.now() - t0;

      const text = result.text;
      if (!text || text.length < 2 || isHallucination(text)) {
        this._consecutiveHallucinations++;
        this.log(`Empty/hallucination #${this._consecutiveHallucinations} (${ms}ms): "${(text || '').substring(0, 30)}"`);
        this._send({ type: 'interim', text: '', lang: '' });
        this._finalizing = false;
        return;
      }

      const detectedLang = result.language;
      const now = Date.now();
      const isFragment = text.length < 30 && this._lastFinalTime && (now - this._lastFinalTime < 2000);
      if (isFragment && this._lastFinalText) {
        const merged = this._lastFinalText + ' ' + text;
        this.log(`Fragment merged (${ms}ms): "${text}" → "${merged.substring(0, 50)}"`);
        const dir = detectDirection(detectedLang, this.langA, this.langB);
        const translated = await translateText(merged, transCode(dir.target));
        this._send({
          type: 'update_last', text: merged, translated,
          spokenLang: langName(dir.spoken),
          translatedLang: langName(dir.target),
          detectedLang,
        });
        this._lastFinalText = merged;
        this._lastFinalTime = now;
        this._finalizing = false;
        return;
      }

      this._consecutiveHallucinations = 0;
      this.log(`Final [${detectedLang}] (${ms}ms): "${text.substring(0, 50)}"`);

      this._send({ type: 'interim', text, lang: detectedLang });

      const dir = detectDirection(detectedLang, this.langA, this.langB);
      const translated = await translateText(text, transCode(dir.target));

      this._lastFinalText = text;
      this._lastFinalTime = now;

      this._send({
        type: 'final', text, translated,
        spokenLang: langName(dir.spoken),
        translatedLang: langName(dir.target),
        detectedLang,
      });
    } catch (e) {
      this.log('Final err: ' + e.message);
      this._send({ type: 'interim', text: '', lang: '' });
    }
    this._finalizing = false;
  }

  _resetVAD() {
    this._allBuffers = [];
    this._isSpeaking = false;
    this._speechStartTime = 0;
    this._silenceStartTime = 0;
    this._stopInterimPolling();
  }

  async stop() {
    this.active = false;
    this._stopInterimPolling();
    this.decoder = null;
    if (this._vad) { this._vad.free(); this._vad = null; }
    if (this._isSpeaking && this._allBuffers.length > 10) {
      this.active = true;
      await this._doFinal();
      this.active = false;
    }
    this.log('Stopped');
  }

  _send(msg) {
    try { if (this.ws.readyState === 1) this.ws.send(JSON.stringify(msg)); } catch (_) {}
  }
}

// ---- Server ----
console.log('Moonshine backend:', MOONSHINE_URL);
initFvad().catch(e => console.error('VAD init failed:', e.message));

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
console.log(`Translate relay [Moonshine] on port ${PORT}`);
