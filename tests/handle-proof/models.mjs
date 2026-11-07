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

// The kid a passkey's key is listed under in an account's log: `sha256:`
// and the hex SHA-256 of its 65-byte uncompressed P-256 point, from the
// virtual authenticator's credential (its PKCS#8 private key, base64).
export function passkeyKid(privateKeyB64) {
  const jwk = createPublicKey(createPrivateKey({ key: Buffer.from(privateKeyB64, "base64"), format: "der", type: "pkcs8" })).export({ format: "jwk" });
  const point = Buffer.concat([Buffer.from([4]), fromB64url(jwk.x), fromB64url(jwk.y)]);
  return `sha256:${sha256hex(point)}`;
}

// `inserted_at` plus `hours`, in the stored form (microseconds, Z).
export function plusHours(stamp, hours) {
  const [, date, time, fraction = ""] = stamp.match(/^(\S+)[T ](\d{2}:\d{2}:\d{2})(\.\d+)?/);
  const at = new Date(Date.parse(`${date}T${time}Z`) + hours * 3_600_000).toISOString().slice(0, 19);
  return `${at}${fraction}Z`;
}

// An entry of a log as the directory stores it (`directory.entries.entry`,
// BYTEA as PostgreSQL's JSON writes it), parsed: its JCS bytes and object.
export function entryOf(stored) {
  const raw = bytesFrom(stored);
  let parsed = null;
  try {
    parsed = raw ? JSON.parse(raw.toString("utf8")) : null;
  } catch {
    parsed = null;
  }
  return { raw, parsed };
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
// The name B's administrator makes their account under.
export const ADMIN_HANDLE = "proof-b";
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
  const id = S.identifier ?? "";
  const genesisHash = `sha256:${id.slice(4)}`;
  const first = (name) => S.rows[name] ?? [];
  const aUser = () => first("setup:a.users")[0]?.id;
  const bAdmin = () => first("allow:b.users")[0]?.id;
  const bytesHex = (buffer) => `\\x${buffer.toString("hex")}`;
  // The two entries the account pages wrote: the genesis, whose hash is
  // the identifier, and the passkey's add_key after it.
  const log = () => first("setup:registry.directory.entries[a]");
  const entry = (seq) => entryOf(log()[seq]?.entry);
  const entryHash = (seq) => `sha256:${sha256hex(entry(seq).raw ?? Buffer.alloc(0))}`;
  const headHash = () => entryHash(1);
  const passkey = () => S.credentials.a?.kid;

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
  // A nonce the signer drew for one request, expiring `lifeS` after it
  // was signed, inside `window` shifted by that: 120 s for a request the
  // account pages sign (`Prima.RegistryRequest`), five minutes for one a
  // CYFR mints for a passkey to sign (`Prima.SignIn.lifetime_ms/0`).
  const nonce = (identifier, window, lifeS = 120, minted = "a signed request") => ({
    identifier: derived(identifier, "the signer's identifier"),
    nonce: captured("16 new bytes", (v) => typeof v === "string" && /^\\x[0-9a-f]{32}$/.test(v), "\\x00"),
    expires_at: within({
      name: `${window.name}, plus the ${lifeS} s ${minted} lives`, from: window.from + lifeS * 1000, to: window.to + lifeS * 1000,
    }),
  });
  const handleAnswer = (handle, identifier) => ({
    status: exact(200),
    protocol: exact("cyfr-handle/v1"),
    registry: exact(REGISTRY),
    handle: exact(handle),
    identifier: derived(identifier, "the owner's genesis, hashed"),
    directory: exact(DIRECTORY),
  });

  const M = {};

  // setup: the account made at registry.test's pages: its log, its name,
  // its acceptance of the registry's policy and the nonces of the two
  // requests the recovery key signed; then A, set up by signing in with it.
  M["setup:registry.directory.entries[a]"] = () => withLabels(["the genesis", "the passkey's add_key"], [
    {
      identifier: derived(id, "the identifier the recovery code names"),
      // A seq no entry of the log holds, so the tamper meets no other row.
      seq: exact(0, { tamper: 7 }),
      kind: exact("genesis"),
      entry_hash: derived(genesisHash, "the identifier's digits: the genesis's hash"),
      prev_hash: nil(),
      entry: relatedTo(log()[0]?.entry, `sha256:${sha256hex(entry(0).raw ?? Buffer.alloc(0))}` === genesisHash && entry(0).parsed?.directory === DIRECTORY,
        "the genesis the page signed: its bytes hash to the identifier, and it names registry.test"),
      bytes: derived(entry(0).raw?.length, "the entry's length"),
      inserted_at: within(win(S, "make")),
    },
    {
      identifier: derived(id, "the identifier the recovery code names"),
      seq: exact(1, { tamper: 8 }),
      kind: exact("add_key"),
      entry_hash: derived(entryHash(1), "the entry's bytes, hashed"),
      prev_hash: derived(genesisHash, "the genesis's hash"),
      entry: relatedTo(log()[1]?.entry, entry(1).parsed?.prev === genesisHash && entry(1).parsed?.key?.kid === passkey() &&
        entry(1).parsed?.key?.credential_id === S.credentials.a?.credentialIdB64url,
        "the passkey's add_key: after the genesis, listing the key and credential the browser's authenticator holds"),
      bytes: derived(entry(1).raw?.length, "the entry's length"),
      inserted_at: within(win(S, "make")),
    },
  ]);
  M["setup:registry.namespaces[proof]"] = () => [nsRow(HANDLE, derived(id, "the identifier the recovery code names"), within(win(S, "make")), within(win(S, "make")))];
  M["setup:registry.identity_heads[a]"] = () => [{
    identifier: derived(id, "the identifier the recovery code names"),
    head: derived(headHash(), "the add_key's hash: the head of the log the claim was verified against"),
    entries: exact(2),
    recovery_epoch: derived(genesisHash, "the genesis's hash: no recover entry since"),
    read_at: within(win(S, "make")),
  }];
  M["setup:registry.policy_acceptances[a]"] = () => [{
    id: aUuid("an acceptance id"),
    policy_version: derived(S.policyVersion, "the registry's GET /v1/legal/version"),
    accepted_at: within(win(S, "make")),
    identifier: derived(id, "the signer's identifier"),
    former_identity: nil(),
  }];
  M["setup:registry.request_nonces[a]"] = () => [nonce(id, win(S, "make")), nonce(id, win(S, "make"))];
  M["setup:handle_answer[proof]"] = () => handleAnswer(HANDLE, id);

  const userRow = (window, admission, readKey) => ({
    id: anId("usr"),
    email: nil(),
    email_verified: nil(),
    admission: exact(admission),
    display_name: nil(),
    namespace: nil(),
    status: exact("active"),
    prefs: exact("{}"),
    first_seen_at: within(win(S, window)),
    last_seen_at: within(until(S, window, readKey)),
    denied_at: noTime(),
    platform_admin_at: admission === "setup" ? within(win(S, window)) : nil(),
    security_generation: exact(1),
    created_at: within(win(S, window)),
    updated_at: within(until(S, window, readKey)),
  });
  const athanorRow = (owner, slug, window, readKey) => ({
    id: anId("ath"),
    name: exact("Me"),
    slug: exact(slug),
    owner_user_id: derived(owner, "its person"),
    status: exact("active"),
    archived_at: noTime(),
    created_by: derived(owner, "its person"),
    settings: nil(),
    provisioned_at: bound(`null, or a time inside ${until(S, window, readKey).name}`, (v) => v === null || inside(until(S, window, readKey), v), LONG_AGO),
    provisioning_failed_at: noTime(),
    provisioning_failure: nil(),
    security_generation: exact(1),
    created_at: within(win(S, window)),
    updated_at: within(until(S, window, readKey)),
  });
  const identityRow = (user, identifier, head, window) => ({
    id: anId("pid"),
    user_id: derived(user, "its person"),
    identifier: derived(identifier, "the account's identifier"),
    head_hash: derived(head, "the head of the account's log when it was admitted"),
    directory_url: exact(DIRECTORY),
    revision: exact(1),
    inserted_at: within(win(S, window)),
    updated_at: within(win(S, window)),
  });
  const directoryHead = (identifier, head, window, readKey) => ({
    identifier: derived(identifier, "the account's identifier"),
    genesis: derived(identifier === id ? entry(0).raw?.toString("utf8") : undefined, "the genesis the directory stores, as its JCS text"),
    directory_url: exact(DIRECTORY),
    head_hash: derived(head, "the head of the account's log as the directory serves it"),
    state: captured("the verified state the head leaves, as JSON text", (v) => typeof v === "string" && v.includes(identifier), "{}"),
    verified_at: within(until(S, window, readKey)),
    gone_at: noTime(),
    revision: captured("the cached head's revision", (v) => Number.isInteger(v) && v >= 1, 0),
    inserted_at: within(win(S, window)),
    updated_at: within(until(S, window, readKey)),
  });
  // A passkey that signed in here: the CYFR knows it by its kid alone,
  // and the client is its own source.
  const passkeyClient = (user, athanor, kid, head, window, row) => ({
    id: anId("pcl"),
    athanor_id: derived(athanor, "the person's own athanor here"),
    user_id: derived(user, "its person"),
    source_kind: exact("passkey"),
    source_id: relatedTo(row?.source_id, !!row && row.source_id === row.id, "the client's own id"),
    device_public_key: nil(),
    standing: exact("active"),
    holder_kind: nil(),
    display_name: nil(),
    kid: derived(kid, "the kid of the key the browser's authenticator holds"),
    head: derived(head, "the head it signed in under"),
    inserted_at: within(win(S, window)),
    updated_at: within(win(S, window)),
  });
  const session = (user, athanor, kid, head, client, cookie, window, row) => ({
    id: anId("ses"),
    token_hash: derived(bytes(Buffer.from(cookie?.sha256 ?? "", "hex")), "the SHA-256 of the session token the browser's cookie carries"),
    token_prefix: derived(cookie?.prefix, "the first 8 characters of that token"),
    user_id: derived(user, "its person"),
    email: nil(),
    provider: exact("passkey"),
    expires_at: derived(plusHours(row?.inserted_at ?? "1970-01-01T00:00:00Z", S.ttlHours), "inserted_at plus session_ttl_hours (Sanctum.Session)"),
    athanor_id: derived(athanor, "the person's own athanor here"),
    kid: derived(kid, "the kid of the key the browser's authenticator holds"),
    head: derived(head, "the head it signed in under"),
    client_id: derived(client, "the passkey's paired client here"),
    inserted_at: within(win(S, window)),
  });

  M["setup:a.users"] = () => [userRow("setup", "setup", "setup:a.users")];
  M["setup:a.athanors"] = () => [athanorRow(aUser(), "me", "setup", "setup:a.athanors")];
  M["setup:a.person_identities"] = () => [identityRow(aUser(), id, headHash(), "setup")];
  M["setup:a.directory_heads"] = () => [directoryHead(id, headHash(), "setup", "setup:a.directory_heads")];
  M["setup:a.paired_clients"] = () => [passkeyClient(aUser(), first("setup:a.athanors")[0]?.id, passkey(), headHash(), "setup", first("setup:a.paired_clients")[0])];

  // allow: B, set up by its administrator's own account, allows @proof.
  const adminId = () => first("allow:b.person_identities")[0]?.identifier;
  const adminHead = () => first("allow:b.person_identities")[0]?.head_hash;
  M["allow:b.users"] = () => [userRow("admin", "setup", "allow:b.users")];
  M["allow:b.athanors"] = () => [athanorRow(bAdmin(), "me", "admin", "allow:b.athanors")];
  M["allow:b.person_identities"] = () => [{
    ...identityRow(bAdmin(), adminId(), adminHead(), "admin"),
    identifier: captured("the administrator's identifier, per_ and 64 hexadecimal digits", (v) => typeof v === "string" && PER.test(v), "~"),
    head_hash: captured("the head of the administrator's log", (v) => typeof v === "string" && HASH.test(v), "~"),
  }];
  M["allow:b.server_allowlist"] = () => byKey(first("allow:b.server_allowlist"), (r) => r.value, [
    [adminId(), {
      id: anId("door"),
      kind: exact("identifier"),
      value: derived(adminId(), "the administrator's identifier"),
      effect: exact("allow"),
      status: exact("allowed"),
      requested_by: nil(),
      added_by: derived(bAdmin(), "B's administrator"),
      note: exact("setup"),
      label: nil(),
      created_at: within(win(S, "admin")),
      updated_at: within(win(S, "admin")),
    }, "setup's allow of the administrator"],
    [id, {
      id: anId("door"),
      kind: exact("identifier"),
      value: derived(id, "the identifier @proof names at the registry"),
      effect: exact("allow"),
      status: exact("allowed"),
      requested_by: nil(),
      added_by: derived(bAdmin(), "B's administrator"),
      note: nil(),
      label: exact(HANDLE),
      created_at: within(win(S, "allow")),
      updated_at: within(win(S, "allow")),
    }, "the allow of @proof"],
  ]);

  // sign_in: the person's passkey, synced to a browser that never visited
  // B, signs them in there: B admits A's identifier under its allow.
  const remote = () => first("sign_in:b.person_identities").find((r) => r.identifier === id)?.user_id;
  const personAthanor = () => first("sign_in:b.athanors").find((r) => r.owner_user_id === remote())?.id;
  const personClient = () => first("sign_in:b.paired_clients").find((r) => r.user_id === remote())?.id;
  M["sign_in:b.person_identities"] = () => byKey(first("sign_in:b.person_identities"), (r) => r.user_id, [
    [bAdmin(), held(first("allow:b.person_identities")[0] ?? {}, {}, "as read at allow"), "the administrator's"],
    [remote(), identityRow(remote(), id, headHash(), "signin"), "the person's"],
  ]);
  M["sign_in:b.users"] = () => byKey(first("sign_in:b.users"), (r) => r.id, [
    [bAdmin(), held(first("allow:b.users")[0] ?? {}, {
      last_seen_at: sameOrWithin(first("allow:b.users")[0]?.last_seen_at, win(S, "signin"), "as read at allow"),
      updated_at: sameOrWithin(first("allow:b.users")[0]?.updated_at, win(S, "signin"), "as read at allow"),
    }, "as read at allow"), "the administrator's"],
    [remote(), { ...userRow("signin", "open", "sign_in:b.users"), id: derived(remote(), "B's identity row for A's identifier") }, "the person's"],
  ]);
  M["sign_in:b.athanors"] = () => byKey(first("sign_in:b.athanors"), (r) => r.owner_user_id, [
    [bAdmin(), held(first("allow:b.athanors")[0] ?? {}, {
      provisioned_at: sameOrWithin(first("allow:b.athanors")[0]?.provisioned_at, win(S, "signin"), "as read at allow"),
      updated_at: sameOrWithin(first("allow:b.athanors")[0]?.updated_at, win(S, "signin"), "as read at allow"),
    }, "as read at allow"), "the administrator's"],
    [remote(), athanorRow(remote(), "me-2", "signin", "sign_in:b.athanors"), "the person's"],
  ]);
  M["sign_in:b.directory_heads"] = () => byKey(first("sign_in:b.directory_heads"), (r) => r.identifier, [
    [adminId(), { ...directoryHead(adminId(), adminHead(), "admin", "sign_in:b.directory_heads"), genesis: captured("the administrator's genesis", (v) => typeof v === "string" && v.includes("genesis"), "~") }, "the administrator's"],
    // B read the person's log when the allow resolved @proof.
    [id, directoryHead(id, headHash(), "allow", "sign_in:b.directory_heads"), "the person's, read at the allow"],
  ]);
  const clientOf = (user) => first("sign_in:b.paired_clients").find((r) => r.user_id === user);
  M["sign_in:b.paired_clients"] = () => byKey(first("sign_in:b.paired_clients"), (r) => r.user_id, [
    [bAdmin(), { ...passkeyClient(bAdmin(), first("allow:b.athanors")[0]?.id, S.credentials.b?.kid, adminHead(), "admin", clientOf(bAdmin())),
      kid: derived(S.credentials.b?.kid, "the kid of the key the administrator's authenticator holds") }, "the administrator's"],
    [remote(), passkeyClient(remote(), personAthanor(), passkey(), headHash(), "signin", clientOf(remote())), "the person's"],
  ]);
  const sessionOf = (user) => first("sign_in:b.sessions").find((r) => r.user_id === user);
  M["sign_in:b.sessions"] = () => byKey(first("sign_in:b.sessions"), (r) => r.user_id, [
    [bAdmin(), session(bAdmin(), first("allow:b.athanors")[0]?.id, S.credentials.b?.kid, adminHead(),
      first("sign_in:b.paired_clients").find((r) => r.user_id === bAdmin())?.id, S.cookies.admin, "admin", sessionOf(bAdmin())), "the administrator's"],
    [remote(), session(remote(), personAthanor(), passkey(), headHash(), personClient(), S.cookies.remote, "signin", sessionOf(remote())), "the person's"],
  ]);

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
    role: exact("personal", { shown: "`\"personal\"`: a personal namespace's role, in `Sanctum.RegistryCredentials`' stored shape" }),
    issued_at: derived(sealed()?.issued_at, "the row's issued_at"),
    label: derived(token()?.label, "the registry's label for that token"),
  });
  M["sync:registry.push_tokens[proof]"] = () => [{
    id: aUuid("a token id"),
    token_hash: derived(`\\x${S.credentialDigest ?? ""}`, "the digest of the token A sealed"),
    namespace_slug: exact(HANDLE),
    label: derived(S.credentialLabel, "the label A sealed with the token"),
    created_at: within(win(S, "sync")),
    last_used_at: noTime(),
    revoked_at: noTime(),
    created_by: derived(id, "A's identifier"),
    recovery_epoch: derived(genesisHash, "the genesis's hash: no recover entry since"),
  }];
  // The nonces read before, each held, and `added` new ones.
  const grown = (before, now, step, added, model) => {
    const fresh = now.filter((r) => !before.some((b) => b.nonce === r.nonce)).map((r) => r.nonce);
    return byKey(now, (r) => r.nonce, [
      ...before.map((b) => [b.nonce, held(b, {}, `as read at ${step}`), `a nonce read at ${step}`]),
      ...Array.from({ length: added }, (_, i) => [fresh[i] ?? `new ${i}`, model, "a new nonce"]),
    ]);
  };
  M["sync:registry.request_nonces[a]"] = () =>
    grown(first("setup:registry.request_nonces[a]"), first("sync:registry.request_nonces[a]"), "setup", 1,
      nonce(id, win(S, "sync"), 300, "a request a CYFR mints for a passkey"));
  M["sync:registry.identity_heads[a]"] = () => [held(first("setup:registry.identity_heads[a]")[0] ?? {}, {
    read_at: sameOrWithin(first("setup:registry.identity_heads[a]")[0]?.read_at, win(S, "sync"), "as read at setup"),
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
  M["ban:registry.push_tokens[proof]"] = () => [held(token() ?? {}, { revoked_at: within(win(S, "ban")) }, "as read at sync", M["sync:registry.push_tokens[proof]"]()[0])];
  M["ban:token_refused"] = () => ({ status: exact(401), body: exact({ errors: [{ code: "UNAUTHORIZED", message: "token revoked" }] }) });
  M["ban:a.sync_refused"] = () => ({ shown: exact(`That did not go through: ${S.refusals.banned?.sentence}`), shared_with: exact([]) });
  M["ban:registry.request_nonces[a]"] = () =>
    grown(first("sync:registry.request_nonces[a]"), first("ban:registry.request_nonces[a]"), "sync", 0, null);

  // ban, last: every object read earlier, held since, each with the
  // fields later steps legitimately move.
  const since = (name, step) => ({ name: `the run from ${step}'s end to the last read`, from: S.w[step].to, to: S.at[`held:${name}`] });
  const heldAll = (name, step, moves = () => ({})) => {
    const base = M[name] ? M[name]() : [];
    return first(name).map((r, i) => held(r, moves(r), `as read at ${step}`, Array.isArray(base) ? base[i] : {}));
  };
  const moving = (name, step, fields) => (r) => Object.fromEntries(fields.map((f) =>
    [f, sameOrWithin(r[f], since(name, step), `as read at ${step}`)]));
  M["held:a.users"] = () => heldAll("setup:a.users", "setup", (r) => ({
    ...moving("a.users", "setup", ["last_seen_at", "updated_at"])(r),
    namespace: exact(HANDLE, { shown: "`\"proof\"`: the personal namespace the sync recorded (`Sanctum.SignIn.record_namespace/2`)" }),
  }));
  M["held:a.athanors"] = () => heldAll("setup:a.athanors", "setup", moving("a.athanors", "setup", ["provisioned_at", "updated_at"]));
  M["held:a.directory_heads"] = () => heldAll("setup:a.directory_heads", "setup", (r) => ({
    ...moving("a.directory_heads", "setup", ["verified_at", "updated_at"])(r),
    revision: captured("the cached head's revision, moved by each read since", (v) => Number.isInteger(v) && v >= r.revision, 0),
  }));
  M["held:b.users"] = () => heldAll("sign_in:b.users", "sign_in", moving("b.users", "signin", ["last_seen_at", "updated_at"]));
  M["held:b.athanors"] = () => heldAll("sign_in:b.athanors", "sign_in", moving("b.athanors", "signin", ["provisioned_at", "updated_at"]));
  for (const [name, step] of [["setup:a.person_identities", "setup"], ["setup:a.paired_clients", "setup"],
    ["sync:a.registry_tokens", "sync"], ["setup:registry.directory.entries[a]", "setup"],
    ["setup:registry.namespaces[proof]", "setup"], ["setup:registry.policy_acceptances[a]", "setup"],
    ["ban:registry.banned_identities", "ban"], ["allow:b.server_allowlist", "allow"],
    ["sign_in:b.sessions", "sign_in"], ["sign_in:b.person_identities", "sign_in"], ["sign_in:b.paired_clients", "sign_in"]]) {
    M[`held:${name.split(":").pop()}`] = () => heldAll(name, step);
  }
  M["held:registry.identity_heads[a]"] = () => heldAll("setup:registry.identity_heads[a]", "setup", () => ({
    read_at: sameOrWithin(first("sync:registry.identity_heads[a]")[0]?.read_at, since("registry.identity_heads[a]", "sync"), "as read at sync"),
  }));
  M["held:registry.push_tokens[proof]"] = () => heldAll("ban:registry.push_tokens[proof]", "ban");
  M["held:registry.request_nonces[a]"] = () => heldAll("ban:registry.request_nonces[a]", "ban");
  return M;
}
