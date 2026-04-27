# serverDashscope

WebSocket relay: Flutter app ⇄ Alibaba Cloud DashScope `paraformer-realtime-v2` ⇄ Google Translate.

The 4th ASR backend in this repo (peers: `serverv1`, `serverWhisper`, `serverMoonshine`).
**Local-only** — not deployed; serves as a comparison baseline against the other backends.

## Quickstart

```bash
cd serverDashscope
npm install
cp .env.example .env  # then fill in real keys

DASHSCOPE_API_KEY=sk-... \
DASHSCOPE_WORKSPACE_ID=ws-... \
GOOGLE_API_KEY=AIza... \
node server.js
```

Then in the Flutter app, set `serverUrl` to `ws://<your-lan-ip>:8082`.

## Environment variables

| Variable | Required | Default | Notes |
|---|---|---|---|
| `DASHSCOPE_API_KEY` | yes | — | Get from <https://bailian.console.aliyun.com> |
| `DASHSCOPE_WORKSPACE_ID` | recommended | (empty) | Sent as `X-DashScope-WorkSpace` header — required for non-default workspaces |
| `GOOGLE_API_KEY` | yes | — | Same key as serverWhisper |
| `PORT` | no | `8082` | Avoids 8080 (v1/v2/Whisper), 8081 (Moonshine) |
| `DASHSCOPE_MODEL` | no | `paraformer-realtime-v2` | |
| `DASHSCOPE_LANGUAGES` | no | `zh,en` | Comma-separated, sent as `language_hints` |
| `DASHSCOPE_WS_URL` | no | `wss://dashscope.aliyuncs.com/api-ws/v1/inference` | Override only if the public endpoint fails for your key |

## Protocol (matches `serverWhisper`)

- `app → server`: `{type:"start", langA, langB}` then Opus 20ms @ 16kHz binary frames; `{type:"stop"}` to end
- `server → app`: `{type:"interim", text, lang}` and `{type:"final", text, translated, lang}` (where `lang` is BCP-47 like `zh-CN`/`en-US`)

## Performance

Measured first-word latency P50 ≈ 835ms (10-utterance smoke against the public `dashscope.aliyuncs.com` endpoint from a developer Mac). The cold WebSocket connect to DashScope is the dominant component (~300–1000ms TCP/TLS); a pre-connect optimization could close the gap to ~250–400ms but is out of scope for the current implementation.

See `docs/superpowers/specs/2026-04-27-serverDashscope-design.md` §1.1 for full measurement details and optimization options.

## Design

See `docs/superpowers/specs/2026-04-27-serverDashscope-design.md`.
