# Agent Formula

Multi-provider conversational agent with dynamic component discovery.

Accepts a generic chat input (provider, model, prompt/messages, system prompt) and dynamically finds the appropriate provider catalyst via MCP `component.search`, maps the input to the provider-specific format, and returns a unified response.

## Supported Providers

- **Claude** — Anthropic Messages API (`messages.stream` / `messages.create`)
- **OpenAI** — Chat Completions API (`chat.completions.create`)
- **Gemini** — Google Generative AI (`content.stream` / `content.generate`)

Unknown providers are attempted with a generic `chat.create` operation.

## Setup

```bash
# Register all local components
cyfr register

# Set up the provider catalysts you want to use
cyfr setup c:local.claude
cyfr setup c:local.openai
cyfr setup c:local.gemini

# Set MCP policy (formula needs component.search permission)
cyfr policy set f:local.agent allowed_tools '["component.search"]'
```

## Input

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `provider` | string | yes | Catalyst name (`claude`, `openai`, `gemini`) |
| `model` | string | yes | Model identifier |
| `prompt` | string | no | Single-turn prompt |
| `system` | string | no | System prompt |
| `messages` | array | no | Full conversation history (overrides `prompt`) |
| `stream` | bool | no | Enable streaming (default: `true`) |
| `params` | object | no | Extra provider-specific parameters |

## Output

| Field | Type | Description |
|-------|------|-------------|
| `provider` | string | Provider name |
| `model` | string | Model used |
| `content` | string | Response text |
| `stream` | bool | Whether streaming was used |
| `component_ref` | string | Registry reference for the catalyst used |

## Usage

### CLI

```bash
cyfr run f:local.agent --input '{
  "provider": "claude",
  "model": "claude-sonnet-4-5-20250514",
  "prompt": "Hello, how are you?",
  "system": "You are a helpful assistant."
}'
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
        "reference": {"registry": "formula:local.agent:0.3.0"},
        "input": {
          "provider": "claude",
          "model": "claude-sonnet-4-5-20250514",
          "prompt": "Hello",
          "system": "Be concise"
        },
        "type": "formula"
      }
    }
  }'
```

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/agent.wasm ../formula.wasm
```
