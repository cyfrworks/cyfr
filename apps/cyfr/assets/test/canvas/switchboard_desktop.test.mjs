// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The switchboard desktop (seed/components/tinctures/local/switchboard): its
// pages, run here as the page runs them, in a context of their own with a
// stand-in for window.cyfr. For 0.1.0, how many stream requests its model
// has in flight when the person's preferences turn parts off while their
// streams are opening; for 0.2.0, what the board opens, holds and shows, and
// what each tap asks of the shell.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

const MODEL = readFileSync(
  new URL("../../../../../seed/components/tinctures/local/switchboard/0.1.0/model.js", import.meta.url),
  "utf8"
)

// Preferences that turn off the parts four of the first five streams serve,
// and turn on two parts that wait in the spares.
const MOVED = {
  threads: {on: false},
  apps: {on: false},
  components: {on: false},
  runs: {on: false},
  vault: {on: true},
  crew: {on: true}
}

// The model started on a stand-in SDK whose opens answer after `answerMs`
// (never, when null), then handed MOVED; answers what it sent and the most
// requests that were ever in flight at once.
async function moved(answerMs) {
  const handlers = {}
  const sent = []
  let inFlight = 0
  let most = 0
  const sdk = {
    desktop: null,
    on(event, handler) {
      handlers[event] = handler
    },
    stream(name, subject) {
      sent.push(subject ? `feed:${subject}` : name)
      inFlight += 1
      most = Math.max(most, inFlight)
      if (answerMs === null) return new Promise(() => {})
      return new Promise((resolve) =>
        setTimeout(() => {
          resolve({
            close() {
              inFlight -= 1
            },
            closed: new Promise(() => {})
          })
        }, answerMs)
      )
    }
  }

  const page = {Map, Set, Object, Array, String, Number, Math, Promise, setTimeout, clearTimeout, requestAnimationFrame() {}}
  page.window = page
  vm.createContext(page)
  vm.runInContext(MODEL, page)
  page.SB.start(sdk, () => {})
  handlers.desktop({prefs: {document: {widgets: MOVED, desktop: {}}, revision: 1}})
  await new Promise((resolve) => setTimeout(resolve, 300))
  return {sent, inFlight, most, SB: page.SB}
}

test("a part turned off while its stream is opening keeps the requests in flight within five", async () => {
  const {sent, inFlight, most} = await moved(null)
  assert.equal(most, 5, `requests in flight at once: ${sent.join(", ")}`)
  assert.equal(inFlight, 5)
  assert.deepEqual(sent, ["attention.changes", "threads.changes", "components.changes", "runs.changes", "schedules.changes"])
})

test("once the stopped opens have their answers, the parts turned on open theirs, within five", async () => {
  const {inFlight, most, SB} = await moved(50)
  assert.equal(most, 5)
  assert.equal(inFlight, 4)
  for (const key of ["attention.changes", "schedules.changes", "vault.changes", "activity.changes"]) {
    assert.ok(SB.reading(key), key)
  }
  for (const key of ["threads.changes", "components.changes", "runs.changes"]) {
    assert.ok(!SB.reading(key), key)
  }
})

// The canvas wire's vectors: `stream_events["threads.changes"]`, a shared
// thread with its unread count and an own thread with none.
const WIRE = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/tincture_wire.json", import.meta.url), "utf8")
)

test("folds the wire's thread events, a shared thread's unread count and an own thread's null, whole", async () => {
  const events = WIRE.stream_events["threads.changes"].map(({event}) => event)
  assert.equal(events.length, 2)

  const handlers = {}
  const delivered = {}
  const sdk = {
    desktop: null,
    on(event, handler) {
      handlers[event] = handler
    },
    stream(name, _subject, onEvent) {
      delivered[name] = onEvent
      return Promise.resolve({close() {}, closed: new Promise(() => {})})
    }
  }

  const page = {Map, Set, Object, Array, String, Number, Math, Promise, setTimeout, clearTimeout, requestAnimationFrame() {}}
  page.window = page
  vm.createContext(page)
  vm.runInContext(MODEL, page)
  page.SB.start(sdk, () => {})
  handlers.desktop({prefs: {document: {widgets: {}, desktop: {}}, revision: 1}})
  await new Promise((resolve) => setTimeout(resolve, 50))

  assert.ok(delivered["threads.changes"], "the model reads threads.changes")
  for (const data of events) delivered["threads.changes"]({data})

  assert.deepEqual(JSON.parse(JSON.stringify(page.SB.threads())), events)
})

// ---------------------------------------------------------------------------
// 0.2.0: the board itself, its four page scripts run in order (cords.js, the
// canvas ropes, stands in as a stub), on a document as small as they need.
// ---------------------------------------------------------------------------

const V2 = new URL("../../../../../seed/components/tinctures/local/switchboard/0.2.0/", import.meta.url)
const MANIFEST = JSON.parse(readFileSync(new URL("cyfr-manifest.json", V2), "utf8"))
const DECLARED = [...MANIFEST.tincture.desktop.data, ...MANIFEST.tincture.desktop.feeds.map((name) => `feed:${name}`)]
const WIDGETS = Object.keys(MANIFEST.tincture.desktop.prefs.widgets)

const decode = (s) => s.replace(/&(amp|lt|gt|quot|#39);/g, (_, e) => ({amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'"})[e])

// An element: its attributes, children and text; parsed from the markup the
// board writes; queried with the selectors the board uses; and tapped with a
// click that bubbles.
class Node {
  constructor(tag) {
    this.tagName = tag.toUpperCase()
    this.attrs = new Map()
    this.kids = []
    this.parentNode = null
    this.listeners = {}
    this.style = {setProperty() {}, removeProperty() {}}
  }
  get children() {
    return this.kids.filter((k) => k instanceof Node)
  }
  get firstChild() {
    return this.kids[0] ?? null
  }
  get textContent() {
    return this.kids.map((k) => (typeof k === "string" ? k : k.textContent)).join("")
  }
  set textContent(value) {
    this.kids = value === "" ? [] : [String(value)]
  }
  set innerHTML(markup) {
    this.kids = []
    parse(markup, this)
  }
  getAttribute(name) {
    return this.attrs.get(name) ?? null
  }
  setAttribute(name, value) {
    this.attrs.set(name, String(value))
  }
  removeAttribute(name) {
    this.attrs.delete(name)
  }
  get className() {
    return this.getAttribute("class") ?? ""
  }
  set className(value) {
    this.setAttribute("class", value)
  }
  get classList() {
    const list = () => this.className.split(/\s+/).filter(Boolean)
    const add = (...c) => (this.className = [...new Set([...list(), ...c])].join(" "))
    const remove = (...c) => (this.className = list().filter((x) => !c.includes(x)).join(" "))
    return {add, remove, contains: (c) => list().includes(c), toggle: (c, on = !list().includes(c)) => ((on ? add(c) : remove(c)), on)}
  }
  get dataset() {
    const name = (k) => "data-" + String(k).replace(/[A-Z]/g, (c) => "-" + c.toLowerCase())
    return new Proxy({}, {
      get: (_, k) => this.attrs.get(name(k)),
      set: (_, k, v) => (this.setAttribute(name(k), v), true),
      deleteProperty: (_, k) => (this.attrs.delete(name(k)), true)
    })
  }
  get hidden() {
    return this.attrs.has("hidden")
  }
  set hidden(on) {
    on ? this.setAttribute("hidden", "") : this.removeAttribute("hidden")
  }
  get disabled() {
    return this.attrs.has("disabled")
  }
  set disabled(on) {
    on ? this.setAttribute("disabled", "") : this.removeAttribute("disabled")
  }
  insertBefore(child, ref) {
    if (child.parentNode) child.remove()
    const at = ref === null ? -1 : this.kids.indexOf(ref)
    at < 0 ? this.kids.push(child) : this.kids.splice(at, 0, child)
    child.parentNode = this
    return child
  }
  appendChild(child) {
    return this.insertBefore(child, null)
  }
  prepend(child) {
    return this.insertBefore(child, this.kids[0] ?? null)
  }
  remove() {
    if (this.parentNode) this.parentNode.kids = this.parentNode.kids.filter((k) => k !== this)
    this.parentNode = null
  }
  replaceChildren(...kids) {
    this.kids = []
    for (const k of kids) this.appendChild(k)
  }
  addEventListener(type, fn) {
    ;(this.listeners[type] ||= []).push(fn)
  }
  querySelectorAll(selector) {
    const out = []
    const walk = (el) => {
      for (const k of el.children) {
        if (matches(k, selector, this)) out.push(k)
        walk(k)
      }
    }
    walk(this)
    return out
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] ?? null
  }
  matches(selector) {
    return matches(this, selector, null)
  }
  closest(selector) {
    for (let el = this; el; el = el.parentNode) if (el.matches(selector)) return el
    return null
  }
  scrollIntoView() {}
  click() {
    const event = {target: this, stopPropagation() {}, preventDefault() {}}
    for (let el = this; el; el = el.parentNode) for (const fn of el.listeners.click || []) fn(event)
  }
}

function parse(markup, parent) {
  const stack = [parent]
  const tags = /<\/([a-z0-9]+)\s*>|<([a-z0-9]+)((?:\s+[^\s=>/]+(?:="[^"]*"|='[^']*')?)*)\s*(\/?)>|([^<]+)/gi
  for (const m of markup.matchAll(tags)) {
    const top = stack[stack.length - 1]
    if (m[1]) stack.pop()
    else if (m[2]) {
      const el = new Node(m[2])
      for (const a of m[3].matchAll(/([^\s=]+)(?:="([^"]*)"|='([^']*)')?/g)) el.attrs.set(a[1], decode(a[2] ?? a[3] ?? ""))
      top.appendChild(el)
      if (!m[4]) stack.push(el)
    } else top.kids.push(decode(m[5]))
  }
}

// A selector as groups of compounds, each with the combinator before it.
function groups(selector) {
  const out = [[]]
  let text = ""
  let comb = " "
  let depth = 0
  const push = () => {
    if (!text) return
    const c = {tag: (/^[a-z][a-z0-9]*/i.exec(text) || [""])[0].toUpperCase(), classes: [], attrs: [], scope: false}
    for (const m of text.matchAll(/\.([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]|(:scope)/g)) {
      if (m[1]) c.classes.push(m[1])
      else if (m[2]) c.attrs.push([m[2], m[3]])
      else c.scope = true
    }
    out[out.length - 1].push({comb, c})
    text = ""
    comb = " "
  }
  for (const ch of selector) {
    if (ch === "[") depth++
    if (ch === "]") depth--
    if (depth === 0 && ch === ",") (push(), out.push([]))
    else if (depth === 0 && ch === ">") (push(), (comb = ">"))
    else if (depth === 0 && /\s/.test(ch)) push()
    else text += ch
  }
  push()
  return out
}

function matches(el, selector, scope) {
  const one = (node, c) =>
    node instanceof Node &&
    (!c.tag || node.tagName === c.tag) &&
    c.classes.every((x) => node.classList.contains(x)) &&
    c.attrs.every(([k, v]) => node.attrs.has(k) && (v === undefined || node.attrs.get(k) === v)) &&
    (!c.scope || node === scope)
  const at = (node, parts, i) => {
    if (!one(node, parts[i].c)) return false
    if (i === 0) return true
    if (parts[i].comb === ">") return at(node.parentNode, parts, i - 1)
    for (let up = node.parentNode; up; up = up.parentNode) if (at(up, parts, i - 1)) return true
    return false
  }
  return groups(selector).some((parts) => at(el, parts, parts.length - 1))
}

// A cord that goes wherever it is told, drawing nothing; `dead` says how it
// went: drawn back in, or gone at once.
const rope = () => ({hold: false, dead: false, patch() {}, retract() { this.dead = "retracted" }, kill() { this.dead = "killed" }})

// The board at 1024 by 600 with the person's preferences `prefs`, its
// document served over `protocol`. The stand-in SDK records each stream the
// page asks for and each one it opens (refusing the ones `refuse` names with
// that class, or with what its function answers), and each call the page
// makes of the shell; `press` answers a control's press. `tell` sends the
// page a value of the shell's (`state`, …); `ropes` are the cords it lifted.
function board({prefs = {}, protocol = "http/1.1", refuse = {}, press = async () => ({outcome: "accepted"}), version = V2} = {}) {
  const html = new Node("html")
  const body = html.appendChild(new Node("body"))
  const ids = Object.fromEntries(["console", "cords", "plain"].map((id) => [id, body.appendChild(new Node("div"))]))
  const asked = []
  const opened = []
  const shell = {settings: [], ask: [], open: [], press: []}
  const handlers = {}
  const ropes = []
  const cyfr = {
    desktop: {prefs: {document: prefs, revision: 1}, appearance: {mode: "light", locale: "en-GB", time_zone: "UTC"}, person: {name: "Noor"}},
    on(event, fn) {
      ;(handlers[event] ||= []).push(fn)
    },
    stream(name, subject, onEvent) {
      const key = subject ? `feed:${subject}` : name
      asked.push(key)
      const code = typeof refuse[key] === "function" ? refuse[key]() : refuse[key]
      if (code) return Promise.reject(Object.assign(new Error("refused"), {code}))
      const open = {key, onEvent, state: "live"}
      open.handle = {close() {}, closed: new Promise((resolve) => (open.end = resolve)), get state() { return open.state }}
      opened.push(open)
      return Promise.resolve(open.handle)
    },
    press: (id, value) => (shell.press.push([id, value]), press(id, value)),
    settings: (page) => shell.settings.push(page),
    ask: (widget) => shell.ask.push(widget),
    open: (ref) => shell.open.push(ref),
    prefs: async () => ({outcome: "saved"}),
    grant() {},
    ready() {}
  }
  const frames = []
  const win = {
    cyfr,
    Cords: {pick: () => ropes[ropes.push(rope()) - 1], wire: rope, fit() {}, wake() {}, freeze() {}, draw() {}},
    document: {documentElement: html, hidden: false, getElementById: (id) => ids[id] ?? null, createElement: (tag) => new Node(tag), addEventListener() {}},
    innerWidth: 1024,
    innerHeight: 600,
    CSS: {escape: String},
    performance: {now: () => Date.now(), getEntriesByType: () => [{nextHopProtocol: protocol}]},
    matchMedia: () => ({matches: false}),
    requestAnimationFrame: (fn) => frames.push(fn),
    setTimeout: (fn, ms) => setTimeout(fn, ms).unref(),
    clearTimeout,
    setInterval: () => 0,
    clearInterval() {},
    addEventListener() {},
    console
  }
  win.window = win
  vm.createContext(win)
  for (const file of ["model.js", "plain.js", "board.js", "main.js"]) {
    vm.runInContext(readFileSync(new URL(file, version), "utf8"), win, {filename: file})
  }
  const pump = () => {
    for (let i = 0; i < 4; i++) for (const fn of frames.splice(0)) fn(0)
  }
  const $ = (selector) => ids.console.querySelector(selector)
  const $$ = (selector) => ids.console.querySelectorAll(selector)
  const tell = (event, value) => {
    for (const fn of handlers[event] || []) fn(value)
    pump()
  }
  return {asked, opened, ropes, shell, tell, pump, $, $$, readout: () => $(".readout-text").textContent}
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve))
}

// One event of the stream `key`, as the SDK hands it to the page's handler.
function hear(b, key, event) {
  const open = b.opened.filter((o) => o.key === key).at(-1)
  assert.ok(open, `${key} was never opened`)
  open.onEvent({id: null, data: null, revision: null, at: null, ...event})
  b.pump()
}
const change = (b, key, data) =>
  hear(b, key, {event: key.startsWith("feed:") ? "feed.results" : key, data, revision: data.revision ?? null, at: data.at ?? null})
// A picture of `items`, whole as of now: after a `resync` when `again`.
function picture(b, key, items, again = false) {
  if (again) hear(b, key, {event: "resync"})
  for (const item of items) change(b, key, {revision: 1, ...item, refresh: true})
  hear(b, key, {event: "snapshot", at: new Date().toISOString()})
}

// A started board, the first picture of each stream it opened handed: empty
// unless named.
async function started(options = {}, pictures = {}) {
  const b = board(options)
  await settle()
  for (const key of DECLARED) if (b.opened.some((o) => o.key === key)) picture(b, key, pictures[key] || [])
  return b
}

// A time today in UTC, the board's time zone here, at `hm`.
const today = (hm) => `${new Date().toISOString().slice(0, 10)}T${hm}:00Z`
const ago = (minutes) => new Date(Date.now() - minutes * 60000).toISOString()
const lines = (b, group) => b.$$(`.cells[data-group="${group}"] .line`).map((el) => el.querySelector(".dymo").textContent)
const line = (b, group, name) => b.$$(`.cells[data-group="${group}"] .line`).find((el) => el.querySelector(".dymo").textContent === name)
// Lifts a line's cord and patches it to the position jack `dest`.
function patch(b, el, dest) {
  assert.ok(el, "no such line")
  el.click()
  b.pump()
  b.$(`.pos[data-dest="${dest}"]`).click()
  b.pump()
}

const RUN = (id, kind, extra = {}) => ({
  kind,
  execution_id: id,
  parent_execution_id: null,
  reference: "formula:local.digest:0.4.0",
  component_type: "formula",
  duration_ms: 30000,
  started_at: ago(30),
  ...(kind === "started" ? {} : {ended_at: ago(29)}),
  ...(kind === "failed" ? {error: {class: "timeout", cause: "timed_out"}} : {}),
  ...extra
})

describe("the switchboard desktop 0.2.0", () => {
  test("its manifest declares Retry exactly, picked from the runs it reads", () => {
    const retry = MANIFEST.tincture.desktop.controls.find((c) => c.id === "retry-run")
    assert.deepEqual(retry, {
      id: "retry-run",
      label: "Retry",
      operation: "execution.retry",
      args: {},
      pick: {stream: "runs.changes", field: "/execution_id", arg: "execution_id"}
    })
    assert.ok(MANIFEST.tincture.desktop.data.includes("runs.changes"))
  })

  for (const protocol of ["http/1.1", "h2", "h3", ""]) {
    for (const [what, on] of [["every part on", true], ["every part off", false]]) {
      test(`every declared stream opens exactly once at start, with ${what} (${protocol || "unknown"})`, async () => {
        const prefs = {widgets: Object.fromEntries(WIDGETS.map((w) => [w, {on}]))}
        const b = board({prefs, protocol})
        await settle()
        b.pump()
        assert.deepEqual(b.opened.map((o) => o.key).sort(), [...DECLARED].sort())
      })
    }
  }

  test("a failed root run offers Retry, and a completed run and a child run offer none", async () => {
    const b = await started({}, {
      "runs.changes": [
        RUN("ex_failed", "failed", {started_at: today("09:00")}),
        RUN("ex_ok", "completed"),
        RUN("ex_child", "failed", {parent_execution_id: "ex_failed"})
      ]
    })
    const keys = b.$$(".paper [data-retry]")
    assert.deepEqual(keys.map((k) => k.getAttribute("data-retry")), ["ex_failed"])
    assert.equal(keys[0].textContent, "Retry")
    // A run's ticket carries its start in the person's own time.
    assert.equal(b.$('.tk[data-run="ex_failed"] .tk-t').textContent, "09:00")
  })

  test("a tap on Retry presses retry-run with the run's execution id, once, waiting until the answer", async () => {
    let answer
    const b = await started({press: () => new Promise((resolve) => (answer = resolve))}, {"runs.changes": [RUN("ex_failed", "failed")]})
    b.$('[data-retry="ex_failed"]').click()
    b.$('[data-retry="ex_failed"]').click()
    assert.deepEqual(b.shell.press, [["retry-run", "ex_failed"]])
    assert.ok(b.$('[data-retry="ex_failed"]').disabled)
    assert.equal(b.$('[data-retry="ex_failed"]').textContent, "Retrying")
    answer({outcome: "accepted"})
    await settle()
    assert.equal(b.readout(), "digest · running again")
    assert.ok(!b.$('[data-retry="ex_failed"]').disabled)
  })

  for (const [answer, words] of [
    [{outcome: "refused", reason: "conflict"}, "this run cannot be run again"],
    [{outcome: "refused", reason: "invalid_argument"}, "no longer among the latest runs"],
    [{outcome: "refused", reason: "not_found"}, "the run is gone"],
    [{outcome: "refused", reason: "forbidden"}, "not yours to run"],
    [{outcome: "refused", reason: "unavailable"}, "CYFR cannot run it now: try again shortly"],
    [{outcome: "refused", reason: "rate_limited"}, "CYFR cannot run it now: try again shortly"],
    [{outcome: "refused", reason: "timeout"}, "CYFR cannot run it now: try again shortly"],
    [{outcome: "refused", reason: "uncertain"}, "no answer came: look at Runs before trying again"],
    [{outcome: "refused", reason: "internal"}, "it could not be run again"],
    [{outcome: "cancelled", reason: "too_soon"}, "too soon after the last tap: tap again in a moment"],
    [{outcome: "cancelled"}, "nothing ran"]
  ]) {
    test(`Retry answered ${answer.outcome} ${answer.reason || ""} says "${words}"`, async () => {
      const b = await started({press: async () => answer}, {"runs.changes": [RUN("ex_failed", "failed")]})
      b.$('[data-retry="ex_failed"]').click()
      await settle()
      assert.equal(b.readout(), `digest · ${words}`)
    })
  }

  test("a failed-run call whose run is held offers its ticket's Retry; one whose run is gone offers none", async () => {
    const digest = {kind: "installed", ref: "formula:local.digest", type: "formula", name: "digest", version: "0.4.0"}
    const call = (ref) => ({kind: "failed_run", id: "formula:local.digest:0.4.0", label: "formula:local.digest:0.4.0", since: ago(29), destination: {kind: "page", page: "executions", ref}})
    // The call's run is older than the six tickets the paper once printed.
    const newer = Array.from({length: 8}, (_, i) => RUN(`ex_ok_${i}`, "completed", {started_at: ago(i + 1)}))
    const b = await started({}, {
      "components.changes": [digest],
      "runs.changes": [...newer, RUN("ex_digest", "failed")],
      "attention.changes": [call("ex_digest")]
    })
    const key = b.$('[data-retry="ex_digest"]')
    assert.ok(key, "the call's run offers Retry on its ticket")
    line(b, "components", "digest").click()
    b.pump()
    assert.match(b.readout(), /or Retry its ticket$/)
    assert.ok(key.classList.contains("beckon"))
    key.click()
    assert.deepEqual(b.shell.press, [["retry-run", "ex_digest"]])

    const gone = await started({}, {
      "components.changes": [digest],
      "runs.changes": newer,
      "attention.changes": [call("ex_gone")]
    })
    assert.equal(gone.$('[data-retry="ex_gone"]'), null)
    line(gone, "components", "digest").click()
    gone.pump()
    assert.doesNotMatch(gone.readout(), /Retry/)
  })

  test("an approval patched through opens AQUA's panel, and a shared thread the chat", async () => {
    const b = await started({}, {
      "threads.changes": [
        {kind: "own", id: "th_trip", title: "Trip planning", people: ["Noor"], last_activity: ago(60), waits_on_you: true, unread: null},
        {kind: "shared", id: "sth_fam", title: "Family", people: ["Ada", "Bob"], last_activity: ago(10), waits_on_you: false, unread: 2}
      ],
      "attention.changes": [{kind: "approval", id: "ap_1", label: "Trip planning", since: ago(60), destination: {kind: "page", page: "aqua", ref: "th_trip"}}]
    })
    line(b, "threads", "Trip planning").click()
    b.pump()
    assert.equal(b.$('.pos[data-dest="aqua"]').getAttribute("data-target"), "primary")
    b.$('.pos[data-dest="aqua"]').click()
    assert.deepEqual(b.shell.settings, ["aqua"])
    assert.deepEqual(b.shell.ask, [])

    // A shared thread shows its unread count, and opens the chat.
    assert.equal(line(b, "threads", "Family").querySelector(".meta-a").textContent, "2 unread")
    patch(b, line(b, "threads", "Family"), "chat")
    assert.deepEqual(b.shell.settings, ["aqua", "chat"])
  })

  test("a call whose destination is a page opens that page; a confirmation opens none", async () => {
    const page = (id, kind, label, dest) => ({kind, id, label, since: ago(5), destination: {kind: "page", page: dest, ref: id}})
    const b = await started({}, {
      "attention.changes": [
        page("off_1", "file_offer", "budget.xlsx", "files"),
        page("sch_1", "failed_schedule", "Morning digest", "schedules"),
        page("catalyst:local.backup:1.0.0", "failed_run", "backup", "executions"),
        page("th_gone", "approval", "Old thread", "aqua"),
        {kind: "confirmation", id: "cf_1", label: "vault.delete", since: ago(1), destination: {kind: "ref", page: null, ref: "cf_1"}}
      ]
    })
    for (const [name, dest] of [["budget.xlsx", "settings"], ["Morning digest", "settings"], ["backup", "settings"], ["Old thread", "aqua"]]) {
      patch(b, line(b, "calls", name), dest)
    }
    assert.deepEqual(b.shell.settings, ["files", "schedules", "executions", "aqua"])

    line(b, "calls", "vault.delete").click()
    b.pump()
    assert.equal(b.$$('.pos[data-target="primary"]').length, 0)
    assert.match(b.readout(), /CYFR asks you this itself/)
  })

  test("a shared thread of one person reads 1 person, and of three, 3 people", async () => {
    const thread = (id, title, people) => ({kind: "shared", id, title, people, last_activity: ago(5), waits_on_you: false, unread: 0})
    const b = await started({}, {"threads.changes": [thread("a", "Alone", ["Ada"]), thread("b", "Family", ["Ada", "Bob", "Cy"])]})
    const meta = (name) => line(b, "threads", name).getAttribute("aria-label")
    assert.match(meta("Alone"), /\b1 person\b/)
    assert.match(meta("Family"), /\b3 people\b/)
  })

  test("a resync and a picture without an item remove it, with no Cleared", async () => {
    const thread = (id, title) => ({kind: "shared", id, title, people: ["Ada"], last_activity: ago(5), waits_on_you: false, unread: 0})
    const b = await started({}, {"threads.changes": [thread("a", "Alpha"), thread("b", "Beta")]})
    assert.deepEqual(lines(b, "threads").sort(), ["Alpha", "Beta"])
    picture(b, "threads.changes", [thread("a", "Alpha")], true)
    assert.deepEqual(lines(b, "threads"), ["Alpha"])
  })

  test("a call a picture drops pulls its cord without Cleared; one the stream removes says Cleared", async () => {
    const call = {kind: "file_offer", id: "off_1", label: "budget.xlsx", since: ago(5), destination: {kind: "page", page: "files", ref: "off_1"}}
    const b = await started({}, {"attention.changes": [call]})
    patch(b, line(b, "calls", "budget.xlsx"), "settings")
    picture(b, "attention.changes", [], true)
    assert.doesNotMatch(b.readout(), /Cleared/)

    const live = await started({}, {"attention.changes": [call]})
    patch(live, line(live, "calls", "budget.xlsx"), "settings")
    change(live, "attention.changes", {kind: "removed", id: "off_1", outcome: "resolved", revision: 5})
    assert.match(live.readout(), /^Cleared · budget\.xlsx/)
  })

  test("a lower revision after a higher one changes nothing, and a removed item stays gone", async () => {
    const b = await started()
    const thread = (title, revision) => ({kind: "own", id: "a", title, people: [], last_activity: ago(1), waits_on_you: false, unread: null, revision})
    change(b, "threads.changes", thread("New", 10))
    change(b, "threads.changes", thread("Old", 5))
    change(b, "threads.changes", thread("Old", 10))
    assert.deepEqual(lines(b, "threads"), ["New"])
    change(b, "threads.changes", {kind: "removed", id: "a", revision: 20})
    change(b, "threads.changes", thread("Old", 15))
    assert.deepEqual(lines(b, "threads"), [])
  })

  test("stale dims the part and says as of when; the next snapshot clears it", async () => {
    const at = today("14:20")
    const b = await started({}, {"schedules.changes": [{kind: "changed", schedule_id: "s1", name: "Digest", status: "active", run_count: 3, error_count: 0}]})
    hear(b, "schedules.changes", {event: "stale", at})
    assert.equal(b.$('[data-part="schedules"]').getAttribute("data-state"), "stale")
    assert.equal(b.$(".schedules .mod-sub").textContent, "as of 14:20")
    assert.equal(b.$$(".seq .sch").length, 1)
    hear(b, "schedules.changes", {event: "snapshot", at})
    assert.equal(b.$('[data-part="schedules"]').getAttribute("data-state"), "live")
    assert.equal(b.$(".schedules .mod-sub").textContent, "1 running")
  })

  test("unavailable keeps the picture and says when it is tried again", async () => {
    const retryAt = today("23:59")
    const b = await started({}, {"runs.changes": [RUN("ex_ok", "completed")]})
    hear(b, "runs.changes", {event: "unavailable", data: {retry_at: retryAt}})
    assert.equal(b.$(".runs .mod-sub").textContent, "trying again at 23:59")
    assert.equal(b.$$(".paper .tk").length, 1)
    hear(b, "runs.changes", {event: "resync"})
    hear(b, "runs.changes", {event: "snapshot", at: new Date().toISOString()})
    assert.equal(b.$(".runs .mod-sub").textContent, "none yet")
  })

  test("denied ends the part and says it is no longer granted", async () => {
    const b = await started({}, {
      "vault.changes": [{kind: "changed", name: "OpenAI key", type: "api_key", status: "fine"}],
      "threads.changes": [{kind: "own", id: "a", title: "Alpha", people: [], last_activity: ago(1), waits_on_you: false, unread: null}]
    })
    assert.equal(b.$$(".vault-annun .win").length, 1)
    hear(b, "vault.changes", {event: "denied", data: {class: "forbidden", message: "not covered", stage: "grant"}})
    assert.equal(b.$$(".vault-annun .win").length, 0)
    assert.equal(b.$(".vault .mod-sub").textContent, "no longer granted")
    assert.equal(b.$('[data-part="vault"]').getAttribute("data-state"), "ended")

    hear(b, "threads.changes", {event: "denied", data: {class: "forbidden", message: "not covered", stage: "grant"}})
    assert.deepEqual(lines(b, "threads"), [])
    assert.equal(b.$('[data-part="threads"] .strip-note').textContent, "no longer granted")
  })

  test("a stream refused at its first open says not granted, or that it could not be read", async () => {
    const b = await started({refuse: {"vault.changes": "forbidden", "system.changes": "internal"}})
    assert.equal(b.$(".vault .mod-sub").textContent, "not granted")
    assert.equal(b.$(".crew .mod-sub").textContent, "could not be read")
  })

  test("a first open with no answer is opened again after a pause, and so is a stream the endpoint ended", async () => {
    let first = true
    const b = await started({refuse: {"files.changes": () => (first ? ((first = false), "unavailable") : null)}})
    assert.match(b.$(".files .mod-sub").textContent, /^trying again at /)
    const runs = b.opened.find((o) => o.key === "runs.changes")
    runs.state = "ended"
    runs.end()
    await new Promise((resolve) => setTimeout(resolve, 2100))
    await settle()
    assert.deepEqual(b.asked.filter((k) => k === "files.changes" || k === "runs.changes").sort(), ["files.changes", "files.changes", "runs.changes", "runs.changes"])
    picture(b, "files.changes", [])
    assert.equal(b.$(".files .mod-sub").textContent, "")
  })

  test("a hidden-then-shown desktop shows its parts live again, with no denied in between", async () => {
    const offer = (id, label) => ({kind: "file_offer", id, label, since: ago(5), destination: {kind: "page", page: "files", ref: id}})
    const thread = (id, title) => ({kind: "shared", id, title, people: ["Ada"], last_activity: ago(5), waits_on_you: false, unread: 0})
    const b = await started({}, {
      "attention.changes": [offer("off_1", "budget.xlsx"), offer("off_2", "cover.png")],
      "threads.changes": [thread("a", "Alpha"), thread("b", "Beta")],
      "runs.changes": [RUN("ex_1", "started"), RUN("ex_2", "completed")]
    })
    // The call the fresh picture will drop has its cord in.
    patch(b, line(b, "calls", "cover.png"), "settings")
    const cord = b.ropes.at(-1)
    const asked = b.asked.length

    // Hidden: the shell freezes the canvas and its streams hear nothing.
    b.tell("state", "frozen")
    for (const open of b.opened) open.state = "suspended"
    await new Promise((resolve) => setTimeout(resolve, 50))
    await settle()

    // Shown: the SDK opens each stream again itself, and each hears a fresh picture.
    b.tell("state", "live")
    for (const open of b.opened) open.state = "live"
    await settle()
    picture(b, "attention.changes", [offer("off_1", "budget.xlsx")], true)
    picture(b, "threads.changes", [thread("a", "Alpha renamed")], true)
    picture(b, "runs.changes", [RUN("ex_1", "completed")], true)

    assert.deepEqual(lines(b, "calls"), ["budget.xlsx"])
    assert.deepEqual(lines(b, "threads"), ["Alpha renamed"])
    assert.deepEqual(b.$$(".paper .tk").map((t) => [t.getAttribute("data-run"), t.querySelector(".tk-d").textContent]), [["ex_1", "ok 30.0 s"]])
    for (const part of b.$$("[data-part]")) assert.equal(part.getAttribute("data-state"), "live", part.getAttribute("data-part"))
    assert.deepEqual(b.$$(".strip-note").map((n) => n.textContent), ["", "", "", ""])
    for (const sub of b.$$(".mod-sub")) assert.doesNotMatch(sub.textContent, /granted|could not be read|trying again|as of/)
    assert.equal(b.asked.length, asked, "the page opened no stream again by itself")
    assert.equal(cord.dead, "killed")
    assert.doesNotMatch(b.readout(), /Cleared/)
  })

  test("the files and system items reach the parts that show them", async () => {
    const b = await started({prefs: {widgets: {files: {on: true}}}}, {
      "files.changes": [
        {kind: "offer", id: "off_1", name: "budget.xlsx", from: "Sam", type: null, changed_at: null},
        {kind: "file", id: "data/cover.png", name: "cover.png", type: "image/png", changed_at: today("13:02"), from: null}
      ],
      "system.changes": [{kind: "changed", health: "ok", storage_used: 38e9, storage_cap: 100e9, model_connected: true, crew_ready: 2, crew_total: 2, version: "0.6.0", update_available: true}],
      "activity.changes": [{kind: "started", id: "job_1", member: "explorer", asked_by: "Noor", title: "Compare ferry times", since: ago(8), status: "running"}]
    })
    assert.ok(!b.$('[data-part="files"]').hidden)
    const files = b.$$(".file-list li").map((li) => li.textContent)
    assert.deepEqual(files, ["budget.xlsxfrom Sam", "imagecover.png13:02"])
    assert.deepEqual(b.$$(".sys-annun .win").map((w) => w.getAttribute("aria-label")), [
      "Health: Healthy. Open settings",
      "Model: Connected. Open settings",
      "Crew: 2 of 2 ready. Open activities",
      "CYFR 0.6.0: Update ready. Open settings"
    ])
    assert.equal(b.$(".storage .st-v").textContent, "38 of 100 GB")
    assert.equal(b.$(".jobs .job-t").textContent, "Compare ferry times")
    assert.equal(b.readout(), "0 calling · 1 busy · healthy")
    b.$('.sys-annun .win[data-sys="settings"]').click()
    assert.deepEqual(b.shell.settings, ["settings"])
  })

  test("the VPN plate lights the trunk in service and presses the feed's own actions, picking none", async () => {
    const b = await started({}, {
      "feed:vpn": [{binding: "b_vpn", feed: "vpn", label: "vpn", at: ago(1), result: {state: "connected", server: "lis-2", servers: ["lis-1", "lis-2"], down_mbps: 84}, actions: [{name: "disconnect", label: "Disconnect"}]}]
    })
    assert.deepEqual(b.$$(".vpn .trunk").map((t) => [t.getAttribute("data-server"), t.getAttribute("data-lamp"), t.tagName]), [
      ["lis-1", "off", "SPAN"],
      ["lis-2", "green", "SPAN"]
    ])
    assert.equal(b.$(".vpn .edgewise").getAttribute("aria-label"), "84 Mbps down")
    b.$('.vpn [data-feedkey="disconnect"]').click()
    assert.deepEqual(b.shell.press, [["b_vpn", "disconnect"]])
  })
})
