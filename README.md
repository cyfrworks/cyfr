# CYFR

Sandboxed WASM runtime for AI agents.

## What is CYFR?

**CYFR** is a sandboxed runtime and governance layer for AI agents. Agents "live" in a sandbox and can discover, build, and execute tools via [MCP](https://modelcontextprotocol.io/) or components with complete capability control and observability. Think of it as a workshop with guardrails: agents can work, but the security boundary is physical, not heuristic.

Components come in three types:

- **Reagent** — pure compute, no I/O (transforms, validation, scoring)
- **Catalyst** — I/O with the outside world (HTTP APIs, databases, secrets)
- **Formula** — compositions that chain Reagents, Catalysts and other Formulas into workflows

Formulas support **execution event streaming** — long-running formulas (like agentic loops) can push intermediate events (`emit`) so that frontends see progressive updates in real-time via SSE or PubSub.

## Quick Start

```bash
# Install via shell script (Linux, macOS, WSL)
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Or via Homebrew (macOS)
brew tap cyfrworks/cyfr
brew install --cask cyfr

# Initialize a project
cyfr init

# Start the server
cyfr up

# Open the dashboard (optional)
open http://localhost:4001

# Authenticate
cyfr login
cyfr whoami
```

## Deploy to a Server

If you've already run `cyfr init` during development, your repo has everything needed. On your server, just install the CLI and start the server.

```bash
# Install cyfr
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Clone your project and start
git clone <your-repo>
cd your-project
cyfr up
```

`cyfr init` scaffolds everything you need: `docker-compose.yml`, config files, example components, WIT interface definitions, the [integration guide](integration-guide.md), and the [component guide](component-guide.md). `cyfr up` starts the server.

## Try the Registry Components

Pull ready-to-use components from the registry. Pick any AI provider you have an API key for:

| Component | Type | Description |
|-----------|------|-------------|
| `c:moonmoon69.claude:0.2.0` | Catalyst | Anthropic Claude API — messages, streaming, models |
| `c:moonmoon69.openai:0.2.0` | Catalyst | OpenAI API — chat completions, embeddings, images, audio |
| `c:moonmoon69.gemini:0.2.0` | Catalyst | Google Gemini API — text generation, embeddings |
| `c:moonmoon69.web:0.2.0` | Catalyst | Web reader — fetch pages, extract text, discover links |
| `f:moonmoon69.list-models:0.3.0` | Formula | Aggregates models from all configured providers |

### 1. Pull a component

```bash
cyfr pull c:moonmoon69.claude:0.2.0
```

Dependencies declared in a component's manifest are automatically pulled.

### 2. Set up a component

```bash
cyfr setup c:moonmoon69.claude:0.2.0
```

This walks you through secrets, grants, and policy in one step. (You can still use `cyfr secret set/grant` and `cyfr policy set` individually.)

### 3. Run it

```bash
cyfr run c:moonmoon69.claude:0.2.0
```

The same pattern works for OpenAI and Gemini:

```bash
cyfr pull c:moonmoon69.openai:0.2.0
cyfr setup c:moonmoon69.openai:0.2.0
cyfr run c:moonmoon69.openai:0.2.0

cyfr pull c:moonmoon69.gemini:0.2.0
cyfr setup c:moonmoon69.gemini:0.2.0
cyfr run c:moonmoon69.gemini:0.2.0
```

### 4. Run the Formula

Once you've configured at least one provider, the `list-models` Formula can aggregate models across all of them:

```bash
cyfr pull f:moonmoon69.list-models:0.3.0
cyfr run f:moonmoon69.list-models:0.3.0
```

### Search the Registry

Discover more components:

```bash
cyfr search <query>
```

## Build Your Own Component

Scaffold, compile, and run a component in three commands:

```bash
# Scaffold a new component (creates directory, manifest, WIT files, starter Rust source)
cyfr new catalyst my-api
# Also: cyfr new reagent my-transform, cyfr new formula my-workflow

# Compile by reference (reads source, compiles to WASM, saves binary, auto-registers)
cyfr build compile catalyst:local.my-api:0.1.0

# Run it
cyfr run c:local.my-api:0.1.0

# Publish when ready (signs with Sigstore)
cyfr publish c:local.my-api:1.0.0
```

The development loop is: **edit source → `cyfr build compile <ref>` → `cyfr run <ref>`**. Each compile saves the `.wasm` binary and re-registers automatically.

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

## Prism Dashboard

CYFR includes **Prism**, a web-based dashboard available at `http://localhost:4001` when the server is running. Prism provides a GUI for:

- Viewing registered components and their policies
- Monitoring executions in real-time
- Managing secrets and configuration
- Authenticating via browser (sessions are shared with the CLI automatically)

```bash
# Start the server (Prism starts alongside it)
cyfr up

# Open the dashboard
open http://localhost:4001
```

> Prism is optional — everything it does is also available via the CLI and MCP tools.

## CLI Reference

Every `cyfr` CLI command maps to an MCP tool call. AI agents use the exact same interface programmatically. Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a new CYFR project (safe to re-run; use `--force` to overwrite config) |
| `cyfr up` / `cyfr down` | Start / stop the server |
| `cyfr upgrade` | Upgrade the cyfr CLI and Docker image (system-wide) |
| `cyfr update` | Update project scaffold files — docs, WIT definitions (project-local) |

### Identity

| Command | Description |
|---------|-------------|
| `cyfr login` | Authenticate via Device Flow |
| `cyfr logout` | End current session |
| `cyfr whoami` | Show current identity |
| `cyfr status` | Check system health (includes CLI version) |

### Components

| Command | Description |
|---------|-------------|
| `cyfr new <type> <name>` | Scaffold a new component project |
| `cyfr build compile <ref>` | Compile a component by reference (saves binary, auto-registers) |
| `cyfr build toolchains` | List available build toolchains |
| `cyfr search <query>` | Search the component registry |
| `cyfr list` | List installed components |
| `cyfr inspect <ref>` | Show component details and policy `[i]` |
| `cyfr pull <ref>` | Fetch a component from the registry |
| `cyfr register` | Scan and register all local components |
| `cyfr setup <ref>` | Configure secrets, grants, and policy for a component `[i]` |
| `cyfr run <ref>` | Execute a component `[i]` |
| `cyfr remove <ref>` | Remove a component `[i]` |
| `cyfr publish <ref>` | Sign and push to the registry |

### Security

| Command | Description |
|---------|-------------|
| `cyfr secret set/get/list/delete` | Manage encrypted secrets |
| `cyfr secret grant/revoke` | Grant or revoke component access to secrets |
| `cyfr policy set/show/list/reset` | Manage Host Policies |
| `cyfr key create/list/get/revoke/rotate` | Manage API keys |
| `cyfr permission get/set/list` | Manage RBAC permissions |

### Administration

| Command | Description |
|---------|-------------|
| `cyfr audit list/export` | View and export audit logs |
| `cyfr storage list/read/write/delete/retention` | Manage sandboxed file storage |
| `cyfr guide list/get/readme` | Access docs and component READMEs |
| `cyfr registry login/discover` | OCI registry operations |
| `cyfr notify` | Send a webhook notification |
| `cyfr context list/set/add` | Manage server connections (local only) |
| `cyfr call <tool> [json-args]` | Invoke any MCP tool directly |

> Run `cyfr --help` or `cyfr <command> --help` for full usage details.

### Interactive Mode

Commands marked `[i]` support interactive selection — run them without arguments to get a picker. For example, `cyfr run` with no ref will prompt you to choose from installed components.

Use `--no-interactive` or set `CYFR_NO_INTERACTIVE=1` to disable interactive prompts (useful for scripts and CI).

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
