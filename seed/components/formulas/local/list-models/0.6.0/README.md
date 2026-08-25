# List Models Formula

Aggregates available models from all AI provider catalysts (Claude, OpenAI, Gemini, Grok, OpenRouter) into a single response.

## Prerequisites

This formula invokes five sub-catalysts. Grant each one a profile with
`cyfr profile grant` (or from the console's consent sheet):

```bash
cyfr profile grant c:local.claude
cyfr profile grant c:local.openai
cyfr profile grant c:local.gemini
cyfr profile grant c:local.grok
cyfr profile grant c:local.openrouter
```

Each grant walks the catalyst's declared needs, binds the API-key Connection,
and mints the consent the component runs under.

| Catalyst | Connection field | Domain |
|----------|--------|--------|
| Claude | `ANTHROPIC_API_KEY` | `api.anthropic.com` |
| OpenAI | `OPENAI_API_KEY` | `api.openai.com` |
| Gemini | `GEMINI_API_KEY` | `generativelanguage.googleapis.com` |
| Grok | `GROK_API_KEY` | `api.x.ai` |
| OpenRouter | `OPENROUTER_API_KEY` | `openrouter.ai` |

## Input Format

```json
{
  "providers": ["claude", "openai", "gemini", "grok", "openrouter"]
}
```

- `providers` (array of strings, optional) — Filter which providers to query. Valid values: `"claude"`, `"openai"`, `"gemini"`, `"grok"`, `"openrouter"`. Defaults to all five.

## Output Format

```json
{
  "models": {
    "claude": {"data": [...], "has_more": false},
    "openai": {"data": [...]},
    "gemini": {"models": [...]},
    "grok": {"data": [...]},
    "openrouter": {"data": [...]}
  },
  "errors": {}
}
```

- `models` (object) — Map of provider name to their `models.list` response data
- `errors` (object) — Map of provider name to error message (empty if all succeeded)

## Usage

### CLI

```bash
# Query all providers (version optional — defaults to latest)
cyfr run f:local.list-models --input '{}'

# Query a single provider
cyfr run f:local.list-models --input '{"providers": ["openai"]}'

# Query a subset of providers
cyfr run f:local.list-models --input '{"providers": ["claude", "gemini"]}'
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
        "reference": "formula:local.list-models:0.4.0",
        "input": {}
      }
    }
  }'
```

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/list_models.wasm ../formula.wasm
```
