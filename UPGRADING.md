# Upgrading

What changes for an operator running a server, release by release. There
is no compatibility layer for behaviour: each item says what is different
and what, if anything, to do. Newest first.

## Consent reads the catalog through a port; a provider that cannot load refuses the boot

`Sanctum.Catalog` is the port a consent shape learns the servable
`tool.action` pairs through, and `Cyfr.Ops.Catalog` its one
implementation. A configured tool provider that cannot load is now a
boot failure — a catalog missing a provider would narrow every consent
digest derived from it — unless `config :cyfr, :tool_providers_lenient`
is set, which only one app's own test run does.

An external MCP server's consent identity is derived from its stored
configuration at every read; the cached copy and its cache keys are
gone, so a configuration change is its own invalidation.

The `arca://files/{path}` resource opens the athanor's whole tree to a
person (a session, or a key holding `:admin`); a key scoped to
`:storage_read` alone reaches `conversations/` and `guest/` — what a
conversation attached and what an agent could have written — and never
the estate's components, its assistant tree or its notes.

## The operation catalog lives under `Cyfr.Ops`; the wire is one adapter

The modules that define an operation — the provider behaviour, the
registry, the action annotations, the visibility rules, the error
vocabulary, the input contract and the service roster — are
`Cyfr.Ops.{Provider, Catalog, Annotations, Visibility, Error, Contract,
Services}`; they were `Emissary.MCP.*`. A provider module in
`:tool_providers` implements `Cyfr.Ops.Provider` now. The wire
(`Emissary.MCP`: router, protocol, sessions, SSE, external servers), the
console (`PrismWeb.Ops`, formerly `PrismWeb.MCPHelpers`) and the
assistant (`Aqua.Ops`, formerly `Aqua.MCPHelpers`) are adapters over
the one catalog and its one gate.

How a handler is run is the adapter's choice. An in-process caller — the
console, the assistant — gets the gate, the contract and the handler as
a function call on its own process: no task, no timeout, no wire
encoding. The wire and an in-chain call from a running component ask
for the supervised run (`runner: :supervised`): a task under the tool
timeout, registered under the request id so a transport whose caller
disconnects can cancel it, and a crash contained to the call. Every
dispatch still files its request-log row.

## One establish recipe, and no permission bag on a session

`Sanctum.Caller.establish/2` is the only builder of an authenticated
context. It takes the credential — a session token, an API key
(`{:api_key, raw}`), a tincture access token (`{:tincture_token, t}`) or a
verified webhook row (`{:webhook, row}`) — names the principal, holds it
to its standing and passes the tenant gate; the MCP plug, the tincture
surface and the webhook controller map its refusals to the wire. The
shipped sign-in providers answer an identity and nothing more: nothing
resolves memberships before the door, the dead session-token arms of
their `authenticate/1` and the `conn.assigns[:session_token]` branch are
gone, and their `current_user/1` is `nil` — a session or key on a request
is established once, by the recipe, never loaded a second time. A key
store that cannot answer is a 503, not a 401. `Sanctum.Tenancy.resolve_into/2`
is gone; `resolve_status/2` is the one resolver.

`sessions.permissions` is dropped (migration `20260913000000`). A session
is a person's, and what they may do is decided by their memberships, the
estate's consents and the policy on every request; a key carries its
scope on its own row. `Sanctum.Context.require_permission/3` is the one
permission gate and takes the plane of the call (`:external`, the
default, refuses a guest-planed context outright; `:in_chain` checks the
identity conjunct, the authority having been applied at dispatch);
`require_permission_for_plane/2` and `require_identity_permission/2` are
gone. Platform-admin revocation was already immediate — the operator
list at sign-in, the boot reconcile and `door.remove` all revoke the
sessions with the row — and stays so.

## A person has an id of this server's; identities are rows of their own

A `users` row's id is now minted here (`usr_…`) and is the `user_id` every
membership, session, key, consent and execution carries. How an identity
provider names the person is an `external_identities` row keyed by the
IdP composite `<provider>|<issuer>|<subject>` (migration
`20260912000000`); one person may be named by several, and a sign-in
through a known identity refreshes the same person. Nothing parses a
`user_id` any more: the session's `whoami` answers the provider the
context carries, and the server's synthetic principals (`system`,
`_seed`, `webhook:<slug>`) are told from people by the prefix.

The door still speaks the provider's terms, because it judges a person
before any row exists: a `user_id` door entry names an IdP identity key,
and the door tool refuses a person's own id there ("name their email").
`member.add` accepts either a person's id or an identity key that names
them. A CLI or client that keyed anything on the old composite `user_id`
will find it changed after the upgrade; there is no migration of
existing rows — a server upgraded in place mints new people at their
next sign-in.

## A server boots with no registry — formula `local.aqua` 1.0.7

A person's own athanor is minted the moment the door admits them, under
a slug of this server's, and a session without a cyfr.run namespace is as
signed in as any other. The namespace is a publishing credential claimed
at first publish (`/claim-namespace`, whenever the person chooses); the
claim gate after sign-in, and the sign-in outcomes that depended on the
registry answering, are gone. The probe after the door is a budgeted
courtesy for everyone: whatever cyfr.run answers, the person proceeds,
and the console flashes what is still owed (a policy to accept, a
namespace another identity here holds).

`CYFR_REGISTRY_URL=none` names no registry at all. Every client refuses
at its network seam with a typed `registry_unconfigured` error before
dialling; the health probe reports the registry as "disabled" rather than
"down"; `component.search` and `component.pull` say so. For that to boot,
the shipped AQUA formula's five model catalysts
(`catalyst:moonmoon69.{claude,openai,gemini,grok,openrouter}`) are now
`optional` dependencies. Provisioning succeeds on the required closure
(`local.files`, `local.http`), the consent bootstrap mints the baseline,
and an activation omits an optional dependency that is not installed — so
when a catalyst is pulled later, the formula's activation changes and
the estate re-consents from the grant sheet, as for any dependency
change. A turn whose agent names a catalyst the estate does not hold is
refused with `catalyst_not_in_estate`, as before.

The manifest change is a new seed version: `local.aqua` 1.0.7 replaces
1.0.6 (the guest binary and source are unchanged; the build stamp still
matches). An estate consented against 1.0.6 re-consents from the grant
sheet at first use.

## An agent belongs to its estate — the borrow machinery is gone

A shared tape runs its own estate's soul and roles alone, and a person's
own assistant rides in their own panel; the code that let an agent be
addressed across estates (`@estate.name`), read from another estate's
tree, or carry standing answers home from a room served nothing and is
deleted. `conversations.orchestrator_owner` and
`tool_grants.agent_athanor_id` are dropped by migration `20260909000000`
— both always named the row's own athanor — and the grant keys are now
per estate and agent (`agent` scope) or per thread and agent
(`conversation` scope). A grant is validated at the write
(`Arca.Schemas.ToolGrant.changeset/2`). The chat's standing-grant strip
names the agent each answer was given for, and revoking one names it too.

Four runtime rules changed with it. A turn resolves its agent from the
tree as it is NOW, every turn — an edited, disabled or revoked answer
holds on the next send; the previous composition is never a starting
point. A card is decided against the policy as it stands when it is
approved, and a standing answer is recorded only after that check. A
conversation's standing answers are keyed by the agent they were given
for, so an answer for the soul never runs a role's card. And an operator
who opens an estate they are not seated in reads it: sending, deciding a
card or revoking a grant there is refused, as saying a line aloud into it
already was.

The grant store now fails closed: a turn whose standing answers cannot be
read is refused rather than composed without them (an outage used to
drop every "never"). The notes tool pages `list` and `search` (`limit`,
`after`), and `read` takes the `athanor_id` a search answered so a person's
own assistant can follow a hit into another of their estates.

## Kind always wins — one policy story for the soul, its roles and the guest

### A destructive or external action is never automatic, anywhere

The seed, the AQUA page and the formula used to disagree: the page said a
destructive action "always asks" while the shipped Builder held
`files.delete` and `storage.delete` at `auto` and the guest ran whatever
the file said. Now one rule holds at every door. A destructive action
(`files.delete`, `storage.delete`, `http.delete`, `notes.forget`, …) or
an external one is `ask` on the soul and is not a role's hand at all;
the `aqua` tool and the page refuse to write `auto` for one, and the
runtime demotes an `auto` that reaches it from a hand-edited file to
`ask` before the guest sees the policy. Writes and executes on a role
stay **clone-is-consent**: in a group, `@aqua` cloning into the Builder
still writes files, POSTs, runs components and creates components with
no card — the clone is the person's yes. That is the decision, stated
here so it is not rediscovered as a bug.

The shipped roles lose `files.delete`, `storage.delete` and
`http.delete`; the soul gains its own read hands (`files.read/list/tree/
grep/search`, `storage.read/list`, `http.get/head/read/links/metadata`)
and holds the three deletes at `ask`, so deleting is a card the soul
raises. A role holds nothing at `ask` — a cloned role has no card to
raise — and the door refuses one. `request_setup.open` is `auto` or
absent. An edited soul or role that held a destructive `auto` keeps its
file; the runtime reads it as `ask`, and the page shows it so.

### An approved delete card actually runs

An approved card for a virtual action (`files`, `storage`, `http`) runs
the wrapped catalyst as a child of the card's own consented authority,
the way the guest runs it — it used to fail at the registry, which is why
nothing could hold one at `ask`.

### Aliases are judged as what they are

`execution.run` of the files or http catalyst, at any version, is
judged — in the guest, in a proposal and on approval — as the virtual
action its input denotes; a `files` call inside `data/storage/` is the
storage operation; `execution.run` of the assistant itself is refused to
the model; a clone of the same formula is admitted only as a role its
parent's roster lists, with the roster's own policy and prompt, whatever
the request carried. A "never" you answered is composed into the policy
as an exact `deny`, so a `tool.*` glob can no longer re-offer — or
silently automate — a pair you declined.

### Arcade is folded into Artisan

The Arcade role shipped with the Artisan's hands; it is gone, and the
Artisan does games and 3D scenes too. A soul edited to name
`aqua_arcade.*` keeps the key harmlessly; `cyfr update` drops the file.
The manifest also stops granting `component.categories`,
`execution.run_stream`, `execution.list`, `execution.cancel` and
`build.validate` — nothing shipped exercised them — so an estate consented
against the previous 1.0.6 caps re-consents from the grant sheet.

### The guest is rebuilt from source

`formula.wasm` is built by `scripts/build-aqua-guest.sh` from the reviewed
source, with rustc 1.93.0 (254b59607 2026-01-19) and cargo-component 0.21.1
targeting `wasm32-wasip2`. The build writes `src/build.stamp` beside the
source: the digest of the source tree it was built from, the digest of the
binary, and the toolchain. CI runs `--check`, which recomputes both digests
and fails on a guest edit that was not rebuilt or a binary the script did
not write; `--rebuild-check` builds and compares byte-for-byte on a machine
with that toolchain. The binary shipped here is that build.

## One AQUA — soul, roles, scrolls, notes; the three-zone console

### `cyfr update` refreshes the AQUA tree again

The scaffold manages `aqua/aqua.md`, `aqua/roles/*.md` and
`aqua/skills/*/SKILL.md` — the shipped soul, roles and scrolls are
overwritten on `cyfr update`; a role or scroll you added is preserved. An
earlier build managed a layout that no longer shipped and refreshed
nothing.

### Storage: `memory/` is `notes/`

What was kept out of a conversation lives under
`data/athanors/<athanor>/notes/`, one markdown file per note with
provenance frontmatter (`kept_by`, `kept_at`, `conversation`,
`execution`). The old `memory/` root is not read by anything. Blobs left
under it are orphaned — nothing lists or deletes them, and they count
against the athanor's quota until you remove the directory by hand.

The `notes` tool replaces the `memory` tool on the wire: `keep`, `pin`,
`forget` (writes, no scope — they land in the estate in focus), `list`,
`read`, `search` (reads, scope `estate` | `mine` | `everywhere`). The
pinned pages are `about-you` (a person's athanor) and `about-us` (a
group's), up to 2 KiB; the soul reads its estate's pinned page and a
bounded index of its filed notes on every turn.

### The AQUA tree: `agents/` is `aqua.md` + `roles/` + `skills/`

The seed tree is `seed/aqua/aqua.md` (the soul), `seed/aqua/roles/*.md`
(the roles it clones into) and `seed/aqua/skills/<name>/SKILL.md` (the
scrolls). An athanor's own tree under `data/athanors/<athanor>/aqua/` has
the same shape.

Nothing reads `aqua/agents/` any more. A bind-mounted `./aqua` shaped the
old way gets the new tree copied beside it by the container's entrypoint
(the guard is `[ ! -f /app/seed/aqua/aqua.md ]`; nothing is deleted) —
delete the old `agents/` directory by hand. An athanor whose overlay holds
an edited `agents/<name>.md` keeps a stray file that the `aqua` tool's
`reset` with `all: true` drops; `status` reports it as `own_shadowing` —
the estate's own bytes standing where the shipped tree has nothing left
to shadow.

An athanor upgraded from before the `agents/` layout — a flat
`aqua/aqua.md` beside `aqua/aqua_*.md` and an `aqua/agent.json` — keeps
its old soul: the flat `aqua.md` sits at the new soul's path and counts as
the estate's own edit, so a plain `reset` leaves it. Run `reset` with
`all: true` to take the shipped soul, and delete `agent.json` and the flat
`aqua_*.md` files by hand; no reset removes them.

### Formula `local.aqua` 1.0.6 needs re-consent

The manifest's `caps.tools` changed: it now grants the `notes.*` actions
and `aqua.skill_list/get/create/update`, and it no longer names actions
the soul never calls. The chain authority checks every in-chain call
against the consent blob. A fresh install consents at bootstrap. An
existing estate consented against 1.0.5 sees "Denied by chain authority"
on an approved note card until a member re-consents from the grant sheet
(the AQUA page → the model's grant sheet, or any consent prompt for the
formula). The AQUA page now says so: when the estate's frozen consent
lacks actions the shipped manifest grants, a banner names them and offers
the consent sheet. 1.0.5 is gone from the seed.

- The consent sheet gains one line: `catalyst:local.http` is now a declared
  static dependency of the formula (it always was what the `http` tool
  called).
- The shipped policies changed. The soul no longer holds `registry.*`,
  `webhook.*`, `tincture_visibility.*`, `component.deprecate/discover/fork/
  get_blob/yank` or `schedule.get` — actions a chat assistant has no
  business proposing — and holds `component.create` at `ask`. A role holds
  no action at `ask` any more: a role's answer is a tool result the soul
  reads, never a turn of its own, so an `ask` on a role could never fire.
  The build roles keep `files.delete`, `storage.delete`, `execution.run` and
  `component.create` at `auto`; the person's yes was the clone itself. An
  estate with an edited soul or role keeps its edits; `reset` takes the
  shipped policy.

### Writes to the AQUA tree are a person's act

Every write on the `aqua` tool — `create`, `update`, `delete`, `reset`,
`skill_create`, `skill_update`, `skill_delete` — now requires a signed-in
session (`consent: :interactive`), exactly as the `notes` tool does. An API
key, a `*` admin key included, is refused and no longer sees those actions
in `tools/list`; the reads (`list`, `get`, `status`, `skill_list`,
`skill_get`) are unchanged. A script that managed the soul, roles or
scrolls with a key must run as a person (`cyfr login`, then `cyfr aqua …`).

### Edits to the AQUA tree meet under the lock

Two members editing one agent at once used to lose one edit: the page's
allowlist toggle read the policy, changed it and wrote the whole map back,
and the last write won. `aqua.update` now takes `tool_policy_patch` — the
keys to change, `"ask"`/`"auto"` to set one, `null` to take one off —
applied to the policy as it is when the write lands and judged as the
whole it makes (the kind ceiling and the no-`ask`-on-a-role rule hold for
a patched key as for a replaced map); `tool_policy` still replaces the map
for a caller that means to, and the two are not given together. The AQUA
page sends patches. A prompt save may carry `expected_digest`, the
`content_digest` that `get` now answers; an `update` over a prompt that
changed since is refused with a conflict ("The prompt changed since you
opened it — reload to see the current one") and the page keeps the draft
open. Title and description are written when the field loses focus, not
on every keystroke.

`aqua.create` gives the soul leave to clone into the new role in the same
act — the `<name>.*` key on the soul's allowlist that the page used to add
in a second write — and answers `cloneable: true`, or `cloneable: false`
with a `note` saying why (no soul here, or the soul write failed; the role
stands either way). A role created over MCP or the CLI is no longer
invisible to the runtime until someone edits the soul.

### The room beside a thread is read for one call

The room a person has open beside their own thread (the panel reading a
group's chat) used to be placed in the system prompt. It is other people's
words, so it now travels as a transient part of the task turn: the guest
puts it in front of the task for the model's call and takes it back out
before the history is returned. It is never a row, never in the history a
later turn reads, and never in what the compactor keeps.

### `aqua.list` can include the roles set aside

`list` leaves a role disabled with `disabled: true` out of the roster, as
it always did; `include_disabled: true` lists it too, and `detail: true`
now carries each agent's `disabled`. The AQUA page reads the roster in
one call rather than one `get` per role it had set aside.

### One pane per estate

The chat holds one conversation pane per estate and turns it to the open
thread by message; a thread switch re-reads the thread's rows and live
state alone, not the roster, the members or the model catalogue. The
draft in the composer is the thread's and is cleared on a switch, as it
was when a switch remounted the pane.

### Two caps ship on

`CYFR_MAX_PAIRS_PER_PERSON` (default 200: the DMs one person may hold open,
checked for both people when a DM is minted) and
`CYFR_MAX_CONVERSATIONS_PER_ATHANOR` (default 1000: the threads one estate
may hold, which any member's client can mint from the wire). An estate
already past a ceiling refuses the next mint with `limit_reached`; `0`
turns either cap off. See `.env.example`.

### DM keys are re-derived by a migration

A DM's canonical key is now the SHA-256 of the JSON encoding of its two
member ids. The migration `20260908000000_pair_key_rehash` re-keys every
active DM from its two seats, so clicking a name finds the DM you already
have rather than minting a second one.

### Whether AQUA answers is derived now

An estate with exactly one active person answers every line; any room
with two or more — Home included — answers only an `@aqua` mention, so
people can talk to people. The `settings.aqua.answer_mode` setting is
gone and a stored value is ignored: a Home with two or more members will
stop answering unaddressed lines.

### Standing approvals are rows, and the old ones are in your markdown

"Always" and "never" decided in a chat are `tool_grants` rows now, scoped
to a conversation or to the soul or role it was answered for, and survive a restart. Before this
release an "Always" click wrote `auto` into the soul's or role's markdown
`tool_policy`. Those entries are still there as declared policy — no
longer revocable from the chat. Review each estate's soul and roles on the
AQUA page for `auto` entries a chat click wrote.

### Topics start unfollowed

Following a topic decides your sidebar and notifications, never access.
There is no backfill: on an upgraded server every existing topic renders
collapsed until each person follows it from the rail.

### Routes and vocabulary

- `/chat` is the one global page: the chat across every estate you belong
  to, with the estate and the thread in the query
  (`/chat?a=<route>&c=<conversation>`). `/a/<route>` and
  `/a/<route>?c=<id>` forward there. The rail lists your own athanor, your
  DMs (by the other person's name), your groups and their topics; clicking
  a person opens the DM in place. `+ New` opens a blank pane at
  `/chat?a=<route>&c=new`: the first message starts the thread, and a
  refresh of that address is the same blank pane, not the newest thread.
- `/a/<route>/aqua` is the estate's AQUA page; `/a/<route>/agents`
  forwards there. The sidebar, drawer and palette say **AQUA** where they
  said Agents. The page holds the soul and roles, the pinned page, the
  notes drawer and the scrolls.
- Your own AQUA is a floating panel on every authenticated page: a button
  bottom-right, a panel onto your own athanor's threads. Beside a room it
  reads the room's newest lines into each send (never kept, never a row of
  your thread) and pastes an answer back onto the room, attributed to you.
- A DM is a small frozen estate: click a name on any members list you
  share. It ends when either person leaves; clicking again starts a new,
  empty one. The members page's Message button is gone.
- The `aqua` tool speaks soul, role, scroll and guide (`list`, `get`,
  `create`, `update`, `delete`, `status`, `reset`, `skill_list`,
  `skill_get`, `skill_create`, `skill_update`, `skill_delete`); there is
  no `type` value of `orchestrator` or `sub-agent`. `cyfr aqua` follows:
  `list` (soul, roles, guides and scrolls), `get`, `status`, `reset`
  (`--all` also deletes the roles and scrolls the estate made — it asks
  first), `skills list` and `skills get`.

### Schedules can keep their outcome

A schedule whose metadata carries `"keep_outcome": true` files every
completed run's output as a note in its estate — named by `"note_name"`
when set, else by the schedule's id — cut at 64 KiB. Each run replaces the
note before it. Nothing changes for schedules that do not ask.
