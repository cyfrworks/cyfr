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
import { chromium } from "../browser/lib.mjs";
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

  // The browser moves to the setup link, the token in its fragment.
  await page.waitForURL((url) => url.origin === `http://localhost:${homePort}`, { timeout: 30_000 });
  const setupLink = page.url();
  const token = new URL(setupLink).hash.slice(1);
  {
    const url = new URL(setupLink);
    check("the pages moved the browser to the setup link, its token in the fragment alone", url.pathname === "/setup" && /^#[0-9a-f]{64}$/.test(url.hash) && url.search === "", { path: url.pathname, query: url.search, fragment: url.hash.length });
  }
  await heading("Set up CYFR").waitFor({ timeout: 120_000 });

  // An earlier install at this origin can leave the undigested bundle
  // cached. The release must name its own bundle, bypassing that entry.
  await page.evaluate(() => navigator.serviceWorker.ready.then(() => true));
  await page.waitForFunction(() => navigator.serviceWorker.controller !== null);
  await page.evaluate(async () => {
    const cache = await caches.open("cyfr-static-v1");
    await cache.put("/assets/app.js", new Response("window.cachedSetupBundle = true", {
      headers: { "content-type": "text/javascript" },
    }));
  });
  await page.reload();
  check("setup loads the release's bundle despite an older bundle in the service-worker cache",
    await page.evaluate(() => window.cachedSetupBundle !== true));
  await heading("Set up CYFR").waitFor();

  // The setup page reads the token and offers the account's two ways in.
  const create = page.locator('[data-test="setup-create"]');
  await create.waitFor({ timeout: 60_000 });
  check("the setup page offers to sign in with an account or to create one",
    await page.locator('[data-test="setup-sign-in"]').isVisible() && await create.isVisible());
  await screen("setup");

  // "Create your account" sends the browser to the new page of CYFR's
  // directory with CYFR's sign-in request in the fragment. The directory's
  // name is .invalid (compose.yml), so the browser's own router answers
  // for it, with an empty page, and the address the page was sent to is
  // read whole.
  await page.route("https://directory.invalid/**", (route) =>
    route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>directory</title>" }));
  await create.tap();
  await page.waitForURL((url) => url.origin === "https://directory.invalid", { timeout: 30_000 });
  const hop = new URL(page.url());
  const params = new URLSearchParams(hop.hash.slice(1));
  let request = null;
  try {
    request = JSON.parse(Buffer.from(params.get("request") || "", "base64url").toString("utf8"));
  } catch {
    request = null;
  }
  check("the new page is sent CYFR's sign-in request, which names CYFR and returns to its sign-in page",
    hop.pathname === "/account/new" && params.get("name") === "" && request?.purpose === "sign_in" &&
      request.audience === `http://localhost:${homePort}` && request.return === `http://localhost:${homePort}/login` &&
      request.expires_at > Date.now(),
    { path: hop.pathname, purpose: request?.purpose, audience: request?.audience, return: request?.return });
  check("the setup token goes nowhere but CYFR: not in the address the browser was sent to",
    !hop.href.includes(token));
  await page.unroute("https://directory.invalid/**");
  {
    // The browser holds no session: CYFR's root, in the same browser,
    // sends it to sign in.
    const root = await context.newPage();
    await root.goto(`http://localhost:${homePort}/`);
    await root.waitForURL((url) => url.pathname === "/login", { timeout: 60_000 }).catch(() => {});
    check("the browser that went to the account pages is not signed in to CYFR", new URL(root.url()).pathname === "/login", { url: root.url() });
    await root.close();
  }

  // The same link in another browser: nobody was admitted, so it offers
  // the same two ways in.
  const fresh = await browser.newContext(HANDHELD);
  const again = await fresh.newPage();
  await again.goto(setupLink);
  await again.locator('[data-test="setup-create"]').waitFor({ timeout: 60_000 });
  check("the link again, with nobody admitted, offers the same two ways in",
    await again.locator('[data-test="setup-sign-in"]').isVisible());
  await again.screenshot({ path: `${OUT}/setup-again.png` });
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
