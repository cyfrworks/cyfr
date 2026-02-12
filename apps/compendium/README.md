# Compendium

**Layer**: Domain
**Purpose**: Component registry, discovery, and OCI artifact management.

## Overview

Compendium serves as an index layer for component discovery and as a managed registry (`registry.cyfr.run`) for marketplace/monetization.

## Documentation

For detailed documentation, see [docs/services/compendium.md](../../docs/services/compendium.md).

## Key Features

- Component search and discovery
- OCI artifact structure
- Component manifests (`cyfr-manifest.json`)
- Source & licensing options
- Trust model with signature verification
- First-party component library

## MCP Tool

Compendium provides the `component` tool with actions: `search`, `inspect`, `pull`, `publish`, `resolve`.

## Component Types

| Type | OCI Media Type | Role |
|------|----------------|------|
| Catalyst | `application/vnd.cyfr.catalyst.v1+wasm` | External APIs |
| Reagent | `application/vnd.cyfr.reagent.v1+wasm` | Pure computation |
| Formula | `application/vnd.cyfr.formula.v1+wasm` | Workflow orchestration |

## Installation

```elixir
def deps do
  [
    {:compendium, in_umbrella: true}
  ]
end
```

## Related Services

- [Locus](../locus) - Build service
- [Opus](../opus) - Execution engine
- [Sanctum](../sanctum) - Trust verification
