# serverDashscope —— 阿里云 DashScope Paraformer-Realtime ASR 后端

- **日期**：2026-04-27
- **作者**：coleman_dlut
- **状态**：Design 阶段（待 plan）
- **Brainstorm 路线**：D（新增对比基准），不替换任何现有后端
- **目标后端编号**：第 4 个 STT 后端（与 `serverv1` / `serverWhisper` / `serverMoonshine` 并列）

---

## 1. 目标 & 范围

新增 `serverDashscope/` 目录，作为 Flutter app 可切换的第 4 个 ASR 后端，借助阿里云 DashScope 上的 `paraformer-realtime-v2` 模型测试以下假设：

- 中文流式 ASR 在 SaaS 路径下能否做到 **首词延迟 ≤ 500ms**
- DashScope 原生 partial 是否提供"逐字增量"体验
- 服务端 VAD 完全交给 DashScope 后，整体代码与运行复杂度是否显著低于 Whisper / Moonshine 路径

### 1.1 KPI（目标 + 实测）

**目标 KPI（设计期，2026-04-27）：**

| 指标 | 目标 |
|---|---|
| 首词延迟（用户开口 → app 收到首个 `interim`） | P50 ≤ 500ms |
| 流式粒度 | 逐字增量（DashScope 原生） |
| 句末判定 | 由 DashScope `SentenceEnd` 触发 final |
| 自动语种识别 | 中 / 英（与现有协议 `lang` 字段对齐；v2 也支持日韩粤但暂不放进 KPI） |

**实测结果（2026-04-27 Task 8 验收，10 句中文 TTS 样本，本地 Mac → 公网 DashScope cn-shanghai endpoint）：**

| 指标 | 实测 | 与目标差距 |
|---|---|---|
| 首词延迟 P50 | **835ms** | 超出目标 67% |
| 首词延迟 P95 | 1601ms | — |
| 首词延迟 mean | 975ms | — |
| 流式粒度 | 逐字增量 ✓ | 达标 |
| 句末判定 | DashScope `SentenceEnd` ✓ | 达标 |
| 自动语种识别 | 中/英自动正确切换 ✓ | 达标 |

**根因分析：** 每个 session 在收到 app 的 `start` 后才**冷启动**对 DashScope 的 WebSocket 连接，TCP/TLS 握手 ~300–1000ms 期间音频被本地缓冲；`task-started` 到达时已积压 15–51 帧待 flush，DashScope 处理完 flush 才出第一个 partial。基线延迟由握手 + 缓冲累积 + 推理三部分组成，无论 DashScope 推理多快，**冷连模式下 P50 难以压进 500ms**。

**优化方向（不在本 spec 范围内，留给后续 task）：**

- **Pre-connect**：在 `ws.on('connection')` 阶段就开始与 DashScope 握手（用默认 `language_hints: ['zh','en']`），不等 app 的 `start`。等用户真正按下录音键时，DashScope 连接已就绪，首词延迟 ≈ 推理时间 ≈ 250–400ms（理论可进 KPI）。代价：每个 app 连接都会持有一个 DashScope 连接，资源/费用略升；`start` 帧的 langA/langB 与预热假设不一致时需重连。
- **Connection pooling**：服务端维护若干预热好的 DashScope 连接池，新会话从池中取。
- **Region 调整**：换到 cn-beijing region（用户的 workspace 已在此 region），可能进一步压缩 RTT。

**结论：** 当前 serverDashscope 作为对比基准（D 路线本意）已经回答了核心问题——「DashScope SaaS + 冷连架构」首词延迟基线约 800ms。是否值得为压进 500ms 投入 pre-connect 优化，由 spec §6.3 的跨后端主观对比结果决定（待 Task 9 后用户运行）。

### 1.2 明确不做（YAGNI）

- ❌ 不上 Fly / 任何云端部署，先纯本地
- ❌ 不替换任何现有后端，仅新增
- ❌ 不切换翻译路径，复用现有 Google Translate
- ❌ 不引入逐词时间戳的新协议事件
- ❌ 不修改 Flutter app 端代码，仅切 server URL
- ❌ 不写自动化延迟对比脚本，用临时日志手测即可
- ❌ 不做断线重连重发音频缓冲（实时场景重连后内容已过时）
- ❌ 不做"幻觉过滤"（Whisper 特有问题，Paraformer 不需要）

---

## 2. 架构 & 数据流

```
[Flutter app]
   │  WebSocket（沿用现有协议）
   │  ─→ {type:"start", sourceLang, targetLang}
   │  ─→ Opus 20ms @ 16kHz（二进制帧）
   │  ─→ {type:"stop"}
   │
   ▼
[serverDashscope/server.js  :8082]
   │  • 接受 ws，解 Opus → PCM 16k 16bit mono
   │  • 为每个 app 客户端建立一条 DashScope WebSocket
   │
   │  WebSocket  wss://dashscope.aliyuncs.com/api-ws/v1/inference/
   │  ─→ run-task（控制帧）+ PCM 二进制流
   │  ←─ task-started / result-generated（partial 逐字 / SentenceEnd）/ task-finished
   │
   ├──→ partial → app: {type:"interim", text, lang}
   ├──→ SentenceEnd → 调 Google Translate → app: {type:"final", text, translated, lang}
   │
   ▼
[Google Translate API]   （复用 serverWhisper 的 translateText() 风格）
```

### 2.1 与 serverWhisper 的关键差异

| 模块 | serverWhisper | serverDashscope |
|---|---|---|
| 服务端 VAD | fvad-wasm（10ms 帧） | **不需要**（DashScope 自带） |
| 静音判定 | `SILENCE_DURATION = 800ms` | DashScope `max_sentence_silence: 800` |
| Partial 触发 | 200ms 间隔轮询 + multipart 上传 WAV | **DashScope 主动 push** |
| 一次任务多句 | 否（每句重启 stream） | 是（Paraformer 原生支持连续句） |
| 语种识别 | 双语言并行假设检测 | DashScope `language_hints` 自带 |
| 幻觉过滤 | `isHallucination()` 字符表 | 不需要 |

---

## 3. 目录结构 & 文件清单

```
serverDashscope/
├── server.js          # 主程序，预计 250–350 行
├── package.json       # 依赖：ws + opusscript
├── package-lock.json
├── .env.example       # 列出必需 env
└── README.md          # 启动方式 + env 说明
```

**不创建：** `Dockerfile`、`fly.toml`、`local_*.py`（本仓库的本地推理子进程模式不适用——DashScope 是 SaaS）。

### 3.1 依赖

| 包 | 用途 |
|---|---|
| `ws` | WebSocket server + DashScope WS client |
| `opusscript` | Opus 解码（与 `serverWhisper` 一致，确保 app 端无需改动） |

### 3.2 环境变量

| 变量 | 必需 | 默认 | 说明 |
|---|---|---|---|
| `DASHSCOPE_API_KEY` | ✅ | — | 百炼平台 API key |
| `GOOGLE_API_KEY` | ✅ | — | 翻译用，与 `serverWhisper` 共用 |
| `PORT` | | `8082` | 选 8082 避免与 v1/v2/Whisper(8080) 及 Moonshine(8081) 冲突 |
| `DASHSCOPE_MODEL` | | `paraformer-realtime-v2` | 可改为 `paraformer-realtime-8k-v2` 等做对比 |
| `DASHSCOPE_LANGUAGES` | | `zh,en` | 逗号分隔，传给 `language_hints` |
| `DASHSCOPE_WORKSPACE_ID` | | (空) | 非默认业务空间时必填，作为 `X-DashScope-WorkSpace` header 发送 |
| `DASHSCOPE_WS_URL` | | `wss://dashscope.aliyuncs.com/api-ws/v1/inference` | 仅当公网 endpoint 拒绝你的 key（401/403）需要走 workspace-scoped MaaS 主机时覆盖 |

---

## 4. DashScope 调用细节

### 4.1 Endpoint & 鉴权

```
wss://dashscope.aliyuncs.com/api-ws/v1/inference/
Authorization: Bearer ${DASHSCOPE_API_KEY}
X-DashScope-DataInspection: enable
```

### 4.2 消息协议（DashScope 通用 WebSocket 范式）

每个 app 会话生命周期内，serverDashscope 发给 DashScope 的消息序列：

**1) `run-task`（text frame，开启任务）**

```json
{
  "header": {
    "action": "run-task",
    "task_id": "<uuid-v4>",
    "streaming": "duplex"
  },
  "payload": {
    "task_group": "audio",
    "task": "asr",
    "function": "recognition",
    "model": "paraformer-realtime-v2",
    "parameters": {
      "format": "pcm",
      "sample_rate": 16000,
      "language_hints": ["zh", "en"],
      "semantic_punctuation_enabled": true,
      "max_sentence_silence": 800
    },
    "input": {}
  }
}
```

**2) 音频帧（binary frame）**：解码后的 PCM 16k 16bit mono，按 ~100ms 一片（≈3200 字节）持续上行。**必须等到收到 `task-started` 之后才开始往 DashScope 上行**，避免丢首包。在此之前 app 已经送来的 PCM 在 server 内存里短缓冲（实测 `task-started` 通常 100–300ms 内到达，缓冲量 < 10KB，无需限长）；`task-started` 一到立即把缓冲全部 flush 上行，之后切换为实时透传。

**3) `finish-task`（text frame，结束）**

```json
{
  "header": { "action": "finish-task", "task_id": "<同上>", "streaming": "duplex" },
  "payload": { "input": {} }
}
```

### 4.3 接收事件（关心这 4 类）

| 事件 | 处理 |
|---|---|
| `task-started` | 标记 ready，flush 短缓冲并切换到实时透传（详见 §4.2） |
| `result-generated` | 见 §4.4 |
| `task-finished` | 关闭 app 侧 ws（如果还开着） |
| `task-failed` | log error，给 app 推空 final 收尾，关 ws |

### 4.4 `result-generated` 处理

`payload.output.sentence` 包含：
- `text`：从句首到当前的**累积**文本（每次都是完整字符串，不是增量）
- `sentence_end`：bool，是否为句末
- `begin_time` / `end_time` / `words`（暂不使用）

逻辑：
- `sentence_end === false` → `app.send({type:"interim", text, lang})`
  - `lang` 取自 DashScope 返回的语言识别字段（若无则透传 `start` 时 app 传的 `sourceLang`）
- `sentence_end === true` → 调 `translateText(text, targetLang)` → `app.send({type:"final", text, translated, lang})`
  - `translateText` 直接从 `serverWhisper/server.js` 复制过来（不抽共用 lib，YAGNI）；签名与行为保持一致，方便未来同步 bugfix

### 4.5 首词延迟预算

> ⚠️ **以下是设计期的预算估算，未考虑冷连接握手成本。实测结果（P50 = 835ms）见 §1.1 — 该预算假设 DashScope 连接已预热（pre-connect），实际部署中每个 session 都要冷启动 WS 握手 ~300–1000ms，因此实测远高于预算。预算在「连接已预热」假设下仍然成立。**

```
app→server LAN          ~5ms
Opus 解码                ~1ms
server→DashScope（国内站）~30–80ms
DashScope 推理首字       ~200–300ms（Paraformer-Realtime 公开数据）
回程                     ~30–80ms
─────────────────────
合计                     ~270–470ms ✓ 大概率达 P50 ≤ 500ms
```

跨境访问约再 +150~200ms，因此本设计仅承诺**本地开发环境 + 国内站**下的 KPI。

---

## 5. 错误处理与重连

### 5.1 DashScope 侧异常

| 情况 | 处理 |
|---|---|
| `task-failed` | log，给 app 推 `{type:"final", text:"", translated:""}` 收尾，关 app ws |
| WS 意外断开（网络抖动 / 超时） | 当前句子放弃，不重发缓冲；下一次 app 发 `start` 时重新建 task |
| 鉴权 401 | **进程启动时 fail-fast**——见 §5.3 |

### 5.2 App 侧异常

| 情况 | 处理 |
|---|---|
| App 主动断开 | 立即给 DashScope 发 `finish-task` 并关 WS，避免计费空转 |
| App 长时间不发音频 | 沿用 DashScope 的 task 超时机制，不自己加 timer |

### 5.3 启动时 boot-check

`server.js` 启动后立即：
- 缺 `DASHSCOPE_API_KEY` 或 `GOOGLE_API_KEY` → `process.exit(1)` 并打印缺失的变量名
- 打印加载完成的 `model` / `port` / `language_hints`，便于排错

---

## 6. 测试策略

### 6.1 手工冒烟（必做）

1. 终端 1：`PORT=8082 DASHSCOPE_API_KEY=... GOOGLE_API_KEY=... node server.js`
2. 终端 2（可选）：`wscat -c ws://localhost:8082` 发 `{"type":"start","langA":"zh-CN","langB":"en-US"}`，确认能拿到 `task-started` 之后的状态（Flutter app 实际发送的是 `{langA, langB}` 双语对译协议，非 `{sourceLang, targetLang}`，详见 plan §"Spec Reconciliation"）
3. Flutter app 把 `serverUrl` 改为 `ws://<mac-ip>:8082`，做以下用例：
   - 说一句中文：观察是否逐字增量出现，首词观感 ≤ 0.5s
   - 说一句英文：同上，且 `lang` 字段切到 `en`
   - 不停顿连说两句中文：确认不需要重新 `start`，DashScope 自动断句
   - 主动按"停止"：确认 server 给 DashScope 发了 `finish-task`

### 6.2 延迟测量（验证 KPI）

在 `server.js` 加**临时**日志：
- 记录每次新会话第一帧 PCM 上行时间戳 `audio_in_ts`
- 记录第一个 `result-generated` 事件到达时间戳 `first_partial_ts`
- 跑 5–10 句样本，记录 P50 / P95，与 KPI 0.5s 对照

KPI 验收通过后**删除这些临时日志**（不引入正式延迟测试框架，YAGNI）。

### 6.3 对比基准（D 路线本意）

同一句话依次切到四个 server URL（`serverv1` / `serverWhisper` / `serverMoonshine` / `serverDashscope`），主观对比：
- ASR 准确率
- 首词延迟
- 句末判定灵敏度
- 标点

不写自动化对比脚本（YAGNI）。

### 6.4 单元测试

不做。这个 server 主要是 IO 编排，单测覆盖收益低；冒烟覆盖即可。

---

## 7. 前置条件 & 实施顺序

### 7.1 开发前置（用户准备）

1. 在 [bailian.console.aliyun.com](https://bailian.console.aliyun.com) 开通"百炼"，拿到 DashScope API key
2. 确认 `paraformer-realtime-v2` 模型已经在账号下激活，且免费额度 / 余额足够开发使用
3. 复用现有 `GOOGLE_API_KEY`（serverWhisper 已使用）

### 7.2 实施顺序（writing-plans 阶段会进一步展开）

骨架步骤：

1. 建 `serverDashscope/` 目录 + `package.json` + 安装 `ws`、`opusscript`
2. 写最小可跑：WebSocket server 接 app + Opus → PCM，**先把 PCM dump 成文件**确认音频管道通
3. 加 DashScope WS client：能连上、发 `run-task`、收到 `task-started`
4. 把 PCM 流送给 DashScope，能收到 `result-generated` 并打印
5. 接通现有协议：partial → `interim`，sentence_end → `final`（先不带 translated）
6. 接 Google Translate，final 带上 `translated`
7. 错误处理 + 启动 fail-fast + boot 信息打印
8. Flutter app 端到端冒烟 + 临时日志测延迟，验证 KPI
9. 通过后删延迟日志、补 README + .env.example、git commit

---

## 8. 开放问题

无。所有关键决策已在 brainstorm 阶段敲定（D / B / D / A / A / A）。
