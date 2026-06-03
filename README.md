<p align="center">
  <img src="apps/cyfr/priv/static/images/logo.png" alt="CYFR" width="200" />
</p>

# CYFR — Governed Runtime for Production Agent Workflows

CYFR is a self-hosted runtime for production agent workflows, with sandboxed execution, governed MCP tooling, and the secrets, policy, and visibility serious teams need.

> **License:** CYFR is **Fair Source** (source available) — the Sanctum subsystem is FSL-1.1-Apache-2.0, everything else is Apache-2.0. See [License](#license).

## What is CYFR?

**CYFR** gives teams a governed place to run agent workflows through native interfaces instead of brittle human UIs. Agents discover, build, and execute tools via [MCP](https://modelcontextprotocol.io/) with the secrets, policy controls, and observability needed for real production use.

Components are the building blocks — sandboxed, composable units that agents use as native interfaces:

- **Reagent** — pure compute, no I/O (transforms, validation, scoring)
- **Catalyst** — I/O with the outside world (HTTP APIs, databases, secrets)
- **Formula** — compositions that chain Reagents, Catalysts and other Formulas into workflows
- **Tincture** — frontend experiences (HTML/JS/CSS) served by CYFR in Prism or at `/t/<org>/<project>/<publisher>/<name>`

Formulas support **execution event streaming** — long-running formulas (like agentic loops) push intermediate events (`emit`) so frontends see progressive updates in real-time via SSE or PubSub.

### Interfaces

CYFR exposes three surfaces over the same runtime:

- **Codex** — the `cyfr` command-line client. Scriptable; talks to a running CYFR instance over MCP. Run it locally (or on the box CYFR runs on) for project setup, builds, component management, and CI.
- **Prism** — the developer dashboard, served by CYFR at `:4001`: a shell-style window manager with executions, components, builds, activities, policies, secrets, API keys, schedules, MCP servers, tinctures, and an "Ask AQUA" agent harness.
- **A.Q.U.A.** — the user-facing client: a PWA (installable on desktop and mobile; a React Native mobile client with the same feature set is planned) served by your CYFR deployment's `porta` container behind Caddy. A consumer-friendly workspace centered on **AQUA** — your friendly assistant — with built-in views for tinctures, the remote browser, schedules, components, MCP servers, and settings.

## Quick Start

There are two ways to use CYFR; pick the one that fits.

### Deploy it for end users (A.Q.U.A.)

Stand up the self-hosted stack on a server (see [Deploy to a Server](#deploy-to-a-server)) and your users just open `https://<your-domain>/`, sign in, and get the A.Q.U.A. PWA — no CLI on their side. "Add to Home Screen" installs it like a native app; it runs equally well on a phone.

### Develop with Codex + Prism

Run CYFR locally and drive it with the `cyfr` CLI. Install Docker first — the shell installer and Homebrew cask install the `cyfr` CLI only; they do not install Docker, and Docker must be running before `cyfr init` / `cyfr up`:

- macOS / Windows: install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Linux: quick dev install via Docker's convenience script: `curl -fsSL https://get.docker.com | sh` (for production hosts, prefer your distro's Docker packages)

```bash
# Install the cyfr CLI via shell script (Linux, macOS, WSL)
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Or via Homebrew (macOS)
brew tap cyfrworks/cyfr
brew install --cask cyfr

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

# Open the Prism dashboard
open http://localhost:4001
```

`cyfr init` downloads your project files and pulls the server images: `docker-compose.yml`, `Caddyfile`, `.env.example`, `cyfr.yaml`, starter components, WIT interface definitions, and the included guides ([integration-guide.md](integration-guide.md), [component-guide.md](component-guide.md), [tincture-guide.md](tincture-guide.md)). It writes `.env` from `.env.example` — a fresh `CYFR_SECRET_KEY_BASE` is generated and you're prompted for the hostname, an allowed sign-in email (single-user; recommended), and — for a real hostname — a Let's Encrypt email. Pass `--no-interactive` to take the defaults. It does not install Docker itself. The scaffolded `docker-compose.yml` is the full self-hosted stack — `cyfr` (API + Prism on `:4001`), `porta` (the A.Q.U.A. PWA), and `caddy` (TLS + reverse proxy at `:80`/`:443`); `cyfr up` brings all three up. With `CYFR_HOST=localhost`, Caddy serves the PWA over plain HTTP on `:80`. See [Deploy to a Server](#deploy-to-a-server) for the same stack on a VPS.

## Dashboard (Prism)

CYFR includes **Prism**, a web-based dashboard at `http://localhost:4001` with a shell-style window manager. Built-in apps include:

- **Ask AQUA** — AI agent harness with builder, artisan, explorer, planner, web, and arcade specialists for interactive component development and web research
- **Executions** — monitor running and past executions in real-time
- **Activities** — unified MCP-log + execution feed with request-anchored causal chains
- **Components** — browse registered components and their policies
- **Builds** — compilation tracking and history
- **Policies / Enforcements** — host policies and enforcement records
- **Secrets** — manage encrypted secrets and component grants
- **API Keys** — create and manage tiered API keys for external access
- **Schedules** — cron-based recurring component execution
- **MCP Servers** — manage external MCP server connections
- **Registry** — namespaces, publishers, and push tokens
- **Tinctures** — open and manage frontend experiences inside Prism's shell
- **Settings** — server configuration

Tinctures can stay private inside Prism, or be made public and shared at `http(s)://<your CYFR_HOST>/t/<org>/<project>/<publisher>/<name>` — served through Caddy (locally, plain HTTP on `:80`; with a real domain, HTTPS). See [Deploy to a Server](#deploy-to-a-server).

## Project Layout

After `cyfr init`, your project looks like this:

```
your-project/
├── integration-guide.md   # How to use CYFR as your app backend
├── component-guide.md      # Full guide to building components
├── tincture-guide.md       # Guide to building tinctures
├── docker-compose.yml      # Self-hosted stack: cyfr + porta + mcp-bridge (+ caddy in TLS mode)
├── Caddyfile               # Reverse proxy (TLS mode only): PWA at /, API under /mcp /api /auth /t
├── Dockerfile.node         # Builds the `porta` and `mcp-bridge` images
├── cyfr.yaml
├── .env                    # Secret key and config (do not commit)
├── .gitignore
├── wit/                    # WIT interface definitions for WASM components
│   ├── reagent/
│   ├── catalyst/
│   └── formula/
├── components/             # Components (type/publisher/name/version/)
│   ├── catalysts/
│   │   ├── local/          # Generic catalysts: files, http
│   │   └── moonmoon69/     # Bundled API catalysts: claude, openai, gemini, grok, openrouter, gmail, notion, supabase
│   ├── reagents/
│   │   ├── local/          # Your local reagents
│   │   └── moonmoon69/     # Bundled reagent: ta
│   ├── formulas/
│   │   └── local/          # Bundled formulas: list-models, aqua
│   └── tinctures/
│       └── local/          # Bundled example tinctures + your own
├── aqua/                   # AQUA agent manifest (agent.json) + role prompts
└── data/
    └── cyfr.db             # Secrets, policies, execution records (.gitignored)
```

> The `components/` directory contains working reference implementations and your own local components. Tinctures live in the same tree as catalysts, reagents, and formulas.

## Using Components

Components use the format `type:publisher.name:version`. The type can be a shorthand (`c:`, `r:`, `f:`, `t:`) or full name (`catalyst:`, `reagent:`, `formula:`, `tincture:`). Version is optional — omit it and the server resolves to the latest installed version.

```bash
# Versionless (recommended) — resolves to latest installed version
cyfr run c:moonmoon69.claude

# Tinctures use the same reference format
cyfr inspect t:local.weather-lookup:0.1.0

# Pinned to a specific version
cyfr run c:moonmoon69.claude:1.0.0

# Search for available components in the registry
cyfr search <query>

# Pull a component and its dependencies from the registry
cyfr pull c:moonmoon69.claude
```

A set of catalysts, reagents, formulas, and example tinctures ships bundled with `cyfr init` and is auto-registered (with dependencies pulled) when you run `cyfr register`. Use `cyfr list` / `cyfr search` to see what's available, then configure one in a single step:

```bash
# Configure secrets, grants, and policy interactively
cyfr setup c:moonmoon69.claude

# Run it
cyfr run c:moonmoon69.claude

# Install another component from the registry
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

# Push when ready (signs with Sigstore)
cyfr push c:local.my-api:1.0.0
```

The development loop is: **edit source → `cyfr build compile <ref>` → `cyfr run <ref>`**. Each compile saves the `.wasm` binary, auto-registers the component, cleans build artifacts, and pulls any missing dependencies.

`cyfr push` pushes a local component to the registry under your **claimed personal namespace** — `c:local.my-api` is pushed as `c:<your-namespace>.my-api`. Run `cyfr login` first to authenticate and claim your namespace; pushing without one returns a "claim a personal namespace" error.

### Tinctures

Tinctures are CYFR's frontend component type — sandboxed HTML/JS/CSS apps managed by the runtime. They run inside Prism's window manager (private, authenticated) or as standalone public pages at `https://<host>/t/<org>/<project>/<publisher>/<name>` (when explicitly made public).

```bash
# Scaffold a static HTML/JS/CSS tincture
cyfr new tincture stock-dashboard

# Or scaffold a React + TypeScript + Vite tincture
cyfr new tincture stock-dashboard --template react

# Build it
cyfr build compile t:local.stock-dashboard:0.1.0

# Open it in Prism
open http://localhost:4001/tinctures

# Make it publicly reachable at /t/local/default/local/stock-dashboard
cyfr tincture visibility set local stock-dashboard true
```

**Data.** Tinctures are self-contained frontends — CYFR serves their web content, not a database. Pull backend data at runtime by calling formulas or catalysts through the auto-injected `cyfr` SDK; if you need static seed data, ship a `data.db` (or any file) as a static asset and read it client-side.

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

> See [component-guide.md](component-guide.md) and [tincture-guide.md](tincture-guide.md) for the full guides on building catalysts, reagents, formulas, and tinctures. See [integration-guide.md](integration-guide.md) for app-backend patterns and tincture data flows.

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

CYFR is self-hosted as a small `docker compose` stack:

| service | what it is |
|---|---|
| `cyfr` | control plane / API (Emissary `:4000`) + Prism dashboard (`:4001`) |
| `porta` | the **A.Q.U.A.** PWA — `vite preview` serves the built React bundle on `:8080` (`ghcr.io/cyfrworks/cyfr-porta`) and proxies `/mcp /api /auth /t` to `cyfr:4000` so the PWA is same-origin in both modes |
| `mcp-bridge` | the HTTP MCP gateway. Wraps stdio/`npx` MCP servers (filesystem, github, …) behind one endpoint and surfaces their tools through cyfr. Built locally from `Dockerfile.node`; backends live in `./data/mcp-bridge/backends.json` |
| `caddy` *(profile: `tls`)* | TLS terminator + reverse proxy: PWA at `/`, API under `/mcp` `/api/*` `/auth/*` `/t/*`. Started only when `CYFR_BEHIND_PROXY=true` in `.env` |

Two modes:
- **Direct** (local / LAN): cyfr + porta + mcp-bridge. PWA at `http://<CYFR_HOST>:8080/`.
- **TLS** (VPS with a hostname): also runs caddy (`--profile tls`). PWA at `https://<CYFR_HOST>/`.

`cyfr init` prompts which mode you want and writes the right values into `.env` (`CYFR_BEHIND_PROXY` and `CYFR_PORTA_BIND`). `cyfr up` reads `.env` and toggles the `tls` profile automatically.

Single-user by design. There is **no censorship-circumvention layer** here — Caddy gives you TLS, not unblockability; if your network actively blocks endpoints, put this stack behind a separate obfuscated transport.

### Prerequisites

- A Linux VPS (or any Docker host) with Docker + the Compose plugin.
- For TLS mode: a domain pointing at the VPS. For direct mode: nothing extra.
- Firewall: TLS mode → open `80/tcp`, `443/tcp` (+ `443/udp` for HTTP/3). Direct mode → open `8080/tcp` (or whatever you bind `CYFR_PORTA_BIND` to).

### Setup

Use the `cyfr` CLI — it downloads `docker-compose.yml` + `Caddyfile`, writes `.env` (generates `CYFR_SECRET_KEY_BASE`, prompts for `CYFR_HOST` / `CYFR_PLATFORM_ADMIN_EMAILS` / TLS y/n / `CADDY_ACME_EMAIL`), and brings the stack up:

```bash
# Install the CLI (the installer/cask install the CLI only, not Docker):
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#   …or:  brew tap cyfrworks/cyfr && brew install --cask cyfr

mkdir my-cyfr && cd my-cyfr
cyfr init        # downloads compose + Caddyfile, writes .env, asks the TLS y/n question
cyfr up          # starts cyfr + porta + mcp-bridge (and caddy if TLS mode)
```

<details><summary>Prefer a source checkout?</summary>

```bash
git clone https://github.com/cyfrworks/cyfr && cd cyfr
cp .env.example .env
# edit .env:
#   CYFR_SECRET_KEY_BASE — `openssl rand -base64 48`
#   CYFR_HOST            — your domain (or "localhost")
#   CYFR_PLATFORM_ADMIN_EMAILS — your email (platform admin; required to access the instance)
#   CYFR_BEHIND_PROXY    — true for TLS (caddy) mode, false for direct
#   CYFR_PORTA_BIND      — 127.0.0.1:8080 (TLS) or 0.0.0.0:8080 (direct)
#   CADDY_ACME_EMAIL     — your email (only needed for TLS mode)

# Direct:
docker compose up -d
# TLS:
docker compose --profile tls up -d
```
</details>

Then open `https://<your-domain>/` (TLS) or `http://<your-host>:8080/` (direct), sign in, and you're in A.Q.U.A. "Add to Home Screen" installs it as a PWA (works on phones too). In TLS mode caddy serves the PWA at `/` and proxies `/api` `/mcp` `/auth` `/t` → `cyfr:4000`; in direct mode porta's `vite preview` proxies the same paths internally. The `cyfr` API (`:4000`) and Prism (`:4001`) are always published on `127.0.0.1` so the `cyfr` CLI works from the host.

**Upgrading.** `cyfr update` pulls the latest images, then `cyfr up`. From a source checkout: `docker compose pull && docker compose up -d` (add `--profile tls` if you're running with caddy). Check the [release notes](https://github.com/cyfrworks/cyfr/releases) first.

### Wrapping stdio / npx MCP servers (filesystem, github, …)

CYFR can only register **HTTP** MCP servers. To use a stdio MCP server (anything that launches with `npx -y …`), the `mcp-bridge` container wraps it: it spawns the child process and exposes a single HTTP MCP endpoint that surfaces all the children's tools, prefixed by backend name.

The PWA wires this up for you:

1. Open **MCP Servers** in the sidebar, click **+ Setup MCP Bridge**. That registers the gateway with CYFR (one external MCP entry named `bridge`, URL `http://mcp-bridge:8001/mcp` resolved inside the compose network — the browser never connects to it directly).
2. Below the server list, a **Bridge backends** section appears. Click **Add backend**, pick a name (e.g. `fs`) and a command (e.g. `npx -y @modelcontextprotocol/server-filesystem ./data`).
3. The child boots, its tools surface as `bridge:fs__read_file`, `bridge:fs__write_file`, … on CYFR's tool list. AQUA agents can use them like any other external MCP tool.

Backends persist to `./data/mcp-bridge/backends.json` so they survive container restarts. Remove or restart them from the same page.

### Reaching Prism on the server

Prism is the developer dashboard; it isn't exposed by Caddy. Forward its port over SSH:

```bash
ssh -L 4001:localhost:4001 <user>@<server>
```

Then open `http://localhost:4001` locally.

## CLI Reference

Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a CYFR project — downloads `docker-compose.yml` + `Caddyfile`, writes `.env` (asks the TLS y/n question), creates dirs (`--force` re-fetches the deploy files; never touches `.env`) |
| `cyfr up` / `cyfr down` | Start / stop the stack (cyfr + porta + mcp-bridge, plus caddy when `CYFR_BEHIND_PROXY=true` in `.env`) |
| `cyfr upgrade` | Upgrade the cyfr CLI binary (system-wide) |
| `cyfr update` | Pull the latest stack images (cyfr, porta, caddy when TLS) and refresh managed scaffold (guides, `wit/`, bundled `aqua/` prompts); leaves your `.env`, `docker-compose.yml`, `Caddyfile` alone |

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
| `cyfr push <ref>` | Sign and push to the registry |
| `cyfr deprecate <ref>` | Mark a published component version as deprecated |
| `cyfr yank <ref>` | Yank a published component version from the registry |
| `cyfr schedule create/list/get/update/pause/resume/delete` | Manage cron schedules for recurring execution `[i]` |
| `cyfr report [component-ref]` | File an abuse report on a component or namespace |

### Tinctures

| Command | Description |
|---------|-------------|
| `cyfr tincture visibility get <publisher> <name>` | Check whether a tincture is private to Prism or publicly reachable |
| `cyfr tincture visibility set <publisher> <name> <true\|false>` | Control whether a tincture is public at `/t/<org>/<project>/<publisher>/<name>` |

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
| `cyfr oauth authorize/status/revoke` | Authorize, check, or revoke a component's access to a user-scoped third-party API (Gmail, Calendar, …) |

### Administration

| Command | Description |
|---------|-------------|
| `cyfr log list/get/correlate` | View and inspect MCP request logs |
| `cyfr retention show/set/cleanup` | Manage data retention policies |
| `cyfr aqua list/get` | Access AQUA agents, prompts, and documentation guides `[i]` |
| `cyfr registry whoami` | Show registry identity (push tokens, claimed namespaces) |
| `cyfr registry probe` | Force a re-probe against cyfr.run (re-mints push tokens) |
| `cyfr registry get-namespace <slug>` | Inspect a cyfr.run namespace |
| `cyfr registry publisher claim/verify <domain>` | Claim + DNS-verify a publisher namespace `[i]` |
| `cyfr registry tokens list/issue/revoke <ns>` | Manage push tokens for a namespace `[i]` |
| `cyfr registry members list/add/update/remove <ns>` | Manage members of a publisher namespace `[i]` |
| `cyfr registry discover <registry>` | Inspect OCI registry capabilities (distribution discovery) |
| `cyfr webhook create/get/list/update/revoke/rotate` | Manage inbound HMAC-signed webhooks that trigger a component `[i]` |
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
| [Component Guide](component-guide.md) | Practical guide to building catalysts, reagents, and formulas |
| [Tincture Guide](tincture-guide.md) | Practical guide to building tinctures |

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

CYFR is **Fair Source** — mixed-licensed per file via `SPDX-License-Identifier`
headers. The boundary is one subsystem: everything under
`apps/cyfr/lib/sanctum/` (Sanctum — the auth, policy, audit, and tenancy
layer) and its tests under `apps/cyfr/test/sanctum/` is licensed under the
**Functional Source License 1.1** with **Apache 2.0** as the Change License
([`FSL-1.1-Apache-2.0`](LICENSES/FSL-1.1-Apache-2.0.txt)). Everything
else is **[Apache License 2.0](LICENSES/Apache-2.0.txt)**. See
[`LICENSE`](LICENSE) for the top-level pointer and
[`FAIR_SOURCE.md`](FAIR_SOURCE.md) for the practical Q&A.

### What this means in one paragraph

You can self-host CYFR for free, modify it, redistribute it, and run it
for your own organization's internal use — that is a *Permitted Purpose*
under FSL. The prohibited use is a *Competing Use*: making CYFR available
to others in a commercial product or service that substitutes for CYFR,
substitutes for a product or service CYFR Works Inc. offers, or provides
substantially similar functionality (e.g. "Managed CYFR" as a SaaS). Each
version of an FSL file also becomes available under plain Apache 2.0 two
years after that version is released.

### Procurement notes

- FSL is **not OSI-approved**. Companies whose policy is "OSI-approved
  only" may need an exception process. The Permitted Purpose covers
  internal use, evaluation, and most consulting.
- GitHub license detection shows "Other" on mixed-license repos; the
  individual files carry their own SPDX identifiers.
- Hex.pm: `:licenses` is declared as `["Apache-2.0", "FSL-1.1-Apache-2.0"]`.
- Distros (Debian `main`, Fedora) typically exclude FSL packages from
  default repos. CYFR ships via Docker, Homebrew, and source checkout.
- NixOS: classify as "unfree" and allow with
  `nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (pkg.meta.license.shortName or "") ["fsl11Apache20"];`

### Precedent

FSL and adjacent source-available licenses (BUSL) are the path Sentry,
HashiCorp, Sourcegraph, Convex, Elastic, and others have taken. The
2-year delay to Apache is what `fsl.software` calls "Delayed Open Source
Publication" — each released version converts to Apache 2.0 two years
later.
