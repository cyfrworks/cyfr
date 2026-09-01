# Design note — keyring fingerprint at boot

**Status:** proposed, not implemented. This note exists because the fix is
a boot-refuse, and a boot-refuse that can brick a volume restore is not
something to write before the restore story is settled.

## The defect

`Cyfr.Application.resolve_crypto_keyring!/0` treats a `nil` and an empty
`CYFR_CRYPTO_KEYRING` identically: both fall through to
`derive_keyring_from_secret_key_base!/0`, which hashes
`"cyfr-cipher-keyring|" <> secret_key_base` into a single key labelled
`"default"`.

Nothing records which material a deployment actually booted with. So:

1. An operator runs with an explicit keyring whose primary is `"default"`.
2. `CYFR_CRYPTO_KEYRING` is later lost — unset, blanked by a bad `.env`,
   dropped by a deploy template.
3. Boot silently derives a *different* key, also labelled `"default"`.
4. Rows sealed before step 3 fail `{:error, {:decrypt, :aad_or_key_mismatch}}`
   while every new write succeeds under the derived key.

The athanor forks into two key generations with no boundary event. The
only signal is a `Logger.warning`, gated on `release?/0`, that says
nothing about the change — it describes the zero-config posture, which is
also a legitimate steady state.

The label is what makes this silent. `Sanctum.Cipher`'s envelope carries
the key *label*, so a mismatch is caught per-row at decrypt time and reads
as data corruption, not as a configuration change. Two different keys both
called `"default"` are indistinguishable until something fails to open.

## What the fix must do

Persist a fingerprint of the keyring at first boot, and compare on every
subsequent boot. On mismatch: refuse to start, unless an explicit migrate
flag says the change is intended.

`sha256("cyfr-keyring-fingerprint|" <> primary_label <> "|" <> primary_key)`
is enough — it identifies the material without being usable to derive it.
Fingerprint the **primary** only; a keyring that gains a decrypt-only
secondary is a rotation in progress, not a fork.

## The three open questions

### 1. Where does the fingerprint live — file or database?

**Database** (a `server_meta` row, or a column beside the existing
singleton settings) is consistent with everything else the server
remembers, survives container replacement, and is what a multi-node
deployment shares. But it is inside the store whose contents the
fingerprint exists to protect, and the check has to run before anything
opens a sealed value — which is early, but after the repo is up. That is
the same window `Arca.TenantTables.verify_roster!/0` already occupies, so
the precedent exists.

**File** (under `data/system/`) boots earlier and needs no repo. But it is
per-volume, so a two-node deployment has two of them and they can disagree
silently — exactly the failure being fixed, one layer down. And a restore
that brings back the database without the volume, or the reverse, gets a
false answer either way.

*Leaning: database.* The file's independence is illusory once there is
more than one node, and the roster check already established that a
repo-dependent boot assertion is acceptable.

### 2. What does a restore look like?

This is the question that blocks implementation. Four cases, and the fix
must answer all four without an operator having to guess:

- **Same DB, same keyring** — normal boot, fingerprints match.
- **Same DB, deliberately rotated keyring** — the migrate flag. The
  operator is saying "I know, re-key". But nothing re-keys existing rows
  today; `Sanctum.Cipher` has no bulk re-seal. So the flag currently means
  "accept that old rows will not open", which is a data-loss
  acknowledgement, not a migration. **A migrate flag that cannot migrate
  should probably not be called one.**
- **Restored DB, current keyring** — fingerprint mismatch, and the
  operator is right. This is the case that must not be a brick wall.
- **Restored DB, restored keyring, new secret_key_base** — matches, and
  correctly so: the derivation is not in play when an explicit keyring is
  set.

### 3. What is the flag, and what does it promise?

`CYFR_CRYPTO_KEYRING_MIGRATE=1` is the obvious spelling, and the obvious
trap: it reads like "migrate my data" and would do nothing of the sort.
Two honest alternatives:

- `CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT=<fingerprint>` — the operator
  names the fingerprint they expect. Refuses a typo, and the value is in
  the deploy config where a reviewer can see it changed.
- Ship the bulk re-seal first, and make the flag mean what it says.

*Leaning: the explicit-fingerprint flag*, because it is a one-line change
that turns a silent fork into a reviewed one, and it does not pretend a
re-key happened.

## What to implement, in order

1. Fingerprint on write only — record it at first boot, never compare.
   Ships the observability with no refusal risk.
2. Compare and **warn loudly** on mismatch, still booting. One release of
   this, to find deployments already forked.
3. Compare and refuse, with the explicit-fingerprint escape hatch.

Steps 1 and 2 are safe now. Step 3 should wait for the restore runbook to
name the fingerprint value operators are meant to copy.

## Not in scope

Bulk re-seal (`Sanctum.Cipher` has no re-key path, and adding one is its
own design), and the `""`-vs-`nil` distinction — both already fall through
to derivation, and once a fingerprint exists the distinction stops
mattering, because the *result* is what gets compared.
