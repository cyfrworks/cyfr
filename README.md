<p align="center">
  <img src="apps/cyfr/priv/static/images/logo.png" alt="CYFR" width="200" />
</p>

<p align="center">CYFR is said <em>cipher</em>.</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-alpha-orange" alt="Status: alpha" />
</p>

Status: alpha. CYFR works end to end and is tested hard, but between releases a schema change can mean recreating your database, behaviour changes without a compatibility layer, and there is no support promise. Read the release notes before upgrading.

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
- **Prism** — the web face, served by CYFR on its one endpoint (`:4000`, or `/` behind Tailscale Serve or Caddy) and installable as a PWA: the chat with **AQUA** — your friendly assistant — one zone across every athanor you belong to (a shared thread every member of an athanor sees, with approvals any member can decide), your own AQUA in a panel on every page, each athanor's AQUA page, and the developer views — executions, components, builds, activities, enforcements, the vault, API keys, schedules, MCP servers, tinctures.

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

# The installer takes the newest release that is not a pre-release; CYFR_VERSION
# names any release, pre-releases included. The installer needs
# cosign (`brew install cosign`) to verify the release's signature; without
# it, CYFR_ALLOW_UNVERIFIED=1 verifies the archive's checksum alone.
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=0.6.0-alpha.1 sh

# Or via Homebrew (macOS), which installs the newest release that is not a pre-release
brew tap cyfrworks/cyfr
brew install --cask cyfr

# Initialize a project
mkdir <project-directory>
cd <project-directory>
cyfr init

# Start the server
cyfr up

# Open Prism, your athanor's chat, and sign in there
cyfr open

# Sign this command line in: approve it in Prism
# (cyfr login --provider github signs in without Prism)
cyfr login

# Scan bundled components and auto-pull their dependencies
cyfr register

# Grant a component the vault entries it needs
# (or use the console's Vault page)
cyfr profile grant c:local.claude

# Learn more about other commands
cyfr -h
```

`cyfr init` downloads your project files and pulls the server images: `docker-compose.yml`, `Caddyfile`, `keeper.seccomp.json` (the `locus-runtime` service's seccomp profile), `.env.example` and the services' own env examples, `cyfr.yaml`, WIT interface definitions, the `aqua/` soul, roles and scrolls, and the included guides ([configuration-guide.md](configuration-guide.md), [integration-guide.md](integration-guide.md), [component-guide.md](component-guide.md), [tincture-guide.md](tincture-guide.md), [identity-guide.md](identity-guide.md), [devices-guide.md](devices-guide.md)). It writes `.env` from `.env.example`, asking first how CYFR is reached (your devices via Tailscale, a public domain via Caddy, or this computer only) and then the operator's sign-in email (the first platform admin), and mints the stack's keys into it: `CYFR_SECRET_KEY_BASE`, `CYFR_LOCUS_BACKENDS_KEY`, the runtime root `CYFR_LOCUS_RUNTIME_ROOT` with the `LOCUS_RUNTIME_KEY` derived from it, and `CYFR_LOCUS_BUILDS_KEY` beside `CYFR_LOCUS_BUILDS_URL`, so builds are on. Pass `--no-interactive` to take the defaults. It does not install Docker itself. The scaffolded `docker-compose.yml` is the full self-hosted stack — `cyfr` (the one endpoint on `:4000`: Prism, API, MCP, tinctures), `locus-runtime` (the runtime that runs components), `locus-builds` (the builds service behind `cyfr build compile`), `locus-backends` (the backends service that runs stdio MCP servers), and the proxy that lets other devices reach CYFR: `tailscale` (Tailscale Serve, for tailnet access) or `caddy` (TLS and the reverse proxy at `:80`/`:443`, for public access); `cyfr up` brings up the first four, and the proxy CYFR's access mode selects. See [Deploy to a Server](#deploy-to-a-server) for the same stack on a VPS.

## Prism — the web face

**Prism** is CYFR's one web face, at `http://localhost:4000` (the same origin as the API — one endpoint, one login), and it is chat-first: `/` lands in your athanor's chat with **AQUA**. A person's athanor is your thread with your own AQUA — the same thread on your phone and your laptop. A group athanor is a group chat every member sees, with approval cards any member can decide; whether a line starts AQUA is derived, never configured: an athanor with one person in it answers every message, and any room with two or more answers only an `@mention`, so people can talk to people. Your own AQUA rides along in a floating panel on every page — a private thread in your own athanor that reads the room you have open and whose answers you paste into the room yourself — a DM is a small frozen athanor minted by clicking a person in the chat rail (anyone you share an athanor with is there; it ends when either person leaves — clicking again starts a new, empty one), following a thread decides your sidebar and notifications (never access), and a line from your private thread reaches a group only when you say it aloud — a deliberate, attributed copy. Sign in on a phone and "Add to Home Screen" — Prism installs like a native app.

Around the chat:

- **The chat** — one page, `/chat`: a rail of your own thread, your DMs, and the threads of every group you belong to (`/chat?a=<athanor>&c=<thread>` deep-links one). The athanor's **AQUA** page at `/a/<athanor>/aqua` holds the soul, its roles, its scrolls, the pinned page and the notes drawer. What AQUA keeps out of a thread is a note — the `notes` tool's `keep`, `pin`, `list`, `read`, `search`, `forget` and `endorse` (a person's click making a note kept after outside reading their own) — and a schedule with `keep_outcome` in its metadata files each run's output as one.
- **The switcher** — You, then the groups you belong to (hidden as a list when it is only you), each row badged with what happened there while you were elsewhere. The one create is **New group…**.
- **The drawer** — off the chat, on every screen size: **AQUA**, **Apps** (tinctures), **Files**, **Members**, **Vault**, **Schedules**, **Webhooks**, **MCP Servers**, **Settings**, **Legal**. Connect a model to AQUA from **AQUA** — the system layer's grant sheet binds an entry to the model's catalyst. The shipped model catalysts name their connection on each request; CYFR attaches the key in the host, and the catalyst receives no key.
- **Canvases** — **Apps** in the drawer (`/a/<athanor>/tinctures`) is the shell: your canvases, each your own page, written in HTML, CSS and JavaScript like any app and showing what it reads, with the apps you open over them. Move between canvases with the canvas switcher, Ctrl+Alt+←/→ or a swipe along the bottom edge; only the canvas you are looking at reads and acts. A canvas changes nothing in CYFR, and what it reads can leave your browser as any app's can. Ask AQUA for a canvas and it writes one (`canvas.write`) as a new version, which your browser validates before it shows it, keeping the version it replaces. A **feed** runs one operation of an installed component on an interval, and a canvas reads its results by the feed's name; AQUA always asks before it binds one, and the **Schedules** page lists and removes them. A canvas that does not start or that fails, or Ctrl+Alt+S, opens safe mode, which offers the canvas again, its kept version or the shipped canvas.
- **`lite` / `dev`** — a per-person preference in Settings, not an edition. `dev` adds the developer views — **Executions**, **Activities**, **Enforcements**, **Components**, **Builds**, **Registry**, **API Keys**, **Reports** — in a sidebar with live indicators; the ops surface stays reachable in `lite`, it just isn't the face. `lite` is the default when the server has an auth provider; operators and private boxes start in `dev`.
- **⌘⇧K** — the command palette, also from the drawer's Search… row.

Tinctures can stay private inside Prism, or be made public and shared at CYFR's address, `<address>/t/<athanor>/<publisher>/<name>`: `http://localhost:4000` with local access, which only its own computer reaches; `https://<machine>.<tailnet>.ts.net` with tailnet access, which your tailnet's devices reach through Tailscale Serve; and `https://<your domain>` with public access, through Caddy under a certificate it obtains over ACME. See [Deploy to a Server](#deploy-to-a-server). A canvas is never public: it is your own data page, so no public profile is staged for one and the public route serves none.

## Project Layout

After `cyfr init`, your project looks like this:

```
your-project/
├── configuration-guide.md # Every setting the server reads, with its default
├── integration-guide.md   # How to use CYFR as your app backend
├── component-guide.md      # Full guide to building components
├── tincture-guide.md       # Guide to building tinctures
├── identity-guide.md       # Your identifier, keys and printed kit, restore, and joining another CYFR
├── devices-guide.md        # Pairing devices and confirming sensitive changes
├── docker-compose.yml      # Self-hosted stack: cyfr, locus-runtime, locus-builds, locus-backends (+ tailscale for tailnet access, caddy for public access)
├── Caddyfile               # The reverse proxy of public access: everything → cyfr's proxy listener
├── keeper.seccomp.json     # The seccomp profile the locus-runtime service runs under (see "Execution workers")
├── cyfr.yaml
├── .cyfr/                  # How CYFR is reached, as `cyfr` keeps it: the stack's lock, the change in flight and recent outcomes (git-ignored; no snapshot holds it)
├── .env                    # The stack's keys and config, written by `cyfr init` (do not commit)
├── .env.example            # The starting .env: init's keys and the deployment choices
├── .env.locus.example      # The Locus services' own settings, one file for every role (copy to .env.locus)
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
            ├── staging/    # Content staged for a fenced publication — host-only, by digest
            ├── objects/    # Each guest object's generations — host-only, read through its row
            └── data/       # Files WASM components store — their `data/` scope, and yours
```

> Every folder exists from the moment the athanor is provisioned. The Files
> page (and the `file` tool) shows the tree the way a phone shows its files:
> `data/` is yours to fill and clear, `components/` and `aqua/` hold shaped
> units whose files you edit in place, `notes/` and `threads/` are read
> there and managed on their own pages, and the server's own storage
> (`payloads/`, `staging/`, `objects/`, the seed, the cache) is not a folder at all.

On **Files**, pick files under `data/` and choose **Send a copy** to offer
a snapshot to someone you share an athanor with. They accept or decline
it in their **Inbox**, choosing a folder under `data/` in their focused
athanor (the default is `data/inbox/<sender slug>/`). Later edits do not
change the offered bytes. Outgoing offers can be withdrawn until accepted;
acceptance keeps the copy even if the sender later removes theirs. The
Inbox shows copies still landing and a notice when delivery fails.

> The seed bundle every athanor starts from rides inside the container image
> (under `CYFR_SEED_PATH`, mounted so `./aqua` replaces its `aqua/` root) and
> is copied into each athanor when it is provisioned — a scaffolded project
> carries no `components/` directory. Your athanor's copies of the bundle and
> your own components live together in its tree under `components/`.

## Using Components

Components use the format `type:publisher.name:version`. The type can be a shorthand (`c:`, `r:`, `f:`, `t:`) or full name (`catalyst:`, `reagent:`, `formula:`, `tincture:`). Version is optional — omit it and the server resolves to the latest installed version.

```bash
# Versionless (recommended) — resolves to latest installed version
cyfr run c:local.claude

# Tinctures use the same reference format
cyfr inspect t:local.weather-lookup:0.1.0

# Pinned to a specific version
cyfr run c:local.claude:1.4.1

# Search for available components in the registry
cyfr search <query>

# Pull a component and its dependencies from the registry
cyfr pull c:acme.claude
```

Generic catalysts, formulas, and example tinctures ship bundled under the
`local` publisher: each athanor gets its own copy when it is provisioned,
and a newer shipped version is offered on the Components page and pulled
with `cyfr pull c:local.<name>`. Components from other publishers arrive from
the registry with `cyfr pull`. Use `cyfr list` / `cyfr search`
to see what's available, then grant one:

```bash
# Pick a vault entry for each thing the component needs, and approve it
cyfr profile grant c:local.claude

# Run it
cyfr run c:local.claude

# Install another component from the registry
cyfr pull c:acme.supabase
```

`cyfr profile grant` walks the consent flow: it shows what the component
asks for, lets you pick a vault entry for each need, renders exactly what
you are approving, and records it as an immutable consent revision. A grant
covers every release of that component line by default; grant a specific
version to pin it. `cyfr profile list <ref>` shows what is granted, and
`cyfr profile revoke <id>` takes it back, effective on the next run.

The **Vault** page stores each entry with the hosts, scheme, port, methods
and paths it may be sent to. Entries are attach-only by default; disclose
one only when a component must read its fields. A provider's default
suggests a choice on the grant sheet and binds nothing by itself. Each
binding has its own lifetime: standing, until a time, or once under one
root run. Platform admins offer attach-only instance entries on **Settings**,
with an audience, method and path bounds and request caps; members choose
them through the same grant sheet. Entering or rotating a key, or widening
who may use an instance entry or its `shipped` policy to `any`, requires
fresh confirmation.

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

**Data.** Tinctures are self-contained frontends — CYFR serves their web content, not a database. Pull backend data at runtime by calling formulas or catalysts through the injected `cyfr` SDK; if you need static seed data, ship a JSON file (or any served type) as a static asset and read it client-side.

**SDK.** The `cyfr` SDK is injected into every tincture's entry page — no script tag needed. The shell hands each frame a credential of its own; the SDK sends it to the endpoint as a bearer, and reaches only what the manifest declares:

```javascript
// Invoke a declared component: it runs with {"operation": "quote", "params": {...}}
const { status, output } = await cyfr.invoke("c:local.my-api", "quote", { symbol: "AAPL" });

// A declared system action, and a declared stream (close() ends it)
await cyfr.action("tool.action", {});
const feed = await cyfr.stream("mcp_servers.changes", null, ({ event, data }) => console.log(event, data));
feed.close();

// Shell verbs: title, close, open another tincture; ready when loaded. A secret
// is typed into the shell, never the page: cyfr.credential(name) resolves with {saved}
cyfr.title("Stock Dashboard");
cyfr.ready();
```

A public tincture opened at its address makes the same calls with no credential, under its public profile. The [Tincture Guide](tincture-guide.md) is the full reference.

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
appear in the server config. The entry's destination must cover the server's URL: a
definition whose header names an entry it does not cover is refused at create, at update
and again when it connects. A definition names only its own athanor's entries,
never an instance entry.

## Deploy to a Server

CYFR is self-hosted as a small `docker compose` stack:

| service | what it is |
|---|---|
| `cyfr` | the one endpoint on `:4000`: Prism (chat + console, a PWA), API, MCP, tinctures; its host API on `:4300` takes the runtime's host calls, signed with a runtime worker's key, from the `locus-runtime` network alone |
| `locus-runtime` | the runtime: runs WASM components as cyfr assigns them, each subtree in a runner VM under a uid of its own, on its own `locus-runtime` network that only cyfr joins, holding one derived key and no tenant state. Built from `Dockerfile.locus`; see [Execution workers](#execution-workers) |
| `locus-builds` *(profile: `locus-builds`)* | the builds service: compiles components and tinctures, each build under a uid and a memory bound of its own, on its own `locus-builds` network that only cyfr joins, holding one builds key and no tenant state. The `cyfr-locus` image, built from `Dockerfile.locus`. Started when `CYFR_LOCUS_BUILDS_URL` in `.env` names it, as `cyfr init` writes it; see [Builds](#builds) |
| `locus-builds-guard` *(profile: `locus-builds`)* | the builds island's egress guard: the same `cyfr-locus` image running `cyfr-guard`, holding `NET_ADMIN` alone, in a network namespace of its own that `locus-builds` runs in, so a build reaches public hosts and the private hosts `CYFR_PRIVATE_EGRESS_TARGETS` names and nothing else; the builder starts only once the guard is healthy, with every rule installed |
| `locus-backends` | the backends service: runs the stdio/`npx` MCP servers (filesystem, github, …) an athanor adds, each backend under a uid and a memory bound of its own, and serves their tools to cyfr, on its own `locus-backends` network that only cyfr joins, holding one backends key and no state. The same `cyfr-locus` image with the backend pool; see [Stdio / npx MCP servers](#stdio--npx-mcp-servers-filesystem-github-) |
| `locus-backends-guard` | the backends island's egress guard: the same `cyfr-locus` image running `cyfr-guard`, holding `NET_ADMIN` alone, in a network namespace of its own that `locus-backends` runs in, so a backend reaches public hosts and the private hosts `CYFR_PRIVATE_EGRESS_TARGETS` names and nothing else; the service starts only once the guard is healthy, with every rule installed |
| `caddy` *(profile: `public`)* | TLS terminator and reverse proxy of public access, forwarding to cyfr's proxy listener. Started only when `CYFR_ACCESS=public` in `.env` |
| `tailscale` *(profile: `tailnet`)* | Tailscale Serve for tailnet access: HTTPS at the machine's tailnet name, forwarding to cyfr's proxy listener; its loopback SOCKS5 proxy lets this device's own browser reach that address. Started only when `CYFR_ACCESS=tailnet` in `.env` |

Three ways CYFR is reached, `CYFR_ACCESS` in `.env`:
- **local**: this computer only. Prism at `http://localhost:4000/`.
- **tailnet**: your devices on Tailscale; also runs tailscale (`--profile tailnet`). Prism at `https://<machine>.<tailnet>.ts.net/`.
- **public**: a domain, for anyone who signs in; also runs caddy (`--profile public`). Prism at `https://<your domain>/`.

`cyfr init` asks which one you want and writes it into `.env` with every setting it implies: the address, and the tailnet machine or the certificate email. [`cyfr access <mode>`](#how-cyfr-is-reached) changes it later, and `cyfr access status` shows it. `cyfr up` selects the proxy's profile from `CYFR_ACCESS`, and the `locus-builds` profile when `CYFR_LOCUS_BUILDS_URL` names the builds service, which it does after `cyfr init`. Whatever the mode, cyfr serves on its loopback listener, `:4000` on this machine's loopback alone; tailnet or public access adds the proxy listener its proxy forwards to, which no port publishes.

There is **no censorship-circumvention layer** here — Tailscale and Caddy give you TLS, not unblockability; if your network actively blocks endpoints, put this stack behind a separate obfuscated transport.

### Prerequisites

- A Linux VPS (or any Docker host) with Docker + the Compose plugin: **Docker Engine 28 or later on a cgroup v2 host** (cgroup v2 is the default of current distributions and of Docker Desktop). `locus-runtime`, `locus-builds` and `locus-backends` hold every runner, build and backend to a memory bound of its own, a cgroup `cyfr-locus` makes for it, which needs the containers' `security_opt: writable-cgroups=true` (in the shipped `docker-compose.yml`; it adds no capability). Without it — an older engine, a cgroup v1 host, or the option removed — nothing runs unbounded and nothing runs: `locus-runtime` starts no runner and logs, naming `writable-cgroups=true`, that it cannot bound one, so no component runs; every build is refused as `unavailable`, naming the option; and every backend's spawn is refused as `memory_unavailable`, which its status reports.
- A host that allows unprivileged user namespaces, and `locus-runtime` under the shipped seccomp profile: every runner gets a user and network namespace of its own (see [Execution workers](#execution-workers)).
- For public access: a domain pointing at the VPS. For tailnet access: a Tailscale account. For local access: nothing extra.
- Firewall: **public** opens `80/tcp`, `443/tcp` (+ `443/udp` for HTTP/3). In every mode CYFR publishes `4000/tcp` on `127.0.0.1` only (`CYFR_PORT` changes it). With **tailnet** access, CYFR also publishes SOCKS5 `1055/tcp` on `127.0.0.1` only, for the device's own browser; it opens no port to other machines. This is a general proxy on this machine's loopback for the device's own browser; a program on this machine can reach through it whatever the sidecar can reach.

### Setup

Use the `cyfr` CLI — it downloads `docker-compose.yml` + `Caddyfile`, writes `.env` (asks how CYFR is reached, then your email, and mints the stack's keys), and brings the stack up:

```bash
# Install the CLI (the installer/cask install the CLI only, not Docker):
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#   …or:  brew tap cyfrworks/cyfr && brew install --cask cyfr

mkdir my-cyfr && cd my-cyfr
cyfr init        # downloads compose + Caddyfile, asks how CYFR is reached, writes .env and its keys
cyfr up          # starts cyfr + locus-runtime + locus-builds + locus-backends (and the proxy of tailnet or public access)
```

`cyfr init` mints every key the stack needs into `.env`: `CYFR_SECRET_KEY_BASE`, `CYFR_LOCUS_BACKENDS_KEY`, the [execution worker](#execution-workers)'s root `CYFR_LOCUS_RUNTIME_ROOT` with the `LOCUS_RUNTIME_KEY` derived from it for the worker's service id (`wrk_locus` unless `.env` names another `LOCUS_RUNTIME_SERVICE_ID`), and the [builds](#builds) key beside `CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100`. It also assigns [`CYFR_CORS_ALLOWED_ORIGINS`](#cors-allowlist) the empty allowlist, which admits no cross-origin caller and which the shipped stack's same-origin clients never notice. Run in a project whose `.env` already exists, it adds only the keys `.env` lacks and never rewrites one: with no root and no service key it mints both, with a root alone it derives the service key from it, a builds URL gets a minted key and a builds key gets the URL. A service key with no root beside it, or one the root beside it does not derive, is refused with a sentence naming the fix, and nothing is written.

<details><summary>Prefer a source checkout?</summary>

```bash
git clone https://github.com/cyfrworks/cyfr && cd cyfr
cp .env.example .env
# edit .env:
#   CYFR_SECRET_KEY_BASE — `openssl rand -base64 48` (at least 64 bytes; a blank or shorter value refuses the boot)
#   CYFR_ACCESS, CYFR_HOST — local and localhost, as .env.example has them;
#                          `cyfr access tailnet|public` writes another mode's settings
#   CYFR_PLATFORM_ADMIN_EMAILS — your email (platform admin; required to access the instance)
#   CYFR_LOCUS_BACKENDS_KEY — `openssl rand -hex 32`
#   CYFR_LOCUS_RUNTIME_ROOT      — `openssl rand -hex 32`
#   LOCUS_RUNTIME_KEY     — `env CYFR_LOCUS_RUNTIME_ROOT=… mix cyfr.locus.runtime_key wrk_locus`
#                          (see "Execution workers" for the openssl equivalent)
#   CYFR_LOCUS_BUILDS_URL — http://locus-builds:4100 (see "Builds")
#   CYFR_LOCUS_BUILDS_KEY — `openssl rand -hex 32`

# with the CLI, as for any CYFR:
cyfr up
# …or, for local access without it, outside the supported path (see "How CYFR is reached"):
docker compose --profile locus-builds up -d
```
</details>

Then open the address `cyfr up` prints (`http://localhost:4000/` with local access), sign in, and you're in your athanor's chat. "Add to Home Screen" installs it as a PWA (works on phones too). With tailnet or public access the proxy forwards everything to cyfr's proxy listener — Prism, `/api`, `/mcp`, `/auth` and `/t` on the same origin. The `cyfr` endpoint (`:4000`) is always published on `127.0.0.1` so the `cyfr` CLI and a local browser work from the host.

**Setting up on a device.** On a machine with a screen of its own and no keyboard, such as a small touch-screen device, `cyfr setup` does what `cyfr init` and `cyfr up` do, from pages on that screen. It serves them on `127.0.0.1` before anything of the stack runs, prints their address, writes it to `.cyfr/setup.url` and, on a machine with a display, opens them in the default browser; `--no-open` leaves that to the device's launcher. Nothing off the machine reaches them. The pages ask how CYFR is reached (your phone and laptop via Tailscale, only this device, or a public domain) and your email, which makes you the administrator, then write `.env`, join and start CYFR with `cyfr init`'s and `cyfr up`'s own steps. With tailnet access, the join shows its approval link as a QR code to scan with your phone and as text with a Copy button, and under it the machine's name, `cyfr` unless you change it there. A join that fails, or a start that fails, says why and offers to try again or to start CYFR on this device only. Once CYFR is up the pages show its address, with a Copy button, and open it, apart from a `ts.net` address: that opens on your other devices on the tailnet, and on the device itself in a browser that uses CYFR's SOCKS5 proxy on `127.0.0.1:1055` (below). `cyfr setup` then stops. In a project that already has a `.env` it refuses, and `cyfr access` changes how that CYFR is reached.

**Upgrading.** `cyfr update` is the one command for it: it brings the `cyfr` program to the newest release, then the CYFR in the current directory to the program's release, and two releases never run side by side on one database.

- **The program.** When a release newer than this `cyfr` is published, `cyfr update` installs it, through `brew` for a Homebrew cask install; any other install downloads the release's archive for this platform, verifies it against the release's `checksums.txt` signed by the release workflow for that tag, and only then replaces its own file. It then goes on as the new program, so the one command finishes the job. Pre-releases (`0.6.0-alpha.1`, `1.0.0-rc.2`) are never chosen this way: `cyfr update --version <version>` installs exactly the release it names, a pre-release or an older release included, and the install script does the same with `CYFR_VERSION=<version>`. A Homebrew install takes only its tap's release, the newest that is not a pre-release. In a directory that holds no CYFR, `cyfr update` stops after the program.
- **CYFR.** In CYFR's directory it then fetches the release's `release.json` and its signature and verifies them: signed keyless by the release workflow of that version's tag, naming that version. Without network access to the release, or with a manifest that does not verify, it refuses and changes nothing, as it refuses a `docker-compose.yml` that lacks a service of the bundled stack (`cyfr init --force` regenerates the file and keeps `.env`). It then shows the release CYFR is on, each image line that changes and where the release notes are, and asks before changing anything (`--yes` makes the change without asking; with no terminal and no `--yes` it shows the change and makes none). A CYFR already on the program's release is left alone, with no stop and no snapshot. A CYFR on a newer release than the program, by its compose file's tags or by the release its running cyfr reports, is refused before anything stops, since older code never starts over a database a newer release migrated: restore a snapshot of the older release instead. Once confirmed, in order, it:

1. pulls every image the manifest names by its digest, and fetches and verifies the release's managed scaffold files without writing them, while the stack still runs; a failed pull changes nothing. It names the storage root it will snapshot as compose resolves it. On PostgreSQL it first reads the server's major through a client image the CLI pins by digest, one for each of PostgreSQL 14 to 18, and pulls the pin of that major for the dump; a server of another major refuses the update before anything changes;
2. refuses while a server of the [cluster](#several-servers-on-one-database-a-cluster) on another release than this one runs outside this stack;
3. cancels a tailnet join waiting for approval, stops every service, printing how long each took (the update holds the stack's lock, `.cyfr/lock` in the project directory, from before its first docker call to its end, as `cyfr restore` and `cyfr access` do, and `cyfr up` holds it across its own start: `cyfr up` refuses while an update runs, and an update refuses while a start runs), and reads the cluster's slots with the server stopped: any server of another release still holding one after a lease (15 s) starts the old stack again and ends the update;
4. copies the cluster into `backups/<timestamp>/`: the database (the SQLite file, or a `pg_dump` in the PostgreSQL server's own major version), the storage root, every managed scaffold file the release replaces as it stood (part `scaffold`, the keeper's seccomp profile among them), the keyring, `.env` and `docker-compose.yml` as it stood (part `compose`), with `snapshot.json` written last, so a backup without it is incomplete. `backups/` ignores itself for git, since a snapshot holds the keyring; An object store (`CYFR_STORAGE=s3`) is outside the snapshot: it relies on the bucket's own versioning;
5. writes the managed scaffold files, putting them back from the snapshot and starting the old stack again if that or the next step fails, rewrites the `image:` lines naming `ghcr.io/cyfrworks/cyfr`, `ghcr.io/cyfrworks/cyfr-locus`, the bundled caddy and the bundled tailscale to the release's version and digest (caddy and tailscale keep their tags), leaving and reporting any other image, then starts the stack and waits for readiness. A release that fails to migrate or start leaves the stack stopped, since old code never starts over migrated bytes, and the update prints the backup's path and `cyfr restore <backup>`.

A server whose release differs from a live server's is refused at boot, naming both releases. `cyfr init` run again in the project adds a key a newer stack needs that `.env` lacks, and changes nothing else. From a source checkout without the CLI: `docker compose --profile locus-builds pull && docker compose --profile locus-builds up -d` (add `--profile public` or `--profile tailnet` for public or tailnet access, and drop the builds profile if builds are off), which is outside the supported path (below). Check the [release notes](https://github.com/cyfrworks/cyfr/releases) first: there is no compatibility layer for behaviour, and a release says what it changes for a running server. A database built from an earlier version of the schema is not carried forward: the server refuses to boot on it and names the database to recreate.

### How CYFR is reached

`cyfr access <mode>` changes how the CYFR in the current directory is reached: `cyfr access local`, `cyfr access tailnet`, or `cyfr access public --domain <your domain>` (and `--acme-email <email>` for the certificate authority's account, if you want one). It shows the change before making it: who can reach CYFR, its address, the certificate email and the ports opened on this machine, each before → after, and what stops working when the address changes. Once you confirm, or pass `--yes`, it stops the stack and checks it stopped, rewrites `.env`, and starts what was running in the new mode. When that start fails, it stops what the new mode started, writes the previous mode back and starts it, and reports what it reached: CYFR running as before (on this machine only, when its tailnet machine is not ready to serve it), CYFR left stopped when the previous mode does not start either, or, when a stop cannot be checked or a write fails, a change to finish with `cyfr access --resume`. `cyfr access status` shows how CYFR is reached, what runs, the proxy's health and the last change's outcome, and changes nothing.

A change holds the stack's lock and keeps its progress in `.cyfr/` in the project directory. When one is interrupted, by a closed terminal or a restart, run `cyfr access --resume`: it finishes the interrupted change under the lock and reports what happened. The next `cyfr up`, `cyfr update`, `cyfr restore` or `cyfr access` does the same before anything else.

A start that leaves CYFR answering on this machine only, because its tailnet machine is not the one `.env` names, has not joined, or has HTTPS certificates off, exits with status 3 and says what to do; Tailscale Serve stays closed until `cyfr access tailnet` serves CYFR on the tailnet again.

**Choose the address once.** Passkeys and paired devices belong to CYFR's address, so a new address, from another tailnet name, another domain or another mode, means registering passkeys and pairing devices again: [devices-guide.md](devices-guide.md#when-cyfrs-address-changes) lists what stops working, as `cyfr access` prints it before it changes the address.

**Tailnet access.** These steps are yours, once:

1. Create a Tailscale account, and install the Tailscale app, signed in, on the phones and computers that will reach CYFR.
2. In the Tailscale admin console's DNS page, turn on MagicDNS and HTTPS certificates. Without HTTPS certificates the machine joins, but CYFR is not served on the tailnet, and `cyfr access tailnet` says what to turn on.

`cyfr init`'s first answer, or `cyfr access tailnet`, then joins this machine to your tailnet: open the link it prints and approve the machine (on a machine with a display `cyfr init` and `cyfr access tailnet` open it in the default browser, unless `--no-open` is given), or join it with an auth key, read from the file `--tailscale-auth-key-file` names and never written to `.env` or a log. CYFR is then at `https://<machine>.<tailnet>.ts.net/`, through the `tailscale` service, with no port opened to other machines. Its SOCKS5 proxy on `127.0.0.1:1055` lets this device's own browser reach the same address through the sidecar. That connection enters through Serve's proxy ingress and carries no loopback-ingress authority.

- **Certificate names are public.** Every HTTPS certificate's name, the machine's full tailnet name included, is published in public certificate logs. Use a randomized tailnet name and a neutral machine name: `cyfr`, unless `--hostname` gives another.
- **The name is the address.** Renaming the machine means registering passkeys and pairing devices again (above). `cyfr access tailnet --new-node` replaces this machine's tailnet identity, so CYFR can take another name; remove the old machine on the admin console's Machines page.
- **Tailscale's hosted service** hands out the tailnet's keys. Tailnet Lock limits that trust, and CYFR's own sign-in applies either way: CYFR reads no Tailscale identity header, so everyone who reaches CYFR still signs in.

**Public access.** `cyfr access public --domain <your domain>` serves CYFR at `https://<your domain>/` through the `caddy` service, which obtains its certificate over ACME. The domain must point at this machine, and ports 80 and 443 must be open (see [Prerequisites](#prerequisites)).

**The supported path.** `cyfr up`, `cyfr access`, `cyfr update` and `cyfr restore` run Docker Compose themselves, with checks of their own. They hold the stack's lock. They clear every `COMPOSE_*` variable from their environment, select the files and profiles from CYFR's settings, and refuse a `.env` that sets a `COMPOSE_*` variable, since Compose would read it to choose the stack's files, project or services behind cyfr's back. They refuse a compose file that sets an access setting in the `cyfr` service's `environment:` or drops its `env_file: .env`. They open Tailscale Serve only once the tailnet machine is the one `.env` names. And they make a change of mode one journaled change, which the next of them recovers if it is interrupted. Running `docker compose` directly is outside that path and skips all of these. The server's own boot check stays either way: a release refuses to start on access settings in `.env` that contradict each other, with the sentence that names the fix.

### Stdio / npx MCP servers (filesystem, github, …)

CYFR reaches an **http** MCP server at its URL. A **stdio** MCP server (anything that launches with `npx -y …`) runs on the `locus-backends` container instead: CYFR tells the backends service what to run and signs every message to it.

Adding one from Prism:

1. Open **MCP Servers** in the sidebar and click **Add stdio server**.
2. Give the server a name (e.g. `github`), a backend name, the command (e.g. `npx -y @modelcontextprotocol/server-github`), and its env, one `NAME=value` per line. A credential is always a vault template — `GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token`, naming a single-field disclosed entry on the **Vault** page (an attach-only entry is refused at create and when the backend starts); only `NODE_ENV`, `LOG_LEVEL`, `TZ`, `LANG`, `LC_ALL`, `NO_COLOR` and `DEBUG` may hold a literal, and a command may never name a vault entry, because every process on the backends service can read command lines.
3. On first use the backends service starts the backend and its tools surface as `github:github__search_repositories`, … on CYFR's tool list. AQUA uses them like any other external MCP tool. A backend that takes longer than 15 s to start (an `npx -y` download, say) has its tools added to the list once it is ready, without a refresh.

From the CLI or MCP, the same server is `cyfr mcp add github '{"transport":"stdio","backends":[{"name":"github","command":"npx -y @modelcontextprotocol/server-github","env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"vault:github-token"}}]}'`; a server may define up to four backends.

Defining or changing a server — `mcp_servers.create` and `update`, http or stdio — takes a signed-in session: Prism, or the CLI after `cyfr login`. A definition decides what the server runs and where it sends the vault entries it names, which is a person's decision like granting a vault entry to a component. An admin API key can list, inspect, test, refresh, restart, enable, disable and delete servers, but defines none.

How it holds together:

- **One key.** `CYFR_LOCUS_BACKENDS_KEY` (32 random bytes as 64 hex digits) is in `.env`; `cyfr init` generates it and compose gives it to `cyfr` and, as `LOCUS_BACKENDS_KEY`, to `locus-backends`. The service refuses to start without it, and cyfr refuses stdio servers without it (and `CYFR_LOCUS_BACKENDS_URL`, which compose sets). It is the only setting the service needs; its limits, timeouts and per-backend memory bound live in `.env.locus` (copy `.env.locus.example`).
- **Nothing on disk.** The backends service persists nothing. CYFR sends a server's definition when the server is first used — its env resolved from the vault and sealed to that server and that service lifetime — and again for every running server when the service restarts. When CYFR restarts, the service releases what the previous boot ran, and each server starts again on its next use. Backends run only while CYFR keeps renewing their lease (30 s; `CYFR_LOCUS_BACKENDS_LEASE_MS` sets it); a server whose backends are slow to start never delays another server's renewal.
- **Idle backends stop.** A backend with no tool call for 15 minutes (`CYFR_LOCUS_BACKENDS_IDLE_MS` sets it) is stopped and its pool slot freed; its tools stay listed, and the next call starts it again — for an `npx -y` package, downloading it again.
- **Isolation.** Each backend runs under a pooled uid of its own (`locus-backend01`…`32`) with a private home directory, an environment built only from its server's env, and no capability. One athanor's backends hold at most a quarter of the pool, and so do the backends of every server one person created, across all their athanors. A server's requests reach only its own backends, and every result is masked with that server's credentials. Each backend is held to a memory bound of its own (`LOCUS_BACKENDS_MEMORY_BYTES`, 512 MiB), ended there alone and restarted. Backends share the network and CPU, and every process on the service, every other athanor's backends included, can read each backend's command line, though never its environment. A credential the program reads from its env stays there; a command that expands a vault-bound env name places the value on its command line, and CYFR saves such a definition and warns about it (see the [integration guide](integration-guide.md#stdio-mcp-servers)).
- **Changes take effect at once.** Updating, disabling, deleting or restarting a server, or rotating, revoking or renaming a vault entry its env names, stops its backends before anything else can reach them; the next use starts them again with the new definition. `mcp_servers.get` shows each backend's status, restarts and a masked stderr tail; **Restart** on the expanded row starts a stdio server's backends afresh.
- Stdio servers are not available when `CYFR_CLUSTER` is on.

### Execution workers

Components run on a worker service, not in `cyfr`: the `locus-runtime` container, Locus's runtime role, runs the WASM engine, and `cyfr` reaches it over HTTP to start and kill runs while the service carries its runners' host calls to `cyfr`'s host API for everything a run needs (its attempt, its credentials, its stream, its children). Every request and host call is authenticated with keys derived from one root, which only `cyfr` holds.

- **Two keys.** `CYFR_LOCUS_RUNTIME_ROOT` (32 random bytes as 64 hex digits) is the root, in `.env` and read by `cyfr` alone. `LOCUS_RUNTIME_KEY` is the key derived from it for the worker's service id, `LOCUS_RUNTIME_SERVICE_ID` (`wrk_locus` by default; another id is named in `CYFR_LOCUS_RUNTIME_WORKERS` too), and compose hands the id and the key to `locus-runtime` alone, from `.env`. `cyfr init` mints the root and derives the key; by hand, the root is `openssl rand -hex 32`, and `CYFR_LOCUS_RUNTIME_ROOT=… mix cyfr.locus.runtime_key wrk_locus` prints the key from a source checkout, or `printf 'cyfr-locus/v1/runtime\nwrk_locus' | openssl dgst -sha256 -mac HMAC -macopt hexkey:$CYFR_LOCUS_RUNTIME_ROOT` is the same HMAC without one. The runtime never sees the root, the keyring or the database; it refuses to start with any of them in its environment, or with the builds or backends key beside its own. Changing the root ends every run in flight and needs every service key derived again: remove `LOCUS_RUNTIME_KEY` beside the new root and `cyfr init` derives it.
- **Who is where.** `CYFR_LOCUS_RUNTIME_WORKERS` lists the worker services `cyfr` dispatches to as `<service_id>=<url>` entries, tried in order; compose sets `wrk_locus=http://locus-runtime:4200`. `cyfr`'s host API listens at `CYFR_HOST_API_BIND:CYFR_HOST_API_PORT` (default `127.0.0.1:4300`; compose binds `cyfr`'s own address on the `locus-runtime` network, so it answers on that network alone, and serves only calls signed with a runtime worker's key) and `LOCUS_RUNTIME_HOST_API_URL` tells the worker where that is. An attempt's host calls go to the server that admitted it: the assignment carries that server's address, `CYFR_HOST_API_URL`, and the worker posts them there. With one server the address is the worker's own `LOCUS_RUNTIME_HOST_API_URL` and nothing more is set. `cyfr` asks each worker for its status every `CYFR_LOCUS_RUNTIME_WATCH_POLL_MS` and, after `CYFR_LOCUS_RUNTIME_WATCH_MISSES` misses in a row or when a worker comes back as a new boot, closes the runs that boot held as lapsed. The runtime's own settings are in `.env.locus` (copy `.env.locus.example`), one file for every Locus role.
- **Runners.** Inside `locus-runtime`, `cyfr-locus` — the keeper binary every Locus role runs under — starts the service as the `locus` user with no capability and runs every subtree in a runner: a VM of its own under a pooled uid (`locus-runner01`…`08`) with a private home directory on a tmpfs, holding no key, reached by the service alone over a control channel. The service runs only under `cyfr-locus`, which hands it the keeper channel: started any other way, a plain `mix` boot included, it refuses to boot, naming `cyfr-locus`, and no setting chooses another launcher. The service keeps `LOCUS_RUNTIME_POOL_SIZE` runners spawned ahead; a runner that completes cleanly is kept idle for its athanor for `LOCUS_RUNTIME_IDLE_TTL_MS`; one that was killed, lost a host answer or exited with attempts open is tainted, never assigned again, and retired — every process of its uid killed and its home directory scrubbed before the uid is reused — with `LOCUS_RUNTIME_RELEASE_GRACE_MS` to report what it held; a guest that ignores its deadline is halted by the runner's watchdog `LOCUS_RUNTIME_WATCHDOG_GRACE_MS` past it. `tests/locus-runtime-image/` runs each of these against the shipped image.
- **No network in a runner.** `cyfr-locus` clones every runner into a user namespace that maps only its own uid and gid, holding no capability, and a network namespace of its own whose loopback is down and which has no route: a runner reaches neither `cyfr`, nor the service's listener, nor the container's loopback, nor anything outside. What a run needs from outside leaves through the runner's relay, a socket to the service: its host calls, which the service verifies against the run's attempt and posts to `cyfr`'s host API, and its guests' outbound requests, for which the service takes the request from the run's rate and connects to the address `cyfr` pinned. The `locus-runtime` network is the service's alone.
- **The seccomp profile and the host.** Docker's default seccomp profile denies the clone that makes those namespaces, so the `locus-runtime` service runs under `keeper.seccomp.json` (Docker's default with that clone allowed and `unshare` and `setns` denied; the image carries it as `/etc/cyfr/keeper.json`). The shipped `docker-compose.yml` names it as `security_opt: seccomp=./keeper.seccomp.json`, which compose reads from the project directory: `cyfr init` and `cyfr update` write it there, and a source checkout copies `apps/locus/keeper/seccomp/keeper.json` there. The host must allow unprivileged user namespaces: `user.max_user_namespaces` above 0, and where AppArmor restricts them (`kernel.apparmor_restrict_unprivileged_userns=1`, as on Ubuntu 24.04 and later) the container keeps Docker's default AppArmor profile, under which the clone is allowed; an unconfined container, a privileged one included, gets a namespace without the ids its runner needs. Without the profile or the host's allowance `cyfr-locus` refuses to start, naming both settings, the service never starts and the container restart-loops.
- **Memory.** Every runner is held to `LOCUS_RUNTIME_MEMORY_BYTES` (384 MiB by default; 16 MiB to 1 TiB): its VM, every guest's linear memory, its home directory and the kernel memory charged to it, together. A runner that reaches it is ended whole by the kernel, the runs it held are reported, and it is never reused; a sibling is untouched. The container's limit, `LOCUS_RUNTIME_MEMORY_LIMIT` in `.env` (4G), holds all eight runner uids at their bound and the service beside them — raise it with the bound. The bound needs the [Docker requirement](#prerequisites) above.
- **One versioned wire.** Every request, host call, answer and exit report carries the wire's version, `"v": 1`, as its first field, and every `x-cyfr-auth` header begins with its version token, `v1`. A listener refuses a header at another version as `unknown_version` before it reads the body, and a body without `v` or at another version as `unknown_version` before it reads the operation, so a worker and a `cyfr` at different versions of the wire refuse each other's work rather than misread it.
- **`cyfr` pins every outbound address.** The engine resolves no name. Before a run's outbound request its runner asks `cyfr` for the address (`egress_pin`), and `cyfr` resolves the host and decides the address under the run's admitted consent: a metadata address is refused before any policy, a private one only under the consent's `egress.private_ips`, and `CYFR_PRIVATE_EGRESS_TARGETS`, the server's own private targets, never applies to a run. The service connects to exactly the pinned address for the runner, keeping the host for TLS and the `Host` header, and streams the answer back through the relay. A redirect's next hop is pinned from the request it came from, and a hop to another scheme or host is refused (`redirect_credentials`), so a request's credentials never follow it to another origin.
- **Nothing on disk.** The worker keeps no state. A run's identity, budget, credentials and output live in `cyfr`; the worker holds only what it was assigned, sealed for its key, and reports a runner that exits. A worker restart ends its runs, which `cyfr` closes as lapsed.

### Builds

`cyfr build compile` runs on the `locus-builds` service, never in `cyfr`: `cyfr` sends a build's sources in a signed request and publishes the result it verifies, and the builder answers with the bytes, their digests and the build's diagnostics. With neither setting below, `cyfr` builds nothing and refuses every build, naming them; it runs no toolchain of its own.

Builds are on after `cyfr init`: it writes both settings into `.env`, and `cyfr up` starts `locus-builds` with the rest of the stack. They need what `locus-runtime` needs anyway, **Docker Engine 28 or later on a cgroup v2 host** (see [Prerequisites](#prerequisites)).

- **One key.** `CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100` and `CYFR_LOCUS_BUILDS_KEY` (32 random bytes as 64 hex digits; `cyfr init` mints it, and by hand it is `openssl rand -hex 32`) in `.env`, both or neither: `cyfr` refuses to boot with one and not the other, or with a malformed value. Compose hands the same key to the builder as `LOCUS_BUILDS_KEY`; the builder refuses to start without it, and with any of `cyfr`'s own secrets in its environment. With the URL set, `cyfr up` starts the service too (`docker compose --profile locus-builds up -d` without the CLI).
- **Turning builds off.** Set both empty in `.env` — `CYFR_LOCUS_BUILDS_URL=` and `CYFR_LOCUS_BUILDS_KEY=` — then `cyfr down` and `cyfr up`: `locus-builds` does not start, and `cyfr` refuses every build. `cyfr init` leaves a URL set empty with no key alone; with the two lines removed or commented out instead, `cyfr init` leaves builds off too.
- **Isolation.** Inside `locus-builds`, `cyfr-locus` runs every build under a pooled uid of its own (`locus-build01`…`16`) with a private home directory on a tmpfs, and every process a build leaves behind is killed with its uid before the uid is reused. Only `cyfr` reaches the builder, over their own network; the network is not internal, because cargo and npm fetch from crates.io and the npm registry.
- **Memory.** Every build is held to `LOCUS_BUILDS_MEMORY_BYTES` (1 GiB by default): its processes, its home directory and the kernel memory charged to it, together. A build that reaches it is ended and answered as having reached its bound; a sibling build is untouched. The container's limit, `LOCUS_BUILDS_MEMORY_LIMIT` in `.env` (4G), holds `LOCUS_BUILDS_MAX_CONCURRENT` builds at their bound and the service beside them. The builder's other settings are in `.env.locus` (copy `.env.locus.example`). The bound needs the [Docker requirement](#prerequisites) above.

**`OOMKilled` is not the container's.** Docker marks the `locus-runtime` or `locus-builds` container `OOMKilled` whenever a runner or a build is ended at its own bound, though neither the container nor its release was touched: the kernel reports the kill in the container's cgroup tree. Read it as a runner or a build that passed its bound — the service's log says which — not as the container running out of memory; alert on the container restarting instead.

### Operator notes for shared servers and open sign-in

- **The seed `local.http` catalyst asks for wildcard egress** (`domains: ["*"]`, http+https; private IPs stay denied) and first-run provisioning consents the bundle automatically — on a server whose allowlist is `*`, that is a consented HTTP relay per signed-in stranger. The minted grant is pinned byte-for-byte by `apps/cyfr/test/sanctum/consent/bootstrap_golden_test.exs`, so widening or narrowing it is always a reviewed diff; narrow the seed manifest before opening sign-in to everyone if that posture is too generous for your deployment.
- **The audit trail carries identity fields, email included.** The allowlist's refusal telemetry carries the attempted email (that is the audit content — who was turned away), and `Prima.Sanitizer` deliberately does not redact identity fields on the audit plane. Every entry is logged, and is also emitted once as the `[:cyfr, :audit, :recorded]` telemetry event carrying the sanitized `Arca.Audit.Event`: attach your own handler there to write the trail to a SIEM or an object store, and only to one that may hold PII.
- **A first sign-in proceeds whatever the registry answers; filling the athanor needs it.** Sign-in asks cyfr.run once, under a short budget, for the person's publishing namespace and push tokens, and proceeds whatever that probe answers. The person and their own athanor are minted at sign-in, and the athanor is then filled in the background, pulling the bundle's published dependencies, the AQUA formula's provider catalysts among them, from the registry. On an air-gapped or registry-unreachable install the athanor is created but left unprovisioned — retried on the next sign-in, with the cause in the server log and the `[:cyfr, :sanctum, :provisioning, :failed]` telemetry event. AQUA stays unavailable until a retry succeeds. A cyfr.run namespace is needed only to publish (`cyfr push`, above), never to sign in.
- **A webhook's replay store is part of its delivery.** A webhook configured with an idempotency key header runs a delivery only once its claim is recorded; when the store cannot answer the claim, the delivery answers 503 `unavailable` with `Retry-After: 5` and runs nothing, and the `[:cyfr, :emissary, :webhook, :dedup_unavailable]` telemetry event is the alarm for the outage. The sender's retry runs it once the store answers.

### Reaching Prism on the server

Prism is served by the same endpoint as everything else, at CYFR's address: `https://<machine>.<tailnet>.ts.net/` from any device on your tailnet, or `https://<your domain>/` with public access. With local access, CYFR answers on the server's loopback alone; forward it over SSH:

```bash
ssh -L 4000:localhost:4000 <user>@<server>
```

Then open `http://localhost:4000` locally — with the port, which is what the
browser origin check trusts (a bare `http://localhost` is port 80, and a page
served there is not this server). With tailnet or public access the same
tunnel reaches CYFR's loopback listener, but its passkeys work only at its address.

## Production Configuration

Everything below is optional — the defaults (GitHub/Google sign-in, SQLite,
local `./data` storage) run a full instance with zero extra configuration.
Each option below is a deployment variable, set in `.env` (`.env.example`
carries the common choices commented out) and read at boot, and fails
loud: if an option is enabled but incompletely configured, the server
refuses to start rather than silently falling back.

The server's limits, windows and log level are **platform settings**: stored
in the database, the same on every server, and changed by a platform admin
on Prism's **Settings** page or with `cyfr settings`, a live one reaching
new work within seconds. [configuration-guide.md](configuration-guide.md)
lists every deployment variable and every platform setting with its
default, and says how to change a setting on a server with no console.

### CORS allowlist

`CYFR_CORS_ALLOWED_ORIGINS` is the browser CORS allowlist. `.env.example`
and `cyfr init` assign it empty:

```bash
CYFR_CORS_ALLOWED_ORIGINS=
```

Empty admits no cross-origin caller at all, which is what the shipped
stack needs: cyfr serves Prism, the API, `/mcp` and the tinctures from its
own origin, and behind Tailscale Serve or Caddy they are still that one
origin, so same-origin traffic never needs CORS. Set it to the origin(s) of a
frontend you serve elsewhere, comma-separated:

```bash
CYFR_CORS_ALLOWED_ORIGINS=https://app.example.com
```

With the line removed, the origins the server's own configuration names
stand: none, as shipped. A release with sign-in configured (it is by
default) refuses to boot while the allowlist holds the wildcard `*`, and
says to list the origins instead; a local `mix phx.server` run only
warns.

### Prometheus metrics

`/metrics` (Prometheus text format, on the endpoint's port) is disabled by
default. Opt in with:

```bash
CYFR_PROMETHEUS_METRICS=true
```

`CYFR_METRICS_TOKEN` makes the scrape require `Authorization: Bearer <token>`.
Without a token the endpoint is unauthenticated when enabled: allowlist the
path at your reverse proxy.

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
(`cyfr admin allow …`) — authentication says who you are, the allowlist says whether
you may come in.

### Sign-in methods, and what a first sign-in needs

A person signs in at a server with one of its sign-in methods: GitHub, Google or
your OIDC provider, a passkey they registered at this server, or, for a
person whose keys another CYFR holds, their CYFR identity (**Sign in with your
CYFR** on the sign-in page; [identity-guide.md](identity-guide.md)). The
server allowlist decides who may come in by any of them, by email, IdP
subject or person identifier, `per_…` (`cyfr admin allow
<email|user_id|identifier|*>`).

A person's first sign-in through one of the server's own sign-in methods mints them
with their own keys and their own athanor, seeded and baseline-consented
(the bundled `catalyst:local.http`
is granted `egress.domains ["*"]` for public hosts, GET/POST/HEAD, 60/min;
private addresses it cannot reach at all — its manifest declares no
`egress.private_ips`, which is the only private-address grant `cyfr` reads
when it pins a running component's outbound address, so a LAN device is
reachable from a chain as an MCP server on `CYFR_PRIVATE_EGRESS_TARGETS`,
which is the server's own, and not as a URL to fetch). Sign-in proceeds
whatever cyfr.run's short probe for a publishing namespace answers: the
athanor is filled in the background (see [Operator
notes](#operator-notes-for-shared-servers-and-open-sign-in)), and a cyfr.run
namespace is needed only to publish. A person admitted with their CYFR
identity is minted no keys and no athanor: theirs stay at their own CYFR, and
here they hold what their memberships give them. An installation set up
for a restore (`CYFR_RESTORE_TOKEN`) reserves its first person for the
restore: no sign-in method signs anyone in before it ([Backup and
restore](#backup-and-restore)). `cyfr admin deny <email>` revokes a
person's sessions and keys, archives their own athanor, removes them from every group
and withdraws the invitations that address was still holding; `cyfr admin
allow` lets them back in and reopens their own athanor — group seats are not
restored, a member adds them again. Work running in an athanor when it is
archived stops for good, on every server, whether or not the server heard:
a reopen admits only runs started after it.

### Opening sign-in to everyone (`*`), and the caps that bound it

`cyfr admin allow '*'` admits any identity your provider authenticates,
and anyone who signs in with their CYFR identity —
that is the public-hosting configuration, and it is the one where the limits
matter. They are platform settings in
[configuration-guide.md](configuration-guide.md): the `tenancy` group's
athanors on the server, groups one person creates, DMs one person holds,
seats in a group, threads, schedules, feeds and external servers in an
athanor, the bytes one athanor holds, and the athanors minted per hour (`CYFR_MINT_PER_HOUR`, a rate). Each count
ships with a generous default — 10,000 athanors, 50 groups, 200 DMs, 1,000
seats, and 1,000 each of threads, schedules, feeds and external servers —
and each is turned off with `0`; the bytes one
athanor holds have no ceiling until you set one. The mint rate is a bound
that is never 0: `CYFR_MINT_PER_HOUR=0` refuses the boot, and unset is no
bound.

A new athanor is provisioned with its own copy of the shipped bundle and
AQUA tree, so the athanor cap bounds tenancy and the storage cap each
athanor's whole tree; copying a shipped version in is never refused by the
storage cap, but its bytes count from then on. A specific `cyfr admin deny`
always beats `*`.

Closing sign-in to everyone again — `cyfr admin remove` on the `*` entry — ejects
everyone it was the only reason for: their sessions end and the API keys they
created are revoked. Their standing is untouched (nothing is archived, no
group seat is lost); that is what `deny` is for. The eject happens when the
entry is removed, so an allowlist row edited directly in the database, or a
`*` removed while the server is down, leaves live credentials behind — remove
it through `cyfr admin` on a running server.

### A CYFR for a household or a team

A household, a team or two people can keep their shared athanors on one
always-on server, the group's CYFR. Someone with no CYFR of their own
signs in there with one of its sign-in methods, as on any server; someone with a
CYFR of their own joins from it, where their keys and their own
athanor stay:

- **Letting them in.** The platform admin of the group's CYFR allows their person
  identifier, `per_…`, which their own CYFR's **Settings → Your identity**
  shows (`cyfr admin allow per_…`), and a member adds them to a group by
  the same identifier (**Members**, or `cyfr member add per_…`). An
  identifier the group's CYFR has not seen yet leaves an invitation that activates
  at their first sign-in.
- **Signing in.** On the sign-in page of the group's CYFR they choose **Sign in
  with your CYFR** and name their own CYFR's address; they confirm there, and
  both show the same short code. The group's CYFR reads their identity at the
  directory it names, which need not be its own, and mints them no
  keys and no athanor.
- **Confirming at the group's CYFR.** Signing in with their CYFR identity is
  not a fresh proof. Their first passkey there, which its sensitive changes
  need, is authorized by its platform admin under the admin's own fresh
  confirmation; after that they confirm for themselves. A phone they pair
  there is certified at their own CYFR ([devices-guide.md](devices-guide.md)).
- **Leaving.** Leaving one athanor, or being removed from it, ends that
  membership, the sessions bound to it and the devices paired for it;
  their other athanors there, and their own CYFR, are untouched.

CYFR enrolls its own people at the directory `CYFR_DIRECTORY_URL` names,
with no hosted default. Any operator, a household or a team included, may
serve one (`CYFR_DIRECTORY_SERVE`), but the only writer on the CYFR it
recovers loses that recovery with that CYFR. Who runs the directory decides
how long the identities it orders last: [identity-guide.md](identity-guide.md)
says what each loss costs.

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

The server migrates the schema on boot. Several servers sharing one Postgres,
or an operator who wants that step in their own hands, set
`CYFR_AUTO_MIGRATE=false` and run it from the release before starting:

```bash
bin/cyfr eval "Cyfr.Release.migrate()"
```

### Several servers on one database (a cluster)

One server per database is the default, and a second one pointed at the
same database refuses to boot rather than quietly running every sweep
twice. A **cluster** is the deliberate alternative: one deployment — one
database, one object store, one set of workers — served by several
control-plane **servers**, each holding its own slot in `cell_leases` and
taking a peer's work only after that peer's lease has run out on the
database's clock.

`CYFR_CLUSTER=1` turns it on, and the flag alone is not a cluster. A server
boots only with all seven of:

- **Postgres** (`CYFR_DATABASE=postgres`). SQLite is one file with one
  writer and no server clock, so the servers could not agree which lease
  stands.
- **Shared object storage** (`CYFR_STORAGE=s3`). Local storage is one
  server's filesystem; two servers would each hold half of every athanor.
- **TLS distribution** — `-proto_dist inet_tls` with an
  `-ssl_dist_optfile` naming the server's certificate, key and CA. Plain
  distribution between control planes is an unauthenticated remote shell
  onto the database.
- **A cluster-only cookie** — `CYFR_CELL_COOKIE`, at least 32 characters,
  the same value on every server and the value each server's BEAM
  actually runs under (`RELEASE_COOKIE`, or `-setcookie`). An ambient
  `~/.erlang.cookie` is the machine's, not the cluster's.
- **A discovery topology** — `CYFR_CLUSTER_NODES` naming the servers, or
  `CYFR_CLUSTER_DNS_QUERY` with `CYFR_CLUSTER_NODE_BASENAME` for a
  headless service.
- **A shared worker root** — `CYFR_LOCUS_RUNTIME_ROOT`, identical on every
  server. A `mix` boot mints one when it is unset; a release without one runs
  no component.
- **This server's own address** — `CYFR_HOST_API_URL`, the address a
  worker service reaches this server's host API at. Every assignment a
  server issues carries its own address, and a worker posts that
  attempt's host calls there; with no address the worker falls back to
  the one address it was configured with, and whichever server that is
  answers every other server's runs.

Each missing one is a named refusal at boot, saying what it found and what
to change.

What a cluster gives up and what it keeps:

- Work is not routed. A turn runs on the server that accepted it and an
  execution on the server that admitted it; ownership is settled after
  the fact by a claim row. Put the servers behind any load balancer.
- A server's lease is 15 s, renewed every 5 s, so a server that stops
  without releasing is taken over within **20 s**. A clean stop releases
  at once.
- Each server sets **`CYFR_HOST_API_URL` to its own host API**, and a
  cluster refuses to boot without it. Every assignment a server issues
  carries that address and that server's boot, so a worker posts an
  attempt's host calls to the server holding it and names that server in
  every header. A server that is not the one named refuses the call —
  including a lease renewal it could have written from the rows — so a
  misrouted worker loses the call loudly rather than keeping a peer's
  lease alive while its work goes nowhere. One worker service may serve
  several servers; each server still lists the workers it dispatches to
  in its own `CYFR_LOCUS_RUNTIME_WORKERS`.
- Stdio MCP servers are not available in a cluster.
- Per-server ceilings multiply: `CYFR_OPUS_MAX_CONCURRENT` and its
  per-tenant cap, and the per-credential stream cap, are each server's.
  The tenant's durable ceilings — its consented invocation rate and its
  budget — are rows, and hold for the cluster.
- A cluster runs one release. A server whose release differs from a live
  server's is refused its slot and stops at boot, naming both releases
  (an older server whose slot names no release counts as another). To
  upgrade a cluster on several hosts, stop the stack on every host, run
  `cyfr update` on one, which starts the new release there, then on each
  of the others: an update admits a live server outside its own stack
  only when that server already runs the release it installs, and
  refuses any other, as **Upgrading** under [Setup](#setup) says.

`scripts/test-partitioned.sh -n 1 -a postgres -- --only cluster
apps/cyfr/test/cluster` is the suite that proves this: two real servers, one
Postgres, one object store, with both process death and a live
partitioned owner.

Before it admits any work, every server reconciles the platform
administrators against `CYFR_PLATFORM_ADMIN_EMAILS` under its own slot,
ending the sessions of anyone the list does not name, and a
reconciliation that fails or stalls refuses the boot. The same holds after
a restart inside a running server: when the database checks, discovery,
the server's claim, the bus or anything else before the reconciliation
restarts, it runs again before anything that admits work comes back, and
the web tier, whose crashes restart it alone, never restarts the rest.

### Headless servers

`CYFR_HEADLESS=true` makes a server Codex-only: `/mcp`, `/api` and public
tinctures under `/t` are served, and every browser page — sign-in, the chat,
Prism — answers 404. The CLI still signs in through the built-in device flow
on `/mcp`, so this is for servers that never show a face (a build worker, a
relay); it does not combine with an external OIDC provider, which moves
sign-in to the browser page a headless server refuses.

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

- `CYFR_TRUSTED_PROXY_HOPS` (default `1`, 0 to 16) — how many reverse-proxy
  hops sit in front of cyfr's proxy listener, with tailnet or public access,
  when `CYFR_TRUSTED_PROXY_CIDRS` is unset. The shipped stack sets the CIDRs
  to its two proxies' addresses on the edge network (Caddy and Tailscale)
  instead. Stack a CDN or another proxy in front and you must
  raise it (or list the proxies in `CYFR_TRUSTED_PROXY_CIDRS`), otherwise
  client IPs resolve to the proxy address and API-key IP allowlists fail
  closed. A count outside 0 to 16, or a `CYFR_TRUSTED_PROXY_CIDRS` entry
  that is neither an address nor a CIDR, refuses the boot, naming it.
- The rate limits, stream limits and execution concurrency caps are
  platform settings ([configuration-guide.md](configuration-guide.md) has
  each with its default and range). The container CPU quota
  (`CYFR_CPU_LIMIT`, default 4) bounds the `cyfr` container's CPU use; components run
  in `locus-runtime`, which has its own quota (`LOCUS_RUNTIME_CPU_LIMIT`).

### Backup and restore

What to back up depends on the backends you configured:

| Backend | What holds state | Backup |
|---|---|---|
| SQLite (default) | `./data` (database, encrypted secrets, every athanor's components and files, caches) | Stop the stack (`cyfr down`), copy `./data`, restart. Copying while running risks a torn SQLite snapshot. |
| Postgres | your database + `./data` for files | `pg_dump` on your schedule + the `./data` copy above |
| S3 | the bucket + the database | enable bucket versioning/replication; back the database up as above |

A restore needs the **same `CYFR_SECRET_KEY_BASE`** — secrets are encrypted
with a key derived from it, so a restored data directory is unreadable under
a different key base. The session cookie's and the LiveView socket's signing
salts, `CYFR_SESSION_SALT` and `CYFR_LIVE_SALT`, are derived from the key base
unless `.env` sets them. Treat `.env` as part of the backup (it holds that key), store it
separately from the data backup if you can, and exclude `erl_crash.dump` and
`tmp/` from backup jobs — a crash dump can contain decrypted key material
from process memory.

**Restore is declared.** `cyfr restore backups/<timestamp>` puts a snapshot
`cyfr update` took back: it refuses an incomplete snapshot or one whose
layout it cannot put back, stops the stack and bars the cluster from starting
before anything lands: it sets `CYFR_RESTORE_INCOMPLETE` in `.env`, which
the image's entrypoint, `cyfr up` and `cyfr update` refuse, and removes the
stopped `cyfr` container. It refuses while any server of the cluster still
runs, on any host and of any release, or while the PostgreSQL server is of
a major the CLI pins no client image for, and otherwise puts back the managed
scaffold files as they stood before the update, the database, the storage
root (each nested mount's bytes at its own source), the keyring, `.env`
and `docker-compose.yml`, and declares the restore before anything starts,
in a one-off container that sets the bar empty for itself alone:

```sh
docker compose run --rm --no-deps -T -e CYFR_RESTORE_INCOMPLETE= cyfr bin/cyfr eval 'IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())'
```

and only then takes the bar out of `.env` and starts the stack
(`--no-start` leaves it stopped). A restore cut short anywhere leaves the
bar up; `cyfr restore <backup>` run again puts every part back and
declares it. A backup put back by hand, with no bar in `.env`, is declared
by the same command, with the whole cluster stopped, before its first start.
The next boot retires what the backup's authority
could still do before it admits anything: every session ends; API keys,
webhook secrets, paired devices and passkeys are suspended until their
person re-enables them from the system layer's checklist under a fresh
sign-in with one of their sign-in methods, an emailed code or their kit (`/restore`, **Recover after a
restore**); every component grant asks for consent again; standing
approvals, unused once-bindings and pending confirmations are dropped;
every stored credential is unusable until it is rotated where it came from
and entered again; runs open at the backup end uncertain and none resumes;
and a group admits no new member until each of its members who held a passkey or device has recovered, or a platform administrator ends that member's recovery (`person.close_recovery`).
[identity-guide.md](identity-guide.md) has the person's side. The
sign-in providers' OAuth client credentials and the registry push tokens
stay as the backup restored them. An object store (`CYFR_STORAGE=s3`) is
outside the snapshot: objects written since it stay in the bucket.

A snapshot holds neither this machine's tailnet identity (the
`tailscale_state` volume) nor `.cyfr/`, so a restore leaves the machine on
the tailnet as it is. When the restored `.env` is for tailnet access and
names another machine than this one, or this machine has joined no
tailnet, as on a new server, CYFR starts answering on this machine
only and `cyfr restore` exits with status 3, saying so. `cyfr access tailnet` then joins the machine, or offers
to move CYFR to the machine's current tailnet name. A new name is a new
address: passkeys are registered and devices paired again there
([devices-guide.md](devices-guide.md#when-cyfrs-address-changes)).

A restore that is not declared keeps the backup's authority, and CYFR
cannot tell it was restored: sessions, keys and grants the backup holds
still work, and a revocation made after the backup was taken is not seen.
Declare every restore.

A backup restores the server. A person's identity has its own recovery,
for a CYFR lost with no backup to put back: someone who enrolled (their
own CYFR's **Settings → Your identity**) restores their identifier and new
keys onto a fresh installation from their printed kit, never their data.
The operator sets a one-time `CYFR_RESTORE_TOKEN` there and hands it to
them, and they open `https://<installation>/restore`; until it completes,
no sign-in method signs anyone in. Their memberships at any other CYFR stand, and they
pair their devices again. [identity-guide.md](identity-guide.md) has the
steps and what each loss costs.

## CLI Reference

Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Scaffold a CYFR project — downloads `docker-compose.yml` + `Caddyfile`, asks how CYFR is reached (tailnet, public or local; `--access`, `--domain`, `--acme-email`, `--tailscale-auth-key-file`, `--hostname`), writes `.env` with the stack's keys minted into it, joins the tailnet for tailnet access, opening the approval link in the default browser on a machine with a display (`--no-open` does not), creates dirs and pulls the images (`--no-pull`); in an existing project it adds only the keys `.env` lacks (`--force` re-fetches the deploy files; never replaces `.env`) |
| `cyfr setup` | Set up a new CYFR from pages on this machine's own screen, `cyfr init`'s face for a device with a touch screen: serves them on `127.0.0.1` before the stack runs (`--port`, a free port when not given), prints their address, writes it to `.cyfr/setup.url` and opens them in the default browser on a machine with a display (`--no-open` does not); the pages ask how CYFR is reached and the administrator's email, run `cyfr init`'s steps and `cyfr up`'s start (`--no-pull`), show a tailnet join's link as a QR code, and stop once CYFR is up; refuses a project whose `.env` exists, and a second `cyfr setup` while one serves the project's pages |
| `cyfr access <mode>` | Change how CYFR is reached, `local`, `tailnet` or `public`: asks first about a tailnet join the change needs, shows who can reach it, its address, the certificate email and the ports opened, before → after (and the tailnet machine, the port on this computer and the builds service when they change), then stops the stack, rewrites `.env` and starts what ran (`--domain`, `--acme-email`, `--tailscale-auth-key-file`, `--hostname`, `--new-node`, `--yes`; a join's approval link opens in the default browser on a machine with a display, `--no-open` not; `--tailscale-auth-key-file` and `--hostname` apply to a new join, so a machine already on the tailnet refuses them without `--new-node`); when CYFR has tailnet access and its Serve is closed (HTTPS off, say), `cyfr access tailnet` serves it on the tailnet again; `cyfr access --resume` finishes a change an interruption left |
| `cyfr access status` | Show how CYFR is reached, what runs and the last change, without the lock and changing nothing |
| `cyfr up` / `cyfr down` | Start / stop the stack under its lock: cyfr, locus-runtime and locus-backends, plus locus-builds when `CYFR_LOCUS_BUILDS_URL` in `.env` names it (as `cyfr init` writes it) and the proxy `CYFR_ACCESS` selects (tailscale for tailnet, caddy for public); `up` refuses a `.env` that contradicts its access settings with the server's own sentence; `down` refuses a directory that holds no compose file, since the stack it stops is the directory's own |
| `cyfr update` | Update this program to the newest release (through brew for a Homebrew install), then the CYFR in this directory to it: shows what changes and asks (`--yes`), verifies the release's signed manifest, pulls every image by digest, stops the stack, snapshots it into `backups/`, rewrites `docker-compose.yml`'s managed image lines (cyfr, cyfr-locus, the bundled caddy and tailscale) to the release's digests and starts it (see **Upgrading**); `--version <version>` installs exactly that release, a pre-release or an older one included; leaves `.env`, `Caddyfile` and every other image line alone, a CYFR already on the release untouched, refuses a CYFR on a newer release and a `docker-compose.yml` that lacks a service of the bundled stack |
| `cyfr restore <snapshot>` | Put a snapshot from `backups/` back with the whole cluster stopped (refused while any server of the cluster runs), declare the restore and start the stack (`--no-start` leaves it stopped); see **Backup and restore** |

> `cyfr --version` and `cyfr status` print a one-line hint when a newer release is available. The check only runs in an interactive terminal and is cached for a day; set `CYFR_NO_UPDATE_CHECK=1` (e.g. in your shell profile) to turn it off.

### Identity

| Command | Description |
|---------|-------------|
| `cyfr login` | Sign this command line in by approving it in Prism: prints a link and a code to check against Prism's, and waits; the session is saved under the context used (`--context` or the current one, a `--url` that is not its address refused) and listed under Devices in Prism, where it is revoked; `--provider github\|google` signs in with the provider's device flow instead (see [devices-guide.md](devices-guide.md)) |
| `cyfr logout` | End the context's session (`--context` or the current one; a `--url` that is not its address is refused) |
| `cyfr open` | Open the context's address in your browser, this machine's loopback context as `http://localhost:<port>`; no session travels with it |
| `cyfr whoami` | Show current identity |
| `cyfr status` | Check system health (includes CLI version) |
| `cyfr athanor list/get/use/create/rename/settings/provision/archive/unarchive` | Your athanors, your own and your groups: list and show them, point this session at one, create, rename or archive a group, merge settings, retry a provisioning that failed |
| `cyfr member list/add/remove/leave` | Who is in an athanor: add or remove someone by email, user id or person identifier (`per_…`), or leave a group |

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
| `cyfr schedule create/list/get/update/pause/resume/delete` | Manage cron schedules for recurring execution `[i]`; `"keep_outcome": true` in a schedule's metadata files each run's output as a note in its athanor |
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
| `cyfr mcp update <name> <config-json>` | Replace an external MCP server's config |
| `cyfr mcp restart <name>` | Restart a stdio MCP server's backends |

### Security

| Command | Description |
|---------|-------------|
| `cyfr call vault '{"action":"list",…}'` | Manage vault entries (encrypted credentials): create/rename/rotate/rebind/revoke/delete, `authorize` for OAuth — also in the console's Vault page |
| `cyfr key create/list/get/revoke/rotate` | Manage API keys `[i]` |
| `cyfr call oauth '{"action":"set_client",…}'` | Store an OAuth app's client credentials per provider; user grants run through `cyfr profile grant` and the console's Vault page |
| `cyfr pair <code>` / `cyfr pair list` / `cyfr pair revoke [client-id]` | Pair a new device with the code its `/pair` page shows, list paired devices, revoke one; pairing and revoking each need a fresh confirmation given in Prism ([devices-guide.md](devices-guide.md)) |

### Administration

| Command | Description |
|---------|-------------|
| `cyfr admin list/allow/deny/remove/requests/resolve` | The sign-in allowlist: who may sign in to this server, by email, IdP subject or person identifier (`per_…`), or `*` for anyone, and the pending requests to approve or drop (platform admins) |
| `cyfr settings list/set/reset` | The platform settings: limits, windows and the log level, and where each value comes from (platform admins; [configuration-guide.md](configuration-guide.md)) |
| `cyfr log list/get/correlate` | View and inspect MCP request logs |
| `cyfr decision list/get/correlate` | View admission decisions, and cross-reference a request's decisions with its logs and executions |
| `cyfr retention show/set/cleanup` | Manage data retention policies |
| `cyfr aqua list/get/status/reset/skills` | Read the AQUA soul, roles, guides and scrolls, see which files are shipped, edited or yours, and reset to shipped `[i]` |
| `file offer/offers/accept/decline/withdraw` (MCP) | Offer a snapshot of a file to someone you share an athanor with, list the offers, and accept, decline or withdraw them |
| `file list/read/write/delete` (MCP) | The athanor's files as the Files page shows them — `data/` open, `components/` and `aqua/` shaped, `notes/` and `threads/` read-only |
| `cyfr registry whoami` | Show registry identity (push tokens, claimed namespaces) |
| `cyfr registry get-namespace <slug>` | Inspect a cyfr.run namespace |
| `cyfr registry publisher claim/verify <domain>` | Claim + DNS-verify a publisher namespace `[i]` |
| `cyfr registry tokens list/issue/revoke <ns>` | Manage push tokens for a namespace; issuing one needs a fresh confirmation given in Prism `[i]` |
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

CLI environment variables: `CYFR_TOKEN` (credential), `CYFR_NO_INTERACTIVE=1` (no prompts), `CYFR_NO_UPDATE_CHECK=1` (no release check — air-gapped installs).

## Glossary

Each part of CYFR has one name, and the name is its directory, its binary or image, its compose service, its environment variable prefix, its MAC domain, its provider's service label and its log label. Words for a role inside a part stay English. What each part is responsible for, how the parts talk to each other and what must always hold are in [ARCHITECTURE.md](ARCHITECTURE.md).

| Name | Is | Directory | Binary or image | Compose service | Environment prefix | MAC domain | Service label | Log label |
|------|----|-----------|-----------------|-----------------|--------------------|------------|---------------|-----------|
| Prima | pure contracts and the rostered runtime primitives | `apps/prima` | in every release | — | — | — | — | `[Prima…]` |
| Arca | persistence: rows, blobs, cache, leases, retention kinds, the records and file entry points | `apps/arca` | the `cyfr` release | — | — | — | `arca` | `[Arca…]` |
| Sanctum | decisions and the gate: identity, tenancy, authority, consent, vault, caps, the operation table, admission and dispatch, the request log and decision record | `apps/sanctum` | the `cyfr` release | — | — | — | `sanctum` | `[Sanctum…]` |
| Cyfr | the host: boot, ownership, bus, telemetry, configuration and settings, the endpoint and every other admission path, wiring | `apps/cyfr/lib/cyfr`, `apps/cyfr/lib/cyfr_web` | the `cyfr` release, image `cyfr` | `cyfr`, with `caddy` in front for public access and `tailscale` in front for tailnet access, with a loopback SOCKS5 proxy for this device's browser | `CYFR_` | — | — | `[Cyfr…]` |
| Compendium | components: kinds, manifests, registry, activation, provenance, builds over Locus, the tincture rules | `apps/cyfr/lib/compendium` | the `cyfr` release | — | — | — | `compendium` | `[Compendium…]` |
| Aqua | the assistant: threads, rooms, turns, approvals, notes, attachments, memory, its providers | `apps/cyfr/lib/aqua` | the `cyfr` release | — | — | — | `aqua` | `[Aqua…]` |
| Opus | execution: admission, attempts, HostAPI, WorkerAPI, guest egress, schedules | `apps/cyfr/lib/opus` | the `cyfr` release | — | `CYFR_OPUS_`, `CYFR_HOST_API_` | — | `opus` | `[Opus…]` |
| Emissary | external application protocol adapters: MCP in both directions (external MCP servers over HTTP or through Locus), the HTTP API and its event streams, health, webhooks, the vault's OAuth callback, tinctures' files and data routes | `apps/cyfr/lib/emissary`, `apps/cyfr/lib/emissary/web` | the `cyfr` release | — | — | — | `emissary` | `[Emissary…]` |
| Prism | the screen: the console | `apps/cyfr/lib/prism`, `apps/cyfr/lib/prism_web` | the `cyfr` release | — | — | — | — | `[Prism…]` |
| Codex | the CLI | `apps/codex` | the `cyfr` binary | — | — | — | — | — |
| Locus | where untrusted things run: the roles runtime (WASM), builds and stdio MCP backends, under the keeper `cyfr-locus` | `apps/locus` | the `locus` release and the keeper binary `cyfr-locus`, image `cyfr-locus` | `locus-runtime`, `locus-builds`, `locus-builds-guard`, `locus-backends`, `locus-backends-guard` | `LOCUS_RUNTIME_`, `LOCUS_BUILDS_`, `LOCUS_BACKENDS_`, `LOCUS_LOG_`, `KEEPER_`, `RUNTIME_`, `CYFR_LOCUS_RUNTIME_`, `CYFR_LOCUS_BUILDS_`, `CYFR_LOCUS_BACKENDS_` | `cyfr-locus/v1`, with its `runtime`, `builds` and `backends` services, each under a key of its own | — | `[Locus…]`, `[cyfr-locus]` |
| provider | the implementation of a tool's operations, `<Name>.Provider` or `<Name>.Providers.<Tool>`; its service label is its part's name | — | — | — | — | — | — | — |
| facade | a part's own module, the one entry the parts above it call | — | — | — | — | — | — | — |
| port | one of four behaviours a lower part declares and a higher one implements, installed at boot | — | — | — | — | — | — | — |
| plane | the kind of caller an operation is admitted for: an external caller, or a call inside a running chain | — | — | — | — | — | — | — |
| actor | the tenant and identity carrier | — | — | — | — | — | — | — |
| athanor | the tenancy unit, a person's own or a group's, with no organization or project above it; the one CYFR that holds it decides everything about it | — | — | — | — | — | — | — |
| lease | a control-plane server's database-held claim to its slot | — | — | — | — | — | — | — |
| fence | the lease row's renewal token, which each renewal and takeover of the row names and raises; never a publication's identity ([`ARCHITECTURE.md` §6.3](ARCHITECTURE.md#63-publication)) | — | — | — | — | — | — | — |
| attempt | one try at running an execution on a worker service | — | — | — | — | — | — | — |
| backend | one stdio process of an external MCP server, run by the Locus backends service | — | — | — | — | — | — | — |
| cluster | several control-plane servers sharing one database | — | — | — | — | — | — | — |
| sign-in method | a way a person signs in at CYFR: GitHub, Google, an OIDC provider, a passkey, or their CYFR identity when another CYFR holds their keys; the server allowlist decides who may come in by each | — | — | — | — | — | — | — |
| person identifier | `per_…`, the hash of the first entry of a person's identity log: it names them at every CYFR and grants no membership anywhere | — | — | — | — | — | — | — |
| directory | the CYFR that orders an identifier's identity log and serves its current public keys, holding no private key and no address of a person's CYFR | — | — | — | — | — | — | — |
| live key | the key a person's CYFR holds for them to sign their sign-ins at any other CYFR and their devices' certificates | — | — | — | — | — | — | — |
| operational key | the key a person's CYFR holds for them to rotate the live key, and nothing else | — | — | — | — | — | — | — |
| recovery key | a key held away from the person's CYFR that replaces the live and operational keys without their cooperation | — | — | — | — | — | — | — |
| recovery kit | three printed lines, the identifier, the directory and a recovery secret, from which a person restores their identity | — | — | — | — | — | — | — |
| `key_epoch` | the identity log entry that introduced a person's current live key; when it changes, every other CYFR retires what it bound to the old one | — | — | — | — | — | — | — |
| `recovery_epoch` | the first entry of a person's identity log, or the latest recovery that replaced their live key; a passkey another CYFR registered for them is bound to it | — | — | — | — | — | — | — |
| restore | bringing a person's identity onto a fresh installation from their recovery kit, under that installation's single-use restore token; it restores no data | — | — | — | — | — | — | — |
| carry | a sign-in at another CYFR, such as one that keeps a household's or a team's shared athanors always on, begun at the person's own CYFR and carried between the two by their browser | — | — | — | — | — | — | — |
| pending action | the durable record of one carry: its destination, challenge and return address, resumed by an exact retry | — | — | — | — | — | — | — |
| passkey | a credential registered at one CYFR, under that CYFR's host, that signs the person in there and gives their fresh confirmations there | — | — | — | — | — | — | — |
| device key | the key pair a paired device makes and never exports, which its device certificates name | — | — | — | — | — | — | — |
| device certificate | a short-lived statement, signed with the person's live key at their CYFR, naming a device key, its client, the CYFR and the athanor | — | — | — | — | — | — | — |
| paired client | a device paired with CYFR for one athanor, holding device keys it never exports and no store, vault or person key, revocable on its own and renewed only while it stands | — | — | — | — | — | — | — |
| fresh confirmation | a proof that the person approved one pending confirmation: a passkey or a fresh sign-in; each sensitive change needs one | — | — | — | — | — | — | — |
| pending confirmation | one sensitive change waiting for its fresh confirmation, with the preview CYFR stores and shows on every device of the person's | — | — | — | — | — | — | — |
| origin | how a run started, `interactive`, `programmatic`, `schedule` or `webhook`, set by the path that admitted it; a grant names the origins it admits | — | — | — | — | — | — | — |

Every setting of the control plane is a `CYFR_` variable; a part named with a prefix of its own beneath it owns those settings. A setting an island's release reads carries the island's own prefix, and the control plane's copy of an island's key carries `CYFR_` before it: `CYFR_LOCUS_BACKENDS_KEY` in `.env` is `LOCUS_BACKENDS_KEY` in the `locus-backends` service. `HostAPI` and `WorkerAPI` are protocol names, and `CYFR_HOST_API_` serves the first.

## Documentation

| Document | Description |
|----------|-------------|
| [Configuration Guide](configuration-guide.md) | Every deployment variable and platform setting, with its default |
| [Integration Guide](integration-guide.md) | How to use CYFR as your application backend |
| [Component Guide](component-guide.md) | Practical guide to building catalysts, reagents, and formulas |
| [Tincture Guide](tincture-guide.md) | Practical guide to building tinctures |
| [Identity Guide](identity-guide.md) | A person's identifier, keys and printed kit, restoring them on a fresh installation, and joining a CYFR that is not your own |
| [Devices Guide](devices-guide.md) | Pairing a device with CYFR, how it stays connected, and confirming a sensitive change from any of your devices |
| [Architecture](ARCHITECTURE.md) | What each part of CYFR owns, how the parts talk to each other, and why |

## Verifying Releases

The install script verifies the cosign signature over the release's
`checksums.txt` as the release workflow's for the version it installs
(identity exactly `release.yml@refs/tags/<version>`, as `cyfr update` checks
it in process), then the SHA-256 checksum of the download against it, and
**fails closed** on any mismatch or missing tooling: without `cosign` on your
PATH it refuses. Two knobs adjust the policy:

- `CYFR_ALLOW_UNVERIFIED=1` — install without cosign or without the
  signature bundle: the checksum is still verified, the signature is not.
- `CYFR_INSECURE_SKIP_VERIFY=1` — skip verification entirely (not
  recommended; for airgapped/bootstrap edge cases).

All release binaries are signed and attested. You can also verify manually at
three levels:

```bash
# GitHub Attestation (easiest — just needs gh CLI)
gh attestation verify cyfr_*.tar.gz --owner cyfrworks

# Checksum verification (no tools needed)
sha256sum --check --ignore-missing checksums.txt

# Full Sigstore verification (maximum rigor): the release workflow at the
# tag of the version you downloaded, as install.sh and cyfr update verify it
VERSION=0.9.0
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity "https://github.com/cyfrworks/cyfr/.github/workflows/release.yml@refs/tags/$VERSION" \
  checksums.txt
```

## License

CYFR is **Fair Source** — mixed-licensed per file via `SPDX-License-Identifier`
headers. The boundary is one application: everything under
`apps/sanctum/` (Sanctum — the auth, policy, audit and tenancy layer, with
its own tests) is licensed under the **Functional Source License 1.1** with **Apache 2.0** as the Future License
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
- Hex.pm: each package declares its own licence: `cyfr` as `Apache-2.0`, `sanctum` as
  `FSL-1.1-Apache-2.0`.
- Distros (Debian `main`, Fedora) typically exclude FSL packages from
  default repos. CYFR ships via Docker, Homebrew, and source checkout.
- NixOS: classify as "unfree" and allow with
  `nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (pkg.meta.license.shortName or "") ["fsl11Apache20"];`

### Precedent

FSL and adjacent source-available licenses (such as BUSL and Elastic License
2.0) are the path Sentry, HashiCorp, Sourcegraph, Convex, Elastic, and others
have taken. The
2-year delay to Apache is what `fsl.software` calls "Delayed Open Source
Publication" — each released version converts to Apache 2.0 two years
later.
