// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The handle proof, run in the official Playwright image by run.sh against
// `cyfr` releases behind the harness's HTTPS front and cyfr.run's registry
// (README.md): the directory dir.test, the person's CYFR A (a.test), the
// CYFR B (b.test) they sign in at, and the registry at registry.test.
// Chromium drives every step with its virtual WebAuthn authenticator.
//
// After each step the proof reads every object the step claims, whole,
// and compares it with its model, in which every field is exact, derived
// from another source, or held to a bound (`exact`, `derived`, `bound`);
// a field the model does not name, or a named field the object lacks,
// fails it. Once a comparison holds, each field of a stored object is
// written behind the browsers' back to a value its model refuses, the
// object is read again and the comparison must fail on that field, and
// the stored value is written back and the comparison must hold again
// (`shown`). The README's field table is the one these models print.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import {
  ask as askRunSh, launchBrowser, readHomes, redact as redactKnown, saveKit, startProxy, waitFor,
} from "../browser/lib.mjs";

const [homesFile, outDir] = process.argv.slice(2);
const { homes } = readHomes(homesFile);
const originOf = (name) => homes.find((home) => home.name === name).origin;
const A = originOf("a");
const B = originOf("b");
const REGISTRY = "registry.test";
// The OCI host a push token is for, which A keys its stored tokens by.
const OCI = `registry.${REGISTRY}`;
const DIRECTORY = "https://dir.test";
const HANDLE = "proof";
const OTHER = "other";
const layer = "#system-layer-dialog";

const secrets = [];
const redact = (text) => redactKnown(text, secrets);
const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });

const rows = [];
const record = { objects: {} };
const contexts = [];

function row(step, held, what, detail) {
  rows.push({ step, held, what, detail });
  console.log(`${held ? "ok" : "FAIL"}: ${step}: ${what}`);
  return held;
}

// ---------------------------------------------------------------------------
// Models: every field exact, derived or bound
// ---------------------------------------------------------------------------

// `tamper`, where given, is the value a tamper writes in place of the
// generic one, for a column whose constraints refuse that.
const exact = (value, tamper, shown) => ({ cls: "exact", value, tamper, shown });
const derived = (value, from, tamper) => ({ cls: "derived", value, from, tamper });
const bound = (says, holds, outside) => ({ cls: "bound", says, holds, outside });

const ISO = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/;
const msOf = (text) => {
  if (typeof text !== "string" || !ISO.test(text)) return NaN;
  const [, date, time, fraction = "", zone = "Z"] = text.match(/^(\S+)[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$/);
  return Date.parse(`${date}T${time}${fraction.slice(0, 4)}${zone || "Z"}`);
};
const LONG_AGO = "2001-01-01T00:00:00.000000Z";
// A time column that must be empty: its tamper writes a time, which a
// registry column of a time type takes where text would not.
const noTime = () => exact(null, LONG_AGO);
// A time between `from` and when the object was read, with a second each
// side for the clocks' resolution.
const during = (window) => bound(`a time inside ${window.name}`, (v) => {
  const at = msOf(v);
  return at >= window.from - 1_000 && at <= (window.to ?? Date.now()) + 1_000;
}, LONG_AGO);
const later = (window, says) => bound(says, (v) => msOf(v) > (window.to ?? Date.now()), LONG_AGO);
const bytesOf = (v) => (v && typeof v.bytes === "string" ? Buffer.from(v.bytes, "base64") : null);
// Byte bounds are shown failing by a single byte, and a shape by a value
// that has none of it.
const ONE_BYTE = { bytes: Buffer.from([0]).toString("base64") };
const nbytes = (n, says) => bound(says, (v) => bytesOf(v)?.length === n, ONE_BYTE);
const somebytes = (says) => bound(says, (v) => (bytesOf(v)?.length ?? 0) > 32, ONE_BYTE);
const shaped = (re, says, outside = "~") => bound(says, (v) => typeof v === "string" && re.test(v), outside);
const NIL_UUID = "00000000-0000-0000-0000-000000000000";
// A UUID column holds a UUID by its type, so the bound is that it is not
// the nil UUID, which a tamper writes.
const uuid = (says) => bound(`${says}: a UUID, not the nil UUID`, (v) => UUID.test(v) && v !== NIL_UUID, NIL_UUID);
const PER = /^per_[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CYFR_ID = /^[a-z]+_[A-Za-z0-9_-]{8,}$/;
const EPOCH = /^sha256:[0-9a-f]{64}$/;
const HASH = EPOCH;

// The generic value a tamper writes: one the field's model refuses.
function tampered(spec, value) {
  if (spec.tamper !== undefined) return spec.tamper;
  if (spec.cls === "bound" && spec.outside !== undefined) return spec.outside;
  if (bytesOf(value)) {
    const bytes = bytesOf(value);
    bytes[0] ^= 0xff;
    return { bytes: bytes.toString("base64") };
  }
  if (value === null) return "tampered";
  if (typeof value === "string" && PER.test(value)) return `per_${"0".repeat(64)}`;
  if (typeof value === "string" && EPOCH.test(value)) return `sha256:${"0".repeat(64)}`;
  if (typeof value === "string" && UUID.test(value)) return "00000000-0000-0000-0000-000000000000";
  if (typeof value === "boolean") return !value;
  if (typeof value === "number") return value + 1;
  if (typeof value === "string" && ISO.test(value)) return LONG_AGO;
  // PostgreSQL's bytes, as row_to_json writes them: the first digit changed.
  if (typeof value === "string" && /^\\x[0-9a-f]+$/.test(value)) return `\\x${value[2] === "0" ? "1" : "0"}${value.slice(3)}`;
  if (typeof value === "string") return `${value}~`;
  if (Array.isArray(value)) return [...value, "00000000-0000-0000-0000-000000000000"];
  return null;
}

// Every field of `object` against `model`: the mismatches, each naming its
// field. A list compares row by row.
function mismatches(object, model, at = "") {
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
    const held = spec.cls === "bound" ? spec.holds(value) : isDeepStrictEqual(value, spec.value);
    if (!held) out.push({ field: path, cls: spec.cls, want: spec.cls === "bound" ? spec.says : spec.value, got: value });
  }
  return out;
}

// The model's fields as the README's table rows.
function classification(name, model) {
  const one = Array.isArray(model) ? model : [model];
  return one.flatMap((m, i) => Object.entries(m).map(([field, spec]) => {
    const what = spec.cls === "exact" ? spec.shown ?? `\`${JSON.stringify(spec.value)}\`` : spec.cls === "derived" ? spec.from : spec.says;
    return `| ${name}${one.length > 1 ? `[${i}]` : ""} | ${field} | ${spec.cls} | ${what} |`;
  }));
}
const table = [];

// One claimed object: `read` answers it whole; `stored`, for a stored
// object, writes a field of its row i (`stored(i, field, value, row)`);
// `via`, for a view such as a registry answer, maps each of its fields to
// the stored field that makes it (null for none) and gives the value a
// tamper writes there and the original the restore writes back.
async function check(step, name, read, model, { stored = null, via = null, what = name } = {}) {
  const tableRows = classification(`${step}: ${name}`, model);
  table.push(...tableRows);
  const object = await read();
  const found = mismatches(object, model);
  record.objects[`${step}:${name}`] = { object, mismatches: found };
  if (found.length) return row(step, false, `${what} is the model's`, { mismatches: found });
  if (!stored) return row(step, true, `${what} is the model's (no stored copy: held as read)`, { fields: tableRows.length });

  // Shown failing: each stored field, written behind the browsers' back.
  const shown = [];
  const list = Array.isArray(model) ? model : [model];
  const objects = Array.isArray(model) ? object : [object];
  for (let i = 0; i < list.length; i++) {
    for (const [field, spec] of Object.entries(list[i])) {
      const target = via ? via[field] : field;
      if (target === null) {
        shown.push({ row: i, field, tampered: "no stored field makes it" });
        continue;
      }
      const original = via ? undefined : objects[i][field];
      const value = via ? via.value(target, objects[i]) : tampered(spec, original);
      const written = await stored(i, target, value, objects[i], "tamper");
      const failing = mismatches(await read().catch((error) => ({ unreadable: String(error.message) })), model);
      // The restore finds the row by the value the tamper left in it.
      await stored(i, target, via ? via.original(target, objects[i]) : original, { ...objects[i], [target]: value }, "restore");
      const again = mismatches(await read(), model);
      const name1 = Array.isArray(model) ? `[${i}].${field}` : `.${field}`;
      const named = failing.some((m) => m.field === name1 || m.field === "(object)" || m.field === "#");
      shown.push({ row: i, field, written, failed_on: failing.map((m) => m.field), named, held_again: again.length === 0 });
      if (!named || again.length) {
        return row(step, false, `${what}: a tamper of ${name1} was not caught, or the restore did not hold`, { shown });
      }
    }
  }
  return row(step, true, `${what} is the model's, and each stored field written behind its back fails it`, { fields: tableRows.length, shown: shown.length });
}

// A CYFR's table, whole or the rows whose `column` is `value`.
const cyfrRows = (cell, table, column = "", value = "") => async () =>
  (await ask({ op: "rows", cell, table, column, value })).rows;
const cyfrStore = (cell, table) => async (i, field, value, rowNow) => {
  const answer = await ask({ op: "set", cell, table, id: rowNow.id, field, value });
  if (answer.set !== 1) throw new Error(`${cell}.${table}.${field}: the write changed ${JSON.stringify(answer)}`);
  return true;
};
const registryRows = (table, column, value) => async () =>
  (await ask({ op: "registry_rows", table, column, value })).rows;
const registryStore = (table, key) => async (i, field, value, rowNow, phase) => {
  const answer = await ask({ op: "registry_set", table, key, key_value: String(rowNow[key]), field, value, phase });
  if (answer.set !== 1) throw new Error(`registry ${table}.${field}: the write changed ${JSON.stringify(answer)}`);
  return true;
};
const handleAnswer = (handle) => async () => {
  const { status, body } = await ask({ op: "handle_answer", handle });
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    parsed = { unparsed: body };
  }
  return { status, ...parsed };
};

// ---------------------------------------------------------------------------
// Browsers and the virtual authenticator (as tests/join-proof/common.mjs)
// ---------------------------------------------------------------------------

const authenticators = new Map();
const highest = new Map();
const held = async (handle) => (await handle.cdp.send("WebAuthn.getCredentials", { authenticatorId: handle.id })).credentials;
const highestOf = (credential) => Math.max(credential.signCount, highest.get(credential.credentialId) ?? 0);

async function authenticatorWith(page, credentials = []) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("WebAuthn.enable", { enableUI: false });
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true,
      isUserVerified: true, automaticPresenceSimulation: true,
    },
  });
  const handle = { cdp, id: authenticatorId };
  authenticators.set(page, handle);
  for (const credential of credentials) {
    await cdp.send("WebAuthn.addCredential", { authenticatorId, credential: { ...credential, signCount: highestOf(credential) } });
  }
}

async function counted() {
  for (const [page, handle] of authenticators) {
    try {
      for (const credential of await held(handle)) highest.set(credential.credentialId, highestOf(credential));
    } catch {
      authenticators.delete(page);
    }
  }
}

async function ready(page) {
  await counted();
  const handle = authenticators.get(page);
  if (!handle) return;
  for (const credential of await held(handle)) {
    const count = highestOf(credential);
    if (count === credential.signCount) continue;
    await handle.cdp.send("WebAuthn.removeCredential", { authenticatorId: handle.id, credentialId: credential.credentialId });
    await handle.cdp.send("WebAuthn.addCredential", { authenticatorId: handle.id, credential: { ...credential, signCount: count } });
  }
}

async function credentialsFor(page, host) {
  await counted();
  return (await held(authenticators.get(page))).filter((c) => c.rpId === host).map((c) => ({ ...c, signCount: highestOf(c) }));
}

async function freshContext(browser) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  contexts.push(context);
  return context;
}

const connected = (page) => page.waitForSelector(".phx-connected", { timeout: 60_000 });

async function confirmHere(page) {
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  await page.waitForSelector(`${own} [data-test="confirm-passkey"]`, { timeout: 60_000 });
  const preview = await page.locator(`${own} [data-test="confirmation-preview"]`).first().innerText().catch(() => "");
  await ready(page);
  await page.locator(`${own} [data-test="confirm-passkey"]`).click();
  await page.waitForFunction((selector) => !document.querySelector(selector), `${own} [data-test="confirm-passkey"]`, { timeout: 30_000 }).catch(() => null);
  await counted();
  return preview;
}

async function readKit(page) {
  const kit = `${layer} [data-test="recovery-kit"]:not([hidden])`;
  await page.waitForSelector(`${kit} [data-test="kit-secret"]`, { timeout: 60_000 });
  const line = (test) => page.locator(`${kit} [data-test="${test}"]`).textContent();
  const lines = { identifier: await line("kit-identifier"), directory_url: await line("kit-directory"), recovery_secret: await line("kit-secret") };
  secrets.push(lines.recovery_secret);
  return lines;
}

const flash = (page) => page.locator("#flash-info, #flash-error, [role=alert]").allInnerTexts();

async function dumpPages() {
  for (const context of contexts) {
    for (const page of context.pages()) {
      const text = await page.locator("body").innerText({ timeout: 2_000 }).catch(() => "unread");
      console.error(`  at ${page.url().replace(/#.*/, "#…")}: ${JSON.stringify(redact(text).slice(0, 1500))}`);
    }
  }
}

// /setup at `origin` with the setup token run.sh holds for `cell`: a
// passkey makes the first person, who lands back on the setup page signed
// in.
async function setUp(page, origin, cell) {
  const { token } = await ask({ op: "setup_token", cell }, { secret: true });
  secrets.push(token);
  await page.goto(`${origin}/setup#${token}`);
  await page.locator('[data-test="setup-create"]').waitFor({ timeout: 60_000 });
  await ready(page);
  await page.locator('[data-test="setup-create"]').click();
  await page.waitForSelector('[data-test="setup-done"]', { timeout: 60_000 });
  await connected(page);
  await counted();
}

// The segment of the person's own athanor, from where Continue lands
// (`/chat?a=@me`, or a page under `/a/<segment>`).
async function continueToCyfr(page, origin) {
  await page.locator('[data-test="setup-continue"]').click();
  await page.waitForURL((url) => url.origin === origin && (url.pathname === "/chat" || url.pathname.startsWith("/a/")), { timeout: 60_000 });
  const url = new URL(page.url());
  return url.searchParams.get("a") ?? decodeURIComponent(url.pathname.split("/")[2]);
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function main(chromium) {
  const started = (await ask({ op: "run_started" })).at;
  const run = { name: "the run", from: started };
  const window = (name, from = started) => ({ name, from, to: Date.now() });
  record.versions = { chromium: chromium.version() };

  // 1. Setup at A: a passkey, @proof, enrollment at dir.test, the kit
  // acknowledged, and the claim at the registry.
  const deskContext = await freshContext(chromium);
  const desk = await deskContext.newPage();
  await authenticatorWith(desk);
  await setUp(desk, A, "a");
  await desk.locator('[data-test="identity-handle-input"]').fill(HANDLE);
  await desk.waitForSelector('[data-test="identity-handle-check"][data-check="free"]', { timeout: 60_000 });
  await desk.locator('[data-test="identity-choose"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="enrollment"]`, { timeout: 60_000 });
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  const enrollPreview = await confirmHere(desk);
  const kit = await readKit(desk);
  await saveKit(desk);
  await desk.waitForSelector('[data-test="identity-claimed"]', { timeout: 120_000 });
  const claimedText = await desk.locator('[data-test="identity-claimed"]').innerText();
  const [aCredential] = await credentialsFor(desk, "a.test");
  const setupDone = window("the run up to the claim");
  const identifier = kit.identifier;
  record.setup = { identifier, kit_directory: kit.directory_url, enroll_preview: enrollPreview, claimed: claimedText };
  if (!row("setup", PER.test(identifier) && kit.directory_url === DIRECTORY && claimedText.includes(`@${HANDLE}`),
    "A is set up through /setup with a passkey; @proof chosen, the enrollment at dir.test confirmed with it, the kit acknowledged and the handle claimed",
    record.setup)) return;

  const aPasskeys = await cyfrRows("a", "passkeys")();
  const aUserId = aPasskeys[0]?.user_id;
  const aIdentities = await cyfrRows("a", "person_identities")();
  const heads = await registryRows("identity_heads", "identifier", identifier)();
  const keyEpoch = heads[0]?.key_epoch;
  const recoveryEpoch = heads[0]?.recovery_epoch;

  await check("setup", "a.passkeys", cyfrRows("a", "passkeys"), [{
    id: shaped(CYFR_ID, "a CYFR id"),
    user_id: derived(aUserId, "the user id A's one passkey row names (the row whose credential the browser holds)"),
    credential_id: derived(aCredential.credentialId.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""), "the credential the browser's authenticator holds for a.test, base64url"),
    rp_id: exact("a.test"),
    relying_home: exact(A),
    public_key: somebytes("a COSE public key: more than 32 bytes"),
    sign_count: derived(aCredential.signCount, "the authenticator's count for that credential"),
    identity_recovery_epoch: exact(null),
    state: exact("active", "revoked"),
    registration_digest: shaped(HASH, "a sha256: digest"),
    possession_verified: exact(1),
    expires_at: noTime(),
    admin_confirmation_id: exact(null),
    activated_at: during(setupDone),
    revoked_at: exact(null),
    inserted_at: during(setupDone),
    updated_at: during(setupDone),
  }], { stored: cyfrStore("a", "passkeys"), what: "A's one passkey, the one the browser holds" });

  await check("setup", "a.users", cyfrRows("a", "users"), [{
    id: derived(aUserId, "the passkey's user id"),
    email: exact(null),
    email_verified: exact(null),
    admission: exact("setup", "open"),
    display_name: exact(null),
    namespace: exact(HANDLE),
    personal_athanor_id: shaped(CYFR_ID, "an athanor id"),
    status: exact("active"),
    prefs: exact("{}"),
    first_seen_at: during(setupDone),
    last_seen_at: during({ ...run }),
    denied_at: exact(null),
    security_generation: exact(1),
    created_at: during(setupDone),
    updated_at: during({ ...run }),
  }], { stored: cyfrStore("a", "users"), what: "A's one person, admitted by setup, holding @proof" });

  await check("setup", "a.person_identities", cyfrRows("a", "person_identities"), [{
    id: shaped(CYFR_ID, "a CYFR id"),
    user_id: derived(aUserId, "the passkey's user id"),
    identifier: derived(identifier, "the kit's identifier line, as the browser showed it"),
    provenance: exact("local", "remote"),
    enrollment: exact("enrolled", "none"),
    live_public_key: nbytes(32, "an Ed25519 public key: 32 bytes"),
    operational_public_key: nbytes(32, "an Ed25519 public key: 32 bytes"),
    live_key_sealed: somebytes("sealed key material: more than 32 bytes"),
    operational_key_sealed: somebytes("sealed key material: more than 32 bytes"),
    genesis_hash: derived(`sha256:${identifier.slice(4)}`, "the identifier's hash, sha256: in place of per_"),
    head_hash: derived(heads[0]?.head, "the head the registry read at dir.test (identity_heads)"),
    directory_url: exact(DIRECTORY),
    first_method_at: during(setupDone),
    revision: exact(4, undefined, "`4`: the row as setup, the enrollment and the kit's acknowledgement leave it"),
    inserted_at: during(setupDone),
    updated_at: during(setupDone),
  }], { stored: cyfrStore("a", "person_identities"), what: "A's identity: the kit's identifier, enrolled at dir.test" });

  await check("setup", "registry.namespaces[proof]", registryRows("namespaces", "slug", HANDLE), [{
    slug: exact(HANDLE),
    kind: exact("personal"),
    reserved: exact(false),
    domain_verified: exact(false),
    verify_token: exact(null),
    verified_at: noTime(),
    last_checked_at: noTime(),
    consecutive_failures: exact(0),
    display_name: exact(null),
    expires_at: noTime(),
    created_at: during(setupDone),
    updated_at: during(setupDone),
    owner_identifier: derived(identifier, "the kit's identifier"),
    address: exact(null),
    reserved_reason: exact(null),
  }], { stored: registryStore("namespaces", "slug"), what: "the registry's @proof: personal, owned by A's identifier, no address" });

  await check("setup", "registry.identity_heads", registryRows("identity_heads", "identifier", identifier), [{
    identifier: derived(identifier, "the kit's identifier"),
    head: derived(aIdentities[0]?.head_hash, "A's own head (person_identities.head_hash)"),
    entries: exact(1),
    recovery_epoch: shaped(EPOCH, "a recovery epoch"),
    key_epoch: shaped(EPOCH, "a key epoch"),
    read_at: during(setupDone),
  }], { stored: registryStore("identity_heads", "identifier"), what: "the registry's read of A's log at dir.test" });

  const answerModel = (address) => ({
    status: exact(200),
    protocol: exact("cyfr-handle/v1"),
    registry: exact(REGISTRY),
    handle: exact(HANDLE),
    identifier: derived(identifier, "the kit's identifier"),
    directory: exact(DIRECTORY),
    ...(address ? { address: exact(address) } : {}),
  });
  const ownerVia = (address) => ({
    status: null, protocol: null, registry: null, directory: null,
    handle: "slug", identifier: "owner_identifier", address: address ? "address" : null,
    value: (field) => ({ slug: `${HANDLE}x`, owner_identifier: `per_${"0".repeat(64)}`, address: `${A}:8443` })[field],
    original: (field) => ({ slug: HANDLE, owner_identifier: identifier, address })[field],
  });
  const viaNamespace = (slug) => async (i, field, value, rowNow, phase) =>
    registryStore("namespaces", "slug")(0, field, value, { slug: rowNow?.slug ?? slug }, phase);
  await check("setup", "handle_answer[proof]", handleAnswer(HANDLE), answerModel(null),
    { stored: viaNamespace(HANDLE), via: ownerVia(null), what: "the registry's answer for @proof: A's identifier and directory, no address" });

  // 2. Publication of A's address from Settings.
  const segment = await continueToCyfr(desk, A);
  await desk.goto(`${A}/a/${encodeURIComponent(segment)}/settings`);
  await connected(desk);
  await desk.waitForSelector('[data-test="identity-publish"][data-published="false"]', { timeout: 60_000 });
  await desk.locator('[data-test="identity-publish"] button').click();
  await desk.waitForSelector('[data-test="identity-publish"][data-published="true"]', { timeout: 60_000 });
  const published = window("the run up to the publication");
  row("publish", true, "Settings at A publishes A's address with @proof", {});
  await check("publish", "registry.namespaces[proof]", registryRows("namespaces", "slug", HANDLE), [{
    slug: exact(HANDLE),
    kind: exact("personal"),
    reserved: exact(false),
    domain_verified: exact(false),
    verify_token: exact(null),
    verified_at: noTime(),
    last_checked_at: noTime(),
    consecutive_failures: exact(0),
    display_name: exact(null),
    expires_at: noTime(),
    created_at: during(setupDone),
    updated_at: during(published),
    owner_identifier: derived(identifier, "the kit's identifier"),
    address: exact(A),
    reserved_reason: exact(null),
  }], { stored: registryStore("namespaces", "slug"), what: "the registry's @proof now holds A's address" });
  await check("publish", "handle_answer[proof]", handleAnswer(HANDLE), answerModel(A),
    { stored: viaNamespace(HANDLE), via: ownerVia(A), what: "the registry's answer for @proof publishes A's address" });

  // 3. B's administrator, set up through /setup, allows @proof.
  const adminContext = await freshContext(chromium);
  const admin = await adminContext.newPage();
  await authenticatorWith(admin);
  await setUp(admin, B, "b");
  const bSegment = await continueToCyfr(admin, B);
  const [bCredential] = await credentialsFor(admin, "b.test");
  const bPasskeys = await cyfrRows("b", "passkeys")();
  const bAdminId = bPasskeys.find((p) => p.credential_id === bCredential.credentialId.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""))?.user_id;
  await admin.goto(`${B}/a/${encodeURIComponent(bSegment)}/settings`);
  await connected(admin);
  const entry = admin.locator('#door-entry-form input[name="value"]');
  await entry.fill(`@${HANDLE}`);
  const allow = admin.locator("#door-entry-form button", { hasText: "Allow" });
  await waitFor(async () => (await allow.getAttribute("phx-value-door")) === `@${HANDLE}`, { timeoutMs: 30_000, what: "the door form taking @proof" });
  await allow.click();
  await admin.waitForSelector('[data-test="door-entry-label"]', { timeout: 60_000 });
  const allowed = window("the run up to the allow");
  row("allow", true, "B's administrator, set up through /setup, allows @proof in Settings", { flash: await flash(admin) });
  await check("allow", "b.server_allowlist", cyfrRows("b", "server_allowlist"), [{
    id: shaped(CYFR_ID, "a CYFR id"),
    kind: exact("identifier", "person"),
    value: derived(identifier, "the identifier @proof names at the registry (A's kit)"),
    effect: exact("allow", "deny"),
    status: exact("allowed", "requested"),
    requested_by: exact(null),
    added_by: derived(bAdminId, "B's administrator: the user of B's passkey the admin's browser holds"),
    note: exact(null),
    label: exact(HANDLE),
    created_at: during(allowed),
    updated_at: during(allowed),
  }], { stored: cyfrStore("b", "server_allowlist"), what: "B's allowlist: one entry, A's identifier, labelled @proof" });

  // 4. At B, "I run my own CYFR" with @proof: A through the published
  // address, and the carry admits the person as A's identifier.
  const personContext = await freshContext(chromium);
  const person = await personContext.newPage();
  await authenticatorWith(person, await credentialsFor(desk, "a.test"));
  await person.goto(`${B}/login`);
  await connected(person);
  await person.locator("#cyfr-own-open").click();
  await person.locator("#cyfr-own-entry").fill(`@${HANDLE}`);
  await person.locator('#cyfr-own button[type="submit"]').click();
  await person.waitForURL((url) => url.origin === A && url.pathname === "/login", { timeout: 60_000 });
  await connected(person);
  await ready(person);
  await person.locator("#passkey-sign-in [data-webauthn-start]").click();
  await person.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
  await connected(person);
  await counted();
  await person.waitForFunction((b) => document.getElementById("carry-destination")?.value === b, B, { timeout: 30_000 });
  await person.locator('#carry-begin button[type="submit"]').click();
  await person.waitForURL((url) => url.origin === B && url.pathname === "/login", { timeout: 60_000 });
  await person.waitForSelector('[data-test="code"]', { timeout: 60_000 });
  const code = (await person.locator('[data-test="code"]').textContent()).trim();
  await person.locator('[data-test="cyfr-continue"]').click();
  await person.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
  await connected(person);
  const confirmation = await confirmHere(person);
  // Admitted with no seat at B yet, the person lands on B's sign-in page,
  // which says they are signed in and have no athanor there.
  await person.waitForURL((url) => url.origin === B && url.search === "?error=no_athanor", { timeout: 90_000 });
  await connected(person);
  const signedIn = window("the run up to B's admission");
  const landedText = await person.locator("body").innerText();
  record.sign_in = {
    code, code_named_at_a: confirmation.includes(code), landed: person.url().replace(/#.*/, ""),
    says_signed_in: landedText.includes("You're signed in, but you have no athanor here yet."),
  };
  row("sign_in", record.sign_in.code_named_at_a && record.sign_in.landed === `${B}/login?error=no_athanor` && record.sign_in.says_signed_in,
    "at B, @proof leads through the published address to A, A's confirmation names B's code, and B admits the person, who has no athanor there yet", record.sign_in);

  const bIdentities = await cyfrRows("b", "person_identities", "identifier", identifier)();
  const remoteId = bIdentities[0]?.user_id;
  await check("sign_in", "b.person_identities[proof]", cyfrRows("b", "person_identities", "identifier", identifier), [{
    id: shaped(CYFR_ID, "a CYFR id"),
    user_id: derived(remoteId, "the user B's identity row for A's identifier names"),
    identifier: derived(identifier, "A's kit"),
    provenance: exact("remote", "local"),
    enrollment: exact("enrolled", "none"),
    live_public_key: exact(null, undefined, "`null`: B keeps no copy of a remote person's keys here; it reads them at the directory"),
    operational_public_key: exact(null),
    live_key_sealed: exact(null),
    operational_key_sealed: exact(null),
    genesis_hash: derived(`sha256:${identifier.slice(4)}`, "the identifier's hash, sha256: in place of per_"),
    head_hash: derived(aIdentities[0]?.head_hash, "A's own head"),
    directory_url: exact(DIRECTORY),
    first_method_at: exact(null),
    revision: exact(1),
    inserted_at: during(signedIn),
    updated_at: during(signedIn),
  }], { stored: cyfrStore("b", "person_identities"), what: "B holds A's identifier as a remote person, under A's keys and head" });
  const remoteUser = async () => (await cyfrRows("b", "users")()).filter((u) => u.id === remoteId);
  await check("sign_in", "b.users[proof]", remoteUser, [{
    id: derived(remoteId, "B's identity row for A's identifier"),
    email: exact(null),
    email_verified: exact(null),
    admission: exact("remote", "open"),
    display_name: exact(null),
    namespace: exact(null),
    personal_athanor_id: exact(null),
    status: exact("active"),
    prefs: exact("{}"),
    first_seen_at: during(signedIn),
    last_seen_at: during(run),
    denied_at: exact(null),
    security_generation: exact(1),
    created_at: during(signedIn),
    updated_at: during(run),
  }], { stored: cyfrStore("b", "users"), what: "B's person for A's identifier, admitted remote" });
  await check("sign_in", "b.sessions[proof]", cyfrRows("b", "sessions", "user_id", remoteId), [{
    id: shaped(CYFR_ID, "a CYFR id"),
    token_hash: nbytes(32, "a SHA-256 digest: 32 bytes"),
    token_prefix: shaped(/^[A-Za-z0-9_-]{8}$/, "the session token's first 8 characters"),
    user_id: derived(remoteId, "B's identity row for A's identifier"),
    email: exact(null),
    provider: exact("cyfr", "github"),
    expires_at: later(signedIn, "after the sign-in"),
    athanor_id: exact(null),
    identity_key_epoch: derived(keyEpoch, "the key epoch the registry read at dir.test"),
    cli_machine: exact(null),
    inserted_at: during(signedIn),
  }], { stored: cyfrStore("b", "sessions"), what: "B's session for the person, bound to A's identifier's key epoch" });

  // 5. A second identity publishes A's address under @other; signing in
  // at B as @other is refused wrong_identity.
  const other = await ask({ op: "other_identity", handle: OTHER, address: A });
  record.other = { identifier: other.identifier, steps: other.steps.map((s) => ({ op: s.op, status: s.status })) };
  const otherHeld = row("wrong_identity",
    isDeepStrictEqual(record.other.steps, [
      { op: "genesis", status: 200 }, { op: "legal_version", status: 200 }, { op: "policy.accept", status: 201 },
      { op: "handle.claim", status: 201 }, { op: "address.set", status: 200 },
    ]) && PER.test(other.identifier) && other.identifier !== identifier,
    "a second identity enrolls at dir.test, claims @other and publishes A's address with it", record.other);
  if (!otherHeld) return;
  await check("wrong_identity", "handle_answer[other]", handleAnswer(OTHER), {
    status: exact(200),
    protocol: exact("cyfr-handle/v1"),
    registry: exact(REGISTRY),
    handle: exact(OTHER),
    identifier: derived(other.identifier, "the second identity's genesis"),
    directory: exact(DIRECTORY),
    address: exact(A),
  }, {
    stored: viaNamespace(OTHER),
    via: {
      status: null, protocol: null, registry: null, directory: null,
      handle: "slug", identifier: "owner_identifier", address: "address",
      value: (field) => ({ slug: `${OTHER}x`, owner_identifier: `per_${"1".repeat(64)}`, address: B })[field],
      original: (field) => ({ slug: OTHER, owner_identifier: other.identifier, address: A })[field],
    },
    what: "the registry's answer for @other: the second identity, and A's address",
  });
  const bUsersBefore = await cyfrRows("b", "users")();
  const bSessionsBefore = await cyfrRows("b", "sessions")();
  await person.goto(`${B}/login`);
  await connected(person);
  await person.locator("#cyfr-own-open").click();
  await person.locator("#cyfr-own-entry").fill(`@${OTHER}`);
  await person.locator('#cyfr-own button[type="submit"]').click();
  await person.waitForURL((url) => url.origin === A && ["/carry", "/login"].includes(url.pathname), { timeout: 60_000 });
  await connected(person);
  record.other_carry_began_signed_in = new URL(person.url()).pathname === "/carry";
  if (!record.other_carry_began_signed_in) {
    await ready(person);
    await person.locator("#passkey-sign-in [data-webauthn-start]").click();
    await person.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
    await connected(person);
    await counted();
  }
  await person.waitForFunction((b) => document.getElementById("carry-destination")?.value === b, B, { timeout: 30_000 });
  await person.locator('#carry-begin button[type="submit"]').click();
  await person.waitForURL((url) => url.origin === B && url.pathname === "/login", { timeout: 60_000 });
  await person.waitForSelector('[data-test="sign-in-error"]', { timeout: 60_000 });
  const refusedText = (await person.locator('[data-test="sign-in-error"]').innerText()).trim();
  const wrongIdentity = await ask({ op: "refusal", cell: "b", reason: "wrong_identity" });
  const sentenceModel = { shown: exact(wrongIdentity.sentence), shared_with: exact([]) };
  record.wrong_identity = { shown: refusedText, refusal: wrongIdentity };
  await check("wrong_identity", "b.sign_in_error", async () => ({ shown: refusedText, shared_with: wrongIdentity.shared_with }), sentenceModel,
    { what: "B's sign-in page shows wrong_identity's sentence, which no other sign-in refusal shares" });
  const notWrongIdentity = mismatches({ shown: (await ask({ op: "refusal", cell: "b", reason: "wrong_destination" })).sentence, shared_with: [] }, sentenceModel);
  row("wrong_identity", notWrongIdentity.length === 1 && notWrongIdentity[0].field === ".shown",
    "the same check fails on wrong_destination's sentence", { mismatches: notWrongIdentity });
  const unchanged = (rowsBefore) => rowsBefore.map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) =>
    [k, ["last_seen_at", "updated_at"].includes(k) && v !== null
      ? bound("not before the value read before the attempt", (now) => msOf(now) >= msOf(v), LONG_AGO)
      : exact(v, undefined, "the value read before the attempt")])));
  await check("wrong_identity", "b.users", cyfrRows("b", "users"), unchanged(bUsersBefore),
    { stored: cyfrStore("b", "users"), what: "B's people are the two it held before: nobody was admitted" });
  await check("wrong_identity", "b.sessions", cyfrRows("b", "sessions"), unchanged(bSessionsBefore),
    { stored: cyfrStore("b", "sessions"), what: "B's sessions are those it held before: no session was made" });

  // 6. registry.sync at A under the passkey stores a push token; the
  // registry bans the identifier; the token is refused there, and A's
  // next sync answers banned.
  const registryPage = `${A}/a/${encodeURIComponent(segment)}/registry`;
  await desk.goto(registryPage);
  await connected(desk);
  await desk.locator("button", { hasText: "Sync push tokens" }).click();
  await confirmHere(desk);
  await desk.waitForFunction(() => document.body.innerText.includes("Your push tokens are synced."), null, { timeout: 60_000 });
  const synced = window("the run up to the sync");
  row("sync", true, "Sync push tokens at A, confirmed with the passkey, answers synced", { flash: await flash(desk) });

  const tokens = await registryRows("push_tokens", "namespace_slug", HANDLE)();
  const aTokens = await cyfrRows("a", "registry_tokens")();
  const credential = async () => (await ask({ op: "credential", user_id: aUserId, registry: OCI, slug: HANDLE })).credential;
  const held1 = await credential().catch(() => null);
  await check("sync", "a.registry_tokens", cyfrRows("a", "registry_tokens"), [{
    id: shaped(CYFR_ID, "a CYFR id"),
    user_id: derived(aUserId, "A's person"),
    registry: exact(OCI, undefined, "`\"registry.registry.test\"`: the OCI host, registry. before CYFR_REGISTRY_URL"),
    namespace_slug: exact(HANDLE),
    credential_ciphertext: somebytes("sealed credential: more than 32 bytes"),
    issued_at: during(synced),
    inserted_at: during(synced),
    updated_at: during(synced),
  }], { stored: cyfrStore("a", "registry_tokens"), what: "A stores one push token, for @proof at registry.test" });
  await check("sync", "a.registry_tokens.credential", credential, {
    type: exact("push_token"),
    token: derived({ sha256: (bytesOf(tokens[0]?.token_hash) ?? Buffer.from(String(tokens[0]?.token_hash ?? "").replace(/^\\x/, ""), "hex")).toString("hex") }, "the registry's token_hash for the one @proof token"),
    namespace: exact(HANDLE),
    role: exact("personal"),
    issued_at: derived(held1 && aTokens[0] ? aTokens[0].issued_at.replace(" ", "T") : null, "the row's issued_at"),
    label: derived(tokens[0]?.label, "the registry's label for that token"),
  }, {
    stored: async (i, field, value) => cyfrStore("a", "registry_tokens")(0, "credential_ciphertext", value, aTokens[0]),
    via: {
      type: "credential_ciphertext", token: "credential_ciphertext", namespace: "credential_ciphertext",
      role: "credential_ciphertext", issued_at: "credential_ciphertext", label: "credential_ciphertext",
      value: () => tampered(somebytes(""), aTokens[0].credential_ciphertext),
      original: () => aTokens[0].credential_ciphertext,
    },
    what: "the sealed credential: a push token whose digest is the registry's",
  });
  await check("sync", "registry.push_tokens[proof]", registryRows("push_tokens", "namespace_slug", HANDLE), [{
    id: uuid("an id"),
    token_hash: derived(tokens[0]?.token_hash, "the digest of the token A sealed (a.registry_tokens.credential)"),
    namespace_slug: exact(HANDLE),
    label: derived(held1?.label, "the label A sealed with the token"),
    created_at: during(synced),
    last_used_at: during(synced),
    revoked_at: noTime(),
    created_by: derived(identifier, "A's identifier"),
    recovery_epoch: derived(recoveryEpoch, "the recovery epoch the registry read at dir.test"),
  }], { stored: registryStore("push_tokens", "id"), what: "the registry holds one live token for @proof, made by A's identifier" });

  const ban = await ask({ op: "ban", handle: HANDLE });
  const banned = window("the sync's end to the ban's answer", synced.to);
  row("ban", ban.status === 303, "the registry's operator bans @proof's owner", { status: ban.status });
  await check("ban", "registry.banned_identities", registryRows("banned_identities", "identifier", identifier), [{
    id: uuid("an id"),
    banned_at: during(banned),
    banned_by: uuid("the operator account's id"),
    reason: exact("handle proof"),
    category: exact("spam", "other"),
    expires_at: noTime(),
    appeal_allowed_after: noTime(),
    related_report_ids: exact([]),
    identifier: derived(identifier, "A's identifier"),
    former_identity: exact(null),
  }], { stored: registryStore("banned_identities", "id"), what: "the ban names A's identifier" });
  await check("ban", "registry.push_tokens[proof]", registryRows("push_tokens", "namespace_slug", HANDLE), [{
    id: derived(tokens[0]?.id, "the token the sync minted"),
    token_hash: derived(tokens[0]?.token_hash, "the token the sync minted"),
    namespace_slug: exact(HANDLE),
    label: derived(held1?.label, "the label A sealed with the token"),
    created_at: derived(tokens[0]?.created_at, "the token the sync minted"),
    last_used_at: derived(tokens[0]?.last_used_at, "the token the sync minted, as the sync left it"),
    revoked_at: during(banned),
    created_by: derived(identifier, "A's identifier"),
    recovery_epoch: derived(recoveryEpoch, "the recovery epoch the registry read at dir.test"),
  }], { stored: registryStore("push_tokens", "id"), what: "the ban revoked the token in its transaction" });
  const revokedAt = (await registryRows("push_tokens", "namespace_slug", HANDLE)())[0]?.revoked_at;
  const tokenUse = async () => {
    const { status, body } = await ask({ op: "token_use", user_id: aUserId, registry: OCI, slug: HANDLE });
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      parsed = body;
    }
    return { status, body: parsed };
  };
  await check("ban", "token_refused", tokenUse, {
    status: exact(401),
    body: exact({ errors: [{ code: "UNAUTHORIZED", message: "token revoked" }] }),
  }, {
    stored: async (i, field, value, rowNow, phase) => registryStore("push_tokens", "id")(0, "revoked_at", value, tokens[0], phase),
    via: {
      status: "revoked_at", body: "revoked_at",
      value: () => null,
      original: () => revokedAt,
    },
    what: "A's stored token, presented to the registry, is refused",
  });

  await desk.goto(registryPage);
  await connected(desk);
  await desk.locator("button", { hasText: "Sync push tokens" }).click();
  const outcome = await Promise.race([
    desk.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"] [data-test="confirm-passkey"]`, { timeout: 60_000 }).then(() => "confirm"),
    desk.waitForFunction(() => document.body.innerText.includes("Sync failed"), null, { timeout: 60_000 }).then(() => "answered"),
  ]);
  if (outcome === "confirm") await confirmHere(desk);
  await desk.waitForFunction(() => document.body.innerText.includes("Sync failed"), null, { timeout: 60_000 });
  // The flash's message alone, without its close control.
  const failedText = ((await desk.locator("#flash-error span").allInnerTexts()).map((t) => t.trim()).find((t) => t.includes("Sync failed"))) ?? "";
  const bannedRefusal = await ask({ op: "refusal", cell: "a", reason: "banned" });
  record.banned_sync = { shown: failedText, refusal: bannedRefusal, asked_confirmation: outcome === "confirm" };
  const bannedModel = { shown: exact(`Sync failed: ${bannedRefusal.sentence}`), shared_with: exact([]) };
  await check("ban", "a.sync_refused", async () => ({ shown: failedText, shared_with: bannedRefusal.shared_with }), bannedModel,
    { what: "A's next sync answers banned's sentence" });
  const notBanned = mismatches({ shown: `Sync failed: ${(await ask({ op: "refusal", cell: "a", reason: "registry_unavailable" })).sentence}`, shared_with: [] }, bannedModel);
  row("ban", notBanned.length === 1 && notBanned[0].field === ".shown", "the same check fails on registry_unavailable's sentence", { mismatches: notBanned });
  record.after_ban = { a_registry_tokens: await cyfrRows("a", "registry_tokens")() };
}

// ---------------------------------------------------------------------------

let proxy;
try {
  proxy = await startProxy({ homes });
} catch (error) {
  console.error(`FAIL: ${error.message.split("\n")[0]}`);
  process.exit(1);
}

let failure = null;
let chromium;
try {
  chromium = await launchBrowser("chromium", proxy);
  await main(chromium);
} catch (error) {
  failure = redact(error.stack || String(error));
  console.error(`FAIL: ${failure}`);
  await dumpPages().catch(() => null);
} finally {
  await chromium?.close().catch(() => null);
  proxy.close();
}

const STEPS = ["setup", "publish", "allow", "sign_in", "wrong_identity", "sync", "ban"];
const outcome = (step) => {
  const found = rows.filter((r) => r.step === step);
  if (!found.length) return "not reached";
  return found.every((r) => r.held) ? "held" : "FAILED";
};
writeFileSync(join(outDir, "handle-proof.json"), redact(JSON.stringify({ versions: record.versions, rows, record, failure }, null, 2)));
const header = ["| object | field | class | value, source or bound |", "|---|---|---|---|"];
const tableText = [...header, ...table].join("\n");
writeFileSync(join(outDir, "handle-proof-fields.md"), `${tableText}\n`);
let readmeHolds = false;
try {
  readmeHolds = !failure && readFileSync(new URL("./README.md", import.meta.url), "utf8").includes(tableText);
} catch {
  readmeHolds = false;
}
if (!failure && rows.length) row("readme", readmeHolds, "README.md's field table is the one the models print", {});
const summary = ["| step | outcome |", "|---|---|", ...[...STEPS, "readme"].map((step) => `| ${step} | ${outcome(step)} |`)];
writeFileSync(join(outDir, "handle-proof.md"), `${summary.join("\n")}\n`);
console.log(summary.join("\n"));
if (failure || [...STEPS, "readme"].some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the handle proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
