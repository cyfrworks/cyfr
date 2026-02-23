# List Models Formula

Aggregates available models from all AI provider catalysts (Claude, OpenAI, Gemini) into a single response.

## Prerequisites

This formula invokes three sub-catalysts. Set up each one with `cyfr setup`:

```bash
cyfr setup c:local.claude
cyfr setup c:local.openai
cyfr setup c:local.gemini
```

Each command reads the catalyst manifest and prompts for the API key, grants access, and applies the host policy.

| Catalyst | Secret | Domain |
|----------|--------|--------|
| Claude | `ANTHROPIC_API_KEY` | `api.anthropic.com` |
| OpenAI | `OPENAI_API_KEY` | `api.openai.com` |
| Gemini | `GEMINI_API_KEY` | `generativelanguage.googleapis.com` |

## Input Format

```json
{
  "providers": ["claude", "openai", "gemini"]
}
```

- `providers` (array of strings, optional) — Filter which providers to query. Valid values: `"claude"`, `"openai"`, `"gemini"`. Defaults to all three.

## Output Format

```json
{
  "models": {
    "claude": {"data": [...], "has_more": false},
    "openai": {"data": [...]},
    "gemini": {"models": [...]}
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
        "reference": {"registry": "formula:local.list-models:0.3.0"},
        "input": {},
        "type": "formula"
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
