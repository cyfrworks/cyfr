# Upgrading

Breaks and required operator actions, newest first. Everything not listed
here is backward compatible in the only sense this project promises: it
keeps working without you doing anything.

There is no compatibility guarantee across versions before 1.0. What this
file guarantees is that a break is **written down** — the previous home
for release notes was a `docs/` symlink outside the repository, so a
break was invisible to anyone who cloned it.

---

## Unreleased — the hardening pass

### Consents re-consent once, on the first re-release after upgrade

`Sanctum.Consent.ShapeDigest` now folds every dependency's release digest
into the shape, so a dependency re-released with different code asks for
consent again instead of riding the old grant. The canonical shape gained
a key, which means **every stored `shape_digest` differs from the live
one**.

Nothing breaks on upgrade. `Sanctum.Consent.Loader` compares the
*activation* digest first and answers `:allow` when it matches, so
existing consents keep loading and AQUA keeps running. The shape is only
consulted once a source has been re-released — and at that point the
profile asks for one re-consent, after which the new-format digest is
stored and it self-heals.

**Action:** none. Expect one consent walk per versionless profile, the
first time its source is re-released.

### Webhooks must state a replay-protection decision

`Sanctum.Webhook.create/2` refuses a webhook that names neither
`timestamp_header` nor `idempotency_key_header` unless you pass
`replay_protection: "none"`. `update/3` refuses a change that would clear
the last of them on the same terms. An HMAC over a raw body stays valid
forever, so "off" being reachable by omission meant a captured delivery
replayed indefinitely.

**Action:** scripted webhook creation that relies on neither header must
add `replay_protection: "none"`. The console has a checkbox for it.

### `component.register` no longer mints consent

Registering is a scanner over the athanor's own overlay tree, so it
consented to whatever had arrived there — including bytes a catalyst with
a storage write grant wrote itself, under the same `"filesystem"` source
stamp the operator's seed carries. Provisioning still mints, over
operator-shipped bytes.

`register` also left the in-chain plane, so AQUA can no longer propose it.

**Action:** a registered component now needs one consent walk before it
can be invoked. First-run provisioning is unchanged.

### New knob: `CYFR_WEBHOOK_PER_IP_RATE_LIMIT_MAX`

The inbound-webhook per-IP ceiling was a hard-coded 600/min, checked
before the per-slug bucket and therefore clamping any `rate_limit`
configured above it. It defaults to 6000/min now and is settable.

**Action:** none unless one sender legitimately needs more than 6000
deliveries a minute from one address.

### `athanor.destroy` — irreversible tenant erasure

A new platform-admin verb that deletes an archived athanor's rows across
all nineteen athanor-scoped tables and its storage tree, keeping the
`athanors` row as an archived tombstone. `purge` still reclaims blobs
only. `destroy` refuses a personal athanor and refuses anything not
archived.

**Action:** none. `Cyfr.Release.migrate/0` now also asserts that every
table carrying `athanor_id` is on the erasure roster, and **raises** if
one is not — a boot that fails is recoverable, a backup full of data
somebody was told was deleted is not.

### Cron schedules are at-most-once

`Arca.CronSchedule.claim/4` advances `next_run_at` inside the
compare-and-set that takes the occurrence, so each occurrence fires at
most once across the cluster. A node that claims and then dies before its
task runs **skips** that occurrence rather than having another node repeat
it — a duplicate side effect is worse here than a missed one.

A run that outlives its own interval can still overlap the next occurrence
on another node; only same-node overlap is prevented.

**Action:** none, unless you were relying on a missed occurrence being
retried by a peer.
