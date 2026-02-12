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

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/claude_catalyst.wasm ../catalyst.wasm
```

## Setup

```bash
cyfr register components/catalysts/local/claude/0.1.0/
cyfr secret set ANTHROPIC_API_KEY=sk-ant-...
cyfr secret grant claude:0.1.0 ANTHROPIC_API_KEY
cyfr policy set claude:0.1.0 allowed_domains '["api.anthropic.com"]'
```

## Test

```bash
# List models
cyfr run claude:0.1.0 --type catalyst --input '{"operation": "models.list", "params": {}}'

# Create a message
cyfr run claude:0.1.0 --type catalyst --input '{"operation": "messages.create", "params": {"model": "claude-sonnet-4-5-20250929", "max_tokens": 1024, "messages": [{"role": "user", "content": "Say hello in one word"}]}}'

# Stream a message
cyfr run claude:0.1.0 --type catalyst --input '{"operation": "messages.stream", "params": {"model": "claude-sonnet-4-5-20250929", "max_tokens": 1024, "messages": [{"role": "user", "content": "Write a haiku about Elixir"}]}}'

# Count tokens
cyfr run claude:0.1.0 --type catalyst --input '{"operation": "messages.count_tokens", "params": {"model": "claude-sonnet-4-5-20250929", "messages": [{"role": "user", "content": "How many tokens?"}]}}'
```
