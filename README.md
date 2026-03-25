<p align="center">
  <img src="apps/cyfr/priv/static/images/logo.png" alt="CYFR" width="200" />
</p>

# CYFR — Governed Runtime for Production Agent Workflows

CYFR is a self-hosted runtime for production agent workflows, with sandboxed execution, governed MCP tooling, and the secrets, policy, and visibility serious teams need.

## What is CYFR?

**CYFR** gives teams a governed place to run agent workflows through native interfaces instead of brittle human UIs. Agents discover, build, and execute tools via [MCP](https://modelcontextprotocol.io/) inside a sandboxed WASM runtime with the secrets, policy controls, and observability needed for real production use.

Components are the building blocks — sandboxed, composable units that agents use as native interfaces:

- **Reagent** — pure compute, no I/O (transforms, validation, scoring)
- **Catalyst** — I/O with the outside world (HTTP APIs, databases, secrets)
- **Formula** — compositions that chain Reagents, Catalysts and other Formulas into workflows

Formulas support **execution event streaming** — long-running formulas (like agentic loops) push intermediate events (`emit`) so frontends see progressive updates in real-time via SSE or PubSub.

## Quick Start

Choose the path that fits how you plan to use CYFR.

### Consumer Quick Start (Porta)

**Porta** is a desktop app for macOS and Linux that manages the Dockerized CYFR server for you. Download from [GitHub Releases](https://github.com/cyfrworks/cyfr/releases) (the release marked "Latest" is always Porta), install, and launch — Porta handles Docker setup, CLI installation, server lifecycle, and updates automatically. Once started, it opens a consumer-friendly desktop agent workspace centered on **AQUA** - your friendly assistant, with built-in views for tasks, components, MCP servers, and settings.

It provides a system tray with status monitoring, automatic update notifications, and an MCP gateway for connecting external tool providers.

### Technical Quick Start (Codex)

```bash
# Install via shell script (Linux, macOS, WSL)
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Or via Homebrew (macOS)
brew tap cyfrworks/cyfr
brew install cyfr

# Initialize a project
cd <project-directory>
cyfr init

# Start the server
cyfr up

# Authenticate
cyfr login

# Scan bundled components and auto-pull their dependencies
cyfr register

# Learn more about other commands
cyfr -h

# Or, open the Prism dashboard for GUI
open http://localhost:4001
```

`cyfr init` scaffolds everything you need: `docker-compose.yml`, config files, example components, WIT interface definitions, prompt examples, the [integration guide](integration-guide.md), and the [component guide](component-guide.md). `cyfr register` scans the `components/` directory and automatically pulls any missing dependencies from the registry.


## Dashboard (Prism)

CYFR includes **Prism**, a web-based dashboard at `http://localhost:4001` with a shell-style window manager. Built-in apps:

- **Ask AQUA** — AI agent harness with builder and explorer specialists for interactive component development and web research
- **Executions** — monitor running and past executions in real-time
- **Components** — browse registered components and their policies
- **Builds** — compilation tracking and history
- **Logs** — MCP request logs with correlation
- **Secrets** — manage encrypted secrets and component grants
- **API Keys** — create and manage tiered API keys for external access
- **Schedules** — cron-based recurring component execution
- **MCP Servers** — manage external MCP server connections
- **Settings** — server configuration

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

## Using Components

Components use the format `type:publisher.name:version`. The type can be a shorthand (`c:`, `r:`, `f:`) or full name (`catalyst:`, `reagent:`, `formula:`). Version is optional — omit it and the server resolves to the latest installed version.

```bash
# Versionless (recommended) — resolves to latest installed version
cyfr run c:moonmoon69.claude

# Pinned to a specific version
cyfr run c:moonmoon69.claude:1.0.0

# Search for available components
cyfr search <query>

# Pull a component and its dependencies from the registry
cyfr pull c:moonmoon69.claude
```

### Available Components

| Component | Type | Description |
|-----------|------|-------------|
| `c:moonmoon69.claude` | Catalyst | Anthropic Claude API — messages, streaming, models |
| `c:moonmoon69.openai` | Catalyst | OpenAI API — chat completions, embeddings, images, audio |
| `c:moonmoon69.gemini` | Catalyst | Google Gemini API — text generation, embeddings |
| `c:moonmoon69.grok` | Catalyst | xAI Grok API — chat, vision, image generation, embeddings |
| `c:moonmoon69.openrouter` | Catalyst | OpenRouter API — unified access to 400+ AI models |
| `f:local.list-models` | Formula | Aggregates models from all configured providers |
| `f:local.agent` | Formula | Agentic loop for orchestrating tasks |

These are bundled with `cyfr init` and auto-pulled when you run `cyfr register`. To configure and use a component:

```bash
# Configure secrets, grants, and policy in one step
cyfr setup c:moonmoon69.claude

# Run it
cyfr run c:moonmoon69.claude

# Search for more components in the registry
cyfr search <query>

# Install Supabase catalyst from registry
cyfr pull c:moonmoon69.supabase
```

`cyfr setup` walks you through secrets, grants, and policy interactively. Grants and policies apply to all versions of a component if version is unspecified, pinned if version is included.

## Build Your Own Component

Scaffold, compile, and run a component in three commands:

```bash
# Scaffold a new component (creates directory, manifest, WIT files, starter Rust source)
cyfr new catalyst my-api
# Creates scaffold in components/<type>/local/my-api/<version>
# Also: cyfr new reagent my-transform, cyfr new formula my-workflow

# Compile (auto-registers the component and auto-pulls any dependencies)
cyfr build compile c:local.my-api:0.1.0

# Run it
cyfr run c:local.my-api

# Publish when ready (signs with Sigstore)
cyfr publish c:local.my-api:1.0.0
```

The development loop is: **edit source → `cyfr build compile <ref>` → `cyfr run <ref>`**. Each compile saves the `.wasm` binary, auto-registers the component, and pulls any missing dependencies.

If you prefer a guided workflow, you can also use **Prism**'s **Ask AQUA** to build components interactively. AQUA has access to component guides, file operations, build/execution tools, and component setup flows, so with a capable model configured it can handle a large share of the scaffolding and iteration for you quickly.

> See [component-guide.md](component-guide.md) for the full guide on building Reagents, Catalysts, and Formulas.

## External MCP Servers

Connect external MCP-compatible servers (Context7, GitHub, custom tools) to make their tools available alongside CYFR's built-in tools:

```bash
# Add an external server (config is a JSON object)
cyfr mcp add github '{"url":"https://api.githubcopilot.com/mcp/"}'
cyfr mcp add notion '{"url":"https://mcp.notion.com/mcp","headers":{"Authorization":"secret:NOTION_KEY"}}'

# Test the connection
cyfr mcp test github

# List all connected servers
cyfr mcp list

# Server tools appear as github:tool_name in your tool list
```

Header values support secret references (`secret:KEY_NAME`) so credentials stay encrypted.

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

## CLI Reference

Every `cyfr` CLI command maps to an MCP tool call. AI agents use the exact same interface programmatically. Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a new CYFR project (safe to re-run; use `--force` to overwrite config) |
| `cyfr up` / `cyfr down` | Start / stop the server |
| `cyfr upgrade` | Upgrade the cyfr CLI binary (system-wide) |
| `cyfr update` | Pull latest Docker image and update scaffold files (project-local) |

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
| `cyfr build compile <ref>` | Compile a component (auto-registers and auto-pulls dependencies) |
| `cyfr build validate <base64>` | Validate a base64-encoded WASM binary |
| `cyfr build toolchains` | List available build toolchains |
| `cyfr search <query>` | Search the component registry |
| `cyfr list` | List installed components |
| `cyfr inspect <ref>` | Show component details, policy, and dependency tree `[i]` |
| `cyfr pull <ref>` | Fetch a component and its dependencies from the registry |
| `cyfr register` | Scan and register all local components (auto-pulls dependencies) |
| `cyfr setup <ref>` | Configure secrets, grants, and policy for a component `[i]` |
| `cyfr run <ref>` | Execute a component `[i]` |
| `cyfr remove <ref>` | Remove a component `[i]` |
| `cyfr publish <ref>` | Sign and push to the registry |
| `cyfr schedule create/list/get/update/pause/resume/delete` | Manage cron schedules for recurring execution `[i]` |

### MCP Servers

| Command | Description |
|---------|-------------|
| `cyfr mcp add <name> <config-json>` | Add an external MCP server `[i]` |
| `cyfr mcp remove <name>` | Remove an external MCP server `[i]` |
| `cyfr mcp list` | List all connected MCP servers |
| `cyfr mcp get <name>` | Show server details and tools `[i]` |
| `cyfr mcp test <name>` | Test connectivity to a server `[i]` |
| `cyfr mcp enable/disable <name>` | Enable or disable a server |
| `cyfr mcp refresh [name]` | Refresh tool list from one or all servers |

### Security

| Command | Description |
|---------|-------------|
| `cyfr secret set/get/list/delete` | Manage encrypted secrets `[i]` |
| `cyfr secret grant/revoke` | Grant or revoke component access to secrets `[i]` |
| `cyfr policy set/show/list/reset/effective` | Manage and inspect host policies `[i]` |
| `cyfr key create/list/get/revoke/rotate` | Manage API keys `[i]` |
| `cyfr permission get/set/list` | Manage RBAC permissions `[i]` |

### Administration

| Command | Description |
|---------|-------------|
| `cyfr log list/get/correlate` | View and inspect MCP request logs |
| `cyfr retention show/set/cleanup` | Manage data retention policies |
| `cyfr guide list/get/readme` | Access docs and component READMEs `[i]` |
| `cyfr registry login/discover` | OCI registry operations `[i]` |
| `cyfr notify <event> <target>` | Send a webhook notification |
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

## Development

If you want to run CYFR locally or work on the codebase, here's the quickest way to get started. CYFR is an Elixir umbrella application with a Go CLI and a Tauri desktop app.

### Prerequisites

- Elixir ~> 1.19 and Erlang/OTP 28
- Rust (for wasmex NIF compilation and Porta)
- Go 1.26+ (for CLI)
- Node.js + npm (optional, only for Porta UI)

### Core Server Setup

```bash
git clone https://github.com/cyfrworks/cyfr
cd cyfr
mix setup
mix phx.server
```

### CLI Development

```bash
cd apps/codex
make build    # produces ./cyfr binary
make test     # run Go tests
make install  # install to $GOPATH/bin
```

### Porta Development

```bash
cd apps/porta
make dev      # installs UI deps and runs cargo tauri dev
make build    # installs UI deps and runs cargo tauri build
```

Porta is optional. If you do not need the desktop app, you can skip `apps/porta/` entirely and omit the Node.js/npm setup. The core server, Prism, component runtime, and Codex CLI do not depend on Porta for local development.

### Running Tests

```bash
mix test                      # all tests
mix test apps/opus/test       # specific service
```

## License

| Component | License |
|-----------|---------|
| CYFR Core (Sanctum, Opus, Locus, Codex, Porta) | [Apache License 2.0](LICENSE) |
| Sanctum Arx (enterprise features) | [FSL-1.1-Apache-2.0](https://fsl.software/) — converts to Apache 2.0 after two years |

Files under `apps/cyfr/lib/sanctum_arx/` are licensed under the Functional Source License (FSL-1.1-Apache-2.0). All other code is Apache 2.0.
