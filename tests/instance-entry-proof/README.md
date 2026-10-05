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
proof fails if either key reaches a page, an answer or the record.

The harness runs no execution engine and no model, so `run.sh` never starts
a run: an admission is the loader's answer (`Crucible.authority_for/3`'s
path), and a claim is `Sanctum.InstanceEntries.resolve/4`'s under the
member's established context and the admitted root's node facts, never a
request sent to a provider. Instance-entry claims count resolver uses, not
dispatched HTTP requests.

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

| Step | What holds |
|---|---|
| `create_entry` | the administrator makes Company AI (provider `openai.com`, the provider of the shipped model catalyst `catalyst:local.openai`; destination `https` `api.openai.com`, `POST` and `GET`, `/v1/chat/completions` and `/v1/models`; audience everyone; component policy any; a person cap of 3) and Company Mail (provider `mail.example`, which no shipped catalyst names; audience everyone) on the Settings card; each key is typed in the system layer's prompt alone, and each `credential_entry` confirmation is proven with the administrator's passkey; the stored entries are as asked and no page shows a key |
| `first_sign_in` | Ana's first sign-in provisions her athanor, whose bootstrap commits Company AI as the instance binding of her `catalyst:local.openai` default profile at the entry's own digest; the real loader admits that root under her interactive context, with no run started; her vault's "Provided by this instance" offers both entries and shows no material |
| `claim_cap` | three `resolve/4` claims of Company AI under Ana's context are admitted; her vault then reads "3 requests today" and "Your daily limit is reached; it resets at midnight UTC."; the fourth claim is refused `connection_cap` with a reset at the database's next UTC midnight, and her count stays 3 |
| `narrow_audience` | Bea signs in once, so the card's people picker lists her; the administrator narrows Company AI from everyone to Bea on the card, whose save sends the audience the card showed (`audience_shown`, the `expected` audience) and needs no prompt; Ana's next claim is refused `not_offered`, her consent's row binding (`Sanctum.Consent.row_binding/3`) answers not offered, and her vault no longer offers it |
| `revoke` | Ana's claim of Company Mail is admitted; the administrator revokes Company Mail on the card; Ana's next claim is refused `entry_unavailable` (revoked), and her vault offers nothing |
| `deny_person` | the administrator denies `bea@example.com` at the door on the Settings page (`door.deny`): Bea's standing is denied, no audience lists her, and Company AI's card reads "nobody listed" |
| `admin_focus` | the administrator's athanor switcher, its popover waited for until drawn, links to no athanor of Ana's (no path under her segment, no page naming her athanor as its `a`), nor does the page; a direct visit to Ana's vault lands elsewhere with "You are not a member of that athanor."; Sanctum's focus and refocus of the administrator's session onto Ana's athanor (`Sanctum.Context.focus/2`, `refocus/2`) refuse `not_member` |

## Record

Recorded on 2026-10-05 by `run.sh`, Chromium 153, at both viewports; every
row held at each, and no key reached a page, an answer or the record.

| Step | desktop (1280×900) | 720×720 | What the record shows |
|---|---|---|---|
| `create_entry` | held | held | both entries stored as asked, Company AI's person cap 3; each create's prompt named `instance_entry.create` and was proven with the passkey |
| `first_sign_in` | held | held | Ana's openai head at revision 1 holds one instance row, scope `instance`, lifetime `standing`, at Company AI's digest; the loader admitted the root under that consent |
| `claim_cap` | held | held | three claims admitted; the vault read "3 requests today" and the limit sentence; the fourth refused `connection_cap`, its reset `2026-10-06T00:00:00Z`, the database's next UTC midnight, and her count stayed 3 |
| `narrow_audience` | held | held | the save sent `audience_shown=everyone`; Company AI listed for Bea alone; Ana's claim refused `not_offered`, her row binding not offered |
| `revoke` | held | held | the claim before admitted; after, refused `entry_unavailable` (revoked); her vault offered nothing |
| `deny_person` | held | held | Bea denied, listed in no audience; Company AI's card read "nobody listed" |
| `admin_focus` | held | held | the switcher's popover drew with the administrator's own athanor alone, and so no row to follow, and no link on the page led into Ana's; the visit landed on the administrator's own chat with "You are not a member of that athanor."; focus and refocus refused `not_member` |

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
