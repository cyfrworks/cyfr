// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The handle proof, run in the official Playwright image by run.sh against
// `cyfr` releases behind the harness's HTTPS front and cyfr.run's registry
// (README.md): the CYFR A (a.test) the person sets up, the CYFR B
// (b.test) they sign in at, and the registry, directory and account pages
// at registry.test. Chromium drives every step with its virtual WebAuthn
// authenticator (../browser/account.mjs).
//
// After each step the proof reads every object the step claims, whole,
// and holds it to its model (models.mjs), built from what the run
// captured: the browsers' credentials and cookies, the clock readings
// around each step, and each generated value at its first read. Every
// stored field is then shown failing behind the browsers' back (models.mjs
// `check`). At the end every object is read again and held to what was
// read before. The README's field table is the one these models print.
//
// Usage: node proof.mjs HOMES_FILE OUT_DIR REGISTRY_PORT

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createAccount, landing, passkeys, setUp, signIn, usePasskey } from "../browser/account.mjs";
import {
  ask as askRunSh, homeOf, launchBrowser, readHomes, redact as redactKnown, startProxy, waitFor,
} from "../browser/lib.mjs";
import {
  ADMIN_HANDLE, HANDLE, LONG_AGO, OCI, PER, REGISTRY, b64url, check, classification, objectModels, otherId, passkeyKid,
} from "./models.mjs";

const [homesFile, outDir, registryPort] = process.argv.slice(2);
const { homes } = readHomes(homesFile);
const AHome = homeOf(homes, "a.test");
const BHome = homeOf(homes, "b.test");
// The registry, as the browsers reach it: its account pages hold every
// passkey of the run, bound to registry.test.
const REG = { host: REGISTRY, origin: `https://${REGISTRY}` };
const A = AHome.origin;
const B = BHome.origin;

const secrets = [];
const redact = (text) => redactKnown(text, secrets);
const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });
const clock = () => Date.now();

// What the run captured, which the models are built from (the record's
// `seen`): origins, clock windows, read times, first reads, the passkeys'
// kids, cookies' digests, refusal sentences.
const S = {
  origins: { a: A, b: B }, w: {}, at: {}, rows: {}, credentials: {}, cookies: {}, refusals: {},
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
// A cell's athanors once none is being filled: the fill runs after the
// admission commits and ends by writing the row (`Sanctum.Provisioning`,
// `provisioned_at` or `provisioning_failed_at`), so a row read before it
// ends is written again under its own tamper loops. A fill's claim stands
// one minute without renewal, the wait's bound.
const athanorRows = (cell) => {
  const read = cyfrRows(cell, "athanors");
  return filtered(async () => {
    const closes = clock() + 60_000;
    for (;;) {
      const rows = await read();
      if (rows.every((r) => r.provisioned_at || r.provisioning_failed_at) || clock() >= closes) return rows;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }, "");
};
const cyfrIo = (cell, tableName, keyField = "id") => ({
  identity: { store: `${cell}.${tableName}`, key: (row) => row[keyField] },
  write: async (i, field, value, rowNow) => {
    const answer = await ask({ op: "set", cell, table: tableName, id: rowNow[keyField], field, value });
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
const answerIo = (handle, owner) => ({
  via: {
    status: { target: "reserved", value: true, original: false },
    handle: { none: "the handle asked for, echoed: shown failing by a control" },
    identifier: { target: "owner_identifier", value: otherId(owner), original: owner },
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
// The browsers
// ---------------------------------------------------------------------------

async function freshContext(browser) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  contexts.push(context);
  return context;
}

const connected = (page) => page.waitForSelector(".phx-connected", { timeout: 60_000 });

// A page done with its CYFR for now, parked on a blank document: an open
// page's socket asks its CYFR about its session, which past the freshness
// bound reads the account's log again and moves the cached head, so no
// page stays open at a CYFR while that CYFR's rows are tampered with.
const park = (page) => page.goto("about:blank");

async function dumpPages() {
  for (const context of contexts) {
    for (const page of context.pages()) {
      const text = await page.locator("body").innerText({ timeout: 2_000 }).catch(() => "unread");
      console.error(`  at ${page.url().replace(/#.*/, "#…")}: ${JSON.stringify(redact(text).slice(0, 1500))}`);
    }
  }
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

// The CYFR `home` set up by the account `keys` hold, through its setup
// link (account.mjs `setUp`), its token asked of run.sh.
async function setUpWith(page, keys, home, cell) {
  const { token } = await ask({ op: "setup_token", cell }, { secret: true });
  secrets.push(token);
  return setUp(page, keys, home, token);
}

// The key the person's authenticator made at registry.test: its kid, as the
// log lists it, and its credential id, as the add_key names it.
async function heldKey(keys) {
  const credential = (await keys.list()).find((c) => c.rpId === REGISTRY);
  return credential ? { kid: passkeyKid(credential.privateKey), credentialIdB64url: b64url(credential.credentialId) } : {};
}

// "Sync push tokens" on A's Registry page: a registry request the passkey
// signs at the sign page in the tab the system layer opens; the tab comes
// back to A, which completes the request and says what it did. Answers
// what the sign page asked and the tab's flash.
async function sync(desk, keys, registryPage) {
  await desk.goto(registryPage);
  await connected(desk);
  const [tab] = await Promise.all([
    desk.context().waitForEvent("page", { timeout: 60_000 }),
    desk.locator("button", { hasText: "Sync push tokens" }).click(),
  ]);
  try {
    const asked = await usePasskey(tab, keys);
    const back = asked.returned ? await landing(tab, AHome) : { landed: false };
    const flash = back.landed
      ? await tab.waitForSelector("#flash-info, #flash-error", { timeout: 60_000 })
        .then((el) => el.innerText()).then((t) => t.replace(/\s+/g, " ").replace(/\s*×$/, "").trim()).catch(() => "")
      : "";
    return { what: asked.what, landed: back.landed, error: back.error ?? asked.error ?? null, flash };
  } finally {
    await keys.sync();
    await tab.close().catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function main(chromium) {
  record.versions = { chromium: chromium.version() };
  S.policyVersion = (await ask({ op: "legal_version" })).policy_version;
  S.ttlHours = Number((await ask({ op: "setting", cell: "b", key: "session_ttl_hours" })).value);

  // 1. @proof made at registry.test's account pages, then A set up with it.
  const deskContext = await freshContext(chromium);
  const desk = await deskContext.newPage();
  const keys = passkeys();
  let from = clock();
  const made = await createAccount(desk, keys, { directory: REG, name: HANDLE, secrets });
  windowed("make", from, "the account made at registry.test's pages");
  const id = made.code?.identifier ?? "";
  S.identifier = id;
  S.credentials.a = await heldKey(keys);
  record.setup = { made: made.section, error: made.error, identifier: id };
  if (!row("setup", made.section === "done" && PER.test(id),
    "@proof is made at registry.test's account pages: the policy accepted, the recovery code shown and saved, then the passkey", record.setup)) return;
  await claim("setup:registry.directory.entries[a]", "the directory's log of @proof's account: its genesis and its passkey's add_key", registryRows("directory.entries", "identifier", id), registryIo("directory.entries", "entry_hash"));
  await claim("setup:registry.namespaces[proof]", "the registry's @proof: personal, owned by the account's identifier", registryRows("namespaces", "slug", HANDLE), registryIo("namespaces", "slug"));
  await claim("setup:registry.identity_heads[a]", "the registry's read of the account's log, which the claim was verified against", registryRows("identity_heads", "identifier", id), registryIo("identity_heads", "identifier"));
  await claim("setup:registry.policy_acceptances[a]", "the account's acceptance of the registry's policy", registryRows("policy_acceptances", "identifier", id), registryIo("policy_acceptances", "id"));
  await claim("setup:registry.request_nonces[a]", "the nonces of the account's two signed requests, the acceptance and the claim", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));
  await claim("setup:handle_answer[proof]", "the registry's answer for @proof: the account's identifier and directory", handleAnswer(HANDLE), answerIo(HANDLE, id));

  from = clock();
  const atA = await setUpWith(desk, keys, AHome, "a");
  windowed("setup", from, "setup at A");
  await park(desk);
  record.setup.at_a = atA;
  if (!row("setup", atA.landed && atA.what === `Sign in to ${A}`,
    "A is set up by signing in with the account at its setup link: the sign page names A, and A lands signed in", atA)) return;
  await claim("setup:a.users", "A's one person, admitted by setup", cyfrRows("a", "users"), cyfrIo("a", "users"));
  await claim("setup:a.athanors", "A's one athanor, its person's", athanorRows("a"), cyfrIo("a", "athanors"));
  await claim("setup:a.person_identities", "A's person is the account's identifier, read at registry.test", cyfrRows("a", "person_identities"), cyfrIo("a", "person_identities"));
  await claim("setup:a.directory_heads", "A's cached head of the account's log", cyfrRows("a", "directory_heads"), cyfrIo("a", "directory_heads", "identifier"));
  await claim("setup:a.paired_clients", "A's one paired client: the passkey that signed in, by its kid", cyfrRows("a", "paired_clients"), cyfrIo("a", "paired_clients"));

  // 2. B's administrator, with an account of their own, sets B up and
  // allows @proof in Settings.
  const adminContext = await freshContext(chromium);
  const admin = await adminContext.newPage();
  const adminKeys = passkeys();
  from = clock();
  const adminMade = await createAccount(admin, adminKeys, { directory: REG, name: ADMIN_HANDLE, secrets });
  const atB = adminMade.section === "done" ? await setUpWith(admin, adminKeys, BHome, "b") : { landed: false };
  windowed("admin", from, "B's administrator's account and setup at B");
  S.credentials.b = await heldKey(adminKeys);
  S.cookies.admin = await cookieDigest(adminContext, B, "b");
  const bSegment = `@${(await ask({ op: "rows", cell: "b", table: "athanors" })).rows[0]?.slug ?? "me"}`;
  await admin.goto(`${B}/a/${encodeURIComponent(bSegment)}/settings`);
  await connected(admin);
  const entry = admin.locator('#door-entry-form input[name="value"]');
  await entry.fill(`@${HANDLE}`);
  const allow = admin.locator("#door-entry-form button", { hasText: "Allow" });
  await waitFor(async () => (await allow.getAttribute("phx-value-door")) === `@${HANDLE}`, { timeoutMs: 30_000, what: "the door form taking @proof" });
  from = clock();
  await allow.click();
  const labelled = await admin.waitForSelector('[data-test="door-entry-label"]', { timeout: 60_000 }).then(() => true).catch(() => false);
  windowed("allow", from, "the allow");
  await park(admin);
  row("allow", atB.landed && labelled, "B's administrator sets B up with their own account and allows @proof in Settings", { setup: atB, labelled });
  await claim("allow:b.users", "B's one person, its administrator", cyfrRows("b", "users"), cyfrIo("b", "users"));
  await claim("allow:b.athanors", "B's one athanor, the administrator's", athanorRows("b"), cyfrIo("b", "athanors"));
  await claim("allow:b.person_identities", "B's administrator is their account's identifier", cyfrRows("b", "person_identities"), cyfrIo("b", "person_identities"));
  await claim("allow:b.server_allowlist", "B's allowlist: setup's allow of the administrator, and @proof's identifier labelled @proof", cyfrRows("b", "server_allowlist"), cyfrIo("b", "server_allowlist"));

  // 3. At B, a browser that never visited it, holding the person's passkey
  // as a synced passkey reaches another device, signs in with the account:
  // no address is typed, and B admits A's identifier under its allow.
  const personContext = await freshContext(chromium);
  const person = await personContext.newPage();
  const personKeys = passkeys((await keys.list()).filter((c) => c.rpId === REGISTRY));
  from = clock();
  const signedIn = await signIn(person, personKeys, BHome);
  windowed("signin", from, "the sign-in at B");
  S.cookies.remote = await cookieDigest(personContext, B, "b");
  await park(person);
  record.sign_in = signedIn;
  row("sign_in", signedIn.landed && signedIn.what === `Sign in to ${B}`,
    "at B's sign-in page the person signs in with their passkey, typing no address: the sign page names B, and B admits the account under its allow", signedIn);
  await claim("sign_in:b.person_identities", "B's identities: its administrator's, and A's identifier, admitted", cyfrRows("b", "person_identities"), cyfrIo("b", "person_identities"));
  await claim("sign_in:b.athanors", "B's athanors: its administrator's, and the person's own, made in the admission", athanorRows("b"), cyfrIo("b", "athanors"));
  await claim("sign_in:b.users", "B's people: its administrator, and the person admitted under the allow", cyfrRows("b", "users"), cyfrIo("b", "users"));
  await claim("sign_in:b.directory_heads", "B's cached heads: the administrator's account's and the person's", cyfrRows("b", "directory_heads"), cyfrIo("b", "directory_heads", "identifier"));
  await claim("sign_in:b.paired_clients", "B's paired clients: each passkey that signed in there, by its kid", cyfrRows("b", "paired_clients"), cyfrIo("b", "paired_clients"));
  await claim("sign_in:b.sessions", "B's sessions: each its browser cookie's token, bound to its passkey's kid and head", cyfrRows("b", "sessions"), cyfrIo("b", "sessions"));

  // 4. registry.sync at A, signed by the passkey, stores a push token; the
  // registry bans the identifier; the token is refused there, and A's next
  // sync answers banned.
  const aSegment = `@${S.rows["setup:a.athanors"]?.[0]?.slug ?? "me"}`;
  const registryPage = `${A}/a/${encodeURIComponent(aSegment)}/registry`;
  from = clock();
  const synced = await sync(desk, keys, registryPage);
  windowed("sync", from, "the sync");
  await park(desk);
  record.sync = synced;
  row("sync", synced.landed && /^Create a publishing token named “.+” at registry\.test$/.test(synced.what ?? "") &&
    synced.flash.includes("Your push tokens are synced."),
  "Sync push tokens at A: the sign page shows the registry request in words, the passkey signs it, and A completes it", synced);

  const aUserId = S.rows["setup:a.users"]?.[0]?.id;
  const credential = async () => (await ask({ op: "credential", user_id: aUserId, registry: OCI, slug: HANDLE })).credential;
  const opened = await credential().catch(() => null);
  const tokenRow = (await registryRows("push_tokens", "namespace_slug", HANDLE)())[0];
  S.credentialOpened = !!opened && `\\x${opened.token?.sha256}` === tokenRow?.token_hash;
  S.credentialDigest = opened?.token?.sha256;
  S.credentialLabel = opened?.label;
  await claim("sync:registry.push_tokens[proof]", "the registry holds one live token for @proof, made by the account, whose digest is the token A sealed", registryRows("push_tokens", "namespace_slug", HANDLE), registryIo("push_tokens", "id"));
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
  await claim("sync:registry.request_nonces[a]", "the nonces: the earlier two held, and the sync's", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));
  await claim("sync:registry.identity_heads[a]", "the registry's read of the account's log, refreshed by the sync's request", registryRows("identity_heads", "identifier", id), registryIo("identity_heads", "identifier"));

  from = clock();
  const ban = await ask({ op: "ban", handle: HANDLE });
  windowed("ban", from, "the ban");
  S.adminId = (await ask({ op: "admin_id" })).id;
  row("ban", ban.status === 303, "the registry's operator bans @proof's owner", { status: ban.status });
  await claim("ban:registry.banned_identities", "the ban names the account's identifier, by the run's operator", registryRows("banned_identities", "identifier", id), registryIo("banned_identities", "id"));
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

  from = clock();
  const refused = await sync(desk, keys, registryPage);
  windowed("sync2", from, "the sync after the ban");
  await park(desk);
  S.refusals.banned = await ask({ op: "refusal", cell: "a", reason: "banned" });
  const unavailable = (await ask({ op: "refusal", cell: "a", reason: "registry_unavailable" })).sentence;
  record.banned_sync = refused;
  await claim("ban:a.sync_refused", "A's next sync shows banned's sentence, which no other sync refusal shares",
    async () => ({ shown: refused.flash, shared_with: S.refusals.banned.shared_with }), {
      controls: [
        { field: ".shown", says: "registry_unavailable's sentence", corrupt: (o) => ({ ...o, shown: `That did not go through: ${unavailable}` }) },
        { field: ".shared_with", says: "a refusal sharing the sentence", corrupt: (o) => ({ ...o, shared_with: ["registry_unavailable"] }) },
      ],
    });
  await claim("ban:registry.request_nonces[a]", "the refused sync recorded no nonce", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce"));

  // Every object read again, held to what was read before.
  const again = [
    ["a.users", cyfrRows("a", "users"), cyfrIo("a", "users")],
    ["a.person_identities", cyfrRows("a", "person_identities"), cyfrIo("a", "person_identities")],
    ["a.athanors", cyfrRows("a", "athanors"), cyfrIo("a", "athanors")],
    ["a.directory_heads", cyfrRows("a", "directory_heads"), cyfrIo("a", "directory_heads", "identifier")],
    ["a.paired_clients", cyfrRows("a", "paired_clients"), cyfrIo("a", "paired_clients")],
    ["a.registry_tokens", cyfrRows("a", "registry_tokens"), cyfrIo("a", "registry_tokens")],
    ["registry.directory.entries[a]", registryRows("directory.entries", "identifier", id), registryIo("directory.entries", "entry_hash")],
    ["registry.namespaces[proof]", registryRows("namespaces", "slug", HANDLE), registryIo("namespaces", "slug")],
    ["registry.identity_heads[a]", registryRows("identity_heads", "identifier", id), registryIo("identity_heads", "identifier")],
    ["registry.policy_acceptances[a]", registryRows("policy_acceptances", "identifier", id), registryIo("policy_acceptances", "id")],
    ["registry.request_nonces[a]", registryRows("request_nonces", "identifier", id), registryIo("request_nonces", "nonce")],
    ["registry.push_tokens[proof]", registryRows("push_tokens", "namespace_slug", HANDLE), registryIo("push_tokens", "id")],
    ["registry.banned_identities", registryRows("banned_identities", "identifier", id), registryIo("banned_identities", "id")],
    ["b.users", cyfrRows("b", "users"), cyfrIo("b", "users")],
    ["b.person_identities", cyfrRows("b", "person_identities"), cyfrIo("b", "person_identities")],
    ["b.paired_clients", cyfrRows("b", "paired_clients"), cyfrIo("b", "paired_clients")],
    ["b.sessions", cyfrRows("b", "sessions"), cyfrIo("b", "sessions")],
    ["b.athanors", cyfrRows("b", "athanors"), cyfrIo("b", "athanors")],
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
  // The browsers reach the registry's account pages through the same
  // front as every home, at its listener, whose certificate the run's
  // authority issued (run.sh `browser_certificate`).
  proxy = await startProxy({
    homes,
    routed: [{
      name: "registry", host: REGISTRY, port: Number(registryPort),
      cert: `/authority/${REGISTRY}.pem`, key: `/authority/${REGISTRY}.key`,
    }],
  });
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

const STEPS = ["setup", "allow", "sign_in", "sync", "ban"];
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
