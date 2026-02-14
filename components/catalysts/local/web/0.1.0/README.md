# Web Catalyst

General-purpose web reader for CYFR agents. Fetches web pages, extracts readable text, discovers links, and reads page metadata — all through the standard catalyst interface.

No API keys or secrets required. Domain access is controlled by the host policy (`allowed_domains` in `config.json`).

## Operations

### `fetch` — Raw HTTP request

Low-level HTTP request for maximum flexibility.

**Params:**
- `url` (string, required) — Target URL
- `method` (string, default `"GET"`) — HTTP method
- `headers` (object, optional) — Custom headers (override defaults)
- `body` (string, optional) — Request body

**Returns:** `status_code`, `content_type`, `headers`, `body`, `truncated`

### `extract` — Fetch and extract readable text

Fetches a page and converts HTML to clean plain text using a built-in single-pass extractor.

**Params:**
- `url` (string, required) — Target URL
- `headers` (object, optional) — Custom headers

**Returns:** `title`, `text`, `word_count`, `url`

### `links` — Fetch and extract hyperlinks

Fetches a page and extracts all anchor links with resolved absolute URLs.

**Params:**
- `url` (string, required) — Target URL
- `headers` (object, optional) — Custom headers

**Returns:** Array of `{href, text}` objects

### `metadata` — Fetch and extract page metadata

Fetches a page and extracts title, description, canonical URL, and OpenGraph tags.

**Params:**
- `url` (string, required) — Target URL
- `headers` (object, optional) — Custom headers

**Returns:** `title`, `description`, `canonical`, `og`

## Setup

```bash
cyfr register components/catalysts/local/web/0.1.0/
cyfr policy set c:local.web:0.1.0 allowed_domains '["example.com", "*.wikipedia.org"]'
```

## Usage

### CLI

```bash
# Extract readable text from a page
cyfr run c:local.web:0.1.0 --input '{"operation": "extract", "params": {"url": "https://example.com"}}'

# Raw HTTP fetch
cyfr run c:local.web:0.1.0 --input '{"operation": "fetch", "params": {"url": "https://example.com"}}'

# Discover links on a page
cyfr run c:local.web:0.1.0 --input '{"operation": "links", "params": {"url": "https://example.com"}}'

# Read page metadata (title, description, OpenGraph)
cyfr run c:local.web:0.1.0 --input '{"operation": "metadata", "params": {"url": "https://example.com"}}'
```

### MCP

```bash
# Extract readable text
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
        "reference": {"registry": "catalyst:local.web:0.1.0"},
        "input": {
          "operation": "extract",
          "params": {"url": "https://example.com"}
        },
        "type": "catalyst"
      }
    }
  }'
```

## Build

```bash
cd src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/web_catalyst.wasm ../catalyst.wasm
```
