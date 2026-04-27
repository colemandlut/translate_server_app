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
  }

  connect() {
    const headers = {
      'Authorization': `Bearer ${DASHSCOPE_API_KEY}`,
      'X-DashScope-DataInspection': 'enable',
    };
    if (DASHSCOPE_WORKSPACE_ID) headers['X-DashScope-WorkSpace'] = DASHSCOPE_WORKSPACE_ID;
    this.ws = new WebSocket(DASHSCOPE_WS_URL, { headers });
    this.ws.on('open', () => {
      console.log(`[dashscope] ws open, task_id=${this.taskId}`);
      this._sendRunTask();
    });
    this.ws.on('message', (data, isBinary) => this._onMessage(data, isBinary));
    this.ws.on('error', (e) => {
      console.error('[dashscope] ws error:', e.message);
      this.onError && this.onError(e);
    });
    this.ws.on('close', (code, reason) => {
      this.closed = true;
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
      // Audio flushing happens in Task 4
    } else if (event === 'result-generated') {
      // Result handling arrives in Task 5
    } else if (event === 'task-finished') {
      console.log('[dashscope] task-finished');
    } else if (event === 'task-failed') {
      const err = (msg.header && msg.header.error_message) || 'unknown';
      console.error('[dashscope] task-failed:', err);
      this.onError && this.onError(new Error(err));
    }
  }

  sendAudio(pcmChunk) {
    // Implemented in Task 4
  }

  finish() {
    if (this.closed || !this.ws) return;
    if (this.ws.readyState === WebSocket.OPEN) {
      try {
        this.ws.send(JSON.stringify({
          header: { action: 'finish-task', task_id: this.taskId, streaming: 'duplex' },
          payload: { input: {} },
        }));
      } catch (e) { console.error('[dashscope] finish error:', e.message); }
    }
    setTimeout(() => { try { this.ws.close(); } catch (_) {} }, 200);
  }
}

// ---- Per-app session (DashScope wiring comes in Task 3) ----
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
  }

  start(langA, langB) {
    this.langA = langA || 'en-US';
    this.langB = langB || 'zh-CN';
    this.active = true;
    this._frameCount = 0;
    this.dashscope = new DashscopeStream({
      onPartial: (text, lang) => {/* Task 5 */},
      onFinal: (text, lang) => {/* Task 5 */},
      onError: (err) => { console.error('[session] dashscope error:', err.message); },
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
    // PCM bridging to DashScope arrives in Task 4
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

// ---- WebSocket server ----
const wss = new WebSocketServer({ port: PORT });
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

console.log(`[ws] listening on :${PORT}`);
