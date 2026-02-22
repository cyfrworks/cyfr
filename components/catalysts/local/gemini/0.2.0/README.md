# Gemini Catalyst

CYFR catalyst bridging to Google's Gemini API (`generativelanguage.googleapis.com`).

## Operations

| Operation | Gemini Endpoint | Method |
|-----------|----------------|--------|
| `content.generate` | `/v1beta/models/{model}:generateContent` | POST |
| `content.stream` | `/v1beta/models/{model}:streamGenerateContent?alt=sse` | POST (SSE) |
| `tokens.count` | `/v1beta/models/{model}:countTokens` | POST |
| `embeddings.create` | `/v1beta/models/{model}:embedContent` | POST |
| `embeddings.batch` | `/v1beta/models/{model}:batchEmbedContents` | POST |
| `models.list` | `/v1beta/models` | GET |
| `models.get` | `/v1beta/models/{model}` | GET |

## Input Format

```json
{
  "operation": "content.generate",
  "params": {
    "model": "gemini-2.5-flash",
    "contents": [{"role": "user", "parts": [{"text": "Hello"}]}],
    "generationConfig": {"temperature": 0.7, "maxOutputTokens": 1024}
  },
  "stream": false
}
```

- `operation` (string, required) — one of the operations above
- `params.model` (string, required for all except `models.list`) — Gemini model ID
- `params` (object) — operation-specific parameters passed through to Gemini
- `stream` (boolean) — when true with `content.generate`, uses streaming

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
{"status": 400, "error": {"type": "...", "message": "..."}}
```

## Setup

Automatic (recommended):

```bash
cyfr setup c:local.gemini
```

This reads the manifest and prompts for the API key, grants access, and applies the host policy.

| What | Value |
|------|-------|
| Secret | `GEMINI_API_KEY` |
| Domain | `generativelanguage.googleapis.com` |

<details><summary>Manual setup</summary>

```bash
cyfr register
cyfr secret set GEMINI_API_KEY=<your-key>
cyfr secret grant c:local.gemini GEMINI_API_KEY
cyfr policy set c:local.gemini allowed_domains '["generativelanguage.googleapis.com"]'
```

</details>

## Usage

### CLI

```bash
# List models (version optional — defaults to latest)
cyfr run c:local.gemini --input '{"operation": "models.list", "params": {}}'

# Generate content
cyfr run c:local.gemini --input '{"operation": "content.generate", "params": {"model": "gemini-2.5-flash", "contents": [{"role": "user", "parts": [{"text": "Say hello in one word"}]}]}}'

# Stream content
cyfr run c:local.gemini --input '{"operation": "content.stream", "params": {"model": "gemini-2.5-flash", "contents": [{"role": "user", "parts": [{"text": "Write a haiku"}]}]}}'

# Count tokens
cyfr run c:local.gemini --input '{"operation": "tokens.count", "params": {"model": "gemini-2.5-flash", "contents": [{"role": "user", "parts": [{"text": "How many tokens?"}]}]}}'
```

### MCP

```bash
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
        "reference": {"registry": "catalyst:local.gemini:0.2.0"},
        "input": {
          "operation": "content.generate",
          "params": {
            "model": "gemini-2.5-flash",
            "contents": [{"role": "user", "parts": [{"text": "Hello"}]}]
          }
        },
        "type": "catalyst"
      }
    }
  }'
```

## Secrets

| Secret | Description | How to Obtain |
|--------|-------------|---------------|
| `GEMINI_API_KEY` | Google Gemini API key | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/gemini_catalyst.wasm ../catalyst.wasm
```
