# CYFR architecture

This document outlines CYFR's architecture in the present tense of its end state: the services, what each owns, how they talk, the invariants every change keeps, and why. A **Not built yet** line names each part or behaviour the code lacks, so a sentence without one describes the code as built, and a built part that falls short of it is a defect in the code. A contract's detail, such as a rule's edge cases, a limit's value, a wire's fields or an order of checks, lives once, in the owning module's documentation or comments. Names, directories, binaries and prefixes are in the [glossary in `README.md`](README.md#glossary).

## 1. Purpose and principles

### 1.1 What CYFR is for

CYFR is a home for a person's work with AI, and a place to talk with other people: components an assistant can build and run, the assistant itself, files, schedules and credentials, on infrastructure the person controls. It rests on one idea: **a model proposes, and CYFR decides.** A model may suggest any action; only a declared operation, admitted by one gate under a consent the person gave for exactly that action and those resources, carries it out, and credentials live in a vault no model sees. Three consequences follow: the person, not a provider, device or sign-in, is the lasting thing; authority is decided at the one home of what it concerns; and untrusted code runs outside the control plane, isolated from it.

### 1.2 Principles

- **Prompts are not permissions.** What a model proposes runs only as a declared operation admitted by one gate under a consent bound to what was shown.
- **Layers, one direction.** A module depends on its own layer or below, and the compiler or a seam test refuses any other edge.
- **One owner per fact.** Each schema, policy, operation, topic, protocol shape and setting has one authoritative module, and everything else is derived from it and checked against it.
- **Downward calls are direct; upward needs are ports; reactions are events.** There are exactly four ports that boot installs, beside the one a caller hands a single run (§4.2).
- **Three guards, each with one owner.** Sanctum's gate admits operations, Arca scopes rows by the actor, and only Sanctum reads security rows.
- **The trust island speaks protocols.** Locus shares only pure contracts and signed, versioned wires with the control plane.
- **Fail closed.** Identity, standing, consent, ownership and catalog completeness are settled before work is admitted, and a control that cannot answer refuses; only the decision audit (§6.4) records without deciding.
- **Admission, not sampling.** The gate admits discrete intents; continuous data, audio and frames included, flows only under a grant already admitted. *Not built yet:* a stream that carries audio.
- **One product, one code path.** Exposure follows from whether authentication is configured, never from an edition.
- **Few names.** A namespace exists only for state or a trust boundary nothing else owns; there are eleven (§3).
- **The person outlasts hardware and homes.** A lost device is removed from the account, a lost home restored from its backup and an account from a recovery code, and a person stays one identifier at every home (§9.1).
- **Data goes down, words come up.** Decision modules answer typed facts and reasons, and surfaces own the words.

### 1.3 What CYFR trusts

- **Trusted:** the home's own code, the system layer and the command line that runs the home's machine among it (§7); the platform administrator; the home's store; a person's passkey or a protected device's local unlock, for sign-in and fresh confirmation (§9.3); the directory, for consistently ordered logs alone: its server receives no sign-in destination and no private key of a person (§9.1); and its static account pages, trusted browser code like any site a passkey lives on, to run the ceremony a home asks of them: they see the destination they return to, and hold recovery material in page memory while an account is made or recovered.
- **Not trusted:** models and their output, components and tinctures, untrusted processes, another person's session, another home's word, and anything a guest hands back.
- **Stated limits.** Fresh confirmation protects against a stolen session, not a compromised administrator; no digest proves what a client displayed; a recovery code, a backup or a session is authority to whoever holds it. A protected device's PIN or passphrase never leaves it, but its key is unsealed into memory while it is unlocked: malware on an unlocked device can copy it and sign until the key is removed from the account, which is the remedy. A local or tailnet home that cannot reach the directory keeps admitting the people it holds on the keys it last read, so a removed key keeps working there until it reconnects, and a browser signs in there only if it visited the account pages before (§9.1).
- **The trusted computing base** is the control plane, which holds the decrypted credentials; Locus is the process boundary for untrusted code.
- **Clock trust.** Expiry, leases and freshness are read on the deciding home's clock, and a cell's leases on its database's.

## 2. Layers

```
L4  Trust island    Locus (untrusted things: the WASM runtime, builds, programs, perception bodies), under its keeper cyfr-locus
                    depends on Prima only; reaches L1/L2 over signed, versioned protocols
                    runners and bodies have no network of their own; builds and programs have their service's

L3  Surfaces        Emissary (external protocols)   Prism (the screen)   Codex (CLI)
                    adapters over Sanctum's gate and Sanctum.Caller; a surface never names another surface

L2  Domains         Compendium   Aqua   Opus
                    an acyclic graph (Aqua→Opus, Aqua→Compendium, Opus→Compendium), facade-only

L1  Foundations     Cyfr (Host)  >  Sanctum  >  Arca
                    strict order; a lower foundation never names a higher one

L0  Prima           types, wire shapes, behaviours, pure primitives, the actor
```

The order describes dependencies, not a request's path. Only Host's composition modules (`Cyfr.Application`, `CyfrWeb.Endpoint`, `CyfrWeb.Router`) name the layers above them, to wire them, beside the boundary catalog (`Cyfr.Boundaries`), which names every module it judges; Emissary is the one surface that also implements a port (§4.2). A new concern goes in the lowest layer whose neighbours do not need it. *Not built yet:* perception bodies (§3, Locus).

**Why.** Each layer can be understood knowing only what is below it, and the compiler and the seam tests, not review, keep it so.

## 3. Modules

### Prima: shared contracts

- The actor, authority data, operation declarations, refusals and the provider, host and worker behaviours.
- Every wire shape and every signing domain two sides share; each protocol is versioned, with one vector file tested on every side.
- The pure network policy and the Locus role table (`Prima.LocusRoles`); no process, persistence or product policy.

### Arca: persistence

- The repo and every schema, query and transaction, on SQLite and PostgreSQL alike; nothing above Arca names the adapter.
- Blobs behind one storage abstraction (`Arca.Storage`), and storage revisions.
- Leases, the cell lease row, job claims, the cache, retention and the durable outbox (§4.3).
- The records and files providers. *Not built yet:* the `memory/` root (§11).

### Sanctum: decisions and the gate

- Accounts as a home relies on them, sign-in, sessions, admission, devices and fresh confirmation, and the directory and name registry a home may serve.
- Tenancy (a person's own athanor, `Sanctum.Tenancy`), shared threads and their people (`Sanctum.SharedThreads`), caps and the caller context (`Sanctum.Caller`).
- Consent, the vault and its shares, credential attachment and the credentials tinctures are served under.
- The gate: the operation table (`Sanctum.Catalog`), its entries (`Sanctum.Gate`, `Sanctum.Streams`), discovery, the request log and the decision record (`Sanctum.Decisions`).
- No Ecto and no broadcast; it alone reads security rows, and its internal strategies are behaviours selected by configuration.

### Cyfr (Host): the machine

- Supervision, boot, the cell claim and the composition root that installs the four ports.
- The bus (`Cyfr.Bus`), telemetry, configuration, the access mode and platform settings (§6.8).
- The endpoint, on a loopback listener and, in a tailnet or public home, a proxy listener its proxy forwards to; the listener that accepted a request is its ingress, never a header, and a loopback listener's non-loopback address stands only on the compose file's assertion (`CyfrWeb.Ingress`).
- The admission roster of every path an intent enters by, each listener and the entries that admit for themselves among them, such as a webhook's delivery and browser sign-in (`Cyfr.Admission`), and the boundary catalog (`Cyfr.Boundaries`). *Not built yet:* the local socket and the compositor, which the roster declares and defers.

### Compendium: components

- Component kinds, manifests, the registry, activation, provenance and builds over Locus.
- The tincture rules (`Compendium.Tincture.Rules`): what a tincture may serve and declare, and the frame policy derived from it.
- The component, registry, source, build, Aqua-file, canvas and layout providers.

### Aqua: the assistant

- A person's daily threads, one per date of their own time zone, where they talk to Aqua: opening Aqua shows today's, a message joins the one current when it is accepted, and a read mark per thread, moved forward only, counts what arrived since it was last open. The crew's child threads, turns and their loop, approvals (§10), notes and memory (§11), and saying a line aloud into a shared thread (`Aqua.Aloud`), the one deliberate copy out of an athanor.
- Workspace threads, the second tier: Aqua opens one from a turn of the daily thread for a piece of real work, or the person does from the daily thread's posts, with its opening (the ask, who asked, the posts it refers to, read as they stand when the work starts, and the files it carries, copied into it) and a pointer on the daily thread, in one transaction that records its delivery. The soul works it there, in turns of that thread, asks the crew from there and posts files, pictures and links into it; it reports the work done, saying what worked and what did not, or that it needs the person, and the host reports when a card opens there and when Aqua could not run there (a turn that ended failed or uncertain, one it could neither resume nor start, an opening that could not start). Each report lands on the daily thread current when it is delivered, once, and starts the soul's next turn there. One rule in Arca says what a workspace thread is from its records: working while anything of it runs, its crew members' work included; needs you while a card waits or Aqua reported so; finished, stopped or error by how its work last ended. No agent has a status of its own: the thread shows each one at work there with its last step and when. The person's stop ends all of its work, its crew members' included, in one transaction, and posts no report; a person writing in one whose work ended opens it again. One that reads working and in which nothing has happened for fifteen minutes, in it or in a crew member's thread under it (a page's calls and reads are no activity), gets one line of the server's for its own Aqua asking where its work stands (`Aqua.Nudge`): it joins the turn that holds the thread when that turn is Aqua's and asks a model, whatever waits behind it, read at that turn's next model round on whichever member runs it, or with nothing open or waiting there opens a turn bound to the thread's current work as the thread's lock finds it, and no second comes while one is unanswered; it reopens nothing and counts as nothing unread. One that reads needs you or error gets a post of the server's on its person's daily thread saying it needs their attention, once fifteen minutes after its wait began and once on each new day while it still waits, one post per wait, which Aqua answers as it answers any post. Each is decided afresh under the thread's lock from its rows, by the database's clock, so a restart or a second member finds what is due and never doubles it. A workspace thread keeps notes of its own, which its turns write whole with no card and its every turn reads. Deleting one removes its notes, its pointers and reports and, in each thread whose turns read it (a `thread` source on the turn), the results of the reads that carried its posts, the compactions since and the brain's session, and stops a turn still open there that read it.
- Archive: the person archives a daily or a workspace thread, or the athanor's one setting does after days with no activity in it or in its crew threads (`archive_days`, three by default, zero for never), never while work remains there; an archived thread is an ordinary thread behind the list's Archived filter, readable, searchable and admitting everything, with its files and notes, and new work there takes it out by itself, the write that starts it clearing it in its own transaction. Its browser window is closed by the browser that holds it, on whichever member it runs, which hears the archive and a deletion on the person's list. No thread is deleted by age: only the person deletes one. A crew member's thread is retired instead, which stops its work there.
- Recall: a turn finds past posts of the person's daily and workspace threads by a plain substring of their text, case folded, the same on both adapters, and reads a thread's posts by cursor (`thread.search`, `thread.events`); a crew member's thread is neither. What a read answers joins the turn's sources before it answers, each thread it carries posts of as a `thread` source and the material of the turns that wrote them, so forgetting a thread finds every turn that read it.
- Reading a person's shared threads for them, under their own seat and only when a question needs it: a turn lists the threads they sit in with what is unread and reads one (`threads`), or a send carries the thread open beside it when the person ticks it (`Aqua.RoomExcerpt`). What it reads, other people's words included, goes to the person's model provider, which the panel says once; what a turn read stays, as every tool's result does, in that thread of the person's own; reading moves no read mark and writes nothing into the shared thread.
- A schedule's line for Aqua: only the person, signed in, makes or changes one. Each fire's claimed occurrence is its record; Aqua starts a turn as the person in their daily thread current when it fires, or the one that already accepted that claim's line, and makes no thread for a schedule (Opus never calls Aqua), the turn's root admission starts the occurrence, and the turn's end ends it through the scheduler's one public end, from what the root's row says. With nobody present a turn does only what needs no asking or what a standing allow covers, opens no card, and at the first call that would ask ends failed saying what it needed and how to allow it next time: an answer "for a schedule", given on a card that names the schedule, which holds for that schedule's turns on any day's thread and ends with the schedule.
- Aqua's browser tool and the person's browser setting (`Aqua.BrowserSetting`), one value of their preferences: while it is on, Aqua opens, reads and acts on sites in its browser without a card; while it is off, every action of the tool is refused. Turning it on asks the person with a card each time; turning it off holds at once: from then on CYFR starts no browser and sends it nothing, no action and no page, and a browser that a start already under way brings up is sent nothing and closed as soon as that start answers; the browser is started so that it reaches nothing by itself, its own background traffic turned off. A page Aqua puts into its browser calls CYFR as Aqua in that window's thread (`Aqua.PageCalls`): each `invoke` or `action` it makes, a tincture's first held to its declaration, is a step the host proposes in the thread's running turn, decided and dispatched by the code that decides a model's call; when no turn runs, it is the first step of a turn that asks no model, run as the person whose turn put the page, which is queued and holds the thread's claim as any turn does and ends when its last step closes.
- Agent configuration and model orchestration: one turn under one grant, whatever the model. *Not built yet:* Aqua's model policy, which chooses a model per step.
- The crew, agents whose turns run on a brain, hand-offs that run as turns of their own and reply on every exit. A brain is a catalyst that speaks the model contract, an API's or a harness's adapter alike; a crew member is who does a job and a scroll is how, so every member runs under the soul's tools, which a hand-off may narrow for its one job. A program a harness runs keeps its own tools inside its box under its own permission mode. *Not built yet:* cards for a program's own tools.

### Opus: execution

- Admission of executions, attempts and accounting, schedules and feeds.
- The HostAPI server and listener and the WorkerAPI client.
- A running invocation's further input (§4.2): a model call's runner asks between its reads for the input its caller supplies, writes it to its harness and reports it sent, and only the run's own live attempt reaches it.
- Guest storage, guest egress (§5.6), the attached request (§5.5) and output masking.
- Programs and their holders, by one rule: a program runs in its box; a driver sits beside it only when CYFR itself must act on what the program says; CYFR's side is always a holder; a terminal program and an MCP server have no driver. A program used as a brain is a session `Opus.Brain` holds for one thread and agent, as long as the work needs it: it speaks the brain wire (`tests/fixtures/brain_wire.json`) to the brain's driver over a run session, writes one command at a time once the driver has said hello, hands each batch of what the driver says to its one attendant and reads on only when told, and treats every line as the program's word, so a line that does not read, one past the bound or one lost unread ends the session. Each write is bound to admitted work: as it is about to be written, the turn, its person and origin, its fence, the step that admitted the program's start and the row and epoch its own call named, the row, the thread's session generation and the decision that admitted the start, the step's card or a standing answer read through `Sanctum.ToolGrants`, are read again, and a paused turn may be written only a post or an answer of its own work. A take-over ends the session only once its holder has read the new work's binding and found it proves, so a stale open never ends its successor. A write the service did not answer is never written again: the session ends, and the next start resumes the native session from its transcript. *Not built yet:* Aqua's attendant of a held session, discovery and cleanup through the holder.
- The programs controller: what the backends service runs, its sessions and kept homes, one owner table and lease per box. The box owns every session it opens and owes each close until the service confirms it. A program a person opens on a terminal is a session the server owns for that athanor and person, never for a page or a browser credential: the person at any of their screens attaches to it, a key or any other caller finds nothing, and detaching ends nothing; what the program prints crosses into the server only as fast as it is taken, one read at a time and one output per screen until that screen has drawn it, the rest waiting in the backends service's bounded buffer or kept as the last 256 KiB; it ends when its program exits, when it is closed, after a day with nothing attached and nothing printed unless kept, with its row's change or removal, or with its person's standing. Aqua runs a program of its own, through the in-chain `program` tool, as a session its turn owns: the turn is proved from the store from the lineage the gate stamps, never from an argument; each start shows the pinned command and every word on a card and asks, unless a standing answer covers every start of that one row; the turn reads what it printed by offset as outside material named by the program, holds a few at once and uses them only while it is running, and every one ends with the turn; a standing answer is one program's, named by its row, written only while that row stands as the card showed it and ended by the row's change or removal. The person lists and closes those sessions, and nothing else of them is theirs; a turn never reaches a session a person started. The person's browser is a session of the person's that `Opus.Browser` holds for them, which their turns use through it and no turn owns: a program row of Aqua's browser's own definition, whose kept folder holds the browser's profile and the Chrome its driver fetches, which starts for no other caller; two such rows are the only ones that start for it, one session each, the person's Chrome and a second, which a workspace thread opened apart and the crew members working under it have their windows in and never in the person's, so the two share no cookie and no storage, and a window goes in the person's only for a thread shown to be theirs, any other, one gone among them, refused with nothing started; each starts when a turn of the person first needs it, acts only for a running turn of theirs proved from the store and only in the window of that turn's thread, four windows at most, shows a window only on a page of the person's that watches it (§7), and ends at its idle stop, with no window in use and no watch open, when the person's browser setting goes off, or as any session ends. A page Aqua shows in a window, one file, several or a `local` tincture's built files as the endpoint reads them, is handed to the driver once at its put, bounded in files and bytes, and the driver answers the window's requests for it from those files at a reserved origin that resolves nowhere (`https://cyfr.invalid`), with no server and no network; a call to CYFR the page makes from that origin is passed up to `Opus.Browser`, and a worker's, another origin's or another window's is not. `Opus.Browser` decides and runs nothing of it: it announces the call on the bus (`Cyfr.Bus.PageCall`) for Aqua to answer as its own call in the window's thread, holds the paused request until that answer, answers it `unavailable` when the process holding it dies, and announces a call that ends unanswered as ended; its own end, however it comes, ends every call it holds, which the process holding each hears by monitoring it. *Not built yet:* boxes beyond the local one.

### Emissary: external application protocols

- MCP in both directions, the HTTP API, webhooks and the OAuth callback, carrying declared operations through the gate but at the entries that admit for themselves. A row of the Programs page is a tool server elsewhere, reached over HTTP, or a program CYFR runs, marked by how it is spoken to: `mcp`, Emissary speaking MCP over its sessions, or `driven`, run by a person or a brain.
- Tinctures' files and data routes (§7), the device channel (§9.3), and the directory's endpoints and account pages a home that serves a directory serves (§9.1).

### Prism: the screen

- The system layer, the frame manager, the shell and the console (§7), and browser sign-in.
- It dispatches through the gate and reads domain facades for its trusted reads. Beside the gate, the console writes only a person's own presentation preferences, which carry no authority, and the sign-in pages are entries that admit for themselves.

### Codex: the command line

- The `cyfr` binary, speaking MCP to Emissary with an API key alone; its operation catalog is generated from the gate's table. The command line is no device and signs no one in; people act on the screen. It runs the machine, and with a key runs tools and reads their runs, the acts a key may do; a key's change that needs a fresh confirmation waits for its person to confirm it in Prism or on the box.
- The access engine (`apps/codex/internal/access`), which `cyfr init`, `setup`, `access`, `up`, `update`, `backup` and `restore` run on the machine: the one owner of the deployment file's access settings and the stack's access services, which it changes under the stack's lock and journals, so the next command to take the lock recovers a change an interruption left. A command that stops the running stack itself (`update` before its switch, `backup`) journals that stop first as a hold naming the command, which the command's own start closes; the next command to take the lock after one that died holding it starts the stack and says which command stopped it.
- Two faces of the one program on the machine: the terminal, and the setup pages `cyfr setup` serves on the machine's loopback before the stack runs, for a device's own screen. The pages drive `cyfr init`'s sequence and `cyfr up`'s start, no second setup, and only the machine reaches them; Prism is never a setup surface.
- The machine's own requirements: on Ubuntu 26.04, at a terminal, `cyfr init` installs Docker when this account cannot reach it, through one `sudo` of the commands it shows; `cyfr` itself never runs as root. `init` prepares and `up` starts, on every system.
- The machine's own screen: `cyfr screen on` installs a service that runs a browser on tty1 at the access engine's address, through one `sudo` of the commands it shows. The launcher is embedded in `cyfr`, the system's package manager supplies the browser, compositor and keyboard, and it never starts or stops the stack.
- The screen's shell holds the box's protected device key, sealed under a six-digit PIN in its TPM or wrapped under a passphrase, and is the one place it is unlocked: at setup it makes the account with the box as its first device, otherwise it is added to an account like any device; it says hello at its home, again after a restore, unlocks into a browser session through a one-time ticket, locks, and confirms a change after drawing the home's preview itself and asking for the PIN again (`Sanctum.DeviceUnlock`). It reports whether the system and data disks are encrypted, which setup and the devices list show and nothing decides; it changes no disk or boot setting.

### Locus: where untrusted things run

- The runtime's OS runners, with no network of their own, and the build and backend services, each signed with its own key.
- The backends service runs programs, each a process of one owner: in lines over pipes, which the owner speaks its protocol over, each line masked of the owner's credentials, or in bytes on a pseudo-terminal whose size the owner sets, for a person at a terminal, masked as a stream so that no credential split between two writes leaves whole or in part; a program's home is scratch, scrubbed at retirement, or kept, the program row's own folder, made and retired with the row, under a uid of its own that no other owner is ever given and no backup carries. *Not built yet:* the VM level and the computer per athanor.
- Aqua's browser: a program like any other, a driven row whose driver fetches Chrome for Testing's current stable into the row's kept folder, as a program fetches itself, and runs it there: the list on `googlechromelabs.github.io` decides only the version number, and the driver builds that version's archive address itself on `storage.googleapis.com`, never replacing a Chrome with a lower version, and a download a start cuts off is taken up at the next start; the backends image holds only the shared libraries Chrome links and a font. The driver starts Chrome over its debugging pipe inside the box, so no debugging port opens, with no window of its own and its background traffic turned off, so that it reaches nothing until a request asks, and speaks framed messages on its terminal. Chrome's own sandbox cannot start under the service's options, so Chrome runs without it, held by its uid, the guard, the read-only root and its memory bound: a page that breaks Chrome's renderer gets that browser's process: its profile and the person's sign-ins kept there, the egress that uid is allowed, and the driver's protocol towards the host, which takes no response past the bound its vector file states.
- A brain's driver: the start of a driven row's command, before the harness's own, in the row's kept folder (`cyfr-claude-code` for Claude Code, `cyfr-codex` for OpenAI Codex), each speaking the brain wire through the one package they share (`internal/brainwire`). It speaks the harness's own protocol to the harness it starts and the brain wire to its holder, keeps no account of the calls it carries, says the harness's errors in its own words, and passes on nothing of the harness's standard error, its folder, its sign-in or its account; the harness's own tools run in the box, shown by name only, and CYFR's reach the harness only once CYFR answers them (through `cyfr-stub` for Claude Code, as the answer to the call Codex holds). Forgetting a session removes that session's transcript from the folder, the harness's own records of it included, and nothing else. On a terminal the driver runs the harness unchanged, so the person signs in on the same row.
- The keeper, `cyfr-locus`, which runs every child under a uid and bounds of its own and scrubs it on release.
- Perception bodies on a device. *Not built yet:* perception bodies.
- Opus, Compendium and Emissary decide what runs; Locus only runs it.

### Apps and releases

`prima`, `arca` and `sanctum` are Mix apps of their own because Sanctum's licence boundary is an application directory and Sanctum needs Arca beneath it; `cyfr` hosts Host, the domains and the surfaces under Boundary declarations; `locus` depends on `prima` alone; the keeper and `codex` are Go.

## 4. How modules talk

### 4.1 Channels

| Between | Channel |
|---|---|
| A module and one below it | A direct facade call, context or actor first |
| A lower module needing something above it | One of the four ports (§4.2) |
| A running invocation needing further input from whoever started it | The invocation-scoped port its caller handed that run (§4.2) |
| Two domains | Facade calls, in one direction only |
| Two owners, one commit | One Arca transaction with the higher owner's closure (§4.4) |
| After a commit | An event on the bus, which never grants authority |
| A surface acting | A declared operation through the gate, or an entry the admission roster names as admitting for itself |
| A surface reading | Domain facades under the caller's context, never a security row |
| A trust island and the control plane | A signed, versioned protocol whose shapes live in Prima |

Telemetry becomes a bus message only through Host's bridge.

### 4.2 The four ports

| Upward need | Declared by | Implemented by |
|---|---|---|
| The storage and counted cap decision (`Prima.Caps`) | Prima | Sanctum |
| Component facts for consent and the gate's stream admission, and filling an athanor with its components (`Sanctum.Consent.Components`) | Sanctum | Compendium |
| Proxied tool resolution (`Sanctum.Proxy`) | Sanctum | Emissary's external half |
| Where a storage unit's bytes live (`Arca.Storage.UnitLocator`) | Arca | Compendium's component and Aqua path grammars |

Host installs each implementation at boot, and the declaring module fails closed when none is installed; a fifth port is an architecture change. **Why:** each port is a need a lower layer cannot meet without naming a higher one.

Beside the four stands one invocation-scoped port, which boot does not install: the further input of a running invocation (`Opus.Inputs`), such as the messages that reach a person's thread while Aqua's model call runs there. The caller that starts the run hands Opus a process for that run alone, and Opus, naming nothing above it, asks that process only for the run's own runner, under its signed header and its live attempt, and tells it the run's trusted identity; the supplier checks that identity in the transaction that records a delivery (`Opus.Inputs.held!/1`), so a stopped, replaced or cancelled run reads no input and marks none. With none handed, a run reads none. Input handed over cannot be recalled, and the catalyst writes it to its harness itself (`cyfr:model/inputs`). **Why:** asking the caller for content is a contract upward, unlike telling a waiter of an end, so it is named as a port; held by one run and gone with it, it widens no boot-time seam.

### 4.3 Events

Topics are declared once in `Cyfr.Bus`, a grantable topic carries discrete facts, a broadcast of a write follows its commit, and a subscriber that reconnects is admitted afresh. A reaction that must survive a crash starts from an Arca outbox record committed with its source, and the bus only wakes its consumer: today a schedule's outcome kept as a note, a crew member's request and reply, and a workspace thread's opening and report, each receipted once in the transaction that acts on it. *Not built yet:* a stream's declared replay, a declared refresh beyond the canvas-readable streams, and Memory's consumer of the outbox (§11).

### 4.4 Transactions across owners

A write two owners must commit together is one Arca transaction. The higher owner's part enters it as a named closure (`verify:`, `also:` or `reserve:`), declared by the Arca function that takes it, which touches only its owner's rows, calls no network and publishes nothing. Arca owns the transaction and never names the owner. Broadcast follows the commit, by the caller, and a fenced write keeps its fence inside the same transaction.

### 4.5 Errors and words

Classified conditions are typed tuples and programmer errors raise. A refusal is a `%Prima.Refusal{}` each surface renders in its own words, and a guest sees only its `Prima.GuestError` projection.

### 4.6 Adding a capability

A new effect is a declared operation in its owner's provider; a new limit, a cap of its own meaning (§5.8); a new credential kind, a vault entry bound to its destination (§5.5); a new record, an actor-scoped Arca row. Only a fifth port, a new layer edge or a new namespace is an architecture change.

## 5. Tenancy, authority and isolation

The person decides; Sanctum validates, records and checks; and the place that releases the data or performs the effect enforces what was admitted.

### 5.1 Tenancy

- The athanor is the one tenancy unit, one person's own: their assistant, vault, components, files, schedules, keys, webhooks, devices and storage. Nobody else sits in it, and every person admitted to a CYFR has one there, minted in their admission.
- Tenant identity comes from the authenticated actor, never from a guest's argument, and ownership travels with rows, blobs, events and cache keys.
- A thread of an athanor holds what its kind names and no more: a daily thread its date, one per date of the athanor; a workspace thread its state, the daily thread's post it was opened from and its notes; a crew member's thread its room, a thread of the same athanor.
- An athanor's rows stay its own. The one widening across athanors is a share, an entry its owner offers to everyone or to one shared thread: a person in its audience sees the entry only through the share, never its material, and a recipient uses it only through the share their own consent names, read under the owner's athanor (`Sanctum.Shares`).
- A platform administrator holds a capability over the instance, a mark on their person row (`users.platform_admin_at`), and works in their own athanor alone: what the instance holds for them is its own, such as the host's decisions, never another athanor's. The installation's first person, made by its setup, carries the mark; an administrator who can still act, read again under the change's own lock, writes it on another person of the instance and clears it, each under a fresh confirmation; no deny, allow removal or denial reaches an administrator, so a denial never takes a mark away. The last administrator who can still act (active, marked, and holding an account this CYFR's directory has not closed) keeps both the mark and the account. Every act that reads the administrators to change them or to decide by them (a marking, a clearing, a deny, a removal of an entry, a denial, an account's closure) takes one administrators' lock first and decides on what it reads under it, its door entry included: an advisory lock on PostgreSQL, the one write lock on SQLite. A closure takes it after the directory's lock, and no holder of it takes the directory's lock after it.
- A shared thread belongs to no athanor: a title, its people, each equal, and their messages and attachments, with no assistant, approval or execution in it. Every read and write of one checks the caller's seat (`Sanctum.SharedThreads`); a pair is a shared thread of two fixed at its birth, and the platform administrator reads a thread only where they sit.
- Outsiders learn nothing of an athanor: anyone but its person gets the answer a missing athanor gets.
- Nothing lands in an athanor its person did not accept.

### 5.2 Identity and standing

Identity and standing are established at the authentication boundary, and a long-lived context revalidates them before protected work within a bounded cache lifetime. A session a protected device's unlock created stands on that device too: it is the person's session, never the device's context, it expires within a minute unless the device's own channel slides it, never past the device's certificate, and the device's lock, the channel's end and the device's revocation, suspension or certificate retirement end it. A session's or a device's holder is a person with an identity row, minted together; a holder without one stands for nothing, whatever its id, and its session or device is refused. A session, a device certificate and a pending confirmation are bound to the key that signed for them and the account head it was verified under: a passkey sign-in's session keeps the ordinary idle expiry, since no device of the home observes the passkey's lock, and removing the key from the account ends every such binding at each home once that home reads the removal (§9.1). Whether a session slides with use follows its client's verified source, never what a client reports of its holder, and a session's traffic never stands for a fresh confirmation. A standing channel, an API key, a webhook, a schedule or a grant, acts under its creator's standing: a person with a row, or one of the server's own principals, which are never denied (`Sanctum.Tenancy.channel_active?/2`). A denied creator's channels stop, and a creator that names nobody stands for nothing.

### 5.3 One gate

The screen, the command line, the wire and the assistant share one operation declaration and one gate, on two planes: external callers and calls inside a running chain. Entry paths that no person's session admits decide for themselves and record their own refusals: sign-in, the answer to a request this home minted, signed by a passkey at the account pages or by a device over its channel; the directory and its account pages, where a home serves one; a device's first hello under the setup token or the open admission; and the spending of a protected device's unlock ticket for its session.

### 5.4 Consent

A consent binds to the exact action and resources its preview showed, and a version that asks for more asks again. Who may consent follows how the caller authenticated, never what it holds; the one consent no person gives is provisioning's, which grants the shipped seed components their declared shape so the assistant works on a new athanor, and which the person revokes like any other (`Sanctum.Consent.Bootstrap`). Human approval unblocks an action already authorized and grants nothing more. A fresh confirmation is a held key's: the person's passkey at the account pages or a protected device of theirs after its unlock, signing the home's request that names the stored record; nothing else confirms, no sign-in method, emailed code or other home's word. *Not built yet:* a declared operation that issues a key's consent capability.

### 5.5 Credentials

An entry has four uses: attach, dispense, disclose and sign. CYFR attaches a credential to the request it is bound to, which goes once to its pinned address, and the component never holds it unless its consent names that disclosure. A program's own sign-in is no entry: it lives in the program row's kept folder, and a grant that lets a component run the program there binds the row. The row's definition, and every change to it, is a fresh confirmation showing its whole definition, each environment name with the vault entry it names, bound to that row at its epoch; a row that stops being a program is removed as one, and that confirmation is bound to the row it becomes as well. A grant made for one definition of a row does not run the next: every grant that binds the row asks again, and the row's removal names and blocks each grant that stands on it, a login's or a grant of its tools. Enabling and disabling a program are the one change that asks nothing: disabling only stops it, and enabling brings back the definition last confirmed, since every change made while it was disabled was confirmed. A confirmed change ends the program's running sessions, as its removal does. A program's folder is never shared. Aqua's browser's profile, the sites the person signed in to in it, is such a folder: session state of the athanor's, kept with the row and retired with it, which Aqua reaches through its browser while the person's browser setting is on; a person who signs that browser in to CYFR gives Aqua that session. Each entry is bound to its destination, and material that must never leave the vault is used only through Sanctum's signing. A credential lives in one vault entry, and a share is the only way it reaches another athanor (§5.1). A shared entry is used attach-only, to its own destination, under the share's audience and caps, and only while its owner stands and the entry stands at the digest the recipient approved. Masking and log redaction are defence in depth, not the bound. *Not built yet:* Sanctum signing with a vault-held key.

### 5.6 Egress

Guest egress is a HostAPI operation: Opus decides it under the attempt's authority, never resolving a host that authority refuses, and pins the address, and every redirect is pinned again. The control plane's own outbound calls are an inventory a seam test holds, and an owner's call to an outside service goes through Sanctum's pinned transport.

### 5.7 Isolation of untrusted processes

Untrusted processes run apart from the control plane and from each other, with restricted privileges, bounded resources and full cleanup before reuse; a runner holds no route, and its traffic with the control plane is signed and versioned. A kept home's uid is never given to another owner: no pool holds it, and only the processes of that home's own sessions run under it. A program reaches the hosts its row names or, with none, public hosts, beside the deployment's private hosts: its island's egress guard holds every spawn uid, pooled or kept, to the addresses its keeper resolved when the process started, and a process it cannot so hold never starts. *Not built yet:* perception bodies.

### 5.8 Separate meanings

Resource limits, platform ceilings, capacity ceilings, depth caps and invocation budgets are separate meanings, each with its own contract for zero and absence; a security bound is never made a capacity setting, and a count that cannot be read refuses the write.

**Why.** Authority is checked where it can be: at the resource's owner, under the actor, at the point that releases the data.

## 6. Ownership, state and reliability

### 6.1 Members and the cell lease

Each control-plane member owns its slot through a database lease with a generation of its own; a peer joining invalidates no healthy member's slot, and host calls bind to the member that issued them. **A stale owner admits no work, dispenses no credential, emits no result and overwrites no successor's state**, which is verified live in the transaction that writes: it holds its slot's lease row against a take-over or a release until it commits, never against its own member's renewal.

### 6.2 Boot and standing transitions

No admission path opens before a declared restore's transition commits under the live lease. A standing transition retires everything it ends in the same transaction.

### 6.3 Publication

Units publish under revision prefixes no other commit writes into. A row or document the host owns publishes fenced: staged immutable, and committed only while the writer's live ownership and the revision it read both still hold, each writer verifying its live slot in its writing transaction. The resource revision, the member generation and the lease row's **fence**, a write token for the lease row alone and never a publication's identity, are three numbers kept apart.

### 6.4 Decision audit

The gate records a decision for every admission but the reads its catalog lists as unrecorded, for every refusal, and a completion after. The audit never decides: a lost write is counted and the result stands, and a missing completion is unknown, never success. Audit traffic never consumes the capacity that renewing ownership needs.

### 6.5 Attempts and outcomes

Each admitted guest holds a durable attempt generation its effects are fenced against. A crash past a step that is not replay-safe is uncertain, a possibly completed effect is replayed only under a contract that proves it safe, and every exit path releases resources and stops dependents in order.

### 6.6 Revocation bounds

A standing or credential change reaches a new admission at once on the member that committed it and within the caller-cache lifetime elsewhere; an open stream ends at its first revalidation after that, and admitted work runs to its recorded outcome under its fence. A protected device's session ends at its expiry once its channel stops sliding it, whatever announcement is missed, and an open page or stream under it revalidates by then. When the store cannot answer, admission refuses.

### 6.7 Schema

Until the first release one baseline migration is the schema; after it, dated migrations follow and the fingerprint names the applied set. Both adapters hold the same constraints, and a cell upgrades with every member stopped. *Not built yet:* dated migrations, a fingerprint of the applied set and a refusal that names the migration to run, and the export and import that move a home between adapters.

### 6.8 Configuration and settings

Configuration is parsed explicitly, and an invalid security-relevant value is refused. A platform setting is read through one accessor, environment first, and an unreadable store refuses the boot.

The access mode is a deployment setting: one value in the deployment file (`CYFR_ACCESS`: `local`, `tailnet` or `public`), from which the home's address, its listeners, its origins, proxy trust and the stack's profile selection follow (`Cyfr.RuntimeConfig.resolve_access/1`). Only the machine's own `cyfr` writes it, the boot refuses a setting that contradicts it, and a local home listens on the loopback alone. A passkey lives at the directory's host, never the home's, so a change of address asks nobody to register anything again; the setup token binds the installation to its first account and then opens nothing (`Arca.InstallationClaims`).

### 6.9 Backup, runtime and budgets

- A backup is a stopped cell's database, storage, keyring and deployment file. An update is a ceremony the platform administrator runs from a signed release manifest, refused before anything stops when the manifest's schema fingerprint is not the running cell's, and a failure leaves the cell stopped with its snapshot.
- A restore is declared: the boot consumes its marker before the gate opens and, in one transition, retires every session, suspends every API key, webhook secret and paired client, revokes every device certificate and every share, asks again for every grant and raises every standing, so nothing admitted under the backup stands and restored authority never re-enables itself. It suspends this home's own bindings and never an account's keys, which no home holds: a device comes back by a fresh hello and a browser by a fresh sign-in, and re-enabling an API key or webhook is its owner's operation under a fresh confirmation. *Not built yet:* an outside rollback floor against an undeclared restore.
- A storage reserve keeps headroom to take authority away (`Cyfr.StorageReserve`): below it the gate admits only reads, the operations declared `reduces_authority` and the confirmations they need, and the cell's renewal and shutdown never refuse.
- Startup and shutdown run in dependency order, and a cell-wide claim whose job the shutdown kills, such as the retention sweep's, is kept until a peer takes it over when it lapses.
- Each workload has a latency budget with its measurement; the canvas proof holds a frame open and a canvas validation to theirs. *Not built yet:* an overload budget for any workload; the latency budgets of an admission at concurrency, a first token, a feed fire, a device intent and a console page; and the measurements of a feed fire and a console page.

**Why.** Correctness rests on the lease verified where the write happens, never on a member's belief that it still owns.

## 7. The screen and tinctures

Prism is one screen, in two layers: the desktop and its apps, tinctures in frames, and everything else, CYFR's own code opened over them without leaving them: the system layer, the top bar and shelf, the settings, the chat and the assistant's panel.

- **One screen.** Sign-in lands on the desktop (`PrismWeb.DesktopLive`): the person's canvases with their apps over them (`PrismWeb.ShellLive`), a LiveView of its own beside the page's, so moving between pages never moves or reloads a frame. The settings are the Dashboard's pages, opened from the gear on the shelf, or from a canvas's `settings` verb by a page name from Prism's list, as an overlay over the desktop in the same document, with no page load (`PrismWeb.Layouts`); the frames keep running under it, and the settings code is given no frame port and no bridge hook. A workspace thread is such a page drawn full (`PrismWeb.WorkspaceLive`), opened from its pointer or report on the daily thread and from the assistant's panel: its posts at the side and its steps and results in the middle on the desk, two tabs in the hand.
- **The chat** is CYFR's own overlay beside the assistant's, with its own control and unread count on the shelf (`PrismWeb.ChatOverlayLive`): the person's shared threads and pairs, opened in place, a sheet that fills the screen in the hand and a panel on the desk. Its sharing acts are plain clicks in CYFR's code; it opens no frame and no message body enters one. While it shows a thread, the person's read mark there moves, kept on their seat by the thread's owner (`Sanctum.SharedThreads`); the assistant's panel reads the thread it shows only when the person ticks it, and approval cards appear only in the assistant's threads: the person's daily threads, which the assistant's panel opens on today's of, with a count on its control of the posts that arrived since it was last open, their workspace threads and their crew threads.
- **The system layer** draws every grant, confirmation, credential entry and frame's request above every frame, and is the one place the screen presents a consent, from Sanctum's preview; the command line presents none and confirms nothing, and a box's shell draws the preview of a change it confirms on its own page, fetched from the home, never from the page that asked. A frame's request is presented on the preview Sanctum builds of exactly the call that runs, naming the frame that asked, and the system layer runs it as the person once they approve; the frame performs nothing (`PrismWeb.SystemLayer`). A confirmation's key ceremony is not the system layer's: after the preview it sends the browser to the account pages with the home's request, and takes the signed answer at its return (§9.3). *Not built yet:* unlocking the vault.
- **A program's terminal** is Prism's own frame on the Programs page, drawn under the system layer: its chrome names the program and nothing the program writes reaches it, the terminal acts on nothing the program writes (no title, no clipboard, no bell; an http or https address opens only on the person's click), asks no secret, and stores and logs nothing. What reaches the program is what the person types and the terminal's own answers to the program's standard queries (where the cursor is, what the terminal is), never text the program chose. The page attaches to a session the person owns (§3 Opus), so a reload or a second tab shows the running screen and leaving ends nothing; when the program ends, the open page keeps its screen, read-only, until the person closes the frame. No address starts a program: a start is the person's press.
- **Aqua's browser in a workspace thread** is Prism's own view in the thread's layer (`PrismWeb.WorkspaceLive.BrowserLive`), drawn under the system layer. While the person's browser holds a window for the thread it offers to show it, and nothing streams until the person asks. Asking is the person's `browser.watch` from that page alone, a browser's session on the console's own admission path, never a paired device's channel or the command line, and is refused while their browser setting is off; that window's images come to the page's own socket, each drawn before the next is sent, only while its context stands, and the person's clicks and keys go back under the same watch to that window alone while Aqua goes on with its work. The view is CYFR's code, not a frame: no frame credential is minted, and the page in the browser reads nothing of the thread beside it. One page shows a window at a time, and a page of the person's that asks after it takes the window, which the first says. Closing it, leaving the page, the context no longer standing and the setting going off end it.
- **Frames.** Prism creates every frame under the sandbox the tincture rules derive, and a frame reaches data only under a per-open credential Sanctum mints and revokes (`Sanctum.TinctureAuth`). A page in Aqua's browser is no frame: it holds no credential and has no shell, the SDK added to its entry runs in its public mode, and its calls are Aqua's own in its thread (§3 Aqua).
- **Apps over a canvas** stand as windows, tiles or full (`Prism.Frames`, `Prism.Arrangement`): a window at its position and size, a tile at an edge with its share of the width, which narrows the canvas, and a full app over the whole area between the top bar and the shelf. The shell draws every piece of chrome outside an app's frame (`PrismWeb.CanvasLive`), so an app can neither fake nor press it; a gesture that places an app raises it, and the shelf holds the canvases, their open apps, the gear, the chat and the assistant. An app's manifest carries a size hint, never a placement it can demand, and in the hand every app is full. The assistant's panel stands over every app and every page drawn over the canvas, a workspace thread's included, and under the system layer, and never narrows the canvas.
- **The layout** is the person's (`Prima.Layout`, stored by `Arca.Layouts`): their canvases and, per posture, where each app stands. It changes only through the gate's `layout` tool, which the shell calls as the person once a gesture settles, as the assistant, the command line and the API do; every screen of the person reads it again when it is announced. No tincture declares the operation.
- **Canvases** are the person's pages, tincture pages written like any other: a canvas reads only the streams its grant names and the feeds it declares (`Opus.Feeds`), each a picture of items its deliverer hands whole, revisioned and timed, and hands again after a gap, telling the canvas when it is unavailable, stale or denied (`Compendium.Canvas.catalog/1`), changes nothing by itself (its credential reaches only its own streams), and learns which installed apps are open over it and the rectangles its windows cover, never what a window shows. What it asks for the person, an open, a press of a control it declares or of a feed's action, a request for one of the person's own acts, a write of its preferences, an ask of the assistant or one of Prism's pages, the shell does once per input of the person's in it, never from a script on its own; hidden, it reads and acts on nothing. A control runs through the gate as the person, held again to the rule publish holds it to, its one picked value checked against the stream's current state (`Compendium.Desktop`): directly when it is a write the person makes directly, a feed's action or a retry, and otherwise as a request the person approves first. Its preferences are the person's own document for that canvas (`Arca.CanvasPrefs`), and while it is shown its chrome's tokens restyle Prism's own chrome; the system layer keeps Prism's theme. A request, from an app's frame as from a canvas's, names one of the person's own acts, a grant of an installed component, a schedule, a feed's binding, an arrangement or an operation that asks for their confirmation, and waits on them in the system layer's prompt until they decide it or it expires; one frame's requests wait one at a time, and a frame grants and runs nothing. *Not built yet:* a canvas's read operations, and a feed from a run that stays open.
- **Code and layout are separate**: a code change is a new version, validated before it replaces the canvas (`Prism.CanvasValidation`), and a version that reads more asks again. The way back from a broken canvas is outside every canvas: when the canvas shown does not start or its frame dies, the shipped canvas stands in its place, every app and the assistant stay, and the system layer offers to try again or to restore the last working version (`Prism.Fallback`). A page error after the canvas started is not a failure.
- Emissary serves every tincture's files and data routes, and a public tincture runs under its own profile, never a viewer's session.

*Not built yet:* the Dashboard's vault page asks for a credential in its own form, not the system layer's.

**Why.** The screen is where consent is given, so what confirms, consents and asks for secrets is CYFR's own code, and every other part of the screen can fail without taking those with it. Arranging the screen is one more operation through the gate, so a window the person drags and one the assistant moves are the same act under the same authority, and no screen holds a write path of its own.

## 8. Homes, glasses and hubs

- A home is the one installation that decides for an athanor. Home, glass, hub, cell, node and door are this document's words: what a person reads, the setup pages, the command line, Prism, the README and the guides, says CYFR for the installation and Aqua for the assistant, device or browser for the glass, the CYFR you join for a hub, cluster for a cell and server for a member of it, machine or server or CYFR for a node by its sense, and sign-in method for a door, and never these words.
- Every athanor has exactly one home; a cell is several members acting as that one home on one database (§6.1). *Not built yet:* replicas and their journal, and home transfer; a node is the home of every athanor its store holds.
- The glass is the client: display, input and one key of its person's account that it never exports, the same at every home. A device's key is held under a local unlock (`Sanctum.DeviceUnlock`); a browser holds none of its own and proves the person with the passkey its platform keeps for the directory, through the account pages. The client shell runs on the box's screen, one home per context; a device keeps its key under a six-digit PIN its TPM checks, or without a chip under a passphrase. *Not built yet:* an application that hosts Prism, the client shell's home switcher, listening without a page, notices and their read state across homes, and push delivery.
- A hub is the always-on home of shared threads, where people, its platform administrator among them, share keys from their own vaults with a shared thread or with everyone (§5.5). Any home may require a company's sign-in of every person there: a standing condition, checked last wherever a person's standing is read, and never a door or the person's identity (`Sanctum.CompanyLogin`). *Not built yet:* the hub as a model provider and as a standby, and the governance floor, which shows every person in a shared thread a consent that exports their contributions and lets each withhold what they authored.
- Every wire between homes names its version, and CYFR has no relay.

**Why.** A decision about an athanor is made in one place, so no node acts for a home because a lease looks expired or a clock says it is lost.

## 9. People

### 9.1 Identity

A person has one account: a name for life at the registry, an identifier, and a log of public keys ordered by one directory (`Prima.Identity`), cyfr.run's by default or a home's that serves one. The log lists the keys of the person's devices and their passkeys, and the recovery keys their recovery codes hold (`Prima.RecoveryCode`); every key lives only on the person's devices and in their codes, and no home holds a key of anyone's. The genesis, signed by a recovery key, is the identifier's hash; any listed key adds a key, any other key or a code removes one, and only a code replaces every key or adds a code, at once. The directory accepts a signed entry after its head, serves the log and the static account pages a passkey lives on, and stores nothing else: no destination, session, email or list of a person's homes. A home is a workspace that admits accounts by identifier and holds its own membership, athanors and sessions, never written at the directory: setup admits its first account and binds the installation to it, an invitation or the open admission the next (`Sanctum.Newcomer`, `Sanctum.Door`). A home reads an account's log fresh within a bound and walks every entry after the head it holds, retiring what was bound to a removed key and everything a recovery replaced; a write that binds authority names the head it was verified under, and is refused once that head has moved (`Sanctum.IdentityFreshness`). A sign-in reads the log live, so what a key removed and added again signs afterwards stands, and only what it bound before its removal retires. Past the bound a public home pauses that person's protected work, and a local or tailnet one keeps admitting the people it holds on the keys it last read and refuses an account it never read. A home resolves a name to its identifier at the registry and reads its keys from the directory (`Sanctum.Handle`). *Not built yet:* attribution by identifier, delegated work, and the mail transport an emailed invitation needs.

### 9.2 Joining a home that is not your own

A person signs in at any home with their account. The home mints a request for that sign-in, bound to the browser that asked, and sends the browser to the directory's sign page with it; the person's passkey signs it there, the page returns the answer to the home, and the home verifies it against the account's log and asks its own rules (`Prima.SignIn`, `Sanctum.SignIn`). A device answers the same request over its channel after its local unlock. The page takes its input from the fragment, returns only to the home that asked and tells its server nothing, so the directory never learns where a person signs in. Each home admits under its own rules. An invitation admits whoever redeems it, once, and writes a lasting allow only where no deny stands, so a deny always wins (`Sanctum.Door`). A home knows a person by identifier: a name is resolved to its identifier when an allowlist entry or a shared thread's seat names it, and the name is never stored as the key.

### 9.3 Devices and fresh confirmation

Who a person is, which devices they connected and whether a change needs a fresh confirmation are three separate facts, and no client holds a rank. Everyday work needs only the session; changes to devices, credentials and anything else that outlives the session need a fresh confirmation at the deciding home (`Sanctum.Pairing`): after the system layer or the device drew the stored record's preview, the person's passkey at the account pages or a device of theirs after its unlock signs the home's request naming that record, and the home checks the signer is a key of that person's under the head it reads. A registry request a key of the person's account signs, over the exact operation and body the account pages show in words, is that operation's fresh confirmation, so a push token minted by it asks for no other (`Sanctum.SignIn`, `Compendium.Providers.Registry`). A device joins the account at the account pages, approved by a passkey from the code the device shows. A passkey joins the other way for a browser that holds none: the account pages make it and return it to the home that sent the browser, which holds it for the person's devices to list, and the box's shell adds it with the box's key once the person compares its code there (`Sanctum.SignIn`). A home admits a device by its first hello over the device channel, verifies its signature against the log and issues its own short certificate under its installation key, renewed over the channel, which no other home ever reads (`Prima.DeviceCert`, `Sanctum.DeviceCerts`). The paired clients a home lists are the devices and passkeys that signed in there, by key. Only the client that asked repeats the change, with the exact operation, arguments and preview the record holds. *Not built yet:* the display and pointer-input contracts and athanor policies that add changes.

### 9.4 Communication

People talk in shared threads of a CYFR that is always on, each from their own athanor there; there is no messaging protocol beside it and no directory of strangers.

**Why.** The person outlives every device, key and home, so identity is a log their own keys extend, checked at each home that relies on it, never vouched for by a home or a provider, and no home holds a key that would let it act as them anywhere else.

## 10. Grants

Consented work runs unattended under its grant; a person is asked only about what no grant covers, and an uncovered external or destructive proposal is approved once, never banked.

- Component grants and standing approvals are the two kinds of grant, under one set of rules.
- A preview is typed rows bound by a digest; narrowing is validated by its owner, and widening is interactive. *Not built yet:* a share's caps on the preview's credential row.
- A grant says what a component may reach and use, never who may start it: a run carries the origin its admission path set for the record, and stands on the grant of the person it acts as, whether a screen, a key, a schedule, a webhook or a page in the assistant's browser started it.
- **A standing approval is bounded.** It ends with its lifecycle or deadline and holds to its resource constraint, and an external or destructive action never takes a standing allow, but for the browser tool's actions, which follow the person's own browser setting: on, they run without a card; off, they are refused. An answer for one of the person's schedules is agent-wide, covers only the runs that schedule started and ends with it, and is part of the answer's identity, so it stands beside another schedule's and beside one for no schedule; an action that takes an answer for one thread only takes one for a schedule too.
- Every turn records the source classes it read (`Prima.Source`), and every send to an exit is held to the flows its grant declares, which `Prima.Flow` decides.
- A standing grant never stands in for a fresh confirmation. *Not built yet:* declared reads of standing approvals.

**Why.** The person decides once, on a preview that says exactly what is granted, and whatever the grant does not cover is asked about each time.

## 11. Memory

Notes are what was kept out of a thread (`Aqua.Notes`): filed notes, which a person approves, and the about-you page, read into every turn, which the assistant keeps current itself with no card, as it does a workspace thread's notes. A note written in a chain keeps the outside sources its chain read and no `thread` source, since it outlives the thread it came from and reading it makes no turn a reader of that thread; it is never endorsed by being written, and a turn that reads it reads its sources too, so an about-you page written after outside material asks a card of every later run whose grant does not let that material out, until the person writes the page as their own or removes it. A turn writes the about-you page only over the revision it read, so a page the person changed during the turn is refused to it and stays theirs. Notes survive the deletion of the thread they came from; the person's page records the thread a revision of the assistant's came from, and the Aqua page marks one learned in a deleted thread and offers Remove, never rewriting it.

*Not built yet:* Memory, the assistant's account of what happened, what is known and what is worth repeating, captured from the outbox (§4.3), published fenced (§6.3) and stored under the `memory/` root; notes and `notes.endorse` exist today (`Aqua.Notes`). Its seams: capture is durable before it is fast, an answer needs access to every athanor it draws on, and outside content becomes a belief only by the person's endorsement.

## 12. How the architecture is held

Layer edges are Mix dependencies and Boundary declarations, so a forbidden edge fails to compile; `Cyfr.Boundaries` rosters what the compiler cannot express, each row with its reason; seam tests hold actor-first arguments, the markers and the security-read seam; drift tests hold every derived view to its owner, this document's module sections, ports table and bounded standing approval among them; and containment suites run the shipped image in each role.

### Sources of truth

| Fact | Owner |
|---|---|
| Wire shapes, the actor, authority data, the Locus role table | Prima |
| Schemas, transactions, revisions, the lease row | Arca |
| Who may do what, consent, credentials, fresh confirmation, identity, caps | Sanctum |
| Operations, arguments, planes, streams | the providers on Sanctum's roster |
| Boot, topics, configuration, settings, boundaries, admission | Host |
| The access mode | the deployment file, written by Codex, checked at boot by Host |
| Served files, frame capabilities, frame policy, the canvas declaration | Compendium's tincture rules |
| Memory records and pages (*Not built yet*) | Aqua, stored by Arca |
| The layout | the person, stored by Arca |
| A contract's detail | its owning module's documentation and comments |
| The architecture | this document; the glossary in `README.md` is checked against it |

A change to a principle, a layer edge, a port or an invariant changes this document in the same change.
