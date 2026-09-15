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

## `model/chat@1`

The catalyst declares the model contract (`"contracts": ["model/chat@1"]` in its manifest) and answers its three operations on the same `run` export: `chat` (a contract request in; the answer streams as the contract's events on the execution's event stream through `cyfr:emit/events`, and the whole contract response is answered), `describe` (capabilities, answered without a key; with a `model` param that names a model by its id or a dated snapshot of it, that model's `context_window` and `max_output_tokens`, from a table in `src/src/chat.rs` (the Models API reports none), or an `unknown_model` refusal) and `models` (the bound key's reachable models, normalized). The shapes are documented once, in `component-guide.md` under "Model catalysts"; the mapping onto this provider's API lives in `src/src/chat.rs` and the stream reading in `src/src/stream.rs`, with host-target tests (`cargo test` in `src/`).

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

## Credentials

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.openai`. The binary reads `OPENAI_API_KEY` through `cyfr:vault/read`; it never learns the vault entry's name.
