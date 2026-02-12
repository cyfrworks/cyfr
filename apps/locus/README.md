# Locus

**Layer**: Domain
**Purpose**: Compile source code to WASM draft artifacts with Sigstore signing at promotion time.

## Overview

Locus compiles source code to draft artifacts. Signing happens at promotion time (via Compendium).

## Documentation

For detailed documentation, see [docs/services/locus.md](../../docs/services/locus.md).

## Key Features

- Compile source to WASM binary
- Draft artifacts (ephemeral, in-memory)
- Sigstore integration for signing
- Support for Rust, Go (TinyGo), Python, JavaScript
- Reproducible builds

## MCP Tool

Locus provides the `build` tool with actions: `create`, `cancel`, `status`, `list`, `targets`.

## Build Targets

| Type | Capabilities | Languages |
|------|--------------|-----------|
| `catalyst` | HTTP, sockets, secrets | Rust, Go, Python, JS |
| `reagent` | None (pure compute) | Rust, Go, Python, JS |
| `formula` | Composition | Rust, Go, Python, JS |

## Installation

```elixir
def deps do
  [
    {:locus, in_umbrella: true}
  ]
end
```

## Related Services

- [Compendium](../compendium) - Component publishing
- [Opus](../opus) - Draft execution
- [Sanctum](../sanctum) - Signing credentials
