// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The canvas proof, run in the official Playwright image by run.sh against a
// `cyfr` release holding the shipped canvas and the proof's tinctures
// (tinctures/), the canvases written for it and the feed bound for them
// (fixture.exs through run.sh). It establishes, in real browsers, the Prism
// shell's canvases as they are now built: each canvas is an ordinary HTML
// page in a sandboxed iframe, written through `canvas.write` on the vanilla
// template or shipped as a tincture page, driven through the shell's bridge,
// the canvas validation, the shelf's switcher and swipe, and the windows.
//
// For every browser the image ships, the fixture's person opens the shell
// and the proof drives the steps the README names, each recorded by name
// with the browsers it runs on, its observation and its result (STEPS).
// Chromium runs every step; Firefox and WebKit run the browser-behaviour
// steps (`activation`, `rebound_control`, `connection_allowlist`, `policy`).
// A browser that cannot launch fails its steps and is recorded absent, never
// as a pass.
//
// The measurement (Chromium) times 20 frame opens (a switch click to the
// shell's receipt of the live canvas frame's `ready`) and 20 validations (a
// switch click to the shell's receipt of the validation frame's `ready`) on
// `performance.now()` in the shell's document, read through an init script
// (INSTRUMENT) that records the click and wraps the shell's port handlers.
// It changes no message and records nothing of a boot, bearer, argument or
// stream payload. Each number's p95 is held to its budget (BUDGET_MS, the
// values of the canvas budgets ARCHITECTURE.md §6.9 names) for the host
// class the run names, at both viewports, and a record over either fails
// the run.
//
// The containment of a canvas's code against the host page, siblings and
// served versions is the hostile-frame proof's and a separate deliverable's
// (README.md); this proof drives the canvas-specific rows itself in `policy`
// and `connection_allowlist`: the page's served policy, a foreign script
// element, a fetch its `connect-src` refuses, Chromium's connection
// allowlist against a peer connection, the shared data routes' and the data
// path's refusals of a canvas credential, and an `open` carrying arguments.
//
// The server's part of each fixture action is run.sh's, asked for through
// OUT_DIR (`ask-N.json`, answered `answer-N.json`); a request carries the
// command and its non-secret arguments, and run.sh holds the session token.
//
// This proof runs on SQLite only. It makes no PostgreSQL claim and starts
// no execution worker: every feed result it shows is a fixed result the
// fixture accepted. No bearer, token, cookie or credential reaches its
// record: each observation is redacted as it is noted, and the record's own
// checks (`recordChecks`) refuse a record that carries one.
//
// Every browser reaches the release at https://cyfr.test through the
// harness's proxy (tests/browser/lib.mjs), Chromium as its full build,
// which trusts the run's authority, and the attacker's recording endpoint
// at https://attacker.test.
//
// Usage: node proof.mjs SEGMENT COOKIE OUT_DIR VIEWPORT NARROWING HOST_CLASS
//        (NARROWING may be empty; HOST_CLASS is a class of BUDGET_MS)
//    or: node proof.mjs --check-record RECORD_JSON [SECRETS_JSON]

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { hostname, cpus } from "node:os";
import { createSocket } from "node:dgram";
import { request as httpRequest } from "node:http";
// Its asks and redaction only: lib.mjs loads without Playwright's library,
// so the record check runs without a browser.
import { ask as askRunSh, redact as redactKnown } from "../browser/lib.mjs";

// Each step and the browsers it runs on, in the record's order.
const ALL = ["chromium", "firefox", "webkit"];
const STEPS = [
  ["two_canvases", ["chromium"]],
  ["attention_moves", ["chromium"]],
  ["switch", ["chromium"]],
  ["written_canvas", ["chromium"]],
  ["feed_chart", ["chromium"]],
  ["app_over_canvas", ["chromium"]],
  ["window_drag", ["chromium"]],
  ["tile_narrows", ["chromium"]],
  ["covered_windows", ["chromium"]],
  ["frame_kept", ["chromium"]],
  ["hidden_canvas", ["chromium"]],
  ["validation_failures", ["chromium"]],
  ["crash_fallback", ["chromium"]],
  ["activation", ALL],
  ["grant_control", ALL],
  ["rebound_control", ALL],
  ["connection_allowlist", ALL],
  ["policy", ALL],
  ["disconnect", ["chromium"]],
  ["failed_fire", ["chromium"]],
];

// The order a browser runs its steps in. The browser-behaviour steps run on
// the canvases held steady (markets, the probe); the steps on canvas-broken,
// one of which ends in the fallback, and the socket cut and the scheduler's
// fire come last.
const ORDER = [
  "two_canvases", "attention_moves", "switch", "written_canvas", "feed_chart", "app_over_canvas",
  "window_drag", "tile_narrows", "covered_windows", "frame_kept", "hidden_canvas",
  "activation", "grant_control", "rebound_control", "connection_allowlist", "policy",
  "validation_failures", "crash_fallback", "disconnect", "failed_fire",
];

const VIEWPORTS = {
  desktop: { width: 1280, height: 900, posture: "desk", device: "the PC" },
  "720x720": { width: 720, height: 720, posture: "hand", device: "the phone" },
};

const CLOCK = "performance.now() in the shell's document, Chromium";
const SAMPLES = 20;
// The p95 each number must not exceed, in milliseconds, at either viewport,
// by host class: `reference` is the host the budget was stated on, and
// `github-hosted` the GitHub-hosted runner, the same measurement on a slower
// host. A record names its class as it names its viewport.
const BUDGET_MS = {
  reference: { frame_open_ms: 100, validation_ms: 100 },
  "github-hosted": { frame_open_ms: 150, validation_ms: 150 },
};
// A sample with no `ready` within this long fails the run.
const SAMPLE_MS = 10_000;

// ---- the record ----------------------------------------------------------------

const record = { steps: {}, browsers: {}, measurement: {} };
const secrets = [];

// Credentials a browser's sentence or an address may carry, and every
// secret this run knew (lib.mjs `redact`).
const redact = (text) => redactKnown(text, secrets);

const redacted = (value) => JSON.parse(redact(JSON.stringify(value === undefined ? null : value)));

// One observation of a step in one browser: `held` false fails the run.
function note(step, browser, held, observation) {
  const entry = record.steps[step] || (record.steps[step] = { on: browsersOf(step), browsers: {} });
  entry.browsers[browser] = { result: held ? "held" : "FAILED", observation: redacted(observation) };
  console.log(`${held ? "held  " : "FAILED"} ${step} [${browser}] ${redact(JSON.stringify(observation)).slice(0, 900)}`);
  return held;
}

// A browser that could not launch: its steps are absent, never a pass.
function absent(step, browser, why) {
  const entry = record.steps[step] || (record.steps[step] = { on: browsersOf(step), browsers: {} });
  entry.browsers[browser] = { result: "absent", observation: null, why: redact(why).slice(0, 300) };
  console.log(`absent ${step} [${browser}] ${redact(why).slice(0, 300)}`);
}

const browsersOf = (step) => (STEPS.find(([name]) => name === step) || [null, []])[1];

// ---- the record's own checks ---------------------------------------------------

// The budget row of a host class, or null for a class the table lacks.
function budgetOf(hostClass) {
  return typeof hostClass === "string" && Object.hasOwn(BUDGET_MS, hostClass) ? BUDGET_MS[hostClass] : null;
}

const hasObservation = (value) =>
  value !== null && value !== undefined && (typeof value !== "object" || Object.keys(value).length > 0);

// Each check the record must pass, as the failure cases name them; every
// sentence returned is a failure.
function recordChecks(rec, knownSecrets = []) {
  const fails = [];
  const text = JSON.stringify(rec);

  if (rec.narrowed) fails.push("the record is of a narrowed run, not the proof's whole matrix");

  // A step reported without its observation, and a browser's absence shown
  // as a pass.
  for (const [step, browsers] of STEPS) {
    const entry = rec.steps && rec.steps[step];
    if (!entry) {
      fails.push(`step ${step} has no result`);
      continue;
    }
    for (const browser of browsers) {
      const one = entry.browsers && entry.browsers[browser];
      if (!one) {
        fails.push(`step ${step} [${browser}] has no result`);
        continue;
      }
      const launched = rec.browsers && typeof rec.browsers[browser] === "string" && rec.browsers[browser] !== "";
      if (!launched && one.result !== "absent") fails.push(`step ${step} [${browser}] reports a browser that never launched as ${one.result}`);
      if (one.result === "absent" && launched) fails.push(`step ${step} [${browser}] is absent in a browser that launched`);
      if (one.result !== "absent" && !hasObservation(one.observation)) fails.push(`step ${step} [${browser}] is ${one.result} with no observation`);
      if (!["held", "FAILED", "absent"].includes(one.result)) fails.push(`step ${step} [${browser}] has no result the proof knows: ${one.result}`);
    }
  }

  // A measurement reported without its date, host and sample counts.
  const m = rec.measurement || {};
  if (!rec.date || !m.date) fails.push("the record carries no date");
  if (!rec.host || !rec.host.name || !rec.host.cpu || !m.host || !m.host.name || !m.host.cpu) {
    fails.push("the record carries no host (name and CPU)");
  }
  if (!rec.host || !Number.isInteger(rec.host.cores) || !m.host || !Number.isInteger(m.host.cores)) {
    fails.push("the record carries no core count");
  }
  if (!m.counts || !Number.isInteger(m.counts.open) || !Number.isInteger(m.counts.validation)) {
    fails.push("the measurement carries no sample counts");
  }
  if (!m.clock) fails.push("the measurement names no clock");

  // A p95 over its class's budget, or none to hold to it. The budget is
  // this file's, never the record's own; the class is the record's, and a
  // record naming no class, or one the table lacks, has no budget to pass.
  const hostClass = rec.host && rec.host.class;
  const budget = budgetOf(hostClass);
  if (!budget) {
    fails.push(hostClass === undefined || hostClass === null || hostClass === ""
      ? "the record names no host class, so no budget holds its measurement"
      : `the record names the host class ${JSON.stringify(hostClass)}, which has no budget`);
  } else if (!m.host || m.host.class !== hostClass) {
    fails.push(`the measurement's host class is not the record's, ${hostClass}`);
  }
  for (const [key, label] of [["frame_open_ms", "frame open"], ["validation_ms", "validation"]]) {
    if (!budget) break;
    const p95 = m[key] && m[key].p95;
    if (typeof p95 !== "number" || !Number.isFinite(p95)) {
      fails.push(`the measurement has no ${label} p95 to hold to the ${hostClass} budget of ${budget[key]} ms`);
    } else if (p95 > budget[key]) {
      fails.push(`the ${label} p95 is ${p95} ms at ${m.viewport || rec.viewport} on the ${hostClass} class, over its budget of ${budget[key]} ms`);
    }
  }

  // A PostgreSQL claim.
  if (/postgres/i.test(text)) fails.push("the record carries a PostgreSQL claim");
  if (rec.adapter !== "sqlite") fails.push(`the record names the adapter ${rec.adapter}`);

  // A fixed feed result reported as an executed run.
  if (rec.executed_runs !== 0) fails.push("the record claims executed runs");
  if (rec.feed_results !== "fixed") fails.push("the record does not say its feed results are fixed");
  for (const [step, entry] of Object.entries(rec.steps || {})) {
    for (const [browser, one] of Object.entries(entry.browsers || {})) {
      if (/"executed":true/.test(JSON.stringify(one.observation))) {
        fails.push(`step ${step} [${browser}] reports a feed result as an executed run`);
      }
    }
  }
  const chart = rec.steps && rec.steps.feed_chart && rec.steps.feed_chart.browsers && rec.steps.feed_chart.browsers.chromium;
  if (chart && chart.result === "held" && !(chart.observation && chart.observation.executed === false)) {
    fails.push("feed_chart does not say its result is a fixed one");
  }
  const fire = rec.steps && rec.steps.failed_fire && rec.steps.failed_fire.browsers && rec.steps.failed_fire.browsers.chromium;
  if (fire && fire.observation && typeof fire.observation.runs === "number" && fire.observation.runs !== 0) {
    fails.push("failed_fire records a run that executed");
  }

  // Any credential value.
  for (const s of knownSecrets || []) {
    if (s && text.includes(s)) fails.push("the record carries a credential value");
  }
  if (/\/_s\/(?!\[credential\])[^/"'\s]/.test(text) || /\/_c\/v1\/(?!\[credential\])[^/"'\s]/.test(text)) {
    fails.push("the record carries an asset credential");
  }
  if (/SFMyNTY\./.test(text)) fails.push("the record carries a signed token");
  if (/Bearer\s+(?!\[secret\])\S/i.test(text)) fails.push("the record carries a bearer");

  return [...new Set(fails)];
}

// ---- asks of run.sh ------------------------------------------------------------

let OUT = null;
let sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const ask = (request, options) => askRunSh(request, { outDir: OUT, timeoutMs: 60_000, ...options });

const OK = (answer) => answer && typeof answer === "object" && answer.ok && typeof answer.ok === "object";

async function versions(canvas) {
  const answer = await ask({ op: "versions", canvas });
  if (!OK(answer)) throw new Error(`the versions of ${canvas} could not be read: ${JSON.stringify(answer)}`);
  return { ...answer.ok.document, revision: answer.ok.revision };
}

async function feedState(feed) {
  const answer = await ask({ op: "state", feed });
  if (!answer || typeof answer.live !== "boolean") throw new Error(`the state of feed ${feed} could not be read: ${JSON.stringify(answer)}`);
  return answer;
}

// ---- the instrument (the shell's document) ---------------------------------------
//
// An init script on the shell's page alone (a frame's document is left as
// it is). It records performance.now() in a capture-phase click on a
// switcher button, which runs before LiveView's handler pushes
// `switch_canvas`, and wraps MessagePort.prototype's onmessage setter, so a
// handler the shell's bridge sets is called through a wrapper that first
// records, for each message a frame posts the shell, performance.now() with
// the message's verb and frame, whether the shell document holds transient
// user activation, whether the canvas's iframe is the document's active
// element, and whether the bridge dropped that message (its frame's
// data-dropped moved as the handler ran). It counts the messages it saw and
// the ones it handed on, records each load of a frame's iframe (a
// capture-phase load on the document, since a load's path stops short of
// the window, seen before the bridge's own handler counts it) with the
// frame and its place (`data-canvas-place`), and records, in a
// capture-phase listener, what the canvas hook tells each canvas frame is
// covered (the `cyfr:to-canvas` events on the frame's element whose verb
// is `covered`): nothing else.
const INSTRUMENT = `(() => {
  if (window.top !== window) return;
  const marks = { clicks: [], receipts: [], loads: [], seen: 0, handed: 0, covered: [] };
  Object.defineProperty(window, "__canvasInstrument", { value: marks, configurable: true });
  const frameEl = (id) => {
    try { return document.querySelector('iframe[data-frame-id="' + (window.CSS ? CSS.escape(id) : id) + '"]'); }
    catch (_error) { return null; }
  };
  const droppedOf = (el) => (el ? Number(el.dataset.dropped || "0") : null);
  document.addEventListener("load", (event) => {
    const el = event.target;
    if (el && el.tagName === "IFRAME" && el.dataset && el.dataset.frameId)
      marks.loads.push({ at: performance.now(), frame: el.dataset.frameId, place: (el.closest("[data-canvas-place]") || { dataset: {} }).dataset.canvasPlace || null });
  }, true);
  window.addEventListener("click", (event) => {
    const target = event.target && event.target.closest
      ? event.target.closest("#canvas-switcher button[data-canvas]") : null;
    if (target) marks.clicks.push({ at: performance.now(), canvas: target.getAttribute("data-canvas") });
  }, true);
  window.addEventListener("cyfr:to-canvas", (event) => {
    const detail = event.detail;
    if (!detail || detail.verb !== "covered" || !event.target || !event.target.dataset) return;
    marks.covered.push({ frame: event.target.dataset.frameId, rects: (detail.args && detail.args.rects) || [] });
  }, true);
  const proto = (typeof MessagePort === "function") && MessagePort.prototype;
  const desc = proto && Object.getOwnPropertyDescriptor(proto, "onmessage");
  if (desc && desc.set && desc.get) {
    Object.defineProperty(proto, "onmessage", {
      configurable: true,
      enumerable: desc.enumerable,
      get() { return desc.get.call(this); },
      set(handler) {
        if (typeof handler !== "function") return desc.set.call(this, handler);
        const wrapped = function (event) {
          marks.seen += 1;
          const data = event && event.data;
          let receipt = null;
          let el = null;
          let before = null;
          if (data && typeof data === "object" && typeof data.verb === "string" && typeof data.frame === "string") {
            el = frameEl(data.frame);
            before = droppedOf(el);
            const ua = navigator.userActivation;
            receipt = {
              at: performance.now(), verb: data.verb, frame: data.frame,
              kind: el ? (el.dataset.frameKind || null) : null,
              active: !!(ua && ua.isActive === true),
              activeElementIsFrame: el !== null && document.activeElement === el,
              dropped_before: before,
            };
            marks.receipts.push(receipt);
          }
          try {
            return handler.call(this, event);
          } finally {
            marks.handed += 1;
            if (receipt) {
              const after = droppedOf(frameEl(data.frame));
              receipt.dropped_after = after;
              receipt.dropped = before !== null && after !== null ? after > before : null;
            }
          }
        };
        return desc.set.call(this, wrapped);
      },
    });
  }
})();`;

const instrument = (page) =>
  page.evaluate(() => {
    const m = window.__canvasInstrument;
    return m ? { clicks: [...m.clicks], receipts: [...m.receipts], loads: [...m.loads], seen: m.seen, handed: m.handed, covered: [...m.covered] } : null;
  });

// The instrument's receipts after index `from`, of `frame` and `verb`.
const receiptsOf = (marks, from, frame, verb) =>
  marks.receipts.slice(from).filter((r) => (!frame || r.frame === frame) && (!verb || r.verb === verb));

// The receipts of `frame`'s `verb` after index `from`, read once the shell
// has handled `count` of them (or 5 s have passed) and 600 ms more, so any
// beyond them is counted too.
async function handled(page, from, frame, verb, count) {
  await lib.waitFor(async () => receiptsOf(await instrument(page), from, frame, verb).filter((r) => r.dropped !== undefined).length >= count || null,
    { timeoutMs: 5_000, stepMs: 50, what: `the shell's receipt of ${count} ${verb}` }).catch(() => null);
  await sleep(600);
  return receiptsOf(await instrument(page), from, frame, verb);
}

// What the shell did with receipts of one verb: how many it received,
// forwarded and dropped, and, for the last, whether it held activation and
// the canvas's frame was its active element.
function receiptFacts(receipts) {
  const last = receipts[receipts.length - 1] || null;
  return {
    received: receipts.length,
    forwarded: receipts.filter((r) => r.dropped === false).length,
    dropped: receipts.filter((r) => r.dropped === true).length,
    active: last && last.active,
    active_element_is_frame: last && last.activeElementIsFrame,
  };
}

// A person's click at (x, y), the viewport point a frame's element was
// measured at, in the frame with id `frame`: the button goes down there and
// comes up once the shell's document holds that frame as its active
// element, or after 2 s, as a person's click comes up a moment after it
// lands. Playwright's own click sends the button's down and up at once. In
// Chromium the canvas's frame runs in a process of its own, and the shell
// learns that the click focused it by way of the browser process, which on
// a loaded host can come after the verb the page sends over its port from
// the click handler; the bridge forwards an `open` or a `press` only from
// the frame that is the shell's active element, so it drops that verb. Only
// the shell's document is read while the button is down; nothing is
// evaluated on the frame, and the page sends its verb from its own click
// handler. Answers whether the shell held the frame as its active element
// before the button came up.
async function personClick(page, frame, x, y) {
  await page.mouse.move(x, y);
  await page.mouse.down();
  const focused = await lib.waitFor(
    () => page.evaluate((id) => {
      const el = document.activeElement;
      return el !== null && el.tagName === "IFRAME" && el.getAttribute("data-frame-id") === id;
    }, frame).catch(() => false),
    { timeoutMs: 2_000, stepMs: 10, what: "the shell's focus on the frame clicked" },
  ).then(() => true, () => false);
  await page.mouse.up();
  return focused;
}

// The center of `locator` in the page's viewport, scrolled into view.
async function centerOf(locator) {
  await locator.scrollIntoViewIfNeeded();
  const b = await locator.boundingBox();
  return b ? { x: b.x + b.width / 2, y: b.y + b.height / 2 } : null;
}

// ---- the frame recorder (a canvas page's document) ------------------------------
//
// Wraps MessagePort.prototype.postMessage in one canvas frame, so every
// shell verb the page's SDK posts the shell is recorded with its binding
// and action. The page dispatches a press synchronously in its click
// handler, so once a click returns, what it posted is here.
function installRecorder() {
  if (window.__posts) return true;
  const posts = [];
  Object.defineProperty(window, "__posts", { value: posts });
  const original = MessagePort.prototype.postMessage;
  MessagePort.prototype.postMessage = function (message, ...rest) {
    if (message && typeof message === "object" && typeof message.verb === "string") {
      posts.push({
        verb: message.verb,
        binding: (message.args && message.args.binding) || null,
        action: (message.args && message.args.action) || null,
      });
    }
    return original.call(this, message, ...rest);
  };
  return true;
}

const posts = (frame) => frame.evaluate(() => [...(window.__posts || [])]);

// ---- page readers ---------------------------------------------------------------

// The shipped canvas's section headings (without the count each carries)
// and its app launchers (`button.app` with the name in `.label`).
const shippedDrawing = (frame) =>
  frame.evaluate(() => ({
    headings: [...document.querySelectorAll("h2")].map((h) => (h.firstChild ? h.firstChild.textContent.trim() : "")),
    tiles: [...document.querySelectorAll(".app .label")].map((n) => n.textContent),
  })).catch(() => null);

// A written or broken canvas's single line of text.
const rootText = (frame) =>
  frame.evaluate(() => {
    const root = document.getElementById("root");
    return root ? root.textContent : null;
  }).catch(() => null);

// The probe page's own state and its drawn candles.
const probeState = (frame) =>
  frame.evaluate(() => (window.__probe ? window.__probe.state() : null)).catch(() => null);

const candleCount = (frame) =>
  frame.evaluate(() => document.querySelectorAll(".candle").length).catch(() => 0);

// Wait until `read(frame)` satisfies `check`, and answer it.
async function until(frame, read, check, what, { timeoutMs = 20_000 } = {}) {
  return lib.waitFor(async () => {
    const value = await read(frame);
    return value && check(value) ? value : null;
  }, { timeoutMs, stepMs: 50, what });
}

// ---- the shell -----------------------------------------------------------------

let lib = null;

async function context(browser, name, base, cookie, viewport) {
  const touch = viewport.posture === "hand";
  const options = { viewport: { width: viewport.width, height: viewport.height }, hasTouch: touch };
  if (touch && name !== "firefox") options.isMobile = true;
  const ctx = await browser.newContext(options);
  await ctx.addInitScript(INSTRUMENT);
  // As a sign-in on the site's https origin leaves it.
  await ctx.addCookies([{ name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: true, sameSite: "Lax" }]);
  return ctx;
}

let SHELL_URL = null;

async function openShell(page) {
  await page.goto(SHELL_URL);
  await page.waitForSelector("#canvas", { timeout: 30_000 });
  await page.waitForSelector(".phx-connected", { timeout: 30_000 });
}

const switcherIds = (page) =>
  page.$$eval("#canvas-switcher button[data-canvas]", (els) => els.map((e) => e.getAttribute("data-canvas"))).catch(() => []);

const visibleCanvas = (page) =>
  page.$eval('#canvas-switcher button[aria-pressed="true"]', (b) => b.getAttribute("data-canvas")).catch(() => null);

// The shown canvas frame: its frame id, state and inertness, and the
// Playwright frame once its page has loaded.
async function shownCanvasFrame(page) {
  const el = await page.$('[data-canvas-place="canvas"][data-canvas-shown="true"] iframe[data-frame-kind="canvas"]');
  if (!el) return null;
  const facts = await el.evaluate((e) => ({ id: e.getAttribute("data-frame-id"), state: e.getAttribute("data-frame-state"), inert: e.inert === true })).catch(() => null);
  if (!facts) return null;
  const frame = await el.contentFrame();
  return frame && frame.url() && frame.url() !== "about:blank" ? { ...facts, el, frame } : null;
}

// A canvas or app frame by its frame id, shown or not: its state,
// inertness, place and the Playwright frame.
async function canvasFrame(page, id) {
  const el = await page.$(`iframe[data-frame-id="${id}"]`);
  if (!el) return null;
  const facts = await el.evaluate((e) => ({
    id: e.getAttribute("data-frame-id"),
    state: e.getAttribute("data-frame-state"),
    inert: e.inert === true,
    dropped: e.dataset.dropped || "0",
    place: e.closest("[data-canvas-place]") ? e.closest("[data-canvas-place]").getAttribute("data-canvas-place") : null,
    shown: e.closest("[data-canvas-shown]") ? e.closest("[data-canvas-shown]").getAttribute("data-canvas-shown") === "true" : null,
  })).catch(() => null);
  if (!facts) return null;
  const frame = await el.contentFrame();
  return { ...facts, el, frame };
}

// The canvas frames the shell held, by canvas id, as the proof saw them
// shown: a canvas switched back to resumes the frame it held.
const held = new Map();

// Show canvas `id` by the switcher (unless the glass shows it already) and
// answer its live, loaded frame: the frame shown after the click, not the
// one shown before it.
async function showCanvas(page, id, { timeoutMs = 45_000 } = {}) {
  const before = await shownCanvasFrame(page);
  let switched = false;
  if ((await visibleCanvas(page)) !== id) {
    await lib.waitFor(async () => (await switcherIds(page)).includes(id), { timeoutMs: 30_000, what: `the switcher to list ${id}` });
    await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
    switched = true;
  }
  const shown = await lib.waitFor(async () => {
    if ((await visibleCanvas(page)) !== id) return null;
    const s = await shownCanvasFrame(page);
    if (!s || s.state !== "live") return null;
    if (switched && before && s.id === before.id) return null;
    return s;
  }, { timeoutMs, stepMs: 50, what: `canvas ${id} shown live` });
  held.set(id, shown.id);
  return shown;
}

// The system layer's open prompt: its kind, description and offers.
async function prompt(page) {
  return page.evaluate(() => {
    const layer = document.getElementById("system-layer");
    const dialog = document.getElementById("system-layer-dialog");
    if (!layer || layer.dataset.open !== "true" || !dialog) return null;
    const text = (attribute) => {
      const id = dialog.getAttribute(attribute);
      const el = id && document.getElementById(id);
      return el ? el.textContent.trim() : "";
    };
    const kind = dialog.querySelector("[data-kind]");
    return {
      kind: kind ? kind.dataset.kind : null,
      title: text("aria-labelledby"),
      description: text("aria-describedby"),
      offers: [...dialog.querySelectorAll("button[phx-value-offer]")].map((b) => ({ offer: b.getAttribute("phx-value-offer"), label: b.textContent.trim() })),
    };
  }).catch(() => null);
}

// The fallback's one line, as the system layer draws it outside every
// frame: its words and its offers, or null while none is drawn.
async function notice(page) {
  return page.evaluate(() => {
    const el = document.getElementById("system-layer-notice");
    if (!el) return null;
    return {
      id: el.dataset.noticeId,
      text: el.textContent.replace(/\s+/g, " ").trim(),
      offers: [...el.querySelectorAll("button[phx-value-offer]")].map((b) => ({ offer: b.getAttribute("phx-value-offer"), label: b.textContent.trim() })),
    };
  }).catch(() => null);
}

const fallbackNotice = (page, timeoutMs = 20_000) =>
  lib.waitFor(async () => (await notice(page)) || null, { timeoutMs, stepMs: 50, what: "the fallback's notice" });

// The window the shown canvas holds open, by its frame, or null.
const shownWindow = (page) =>
  page.evaluate(() => {
    const wrapper = document.querySelector('[data-canvas-place="window"][data-canvas-shown="true"]');
    const iframe = wrapper && wrapper.querySelector("iframe");
    return iframe ? { id: iframe.dataset.frameId, state: iframe.dataset.frameState } : null;
  }).catch(() => null);

// AQUA's own control, as the page draws it beside the shell.
const aquaState = (page) =>
  page.evaluate(() => {
    const button = document.getElementById("aqua-panel-button");
    return button ? { present: true, expanded: button.getAttribute("aria-expanded"), inert: button.closest("[inert]") !== null } : { present: false };
  }).catch(() => null);

// The grant prompt a canvas version raises when what it reads differs from
// today's grant (`Compendium.Canvas`): the shell's for the working version
// a failed validation falls back to, the fallback notice's for the kept
// version it restores. `ref` is the version it must ask for. While it is open the
// shown canvas place is read and `whileOpen` is asked, and the person then
// confirms it in the prompt's own sheet, which walks the consent plan,
// preview and commit. Answers the prompt's title, what the place held and
// what `whileOpen` answered.
async function confirmRegrant(page, ref, { timeoutMs = 45_000, whileOpen = async () => null } = {}) {
  const asked = await lib.waitFor(async () => {
    const p = await prompt(page);
    return p && p.kind === "grant" ? p : null;
  }, { timeoutMs, stepMs: 50, what: `the grant prompt for ${ref}` });
  const place = await page.evaluate(() => {
    const shown = document.querySelector('[data-canvas-place="canvas"][data-canvas-shown="true"]');
    const refused = shown && shown.querySelector("[data-tincture-state]");
    const iframe = shown && shown.querySelector('iframe[data-frame-kind="canvas"]');
    return { refusal: refused ? refused.dataset.tinctureState : null, frame: iframe ? iframe.getAttribute("data-frame-state") : null };
  });
  const meanwhile = await whileOpen();
  await page.locator('#system-layer-dialog [data-test="prompt-confirm"]').click({ timeout: timeoutMs });
  await lib.waitFor(async () => {
    const p = await prompt(page);
    return !p || p.kind !== "grant" ? true : null;
  }, { timeoutMs, what: `the grant prompt for ${ref} confirmed` });
  return { title: asked.title, asked_for: asked.title === `Grant ${ref}`, place, meanwhile };
}

// What the shell draws, for a step that did not find what it expected.
async function diagnose(page) {
  const frames = await page.$$eval("[data-canvas-frame]", (els) => els.map((e) => {
    const f = e.querySelector("iframe");
    return {
      place: e.dataset.canvasPlace, shown: e.dataset.canvasShown, kind: f ? f.dataset.frameKind : null,
      id: f ? f.dataset.frameId : null, state: f ? f.dataset.frameState : null, dropped: f ? f.dataset.dropped || "0" : null,
      refusal: e.querySelector("[data-tincture-state]") ? e.querySelector("[data-tincture-state]").dataset.tinctureState : null,
    };
  })).catch(() => []);
  const marks = await instrument(page).catch(() => null);
  return {
    url_path: await page.evaluate(() => location.pathname).catch(() => null),
    switcher: await switcherIds(page),
    visible: await visibleCanvas(page),
    prompt: await prompt(page),
    frames,
    receipts: marks && marks.receipts.slice(-12),
    log: (page.__log || []).slice(-12),
  };
}

// ---- layouts -------------------------------------------------------------------

const posture = (apps = []) => ({ desk: { apps }, hand: { apps } });

// canvas-full as a window over the right half of a canvas, on the desk.
const windowApp = [{
  tincture: "tincture:local.canvas-full", placement: "window", order: 0, minimised: false,
  geometry: { x: 5000, y: 0, w: 5000, h: 10000 },
}];

// The proof's layout: the shipped canvas `start` (canvas-full as its full
// app, minimised, so it opens when the canvas asks for it), markets
// (canvas-full as a window on the desk, the sibling the activation step
// records a click in; in the hand every app is full over the whole canvas,
// so markets has none there), the probe (canvas-full as its full app,
// minimised), canvas-broken, and any canvas a step adds or puts in
// another's place.
function layout(extra = [], { without = [] } = {}) {
  const full = [{ tincture: "tincture:local.canvas-full", placement: "full", order: 0, minimised: true }];
  const base = [
    { id: "start", tincture: "tincture:local.canvas", postures: posture(full) },
    { id: "markets", tincture: "tincture:local.markets", postures: { desk: { apps: windowApp }, hand: { apps: [] } } },
    { id: "probe", tincture: "tincture:local.canvas-probe", postures: posture(full) },
    { id: "broken", tincture: "tincture:local.canvas-broken", postures: posture() },
  ].filter((c) => !without.includes(c.id));
  return { version: 3, canvases: [...base, ...extra.map((e) => ({ id: e.id, tincture: e.tincture, postures: e.postures || posture() }))] };
}

// Publish `document` and wait until the switcher lists exactly its canvases.
async function publish(page, document) {
  const answer = await ask({ op: "layout", document });
  if (!OK(answer)) throw new Error(`the layout was not published: ${JSON.stringify(answer)}`);
  const ids = document.canvases.map((c) => c.id);
  await lib.waitFor(async () => {
    const listed = await switcherIds(page);
    return listed.length === ids.length && ids.every((id, i) => listed[i] === id) ? true : null;
  }, { timeoutMs: 30_000, what: `the switcher to list ${ids.join(", ")}` });
  for (const id of [...held.keys()]) if (!ids.includes(id)) held.delete(id);
}

// ---- steps ---------------------------------------------------------------------

// two_canvases: the shipped canvas and a written one, each shown live, the
// written one ending its validation on `ready`. switch: the switcher, the
// chords and a swipe on the shelf each move the glass, the canvas left is
// frozen, and nothing wraps.
async function stepTwoCanvases(page, name, viewport) {
  const ids = await switcherIds(page);
  const start = await showCanvas(page, "start");
  const startDrawn = await until(start.frame, shippedDrawing, (d) => d.headings.includes("Apps") && d.tiles.includes("canvas-full"), "the shipped canvas's launchers");
  const startVersions = await versions("canvas");

  // A frame is "live" (shown) before its page calls ready(), so wait for the
  // shipped canvas's own ready before the mark, lest its late ready count
  // among the written canvas's.
  await lib.waitFor(async () => receiptsOf(await instrument(page), 0, start.id, "ready").length >= 1 || null, { timeoutMs: SAMPLE_MS, what: "the shipped canvas's ready" }).catch(() => null);
  const marks0 = (await instrument(page)).receipts.length;
  const markets = await showCanvas(page, "markets");
  const marketsDrawn = await until(markets.frame, rootText, (t) => t.includes("markets"), "the written canvas drawn");
  await lib.waitFor(async () => receiptsOf(await instrument(page), marks0, markets.id, "ready").length >= 1 || null, { timeoutMs: SAMPLE_MS, what: "markets live ready" }).catch(() => null);
  const marks = await instrument(page);
  const readies = receiptsOf(marks, marks0, null, "ready");
  // A validation frame and the live canvas frame are canvas-kind; a column
  // app beside the canvas (canvas-full) readies too, and is not counted.
  const validationReady = readies.filter((r) => r.frame !== markets.id && r.kind === "canvas");
  const marketsReady = readies.filter((r) => r.frame === markets.id);
  const marketsVersions = await versions("markets");
  const startLeft = await canvasFrame(page, start.id);

  note("two_canvases", name,
    ids.includes("start") && ids.includes("markets") && startVersions.working === "0.3.0" &&
      marketsVersions.working === "0.1.0" && validationReady.length === 1 && marketsReady.length === 1 &&
      startLeft && startLeft.state === "frozen",
    {
      shipped: { canvas: "start", tincture: "tincture:local.canvas", working: startVersions.working, draws: startDrawn.headings.slice(0, 3), launchers: startDrawn.tiles },
      written: { canvas: "markets", tincture: "tincture:local.markets", working: marketsVersions.working, validation_readies: validationReady.length, live_readies: marketsReady.length },
      diag: { ready_frames: readies.map((r) => r.frame), shown_id: markets.id, start_id: start.id },
      switcher: ids,
      start_after_switch: startLeft && { state: startLeft.state, inert: startLeft.inert },
    });

  // switch: by the chord, back to start (the frame it held, resumed). On
  // the desk markets carries a window, the active app, which
  // Ctrl+Alt+ArrowLeft would tile, so the chord there is Ctrl+Alt+1, the
  // first canvas.
  const viaSwitcher = { from: "start", to: "markets", shown: markets.id !== start.id };
  await page.keyboard.press("Control+Alt+1");
  const byChord = await lib.waitFor(async () => {
    const s = await shownCanvasFrame(page);
    return (await visibleCanvas(page)) === "start" && s && s.id === start.id && s.state === "live" ? s : null;
  }, { timeoutMs: 15_000, what: "the chord to show start" }).then(() => true).catch(() => false);
  const marketsLeft = await canvasFrame(page, markets.id);

  // At the first canvas, which has no active app, the chord leftward does
  // nothing; rightward then shows markets, which a wrap to the last canvas
  // would not.
  await page.keyboard.press("Control+Alt+ArrowLeft");
  await page.keyboard.press("Control+Alt+ArrowRight");
  const noWrap = await lib.waitFor(async () => ((await visibleCanvas(page)) === "markets" ? true : null),
    { timeoutMs: 15_000, what: "the chord to show markets" }).then(() => true).catch(() => false);

  // By the shelf: rightward is the canvas before, leftward the next.
  const swipeBack = await swipe(page, viewport, "rightward");
  const bySwipeBack = await lib.waitFor(async () => ((await visibleCanvas(page)) === "start" ? true : null),
    { timeoutMs: 15_000, what: "the swipe to show start" }).then(() => true).catch(() => false);
  await swipe(page, viewport, "leftward");
  const bySwipeOn = await lib.waitFor(async () => ((await visibleCanvas(page)) === "markets" ? true : null),
    { timeoutMs: 15_000, what: "the swipe to show markets" }).then(() => true).catch(() => false);
  const shownAfter = await shownCanvasFrame(page);
  const startFrozen = await canvasFrame(page, start.id);

  note("switch", name,
    viaSwitcher.shown && byChord && marketsLeft && marketsLeft.state === "frozen" && marketsLeft.inert &&
      noWrap && bySwipeBack && bySwipeOn && shownAfter && shownAfter.id === markets.id && shownAfter.state === "live" &&
      startFrozen && startFrozen.state === "frozen",
    {
      by_switcher: viaSwitcher,
      by_chord: { keys: "Ctrl+Alt+1", shown: byChord, frame_resumed: byChord, left_frozen: marketsLeft && { state: marketsLeft.state, inert: marketsLeft.inert } },
      no_wrap: { at_first: "Ctrl+Alt+ArrowLeft then Ctrl+Alt+ArrowRight", shows: noWrap ? "markets" : await visibleCanvas(page) },
      by_swipe: { pointer: swipeBack.pointer, rightward: bySwipeBack, leftward: bySwipeOn, frame_resumed: !!(shownAfter && shownAfter.id === markets.id) },
      left_frozen_after_swipe: startFrozen && { state: startFrozen.state, inert: startFrozen.inert },
    });
}

// A horizontal swipe along the shelf, from its empty right end: a touch
// swipe in the hand, a pointer drag on the desk.
async function swipe(page, viewport, direction) {
  const box = await page.$eval("#canvas-shelf", (e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
  const y = box.y + box.h / 2;
  const right = box.x + box.w - 24;
  const left = right - 160;
  const [from, to] = direction === "leftward" ? [right, left] : [left, right];
  if (viewport.posture === "hand") {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: from, y }] });
    for (let i = 1; i <= 8; i++) {
      await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: from + ((to - from) * i) / 8, y }] });
    }
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
    await cdp.detach();
    return { pointer: "touch" };
  }
  await page.mouse.move(from, y);
  await page.mouse.down();
  await page.mouse.move(to, y, { steps: 8 });
  await page.mouse.up();
  return { pointer: "mouse" };
}

// written_canvas: a canvas written with canvas.write is validated (ending
// on ready), then activated, then opened live at its working version.
async function stepWrittenCanvas(page, name) {
  const canvas = "written";
  const written = await ask({ op: "write", canvas, kind: "written", streams: [] });
  if (!OK(written)) throw new Error(`canvas.write refused the canvas: ${JSON.stringify(written)}`);
  const before = await versions(canvas);
  await publish(page, layout([{ id: canvas, tincture: `tincture:local.${canvas}` }]));
  const from = (await instrument(page)).receipts.length;
  const shown = await showCanvas(page, canvas);
  const text = await until(shown.frame, rootText, (t) => t === `written ${written.ok.version}`, "the written canvas drawn at its version");
  await lib.waitFor(async () => receiptsOf(await instrument(page), from, shown.id, "ready").length >= 1 || null, { timeoutMs: SAMPLE_MS, what: "the written canvas's live ready" }).catch(() => null);
  const marks = await instrument(page);
  const readies = receiptsOf(marks, from, null, "ready");
  const validationReady = readies.filter((r) => r.frame !== shown.id && r.kind === "canvas");
  const liveReady = readies.filter((r) => r.frame === shown.id);
  const after = await versions(canvas);
  note("written_canvas", name,
    written.ok.version === "0.1.0" && before.working === null && validationReady.length === 1 &&
      liveReady.length === 1 && after.working === written.ok.version && after.failed === null && text === "written 0.1.0",
    {
      written: { version: written.ok.version, reference: written.ok.reference, working_before: before.working },
      validated: { validation_frame_readies: validationReady.length, validation_frame_is_another: validationReady.every((r) => r.frame !== shown.id) },
      activated: { working: after.working, kept: after.kept, failed: after.failed },
      live: { draws: text, live_readies: liveReady.length },
      diag: { ready_frames: readies.map((r) => r.frame), shown_id: shown.id },
    });
  await showCanvas(page, "start");
  await publish(page, layout());
}

// feed_chart: the feed `candles`' fixed result, drawn by the probe page as
// its own SVG candles.
async function stepFeedChart(page, name) {
  const state = await feedState("candles");
  const shown = await showCanvas(page, "probe");
  const s = await until(shown.frame, probeState, (st) => st.stream.settled && st.candles > 0 && st.revision === state.result_seq, "the probe's candles at the accepted revision");
  const drawn = await candleCount(shown.frame);
  note("feed_chart", name, drawn === 6 && s.candles === 6,
    {
      chart: { drawn_candles: drawn, state_candles: s.candles },
      drawn_revision: s.revision,
      accepted_seq: state.result_seq,
      executed: false,
      source: "a fixed result the fixture accepted through the gate's accept path; no run executed",
    });
  await showCanvas(page, "start");
}

// app_over_canvas: canvas-full opened full from the shipped canvas's
// launcher tile over the shipped canvas, frozen with it on a switch, shown
// again on the way back, and closed. The tile is clicked as a person
// clicks it (personClick), and the page opens from its click handler.
async function stepAppOverCanvas(page, name) {
  const start = await showCanvas(page, "start");
  await until(start.frame, shippedDrawing, (d) => d.tiles.includes("canvas-full"), "the canvas-full launcher");
  const tile = await centerOf(start.frame.locator('.app', { has: start.frame.locator('.label', { hasText: "canvas-full" }) }).first());
  if (!tile) throw new Error("the canvas-full launcher could not be measured");
  const from = (await instrument(page)).receipts.length;
  await personClick(page, start.id, tile.x, tile.y);
  const full = await lib.waitFor(async () => {
    const el = await page.$('[data-canvas-place="full"][data-canvas-shown="true"] iframe');
    if (!el) return null;
    const f = await el.contentFrame();
    const drawnFull = f ? await f.evaluate(() => document.body && document.body.dataset.drawn === "yes").catch(() => false) : false;
    return drawnFull ? { id: await el.getAttribute("data-frame-id"), state: await el.getAttribute("data-frame-state") } : null;
  }, { timeoutMs: 20_000, what: "canvas-full opened full" });
  const opened = receiptsOf(await instrument(page), from, start.id, "open").filter((r) => r.dropped === false).length;
  const startUnder = await canvasFrame(page, start.id);

  await showCanvasAway(page, "markets");
  const fullFrozen = await lib.waitFor(async () => {
    const f = await canvasFrame(page, full.id);
    return f && f.state === "frozen" && f.inert && f.shown === false ? f : null;
  }, { timeoutMs: 15_000, what: "canvas-full frozen" });
  const startFrozen = await canvasFrame(page, start.id);

  // Back to start: its full app is shown again, live, over it.
  await page.click('#canvas-switcher button[data-canvas="start"]');
  const fullAgain = await lib.waitFor(async () => {
    const f = await canvasFrame(page, full.id);
    return f && f.state === "live" && f.shown === true ? f : null;
  }, { timeoutMs: 15_000, what: "canvas-full shown again" });
  await page.locator('button[phx-click="close_active_tincture"]:visible').click();
  await lib.waitFor(async () => ((await page.$(`iframe[data-frame-id="${full.id}"]`)) ? null : true), { timeoutMs: 15_000, what: "canvas-full closed" });
  const startBack = await showCanvas(page, "start");

  note("app_over_canvas", name,
    opened === 1 && full.state === "live" && startUnder && startUnder.state === "frozen" &&
      fullFrozen.state === "frozen" && fullFrozen.inert && startFrozen && startFrozen.state === "frozen" &&
      fullAgain.state === "live" && startBack.id === start.id && startBack.state === "live",
    {
      opened: { by: "the shipped canvas's launcher tile", open_verbs: opened, full_frame: full.state, canvas_under: startUnder && startUnder.state },
      on_switch: { full_frame: { state: fullFrozen.state, inert: fullFrozen.inert, shown: fullFrozen.shown }, canvas: startFrozen && startFrozen.state },
      switched_back: { full_frame: fullAgain.state },
      closed: { canvas_shown_again: startBack.state, same_frame: startBack.id === start.id },
    });
}

// attention_moves: the shipped canvas moves "Needs attention" out from
// under a window and nothing else. Its runs stream is answered with three
// failures a grant fixes and one long unrelated failure, so the card holds
// both kinds; a window is reported covering the card. On the desk the card
// moves to the other column and Recent runs, Apps and Schedules stand
// exactly where they stood; in the hand every section stands in one
// column. The stream is answered as usual again afterwards.
const STREAM_ROUTE = "**/_f/v1/o/*/stream";

function attentionFailures(route) {
  let body = null;
  try { body = route.request().postDataJSON(); } catch (_error) { body = null; }
  if (!body || body.stream !== "runs.changes") return route.continue();
  const grant = "This account is not granted to the component; grant it first.";
  const events = [
    ...[0, 1, 2].map((i) => ({ kind: "failed", execution_id: `attention_${i}`, reference: "catalyst:local.claude:1.4.1", duration_ms: 100, error: { class: "internal", message: grant } })),
    { kind: "failed", execution_id: "attention_long", reference: "catalyst:local.openai:1.4.1", duration_ms: 100, error: { class: "unavailable", message: "The model provider answered with an error the runner could not read, so this run stopped before it finished; the provider may be down, or the reply may have been too large to hold at once." } },
  ];
  return route.fulfill({
    status: 200,
    contentType: "text/event-stream",
    body: events.map((data, i) => `id: ${i + 1}\nevent: message\ndata: ${JSON.stringify(data)}\n\n`).join(""),
  });
}

const sections = (frame) =>
  frame.evaluate(() => Object.fromEntries([...document.querySelectorAll("section.card")].map((el) => {
    const b = el.getBoundingClientRect();
    return [el.querySelector("h2").firstChild.textContent.trim(), { x: b.x, y: b.y, width: b.width, height: b.height }];
  }))).catch(() => null);

async function stepAttentionMoves(page, name, viewport) {
  const ctx = page.context();
  await ctx.route(STREAM_ROUTE, attentionFailures);
  try {
    await openShell(page);
    held.clear();
    const start = await showCanvas(page, "start");
    const before = await until(start.frame, sections, (s) => s["Needs attention"] && s["Recent runs"] && s.Apps && s.Schedules, "the shipped canvas's sections with Needs attention");
    const others = ["Recent runs", "Apps", "Schedules"];

    if (viewport.posture === "hand") {
      const x = before["Needs attention"].x;
      note("attention_moves", name, others.every((n) => near(before[n].x, x)), { posture: "hand", sections: before });
      return;
    }

    const card = before["Needs attention"];
    await page.$eval(`iframe[data-frame-id="${start.id}"]`, (el, rect) => el.dispatchEvent(new CustomEvent("cyfr:to-canvas", { detail: { verb: "covered", args: { rects: [rect] } } })), card);
    const after = await until(start.frame, sections, (s) => s["Needs attention"] && s["Needs attention"].x > card.x + 10, "Needs attention moved out from under the window").catch(() => null);
    const stayed = after !== null && others.every((n) => after[n] && after[n].x === before[n].x && after[n].y === before[n].y);
    note("attention_moves", name, stayed, { covered: card, before, after });
  } finally {
    await ctx.unroute(STREAM_ROUTE, attentionFailures).catch(() => null);
    await openShell(page);
    held.clear();
  }
}

// ---- windows ---------------------------------------------------------------------

// The layout as the layout tool reads it now: its revision, and markets's
// desk apps.
async function layoutRead() {
  const answer = await ask({ op: "layout_read" });
  if (!OK(answer)) throw new Error(`the layout could not be read: ${JSON.stringify(answer)}`);
  const doc = answer.ok.document || {};
  const markets = (doc.canvases || []).find((c) => c.id === "markets");
  const desk = markets && markets.postures && markets.postures.desk;
  return { revision: answer.ok.revision, apps: (desk && desk.apps) || [] };
}

// An element's box in the page, or null.
const boxOn = (page, selector) =>
  page.$eval(selector, (e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; }).catch(() => null);

// What the hook last told canvas frame `frame` covers it.
async function lastCovered(page, frame) {
  const told = ((await instrument(page)) || { covered: [] }).covered.filter((c) => c.frame === frame);
  return told.length ? told[told.length - 1].rects : null;
}

const near = (a, b, slack = 2) => Math.abs(a - b) <= slack;

// window_drag, tile_narrows, covered_windows: markets carries canvas-full as
// a window over its right half on the desk. Dragged by its title bar, the
// window is written to the layout and read back through the layout tool at
// a newer revision, at the geometry the shell draws; the canvas is told the
// window's rectangle and nothing else. Its tile control tiles it: the
// canvas's frame narrows by the tile's width, and the canvas is told
// nothing covers it. In the hand every app is full and markets places
// none: no chrome is drawn and nothing is told covering the canvas.
async function stepWindows(page, name, viewport) {
  const markets = await showCanvas(page, "markets");

  if (viewport.posture === "hand") {
    const grips = await page.$$eval("[data-canvas-grip]", (els) => els.length).catch(() => -1);
    const placed = await page.$$eval('[data-canvas-shown="true"][data-canvas-place="window"], [data-canvas-shown="true"][data-canvas-place="tile"]', (els) => els.length).catch(() => -1);
    const covered = await lib.waitFor(async () => lastCovered(page, markets.id), { timeoutMs: 15_000, what: "markets told what covers it" }).catch(() => null);
    const hand = { posture: "hand", title_bars: grips, windows_and_tiles: placed, covered };
    note("window_drag", name, grips === 0 && placed === 0, hand);
    note("tile_narrows", name, grips === 0 && placed === 0, hand);
    note("covered_windows", name, Array.isArray(covered) && covered.length === 0, hand);
    return;
  }

  const wrapperSel = '[data-canvas-shown="true"][data-canvas-place="window"]';
  await page.waitForSelector(wrapperSel, { timeout: 20_000 });
  const frame = await page.$eval(wrapperSel, (e) => e.getAttribute("data-canvas-frame"));
  const wrapper = `[data-canvas-frame="${frame}"]`;
  const before = await layoutRead();

  // Drag the window by its title bar, 200 pixels left and 40 down.
  const title = await boxOn(page, `${wrapper} .canvas-app-name`);
  if (!title) throw new Error("the window's title bar could not be measured");
  const from = { x: title.x + 10, y: title.y + title.height / 2 };
  await page.mouse.move(from.x, from.y);
  await page.mouse.down();
  await page.mouse.move(from.x - 100, from.y + 20, { steps: 6 });
  const shieldMidDrag = await page.$eval(".canvas-shield", (e) => !e.hidden).catch(() => false);
  await page.mouse.move(from.x - 200, from.y + 40, { steps: 6 });
  await page.mouse.up();

  const drawn = await lib.waitFor(async () => {
    const g = await page.$eval(wrapper, (e) => e.getAttribute("data-canvas-geometry")).catch(() => null);
    return g && g !== "5000 0 5000 10000" ? g : null;
  }, { timeoutMs: 15_000, what: "the window drawn where it was dropped" });
  const read = await lib.waitFor(async () => {
    const now = await layoutRead();
    const app = now.apps.find((a) => a.tincture === "tincture:local.canvas-full");
    const g = app && app.geometry;
    return now.revision > before.revision && g && `${g.x} ${g.y} ${g.w} ${g.h}` === drawn ? { revision: now.revision, geometry: g, placement: app.placement } : null;
  }, { timeoutMs: 20_000, what: "the dragged window read back through the layout tool" }).catch(() => null);

  note("window_drag", name,
    shieldMidDrag && read !== null && read.placement === "window" && read.geometry.x < 5000,
    { shield_mid_drag: shieldMidDrag, before: { revision: before.revision, geometry: "5000 0 5000 10000" }, drawn, read_back: read });

  // What covers the canvas: the window's rectangle, in the canvas frame's
  // own pixels, and nothing else.
  const canvasFrameSel = `iframe[data-frame-id="${markets.id}"]`;
  const told = await lib.waitFor(async () => {
    const rects = await lastCovered(page, markets.id);
    const win = await boxOn(page, wrapper);
    const canvasBox = await boxOn(page, canvasFrameSel);
    if (!rects || !win || !canvasBox || rects.length !== 1) return null;
    const [r] = rects;
    const expect = {
      x: Math.max(0, win.x - canvasBox.x), y: Math.max(0, win.y - canvasBox.y),
      width: Math.min(win.x + win.width, canvasBox.x + canvasBox.width) - Math.max(win.x, canvasBox.x),
      height: Math.min(win.y + win.height, canvasBox.y + canvasBox.height) - Math.max(win.y, canvasBox.y),
    };
    return near(r.x, expect.x) && near(r.y, expect.y) && near(r.width, expect.width) && near(r.height, expect.height) ? { rects, window: expect } : null;
  }, { timeoutMs: 15_000, what: "the window reported as covering the canvas" }).catch(async () => ({ rects: await lastCovered(page, markets.id), window: null }));

  // Tile it: the canvas's frame narrows by the tile's width, and nothing is
  // reported covering it.
  const area = await boxOn(page, "#canvas-frames");
  await page.click(`${wrapper} [data-canvas-action="tile"]`);
  const tiled = await lib.waitFor(async () => {
    const place = await page.$eval(wrapper, (e) => e.getAttribute("data-canvas-place")).catch(() => null);
    const tile = await boxOn(page, wrapper);
    const canvasBox = await boxOn(page, canvasFrameSel);
    return place === "tile" && tile && canvasBox && near(canvasBox.width, area.width - tile.width) ? { tile, canvas: canvasBox } : null;
  }, { timeoutMs: 15_000, what: "the tile narrowing the canvas's frame" }).catch(() => null);
  const coveredAfterTile = await lib.waitFor(async () => {
    const rects = await lastCovered(page, markets.id);
    return Array.isArray(rects) && rects.length === 0 ? rects : null;
  }, { timeoutMs: 10_000, what: "nothing reported covering the canvas beside a tile" }).catch(async () => lastCovered(page, markets.id));

  note("tile_narrows", name, tiled !== null,
    { area_width: area && area.width, tile: tiled && tiled.tile, canvas_frame: tiled && tiled.canvas });
  note("covered_windows", name,
    told.window !== null && Array.isArray(coveredAfterTile) && coveredAfterTile.length === 0,
    { window_over_canvas: told, beside_a_tile: coveredAfterTile });

  // The shell's own write of the tile lands before the proof's layout
  // replaces it, so no write of the shell's, retried over a newer revision,
  // tiles it again afterwards.
  await lib.waitFor(async () => {
    const now = await layoutRead();
    return now.apps.some((a) => a.tincture === "tincture:local.canvas-full" && a.placement === "tile") ? true : null;
  }, { timeoutMs: 20_000, what: "the tile written to the layout" }).catch(() => null);
  await publish(page, layout());
}

// frame_kept: an app's frame is never moved or loaded again as the app is
// raised, tiled, made full and made a window again. markets's window is
// marked in the page, raised from the shelf, tiled and made full with its
// controls and made a window again with Ctrl+Alt+ArrowDown; after each, its
// iframe is the element marked, under the same frame id, and has loaded no
// more than before. In the hand every app is full and markets places none.
async function stepFrameKept(page, name, viewport) {
  await showCanvas(page, "markets");
  if (viewport.posture === "hand") {
    const placed = await page.$$eval('[data-canvas-shown="true"][data-canvas-place="window"]', (els) => els.length).catch(() => -1);
    note("frame_kept", name, placed === 0, { posture: "hand", windows: placed });
    return;
  }

  const wrapperSel = '[data-canvas-shown="true"][data-canvas-place="window"]';
  await page.waitForSelector(wrapperSel, { timeout: 20_000 });
  const frame = await page.$eval(wrapperSel, (e) => e.getAttribute("data-canvas-frame"));
  const wrapper = `[data-canvas-frame="${frame}"]`;
  const ref = "tincture:local.canvas-full";
  const loadsOf = async () => ((await instrument(page)) || { loads: [] }).loads.filter((l) => l.frame === frame).length;
  await lib.waitFor(async () => (await loadsOf()) >= 1 || null,
    { timeoutMs: 20_000, what: "the window's frame loaded" });

  const mark = `kept-${Date.now()}`;
  await page.$eval(`iframe[data-frame-id="${frame}"]`, (el, value) => { el.__proofMark = value; }, mark);
  const loads = await loadsOf();

  // The iframe after a gesture: the wrapper standing as `place`, which the
  // gesture asked for, and the element marked, under its frame id, with no
  // new load. A placement that never happens fails the step.
  const kept = async (gesture, place) => {
    await lib.waitFor(async () => (await page.$eval(wrapper, (e) => e.getAttribute("data-canvas-place")).catch(() => null)) === place || null,
      { timeoutMs: 15_000, what: `the app standing as ${place} after ${gesture}` }).catch(() => null);
    await page.waitForTimeout(500);
    const same = await page.$eval(`iframe[data-frame-id="${frame}"]`, (el, value) => el.__proofMark === value, mark).catch(() => false);
    const now = await loadsOf();
    const stands = await page.$eval(wrapper, (e) => e.getAttribute("data-canvas-place")).catch(() => null);
    return { gesture, asked: place, place: stands, same_element: same, loads: now, held: stands === place && same && now === loads };
  };

  const seen = [];
  await page.click(`#canvas-shelf-apps [data-canvas-shelf-app="${ref}"]`);
  seen.push(await kept("raise", "window"));
  await page.click(`${wrapper} [data-canvas-action="tile"]`);
  seen.push(await kept("tile", "tile"));
  await page.click(`${wrapper} [data-canvas-action="full"]`);
  seen.push(await kept("full", "full"));
  await page.keyboard.press("Control+Alt+ArrowDown");
  seen.push(await kept("window", "window"));

  note("frame_kept", name, seen.every((s) => s.held), { frame, loads_before: loads, after: seen });

  // The shell's own writes land before the proof's layout replaces them.
  await lib.waitFor(async () => {
    const now = await layoutRead();
    return now.apps.some((a) => a.tincture === ref && a.placement === "window") ? true : null;
  }, { timeoutMs: 20_000, what: "the window written to the layout" }).catch(() => null);
  await publish(page, layout());
}

// Switch to `id` while a full frame covers the visible canvas: the glass
// moves, and the switcher stays reachable.
async function showCanvasAway(page, id) {
  await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
  await lib.waitFor(async () => ((await visibleCanvas(page)) === id ? true : null), { timeoutMs: 15_000, what: `canvas ${id} shown` });
}

// hidden_canvas: a hidden canvas reads and acts on nothing. The probe is
// shown and reading its stream, and tags each feed event with the state the
// shell last told it; switched away, once it has heard `frozen` no stream
// open of it reaches the server, a new feed result reaches it not, and a
// press it sends is dropped (counted in the frame's data-dropped, never
// received by the shell), a count that outlives the next switch, which
// draws every frame again, the hidden one's iframe included; switched
// back, its stream refreshes to the new result, and no feed event it ever
// read is tagged `frozen`. Nothing here reads the page's own timer as proof
// it stopped.
async function stepHiddenCanvas(page, name, proxy) {
  const probe = await showCanvas(page, "probe");
  const before = await until(probe.frame, probeState, (s) => s.stream.settled && s.stream.events >= 1 && s.candles === 6 && s.told === "live", "the probe reading its stream");
  const from = (await instrument(page)).receipts.length;
  const droppedBefore = Number((await canvasFrame(page, probe.id)).dropped);

  // Switched away, the probe's frame is frozen, and the probe hears it.
  await showCanvas(page, "start");
  const frozen = await canvasFrame(page, probe.id);
  await until(frozen.frame, probeState, (s) => s.told === "frozen", "the hidden probe hearing it is frozen");
  const proxyMark = proxy.seen.length;

  // A new result published while the probe is hidden reaches its closed
  // stream not.
  const accepted = await ask({ op: "accept", feed: "candles", data: { symbol: "BTC", price: 7, change: null, at: new Date().toISOString().replace(/\.\d+Z$/, "Z"), candles: candles("BTC") } });
  await sleep(1500);
  const whileHidden = await probeState(frozen.frame);

  // A press the hidden probe sends is dropped by the bridge, never received.
  await frozen.frame.evaluate(() => window.__probe && window.__probe.press());
  await sleep(500);
  const droppedAfterPress = Number((await canvasFrame(page, probe.id)).dropped);
  const pressReceipts = receiptsOf(await instrument(page), from, probe.id, "press");
  const pressForwarded = pressReceipts.filter((r) => r.dropped === false).length;

  // Another switch while the probe stays hidden draws every frame again,
  // which patches the probe's iframe to the view's attributes: its count
  // stays. The patch is watched on the iframe, so the record says whether
  // one came.
  await page.evaluate((id) => {
    const el = document.querySelector(`iframe[data-frame-id="${id}"]`);
    const seen = [];
    const observer = new MutationObserver((records) => { for (const r of records) seen.push(r.attributeName); });
    observer.observe(el, { attributes: true });
    window.__probePatch = { seen, observer };
  }, probe.id);
  await showCanvas(page, "markets");
  const patch = await page.evaluate(() => {
    const { seen, observer } = window.__probePatch;
    observer.disconnect();
    delete window.__probePatch;
    return { patched: seen.length > 0, attributes: [...new Set(seen)] };
  });
  const droppedAfterSwitch = Number((await canvasFrame(page, probe.id)).dropped);

  // The probe asks for its stream again on a timer while it is hidden; no
  // open of it reached the server since it heard `frozen`.
  const streamPath = `/_f/v1/o/${probe.id}/stream`;
  const opensWhileHidden = proxy.seen.slice(proxyMark).filter((r) => {
    try { return r.method === "POST" && new URL(r.url).pathname === streamPath; } catch { return false; }
  }).length;

  // Switched back, its stream refreshes to the new result.
  const back = await showCanvas(page, "probe");
  const after = await until(back.frame, probeState, (s) => s.stream.settled && s.stream.events > whileHidden.stream.events && s.revision === accepted.revision, "the probe's stream refreshed on return");

  note("hidden_canvas", name,
    back.id === probe.id && frozen.state === "frozen" &&
      whileHidden.stream.events === before.stream.events && whileHidden.revision === before.revision &&
      opensWhileHidden === 0 &&
      droppedAfterPress === droppedBefore + 1 && pressForwarded === 0 && droppedAfterSwitch === droppedAfterPress &&
      after.stream.events > whileHidden.stream.events && after.revision === accepted.revision &&
      after.tagged.frozen === 0 && after.tagged.none === 0 && after.tagged.live === after.stream.events,
    {
      before: { events: before.stream.events, revision: before.revision, tagged: before.tagged },
      while_hidden: {
        frame: frozen.state,
        told: whileHidden.told,
        new_result_accepted_revision: accepted.revision,
        events: whileHidden.stream.events,
        revision: whileHidden.revision,
        stream_event_reached_it: whileHidden.stream.events !== before.stream.events,
        stream_opens_reaching_the_server: opensWhileHidden,
        press_received: pressReceipts.length,
        press_dropped: droppedAfterPress - droppedBefore,
        press_forwarded: pressForwarded,
        after_another_switch: { patched: patch.patched, attributes: patch.attributes, dropped_kept: droppedAfterSwitch === droppedAfterPress },
        tagged: whileHidden.tagged,
      },
      shown_again: { same_frame: back.id === probe.id, told: after.told, events: after.stream.events, refresh: after.stream.refresh, revision: after.revision, tagged: after.tagged },
      tagged_frozen: after.tagged.frozen,
    });
  await showCanvas(page, "start");
}

function candles(symbol) {
  const now = Date.now();
  return Array.from({ length: 4 }, (_unused, i) => {
    const o = 100 + i;
    return { t: new Date(now - (4 - i) * 3_600_000).toISOString().replace(/\.\d+Z$/, "Z"), o, h: o + 2, l: o - 1, c: o + 1 };
  });
}

// validation_failures: canvas-broken's 1.0.0 is validated and working; a
// later version that never becomes ready is recorded `not_ready`, and one
// that dies before ready is recorded `died`; each reads a stream 1.0.0 does
// not, so once its validation fails the working version, 1.0.0, opens
// nothing until the person confirms its grant.
async function stepValidationFailures(page, name) {
  const first = await showCanvas(page, "broken");
  await until(first.frame, rootText, (t) => t === "broken 1.0.0", "canvas-broken 1.0.0 drawn");
  const start = await versions("canvas-broken");
  await showCanvas(page, "start");

  const outcomes = {};
  for (const [id, kind, feed, outcome] of [["brk1", "broken-quiet", "broken-quiet", "not_ready"], ["brk2", "broken-die", "broken-die", "died"]]) {
    const written = await ask({ op: "write", canvas: "canvas-broken", kind, streams: [{ name: "feed.results", subject: feed }] });
    if (!OK(written)) throw new Error(`canvas.write refused canvas-broken: ${JSON.stringify(written)}`);
    await publish(page, layout([{ id, tincture: "tincture:local.canvas-broken" }], { without: ["broken"] }));
    const from = (await instrument(page)).receipts.length;
    await lib.waitFor(async () => (await switcherIds(page)).includes(id), { timeoutMs: 30_000, what: `the switcher to list ${id}` });
    await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
    const regrant = await confirmRegrant(page, `tincture:local.canvas-broken:${start.working}`);
    const shown = await showCanvas(page, id);
    await until(shown.frame, rootText, (t) => t === `broken ${start.working}`, "the working version opened");
    const marks = await instrument(page);
    const after = await versions("canvas-broken");
    outcomes[kind] = {
      version: written.ok.version,
      validation: { readies: receiptsOf(marks, from, null, "ready").filter((r) => r.frame !== shown.id).length, failed: receiptsOf(marks, from, null, "failed").filter((r) => r.frame !== shown.id).length },
      recorded: after.failed,
      working: after.working,
      regrant,
      opened: await rootText(shown.frame),
      fallback_line: await notice(page),
      expected: outcome,
    };
    await showCanvas(page, "start");
  }
  await publish(page, layout());

  const quiet = outcomes["broken-quiet"];
  const die = outcomes["broken-die"];
  const waited = (o) => o.regrant.asked_for && o.regrant.place.refusal === "ungranted" && o.regrant.place.frame === null && o.fallback_line === null;
  note("validation_failures", name,
    start.working === "1.0.0" &&
      quiet.validation.readies === 0 && quiet.validation.failed === 0 && quiet.recorded && quiet.recorded.version === quiet.version && quiet.recorded.outcome === "not_ready" && quiet.working === "1.0.0" && waited(quiet) && quiet.opened === "broken 1.0.0" &&
      die.validation.readies === 0 && die.validation.failed === 1 && die.recorded && die.recorded.version === die.version && die.recorded.outcome === "died" && die.working === "1.0.0" && waited(die) && die.opened === "broken 1.0.0",
    { first: { working: start.working }, not_ready: quiet, died: die });
}

// crash_fallback: a version that becomes ready is validated and activated,
// then its live frame dies after ready(): the page reloads itself, a second
// load of its frame (desktop.md section 6: a live canvas falls back when its
// frame dies, not when its page throws), and no `failed` reaches the shell.
// The shipped canvas shows in its place, the window over it on the desk
// stays open, the same frame, and AQUA is as it was; one line offers to try
// again and the kept version. Restoring the kept version asks its own grant
// first, with the shipped canvas still in place and nothing restored, and
// once it is confirmed the kept version is restored, the line goes, and the
// kept version opens.
async function stepCrashFallback(page, name, viewport) {
  const written = await ask({ op: "write", canvas: "canvas-broken", kind: "broken-crash", streams: [{ name: "feed.results", subject: "broken-crash" }] });
  if (!OK(written)) throw new Error(`canvas.write refused canvas-broken: ${JSON.stringify(written)}`);
  const before = await versions("canvas-broken");
  const desk = viewport.posture === "desk";
  await publish(page, layout([{ id: "crash", tincture: "tincture:local.canvas-broken", postures: { desk: { apps: windowApp }, hand: { apps: [] } } }], { without: ["broken"] }));
  const start = await instrument(page);
  const from = start.receipts.length;
  const loadsFrom = start.loads.length;
  await page.click('#canvas-switcher button[data-canvas="crash"]');
  const windowBefore = desk ? await lib.waitFor(() => shownWindow(page), { timeoutMs: 30_000, what: "the crash canvas's window" }) : null;
  const aquaBefore = await aquaState(page);
  const line = await fallbackNotice(page, 40_000);
  const marks = await instrument(page);
  // The loads of each frame since the switch, by place: the validation
  // frame loads once; the live canvas frame, which reloaded itself, twice;
  // the shipped canvas in its place once.
  const loadsOf = (place) => {
    const by = {};
    for (const l of marks.loads.slice(loadsFrom).filter((l) => l.place === place)) by[l.frame] = (by[l.frame] || 0) + 1;
    return Object.values(by);
  };
  const reloaded = loadsOf("canvas").filter((n) => n >= 2).length;
  const activated = await versions("canvas-broken");
  const inPlace = await showCanvas(page, "crash");
  const drawn = await until(inPlace.frame, shippedDrawing, (d) => d.headings.includes("Apps"), "the shipped canvas in the crash canvas's place");
  const windowAfter = desk ? await shownWindow(page) : null;
  const aquaAfter = await aquaState(page);
  const kept = line.offers.find((o) => o.offer === "kept");
  // The kept version reads no stream, the crashed one's grant names one: its
  // restore waits for its own grant, and nothing is restored until the
  // person confirms it.
  await page.click('#system-layer-notice button[phx-value-offer="kept"]');
  const regrant = await confirmRegrant(page, `tincture:local.canvas-broken:${before.working}`, {
    whileOpen: () => versions("canvas-broken"),
  });
  await lib.waitFor(async () => ((await notice(page)) === null ? true : null), { timeoutMs: 20_000, what: "the fallback's notice gone" });
  const shown = await showCanvas(page, "crash");
  const text = await until(shown.frame, rootText, (t) => t === `broken ${before.working}`, "the kept version opened");
  const restored = await versions("canvas-broken");
  await showCanvas(page, "start");
  await publish(page, layout());

  const windowKept = !desk || (!!windowBefore && !!windowAfter && windowAfter.id === windowBefore.id && windowAfter.state === "live");
  note("crash_fallback", name,
    activated.working === written.ok.version && activated.kept === before.working &&
      receiptsOf(marks, from, null, "ready").length >= 1 && reloaded === 1 &&
      receiptsOf(marks, from, null, "failed").length === 0 &&
      line.text.startsWith("Your canvas stopped. Showing the standard one.") &&
      !!kept && kept.label === "Restore the last working one" && line.offers.map((o) => o.offer).join(",") === "retry,kept" &&
      drawn.headings.includes("Apps") && windowKept && JSON.stringify(aquaAfter) === JSON.stringify(aquaBefore) &&
      regrant.asked_for && regrant.meanwhile.working === written.ok.version && regrant.meanwhile.kept === before.working &&
      restored.working === before.working && restored.kept === written.ok.version && text === `broken ${before.working}`,
    {
      activated: { version: written.ok.version, working: activated.working, kept: activated.kept, validation_readies: receiptsOf(marks, from, null, "ready").length },
      crashed: { canvas_frame_loads: loadsOf("canvas"), validation_frame_loads: loadsOf("validation"), canvas_frames_loaded_twice: reloaded, failed_verbs: receiptsOf(marks, from, null, "failed").length },
      fallback: { line: line.text, offers: line.offers.map((o) => o.offer), kept_offer: kept && kept.label, in_place: drawn.headings.slice(0, 3), window: desk ? { before: windowBefore, after: windowAfter, kept: windowKept } : "none in the hand", aqua: { before: aquaBefore, after: aquaAfter } },
      regrant: { title: regrant.title, asked_for: regrant.asked_for, place: regrant.place, working: regrant.meanwhile.working, kept: regrant.meanwhile.kept },
      restored: { working: restored.working, kept: restored.kept, opened: text },
    });
}

// ---- activation ----------------------------------------------------------------

// The markets canvas shown, its press button bound to the feed, with the
// frame recorder installed and the buttons' coordinates measured.
async function marketsBound(page) {
  const shown = await showCanvas(page, "markets");
  await until(shown.frame, (f) => f.evaluate(() => window.__canvas ? window.__canvas.bound() : false), (b) => b === true, "the markets press bound to the feed");
  await shown.frame.evaluate(installRecorder);
  const box = async (sel) => shown.frame.locator(sel).boundingBox();
  const centers = {};
  for (const [key, sel] of [["press", "#press"], ["press3", "#press3"], ["later", "#later"], ["grant", "#grant"]]) {
    const b = await box(sel);
    centers[key] = b ? { x: b.x + b.width / 2, y: b.y + b.height / 2 } : null;
  }
  return { shown, centers };
}

// activation: a press the shell forwards to the view only within moments of
// the person's own input, on the shown canvas whose frame it focuses
// (`iframe_bridge.js`). A press dispatched by the page with no input, or
// held past the window, is dropped; one inside a click is forwarded, and
// several inside one click are each forwarded. The residual cases — a click
// elsewhere in the shell or in a sibling frame with the canvas focusing
// itself — are recorded per browser with no drop asserted.
async function stepActivation(page, name) {
  const { shown, centers } = await marketsBound(page);
  const frame = shown.frame;
  if (!centers.press || !centers.press3 || !centers.later) throw new Error("the markets buttons could not be measured");

  // Reads the instrument (on the shell page) and classifies the press
  // receipts of the markets frame since `from`. This evaluates on the shell,
  // never on a frame, so it leaves no user gesture on the canvas.
  const readMarks = () => instrument(page);
  const classify = (press) =>
    ({ forwarded: press.filter((r) => r.dropped === false).length, dropped: press.filter((r) => r.dropped === true).length, total: press.length, receipts: press });
  const since = async (from) => classify(receiptsOf(await readMarks(), from, shown.id, "press"));

  // One inside a click: a person's click on the button (personClick)
  // dispatches one press, inside the click, forwarded.
  let mark = (await readMarks()).receipts.length;
  await personClick(page, shown.id, centers.press.x, centers.press.y);
  const inside = classify(await handled(page, mark, shown.id, "press", 1));

  // Several inside one click: three presses, each forwarded.
  mark = (await readMarks()).receipts.length;
  await personClick(page, shown.id, centers.press3.x, centers.press3.y);
  const several = classify(await handled(page, mark, shown.id, "press", 3));

  // The residual cases, recorded per browser, no drop asserted. A click
  // elsewhere (the markets switcher button, in the shell; the sibling window
  // frame), then the canvas focuses itself and presses from a timer.
  const siblingBox = await page.$('[data-canvas-place="window"][data-canvas-shown="true"] iframe')
    .then((el) => el && el.boundingBox()).catch(() => null);
  const switcherBox = await page.$('#canvas-switcher button[data-canvas="markets"]').then((el) => el && el.boundingBox()).catch(() => null);
  const recorded = {};
  for (const target of ["shell", "sibling"]) {
    for (const focus of ["none", "window", "element"]) {
      const at = target === "shell" ? switcherBox : siblingBox;
      if (!at) {
        recorded[`${target}_${focus}`] = { not_recorded: target === "sibling" ? "no sibling frame beside the canvas in this posture" : "no shell control to click" };
        continue;
      }
      await frame.evaluate((m) => window.__canvas && window.__canvas.scheduleFocusPress(m, 500), focus);
      await sleep(350);
      const m0 = (await readMarks()).receipts.length;
      await page.mouse.click(at.x + at.width / 2, at.y + at.height / 2);
      await sleep(900);
      const r = await since(m0);
      const one = r.receipts[r.receipts.length - 1] || null;
      recorded[`${target}_${focus}`] = {
        forwarded: r.forwarded, dropped: r.dropped,
        active: one && one.active, active_element_is_frame: one && one.activeElementIsFrame,
      };
      // Keep markets the shown canvas (a shell-switcher click to the current
      // canvas is a no-op; confirm it still shows).
      await showCanvas(page, "markets").catch(() => null);
    }
  }

  // Held 8 s: a click schedules the press 8 s on, past the activation
  // window, so it is dropped. No evaluation on any frame while it is held.
  mark = (await readMarks()).receipts.length;
  const heldDropped0 = Number((await canvasFrame(page, shown.id)).dropped);
  await page.mouse.click(centers.later.x, centers.later.y);
  await sleep(8800);
  const held8 = await since(mark);
  const heldDropped1 = Number((await canvasFrame(page, shown.id)).dropped);

  // Scripted, no input: the page presses from a timer 9 s on, with no click
  // and no evaluation near it, so it is dropped.
  const noInputDropped0 = Number((await canvasFrame(page, shown.id)).dropped);
  mark = (await readMarks()).receipts.length;
  await frame.evaluate(() => window.__canvas && window.__canvas.pressAfter(9000));
  await sleep(9800);
  const noInput = await since(mark);
  const noInputDropped1 = Number((await canvasFrame(page, shown.id)).dropped);

  note("activation", name,
    inside.forwarded === 1 && inside.total === 1 && inside.receipts[0] && inside.receipts[0].active === true && inside.receipts[0].activeElementIsFrame === true &&
      several.forwarded === 3 && several.total === 3 &&
      held8.forwarded === 0 && heldDropped1 > heldDropped0 &&
      noInput.forwarded === 0 && noInputDropped1 > noInputDropped0,
    {
      inside_click: { forwarded: inside.forwarded, total: inside.total, active: inside.receipts[0] && inside.receipts[0].active, active_element_is_frame: inside.receipts[0] && inside.receipts[0].activeElementIsFrame },
      several_in_one_click: { forwarded: several.forwarded, total: several.total },
      held_8s: { forwarded: held8.forwarded, dropped_delta: heldDropped1 - heldDropped0 },
      scripted_no_input: { forwarded: noInput.forwarded, dropped_delta: noInputDropped1 - noInputDropped0 },
      recorded_residuals: recorded,
    });
  await showCanvas(page, "start");
}

// grant_control: a canvas's request for a component's grant leaves it as
// a press does: the grant control clicked by the person sends one `grant`,
// which the shell receives inside the click with its activation and the
// canvas its active element, and forwards; the same request sent from a
// timer with no input near it is dropped (the frame's `data-dropped`
// moves). The shell's offer of the grant, in the system layer, is checked
// once the shell handles the verb.
async function stepGrantControl(page, name) {
  const { shown, centers } = await marketsBound(page);
  if (!centers.grant) throw new Error("the markets grant control could not be measured");
  const classify = (receipts) =>
    ({ forwarded: receipts.filter((r) => r.dropped === false).length, dropped: receipts.filter((r) => r.dropped === true).length, total: receipts.length, receipts });

  let mark = (await instrument(page)).receipts.length;
  await personClick(page, shown.id, centers.grant.x, centers.grant.y);
  const inside = classify(await handled(page, mark, shown.id, "grant", 1));

  const dropped0 = Number((await canvasFrame(page, shown.id)).dropped);
  mark = (await instrument(page)).receipts.length;
  await shown.frame.evaluate(() => window.__canvas && window.__canvas.grantAfter(9000));
  await sleep(9800);
  const noInput = classify(receiptsOf(await instrument(page), mark, shown.id, "grant"));
  const dropped1 = Number((await canvasFrame(page, shown.id)).dropped);

  note("grant_control", name,
    inside.forwarded === 1 && inside.total === 1 && inside.receipts[0].active === true && inside.receipts[0].activeElementIsFrame === true &&
      noInput.total === 1 && noInput.forwarded === 0 && dropped1 > dropped0,
    {
      inside_click: { forwarded: inside.forwarded, total: inside.total, active: inside.receipts[0] && inside.receipts[0].active, active_element_is_frame: inside.receipts[0] && inside.receipts[0].activeElementIsFrame },
      scripted_no_input: { received: noInput.total, forwarded: noInput.forwarded, dropped_delta: dropped1 - dropped0 },
      offer: "not checked: the shell's handling of grant comes after S6",
    });
  await showCanvas(page, "start");
}

// rebound_control: the feed is removed and bound again with other
// arguments. feed.press naming the old binding is refused not_found, the
// canvas's stale press still names the old binding, and once a new result
// of the new binding reaches the canvas on a reopened stream its press
// names the new binding and the shell forwards it. The stream is reopened
// because an open feed stream was seen to keep its old binding after a
// rebind, an open finding the record and the README name; this step does
// not show what an open stream does across a rebind. Each press is the
// page's own, sent from its click handler inside a person's click
// (personClick) on the press button where it was measured on the frame
// shown at that moment, and each records what the shell did with it.
async function stepReboundControl(page, name) {
  const { shown, centers } = await marketsBound(page);
  const old = await feedState("candles");
  if (!centers.press) throw new Error("the markets press button could not be measured");

  // One click on the press button at `at` in the shown frame `on`: the
  // presses it posted, read from the page once the shell has received them,
  // and what the shell did with them.
  const pressAt = async (on, at) => {
    const from = (await instrument(page)).receipts.length;
    const n = (await posts(on.frame)).length;
    await personClick(page, on.id, at.x, at.y);
    const shell = receiptFacts(await handled(page, from, on.id, "press", 1));
    return { sent: (await posts(on.frame)).slice(n).filter((p) => p.verb === "press"), shell };
  };

  // While the binding is live, a press names it.
  const live = await pressAt(shown, centers.press);

  const symbol = `ETH-${name}`;
  const rebound = await ask({ op: "rebind", feed: "candles", args: { symbol } });
  if (!rebound || !rebound.bound || !OK(rebound.bound)) throw new Error(`the feed was not bound again: ${JSON.stringify(rebound)}`);
  const fresh = rebound.bound.ok.binding;

  // The canvas still holds the old binding, so a press before a new result
  // names it; the view drops it, since the old binding is no longer live.
  const stale = await pressAt(shown, centers.press);

  // feed.press naming the old binding is refused not_found.
  const refused = await ask({ op: "press", binding: old.binding, action: "refresh" });
  const refusal = typeof refused.error === "string" ? refused.error : null;

  // A result of the new binding reaches the canvas, whose press then names
  // the new binding and the shell forwards it.
  const accepted = await ask({ op: "accept", feed: "candles", data: { symbol, price: 2, change: null, at: new Date().toISOString().replace(/\.\d+Z$/, "Z"), candles: candles(symbol) } });
  // Switched away and back, markets' feed stream closes with its suspended
  // credential and opens again from its refresh, which carries the new
  // binding; then wait for it, and measure the press button on the frame
  // shown again before the click.
  await showCanvas(page, "start");
  const again = await showCanvas(page, "markets");
  await until(again.frame, (f) => f.evaluate(() => (window.__canvas ? window.__canvas.current() : null)), (b) => b === fresh, "the new binding reaching the canvas on reopen");
  await again.frame.evaluate(installRecorder);
  const at = await centerOf(again.frame.locator("#press"));
  if (!at) throw new Error("the markets press button could not be measured on the canvas shown again");
  const renewed = await pressAt(again, at);
  const forwarded = renewed.shell.forwarded;

  note("rebound_control", name,
    live.sent.length === 1 && live.sent[0].binding === old.binding &&
      fresh !== old.binding && rebound.old === old.binding &&
      stale.sent.length === 1 && stale.sent[0].binding === old.binding &&
      refusal === `{:not_found, "Feed", "${old.binding}"}` &&
      renewed.sent.length === 1 && renewed.sent[0].binding === fresh && forwarded === 1,
    {
      while_live: { press_names_current: live.sent.length === 1 && live.sent[0].binding === old.binding, shell: live.shell },
      rebound: { new_binding: fresh !== old.binding, args: { symbol } },
      stale_press: { dispatches: stale.sent.length, names_old_binding: stale.sent.length === 1 && stale.sent[0].binding === old.binding, shell: stale.shell },
      feed_press_naming_old: { refused: refusal !== null, not_found_naming_old: refusal === `{:not_found, "Feed", "${old.binding}"}`, refusal: refusal && refusal.slice(0, 160) },
      after_new_result: { accepted_revision: accepted.revision, new_press_names_new_binding: renewed.sent.length === 1 && renewed.sent[0].binding === fresh, forwarded, shell: renewed.shell },
      stream_reopened: {
        how: "markets switched away and back: its feed stream closes with the suspended credential and opens again from its refresh",
        why: "an open feed stream was once seen to keep its old binding after a rebind (one debug run, not proven)",
        open_finding: "on the follow-up list; its unit check: after a rebind, an open feed stream delivers the new binding's results or closes",
        shown_here: "not what an open stream does across a rebind",
      },
    });
  await showCanvas(page, "start");
}

// connection_allowlist: under the canvas page's connection-allowlist header
// the SDK, the page's own assets and its streams all work, in every browser.
async function stepConnectionAllowlist(page, name) {
  const shown = await showCanvas(page, "probe");
  const s = await until(shown.frame, probeState, (st) => st.stream.settled && st.stream.events >= 1 && st.candles > 0, "the probe's stream open under the header");
  const sdk = await shown.frame.evaluate(() => typeof window.cyfr === "object" && window.cyfr !== null && typeof window.cyfr.stream === "function");
  const css = await shown.frame.evaluate(() => {
    const root = document.getElementById("root");
    return root ? getComputedStyle(root).paddingTop : null;
  });
  const assetLoaded = css === "16px";
  note("connection_allowlist", name,
    sdk === true && assetLoaded && s.stream.opened && s.stream.events >= 1 && s.candles > 0,
    {
      sdk_loaded: sdk === true,
      asset_loaded: { style: "the probe's own probe.css applied #root padding", padding_top: css, loaded: assetLoaded },
      stream: { opened: s.stream.opened, events: s.stream.events, candles: s.candles },
      note: "all under the page's connection-allowlist header (its presence is checked in policy)",
    });
  await showCanvas(page, "start");
}

// ---- policy --------------------------------------------------------------------

// A GET of the canvas page from the harness (not from inside the frame),
// for its served response headers.
async function pagePolicy(path, origin, frameId) {
  const answer = await lib.askHome(HOME, path);
  const headers = answer.headers || {};
  const csp = headers["content-security-policy"] || "";
  const directive = (d) => {
    const found = csp.split(";").map((s) => s.trim()).find((s) => s === d || s.startsWith(d + " "));
    return found ? found.slice(d.length).trim().split(/\s+/).filter(Boolean) : null;
  };
  const esc = origin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // F, the version's files under the asset credential; K, the SDK's one
  // path named by its digest; D, the open's own data path.
  const filesRe = new RegExp(`^${esc}/_s/[^/]+/$`);
  const sdkRe = new RegExp(`^${esc}/_c/v1/sdk/[^/]+\\.js$`);
  const scriptSrc = directive("script-src") || [];
  const connectSrc = directive("connect-src") || [];
  const filesPrefix = scriptSrc.find((t) => filesRe.test(t)) || null;
  const sdk = scriptSrc.find((t) => sdkRe.test(t)) || null;
  const dataPath = `${origin}/_f/v1/o/${frameId}/`;
  return {
    status: answer.status,
    script_src_is_files_and_sdk: scriptSrc.length === 2 && !!filesPrefix && !!sdk,
    connect_src_is_data_and_files: connectSrc.length === 2 && connectSrc.includes(dataPath) && !!filesPrefix && connectSrc.includes(filesPrefix),
    allowlist: headers["connection-allowlist"] || null,
    no_access_control: !("access-control-allow-origin" in headers),
    // Redacted summaries only: the asset credential and the SDK digest are
    // replaced where they are recorded.
    script_src: scriptSrc.map((t) => t.replace(/\/_s\/[^/]+\//, "/_s/[credential]/").replace(/\/sdk\/[^/]+$/, "/sdk/[digest]")),
    connect_src: connectSrc.map((t) => t.replace(/\/_s\/[^/]+\//, "/_s/[credential]/").replace(/\/o\/[^/]+\//, "/o/[frame]/")),
  };
}

// A POST to the home as the front forwards a browser's request, under an
// optional bearer: its status and body, for the data routes' refusals.
function homeRequest({ method = "POST", path, bearer = null, body = "{}" }) {
  const headers = {
    host: HOME.host,
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
    "x-forwarded-for": "127.0.0.1",
    "x-forwarded-proto": "https",
    "x-forwarded-host": HOME.host,
  };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port: HOME.port, method, path, headers, timeout: 30_000 }, (res) => {
      let data = "";
      res.setEncoding("utf8");
      res.on("data", (c) => { data += c; });
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

// policy: ordinary requests and checks on a canvas open, none framed as an
// escape. The page's served policy, a foreign script element, a fetch its
// connect-src refuses, Chromium's connection allowlist against a peer
// connection, the data routes' refusals of a canvas credential, and an open
// carrying arguments.
async function stepPolicy(page, name, proxy, receiver, udp) {
  const probe = await showCanvas(page, "probe");
  await until(probe.frame, probeState, (s) => s.stream.settled, "the probe drawn with its stream open");
  const origin = new URL(page.url()).origin;
  const src = await probe.el.getAttribute("src");
  const pagePath = new URL(src, origin).pathname + new URL(src, origin).search;

  // 1. The page's policy as served.
  const policy = await pagePolicy(pagePath, origin, probe.id);

  // 2. A script element with a foreign src: it does not load and no request
  // reaches the recording endpoint.
  const receiverMark = receiver.log.length;
  const proxyMark = proxy.seen.length;
  const foreign = await probe.frame.evaluate((url) => window.__probe.foreignScript(url), `https://${lib.ATTACKER}/collect.js`);
  await sleep(500);
  const attackerRequests = proxy.seen.slice(proxyMark).filter((r) => r.host === lib.ATTACKER).length + (receiver.log.length - receiverMark);

  // 3. A fetch to routes the policy's connect-src does not name: refused
  // before a request is sent.
  const invokeFetch = await probe.frame.evaluate(() => window.__probe.blockedFetch("/_f/v1/invoke"));
  const webhookFetch = await probe.frame.evaluate(() => window.__probe.blockedFetch("/hooks/canvas-proof"));
  await sleep(300);
  const pathOf = (r) => { try { return new URL(r.url).pathname; } catch { return ""; } };
  const blockedReached = proxy.seen.slice(proxyMark).filter((r) => r.host === lib.SITE && (pathOf(r) === "/_f/v1/invoke" || pathOf(r).startsWith("/hooks/"))).length;

  // 4. The connection allowlist against a peer connection. The listener is
  // on loopback: a browser other than Chromium that sends it nothing has not
  // shown the disclosure here, and the canvas plan's Appendix A.3 measured
  // it against a non-loopback address.
  const udpMark = udp.packets;
  await probe.frame.evaluate(({ host, port }) => window.__probe.peerConnection(host, port), { host: "127.0.0.1", port: udp.port });
  await sleep(2500);
  const udpPackets = udp.packets - udpMark;

  // 5. The canvas open has no write route. A canvas credential on the
  // shared invoke route is refused canvas_path_required; a credential of
  // another open on this canvas's data path is refused frame_path_mismatch;
  // the canvas's own data path has no invoke route.
  const minted = await ask({ op: "bearer", reference: "tincture:local.canvas-probe:1.0.0" });
  if (!minted || typeof minted.bearer !== "string" || !minted.bearer) throw new Error("the fixture minted no canvas credential");
  secrets.push(minted.bearer);
  const sharedInvoke = await homeRequest({ path: "/_f/v1/invoke", bearer: minted.bearer, body: JSON.stringify({ v: 1, ref: "c:local.x:1.0.0", operation: "run", args: {} }) });
  const mismatch = await homeRequest({ path: `/_f/v1/o/${probe.id}/stream`, bearer: minted.bearer, body: JSON.stringify({ v: 1, stream: "feed.results", subject: "candles" }) });
  const ownInvoke = await homeRequest({ path: `/_f/v1/o/${probe.id}/invoke`, bearer: minted.bearer, body: JSON.stringify({ v: 1 }) });
  const routes = {
    shared_invoke: { status: sharedInvoke.status, canvas_path_required: sharedInvoke.body.includes("canvas_path_required") },
    data_path_mismatch: { status: mismatch.status, frame_path_mismatch: mismatch.body.includes("frame_path_mismatch") },
    own_data_path_invoke: { status: ownInvoke.status, no_route: ownInvoke.status === 404 },
  };

  // 6. An open carrying arguments beyond ref is dropped by the bridge: no
  // tincture opens, none is forwarded and the frame's data-dropped moves.
  const droppedBefore = Number((await canvasFrame(page, probe.id)).dropped);
  const openFrom = (await instrument(page)).receipts.length;
  const fullBefore = await page.$('[data-canvas-place="full"][data-canvas-shown="true"] iframe');
  await probe.frame.evaluate(() => window.__probe.openRaw());
  await sleep(600);
  const droppedAfter = Number((await canvasFrame(page, probe.id)).dropped);
  const fullAfter = await page.$('[data-canvas-place="full"][data-canvas-shown="true"] iframe');
  const openForwarded = receiptsOf(await instrument(page), openFrom, probe.id, "open").filter((r) => r.dropped === false).length;
  const openDropped = { dropped_delta: droppedAfter - droppedBefore, forwarded: openForwarded, no_full_opened: !fullBefore && !fullAfter };

  const chromiumAllowlist = name !== "chromium" || udpPackets === 0;

  note("policy", name,
    policy.status === 200 && policy.script_src_is_files_and_sdk && policy.connect_src_is_data_and_files &&
      policy.allowlist === "(response-origin)" && policy.no_access_control &&
      foreign.outcome === "error" && attackerRequests === 0 &&
      invokeFetch.outcome === "refused" && webhookFetch.outcome === "refused" && blockedReached === 0 &&
      chromiumAllowlist &&
      routes.shared_invoke.canvas_path_required && routes.data_path_mismatch.frame_path_mismatch && routes.own_data_path_invoke.no_route &&
      openDropped.dropped_delta >= 1 && openDropped.forwarded === 0 && openDropped.no_full_opened,
    {
      served_policy: policy,
      foreign_script: { outcome: foreign.outcome, attacker_requests: attackerRequests },
      blocked_fetch: { invoke: invokeFetch.outcome, webhook: webhookFetch.outcome, requests_at_proxy: blockedReached },
      connection_allowlist: name === "chromium"
        ? { browser: name, udp_packets: udpPackets, chromium_sends_none: udpPackets === 0 }
        : {
          browser: name, udp_packets: udpPackets,
          disclosure: udpPackets > 0
            ? "recorded (disclosure P1 (a))"
            : "not demonstrated against the loopback listener, which no packet reached; the canvas plan's Appendix A.3 measurement against a non-loopback address stands",
        },
      data_routes: routes,
      open_with_arguments: openDropped,
    });
  await showCanvas(page, "start");
}

// disconnect: the socket is cut and regained; while it is down the canvas is
// marked disconnected and its frame is inert, and after it the canvas is
// live and acts again.
async function stepDisconnect(page, name, proxy, viewport) {
  const start = await showCanvas(page, "start");
  const marker = () => page.$eval("#canvas-status [data-canvas-connection]", (e) => ({ state: e.dataset.canvasConnection, hidden: e.hidden })).catch(() => null);
  proxy.cut();
  const down = await lib.waitFor(async () => {
    const m = await marker();
    return m && m.state === "disconnected" && !m.hidden ? m : null;
  }, { timeoutMs: 30_000, stepMs: 100, what: "the canvas marked disconnected" }).catch(() => null);
  const inert = await canvasFrame(page, start.id);
  const drawnWhileDown = inert ? await shippedDrawing(inert.frame) : null;
  proxy.restore();
  const up = await lib.waitFor(async () => {
    const m = await marker();
    return m && m.state === "connected" && m.hidden ? m : null;
  }, { timeoutMs: 60_000, stepMs: 250, what: "the canvas connected again" }).catch(() => null);
  const again = await lib.waitFor(async () => {
    const s = await shownCanvasFrame(page);
    if (!s || s.state !== "live" || s.inert) return null;
    const d = await shippedDrawing(s.frame);
    return d && d.headings.includes("Apps") ? s : null;
  }, { timeoutMs: 45_000, stepMs: 100, what: "the canvas live again" }).catch(() => null);
  const acts = again ? await showCanvas(page, "markets").then(() => true).catch(() => false) : false;
  note("disconnect", name, !!down && !!inert && inert.inert && !!drawnWhileDown && !!up && !!again && acts,
    {
      device: viewport.device, posture: viewport.posture,
      while_down: { marked: down, frame_inert: inert && inert.inert, still_drawn: !!drawnWhileDown },
      after: { marked: up, canvas_live: !!again, switches_again: acts },
    });
  await showCanvas(page, "start");
}

// failed_fire: the scheduler's own failed fire leaves the fixture's claim
// acceptable (fixture.exs `failed_fire`).
async function stepFailedFire(page, name) {
  const answer = await ask({ op: "failed_fire" }, { timeoutMs: 210_000 });
  const fire = answer && answer.fire;
  const outcome = fire
    ? `${fire.fires} fire(s) ended: ${fire.runs} run(s), ${fire.errors} error(s); the accepted seq ${fire.accepted_before === fire.accepted_at_fire ? "did not move" : "moved"}`
    : null;
  note("failed_fire", name,
    !!fire && fire.fired_seq > fire.claimed && fire.fires >= 1 && fire.runs === 0 && fire.errors >= 1 &&
      fire.accepted_before === fire.accepted_at_fire && typeof fire.accepted_revision === "number" && fire.accepted_revision === fire.claimed &&
      answer.removed && OK(answer.removed),
    fire ? {
      claimed: fire.claimed, fired_seq: fire.fired_seq, fires: fire.fires, runs: fire.runs, errors: fire.errors,
      accepted_before: fire.accepted_before, accepted_at_fire: fire.accepted_at_fire, accepted_revision: fire.accepted_revision,
      waited_ms: fire.waited_ms, outcome, cause: "not observable: the store records no reason for a fire's error",
      binding_removed: !!(answer.removed && OK(answer.removed)),
    } : { answer });
}

// ---- the measurement -------------------------------------------------------------

function measureLayout(id) {
  return { version: 3, canvases: [
    { id: "start", tincture: "tincture:local.canvas", postures: {} },
    { id, tincture: "tincture:local.measure", postures: {} },
  ] };
}

// One frame open: the switch click's mark to the shell's receipt of that
// live canvas frame's `ready`, with no validation frame between.
async function sampleOpen(page, id) {
  const before = await instrument(page);
  const known = new Set(before.receipts.map((r) => r.frame));
  await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
  const found = await lib.waitFor(async () => {
    const m = await instrument(page);
    const click = m.clicks.slice(before.clicks.length).find((c) => c.canvas === id);
    if (!click) return null;
    const ready = m.receipts.slice(before.receipts.length).find((r) => r.verb === "ready" && r.kind === "canvas" && !known.has(r.frame));
    return ready ? { click, ready, between: m.receipts.slice(before.receipts.length).filter((r) => r.at < ready.at) } : null;
  }, { timeoutMs: SAMPLE_MS, stepMs: 25, what: `${id}'s ready` });
  const live = await canvasFrame(page, found.ready.frame);
  const between = found.between.map((r) => r.verb);
  return {
    ms: found.ready.at - found.click.at,
    ordered: found.ready.at >= found.click.at,
    frame: found.ready.frame,
    place: live ? live.place : null,
    between,
    fresh: !between.includes("failed"),
  };
}

// A sample counts only when the instrument saw a fresh live open.
function freshOpen(id, s) {
  if (s.place !== "canvas" || !s.fresh) throw new Error(`${id}'s ready was not a fresh live open: ${JSON.stringify({ place: s.place, between: s.between })}`);
  return s;
}

// One validation: the switch click's mark to the shell's receipt of the
// validation frame's `ready`; the canvas then shows live.
async function sampleValidation(page, id) {
  const before = await instrument(page);
  await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
  const found = await lib.waitFor(async () => {
    const m = await instrument(page);
    const click = m.clicks.slice(before.clicks.length).find((c) => c.canvas === id);
    if (!click) return null;
    const ready = m.receipts.slice(before.receipts.length).find((r) => r.verb === "ready" && r.kind === "canvas");
    return ready ? { click, validation: ready } : null;
  }, { timeoutMs: SAMPLE_MS, stepMs: 25, what: `${id}'s validation ready` });
  const live = await lib.waitFor(async () => {
    const m = await instrument(page);
    return m.receipts.slice(before.receipts.length).find((r) => r.verb === "ready" && r.kind === "canvas" && r.frame !== found.validation.frame) || null;
  }, { timeoutMs: SAMPLE_MS, stepMs: 25, what: `${id} live after its validation` });
  return { ms: found.validation.at - found.click.at, ordered: found.validation.at >= found.click.at && live.at >= found.validation.at, frame: found.validation.frame, live: live.frame };
}

async function measurement(page) {
  const m = record.measurement;
  // The measured canvas's first version, validated and activated, and the
  // instrument checked on one validation and one open.
  await publish(page, measureLayout("mz"));
  await showCanvas(page, "start");
  const handed0 = await instrument(page);
  const firstValidation = await sampleValidation(page, "mz");
  const working = await versions("measure");
  await showCanvas(page, "start");
  await publish(page, measureLayout("mo"));
  const firstOpen = await sampleOpen(page, "mo");
  const opened = await showCanvas(page, "mo");
  const draws = await until(opened.frame, rootText, (t) => t === "measure", "the measured canvas drawn");
  const handed1 = await instrument(page);
  const dropped = await page.$$eval('iframe[data-frame-kind="canvas"]', (els) => els.map((e) => Number(e.dataset.dropped || "0")).reduce((a, b) => a + b, 0));
  m.instrument_check = {
    validation: { click_then_ready_then_live_ready: firstValidation.ordered, ready_frame_is_not_the_live_frame: firstValidation.frame !== firstValidation.live },
    open: {
      click_then_ready: firstOpen.ordered,
      ready_frame_place: firstOpen.place,
      received_between: firstOpen.between,
      fresh_live_frame_with_no_validation_between: firstOpen.place === "canvas" && firstOpen.fresh,
    },
    bridge_handed_every_message_on: handed1.seen === handed1.handed && handed1.seen > handed0.seen,
    bridge_dropped: dropped,
    tree_reached_prism: working.working === "0.1.0",
    canvas_answers_and_opens: draws === "measure",
  };
  const instrumentOk = firstValidation.ordered && firstValidation.frame !== firstValidation.live && firstOpen.ordered &&
    m.instrument_check.open.fresh_live_frame_with_no_validation_between &&
    m.instrument_check.bridge_handed_every_message_on &&
    dropped === 0 && m.instrument_check.tree_reached_prism && m.instrument_check.canvas_answers_and_opens;
  if (!instrumentOk) throw new Error(`the instrument's own check failed: ${JSON.stringify(m.instrument_check)}`);
  await showCanvas(page, "start");

  const open = [];
  const validation = [];
  const round = (x) => Math.round(x * 10) / 10;
  const pct = (values) => {
    const p = lib.percentiles(values);
    return { p50: p.p50 === null ? null : round(p.p50), p95: p.p95 === null ? null : round(p.p95), clock: CLOCK };
  };
  const tally = () => {
    m.counts = { open: open.length, validation: validation.length };
    m.frame_open_ms = { ...pct(open), from: "the switch click", to: "the shell's receipt of the live canvas frame's ready" };
    m.validation_ms = { ...pct(validation), from: "the switch click", to: "the shell's receipt of the validation frame's ready" };
    m.samples_ms = { open: open.map(round), validation: validation.map(round) };
  };
  tally();
  for (let i = 1; i <= SAMPLES; i++) {
    await publish(page, measureLayout(`open${i}`));
    const s = freshOpen(`open${i}`, await sampleOpen(page, `open${i}`));
    if (!s.ordered) throw new Error(`frame open ${i} has its marks out of order`);
    open.push(s.ms);
    tally();
    await showCanvas(page, "start");
  }
  for (let i = 1; i <= SAMPLES; i++) {
    const written = await ask({ op: "write", canvas: "measure", kind: "measure", streams: [] });
    if (!OK(written)) throw new Error(`canvas.write refused measure: ${JSON.stringify(written)}`);
    await publish(page, measureLayout(`val${i}`));
    const s = await sampleValidation(page, `val${i}`);
    if (!s.ordered) throw new Error(`validation ${i} has its marks out of order`);
    validation.push(s.ms);
    tally();
    await showCanvas(page, "start");
  }
  await publish(page, layout());
}

// ---- running one browser --------------------------------------------------------

async function recover(page) {
  await openShell(page).catch(() => null);
  if (await notice(page)) await page.click('#system-layer-notice button[phx-value-offer="retry"]').catch(() => null);
  await publish(page, layout()).catch(() => null);
  held.clear();
}

async function runBrowser(name, viewport, proxy, receiver, udp, { only, measuring }) {
  let browser;
  try {
    browser = await lib.launchBrowser(name, proxy);
  } catch (error) {
    for (const step of ORDER.filter((s) => browsersOf(s).includes(name))) absent(step, name, error.message);
    return;
  }
  record.browsers[name] = browser.version();
  held.clear();
  const steps = ORDER.filter((s) => browsersOf(s).includes(name) && (!only || only.includes(s)));
  const ctx = await context(browser, name, BASE, COOKIE, viewport);
  try {
    const page = await ctx.newPage();
    page.__log = [];
    page.on("console", (m) => page.__log.push(redact(`${m.type()}: ${m.text()}`).slice(0, 200)));
    page.on("pageerror", (e) => page.__log.push(redact(`pageerror: ${e.message}`).slice(0, 200)));
    await ask({ op: "layout", document: layout() });
    await openShell(page);
    for (const step of steps) {
      try {
        await STEP_FNS[step](page, name, { proxy, receiver, udp, viewport });
      } catch (error) {
        const shell = await diagnose(page).catch(() => null);
        note(step, name, false, { error: redact(error.message).slice(0, 400), shell });
        await recover(page);
      }
    }
    if (measuring) {
      try {
        await measurement(page);
      } catch (error) {
        record.measurement.error = redact(error.message).slice(0, 400);
        record.measurement.shell = redacted(await diagnose(page).catch(() => null));
      }
    }
  } finally {
    await ctx.close().catch(() => null);
    await browser.close().catch(() => null);
  }
}

const STEP_FNS = {
  two_canvases: (page, name, { viewport }) => stepTwoCanvases(page, name, viewport),
  attention_moves: (page, name, { viewport }) => stepAttentionMoves(page, name, viewport),
  switch: async () => {},
  written_canvas: (page, name) => stepWrittenCanvas(page, name),
  feed_chart: (page, name) => stepFeedChart(page, name),
  app_over_canvas: (page, name) => stepAppOverCanvas(page, name),
  window_drag: (page, name, { viewport }) => stepWindows(page, name, viewport),
  tile_narrows: async () => {},
  covered_windows: async () => {},
  frame_kept: (page, name, { viewport }) => stepFrameKept(page, name, viewport),
  hidden_canvas: (page, name, { proxy }) => stepHiddenCanvas(page, name, proxy),
  activation: (page, name) => stepActivation(page, name),
  grant_control: (page, name) => stepGrantControl(page, name),
  rebound_control: (page, name) => stepReboundControl(page, name),
  connection_allowlist: (page, name) => stepConnectionAllowlist(page, name),
  policy: (page, name, { proxy, receiver, udp }) => stepPolicy(page, name, proxy, receiver, udp),
  validation_failures: (page, name) => stepValidationFailures(page, name),
  crash_fallback: (page, name, { viewport }) => stepCrashFallback(page, name, viewport),
  disconnect: (page, name, { proxy, viewport }) => stepDisconnect(page, name, proxy, viewport),
  failed_fire: (page, name) => stepFailedFire(page, name),
};

let BASE = null;
let COOKIE = null;
let HOME = null;

// The local UDP listener a worker's peer connection would send to.
function startUdp() {
  return new Promise((resolve) => {
    const socket = createSocket("udp4");
    const udp = { packets: 0, port: null, close: () => socket.close() };
    socket.on("message", () => { udp.packets += 1; });
    socket.bind(0, "127.0.0.1", () => {
      udp.port = socket.address().port;
      resolve(udp);
    });
  });
}

// ---- the record's table ----------------------------------------------------------

function renderMd(rec) {
  const cell = (step, browser) => {
    const on = browsersOf(step);
    if (!on.includes(browser)) return "Chromium only";
    const e = rec.steps[step] && rec.steps[step].browsers[browser];
    return e ? e.result : "not reached";
  };
  const m = rec.measurement;
  const budget = budgetOf(rec.host.class);
  const row = (label, key, count) => `| ${label} | ${count} | ${m[key] ? m[key].p50 : null} | ${m[key] ? m[key].p95 : null} | ${budget ? budget[key] : "none"} | ${m[key] ? m[key].clock : CLOCK} |`;
  return [
    `# The canvas proof: ${rec.viewport} (${rec.device}, posture ${rec.posture})`,
    "",
    `Recorded on ${rec.date} on ${rec.host.name} (${rec.host.cpu}, ${rec.host.cores} cores), host class ${rec.host.class}, on a SQLite cell, in the pinned Playwright image.`,
    `Browsers: ${ALL.map((b) => `${b} ${rec.browsers[b] || "absent"}`).join(", ")}.`,
    `Feed results: fixed results the fixture accepted; no run executed (${rec.executed_runs} executed).`,
    ...(rec.narrowed ? ["", `Narrowed run (${JSON.stringify(rec.narrowed)}): not the proof's record.`] : []),
    "",
    `| step | ${ALL.join(" | ")} |`,
    `|---|${ALL.map(() => "---").join("|")}|`,
    ...STEPS.map(([step]) => `| ${step} | ${ALL.map((b) => cell(step, b)).join(" | ")} |`),
    "",
    `## Measurement (Chromium ${rec.browsers.chromium || "absent"}, ${rec.viewport})`,
    "",
    `| number | samples | p50 (ms) | p95 (ms) | p95 budget (ms) | clock |`,
    `|---|---|---|---|---|---|`,
    row("frame open: switch click to the shell's receipt of ready", "frame_open_ms", m.counts ? m.counts.open : 0),
    row("validation: switch click to the shell's receipt of the validation ready", "validation_ms", m.counts ? m.counts.validation : 0),
    ...(m.error ? ["", `The measurement did not finish: ${m.error}`] : []),
    "",
  ].join("\n");
}

// ---- main ------------------------------------------------------------------------

async function main() {
  const argv = process.argv.slice(2);
  if (argv[0] === "--check-record") {
    const rec = JSON.parse(readFileSync(argv[1], "utf8"));
    const known = argv[2] && existsSync(argv[2]) ? JSON.parse(readFileSync(argv[2], "utf8")) : [];
    const fails = recordChecks(rec, known);
    for (const f of fails) console.error(`record check FAILED: ${f}`);
    if (fails.length) process.exit(1);
    console.log("ok: the record passes its checks");
    return;
  }

  const [segment, cookie, outDir, viewportName, narrowing, hostClass] = argv;
  const viewport = VIEWPORTS[viewportName];
  if (!segment || !cookie || !outDir || !viewport || !budgetOf(hostClass)) {
    console.error(`usage: node proof.mjs SEGMENT COOKIE OUT_DIR desktop|720x720 NARROWING ${Object.keys(BUDGET_MS).join("|")}`);
    process.exit(64);
  }
  lib = await import("../browser/lib.mjs");
  sleep = lib.sleep;
  OUT = outDir;
  COOKIE = cookie;
  secrets.push(cookie);
  mkdirSync(outDir, { recursive: true });

  const narrowed = {};
  for (const pair of (narrowing || "").split(";").filter(Boolean)) {
    const [k, v] = pair.split("=");
    if (k === "browsers" || k === "steps") narrowed[k] = v.split(",");
    if (k === "measure") narrowed.measure = v !== "0";
  }

  const host = { name: hostname(), cpu: (cpus()[0] || {}).model || "unknown", cores: cpus().length, class: hostClass };
  const date = new Date().toISOString().slice(0, 10);
  Object.assign(record, {
    suite: "canvas",
    viewport: viewportName, posture: viewport.posture, device: viewport.device,
    adapter: "sqlite", executed_runs: 0, feed_results: "fixed",
    date, host,
  });
  if (Object.keys(narrowed).length) record.narrowed = narrowed;
  Object.assign(record.measurement, { date, host, viewport: viewportName, clock: CLOCK, counts: { open: 0, validation: 0 }, budget_ms: BUDGET_MS[hostClass] });

  const receiver = await lib.startReceiver();
  const udp = await startUdp();
  const homes = lib.readHomes();
  HOME = lib.homeOf(homes.homes);
  BASE = HOME.origin;
  SHELL_URL = `${BASE}/a/${encodeURIComponent(segment)}/canvas`;
  const proxy = await lib.startProxy({ ...homes, receiver, bodies: false });

  let failure = null;
  try {
    for (const name of ALL.filter((b) => !narrowed.browsers || narrowed.browsers.includes(b))) {
      const measuring = name === "chromium" && narrowed.measure !== false;
      await runBrowser(name, viewport, proxy, receiver, udp, { only: narrowed.steps || null, measuring });
    }
    record.measurement.chromium = record.browsers.chromium || null;
  } catch (error) {
    failure = redact(error.stack || String(error)).slice(0, 2000);
    console.error(`FAIL: ${failure}`);
  } finally {
    proxy.close();
    receiver.close();
    udp.close();
  }

  const final = redacted(record);
  writeFileSync(join(outDir, "canvas-proof.json"), JSON.stringify(final, null, 2) + "\n");
  const md = renderMd(final);
  writeFileSync(join(outDir, "canvas-proof.md"), md);
  console.log(md);

  const fails = recordChecks(final, secrets);
  for (const f of fails) console.error(`record check FAILED: ${f}`);
  const m = final.measurement;
  const measured = m.counts.open === SAMPLES && m.counts.validation === SAMPLES && !m.error;
  if (!measured) console.error(`FAIL: the measurement has ${m.counts.open} frame opens and ${m.counts.validation} validations of ${SAMPLES} each${m.error ? `: ${m.error}` : ""}`);
  const unheld = STEPS.some(([step, browsers]) => browsers.some((b) => {
    const e = final.steps[step] && final.steps[step].browsers[b];
    return !e || e.result !== "held";
  }));
  if (failure || fails.length || unheld || !measured) {
    console.error("FAIL: the canvas proof did not hold");
    process.exit(1);
  }
  console.log("ok: every step held, the measurement has its samples within their budgets and the record passes its checks");
}

main().catch((error) => {
  console.error(`FAIL: ${redact(error.stack || String(error))}`);
  process.exit(1);
});
