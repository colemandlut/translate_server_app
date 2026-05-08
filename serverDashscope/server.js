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

// ---- HTTP server (translate proxy for on-device clients) + WS upgrade ----
const http = require('http');
const httpServer = http.createServer((req, res) => {
  // CORS for browser clients (no-op for native flutter HTTP)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

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

