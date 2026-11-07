// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The account pages a directory serves (`/account/*`, built from
// apps/cyfr/assets/account), driven as a person drives them, and a CYFR's
// pages that send the browser there and take it back: an account made at
// `/account/new`, a request signed at `/account/sign` (a sign-in, a
// confirmation in the tab the system layer opens), a device added at
// `/account/add`, the recovery code's page `/account/recover` and the
// devices page `/account/devices`. Every passkey is made and used by
// Chromium's virtual WebAuthn authenticator (lib.mjs `virtualAuthenticator`),
// so these are Chromium's alone.
//
// A person's passkeys are held by the proof (`passkeys()`), as their
// platform keeps them: an authenticator lives in one page, so each page a
// ceremony runs in is given one holding every credential the person has,
// and what each authenticator holds is read back after every ceremony.
// One holder is one person: a discoverable assertion picks the one
// credential of the page's host it holds.
//
// The pages show one section of their `main` at a time; each step here
// waits for the section a step leads to, or for the error the page says,
// and answers what it saw. A recovery code the page shows is read as the
// person reads it and joins the proof's `secrets` (lib.mjs `redact`)
// before it is decoded, its secret once decoded.

import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { askHome, virtualAuthenticator, waitFor } from "./lib.mjs";

const STEP_MS = 60_000;

// A person's passkeys: every credential an authenticator of theirs made,
// given to each page `attach` names. `list()` reads them back first.
export function passkeys() {
  const held = new Map();
  const attached = new Map();
  const sync = async () => {
    for (const [page, authenticator] of attached) {
      if (page.isClosed()) {
        attached.delete(page);
        continue;
      }
      const credentials = await authenticator.credentials().catch(() => null);
      if (!credentials) continue;
      for (const credential of credentials) {
        const known = held.get(credential.credentialId);
        if (!known || credential.signCount >= known.signCount) held.set(credential.credentialId, credential);
      }
    }
  };
  return {
    async attach(page) {
      if (attached.has(page)) return attached.get(page);
      await sync();
      const authenticator = await virtualAuthenticator(page);
      for (const credential of held.values()) await authenticator.add(credential);
      attached.set(page, authenticator);
      return authenticator;
    },
    sync,
    async list() {
      await sync();
      return [...held.values()];
    },
  };
}

// The section of `main` the page shows, and the error that section says.
async function shown(page) {
  return page.evaluate(() => {
    const section = [...document.querySelectorAll("main > section")].find((s) => !s.hidden);
    if (!section) return { section: null, error: null };
    const error = [...section.querySelectorAll(".error, #refused-text")]
      .map((e) => (e.hidden ? "" : e.textContent.trim())).find(Boolean);
    return { section: section.id, error: error || null };
  }).catch(() => ({ section: null, error: null }));
}

// The section once it is one of `sections`, or once the one shown says an
// error (with `orError`): `{section, error}`.
async function settle(page, sections, { orError = true, timeoutMs = STEP_MS } = {}) {
  return waitFor(async () => {
    const now = await shown(page);
    if (sections.includes(now.section) || (orError && now.error) || now.section === "refused") return now;
    return null;
  }, { timeoutMs, stepMs: 100, what: `the account page to show ${sections.join(" or ")}` });
}

// The account pages' own recovery code reader: from the checkout beside
// this file, or, in the Playwright container, from the assets it mounts at
// /assets (harness.sh `playwright_run`).
const READER = "account/recovery_code.js";
let reader = null;
function codeReader() {
  if (!reader) {
    const beside = new URL(`../../apps/cyfr/assets/${READER}`, import.meta.url);
    reader = import(existsSync(beside) ? beside.href : pathToFileURL(`/assets/${READER}`).href);
  }
  return reader;
}

// The recovery code `code`, as `where` showed it, decoded:
// `{code, identifier, secret}`, both joined to `secrets` as they are read.
export async function decodeCode(code, secrets, where = "the page") {
  secrets.push(code);
  const { decodeRecoveryCode } = await codeReader();
  const read = await decodeRecoveryCode(code);
  if (read.error) throw new Error(`the recovery code ${where} shows does not read: ${read.error}`);
  secrets.push(read.secret);
  return { code, identifier: read.identifier, secret: read.secret };
}

// The recovery code the page shows (`#code`), read as the person reads it
// (`decodeCode`).
export async function readShownCode(page, secrets) {
  await page.locator("#show-code:not([hidden]) #code").waitFor({ timeout: STEP_MS });
  return decodeCode((await page.locator("#code").textContent()).trim(), secrets);
}

// A key's short code, as a device and the pages show it.
export const shortCode = (kid) => kid.slice("sha256:".length, "sha256:".length + 16);

// ---------------------------------------------------------------------------
// The account pages
// ---------------------------------------------------------------------------

// `url` opened afresh: a page already at the same address but its fragment
// is left first, since a change of fragment alone would not load it again.
async function openAfresh(page, url) {
  if (page.url().split("#")[0] === url.split("#")[0]) await page.goto("about:blank");
  await page.goto(url);
}

// An account made at `/account/new`: at `directory`'s page with `name`
// in its fragment, or, with no directory, on the page the browser was sent
// to (a CYFR's "Create your account", whose request the page answers
// after). `name` typed, "Create your account", the code read
// (`readShownCode`), "I saved it", which makes the passkey and submits.
// Answers the code, the section the page ends on (`done`, or `done-return`
// when a CYFR's request waits) and any error it says.
export async function createAccount(page, keys, { directory = null, name, secrets, timeoutMs = STEP_MS }) {
  await keys.attach(page);
  if (directory) await openAfresh(page, `${directory.origin}/account/new#name=${encodeURIComponent(name)}`);
  else await page.waitForURL((url) => url.pathname === "/account/new", { timeout: timeoutMs });
  const chose = await settle(page, ["choose"], { timeoutMs });
  if (chose.section !== "choose") return { ...chose, code: null };
  await page.locator("#name").fill(name);
  await page.locator("#create").click();
  const codeShown = await settle(page, ["show-code"], { timeoutMs });
  if (codeShown.section !== "show-code") return { ...codeShown, code: null };
  const code = await readShownCode(page, secrets);
  await page.locator("#saved").click();
  const ended = await settle(page, ["done", "done-return", "rename", "policy-again"], { timeoutMs });
  await keys.sync();
  return { ...ended, code };
}

// "Continue to <CYFR>" on the new page's last section: the passkey asked
// once more, and the browser sent to the request's return.
export async function continueToCyfr(page, keys, home, { timeoutMs = STEP_MS } = {}) {
  await keys.attach(page);
  const label = (await page.locator("#continue").textContent()).trim();
  await page.locator("#continue").click();
  const left = await waitFor(async () => {
    if (new URL(page.url()).origin === home.origin) return { left: true };
    const now = await shown(page);
    return now.error ? { left: false, error: now.error } : null;
  }, { timeoutMs, stepMs: 100, what: "the new page to return to the CYFR" });
  await keys.sync();
  return { label, ...left };
}

// The sign page the browser is on, its request signed with the passkey:
// what the page asks ("Sign in to …", "Confirm a change at …", a registry
// operation in words) and whether it returned, or the error it says.
export async function usePasskey(page, keys, { timeoutMs = STEP_MS } = {}) {
  await page.waitForURL((url) => url.pathname === "/account/sign", { timeout: timeoutMs });
  await keys.attach(page);
  const asked = await settle(page, ["ask"], { timeoutMs });
  if (asked.section !== "ask") return { what: null, returned: false, error: asked.error };
  const what = (await page.locator("#what").textContent()).trim();
  await page.locator("#use-passkey").click();
  const outcome = await waitFor(async () => {
    if (new URL(page.url()).pathname !== "/account/sign") return { returned: true, error: null };
    const now = await shown(page);
    return now.error ? { returned: false, error: now.error } : null;
  }, { timeoutMs, stepMs: 100, what: "the sign page to return" });
  await keys.sync();
  return { what, ...outcome };
}

// A device added to the account of the passkey the person picks, at
// `directory`'s `/account/add` with the device's key and short code in the
// fragment, as the device's QR code names it: the code the page shows, and
// the section it ends on (`added`) or the error it says.
export async function addDevice(page, keys, { directory, device, code = shortCode(device.kid), timeoutMs = STEP_MS }) {
  await keys.attach(page);
  await openAfresh(page, `${directory.origin}/account/add#key=${device.pub}&alg=ed25519&kind=device&code=${code}`);
  const asked = await settle(page, ["ask"], { timeoutMs });
  if (asked.section !== "ask") return { ...asked, shown: null };
  const shownCode = (await page.locator("#device-code").textContent()).trim();
  await page.locator("#add").click();
  const ended = await settle(page, ["added"], { timeoutMs });
  await keys.sync();
  return { ...ended, shown: shownCode };
}

// The rows a key list (`#keys`) shows, as their text.
const listed = (page) => page.$$eval("#keys li > span", (els) => els.map((e) => e.textContent.trim()));

// Click the Remove of the row naming `kid`'s short code.
async function removeRow(page, kid) {
  const row = page.locator("#keys li", { hasText: shortCode(kid) });
  if ((await row.count()) !== 1) throw new Error(`the page lists ${await row.count()} rows for the key ${shortCode(kid)}`);
  await row.locator("button").click();
}

// The recovery code's page at `directory`, opened with `code`: `opened`
// (the section it shows, `account`, or the error it says) and what the
// page then offers, each step settling once the directory's log changed
// (`readLog`, `identifier`) or the page said why not:
//   keys()            the rows it lists
//   addCode(secrets)  another code drawn, shown, read and saved, then submitted
//   replace(secrets)  every key replaced: a new code, the account's only one
//   removeKey(kid)    a key removed
//   addPasskey(name)  a new passkey for the account named `name`
export async function recoveryPage(page, keys, { directory, code, identifier, timeoutMs = STEP_MS }) {
  await keys.attach(page);
  await openAfresh(page, `${directory.origin}/account/recover#`);
  await settle(page, ["enter"], { timeoutMs });
  await page.locator("#code-input").fill(code);
  await page.locator("#enter-code").click();
  const opened = await settle(page, ["account"], { timeoutMs });
  const submitted = async (act) => {
    const before = (await readLog(directory, identifier)).length;
    await act();
    const outcome = await waitFor(async () => {
      const now = await shown(page);
      if (now.error) return { done: false, error: now.error };
      const log = await readLog(directory, identifier);
      return log.length > before && now.section === "account" ? { done: true, error: null } : null;
    }, { timeoutMs, stepMs: 200, what: "the recovery page's change to reach the log" });
    await keys.sync();
    return outcome;
  };
  const drawn = async (button, secrets) => {
    await page.locator(button).click();
    const fresh = await settle(page, ["show-code"], { timeoutMs });
    if (fresh.section !== "show-code") return { code: null, ...fresh };
    const next = await readShownCode(page, secrets);
    return { code: next, ...(await submitted(() => page.locator("#saved").click())) };
  };
  return {
    opened,
    keys: () => listed(page),
    addCode: (secrets) => drawn("#add-code", secrets),
    replace: (secrets) => drawn("#replace", secrets),
    removeKey: (kid) => submitted(() => removeRow(page, kid)),
    addPasskey: (name) => submitted(async () => {
      await page.locator("#passkey-name").fill(name);
      await page.locator("#add-passkey").click();
    }),
  };
}

// The devices page at `directory`, opened with the passkey: `opened` and
// `keys()` as `recoveryPage` has them, and `removeKey(kid)`, a key removed
// with the passkey in use, settling once the log changed.
export async function devicesPage(page, keys, { directory, identifier, timeoutMs = STEP_MS }) {
  await keys.attach(page);
  await openAfresh(page, `${directory.origin}/account/devices#`);
  await settle(page, ["ask"], { timeoutMs });
  await page.locator("#open").click();
  const opened = await settle(page, ["list"], { timeoutMs });
  await keys.sync();
  return {
    opened,
    keys: () => listed(page),
    async removeKey(kid) {
      const before = (await readLog(directory, identifier)).length;
      await removeRow(page, kid);
      const outcome = await waitFor(async () => {
        const now = await shown(page);
        if (now.error) return { done: false, error: now.error };
        return (await readLog(directory, identifier)).length > before ? { done: true, error: null } : null;
      }, { timeoutMs, stepMs: 200, what: "the removal to reach the log" });
      await keys.sync();
      return outcome;
    },
  };
}

// ---------------------------------------------------------------------------
// A CYFR's pages
// ---------------------------------------------------------------------------

// Where a CYFR's page left the browser once an answer came back: `landed`
// at `home` off its sign-in, setup and invitation pages, or the error the
// page it stayed on shows.
export async function landing(page, home, { timeoutMs = STEP_MS } = {}) {
  const errors = page.locator('[data-test="sign-in-error"], [data-test="setup-error"], [data-test="invite-error"]');
  return waitFor(async () => {
    const url = new URL(page.url());
    if (url.origin === home.origin && !["/login", "/setup", "/invite"].includes(url.pathname) &&
      !url.pathname.startsWith("/auth/")) return { landed: true, at: url.pathname, error: null };
    if (await errors.count().catch(() => 0)) {
      const error = (await errors.first().innerText().catch(() => "")).trim();
      if (error) return { landed: false, at: url.pathname, error };
    }
    return null;
  }, { timeoutMs, stepMs: 100, what: `the browser to land at ${home.host}` });
}

// A sign-in at `home`: its sign-in page's one button, the sign page's
// passkey, and the landing.
export async function signIn(page, keys, home, { timeoutMs = STEP_MS } = {}) {
  await page.goto(`${home.origin}/login`);
  await page.waitForSelector(".phx-connected", { timeout: timeoutMs });
  await page.locator('[data-test="sign-in"]').click();
  const asked = await usePasskey(page, keys, { timeoutMs });
  if (!asked.returned) return { ...asked, landed: false };
  return { what: asked.what, ...(await landing(page, home, { timeoutMs })) };
}

// A confirmation given with the passkey: `click` makes the page ask (the
// system layer's "Confirm with a passkey", which opens the sign page in a
// new tab), the tab's request is signed, and the tab returns to the CYFR,
// which confirms the record and sends the tab on. Answers what the sign
// page asked and where the tab landed; the tab is closed.
export async function confirmInTab(page, keys, home, click, { timeoutMs = STEP_MS } = {}) {
  const [tab] = await Promise.all([page.context().waitForEvent("page", { timeout: timeoutMs }), click()]);
  try {
    const asked = await usePasskey(tab, keys, { timeoutMs });
    if (!asked.returned) return { ...asked, landed: false };
    return { what: asked.what, ...(await landing(tab, home, { timeoutMs })) };
  } finally {
    await keys.sync();
    await tab.close().catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// The directory's log, as any reader reads it
// ---------------------------------------------------------------------------

// `identifier`'s log at `directory`'s cell (`GET /directory/v1/{id}`,
// every page of it): its status, length and head, each entry's kind, and
// the state its entries leave: the keys listed (kid and kind) and how many
// recovery keys. A refused read answers its status and error alone.
export async function readLog(directory, identifier) {
  const entries = [];
  let after = -1;
  let page;
  for (;;) {
    const answer = await askHome(directory, `/directory/v1/${identifier}${after < 0 ? "" : `?after=${after}`}`);
    if (answer.status !== 200) {
      let error = null;
      try { error = JSON.parse(answer.body).error; } catch { error = null; }
      return { status: answer.status, error, length: 0, head: null, kinds: [], keys: [], recovery: 0 };
    }
    page = JSON.parse(answer.body);
    entries.push(...page.entries);
    if (page.next === null || page.next === undefined) break;
    after = page.next;
  }
  let keys = [];
  let recovery = [];
  for (const entry of entries) {
    if (entry.kind === "genesis") recovery = entry.recovery;
    if (entry.kind === "add_key") keys.push({ kid: entry.key.kid, kind: entry.key.kind });
    if (entry.kind === "remove_key") keys = keys.filter((k) => k.kid !== entry.kid);
    if (entry.kind === "recover") {
      keys = entry.keys.map((k) => ({ kid: k.kid, kind: k.kind }));
      recovery = entry.recovery;
    }
    if (entry.kind === "add_recovery") recovery = entry.recovery;
  }
  return {
    status: 200, error: null, length: page.length, head: page.head, kinds: entries.map((e) => e.kind),
    keys, recovery: recovery.length,
  };
}
