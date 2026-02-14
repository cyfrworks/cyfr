# List Models Formula

Aggregates available models from all AI provider catalysts (Claude, OpenAI, Gemini) into a single response.

## Prerequisites

This formula invokes three sub-catalysts. Each must be registered, granted its API key, and given a domain policy:

| Catalyst | Ref | Secret | Allowed Domain |
|----------|-----|--------|----------------|
| Claude | `c:local.claude:0.1.0` | `ANTHROPIC_API_KEY` | `api.anthropic.com` |
| OpenAI | `c:local.openai:0.1.0` | `OPENAI_API_KEY` | `api.openai.com` |
| Gemini | `c:local.gemini:0.1.0` | `GEMINI_API_KEY` | `generativelanguage.googleapis.com` |

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

## Setup

```bash
# Register the formula
cyfr register components/formulas/local/list-models/0.1.0/

# Register and configure each sub-catalyst (if not already done)
cyfr register components/catalysts/local/claude/0.1.0/
cyfr secret set ANTHROPIC_API_KEY=sk-ant-...
cyfr secret grant c:local.claude:0.1.0 ANTHROPIC_API_KEY
cyfr policy set c:local.claude:0.1.0 allowed_domains '["api.anthropic.com"]'

cyfr register components/catalysts/local/openai/0.1.0/
cyfr secret set OPENAI_API_KEY=sk-...
cyfr secret grant c:local.openai:0.1.0 OPENAI_API_KEY
cyfr policy set c:local.openai:0.1.0 allowed_domains '["api.openai.com"]'

cyfr register components/catalysts/local/gemini/0.1.0/
cyfr secret set GEMINI_API_KEY=<your-key>
cyfr secret grant c:local.gemini:0.1.0 GEMINI_API_KEY
cyfr policy set c:local.gemini:0.1.0 allowed_domains '["generativelanguage.googleapis.com"]'
```

## Usage

### CLI

```bash
# Query all providers (version optional — defaults to latest)
cyfr run f:local.list-models --input '{}'

# Query a single provider
cyfr run f:local.list-models --input '{"providers": ["openai"]}'

# Query a subset of providers
cyfr run f:local.list-models --input '{"providers": ["claude", "gemini"]}'

# Specific version
cyfr run f:local.list-models:0.1.0 --input '{}'
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
        "reference": {"registry": "formula:local.list-models:0.1.0"},
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
