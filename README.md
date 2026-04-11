<p align="center">
  <img src="apps/cyfr/priv/static/images/logo.png" alt="CYFR" width="200" />
</p>

# CYFR — Governed Runtime for Production Agent Workflows

CYFR is a self-hosted runtime for production agent workflows, with sandboxed execution, governed MCP tooling, and the secrets, policy, and visibility serious teams need.

## What is CYFR?

**CYFR** gives teams a governed place to run agent workflows through native interfaces instead of brittle human UIs. Agents discover, build, and execute tools via [MCP](https://modelcontextprotocol.io/) with the secrets, policy controls, and observability needed for real production use.

Components are the building blocks — sandboxed, composable units that agents use as native interfaces:

- **Reagent** — pure compute, no I/O (transforms, validation, scoring)
- **Catalyst** — I/O with the outside world (HTTP APIs, databases, secrets)
- **Formula** — compositions that chain Reagents, Catalysts and other Formulas into workflows
- **Tincture** — frontend experiences (HTML/JS/CSS) served by CYFR in Prism or at `/t/<publisher>/<name>`

Formulas support **execution event streaming** — long-running formulas (like agentic loops) push intermediate events (`emit`) so frontends see progressive updates in real-time via SSE or PubSub.

## Quick Start

Choose the path that fits how you plan to use CYFR.

### Consumer Quick Start (Porta)

**Porta** is a desktop app for macOS and Linux that manages the Dockerized CYFR server for you. Download from [GitHub Releases](https://github.com/cyfrworks/cyfr/releases) (the release marked "Latest" is always Porta), install, and launch — Porta handles Docker setup, CLI installation, server lifecycle, and updates automatically. Once started, it opens a consumer-friendly desktop agent workspace centered on **AQUA** - your friendly assistant, with built-in views for tasks, components, MCP servers, and settings.

It provides a system tray with status monitoring, automatic update notifications, and an MCP gateway for connecting external tool providers.

### Technical Quick Start (Codex)

Before using the CLI path, install Docker first. The shell installer and Homebrew formula install the `cyfr` CLI only; they do not install Docker. Make sure Docker is running before `cyfr init` or `cyfr up`.

- macOS / Windows: install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Linux: quick dev install via Docker's convenience script: `curl -fsSL https://get.docker.com | sh`

For production Linux hosts, prefer Docker's distro-specific package instructions instead of the convenience script.

```bash
# Install via shell script (Linux, macOS, WSL)
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Or via Homebrew (macOS)
brew tap cyfrworks/cyfr
brew install cyfr

# Initialize a project
mkdir <project-directory>
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

`cyfr init` scaffolds your project files and pulls the CYFR server image: `docker-compose.yml`, config files, starter components, WIT interface definitions, and the included guides such as [integration-guide.md](integration-guide.md) and [component-guide.md](component-guide.md). It does not install Docker itself. `cyfr register` scans the `components/` directory and automatically pulls any missing dependencies from the registry.


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
- **Tinctures** — open and manage frontend experiences inside Prism's shell
- **Settings** — server configuration

Tinctures can stay private inside Prism, or be made public and shared at `http://<host>:4000/t/<publisher>/<name>` (or `https://<domain>/t/<publisher>/<name>` when deployed behind Caddy with `cyfr init --remote`).

## Project Layout

After `cyfr init`, your project looks like this:

```
your-project/
├── integration-guide.md # How to use CYFR as your app backend
├── component-guide.md  # Full guide to building components and tinctures
├── docker-compose.yml
├── cyfr.yaml
├── .env                # Secret key and config (do not commit)
├── wit/                # WIT interface definitions for WASM components
│   ├── reagent/
│   ├── catalyst/
│   └── formula/
├── components/         # Components (type/publisher/name/version/)
│   ├── catalysts/
│   │   ├── local/      # Generic catalysts: files, http
│   │   └── moonmoon69/ # Bundled API catalysts: claude, openai, gemini, grok, openrouter, gmail, notion, supabase, web
│   ├── reagents/
│   │   └── local/
│   ├── formulas/
│   │   └── local/      # Bundled formulas: list-models, aqua
│   └── tinctures/
│       └── local/      # Created when you scaffold or pull tinctures
└── data/
    └── cyfr.db         # Secrets, policies, execution records (.gitignored)
```

> The `components/` directory contains working reference implementations and your own local components. Tinctures live in the same tree as catalysts, reagents, and formulas.

## Using Components

Components use the format `type:publisher.name:version`. The type can be a shorthand (`c:`, `r:`, `f:`, `t:`) or full name (`catalyst:`, `reagent:`, `formula:`, `tincture:`). Version is optional — omit it and the server resolves to the latest installed version.

```bash
# Versionless (recommended) — resolves to latest installed version
cyfr run c:moonmoon69.claude

# Tinctures use the same reference format
cyfr inspect t:local.stock-dashboard:0.1.0

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
| `c:moonmoon69.gmail` | Catalyst | Gmail API — read, send, and manage messages |
| `c:moonmoon69.notion` | Catalyst | Notion API — pages, databases, blocks |
| `c:moonmoon69.supabase` | Catalyst | Supabase backend — auth, database, storage |
| `c:moonmoon69.web` | Catalyst | Web fetching and scraping |
| `c:local.files` | Catalyst | Local filesystem operations |
| `c:local.http` | Catalyst | Generic HTTP client |
| `f:local.list-models` | Formula | Aggregates models from all configured providers |
| `f:local.aqua` | Formula | Agentic loop powering AQUA — orchestrates sub-agents and tool use |

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

CYFR supports both WASM components and tinctures. The fastest path is to scaffold and iterate locally, then use the packaging or publishing workflow that fits your component type.

### WASM Components

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

The development loop is: **edit source → `cyfr build compile <ref>` → `cyfr run <ref>`**. Each compile saves the `.wasm` binary, auto-registers the component, cleans build artifacts, and pulls any missing dependencies.

### Tinctures

Tinctures are CYFR's frontend component type — sandboxed HTML/JS/CSS apps managed by the runtime. They run inside Prism's window manager (private, authenticated) or as standalone public pages at `https://<host>/t/<publisher>/<name>` (when explicitly made public). Each tincture can declare its own SQLite-backed data schema and named queries in its manifest, and read that data from the browser via the auto-injected `cyfr` SDK.

```bash
# Scaffold a static HTML/JS/CSS tincture
cyfr new tincture stock-dashboard

# Or scaffold a React + TypeScript + Vite tincture
cyfr new tincture stock-dashboard --template react

# Build it
cyfr build compile t:local.stock-dashboard:0.1.0

# Open it in Prism
open http://localhost:4001/tinctures

# Make it publicly reachable at /t/local/stock-dashboard
cyfr tincture visibility set local stock-dashboard true
```

**Data and queries.** Declare tables and named queries in `cyfr-manifest.json`:

```json
{
  "name": "stock-dashboard",
  "type": "tincture",
  "version": "0.1.0",
  "schema": {
    "tables": {
      "stocks": {
        "columns": [
          {"name": "symbol", "type": "TEXT", "not_null": true},
          {"name": "date", "type": "TEXT", "not_null": true},
          {"name": "price", "type": "REAL"}
        ],
        "primary_key": ["symbol", "date"]
      }
    },
    "queries": {
      "latest": {
        "sql": "SELECT * FROM stocks WHERE date = (SELECT MAX(date) FROM stocks)",
        "cache_ttl": 600
      }
    }
  }
}
```

Reads are read-only and validated server-side; writes go through the `local_sqlite` MCP tool so a formula or catalyst can populate the database.

**SDK.** The `cyfr` SDK is auto-injected into every tincture's `<head>` — no script tag needed:

```javascript
// Invoke a backend component (PostMessage in Prism, HTTP in public mode)
const { status, output } = await cyfr.invoke("c:local.my-api", { key: "value" });

// React to shell events, update the window title, signal ready
cyfr.on("focus", () => { /* ... */ });
await cyfr.setTitle("Stock Dashboard");
await cyfr.ready();
```

Vanilla tinctures are simple static frontends; the React template gives you Vite + TypeScript out of the box. Tinctures default to private — use `cyfr tincture visibility set` to publish one. If you make file changes outside the normal build flow, run `cyfr register` to rescan local components.

### Fork a Component

```bash
# Pull a published component into your local cache
cyfr pull c:acme.sentiment:1.0.0

# Fork it into your local namespace
cyfr fork c:acme.sentiment:1.0.0 --name my-sentiment

# Same idea for tinctures
cyfr fork t:acme.stock-dashboard:1.0.0

# Rebuild your local fork
cyfr build compile c:local.my-sentiment:1.0.0
```

Forking is useful when you want to customize an existing component instead of starting from scratch. Pull the component first, and make sure the published component includes source code. For tinctures, the fork starts from the source files rather than any local runtime `data.db`.

If you prefer a guided workflow, you can also use **Prism**'s **Ask AQUA** to build components interactively. AQUA has access to component guides, file operations, build/execution tools, and component setup flows, so with a capable model configured it can handle a large share of the scaffolding and iteration for you quickly.

> See [component-guide.md](component-guide.md) for the full guide on building catalysts, reagents, formulas, and tinctures. See [integration-guide.md](integration-guide.md) for app-backend patterns and tincture data flows.

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

CYFR can be self-hosted on a VPS so multiple clients (Porta, browsers, public tinctures) can reach it over HTTPS. SSH into your server, install Docker, install the `cyfr` CLI, then run `cyfr init --remote`.

```bash
# Install Docker first
# Linux quick dev install: curl -fsSL https://get.docker.com | sh

# Install cyfr
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Initialize a VPS-ready project (Caddy reverse proxy + automatic TLS)
mkdir cyfr && cd cyfr
cyfr init --remote --domain cyfr.example.com

# Start everything (Caddy will obtain a Let's Encrypt certificate)
cyfr up
```

`cyfr init --remote` is the same as `cyfr init` but adds a Caddy service to `docker-compose.yml`, generates a `Caddyfile` that proxies `https://<domain>` → CYFR, and writes `CYFR_HOST=<domain>` into `.env`. Caddy handles HTTPS automatically — make sure your domain's DNS points to the server before running `cyfr up`.

From your local Porta, set `cyfrUrl` to `https://<domain>` in `~/.cyfr/porta.json`. Porta detects the remote URL, skips Docker management, and connects directly.

If you'd rather access the Prism dashboard on a remote Linux server, forward port 4001 over SSH:

```bash
ssh -L 4001:localhost:4001 <user>@<server>
```

Then open `http://localhost:4001` locally.

## CLI Reference

Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a new CYFR project (`--remote` for VPS deployment with Caddy + auto-TLS, `--force` to overwrite config) |
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
| `cyfr fork [type] <reference>` | Copy a published component into your local namespace for customization |
| `cyfr remove <ref>` | Remove a component `[i]` |
| `cyfr publish <ref>` | Sign and push to the registry |
| `cyfr schedule create/list/get/update/pause/resume/delete` | Manage cron schedules for recurring execution `[i]` |

### Tinctures

| Command | Description |
|---------|-------------|
| `cyfr tincture visibility get <publisher> <name>` | Check whether a tincture is private to Prism or publicly reachable |
| `cyfr tincture visibility set <publisher> <name> <true|false>` | Control whether a tincture is public at `/t/<publisher>/<name>` |

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
| `cyfr aqua list/get` | Access AQUA agents, prompts, and documentation guides `[i]` |
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
| [Component Guide](component-guide.md) | Practical guide to building components and tinctures |

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

## License

| Component | License |
|-----------|---------|
| CYFR Core | [Apache License 2.0](LICENSE) |
| Sanctum Arx (enterprise features) | [FSL-1.1-Apache-2.0](https://fsl.software/) — converts to Apache 2.0 after two years |

CYFR Core is Apache 2.0. Sanctum Arx enterprise features use the Functional Source License and convert to Apache 2.0 after two years.
