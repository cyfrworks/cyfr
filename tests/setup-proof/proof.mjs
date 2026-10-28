// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// `cyfr setup`'s pages at the 720×720 touch handheld in Chromium, driven
// by touch as a person drives them (tests/setup-proof/run.sh says the
// cases): `node proof.mjs <local|tailnet> <the address cyfr setup printed>
// <the home's CYFR_PORT>`. Each screen is held to the handheld's checks
// (tests/browser/handheld.mjs) and photographed into /out; a console error
// or a page error on the pages fails the case. The join's link, its
// machine, its approval and the home through Serve are asked of run.sh
// (lib.mjs `ask`). Writes setup-proof-<case>.json to /out and exits
// non-zero when a check fails.

import { writeFileSync } from "node:fs";
import { ask, chromium, waitFor } from "../browser/lib.mjs";
import { HANDHELD, measure, unmet } from "../browser/handheld.mjs";

const [kind, address, homePort] = process.argv.slice(2);
const OUT = "/out";
const pagesOrigin = new URL(address).origin;
const record = { case: kind, checks: [], screens: {}, errors: [] };

function check(what, holds, detail = {}) {
  record.checks.push({ what, holds, ...detail });
  if (!holds) throw new Error(`${what}: ${JSON.stringify(detail)}`);
}

const browser = await chromium.launch();
let page;
try {
  // The clipboard is read back after a Copy button is tapped.
  const context = await browser.newContext({ ...HANDHELD, permissions: ["clipboard-read", "clipboard-write"] });
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
    await page.screenshot({ path: `${OUT}/${kind}-${name}.png` });
  };
  const button = (name) => page.getByRole("button", { name, exact: true });
  // copied taps the Copy button `name` and answers what the clipboard
  // then holds, once the button says it copied.
  const copied = async (name) => {
    await button(name).tap();
    await button("Copied").waitFor({ timeout: 5_000 });
    return page.evaluate(() => navigator.clipboard.readText());
  };
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
  await button("Set up CYFR").tap();
  await heading("How will you reach CYFR?").waitFor();
  {
    const first = await page.locator("button.choice").first().innerText();
    check("Tailscale is the recommended choice, first", first.includes("My phone and laptop, via Tailscale") && first.includes("Recommended"), { first });
  }
  await screen("how");

  // Choosing how CYFR is reached starts it: setup asks for nothing more.
  await page.getByRole("button", { name: kind === "local" ? /Only this device/ : /My phone and laptop/ }).tap();
  await heading("Setting up CYFR").waitFor();
  await screen("progress");

  if (kind === "local") {
    await heading("CYFR is ready").waitFor({ timeout: 600_000 });
    const shown = await page.locator('[data-screen="done"] [data-address]').innerText();
    check("the Done page names the home at localhost", shown === `http://localhost:${homePort}`, { shown });
    check("the Done page says nothing more for a home on this device", !(await page.locator('[data-screen="done"] [data-tailnet]').isVisible()));
    await screen("done");
    await page.waitForURL((url) => url.origin === `http://localhost:${homePort}`, { timeout: 30_000 });
    await heading("Sign in to continue").waitFor({ timeout: 120_000 });
    check("the pages moved the browser to the home's sign-in page", new URL(page.url()).pathname === "/login", { url: page.url() });
    await page.screenshot({ path: `${OUT}/${kind}-home.png` });
  } else {
    const link = page.locator("[data-link]");
    await link.waitFor({ state: "visible", timeout: 300_000 });
    const first = await link.innerText();
    const join = await ask({ op: "join" }, { outDir: OUT, timeoutMs: 240_000, refuseError: true });
    check("the page shows the waiting join's own approval link", first === join.link, { shown: first, join: join.link });
    check("the join asks for the machine cyfr, named under the code", join.hostname === "cyfr" && (await page.locator("#name").inputValue()) === "cyfr", { join: join.hostname });
    const qr = page.locator("[data-qr] svg");
    const box = await qr.boundingBox();
    check("the link is drawn as a QR code at least 240 px wide", !!box && box.width >= 240 && box.height >= 240, { box });
    check("the code draws modules", ((await qr.locator("path").getAttribute("d")) || "").length > 1000);
    await screen("approval");
    check("Copy link puts the approval link on the clipboard", (await copied("Copy link")) === first);

    await page.locator("#name").fill("proofhome");
    await button("Use this name").tap();
    const second = await waitFor(async () => {
      const shown = (await link.isVisible()) && (await link.innerText());
      return shown && shown !== first ? shown : null;
    }, { timeoutMs: 240_000, what: "the new name's approval link" });
    const renamed = await ask({ op: "join", not: join.container }, { outDir: OUT, timeoutMs: 240_000, refuseError: true });
    check("a new name joins again under it, a new link", second === renamed.link && renamed.hostname === "proofhome" && renamed.container !== join.container, { shown: second, join: renamed });
    check("the name under the code is the new one", (await page.locator("#name").inputValue()) === "proofhome");

    const approved = await ask({ op: "approve", container: renamed.container }, { outDir: OUT, timeoutMs: 60_000, refuseError: true });
    check("the stand-in approved the machine", approved.name === "proofhome.proof.ts.net", { approved });
    await page.getByText(`This machine is on your tailnet as ${approved.name}.`).waitFor({ timeout: 120_000 });
    await screen("joined");
    await heading("CYFR is ready").waitFor({ timeout: 600_000 });
    const shown = await page.locator('[data-screen="done"] [data-address]').innerText();
    check("the Done page names the home's ts.net address", shown === `https://${approved.name}`, { shown });
    check("the Done page says where that address opens", await page.getByText("This address opens on your phone and laptop on your tailnet, and on this device in a browser that uses CYFR's proxy at 127.0.0.1:1055.").isVisible());
    await screen("done");
    check("Copy address puts the home's address on the clipboard", (await copied("Copy address")) === shown);
    await page.waitForTimeout(4_000);
    check("the pages do not move the browser to a ts.net address", new URL(page.url()).origin === pagesOrigin, { url: page.url() });
    const served = await ask({ op: "served", name: approved.name }, { outDir: OUT, timeoutMs: 120_000, refuseError: true });
    check("the home answers through Serve at its name", served.status === 200, { served });
  }

  const failing = unmet(record.screens);
  check("every screen meets the handheld's checks", failing.length === 0, { failing });
  check("the pages logged no error", record.errors.length === 0, { errors: record.errors });
  record.passed = true;
} catch (err) {
  record.passed = false;
  record.failure = String(err && err.stack ? err.stack : err);
  if (page) await page.screenshot({ path: `${OUT}/${kind}-failure.png` }).catch(() => {});
} finally {
  await browser.close();
  writeFileSync(`${OUT}/setup-proof-${kind}.json`, JSON.stringify(record, null, 2));
}
if (!record.passed) {
  console.error(record.failure);
  process.exit(1);
}
console.log(`setup proof (${kind}): ${record.checks.length} checks held`);
