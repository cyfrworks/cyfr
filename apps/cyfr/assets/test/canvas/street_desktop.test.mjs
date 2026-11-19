// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The street desktop (seed/components/tinctures/local/street): its page run here as the page runs it,
// in a context of its own with a stand-in for window.cyfr, a small reading of the HTML the page writes
// and a 2D context that draws nothing. What it opens, how it holds what its streams tell it, and what
// it offers on the board.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

const STREET = new URL("../../../../../seed/components/tinctures/local/street/", import.meta.url)
const PROTOCOLS = ["http/1.1", "h2", "h3", ""]

// A 2D context that accepts every call and every setting, and draws nothing.
function context2d() {
  const noop = () => {}
  return new Proxy({}, {get: (target, key) => (key in target ? target[key] : noop), set: (target, key, value) => ((target[key] = value), true)})
}

// An element read from the HTML the page writes: its attributes, data, classes, inline style and
// children, enough of the DOM for the page's queries, listeners and text.
const VOID = new Set(["input", "br", "img", "meta", "link"])
const unescape = (s) => s.replace(/&(amp|lt|gt|quot|nbsp);/g, (_, e) => ({amp: "&", lt: "<", gt: ">", quot: '"', nbsp: " "})[e])
class Element {
  constructor(tag) {
    Object.assign(this, {tagName: tag.toUpperCase(), children: [], parentElement: null, listeners: {}, attributes: {}, dataset: {}, classes: new Set()})
    Object.assign(this, {style: {setProperty() {}}, hidden: false, checked: false, disabled: false})
  }
  setAttribute(key, value) {
    value = String(value)
    this.attributes[key] = value
    if (key === "class") this.classes = new Set(value.split(/\s+/).filter(Boolean))
    else if (key === "style") for (const d of value.split(";")) d.includes(":") && (this.style[d.slice(0, d.indexOf(":")).trim()] = d.slice(d.indexOf(":") + 1).trim())
    else if (key.startsWith("data-")) this.dataset[key.slice(5).replace(/-(\w)/g, (_, c) => c.toUpperCase())] = value
    else if (["hidden", "checked", "disabled"].includes(key)) this[key] = true
  }
  getAttribute(key) {
    return this.attributes[key] ?? null
  }
  get id() {
    return this.attributes.id || ""
  }
  get className() {
    return [...this.classes].join(" ")
  }
  set className(value) {
    this.setAttribute("class", value)
  }
  get classList() {
    const c = this.classes
    return {add: (x) => c.add(x), remove: (x) => c.delete(x), contains: (x) => c.has(x), toggle: (x, on = !c.has(x)) => (on ? c.add(x) : c.delete(x), on)}
  }
  get textContent() {
    return this.children.map((c) => (typeof c === "string" ? c : c.textContent)).join("")
  }
  set textContent(value) {
    this.children = [String(value)]
  }
  set innerHTML(html) {
    this.children = []
    let at = this
    for (const m of html.matchAll(/<(\/?)([a-zA-Z0-9]+)((?:\s+[\w-]+(?:="[^"]*")?)*)\s*\/?>|([^<]+)/g)) {
      if (m[4] !== undefined) at.children.push(unescape(m[4]))
      else if (m[1]) at = at === this ? this : at.parentElement
      else {
        const el = new Element(m[2])
        for (const a of m[3].matchAll(/([\w-]+)(?:="([^"]*)")?/g)) el.setAttribute(a[1], unescape(a[2] ?? ""))
        at.appendChild(el)
        if (!VOID.has(m[2].toLowerCase())) at = el
      }
    }
  }
  appendChild(child) {
    child.parentElement = this
    this.children.push(child)
    return child
  }
  remove() {
    if (this.parentElement) this.parentElement.children = this.parentElement.children.filter((c) => c !== this)
  }
  addEventListener(type, handler) {
    ;(this.listeners[type] ||= []).push(handler)
  }
  dispatch(type, init = {}) {
    for (const handler of this.listeners[type] || []) handler({target: this, key: "", preventDefault() {}, stopPropagation() {}, ...init})
  }
  elements() {
    return this.children.filter((c) => typeof c !== "string").flatMap((c) => [c, ...c.elements()])
  }
  querySelectorAll(selector) {
    return this.elements().filter((e) => matches(e, selector))
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null
  }
  closest(selector) {
    for (let e = this; e; e = e.parentElement) if (matches(e, selector)) return e
    return null
  }
  getBoundingClientRect() {
    const n = (k) => parseFloat(this.style[k]) || 0
    return {left: n("left"), top: n("top"), right: n("left") + n("width"), bottom: n("top") + n("height"), width: n("width"), height: n("height")}
  }
  get offsetWidth() {
    return this.textContent.length * 8
  }
  get offsetHeight() {
    return 20
  }
  getContext() {
    return context2d()
  }
  setPointerCapture() {}
  focus() {}
}
// Selectors as the page writes them: tag, #id, .class, [attr] and [attr="value"], descendants, lists.
function compound(e, part) {
  const [, tag, rest] = /^([a-z0-9]*)(.*)$/i.exec(part)
  if (tag && e.tagName !== tag.toUpperCase()) return false
  for (const m of rest.matchAll(/([#.])([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]/g)) {
    if (m[1] === "#" && e.id !== m[2]) return false
    if (m[1] === "." && !e.classes.has(m[2])) return false
    if (m[3] && (e.getAttribute(m[3]) === null || (m[4] !== undefined && e.getAttribute(m[3]) !== m[4]))) return false
  }
  return true
}
function matches(e, selector) {
  return selector.split(",").some((one) => {
    const parts = one.trim().split(/\s+/)
    if (!compound(e, parts.pop())) return false
    let up = e.parentElement
    for (const part of parts.reverse()) {
      while (up && !compound(up, part)) up = up.parentElement
      if (!up) return false
      up = up.parentElement
    }
    return true
  })
}

// The page of `version` at `width` by `height` CSS pixels, the person's preferences `document`, the
// streams named in `refuse` refused at their first open with that class, the shell's `installed`
// apps. Its timers run at once, or at their own delays on the test's clock with `clock`. Answers
// the streams it opened (each a stand-in handle the test pushes events into), the presses and pages
// it asked for, its opens of apps, each waiting until the test answers it (`openings`), and a pump
// that runs the page's queued frames.
async function street({version = "0.2.0", width = 1024, height = 600, protocol = "http/1.1", document: prefs = {}, refuse = {}, installed = null, clock = false} = {}) {
  const dir = new URL(`${version}/`, STREET)
  const html = readFileSync(new URL("index.html", dir), "utf8")
  const body = new Element("body")
  body.innerHTML = html.slice(html.indexOf("<body>") + 6, html.indexOf("</body>")).replace(/<script[^>]*><\/script>/g, "")
  const doc = {hidden: false, documentElement: new Element("html"), body, querySelector: (s) => body.querySelector(s), createElement: (tag) => new Element(tag), addEventListener() {}}
  const frames = []
  const opened = []
  const presses = []
  const pages = []
  const openings = []
  const p = {opened, presses, pages, openings, answer: {outcome: "accepted"}}
  const cyfr = {
    desktop: {prefs: {document: prefs, revision: 1}, appearance: {mode: "light", locale: "en", time_zone: "UTC", safe_areas: {}}, person: {name: "Noor"}},
    on(event, handler) {
      if (event === "state") (p.state = handler)("live")
      if (event === "posture") handler(width < 768 ? "hand" : "desk")
      if (event === "installed" && installed) handler(installed)
      return () => {}
    },
    stream(name, subject, onEvent) {
      const s = {name: subject ? `feed:${subject}` : name, stream: name, state: "live", closed: false}
      let ended
      s.handle = {close: () => (s.closed = true), closed: new Promise((resolve) => (ended = resolve)), get state() { return s.state }}
      s.end = (state) => ((s.state = state), ended())
      s.push = (event, data = null, extra = {}) => onEvent({id: null, event, data, revision: null, at: null, ...extra})
      opened.push(s)
      const code = refuse[s.name]
      return code ? Promise.reject(Object.assign(new Error("refused"), {code})) : Promise.resolve(s.handle)
    },
    press(control, value) {
      presses.push([control, value])
      return typeof p.answer === "function" ? p.answer() : Promise.resolve(p.answer)
    },
    settings: (...args) => pages.push(args),
    prefs: async (document) => ({outcome: "saved", document}),
    ask() {},
    open: (ref) => new Promise((answer) => openings.push({ref, answer})),
    grant() {},
    ready() {},
  }
  const win = {
    cyfr,
    document: doc,
    console,
    innerWidth: width,
    innerHeight: height,
    performance: {now: () => Date.now(), getEntriesByType: () => [{nextHopProtocol: protocol}]},
    matchMedia: () => ({matches: false, addEventListener() {}}),
    getComputedStyle: () => ({getPropertyValue: () => ""}),
    CSS: {escape: (s) => String(s)},
    requestAnimationFrame: (f) => frames.push(f),
    cancelAnimationFrame() {},
    addEventListener() {},
    // The page's pauses run at once here, so what it opens again is seen without waiting.
    setTimeout: (f, ms) => {
      const t = setTimeout(f, clock ? ms : Math.min(ms, 5))
      t.unref()
      return t
    },
    clearTimeout,
  }
  win.window = win
  vm.createContext(win)
  vm.runInContext(readFileSync(new URL("app.js", dir), "utf8"), win, {filename: `street/${version}/app.js`})
  let ts = 1000
  p.pump = (n = 3) => {
    for (let i = 0; i < n; i++) {
      ts += 100
      for (const f of frames.splice(0)) f(ts)
    }
  }
  p.settle = async () => {
    for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve))
    p.pump()
  }
  p.stream = (name) => opened.filter((s) => s.name === name).at(-1)
  p.board = () => body.querySelector("#board")
  p.hits = () => body.querySelector("#labels").querySelectorAll(".hit")
  p.plain = () => doc.documentElement.classList.contains("plain")
  await p.settle()
  return p
}

const MINUTE = 60000
const at = (minutes) => new Date(Date.now() + minutes * MINUTE).toISOString()
// A time as the street tells it in UTC: "14:20", or "Wed 00:01" on another day.
const told = (iso) => `(\\S+ )?${iso.slice(11, 16)}`
let revision = 100
// A picture: each item marked refresh, then its snapshot.
function picture(s, items) {
  for (const data of items) s.push(s.stream, {...data, refresh: true}, {revision: ++revision})
  s.push("snapshot", null, {at: at(0)})
}
const change = (s, data) => s.push(s.stream, data, {revision: ++revision})

const hit = (p, start) => {
  const found = p.hits().find((h) => (h.getAttribute("aria-label") || "").startsWith(start))
  assert.ok(found, `no tap target "${start}" among ${p.hits().map((h) => h.getAttribute("aria-label")).join(" | ")}`)
  return found
}
const labelled = (p, start) => p.hits().some((h) => (h.getAttribute("aria-label") || "").startsWith(start))
const tap = (p, start) => (hit(p, start).dispatch("click"), p.pump())
const button = (p, label) => p.board().querySelectorAll("button").find((b) => (label instanceof RegExp ? label.test(b.textContent) : b.textContent === label))
const press = async (p, label) => {
  const b = button(p, label)
  assert.ok(b, `no "${label}" on the board: ${p.board().textContent}`)
  b.dispatch("click")
  await p.settle()
}

const weather = {binding: "bnd_w", feed: "weather", label: "weather", result: {place: "Lisbon", temp_c: 21, sky: "clear", wind_kmh: 14, next_hours: [21, 20, 19, 18]}, actions: [{name: "refresh", label: "Refresh"}]}
const vpn = {binding: "bnd_v", feed: "vpn", label: "vpn", result: {state: "connected", server: "lis-2", servers: ["lis-1", "lis-2", "ams-1"], down_mbps: 84}, actions: [{name: "disconnect", label: "Disconnect"}]}
const run = (id, kind, extra = {}) => ({kind, execution_id: id, parent_execution_id: null, reference: "formula:local.digest:0.4.0", component_type: "formula", duration_ms: 1200, started_at: at(-30), ended_at: kind === "started" ? null : at(-29), error: kind === "failed" ? {class: "timeout", cause: "timed_out"} : null, ...extra})
const waiting = (id, kind, destination, extra = {}) => ({kind, id, label: "Morning digest", since: at(-25), destination, outcome: null, ...extra})

describe("the street desktop 0.1.0", () => {
  test("it opens at most five streams with every part on", async () => {
    const p = await street({version: "0.1.0"})
    const names = p.opened.map((s) => s.name)
    assert.ok(names.length <= 5, `opened ${names.join(", ")}`)
    assert.equal(new Set(names).size, names.length)
  })
})

describe("the street desktop 0.2.0", () => {
  const MANIFEST = JSON.parse(readFileSync(new URL("0.2.0/cyfr-manifest.json", STREET), "utf8"))
  const DESK = MANIFEST.tincture.desktop
  const DECLARED = [...DESK.data, ...DESK.feeds.map((f) => `feed:${f}`)].sort()
  const PARTS = Object.keys(DESK.prefs.widgets)

  for (const protocol of PROTOCOLS) {
    for (const [parts, on] of [["every part on", true], ["every part off", false]]) {
      test(`every declared stream is opened exactly once at start, with ${parts} (${protocol || "unknown"})`, async () => {
        const p = await street({protocol, document: {widgets: Object.fromEntries(PARTS.map((w) => [w, {on}]))}})
        assert.deepEqual(p.opened.map((s) => s.name).sort(), DECLARED)
      })
    }
  }

  test("the manifest declares retry-run exactly", () => {
    assert.deepEqual(DESK.controls.find((c) => c.id === "retry-run"), {
      id: "retry-run",
      label: "Retry",
      operation: "execution.retry",
      args: {},
      pick: {stream: "runs.changes", field: "/execution_id", arg: "execution_id"},
    })
    assert.ok(DESK.data.includes("runs.changes"))
  })

  test("a failed root run offers Retry, which presses retry-run with its id and waits for the answer", async () => {
    const p = await street()
    picture(p.stream("runs.changes"), [run("ex-1", "failed")])
    p.pump()
    tap(p, "Runs at")
    let answer
    p.answer = () => new Promise((resolve) => (answer = resolve))
    await press(p, "Retry")
    assert.deepEqual(p.presses, [["retry-run", "ex-1"]])
    assert.ok(button(p, "Retrying…").disabled)
    answer({outcome: "accepted"})
    await p.settle()
    assert.match(p.board().textContent, /It runs again\./)
    assert.ok(!button(p, "Retry").disabled)
  })

  test("a failed_run item whose run is held offers Retry with that run's id, and none once the run leaves the picture", async () => {
    const p = await street()
    picture(p.stream("runs.changes"), [run("ex-1", "failed")])
    picture(p.stream("attention.changes"), [waiting("formula:local.digest:0.4.0", "failed_run", {kind: "page", page: "executions", ref: "ex-1"})])
    p.pump()
    tap(p, "Waiting on you: a failed run")
    await press(p, "Retry")
    assert.deepEqual(p.presses, [["retry-run", "ex-1"]])

    p.stream("runs.changes").push("resync")
    picture(p.stream("runs.changes"), [run("ex-2", "completed")])
    p.pump()
    assert.equal(button(p, "Retry"), undefined)
    assert.ok(button(p, "Open runs"))
  })

  test("each answer to Retry reads in the street's words", async () => {
    const words = {
      conflict: "This run cannot run again: only a run a schedule or a feed started runs again.",
      invalid_argument: "This run is no longer among the latest runs.",
      not_found: "This run is gone.",
      forbidden: "This run is not yours to run again.",
      unavailable: "CYFR cannot run it now: try again shortly.",
      rate_limited: "CYFR cannot run it now: try again shortly.",
      timeout: "CYFR cannot run it now: try again shortly.",
      uncertain: "No answer came: look at Runs before trying again.",
      internal: "It could not be run again.",
    }
    const p = await street()
    picture(p.stream("runs.changes"), [run("ex-1", "failed")])
    p.pump()
    tap(p, "Runs at")
    for (const [reason, sentence] of Object.entries(words)) {
      p.answer = {outcome: "refused", reason}
      await press(p, "Retry")
      assert.ok(p.board().textContent.includes(sentence), `${reason}: ${p.board().textContent}`)
    }
    p.answer = {outcome: "cancelled", reason: "too_soon"}
    await press(p, "Retry")
    assert.match(p.board().textContent, /Too soon after your last tap: tap Retry again in a moment\./)
    p.answer = {outcome: "cancelled"}
    await press(p, "Retry")
    assert.match(p.board().textContent, /Nothing ran: tap Retry again\./)
  })

  test("a completed run and a child run offer no Retry", async () => {
    const p = await street()
    picture(p.stream("runs.changes"), [run("ex-1", "completed", {started_at: at(-90)}), run("ex-2", "failed", {parent_execution_id: "ex-0", started_at: at(-20)})])
    p.pump()
    for (const lamp of p.hits().filter((h) => h.getAttribute("aria-label").startsWith("Runs at"))) {
      lamp.dispatch("click")
      p.pump()
      assert.equal(button(p, "Retry"), undefined, p.board().textContent)
      button(p, "Close").dispatch("click")
      p.pump()
    }
    assert.equal(p.hits().filter((h) => h.getAttribute("aria-label").startsWith("Runs at")).length, 2)
  })

  test("a resync followed by a picture without an item removes it", async () => {
    const p = await street()
    const threads = p.stream("threads.changes")
    const thread = (id, title) => ({kind: "shared", id, title, people: ["Noor", "Sam"], last_activity: at(-40), waits_on_you: false, unread: 0})
    picture(threads, [thread("th-1", "One"), thread("th-2", "Two")])
    p.pump()
    assert.ok(labelled(p, "Thread Two"))
    threads.push("resync")
    picture(threads, [thread("th-1", "One")])
    p.pump()
    assert.ok(labelled(p, "Thread One"))
    assert.ok(!labelled(p, "Thread Two"))
  })

  test("a lower revision after a higher one changes nothing", async () => {
    const p = await street()
    const threads = p.stream("threads.changes")
    const thread = (title) => ({kind: "own", id: "th-1", title, people: ["Noor"], last_activity: at(-40), waits_on_you: false, unread: null})
    picture(threads, [])
    threads.push("threads.changes", thread("Newer"), {revision: 9})
    threads.push("threads.changes", thread("Older"), {revision: 8})
    threads.push("threads.changes", thread("Again"), {revision: 9})
    p.pump()
    assert.ok(labelled(p, "Thread Newer"))
    assert.ok(!labelled(p, "Thread Older") && !labelled(p, "Thread Again"))
  })

  test("a live removal of a waiting item boards the tram, and one a picture drops does not", async () => {
    const p = await street()
    const attention = p.stream("attention.changes")
    picture(attention, [waiting("ap-1", "approval", {kind: "page", page: "aqua", ref: "th-1"}), waiting("ap-2", "approval", {kind: "page", page: "aqua", ref: "th-2"}, {label: "Trip"})])
    p.pump()
    const villagers = () => p.hits().map((h) => h.getAttribute("aria-label")).filter((l) => l.startsWith("Waiting on you"))
    change(attention, {kind: "removed", id: "ap-1", label: null, since: null, destination: null, outcome: "resolved"})
    p.pump()
    assert.equal(villagers().length, 2, "the settled one walks to the tram")
    attention.push("resync")
    picture(attention, [])
    p.pump()
    assert.deepEqual(villagers().map((l) => l.split(", ")[1]), ["Approve in Morning digest"], "the one the picture dropped is simply gone")
    assert.match(p.board().textContent, /Nothing waits on you/)
  })

  test("stale shows the tired picture, and the next snapshot clears it", async () => {
    const p = await street()
    const threads = p.stream("threads.changes")
    picture(threads, [{kind: "own", id: "th-1", title: "Tax notes", people: ["Noor"], last_activity: at(-40), waits_on_you: false, unread: null}])
    p.pump()
    const as = at(-12)
    threads.push("stale", null, {at: as})
    p.pump()
    assert.match(p.board().textContent, new RegExp(`thread houses as of ${told(as)}`))
    assert.ok(hit(p, "Thread Tax notes").querySelector(".plate").classes.has("dim"))
    threads.push("snapshot", null, {at: at(0)})
    p.pump()
    assert.doesNotMatch(p.board().textContent, /as of/)
    assert.ok(!hit(p, "Thread Tax notes").querySelector(".plate").classes.has("dim"))
  })

  test("unavailable keeps the picture and says when it tries again", async () => {
    const p = await street()
    const runs = p.stream("runs.changes")
    picture(runs, [run("ex-1", "completed")])
    const retry = at(1)
    runs.push("unavailable", {retry_at: retry})
    p.pump()
    assert.match(p.board().textContent, new RegExp(`run lamps trying again at ${told(retry)}`))
    assert.ok(labelled(p, "Runs at"))
  })

  test("denied ends the part and says so", async () => {
    const p = await street()
    const schedules = p.stream("schedules.changes")
    picture(schedules, [{kind: "changed", schedule_id: "sch-1", name: "Weather every 10 min", reference: "catalyst:local.weather", cron_expression: "*/10 * * * *", status: "active", next_run_at: at(10), last_run_at: at(-1), run_count: 3, error_count: 0}])
    p.pump()
    assert.ok(labelled(p, "Schedule Weather"))
    schedules.push("denied", {class: "forbidden", message: "not shown to a person", stage: "admission"})
    p.pump()
    assert.ok(!labelled(p, "Schedule Weather"))
    assert.match(p.board().textContent, /schedule stops no longer granted/)
    assert.doesNotMatch(p.board().textContent, /not shown to a person/)
  })

  test("a first open refused says not granted, one with no answer and one the endpoint ended are opened again", async () => {
    const p = await street({refuse: {"vault.changes": "forbidden", "system.changes": "unavailable"}})
    assert.match(p.board().textContent, /vault tower not granted/)
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.ok(p.opened.filter((s) => s.name === "system.changes").length >= 2)
    const files = p.stream("files.changes")
    files.end("ended")
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.equal(p.opened.filter((s) => s.name === "files.changes").length, 2)
  })

  test("an approval opens Aqua, a shared thread the chat and an own thread Aqua, and each page destination its page", async () => {
    const p = await street()
    picture(p.stream("runs.changes"), [])
    picture(p.stream("attention.changes"), [
      waiting("ap-1", "approval", {kind: "page", page: "aqua", ref: "th-1"}, {label: "Trip planning", since: at(-200)}),
      waiting("formula:local.digest", "failed_run", {kind: "page", page: "executions", ref: "ex-9"}, {since: at(-150)}),
      waiting("sch-1", "failed_schedule", {kind: "page", page: "schedules", ref: "sch-1"}, {label: "Backup", since: at(-100)}),
      waiting("of-1", "file_offer", {kind: "page", page: "files", ref: "of-1"}, {label: "budget.xlsx", since: at(-50)}),
    ])
    picture(p.stream("threads.changes"), [
      {kind: "shared", id: "th-2", title: "Family", people: ["Noor", "Sam", "Ana"], last_activity: at(-60), waits_on_you: false, unread: 2},
      {kind: "own", id: "th-3", title: "Tax notes", people: ["Noor"], last_activity: at(-130), waits_on_you: false, unread: null},
    ])
    p.pump()
    // The 0.2.0 desktop cannot change and wrote the name in capitals, so it is matched without regard to case.
    for (const [target, label, page] of [
      ["Waiting on you: an approval", /^Open Aqua$/i, ["aqua", "th-1"]],
      ["Waiting on you: a failed run", "Open runs", ["executions", "ex-9"]],
      ["Waiting on you: a failed schedule", "Open schedules", ["schedules", "sch-1"]],
      ["Waiting on you: a file offered", "Open files", ["files", "of-1"]],
      ["Thread Family", "Open the chat", ["chat", "th-2"]],
      ["Thread Tax notes", /^Open Aqua$/i, ["aqua", "th-3"]],
    ]) {
      tap(p, target)
      await press(p, label)
      assert.deepEqual(p.pages.at(-1), page, target)
      button(p, "Close").dispatch("click")
      p.pump()
    }
    assert.equal(button(p, "Retry"), undefined)
  })

  test("a waiting item opens its destination at its ref, and a thread house opens Aqua or the chat at its thread", async () => {
    const p = await street()
    picture(p.stream("runs.changes"), [])
    picture(p.stream("attention.changes"), [
      waiting("ap-1", "approval", {kind: "page", page: "aqua", ref: "th-1"}, {label: "Trip planning", since: at(-200)}),
      waiting("ap-2", "approval", {kind: "page", page: "aqua", ref: null}, {label: "Book club", since: at(-180)}),
      waiting("formula:local.digest", "failed_run", {kind: "page", page: "executions", ref: "ex-9"}, {since: at(-150)}),
    ])
    picture(p.stream("threads.changes"), [
      {kind: "shared", id: "th-2", title: "Family", people: ["Noor", "Sam", "Ana"], last_activity: at(-60), waits_on_you: false, unread: 0},
      {kind: "own", id: "th-3", title: "Tax notes", people: ["Noor"], last_activity: at(-130), waits_on_you: false, unread: null},
    ])
    p.pump()
    // The 0.2.0 desktop cannot change and wrote the name in capitals, so it is matched without regard to case.
    for (const [target, label] of [
      ["Waiting on you: an approval, Approve in Trip planning", /^Open Aqua$/i],
      ["Waiting on you: an approval, Approve in Book club", /^Open Aqua$/i],
      ["Waiting on you: a failed run", "Open runs"],
      ["Thread Family", "Open the chat"],
      ["Thread Tax notes", /^Open Aqua$/i],
    ]) {
      tap(p, target)
      await press(p, label)
      button(p, "Close").dispatch("click")
      p.pump()
    }
    assert.deepEqual(p.pages, [["aqua", "th-1"], ["aqua"], ["executions", "ex-9"], ["chat", "th-2"], ["aqua", "th-3"]])
  })

  // While frozen the SDK tells a stream nothing and its handle stands suspended; shown again, the SDK
  // opens each stream itself and the page hears resync, the fresh picture and its snapshot.
  test("a hidden-then-shown desktop shows its parts live again, with no denied in between", async () => {
    const p = await street()
    const attention = p.stream("attention.changes"), threads = p.stream("threads.changes"), runs = p.stream("runs.changes")
    const thread = (id, title) => ({kind: "shared", id, title, people: ["Noor", "Sam"], last_activity: at(-40), waits_on_you: false, unread: 0})
    picture(attention, [waiting("ap-1", "approval", {kind: "page", page: "aqua", ref: "th-1"}, {label: "Trip"}), waiting("ap-2", "approval", {kind: "page", page: "aqua", ref: "th-2"}, {label: "Book club"})])
    picture(threads, [thread("th-1", "One"), thread("th-2", "Two")])
    picture(runs, [run("ex-1", "started", {ended_at: null, error: null}), run("ex-2", "completed", {started_at: at(-90)})])
    p.pump()
    const opens = p.opened.length

    p.state("frozen")
    for (const s of [attention, threads, runs]) s.state = "suspended"
    await new Promise((resolve) => setTimeout(resolve, 30))
    p.pump()
    p.state("live")
    for (const s of [attention, threads, runs]) {
      s.state = "live"
      s.push("resync")
    }
    picture(attention, [waiting("ap-1", "approval", {kind: "page", page: "aqua", ref: "th-1"}, {label: "Trip planning"})])
    picture(threads, [thread("th-1", "One again")])
    picture(runs, [run("ex-1", "completed")])
    p.pump()

    const labels = p.hits().map((h) => h.getAttribute("aria-label"))
    assert.deepEqual(labels.filter((l) => l.startsWith("Waiting on you")).map((l) => l.split(", ")[1]), ["Approve in Trip planning"], "the dropped one does not board the tram")
    assert.deepEqual(labels.filter((l) => l.startsWith("Thread")).map((l) => l.split(",")[0]), ["Thread One again"])
    assert.deepEqual(labels.filter((l) => l.startsWith("Runs at")).map((l) => l.replace(/^Runs at (\S+ )?\d\d:\d\d /, "")), ["digest ok"])
    assert.match(p.board().textContent, /^1 thing waits on you/)
    assert.doesNotMatch(p.board().textContent, /granted|as of|trying again|could not be read/)
    assert.equal(p.opened.length, opens, "the page opened no stream again by itself")
  })

  test("the weather feed stands at the sun with its forecast, the VPN feed is the ferry, and their actions press the feed", async () => {
    const p = await street()
    picture(p.stream("feed:weather"), [{...weather, at: at(-5)}])
    picture(p.stream("feed:vpn"), [{...vpn, at: at(-1), result: {...vpn.result, since: at(-20)}}])
    p.pump()
    assert.ok(labelled(p, "VPN server lis-2, current"))
    tap(p, "Weather in Lisbon: 21°, clear")
    assert.match(p.board().textContent, /wind 14 km\/h · next hours 21° 20° 19° 18°/)
    await press(p, "Refresh")
    tap(p, "VPN connected to lis-2")
    assert.match(p.board().textContent, /VPN connected to lis-2.*down 84 Mb\/s/)
    await press(p, "Disconnect")
    assert.deepEqual(p.presses, [["bnd_w", "refresh"], ["bnd_v", "disconnect"]])
  })

  for (const [width, height] of [[390, 844], [1024, 600], [1440, 900]]) {
    test(`the whole street draws at ${width}x${height} without falling back`, async () => {
      const p = await street({width, height})
      picture(p.stream("runs.changes"), [run("ex-1", "failed"), run("ex-2", "started", {started_at: at(-3), reference: "catalyst:local.weather:1.1.0"})])
      picture(p.stream("attention.changes"), [waiting("ap-1", "approval", {kind: "page", page: "aqua", ref: "th-1"}), waiting("cf-1", "confirmation", {kind: "ref", page: null, ref: "cf-1"})])
      picture(p.stream("threads.changes"), [{kind: "shared", id: "th-2", title: "Family", people: ["Noor", "Sam", "Ana"], last_activity: at(-60), waits_on_you: true, unread: 2}])
      picture(p.stream("activity.changes"), [{kind: "started", id: "job-1", member: "explorer", asked_by: "Noor", title: "Compare ferry times", since: at(-8), status: "running"}])
      picture(p.stream("schedules.changes"), [{kind: "changed", schedule_id: "sch-1", name: "Backup", reference: "catalyst:local.backup", cron_expression: "0 2 * * *", status: "paused", next_run_at: null, last_run_at: at(-2000), run_count: 9, error_count: 0}])
      picture(p.stream("files.changes"), [{kind: "file", id: "data/notes.pdf", name: "notes.pdf", type: "application/pdf", changed_at: at(-1500), from: null}])
      picture(p.stream("components.changes"), [{kind: "installed", ref: "catalyst:local.weather", type: "catalyst", name: "weather", icon: null, version: "1.1.0", update_available: true, grant_current: null}])
      picture(p.stream("vault.changes"), [{kind: "changed", name: "Dropbox", type: "account", status: "needs_reauthorisation"}])
      picture(p.stream("system.changes"), [{kind: "changed", health: "low_storage", storage_used: 95e9, storage_cap: 100e9, model_connected: false, crew_ready: 1, crew_total: 2, version: "0.6.0", update_available: false}])
      picture(p.stream("feed:weather"), [{...weather, at: at(-5)}])
      picture(p.stream("feed:vpn"), [{...vpn, at: at(-1)}])
      p.pump(5)
      assert.ok(!p.plain())
      assert.ok(labelled(p, "CYFR 0.6.0, low on storage") && labelled(p, "The vault, 1 to see") && labelled(p, "VPN connected to lis-2"))
      assert.equal(labelled(p, "catalyst weather, update available"), width >= 768)
    })
  }

  test("a shared thread of one person reads 1 person, and of three, 3 people", async () => {
    const p = await street()
    picture(p.stream("threads.changes"), [
      {kind: "shared", id: "th-1", title: "Alone", people: ["Noor"], last_activity: at(-60), waits_on_you: false, unread: 0},
      {kind: "shared", id: "th-3", title: "Family", people: ["Noor", "Sam", "Ana"], last_activity: at(-50), waits_on_you: false, unread: 0},
    ])
    p.pump(5)
    const text = (start) => hit(p, start).textContent
    assert.match(text("Thread Alone"), /1 person$/)
    assert.match(text("Thread Family"), /3 people$/)
    tap(p, "Thread Alone")
    assert.match(p.board().textContent, /shared, 1 person/)
  })

  test("the files, the offer's sender and how CYFR stands reach the street", async () => {
    const p = await street()
    picture(p.stream("files.changes"), [
      {kind: "file", id: "data/cover.png", name: "cover.png", type: "image/png", changed_at: at(-45), from: null},
      {kind: "offer", id: "of-1", name: "budget.xlsx", type: "application/vnd.ms-excel", changed_at: at(-50), from: "Sam"},
    ])
    picture(p.stream("attention.changes"), [waiting("of-1", "file_offer", {kind: "page", page: "files", ref: "of-1"}, {label: "budget.xlsx"})])
    picture(p.stream("system.changes"), [{kind: "changed", health: "ok", storage_used: 38e9, storage_cap: 100e9, model_connected: true, crew_ready: 2, crew_total: 2, version: "0.6.0", update_available: true}])
    p.pump()
    assert.ok(labelled(p, "File cover.png, changed"))
    assert.ok(labelled(p, "Waiting on you: a file offered, Sam offers budget.xlsx"))
    assert.match(hit(p, "CYFR 0.6.0, healthy").textContent, /healthy · 38\/100 GB · update/)
    tap(p, "CYFR 0.6.0")
    assert.match(p.board().textContent, /CYFR 0\.6\.0 · healthy/)
    assert.match(p.board().textContent, /storage 38 GB of 100 GB · model connected · crew 2 of 2 ready · update available/)
  })
})

// A daily thread's title: the ISO date `n` days from today, in UTC, the stand-in's person's zone.
const day = (n) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10)

describe("the street desktop 0.3.4", () => {
  // An answer belongs to the board that asked: never another board, even
  // the same app's opened again, and never the scrub view.
  test("an open's answer shows only on the board that asked it, while it is the board shown and not scrubbed", async (t) => {
    // The page's timers on the test's clock, which does not move here: every
    // answer is inside its four seconds.
    t.mock.timers.enable({apis: ["setTimeout", "Date"], now: Date.now()})
    const MAPS = {ref: "tincture:local.maps", name: "Maps", icon: null, open: false}
    const p = await street({version: "0.3.4", installed: [MAPS], clock: true})
    const said = () => p.board().querySelector(".said")?.textContent ?? null
    const tram = () => p.hits().find((h) => (h.getAttribute("aria-label") || "").startsWith("Now,"))

    // Asked, then the board closed and the same app's board opened again.
    tap(p, "App Maps")
    await press(p, "Open Maps")
    tap(p, "App Maps")
    tap(p, "App Maps")
    assert.ok(button(p, "Open Maps"))
    p.openings.at(-1).answer({outcome: "refused", reason: "uncertain"})
    await p.settle()
    assert.equal(said(), null)
    // Its own tap's answer still shows.
    await press(p, "Open Maps")
    p.openings.at(-1).answer({outcome: "cancelled"})
    await p.settle()
    assert.equal(said(), "Not opened: tap again")

    // Words shown, then the day scrubbed: not on the scrub view, nor back on
    // the board after it.
    tram().dispatch("keydown", {key: "ArrowLeft"})
    await p.settle()
    assert.match(p.board().textContent, /^At /)
    assert.equal(said(), null)
    tram().dispatch("keydown", {key: "Escape"})
    await p.settle()
    assert.ok(button(p, "Open Maps"))
    assert.equal(said(), null)

    // Asked, then the day scrubbed before the answer: not on the scrub view,
    // nor on the board after it.
    await press(p, "Open Maps")
    tram().dispatch("keydown", {key: "ArrowLeft"})
    await p.settle()
    p.openings.at(-1).answer({outcome: "refused", reason: "not_found"})
    await p.settle()
    assert.doesNotMatch(p.board().textContent, /It is no longer installed/)
    tram().dispatch("keydown", {key: "Escape"})
    await p.settle()
    assert.ok(button(p, "Open Maps"))
    assert.equal(said(), null)
    assert.equal(p.openings.length, 3)
  })

  test("a tap on Open on an app's board that opens nothing says why on the board, the shipped canvas's words, for four seconds from the last answer; an open says nothing", async (t) => {
    t.mock.timers.enable({apis: ["setTimeout", "Date"], now: Date.now()})
    const MAPS = {ref: "tincture:local.maps", name: "Maps", icon: null, open: false}
    const p = await street({version: "0.3.4", installed: [MAPS], clock: true})
    tap(p, "App Maps")
    const said = () => p.board().querySelector(".said")?.textContent ?? null
    const answer = async (a) => {
      const before = said()
      await press(p, "Open Maps")
      // The tap claims nothing before the shell answers.
      assert.equal(said(), before)
      p.openings.at(-1).answer(a)
      await p.settle()
      return said()
    }
    assert.equal(await answer({outcome: "cancelled", reason: "too_soon"}), "Tap again in a moment")
    // Opened inside the four seconds: the earlier tap's words go at once.
    assert.equal(await answer({outcome: "opened"}), null)
    assert.equal(await answer({outcome: "refused", reason: "not_found"}), "It is no longer installed")
    assert.equal(await answer({outcome: "opened"}), null)
    // An open never answered may have opened: it says only that no answer came.
    assert.equal(await answer({outcome: "refused", reason: "uncertain"}), "No answer yet")
    assert.doesNotMatch(p.board().textContent, /Not opened/)
    assert.equal(await answer({outcome: "cancelled"}), "Not opened: tap again")
    assert.equal(await answer({outcome: "refused", reason: "invalid_argument"}), "Not opened: tap again")
    assert.deepEqual(p.openings.map((o) => o.ref), Array(7).fill(MAPS.ref))

    // The same answer again three seconds on restarts the four seconds.
    t.mock.timers.tick(3000)
    assert.equal(await answer({outcome: "cancelled"}), "Not opened: tap again")
    t.mock.timers.tick(3999)
    await p.settle()
    assert.equal(said(), "Not opened: tap again")
    t.mock.timers.tick(1)
    await p.settle()
    assert.equal(said(), null)
  })

  const sentence = (name) => `No reading from the ${name} feed yet. To bind one, ask Aqua for a feed named ${name}.`

  test("the sky and the ferry with no reading name their feed and say to ask Aqua for one, until a reading comes", async () => {
    const p = await street({version: "0.3.4"})
    assert.ok(labelled(p, sentence("weather")), p.hits().map((h) => h.getAttribute("aria-label")).join(" | "))
    assert.ok(labelled(p, sentence("vpn")))
    // Their plates say it where the sun and the ferry stand, and their board when tapped.
    const plates = p.hits().map((h) => h.textContent).join(" | ")
    assert.match(plates, /No reading from the weather feed yet ?To bind one, ask Aqua for a feed named weather/)
    assert.match(plates, /No reading from the vpn feed yet ?To bind one, ask Aqua for a feed named vpn/)
    tap(p, sentence("vpn"))
    assert.match(p.board().textContent, /No reading from the vpn feed yet/)
    assert.match(p.board().textContent, /To bind one, ask Aqua for a feed named vpn/)

    picture(p.stream("feed:weather"), [weather])
    p.pump()
    assert.ok(labelled(p, "Weather in Lisbon"))
    assert.ok(!labelled(p, sentence("weather")))
    assert.ok(labelled(p, sentence("vpn")))
  })

  test("on a phone the board's cards say the same of a feed with no reading", async () => {
    const p = await street({version: "0.3.4", width: 390, height: 844})
    assert.equal(p.plain(), false)
    assert.match(p.board().textContent, /No reading from the weather feed yet ?To bind one, ask Aqua for a feed named weather/)
    assert.match(p.board().textContent, /No reading from the vpn feed yet ?To bind one, ask Aqua for a feed named vpn/)
  })

  test("today's daily thread is a house read Today that opens Aqua, an earlier day's stands nowhere, a workspace thread opens Aqua and a shared one the chat", async () => {
    const p = await street({version: "0.3.4"})
    picture(p.stream("runs.changes"), [])
    picture(p.stream("threads.changes"), [
      {kind: "daily", id: "th-today", title: day(0), people: ["Noor"], last_activity: at(-30), waits_on_you: false, unread: 2},
      {kind: "daily", id: "th-before", title: day(-1), people: ["Noor"], last_activity: at(-40), waits_on_you: false, unread: 1},
      {kind: "workspace", id: "th-work", title: "Ferry tracker", people: ["Noor"], last_activity: at(-50), waits_on_you: false, unread: 0},
      {kind: "shared", id: "th-family", title: "Family", people: ["Noor", "Sam", "Ana"], last_activity: at(-60), waits_on_you: false, unread: 0},
    ])
    p.pump(5)
    const houses = p.hits().map((h) => h.getAttribute("aria-label") || "").filter((l) => l.startsWith("Thread "))
    assert.deepEqual(houses.map((l) => l.split(", ").slice(0, 2).join(", ")).sort(), ["Thread Family, shared", "Thread Ferry tracker, with Aqua", "Thread Today, with Aqua"])
    assert.match(hit(p, "Thread Today").textContent, /2 unread · with Aqua$/)
    for (const [target, label, page] of [
      ["Thread Today", "Open Aqua", ["aqua", "th-today"]],
      ["Thread Ferry tracker", "Open Aqua", ["aqua", "th-work"]],
      ["Thread Family", "Open the chat", ["chat", "th-family"]],
    ]) {
      tap(p, target)
      await press(p, label)
      assert.deepEqual(p.pages.at(-1), page, target)
      button(p, "Close").dispatch("click")
      p.pump()
    }
    tap(p, "Thread Today")
    assert.match(p.board().textContent, /with Aqua/)
    assert.doesNotMatch(p.board().textContent, /shared|1 person/)
  })

  test("the newest daily thread's house reads Yesterday a day back, and its date further back", async () => {
    const date = new Intl.DateTimeFormat("en", {timeZone: "UTC", day: "numeric", month: "short"}).format(Date.parse(day(-3)))
    for (const [n, words] of [[-1, "Yesterday"], [-3, date]]) {
      const p = await street({version: "0.3.4"})
      picture(p.stream("threads.changes"), [{kind: "daily", id: "th-1", title: day(n), people: ["Noor"], last_activity: at(-30), waits_on_you: false, unread: 0}])
      p.pump(5)
      assert.ok(labelled(p, `Thread ${words}, with Aqua`), p.hits().map((h) => h.getAttribute("aria-label")).join(" | "))
    }
  })

  test("an approval in a daily thread is named by its day as the thread is, and one in a crew thread by its title as given", async () => {
    const date = new Intl.DateTimeFormat("en", {timeZone: "UTC", day: "numeric", month: "short"}).format(Date.parse(day(-3)))
    const named = ["Today", "Yesterday", date, "builder"]
    const p = await street({version: "0.3.4"})
    picture(p.stream("attention.changes"), [[day(0), day(0), "th-0"], [day(-1), day(-1), "th-1"], [day(-3), day(-3), "th-3"], ["builder", null, "th-crew"]].map(([label, d, ref], i) =>
      waiting(`ap-${i}`, "approval", {kind: "page", page: "aqua", ref}, {label, day: d, since: at(i * 10 - 60)})))
    p.pump(5)
    const asks = p.hits().map((h) => h.getAttribute("aria-label") || "").filter((l) => l.startsWith("Waiting on you: an approval"))
    assert.deepEqual(asks.map((l) => l.split(", ")[1]).sort(), named.map((n) => `Approve in ${n}`).sort())
    tap(p, "Waiting on you: an approval, Approve in Yesterday")
    assert.match(p.board().textContent, /Approve in Yesterday/)
    assert.ok([0, -1, -3].every((n) => !(asks.join(" ") + p.board().textContent).includes(day(n))), asks.join(" | "))
  })

  test("a crew member named like a date keeps its name: only an item's day is worded as a day", async () => {
    const p = await street({version: "0.3.4"})
    picture(p.stream("attention.changes"), [waiting("ap-crew", "approval", {kind: "page", page: "aqua", ref: "th-crew"}, {label: "2026-11-15", day: null, since: at(-30)})])
    p.pump(5)
    const asks = p.hits().map((h) => h.getAttribute("aria-label") || "").filter((l) => l.startsWith("Waiting on you: an approval"))
    assert.deepEqual(asks.map((l) => l.split(", ")[1]), ["Approve in 2026-11-15"])
    tap(p, "Waiting on you: an approval, Approve in 2026-11-15")
    assert.match(p.board().textContent, /Approve in 2026-11-15/)
  })

  // Two daily threads in each list, a workspace thread in each and a shared one, whose
  // `archived` is null.
  const THREADS = [
    {kind: "daily", id: "th-today", title: day(0), people: ["Noor"], last_activity: at(-30), waits_on_you: false, unread: 2, archived: false},
    {kind: "daily", id: "th-two", title: day(-2), people: ["Noor"], last_activity: at(-35), waits_on_you: false, unread: 0, archived: false},
    {kind: "daily", id: "th-one", title: day(-1), people: ["Noor"], last_activity: at(-40), waits_on_you: false, unread: 1, archived: true},
    {kind: "daily", id: "th-three", title: day(-3), people: ["Noor"], last_activity: at(-45), waits_on_you: false, unread: 0, archived: true},
    {kind: "workspace", id: "th-work", title: "Ferry tracker", people: ["Noor"], last_activity: at(-50), waits_on_you: false, unread: 0, archived: false},
    {kind: "workspace", id: "th-old", title: "Old tracker", people: ["Noor"], last_activity: at(-55), waits_on_you: true, unread: 0, archived: true},
    {kind: "shared", id: "th-family", title: "Family", people: ["Noor", "Sam", "Ana"], last_activity: at(-60), waits_on_you: false, unread: 0, archived: null},
  ]
  const dateOf = (n) => new Intl.DateTimeFormat("en", {timeZone: "UTC", day: "numeric", month: "short"}).format(Date.parse(day(n)))
  // The houses that stand, by title, in sorted order.
  const houses = (p) => p.hits().map((h) => h.getAttribute("aria-label") || "").filter((l) => l.startsWith("Thread ")).map((l) => l.slice(7).split(", ")[0]).sort()
  const flip = (p) => (button(p, "Archived").dispatch("click"), p.pump())
  async function built(threads) {
    const p = await street({version: "0.3.4"})
    picture(p.stream("runs.changes"), [])
    picture(p.stream("threads.changes"), threads)
    p.pump(5)
    return p
  }

  test("the houses of the threads not archived stand; the board's Archived key stands only the archived ones, each drawn and opened as before, the newest daily thread of each list standing for its days", async () => {
    const p = await built(THREADS)
    assert.equal(button(p, "Archived").getAttribute("aria-pressed"), "false")
    assert.deepEqual(houses(p), ["Family", "Ferry tracker", "Today"])

    flip(p)
    assert.equal(button(p, "Archived").getAttribute("aria-pressed"), "true")
    assert.deepEqual(houses(p), ["Old tracker", "Yesterday"])
    assert.ok(labelled(p, "Thread Yesterday, with Aqua, last active "), p.hits().map((h) => h.getAttribute("aria-label")).join(" | "))
    assert.match(hit(p, "Thread Yesterday").getAttribute("aria-label"), /, 1 unread$/)
    assert.match(hit(p, "Thread Old tracker").getAttribute("aria-label"), /, waits on you$/)
    tap(p, "Thread Old tracker")
    await press(p, "Open Aqua")
    assert.deepEqual(p.pages, [["aqua", "th-old"]])
    button(p, "Close").dispatch("click")
    p.pump()

    flip(p)
    assert.equal(button(p, "Archived").getAttribute("aria-pressed"), "false")
    assert.deepEqual(houses(p), ["Family", "Ferry tracker", "Today"])
  })

  test("a live item that archives a thread moves it to the archived list, one that takes it out moves it back, and a removed item leaves both lists", async () => {
    const p = await built(THREADS)
    const line = p.stream("threads.changes")
    const work = THREADS.find((t) => t.id === "th-work")
    change(line, {...work, archived: true})
    p.pump(5)
    assert.deepEqual(houses(p), ["Family", "Today"])
    flip(p)
    assert.deepEqual(houses(p), ["Ferry tracker", "Old tracker", "Yesterday"])

    change(line, {...work, last_activity: at(-10), archived: false})
    p.pump(5)
    assert.deepEqual(houses(p), ["Old tracker", "Yesterday"])
    flip(p)
    assert.deepEqual(houses(p), ["Family", "Ferry tracker", "Today"])

    change(line, {kind: "removed", id: "th-work"})
    change(line, {kind: "removed", id: "th-old"})
    p.pump(5)
    assert.deepEqual(houses(p), ["Family", "Today"])
    flip(p)
    assert.deepEqual(houses(p), ["Yesterday"])
  })

  test("a daily thread archived live hands its days to the newest one left in the list, and the archived list's newest is the one that stands", async () => {
    const p = await built(THREADS)
    change(p.stream("threads.changes"), {...THREADS.find((t) => t.id === "th-today"), archived: true})
    p.pump(5)
    assert.deepEqual(houses(p), [dateOf(-2), "Family", "Ferry tracker"].sort())
    flip(p)
    assert.deepEqual(houses(p), ["Old tracker", "Today"])
  })

  test("the Archived key stands on the board only while the thread houses are on", async () => {
    const p = await street({version: "0.3.4", document: {widgets: {houses: {on: false}}}})
    assert.ok(button(p, "Arrange"))
    assert.equal(button(p, "Archived"), undefined)
  })
})
