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

# Initialize a project
cyfr init

# Start the server
cyfr up

# Authenticate
cyfr login
cyfr whoami
```

`cyfr init` scaffolds everything you need: `docker-compose.yml`, config files, example components, WIT interface definitions, the [integration guide](integration-guide.md), and the [component guide](component-guide.md). `cyfr up` starts the server.

## Try the Included Components

`cyfr init` ships with ready-to-use example components. Pick any AI provider you have an API key for:

| Component | Type | Description |
|-----------|------|-------------|
| `c:local.claude:0.1.0` | Catalyst | Anthropic Claude API — messages, streaming, models |
| `c:local.openai:0.1.0` | Catalyst | OpenAI API — chat completions, embeddings, images, audio |
| `c:local.gemini:0.1.0` | Catalyst | Google Gemini API — text generation, embeddings |
| `f:local.list-models:0.1.0` | Formula | Aggregates models from all configured providers |

### 1. Register a component

```bash
cyfr register components/catalysts/local/claude/0.1.0/
```

### 2. Store your API key and grant access

```bash
cyfr secret set ANTHROPIC_API_KEY=sk-ant-...
cyfr secret grant c:local.claude:0.1.0 ANTHROPIC_API_KEY
```

### 3. Set the host policy

```bash
cyfr policy set c:local.claude:0.1.0 allowed_domains '["api.anthropic.com"]'
```

### 4. Run it

```bash
cyfr run c local.claude:0.1.0
```

The same pattern works for OpenAI and Gemini — just swap the component ref, secret name, and allowed domain:

```bash
# OpenAI
cyfr register components/catalysts/local/openai/0.1.0/
cyfr secret set OPENAI_API_KEY=sk-...
cyfr secret grant c:local.openai:0.1.0 OPENAI_API_KEY
cyfr policy set c:local.openai:0.1.0 allowed_domains '["api.openai.com"]'
cyfr run c local.openai:0.1.0

# Gemini
cyfr register components/catalysts/local/gemini/0.1.0/
cyfr secret set GEMINI_API_KEY=AIza...
cyfr secret grant c:local.gemini:0.1.0 GEMINI_API_KEY
cyfr policy set c:local.gemini:0.1.0 allowed_domains '["generativelanguage.googleapis.com"]'
cyfr run c local.gemini:0.1.0
```

### 5. Run the Formula

Once you've configured at least one provider, the `list-models` Formula can aggregate models across all of them:

```bash
cyfr register components/formulas/local/list-models/0.1.0/
cyfr run f local.list-models:0.1.0
```

## Pull from the Registry

Beyond the included examples, you can pull pre-built components from the registry:

```bash
cyfr pull r:cyfr.json-transform:1.0.0
cyfr run r:cyfr.json-transform:1.0.0
```

## Build Your Own Component

Build a WASM component and place it in the canonical layout:

```bash
# Build (using your language's WASM toolchain)
cd components/reagents/local/my-reagent/0.1.0/src
cargo component build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/my_reagent.wasm ../reagent.wasm

# Register, run, iterate
cyfr register components/reagents/local/my-reagent/0.1.0/
cyfr run r:local.my-reagent:0.1.0

# Publish when ready (signs with Sigstore)
cyfr publish r:local.my-reagent:1.0.0
```

> See [component-guide.md](component-guide.md) for the full guide on building Reagents, Catalysts, and Formulas.

## Project Layout

After `cyfr init`, your project looks like this:

```
your-project/
├── integration-guide.md # How to use CYFR as your app backend
├── component-guide.md  # Full guide to building WASM components
├── docker-compose.yml
├── cyfr.yaml
├── .env                # Secret key and config (do not commit)
├── wit/                # WIT interface definitions — copy into your components
│   ├── reagent/
│   ├── catalyst/
│   └── formula/
├── components/         # WASM components (type/namespace/name/version/)
│   ├── catalysts/
│   │   └── local/      # Example catalysts: claude, openai, gemini
│   ├── reagents/
│   │   └── local/
│   └── formulas/
│       └── local/      # Example formula: list-models
└── data/
    └── cyfr.db         # Secrets, policies, execution records (.gitignored)
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

> Run `cyfr --help` or `cyfr <command> --help` for full usage details.

## Documentation

| Document | Description |
|----------|-------------|
| [Integration Guide](integration-guide.md) | How to use CYFR as your application backend |
| [Component Guide](component-guide.md) | Practical guide to building WASM components |

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
