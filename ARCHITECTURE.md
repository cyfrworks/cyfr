# CYFR architecture

This document outlines CYFR's architecture in the present tense of its end state: the services, what each owns, how they talk, the invariants every change keeps, and why. A **Not built yet** line names each part or behaviour the code lacks, so a sentence without one describes the code as built, and a built part that falls short of it is a defect in the code. A contract's detail, such as a rule's edge cases, a limit's value, a wire's fields or an order of checks, lives once, in the owning module's documentation or comments. Names, directories, binaries and prefixes are in the [glossary in `README.md`](README.md#glossary).

## 1. Purpose and principles

### 1.1 What CYFR is for

CYFR is a home for a person's or a group's work with AI: components an assistant can build and run, the assistant itself, files, schedules and credentials, on infrastructure the person controls. It rests on one idea: **a model proposes, and CYFR decides.** A model may suggest any action; only a declared operation, admitted by one gate under a consent the person gave for exactly that action and those resources, carries it out, and credentials live in a vault no model sees. Three consequences follow: the person, not a provider, device or sign-in, is the lasting thing; authority is decided at the one home of what it concerns; and untrusted code runs outside the control plane, isolated from it.

### 1.2 Principles

- **Prompts are not permissions.** What a model proposes runs only as a declared operation admitted by one gate under a consent bound to what was shown.
- **Layers, one direction.** A module depends on its own layer or below, and the compiler or a seam test refuses any other edge.
- **One owner per fact.** Each schema, policy, operation, topic, protocol shape and setting has one authoritative module, and everything else is derived from it and checked against it.
- **Downward calls are direct; upward needs are ports; reactions are events.** There are exactly four ports (§4.2).
- **Three guards, each with one owner.** Sanctum's gate admits operations, Arca scopes rows by the actor, and only Sanctum reads security rows.
- **The trust island speaks protocols.** Locus shares only pure contracts and signed, versioned wires with the control plane.
- **Fail closed.** Identity, standing, consent, ownership and catalog completeness are settled before work is admitted, and a control that cannot answer refuses; only the decision audit (§6.4) records without deciding.
- **Admission, not sampling.** The gate admits discrete intents; continuous data, audio and frames included, flows only under a grant already admitted. *Not built yet:* a stream that carries audio or frames.
- **One product, one code path.** Exposure follows from whether authentication is configured, never from an edition.
- **Few names.** A namespace exists only for state or a trust boundary nothing else owns; there are eleven (§3).
- **The person outlasts hardware and doors.** A lost device is revoked, a lost home restored from its backup and an identity from its kit, a lost sign-in replaced, and an enrolled person stays one identifier (§9.1).
- **Data goes down, words come up.** Decision modules answer typed facts and reasons, and surfaces own the words.

### 1.3 What CYFR trusts

- **Trusted:** the home's own code, the system layer and the command line among it (§7); the platform administrator; the home's store; a passkey or fresh sign-in, for fresh confirmation (§9.3); the identity directory, for consistently ordered state alone (§9.1).
- **Not trusted:** models and their output, components and tinctures, untrusted processes, another member's session, another home's word, and anything a guest hands back.
- **Stated limits.** Fresh confirmation protects against a stolen session, not a compromised administrator; no digest proves what a client displayed; a recovery kit, a backup or a session is authority to whoever holds it.
- **The trusted computing base** is the control plane, which holds the decrypted credentials; Locus is the process boundary for untrusted code.
- **Clock trust.** Expiry, leases and freshness are read on the deciding home's clock, and a cell's leases on its database's.

## 2. Layers

```
L4  Trust island    Locus (untrusted things: the WASM runtime, builds, stdio MCP backends, perception bodies), under its keeper cyfr-locus
                    depends on Prima only; reaches L1/L2 over signed, versioned protocols
                    runners and bodies have no network of their own; builds and backends have their service's

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

- Identity, sessions, doors, keys, devices, passkeys, recovery and fresh confirmation.
- Membership, tenancy, caps and the caller context (`Sanctum.Caller`).
- Consent, the vault, the instance's entries, credential attachment and the credentials tinctures are served under.
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
- The component, registry, source, build, AQUA-file, canvas and layout providers.

### Aqua: the assistant

- Threads, rooms, turns and their loop, approvals (§10), notes and memory (§11).
- Agent configuration and model orchestration: one turn under one grant, whatever the model. *Not built yet:* Aqua's model policy, which chooses a model per step.

### Opus: execution

- Admission of executions, attempts and accounting, schedules and feeds.
- The HostAPI server and listener and the WorkerAPI client.
- Guest storage, guest egress (§5.6), the attached request (§5.5) and output masking.

### Emissary: external application protocols

- MCP in both directions, the HTTP API, webhooks and the OAuth callback, carrying declared operations through the gate but at the entries that admit for themselves.
- Tinctures' files and data routes (§7), the device channel (§9.3), and the directory's and restore's endpoints (§9.1).

### Prism: the screen

- The system layer, the frame manager, the shell and the console (§7), and browser sign-in.
- It dispatches through the gate and reads domain facades for its trusted reads. Beside the gate, the console writes only a person's own presentation preferences, which carry no authority, and the sign-in pages are entries that admit for themselves.

### Codex: the command line

- The `cyfr` binary, speaking MCP to Emissary with an API key or a session; its operation catalog is generated from the gate's table.
- The access engine (`apps/codex/internal/access`), which `cyfr init`, `setup`, `access`, `up`, `update` and `restore` run on the machine: the one owner of the deployment file's access settings and the stack's access services, which it changes under the stack's lock and journals, so the next command to take the lock recovers a change an interruption left.
- Two faces of the one program on the machine: the terminal, and the setup pages `cyfr setup` serves on the machine's loopback before the stack runs, for a device's own screen. The pages drive `cyfr init`'s sequence and `cyfr up`'s start, no second setup, and only the machine reaches them; Prism is never a setup surface.

### Locus: where untrusted things run

- The runtime's OS runners, with no network of their own, and the build and backend services, each signed with its own key.
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
| Where a storage unit's bytes live (`Arca.Storage.UnitLocator`) | Arca | Compendium's component and AQUA path grammars |

Host installs each implementation at boot, and the declaring module fails closed when none is installed; a fifth port is an architecture change. **Why:** each port is a need a lower layer cannot meet without naming a higher one.

### 4.3 Events

Topics are declared once in `Cyfr.Bus`, a grantable topic carries discrete facts, a broadcast of a write follows its commit, and a subscriber that reconnects is admitted afresh. A reaction that must survive a crash starts from an Arca outbox record committed with its source, and the bus only wakes its consumer. *Not built yet:* a stream's declared replay, a declared refresh beyond the canvas-readable streams, and Memory's consumer of the outbox (§11).

### 4.4 Transactions across owners

A write two owners must commit together is one Arca transaction. The higher owner's part enters it as a named closure (`verify:`, `also:` or `reserve:`), declared by the Arca function that takes it, which touches only its owner's rows, calls no network and publishes nothing. Arca owns the transaction and never names the owner. Broadcast follows the commit, by the caller, and a fenced write keeps its fence inside the same transaction.

### 4.5 Errors and words

Classified conditions are typed tuples and programmer errors raise. A refusal is a `%Prima.Refusal{}` each surface renders in its own words, and a guest sees only its `Prima.GuestError` projection.

### 4.6 Adding a capability

A new effect is a declared operation in its owner's provider; a new limit, a cap of its own meaning (§5.8); a new credential kind, a vault entry bound to its destination (§5.5); a new record, an actor-scoped Arca row. Only a fifth port, a new layer edge or a new namespace is an architecture change.

## 5. Tenancy, authority and isolation

The person decides; Sanctum validates, records and checks; and the place that releases the data or performs the effect enforces what was admitted.

### 5.1 Tenancy

- The athanor is the one tenancy unit, a person's or a group's, and every active member holds the same authority.
- Tenant identity comes from the authenticated actor, never from a guest's argument, and ownership travels with rows, blobs, events and cache keys.
- A platform administrator holds a capability over the instance, not a seat: what the instance holds for them is its own, such as the host's decisions and archived athanors, never an athanor's decisions.
- Outsiders learn nothing of an athanor: anyone without a current seat gets the answer a missing athanor gets.
- Nothing lands in an athanor its members did not accept.

### 5.2 Identity and standing

Identity and standing are established at the authentication boundary, and a long-lived context revalidates them before protected work within a bounded cache lifetime.

### 5.3 One gate

The screen, the command line, the wire and the assistant share one operation declaration and one gate, on two planes: external callers and calls inside a running chain.

### 5.4 Consent

A consent binds to the exact action and resources its preview showed, and a version that asks for more asks again. Who may consent follows how the caller authenticated, never what it holds; the one consent no person gives is provisioning's, which grants the shipped seed components their declared shape so the assistant works on a new athanor, and which the person revokes like any other (`Sanctum.Consent.Bootstrap`). Human approval unblocks an action already authorized and grants nothing more. *Not built yet:* a declared operation that issues a key's consent capability.

### 5.5 Credentials

CYFR attaches a credential to the request it is bound to, which goes once to its pinned address, and the component never holds it unless its consent names that disclosure. Each entry is bound to its destination, and material that must never leave the vault is used only through Sanctum's signing. Masking and log redaction are defence in depth, not the bound. *Not built yet:* Sanctum signing with a vault-held key.

### 5.6 Egress

Guest egress is a HostAPI operation: Opus decides it under the attempt's authority, never resolving a host that authority refuses, and pins the address, and every redirect is pinned again. The control plane's own outbound calls are an inventory a seam test holds, and an owner's call to an outside service goes through Sanctum's pinned transport.

### 5.7 Isolation of untrusted processes

Untrusted processes run apart from the control plane and from each other, with restricted privileges, bounded resources and full cleanup before reuse; a runner holds no route, and its traffic with the control plane is signed and versioned. *Not built yet:* perception bodies.

### 5.8 Separate meanings

Resource limits, platform ceilings, capacity ceilings, depth caps and invocation budgets are separate meanings, each with its own contract for zero and absence; a security bound is never made a capacity setting, and a count that cannot be read refuses the write.

**Why.** Authority is checked where it can be: at the resource's owner, under the actor, at the point that releases the data.

## 6. Ownership, state and reliability

### 6.1 Members and the cell lease

Each control-plane member owns its slot through a database lease with a generation of its own; a peer joining invalidates no healthy member's slot, and host calls bind to the member that issued them. **A stale owner admits no work, dispenses no credential, emits no result and overwrites no successor's state**, which is verified live in the transaction that writes.

### 6.2 Boot and standing transitions

No admission path opens before the platform administrators' security reconciliation succeeds under the live lease. A standing transition retires everything it ends in the same transaction.

### 6.3 Publication

Units publish under revision prefixes no other commit writes into. A row or document the host owns publishes fenced: staged immutable, and committed only while the writer's live ownership and the revision it read both still hold, each writer verifying its live slot in its writing transaction. The resource revision, the member generation and the lease row's **fence**, a write token for the lease row alone and never a publication's identity, are three numbers kept apart.

### 6.4 Decision audit

The gate records a decision for every admission but the reads its catalog lists as unrecorded, for every refusal, and a completion after. The audit never decides: a lost write is counted and the result stands, and a missing completion is unknown, never success. Audit traffic never consumes the capacity that renewing ownership needs.

### 6.5 Attempts and outcomes

Each admitted guest holds a durable attempt generation its effects are fenced against. A crash past a step that is not replay-safe is uncertain, a possibly completed effect is replayed only under a contract that proves it safe, and every exit path releases resources and stops dependents in order.

### 6.6 Revocation bounds

A standing or credential change reaches a new admission at once on the member that committed it and within the caller-cache lifetime elsewhere; an open stream ends at its first revalidation after that, and admitted work runs to its recorded outcome under its fence. When the store cannot answer, admission refuses.

### 6.7 Schema

Until the first release one baseline migration is the schema; after it, dated migrations follow and the fingerprint names the applied set. Both adapters hold the same constraints, and a cell upgrades with every member stopped. *Not built yet:* dated migrations, a fingerprint of the applied set and a refusal that names the migration to run, and the export and import that move a home between adapters.

### 6.8 Configuration and settings

Configuration is parsed explicitly, and an invalid security-relevant value is refused. A platform setting is read through one accessor, environment first, and an unreadable store refuses the boot.

The access mode is a deployment setting: one value in the deployment file (`CYFR_ACCESS`: `local`, `tailnet` or `public`), from which the home's address, its listeners, its origins, proxy trust and the stack's profile selection follow (`Cyfr.RuntimeConfig.resolve_access/1`). Only the machine's own `cyfr` writes it, the boot refuses a setting that contradicts it, and a local home listens on the loopback alone.

### 6.9 Backup, runtime and budgets

- A backup is a stopped cell's database, storage, keyring and deployment file. An update is a ceremony the platform administrator runs from a signed release manifest, and a failure leaves the cell stopped with its snapshot.
- A restore is declared: the boot consumes its marker before the gate opens and, in one transition, retires every session, suspends every API key, webhook secret, device and passkey, asks again for every grant and raises every standing, so nothing admitted under the backup stands and restored authority never re-enables itself. *Not built yet:* an outside rollback floor against an undeclared restore.
- A storage reserve keeps headroom to take authority away (`Cyfr.StorageReserve`): below it the gate admits only reads, the operations declared `reduces_authority` and the confirmations they need, the recovery kit keeps its own ingress, and the cell's renewal and shutdown never refuse.
- Startup and shutdown run in dependency order, and a cell-wide claim whose job the shutdown kills, such as the retention sweep's, is kept until a peer takes it over when it lapses.
- Each workload has a latency budget with its measurement; the canvas proof holds a frame open and a canvas validation to theirs. *Not built yet:* an overload budget for any workload; the latency budgets of an admission at concurrency, a first token, a feed fire, a device intent and a console page; and the measurements of a feed fire and a console page.

**Why.** Correctness rests on the lease verified where the write happens, never on a member's belief that it still owns.

## 7. The screen and tinctures

Prism is one screen: everything on it is a tincture, untrusted code in a frame, except the system layer, Prism's own controls, the assistant's thread and the frames themselves.

- **The system layer** draws every grant, confirmation and credential entry above every frame, and is the one place the screen presents a consent, from Sanctum's preview; the command line shows the same preview in the terminal. *Not built yet:* unlocking the vault, and a tincture's request for a consent.
- **Frames.** Prism creates every frame under the sandbox the tincture rules derive, and a frame reaches data only under a per-open credential Sanctum mints and revokes (`Sanctum.TinctureAuth`).
- **Canvases** are the person's pages: a canvas reads only what its grant names, shows outside data only through feeds (`Opus.Feeds`), and lets what it reads leave only as controls the person sees. *Not built yet:* a canvas's read operations, a feed from a run that stays open, and telling a canvas which tinctures are open over it; it learns only the rectangles they cover.
- **Code and layout are separate**: a code change is a new version, a version that reads more asks again, and the way back from a broken canvas is outside every canvas.
- Emissary serves every tincture's files and data routes, and a public tincture runs under its own profile, never a viewer's session.

*Not built yet:* the console as tinctures, and the canvas as home; the console's pages are LiveViews beside the shell, and its vault page asks for a credential in its own form.

**Why.** The screen is where consent is given, so what confirms, consents and asks for secrets is CYFR's own code, and every other part of the screen can fail without taking those with it.

## 8. Homes, glasses and hubs

- A home is the one installation that decides for an athanor. Home, glass, hub, cell, node and door are this document's words: what a person reads, the setup pages, the command line, Prism, the README and the guides, says CYFR for the installation and Aqua for the assistant, device or browser for the glass, the CYFR you join for a hub, cluster for a cell and server for a member of it, machine or server or CYFR for a node by its sense, and sign-in method for a door, and never these words.
- Every athanor has exactly one home; a cell is several members acting as that one home on one database (§6.1). *Not built yet:* replicas and their journal, and home transfer; a node is the home of every athanor its store holds.
- The glass is the client: display, input and device keys it never exports, bound to each home separately. *Not built yet:* an application that hosts Prism, a client shell with its own home switcher, listening without a page, notices and their read state across homes, and push delivery.
- A hub is the always-on home of shared athanors and an instance that offers entries to its people. *Not built yet:* the hub as a model provider and as a standby, the governance floor, which shows every member of a group a consent that exports their contributions and lets each withhold what they authored, and a join that requires a company's single sign-on beside the person's own identity.
- Every wire between homes names its version, and CYFR has no relay.

**Why.** A decision about an athanor is made in one place, so no node acts for a home because a lease looks expired or a clock says it is lost.

## 9. People

### 9.1 Identity

An enrolled person is an identifier, the hash of the genesis of a log their own keys extend, ordered by one directory (`Sanctum.Directory`); a person who never enrolls keeps their keys, home and local devices without one. A live key at their home signs for them, an operational key rotates it, and recovery keys in a printed kit replace both (`Sanctum.Recovery`). A home reads a remote person's head fresh within a bound (`Sanctum.IdentityFreshness`); doors are sign-in methods at a relying home; restore is an entry path, not an operation. *Not built yet:* memberships and attribution by identifier, delegated work, the email door, and the mail transport it and an emailed confirmation code need.

### 9.2 Joining a home that is not your own

A person signs in at another home through the CYFR door (`Sanctum.Auth.CyfrDoor`) with an assertion their own home signs after a fresh confirmation, carried by the browser (`Sanctum.Carry`); their devices there are certified by their own home (`Sanctum.RemoteCertification`), and each home admits under its own rules.

### 9.3 Devices and fresh confirmation

Who a person is, which devices they connected and whether a change needs a fresh confirmation are three separate facts, and no client holds a rank. Everyday work needs only the session; changes to keys, devices, doors, passkeys, recovery material and credentials that outlive the session need a fresh confirmation at the deciding home (`Sanctum.Pairing`). *Not built yet:* the display and pointer-input contracts, athanor policies that add changes, and, against a copied home certifying devices, a survivor's countersignature verified at a relying home and a directory-published device anchor.

### 9.4 Communication

People talk by sharing an athanor whose home is always on; there is no messaging protocol beside it and no directory of strangers.

**Why.** The person outlives every device, key and door, so identity is a log their own keys extend, checked at each home that relies on it, never vouched for by a home or a provider.

## 10. Grants

Consented work runs unattended under its grant; a person is asked only about what no grant covers, and an uncovered external or destructive proposal is approved once, never banked.

- Component grants and standing approvals are the two kinds of grant, under one set of rules.
- A preview is typed rows bound by a digest; narrowing is validated by its owner, and widening is interactive. *Not built yet:* an instance entry's use cap on the preview's credential row.
- Every run carries the origin its admission path set, and a grant names the origins it admits.
- **A standing approval is bounded.** It ends with its lifecycle or deadline and holds to its resource constraint, and an external or destructive action never takes a standing allow.
- Every turn records the source classes it read (`Prima.Source`), and every send to an exit is held to the flows its grant declares, which `Prima.Flow` decides.
- A standing grant never stands in for a fresh confirmation. *Not built yet:* declared reads of standing approvals.

**Why.** The person decides once, on a preview that says exactly what is granted, and whatever the grant does not cover is asked about each time.

## 11. Memory

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
| Served files, frame capabilities, frame policy, canvas grammar | Compendium's tincture rules |
| Memory records and pages (*Not built yet*) | Aqua, stored by Arca |
| The layout | the person, stored by Arca |
| A contract's detail | its owning module's documentation and comments |
| The architecture | this document; the glossary in `README.md` is checked against it |

A change to a principle, a layer edge, a port or an invariant changes this document in the same change.
