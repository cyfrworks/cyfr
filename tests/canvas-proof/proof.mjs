// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The canvas proof, run in the official Playwright image by run.sh against a
// `cyfr` release holding the shipped canvas and the proof's tinctures
// (tinctures/), the canvases written for it and the feeds bound for them
// (fixture.exs through run.sh). It establishes, in real browsers, the Prism
// shell's canvases — its bridge, the canvas validation, the switcher and
// the edge strip — and the toolkit's confinement of a canvas's code, against
// the real host page, toolkit and served versions.
//
// For every browser the image ships, the fixture's person opens the shell
// and the proof drives the steps the README names, each recorded by name
// with the browsers it runs on, its observation and its result (STEPS).
// Chromium runs every step; Firefox and WebKit also run `exits`,
// `worker_policy`, `labels`, `activation_once` and `rebound_control`. A
// browser that cannot launch fails its steps and is recorded absent, never
// as a pass.
//
// The measurement (Chromium) times 20 frame opens (a switch click to the
// shell's receipt of the canvas frame's `ready`) and 20 validations (a
// switch click to the shell's receipt of the validation frame's `tree`) on
// `performance.now()` in the shell's document, read through an init script
// (INSTRUMENT) that records the click and wraps the shell's port handlers.
// It changes no message and records nothing of a boot, bearer, argument or
// stream payload. Each number's p95 is held to its budget (BUDGET_MS, the
// canvas budgets ARCHITECTURE.md §6.9 states) for the host class the run
// names, at both viewports, and a record over either fails the run.
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
// Usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR VIEWPORT NARROWING HOST_CLASS
//        (NARROWING may be empty; HOST_CLASS is a class of BUDGET_MS)
//    or: node proof.mjs --check-record RECORD_JSON [SECRETS_JSON]

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { hostname, cpus } from "node:os";
import { createSocket } from "node:dgram";
// Its asks and redaction only: lib.mjs loads without Playwright's library,
// so the record check runs without a browser.
import { ask as askRunSh, redact as redactKnown } from "../browser/lib.mjs";

// Each step and the browsers it runs on, in the record's order.
const ALL = ["chromium", "firefox", "webkit"];
const STEPS = [
  ["two_canvases", ["chromium"]],
  ["switch", ["chromium"]],
  ["written_canvas", ["chromium"]],
  ["feed_chart", ["chromium"]],
  ["app_over_canvas", ["chromium"]],
  ["worker_stop", ["chromium"]],
  ["validation_failures", ["chromium"]],
  ["crash_safe_mode", ["chromium"]],
  ["exits", ALL],
  ["worker_policy", ALL],
  ["labels", ALL],
  ["activation_once", ALL],
  ["rebound_control", ALL],
  ["disconnect", ["chromium"]],
  ["failed_fire", ["chromium"]],
];

// The order a browser runs its steps in. `labels` fails its canvas closed,
// which is safe mode `crashed`, so it follows the steps that need the
// canvases held; the steps on canvas-broken follow it, and the socket cut and
// the scheduler's fire come last.
const ORDER = [
  "two_canvases", "switch", "written_canvas", "feed_chart", "app_over_canvas", "worker_stop",
  "exits", "worker_policy", "activation_once", "rebound_control", "labels",
  "validation_failures", "crash_safe_mode", "disconnect", "failed_fire",
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
// A sample with no `ready` or `tree` within this long fails the run.
const SAMPLE_MS = 10_000;
const FORGED = "forged-by-neighbour";

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

const hasObservation = (value) =>
  value !== null && value !== undefined && (typeof value !== "object" || Object.keys(value).length > 0);

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
// records performance.now() with the message's verb and frame, and then
// calls the handler with the same event. It counts the messages the wrapper
// saw and the ones it handed on, and records nothing else.
const INSTRUMENT = `(() => {
  if (window.top !== window) return;
  const marks = { clicks: [], receipts: [], seen: 0, handed: 0 };
  Object.defineProperty(window, "__canvasInstrument", { value: marks, configurable: true });
  window.addEventListener("click", (event) => {
    const target = event.target && event.target.closest
      ? event.target.closest("#canvas-switcher button[data-canvas]") : null;
    if (target) marks.clicks.push({ at: performance.now(), canvas: target.getAttribute("data-canvas") });
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
          if (data && typeof data === "object" && typeof data.verb === "string" && typeof data.frame === "string") {
            marks.receipts.push({ at: performance.now(), verb: data.verb, frame: data.frame });
          }
          try {
            return handler.call(this, event);
          } finally {
            marks.handed += 1;
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
    return m ? { clicks: [...m.clicks], receipts: [...m.receipts], seen: m.seen, handed: m.handed } : null;
  });

// ---- the frame recorder (a canvas frame's document) -----------------------------
//
// Installed by the proof in one canvas frame's own document, after the
// toolkit started: it records each message the toolkit posts to the shell
// over its port (the verb, a press's binding and action, and the event the
// post happened during), and keeps the last trusted click on a control, so
// it can be dispatched again. The toolkit dispatches a press synchronously
// in its handler, so once a click or a key returns, what it posted is here.
function installRecorder() {
  if (window.__proofPosts) return true;
  const posts = [];
  Object.defineProperty(window, "__proofPosts", { value: posts });
  const original = MessagePort.prototype.postMessage;
  MessagePort.prototype.postMessage = function (message, ...rest) {
    if (message && typeof message === "object" && typeof message.verb === "string") {
      const event = window.event;
      posts.push({
        verb: message.verb,
        binding: (message.args && message.args.binding) || null,
        action: (message.args && message.args.action) || null,
        stage: (message.args && message.args.stage) || null,
        during: event ? { type: event.type, trusted: event.isTrusted === true, repeat: event.repeat === true } : null,
      });
    }
    return original.call(this, message, ...rest);
  };
  window.addEventListener("click", (event) => {
    const control = event.target && event.target.closest ? event.target.closest(".cyfr-control") : null;
    if (control && event.isTrusted) window.__proofClick = event;
  }, true);
  return true;
}

const posts = (frame) => frame.evaluate(() => [...(window.__proofPosts || [])]);

// ---- the shell -----------------------------------------------------------------

let lib = null;

async function context(browser, name, base, cookie, viewport) {
  const touch = viewport.posture === "hand";
  const options = { viewport: { width: viewport.width, height: viewport.height }, hasTouch: touch };
  if (touch && name !== "firefox") options.isMobile = true;
  const ctx = await browser.newContext(options);
  await ctx.addInitScript(INSTRUMENT);
  await ctx.addCookies([{ name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: false, sameSite: "Lax" }]);
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
  const el = await page.$('[data-canvas-place="canvas"][data-canvas-shown="true"] iframe[data-frame-wire="canvas"]');
  if (!el) return null;
  const facts = await el.evaluate((e) => ({ id: e.getAttribute("data-frame-id"), state: e.getAttribute("data-frame-state"), inert: e.inert === true })).catch(() => null);
  if (!facts) return null;
  const frame = await el.contentFrame();
  return frame && frame.url() && frame.url() !== "about:blank" ? { ...facts, el, frame } : null;
}

// A canvas frame by its frame id, shown or not: its state, inertness, place
// and the Playwright frame.
async function canvasFrame(page, id) {
  const el = await page.$(`iframe[data-frame-id="${id}"]`);
  if (!el) return null;
  const facts = await el.evaluate((e) => ({
    id: e.getAttribute("data-frame-id"),
    state: e.getAttribute("data-frame-state"),
    inert: e.inert === true,
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

// What a canvas frame has drawn: its texts and its controls.
async function drawing(frame) {
  return frame.evaluate(() => {
    const root = document.querySelector(".cyfr-canvas");
    if (!root || root.children.length === 0) return null;
    return {
      texts: [...root.querySelectorAll(".cyfr-text")].map((e) => e.textContent),
      controls: [...root.querySelectorAll(".cyfr-control")].map((e) => ({
        label: e.getAttribute("aria-label"),
        disabled: e.getAttribute("aria-disabled") === "true",
        look: e.getAttribute("class"),
      })),
      charts: root.querySelectorAll(".cyfr-chart").length,
      candles: root.querySelectorAll(".cyfr-chart-candle").length,
      legend: [...root.querySelectorAll(".cyfr-chart-key")].map((e) => e.textContent),
    };
  }).catch(() => null);
}

// Wait until the frame's drawing satisfies `check`, and answer it.
async function drawn(frame, check, what, { timeoutMs = 20_000 } = {}) {
  return lib.waitFor(async () => {
    const d = await drawing(frame);
    return d && check(d) ? d : null;
  }, { timeoutMs, stepMs: 50, what });
}

// The instrument's receipts after index `from`, of `frame` and `verb`.
const receiptsOf = (marks, from, frame, verb) =>
  marks.receipts.slice(from).filter((r) => (!frame || r.frame === frame) && (!verb || r.verb === verb));

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

const safeModePrompt = (page, timeoutMs = 20_000) =>
  lib.waitFor(async () => {
    const p = await prompt(page);
    return p && p.kind === "safe_mode" ? p : null;
  }, { timeoutMs, stepMs: 50, what: "safe mode" });

async function chooseOffer(page, offer) {
  await page.click(`#system-layer-dialog button[phx-value-offer="${offer}"]`);
  await lib.waitFor(async () => {
    const p = await prompt(page);
    return !p || p.kind !== "safe_mode" ? true : null;
  }, { timeoutMs: 20_000, what: `safe mode left by ${offer}` });
}

// What the shell draws, for a step that did not find what it expected.
async function diagnose(page) {
  const frames = await page.$$eval("[data-canvas-frame]", (els) => els.map((e) => {
    const f = e.querySelector("iframe");
    return {
      place: e.dataset.canvasPlace, shown: e.dataset.canvasShown, wire: f ? f.dataset.frameWire : null,
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

const posture = (apps = []) => ({ desk: { apps, floating: [] }, hand: { apps, floating: [] } });

// The proof's layout: home (canvas-full as its full app), markets, probe
// (canvas-neighbour as its column app), broken and labels, and any canvas a
// step adds or puts in another's place.
function layout(extra = [], { without = [] } = {}) {
  const base = [
    { id: "home", tincture: "tincture:local.canvas", postures: posture([{ tincture: "tincture:local.canvas-full", mode: "full", order: 0 }]) },
    { id: "markets", tincture: "tincture:local.markets", postures: posture() },
    { id: "probe", tincture: "tincture:local.canvas-probe", postures: posture([{ tincture: "tincture:local.canvas-neighbour", mode: "column", order: 0 }]) },
    { id: "broken", tincture: "tincture:local.canvas-broken", postures: posture() },
    { id: "labels", tincture: "tincture:local.labels", postures: posture() },
  ].filter((c) => !without.includes(c.id));
  return { version: 2, canvases: [...base, ...extra.map((e) => ({ id: e.id, tincture: e.tincture, postures: posture() }))] };
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

// two_canvases: the shipped canvas and a written one, each validated and
// shown live. switch: the switcher, the chord and the edge swipe each move
// the glass, the canvas left is frozen, and nothing wraps.
async function stepTwoCanvases(page, name, viewport) {
  const ids = await switcherIds(page);
  const home = await showCanvas(page, "home");
  const homeDrawn = await drawn(home.frame, (d) => d.texts.includes("Apps") && d.controls.some((c) => c.label === "canvas-full"), "the shipped canvas's launchers");
  const homeVersions = await versions("canvas");

  const marks0 = (await instrument(page)).receipts.length;
  const markets = await showCanvas(page, "markets");
  const marketsDrawn = await drawn(markets.frame, (d) => d.texts.includes("markets"), "the written canvas drawn");
  const marks = await instrument(page);
  const marketsTree = receiptsOf(marks, marks0, null, "tree").filter((r) => r.frame !== markets.id);
  const marketsReady = receiptsOf(marks, marks0, markets.id, "ready");
  const marketsVersions = await versions("markets");
  const homeLeft = await canvasFrame(page, home.id);

  note("two_canvases", name,
    ids.includes("home") && ids.includes("markets") && homeVersions.working === "0.1.0" &&
      marketsVersions.working === "0.1.0" && marketsTree.length === 1 && marketsReady.length === 1 &&
      homeLeft && homeLeft.state === "frozen",
    {
      switcher: ids,
      shipped: { canvas: "home", tincture: "tincture:local.canvas", working: homeVersions.working, draws: homeDrawn.texts.slice(0, 3), launchers: homeDrawn.controls.map((c) => c.label) },
      written: { canvas: "markets", tincture: "tincture:local.markets", working: marketsVersions.working, validation_trees: marketsTree.length, live_ready: marketsReady.length, draws: marketsDrawn.texts.slice(0, 2) },
      shown_by: "the switcher",
      home_after_switch: homeLeft && { state: homeLeft.state, inert: homeLeft.inert },
    });

  // switch: by the chord, back to home (the frame it held, resumed).
  const viaSwitcher = { from: "home", to: "markets", shown: markets.id !== home.id };
  await page.keyboard.press("Control+Alt+ArrowLeft");
  const byChord = await lib.waitFor(async () => {
    const s = await shownCanvasFrame(page);
    return (await visibleCanvas(page)) === "home" && s && s.id === home.id && s.state === "live" ? s : null;
  }, { timeoutMs: 15_000, what: "the chord to show home" }).then(() => true).catch(() => false);
  const marketsLeft = await canvasFrame(page, markets.id);

  // At the first canvas the chord leftward does nothing; rightward then
  // shows markets, which a wrap to the last canvas would not.
  await page.keyboard.press("Control+Alt+ArrowLeft");
  await page.keyboard.press("Control+Alt+ArrowRight");
  const noWrap = await lib.waitFor(async () => ((await visibleCanvas(page)) === "markets" ? true : null),
    { timeoutMs: 15_000, what: "the chord to show markets" }).then(() => true).catch(() => false);

  // By the edge strip: rightward is the canvas before, leftward the next.
  const swipeBack = await swipe(page, viewport, "rightward");
  const bySwipeBack = await lib.waitFor(async () => ((await visibleCanvas(page)) === "home" ? true : null),
    { timeoutMs: 15_000, what: "the swipe to show home" }).then(() => true).catch(() => false);
  const swipeOn = await swipe(page, viewport, "leftward");
  const bySwipeOn = await lib.waitFor(async () => ((await visibleCanvas(page)) === "markets" ? true : null),
    { timeoutMs: 15_000, what: "the swipe to show markets" }).then(() => true).catch(() => false);
  const shownAfter = await shownCanvasFrame(page);
  const homeFrozen = await canvasFrame(page, home.id);

  note("switch", name,
    viaSwitcher.shown && byChord && marketsLeft && marketsLeft.state === "frozen" && marketsLeft.inert &&
      noWrap && bySwipeBack && bySwipeOn && shownAfter && shownAfter.id === markets.id && shownAfter.state === "live" &&
      homeFrozen && homeFrozen.state === "frozen",
    {
      by_switcher: viaSwitcher,
      by_chord: { keys: "Ctrl+Alt+ArrowLeft", shown: byChord, frame_resumed: byChord, left_frozen: marketsLeft && { state: marketsLeft.state, inert: marketsLeft.inert } },
      no_wrap: { at_first: "Ctrl+Alt+ArrowLeft then Ctrl+Alt+ArrowRight", shows: noWrap ? "markets" : await visibleCanvas(page) },
      by_swipe: { pointer: swipeOn.pointer, rightward: bySwipeBack, leftward: bySwipeOn, frame_resumed: !!(shownAfter && shownAfter.id === markets.id) },
      left_frozen_after_swipe: homeFrozen && { state: homeFrozen.state, inert: homeFrozen.inert },
    });
}

// A horizontal swipe along the edge strip: a touch swipe in the hand, a
// pointer drag on the desk.
async function swipe(page, viewport, direction) {
  const box = await page.$eval("#canvas-edge-strip", (e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
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

// written_canvas: a canvas written with canvas.write is validated, then
// activated, then opened live at its working version.
async function stepWrittenCanvas(page, name) {
  const canvas = "written";
  const module = "export default (canvas) => canvas.render({type: 'text', value: 'written ' + new URL(import.meta.url).pathname.split('/').slice(-2)[0]})";
  const written = await ask({ op: "write", canvas, module, streams: [] });
  if (!OK(written)) throw new Error(`canvas.write refused the canvas: ${JSON.stringify(written)}`);
  const before = await versions(canvas);
  await publish(page, layout([{ id: canvas, tincture: `tincture:local.${canvas}` }]));
  const from = (await instrument(page)).receipts.length;
  const shown = await showCanvas(page, canvas);
  const d = await drawn(shown.frame, (x) => x.texts.some((t) => t === `written ${written.ok.version}`), "the written canvas drawn at its version");
  await lib.waitFor(async () => receiptsOf(await instrument(page), from, shown.id, "ready").length > 0 || null, { timeoutMs: SAMPLE_MS, what: "the written canvas's ready" });
  const marks = await instrument(page);
  const trees = receiptsOf(marks, from, null, "tree").filter((r) => r.frame !== shown.id);
  const after = await versions(canvas);
  note("written_canvas", name,
    written.ok.version === "0.1.0" && before.working === null && trees.length === 1 &&
      after.working === written.ok.version && after.failed === null && d.texts.includes("written 0.1.0"),
    {
      written: { version: written.ok.version, reference: written.ok.reference, working_before: before.working },
      validated: { validation_frame_trees: trees.length, validation_frame_is_another: trees.every((t) => t.frame !== shown.id) },
      activated: { working: after.working, kept: after.kept, failed: after.failed },
      live: { draws: d.texts, ready: true },
    });
  await showCanvas(page, "home");
  await publish(page, layout());
}

// feed_chart: the feed `candles`, a fixed result the fixture accepted, drawn
// by the chart element as candles.
async function stepFeedChart(page, name) {
  const state = await feedState("candles");
  const shown = await showCanvas(page, "markets");
  const d = await drawn(shown.frame, (x) => x.charts === 1 && x.candles > 0 && x.texts.some((t) => t.startsWith(`revision ${state.result_seq}`)),
    "the candle chart at the accepted revision");
  note("feed_chart", name, d.candles === 6 && d.charts === 1,
    {
      chart: { kind: "candle", candles: d.candles, series: d.legend },
      drawn_revision: d.texts.find((t) => t.startsWith("revision")),
      accepted_seq: state.result_seq,
      executed: false,
      source: "a fixed result the fixture accepted through the gate's accept path; no run executed",
    });
}

// app_over_canvas: canvas-full opened full from the shipped canvas's
// launcher over home, frozen with home on a switch, shown again on the way
// back, and closed.
async function stepAppOverCanvas(page, name) {
  const home = await showCanvas(page, "home");
  await drawn(home.frame, (d) => d.controls.some((c) => c.label === "canvas-full" && !c.disabled), "the canvas-full launcher");
  const from = (await instrument(page)).receipts.length;
  await home.frame.locator('.cyfr-canvas .cyfr-control[aria-label="canvas-full"]').click();
  const full = await lib.waitFor(async () => {
    const el = await page.$('[data-canvas-place="full"][data-canvas-shown="true"] iframe');
    if (!el) return null;
    const f = await el.contentFrame();
    const drawnFull = f ? await f.evaluate(() => document.body && document.body.dataset.drawn === "yes").catch(() => false) : false;
    return drawnFull ? { id: await el.getAttribute("data-frame-id"), state: await el.getAttribute("data-frame-state") } : null;
  }, { timeoutMs: 20_000, what: "canvas-full opened full" });
  const opened = receiptsOf(await instrument(page), from, home.id, "open").length;
  const homeUnder = await canvasFrame(page, home.id);

  await showCanvasAway(page, "markets");
  const fullFrozen = await lib.waitFor(async () => {
    const f = await canvasFrame(page, full.id);
    return f && f.state === "frozen" && f.inert && f.shown === false ? f : null;
  }, { timeoutMs: 15_000, what: "canvas-full frozen" });
  const homeFrozen = await canvasFrame(page, home.id);

  // Back to home: its full app is shown again, live, over it.
  await page.click('#canvas-switcher button[data-canvas="home"]');
  const fullAgain = await lib.waitFor(async () => {
    const f = await canvasFrame(page, full.id);
    return f && f.state === "live" && f.shown === true ? f : null;
  }, { timeoutMs: 15_000, what: "canvas-full shown again" });
  await page.locator('button[phx-click="close_active_tincture"]:visible').click();
  await lib.waitFor(async () => ((await page.$(`iframe[data-frame-id="${full.id}"]`)) ? null : true), { timeoutMs: 15_000, what: "canvas-full closed" });
  const homeBack = await showCanvas(page, "home");

  note("app_over_canvas", name,
    opened === 1 && full.state === "live" && homeUnder && homeUnder.state === "frozen" &&
      fullFrozen.state === "frozen" && fullFrozen.inert && homeFrozen && homeFrozen.state === "frozen" &&
      fullAgain.state === "live" && homeBack.id === home.id && homeBack.state === "live",
    {
      opened: { by: "the shipped canvas's launcher", open_verbs: opened, full_frame: full.state, canvas_under: homeUnder && homeUnder.state },
      on_switch: { full_frame: { state: fullFrozen.state, inert: fullFrozen.inert, shown: fullFrozen.shown }, canvas: homeFrozen && homeFrozen.state },
      switched_back: { full_frame: fullAgain.state },
      closed: { canvas_shown_again: homeBack.state, same_frame: homeBack.id === home.id },
    });
}

// Switch to `id` while a full frame covers the visible canvas: the glass
// moves, and the switcher stays reachable.
async function showCanvasAway(page, id) {
  await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
  await lib.waitFor(async () => ((await visibleCanvas(page)) === id ? true : null), { timeoutMs: 15_000, what: `canvas ${id} shown` });
}

// The probe's module worker, where its exits are attempted: the dedicated
// worker in the role the toolkit gives the module that holds `__canvasProbe`.
async function probeWorker(page, { generation = null, timeoutMs = 15_000 } = {}) {
  return lib.waitFor(async () => {
    for (const worker of page.workers()) {
      const facts = await worker.evaluate(() => ({
        role: self.name,
        generation: self.__canvasProbe && typeof self.__canvasProbe === "object" ? self.__canvasProbe.generation : null,
      })).catch(() => null);
      if (facts && facts.role === "cyfr-toolkit-module" && facts.generation && (!generation || facts.generation !== generation)) {
        return { worker, generation: facts.generation };
      }
    }
    return null;
  }, { timeoutMs, stepMs: 100, what: "the probe's module worker" });
}

const countOf = (d) => {
  const line = d && d.texts.find((t) => /^count \d+$/.test(t));
  return line ? Number(line.slice(6)) : null;
};

// worker_stop: canvas-probe's counter stops when its canvas is switched
// away (the toolkit terminates its worker) and resumes from its stream in a
// new generation when it is switched back.
async function stepWorkerStop(page, name) {
  const probe = await showCanvas(page, "probe");
  const ticking = await drawn(probe.frame, (d) => countOf(d) >= 3 && d.texts.some((t) => t.startsWith("stream open")), "the probe's counter ticking and its stream open");
  const first = await probeWorker(page);
  const closed = new Promise((resolve) => first.worker.once("close", () => resolve(true)));

  await showCanvas(page, "home");
  const stopped = await Promise.race([closed, sleep(15_000).then(() => false)]);
  const frozen = await canvasFrame(page, probe.id);
  const atStop = countOf(await drawing(frozen.frame));
  const workersLeft = [];
  for (const w of page.workers()) {
    const g = await w.evaluate(() => (self.__canvasProbe ? self.__canvasProbe.generation : null)).catch(() => null);
    if (g) workersLeft.push(g);
  }
  // Read again once the glass has shown home live: nothing ticked.
  await drawn((await shownCanvasFrame(page)).frame, (d) => d.texts.includes("Apps"), "home drawn");
  const stillAtStop = countOf(await drawing(frozen.frame));

  const back = await showCanvas(page, "probe");
  const second = await probeWorker(page, { generation: first.generation });
  const resumed = await drawn(back.frame, (d) => d.texts.includes(`probe ${second.generation}`) && countOf(d) >= 1 && d.texts.some((t) => /^stream open, [1-9]\d* events, revision \d+ \(refresh\)$/.test(t)),
    "the probe's new generation ticking from its stream");
  const state = await second.worker.evaluate(() => self.__canvasProbe.state());

  note("worker_stop", name,
    stopped === true && frozen.state === "frozen" && workersLeft.length === 0 && atStop !== null && atStop === stillAtStop &&
      back.id === probe.id && second.generation !== first.generation && state.stream.opened && state.stream.refresh && state.stream.events >= 1,
    {
      before: { generation: first.generation, count: countOf(ticking) },
      switched_away: { worker_terminated: stopped, frame: frozen.state, probe_workers_left: workersLeft.length, count_at_stop: atStop, count_after: stillAtStop },
      switched_back: { same_frame: back.id === probe.id, generation: second.generation, new_generation: second.generation !== first.generation, count: state.count, stream: state.stream, draws: resumed.texts.slice(0, 3) },
    });
}

// The neighbour's column frame beside the probe, and its counts.
async function neighbourFrame(page) {
  return lib.waitFor(async () => {
    const el = await page.$('[data-canvas-place="column"][data-canvas-shown="true"] iframe');
    if (!el) return null;
    const src = await el.getAttribute("src");
    const frame = await el.contentFrame();
    if (!frame || !src || !src.includes("/local/canvas-neighbour/")) return null;
    const counts = await frame.evaluate(() => ({
      posted: Number((document.getElementById("posted") || {}).textContent || "0"),
      heard: Number((document.getElementById("heard") || {}).textContent || "0"),
      channel: document.body ? document.body.dataset.channel || null : null,
    })).catch(() => null);
    return counts && counts.posted > 0 ? { el, frame, dir: src.slice(0, src.lastIndexOf("/") + 1), counts } : null;
  }, { timeoutMs: 20_000, stepMs: 100, what: "the neighbour's column, posting" });
}

const neighbourCounts = (frame) => frame.evaluate(() => ({
  posted: Number((document.getElementById("posted") || {}).textContent || "0"),
  heard: Number((document.getElementById("heard") || {}).textContent || "0"),
}));

// Every request since `mark` that carried `attempt`, as the proxy saw it.
function attempts(proxy, mark, name) {
  return proxy.seen.slice(mark).filter((r) => {
    try {
      return r.host === lib.SITE && new URL(r.url).searchParams.get("attempt") === name;
    } catch {
      return false;
    }
  }).map((r) => ({ method: r.method, status: r.status === undefined ? null : r.status }));
}

// A write that reached the server was refused there: a CORS preflight
// (OPTIONS) is answered on its own, and every request it let through was
// answered 4xx.
const NEVER_2XX = (reached) => reached.every((r) => r.method === "OPTIONS" || r.status === null || r.status >= 400);

// exits: each exit the probe's code attempts from its worker, with what
// the worker saw and what the proxy saw reach the server.
async function stepExits(page, name, proxy, receiver, udp) {
  const home = held.get("home") || (await showCanvas(page, "home")).id;
  const probe = await showCanvas(page, "probe");
  await drawn(probe.frame, (d) => d.texts.some((t) => t.startsWith("stream open")), "the probe drawn with its stream open");
  const neighbour = await neighbourFrame(page);
  const { worker } = await probeWorker(page);
  const other = await ask({ op: "bearer", reference: "tincture:local.canvas-neighbour:1.0.0" });
  if (!other || typeof other.bearer !== "string" || !other.bearer) throw new Error("the fixture minted no foreign bearer");
  secrets.push(other.bearer);

  const origin = new URL(page.url()).origin;
  const ownPath = `/_f/v1/o/${probe.id}/`;
  const urlBefore = probe.frame.url();
  const proxyMark = proxy.seen.length;
  const receiverMark = receiver.log.length;
  const udpMark = udp.packets;
  const marks0 = (await instrument(page)).receipts.length;
  const counts0 = await neighbourCounts(neighbour.frame);

  const seen = await worker.evaluate((t) => self.__canvasProbe.exits(t), {
    origin,
    own_data_path: ownPath,
    navigate_to: "/a/x/tinctures",
    neighbour_script: neighbour.dir + "neighbour.js",
    neighbour_connect: `http://${lib.ATTACKER}/collect`,
    forbidden: neighbour.dir + "neighbour.js",
    public_invoke: "/_f/v1/invoke",
    shared_action: "/_f/v1/action",
    webhook: "/hooks/canvas-proof",
    udp_port: udp.port,
    foreign_bearer: other.bearer,
  });

  // An open carrying data: the toolkit's grammar refuses the whole tree, so
  // nothing of it is drawn and nothing is opened. Watched in the frame for
  // a second, four times the toolkit's longest wait before it draws.
  const watch = probe.frame.evaluate(() => new Promise((resolve) => {
    const root = document.querySelector(".cyfr-canvas");
    let shownWithData = false;
    const observer = new MutationObserver(() => {
      if (root.textContent.includes("open with data")) shownWithData = true;
    });
    observer.observe(root, { childList: true, subtree: true, characterData: true });
    setTimeout(() => {
      observer.disconnect();
      resolve({ shown_with_data: shownWithData || root.textContent.includes("open with data"), window_ms: 1000 });
    }, 1000);
  }));
  await worker.evaluate(() => self.__canvasProbe.openWithData("tincture:local.canvas-neighbour"));
  const openWithData = await watch;
  await worker.evaluate(() => self.__canvasProbe.resume());
  const afterResume = await drawn(probe.frame, (d) => countOf(d) !== null, "the probe drawn again after its refused tree");

  const counts1 = await neighbourCounts(neighbour.frame);
  const marks = await instrument(page);
  const since = proxy.seen.slice(proxyMark).filter((r) => r.host === lib.SITE);
  const pathOf = (r) => { try { return new URL(r.url).pathname; } catch { return ""; } };
  const neighbourScript = new URL(neighbour.dir + "neighbour.js", origin).pathname;
  const redirectNames = [...Object.keys(seen.redirect.fetch).map((k) => `redirect_${k}`),
    "redirect_version_directory", "redirect_version_directory_slash", "redirect_prefix_root", "redirect_script_dot_segments", "redirect_script_next_query"];
  const redirectReached = Object.fromEntries(redirectNames.map((n) => [n, attempts(proxy, proxyMark, n)]));
  const threeXX = since.filter((r) => typeof r.status === "number" && r.status >= 300 && r.status < 400 && /^\/(_c\/v1|_f\/v1\/o|_s)\//.test(pathOf(r)));
  const attacker = proxy.seen.slice(proxyMark).filter((r) => r.host === lib.ATTACKER).length + (receiver.log.length - receiverMark);
  const opened = receiptsOf(marks, marks0, probe.id, "open").length;
  const failed = receiptsOf(marks, marks0, probe.id, "failed").length;
  const foreign = attempts(proxy, proxyMark, "foreign_bearer");

  const checks = {
    navigate: seen.navigate.location_assign === "undefined" && seen.navigate.open === "undefined" &&
      seen.navigate.href_assigned.outcome === "refused" && seen.navigate.protocol_after === "blob:" &&
      probe.frame.url() === urlBefore && attempts(proxy, proxyMark, "navigate").length === 0,
    sibling: ["window", "parent", "top", "opener", "frames", "document"].every((k) => seen.sibling[k] === "undefined") &&
      counts1.heard === counts0.heard,
    colluding: counts1.posted > counts0.posted && seen.colluding.forged_installed_seen === 0 && !seen.colluding.installed.includes(FORGED),
    neighbour_script: seen.neighbour.import.outcome === "refused" && seen.neighbour.import_scripts.outcome === "refused" &&
      attempts(proxy, proxyMark, "neighbour_import").length === 0 && attempts(proxy, proxyMark, "neighbour_import_scripts").length === 0 &&
      since.filter((r) => pathOf(r) === neighbourScript).length === 0,
    neighbour_connect: seen.neighbour.connect_origin.outcome === "refused" && attacker === 0,
    redirect: threeXX.length === 0 && Object.values(seen.redirect.fetch).every((r) => r.outcome !== "redirected") &&
      Object.values(redirectReached).every((reached) => reached.every((r) => r.status === null || r.status < 300 || r.status >= 400)) &&
      since.filter((r) => pathOf(r) === neighbourScript).length === 0,
    rtc: seen.rtc.attempt.outcome !== "constructed" && udp.packets === udpMark,
    public: seen.public.invoke.outcome === "refused" && seen.public.webhook.outcome === "refused" &&
      attempts(proxy, proxyMark, "public_invoke").length === 0 && attempts(proxy, proxyMark, "webhook").length === 0 &&
      since.filter((r) => pathOf(r).startsWith("/hooks/")).length === 0,
    write: Object.values(seen.write).every((r) => r.outcome !== "answered" || r.status >= 400) &&
      ["write_own_invoke", "write_own_action", "write_own_stream", "write_shared_action"].every((n) => NEVER_2XX(attempts(proxy, proxyMark, n))),
    foreign_bearer: seen.foreign_bearer.outcome === "answered" && seen.foreign_bearer.status === 403 &&
      seen.foreign_bearer.code === "frame_path_mismatch" && foreign.some((r) => r.method === "POST" && r.status === 403),
    open_with_data: !openWithData.shown_with_data && opened === 0 && failed === 0 && countOf(afterResume) !== null,
  };

  note("exits", name, Object.values(checks).every(Boolean), {
    checks,
    navigate: { ...seen.navigate, frame_address_unchanged: probe.frame.url() === urlBefore, requests: attempts(proxy, proxyMark, "navigate").length },
    sibling: { ...seen.sibling, neighbour_heard: counts1.heard - counts0.heard },
    colluding: { neighbour_posted: counts1.posted - counts0.posted, neighbour_channel: neighbour.counts.channel, forged_installed_seen: seen.colluding.forged_installed_seen, installed: seen.colluding.installed },
    neighbour_script: { import: seen.neighbour.import, import_scripts: seen.neighbour.import_scripts, requests: since.filter((r) => pathOf(r) === neighbourScript).length },
    neighbour_connect: { fetch: seen.neighbour.connect_origin, attacker_requests: attacker },
    redirect: { fetch: seen.redirect.fetch, script: seen.redirect.script, reached: redirectReached, three_xx: threeXX.length },
    rtc: { ...seen.rtc, udp_packets: udp.packets - udpMark },
    public: { invoke: seen.public.invoke, webhook: seen.public.webhook, requests: attempts(proxy, proxyMark, "public_invoke").length + attempts(proxy, proxyMark, "webhook").length },
    write: { attempts: seen.write, reached: Object.fromEntries(["write_own_invoke", "write_own_action", "write_own_stream", "write_shared_action"].map((n) => [n, attempts(proxy, proxyMark, n)])) },
    foreign_bearer: { outcome: seen.foreign_bearer.outcome, status: seen.foreign_bearer.status, class: seen.foreign_bearer.class, code: seen.foreign_bearer.code, reached: foreign },
    open_with_data: { ...openWithData, open_verbs: opened, failed_verbs: failed, canvas_drawn_after: countOf(afterResume) !== null },
    other_open: home ? "home" : null,
  });
}

// worker_policy: the eight results, against the real host page, toolkit
// and served version, each asserted.
async function stepWorkerPolicy(page, name, proxy) {
  const home = held.get("home") || (await showCanvas(page, "home")).id;
  const probe = await showCanvas(page, "probe");
  await drawn(probe.frame, (d) => d.texts.some((t) => t.startsWith("stream open")), "the probe drawn with its stream open");
  const neighbour = await neighbourFrame(page);
  const { worker } = await probeWorker(page);
  const origin = new URL(page.url()).origin;
  const proxyMark = proxy.seen.length;

  const r = await worker.evaluate((t) => self.__canvasProbe.policy(t), {
    origin,
    other_data_path: `/_f/v1/o/${home}/stream`,
    other_prefix_file: neighbour.dir + "shared.js",
  });
  const state = await worker.evaluate(() => self.__canvasProbe.state());
  const versionDir = await worker.evaluate(() => self.__canvasProbe.versionDir());

  // From the page: the frame's own document, its scripts, and a URL worker.
  // A browser that constructs the worker is given the time to load it: the
  // worker ran (it posts), failed (its error event), or sent nothing within
  // five seconds, and only then is it ended, so no request it would make is
  // cut short.
  const page_ = await probe.frame.evaluate(async (file) => {
    const scripts = [...document.scripts];
    const fromPage = await new Promise((resolve) => {
      let worker;
      try {
        worker = new Worker(file);
      } catch (error) {
        resolve({ outcome: "not started", error: error.name });
        return;
      }
      const done = (seen) => {
        try { worker.terminate(); } catch (_ended) { /* already ended */ }
        resolve({ constructed: true, ...seen });
      };
      worker.onmessage = () => done({ outcome: "ran" });
      worker.onerror = (event) => {
        if (event && typeof event.preventDefault === "function") event.preventDefault();
        done({ outcome: "not started", error: "error event" });
      };
      setTimeout(() => done({ outcome: "not started", error: "no message within 5 s" }), 5000);
    });
    return {
      origin: self.origin,
      executable_scripts: scripts.filter((s) => !s.type || s.type === "text/javascript" || s.type === "module").length,
      inert_bundle: scripts.filter((s) => s.id === "cyfr-toolkit-worker" && s.type === "application/json").length,
      from_page: fromPage,
    };
  }, versionDir + "canvas.js?attempt=policy_page_worker");

  const reached = (n) => attempts(proxy, proxyMark, n);
  const pathOf = (x) => { try { return new URL(x.url).pathname; } catch { return ""; } };
  const ownStream = proxy.seen.filter((x) => x.host === lib.SITE && x.method === "POST" && pathOf(x) === `/_f/v1/o/${probe.id}/stream`);
  const siblingLoaded = proxy.seen.filter((x) => x.host === lib.SITE && x.method === "GET" && /\/local\/canvas-probe\/1\.0\.0\/shared\.js$/.test(pathOf(x)) && x.status === 200);

  const results = {
    r1_origin_null: r.origin === "null" && page_.origin === "null",
    r2_inert_bundle: r.worker.protocol === "blob:" && r.worker.role === "cyfr-toolkit-module" && page_.inert_bundle === 1 && page_.executable_scripts === 1,
    r3_own_stream_answered: state.stream.opened === true && state.stream.events >= 1 && ownStream.some((x) => x.status === 200),
    r4_other_open_blocked: r.other_open.outcome === "refused" && reached("policy_other_open").length === 0,
    r5_version_fetch_blocked: r.version_file.outcome === "refused" && reached("policy_version_fetch").length === 0,
    r6_other_prefix_blocked: r.other_prefix.import.outcome === "refused" && r.other_prefix.import_scripts.outcome === "refused" &&
      reached("policy_other_prefix_import").length === 0 && reached("policy_other_prefix_import_scripts").length === 0,
    r7_sibling_import: r.sibling === "canvas-neighbour/shared.js" && siblingLoaded.length >= 1,
    r8_url_worker_never_runs: r.nested_worker.outcome !== "ran" && page_.from_page.outcome !== "ran" &&
      reached("policy_nested_worker").length === 0 && reached("policy_page_worker").length === 0,
  };

  note("worker_policy", name, Object.values(results).every(Boolean), {
    version: record.browsers[name],
    results,
    seen: {
      r1: { worker_origin: r.origin, frame_origin: page_.origin },
      r2: { worker: r.worker, inert_bundle_elements: page_.inert_bundle, executable_scripts: page_.executable_scripts },
      r3: { stream: state.stream, own_stream_requests: ownStream.map((x) => x.status) },
      r4: { fetch: r.other_open, reached: reached("policy_other_open").length, other_open: "home's canvas frame" },
      r5: { fetch: r.version_file, reached: reached("policy_version_fetch").length },
      r6: { import: r.other_prefix.import, import_scripts: r.other_prefix.import_scripts, reached: reached("policy_other_prefix_import").length + reached("policy_other_prefix_import_scripts").length },
      r7: { sibling: r.sibling, sibling_requests: siblingLoaded.length },
      r8: { nested: r.nested_worker, from_page: page_.from_page, reached: reached("policy_nested_worker").length + reached("policy_page_worker").length },
    },
  });
}

// The markets canvas shown, its controls bound and enabled, with the frame
// recorder installed.
async function marketsReady(page) {
  const shown = await showCanvas(page, "markets");
  const d = await drawn(shown.frame, (x) => x.controls.length === 2 && x.controls.every((c) => !c.disabled) &&
    x.controls.map((c) => c.label).join(",") === "Buy,Refresh", "the markets controls bound");
  await shown.frame.evaluate(installRecorder);
  return { shown, drawing: d };
}

// activation_once: one replayed click and one held key each produce exactly
// one dispatch, inside the original event, and none after.
async function stepActivationOnce(page, name) {
  const { shown } = await marketsReady(page);
  const frame = shown.frame;
  // The counted window opens with no scheduled fire of the feed near.
  const clear = await clearOfFires(() => feedState("candles"));
  const before = clear.state;
  const from = (await instrument(page)).receipts.length;
  const control = frame.locator('.cyfr-canvas .cyfr-control[aria-label="Refresh"]');

  // The replayed activation: a genuine click, then the very event dispatched
  // again on the control.
  const mark = (await posts(frame)).length;
  await control.click();
  const afterClick = (await posts(frame)).slice(mark);
  const replay = await frame.evaluate(() => {
    const event = window.__proofClick;
    const control = document.querySelector('.cyfr-canvas .cyfr-control[aria-label="Refresh"]');
    if (!event || !control) return { replayed: false };
    control.dispatchEvent(event);
    return { replayed: true, trusted_after: event.isTrusted };
  });
  const afterReplay = (await posts(frame)).slice(mark);

  // The held activation: Enter held down, the browser repeating its keydown.
  await control.focus();
  await page.keyboard.down("Enter");
  const afterKey = (await posts(frame)).slice(mark);
  for (let i = 0; i < 3; i++) await page.keyboard.down("Enter");
  await page.keyboard.up("Enter");
  const afterHeld = (await posts(frame)).slice(mark);

  // The shell received each dispatch, and nothing else of the canvas's.
  const presses = await lib.waitFor(async () => {
    const got = receiptsOf(await instrument(page), from, shown.id, "press");
    return got.length >= 2 ? got : null;
  }, { timeoutMs: 10_000, what: "the shell's receipt of both presses" });
  await lib.waitFor(async () => {
    const s = await feedState("candles");
    return s.fire_seq >= before.fire_seq + 2 ? s : null;
  }, { timeoutMs: 15_000, stepMs: 250, what: "both presses reaching feed.press" });
  // Read once the shell has handled every press, so a claim it made later
  // than the two would be counted.
  await shellHandled(page, "home");
  const after = await feedState("candles");
  const all = receiptsOf(await instrument(page), from, shown.id, null);

  const clickPosts = afterClick.filter((p) => p.verb === "press");
  const keyPosts = afterKey.slice(afterReplay.length).filter((p) => p.verb === "press");
  note("activation_once", name,
    clickPosts.length === 1 && clickPosts[0].during && clickPosts[0].during.type === "click" && clickPosts[0].during.trusted &&
      replay.replayed && afterReplay.length === afterClick.length &&
      keyPosts.length === 1 && keyPosts[0].during && keyPosts[0].during.type === "keydown" && keyPosts[0].during.trusted && !keyPosts[0].during.repeat &&
      afterHeld.length === afterKey.length &&
      presses.length === 2 && all.length === 2 && after.fire_seq - before.fire_seq === 2 &&
      after.next_run_at === before.next_run_at,
    {
      replayed: {
        original: { dispatches: clickPosts.length, during: clickPosts[0] && clickPosts[0].during, action: clickPosts[0] && clickPosts[0].action },
        replay: { dispatched_again: replay.replayed, trusted_after: replay.trusted_after, dispatches_after: afterReplay.length - afterClick.length },
      },
      held: {
        original: { dispatches: keyPosts.length, during: keyPosts[0] && keyPosts[0].during },
        repeats: { keydowns: 3, dispatches_after: afterHeld.length - afterKey.length },
      },
      shell: { press_receipts: presses.length, all_receipts_of_the_frame: all.length },
      feed: {
        seq_before: before.fire_seq, seq_after: after.fire_seq, seq_claims_since: after.fire_seq - before.fire_seq,
        next_run_at_before: before.next_run_at, next_run_at_after: after.next_run_at,
        due_in_s_at_open: before.next_run_in_s, fires_waited_for: clear.waited,
      },
    });
}

// Before a counted window on a binding: while its next scheduled fire is
// due within 90 s, wait for that fire, bounded at 150 s as failed_fire's
// wait is: its claim has moved the cursor and the seq, and its run or error
// is recorded. Answers the binding's state once no fire is that near, which
// is the window's first read, and each fire waited for.
const DUE_WITHIN_S = 90;
async function clearOfFires(read) {
  const waited = [];
  for (;;) {
    const s = await read();
    if (typeof s.next_run_in_s !== "number" || typeof s.next_run_at !== "string") {
      throw new Error(`the binding's next fire could not be read: ${JSON.stringify(s)}`);
    }
    if (s.next_run_in_s > DUE_WITHIN_S) return { state: s, waited };
    if (waited.length >= 3) throw new Error("the binding stayed due within 90 s across three fires");
    const ended = await lib.waitFor(async () => {
      const now = await read();
      return now.next_run_at !== s.next_run_at && now.fire_seq > s.fire_seq && now.runs + now.errors > s.runs + s.errors ? now : null;
    }, { timeoutMs: 150_000, stepMs: 500, what: "the binding's due fire to end" });
    waited.push({ due_in_s: s.next_run_in_s, cursor_before: s.next_run_at, cursor_after: ended.next_run_at, fire_seq: ended.fire_seq });
  }
}

// A point in the shell's order: the glass shows `id` only in answer to the
// switch this sends, which the shell handles after every event the page
// sent it before, a canvas's press among them. Once it shows, those are
// handled, and what they did to the store can be read.
async function shellHandled(page, id) {
  if ((await visibleCanvas(page)) === id) throw new Error(`the glass already shows ${id}, so a switch to it orders nothing`);
  await showCanvas(page, id);
}

// rebound_control: the feed is removed and bound again with other
// arguments. The control drawn before still names the old binding, which
// is no longer live, so pressing it claims nothing on the new binding, and
// feed.press naming it is refused not_found. A new result of the new
// binding draws a new tree, whose control names the new binding and whose
// press is the new binding's one claim besides the fixture's accept.
async function stepReboundControl(page, name) {
  const { shown } = await marketsReady(page);
  const frame = shown.frame;
  const old = await feedState("candles");

  // While the binding is live, a press reaches feed.press.
  const control = frame.locator('.cyfr-canvas .cyfr-control[aria-label="Refresh"]');
  const mark = (await posts(frame)).length;
  await control.click();
  const live = (await posts(frame)).slice(mark).filter((p) => p.verb === "press");
  const reached = await lib.waitFor(async () => {
    const s = await feedState("candles");
    return s.fire_seq > old.fire_seq ? s : null;
  }, { timeoutMs: 15_000, stepMs: 250, what: "the live press reaching feed.press" });

  const symbol = `ETH-${name}`;
  const rebound = await ask({ op: "rebind", feed: "candles", args: { symbol } });
  if (!rebound || !rebound.bound || !OK(rebound.bound)) throw new Error(`the feed was not bound again: ${JSON.stringify(rebound)}`);
  const fresh = rebound.bound.ok.binding;

  // The new binding's claimed seq, once the scheduler's first fire of it,
  // due as it is bound, has ended, and no later fire of it is near: every
  // claim so far is a fire that ended, and the counted window opens here.
  await lib.waitFor(async () => {
    const s = await ask({ op: "state_of", binding: fresh });
    return s && s.live === true && s.fire_seq >= 1 && s.runs + s.errors >= s.fire_seq ? s : null;
  }, { timeoutMs: 90_000, stepMs: 500, what: "the new binding's first fire to end" });
  const clear = await clearOfFires(() => ask({ op: "state_of", binding: fresh }));
  const settled = clear.state;

  // The control drawn before: the same element, its tree unchanged. Once
  // the shell has handled its press, the new binding's seq has not moved.
  const from = (await instrument(page)).receipts.length;
  const n = (await posts(frame)).length;
  await control.click();
  const stale = (await posts(frame)).slice(n).filter((p) => p.verb === "press");
  const received = await lib.waitFor(async () => {
    const got = receiptsOf(await instrument(page), from, shown.id, "press");
    return got.length >= 1 ? got : null;
  }, { timeoutMs: 10_000, what: "the shell's receipt of the stale press" });
  await shellHandled(page, "home");
  const afterStale = await ask({ op: "state_of", binding: fresh });
  const oldNow = await ask({ op: "state_of", binding: old.binding });
  const refused = await ask({ op: "press", binding: old.binding, action: "refresh" });

  // A result of the new binding: shown again, the canvas draws a new tree,
  // whose control names it. Its press is the one claim after the accept's,
  // read once the shell has handled it.
  const accepted = await ask({ op: "accept", feed: "candles", data: { symbol, price: 2, change: null, at: new Date().toISOString().replace(/\.\d+Z$/, "Z"), candles: candles(symbol) } });
  const again = await showCanvas(page, "markets");
  await drawn(again.frame, (d) => d.legend.includes(symbol) && d.controls.length === 2 && d.controls.every((c) => !c.disabled), "the new binding's result drawn");
  const m = (await posts(again.frame)).length;
  await again.frame.locator('.cyfr-canvas .cyfr-control[aria-label="Refresh"]').click();
  const renewed = (await posts(again.frame)).slice(m).filter((p) => p.verb === "press");
  await lib.waitFor(async () => {
    const s = await ask({ op: "state_of", binding: fresh });
    return s && s.fire_seq >= settled.fire_seq + 2 ? s : null;
  }, { timeoutMs: 15_000, stepMs: 250, what: "the renewed press reaching feed.press" });
  await shellHandled(page, "home");
  const afterRenewed = await ask({ op: "state_of", binding: fresh });

  const refusal = typeof refused.error === "string" ? refused.error : null;
  note("rebound_control", name,
    live.length === 1 && live[0].binding === old.binding && reached.fire_seq > old.fire_seq &&
      fresh !== old.binding && rebound.old === old.binding &&
      stale.length === 1 && stale[0].binding === old.binding && received.length === 1 &&
      afterStale.fire_seq === settled.fire_seq &&
      oldNow && oldNow.live === false &&
      refusal === `{:not_found, "Feed", "${old.binding}"}` &&
      accepted.revision === settled.fire_seq + 1 &&
      renewed.length === 1 && renewed[0].binding === fresh &&
      afterRenewed.fire_seq === settled.fire_seq + 2 &&
      afterRenewed.next_run_at === settled.next_run_at,
    {
      while_live: { press_binding_is_current: live.length === 1 && live[0].binding === old.binding, reached_feed_press: reached.fire_seq > old.fire_seq },
      rebound: { new_binding: fresh !== old.binding, args: { symbol } },
      new_binding_settled: {
        fire_seq: settled.fire_seq, runs: settled.runs, errors: settled.errors,
        next_run_at: settled.next_run_at, due_in_s_at_open: settled.next_run_in_s, fires_waited_for: clear.waited,
      },
      control_drawn_before: { dispatches: stale.length, names_old_binding: stale.length === 1 && stale[0].binding === old.binding, shell_received: received.length },
      new_binding_after_the_stale_press: { fire_seq: afterStale.fire_seq, moved: afterStale.fire_seq - settled.fire_seq, next_run_at: afterStale.next_run_at },
      old_binding: { live: oldNow && oldNow.live },
      feed_press_naming_it: { refused: refusal !== null, not_found_naming_the_old_binding: refusal === `{:not_found, "Feed", "${old.binding}"}`, refusal: refusal && refusal.slice(0, 160) },
      after_new_result: {
        accepted_revision: accepted.revision,
        new_control_names_new_binding: renewed.length === 1 && renewed[0].binding === fresh,
        fire_seq: afterRenewed.fire_seq,
        claims_since_settled: afterRenewed.fire_seq - settled.fire_seq,
        next_run_at: afterRenewed.next_run_at,
      },
    });
}

function candles(symbol) {
  const now = Date.now();
  return Array.from({ length: 4 }, (_, i) => {
    const o = 100 + i;
    return { t: new Date(now - (4 - i) * 3_600_000).toISOString().replace(/\.\d+Z$/, "Z"), o, h: o + 2, l: o - 1, c: o + 1 };
  });
}

// labels: two look-alike controls bound to different effects show the
// labels their binding declares. A binding record the module posts itself,
// labelling `buy` as "Refresh", relabels nothing: the canvas fails closed
// and the shell enters safe mode `crashed`.
async function stepLabels(page, name) {
  const shown = await showCanvas(page, "labels");
  const before = await drawn(shown.frame, (d) => d.controls.length === 2 && d.controls.every((c) => !c.disabled) &&
    d.controls.map((c) => c.label).join(",") === "Buy,Refresh", "the labels canvas's controls bound");
  await shown.frame.evaluate(installRecorder);
  const lw = await lib.waitFor(async () => {
    for (const w of page.workers()) {
      const has = await w.evaluate(() => typeof self.__canvasLabels === "object" && self.__canvasLabels !== null).catch(() => false);
      if (has) return w;
    }
    return null;
  }, { timeoutMs: 15_000, stepMs: 100, what: "the labels canvas's module worker" });

  // Every label each control shows from now until the canvas fails closed.
  const watched = shown.frame.evaluate(() => new Promise((resolve) => {
    const root = document.querySelector(".cyfr-canvas");
    const labels = new Set();
    const read = () => [...root.querySelectorAll(".cyfr-control")].map((c) => ({ label: c.getAttribute("aria-label"), text: c.textContent, disabled: c.getAttribute("aria-disabled") === "true" }));
    const take = () => {
      const now = read();
      for (const [i, c] of now.entries()) labels.add(`${i}:${c.label}:${c.text}`);
      if (now.length > 0 && now.every((c) => c.disabled)) {
        observer.disconnect();
        resolve({ labels: [...labels], at_close: now });
      }
    };
    const observer = new MutationObserver(take);
    observer.observe(root, { childList: true, subtree: true, attributes: true, characterData: true });
    take();
    setTimeout(() => { observer.disconnect(); resolve({ labels: [...labels], at_close: read(), timed_out: true }); }, 10_000);
  }));
  const from = (await instrument(page)).receipts.length;
  // The forged record ends the worker it is posted from, so it is posted
  // once this evaluation has answered, which says whether the module held
  // the feed's binding to forge a record for.
  const forged = await lw.evaluate(() => {
    const bound = self.__canvasLabels.bound();
    setTimeout(() => self.__canvasLabels.forge(), 0);
    return bound;
  });
  const closed = await watched;
  const failedPosts = (await posts(shown.frame).catch(() => [])).filter((p) => p.verb === "failed");
  const safe = await safeModePrompt(page);
  const failedReceipts = receiptsOf(await instrument(page), from, shown.id, "failed").length;
  await chooseOffer(page, "retry");
  const again = await showCanvas(page, "labels");
  const relabelled = await drawn(again.frame, (d) => d.controls.map((c) => c.label).join(",") === "Buy,Refresh", "the labels canvas drawn again");

  const looks = before.controls.map((c) => c.look);
  note("labels", name,
    looks.length === 2 && looks[0] === looks[1] && before.controls[0].label !== before.controls[1].label &&
      forged === true && !closed.timed_out && closed.at_close.every((c) => c.disabled) &&
      closed.labels.every((l) => l.startsWith("0:Buy:Buy") || l.startsWith("1:Refresh:Refresh")) &&
      failedReceipts === 1 && safe.kind === "safe_mode" &&
      relabelled.controls.map((c) => c.label).join(",") === "Buy,Refresh",
    {
      look_alike: { same_look: looks[0] === looks[1], labels: before.controls.map((c) => c.label) },
      forged_record: { module_held_the_binding: forged, labels_seen_until_closed: closed.labels, controls_at_close: closed.at_close },
      failed_closed: { failed_posts: failedPosts.map((p) => p.stage), shell_failed_receipts: failedReceipts, safe_mode: safe.description },
      retried: { labels: relabelled.controls.map((c) => c.label) },
    });
}

// validation_failures: canvas-broken's 1.0.0 is validated and working; a
// later version that answers no tree, and one that dies on its stream's
// fixture, are each recorded as failed, and the working version opens.
async function stepValidationFailures(page, name) {
  const first = await showCanvas(page, "broken");
  await drawn(first.frame, (d) => d.texts.includes("broken 1.0.0"), "canvas-broken 1.0.0 drawn");
  const start = await versions("canvas-broken");
  await showCanvas(page, "home");

  const outcomes = {};
  for (const [id, feed, outcome] of [["brk1", "broken-quiet", "no_tree"], ["brk2", "broken-die", "died"]]) {
    const written = await ask({ op: "write", canvas: "canvas-broken", module: "broken", streams: [{ name: "feed.results", subject: feed }] });
    if (!OK(written)) throw new Error(`canvas.write refused canvas-broken: ${JSON.stringify(written)}`);
    await publish(page, layout([{ id, tincture: "tincture:local.canvas-broken" }], { without: ["broken"] }));
    const from = (await instrument(page)).receipts.length;
    const shown = await showCanvas(page, id);
    const d = await drawn(shown.frame, (x) => x.texts.includes(`broken ${start.working}`), "the working version opened");
    const marks = await instrument(page);
    const after = await versions("canvas-broken");
    outcomes[feed] = {
      version: written.ok.version,
      validation: { trees: receiptsOf(marks, from, null, "tree").length, failed: receiptsOf(marks, from, null, "failed").filter((r) => r.frame !== shown.id).length },
      recorded: after.failed,
      working: after.working,
      opened: d.texts[0],
      expected: outcome,
    };
    await showCanvas(page, "home");
  }
  await publish(page, layout());

  const q = outcomes["broken-quiet"];
  const die = outcomes["broken-die"];
  note("validation_failures", name,
    start.working === "1.0.0" &&
      q.validation.trees === 0 && q.recorded && q.recorded.version === q.version && q.recorded.outcome === "no_tree" && q.working === "1.0.0" && q.opened === "broken 1.0.0" &&
      die.validation.trees === 0 && die.validation.failed === 1 && die.recorded && die.recorded.version === die.version && die.recorded.outcome === "died" && die.working === "1.0.0" && die.opened === "broken 1.0.0",
    { first: { working: start.working }, no_tree: q, died: die });
}

// crash_safe_mode: a version that answers its fixture is activated, then
// crashes live on the feed's accepted result: safe mode `crashed`, whose
// kept version is restored and opens.
async function stepCrashSafeMode(page, name) {
  const written = await ask({ op: "write", canvas: "canvas-broken", module: "broken", streams: [{ name: "feed.results", subject: "broken-crash" }] });
  if (!OK(written)) throw new Error(`canvas.write refused canvas-broken: ${JSON.stringify(written)}`);
  const before = await versions("canvas-broken");
  await publish(page, layout([{ id: "crash", tincture: "tincture:local.canvas-broken" }], { without: ["broken"] }));
  const from = (await instrument(page)).receipts.length;
  await page.click('#canvas-switcher button[data-canvas="crash"]');
  const safe = await safeModePrompt(page, 40_000);
  const marks = await instrument(page);
  const activated = await versions("canvas-broken");
  const kept = safe.offers.find((o) => o.offer === "kept");
  await chooseOffer(page, "kept");
  const shown = await showCanvas(page, "crash");
  const d = await drawn(shown.frame, (x) => x.texts.includes(`broken ${before.working}`), "the kept version opened");
  const restored = await versions("canvas-broken");
  await showCanvas(page, "home");
  await publish(page, layout());

  note("crash_safe_mode", name,
    activated.working === written.ok.version && activated.kept === before.working &&
      receiptsOf(marks, from, null, "tree").length === 1 && receiptsOf(marks, from, null, "failed").length >= 1 &&
      safe.kind === "safe_mode" && !!kept && safe.offers.some((o) => o.offer === "retry") && safe.offers.some((o) => o.offer === "shipped") &&
      restored.working === before.working && restored.kept === written.ok.version && d.texts.includes(`broken ${before.working}`),
    {
      activated: { version: written.ok.version, working: activated.working, kept: activated.kept, validation_trees: receiptsOf(marks, from, null, "tree").length },
      crashed: { live_failed_verbs: receiptsOf(marks, from, null, "failed").length, safe_mode: safe.description, offers: safe.offers.map((o) => o.offer), kept_offer: kept && kept.label },
      restored: { working: restored.working, kept: restored.kept, opened: d.texts[0] },
    });
}

// disconnect: the socket is cut and regained; while it is down the canvas is
// marked disconnected and its frame is inert, and after it the canvas is
// live and acts again.
async function stepDisconnect(page, name, proxy, viewport) {
  const home = await showCanvas(page, "home");
  const marker = () => page.$eval("#canvas-status [data-canvas-connection]", (e) => ({ state: e.dataset.canvasConnection, hidden: e.hidden })).catch(() => null);
  proxy.cut();
  const down = await lib.waitFor(async () => {
    const m = await marker();
    return m && m.state === "disconnected" && !m.hidden ? m : null;
  }, { timeoutMs: 30_000, stepMs: 100, what: "the canvas marked disconnected" }).catch(() => null);
  const inert = await canvasFrame(page, home.id);
  const drawnWhileDown = inert ? await drawing(inert.frame) : null;
  proxy.restore();
  const up = await lib.waitFor(async () => {
    const m = await marker();
    return m && m.state === "connected" && m.hidden ? m : null;
  }, { timeoutMs: 60_000, stepMs: 250, what: "the canvas connected again" }).catch(() => null);
  const again = await lib.waitFor(async () => {
    const s = await shownCanvasFrame(page);
    if (!s || s.state !== "live" || s.inert) return null;
    const d = await drawing(s.frame);
    return d && d.texts.includes("Apps") ? s : null;
  }, { timeoutMs: 45_000, stepMs: 100, what: "the canvas live again" }).catch(() => null);
  const acts = again ? await showCanvas(page, "markets").then(() => true).catch(() => false) : false;
  note("disconnect", name, !!down && !!inert && inert.inert && !!drawnWhileDown && !!up && !!again && acts,
    {
      device: viewport.device, posture: viewport.posture,
      while_down: { marked: down, frame_inert: inert && inert.inert, still_drawn: !!drawnWhileDown },
      after: { marked: up, canvas_live: !!again, switches_again: acts },
    });
}

// failed_fire: the scheduler's own failed fire leaves the fixture's claim
// acceptable (fixture.exs `failed_fire`).
async function stepFailedFire(page, name) {
  const answer = await ask({ op: "failed_fire" }, { timeoutMs: 210_000 });
  const fire = answer && answer.fire;
  // The outcome as the store records it: the fires' runs and errors, and
  // whether the accepted seq moved. Why a fire failed is not observable:
  // the store keeps no reason for a fire's error.
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
  return { version: 2, canvases: [
    { id: "home", tincture: "tincture:local.canvas", postures: {} },
    { id, tincture: "tincture:local.measure", postures: {} },
  ] };
}

// One frame open: the switch click's mark to the shell's receipt of that
// canvas frame's `ready`, with no validation frame between.
async function sampleOpen(page, id) {
  const before = await instrument(page);
  const known = new Set(before.receipts.map((r) => r.frame));
  await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
  const found = await lib.waitFor(async () => {
    const m = await instrument(page);
    const click = m.clicks.slice(before.clicks.length).find((c) => c.canvas === id);
    if (!click) return null;
    const ready = m.receipts.slice(before.receipts.length).find((r) => r.verb === "ready" && !known.has(r.frame));
    return ready ? { click, ready, between: m.receipts.slice(before.receipts.length).filter((r) => r.at < ready.at) } : null;
  }, { timeoutMs: SAMPLE_MS, stepMs: 25, what: `${id}'s ready` });
  const live = await canvasFrame(page, found.ready.frame);
  // What the instrument saw: the ready frame's place, and no validation
  // frame's tree or failure received between the click and its ready.
  const between = found.between.map((r) => r.verb);
  return {
    ms: found.ready.at - found.click.at,
    ordered: found.ready.at >= found.click.at,
    frame: found.ready.frame,
    place: live ? live.place : null,
    between,
    fresh: !between.includes("tree") && !between.includes("failed"),
  };
}

// A sample counts only when the instrument saw its kind.
function freshOpen(id, s) {
  if (s.place !== "canvas" || !s.fresh) throw new Error(`${id}'s ready was not a fresh live open: ${JSON.stringify({ place: s.place, between: s.between })}`);
  return s;
}

// One validation: the switch click's mark to the shell's receipt of the
// validation frame's `tree`; the canvas then shows live.
async function sampleValidation(page, id) {
  const before = await instrument(page);
  await page.click(`#canvas-switcher button[data-canvas="${id}"]`);
  const found = await lib.waitFor(async () => {
    const m = await instrument(page);
    const click = m.clicks.slice(before.clicks.length).find((c) => c.canvas === id);
    if (!click) return null;
    const tree = m.receipts.slice(before.receipts.length).find((r) => r.verb === "tree");
    return tree ? { click, tree } : null;
  }, { timeoutMs: SAMPLE_MS, stepMs: 25, what: `${id}'s validation tree` });
  const live = await lib.waitFor(async () => {
    const m = await instrument(page);
    return m.receipts.slice(before.receipts.length).find((r) => r.verb === "ready" && r.frame !== found.tree.frame) || null;
  }, { timeoutMs: SAMPLE_MS, stepMs: 25, what: `${id} live after its validation` });
  return { ms: found.tree.at - found.click.at, ordered: found.tree.at >= found.click.at && live.at >= found.tree.at, frame: found.tree.frame, live: live.frame };
}

async function measurement(page) {
  const m = record.measurement;
  // The measured canvas's first version, validated and activated, and the
  // instrument checked on one validation and one open.
  await publish(page, measureLayout("mz"));
  await showCanvas(page, "home");
  const handed0 = await instrument(page);
  const firstValidation = await sampleValidation(page, "mz");
  const working = await versions("measure");
  await showCanvas(page, "home");
  await publish(page, measureLayout("mo"));
  const firstOpen = await sampleOpen(page, "mo");
  const opened = await showCanvas(page, "mo");
  const draws = await drawn(opened.frame, (d) => d.texts.includes("measure"), "the measured canvas drawn");
  const handed1 = await instrument(page);
  const dropped = await page.$$eval("iframe[data-frame-wire=canvas]", (els) => els.map((e) => Number(e.dataset.dropped || "0")).reduce((a, b) => a + b, 0));
  m.instrument_check = {
    validation: { click_then_tree_then_live_ready: firstValidation.ordered, tree_frame_is_not_the_live_frame: firstValidation.frame !== firstValidation.live },
    open: {
      click_then_ready: firstOpen.ordered,
      ready_frame_place: firstOpen.place,
      received_between: firstOpen.between,
      fresh_live_frame_with_no_validation_between: firstOpen.place === "canvas" && firstOpen.fresh,
    },
    bridge_handed_every_message_on: handed1.seen === handed1.handed && handed1.seen > handed0.seen,
    bridge_dropped: dropped,
    tree_reached_prism: working.working === "0.1.0",
    canvas_answers_and_opens: draws.texts.includes("measure"),
  };
  const instrumentOk = firstValidation.ordered && firstValidation.frame !== firstValidation.live && firstOpen.ordered &&
    m.instrument_check.open.fresh_live_frame_with_no_validation_between &&
    m.instrument_check.bridge_handed_every_message_on &&
    dropped === 0 && m.instrument_check.tree_reached_prism && m.instrument_check.canvas_answers_and_opens;
  if (!instrumentOk) throw new Error(`the instrument's own check failed: ${JSON.stringify(m.instrument_check)}`);
  await showCanvas(page, "home");

  // Each sample is counted as it is taken, so a run that stops short
  // records what it measured; a sample missing its mark stops the run.
  const open = [];
  const validation = [];
  const round = (x) => Math.round(x * 10) / 10;
  const pct = (values) => {
    const p = lib.percentiles(values);
    return { p50: p.p50 === null ? null : round(p.p50), p95: p.p95 === null ? null : round(p.p95), clock: CLOCK };
  };
  const tally = () => {
    m.counts = { open: open.length, validation: validation.length };
    m.frame_open_ms = { ...pct(open), from: "the switch click", to: "the shell's receipt of the canvas frame's ready" };
    m.validation_ms = { ...pct(validation), from: "the switch click", to: "the shell's receipt of the validation frame's tree" };
    m.samples_ms = { open: open.map(round), validation: validation.map(round) };
  };
  tally();
  for (let i = 1; i <= SAMPLES; i++) {
    await publish(page, measureLayout(`open${i}`));
    const s = freshOpen(`open${i}`, await sampleOpen(page, `open${i}`));
    if (!s.ordered) throw new Error(`frame open ${i} has its marks out of order`);
    open.push(s.ms);
    tally();
    await showCanvas(page, "home");
  }
  for (let i = 1; i <= SAMPLES; i++) {
    const written = await ask({ op: "write", canvas: "measure", module: "measure", streams: [] });
    if (!OK(written)) throw new Error(`canvas.write refused measure: ${JSON.stringify(written)}`);
    await publish(page, measureLayout(`val${i}`));
    const s = await sampleValidation(page, `val${i}`);
    if (!s.ordered) throw new Error(`validation ${i} has its marks out of order`);
    validation.push(s.ms);
    tally();
    await showCanvas(page, "home");
  }
  await publish(page, layout());
}

// ---- running one browser --------------------------------------------------------

async function recover(page) {
  await openShell(page).catch(() => null);
  const p = await prompt(page);
  if (p && p.kind === "safe_mode") await chooseOffer(page, "retry").catch(() => null);
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
  switch: async () => {},
  written_canvas: (page, name) => stepWrittenCanvas(page, name),
  feed_chart: (page, name) => stepFeedChart(page, name),
  app_over_canvas: (page, name) => stepAppOverCanvas(page, name),
  worker_stop: (page, name) => stepWorkerStop(page, name),
  exits: (page, name, { proxy, receiver, udp }) => stepExits(page, name, proxy, receiver, udp),
  worker_policy: (page, name, { proxy }) => stepWorkerPolicy(page, name, proxy),
  labels: (page, name) => stepLabels(page, name),
  activation_once: (page, name) => stepActivationOnce(page, name),
  rebound_control: (page, name) => stepReboundControl(page, name),
  validation_failures: (page, name) => stepValidationFailures(page, name),
  crash_safe_mode: (page, name) => stepCrashSafeMode(page, name),
  disconnect: (page, name, { proxy, viewport }) => stepDisconnect(page, name, proxy, viewport),
  failed_fire: (page, name) => stepFailedFire(page, name),
};

let BASE = null;
let COOKIE = null;

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
    row("validation: switch click to the shell's receipt of tree", "validation_ms", m.counts ? m.counts.validation : 0),
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

  const [server, segment, cookie, outDir, viewportName, narrowing, hostClass] = argv;
  const viewport = VIEWPORTS[viewportName];
  if (!server || !segment || !cookie || !outDir || !viewport || !budgetOf(hostClass)) {
    console.error(`usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR desktop|720x720 NARROWING ${Object.keys(BUDGET_MS).join("|")}`);
    process.exit(64);
  }
  lib = await import("../browser/lib.mjs");
  sleep = lib.sleep;
  OUT = outDir;
  COOKIE = cookie;
  secrets.push(cookie);
  mkdirSync(outDir, { recursive: true });

  // A local run may narrow the matrix (browsers=…;steps=…;measure=0); its
  // record says so and never passes as the proof's.
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
  BASE = `http://${lib.SITE}:${new URL(server).port || 80}`;
  SHELL_URL = `${BASE}/a/${encodeURIComponent(segment)}/tinctures`;
  const proxy = await lib.startProxy(server, { receiver, bodies: false });

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
