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
Everything the run starts (the cells' servers, the fronts, the registry's
and its database's containers and image, the Playwright container) and
the scratch directory, with the run's authority key and every token, is
removed when it ends, whether it succeeds or fails. `PROOF_RUN_PREFIX`
prefixes every container's name.

## Steps

Chromium runs every step with its virtual WebAuthn authenticator; the
person's passkey for A is copied to the profile that signs in at B, as a
synced passkey is. `proof.mjs` drives the browsers and `run.sh` answers its
asks for the servers' part (`fixture.exs` inside a CYFR, `psql` in the
registry's database, `curl` through the fronts).

| Step | What holds |
|---|---|
| `setup` | A is set up through `/setup` with a passkey; `@proof` is chosen, which runs the enrollment at `dir.test`, confirmed with the passkey; the kit is acknowledged, and only then is the handle claimed at the registry |
| `publish` | Settings at A publishes A's address with `@proof` |
| `allow` | B, set up through `/setup` by its administrator, allows `@proof` in Settings; B's one allowlist entry names A's identifier, labelled `proof` |
| `sign_in` | a fresh profile at B's sign-in page, "I run my own CYFR" with `@proof`, reaches A through the published address, signs in there with the passkey, begins the carry, sees B's code named in A's confirmation, and B admits the person as A's identifier |
| `wrong_identity` | a second identity enrolls at `dir.test`, claims `@other` and publishes A's address with it; the same profile at B with `@other` reaches A, whose carry names A's identifier, and B refuses it with `wrong_identity`'s sentence, admitting nobody and making no session |
| `sync` | Sync push tokens at A, confirmed with the passkey, stores one push token for `@proof`, whose digest is the registry's token for it, made by A's identifier |
| `ban` | the registry's operator bans `@proof`'s owner through the admin pages; the ban revokes the token in its transaction, the token presented to the registry is refused, and A's next sync shows `banned`'s sentence |
| `readme` | this file's field table is the one the proof's models print |

## Whole objects

After each step the proof reads every object the step claims whole: a
CYFR's table, all its columns, through `fixture.exs` (bytes as base64); a
registry table's rows as PostgreSQL's `row_to_json` writes them; an answer
of the registry as its status and body. Each object is compared with a
model in which every field is one of three classes:

- **exact**: the value the step must leave;
- **derived**: a value read from another source, independent of the row
  (the browser's authenticator, the kit's lines, A's own row for B's copy,
  the registry's read of the directory, the other store's digest);
- **bound**: a server-minted value held to a stated bound (a time inside
  the step's window, a key's length, an id's shape).

A field the model does not classify, or a classified field the object
lacks, fails the comparison, and the proof keeps going so one run reports
every mismatch. A refusal shown on a page is compared with
`Prima.Refusal`'s sentence for its reason, read inside the CYFR, and with
the list of other sign-in and sync refusals that share that sentence,
which must be empty.

Once a comparison holds, each field of a stored object is shown failing:
the field is written behind the browsers' back to a value its model
refuses (outside its bound, for a bound field), with the database's own
checks off for that write (on a CYFR, SQLite's foreign keys and CHECK
constraints for the one write; on the registry, foreign keys for the
transaction and the table's CHECK constraints, dropped by the tamper and
added back from their saved definitions by the restore), the object is
read again and the comparison must fail on that field, then the stored
value is written back and the comparison must hold again. An answer's fields are shown failing
through the stored field that makes each (the namespace's slug, owner and
address; the token's `revoked_at`); the sealed credential's through its
ciphertext. Fields no stored value makes (an answer's `status`,
`protocol`, `registry`, `directory`) are held as read and are not shown
failing, and a page's refusal sentence is shown failing against another
reason's sentence.

## Fields

The table the models print (`handle-proof-fields.md` in the output), one
row per field of each step's objects:

| object | field | class | value, source or bound |
|---|---|---|---|
| setup: a.passkeys | id | bound | a CYFR id |
| setup: a.passkeys | user_id | derived | the user id A's one passkey row names (the row whose credential the browser holds) |
| setup: a.passkeys | credential_id | derived | the credential the browser's authenticator holds for a.test, base64url |
| setup: a.passkeys | rp_id | exact | `"a.test"` |
| setup: a.passkeys | relying_home | exact | `"https://a.test"` |
| setup: a.passkeys | public_key | bound | a COSE public key: more than 32 bytes |
| setup: a.passkeys | sign_count | derived | the authenticator's count for that credential |
| setup: a.passkeys | identity_recovery_epoch | exact | `null` |
| setup: a.passkeys | state | exact | `"active"` |
| setup: a.passkeys | registration_digest | bound | a sha256: digest |
| setup: a.passkeys | possession_verified | exact | `1` |
| setup: a.passkeys | expires_at | exact | `null` |
| setup: a.passkeys | admin_confirmation_id | exact | `null` |
| setup: a.passkeys | activated_at | bound | a time inside the run up to the claim |
| setup: a.passkeys | revoked_at | exact | `null` |
| setup: a.passkeys | inserted_at | bound | a time inside the run up to the claim |
| setup: a.passkeys | updated_at | bound | a time inside the run up to the claim |
| setup: a.users | id | derived | the passkey's user id |
| setup: a.users | email | exact | `null` |
| setup: a.users | email_verified | exact | `null` |
| setup: a.users | admission | exact | `"setup"` |
| setup: a.users | display_name | exact | `null` |
| setup: a.users | namespace | exact | `"proof"` |
| setup: a.users | personal_athanor_id | bound | an athanor id |
| setup: a.users | status | exact | `"active"` |
| setup: a.users | prefs | exact | `"{}"` |
| setup: a.users | first_seen_at | bound | a time inside the run up to the claim |
| setup: a.users | last_seen_at | bound | a time inside the run |
| setup: a.users | denied_at | exact | `null` |
| setup: a.users | security_generation | exact | `1` |
| setup: a.users | created_at | bound | a time inside the run up to the claim |
| setup: a.users | updated_at | bound | a time inside the run |
| setup: a.person_identities | id | bound | a CYFR id |
| setup: a.person_identities | user_id | derived | the passkey's user id |
| setup: a.person_identities | identifier | derived | the kit's identifier line, as the browser showed it |
| setup: a.person_identities | provenance | exact | `"local"` |
| setup: a.person_identities | enrollment | exact | `"enrolled"` |
| setup: a.person_identities | live_public_key | bound | an Ed25519 public key: 32 bytes |
| setup: a.person_identities | operational_public_key | bound | an Ed25519 public key: 32 bytes |
| setup: a.person_identities | live_key_sealed | bound | sealed key material: more than 32 bytes |
| setup: a.person_identities | operational_key_sealed | bound | sealed key material: more than 32 bytes |
| setup: a.person_identities | genesis_hash | derived | the identifier's hash, sha256: in place of per_ |
| setup: a.person_identities | head_hash | derived | the head the registry read at dir.test (identity_heads) |
| setup: a.person_identities | directory_url | exact | `"https://dir.test"` |
| setup: a.person_identities | first_method_at | bound | a time inside the run up to the claim |
| setup: a.person_identities | revision | exact | `4`: the row as setup, the enrollment and the kit's acknowledgement leave it |
| setup: a.person_identities | inserted_at | bound | a time inside the run up to the claim |
| setup: a.person_identities | updated_at | bound | a time inside the run up to the claim |
| setup: registry.namespaces[proof] | slug | exact | `"proof"` |
| setup: registry.namespaces[proof] | kind | exact | `"personal"` |
| setup: registry.namespaces[proof] | reserved | exact | `false` |
| setup: registry.namespaces[proof] | domain_verified | exact | `false` |
| setup: registry.namespaces[proof] | verify_token | exact | `null` |
| setup: registry.namespaces[proof] | verified_at | exact | `null` |
| setup: registry.namespaces[proof] | last_checked_at | exact | `null` |
| setup: registry.namespaces[proof] | consecutive_failures | exact | `0` |
| setup: registry.namespaces[proof] | display_name | exact | `null` |
| setup: registry.namespaces[proof] | expires_at | exact | `null` |
| setup: registry.namespaces[proof] | created_at | bound | a time inside the run up to the claim |
| setup: registry.namespaces[proof] | updated_at | bound | a time inside the run up to the claim |
| setup: registry.namespaces[proof] | owner_identifier | derived | the kit's identifier |
| setup: registry.namespaces[proof] | address | exact | `null` |
| setup: registry.namespaces[proof] | reserved_reason | exact | `null` |
| setup: registry.identity_heads | identifier | derived | the kit's identifier |
| setup: registry.identity_heads | head | derived | A's own head (person_identities.head_hash) |
| setup: registry.identity_heads | entries | exact | `1` |
| setup: registry.identity_heads | recovery_epoch | bound | a recovery epoch |
| setup: registry.identity_heads | key_epoch | bound | a key epoch |
| setup: registry.identity_heads | read_at | bound | a time inside the run up to the claim |
| setup: handle_answer[proof] | status | exact | `200` |
| setup: handle_answer[proof] | protocol | exact | `"cyfr-handle/v1"` |
| setup: handle_answer[proof] | registry | exact | `"registry.test"` |
| setup: handle_answer[proof] | handle | exact | `"proof"` |
| setup: handle_answer[proof] | identifier | derived | the kit's identifier |
| setup: handle_answer[proof] | directory | exact | `"https://dir.test"` |
| publish: registry.namespaces[proof] | slug | exact | `"proof"` |
| publish: registry.namespaces[proof] | kind | exact | `"personal"` |
| publish: registry.namespaces[proof] | reserved | exact | `false` |
| publish: registry.namespaces[proof] | domain_verified | exact | `false` |
| publish: registry.namespaces[proof] | verify_token | exact | `null` |
| publish: registry.namespaces[proof] | verified_at | exact | `null` |
| publish: registry.namespaces[proof] | last_checked_at | exact | `null` |
| publish: registry.namespaces[proof] | consecutive_failures | exact | `0` |
| publish: registry.namespaces[proof] | display_name | exact | `null` |
| publish: registry.namespaces[proof] | expires_at | exact | `null` |
| publish: registry.namespaces[proof] | created_at | bound | a time inside the run up to the claim |
| publish: registry.namespaces[proof] | updated_at | bound | a time inside the run up to the publication |
| publish: registry.namespaces[proof] | owner_identifier | derived | the kit's identifier |
| publish: registry.namespaces[proof] | address | exact | `"https://a.test"` |
| publish: registry.namespaces[proof] | reserved_reason | exact | `null` |
| publish: handle_answer[proof] | status | exact | `200` |
| publish: handle_answer[proof] | protocol | exact | `"cyfr-handle/v1"` |
| publish: handle_answer[proof] | registry | exact | `"registry.test"` |
| publish: handle_answer[proof] | handle | exact | `"proof"` |
| publish: handle_answer[proof] | identifier | derived | the kit's identifier |
| publish: handle_answer[proof] | directory | exact | `"https://dir.test"` |
| publish: handle_answer[proof] | address | exact | `"https://a.test"` |
| allow: b.server_allowlist | id | bound | a CYFR id |
| allow: b.server_allowlist | kind | exact | `"identifier"` |
| allow: b.server_allowlist | value | derived | the identifier @proof names at the registry (A's kit) |
| allow: b.server_allowlist | effect | exact | `"allow"` |
| allow: b.server_allowlist | status | exact | `"allowed"` |
| allow: b.server_allowlist | requested_by | exact | `null` |
| allow: b.server_allowlist | added_by | derived | B's administrator: the user of B's passkey the admin's browser holds |
| allow: b.server_allowlist | note | exact | `null` |
| allow: b.server_allowlist | label | exact | `"proof"` |
| allow: b.server_allowlist | created_at | bound | a time inside the run up to the allow |
| allow: b.server_allowlist | updated_at | bound | a time inside the run up to the allow |
| sign_in: b.person_identities[proof] | id | bound | a CYFR id |
| sign_in: b.person_identities[proof] | user_id | derived | the user B's identity row for A's identifier names |
| sign_in: b.person_identities[proof] | identifier | derived | A's kit |
| sign_in: b.person_identities[proof] | provenance | exact | `"remote"` |
| sign_in: b.person_identities[proof] | enrollment | exact | `"enrolled"` |
| sign_in: b.person_identities[proof] | live_public_key | exact | `null`: B keeps no copy of a remote person's keys here; it reads them at the directory |
| sign_in: b.person_identities[proof] | operational_public_key | exact | `null` |
| sign_in: b.person_identities[proof] | live_key_sealed | exact | `null` |
| sign_in: b.person_identities[proof] | operational_key_sealed | exact | `null` |
| sign_in: b.person_identities[proof] | genesis_hash | derived | the identifier's hash, sha256: in place of per_ |
| sign_in: b.person_identities[proof] | head_hash | derived | A's own head |
| sign_in: b.person_identities[proof] | directory_url | exact | `"https://dir.test"` |
| sign_in: b.person_identities[proof] | first_method_at | exact | `null` |
| sign_in: b.person_identities[proof] | revision | exact | `1` |
| sign_in: b.person_identities[proof] | inserted_at | bound | a time inside the run up to B's admission |
| sign_in: b.person_identities[proof] | updated_at | bound | a time inside the run up to B's admission |
| sign_in: b.users[proof] | id | derived | B's identity row for A's identifier |
| sign_in: b.users[proof] | email | exact | `null` |
| sign_in: b.users[proof] | email_verified | exact | `null` |
| sign_in: b.users[proof] | admission | exact | `"remote"` |
| sign_in: b.users[proof] | display_name | exact | `null` |
| sign_in: b.users[proof] | namespace | exact | `null` |
| sign_in: b.users[proof] | personal_athanor_id | exact | `null` |
| sign_in: b.users[proof] | status | exact | `"active"` |
| sign_in: b.users[proof] | prefs | exact | `"{}"` |
| sign_in: b.users[proof] | first_seen_at | bound | a time inside the run up to B's admission |
| sign_in: b.users[proof] | last_seen_at | bound | a time inside the run |
| sign_in: b.users[proof] | denied_at | exact | `null` |
| sign_in: b.users[proof] | security_generation | exact | `1` |
| sign_in: b.users[proof] | created_at | bound | a time inside the run up to B's admission |
| sign_in: b.users[proof] | updated_at | bound | a time inside the run |
| sign_in: b.sessions[proof] | id | bound | a CYFR id |
| sign_in: b.sessions[proof] | token_hash | bound | a SHA-256 digest: 32 bytes |
| sign_in: b.sessions[proof] | token_prefix | bound | the session token's first 8 characters |
| sign_in: b.sessions[proof] | user_id | derived | B's identity row for A's identifier |
| sign_in: b.sessions[proof] | email | exact | `null` |
| sign_in: b.sessions[proof] | provider | exact | `"cyfr"` |
| sign_in: b.sessions[proof] | expires_at | bound | after the sign-in |
| sign_in: b.sessions[proof] | athanor_id | exact | `null` |
| sign_in: b.sessions[proof] | identity_key_epoch | derived | the key epoch the registry read at dir.test |
| sign_in: b.sessions[proof] | cli_machine | exact | `null` |
| sign_in: b.sessions[proof] | inserted_at | bound | a time inside the run up to B's admission |
| wrong_identity: handle_answer[other] | status | exact | `200` |
| wrong_identity: handle_answer[other] | protocol | exact | `"cyfr-handle/v1"` |
| wrong_identity: handle_answer[other] | registry | exact | `"registry.test"` |
| wrong_identity: handle_answer[other] | handle | exact | `"other"` |
| wrong_identity: handle_answer[other] | identifier | derived | the second identity's genesis |
| wrong_identity: handle_answer[other] | directory | exact | `"https://dir.test"` |
| wrong_identity: handle_answer[other] | address | exact | `"https://a.test"` |
| wrong_identity: b.sign_in_error | shown | exact | `"That sign-in came from someone other than the handle you named, so nobody was signed in."` |
| wrong_identity: b.sign_in_error | shared_with | exact | `[]` |
| wrong_identity: b.users[0] | admission | exact | the value read before the attempt |
| wrong_identity: b.users[0] | created_at | exact | the value read before the attempt |
| wrong_identity: b.users[0] | denied_at | exact | the value read before the attempt |
| wrong_identity: b.users[0] | display_name | exact | the value read before the attempt |
| wrong_identity: b.users[0] | email | exact | the value read before the attempt |
| wrong_identity: b.users[0] | email_verified | exact | the value read before the attempt |
| wrong_identity: b.users[0] | first_seen_at | exact | the value read before the attempt |
| wrong_identity: b.users[0] | id | exact | the value read before the attempt |
| wrong_identity: b.users[0] | last_seen_at | bound | not before the value read before the attempt |
| wrong_identity: b.users[0] | namespace | exact | the value read before the attempt |
| wrong_identity: b.users[0] | personal_athanor_id | exact | the value read before the attempt |
| wrong_identity: b.users[0] | prefs | exact | the value read before the attempt |
| wrong_identity: b.users[0] | security_generation | exact | the value read before the attempt |
| wrong_identity: b.users[0] | status | exact | the value read before the attempt |
| wrong_identity: b.users[0] | updated_at | bound | not before the value read before the attempt |
| wrong_identity: b.users[1] | admission | exact | the value read before the attempt |
| wrong_identity: b.users[1] | created_at | exact | the value read before the attempt |
| wrong_identity: b.users[1] | denied_at | exact | the value read before the attempt |
| wrong_identity: b.users[1] | display_name | exact | the value read before the attempt |
| wrong_identity: b.users[1] | email | exact | the value read before the attempt |
| wrong_identity: b.users[1] | email_verified | exact | the value read before the attempt |
| wrong_identity: b.users[1] | first_seen_at | exact | the value read before the attempt |
| wrong_identity: b.users[1] | id | exact | the value read before the attempt |
| wrong_identity: b.users[1] | last_seen_at | bound | not before the value read before the attempt |
| wrong_identity: b.users[1] | namespace | exact | the value read before the attempt |
| wrong_identity: b.users[1] | personal_athanor_id | exact | the value read before the attempt |
| wrong_identity: b.users[1] | prefs | exact | the value read before the attempt |
| wrong_identity: b.users[1] | security_generation | exact | the value read before the attempt |
| wrong_identity: b.users[1] | status | exact | the value read before the attempt |
| wrong_identity: b.users[1] | updated_at | bound | not before the value read before the attempt |
| wrong_identity: b.sessions[0] | athanor_id | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | cli_machine | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | email | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | expires_at | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | id | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | identity_key_epoch | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | inserted_at | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | provider | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | token_hash | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | token_prefix | exact | the value read before the attempt |
| wrong_identity: b.sessions[0] | user_id | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | athanor_id | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | cli_machine | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | email | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | expires_at | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | id | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | identity_key_epoch | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | inserted_at | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | provider | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | token_hash | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | token_prefix | exact | the value read before the attempt |
| wrong_identity: b.sessions[1] | user_id | exact | the value read before the attempt |
| sync: a.registry_tokens | id | bound | a CYFR id |
| sync: a.registry_tokens | user_id | derived | A's person |
| sync: a.registry_tokens | registry | exact | `"registry.registry.test"`: the OCI host, registry. before CYFR_REGISTRY_URL |
| sync: a.registry_tokens | namespace_slug | exact | `"proof"` |
| sync: a.registry_tokens | credential_ciphertext | bound | sealed credential: more than 32 bytes |
| sync: a.registry_tokens | issued_at | bound | a time inside the run up to the sync |
| sync: a.registry_tokens | inserted_at | bound | a time inside the run up to the sync |
| sync: a.registry_tokens | updated_at | bound | a time inside the run up to the sync |
| sync: a.registry_tokens.credential | type | exact | `"push_token"` |
| sync: a.registry_tokens.credential | token | derived | the registry's token_hash for the one @proof token |
| sync: a.registry_tokens.credential | namespace | exact | `"proof"` |
| sync: a.registry_tokens.credential | role | exact | `"personal"` |
| sync: a.registry_tokens.credential | issued_at | derived | the row's issued_at |
| sync: a.registry_tokens.credential | label | derived | the registry's label for that token |
| sync: registry.push_tokens[proof] | id | bound | an id: a UUID, not the nil UUID |
| sync: registry.push_tokens[proof] | token_hash | derived | the digest of the token A sealed (a.registry_tokens.credential) |
| sync: registry.push_tokens[proof] | namespace_slug | exact | `"proof"` |
| sync: registry.push_tokens[proof] | label | derived | the label A sealed with the token |
| sync: registry.push_tokens[proof] | created_at | bound | a time inside the run up to the sync |
| sync: registry.push_tokens[proof] | last_used_at | bound | a time inside the run up to the sync |
| sync: registry.push_tokens[proof] | revoked_at | exact | `null` |
| sync: registry.push_tokens[proof] | created_by | derived | A's identifier |
| sync: registry.push_tokens[proof] | recovery_epoch | derived | the recovery epoch the registry read at dir.test |
| ban: registry.banned_identities | id | bound | an id: a UUID, not the nil UUID |
| ban: registry.banned_identities | banned_at | bound | a time inside the sync's end to the ban's answer |
| ban: registry.banned_identities | banned_by | bound | the operator account's id: a UUID, not the nil UUID |
| ban: registry.banned_identities | reason | exact | `"handle proof"` |
| ban: registry.banned_identities | category | exact | `"spam"` |
| ban: registry.banned_identities | expires_at | exact | `null` |
| ban: registry.banned_identities | appeal_allowed_after | exact | `null` |
| ban: registry.banned_identities | related_report_ids | exact | `[]` |
| ban: registry.banned_identities | identifier | derived | A's identifier |
| ban: registry.banned_identities | former_identity | exact | `null` |
| ban: registry.push_tokens[proof] | id | derived | the token the sync minted |
| ban: registry.push_tokens[proof] | token_hash | derived | the token the sync minted |
| ban: registry.push_tokens[proof] | namespace_slug | exact | `"proof"` |
| ban: registry.push_tokens[proof] | label | derived | the label A sealed with the token |
| ban: registry.push_tokens[proof] | created_at | derived | the token the sync minted |
| ban: registry.push_tokens[proof] | last_used_at | derived | the token the sync minted, as the sync left it |
| ban: registry.push_tokens[proof] | revoked_at | bound | a time inside the sync's end to the ban's answer |
| ban: registry.push_tokens[proof] | created_by | derived | A's identifier |
| ban: registry.push_tokens[proof] | recovery_epoch | derived | the recovery epoch the registry read at dir.test |
| ban: token_refused | status | exact | `401` |
| ban: token_refused | body | exact | `{"errors":[{"code":"UNAUTHORIZED","message":"token revoked"}]}` |
| ban: a.sync_refused | shown | exact | `"Sync failed: The registry has banned this identity."` |
| ban: a.sync_refused | shared_with | exact | `[]` |
