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
- **Prism** — the web face, served by CYFR on its one endpoint (`:4000`, or `/` behind Tailscale Serve or Caddy) and installable as a PWA: your desktop and the apps over it, your own **Aqua** — your friendly assistant — in a panel beside it, the chat of the shared threads you talk in with other people, the settings behind a gear, your athanor's Aqua page, and the developer views — executions, components, builds, activities, enforcements, the vault, API keys, schedules, programs, tinctures.

The **CYFR app** shows Prism in a window of its own on Linux, macOS and Windows, connected to a CYFR that runs elsewhere, with no Docker on your computer: **Connect to a CYFR**, then sign in with your passkey (macOS and Windows) or with the computer's own key under its PIN or passphrase ([devices guide](devices-guide.md#the-cyfr-app)). Each release carries it for every system ([Install the CYFR app](#install-the-cyfr-app)). Its first screen also sets CYFR up on the computer itself, with Docker: it says what Docker needs and shows each step ([devices guide](devices-guide.md#the-cyfr-app)).

## Quick Start

There are two ways to use CYFR; pick the one that fits.

### Install the CYFR app

Each release carries the CYFR app for Apple silicon Macs, and for Windows and Linux on Intel and AMD (amd64) and on Arm (arm64), with its own `cyfr` inside. CYFR does not run on Intel Macs: the install script and Homebrew refuse one. Every file is listed in the release's signed `checksums.txt` ([Verifying Releases](#verifying-releases)).

- **macOS** (Apple silicon): `brew install --cask cyfrworks/cyfr/cyfr` installs CYFR in Applications and puts its `cyfr` on your `PATH`; `brew upgrade --cask cyfr` takes the next release, and `brew uninstall --cask cyfr` removes both. Or download `cyfr-desktop_<version>_darwin_arm64.dmg` from the [release](https://github.com/cyfrworks/cyfr/releases), open it and drag CYFR to Applications. It is signed by CYFR Works Inc. and notarised by Apple, so the first time you open it, whether Homebrew or your browser downloaded it, macOS asks once whether to open an app downloaded from the internet: choose **Open**. Dragging the app puts no `cyfr` on your `PATH`; for that, run once in Terminal:

  ```bash
  sudo mkdir -p /usr/local/bin && sudo ln -s /Applications/CYFR.app/Contents/Resources/cyfr /usr/local/bin/cyfr
  ```

  It links the app's `cyfr` as `/usr/local/bin/cyfr` and never replaces a file already there: when another `cyfr` holds that name, such as the one the install script put there, `ln` says `File exists` and changes nothing. `ls -l /usr/local/bin/cyfr` shows what it is; to use the app's instead, remove that one (`sudo rm /usr/local/bin/cyfr`) and run the command again.

- **Windows**: download `cyfr-desktop_<version>_windows_amd64.msi` (Intel and AMD) or `cyfr-desktop_<version>_windows_arm64.msi` (Arm) from the [release](https://github.com/cyfrworks/cyfr/releases) and open it. It installs CYFR for your account alone, with no administrator, and puts its `cyfr` on your `PATH` for every terminal opened afterwards; **Installed apps** in Settings removes it. The installer is not signed yet, so Windows may say **Windows protected your PC**: choose **More info**, then **Run anyway**. A work computer's policy may refuse it.
- **Linux** (Ubuntu): download `cyfr-desktop_<version>_linux_amd64.deb` or `cyfr-desktop_<version>_linux_arm64.deb` and install it with `sudo apt install ./<file>`, which links its `cyfr` as `/usr/bin/cyfr`.

### Deploy it for end users

Stand up the self-hosted stack on a server (see [Deploy to a Server](#deploy-to-a-server)) and your users just open `https://<your-domain>/`, sign in, and get their athanor's chat — no CLI on their side. "Add to Home Screen" installs it like a native app; it runs equally well on a phone.

### Develop with Codex + Prism

Run CYFR locally and drive it with the `cyfr` CLI.

On **Ubuntu 26.04 LTS**, at a terminal, nothing needs installing by hand. The install script offers to install cosign, which verifies the release, with `sudo apt-get install -y cosign`, and puts `cyfr` in `~/.local/bin`, or `/usr/local/bin` if you can write it. From `~/.local/bin` it links `cyfr` into `/usr/local/bin` with `sudo ln -sf` when `~/.local/bin` is not on your `PATH`, so `cyfr` works in the same terminal. When your account cannot reach Docker, `cyfr init` shows the commands that install what is missing (`docker.io`, `docker-compose-v2` and `apparmor`, the running service and your membership of the `docker` group), asks `Install these requirements?`, and runs them through one `sudo`. CYFR never asks for, reads or keeps a password: when `sudo` will ask, CYFR first says `Ubuntu will now ask for your password: the one you log in to this machine with. Nothing shows while you type.`, and `sudo` asks in its own prompt before any command runs, so a refused password changes nothing. An account outside the `sudo` and `admin` groups is told so before anything is asked, with the commands as one `sudo` line for whoever administers the machine, and nothing is changed. Members of the `docker` group control Docker, which is root's power over the machine. Joining the group takes effect in a new login, so `cyfr init` and `cyfr up` run themselves through `sg docker` in a terminal older than it. Locus runs under the AppArmor profile `cyfr` carries, whose name carries its content: `cyfr-locus-` and the first 12 hex digits of its text's hash, which `.env`'s `CYFR_LOCUS_APPARMOR` names to the compose file. Where the kernel has not loaded that name, `cyfr init`, before it writes anything, shows the two commands that install and load it, asks `Load it?`, and runs them through one `sudo`, as above, root reading the profile from `cyfr` itself; `cyfr update` does the same before it stops anything, and takes the profile it replaced off the machine once the new release runs, and `cyfr up`, `cyfr restore` and `cyfr access` do the same before anything starts. Answered no, nothing is changed. Without a terminal they refuse, naming the one command, `cyfr apparmor-profile | sudo sh -c 'cat > /etc/apparmor.d/<name> && apparmor_parser -r -W /etc/apparmor.d/<name>'`, which is also what to run on another Linux. Docker starts the Locus container only under a loaded profile of that name, and its keeper proves at its own start that it runs under its release's, and otherwise refuses to start, naming that command. On a Linux host whose kernel enforces no AppArmor, as on Docker Desktop, the option is ignored and nothing stands in the place of Docker's masks: the keeper starts, says so once in its log, and alone, never a space, may write `/proc/sys`. `cyfr uninstall` leaves the profile, which every CYFR on the machine may share, and names the command that removes it. Ubuntu's universe archive must be enabled (`sudo add-apt-repository universe`).

On other systems, install Docker first. The install script installs the `cyfr` CLI only, and the Homebrew cask the CYFR app with its `cyfr`; Docker must be running before `cyfr init` / `cyfr up`:

- macOS / Windows: install [Docker Desktop](https://www.docker.com/products/docker-desktop/). At a terminal, while Docker does not answer, `cyfr init` offers to open that page and says what the installer's prompt will be (on a Mac, its login password or Touch ID; on Windows, whether to allow the app to make changes to your device), or, with Docker Desktop installed, says to start it; it then waits, writing nothing, until Docker answers, and goes on. Answered no, it opens and writes nothing.
- Linux: your distribution's Docker packages, or Docker's convenience script for a quick dev install: `curl -fsSL https://get.docker.com | sh`. Then, **if you are not running as root**, add yourself to the `docker` group so the CLI can reach the daemon without `sudo`:

  ```bash
  sudo groupadd docker
  sudo usermod -aG docker $USER
  newgrp docker            # or log out and back in
  ```

```bash
# Install the cyfr CLI via shell script (Linux, macOS, WSL). It takes the
# newest release that is not a pre-release and, while none is published,
# the newest pre-release, and says which it took; CYFR_VERSION=<version>
# names an exact one instead. The installer needs cosign to verify the release's signature: on Ubuntu 26.04
# LTS it offers to install it, elsewhere install it yourself
# (`brew install cosign`); without it, CYFR_ALLOW_UNVERIFIED=1 verifies the
# archive's checksum alone.
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh

# Or via Homebrew (macOS): the CYFR app with its cyfr, at the newest release
# that is not a pre-release
brew install --cask cyfrworks/cyfr/cyfr

# Initialize a project reached from this machine; on Ubuntu 26.04 LTS it
# first installs Docker if the machine lacks it; it prints this CYFR's
# setup link
mkdir <project-directory>
cd <project-directory>
cyfr init

# Start the server; on its first start it prints the setup link again
cyfr up

# Set CYFR up: open the setup link and sign in with your account, or
# create it there (your name, your recovery code, your passkey); that
# makes you its first person and its administrator. Prism, your
# athanor's chat, is there from then on.

# Grant a component the vault entries it needs: on Components, open
# c:local.claude and choose Grant access

# This command line calls CYFR with an API key: make one on the API Keys
# page (the preset "Build components" also registers and builds)
export CYFR_TOKEN=cyfr_sk_...

# Scan bundled components and auto-pull their dependencies
cyfr register

# Run what you granted
cyfr run c:local.claude

# Learn more about other commands
cyfr -h
```

`cyfr init` downloads your project files and pulls the server images: `docker-compose.yml`, `Caddyfile`, `keeper.seccomp.json` (the seccomp profile Locus runs under), `.env.example` and Locus's own env example, WIT interface definitions, the `aqua/` soul and scrolls, and the included guides ([configuration-guide.md](configuration-guide.md), [integration-guide.md](integration-guide.md), [component-guide.md](component-guide.md), [tincture-guide.md](tincture-guide.md), [identity-guide.md](identity-guide.md), [devices-guide.md](devices-guide.md)). It asks nothing about how CYFR is reached: it writes `.env` from `.env.example` for a CYFR reached from this machine, and mints the stack's keys into it: `CYFR_SECRET_KEY_BASE`, `CYFR_LOCUS_BACKENDS_KEY`, the runtime root `CYFR_LOCUS_RUNTIME_ROOT` with the `LOCUS_RUNTIME_KEY` derived from it, and `CYFR_LOCUS_BUILDS_KEY`, so builds are on, and the setup token `CYFR_SETUP_TOKEN`. It then prints the setup link, `<CYFR address>/setup#<token>`, which sets CYFR up once `cyfr up` has started it: the page signs you in with your account, or creates one, and that makes you its first person (see [Signing in, and what a first sign-in needs](#signing-in-and-what-a-first-sign-in-needs)). [`cyfr access`](#how-cyfr-is-reached) reaches it from your other devices or the internet later. Pass `--no-interactive` to ask nothing. On Ubuntu 26.04 LTS it installs Docker first when the machine lacks it, as above; on other systems it does not install Docker. The scaffolded `docker-compose.yml` is the full self-hosted stack — `cyfr` (the one endpoint on `:4000`: Prism, API, MCP, tinctures), `locus` (the one Locus: its runtime role runs components, its builds role is behind `cyfr build compile`, and its backends role runs programs: MCP servers and the harnesses people and brains drive) behind its egress guard `locus-guard`, and the proxy that lets other devices reach CYFR: `tailscale` (Tailscale Serve, for tailnet access) or `caddy` (TLS and the reverse proxy at `:80`/`:443`, for public access); `cyfr up` brings up the first three, and the proxy CYFR's access mode selects. See [Deploy to a Server](#deploy-to-a-server) for the same stack on a VPS.

## Prism — the web face

**Prism** is CYFR's one web face, at `http://localhost:4000` (the same origin as the API — one endpoint, one login), and it is one screen: `/` lands on your desktop, and everything else opens over it without leaving it. Your athanor is your own place, and nobody else sits in it, though whoever runs the machine CYFR runs on can read what it keeps there (Legal → Privacy says who can read what): in your daily thread with Aqua, one a day, every message addresses Aqua — the same thread on your phone and your laptop. People talk in shared threads: a title, its people, each equal, and their messages with attachments. Nothing runs in a shared thread — no Aqua answers there. A pair is a shared thread of two, made by clicking a person in the chat (anyone you share a thread with is there); it ends when either person leaves, and clicking again starts a new, empty one. Your own Aqua opens from the shelf in a panel over whatever you are looking at — a private thread in your own athanor that reads your shared threads when you ask about them, or the one the chat has open with each message when you tick it; what it reads there, other people's words included, goes to your model provider — and a line from it reaches a shared thread only when you say it aloud — a deliberate, attributed copy. Sign in on a phone and "Add to Home Screen" — Prism installs like a native app.

Around the desktop:

- **Chat** — on the shelf along the bottom: your pairs and your shared threads, with how many hold messages you have not read: a panel on a desk, a sheet that fills the screen on a phone. A thread opens in place. **New thread with people** names a title and people. A shared thread's header holds its people, adding someone by name, an invitation link, rename, leave and archive. The athanor's **Aqua** page at `/a/<athanor>/aqua` holds the soul, its crew, its scrolls, the pinned page and the notes drawer. A scroll Aqua proposes waits in its thread as a card until you press **Save as scroll**. What Aqua keeps out of a thread is a note — the `notes` tool's `keep`, `pin`, `list`, `read`, `search` and `forget` — and a schedule with `keep_outcome` in its metadata files each run's output as one.
- **The crew** — who Aqua hands a job to. A crew member is a file under `aqua/crew/`: a brain (a model's catalyst, or a coding harness such as Claude Code, which runs as itself in its program's folder on your own plan), what it is good at and what to avoid, and the brain's options from what the brain itself declares. It has no prompt of its own: CYFR tells every member how a job arrives and where its reply goes, and the job Aqua hands it names the scroll to follow. A crew file that still holds instructions below its header is refused, and Aqua's page says how to keep them as a scroll. Aqua's prompt lists the members whose brain is ready, and `crew.ask` hands one a job: the member works it in a thread of its own under yours, holding every tool Aqua holds, and its reply lands on your thread whether it finished, failed or was stopped; `@name` in your thread asks one yourself. Aqua and a crew member may make, change, pause and remove a schedule from a turn as you do on the **Schedules** page: one that holds a line for Aqua, at one time (`at`) or by cron, fires in the thread it was set from as Aqua's turn, whose line names who set it, and Aqua hands that member the job again; one set in a daily thread fires in the daily thread of the day it fires. The **Schedules** page names who set each schedule and where it fires, and you change or remove it as your own. How a job is done is a scroll any of them reads, named by its pack and its name: CYFR's own pack, `cyfr`, ships `cyfr:builder`, `cyfr:artisan`, `cyfr:planner`, `cyfr:research` and `cyfr:web` beside `cyfr:canvas` and `cyfr:capability-acquisition` (**Scrolls**, below). No crew member ships: **Set up Aqua** on the Aqua page offers one for each brain you connect that no member runs on yet, made when you pick its model from the brain's own list, its effort where that model lists efforts and, for a coding harness, its **Access**, and press **Make**; a member is its brain, model, effort and access together, and what it is good at and what to avoid are yours to write there or on its card; **+ New crew member** makes more, several on one brain if you like. Making a member and choosing the one Aqua runs on ask nothing: every member works under Aqua's grant. A member on Claude Code, OpenAI Codex, Antigravity, OpenCode or Cursor runs its program in the program row named `claude-code`, `openai-codex`, `antigravity`, `opencode` or `cursor` (**Installing a harness**, under Programs). OpenAI Codex takes CYFR's tools when it first works in a thread and keeps those for that thread: a tool added to the soul's list later reaches it in a thread it starts afresh, and one taken off is still refused. Once it starts a helper agent of its own, its usage is counted as partial, since Codex does not say whether its count holds the helper's. A post it had taken when it stopped may be missing from what it kept: the thread then says that post is not handed to it again. Aqua and every crew member are offered the tools the soul's file lists (`tools` in `aqua/aqua.md`), one action an entry (`files.read`, the provider's own search `native_search`, or an outside server's `server:tool`) and no wildcard: for every action of a tool, list each one, and add a new action yourself when a later release brings it. The Aqua page shows that list as **What Aqua may use**, in groups: each of your MCP servers with its tools, then its resources and its prompts, each off until you switch it on there, then each of CYFR's own tool families by its name, Browser, Search and Scrolls. A group's switch turns all of it on or off at once, an entry no brain would be handed says why, and any switch asks for Aqua's grant again before its next turn. Opening the page asks each MCP server that is on what it offers, starting one that is not running, and a server that does not answer says so in its group, with **Ask again**. An outside server's tool is offered like CYFR's own, to a member on an API brain or a coding harness alike, as `server__tool`, and each of its calls goes through CYFR, which holds the server's credentials: Aqua's grant names each server the list names, with exactly the tools listed of it, shown on its sheet and not chosen there. A server's tool is handed only while that server lists it and the grant covers the server as it is set up now, and only when every brain can carry it whole: names of letters, digits, `_` and `-` (neither holding `__`, the server not ending in `_` nor named `mcp`, the tool not beginning with `_` nor named `resources` or `prompts`), 64 characters in all as `server__tool`, a description of at most 16,384 characters, a definition of at most 131,071 bytes, and no argument named `result`, `error`, `action` or one CYFR stamps on a call. A server's resources and prompts are two more of its entries, `server:@resources` and `server:@prompts`, offered as `server__resources`, which lists the server's resources with their templates and reads one by its uri, and `server__prompts`, which lists its prompts and gets one with its arguments: each is handed only while the server declares it, a binary resource is named by its type and size rather than read out, and each is granted only by naming it, whole, so a grant of a server's tools by `*` covers neither, and a server's resources are granted all or none, its prompts likewise. The **Aqua** page sets each member's brain, options and lines. A member on a coding harness has an **Access**, one of the choices the harness's driver offers, named in its words; today each harness offers one (Claude Code its default mode, OpenAI Codex, Antigravity, OpenCode and Cursor full access with no approvals), so the choice is shown and cannot be changed. Access is the harness's own setting, not a limit of CYFR's: CYFR answers the harness's permission questions with allow, and every member, on a harness or an API brain, can use every tool it is offered. A member on Claude Code, OpenAI Codex, Antigravity, OpenCode or Cursor also has the MCP servers you set up in that program itself, beside CYFR's tools: they are the program's own, so their calls do not go through CYFR, and neither the soul's list, a grant nor a member's access decides what they do. Aqua has no brain of its own: it runs on the crew member its card names under **Runs on**, with that member's brain, model and options, and a new athanor's Aqua runs on no one until you choose one there or in **Set up Aqua**. The member Aqua runs on still takes jobs of its own under its own name.
- **Scrolls** — procedures kept in packs, each pack a folder under `aqua/scrolls/` as its author published it, in the Agent Skills layout (`skills/<name>/SKILL.md` and the files beside it), and each scroll named by its pack and its name, `mine:release-notes`. The Aqua page's **Scrolls** shows the packs as cards: `cyfr`, CYFR's own, which follows CYFR's update and changes only with it; packs you bring in; and packs of your own, `mine` first, where the scrolls you made before packs now live. **Bring in a pack** takes a `.zip` or `.tar.gz` you upload, such as a skill pack from a GitHub repository, and shows one sheet first: its scrolls, scripts, hooks, agents, commands and the MCP servers it would start, and what its scripts can reach in your programs' sessions; **Bring in** keeps exactly the files the sheet showed, and a brought pack is kept as published until you bring in an update, which shows what changed, scripts and hooks first. **New pack** makes a pack of your own with its first scroll; in a pack of your own a scroll has **Edit** and **Delete**, files beside a scroll are written through Files (`aqua/scrolls/<pack>/…`, the same writes the page makes), and a file that begins with `#!` runs. A scroll of a brought pack has **Copy to my pack**. Each card has a switch: a pack switched off is in no index and no program's folder. **Download** gives any pack back as the archive it would be brought in by, to publish wherever you like. Aqua reads the scrolls of the packs switched on with `aqua.skill_get`, from an index in its instructions, and a scroll its author kept from the model (`disable-model-invocation: true`) is left out of Aqua's index and read when a job or another scroll names it. Aqua or a member on Claude Code or OpenAI Codex gets no index: its program loads the packs as its own skills (**Installing a harness**, under Programs).
- **The gear** — on the shelf: the settings, the Dashboard's pages, opened over the desktop while its apps keep running, with the drawer (the top bar's menu, on every screen size) listing them: **Aqua**, **Files**, **Vault**, **Schedules**, **Webhooks**, **API Keys**, **Programs**, **Settings**, **Tips**, **Legal**. The × goes back to the desktop. **Tips** holds short answers to what the first screen leaves out — changing the desktop and asking Aqua to change it, the two modes, letting people in, API keys and scripts, where a failure is explained — each with a "Show me" that opens the page or the desktop it talks about. Connect a model to Aqua in **Aqua**'s setup, which opens while Aqua has none: it lists every installed brain with what it needs, a key someone shared with you first; each brain you tick is one step, its grant sheet taking your key, and CYFR then asks the brain for its models and shows what the provider answered. The shipped model catalysts name their connection on each request; CYFR attaches the key in the host, and the catalyst receives no key.
- **Canvases** — the desktop (`/a/<athanor>`) shows your canvases, each your own page, written in HTML, CSS and JavaScript like any app and showing what it reads, with the apps you open over them, each a window, a tile at an edge or full, arranged as you leave it. Move between canvases with the dots on the shelf along the bottom, Ctrl+Alt+1 to 8, Ctrl+Alt+←/→ while no app is active, or a swipe on the shelf; only the canvas you are looking at reads and acts. A canvas changes nothing in CYFR, and what it reads can leave your browser as any app's can. Ask Aqua for a canvas and it writes one (`canvas.write`) as a new version; your browser validates the version before it shows it, keeping the version it replaces. A **feed** runs one operation of an installed component on an interval, and a canvas reads its results by the feed's name; Aqua can bind one, and the **Schedules** page lists and removes them. A canvas that does not start, or whose page stops, is replaced by the standard canvas while your windows and Aqua stay as they are, with one line offering to try it again or restore its last working version.
- **`lite` / `dev`** — a per-person preference in Settings, not an edition. `dev` adds the developer views — **Executions**, **Activities**, **Enforcements**, **Components**, **Builds**, **Registry**, **Reports** — in a sidebar with live indicators; the ops surface stays reachable in `lite`, it just isn't the face. `lite` is everyone's default but the administrator's, who starts in `dev`.
- **⌘⇧K** — the command palette, also from the drawer's Search… row.

Tinctures can stay private inside Prism, or be made public and shared at CYFR's address, `<address>/t/@<namespace>/<publisher>/<name>`: `http://localhost:4000` with local access, which only its own computer reaches; `https://<machine>.<tailnet>.ts.net` with tailnet access, which your tailnet's devices reach through Tailscale Serve; and `https://<your domain>` with public access, through Caddy under a certificate it obtains over ACME. See [Deploy to a Server](#deploy-to-a-server). A canvas is never public: it is your own data page, so no public profile is staged for one and the public route serves none.

## Project Layout

After `cyfr init`, your project looks like this:

```
your-project/
├── configuration-guide.md # Every setting the server reads, with its default
├── integration-guide.md   # How to use CYFR as your app backend
├── component-guide.md      # Full guide to building components
├── tincture-guide.md       # Guide to building tinctures
├── identity-guide.md       # Your account at every CYFR: name, keys, recovery code, signing in
├── devices-guide.md        # Adding devices to your account and confirming sensitive changes
├── docker-compose.yml      # Self-hosted stack: cyfr, locus and its guard (+ tailscale for tailnet access, caddy for public access)
├── Caddyfile               # The reverse proxy of public access: everything → cyfr's proxy listener
├── keeper.seccomp.json     # The seccomp profile Locus runs under (see "Execution workers")
├── .cyfr/                  # How CYFR is reached, as `cyfr` keeps it: the stack's lock, the change in flight and recent outcomes (git-ignored; no snapshot holds it)
├── .env                    # The stack's keys and config, written by `cyfr init` (do not commit)
├── .env.example            # The starting .env: init's keys and the deployment choices
├── .env.locus.example      # Locus's own settings, one file for every role (copy to .env.locus)
├── .gitignore
├── LICENSE, LICENSES/, FAIR_SOURCE.md   # The license notices
├── wit/                    # WIT interface definitions for WASM components (developer reference)
│   ├── reagent/
│   ├── catalyst/
│   └── formula/
├── aqua/                   # The Aqua template every athanor is given: aqua.md (the soul), skills/
└── data/                   # ALL runtime state — one directory, .gitignored
    ├── cyfr.db             # Vault entries, consents, execution records
    ├── cache/              # Immutable cached artifacts (OCI blobs)
    ├── system/             # Server-internal scratch (health probes)
    ├── shared/             # One tree per shared thread: its attachments
    └── athanors/           # One tree per athanor — each person's own
        └── <athanor id>/
            ├── components/ # {type}s/{publisher}/{name}/{version}/
            │   ├── catalysts/   # Bundled: files, http, claude, openai, gemini, grok, openrouter
            │   ├── reagents/    # Your local reagents
            │   ├── formulas/    # Bundled formulas: list-models
            │   └── tinctures/   # Bundled example tinctures + your own
            ├── aqua/       # The athanor's own Aqua: the soul, its crew, its packs of scrolls
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
> units whose files you edit in place, `threads/` holds the files of Aqua's
> threads, which you may read and delete there, `notes/` is read there and
> managed on its own page, and the server's own storage
> (`payloads/`, `staging/`, `objects/`, the seed, the cache) is not a folder at all.

On **Files**, pick files under `data/` and choose **Send a copy** to offer
a snapshot to someone you share a thread with. They accept or decline
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
cyfr run c:local.claude:1.4.4

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
to see what's available, then grant one on the Components page: open
it and choose **Grant access**.

```bash
# Run what you granted
cyfr run c:local.claude

# Install another component from the registry
cyfr pull c:acme.supabase
```

The grant sheet walks the consent flow: it shows what the component asks
for, lets you pick a vault entry for each need, renders exactly what you
are approving, and records it as an immutable consent revision. A grant
covers every release of that component line. The component's grants
are listed under it on Components, each with **Revoke**, which takes it
back, effective on the next run; `cyfr profile list <ref>` shows them too.

The **Vault** page stores each entry with the hosts, scheme, port, methods
and paths it may be sent to. Entries are attach-only by default; disclose
one only when a component must read its fields. A provider's default
suggests a choice on the grant sheet and binds nothing by itself. Each
binding has its own lifetime: standing, until a time, or once under one
root run. **Share** offers an attach-only API key or bundle whose
destination names its methods and paths to everyone on this CYFR or to one
shared thread you sit in, with optional daily caps per person and in total. The
people it is offered to see it under **Shared with you** and pick it on
their own grant sheet, and CYFR attaches the key to their requests without
disclosing it. **Shared by you** lists your shares with today's use, where
you change a share's audience or caps or revoke it. A platform admin's key
shared with everyone is what a new person's Aqua uses at first sign-in when
it fits. Entering or rotating a key, sharing one, or widening who it is
shared with requires fresh confirmation.

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
```

The development loop is: **edit source → `cyfr build compile <ref>` → `cyfr run <ref>`**. Each compile saves the `.wasm` binary, auto-registers the component, cleans build artifacts, and pulls any missing dependencies. A Rust build is locked to the component's `Cargo.lock` after its first build; compile with `--resolve` after changing a dependency.

A version's **Push** on the Components page pushes a local component to the registry under your **personal namespace**, the name your account holds at cyfr.run ([identity-guide.md](identity-guide.md)) — `c:local.my-api` is pushed as `c:<your-name>.my-api`. **Sync push tokens** on the Registry page mints and stores your push tokens by a request you sign with your passkey in a new tab. A sign-in mints none: it asks the registry only for the name your account holds, while this CYFR has no name for you, and stands whatever the answer. A push whose namespace has no stored token, or whose token the registry revoked, refuses and says to sync your push tokens on the Registry page.

### Tinctures

Tinctures are CYFR's frontend component type — sandboxed HTML/JS/CSS apps managed by the runtime. They run inside Prism (private, authenticated — over your canvases in **Canvas**) or as standalone public pages at `https://<host>/t/<athanor>/<publisher>/<name>` (when explicitly made public).

```bash
# Scaffold a static HTML/JS/CSS tincture
cyfr new tincture stock-dashboard

# Or scaffold a React + TypeScript + Vite tincture
cyfr new tincture stock-dashboard --template react

# Build it
cyfr build compile t:local.stock-dashboard:0.1.0

# Open it in Prism (the athanor in focus is in the URL)
open http://localhost:4000/a/@alice/canvas

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

If you prefer a guided workflow, you can also use **Prism**'s **Aqua chat** to build components interactively. Aqua has access to component guides, file operations, build/execution tools, and component setup flows, so with a capable model configured it can handle a large share of the scaffolding and iteration for you quickly.

> See [component-guide.md](component-guide.md) and [tincture-guide.md](tincture-guide.md) for the full guides on building catalysts, reagents, formulas, and tinctures. See [integration-guide.md](integration-guide.md) for app-backend patterns and tincture data flows.

## External MCP Servers

Connect external MCP-compatible servers (Context7, GitHub, custom tools) to make their tools available alongside CYFR's built-in tools. Add one on the **Programs** page: its definition is a JSON object, such as `{"url":"https://api.githubcopilot.com/mcp/"}` for GitHub or `{"url":"https://mcp.notion.com/mcp","headers":{"Authorization":"vault:notion-key"}}` for Notion.

```bash
# Test the connection
cyfr mcp test github

# List all connected servers
cyfr mcp list

# Server tools appear as github:tool_name in your tool list
```

A component's chain calls a server's tools by those names once its grant covers the server. From outside a chain, by `cyfr call github:tool_name`, the API or `/mcp`, a server's tools are reached only when its config sets `"console": true`; without it the call is refused and names the setting.

Header values support vault references (`vault:ENTRY_NAME`, or with a scheme,
`Bearer vault:ENTRY_NAME`) — the named vault entry's single field is resolved at request
time, after the scheme when there is one, so credentials stay encrypted at rest and never
appear in the server config. The entry's destination must cover the server's URL: a
definition whose header names an entry it does not cover is refused at create, at update
and again when it connects. A definition names only its own athanor's entries,
never a key shared with you.

## Deploy to a Server

CYFR is self-hosted as a small `docker compose` stack:

| service | what it is |
|---|---|
| `cyfr` | the one endpoint on `:4000`: Prism (chat + console, a PWA), API, MCP, tinctures; its host API on `:4300` takes the runtime's host calls, signed with a runtime worker's key, from the `locus` network alone |
| `locus` | the one Locus, built from `Dockerfile.locus` as the `cyfr-locus` image: its keeper, `cyfr-locus`, starts a role process for each role whose key `.env` holds, each under a user of its own, in a space of its own, with its own run folder, its own memory and processor bounds and a channel to the keeper that reaches its own spawns alone. The **runtime** (`:4200`) runs WASM components as cyfr assigns them, each subtree in a runner VM under a uid of its own, holding one derived key and no tenant state; see [Execution workers](#execution-workers). The **builds** role (`:4100`) compiles components and tinctures, each build under a uid and a memory bound of its own, whenever `CYFR_LOCUS_BUILDS_KEY` is set, as `cyfr init` writes it; see [Builds](#builds). The **backends** role (`:4101`) runs the programs an athanor defines — `npx` MCP servers (filesystem, github, …) and the harnesses people and brains drive — each process under a uid and a memory bound of its own, its lines going to and from CYFR; the `homes` volume holds the folders programs keep; see [Programs](#programs). No role sees another's key, processes, files, port or spawns. A role that dies has its spawns retired and starts again alone; the keeper's own end, or its guard's loss, ends all three roles and every spawn, and the container starts again |
| `locus-guard` | Locus's egress guard: the same `cyfr-locus` image running `cyfr-guard`, holding `NET_ADMIN` alone, in a network namespace of its own that `locus` shares, and the one member of the `locus` network beside cyfr, under the name `locus`. It makes each role process's, each build's and each program session's one route out of its space before it starts, so a build reaches public hosts and the private hosts `CYFR_PRIVATE_EGRESS_TARGETS` names, a program the hosts its row names or, with none, public hosts and those private hosts, the runtime's role process cyfr's host API, and none of them another space; `locus` starts only once the guard is healthy, with every rule installed |
| `caddy` *(profile: `public`)* | TLS terminator and reverse proxy of public access, forwarding to cyfr's proxy listener. Started only when `CYFR_ACCESS=public` in `.env` |
| `tailscale` *(profile: `tailnet`)* | Tailscale Serve for tailnet access: HTTPS at the machine's tailnet name, forwarding to cyfr's proxy listener; its loopback SOCKS5 proxy lets this device's own browser reach that address. Started only when `CYFR_ACCESS=tailnet` in `.env` |

Three ways CYFR is reached, `CYFR_ACCESS` in `.env`:
- **local**: this computer only. Prism at `http://localhost:4000/`.
- **tailnet**: your devices on Tailscale; also runs tailscale (`--profile tailnet`). Prism at `https://<machine>.<tailnet>.ts.net/`.
- **public**: a domain, for anyone who signs in; also runs caddy (`--profile public`). Prism at `https://<your domain>/`.

Local is the base, and Tailscale and Caddy are add-ons: `cyfr init` writes local into `.env`, with every setting it implies, and [`cyfr access <mode>`](#how-cyfr-is-reached) changes it to tailnet or public, with the address and the tailnet machine or the certificate email. `cyfr access status` shows it. `cyfr up` selects the proxy's profile from `CYFR_ACCESS`. Whatever the mode, cyfr serves on its loopback listener, `:4000` on this machine's loopback alone; tailnet or public access adds the proxy listener its proxy forwards to, which no port publishes.

There is **no censorship-circumvention layer** here — Tailscale and Caddy give you TLS, not unblockability; if your network actively blocks endpoints, put this stack behind a separate obfuscated transport.

### Prerequisites

- A Linux VPS (or any Docker host) with Docker + the Compose plugin: **Docker Engine 28 or later on a cgroup v2 host**. On Ubuntu 26.04 LTS at a terminal, `cyfr init` installs them from Ubuntu's archive when your account cannot reach Docker. Locus holds each role and every runner, build and backend to bounds of its own, a cgroup `cyfr-locus` makes for it, which needs the container's `security_opt: writable-cgroups=true` (in the shipped `docker-compose.yml`; it adds no capability). Without it — an older engine, a cgroup v1 host, or the option removed — nothing runs unbounded and nothing runs: `cyfr-locus` refuses to start, saying it can make no cgroup group for a role, and the container restart-loops, so no component runs, every build is refused as `unavailable`, and no program starts.
- A host that allows unprivileged user namespaces, and Locus under the shipped seccomp profile: every role process, runner, build and program session gets a user, network and IPC namespace of its own (see [Execution workers](#execution-workers)).
- Size: 2 processor cores, 4 GB of memory and 20 GB of free disk run CYFR for a few people. Idle, the stack holds under 1 GB of memory. Under load cyfr and Locus's roles grow up to their bounds, which add up to about 12 GB (cyfr 2 GB, the runtime 4 GB, builds 4 GB, the backends 2 GB), so a machine that builds components and runs several programs at once wants 8 GB or more, or lower limits in `.env` ([configuration-guide.md](configuration-guide.md#compose-only-variables)). Their processor bounds are 4 cores for cyfr, 4 for the runtime and 2 for builds; more cores let more run at once. A release's images take about 3 GB; `cyfr update` pulls the next release's beside them and leaves the old ones (`docker image prune -a` removes them once no container uses them), and the data grows with what people keep.
- For public access: a domain pointing at the VPS. For tailnet access: a Tailscale account. For local access: nothing extra.
- Firewall: **public** opens `80/tcp`, `443/tcp` (+ `443/udp` for HTTP/3). In every mode CYFR publishes `4000/tcp` on `127.0.0.1` only (`CYFR_PORT` changes it). With **tailnet** access, CYFR also publishes SOCKS5 `1055/tcp` on `127.0.0.1` only, for the device's own browser; it opens no port to other machines. This is a general proxy on this machine's loopback for the device's own browser; a program on this machine can reach through it whatever the sidecar can reach.

### Setup

Use the `cyfr` CLI — it downloads `docker-compose.yml` + `Caddyfile`, writes `.env` for a CYFR reached from this machine with the stack's keys minted into it, and brings the stack up:

```bash
# Install the CLI (on Ubuntu 26.04 LTS the installer offers to install
# cosign to verify it; elsewhere it installs the CLI only):
curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh
#   …or, on a Mac, the CYFR app with its cyfr:  brew install --cask cyfrworks/cyfr/cyfr

mkdir my-cyfr && cd my-cyfr
cyfr init        # installs Docker on Ubuntu 26.04 LTS if missing, downloads compose + Caddyfile, writes .env and its keys
cyfr up          # starts cyfr + locus and its guard (and the proxy of tailnet or public access)
```

`cyfr init` asks nothing about how CYFR is reached. It makes a CYFR reached from this machine and ends:

```
CYFR is set up in this directory, reached from this computer at http://localhost:4000.
Want it on your phone and laptop too? Run cyfr access tailnet first.
Next: cyfr up. Then open <setup link> to set up its first person.
```

Before it, each image it pulls is one line, `Pulling <image> ...`. `cyfr access tailnet` reaches CYFR from your other devices on Tailscale, and `cyfr access public --domain <your domain>` from the internet; each gives CYFR a new address.

On a machine with no display it adds `From another computer: ssh -L 4000:127.0.0.1:4000 <account>@<this machine's name>, then open the link there.`, with your login name and the machine's name filled in. On a first start, with no one set up yet, `cyfr up` ends on the same step: `Open <setup link> to set up its first person.`, the ssh line beside it as above, or, with tailnet access, `Open <setup link> on your phone or laptop, with Tailscale on, to set up its first person.` A later start prints `CYFR server started.` and Prism's address alone. Run again in a project whose `.env` exists, `cyfr init` prints `Added to .env: <names>.` when it added keys `.env` lacked, and ends `Next: cyfr up.`

`cyfr init` mints every key the stack needs into `.env`: `CYFR_SECRET_KEY_BASE`, `CYFR_LOCUS_BACKENDS_KEY`, the [execution worker](#execution-workers)'s root `CYFR_LOCUS_RUNTIME_ROOT` with the `LOCUS_RUNTIME_KEY` derived from it for the worker's service id (`wrk_locus` unless `.env` names another `LOCUS_RUNTIME_SERVICE_ID`), the [builds](#builds) key `CYFR_LOCUS_BUILDS_KEY`, and the setup token `CYFR_SETUP_TOKEN`, which nothing removes. It also assigns [`CYFR_CORS_ALLOWED_ORIGINS`](#cors-allowlist) the empty allowlist, which admits no cross-origin caller and which the shipped stack's same-origin clients never notice. Run in a project whose `.env` already exists, it adds only the keys `.env` lacks and never rewrites one: with no root and no service key it mints both, with a root alone it derives the service key from it. A service key with no root beside it, or one the root beside it does not derive, is refused with a sentence naming the fix, and nothing is written.

<details><summary>Prefer a source checkout?</summary>

```bash
git clone https://github.com/cyfrworks/cyfr && cd cyfr
cp .env.example .env
# edit .env:
#   CYFR_SECRET_KEY_BASE — `openssl rand -base64 48` (at least 64 bytes; a blank or shorter value refuses the boot)
#   CYFR_ACCESS, CYFR_HOST — local and localhost, as .env.example has them;
#                          `cyfr access tailnet|public` writes another mode's settings
#   CYFR_LOCUS_BACKENDS_KEY — `openssl rand -hex 32`
#   CYFR_LOCUS_RUNTIME_ROOT      — `openssl rand -hex 32`
#   LOCUS_RUNTIME_KEY     — `env CYFR_LOCUS_RUNTIME_ROOT=… mix cyfr.locus.runtime_key wrk_locus`
#                          (see "Execution workers" for the openssl equivalent)
#   CYFR_LOCUS_BUILDS_KEY — `openssl rand -hex 32`

# with the CLI, as for any CYFR:
cyfr up
# …or, for local access without it, outside the supported path (see "How CYFR is reached"):
docker compose up -d
```
</details>

Once you are set up, open the address `cyfr up` prints (`http://localhost:4000/` with local access), sign in, and you're in your athanor's chat. "Add to Home Screen" installs it as a PWA (works on phones too). With tailnet or public access the proxy forwards everything to cyfr's proxy listener — Prism, `/api`, `/mcp`, `/auth` and `/t` on the same origin. The `cyfr` endpoint (`:4000`) is always published on `127.0.0.1` so the `cyfr` CLI and a local browser work from the host.

**CYFR on the machine's own screen.** On Ubuntu 26.04 LTS on amd64 or arm64 with no desktop, `cyfr init` asks before it writes anything:

```
This machine has no desktop. Show CYFR on its screen?
  1. Yes. At power-on this screen shows CYFR full screen, with an on-screen keyboard.
  2. No. This screen keeps its login prompt, and you open CYFR from another machine.
Choose 1 or 2 [1]:
```

With `--no-interactive` it asks nothing and the screen keeps its login prompt. The first answer, once `.env` is written, and `cyfr screen on` in a project directory show the commands and run them through one `sudo` (`cyfr screen on` asks first; answered no, it installs nothing and exits 0): labwc, wvkbd and swayidle from Ubuntu, the CYFR app of this cyfr's release unless the app's own cyfr already answers that release, its package's checksum read from the release's signed checksums before anything is asked and the package downloaded only after the yes and checked against it (`Downloading the CYFR app, release 0.6.0 for amd64, and checking it against the release's signed checksums.`), and a service that takes tty1 from the login prompt at the next boot. `cyfr init` then ends with `Next: cyfr up, then sudo reboot.` and `At power-on this screen opens CYFR's setup page, which makes its first person's account with this box as its first device.`, and a first `cyfr up` with `Now run sudo reboot. This screen opens setup at power-on.`, or, once the screen runs, `Setup is on this screen (Ctrl+Alt+F1).` At power-on the CYFR app, one frameless window covering the screen above an on-screen keyboard, opens the box's own pages, which `cyfr screen shell` serves on this machine's loopback alone, at `http://127.0.0.1:7340/`: until CYFR answers they say how to start it, and Ctrl+Alt+F2 gives a terminal; then they set the box up, with **Set up CYFR** or **Add this box to my account** ([devices-guide.md](devices-guide.md#the-boxs-own-screen)), and from then on ask the box's PIN or passphrase and open Prism with a one-time ticket, locking again after five minutes without input, whatever is playing on it. A lock hides the screen first, confirmed by the compositor's own list of windows: an app that has not hidden its windows 2 seconds after a lock is ended from outside and starts again on the lock page. The screen never starts or stops CYFR, so `cyfr down` stays effective across a reboot. `cyfr screen off` gives tty1 back to the login prompt and leaves the packages and the app; `cyfr uninstall` removes the app where this cyfr may, and a cyfr the app's package owns leaves its removal to the system's package tool and says so. Where the app is another release than the folder is set to, the screen's pages say so, with the `cyfr update --version <release>` to run in the folder, which brings the app to the folder's release.

**Setting up from a terminal.** `cyfr setup` opens the CYFR app with the current directory as the folder its **Or set up CYFR on this computer** suggests in place of `~/cyfr`, where **Set up and start** does what `cyfr init` and `cyfr up` do there and asks nothing ([devices guide](devices-guide.md#the-cyfr-app)); an app already open is shown as it is. It needs the app installed, the `cyfr-desktop` package on Linux, `CYFR.app` in `/Applications` on macOS, the CYFR installer's on Windows, and says `cyfr setup opens the CYFR app, which is not installed here. Run cyfr init at a terminal.` without it; on a Linux machine with no display it says `This machine has no display for the CYFR app. Run cyfr init here instead.`

**Upgrading.** `cyfr update` is the one command for it: it brings the `cyfr` program to the newest release, then the CYFR in the current directory to the program's release, and two releases never run side by side on one database.

- **The program.** When the newest release is newer than this `cyfr`, `cyfr update` installs it: the newest published release that is not a pre-release and, while none is published, the newest pre-release, the rule the install script and the server's update notice follow too. It installs it through `brew` for a Homebrew cask install. Where the CYFR app is installed, whichever `cyfr` runs the command, the app is updated whole by its own installer, outside the app: the release's installer for this machine is downloaded and verified against the release's `checksums.txt` signed by the release workflow for that tag; then the elevation it needs is asked for (`sudo` for the DEB, before anything closes; see below for the DEB's update service, which asks none); then the running app is closed, or on the box's own screen the screen's service stopped, so its launcher cannot start the old app while it is replaced; then `apt` installs the DEB, the whole signed app replaces the one in `/Applications` on a Mac, or Windows Installer installs the MSI; then the release the app's own `cyfr` answers is checked, and the app opened again as it was (the box's screen comes back locked). A refused password, an installer that fails or another release installed leaves a working app at its release and the CYFR in the folder untouched, and says what to run again. A `cyfr` installed any other way, by the install script or a download, replaces its own file once the release's archive for this platform verifies the same way, so the command you type is never left behind the app; both downloads verify before anything changes, and the update then says `The CYFR app and this cyfr, <path>, are release <version>.` A `cyfr` inside an app's bundle is never rewritten alone. On Windows, close every other terminal that runs `cyfr` before you update: Windows Installer ends the programs of a terminal in which a file it replaces runs, and only the `cyfr` running the update steps aside for it. On Linux, an update run from a session with no display, such as a terminal over SSH, closes the app on the computer's desktop and cannot open it again from there: open CYFR on the desktop, then run `cyfr update` again. On Linux the app's package carries CYFR's update service, which installs a newer release of the app as root with no password, for an account in the `sudo` group, from a terminal, over SSH, and on the box's own screen alike: `cyfr update` names only the release, and the service refuses one that is not newer than the installed app, downloads the release's DEB itself and verifies it against the release's signed `checksums.txt`, and that it is the app's package at that release, before anything closes, then installs it with `apt` (stopping and starting the box's screen around it), and nothing else. A release it refuses, one that does not verify or is not newer than the installed app, is the update's answer: `cyfr update` says so and stops. Where the service cannot be used, because it is not on the machine, the account is outside the `sudo` group, root cannot download the release (through a proxy only your account knows, say) or the service ends without an answer, and for an older release `--version` names, which the service never installs, `cyfr update` says why and goes through `sudo` as above. A second update started the moment one ends can find the service still finishing the first and goes through `sudo`, saying so. On Linux, an update through `sudo` cut off while `apt` installed the app (a closed terminal, a lost connection, a restart) can leave `dpkg` interrupted, and `apt` then refuses every install, saying so: run `sudo dpkg --configure -a`, then `cyfr update` again. It then goes on as the new program, so the one command finishes the job. Once a release that is not a pre-release is published, pre-releases (`0.6.0-alpha.1`, `1.0.0-rc.2`) are no longer chosen this way: `cyfr update --version <version>` installs exactly the release it names, a pre-release or an older release included, and the install script does the same with `CYFR_VERSION=<version>`. A Homebrew install takes only its tap's release, the newest that is not a pre-release. In a directory that holds no CYFR, `cyfr update` stops after the program.
- **In the app.** On a desktop, and on the box's own screen while it is unlocked, **Update** at the foot of the app's list of CYFRs opens **Update CYFR** over the CYFR shown: it names the app's release and the newest, and what updating does. Its button runs the same `cyfr update`, by the app's own `cyfr`, apart from the app, which closes, is replaced and opens again at the new release, with **Update CYFR** showing what the update said, kept for this account alone in `~/.cyfr/device/update.log` until the next update; **Update CYFR** opened from the list shows it on request, with when it was last written. On Linux it goes through CYFR's update service where its socket takes your account, and says so; where it does not, and `sudo` would ask for a password, it says why and shows the line to run in a terminal instead. On the box's screen the service stops the screen, installs the new release and starts the screen again, which comes back locked; a lock closes **Update CYFR**. The app's update leaves the CYFR set up on this computer on its release, as `cyfr update` answered no leaves it: once the app has opened again, **Update CYFR** offers that CYFR's change as `cyfr update` shows it, and its button makes the change only where that CYFR's folder, its release and its `docker-compose.yml` are still as they were read for it.
- **CYFR.** In CYFR's directory it then fetches the release's `release.json` and its signature and verifies them: signed keyless by the release workflow of that version's tag, naming that version. Without network access to the release, or with a manifest that does not verify, it refuses and changes nothing, as it refuses a `docker-compose.yml` without a service named `cyfr` and a service running `ghcr.io/cyfrworks/cyfr-locus` (`cyfr init --force` regenerates the file and keeps `.env`). `docker-compose.yml` is the release's own: the update replaces yours with the new release's, so an edit of yours is carried over by hand from the snapshot. Before anything stops it compares your file with the one the release CYFR runs shipped, image lines aside; a file you changed is said, its differing lines (no environment value) and, in a sentence of its own, each managed service whose volumes differ, since the stack would start without the data the folders you mount there hold, and it asks `Replace docker-compose.yml with release <version>'s and update this CYFR?`, the answer defaulting to no. `--yes` does not answer that question: with no terminal to ask on, the update refuses with the same words. It then shows the release CYFR is on, that the release's `docker-compose.yml` replaces yours, each managed image that changes, by its repository, each image line of yours it does not manage, which the new file does not keep, and where the release notes are, and asks before changing anything (`--yes` makes the change without asking; with no terminal and no `--yes` it shows the change and makes none; answered no, it changes nothing and exits 0). A CYFR already on the program's release is not switched again, with no stop and no snapshot: it is started as `cyfr up` starts it and waited for whole, so an update run again after one whose services did not come up waits again. A CYFR on a newer release than the program, by its compose file's tags or by the release its running cyfr reports, is refused before anything stops, since older code never starts over a database a newer release migrated: restore a snapshot of the older release instead. A CYFR whose database was built from another schema than the release's, which its manifest names by fingerprint, is refused before it asks and before it takes the stack's lock, so the refusal changes nothing: the fingerprint is read through the running cyfr, or offline from its image while cyfr is stopped, in a one-off container that mounts nothing and never pulls, and the refusal says how to start over, since there is no upgrade path between schemas. An answer that does not read refuses as well. Once confirmed, in order, it:

1. fetches and verifies the release's scaffold files, its `docker-compose.yml` and `.env.example` among them, without writing them, and pulls every image the release's `docker-compose.yml` manages by the manifest's digest while the stack still runs; a failed pull changes nothing. It names the storage root it will snapshot as compose resolves it. On PostgreSQL it first reads the server's major through a client image the CLI pins by digest, one for each of PostgreSQL 14 to 18, and pulls the pin of that major for the dump; a server of another major refuses the update before anything changes;
2. refuses while a server of the [cluster](#several-servers-on-one-database-a-cluster) on another release than this one runs outside this stack;
3. cancels a tailnet join waiting for approval, stops every service, printing how long each took (the update holds the stack's lock, `.cyfr/lock` in the project directory, from before its first docker call to its end, as `cyfr restore` and `cyfr access` do, and `cyfr up` holds it across its own start: `cyfr up` refuses while an update runs, and an update refuses while a start runs), and reads the cluster's slots with the server stopped: any server of another release still holding one after a lease (15 s) starts the old stack again and ends the update;
4. copies the cluster into `backups/<timestamp>/`: the database (the SQLite file, or a `pg_dump` in the PostgreSQL server's own major version), the storage root, every managed scaffold file the release replaces as it stood (part `scaffold`, the keeper's seccomp profile among them), the keyring, `.env` and `docker-compose.yml` as it stood (part `compose`), with `snapshot.json` written last, so a backup without it is incomplete. `backups/` ignores itself for git, since a snapshot holds the keyring; An object store (`CYFR_STORAGE=s3`) is outside the snapshot: it relies on the bucket's own versioning;
5. writes the managed scaffold files and changes `.env` by the two releases' `.env.example` (read from their verified scaffolds, never the project's own copy, which `cyfr init` laid down and no update replaces): a line holding the old release's shipped value, where the new release ships another, takes the new value, a line you set that names a service of the old release's `docker-compose.yml` the new one does not run, as a URL, a host and port or an `id=URL` item of a list, is named by its key, its line and the service, never its value, with the exact edit (the release's host in that service's place, the rest of the line kept) and that CYFR cannot reach that host until each such line is changed and `cyfr up` is run, and left, and a setting assigned more than once is yours, none of its lines changed, and named with its lines. It then writes the release's `docker-compose.yml` in place of yours, its `image:` lines naming `ghcr.io/cyfrworks/cyfr` and `ghcr.io/cyfrworks/cyfr-locus` at the release's version and digest and the bundled caddy and tailscale at their tags and the digest, and says where the snapshot keeps the file it replaced; a failure of either puts the scaffold files and `.env` back from the snapshot and starts the old stack again. It then starts the stack and waits for cyfr's readiness, then, under the settings that start read, for every service of the stack within one 150 s deadline: healthy where it has a health check, running where it has none. A release that fails to start, or a service that does not come up, leaves the stack stopped, since old code never starts over migrated bytes, and the update prints the services that did not come up with `docker compose logs <service>`, the refusal a service's boot logged, the backup's path and `cyfr restore <backup>`.

A server whose release differs from a live server's is refused at boot, naming both releases. `cyfr init` run again in the project adds a key a newer stack needs that `.env` lacks, and changes nothing else. From a source checkout without the CLI: `docker compose pull && docker compose up -d` (add `--profile public` or `--profile tailnet` for public or tailnet access), which is outside the supported path (below). Check the [release notes](https://github.com/cyfrworks/cyfr/releases) first: there is no compatibility layer for behaviour, and a release says what it changes for a running server. A database built from an earlier version of the schema is not carried forward: `cyfr update` refuses before it stops anything, and the server refuses to boot on it and names the database to recreate.

**Uninstalling.** `cyfr uninstall`, in CYFR's directory, takes CYFR's stack and this program off the machine: it stops CYFR as `cyfr down` does and removes nothing else from your folder. It shows what it removes and what it leaves, then asks once (`--yes` answers; with no terminal and no `--yes` it removes nothing). After the stop it removes the stack's networks and the images its compose file names (one another container still uses stays), the screen service `cyfr screen on` installed, the CYFR app's package (`cyfr-desktop`) where this program is no package's and the link in `/usr/local/bin` (all as root, through `sudo`: an account outside the `sudo` and `admin` groups is refused before anything is asked, and a refused password changes nothing), and this program, by the path it runs from; a Homebrew install is left to `brew uninstall --cask cyfr`, and the `cyfr` inside the CYFR app's package to the system's package tool (`sudo apt remove cyfr-desktop`), which removes the app and its update service with it: a `cyfr` that is a package's, or may be, leaves the app's package alone and says which command removes it. On a Mac, the CYFR app installed from its disk image is closed and removed from `/Applications` whole, the `cyfr` inside it with it, and its link in `/usr/local/bin`; on Windows the app is Windows Installer's, and the uninstall names its removal (CYFR in Windows' Settings, Apps, Installed apps). A `cyfr` inside an app is never removed alone: it goes with its app. The program or its link stays when the folder holds it, or holds what it resolves to. It leaves every file in the folder as `cyfr down` leaves it (the compose file, the Caddyfile, `.env`, `.gitignore`, the guides, `.cyfr/`, `data/`, `backups/`), the stack's volumes, this program's settings files in `~/.cyfr` and this machine's device key, and ends by naming each by its path, with the one command it gives: `docker volume rm` for the stack's volumes, by name. Each step is said as it is done; when one fails, it says what is gone and what is still here.

### How CYFR is reached

CYFR starts reached from this machine alone, as `cyfr init` makes it. `cyfr access <mode>` changes how the CYFR in the current directory is reached: `cyfr access local`, `cyfr access tailnet`, or `cyfr access public --domain <your domain>` (and `--acme-email <email>` for the certificate authority's account, if you want one). It shows the change before making it: who will reach CYFR and at what address (`CYFR will be reached by your devices on Tailscale at https://cyfr.<tailnet>.ts.net.`), with the ports public access opens, then each other setting that changes, before → after, and what changes when the address changes, unless no one is set up on CYFR yet: CYFR has never started in this directory, or cyfr's log since its start says no one is set up on it. Answering no changes nothing, says what stands (`Nothing changed.`, or after a join `Nothing changed. This machine stays on your tailnet as <name>; run cyfr access tailnet again when you want CYFR reached there.`) and exits 0. Once you confirm, or pass `--yes`, it stops the stack and checks it stopped, rewrites `.env`, and starts what was running in the new mode. When that start fails, it stops what the new mode started, writes the previous mode back and starts it, and reports what it reached: CYFR running as before (on this machine only, when its tailnet machine is not ready to serve it), CYFR left stopped when the previous mode does not start either, or, when a stop cannot be checked or a write fails, a change to finish with `cyfr access --resume`. `cyfr access status` shows how CYFR is reached, what runs, the proxy's health and the last change's outcome, and changes nothing.

A change holds the stack's lock and keeps its progress in `.cyfr/` in the project directory. When one is interrupted, by a closed terminal or a restart, run `cyfr access --resume`: it finishes the interrupted change under the lock and reports what happened. The next `cyfr up`, `cyfr update`, `cyfr restore` or `cyfr access` does the same before anything else.

A start that leaves CYFR answering on this machine only, because its tailnet machine is not the one `.env` names, has not joined, or has HTTPS certificates off, exits with status 3 and says what to do; Tailscale Serve stays closed until `cyfr access tailnet` serves CYFR on the tailnet again.

**Choose the address once.** A new address, from another tailnet name, another domain or another mode, means every browser signs in again there and each command line connects to CYFR there anew; your people's accounts and passkeys stay as they are, since they live at the account service (a CYFR that serves its own account service keeps its address for good): [devices-guide.md](devices-guide.md#when-cyfrs-address-changes) lists what changes. On a CYFR that never started, the change ends on `Next: cyfr up. Then open <setup link at the new address> to set up its first person.`, and on a running CYFR no one is set up on, on the setup link at the new address as `cyfr up` says it. When the project shows CYFR on the machine's own screen, `cyfr access` changes nothing of the screen: the screen reads the folder each time it starts, and a running screen whose folder now names another address starts again there.

**Tailnet access.** These steps are yours, once:

1. Create a Tailscale account, and install the Tailscale app, signed in, on the phones and computers that will reach CYFR.
2. In the Tailscale admin console's DNS page, turn on MagicDNS and HTTPS certificates. Without HTTPS certificates the machine joins, but CYFR is not served on the tailnet, and `cyfr access tailnet` says what to turn on.

`cyfr access tailnet` then joins this machine to your tailnet: open the link it prints and approve the machine (on a machine with a display it opens it in the default browser, unless `--no-open` is given), or join it with an auth key, read from the file `--tailscale-auth-key-file` names and never written to `.env` or a log. CYFR is then at `https://<machine>.<tailnet>.ts.net/`, through the `tailscale` service, with no port opened to other machines. Its SOCKS5 proxy on `127.0.0.1:1055` lets this device's own browser reach the same address through the sidecar. That connection enters through Serve's proxy ingress and carries no loopback-ingress authority.

- **Certificate names are public.** Every HTTPS certificate's name, the machine's full tailnet name included, is published in public certificate logs. Use a randomized tailnet name and a neutral machine name: `cyfr`, unless `--hostname` gives another.
- **The name is the address.** Renaming the machine gives CYFR a new address (above). `cyfr access tailnet --new-node` replaces this machine's tailnet identity, so CYFR can take another name; remove the old machine on the admin console's Machines page.
- **Tailscale's hosted service** hands out the tailnet's keys. Tailnet Lock limits that trust, and CYFR's own sign-in applies either way: CYFR reads no Tailscale identity header, so everyone who reaches CYFR still signs in.

**Public access.** `cyfr access public --domain <your domain>` serves CYFR at `https://<your domain>/` through the `caddy` service, which obtains its certificate over ACME. The domain must point at this machine, and ports 80 and 443 must be open (see [Prerequisites](#prerequisites)). Once the change is made, `cyfr access public` resolves the domain from this machine and says `Done.` only when it resolves; otherwise it says that no one reaches CYFR there, and no certificate is issued, until the domain's DNS names this machine.

**The supported path.** `cyfr up`, `cyfr access`, `cyfr update` and `cyfr restore` run Docker Compose themselves, with checks of their own. They hold the stack's lock. They clear every `COMPOSE_*` variable from their environment, select the files and profiles from CYFR's settings, and refuse a `.env` that sets a `COMPOSE_*` variable, since Compose would read it to choose the stack's files, project or services behind cyfr's back. They refuse a compose file that sets an access setting in the `cyfr` service's `environment:` or drops its `env_file: .env`. They open Tailscale Serve only once the tailnet machine is the one `.env` names. And they make a change of mode one journaled change, which the next of them recovers if it is interrupted. Running `docker compose` directly is outside that path and skips all of these. The server's own boot check stays either way: a release refuses to start on access settings in `.env` that contradict each other, with the sentence that names the fix.

### Programs

The **Programs** page lists two kinds of row. A **tool server** elsewhere (`"transport": "http"`) is an MCP server CYFR reaches at its URL. A **program** (`"transport": "program"`) runs in Locus's backends role instead: a command the athanor's admin defines (in your own athanor, that is you), run by the backends role as a process whose lines go to and from CYFR, which signs every message to the service. Every program is the same kind of row; its **mark** says how it is spoken to:

- **`mcp`** — an MCP server that launches with `npx -y …` or any command. CYFR's MCP client speaks to it over the process's lines, and its tools surface as `<row>:<tool>` — `github:search_repositories`, … — on CYFR's tool list.
- **`driven`** — a program a person or a brain runs: a coding harness such as Claude Code or OpenAI Codex, which a crew member runs as its brain with its own tools, on your own plan, its command starting with the harness's driver (`cyfr-claude-code`, `cyfr-codex`).

Adding a program from Prism:

1. Open **Programs** in the drawer and click **Add program**.
2. Give the program a name (e.g. `github`), the command (e.g. `npx -y @modelcontextprotocol/server-github`), how it is spoken to (MCP here), and its env, one `NAME=value` per line. A credential is always a vault template — `GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token`, naming a single-field disclosed entry on the **Vault** page (an attach-only entry is refused at create and when the program starts); only `NODE_ENV`, `LOG_LEVEL`, `TZ`, `LANG`, `LC_ALL`, `NO_COLOR` and `DEBUG` may hold a literal, and a command may never name a vault entry, because every process of the program's own session can read its command line.
3. Confirm the program: CYFR shows its whole definition — the command, the mark, the folder, the hosts, the bounds, and each environment name with the vault entry it names (`GITHUB_PERSONAL_ACCESS_TOKEN=vault:github-token`; a literal by its name alone) — and makes the row once you confirm it with your passkey or paired device. The confirmation is bound to that definition: it makes no other.
4. On first use the backends service starts the program and CYFR asks it for its tools. Aqua uses them like any other external MCP tool.

Over MCP, the same program is `mcp_servers.create` with `{"transport":"program","mark":"mcp","command":"npx -y @modelcontextprotocol/server-github","env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"vault:github-token"}}`, in a session signed in on the screen, confirmed the same way. A program is one command and one environment: a package that bundles several MCP servers is a row for each server, each with its own name, folder and tools.

**Edit** on an expanded program replaces its whole definition, at the version it was read at, and keeps its folder. Every edit that changes the definition — its command, mark, folder, hosts, bounds, or any environment variable, a literal's value included — is confirmed as an addition is, and every grant that uses the program asks again; saving it unchanged asks nothing. Making a program a tool server elsewhere removes it as a program. **Remove** is confirmed too, and its confirmation says, before you give it, that the program's sessions end, its folder goes with it, and which grants that use it, to run it or to call its tools, will ask again.

**Installing a harness.** CYFR ships a driver for five programs a crew member can run as its brain, and names each one's row and command once: `claude-code`, which runs `cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323`, `openai-codex`, which runs `cyfr-codex npx -y @openai/codex@0.169.0`, `antigravity`, which runs `cyfr-antigravity cyfr-fetch agy 1.5.16 …`, Google's release of that version for your machine, `opencode`, which runs `cyfr-opencode cyfr-fetch opencode 2.4.1 …`, OpenCode's release of that version for your machine, and `cursor`, which runs `cyfr-cursor cyfr-fetch cursor-agent 2026.11.22-e9042b2 --tree=cursor-agent … -- --disable-auto-update`, Cursor's own archive of its agent at that version for your machine, unpacked whole, each of the last three checked against its SHA-512 before it runs, each fetching its program at the version its driver was proved against into the program's folder. The setup on the **Aqua** page lists them among the programs and keys: ticking one offers **install `<name>`** while the athanor has no row of that name, the Programs page's form with the row as it will run, its command shown and editable. Accepting asks you to confirm the program once, makes the driven program that keeps its folder and opens its terminal in that folder, where you sign it in as the program asks (Claude Code and Antigravity show an address and ask you to paste back the code its page shows; with Codex, **Open** it with the words `login --device-auth`; OpenCode works with its own free models unsigned, and to use a provider of yours, **Open** it with the words `auth login` and connect one: a key provider asks for its key, and ChatGPT shows an address and asks for the address your browser was sent back to; with Cursor, **Open** it with the word `login` and open the address it shows, in any browser, to sign in with your Cursor account). **Back to Aqua** returns to the setup, where the program reads installed and can be chosen for a crew member. Opening the page starts no program: CYFR asks one for its models only when you choose it under **New crew member** or press **Edit** on a card. It reads signed in or signed out only as the program itself said then, or when a turn started it; an error or a busy CYFR never reads as a sign-out. A member whose program is signed out is greyed, with **Sign in**, which shows the program's terminal on the Aqua page, the one still running when there is one, and asks the program again when that terminal ends, and **Change**. You may also define a row by hand. The programs are yours and each fetches itself: CYFR's image carries none of them, only what CYFR runs itself, Aqua's browser among it. In the sessions CYFR starts, Claude Code and OpenAI Codex load the packs you switch on (**Scrolls**) as their own skills, beside yours, from a read-only folder of the session: Claude Code each pack as a plugin, named by its `.claude-plugin/plugin.json` or else by the pack's name, and Codex each pack's `skills/`. The program and its model decide what to use, and a Claude Code plugin of yours named like a pack gives way to the pack in those sessions. A program's own terminal loads none of them, and Antigravity, OpenCode and Cursor read the packs through CYFR's index. Antigravity reaches CYFR's tools through a socket only its own session reaches, by a server named `cyfr`, or `cyfr-2` and on where a server of your own in the program already has that name, so none of yours loses its place, and has three lacks of its own: its usage is counted as partial, since it does not count the title it asks its model for; a message you send while it waits on one of CYFR's tools goes in when its turn ends; and when a thread is deleted, its session's own files are removed but its title and summary stay in Antigravity's own index of sessions, which CYFR never writes. OpenCode reaches CYFR's tools the same way, and calls them, as it calls every MCP server's, from code it runs in its own tool `execute`: the thread shows `execute` running and each of CYFR's calls beside it. Its lacks: CYFR's instructions reach it as the opening of a thread's first message, not as its system text, and a change to them reaches a session already made the same way; its usage is counted as partial, since it counts neither the title it asks for nor a helper agent's work; when a helper agent of its own finishes after its turn, OpenCode works on by itself and the thread does not show that work, though its next turn knows it; and when a thread is deleted, OpenCode deletes the session itself, though its words can stay in the free space of its database until it reuses it. A command you run on its terminal, `auth login` among them, leaves OpenCode's own background server running in that terminal's session, which ends with it. Cursor reaches CYFR's tools the same way; its row tells it not to update itself, so you change Cursor's version on its row. Cursor starts the servers of your own `~/.cursor/mcp.json` only once you approve each on its terminal, with the words `mcp enable <name>`, since the program works in its own folder, which Cursor reads as a project of its own; CYFR approves nothing for you, and CYFR's own server needs no approval. Its lacks: CYFR's instructions reach it as the opening of a thread's first message, not as its system text, and a change to them reaches a session already made the same way; its usage is unknown, since it reports none; a message you send while it works goes in when its turn ends, since Cursor would stop the turn for it; CYFR names its server when a thread first starts, so a server of yours added later under that very name gives way to CYFR's in that thread, and yours is back in the next one; and a turn that failed, which Cursor ends as if it had answered, is shown as an error only when Cursor said nothing else in it, so a turn that failed after it began shows Cursor's own words as its answer, and a reply that is nothing but words of exactly that form is shown as an error.

**Kept folders.** A program's folder (its row's `home`) is `scratch` — made for each process and scrubbed when it is retired — or `kept`: the row's own folder, made when the program first runs and removed with the row, so a program stays signed in and keeps what it fetched. The program runs with that folder as `HOME` and finds what it or you install there first: its `PATH` is CYFR's drivers, then the folder's `.local/bin`, where `npm install -g` puts a tool, then the image's. It runs under a uid of the folder's own that no other folder, pool or program is given while the folder lasts; every session of the row shares it, and no other row's program is offered it. A program is signed in when it says so, and you sign it out and in again in its terminal. No CYFR process can read a kept folder. A kept folder is removed with its row, with its athanor, and by **Reset folder** (`mcp_servers.reset_home`), which leaves it empty under the same uid. A kept folder is a program's whole disk and is never in a backup: a restore does not bring it back; after a restore, signing the program in again in its terminal makes the folder anew.

**A program's terminal.** **Open** on any expanded program runs its command, followed by the words you type after it, on a terminal in CYFR's own frame on the Programs page: the frame names the program, and nothing the program writes reaches beyond the terminal — it sets no title, writes no clipboard, rings no bell, and an address it prints opens only when you click it, an http or https one alone. The program belongs to you, not to the page: reload the page or open it in another tab and you see the same running screen, and leaving ends nothing. What reaches the program is what you type and the terminal's own answers to the program's standard queries, such as where the cursor is; nothing the program prints makes the terminal send text the program chose. It ends when it exits, when you **Close** it, after a day with nothing attached and nothing printed unless you mark it **Keep running when no one watches**, when its program is changed or removed, or when you no longer have access to the athanor; signing out of a browser ends nothing. When it ends, its screen stays as it was, to read, beside why it ended, until you close the frame. The expanded program lists your running sessions of it, to show again or close. CYFR stores nothing of what passes through it and logs none of it, not even the words you typed after its command.

**A program in a turn.** Aqua and its crew run a program for a turn on a terminal of the turn's own (`program.start`), and the run ends with the turn: the turn waits on it with `program.wait` as long as it takes, which answers once the program prints more and pauses, or ends, and `aqua.wait` waits until a time. A message you send while the turn waits ends the wait early: the turn reads it and may wait again, and the run goes on meanwhile. A wait holds its turn, and a crew member's program, in memory until it ends; a restart of CYFR ends the run, and the turn learns that it ended.

**Bounds.** A program's row may set its memory bound (`memory_bytes`; without one each process gets the service's own, `LOCUS_BACKENDS_MEMORY_BYTES` in `.env.locus`, 512 MiB) and a kept folder's disk bound (`home_max_bytes`; without one the `homes` volume is the only bound). The service starts a program only while the memory bounds of the programs it runs, the new one with them, fit its budget, `LOCUS_BACKENDS_MEMORY_BUDGET` in `.env.locus` (1792 MiB by default, three programs at the default bound, times `LOCUS_BACKENDS_MEMORY_OVERCOMMIT`, 1), and one athanor's fit the `athanor_program_memory_bytes` setting (unset, the whole budget); past either the program is refused as busy and asked for again later, never left for the kernel to end. The container's limit, `LOCUS_BACKENDS_MEMORY_LIMIT` in `.env` (2G), is the budget plus 256 MiB for the service: raise the two together. A kept folder is measured every 10 s while its program runs: at its bound, or when it cannot be measured whole, its processes are ended and the folder refuses to start a program until it is reset.

Defining or changing a program — `mcp_servers.create` and `update` — takes a person signed in on the screen, in Prism or on the box, and a fresh confirmation as above. A definition decides what runs and where it sends the vault entries it names, which is a person's decision like granting a vault entry to a component. An API key holding `admin` can list, inspect, test, refresh, restart, enable, disable and delete programs and tool servers, but defines none; removing a program asks the key's person to confirm it, and only a person signs a program in.

How it holds together:

- **One key.** `CYFR_LOCUS_BACKENDS_KEY` (32 random bytes as 64 hex digits) is in `.env`; `cyfr init` generates it and compose gives it to `cyfr` and, as `LOCUS_BACKENDS_KEY`, to `locus`, whose backends role starts only with it, and cyfr refuses programs without it (and `CYFR_LOCUS_BACKENDS_URL`, which compose sets). Its per-program memory bound lives in `.env.locus` (copy `.env.locus.example`); the kept folders' uid range and root are the keeper's `--kept-homes` flag in compose's entrypoint.
- **Nothing of CYFR's on disk.** The backends service persists nothing of CYFR's: no definition, no credential, no line. CYFR sends a server's definition when it is first used — its env resolved from the vault and sealed to that server and that service lifetime — and again for every running server when the service restarts. When CYFR restarts, the service releases what the previous boot ran, and each program starts again on its next use. Programs run only while CYFR keeps renewing their lease (30 s; `CYFR_LOCUS_BACKENDS_LEASE_MS` sets it). The kept folders on the `homes` volume are the programs' own.
- **Sessions.** Each running process is a session for one key, with a numbered buffer of the lines it writes (each at most 1 MiB, 8 MiB held), read again by number when an answer is lost. A session that ends — its program exited, was idle, or was retired — answers so, and the next use starts the program again; CYFR's MCP client then initializes it afresh.
- **Idle programs stop.** A session with no line sent or read for 15 minutes (`CYFR_LOCUS_BACKENDS_IDLE_MS` sets it) is ended and its pool slot freed; the next use starts it again — for an `npx -y` package, downloading it again unless it keeps its folder.
- **Isolation.** Each process of a scratch program runs under a pooled uid of its own (`locus-backend01`…`32`) with a private home directory that is scrubbed when it ends; a kept program's process runs under its folder's uid. Each runs with an environment built only from its server's env and no capability. One athanor's programs hold at most a quarter of the pool. A server's requests reach only its own programs, and every line is masked with that server's credentials. Each process is held to its memory bound, ended there alone. Each process may use `LOCUS_BACKENDS_CPU_QUOTA` of CPU (two CPUs by default). Each session runs in a space of its own: its own loopback and one route out, its own processes, `/tmp` and home directory, and nothing of another session's; only its own session's processes read its command line, and none its environment. A credential the program reads from its env stays there; a command that expands a vault-bound env name places the value on its command line, and CYFR saves such a definition and warns about it (see the [integration guide](integration-guide.md#programs)).
- **Changes take effect at once.** Updating, disabling, deleting or restarting a server, or rotating, revoking or renaming a vault entry its env names, ends its sessions before anything else can reach them; the next use starts them again with the new definition. `mcp_servers.get` shows each program's status, sessions, crashes, a masked stderr tail (for a kept folder, only its length) and its folder's measured bytes; **Restart** on the expanded row starts an MCP program's processes afresh. A disabled program reads as stopped: nothing runs it until it is enabled.
- Programs are not available when `CYFR_CLUSTER` is on.

### Execution workers

Components run on a worker service, not in `cyfr`: Locus's runtime role runs the WASM engine, and `cyfr` reaches it over HTTP to start and kill runs while the service carries its runners' host calls to `cyfr`'s host API for everything a run needs (its attempt, its credentials, its stream, its children). Every request and host call is authenticated with keys derived from one root, which only `cyfr` holds.

- **Two keys.** `CYFR_LOCUS_RUNTIME_ROOT` (32 random bytes as 64 hex digits) is the root, in `.env` and read by `cyfr` alone. `LOCUS_RUNTIME_KEY` is the key derived from it for the worker's service id, `LOCUS_RUNTIME_SERVICE_ID` (`wrk_locus` by default; another id is named in `CYFR_LOCUS_RUNTIME_WORKERS` too), and compose hands the id and the key to `locus`, whose keeper hands them to the runtime's role process alone, from `.env`. `cyfr init` mints the root and derives the key; by hand, the root is `openssl rand -hex 32`, and `CYFR_LOCUS_RUNTIME_ROOT=… mix cyfr.locus.runtime_key wrk_locus` prints the key from a source checkout, or `printf 'cyfr-locus/v1/runtime\nwrk_locus' | openssl dgst -sha256 -mac HMAC -macopt hexkey:$CYFR_LOCUS_RUNTIME_ROOT` is the same HMAC without one. The runtime never sees the root, the keyring or the database; it refuses to start with any of them in its environment, or with the builds or backends key beside its own. Changing the root ends every run in flight and needs every service key derived again: remove `LOCUS_RUNTIME_KEY` beside the new root and `cyfr init` derives it.
- **Who is where.** `CYFR_LOCUS_RUNTIME_WORKERS` lists the worker services `cyfr` dispatches to as `<service_id>=<url>` entries, tried in order; compose sets `wrk_locus=http://locus:4200`. `cyfr`'s host API listens at `CYFR_HOST_API_BIND:CYFR_HOST_API_PORT` (default `127.0.0.1:4300`; compose binds `cyfr`'s own address on the `locus` network, so it answers on that network alone, and serves only calls signed with a runtime worker's key) and `LOCUS_RUNTIME_HOST_API_URL` tells the worker where that is. An attempt's host calls go to the server that admitted it: the assignment carries that server's address, `CYFR_HOST_API_URL`, and the worker posts them there. With one server the address is the worker's own `LOCUS_RUNTIME_HOST_API_URL` and nothing more is set. `cyfr` asks each worker for its status every `CYFR_LOCUS_RUNTIME_WATCH_POLL_MS` and, after `CYFR_LOCUS_RUNTIME_WATCH_MISSES` misses in a row or when a worker comes back as a new boot, closes the runs that boot held as lapsed. The runtime's own settings are in `.env.locus` (copy `.env.locus.example`), one file for every Locus role.
- **Runners.** In Locus, `cyfr-locus` — the keeper binary every Locus role runs under — starts the runtime's role process as the `locus-runtime` user with no capability, in a space of its own, and runs every subtree in a runner: a VM of its own under a pooled uid (`locus-runner01`…`08`) with a private home directory on a tmpfs, holding no key, reached by the service alone over a control channel. The service runs only under `cyfr-locus`, which hands it the keeper channel: started any other way, a plain `mix` boot included, it refuses to boot, naming `cyfr-locus`, and no setting chooses another launcher. The service keeps `LOCUS_RUNTIME_POOL_SIZE` runners spawned ahead; a runner that completes cleanly is kept idle for its athanor for `LOCUS_RUNTIME_IDLE_TTL_MS`; one that was killed, lost a host answer or exited with attempts open is tainted, never assigned again, and retired — every process of its uid killed and its home directory scrubbed before the uid is reused — with `LOCUS_RUNTIME_RELEASE_GRACE_MS` to report what it held; a guest that ignores its deadline is halted by the runner's watchdog `LOCUS_RUNTIME_WATCHDOG_GRACE_MS` past it. `tests/locus-runtime-image/` runs each of these against the shipped image.
- **No network in a runner.** `cyfr-locus` clones every runner into a user namespace that maps only its own uid and gid, holding no capability, an IPC namespace of its own, and a network namespace of its own whose loopback is down, with no resolver, and which has no route: a runner reaches neither `cyfr`, nor the service's listener, nor the container's loopback, nor anything outside. What a run needs from outside leaves through the runner's relay, a socket to the service: its host calls, which the service verifies against the run's attempt and posts to `cyfr`'s host API, and its guests' outbound requests, for which the service takes the request from the run's rate and connects to the address `cyfr` pinned. Its guard routes the runtime's role process to `cyfr`'s host API and the private addresses a run's egress may reach, and enters its port from the `locus` network alone.
- **The seccomp profile and the host.** Docker's default seccomp profile denies the clone that makes those namespaces, so Locus runs under `keeper.seccomp.json` (Docker's default with that clone allowed, `unshare`, `setns` and `socketcall` denied, `socket`'s and `socketpair`'s domain and `personality`'s persona compared by their low 32 bits, as the kernel reads them, and every 32-bit and x32 call killed; the image carries it as `/etc/cyfr/keeper.json`). No 32-bit program runs in Locus. The shipped `docker-compose.yml` names it as `security_opt: seccomp=./keeper.seccomp.json`, which compose reads from the project directory: `cyfr init` and `cyfr update` write it there, and a source checkout copies `apps/locus/keeper/seccomp/keeper.json` there. The host must allow unprivileged user namespaces: `user.max_user_namespaces` above 0, and where AppArmor restricts them (`kernel.apparmor_restrict_unprivileged_userns=1`, as on Ubuntu 24.04 and later) the container runs under the AppArmor profile above, which allows them and the mounts that build a space's files; an unconfined container, a privileged one included, gets a namespace without the ids its runner needs. Without the profiles or the host's allowance `cyfr-locus` refuses to start, naming what to check, the service never starts and the container restart-loops.
- **Memory.** Every runner is held to `LOCUS_RUNTIME_MEMORY_BYTES` (384 MiB by default; 16 MiB to 1 TiB): its VM, every guest's linear memory, its home directory and the kernel memory charged to it, together. A runner that reaches it is ended whole by the kernel, the runs it held are reported, and it is never reused; a sibling is untouched. Each runner may use `LOCUS_RUNTIME_CPU_QUOTA` of CPU (one CPU by default). The runtime role's bound, `LOCUS_RUNTIME_MEMORY_LIMIT` in `.env` (4G), which `cyfr-locus` writes into the role's cgroup with swap the same, holds all eight runner uids at their bound and the service beside them — raise it with the bound. The bound needs the [Docker requirement](#prerequisites) above.
- **One versioned wire.** Every request, host call, answer and exit report carries the wire's version, `"v": 1`, as its first field, and every `x-cyfr-auth` header begins with its version token, `v1`. A listener refuses a header at another version as `unknown_version` before it reads the body, and a body without `v` or at another version as `unknown_version` before it reads the operation, so a worker and a `cyfr` at different versions of the wire refuse each other's work rather than misread it.
- **`cyfr` pins every outbound address.** The engine resolves no name. Before a run's outbound request its runner asks `cyfr` for the address (`egress_pin`), and `cyfr` resolves the host and decides the address under the run's admitted consent: a metadata address is refused before any policy, a private one only under the consent's `egress.private_ips`, and `CYFR_PRIVATE_EGRESS_TARGETS`, the server's own private targets, never applies to a run. The service connects to exactly the pinned address for the runner, keeping the host for TLS and the `Host` header, and streams the answer back through the relay. A redirect's next hop is pinned from the request it came from, and a hop to another scheme or host is refused (`redirect_credentials`), so a request's credentials never follow it to another origin.
- **Nothing on disk.** The worker keeps no state. A run's identity, budget, credentials and output live in `cyfr`; the worker holds only what it was assigned, sealed for its key, and reports a runner that exits. A worker restart ends its runs, which `cyfr` closes as lapsed.

### Builds

`cyfr build compile` runs in Locus's builds role, never in `cyfr`: `cyfr` sends a build's sources in a signed request and publishes the result it verifies, and the builder answers with the bytes, their digests and the build's diagnostics. With neither setting below, `cyfr` builds nothing and refuses every build, naming them; it runs no toolchain of its own.

Builds are on after `cyfr init`: it writes `CYFR_LOCUS_BUILDS_KEY` into `.env`, and the keeper starts the builds role with the rest of Locus. They need what the runtime needs anyway, **Docker Engine 28 or later on a cgroup v2 host** (see [Prerequisites](#prerequisites)).

- **One key.** `CYFR_LOCUS_BUILDS_KEY` (32 random bytes as 64 hex digits; `cyfr init` mints it, and by hand it is `openssl rand -hex 32`) in `.env`. With it set, `cyfr` builds in the Locus `CYFR_LOCUS_BACKENDS_URL` names, at its host on port 4100 (compose: `http://locus:4100`), and refuses to boot with the key and no backends URL, or with a malformed value. Compose hands the same key to Locus as `LOCUS_BUILDS_KEY`, which starts the builds role; the role refuses to start with any of `cyfr`'s own secrets in its environment.
- **Turning builds off.** Set `CYFR_LOCUS_BUILDS_KEY=` empty in `.env`, then `cyfr down` and `cyfr up`: the keeper starts no builds role, and `cyfr` refuses every build. `cyfr init` leaves an empty key empty.
- **Isolation.** In the builds role, `cyfr-locus` runs every build under a pooled uid of its own (`locus-build01`…`16`) with a private home directory on a tmpfs, and every process a build leaves behind is killed with its uid before the uid is reused. Only `cyfr` reaches the builds role, over the `locus` network; the network is not internal, because cargo and npm fetch from crates.io and the npm registry.
- **Memory.** Every build is held to `LOCUS_BUILDS_MEMORY_BYTES` (1 GiB by default): its processes, its home directory and the kernel memory charged to it, together. A build that reaches it is ended and answered as having reached its bound; a sibling build is untouched. Each build may use `LOCUS_BUILDS_CPU_QUOTA` of CPU (one CPU by default). The builds role's bound, `LOCUS_BUILDS_MEMORY_LIMIT` in `.env` (4G), holds `LOCUS_BUILDS_MAX_CONCURRENT` builds at their bound and the role beside them. The builder's other settings are in `.env.locus` (copy `.env.locus.example`). The bound needs the [Docker requirement](#prerequisites) above.

**`OOMKilled` is not the container's.** Docker marks the `locus` container `OOMKilled` whenever a runner or a build is ended at its own bound, though neither the container nor its release was touched: the kernel reports the kill in the container's cgroup tree. Read it as a runner or a build that passed its bound — the service's log says which — not as the container running out of memory; alert on the container restarting instead.

### Operator notes for shared servers and open sign-in

- **The seed `local.http` catalyst asks for wildcard egress** (`domains: ["*"]`, http+https; private IPs stay denied) and first-run provisioning consents the bundle automatically — on a server whose allowlist is `*`, that is a consented HTTP relay per signed-in stranger. The minted grant is pinned byte-for-byte by `apps/cyfr/test/sanctum/consent/bootstrap_golden_test.exs`, so widening or narrowing it is always a reviewed diff; narrow the seed manifest before opening sign-in to everyone if that posture is too generous for your deployment.
- **The audit trail carries identity fields.** The allowlist's refusal telemetry carries the person and the identifier it turned away (that is the audit content — who was turned away), and `Prima.Sanitizer` deliberately does not redact identity fields on the audit plane. Every entry is logged, and is also emitted once as the `[:cyfr, :audit, :recorded]` telemetry event carrying the sanitized `Arca.Audit.Event`: attach your own handler there to write the trail to a SIEM or an object store, and only to one that may hold PII.
- **Sign-in reads the account service; the registry serves what CYFR does not ship.** Every sign-in checks the account's keys at the account service this CYFR names (`CYFR_DIRECTORY_URL`, cyfr.run by default), within the freshness bound ([identity-guide.md](identity-guide.md#when-the-account-service-cannot-be-reached)). The person and their own athanor are minted at their first admission. The sign-in that follows copies in what CYFR ships and grants it, the desktop's canvas among it, before the person reaches the desktop; the athanor's fill then finishes in the background from the shipped bundle alone, since every dependency a shipped component declares, the Aqua formula's provider catalysts among them, ships with it, so a fresh athanor's fill pulls nothing. The bundle sync that runs again at each boot also reads the components installed since, and pulls from the registry a dependency one of them declares that is not present, such as one an interrupted install left behind. A fill that fails is retried on the next sign-in, with the cause in the server log and the `[:cyfr, :sanctum, :provisioning, :failed]` telemetry event, and Aqua stays unavailable until a retry succeeds. Every CYFR names a registry and calls it ([configuration-guide.md](configuration-guide.md)): an install cut off from the internet names one of its own. The registry is asked for a person's name at sign-in and for the components a person installs or publishes; when the one a CYFR names cannot be reached, those answer that the registry is unavailable, and the fill does not wait on it. Push tokens are needed only to publish (a version's **Push**, above), never to sign in.
- **A webhook's replay store is part of its delivery.** A webhook configured with an idempotency key header runs a delivery only once its claim is recorded; when the store cannot answer the claim, the delivery answers 503 `unavailable` with `Retry-After: 5` and runs nothing, and the `[:cyfr, :emissary, :webhook, :dedup_unavailable]` telemetry event is the alarm for the outage. The sender's retry runs it once the store answers.

### Reaching Prism on the server

Prism is served by the same endpoint as everything else, at CYFR's address: `https://<machine>.<tailnet>.ts.net/` from any device on your tailnet, or `https://<your domain>/` with public access. With local access, CYFR answers on the server's loopback alone; forward it over SSH:

```bash
ssh -L 4000:localhost:4000 <user>@<server>
```

Then open `http://localhost:4000` locally — with the port, which is what the
browser origin check trusts (a bare `http://localhost` is port 80, and a page
served there is not this server). With tailnet or public access the same
tunnel reaches CYFR's loopback listener, but a sign-in returns the browser to CYFR's address.

## Production Configuration

Everything below is optional — the defaults (accounts at cyfr.run, SQLite,
local `./data` storage) run a full instance with zero extra configuration.
Each option below is a deployment variable, set in `.env` (`.env.example`
carries the common choices commented out) and read at boot, and fails
loud: if an option is enabled but incompletely configured, the server
refuses to start rather than silently falling back.

The server's limits, windows and log level are **platform settings**: stored
in the database, the same on every server, and changed by a platform admin
on Prism's **Settings** page, a live one reaching
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
stand: none, as shipped. A release refuses to boot while the allowlist
holds the wildcard `*`, and says to list the origins instead; a local `mix phx.server` run only
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

### Requiring a company sign-in

A CYFR can require every person there to sign in with their company's
account, as a condition of being there. The company's issuer is WorkOS:

```bash
CYFR_COMPANY_LOGIN=renew          # off (the default), join or renew
CYFR_COMPANY_LOGIN_DAYS=30        # with renew alone
CYFR_WORKOS_CLIENT_ID=client_...
CYFR_WORKOS_API_KEY=sk_...
CYFR_WORKOS_ORGANIZATION=org_...
```

or, where WorkOS is not configured, your OpenID Connect issuer (Okta,
Auth0, Keycloak, Azure AD, …):

```bash
CYFR_OIDC_ISSUER=https://auth.example.com
CYFR_OIDC_CLIENT_ID=...
CYFR_OIDC_CLIENT_SECRET=...
```

`join` asks for the company sign-in once, and `renew` asks again every
`CYFR_COMPANY_LOGIN_DAYS` days. An OIDC issuer is set with all three of
its settings or none, and beside WorkOS it goes unused. Register
`<CYFR address>/auth/company/callback` as a redirect URI at the company's
issuer. The boot refuses `join` or `renew` with no issuer, an OIDC issuer
set in part, and WorkOS set in part or set while the mode is `off`.

The company sign-in never signs anyone in and never makes a person: a
person still signs in with their account. Until their company sign-in
stands, every page sends them to the company page (`/company-login`), and
the API keys they made and the devices they connected are refused.
[integration-guide.md](integration-guide.md#when-a-cyfr-requires-a-company-sign-in)
shows what an API client sees. CYFR binds a company account to one person
by the subject the issuer names, never by email. Moving to another OIDC issuer,
OIDC client ID or WorkOS organization, or between OIDC and WorkOS, makes
everyone sign in with their company again. Setting the mode back to `off`
requires nothing more and keeps the bindings.

### Signing in, and what a first sign-in needs

A person signs in at a CYFR with their account, the same one at every
CYFR ([identity-guide.md](identity-guide.md)). **Sign in with your
account** on the sign-in page sends the browser to the account pages of
the account service this CYFR names (`CYFR_DIRECTORY_URL`, cyfr.run by
default), where the person's passkey signs this CYFR's request, and back;
a device signs the same request itself after its local unlock
([devices-guide.md](devices-guide.md)). The CYFR checks the signature
against the account's keys and asks its allowlist, which judges accounts,
never how they signed in: an account its setup or an invitation admitted
is let in by the allow of its identifier that admission wrote, and any
other by `*` or an allow naming its identifier, `per_…`, unless a deny
names it. **Settings → Server allowlist** allows or denies a name
(`@name`) or `*`. An entry given a name keeps the identifier the registry
answers for that name when the entry is written, shown with the name. With no person yet the sign-in page offers
nothing but the way to set up: it says the CYFR is not set up and points
to the link `cyfr init` printed, or Open CYFR in the CYFR app that set it
up.

An invitation admits someone without opening sign-in to everyone. The
platform administrator creates an invitation link to this CYFR on
**Settings** (**Invite to this CYFR**); anyone in a shared thread creates
one that also seats the newcomer there, from the thread's header (or `cyfr
call invitation '{"action":"create","thread_id":"sth_…"}'`, with an
optional `"name"`, which the new account page fills in). The link is `<CYFR address>/invite#<code>`:
it is shown once, works once and expires after seven days, and this CYFR
keeps only the code's hash. Its page names who invited and to which thread,
if any, and offers **Sign in with your account** and **Create your
account**. Either redeems the invitation for the account that answers: it
makes the person here if this CYFR does not hold them yet, seats them and
writes an allow of their identifier, so they sign in later without the
link. That allow is written only where no deny names them, a
deny written later outranks it, and it shows in Settings' allowlist, where
it is removed like any other, except a platform
administrator's, which stays. The issuer or the
administrator revokes a link; a link whose issuer has since left the thread
or been denied, or whose issuer's standing has changed since it was made (a
restore from backup changes everyone's), admits no one.

The first person of a CYFR is made by its setup, and is its platform
administrator. An administrator makes another person of this CYFR an
administrator, or takes the mark away again, in Settings' allowlist, each
with a fresh confirmation; marking also allows the person's account, and
the last administrator's mark always stays. `cyfr init` and the CYFR
app's setup write the setup token `CYFR_SETUP_TOKEN` into `.env`, and
`cyfr init` prints the setup link, `<CYFR address>/setup#<token>`, which
the app opens on macOS and Windows; the token travels
only in the link's fragment, which no server log records. The setup page
offers **Sign in with your account** and **Create your account**: the
account that answers is admitted under the token and administers this
CYFR, and from then on the link opens nothing. The box's own screen does
the same with **Set up CYFR**. A new account's recovery code is shown and
saved before anything is sent, and an account whose making stopped is
finished from the same browser or box with that code ([identity-guide.md](identity-guide.md)). This CYFR
records the person's name once the registry confirms it is their
account's: at a sign-in, which asks the registry for the name their
identifier holds; when they create their account from an invitation that
offered it; or with **Finish your name** in Settings.
Every admission at this server (setup, an invitation or the open admission)
makes the person with their own athanor, and an invitation adds the thread
seat it names. The athanor is seeded and baseline-consented
(the bundled `catalyst:local.http`
is granted `egress.domains ["*"]` for public hosts, GET/POST/HEAD, 60/min;
private addresses it cannot reach at all — its manifest declares no
`egress.private_ips`, which is the only private-address grant `cyfr` reads
when it pins a running component's outbound address, so a LAN device is
reachable from a chain as an MCP server on `CYFR_PRIVATE_EGRESS_TARGETS`,
which is the server's own, and not as a URL to fetch). Signing in does not
need the registry: the athanor's registry pulls run in the background (see
[Operator notes](#operator-notes-for-shared-servers-and-open-sign-in)), and
push tokens are needed only to publish. A deny of a person in Settings'
allowlist revokes their sessions and keys, archives their own athanor, removes them from every shared
thread (archiving their pairs and every thread they leave empty) and withdraws the
invitations that identifier was still holding; removing
the deny, or allowing the identifier, lets them back in and reopens their own athanor — thread seats are not
restored, someone in the thread adds them again. Work running in an athanor when it is
archived stops for good, on every server, whether or not the server heard:
a reopen admits only runs started after it.

### Opening sign-in to everyone (`*`), and the caps that bound it

An allow of `*` in Settings' allowlist admits every account of the account
service this CYFR names — that is the public-hosting configuration, and it is the one where the limits
matter. They are platform settings in
[configuration-guide.md](configuration-guide.md): the `tenancy` group's
athanors on the server, shared threads one person creates, pairs one
person holds, people in one shared thread, schedules, feeds and external
servers in an athanor, the bytes one athanor holds, and the athanors
minted per hour (`CYFR_MINT_PER_HOUR`, a rate). The athanor counts ship
with a generous default — 10,000 athanors, and 1,000 each of schedules,
feeds and external servers in one — and each is turned off with `0`;
the shared-thread counts and the bytes one athanor holds have no ceiling
until you set one. The mint rate is a bound
that is never 0: `CYFR_MINT_PER_HOUR=0` refuses the boot, and unset is no
bound.

A new athanor is provisioned with its own copy of the shipped bundle and
Aqua tree, so the athanor cap bounds tenancy and the storage cap each
athanor's whole tree; copying a shipped version in is never refused by the
storage cap, but its bytes count from then on. A specific deny always
beats `*`.

Closing sign-in to everyone again — removing the `*` entry — ejects
everyone it was the only reason for: their sessions end and the API keys they
created are revoked. Their standing is untouched (nothing is archived, no
thread seat is lost); that is what `deny` is for. The eject happens when the
entry is removed, so an allowlist row edited directly in the database, or a
`*` removed while the server is down, leaves live credentials behind — remove
it in Settings' allowlist on a running server.

### A CYFR for a household or a team

A household, a team or two people can keep their shared threads on one
always-on CYFR. Each person signs in there with the account they use at
every CYFR, as on any server; no key of theirs is held there, and nothing
of theirs elsewhere moves:

- **Letting them in.** The platform admin allows their name (`@name`) in
  Settings' allowlist, and anyone in a shared thread adds them to it the
  same way from the thread's header, each keeping the identifier the name
  belongs to; an invitation link from a thread does both at once. An
  identifier this CYFR has not admitted yet holds the seat until their first sign-in, and leaves a request for
  the operator while the allowlist would refuse them.
- **Signing in.** **Sign in with your account** on its sign-in page, with
  the passkey they use everywhere, or on a CYFR box of theirs; the first
  sign-in makes them an athanor of their own there, as it does for anyone
  it admits.
- **Confirming.** Their passkey, or a device of theirs after its unlock,
  confirms their sensitive changes there, as at any CYFR; nobody else's
  authorization is needed.
- **Leaving.** Leaving a shared thread, or being removed from it, ends that
  seat and nothing else: their athanor there, and its sessions and devices,
  are untouched. A deny is the one way out of the CYFR.

CYFR reads its people's accounts at the account service `CYFR_DIRECTORY_URL`
names, `https://cyfr.run` by default. Any operator, a household or a team
included, may serve their own (`CYFR_DIRECTORY_SERVE=writer`) and name it
there; its people's passkeys then live at that CYFR's address, and losing
that CYFR loses every account it serves. Who runs the account service
decides how long the accounts it keeps last:
[identity-guide.md](identity-guide.md) says what each loss costs.

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
  server. A server without one runs no component.
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
- Programs are not available in a cluster.
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

Before it admits any work, every server applies a declared restore under
its own slot, and a transition that fails refuses the boot. The same holds
after a restart inside a running server: when the database checks,
discovery, the server's claim, the bus or anything else before that step
restarts, it runs again before anything that admits work comes back, and
the web tier, whose crashes restart it alone, never restarts the rest.

### Storage paths

File storage defaults to the local `./data` volume — the one root holding
every athanor's tree, the caches, and (on SQLite) the database itself.
These variables move the pieces (dev and releases alike; tests pin their
own tmp roots):

```bash
CYFR_DATA_PATH=data                     # the one storage root
CYFR_SEED_PATH=seed                     # the seed tree, read in place: the
                                        # component bundle under components/ and
                                        # the Aqua template under aqua/
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
  in Locus's runtime role, which has its own bound (`LOCUS_RUNTIME_CPU_LIMIT`).

### Backup and restore

What to back up depends on the backends you configured:

| Backend | What holds state | Backup |
|---|---|---|
| SQLite (default) | `./data` (database, encrypted secrets, every athanor's components and files, caches) | `cyfr backup`, which stops a running stack for the snapshot and starts it again. Copying `./data` while the stack runs risks a torn SQLite snapshot. |
| Postgres | your database + `./data` for files | `cyfr backup`, which dumps the database with `pg_dump` beside the `./data` copy |
| S3 | the bucket + the database | enable bucket versioning/replication; `cyfr backup` holds the database but not the bucket |

A restore needs the **same `CYFR_SECRET_KEY_BASE`** — secrets are encrypted
with a key derived from it, so a restored data directory is unreadable under
a different key base. The session cookie's and the LiveView socket's signing
salts, `CYFR_SESSION_SALT` and `CYFR_LIVE_SALT`, are derived from the key base
unless `.env` sets them. Treat `.env` as part of the backup (it holds that key), store it
separately from the data backup if you can, and exclude `erl_crash.dump` and
`tmp/` from backup jobs — a crash dump can contain decrypted key material
from process memory.

**`cyfr backup`** takes the snapshot `cyfr update` takes before it changes
anything, into `backups/<UTC timestamp>/`: the database (the SQLite file, or
a `pg_dump` of PostgreSQL), the local storage root, the managed scaffold
files the directory holds, the keyring, `.env` and `docker-compose.yml`, with
`snapshot.json` written last. It takes the stack's lock first. A running
CYFR is stopped for it as an update stops it and started again afterwards,
also when the snapshot fails; a stopped one stays stopped. It refuses while
a server outside this stack still holds a slot of the cluster. A snapshot
holds the keyring and the database: keep it as you keep the data. `cyfr
backup`'s last line names the restore command.

**Restore is declared.** `cyfr restore backups/<timestamp>` puts a snapshot
`cyfr backup` or `cyfr update` took back: it refuses an incomplete snapshot or one whose
layout it cannot put back, stops the stack and bars the cluster from starting
before anything lands: it sets `CYFR_RESTORE_INCOMPLETE` in `.env`, which
the image's entrypoint, `cyfr up` and `cyfr update` refuse, and removes the
stopped `cyfr` container. It refuses while any server of the cluster still
runs, on any host and of any release, or while the PostgreSQL server is of
a major the CLI pins no client image for, and otherwise puts back the managed
scaffold files as they stood when the snapshot was taken, the database, the storage
root (each nested mount's bytes at its own source), the keyring, `.env`
and `docker-compose.yml`, and declares the restore before anything starts,
in a one-off container that sets the bar empty for itself alone:

```sh
docker compose run --rm --no-deps -T -e CYFR_RESTORE_INCOMPLETE= cyfr bin/cyfr eval 'IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())'
```

and only then takes the bar out of `.env` and starts the stack
(`--no-start` leaves it stopped). It runs as you, with no sudo, also on
native Linux, where the server's container owns the storage root once the
stack has run: the storage root and the SQLite file are written through
the stack, as `cyfr update` and `cyfr backup` read them, by one-off
containers of the snapshot's image (pulled first when this machine has
none), the binds they replace writable and every other mount of the
`cyfr` service read only, with no network, from what `cyfr` streams them
of the snapshot; the declaration's run hands what they wrote to the
image's user, as every start does. A bind that is a parent of the storage
root (say `./:/app` with the storage root at `/app/data`) is writable to
those containers whole, and only their arguments keep the write inside
the storage root; on kernels before 5.12 Docker's read-only does not
reach a read-only mount's submounts. `.env`, `docker-compose.yml`, the
scaffold files and `.cyfr/` are written as you, and a project folder you
cannot write is refused before anything stops. A restore cut short anywhere leaves the
bar up; `cyfr restore <backup>` run again puts every part back and
declares it. While that bar is up, the restore of another backup refuses a
database that does not answer, which the one cut short may have left half
written, and names that restore to run again first. A backup put back by hand, with no bar in `.env`, is declared
by the same command, with the whole cluster stopped, before its first start.
The next boot retires what the backup's authority
could still do before it admits anything: every session ends; API keys
and webhook secrets are suspended until their person re-enables each from
the system layer's checklist under a fresh confirmation; every device
connected there is suspended and its certificate revoked, and comes back
by connecting again as it did the first time; every component grant asks
for consent again; components' standing permissions, unused once-bindings and pending
confirmations are dropped; every invitation link still open and every
share are revoked; every stored credential is unusable until it is rotated
where it came from and entered again; and runs open at the backup end
uncertain and none resumes. No CYFR holds an account's keys, so people
sign in again with their passkeys and devices. A CYFR that serves its own
account service (`CYFR_DIRECTORY_SERVE=writer`) keeps its people's account
logs in the database the snapshot holds, so the restore puts each log back
as the snapshot held it: a change made after the snapshot (a key added or
removed, a recovery code added, everything replaced, an account made) is
gone from that service until its person makes it again, a key removed since
is listed again until then, and a CYFR that read the later log pauses that
person's work, since the restored log does not hold what it read; devices
keeping their keys does not keep the log.
[identity-guide.md](identity-guide.md) has the person's side. The
registry push tokens stay as the backup restored them. An object store (`CYFR_STORAGE=s3`) is
outside the snapshot: objects written since it stay in the bucket.

A snapshot holds neither this machine's tailnet identity (the
`tailscale_state` volume) nor `.cyfr/`, so a restore leaves the machine on
the tailnet as it is. When the restored `.env` is for tailnet access and
names another machine than this one, or this machine has joined no
tailnet, as on a new server, CYFR starts answering on this machine
only and `cyfr restore` exits with status 3, saying so. `cyfr access tailnet` then joins the machine, or offers
to move CYFR to the machine's current tailnet name. A new name is a new
address: everyone signs in again there, and each command line connects
there anew ([devices-guide.md](devices-guide.md#when-cyfrs-address-changes)).

A restore that is not declared keeps the backup's authority, and CYFR
cannot tell it was restored: sessions, keys and grants the backup holds
still work, and a revocation made after the backup was taken is not seen.
Declare every restore.

A backup restores the server, and an account only where the server serves
its account service: an account lives at its account service, and the
person recovers it with their recovery code at `/account/recover`. A CYFR lost with no backup to put back is set up anew,
and its people, admitted again by its setup and its invitations, sign in
with the accounts they have, with new athanors there; their athanors and
thread seats at every other CYFR stand. [identity-guide.md](identity-guide.md)
says what each loss costs.

## CLI Reference

Commands marked with `[i]` support interactive selection when run without arguments.

### Server

| Command | Description |
|---------|-------------|
| `cyfr init` | Set up a new CYFR in this directory, at a terminal, reached from this machine and asking nothing about how it is reached — on Ubuntu 26.04 LTS at a terminal first installs the Docker, Docker service and `docker` group membership the machine lacks, after showing the commands and asking, through one `sudo`; on a machine with no desktop asks, before it writes anything, whether its screen shows CYFR, and installs what `cyfr screen on` installs once `.env` is written; then downloads `docker-compose.yml` + `Caddyfile`, writes `.env` with the stack's keys and the setup token minted into it, creates dirs, pulls the images (`--no-pull`) and ends on where CYFR is reached and the next step: `cyfr up`, then the setup link (with the ssh command on a machine with no display); `--no-interactive` asks nothing; declining the Docker install changes nothing and exits 0; in an existing project it adds only the keys `.env` lacks, naming them (`--force` re-fetches the deploy files; never replaces `.env`) |
| `cyfr screen on` | Show CYFR on this machine's own screen at power-on, with no desktop, on Ubuntu 26.04 LTS on amd64 or arm64: shows the commands, asks, and runs them through one `sudo`; run it again to rewrite what shows it |
| `cyfr screen off` | Give this machine's screen back to its login prompt, leaving the packages and the CYFR app |
| `cyfr setup` | Open the CYFR app with the current directory suggested for setting CYFR up on this computer, a running app shown as it is; refuses without the app installed or, on Linux, without a display, naming `cyfr init` |
| `cyfr access <mode>` | Change how CYFR is reached, `local`, `tailnet` or `public`: asks first about a tailnet join the change needs, shows who will reach it and at what address, then each other setting that changes, before → after (the certificate email, the ports opened, a tailnet machine replaced, the port on this computer), and what an address change costs unless no one is set up on CYFR yet; a no changes nothing and exits 0; then stops the stack, rewrites `.env` and starts what ran (`--domain`, `--acme-email`, `--tailscale-auth-key-file`, `--hostname`, `--new-node`, `--yes`; a join's approval link opens in the default browser on a machine with a display, `--no-open` not; `--tailscale-auth-key-file` and `--hostname` apply to a new join, so a machine already on the tailnet refuses them without `--new-node`); when CYFR has tailnet access and its Serve is closed (HTTPS off, say), `cyfr access tailnet` serves it on the tailnet again; after a change of address it prints the setup link at the new address, which sets up the first person of a CYFR no one is set up on; `cyfr access --resume` finishes a change an interruption left |
| `cyfr access status` | Show how CYFR is reached, what runs and the last change, without the lock and changing nothing |
| `cyfr up` / `cyfr down` | Start / stop the stack under its lock: cyfr, locus and its guard, and the proxy `CYFR_ACCESS` selects (tailscale for tailnet, caddy for public); `up` refuses a `.env` that contradicts its access settings with the server's own sentence, and on a first start, with no one set up yet, ends on how the first person is set up: the setup link (from a phone or laptop with Tailscale on for tailnet access, through the ssh command for local access on a machine with no display), or this machine's screen (a reboot away until it runs); `down` stops and removes every container of the project and keeps its networks, and refuses a directory that holds no compose file, since the stack it stops is the directory's own |
| `cyfr update` | Update the installed CYFR app by its own installer and this program to the newest release (through brew for a Homebrew install), then the CYFR in this directory to it: shows what changes and asks (`--yes`), verifies the release's signed manifest, pulls every image of the release's `docker-compose.yml` by digest, stops the stack, snapshots it into `backups/`, writes the release's `docker-compose.yml` in place of yours, its images pinned to the release's digests (the snapshot keeps yours), and starts it, done once every service of the stack is up (see **Upgrading**); `--version <version>` installs exactly that release, a pre-release or an older one included; removes from `.env` each setting the release this CYFR ran shipped in its `.env.example` that the new release's `.env.example` does not declare, sets each line holding the old `.env.example`'s value to the new one's where it changed, names both, and names the lines you set that name a service the release no longer runs, leaving every value you set and `Caddyfile` alone, asks before it replaces a `docker-compose.yml` you changed (`--yes` does not answer that), starts a CYFR already on the release and waits for its stack, refuses a CYFR on a newer release and a `docker-compose.yml` without a `cyfr` service and a service running the `cyfr-locus` image |
| `cyfr backup` | Take a snapshot of the CYFR in this directory into `backups/`, the one `cyfr update` takes, which `cyfr restore` puts back; a running stack is stopped for it and started again; see **Backup and restore** |
| `cyfr restore <snapshot>` | Put a snapshot from `backups/` back with the whole cluster stopped (refused while any server of the cluster runs), declare the restore and start the stack (`--no-start` leaves it stopped); see **Backup and restore** |
| `cyfr uninstall` | Take CYFR's stack and this program off this machine (see **Uninstalling**): stops CYFR as `cyfr down` does and removes nothing else from your folder; shows what it removes and leaves, asks once (`--yes`), removes the stack's networks and images, the screen service, the CYFR app's package (on a Mac its bundle; on Windows it names Windows Installer's removal), the link in `/usr/local/bin` and this program, never the `cyfr` inside an app alone, keeping either when the folder holds it or its target; leaves the folder, the volumes, the settings files and the device key, naming each by its path and the volumes' `docker volume rm` |
| `cyfr apparmor-profile` | Print the AppArmor profile built into this `cyfr`, under its name, the one Locus runs under on a host with AppArmor, for root to install and load: `cyfr apparmor-profile \| sudo sh -c 'cat > /etc/apparmor.d/<name> && apparmor_parser -r -W /etc/apparmor.d/<name>'` |

> `cyfr --version` and `cyfr status` print a one-line hint when a newer release is available. The check only runs in an interactive terminal and is cached for a day; set `CYFR_NO_UPDATE_CHECK=1` (e.g. in your shell profile) to turn it off.

### Identity

| Command | Description |
|---------|-------------|
| `cyfr whoami` | Show who this command line calls CYFR as: the API key's name, its person's name and role (administrator or person), the address it called, their name at cyfr.run, or that it is not finished yet (Settings' **Finish your name**), their athanor, their publisher memberships and their id here (`usr_…`) |
| `cyfr status` | Check system health (includes CLI version) |
| `cyfr athanor get` | Your athanor: show it (whether it is provisioned, its settings, which you change on the **Settings** page, and the step a failed provisioning stopped at, which the Aqua panel's **Retry** retries) |

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
| `cyfr profile list <ref>` | Show a component's profiles and consent revisions; **Revoke** on a grant in **Components** takes one back |
| `cyfr run <ref>` | Execute a component `[i]` |
| `cyfr fork [type] <reference>` | Copy a published component into your local namespace for customization |
| `cyfr remove <ref>` | Remove a component `[i]` |
| `cyfr schedule list/get/update/pause/resume/delete` | Manage cron schedules for recurring execution, which the **Schedules** page makes `[i]`; `"keep_outcome": true` in a schedule's metadata files each run's output as a note in its athanor |

### Tinctures

| Command | Description |
|---------|-------------|
| `cyfr tincture visibility get <publisher> <name>` | Check whether a tincture is private to Prism or publicly reachable |

### MCP Servers

| Command | Description |
|---------|-------------|
| `cyfr mcp remove <name>` | Remove an external MCP server `[i]` |
| `cyfr mcp list` | List all connected MCP servers |
| `cyfr mcp get <name>` | Show server details and tools `[i]` |
| `cyfr mcp test <name>` | Test connectivity to a server `[i]` |
| `cyfr mcp enable/disable <name>` | Enable or disable a server |
| `cyfr mcp refresh [name]` | Refresh tool list from one or all servers |
| `cyfr mcp restart <name>` | Restart a program's processes |

### Security

| Command | Description |
|---------|-------------|
| `cyfr call vault '{"action":"list",…}'` | Manage vault entries (encrypted credentials): create/rename/rotate/rebind/revoke/delete, `authorize` for OAuth — also in the console's Vault page |
| `cyfr key create/list/get/revoke/rotate` | Manage API keys `[i]` |
| `cyfr call oauth '{"action":"set_client",…}'` | Store an OAuth app's client credentials per provider; user grants run through the grant sheet on **Components** and the console's Vault page |

### Administration

| Command | Description |
|---------|-------------|
| `cyfr log list/get/correlate` | View and inspect MCP request logs |
| `cyfr decision list/get/correlate` | View the athanor's admission decisions, and cross-reference a request's decisions with its logs and executions; a platform admin reads the host's own on the **Settings** page |
| `cyfr retention show/set/cleanup` | Manage data retention policies |
| `cyfr aqua list/get/status/skills` | Read the Aqua soul, crew, guides and scrolls, and see which files are shipped, edited or yours; Aqua's restore puts the shipped files back `[i]` |
| `file offer/offers/accept/decline/withdraw` (MCP) | Offer a snapshot of a file to someone you share a thread with, list the offers, and accept, decline or withdraw them |
| `file list/read/write/delete` (MCP) | The athanor's files as the Files page shows them — `data/` open, `components/` and `aqua/` shaped, `threads/` read and delete, `notes/` read-only |
| `cyfr registry whoami` | Show registry identity (push tokens, claimed namespaces) |
| `cyfr registry get-namespace <slug>` | Inspect a cyfr.run namespace |
| `cyfr registry tokens list <ns>` | List a namespace's push tokens; the **Registry** page issues and revokes them |
| `cyfr registry members list <ns>` | List a publisher namespace's members; the **Registry** page adds, changes and removes them |
| `cyfr registry discover <namespace>` | List a publisher's components on the registry |
| `cyfr webhook get/list/update/revoke/rotate` | Manage inbound HMAC-signed webhooks that trigger a component, which the **Webhooks** page makes `[i]` |
| `cyfr notify <event> <target>` | Send a webhook notification |
| `cyfr context list/set/add` | Manage server connections (local only) |
| `cyfr call <tool> [json-args]` | Invoke any MCP tool directly |

> Run `cyfr --help` or `cyfr <command> --help` for full usage details.

### Interactive Mode

Commands marked `[i]` support interactive selection — run them without arguments to get a picker. For example, `cyfr run` with no ref will prompt you to choose from installed components.

Use `--no-interactive` or set `CYFR_NO_INTERACTIVE=1` to disable interactive prompts (useful for scripts and CI).

### Non-interactive credentials (CI)

`cyfr` calls CYFR with an API key: the one `--token <cyfr_sk_…>` names on any command, else `CYFR_TOKEN`'s from the environment. Make one on CYFR's **API Keys** page, or with `cyfr key create` from a key that may manage keys; a command with neither says so and asks for one. A CI job or container passes it the same way. `~/.cyfr/config.json` keeps each context's address and never a credential.

CLI environment variables: `CYFR_TOKEN` (credential), `CYFR_NO_INTERACTIVE=1` (no prompts), `CYFR_NO_UPDATE_CHECK=1` (no release check — air-gapped installs; set in the CYFR's `.env`, the server makes none either).

## Glossary

Each part of CYFR has one name, and the name is its directory, its binary or image, its compose service, its environment variable prefix, its MAC domain, its provider's service label and its log label. Words for a role inside a part stay English. What each part is responsible for, how the parts talk to each other and what must always hold are in [ARCHITECTURE.md](ARCHITECTURE.md).

| Name | Is | Directory | Binary or image | Compose service | Environment prefix | MAC domain | Service label | Log label |
|------|----|-----------|-----------------|-----------------|--------------------|------------|---------------|-----------|
| Prima | pure contracts and the rostered runtime primitives | `apps/prima` | in every release | — | — | — | — | `[Prima…]` |
| Arca | persistence: rows, blobs, cache, leases, retention kinds, the records and file entry points | `apps/arca` | the `cyfr` release | — | — | — | `arca` | `[Arca…]` |
| Sanctum | decisions and the gate: identity, tenancy, authority, consent, vault, caps, the operation table, admission and dispatch, the request log and decision record | `apps/sanctum` | the `cyfr` release | — | — | — | `sanctum` | `[Sanctum…]` |
| Cyfr | the host: boot, ownership, bus, telemetry, configuration and settings, the endpoint and every other admission path, wiring | `apps/cyfr/lib/cyfr`, `apps/cyfr/lib/cyfr_web` | the `cyfr` release, image `cyfr` | `cyfr`, with `caddy` in front for public access and `tailscale` in front for tailnet access, with a loopback SOCKS5 proxy for this device's browser | `CYFR_` | — | — | `[Cyfr…]` |
| Compendium | components: kinds, manifests, registry, activation, provenance, builds over Locus, the tincture rules | `apps/cyfr/lib/compendium` | the `cyfr` release | — | — | — | `compendium` | `[Compendium…]` |
| Aqua | the assistant: a person's own threads, its crew and their child threads, turns, notes, attachments, memory, saying a line aloud into a shared thread, its providers | `apps/cyfr/lib/aqua` | the `cyfr` release | — | — | — | `aqua` | `[Aqua…]` |
| Opus | execution: admission, attempts, HostAPI, WorkerAPI, guest egress, schedules | `apps/cyfr/lib/opus` | the `cyfr` release | — | `CYFR_OPUS_`, `CYFR_HOST_API_` | — | `opus` | `[Opus…]` |
| Emissary | external application protocol adapters: MCP in both directions (external MCP servers over HTTP or through Locus), the HTTP API and its event streams, health, webhooks, the vault's OAuth callback, tinctures' files and data routes | `apps/cyfr/lib/emissary`, `apps/cyfr/lib/emissary/web` | the `cyfr` release | — | — | — | `emissary` | `[Emissary…]` |
| Prism | the screen: the console | `apps/cyfr/lib/prism`, `apps/cyfr/lib/prism_web` | the `cyfr` release | — | — | — | — | `[Prism…]` |
| Codex | the CLI | `apps/codex` | the `cyfr` binary | — | — | — | — | — |
| Locus | where untrusted things run: the roles runtime (WASM), builds and programs, under the keeper `cyfr-locus` | `apps/locus` | the `locus` release and the keeper binary `cyfr-locus`, image `cyfr-locus` | `locus`, `locus-guard` | `LOCUS_RUNTIME_`, `LOCUS_BUILDS_`, `LOCUS_BACKENDS_`, `LOCUS_LOG_`, `KEEPER_`, `RUNTIME_`, `CYFR_LOCUS_RUNTIME_`, `CYFR_LOCUS_BUILDS_`, `CYFR_LOCUS_BACKENDS_` | `cyfr-locus/v1`, with its `runtime`, `builds` and `backends` services, each under a key of its own | — | `[Locus…]`, `[cyfr-locus]` |
| provider | the implementation of a tool's operations, `<Name>.Provider` or `<Name>.Providers.<Tool>`; its service label is its part's name | — | — | — | — | — | — | — |
| facade | a part's own module, the one entry the parts above it call | — | — | — | — | — | — | — |
| port | one of four behaviours a lower part declares and a higher one implements, installed at boot | — | — | — | — | — | — | — |
| plane | the kind of caller an operation is admitted for: an external caller, or a call inside a running chain | — | — | — | — | — | — | — |
| actor | the tenant and identity carrier | — | — | — | — | — | — | — |
| athanor | the tenancy unit, one person's own place, with no organization or project above it; the one CYFR that holds it decides everything about it | — | — | — | — | — | — | — |
| shared thread | a place people talk, which no athanor holds: a title, its people, each equal, and their messages and attachments, with nothing running in it; a pair is a shared thread of two, fixed at its birth | — | — | — | — | — | — | — |
| lease | a control-plane server's database-held claim to its slot | — | — | — | — | — | — | — |
| fence | the lease row's renewal token, which each renewal and takeover of the row names and raises; never a publication's identity ([`ARCHITECTURE.md` §6.3](ARCHITECTURE.md#63-publication)) | — | — | — | — | — | — | — |
| attempt | one try at running an execution on a worker service | — | — | — | — | — | — | — |
| program | a command an athanor's admin defines, run by the Locus backends service as a process whose lines go to and from CYFR, marked `mcp` (CYFR speaks MCP to it) or `driven` (a person or a brain runs it); what Prism's **Programs** page lists beside the tool servers elsewhere | — | — | — | — | — | — | — |
| cluster | several control-plane servers sharing one database | — | — | — | — | — | — | — |
| account | a person: their name, their identifier and the log of their keys at one account service; every CYFR admits accounts by name and holds none of their keys | — | — | — | — | — | — | — |
| person identifier | `per_…`, the hash of the first entry of an account's log: it names the account at every CYFR, its name at the registry names it, and it admits it nowhere by itself | — | — | — | — | — | — | — |
| account service | the service that keeps each account's log in one order and serves the account pages its passkeys live on, cyfr.run unless `CYFR_DIRECTORY_URL` names another; it holds no private key and no address of any CYFR | — | — | — | — | — | — | — |
| account pages | `/account/new`, `/account/sign`, `/account/add`, `/account/devices` and `/account/recover` at the account service: an account is made there, signs a CYFR's request, adds a device, lists and removes its keys, and is recovered with its recovery code | — | — | — | — | — | — | — |
| recovery code | one line starting `CYFR-` that spells an account's identifier and a recovery secret, whose key adds or removes any key of the account or replaces every one; only a code adds another | — | — | — | — | — | — | — |
| passkey | a key of an account that the person's phone or computer keeps for the account service's address, which signs them in and confirms their changes at every CYFR that uses that service | — | — | — | — | — | — | — |
| device key | the key a device makes and never exports, under its chip's PIN or a passphrase, one per machine for every CYFR, listed in its account's log | — | — | — | — | — | — | — |
| device certificate | a CYFR's own short-lived statement, signed with its installation key and read by no other CYFR, that a device key of an account is admitted there, naming the key, its client, the account, the head it was issued under and the athanor | — | — | — | — | — | — | — |
| paired client | a device or a passkey of an account as one CYFR knows it, by its key, from its first sign-in there; revoked there on its own, and ended at every CYFR by removing its key from the account | — | — | — | — | — | — | — |
| sign-in method | a company's sign-in, which a CYFR may require of every person there (`CYFR_COMPANY_LOGIN`) as a condition of being there; it never signs anyone in, since a person signs in with their account | — | — | — | — | — | — | — |
| fresh confirmation | a key of the person's account signing one pending confirmation, a passkey at the account pages or a device after its unlock; each sensitive change needs one | — | — | — | — | — | — | — |
| pending confirmation | one sensitive change waiting for its fresh confirmation, with the preview CYFR stores and shows on every device of the person's | — | — | — | — | — | — | — |
| origin | how a run started, `interactive`, `programmatic`, `schedule` or `webhook`, set by the path that admitted it, for the record; a run stands on its person's grant whatever started it | — | — | — | — | — | — | — |

Every setting of the control plane is a `CYFR_` variable; a part named with a prefix of its own beneath it owns those settings. A setting an island's release reads carries the island's own prefix, and the control plane's copy of an island's key carries `CYFR_` before it: `CYFR_LOCUS_BACKENDS_KEY` in `.env` is `LOCUS_BACKENDS_KEY` in the `locus` service. `HostAPI` and `WorkerAPI` are protocol names, and `CYFR_HOST_API_` serves the first.

## Documentation

| Document | Description |
|----------|-------------|
| [Configuration Guide](configuration-guide.md) | Every deployment variable and platform setting, with its default |
| [Integration Guide](integration-guide.md) | How to use CYFR as your application backend |
| [Component Guide](component-guide.md) | Practical guide to building catalysts, reagents, and formulas |
| [Tincture Guide](tincture-guide.md) | Practical guide to building tinctures |
| [Identity Guide](identity-guide.md) | Your account at every CYFR: its name, identifier, keys and recovery code, the account pages, signing in and invitations, and what each loss costs |
| [Devices Guide](devices-guide.md) | Adding a device to your account by approval, how it stays connected at each CYFR, and confirming a sensitive change with a key of yours |
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

A release signs and attests its `checksums.txt`, which holds the SHA-256 of
each download, the CYFR app's five installers among them. To verify manually,
verify `checksums.txt`, by its attestation or its signature, and then the
download against it (on a Mac `shasum -a 256 --check --strict` in place of
`sha256sum --check --strict`; on Windows compare `Get-FileHash <file>` with
the file's line):

```bash
# GitHub Attestation of the checksums (just needs gh CLI)
gh attestation verify checksums.txt --owner cyfrworks

# The file you install, beside checksums.txt, against its own line there:
# this fails unless checksums.txt lists exactly that file and it matches
FILE=cyfr-desktop_0.9.0_linux_amd64.deb
awk -v f="$FILE" '$2 == f' checksums.txt | sha256sum --check --strict

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
