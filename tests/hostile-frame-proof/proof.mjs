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
// Usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR PUBLIC_NEIGHBOUR_PATH

import { request } from "node:http";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ATTACKER, BROWSERS, SITE, awaitFrame, chromium, firefox, launch, openShell, signedIn, sleep,
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

const NOT_DRIVEN = [
  ["grant_prompt_fullscreen",
    "fullscreen reacquired while a grant prompt is up: nothing in this proof opens a grant prompt, since its probe declares nothing and the shell offers a grant only to a tincture whose owner profile needs consent again"],
  ["suspended_on_another_member",
    "an action after the frame was suspended on another member: run at one member, the suspension made through the shell (suspended_invoke)"],
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
