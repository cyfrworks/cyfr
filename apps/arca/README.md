# Arca

**Layer**: Foundation
**Purpose**: Database, files, and cache with adapter-based storage for multi-tenant scalability.

## Overview

Arca provides unified storage abstraction with swappable adapters. All services use Arca for persistent storage, enabling seamless transition from local filesystem to cloud storage.

## Documentation

For detailed documentation, see [docs/services/arca.md](../../docs/services/arca.md).

## Key Features

- Hybrid database architecture (global + per-user)
- Adapter-based storage (Local, S3)
- Execution record storage for forensic replay
- OCI cache management
- Retention policies and cleanup

## MCP Tool

Arca provides the `storage` tool with actions: `list`, `read`, `write`, `delete`, `retention`.

## Storage Adapters

```elixir
# Sanctum (local filesystem)
config :arca, storage_adapter: Arca.Adapters.Local

# Managed/Enterprise (S3)
config :arca, storage_adapter: Arca.Adapters.S3
```

## Installation

```elixir
def deps do
  [
    {:arca, in_umbrella: true}
  ]
end
```

## Related Services

- [Opus](../opus) - Execution records
- [Sanctum](../sanctum) - Audit logs
- [Emissary](../emissary) - Request logs
