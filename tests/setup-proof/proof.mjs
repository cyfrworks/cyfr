// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// `cyfr setup`'s pages at the 720×720 touch handheld in Chromium, driven
// by touch as a person drives them (tests/setup-proof/run.sh says the
// case): `node proof.mjs <the address cyfr setup printed> <CYFR's
// CYFR_PORT>`. Each screen is held to the handheld's checks
// (tests/browser/handheld.mjs) and photographed into /out; a console error
// or a page error on the pages fails the case. Writes setup-proof.json to
// /out and exits non-zero when a check fails.

import { writeFileSync } from "node:fs";
import { admissionState, chromium, typeName } from "../browser/lib.mjs";
import { HANDHELD, measure, unmet } from "../browser/handheld.mjs";

const [address, homePort] = process.argv.slice(2);
const OUT = "/out";
const pagesOrigin = new URL(address).origin;
const record = { checks: [], screens: {}, errors: [] };

function check(what, holds, detail = {}) {
  record.checks.push({ what, holds, ...detail });
  if (!holds) throw new Error(`${what}: ${JSON.stringify(detail)}`);
}

const browser = await chromium.launch();
let page;
try {
  const context = await browser.newContext(HANDHELD);
  page = await context.newPage();
  page.on("console", (m) => {
    if (m.type() !== "error" || new URL(page.url()).origin !== pagesOrigin) return;
    record.errors.push(`console: ${m.text()}`);
  });
  page.on("pageerror", (e) => {
    if (new URL(page.url()).origin === pagesOrigin) record.errors.push(`page: ${e.message}`);
  });

  // screen measures and photographs what shows now as `name`.
  const screen = async (name) => {
    record.screens[name] = await measure(page);
    await page.screenshot({ path: `${OUT}/${name}.png` });
  };
  const button = (name) => page.getByRole("button", { name, exact: true });
  const heading = (name) => page.getByRole("heading", { name, exact: true });

  await page.goto(address);
  await button("Set up CYFR").waitFor();
  const logo = await page.waitForFunction(() => {
    const img = document.querySelector('[data-screen="welcome"] img.logo');
    return img && img.complete && img.naturalWidth > 0 ? img.naturalWidth : 0;
  });
  check("the welcome shows the capybara", (await logo.jsonValue()) === 512);
  await screen("welcome");
  // A desktop's tall window holds the screen in its middle, where the
  // handheld starts it at the top.
  {
    const desktop = await browser.newContext({ viewport: { width: 1280, height: 1600 } });
    const tall = await desktop.newPage();
    await tall.goto(address);
    await tall.getByRole("button", { name: "Set up CYFR", exact: true }).waitFor();
    const top = await tall.evaluate(() => document.querySelector('[data-screen="welcome"]').getBoundingClientRect().top);
    await desktop.close();
    check("a 1280×1600 window holds the welcome below a third of its height", top > 1600 / 3, { top });
  }
  // Set up CYFR starts it: the pages ask nothing, as cyfr init asks
  // nothing.
  await button("Set up CYFR").tap();
  await heading("Setting up CYFR").waitFor();
  check("the pages ask nothing: no field to fill", (await page.locator("input, select, textarea").count()) === 0);
  await screen("progress");

  await heading("CYFR is ready").waitFor({ timeout: 600_000 });
  const shown = await page.locator('[data-screen="done"] [data-setup-url]').innerText();
  check("the Done page names the setup link at localhost, its token in the fragment", new RegExp(`^http://localhost:${homePort}/setup#[0-9a-f]{64}$`).test(shown), { shown: shown.replace(/#.*/, "#…") });
  await screen("done");

  // The browser moves to the setup link, the token in its fragment, and
  // a virtual authenticator holds the passkey the page asks for.
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
  });
  await page.waitForURL((url) => url.origin === `http://localhost:${homePort}`, { timeout: 30_000 });
  const setupLink = page.url();
  {
    const url = new URL(setupLink);
    check("the pages moved the browser to the setup link, its token in the fragment alone", url.pathname === "/setup" && /^#[0-9a-f]{64}$/.test(url.hash) && url.search === "", { path: url.pathname, query: url.search, fragment: url.hash.length });
  }
  await heading("Set up CYFR").waitFor({ timeout: 120_000 });

  // The first screen: the name typed, and the check under it saying the
  // registry did not answer (its name is .invalid, compose.yml), which
  // leaves "Create a passkey" enabled.
  const checked = await typeName(page, "proof", { check: "unavailable" });
  check("the first screen says cyfr.run did not answer the name's check",
    checked === "cyfr.run did not answer, so your name is checked again when you create it.", { checked });
  const create = page.locator('[data-test="admission-create"]');
  check("Create a passkey stays enabled while cyfr.run is silent", await create.isEnabled());
  await page.screenshot({ path: `${OUT}/setup-name.png` });
  await create.tap();

  // The second screen: the person is made, and their registration meets
  // a directory that does not answer (.invalid), so it offers to try
  // again and nothing more.
  const state = await admissionState(page);
  const second = page.locator('[data-test="admission-code"]');
  const says = (await second.innerText()).trim();
  check("the second screen says cyfr.run did not answer and offers to try again",
    state === "silent" && says.includes("cyfr.run did not answer. Try again.") &&
      await page.locator('[data-test="admission-retry"]').isVisible(), { state, says });
  check("the second screen shows no recovery code and no way on into CYFR",
    (await page.locator('[data-test="admission-saved"]').count()) === 0 &&
      ((await page.locator('[data-test="recovery-code"]').allTextContents()).join("").trim() === "") &&
      new URL(page.url()).pathname === "/setup", { url: page.url().replace(/#.*/, "#…") });
  const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
  check("the authenticator holds one passkey, for this CYFR", credentials.length === 1 && credentials[0].rpId === "localhost", { credentials: credentials.map((c) => c.rpId) });
  await page.screenshot({ path: `${OUT}/setup-silent.png` });
  {
    // The browser holds no session: CYFR's root, in the same browser,
    // sends it to sign in.
    const root = await context.newPage();
    await root.goto(`http://localhost:${homePort}/`);
    await root.waitForURL((url) => url.pathname === "/login", { timeout: 60_000 }).catch(() => {});
    check("the browser that made the passkey is not signed in to CYFR", new URL(root.url()).pathname === "/login", { url: root.url() });
    await root.close();
  }

  // The same link in another browser, once the person holds a passkey.
  const fresh = await browser.newContext(HANDHELD);
  const again = await fresh.newPage();
  await again.goto(setupLink);
  await again.waitForURL((url) => url.pathname !== "/setup", { timeout: 60_000 });
  check("the link again, once the first person holds a passkey, goes on to CYFR and starts no ceremony",
    (await again.locator('[data-test="admission-create"]').count()) === 0);
  await again.screenshot({ path: `${OUT}/setup-closed.png` });
  await fresh.close();
  const failing = unmet(record.screens);
  check("every screen meets the handheld's checks", failing.length === 0, { failing });
  check("the pages logged no error", record.errors.length === 0, { errors: record.errors });
  record.passed = true;
} catch (err) {
  record.passed = false;
  record.failure = String(err && err.stack ? err.stack : err);
  if (page) await page.screenshot({ path: `${OUT}/failure.png` }).catch(() => {});
} finally {
  await browser.close();
  writeFileSync(`${OUT}/setup-proof.json`, JSON.stringify(record, null, 2));
}
if (!record.passed) {
  console.error(record.failure);
  process.exit(1);
}
console.log(`setup proof: ${record.checks.length} checks held`);
