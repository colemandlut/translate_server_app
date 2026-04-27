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
