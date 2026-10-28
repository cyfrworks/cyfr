# The handle proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a handle
at the registry carries a sign-in from one CYFR to another and no further:
a person sets up their CYFR with a passkey and claims `@proof`, publishes
their CYFR's address with it, and signs in at another CYFR by typing the
handle; an address published under someone else's handle signs nobody in;
and a ban at the registry retires the person's push token.

The registry is cyfr.run's own, built from the checkout `CYFR_RUN_DIR`
names. CI cannot read that source, so CI never runs this proof; without
`CYFR_RUN_DIR` the script says it did not run and why, and exits 0.

```bash
CYFR_RUN_DIR=<cyfr.run checkout> scripts/heavy-check.sh -- tests/handle-proof/run.sh
```

## What runs

| Part | Name | Configured |
|---|---|---|
| the directory | `dir.test` | a `cyfr` release, `CYFR_DIRECTORY_SERVE=writer`, behind the identity proof's front on `127.77.0.1` |
| A | `a.test` | a `cyfr` release with a `CYFR_SETUP_TOKEN` of its own; enrolls at `dir.test`; `CYFR_REGISTRY_URL=registry.test` |
| B | `b.test` | the same, with its own setup token |
| the registry | `registry.test` | cyfr.run's image, built from `git archive HEAD` of `CYFR_RUN_DIR` by its `Dockerfile`, on a `postgres:16-alpine` of the run's own, with `DOMAIN=registry.test`, `DIRECTORY_URL=https://dir.test` and the run's authority as `DIRECTORY_CA_FILE`, behind a front of the identity proof's kind on `127.77.0.3` |

The CYFRs reach the directory and the registry by name through their
`ERL_INETRC` at addresses listed in `CYFR_PRIVATE_EGRESS_TARGETS`, and trust
the run's authority (`tests/identity-proof/cells.sh`); the registry
resolves `dir.test` through its container's hosts entry. No DNS,
`/etc/hosts`, trust store or other configuration outside the scratch
directory is read or changed. The second identity is cyfr.run's smoke
person (`cmd/smokeid`, built from the same checkout): a key log of its own
at `dir.test`, signing its registry requests itself, as anyone may.

Everything the run starts is removed when it ends, on every exit path, a
signal included: the cells' servers, the fronts, the registry's container
and image, its database's container and its named volume
(`<prefix>cyfr-handle-proof-<pid>-pgdata`), the Playwright container, and
the scratch directory with the run's authority key and every token.
`PROOF_RUN_PREFIX` prefixes every container's and volume's name. The one
exception is the release: it is built through `tests/release-boot/release.sh`
into the shared `_build/prod_release_boot_sqlite` with its reuse stamp,
under heavy-check's exclusive slot, as every other release proof builds it.

## Steps

Chromium runs every step with its virtual WebAuthn authenticator; the
person's passkey for A is copied to the profile that signs in at B, as a
synced passkey is. `proof.mjs` drives the browsers and `run.sh` answers its
asks for the servers' part (`fixture.exs` inside a CYFR, `psql` in the
registry's database, `curl` through the fronts). `models.mjs` holds every
object's model, the comparison and the tamper loop, apart from the
browsers, so the models can be rebuilt from a run's record.

| Step | What holds |
|---|---|
| `setup` | A is set up through `/setup` with a passkey; `@proof` is chosen, which runs the enrollment at `dir.test`, confirmed with the passkey. With the kit shown and not yet acknowledged, the directory holds the genesis, the enrollment attempt is accepted, and the registry holds no `@proof`, no acceptance and no nonce of the identifier; once the kit is acknowledged the attempt completes (a transition from the attempt read before it) and the card claims the handle. A's person, passkey, identity, athanor and both seats (the athanor's and the first person's platform grant) are read whole |
| `publish` | Settings at A publishes A's address with `@proof`; the namespace is the one read at setup with its address and `updated_at` moved, and the signed request added one nonce |
| `allow` | B, set up through `/setup` by its administrator, allows `@proof` in Settings; B's one allowlist entry names A's identifier, labelled `proof`; B's passkey, person, athanor and seats are its administrator's |
| `sign_in` | a fresh profile at B's sign-in page, "I run my own CYFR" with `@proof`, reaches A through the published address, signs in there with the passkey, begins the carry, sees B's code named in A's confirmation, and B admits the person as A's identifier, landing them on B's sign-in page as signed in with no athanor there; B's athanors and seats are still its administrator's alone, and the person's session holds the token the browser's cookie carries |
| `wrong_identity` | a second identity enrolls at `dir.test`, claims `@other` and publishes A's address with it; the same profile at B with `@other` reaches A, whose carry names A's identifier, and B shows `wrong_identity`'s sentence, which no other sign-in refusal of `Prima.Refusal` shares, admitting nobody and making no session. No wrong-destination request is made: a wrong-destination refusal needs a carry for another destination, which the proof does not drive |
| `sync` | Sync push tokens at A, confirmed with the passkey, stores one push token for `@proof`, whose digest is the registry's token for it, made by A's identifier |
| `ban` | the registry's operator bans `@proof`'s owner through the admin pages; the ban revokes the token in its transaction, the token presented to the registry is refused, A's next sync shows `banned`'s sentence and records no nonce; then every object read in the run is read again and held to what was read before |
| `readme` | this file's field table holds exactly the rows the proof's models print |

## Whole objects

After each step the proof reads every object the step claims whole: a
CYFR's table, all its columns, through `fixture.exs` (bytes as base64,
printable bytes as text); a registry table's rows as PostgreSQL's
`row_to_json` writes them; an answer of the registry as its status and
body. Each object is compared with a model in which every field is one of
four classes:

- **exact**: the value the step must leave, or a value this run read
  before and holds from then on;
- **derived**: a value read from another source, independent of the row:
  the browser's authenticator (a passkey's credential id, count, and the
  COSE key its private key gives), the browser's session cookie (the
  token's SHA-256 and first 8 characters, read inside the CYFR that set
  it), the kit's lines, the directory's stored genesis (the identifier is
  its hash; the keys are its keys; a genesis's key and recovery epochs are
  its own hash), the run's admin account, the other store's digest;
- **captured**: a value the server generated, read here for the first
  time, that no other source names (a row id, a registration digest, a
  nonce): held to its shape at its first read and exact at every later read;
- **bound**: a time the server stamps, inside a window whose two ends are
  the proof's own clock readings around the step (5 ms either side for the
  stamp's resolution); a session's `expires_at` is derived exactly, as its
  `inserted_at` plus `session_ttl_hours`.

A sealed key is held once its relationship is checked: it opens, inside
the CYFR that sealed it, to the private half of the public key beside it or
of the genesis's key. A field the model does not classify, or a classified
field the object lacks, fails the comparison, and the proof keeps going so
one run reports every mismatch. A list's rows are matched by what each
holds (a seat by its scope, a nonce by its bytes, a log entry by its
identifier), so a missing or extra row fails it.

Once a comparison holds, each stored field is shown failing: written behind
the browsers' back to a value its model refuses (a byte field with one byte
flipped, an id or digest another valid one of its kind, a first read's
field outside its shape, a time outside its window), read again, and the
comparison must refuse that field read back with the written value, or the
row must leave a read filtered by that very field. The write has the
database's own checks off for it alone (on a CYFR, SQLite's foreign keys
and CHECK constraints; on the registry, foreign keys for the transaction
and the table's CHECK constraints, dropped by the tamper and added back
from their saved definitions by the restore). The restore runs however the
comparison ends, and after it the whole table, and the CYFR's whole schema
or every constraint on the registry's table as PostgreSQL prints it, must
be what they were before the first tamper, and the registry's session back
to `origin`.

An answer's fields are shown failing through the stored field that makes
each: its `status` by reserving the namespace (cyfr.run
`internal/api/handles.go:31`), its identifier and address through the
namespace's owner and address, the refused token's status and body through
the token's `revoked_at` (whose use the restore writes back too). The
sealed credential's members are each changed and sealed again alone. An
answer's `handle`, `protocol`, `registry` and `directory`, which no stored
field makes, and both refusal sentences' `shown` and `shared_with`, are
each shown failing by a control: a copy of the object with that one field
corrupted, which the comparison must refuse on that field.

At the end every object is read again and held to what was read before,
with the fields later steps move (a passkey's count, a person's
`last_seen_at`, the registry's `read_at`) each held to its own source or
window; a captured field's loop runs there, where it is exact, and every
other field's ran at its first read. The run prints how many tamper loops
ran, how many controls were refused, and names each field with no loop
there and why.

## Fields

The table the models print (`handle-proof-fields.md` in the output), one
row per field of each row of each step's objects:

| object | field | class | value, source or bound |
|---|---|---|---|
| setup:a.passkeys | id | captured | a new psk_ id |
| setup:a.passkeys | user_id | captured | a new usr_ id |
| setup:a.passkeys | credential_id | derived | the credential the browser's authenticator holds for a.test, base64url |
| setup:a.passkeys | rp_id | exact | `"a.test"` |
| setup:a.passkeys | relying_home | exact | `"https://a.test"` |
| setup:a.passkeys | public_key | derived | the authenticator's key, as the COSE map CYFR stores (term_to_binary) |
| setup:a.passkeys | sign_count | derived | the authenticator's count for that credential |
| setup:a.passkeys | identity_recovery_epoch | exact | `null` |
| setup:a.passkeys | state | exact | `"active"` |
| setup:a.passkeys | registration_digest | captured | the registration's digest: a new sha256: digest |
| setup:a.passkeys | possession_verified | exact | `1` |
| setup:a.passkeys | expires_at | exact | `null` |
| setup:a.passkeys | admin_confirmation_id | exact | `null` |
| setup:a.passkeys | activated_at | bound | a time inside setup at A |
| setup:a.passkeys | revoked_at | exact | `null` |
| setup:a.passkeys | inserted_at | bound | a time inside setup at A |
| setup:a.passkeys | updated_at | bound | a time inside setup at A |
| setup:dir.identity_log_entries | id | captured | a new ile_ id |
| setup:dir.identity_log_entries | identifier | derived | the identifier the signer's genesis hashes to |
| setup:dir.identity_log_entries | seq | exact | `0` |
| setup:dir.identity_log_entries | kind | exact | `"genesis"` |
| setup:dir.identity_log_entries | entry_hash | derived | the entry's bytes, hashed |
| setup:dir.identity_log_entries | prev_hash | exact | `null` |
| setup:dir.identity_log_entries | entry | derived | the genesis its signer sent, whose hash is the identifier |
| setup:dir.identity_log_entries | request_id | exact | `null` |
| setup:dir.identity_log_entries | request_digest | exact | `null` |
| setup:dir.identity_log_entries | outcome | exact | `"accepted"` |
| setup:dir.identity_log_entries | outcome_body | exact | `null` |
| setup:dir.identity_log_entries | bytes | derived | the entry's length |
| setup:dir.identity_log_entries | inserted_at | bound | a time inside the enrollment, to the kit shown |
| setup:pre:a.identity_attempts | id | captured | a new iat_ id |
| setup:pre:a.identity_attempts | kind | exact | `"enrollment"` |
| setup:pre:a.identity_attempts | request_id | captured | a new request id, req_ and 32 hexadecimal digits |
| setup:pre:a.identity_attempts | user_id | derived | A's passkey's person |
| setup:pre:a.identity_attempts | identifier | derived | the kit's identifier line, as the browser showed it |
| setup:pre:a.identity_attempts | directory_url | exact | `"https://dir.test"` |
| setup:pre:a.identity_attempts | phase | exact | `"accepted"` |
| setup:pre:a.identity_attempts | genesis | derived | the directory's stored genesis |
| setup:pre:a.identity_attempts | entry | exact | `null` |
| setup:pre:a.identity_attempts | entry_hash | exact | `null` |
| setup:pre:a.identity_attempts | expected_head | exact | `null` |
| setup:pre:a.identity_attempts | expected_revision | exact | `null` |
| setup:pre:a.identity_attempts | request_digest | derived | the genesis's hash: an enrollment's request is its genesis |
| setup:pre:a.identity_attempts | token_digest | exact | `null` |
| setup:pre:a.identity_attempts | staged_live_public_key | exact | `null`: the accepted enrollment moved its staged keys onto the identity row |
| setup:pre:a.identity_attempts | staged_operational_public_key | exact | `null` |
| setup:pre:a.identity_attempts | staged_live_key_sealed | exact | `null` |
| setup:pre:a.identity_attempts | staged_operational_key_sealed | exact | `null` |
| setup:pre:a.identity_attempts | kit_seed_sealed | captured | the kit's seed, sealed until the kit is acknowledged: new sealed bytes |
| setup:pre:a.identity_attempts | kit_acknowledged_at | exact | `null` |
| setup:pre:a.identity_attempts | outcome | exact | `"accepted"` |
| setup:pre:a.identity_attempts | reproof_challenge_digest | exact | `null` |
| setup:pre:a.identity_attempts | reproof_expires_at | exact | `null` |
| setup:pre:a.identity_attempts | revision | exact | `3`: the attempt as its enrollment's acceptance leaves it |
| setup:pre:a.identity_attempts | inserted_at | bound | a time inside the enrollment, to the kit shown |
| setup:pre:a.identity_attempts | updated_at | bound | a time inside the enrollment, to the kit shown |
| setup:a.identity_attempts | directory_url | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | entry | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | entry_hash | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | expected_head | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | expected_revision | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | genesis | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | id | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | identifier | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | inserted_at | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | kind | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | kit_acknowledged_at | bound | a time inside the kit's acknowledgement, to @proof claimed |
| setup:a.identity_attempts | kit_seed_sealed | exact | `null`: the kit's seed is dropped once the kit is acknowledged |
| setup:a.identity_attempts | outcome | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | phase | exact | `"completed"` |
| setup:a.identity_attempts | reproof_challenge_digest | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | reproof_expires_at | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | request_digest | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | request_id | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | revision | exact | the revision read before the acknowledgement, plus one |
| setup:a.identity_attempts | staged_live_key_sealed | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | staged_live_public_key | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | staged_operational_key_sealed | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | staged_operational_public_key | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | token_digest | exact | as read before the kit's acknowledgement |
| setup:a.identity_attempts | updated_at | bound | a time inside the kit's acknowledgement, to @proof claimed |
| setup:a.identity_attempts | user_id | exact | as read before the kit's acknowledgement |
| setup:a.athanors | id | captured | a new ath_ id |
| setup:a.athanors | kind | exact | `"person"` |
| setup:a.athanors | name | exact | `"Me"` |
| setup:a.athanors | slug | exact | `"me"` |
| setup:a.athanors | owner_user_id | derived | A's person |
| setup:a.athanors | status | exact | `"active"` |
| setup:a.athanors | archived_at | exact | `null` |
| setup:a.athanors | created_by | derived | A's person |
| setup:a.athanors | settings | exact | `null` |
| setup:a.athanors | provisioned_at | bound | a time inside setup at A up to setup:a.athanors's read |
| setup:a.athanors | provisioning_failed_at | exact | `null` |
| setup:a.athanors | provisioning_failure | exact | `null` |
| setup:a.athanors | roster | exact | `"open"` |
| setup:a.athanors | pair_key | exact | `null` |
| setup:a.athanors | security_generation | exact | `1` |
| setup:a.athanors | created_at | bound | a time inside setup at A |
| setup:a.athanors | updated_at | bound | a time inside setup at A up to setup:a.athanors's read |
| setup:a.memberships[0] | id | captured | a new mem_ id |
| setup:a.memberships[0] | user_id | derived | the person |
| setup:a.memberships[0] | person_identifier | exact | `null` |
| setup:a.memberships[0] | scope | exact | `"platform"` |
| setup:a.memberships[0] | status | exact | `"active"` |
| setup:a.memberships[0] | added_by | exact | `null` |
| setup:a.memberships[0] | athanor_id | exact | `null` |
| setup:a.memberships[0] | created_at | bound | a time inside setup at A |
| setup:a.memberships[0] | updated_at | bound | a time inside setup at A |
| setup:a.memberships[1] | id | captured | a new mem_ id |
| setup:a.memberships[1] | user_id | derived | the person |
| setup:a.memberships[1] | person_identifier | exact | `null` |
| setup:a.memberships[1] | scope | exact | `"athanor"` |
| setup:a.memberships[1] | status | exact | `"active"` |
| setup:a.memberships[1] | added_by | exact | `null` |
| setup:a.memberships[1] | athanor_id | derived | the person's one athanor |
| setup:a.memberships[1] | created_at | bound | a time inside setup at A |
| setup:a.memberships[1] | updated_at | bound | a time inside setup at A |
| setup:a.users | id | derived | the user A's passkey names |
| setup:a.users | email | exact | `null` |
| setup:a.users | email_verified | exact | `null` |
| setup:a.users | admission | exact | `"setup"` |
| setup:a.users | display_name | exact | `null` |
| setup:a.users | namespace | exact | `"proof"` |
| setup:a.users | personal_athanor_id | derived | A's one athanor |
| setup:a.users | status | exact | `"active"` |
| setup:a.users | prefs | exact | `"{}"`: Newcomer's empty document (newcomer.ex:264), the cleared handle_wanted removed |
| setup:a.users | first_seen_at | bound | a time inside setup at A |
| setup:a.users | last_seen_at | bound | a time inside setup at A up to setup:a.users's read |
| setup:a.users | denied_at | exact | `null` |
| setup:a.users | security_generation | exact | `1` |
| setup:a.users | created_at | bound | a time inside setup at A |
| setup:a.users | updated_at | bound | a time inside setup at A up to setup:a.users's read |
| setup:a.person_identities | id | captured | a new pid_ id |
| setup:a.person_identities | user_id | derived | A's passkey's person |
| setup:a.person_identities | identifier | derived | the kit's identifier line |
| setup:a.person_identities | provenance | exact | `"local"` |
| setup:a.person_identities | enrollment | exact | `"enrolled"` |
| setup:a.person_identities | live_public_key | derived | the directory's genesis's live key |
| setup:a.person_identities | operational_public_key | derived | the directory's genesis's operational key |
| setup:a.person_identities | live_key_sealed | derived | opens, in A, to the genesis's live key |
| setup:a.person_identities | operational_key_sealed | derived | opens, in A, to the genesis's operational key |
| setup:a.person_identities | genesis_hash | derived | the directory's genesis, hashed |
| setup:a.person_identities | head_hash | derived | the directory's one entry |
| setup:a.person_identities | directory_url | exact | `"https://dir.test"` |
| setup:a.person_identities | first_method_at | bound | a time inside setup at A |
| setup:a.person_identities | revision | exact | `4`: 1 at insertion, then first_method! (person_identities.ex:233), enrolling! (:145) and enrolled! (:174), each one step (:259) |
| setup:a.person_identities | inserted_at | bound | a time inside setup at A |
| setup:a.person_identities | updated_at | bound | a time inside the enrollment, to the kit shown |
| setup:registry.namespaces[proof] | slug | exact | `"proof"` |
| setup:registry.namespaces[proof] | kind | exact | `"personal"` |
| setup:registry.namespaces[proof] | reserved | exact | `false` |
| setup:registry.namespaces[proof] | domain_verified | exact | `false` |
| setup:registry.namespaces[proof] | verify_token | exact | `null` |
| setup:registry.namespaces[proof] | verified_at | exact | `null` |
| setup:registry.namespaces[proof] | last_checked_at | exact | `null` |
| setup:registry.namespaces[proof] | consecutive_failures | exact | `0` |
| setup:registry.namespaces[proof] | display_name | exact | `null` |
| setup:registry.namespaces[proof] | expires_at | exact | `null` |
| setup:registry.namespaces[proof] | created_at | bound | a time inside the kit's acknowledgement, to @proof claimed |
| setup:registry.namespaces[proof] | updated_at | bound | a time inside the kit's acknowledgement, to @proof claimed |
| setup:registry.namespaces[proof] | owner_identifier | derived | the kit's identifier |
| setup:registry.namespaces[proof] | address | exact | `null` |
| setup:registry.namespaces[proof] | reserved_reason | exact | `null` |
| setup:registry.identity_heads[a] | identifier | derived | the identity's genesis, hashed |
| setup:registry.identity_heads[a] | head | derived | the genesis's hash: one entry, so the head (`Prima.Identity`) |
| setup:registry.identity_heads[a] | entries | exact | `1` |
| setup:registry.identity_heads[a] | recovery_epoch | derived | a genesis's own hash (`Prima.Identity`, identity.ex:1150) |
| setup:registry.identity_heads[a] | key_epoch | derived | a genesis's own hash (`Prima.Identity`, identity.ex:1150) |
| setup:registry.identity_heads[a] | read_at | bound | a time inside the kit's acknowledgement, to @proof claimed |
| setup:registry.policy_acceptances[a] | id | captured | an acceptance id: a new UUID, not the nil UUID |
| setup:registry.policy_acceptances[a] | policy_version | derived | the registry's GET /v1/legal/version |
| setup:registry.policy_acceptances[a] | accepted_at | bound | a time inside the kit's acknowledgement, to @proof claimed |
| setup:registry.policy_acceptances[a] | ip_address | exact | `"::ffff:127.0.0.1"`: the front's forwarded loopback address, as PostgreSQL's inet stores it |
| setup:registry.policy_acceptances[a] | user_agent | derived | the signer's HTTP client: Req's default for a CYFR (req 0.7.5, mix.lock), the run's curl for the second identity |
| setup:registry.policy_acceptances[a] | identifier | derived | the signer's identifier |
| setup:registry.policy_acceptances[a] | former_identity | exact | `null` |
| setup:registry.request_nonces[a][0] | identifier | derived | the signer's identifier |
| setup:registry.request_nonces[a][0] | nonce | captured | 16 new bytes |
| setup:registry.request_nonces[a][0] | expires_at | bound | a time inside the kit's acknowledgement, to @proof claimed, plus the 120 s a signed request lives |
| setup:registry.request_nonces[a][1] | identifier | derived | the signer's identifier |
| setup:registry.request_nonces[a][1] | nonce | captured | 16 new bytes |
| setup:registry.request_nonces[a][1] | expires_at | bound | a time inside the kit's acknowledgement, to @proof claimed, plus the 120 s a signed request lives |
| setup:handle_answer[proof] | status | exact | `200` |
| setup:handle_answer[proof] | protocol | exact | `"cyfr-handle/v1"` |
| setup:handle_answer[proof] | registry | exact | `"registry.test"` |
| setup:handle_answer[proof] | handle | exact | `"proof"` |
| setup:handle_answer[proof] | identifier | derived | the owner's genesis, hashed |
| setup:handle_answer[proof] | directory | exact | `"https://dir.test"` |
| publish:registry.namespaces[proof] | slug | exact | as read at setup |
| publish:registry.namespaces[proof] | kind | exact | as read at setup |
| publish:registry.namespaces[proof] | reserved | exact | as read at setup |
| publish:registry.namespaces[proof] | domain_verified | exact | as read at setup |
| publish:registry.namespaces[proof] | verify_token | exact | as read at setup |
| publish:registry.namespaces[proof] | verified_at | exact | as read at setup |
| publish:registry.namespaces[proof] | last_checked_at | exact | as read at setup |
| publish:registry.namespaces[proof] | consecutive_failures | exact | as read at setup |
| publish:registry.namespaces[proof] | display_name | exact | as read at setup |
| publish:registry.namespaces[proof] | expires_at | exact | as read at setup |
| publish:registry.namespaces[proof] | created_at | exact | as read at setup |
| publish:registry.namespaces[proof] | updated_at | bound | a time inside the publication |
| publish:registry.namespaces[proof] | owner_identifier | exact | as read at setup |
| publish:registry.namespaces[proof] | address | exact | `"https://a.test"` |
| publish:registry.namespaces[proof] | reserved_reason | exact | as read at setup |
| publish:handle_answer[proof] | status | exact | `200` |
| publish:handle_answer[proof] | protocol | exact | `"cyfr-handle/v1"` |
| publish:handle_answer[proof] | registry | exact | `"registry.test"` |
| publish:handle_answer[proof] | handle | exact | `"proof"` |
| publish:handle_answer[proof] | identifier | derived | the owner's genesis, hashed |
| publish:handle_answer[proof] | directory | exact | `"https://dir.test"` |
| publish:handle_answer[proof] | address | exact | `"https://a.test"` |
| publish:registry.request_nonces[a][0] | identifier | exact | as read at setup |
| publish:registry.request_nonces[a][0] | nonce | exact | as read at setup |
| publish:registry.request_nonces[a][0] | expires_at | exact | as read at setup |
| publish:registry.request_nonces[a][1] | identifier | exact | as read at setup |
| publish:registry.request_nonces[a][1] | nonce | exact | as read at setup |
| publish:registry.request_nonces[a][1] | expires_at | exact | as read at setup |
| publish:registry.request_nonces[a][2] | identifier | derived | the signer's identifier |
| publish:registry.request_nonces[a][2] | nonce | captured | 16 new bytes |
| publish:registry.request_nonces[a][2] | expires_at | bound | a time inside the publication, plus the 120 s a signed request lives |
| publish:registry.identity_heads[a] | identifier | exact | as read at setup |
| publish:registry.identity_heads[a] | head | exact | as read at setup |
| publish:registry.identity_heads[a] | entries | exact | as read at setup |
| publish:registry.identity_heads[a] | recovery_epoch | exact | as read at setup |
| publish:registry.identity_heads[a] | key_epoch | exact | as read at setup |
| publish:registry.identity_heads[a] | read_at | bound | as read at setup, or a time inside the publication |
| allow:b.passkeys | id | captured | a new psk_ id |
| allow:b.passkeys | user_id | captured | a new usr_ id |
| allow:b.passkeys | credential_id | derived | the credential the administrator's authenticator holds for b.test, base64url |
| allow:b.passkeys | rp_id | exact | `"b.test"` |
| allow:b.passkeys | relying_home | exact | `"https://b.test"` |
| allow:b.passkeys | public_key | derived | the administrator's authenticator's key, as the COSE map CYFR stores |
| allow:b.passkeys | sign_count | derived | the authenticator's count for that credential |
| allow:b.passkeys | identity_recovery_epoch | exact | `null` |
| allow:b.passkeys | state | exact | `"active"` |
| allow:b.passkeys | registration_digest | captured | the registration's digest: a new sha256: digest |
| allow:b.passkeys | possession_verified | exact | `1` |
| allow:b.passkeys | expires_at | exact | `null` |
| allow:b.passkeys | admin_confirmation_id | exact | `null` |
| allow:b.passkeys | activated_at | bound | a time inside setup at B |
| allow:b.passkeys | revoked_at | exact | `null` |
| allow:b.passkeys | inserted_at | bound | a time inside setup at B |
| allow:b.passkeys | updated_at | bound | a time inside setup at B |
| allow:b.athanors | id | captured | a new ath_ id |
| allow:b.athanors | kind | exact | `"person"` |
| allow:b.athanors | name | exact | `"Me"` |
| allow:b.athanors | slug | exact | `"me"` |
| allow:b.athanors | owner_user_id | derived | B's administrator |
| allow:b.athanors | status | exact | `"active"` |
| allow:b.athanors | archived_at | exact | `null` |
| allow:b.athanors | created_by | derived | B's administrator |
| allow:b.athanors | settings | exact | `null` |
| allow:b.athanors | provisioned_at | bound | a time inside setup at B up to allow:b.athanors's read |
| allow:b.athanors | provisioning_failed_at | exact | `null` |
| allow:b.athanors | provisioning_failure | exact | `null` |
| allow:b.athanors | roster | exact | `"open"` |
| allow:b.athanors | pair_key | exact | `null` |
| allow:b.athanors | security_generation | exact | `1` |
| allow:b.athanors | created_at | bound | a time inside setup at B |
| allow:b.athanors | updated_at | bound | a time inside setup at B up to allow:b.athanors's read |
| allow:b.memberships[0] | id | captured | a new mem_ id |
| allow:b.memberships[0] | user_id | derived | the person |
| allow:b.memberships[0] | person_identifier | exact | `null` |
| allow:b.memberships[0] | scope | exact | `"platform"` |
| allow:b.memberships[0] | status | exact | `"active"` |
| allow:b.memberships[0] | added_by | exact | `null` |
| allow:b.memberships[0] | athanor_id | exact | `null` |
| allow:b.memberships[0] | created_at | bound | a time inside setup at B |
| allow:b.memberships[0] | updated_at | bound | a time inside setup at B |
| allow:b.memberships[1] | id | captured | a new mem_ id |
| allow:b.memberships[1] | user_id | derived | the person |
| allow:b.memberships[1] | person_identifier | exact | `null` |
| allow:b.memberships[1] | scope | exact | `"athanor"` |
| allow:b.memberships[1] | status | exact | `"active"` |
| allow:b.memberships[1] | added_by | exact | `null` |
| allow:b.memberships[1] | athanor_id | derived | the person's one athanor |
| allow:b.memberships[1] | created_at | bound | a time inside setup at B |
| allow:b.memberships[1] | updated_at | bound | a time inside setup at B |
| allow:b.users | id | derived | the user B's administrator's passkey names |
| allow:b.users | email | exact | `null` |
| allow:b.users | email_verified | exact | `null` |
| allow:b.users | admission | exact | `"setup"` |
| allow:b.users | display_name | exact | `null` |
| allow:b.users | namespace | exact | `null` |
| allow:b.users | personal_athanor_id | derived | B's one athanor |
| allow:b.users | status | exact | `"active"` |
| allow:b.users | prefs | exact | `"{}"`: Newcomer's empty document (newcomer.ex:264), the cleared handle_wanted removed |
| allow:b.users | first_seen_at | bound | a time inside setup at B |
| allow:b.users | last_seen_at | bound | a time inside setup at B up to allow:b.users's read |
| allow:b.users | denied_at | exact | `null` |
| allow:b.users | security_generation | exact | `1` |
| allow:b.users | created_at | bound | a time inside setup at B |
| allow:b.users | updated_at | bound | a time inside setup at B up to allow:b.users's read |
| allow:b.server_allowlist | id | captured | a new door_ id |
| allow:b.server_allowlist | kind | exact | `"identifier"` |
| allow:b.server_allowlist | value | derived | the identifier @proof names at the registry (A's kit) |
| allow:b.server_allowlist | effect | exact | `"allow"` |
| allow:b.server_allowlist | status | exact | `"allowed"` |
| allow:b.server_allowlist | requested_by | exact | `null` |
| allow:b.server_allowlist | added_by | derived | B's administrator |
| allow:b.server_allowlist | note | exact | `null` |
| allow:b.server_allowlist | label | exact | `"proof"` |
| allow:b.server_allowlist | created_at | bound | a time inside the allow |
| allow:b.server_allowlist | updated_at | bound | a time inside the allow |
| sign_in:b.person_identities[0] | id | captured | a new pid_ id |
| sign_in:b.person_identities[0] | user_id | derived | B's administrator |
| sign_in:b.person_identities[0] | identifier | exact | `null` |
| sign_in:b.person_identities[0] | provenance | exact | `"local"` |
| sign_in:b.person_identities[0] | enrollment | exact | `"none"` |
| sign_in:b.person_identities[0] | live_public_key | derived | the public half of the sealed live key, opened in B |
| sign_in:b.person_identities[0] | live_key_sealed | derived | opens, in B, to the live public key beside it |
| sign_in:b.person_identities[0] | operational_public_key | derived | the public half of the sealed operational key, opened in B |
| sign_in:b.person_identities[0] | operational_key_sealed | derived | opens, in B, to the operational public key beside it |
| sign_in:b.person_identities[0] | genesis_hash | exact | `null` |
| sign_in:b.person_identities[0] | head_hash | exact | `null` |
| sign_in:b.person_identities[0] | directory_url | exact | `null` |
| sign_in:b.person_identities[0] | first_method_at | bound | a time inside setup at B |
| sign_in:b.person_identities[0] | revision | exact | `2`: 1 at insertion, then first_method! (person_identities.ex:233) |
| sign_in:b.person_identities[0] | inserted_at | bound | a time inside setup at B |
| sign_in:b.person_identities[0] | updated_at | bound | a time inside setup at B |
| sign_in:b.person_identities[1] | id | captured | a new pid_ id |
| sign_in:b.person_identities[1] | user_id | captured | a new usr_ id |
| sign_in:b.person_identities[1] | identifier | derived | A's kit |
| sign_in:b.person_identities[1] | provenance | exact | `"remote"` |
| sign_in:b.person_identities[1] | enrollment | exact | `"enrolled"` |
| sign_in:b.person_identities[1] | live_public_key | exact | `null`: B keeps no copy of a remote person's keys; it reads them at the directory |
| sign_in:b.person_identities[1] | operational_public_key | exact | `null` |
| sign_in:b.person_identities[1] | live_key_sealed | exact | `null` |
| sign_in:b.person_identities[1] | operational_key_sealed | exact | `null` |
| sign_in:b.person_identities[1] | genesis_hash | derived | the directory's genesis, hashed |
| sign_in:b.person_identities[1] | head_hash | derived | the directory's one entry |
| sign_in:b.person_identities[1] | directory_url | exact | `"https://dir.test"` |
| sign_in:b.person_identities[1] | first_method_at | exact | `null` |
| sign_in:b.person_identities[1] | revision | exact | `1` |
| sign_in:b.person_identities[1] | inserted_at | bound | a time inside the sign-in at B |
| sign_in:b.person_identities[1] | updated_at | bound | a time inside the sign-in at B |
| sign_in:b.users[0] | admission | exact | as read at allow |
| sign_in:b.users[0] | created_at | exact | as read at allow |
| sign_in:b.users[0] | denied_at | exact | as read at allow |
| sign_in:b.users[0] | display_name | exact | as read at allow |
| sign_in:b.users[0] | email | exact | as read at allow |
| sign_in:b.users[0] | email_verified | exact | as read at allow |
| sign_in:b.users[0] | first_seen_at | exact | as read at allow |
| sign_in:b.users[0] | id | exact | as read at allow |
| sign_in:b.users[0] | last_seen_at | bound | as read at allow, or a time inside the sign-in at B |
| sign_in:b.users[0] | namespace | exact | as read at allow |
| sign_in:b.users[0] | personal_athanor_id | exact | as read at allow |
| sign_in:b.users[0] | prefs | exact | as read at allow |
| sign_in:b.users[0] | security_generation | exact | as read at allow |
| sign_in:b.users[0] | status | exact | as read at allow |
| sign_in:b.users[0] | updated_at | bound | as read at allow, or a time inside the sign-in at B |
| sign_in:b.users[1] | id | derived | B's identity row for A's identifier |
| sign_in:b.users[1] | email | exact | `null` |
| sign_in:b.users[1] | email_verified | exact | `null` |
| sign_in:b.users[1] | admission | exact | `"remote"` |
| sign_in:b.users[1] | display_name | exact | `null` |
| sign_in:b.users[1] | namespace | exact | `null` |
| sign_in:b.users[1] | personal_athanor_id | exact | `null` |
| sign_in:b.users[1] | status | exact | `"active"` |
| sign_in:b.users[1] | prefs | exact | `"{}"`: Newcomer's empty document (newcomer.ex:264) |
| sign_in:b.users[1] | first_seen_at | bound | a time inside the sign-in at B |
| sign_in:b.users[1] | last_seen_at | bound | a time inside the sign-in at B up to sign_in:b.users's read |
| sign_in:b.users[1] | denied_at | exact | `null` |
| sign_in:b.users[1] | security_generation | exact | `1` |
| sign_in:b.users[1] | created_at | bound | a time inside the sign-in at B |
| sign_in:b.users[1] | updated_at | bound | a time inside the sign-in at B up to sign_in:b.users's read |
| sign_in:b.sessions[proof] | id | captured | a new ses_ id |
| sign_in:b.sessions[proof] | token_hash | derived | the SHA-256 of the session token the browser's cookie carries |
| sign_in:b.sessions[proof] | token_prefix | derived | the first 8 characters of that token |
| sign_in:b.sessions[proof] | user_id | derived | B's identity row for A's identifier |
| sign_in:b.sessions[proof] | email | exact | `null` |
| sign_in:b.sessions[proof] | provider | exact | `"cyfr"`: the CYFR identity kind, as `CyfrDoor.context/1` mints it (cyfr_door.ex:509) |
| sign_in:b.sessions[proof] | expires_at | derived | inserted_at plus session_ttl_hours (Sanctum.Session) |
| sign_in:b.sessions[proof] | athanor_id | exact | `null` |
| sign_in:b.sessions[proof] | identity_key_epoch | derived | a genesis's key epoch, its own hash |
| sign_in:b.sessions[proof] | cli_machine | exact | `null` |
| sign_in:b.sessions[proof] | inserted_at | bound | a time inside the sign-in at B |
| sign_in:b.athanors | archived_at | exact | as read at allow |
| sign_in:b.athanors | created_at | exact | as read at allow |
| sign_in:b.athanors | created_by | exact | as read at allow |
| sign_in:b.athanors | id | exact | as read at allow |
| sign_in:b.athanors | kind | exact | as read at allow |
| sign_in:b.athanors | name | exact | as read at allow |
| sign_in:b.athanors | owner_user_id | exact | as read at allow |
| sign_in:b.athanors | pair_key | exact | as read at allow |
| sign_in:b.athanors | provisioned_at | exact | as read at allow |
| sign_in:b.athanors | provisioning_failed_at | exact | as read at allow |
| sign_in:b.athanors | provisioning_failure | exact | as read at allow |
| sign_in:b.athanors | roster | exact | as read at allow |
| sign_in:b.athanors | security_generation | exact | as read at allow |
| sign_in:b.athanors | settings | exact | as read at allow |
| sign_in:b.athanors | slug | exact | as read at allow |
| sign_in:b.athanors | status | exact | as read at allow |
| sign_in:b.athanors | updated_at | exact | as read at allow |
| sign_in:b.memberships[0] | added_by | exact | as read at allow |
| sign_in:b.memberships[0] | athanor_id | exact | as read at allow |
| sign_in:b.memberships[0] | created_at | exact | as read at allow |
| sign_in:b.memberships[0] | id | exact | as read at allow |
| sign_in:b.memberships[0] | person_identifier | exact | as read at allow |
| sign_in:b.memberships[0] | scope | exact | as read at allow |
| sign_in:b.memberships[0] | status | exact | as read at allow |
| sign_in:b.memberships[0] | updated_at | exact | as read at allow |
| sign_in:b.memberships[0] | user_id | exact | as read at allow |
| sign_in:b.memberships[1] | added_by | exact | as read at allow |
| sign_in:b.memberships[1] | athanor_id | exact | as read at allow |
| sign_in:b.memberships[1] | created_at | exact | as read at allow |
| sign_in:b.memberships[1] | id | exact | as read at allow |
| sign_in:b.memberships[1] | person_identifier | exact | as read at allow |
| sign_in:b.memberships[1] | scope | exact | as read at allow |
| sign_in:b.memberships[1] | status | exact | as read at allow |
| sign_in:b.memberships[1] | updated_at | exact | as read at allow |
| sign_in:b.memberships[1] | user_id | exact | as read at allow |
| wrong_identity:dir.identity_log_entries[0] | bytes | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | entry | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | entry_hash | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | id | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | identifier | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | inserted_at | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | kind | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | outcome | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | outcome_body | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | prev_hash | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | request_digest | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | request_id | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[0] | seq | exact | as read at setup |
| wrong_identity:dir.identity_log_entries[1] | id | captured | a new ile_ id |
| wrong_identity:dir.identity_log_entries[1] | identifier | derived | the identifier the signer's genesis hashes to |
| wrong_identity:dir.identity_log_entries[1] | seq | exact | `0` |
| wrong_identity:dir.identity_log_entries[1] | kind | exact | `"genesis"` |
| wrong_identity:dir.identity_log_entries[1] | entry_hash | derived | the entry's bytes, hashed |
| wrong_identity:dir.identity_log_entries[1] | prev_hash | exact | `null` |
| wrong_identity:dir.identity_log_entries[1] | entry | derived | the genesis its signer sent, whose hash is the identifier |
| wrong_identity:dir.identity_log_entries[1] | request_id | exact | `null` |
| wrong_identity:dir.identity_log_entries[1] | request_digest | exact | `null` |
| wrong_identity:dir.identity_log_entries[1] | outcome | exact | `"accepted"` |
| wrong_identity:dir.identity_log_entries[1] | outcome_body | exact | `null` |
| wrong_identity:dir.identity_log_entries[1] | bytes | derived | the entry's length |
| wrong_identity:dir.identity_log_entries[1] | inserted_at | bound | a time inside the second identity's requests |
| wrong_identity:registry.namespaces[other] | slug | exact | `"other"` |
| wrong_identity:registry.namespaces[other] | kind | exact | `"personal"` |
| wrong_identity:registry.namespaces[other] | reserved | exact | `false` |
| wrong_identity:registry.namespaces[other] | domain_verified | exact | `false` |
| wrong_identity:registry.namespaces[other] | verify_token | exact | `null` |
| wrong_identity:registry.namespaces[other] | verified_at | exact | `null` |
| wrong_identity:registry.namespaces[other] | last_checked_at | exact | `null` |
| wrong_identity:registry.namespaces[other] | consecutive_failures | exact | `0` |
| wrong_identity:registry.namespaces[other] | display_name | exact | `null` |
| wrong_identity:registry.namespaces[other] | expires_at | exact | `null` |
| wrong_identity:registry.namespaces[other] | created_at | bound | a time inside the second identity's requests |
| wrong_identity:registry.namespaces[other] | updated_at | bound | a time inside the second identity's requests |
| wrong_identity:registry.namespaces[other] | owner_identifier | derived | the second identity's genesis, hashed |
| wrong_identity:registry.namespaces[other] | address | exact | `"https://a.test"` |
| wrong_identity:registry.namespaces[other] | reserved_reason | exact | `null` |
| wrong_identity:registry.identity_heads[c] | identifier | derived | the identity's genesis, hashed |
| wrong_identity:registry.identity_heads[c] | head | derived | the genesis's hash: one entry, so the head (`Prima.Identity`) |
| wrong_identity:registry.identity_heads[c] | entries | exact | `1` |
| wrong_identity:registry.identity_heads[c] | recovery_epoch | derived | a genesis's own hash (`Prima.Identity`, identity.ex:1150) |
| wrong_identity:registry.identity_heads[c] | key_epoch | derived | a genesis's own hash (`Prima.Identity`, identity.ex:1150) |
| wrong_identity:registry.identity_heads[c] | read_at | bound | a time inside the second identity's requests |
| wrong_identity:registry.policy_acceptances[c] | id | captured | an acceptance id: a new UUID, not the nil UUID |
| wrong_identity:registry.policy_acceptances[c] | policy_version | derived | the registry's GET /v1/legal/version |
| wrong_identity:registry.policy_acceptances[c] | accepted_at | bound | a time inside the second identity's requests |
| wrong_identity:registry.policy_acceptances[c] | ip_address | exact | `"::ffff:127.0.0.1"`: the front's forwarded loopback address, as PostgreSQL's inet stores it |
| wrong_identity:registry.policy_acceptances[c] | user_agent | derived | the signer's HTTP client: Req's default for a CYFR (req 0.7.5, mix.lock), the run's curl for the second identity |
| wrong_identity:registry.policy_acceptances[c] | identifier | derived | the signer's identifier |
| wrong_identity:registry.policy_acceptances[c] | former_identity | exact | `null` |
| wrong_identity:registry.request_nonces[c][0] | identifier | derived | the signer's identifier |
| wrong_identity:registry.request_nonces[c][0] | nonce | captured | 16 new bytes |
| wrong_identity:registry.request_nonces[c][0] | expires_at | bound | a time inside the second identity's requests, plus the 120 s a signed request lives |
| wrong_identity:registry.request_nonces[c][1] | identifier | derived | the signer's identifier |
| wrong_identity:registry.request_nonces[c][1] | nonce | captured | 16 new bytes |
| wrong_identity:registry.request_nonces[c][1] | expires_at | bound | a time inside the second identity's requests, plus the 120 s a signed request lives |
| wrong_identity:registry.request_nonces[c][2] | identifier | derived | the signer's identifier |
| wrong_identity:registry.request_nonces[c][2] | nonce | captured | 16 new bytes |
| wrong_identity:registry.request_nonces[c][2] | expires_at | bound | a time inside the second identity's requests, plus the 120 s a signed request lives |
| wrong_identity:handle_answer[other] | status | exact | `200` |
| wrong_identity:handle_answer[other] | protocol | exact | `"cyfr-handle/v1"` |
| wrong_identity:handle_answer[other] | registry | exact | `"registry.test"` |
| wrong_identity:handle_answer[other] | handle | exact | `"other"` |
| wrong_identity:handle_answer[other] | identifier | derived | the owner's genesis, hashed |
| wrong_identity:handle_answer[other] | directory | exact | `"https://dir.test"` |
| wrong_identity:handle_answer[other] | address | exact | `"https://a.test"` |
| wrong_identity:pre:b.sessions[0] | id | captured | a new ses_ id |
| wrong_identity:pre:b.sessions[0] | token_hash | derived | the SHA-256 of the session token the administrator's cookie carries |
| wrong_identity:pre:b.sessions[0] | token_prefix | derived | the first 8 characters of that token |
| wrong_identity:pre:b.sessions[0] | user_id | derived | B's administrator |
| wrong_identity:pre:b.sessions[0] | email | exact | `null` |
| wrong_identity:pre:b.sessions[0] | provider | exact | `"passkey"` |
| wrong_identity:pre:b.sessions[0] | expires_at | derived | inserted_at plus session_ttl_hours (Sanctum.Session) |
| wrong_identity:pre:b.sessions[0] | athanor_id | derived | B's one athanor |
| wrong_identity:pre:b.sessions[0] | identity_key_epoch | exact | `null` |
| wrong_identity:pre:b.sessions[0] | cli_machine | exact | `null` |
| wrong_identity:pre:b.sessions[0] | inserted_at | bound | a time inside setup at B |
| wrong_identity:pre:b.sessions[1] | athanor_id | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | cli_machine | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | email | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | expires_at | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | id | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | identity_key_epoch | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | inserted_at | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | provider | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | token_hash | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | token_prefix | exact | as read at sign_in |
| wrong_identity:pre:b.sessions[1] | user_id | exact | as read at sign_in |
| wrong_identity:b.sign_in_error | shown | exact | `"That sign-in came from someone other than the handle you named, so nobody was signed in."` |
| wrong_identity:b.sign_in_error | shared_with | exact | `[]` |
| wrong_identity:b.users[0] | admission | exact | as read at sign_in |
| wrong_identity:b.users[0] | created_at | exact | as read at sign_in |
| wrong_identity:b.users[0] | denied_at | exact | as read at sign_in |
| wrong_identity:b.users[0] | display_name | exact | as read at sign_in |
| wrong_identity:b.users[0] | email | exact | as read at sign_in |
| wrong_identity:b.users[0] | email_verified | exact | as read at sign_in |
| wrong_identity:b.users[0] | first_seen_at | exact | as read at sign_in |
| wrong_identity:b.users[0] | id | exact | as read at sign_in |
| wrong_identity:b.users[0] | last_seen_at | bound | as read at sign_in, or a time inside the attempt as @other |
| wrong_identity:b.users[0] | namespace | exact | as read at sign_in |
| wrong_identity:b.users[0] | personal_athanor_id | exact | as read at sign_in |
| wrong_identity:b.users[0] | prefs | exact | as read at sign_in |
| wrong_identity:b.users[0] | security_generation | exact | as read at sign_in |
| wrong_identity:b.users[0] | status | exact | as read at sign_in |
| wrong_identity:b.users[0] | updated_at | bound | as read at sign_in, or a time inside the attempt as @other |
| wrong_identity:b.users[1] | admission | exact | as read at sign_in |
| wrong_identity:b.users[1] | created_at | exact | as read at sign_in |
| wrong_identity:b.users[1] | denied_at | exact | as read at sign_in |
| wrong_identity:b.users[1] | display_name | exact | as read at sign_in |
| wrong_identity:b.users[1] | email | exact | as read at sign_in |
| wrong_identity:b.users[1] | email_verified | exact | as read at sign_in |
| wrong_identity:b.users[1] | first_seen_at | exact | as read at sign_in |
| wrong_identity:b.users[1] | id | exact | as read at sign_in |
| wrong_identity:b.users[1] | last_seen_at | bound | as read at sign_in, or a time inside the attempt as @other |
| wrong_identity:b.users[1] | namespace | exact | as read at sign_in |
| wrong_identity:b.users[1] | personal_athanor_id | exact | as read at sign_in |
| wrong_identity:b.users[1] | prefs | exact | as read at sign_in |
| wrong_identity:b.users[1] | security_generation | exact | as read at sign_in |
| wrong_identity:b.users[1] | status | exact | as read at sign_in |
| wrong_identity:b.users[1] | updated_at | bound | as read at sign_in, or a time inside the attempt as @other |
| wrong_identity:b.sessions[0] | athanor_id | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | cli_machine | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | email | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | expires_at | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | id | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | identity_key_epoch | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | inserted_at | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | provider | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | token_hash | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | token_prefix | exact | as read before the attempt |
| wrong_identity:b.sessions[0] | user_id | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | athanor_id | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | cli_machine | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | email | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | expires_at | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | id | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | identity_key_epoch | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | inserted_at | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | provider | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | token_hash | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | token_prefix | exact | as read before the attempt |
| wrong_identity:b.sessions[1] | user_id | exact | as read before the attempt |
| wrong_identity:b.person_identities[0] | directory_url | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | enrollment | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | first_method_at | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | genesis_hash | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | head_hash | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | id | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | identifier | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | inserted_at | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | live_key_sealed | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | live_public_key | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | operational_key_sealed | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | operational_public_key | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | provenance | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | revision | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | updated_at | exact | as read at sign_in |
| wrong_identity:b.person_identities[0] | user_id | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | directory_url | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | enrollment | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | first_method_at | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | genesis_hash | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | head_hash | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | id | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | identifier | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | inserted_at | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | live_key_sealed | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | live_public_key | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | operational_key_sealed | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | operational_public_key | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | provenance | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | revision | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | updated_at | exact | as read at sign_in |
| wrong_identity:b.person_identities[1] | user_id | exact | as read at sign_in |
| wrong_identity:b.athanors | archived_at | exact | as read at allow |
| wrong_identity:b.athanors | created_at | exact | as read at allow |
| wrong_identity:b.athanors | created_by | exact | as read at allow |
| wrong_identity:b.athanors | id | exact | as read at allow |
| wrong_identity:b.athanors | kind | exact | as read at allow |
| wrong_identity:b.athanors | name | exact | as read at allow |
| wrong_identity:b.athanors | owner_user_id | exact | as read at allow |
| wrong_identity:b.athanors | pair_key | exact | as read at allow |
| wrong_identity:b.athanors | provisioned_at | exact | as read at allow |
| wrong_identity:b.athanors | provisioning_failed_at | exact | as read at allow |
| wrong_identity:b.athanors | provisioning_failure | exact | as read at allow |
| wrong_identity:b.athanors | roster | exact | as read at allow |
| wrong_identity:b.athanors | security_generation | exact | as read at allow |
| wrong_identity:b.athanors | settings | exact | as read at allow |
| wrong_identity:b.athanors | slug | exact | as read at allow |
| wrong_identity:b.athanors | status | exact | as read at allow |
| wrong_identity:b.athanors | updated_at | exact | as read at allow |
| wrong_identity:b.memberships[0] | added_by | exact | as read at allow |
| wrong_identity:b.memberships[0] | athanor_id | exact | as read at allow |
| wrong_identity:b.memberships[0] | created_at | exact | as read at allow |
| wrong_identity:b.memberships[0] | id | exact | as read at allow |
| wrong_identity:b.memberships[0] | person_identifier | exact | as read at allow |
| wrong_identity:b.memberships[0] | scope | exact | as read at allow |
| wrong_identity:b.memberships[0] | status | exact | as read at allow |
| wrong_identity:b.memberships[0] | updated_at | exact | as read at allow |
| wrong_identity:b.memberships[0] | user_id | exact | as read at allow |
| wrong_identity:b.memberships[1] | added_by | exact | as read at allow |
| wrong_identity:b.memberships[1] | athanor_id | exact | as read at allow |
| wrong_identity:b.memberships[1] | created_at | exact | as read at allow |
| wrong_identity:b.memberships[1] | id | exact | as read at allow |
| wrong_identity:b.memberships[1] | person_identifier | exact | as read at allow |
| wrong_identity:b.memberships[1] | scope | exact | as read at allow |
| wrong_identity:b.memberships[1] | status | exact | as read at allow |
| wrong_identity:b.memberships[1] | updated_at | exact | as read at allow |
| wrong_identity:b.memberships[1] | user_id | exact | as read at allow |
| sync:registry.push_tokens[proof] | id | captured | a token id: a new UUID, not the nil UUID |
| sync:registry.push_tokens[proof] | token_hash | derived | the digest of the token A sealed |
| sync:registry.push_tokens[proof] | namespace_slug | exact | `"proof"` |
| sync:registry.push_tokens[proof] | label | derived | the label A sealed with the token |
| sync:registry.push_tokens[proof] | created_at | bound | a time inside the sync |
| sync:registry.push_tokens[proof] | last_used_at | bound | a time inside the sync |
| sync:registry.push_tokens[proof] | revoked_at | exact | `null` |
| sync:registry.push_tokens[proof] | created_by | derived | A's identifier |
| sync:registry.push_tokens[proof] | recovery_epoch | derived | a genesis's recovery epoch, its own hash |
| sync:a.registry_tokens | id | captured | a new rtk_ id |
| sync:a.registry_tokens | user_id | derived | A's person |
| sync:a.registry_tokens | registry | exact | `"registry.registry.test"`: the OCI host, registry. before CYFR_REGISTRY_URL |
| sync:a.registry_tokens | namespace_slug | exact | `"proof"` |
| sync:a.registry_tokens | credential_ciphertext | derived | opens, in A, to the credential below |
| sync:a.registry_tokens | issued_at | bound | a time inside the sync |
| sync:a.registry_tokens | inserted_at | bound | a time inside the sync |
| sync:a.registry_tokens | updated_at | bound | a time inside the sync |
| sync:a.registry_tokens.credential | type | exact | `"push_token"` |
| sync:a.registry_tokens.credential | token | derived | the registry's token_hash for the one @proof token |
| sync:a.registry_tokens.credential | namespace | exact | `"proof"` |
| sync:a.registry_tokens.credential | role | exact | `"personal"`: a personal namespace's role, in `Sanctum.RegistryCredentials`' stored shape (registry_credentials.ex:28) |
| sync:a.registry_tokens.credential | issued_at | derived | the row's issued_at |
| sync:a.registry_tokens.credential | label | derived | the registry's label for that token |
| sync:registry.request_nonces[a][0] | identifier | exact | as read at publish |
| sync:registry.request_nonces[a][0] | nonce | exact | as read at publish |
| sync:registry.request_nonces[a][0] | expires_at | exact | as read at publish |
| sync:registry.request_nonces[a][1] | identifier | exact | as read at publish |
| sync:registry.request_nonces[a][1] | nonce | exact | as read at publish |
| sync:registry.request_nonces[a][1] | expires_at | exact | as read at publish |
| sync:registry.request_nonces[a][2] | identifier | exact | as read at publish |
| sync:registry.request_nonces[a][2] | nonce | exact | as read at publish |
| sync:registry.request_nonces[a][2] | expires_at | exact | as read at publish |
| sync:registry.request_nonces[a][3] | identifier | derived | the signer's identifier |
| sync:registry.request_nonces[a][3] | nonce | captured | 16 new bytes |
| sync:registry.request_nonces[a][3] | expires_at | bound | a time inside the sync, plus the 120 s a signed request lives |
| sync:registry.identity_heads[a] | identifier | exact | as read at setup |
| sync:registry.identity_heads[a] | head | exact | as read at setup |
| sync:registry.identity_heads[a] | entries | exact | as read at setup |
| sync:registry.identity_heads[a] | recovery_epoch | exact | as read at setup |
| sync:registry.identity_heads[a] | key_epoch | exact | as read at setup |
| sync:registry.identity_heads[a] | read_at | bound | as read at publish, or a time inside the sync |
| ban:registry.banned_identities | id | captured | a ban id: a new UUID, not the nil UUID |
| ban:registry.banned_identities | banned_at | bound | a time inside the ban |
| ban:registry.banned_identities | banned_by | derived | the registry's admin account the run bootstrapped |
| ban:registry.banned_identities | reason | exact | `"handle proof"` |
| ban:registry.banned_identities | category | exact | `"spam"` |
| ban:registry.banned_identities | expires_at | exact | `null` |
| ban:registry.banned_identities | appeal_allowed_after | exact | `null` |
| ban:registry.banned_identities | related_report_ids | exact | `[]` |
| ban:registry.banned_identities | identifier | derived | A's identifier |
| ban:registry.banned_identities | former_identity | exact | `null` |
| ban:registry.push_tokens[proof] | id | exact | as read at sync |
| ban:registry.push_tokens[proof] | token_hash | exact | as read at sync |
| ban:registry.push_tokens[proof] | namespace_slug | exact | as read at sync |
| ban:registry.push_tokens[proof] | label | exact | as read at sync |
| ban:registry.push_tokens[proof] | created_at | exact | as read at sync |
| ban:registry.push_tokens[proof] | last_used_at | exact | as read at sync |
| ban:registry.push_tokens[proof] | revoked_at | bound | a time inside the ban |
| ban:registry.push_tokens[proof] | created_by | exact | as read at sync |
| ban:registry.push_tokens[proof] | recovery_epoch | exact | as read at sync |
| ban:token_refused | status | exact | `401` |
| ban:token_refused | body | exact | `{"errors":[{"code":"UNAUTHORIZED","message":"token revoked"}]}` |
| ban:a.sync_refused | shown | exact | `"Sync failed: The registry has banned this identity."` |
| ban:a.sync_refused | shared_with | exact | `[]` |
| ban:registry.request_nonces[a][0] | identifier | exact | as read at sync |
| ban:registry.request_nonces[a][0] | nonce | exact | as read at sync |
| ban:registry.request_nonces[a][0] | expires_at | exact | as read at sync |
| ban:registry.request_nonces[a][1] | identifier | exact | as read at sync |
| ban:registry.request_nonces[a][1] | nonce | exact | as read at sync |
| ban:registry.request_nonces[a][1] | expires_at | exact | as read at sync |
| ban:registry.request_nonces[a][2] | identifier | exact | as read at sync |
| ban:registry.request_nonces[a][2] | nonce | exact | as read at sync |
| ban:registry.request_nonces[a][2] | expires_at | exact | as read at sync |
| ban:registry.request_nonces[a][3] | identifier | exact | as read at sync |
| ban:registry.request_nonces[a][3] | nonce | exact | as read at sync |
| ban:registry.request_nonces[a][3] | expires_at | exact | as read at sync |
| held:a.passkeys | activated_at | exact | as read at setup |
| held:a.passkeys | admin_confirmation_id | exact | as read at setup |
| held:a.passkeys | credential_id | exact | as read at setup |
| held:a.passkeys | expires_at | exact | as read at setup |
| held:a.passkeys | id | exact | as read at setup |
| held:a.passkeys | identity_recovery_epoch | exact | as read at setup |
| held:a.passkeys | inserted_at | exact | as read at setup |
| held:a.passkeys | possession_verified | exact | as read at setup |
| held:a.passkeys | public_key | exact | as read at setup |
| held:a.passkeys | registration_digest | exact | as read at setup |
| held:a.passkeys | relying_home | exact | as read at setup |
| held:a.passkeys | revoked_at | exact | as read at setup |
| held:a.passkeys | rp_id | exact | as read at setup |
| held:a.passkeys | sign_count | derived | the authenticator's count for that credential now |
| held:a.passkeys | state | exact | as read at setup |
| held:a.passkeys | updated_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.passkeys | user_id | exact | as read at setup |
| held:a.users | admission | exact | as read at setup |
| held:a.users | created_at | exact | as read at setup |
| held:a.users | denied_at | exact | as read at setup |
| held:a.users | display_name | exact | as read at setup |
| held:a.users | email | exact | as read at setup |
| held:a.users | email_verified | exact | as read at setup |
| held:a.users | first_seen_at | exact | as read at setup |
| held:a.users | id | exact | as read at setup |
| held:a.users | last_seen_at | bound | as read at setup, or a time inside the run from ack's end to the last read |
| held:a.users | namespace | exact | as read at setup |
| held:a.users | personal_athanor_id | exact | as read at setup |
| held:a.users | prefs | exact | as read at setup |
| held:a.users | security_generation | exact | as read at setup |
| held:a.users | status | exact | as read at setup |
| held:a.users | updated_at | bound | as read at setup, or a time inside the run from ack's end to the last read |
| held:a.person_identities | directory_url | exact | as read at setup |
| held:a.person_identities | enrollment | exact | as read at setup |
| held:a.person_identities | first_method_at | exact | as read at setup |
| held:a.person_identities | genesis_hash | exact | as read at setup |
| held:a.person_identities | head_hash | exact | as read at setup |
| held:a.person_identities | id | exact | as read at setup |
| held:a.person_identities | identifier | exact | as read at setup |
| held:a.person_identities | inserted_at | exact | as read at setup |
| held:a.person_identities | live_key_sealed | exact | as read at setup |
| held:a.person_identities | live_public_key | exact | as read at setup |
| held:a.person_identities | operational_key_sealed | exact | as read at setup |
| held:a.person_identities | operational_public_key | exact | as read at setup |
| held:a.person_identities | provenance | exact | as read at setup |
| held:a.person_identities | revision | exact | as read at setup |
| held:a.person_identities | updated_at | exact | as read at setup |
| held:a.person_identities | user_id | exact | as read at setup |
| held:a.athanors | archived_at | exact | as read at setup |
| held:a.athanors | created_at | exact | as read at setup |
| held:a.athanors | created_by | exact | as read at setup |
| held:a.athanors | id | exact | as read at setup |
| held:a.athanors | kind | exact | as read at setup |
| held:a.athanors | name | exact | as read at setup |
| held:a.athanors | owner_user_id | exact | as read at setup |
| held:a.athanors | pair_key | exact | as read at setup |
| held:a.athanors | provisioned_at | exact | as read at setup |
| held:a.athanors | provisioning_failed_at | exact | as read at setup |
| held:a.athanors | provisioning_failure | exact | as read at setup |
| held:a.athanors | roster | exact | as read at setup |
| held:a.athanors | security_generation | exact | as read at setup |
| held:a.athanors | settings | exact | as read at setup |
| held:a.athanors | slug | exact | as read at setup |
| held:a.athanors | status | exact | as read at setup |
| held:a.athanors | updated_at | exact | as read at setup |
| held:a.memberships[0] | added_by | exact | as read at setup |
| held:a.memberships[0] | athanor_id | exact | as read at setup |
| held:a.memberships[0] | created_at | exact | as read at setup |
| held:a.memberships[0] | id | exact | as read at setup |
| held:a.memberships[0] | person_identifier | exact | as read at setup |
| held:a.memberships[0] | scope | exact | as read at setup |
| held:a.memberships[0] | status | exact | as read at setup |
| held:a.memberships[0] | updated_at | exact | as read at setup |
| held:a.memberships[0] | user_id | exact | as read at setup |
| held:a.memberships[1] | added_by | exact | as read at setup |
| held:a.memberships[1] | athanor_id | exact | as read at setup |
| held:a.memberships[1] | created_at | exact | as read at setup |
| held:a.memberships[1] | id | exact | as read at setup |
| held:a.memberships[1] | person_identifier | exact | as read at setup |
| held:a.memberships[1] | scope | exact | as read at setup |
| held:a.memberships[1] | status | exact | as read at setup |
| held:a.memberships[1] | updated_at | exact | as read at setup |
| held:a.memberships[1] | user_id | exact | as read at setup |
| held:a.identity_attempts | directory_url | exact | as read at setup |
| held:a.identity_attempts | entry | exact | as read at setup |
| held:a.identity_attempts | entry_hash | exact | as read at setup |
| held:a.identity_attempts | expected_head | exact | as read at setup |
| held:a.identity_attempts | expected_revision | exact | as read at setup |
| held:a.identity_attempts | genesis | exact | as read at setup |
| held:a.identity_attempts | id | exact | as read at setup |
| held:a.identity_attempts | identifier | exact | as read at setup |
| held:a.identity_attempts | inserted_at | exact | as read at setup |
| held:a.identity_attempts | kind | exact | as read at setup |
| held:a.identity_attempts | kit_acknowledged_at | exact | as read at setup |
| held:a.identity_attempts | kit_seed_sealed | exact | as read at setup |
| held:a.identity_attempts | outcome | exact | as read at setup |
| held:a.identity_attempts | phase | exact | as read at setup |
| held:a.identity_attempts | reproof_challenge_digest | exact | as read at setup |
| held:a.identity_attempts | reproof_expires_at | exact | as read at setup |
| held:a.identity_attempts | request_digest | exact | as read at setup |
| held:a.identity_attempts | request_id | exact | as read at setup |
| held:a.identity_attempts | revision | exact | as read at setup |
| held:a.identity_attempts | staged_live_key_sealed | exact | as read at setup |
| held:a.identity_attempts | staged_live_public_key | exact | as read at setup |
| held:a.identity_attempts | staged_operational_key_sealed | exact | as read at setup |
| held:a.identity_attempts | staged_operational_public_key | exact | as read at setup |
| held:a.identity_attempts | token_digest | exact | as read at setup |
| held:a.identity_attempts | updated_at | exact | as read at setup |
| held:a.identity_attempts | user_id | exact | as read at setup |
| held:a.registry_tokens | credential_ciphertext | exact | as read at sync |
| held:a.registry_tokens | id | exact | as read at sync |
| held:a.registry_tokens | inserted_at | exact | as read at sync |
| held:a.registry_tokens | issued_at | exact | as read at sync |
| held:a.registry_tokens | namespace_slug | exact | as read at sync |
| held:a.registry_tokens | registry | exact | as read at sync |
| held:a.registry_tokens | updated_at | exact | as read at sync |
| held:a.registry_tokens | user_id | exact | as read at sync |
| held:dir.identity_log_entries[0] | bytes | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | entry | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | entry_hash | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | id | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | identifier | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | inserted_at | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | kind | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | outcome | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | outcome_body | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | prev_hash | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | request_digest | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | request_id | exact | as read at wrong_identity |
| held:dir.identity_log_entries[0] | seq | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | bytes | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | entry | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | entry_hash | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | id | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | identifier | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | inserted_at | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | kind | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | outcome | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | outcome_body | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | prev_hash | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | request_digest | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | request_id | exact | as read at wrong_identity |
| held:dir.identity_log_entries[1] | seq | exact | as read at wrong_identity |
| held:registry.namespaces[proof] | slug | exact | as read at publish |
| held:registry.namespaces[proof] | kind | exact | as read at publish |
| held:registry.namespaces[proof] | reserved | exact | as read at publish |
| held:registry.namespaces[proof] | domain_verified | exact | as read at publish |
| held:registry.namespaces[proof] | verify_token | exact | as read at publish |
| held:registry.namespaces[proof] | verified_at | exact | as read at publish |
| held:registry.namespaces[proof] | last_checked_at | exact | as read at publish |
| held:registry.namespaces[proof] | consecutive_failures | exact | as read at publish |
| held:registry.namespaces[proof] | display_name | exact | as read at publish |
| held:registry.namespaces[proof] | expires_at | exact | as read at publish |
| held:registry.namespaces[proof] | created_at | exact | as read at publish |
| held:registry.namespaces[proof] | updated_at | exact | as read at publish |
| held:registry.namespaces[proof] | owner_identifier | exact | as read at publish |
| held:registry.namespaces[proof] | address | exact | as read at publish |
| held:registry.namespaces[proof] | reserved_reason | exact | as read at publish |
| held:registry.namespaces[other] | slug | exact | as read at wrong_identity |
| held:registry.namespaces[other] | kind | exact | as read at wrong_identity |
| held:registry.namespaces[other] | reserved | exact | as read at wrong_identity |
| held:registry.namespaces[other] | domain_verified | exact | as read at wrong_identity |
| held:registry.namespaces[other] | verify_token | exact | as read at wrong_identity |
| held:registry.namespaces[other] | verified_at | exact | as read at wrong_identity |
| held:registry.namespaces[other] | last_checked_at | exact | as read at wrong_identity |
| held:registry.namespaces[other] | consecutive_failures | exact | as read at wrong_identity |
| held:registry.namespaces[other] | display_name | exact | as read at wrong_identity |
| held:registry.namespaces[other] | expires_at | exact | as read at wrong_identity |
| held:registry.namespaces[other] | created_at | exact | as read at wrong_identity |
| held:registry.namespaces[other] | updated_at | exact | as read at wrong_identity |
| held:registry.namespaces[other] | owner_identifier | exact | as read at wrong_identity |
| held:registry.namespaces[other] | address | exact | as read at wrong_identity |
| held:registry.namespaces[other] | reserved_reason | exact | as read at wrong_identity |
| held:registry.identity_heads[a] | identifier | exact | as read at setup |
| held:registry.identity_heads[a] | head | exact | as read at setup |
| held:registry.identity_heads[a] | entries | exact | as read at setup |
| held:registry.identity_heads[a] | recovery_epoch | exact | as read at setup |
| held:registry.identity_heads[a] | key_epoch | exact | as read at setup |
| held:registry.identity_heads[a] | read_at | bound | as read at sync, or a time inside the run from sync's end to the last read |
| held:registry.identity_heads[c] | identifier | exact | as read at wrong_identity |
| held:registry.identity_heads[c] | head | exact | as read at wrong_identity |
| held:registry.identity_heads[c] | entries | exact | as read at wrong_identity |
| held:registry.identity_heads[c] | recovery_epoch | exact | as read at wrong_identity |
| held:registry.identity_heads[c] | key_epoch | exact | as read at wrong_identity |
| held:registry.identity_heads[c] | read_at | exact | as read at wrong_identity |
| held:registry.policy_acceptances[a] | id | exact | as read at setup |
| held:registry.policy_acceptances[a] | policy_version | exact | as read at setup |
| held:registry.policy_acceptances[a] | accepted_at | exact | as read at setup |
| held:registry.policy_acceptances[a] | ip_address | exact | as read at setup |
| held:registry.policy_acceptances[a] | user_agent | exact | as read at setup |
| held:registry.policy_acceptances[a] | identifier | exact | as read at setup |
| held:registry.policy_acceptances[a] | former_identity | exact | as read at setup |
| held:registry.policy_acceptances[c] | id | exact | as read at wrong_identity |
| held:registry.policy_acceptances[c] | policy_version | exact | as read at wrong_identity |
| held:registry.policy_acceptances[c] | accepted_at | exact | as read at wrong_identity |
| held:registry.policy_acceptances[c] | ip_address | exact | as read at wrong_identity |
| held:registry.policy_acceptances[c] | user_agent | exact | as read at wrong_identity |
| held:registry.policy_acceptances[c] | identifier | exact | as read at wrong_identity |
| held:registry.policy_acceptances[c] | former_identity | exact | as read at wrong_identity |
| held:registry.request_nonces[a][0] | identifier | exact | as read at ban |
| held:registry.request_nonces[a][0] | nonce | exact | as read at ban |
| held:registry.request_nonces[a][0] | expires_at | exact | as read at ban |
| held:registry.request_nonces[a][1] | identifier | exact | as read at ban |
| held:registry.request_nonces[a][1] | nonce | exact | as read at ban |
| held:registry.request_nonces[a][1] | expires_at | exact | as read at ban |
| held:registry.request_nonces[a][2] | identifier | exact | as read at ban |
| held:registry.request_nonces[a][2] | nonce | exact | as read at ban |
| held:registry.request_nonces[a][2] | expires_at | exact | as read at ban |
| held:registry.request_nonces[a][3] | identifier | exact | as read at ban |
| held:registry.request_nonces[a][3] | nonce | exact | as read at ban |
| held:registry.request_nonces[a][3] | expires_at | exact | as read at ban |
| held:registry.request_nonces[c][0] | identifier | exact | as read at wrong_identity |
| held:registry.request_nonces[c][0] | nonce | exact | as read at wrong_identity |
| held:registry.request_nonces[c][0] | expires_at | exact | as read at wrong_identity |
| held:registry.request_nonces[c][1] | identifier | exact | as read at wrong_identity |
| held:registry.request_nonces[c][1] | nonce | exact | as read at wrong_identity |
| held:registry.request_nonces[c][1] | expires_at | exact | as read at wrong_identity |
| held:registry.request_nonces[c][2] | identifier | exact | as read at wrong_identity |
| held:registry.request_nonces[c][2] | nonce | exact | as read at wrong_identity |
| held:registry.request_nonces[c][2] | expires_at | exact | as read at wrong_identity |
| held:registry.push_tokens[proof] | id | exact | as read at ban |
| held:registry.push_tokens[proof] | token_hash | exact | as read at ban |
| held:registry.push_tokens[proof] | namespace_slug | exact | as read at ban |
| held:registry.push_tokens[proof] | label | exact | as read at ban |
| held:registry.push_tokens[proof] | created_at | exact | as read at ban |
| held:registry.push_tokens[proof] | last_used_at | exact | as read at ban |
| held:registry.push_tokens[proof] | revoked_at | exact | as read at ban |
| held:registry.push_tokens[proof] | created_by | exact | as read at ban |
| held:registry.push_tokens[proof] | recovery_epoch | exact | as read at ban |
| held:registry.banned_identities | id | exact | as read at ban |
| held:registry.banned_identities | banned_at | exact | as read at ban |
| held:registry.banned_identities | banned_by | exact | as read at ban |
| held:registry.banned_identities | reason | exact | as read at ban |
| held:registry.banned_identities | category | exact | as read at ban |
| held:registry.banned_identities | expires_at | exact | as read at ban |
| held:registry.banned_identities | appeal_allowed_after | exact | as read at ban |
| held:registry.banned_identities | related_report_ids | exact | as read at ban |
| held:registry.banned_identities | identifier | exact | as read at ban |
| held:registry.banned_identities | former_identity | exact | as read at ban |
| held:b.passkeys | activated_at | exact | as read at allow |
| held:b.passkeys | admin_confirmation_id | exact | as read at allow |
| held:b.passkeys | credential_id | exact | as read at allow |
| held:b.passkeys | expires_at | exact | as read at allow |
| held:b.passkeys | id | exact | as read at allow |
| held:b.passkeys | identity_recovery_epoch | exact | as read at allow |
| held:b.passkeys | inserted_at | exact | as read at allow |
| held:b.passkeys | possession_verified | exact | as read at allow |
| held:b.passkeys | public_key | exact | as read at allow |
| held:b.passkeys | registration_digest | exact | as read at allow |
| held:b.passkeys | relying_home | exact | as read at allow |
| held:b.passkeys | revoked_at | exact | as read at allow |
| held:b.passkeys | rp_id | exact | as read at allow |
| held:b.passkeys | sign_count | exact | as read at allow |
| held:b.passkeys | state | exact | as read at allow |
| held:b.passkeys | updated_at | exact | as read at allow |
| held:b.passkeys | user_id | exact | as read at allow |
| held:b.users[0] | admission | exact | as read after the attempt |
| held:b.users[0] | created_at | exact | as read after the attempt |
| held:b.users[0] | denied_at | exact | as read after the attempt |
| held:b.users[0] | display_name | exact | as read after the attempt |
| held:b.users[0] | email | exact | as read after the attempt |
| held:b.users[0] | email_verified | exact | as read after the attempt |
| held:b.users[0] | first_seen_at | exact | as read after the attempt |
| held:b.users[0] | id | exact | as read after the attempt |
| held:b.users[0] | last_seen_at | bound | as read after the attempt, or a time inside the run from attempt's end to the last read |
| held:b.users[0] | namespace | exact | as read after the attempt |
| held:b.users[0] | personal_athanor_id | exact | as read after the attempt |
| held:b.users[0] | prefs | exact | as read after the attempt |
| held:b.users[0] | security_generation | exact | as read after the attempt |
| held:b.users[0] | status | exact | as read after the attempt |
| held:b.users[0] | updated_at | bound | as read after the attempt, or a time inside the run from attempt's end to the last read |
| held:b.users[1] | admission | exact | as read after the attempt |
| held:b.users[1] | created_at | exact | as read after the attempt |
| held:b.users[1] | denied_at | exact | as read after the attempt |
| held:b.users[1] | display_name | exact | as read after the attempt |
| held:b.users[1] | email | exact | as read after the attempt |
| held:b.users[1] | email_verified | exact | as read after the attempt |
| held:b.users[1] | first_seen_at | exact | as read after the attempt |
| held:b.users[1] | id | exact | as read after the attempt |
| held:b.users[1] | last_seen_at | bound | as read after the attempt, or a time inside the run from attempt's end to the last read |
| held:b.users[1] | namespace | exact | as read after the attempt |
| held:b.users[1] | personal_athanor_id | exact | as read after the attempt |
| held:b.users[1] | prefs | exact | as read after the attempt |
| held:b.users[1] | security_generation | exact | as read after the attempt |
| held:b.users[1] | status | exact | as read after the attempt |
| held:b.users[1] | updated_at | bound | as read after the attempt, or a time inside the run from attempt's end to the last read |
| held:b.person_identities[0] | directory_url | exact | as read at sign_in |
| held:b.person_identities[0] | enrollment | exact | as read at sign_in |
| held:b.person_identities[0] | first_method_at | exact | as read at sign_in |
| held:b.person_identities[0] | genesis_hash | exact | as read at sign_in |
| held:b.person_identities[0] | head_hash | exact | as read at sign_in |
| held:b.person_identities[0] | id | exact | as read at sign_in |
| held:b.person_identities[0] | identifier | exact | as read at sign_in |
| held:b.person_identities[0] | inserted_at | exact | as read at sign_in |
| held:b.person_identities[0] | live_key_sealed | exact | as read at sign_in |
| held:b.person_identities[0] | live_public_key | exact | as read at sign_in |
| held:b.person_identities[0] | operational_key_sealed | exact | as read at sign_in |
| held:b.person_identities[0] | operational_public_key | exact | as read at sign_in |
| held:b.person_identities[0] | provenance | exact | as read at sign_in |
| held:b.person_identities[0] | revision | exact | as read at sign_in |
| held:b.person_identities[0] | updated_at | exact | as read at sign_in |
| held:b.person_identities[0] | user_id | exact | as read at sign_in |
| held:b.person_identities[1] | directory_url | exact | as read at sign_in |
| held:b.person_identities[1] | enrollment | exact | as read at sign_in |
| held:b.person_identities[1] | first_method_at | exact | as read at sign_in |
| held:b.person_identities[1] | genesis_hash | exact | as read at sign_in |
| held:b.person_identities[1] | head_hash | exact | as read at sign_in |
| held:b.person_identities[1] | id | exact | as read at sign_in |
| held:b.person_identities[1] | identifier | exact | as read at sign_in |
| held:b.person_identities[1] | inserted_at | exact | as read at sign_in |
| held:b.person_identities[1] | live_key_sealed | exact | as read at sign_in |
| held:b.person_identities[1] | live_public_key | exact | as read at sign_in |
| held:b.person_identities[1] | operational_key_sealed | exact | as read at sign_in |
| held:b.person_identities[1] | operational_public_key | exact | as read at sign_in |
| held:b.person_identities[1] | provenance | exact | as read at sign_in |
| held:b.person_identities[1] | revision | exact | as read at sign_in |
| held:b.person_identities[1] | updated_at | exact | as read at sign_in |
| held:b.person_identities[1] | user_id | exact | as read at sign_in |
| held:b.sessions[0] | athanor_id | exact | as read at wrong_identity |
| held:b.sessions[0] | cli_machine | exact | as read at wrong_identity |
| held:b.sessions[0] | email | exact | as read at wrong_identity |
| held:b.sessions[0] | expires_at | exact | as read at wrong_identity |
| held:b.sessions[0] | id | exact | as read at wrong_identity |
| held:b.sessions[0] | identity_key_epoch | exact | as read at wrong_identity |
| held:b.sessions[0] | inserted_at | exact | as read at wrong_identity |
| held:b.sessions[0] | provider | exact | as read at wrong_identity |
| held:b.sessions[0] | token_hash | exact | as read at wrong_identity |
| held:b.sessions[0] | token_prefix | exact | as read at wrong_identity |
| held:b.sessions[0] | user_id | exact | as read at wrong_identity |
| held:b.sessions[1] | athanor_id | exact | as read at wrong_identity |
| held:b.sessions[1] | cli_machine | exact | as read at wrong_identity |
| held:b.sessions[1] | email | exact | as read at wrong_identity |
| held:b.sessions[1] | expires_at | exact | as read at wrong_identity |
| held:b.sessions[1] | id | exact | as read at wrong_identity |
| held:b.sessions[1] | identity_key_epoch | exact | as read at wrong_identity |
| held:b.sessions[1] | inserted_at | exact | as read at wrong_identity |
| held:b.sessions[1] | provider | exact | as read at wrong_identity |
| held:b.sessions[1] | token_hash | exact | as read at wrong_identity |
| held:b.sessions[1] | token_prefix | exact | as read at wrong_identity |
| held:b.sessions[1] | user_id | exact | as read at wrong_identity |
| held:b.athanors | archived_at | exact | as read at allow |
| held:b.athanors | created_at | exact | as read at allow |
| held:b.athanors | created_by | exact | as read at allow |
| held:b.athanors | id | exact | as read at allow |
| held:b.athanors | kind | exact | as read at allow |
| held:b.athanors | name | exact | as read at allow |
| held:b.athanors | owner_user_id | exact | as read at allow |
| held:b.athanors | pair_key | exact | as read at allow |
| held:b.athanors | provisioned_at | exact | as read at allow |
| held:b.athanors | provisioning_failed_at | exact | as read at allow |
| held:b.athanors | provisioning_failure | exact | as read at allow |
| held:b.athanors | roster | exact | as read at allow |
| held:b.athanors | security_generation | exact | as read at allow |
| held:b.athanors | settings | exact | as read at allow |
| held:b.athanors | slug | exact | as read at allow |
| held:b.athanors | status | exact | as read at allow |
| held:b.athanors | updated_at | exact | as read at allow |
| held:b.memberships[0] | added_by | exact | as read at allow |
| held:b.memberships[0] | athanor_id | exact | as read at allow |
| held:b.memberships[0] | created_at | exact | as read at allow |
| held:b.memberships[0] | id | exact | as read at allow |
| held:b.memberships[0] | person_identifier | exact | as read at allow |
| held:b.memberships[0] | scope | exact | as read at allow |
| held:b.memberships[0] | status | exact | as read at allow |
| held:b.memberships[0] | updated_at | exact | as read at allow |
| held:b.memberships[0] | user_id | exact | as read at allow |
| held:b.memberships[1] | added_by | exact | as read at allow |
| held:b.memberships[1] | athanor_id | exact | as read at allow |
| held:b.memberships[1] | created_at | exact | as read at allow |
| held:b.memberships[1] | id | exact | as read at allow |
| held:b.memberships[1] | person_identifier | exact | as read at allow |
| held:b.memberships[1] | scope | exact | as read at allow |
| held:b.memberships[1] | status | exact | as read at allow |
| held:b.memberships[1] | updated_at | exact | as read at allow |
| held:b.memberships[1] | user_id | exact | as read at allow |
| held:b.server_allowlist | added_by | exact | as read at allow |
| held:b.server_allowlist | created_at | exact | as read at allow |
| held:b.server_allowlist | effect | exact | as read at allow |
| held:b.server_allowlist | id | exact | as read at allow |
| held:b.server_allowlist | kind | exact | as read at allow |
| held:b.server_allowlist | label | exact | as read at allow |
| held:b.server_allowlist | note | exact | as read at allow |
| held:b.server_allowlist | requested_by | exact | as read at allow |
| held:b.server_allowlist | status | exact | as read at allow |
| held:b.server_allowlist | updated_at | exact | as read at allow |
| held:b.server_allowlist | value | exact | as read at allow |
