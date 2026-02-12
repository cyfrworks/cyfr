# OpenAI Catalyst

CYFR catalyst bridging to OpenAI's API (`api.openai.com`).

## Operations

| Operation | OpenAI Endpoint | Method |
|-----------|----------------|--------|
| `chat.completions.create` | `/v1/chat/completions` | POST |
| `chat.completions.create` + `stream: true` | `/v1/chat/completions` (SSE) | POST (SSE) |
| `models.list` | `/v1/models` | GET |
| `models.get` | `/v1/models/{model_id}` | GET |
| `embeddings.create` | `/v1/embeddings` | POST |
| `moderations.create` | `/v1/moderations` | POST |
| `images.generate` | `/v1/images/generations` | POST |
| `audio.speech` | `/v1/audio/speech` | POST |
| `audio.transcriptions` | `/v1/audio/transcriptions` | POST (multipart) |
| `audio.translations` | `/v1/audio/translations` | POST (multipart) |
| `responses.create` | `/v1/responses` | POST |
| `files.list` | `/v1/files` | GET |
| `files.get` | `/v1/files/{file_id}` | GET |
| `files.delete` | `/v1/files/{file_id}` | DELETE |

## Input Format

```json
{
  "operation": "chat.completions.create",
  "params": {
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 1024
  },
  "stream": false
}
```

- `operation` (string, required) — one of the operations above
- `params` (object) — operation-specific parameters passed through to OpenAI
- `stream` (boolean) — when true with `chat.completions.create`, uses streaming

## Output Format

Success:
```json
{"status": 200, "data": { ... }}
```

Streaming success:
```json
{"status": 200, "data": {"chunks": [...], "combined_text": "full text"}}
```

Error:
```json
{"status": 401, "error": {"type": "...", "message": "..."}}
```

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/openai_catalyst.wasm ../catalyst.wasm
```

## Setup

```bash
cyfr register components/catalysts/local/openai/0.1.0/
cyfr secret set OPENAI_API_KEY=sk-...
cyfr secret grant local.openai:0.1.0 OPENAI_API_KEY
cyfr policy set local.openai:0.1.0 allowed_domains '["api.openai.com"]'
```

## Test

```bash
# Offline tests only:
mix test apps/opus/test/opus/openai_catalyst_test.exs

# With invalid keys (hits API, zero cost):
mix test apps/opus/test/opus/openai_catalyst_test.exs --include external

# Full integration with real API key:
OPENAI_API_KEY=sk-... mix test apps/opus/test/opus/openai_catalyst_test.exs --include integration --include external
```
