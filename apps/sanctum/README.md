# Sanctum

**Layer**: Foundation
**Purpose**: Identity (OIDC), Host Policy, Component Config, secrets management, and authorization.

## Overview

Sanctum is the identity and authorization layer. It delegates to proven systems (OIDC, Sigstore, Vault) rather than implementing auth from scratch.

## Documentation

For detailed documentation, see [docs/services/sanctum.md](../../docs/services/sanctum.md).

## Key Features

- OIDC authentication (GitHub, Google, corporate SSO)
- JWT session management
- Secrets management with component grants
- Host Policy enforcement
- Component Config injection
- Policy Lock (sudo) for critical operations
- API key management with tiered access

## MCP Tools

Sanctum provides these tools:
- `session` - Authentication and identity
- `permission` - Access control management
- `secret` - Secrets management
- `key` - API key management
- `audit` - Audit log access

## Installation

```elixir
def deps do
  [
    {:sanctum, in_umbrella: true}
  ]
end
```

## Related Services

- [Opus](../opus) - Policy enforcement
- [Emissary](../emissary) - Transport layer
- [Arca](../arca) - Audit logging
