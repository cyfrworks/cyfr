# Grok Catalyst

xAI Grok API — chat, vision, image generation, and embeddings.

## Setup

```bash
cyfr setup c:local.grok:1.0.0
```

Requires `XAI_API_KEY` from https://console.x.ai

## Operations

| Operation | Description |
|-----------|-------------|
| `chat.completions.create` | Chat completion (set top-level `"stream": true` for streaming) |
| `models.list` | List available models |
| `embeddings.create` | Text embeddings |
| `images.generate` | Image generation |
| `images.edit` | Edit images with natural language |

The `messages.create` operation is also accepted as an alias for `chat.completions.create` for agent formula compatibility.

## Models

- `grok-4` / `grok-4-0709` — flagship (256K context)
- `grok-4-1-fast-reasoning` — fast reasoning + vision (2M context)
- `grok-3` / `grok-3-mini` — previous generation (131K context)
- `grok-2-vision-latest` — vision-capable
- `grok-imagine-image` / `grok-2-image` — image generation
- `grok-code-fast-1` — code-optimized (256K context)

## Usage

```bash
# Chat completion
cyfr run c:local.grok:1.0.0 --input '{"operation": "chat.completions.create", "params": {"model": "grok-4-1-fast-reasoning", "messages": [{"role": "user", "content": "Hello"}]}}'

# Streaming
cyfr run c:local.grok:1.0.0 --input '{"operation": "chat.completions.create", "stream": true, "params": {"model": "grok-4-1-fast-reasoning", "messages": [{"role": "user", "content": "Count to 5"}]}}'

# Generate image
cyfr run c:local.grok:1.0.0 --input '{"operation": "images.generate", "params": {"model": "grok-imagine-image", "prompt": "A cat wearing a hat"}}'

# List models
cyfr run c:local.grok:1.0.0 --input '{"operation": "models.list", "params": {}}'
```
