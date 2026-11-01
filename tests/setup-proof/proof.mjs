// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// `cyfr setup`'s pages at the 720×720 touch handheld in Chromium, driven
// by touch as a person drives them (tests/setup-proof/run.sh says the
// cases): `node proof.mjs <local|tailnet> <the address cyfr setup printed>
// <the home's CYFR_PORT>`. Each screen is held to the handheld's checks
// (tests/browser/handheld.mjs) and photographed into /out; a console error
// or a page error on the pages fails the case. The join's link, its
// machine, its approval, the home through Serve and setup's status route
// are asked of run.sh (lib.mjs `ask`). Writes setup-proof-<case>.json to /out and exits
// non-zero when a check fails.

import { writeFileSync } from "node:fs";
import { admissionState, ask, chromium, typeName, waitFor } from "../browser/lib.mjs";
import { HANDHELD, measure, unmet } from "../browser/handheld.mjs";

const [kind, address, homePort] = process.argv.slice(2);
const OUT = "/out";
const pagesOrigin = new URL(address).origin;
const record = { case: kind, checks: [], screens: {}, errors: [] };

function check(what, holds, detail = {}) {
  record.checks.push({ what, holds, ...detail });
  if (!holds) throw new Error(`${what}: ${JSON.stringify(detail)}`);
}

// Whether `reply`, one of run.sh's answers of the status route, is exactly
// the wire's answer `state` at 200.
const reads = (reply, state) => {
  if (reply?.status !== 200) return false;
  const { version, state: read, ...rest } = JSON.parse(reply.body);
  return version === 1 && read === state && Object.keys(rest).length === 0;
};
// Whether `reply` is the route's refusal of a request that is not local.
const refused = (reply) => reply?.status === 403 && JSON.parse(reply.body || "{}").code === "forbidden";

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
    const shown = await page.locator('[data-screen="done"] [data-setup-url]').innerText();
    check("the Done page names the setup link at localhost, its token in the fragment", new RegExp(`^http://localhost:${homePort}/setup#[0-9a-f]{64}$`).test(shown), { shown: shown.replace(/#.*/, "#…") });
    check("the Done page says nothing more for a home on this device", !(await page.locator('[data-screen="done"] [data-tailnet]').isVisible()));
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
    await page.screenshot({ path: `${OUT}/${kind}-setup-name.png` });

    // Before the first person: the route says what a launcher opens.
    {
      const status = await ask({ op: "status" }, { outDir: OUT, timeoutMs: 60_000, refuseError: true });
      check("before the first person the setup token reads open", reads(status.setup, "open"), { status });
      check("before the first person an invalid token reads closed", reads(status.invalid, "closed"), { status });
      check("a browser's Origin is refused the status route", refused(status.origin), { status });
      check("reading the status made no one", status.people === 0, { status });
    }
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
    await page.screenshot({ path: `${OUT}/${kind}-setup-silent.png` });
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
    await again.locator('[data-test="setup-closed"]').waitFor({ timeout: 60_000 });
    check("the link again, once the first person holds a passkey, says setup is closed and starts no ceremony",
      (await again.locator('[data-test="admission-create"]').count()) === 0);
    await again.screenshot({ path: `${OUT}/${kind}-setup-closed.png` });
    await fresh.close();

    // After it: the same token reads closed, as any other does, and the
    // person stands.
    {
      const status = await ask({ op: "status" }, { outDir: OUT, timeoutMs: 60_000, refuseError: true });
      check("once the person holds a passkey the setup token reads closed", reads(status.setup, "closed"), { status });
      check("an invalid token still reads closed, as the spent one does", status.invalid.body === status.setup.body && status.invalid.status === status.setup.status, { status });
      check("a browser's Origin is still refused the status route", refused(status.origin), { status });
      check("reading the status kept the first person, and them alone", status.people === 1, { status });
    }
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
    const shown = await page.locator('[data-screen="done"] [data-setup-url]').innerText();
    check("the Done page names the setup link at the home's ts.net address", new RegExp(`^https://${approved.name.replace(/\./g, "\\.")}/setup#[0-9a-f]{64}$`).test(shown), { shown: shown.replace(/#.*/, "#…") });
    check("the Done page says where that link opens", await page.getByText("This link opens on your phone and laptop on your tailnet, and on this device in a browser that uses CYFR's proxy at 127.0.0.1:1055.").isVisible());
    await screen("done");
    check("Copy link puts the setup link on the clipboard", (await copied("Copy link")) === shown);
    await page.waitForTimeout(4_000);
    check("the pages do not move the browser to a ts.net address", new URL(page.url()).origin === pagesOrigin, { url: page.url() });
    const served = await ask({ op: "served", name: approved.name }, { outDir: OUT, timeoutMs: 120_000, refuseError: true });
    check("the home answers through Serve at its name", served.status === 200, { served });
    const route = await ask({ op: "status_serve", name: approved.name }, { outDir: OUT, timeoutMs: 120_000, refuseError: true });
    check("the setup token reads open on the loopback listener", reads(route.local, "open"), { route });
    check("that token is refused through Serve, on the proxy listener", refused(route.plain), { route });
    check("headers claiming loopback change nothing there", refused(route.claimed), { route });
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
