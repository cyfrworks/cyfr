# Opus

**Layer**: Domain
**Purpose**: Sandboxed WASM execution engine with signature verification and capability-based security.

## Overview

Opus is the WASM execution kernel. It pulls artifacts, verifies signatures, and executes in sandboxed environments. All execution is WASM—no native binaries.

## Documentation

For detailed documentation, see [docs/services/opus.md](../../docs/services/opus.md).

## Key Features

- Pulls WASM from OCI registries or draft cache
- Verifies Sigstore signature for published artifacts
- Verifies ownership for draft artifacts
- Makes NO network calls during execution
- Epoch-based interruption for infinite loop protection
- Forensic replay capability

## MCP Tool

Opus provides the `execution` tool with actions: `run`, `list`, `logs`, `cancel`.

## Installation

```elixir
def deps do
  [
    {:opus, in_umbrella: true}
  ]
end
```

## Related Services

- [Sanctum](../sanctum) - Policy enforcement
- [Arca](../arca) - Execution record storage
- [Compendium](../compendium) - Component registry
