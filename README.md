<p align="center">
  <img src="apps/cyfr/priv/static/images/logo.png" alt="CYFR" width="200" />
</p>

# Prompts aren't permissions

Users can send prompts can tell a model what not to do, but can only HOPE the model is following the prompts. CYFR controls what models can actually reach.

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
- **Prism** — the web face, served by CYFR on its one endpoint (`:4000`, or `/` behind Caddy) and installable as a PWA: each athanor's chat with **AQUA** — your friendly assistant — (a shared thread every member sees, with approvals any member can decide), its Agents page, and the developer views — executions, components, builds, activities, enforcements, connections, API keys, schedules, MCP servers, tinctures.

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

# Grant a component the Connections it needs
# (or use the console's Connections page)
cyfr profile grant c:moonmoon69.claude

# Learn more about other commands
cyfr -h

# Open Prism — your athanor's chat
open http://localhost:4000
```

`cyfr init` downloads your project files and pulls the server images: `docker-compose.yml`, `Caddyfile`, `.env.example`, `cyfr.yaml`, WIT interface definitions, the `aqua/` orchestrator prompts, and the included guides ([integration-guide.md](integration-guide.md), [component-guide.md](component-guide.md), [tincture-guide.md](tincture-guide.md)). It writes `.env` from `.env.example` — a fresh `CYFR_SECRET_KEY_BASE` is generated and you're prompted for the hostname, the operator's sign-in email (the first platform admin), and — for a real hostname — a Let's Encrypt email. Pass `--no-interactive` to take the defaults. It does not install Docker itself. The scaffolded `docker-compose.yml` is the full self-hosted stack — `cyfr` (the one endpoint on `:4000`: Prism, API, MCP, tinctures) and `mcp-bridge`; `cyfr up` brings both up. A third service, `caddy` (TLS + reverse proxy at `:80`/`:443`), is opt-in behind the `tls` compose profile for real-hostname deployments — `cyfr up` adds `--profile tls` automatically when you enabled TLS at init. See [Deploy to a Server](#deploy-to-a-server) for the same stack on a VPS.

## Prism — the web face

**Prism** is CYFR's one web face, at `http://localhost:4000` (the same origin as the API — one endpoint, one login), and it is chat-first: `/` lands in your athanor's chat with **AQUA**. A person's athanor is your conversation with your own AQUA — the same thread on your phone and your laptop; a group athanor is a group chat every member sees, with the group's AQUA in it answering when `@mentioned` (or to everything, a group setting) and approval cards any member can decide. Sign in on a phone and "Add to Home Screen" — Prism installs like a native app.

Around the chat:

- **The switcher** — You, then the groups you belong to (hidden as a list when it is only you), each row badged with what happened there while you were elsewhere. The one create is **New group…**.
- **The drawer** — off the chat, on every screen size: **Apps** (tinctures), **Members**, **Connections**, **Agents**, **Schedules**, **Webhooks**, **MCP Servers**, **Settings**, **Legal**. Connect a model to AQUA from **Agents** — the grant sheet binds a sealed Connection to the model's catalyst — no developer view needed.
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
├── docker-compose.yml      # Self-hosted stack: cyfr + mcp-bridge (+ caddy in TLS mode)
├── Caddyfile               # Reverse proxy (TLS mode only): everything → cyfr:4000
├── Dockerfile.node         # Builds the `mcp-bridge` image
├── cyfr.yaml
├── .env                    # Secret key and config (do not commit)
├── .gitignore
├── wit/                    # WIT interface definitions for WASM components (developer reference)
│   ├── reagent/
│   ├── catalyst/
│   └── formula/
├── aqua/                   # AQUA agent template (agent.json + role prompts) every athanor is given
└── data/                   # ALL runtime state — one directory, .gitignored
    ├── cyfr.db             # Connections, consents, execution records
    ├── cache/              # Immutable cached artifacts (OCI blobs)
    ├── system/             # Server-internal scratch (health probes)
    ├── mcp-bridge/         # The mcp-bridge sidecar's own files (not managed by cyfr)
    └── athanors/           # One tree per athanor — Home, then each person's and group's
        └── <athanor id>/
            ├── components/ # {type}s/{publisher}/{name}/{version}/
            │   ├── catalysts/   # local: files, http · moonmoon69: claude, openai, gemini, …
            │   ├── reagents/    # Your local reagents
            │   ├── formulas/    # Bundled formulas: list-models, aqua
            │   └── tinctures/   # Bundled example tinctures + your own
            ├── aqua/       # The athanor's own AQUA agent definitions
            ├── builds/     # Build records
            ├── config/     # Retention settings and other per-athanor config
            ├── conversations/  # Chat attachment files
            └── guest/      # Files WASM components store (their `data/` scope)
```

> The seed bundle every athanor starts from rides inside the container image
> (`CYFR_BUNDLE_PATH`) and is read in place — a scaffolded project carries no
> `components/` directory. Your own components live inside your athanor's
> tree under `components/`.

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
`local` publisher and register from the packaged tree when you run
`cyfr register`. The `moonmoon69` API catalysts are **not** bundled: they
arrive from the registry, normally pulled automatically as dependencies at
register time, or explicitly with `cyfr pull`. Use `cyfr list` / `cyfr search`
to see what's available, then grant one:

```bash
# Pick a connection for each thing the component needs, and approve it
cyfr profile grant c:moonmoon69.claude

# Run it
cyfr run c:moonmoon69.claude

# Install another component from the registry
cyfr pull c:moonmoon69.supabase
```

`cyfr profile grant` walks the consent flow: it shows what the component
asks for, lets you pick a connection for each need, renders exactly what
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

The development loop is: **edit source → `cyfr build compile <ref>` → `cyfr run <ref>`**. Each compile saves the `.wasm` binary, auto-registers the component, cleans build artifacts, and pulls any missing dependencies.

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
open http://localhost:4000/a/home/tinctures

# Make it publicly reachable at /t/home/local/stock-dashboard
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

Header values support vault references (`vault:CONNECTION_NAME`) — the named Connection's
single field is resolved at request time, so credentials stay encrypted at rest and never
appear in the server config.

## Deploy to a Server

CYFR is self-hosted as a small `docker compose` stack:

| service | what it is |
|---|---|
| `cyfr` | the one endpoint on `:4000`: Prism (chat + console, a PWA), API, MCP, tinctures |
| `mcp-bridge` | the HTTP MCP gateway. Wraps stdio/`npx` MCP servers (filesystem, github, …) behind one endpoint and surfaces their tools through cyfr. Built locally from `Dockerfile.node`; backends live in `./data/mcp-bridge/backends.json` |
| `caddy` *(profile: `tls`)* | TLS terminator + reverse proxy in front of `cyfr:4000`. Started only when `CYFR_BEHIND_PROXY=true` in `.env` |

Two modes:
- **Direct** (local): cyfr + mcp-bridge. Prism at `http://localhost:4000/`.
- **TLS** (VPS with a hostname): also runs caddy (`--profile tls`). Prism at `https://<CYFR_HOST>/`.

`cyfr init` prompts which mode you want and writes the right value into `.env` (`CYFR_BEHIND_PROXY`). `cyfr up` reads `.env` and toggles the `tls` profile automatically.

There is **no censorship-circumvention layer** here — Caddy gives you TLS, not unblockability; if your network actively blocks endpoints, put this stack behind a separate obfuscated transport.

### Prerequisites

- A Linux VPS (or any Docker host) with Docker + the Compose plugin.
- For TLS mode: a domain pointing at the VPS. For direct mode: nothing extra.
- Firewall: TLS mode → open `80/tcp`, `443/tcp` (+ `443/udp` for HTTP/3). Direct mode publishes `:4000` on `127.0.0.1` only — it is for the box you run it on.

### Setup

Use the `cyfr` CLI — it downloads `docker-compose.yml` + `Caddyfile`, writes `.env` (generates `CYFR_SECRET_KEY_BASE`, prompts for `CYFR_HOST` / `CYFR_PLATFORM_ADMIN_EMAILS` / TLS y/n / `CADDY_ACME_EMAIL`), and brings the stack up:

```bash
# Install the CLI (the installer/cask install the CLI only, not Docker):
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#   …or:  brew tap cyfrworks/cyfr && brew install --cask cyfr

mkdir my-cyfr && cd my-cyfr
cyfr init        # downloads compose + Caddyfile, writes .env, asks the TLS y/n question
cyfr up          # starts cyfr + mcp-bridge (and caddy if TLS mode)
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
#   CADDY_ACME_EMAIL     — your email (only needed for TLS mode)

# Direct:
docker compose up -d
# TLS:
docker compose --profile tls up -d
```
</details>

Then open `https://<your-domain>/` (TLS) or `http://localhost:4000/` (direct), sign in, and you're in your athanor's chat. "Add to Home Screen" installs it as a PWA (works on phones too). In TLS mode caddy proxies everything to `cyfr:4000` — Prism, `/api`, `/mcp`, `/auth` and `/t` on the same origin. The `cyfr` endpoint (`:4000`) is always published on `127.0.0.1` so the `cyfr` CLI and a local browser work from the host.

**Upgrading.** `cyfr update` pulls the latest images, then `cyfr up`. From a source checkout: `docker compose pull && docker compose up -d` (add `--profile tls` if you're running with caddy). Check the [release notes](https://github.com/cyfrworks/cyfr/releases) first.

### Wrapping stdio / npx MCP servers (filesystem, github, …)

CYFR can only register **HTTP** MCP servers. To use a stdio MCP server (anything that launches with `npx -y …`), the `mcp-bridge` container wraps it: it spawns the child process and exposes a single HTTP MCP endpoint that surfaces all the children's tools, prefixed by backend name.

Prism wires this up for you:

1. Open **MCP Servers** in the sidebar, click **+ Setup MCP Bridge**. That registers the gateway with CYFR (one external MCP entry named `bridge`, URL `http://mcp-bridge:8001/mcp` resolved inside the compose network — the browser never connects to it directly).
2. Below the server list, a **Bridge backends** section appears. Click **Add backend**, pick a name (e.g. `fs`) and a command (e.g. `npx -y @modelcontextprotocol/server-filesystem ./data`).
3. The child boots, its tools surface as `bridge:fs__read_file`, `bridge:fs__write_file`, … on CYFR's tool list. AQUA agents can use them like any other external MCP tool.

Backends persist to `./data/mcp-bridge/backends.json` so they survive container restarts. Remove or restart them from the same page.

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
with one exception: a server (release) deployment must set the CORS
allowlist, because sign-in is enabled by default. Each option is set in
`.env` (see the matching blocks in `.env.example`) and fails loud: if an
option is enabled but incompletely configured, the server refuses to start
rather than silently falling back.

### CORS allowlist (required for server deployments)

A release refuses to boot when authentication is configured (it is by
default) while CORS still allows every origin — that combination would let
any website make credentialed cross-origin requests. Set the allowlist to
the origin(s) your browser clients are served from:

```bash
CYFR_CORS_ALLOWED_ORIGINS=https://app.example.com
```

Comma-separate multiple origins. An empty value allows no cross-origin
callers at all; same-origin traffic (Prism on the same host) never needs
CORS. Local `mix phx.server` runs only warn, so development is
unaffected.

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
matter. They are all optional and **off unless set**; a private box needs
none of them.

| Variable | Bounds |
|---|---|
| `CYFR_MAX_ATHANORS` | athanors on this server, active ones only — an archived furnace frees its place |
| `CYFR_MINT_PER_HOUR` | personal athanors minted per hour, i.e. how fast strangers can arrive |
| `CYFR_MAX_GROUPS_PER_PERSON` | groups one person may **create** (they may belong to more) |
| `CYFR_MAX_MEMBERS_PER_GROUP` | seats in one group, invitations included |
| `CYFR_ATHANOR_STORAGE_BYTES` | bytes one athanor may hold — its data *and* its components, the seeded bundle included |

Every athanor is minted with its own copy of the component bundle, so
`CYFR_MAX_ATHANORS` and `CYFR_ATHANOR_STORAGE_BYTES` are what bound the disk.
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
Release-only variables move the pieces:

```bash
CYFR_DATA_PATH=data                     # the one storage root; the SQLite
                                        # database defaults to cyfr.db inside it
CYFR_BUNDLE_PATH=components/_bundle     # the seed bundle, read in place
                                        # (the container image sets its own)
CYFR_AQUA_TEMPLATE_PATH=aqua            # the AQUA agent template, read in place
                                        # (the image points it at /app/aqua)
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
| SQLite (default) | `./data` (database, encrypted secrets, every athanor's components and files, caches, mcp-bridge config) | Stop the stack (`cyfr down`), copy `./data`, restart. Copying while running risks a torn SQLite snapshot. |
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
| `cyfr init` | Scaffold a CYFR project — downloads `docker-compose.yml` + `Caddyfile`, writes `.env` (asks the TLS y/n question), creates dirs (`--force` re-fetches the deploy files; never touches `.env`) |
| `cyfr up` / `cyfr down` | Start / stop the stack (cyfr + mcp-bridge, plus caddy when `CYFR_BEHIND_PROXY=true` in `.env`) |
| `cyfr upgrade` | Upgrade the CYFR Codex binary (system-wide) |
| `cyfr update` | Pull the latest stack images (cyfr, caddy when TLS) and refresh managed scaffold (guides, `wit/`, bundled `aqua/` prompts); leaves your `.env`, `docker-compose.yml`, `Caddyfile` alone |

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
| `cyfr profile grant <ref>` | Grant a component the connections it needs `[i]` |
| `cyfr profile list <ref>` | Show a component's profiles and consent revisions |
| `cyfr profile revoke <id>` | Revoke a profile, effective on the next run |
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
| `cyfr tincture visibility set <publisher> <name> <true\|false>` | Control whether a tincture is public at `/t/<athanor>/<publisher>/<name>` |

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
| `cyfr call vault '{"action":"list",…}'` | Manage Connections (encrypted credentials): create/rename/rotate/rebind/revoke/delete, `authorize` for OAuth — also in the console's Connections page |
| `cyfr key create/list/get/revoke/rotate` | Manage API keys `[i]` |
| `cyfr call oauth '{"action":"set_client",…}'` | Store an OAuth app's client credentials per provider; user grants run through `cyfr profile grant` and the console's Connections page |

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
