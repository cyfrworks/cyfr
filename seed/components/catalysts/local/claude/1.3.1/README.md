# Claude Catalyst

CYFR catalyst bridging to Anthropic's Claude API (`api.anthropic.com`).

## Operations

| Operation | Claude Endpoint | Method |
|-----------|----------------|--------|
| `messages.create` | `/v1/messages` | POST |
| `messages.stream` | `/v1/messages` (stream: true) | POST (SSE) |
| `messages.count_tokens` | `/v1/messages/count_tokens` | POST |
| `models.list` | `/v1/models` | GET |
| `batches.create` | `/v1/messages/batches` | POST |
| `batches.get` | `/v1/messages/batches/{id}` | GET |
| `batches.list` | `/v1/messages/batches` | GET |
| `batches.cancel` | `/v1/messages/batches/{id}/cancel` | POST |
| `batches.results` | `/v1/messages/batches/{id}/results` | GET |

## `model/chat@1`

The catalyst declares the model contract (`"contracts": ["model/chat@1"]` in its manifest) and answers its three operations on the same `run` export: `chat` (a contract request in; the answer streams as the contract's events on the execution's event stream through `cyfr:emit/events`, and the whole contract response is answered), `describe` (capabilities, answered without a key; with a `model` param, that model's `context_window` and `max_output_tokens`, from the Models API's, which takes the key, or an `unknown_model` refusal) and `models` (the bound key's reachable models, normalized). The shapes are documented once, in `component-guide.md` under "Model catalysts"; the mapping onto this provider's API lives in `src/src/chat.rs` and the stream reading in `src/src/stream.rs`, with host-target tests (`cargo test` in `src/`).

## Input Format

```json
{
  "operation": "messages.create",
  "params": {
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hello"}]
  }
}
```

- `operation` (string, required) — one of the operations above
- `params` (object) — operation-specific parameters passed through to Claude

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

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.claude`. The binary reads `ANTHROPIC_API_KEY` through `cyfr:vault/read`; it never learns the vault entry's name.
