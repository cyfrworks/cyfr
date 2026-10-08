# The instance-entry proof

`run.sh` proves, on the browser harness (`tests/browser/`), that an
instance entry is offered, capped, narrowed, revoked and denied as the
platform administrator sets it in Prism, that its first sign-in binding is
made, and that the administrator enters no athanor they hold no seat in.
The home is one `cyfr` release on a SQLite cell, `home.test`, behind the
harness's HTTPS front (`browser_home`). The platform administrator
(`operator@example.com`, the cell's `CYFR_PLATFORM_ADMIN_EMAILS`) is signed
in by the release fixture's door (`tests/release-boot/fixture.exs`
`person`), and so are Ana and Bea when the proof asks for them, each
through the same sign-in path. `proof.mjs` drives the administrator and Ana
in Chromium's full build, the administrator's confirmations proven with the
passkey Chromium's virtual authenticator makes and registers first, as
`tests/canvas-proof/` proves its vault entry's. It asks `run.sh` for the
home's part of a step through its output directory (`ask-N.json`, answered
`answer-N.json`): a sign-in, and the reads and claims of `fixture.exs`,
which calls the real paths and answers bounded facts. The material an
entry unseals is discarded inside the fixture and never serialized, and the
proof fails if either key, or a digest of one, reaches a page, an answer or
the record.

The harness runs no execution engine and no model, so `run.sh` never starts
a run: an admission is the loader's answer (`Crucible.authority_for/3`'s
path), asked once the person's athanor is filled, as a turn is admitted
only then (`Sanctum.Provisioning.ready/1`), since a sign-in answers before
the fill that mints its consent bootstrap; and a claim is
`Sanctum.InstanceEntries.resolve/4`'s under the member's established
context and the admitted root's node facts, never a request sent to a
provider. Instance-entry claims count resolver uses, not dispatched HTTP
requests.

`VAULT_PROOF_VIEWPORT` is `desktop` (1280×900, the default) or `720x720`;
every step runs at either, and the record names the one it ran at.

The release is built by hand, as `tests/release-boot/release.sh`'s
`release_build` builds it but without fetching dependencies
(`MIX_ENV=prod MIX_BUILD_PATH=_build/prod_release_boot_sqlite
CYFR_DATABASE=sqlite mix compile --warnings-as-errors && mix assets.deploy
&& mix release cyfr --overwrite`), and the proof runs with
`RELEASE_BOOT_SKIP_BUILD=1`. It writes `instance-entry-proof.json` and
`instance-entry-proof.md` into `PROOF_OUT`.

## Steps

Each step is one row; the proof fails when a row does not hold, and stops at
the first row a later one rests on.

After every step the proof compares the whole of what this README names,
as the home holds it, with its own model of it, as one equality after the
same canonical ordering on both sides (members by name, the items of a list
by their own canonical text). The home's side is one read (`fixture.exs`
`state`), which picks no row out of a set:

- every row of the instance's entries (tombstoned ones too), of their listed
  members and of their use, read from the tables whole;
- once Ana has signed in, every profile of `catalyst:local.openai` in her
  athanor, every consent of those profiles, every binding row of those
  consents, and the entries offered to her;
- once Bea has signed in, her row.

The model changes at each step only by what that step did: an entry made,
narrowed, used, revoked; a sign-in; a claim counted; a deny. So a change
made behind the browser to any of these, at any time, fails the next
step, whichever step that is. A step about one object says so in its row,
and passes only if the whole state matches as well. Nothing this README
names is left out of that comparison, and no field of it is dropped: each is
in one of the three classes below.

The model takes only these values from the home, each the decision or
identity it names, never a read of what it is compared with:

- each entry's id, as its card on the Settings page shows it;
- each person's id, athanor and segment, the administrator's included, from
  their sign-in;
- the profile and consent the loader roots Ana's run on (`fixture.exs`
  `admit`);
- what the request implies an entry stores (`requested_digest`);
- what the bootstrap derives for her head (`derived_head`);
- the database's time as the run starts (`clock`), and its time and UTC date
  at the end of each `state` read: the window a stored time is held to, and
  the today a use row's day is;
- the database's next UTC midnight, computed from its clock with each claim,
  which a cap's reset is compared with.

**Every field, classified.** Each field of the named state is in one of
three classes, declared in one table in `proof.mjs` (`FIELDS`), which this
section mirrors:

- **exact:** compared exactly with the model;
- **derived:** compared with a value derived independently of the row,
  which the model holds;
- **bound:** a clock or server-minted value, held to its stated bound.

A field the table does not name fails the step as unclassified, and a named
field a row lacks fails it as missing, so a new column cannot slip in
unchecked.

| Table | Exact | Derived | Bound |
|---|---|---|---|
| `instance_entries` | `name`, `kind`, `provider_hint`, `provenance`, `field_names`, `oauth_endpoints`, `oauth_scopes`, `attach_only`, `status`, `payload_rev`, `audience`, `person_daily`, `total_daily`, `component_policy` | `destination`, `binding_digest`: what the card's request implies (`requested_digest`); `sealed_payload`: the payload its card typed, compared inside the fixture | `id`: the card's; `created_by`: the administrator's sign-in's; `last_used_at`, `inserted_at`, `updated_at`: times |
| `instance_entry_members` | | | `instance_entry_id`: the card's; `user_id`: the sign-in's; `inserted_at`: a time |
| `instance_entry_usage` | `count` | | `instance_entry_id`: the card's; `user_id`: the sign-in's, or the empty id of the entry's own total; `day`: today; `updated_at`: a time |
| `profiles` | `source_ref`, `kind`, `label`, `status` | | `id`, `head_consent_id`: the admission's; `athanor_id`: the sign-in's; `inserted_at`, `updated_at`: times |
| `consents` | `revision`, `scope`, `pinned_version`, `invoke_mode`, `granted_via`, `supersedes_id`, `admitted_origins` | `resolved_policy`, `blob_digest`, `activation`, `shape_digest`, `commit_digest`: what the bootstrap derives (`derived_head`) | `id`, `profile_id`: the admission's; `athanor_id`, `granted_by`: the sign-in's; `granted_at`: a time |
| `consent_vault_refs` | `binding_key`, `scope`, `vault_entry_id`, `via_label`, `lifetime_kind`, `expires_at`, `consumed_by_root` | `binding_digest`: `requested_digest` | `consent_id`: the admission's; `athanor_id`: the sign-in's; `instance_entry_id`: the card's |
| `users` | `email`, `email_verified`, `provider`, `display_name`, `namespace`, `status`, `prefs`, `security_generation` | | `id`, `personal_athanor_id`: the sign-in's; `first_seen_at`, `last_seen_at`, `denied_at`, `created_at`, `updated_at`: times |

The bounds:

- **An id** equals the one its source showed: the entry's card on the
  Settings page, the person's sign-in, or the loader's admission of Ana's
  root.
- **A time** is none where the model holds none (an entry never used, a
  person not denied). Otherwise it lies inside the run's window: from the
  database's time as the run starts to its time at the end of the read that
  returned it.
- **A use row's day** equals the database's today, read in the same call.
  A row on any other day, earlier or later, fails.

**The sealed payload** is derived. The proof passes the fixture the digest
of the payload document each card typed (`Sanctum.Vault.Payload`'s version
3, its one field, no token bundle, in canonical text). The fixture unseals
the stored payload as its owner does (`Sanctum.InstanceEntries`' private
`unseal/1`: the same AAD, `Sanctum.Cipher.decrypt/2` and
`Sanctum.Vault.Payload.decode/1`), hashes the decoded document's canonical
text, and answers only the outcome. So a payload replaced by another validly
sealed value fails as one that unseals to another value than its card typed.
A payload that does not unseal fails with its own sentence, and so does no
payload where the card typed one. Neither the material nor anything derived
from it leaves the fixture. `run.sh` removes each question once it is
answered, so the digests the proof passes never outlive the read. The proof
fails if a key, a digest of a key or a typed payload's digest reaches an
answer, the record or a question left behind.

Ana's offered entries are the owner's decision (`Sanctum.InstanceEntries.offered/1`),
compared exactly as the set of ids the model holds.

**Stored text, byte for byte.** A stored JSON text (an entry's destination and
field names, a head's admitted origins, policy blob and activation) is
compared as the text it is, and never parsed first: its owner reads it with
the first of two duplicate members, and a parse here would keep the last.

- **An entry's destination** is compared with the canonical text of the
  destination its card requested (`Prima.Destination.canonical/1`), and its
  binding digest with the digest over that text.
- **The head's policy blob, its digest, its activation and its shape and
  commit digests** are compared with what the first sign-in's bootstrap
  derives from the request alone. They are built by the owner's own builders
  over the installed catalyst and the requested entry, never read back from
  the head. The loader checks the blob only against the digest in the same
  row, so a widened blob stored with its own digest would otherwise be
  admitted.

**Decisions.** Each answer is compared whole with the decision the step
expects, every field in one of the same three classes:

- **The admission:** whether it admitted, exact; its profile and consent,
  the ids the model takes; the catalyst's node and the activation digest it
  verified, derived: the catalyst's entry in the activation the bootstrap
  derives (`derived_head`).
- **A claim:** its results, exact, a cap's reset compared with the
  database's next UTC midnight; that midnight is the value the model takes.
- **The row binding:** exact.
- **The focus decision:** whether the session is a platform administrator
  and each refusal, exact; the athanor the session is in, the
  administrator's own, as their sign-in named it.

The pages are read for what each person sees: the vault's offered entries,
as the exact set the model holds.

| Step | What holds |
|---|---|
| `create_entry` | the administrator makes Company AI (provider `openai.com`, the provider of the shipped model catalyst `catalyst:local.openai`; destination `https` `api.openai.com`, `POST` and `GET`, `/v1/chat/completions` and `/v1/models`, no port; audience everyone; component policy any; a person cap of 3) and Company Mail (provider `mail.example`, which no shipped catalyst names; destination `https` `api.mail.example`, `POST`, `/v1/send`; audience everyone; no caps) on the Settings card; each key is typed in the system layer's prompt alone, and each `credential_entry` confirmation is proven with the administrator's passkey; the store holds those two entries alone, each whole stored entry the one its card requested, and no page shows a key |
| `first_sign_in` | Ana's first sign-in provisions her athanor, whose bootstrap commits her `catalyst:local.openai` default profile: the whole stored profile is her active owner profile labelled `default`, sourced from the catalyst, headed by the bootstrap's consent; the whole stored head is revision 1, versionless, `open_inert`, admitting the interactive and programmatic origins, granted by Ana via `bootstrap`, superseding nothing; its stored binding rows are exactly one, whole: Company AI on the catalyst's default slot, scope `instance`, standing, at the digest its request implies; the real loader admits that root under her interactive context, on that head, with no run started; her vault's "Provided by this instance" offers exactly both entries and shows no material |
| `claim_cap` | three `resolve/4` claims of Company AI under Ana's context are admitted, each whole answer an admission; her vault then reads "3 requests today" and "Your daily limit is reached; it resets at midnight UTC."; the fourth claim's whole answer is the refusal `connection_cap` with a reset at the database's next UTC midnight; the whole state read after the step holds Company AI's use as two rows, Ana's 3 and the day's 3, each on the database's today, and no other use row |
| `narrow_audience` | Bea signs in once, so the card's people picker lists her; the administrator narrows Company AI from everyone to Bea on the card, whose save sends the audience the card showed (`audience_shown`, the `expected` audience) and needs no prompt; the whole stored entry is the one requested, listed for Bea alone and used; Ana's next claim's whole answer is `not_offered`, her consent's row binding (`Sanctum.Consent.row_binding/3`) answers not offered, whole, and her vault no longer offers it |
| `revoke` | Ana's claim of Company Mail is admitted; the administrator revokes Company Mail on the card; Ana's next claim's whole answer is `entry_unavailable` (revoked); the whole stored entry is the one requested, used and revoked; her vault offers nothing |
| `deny_person` | the administrator denies `bea@example.com` at the door on the Settings page (`door.deny`): the whole stored Company AI is the one requested, listed for no one; Bea's whole stored row is the active one read just before the deny with the three columns a deny commits together (`Sanctum.Tenancy.Users`): denied, a denial time set, and her security generation one above; no stored audience lists her; Company AI's card reads "nobody listed" |
| `admin_focus` | the administrator's athanor switcher, its popover waited for until drawn, links to no athanor of Ana's (no path under her segment, no page naming her athanor as its `a`), nor does the page; a direct visit to Ana's vault lands elsewhere with "You are not a member of that athanor."; Sanctum's focus and refocus of the administrator's session onto Ana's athanor (`Sanctum.Context.focus/2`, `refocus/2`) refuse `not_member` |

## Record

Recorded on 2026-10-05 by `run.sh`, Chromium 153, at both viewports on the
committed source (`7b33b5d9`; this README's Record section is the only later
change). Every row held at each. After every step the whole state matched
the model, with no field unclassified or missing and each entry's payload
the value its card typed. No key, and no digest of a key or of a typed
payload, reached a page, an answer or the record.

| Step | desktop (1280×900) | 720×720 | What the record shows |
|---|---|---|---|
| `create_entry` | held | held | The store held the two entries alone, each whole entry the one its card requested: Company AI `https` `api.openai.com`, `GET` and `POST`, its two paths, no port, a person cap of 3. Each one's stored payload unsealed to the value its card typed, and its times were inside the run's window. Each create's prompt named `instance_entry.create` and was proven with the passkey. |
| `first_sign_in` | held | held | The whole stored profile was Ana's active owner `default` of the catalyst, headed by the bootstrap's consent. The whole head was revision 1, versionless, `open_inert`, admitting `["interactive","programmatic"]`, granted by Ana via `bootstrap`. Its policy blob, blob digest, activation and shape and commit digests were the ones the bootstrap derives from the request. It held one stored binding row, the bootstrap's of Company AI, standing, at its requested digest. The loader admitted the root on that head, on the node and activation digest the derived activation names. The vault offered exactly the two entries. |
| `claim_cap` | held | held | Three admissions. The vault offered Company AI and Company Mail alone and read "3 requests today" and the limit sentence. The fourth claim was refused `connection_cap`, its reset `2026-10-06T00:00:00.000000Z`, the database's next UTC midnight. The use rows read with the state after the step were Ana's 3 and the day's 3, each on the database's today, and no other. |
| `narrow_audience` | held | held | The save sent `audience_shown=everyone`. The whole stored Company AI was the requested entry listed, with one member row, Bea's. Ana's claim and row binding were refused `not_offered`. Her vault offered Company Mail alone. |
| `revoke` | held | held | The claim before was admitted, and the one after refused `entry_unavailable` (revoked). The whole stored Company Mail was the requested entry, used and revoked. Its use rows were Ana's 1 and the day's 1 on the database's today. Her vault offered nothing. |
| `deny_person` | held | held | The whole stored Company AI was the requested entry, with no member row. Bea's whole row was denied, with a denial time inside the run's window and her security generation 2 from 1. The card read "nobody listed". |
| `admin_focus` | held | held | The switcher's popover drew with the administrator's own athanor alone, so there was no row to follow, and no link on the page led into Ana's. The visit landed on the administrator's own chat with "You are not a member of that athanor.". Focus and refocus refused `not_member`, the session staying in the administrator's own athanor. |

## Shown elsewhere

The steps that need an execution engine, a model or a runner are shown by
their owners' tests, which this proof does not run. Each test named here is
in the tree.

| Claim | Test file | Test | Owner |
|---|---|---|---|
| E1: real own/provided/instance attached requests reach only the admitted destination, with current instance policy enforced | `apps/cyfr/test/integration/opus/attached_fetch_test.exs` | "own and provided connections reach the pinned upstream without entering the runner"; "destination and egress refusals contact no upstream"; "any admits a consented custom component only within its destination and egress"; "tightening to shipped refuses the next custom component request before claim or upstream contact" | K.K5 |
| E2: reflected material, runner memory/logs/events/output and positive control | `apps/cyfr/test/integration/opus/attached_fetch_test.exs`; `tests/worker-image/canary.py`; `apps/cyfr/test/integration/opus/secret_audit_test.exs` | "reflected credentials are masked across frames and execution exits"; scenario `credential_canary` (real runner, scripted control plane, with its mandatory positive-control record); "an attached value is audited by field and destination without material" | K.K5 / K.K4 |
| E3: real streamed AQUA turn through an instance entry, cap and revocation | `apps/cyfr/test/integration/opus/model_contract_test.exs` | "an instance entry drives a streamed model turn without exposing its value"; "instance cap and revocation refuse the next model request" | K.K3 |
| E4: bootstrap binding and matching/lifetime decisions | `apps/cyfr/test/sanctum/consent/bootstrap_test.exs`; `apps/sanctum/test/sanctum/instance_entries_test.exs`; `apps/cyfr/test/sanctum/consent/commit_test.exs` | "a newly provisioned athanor binds its sole offered provider entry"; "the fourth claim is refused with its database reset"; "any and shipped enforce the stored component policy at each resolution"; "widening a component policy requires confirmation and rejects a stale write"; "matching and binding lifetimes are committed per edge without implicit disclosure" | A.A0 / U.U1 |
| E10: administrator lacks a seat; stale platform basis cannot issue tenant authority | `apps/cyfr/test/sanctum/context_focus_test.exs`; `apps/sanctum/test/sanctum/issuance_test.exs` | "a platform administrator without a seat cannot focus an athanor"; "a platform membership cannot authorize tenant credential issuance" | U.U0 |

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
