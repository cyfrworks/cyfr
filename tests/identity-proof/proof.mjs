// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The identity proof, run in the official Playwright image by run.sh
// against `cyfr` releases behind the harness's HTTPS front (README.md):
// homes A, B, C, C2 and C3 and a directory, each a cell on its own `.test`
// name. Chromium alone, since a passkey is made and used by its virtual
// authenticator; the glass's steps run once more at the proposed
// handheld's 720×720 touch viewport (../browser/handheld.mjs). Each step is
// one row of the record; the proof fails when a row does not hold, and
// stops at the first row a later one rests on.
//
// The homes' part of a step — a cell stopped, copied, killed or started
// again, the directory's front broken on purpose, a restore posted at a
// phase, and what a home holds — is run.sh's, asked for through OUT_DIR
// (`ask-N.json`, answered `answer-N.json`). An ask or an answer that
// carries a kit line or an installation token is deleted once read.
//
// Usage: node proof.mjs HOMES_FILE SEGMENT_A COOKIE_A OUT_DIR

import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HANDHELD, measure, unmet } from "../browser/handheld.mjs";
import { launchBrowser, readHomes, signedIn, sleep, startProxy, virtualAuthenticator, waitFor } from "../browser/lib.mjs";

const [homesFile, segmentA, cookieA, outDir] = process.argv.slice(2);
if (!homesFile || !segmentA || !cookieA || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE SEGMENT_A COOKIE_A OUT_DIR");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

const { homes } = readHomes(homesFile);
const homeNamed = (name) => homes.find((home) => home.name === name) || (() => { throw new Error(`no home ${name}`); })();
const A = homeNamed("a").origin;
const C = homeNamed("c").origin;
const C3 = homeNamed("c3").origin;
const settingsOf = (base, segment) => `${base}/a/${encodeURIComponent(segment)}/settings`;
const shellOf = (base, segment) => `${base}/a/${encodeURIComponent(segment)}/tinctures`;
const rows = [];
const record = {};
// Every kit line and token the proof handled, so no page, address or
// record is shown to hold one.
const secrets = [];

function row(step, held, what, detail) {
  rows.push({ step, held: !!held, what, detail });
  const shown = JSON.stringify(detail);
  console.log(`${held ? "held  " : "FAILED"} ${step}: ${what} — ${redact(shown).slice(0, 2000)}`);
  return !!held;
}

function redact(text) {
  return secrets.reduce((out, secret) => (secret ? out.split(secret).join("[secret]") : out), text);
}

// The homes' part of a step, asked of run.sh. `secret: true` deletes the
// ask and its answer once read.
let asked = 0;
async function ask(request, { timeoutMs = 300_000, secret = false } = {}) {
  const id = ++asked;
  const answer = join(outDir, `answer-${id}.json`);
  writeFileSync(join(outDir, `ask-${id}.part`), JSON.stringify(request));
  renameSync(join(outDir, `ask-${id}.part`), join(outDir, `ask-${id}.json`));
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(answer)) {
    if (Date.now() > deadline) throw new Error(`run.sh never answered ${request.op}`);
    await sleep(100);
  }
  const answered = JSON.parse(readFileSync(answer, "utf8"));
  if (secret) {
    rmSync(answer, { force: true });
    rmSync(join(outDir, `ask-${id}.json`), { force: true });
  }
  if (answered.error && !request.tolerate) throw new Error(`run.sh: ${request.op}: ${answered.error}`);
  return answered;
}

// ---------------------------------------------------------------------------
// The glass's device channel, watched from inside its own page
// (tests/pairing-proof/proof.mjs's instrument, reduced to what this proof reads)
// ---------------------------------------------------------------------------

function instrumentDevice() {
  const Native = window.WebSocket;
  const device = { log: [], sockets: 0 };
  window.__device = device;
  const describe = (data) => {
    try {
      const map = JSON.parse(data);
      return { type: map.type, id: map.id, error: map.error ? (map.error.class || "error") : undefined };
    } catch {
      return { type: "unreadable" };
    }
  };
  class Watched extends Native {
    constructor(url, protocols) {
      super(url, protocols);
      if (!/\/device\/websocket/.test(String(url))) return;
      this.__serial = ++device.sockets;
      super.addEventListener("message", (event) => device.log.push({ socket: this.__serial, dir: "in", ...describe(event.data) }));
      super.addEventListener("close", (event) => device.log.push({ socket: this.__serial, event: "close", code: event.code }));
    }
    send(data) {
      if (this.__serial) device.log.push({ socket: this.__serial, dir: "out", ...describe(data) });
      return super.send(data);
    }
  }
  window.WebSocket = Watched;
}

const storedDevice = (page) => page.evaluate(() => new Promise((resolve, reject) => {
  const open = indexedDB.open("cyfr-glass", 1);
  open.onupgradeneeded = () => open.result.createObjectStore("glass");
  open.onerror = () => reject(open.error);
  open.onsuccess = () => {
    const read = open.result.transaction("glass", "readonly").objectStore("glass").get("device");
    read.onsuccess = () => {
      window.__heldDevice = read.result || null;
      resolve(read.result ? { clientId: read.result.clientId, certificate: read.result.certificate } : null);
    };
    read.onerror = () => reject(read.error);
  };
}));

// A connection of its own, from the glass's page, under the certificate
// `certificate` and the device key the glass holds: `connect`, the
// challenge signed with the key, and how the home closed it.
const connectWith = (page, certificate) => page.evaluate(async (cert) => {
  const held = window.__heldDevice;
  if (!held) return { error: "no device held" };
  const b64url = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const jcs = (value) => value === null || typeof value !== "object"
    ? JSON.stringify(value)
    : Array.isArray(value)
      ? `[${value.map(jcs).join(",")}]`
      : `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${jcs(value[k])}`).join(",")}}`;
  const Native = Object.getPrototypeOf(window.WebSocket.prototype).constructor;
  return new Promise((resolve) => {
    const seen = [];
    const ws = new Native(`wss://${location.host}/device/websocket`);
    const done = setTimeout(() => { ws.close(); resolve({ seen, code: null, timedOut: true }); }, 20_000);
    ws.onopen = () => ws.send(JSON.stringify({ protocol: "cyfr-device/v1", type: "connect", client_id: held.clientId, certificate: cert }));
    ws.onmessage = async (event) => {
      const map = JSON.parse(event.data);
      seen.push(map.type);
      if (map.type === "challenge") {
        const { sig: _sig, ...fields } = map.challenge;
        const sig = await crypto.subtle.sign({ name: "Ed25519" }, held.privateKey, new TextEncoder().encode(jcs(fields)));
        ws.send(JSON.stringify({ protocol: "cyfr-device/v1", type: "proof", proof: { ...fields, sig: b64url(sig) } }));
      }
    };
    ws.onclose = (event) => { clearTimeout(done); resolve({ seen, code: event.code }); };
  });
}, certificate);

const deviceLog = (page) => page.evaluate(() => window.__device.log.slice());

const glassStateOf = (page) =>
  page.locator('[data-test="glass-status"]').getAttribute("data-state", { timeout: 2_000 }).catch(() => null);

// ---------------------------------------------------------------------------
// Prism's side
// ---------------------------------------------------------------------------

const connected = (page) => page.waitForSelector(".phx-connected", { timeout: 60_000 });
const layer = "#system-layer-dialog";
const layerText = (page) => page.locator(layer).innerText({ timeout: 2_000 }).catch((error) => `unread: ${error.message.split("\n")[0]}`);

async function closePrompt(page) {
  const close = page.locator(`${layer}[open] [data-test="prompt-dismiss"]`);
  if (await close.count()) {
    await close.click();
    await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, { timeout: 30_000 });
  }
}

async function open(page, url, { close = true } = {}) {
  await page.goto(url);
  await connected(page);
  if (close) await closePrompt(page);
}

// The page's own request, confirmed here with the passkey its
// authenticator holds.
async function confirmHere(page) {
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  await page.waitForSelector(`${own} [data-test="confirm-passkey"]`, { timeout: 30_000 });
  await page.locator(`${own} [data-test="confirm-passkey"]`).click();
}

// What the page says after a change: its flash, or the layer's sentence.
const flashed = (page, text, timeout = 30_000) =>
  page.waitForFunction((t) => document.body.innerText.includes(t), text, { timeout });

// The kit the layer drew, read from the prompt as the person reads it.
async function readKit(page) {
  const kit = `${layer} [data-test="recovery-kit"]:not([hidden])`;
  await page.waitForSelector(`${kit} [data-test="kit-secret"]`, { timeout: 60_000 });
  const line = (test) => page.locator(`${kit} [data-test="${test}"]`).textContent();
  const lines = { identifier: await line("kit-identifier"), directory_url: await line("kit-directory"), recovery_secret: await line("kit-secret") };
  secrets.push(lines.recovery_secret);
  return lines;
}

async function saveKit(page) {
  await page.locator(`${layer} [data-test="recovery-ack"]`).click();
  await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, { timeout: 30_000 });
}

// Where a secret the proof handled might have gone in the page's own
// browser: its storage, its address, and every request the proxy saw.
async function leaks(page, proxy, mark) {
  const stored = await page.evaluate(() => {
    const dump = (store) => {
      const out = [];
      for (let i = 0; i < store.length; i++) out.push(store.key(i), store.getItem(store.key(i)));
      return out.join("\n");
    };
    return `${dump(localStorage)}\n${dump(sessionStorage)}\n${location.href}\n${document.cookie}`;
  });
  const requests = proxy.seen.slice(mark).map((r) => `${r.url} ${r.referer ?? ""}`).join("\n");
  return secrets.filter((secret) => secret && (stored.includes(secret) || requests.includes(secret))).length;
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

async function firstPasskey(page, authenticator, base, segment, step) {
  await open(page, settingsOf(base, segment));
  await page.locator('[data-test="passkey-register"]').click();
  await flashed(page, "Passkey registered.");
  await page.waitForSelector('[data-test="passkey"][data-state="active"]', { timeout: 30_000 });
  // The authenticator may hold a credential an earlier, refused ceremony
  // made; the home holds the one it registered.
  const held = (await authenticator.credentials()).filter((c) => c.rpId === new URL(base).host).length;
  const registered = await page.locator('[data-test="passkey"][data-state="active"]').count();
  record[step] = { credentials_for_rp: held, registered_here: registered };
  return row(step, held >= 1 && registered === 1, "the first passkey is registered from the settings page through the system layer's ceremony", record[step]);
}

// A glass paired at A from the desktop's Devices: the pairing confirmed on
// the desktop, its link opened on `glass`. Answers the device it holds.
async function pairAtA(desk, glass) {
  await open(desk, shellOf(A, segmentA));
  await desk.locator("#shell-devices").click();
  await desk.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="pairing-begin"]`).click();
  await confirmHere(desk);
  await desk.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await desk.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  await closePrompt(desk);
  await glass.goto(link);
  await glass.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  return storedDevice(glass);
}

async function pairLocally(desk, phone) {
  const device = await pairAtA(desk, phone);
  const identity = await ask({ op: "a_head" });
  record.pair = { enrolled_before: identity.enrollment, subject: device && device.certificate.subject };
  return [row("pair", identity.enrollment === "none" && device && device.certificate.subject.kind === "local",
    "before any enrollment, a glass pairs locally under a local subject, with no directory read",
    record.pair), device];
}

async function enroll(desk, proxy) {
  const mark = proxy.seen.length;
  await open(desk, settingsOf(A, segmentA));
  const directory = await desk.locator('[data-test="identity-directory"]').textContent();
  await desk.locator('[data-test="identity-enroll"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="enrollment"]`, { timeout: 30_000 });
  const statements = await desk.locator(`${layer} [data-test="recovery-statements"]`).innerText();
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  await confirmHere(desk);
  const kit = await readKit(desk);
  const shownBeforeSave = (await desk.content()).includes(kit.recovery_secret);
  await saveKit(desk);
  await desk.waitForSelector('[data-test="identity"][data-enrollment="enrolled"]', { timeout: 30_000 });
  const leaked = await leaks(desk, proxy, mark);
  const afterSave = (await desk.content()).includes(kit.recovery_secret);
  record.enroll = {
    directory: directory.trim(), identifier: kit.identifier, kit_directory: kit.directory_url,
    statements: ["cannot be reached", "If every kit is lost", "never your private data"].map((s) => statements.includes(s)),
    drawn_in_the_prompt: shownBeforeSave, kept_after_saving: afterSave, leaked,
  };
  return [row("enroll",
    kit.directory_url === directory.trim() && kit.identifier.startsWith("per_") &&
      record.enroll.statements.every(Boolean) && shownBeforeSave && !afterSave && leaked === 0,
    "enrolled from the settings page: the form says what it commits to, the confirmed seed prints its kit in the system layer, and saving it erases it",
    record.enroll), kit];
}

async function secondKit(desk, proxy, first) {
  const mark = proxy.seen.length;
  await open(desk, settingsOf(A, segmentA));
  await desk.locator('[data-test="identity-add-kit"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="holder"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="recovery-signer"]`).fill(first.recovery_secret);
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  await confirmHere(desk);
  const kit = await readKit(desk);
  await saveKit(desk);
  const leaked = await leaks(desk, proxy, mark);
  record.second_kit = { same_identifier: kit.identifier === first.identifier, distinct: kit.recovery_secret !== first.recovery_secret, leaked };
  return [row("second_kit", record.second_kit.same_identifier && record.second_kit.distinct && leaked === 0,
    "another printed kit, signed by the first one typed into the prompt and drawn in the browser",
    record.second_kit), kit];
}

async function rotate(desk, phone, paired) {
  const before = await ask({ op: "a_head" });
  const mark = (await deviceLog(phone)).length;
  await open(desk, settingsOf(A, segmentA));
  await desk.locator('[data-test="identity-rotate"]').click();
  await confirmHere(desk);
  await flashed(desk, "Your live key was rotated.");
  const after = await ask({ op: "a_head" });

  // The certificate signed under the replaced key opens nothing; the glass
  // renews by its device key — on the connection it holds, or on its next
  // one, whose stale connect is closed 4408 — and stands again.
  const replaced = await connectWith(phone, paired.certificate);
  const renewedHere = await waitFor(async () => {
    const held = await storedDevice(phone);
    return held && JSON.stringify(held.certificate) !== JSON.stringify(paired.certificate) ? held : null;
  }, { timeoutMs: 20_000, what: "the glass's renewed certificate" }).catch(() => null);
  const held = (await deviceLog(phone)).slice(mark);
  await phone.goto(`${A}/pair`);
  await phone.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  const renewed = renewedHere || await waitFor(async () => {
    const stored = await storedDevice(phone);
    return stored && JSON.stringify(stored.certificate) !== JSON.stringify(paired.certificate) ? stored : null;
  }, { timeoutMs: 60_000, what: "the glass's renewed certificate" }).catch(() => null);
  const frames = [...held, ...(await deviceLog(phone))];
  record.rotate = {
    head_moved: before.head !== after.head, live_key_moved: before.live_key !== after.live_key,
    replaced_certificate: replaced,
    sent: frames.filter((e) => e.dir === "out").map((e) => e.type),
    closes: frames.filter((e) => e.event === "close").map((e) => e.code),
    renewed_on: renewedHere ? "the connection it held" : "its next connection",
    new_certificate: !!renewed,
  };
  return row("rotate",
    record.rotate.head_moved && record.rotate.live_key_moved && replaced.code === 4408 &&
      record.rotate.sent.includes("renew") && record.rotate.new_certificate,
    "the live key rotated under a fresh confirmation: a certificate signed under the replaced key opens nothing, and the paired glass renews by its device key",
    record.rotate);
}

async function cache() {
  const answer = await ask({ op: "b_resolve" });
  const head = await ask({ op: "a_head" });
  record.cache = { b: answer.key_epoch, a: head.head };
  return row("cache", answer.key_epoch === head.head,
    "B, which holds nothing of the person's, reads the identity at its directory and caches the head",
    record.cache);
}

// The restore page of `base`, filled with `token` and `kit`, and its
// answer once it settles.
async function restoreThere(page, base, token, kit) {
  await page.goto(`${base}/restore`);
  await connected(page);
  await page.locator('[data-test="restore-token"]').fill(token);
  await page.locator('[data-test="restore-identifier"]').fill(kit.identifier);
  await page.locator('[data-test="restore-directory"]').fill(kit.directory_url);
  await page.locator('[data-test="restore-secret"]').fill(kit.recovery_secret);
  await page.locator('[data-test="restore-submit"]').click();
  await page.waitForSelector('[data-test="restore-status"]:not([data-state="idle"]):not([data-state="retry"])', { timeout: 180_000 });
  return page.locator('[data-test="restore-status"]').getAttribute("data-state");
}

async function restoredHome(page, proxy, base, cell, token, kit, step) {
  const mark = proxy.seen.length;
  const state = await restoreThere(page, base, token, kit);
  const fields = await page.$$eval("[data-field]", (inputs) => inputs.map((input) => input.value));
  const leaked = await leaks(page, proxy, mark);
  const posted = proxy.seen.slice(mark).filter((r) => r.method === "POST" && r.url === `${base}/restore`);
  record[step] = { state, emptied: fields.every((value) => value === ""), leaked, posts: posted.length };
  const held = row(step, state === "completed" && record[step].emptied && leaked === 0,
    `the person restores on ${cell} from the kit's three lines and its own installation token; the form forgets both`,
    record[step]);
  return held;
}

// ---------------------------------------------------------------------------
// The glass's steps once more on the proposed handheld (HANDHELD)
// ---------------------------------------------------------------------------

// A second glass, the handheld, follows the phone through the glass's
// steps: paired locally at A before any enrollment, reconnected at A after
// the rotation under a renewed certificate, and opened at C, a home that
// holds no device of it. Each of those screens meets the handheld's
// checks, which the `viewport` row holds.
async function handheldPairs(browser, desk) {
  const context = await browser.newContext(HANDHELD);
  await context.addInitScript(instrumentDevice);
  const page = await context.newPage();
  const device = await pairAtA(desk, page);
  const hand = { context, page, device, measured: {}, facts: {} };
  hand.measured.paired = await measure(page, "#glass");
  hand.facts.paired_subject = device && device.certificate.subject.kind;
  return hand;
}

// `before` is the handheld's device as it stood just before the rotation.
async function handheldReconnects(hand, before) {
  await hand.page.goto(`${A}/pair`);
  await hand.page.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  const renewed = await waitFor(async () => {
    const held = await storedDevice(hand.page);
    return held && before && JSON.stringify(held.certificate) !== JSON.stringify(before.certificate) ? held : null;
  }, { timeoutMs: 60_000, what: "the handheld's renewed certificate" }).catch(() => null);
  await hand.page.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });
  hand.measured.reconnected = await measure(hand.page, "#glass");
  hand.facts.renewed_after_rotation = !!renewed;
}

async function handheldElsewhere(hand) {
  await hand.page.goto(`${C}/pair`);
  hand.facts.at_c = await hand.page.waitForSelector('[data-test="glass-status"][data-state="unpaired"]', { timeout: 60_000 })
    .then(() => "unpaired").catch(() => glassStateOf(hand.page));
  hand.measured.other_home = await measure(hand.page, "#glass");
  await hand.context.close();
  const failures = unmet(hand.measured);
  record.viewport = { viewport: HANDHELD.viewport, ...hand.facts, measured: hand.measured, failures };
  return row("viewport",
    hand.facts.paired_subject === "local" && hand.facts.renewed_after_rotation && hand.facts.at_c === "unpaired" &&
      failures.length === 0,
    "at 720×720: a glass paired locally, reconnected under a renewed certificate after the rotation, and opened at a home that holds no device of it, every control 24×24 CSS px or more, text 12 px or more, nothing overflowing",
    record.viewport);
}

async function main(browser, proxy) {
  const deskContext = await signedIn(browser, A, cookieA);
  const desk = await deskContext.newPage();
  const deskAuthenticator = await virtualAuthenticator(desk);
  const phoneContext = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await phoneContext.addInitScript(instrumentDevice);
  const phone = await phoneContext.newPage();

  if (!(await firstPasskey(desk, deskAuthenticator, A, segmentA, "passkey"))) return;
  const [paired, device] = await pairLocally(desk, phone);
  if (!paired) return;
  const hand = await handheldPairs(browser, desk);
  const [enrolled, kit1] = await enroll(desk, proxy);
  if (!enrolled) return;
  const [added, kit2] = await secondKit(desk, proxy, kit1);
  if (!added) return;
  const handBefore = await storedDevice(hand.page);
  if (!(await rotate(desk, phone, device))) return;
  await handheldReconnects(hand, handBefore);
  if (!(await cache())) return;

  // A thief takes a copy of A as it stands.
  record.preserved = await ask({ op: "preserve_a" });

  // C, configured for one restore: its first door is refused before any kit.
  const reserved = await ask({ op: "c_first_sign_in" });
  record.reserved = reserved;
  if (!row("reserved", reserved.refused === "restore_reserved",
    "C, an empty installation configured for restore, refuses its first door sign-in before any kit is presented", reserved)) return;

  // C's token and kit 2, handed to run.sh, which posts with them as the
  // browser does; neither stays in an ask or an answer.
  const tokenC = (await ask({ op: "token", cell: "c" }, { secret: true })).token;
  secrets.push(tokenC);
  const claims = await ask({ op: "c_claims", kit: kit2 }, { secret: true });
  record.claims = claims;
  if (!row("claims", claims.other_token === 401 && claims.unknown_kit === 422 && claims.wrong_seed === 422 && claims.attempts === 0,
    "C's own token alone opens it: another cell's token, an unknown identity and a seed that is no kit of it are refused, and nothing is claimed", claims)) return;

  const phases = await ask({ op: "c_phases", kit: kit2 }, { secret: true, timeoutMs: 900_000 });
  record.phases = phases;
  if (!row("phases",
    phases.submitted.status === 503 && phases.submitted.phase === "submitted" &&
      phases.accepted.status === 503 && phases.accepted.phase === "accepted" &&
      phases.minted.status === 503 && phases.minted.phase === "minted" &&
      phases.recoveries === 1,
    "C killed at submitted (its reply lost), at accepted (its head unread) and at minted (its athanor refused) resumes each time under the same request, and the directory holds one recovery",
    phases)) return;
  if (!row("replay", phases.replay.entry_hash && phases.replay.entry_hash === phases.accepted.entry_hash,
    "the recovery's request sent again returns its recorded outcome, and nothing new is recorded", phases.replay)) return;
  if (!row("thief", phases.thief.won === false && phases.thief.later_refused,
    "a thief rotating on a copy of A, concurrently, loses: the recovery's keys hold, and a rotation after it is refused", phases.thief)) return;

  const cContext = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const cPage = await cContext.newPage();
  const cAuthenticator = await virtualAuthenticator(cPage);
  if (!(await restoredHome(cPage, proxy, C, "C", tokenC, kit2, "restore"))) return;

  const observed = await ask({ op: "b_observes", cell: "c" }, { timeoutMs: 300_000 });
  record.b_observes = observed;
  if (!row("b_observes", observed.observed && observed.seconds <= observed.bound + observed.slack,
    "B, holding only a directory cache, observes C's new head within its freshness bound (and the one poll of B that saw it)", observed)) return;

  // The restored person on C: their first passkey's window does not slide
  // with use; a reproof opens a new one; then a door is linked.
  const { segment: segmentC, waited } = await ask({ op: "c_window" });
  const settingsC = settingsOf(C, segmentC);
  const until = Date.now() + waited * 1000;
  while (Date.now() < until) {
    await open(cPage, settingsC);
    await sleep(3_000);
  }
  await open(cPage, settingsC);
  await cPage.locator('[data-test="passkey-register"]').click();
  await cPage.waitForFunction(() => /Passkey:/.test(document.body.innerText), null, { timeout: 30_000 });
  const lapsed = await cPage.locator('[data-test="passkey"]').count();
  const reproof = await (async () => {
    await cPage.goto(`${C}/restore`);
    await connected(cPage);
    await cPage.locator('[data-test="restore-token"]').fill(tokenC);
    await cPage.locator('[data-test="restore-identifier"]').fill(kit2.identifier);
    await cPage.locator('[data-test="restore-directory"]').fill(kit2.directory_url);
    await cPage.locator('[data-test="restore-secret"]').fill(kit2.recovery_secret);
    await cPage.locator('[data-test="restore-submit"]').click();
    await cPage.waitForSelector('[data-test="restore-status"][data-state="restored"]', { timeout: 60_000 });
    await cPage.locator('[data-test="restore-reproof"]').click();
    await cPage.waitForSelector('[data-test="restore-status"][data-state="completed"]', { timeout: 60_000 });
    return cPage.locator('[data-test="restore-status"]').getAttribute("data-state");
  })();
  record.window = { refused_after_window: lapsed === 0, reproof };
  if (!row("window", lapsed === 0 && reproof === "completed",
    "past the restore session's window, kept in use, no first passkey registers; the kit proven again under a new challenge opens a new window",
    record.window)) return;
  if (!(await firstPasskey(cPage, cAuthenticator, C, segmentC, "first_passkey"))) return;

  const cookie = (await cContext.cookies(C)).find((c) => c.name === "_cyfr_key");
  const linked = await ask({ op: "c_link_ticket", cookie: cookie.value }, { secret: true });
  await cContext.addCookies([{ ...cookie, value: linked.cookie }]);
  // The page presents the ticket as it loads, and asks for its confirmation.
  await open(cPage, settingsC, { close: false });
  await confirmHere(cPage);
  await flashed(cPage, "Linked github sign-in");
  const doors = await cPage.locator('[data-test="door"]').count();
  record.door = { doors };
  if (!row("door", doors === 1, "the restored person links a door, freshly confirmed with their new passkey", record.door)) return;

  // The glass paired at A is not C's: C holds no paired client, and a
  // glass opening C's page holds no device there.
  const people = await ask({ op: "people", cell: "c" });
  await phone.goto(`${C}/pair`);
  await phone.waitForSelector('[data-test="glass-status"][data-state="unpaired"]', { timeout: 60_000 });
  record.pair_again = { people: people.people };
  if (!row("pair_again", people.people.length === 1 && people.people[0].paired_clients === 0,
    "a restore without the old paired client's row: the glass pairs again", record.pair_again)) return;
  if (!(await handheldElsewhere(hand))) return;

  // A gone: recovery still completes, and a recovery accepted, its reply
  // lost and superseded elsewhere, activates nothing.
  await ask({ op: "a_down" });
  const tokenC2 = (await ask({ op: "token", cell: "c2" }, { secret: true })).token;
  secrets.push(tokenC2);
  const accepted = await ask({ op: "c2_accepted", kit: kit1 }, { secret: true, timeoutMs: 600_000 });
  record.c2_accepted = accepted;
  const tokenC3 = (await ask({ op: "token", cell: "c3" }, { secret: true })).token;
  secrets.push(tokenC3);
  const c3Context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const c3Page = await c3Context.newPage();
  const front = await ask({ op: "front_mark" });
  if (!(await restoredHome(c3Page, proxy, C3, "C3, with A gone", tokenC3, kit2, "without_a"))) return;
  const seen = await ask({ op: "front_since", mark: front.mark, cell: "a" });
  record.without_a = { ...record.without_a, directory_paths_only: seen.directory_only, a_answers: seen.a_answers };
  if (!row("without_a_reach", seen.directory_only && seen.a_answers === false,
    "with A gone, the restore reached the directory alone: no home, and no saved-home list, was asked", record.without_a)) return;

  const superseded = await ask({ op: "c2_resume", tolerate: true }, { timeoutMs: 300_000 });
  record.superseded = superseded;
  if (!row("superseded",
    accepted.status === 503 && accepted.phase === "accepted" && superseded.status === 409 && superseded.error === "superseded" &&
      superseded.phase === "superseded" && superseded.staged === false && superseded.people === 0,
    "C2's recovery, accepted with its reply lost and replaced by C3's, resumes as superseded and activates nothing",
    superseded)) return;

  const observedC3 = await ask({ op: "b_observes", cell: "c3" }, { timeoutMs: 300_000 });
  record.b_observes_again = observedC3;
  if (!row("b_observes_again", observedC3.observed && observedC3.seconds <= observedC3.bound + observedC3.slack,
    "B observes C3's head within its bound (and the one poll that saw it), with A gone", observedC3)) return;

  const down = await ask({ op: "directory_down" }, { timeoutMs: 300_000 });
  record.directory_down = down;
  row("directory_down", down.within.key_epoch && down.past.refused === "identity_stale",
    "with the directory down, B serves the cached head within its bound and pauses past it", down);
}

// ---------------------------------------------------------------------------

let proxy;
try {
  proxy = await startProxy(null, { homes });
} catch (error) {
  console.error(`FAIL: ${error.message.split("\n")[0]}`);
  process.exit(1);
}
const browser = await launchBrowser("chromium", proxy);
const version = browser.version();
console.log(`== chromium ${version}`);
let failure = null;
try {
  await main(browser, proxy);
} catch (error) {
  failure = redact(error.stack || String(error));
  console.error(`FAIL: ${failure}`);
  for (const context of browser.contexts()) {
    for (const page of context.pages()) {
      const text = await page.locator("body").innerText({ timeout: 2_000 }).catch(() => "unread");
      console.error(`  at ${page.url().replace(/#.*/, "#…")}: ${JSON.stringify(redact(text).slice(0, 3000))}`);
      const shown = await layerText(page);
      if (shown && !shown.startsWith("unread")) console.error(`  its layer: ${JSON.stringify(redact(shown).slice(0, 2000))}`);
    }
  }
} finally {
  await browser.close();
  proxy.close();
}

const STEPS = [
  "passkey", "pair", "enroll", "second_kit", "rotate", "cache", "reserved", "claims", "phases", "replay", "thief",
  "restore", "b_observes", "window", "first_passkey", "door", "pair_again", "viewport", "without_a", "without_a_reach",
  "superseded", "b_observes_again", "directory_down",
];
const outcome = (step) => {
  const found = rows.find((r) => r.step === step);
  return found ? (found.held ? "held" : "FAILED") : "not reached";
};
writeFileSync(join(outDir, "identity-proof.json"), redact(JSON.stringify({ chromium: version, rows, record, failure }, null, 2)));
const table = [`| step | chromium ${version} |`, "|---|---|", ...STEPS.map((step) => `| ${step} | ${outcome(step)} |`)];
writeFileSync(join(outDir, "identity-proof.md"), table.join("\n") + "\n");
console.log(table.join("\n"));
if (failure || STEPS.some((step) => outcome(step) !== "held")) {
  console.error("FAIL: a step of the identity proof did not hold");
  process.exit(1);
}
console.log("ok: every step held");
