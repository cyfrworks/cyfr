// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The frame sandbox containment proof, run in the official Playwright image
// by run.sh against a `cyfr` release holding the proof's tinctures
// (tinctures/): containment-probe, private and, as a copy, public;
// containment-neighbour, private; and the harness's frame-neighbour, public.
//
// For every browser the image ships, the fixture's person opens the probe
// from the Prism shell, which creates its frame as it creates every frame,
// and the proof drives one attempt at a time inside it
// (`window.__containment.run`). Each attempt belongs to one column of the
// expected-outcome table (README.md) and is asserted there:
//
//   allowed     the bundle's own function works;
//   refused     the attempt reaches nothing: the frame sees a refusal, the
//               recording endpoint records no request, the shell's page
//               stays where it was;
//   disclosure  a route that stays open, asserted to carry nothing the
//               tincture was not given.
//
// Everything stays inside the harness. The recording endpoint listens on
// loopback and is reached, through the harness's proxy, under the name
// `attacker.test`; the tinctures are published into the harness's own
// athanor of the release under test.
//
// The system layer over a malicious fullscreen frame: the fullscreen probe
// (tinctures/fullscreen-probe), which declares fullscreen and pointer lock,
// takes both from a click and asks for them again whenever it loses them,
// holds the screen while a grant prompt and then a confirmation prompt
// open over it. The server's part of each — publishing a layout that
// floats a tincture waiting for its grant, and another session of the
// person asking for a sensitive change — is run.sh's, asked for through
// OUT_DIR (`ask-N.json`, answered `answer-N.json`).
//
// Usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR PUBLIC_NEIGHBOUR_PATH

import { request } from "node:http";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ATTACKER, BROWSERS, SITE, awaitFrame, chromium, firefox, launch, launchBrowser, openShell, signedIn, sleep,
  startProxy, startReceiver, waitFor, webkit,
} from "../browser/lib.mjs";

const TYPES = { chromium, firefox, webkit };
const RECEIVER = `http://${ATTACKER}`;
const NEIGHBOUR = "containment-neighbour";
const SETTLE_MS = 400;

const failures = [];

// One row of the table per probe: its column, what must hold of what the
// frame saw, and the recording endpoint's path that must stay unrecorded.
const bodyOf = (r) => {
  try { return JSON.parse(r.body); } catch (_error) { return null; }
};
const refusedAtAdmission = (r) => r.ok === false && r.stage === "admission";

const EXPECTED = [
  { name: "module_script", column: "allowed", holds: (r) => r.ran === true,
    what: "a module script of the bundle runs" },
  { name: "blob_worker", column: "allowed", holds: (r) => r.ran === true,
    what: "a worker from a blob of the bundle runs" },
  { name: "wasm_instantiate", column: "allowed", holds: (r) => r.instantiated === true,
    what: "a WebAssembly module instantiates" },
  { name: "public_neighbour_script", column: "allowed", holds: (r) => r.ran === true,
    what: "a public tincture's script loads and runs under the loader's grant" },

  { name: "private_neighbour_script", column: "refused", holds: (r) => r.ran === false,
    what: "another private version's script does not load" },
  { name: "form_post", column: "refused", path: "/form", holds: () => true,
    what: "a form POST leaves nothing at the recording endpoint" },
  { name: "top_read", column: "refused", holds: (r) => r.read === false && r.parent_document === false,
    what: "the shell's location and document cannot be read" },
  { name: "top_navigate", column: "refused", path: "/top", holds: () => true, shellStays: true,
    what: "the shell's page cannot be navigated" },
  { name: "opener", column: "refused", holds: (r) => r.opener === null,
    what: "the frame has no opener" },
  { name: "popup", column: "refused", path: "/popup", holds: (r) => r.opened === false,
    what: "the frame opens no window" },
  { name: "fetch_undeclared", column: "refused", path: "/fetch", holds: (r) => r.answered === false,
    what: "a fetch to an undeclared origin is refused before it is sent" },
  { name: "image_beacon", column: "refused", path: "/img", holds: (r) => r.loaded === false,
    what: "an image from an undeclared origin is refused before it is sent" },
  { name: "send_beacon", column: "refused", path: "/beacon", holds: () => true,
    what: "a beacon to an undeclared origin is refused before it is sent" },
  { name: "redirect_fetch", column: "refused", path: "/redirected",
    holds: (r) => r.answered === false || !String(r.url || "").includes(ATTACKER),
    what: "an asset fetch redirected to an undeclared origin is not followed there" },
  { name: "asset_credential_on_data_route", column: "refused", privateOnly: true,
    holds: (r) => r.answered === true && r.status >= 400 && (bodyOf(r) || {}).ok === false,
    what: "the asset credential opens no data route" },
  { name: "undeclared_invoke", column: "refused", holds: refusedAtAdmission,
    what: "a component the declaration does not name is refused at admission" },
  { name: "undeclared_action", column: "refused", holds: refusedAtAdmission,
    what: "a system action the declaration does not name is refused at admission" },
  { name: "undeclared_stream", column: "refused", holds: refusedAtAdmission,
    what: "a stream the declaration does not name is refused at admission" },
  { name: "fullscreen_undeclared", column: "refused", holds: (r) => r.entered === false,
    what: "fullscreen without the declared capability is refused" },
  { name: "cookie_and_storage", column: "refused", holds: (r) => !r.cookie && r.local_storage === false,
    what: "the frame reads no cookie and holds no storage" },
];

function check(condition, browser, phase, name, what, detail) {
  if (!condition) failures.push({ browser, phase, name, what, detail });
  console.log(`${condition ? "ok" : "FAIL"}: ${browser}/${phase}/${name}: ${what}` +
    `${condition ? "" : ` — ${JSON.stringify(detail)}`}`);
  return condition;
}

const redact = (text) => String(text).replace(/\/_s\/[^/]+/g, "/_s/…");
const brief = (result) => {
  const { violations, body, ...rest } = result || {};
  const directives = [...new Set((violations || []).map((v) => v.directive))];
  const out = { ...rest };
  if (directives.length) out.csp = directives;
  return JSON.parse(redact(JSON.stringify(out)));
};

const ready = () => {
  const r = document.getElementById("results");
  return !!r && r.dataset.ready === "yes" && !!window.__containment;
};

const call = (frame, name, args) =>
  frame.evaluate(([n, a]) => window.__containment.run(n, a), [name, args]);

const recorded = (receiver, path) => receiver.log.filter((entry) => entry.path === path);

// The harness answers one asset of the probe itself: a redirect to the
// recording endpoint, carrying the CORS header an asset answer carries.
const redirect = (_req, url) =>
  url.hostname === SITE && url.pathname.endsWith("/moved.json")
    ? [302, { location: `${RECEIVER}/redirected`, "access-control-allow-origin": "*", "content-length": "0" }, ""]
    : null;

// One phase: the probe opened from the shell as `tincture`, every attempt
// driven and asserted.
async function phase(browser, browserName, phaseName, tincture, base, proxy, receiver, segment, cookie, publicNeighbour) {
  proxy.seen = [];
  receiver.log = [];
  const record = { attempts: {} };
  const context = await signedIn(browser, base, cookie);
  try {
    const page = await context.newPage();
    await openShell(page, base, segment, tincture);
    const shellUrl = page.url();
    const { frame, attributes } = await launch(page, tincture);
    await frame.waitForFunction(ready, null, { timeout: 60_000 });

    const sandbox = (attributes.sandbox || "").split(/\s+/).filter(Boolean).sort();
    check(JSON.stringify(sandbox) === JSON.stringify(["allow-scripts"]), browserName, phaseName, "sandbox",
      "a tincture that declares nothing is framed with allow-scripts alone", attributes.sandbox);
    check(!(attributes.allow || "").trim(), browserName, phaseName, "allow",
      "and is allowed no feature", attributes.allow);
    const isPrivate = attributes.src.startsWith("/_s/");
    check(isPrivate === (phaseName === "private"), browserName, phaseName, "address",
      "its page is served at the address its visibility names", redact(attributes.src));
    record.frame = { sandbox: attributes.sandbox, allow: attributes.allow, src: redact(attributes.src) };
    record.origin = await frame.evaluate(() => window.__containment.origin);
    check(record.origin === "null", browserName, phaseName, "origin", "the frame's origin is opaque", record.origin);

    const credential = isPrivate ? attributes.src.split("/")[2] : "none";
    const args = {
      receiver: RECEIVER,
      publicNeighbour: `${publicNeighbour}/neighbour.js`,
      privateNeighbour: `/_s/${credential}/local/${NEIGHBOUR}/1.0.0/neighbour.js`,
      credential,
      ref: `t:local.${NEIGHBOUR}`,
    };

    for (const expected of EXPECTED) {
      if (expected.privateOnly && !isPrivate) {
        record.attempts[expected.name] = { column: expected.column, outcome: "not applicable", detail: "a public tincture's address carries no credential" };
        continue;
      }
      const result = await call(frame, expected.name, args);
      if (expected.path || expected.shellStays) await sleep(SETTLE_MS);
      const reached = expected.path ? recorded(receiver, expected.path) : [];
      const stayed = !expected.shellStays || page.url() === shellUrl;
      const held = result.settled !== false && expected.holds(result) && reached.length === 0 && stayed;
      check(held, browserName, phaseName, expected.name, expected.what,
        { frame: brief(result), reached: reached.length, shell: stayed ? "stayed" : page.url() });
      record.attempts[expected.name] = {
        column: expected.column, outcome: held ? "held" : "FAILED", frame: brief(result),
        recorded: reached.length,
      };
    }

    // ---- a sibling frame, and this frame suspended -----------------------
    const known = new Set(await page.$$eval("iframe[phx-hook=IframeBridge]", (els) => els.map((e) => e.id)));
    const asked = await call(frame, "open_neighbour", args);
    let neighbour = null;
    try {
      neighbour = await awaitFrame(page, known, 20_000);
      await neighbour.frame.waitForFunction(() => !!document.getElementById("messages"), null, { timeout: 20_000 });
    } catch (error) {
      check(false, browserName, phaseName, "open_neighbour", "the shell opened the sibling the frame asked for",
        { asked: brief(asked), error: error.message });
    }

    if (neighbour) {
      // The shell hid this frame to show the sibling, and suspended its
      // credential with it.
      const suspended = await waitFor(async () => {
        const r = await call(frame, "suspended_invoke", args);
        return r.ok === false && /suspend/i.test(r.message || "") ? r : null;
      }, { timeoutMs: 10_000, stepMs: 250, what: "the hidden frame's refusal as suspended" })
        .catch(async () => call(frame, "suspended_invoke", args));
      const held = suspended.ok === false && /suspend/i.test(suspended.message || "");
      check(held, browserName, phaseName, "suspended_invoke",
        "a hidden frame's call is refused as suspended (one member; the suspension made through the shell)",
        brief(suspended));
      record.attempts.suspended_invoke = { column: "refused", outcome: held ? "held" : "FAILED", frame: brief(suspended) };

      // The sibling has its identity once its handshake with the shell is done.
      await neighbour.frame.waitForFunction(() => !!(window.cyfr && window.cyfr.frame), null, { timeout: 30_000 });
      const before = await neighbour.frame.evaluate(() => (window.cyfr ? window.cyfr.frame : null));
      const posted = await call(frame, "sibling_message", args);
      await sleep(SETTLE_MS);
      const arrived = await neighbour.frame.evaluate(() => JSON.parse(document.getElementById("messages").textContent));
      const after = await neighbour.frame.evaluate(() => (window.cyfr ? window.cyfr.frame : null));
      const fromSibling = arrived.filter((m) => !m.from_parent);
      const kept = !!before && before === after && page.url() === shellUrl;
      check(kept, browserName, phaseName, "sibling_message",
        "a post to a sibling's window changes neither the sibling's frame identity nor the shell",
        { posted: brief(posted), arrived: fromSibling, before, after });
      record.attempts.sibling_message = {
        column: "disclosure", outcome: kept ? "held" : "FAILED",
        frame: brief(posted),
        arrived: fromSibling.map((m) => ({ origin: m.origin, keys: Object.keys(m.data || {}) })),
      };
    }

    // ---- a shared credential address -------------------------------------
    if (isPrivate) {
      const directory = attributes.src.slice(0, attributes.src.lastIndexOf("/"));
      const clean = await browser.newContext();
      try {
        const other = await clean.newPage();
        const response = await other.goto(`${base}${directory}/asset.json`);
        const status = response ? response.status() : null;
        const text = response ? await response.text() : "";
        const held = status === 200 && text.includes("containment-probe");
        check(held, browserName, phaseName, "shared_credential_url",
          "a shared credential address serves that version's bytes to whoever holds it", { status });
        record.attempts.shared_credential_url = { column: "disclosure", outcome: held ? "held" : "FAILED", status };
      } finally {
        await clean.close();
      }
    } else {
      record.attempts.shared_credential_url = { column: "disclosure", outcome: "not applicable", detail: "a public tincture's bytes are public" };
    }

    // ---- navigating itself to a foreign origin, last in this frame --------
    // The shell's own policy (`frame-src 'self'`) governs where its frames
    // may navigate, so the navigation reaches nothing.
    await call(frame, "self_navigation", { ...args, target: `${RECEIVER}/nav` }).catch(() => null);
    await sleep(4 * SETTLE_MS);
    const foreign = recorded(receiver, "/nav");
    check(foreign.length === 0 && page.url() === shellUrl, browserName, phaseName, "self_navigation_foreign",
      "a frame's navigation of itself to a foreign origin reaches nothing", { recorded: foreign.length });
    record.attempts.self_navigation_foreign = {
      column: "refused", outcome: foreign.length === 0 ? "held" : "FAILED", recorded: foreign.length,
    };

    // ---- navigating itself within the site origin: the open route ---------
    // A second open of the probe, whose only attempt this is.
    const second = await context.newPage();
    await openShell(second, base, segment, tincture);
    const again = await launch(second, tincture);
    await again.frame.waitForFunction(ready, null, { timeout: 60_000 });
    const ownAgain = await again.frame.evaluate(() => window.location.pathname);
    const mark = proxy.seen.length;
    await call(again.frame, "self_navigation", { ...args, target: `${publicNeighbour}/index.html` }).catch(() => null);
    const arrivedAt = await waitFor(
      () => proxy.seen.slice(mark).find((r) => r.url.includes("carried=") && new URL(r.url).pathname.startsWith(publicNeighbour)),
      { timeoutMs: 10_000, what: "the navigation within the site" }).catch(() => null);
    const carried = arrivedAt ? new URL(arrivedAt.url).searchParams.get("carried") : null;
    // Whether the person's session cookie goes with that navigation is the
    // browser's decision (COOKIE_ON_SITE_NAVIGATION). Where it does, it
    // reaches a route that reads no session (session_blind_page), and the
    // document that lands cannot read it.
    const held = !!arrivedAt && carried === ownAgain && !arrivedAt.referer &&
      arrivedAt.cookie === COOKIE_ON_SITE_NAVIGATION[browserName];
    check(held, browserName, phaseName, "self_navigation_site",
      `a frame may navigate itself within the site, and carries its own address and no referrer; the session cookie goes with it: ${COOKIE_ON_SITE_NAVIGATION[browserName]}`,
      arrivedAt ? { carried: redact(carried), cookie: arrivedAt.cookie, referer: arrivedAt.referer, fetch: arrivedAt.fetch } : "nothing arrived");
    record.attempts.self_navigation_site = {
      column: "disclosure", outcome: held ? "held" : "FAILED",
      carried: arrivedAt ? redact(carried) : null,
      cookie: arrivedAt ? arrivedAt.cookie : null,
      referer: arrivedAt ? arrivedAt.referer : null,
      fetch: arrivedAt ? arrivedAt.fetch : null,
    };

    // ---- navigating itself to a page that reads the session ---------------
    // A third open, whose only attempt this is: the frame navigates itself
    // to the shell's own address. The request may leave with the cookie
    // (the browser's decision, as above); no page of the person's is drawn
    // in the frame, because a Prism page is framed by nothing, and a
    // browser that names the request's destination is answered a refusal
    // before the session is read (frame_request_refused).
    const third = await context.newPage();
    await openShell(third, base, segment, tincture);
    const last = await launch(third, tincture);
    await last.frame.waitForFunction(ready, null, { timeout: 60_000 });
    const shellPath = new URL(shellUrl).pathname;
    const from = proxy.seen.length;
    await call(last.frame, "self_navigation", { ...args, target: shellPath }).catch(() => null);
    const reached = await waitFor(
      () => proxy.seen.slice(from).find((r) => r.url.includes("carried=") && new URL(r.url).pathname === shellPath),
      { timeoutMs: 10_000, what: "the navigation to the shell's page" }).catch(() => null);
    await sleep(4 * SETTLE_MS);
    let drawn = false;
    for (const child of third.frames()) {
      if (child === third.mainFrame()) continue;
      // A frame whose page the browser refused may never answer.
      const seen = await Promise.race([
        child.evaluate(() => !!document.querySelector("[data-phx-main], [data-phx-session]")).catch(() => false),
        sleep(3000).then(() => false),
      ]);
      drawn = drawn || seen;
    }
    const refused = !!reached && !drawn && third.url() === shellUrl;
    check(refused, browserName, phaseName, "self_navigation_session_page",
      "a frame that navigates itself to a page of the person's draws none of it",
      reached ? { drawn, cookie: reached.cookie } : "nothing arrived");
    record.shell_path = shellPath;
    record.attempts.self_navigation_session_page = {
      column: "refused", outcome: refused ? "held" : "FAILED", drawn, cookie: reached ? reached.cookie : null,
    };

    // Nothing of this phase reached the recording endpoint.
    check(receiver.log.length === 0, browserName, phaseName, "recording_endpoint",
      "nothing reached the recording endpoint",
      receiver.log.map((entry) => `${entry.method} ${entry.path}`));
    record.recorded = receiver.log.map((entry) => `${entry.method} ${entry.path}`);
  } finally {
    await context.close();
  }
  return record;
}

// Whether a browser attaches the person's session cookie when a sandboxed
// frame navigates itself to an address of the site. A browser that changes
// its answer fails the proof, so the change is read before it is accepted.
const COOKIE_ON_SITE_NAVIGATION = { chromium: false, firefox: false, webkit: true };

// The page a frame can land on within the site is a tincture's, and its
// route reads no session: it answers the same with the cookie and without.
async function sessionBlind(server, path, cookie) {
  const ask = async (headers) => {
    const response = await fetch(`${server}${path}`, { headers, redirect: "manual" });
    // Every page carries a nonce of its own, in its policy and on its
    // injected script; the comparison is of everything else.
    const policy = response.headers.get("content-security-policy") || "";
    const nonce = (policy.match(/'nonce-([^']+)'/) || [])[1];
    const plain = (text) => (nonce ? text.split(nonce).join("NONCE") : text);
    return {
      status: response.status,
      body: plain(await response.text()),
      sets: response.headers.get("set-cookie"),
      policy: plain(policy),
    };
  };
  const bare = await ask({});
  const signed = await ask({ cookie: `_cyfr_key=${cookie}` });
  const same = bare.status === 200 && signed.status === 200 && bare.body === signed.body &&
    bare.policy === signed.policy && !bare.sets && !signed.sets;
  check(same, "server", "both", "session_blind_page",
    "a tincture's page answers the same with the session cookie and without, and sets none",
    { bare: bare.status, signed: signed.status, same_body: bare.body === signed.body,
      same_policy: bare.policy === signed.policy, sets: !!(bare.sets || signed.sets) });
  return same;
}

// A page that reads the session refuses a request whose destination is a
// frame, before it reads the session, and tells every browser it is framed
// by nothing. Asked of the server, because a browser names a request's
// destination only to a secure origin, which the harness's is not.
function get(server, path, headers) {
  return new Promise((resolve, reject) => {
    const target = new URL(path, server);
    const req = request({ host: target.hostname, port: target.port, path: target.pathname, method: "GET", headers },
      (res) => { res.resume(); res.on("end", () => resolve({ status: res.statusCode, headers: res.headers })); });
    req.on("error", reject);
    req.end();
  });
}

async function frameRequestRefused(server, path, cookie) {
  const signed = { cookie: `_cyfr_key=${cookie}`, accept: "text/html" };
  const framed = await get(server, path, { ...signed, "sec-fetch-dest": "iframe" });
  const plain = await get(server, path, signed);
  const policy = String(plain.headers["content-security-policy"] || "");
  const held = framed.status === 403 && !framed.headers["set-cookie"] && !framed.headers.location &&
    plain.status === 200 && policy.includes("frame-ancestors 'none'") && plain.headers["x-frame-options"] === "DENY";
  check(held, "server", "both", "frame_request_refused",
    "a page of the person's refuses a frame's request before the session, and is framed by nothing",
    { framed: framed.status, plain: plain.status, policy: policy.includes("frame-ancestors 'none'"), options: plain.headers["x-frame-options"] });
  return held;
}

// ---------------------------------------------------------------------------
// The system layer over a malicious fullscreen frame
// ---------------------------------------------------------------------------

// The server's part of a step, asked of run.sh through the output
// directory: `request` written as ask-N.json, its answer read from
// answer-N.json.
let asked = 0;
async function ask(outDir, request, timeoutMs = 90_000) {
  const id = ++asked;
  const answer = join(outDir, `answer-${id}.json`);
  writeFileSync(join(outDir, `ask-${id}.part`), JSON.stringify(request));
  renameSync(join(outDir, `ask-${id}.part`), join(outDir, `ask-${id}.json`));
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(answer)) {
    if (Date.now() > deadline) throw new Error(`run.sh never answered ${JSON.stringify(request)}`);
    await sleep(100);
  }
  return JSON.parse(readFileSync(answer, "utf8"));
}

// In the shell's own document, before any of its scripts: every time a
// dialog is shown modally, which prompt it holds and whether the document
// was fullscreen or pointer-locked at that instant.
function recordShows() {
  if (window !== window.top) return;
  window.__shows = [];
  const show = HTMLDialogElement.prototype.showModal;
  HTMLDialogElement.prototype.showModal = function () {
    const held = this.querySelector("[data-kind]");
    const frames = Array.from(document.querySelectorAll("iframe"));
    window.__shows.push({
      dialog: this.id,
      kind: held ? held.dataset.kind : null,
      fullscreen: !!document.fullscreenElement,
      pointer_lock: !!document.pointerLockElement,
      frames: frames.length,
      frames_hidden: frames.every((f) => getComputedStyle(f).visibility === "hidden" && f.inert),
    });
    return show.call(this);
  };
}

const PROMPTS = [
  { name: "grant_prompt_fullscreen", kind: "grant", request: { op: "grant" },
    what: "a grant prompt opened over a frame holding fullscreen and pointer lock is shown only once every frame is hidden and inert and the page left fullscreen; the frame holds and takes back neither, while it shows or after" },
  { name: "confirmation_prompt_fullscreen", kind: "confirmation", request: { op: "confirmation" },
    what: "a confirmation prompt opened over a frame holding fullscreen and pointer lock is shown only once every frame is hidden and inert and the page left fullscreen; the frame holds and takes back neither, while it shows or after" },
];

// What the shell's document and the frame's own hold now.
async function screenState(page, frame) {
  const top = await page.evaluate(() => {
    const dialog = document.getElementById("system-layer-dialog");
    const held = dialog && dialog.querySelector("[data-kind]");
    const frames = Array.from(document.querySelectorAll("iframe"));
    return {
      fullscreen: !!document.fullscreenElement,
      pointer_lock: !!document.pointerLockElement,
      open: !!(dialog && dialog.open),
      modal: !!(dialog && dialog.matches(":modal")),
      kind: held ? held.dataset.kind : null,
      prompt: dialog && dialog.parentElement ? dialog.parentElement.dataset.promptId || null : null,
      focus_in_prompt: !!(dialog && dialog.contains(document.activeElement)),
      focused: document.activeElement ? (document.activeElement.id || document.activeElement.name || document.activeElement.tagName) : null,
      frames_hidden: frames.length > 0 && frames.every((f) => getComputedStyle(f).visibility === "hidden" && f.inert),
      shows: window.__shows || [],
    };
  });
  const own = await frame.evaluate(() => window.__fullscreen.state()).catch(() => null);
  return { ...top, frame: own };
}

// How long a person's click lets a frame ask for fullscreen without
// another (the browsers' transient activation is about five seconds): the
// prompt opens after it, so the fullscreen the frame asks for again over
// the prompt has no gesture behind it. A frame needs none to take pointer
// lock again in Chromium; the layer hides every frame while its prompt is
// open, and the probe does not ask (README.md's `pointer_lock_retaken`).
const ACTIVATION_MS = 6_000;

// One prompt over the fullscreen frame: the frame takes the screen from a
// click, and the pointer once it is fullscreen; the server opens the
// prompt; the prompt is shown with neither fullscreen nor pointer lock
// held, in the browser's top layer, and stays so while the frame keeps
// asking for both back.
async function promptOverFullscreen(page, frame, browserName, expected, outDir) {
  const clicked = Date.now();
  await frame.click("#take");
  const before = await waitFor(async () => {
    const state = await screenState(page, frame);
    return state.fullscreen && state.frame && state.frame.pointer_lock ? state : null;
  }, { timeoutMs: 5_000, what: "the frame's fullscreen and pointer lock" }).catch(() => screenState(page, frame));

  if (!before.fullscreen || !(before.frame && before.frame.pointer_lock)) {
    // Without the screen and the pointer there is nothing to leave: a
    // browser that grants a frame neither here cannot show the attempt.
    // Chromium must.
    const held = browserName !== "chromium";
    check(held, browserName, "prompts", expected.name, "the frame took fullscreen and pointer lock from a click",
      { fullscreen: before.fullscreen, frame: before.frame });
    if (before.fullscreen) await page.evaluate(() => document.exitFullscreen()).catch(() => null);
    return { column: "refused", outcome: held ? "not applicable" : "FAILED",
      detail: "this browser granted the frame no fullscreen and pointer lock from a click",
      frame: before.frame };
  }

  await sleep(Math.max(0, clicked + ACTIVATION_MS - Date.now()));
  const shown = (await page.evaluate(() => (window.__shows || []).length));
  const answered = await ask(outDir, expected.request);
  await page.waitForFunction((kind) => {
    const dialog = document.getElementById("system-layer-dialog");
    const held = dialog && dialog.querySelector("[data-kind]");
    return !!(dialog && dialog.open && held && held.dataset.kind === kind);
  }, expected.kind, { timeout: 30_000 });

  // The frame keeps asking for both back, and a click aimed at it lands on
  // the prompt's backdrop: nothing it does takes them over the prompt.
  const box = await page.locator("iframe[phx-hook=IframeBridge]").first().boundingBox();
  if (box) await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await sleep(1_500);

  const after = await screenState(page, frame);
  const shows = after.shows.slice(shown).filter((s) => s.dialog === "system-layer-dialog");
  // The page's fullscreen element is what covers a prompt: a hidden frame
  // runs no rendering steps, so the fullscreen element its own document
  // reports is stale until it is shown again, and is recorded, not held.
  const shownHeld = shows.length > 0 &&
    shows.every((s) => !s.fullscreen && !s.pointer_lock && s.frames > 0 && s.frames_hidden) &&
    after.open && after.modal && after.kind === expected.kind &&
    !after.fullscreen && !after.pointer_lock &&
    !!after.frame && !after.frame.pointer_lock;

  // Ended, so the next step starts from no prompt: a grant prompt is
  // dismissed; another client's request is cancelled, so no later page
  // finds it waiting. A pointer the frame still holds would take the
  // click, so it is let go first, as a person's Escape lets it go.
  await frame.evaluate(() => document.exitPointerLock()).catch(() => null);
  if (expected.kind === "confirmation") {
    await page.locator('#system-layer-dialog [data-test="confirm-cancel"]').click();
  } else {
    await page.locator('#system-layer-dialog button[phx-click="dismiss"]').click();
  }
  await page.waitForFunction(() => {
    const dialog = document.getElementById("system-layer-dialog");
    return !(dialog && dialog.open);
  }, null, { timeout: 30_000 });

  // Shown again once the prompt closed, the frame asks for fullscreen with
  // no gesture behind it, and holds neither.
  await sleep(1_500);
  const closed = await screenState(page, frame);
  const closedHeld = !closed.fullscreen && !!closed.frame && !closed.frame.fullscreen && !closed.frame.pointer_lock;

  const held = shownHeld && closedHeld;
  const detail = {
    before: { fullscreen: before.fullscreen, frame_fullscreen: before.frame.fullscreen, frame_pointer_lock: before.frame.pointer_lock },
    shows, after: { fullscreen: after.fullscreen, pointer_lock: after.pointer_lock, open: after.open, modal: after.modal, kind: after.kind },
    frame: after.frame, closed: { fullscreen: closed.fullscreen, frame: closed.frame }, server: answered,
  };
  check(held, browserName, "prompts", expected.name, expected.what, detail);

  return { column: "refused", outcome: held ? "held" : "FAILED", detail };
}

// ---------------------------------------------------------------------------
// A frame that takes the pointer back over the prompt it opened
// ---------------------------------------------------------------------------

const RETAKEN = {
  name: "pointer_lock_retaken",
  what: "a frame that opens a prompt inside its person's gesture takes the pointer back while hidden behind it; still it is hidden and inert, focus is in the prompt, which Tab and Escape operate, Escape ends the lock for good, and nothing the frame does confirms or dismisses the prompt",
};

// An Escape the browser itself reads, as the person's key: Chromium ends a
// pointer lock on it. Playwright's own key press does not reach that
// handling; the DevTools protocol's key event does.
async function browserEscape(cdp) {
  const key = { key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 };
  await cdp.send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...key });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...key });
}

// No document can release a pointer lock another frame holds. The frame
// locks the pointer and asks for a credential prompt in one click; the
// layer hides it, which ends the lock in Chromium, and the frame, still
// holding the click's activation, takes it back while hidden. What holds
// instead is asserted, and whether the frame held the pointer over the
// prompt is recorded as what it is: a limitation.
async function pointerRetaken(page, frame, browserName) {
  if (browserName !== "chromium") {
    return { column: "disclosure", outcome: "not applicable",
      detail: "Escape reaches the browser's own end of a pointer lock here only through Chromium's DevTools protocol" };
  }
  const cdp = await page.context().newCDPSession(page);
  try {
    const shown = (await page.evaluate(() => (window.__shows || []).length));
    await frame.click("#ask");
    await page.waitForFunction(() => {
      const dialog = document.getElementById("system-layer-dialog");
      const held = dialog && dialog.querySelector("[data-kind]");
      return !!(dialog && dialog.open && held && held.dataset.kind === "credential_entry");
    }, null, { timeout: 30_000 });
    await sleep(1_500);

    // 1. Hidden and inert while the prompt shows, and the frame's hold.
    const over = await screenState(page, frame);
    const shows = over.shows.slice(shown).filter((s) => s.dialog === "system-layer-dialog");
    const hiddenHeld = shows.length > 0 && shows.every((s) => s.frames > 0 && s.frames_hidden) && over.frames_hidden &&
      over.open && over.modal && over.kind === "credential_entry";

    // 2. Focus in the prompt, which Tab moves within it.
    const focusBefore = over.focused;
    await page.keyboard.press("Tab");
    const tabbed = await screenState(page, frame);
    const focusHeld = over.focus_in_prompt && tabbed.focus_in_prompt && tabbed.focused !== focusBefore;

    // 4. Nothing the frame does confirms or dismisses the prompt.
    const tried = await frame.evaluate(() => window.__fullscreen.attack());
    await sleep(1_000);
    const attacked = await screenState(page, frame);
    const untouched = attacked.open && attacked.prompt === over.prompt && attacked.kind === "credential_entry" &&
      attacked.frame && attacked.frame.credential === null;

    // 3. Escape ends the lock, and it is not given back without a gesture.
    await browserEscape(cdp);
    await sleep(1_000);
    const escaped = await screenState(page, frame);
    const escapeHeld = !!escaped.frame && !escaped.frame.pointer_lock &&
      (over.frame && over.frame.pointer_lock ? escaped.open && escaped.prompt === over.prompt : true);

    // And the person's keyboard ends the prompt: the frame hears it closed
    // unsaved, and nothing else.
    if (escaped.open) await browserEscape(cdp);
    await page.waitForFunction(() => {
      const dialog = document.getElementById("system-layer-dialog");
      return !(dialog && dialog.open);
    }, null, { timeout: 30_000 });
    const ended = await waitFor(async () => {
      const state = await screenState(page, frame);
      return state.frame && state.frame.credential ? state : null;
    }, { timeoutMs: 10_000, what: "the frame to hear its prompt closed" }).catch(() => screenState(page, frame));
    const closedUnsaved = !!ended.frame && !!ended.frame.credential && ended.frame.credential.saved === false;

    const held = hiddenHeld && focusHeld && untouched && escapeHeld && closedUnsaved;
    const detail = {
      limitation: { held_pointer_over_prompt: !!(over.frame && over.frame.pointer_lock), locks: over.frame && over.frame.locks, lost: over.frame && over.frame.lost },
      hidden_and_inert: { shows, now: over.frames_hidden },
      keyboard: { focus: focusBefore, after_tab: tabbed.focused, in_prompt: [over.focus_in_prompt, tabbed.focus_in_prompt] },
      frame_tried: tried, frame_answers: attacked.frame && attacked.frame.attacks, prompt_untouched: untouched,
      escape: { pointer_lock_after: escaped.frame && escaped.frame.pointer_lock, prompt_open_after_first: escaped.open,
        refusals: escaped.frame && escaped.frame.refusals },
      closed: { credential: ended.frame && ended.frame.credential },
    };
    check(held, browserName, "prompts", RETAKEN.name, RETAKEN.what, detail);
    return { column: "disclosure", outcome: held ? "held" : "FAILED", detail };
  } finally {
    await cdp.detach().catch(() => null);
  }
}

async function prompts(browser, browserName, base, segment, cookie, outDir) {
  const record = { attempts: {} };
  const context = await signedIn(browser, base, cookie);
  await context.addInitScript(recordShows);
  try {
    const page = await context.newPage();
    await openShell(page, base, segment, "fullscreen-probe");
    const { frame, attributes } = await launch(page, "fullscreen-probe");
    await frame.waitForFunction(() => document.getElementById("state")?.dataset.ready === "yes", null, { timeout: 60_000 });
    record.frame = { sandbox: attributes.sandbox, allow: attributes.allow };
    for (const expected of PROMPTS) {
      record.attempts[expected.name] = await promptOverFullscreen(page, frame, browserName, expected, outDir);
    }
    record.attempts[RETAKEN.name] = await pointerRetaken(page, frame, browserName);
  } finally {
    // The layout floats no waiting tincture for the next browser.
    await ask(outDir, { op: "reset" });
    await context.close();
  }
  return record;
}

// The prompts over the fullscreen frame run in Chromium's full build, as
// the harness launches it elsewhere (`launchBrowser`), not the headless
// shell the rest of the proof runs in: the shell keeps a hidden frame's
// pointer lock, where Chrome, and the full build, release it as the frame
// is hidden. Firefox and WebKit run as the rest of the proof does.
async function promptsIn(browser, name, proxy, base, segment, cookie, outDir) {
  if (name !== "chromium") return prompts(browser, name, base, segment, cookie, outDir);
  const full = await launchBrowser("chromium", proxy);
  try {
    const record = await prompts(full, name, base, segment, cookie, outDir);
    return { ...record, build: `chromium ${full.version()} (full build)` };
  } finally {
    await full.close();
  }
}

const NOT_DRIVEN = [
  ["suspended_on_another_member",
    "an action after the frame was suspended on another member: a browser cell runs one member on SQLite, so it is proven in the cluster suite (apps/cyfr/test/cluster/frame_suspension_test.exs), the suspension made on one member and refused at the credential's next use on the other"],
];

async function main() {
  const [server, segment, cookie, outDir, publicNeighbour] = process.argv.slice(2);
  if (!server || !segment || !cookie || !outDir || !publicNeighbour) {
    console.error("usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR PUBLIC_NEIGHBOUR_PATH");
    process.exit(64);
  }
  mkdirSync(outDir, { recursive: true });
  const receiver = await startReceiver();
  const proxy = await startProxy(server, { receiver, answer: redirect });
  const base = `http://${SITE}:${new URL(server).port || 80}`;
  const record = {};
  for (const name of BROWSERS) {
    const browser = await TYPES[name].launch({ proxy: { server: `http://127.0.0.1:${proxy.address().port}` } });
    try {
      console.log(`== ${name} ${browser.version()}`);
      record[name] = { version: browser.version() };
      record[name].private = await phase(browser, name, "private", "containment-probe", base, proxy, receiver, segment, cookie, publicNeighbour);
      record[name].public = await phase(browser, name, "public", "containment-probe-public", base, proxy, receiver, segment, cookie, publicNeighbour);
      record[name].prompts = await promptsIn(browser, name, proxy, base, segment, cookie, outDir);
    } finally {
      await browser.close();
    }
  }
  proxy.close();
  receiver.close();
  const blind = await sessionBlind(server, `${publicNeighbour}/index.html`, cookie);
  const framed = await frameRequestRefused(server, record[BROWSERS[0]].private.shell_path, cookie);
  writeFileSync(join(outDir, "containment-proof.json"),
    JSON.stringify({ record, session_blind_page: blind ? "held" : "FAILED",
      frame_request_refused: framed ? "held" : "FAILED", not_driven: NOT_DRIVEN }, null, 2));

  const names = [...EXPECTED.map((e) => e.name), "suspended_invoke", "self_navigation_foreign",
    "self_navigation_session_page", "sibling_message", "shared_credential_url", "self_navigation_site"];
  const columnOf = (name) =>
    (EXPECTED.find((e) => e.name === name) || {}).column ||
    (["suspended_invoke", "self_navigation_foreign", "self_navigation_session_page"].includes(name) ? "refused" : "disclosure");
  const cell = (b, name) => {
    const p = (record[b].private.attempts[name] || {}).outcome || "not run";
    const q = (record[b].public.attempts[name] || {}).outcome || "not run";
    return `${p} / ${q}`;
  };
  const table = [
    `| attempt | column | ${BROWSERS.map((b) => `${b} ${record[b].version} (private / public)`).join(" | ")} |`,
    `|---|---|${BROWSERS.map(() => "---|").join("")}`,
    ...names.map((name) => `| ${name} | ${columnOf(name)} | ${BROWSERS.map((b) => cell(b, name)).join(" | ")} |`),
    ...PROMPTS.map((p) => `| ${p.name} | refused | ${BROWSERS.map((b) => (record[b].prompts.attempts[p.name] || {}).outcome || "not run").join(" | ")} |`),
    `| ${RETAKEN.name} | disclosure | ${BROWSERS.map((b) => {
      const attempt = record[b].prompts.attempts[RETAKEN.name] || {};
      const limit = attempt.detail && attempt.detail.limitation;
      return `${attempt.outcome || "not run"}${limit ? ` (the frame held the pointer over the prompt: ${limit.held_pointer_over_prompt ? "yes" : "no"})` : ""}`;
    }).join(" | ")} |`,
    `| session_blind_page | disclosure | ${blind ? "held" : "FAILED"} (asked of the server, with the cookie and without) |`,
    `| frame_request_refused | refused | ${framed ? "held" : "FAILED"} (asked of the server, as a frame and not) |`,
    ...NOT_DRIVEN.map(([name, why]) => `| ${name} | not driven | ${why} |`),
  ];
  writeFileSync(join(outDir, "containment-proof.md"), table.join("\n") + "\n");
  console.log(table.join("\n"));

  if (failures.length) {
    console.error(`FAIL: ${failures.length} attempt(s) did not hold their column`);
    for (const f of failures) console.error(`  ${f.browser}/${f.phase}/${f.name}: ${f.what} — ${JSON.stringify(f.detail)}`);
    process.exit(1);
  }
  console.log("ok: every attempt held its column in every browser");
}

main().catch((error) => {
  console.error(`FAIL: ${error.stack || error}`);
  process.exit(1);
});
