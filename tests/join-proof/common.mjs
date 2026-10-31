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
// a recovery code, a token, a cookie or a confirmation's secret is
// deleted once read.
//
// This module holds what every step shares: the homes, the record, the
// asks of run.sh, the browsers' helpers and the steps up to the
// sign-ins; proof.mjs runs them and steps.mjs the rest.

import { mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  admit, ask as askRunSh, instrumentDevice, readCode, readHomes, redact as redactKnown, saveAdmissionCode, saveCode,
  sleep, waitFor,
} from "../browser/lib.mjs";
export { instrumentDevice, sleep, waitFor };

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
// The name the person types on A's first setup screen.
const NAME = "join-a";

export const rows = [];
export const record = {};
export const secrets = [];

export function row(step, browser, held, what, detail) {
  rows.push({ step, browser, held: !!held, what, detail });
  console.log(`${held ? "held  " : "FAILED"} ${step} [${browser}]: ${what} — ${redact(JSON.stringify(detail)).slice(0, 2500)}`);
  return !!held;
}

// What the proof writes, with every secret it handled replaced
// (lib.mjs `redact`).
export const redact = (text) => redactKnown(text, secrets);

// The homes' part of a step, asked of run.sh (lib.mjs `ask`). `secret: true`
// removes the answer once read; run.sh has removed the ask.
export const ask = (request, options) => askRunSh(request, { outDir, timeoutMs: 300_000, refuseError: true, ...options });

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
// The glass, watched from inside its own page (lib.mjs `instrumentDevice`)
// ---------------------------------------------------------------------------

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

// The first press after a prompt opens, on the control `selector` names in
// the system layer. It waits for the dialog to be the document's modal top
// layer and for two animation frames, since no person presses sooner. A
// canvas frame is sandboxed and runs in a process of its own, and Chromium
// may route a press there on hit-testing that still predates the cover:
// the press never reaches the page and focus lands in the frame. Each
// press is watched by a one-time capture listener on the control; one that
// landed in a frame is answered `{ misses }` for the step's record and made
// once more, and a second miss fails the step.
export async function pressInLayer(page, selector) {
  await page.waitForFunction(() => {
    const dialog = document.querySelector("#system-layer-dialog");
    return Boolean(dialog && dialog.open && dialog.matches(":modal"));
  }, null, { timeout: 30_000 });
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  const misses = [];
  while (true) {
    const control = page.locator(`${layer} ${selector}`);
    await control.evaluate((element) => {
      window.__layerPress = false;
      element.addEventListener("click", () => { window.__layerPress = true; }, { capture: true, once: true });
    });
    await control.click();
    const landed = await page.waitForFunction(() => {
      if (window.__layerPress) return "control";
      const active = document.activeElement;
      return active && active.nodeName === "IFRAME" ? `frame ${active.id || active.name || ""}`.trim() : null;
    }, null, { timeout: 5_000 }).then((handle) => handle.jsonValue()).catch(() => null);
    if (landed === "control") return { misses };
    if (landed === null) throw new Error(`a press on ${selector} reached neither the control nor a frame`);
    misses.push(landed);
    if (misses.length === 2) throw new Error(`a press on ${selector} landed in a frame twice: ${misses.join(", ")}`);
  }
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

// At H's sign-in page, the person names their home: "I run my own CYFR",
// then its address.
export async function nameHome(page, home) {
  await page.goto(`${H}/login`);
  await connected(page);
  await page.locator("#cyfr-own-open").click();
  await page.locator("#cyfr-own-entry").fill(home);
  await page.locator('#cyfr-own button[type="submit"]').click();
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
  const deskContext = await freshContext(chromium);
  const desk = await deskContext.newPage();
  await authenticatorWith(desk);

  // A's first person, through A's two setup screens: the name typed and
  // free at the stand-in, a passkey made, the identity registered at
  // dir.test and the name claimed, and the recovery code read and saved,
  // which signs the browser in.
  const { token } = await ask({ op: "setup_token" }, { secret: true });
  secrets.push(token);
  await desk.goto(`${A}/setup#${token}`);
  await connected(desk);
  const { recovery: code1 } = await admit(desk, NAME, secrets, { before: () => ready(desk) });
  await saveAdmissionCode(desk);
  await counted();
  const person = await ask({ op: "a_person" });
  const { segment } = person;
  const settings = `${A}/a/${encodeURIComponent(segment)}/settings`;

  // A second recovery code, approved by the first.
  await open(desk, settings);
  await desk.locator('[data-test="identity-add-code"]').click();
  await desk.waitForSelector(`${layer} [data-test="recovery"][data-kind="holder"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="recovery-signer"]`).fill(code1.code);
  await desk.locator(`${layer} [data-test="recovery-submit"]`).click();
  await confirmHere(desk);
  const code2 = await readCode(desk, secrets);
  await saveCode(desk);

  // A glass paired at A, which confirms what Firefox and WebKit ask for:
  // it makes its key first on A's /pair page and shows its code, which the
  // desktop's pairing is begun for.
  const glassContext = await freshContext(chromium, { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await glassContext.addInitScript(instrumentDevice);
  const glass = await glassContext.newPage();
  await authenticatorWith(glass, await credentialsFor(desk, new URL(A).host));
  const code = await shownCode(glass, A);
  await open(desk, `${A}/a/${encodeURIComponent(segment)}/canvas`);
  await desk.locator("#shell-devices").click();
  await desk.waitForSelector(`${layer} [data-test="pairing"]`, { timeout: 30_000 });
  await desk.locator(`${layer} [data-test="pairing-key-input"]`).fill(code);
  await desk.locator(`${layer} [data-test="pairing-begin"]`).click();
  await confirmHere(desk);
  await desk.waitForSelector(`${layer} [data-test="pairing-link"]`, { timeout: 30_000 });
  const link = await desk.locator(`${layer} [data-test="pairing-link"]`).inputValue();
  await closePrompt(desk);
  await glass.goto(link);
  await glass.waitForSelector('[data-test="glass-status"][data-state="ready"]', { timeout: 60_000 });

  const head = await ask({ op: "a_head" });
  record.home = {
    people: person.people, admission: person.admission, identifier: code1.identifier, a_identifier: head.identifier,
    same_identifier: code2.identifier === code1.identifier,
    distinct_codes: code2.secret !== code1.secret, enrollment: head.enrollment,
    a_credentials: (await credentialsFor(desk, new URL(A).host)).length,
    glass: (await storedDevice(glass)).device?.certificate?.subject?.kind,
  };
  const held = row("home", "chromium",
    person.people === 1 && person.admission === "setup" && head.enrollment === "enrolled" &&
      code1.identifier === head.identifier && record.home.same_identifier && record.home.distinct_codes &&
      record.home.a_credentials === 1 && record.home.glass === "local",
    `the person is set up at A through its two screens as @${NAME} with a passkey, registered at dir.test, adds a second recovery code (person/recovery_code_add), and pairs a glass there`,
    record.home);
  return { held, desk, deskContext, segment, settings, glass, code1, code2, identifier: code1.identifier };
}

// The code a new device's /pair page at `base` shows: the digest of the
// key it made before any invitation, which a pairing is begun for.
export async function shownCode(page, base) {
  await page.goto(`${base}/pair`);
  const shown = page.locator('[data-test="pair-key-code"]');
  await shown.waitFor({ timeout: 30_000 });
  return (await shown.textContent()).trim();
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
