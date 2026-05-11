// ---- Config & boot ----
const PORT = parseInt(process.env.PORT || '8082', 10);
const DASHSCOPE_API_KEY = process.env.DASHSCOPE_API_KEY || '';
const GOOGLE_API_KEY = process.env.GOOGLE_API_KEY || '';
const DASHSCOPE_MODEL = process.env.DASHSCOPE_MODEL || 'paraformer-realtime-v2';
const DASHSCOPE_LANGUAGES = (process.env.DASHSCOPE_LANGUAGES || 'zh,en')
  .split(',').map((s) => s.trim()).filter(Boolean);
const DASHSCOPE_WS_URL = process.env.DASHSCOPE_WS_URL
  || 'wss://dashscope.aliyuncs.com/api-ws/v1/inference';
const DASHSCOPE_WORKSPACE_ID = process.env.DASHSCOPE_WORKSPACE_ID || '';

if (!DASHSCOPE_API_KEY) {
  console.error('FATAL: DASHSCOPE_API_KEY is required'); process.exit(1);
}
if (!GOOGLE_API_KEY) {
  console.error('FATAL: GOOGLE_API_KEY is required'); process.exit(1);
}

process.on('uncaughtException', (err) => console.error('UNCAUGHT:', err.message));
process.on('unhandledRejection', (err) => console.error('UNHANDLED:', err));

console.log(`[boot] serverDashscope on :${PORT}`);
console.log(`[boot] model=${DASHSCOPE_MODEL} languages=${DASHSCOPE_LANGUAGES.join(',')}`);
console.log(`[boot] ws_url=${DASHSCOPE_WS_URL}${DASHSCOPE_WORKSPACE_ID ? ` workspace=${DASHSCOPE_WORKSPACE_ID}` : ''}`);

// ---- Translation (initially copied from serverWhisper/server.js; timeout tightened to 3s
//      because a slow translate would block the per-session promise chain in onFinal) ----
const https = require('https');

function translateText(text, targetLang) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), 3000);
    const body = JSON.stringify({ q: text, target: targetLang, format: 'text' });
    const req = https.request({
      hostname: 'translation.googleapis.com',
      path: `/language/translate/v2?key=${GOOGLE_API_KEY}`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 3000,
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

// ---- Bilingual direction ----
// transCode: BCP-47 -> Google Translate `target` form
function transCode(c) { return c.toLowerCase() === 'zh-tw' ? 'zh-TW' : c.split('-')[0]; }

// detectDirection: pick {spoken, target} from {langA, langB} given detected lang
// detectedLang is the short form returned by detectLang() (e.g. "zh", "en")
function detectDirection(detectedLang, langA, langB) {
  const det = (detectedLang || '').toLowerCase();
  const aShort = langA.split('-')[0].toLowerCase();
  const bShort = langB.split('-')[0].toLowerCase();
  if (det === bShort) return { spoken: langB, target: langA };
  if (det === aShort) return { spoken: langA, target: langB };
  console.warn(`[direction] detected ${det || '<empty>'} matches neither ${langA}/${langB}, defaulting to A`);
  return { spoken: langA, target: langB };
}

// ---- DashScope client ----
const WebSocket = require('ws');
const { randomUUID } = require('crypto');

class DashscopeStream {
  constructor({ onPartial, onFinal, onError }) {
    this.onPartial = onPartial;
    this.onFinal = onFinal;
    this.onError = onError;
    this.ws = null;
    this.taskId = randomUUID().replace(/-/g, '');
    this.ready = false;
    this.closed = false;
    this._pcmBuffer = []; // PCM chunks received before task-started
    this._connectTimer = null;
    this._finishTimer = null;
    this._errored = false;
    this._finishPending = false; // finish() called before task-started
  }

  connect() {
    const headers = {
      'Authorization': `Bearer ${DASHSCOPE_API_KEY}`,
      'X-DashScope-DataInspection': 'enable',
    };
    if (DASHSCOPE_WORKSPACE_ID) headers['X-DashScope-WorkSpace'] = DASHSCOPE_WORKSPACE_ID;
    this.ws = new WebSocket(DASHSCOPE_WS_URL, { headers });
    this._connectTimer = setTimeout(() => {
      if (!this.ready) {
        console.error('[dashscope] connect timeout (5s)');
        this._callError(new Error('dashscope connect timeout'));
        try { this.ws.terminate(); } catch (_) {}
      }
    }, 5000);
    this._connectTimer.unref();
    this.ws.on('open', () => {
      console.log(`[dashscope] ws open, task_id=${this.taskId}`);
      this._sendRunTask();
    });
    this.ws.on('message', (data, isBinary) => this._onMessage(data, isBinary));
    this.ws.on('error', (e) => {
      console.error('[dashscope] ws error:', e.message);
      this._callError(e);
    });
    this.ws.on('close', (code, reason) => {
      this.closed = true;
      clearTimeout(this._connectTimer);
      clearTimeout(this._finishTimer);
      console.log(`[dashscope] ws closed code=${code} reason=${reason}`);
    });
  }

  _sendRunTask() {
    const msg = {
      header: { action: 'run-task', task_id: this.taskId, streaming: 'duplex' },
      payload: {
        task_group: 'audio',
        task: 'asr',
        function: 'recognition',
        model: DASHSCOPE_MODEL,
        parameters: {
          format: 'pcm',
          sample_rate: 16000,
          language_hints: DASHSCOPE_LANGUAGES,
          semantic_punctuation_enabled: true,
          max_sentence_silence: 800,
        },
        input: {},
      },
    };
    this.ws.send(JSON.stringify(msg));
  }

  _onMessage(data, isBinary) {
    if (isBinary) return; // DashScope responses are JSON text frames
    let msg;
    try { msg = JSON.parse(data.toString()); }
    catch (e) { console.error('[dashscope] bad json:', e.message); return; }
    const event = msg.header && msg.header.event;
    if (event === 'task-started') {
      console.log('[dashscope] task-started');
      this.ready = true;
      clearTimeout(this._connectTimer);
      if (this._pcmBuffer.length > 0) {
        let sendFailed = false;
        for (const buf of this._pcmBuffer) {
          try { this.ws.send(buf, { binary: true }); }
          catch (e) {
            if (!sendFailed) { console.error('[dashscope] flush send failed:', e.message); sendFailed = true; }
            break;
          }
        }
        console.log(`[dashscope] flushed ${this._pcmBuffer.length} buffered chunks on ready`);
        this._pcmBuffer = [];
      }
      // If finish() was requested before we were ready (e.g. client sent
      // start + all audio + stop in one burst), send finish-task now.
      if (this._finishPending) {
        console.log('[dashscope] deferred finish-task fired after task-started');
        this._finishPending = false;
        this.finish();
      }
    } else if (event === 'result-generated') {
      const sentence = msg.payload && msg.payload.output && msg.payload.output.sentence;
      if (!sentence) return;
      const text = (sentence.text || '').trim();
      if (!text) return;
      // Sentence-final signal: end_time non-null OR explicit sentence_end flag
      const isFinal = (sentence.end_time !== null && sentence.end_time !== undefined)
                   || sentence.sentence_end === true;
      if (isFinal) {
        this.onFinal && this.onFinal(text);
      } else {
        this.onPartial && this.onPartial(text);
      }
    } else if (event === 'task-finished') {
      console.log('[dashscope] task-finished');
      clearTimeout(this._connectTimer);
      clearTimeout(this._finishTimer);
      try { this.ws.close(); } catch (_) {}
    } else if (event === 'task-failed') {
      const code = (msg.header && msg.header.error_code) || 'unknown';
      const errMsg = (msg.header && msg.header.error_message) || 'unknown';
      console.error(`[dashscope] task-failed: code=${code} message=${errMsg}`);
      clearTimeout(this._finishTimer);
      this._callError(new Error(`${code}: ${errMsg}`));
    }
  }

  _callError(err) {
    if (this._errored) return;
    this._errored = true;
    this._pcmBuffer = []; // drop any buffered audio — session is failed
    this.onError && this.onError(err);
  }

  sendAudio(pcmChunk) {
    if (this.closed) return;
    if (!this.ready) {
      this._pcmBuffer.push(pcmChunk);
      return;
    }
    if (this._pcmBuffer.length > 0) {
      // Flush buffer in order, then drop the buffer
      let sendFailed = false;
      for (const buf of this._pcmBuffer) {
        try { this.ws.send(buf, { binary: true }); }
        catch (e) {
          if (!sendFailed) { console.error('[dashscope] flush send failed:', e.message); sendFailed = true; }
          break;
        }
      }
      console.log(`[dashscope] flushed ${this._pcmBuffer.length} buffered chunks`);
      this._pcmBuffer = [];
    }
    try { this.ws.send(pcmChunk, { binary: true }); } catch (_) {}
  }

  finish() {
    if (this.closed || !this.ws) return;
    // If task-started hasn't arrived yet, defer the finish; _onMessage will
    // call finish() again as soon as task-started comes back.
    if (!this.ready || this.ws.readyState !== WebSocket.OPEN) {
      this._finishPending = true;
      console.log('[dashscope] finish() deferred — task not yet started');
      return;
    }
    try {
      this.ws.send(JSON.stringify({
        header: { action: 'finish-task', task_id: this.taskId, streaming: 'duplex' },
        payload: { input: {} },
      }));
    } catch (e) { console.error('[dashscope] finish error:', e.message); }
    // 10s — long enough for DashScope to finish processing burst-uploaded
    // audio (e.g. an 8-second utterance from cloud secondary recognition);
    // task-finished arriving sooner clears this timer (line ~193).
    this._finishTimer = setTimeout(() => { try { this.ws.close(); } catch (_) {} }, 10_000);
    this._finishTimer.unref();
  }
}

// ---- Language direction (script-based) ----
function detectLang(text) {
  // ISO 639-1 short codes; expanded to BCP-47 by detectDirection in Task 6.
  // Order matters: kana proves Japanese before any CJK ideograph test.
  if (/[぀-ヿ]/.test(text)) return 'ja';   // kana proves Japanese
  if (/[가-힯]/.test(text)) return 'ko';
  if (/[一-鿿]/.test(text)) return 'zh';   // CJK ideographs after kana check
  if (/[Ѐ-ӿ]/.test(text)) return 'ru';
  if (/[؀-ۿ]/.test(text)) return 'ar';
  if (/[฀-๿]/.test(text)) return 'th';
  if (/[ऀ-ॿ]/.test(text)) return 'hi';
  return 'en'; // default for Latin-script
}

// ---- Per-app session ----
const { Server: WebSocketServer } = require('ws');
const OpusScript = require('opusscript');

class Session {
  constructor(ws) {
    this.ws = ws;
    this.opus = new OpusScript(16000, 1, OpusScript.Application.VOIP);
    this.langA = 'en-US';
    this.langB = 'zh-CN';
    this.active = false;
    this._frameCount = 0;
    this._finalChain = Promise.resolve();
    this._lastInterimText = '';
    this._lastInterimTranslateAt = 0;
  }

  start(langA, langB) {
    this.langA = langA || 'en-US';
    this.langB = langB || 'zh-CN';
    this.active = true;
    this._frameCount = 0;
    this.dashscope = new DashscopeStream({
      onPartial: (text) => {
        if (text === this._lastInterimText) return; // dashscope repeats identical partials
        this._lastInterimText = text;
        const detected = detectLang(text);
        const dir = detectDirection(detected, this.langA, this.langB);
        this.send({ type: 'interim', text, lang: dir.spoken });
        // Translate partial in background, throttled. Drop result if stale.
        const now = Date.now();
        if (now - this._lastInterimTranslateAt < 250) return;
        this._lastInterimTranslateAt = now;
        const targetCode = transCode(dir.target);
        translateText(text, targetCode).then((translated) => {
          if (this._lastInterimText !== text || !this.active) return;
          this.send({ type: 'interim_translation', text, translated, lang: dir.spoken });
        }).catch((e) => console.error('[interim translate] failed:', e.message));
      },
      onFinal: (text) => {
        // Serialize on a per-session promise chain so concurrent finals from DashScope's
        // sentence splitter emit in order even when Google Translate latencies vary.
        this._finalChain = this._finalChain.then(async () => {
          try {
            const detected = detectLang(text);
            const dir = detectDirection(detected, this.langA, this.langB);
            let translated = '';
            try {
              translated = await translateText(text, transCode(dir.target));
            } catch (e) {
              console.error('[translate] failed:', e.message);
            }
            // Use spoken (BCP-47, e.g. zh-CN) as the lang field — matches serverWhisper behavior
            this.send({ type: 'final', text, translated, lang: dir.spoken });
          } catch (e) {
            console.error('[session] onFinal error:', e.message);
          }
        });
      },
      onError: (err) => {
        console.error('[session] dashscope error:', err.message);
        this.send({ type: 'final', text: '', translated: '', lang: this.langA });
        this.active = false;
      },
    });
    this.dashscope.connect();
    console.log(`[session] start langA=${this.langA} langB=${this.langB}`);
  }

  audio(opusFrame) {
    if (!this.active || !this.opus) return;
    let pcm;
    try {
      const decoded = this.opus.decode(opusFrame, 320); // 20ms @ 16kHz = 320 samples
      pcm = Buffer.from(decoded.buffer, decoded.byteOffset, decoded.byteLength);
    } catch (e) {
      console.error('[opus] decode error:', e.message);
      return;
    }
    this._frameCount++;
    if (this._frameCount === 1) {
      console.log(`[audio] first frame decoded: ${pcm.length} bytes pcm`);
    }
    if (this.dashscope) this.dashscope.sendAudio(pcm);
  }

  stop() {
    this.active = false;
    this.opus = null;
    if (this.dashscope) { this.dashscope.finish(); this.dashscope = null; }
    console.log(`[session] stop (${this._frameCount} frames received)`);
  }

  send(msg) {
    try { if (this.ws.readyState === 1) this.ws.send(JSON.stringify(msg)); } catch (_) {}
  }
}

// ---- File-mode recognition (POST /file-recognize + GET /tmp-audio/:token) ----
// Whole-recording ASR using Dashscope paraformer-v2 file API (async task).
// Flow: client uploads m4a → we save to /tmp + expose a one-shot HTTPS URL on
// this same server → submit task → poll → fetch transcription JSON → Google
// Translate the aggregated text → return one JSON response.
const Busboy = require('busboy');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');

const FILE_RECOGNIZE_TMP_DIR = '/tmp/file-recognize';
try { fs.mkdirSync(FILE_RECOGNIZE_TMP_DIR, { recursive: true }); } catch (_) {}

// In-memory map of temp-token -> { path, expiresAt }. Cleaned up by the
// /file-recognize handler when its task is done, with a sweep fallback.
const _tempFileTokens = new Map();
setInterval(() => {
  const now = Date.now();
  for (const [token, entry] of _tempFileTokens) {
    if (entry.expiresAt < now) {
      _tempFileTokens.delete(token);
      fsp.unlink(entry.path).catch(() => {});
    }
  }
}, 60_000).unref();

// translateText with a configurable (longer) timeout — overall-text translation
// can take a few seconds because the input is much longer than per-utterance.
function translateTextLong(text, targetLang, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), timeoutMs);
    const body = JSON.stringify({ q: text, target: targetLang, format: 'text' });
    const req = https.request({
      hostname: 'translation.googleapis.com',
      path: `/language/translate/v2?key=${GOOGLE_API_KEY}`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: timeoutMs,
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

async function fetchJsonDashscope(url, { method = 'GET', body = null, extraHeaders = {} } = {}) {
  const headers = {
    'Authorization': `Bearer ${DASHSCOPE_API_KEY}`,
    'Content-Type': 'application/json',
    ...extraHeaders,
  };
  if (DASHSCOPE_WORKSPACE_ID) headers['X-DashScope-WorkSpace'] = DASHSCOPE_WORKSPACE_ID;
  const r = await fetch(url, { method, headers, body });
  const txt = await r.text();
  let json;
  try { json = JSON.parse(txt); } catch (_) { json = { rawText: txt }; }
  if (!r.ok) {
    const err = new Error(`HTTP ${r.status}: ${(json && (json.message || json.code)) || txt.slice(0, 200)}`);
    err.statusCode = r.status;
    err.body = json;
    throw err;
  }
  return json;
}

async function submitDashscopeTranscriptionTask(fileUrl, languageHints) {
  const body = JSON.stringify({
    model: 'paraformer-v2',
    input: { file_urls: [fileUrl] },
    parameters: { language_hints: languageHints, disfluency_removal_enabled: false },
  });
  const j = await fetchJsonDashscope(
    'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription',
    { method: 'POST', body, extraHeaders: { 'X-DashScope-Async': 'enable' } },
  );
  const taskId = j && j.output && j.output.task_id;
  if (!taskId) throw new Error('no task_id: ' + JSON.stringify(j).slice(0, 200));
  return taskId;
}

async function pollDashscopeTask(taskId, { intervalMs = 2000, maxMs = 120_000 } = {}) {
  const start = Date.now();
  while (Date.now() - start < maxMs) {
    const j = await fetchJsonDashscope(`https://dashscope.aliyuncs.com/api/v1/tasks/${taskId}`);
    const status = j && j.output && j.output.task_status;
    if (status === 'SUCCEEDED') return j.output;
    if (status === 'FAILED') {
      const reason = (j.output && (j.output.message || j.output.code)) || 'task FAILED';
      throw new Error(reason);
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error('dashscope task poll timeout');
}

async function fetchTranscriptionJson(transcriptionUrl) {
  const r = await fetch(transcriptionUrl);
  if (!r.ok) throw new Error(`transcription fetch HTTP ${r.status}`);
  return await r.json();
}

// Aggregate Dashscope file-mode transcription JSON into { text, lang }. The
// response shape is `{ transcripts: [{ text, sentences: [{ text, language? }] }] }`.
// We pick the dominant per-sentence language for translation targeting.
function aggregateTranscription(json) {
  if (!json || !Array.isArray(json.transcripts) || json.transcripts.length === 0) {
    return { text: '', lang: '' };
  }
  const langCounts = new Map();
  const lines = [];
  for (const tr of json.transcripts) {
    const trText = (tr.text || '').trim();
    if (trText) lines.push(trText);
    const sentences = Array.isArray(tr.sentences) ? tr.sentences : [];
    for (const s of sentences) {
      const lang = (s.language || tr.language || '').toLowerCase();
      if (lang) langCounts.set(lang, (langCounts.get(lang) || 0) + 1);
    }
  }
  let bestLang = '';
  let bestCount = 0;
  for (const [lang, count] of langCounts) {
    if (count > bestCount) { bestLang = lang; bestCount = count; }
  }
  return { text: lines.join('\n'), lang: bestLang };
}

async function handleFileRecognize(req, res) {
  const fields = {};
  let savedPath = null;
  let token = null;

  await new Promise((resolve, reject) => {
    let bb;
    try { bb = Busboy({ headers: req.headers, limits: { fileSize: 50 * 1024 * 1024 } }); }
    catch (e) { reject(e); return; }
    bb.on('file', (name, fileStream, info) => {
      if (name !== 'audio') { fileStream.resume(); return; }
      token = randomUUID().replace(/-/g, '');
      const extMatch = (info.filename || '').match(/\.(m4a|aac|mp3|wav|mp4)$/i);
      const ext = extMatch ? extMatch[0] : '.m4a';
      savedPath = path.join(FILE_RECOGNIZE_TMP_DIR, `${token}${ext}`);
      const wstream = fs.createWriteStream(savedPath);
      fileStream.pipe(wstream);
      fileStream.on('limit', () => { wstream.destroy(); reject(new Error('file too large (max 50MB)')); });
      wstream.on('error', reject);
    });
    bb.on('field', (name, val) => { fields[name] = val; });
    bb.on('finish', resolve);
    bb.on('error', reject);
    req.pipe(bb);
  });

  if (!savedPath) throw new Error('missing audio field in multipart');

  _tempFileTokens.set(token, { path: savedPath, expiresAt: Date.now() + 5 * 60_000 });

  const protoHeader = req.headers['x-forwarded-proto'];
  const proto = protoHeader ? protoHeader.split(',')[0].trim() : 'https';
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  if (!host) throw new Error('missing host header');
  const fileUrl = `${proto}://${host}/tmp-audio/${token}${path.extname(savedPath)}`;
  console.log(`[file-recognize] saved → ${savedPath} (${token}), url=${fileUrl}`);

  const langA = fields.langA || 'en-US';
  const langB = fields.langB || 'zh-CN';
  const hintsSet = new Set();
  hintsSet.add(langA.split('-')[0].toLowerCase());
  hintsSet.add(langB.split('-')[0].toLowerCase());
  hintsSet.add('zh'); hintsSet.add('en'); // hedge against mixed audio
  const languageHints = [...hintsSet];

  const cleanup = async () => {
    _tempFileTokens.delete(token);
    try { await fsp.unlink(savedPath); } catch (_) {}
  };

  try {
    console.log(`[file-recognize] submit, hints=${languageHints.join(',')}`);
    const taskId = await submitDashscopeTranscriptionTask(fileUrl, languageHints);
    console.log(`[file-recognize] task_id=${taskId}, polling...`);
    const output = await pollDashscopeTask(taskId);
    console.log(`[file-recognize] task SUCCEEDED`);

    const results = output.results || [];
    if (results.length === 0) throw new Error('no transcription results');
    const allTranscripts = [];
    for (const r of results) {
      if (r.subtask_status !== 'SUCCEEDED') {
        console.warn(`[file-recognize] sub-task ${r.subtask_status}: ${r.message || ''}`);
        continue;
      }
      if (!r.transcription_url) continue;
      const tjson = await fetchTranscriptionJson(r.transcription_url);
      allTranscripts.push(tjson);
    }
    if (allTranscripts.length === 0) throw new Error('all sub-tasks failed');

    const lines = [];
    const langCounts = new Map();
    for (const tjson of allTranscripts) {
      const { text, lang } = aggregateTranscription(tjson);
      if (text) lines.push(text);
      if (lang) langCounts.set(lang, (langCounts.get(lang) || 0) + 1);
    }
    const overallText = lines.join('\n');
    let dominantLang = '';
    let best = 0;
    for (const [lang, count] of langCounts) { if (count > best) { dominantLang = lang; best = count; } }
    if (!dominantLang && overallText) dominantLang = detectLang(overallText);

    const dir = detectDirection(dominantLang, langA, langB);
    const targetCode = transCode(dir.target);

    let overallTranslated = '';
    if (overallText) {
      try {
        overallTranslated = await translateTextLong(overallText, targetCode, 30_000);
      } catch (e) {
        console.error('[file-recognize] translate failed:', e.message);
        overallTranslated = '';
      }
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ overallText, overallTranslated, lang: dir.spoken }));
    console.log(`[file-recognize] done: text=${overallText.length}b translated=${overallTranslated.length}b`);
  } finally {
    await cleanup();
  }
}

// ---- HTTP server (translate proxy for on-device clients) + WS upgrade ----
const http = require('http');
const httpServer = http.createServer((req, res) => {
  // CORS for browser clients (no-op for native flutter HTTP)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  if (req.method === 'POST' && req.url === '/file-recognize') {
    handleFileRecognize(req, res).catch((e) => {
      console.error('[file-recognize] error:', e.message);
      if (!res.headersSent) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      } else {
        try { res.end(); } catch (_) {}
      }
    });
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/tmp-audio/')) {
    // URL form: /tmp-audio/<token>.<ext>
    const tail = req.url.slice('/tmp-audio/'.length).split('?')[0];
    const token = tail.split('.')[0];
    const entry = _tempFileTokens.get(token);
    if (!entry) { res.writeHead(404); res.end(); return; }
    fs.stat(entry.path, (err, stat) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': 'audio/mp4', 'Content-Length': stat.size });
      fs.createReadStream(entry.path).pipe(res);
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/translate') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 10000) req.destroy(); });
    req.on('end', async () => {
      try {
        const { text, target } = JSON.parse(body || '{}');
        if (!text || !target) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'text and target required' }));
          return;
        }
        const translated = await translateText(text, target);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ translated }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  // Health probe
  if (req.method === 'GET' && (req.url === '/' || req.url === '/health')) {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
    return;
  }

  res.writeHead(404); res.end();
});

const wss = new WebSocketServer({ server: httpServer });
wss.on('connection', (ws) => {
  console.log('[ws] app connected');
  let session = null;
  ws.on('message', (data, isBinary) => {
    if (isBinary) { if (session) session.audio(data); return; }
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'start') {
        if (session) session.stop();
        session = new Session(ws);
        session.start(msg.langA, msg.langB);
      } else if (msg.type === 'stop') {
        if (session) { session.stop(); session = null; }
      }
    } catch (e) { console.error('[ws] parse:', e.message); }
  });
  ws.on('close', () => {
    if (session) { session.stop(); session = null; }
    console.log('[ws] app disconnected');
  });
  ws.on('error', (e) => {
    if (session) { session.stop(); session = null; }
    console.error('[ws] error:', e.message);
  });
});

httpServer.listen(PORT, () => {
  console.log(`[ws] listening on :${PORT} — point Flutter app at ws://<lan-ip>:${PORT}`);
  console.log(`[http] POST /translate available for on-device clients`);
  console.log(`[boot] ready (DashScope ${DASHSCOPE_MODEL}, langs ${DASHSCOPE_LANGUAGES.join('+')})`);
});

