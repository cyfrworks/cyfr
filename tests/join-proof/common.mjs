// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The join proof, run in the official Playwright image by run.sh against
// `cyfr` releases behind the harness's HTTPS front (README.md): the
// person's home A, the hub H, the directories dir.test (A's) and
// dir2.test (H's), and a fresh installation A2 the person restores onto.
// Each step is one row per browser of the record; the proof fails when a
// row does not hold, and stops at the first row a later one rests on.
//
// Chromium runs every step, and the glass's steps once more at the
// handheld's 720×720 touch viewport (../browser/handheld.mjs). Firefox and
// WebKit offer no virtual authenticator, so they run the sign-in at H, the
// carry between the homes and a second browser profile; each fresh
// confirmation those need is given on a glass paired at A in Chromium.
//
// The homes' part of a step — a fixture's answer, a cell stopped, the
// directory broken on purpose — is run.sh's, asked for through OUT_DIR
// (`ask-N.json`, answered `answer-N.json`); an ask or answer that carries
// a kit line, a token, a cookie or a confirmation's secret is deleted
// once read.
//
// This module holds what every step shares: the homes, the record, the
// asks of run.sh, the browsers' helpers and the steps up to the
// sign-ins; proof.mjs runs them and steps.mjs the rest.

import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { readHomes, sleep, waitFor } from "../browser/lib.mjs";
export { sleep, waitFor };

export const [homesFile, outDir] = process.argv.slice(2);
if (!homesFile || !outDir) {
  console.error("usage: node proof.mjs HOMES_FILE OUT_DIR");
  process.exit(64);
}
mkdirSync(outDir, { recursive: true });

// The run's settings, which run.sh writes beside the asks.
export const SETTINGS = JSON.parse(readFileSync(join(outDir, "join-settings.json"), "utf8"));
export const BROWSERS = SETTINGS.browsers;
export const { homes } = readHomes(homesFile);
export const homeNamed = (name) => homes.find((home) => home.name === name) || (() => { throw new Error(`no home ${name}`); })();
export const A = homeNamed("a").origin;
export const H = homeNamed("h").origin;
export const A2 = homeNamed("a2").origin;
export const HOMES = homes.map((home) => home.host);
export const layer = "#system-layer-dialog";

export const rows = [];
export const record = {};
export const secrets = [];

export function row(step, browser, held, what, detail) {
  rows.push({ step, browser, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step} [${browser}]: ${what} — ${redact(JSON.stringify(detail)).slice(0, 2500)}`);
  return !!held;
}

export function redact(text) {
  return secrets.reduce((out, secret) => (secret ? out.split(secret).join("[secret]") : out), String(text));
}

// The homes' part of a step, asked of run.sh. `secret: true` deletes the
// ask and its answer once read.
let asked = 0;
export async function ask(request, { timeoutMs = 300_000, secret = false } = {}) {
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
// Browsers, contexts and the virtual authenticator
// ---------------------------------------------------------------------------

export const connected = (page) => page.waitForSelector(".phx-connected", { timeout: 60_000 });

export async function closePrompt(page) {
  const close = page.locator(`${layer}[open] [data-test="prompt-dismiss"]`);
  if (await close.count()) {
    await close.click();
    await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, { timeout: 30_000 });
  }
}

export async function open(page, url, { close = true } = {}) {
  await page.goto(url);
  await connected(page);
  if (close) await closePrompt(page);
}

// The person's passkeys, as a synced passkey is: one credential held by
// the authenticators of several of their browsers. Chromium's virtual
// authenticator counts each assertion, and a home refuses a counter that
// did not rise, so before each ceremony the page's copy of every
// credential it holds takes the highest count any copy reached
// (`ready`), and after it that count is read back (`counted`).
const authenticators = new Map();
const highest = new Map();

// A Chromium authenticator for `page`, the harness's options, holding
// `credentials` (another authenticator's, as a synced passkey is).
export async function authenticatorWith(page, credentials = []) {
  const existing = authenticators.get(page);
  if (existing) {
    for (const credential of credentials) {
      await existing.cdp.send("WebAuthn.addCredential", { authenticatorId: existing.id, credential: { ...credential, signCount: highestOf(credential) } });
    }
    return { id: existing.id, credentials: () => held(existing) };
  }
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
  return { id: authenticatorId, credentials: () => held(handle) };
}

const held = async (handle) => (await handle.cdp.send("WebAuthn.getCredentials", { authenticatorId: handle.id })).credentials;
const highestOf = (credential) => Math.max(credential.signCount, highest.get(credential.credentialId) ?? 0);

// Every count any open authenticator reached.
export async function counted() {
  for (const [page, handle] of authenticators) {
    try {
      for (const credential of await held(handle)) highest.set(credential.credentialId, highestOf(credential));
    } catch {
      authenticators.delete(page);
    }
  }
}

// `page`'s copies brought up to the highest count, before a ceremony.
export async function ready(page) {
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

// Every credential `from` holds for the home `host`, with its highest count.
export async function credentialsFor(page, host) {
  await counted();
  const handle = authenticators.get(page);
  return (await held(handle)).filter((c) => c.rpId === host).map((c) => ({ ...c, signCount: highestOf(c) }));
}

// Every context the proof opened, so a failure can say where each page
// stood.
export const contexts = [];

// A fresh browser profile: no cookie, no storage, no saved home.
export async function freshContext(browser, options = {}) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, ...options });
  contexts.push(context);
  return context;
}

// Where every open page stands, its text and its layer's, for a failure.
export async function dumpPages() {
  for (const context of contexts) {
    for (const page of context.pages ? context.pages() : []) {
      const text = await page.locator("body").innerText({ timeout: 2_000 }).catch(() => "unread");
      console.error(`  at ${page.url().replace(/#.*/, "#…")}: ${JSON.stringify(redact(text).slice(0, 2000))}`);
    }
  }
}

// The person's session at `base`, as the release fixture's door leaves
// one (`signedIn` in the harness): the cookie run.sh minted.
export async function addSession(context, base, cookie) {
  await context.addCookies([{
    name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: true, sameSite: "Lax",
  }]);
}

// What a page of one origin holds that a home's code could read: its
// storage of every kind, by key, values elided.
export const storageOf = (page) => page.evaluate(async () => {
  const keys = (store) => { const out = []; for (let i = 0; i < store.length; i++) out.push(store.key(i)); return out; };
  const databases = indexedDB.databases ? (await indexedDB.databases()).map((db) => db.name) : [];
  return { origin: location.origin, local: keys(localStorage), session: keys(sessionStorage), indexeddb: databases, cookie: document.cookie };
});

// Every request one home received that another home's page made, with
// how the browser labelled it: a cross-home request is `cross-site`.
export function crossHome(seen) {
  const homeOf = (value) => {
    try {
      const host = new URL(value).host;
      return HOMES.includes(host) ? host : null;
    } catch {
      return null;
    }
  };
  return seen
    .filter((r) => r.method !== "CONNECT" && r.method !== "UPGRADE" && HOMES.includes(r.host))
    .map((r) => ({ to: r.host, from: homeOf(r.origin) || homeOf(r.referer), site: r.fetch && r.fetch.site, dest: r.fetch && r.fetch.dest, method: r.method, path: new URL(r.url).pathname }))
    .filter((r) => r.from && r.from !== r.to);
}

export function crossSiteHeld(seen) {
  const crossed = crossHome(seen);
  const wrong = crossed.filter((r) => r.site !== "cross-site");
  return { requests: crossed.length, wrong, held: crossed.length > 0 && wrong.length === 0 };
}

// ---------------------------------------------------------------------------
// The glass, watched from inside its own page
// ---------------------------------------------------------------------------

export function instrumentDevice() {
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

export const deviceLog = (page) => page.evaluate(() => (window.__device ? window.__device.log.slice() : []));

export const storedDevice = (page) => page.evaluate(() => new Promise((resolve, reject) => {
  const open = indexedDB.open("cyfr-glass", 1);
  open.onupgradeneeded = () => open.result.createObjectStore("glass");
  open.onerror = () => reject(open.error);
  open.onsuccess = () => {
    const tx = open.result.transaction("glass", "readonly");
    const read = tx.objectStore("glass").get("device");
    const pending = tx.objectStore("glass").get("pending");
    tx.oncomplete = () => resolve({
      device: read.result ? { clientId: read.result.clientId, certificate: read.result.certificate } : null,
      pending: pending.result ? { at: pending.result.at, certify: pending.result.certify } : null,
    });
    tx.onerror = () => reject(tx.error);
  };
}));

export const glassState = (page) => page.locator('[data-test="glass-status"]').getAttribute("data-state").catch(() => null);

// The glass's prompt for the record `ref`, or for the first it shows.
export async function glassPrompt(page, ref = null) {
  const handle = await waitFor(async () => {
    for (const prompt of await page.$$('[data-test="glass-prompt"]')) {
      const shown = await prompt.getAttribute("data-ref");
      if (!ref || shown === ref) return { prompt, ref: shown };
    }
    return null;
  }, { timeoutMs: 60_000, stepMs: 250, what: `the glass's prompt for ${ref || "a record"}` });
  const preview = await handle.prompt.$eval('[data-test="glass-preview"]', (e) => e.textContent);
  const asker = await handle.prompt.$eval('[data-test="glass-asker"]', (e) => e.textContent);
  return { ref: handle.ref, preview, asker };
}

// Confirm, on a glass, the pending change `ref` naming `operation`.
export async function confirmOnGlass(glass, operation, ref = null) {
  const shown = await glassPrompt(glass, ref);
  if (!shown.preview.includes(operation)) throw new Error(`the glass shows ${shown.preview}, not ${operation}`);
  await ready(glass);
  await glass.locator(`[data-test="glass-prompt"][data-ref="${shown.ref}"] [data-test="glass-passkey"]`).click();
  // Confirmed, the record leaves the pending list the glass reads again,
  // and its prompt with it; a refused proof says so in its outcome.
  const prompt = `[data-test="glass-prompt"][data-ref="${shown.ref}"]`;
  const ended = await glass.waitForFunction((selector) => {
    const shownPrompt = document.querySelector(selector);
    if (!shownPrompt) return "gone";
    const outcome = shownPrompt.querySelector('[data-test="glass-outcome"]');
    return outcome ? outcome.getAttribute("data-ok") : null;
  }, prompt, { timeout: 30_000 }).then((handle) => handle.jsonValue());
  if (ended === "false") throw new Error(`the glass's proof for ${shown.ref} was refused`);
  await counted();
  return shown;
}

// The page's own request, confirmed in its system layer with the passkey
// its authenticator holds; answers what the prompt showed.
export async function confirmHere(page) {
  const own = `${layer} [data-test="confirmation"][data-own="true"]`;
  await page.waitForSelector(`${own} [data-test="confirm-passkey"]`, { timeout: 60_000 });
  const preview = await page.locator(`${own} [data-test="confirmation-preview"]`).first().innerText().catch(() => "");
  await ready(page);
  await page.locator(`${own} [data-test="confirm-passkey"]`).click();
  await page.waitForFunction((selector) => !document.querySelector(selector), `${own} [data-test="confirm-passkey"]`, { timeout: 30_000 }).catch(() => null);
  await counted();
  return preview;
}

// Another client's request, confirmed here.
export async function confirmFromHere(page) {
  const other = `${layer} [data-test="confirmation"][data-own="false"]`;
  await page.waitForSelector(`${other} [data-test="confirm-passkey"]`, { timeout: 60_000 });
  const preview = await page.locator(`${other} [data-test="confirmation-preview"]`).first().innerText().catch(() => "");
  await ready(page);
  await page.locator(`${other} [data-test="confirm-passkey"]`).click();
  await page.waitForFunction((selector) => !document.querySelector(selector), `${other} [data-test="confirm-passkey"]`, { timeout: 30_000 }).catch(() => null);
  await counted();
  return preview;
}

export const flashed = (page, text, timeout = 30_000) =>
  page.waitForFunction((t) => document.body.innerText.includes(t), text, { timeout });

// ---------------------------------------------------------------------------
// The sign-in carry, hop by hop
// ---------------------------------------------------------------------------

// At H's sign-in page, the person names their home.
export async function nameHome(page, home) {
  await page.goto(`${H}/login`);
  await connected(page);
  await page.locator("#cyfr-home").fill(home);
  await page.locator('#cyfr-sign-in button[type="submit"]').click();
}

// At the home's sign-in page the carry's fragment waits for the person:
// read what the page kept, then sign in there, by passkey (Chromium) or
// with the session `cookie` the fixture minted.
export async function signInAtHome(page, home, { cookie = null } = {}) {
  await page.waitForURL((url) => url.origin === home && url.pathname === "/login", { timeout: 60_000 });
  await connected(page);
  const kept = await page.evaluate(() => {
    try {
      return JSON.parse(sessionStorage.getItem("cyfr:carry:source") || "null");
    } catch {
      return null;
    }
  });
  if (cookie) {
    await addSession(page.context(), home, cookie);
    await page.goto(`${home}/`);
  } else {
    await passkeySignIn(page, home);
  }
  return kept;
}

// The sign-in page's passkey door, with the passkey this page's
// authenticator holds for the home.
export async function passkeySignIn(page, home) {
  await ready(page);
  await page.locator("#passkey-sign-in [data-webauthn-start]").click();
  await page.waitForURL((url) => url.origin === home && url.pathname !== "/login", { timeout: 60_000 });
  await counted();
}

// The home's `/carry`, its destination filled in from the fragment: Begin.
export async function begin(page, home) {
  await page.waitForURL((url) => url.origin === home && url.pathname === "/carry", { timeout: 60_000 });
  await connected(page);
  await page.waitForFunction((h) => document.getElementById("carry-destination")?.value === h, H, { timeout: 30_000 });
  await page.locator('#carry-begin button[type="submit"]').click();
}

// H shows its code; the person continues to their home with it.
export async function continueAtHub(page) {
  await page.waitForURL((url) => url.origin === H && url.pathname === "/login", { timeout: 60_000 });
  await page.waitForSelector('[data-test="code"]', { timeout: 60_000 });
  const code = (await page.locator('[data-test="code"]').textContent()).trim();
  await page.locator('[data-test="cyfr-continue"]').click();
  return code;
}

// Back at the home, its confirmation of the sign-in: here with the
// passkey, or on the glass.
export async function confirmSignIn(page, home, glass) {
  await page.waitForURL((url) => url.origin === home && url.pathname === "/carry", { timeout: 60_000 });
  await connected(page);
  if (glass) {
    const own = `${layer} [data-test="confirmation"][data-own="true"]`;
    await page.waitForSelector(own, { timeout: 60_000 });
    const ref = await page.locator(own).first().getAttribute("data-ref");
    const preview = await page.locator(`${own} [data-test="confirmation-preview"]`).first().innerText().catch(() => "");
    const shown = await confirmOnGlass(glass, "person.assert", ref);
    return { preview: `${preview} ${shown.preview}`, on: "glass" };
  }
  return { preview: await confirmHere(page), on: "here" };
}

// The callback lands, H admits, and the home sends the person on to H.
export async function admitted(page) {
  await page.waitForURL((url) => url.origin === H && url.pathname !== "/login", { timeout: 90_000 });
  return page.url();
}

// The whole sign-in at H from a fresh profile, naming `home`.
export async function signInAtHub(page, { home = A, cookie = null, glass = null } = {}) {
  await nameHome(page, home);
  const kept = await signInAtHome(page, home, { cookie });
  await begin(page, home);
  const code = await continueAtHub(page);
  const confirmed = await confirmSignIn(page, home, glass);
  const landed = await admitted(page);
  return { kept, code, confirmed, landed };
}

// ---------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------

export async function setUpHome(chromium, proxy) {
  const { cookie, segment } = await ask({ op: "a_cookie" }, { secret: true });
  secrets.push(cookie);
  const deskContext = await freshContext(chromium);
  await addSession(deskContext, A, cookie);
  const desk = await deskContext.newPage();
  await authenticatorWith(desk);
  const settings = `${A}/a/${encodeURIComponent(segment)}/settings`;

  // The first passkey at A, then enrollment and a second kit.
  await open(desk, settings);
  await desk.locator('[data-test="passkey-register"]').click();
  await flashed(desk, "Passkey registered.");
  await counted();
  await open(desk, settings);
  await desk.locator('[data-test="identity-enroll"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="enrollment"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  await confirmHere(desk);
  const kit1 = await readKit(desk);
  await saveKit(desk);
  await desk.waitForSelector('[data-test="identity"][data-enrollment="enrolled"]', { timeout: 30_000 });

  await open(desk, settings);
  await desk.locator('[data-test="identity-add-kit"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="holder"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="recovery-signer"]`).fill(kit1.recovery_secret);
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  await confirmHere(desk);
  const kit2 = await readKit(desk);
  await saveKit(desk);

  // A glass paired at A, which confirms what Firefox and WebKit ask for.
  const glassContext = await freshContext(chromium, { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await glassContext.addInitScript(instrumentDevice);
  const glass = await glassContext.newPage();
  await authenticatorWith(glass, await credentialsFor(desk, new URL(A).host));
  await open(desk, `${A}/a/${encodeURIComponent(segment)}/tinctures`);
  await desk.locator("#shell-devices").click();
  await desk.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="pairing-begin"]`).click();
  await confirmHere(desk);
  await desk.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await desk.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  await closePrompt(desk);
  await glass.goto(link);
  await glass.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });

  const head = await ask({ op: "a_head" });
  record.home = {
    identifier: kit1.identifier, same_identifier: kit2.identifier === kit1.identifier,
    distinct_kits: kit2.recovery_secret !== kit1.recovery_secret, enrollment: head.enrollment,
    a_credentials: (await credentialsFor(desk, new URL(A).host)).length,
    glass: (await storedDevice(glass)).device?.certificate?.subject?.kind,
  };
  const held = row("home", "chromium",
    head.enrollment === "enrolled" && record.home.same_identifier && record.home.distinct_kits &&
      record.home.a_credentials === 1 && record.home.glass === "local",
    "the person enrolls at A with a passkey, adds a second printed kit (person/enroll_holder), and pairs a glass there",
    record.home);
  return { held, desk, deskContext, segment, settings, glass, kit1, kit2, identifier: kit1.identifier };
}

export async function readKit(page) {
  const kit = `${layer} [data-test="recovery-kit"]:not([hidden])`;
  await page.waitForSelector(`${kit} [data-test="kit-secret"]`, { timeout: 60_000 });
  const line = (test) => page.locator(`${kit} [data-test="${test}"]`).textContent();
  const lines = { identifier: await line("kit-identifier"), directory_url: await line("kit-directory"), recovery_secret: await line("kit-secret") };
  secrets.push(lines.recovery_secret);
  return lines;
}

export async function saveKit(page) {
  await page.locator(`${layer} [data-test="recovery-ack"]`).click();
  await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, { timeout: 30_000 });
}

export async function setUpHub(identifier) {
  const hub = await ask({ op: "h_setup", identifier });
  record.hub = hub;
  return [row("hub", "chromium",
    hub.allowed && hub.invited_group && hub.invited_pair && hub.directory === "https://dir2.test" && hub.a_directory === "https://dir.test",
    "H, enrolling at its own directory dir2.test, allows the identifier at its door and invites it to a group athanor and a pair athanor",
    hub), hub];
}

// The assertions the person's home sent back, as their addresses carried
// them: a later step replays one. Kept apart from the record.
export const assertions = [];

export function captureAssertions(page) {
  page.on("framenavigated", (frame) => {
    if (frame !== page.mainFrame()) return;
    const at = frame.url().indexOf("#cyfr=");
    if (at >= 0) assertions.push(frame.url().slice(at + "#cyfr=".length));
  });
}

export async function signIn(browser, name, proxy, { home, identifier, glass, cookie = null, passkeysFrom = null, step = "sign_in" }) {
  const context = await freshContext(browser);
  const page = await context.newPage();
  captureAssertions(page);
  if (passkeysFrom) await authenticatorWith(page, await credentialsFor(passkeysFrom, new URL(home).host));
  const mark = proxy.seen.length;
  const before = (await ask({ op: "h_receipts", identifier })).receipts.length;
  const startStorage = await page.goto(`${H}/login`).then(() => storageOf(page));
  const flow = await signInAtHub(page, { home, cookie, glass });
  const after = await waitFor(async () => {
    const receipts = (await ask({ op: "h_receipts", identifier })).receipts;
    return receipts.length > before ? receipts : null;
  }, { timeoutMs: 30_000, stepMs: 500, what: "H's receipt" }).catch(() => []);
  const person = await ask({ op: "h_person", identifier });
  const storageH = await storageOf(page);
  await page.goto(`${home}/`).catch(() => null);
  const storageA = await storageOf(page).catch(() => null);
  const cross = crossSiteHeld(proxy.seen.slice(mark));
  const keptDestination = !!(flow.kept && flow.kept.transport && /destination=/.test(flow.kept.transport.fragment));
  const codeShownThere = flow.confirmed.preview.includes(flow.code);
  record[`${step}_${name}`] = {
    landed: flow.landed.replace(/#.*/, ""), code: flow.code, code_named_at_home: codeShownThere, confirmed_on: flow.confirmed.on,
    fragment_kept_through_login: keptDestination, admissions: after.length - before,
    provenance: person.provenance, memberships: person.memberships, cross_site: cross,
    saved_homes_at_start: startStorage, storage: { h: storageH, a: storageA },
  };
  return {
    held: row(step, name,
      keptDestination && codeShownThere && after.length - before === 1 && person.provenance === "remote" &&
        person.memberships.length >= 1 && cross.held,
      "a fresh profile opens H by its address, names A, the carry begins at A, the fragment survives A's sign-in, the codes match, and H admits once",
      record[`${step}_${name}`]),
    page, context,
  };
}
