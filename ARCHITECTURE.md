# CYFR architecture

This document describes the architecture CYFR is built toward: what each part owns, how the parts talk to each other, what must always hold, and why. It is written in the present tense of that end state: every sentence is the target, not evidence that the code already does it. A **Not built yet** line marks each larger part the code does not have. Which parts are built, the smaller gaps between this document and the code, and the order in which they close are recorded with the implementation work, outside this repository.

Each part's name, directory, binary, environment prefix and labels are in the [glossary in `README.md`](README.md#glossary). This document owns what each part is responsible for.

## 1. Purpose and principles

### 1.1 What CYFR is for

CYFR is a home for a person's or a group's work with AI: components an assistant can build and run, the assistant itself, files, schedules and credentials, kept on infrastructure the person controls. It is built on one idea: **a model proposes, and CYFR decides.** A model may suggest any action. Only a declared operation, admitted by one gate under a consent the person gave for exactly that action and those resources, ever runs. Credentials live in a vault no model sees; CYFR attaches a credential to a component's request, and a component holds a field's value only when its consent names that disclosure.

Three consequences shape everything below.

- **The person is the lasting thing**, not the model provider, the device or the sign-in method. Keys, devices, sign-in methods and the home machine itself can be replaced without the person losing their identity or their memberships.
- **Authority is decided where the resource lives.** Every athanor has one home, and that home admits or refuses every request about what the athanor owns.
- **Untrusted code runs outside the control plane**, isolated, and reaches only what was pinned for it.

### 1.2 Principles

- **Prompts are not permissions.** A model proposes; CYFR decides what it can reach. Every mutation is a declared operation admitted by one gate under a consent that binds to the exact action and resources shown.
- **Layers, one direction.** A module depends on its own layer or below, never above and never sideways across surfaces. The layering is a compile error where the compiler can see it and a seam test where it cannot, so a forbidden dependency is caught before it merges.
- **One owner per fact.** Every schema, policy, operation declaration, topic, protocol shape, configuration key, served-file type, frame capability and layout has one authoritative module. Everything else is derived from it and checked against it, because a fact with two definitions drifts.
- **Downward calls are direct; upward needs are ports; reactions are events.** There are exactly five ports (§4.2). Two owners whose writes must commit together join one Arca transaction through a named closure (§4.4).
- **Three guards, each with one owner.** Operations pass the Grimoire gate with Sanctum's decision. Domain rows and blobs are tenant-scoped by the actor in Arca. Security rows are read only through Sanctum.
- **Trust islands speak protocols.** An island shares pure contracts and signed, versioned wire shapes with the control plane, never a code dependency on it.
- **Fail closed.** Identity, standing, consent, ownership and catalog completeness are established before work is admitted, and a control that cannot answer refuses. The one named exception is the decision audit (§6.4), which records and never decides. Unavailable infrastructure, absent data, denied access and successful work stay distinguishable in every result.
- **Admission, not sampling.** The gate admits discrete intents: open a stream, send this, confirm. Continuous data (execution deltas, a pointer, a game loop, audio, camera frames) stays in the frame, on the bus or inside the island that produces it, under a grant the gate already admitted. A granted stream may carry audio or frames to wherever the grant names; no frame is an operation.
- **One product, one code path.** Behaviour that depends on exposure derives from whether authentication is configured, never from an edition. A phone, a small box, a kiosk and a server run the same code with different wiring.
- **Few names.** A namespace exists only when it owns state, a state machine or a trust boundary nothing else can own. There are thirteen namespaces and one role (§3). A struct is not a namespace and a page is not a domain.
- **The person is not the door.** Google, GitHub, OIDC, email and passkeys are sign-in methods registered at a relying home; none of them is the person. A person is an identifier that survives every key, device, sign-in method and home address.
- **Authority follows the resource's owner.** Whatever an athanor owns is decided at that athanor's home: membership, consent, caps, vault, confirmation. A request from another node is admitted there or refused there, never trusted because the other node vouched for it.
- **Hardware is disposable; the person and their relationships are not.** A lost device is revoked, a lost home is restored from recovery material, a lost sign-in is replaced. Starting over as a new person is the last resort, after every recovery route is gone.
- **Data goes down, words come up.** A decision module answers typed facts, decisions and reason codes. Wording, grouping and ordering belong to the surface that renders them. A surface may suggest a default the person can change; a default that decides authority when nobody chooses belongs to the module that owns the policy. A surface offers only choices a lower layer validates: every control maps to a typed input its owner checks, narrowing is accepted and widening refused, and no label promises a restriction the enforcement point does not hold.

### 1.3 What CYFR trusts

- **Trusted:** the home's own code, including the system layer that renders every consent and confirmation; the platform administrator, who on a personal install is the person; the store the home runs on; a person's passkey, and a sign-in method that proves a fresh sign-in, for fresh confirmation (§9.3); and the directory that orders an identifier's log, for serving current, consistently ordered state and nothing more (§9.1).
- **Not trusted:** models and anything they produce; components and tinctures, first-party desktops and console tinctures included; untrusted native processes; another member's session; another home, which is never believed because it vouches for something; anything a frame or a guest hands back.
- **The limits, stated.** Fresh confirmation protects against a stolen session, not against a compromised platform administrator. A consent's digest binds the exact request that was approved, so it cannot be changed afterwards, but no digest proves what a client displayed: a replaced command-line client, a modified browser or a modified home could misdescribe a request while submitting it under the person's own credentials. Replacing the home's code or the trusted client replaces the trusted system itself.
- **Recovery material is authority.** Anyone holding a current recovery kit can replace the online keys and use the surviving memberships. There is no delay or contest period. Separate live and operational keys restrict what a leaked live key can sign; sealing both at one home does not protect either from a compromise of that home. Recovery restores identity, never private data or a revoked membership.

## 2. Layers

```
L4  Trust islands   Opus (WASM engine)   Locus (untrusted native processes: builds, stdio MCP backends, perception bodies)
                    depend on Prima only; reach L1/L2 over signed, versioned protocols
                    runners and bodies have no network of their own; builds and backends have their service's

L3  Surfaces        Emissary (external protocols)   Prism (the screen)   Codex (CLI)
                    adapters over Grimoire and Sanctum.Caller; a surface never names another surface

L2  Domains         Compendium   Aqua   Crucible
                    an acyclic graph (Aqua→Crucible, Aqua→Compendium, Crucible→Compendium), facade-only

L1  Foundations     Cyfr (Host)  >  Grimoire  >  Sanctum  >  Arca
                    strict order; a lower foundation never names a higher one

L0  Prima           types, wire shapes, behaviours, pure primitives, the actor
```

The order describes dependencies. A request does not have to pass through every layer.

| Layer | May depend on | Must not know | Public surface |
|---|---|---|---|
| Prima | Jason and its rostered runtime primitives | the repo, product modules, unclassified effects | structs, behaviours, codecs, primitives started by their owners |
| Arca | Prima | Sanctum, Grimoire, Host, domains, surfaces | storage facades returning plain data; blobs; cache; leases; two providers |
| Sanctum | Prima, Arca | Grimoire, Host, domains, surfaces | its Boundary export list |
| Grimoire | Prima, Arca, Sanctum | Host, domains, surfaces | the operation and stream entries, discovery, the request log, decisions, the system provider |
| Cyfr (Host) | everything below; its composition modules may name domains and surfaces to wire them | — | boot, cell, bus, telemetry catalog, runtime configuration, platform settings, the admission roster |
| Domains | Prima, foundations, other domains' facades (acyclic) | surfaces, each other's internals | one facade module, providers, storage under Arca |
| Surfaces | Prima, foundations, domain facades for reads | other surfaces, domain internals | plugs, routers, controllers, LiveViews, the frame manager, CLI commands |
| Trust islands | Prima | everything else | a protocol implementation |

**Placement.** A new concern goes in the lowest layer whose neighbours do not need it; if two foundations need it, it goes in Prima. A domain owns its state machine, one facade and its providers; a surface owns adapters only.

Two edges the diagram does not draw, both declared in the table: Host's composition modules (`Cyfr.Application`, `CyfrWeb.Endpoint`, `CyfrWeb.Router`) name domains and surfaces to wire them, and a surface reads domain facades directly for the screen's trusted reads (§7) beside dispatching through the gate. No other module copies either edge.

Emissary is the one surface that also implements a foundation port (§4.2). Its protocol adapters are a surface and its outbound MCP integration implements the proxy port; it is one name for economy of vocabulary, not a precedent for another surface implementing a port. Nothing names Emissary except Host's wiring.

## 3. Modules

### Prima: shared contracts

Owns every shape two sides must agree on and every primitive a trust island needs: path safety, digests, IDs, JSON and canonical JSON, component references, limits, authority data, the actor, operation and argument declarations, the provider, host and worker behaviours, execution deltas and outcomes, the signed-message envelope and every signing domain, the builder, backends, keeper and runner protocols, the MCP codec, the refusal and guest-error shapes, the component ABI, the pure network policy, the tincture frame, card and stream shapes, the layout document, the device protocol, and the identity, device-certificate, confirmation and sign-in carry shapes.

- It starts no application process and holds no persistence or product policy. Its runtime primitives are exactly Boot, RateLimiter, LoggerContext, JsonFormatter, Slots and Caps, each with a fixed effect and owner.
- A module lives here only if a wire shape, a vector file, a trust island, a Go, Python or JavaScript consumer, or two apps above Prima reference it.
- The network policy is pure: URL parsing, metadata refusal, private-address policy, pinned options, origin comparison, the credential headers a cross-origin hop strips, and domain matching. Resolution and transport are Sanctum's.
- Every protocol carries an explicit version and has one vector file consumed by a test on every side, in every language.

### Arca: persistence

Owns the repo, every schema, query and transaction, blobs and path translation, the cache, leases and reservations, the cell lease row, job claims and rate windows, retention kinds, storage revisions, build records, the write-behind sink, the durable outbox (§4.3), platform-settings rows, layout documents, and two doors: the records provider and the file provider.

- Tenant-facing functions take the actor first. A deliberately unscoped query carries `arca:unscoped-ok` with its reason; a direct filesystem call fits a documented `arca:bypass-ok` group. File and blob operations go through the storage abstraction, which enforces path translation and guest-visible scopes, so every adapter behaves the same.
- Functions return plain maps or Prima structs, never schemas or changesets.
- Nothing is broadcast inside a transaction; functions return committed change data and the caller emits it.
- Caps are checked at the mutating chokepoint through the `Prima.Caps` port.
- Locking is a conditional write. Row locks serve only multi-row transitions, through Arca's helpers, and nothing above Arca names the database adapter. SQLite and PostgreSQL behave the same.
- Each athanor's storage holds `components/`, `aqua/`, `threads/`, `notes/`, `memory/`, `payloads/` and `data/`; `notes/` and `memory/` are host-only, with no guest scope.

### Sanctum: decisions

Owns identity, sessions, doors, API keys, membership and tenancy, the caller context, authority and its transitions, consent and its proofs, the vault, the instance's entries, and credential attachment and disclosure, policy logging, caps policy, provisioning, the control plane's own network resolution and pinned transport, paired clients and their standing, passkeys, the changes that need fresh confirmation, the credentials tinctures are served under, the person's keys and recovery, the directory's decisions, device certificates and pending confirmations.

- It uses no Ecto. It is the only reader of security rows, and a seam test refuses a reader outside it.
- Its upward needs are its two ports (§4.2). Its internal strategies (consent proof storage, sign-in methods) are behaviours it declares and implements itself, selected by configuration.
- It emits telemetry for every standing change and never broadcasts. Every standing change drops the cached caller context for the affected credentials before returning.

### Grimoire: the operation table and the gate

Owns the operation table, the gate, argument casting, dispatch on the external and in-chain planes, stream admission, replay and uncertainty semantics, discovery, the request log, running tasks, the decision record and the system provider.

- There is one entry for operations on each plane and one for streams. An operation that is undeclared, unannotated or called on the wrong plane is denied; boot refuses a partial table; every provider module is on the configured roster.
- **Streams are declared where operations are.** A provider declares the streams it offers beside its operations. The gate admits a stream once, records it once and answers with a bounded grant; the delivery owner above Grimoire keeps enforcing it and closes the stream on a standing change, the grant's deadline, a suspended frame, overflow or failed revalidation. A reconnect is a new admission.
- Every admission makes one decision record (§6.4). Ownership is checked downward, through Arca, before dispatch.
- Grimoire names no surface, no Host module and no bus; the delivery owner resolves a granted topic.

### Cyfr (Host): the machine

Owns supervision, boot, the cell claim and renewal, the bus and its topic roster, telemetry and its bridge, runtime configuration and platform settings, `Cyfr.Boundaries`, the endpoint, the admission roster, and the composition root that installs the five ports.

- Ordinary Host modules name no domain or surface; `Cyfr.Application`, `CyfrWeb.Endpoint` and `CyfrWeb.Router` are the composition boundaries. Host keeps the listeners, the endpoint and the composition that wires them; every adapter behind the endpoint is Emissary's or Prism's.
- **The admission roster** names every path an intent enters by: the HTTP endpoint through the gate, the HostAPI listener's child admission through Crucible, the scheduler's fire, the device channel (§9.3), and, on a device, a local socket and a compositor or physical jack, which appears as a body and never as a namespace. A path not on the roster admits nothing. Each admission point that decides for itself records its decision. *Not built yet:* the local socket and the compositor, which the roster declares and defers, so they admit nothing.
- **Configuration has two planes.** A deployment variable is one the boot needs before it can read a row, or one that decides how the box is reachable: secrets and keys, database and storage backends, bind, port, host, proxy trust, allowed origins, private egress targets, sign-in providers, platform administrators, cluster roles, island URLs and keys, registry hosts, the public URL. Everything else is a platform setting, declared once in Host's settings roster and read through one accessor (§6.8).

### Compendium: components

Owns component kinds, manifests, the registry, activation, provenance, scaffolding, the agent index, build orchestration over Locus, the tincture rules, and the component, registry, source, build and AQUA-file providers.

- **The tincture rules are one module**: the file types a tincture may serve, the frame capabilities a manifest may declare, the map from granted capabilities to the frame's sandbox and permissions (never `allow-same-origin`, top navigation or popups), the derivation of each entry page's Content-Security-Policy from its declaration, the templates, the lockfile rule for a built tincture, and the grammar for cards, streams and system actions. The publish check, the screen and the served headers all read it; nothing writes a sandbox token or CSP directive anywhere else.
- **Signed pulls.** A pull that requires verification is verified against the manifest digest that was stored; the signature tool's verified digest must equal it, and an answer that names no signer identity is not a verification. A shipped version is immutable: a change is a new version.

### Aqua: the assistant

Owns threads, rooms, direct threads, turns and their loop, approvals and standing approvals (§10), notes, attachments, agent configuration, model orchestration and memory (§11).

- **Model orchestration has one plane.** A small or local model is an ordinary provider under the same grant and the same turn, chosen for a step by Aqua's model policy. There is no second pipeline beside the turn.
- **Chat is Aqua's state and Prism's trusted surface.** Threads, rooms, a two-person direct thread, whether a line starts the assistant, following, and saying a line aloud into a room are Aqua state machines. Prism draws them beside the desktop, not as tinctures, so a broken desktop never takes the assistant with it. A tincture reaches a thread only through declared operations and streams.
- Turn transitions persist through their owning transaction and broadcast committed state.

### Crucible: execution

Owns admission of executions, attempts and assignments, accounting, output masking, terminal writes, the HostAPI server, the WorkerAPI client, guest storage, guest egress (§5.6) and the attached request (§5.5), schedules and card refresh, and the execution and schedule providers.

- A card is refreshed by `card.refresh`, a write operation admitted through the gate that runs the card tincture's execution under its grant, as the person who placed the card, charged to that athanor; or once as a schedule bound to the card's declared stream. Returning display data does not make it a read. The desktop chooses only which placed card to refresh.

### Emissary: external application protocols

Owns CYFR's external application protocol adapters and the proxy port's outbound MCP integration. Each adapter carries declared operations and streams through the gate and adds no domain meaning; what a fact means and how long it is kept belong to its owner.

- MCP in both directions: the router, sessions, streaming, subscriptions and progress, and external MCP servers over HTTP or through Locus's backends service.
- The HTTP API and its event streams, health, inbound webhooks, and the OAuth callback that completes a vault credential.
- Tinctures' served files and their frames' data routes (§7).
- The directory's and restore's HTTP endpoints (§9.1), the renewal of a certificate the person's home issued for a device at another home (§9.2), and the device channel (§9.3).

A component's egress stays Crucible's (§5.6), the control plane's own outbound calls stay with their owner through Sanctum's transport, and each island's protocol stays between that island and its owner.

### Prism: the screen

Owns the system layer, the frame manager, the shell, the server side of the desktop and of the console's tinctures (§7), and the pages and callbacks of browser sign-in, passkey ceremonies included. It authenticates through `Sanctum.Caller`, dispatches mutations and stream opens through the gate, and reads domain facades directly for the shell's own trusted reads.

### Codex: the command line

The `cyfr` binary. It speaks to Emissary over MCP with an API key or a session; its operation catalog is generated from the gate's table.

### Opus: the WASM engine

A service holding a pool of OS runners under the keeper, each execution subtree in one runner. **A runner has no network**: its host calls and its pinned fetches leave through the service over the keeper's control channel, bound to the attempt the runner was assigned. The WASM sandbox, the uid, the cgroup and the network namespace are four independent bounds.

### Locus: untrusted native processes

Where untrusted native processes run, under the keeper and nowhere else: builds and stdio MCP backends, each its own signed HTTP service with its own key, and on a device perception bodies (a camera, a radio, a HID jack) as a third service over the device protocol. A build or a backend reaches only what its service's network allows and holds no credential the control plane did not inject. *Not built yet:* perception bodies.

### keeper: the privileged companion

A role, not a namespace: the Go binary `cyfr-keeper`, the entrypoint of every island image. It pools uids, stages private homes, relays a control channel, bounds each child in a cgroup of its own, places each runner and each body in a network namespace with no route but the relay, and kills and scrubs on release. It holds exactly `SETUID`, `SETGID` and `KILL`, never `CAP_SYS_ADMIN` in the initial namespace, and refuses to serve with anything else. Every island refuses to serve without it.

### Apps and releases

`prima`, `arca` and `sanctum` are Mix apps of their own because Sanctum's licence boundary is an application directory and Sanctum needs Arca beneath it; `cyfr` hosts Grimoire, Host, every domain and every surface under Boundary declarations. `opus` and `locus` depend on `prima` alone. `keeper` and `codex` are Go. The `cyfr` release starts prima, arca, sanctum and cyfr; the `opus` and `locus` releases start prima and themselves under the keeper.

## 4. How modules talk

### 4.1 Channels

| Between | Channel | Rule |
|---|---|---|
| A module and one below it | A direct facade call, context or actor first | Returns facts, decisions and reason codes |
| A lower module needing something from above | One of the five ports, installed by Host at boot | A sixth port is an architecture change |
| Two domains | Facade calls, in one direction only | Never another domain's internals |
| Two owners, one commit | Arca's transaction with the higher owner's named closure (§4.4) | Each owner's code touches only its own rows |
| After a commit | An event on the bus | Reactions only; an event never grants authority |
| A surface acting | A declared operation through the gate, decided by Sanctum | Prism, Codex and Emissary call the same operation |
| A surface reading | Domain facades under the caller's context, for the shell's trusted reads | Never a bridge that exposes a facade to a frame |
| A trust island and the control plane | A signed, versioned protocol whose shapes live in Prima | One vector file per protocol, tested on every side |

Foundations below Host emit telemetry; Host's bridge is the one place telemetry becomes a bus message.

### 4.2 The five ports

| Upward need | Declared by | Implemented by |
|---|---|---|
| The storage and counted cap decision (`Prima.Caps`) | Prima | Sanctum |
| Consent's view of the operation table (`Sanctum.Grimoire`) | Sanctum | Grimoire |
| Component facts for consent (`Sanctum.Consent.Components`) | Sanctum | Compendium |
| Proxied tool resolution (`Grimoire.Proxy`) | Grimoire | Emissary's external half |
| Where a storage unit's bytes live (`Arca.Storage.UnitLocator`) | Arca | Compendium's component and AQUA path grammars |

Host writes each implementation at boot and the declaring module reads it; an uninstalled port raises. The same mechanism carries **installed data** downward, such as the settings roster's defaults: a plain value a lower layer reads, never a call it makes, so it is not a port. A frame's capabilities, a paired client's standing and a tincture's grant are facts the catalog and Sanctum already hold, so the screen and devices add no port. `Prima.Provider`, `Prima.HostAPI`, `Prima.WorkerAPI` and `Prima.Device` are contracts their implementers declare, not ports.

### 4.3 Events

Topics are declared once in `Cyfr.Bus` with their tenant prefix rule, and each carries one payload struct declared beside it. A stream a tincture may declare names the topic it rides, and Host checks at boot that the topic exists. A grantable topic carries discrete facts, never samples. Broadcast follows commit. Execution deltas are the one exception: they are buffered and broadcast with sequence numbers before the write-behind sink persists them.

A subscriber that reconnects is admitted afresh (§3, Grimoire), then the stream replays or refreshes, as it declares. A replaying stream answers the retained events after the subscriber's last position, within a bounded window, each under a stable identifier the subscriber deduplicates by; a refreshing stream, or a position older than the window, answers current state. Delivery may repeat, and nothing is promised that the stream does not retain. *Not built yet:* a declared replay or refresh for any stream but the execution events, which replay today.

A reaction that must survive a crash starts from an Arca outbox record committed with the source transition. The record identifies the source, revision, tenant and event kind through a Prima shape; it names no consumer. A consumer keeps its own durable receipt and derived work, deduplicates by source and revision, and rechecks authority before reading or publishing. Delivery may repeat; the bus only wakes the consumer. Crucible emits its own completion fact and never writes Aqua's memory rows. *Not built yet:* the durable outbox and its consumers; schedule notes are currently best effort.

### 4.4 Transactions across owners

A write two owners must commit together is one Arca transaction, and the higher owner's part enters it as a named closure the owner passes in: `verify:` for a policy check that must hold at commit, `also:` for a row the owner writes beside Arca's, `reserve:` for a reservation the owner takes against a cap it holds. Arca owns the transaction, its lock order and its retry, never names the owner, and is not a general callback dispatcher: each closure is declared by the Arca function that takes it. A closure reads and writes only its owner's rows through Arca, makes no network call, publishes nothing, and answers ok or a typed refusal that rolls the whole transaction back. Broadcast follows the commit, by the caller. A fenced write keeps its fence inside the same transaction. *Not built yet:* `reserve:`; `verify:` and `also:` are in use today.

### 4.5 Errors and words

Conditions a caller classifies are typed tuples; programmer errors raise. Refusals are `%Prima.Refusal{}` with a closed class table, each surface owns its rendering, and a guest sees only the `Prima.GuestError` projection. A crash past a step that is not replay-safe returns `:uncertain`, never `:failed`. A decision module answers typed reasons; the words are the surface's, with a default beside the code in Prima for codes that cross a wire.

### 4.6 Adding a capability

The architecture grows through these seams, not through new layers:

- **A new effect** is a declared operation in its owning domain's provider, admitted by the gate under Sanctum's decision; one that changes keys, devices or other sensitive state joins the list of changes Sanctum requires fresh confirmation for (§9.3).
- **A new limit** is a cap of its own meaning held by Sanctum (§5.8); when it must commit with a domain row it is taken inside Arca's transaction through a `reserve:` closure (§4.4).
- **A new credential kind** is a vault entry with its destination and attach rule, disclosed only where its consent says so; material that must never leave is used through Sanctum's signing (§5.5).
- **A new outside service** is reached one of three ways: by a component, through a catalyst over pinned egress under its consent; as an external MCP server, through Emissary; or by the control plane itself, through the owning module and Sanctum's pinned transport, never on a guest's behalf. Its wire is a versioned Prima shape with one vector file.
- **A new record** is an actor-scoped Arca row owned by the domain that keeps it; a record about authority is a security row Sanctum owns.

Only a need none of these covers, a sixth port, a new layer edge or a new namespace, is an architecture change.

## 5. Tenancy, authority and isolation

**The person decides; Sanctum validates, records and checks.** A person makes each consent decision in a trusted surface (§7). Sanctum validates that decision against who is making it and what may be granted, records it, and checks every later request against it; it is not in the path of every byte. The gate admits a discrete intent under Sanctum's decision, and the place that releases data or performs the effect enforces what was admitted: the vault when it dispenses, Crucible at egress, the storage boundary at each path, the delivery owner on each stream. A granted stream never asks Sanctum about each sample; its owner enforces the grant's scope, expiry and revocation.

### 5.1 Tenancy

- **The athanor is the tenancy unit**, a person's own or a group's. There is no organization or project above it and no second word for it. Membership conveys the same authority to every active member; platform administration is a capability, not a wider tenant scope.
- **Tenant identity comes from the authenticated actor.** A guest-supplied path or argument never selects a tenant, and an unresolved identity is a refusal, never a placeholder.
- **Ownership travels** with rows, relationships, blobs, events and cache keys. A cross-tenant operation names its system responsibility or an authorized change of focus. Caches, indexes and derived labels obey the boundaries of the rows they come from, and a cache never creates or widens authority.
- **A platform administrator holds a capability over the instance, not a seat**: they enter no athanor they are not a member of, and the instance's own resources are offered to athanors, never reached into.
- **Nothing lands in an athanor its members did not accept**: a file sent to a person is an offer until they accept it into their own tree.
- **The actor** is a Prima struct. `Sanctum.Context` carries it with authority, focus and credentials; Arca and the bus accept the actor and never the context.

### 5.2 Identity and standing

Identity and standing are established once, at the authentication boundary, from stored identities; admission to the server precedes session creation. A long-lived context revalidates its stored session and standing before protected work, within a bounded cache lifetime; notifications speed up invalidation but are never the only guard. A frame's credential and a paired client's standing are revalidated on the same rule.

### 5.3 One gate

The screen, the command line, the wire and the assistant share one operation declaration and one gate; an undeclared operation is denied. External callers and calls inside a running chain are separate planes, each admitted for what it is declared for.

### 5.4 Consent

- A consent binds to the exact action and resources shown in its preview: a component's needs, a tincture's frame capabilities, system actions, streams, cards and placement. A version that asks for more asks again, and a layout edit never widens a grant. Shape, decision, policy, activation and credential-binding digests keep distinct meanings.
- Who may consent is decided by how the caller authenticated, not by what it holds: an interactive session or a paired client may, a key only for the one exact commit its capability names, and nothing on the guest plane, a tincture session, a webhook or a schedule may. Granting a component more than its author declared is always interactive.
- Human approval unblocks an action that is already authorized and grants nothing more. A child execution holds only authority derived from its parent. Entering a guest context is irreversible.
- A grant's structured preview, narrowing, origin and lifetime are §10's.

### 5.5 Credentials

- **An entry is bound to its destination**: a scheme (`https` unless it states `http`), an optional port, hosts in the egress domain grammar (§5.6), and the methods and path prefixes it may be sent with. Its binding digest covers the destination, so changing it asks every consent that binds the entry again, and an OAuth entry's endpoints are fixed when it is created. A request, a server definition or a refresh that would carry the material anywhere else is refused before anything is unsealed, and an http server definition names only its own athanor's entries whose destination matches its URL. The consuming component's egress grant is a second, independent bound.
- **CYFR attaches the credential; the component never holds it.** A guest names the need its request uses and carries no credential header. Crucible, under Sanctum's decision, pins the request once under the guest's authority through the same pin a guest fetch gets (§5.6), attaches the credential by the need's attach rule, connects to that pinned address following no redirect and with no retry, masks the attached value out of the answer, and returns the answer to the runner sealed. No component, runner or worker service receives the credential, and the attached value joins the attempt's masking set.
- **A disclosure is named on the consent.** An entry is attach-only unless it was created or rebound disclosed. A disclosure, named on the consent or, for a stdio backend, on its server definition, is the only way a field reaches a guest, an OAuth token reaches a guest, or a value reaches a stdio backend's environment, including for integrations configured interactively. A projection names its fields or scopes; an edge that names none is corrupt and dispenses nothing, and a field the entry lacks refuses the whole resolution.
- **An OAuth projection narrower than its entry** is dispensed only by a refresh the provider is shown to attenuate, and is otherwise refused, never served the entry's broader token.
- **An instance entry is the instance's**, not an athanor's: the platform administrator enters it, and the instance offers it to people under an audience (everyone, or listed people), a component policy and a counted cap (§5.8). The component policy is `any` by default, admitting any consented component, or `shipped`, admitting only an unmodified shipped component, checked when a consent binds the entry and at each request. Its destination names methods and paths under either policy. An instance entry is attach-only: it is never disclosed and never named by a definition whose URL a member chose. Revoking it returns every consent that binds it, in every athanor, to needing consent again, within §6.6's bounds.
- **A publisher's provided configuration is public.** Values a publisher provides in an app's manifest for a dependency's need are part of the consent's shape and are attached and disclosed alike.
- **Keys that never leave.** A credential whose material must never leave the vault, a signing key for example, is used only through Sanctum signing exactly what an admitted operation fixed. A component receives the signature, never the key, and no projection can name the key itself. *Not built yet:* Sanctum signing with a vault-held key; no operation signs with one today.
- Every output, failure message and streamed chunk is masked against the attempt's secret values in their raw and common encoded forms. Masking is defence in depth against accidental disclosure; the projection and the egress bounds are what stop a malicious guest. Logs are redacted by key.
- Nothing a person types into a frame is ever a credential: entering or rotating a secret is a trusted flow the system layer draws (§7), and the system layer is the only place CYFR asks for one.

### 5.6 Egress

- **Guest egress is a HostAPI operation.** A guest submits a URL and Crucible pins it under the attempt's admitted authority, in order: the host must match the authority's domains and a redirect must stay on the origin of the pin it follows, before any lookup, so a refused host is never resolved; then the host resolves; then a metadata address is refused whatever the policy; then a private address is allowed only under the authority's private ranges. Every refusal is a recorded denial. The connection goes to the pinned address with the original TLS and host identity, every redirect is pinned again, and credential headers are stripped on a cross-origin hop.
- The control plane's own outbound calls follow the same validation and pinning, through Sanctum. The deployment's private egress targets never apply to a guest.

### 5.7 Isolation of untrusted processes

Untrusted builds and backend processes run isolated from the control plane and from each other: an explicit child environment, restricted privileges, bounded resources and complete cleanup before an identity or workspace is reused. A runner and a body resolve no name and hold no route. Attempt bodies and answers cross the network sealed and signed; a listener refuses an unknown wire version before it reads the body, and a host call is verified for signature, window, generation, member and nonce.

### 5.8 Separate meanings

Resource limits, platform ceilings, depth caps and shared invocation budgets are separate meanings, and a new kind of budget is a cap of its own meaning beside them, never folded into one. What zero, absence, a default, a charge or a release means is stated by each one's own contract. An instance entry's use cap is a cap of its own meaning, counted in requests attached per person and in total each day, and distinct from any spend budget counted in currency.

## 6. Ownership, state and reliability

### 6.1 Members and the cell lease

Each control-plane member owns its slot through a database lease, with a generation of its own; a peer joining invalidates no healthy member's slot. Host calls bind to the member that issued them. **A stale owner admits no work, dispenses no credential, emits no result and overwrites no successor's state.** A cached view of ownership is only a fast refusal; the guarantee is verified live in the transaction that writes.

### 6.2 Boot and standing transitions

Security reconciliation of the platform administrators must succeed under the member's live lease before any admission path opens; a failed or stalled reconciliation refuses the boot, and optional seeding is separately best-effort. Deny, allow, archive and reopen commit their session, key, derived-token, tincture-credential and pairing retirement atomically with the transition. Leaving or being removed from one athanor retires that membership, the person's clients and certificates for it and the sessions bound to it in one transition.

### 6.3 Publication

Two kinds, named apart. **Unit publication** stages a component or AQUA unit under a revision prefix, commits its pointer, then places its bytes at the served path. **Fenced publication** is for a row or document owned by the host that a stale member must not write: content is staged immutable, and the reference commits only if the writer's live ownership, verified in the transaction, and the resource revision it read both still hold. Three numbers are kept apart: the **resource revision** (two healthy members editing one resource conflict on it), the **member generation** (ownership), and the lease row's own **fence** (a write token for the lease row alone, never a publication's identity). Layout documents, schedule outcomes and provisioning fills publish fenced.

### 6.4 Decision audit

The gate appends one decision before dispatch and one completion after, each under a small database budget. The audit never decides: a lost write is a catalogued event with an operator counter, and the operation's result stands. Admission is admitted or refused; completion is succeeded, failed, cancelled or uncertain; a missing completion is unknown, never success. A stream open is one decision; the frames it carries are none.

Audit traffic cannot consume the capacity needed to renew ownership. Audit writers and their waits are bounded, overload is observable, and any queue introduced to protect renewal has a fixed capacity. Batching or dropping a class of decisions changes this contract and requires a measured design change; best-effort persistence does not make a missing record evidence of success.

### 6.5 Attempts and outcomes

An admitted guest holds a durable attempt generation, and its discrete effects and completion are fenced against it. A crash past a step that is not replay-safe leaves an explicit uncertain outcome, and a possibly completed side effect is replayed only under a contract that proves replay safe. Every exit path, timeout, cancellation, process death and loss of ownership included, releases resources and stops dependents in dependency order. A replay-protected endpoint refuses with `unavailable` when its store cannot answer.

### 6.6 Revocation bounds

A new admission sees a standing or credential change at once on the member that committed it and within the caller-cache lifetime elsewhere; an open stream closes within the same bound; an asset fetch is refused at its next request, and bytes a browser already holds are not recalled; work already admitted runs to its recorded outcome under its attempt's fence. Nothing is promised "at once" across members. When the store cannot answer, admission refuses.

### 6.7 Schema

Until the first tagged release the one baseline migration is the schema, and a changed schema rebuilds the database. From the first release a schema change is a dated migration after the baseline, the fingerprint names the applied set, and a refusal names the migration to run. A cell upgrades with every member stopped, so no two code versions ever read one bus payload. Tenant constraints and fingerprint validation hold on both database adapters.

### 6.8 Configuration and settings

Configuration is parsed explicitly and an invalid security-relevant value is refused; compile-time and runtime configuration agree. A platform setting resolves from the environment if set, then the stored row, then the code default; an unreadable store refuses the boot; every member converges within the accessor's cache bound, and divergence is visible, never silent. Each release refuses a variable under its own prefix that its roster does not declare.

### 6.9 Backup, runtime and budgets

- A cell's backup is the database, the storage root, the keyring and the deployment file, copied while the cell is stopped, and a scripted round trip proves a restore.
- Arca and Sanctum start before Cyfr. Host's infrastructure tier restarts in order, so a restart before the gate reruns security reconciliation first; every long-running child states its shutdown; shutdown drains ingress, stops dependents in order, releases claims while Arca is available, except the cell-wide `regrant_notice` claim, which a member keeps through its shutdown as the retention sweep's is kept and a peer takes over when it lapses, and stops the repo last.
- Each workload has a stated latency and overload budget with its measurement: an admission at concurrency, a first token, a frame open, a card refresh, a device intent, a console page whose reads are operations.
- The endpoint, the root router and the shared helpers are Host's; every error body renders through one renderer per surface.

## 7. The screen and tinctures

**Prism is one screen, not a sitemap.** Everything on it is a tincture except the system layer, the assistant's thread and the frames themselves.

- **Layers, bottom to top:** the desktop (one tincture, full screen, chosen by the person), apps opened into the slots the desktop names, floating tinctures the person placed with permission beside the assistant's panel, and the **system layer** (grant, fresh confirmation, unlock, sign-in, credential entry, pairing, recovery material, safe mode), which Prism alone draws in the browser's top layer after leaving fullscreen and pointer lock, with every frame hidden and inert, so nothing covers it. Pointer lock carries one recorded limitation: no document can release a lock another frame holds, so a frame granted pointer lock can take the pointer back over a prompt while it holds its own fresh activation. The frame stays hidden and inert, focus stays in the prompt, Escape frees the pointer, and nothing the frame does confirms or dismisses the prompt.
- **Prism creates every frame.** It sets the sandbox, places, freezes and discards frames, and is the only peer a frame's SDK talks to. A tincture never parents another or makes itself float; layers cannot see each other's content, and a card is the one thing a tincture shares with the desktop.
- **A frame is sandboxed with an opaque origin**, derived from the tincture rules. Its only connections are the endpoint and the origins its manifest declares, and its only scripts, styles and workers come from the site origin. Its data requests authenticate a per-open credential and nothing else, never a session cookie; shell messages are bound to the channel Prism handed that frame. The CSP guarantees the serving origin; which bytes of that origin answer is the credential's guarantee. A frame can draw something that looks like the system layer, but it cannot confirm anything, because confirmation is an operation it cannot call.
- **The sandbox isolates a frame's code, not the data handed to it.** A frame may navigate itself within the site, and it may hand its own credential to anyone, which is bounded delegation until suspension, expiry or revocation. Whatever a frame is given is disclosed to it.
- **The per-open credential** is Sanctum's: minted when Prism opens a frame, bound to the person, the version digest, the grant revision and the frame, suspended and resumed with the frame, revoked with it and with every standing transition, and bounded by its own deadline, which never outlasts the session or key it was minted under. **The asset credential** serves a private tincture's files for one person, one version and one window, so a reopen inside the window is served from the browser's cache; the window never outlasts its source session or key, and the credential is refused at the next request once its source session or key is retired.
- **Code and layout are separate.** The layout (which tinctures sit where, at what size) is the person's, stored in Arca; editing it can only arrange, and a code change is a new version. **The desktop reaches nothing of its own.** Its grant is layout, discovery, opening and the cards it draws; it declares no connect origin, no egress and no component dependency, so it cannot join other tinctures' card data to a way out. Because a frame can still navigate itself, whatever a card discloses to one desktop another publisher's desktop could export, and installing one shows that disclosure in its grant.
- **Lifecycle.** Hiding is visual; stopping is the browser's; suspending is the server's: a hidden frame without a background grant has its credential suspended, so it fires no action and receives no stream. A background grant (audio, a call, a timer) is consented like any capability. Safe mode runs with no tincture at all.
- **The SDK** talks to Prism for shell verbs (open, close, title, ready, credential) and to Emissary's data routes, under the per-open credential, for data: declared components, system actions and streams.
- **The console is a hybrid while it migrates.** The desktop is home, and console pages that are not yet tinctures open from the shell's drawer as trusted LiveViews under the caller's context. A page becomes a tincture only once the tincture has the page's whole function, using operations a provider already declares. *Not built yet:* the console as tinctures; the vault tincture ships beside the console's vault page.
- **Consent is presented only by the system layer.** A tincture, a replaced desktop and the console's own tinctures included, may ask for a consent through a bounded request to the shell, but cannot provide the authoritative consent screen or approve it: the system layer obtains the preview from Sanctum, draws it where nothing covers it, groups it for the person, and submits the person's exact choices, never a category. The asking frame learns only the outcome and receives no session credential. Prism's own trusted views raise the same prompt rather than drawing a consent inline, since only the system layer is never covered. Customizing the desktop changes nothing about how a consent is shown or decided. The command line shows the same preview in the terminal. *Not built yet:* a tincture's request for a consent.
- **Serving.** Emissary serves every tincture's files and its frames' data routes under the tincture rules and Sanctum's credentials; Prism creates and manages the frames. **Public tinctures** are served on the site origin under the same derived CSP and sandbox, by a headless node too; a public invoke runs under the tincture's public profile, never a viewer's session.

## 8. Homes, glasses and hubs

- **Every athanor has exactly one home.** A node holds a store and a set of athanors, and for each it is the home, a replica, or nothing. A single server is the case where every home coincides on one node.
- **A cell** is several members sharing one database and acting as one home: the slot lease and member generation are the only ownership, a dead member's slot expires and is taken, and there is no replica and no handover.
- **The glass** is the client: a browser or an application that hosts Prism. It owns display, input, device keys it never exports and the certificates that name them; it holds no athanor store, vault or person key. Each home serves its own Prism, including its LiveViews and system layer, in an isolated tab or view at that home's origin. The assistant's loop, memory, jobs and vault run at that home. A client is enrolled with, bound to and revoked from each home independently, and every request is bound to one home and one athanor, so switching tabs never redirects a running action. A client that hosts Prism adds no domain surface. A device's own permission for a camera, a microphone or a location, the browser's or the operating system's, is a separate boundary no CYFR grant overrides.
- **Tabs and saved homes belong to the client.** The list lives only on that device, outside every home's pages and origin storage; homes neither read it nor synchronize or back it up. A new device starts with no saved homes: the person adds an address or invitation and authenticates at each home independently. An entry is a navigation hint, never membership or authority, and removing it revokes neither. The client keeps its tab controls available when a home is unreachable and identifies the home whose page is active; no home page can draw those controls or enumerate the other tabs. The same contract holds for a browser and for a dedicated client shell, including one on a device that also runs a home. Browser tabs and local, unsynchronized bookmarks provide it today. *Not built yet:* the dedicated client shell and its local switcher.
- **A client listens without a page.** A client subscribes through Emissary to the streams each home granted it, whichever tab is visible and under the paired client's standing, and after reconnecting each stream replays or refreshes as it declares (§4.3). Each home sees only its own subscriptions. A notice names its home and opens that home's Prism, whose system layer asks for anything that needs a decision; a notice confirms nothing and grants nothing. A home may wake a sleeping device through the platform's push service with a notice that carries no athanor data; the push subscription belongs to the paired client and ends with it. The client combines notices from several homes and keeps its own read state. *Not built yet:* the client's subscriptions beyond the streams a paired glass receives over its device channel, and push delivery.
- **A hub** is a CYFR node with up to three roles: the always-on home of shared athanors (a household's, a team's, a pair's), an instance whose administrator offers entries to the people on it, and, for a person whose home is elsewhere, a model provider their assistant reaches as an ordinary catalyst over pinned egress (*Not built yet*), and, when configured, the standby of a member's personal athanor. Joining a household copies nothing personal to the hub, and membership and provider are two separate relations.
- **Governance among equals.** Every active member has the same authority. Control inside a household or organization is which athanors a person belongs to, each athanor's caps and policy, and platform administration of the hub. Organization rules are enforced at the shared athanor's home. A company's single sign-on is a fact about employment, orthogonal to identity; a join may require both.
- **Replicas** apply the home's journal and serve reads under the client's standing as last journaled; they admit nothing protected except the one succession operation. A replica or client out of contact for longer than the session-freshness bound shows no further athanor data until it reconnects. A person away from the home with only a replica can read, not act. A replica's second copy of tenant data, sealed vault rows included, is protected by volume encryption and by pairing and remote revocation. *Not built yet:* replicas and the journal.
- **Home transfer.** An athanor has one home at a time, recorded in its store and never decided by a clock. A **home epoch**, raised by every transfer, is a third counter beside member generation and resource revision. No replica promotes itself because a lease looks expired; a transfer has one arbiter, the old home's store; a reachable old home is fenced before the new one admits protected work; a lost home is declared lost by a fresh confirmation that raises the epoch, and a partitioned old home keeps acting until it reconnects, sees the higher epoch and fences itself. Work it committed after the last journaled position returns as a conflict, never applied. *Not built yet:* home transfer.

## 9. People

### 9.1 Identity

- **The identifier** is the hash of the genesis entry of the person's log and never changes. Memberships, thread attribution and shared spaces reference it. It proves who someone is; it grants no membership anywhere. A home records whether the person's keys are **local** (held here) or **remote** (held at another home that admitted them through the CYFR door), and never infers this from the door last used.
- **Three keys, three meanings.** The **live key** is held at the person's home, sealed to the person and never in an athanor's vault; it signs assertions for doors and device certificates, and the intents delegated work will carry to other homes (*Not built yet:* delegated work and its signed intent). The **operational key**, also at home and used rarely, rotates the live key. **Recovery keys** are held away from the home, as a printed kit, and replace both online keys without their cooperation. The online keys can never change the recovery set; only an authorized recovery can.
- **The log** is append-only; each entry names the previous one and is signed by a key the previous entry authorized. Its kinds are genesis, rotate and recover. A recovery request is signed over the protocol version, the identifier, the directory that orders it, the new keys, the recovery-policy revision it expects and a request id, so it authorizes that identifier alone; a verifier checks it against the recovery keys the chain authorized at the preceding entry. A recovery never moves the identifier to another directory.
- **One directory orders each identifier.** It serializes updates: a rotation names the head it extends; a recovery is applied atomically against whatever the current online state is and is never refused because online state moved; an answered request id returns its recorded outcome. No clock takes part in ordering, so the owner never has to win a race against a thief's rotations. The directory holds only public keys, the recovery policy and the log; it publishes no home address or saved-home list. It is trusted to serve current, consistently ordered state, and signatures make forgery impossible; a dishonest directory could withhold an update or keep answering an old, valid head as current, and nothing detects that. Freshness bounds how long a home caches an honest answer, not what a dishonest directory can do. Any CYFR node can serve as a directory; the deployment chooses one explicitly for enrolling its local people, and mirrors serve history without accepting writes. A relying home resolves a remote person at the directory named by that person's genesis: it verifies the genesis hashes to the presented identifier before contacting the embedded URL over pinned transport. A genesis is a locator and a trust binding, never evidence of membership or current authority. Joining does not require the homes to enroll at the same directory. Public routes bound registration, signature verification, response pages and storage consumption; rate limiting reports retryable overload and never changes identity ordering.
- **`key_epoch`.** The hash of the verified genesis, rotate or recover entry that introduced the current live key. Every change of `key_epoch`, whether rotation or recovery, retires a remote person's sessions, whichever door admitted them, and the device certificates and pending confirmations bound to its predecessor; it never grants permission to register a new method. This identity fact is separate from the athanor ownership epoch in §8. A locally initiated rotation needs fresh confirmation and advances durably through an immutable attempt.
- **`recovery_epoch`.** The hash of the genesis, or of the latest recover entry that replaced the live key. A passkey a remote person registered at a relying home is bound to it, so a recovery that replaces the live key retires those passkeys, and an ordinary rotation, or a recover entry that only adds a printed kit, keeps them. An ordinary rotation is the owner's own act under the live key, and a passkey registered at the relying home never depended on that key, so retiring it would only send the person back to the hub's administrator after every rotation. A recovery is the path a compromise takes, so it retires every method the old keys could have reached.
- **Freshness.** A home caches a verified remote head for a bounded time and reads the directory fresh at enrollment, remote sign-in and before a remote person's fresh confirmation, never trusting the person's home for freshness, since that may be the stolen one. Past the bound with the directory unreachable, that person's protected work there pauses with a distinguishable refusal; revoking a local membership is immediate regardless. Local work, local passkeys and local pairing use the home's stored identity and do not require a directory.
- **Doors** (GitHub, Google, OIDC, email and passkeys) admit a person at the relying home where that method is registered. *Not built yet:* the email door, and the mail transport it and §9.3's email code need; GitHub, Google, OIDC and passkeys exist today. The first sign-in creates the person and their online keys together. Linking or unlinking a door needs the person's session and fresh confirmation at that relying home, including proof that they control the new door. A matching email never links identities. The installation or recorded administrator recovery ceremony initializes a first method; a remote session cannot create one by linking a door.
- **Enrollment** gives a person an identifier: under a fresh confirmation it fixes the initial recovery set, mints the genesis, registers it with the pinned directory, and prints the kit (identifier, directory and one recovery signing seed). Confirmation is consumed with the durable enrollment attempt before registration, not merely before displaying the kit. It survives a lost response, and registering the same genesis twice is one registration. A person who never enrolls has keys, a home and local paired devices, and never consults a directory. The deployment explicitly selects its directory before enrollment; operating one's own directory is supported, with its availability burden stated. A hosted default is offered only when its operation and recovery have been verified.
- **Restore** is an entry path, not an operation, because no person exists yet to admit one. It runs only on a node that holds no person, or whose only person is the one its own pending restore is creating, so a restore that crashed after creating the person resumes; never on a hub. The kit proves identity; a separate, single-use installation capability authorizes initializing this node. Configuring the installation for restore reserves its first person for that path: ordinary first door sign-in is refused while the capability is configured. Claiming that capability and the empty node is atomic and binds one resumable attempt; once claimed, removing the configuration does not release the pending attempt. Restore passes through durable phases that resume after a crash. It restores no private data and no membership a home revoked. If a later recovery already replaced the keys it introduced, it ends as superseded and activates nothing: the head is read again before the keys are made active and before the mint, the mint is fenced on the cached head, and no session is issued; a person row the mint created before the supersession stays, with dead keys and no door, until an operator removes it.

### 9.2 Joining a home that is not your own

- **The CYFR door.** At another home, a person presents an assertion their own home signed over that home's challenge, audience and pending carry, only after fresh confirmation of that exact remote sign-in at the issuing home. The other home verifies the carried genesis against the identifier, resolves its pinned directory, verifies the chain and current `key_epoch`, and admits under its own standing rules. A stolen home session alone cannot mint the assertion. The resulting session is not a fresh proof and cannot initialize a passkey or linked door there. It is refused once a fresh head changes its bound `key_epoch`.
- **The browser carries the sign-in.** The person supplies their signing home's address; the directory does not discover it. A durable pending action fixes the destination, challenge and return address, and exact retries resume its recorded outcome without another admission. No session credential crosses origins, and homes do not delegate authority to one another. This exchange discloses the signing home's address to the relying home, but never the client's saved-home list. The directory's URL is public too; hosting it on the signing home can disclose the same address. Restoring an identity restores no client tabs or saved addresses: the person adds them again and authenticates at each home.
- **Membership binds to the identifier.** Leaving or being removed from one athanor retires that membership, the person's clients and certificates for it and the sessions bound to it, in one transition; other memberships and the identity are untouched. The server-wide eject retires everything.
- **Protected work at another home** revalidates both the person's standing and, for a remote identity, the identity head, each within its own bound.
- **Devices at another home** are certified by the person's own home, under a fresh confirmation there, and renewed there by the device proving its key; the other home verifies the certificate under the current live key and never calls the person's home.
- **A hub on the local network** is reached by a catalyst whose consent grants the hub's private range; the deployment's own private targets never apply to a guest.

### 9.3 Devices and fresh confirmation

- **Three separate facts, not a ladder.** Who a person is, established by their session from any door; which devices they have connected, each holding a key it never exports and revocable on its own; and whether a change needs a fresh confirmation. Connecting a device grants no authority a session lacks, and no client holds a rank.
- **Everyday work needs only the session.** Using what was granted, making a grant and answering an agent's approval need no further proof.
- **A short list of sensitive changes needs a fresh confirmation**, whoever makes them, without a client rank or an optional switch: entering or rotating a credential, issuing or rotating a credential that outlives the session (an API key or a webhook secret), pairing or certifying a device, revoking one, establishing or changing recovery material, rotating the live key, issuing a remote sign-in assertion, linking or unlinking a door, registering or removing a passkey, widening who may use an instance entry or widening its component policy from shipped to any, and, once implemented, unlocking the vault or transferring a home. Sanctum opens a pending confirmation for the exact change, with a preview free of secrets, and the proof covers that record's digest, is used once and expires quickly. Members stay equals: the rule is the same for every person.
- **The proof.** A passkey the person registered at the home deciding the change (Face ID, a fingerprint or a security key), asserting over the confirmation's digest; the same passkey also signs them in there. Or a re-authentication through a sign-in method that home verifies as fresh and bound to the confirmation: an OpenID Connect login forced fresh, whose subject, sign-in time and nonce are checked, or a one-time code sent to the person's email verified there for that confirmation. A sign-in method that cannot prove freshness does not count, and a login redirect an identity provider answers from its own session is not a fresh proof. Passkeys are scoped to that home's RP ID and expected origin, not to the person's portable identifier. A remote person registers a separate passkey at the receiving home through its administrator-authorized first-method path below; no home accepts another home's passkey or a signed login assertion as a fresh confirmation. Changing the RP ID requires a new registration or another recovery method.
- **First method and loss.** A passkey registration needs a fresh method verified by the deciding home. A local person who has never registered one may initialize it from a local door sign-in or the installation-authorized restore completion, completed within a short bound, announced to their other clients; revocation never reopens that exception. A CYFR-door sign-in cannot initialize a method, however recent. A remote person without a fresh method there needs the relying home's platform administrator to authorize their exact pending credential registration, under the administrator's fresh confirmation, recorded and announced. This authorization names the person, home, current `key_epoch` and registration digest and is consumed once with registration. A recovery that replaces the live key retires old remote registrations and does not authorize replacements; an ordinary rotation keeps them (`recovery_epoch`). Losing every method uses the same administrator recovery path. Fresh confirmation protects against a stolen session, not a compromised platform administrator.
- **Who can confirm.** A client with no person behind it, a display on a cable, a perception body or a tincture frame, confirms nothing. A person signed in on a borrowed computer can confirm with a security key or from another of their devices. Sanctum checks the proof where each change is decided and nowhere else; the system layer presents the prompt and never decides; display, pointer input and confirmation are three separate contracts, so a pointer a perception body drives can never supply a proof. A gesture is never a key.
- **What a confirmation proves.** A proof shows that the person approved the digest of one pending confirmation; it does not prove what the asking client displayed. So a pending confirmation carries its own preview, stored at the home, and a person confirming on another of their devices sees that device render the preview from the home's record, not from the client that asked.
- **Policies may add changes.** An athanor policy may add operations to those requiring fresh confirmation, including predicates over typed arguments validated by the policy owner. It cannot remove a baseline requirement, grant authority or assign a rank to a member or client. Weakening such a policy itself requires fresh confirmation. Sanctum evaluates the current policy at the deciding write, including when a pending confirmation is consumed. *Not built yet:* policy-specific predicates; no current policy adds one.
- **Device keys and certificates.** A glass generates a key pair it never exports. A certificate, signed by the person's live key at their home, names the device key, the client, the home and athanor and a short validity; it is renewed only while the client is in good standing and ends by expiry or by the revocation of its paired client, which refuses it on the next request. Its subject is either a local person id valid only at the issuing home, or an enrolled person identifier for a remote home. Local pairing needs no directory or kit. A backend checks the certificate and the paired client's standing on every request and a proof of possession on the connection; a remote identity also needs a head fresher than the bound. No cache extends a certificate. The glass renews before expiry and revalidates after sleep before sending work. A change of `key_epoch` retires the remote credentials and proofs bound to its predecessor; local device certificates are refused when the stored signing key changes. An active local paired-client row can authorize a replacement certificate through a fresh device-key challenge after ordinary rotation or expiry; the old certificate alone authorizes nothing. A restored installation without that row requires pairing again. Certificate validity, identity freshness and clock tolerance are three separate numbers. Expiry is strict on the receiving home's clock; clock tolerance never extends a certificate's lifetime.
- **Pairing is bounded.** A pairing invitation is short-lived, has at least 128 bits of randomness, is stored hashed and consumed once with issuance. The new device proves possession of the key it submits. Rate limits bound a source, each client and person, and the installation's verification work: an attempt is charged to a client's or a person's own budget only once it proves itself against the stored row, so a flood that merely names a device cannot lock it out, and the installation's cap is the ceiling for every attempt no name proved. A human-typed shortcut, if offered, has a durable attempt cap per invitation. The existing client gives fresh confirmation before issuing the invitation, and its preview states that whoever redeems this bearer invitation may connect a device.
- **A lost device** leaves the identity intact; until revocation or expiry, cached data and unexpired credentials are the exposure. Revocation erases nothing already disclosed.
- **The device protocol** carries pairing, standing, capabilities, the connect challenge and its proof, discrete intents, the facts of streams granted to the client, and grants and revocations. An intent carrying continuous data is refused by its shape. A stream on the device channel ends at the certificate's expiry and the pairing's revocation, and within §6.6's bounds.

### 9.4 Communication

People talk by being members of one athanor whose home is always on. A pair athanor is a room of two, homed where the two agree, usually a hub. A thread is rows at that home and events on its bus, read by each member's glass. There is no messaging protocol beside the athanor and no directory of strangers.

## 10. Grants

- **Two kinds of grant, one set of rules.** A component grant is a consent revision; a standing approval is an answer a person gave when an agent asked. They have different subjects and rows and obey the same rules; no surface invents a third kind.
- **The preview is structured.** Sanctum answers a preview as typed rows, one per resource an edge grants (a credential and its projection, egress, storage, tools, tool servers, limits, any cap the grant carries, and for a tincture its frame capabilities, placement, background permission, streams, cards and system actions), with the digest that binds them. Every surface renders the rows itself, and a drift test holds that no surface hides a row kind. Explanatory text is shown and kept for audit but never bound, so rewording it invalidates no consent.
- **Narrowing is a decision its owner validates.** A consent may name, per resource kind, a subset of what the component asked for. Sanctum intersects it with the ask and the ceiling and refuses a superset; widening stays the interactive override. A resource kind whose enforcement point cannot check a subset is offered whole or not at all, never under a label that promises less.
- **Selecting beats granting a category.** Where a resource can be chosen, a trusted picker in the system layer lets the person select the exact files, folders or accounts; the surface submits that selection, Sanctum validates it as a narrowing, and the resource's owner enforces it, so a component never receives a whole collection with a promise to ignore the rest. A dimension the person sees, such as approximate rather than precise, exists only where its enforcement point delivers the reduced form; rounding on the screen protects nothing.
- **Every run carries its origin**, set by the admission path that starts it, never by the credential it carries: `interactive` when a person acts on an interactive surface (Prism under a session, or a paired device); `programmatic` for a call over the HTTP API or MCP, whether an API key, a session or a script is behind it; `schedule`; `webhook`. Authentication proves who; it never proves that a person is present. Children inherit their root's origin, so a call between components never turns a scheduled run into an interactive one. A grant names the origins it admits and Sanctum refuses others; a grant that names none admits `interactive` alone, so a command-line or API caller runs a component only under a grant that names `programmatic`. The trusted grant screen and the command line show `programmatic`, `schedule` and `webhook` as visible choices, unticked by default, so admitting one is a deliberate choice when the grant is made, never a prompt on each call. The origin is recorded on the run's own row, not in the authority a runner receives. Origin records how a run started, not that a person stays present: a run started interactively may outlive the screen that started it, and a grant meant to end with the person's activity binds to a lifecycle instead (below).
- **A credential binding carries a lifetime**: standing, until a time, or once. The lifetime is checked where the binding is used, and a once binding is consumed by its first use under a root, so another root is refused. A lifetime is separate from the run's origin: a scheduled or webhook run uses a binding while it is live and is refused at a fire after it expires.
- **An edge may bind named accounts** of its kind beside its default, and a call names one; the system layer's prompts (§7) name the account. A name the edge lacks ends the call as setup required, and the grant prompt names that account; the answer is a consent revision, never an approval. A running turn is never widened by a new grant: it stays on the consent revision it was admitted under, so a retry is a new turn. *Not built yet:* named accounts in use; a consent binds them beside the default, but no call names one.
- **A standing approval is bounded.** It may carry the lifecycle it was given under (an execution, a turn or a schedule), ending with it, with a deadline as an extra bound; and a resource constraint, only for an action whose provider declares which of its arguments names which resource. An action that declares none, a shell command for example, takes no constraint. A standing approval of running a component may be bound to one vault entry, compared with the entry the call's named account resolves to; that bound only narrows the allow and never admits a destructive or external action, which takes no standing allow. A bounded allow is checked when each call is made, against the current execution or turn, the clock and the call's own resource, never against a snapshot from when the turn began. A destructive or external action never takes a standing allow; a standing deny carries no lifecycle, deadline or constraint and always stands. *Not built yet:* named accounts in use (a consent binds them, but no call names one), including a standing approval bound to one entry.
- **Grouping is presentation.** Categories and groups live in the trusted renderer (§7) and never confer authority. Approving several actions at once writes one exact record per action; no group or category answers for an action a person decided, and adding an action to a group never widens an existing grant.
- **Reads are declared.** Which grants reach a resource and which runs used a grant are declared read operations, so any surface can show them from one contract.
- **Revocation and expiry** keep §6.6's bounds, and a standing grant never stands in for a fresh confirmation.

## 11. Memory

*Not built yet.*

Memory is an assistant capability, `Aqua.Memory`, not a process the person tends. It keeps three connected forms: **experiences** (a compact, attributable account of a meaningful event), **understanding** (maintained pages about activities, entities, decisions, findings, preferences and open questions, with observations, statements and interpretations kept distinct) and **procedures** (an approach worth repeating, with its conditions and limits).

- **Capture is durable before it is fast.** The transaction that finalizes a capturable event also writes its Arca outbox fact (§4.3). Aqua consumes that fact into its own capture work and receipt in one transaction, so a crash between commit and broadcast loses nothing; the bus message is a wake-up, never the record. Capture pins the revision it saw. No lower domain names Aqua to make capture reliable.
- **Relevance is personal, reach is system-wide, access is authority.** Capture needs a traceable connection to the person's participation and permission to retain in the destination athanor. A late synthesis never overwrites a correction, a forgotten source stays out of every rebuild, and an answer drawing on several athanors needs access to every one of them or is rebuilt from the accessible subset before generation.
- Pages publish fenced (§6.3), and `memory/` storage is host-only.

## 12. How the architecture is held

- **Compilation.** Layer edges are Mix dependencies and Boundary declarations, so a forbidden edge fails to compile. Sanctum's lack of Ecto is enforced the same way.
- **`Cyfr.Boundaries`** holds the rows the compiler cannot express, each with its reason: narrower allow lists, cross-application reaches, the security-read seam, the admission entries, the bus, gate, configuration, settings, route and port rosters, and the marker groups.
- **Seam tests** hold actor-first arguments, the unscoped and bypass markers, roster membership, the surface reads each surface may make, Sanctum-only security storage, refusal rendering, the rule that no frame reaches a facade, and the rule that no sandbox token, CSP directive or served file type is written outside the tincture rules.
- **Drift tests** compare every derived view with its owner: the CLI catalog, discovery, telemetry rosters, protocol vectors in every language, environment variables against the shipped examples, the configuration guide against the settings roster, the guides' tables, the route map and the glossary.
- **Containment suites** run the shipped images: runner isolation, memory and network, builder and backend isolation, and the credential canary.

### Sources of truth

| Fact | Owner | Derived views, drift-checked |
|---|---|---|
| Wire shapes, versions, signing domains, actor, authority data, MCP codec, device, identity and confirmation shapes | Prima | vector files; Go, Python and JavaScript codecs |
| Schemas, transactions, revision pointers, retention kinds, the lease row | Arca | schema fingerprint, baseline migration |
| Who may do what, consent, credential projection, the changes that need fresh confirmation, identity decisions, caps | Sanctum | surface rosters, consent golden files, the system layer's prompts |
| Operations, arguments, planes, permissions, streams | Grimoire providers | discovery, CLI catalog, consent shapes, guide tables |
| Boot ownership, topics, configuration schema, settings roster, telemetry, boundaries, admission roster | Host | consumer rosters, `.env*.example`, `configuration-guide.md`, the route map |
| Served file types, frame capabilities, sandbox and CSP, templates, card and stream grammar | Compendium's tincture rules | the publish check, `tincture-guide.md`, the frame's headers |
| Memory records and pages | Aqua, stored by Arca | rebuildable indexes |
| The layout | the person, stored by Arca | the desktop's rendering |
| The architecture | this document | the glossary in `README.md` |

A change to a principle, a layer edge, a port or an invariant is a change to this document, made in the same change as the code.
