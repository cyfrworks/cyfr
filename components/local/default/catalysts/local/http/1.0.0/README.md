# Web Catalyst

General-purpose web catalyst for CYFR agents and scheduled tasks. Read pages as clean Markdown, make raw HTTP requests, discover links, and extract metadata.

No API keys or secrets required. Domain access is controlled by host policy (`allowed_domains` in `setup.policy`).

## Operations

### `read` — Extract page content as Markdown

Fetches a URL via [Jina Reader](https://jina.ai/reader/) and returns clean Markdown with boilerplate removed (navigation, ads, sidebars). Jina handles JavaScript rendering and readability extraction.

**Params:**
- `url` (string, required) — Target URL
- `cache` (bool, default `true`) — Use Jina's cache (3600s TTL)

**Returns:** `title`, `content` (Markdown), `word_count`, `url`

**Note:** `read` requires the target URL to be publicly accessible (Jina's servers fetch it). For localhost or private URLs, use `fetch` instead.

### `fetch` — Raw HTTP request

Direct HTTP request for maximum flexibility. Works with any URL including localhost and private networks (subject to host policy).

**Params:**
- `url` (string, required) — Target URL
- `method` (string, default `"GET"`) — HTTP method (GET or POST)
- `headers` (object, optional) — Custom headers
- `body` (string, optional) — Request body

**Returns:** `status_code`, `content_type`, `headers`, `body`, `truncated`

### `links` — Discover hyperlinks

Fetches a page directly and extracts all anchor links with resolved absolute URLs.

**Params:**
- `url` (string, required) — Target URL
- `headers` (object, optional) — Custom headers
- `max` (integer, default `500`) — Maximum links to return

**Returns:** Array of `{href, text}` objects, `count`

### `metadata` — Page metadata

Fetches a page directly and extracts title, description, canonical URL, and OpenGraph tags.

**Params:**
- `url` (string, required) — Target URL
- `headers` (object, optional) — Custom headers

**Returns:** `title`, `description`, `canonical`, `og`

### `head` — Check URL without downloading

Issues an HTTP HEAD request. Returns status and headers without downloading the body.

**Params:**
- `url` (string, required) — Target URL
- `headers` (object, optional) — Custom headers

**Returns:** `status_code`, `content_type`, `content_length`, `headers`

## Setup

```bash
cyfr setup c:local.web
```

| What | Value |
|------|-------|
| Secrets | None |
| Domains | `*` (all) |

## Usage

```bash
# Read page as Markdown (via Jina Reader)
cyfr run c:local.web --input '{"operation": "read", "params": {"url": "https://example.com"}}'

# Raw HTTP fetch
cyfr run c:local.web --input '{"operation": "fetch", "params": {"url": "https://httpbin.org/get"}}'

# Discover links (max 10)
cyfr run c:local.web --input '{"operation": "links", "params": {"url": "https://example.com", "max": 10}}'

# Page metadata
cyfr run c:local.web --input '{"operation": "metadata", "params": {"url": "https://example.com"}}'

# HEAD check
cyfr run c:local.web --input '{"operation": "head", "params": {"url": "https://example.com"}}'
```

## Build

```bash
cyfr build compile catalyst:local.web:0.3.0
```
