<p align="center">
  <img src="apps/cyfr/priv/static/images/logo.png" alt="CYFR" width="200" />
</p>

# Prompts aren't permissions

A prompt can tell a model what not to do, but you can only hope it obeys. CYFR controls what a model can actually reach.

# What is CYFR

CYFR is a self-hosted runtime and control plane for agents that call APIs, use data, and run workflows. If AI models are the new electricity (model proposes an action), CYFR is your electrical system that routes that power through controlled circuits (CYFR checks it against policies and permission granted by you) and run the appliances (sandboxed component performs the action if allowed). **The brain is rented; the keys stay with you.**

When a task comes, search the registry or create your own reusable component for super fast execution instead of asking and waiting for a model to figure it out, especially when tasks become routine. **Pay for intelligence, not repetition.**

> **License:** CYFR is **Fair Source** (source available) — the Sanctum subsystem is FSL-1.1-Apache-2.0, everything else is Apache-2.0. See [License](#license).

## How CYFR works

CYFR exposes components to agents as structured tools over [MCP](https://modelcontextprotocol.io/), avoiding brittle UI automation while the runtime handles credentials, consent enforcement, and execution records.

Components are the appliances in that system — purpose-built, sandboxed, and composable units:

- **Reagent** — pure compute, no I/O (transforms, validation, scoring)
- **Catalyst** — I/O with the outside world (HTTP APIs, databases, secrets)
- **Formula** — compositions that chain Reagents, Catalysts and other Formulas into workflows
- **Tincture** — frontend experiences (HTML/JS/CSS) served by CYFR and can be interacted privately or publicly

Formulas support **execution event streaming** — long-running formulas (like agentic loops) push intermediate events (`emit`) so frontends see progressive updates in real-time via SSE or PubSub.

### Interfaces

CYFR exposes two surfaces over the same runtime:

- **Codex** — the `cyfr` command-line client. Scriptable; talks to a running CYFR instance over MCP. Run it locally (or on the box CYFR runs on) for project setup, builds, component management, and CI.
- **Prism** — the web face, served by CYFR on its one endpoint (`:4000`, or `/` behind Caddy) and installable as a PWA: the chat with **AQUA** — your friendly assistant — one zone across every estate you belong to (a shared thread every member of an estate sees, with approvals any member can decide), your own AQUA in a panel on every page, each estate's AQUA page, and the developer views — executions, components, builds, activities, enforcements, the vault, API keys, schedules, MCP servers, tinctures.

## Quick Start

There are two ways to use CYFR; pick the one that fits.

### Deploy it for end users

Stand up the self-hosted stack on a server (see [Deploy to a Server](#deploy-to-a-server)) and your users just open `https://<your-domain>/`, sign in, and get their athanor's chat — no CLI on their side. "Add to Home Screen" installs it like a native app; it runs equally well on a phone.

### Develop with Codex + Prism

Run CYFR locally and drive it with the `cyfr` CLI. Install Docker first — the shell installer and Homebrew cask install the `cyfr` CLI only; they do not install Docker, and Docker must be running before `cyfr init` / `cyfr up`:

- macOS / Windows: install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Linux: quick dev install via Docker's convenience script: `curl -fsSL https://get.docker.com | sh` (for production hosts, prefer your distro's Docker packages). Then, **if you are not running as root**, add yourself to the `docker` group so the CLI can reach the daemon without `sudo`:

  ```bash
  sudo groupadd docker
  sudo usermod -aG docker $USER
  newgrp docker            # or log out and back in
  ```

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

# Grant a component the vault entries it needs
# (or use the console's Vault page)
cyfr profile grant c:moonmoon69.claude

# Learn more about other commands
cyfr -h

# Open Prism — your athanor's chat
open http://localhost:4000
```

`cyfr init` downloads your project files and pulls the server images: `docker-compose.yml`, `Caddyfile`, `.env.example` and the services' own env examples, `cyfr.yaml`, WIT interface definitions, the `aqua/` soul, roles and scrolls, and the included guides ([integration-guide.md](integration-guide.md), [component-guide.md](component-guide.md), [tincture-guide.md](tincture-guide.md)). It writes `.env` from `.env.example`, prompting for the hostname, the operator's sign-in email (the first platform admin), and — for a real hostname — a Let's Encrypt email, and mints the stack's keys into it: `CYFR_SECRET_KEY_BASE`, `CYFR_MCP_BRIDGE_KEY`, the worker root `CYFR_WORKER_KEY` with the `OPUS_SERVICE_KEY` derived from it, and `CYFR_LOCUS_BUILDS_KEY` beside `CYFR_LOCUS_BUILDS_URL`, so builds are on. Pass `--no-interactive` to take the defaults. It does not install Docker itself. The scaffolded `docker-compose.yml` is the full self-hosted stack — `cyfr` (the one endpoint on `:4000`: Prism, API, MCP, tinctures), `opus` (the execution worker that runs components), `locus-builds` (the builds service behind `cyfr build compile`), `mcp-bridge` (stdio MCP servers) and `caddy` (TLS + reverse proxy at `:80`/`:443`, for real-hostname deployments); `cyfr up` brings up the first four, and `caddy` too when you enabled TLS at init. See [Deploy to a Server](#deploy-to-a-server) for the same stack on a VPS.

## Prism — the web face

**Prism** is CYFR's one web face, at `http://localhost:4000` (the same origin as the API — one endpoint, one login), and it is chat-first: `/` lands in your athanor's chat with **AQUA**. A person's athanor is your thread with your own AQUA — the same thread on your phone and your laptop. A group athanor is a group chat every member sees, with approval cards any member can decide; whether a line starts AQUA is derived, never configured: an estate with one person in it answers every message, and any room with two or more answers only an `@mention`, so people can talk to people. Your own AQUA rides along in a floating panel on every page — a private thread in your own estate that reads the room you have open and whose answers you paste into the room yourself — a DM is a small frozen estate minted by clicking a person in the chat rail (anyone you share an estate with is there; it ends when either person leaves — clicking again starts a new, empty one), following a thread decides your sidebar and notifications (never access), and a line from your private thread reaches a group only when you say it aloud — a deliberate, attributed copy. Sign in on a phone and "Add to Home Screen" — Prism installs like a native app.

Around the chat:

- **The chat** — one page, `/chat`: a rail of your own thread, your DMs, and the threads of every group you belong to (`/chat?a=<estate>&c=<thread>` deep-links one). The estate's **AQUA** page at `/a/<estate>/aqua` holds the soul, its roles, its scrolls, the pinned page and the notes drawer. What AQUA keeps out of a thread is a note — the `notes` tool's `keep`, `pin`, `list`, `read`, `search` and `forget` — and a schedule with `keep_outcome` in its metadata files each run's output as one.
- **The switcher** — You, then the groups you belong to (hidden as a list when it is only you), each row badged with what happened there while you were elsewhere. The one create is **New group…**.
- **The drawer** — off the chat, on every screen size: **AQUA**, **Apps** (tinctures), **Members**, **Vault**, **Schedules**, **Webhooks**, **MCP Servers**, **Settings**, **Legal**. Connect a model to AQUA from **AQUA** — the grant sheet binds a sealed vault entry to the model's catalyst — no developer view needed.
- **`lite` / `dev`** — a per-person preference in Settings, not an edition. `dev` adds the developer views — **Executions**, **Activities**, **Enforcements**, **Components**, **Builds**, **Registry**, **API Keys**, **Reports** — in a sidebar with live indicators; the ops surface stays reachable in `lite`, it just isn't the face. `lite` is the default when the server has a door (an auth provider); operators and private boxes start in `dev`.
- **⌘⇧K** — the command palette, also from the drawer's Search… row.

Tinctures can stay private inside Prism, or be made public and shared at `http(s)://<your CYFR_HOST>/t/<athanor>/<publisher>/<name>` — served through Caddy (locally, plain HTTP on `:80`; with a real domain, HTTPS). See [Deploy to a Server](#deploy-to-a-server).

## Project Layout

After `cyfr init`, your project looks like this:

```
your-project/
├── integration-guide.md   # How to use CYFR as your app backend
├── component-guide.md      # Full guide to building components
├── tincture-guide.md       # Guide to building tinctures
├── docker-compose.yml      # Self-hosted stack: cyfr, opus, locus-builds, mcp-bridge (+ caddy in TLS mode)
├── Caddyfile               # Reverse proxy (TLS mode only): everything → cyfr:4000
├── Dockerfile.node         # Builds the `mcp-bridge` image
├── apps/                   # The sources that image is built from: mcp-bridge/, spawn/
├── cyfr.yaml
├── .env                    # The stack's keys and config, written by `cyfr init` (do not commit)
├── .env.example            # Everything .env can set
├── .env.opus.example       # The opus service's own settings (copy to .env.opus)
├── .env.locus.example      # The locus-builds service's own settings (copy to .env.locus)
├── .env.bridge.example     # The mcp-bridge service's own settings (copy to .env.bridge)
├── .gitignore
├── LICENSE, LICENSES/, FAIR_SOURCE.md   # The license notices
├── wit/                    # WIT interface definitions for WASM components (developer reference)
│   ├── reagent/
│   ├── catalyst/
│   └── formula/
├── aqua/                   # The AQUA template every athanor is given: aqua.md (the soul), roles/, skills/
└── data/                   # ALL runtime state — one directory, .gitignored
    ├── cyfr.db             # Vault entries, consents, execution records
    ├── cache/              # Immutable cached artifacts (OCI blobs)
    ├── system/             # Server-internal scratch (health probes)
    └── athanors/           # One tree per athanor — each person's and each group's
        └── <athanor id>/
            ├── components/ # {type}s/{publisher}/{name}/{version}/
            │   ├── catalysts/   # Bundled: files, http, claude, openai, gemini, grok, openrouter
            │   ├── reagents/    # Your local reagents
            │   ├── formulas/    # Bundled formulas: list-models
            │   └── tinctures/   # Bundled example tinctures + your own
            ├── aqua/       # The athanor's own AQUA: the soul, its roles, its scrolls
            ├── threads/  # Chat attachment files
            ├── notes/      # What was kept out of a thread — host-only, no guest scope
            ├── payloads/   # Retained execution inputs and results — host-only, by digest
            └── data/       # Files WASM components store — their `data/` scope, and yours
```

> Every folder exists from the moment the athanor is provisioned. The Files
> page (and the `file` tool) shows the tree the way a phone shows its files:
> `data/` is yours to fill and clear, `components/` and `aqua/` hold shaped
> units whose files you edit in place, `notes/` and `threads/` are read
> there and managed on their own pages, and the server's own storage
> (`payloads/`, the seed, the cache) is not a folder at all.

> The seed bundle every athanor starts from rides inside the container image
> (under `CYFR_SEED_PATH`, mounted so `./aqua` replaces its `aqua/` root) and
> is copied into each athanor when it is provisioned — a scaffolded project
> carries no `components/` directory. Your athanor's copies of the bundle and
> your own components live together in its tree under `components/`.

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

Generic catalysts, formulas, and example tinctures ship bundled under the
`local` publisher: each athanor gets its own copy when it is provisioned,
and a newer shipped version is offered on the Components page and pulled
with `cyfr pull c:local.<name>`. The `moonmoon69` API catalysts are **not** bundled: they
arrive from the registry, normally pulled automatically as dependencies at
register time, or explicitly with `cyfr pull`. Use `cyfr list` / `cyfr search`
to see what's available, then grant one:

```bash
# Pick a vault entry for each thing the component needs, and approve it
cyfr profile grant c:moonmoon69.claude

# Run it
cyfr run c:moonmoon69.claude

# Install another component from the registry
cyfr pull c:moonmoon69.supabase
```

`cyfr profile grant` walks the consent flow: it shows what the component
asks for, lets you pick a vault entry for each need, renders exactly what
you are approving, and records it as an immutable consent revision. A grant
covers every release of that component line by default; grant a specific
version to pin it. `cyfr profile list <ref>` shows what is granted, and
`cyfr profile revoke <id>` takes it back, effective on the next run.

## Build Your Own Component

CYFR supports both WASM components and tinctures. The fastest path is to scaffold and iterate locally, then use the packaging or publishing workflow that fits your component type.

### WASM Components

```bash
# Scaffold a new component (creates directory, manifest, WIT files, starter Rust source)
cyfr new catalyst my-api
# Creates the scaffold inside your athanor's storage: data/athanors/<athanor>/components/catalysts/local/my-api/<version>
# Also: cyfr new reagent my-transform, cyfr new formula my-workflow

# Compile (auto-registers the component and auto-pulls any dependencies)
cyfr build compile c:local.my-api:0.1.0

# Run it
cyfr run c:local.my-api

# Push when ready (signs with Sigstore)
cyfr push c:local.my-api:1.0.0
```

The development loop is: **edit source → `cyfr build compile <ref>` → `cyfr run <ref>`**. Each compile saves the `.wasm` binary, auto-registers the component, cleans build artifacts, and pulls any missing dependencies. A Rust build is locked to the component's `Cargo.lock` after its first build; compile with `--resolve` after changing a dependency.

`cyfr push` pushes a local component to the registry under your **claimed personal namespace** — `c:local.my-api` is pushed as `c:<your-namespace>.my-api`. Run `cyfr login` first to authenticate and claim your namespace; pushing without one returns a "claim a personal namespace" error.

### Tinctures

Tinctures are CYFR's frontend component type — sandboxed HTML/JS/CSS apps managed by the runtime. They run inside Prism (private, authenticated — **Apps** in the drawer) or as standalone public pages at `https://<host>/t/<athanor>/<publisher>/<name>` (when explicitly made public).

```bash
# Scaffold a static HTML/JS/CSS tincture
cyfr new tincture stock-dashboard

# Or scaffold a React + TypeScript + Vite tincture
cyfr new tincture stock-dashboard --template react

# Build it
cyfr build compile t:local.stock-dashboard:0.1.0

# Open it in Prism (the athanor in focus is in the URL)
open http://localhost:4000/a/@alice/tinctures

# Check whether it is publicly reachable at /t/@alice/local/stock-dashboard
cyfr tincture visibility get local stock-dashboard
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

Vanilla tinctures are simple static frontends; the React template gives you Vite + TypeScript out of the box. Tinctures default to private; publishing one is a consent decision — the profile tool's `publish` (plan → preview → commit) mints its public profile, and revoking that profile unpublishes it. If you make file changes outside the normal build flow, run `cyfr register` to rescan local components.

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

If you prefer a guided workflow, you can also use **Prism**'s **AQUA chat** to build components interactively. AQUA has access to component guides, file operations, build/execution tools, and component setup flows, so with a capable model configured it can handle a large share of the scaffolding and iteration for you quickly.

> See [component-guide.md](component-guide.md) and [tincture-guide.md](tincture-guide.md) for the full guides on building catalysts, reagents, formulas, and tinctures. See [integration-guide.md](integration-guide.md) for app-backend patterns and tincture data flows.

## External MCP Servers

Connect external MCP-compatible servers (Context7, GitHub, custom tools) to make their tools available alongside CYFR's built-in tools:

```bash
# Add an external server (config is a JSON object)
cyfr mcp add github '{"url":"https://api.githubcopilot.com/mcp/"}'
cyfr mcp add notion '{"url":"https://mcp.notion.com/mcp","headers":{"Authorization":"vault:notion-key"}}'

# Test the connection
cyfr mcp test github

# List all connected servers
cyfr mcp list

# Server tools appear as github:tool_name in your tool list
```

Header values support vault references (`vault:ENTRY_NAME`, or with a scheme,
`Bearer vault:ENTRY_NAME`) — the named vault entry's single field is resolved at request
time, after the scheme when there is one, so credentials stay encrypted at rest and never
appear in the server config.

## Deploy to a Server

CYFR is self-hosted as a small `docker compose` stack:

| service | what it is |
|---|---|
| `cyfr` | the one endpoint on `:4000`: Prism (chat + console, a PWA), API, MCP, tinctures; its host API on `:4300` (the worker network only) takes the execution worker's host calls |
| `opus` | the execution worker: runs WASM components as cyfr assigns them, each subtree in a runner VM under a uid of its own, on the internal `worker` network, holding one derived key and no tenant state. Built from `Dockerfile.opus`; see [Execution workers](#execution-workers) |
| `mcp-bridge` | runs the stdio/`npx` MCP servers (filesystem, github, …) an athanor adds, each backend under a uid of its own, and serves their tools to cyfr. Built locally from `Dockerfile.node`; it keeps no state |
| `locus-builds` *(profile: `locus-builds`)* | the builds service: compiles components and tinctures, each build under a uid and a memory bound of its own, on its own `locus-builds` network that only cyfr joins, holding one builds key and no tenant state. The `cyfr-locus` image, built from `Dockerfile.locus`. Started when `CYFR_LOCUS_BUILDS_URL` in `.env` names it, as `cyfr init` writes it; see [Builds](#builds) |
| `caddy` *(profile: `tls`)* | TLS terminator + reverse proxy in front of `cyfr:4000`. Started only when `CYFR_BEHIND_PROXY=true` in `.env` |

Two modes:
- **Direct** (local): cyfr + opus + locus-builds + mcp-bridge. Prism at `http://localhost:4000/`.
- **TLS** (VPS with a hostname): also runs caddy (`--profile tls`). Prism at `https://<CYFR_HOST>/`.

`cyfr init` prompts which mode you want and writes the right value into `.env` (`CYFR_BEHIND_PROXY`). `cyfr up` reads `.env` and toggles the `tls` profile automatically, and the `locus-builds` profile when `CYFR_LOCUS_BUILDS_URL` names the builds service, which it does after `cyfr init`.

There is **no censorship-circumvention layer** here — Caddy gives you TLS, not unblockability; if your network actively blocks endpoints, put this stack behind a separate obfuscated transport.

### Prerequisites

- A Linux VPS (or any Docker host) with Docker + the Compose plugin: **Docker Engine 28 or later on a cgroup v2 host** (cgroup v2 is the default of current distributions and of Docker Desktop). `opus` and `locus-builds` hold every runner and every build to a memory bound of its own, a cgroup `cyfr-spawn` makes for it, which needs the containers' `security_opt: writable-cgroups=true` (in the shipped `docker-compose.yml`; it adds no capability). Without it — an older engine, a cgroup v1 host, or the option removed — nothing runs unbounded and nothing runs: `opus` starts no runner and logs, naming `writable-cgroups=true`, that it cannot bound one, so no component runs; and every build is refused as `unavailable`, naming the option.
- For TLS mode: a domain pointing at the VPS. For direct mode: nothing extra.
- Firewall: TLS mode → open `80/tcp`, `443/tcp` (+ `443/udp` for HTTP/3). Direct mode publishes `:4000` on `127.0.0.1` only — it is for the box you run it on.

### Setup

Use the `cyfr` CLI — it downloads `docker-compose.yml` + `Caddyfile`, writes `.env` (prompts for `CYFR_HOST` / `CYFR_PLATFORM_ADMIN_EMAILS` / TLS y/n / `CADDY_ACME_EMAIL` and mints the stack's keys), and brings the stack up:

```bash
# Install the CLI (the installer/cask install the CLI only, not Docker):
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#   …or:  brew tap cyfrworks/cyfr && brew install --cask cyfr

mkdir my-cyfr && cd my-cyfr
cyfr init        # downloads compose + Caddyfile, writes .env and its keys, asks the TLS y/n question
cyfr up          # starts cyfr + opus + locus-builds + mcp-bridge (and caddy if TLS mode)
```

`cyfr init` mints every key the stack needs into `.env`: `CYFR_SECRET_KEY_BASE`, `CYFR_MCP_BRIDGE_KEY`, the [execution worker](#execution-workers)'s root `CYFR_WORKER_KEY` with the `OPUS_SERVICE_KEY` derived from it for the worker's service id (`wrk_opus` unless `.env` names another `OPUS_SERVICE_ID`), and the [builds](#builds) key beside `CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100`. It also assigns [`CYFR_CORS_ALLOWED_ORIGINS`](#cors-allowlist-required-for-server-deployments) the empty allowlist, which a release with sign-in configured needs to boot and the shipped stack's same-origin clients never notice. Run in a project whose `.env` already exists, it adds only the keys `.env` lacks and never rewrites one: with no root and no service key it mints both, with a root alone it derives the service key from it, a builds URL gets a minted key and a builds key gets the URL. A service key with no root beside it, or one the root beside it does not derive, is refused with a sentence naming the fix, and nothing is written.

<details><summary>Prefer a source checkout?</summary>

```bash
git clone https://github.com/cyfrworks/cyfr && cd cyfr
cp .env.example .env
# edit .env:
#   CYFR_SECRET_KEY_BASE — `openssl rand -base64 48`
#   CYFR_HOST            — your domain (or "localhost")
#   CYFR_PLATFORM_ADMIN_EMAILS — your email (platform admin; required to access the instance)
#   CYFR_BEHIND_PROXY    — true for TLS (caddy) mode, false for direct
#   CADDY_ACME_EMAIL     — your email (only needed for TLS mode)
#   CYFR_MCP_BRIDGE_KEY  — `openssl rand -hex 32`
#   CYFR_WORKER_KEY      — `openssl rand -hex 32`
#   OPUS_SERVICE_KEY     — `env CYFR_WORKER_KEY=… mix cyfr.worker.key wrk_opus`
#                          (see "Execution workers" for the openssl equivalent)
#   CYFR_LOCUS_BUILDS_URL — http://locus-builds:4100 (see "Builds")
#   CYFR_LOCUS_BUILDS_KEY — `openssl rand -hex 32`

# Direct:
docker compose --profile locus-builds up -d
# TLS:
docker compose --profile tls --profile locus-builds up -d
```
</details>

Then open `https://<your-domain>/` (TLS) or `http://localhost:4000/` (direct), sign in, and you're in your athanor's chat. "Add to Home Screen" installs it as a PWA (works on phones too). In TLS mode caddy proxies everything to `cyfr:4000` — Prism, `/api`, `/mcp`, `/auth` and `/t` on the same origin. The `cyfr` endpoint (`:4000`) is always published on `127.0.0.1` so the `cyfr` CLI and a local browser work from the host.

**Upgrading.** `cyfr update` pulls the latest images, then `cyfr up`. `cyfr init` run again in the project adds a key a newer stack needs that `.env` lacks, and changes nothing else. From a source checkout: `docker compose --profile locus-builds pull && docker compose --profile locus-builds up -d` (add `--profile tls` if you're running with caddy, and drop the builds profile if builds are off). Check the [release notes](https://github.com/cyfrworks/cyfr/releases) first: there is no compatibility layer for behaviour, and a release says what it changes for a running server.

### Stdio / npx MCP servers (filesystem, github, …)

CYFR reaches an **http** MCP server at its URL. A **stdio** MCP server (anything that launches with `npx -y …`) runs on the `mcp-bridge` container instead: CYFR tells the bridge what to run and signs every message to it.

Adding one from Prism:

1. Open **MCP Servers** in the sidebar and click **Add stdio server**.
2. Give the server a name (e.g. `github`), a backend name, the command (e.g. `npx -y @modelcontextprotocol/server-github`), and its env, one `NAME=value` per line. A credential is always a vault template — `GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token`, naming a single-field entry on the **Vault** page; only `NODE_ENV`, `LOG_LEVEL`, `TZ`, `LANG`, `LC_ALL`, `NO_COLOR` and `DEBUG` may hold a literal, and a command may never name a vault entry, because every process in the bridge can read command lines.
3. On first use the bridge starts the backend and its tools surface as `github:github__search_repositories`, … on CYFR's tool list. AQUA uses them like any other external MCP tool. A backend that takes longer than 15 s to start (an `npx -y` download, say) has its tools added to the list once it is ready, without a refresh.

From the CLI or MCP, the same server is `cyfr mcp add github '{"transport":"stdio","backends":[{"name":"github","command":"npx -y @modelcontextprotocol/server-github","env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"vault:github-token"}}]}'`; a server may define up to four backends.

Defining or changing a server — `mcp_servers.create` and `update`, http or stdio — takes a signed-in session: Prism, or the CLI after `cyfr login`. A definition decides what the server runs and where it sends the vault entries it names, which is a person's decision like granting a vault entry to a component. An admin API key can list, inspect, test, refresh, restart, enable, disable and delete servers, but defines none.

How it holds together:

- **One key.** `CYFR_MCP_BRIDGE_KEY` (32 random bytes as 64 hex digits) is in `.env`; `cyfr init` generates it and compose gives it to both `cyfr` and `mcp-bridge`. The bridge refuses to start without it, and cyfr refuses stdio servers without it (and `CYFR_MCP_BRIDGE_URL`, which compose sets). It is the only setting the bridge needs.
- **Nothing on disk.** The bridge persists nothing. CYFR sends a server's definition when the server is first used — its env resolved from the vault and sealed to that server and that bridge lifetime — and again for every running server when the bridge restarts. When CYFR restarts, the bridge releases what the previous boot ran, and each server starts again on its next use. Backends run only while CYFR keeps renewing their lease (30 s; `CYFR_MCP_BRIDGE_LEASE_MS` sets it); a server whose backends are slow to start never delays another server's renewal.
- **Idle backends stop.** A backend with no tool call for 15 minutes (`CYFR_MCP_BRIDGE_IDLE_MS` sets it) is stopped and its pool slot freed; its tools stay listed, and the next call starts it again — for an `npx -y` package, downloading it again.
- **Isolation.** Each backend runs under a pooled uid of its own with a private home, an environment built only from its server's env, and no capability. One athanor's backends hold at most a quarter of the pool, and so do the backends of every server one person created, across all their athanors. A server's requests reach only its own backends, and every result is masked with that server's credentials. Backends share the network, CPU and memory, and can see each other's command lines.
- **Changes take effect at once.** Updating, disabling, deleting or restarting a server, or rotating, revoking or renaming a vault entry its env names, stops its backends before anything else can reach them; the next use starts them again with the new definition. `mcp_servers.get` shows each backend's status, restarts and a masked stderr tail; **Restart** on the expanded row starts a stdio server's backends afresh.
- Stdio servers are not available when `CYFR_CLUSTER` is on.

### Execution workers

Components run on a worker service, not in `cyfr`: the `opus` container runs the WASM engine, and `cyfr` reaches it over HTTP to start and kill runs while its runners reach `cyfr`'s host API for everything a run needs (its attempt, its credentials, its stream, its children). Every request and host call is authenticated with keys derived from one root, which only `cyfr` holds.

- **Two keys.** `CYFR_WORKER_KEY` (32 random bytes as 64 hex digits) is the root, in `.env` and read by `cyfr` alone. `OPUS_SERVICE_KEY` is the key derived from it for the worker's service id, `OPUS_SERVICE_ID` (`wrk_opus` by default; another id is named in `CYFR_WORKERS` too), and compose hands the id and the key to `opus` alone, from `.env`. `cyfr init` mints the root and derives the key; by hand, the root is `openssl rand -hex 32`, and `CYFR_WORKER_KEY=… mix cyfr.worker.key wrk_opus` prints the key from a source checkout, or `printf 'cyfr-worker/v1/worker\nwrk_opus' | openssl dgst -sha256 -mac HMAC -macopt hexkey:$CYFR_WORKER_KEY` is the same HMAC without one. The worker never sees the root, the keyring or the database; it refuses to start with any of them in its environment. Changing the root ends every run in flight and needs every service key derived again: remove `OPUS_SERVICE_KEY` beside the new root and `cyfr init` derives it.
- **Who is where.** `CYFR_WORKERS` lists the worker services `cyfr` dispatches to as `<service_id>=<url>` entries, tried in order; compose sets `wrk_opus=http://opus:4200`. `cyfr`'s host API listens at `CYFR_HOST_API_BIND:CYFR_HOST_API_PORT` (default `127.0.0.1:4300`; compose binds every interface, since it is reached over the internal `worker` network alone) and `OPUS_HOST_URL` tells the worker where that is. `cyfr` asks each worker for its status every `CYFR_WORKER_WATCH_POLL_MS` and, after `CYFR_WORKER_WATCH_MISSES` misses in a row or when a worker comes back as a new boot, closes the runs that boot held as lapsed. The worker's own settings are in `.env.opus` (copy `.env.opus.example`).
- **Runners.** Inside `opus`, `cyfr-spawn` — the keeper binary the builder and the bridge also run under — starts the service as the `opus` user with no capability and runs every subtree in a runner: a VM of its own under a pooled uid (`opus-runner01`…`08`) with a private home on a tmpfs, holding no key, reached by the service alone over a control channel. The service keeps `OPUS_POOL_SIZE` runners spawned ahead; a runner that completes cleanly is kept idle for its athanor for `OPUS_IDLE_TTL_MS`; one that was killed, lost a host answer or exited with attempts open is tainted, never assigned again, and retired — every process of its uid killed and its home scrubbed before the uid is reused — with `OPUS_RELEASE_GRACE_MS` to report what it held; a guest that ignores its deadline is halted by the runner's watchdog `OPUS_WATCHDOG_GRACE_MS` past it. `tests/worker-image/` runs each of these against the shipped image.
- **Memory.** Every runner is held to `OPUS_RUNNER_MEMORY_BYTES` (384 MiB by default; 16 MiB to 1 TiB): its VM, every guest's linear memory, its home and the kernel memory charged to it, together. A runner that reaches it is ended whole by the kernel, the runs it held are reported, and it is never reused; a sibling is untouched. The container's limit, `OPUS_MEMORY_LIMIT` in `.env` (4G), holds all eight runner uids at their bound and the service beside them — raise it with the bound. The bound needs the [Docker requirement](#prerequisites) above.
- **Nothing on disk.** The worker keeps no state. A run's identity, budget, credentials and output live in `cyfr`; the worker holds only what it was assigned, sealed for its key, and reports a runner that exits. A worker restart ends its runs, which `cyfr` closes as lapsed.

### Builds

`cyfr build compile` runs on the `locus-builds` service, never in `cyfr`: `cyfr` sends a build's sources in a signed request and publishes the result it verifies, and the builder answers with the bytes, their digests and the build's diagnostics. With neither setting below, `cyfr` builds nothing and refuses every build, naming them; it runs no toolchain of its own.

Builds are on after `cyfr init`: it writes both settings into `.env`, and `cyfr up` starts `locus-builds` with the rest of the stack. They need what `opus` needs anyway, **Docker Engine 28 or later on a cgroup v2 host** (see [Prerequisites](#prerequisites)).

- **One key.** `CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100` and `CYFR_LOCUS_BUILDS_KEY` (32 random bytes as 64 hex digits; `cyfr init` mints it, and by hand it is `openssl rand -hex 32`) in `.env`, both or neither: `cyfr` refuses to boot with one and not the other, or with a malformed value. Compose hands the same key to the builder as `LOCUS_BUILDS_KEY`; the builder refuses to start without it, and with any of `cyfr`'s own secrets in its environment. With the URL set, `cyfr up` starts the service too (`docker compose --profile locus-builds up -d` without the CLI).
- **Turning builds off.** Set both empty in `.env` — `CYFR_LOCUS_BUILDS_URL=` and `CYFR_LOCUS_BUILDS_KEY=` — then `cyfr down` and `cyfr up`: `locus-builds` no longer starts, and `cyfr` refuses every build. `cyfr init` leaves a URL set empty with no key alone; with the two lines removed or commented out instead, running it again turns builds back on.
- **Isolation.** Inside `locus-builds`, `cyfr-spawn` runs every build under a pooled uid of its own with a private home on a tmpfs, and every process a build leaves behind is killed with its uid before the uid is reused. Only `cyfr` reaches the builder, over their own network; the network is not internal, because cargo and npm fetch from crates.io and the npm registry.
- **Memory.** Every build is held to `LOCUS_BUILDS_MEMORY_BYTES` (1 GiB by default): its processes, its home and the kernel memory charged to it, together. A build that reaches it is ended and answered as having reached its bound; a sibling build is untouched. The container's limit, `LOCUS_BUILDS_MEMORY_LIMIT` in `.env` (4G), holds `LOCUS_BUILDS_MAX_CONCURRENT` builds at their bound and the service beside them. The builder's other settings are in `.env.locus` (copy `.env.locus.example`). The bound needs the [Docker requirement](#prerequisites) above.

**`OOMKilled` is not the container's.** Docker marks the `opus` or `locus-builds` container `OOMKilled` whenever a runner or a build is ended at its own bound, though neither the container nor its release was touched: the kernel reports the kill in the container's cgroup tree. Read it as a runner or a build that passed its bound — the service's log says which — not as the container running out of memory; alert on the container restarting instead.

### Operator notes for shared and open-door servers

- **The seed `local.http` catalyst asks for wildcard egress** (`domains: ["*"]`, http+https; private IPs stay denied) and first-run provisioning consents the bundle automatically — on a server whose allowlist is `*`, that is a consented HTTP relay per signed-in stranger. The minted grant is pinned byte-for-byte by `apps/cyfr/test/sanctum/consent/bootstrap_golden_test.exs`, so widening or narrowing it is always a reviewed diff; narrow the seed manifest before opening the door if that posture is too generous for your deployment.
- **The audit trail carries identity fields, email included.** The door's refusal telemetry carries the attempted email (that is the audit content — who was turned away), and `Cyfr.Sanitizer` deliberately does not redact identity fields on the audit plane. Every entry is logged, and is also emitted once as the `[:cyfr, :audit, :recorded]` telemetry event carrying the sanitized `Arca.Audit.Event`: attach your own handler there to write the trail to a SIEM or an object store, and only to one that may hold PII.
- **A first sign-in needs cyfr.run reachable once** (to find or claim the person's namespace) and pulls the AQUA formula's provider catalysts from the registry. On an air-gapped or registry-unreachable install the athanor is created but left unprovisioned — retried on the next sign-in, with the cause in the server log and the `[:cyfr, :sanctum, :provisioning, :failed]` telemetry event. AQUA stays unavailable until a retry succeeds.

### Reaching Prism on the server

Prism is served by the same endpoint as everything else: `https://<your-domain>/` in TLS mode. In direct mode the endpoint is loopback-only; forward it over SSH:

```bash
ssh -L 4000:localhost:4000 <user>@<server>
```

Then open `http://localhost:4000` locally — with the port, which is what the
browser origin check trusts (a bare `http://localhost` is port 80, and a page
served there is not this server).

## Production Configuration

Everything below is optional — the defaults (GitHub/Google sign-in, SQLite,
local `./data` storage) run a full instance with zero extra configuration —
with one exception: a server (release) deployment must assign the CORS
allowlist, because sign-in is enabled by default, and `.env.example` and
`cyfr init` assign it empty for you. Each option is set in
`.env` (see the matching blocks in `.env.example`) and fails loud: if an
option is enabled but incompletely configured, the server refuses to start
rather than silently falling back.

### CORS allowlist (required for server deployments)

A release refuses to boot when authentication is configured (it is by
default) while CORS still allows every origin — that combination would let
any website make credentialed cross-origin requests. `.env.example` and
`cyfr init` therefore assign the allowlist empty:

```bash
CYFR_CORS_ALLOWED_ORIGINS=
```

Empty allows no cross-origin caller at all, which is what the shipped
stack needs: cyfr serves Prism, the API, `/mcp` and the tinctures from its
own origin, and behind Caddy they are still that one origin, so
same-origin traffic never needs CORS. Set it to the origin(s) of a
frontend you serve elsewhere, comma-separated:

```bash
CYFR_CORS_ALLOWED_ORIGINS=https://app.example.com
```

Assigning it is what matters: with the line removed the wildcard default
stands and the release refuses to boot. Local `mix phx.server` runs only
warn, so development is unaffected.

### Prometheus metrics

`/metrics` (Prometheus text format, API port) is disabled by default because
it is unauthenticated. Opt in with:

```bash
CYFR_PROMETHEUS_METRICS=true
```

When enabled, bind the server to a private interface (`CYFR_BIND_ADDRESS`) or
allowlist the path at your reverse proxy.

### Federated SSO (OIDC)

Point sign-in at your identity provider (Okta, Auth0, Keycloak, Azure AD, …):

```bash
CYFR_AUTH_PROVIDER=oidc
CYFR_OIDC_ISSUER=https://auth.example.com
CYFR_OIDC_CLIENT_ID=...
CYFR_OIDC_CLIENT_SECRET=...
```

All three `CYFR_OIDC_*` values are required once `oidc` is selected.
Sign-in is still gated by `CYFR_PLATFORM_ADMIN_EMAILS` and the server allowlist
(`cyfr admin allow …`) — authentication says who you are, the door says whether
you may come in.

### The door, and what a first sign-in needs

A person's first sign-in on a server asks cyfr.run once for their personal
namespace — the same on every server, claimed once — and mints their own
athanor, seeded and baseline-consented (the bundled `catalyst:local.http`
is granted `egress.domains ["*"]` for public hosts, GET/POST/HEAD, 60/min;
private addresses it cannot reach at all — its manifest declares no
`egress.private_ips`, which is the only list a running component's private-IP
check consults, so a LAN device is reachable from a chain as an MCP server on
`CYFR_PRIVATE_EGRESS_TARGETS` and not as a URL to fetch). If cyfr.run
cannot be reached at that moment, nothing is set up and the person is told
to try again; later sign-ins do not need cyfr.run at all — the namespace is
recorded on their `users` row. `cyfr admin deny <email>` revokes their
sessions and keys, archives their own athanor, removes them from every group
and withdraws the invitations that address was still holding; `cyfr admin
allow` lets them back in and reopens their own athanor — group seats are not
restored, a member adds them again.

### Opening the door to everyone (`*`), and the caps that bound it

`cyfr admin allow '*'` admits any identity your provider authenticates —
that is the public-hosting configuration, and it is the one where the limits
matter. They are all optional and **off unless set** — except the group,
DM and thread caps, which ship at 50, 200 and 1000 and are each turned off
with `0`; a private box needs none of the others.

| Variable | Bounds |
|---|---|
| `CYFR_MAX_ATHANORS` | athanors on this server, active ones only — an archived furnace frees its place |
| `CYFR_MINT_PER_HOUR` | personal athanors minted per hour, i.e. how fast strangers can arrive |
| `CYFR_MAX_GROUPS_PER_PERSON` | groups one person may **create** (default 50; they may belong to more) |
| `CYFR_MAX_PAIRS_PER_PERSON` | DMs one person may hold open (default 200). A DM is minted for two, so either person at the ceiling refuses it; an ended DM frees its place |
| `CYFR_MAX_MEMBERS_PER_GROUP` | seats in one group, invitations included |
| `CYFR_MAX_THREADS_PER_ATHANOR` | threads one estate may hold (default 1000) — a thread is a row any member's client can mint from the wire, each with a follow row of its own |
| `CYFR_ATHANOR_STORAGE_BYTES` | bytes one athanor may hold — everything in its tree, its copies of the shipped bundle included; copying a shipped version in is never refused by the cap, but its bytes count from then on |

A new athanor is provisioned with its own copy of the shipped bundle and
AQUA tree, so `CYFR_MAX_ATHANORS` bounds tenancy and
`CYFR_ATHANOR_STORAGE_BYTES` bounds each athanor's whole tree.
A specific `cyfr admin deny` always beats `*`.

Closing the door again — `cyfr admin remove` on the `*` entry — ejects
everyone it was the only reason for: their sessions end and the API keys they
created are revoked. Their standing is untouched (nothing is archived, no
group seat is lost); that is what `deny` is for. The eject happens when the
entry is removed, so an allowlist row edited directly in the database, or a
`*` removed while the server is down, leaves live credentials behind — remove
it through `cyfr admin` on a running server.

### Postgres (bring your own)

The default database is embedded SQLite (`./data/cyfr.db`). Postgres is
opt-in, and the Ecto adapter is chosen at **build time** — the published
Docker image is SQLite-built, so a Postgres deployment needs an image built
with `CYFR_DATABASE=postgres`. At runtime point it at your database:

```bash
CYFR_DATABASE_URL=postgres://user:pass@host:5432/cyfr
```

`CYFR_DATABASE_URL` is required for a Postgres build (no localhost fallback).
Both adapters run as blocking legs in CI.

The server migrates the schema on boot. Several nodes sharing one Postgres,
or an operator who wants that step in their own hands, set
`CYFR_AUTO_MIGRATE=false` and run it from the release before starting:

```bash
bin/cyfr eval "Cyfr.Release.migrate()"
```

### Several members on one database (a cell)

One server per database is the default, and a second one pointed at the
same database refuses to boot rather than quietly running every sweep
twice. A **cell** is the deliberate alternative: one deployment — one
database, one object store, one set of workers — served by several
control-plane **members**, each holding its own slot in `cell_leases` and
taking a peer's work only after that peer's lease has run out on the
database's clock.

`CYFR_CLUSTER=1` turns it on, and the flag alone is not a cell. A member
boots only with all six of:

- **Postgres** (`CYFR_DATABASE=postgres`). SQLite is one file with one
  writer and no server clock, so members could not agree which lease
  stands.
- **Shared object storage** (`CYFR_STORAGE=s3`). Local storage is one
  member's filesystem; two members would each hold half of every estate.
- **TLS distribution** — `-proto_dist inet_tls` with an
  `-ssl_dist_optfile` naming the member's certificate, key and CA. Plain
  distribution between control planes is an unauthenticated remote shell
  onto the database.
- **A cell-only cookie** — `CYFR_CELL_COOKIE`, at least 32 characters,
  the same value on every member and the value each member's BEAM
  actually runs under (`RELEASE_COOKIE`, or `-setcookie`). An ambient
  `~/.erlang.cookie` is the machine's, not the cell's.
- **A discovery topology** — `CYFR_CLUSTER_NODES` naming the members, or
  `CYFR_CLUSTER_DNS_QUERY` with `CYFR_CLUSTER_NODE_BASENAME` for a
  headless service.
- **A shared worker root** — `CYFR_WORKER_KEY`, identical on every
  member. Unset it is random per boot, so a worker's report to a peer
  fails verification.

Each missing one is a named refusal at boot, saying what it found and what
to change.

What a cell gives up and what it keeps:

- Work is not routed. A turn runs on the member that accepted it and an
  execution on the member that admitted it; ownership is settled after
  the fact by a claim row. Put the members behind any load balancer.
- A member's lease is 15 s, renewed every 5 s, so a member that stops
  without releasing is taken over within **20 s**. A clean stop releases
  at once.
- Each member needs a **worker service of its own**, named in that
  member's `CYFR_WORKERS`, with its `OPUS_HOST_URL` pointing at that
  member's host API. A worker posts every host call and exit report to
  the one address its credentials name, so a worker shared between
  members would answer one member's runs and lose the other's.
- Stdio MCP servers are not available in a cell.
- Per-member ceilings multiply: `CYFR_MAX_CONCURRENT_EXECUTIONS` and its
  per-tenant cap, and the per-credential stream cap, are each member's.
  The tenant's durable ceilings — its consented invocation rate and its
  budget — are rows, and hold for the cell.

`mix test --only cluster apps/cyfr/test/cluster` is the suite that proves
this: two real nodes, one Postgres, one object store, with both process
death and a live partitioned owner.

### Headless nodes

`CYFR_HEADLESS=true` makes a node Codex-only: `/mcp`, `/api` and public
tinctures under `/t` are served, and every browser page — sign-in, the chat,
Prism — answers 404. The CLI still signs in through the built-in device flow
on `/mcp`, so this is for nodes that never show a face (a build worker, a
relay); it does not combine with an external OIDC provider, which moves
sign-in to the browser page a headless node refuses.

### Storage paths

File storage defaults to the local `./data` volume — the one root holding
every athanor's tree, the caches, and (on SQLite) the database itself.
These variables move the pieces (dev and releases alike; tests pin their
own tmp roots):

```bash
CYFR_DATA_PATH=data                     # the one storage root
CYFR_SEED_PATH=seed                     # the seed tree, read in place: the
                                        # component bundle under components/ and
                                        # the AQUA template under aqua/
                                        # (the image points it at /app/seed)
CYFR_DATABASE_PATH=data/cyfr.db         # the SQLite file; defaults to
                                        # cyfr.db inside the storage root
```

### S3-compatible object storage

For S3 (or MinIO and other S3-compatible stores):

```bash
CYFR_STORAGE=s3
CYFR_S3_BUCKET=...
CYFR_S3_REGION=us-east-1
CYFR_S3_ACCESS_KEY_ID=...
CYFR_S3_SECRET_ACCESS_KEY=...
# MinIO / non-AWS: also set CYFR_S3_ENDPOINT and CYFR_S3_PATH_STYLE=true
```

All four required vars must be set or the server refuses to start.

> On S3 the bucket holds the Arca objects only — the `data/` volume still
> holds the database (`cyfr.db`), so backing up an S3 deployment means both.

> A built tincture's compile (one whose manifest declares `tincture.build`)
> saves on S3 as it does on disk: what publishes a version is its database
> pointer and the journal entry beside it, not the objects, so the commit
> needs nothing of the store that an object store lacks. What differs is
> what a reader can see while the new `dist/` is moved into place. On disk
> the tree is swapped, so a reader sees the whole previous build and then
> the whole new one. An object store has no rename, so the move is object
> by object: between its first object and its last, a reader can be served
> some files of the new build and some of the previous one. Each file is
> whole, the version reads complete throughout, and the mixture lasts only
> as long as the move.

### Proxy trust and rate limits

- `CYFR_TRUSTED_PROXY_HOPS` (default `1`) — how many reverse-proxy hops sit
  in front of cyfr when `CYFR_BEHIND_PROXY=true`. The shipped stack has
  exactly one (Caddy). Stack a CDN or another proxy in front and you must
  raise it (or list the proxies in `CYFR_TRUSTED_PROXY_CIDRS`), otherwise
  client IPs resolve to the proxy address and API-key IP allowlists fail
  closed.
- `CYFR_MCP_RATE_LIMIT_MAX` / `CYFR_MCP_RATE_LIMIT_WINDOW_MS` (default
  120/60s) — per-client-IP transport throttle on the `/mcp` endpoint.
- `CYFR_MAX_CONCURRENT_EXECUTIONS` (default 128) and
  `CYFR_MAX_CONCURRENT_EXECUTIONS_PER_TENANT` (default 16) — global and
  per-athanor WASM concurrency caps. The container CPU quota
  (`CYFR_CPU_LIMIT`, default 4) bounds aggregate CPU use.

### Backup and restore

What to back up depends on the backends you configured:

| Backend | What holds state | Backup |
|---|---|---|
| SQLite (default) | `./data` (database, encrypted secrets, every athanor's components and files, caches) | Stop the stack (`cyfr down`), copy `./data`, restart. Copying while running risks a torn SQLite snapshot. |
| Postgres | your database + `./data` for files | `pg_dump` on your schedule + the `./data` copy above |
| S3 | the bucket + the database | enable bucket versioning/replication; back the database up as above |

Restore = put `./data` (and the database) back, then start the stack with the
**same `CYFR_SECRET_KEY_BASE`** — secrets are encrypted with a key derived
from it, so a restored data directory is unreadable under a different key
base. Treat `.env` as part of the backup (it holds that key), store it
separately from the data backup if you can, and exclude `erl_crash.dump` and
`tmp/` from backup jobs — a crash dump can contain decrypted key material
from process memory.

## CLI Reference

Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a CYFR project — downloads `docker-compose.yml` + `Caddyfile`, writes `.env` (asks the TLS y/n question) with the stack's keys minted into it, creates dirs; in an existing project it adds only the keys `.env` lacks (`--force` re-fetches the deploy files; never replaces `.env`) |
| `cyfr up` / `cyfr down` | Start / stop the stack: cyfr, opus and mcp-bridge, plus locus-builds when `CYFR_LOCUS_BUILDS_URL` in `.env` names it (as `cyfr init` writes it) and caddy when `CYFR_BEHIND_PROXY=true` |
| `cyfr upgrade` | Upgrade the CYFR Codex binary (system-wide) |
| `cyfr update` | Pull the latest stack images (cyfr, opus, locus-builds when builds are on, caddy when TLS) and refresh managed scaffold (guides, `wit/`, bundled `aqua/` prompts); leaves your `.env`, `docker-compose.yml`, `Caddyfile` alone, and notes a service of the bundled stack your `docker-compose.yml` lacks |

> `cyfr --version` and `cyfr status` print a one-line hint when a newer release is available. The check only runs in an interactive terminal and is cached for a day; set `CYFR_NO_UPDATE_CHECK=1` (e.g. in your shell profile) to turn it off.

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
| `cyfr inspect <ref>` | Show component details, declared needs/caps, and dependency tree `[i]` |
| `cyfr pull <ref>` | Fetch a component and its dependencies from the registry |
| `cyfr register` | Scan and register all local components (auto-pulls dependencies) |
| `cyfr profile grant <ref>` | Grant a component the vault entries it needs `[i]` |
| `cyfr profile list <ref>` | Show a component's profiles and consent revisions |
| `cyfr profile revoke <id>` | Revoke a profile, effective on the next run |
| `cyfr run <ref>` | Execute a component `[i]` |
| `cyfr fork [type] <reference>` | Copy a published component into your local namespace for customization |
| `cyfr remove <ref>` | Remove a component `[i]` |
| `cyfr push <ref>` | Sign and push to the registry |
| `cyfr deprecate <ref>` | Mark a published component version as deprecated |
| `cyfr yank <ref>` | Yank a published component version from the registry |
| `cyfr schedule create/list/get/update/pause/resume/delete` | Manage cron schedules for recurring execution `[i]`; `"keep_outcome": true` in a schedule's metadata files each run's output as a note in its estate |
| `cyfr report [component-ref]` | File an abuse report on a component or namespace |

### Tinctures

| Command | Description |
|---------|-------------|
| `cyfr tincture visibility get <publisher> <name>` | Check whether a tincture is private to Prism or publicly reachable |

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
| `cyfr call vault '{"action":"list",…}'` | Manage vault entries (encrypted credentials): create/rename/rotate/rebind/revoke/delete, `authorize` for OAuth — also in the console's Vault page |
| `cyfr key create/list/get/revoke/rotate` | Manage API keys `[i]` |
| `cyfr call oauth '{"action":"set_client",…}'` | Store an OAuth app's client credentials per provider; user grants run through `cyfr profile grant` and the console's Vault page |

### Administration

| Command | Description |
|---------|-------------|
| `cyfr log list/get/correlate` | View and inspect MCP request logs |
| `cyfr retention show/set/cleanup` | Manage data retention policies |
| `cyfr aqua list/get/status/reset/skills` | Read the AQUA soul, roles, guides and scrolls, see which files are shipped, edited or yours, and reset to shipped `[i]` |
| `file list/read/write/delete` (MCP) | The athanor's files as the Files page shows them — `data/` open, `components/` and `aqua/` shaped, `notes/` and `threads/` read-only |
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

### Non-interactive credentials (CI)

`cyfr` normally reads its credential from `~/.cyfr/config.json` (written by `cyfr login`). A CI job or container passes one directly instead: `--token <cyfr_...>` on any command, or `CYFR_TOKEN` in the environment — a `cyfr_` API key minted with `cyfr key create`, or a session token. The flag wins over the environment, which wins over the stored config.

CLI environment variables: `CYFR_TOKEN` (credential), `CYFR_NO_INTERACTIVE=1` (no prompts), `CYFR_NO_UPDATE_CHECK=1` (no release check — air-gapped installs), `CYFR_DEBUG=1` (verbose request/response detail on stderr).

## Documentation

| Document | Description |
|----------|-------------|
| [Integration Guide](integration-guide.md) | How to use CYFR as your application backend |
| [Component Guide](component-guide.md) | Practical guide to building catalysts, reagents, and formulas |
| [Tincture Guide](tincture-guide.md) | Practical guide to building tinctures |

## Verifying Releases

The install script verifies the SHA-256 checksum of every download against
the release's `checksums.txt` and **fails closed** on any mismatch or missing
tooling. If `cosign` is on your PATH it also strictly verifies the cosign
signature over `checksums.txt`. Two knobs adjust the policy:

- `CYFR_REQUIRE_SIGNATURE=1` — hard-require the cosign signature (the install
  fails if cosign is missing or verification fails).
- `CYFR_INSECURE_SKIP_VERIFY=1` — skip verification entirely (not
  recommended; for airgapped/bootstrap edge cases).

All release binaries are signed and attested. You can also verify manually at
three levels:

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
headers. The boundary is one application: everything under
`apps/sanctum/` (Sanctum — the auth, policy, audit and tenancy layer, with
its own tests) is licensed under the **Functional Source License 1.1** with **Apache 2.0** as the Change License
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
