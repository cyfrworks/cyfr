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
// and holds it to its model (models.mjs), built from what the run
// captured: the browsers' credentials and cookies, the clock readings
// around each step, and each generated value at its first read. Every
// stored field is then shown failing behind the browsers' back (models.mjs
// `check`). At the end every object is read again and held to what was
// read before. The README's field table is the one these models print.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ask as askRunSh, launchBrowser, readHomes, redact as redactKnown, saveKit, startProxy, waitFor,
} from "../browser/lib.mjs";
import {
  HANDLE, LONG_AGO, OCI, OTHER, PER, bytesFrom, check, classification, coseTerm, objectModels, otherId, sha256hex,
} from "./models.mjs";

const [homesFile, outDir] = process.argv.slice(2);
const { homes } = readHomes(homesFile);
const originOf = (name) => homes.find((home) => home.name === name).origin;
const A = originOf("a");
const B = originOf("b");
const DIRECTORY = "https://dir.test";
const layer = "#system-layer-dialog";

const secrets = [];
const redact = (text) => redactKnown(text, secrets);
const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });
const clock = () => Date.now();

// What the run captured, which the models are built from (the record's
// `seen`): origins, clock windows, read times, first reads, credentials'
// public parts, cookies' digests, the second identity, refusal sentences.
const S = {
  origins: { a: A, b: B }, w: {}, at: {}, rows: {}, credentials: {}, cookies: {}, opens: {}, refusals: {}, genesis: {},
};
const rows = [];
const record = { objects: {}, checks: {} };
const table = [];
const tally = { loops: 0, skipped: [], controls: 0 };
const contexts = [];
// Every tamper loop that ran, by store, row key and field (models.mjs check).
const ran = new Map();

function row(step, held, what, detail) {
  rows.push({ step, held, what, detail });
  console.log(`${held ? "ok" : "FAIL"}: ${step}: ${what}`);
  return held;
}

// The window `name` from `from` to now, kept in `S`.
function windowed(name, from, says) {
  S.w[name] = { name: says, from, to: clock() };
  return S.w[name];
}

// One claimed object: read whole, its model built, compared, each stored
// field shown failing. `io.prepare(object)` checks a relationship the
// model needs before it is built.
async function claim(key, what, read, io = {}) {
  const step = key.startsWith("held:") ? "ban" : key.split(":")[0];
  let object;
  try {
    object = await read();
  } catch (error) {
    return row(step, false, `${what}: the read failed`, { error: String(error.message) });
  }
  S.at[key] = clock();
  if (Array.isArray(object)) S.rows[key] = object;
  if (io.prepare) await io.prepare(object);
  record.objects[key] = object;
  let model;
  try {
    model = objectModels(S)[key]();
  } catch (error) {
    return row(step, false, `${what}: no model (${error.message})`, { object });
  }
  table.push(...classification(key, model));
  let result;
  try {
    result = await check(object, model, { read, ran, at: key, ...io });
  } catch (error) {
    return row(step, false, `${what}: ${error.message}`, {});
  }
  record.checks[key] = result;
  tally.loops += result.loops.length;
  tally.controls += result.controls.length;
  tally.skipped.push(...result.skipped.map((s) => ({ object: key, ...s })));
  if (result.mismatches.length) return row(step, false, `${what} is the model's`, { mismatches: result.mismatches });
  if (result.failures.length) return row(step, false, `${what}: ${result.failures[0]}`, { failures: result.failures, loop: result.loops.at(-1) });
  return row(step, true, `${what} is the model's${result.loops.length ? `, and each of the ${result.loops.length} stored fields written behind its back fails it` : ""}${result.controls.length ? `; its ${result.controls.length} controls are refused` : ""}`,
    { loops: result.loops.length, skipped: result.skipped.length, controls: result.controls.length });
}

// The stores: a CYFR's table, the registry's table.
// A read filtered by `column` names it (`filter`): a tamper of that column
// is refused by the row leaving the read.
const filtered = (read, column) => Object.assign(read, { filter: column || null });
const cyfrRows = (cell, tableName, column = "", value = "") => filtered(async () =>
  (await ask({ op: "rows", cell, table: tableName, column, value })).rows, column);
const cyfrIo = (cell, tableName) => ({
  identity: { store: `${cell}.${tableName}`, key: (row) => row.id },
  write: async (i, field, value, rowNow) => {
    const answer = await ask({ op: "set", cell, table: tableName, id: rowNow.id, field, value });
    if (answer.set !== 1) throw new Error(`${cell}.${tableName}.${field}: the write changed ${JSON.stringify(answer)}`);
    return answer;
  },
  state: async () => ask({ op: "state", cell, table: tableName }),
});
const registryRows = (tableName, column = "", value = "") => filtered(async () =>
  (await ask({ op: "registry_rows", table: tableName, column, value })).rows, column);
const registryWrite = async (tableName, key, keyValue, field, value, phase) => {
  const answer = await ask({ op: "registry_set", table: tableName, key, key_value: String(keyValue), field, value, phase });
  if (answer.set !== 1) throw new Error(`registry ${tableName}.${field}: the write changed ${JSON.stringify(answer)}`);
  return answer;
};
const registryIo = (tableName, key) => ({
  identity: { store: `registry.${tableName}`, key: (row) => row[key] },
  write: (i, field, value, rowNow, phase) => registryWrite(tableName, key, rowNow[key], field, value, phase),
  state: async () => ask({ op: "registry_state", table: tableName }),
});
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
// A handle answer's fields, each through the namespace row's field that
// makes it (`status` by reserving the namespace, cyfr.run
// internal/api/handles.go:31); protocol, registry and directory by
// controls.
const answerIo = (handle, owner, address) => ({
  via: {
    status: { target: "reserved", value: true, original: false },
    handle: { none: "the handle asked for, echoed: shown failing by a control" },
    identifier: { target: "owner_identifier", value: otherId(owner), original: owner },
    ...(address ? { address: { target: "address", value: `${address}:8443`, original: address } } : {}),
    protocol: { none: "the wire's constant: shown failing by a control" },
    registry: { none: "the registry's configured host: shown failing by a control" },
    directory: { none: "the registry's configured directory: shown failing by a control" },
  },
  write: (i, field, value, rowNow, phase) => registryWrite("namespaces", "slug", rowNow.slug ?? handle, field, value, phase),
  state: async () => ask({ op: "registry_state", table: "namespaces" }),
  controls: [
    { field: ".handle", says: "another handle", corrupt: (o) => ({ ...o, handle: `${handle}x` }) },
    { field: ".protocol", says: "cyfr-handle/v2", corrupt: (o) => ({ ...o, protocol: "cyfr-handle/v2" }) },
    { field: ".registry", says: "another registry", corrupt: (o) => ({ ...o, registry: "elsewhere.test" }) },
    { field: ".directory", says: "another directory", corrupt: (o) => ({ ...o, directory: "https://dir2.test" }) },
  ],
});

// ---------------------------------------------------------------------------
// Browsers and the virtual authenticator (as tests/join-proof/common.mjs)
// ---------------------------------------------------------------------------

const authenticators = new Map();
const highest = new Map();
const heldCredentials = async (handle) => (await handle.cdp.send("WebAuthn.getCredentials", { authenticatorId: handle.id })).credentials;
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
      for (const credential of await heldCredentials(handle)) highest.set(credential.credentialId, highestOf(credential));
    } catch {
      authenticators.delete(page);
    }
  }
}

async function ready(page) {
  await counted();
  const handle = authenticators.get(page);
  if (!handle) return;
  for (const credential of await heldCredentials(handle)) {
    const count = highestOf(credential);
    if (count === credential.signCount) continue;
    await handle.cdp.send("WebAuthn.removeCredential", { authenticatorId: handle.id, credentialId: credential.credentialId });
    await handle.cdp.send("WebAuthn.addCredential", { authenticatorId: handle.id, credential: { ...credential, signCount: count } });
  }
}

// The credential the page's authenticator holds for `host`, with the
// highest count any copy reached.
async function credentialFor(page, host) {
  await counted();
  const [credential] = (await heldCredentials(authenticators.get(page))).filter((c) => c.rpId === host);
  return { ...credential, signCount: highestOf(credential) };
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

// The public half of the sealed key `column` of `rowNow`, opened in `cell`
// as the person's `role` key, kept in `S` as `prefix.role`.
async function opens(cell, prefix, rowNow, column, role) {
  const answer = await ask({ op: "opens", cell, user_id: rowNow?.user_id, role, sealed: rowNow?.[column] }, { refuseError: false });
  S.opens[`${prefix}.${role}`] = answer.opens ? answer.public : null;
}

// The digest of the session token the context's cookie for `origin`
// carries, read inside the CYFR that set it; the cookie itself is
// redacted from everything the proof writes.
async function cookieDigest(context, origin, cell) {
  const cookie = (await context.cookies(origin)).find((c) => c.name === "_cyfr_key")?.value;
  if (!cookie) return null;
  secrets.push(cookie);
  return ask({ op: "session_digest", cell, cookie }, { secret: true });
}

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

// "I run my own CYFR" at B with `handle`, to A's /carry, signing in at A
// with the passkey when the browser holds no session there, then Begin,
// back to B's sign-in page.
async function carryFrom(person, handle) {
  await person.goto(`${B}/login`);
  await connected(person);
  await person.locator("#cyfr-own-open").click();
  await person.locator("#cyfr-own-entry").fill(`@${handle}`);
  await person.locator('#cyfr-own button[type="submit"]').click();
  await person.waitForURL((url) => url.origin === A && ["/carry", "/login"].includes(url.pathname), { timeout: 60_000 });
  await connected(person);
  if (new URL(person.url()).pathname === "/login") {
    await ready(person);
    await person.locator("#passkey-sign-in [data-webauthn-start]").click();
    await person.waitForURL((url) => url.origin === A && url.pathname === "/carry", { timeout: 60_000 });
    await connected(person);
    await counted();
  }
  await person.waitForFunction((b) => document.getElementById("carry-destination")?.value === b, B, { timeout: 30_000 });
  await person.locator('#carry-begin button[type="submit"]').click();
  await person.waitForURL((url) => url.origin === B && url.pathname === "/login", { timeout: 60_000 });
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function main(chromium) {
  record.versions = { chromium: chromium.version() };
  S.policyVersion = (await ask({ op: "legal_version" })).policy_version;
  S.ttlHours = Number((await ask({ op: "setting", cell: "b", key: "session_ttl_hours" })).value);
  S.clients = await ask({ op: "user_agents" });

  // 1. Setup at A: a passkey, @proof, enrollment at dir.test, the kit
  // acknowledged, and only then the claim at the registry.
  const deskContext = await freshContext(chromium);
  const desk = await deskContext.newPage();
  await authenticatorWith(desk);
  let from = clock();
  await setUp(desk, A, "a");
  windowed("setup", from, "setup at A");
  const aCredential = await credentialFor(desk, "a.test");
  S.credentials.a = { credentialId: aCredential.credentialId, signCount: aCredential.signCount, cose: coseTerm(aCredential.privateKey) };
  await claim("setup:a.passkeys", "A's one passkey, the one the browser's authenticator holds", cyfrRows("a", "passkeys"), cyfrIo("a", "passkeys"));

  from = clock();
  await desk.locator('[data-test="identity-handle-input"]').fill(HANDLE);
  await desk.waitForSelector('[data-test="identity-handle-check"][data-check="free"]', { timeout: 60_000 });
  await desk.locator('[data-test="identity-choose"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="enrollment"]`, { timeout: 60_000 });
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  const enrollPreview = await confirmHere(desk);
  const kit = await readKit(desk);
  windowed("enroll", from, "the enrollment, to the kit shown");
  const id = kit.identifier;
  S.identifier = id;
  record.setup = { identifier: id, kit_directory: kit.directory_url, enroll_preview: enrollPreview };
  if (!row("setup", PER.test(id) && kit.directory_url === DIRECTORY,
    "A is set up through /setup with a passkey; @proof chosen, the enrollment at dir.test confirmed with it, the kit shown", record.setup)) return;

  // Before the acknowledgement: the directory holds the genesis, the
  // attempt is accepted, and the registry holds nothing of the person.
  await claim("setup:dir.identity_log_entries", "the directory's one entry: A's genesis, whose hash is the identifier", cyfrRows("dir", "identity_log_entries"), {
    ...cyfrIo("dir", "identity_log_entries"),
    prepare: async (entries) => {
      const entry = bytesFrom(entries[0]?.entry);
      S.genesis.a = entry && sha256hex(entry) === id.slice(4) ? entry.toString("base64") : "";
    },
  });
  await claim("setup:pre:a.identity_attempts", "A's enrollment attempt, accepted, its kit not yet acknowledged", cyfrRows("a", "identity_attempts"), cyfrIo("a", "identity_attempts"));
  await claim("setup:pre:registry.namespaces[proof]", "the registry holds no @proof before the kit's acknowledgement", registryRows("namespaces", "slug", HANDLE), registryIo("namespaces", "slug"));
  await claim("setup:pre:registry.policy_acceptances[a]", "nor an acceptance by A's identifier", registryRows("policy_acceptances", "identifier", id), registryIo("policy_acceptances", "id"));
  await claim("setup:pre:registry.request_nonces[a]", "nor a request A's identifier signed", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));

  from = clock();
  await saveKit(desk);
  await desk.waitForSelector('[data-test="identity-claimed"]', { timeout: 120_000 });
  windowed("ack", from, "the kit's acknowledgement, to @proof claimed");
  const claimedText = await desk.locator('[data-test="identity-claimed"]').innerText();
  row("setup", claimedText.includes(`@${HANDLE}`), "once the kit is acknowledged, the card claims @proof", { claimed: claimedText });

  await claim("setup:a.identity_attempts", "the attempt after the acknowledgement: the transition from the attempt read before it", cyfrRows("a", "identity_attempts"), cyfrIo("a", "identity_attempts"));
  await claim("setup:a.athanors", "A's one athanor, its person's", cyfrRows("a", "athanors"), cyfrIo("a", "athanors"));
  await claim("setup:a.memberships", "A's seats: the person's in their athanor, and the first person's platform grant", cyfrRows("a", "memberships"), cyfrIo("a", "memberships"));
  await claim("setup:a.users", "A's one person, admitted by setup, holding @proof", cyfrRows("a", "users"), cyfrIo("a", "users"));
  await claim("setup:a.person_identities", "A's identity: the kit's identifier, enrolled at dir.test, keys that open to the genesis's", cyfrRows("a", "person_identities"), {
    ...cyfrIo("a", "person_identities"),
    prepare: async ([identity]) => {
      await opens("a", "identity", identity, "live_key_sealed", "live");
      await opens("a", "identity", identity, "operational_key_sealed", "operational");
    },
  });
  await claim("setup:registry.namespaces[proof]", "the registry's @proof: personal, owned by A's identifier, no address", registryRows("namespaces", "slug", HANDLE), registryIo("namespaces", "slug"));
  await claim("setup:registry.identity_heads[a]", "the registry's read of A's log at dir.test", registryRows("identity_heads", "identifier", id), registryIo("identity_heads", "identifier"));
  await claim("setup:registry.policy_acceptances[a]", "A's identifier's acceptance of the registry's policy", registryRows("policy_acceptances", "identifier", id), registryIo("policy_acceptances", "id"));
  await claim("setup:registry.request_nonces[a]", "the nonces of A's two signed requests, the acceptance and the claim", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));
  await claim("setup:handle_answer[proof]", "the registry's answer for @proof: A's identifier and directory, no address", handleAnswer(HANDLE), answerIo(HANDLE, id, null));

  // 2. Publication of A's address from Settings.
  const segment = await continueToCyfr(desk, A);
  await desk.goto(`${A}/a/${encodeURIComponent(segment)}/settings`);
  await connected(desk);
  await desk.waitForSelector('[data-test="identity-publish"][data-published="false"]', { timeout: 60_000 });
  from = clock();
  await desk.locator('[data-test="identity-publish"] button').click();
  await desk.waitForSelector('[data-test="identity-publish"][data-published="true"]', { timeout: 60_000 });
  windowed("publish", from, "the publication");
  row("publish", true, "Settings at A publishes A's address with @proof", {});
  await claim("publish:registry.namespaces[proof]", "the registry's @proof now holds A's address, created as it was", registryRows("namespaces", "slug", HANDLE), registryIo("namespaces", "slug"));
  await claim("publish:handle_answer[proof]", "the registry's answer for @proof publishes A's address", handleAnswer(HANDLE), answerIo(HANDLE, id, A));
  await claim("publish:registry.request_nonces[a]", "the nonces: setup's two held, and the publication's", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));
  await claim("publish:registry.identity_heads[a]", "the registry's read of A's log, refreshed by the signed request", registryRows("identity_heads", "identifier", id), registryIo("identity_heads", "identifier"));

  // 3. B's administrator, set up through /setup, allows @proof.
  const adminContext = await freshContext(chromium);
  const admin = await adminContext.newPage();
  await authenticatorWith(admin);
  from = clock();
  await setUp(admin, B, "b");
  const bSegment = await continueToCyfr(admin, B);
  windowed("admin", from, "setup at B");
  const bCredential = await credentialFor(admin, "b.test");
  S.credentials.b = { credentialId: bCredential.credentialId, signCount: bCredential.signCount, cose: coseTerm(bCredential.privateKey) };
  S.cookies.admin = await cookieDigest(adminContext, B, "b");
  await admin.goto(`${B}/a/${encodeURIComponent(bSegment)}/settings`);
  await connected(admin);
  const entry = admin.locator('#door-entry-form input[name="value"]');
  await entry.fill(`@${HANDLE}`);
  const allow = admin.locator("#door-entry-form button", { hasText: "Allow" });
  await waitFor(async () => (await allow.getAttribute("phx-value-door")) === `@${HANDLE}`, { timeoutMs: 30_000, what: "the door form taking @proof" });
  from = clock();
  await allow.click();
  await admin.waitForSelector('[data-test="door-entry-label"]', { timeout: 60_000 });
  windowed("allow", from, "the allow");
  row("allow", true, "B's administrator, set up through /setup, allows @proof in Settings", { flash: await flash(admin) });
  await claim("allow:b.passkeys", "B's one passkey, the administrator's", cyfrRows("b", "passkeys"), cyfrIo("b", "passkeys"));
  await claim("allow:b.athanors", "B's one athanor, the administrator's", cyfrRows("b", "athanors"), cyfrIo("b", "athanors"));
  await claim("allow:b.memberships", "B's seats: the administrator's, and the platform grant", cyfrRows("b", "memberships"), cyfrIo("b", "memberships"));
  await claim("allow:b.users", "B's one person, its administrator", cyfrRows("b", "users"), cyfrIo("b", "users"));
  await claim("allow:b.server_allowlist", "B's allowlist: one entry, A's identifier, labelled @proof", cyfrRows("b", "server_allowlist"), cyfrIo("b", "server_allowlist"));

  // 4. At B, "I run my own CYFR" with @proof: A through the published
  // address, and the carry admits the person as A's identifier.
  const personContext = await freshContext(chromium);
  const person = await personContext.newPage();
  await authenticatorWith(person, [await credentialFor(desk, "a.test")]);
  from = clock();
  await carryFrom(person, HANDLE);
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
  windowed("signin", from, "the sign-in at B");
  const landedText = await person.locator("body").innerText();
  record.sign_in = {
    code, code_named_at_a: confirmation.includes(code), landed: person.url().replace(/#.*/, ""),
    says_signed_in: landedText.includes("You're signed in, but you have no athanor here yet."),
  };
  row("sign_in", record.sign_in.code_named_at_a && record.sign_in.landed === `${B}/login?error=no_athanor` && record.sign_in.says_signed_in,
    "at B, @proof leads through the published address to A, A's confirmation names B's code, and B admits the person, with no seat there", record.sign_in);
  S.cookies.remote = await cookieDigest(personContext, B, "b");
  await claim("sign_in:b.person_identities", "B's identities: its administrator's, and A's identifier as a remote person under A's genesis", cyfrRows("b", "person_identities"), {
    ...cyfrIo("b", "person_identities"),
    prepare: async (identities) => {
      const own = identities.find((r) => r.provenance === "local");
      await opens("b", "b.identity", own, "live_key_sealed", "live");
      await opens("b", "b.identity", own, "operational_key_sealed", "operational");
    },
  });
  await claim("sign_in:b.users", "B's people: its administrator, and the person admitted remote", cyfrRows("b", "users"), cyfrIo("b", "users"));
  const remoteId = S.rows["sign_in:b.person_identities"]?.find((r) => r.identifier === id)?.user_id ?? "";
  await claim("sign_in:b.sessions[proof]", "the person's session at B: the browser's cookie's token, bound to the genesis's key epoch", cyfrRows("b", "sessions", "user_id", remoteId), cyfrIo("b", "sessions"));
  await claim("sign_in:b.athanors", "B's athanors are only its administrator's: the admission made none", cyfrRows("b", "athanors"), cyfrIo("b", "athanors"));
  await claim("sign_in:b.memberships", "B's seats are only its administrator's: the admission made none", cyfrRows("b", "memberships"), cyfrIo("b", "memberships"));

  // 5. A second identity publishes A's address under @other; signing in at
  // B as @other is refused wrong_identity.
  from = clock();
  const other = await ask({ op: "other_identity", handle: OTHER, address: A });
  windowed("other", from, "the second identity's requests");
  S.other = other.identifier;
  S.userAgents = { [id]: S.clients.cyfr, [other.identifier]: S.clients.curl };
  S.genesis.c = other.genesis;
  record.other = { identifier: other.identifier, steps: other.steps.map((s) => ({ op: s.op, status: s.status })) };
  const otherSteps = [
    { op: "genesis", status: 200 }, { op: "legal_version", status: 200 }, { op: "policy.accept", status: 201 },
    { op: "handle.claim", status: 201 }, { op: "address.set", status: 200 },
  ];
  if (!row("wrong_identity", JSON.stringify(record.other.steps) === JSON.stringify(otherSteps) && PER.test(other.identifier) && other.identifier !== id,
    "a second identity enrolls at dir.test, claims @other and publishes A's address with it", record.other)) return;
  await claim("wrong_identity:dir.identity_log_entries", "the directory's entries: A's genesis as before, and the second identity's as it sent it", cyfrRows("dir", "identity_log_entries"), cyfrIo("dir", "identity_log_entries"));
  await claim("wrong_identity:registry.namespaces[other]", "the registry's @other: owned by the second identity, A's address", registryRows("namespaces", "slug", OTHER), registryIo("namespaces", "slug"));
  await claim("wrong_identity:registry.identity_heads[c]", "the registry's read of the second identity's log", registryRows("identity_heads", "identifier", other.identifier), registryIo("identity_heads", "identifier"));
  await claim("wrong_identity:registry.policy_acceptances[c]", "the second identity's acceptance", registryRows("policy_acceptances", "identifier", other.identifier), registryIo("policy_acceptances", "id"));
  await claim("wrong_identity:registry.request_nonces[c]", "the nonces of the second identity's three signed requests", registryRows("request_nonces", "identifier", other.identifier), registryIo("request_nonces", "nonce"));
  await claim("wrong_identity:handle_answer[other]", "the registry's answer for @other: the second identity, and A's address", handleAnswer(OTHER), answerIo(OTHER, other.identifier, A));
  await claim("wrong_identity:pre:b.sessions", "B's sessions before the attempt: the administrator's, its cookie's token, and the person's", cyfrRows("b", "sessions"), cyfrIo("b", "sessions"));

  from = clock();
  await carryFrom(person, OTHER);
  await person.waitForSelector('[data-test="sign-in-error"]', { timeout: 60_000 });
  windowed("attempt", from, "the attempt as @other");
  const refusedText = (await person.locator('[data-test="sign-in-error"]').innerText()).trim();
  S.refusals.wrong_identity = await ask({ op: "refusal", cell: "b", reason: "wrong_identity" });
  const otherSentence = (await ask({ op: "refusal", cell: "b", reason: "wrong_destination" })).sentence;
  await claim("wrong_identity:b.sign_in_error", "B's sign-in page shows wrong_identity's sentence, distinct from every other sign-in refusal's; no wrong-destination request is made",
    async () => ({ shown: refusedText, shared_with: S.refusals.wrong_identity.shared_with }), {
      controls: [
        { field: ".shown", says: "wrong_destination's sentence", corrupt: (o) => ({ ...o, shown: otherSentence }) },
        { field: ".shared_with", says: "a refusal sharing the sentence", corrupt: (o) => ({ ...o, shared_with: ["wrong_destination"] }) },
      ],
    });
  await claim("wrong_identity:b.users", "B's people are the two it held: nobody was admitted", cyfrRows("b", "users"), cyfrIo("b", "users"));
  await claim("wrong_identity:b.sessions", "B's sessions are those it held before the attempt: none was made", cyfrRows("b", "sessions"), cyfrIo("b", "sessions"));
  await claim("wrong_identity:b.person_identities", "B's identities are the two it held", cyfrRows("b", "person_identities"), cyfrIo("b", "person_identities"));
  await claim("wrong_identity:b.athanors", "B's athanors are its administrator's alone", cyfrRows("b", "athanors"), cyfrIo("b", "athanors"));
  await claim("wrong_identity:b.memberships", "B's seats are its administrator's alone", cyfrRows("b", "memberships"), cyfrIo("b", "memberships"));

  // 6. registry.sync at A under the passkey stores a push token; the
  // registry bans the identifier; the token is refused there, and A's
  // next sync answers banned.
  const registryPage = `${A}/a/${encodeURIComponent(segment)}/registry`;
  await desk.goto(registryPage);
  await connected(desk);
  from = clock();
  await desk.locator("button", { hasText: "Sync push tokens" }).click();
  await confirmHere(desk);
  await desk.waitForFunction(() => document.body.innerText.includes("Your push tokens are synced."), null, { timeout: 60_000 });
  windowed("sync", from, "the sync");
  row("sync", true, "Sync push tokens at A, confirmed with the passkey, answers synced", { flash: await flash(desk) });

  const aUserId = S.rows["setup:a.passkeys"]?.[0]?.user_id;
  const credential = async () => (await ask({ op: "credential", user_id: aUserId, registry: OCI, slug: HANDLE })).credential;
  const opened = await credential().catch(() => null);
  const tokenRow = (await registryRows("push_tokens", "namespace_slug", HANDLE)())[0];
  S.credentialOpened = !!opened && `\\x${opened.token?.sha256}` === tokenRow?.token_hash;
  S.credentialDigest = opened?.token?.sha256;
  S.credentialLabel = opened?.label;
  await claim("sync:registry.push_tokens[proof]", "the registry holds one live token for @proof, made by A's identifier, whose digest is the token A sealed", registryRows("push_tokens", "namespace_slug", HANDLE), registryIo("push_tokens", "id"));
  await claim("sync:a.registry_tokens", "A stores one push token, for @proof at the registry's OCI host", cyfrRows("a", "registry_tokens"), cyfrIo("a", "registry_tokens"));
  const sealedRow = S.rows["sync:a.registry_tokens"]?.[0] ?? {};
  const memberTamper = { type: "push_token~", token: "tampered", namespace: `${HANDLE}~`, role: "personal~", issued_at: LONG_AGO, label: `${opened?.label}~` };
  await claim("sync:a.registry_tokens.credential", "the sealed credential: a push token whose digest is the registry's, each member resealed alone and refused", credential, {
    via: Object.fromEntries(Object.entries(memberTamper).map(([member, value]) => [member, { target: member, value, original: sealedRow.credential_ciphertext }])),
    write: async (i, member, value, rowNow, phase) => {
      const answer = phase === "tamper"
        ? await ask({ op: "reseal", user_id: aUserId, registry: OCI, slug: HANDLE, patch: { [member]: value } })
        : await ask({ op: "set", cell: "a", table: "registry_tokens", id: sealedRow.id, field: "credential_ciphertext", value });
      if (answer.set !== 1) throw new Error(`the credential's ${member}: the write changed ${JSON.stringify(answer)}`);
      return answer;
    },
    state: async () => ask({ op: "state", cell: "a", table: "registry_tokens" }),
  });
  await claim("sync:registry.request_nonces[a]", "the nonces: the earlier three held, and the sync's", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));
  await claim("sync:registry.identity_heads[a]", "the registry's read of A's log, refreshed by the sync's request", registryRows("identity_heads", "identifier", id), registryIo("identity_heads", "identifier"));

  from = clock();
  const ban = await ask({ op: "ban", handle: HANDLE });
  windowed("ban", from, "the ban");
  S.adminId = (await ask({ op: "admin_id" })).id;
  row("ban", ban.status === 303, "the registry's operator bans @proof's owner", { status: ban.status });
  await claim("ban:registry.banned_identities", "the ban names A's identifier, by the run's operator", registryRows("banned_identities", "identifier", id), registryIo("banned_identities", "id"));
  await claim("ban:registry.push_tokens[proof]", "the ban revoked the token in its transaction", registryRows("push_tokens", "namespace_slug", HANDLE), registryIo("push_tokens", "id"));
  const revokedAt = S.rows["ban:registry.push_tokens[proof]"]?.[0]?.revoked_at;
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
  // With revoked_at cleared the token stands, and its use stamps
  // last_used_at: the restore writes that back too.
  let usedAt;
  await claim("ban:token_refused", "A's stored token, presented to the registry, is refused", tokenUse, {
    via: { status: { target: "revoked_at", value: null, original: revokedAt }, body: { target: "revoked_at", value: null, original: revokedAt } },
    write: async (i, field, value, rowNow, phase) => {
      if (phase === "tamper") usedAt = (await registryRows("push_tokens", "namespace_slug", HANDLE)())[0]?.last_used_at;
      const answer = await registryWrite("push_tokens", "id", tokenRow?.id, field, value, phase);
      if (phase === "restore") await registryWrite("push_tokens", "id", tokenRow?.id, "last_used_at", usedAt, "restore");
      return answer;
    },
    state: async () => ask({ op: "registry_state", table: "push_tokens" }),
  });

  await desk.goto(registryPage);
  await connected(desk);
  from = clock();
  await desk.locator("button", { hasText: "Sync push tokens" }).click();
  const outcome = await Promise.race([
    desk.waitForSelector(`${layer} [data-test="confirmation"][data-own="true"] [data-test="confirm-passkey"]`, { timeout: 60_000 }).then(() => "confirm"),
    desk.waitForFunction(() => document.body.innerText.includes("Sync failed"), null, { timeout: 60_000 }).then(() => "answered"),
  ]);
  if (outcome === "confirm") await confirmHere(desk);
  await desk.waitForFunction(() => document.body.innerText.includes("Sync failed"), null, { timeout: 60_000 });
  windowed("sync2", from, "the sync after the ban");
  // The flash's message alone, without its close control.
  const failedText = ((await desk.locator("#flash-error span").allInnerTexts()).map((t) => t.trim()).find((t) => t.includes("Sync failed"))) ?? "";
  S.refusals.banned = await ask({ op: "refusal", cell: "a", reason: "banned" });
  const unavailable = (await ask({ op: "refusal", cell: "a", reason: "registry_unavailable" })).sentence;
  record.banned_sync = { shown: failedText, asked_confirmation: outcome === "confirm" };
  await claim("ban:a.sync_refused", "A's next sync shows banned's sentence, which no other sync refusal shares",
    async () => ({ shown: failedText, shared_with: S.refusals.banned.shared_with }), {
      controls: [
        { field: ".shown", says: "registry_unavailable's sentence", corrupt: (o) => ({ ...o, shown: `Sync failed: ${unavailable}` }) },
        { field: ".shared_with", says: "a refusal sharing the sentence", corrupt: (o) => ({ ...o, shared_with: ["registry_unavailable"] }) },
      ],
    });
  await claim("ban:registry.request_nonces[a]", "the refused sync recorded no nonce", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));

  // Every object read again, held to what was read before.
  S.credentials.aLast = { signCount: (await credentialFor(desk, "a.test")).signCount };
  const again = [
    ["a.passkeys", cyfrRows("a", "passkeys"), cyfrIo("a", "passkeys")],
    ["a.users", cyfrRows("a", "users"), cyfrIo("a", "users")],
    ["a.person_identities", cyfrRows("a", "person_identities"), cyfrIo("a", "person_identities")],
    ["a.athanors", cyfrRows("a", "athanors"), cyfrIo("a", "athanors")],
    ["a.memberships", cyfrRows("a", "memberships"), cyfrIo("a", "memberships")],
    ["a.identity_attempts", cyfrRows("a", "identity_attempts"), cyfrIo("a", "identity_attempts")],
    ["a.registry_tokens", cyfrRows("a", "registry_tokens"), cyfrIo("a", "registry_tokens")],
    ["dir.identity_log_entries", cyfrRows("dir", "identity_log_entries"), cyfrIo("dir", "identity_log_entries")],
    ["registry.namespaces[proof]", registryRows("namespaces", "slug", HANDLE), registryIo("namespaces", "slug")],
    ["registry.namespaces[other]", registryRows("namespaces", "slug", OTHER), registryIo("namespaces", "slug")],
    ["registry.identity_heads[a]", registryRows("identity_heads", "identifier", id), registryIo("identity_heads", "identifier")],
    ["registry.identity_heads[c]", registryRows("identity_heads", "identifier", other.identifier), registryIo("identity_heads", "identifier")],
    ["registry.policy_acceptances[a]", registryRows("policy_acceptances", "identifier", id), registryIo("policy_acceptances", "id")],
    ["registry.policy_acceptances[c]", registryRows("policy_acceptances", "identifier", other.identifier), registryIo("policy_acceptances", "id")],
    ["registry.request_nonces[a]", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce")],
    ["registry.request_nonces[c]", registryRows("request_nonces", "identifier", other.identifier), registryIo("request_nonces", "nonce")],
    ["registry.push_tokens[proof]", registryRows("push_tokens", "namespace_slug", HANDLE), registryIo("push_tokens", "id")],
    ["registry.banned_identities", registryRows("banned_identities", "identifier", id), registryIo("banned_identities", "id")],
    ["b.passkeys", cyfrRows("b", "passkeys"), cyfrIo("b", "passkeys")],
    ["b.users", cyfrRows("b", "users"), cyfrIo("b", "users")],
    ["b.person_identities", cyfrRows("b", "person_identities"), cyfrIo("b", "person_identities")],
    ["b.sessions", cyfrRows("b", "sessions"), cyfrIo("b", "sessions")],
    ["b.athanors", cyfrRows("b", "athanors"), cyfrIo("b", "athanors")],
    ["b.memberships", cyfrRows("b", "memberships"), cyfrIo("b", "memberships")],
    ["b.server_allowlist", cyfrRows("b", "server_allowlist"), cyfrIo("b", "server_allowlist")],
  ];
  // Each field's loop runs again unless the identical predicate already
  // ran on that same row (models.mjs check): a bound that is now exact, or
  // a row a later step first read, runs here.
  for (const [name, read, io] of again) {
    await claim(`held:${name}`, `${name}, read again at the end, is what was read before`, read, { ...io, skipIfRan: true });
  }
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
record.tally = { loops: tally.loops, controls: tally.controls, skipped: tally.skipped };
// What the models are built from, as the run captured it (`seen`), so a
// reader can build them again from the record. No authenticator's private
// key is in it: the COSE key each derives is.
writeFileSync(join(outDir, "handle-proof.json"), redact(JSON.stringify({ versions: record.versions, rows, record, seen: S, failure }, null, 2)));
const header = ["| object | field | class | value, source or bound |", "|---|---|---|---|"];
const tableText = [...header, ...table].join("\n");
writeFileSync(join(outDir, "handle-proof-fields.md"), `${tableText}\n`);
// The README's table holds exactly the rows the models print, one line
// each; a list's rows come in the order the run read them, so lines are
// compared as sorted.
let readmeHolds = false;
try {
  const readme = readFileSync(new URL("./README.md", import.meta.url), "utf8").split("\n");
  const start = readme.indexOf(header[0]);
  const end = readme.findIndex((l, i) => i > start + 1 && !l.startsWith("|"));
  const lines = start < 0 ? [] : readme.slice(start + 2, end < 0 ? readme.length : end);
  readmeHolds = !failure && JSON.stringify([...lines].sort()) === JSON.stringify([...table].sort());
} catch {
  readmeHolds = false;
}
if (!failure && rows.length) row("readme", readmeHolds, "README.md's field table is the one the models print", {});
const summary = ["| step | outcome |", "|---|---|", ...[...STEPS, "readme"].map((step) => `| ${step} | ${outcome(step)} |`)];
writeFileSync(join(outDir, "handle-proof.md"), `${summary.join("\n")}\n\nTamper loops run: ${tally.loops}. Controls refused: ${tally.controls}. Fields with no loop here, each named with its reason in handle-proof.json: ${tally.skipped.length}.\n`);
console.log(summary.join("\n"));
console.log(`tamper loops run: ${tally.loops}; controls refused: ${tally.controls}; fields with no loop here, each named: ${tally.skipped.length}`);
if (failure || [...STEPS, "readme"].some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the handle proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
