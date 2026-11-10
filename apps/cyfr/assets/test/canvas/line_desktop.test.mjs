// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The shipped line desktop (seed/components/tinctures/local/line): its page
// run as the browser runs it, in a context of its own, against a stand-in
// for window.cyfr and the few parts of the document it touches.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

const VERSION = new URL("../../../../../seed/components/tinctures/local/line/0.1.0/", import.meta.url)
const source = readFileSync(new URL("app.js", VERSION), "utf8")

// The browser keeps six connections to one host over plain HTTP, and each
// stream the page has asked for holds one until it answers and is closed.
const MAX_OPEN = 5

const settle = () => new Promise((resolve) => setImmediate(resolve))

// The page at 1024 pixels wide (the carried screen), with a stand-in SDK
// whose stream opens wait until the test answers them.
function page() {
  const opens = []
  const handlers = {}
  const element = () => ({
    innerHTML: "",
    dataset: {},
    style: {setProperty() {}},
    classList: {add() {}, remove() {}, toggle() {}},
    getBoundingClientRect: () => ({left: 0, top: 0, right: 1024, bottom: 600, width: 1024, height: 600})
  })
  const parts = {"#near": element(), "#far": element(), "#frame": element()}
  const cyfr = {
    desktop: {prefs: {document: {}, revision: 0}, appearance: {mode: "light"}, person: {name: "Noor"}},
    on(event, handler) {
      handlers[event] = handler
    },
    stream(name, subject) {
      return new Promise((resolve, reject) => {
        const open = {name, subject, closed: false}
        open.answer = () =>
          resolve({
            closed: new Promise((ended) => (open.end = ended)),
            close() {
              open.closed = true
              open.end()
            }
          })
        open.refuse = (error) => reject(error)
        opens.push(open)
      })
    },
    ready() {},
    prefs: () => new Promise(() => {}),
    press: () => new Promise(() => {})
  }
  const context = {
    cyfr,
    innerWidth: 1024,
    innerHeight: 600,
    document: {
      documentElement: element(),
      activeElement: null,
      querySelector: (selector) => parts[selector] || null,
      querySelectorAll: () => [],
      addEventListener() {}
    },
    addEventListener() {},
    matchMedia: () => ({matches: true}),
    requestAnimationFrame: (fn) => setImmediate(fn),
    setTimeout: (fn) => setImmediate(fn),
    clearTimeout() {},
    setInterval: () => 0,
    clearInterval() {},
    CSS: {escape: (s) => s}
  }
  context.window = context
  vm.runInNewContext(source, context)
  const held = () => opens.filter((o) => !o.closed).length
  const asked = (name, subject = null) => opens.filter((o) => o.name === name && o.subject === subject)
  return {opens, handlers, held, asked}
}

test("pending_stream_replacement_stays_within_five", async () => {
  const {opens, handlers, held, asked} = page()
  for (let i = 0; i < 20; i++) await settle()

  // The carried screen's widgets read five streams; none of them answers.
  assert.deepEqual(opens.map((o) => o.subject ?? o.name).sort(), [
    "activity.changes",
    "attention.changes",
    "runs.changes",
    "schedules.changes",
    "weather"
  ])

  // The person turns Weather off and Threads on while every open still
  // waits: the weather's request cannot be called back, so Threads waits
  // for its connection.
  handlers.desktop({
    prefs: {
      document: {widgets: {weather: {on: true, carried: false}, threads: {on: true, carried: true}}},
      revision: 1
    }
  })
  for (let i = 0; i < 20; i++) await settle()
  assert.equal(held(), MAX_OPEN)
  assert.equal(asked("threads.changes").length, 0)

  // The weather's open answers: the page closes it at once, and only then
  // asks for Threads.
  const [weather] = asked("feed.results", "weather")
  weather.answer()
  for (let i = 0; i < 20; i++) await settle()
  assert.equal(weather.closed, true)
  assert.equal(asked("threads.changes").length, 1)
  assert.equal(held(), MAX_OPEN)
})

// 0.2.0: every declared stream open at once on the frame's one connection,
// each held by the delivery contract, and Retry on a failed run.
const NEXT = new URL("../../../../../seed/components/tinctures/local/line/0.2.0/", import.meta.url)
const MANIFEST = JSON.parse(readFileSync(new URL("cyfr-manifest.json", NEXT), "utf8"))
const DECLARED = [
  ...MANIFEST.tincture.desktop.data,
  ...MANIFEST.tincture.desktop.feeds.map((name) => `feed:${name}`)
].sort()
const WIDGET_IDS = Object.keys(MANIFEST.tincture.desktop.prefs.widgets)

// A time today, in UTC, the time zone the stand-in's person reads in.
const today = (h, m) => {
  const d = new Date()
  d.setUTCHours(h, m, 0, 0)
  return d.toISOString()
}
const unescape = (s) =>
  s.replace(/&(amp|lt|gt|quot|#39);/g, (_, e) => ({amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'"})[e])

// The page at `width` pixels, served over `protocol`, with the person's
// stored `prefs`; `refuse` refuses a stream's first open by its name. Every
// open answers at once; timers wait until the test runs them.
function desk({width = 1024, protocol = "h2", prefs = {}, refuse = {}, version = NEXT} = {}) {
  const listeners = {}
  const timers = []
  const opens = []
  const presses = []
  const pages = []
  const shell = {}
  const element = () => ({
    innerHTML: "",
    dataset: {},
    style: {setProperty() {}},
    classList: {add() {}, remove() {}, toggle() {}},
    getBoundingClientRect: () => ({left: 0, top: 0, right: width, bottom: 600, width, height: 600})
  })
  const parts = {"#near": element(), "#far": element(), "#frame": element()}
  const cyfr = {
    desktop: {prefs: {document: prefs, revision: 1}, appearance: {mode: "light", locale: "en-GB", time_zone: "UTC"}, person: {name: "Noor"}},
    on: (event, handler) => (shell[event] = handler),
    stream(name, subject, onEvent) {
      const open = {name: subject ? `feed:${subject}` : name, stream: name, onEvent}
      opens.push(open)
      if (refuse[open.name]) {
        const error = Object.assign(new Error("refused"), refuse[open.name])
        delete refuse[open.name]
        return Promise.reject(error)
      }
      open.handle = {state: "live", close() {}, closed: new Promise((resolve) => (open.end = resolve))}
      return Promise.resolve(open.handle)
    },
    press: (control, value) => new Promise((answer) => presses.push({control, value, answer})),
    settings: (page) => pages.push(page),
    prefs: () => new Promise(() => {}),
    ask() {},
    open() {},
    grant() {},
    ready() {}
  }
  const context = {
    cyfr,
    innerWidth: width,
    innerHeight: 600,
    document: {
      documentElement: element(),
      activeElement: null,
      body: {append() {}},
      querySelector: (selector) => parts[selector] || null,
      querySelectorAll: () => [],
      addEventListener: (type, fn) => (listeners[type] = fn)
    },
    performance: {getEntriesByType: () => [{nextHopProtocol: protocol}]},
    addEventListener() {},
    matchMedia: () => ({matches: true}),
    requestAnimationFrame: (fn) => setImmediate(fn),
    setTimeout: (fn) => timers.push(fn),
    clearTimeout: (id) => (timers[id - 1] = null),
    setInterval: () => 0,
    clearInterval() {},
    CSS: {escape: (s) => s}
  }
  context.window = context
  vm.runInNewContext(readFileSync(new URL("app.js", version), "utf8"), context)

  const last = (name) => opens.filter((o) => o.name === name).at(-1)
  const send = (name, event) => last(name).onEvent({id: null, data: null, revision: null, at: null, ...event})
  const change = (name, data, revision) =>
    send(name, {event: last(name).stream, data: {...data, revision, at: today(12, 0)}, revision, at: today(12, 0)})
  const picture = (name, items, at = today(12, 0)) => {
    items.forEach((data, i) => change(name, {...data, refresh: true}, i + 1))
    send(name, {event: "snapshot", at})
  }
  const html = () => parts["#near"].innerHTML + parts["#far"].innerHTML
  const seen = () => unescape(html().replace(/<[^>]*>/g, " ")).replace(/\s+/g, " ")
  const buttons = () =>
    [...html().matchAll(/<button\b([^>]*)>([\s\S]*?)<\/button>/g)].map(([, attributes, inner]) => {
      const attrs = Object.fromEntries([...attributes.matchAll(/([\w-]+)="([^"]*)"/g)].map(([, k, v]) => [k, unescape(v)]))
      const dataset = Object.fromEntries(
        Object.entries(attrs)
          .filter(([k]) => k.startsWith("data-"))
          .map(([k, v]) => [k.slice(5).replace(/-(\w)/g, (_, c) => c.toUpperCase()), v])
      )
      return {attrs, dataset, label: attrs["aria-label"] || "", words: unescape(inner.replace(/<[^>]*>/g, "")).trim()}
    })
  const button = (match) => {
    const found = buttons().find(match)
    assert.ok(found, `no such button among ${buttons().map((b) => b.label || b.words).join(" | ")}`)
    return found
  }
  const tap = (match) => {
    const b = button(match)
    listeners.click({target: {closest: () => ({dataset: b.dataset, getAttribute: (k) => b.attrs[k] ?? null})}})
  }
  const runTimers = () => timers.splice(0).forEach((fn) => fn && fn())
  const tell = (event, value) => shell[event](value)
  return {opens, presses, pages, send, change, picture, seen, buttons, button, tap, runTimers, last, tell}
}

const flush = async () => {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve))
}

const DIGEST = "formula:local.digest:1.0.0"
const failedRun = {kind: "failed", execution_id: "ex_digest", parent_execution_id: null, reference: DIGEST, component_type: "formula",
  duration_ms: 900, started_at: today(9, 0), ended_at: today(9, 1), error: {class: "timeout", cause: "timed_out"}}
const failedAttention = {kind: "failed_run", id: DIGEST, label: DIGEST, since: today(9, 1),
  destination: {kind: "page", page: "executions", ref: "ex_digest"}, outcome: null}

describe("the line desktop 0.2.0", () => {
  for (const protocol of ["http/1.1", "h2", "h3", ""]) {
    test(`every declared stream opens once at start, whatever is on (${protocol || "unknown"})`, async () => {
      for (const width of [390, 1024, 1440]) {
        for (const on of [true, false]) {
          const prefs = {widgets: Object.fromEntries(WIDGET_IDS.map((id) => [id, {on}]))}
          const p = desk({width, protocol, prefs})
          await flush()
          assert.deepEqual(p.opens.map((o) => o.name).sort(), DECLARED, `at ${width} with every part ${on ? "on" : "off"}`)
        }
      }
    })
  }

  test("the manifest declares retry-run exactly", () => {
    assert.deepEqual(
      MANIFEST.tincture.desktop.controls.find((c) => c.id === "retry-run"),
      {id: "retry-run", label: "Retry", operation: "execution.retry", args: {}, pick: {stream: "runs.changes", field: "/execution_id", arg: "execution_id"}}
    )
    assert.ok(MANIFEST.tincture.desktop.data.includes("runs.changes"))
  })

  test("a failed run that waits on you offers Retry in the queue, and a tap presses retry-run with its run", async () => {
    const p = desk()
    await flush()
    p.picture("runs.changes", [failedRun])
    p.picture("attention.changes", [failedAttention])
    await flush()
    const retry = p.button((b) => b.dataset.act === "retry")
    assert.equal(retry.words, "Retry")
    assert.equal(retry.label, "Retry: digest")
    // Today points at the queue instead of offering it twice.
    assert.match(p.seen(), /← waits on you/)
    assert.equal(p.buttons().filter((b) => b.dataset.act === "retry").length, 1)

    p.tap((b) => b.dataset.act === "retry")
    await flush()
    assert.deepEqual(p.presses.map(({control, value}) => [control, value]), [["retry-run", "ex_digest"]])
    const waiting = p.button((b) => b.dataset.act === "retry")
    assert.equal(waiting.words, "Retrying")
    assert.equal(waiting.attrs["aria-disabled"], "true")
    // A second tap while it waits presses nothing.
    p.tap((b) => b.dataset.act === "retry")
    assert.equal(p.presses.length, 1)

    p.presses[0].answer({outcome: "accepted"})
    await flush()
    assert.match(p.seen(), /Running again/)
  })

  test("a failed_run item whose run the runs picture does not hold opens the runs page instead", async () => {
    const p = desk()
    await flush()
    p.picture("attention.changes", [failedAttention])
    await flush()
    assert.equal(p.buttons().filter((b) => b.dataset.act === "retry").length, 0)
    p.tap((b) => b.words === "Open runs")
    assert.deepEqual(p.pages, ["executions"])
  })

  test("a failed root run offers Retry in Today; a completed run and a child run offer none", async () => {
    const p = desk()
    await flush()
    p.picture("runs.changes", [
      {...failedRun, execution_id: "ex_root"},
      {...failedRun, execution_id: "ex_child", parent_execution_id: "ex_root"},
      {...failedRun, execution_id: "ex_done", kind: "completed", error: null}
    ])
    await flush()
    assert.deepEqual(p.buttons().filter((b) => b.dataset.act === "retry").map((b) => b.dataset.id), ["ex_root"])
  })

  test("each answer to Retry shows its words", async () => {
    const p = desk()
    await flush()
    p.picture("runs.changes", [{...failedRun, execution_id: "ex_root"}])
    await flush()
    const answers = [
      [{outcome: "refused", reason: "conflict"}, "Only a run a schedule or a feed started runs again"],
      [{outcome: "refused", reason: "invalid_argument"}, "No longer among the latest runs"],
      [{outcome: "refused", reason: "not_found"}, "This run is gone"],
      [{outcome: "refused", reason: "forbidden"}, "Not yours to run again"],
      [{outcome: "refused", reason: "unavailable"}, "CYFR can't run it now. Try again shortly"],
      [{outcome: "refused", reason: "rate_limited"}, "CYFR can't run it now. Try again shortly"],
      [{outcome: "refused", reason: "timeout"}, "CYFR can't run it now. Try again shortly"],
      [{outcome: "refused", reason: "uncertain"}, "No answer came. Look at Runs before trying again"],
      [{outcome: "refused", reason: "internal"}, "It could not run again"],
      [{outcome: "cancelled", reason: "too_soon"}, "Too soon after your last tap. Tap again in a moment"],
      [{outcome: "cancelled"}, "Nothing ran"],
      [{outcome: "accepted"}, "Running again"]
    ]
    for (const [i, [answer, words]] of answers.entries()) {
      p.tap((b) => b.dataset.act === "retry" && b.dataset.id === "ex_root")
      await flush()
      p.presses[i].answer(answer)
      await flush()
      assert.ok(p.seen().includes(words), `${JSON.stringify(answer)} says "${words}"`)
    }
    assert.equal(p.presses.length, answers.length)
  })

  test("a resync followed by a picture without an item removes it, with no crossing", async () => {
    const p = desk()
    await flush()
    p.picture("schedules.changes", [
      {kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active", next_run_at: today(23, 0)},
      {kind: "changed", schedule_id: "s2", name: "Weekly review", status: "active", next_run_at: today(23, 30)}
    ])
    p.picture("attention.changes", [{kind: "approval", id: "ap_1", label: "Trip planning", since: today(11, 40), destination: {kind: "page", page: "aqua", ref: "th_1"}}])
    await flush()
    assert.match(p.seen(), /Weekly review/)
    assert.match(p.seen(), /Trip planning/)

    p.send("schedules.changes", {event: "resync"})
    p.picture("schedules.changes", [{kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active", next_run_at: today(23, 0)}])
    p.send("attention.changes", {event: "resync"})
    p.picture("attention.changes", [])
    await flush()
    assert.match(p.seen(), /Morning digest/)
    assert.doesNotMatch(p.seen(), /Weekly review/)
    assert.doesNotMatch(p.seen(), /Trip planning/)
    assert.doesNotMatch(p.seen(), /settled/)
  })

  test("a live removal settles the item across the line, saying how it left", async () => {
    const p = desk()
    await flush()
    p.picture("attention.changes", [{kind: "file_offer", id: "of_1", label: "budget.xlsx", since: today(13, 10), destination: {kind: "page", page: "files", ref: "of_1"}}])
    await flush()
    p.change("attention.changes", {kind: "removed", id: "of_1", label: null, since: null, destination: null, outcome: "withdrawn"}, 5)
    await flush()
    assert.match(p.seen(), /budget\.xlsx Withdrawn before you got to it withdrawn/)
    assert.match(p.seen(), /Nothing waits on you/)
  })

  test("a lower revision after a higher one changes nothing, and a removal keeps its revision", async () => {
    const p = desk()
    await flush()
    p.picture("schedules.changes", [])
    p.change("schedules.changes", {kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active"}, 10)
    p.change("schedules.changes", {kind: "changed", schedule_id: "s1", name: "Old name", status: "active"}, 5)
    await flush()
    assert.match(p.seen(), /Morning digest/)
    assert.doesNotMatch(p.seen(), /Old name/)

    p.change("schedules.changes", {kind: "removed", schedule_id: "s1"}, 12)
    p.change("schedules.changes", {kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active"}, 11)
    await flush()
    assert.doesNotMatch(p.seen(), /Morning digest/)
  })

  test("stale shows the tired picture as of its time until the next snapshot", async () => {
    const p = desk()
    await flush()
    p.picture("schedules.changes", [{kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active"}])
    await flush()
    p.send("schedules.changes", {event: "stale", at: today(14, 20)})
    await flush()
    assert.match(p.seen(), /Schedules .*As of 14:20 Morning digest/)
    p.send("schedules.changes", {event: "snapshot", at: today(14, 25)})
    await flush()
    assert.doesNotMatch(p.seen(), /As of/)
    assert.match(p.seen(), /Morning digest/)
  })

  test("unavailable keeps the picture and says when it tries again", async () => {
    const p = desk()
    await flush()
    p.picture("schedules.changes", [{kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active"}])
    await flush()
    p.send("schedules.changes", {event: "unavailable", data: {retry_at: today(14, 21)}})
    await flush()
    assert.match(p.seen(), /trying again at 14:21 Morning digest/)
    p.send("schedules.changes", {event: "resync"})
    p.picture("schedules.changes", [{kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active"}])
    await flush()
    assert.doesNotMatch(p.seen(), /trying again/)
  })

  test("denied ends the part and says it is no longer granted", async () => {
    const p = desk()
    await flush()
    p.picture("schedules.changes", [{kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active"}])
    await flush()
    const open = p.last("schedules.changes")
    open.handle.state = "denied"
    p.send("schedules.changes", {event: "denied", data: {class: "forbidden", message: "Refusal text the page never shows", stage: "grant"}})
    open.end()
    await flush()
    p.runTimers()
    await flush()
    assert.match(p.seen(), /Schedules .*No longer granted to this desktop/)
    assert.doesNotMatch(p.seen(), /Morning digest|Refusal text/)
    assert.equal(p.opens.filter((o) => o.name === "schedules.changes").length, 1)
  })

  test("a hidden-then-shown desktop shows its parts live again, with no denied in between", async () => {
    const p = desk()
    await flush()
    const approval = {kind: "approval", id: "ap_1", label: "Trip planning", since: today(11, 40), destination: {kind: "page", page: "aqua", ref: "th_1"}}
    const offer = {kind: "file_offer", id: "of_1", label: "budget.xlsx", since: today(13, 10), destination: {kind: "page", page: "files", ref: "of_1"}}
    const run = (id, kind, h) => ({...failedRun, execution_id: id, kind, error: null, ended_at: null, started_at: today(h, 0)})
    const schedule = (id, name, status) => ({kind: "changed", schedule_id: id, name, status, next_run_at: today(23, 0)})
    p.picture("attention.changes", [approval, offer])
    p.picture("runs.changes", [run("ex_a", "completed", 10), run("ex_b", "started", 11)])
    p.picture("schedules.changes", [schedule("s1", "Morning digest", "active"), schedule("s2", "Weekly review", "active")])
    await flush()
    assert.match(p.seen(), /2 things wait on you .*budget\.xlsx/)
    assert.match(p.seen(), /Weekly review/)
    const opened = p.opens.length

    // Hidden: every handle is suspended and the page hears nothing.
    for (const o of p.opens) if (o.handle) o.handle.state = "suspended"
    p.tell("state", "frozen")
    p.runTimers()
    await flush()

    // Shown: the SDK opens each stream again itself; each hears its fresh picture.
    p.tell("state", "live")
    for (const o of p.opens) if (o.handle) o.handle.state = "live"
    for (const name of ["attention.changes", "runs.changes", "schedules.changes"]) p.send(name, {event: "resync"})
    p.picture("attention.changes", [{...approval, label: "Trip planning, day 2"}])
    p.picture("runs.changes", [{...run("ex_b", "completed", 11), duration_ms: 2400}])
    p.picture("schedules.changes", [schedule("s1", "Morning digest", "paused")])
    await flush()

    const seen = p.seen()
    assert.match(seen, /1 thing waits on you .*Trip planning, day 2/)
    assert.doesNotMatch(seen, /budget\.xlsx|settled|left your queue/)
    assert.match(seen, /Morning digest Paused/)
    assert.doesNotMatch(seen, /Weekly review/)
    assert.match(seen, /Today 1 run · 0 failed .*ok 2\.4 s/)
    assert.doesNotMatch(seen, /No longer granted|Not granted|As of|trying again|Can't be read|could not be read/)
    assert.equal(p.opens.length, opened)
  })

  test("a first open with no answer, and a stream the endpoint ended, open again", async () => {
    const p = desk({refuse: {"runs.changes": {code: "unavailable"}}})
    await flush()
    assert.match(p.seen(), /Today .*trying again at/)
    const vault = p.last("vault.changes")
    vault.handle.state = "ended"
    vault.end()
    await flush()
    p.runTimers()
    await flush()
    assert.equal(p.opens.filter((o) => o.name === "runs.changes").length, 2)
    assert.equal(p.opens.filter((o) => o.name === "vault.changes").length, 2)
  })

  test("a first open refused forbidden says the part is not granted", async () => {
    const p = desk({refuse: {"schedules.changes": {code: "forbidden", message: "Refusal text"}}})
    await flush()
    assert.match(p.seen(), /Schedules .*Not granted to this desktop/)
    assert.doesNotMatch(p.seen(), /Refusal text/)
  })

  test("each attention destination opens its page: AQUA, runs, schedules, files", async () => {
    const p = desk()
    await flush()
    const item = (id, kind, page, since) => ({kind, id, label: id, since: today(10, since), destination: {kind: "page", page, ref: id}})
    p.picture("attention.changes", [
      item("Trip planning", "approval", "aqua", 1),
      item(DIGEST, "failed_run", "executions", 2),
      item("Backup photos", "failed_schedule", "schedules", 3),
      item("budget.xlsx", "file_offer", "files", 4)
    ])
    await flush()
    for (const words of ["Open in AQUA", "Open runs", "Open schedules", "Open files"]) p.tap((b) => b.words === words)
    assert.deepEqual(p.pages, ["aqua", "executions", "schedules", "files"])
  })

  test("a shared thread opens the chat and an own thread opens AQUA, with unread counts", async () => {
    const p = desk({width: 1440})
    await flush()
    p.picture("threads.changes", [
      {kind: "shared", id: "th_family", title: "Family", people: ["a", "b", "c"], last_activity: today(13, 55), waits_on_you: false, unread: 2},
      {kind: "own", id: "th_tax", title: "Tax notes", people: ["a"], last_activity: today(13, 0), waits_on_you: false, unread: null}
    ])
    await flush()
    assert.match(p.seen(), /Family 3 people · 2 unread/)
    p.tap((b) => b.dataset.key === "th-th_family")
    p.tap((b) => b.dataset.key === "th-th_tax")
    assert.deepEqual(p.pages, ["chat", "aqua"])
  })

  test("a file offer names its sender once files.changes holds the offer, and reads as before without it", async () => {
    const p = desk()
    await flush()
    p.picture("attention.changes", [
      {kind: "file_offer", id: "of_1", label: "budget.xlsx", since: today(13, 10), destination: {kind: "page", page: "files", ref: "of_1"}},
      {kind: "file_offer", id: "of_2", label: "trip.md", since: today(13, 20), destination: {kind: "page", page: "files", ref: "of_2"}}
    ])
    await flush()
    assert.match(p.seen(), /budget\.xlsx File offer · since 13:10/)

    p.picture("files.changes", [
      {kind: "offer", id: "of_1", name: "budget.xlsx", type: null, changed_at: null, from: "Sam"},
      {kind: "file", id: "data/cover.png", name: "cover.png", type: "image/png", changed_at: today(13, 2), from: null}
    ])
    await flush()
    assert.match(p.seen(), /budget\.xlsx File offer from Sam · since 13:10/)
    assert.match(p.seen(), /trip\.md File offer · since 13:20/)

    // A removal is a reread: the fresh picture that follows decides.
    p.change("files.changes", {kind: "removed", id: "of_1"}, 9)
    await flush()
    assert.match(p.seen(), /File offer from Sam/)
    p.send("files.changes", {event: "resync"})
    p.picture("files.changes", [])
    await flush()
    assert.match(p.seen(), /budget\.xlsx File offer · since 13:10/)
  })

  test("the system's status reaches the System widget and the far side's subline", async () => {
    const p = desk({width: 1440})
    await flush()
    p.picture("system.changes", [{kind: "changed", health: "ok", storage_used: 38e9, storage_cap: 100e9, model_connected: true,
      crew_ready: 2, crew_total: 2, version: "0.6.0", update_available: true}])
    p.picture("components.changes", [{kind: "installed", ref: "tincture:local.maps", type: "tincture", name: "Maps", update_available: true}])
    await flush()
    assert.match(p.seen(), /Running on its own Healthy · model connected · crew 2 of 2/)
    assert.match(p.seen(), /System CYFR 0\.6\.0 .*Healthy Update available Storage 38 of 100 GB/)
    assert.match(p.seen(), /Model Connected Crew 2 of 2 ready/)
    assert.match(p.seen(), /Apps Maps has an update/)
  })

  test("runs show the time they started, and a crew job its title", async () => {
    const p = desk()
    await flush()
    p.picture("runs.changes", [{...failedRun, execution_id: "ex_ok", kind: "completed", error: null, started_at: today(14, 0), duration_ms: 1200}])
    p.picture("schedule_runs.changes", [{kind: "fired", schedule_id: "s1", occurrence_id: "oc_1", execution_id: "ex_ok", scheduled_for: today(14, 0), reason: null}])
    p.picture("schedules.changes", [{kind: "changed", schedule_id: "s1", name: "Weather every 10 min", reference: "catalyst:local.weather:1.0.0", status: "active"}])
    p.picture("activity.changes", [{kind: "started", id: "job_1", member: "explorer", asked_by: "Noor", title: "Compare ferry times", since: today(14, 12), status: "running"}])
    await flush()
    assert.match(p.seen(), /14:12 Compare ferry times explorer · for Noor/)
    assert.match(p.seen(), /14:00 Weather every 10 min Scheduled ok 1\.2 s/)
  })
})
