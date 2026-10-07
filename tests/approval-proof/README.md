# The approval proof

`run.sh` proves, on the browser harness (`tests/browser/`), that approving an
app in Prism shows a dependency's provided configuration with no key
question, lets the person choose an entry per edge among two of one
provider, commits each binding with its own lifetime, and that the home's
decisions on those bindings hold: a `once` binding admits one root, an
`until` binding stops at its instant, a GET-only grant holds GET alone, a
grant opened for a named account binds it, and a revoked entry's next use
is refused. The home is one `cyfr` release on a SQLite cell, `home.test`,
behind the harness's HTTPS front (`browser_home`). One person
(`operator@example.com`) is signed in by the release fixture's door
(`tests/release-boot/fixture.exs` `person`). `proof.mjs` drives her in
Chromium's full build, every entry she makes confirmed with the passkey
Chromium's virtual authenticator makes and registers first, as
`tests/instance-entry-proof/` confirms its administrator's. It asks
`run.sh` for the home's part of a step through its output directory
(`ask-N.json`, answered `answer-N.json`), and `fixture.exs` answers it by
calling the real paths and returning bounded facts. A question longer than
its arguments is read by the fixture from its own file, by path, so none of
it rides a command line.

The app is the tincture `approval-probe`, which `proof.mjs` describes and
`run.sh` writes into the run's scratch directory and installs through the
release's own path (`fixture.exs` `publish`, as `tests/grant-proof/`
installs its tincture). It declares one need of its own, `openai`
(`api_key:openai.com`, attached as `Authorization: Bearer {value}` for
`api.openai.com`, a host its own network ask names, GET and POST, as the
registry requires), and three shipped catalysts as dependencies:
`catalyst:local.openai` (the same provider, its network ask GET and POST),
`catalyst:local.claude` (`anthropic.com`) and `catalyst:local.grok`, whose
need the app's `provides` block fills (`api.x.ai`, GET and POST, `/v1/`, one
public value). Nothing of it is compiled.

The harness runs no execution engine and no model, so `run.sh` never starts
a run, sends no request and runs no turn:

- **An admission** is the loader's answer for a run of the app under her
  context (`Crucible.authority_for/3`'s path).
- **A use** is the decision of the path an attached request takes
  (`Sanctum.Attach.resolve/5`), for a request of a method to a URL, under a
  root execution id the proof names and for which no execution exists. The
  material it resolves is dropped inside the fixture. A use is not a
  dispatched request, and the record never calls it one.
- **The named-account prompt** is the one the chat's thread pane opens when
  a launch names an account its app does not bind. Only a turn ends that
  way, so the fixture stands in for the loop. It first reads the real
  resolution of the account (`Sanctum.Consent.Accounts.resolve/4`), which
  must answer `connection_not_granted`, the answer a turn ends on. It then
  announces, on a thread of hers (made by the `thread` operation's `create`,
  holding no message), exactly what `Aqua.Loop.end_for_account/2` announces
  (`apps/cyfr/lib/aqua/loop.ex:1059-1076`): `:consent_required` with the
  app, her id, the account and its need (none, since the app declares one),
  and no message (`Aqua.Tape.announce/4`). No turn exists, before or after,
  and the state shows none.

The actual requests, turns and scheduled or webhook execution are the
named suite cases under [Shown elsewhere](#shown-elsewhere).

`VAULT_PROOF_VIEWPORT` is `desktop` (1280×900, the default) or `720x720`;
every step runs at either, and the record names the one it ran at.

The release is built by hand, as `tests/release-boot/release.sh`'s
`release_build` builds it but without fetching dependencies
(`MIX_ENV=prod MIX_BUILD_PATH=_build/prod_release_boot_sqlite
CYFR_DATABASE=sqlite mix compile --warnings-as-errors && mix assets.deploy
&& mix release cyfr --overwrite`), and the proof runs with
`RELEASE_BOOT_SKIP_BUILD=1`. It writes `approval-proof.json` and
`approval-proof.md` into `PROOF_OUT`. A failed run also leaves
`approval-proof-frames.json`, the page's last socket frames, and
`approval-proof.png`, the page, unless the page could then show a key she
typed. Frames, records, progress lines and error output replace every known
secret with the shared fixed marker (`tests/grant-proof/redact.mjs`): the
session cookie, each typed key, its SHA-256 value, each typed-payload digest,
and any page tokens already collected. Text is redacted before truncation.
Comparisons and material detection use the original values in memory, so
redacting failure evidence does not change the failed decision or exit.
Confirmation text stays complete through detection; a raw length bound
could split a known secret into an unrecognizable fragment.
`run.sh` removes every question and answer
on every exit, a kept or outside `PROOF_OUT` included, since a `state`
question carries digests of the keys she typed.

**The screenshot.** The proof types a key in two places alone: the
credential prompt's value field that "Connect your <provider> account"
opens (`#system-layer-secret`, a password field), for OpenAI Work and
Anthropic; and the Vault page create form's fields (`textarea[name="fields"]`,
`OPENAI_API_KEY=<key>` in plain text), for OpenAI Home. It holds a flag from
the moment it fills a key in until it has read, on the page, that no field's
value and none of the page's text holds any key it typed; a step that made an entry
holds only once each key is read gone. A run that fails while the flag is
set writes no screenshot, and its record's `screenshot` names the flag and
says the screenshot was withheld, with redact.mjs's marker. A run that fails
at any other moment keeps its screenshot.

## Steps

Each step is one row; the proof fails when a row does not hold, and stops at
the first row a later one rests on.

After every step the proof compares the whole of what this README names, as
the home holds it, with its own model of it. This is one equality after the
same canonical ordering on both sides: members by name. A list keeps its
order on both sides, so an item in another place fails, except where its
owner defines it as a set; those lists are named in one list in `proof.mjs`
(`SETS`) with the reason, and their items are ordered by their own canonical
text on both sides. They are the state's tables: `state` reads each with no
order, and SQL answers a table's rows in none. The home's side is one read
(`fixture.exs` `state`), which picks no row out of a set:

- every row of her athanor's vault entries (tombstoned ones too) and of its
  per-provider defaults;
- every profile of `tincture:local.approval-probe` in her athanor, every
  consent of those profiles and every binding row of those consents;
- every turn and every execution of her athanor, of which there are none at
  any step.

The model changes at each step only by what that step did: an entry made, a
grant committed, a use decided, an entry revoked. So a change made behind
the browser to any of these, at any time, fails the next step, whichever
step that is. A step about one object says so in its row, and passes only if
the whole state matches as well.

Two things are outside the comparison, each because it carries no
authority:

- **The thread** the announcement goes to. The proof sends nothing on it,
  and no turn of it exists, which the state's turns and executions show.
- **The component rows** of the tincture and the shipped catalysts. They
  are the installed request the derivations read, never a row the
  comparison checks.

The model takes only these values from the home, each the decision or
identity it names, never a read of what it is compared with:

- her user id and athanor, from her sign-in;
- each entry's id, as the Vault page lists it under its name;
- the profile and consent the loader roots the app on after each commit
  (`fixture.exs` `admit`);
- what each entry's request implies the owner stores (`requested`): the
  canonical text of the destination she sent and the binding digest over the
  entry's binding fields;
- what a commit of her decisions writes on the consent row (`derived`): the
  policy blob, its digest, the activation and the shape and commit digests,
  and the source node's edges and activation digest, built by the owner's
  own builders over the installed components from her decisions alone;
- the database's time as the run starts (`clock`), and its time at the end
  of each `state` read: the window a stored time is held to;
- the until the preview row showed her when she chose five minutes.

**Every field, classified.** Each field of the named state is in one of
three classes, declared in one table in `proof.mjs` (`FIELDS`), which this
section mirrors:

- **exact:** compared exactly with the model;
- **derived:** compared with a value derived independently of the row,
  which the model holds;
- **bound:** a clock or server-minted value, held to its stated bound.

A field the table does not name fails the step as unclassified, and a named
field a row lacks fails it as missing, so a new column cannot slip in
unchecked. Turns and executions are none at every step, so any row of
either fails whole, and their columns need no class.

| Table | Exact | Derived | Bound |
|---|---|---|---|
| `vault_entries` | `name`, `provider_hint`, `kind`, `provenance`, `field_names`, `oauth_endpoints`, `oauth_scopes`, `attach_only`, `status`, `payload_rev` | `binding_digest`, `destination`: what her request implies (`requested`); `sealed_payload`: the value she typed, compared inside the fixture | `id`: the Vault page's; `athanor_id`: the sign-in's; `last_used_at`, `inserted_at`, `updated_at`: times |
| `vault_defaults` | `provider_hint`, `instance_entry_id` | | `id`: a default's own id; `athanor_id`: the sign-in's; `vault_entry_id`: the Vault page's; `inserted_at`, `updated_at`: times |
| `profiles` | `source_ref`, `kind`, `label`, `status` | | `id`, `head_consent_id`: the admission's; `athanor_id`: the sign-in's; `inserted_at`, `updated_at`: times |
| `consents` | `revision`, `scope`, `pinned_version`, `invoke_mode`, `granted_via`, `supersedes_id`, `admitted_origins` | `shape_digest`, `commit_digest`, `blob_digest`, `resolved_policy`, `activation`: what a commit of her decisions writes (`derived`) | `id`, `profile_id`: the admission's; `athanor_id`, `granted_by`: the sign-in's; `granted_at`: a time |
| `consent_vault_refs` | `binding_key`, `scope`, `instance_entry_id`, `via_label`, `lifetime_kind`, `consumed_by_root` | `binding_digest`: `requested`; `expires_at`: the until the preview showed her | `consent_id`: the admission's; `athanor_id`: the sign-in's; `vault_entry_id`: the Vault page's |

The bounds:

- **An id** equals the one its source showed: the Vault page, her sign-in,
  or the loader's admission after the commit that wrote it.
- **A default's own id** is of the `vdf_` form. It names nothing a person
  acts on: a default is found by its athanor and provider, both compared.
- **A time** is none where the model holds none (an entry never used).
  Otherwise it lies inside the run's window: from the database's time as the
  run starts to its time at the end of the read that returned it.

No writer sets a consent's `supersedes_id`: a revision follows the one
before it by its number and the profile's head, so the column is none at
every revision, compared exactly.

**The until.** A five-minute binding's `expires_at` is compared, as an
instant, with the until the preview row showed her, never with the stored
row. That until is in turn held to the moment she chose it: less five
minutes, it lies between the database's time just before her click, cut to
its second as the sheet cuts it, and its time just after.

**The sealed payload** is derived. The proof passes the fixture the digest
of the payload document she typed for each entry (`Sanctum.Vault.Payload`'s
version 3, its one field, in canonical text). The fixture unseals the stored
payload as its owner does (`Sanctum.VaultReader`'s private
`unseal_material/2`: the same AAD, `Sanctum.Cipher.decrypt/2` and
`Sanctum.Vault.Payload.decode/1`), hashes the decoded document's canonical
text, and answers only the outcome. A payload replaced by another validly
sealed value fails as one that unseals to another value than she typed. A
payload that does not unseal fails with its own sentence, and so does no
payload where she typed one. Neither the material nor anything derived from
it leaves the fixture. The proof fails if a key, a digest of a key or a
typed payload's digest reaches an answer, the record or a question left
behind.

**Stored text, byte for byte.** A stored JSON text (an entry's destination
and field names, a consent's admitted origins, policy blob and activation)
is compared as the text it is, and never parsed first: its owner reads it
with the first of two duplicate members, and a parse here would keep the
last.

- **An entry's destination** is compared with the canonical text of the
  destination she sent (`Prima.Destination.canonical/1`), and its binding
  digest with the digest `Sanctum.VaultReader.binding_digest/1` gives over
  her request.
- **A consent's policy blob, its digest, its activation and its shape and
  commit digests** are compared with what a commit of her decisions writes,
  built by the owner's own public builders as `Sanctum.Consent.Commit`
  builds them, never read back from a consent:
  `Sanctum.Consent.BlobBuilder.build/5` over the installed closure, each
  binding through `vault_resource/1` from the entry's id, her request for it
  and the need's own projection and attach rule, the provided edge through
  `provided/3`, her narrowing, then `encode/1`; `Prima.JCS` for the blob's
  digest and the activation's text; `Sanctum.Consent.ShapeDerivation` and
  `Sanctum.Consent.ShapeDigest`; and `Sanctum.Consent.CommitDigest` over her
  decisions, lifetimes included, with nothing removed, as the sheet showed.
  The loader checks the blob only against the digest in the same row, so a
  widened blob stored with its own digest would otherwise be admitted.

**Decisions.** Each answer is compared whole with the decision the step
expects:

- **The admission:** whether it admitted, exact; its profile and consent,
  the ids the model takes; the source node, its activation digest and every
  edge the loaded authority holds for it, derived: the blob a commit of her
  decisions writes, read by the owner's parser (`Prima.Authority.Blob`).
- **The uses:** as many answers as uses asked, in the order asked, each
  naming the request it decides as the proof sent it (the edge, need or
  account, root, method and URL) beside its decision, exact. An answer
  moved to another request, or two answers exchanged, fails.
- **The announcement:** the resolution and that it was announced, exact.
- **The account:** the entry the account resolves to and its stored name,
  exact.

**What she sees** is read from the pages as whole objects: each need's
offered entries, in the order the vault lists them (by name), and which is
pressed; the controls it offers; each previewed credential row's binding,
entry and lifetime, the lifetimes compared by each row's own binding key
over every row shown, never by their place; the OpenAI catalyst's network
row; and what the grant removes, which is nothing at
every commit.

| Step | What holds |
|---|---|
| `provided_preview` | she registers her passkey; her first grant of the app, opened from its Components row, shows the Grok catalyst's need as the publisher's configuration, "Provided by local", naming its destination (`https://api.x.ai`, GET and POST, `/v1/`), with no entry offered, no "Change", no "Connect your … account", no account to add and no credential prompt; she grants it with nothing else bound; the loader admits the root, whole, its Grok edge carrying exactly the provided configuration (the destination over https, the value, Grok's attach rule); the use path admits the provided value for a request inside that destination and refuses one outside it (`destination_mismatch`), sending nothing; the whole state is her profile and its revision 1, with no binding row and no entry |
| `account_choices` | in a grant she makes "OpenAI Work" through "Connect your openai.com account" on the app's own need and "Anthropic" through Connect on the Claude dependency's, each key typed in the credential prompt and confirmed with her passkey; on the Vault page she makes "OpenAI Home" through the form's provider choice "openai.com (api_key)", confirmed the same way; reopened, the grant presses OpenAI Work, the openai.com default, on both OpenAI needs with "Change" beside each, and the one Anthropic entry with no "Change" and no picker; she changes the OpenAI dependency's edge to OpenAI Home; the preview names OpenAI Work for the app's own calls, OpenAI Home for the OpenAI edge and Anthropic for the Claude edge, each until revoked, and removes nothing; the whole state is the three entries, each the one her request implies and holding what she typed, the first of each provider its default, and revision 2 with its three binding rows |
| `commit_bindings` | the re-grant opens on the head's bindings, each until revoked; she makes the OpenAI edge "Once (one run)" and the Claude edge "5 minutes", whose until the preview shows five minutes from her click, and presses "GET only" on the OpenAI catalyst's network row, which then gives GET and not POST; revision 3 holds the three bindings standing, once and until that instant, its blob the narrowed grant |
| `lifetime_decisions` | the use path admits the app's own calls, admits the once binding for root A and again for root A, refuses it for root B (`grant_expired`), and admits the five-minute binding; the once row is then consumed by root A and each entry used; after a real wait, bounded at 330 s, until the database's time is past the until, the five-minute binding is refused (`grant_expired`) and the standing one still admitted; the loaded OpenAI edge grants GET alone; nothing is sent |
| `named_prompt` | on a thread of hers, opened in the chat, the fixture announces the setup a launch naming the account "Personal" ends on; the grant prompt opens on the app's own calls with a "Personal" row of that fixed name, both OpenAI entries offered and none pressed; the binding whose until passed opens with no lifetime pressed, the used once binding stays once with "Grant once again" not pressed, and the OpenAI catalyst's network row opens on the head's narrowing, GET given and POST not, "GET only" pressed; she binds OpenAI Home as "Personal" and grants Anthropic until revoked, and narrows nothing herself; the pane then says "Granted. The turn that asked has ended — send your message again to run it."; revision 4 holds the default, the account beside it, the once binding still consumed by root A, and Anthropic until revoked, its blob still GET only on the OpenAI edge; "Personal" now resolves to OpenAI Home; no turn and no execution exists |
| `revocation` | she revokes OpenAI Work on the Vault page, which says one profile loses access at its next run; the loader still admits the root, whole; the next use of the app's own calls is refused (`entry_unavailable`, revoked) and the "Personal" account beside it is still admitted; the whole state holds OpenAI Work revoked |

## Record

Recorded on 2026-10-07 by `run.sh`, Chromium 153, at both viewports, on
`893f2daefbc5a5a23b70a8e3ff57c572de5f1cde` with this proof's four-file
candidate. Every row held at each. After every step
the whole state matched the model, with no field unclassified or missing and
each entry's payload the value she typed. No key, and no digest of a key or
of a typed payload, reached an answer or the record, and each key she typed
was read gone from the page once its entry was made. No turn and no
execution existed at any step. Every use answer named, in its place, the
request it decides, and every previewed lifetime was compared on its own
row's binding.

| Step | desktop (1280×900) | 720×720 | What the record shows |
|---|---|---|---|
| `provided_preview` | held | held | The Grok need read "Provided by local, the app's public configuration, sent only to https://api.x.ai, methods GET, POST, paths /v1/.", with no entry, "Change", "Connect" or account offered. Revision 1 held no binding row. The loader admitted the root on it, whole, its Grok edge's vault exactly the provided configuration. The use path's answers, in order, named `POST https://api.x.ai/v1/chat/completions` admitted and `GET https://api.x.ai/v2/models` refused (`destination_mismatch`). |
| `account_choices` | held | held | Connect's prompts read "Connect your openai.com account" and "Connect your anthropic.com account", prefilled with the provider as the name and the need's host. The Vault page's provider choice offered the providers of the athanor's components' key needs, "openai.com (api_key)" among them. Reopened, the grant pressed OpenAI Work with "Change" on both OpenAI needs, and Anthropic alone with no "Change". After she changed the OpenAI edge, the preview named OpenAI Work, OpenAI Home and Anthropic on their edges, its four rows, Grok's included, each until revoked, and removed nothing. Each key she typed was read gone from the page. Each of the three entries was the one its request implies, holding what she typed; OpenAI Work and Anthropic were their providers' defaults. |
| `commit_bindings` | held | held | The re-grant opened each binding until revoked. The five-minute until she was shown was five minutes from her click, to the second, inside the database's clock around it. The OpenAI row gave GET and not POST, "GET only" pressed. Revision 3 held the three bindings standing, once and until that instant. |
| `lifetime_decisions` | held | held | The uses answered, each naming its request, admitted (the app's own calls, root A), admitted and admitted again (the once binding, root A), `grant_expired` (the once binding, root B) and admitted (the five-minute binding, root A), and the once row then named root A. After a real wait past the previewed expiry at each viewport, the five-minute binding was refused `grant_expired` and the standing one admitted. The loaded OpenAI edge's egress was `api.openai.com`, `https`, GET alone, no private range. |
| `named_prompt` | held | held | The resolution answered `connection_not_granted` and the announcement went out. The prompt opened with a "Personal" row of that fixed name, OpenAI Home and OpenAI Work offered in that order and neither pressed; the Anthropic binding with no lifetime pressed; the OpenAI edge once, "Grant once again" not pressed; and the OpenAI row GET only, as the head held it. Revision 4 held the default, "Personal" on OpenAI Home, the once row still naming root A, and Anthropic until revoked. The pane said "Granted. The turn that asked has ended — send your message again to run it.", and "Personal" resolved to OpenAI Home. |
| `revocation` | held | held | The Vault page said "Entry revoked — 1 profile(s) lose access at next run.". The root was still admitted, whole. The next use of the app's own calls was refused `entry_unavailable` (revoked), and "Personal" was admitted. OpenAI Work was stored revoked. |

## Shown elsewhere

The actual requests, turns and scheduled or webhook execution are shown by
their owners' tests, which this proof does not run. Each test named here is
in the tree.

| Claim | Test file | Test | Owner |
|---|---|---|---|
| E1: real own/provided/instance attached requests reach only the admitted destination, with current instance policy enforced | `apps/cyfr/test/integration/opus/attached_fetch_test.exs` | "own and provided connections reach the pinned upstream without entering the runner"; "destination and egress refusals contact no upstream"; "any admits a consented custom component only within its destination and egress"; "tightening to shipped refuses the next custom component request before claim or upstream contact" | K.K5 |
| E5: named account reaches an actually executed child | `apps/cyfr/test/integration/opus/formula_handler_test.exs` | "a real formula runs two named-account children with distinct upstream credentials" | A.A2 |
| E6: a new grant cannot widen the live turn | `apps/cyfr/test/aqua/loop/loop_test.exs` | "a named-account grant leaves the running turn pinned and only a new turn uses it" | A.A2b |
| E7: once, expiry, scheduled/webhook fire and revocation at use | `apps/cyfr/test/integration/opus/attached_fetch_test.exs`; `apps/cyfr/test/crucible/schedules/scheduler_test.exs`; `apps/cyfr/test/integration/webhook_flow_test.exs` | "once expiry and revocation refuse subsequent roots before an upstream request"; "a scheduled attached request succeeds before expiry and is refused after it"; "a webhook attached request succeeds before expiry and is refused after it" | K.K5 |
| E8: external definitions cannot redirect material; disclosed stdio is explicit | `apps/cyfr/test/emissary/external/provider_test.exs`; `apps/cyfr/test/emissary/external/backends_test.exs` | "an external definition cannot send an entry outside its destination"; "stdio refuses an attach-only entry before starting a backend" | K.K1 |

E1 shows the POST a GET-only grant refuses; this proof shows the committed
grant and the loaded edge alone.

## Declared coverage limit

The unchanged shipped model artifact → production
`Crucible.Host.AttachedFetch` → local provider stand-in composition is
**uncovered**. The current artifacts hard-code provider HTTPS origins
(`seed/components/catalysts/local/openai/1.3.1/src/src/lib.rs:14` and its
peers); `Crucible.Host.Egress.pin/3` has a resolver option which the actual
host never passes (`apps/cyfr/lib/crucible/host/egress.ex:94`). The
existing suites found in `seed_model_catalysts_test.exs`,
`model_contract_test.exs`, `TwoServices`, `tests/worker-image/` and
`Sanctum.Test.ResolverFixture` do not provide an end-to-end local
replacement for that production path. E12 exercises the shipped artifact
with a scripted host; E1/E3 exercise production attachment with controlled
fixture guests. Neither is reported as the full composition, and this proof
starts no runner and sends no request to a provider. No live provider
account or credentials, TLS bypass, endpoint parameter or new
resolver/transport override is used. This is an explicit test-coverage
limitation, not a claim that the composition passed.
