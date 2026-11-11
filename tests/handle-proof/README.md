# The handle proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a name at
the registry names the account another CYFR allows, and that the person
signs in there with their passkey, typing no address: a person makes
their account `@proof` at the registry's account pages and sets up their
CYFR A with it; B's administrator, with an account of their own, sets B
up and allows `@proof`; the person's passkey, synced to a browser that
never visited B, signs them in at B's sign-in page; a push token the
passkey signs for at A is stored at both ends, and a ban at the registry
retires it.

The registry, directory and account pages are cyfr.run's own, built from
the checkout `CYFR_RUN_DIR` names. CI cannot read that source, so CI never
runs this proof; without `CYFR_RUN_DIR` the script says it did not run and
why, and exits 0.

```bash
CYFR_RUN_DIR=<cyfr.run checkout> scripts/heavy-check.sh -q 1 -- tests/handle-proof/run.sh
```

## What runs

| Part | Name | Configured |
|---|---|---|
| A | `a.test` | a `cyfr` release with a `CYFR_SETUP_TOKEN` of its own; reads accounts at `CYFR_DIRECTORY_URL=https://registry.test` and names at `CYFR_REGISTRY_URL=registry.test` |
| B | `b.test` | the same, with its own setup token |
| the registry, directory and account pages | `registry.test` | cyfr.run's image, built from `git archive HEAD` of `CYFR_RUN_DIR` by its `Dockerfile`, on a `postgres:16-alpine` of the run's own, with `DOMAIN=registry.test`, behind a front of the identity proof's kind on `127.77.0.3` for the CYFRs, and routed by the browsers' proxy to its listener (`startProxy`'s `routed`) |

The model checks run independently with
`node --test tests/handle-proof/models-test.mjs`. The PostgreSQL tamper
helper's checks run with
`scripts/heavy-check.sh -q 1 -- bash tests/handle-proof/registry-test.sh`.

The directory's rows are read from `directory.entries` in the registry's
PostgreSQL. Their canonical entries, hashes, lengths and timestamps are
checked and tampered as every other row; a row is found by its entry's
hash.

The CYFRs reach the registry by name through their `ERL_INETRC` at an
address listed in `CYFR_PRIVATE_EGRESS_TARGETS`, and trust the run's
authority (`tests/identity-proof/cells.sh`). No DNS, `/etc/hosts`, trust
store or other configuration outside the scratch directory is read or
changed. cyfr.run's smoke person (`cmd/smokeid`, built from the same
checkout) computes the TOTP code the registry's admin sign-in takes.

Everything the run starts is removed when it ends, on every exit path, a
signal included: the cells' servers, the fronts, the registry's container
and image, its database's container and its named volume
(`<prefix>cyfr-handle-proof-<pid>-pgdata`), the Playwright container, and
the scratch directory with the run's authority key and every token.
`PROOF_RUN_PREFIX` prefixes every container's and volume's name. The one
exception is the release: it is built through `tests/release-boot/release.sh`
into the shared `_build/prod_release_boot_sqlite` with its reuse stamp,
under the proof's own heavy-check, as every other release proof builds it.

## Steps

Chromium runs every step with its virtual WebAuthn authenticator
(`tests/browser/account.mjs`); the person's passkey is copied to the
profile that signs in at B, as a synced passkey is. `proof.mjs` drives the
browsers and `run.sh` answers its asks for the servers' part (`fixture.exs`
inside a CYFR, `psql` in the registry's database, including its
`directory` schema, `curl` through the front). `models.mjs` holds every
object's model, the comparison and the tamper loop, apart from the
browsers, so the models can be rebuilt from a run's record.

| Step | What holds |
|---|---|
| `setup` | `@proof` is made at `registry.test`'s `/account/new`: the registry's policy accepted, the recovery code shown and saved, then the passkey. The directory holds the account's genesis and the passkey's `add_key`, and the registry holds `@proof` owned by the account's identifier, that identifier's acceptance of its policy, the nonces of the two requests the recovery key signed and its read of the log, and answers `@proof` with the identifier and `https://registry.test`. A is then set up by signing in with the account through its setup link; A's person (with the platform administrator's mark), identity, cached head, athanor and paired client (the passkey, by its kid) are read whole |
| `allow` | B's administrator makes `@proof-b` at the pages, sets B up with it, and allows `@proof` in Settings; B's allowlist holds setup's allow of the administrator's identifier and `@proof`'s identifier labelled `proof`; B's person, identity and athanor are its administrator's |
| `sign_in` | a fresh profile holding the person's passkey opens B's sign-in page and signs in with the account, typing no address: the sign page says "Sign in to https://b.test", and B admits the identifier under its allow (`admission` `open`), with an athanor of their own there; B's identities, people, athanors, cached heads, paired clients and sessions are read whole, each session bound to its passkey's kid and head and holding the token its browser's cookie carries |
| `sync` | "Sync push tokens" at A opens the sign page, which shows the registry request in words ("Create a publishing token named … at registry.test"); the passkey signs it, A completes it and says "Your push tokens are synced."; A stores one push token for `@proof`, whose digest is the registry's token for it, made by the account's identifier |
| `ban` | the registry's operator bans `@proof`'s owner through the admin pages; the ban revokes the token in its transaction, the token presented to the registry is refused, A's next sync says banned's sentence and records no nonce; then every object read in the run is read again and held to what was read before |
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
  the browser's authenticator (a passkey's credential id, and the kid its
  private key's public point gives), the browser's session cookie (the
  token's SHA-256 and first 8 characters, read inside the CYFR that set
  it), the recovery code, the directory's stored entries (the identifier is
  the genesis's hash; a head is its last entry's hash; the recovery epoch
  is the genesis's hash), the run's admin account, the other store's
  digest;
- **captured**: a value the server generated, read here for the first
  time, that no other source names (a row id, a nonce, a cached head's
  verified state): held to its shape and to the value its first read
  read, and exact at every later read;
- **bound**: a time the server stamps, inside a window whose two ends are
  the proof's own clock readings around the step (5 ms either side for the
  stamp's resolution); a session's `expires_at` is derived exactly, as its
  `inserted_at` plus `session_ttl_hours`.

A field whose value is related to another source, an entry's bytes or a
sealed credential, is held once that relationship is checked: an entry
hashes to the identifier or lists the authenticator's key, a credential
opens inside the CYFR that sealed it. A field the model does not classify, or a classified
field the object lacks, fails the comparison, and the proof keeps going so
one run reports every mismatch. A list's rows are matched by what each
holds (a nonce by its bytes, a log entry by its
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
with the fields later steps move (a person's `last_seen_at`, a cached
head's `verified_at`, the
registry's `read_at`) each held to its own source or
window. Every loop that ran is recorded by its row's identity (store,
table and the row's own key, never its position) and the predicate it ran
under; at this last read a field's loop is skipped only when the
identical predicate (equality to the same value) already ran on that same
row, so a time once held to a window and now exact runs its loop again,
and so does a row a later step first read. The run prints how many tamper
loops ran, how many controls were refused, and names each field with no
loop and why.

The table's rows of a list are labelled by what each row is (a nonce
as read at a step or new, a session by whose it is),
never by the order the run read them in, so the table is the same
whatever that order.

## Fields

The table the models print (`handle-proof-fields.md` in the output), one
row per field of each row of each step's objects:

| object | field | class | value, source or bound |
|---|---|---|---|
| setup:registry.directory.entries[a][the genesis] | identifier | derived | the identifier the recovery code names |
| setup:registry.directory.entries[a][the genesis] | seq | exact | `0` |
| setup:registry.directory.entries[a][the genesis] | kind | exact | `"genesis"` |
| setup:registry.directory.entries[a][the genesis] | entry_hash | derived | the identifier's digits: the genesis's hash |
| setup:registry.directory.entries[a][the genesis] | prev_hash | exact | `null` |
| setup:registry.directory.entries[a][the genesis] | entry | derived | the genesis the page signed: its bytes hash to the identifier, and it names registry.test |
| setup:registry.directory.entries[a][the genesis] | bytes | derived | the entry's length |
| setup:registry.directory.entries[a][the genesis] | inserted_at | bound | a time inside the account made at registry.test's pages |
| setup:registry.directory.entries[a][the passkey's add_key] | identifier | derived | the identifier the recovery code names |
| setup:registry.directory.entries[a][the passkey's add_key] | seq | exact | `1` |
| setup:registry.directory.entries[a][the passkey's add_key] | kind | exact | `"add_key"` |
| setup:registry.directory.entries[a][the passkey's add_key] | entry_hash | derived | the entry's bytes, hashed |
| setup:registry.directory.entries[a][the passkey's add_key] | prev_hash | derived | the genesis's hash |
| setup:registry.directory.entries[a][the passkey's add_key] | entry | derived | the passkey's add_key: after the genesis, listing the key and credential the browser's authenticator holds |
| setup:registry.directory.entries[a][the passkey's add_key] | bytes | derived | the entry's length |
| setup:registry.directory.entries[a][the passkey's add_key] | inserted_at | bound | a time inside the account made at registry.test's pages |
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
| setup:registry.namespaces[proof][row] | created_at | bound | a time inside the account made at registry.test's pages |
| setup:registry.namespaces[proof][row] | updated_at | bound | a time inside the account made at registry.test's pages |
| setup:registry.namespaces[proof][row] | owner_identifier | derived | the identifier the recovery code names |
| setup:registry.namespaces[proof][row] | reserved_reason | exact | `null` |
| setup:registry.identity_heads[a][row] | identifier | derived | the identifier the recovery code names |
| setup:registry.identity_heads[a][row] | head | derived | the add_key's hash: the head of the log the claim was verified against |
| setup:registry.identity_heads[a][row] | entries | exact | `2` |
| setup:registry.identity_heads[a][row] | recovery_epoch | derived | the genesis's hash: no recover entry since |
| setup:registry.identity_heads[a][row] | read_at | bound | a time inside the account made at registry.test's pages |
| setup:registry.policy_acceptances[a][row] | id | captured | an acceptance id: a new UUID, not the nil UUID |
| setup:registry.policy_acceptances[a][row] | policy_version | derived | the registry's GET /v1/legal/version |
| setup:registry.policy_acceptances[a][row] | accepted_at | bound | a time inside the account made at registry.test's pages |
| setup:registry.policy_acceptances[a][row] | identifier | derived | the signer's identifier |
| setup:registry.policy_acceptances[a][row] | former_identity | exact | `null` |
| setup:registry.request_nonces[a][row 1] | identifier | derived | the signer's identifier |
| setup:registry.request_nonces[a][row 1] | nonce | captured | 16 new bytes |
| setup:registry.request_nonces[a][row 1] | expires_at | bound | a time inside the account made at registry.test's pages, plus the 120 s a signed request lives |
| setup:registry.request_nonces[a][row 2] | identifier | derived | the signer's identifier |
| setup:registry.request_nonces[a][row 2] | nonce | captured | 16 new bytes |
| setup:registry.request_nonces[a][row 2] | expires_at | bound | a time inside the account made at registry.test's pages, plus the 120 s a signed request lives |
| setup:handle_answer[proof] | status | exact | `200` |
| setup:handle_answer[proof] | protocol | exact | `"cyfr-handle/v1"` |
| setup:handle_answer[proof] | registry | exact | `"registry.test"` |
| setup:handle_answer[proof] | handle | exact | `"proof"` |
| setup:handle_answer[proof] | identifier | derived | the owner's genesis, hashed |
| setup:handle_answer[proof] | directory | exact | `"https://registry.test"` |
| setup:a.users[row] | id | captured | a new usr_ id |
| setup:a.users[row] | email | exact | `null` |
| setup:a.users[row] | email_verified | exact | `null` |
| setup:a.users[row] | admission | exact | `"setup"` |
| setup:a.users[row] | display_name | exact | `null` |
| setup:a.users[row] | namespace | exact | `"proof"`: the name the registry says the account holds, learned at the sign-in (`Sanctum.SignIn`) |
| setup:a.users[row] | status | exact | `"active"` |
| setup:a.users[row] | prefs | exact | `"{}"` |
| setup:a.users[row] | first_seen_at | bound | a time inside setup at A |
| setup:a.users[row] | last_seen_at | bound | a time inside setup at A up to setup:a.users's read |
| setup:a.users[row] | denied_at | exact | `null` |
| setup:a.users[row] | platform_admin_at | bound | a time inside setup at A |
| setup:a.users[row] | security_generation | exact | `1` |
| setup:a.users[row] | created_at | bound | a time inside setup at A |
| setup:a.users[row] | updated_at | bound | a time inside setup at A up to setup:a.users's read |
| setup:a.athanors[row] | id | captured | a new ath_ id |
| setup:a.athanors[row] | name | exact | `"Me"` |
| setup:a.athanors[row] | slug | exact | `"me"` |
| setup:a.athanors[row] | owner_user_id | derived | its person |
| setup:a.athanors[row] | status | exact | `"active"` |
| setup:a.athanors[row] | archived_at | exact | `null` |
| setup:a.athanors[row] | created_by | derived | its person |
| setup:a.athanors[row] | settings | exact | `null` |
| setup:a.athanors[row] | provisioned_at | bound | null, or a time inside setup at A up to setup:a.athanors's read |
| setup:a.athanors[row] | provisioning_failed_at | exact | `null` |
| setup:a.athanors[row] | provisioning_failure | exact | `null` |
| setup:a.athanors[row] | security_generation | exact | `1` |
| setup:a.athanors[row] | created_at | bound | a time inside setup at A |
| setup:a.athanors[row] | updated_at | bound | a time inside setup at A up to setup:a.athanors's read |
| setup:a.person_identities[row] | id | captured | a new pid_ id |
| setup:a.person_identities[row] | user_id | derived | its person |
| setup:a.person_identities[row] | identifier | derived | the account's identifier |
| setup:a.person_identities[row] | head_hash | derived | the head of the account's log when it was admitted |
| setup:a.person_identities[row] | directory_url | exact | `"https://registry.test"` |
| setup:a.person_identities[row] | revision | exact | `1` |
| setup:a.person_identities[row] | inserted_at | bound | a time inside setup at A |
| setup:a.person_identities[row] | updated_at | bound | a time inside setup at A |
| setup:a.directory_heads[row] | identifier | derived | the account's identifier |
| setup:a.directory_heads[row] | genesis | derived | the genesis the directory stores, as its JCS text |
| setup:a.directory_heads[row] | directory_url | exact | `"https://registry.test"` |
| setup:a.directory_heads[row] | head_hash | derived | the head of the account's log as the directory serves it |
| setup:a.directory_heads[row] | state | captured | the verified state the head leaves, as JSON text |
| setup:a.directory_heads[row] | keys_added | captured | when each listed key was added, as JSON text |
| setup:a.directory_heads[row] | verified_at | bound | a time inside setup at A up to setup:a.directory_heads's read |
| setup:a.directory_heads[row] | gone_at | exact | `null` |
| setup:a.directory_heads[row] | revision | captured | the cached head's revision |
| setup:a.directory_heads[row] | inserted_at | bound | a time inside setup at A |
| setup:a.directory_heads[row] | updated_at | bound | a time inside setup at A up to setup:a.directory_heads's read |
| setup:a.paired_clients[row] | id | captured | a new pcl_ id |
| setup:a.paired_clients[row] | athanor_id | derived | the person's own athanor here |
| setup:a.paired_clients[row] | user_id | derived | its person |
| setup:a.paired_clients[row] | source_kind | exact | `"passkey"` |
| setup:a.paired_clients[row] | source_id | derived | the client's own id |
| setup:a.paired_clients[row] | device_public_key | exact | `null` |
| setup:a.paired_clients[row] | standing | exact | `"active"` |
| setup:a.paired_clients[row] | holder_kind | exact | `null` |
| setup:a.paired_clients[row] | display_name | exact | `null` |
| setup:a.paired_clients[row] | kid | derived | the kid of the key the browser's authenticator holds |
| setup:a.paired_clients[row] | head | derived | the head it signed in under |
| setup:a.paired_clients[row] | inserted_at | bound | a time inside setup at A |
| setup:a.paired_clients[row] | updated_at | bound | a time inside setup at A |
| allow:b.users[row] | id | captured | a new usr_ id |
| allow:b.users[row] | email | exact | `null` |
| allow:b.users[row] | email_verified | exact | `null` |
| allow:b.users[row] | admission | exact | `"setup"` |
| allow:b.users[row] | display_name | exact | `null` |
| allow:b.users[row] | namespace | exact | `"proof-b"`: the name the registry says the account holds, learned at the sign-in (`Sanctum.SignIn`) |
| allow:b.users[row] | status | exact | `"active"` |
| allow:b.users[row] | prefs | exact | `"{}"` |
| allow:b.users[row] | first_seen_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.users[row] | last_seen_at | bound | a time inside B's administrator's account and setup at B up to allow:b.users's read |
| allow:b.users[row] | denied_at | exact | `null` |
| allow:b.users[row] | platform_admin_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.users[row] | security_generation | exact | `1` |
| allow:b.users[row] | created_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.users[row] | updated_at | bound | a time inside B's administrator's account and setup at B up to allow:b.users's read |
| allow:b.athanors[row] | id | captured | a new ath_ id |
| allow:b.athanors[row] | name | exact | `"Me"` |
| allow:b.athanors[row] | slug | exact | `"me"` |
| allow:b.athanors[row] | owner_user_id | derived | its person |
| allow:b.athanors[row] | status | exact | `"active"` |
| allow:b.athanors[row] | archived_at | exact | `null` |
| allow:b.athanors[row] | created_by | derived | its person |
| allow:b.athanors[row] | settings | exact | `null` |
| allow:b.athanors[row] | provisioned_at | bound | null, or a time inside B's administrator's account and setup at B up to allow:b.athanors's read |
| allow:b.athanors[row] | provisioning_failed_at | exact | `null` |
| allow:b.athanors[row] | provisioning_failure | exact | `null` |
| allow:b.athanors[row] | security_generation | exact | `1` |
| allow:b.athanors[row] | created_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.athanors[row] | updated_at | bound | a time inside B's administrator's account and setup at B up to allow:b.athanors's read |
| allow:b.person_identities[row] | id | captured | a new pid_ id |
| allow:b.person_identities[row] | user_id | derived | its person |
| allow:b.person_identities[row] | identifier | captured | the administrator's identifier, per_ and 64 hexadecimal digits |
| allow:b.person_identities[row] | head_hash | captured | the head of the administrator's log |
| allow:b.person_identities[row] | directory_url | exact | `"https://registry.test"` |
| allow:b.person_identities[row] | revision | exact | `1` |
| allow:b.person_identities[row] | inserted_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.person_identities[row] | updated_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.server_allowlist[setup's allow of the administrator] | id | captured | a new door_ id |
| allow:b.server_allowlist[setup's allow of the administrator] | kind | exact | `"identifier"` |
| allow:b.server_allowlist[setup's allow of the administrator] | value | derived | the administrator's identifier |
| allow:b.server_allowlist[setup's allow of the administrator] | effect | exact | `"allow"` |
| allow:b.server_allowlist[setup's allow of the administrator] | status | exact | `"allowed"` |
| allow:b.server_allowlist[setup's allow of the administrator] | requested_by | exact | `null` |
| allow:b.server_allowlist[setup's allow of the administrator] | added_by | derived | B's administrator |
| allow:b.server_allowlist[setup's allow of the administrator] | note | exact | `"setup"` |
| allow:b.server_allowlist[setup's allow of the administrator] | label | exact | `null` |
| allow:b.server_allowlist[setup's allow of the administrator] | created_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.server_allowlist[setup's allow of the administrator] | updated_at | bound | a time inside B's administrator's account and setup at B |
| allow:b.server_allowlist[the allow of @proof] | id | captured | a new door_ id |
| allow:b.server_allowlist[the allow of @proof] | kind | exact | `"identifier"` |
| allow:b.server_allowlist[the allow of @proof] | value | derived | the identifier @proof names at the registry |
| allow:b.server_allowlist[the allow of @proof] | effect | exact | `"allow"` |
| allow:b.server_allowlist[the allow of @proof] | status | exact | `"allowed"` |
| allow:b.server_allowlist[the allow of @proof] | requested_by | exact | `null` |
| allow:b.server_allowlist[the allow of @proof] | added_by | derived | B's administrator |
| allow:b.server_allowlist[the allow of @proof] | note | exact | `null` |
| allow:b.server_allowlist[the allow of @proof] | label | exact | `"proof"` |
| allow:b.server_allowlist[the allow of @proof] | created_at | bound | a time inside the allow |
| allow:b.server_allowlist[the allow of @proof] | updated_at | bound | a time inside the allow |
| sign_in:b.person_identities[the administrator's] | directory_url | exact | as read at allow |
| sign_in:b.person_identities[the administrator's] | head_hash | exact | as read at allow |
| sign_in:b.person_identities[the administrator's] | id | exact | as read at allow |
| sign_in:b.person_identities[the administrator's] | identifier | exact | as read at allow |
| sign_in:b.person_identities[the administrator's] | inserted_at | exact | as read at allow |
| sign_in:b.person_identities[the administrator's] | revision | exact | as read at allow |
| sign_in:b.person_identities[the administrator's] | updated_at | exact | as read at allow |
| sign_in:b.person_identities[the administrator's] | user_id | exact | as read at allow |
| sign_in:b.person_identities[the person's] | id | captured | a new pid_ id |
| sign_in:b.person_identities[the person's] | user_id | derived | its person |
| sign_in:b.person_identities[the person's] | identifier | derived | the account's identifier |
| sign_in:b.person_identities[the person's] | head_hash | derived | the head of the account's log when it was admitted |
| sign_in:b.person_identities[the person's] | directory_url | exact | `"https://registry.test"` |
| sign_in:b.person_identities[the person's] | revision | exact | `1` |
| sign_in:b.person_identities[the person's] | inserted_at | bound | a time inside the sign-in at B |
| sign_in:b.person_identities[the person's] | updated_at | bound | a time inside the sign-in at B |
| sign_in:b.athanors[the administrator's] | archived_at | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | created_at | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | created_by | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | id | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | name | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | owner_user_id | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | provisioned_at | bound | as read at allow, or a time inside the sign-in at B |
| sign_in:b.athanors[the administrator's] | provisioning_failed_at | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | provisioning_failure | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | security_generation | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | settings | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | slug | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | status | exact | as read at allow |
| sign_in:b.athanors[the administrator's] | updated_at | bound | as read at allow, or a time inside the sign-in at B |
| sign_in:b.athanors[the person's] | id | captured | a new ath_ id |
| sign_in:b.athanors[the person's] | name | exact | `"Me"` |
| sign_in:b.athanors[the person's] | slug | exact | `"me-2"` |
| sign_in:b.athanors[the person's] | owner_user_id | derived | its person |
| sign_in:b.athanors[the person's] | status | exact | `"active"` |
| sign_in:b.athanors[the person's] | archived_at | exact | `null` |
| sign_in:b.athanors[the person's] | created_by | derived | its person |
| sign_in:b.athanors[the person's] | settings | exact | `null` |
| sign_in:b.athanors[the person's] | provisioned_at | bound | null, or a time inside the sign-in at B up to sign_in:b.athanors's read |
| sign_in:b.athanors[the person's] | provisioning_failed_at | exact | `null` |
| sign_in:b.athanors[the person's] | provisioning_failure | exact | `null` |
| sign_in:b.athanors[the person's] | security_generation | exact | `1` |
| sign_in:b.athanors[the person's] | created_at | bound | a time inside the sign-in at B |
| sign_in:b.athanors[the person's] | updated_at | bound | a time inside the sign-in at B up to sign_in:b.athanors's read |
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
| sign_in:b.users[the administrator's] | platform_admin_at | exact | as read at allow |
| sign_in:b.users[the administrator's] | prefs | exact | as read at allow |
| sign_in:b.users[the administrator's] | security_generation | exact | as read at allow |
| sign_in:b.users[the administrator's] | status | exact | as read at allow |
| sign_in:b.users[the administrator's] | updated_at | bound | as read at allow, or a time inside the sign-in at B |
| sign_in:b.users[the person's] | id | derived | B's identity row for A's identifier |
| sign_in:b.users[the person's] | email | exact | `null` |
| sign_in:b.users[the person's] | email_verified | exact | `null` |
| sign_in:b.users[the person's] | admission | exact | `"open"` |
| sign_in:b.users[the person's] | display_name | exact | `null` |
| sign_in:b.users[the person's] | namespace | exact | `"proof"`: the name the registry says the account holds, learned at the sign-in (`Sanctum.SignIn`) |
| sign_in:b.users[the person's] | status | exact | `"active"` |
| sign_in:b.users[the person's] | prefs | exact | `"{}"` |
| sign_in:b.users[the person's] | first_seen_at | bound | a time inside the sign-in at B |
| sign_in:b.users[the person's] | last_seen_at | bound | a time inside the sign-in at B up to sign_in:b.users's read |
| sign_in:b.users[the person's] | denied_at | exact | `null` |
| sign_in:b.users[the person's] | platform_admin_at | exact | `null` |
| sign_in:b.users[the person's] | security_generation | exact | `1` |
| sign_in:b.users[the person's] | created_at | bound | a time inside the sign-in at B |
| sign_in:b.users[the person's] | updated_at | bound | a time inside the sign-in at B up to sign_in:b.users's read |
| sign_in:b.directory_heads[the administrator's] | identifier | derived | the account's identifier |
| sign_in:b.directory_heads[the administrator's] | genesis | captured | the administrator's genesis |
| sign_in:b.directory_heads[the administrator's] | directory_url | exact | `"https://registry.test"` |
| sign_in:b.directory_heads[the administrator's] | head_hash | derived | the head of the account's log as the directory serves it |
| sign_in:b.directory_heads[the administrator's] | state | captured | the verified state the head leaves, as JSON text |
| sign_in:b.directory_heads[the administrator's] | keys_added | captured | when each listed key was added, as JSON text |
| sign_in:b.directory_heads[the administrator's] | verified_at | bound | a time inside B's administrator's account and setup at B up to sign_in:b.directory_heads's read |
| sign_in:b.directory_heads[the administrator's] | gone_at | exact | `null` |
| sign_in:b.directory_heads[the administrator's] | revision | captured | the cached head's revision |
| sign_in:b.directory_heads[the administrator's] | inserted_at | bound | a time inside B's administrator's account and setup at B |
| sign_in:b.directory_heads[the administrator's] | updated_at | bound | a time inside B's administrator's account and setup at B up to sign_in:b.directory_heads's read |
| sign_in:b.directory_heads[the person's, read at the allow] | identifier | derived | the account's identifier |
| sign_in:b.directory_heads[the person's, read at the allow] | genesis | derived | the genesis the directory stores, as its JCS text |
| sign_in:b.directory_heads[the person's, read at the allow] | directory_url | exact | `"https://registry.test"` |
| sign_in:b.directory_heads[the person's, read at the allow] | head_hash | derived | the head of the account's log as the directory serves it |
| sign_in:b.directory_heads[the person's, read at the allow] | state | captured | the verified state the head leaves, as JSON text |
| sign_in:b.directory_heads[the person's, read at the allow] | keys_added | captured | when each listed key was added, as JSON text |
| sign_in:b.directory_heads[the person's, read at the allow] | verified_at | bound | a time inside the allow up to sign_in:b.directory_heads's read |
| sign_in:b.directory_heads[the person's, read at the allow] | gone_at | exact | `null` |
| sign_in:b.directory_heads[the person's, read at the allow] | revision | captured | the cached head's revision |
| sign_in:b.directory_heads[the person's, read at the allow] | inserted_at | bound | a time inside the allow |
| sign_in:b.directory_heads[the person's, read at the allow] | updated_at | bound | a time inside the allow up to sign_in:b.directory_heads's read |
| sign_in:b.paired_clients[the administrator's] | id | captured | a new pcl_ id |
| sign_in:b.paired_clients[the administrator's] | athanor_id | derived | the person's own athanor here |
| sign_in:b.paired_clients[the administrator's] | user_id | derived | its person |
| sign_in:b.paired_clients[the administrator's] | source_kind | exact | `"passkey"` |
| sign_in:b.paired_clients[the administrator's] | source_id | derived | the client's own id |
| sign_in:b.paired_clients[the administrator's] | device_public_key | exact | `null` |
| sign_in:b.paired_clients[the administrator's] | standing | exact | `"active"` |
| sign_in:b.paired_clients[the administrator's] | holder_kind | exact | `null` |
| sign_in:b.paired_clients[the administrator's] | display_name | exact | `null` |
| sign_in:b.paired_clients[the administrator's] | kid | derived | the kid of the key the administrator's authenticator holds |
| sign_in:b.paired_clients[the administrator's] | head | derived | the head it signed in under |
| sign_in:b.paired_clients[the administrator's] | inserted_at | bound | a time inside B's administrator's account and setup at B |
| sign_in:b.paired_clients[the administrator's] | updated_at | bound | a time inside B's administrator's account and setup at B |
| sign_in:b.paired_clients[the person's] | id | captured | a new pcl_ id |
| sign_in:b.paired_clients[the person's] | athanor_id | derived | the person's own athanor here |
| sign_in:b.paired_clients[the person's] | user_id | derived | its person |
| sign_in:b.paired_clients[the person's] | source_kind | exact | `"passkey"` |
| sign_in:b.paired_clients[the person's] | source_id | derived | the client's own id |
| sign_in:b.paired_clients[the person's] | device_public_key | exact | `null` |
| sign_in:b.paired_clients[the person's] | standing | exact | `"active"` |
| sign_in:b.paired_clients[the person's] | holder_kind | exact | `null` |
| sign_in:b.paired_clients[the person's] | display_name | exact | `null` |
| sign_in:b.paired_clients[the person's] | kid | derived | the kid of the key the browser's authenticator holds |
| sign_in:b.paired_clients[the person's] | head | derived | the head it signed in under |
| sign_in:b.paired_clients[the person's] | inserted_at | bound | a time inside the sign-in at B |
| sign_in:b.paired_clients[the person's] | updated_at | bound | a time inside the sign-in at B |
| sign_in:b.sessions[the administrator's] | id | captured | a new ses_ id |
| sign_in:b.sessions[the administrator's] | token_hash | derived | the SHA-256 of the session token the browser's cookie carries |
| sign_in:b.sessions[the administrator's] | token_prefix | derived | the first 8 characters of that token |
| sign_in:b.sessions[the administrator's] | user_id | derived | its person |
| sign_in:b.sessions[the administrator's] | email | exact | `null` |
| sign_in:b.sessions[the administrator's] | provider | exact | `"passkey"` |
| sign_in:b.sessions[the administrator's] | expires_at | derived | inserted_at plus session_ttl_hours (Sanctum.Session) |
| sign_in:b.sessions[the administrator's] | athanor_id | derived | the person's own athanor here |
| sign_in:b.sessions[the administrator's] | kid | derived | the kid of the key the browser's authenticator holds |
| sign_in:b.sessions[the administrator's] | head | derived | the head it signed in under |
| sign_in:b.sessions[the administrator's] | client_id | derived | the passkey's paired client here |
| sign_in:b.sessions[the administrator's] | browser | captured | the browser the sign-in's user agent names, in words |
| sign_in:b.sessions[the administrator's] | system | captured | the system the sign-in's user agent names, in words |
| sign_in:b.sessions[the administrator's] | last_seen_at | bound | a time inside B's administrator's account and setup at B |
| sign_in:b.sessions[the administrator's] | inserted_at | bound | a time inside B's administrator's account and setup at B |
| sign_in:b.sessions[the person's] | id | captured | a new ses_ id |
| sign_in:b.sessions[the person's] | token_hash | derived | the SHA-256 of the session token the browser's cookie carries |
| sign_in:b.sessions[the person's] | token_prefix | derived | the first 8 characters of that token |
| sign_in:b.sessions[the person's] | user_id | derived | its person |
| sign_in:b.sessions[the person's] | email | exact | `null` |
| sign_in:b.sessions[the person's] | provider | exact | `"passkey"` |
| sign_in:b.sessions[the person's] | expires_at | derived | inserted_at plus session_ttl_hours (Sanctum.Session) |
| sign_in:b.sessions[the person's] | athanor_id | derived | the person's own athanor here |
| sign_in:b.sessions[the person's] | kid | derived | the kid of the key the browser's authenticator holds |
| sign_in:b.sessions[the person's] | head | derived | the head it signed in under |
| sign_in:b.sessions[the person's] | client_id | derived | the passkey's paired client here |
| sign_in:b.sessions[the person's] | browser | captured | the browser the sign-in's user agent names, in words |
| sign_in:b.sessions[the person's] | system | captured | the system the sign-in's user agent names, in words |
| sign_in:b.sessions[the person's] | last_seen_at | bound | a time inside the sign-in at B |
| sign_in:b.sessions[the person's] | inserted_at | bound | a time inside the sign-in at B |
| sync:registry.push_tokens[proof][row] | id | captured | a token id: a new UUID, not the nil UUID |
| sync:registry.push_tokens[proof][row] | token_hash | derived | the digest of the token A sealed |
| sync:registry.push_tokens[proof][row] | namespace_slug | exact | `"proof"` |
| sync:registry.push_tokens[proof][row] | label | derived | the label A sealed with the token |
| sync:registry.push_tokens[proof][row] | created_at | bound | a time inside the sync |
| sync:registry.push_tokens[proof][row] | last_used_at | exact | `null` |
| sync:registry.push_tokens[proof][row] | revoked_at | exact | `null` |
| sync:registry.push_tokens[proof][row] | created_by | derived | A's identifier |
| sync:registry.push_tokens[proof][row] | recovery_epoch | derived | the genesis's hash: no recover entry since |
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
| sync:a.registry_tokens.credential | role | exact | `"personal"`: a personal namespace's role, in `Sanctum.RegistryCredentials`' stored shape |
| sync:a.registry_tokens.credential | issued_at | derived | the row's issued_at |
| sync:a.registry_tokens.credential | label | derived | the registry's label for that token |
| sync:registry.request_nonces[a][a new nonce] | identifier | derived | the signer's identifier |
| sync:registry.request_nonces[a][a new nonce] | nonce | captured | 16 new bytes |
| sync:registry.request_nonces[a][a new nonce] | expires_at | bound | a time inside the sync, plus the 300 s a request a CYFR mints for a passkey lives |
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
| ban:a.sync_refused | shown | exact | `"That did not go through: The registry has banned this identity."` |
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
| held:a.users[row] | admission | exact | as read at setup |
| held:a.users[row] | created_at | exact | as read at setup |
| held:a.users[row] | denied_at | exact | as read at setup |
| held:a.users[row] | display_name | exact | as read at setup |
| held:a.users[row] | email | exact | as read at setup |
| held:a.users[row] | email_verified | exact | as read at setup |
| held:a.users[row] | first_seen_at | exact | as read at setup |
| held:a.users[row] | id | exact | as read at setup |
| held:a.users[row] | last_seen_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.users[row] | namespace | exact | as read at setup |
| held:a.users[row] | platform_admin_at | exact | as read at setup |
| held:a.users[row] | prefs | exact | as read at setup |
| held:a.users[row] | security_generation | exact | as read at setup |
| held:a.users[row] | status | exact | as read at setup |
| held:a.users[row] | updated_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.person_identities[row] | directory_url | exact | as read at setup |
| held:a.person_identities[row] | head_hash | exact | as read at setup |
| held:a.person_identities[row] | id | exact | as read at setup |
| held:a.person_identities[row] | identifier | exact | as read at setup |
| held:a.person_identities[row] | inserted_at | exact | as read at setup |
| held:a.person_identities[row] | revision | exact | as read at setup |
| held:a.person_identities[row] | updated_at | exact | as read at setup |
| held:a.person_identities[row] | user_id | exact | as read at setup |
| held:a.athanors[row] | archived_at | exact | as read at setup |
| held:a.athanors[row] | created_at | exact | as read at setup |
| held:a.athanors[row] | created_by | exact | as read at setup |
| held:a.athanors[row] | id | exact | as read at setup |
| held:a.athanors[row] | name | exact | as read at setup |
| held:a.athanors[row] | owner_user_id | exact | as read at setup |
| held:a.athanors[row] | provisioned_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.athanors[row] | provisioning_failed_at | exact | as read at setup |
| held:a.athanors[row] | provisioning_failure | exact | as read at setup |
| held:a.athanors[row] | security_generation | exact | as read at setup |
| held:a.athanors[row] | settings | exact | as read at setup |
| held:a.athanors[row] | slug | exact | as read at setup |
| held:a.athanors[row] | status | exact | as read at setup |
| held:a.athanors[row] | updated_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.directory_heads[row] | directory_url | exact | as read at setup |
| held:a.directory_heads[row] | genesis | exact | as read at setup |
| held:a.directory_heads[row] | gone_at | exact | as read at setup |
| held:a.directory_heads[row] | head_hash | exact | as read at setup |
| held:a.directory_heads[row] | identifier | exact | as read at setup |
| held:a.directory_heads[row] | inserted_at | exact | as read at setup |
| held:a.directory_heads[row] | keys_added | exact | as read at setup |
| held:a.directory_heads[row] | revision | captured | the cached head's revision, moved by each read since |
| held:a.directory_heads[row] | state | exact | as read at setup |
| held:a.directory_heads[row] | updated_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.directory_heads[row] | verified_at | bound | as read at setup, or a time inside the run from setup's end to the last read |
| held:a.paired_clients[row] | athanor_id | exact | as read at setup |
| held:a.paired_clients[row] | device_public_key | exact | as read at setup |
| held:a.paired_clients[row] | display_name | exact | as read at setup |
| held:a.paired_clients[row] | head | exact | as read at setup |
| held:a.paired_clients[row] | holder_kind | exact | as read at setup |
| held:a.paired_clients[row] | id | exact | as read at setup |
| held:a.paired_clients[row] | inserted_at | exact | as read at setup |
| held:a.paired_clients[row] | kid | exact | as read at setup |
| held:a.paired_clients[row] | source_id | exact | as read at setup |
| held:a.paired_clients[row] | source_kind | exact | as read at setup |
| held:a.paired_clients[row] | standing | exact | as read at setup |
| held:a.paired_clients[row] | updated_at | exact | as read at setup |
| held:a.paired_clients[row] | user_id | exact | as read at setup |
| held:a.registry_tokens[row] | credential_ciphertext | exact | as read at sync |
| held:a.registry_tokens[row] | id | exact | as read at sync |
| held:a.registry_tokens[row] | inserted_at | exact | as read at sync |
| held:a.registry_tokens[row] | issued_at | exact | as read at sync |
| held:a.registry_tokens[row] | namespace_slug | exact | as read at sync |
| held:a.registry_tokens[row] | registry | exact | as read at sync |
| held:a.registry_tokens[row] | updated_at | exact | as read at sync |
| held:a.registry_tokens[row] | user_id | exact | as read at sync |
| held:registry.directory.entries[a][the genesis] | identifier | exact | as read at setup |
| held:registry.directory.entries[a][the genesis] | seq | exact | as read at setup |
| held:registry.directory.entries[a][the genesis] | kind | exact | as read at setup |
| held:registry.directory.entries[a][the genesis] | entry_hash | exact | as read at setup |
| held:registry.directory.entries[a][the genesis] | prev_hash | exact | as read at setup |
| held:registry.directory.entries[a][the genesis] | entry | exact | as read at setup |
| held:registry.directory.entries[a][the genesis] | bytes | exact | as read at setup |
| held:registry.directory.entries[a][the genesis] | inserted_at | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | identifier | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | seq | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | kind | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | entry_hash | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | prev_hash | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | entry | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | bytes | exact | as read at setup |
| held:registry.directory.entries[a][the passkey's add_key] | inserted_at | exact | as read at setup |
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
| held:registry.identity_heads[a][row] | identifier | exact | as read at setup |
| held:registry.identity_heads[a][row] | head | exact | as read at setup |
| held:registry.identity_heads[a][row] | entries | exact | as read at setup |
| held:registry.identity_heads[a][row] | recovery_epoch | exact | as read at setup |
| held:registry.identity_heads[a][row] | read_at | bound | as read at sync, or a time inside the run from sync's end to the last read |
| held:registry.policy_acceptances[a][row] | id | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | policy_version | exact | as read at setup |
| held:registry.policy_acceptances[a][row] | accepted_at | exact | as read at setup |
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
| held:b.users[the administrator's] | admission | exact | as read at sign_in |
| held:b.users[the administrator's] | created_at | exact | as read at sign_in |
| held:b.users[the administrator's] | denied_at | exact | as read at sign_in |
| held:b.users[the administrator's] | display_name | exact | as read at sign_in |
| held:b.users[the administrator's] | email | exact | as read at sign_in |
| held:b.users[the administrator's] | email_verified | exact | as read at sign_in |
| held:b.users[the administrator's] | first_seen_at | exact | as read at sign_in |
| held:b.users[the administrator's] | id | exact | as read at sign_in |
| held:b.users[the administrator's] | last_seen_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.users[the administrator's] | namespace | exact | as read at sign_in |
| held:b.users[the administrator's] | platform_admin_at | exact | as read at sign_in |
| held:b.users[the administrator's] | prefs | exact | as read at sign_in |
| held:b.users[the administrator's] | security_generation | exact | as read at sign_in |
| held:b.users[the administrator's] | status | exact | as read at sign_in |
| held:b.users[the administrator's] | updated_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.users[the person's] | admission | exact | as read at sign_in |
| held:b.users[the person's] | created_at | exact | as read at sign_in |
| held:b.users[the person's] | denied_at | exact | as read at sign_in |
| held:b.users[the person's] | display_name | exact | as read at sign_in |
| held:b.users[the person's] | email | exact | as read at sign_in |
| held:b.users[the person's] | email_verified | exact | as read at sign_in |
| held:b.users[the person's] | first_seen_at | exact | as read at sign_in |
| held:b.users[the person's] | id | exact | as read at sign_in |
| held:b.users[the person's] | last_seen_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.users[the person's] | namespace | exact | as read at sign_in |
| held:b.users[the person's] | platform_admin_at | exact | as read at sign_in |
| held:b.users[the person's] | prefs | exact | as read at sign_in |
| held:b.users[the person's] | security_generation | exact | as read at sign_in |
| held:b.users[the person's] | status | exact | as read at sign_in |
| held:b.users[the person's] | updated_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.person_identities[the administrator's] | directory_url | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | head_hash | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | id | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | identifier | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | inserted_at | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | revision | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | updated_at | exact | as read at sign_in |
| held:b.person_identities[the administrator's] | user_id | exact | as read at sign_in |
| held:b.person_identities[the person's] | directory_url | exact | as read at sign_in |
| held:b.person_identities[the person's] | head_hash | exact | as read at sign_in |
| held:b.person_identities[the person's] | id | exact | as read at sign_in |
| held:b.person_identities[the person's] | identifier | exact | as read at sign_in |
| held:b.person_identities[the person's] | inserted_at | exact | as read at sign_in |
| held:b.person_identities[the person's] | revision | exact | as read at sign_in |
| held:b.person_identities[the person's] | updated_at | exact | as read at sign_in |
| held:b.person_identities[the person's] | user_id | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | athanor_id | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | device_public_key | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | display_name | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | head | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | holder_kind | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | id | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | inserted_at | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | kid | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | source_id | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | source_kind | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | standing | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | updated_at | exact | as read at sign_in |
| held:b.paired_clients[the administrator's] | user_id | exact | as read at sign_in |
| held:b.paired_clients[the person's] | athanor_id | exact | as read at sign_in |
| held:b.paired_clients[the person's] | device_public_key | exact | as read at sign_in |
| held:b.paired_clients[the person's] | display_name | exact | as read at sign_in |
| held:b.paired_clients[the person's] | head | exact | as read at sign_in |
| held:b.paired_clients[the person's] | holder_kind | exact | as read at sign_in |
| held:b.paired_clients[the person's] | id | exact | as read at sign_in |
| held:b.paired_clients[the person's] | inserted_at | exact | as read at sign_in |
| held:b.paired_clients[the person's] | kid | exact | as read at sign_in |
| held:b.paired_clients[the person's] | source_id | exact | as read at sign_in |
| held:b.paired_clients[the person's] | source_kind | exact | as read at sign_in |
| held:b.paired_clients[the person's] | standing | exact | as read at sign_in |
| held:b.paired_clients[the person's] | updated_at | exact | as read at sign_in |
| held:b.paired_clients[the person's] | user_id | exact | as read at sign_in |
| held:b.sessions[the administrator's] | athanor_id | exact | as read at sign_in |
| held:b.sessions[the administrator's] | browser | exact | as read at sign_in |
| held:b.sessions[the administrator's] | client_id | exact | as read at sign_in |
| held:b.sessions[the administrator's] | email | exact | as read at sign_in |
| held:b.sessions[the administrator's] | expires_at | exact | as read at sign_in |
| held:b.sessions[the administrator's] | head | exact | as read at sign_in |
| held:b.sessions[the administrator's] | id | exact | as read at sign_in |
| held:b.sessions[the administrator's] | inserted_at | exact | as read at sign_in |
| held:b.sessions[the administrator's] | kid | exact | as read at sign_in |
| held:b.sessions[the administrator's] | last_seen_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.sessions[the administrator's] | provider | exact | as read at sign_in |
| held:b.sessions[the administrator's] | system | exact | as read at sign_in |
| held:b.sessions[the administrator's] | token_hash | exact | as read at sign_in |
| held:b.sessions[the administrator's] | token_prefix | exact | as read at sign_in |
| held:b.sessions[the administrator's] | user_id | exact | as read at sign_in |
| held:b.sessions[the person's] | athanor_id | exact | as read at sign_in |
| held:b.sessions[the person's] | browser | exact | as read at sign_in |
| held:b.sessions[the person's] | client_id | exact | as read at sign_in |
| held:b.sessions[the person's] | email | exact | as read at sign_in |
| held:b.sessions[the person's] | expires_at | exact | as read at sign_in |
| held:b.sessions[the person's] | head | exact | as read at sign_in |
| held:b.sessions[the person's] | id | exact | as read at sign_in |
| held:b.sessions[the person's] | inserted_at | exact | as read at sign_in |
| held:b.sessions[the person's] | kid | exact | as read at sign_in |
| held:b.sessions[the person's] | last_seen_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.sessions[the person's] | provider | exact | as read at sign_in |
| held:b.sessions[the person's] | system | exact | as read at sign_in |
| held:b.sessions[the person's] | token_hash | exact | as read at sign_in |
| held:b.sessions[the person's] | token_prefix | exact | as read at sign_in |
| held:b.sessions[the person's] | user_id | exact | as read at sign_in |
| held:b.athanors[the administrator's] | archived_at | exact | as read at sign_in |
| held:b.athanors[the administrator's] | created_at | exact | as read at sign_in |
| held:b.athanors[the administrator's] | created_by | exact | as read at sign_in |
| held:b.athanors[the administrator's] | id | exact | as read at sign_in |
| held:b.athanors[the administrator's] | name | exact | as read at sign_in |
| held:b.athanors[the administrator's] | owner_user_id | exact | as read at sign_in |
| held:b.athanors[the administrator's] | provisioned_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.athanors[the administrator's] | provisioning_failed_at | exact | as read at sign_in |
| held:b.athanors[the administrator's] | provisioning_failure | exact | as read at sign_in |
| held:b.athanors[the administrator's] | security_generation | exact | as read at sign_in |
| held:b.athanors[the administrator's] | settings | exact | as read at sign_in |
| held:b.athanors[the administrator's] | slug | exact | as read at sign_in |
| held:b.athanors[the administrator's] | status | exact | as read at sign_in |
| held:b.athanors[the administrator's] | updated_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.athanors[the person's] | archived_at | exact | as read at sign_in |
| held:b.athanors[the person's] | created_at | exact | as read at sign_in |
| held:b.athanors[the person's] | created_by | exact | as read at sign_in |
| held:b.athanors[the person's] | id | exact | as read at sign_in |
| held:b.athanors[the person's] | name | exact | as read at sign_in |
| held:b.athanors[the person's] | owner_user_id | exact | as read at sign_in |
| held:b.athanors[the person's] | provisioned_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.athanors[the person's] | provisioning_failed_at | exact | as read at sign_in |
| held:b.athanors[the person's] | provisioning_failure | exact | as read at sign_in |
| held:b.athanors[the person's] | security_generation | exact | as read at sign_in |
| held:b.athanors[the person's] | settings | exact | as read at sign_in |
| held:b.athanors[the person's] | slug | exact | as read at sign_in |
| held:b.athanors[the person's] | status | exact | as read at sign_in |
| held:b.athanors[the person's] | updated_at | bound | as read at signin, or a time inside the run from signin's end to the last read |
| held:b.server_allowlist[setup's allow of the administrator] | added_by | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | created_at | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | effect | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | id | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | kind | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | label | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | note | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | requested_by | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | status | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | updated_at | exact | as read at allow |
| held:b.server_allowlist[setup's allow of the administrator] | value | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | added_by | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | created_at | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | effect | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | id | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | kind | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | label | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | note | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | requested_by | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | status | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | updated_at | exact | as read at allow |
| held:b.server_allowlist[the allow of @proof] | value | exact | as read at allow |
