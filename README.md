# CYFR

Sandboxed WASM runtime for AI agents.

## What is CYFR?

**CYFR** is a sandboxed runtime and governance layer for AI agents. Agents "live" in a sandbox and can discover, build, and execute tools via [MCP](https://modelcontextprotocol.io/) or components with complete capability control and observability. Think of it as a workshop with guardrails: agents can work, but the security boundary is physical, not heuristic.

Components come in three types:

- **Reagent** — pure compute, no I/O (transforms, validation, scoring)
- **Catalyst** — I/O with the outside world (HTTP APIs, databases, secrets)
- **Formula** — compositions that chain Reagents, Catalysts and other Formulas into workflows

## Quick Start

```bash
# Install via Homebrew
brew tap cyfrworks/cyfr
brew install --cask cyfr

# Initialize a project in the current directory
cyfr init

# Start the server
cyfr up

# Authenticate
cyfr login
cyfr whoami
```

`cyfr init` scaffolds a project with a `docker-compose.yml`, pulls the CYFR server image, and sets up the local directory structure. `cyfr up` starts the server container.

## Your First Component

### Pull and run a pre-built component

```bash
# Pull a first-party Reagent from the registry
cyfr pull cyfr.run/reagents/json-transform:1.0

# Run it
cyfr run cyfr.json-transform:1.0.0
```

### Configure a Catalyst with secrets and policy

Catalysts talk to external APIs — they need a **policy** (which domains they can reach) and **secrets** (API keys):

```bash
# Pull the Stripe Catalyst
cyfr pull cyfr.run/catalysts/stripe:1.0

# Set the Host Policy — which domains it's allowed to call
cyfr policy set cyfr.stripe:1.0.0 allowed_domains '["api.stripe.com"]'

# Store a secret and grant the component access
cyfr secret set STRIPE_API_KEY=sk_live_...
cyfr secret grant cyfr.stripe:1.0.0 STRIPE_API_KEY

# Run it
cyfr run cyfr.stripe:1.0.0
```

### Develop a local component

Build your own WASM component and place it in the canonical layout:

```bash
# Build (using your language's WASM toolchain)
cd components/reagents/local/my-reagent/0.1.0/src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/my_reagent.wasm ../reagent.wasm

# Register it in Compendium for discovery
cyfr register components/reagents/local/my-reagent/0.1.0/

# Run it
cyfr run local.my-reagent:0.1.0

# Iterate, rebuild, re-register, re-run...

# Publish when ready (signs with Sigstore)
cyfr publish local.my-reagent --version 1.0.0
```

> See [component-guide.md](component-guide.md) for the full guide on building Reagents, Catalysts, and Formulas.

## Project Layout

After `cyfr init`, your project looks like this:

```
your-project/
├── wit/              # WIT interface definitions — copy into your components
│   ├── reagent/
│   ├── catalyst/
│   └── formula/
├── components/       # WASM components (type/namespace/name/version/)
│   ├── catalysts/
│   ├── reagents/
│   └── formulas/
└── data/
    └── cyfr.db       # Secrets, policies, execution records (.gitignored)
```

## CLI Reference

Every `cyfr` CLI command maps to an MCP tool call. AI agents use the exact same interface programmatically.

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a new CYFR project |
| `cyfr up` / `cyfr down` | Start / stop the server |
| `cyfr login` / `cyfr logout` / `cyfr whoami` | Session management |
| `cyfr run <ref>` | Execute a component |
| `cyfr search <query>` | Search the component registry |
| `cyfr inspect <ref>` | Show component details and policy |
| `cyfr pull <ref>` | Fetch a component from the registry |
| `cyfr register <dir>` | Register a local component |
| `cyfr publish <ref>` | Sign and push to the registry |
| `cyfr secret set/get/list/delete` | Manage secrets |
| `cyfr secret grant/revoke` | Grant or revoke component access to secrets |
| `cyfr policy set/show/list/reset` | Manage Host Policies |
| `cyfr config set/show` | Component config overrides |
| `cyfr status` | Health check |
| `cyfr context list/set/add` | Manage multiple server instances |

> Full CLI reference: [docs/services/codex.md](docs/services/codex.md)

## Documentation

| Document | Description |
|----------|-------------|
| [Component Guide](component-guide.md) | Practical guide to building WASM components |
| [Overview](docs/overview.md) | Philosophy, editions, deployment |
| [Architecture](docs/ARCHITECTURE.md) | Implementation patterns and design |
| [Security Model](docs/security-model.md) | Auth, policy, secrets, trust, signing |
| [CLI Reference](docs/services/codex.md) | Full `cyfr` command reference |
| [Observability](docs/observability.md) | Telemetry, logging, forensic replay |

## Verifying Releases

All release binaries are signed and attested. You can verify authenticity at three levels:

```bash
# GitHub Attestation (easiest — just needs gh CLI)
gh attestation verify cyfr_*.tar.gz --owner cyfrworks

# Checksum verification (no tools needed)
sha256sum --check --ignore-missing checksums.txt

# Full Sigstore verification (maximum rigor)
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/cyfrworks/cyfr/" \
  checksums.txt
```

## Contributing

CYFR is an Elixir umbrella application with a Go CLI.

### Prerequisites

- Elixir ~> 1.19 and Erlang/OTP
- Rust (for wasmex NIF compilation)
- Go 1.21+ (for CLI)

### Setup

```bash
git clone https://github.com/cyfrworks/cyfr
cd cyfr
mix setup
mix phx.server
```

### Building the CLI

```bash
cd apps/codex
make build    # produces ./cyfr binary
make test     # run Go tests
make install  # install to $GOPATH/bin
```

### Running Tests

```bash
mix test                      # all tests
mix test apps/opus/test       # specific service
```

## License

CYFR uses a dual-license model:

- **Base platform** — [Apache License 2.0](LICENSE). Covers all code except `apps/sanctum_arx/`.
- **Enterprise features** (`apps/sanctum_arx/`) — [FSL-1.1-Apache-2.0](apps/sanctum_arx/LICENSE) (Functional Source License). Converts to Apache 2.0 two years after each release.

See the respective LICENSE files for full terms.
