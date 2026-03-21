<p align="center">
  <img src="apps/cyfr/priv/static/images/logo.jpg" alt="CYFR" width="200" />
</p>

# CYFR — Native Interfaces for AI Agents

The governed runtime for recurring agent work.

## What is CYFR?

**CYFR** is the execution and governance layer for agents that work through native interfaces, not brittle human UIs. Agents discover, build, and execute tools via [MCP](https://modelcontextprotocol.io/) inside a sandboxed WASM runtime with complete capability control and observability.

Components are the building blocks — sandboxed, composable units that agents use as native interfaces:

- **Reagent** — pure compute, no I/O (transforms, validation, scoring)
- **Catalyst** — I/O with the outside world (HTTP APIs, databases, secrets)
- **Formula** — compositions that chain Reagents, Catalysts and other Formulas into workflows

Formulas support **execution event streaming** — long-running formulas (like agentic loops) push intermediate events (`emit`) so frontends see progressive updates in real-time via SSE or PubSub.

## Quick Start

```bash
# Install via shell script (Linux, macOS, WSL)
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Or via Homebrew (macOS)
brew tap cyfrworks/cyfr
brew install cyfr

# Initialize a project
cyfr init

# Start the server
cyfr up

# Open the dashboard
open http://localhost:4001

# Authenticate
cyfr login
cyfr whoami
```

## Porta Desktop App

**Porta** (A.Q.U.A.) is a desktop GUI for macOS and Linux that manages the Dockerized CYFR server. It provides a system tray with start/stop/restart, automatic update notifications, and an MCP gateway for connecting external tool providers.

Download from [GitHub Releases](https://github.com/cyfrworks/cyfr/releases) (look for `porta-v*` tags) or build from source:

```bash
cd apps/porta && cargo tauri build
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

## Component References

Components use the format `type:publisher.name:version`. The type can be a shorthand (`c:`, `r:`, `f:`) or full name (`catalyst:`, `reagent:`, `formula:`).

```bash
# Full reference
cyfr run c:moonmoon69.claude:1.0.0

# Versionless — resolves to latest installed version
cyfr run c:moonmoon69.claude

# Dependencies are auto-pulled when you pull a component
cyfr pull f:moonmoon69.list-models:0.5.0
```

## Registry Components

Pull ready-to-use components from the registry:

| Component | Type | Description |
|-----------|------|-------------|
| `c:moonmoon69.claude:1.0.0` | Catalyst | Anthropic Claude API — messages, streaming, models |
| `c:moonmoon69.openai:1.0.0` | Catalyst | OpenAI API — chat completions, embeddings, images, audio |
| `c:moonmoon69.gemini:1.0.0` | Catalyst | Google Gemini API — text generation, embeddings |
| `c:moonmoon69.grok:1.0.0` | Catalyst | xAI Grok API — chat, vision, image generation, embeddings |
| `c:moonmoon69.openrouter:1.0.0` | Catalyst | OpenRouter API — unified access to 400+ AI models |
| `c:moonmoon69.supabase:0.2.0` | Catalyst | Supabase SDK — database, auth, storage, edge functions |
| `c:moonmoon69.web:0.2.0` | Catalyst | Web reader — fetch pages, extract text, discover links |
| `f:moonmoon69.list-models:0.5.0` | Formula | Aggregates models from all configured providers |

```bash
# Pull, configure, and run
cyfr pull c:moonmoon69.claude:1.0.0
cyfr setup c:moonmoon69.claude:1.0.0
cyfr run c:moonmoon69.claude:1.0.0

# Search for more
cyfr search <query>
```

`cyfr setup` walks you through secrets, grants, and policy in one step. Grants apply to all versions of a component.

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

## External MCP Servers

Connect external MCP-compatible servers (Notion, GitHub, custom tools) to make their tools available alongside CYFR's built-in tools:

```bash
# Add an external server
cyfr mcp add github --url https://api.github.com/mcp --headers '{"Authorization":"secret:GITHUB_TOKEN"}'

# Test the connection
cyfr mcp test github

# List all connected servers
cyfr mcp list

# Server tools appear as github:tool_name in your tool list
```

Headers support secret references (`secret:KEY_NAME`) so credentials stay encrypted.

## Prism Dashboard

CYFR includes **Prism**, a web-based dashboard at `http://localhost:4001` with a shell-style window manager. Built-in apps:

- **Ask AQUA** — AI agent harness with builder and explorer specialists for interactive component development and web research
- **Executions** — monitor running and past executions in real-time
- **Components** — browse registered components and their policies
- **Builds** — compilation tracking and history
- **Logs** — MCP request logs with correlation
- **Secrets** — manage encrypted secrets and component grants
- **API Keys** — create and manage tiered API keys
- **Schedules** — cron-based recurring component execution
- **MCP Servers** — manage external MCP server connections
- **Settings** — server configuration

Prism also supports **iframe apps** — third-party web dashboards sandboxed within the shell.

> Prism is optional — everything it does is also available via the CLI and MCP tools.

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
│       └── local/      # Example formulas: list-models, agent
└── data/
    └── cyfr.db         # Secrets, policies, execution records (.gitignored)
```

> The `components/` directory contains working reference implementations with full source code — catalysts, reagents, and formulas you can study, modify, and use as starting points for your own components.

## CLI Reference

Every `cyfr` CLI command maps to an MCP tool call. AI agents use the exact same interface programmatically. Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a new CYFR project (safe to re-run; use `--force` to overwrite config) |
| `cyfr up` / `cyfr down` | Start / stop the server |
| `cyfr upgrade` | Upgrade the cyfr CLI and Docker image (system-wide) |
| `cyfr update` | Update project scaffold files — docs, WIT definitions (project-local) |
| `cyfr status` | Check system health (includes CLI version) |

### Identity

| Command | Description |
|---------|-------------|
| `cyfr login` | Authenticate via Device Flow |
| `cyfr logout` | End current session |
| `cyfr whoami` | Show current identity |

### Components

| Command | Description |
|---------|-------------|
| `cyfr new <type> <name>` | Scaffold a new component project |
| `cyfr build compile <ref>` | Compile a component by reference (saves binary, auto-registers) |
| `cyfr build validate <ref>` | Validate a component without compiling |
| `cyfr build toolchains` | List available build toolchains |
| `cyfr search <query>` | Search the component registry |
| `cyfr list` | List installed components |
| `cyfr inspect <ref>` | Show component details, policy, and dependency tree `[i]` |
| `cyfr pull <ref>` | Fetch a component and its dependencies from the registry |
| `cyfr register` | Scan and register all local components |
| `cyfr setup <ref>` | Configure secrets, grants, and policy for a component `[i]` |
| `cyfr run <ref>` | Execute a component `[i]` |
| `cyfr remove <ref>` | Remove a component `[i]` |
| `cyfr publish <ref>` | Sign and push to the registry |

### MCP Servers

| Command | Description |
|---------|-------------|
| `cyfr mcp add <name>` | Add an external MCP server |
| `cyfr mcp remove <name>` | Remove an external MCP server |
| `cyfr mcp list` | List all connected MCP servers |
| `cyfr mcp get <name>` | Show server details and tools |
| `cyfr mcp test <name>` | Test connectivity to a server |
| `cyfr mcp enable/disable <name>` | Enable or disable a server |
| `cyfr mcp refresh <name>` | Refresh a server's tool list |

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
| `cyfr schedule create/list/get/update/pause/resume/delete` | Manage cron schedules for recurring component execution |
| `cyfr log list/get/correlate` | View and inspect MCP request logs |
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

CYFR is an Elixir umbrella application with a Go CLI and a Tauri desktop app.

### Prerequisites

- Elixir ~> 1.19 and Erlang/OTP 28
- Rust (for wasmex NIF compilation and Porta)
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

### Building Porta

```bash
cd apps/porta
cargo tauri dev    # development mode
cargo tauri build  # production build
```

### Running Tests

```bash
mix test                      # all tests
mix test apps/opus/test       # specific service
```

## License

[Apache License 2.0](LICENSE)
