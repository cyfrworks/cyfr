# CYFR architecture

This document outlines CYFR's architecture in the present tense of its end state: the layers, what each part owns, how the parts talk, the guarantees two or more parts keep, and why. A **Not built yet** line names what the code lacks, so a sentence without one describes the code as built. A sentence belongs here only if it says who owns a thing, who may reach or trust whom, which channel joins two parts, or a guarantee two parts must both keep; the rest lives once, in its owner's documentation. Names, directories, binaries and prefixes are in the [glossary in `README.md`](README.md#glossary).

## 1. Purpose and principles

### 1.1 What CYFR is for

CYFR is a home for a person's work with AI and a place to talk with other people: an assistant, the components it builds and runs, files, schedules and credentials, on infrastructure the person controls. It rests on one idea: **a model proposes, and CYFR decides.** Only a declared operation, admitted by one gate under a consent the person gave for exactly that action and those resources, carries an action out, and credentials live in a vault no model sees. The person, not a provider, device or sign-in, is the lasting thing; authority is decided at the one home of what it concerns; and untrusted code runs outside the control plane.

### 1.2 Principles

- **One owner per fact.** Each schema, policy, operation, topic, protocol shape and setting has one authoritative module, and everything else is derived from it and checked against it.
- **Downward calls are direct; upward needs are ports; reactions are events.** Boot installs exactly four ports (§4.2).
- **Three guards, each with one owner.** Sanctum's gate admits operations, Arca scopes rows by the actor, and only Sanctum reads security rows.
- **Fail closed.** Identity, standing, consent, ownership and catalog completeness are settled before work is admitted, and a control that cannot answer refuses; only the decision audit (§6.4) records without deciding.
- **Admission, not sampling.** The gate admits discrete intents; continuous data flows only under a grant already admitted.
- **Few names.** A namespace exists only for state or a trust boundary nothing else owns; there are eleven (§3).
- **Data goes down, typed reasons come up.** A decision module answers typed facts and refusals, never prose of its own (§4.5).

### 1.3 What CYFR trusts

- **Trusted:** the home's own code, with the system layer and the command line that runs its machine; the platform administrator; the home's store; a person's passkey or a protected device's local unlock (§9.3); and the directory, for consistently ordered logs alone, with its account pages, trusted browser code like any site a passkey lives on.
- **Not trusted:** models and their output, components and tinctures, untrusted processes, another person's session, another home's word, and anything a guest hands back.
- **Stated limits.** Fresh confirmation protects against a stolen session, not a compromised administrator. A recovery code, a backup or a session is authority to whoever holds it, and malware on an unlocked device can use its key until the key is removed from the account. A local or tailnet home that cannot reach the directory keeps admitting the people it holds on the keys it last read, so a removed key keeps working there until it reconnects. The gate decides CYFR's operations: a program harness's own tools run inside its box, bounded by its isolation (§5.7), not by the gate.
- **The trusted computing base** is the control plane, which holds the decrypted credentials; Locus is the process boundary for untrusted code.
- **Clock trust.** Expiry, leases and freshness are read on the deciding home's clock, and a cell's leases on its database's.

## 2. Layers

```
L4  Trust island    Locus (the WASM runtime, builds, programs), under its keeper cyfr-locus
                    depends on Prima only; reaches L1/L2 over signed, versioned protocols

L3  Surfaces        Emissary (external protocols)   Prism (the screen)   Codex (CLI, the CYFR app)
                    adapters over Sanctum's gate and Sanctum.Caller; a surface never names another surface

L2  Domains         Compendium   Aqua   Opus
                    an acyclic graph (Aqua→Opus, Aqua→Compendium, Opus→Compendium) through exported modules

L1  Foundations     Cyfr (Host)  >  Sanctum  >  Arca
                    strict order; a lower foundation never names a higher one

L0  Prima           types, wire shapes, behaviours, pure primitives, the actor
```

The order describes dependencies, not a request's path. Codex shares no code with the control plane: it speaks Emissary's protocols and runs the machine the stack runs on. Only Host's composition modules (`Cyfr.Application`, `CyfrWeb.Endpoint`, `CyfrWeb.Router`) name the layers above them, to wire them, beside the boundary catalog (`Cyfr.Boundaries`), which names every module it judges; Emissary is the one surface that also implements a port (§4.2). A new concern goes in the lowest layer whose neighbours do not need it.

**Why.** Each layer can be understood knowing only what is below it, and builds and scans, not review, keep it so.

## 3. Modules

### Prima: shared contracts

- The actor, authority data, operation declarations, refusals and the provider, host and worker behaviours.
- The wire shapes and signing domains more than one part implements, such as the HostAPI, the WorkerAPI and the keeper's protocol.
- The pure network policy and the Locus role table (`Prima.LocusRoles`).
- No persistence, no product policy and no process: the two process modules it defines run under the applications that start them.

### Arca: persistence

- The repo and every schema, query and transaction, on SQLite and PostgreSQL alike; nothing above Arca names the adapter.
- Blobs behind one storage abstraction (`Arca.Storage`), and storage revisions.
- Leases, the cell lease row, job claims, the cache, retention and the durable outbox (§4.3).
- The security rows, which it holds and only Sanctum reads, and the records and files providers.

### Sanctum: decisions and the gate

- Accounts as a home relies on them: sign-in, sessions, admission, devices and fresh confirmation, and the directory a home may serve.
- Tenancy, shared threads and their people, caps and the caller context (`Sanctum.Caller`).
- Consent, the vault and its shares, credential attachment, a component's question to its person, and frame credentials.
- The gate: the operation table (`Sanctum.Catalog`), its entries (`Sanctum.Gate`, `Sanctum.Streams`) and the decision record (`Sanctum.Decisions`).
- No Ecto and no broadcast. It alone reads security rows (§6.2).

### Cyfr (Host): the machine

- Supervision, boot, the cell claim and the composition root that installs the four ports.
- The bus (`Cyfr.Bus`), the telemetry bridge, configuration, the access mode and platform settings (§6.8).
- The endpoint: the listener that accepted a request is its ingress, never a header (`CyfrWeb.Ingress`).
- The admission roster of every path an intent enters by (`Cyfr.Admission`) and the boundary catalog (`Cyfr.Boundaries`). *Not built yet:* the local socket and the compositor, which the roster declares and defers.

### Compendium: components

- Component kinds, manifests, the registry, activation, provenance and builds over Locus.
- The tincture rules (`Compendium.Tincture.Rules`): what a tincture may serve and declare, the frame policy derived from it, and what a canvas may ask.
- The assistant's files, and the source of its one grant (`Compendium.AgentSource`).
- The component, registry, source, build, Aqua-file, canvas and layout providers.
- Two ports' implementations (§4.2).

### Aqua: the assistant

- A person's daily, workspace and crew threads with the assistant, each driven by one runner, and notes (§11).
- The crew: the soul and the members a person makes, each on a brain, a model catalyst or a program Opus holds.
- Every crew turn runs under one grant, Aqua's, so toward CYFR the crew is one caller; its model call runs under its brain's own grant.
- Nothing leaves an athanor for a shared thread but what its person says aloud (`Aqua.Aloud`).
- Opus never calls Aqua: a schedule's fire and a page's call reach it as events.

### Opus: execution

- Admission of executions, attempts and accounting, schedules and feeds.
- The HostAPI server and the WorkerAPI client, its side of the wires to Locus.
- Guest storage, guest egress (§5.6), the attached request (§5.5), a guest's ask and output masking.
- Programs, their sessions and kept folders (`Opus.Programs`). CYFR's side of a program is always a holder (`Opus.Brain`, `Opus.Browser`), and a driver sits beside a program only where CYFR must act on what it says, over a wire of Opus's own.
- A session belongs to the person, turn or thread it was opened for.

### Emissary: external application protocols

- MCP in both directions, the HTTP API, webhooks and the OAuth callback, carrying declared operations through the gate, or deciding at an entry the admission roster names (§5.3).
- Tinctures' files and data routes (§7), the device channel (§9.3), and the directory's endpoints and account pages where a home serves a directory (§9.1).
- The proxied-tools port's implementation (§4.2).

### Prism: the screen

- The system layer, the frame manager, the shell, the desktop and its pages (§7), and browser sign-in.
- It dispatches through the gate and reads domain facades. Beside the gate it writes only a person's own presentation state, signs its browser session out, drives that person's own terminal sessions (`Opus.Programs`) and mints and revokes its frames' credentials through Sanctum, each a rostered call (`Cyfr.Boundaries`); its sign-in pages admit for themselves.
- Its setup page admits an installation's first person and changes nothing on the machine.

### Codex: the command line and the CYFR app

- The `cyfr` binary, speaking MCP to Emissary with an API key alone, its operation catalog generated from the gate's table. It signs no one in and confirms nothing.
- The machine: its access engine alone owns the deployment file's access settings and the stack's access services, and backup, restore and update are its commands (§6.9).
- The device's shell, on the box's screen and in the CYFR app: the one place a protected device's key is unlocked (§9.3).
- The CYFR app, which shows Prism from a machine that runs no stack and keeps each window to the home it opened.

### Locus: where untrusted things run

- The runtime, whose runners execute components with no network of their own, and the builds and backends services, for toolchains and programs, each reached under a key of its own.
- The keeper, `cyfr-locus`, which starts every child under a uid and bounds of its own and scrubs it on release, and the egress guard (§5.7).
- A program's driver, between the program's own protocol and Opus's wire.
- Opus, Compendium and Emissary decide what runs; Locus only runs it.
- *Not built yet:* a VM level of isolation, a computer per athanor, and perception bodies with their display and pointer-input contracts.

### Apps and releases

Two releases: `cyfr` (the Mix apps `prima`, `arca`, `sanctum` and `cyfr`) and `locus` (`prima` and `locus`). Sanctum is an app of its own because its licence boundary is an application directory; `cyfr` hosts Host, the domains and the surfaces under Boundary declarations. The keeper with its drivers and `codex` are Go modules, and the CYFR app wraps `codex`'s binary.

## 4. How modules talk

### 4.1 Channels

| Between | Channel |
|---|---|
| A module and one below it | A direct call into an exported module, context or actor first |
| A lower module needing something above it | One of the four ports (§4.2) |
| Two domains | Calls into exported modules, in one direction only |
| Two owners, one commit | One Arca transaction with the higher owner's closure (§4.4) |
| After a commit | An event on the bus, which never grants authority |
| A surface acting | A declared operation through the gate, or an entry the admission roster names |
| A surface reading | Domain facades under the caller's context, never a security row |
| The trust island and the control plane | A signed, versioned protocol whose shapes live in Prima |

Telemetry becomes a bus message only through Host's bridge.

### 4.2 The four ports

| Upward need | Declared by | Implemented by |
|---|---|---|
| The storage and counted cap decision (`Prima.Caps`) | Prima | Sanctum |
| Component facts for consent and the gate's stream admission, and filling an athanor with its components (`Sanctum.Consent.Components`) | Sanctum | Compendium |
| Proxied tool resolution (`Sanctum.Proxy`) | Sanctum | Emissary's external half |
| Where a storage unit's bytes live (`Arca.Storage.UnitLocator`) | Arca | Compendium's component and Aqua path grammars |

Host installs each implementation at boot, and the declaring module fails closed when none is installed; a fifth port is an architecture change. **Why:** each port is a need a lower layer cannot meet without naming a higher one.

### 4.3 Events

Topics are declared once in `Cyfr.Bus`, a grantable topic carries discrete facts, a broadcast of a write follows its commit, and a subscriber that reconnects is admitted afresh. A reaction that must survive a crash starts from an Arca outbox record committed with its source; the bus, or the caller that committed it, only wakes its consumer, which receipts each record once. What waits on a person reaches their screens as a reference on one stream, never as the record (`Cyfr.Providers.Prompts`). *Not built yet:* a stream's declared replay.

### 4.4 Transactions across owners

A write two owners must commit together is one Arca transaction. The higher owner's part enters it as a named closure (`verify:` or `also:`), declared by the Arca function that takes it, which touches only its owner's rows, calls no network and publishes nothing. Arca owns the transaction and never names the owner. Broadcast follows the commit, by the caller, and a fenced write keeps its fence inside the same transaction.

### 4.5 Errors and words

Classified conditions are typed tuples and programmer errors raise. A refusal crosses every boundary as a `%Prima.Refusal{}`, whose class and one sentence are Prima's, and a guest sees only its `Prima.GuestError` projection.

### 4.6 Adding a capability

A new effect is a declared operation in its owner's provider, and a new record an actor-scoped Arca row. Only a fifth port, a new layer edge, a new channel or a new namespace is an architecture change.

## 5. Tenancy, authority and isolation

The person decides; Sanctum validates, records and checks; and the place that releases the data or performs the effect enforces what was admitted.

### 5.1 Tenancy

- The athanor is the one tenancy unit, one person's own, and every person admitted to a CYFR has one there.
- Tenant identity comes from the authenticated actor, never from a guest's argument, and ownership travels with rows, blobs, events and cache keys.
- The one widening across athanors is a share of a vault entry, which its audience uses only through their own consent and never sees the material of (`Sanctum.Shares`).
- A platform administrator holds a capability over the instance, not a wider scope: what the instance holds for them is the host's own, never another athanor's.
- A shared thread belongs to no athanor and holds no assistant or execution; every read and write checks the caller's seat (`Sanctum.SharedThreads`).
- Outsiders learn nothing of an athanor: anyone but its person gets the answer a missing athanor gets.
- Nothing lands in an athanor its person did not accept.

### 5.2 Identity and standing

Identity and standing are established at the authentication boundary (`Sanctum.Caller`), and a long-lived context revalidates them before protected work. A session, a device certificate and a pending confirmation are bound to the key that signed for them, so removing the key from the account ends each at every home that reads the removal (§9.1). A standing channel, an API key, a webhook, a schedule or a grant, acts under its creator's standing.

### 5.3 One gate

The screen, the command line, the wire and the assistant share one operation declaration and one gate, on two planes: external callers and calls inside a running chain. An entry that decides a request before, or instead of, the gate records its own decision and is a row of Host's roster (`Cyfr.Boundaries.admission_entries/0`).

### 5.4 Consent

A consent binds to the exact action and resources its preview showed. Who may consent follows how the caller authenticated, never what it holds. Human approval unblocks an action already authorized and grants nothing more, and neither does what a turn is offered or a harness's access setting: the gate admits every call under the authority as it stands when the call is made. A fresh confirmation is a held key's: the person's passkey at the account pages or a protected device of theirs after its unlock, signing the home's request that names the stored record.

### 5.5 Credentials

A credential lives in one vault entry bound to its destination, and a share is the only way it reaches another athanor. CYFR attaches a credential to the request it is bound to, which goes once to its pinned address, and the component never holds it unless its consent names that disclosure. A program's own sign-in is no vault entry: it lives in the program's kept folder, which no CYFR process reads and no backup carries.

### 5.6 Egress

Guest egress is a HostAPI operation: Opus decides it under the attempt's authority, never resolving a host that authority refuses, and pins the address and every redirect. The control plane's own outbound calls are an inventory a seam test holds, and an owner's call to an outside service goes through Sanctum's pinned transport.

### 5.7 Isolation of untrusted processes

Untrusted processes run apart from the control plane, each under a uid of its own with restricted privileges, bounded resources and full cleanup before the uid is used again. A runner has a user and a network namespace of its own, with no route. A build or a program shares its island's network and its container's process and IPC namespaces with its neighbours (`Prima.LocusRoles`): the uid keeps them apart, and the island's egress guard holds each to the addresses its keeper resolved at its start. The assistant's browser runs without its engine's own sandbox, so a page that breaks the renderer gets that browser's process: its profile and the person's sign-ins kept there, the egress its uid is allowed, and the driver's protocol towards the host.

### 5.8 Separate meanings

Resource limits, platform ceilings, capacity ceilings, depth caps and invocation budgets are separate meanings, each with its own contract for zero and absence; a security bound is never made a capacity setting, and a count that cannot be read refuses the write.

**Why.** Authority is checked where it can be: at the resource's owner, under the actor, at the point that releases the data.

## 6. Ownership, state and reliability

### 6.1 Members and the cell lease

Each control-plane member owns its slot through a database lease with a generation of its own; a peer joining invalidates no healthy member's slot, and host calls bind to the member that issued them. **A stale owner admits no work, dispenses no credential, emits no result and overwrites no successor's state**, which is verified live in the transaction that writes: it holds its slot's lease row against a take-over or a release until it commits, never against its own member's renewal.

### 6.2 Boot and standing transitions

No admission path opens before a declared restore's transition commits under the live lease. Host runs it at boot through `Arca.SecurityTransitions`, the one security store it names. A standing transition retires everything it ends in the same transaction.

### 6.3 Publication

A row or document the host owns publishes fenced: staged immutable, and committed only while the writer's live ownership and the revision it read both still hold, each writer verifying its live slot in its writing transaction. The resource revision, the member generation and the lease row's **fence**, a write token for the lease row alone and never a publication's identity, are three numbers kept apart.

### 6.4 Decision audit

The gate records a decision for every admission but the reads its catalog lists as unrecorded, for every refusal, and a completion after. The audit never decides: a lost write is counted and the result stands, and a missing completion is unknown, never success. Audit traffic never consumes the capacity that renewing ownership needs.

### 6.5 Attempts and outcomes

Each admitted guest holds a durable attempt generation its effects are fenced against. A crash past a step that is not replay-safe is uncertain, a possibly completed effect is replayed only under a contract that proves it safe, and every exit path releases resources and stops dependents in order.

### 6.6 Revocation bounds

A standing or credential change reaches a new admission at once on the member that committed it and within the caller-cache lifetime elsewhere, and an open stream or page ends at its next revalidation. When the store cannot answer, admission refuses.

### 6.7 Schema

One baseline migration is the schema, on both adapters alike, and a database runs only under the release whose schema fingerprint it records. *Not built yet:* a schema upgrade path.

### 6.8 Configuration and settings

Configuration is parsed explicitly, and an invalid security-relevant value is refused. A platform setting is read through one accessor, and an unreadable store refuses the boot. The access mode is a deployment setting from which the home's address, listeners, origins and proxy trust follow (`Cyfr.RuntimeConfig`): only the machine's own `cyfr` writes it, and the boot refuses a setting that contradicts it.

### 6.9 Backup, runtime and budgets

- Backup, restore and update are the machine's `cyfr` commands on a stopped cell, and an update is refused before anything stops when its schema fingerprint is not the running cell's.
- A restore is declared: the boot consumes its marker before the gate opens, and its one transition retires or suspends every authority the backup carried, so restored authority never re-enables itself. *Not built yet:* an outside rollback floor against an undeclared restore.
- A storage reserve keeps headroom to take authority away (`Cyfr.StorageReserve`): below it the gate admits only reads, the operations declared `reduces_authority` and the confirmations they need, and the cell's renewal and shutdown never refuse.
- Startup and shutdown run in dependency order, and a latency budget is stated by the proof that measures it.

**Why.** Correctness rests on the lease verified where the write happens, never on a member's belief that it still owns.

## 7. The screen and tinctures

Prism is one screen in two layers: the desktop and its apps, tinctures in frames, and CYFR's own code drawn over them, the system layer above everything.

- **The system layer** is the one place the screen presents a consent, on Sanctum's preview, and draws every grant, confirmation, frame's request and component's question above every frame (`PrismWeb.SystemLayer`). A confirmation's key ceremony belongs to the account pages or the device, never to Prism (§9.3).
- **A frame performs nothing itself.** Prism creates every frame under the sandbox Compendium's tincture rules derive, and a frame reaches data only under a per-open credential Sanctum mints and revokes (`Sanctum.TinctureAuth`). What it asks for the person runs as the person, on the preview of exactly that call, once they approve.
- **Serving.** Emissary serves every tincture's files and data routes, and a public tincture runs under its own profile, never a viewer's session.
- **The layout** is the person's, stored by Arca, and changes only through the gate's `layout` operation, whoever arranges the screen.

**Why.** The screen is where consent is given, so what confirms, consents and asks for secrets is CYFR's own code, and the rest of the screen can fail without taking it along.

## 8. Homes, glasses and hubs

- A home is the one installation that decides for an athanor, and every athanor has exactly one. A cell is several members acting as that one home on one database (§6.1), and a node is the home of every athanor its store holds.
- The glass is the client: display, input and one key of its person's account that it never exports.
- A hub is the always-on home of shared threads, and a door is a home's own rule for whom it admits (`Sanctum.Door`).
- Home, glass, hub, cell, node and door are this document's words, and nothing a person reads uses them (`scripts/ci/vocabulary.sh`).
- Every wire between homes names its version, and CYFR has no relay.
- *Not built yet:* replicas and their journal, home transfer, the hub as a model provider and as a standby, and push delivery to a glass.

**Why.** A decision about an athanor is made in one place, so no node acts for a home because a lease looks expired or a clock says it is lost.

## 9. People

### 9.1 Identity

A person has one account: an identifier and a log of public keys that only the account's own keys extend, ordered by one directory (`Prima.Identity`), cyfr.run's by default or a home's that serves one with its name registry and account pages. Every key lives only on the person's devices and in their recovery codes, and no home holds a key of anyone's. A home admits accounts by identifier, where a name is optional, and holds its own membership, never written at the directory. It reads and verifies an account's log itself, fresh within a bound, and retires what was bound to a removed key (`Sanctum.IdentityFreshness`). *Not built yet:* delegated work between homes.

### 9.2 Joining a home that is not your own

A person signs in at any home with their account. The home mints a request bound to the browser that asked; a key of the account signs it, a passkey at the directory's account pages or a device over its channel; and the home verifies the answer against the account's log and asks its own rules (`Sanctum.SignIn`). The account page returns only to the home that asked and tells its server nothing, so the directory never learns where a person signs in.

### 9.3 Devices and fresh confirmation

Who a person is, which devices they connected and whether a change needs a fresh confirmation are three separate facts, and no client holds a rank. Everyday work, a grant and an approval need only the session. The changes that need a fresh confirmation are one table of Sanctum's (`Sanctum.Pairing`), a credential entered, issued or shared and a device revoked among them, and the deciding home decides each (§5.4). A home admits a device by its first hello over the device channel, verified against the account's log, and issues it a certificate of its own, which no other home reads.

### 9.4 Communication

People talk in shared threads of a CYFR that is always on, each from their own athanor there; there is no messaging protocol beside it and no directory of strangers.

**Why.** The person outlives every device, key and home, so identity is a log their own keys extend, checked at each home that relies on it.

## 10. Grants

Consented work runs unattended under its grant; a person is asked only about what no grant covers, or what a component itself asks about inside its grant.

- A grant says what a component may reach and use, never who may start it: a run stands on the grant of the person it acts as, whatever started it.
- A component's question, once answered, may stand as a permission, which is no grant: it adds no reach and satisfies no fresh confirmation.
- A standing grant never stands in for a fresh confirmation.

**Why.** The person decides once, on a preview that says exactly what is granted, and whatever the grant does not cover is asked about each time.

## 11. Memory

Notes exist today (`Aqua.Notes`).

*Not built yet:* Memory, the assistant's account of what happened, what is known and what is worth repeating, captured from the outbox (§4.3), published fenced (§6.3) and stored by Arca. Its seams: capture is durable before it is fast, and an answer needs access to every athanor it draws on.

## 12. How the architecture is held

Each kind of edge has its own holder. Edges between applications are Mix dependencies. Edges inside `arca`, `sanctum` and `cyfr` are Boundary declarations, which the compiler checks in the dev and prod builds; a test build compiles without it. What no compiler can express is a roster of `Cyfr.Boundaries`, each row with its reason, held by scans of the source and the compiled modules. Seam tests hold actor-first arguments, the markers and the security-read seam. Drift tests hold every derived view to its owner, this document's module sections, ports table and size among them: a sentence that does not fit belongs in its owner's documentation. One vector file per protocol two languages implement is read by a test on every side, and containment suites run the shipped image in each role.

A change to a principle, a layer edge, a port, a channel or an invariant two or more parts keep changes this document in the same change. A change to one part's behaviour changes that part's documentation and leaves this document alone.
