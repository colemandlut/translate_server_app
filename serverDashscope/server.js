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
