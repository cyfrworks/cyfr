# The handle proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a handle
at the registry names the person another CYFR allows, and that the person
signs in there from their own CYFR: a person sets up their CYFR through
its two setup screens as `@proof`, another CYFR allows `@proof`, and the person
signs in at that CYFR by typing their own CYFR's address; and a ban at the
registry retires the person's push token.

The registry is cyfr.run's own, built from the checkout `CYFR_RUN_DIR`
names. CI cannot read that source, so CI never runs this proof; without
`CYFR_RUN_DIR` the script says it did not run and why, and exits 0.

```bash
CYFR_RUN_DIR=<cyfr.run checkout> scripts/heavy-check.sh -- tests/handle-proof/run.sh
```

## What runs

| Part | Name | Configured |
|---|---|---|
| A | `a.test` | a `cyfr` release with a `CYFR_SETUP_TOKEN` of its own; enrolls at `registry.test`; `CYFR_REGISTRY_URL=registry.test` |
| B | `b.test` | the same, with its own setup token |
| the registry and directory | `registry.test` | cyfr.run's image, built from `git archive HEAD` of `CYFR_RUN_DIR` by its `Dockerfile`, on a `postgres:16-alpine` of the run's own, with `DOMAIN=registry.test`, behind a front of the identity proof's kind on `127.77.0.3` |

The model checks run independently with
`node --test tests/handle-proof/models-test.mjs`. The PostgreSQL tamper
helper's checks run with
`scripts/heavy-check.sh -- bash tests/handle-proof/registry-test.sh`.

The directory's whole rows are read from `directory.identity_log_entries`
in the registry's PostgreSQL. Their canonical entries, hashes, lengths
and timestamps are checked and tampered as before. A generated ID is
updated in `BY DEFAULT` mode, with its `ALWAYS` declaration restored in
the same transaction. Every tamper's restore compares the identity
columns' declarations as well as the rows and constraints.

The CYFRs reach the directory and the registry by name through their
`ERL_INETRC` at addresses listed in `CYFR_PRIVATE_EGRESS_TARGETS`, and trust
the run's authority (`tests/identity-proof/cells.sh`). No DNS,
`/etc/hosts`, trust store or other configuration outside the scratch
directory is read or changed. cyfr.run's smoke person (`cmd/smokeid`,
built from the same checkout) computes the TOTP code the registry's admin
sign-in takes.

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
registry's database, including its `directory` schema, `curl` through the
fronts). `models.mjs` holds every object's model, the comparison and the
tamper loop, apart from the browsers, so the models can be rebuilt from a
run's record.

| Step | What holds |
|---|---|
| `setup` | A is set up through `/setup`'s two screens: `@proof` is typed on the first and found free at the registry, and a passkey is made, which admits the person and opens their enrollment; the second screen registers the identity at `registry.test` and claims `@proof` before it shows the recovery code. With the code shown and not yet saved, the directory holds A's genesis, the enrollment attempt is accepted, and the registry holds `@proof` owned by A's identifier, that identifier's acceptance of its policy, the nonces of its two signed requests and its read of A's log, and answers `@proof` with A's identifier and directory; "I saved it" completes the attempt (a transition from the attempt read before it) and lands in CYFR signed in, where Settings says "Your name is @proof.". A's person, passkey, identity, athanor and both seats (the athanor's and the first person's platform grant) are read whole |
| `allow` | B, set up through `/setup`'s two screens by its administrator as `@proof-b`, allows `@proof` in Settings; B's one allowlist entry names A's identifier, labelled `proof`; B's passkey, person, athanor and seats are its administrator's |
| `sign_in` | a fresh profile at B's sign-in page, "I run my own CYFR" with A's address, reaches A, signs in there with the passkey, begins the carry, sees B's code named in A's confirmation, and B admits the person as A's identifier, landing them on B's sign-in page as signed in with no athanor there; B's athanors and seats are still its administrator's alone, its sessions are its administrator's and the person's, and the person's session holds the token the browser's cookie carries |
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
  it), the recovery code, the directory's stored genesis (the identifier is
  its hash; the keys are its keys; a genesis's key and recovery epochs are
  its own hash), the run's admin account, the other store's digest;
- **captured**: a value the server generated, read here for the first
  time, that no other source names (a row id, a registration digest, a
  nonce, the recovery code's sealed secret): held to its shape and to the value its
  first read read, and exact at every later read;
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
the browsers' back to a value its model refuses (a byte field, captured or
exact, with one byte flipped; an id or digest another valid one of its
kind, `req_` and 32 hexadecimal digits among them; a time outside its
window), read again, and the
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
`internal/api/handles.go:31`), its identifier through the namespace's
owner, the refused token's status and body through
the token's `revoked_at` (whose use the restore writes back too). The
sealed credential's members are each changed and sealed again alone. An
answer's `handle`, `protocol`, `registry` and `directory`, which no stored
field makes, and the refusal sentence's `shown` and `shared_with`, are
each shown failing by a control: a copy of the object with that one field
corrupted, which the comparison must refuse on that field.

At the end every object is read again and held to what was read before,
with the fields later steps move (a passkey's count, a person's
`last_seen_at`, the registry's `read_at`) each held to its own source or
window. Every loop that ran is recorded by its row's identity (store,
table and the row's own key, never its position) and the predicate it ran
under; at this last read a field's loop is skipped only when the
identical predicate (equality to the same value) already ran on that same
row, so a time once held to a window and now exact runs its loop again,
and so does a row a later step first read. The run prints how many tamper
loops ran, how many controls were refused, and names each field with no
loop and why.

The table's rows of a list are labelled by what each row is (a seat by
its scope, a nonce as read at a step or new, a session by whose it is),
never by the order the run read them in, so the table is the same
whatever that order.

## Fields

The table the models print (`handle-proof-fields.md` in the output), one
row per field of each row of each step's objects:

| object | field | class | value, source or bound |
|---|---|---|---|
| setup:a.passkeys[row] | id | captured | a new psk_ id |
| setup:a.passkeys[row] | user_id | captured | a new usr_ id |
| setup:a.passkeys[row] | credential_id | derived | the credential the browser's authenticator holds for a.test, base64url |
| setup:a.passkeys[row] | rp_id | exact | `"a.test"` |
| setup:a.passkeys[row] | relying_home | exact | `"https://a.test"` |
| setup:a.passkeys[row] | public_key | derived | the authenticator's key, as the COSE map CYFR stores (term_to_binary) |
| setup:a.passkeys[row] | sign_count | derived | the authenticator's count for that credential |
| setup:a.passkeys[row] | identity_recovery_epoch | exact | `null` |
| setup:a.passkeys[row] | state | exact | `"active"` |
| setup:a.passkeys[row] | registration_digest | captured | the registration's digest: a new sha256: digest |
| setup:a.passkeys[row] | possession_verified | exact | `1` |
| setup:a.passkeys[row] | expires_at | exact | `null` |
| setup:a.passkeys[row] | admin_confirmation_id | exact | `null` |
| setup:a.passkeys[row] | activated_at | bound | a time inside setup at A |
| setup:a.passkeys[row] | revoked_at | exact | `null` |
| setup:a.passkeys[row] | inserted_at | bound | a time inside setup at A |
| setup:a.passkeys[row] | updated_at | bound | a time inside setup at A |
| setup:registry.directory.identity_log_entries[row] | id | captured | a new directory row id |
| setup:registry.directory.identity_log_entries[row] | identifier | derived | the identifier the signer's genesis hashes to |
| setup:registry.directory.identity_log_entries[row] | seq | exact | `0` |
| setup:registry.directory.identity_log_entries[row] | kind | exact | `"genesis"` |
| setup:registry.directory.identity_log_entries[row] | entry_hash | derived | the entry's bytes, hashed |
| setup:registry.directory.identity_log_entries[row] | prev_hash | exact | `null` |
| setup:registry.directory.identity_log_entries[row] | entry | derived | the genesis its signer sent, whose hash is the identifier |
| setup:registry.directory.identity_log_entries[row] | request_id | exact | `null` |
| setup:registry.directory.identity_log_entries[row] | request_digest | exact | `null` |
| setup:registry.directory.identity_log_entries[row] | outcome | exact | `"accepted"` |
| setup:registry.directory.identity_log_entries[row] | outcome_body | exact | `null` |
| setup:registry.directory.identity_log_entries[row] | bytes | derived | the entry's length |
| setup:registry.directory.identity_log_entries[row] | inserted_at | bound | a time inside the enrollment, to the recovery code shown |
| setup:pre:a.identity_attempts[row] | id | captured | a new iat_ id |
| setup:pre:a.identity_attempts[row] | kind | exact | `"enrollment"` |
| setup:pre:a.identity_attempts[row] | request_id | captured | a new request id, req_ and 32 hexadecimal digits |
| setup:pre:a.identity_attempts[row] | user_id | derived | A's passkey's person |
| setup:pre:a.identity_attempts[row] | identifier | derived | the identifier the recovery code names, as the browser showed it |
| setup:pre:a.identity_attempts[row] | directory_url | exact | `"https://registry.test"` |
| setup:pre:a.identity_attempts[row] | phase | exact | `"accepted"` |
| setup:pre:a.identity_attempts[row] | genesis | derived | the directory's stored genesis |
| setup:pre:a.identity_attempts[row] | entry | exact | `null` |
| setup:pre:a.identity_attempts[row] | entry_hash | exact | `null` |
| setup:pre:a.identity_attempts[row] | expected_head | exact | `null` |
| setup:pre:a.identity_attempts[row] | expected_revision | exact | `null` |
| setup:pre:a.identity_attempts[row] | request_digest | derived | the genesis's hash: an enrollment's request is its genesis |
| setup:pre:a.identity_attempts[row] | token_digest | exact | `null` |
| setup:pre:a.identity_attempts[row] | staged_live_public_key | exact | `null`: the accepted enrollment moved its staged keys onto the identity row |
| setup:pre:a.identity_attempts[row] | staged_operational_public_key | exact | `null` |
| setup:pre:a.identity_attempts[row] | staged_live_key_sealed | exact | `null` |
| setup:pre:a.identity_attempts[row] | staged_operational_key_sealed | exact | `null` |
| setup:pre:a.identity_attempts[row] | kit_seed_sealed | captured | the recovery code's secret, sealed until the code is saved: new sealed bytes |
| setup:pre:a.identity_attempts[row] | kit_acknowledged_at | exact | `null` |
| setup:pre:a.identity_attempts[row] | outcome | exact | `"accepted"` |
| setup:pre:a.identity_attempts[row] | reproof_challenge_digest | exact | `null` |
| setup:pre:a.identity_attempts[row] | reproof_expires_at | exact | `null` |
| setup:pre:a.identity_attempts[row] | revision | exact | `3`: the attempt as its enrollment's acceptance leaves it |
| setup:pre:a.identity_attempts[row] | inserted_at | bound | a time inside the enrollment, to the recovery code shown |
| setup:pre:a.identity_attempts[row] | updated_at | bound | a time inside the enrollment, to the recovery code shown |
| setup:a.identity_attempts[row] | directory_url | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | entry | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | entry_hash | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | expected_head | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | expected_revision | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | genesis | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | id | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | identifier | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | inserted_at | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | kind | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | kit_acknowledged_at | bound | a time inside saving the recovery code, to @proof claimed |
| setup:a.identity_attempts[row] | kit_seed_sealed | exact | `null`: the recovery code's secret is dropped once the code is saved |
| setup:a.identity_attempts[row] | outcome | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | phase | exact | `"completed"` |
| setup:a.identity_attempts[row] | reproof_challenge_digest | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | reproof_expires_at | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | request_digest | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | request_id | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | revision | exact | the revision read before the code was saved, plus one |
| setup:a.identity_attempts[row] | staged_live_key_sealed | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | staged_live_public_key | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | staged_operational_key_sealed | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | staged_operational_public_key | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | token_digest | exact | as read before the recovery code was saved |
| setup:a.identity_attempts[row] | updated_at | bound | a time inside saving the recovery code, to @proof claimed |
| setup:a.identity_attempts[row] | user_id | exact | as read before the recovery code was saved |
| setup:a.athanors[row] | id | captured | a new ath_ id |
| setup:a.athanors[row] | kind | exact | `"person"` |
| setup:a.athanors[row] | name | exact | `"Me"` |
| setup:a.athanors[row] | slug | exact | `"me"` |
| setup:a.athanors[row] | owner_user_id | derived | A's person |
| setup:a.athanors[row] | status | exact | `"active"` |
| setup:a.athanors[row] | archived_at | exact | `null` |
| setup:a.athanors[row] | created_by | derived | A's person |
| setup:a.athanors[row] | settings | exact | `null` |
| setup:a.athanors[row] | provisioned_at | bound | a time inside setup at A up to setup:a.athanors's read |
| setup:a.athanors[row] | provisioning_failed_at | exact | `null` |
| setup:a.athanors[row] | provisioning_failure | exact | `null` |
| setup:a.athanors[row] | roster | exact | `"open"` |
| setup:a.athanors[row] | pair_key | exact | `null` |
| setup:a.athanors[row] | security_generation | exact | `1` |
| setup:a.athanors[row] | created_at | bound | a time inside setup at A |
| setup:a.athanors[row] | updated_at | bound | a time inside setup at A up to setup:a.athanors's read |
| setup:a.memberships[the athanor's seat] | id | captured | a new mem_ id |
| setup:a.memberships[the athanor's seat] | user_id | derived | the person |
| setup:a.memberships[the athanor's seat] | person_identifier | exact | `null` |
| setup:a.memberships[the athanor's seat] | scope | exact | `"athanor"` |
| setup:a.memberships[the athanor's seat] | status | exact | `"active"` |
| setup:a.memberships[the athanor's seat] | added_by | exact | `null` |
| setup:a.memberships[the athanor's seat] | athanor_id | derived | the person's one athanor |
| setup:a.memberships[the athanor's seat] | created_at | bound | a time inside setup at A |
| setup:a.memberships[the athanor's seat] | updated_at | bound | a time inside setup at A |
| setup:a.memberships[the platform grant] | id | captured | a new mem_ id |
| setup:a.memberships[the platform grant] | user_id | derived | the person |
| setup:a.memberships[the platform grant] | person_identifier | exact | `null` |
| setup:a.memberships[the platform grant] | scope | exact | `"platform"` |
| setup:a.memberships[the platform grant] | status | exact | `"active"` |
| setup:a.memberships[the platform grant] | added_by | exact | `null` |
| setup:a.memberships[the platform grant] | athanor_id | exact | `null` |
| setup:a.memberships[the platform grant] | created_at | bound | a time inside setup at A |
| setup:a.memberships[the platform grant] | updated_at | bound | a time inside setup at A |
| setup:a.users[row] | id | derived | the user A's passkey names |
| setup:a.users[row] | email | exact | `null` |
| setup:a.users[row] | email_verified | exact | `null` |
| setup:a.users[row] | admission | exact | `"setup"` |
| setup:a.users[row] | display_name | exact | `null` |
| setup:a.users[row] | namespace | exact | `"proof"` |
| setup:a.users[row] | personal_athanor_id | derived | A's one athanor |
| setup:a.users[row] | status | exact | `"active"` |
| setup:a.users[row] | prefs | exact | `"{}"`: Newcomer's empty document (newcomer.ex:264), the cleared handle_wanted removed |
| setup:a.users[row] | first_seen_at | bound | a time inside setup at A |
| setup:a.users[row] | last_seen_at | bound | a time inside setup at A up to setup:a.users's read |
| setup:a.users[row] | denied_at | exact | `null` |
| setup:a.users[row] | security_generation | exact | `1` |
| setup:a.users[row] | created_at | bound | a time inside setup at A |
| setup:a.users[row] | updated_at | bound | a time inside setup at A up to setup:a.users's read |
| setup:a.person_identities[row] | id | captured | a new pid_ id |
| setup:a.person_identities[row] | user_id | derived | A's passkey's person |
| setup:a.person_identities[row] | identifier | derived | the identifier the recovery code names |
| setup:a.person_identities[row] | provenance | exact | `"local"` |
| setup:a.person_identities[row] | enrollment | exact | `"enrolled"` |
| setup:a.person_identities[row] | live_public_key | derived | the directory's genesis's live key |
| setup:a.person_identities[row] | operational_public_key | derived | the directory's genesis's operational key |
| setup:a.person_identities[row] | live_key_sealed | derived | opens, in A, to the genesis's live key |
| setup:a.person_identities[row] | operational_key_sealed | derived | opens, in A, to the genesis's operational key |
| setup:a.person_identities[row] | genesis_hash | derived | the directory's genesis, hashed |
| setup:a.person_identities[row] | head_hash | derived | the directory's one entry |
| setup:a.person_identities[row] | directory_url | exact | `"https://registry.test"` |
| setup:a.person_identities[row] | first_method_at | bound | a time inside setup at A |
| setup:a.person_identities[row] | revision | exact | `4`: 1 at insertion, then first_method! (person_identities.ex:233), enrolling! (:145) and enrolled! (:174), each one step (:259) |
| setup:a.person_identities[row] | inserted_at | bound | a time inside setup at A |
| setup:a.person_identities[row] | updated_at | bound | a time inside the enrollment, to the recovery code shown |
| setup:registry.namespaces[proof][row] | slug | exact | `"proof"` |
| setup:registry.namespaces[proof][row] | kind | exact | `"personal"` |
| setup:registry.namespaces[proof][row] | reserved | exact | `false` |
| setup:registry.namespaces[proof][row] | domain_verified | exact | `false` |
| setup:registry.namespaces[proof][row] | verify_token | exact | `null` |
| setup:registry.namespaces[proof][row] | verified_at | exact | `null` |
| setup:registry.namespaces[proof][row] | last_checked_at | exact | `null` |
| setup:registry.namespaces[proof][row] | consecutive_failures | exact | `0` |
| setup:registry.namespaces[proof][row] | display_name | exact | `null` |
| setup:registry.namespaces[proof][row] | expires_at | exact | `null` |
| setup:registry.namespaces[proof][row] | created_at | bound | a time inside saving the recovery code, to @proof claimed |
| setup:registry.namespaces[proof][row] | updated_at | bound | a time inside saving the recovery code, to @proof claimed |
| setup:registry.namespaces[proof][row] | owner_identifier | derived | the identifier the recovery code names |
| setup:registry.namespaces[proof][row] | reserved_reason | exact | `null` |
| setup:registry.identity_heads[a][row] | identifier | derived | the identity's genesis, hashed |
| setup:registry.identity_heads[a][row] | head | derived | the genesis's hash: one entry, so the head (`Prima.Identity`) |
| setup:registry.identity_heads[a][row] | entries | exact | `1` |
| setup:registry.identity_heads[a][row] | recovery_epoch | derived | a genesis's own hash (`Prima.Identity`, identity.ex:1150) |
| setup:registry.identity_heads[a][row] | key_epoch | derived | a genesis's own hash (`Prima.Identity`, identity.ex:1150) |
| setup:registry.identity_heads[a][row] | read_at | bound | a time inside saving the recovery code, to @proof claimed |
| setup:registry.policy_acceptances[a][row] | id | captured | an acceptance id: a new UUID, not the nil UUID |
| setup:registry.policy_acceptances[a][row] | policy_version | derived | the registry's GET /v1/legal/version |
| setup:registry.policy_acceptances[a][row] | accepted_at | bound | a time inside saving the recovery code, to @proof claimed |
| setup:registry.policy_acceptances[a][row] | ip_address | exact | `"::ffff:127.0.0.1"`: the front's forwarded loopback address, as PostgreSQL's inet stores it |
| setup:registry.policy_acceptances[a][row] | identifier | derived | the signer's identifier |
| setup:registry.policy_acceptances[a][row] | former_identity | exact | `null` |
| setup:registry.policy_acceptances[a][row] | user_agent | derived | the signer's HTTP client: Req's default for a CYFR (req 0.7.5, mix.lock) |
| setup:registry.request_nonces[a][row 1] | identifier | derived | the signer's identifier |
| setup:registry.request_nonces[a][row 1] | nonce | captured | 16 new bytes |
| setup:registry.request_nonces[a][row 1] | expires_at | bound | a time inside saving the recovery code, to @proof claimed, plus the 120 s a signed request lives |
| setup:registry.request_nonces[a][row 2] | identifier | derived | the signer's identifier |
| setup:registry.request_nonces[a][row 2] | nonce | captured | 16 new bytes |
| setup:registry.request_nonces[a][row 2] | expires_at | bound | a time inside saving the recovery code, to @proof claimed, plus the 120 s a signed request lives |
| setup:handle_answer[proof] | status | exact | `200` |
| setup:handle_answer[proof] | protocol | exact | `"cyfr-handle/v1"` |
| setup:handle_answer[proof] | registry | exact | `"registry.test"` |
| setup:handle_answer[proof] | handle | exact | `"proof"` |
| setup:handle_answer[proof] | identifier | derived | the owner's genesis, hashed |
| setup:handle_answer[proof] | directory | exact | `"https://registry.test"` |
| allow:b.passkeys[row] | id | captured | a new psk_ id |
| allow:b.passkeys[row] | user_id | captured | a new usr_ id |
| allow:b.passkeys[row] | credential_id | derived | the credential the administrator's authenticator holds for b.test, base64url |
| allow:b.passkeys[row] | rp_id | exact | `"b.test"` |
| allow:b.passkeys[row] | relying_home | exact | `"https://b.test"` |
| allow:b.passkeys[row] | public_key | derived | the administrator's authenticator's key, as the COSE map CYFR stores |
| allow:b.passkeys[row] | sign_count | derived | the authenticator's count for that credential |
| allow:b.passkeys[row] | identity_recovery_epoch | exact | `null` |
| allow:b.passkeys[row] | state | exact | `"active"` |
| allow:b.passkeys[row] | registration_digest | captured | the registration's digest: a new sha256: digest |
| allow:b.passkeys[row] | possession_verified | exact | `1` |
| allow:b.passkeys[row] | expires_at | exact | `null` |
| allow:b.passkeys[row] | admin_confirmation_id | exact | `null` |
| allow:b.passkeys[row] | activated_at | bound | a time inside setup at B |
| allow:b.passkeys[row] | revoked_at | exact | `null` |
| allow:b.passkeys[row] | inserted_at | bound | a time inside setup at B |
| allow:b.passkeys[row] | updated_at | bound | a time inside setup at B |
| allow:b.athanors[row] | id | captured | a new ath_ id |
| allow:b.athanors[row] | kind | exact | `"person"` |
| allow:b.athanors[row] | name | exact | `"Me"` |
| allow:b.athanors[row] | slug | exact | `"me"` |
| allow:b.athanors[row] | owner_user_id | derived | B's administrator |
| allow:b.athanors[row] | status | exact | `"active"` |
| allow:b.athanors[row] | archived_at | exact | `null` |
| allow:b.athanors[row] | created_by | derived | B's administrator |
| allow:b.athanors[row] | settings | exact | `null` |
| allow:b.athanors[row] | provisioned_at | bound | a time inside setup at B up to allow:b.athanors's read |
| allow:b.athanors[row] | provisioning_failed_at | exact | `null` |
| allow:b.athanors[row] | provisioning_failure | exact | `null` |
| allow:b.athanors[row] | roster | exact | `"open"` |
| allow:b.athanors[row] | pair_key | exact | `null` |
| allow:b.athanors[row] | security_generation | exact | `1` |
| allow:b.athanors[row] | created_at | bound | a time inside setup at B |
| allow:b.athanors[row] | updated_at | bound | a time inside setup at B up to allow:b.athanors's read |
| allow:b.memberships[the athanor's seat] | id | captured | a new mem_ id |
| allow:b.memberships[the athanor's seat] | user_id | derived | the person |
| allow:b.memberships[the athanor's seat] | person_identifier | exact | `null` |
| allow:b.memberships[the athanor's seat] | scope | exact | `"athanor"` |
| allow:b.memberships[the athanor's seat] | status | exact | `"active"` |
| allow:b.memberships[the athanor's seat] | added_by | exact | `null` |
| allow:b.memberships[the athanor's seat] | athanor_id | derived | the person's one athanor |
| allow:b.memberships[the athanor's seat] | created_at | bound | a time inside setup at B |
| allow:b.memberships[the athanor's seat] | updated_at | bound | a time inside setup at B |
| allow:b.memberships[the platform grant] | id | captured | a new mem_ id |
| allow:b.memberships[the platform grant] | user_id | derived | the person |
| allow:b.memberships[the platform grant] | person_identifier | exact | `null` |
| allow:b.memberships[the platform grant] | scope | exact | `"platform"` |
| allow:b.memberships[the platform grant] | status | exact | `"active"` |
| allow:b.memberships[the platform grant] | added_by | exact | `null` |
| allow:b.memberships[the platform grant] | athanor_id | exact | `null` |
| allow:b.memberships[the platform grant] | created_at | bound | a time inside setup at B |
| allow:b.memberships[the platform grant] | updated_at | bound | a time inside setup at B |
| allow:b.users[row] | id | derived | the user B's administrator's passkey names |
| allow:b.users[row] | email | exact | `null` |
| allow:b.users[row] | email_verified | exact | `null` |
| allow:b.users[row] | admission | exact | `"setup"` |
| allow:b.users[row] | display_name | exact | `null` |
| allow:b.users[row] | namespace | exact | `null` |
| allow:b.users[row] | personal_athanor_id | derived | B's one athanor |
| allow:b.users[row] | status | exact | `"active"` |
| allow:b.users[row] | prefs | exact | `"{}"`: Newcomer's empty document (newcomer.ex:264), the cleared handle_wanted removed |
| allow:b.users[row] | first_seen_at | bound | a time inside setup at B |
| allow:b.users[row] | last_seen_at | bound | a time inside setup at B up to allow:b.users's read |
| allow:b.users[row] | denied_at | exact | `null` |
| allow:b.users[row] | security_generation | exact | `1` |
| allow:b.users[row] | created_at | bound | a time inside setup at B |
| allow:b.users[row] | updated_at | bound | a time inside setup at B up to allow:b.users's read |
| allow:b.server_allowlist[row] | id | captured | a new door_ id |
| allow:b.server_allowlist[row] | kind | exact | `"identifier"` |
| allow:b.server_allowlist[row] | value | derived | the identifier @proof names at the registry (A's recovery code's) |
| allow:b.server_allowlist[row] | effect | exact | `"allow"` |
| allow:b.server_allowlist[row] | status | exact | `"allowed"` |
| allow:b.server_allowlist[row] | requested_by | exact | `null` |
| allow:b.server_allowlist[row] | added_by | derived | B's administrator |
| allow:b.server_allowlist[row] | note | exact | `null` |
| allow:b.server_allowlist[row] | label | exact | `"proof"` |
| allow:b.server_allowlist[row] | created_at | bound | a time inside the allow |
| allow:b.server_allowlist[row] | updated_at | bound | a time inside the allow |
| sign_in:b.person_identities[the administrator's] | id | captured | a new pid_ id |
| sign_in:b.person_identities[the administrator's] | user_id | derived | B's administrator |
| sign_in:b.person_identities[the administrator's] | identifier | exact | `null` |
| sign_in:b.person_identities[the administrator's] | provenance | exact | `"local"` |
| sign_in:b.person_identities[the administrator's] | enrollment | exact | `"none"` |
| sign_in:b.person_identities[the administrator's] | live_public_key | derived | the public half of the sealed live key, opened in B |
| sign_in:b.person_identities[the administrator's] | live_key_sealed | derived | opens, in B, to the live public key beside it |
| sign_in:b.person_identities[the administrator's] | operational_public_key | derived | the public half of the sealed operational key, opened in B |
| sign_in:b.person_identities[the administrator's] | operational_key_sealed | derived | opens, in B, to the operational public key beside it |
| sign_in:b.person_identities[the administrator's] | genesis_hash | exact | `null` |
| sign_in:b.person_identities[the administrator's] | head_hash | exact | `null` |
| sign_in:b.person_identities[the administrator's] | directory_url | exact | `null` |
| sign_in:b.person_identities[the administrator's] | first_method_at | bound | a time inside setup at B |
| sign_in:b.person_identities[the administrator's] | revision | exact | `2`: 1 at insertion, then first_method! (person_identities.ex:233) |
| sign_in:b.person_identities[the administrator's] | inserted_at | bound | a time inside setup at B |
| sign_in:b.person_identities[the administrator's] | updated_at | bound | a time inside setup at B |
| sign_in:b.person_identities[the person's] | id | captured | a new pid_ id |
| sign_in:b.person_identities[the person's] | user_id | captured | a new usr_ id |
| sign_in:b.person_identities[the person's] | identifier | derived | the identifier A's recovery code names |
| sign_in:b.person_identities[the person's] | provenance | exact | `"remote"` |
| sign_in:b.person_identities[the person's] | enrollment | exact | `"enrolled"` |
| sign_in:b.person_identities[the person's] | live_public_key | exact | `null`: B keeps no copy of a remote person's keys; it reads them at the directory |
| sign_in:b.person_identities[the person's] | operational_public_key | exact | `null` |
| sign_in:b.person_identities[the person's] | live_key_sealed | exact | `null` |
| sign_in:b.person_identities[the person's] | operational_key_sealed | exact | `null` |
| sign_in:b.person_identities[the person's] | genesis_hash | derived | the directory's genesis, hashed |
| sign_in:b.person_identities[the person's] | head_hash | derived | the directory's one entry |
| sign_in:b.person_identities[the person's] | directory_url | exact | `"https://registry.test"` |
| sign_in:b.person_identities[the person's] | first_method_at | exact | `null` |
| sign_in:b.person_identities[the person's] | revision | exact | `1` |
| sign_in:b.person_identities[the person's] | inserted_at | bound | a time inside the sign-in at B |
| sign_in:b.person_identities[the person's] | updated_at | bound | a time inside the sign-in at B |
| sign_in:b.users[the administrator's] | admission | exact | as read at allow |
| sign_in:b.users[the administrator's] | created_at | exact | as read at allow |
| sign_in:b.users[the administrator's] | denied_at | exact | as read at allow |
| sign_in:b.users[the administrator's] | display_name | exact | as read at allow |
| sign_in:b.users[the administrator's] | email | exact | as read at allow |
| sign_in:b.users[the administrator's] | email_verified | exact | as read at allow |
| sign_in:b.users[the administrator's] | first_seen_at | exact | as read at allow |
| sign_in:b.users[the administrator's] | id | exact | as read at allow |
| sign_in:b.users[the administrator's] | last_seen_at | bound | as read at allow, or a time inside the sign-in at B |
| sign_in:b.users[the administrator's] | namespace | exact | as read at allow |
| sign_in:b.users[the administrator's] | personal_athanor_id | exact | as read at allow |
| sign_in:b.users[the administrator's] | prefs | exact | as read at allow |
| sign_in:b.users[the administrator's] | security_generation | exact | as read at allow |
| sign_in:b.users[the administrator's] | status | exact | as read at allow |
| sign_in:b.users[the administrator's] | updated_at | bound | as read at allow, or a time inside the sign-in at B |
| sign_in:b.users[the person's] | id | derived | B's identity row for A's identifier |
| sign_in:b.users[the person's] | email | exact | `null` |
| sign_in:b.users[the person's] | email_verified | exact | `null` |
| sign_in:b.users[the person's] | admission | exact | `"remote"` |
| sign_in:b.users[the person's] | display_name | exact | `null` |
| sign_in:b.users[the person's] | namespace | exact | `null` |
| sign_in:b.users[the person's] | personal_athanor_id | exact | `null` |
| sign_in:b.users[the person's] | status | exact | `"active"` |
| sign_in:b.users[the person's] | prefs | exact | `"{}"`: Newcomer's empty document (newcomer.ex:264) |
| sign_in:b.users[the person's] | first_seen_at | bound | a time inside the sign-in at B |
| sign_in:b.users[the person's] | last_seen_at | bound | a time inside the sign-in at B up to sign_in:b.users's read |
| sign_in:b.users[the person's] | denied_at | exact | `null` |
| sign_in:b.users[the person's] | security_generation | exact | `1` |
| sign_in:b.users[the person's] | created_at | bound | a time inside the sign-in at B |
| sign_in:b.users[the person's] | updated_at | bound | a time inside the sign-in at B up to sign_in:b.users's read |
| sign_in:b.sessions[proof][row] | id | captured | a new ses_ id |
| sign_in:b.sessions[proof][row] | token_hash | derived | the SHA-256 of the session token the browser's cookie carries |
| sign_in:b.sessions[proof][row] | token_prefix | derived | the first 8 characters of that token |
| sign_in:b.sessions[proof][row] | user_id | derived | B's identity row for A's identifier |
| sign_in:b.sessions[proof][row] | email | exact | `null` |
| sign_in:b.sessions[proof][row] | provider | exact | `"cyfr"`: the CYFR identity kind, as `CyfrDoor.context/1` mints it (cyfr_door.ex:509) |
| sign_in:b.sessions[proof][row] | expires_at | derived | inserted_at plus session_ttl_hours (Sanctum.Session) |
| sign_in:b.sessions[proof][row] | athanor_id | exact | `null` |
| sign_in:b.sessions[proof][row] | identity_key_epoch | derived | a genesis's key epoch, its own hash |
| sign_in:b.sessions[proof][row] | cli_machine | exact | `null` |
| sign_in:b.sessions[proof][row] | inserted_at | bound | a time inside the sign-in at B |
| sign_in:b.sessions[the administrator's] | id | captured | a new ses_ id |
| sign_in:b.sessions[the administrator's] | token_hash | derived | the SHA-256 of the session token the administrator's cookie carries |
| sign_in:b.sessions[the administrator's] | token_prefix | derived | the first 8 characters of that token |
| sign_in:b.sessions[the administrator's] | user_id | derived | B's administrator |
| sign_in:b.sessions[the administrator's] | email | exact | `null` |
| sign_in:b.sessions[the administrator's] | provider | exact | `"passkey"` |
| sign_in:b.sessions[the administrator's] | expires_at | derived | inserted_at plus session_ttl_hours (Sanctum.Session) |
| sign_in:b.sessions[the administrator's] | athanor_id | derived | B's one athanor |
| sign_in:b.sessions[the administrator's] | identity_key_epoch | exact | `null` |
| sign_in:b.sessions[the administrator's] | cli_machine | exact | `null` |
| sign_in:b.sessions[the administrator's] | inserted_at | bound | a time inside setup at B |
| sign_in:b.sessions[the person's] | athanor_id | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | cli_machine | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | email | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | expires_at | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | id | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | identity_key_epoch | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | inserted_at | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | provider | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | token_hash | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | token_prefix | exact | as read at sign_in |
| sign_in:b.sessions[the person's] | user_id | exact | as read at sign_in |
| sign_in:b.athanors[row] | archived_at | exact | as read at allow |
| sign_in:b.athanors[row] | created_at | exact | as read at allow |
| sign_in:b.athanors[row] | created_by | exact | as read at allow |
| sign_in:b.athanors[row] | id | exact | as read at allow |
| sign_in:b.athanors[row] | kind | exact | as read at allow |
| sign_in:b.athanors[row] | name | exact | as read at allow |
| sign_in:b.athanors[row] | owner_user_id | exact | as read at allow |
| sign_in:b.athanors[row] | pair_key | exact | as read at allow |
| sign_in:b.athanors[row] | provisioned_at | exact | as read at allow |
| sign_in:b.athanors[row] | provisioning_failed_at | exact | as read at allow |
| sign_in:b.athanors[row] | provisioning_failure | exact | as read at allow |
| sign_in:b.athanors[row] | roster | exact | as read at allow |
| sign_in:b.athanors[row] | security_generation | exact | as read at allow |
| sign_in:b.athanors[row] | settings | exact | as read at allow |
| sign_in:b.athanors[row] | slug | exact | as read at allow |
| sign_in:b.athanors[row] | status | exact | as read at allow |
| sign_in:b.athanors[row] | updated_at | exact | as read at allow |
| sign_in:b.memberships[row 1] | added_by | exact | as read at allow |
| sign_in:b.memberships[row 1] | athanor_id | exact | as read at allow |
| sign_in:b.memberships[row 1] | created_at | exact | as read at allow |
| sign_in:b.memberships[row 1] | id | exact | as read at allow |
| sign_in:b.memberships[row 1] | person_identifier | exact | as read at allow |
| sign_in:b.memberships[row 1] | scope | exact | as read at allow |
| sign_in:b.memberships[row 1] | status | exact | as read at allow |
| sign_in:b.memberships[row 1] | updated_at | exact | as read at allow |
| sign_in:b.memberships[row 1] | user_id | exact | as read at allow |
| sign_in:b.memberships[row 2] | added_by | exact | as read at allow |
| sign_in:b.memberships[row 2] | athanor_id | exact | as read at allow |
| sign_in:b.memberships[row 2] | created_at | exact | as read at allow |
| sign_in:b.memberships[row 2] | id | exact | as read at allow |
| sign_in:b.memberships[row 2] | person_identifier | exact | as read at allow |
| sign_in:b.memberships[row 2] | scope | exact | as read at allow |
| sign_in:b.memberships[row 2] | status | exact | as read at allow |
| sign_in:b.memberships[row 2] | updated_at | exact | as read at allow |
| sign_in:b.memberships[row 2] | user_id | exact | as read at allow |
| sync:registry.push_tokens[proof][row] | id | captured | a token id: a new UUID, not the nil UUID |
| sync:registry.push_tokens[proof][row] | token_hash | derived | the digest of the token A sealed |
| sync:registry.push_tokens[proof][row] | namespace_slug | exact | `"proof"` |
| sync:registry.push_tokens[proof][row] | label | derived | the label A sealed with the token |
| sync:registry.push_tokens[proof][row] | created_at | bound | a time inside the sync |
| sync:registry.push_tokens[proof][row] | last_used_at | bound | a time inside the sync |
| sync:registry.push_tokens[proof][row] | revoked_at | exact | `null` |
| sync:registry.push_tokens[proof][row] | created_by | derived | A's identifier |
| sync:registry.push_tokens[proof][row] | recovery_epoch | derived | a genesis's recovery epoch, its own hash |
| sync:a.registry_tokens[row] | id | captured | a new rtk_ id |
| sync:a.registry_tokens[row] | user_id | derived | A's person |
| sync:a.registry_tokens[row] | registry | exact | `"registry.registry.test"`: the OCI host, registry. before CYFR_REGISTRY_URL |
| sync:a.registry_tokens[row] | namespace_slug | exact | `"proof"` |
| sync:a.registry_tokens[row] | credential_ciphertext | derived | opens, in A, to the credential below |
| sync:a.registry_tokens[row] | issued_at | bound | a time inside the sync |
| sync:a.registry_tokens[row] | inserted_at | bound | a time inside the sync |
| sync:a.registry_tokens[row] | updated_at | bound | a time inside the sync |
| sync:a.registry_tokens.credential | type | exact | `"push_token"` |
| sync:a.registry_tokens.credential | token | derived | the registry's token_hash for the one @proof token |
| sync:a.registry_tokens.credential | namespace | exact | `"proof"` |
| sync:a.registry_tokens.credential | role | exact | `"personal"`: a personal namespace's role, in `Sanctum.RegistryCredentials`' stored shape (registry_credentials.ex:28) |
| sync:a.registry_tokens.credential | issued_at | derived | the row's issued_at |
| sync:a.registry_tokens.credential | label | derived | the registry's label for that token |
| sync:registry.request_nonces[a][a new nonce] | identifier | derived | the signer's identifier |
| sync:registry.request_nonces[a][a new nonce] | nonce | captured | 16 new bytes |
| sync:registry.request_nonces[a][a new nonce] | expires_at | bound | a time inside the sync, plus the 120 s a signed request lives |
| sync:registry.request_nonces[a][a nonce read at setup 1] | identifier | exact | as read at setup |
| sync:registry.request_nonces[a][a nonce read at setup 1] | nonce | exact | as read at setup |
| sync:registry.request_nonces[a][a nonce read at setup 1] | expires_at | exact | as read at setup |
| sync:registry.request_nonces[a][a nonce read at setup 2] | identifier | exact | as read at setup |
| sync:registry.request_nonces[a][a nonce read at setup 2] | nonce | exact | as read at setup |
| sync:registry.request_nonces[a][a nonce read at setup 2] | expires_at | exact | as read at setup |
| sync:registry.identity_heads[a][row] | identifier | exact | as read at setup |
| sync:registry.identity_heads[a][row] | head | exact | as read at setup |
| sync:registry.identity_heads[a][row] | entries | exact | as read at setup |
| sync:registry.identity_heads[a][row] | recovery_epoch | exact | as read at setup |
| sync:registry.identity_heads[a][row] | key_epoch | exact | as read at setup |
| sync:registry.identity_heads[a][row] | read_at | bound | as read at setup, or a time inside the sync |
| ban:registry.banned_identities[row] | id | captured | a ban id: a new UUID, not the nil UUID |
| ban:registry.banned_identities[row] | banned_at | bound | a time inside the ban |
| ban:registry.banned_identities[row] | banned_by | derived | the registry's admin account the run bootstrapped |
| ban:registry.banned_identities[row] | reason | exact | `"handle proof"` |
| ban:registry.banned_identities[row] | category | exact | `"spam"` |
| ban:registry.banned_identities[row] | expires_at | exact | `null` |
| ban:registry.banned_identities[row] | appeal_allowed_after | exact | `null` |
| ban:registry.banned_identities[row] | related_report_ids | exact | `[]` |
| ban:registry.banned_identities[row] | identifier | derived | A's identifier |
| ban:registry.banned_identities[row] | former_identity | exact | `null` |
| ban:registry.push_tokens[proof][row] | id | exact | as read at sync |
| ban:registry.push_tokens[proof][row] | token_hash | exact | as read at sync |
| ban:registry.push_tokens[proof][row] | namespace_slug | exact | as read at sync |
| ban:registry.push_tokens[proof][row] | label | exact | as read at sync |
| ban:registry.push_tokens[proof][row] | created_at | exact | as read at sync |
| ban:registry.push_tokens[proof][row] | last_used_at | exact | as read at sync |
| ban:registry.push_tokens[proof][row] | revoked_at | bound | a time inside the ban |
| ban:registry.push_tokens[proof][row] | created_by | exact | as read at sync |
| ban:registry.push_tokens[proof][row] | recovery_epoch | exact | as read at sync |
| ban:token_refused | status | exact | `401` |
| ban:token_refused | body | exact | `{"errors":[{"code":"UNAUTHORIZED","message":"token revoked"}]}` |
| ban:a.sync_refused | shown | exact | `"Sync failed: The registry has banned this identity."` |
| ban:a.sync_refused | shared_with | exact | `[]` |
| ban:registry.request_nonces[a][a nonce read at sync 1] | identifier | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 1] | nonce | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 1] | expires_at | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 2] | identifier | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 2] | nonce | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 2] | expires_at | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 3] | identifier | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 3] | nonce | exact | as read at sync |
| ban:registry.request_nonces[a][a nonce read at sync 3] | expires_at | exact | as read at sync |
| held:a.passkeys[row] | activated_at | exact | as read at setup |
| held:a.passkeys[row] | admin_confirmation_id | exact | as read at setup |
| held:a.passkeys[row] | credential_id | exact | as read at setup |
| held:a.passkeys[row] | expires_at | exact | as read at setup |
| held:a.passkeys[row] | id | exact | as read at setup |
| held:a.passkeys[row] | identity_recovery_epoch | exact | as read at setup |
| held:a.passkeys[row] | inserted_at | exact | as read at setup |
| held:a.passkeys[row] | possession_verified | exact | as read at setup |
| held:a.passkeys[row] | public_key | exact | as read at setup |
| held:a.passkeys[row] | registration_digest | exact | as read at setup |
| held:a.passkeys[row] | relying_home | exact | as read at setup |
| held:a.passkeys[row] | revoked_at | exact | as read at setup |
| held:a.passkeys[row] | rp_id | exact | as read at setup |
| held:a.passkeys[row] | sign_count | derived | the authenticator's count for that credential now |
| held:a.passkeys[row] | state | exact | as read at setup |
| held:a.passkeys[row] | updated_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.passkeys[row] | user_id | exact | as read at setup |
| held:a.users[row] | admission | exact | as read at setup |
| held:a.users[row] | created_at | exact | as read at setup |
| held:a.users[row] | denied_at | exact | as read at setup |
| held:a.users[row] | display_name | exact | as read at setup |
| held:a.users[row] | email | exact | as read at setup |
| held:a.users[row] | email_verified | exact | as read at setup |
| held:a.users[row] | first_seen_at | exact | as read at setup |
| held:a.users[row] | id | exact | as read at setup |
| held:a.users[row] | last_seen_at | bound | as read at setup, or a time inside the run from ack's end to the last read |
| held:a.users[row] | namespace | exact | as read at setup |
| held:a.users[row] | personal_athanor_id | exact | as read at setup |
| held:a.users[row] | prefs | exact | as read at setup |
| held:a.users[row] | security_generation | exact | as read at setup |
| held:a.users[row] | status | exact | as read at setup |
| held:a.users[row] | updated_at | bound | as read at setup, or a time inside the run from ack's end to the last read |
| held:a.person_identities[row] | directory_url | exact | as read at setup |
| held:a.person_identities[row] | enrollment | exact | as read at setup |
| held:a.person_identities[row] | first_method_at | exact | as read at setup |
| held:a.person_identities[row] | genesis_hash | exact | as read at setup |
| held:a.person_identities[row] | head_hash | exact | as read at setup |
| held:a.person_identities[row] | id | exact | as read at setup |
| held:a.person_identities[row] | identifier | exact | as read at setup |
| held:a.person_identities[row] | inserted_at | exact | as read at setup |
| held:a.person_identities[row] | live_key_sealed | exact | as read at setup |
| held:a.person_identities[row] | live_public_key | exact | as read at setup |
| held:a.person_identities[row] | operational_key_sealed | exact | as read at setup |
| held:a.person_identities[row] | operational_public_key | exact | as read at setup |
| held:a.person_identities[row] | provenance | exact | as read at setup |
| held:a.person_identities[row] | revision | exact | as read at setup |
| held:a.person_identities[row] | updated_at | exact | as read at setup |
| held:a.person_identities[row] | user_id | exact | as read at setup |
| held:a.athanors[row] | archived_at | exact | as read at setup |
| held:a.athanors[row] | created_at | exact | as read at setup |
| held:a.athanors[row] | created_by | exact | as read at setup |
| held:a.athanors[row] | id | exact | as read at setup |
| held:a.athanors[row] | kind | exact | as read at setup |
| held:a.athanors[row] | name | exact | as read at setup |
| held:a.athanors[row] | owner_user_id | exact | as read at setup |
| held:a.athanors[row] | pair_key | exact | as read at setup |
| held:a.athanors[row] | provisioned_at | exact | as read at setup |
| held:a.athanors[row] | provisioning_failed_at | exact | as read at setup |
| held:a.athanors[row] | provisioning_failure | exact | as read at setup |
| held:a.athanors[row] | roster | exact | as read at setup |
| held:a.athanors[row] | security_generation | exact | as read at setup |
| held:a.athanors[row] | settings | exact | as read at setup |
| held:a.athanors[row] | slug | exact | as read at setup |
| held:a.athanors[row] | status | exact | as read at setup |
| held:a.athanors[row] | updated_at | exact | as read at setup |
| held:a.memberships[the athanor's seat] | added_by | exact | as read at setup |
| held:a.memberships[the athanor's seat] | athanor_id | exact | as read at setup |
| held:a.memberships[the athanor's seat] | created_at | exact | as read at setup |
| held:a.memberships[the athanor's seat] | id | exact | as read at setup |
| held:a.memberships[the athanor's seat] | person_identifier | exact | as read at setup |
| held:a.memberships[the athanor's seat] | scope | exact | as read at setup |
| held:a.memberships[the athanor's seat] | status | exact | as read at setup |
| held:a.memberships[the athanor's seat] | updated_at | exact | as read at setup |
| held:a.memberships[the athanor's seat] | user_id | exact | as read at setup |
| held:a.memberships[the platform grant] | added_by | exact | as read at setup |
| held:a.memberships[the platform grant] | athanor_id | exact | as read at setup |
| held:a.memberships[the platform grant] | created_at | exact | as read at setup |
| held:a.memberships[the platform grant] | id | exact | as read at setup |
| held:a.memberships[the platform grant] | person_identifier | exact | as read at setup |
| held:a.memberships[the platform grant] | scope | exact | as read at setup |
| held:a.memberships[the platform grant] | status | exact | as read at setup |
| held:a.memberships[the platform grant] | updated_at | exact | as read at setup |
| held:a.memberships[the platform grant] | user_id | exact | as read at setup |
| held:a.identity_attempts[row] | directory_url | exact | as read at setup |
| held:a.identity_attempts[row] | entry | exact | as read at setup |
| held:a.identity_attempts[row] | entry_hash | exact | as read at setup |
| held:a.identity_attempts[row] | expected_head | exact | as read at setup |
| held:a.identity_attempts[row] | expected_revision | exact | as read at setup |
| held:a.identity_attempts[row] | genesis | exact | as read at setup |
| held:a.identity_attempts[row] | id | exact | as read at setup |
| held:a.identity_attempts[row] | identifier | exact | as read at setup |
| held:a.identity_attempts[row] | inserted_at | exact | as read at setup |
| held:a.identity_attempts[row] | kind | exact | as read at setup |
| held:a.identity_attempts[row] | kit_acknowledged_at | exact | as read at setup |
| held:a.identity_attempts[row] | kit_seed_sealed | exact | as read at setup |
| held:a.identity_attempts[row] | outcome | exact | as read at setup |
| held:a.identity_attempts[row] | phase | exact | as read at setup |
| held:a.identity_attempts[row] | reproof_challenge_digest | exact | as read at setup |
| held:a.identity_attempts[row] | reproof_expires_at | exact | as read at setup |
| held:a.identity_attempts[row] | request_digest | exact | as read at setup |
| held:a.identity_attempts[row] | request_id | exact | as read at setup |
| held:a.identity_attempts[row] | revision | exact | as read at setup |
| held:a.identity_attempts[row] | staged_live_key_sealed | exact | as read at setup |
| held:a.identity_attempts[row] | staged_live_public_key | exact | as read at setup |
| held:a.identity_attempts[row] | staged_operational_key_sealed | exact | as read at setup |
| held:a.identity_attempts[row] | staged_operational_public_key | exact | as read at setup |
| held:a.identity_attempts[row] | token_digest | exact | as read at setup |
| held:a.identity_attempts[row] | updated_at | exact | as read at setup |
| held:a.identity_attempts[row] | user_id | exact | as read at setup |
| held:a.registry_tokens[row] | credential_ciphertext | exact | as read at sync |
| held:a.registry_tokens[row] | id | exact | as read at sync |
| held:a.registry_tokens[row] | inserted_at | exact | as read at sync |
| held:a.registry_tokens[row] | issued_at | exact | as read at sync |
| held:a.registry_tokens[row] | namespace_slug | exact | as read at sync |
| held:a.registry_tokens[row] | registry | exact | as read at sync |
| held:a.registry_tokens[row] | updated_at | exact | as read at sync |
| held:a.registry_tokens[row] | user_id | exact | as read at sync |
| held:registry.identity_heads[a][row] | identifier | exact | as read at setup |
| held:registry.identity_heads[a][row] | head | exact | as read at setup |
| held:registry.identity_heads[a][row] | entries | exact | as read at setup |
| held:registry.identity_heads[a][row] | recovery_epoch | exact | as read at setup |
| held:registry.identity_heads[a][row] | key_epoch | exact | as read at setup |
| held:registry.identity_heads[a][row] | read_at | bound | as read at sync, or a time inside the run from sync's end to the last read |
| held:registry.policy_acceptances[a][row] | id | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | policy_version | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | accepted_at | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | ip_address | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | user_agent | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | identifier | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | former_identity | exact | as read at setup |
| held:registry.request_nonces[a][a nonce read at sync 1] | identifier | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 1] | nonce | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 1] | expires_at | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 2] | identifier | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 2] | nonce | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 2] | expires_at | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 3] | identifier | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 3] | nonce | exact | as read at ban |
| held:registry.request_nonces[a][a nonce read at sync 3] | expires_at | exact | as read at ban |
| held:registry.push_tokens[proof][row] | id | exact | as read at ban |
| held:registry.push_tokens[proof][row] | token_hash | exact | as read at ban |
| held:registry.push_tokens[proof][row] | namespace_slug | exact | as read at ban |
| held:registry.push_tokens[proof][row] | label | exact | as read at ban |
| held:registry.push_tokens[proof][row] | created_at | exact | as read at ban |
| held:registry.push_tokens[proof][row] | last_used_at | exact | as read at ban |
| held:registry.push_tokens[proof][row] | revoked_at | exact | as read at ban |
| held:registry.push_tokens[proof][row] | created_by | exact | as read at ban |
| held:registry.push_tokens[proof][row] | recovery_epoch | exact | as read at ban |
| held:registry.banned_identities[row] | id | exact | as read at ban |
| held:registry.banned_identities[row] | banned_at | exact | as read at ban |
| held:registry.banned_identities[row] | banned_by | exact | as read at ban |
| held:registry.banned_identities[row] | reason | exact | as read at ban |
| held:registry.banned_identities[row] | category | exact | as read at ban |
| held:registry.banned_identities[row] | expires_at | exact | as read at ban |
| held:registry.banned_identities[row] | appeal_allowed_after | exact | as read at ban |
| held:registry.banned_identities[row] | related_report_ids | exact | as read at ban |
| held:registry.banned_identities[row] | identifier | exact | as read at ban |
| held:registry.banned_identities[row] | former_identity | exact | as read at ban |
| held:b.passkeys[row] | activated_at | exact | as read at allow |
| held:b.passkeys[row] | admin_confirmation_id | exact | as read at allow |
| held:b.passkeys[row] | credential_id | exact | as read at allow |
| held:b.passkeys[row] | expires_at | exact | as read at allow |
| held:b.passkeys[row] | id | exact | as read at allow |
| held:b.passkeys[row] | identity_recovery_epoch | exact | as read at allow |
| held:b.passkeys[row] | inserted_at | exact | as read at allow |
| held:b.passkeys[row] | possession_verified | exact | as read at allow |
| held:b.passkeys[row] | public_key | exact | as read at allow |
| held:b.passkeys[row] | registration_digest | exact | as read at allow |
| held:b.passkeys[row] | relying_home | exact | as read at allow |
| held:b.passkeys[row] | revoked_at | exact | as read at allow |
| held:b.passkeys[row] | rp_id | exact | as read at allow |
| held:b.passkeys[row] | sign_count | exact | as read at allow |
| held:b.passkeys[row] | state | exact | as read at allow |
| held:b.passkeys[row] | updated_at | exact | as read at allow |
| held:b.passkeys[row] | user_id | exact | as read at allow |
| held:b.person_identities[the administrator's] | directory_url | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | enrollment | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | first_method_at | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | genesis_hash | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | head_hash | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | id | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | identifier | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | inserted_at | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | live_key_sealed | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | live_public_key | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | operational_key_sealed | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | operational_public_key | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | provenance | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | revision | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | updated_at | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | user_id | exact | as read at sign_in |
| held:b.person_identities[the person's] | directory_url | exact | as read at sign_in |
| held:b.person_identities[the person's] | enrollment | exact | as read at sign_in |
| held:b.person_identities[the person's] | first_method_at | exact | as read at sign_in |
| held:b.person_identities[the person's] | genesis_hash | exact | as read at sign_in |
| held:b.person_identities[the person's] | head_hash | exact | as read at sign_in |
| held:b.person_identities[the person's] | id | exact | as read at sign_in |
| held:b.person_identities[the person's] | identifier | exact | as read at sign_in |
| held:b.person_identities[the person's] | inserted_at | exact | as read at sign_in |
| held:b.person_identities[the person's] | live_key_sealed | exact | as read at sign_in |
| held:b.person_identities[the person's] | live_public_key | exact | as read at sign_in |
| held:b.person_identities[the person's] | operational_key_sealed | exact | as read at sign_in |
| held:b.person_identities[the person's] | operational_public_key | exact | as read at sign_in |
| held:b.person_identities[the person's] | provenance | exact | as read at sign_in |
| held:b.person_identities[the person's] | revision | exact | as read at sign_in |
| held:b.person_identities[the person's] | updated_at | exact | as read at sign_in |
| held:b.person_identities[the person's] | user_id | exact | as read at sign_in |
| held:b.athanors[row] | archived_at | exact | as read at allow |
| held:b.athanors[row] | created_at | exact | as read at allow |
| held:b.athanors[row] | created_by | exact | as read at allow |
| held:b.athanors[row] | id | exact | as read at allow |
| held:b.athanors[row] | kind | exact | as read at allow |
| held:b.athanors[row] | name | exact | as read at allow |
| held:b.athanors[row] | owner_user_id | exact | as read at allow |
| held:b.athanors[row] | pair_key | exact | as read at allow |
| held:b.athanors[row] | provisioned_at | exact | as read at allow |
| held:b.athanors[row] | provisioning_failed_at | exact | as read at allow |
| held:b.athanors[row] | provisioning_failure | exact | as read at allow |
| held:b.athanors[row] | roster | exact | as read at allow |
| held:b.athanors[row] | security_generation | exact | as read at allow |
| held:b.athanors[row] | settings | exact | as read at allow |
| held:b.athanors[row] | slug | exact | as read at allow |
| held:b.athanors[row] | status | exact | as read at allow |
| held:b.athanors[row] | updated_at | exact | as read at allow |
| held:b.memberships[the athanor's seat] | added_by | exact | as read at allow |
| held:b.memberships[the athanor's seat] | athanor_id | exact | as read at allow |
| held:b.memberships[the athanor's seat] | created_at | exact | as read at allow |
| held:b.memberships[the athanor's seat] | id | exact | as read at allow |
| held:b.memberships[the athanor's seat] | person_identifier | exact | as read at allow |
| held:b.memberships[the athanor's seat] | scope | exact | as read at allow |
| held:b.memberships[the athanor's seat] | status | exact | as read at allow |
| held:b.memberships[the athanor's seat] | updated_at | exact | as read at allow |
| held:b.memberships[the athanor's seat] | user_id | exact | as read at allow |
| held:b.memberships[the platform grant] | added_by | exact | as read at allow |
| held:b.memberships[the platform grant] | athanor_id | exact | as read at allow |
| held:b.memberships[the platform grant] | created_at | exact | as read at allow |
| held:b.memberships[the platform grant] | id | exact | as read at allow |
| held:b.memberships[the platform grant] | person_identifier | exact | as read at allow |
| held:b.memberships[the platform grant] | scope | exact | as read at allow |
| held:b.memberships[the platform grant] | status | exact | as read at allow |
| held:b.memberships[the platform grant] | updated_at | exact | as read at allow |
| held:b.memberships[the platform grant] | user_id | exact | as read at allow |
| held:b.server_allowlist[row] | added_by | exact | as read at allow |
| held:b.server_allowlist[row] | created_at | exact | as read at allow |
| held:b.server_allowlist[row] | effect | exact | as read at allow |
| held:b.server_allowlist[row] | id | exact | as read at allow |
| held:b.server_allowlist[row] | kind | exact | as read at allow |
| held:b.server_allowlist[row] | label | exact | as read at allow |
| held:b.server_allowlist[row] | note | exact | as read at allow |
| held:b.server_allowlist[row] | requested_by | exact | as read at allow |
| held:b.server_allowlist[row] | status | exact | as read at allow |
| held:b.server_allowlist[row] | updated_at | exact | as read at allow |
| held:b.server_allowlist[row] | value | exact | as read at allow |
| held:registry.directory.identity_log_entries[row] | id | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | identifier | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | seq | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | kind | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | entry_hash | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | prev_hash | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | entry | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | request_id | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | request_digest | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | outcome | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | outcome_body | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | bytes | exact | as read at setup |
| held:registry.directory.identity_log_entries[row] | inserted_at | exact | as read at setup |
| held:registry.namespaces[proof][row] | slug | exact | as read at setup |
| held:registry.namespaces[proof][row] | kind | exact | as read at setup |
| held:registry.namespaces[proof][row] | reserved | exact | as read at setup |
| held:registry.namespaces[proof][row] | domain_verified | exact | as read at setup |
| held:registry.namespaces[proof][row] | verify_token | exact | as read at setup |
| held:registry.namespaces[proof][row] | verified_at | exact | as read at setup |
| held:registry.namespaces[proof][row] | last_checked_at | exact | as read at setup |
| held:registry.namespaces[proof][row] | consecutive_failures | exact | as read at setup |
| held:registry.namespaces[proof][row] | display_name | exact | as read at setup |
| held:registry.namespaces[proof][row] | expires_at | exact | as read at setup |
| held:registry.namespaces[proof][row] | created_at | exact | as read at setup |
| held:registry.namespaces[proof][row] | updated_at | exact | as read at setup |
| held:registry.namespaces[proof][row] | owner_identifier | exact | as read at setup |
| held:registry.namespaces[proof][row] | reserved_reason | exact | as read at setup |
| held:b.users[row 1] | admission | exact | as read at sign_in |
| held:b.users[row 1] | created_at | exact | as read at sign_in |
| held:b.users[row 1] | denied_at | exact | as read at sign_in |
| held:b.users[row 1] | display_name | exact | as read at sign_in |
| held:b.users[row 1] | email | exact | as read at sign_in |
| held:b.users[row 1] | email_verified | exact | as read at sign_in |
| held:b.users[row 1] | first_seen_at | exact | as read at sign_in |
| held:b.users[row 1] | id | exact | as read at sign_in |
| held:b.users[row 1] | last_seen_at | bound | as read at sign_in, or a time inside the run from signin's end to the last read |
| held:b.users[row 1] | namespace | exact | as read at sign_in |
| held:b.users[row 1] | personal_athanor_id | exact | as read at sign_in |
| held:b.users[row 1] | prefs | exact | as read at sign_in |
| held:b.users[row 1] | security_generation | exact | as read at sign_in |
| held:b.users[row 1] | status | exact | as read at sign_in |
| held:b.users[row 1] | updated_at | bound | as read at sign_in, or a time inside the run from signin's end to the last read |
| held:b.users[row 2] | admission | exact | as read at sign_in |
| held:b.users[row 2] | created_at | exact | as read at sign_in |
| held:b.users[row 2] | denied_at | exact | as read at sign_in |
| held:b.users[row 2] | display_name | exact | as read at sign_in |
| held:b.users[row 2] | email | exact | as read at sign_in |
| held:b.users[row 2] | email_verified | exact | as read at sign_in |
| held:b.users[row 2] | first_seen_at | exact | as read at sign_in |
| held:b.users[row 2] | id | exact | as read at sign_in |
| held:b.users[row 2] | last_seen_at | bound | as read at sign_in, or a time inside the run from signin's end to the last read |
| held:b.users[row 2] | namespace | exact | as read at sign_in |
| held:b.users[row 2] | personal_athanor_id | exact | as read at sign_in |
| held:b.users[row 2] | prefs | exact | as read at sign_in |
| held:b.users[row 2] | security_generation | exact | as read at sign_in |
| held:b.users[row 2] | status | exact | as read at sign_in |
| held:b.users[row 2] | updated_at | bound | as read at sign_in, or a time inside the run from signin's end to the last read |
| held:b.sessions[the administrator's] | athanor_id | exact | as read at sign_in |
| held:b.sessions[the administrator's] | cli_machine | exact | as read at sign_in |
| held:b.sessions[the administrator's] | email | exact | as read at sign_in |
| held:b.sessions[the administrator's] | expires_at | exact | as read at sign_in |
| held:b.sessions[the administrator's] | id | exact | as read at sign_in |
| held:b.sessions[the administrator's] | identity_key_epoch | exact | as read at sign_in |
| held:b.sessions[the administrator's] | inserted_at | exact | as read at sign_in |
| held:b.sessions[the administrator's] | provider | exact | as read at sign_in |
| held:b.sessions[the administrator's] | token_hash | exact | as read at sign_in |
| held:b.sessions[the administrator's] | token_prefix | exact | as read at sign_in |
| held:b.sessions[the administrator's] | user_id | exact | as read at sign_in |
| held:b.sessions[the person's] | athanor_id | exact | as read at sign_in |
| held:b.sessions[the person's] | cli_machine | exact | as read at sign_in |
| held:b.sessions[the person's] | email | exact | as read at sign_in |
| held:b.sessions[the person's] | expires_at | exact | as read at sign_in |
| held:b.sessions[the person's] | id | exact | as read at sign_in |
| held:b.sessions[the person's] | identity_key_epoch | exact | as read at sign_in |
| held:b.sessions[the person's] | inserted_at | exact | as read at sign_in |
| held:b.sessions[the person's] | provider | exact | as read at sign_in |
| held:b.sessions[the person's] | token_hash | exact | as read at sign_in |
| held:b.sessions[the person's] | token_prefix | exact | as read at sign_in |
| held:b.sessions[the person's] | user_id | exact | as read at sign_in |
