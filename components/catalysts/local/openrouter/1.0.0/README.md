# OpenRouter Catalyst

Unified access to 400+ AI models through a single API key. Supports chat completions (with streaming), embeddings, model listing, and account info.

## Setup

```bash
cyfr setup c:local.openrouter:1.0.0
```

Requires `OPENROUTER_API_KEY` from https://openrouter.ai/settings/keys

## Operations

| Operation | Description |
|-----------|-------------|
| `chat.completions.create` | Chat completion (set top-level `"stream": true` for streaming) |
| `models.list` | List all available models with pricing |
| `embeddings.create` | Text/image embeddings |
| `credits.get` | Check account balance |
| `key.info` | Check key rate limits and credits |

The `messages.create` operation is also accepted as an alias for `chat.completions.create` for agent formula compatibility.

## Usage

```bash
# Chat completion
cyfr run c:local.openrouter:1.0.0 --input '{"operation": "chat.completions.create", "params": {"model": "anthropic/claude-sonnet-4", "messages": [{"role": "user", "content": "Hello"}]}}'

# Streaming
cyfr run c:local.openrouter:1.0.0 --input '{"operation": "chat.completions.create", "stream": true, "params": {"model": "meta-llama/llama-3.1-8b-instruct:free", "messages": [{"role": "user", "content": "Count to 5"}]}}'

# List models
cyfr run c:local.openrouter:1.0.0 --input '{"operation": "models.list", "params": {}}'

# Check credits
cyfr run c:local.openrouter:1.0.0 --input '{"operation": "credits.get", "params": {}}'
```

## Optional Headers

Pass `referer` and `title` in params for OpenRouter analytics attribution:

```json
{
  "operation": "chat.completions.create",
  "params": {
    "model": "anthropic/claude-sonnet-4",
    "messages": [{"role": "user", "content": "Hello"}],
    "referer": "https://myapp.com",
    "title": "My App"
  }
}
```
