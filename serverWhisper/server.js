const { Server: WebSocketServer } = require('ws');
const https = require('https');
const path = require('path');
const OpusScript = require('opusscript');

const http = require('http');
const WHISPER_API_KEY = process.env.WHISPER_API_KEY || process.env.GROQ_API_KEY || '';
const GOOGLE_API_KEY = process.env.GOOGLE_API_KEY || 'AIzaSyCTN5gvTBRAFmCiU_jFu1mV2N16fEeurCM';
const PORT = process.env.PORT || 8080;
// Whisper backend: local, groq, or deepinfra
// local:      http://localhost:8090
// groq:       https://api.groq.com
// deepinfra:  https://api.deepinfra.com
const WHISPER_URL = process.env.WHISPER_URL || 'http://localhost:8090';
const WHISPER_MODEL = process.env.WHISPER_MODEL || '';

// VAD + streaming config
const SILENCE_THRESHOLD = 200;
const SILENCE_DURATION = 800;    // ms silence = sentence end
const MIN_SPEECH_DURATION = 300;
const MAX_SPEECH_DURATION = 15000;
// Adjust based on backend: local=200ms, cloud=200ms (skips if busy)
const INTERIM_INTERVAL = parseInt(process.env.INTERIM_INTERVAL || '200');

process.on('uncaughtException', (err) => console.error('UNCAUGHT:', err.message));
process.on('unhandledRejection', (err) => console.error('UNHANDLED:', err));

// ---- Whisper API (local, Groq, or DeepInfra) ----
function transcribeAudio(wavBuffer, language) {
  return new Promise((resolve, reject) => {
    const url = new URL(WHISPER_URL);
    const isLocal = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
    const useHttps = url.protocol === 'https:';
    const transport = useHttps ? https : http;

    const boundary = '----FormBoundary' + Date.now() + Math.random();
    const parts = [];
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n`);
    parts.push(wavBuffer);
    parts.push('\r\n');
    let model = WHISPER_MODEL;
    if (!model) {
      if (isLocal) model = 'whisper-large-v3-v20240930_turbo';
      else if (url.hostname.includes('groq')) model = 'whisper-large-v3-turbo';
      else if (url.hostname.includes('deepinfra')) model = 'openai/whisper-large-v3-turbo';
      else model = 'whisper-large-v3-turbo';
    }
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n${model}\r\n`);
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\nverbose_json\r\n`);
    if (language) {
      parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="language"\r\n\r\n${language}\r\n`);
    }
    parts.push(`--${boundary}--\r\n`);

    const body = Buffer.concat(parts.map(p => typeof p === 'string' ? Buffer.from(p) : p));
    const timeout = isLocal ? 30000 : 10000;
    const timer = setTimeout(() => reject(new Error('Whisper timeout')), timeout);

    const headers = {
      'Content-Type': `multipart/form-data; boundary=${boundary}`,
      'Content-Length': body.length,
    };
    if (!isLocal && WHISPER_API_KEY) {
      headers['Authorization'] = `Bearer ${WHISPER_API_KEY}`;
    }

    const req = transport.request({
      hostname: url.hostname,
      port: url.port || (useHttps ? 443 : 80),
      path: '/v1/audio/transcriptions',
      method: 'POST',
      headers,
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
            language: j.language || language || '',
            avgLogProb: j.segments && j.segments[0] ? j.segments[0].avg_logprob : -999,
            noSpeechProb: j.segments && j.segments[0] ? j.segments[0].no_speech_prob : 1,
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

// Dual-language transcription: send both langA and langB in parallel, pick best
async function transcribeDual(wavBuffer, langA, langB) {
  const aCode = langA.split('-')[0].toLowerCase(); // 'zh-CN' -> 'zh'
  const bCode = langB.split('-')[0].toLowerCase(); // 'ja-JP' -> 'ja'

  const [resultA, resultB] = await Promise.all([
    transcribeAudio(wavBuffer, aCode).catch(() => null),
    transcribeAudio(wavBuffer, bCode).catch(() => null),
  ]);

  // Pick the one with higher confidence (avg_logprob closer to 0 = better)
  if (!resultA && !resultB) return { text: '', language: '' };
  if (!resultA) return resultB;
  if (!resultB) return resultA;

  // Filter out empty/noise
  const aValid = resultA.text.length >= 2 && resultA.noSpeechProb < 0.5;
  const bValid = resultB.text.length >= 2 && resultB.noSpeechProb < 0.5;
  if (aValid && !bValid) return resultA;
  if (bValid && !aValid) return resultB;
  if (!aValid && !bValid) return { text: '', language: '' };

  // Both valid: pick higher avg_logprob (closer to 0)
  return resultA.avgLogProb > resultB.avgLogProb ? resultA : resultB;
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

// ---- Utils ----
// Whisper hallucination filter
const HALLUCINATION_PATTERNS = [
  'thank you', 'thanks for watching', 'thanks for listening',
  'please subscribe', 'like and subscribe', 'see you next time',
  'goodbye', 'bye bye', 'bye-bye', 'the end',
  'sous-titrage', 'sous-titre', 'subtitles', 'copyright',
  'music', '♪', '...', 'you', 'yeah', 'okay', 'ok',
  'i don\'t know', 'hmm', 'uh', 'um', 'oh',
  'ご視聴ありがとうございました', 'チャンネル登録',
  'ありがとうございました', 'ありがとうございます',
  'お疲れ様でした', 'それでは', 'では',
  '谢谢', '谢谢观看', '感谢收看',
];

function isHallucination(text, detectedLang, langA, langB) {
  const lower = text.toLowerCase().trim();
  // Check common hallucination phrases
  if (HALLUCINATION_PATTERNS.some(p => lower === p || lower === p + '.')) return true;
  // Very short text (< 4 chars) is likely noise
  if (lower.length < 4) return true;
  // If detected language doesn't match either langA or langB, likely hallucination
  const det = (detectedLang || '').toLowerCase();
  const mapped = WHISPER_LANG_MAP[det] || det;
  const aB = langA.split('-')[0].toLowerCase();
  const bB = langB.split('-')[0].toLowerCase();
  if (mapped && mapped !== aB && mapped !== bB) return true;
  return false;
}

// Whisper returns full names like "Japanese", "Chinese", "English"
const WHISPER_LANG_MAP = {
  'japanese': 'ja', 'chinese': 'zh', 'english': 'en', 'korean': 'ko',
  'french': 'fr', 'german': 'de', 'spanish': 'es', 'portuguese': 'pt',
  'russian': 'ru', 'arabic': 'ar', 'hindi': 'hi', 'thai': 'th',
  'vietnamese': 'vi', 'italian': 'it',
};

function detectDirection(detectedLang, langA, langB) {
  let det = (detectedLang || '').toLowerCase();
  // Map full name to ISO code
  if (WHISPER_LANG_MAP[det]) det = WHISPER_LANG_MAP[det];
  const aB = langA.split('-')[0].toLowerCase();
  const bB = langB.split('-')[0].toLowerCase();
  if (det === bB) return { spoken: langB, target: langA };
  if (det === aB) return { spoken: langA, target: langB };
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

    this._allBuffers = [];     // all PCM for current utterance
    this._isSpeaking = false;
    this._speechStartTime = 0;
    this._silenceStartTime = 0;
    this._interimTimer = null;
    this._interimBusy = false;
    this._lastInterimText = '';
    this._lastInterimLang = '';
  }

  log(m) { console.log(`[${this.id}] ${m}`); }

  start(langA, langB) {
    this.langA = langA;
    this.langB = langB;
    this.active = true;
    try { this.decoder = new OpusScript(16000, 1, OpusScript.Application.VOIP); } catch (e) {
      this.log('Opus fail: ' + e.message);
    }
    this.log(`Started: ${langA} <-> ${langB} [Whisper/Groq]`);
  }

  audio(data) {
    if (!this.active || !this.decoder) return;

    let pcm;
    try {
      const decoded = this.decoder.decode(data, 320);
      pcm = Buffer.from(decoded.buffer, decoded.byteOffset, decoded.byteLength);
    } catch (_) { return; }

    // RMS energy
    let energy = 0;
    for (let i = 0; i < pcm.length; i += 2) {
      const s = pcm.readInt16LE(i);
      energy += s * s;
    }
    const rms = Math.sqrt(energy / (pcm.length / 2));
    const isSpeech = rms > SILENCE_THRESHOLD;
    const now = Date.now();

    if (isSpeech) {
      if (!this._isSpeaking) {
        this._isSpeaking = true;
        this._speechStartTime = now;
        this._silenceStartTime = 0;
        this._lastInterimText = '';
        this._lastInterimLang = '';
        // Start interim polling
        this._startInterimPolling();
      }
      this._allBuffers.push(pcm);
      this._silenceStartTime = 0;

      // Force if too long
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
      if (!this._isSpeaking || this._interimBusy || this._allBuffers.length < 50) return; // min 1s audio
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
      const needDual = WHISPER_URL.includes('deepinfra');
      const result = needDual
        ? await transcribeDual(wav, this.langA, this.langB)
        : await transcribeAudio(wav);
      const ms = Date.now() - t0;

      const text = result.text;
      if (text && text.length >= 2 && text !== this._lastInterimText) {
        if (isHallucination(text, result.language, this.langA, this.langB)) {
          this.log(`interim SKIP hallucination (${ms}ms): "${text.substring(0, 40)}"`);
          this._interimBusy = false;
          return;
        }
        this._lastInterimText = text;
        this._lastInterimLang = result.language;
        this.log(`interim (${ms}ms): "${text.substring(0, 40)}"`);
        this._send({ type: 'interim', text, lang: result.language });

        // Interim translation
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
    this._stopInterimPolling();
    const buffers = this._allBuffers;
    this._resetVAD();

    if (buffers.length < 10) return;

    const durationMs = buffers.length * 20;
    this.log(`Final transcribing ${durationMs}ms...`);

    try {
      const wav = buildWav(buffers, 16000);
      const t0 = Date.now();
      const needDual = WHISPER_URL.includes('deepinfra');
      const result = needDual
        ? await transcribeDual(wav, this.langA, this.langB)
        : await transcribeAudio(wav);
      const ms = Date.now() - t0;

      const text = result.text;
      if (!text || text.length < 2 || isHallucination(text, result.language, this.langA, this.langB)) {
        this.log(`Empty/hallucination (${ms}ms): "${(text||'').substring(0,30)}"`);
        this._send({ type: 'interim', text: '', lang: '' });
        this._send({ type: 'interim', text: '', lang: '' });
        return;
      }

      const detectedLang = result.language;
      this.log(`Final [${detectedLang}] (${ms}ms): "${text.substring(0, 50)}"`);

      // Send interim text first
      this._send({ type: 'interim', text, lang: detectedLang });

      // Translate
      const dir = detectDirection(detectedLang, this.langA, this.langB);
      const translated = await translateText(text, transCode(dir.target));

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
  }

  _resetVAD() {
    this._allBuffers = [];
    this._isSpeaking = false;
    this._speechStartTime = 0;
    this._silenceStartTime = 0;
    this._stopInterimPolling();
  }

  async stop() {
    this._stopInterimPolling();
    if (this._isSpeaking && this._allBuffers.length > 10) {
      await this._doFinal();
    }
    this.active = false;
    this.decoder = null;
    this.log('Stopped');
  }

  _send(msg) {
    try { if (this.ws.readyState === 1) this.ws.send(JSON.stringify(msg)); } catch (_) {}
  }
}

// ---- Server ----
const whisperTarget = WHISPER_URL.includes('localhost') ? 'Local' :
  WHISPER_URL.includes('groq') ? 'Groq' :
  WHISPER_URL.includes('deepinfra') ? 'DeepInfra' : 'Custom';
console.log('Whisper backend:', whisperTarget, WHISPER_URL);

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
console.log(`Translate relay [Whisper/Groq] on port ${PORT}`);
