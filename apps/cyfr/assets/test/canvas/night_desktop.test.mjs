// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The night desktop (seed/components/tinctures/local/night): its own page
// files, run here as the page runs them, in a context of their own with the
// SDK's client over a stand-in stream connection and the few DOM calls the
// page makes.
// What it keeps in flight while its parts change.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

import {createClient} from "../../js/sdk/client.js"
import {CREDENTIAL, HANDSHAKE, toFrameMessage} from "../../js/sdk/wire.js"

const VERSION = new URL("../../../../../seed/components/tinctures/local/night/0.1.0/", import.meta.url)
const WIRE = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/tincture_wire.json", import.meta.url), "utf8"))
const MANIFEST = JSON.parse(readFileSync(new URL("cyfr-manifest.json", VERSION), "utf8"))

const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

// An element that takes every call the page makes and lays nothing out.
function element() {
  return {
    dataset: {},
    style: {setProperty() {}},
    classList: {add() {}, remove() {}, toggle() {}, contains: () => false},
    addEventListener() {},
    setAttribute() {},
    removeAttribute() {},
    getBoundingClientRect: () => ({left: 0, top: 0, right: 1024, bottom: 600, width: 1024, height: 600}),
    hidden: true,
    innerHTML: "",
  }
}

// The page's model.js and street.js under the SDK's client, whose
// subscriptions are never answered until the test settles them, which ends
// each unopened; answers every subscription the page made, by stream, with
// whether it is still in flight.
async function night(widgets) {
  const requests = []
  const socket = {
    send(data) {
      const {type, sub, stream} = JSON.parse(data)
      if (type === "unsubscribe") {
        for (const request of requests) if (request.sub === sub) request.closed = true
        return
      }
      const request = {stream, sub, settled: false, closed: false}
      request.settle = () => {
        request.settled = true
        socket.onmessage({data: JSON.stringify({v: 1, type: "ended", sub})})
      }
      requests.push(request)
    },
  }
  const win = {location: {pathname: "/_c/v1/review/frm_1"}, parent: {}}
  const {api, onWindowMessage} = createClient({
    win,
    base: "http://127.0.0.1:4000/",
    socketFn: () => {
      setTimeout(() => socket.onopen(), 0)
      return socket
    },
  })
  const elements = new Map(["street", "header", "wall", "level", "puddle-index", "plate", "fusebox"].map((id) => [`#${id}`, element()]))
  const document = {
    readyState: "complete",
    documentElement: element(),
    querySelector: (query) => elements.get(query) || null,
    querySelectorAll: () => [],
    addEventListener() {},
  }
  const page = {
    Intl, Date, Math, Number, String, JSON, Map, Set, Object, Array, Promise,
    document,
    cyfr: api,
    matchMedia: () => ({matches: true}),
    innerWidth: 1024,
    requestAnimationFrame: () => 1,
    setTimeout: () => 1,
    clearTimeout() {},
    setInterval: () => 1,
    addEventListener() {},
    performance: {now: () => 0},
  }
  page.window = page
  vm.createContext(page)
  for (const file of ["model.js", "street.js"]) vm.runInContext(readFileSync(new URL(file, VERSION), "utf8"), page)

  // The shell's open: the canvas block, with the stored preferences arriving
  // while the page's first opens are still in flight.
  const [{frame, reply}] = WIRE.canvas.handshake.valid
  const desk = MANIFEST.tincture.desktop
  const block = {
    ...reply.canvas,
    streams: [...desk.data.map((name) => ({name, subject: null})), ...desk.feeds.map((subject) => ({name: "feed.results", subject}))],
    prefs: {document: {widgets, desktop: {}}, revision: 1},
  }
  const channel = new MessageChannel()
  channel.port1.onmessage = () => {}
  onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame}, ports: [channel.port2]})
  channel.port1.postMessage(toFrameMessage("canvas", frame, block))
  channel.port1.postMessage({v: 1, type: CREDENTIAL, frame, credential: reply.credential})
  channel.port1.postMessage(toFrameMessage("state", frame, {state: "live"}))
  for (let i = 0; i < 20; i++) await tick()
  return {requests, close: () => (channel.port1.close(), channel.port2.close())}
}

const inFlight = (requests) => requests.filter((r) => !r.settled && !r.closed)

describe("the night desktop", () => {
  test("parts turned off while their streams still open keep no more than five opens in flight, and what waits opens once they settle", async () => {
    // The page opens the five the shipped parts read; the stored preferences
    // then cut the threads and the board and light the crew and the vault.
    const {requests, close} = await night({threads: {on: false}, board: {on: false}, crew: {on: true}, vault: {on: true}})
    try {
      assert.ok(requests.length <= 5, `${requests.length} opens sent: ${requests.map((r) => r.stream).join(", ")}`)
      assert.ok(inFlight(requests).length <= 5)

      // The cut parts' opens settle: the crew's and the vault's open then,
      // and no more than five are ever in flight.
      for (const r of requests.filter((r) => ["threads.changes", "schedules.changes", "runs.changes"].includes(r.stream))) r.settle()
      for (let i = 0; i < 20; i++) await tick()
      assert.ok(inFlight(requests).length <= 5)
      assert.deepEqual(inFlight(requests).map((r) => r.stream).sort(), ["activity.changes", "attention.changes", "components.changes", "vault.changes"])
    } finally {
      close()
    }
  })
})

// ---------- 0.2.0: every stream at once, held by the delivery contract ----------

const V2 = new URL("../../../../../seed/components/tinctures/local/night/0.2.0/", import.meta.url)
const MANIFEST_2 = JSON.parse(readFileSync(new URL("cyfr-manifest.json", V2), "utf8"))
const DESK_2 = MANIFEST_2.tincture.desktop
const DECLARED = [...DESK_2.data, ...DESK_2.feeds.map((feed) => `feed:${feed}`)].sort()
const PARTS_2 = Object.keys(DESK_2.prefs.widgets)
const AT = "2026-11-10T14:20:00Z"

// An element that keeps what the page writes into it and lays nothing out.
function stub() {
  const classes = new Set()
  return {
    dataset: {},
    style: {setProperty() {}},
    classList: {add: (c) => classes.add(c), remove: (c) => classes.delete(c), toggle() {}, contains: (c) => classes.has(c)},
    addEventListener() {},
    setAttribute() {},
    removeAttribute() {},
    getBoundingClientRect: () => ({left: 0, top: 0, right: 1024, bottom: 600, width: 1024, height: 600}),
    querySelector: () => null,
    querySelectorAll: () => [],
    focus() {},
    hidden: true,
    innerHTML: "",
    offsetWidth: 296,
    offsetHeight: 200,
  }
}

// The page's model.js and street.js at 1024 by 600 under a stand-in
// window.cyfr whose `stream` records each open as a line the test pushes
// events into, whose `press` answers `answer` (a value, or a function of
// the press), and whose first opens of the streams named in `refuse` reject
// with that code. Its timers wait until the test runs them.
function night2({widgets = {}, refuse = {}, answer = {outcome: "accepted"}} = {}) {
  const els = new Map(["street", "header", "wall", "level", "puddle-index", "plate", "fusebox"].map((id) => [`#${id}`, stub()]))
  const frames = []
  const timers = []
  const listeners = {}
  const opened = []
  const presses = []
  const pages = []
  const cyfr = {
    desktop: {prefs: {document: {widgets, desktop: {}}, revision: 1}, appearance: {mode: "dark", accent: "#d9e4ff", locale: "en", time_zone: "UTC", safe_areas: {}}, person: {name: "Noor"}},
    on() {},
    stream(name, subject, onEvent) {
      const line = {key: subject ? `feed:${subject}` : name, name, state: "live", push: (event) => onEvent(event)}
      line.handle = {close() {}, closed: new Promise((resolve) => (line.end = resolve)), get state() { return line.state }}
      opened.push(line)
      const code = refuse[line.key]
      delete refuse[line.key]
      return code ? Promise.reject(Object.assign(new Error("A sentence the page must not show."), {code})) : Promise.resolve(line.handle)
    },
    prefs: async (document) => ({outcome: "saved", document, revision: 2}),
    press: async (control, value) => (presses.push([control, value]), typeof answer === "function" ? answer(control, value) : answer),
    settings: (page) => pages.push(page),
    ask() {},
    open() {},
    grant() {},
    ready() {},
  }
  const page = {
    console,
    document: {
      readyState: "complete",
      documentElement: stub(),
      querySelector: (query) => els.get(query) || null,
      querySelectorAll: () => [],
      addEventListener: (type, handler) => (listeners[type] = handler),
    },
    cyfr,
    matchMedia: () => ({matches: true}),
    innerWidth: 1024,
    innerHeight: 600,
    requestAnimationFrame: (f) => frames.push(f),
    setTimeout: (fn, ms) => timers.push({fn, ms}),
    clearTimeout: (id) => timers[id - 1] && (timers[id - 1].cleared = true),
    setInterval: () => 0,
    addEventListener() {},
  }
  page.window = page
  vm.createContext(page)
  for (const file of ["model.js", "street.js"]) vm.runInContext(readFileSync(new URL(file, V2), "utf8"), page, {filename: file})
  const html = (id) => els.get(`#${id}`).innerHTML
  return {
    opened,
    presses,
    pages,
    plate: els.get("#plate"),
    html,
    street: () => html("wall") + html("level"),
    line: (key) => opened.filter((l) => l.key === key).at(-1),
    opens: (key) => opened.filter((l) => l.key === key).length,
    // Draws what the page has queued.
    draw() {
      for (let i = 0; i < 5 && frames.length; i++) for (const f of frames.splice(0)) f(0)
    },
    runTimers() {
      for (const t of timers.splice(0)) if (!t.cleared) t.fn()
    },
    // A tap on an element carrying `attrs`, as the page's document hears it.
    tap(attrs) {
      const node = {
        ...stub(),
        dataset: Object.fromEntries(Object.entries(attrs).filter(([k]) => k.startsWith("data-")).map(([k, v]) => [k.slice(5), v])),
        classList: {add() {}, remove() {}, contains: (c) => (attrs.class || "").split(" ").includes(c)},
        closest(query) {
          const attr = /^\[([\w-]+)\]$/.exec(query)
          if (attr) return attr[1] in attrs ? node : null
          return query.startsWith(".") && node.classList.contains(query.slice(1)) ? node : null
        },
      }
      listeners.click({target: node})
    },
  }
}

const settle = async () => {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve))
}

// A stream's picture: its items, each marked fresh, then its snapshot.
function picture(line, items) {
  for (const data of items) line.push({id: null, event: line.name, data: {revision: 1, ...data, refresh: true, at: AT}, revision: data.revision ?? 1, at: AT})
  line.push({id: null, event: "snapshot", data: null, revision: null, at: AT})
}
const change = (line, data) => line.push({id: null, event: line.name, data: {...data, at: AT}, revision: data.revision, at: AT})

// The plate's buttons as the person reads them, and its last answer.
function plateButtons(p) {
  return [...p.plate.innerHTML.matchAll(/<button class="([^"]*)" data-plate="(\d+)"([^>]*)>([\s\S]*?)<\/button>/g)].map(([, cls, index, attrs, inner]) => ({
    index,
    cls,
    attrs,
    label: inner.replace(/<[^>]*>/g, "").trim(),
  }))
}
const plateNote = (p) => (/<p class="plate__note" role="status">([^<]*)<\/p>/.exec(p.plate.innerHTML) || [])[1]
function press(p, label) {
  const button = plateButtons(p).find((b) => b.label === label)
  assert.ok(button, `no "${label}" on the plate among ${plateButtons(p).map((b) => b.label).join(" | ")}`)
  p.tap({"data-plate": button.index})
}

const RUN_FAILED = {kind: "failed", execution_id: "exe_fail", parent_execution_id: null, reference: "formula:local.digest:1.0.0", component_type: "formula", started_at: "2026-11-10T09:00:00Z", ended_at: "2026-11-10T09:00:04Z", error: {class: "timeout", cause: "provider_slow"}}
const RUN_DONE = {kind: "completed", execution_id: "exe_ok", parent_execution_id: null, reference: "catalyst:local.weather:1.0.0", component_type: "catalyst", duration_ms: 1100, started_at: "2026-11-10T14:10:00Z", ended_at: "2026-11-10T14:10:01Z"}
const RUN_CHILD = {kind: "failed", execution_id: "exe_child", parent_execution_id: "exe_ok", reference: "catalyst:local.lookup:1.0.0", component_type: "catalyst", started_at: "2026-11-10T14:10:00Z", ended_at: "2026-11-10T14:10:01Z", error: {class: "timeout", cause: "provider_slow"}}
const FAILED_ITEM = {kind: "failed_run", id: "formula:local.digest:1.0.0", label: "formula:local.digest:1.0.0", since: "2026-11-10T09:00:04Z", destination: {kind: "page", page: "executions", ref: "exe_fail"}}

// A page with every opened stream's first picture in: runs as given, the rest empty.
async function lit({runs = [], attention = [], ...options} = {}) {
  const p = night2(options)
  await settle()
  for (const line of p.opened) picture(line, line.key === "runs.changes" ? runs : line.key === "attention.changes" ? attention : [])
  p.draw()
  return p
}

describe("the night desktop 0.2.0", () => {
  for (const [name, widgets] of [
    ["the design's defaults", {}],
    ["every part on", Object.fromEntries(PARTS_2.map((id) => [id, {on: true}]))],
    ["every part off", Object.fromEntries(PARTS_2.map((id) => [id, {on: false}]))],
  ]) {
    test(`every declared stream opens exactly once at start, and nothing undeclared, with ${name}`, async () => {
      const p = night2({widgets})
      await settle()
      assert.deepEqual(p.opened.map((l) => l.key).sort(), DECLARED)
    })
  }

  test("the manifest declares retry-run exactly as the brief spells it, and reads files and system", () => {
    assert.deepEqual(DESK_2.controls.find((c) => c.id === "retry-run"), {id: "retry-run", label: "Retry", operation: "execution.retry", args: {}, pick: {stream: "runs.changes", field: "/execution_id", arg: "execution_id"}})
    assert.ok(DESK_2.data.includes("files.changes") && DESK_2.data.includes("system.changes"))
  })

  test("a failed root run's plate offers Retry, which waits for its answer and presses retry-run with the run's id once", async () => {
    let answered
    const p = await lit({runs: [RUN_FAILED, RUN_DONE, RUN_CHILD], answer: () => new Promise((resolve) => (answered = resolve))})
    assert.match(p.html("wall"), /data-target="run:exe_fail"/)
    assert.match(p.html("wall"), /<span class="dot when">09:00<\/span>/, "the run's own start time")
    p.tap({"data-target": "run:exe_fail"})
    press(p, "Retry")
    const waiting = plateButtons(p).find((b) => b.label === "Retry")
    assert.match(waiting.attrs, /disabled aria-busy="true"/)
    assert.match(waiting.cls, /is-working/)
    press(p, "Retry")
    assert.deepEqual(p.presses, [["retry-run", "exe_fail"]])
    answered({outcome: "accepted"})
    await settle()
    assert.equal(plateNote(p), "Running it again.")
    assert.doesNotMatch(plateButtons(p).find((b) => b.label === "Retry").attrs, /disabled/)
  })

  test("a completed run and a child run offer no Retry", async () => {
    const p = await lit({runs: [RUN_FAILED, RUN_DONE, RUN_CHILD]})
    assert.doesNotMatch(p.html("wall"), /exe_child/, "a child run is not on the board")
    for (const target of ["run:exe_ok", "run:exe_child"]) {
      p.tap({"data-target": target})
      assert.ok(!plateButtons(p).some((b) => b.label === "Retry"), `${target} offers Retry`)
      p.tap({"data-act": "plate-close"})
    }
  })

  test("a failed_run waiting item lights its run's row, and offers Retry only while that run is held", async () => {
    const p = await lit({runs: [RUN_FAILED, RUN_DONE], attention: [FAILED_ITEM]})
    assert.match(p.html("wall"), /data-target="failed:formula:local.digest:1.0.0" data-light="sputter"/)
    p.tap({class: "ripple", "data-ref": "failed:formula:local.digest:1.0.0"})
    press(p, "Retry")
    await settle()
    assert.deepEqual(p.presses, [["retry-run", "exe_fail"]])
    p.tap({"data-act": "plate-close"})

    // The runs' fresh picture no longer holds it: Retry goes, Open runs stays.
    const runs = p.line("runs.changes")
    runs.push({id: null, event: "resync", data: null, revision: null, at: null})
    picture(runs, [RUN_DONE])
    p.draw()
    p.tap({class: "ripple", "data-ref": "failed:formula:local.digest:1.0.0"})
    assert.deepEqual(plateButtons(p).map((b) => b.label), ["Open runs", "Ask AQUA"])
  })

  for (const [answer, words] of [
    [{outcome: "refused", reason: "conflict"}, /only a failed run a schedule or a feed started can/],
    [{outcome: "refused", reason: "invalid_argument"}, /no longer among the latest runs/],
    [{outcome: "refused", reason: "not_found"}, /That run is gone/],
    [{outcome: "refused", reason: "forbidden"}, /not yours to run again/],
    [{outcome: "refused", reason: "unavailable"}, /cannot run it now\. Try again shortly/],
    [{outcome: "refused", reason: "rate_limited"}, /cannot run it now\. Try again shortly/],
    [{outcome: "refused", reason: "timeout"}, /cannot run it now\. Try again shortly/],
    [{outcome: "refused", reason: "uncertain"}, /No answer came\. Look at your runs before trying again/],
    [{outcome: "refused", reason: "internal"}, /It could not be run again/],
    [{outcome: "cancelled", reason: "too_soon"}, /tap again/],
    [{outcome: "cancelled"}, /nothing ran/],
  ]) {
    test(`Retry answered ${answer.outcome} ${answer.reason || "with no reason"} says so in the street's words`, async () => {
      const p = await lit({runs: [RUN_FAILED], answer})
      p.tap({"data-target": "run:exe_fail"})
      press(p, "Retry")
      await settle()
      assert.match(plateNote(p), words)
    })
  }

  test("a resync followed by a picture without an item removes it, and only a live answer switches a light off", async () => {
    const p = await lit()
    const threads = p.line("threads.changes")
    const attention = p.line("attention.changes")
    picture(threads, [{kind: "shared", id: "t1", title: "Family", people: ["a", "b", "c"]}, {kind: "own", id: "t2", title: "Tax notes", people: ["me"], unread: null}])
    picture(attention, [{kind: "approval", id: "ap1", label: "Family", since: AT, destination: {kind: "page", page: "aqua", ref: "t1"}}])
    p.draw()
    assert.match(p.html("wall"), /Tax notes/)

    threads.push({id: null, event: "resync", data: null, revision: null, at: null})
    picture(threads, [{kind: "shared", id: "t1", title: "Family", people: ["a", "b", "c"]}])
    attention.push({id: null, event: "resync", data: null, revision: null, at: null})
    picture(attention, [])
    p.draw()
    assert.doesNotMatch(p.html("wall"), /Tax notes/)
    assert.doesNotMatch(p.html("puddle-index"), /data-going/, "a picture's drop does not switch a light off")

    change(attention, {kind: "approval", id: "ap2", label: "Family", since: AT, destination: {kind: "page", page: "aqua", ref: "t1"}, revision: 2})
    p.draw()
    change(attention, {kind: "removed", id: "ap2", outcome: "resolved", revision: 3})
    p.draw()
    assert.match(p.html("puddle-index"), /data-going="1"/, "a live answer switches its light off")
  })

  test("a lower revision after a higher one, or the same one twice, changes nothing", async () => {
    const p = await lit()
    const threads = p.line("threads.changes")
    change(threads, {kind: "shared", id: "t1", title: "Family", people: ["a", "b"], revision: 5})
    change(threads, {kind: "shared", id: "t1", title: "Old name", people: ["a", "b"], revision: 3})
    change(threads, {kind: "removed", id: "t1", revision: 5})
    p.draw()
    assert.match(p.html("wall"), /Family/)
    assert.doesNotMatch(p.html("wall"), /Old name/)
  })

  test("stale shows the tired picture as of its time, and the next snapshot clears it", async () => {
    const p = await lit()
    const threads = p.line("threads.changes")
    change(threads, {kind: "shared", id: "t1", title: "Family", people: ["a", "b"], revision: 2})
    threads.push({id: null, event: "stale", data: null, revision: null, at: AT})
    p.draw()
    assert.match(p.html("wall"), /data-part="threads" data-line="stale"/)
    assert.match(p.html("wall"), /as of 14:20/)
    assert.match(p.html("wall"), /Family/)
    picture(threads, [{kind: "shared", id: "t1", title: "Family", people: ["a", "b"], revision: 3}])
    p.draw()
    assert.match(p.html("wall"), /data-part="threads" data-line="live"/)
    assert.doesNotMatch(p.html("wall"), /as of/)
  })

  test("unavailable keeps the picture and says when it tries again", async () => {
    const p = await lit({runs: [RUN_DONE]})
    p.line("runs.changes").push({id: null, event: "unavailable", data: {retry_at: "2026-11-10T14:21:00Z"}, revision: null, at: null})
    p.draw()
    assert.match(p.html("wall"), /trying again at 14:21/)
    assert.match(p.html("wall"), /data-target="run:exe_ok"/)
  })

  test("denied ends the part and says it is no longer granted, never the refusal's sentence, and the page does not open it again", async () => {
    const p = await lit()
    const vault = p.line("vault.changes")
    const threads = p.line("threads.changes")
    change(threads, {kind: "shared", id: "t1", title: "Family", people: ["a", "b"], revision: 2})
    threads.state = "denied"
    threads.push({id: null, event: "denied", data: {class: "forbidden", message: "A sentence the page must not show.", stage: "admission"}, revision: null, at: null})
    threads.end()
    await settle()
    p.runTimers()
    p.draw()
    assert.doesNotMatch(p.html("wall"), /Family/)
    assert.match(p.html("wall"), /No longer granted/)
    assert.doesNotMatch(p.html("wall"), /must not show|No threads yet/)
    assert.equal(p.opens("threads.changes"), 1)
    assert.equal(p.opens("vault.changes"), 1, `${vault.key} untouched`)
  })

  test("a first open refused forbidden says not granted; one with no answer, or one the endpoint ended, opens again", async () => {
    const p = night2({refuse: {"system.changes": "forbidden", "threads.changes": "unavailable"}})
    await settle()
    p.draw()
    assert.match(p.html("level"), /Not granted/)
    assert.doesNotMatch(p.html("level"), /must not show/)
    assert.match(p.html("wall"), /data-part="threads" data-line="unavailable"[\s\S]*trying again at \d\d:\d\d/)
    const runs = p.line("runs.changes")
    runs.state = "ended"
    runs.end()
    await settle()
    p.runTimers()
    await settle()
    assert.equal(p.opens("threads.changes"), 2)
    assert.equal(p.opens("runs.changes"), 2)
    assert.equal(p.opens("system.changes"), 1)
  })

  test("each waiting item and thread opens the page its destination names", async () => {
    const p = await lit({
      runs: [RUN_FAILED],
      attention: [
        {kind: "approval", id: "ap1", label: "Trip planning", since: AT, destination: {kind: "page", page: "aqua", ref: "t1"}},
        FAILED_ITEM,
        {kind: "failed_schedule", id: "sch_1", label: "Morning digest", since: AT, destination: {kind: "page", page: "schedules", ref: "sch_1"}},
        {kind: "file_offer", id: "off_1", label: "budget.xlsx", since: AT, destination: {kind: "page", page: "files", ref: "off_1"}},
      ],
    })
    picture(p.line("threads.changes"), [
      {kind: "own", id: "t1", title: "Trip planning", people: ["me"], unread: null},
      {kind: "shared", id: "t2", title: "Family", people: ["a", "b", "c"], unread: 2},
      {kind: "own", id: "t3", title: "Tax notes", people: ["me"], unread: null},
    ])
    picture(p.line("schedules.changes"), [{kind: "changed", schedule_id: "sch_1", name: "Morning digest", reference: "formula:local.digest:1.0.0", cron_expression: "0 9 * * *", status: "active", next_run_at: "2026-11-11T09:00:00Z", run_count: 41, error_count: 1}])
    picture(p.line("files.changes"), [{kind: "offer", id: "off_1", name: "budget.xlsx", from: "Sam", changed_at: AT}])
    p.draw()
    for (const [target, label, page] of [
      ["thread:t1", "Open the approval", "aqua"],
      ["thread:t2", "Open in chat", "chat"],
      ["thread:t3", "Open in AQUA", "aqua"],
      ["failed:formula:local.digest:1.0.0", "Open runs", "executions"],
      ["schedule:sch_1", "Open schedules", "schedules"],
      ["offer:off_1", "Open files", "files"],
    ]) {
      assert.match(p.street(), new RegExp(`data-target="${target}"`))
      p.tap({"data-target": target})
      press(p, label)
      assert.equal(p.pages.at(-1), page, `${target} opened ${p.pages.at(-1)}`)
    }
  })

  test("the files and system items reach the locker and the junction box, and the fields the catalog now carries show", async () => {
    const p = await lit({runs: [RUN_DONE]})
    picture(p.line("files.changes"), [
      {kind: "file", id: "data/trip.md", name: "trip.md", type: "text/markdown", changed_at: AT},
      {kind: "offer", id: "off_1", name: "budget.xlsx", from: "Sam", changed_at: "2026-11-10T13:10:00Z"},
    ])
    picture(p.line("system.changes"), [{kind: "changed", health: "ok", storage_used: 38 * 2 ** 30, storage_cap: 100 * 2 ** 30, model_connected: true, crew_ready: 2, crew_total: 2, version: "0.6.0", update_available: true}])
    picture(p.line("attention.changes"), [{kind: "file_offer", id: "off_1", label: "budget.xlsx", since: AT, destination: {kind: "page", page: "files", ref: "off_1"}}])
    picture(p.line("threads.changes"), [{kind: "shared", id: "t2", title: "Family", people: ["a", "b", "c"], unread: 2}])
    picture(p.line("activity.changes"), [{kind: "started", id: "j1", member: "explorer", asked_by: "Noor", title: "Compare ferry times", since: AT, status: "running"}])
    p.draw()
    const level = p.html("level")
    for (const seen of ["trip.md", "budget.xlsx", "from Sam · 13:10", "0.6.0", "healthy", "model connected", "crew 2 of 2", "38 of 100 GB", "update available"]) assert.ok(level.includes(seen), `the street level lacks "${seen}"`)
    assert.match(p.html("puddle-index"), /budget\.xlsx from Sam/)
    assert.match(p.html("wall"), /2 new/)
    assert.match(p.html("wall"), /Compare ferry times/)
    p.tap({"data-target": "file:data/trip.md"})
    press(p, "Open files")
    assert.deepEqual(p.pages, ["files"])
  })
})
