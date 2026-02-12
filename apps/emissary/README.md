# Emissary

**Layer**: Foundation
**Purpose**: Unified MCP transport (HTTP, SSE, Internal) with session management and request logging.

## Overview

Emissary provides unified MCP transport. It handles session management, request routing, message buffering, and coordinates tool registration from all services.

## Documentation

For detailed documentation, see [docs/services/emissary.md](../../docs/services/emissary.md).

## Key Features

- HTTP/SSE transport (no Stdio for security)
- Session management with 5-minute message buffering
- Protocol version negotiation
- Tool registration from all services
- Request/response logging with correlation IDs
- Webhook notifications

## Running

```bash
# Run setup and start Phoenix endpoint
mix setup
mix phx.server

# Or inside IEx
iex -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) from your browser.

## MCP Tools

Emissary coordinates all MCP tools:
- `execution` (Opus)
- `build` (Locus)
- `component` (Compendium)
- `session`, `permission`, `secret`, `key`, `audit` (Sanctum)
- `storage` (Arca)
- `system` (Emissary)

## Related Services

- [Opus](../opus) - Execution engine
- [Sanctum](../sanctum) - Auth & authorization
- [Arca](../arca) - Request logging
