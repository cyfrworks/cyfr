# Agent Formula

Multi-provider conversational agent with dynamic component discovery.

Accepts a generic chat input (provider, model, prompt/messages, system prompt) and dynamically finds the appropriate provider catalyst via MCP `component.search`, maps the input to the provider-specific format, and returns a unified response.

## Supported Providers

- **Claude** — Anthropic Messages API (`messages.stream` / `messages.create`)
- **OpenAI** — Chat Completions API (`chat.completions.create`)
- **Gemini** — Google Generative AI (`content.stream` / `content.generate`)

Unknown providers are attempted with a generic `chat.create` operation.

## Usage

```bash
# Register the formula
cyfr register components/formulas/local/agent/0.1.0/

# Set MCP policy (formula needs component.search permission)
cyfr policy set f:local.agent:0.1.0 allowed_tools '["component.search"]'

# Run
cyfr run f:local.agent:0.1.0 --input '{
  "provider": "claude",
  "model": "claude-sonnet-4-5-20250514",
  "prompt": "Hello, how are you?",
  "system": "You are a helpful assistant."
}'
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

## Building

```bash
cd components/formulas/local/agent/0.1.0/src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/agent.wasm ../formula.wasm
```
