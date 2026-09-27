// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The canvas proof, run in the official Playwright image by run.sh against a
// `cyfr` release holding the shipped desktop and vault, and the proof's
// tinctures (tinctures/): canvas-card (one static card), canvas-full (a page
// opened full over the desktop) and canvas-stall (a desktop that never says
// it is ready). The fixture's person has a layout run.sh published: the
// shipped desktop in both postures, the vault as an icon, canvas-card as a
// card and canvas-full as an icon, in another order per posture.
//
// For every browser the image ships, one after another:
//
//   postures     a desk viewport and a hand viewport of the same person each
//                show the desktop with its strip, the card and the vault
//                icon, in that posture's order;
//   full         canvas-full opened from the desktop and closed: the
//                desktop frozen while covered (inert, and a call from it
//                refused as suspended), Tab from its capsule landing on no
//                control it covers, and live again after;
//   vault        the vault page lists names; an entry is added through the
//                shell's credential prompt by keyboard alone; the value is
//                in no frame's DOM and in no request a frame made (read at
//                the harness's proxy); the entry is then listed;
//   safe mode    by the chord Ctrl+Alt+S, and by a desktop that never sends
//                ready (canvas-stall, set as the layout's desktop by the
//                shipped desktop's own layout.edit): every frame gone, the
//                prompt operated by keyboard alone, the shipped desktop back;
//   prompts      each prompt has a role, an accessible name and a
//                description, takes focus when shown and gives it back;
//   disconnect   the LiveView socket cut at the proxy: the last layout stays
//                drawn and marked disconnected, a frame's actions fail
//                closed; on reconnect the desktop acts again.
//
// Then, with a tab open in every browser at once, run.sh kills the release
// (`stop-server` in OUT_DIR, answered by `server-stopped`): the last layout
// stays drawn and every stream and action fails closed.
//
// Measurements, recorded and not gated: card.refresh through the endpoint
// from the desktop, 50 in a row; vault.status through the endpoint from the
// vault page, 200 at concurrency 16; and the in-server measurements run.sh
// took (server-measurements-*.json in OUT_DIR).
//
// Usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR [BROWSERS]
// BROWSERS, comma-separated, narrows the matrix for a local run.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  BROWSERS, SITE, awaitFrame, chromium, firefox, percentiles, sleep, startProxy, waitFor, webkit,
} from "../browser/lib.mjs";

const TYPES = { chromium, firefox, webkit };
const DESK = { width: 1280, height: 800 };
const HAND = { width: 390, height: 844 };
const ORDER = { desk: ["vault", "card", "full-app"], hand: ["card", "vault", "full-app"] };
const STALL = "tincture:local.canvas-stall";
const READY_DEADLINE_MS = 10_000;

const failures = [];
function check(condition, browser, section, name, what, detail) {
  if (!condition) failures.push({ browser, section, name, what, detail });
  console.log(`${condition ? "ok" : "FAIL"}: ${browser}/${section}/${name}: ${what}` +
    `${condition ? "" : ` — ${JSON.stringify(detail)}`}`);
  return condition;
}

// ---- the shell and its frames ----------------------------------------------

async function context(browser, name, base, cookie, viewport) {
  const touch = viewport === HAND;
  const options = { viewport, hasTouch: touch };
  if (touch && name !== "firefox") options.isMobile = true;
  const ctx = await browser.newContext(options);
  await ctx.addCookies([{
    name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: false, sameSite: "Lax",
  }]);
  return ctx;
}

async function openShell(page, base, segment) {
  // What the page said, kept for the account of a shell that never
  // connected or never drew its desktop.
  const said = [];
  page.on("console", (m) => said.push(`${m.type()}: ${m.text()}`));
  page.on("pageerror", (e) => said.push(`pageerror: ${e.message}`));
  const response = await page.goto(`${base}/a/${encodeURIComponent(segment)}/tinctures`);
  try {
    await page.waitForSelector(".phx-connected", { timeout: 30_000 });
    return await desktop(page);
  } catch (error) {
    const body = await page.evaluate(() => document.body && document.body.innerText.slice(0, 600)).catch(() => null);
    console.error(`openShell: ${error.message}\n  status ${response && response.status()} at ${page.url()}\n  body: ${JSON.stringify(body)}\n  console: ${JSON.stringify(said.slice(-20))}`);
    throw error;
  }
}

const frameIds = (page) =>
  page.$$eval("iframe[phx-hook=IframeBridge]", (els) => els.map((e) => e.id)).catch(() => []);

// The desktop frame once its strip is drawn and its handshake done.
async function desktop(page, { slots = 3, timeoutMs = 60_000 } = {}) {
  return waitFor(async () => {
    const element = await page.$('[data-canvas-place="desktop"] iframe[phx-hook=IframeBridge]');
    const frame = element && await element.contentFrame();
    if (!frame) return null;
    const drawn = await frame.evaluate((n) =>
      !!(window.cyfr && window.cyfr.frame) && document.querySelectorAll("#strip li[data-slot]").length >= n,
    slots).catch(() => false);
    return drawn ? { element, frame, id: await element.getAttribute("id") } : null;
  }, { timeoutMs, stepMs: 100, what: "the desktop" });
}

// A call a frame makes through the SDK, answered as `{ok, value}` or
// `{ok: false, code, message}`.
const call = (frame, kind, name, args = {}) =>
  frame.evaluate(async ([kind, name, args]) => {
    try {
      const value = kind === "stream"
        ? await window.cyfr.stream(name, null, () => {}).then((h) => { h.close(); return "opened"; })
        : await window.cyfr.action(name, args);
      return { ok: true, value };
    } catch (error) {
      return { ok: false, code: error.code || null, message: String(error.message) };
    }
  }, [kind, name, args]).catch((error) => ({ ok: false, code: "evaluate", message: error.message }));

async function openFromDesktop(page, desk, slot) {
  const known = new Set(await frameIds(page));
  await desk.frame.click(`li[data-slot="${slot}"] button.icon`);
  return awaitFrame(page, known, 30_000);
}

async function closeFull(page) {
  await page.locator('button[phx-click="close_active_tincture"]:visible').click();
  await waitFor(async () => !(await page.$('[data-canvas-place="full"] iframe')), { what: "the full frame closed" });
}

const standing = (element) => element.evaluate((e) => ({
  inert: e.inert === true, state: e.getAttribute("data-frame-state"), dropped: e.dataset.dropped || "0",
}));

// ---- the system layer ------------------------------------------------------

// The open prompt's facts: its kind, role, accessible name and description,
// and whether focus is inside it.
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
    const shown = dialog.open || (() => { try { return dialog.matches(":popover-open"); } catch (_e) { return false; } })();
    const kind = dialog.querySelector("[data-kind]");
    return {
      kind: kind ? kind.dataset.kind : null,
      shown,
      role: dialog.getAttribute("role"),
      name: text("aria-labelledby"),
      description: text("aria-describedby"),
      focused: dialog.contains(document.activeElement),
      active: document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : null,
    };
  });
}

async function shownPrompt(page, kind) {
  return waitFor(async () => {
    const p = await prompt(page);
    return p && p.kind === kind && p.shown && p.focused ? p : null;
  }, { timeoutMs: 30_000, stepMs: 50, what: `the ${kind} prompt, shown with focus in it` });
}

const activeId = (page) => page.evaluate(() => {
  const a = document.activeElement;
  return a ? { id: a.id || null, tag: a.tagName, connected: a.isConnected } : null;
});

function promptFacts(browser, section, facts, roles) {
  check(roles.includes(facts.role), browser, section, "prompt_role", `the prompt has role ${roles.join(" or ")}`, facts);
  check(facts.name !== "", browser, section, "prompt_name", "the prompt has an accessible name", facts);
  check(facts.description !== "", browser, section, "prompt_description", "the prompt has a description", facts);
  check(facts.focused, browser, section, "prompt_focus", "focus is inside the prompt when it is shown", facts);
}

// Focus left the prompt and went back to the element that had it before,
// or to the body when that element is gone.
async function focusRestored(page, before) {
  return waitFor(async () => {
    const now = await page.evaluate((beforeId) => {
      const dialog = document.getElementById("system-layer-dialog");
      const a = document.activeElement;
      const back = beforeId && document.getElementById(beforeId);
      return {
        inside: !!(dialog && dialog.contains(a)),
        id: a ? a.id || a.tagName : null,
        restored: back && back.isConnected ? a === back : a === document.body || a === null,
      };
    }, before && before.id);
    return !now.inside && now.restored ? now : null;
  }, { timeoutMs: 10_000, stepMs: 50, what: "focus back where it was" }).catch(() => null);
}

// ---- sections --------------------------------------------------------------

async function postures(browser, name, base, segment, cookie, record) {
  for (const [posture, viewport] of [["desk", DESK], ["hand", HAND]]) {
    const ctx = await context(browser, name, base, cookie, viewport);
    try {
      const page = await ctx.newPage();
      const desk = await openShell(page, base, segment);
      const reported = await page.$eval("#canvas", (e) => e.dataset.posture);
      const strip = await desk.frame.$$eval("#strip li[data-slot]", (els) => els.map((e) => e.dataset.slot));
      const card = await waitFor(() => desk.frame.$eval('li[data-slot="card"] .card-title', (e) => e.textContent)
        .catch(() => null), { timeoutMs: 20_000, what: "the card" }).catch(() => null);
      const vault = await desk.frame.$('li[data-slot="vault"] button.icon');
      const place = await page.$eval('[data-canvas-place="desktop"]', (e) => e.getBoundingClientRect())
        .then((r) => ({ width: Math.round(r.width), height: Math.round(r.height) }));
      record[posture] = { reported, strip, card, vault: !!vault, place };
      check(reported === posture, name, "postures", `${posture}_posture`, `the canvas reports ${posture}`, reported);
      check(JSON.stringify(strip) === JSON.stringify(ORDER[posture]), name, "postures", `${posture}_strip`,
        `the desktop's strip is the ${posture} arrangement, in its order`, strip);
      check(card === "Hello card", name, "postures", `${posture}_card`, "the card is drawn from card.refresh", card);
      check(!!vault, name, "postures", `${posture}_vault`, "the vault is an icon on the desktop", !!vault);
      check(place.width > 0 && place.height > 0, name, "postures", `${posture}_fills`, "the desktop fills the canvas", place);
    } finally {
      await ctx.close();
    }
  }
}

// The data routes hold every address to a request budget per window
// (`CyfrWeb.Plugs.TinctureRateLimit`, 120 a minute), and every browser
// reaches the server from the proxy's one address: a measurement runs in
// budget-sized batches, each followed by the window's end.
const BUDGET_WINDOW_MS = 61_000;

// `calls` calls of `action` from `frame`, `concurrency` at once, each
// timed in the frame; a refusal is counted, not timed.
const timed = (frame, action, args, calls, concurrency) =>
  frame.evaluate(async ([action, args, calls, concurrency]) => {
    const out = { ms: [], refused: {} };
    let next = 0;
    const worker = async () => {
      while (next < calls) {
        next += 1;
        const at = performance.now();
        try {
          await window.cyfr.action(action, args);
          out.ms.push(performance.now() - at);
        } catch (error) {
          out.refused[error.code] = (out.refused[error.code] || 0) + 1;
        }
      }
    };
    await Promise.all(Array.from({ length: concurrency }, worker));
    return out;
  }, [action, args, calls, concurrency]);

async function measure(frame, action, args, batches, concurrency) {
  const ms = [];
  const refused = {};
  for (const calls of batches) {
    await sleep(BUDGET_WINDOW_MS);
    const batch = await timed(frame, action, args, calls, concurrency);
    ms.push(...batch.ms);
    for (const [code, n] of Object.entries(batch.refused)) refused[code] = (refused[code] || 0) + n;
  }
  await sleep(BUDGET_WINDOW_MS);
  return { ...percentiles(ms.map((v) => Math.round(v * 10) / 10)), refused, concurrency };
}

// Where focus lands on each of `presses` Tabs from the shown full frame's
// close control: whether the element is under the full frame (the full
// frame is what the page shows at its centre) without being part of it.
async function tabFromCapsule(page, presses) {
  await page.focus('[data-canvas-place="full"] button[phx-click="close_active_tincture"]');
  const landings = [];
  for (let i = 0; i < presses; i++) {
    await page.keyboard.press("Tab");
    landings.push(await page.evaluate(() => {
      const full = document.querySelector('[data-canvas-place="full"]:not(.hidden)');
      const a = document.activeElement;
      if (!a || a === document.body || !full) return { at: "body", covered: false };
      const label = a.id || a.getAttribute("aria-label") || a.tagName;
      if (full.contains(a)) return { at: label, covered: false };
      const assistant = !!a.closest("#aqua-panel");
      const r = a.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return { at: label, covered: false, unseen: true };
      const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      const under = !!top && full.contains(top);
      return { at: label, covered: under && !assistant, assistant: under && assistant };
    }));
  }
  return landings;
}

async function full(page, name, record) {
  let desk = await desktop(page);
  const opened = await openFromDesktop(page, desk, "full-app");
  await opened.frame.waitForFunction(() => document.body.dataset.drawn === "yes", null, { timeout: 30_000 });
  const covered = await waitFor(async () => {
    const s = await standing(desk.element);
    return s.inert && s.state === "frozen" ? s : null;
  }, { timeoutMs: 15_000, what: "the desktop frozen" }).catch(() => standing(desk.element));
  const refused = await waitFor(async () => {
    const r = await call(desk.frame, "action", "layout.get", { posture: "desk" });
    return !r.ok && /suspend/i.test(r.message) ? r : null;
  }, { timeoutMs: 15_000, stepMs: 1000, what: "the covered desktop refused" })
    .catch(() => call(desk.frame, "action", "layout.get", { posture: "desk" }));
  check(covered.inert && covered.state === "frozen", name, "full", "desktop_frozen",
    "the desktop is frozen and inert while a full frame covers it", covered);
  check(!refused.ok && /suspend/i.test(refused.message), name, "full", "desktop_suspended",
    "a call from the covered desktop is refused as suspended", refused);

  // Tab from the full frame's capsule never lands on a control the full
  // frame covers. The assistant's panel is left reachable by design and is
  // counted apart.
  const tabs = await tabFromCapsule(page, 40);
  const onCovered = tabs.filter((t) => t.covered);
  check(onCovered.length === 0, name, "full", "tab_skips_covered",
    "Tab from the full frame's capsule never lands on a covered control", onCovered);

  await closeFull(page);
  const live = await waitFor(async () => {
    const s = await standing(desk.element);
    return !s.inert && s.state === "live" ? s : null;
  }, { timeoutMs: 15_000, what: "the desktop live again" }).catch(() => standing(desk.element));
  const again = await waitFor(async () => {
    const r = await call(desk.frame, "action", "layout.get", { posture: "desk" });
    return r.ok ? r : null;
  }, { timeoutMs: 15_000, stepMs: 1000, what: "the desktop acting" })
    .catch(() => call(desk.frame, "action", "layout.get", { posture: "desk" }));
  check(!live.inert && live.state === "live" && again.ok, name, "full", "desktop_live",
    "closing the full frame makes the desktop live again", { live, again: again.ok });
  record.full = {
    covered, refused: { code: refused.code, message: refused.message }, live,
    tab_landings: tabs.length, tab_on_covered: onCovered.length,
    tab_on_assistant: tabs.filter((t) => t.assistant).length,
  };
}

async function vault(page, name, proxy, record) {
  const secret = `v4lue-${name}-${Math.random().toString(36).slice(2)}`;
  const entry = `proof-${name}`;
  const desk = await desktop(page);
  const opened = await openFromDesktop(page, desk, "vault");
  const frame = opened.frame;
  const listed = await waitFor(() => frame.$$eval("#entries-body tr[data-entry]", (els) => els.map((e) => e.dataset.entry))
    .then((names) => (names.includes("seeded-api") ? names : null)).catch(() => null),
  { timeoutMs: 30_000, what: "the vault's names" }).catch(() => []);
  check(listed.includes("seeded-api"), name, "vault", "listing", "the vault page lists entry names", listed);
  const offers = await frame.evaluate(() => ({
    note: (document.getElementById("console-note") || {}).textContent || "",
    buttons: [...document.querySelectorAll("button")].map((b) => b.textContent.trim()),
  })).catch(() => ({ note: "", buttons: [] }));
  check(offers.note === "Entries are changed and removed on the console's vault page." &&
    JSON.stringify(offers.buttons.sort()) === JSON.stringify(["Add entry", "Refresh"]),
  name, "vault", "lists_and_adds_only",
  "the page lists and adds, and says entries are changed and removed on the console's vault page", offers);

  // The name field by keyboard alone: Tab until it holds focus.
  // Focus is in the frame when the shell's active element is the frame's
  // element, and then the frame's own active element is where it is.
  const focusedIn = async () => {
    const inFrame = await page.evaluate((id) => !!document.activeElement && document.activeElement.id === id,
      opened.attributes.id).catch(() => false);
    if (!inFrame) return null;
    return frame.evaluate(() => document.activeElement && document.activeElement.id).catch(() => null);
  };
  let tabs = 0;
  for (; tabs < 120; tabs++) {
    if ((await focusedIn()) === "add-name") break;
    await page.keyboard.press("Tab");
  }
  const reached = await focusedIn();
  check(reached === "add-name", name, "vault", "keyboard_reach", "Tab reaches the vault's name field", { tabs, reached });

  const mark = proxy.seen.length;
  await page.keyboard.type(entry);
  record.vault_typed = await frame.evaluate(() => ({
    active: document.activeElement && (document.activeElement.id || document.activeElement.textContent),
    value: document.getElementById("add-name").value,
  })).catch((e) => e.message);
  const before = await activeId(page);
  await page.keyboard.press("Enter");
  const shown = await shownPrompt(page, "credential_entry").catch(async () => prompt(page));
  if (shown) promptFacts(name, "vault", shown, ["dialog"]);
  const diagnosis = shown ? null : {
    typedAt: await frame.evaluate(() => ({
      active: document.activeElement && (document.activeElement.id || document.activeElement.textContent),
      value: document.getElementById("add-name").value,
      status: document.getElementById("status").textContent,
    })).catch((e) => e.message),
    bridge: await standing(opened.element).catch((e) => e.message),
  };
  check(!!shown && shown.name.includes(entry), name, "vault", "prompt_names_entry",
    "the credential prompt names the entry it saves", shown || diagnosis);

  // The secret, typed into the shell's own field and submitted with Enter.
  const field = await page.evaluate(() => document.activeElement && document.activeElement.getAttribute("type"));
  if (field !== "password") {
    for (let i = 0; i < 6; i++) {
      await page.keyboard.press("Tab");
      if (await page.evaluate(() => document.activeElement && document.activeElement.getAttribute("type") === "password")) break;
    }
  }
  await page.keyboard.type(secret);
  await page.keyboard.press("Enter");
  const closed = await waitFor(async () => !(await prompt(page)), { timeoutMs: 20_000, what: "the prompt closed" })
    .then(() => true).catch(() => false);
  check(closed, name, "vault", "prompt_closed", "the prompt closes once the entry is saved", closed);
  const restored = await focusRestored(page, before);
  check(!!restored, name, "vault", "prompt_focus_restored", "focus returns where it was before the prompt", { before, restored });

  const after = await waitFor(() => frame.$$eval("#entries-body tr[data-entry]", (els) => els.map((e) => e.dataset.entry))
    .then((names) => (names.includes(entry) ? names : null)).catch(() => null),
  { timeoutMs: 20_000, what: "the new entry listed" }).catch(() => []);
  check(after.includes(entry), name, "vault", "entry_listed", "the entry is listed once saved", after);
  const told = await frame.$eval("#status", (e) => e.textContent).catch(() => "");
  check(told.includes(`Saved ${entry}`), name, "vault", "told_saved", "the page is told the entry was saved", told);

  // The value is in no frame's document and in no request a frame made.
  const doms = [];
  for (const f of page.frames()) {
    if (f === page.mainFrame()) continue;
    const html = await f.evaluate(() => document.documentElement.outerHTML).catch(() => "");
    doms.push({ url: f.url().replace(/\/_s\/[^/]+/, "/_s/…"), carries: html.includes(secret) });
  }
  const framed = proxy.seen.slice(mark).filter((r) => r.host === SITE && /^\/(_f|_s|t)\//.test(new URL(r.url).pathname));
  const leaked = framed.filter((r) => r.url.includes(secret) || (r.body || "").includes(secret));
  const anywhere = proxy.seen.slice(mark).filter((r) => r.url.includes(secret) || (r.body || "").includes(secret));
  check(doms.length >= 1 && doms.every((d) => !d.carries), name, "vault", "value_not_in_frames",
    "the value is in no frame's document", doms);
  check(framed.length > 0 && leaked.length === 0, name, "vault", "value_not_in_frame_requests",
    "the value is in no request a frame made, as the proxy read them", { requests: framed.length, leaked: leaked.length });

  // vault.status through the endpoint, as the page asks it: 200 calls at
  // concurrency 16, in two batches the request budget admits.
  if (record.measuring) {
    record.measurements.vault_status_endpoint = await measure(frame, "vault.status", {}, [100, 100], 16);
  }
  record.vault = {
    listed, tabs, prompt: shown, restored, entry_listed: after.includes(entry),
    frame_requests: framed.length, leaked: leaked.length, any_request_carrying_value: anywhere.length,
  };
  await closeFull(page);
}

async function safeModeByChord(page, name, record) {
  await desktop(page);
  const before = await activeId(page);
  await page.keyboard.press("Control+Alt+KeyS");
  const shown = await shownPrompt(page, "safe_mode").catch(async () => prompt(page));
  const frames = await frameIds(page);
  const picker = !!(await page.$("#shell-picker"));
  check(!!shown, name, "safe_mode_chord", "entered", "Ctrl+Alt+S on the shell's page enters safe mode", shown);
  if (shown) promptFacts(name, "safe_mode_chord", shown, ["alertdialog"]);
  check(frames.length === 0, name, "safe_mode_chord", "frames_gone", "every frame is gone", frames);
  check(picker, name, "safe_mode_chord", "picker", "the picker is drawn", picker);

  // Try again, by keyboard: focus is on the first offer.
  await page.keyboard.press("Enter");
  const desk = await desktop(page).catch(() => null);
  const restored = await focusRestored(page, before);
  const seen = desk ? null : await page.evaluate(() => ({
    frames: [...document.querySelectorAll("[data-canvas-frame]")].map((e) => e.dataset.canvasPlace + ":" + (e.querySelector("iframe") ? "iframe" : e.textContent.trim())),
    picker: !!document.getElementById("shell-picker"),
    layer: document.getElementById("system-layer") && document.getElementById("system-layer").dataset.open,
    posture: document.getElementById("canvas") && document.getElementById("canvas").dataset.posture,
  })).catch((e) => e.message);
  check(!!desk && !(await prompt(page)), name, "safe_mode_chord", "left", "choosing leaves safe mode and the desktop runs again", seen || !!desk);
  check(!!restored, name, "safe_mode_chord", "prompt_focus_restored", "focus leaves the prompt once it closes", { before, restored });
  record.safe_mode_chord = { prompt: shown, frames_during: frames.length, picker, restored };
}

async function safeModeByStall(page, name, record) {
  const desk = await desktop(page);
  // The shipped desktop sets canvas-stall as the desktop, through its own layout.edit.
  const set = await desk.frame.evaluate(async (stall) => {
    const read = await window.cyfr.action("layout.get", { posture: "desk" });
    const document_ = JSON.parse(JSON.stringify(read.document));
    for (const posture of ["desk", "hand"]) {
      const own = document_.postures[posture] || { slots: [], floating: [] };
      document_.postures[posture] = { ...own, desktop: stall };
    }
    return window.cyfr.action("layout.edit", { document: document_, revision: read.revision });
  }, STALL).then((v) => ({ ok: true, v })).catch((e) => ({ ok: false, message: String(e.message) }));

  const started = Date.now();
  const stalled = await waitFor(async () => {
    const el = await page.$('[data-canvas-place="desktop"] iframe');
    const src = el && await el.getAttribute("src");
    return src && src.includes("/canvas-stall/") ? src : null;
  }, { timeoutMs: 30_000, what: "canvas-stall opened as the desktop" }).catch(() => null);
  // The shell replaces the desktop as soon as the edit lands, so the
  // desktop's own frame may be gone before the answer reaches it (each
  // browser words that its own way): the edit is proved by the desktop
  // the shell opens.
  const frameGone = /detached|execution context was destroyed|navigation/i.test(set.message || "");
  check(set.ok || (frameGone && !!stalled), name, "safe_mode_stall", "layout_set",
    "the desktop publishes canvas-stall as the layout's desktop", set);
  check(!!stalled, name, "safe_mode_stall", "stall_opened", "the shell reads the layout again and opens its desktop", stalled);
  const before = await activeId(page);
  const shown = await waitFor(async () => {
    const p = await prompt(page);
    return p && p.kind === "safe_mode" && p.shown && p.focused ? p : null;
  }, { timeoutMs: READY_DEADLINE_MS + 20_000, stepMs: 200, what: "safe mode for a desktop that never said ready" })
    .catch(async () => prompt(page));
  const waited = Date.now() - started;
  const frames = await frameIds(page);
  check(!!shown && shown.description.includes("did not start"), name, "safe_mode_stall", "entered",
    "a desktop that never sends ready is safe mode", shown);
  check(waited >= READY_DEADLINE_MS - 1000, name, "safe_mode_stall", "waited_for_ready",
    "safe mode waits the desktop's ten seconds", waited);
  if (shown) promptFacts(name, "safe_mode_stall", shown, ["alertdialog"]);
  check(frames.length === 0, name, "safe_mode_stall", "frames_gone", "every frame is gone", frames);

  // The default, by keyboard: Tab from the first offer to the second, Enter.
  await page.keyboard.press("Tab");
  const on = await page.evaluate(() => document.activeElement && document.activeElement.textContent.trim());
  await page.keyboard.press("Enter");
  const back = await desktop(page).catch(() => null);
  const src = back && await back.element.getAttribute("src");
  const restored = await focusRestored(page, before);
  check(on === "Use the default desktop", name, "safe_mode_stall", "keyboard_default", "Tab reaches the default offer", on);
  check(!!src && src.includes("/local/desktop/"), name, "safe_mode_stall", "default_back",
    "choosing the default brings the shipped desktop back", src && src.replace(/\/_s\/[^/]+/, "/_s/…"));
  check(!!restored, name, "safe_mode_stall", "prompt_focus_restored", "focus leaves the prompt once it closes", { before, restored });
  record.safe_mode_stall = { waited_ms: waited, prompt: shown, frames_during: frames.length, offer: on, restored };
}

async function disconnect(page, name, proxy, record) {
  const desk = await desktop(page);
  const marker = () => page.$eval("#canvas-status [data-canvas-connection]", (e) => ({
    state: e.dataset.canvasConnection, hidden: e.hidden,
  })).catch(() => null);

  proxy.cut();
  const down = await waitFor(async () => {
    const m = await marker();
    return m && m.state === "disconnected" && !m.hidden ? m : null;
  }, { timeoutMs: 20_000, what: "the canvas marked disconnected" }).catch(() => marker());
  const still = !!(await page.$(`iframe[id="${desk.id}"]`)) &&
    (await desk.frame.$$eval("#strip li[data-slot]", (els) => els.length).catch(() => 0)) >= 3;
  const inert = await standing(desk.element);
  const known = new Set(await frameIds(page));
  await desk.frame.evaluate(() => window.cyfr.open("tincture:local.canvas-full")).catch(() => null);
  await sleep(1000);
  const opened = (await frameIds(page)).filter((id) => !known.has(id));
  const dropped = await standing(desk.element);
  const refused = await waitFor(async () => {
    const r = await call(desk.frame, "action", "layout.get", { posture: "desk" });
    return r.ok ? null : r;
  }, { timeoutMs: 20_000, stepMs: 1000, what: "the desktop's action refused" })
    .catch(() => call(desk.frame, "action", "layout.get", { posture: "desk" }));

  check(down && down.state === "disconnected" && !down.hidden, name, "disconnect", "marked",
    "the canvas is marked disconnected", down);
  check(still, name, "disconnect", "layout_kept", "the last layout stays drawn", still);
  check(inert.inert, name, "disconnect", "frames_inert", "every frame is inert while the socket is down", inert);
  check(opened.length === 0 && Number(dropped.dropped) > Number(inert.dropped), name, "disconnect", "verb_dropped",
    "a frame's shell verb is dropped while the socket is down", { opened, before: inert.dropped, after: dropped.dropped });
  check(!refused.ok, name, "disconnect", "action_fails_closed",
    "a frame's data action fails closed once the view is gone", refused);

  proxy.restore();
  const up = await waitFor(async () => {
    const m = await marker();
    return m && m.state === "connected" && m.hidden ? m : null;
  }, { timeoutMs: 60_000, stepMs: 250, what: "the canvas connected again" }).catch(() => marker());
  const again = await desktop(page).catch(() => null);
  const acted = again ? await call(again.frame, "action", "layout.get", { posture: "desk" }) : { ok: false };
  let reopened = false;
  if (again) {
    const openedAgain = await openFromDesktop(page, again, "full-app").catch(() => null);
    reopened = !!openedAgain;
    if (openedAgain) await closeFull(page);
  }
  check(up && up.state === "connected", name, "disconnect", "reconnected", "the socket comes back", up);
  check(!!again && again.id !== desk.id && acted.ok && reopened, name, "disconnect", "acting_again",
    "the desktop acts again after the reconnect, as a new frame", { id: again && again.id, acted: acted.ok, reopened });
  record.disconnect = {
    marked: down, layout_kept: still, inert: inert.inert, verb_opened: opened.length,
    action: { ok: refused.ok, code: refused.code || null }, reconnected: up, acting_again: acted.ok && reopened,
  };
}

// ---- one browser -------------------------------------------------------------

async function run(name, base, proxy, segment, cookie, measuring) {
  const browser = await TYPES[name].launch({ proxy: { server: `http://127.0.0.1:${proxy.address().port}` } });
  const record = { version: browser.version(), measurements: {}, measuring };
  try {
    console.log(`== ${name} ${browser.version()}`);
    await postures(browser, name, base, segment, cookie, record);

    const ctx = await context(browser, name, base, cookie, DESK);
    try {
      const page = await ctx.newPage();
      const desk = await openShell(page, base, segment);
      if (measuring) {
        record.measurements.card_refresh =
          await measure(desk.frame, "card.refresh", { slot: "card", posture: "desk" }, [50], 1);
      }
      for (const [section, fn] of [
        ["full", () => full(page, name, record)],
        ["vault", () => vault(page, name, proxy, record)],
        ["safe_mode_chord", () => safeModeByChord(page, name, record)],
        ["safe_mode_stall", () => safeModeByStall(page, name, record)],
        ["disconnect", () => disconnect(page, name, proxy, record)],
      ]) {
        try {
          await fn();
        } catch (error) {
          check(false, name, section, "ran", "the section ran to its end", error.message);
          await page.goto(`${base}/a/${encodeURIComponent(segment)}/tinctures`).catch(() => null);
        }
      }
    } finally {
      await ctx.close();
    }
  } finally {
    await browser.close();
  }
  return record;
}

// ---- the server gone -----------------------------------------------------------

async function serverGone(browsers, base, proxy, segment, cookie, outDir) {
  const tabs = [];
  const record = {};
  try {
    for (const name of browsers) {
      const browser = await TYPES[name].launch({ proxy: { server: `http://127.0.0.1:${proxy.address().port}` } });
      const ctx = await context(browser, name, base, cookie, DESK);
      const page = await ctx.newPage();
      const desk = await openShell(page, base, segment);
      await desk.frame.evaluate(async () => {
        const handle = await window.cyfr.stream("cards.refreshed", null, () => {});
        window.__proofStream = "open";
        handle.closed.then(() => { window.__proofStream = "ended"; }, () => { window.__proofStream = "broken"; });
      });
      const events = [];
      page.on("framenavigated", (f) => { if (f === page.mainFrame()) events.push(`navigated ${f.url()}`); });
      page.on("console", (m) => { if (/phx|reload|socket|transport|join/i.test(m.text())) events.push(m.text().slice(0, 200)); });
      await page.evaluate(() => window.liveSocket && window.liveSocket.enableDebug()).catch(() => null);
      tabs.push({ name, browser, page, desk, events });
    }

    writeFileSync(join(outDir, "stop-server"), "stop\n");
    await waitFor(() => existsSync(join(outDir, "server-stopped")), { timeoutMs: 120_000, stepMs: 250, what: "the release stopped" });

    for (const { name, page, desk, events } of tabs) {
      const marker = await waitFor(() => page.$eval("#canvas-status [data-canvas-connection]", (e) =>
        (e.dataset.canvasConnection === "disconnected" && !e.hidden ? e.dataset.canvasConnection : null)).catch(() => null),
      { timeoutMs: 30_000, what: "the canvas marked disconnected" }).catch(() => null);
      const kept = !!(await page.$(`iframe[id="${desk.id}"]`)) &&
        (await desk.frame.$$eval("#strip li[data-slot]", (els) => els.length).catch(() => 0)) >= 3;
      const stream = await waitFor(() => desk.frame.evaluate(() => (window.__proofStream !== "open" ? window.__proofStream : null)),
        { timeoutMs: 30_000, what: "the open stream ended" }).catch(() => "open");
      const action = await call(desk.frame, "action", "layout.get", { posture: "desk" });
      const reopen = await call(desk.frame, "stream", "cards.refreshed");
      check(marker === "disconnected", name, "server_gone", "marked", "the canvas is marked disconnected", marker);
      check(kept, name, "server_gone", "layout_kept", "the last layout stays drawn", kept);
      check(stream !== "open", name, "server_gone", "stream_ended", "the open stream ends", stream);
      check(!action.ok, name, "server_gone", "action_fails_closed", "an action fails closed", action);
      check(!reopen.ok, name, "server_gone", "stream_fails_closed", "a new stream fails closed", reopen);
      record[name] = { marker, layout_kept: kept, stream, action: action.code, stream_open: reopen.code, events: events.slice(-40) };
    }
  } finally {
    for (const { browser } of tabs) await browser.close().catch(() => null);
  }
  return record;
}

// ---- the record --------------------------------------------------------------

const NOT_DRIVEN = [
  ["vault_list_on_the_page",
    "vault.list from the vault page: its consent class (staging) refuses a tincture frame, so the page lists through vault.status; vault.list is measured in-server through the gate (run.sh)"],
  ["hand_touch_gestures",
    "touch gestures in the hand viewport: the posture is asserted, the strip is not driven by touch"],
];

function table(record, server) {
  const rows = [];
  const cell = (b, f) => { try { return f(record[b]); } catch (_e) { return "—"; } };
  const line = (label, f) => rows.push(`| ${label} | ${BROWSERS.map((b) => cell(b, f)).join(" | ")} |`);
  rows.push(`| fact | ${BROWSERS.map((b) => `${b} ${record[b] ? record[b].version : ""}`).join(" | ")} |`);
  rows.push(`|---|${BROWSERS.map(() => "---|").join("")}`);
  line("desk strip", (r) => r.desk.strip.join(" "));
  line("hand strip", (r) => r.hand.strip.join(" "));
  line("desktop frozen under a full frame", (r) => `${r.full.covered.state}, inert ${r.full.covered.inert}`);
  line("covered desktop's call", (r) => r.full.refused.code);
  line("Tab from the capsule: landings on covered controls (on the assistant)", (r) => `${r.full.tab_on_covered} of ${r.full.tab_landings} (${r.full.tab_on_assistant})`);
  line("vault: Tab presses to the name field", (r) => r.vault.tabs);
  line("vault: frame requests carrying the value", (r) => `${r.vault.leaked} of ${r.vault.frame_requests}`);
  line("safe mode by chord: frames during", (r) => r.safe_mode_chord.frames_during);
  line("safe mode by stall: waited ms", (r) => r.safe_mode_stall.waited_ms);
  line("disconnect: action", (r) => `${r.disconnect.action.ok ? "answered" : "refused"} (${r.disconnect.action.code})`);
  line("disconnect: acting again", (r) => r.disconnect.acting_again);
  const measured = (m) => (m ? `${m.p50}/${m.p95}/${m.p99} (${m.n}, c${m.concurrency}, refused ${JSON.stringify(m.refused)})` : "not measured here");
  line("card.refresh ms p50/p95/p99 (n)", (r) => measured(r.measurements.card_refresh));
  line("vault.status endpoint ms p50/p95/p99 (n)", (r) => measured(r.measurements.vault_status_endpoint));
  line("server gone", (r) => server[r.__name] ? "held" : "—");
  const serverRows = Object.entries(server).map(([b, s]) =>
    `| server gone, ${b} | marker ${s.marker}, layout kept ${s.layout_kept}, stream ${s.stream}, action ${s.action}, new stream ${s.stream_open} |`);
  return [...rows, "", "| server gone | outcome |", "|---|---|", ...serverRows];
}

function inServer(outDir) {
  const lines = [];
  const found = {};
  for (const adapter of ["sqlite", "postgres"]) {
    const file = join(outDir, `server-measurements-${adapter}.json`);
    if (!existsSync(file)) {
      found[adapter] = null;
      lines.push(`| ${adapter} | not measured | ${existsSync(join(outDir, `server-measurements-${adapter}.skipped`)) ? readFileSync(join(outDir, `server-measurements-${adapter}.skipped`), "utf8").trim() : "no record"} |`);
      continue;
    }
    const m = JSON.parse(readFileSync(file, "utf8"));
    found[adapter] = m;
    for (const op of ["vault.list", "vault.status"]) {
      const s = m[op];
      lines.push(`| ${adapter} | ${op} | ${s.p50}/${s.p95}/${s.p99} ms p50/p95/p99, ${s.n} calls at concurrency ${m.concurrency}, ${s.refused} refused |`);
    }
  }
  return { found, lines: ["| adapter | operation | through the gate, in-server |", "|---|---|---|", ...lines] };
}

async function main() {
  const [server, segment, cookie, outDir, only] = process.argv.slice(2);
  const browsers = only ? only.split(",").filter((b) => BROWSERS.includes(b)) : BROWSERS;
  if (!server || !segment || !cookie || !outDir) {
    console.error("usage: node proof.mjs SERVER_URL SEGMENT COOKIE OUT_DIR");
    process.exit(64);
  }
  mkdirSync(outDir, { recursive: true });
  const proxy = await startProxy(server, { bodies: true });
  const base = `http://${SITE}:${new URL(server).port || 80}`;
  const record = {};
  // The measurements are taken once, in the first browser.
  for (const name of browsers) {
    record[name] = await run(name, base, proxy, segment, cookie, name === browsers[0]);
    record[name].__name = name;
  }
  let server_gone = {};
  try {
    server_gone = await serverGone(browsers, base, proxy, segment, cookie, outDir);
  } catch (error) {
    check(false, "all", "server_gone", "ran", "the server-gone section ran to its end", error.message);
  }
  proxy.close();

  const measured = inServer(outDir);
  writeFileSync(join(outDir, "canvas-proof.json"), JSON.stringify({
    record, server_gone, in_server: measured.found, not_driven: NOT_DRIVEN, failures,
  }, null, 2));
  const md = [
    ...table(record, server_gone), "",
    ...measured.lines, "",
    "| not driven | why |", "|---|---|",
    ...NOT_DRIVEN.map(([n, why]) => `| ${n} | ${why} |`),
  ];
  writeFileSync(join(outDir, "canvas-proof.md"), md.join("\n") + "\n");
  console.log(md.join("\n"));

  if (failures.length) {
    console.error(`FAIL: ${failures.length} assertion(s) did not hold`);
    for (const f of failures) console.error(`  ${f.browser}/${f.section}/${f.name}: ${f.what} — ${JSON.stringify(f.detail)}`);
    process.exit(1);
  }
  console.log("ok: every assertion held in every browser");
}

main().catch((error) => {
  console.error(`FAIL: ${error.stack || error}`);
  process.exit(1);
});
