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

## Credentials

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.gemini`. The binary reads `GEMINI_API_KEY` through `cyfr:vault/read`; it never learns the vault entry's name.
