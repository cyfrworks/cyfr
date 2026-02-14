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

## Setup

```bash
cyfr register components/catalysts/local/openai/0.1.0/
cyfr secret set OPENAI_API_KEY=sk-...
cyfr secret grant c:local.openai:0.1.0 OPENAI_API_KEY
cyfr policy set c:local.openai:0.1.0 allowed_domains '["api.openai.com"]'
```

## Usage

### CLI

```bash
# List models (version optional — defaults to latest)
cyfr run c:local.openai --input '{"operation": "models.list", "params": {}}'

# Create a chat completion
cyfr run c:local.openai --input '{"operation": "chat.completions.create", "params": {"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "Say hello in one word"}], "max_tokens": 1024}}'

# Stream a chat completion
cyfr run c:local.openai --input '{"operation": "chat.completions.create", "params": {"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "Write a haiku"}], "max_tokens": 1024}, "stream": true}'

# Create embeddings
cyfr run c:local.openai --input '{"operation": "embeddings.create", "params": {"model": "text-embedding-3-small", "input": "Hello world"}}'

# Specific version
cyfr run c:local.openai:0.1.0 --input '{"operation": "models.list", "params": {}}'
```

### MCP

```bash
# Create a chat completion
curl -X POST http://localhost:4000/mcp \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -H "Authorization: Bearer cyfr_sk_..." \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "execution",
      "arguments": {
        "action": "run",
        "reference": {"registry": "catalyst:local.openai:0.1.0"},
        "input": {
          "operation": "chat.completions.create",
          "params": {
            "model": "gpt-4o-mini",
            "messages": [{"role": "user", "content": "Hello"}],
            "max_tokens": 1024
          }
        },
        "type": "catalyst"
      }
    }
  }'

# List models
curl -X POST http://localhost:4000/mcp \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -H "Authorization: Bearer cyfr_sk_..." \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "execution",
      "arguments": {
        "action": "run",
        "reference": {"registry": "catalyst:local.openai:0.1.0"},
        "input": {"operation": "models.list", "params": {}},
        "type": "catalyst"
      }
    }
  }'
```

## Secrets

| Secret | Description | How to Obtain |
|--------|-------------|---------------|
| `OPENAI_API_KEY` | OpenAI API key | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/openai_catalyst.wasm ../catalyst.wasm
```
