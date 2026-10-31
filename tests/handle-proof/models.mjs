// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// What the handle proof holds each object to (README.md, "Whole objects"),
// apart from the browsers and the run, so the models can be built from a
// run's record and fed corrupted objects outside it.
//
// A model gives every field of an object one class:
//
//   exact     the value the step must leave, or a value this run read
//             before and holds from then on
//   derived   a value read from another source, independent of the row
//   captured  a value the server generated, read here for the first time,
//             that no other source names: held to its shape now and exact
//             at every later read
//   bound     a time the server stamps, inside a window whose two ends are
//             the proof's own clock readings
//
// `check` compares an object read whole with its model, then shows each
// stored field failing: written behind the server's back to a value the
// model refuses, read again, compared, and restored, with the table's
// schema or constraints and every other row compared before and after.

import { createPrivateKey, createPublicKey, createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";

export const ISO = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/;
export const PER = /^per_[0-9a-f]{64}$/;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const CYFR_ID = /^[a-z]+_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const HASH = /^sha256:[0-9a-f]{64}$/;
export const LONG_AGO = "2001-01-01T00:00:00.000000Z";
// The resolution of a server's stamp against the proof's clock: a stamp
// in microseconds is compared with milliseconds read either side of it.
const SLACK_MS = 5;

export const exact = (value, { tamper, shown } = {}) => ({ cls: "exact", value, tamper, shown });
export const derived = (value, from, { tamper } = {}) => ({ cls: "derived", value, from, tamper });
// A captured field is bound (`bindCaptured`) to the value its first read
// read: it holds when it has its shape and is that value.
export const captured = (says, shape, outside) => ({
  cls: "captured", says, outside, shape,
  holds(v) { return shape(v) && (!("value" in this) || isDeepStrictEqual(v, this.value)); },
});
// A row's stable label in the field table, from what the row is (its key),
// never its position: a list's rows print sorted by it.
export const LABEL = Symbol("label");
export const labelled = (model, label) => Object.assign(model, { [LABEL]: label });
export const bound = (says, holds, outside) => ({ cls: "bound", says, holds, outside });

export const msOf = (text) => {
  if (typeof text !== "string" || !ISO.test(text)) return NaN;
  const [, date, time, fraction = "", zone] = text.match(/^(\S+)[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$/);
  return Date.parse(`${date}T${time}${fraction.slice(0, 4)}${zone || "Z"}`);
};
const inside = (window, v) => msOf(v) >= window.from - SLACK_MS && msOf(v) <= window.to + SLACK_MS;

// A time the server stamped inside `window` ({name, from, to}).
export const within = (window) => bound(`a time inside ${window.name}`, (v) => inside(window, v), LONG_AGO);
// A time that is `before`, read earlier, unless the server stamped it again
// inside `window`.
export const sameOrWithin = (before, window, what) =>
  bound(`${what}, or a time inside ${window.name}`, (v) => v === before || inside(window, v), LONG_AGO);

export const bytesOf = (v) => (v && typeof v.bytes === "string" ? Buffer.from(v.bytes, "base64") : null);
export const bytes = (buffer) => ({ bytes: Buffer.from(buffer).toString("base64") });
const ONE_BYTE = bytes([0]);
// A first read's shapes: an id of a kind, a digest, so many bytes.
export const anId = (prefix) => captured(`a new ${prefix}_ id`, (v) => typeof v === "string" && CYFR_ID.test(v) && v.startsWith(`${prefix}_`), "~");
// A UUID column holds a UUID by its type: the shape refused is the nil UUID.
export const aUuid = (what) => captured(`${what}: a new UUID, not the nil UUID`, (v) => UUID.test(v) && v !== "00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000000");
export const aDigest = (what) => captured(`${what}: a new sha256: digest`, (v) => typeof v === "string" && HASH.test(v), "~");
export const someBytes = (n, what) => captured(`${what}: ${n} new bytes`, (v) => bytesOf(v)?.length === n, ONE_BYTE);
export const sealedBytes = (what) => captured(`${what}: new sealed bytes`, (v) => (bytesOf(v)?.length ?? 0) > 32, ONE_BYTE);

// Another valid value of the same kind: the last character of an id or
// digest changed.
export function otherId(v) {
  const last = v.at(-1);
  return `${v.slice(0, -1)}${last === "0" ? "1" : "0"}`;
}

// The value a tamper writes: one the field's model refuses. A field's own
// `tamper` comes first; a first read's or a bound's comes next, outside
// its window; then a byte field, captured or exact, has one byte flipped,
// and an id or digest of a shaped kind becomes another valid one of that
// kind, before any malformed replacement.
const SHAPED_ID = /^[a-z]+_[0-9a-f]{32}$/;
export function tampered(spec, value) {
  if (spec.tamper !== undefined) return spec.tamper;
  const asBytes = bytesOf(value);
  if (asBytes) {
    asBytes[0] ^= 0xff;
    return bytes(asBytes);
  }
  // PostgreSQL's bytes, as row_to_json writes them: the first digit changed.
  if (typeof value === "string" && /^\\x[0-9a-f]+$/.test(value)) return `\\x${value[2] === "0" ? "1" : "0"}${value.slice(3)}`;
  if (typeof value === "string" && (PER.test(value) || HASH.test(value) || UUID.test(value) || CYFR_ID.test(value) || SHAPED_ID.test(value))) {
    return otherId(value);
  }
  if ((spec.cls === "captured" || spec.cls === "bound") && spec.outside !== undefined) return spec.outside;
  if (value === null) return "tampered";
  if (typeof value === "boolean") return !value;
  if (typeof value === "number") return value + 1;
  if (Array.isArray(value)) return [...value, "00000000-0000-0000-0000-000000000000"];
  if (typeof value === "string" && ISO.test(value)) return LONG_AGO;
  if (typeof value === "string") return `${value}~`;
  return null;
}

// Every field of `object` against `model`: the mismatches, each naming its
// field. A list compares row by row; a field the model does not classify,
// or a classified field the object lacks, is a mismatch.
export function mismatches(object, model, at = "") {
  if (Array.isArray(model)) {
    if (!Array.isArray(object) || object.length !== model.length) {
      return [{ field: `${at}#`, want: model.length, got: Array.isArray(object) ? object.length : object }];
    }
    return model.flatMap((m, i) => mismatches(object[i], m, `${at}[${i}]`));
  }
  if (object === null || typeof object !== "object") return [{ field: at || "(object)", want: "an object", got: object }];
  const out = [];
  for (const field of Object.keys(object)) {
    if (!(field in model)) out.push({ field: `${at}.${field}`, want: "a classification", got: object[field], unclassified: true });
  }
  for (const [field, spec] of Object.entries(model)) {
    const path = `${at}.${field}`;
    if (!(field in object)) {
      out.push({ field: path, want: spec.cls, got: "missing" });
      continue;
    }
    const value = object[field];
    const held = spec.cls === "bound" || spec.cls === "captured" ? spec.holds(value) : isDeepStrictEqual(value, spec.value);
    if (!held) out.push({ field: path, cls: spec.cls, want: spec.cls === "bound" || spec.cls === "captured" ? spec.says : spec.value, got: value });
  }
  return out;
}

// The model's fields as the README's table rows.
export function classification(name, model) {
  const one = Array.isArray(model) ? model : [model];
  const describe = (m) => Object.entries(m).map(([field, spec]) => {
    const what = spec.cls === "exact" ? spec.shown ?? `\`${JSON.stringify(spec.value)}\`` : spec.cls === "derived" ? spec.from : spec.says;
    return [field, spec.cls, what];
  });
  // Each row by its label, then by what it says; a label two rows share
  // takes an ordinal after that order, so the table does not depend on the
  // order the run read the rows in.
  const rows = one.map((m) => ({ label: m[LABEL] ?? "", lines: describe(m) }))
    .sort((x, y) => (x.label + JSON.stringify(x.lines)).localeCompare(y.label + JSON.stringify(y.lines)));
  const seen = new Map();
  return rows.flatMap(({ label, lines }) => {
    const n = (seen.get(label) ?? 0) + 1;
    seen.set(label, n);
    const shared = rows.filter((r) => r.label === label).length > 1;
    const tag = !Array.isArray(model) ? "" : `[${label || "row"}${shared ? ` ${n}` : ""}]`;
    return lines.map(([field, cls, what]) => `| ${name}${tag} | ${field} | ${cls} | ${what} |`);
  });
}

// A row read before, held: every field exact but those in `moves`, each
// given its own spec. `base`, the row's first model, lends each field the
// tamper its column's type needs.
export function held(row, moves = {}, shown = "as read before", base = {}) {
  return labelled(Object.fromEntries(Object.entries(row).map(([field, value]) =>
    [field, field in moves ? moves[field] : exact(value, { shown: `${shown}`, tamper: base[field]?.tamper })])), base[LABEL]);
}

// One claimed object, compared whole with `model`, then each stored field
// shown failing. `io.read()` answers the object; for a stored object
// `io.write(i, field, value, row, phase)` writes one field of row i
// (phase `tamper` or `restore`) and answers `{set, role?}`, and
// `io.state()` answers the whole stored table with its schema or
// constraints, which must be the same before the first tamper and after
// every restore. `io.identity` ({store, key}) names each row of a stored
// object; `io.ran` (a Map shared by the run) records each loop that ran by
// store, row key and field, with the predicate it ran under; with
// `io.skipIfRan` a field's loop is skipped only when an identical
// predicate (equality to the same value) already ran on that same row.
// For a view (`io.via`), each field names the stored field
// that makes it and the value its tamper writes and its restore writes
// back, or `{none: reason}`. `io.controls` are in-memory negative
// controls: a copy of the object with one field corrupted, which the
// comparison must refuse on that field. Answers the record of what ran.
export async function check(object, model, io) {
  const out = { mismatches: mismatches(object, model), loops: [], skipped: [], controls: [], failures: [] };
  if (out.mismatches.length) return out;
  for (const control of io.controls ?? []) {
    const failed = mismatches(control.corrupt(structuredClone(object)), model);
    const named = failed.some((m) => m.field === control.field);
    out.controls.push({ field: control.field, says: control.says, failed_on: failed.map((m) => m.field), named });
    if (!named) out.failures.push(`the control for ${control.field} was not refused`);
  }
  if (!io.write) return out;
  const list = Array.isArray(model) ? model : [model];
  const objects = Array.isArray(model) ? object : [object];
  if (!io.state) throw new Error("a stored object's check needs its table's state, to verify every restore");
  const before = await io.state();
  for (let i = 0; i < list.length; i++) {
    for (const [field, spec] of Object.entries(list[i])) {
      const name = Array.isArray(model) ? `[${i}].${field}` : `.${field}`;
      // An equality predicate's fingerprint: its value. A bound has none,
      // so a bound's loop never stands for an exact one's.
      const fingerprint = spec.cls === "bound" || !("value" in spec) ? null : JSON.stringify(spec.value);
      const rowId = io.identity ? `${io.identity.store}|${io.identity.key(objects[i])}|${field}` : null;
      const prior = rowId && io.ran ? io.ran.get(rowId) : null;
      if (io.skipIfRan && fingerprint !== null && prior && prior.fingerprint === fingerprint) {
        out.skipped.push({ field: name, reason: `the identical predicate already ran on this row (${prior.at})` });
        continue;
      }
      const via = io.via ? io.via[field] : null;
      if (io.via && (!via || via.none)) {
        out.skipped.push({ field: name, reason: via?.none ?? "no stored field makes it" });
        continue;
      }
      const target = via ? via.target : field;
      const value = via ? via.value : tampered(spec, objects[i][field]);
      const original = via ? via.original : objects[i][field];
      const loop = { field: name, target };
      try {
        loop.written = await io.write(i, target, value, objects[i], "tamper");
        const failing = mismatches(await io.read().catch((error) => ({ unreadable: String(error.message) })), model);
        loop.failed_on = failing.map((m) => m.field);
        // Refused on this field, read back with the tampered value; or the
        // row left a read filtered by this very field.
        // A list's rows are matched by what each holds, so a tamper that
        // reorders them is refused at the row it moved to.
        const sameField = (m) => (Array.isArray(model) ? m.field.replace(/^\[\d+\]/, "") === `.${field}` : m.field === name);
        loop.named = failing.some((m) => sameField(m) && m.got !== "missing") ||
          (io.read.filter === target && failing.some((m) => m.field === "#"));
      } finally {
        // The restore finds the row by the value the tamper left in it.
        loop.restored = await io.write(i, target, original, { ...objects[i], [target]: value }, "restore");
      }
      loop.state_same = isDeepStrictEqual(await io.state(), before);
      loop.role_back = loop.restored?.role === undefined || loop.restored.role === "origin";
      loop.held_again = mismatches(await io.read(), model).length === 0;
      out.loops.push(loop);
      if (rowId && io.ran && fingerprint !== null && loop.named && loop.state_same && loop.held_again) io.ran.set(rowId, { fingerprint, at: io.at });
      if (!loop.named) out.failures.push(`a tamper of ${name} was not refused`);
      if (!loop.state_same) out.failures.push(`after ${name}'s restore the table, its schema or its constraints differ`);
      if (!loop.role_back) out.failures.push(`after ${name}'s restore the registry's session is ${loop.restored.role}, not origin`);
      if (!loop.held_again) out.failures.push(`after ${name}'s restore the object is not the model's`);
      if (out.failures.length) return out;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Derivations from other sources
// ---------------------------------------------------------------------------

export const sha256hex = (buffer) => createHash("sha256").update(buffer).digest("hex");
// Bytes as a CYFR's fixture answers them: printable text as the text
// (Elixir's `String.printable?/1`), anything else as base64.
export function storedForm(buffer) {
  const text = buffer.toString("utf8");
  const printable = Buffer.from(text, "utf8").equals(buffer) && /^[^\x00-\x06\x0e-\x1a\x1c-\x1f]*$/.test(text);
  return printable ? text : bytes(buffer);
}
// Canonical entry bytes from the CYFR fixture or a PostgreSQL BYTEA column.
export const bytesFrom = (v) => {
  if (typeof v !== "string") return bytesOf(v);
  return /^\\x[0-9a-f]+$/.test(v) ? Buffer.from(v.slice(2), "hex") : Buffer.from(v, "utf8");
};
export const b64url = (b64) => b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export const fromB64url = (text) => Buffer.from(text.replace(/-/g, "+").replace(/_/g, "/"), "base64");

// The COSE key a virtual authenticator's credential (its PKCS#8 private
// key, base64) registers, as Erlang's term_to_binary writes the map CYFR
// stores (`passkeys.public_key`): {-3 => y, -2 => x, -1 => 1, 1 => 2,
// 3 => -7} in term order.
export function coseTerm(privateKeyB64) {
  const jwk = createPublicKey(createPrivateKey({ key: Buffer.from(privateKeyB64, "base64"), format: "der", type: "pkcs8" })).export({ format: "jwk" });
  const int = (n) => (n >= 0 && n < 256 ? Buffer.from([97, n]) : (() => { const b = Buffer.alloc(5); b[0] = 98; b.writeInt32BE(n, 1); return b; })());
  const bin = (buffer) => { const head = Buffer.alloc(5); head[0] = 109; head.writeUInt32BE(buffer.length, 1); return Buffer.concat([head, buffer]); };
  const head = Buffer.from([131, 116, 0, 0, 0, 5]);
  return bytes(Buffer.concat([head,
    int(-3), bin(fromB64url(jwk.y)), int(-2), bin(fromB64url(jwk.x)),
    int(-1), int(1), int(1), int(2), int(3), int(-7)]));
}

// `inserted_at` plus `hours`, in the stored form (microseconds, Z).
export function plusHours(stamp, hours) {
  const [, date, time, fraction = ""] = stamp.match(/^(\S+)[T ](\d{2}:\d{2}:\d{2})(\.\d+)?/);
  const at = new Date(Date.parse(`${date}T${time}Z`) + hours * 3_600_000).toISOString().slice(0, 19);
  return `${at}${fraction}Z`;
}

// ---------------------------------------------------------------------------
// The objects each step claims, built from what the run captured (`S`, the
// record's `seen`): the browsers' credentials and cookies' digests, the
// rows first read, the clock readings around each step and each read.
// ---------------------------------------------------------------------------

export const DIRECTORY = "https://registry.test";
export const REGISTRY = "registry.test";
// The OCI host a push token is for, which A keys its stored tokens by:
// `registry.` before CYFR_REGISTRY_URL (`Compendium.RegistryHost`).
export const OCI = `registry.${REGISTRY}`;
export const HANDLE = "proof";
// The name B's administrator types on B's first screen.
export const ADMIN_HANDLE = "proof-b";
// This fresh proof database mints IDs from 1; the largest exact JS integer
// remains a valid PostgreSQL BIGINT without colliding with another proof row.
const DIRECTORY_ID_TAMPER = Number.MAX_SAFE_INTEGER;
const NONE_TIME = { tamper: LONG_AGO };
const nil = () => exact(null);
const noTime = () => exact(null, NONE_TIME);

// A window from the proof's clock: `from` and `to` readings, named.
const win = (S, name) => S.w[name];
// From a step's start to the read of `object`.
const until = (S, name, object) => ({ name: `${S.w[name].name} up to ${object}'s read`, from: S.w[name].from, to: S.at[object] });

// A field whose relationship to another source was checked once at its
// first read (`related`, true when it held): held as read from then on.
const relatedTo = (value, related, from) => derived(related ? value : { relationship: "did not hold" }, from);

// The models of rows a table reads in its own order, each found by its
// key (`keyOf`) among `expected` (`[key, model, label]`, the label what
// the row is, for the field table): when the rows read are not exactly the
// expected keys, the expected models in their own order, which the
// comparison then refuses.
function byKey(rows, keyOf, expected) {
  const want = new Map(expected.map(([key, model, label]) => [key, labelled(model, label)]));
  const read = rows.map(keyOf);
  const same = read.length === want.size && read.every((k) => want.has(k)) && new Set(read).size === read.length;
  return same ? read.map((k) => want.get(k)) : [...want.values()];
}

export function objectModels(S) {
  const M = models(S);
  // Every captured field bound to the value the object's first read read.
  return Object.fromEntries(Object.entries(M).map(([key, build]) => [key, () => {
    const model = build();
    const rows = S.rows[key];
    if (Array.isArray(model) && Array.isArray(rows)) {
      model.forEach((m, i) => {
        for (const [field, spec] of Object.entries(m)) if (spec.cls === "captured" && rows[i] && field in rows[i]) spec.value = rows[i][field];
      });
    }
    return model;
  }]));
}

const withLabels = (labels, rows) => rows.map((m, i) => labelled(m, labels[i]));

function models(S) {
  const A = S.origins.a;
  const id = S.identifier ?? "";
  const genesisHash = `sha256:${id.slice(4)}`;
  const first = (name) => S.rows[name];
  const aUser = () => first("setup:a.passkeys")[0].user_id;
  const bAdmin = () => first("allow:b.passkeys")[0].user_id;
  const genesisA = S.genesis.a;
  const bytesHex = (hex) => `\\x${hex}`;

  const nsRow = (slug, owner, created, updated) => ({
    slug: exact(slug),
    kind: exact("personal"),
    reserved: exact(false),
    domain_verified: exact(false),
    verify_token: nil(),
    verified_at: noTime(),
    last_checked_at: noTime(),
    consecutive_failures: exact(0),
    display_name: nil(),
    expires_at: noTime(),
    created_at: created,
    updated_at: updated,
    owner_identifier: owner,
    reserved_reason: nil(),
  });
  const head = (identifier, genesis, readAt) => ({
    identifier: derived(identifier, "the identity's genesis, hashed"),
    head: derived(genesis, "the genesis's hash: one entry, so the head (`Prima.Identity`)"),
    entries: exact(1),
    recovery_epoch: derived(genesis, "a genesis's own hash (`Prima.Identity`, identity.ex:1150)"),
    key_epoch: derived(genesis, "a genesis's own hash (`Prima.Identity`, identity.ex:1150)"),
    read_at: readAt,
  });
  const policy = (identifier, window) => ({
    id: aUuid("an acceptance id"),
    policy_version: derived(S.policyVersion, "the registry's GET /v1/legal/version"),
    accepted_at: within(window),
    ip_address: exact("::ffff:127.0.0.1", { tamper: "::ffff:127.0.0.2", shown: "`\"::ffff:127.0.0.1\"`: the front's forwarded loopback address, as PostgreSQL's inet stores it" }),
    user_agent: derived(S.clients?.cyfr, "the signer's HTTP client: Req's default for a CYFR (req 0.7.5, mix.lock)"),
    identifier: derived(identifier, "the signer's identifier"),
    former_identity: nil(),
  });
  // A nonce the signer drew for one request, expiring 120 s after it was
  // signed (`Prima.RegistryRequest`), inside `window` shifted by that.
  const nonce = (identifier, window) => ({
    identifier: derived(identifier, "the signer's identifier"),
    nonce: captured("16 new bytes", (v) => typeof v === "string" && /^\\x[0-9a-f]{32}$/.test(v), "\\x00"),
    expires_at: within({ name: `${window.name}, plus the 120 s a signed request lives`, from: window.from + 120_000, to: window.to + 120_000 }),
  });
  const handleAnswer = (handle, identifier) => ({
    status: exact(200),
    protocol: exact("cyfr-handle/v1"),
    registry: exact(REGISTRY),
    handle: exact(handle),
    identifier: derived(identifier, "the owner's genesis, hashed"),
    directory: exact(DIRECTORY),
  });
  const logEntry = (identifier, genesis, window) => ({
    id: { ...captured("a new directory row id", (v) => Number.isSafeInteger(v) && v > 0, DIRECTORY_ID_TAMPER), tamper: DIRECTORY_ID_TAMPER },
    identifier: derived(identifier, "the identifier the signer's genesis hashes to"),
    seq: exact(0),
    kind: exact("genesis"),
    entry_hash: derived(`sha256:${sha256hex(fromB64(genesis))}`, "the entry's bytes, hashed"),
    prev_hash: nil(),
    entry: relatedTo(bytesHex(fromB64(genesis).toString("hex")), sha256hex(fromB64(genesis)) === identifier.slice(4), "the genesis its signer sent, whose hash is the identifier"),
    request_id: nil(),
    request_digest: nil(),
    outcome: exact("accepted"),
    outcome_body: nil(),
    bytes: derived(fromB64(genesis).length, "the entry's length"),
    inserted_at: within(window),
  });
  const genesisKey = (genesis, key) => bytes(fromB64url(JSON.parse(fromB64(genesis).toString("utf8"))[key]));

  const M = {};

  // setup: the passkey, read once setup is done.
  M["setup:a.passkeys"] = () => [{
    id: anId("psk"),
    user_id: anId("usr"),
    credential_id: derived(b64url(S.credentials.a.credentialId), "the credential the browser's authenticator holds for a.test, base64url"),
    rp_id: exact("a.test"),
    relying_home: exact(A),
    public_key: derived(S.credentials.a.cose, "the authenticator's key, as the COSE map CYFR stores (term_to_binary)"),
    sign_count: derived(S.credentials.a.signCount, "the authenticator's count for that credential"),
    identity_recovery_epoch: nil(),
    state: exact("active"),
    registration_digest: aDigest("the registration's digest"),
    possession_verified: exact(1),
    expires_at: noTime(),
    admin_confirmation_id: nil(),
    activated_at: within(win(S, "setup")),
    revoked_at: noTime(),
    inserted_at: within(win(S, "setup")),
    updated_at: within(win(S, "setup")),
  }];

  // setup, before the recovery code is saved: the accepted enrollment, the
  // directory's entry, and the name claimed at the registry.
  M["setup:registry.directory.identity_log_entries"] = () => [logEntry(id, genesisA, win(S, "enroll"))];
  M["setup:pre:a.identity_attempts"] = () => {
    const pre = first("setup:pre:a.identity_attempts")[0];
    return [{
      id: anId("iat"),
      kind: exact("enrollment"),
      request_id: captured("a new request id, req_ and 32 hexadecimal digits", (v) => typeof v === "string" && /^req_[0-9a-f]{32}$/.test(v), "~"),
      user_id: derived(aUser(), "A's passkey's person"),
      identifier: derived(id, "the identifier the recovery code names, as the browser showed it"),
      directory_url: exact(DIRECTORY),
      name: exact(HANDLE, { shown: "`\"proof\"`: the name typed on setup's first screen" }),
      phase: exact("accepted"),
      genesis: derived(storedForm(fromB64(genesisA)), "the directory's stored genesis"),
      entry: nil(),
      entry_hash: nil(),
      expected_head: nil(),
      expected_revision: nil(),
      request_digest: derived(genesisHash, "the genesis's hash: an enrollment's request is its genesis"),
      token_digest: nil(),
      staged_live_public_key: exact(null, { shown: "`null`: the accepted enrollment moved its staged keys onto the identity row" }),
      staged_operational_public_key: nil(),
      staged_live_key_sealed: nil(),
      staged_operational_key_sealed: nil(),
      kit_seed_sealed: sealedBytes("the recovery code's secret, sealed until the code is saved"),
      kit_acknowledged_at: noTime(),
      outcome: exact("accepted"),
      reproof_challenge_digest: nil(),
      reproof_expires_at: noTime(),
      revision: exact(3, { shown: "`3`: the attempt as its enrollment's acceptance leaves it" }),
      inserted_at: within(win(S, "enroll")),
      updated_at: within(win(S, "enroll")),
    }];
  };

  // setup, after it: the transition, and the claim.
  M["setup:a.identity_attempts"] = () => [held(first("setup:pre:a.identity_attempts")[0], {
    phase: exact("completed"),
    kit_acknowledged_at: within(win(S, "ack")),
    kit_seed_sealed: exact(null, { shown: "`null`: the recovery code's secret is dropped once the code is saved" }),
    revision: exact(first("setup:pre:a.identity_attempts")[0].revision + 1, { shown: "the revision read before the code was saved, plus one" }),
    updated_at: within(win(S, "ack")),
  }, "as read before the recovery code was saved")];
  M["setup:a.users"] = () => [{
    id: derived(aUser(), "the user A's passkey names"),
    email: nil(),
    email_verified: nil(),
    admission: exact("setup"),
    display_name: nil(),
    namespace: exact(HANDLE),
    personal_athanor_id: derived(first("setup:a.athanors")[0]?.id, "A's one athanor"),
    status: exact("active"),
    prefs: exact("{}", { shown: "`\"{}\"`: Newcomer's empty document (newcomer.ex:264), the cleared handle_wanted removed" }),
    first_seen_at: within(win(S, "setup")),
    last_seen_at: within(until(S, "setup", "setup:a.users")),
    denied_at: noTime(),
    security_generation: exact(1),
    created_at: within(win(S, "setup")),
    updated_at: within(until(S, "setup", "setup:a.users")),
  }];
  M["setup:a.athanors"] = () => [{
    id: anId("ath"),
    kind: exact("person"),
    name: exact("Me"),
    slug: exact("me"),
    owner_user_id: derived(aUser(), "A's person"),
    status: exact("active"),
    archived_at: noTime(),
    created_by: derived(aUser(), "A's person"),
    settings: nil(),
    provisioned_at: within(until(S, "setup", "setup:a.athanors")),
    provisioning_failed_at: noTime(),
    provisioning_failure: nil(),
    roster: exact("open"),
    pair_key: nil(),
    security_generation: exact(1),
    created_at: within(win(S, "setup")),
    updated_at: within(until(S, "setup", "setup:a.athanors")),
  }];
  const membership = (user, athanor, scope, window) => ({
    id: anId("mem"),
    user_id: derived(user, "the person"),
    person_identifier: nil(),
    scope: exact(scope),
    status: exact("active"),
    added_by: nil(),
    athanor_id: athanor,
    created_at: within(window),
    updated_at: within(window),
  });
  // A person's seat in their athanor and, for the first person, the
  // platform grant: one row each, in the order the table reads them.
  const seats = (name, user, athanor, window) => byKey(first(name), (r) => r.scope, [
    ["athanor", membership(user, derived(athanor, "the person's one athanor"), "athanor", window), "the athanor's seat"],
    ["platform", membership(user, nil(), "platform", window), "the platform grant"],
  ]);
  M["setup:a.memberships"] = () => seats("setup:a.memberships", aUser(), first("setup:a.athanors")[0]?.id, win(S, "setup"));
  M["setup:a.person_identities"] = () => {
    const row = first("setup:a.person_identities")[0];
    return [{
      id: anId("pid"),
      user_id: derived(aUser(), "A's passkey's person"),
      identifier: derived(id, "the identifier the recovery code names"),
      provenance: exact("local"),
      enrollment: exact("enrolled"),
      live_public_key: derived(genesisKey(genesisA, "live_key"), "the directory's genesis's live key"),
      operational_public_key: derived(genesisKey(genesisA, "operational_key"), "the directory's genesis's operational key"),
      live_key_sealed: relatedTo(row.live_key_sealed, S.opens["identity.live"] === genesisKey(genesisA, "live_key").bytes, "opens, in A, to the genesis's live key"),
      operational_key_sealed: relatedTo(row.operational_key_sealed, S.opens["identity.operational"] === genesisKey(genesisA, "operational_key").bytes, "opens, in A, to the genesis's operational key"),
      genesis_hash: derived(genesisHash, "the directory's genesis, hashed"),
      head_hash: derived(genesisHash, "the directory's one entry"),
      directory_url: exact(DIRECTORY),
      first_method_at: within(win(S, "setup")),
      revision: exact(4, { shown: "`4`: 1 at insertion, then first_method! (person_identities.ex:233), enrolling! (:145) and enrolled! (:174), each one step (:259)" }),
      inserted_at: within(win(S, "setup")),
      updated_at: within(win(S, "enroll")),
    }];
  };
  M["setup:registry.namespaces[proof]"] = () => [nsRow(HANDLE, derived(id, "the identifier the recovery code names"), within(win(S, "enroll")), within(win(S, "enroll")))];
  M["setup:registry.identity_heads[a]"] = () => [head(id, genesisHash, within(win(S, "enroll")))];
  M["setup:registry.policy_acceptances[a]"] = () => [policy(id, win(S, "enroll"))];
  M["setup:registry.request_nonces[a]"] = () => [nonce(id, win(S, "enroll")), nonce(id, win(S, "enroll"))];
  M["setup:handle_answer[proof]"] = () => handleAnswer(HANDLE, id);

  // The nonces read before, each held, and `added` new ones.
  const grown = (before, now, step, added, window) => {
    const fresh = now.filter((r) => !before.some((b) => b.nonce === r.nonce)).map((r) => r.nonce);
    return byKey(now, (r) => r.nonce, [
      ...before.map((b) => [b.nonce, held(b, {}, `as read at ${step}`), `a nonce read at ${step}`]),
      ...Array.from({ length: added }, (_, i) => [fresh[i] ?? `new ${i}`, nonce(id, window), `a new nonce`]),
    ]);
  };

  // allow
  M["allow:b.passkeys"] = () => [{
    ...M["setup:a.passkeys"]()[0],
    credential_id: derived(b64url(S.credentials.b.credentialId), "the credential the administrator's authenticator holds for b.test, base64url"),
    rp_id: exact("b.test"),
    relying_home: exact(S.origins.b),
    public_key: derived(S.credentials.b.cose, "the administrator's authenticator's key, as the COSE map CYFR stores"),
    sign_count: derived(S.credentials.b.signCount, "the authenticator's count for that credential"),
    activated_at: within(win(S, "admin")),
    inserted_at: within(win(S, "admin")),
    updated_at: within(win(S, "admin")),
  }];
  M["allow:b.users"] = () => [{
    ...M["setup:a.users"]()[0],
    id: derived(bAdmin(), "the user B's administrator's passkey names"),
    namespace: exact(ADMIN_HANDLE, { shown: "`\"proof-b\"`: the name typed on B's first screen" }),
    personal_athanor_id: derived(first("allow:b.athanors")[0]?.id, "B's one athanor"),
    first_seen_at: within(win(S, "admin")),
    last_seen_at: within(until(S, "admin", "allow:b.users")),
    created_at: within(win(S, "admin")),
    updated_at: within(until(S, "admin", "allow:b.users")),
  }];
  M["allow:b.athanors"] = () => [{
    ...M["setup:a.athanors"]()[0],
    owner_user_id: derived(bAdmin(), "B's administrator"),
    created_by: derived(bAdmin(), "B's administrator"),
    provisioned_at: within(until(S, "admin", "allow:b.athanors")),
    created_at: within(win(S, "admin")),
    updated_at: within(until(S, "admin", "allow:b.athanors")),
  }];
  M["allow:b.memberships"] = () => seats("allow:b.memberships", bAdmin(), first("allow:b.athanors")[0]?.id, win(S, "admin"));
  M["allow:b.server_allowlist"] = () => [{
    id: anId("door"),
    kind: exact("identifier"),
    value: derived(id, "the identifier @proof names at the registry (A's recovery code's)"),
    effect: exact("allow"),
    status: exact("allowed"),
    requested_by: nil(),
    added_by: derived(bAdmin(), "B's administrator"),
    note: nil(),
    label: exact(HANDLE),
    created_at: within(win(S, "allow")),
    updated_at: within(win(S, "allow")),
  }];

  // sign_in: B's people, identities, sessions, athanors and seats. The
  // administrator's keys are minted at setup, which also registers them at
  // registry.test: each public key is the public half of its sealed key,
  // opened in B, and the identifier is the hash of the genesis over them.
  const adminKeys = () => {
    const row = first("sign_in:b.person_identities").find((r) => r.user_id === bAdmin()) ?? {};
    const pair = (role, pub, sealedCol) => ({
      [pub]: relatedTo(row[pub], !!row[pub] && S.opens[`b.identity.${role}`] === row[pub].bytes, `the public half of the sealed ${role} key, opened in B`),
      [sealedCol]: relatedTo(row[sealedCol], !!row[pub] && S.opens[`b.identity.${role}`] === row[pub].bytes, `opens, in B, to the ${role} public key beside it`),
    });
    return { ...pair("live", "live_public_key", "live_key_sealed"), ...pair("operational", "operational_public_key", "operational_key_sealed") };
  };
  const remote = () => first("sign_in:b.person_identities").find((r) => r.identifier === id)?.user_id;
  const adminIdentifier = () => first("sign_in:b.person_identities").find((r) => r.user_id === bAdmin())?.identifier;
  M["sign_in:b.person_identities"] = () => withLabels(["the administrator's", "the person's"], [
    {
      id: anId("pid"),
      user_id: derived(bAdmin(), "B's administrator"),
      identifier: captured("B's administrator's identifier, per_ and 64 hexadecimal digits", (v) => typeof v === "string" && /^per_[0-9a-f]{64}$/.test(v), "~"),
      provenance: exact("local"),
      enrollment: exact("enrolled"),
      ...adminKeys(),
      genesis_hash: derived(`sha256:${adminIdentifier()?.slice(4)}`, "the identifier's 64 hexadecimal digits: the genesis's hash"),
      head_hash: derived(`sha256:${adminIdentifier()?.slice(4)}`, "the genesis: the administrator's log holds one entry"),
      directory_url: exact(DIRECTORY),
      first_method_at: within(win(S, "admin")),
      revision: exact(4, { shown: "`4`: 1 at insertion, then first_method! (person_identities.ex:233), enrolling! (:145) and enrolled! (:174), each one step (:259)" }),
      inserted_at: within(win(S, "admin")),
      updated_at: within(win(S, "admin")),
    },
    {
      id: anId("pid"),
      user_id: anId("usr"),
      identifier: derived(id, "the identifier A's recovery code names"),
      provenance: exact("remote"),
      enrollment: exact("enrolled"),
      live_public_key: exact(null, { shown: "`null`: B keeps no copy of a remote person's keys; it reads them at the directory" }),
      operational_public_key: nil(),
      live_key_sealed: nil(),
      operational_key_sealed: nil(),
      genesis_hash: derived(genesisHash, "the directory's genesis, hashed"),
      head_hash: derived(genesisHash, "the directory's one entry"),
      directory_url: exact(DIRECTORY),
      first_method_at: noTime(),
      revision: exact(1),
      inserted_at: within(win(S, "signin")),
      updated_at: within(win(S, "signin")),
    },
  ]);
  M["sign_in:b.users"] = () => withLabels(["the administrator's", "the person's"], [
    held(first("allow:b.users")[0], {
      last_seen_at: sameOrWithin(first("allow:b.users")[0].last_seen_at, win(S, "signin"), "as read at allow"),
      updated_at: sameOrWithin(first("allow:b.users")[0].updated_at, win(S, "signin"), "as read at allow"),
    }, "as read at allow"),
    {
      id: derived(remote(), "B's identity row for A's identifier"),
      email: nil(),
      email_verified: nil(),
      admission: exact("remote"),
      display_name: nil(),
      namespace: nil(),
      personal_athanor_id: nil(),
      status: exact("active"),
      prefs: exact("{}", { shown: "`\"{}\"`: Newcomer's empty document (newcomer.ex:264)" }),
      first_seen_at: within(win(S, "signin")),
      last_seen_at: within(until(S, "signin", "sign_in:b.users")),
      denied_at: noTime(),
      security_generation: exact(1),
      created_at: within(win(S, "signin")),
      updated_at: within(until(S, "signin", "sign_in:b.users")),
    },
  ]);
  M["sign_in:b.sessions[proof]"] = () => [{
    id: anId("ses"),
    token_hash: derived(bytes(Buffer.from(S.cookies.remote?.sha256 ?? "", "hex")), "the SHA-256 of the session token the browser's cookie carries"),
    token_prefix: derived(S.cookies.remote?.prefix, "the first 8 characters of that token"),
    user_id: derived(remote(), "B's identity row for A's identifier"),
    email: nil(),
    provider: exact("cyfr", { shown: "`\"cyfr\"`: the CYFR identity kind, as `CyfrDoor.context/1` mints it (cyfr_door.ex:509)" }),
    expires_at: derived(plusHours(first("sign_in:b.sessions[proof]")[0]?.inserted_at ?? "", S.ttlHours), "inserted_at plus session_ttl_hours (Sanctum.Session)"),
    athanor_id: nil(),
    identity_key_epoch: derived(genesisHash, "a genesis's key epoch, its own hash"),
    cli_machine: nil(),
    inserted_at: within(win(S, "signin")),
  }];
  M["sign_in:b.athanors"] = () => [held(first("allow:b.athanors")[0], {}, "as read at allow")];
  M["sign_in:b.memberships"] = () => first("allow:b.memberships").map((r) => held(r, {}, "as read at allow"));

  // sign_in, B's sessions whole: the administrator's and the person's.
  M["sign_in:b.sessions"] = () => (() => {
    const adminSession = first("sign_in:b.sessions").find((r) => r.user_id === bAdmin()) ?? {};
    return byKey(first("sign_in:b.sessions"), (r) => r.user_id, [[bAdmin(), {
    id: anId("ses"),
    token_hash: derived(bytes(Buffer.from(S.cookies.admin?.sha256 ?? "", "hex")), "the SHA-256 of the session token the administrator's cookie carries"),
    token_prefix: derived(S.cookies.admin?.prefix, "the first 8 characters of that token"),
    user_id: derived(bAdmin(), "B's administrator"),
    email: nil(),
    provider: exact("passkey"),
    expires_at: derived(plusHours(adminSession.inserted_at ?? "", S.ttlHours), "inserted_at plus session_ttl_hours (Sanctum.Session)"),
    athanor_id: derived(first("allow:b.athanors")[0]?.id, "B's one athanor"),
    identity_key_epoch: nil(),
    cli_machine: nil(),
    inserted_at: within(win(S, "admin")),
  }, "the administrator's"], [remote(), held(first("sign_in:b.sessions[proof]")[0], {}, "as read at sign_in"), "the person's"]]);
  })();
  // sync
  const token = () => first("sync:registry.push_tokens[proof]")[0];
  const sealed = () => first("sync:a.registry_tokens")[0];
  M["sync:a.registry_tokens"] = () => [{
    id: anId("rtk"),
    user_id: derived(aUser(), "A's person"),
    registry: exact(OCI, { shown: "`\"registry.registry.test\"`: the OCI host, registry. before CYFR_REGISTRY_URL" }),
    namespace_slug: exact(HANDLE),
    credential_ciphertext: relatedTo(sealed()?.credential_ciphertext, S.credentialOpened === true, "opens, in A, to the credential below"),
    issued_at: within(win(S, "sync")),
    inserted_at: within(win(S, "sync")),
    updated_at: within(win(S, "sync")),
  }];
  M["sync:a.registry_tokens.credential"] = () => ({
    type: exact("push_token"),
    token: derived({ sha256: String(token()?.token_hash ?? "").replace(/^\\x/, "") }, "the registry's token_hash for the one @proof token"),
    namespace: exact(HANDLE),
    role: exact("personal", { shown: "`\"personal\"`: a personal namespace's role, in `Sanctum.RegistryCredentials`' stored shape (registry_credentials.ex:28)" }),
    issued_at: derived(sealed()?.issued_at, "the row's issued_at"),
    label: derived(token()?.label, "the registry's label for that token"),
  });
  M["sync:registry.push_tokens[proof]"] = () => [{
    id: aUuid("a token id"),
    token_hash: derived(bytesHex(S.credentialDigest ?? ""), "the digest of the token A sealed"),
    namespace_slug: exact(HANDLE),
    label: derived(S.credentialLabel, "the label A sealed with the token"),
    created_at: within(win(S, "sync")),
    last_used_at: within(win(S, "sync")),
    revoked_at: noTime(),
    created_by: derived(id, "A's identifier"),
    recovery_epoch: derived(genesisHash, "a genesis's recovery epoch, its own hash"),
  }];
  M["sync:registry.request_nonces[a]"] = () =>
    grown(first("setup:registry.request_nonces[a]"), first("sync:registry.request_nonces[a]"), "setup", 1, win(S, "sync"));
  M["sync:registry.identity_heads[a]"] = () => [held(first("setup:registry.identity_heads[a]")[0], {
    read_at: sameOrWithin(first("setup:registry.identity_heads[a]")[0].read_at, win(S, "sync"), "as read at setup"),
  }, "as read at setup")];

  // ban
  M["ban:registry.banned_identities"] = () => [{
    id: aUuid("a ban id"),
    banned_at: within(win(S, "ban")),
    banned_by: derived(S.adminId, "the registry's admin account the run bootstrapped"),
    reason: exact("handle proof"),
    category: exact("spam"),
    expires_at: noTime(),
    appeal_allowed_after: noTime(),
    related_report_ids: exact([]),
    identifier: derived(id, "A's identifier"),
    former_identity: nil(),
  }];
  M["ban:registry.push_tokens[proof]"] = () => [held(token(), { revoked_at: within(win(S, "ban")) }, "as read at sync", M["sync:registry.push_tokens[proof]"]()[0])];
  M["ban:token_refused"] = () => ({ status: exact(401), body: exact({ errors: [{ code: "UNAUTHORIZED", message: "token revoked" }] }) });
  M["ban:a.sync_refused"] = () => ({ shown: exact(`Sync failed: ${S.refusals.banned.sentence}`), shared_with: exact([]) });
  M["ban:registry.request_nonces[a]"] = () =>
    grown(first("sync:registry.request_nonces[a]"), first("ban:registry.request_nonces[a]"), "sync", 0, win(S, "ban"));

  // ban, last: every object read earlier, held since, each with the
  // fields later steps legitimately move.
  const since = (name, step) => ({ name: `the run from ${step}'s end to the last read`, from: S.w[step].to, to: S.at[`held:${name}`] });
  const heldAll = (name, step, moves = () => ({})) => {
    const base = M[name] ? M[name]() : [];
    return first(name).map((r, i) => held(r, moves(r), `as read at ${step}`, Array.isArray(base) ? base[i] : {}));
  };
  M["held:a.passkeys"] = () => heldAll("setup:a.passkeys", "setup", (r) => ({
    sign_count: derived(S.credentials.aLast?.signCount, "the authenticator's count for that credential now"),
    updated_at: sameOrWithin(r.updated_at, since("a.passkeys", "setup"), "as read at setup"),
  }));
  M["held:a.users"] = () => heldAll("setup:a.users", "setup", (r) => ({
    last_seen_at: sameOrWithin(r.last_seen_at, since("a.users", "ack"), "as read at setup"),
    updated_at: sameOrWithin(r.updated_at, since("a.users", "ack"), "as read at setup"),
  }));
  for (const [name, step] of [["setup:a.person_identities", "setup"], ["setup:a.athanors", "setup"], ["setup:a.memberships", "setup"],
    ["setup:a.identity_attempts", "setup"], ["sync:a.registry_tokens", "sync"], ["setup:registry.directory.identity_log_entries", "setup"],
    ["setup:registry.namespaces[proof]", "setup"], ["setup:registry.policy_acceptances[a]", "setup"],
    ["ban:registry.banned_identities", "ban"], ["allow:b.passkeys", "allow"], ["allow:b.server_allowlist", "allow"],
    ["sign_in:b.sessions", "sign_in"], ["sign_in:b.person_identities", "sign_in"], ["allow:b.athanors", "allow"],
    ["allow:b.memberships", "allow"]]) {
    M[`held:${name.split(":").pop()}`] = () => heldAll(name, step);
  }
  M["held:registry.identity_heads[a]"] = () => heldAll("setup:registry.identity_heads[a]", "setup", (r) => ({
    read_at: sameOrWithin(first("sync:registry.identity_heads[a]")[0].read_at, since("registry.identity_heads[a]", "sync"), "as read at sync"),
  }));
  M["held:b.users"] = () => first("sign_in:b.users").map((r) => held(r, {
    last_seen_at: sameOrWithin(r.last_seen_at, since("b.users", "signin"), "as read at sign_in"),
    updated_at: sameOrWithin(r.updated_at, since("b.users", "signin"), "as read at sign_in"),
  }, "as read at sign_in"));
  M["held:registry.push_tokens[proof]"] = () => heldAll("ban:registry.push_tokens[proof]", "ban");
  M["held:registry.request_nonces[a]"] = () => heldAll("ban:registry.request_nonces[a]", "ban");
  return M;
}

const fromB64 = (text) => Buffer.from(text, "base64");
