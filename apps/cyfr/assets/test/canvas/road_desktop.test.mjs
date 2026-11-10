// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The road desktop (seed/components/tinctures/local/road): its own page files, run here as the
// page runs them, in a context of their own with a stand-in for window.cyfr, the few DOM calls
// the page makes and a 2D context that draws nothing. What it opens, what its Plan offers, and
// from 0.2.0 how it holds what its streams say, what it offers to run again and where it opens.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

const ROAD = new URL("../../../../../seed/components/tinctures/local/road/", import.meta.url)
const SCRIPTS = ["font.js", "art.js", "model.js", "list.js", "scene.js", "boot.js"]
const PARTS = ["Visitors", "Post boxes", "Crew house", "Market", "Tower and road", "Strongroom", "Windmill", "Tram line"]
const WIDGETS = ["attention", "threads", "activity", "components", "schedules", "vault", "weather", "vpn"]

// A 2D context that accepts every call and every setting, and draws nothing.
function context2d() {
  const noop = () => {}
  return new Proxy({}, {get: (target, key) => (key in target ? target[key] : noop), set: (target, key, value) => ((target[key] = value), true)})
}

class Element {
  constructor(tag) {
    this.tagName = tag.toUpperCase()
    this.children = []
    this.parent = null
    this.style = {}
    this.attributes = {}
    this.listeners = {}
    this.dataset = {}
    this.textContent = ""
    this.className = ""
    this.disabled = false
    this.tabIndex = 0
    this.width = 0
    this.height = 0
    this.clientWidth = 0
    this.clientHeight = 0
    const classes = new Set()
    this.classList = {add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c)}
  }
  appendChild(child) {
    child.parent = this
    this.children.push(child)
    return child
  }
  append(...children) {
    for (const child of children) if (typeof child !== "string") this.appendChild(child)
  }
  replaceChildren(...children) {
    this.children = []
    this.append(...children)
  }
  remove() {
    if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this)
  }
  setAttribute(key, value) {
    this.attributes[key] = String(value)
  }
  getAttribute(key) {
    return this.attributes[key] ?? null
  }
  removeAttribute(key) {
    delete this.attributes[key]
  }
  addEventListener(type, handler) {
    ;(this.listeners[type] ||= []).push(handler)
  }
  dispatch(type, init = {}) {
    for (const handler of this.listeners[type] || []) handler({stopPropagation() {}, preventDefault() {}, ...init})
  }
  setPointerCapture() {}
  getBoundingClientRect() {
    return {left: 0, top: 0, x: 0, y: 0, width: this.clientWidth, height: this.clientHeight}
  }
  getContext() {
    return context2d()
  }
}

// The page of `version` at `width` by `height` CSS pixels, its document served over `protocol`,
// the person's preferences `document`, the shell's `installed` apps; `refuse` names, per stream,
// the codes its next opens are refused with, and `scale` speeds the page's timers. Answers the
// context, the streams the page opened (each open's handler and handle in `subs`), what it
// asked the shell (`calls`) and a pump that runs the page's queued frames.
function page({version = "0.1.0", width = 1024, height = 600, protocol = "http/1.1", document: prefs = {}, scripts = SCRIPTS, installed = null, refuse = {}, scale = 1} = {}) {
  const ids = Object.fromEntries(["stage", "village", "hits", "live", "road", "lists", "fallback"].map((id) => [id, new Element(id === "village" ? "canvas" : "div")]))
  ids.stage.clientWidth = width
  ids.stage.clientHeight = height
  const doc = {
    hidden: false,
    documentElement: new Element("html"),
    getElementById: (id) => ids[id] || null,
    createElement: (tag) => new Element(tag),
    addEventListener() {},
  }
  const frames = []
  const opened = []
  const subs = {}
  const handlers = {}
  const calls = {press: [], settings: [], grant: []}
  const answers = {press: {outcome: "accepted"}}
  let stored = {document: prefs, revision: 1}
  const cyfr = {
    get desktop() {
      return {prefs: stored, appearance: {mode: "dark", accent: "#36c9c0", locale: "en", time_zone: "UTC", safe_areas: {}}, person: {name: "Noor"}}
    },
    on(event, handler) {
      handlers[event] = handler
      if (event === "state") handler("live")
      if (event === "posture") handler(width < 768 ? "hand" : "desk")
      if (event === "installed" && installed) handler(installed)
      return () => {}
    },
    stream(name, subject, onEvent) {
      const key = subject ? `feed:${subject}` : name
      opened.push(key)
      const code = (refuse[key] || []).shift()
      if (code) return Promise.reject(Object.assign(new Error("refused"), {code}))
      let settle
      const handle = {state: "live", closed: new Promise((resolve) => (settle = resolve)), close: () => end("ended")}
      const end = (state) => ((handle.state = state), settle())
      subs[key] = {onEvent, handle, end}
      return Promise.resolve(handle)
    },
    async prefs({widgets}) {
      const document = {...stored.document, widgets: {...(stored.document.widgets || {}), ...widgets}}
      stored = {document, revision: stored.revision + 1}
      return {outcome: "saved", document, revision: stored.revision}
    },
    async press(control, value) {
      calls.press.push([control, value])
      return answers.press
    },
    ask() {},
    settings: (page) => calls.settings.push(page),
    open() {},
    grant: (ref) => calls.grant.push(ref),
    ready() {},
  }
  const win = {
    cyfr,
    document: doc,
    console,
    innerWidth: width,
    innerHeight: height,
    performance: {now: () => Date.now(), getEntriesByType: () => [{nextHopProtocol: protocol}]},
    matchMedia: () => ({matches: false}),
    requestAnimationFrame: (f) => frames.push(f),
    addEventListener() {},
    setTimeout: (f, ms) => {
      const t = setTimeout(f, ms * scale)
      t.unref()
      return t
    },
    clearTimeout,
  }
  win.window = win
  win.self = win
  const ctx = vm.createContext(win)
  for (const file of scripts) vm.runInContext(readFileSync(new URL(`${version}/${file}`, ROAD), "utf8"), ctx, {filename: file})
  let now = 1000
  const pump = (n = 3) => {
    for (let i = 0; i < n; i++) {
      const due = frames.splice(0)
      now += 100
      for (const f of due) f(now)
    }
  }
  return {win, ids, opened, subs, handlers, calls, answers, pump}
}

const settle = () => new Promise((resolve) => setImmediate(resolve))

// The tap targets the scene declares, by label, with where each stands in the page.
function hits(p) {
  return p.ids.hits.children.map((e) => {
    const box = Object.fromEntries((e.style.cssText || "").split(";").filter(Boolean).map((d) => d.split(":")).map(([k, v]) => [k, parseFloat(v)]))
    return {label: e.getAttribute("aria-label") || "", element: e, ...box}
  })
}
const tap = (p, start) => {
  const hit = hits(p).find((h) => h.label.startsWith(start))
  assert.ok(hit, `no tap target "${start}" among ${hits(p).map((h) => h.label).join(" | ")}`)
  hit.element.dispatch("click")
  p.pump()
}

describe("the road desktop", () => {
  for (const protocol of ["http/1.1", "h2", "h3", ""]) {
    test(`road_stream_budget_is_five_on_every_protocol (${protocol || "unknown"})`, async () => {
      const every = {widgets: Object.fromEntries(WIDGETS.map((w) => [w, {on: true}]))}
      const p = page({protocol, document: every, scripts: ["model.js"]})
      p.win.Road.start()
      await settle()
      assert.equal(p.opened.length, 5, `opened ${p.opened.join(", ")}`)
      assert.equal(p.win.Road.BUDGET, 5)
    })
  }

  for (const [width, height] of [
    [390, 844],
    [390, 744],
    [1024, 600],
    [1440, 800],
    [1440, 900],
  ]) {
    test(`road_plan_keeps_all_parts_reachable_at_phone_and_desk_sizes (${width}x${height})`, async () => {
      const p = page({width, height})
      await settle()
      p.pump()
      tap(p, "Plan the village")
      const reached = new Set()
      for (let page = 0; page < PARTS.length; page++) {
        for (const h of hits(p)) {
          const m = /^Turn (?:on|off) (.+)$/.exec(h.label)
          if (!m) continue
          assert.ok(h.left >= 0 && h.top >= 0 && h.left + h.width <= width && h.top + h.height <= height, `${h.label} stands outside the page`)
          reached.add(m[1])
        }
        if (reached.size === PARTS.length) break
        const more = hits(p).find((h) => /^More parts/.test(h.label))
        if (!more) break
        more.element.dispatch("click")
        p.pump()
      }
      assert.deepEqual([...reached].sort(), [...PARTS].sort())
    })
  }

  test("a part turned on from a later page of the Plan is written and opens its stream", async () => {
    const p = page({width: 390, height: 844, protocol: "http/1.1"})
    await settle()
    p.pump()
    tap(p, "Plan the village")
    tap(p, "Turn off Visitors")
    await settle()
    p.pump()
    for (let i = 0; i < PARTS.length && !hits(p).some((h) => h.label === "Turn on Tram line"); i++) tap(p, "More parts")
    tap(p, "Turn on Tram line")
    await settle()
    assert.ok(p.opened.includes("feed:vpn"), `opened ${p.opened.join(", ")}`)
  })
})

// ---- 0.2.0 -------------------------------------------------------------------------------------

const V2 = "0.2.0"
const MANIFEST = JSON.parse(readFileSync(new URL(`${V2}/cyfr-manifest.json`, ROAD), "utf8")).tincture.desktop
const DECLARED = [...MANIFEST.data, ...MANIFEST.feeds.map((feed) => `feed:${feed}`)].sort()
const WIDGETS_2 = Object.keys(MANIFEST.prefs.widgets)
const PARTS_2 = [...PARTS.slice(0, 6), "Silo", "Archive", "Windmill", "Tram line"]
const iso = (minutes) => new Date(Date.now() + minutes * 60000).toISOString()
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// A started 0.2.0 page with every stream opened; `hold` hands each stream its picture.
async function road(options = {}, hold = {}) {
  const p = page({version: V2, ...options})
  await settle()
  for (const [key, items] of Object.entries(hold)) picture(p, key, items)
  p.pump()
  return p
}
// Events into the stream `key` the page opened last, then the frames they ask for.
function push(p, key, ...events) {
  for (const event of events) p.subs[key].onEvent({id: null, revision: null, at: null, data: null, ...event})
  p.pump()
}
// A whole picture of `key`: each item marked refresh, at revision 1 unless it names its own, then the snapshot.
function picture(p, key, items) {
  const name = key.startsWith("feed:") ? "feed.results" : key
  push(p, key, ...items.map((item) => ({event: name, data: {revision: 1, ...item, refresh: true}, revision: item.revision ?? 1})), {event: "snapshot", at: iso(0)})
}
const change = (p, key, data, revision) => push(p, key, {event: key, data: {...data, revision}, revision})
const labels = (p) => hits(p).map((h) => h.label)
const label = (p, start) => labels(p).find((l) => l.startsWith(start)) ?? ""
// What the page last said aloud (its live region, filled a moment after the tap's answer).
async function said(p) {
  await wait(60)
  return p.ids.live.textContent
}

const failedRun = (id, ref, parent = null) => ({kind: "failed", execution_id: id, parent_execution_id: parent, reference: ref, component_type: "formula", started_at: iso(-30), ended_at: iso(-29), error: {class: "timeout", cause: "timed_out"}})
const failedItem = (id, label, ref) => ({kind: "failed_run", id, label, since: iso(-29), destination: {kind: "page", page: "executions", ref}})

describe("the road desktop 0.2.0", () => {
  test("the manifest declares retry-run exactly as the contract writes it", () => {
    assert.deepEqual(
      MANIFEST.controls.find((c) => c.id === "retry-run"),
      {id: "retry-run", label: "Retry", operation: "execution.retry", args: {}, pick: {stream: "runs.changes", field: "/execution_id", arg: "execution_id"}},
    )
  })

  for (const protocol of ["http/1.1", "h2", "h3", ""]) {
    for (const on of [true, false]) {
      test(`every declared stream opens once at start, nothing else, every part ${on ? "on" : "off"} (${protocol || "unknown"})`, async () => {
        const p = await road({protocol, document: {widgets: Object.fromEntries(WIDGETS_2.map((w) => [w, {on}]))}})
        assert.deepEqual([...p.opened].sort(), DECLARED)
        const buildings = ["Post boxes", "Crew house", "Market", "Bell tower", "Strongroom", "Silo", "Archive"].filter((b) => labels(p).some((l) => l.startsWith(b)))
        assert.deepEqual(buildings, on ? ["Post boxes", "Crew house", "Market", "Bell tower", "Strongroom", "Silo", "Archive"] : [])
      })
    }
  }

  test("parts stand as the design has them by default: all but the archive", async () => {
    const p = await road()
    for (const start of ["Post boxes", "Crew house", "Market", "Bell tower", "Strongroom", "Silo", "Windmill", "Tram line"]) assert.ok(label(p, start), `no ${start}`)
    assert.equal(label(p, "Archive"), "")
  })

  for (const [width, height] of [
    [390, 844],
    [1024, 600],
    [1440, 900],
  ]) {
    test(`every part of 0.2.0 is reachable in the Plan (${width}x${height})`, async () => {
      const p = await road({width, height})
      tap(p, "Plan the village")
      const reached = new Set()
      for (let n = 0; n < PARTS_2.length && reached.size < PARTS_2.length; n++) {
        for (const l of labels(p)) {
          const m = /^Turn (?:on|off) (.+)$/.exec(l)
          if (m) reached.add(m[1])
        }
        if (reached.size < PARTS_2.length) tap(p, "More parts")
      }
      assert.deepEqual([...reached].sort(), [...PARTS_2].sort())
    })
  }

  test("a failed root run's attention item offers Retry, and the tap presses retry-run with its run", async () => {
    const p = await road({}, {
      "runs.changes": [failedRun("e1", "formula:local.digest:1.0.0")],
      "attention.changes": [failedItem("a1", "formula:local.digest:1.0.0", "e1")],
    })
    tap(p, "digest failed")
    tap(p, "Retry run")
    await settle()
    assert.deepEqual(p.calls.press, [["retry-run", "e1"]])
    assert.equal(await said(p), "Sent: it runs again.")
  })

  test("the failed firing the capybara trips on offers Retry for its run", async () => {
    const p = await road({}, {
      "schedules.changes": [{kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active", cron_expression: "0 9 * * *", next_run_at: iso(600)}],
      "schedule_runs.changes": [{kind: "failed", occurrence_id: "o1", schedule_id: "s1", execution_id: "e1", scheduled_for: iso(-2), reason: {class: "timeout", cause: "timed_out"}}],
      "runs.changes": [{...failedRun("e1", "formula:local.digest:1.0.0"), started_at: iso(-2)}],
    })
    p.ids.road.dispatch("keydown", {key: "Enter"})
    p.pump()
    assert.ok(labels(p).includes("Retry run"), labels(p).join(" | "))
    tap(p, "Retry run")
    await settle()
    assert.deepEqual(p.calls.press, [["retry-run", "e1"]])
  })

  test("Retry waits for its answer, one press per tap", async () => {
    const p = await road({}, {"runs.changes": [failedRun("e1", "formula:local.digest")], "attention.changes": [failedItem("a1", "formula:local.digest", "e1")]})
    let answer
    p.answers.press = new Promise((resolve) => (answer = resolve))
    tap(p, "digest failed")
    tap(p, "Retry run")
    assert.ok(labels(p).includes("Retrying..."))
    tap(p, "Retrying...")
    assert.equal(p.calls.press.length, 1)
    answer({outcome: "accepted"})
    await settle()
    p.pump()
    assert.ok(labels(p).includes("Retry run"))
  })

  for (const [reason, words] of [
    ["conflict", "This run cannot be run again: only a run a schedule or a feed started, known to have failed, runs again."],
    ["invalid_argument", "This run is no longer among the latest runs."],
    ["not_found", "This run is gone."],
    ["forbidden", "This run is not yours to run again."],
    ["unavailable", "CYFR cannot run it now. Try again shortly."],
    ["rate_limited", "CYFR cannot run it now. Try again shortly."],
    ["timeout", "CYFR cannot run it now. Try again shortly."],
    ["uncertain", "No answer came. Look at Runs before trying again."],
    ["internal", "It could not be run again."],
  ]) {
    test(`a Retry refused ${reason} says so in the village's words`, async () => {
      const p = await road({}, {"runs.changes": [failedRun("e1", "formula:local.digest")], "attention.changes": [failedItem("a1", "formula:local.digest", "e1")]})
      p.answers.press = {outcome: "refused", reason}
      tap(p, "digest failed")
      tap(p, "Retry run")
      assert.equal(await said(p), words)
    })
  }

  for (const [answer, words] of [
    [{outcome: "cancelled", reason: "too_soon"}, "Too soon after your last tap: wait a few seconds, then tap again."],
    [{outcome: "cancelled"}, "Nothing ran."],
  ]) {
    test(`a Retry answered ${answer.reason || "cancelled"} says ${words}`, async () => {
      const p = await road({}, {"runs.changes": [failedRun("e1", "formula:local.digest")], "attention.changes": [failedItem("a1", "formula:local.digest", "e1")]})
      p.answers.press = answer
      tap(p, "digest failed")
      tap(p, "Retry run")
      assert.equal(await said(p), words)
    })
  }

  test("a completed run, a child run and a run no longer held offer no Retry", async () => {
    const p = await road({}, {
      "runs.changes": [{...failedRun("e2", "formula:local.two"), kind: "completed", error: null}, failedRun("e3", "formula:local.three", "e0")],
      "attention.changes": [failedItem("a2", "formula:local.two", "e2"), failedItem("a3", "formula:local.three", "e3"), failedItem("a4", "formula:local.four", "e4")],
    })
    for (const start of ["two failed", "three failed", "four failed"]) {
      tap(p, start)
      assert.ok(labels(p).includes("Open runs"), `${start}: ${labels(p).join(" | ")}`)
      assert.ok(!labels(p).includes("Retry run"), `${start} offers Retry`)
      tap(p, "Close")
    }
  })

  test("a resync followed by a picture without an item removes it", async () => {
    const p = await road({}, {"attention.changes": [failedItem("a1", "formula:local.one", "e1"), failedItem("a2", "formula:local.two", "e2")]})
    assert.ok(label(p, "2 waiting at your house"))
    push(p, "attention.changes", {event: "resync"}, {event: "attention.changes", data: {...failedItem("a1", "formula:local.one", "e1"), refresh: true, revision: 1}, revision: 1}, {event: "snapshot", at: iso(0)})
    assert.ok(label(p, "1 waiting at your house"), labels(p).join(" | "))
    assert.ok(!labels(p).some((l) => l.startsWith("two failed")))
  })

  test("a lower revision after a higher one changes nothing", async () => {
    const thread = {kind: "own", id: "t1", title: "New plan", people: [], last_activity: iso(-5), waits_on_you: false, unread: null}
    const p = await road({}, {"threads.changes": [{...thread, revision: 5}]})
    change(p, "threads.changes", {...thread, title: "Old plan"}, 3)
    change(p, "threads.changes", {...thread, title: "Same revision"}, 5)
    tap(p, "Post boxes")
    assert.ok(label(p, "New plan, "), labels(p).join(" | "))
    assert.equal(label(p, "Old plan"), "")
  })

  test("stale shows the picture as of its time until the next snapshot", async () => {
    const p = await road({}, {"threads.changes": []})
    push(p, "threads.changes", {event: "stale", at: "2026-11-10T14:20:00Z"})
    assert.match(label(p, "Post boxes"), /, as of 14:20$/)
    push(p, "threads.changes", {event: "snapshot", at: iso(0)})
    assert.doesNotMatch(label(p, "Post boxes"), /as of/)
  })

  test("unavailable keeps the picture and says when it tries again", async () => {
    const thread = {kind: "shared", id: "t1", title: "Trip", people: ["a", "b"], last_activity: iso(-5), waits_on_you: true, unread: 2}
    const p = await road({}, {"threads.changes": [thread]})
    push(p, "threads.changes", {event: "unavailable", data: {retry_at: "2026-11-10T14:21:00Z"}})
    assert.equal(label(p, "Post boxes"), "Post boxes: 1 thread, 1 waiting on you, 2 unread, trying again at 14:21")
  })

  test("denied ends the part: its picture cleared, and it says it is no longer granted", async () => {
    const thread = {kind: "shared", id: "t1", title: "Trip", people: ["a"], last_activity: iso(-5), waits_on_you: false, unread: 0}
    const p = await road({}, {"threads.changes": [thread]})
    push(p, "threads.changes", {event: "denied", data: {class: "forbidden", message: "The grant ended.", stage: "admission"}})
    p.subs["threads.changes"].end("denied")
    await settle()
    p.pump()
    assert.equal(label(p, "Post boxes"), "Post boxes: 0 threads, 0 waiting on you, 0 unread, no longer granted")
    assert.equal(p.opened.filter((k) => k === "threads.changes").length, 1)
    tap(p, "Post boxes")
    assert.equal(await said(p), "Threads. No longer granted. No threads yet.")
  })

  test("components.changes denied takes away the porters, not the visitors or their state", async () => {
    const installed = [{ref: "tincture:local.photos", name: "Photos", icon: null, open: false}]
    const p = await road({installed}, {
      "attention.changes": [failedItem("a1", "formula:local.digest", "e1")],
      "components.changes": [{kind: "installed", ref: "tincture:local.photos", type: "tincture", name: "photos", version: "1.0.0", update_available: false, grant_current: false}],
    })
    assert.ok(label(p, "Photos waits for your grant"))
    push(p, "components.changes", {event: "denied", data: {class: "forbidden", message: "The grant ended.", stage: "admission"}})
    assert.equal(label(p, "1 waiting at your house"), "1 waiting at your house. Open the list.")
    assert.ok(label(p, "digest failed"))
    assert.equal(label(p, "Photos waits for your grant"), "")
    assert.match(label(p, "Market"), /, no longer granted$/)
  })

  test("a hidden-then-shown desktop shows its parts live again, with no denied in between", async () => {
    const schedule = (id, name) => ({kind: "changed", schedule_id: id, name, status: "active", cron_expression: "0 9 * * *", next_run_at: iso(600), run_count: 1, error_count: 0})
    const thread = (id, title) => ({kind: "shared", id, title, people: ["a"], last_activity: iso(-5), waits_on_you: false, unread: 0})
    const p = await road({scale: 0.01}, {
      "attention.changes": [failedItem("a1", "formula:local.one", "e1"), failedItem("a2", "formula:local.two", "e2")],
      "schedules.changes": [schedule("s1", "Morning digest"), schedule("s2", "Backup")],
      "threads.changes": [thread("t1", "Trip"), thread("t2", "Notes")],
    })
    assert.ok(label(p, "2 waiting at your house") && label(p, "Bell tower: 2 schedules") && label(p, "Post boxes: 2 threads"))
    const opens = p.opened.length
    // hidden: the streams hear nothing at all, each handle suspended
    p.handlers.state("frozen")
    for (const sub of Object.values(p.subs)) sub.handle.state = "suspended"
    p.pump()
    await wait(50)
    // shown: the SDK opens each again itself, and each hears a fresh picture
    p.handlers.state("live")
    for (const sub of Object.values(p.subs)) sub.handle.state = "live"
    for (const [key, items] of [
      ["attention.changes", [failedItem("a1", "formula:local.uno", "e1")]],
      ["schedules.changes", [schedule("s1", "Morning news")]],
      ["threads.changes", [thread("t1", "Trip to Porto")]],
    ]) {
      push(p, key, {event: "resync"})
      picture(p, key, items)
    }
    await wait(50)
    p.pump()
    assert.equal(label(p, "1 waiting at your house"), "1 waiting at your house. Open the list.")
    assert.ok(label(p, "uno failed"))
    assert.ok(!labels(p).some((l) => l.startsWith("one failed") || l.startsWith("two failed")), labels(p).join(" | "))
    assert.equal(label(p, "Bell tower"), "Bell tower: 1 schedules")
    assert.equal(label(p, "Post boxes"), "Post boxes: 1 thread, 0 waiting on you, 0 unread")
    assert.ok(!labels(p).some((l) => /granted|as of|trying again|could not be read/.test(l)), labels(p).join(" | "))
    assert.equal(p.opened.length, opens)
    // the visitor the picture dropped did not wave goodbye: nothing was said of it settling
    assert.doesNotMatch(p.ids.live.textContent, /Settled/)
    tap(p, "Post boxes")
    assert.ok(label(p, "Trip to Porto, "))
    assert.equal(label(p, "Notes"), "")
  })

  test("a first open refused forbidden says not granted; one with no answer opens again after a pause", async () => {
    const p = await road({scale: 0.01, refuse: {"vault.changes": ["forbidden"], "system.changes": ["unavailable"]}})
    assert.match(label(p, "Strongroom"), /, not granted$/)
    assert.match(label(p, "Silo"), /, trying again at \d\d:\d\d$/)
    await wait(60)
    assert.equal(p.opened.filter((k) => k === "system.changes").length, 2)
    assert.equal(p.opened.filter((k) => k === "vault.changes").length, 1)
  })

  test("a stream the endpoint ended with no refusal opens again", async () => {
    const p = await road({scale: 0.01})
    p.subs["files.changes"].end("ended")
    await wait(60)
    assert.equal(p.opened.filter((k) => k === "files.changes").length, 2)
  })

  test("an approval opens AQUA; a failed run, schedule and offer open their pages", async () => {
    const p = await road({}, {
      "attention.changes": [
        {kind: "approval", id: "a1", label: "Trip", since: iso(-9), destination: {kind: "page", page: "aqua", ref: "th1"}},
        failedItem("a2", "formula:local.digest", "e9"),
        {kind: "failed_schedule", id: "a3", label: "Backup", since: iso(-8), destination: {kind: "page", page: "schedules", ref: "s1"}},
        {kind: "file_offer", id: "a4", label: "report.pdf", since: iso(-7), destination: {kind: "page", page: "files", ref: "o1"}},
        {kind: "confirmation", id: "a5", label: "Send mail", since: iso(-6), destination: {kind: "ref", page: null, ref: "c1"}},
      ],
    })
    for (const [visitor, choice] of [["Approval in Trip", "Open AQUA"], ["digest failed", "Open runs"], ["Backup failed", "Open schedules"], ["report.pdf offered", "Open files"]]) {
      tap(p, visitor)
      tap(p, choice)
      tap(p, "Close")
    }
    assert.deepEqual(p.calls.settings, ["aqua", "executions", "schedules", "files"])
    tap(p, "Confirm Send mail")
    assert.ok(!labels(p).some((l) => l.startsWith("Open")), labels(p).join(" | "))
  })

  test("a shared thread opens the chat and an own thread AQUA's panel", async () => {
    const p = await road({}, {
      "threads.changes": [
        {kind: "shared", id: "t1", title: "Trip", people: ["a", "b"], last_activity: iso(-5), waits_on_you: false, unread: 3},
        {kind: "own", id: "t2", title: "Notes", people: [], last_activity: iso(-9), waits_on_you: false, unread: null},
      ],
    })
    tap(p, "Post boxes")
    tap(p, "Trip, 3 unread")
    tap(p, "Notes, with AQUA")
    assert.deepEqual(p.calls.settings, ["chat", "aqua"])
  })

  test("files and offers reach the archive, and an offer's sender its visitor", async () => {
    const p = await road({document: {widgets: {files: {on: true}}}}, {
      "files.changes": [
        {kind: "file", id: "data/notes.md", name: "notes.md", type: "text/markdown", changed_at: iso(-5), from: null},
        {kind: "offer", id: "o1", name: "report.pdf", type: "application/pdf", changed_at: null, from: "Sam"},
      ],
      "attention.changes": [{kind: "file_offer", id: "a4", label: "report.pdf", since: iso(-7), destination: {kind: "page", page: "files", ref: "o1"}}],
    })
    assert.equal(label(p, "Archive"), "Archive: 1 recent files, 1 offer")
    assert.ok(label(p, "Sam offers report.pdf"))
    tap(p, "Archive")
    assert.ok(label(p, "report.pdf, offered by Sam"))
    assert.ok(label(p, "notes.md, text/markdown, changed "))
  })

  test("how CYFR stands reaches the silo and the crew house", async () => {
    const p = await road({}, {
      "system.changes": [{health: "ok", storage_used: 38e9, storage_cap: 100e9, model_connected: true, crew_ready: 2, crew_total: 3, version: "0.6.0", update_available: true}],
    })
    assert.equal(label(p, "Silo"), "Silo: how CYFR stands, all is well, storage 38 GB of 100 GB, an update is ready")
    assert.match(label(p, "Crew house"), /, 2 of 3 ready$/)
  })

  test("an app with an update shows it in the market; one whose grant is not current waits at the house", async () => {
    const installed = [{ref: "tincture:local.maps", name: "Maps", icon: null, open: false}, {ref: "tincture:local.photos", name: "Photos", icon: null, open: false}]
    const p = await road({installed}, {
      "components.changes": [
        {kind: "installed", ref: "tincture:local.maps", type: "tincture", name: "maps", version: "1.0.0", update_available: true, grant_current: true},
        {kind: "installed", ref: "tincture:local.photos", type: "tincture", name: "photos", version: "1.0.0", update_available: false, grant_current: false},
      ],
    })
    // a live reread kind says only that a fresh picture follows
    change(p, "components.changes", {kind: "installed", ref: "tincture:local.maps", type: "tincture", name: "maps", version: "1.1.0", update_available: null, grant_current: null}, 9)
    assert.equal(label(p, "Market"), "Market: 2 apps, 1 with an update")
    tap(p, "Photos waits for your grant")
    tap(p, "Review grant")
    assert.deepEqual(p.calls.grant, ["tincture:local.photos"])
  })
})

describe("the road desktop 0.2.0 draws", () => {
  const everything = {
    "attention.changes": [failedItem("a1", "formula:local.digest", "e1"), {kind: "approval", id: "a2", label: "Trip", since: iso(-300), destination: {kind: "page", page: "aqua", ref: "th1"}}],
    "schedules.changes": [{kind: "changed", schedule_id: "s1", name: "Morning digest", status: "active", cron_expression: "*/30 * * * *", next_run_at: iso(20), run_count: 3, error_count: 1}, {kind: "changed", schedule_id: "s2", name: "Backup", status: "paused", cron_expression: "0 2 * * *", next_run_at: null}],
    "schedule_runs.changes": [{kind: "failed", occurrence_id: "o1", schedule_id: "s1", execution_id: "e1", scheduled_for: iso(-30), reason: {class: "timeout", cause: "timed_out"}}, {kind: "fired", occurrence_id: "o2", schedule_id: "s1", execution_id: "e5", scheduled_for: iso(-60)}],
    "runs.changes": [failedRun("e1", "formula:local.digest"), {...failedRun("e2", "formula:local.notes"), kind: "started", ended_at: null, error: null, started_at: iso(-3)}, {...failedRun("e3", "formula:local.mail"), kind: "completed", error: null, started_at: iso(-90)}],
    "threads.changes": [{kind: "shared", id: "t1", title: "Trip", people: ["a", "b"], last_activity: iso(-5), waits_on_you: true, unread: 3}, {kind: "own", id: "t2", title: "Notes", people: [], last_activity: iso(-50), waits_on_you: false, unread: null}],
    "activity.changes": [{kind: "started", id: "j1", member: "explorer", asked_by: "Noor", title: "Compare ferry times", since: iso(-8), status: "running"}],
    "components.changes": [{kind: "installed", ref: "tincture:local.maps", type: "tincture", name: "maps", version: "1.0.0", update_available: true, grant_current: false}],
    "vault.changes": [{kind: "changed", name: "dropbox", type: "oauth", status: "needs_reauthorisation"}],
    "files.changes": [{kind: "file", id: "data/a.png", name: "a.png", type: "image/png", changed_at: iso(-4), from: null}, {kind: "offer", id: "o1", name: "b.pdf", type: "application/pdf", changed_at: null, from: "Sam"}],
    "system.changes": [{health: "low_storage", storage_used: 92e9, storage_cap: 100e9, model_connected: true, crew_ready: 1, crew_total: 6, version: "0.6.0", update_available: true}],
    "feed:weather": [{binding: "b1", feed: "weather", label: "Weather", result: {temp_c: 21, place: "Lisbon", sky: "clear", wind_kmh: 14, next_hours: [20, 19]}, actions: [{name: "refresh", label: "Refresh"}]}],
    "feed:vpn": [{binding: "b2", feed: "vpn", label: "VPN", result: {state: "connected", server: "lis-2", down_mbps: 84}, actions: []}],
  }
  const installed = [{ref: "tincture:local.maps", name: "Maps", icon: null, open: true}]

  for (const [width, height] of [
    [390, 844],
    [1024, 600],
    [1440, 900],
  ]) {
    test(`every part draws with every stream's data, and every card opens, with no fallback (${width}x${height})`, async () => {
      const p = await road({width, height, installed, document: {widgets: {files: {on: true}}}})
      const errors = []
      p.win.console = {...console, error: (...args) => errors.push(args.map(String).join(" "))}
      for (const [key, items] of Object.entries(everything)) picture(p, key, items)
      push(p, "vault.changes", {event: "stale", at: "2026-11-10T14:20:00Z"})
      push(p, "files.changes", {event: "unavailable", data: {retry_at: "2026-11-10T14:21:00Z"}})
      push(p, "system.changes", {event: "denied", data: {class: "forbidden", message: "gone", stage: "admission"}})
      // each tap opens its card in place of the one before
      for (const start of ["Post boxes", "Crew house", "Market", "Bell tower", "Press", "Barn", "Strongroom", "Silo", "Archive", "Weather in Lisbon", "Tram line", "Maps waits for your grant", "digest failed", "Plan the village"]) tap(p, start)
      p.ids.road.dispatch("keydown", {key: "PageDown"})
      p.ids.road.dispatch("keydown", {key: "Enter"})
      p.pump(5)
      assert.deepEqual(errors, [])
      assert.ok(p.win.document.documentElement.classList.contains("scene"), "the scene fell back to the plain list")
    })
  }

  for (const [width, height] of [
    [1024, 600],
    [390, 844],
  ]) {
    test(`the controls 0.2.0 adds are at least 44 by 44 CSS pixels (${width}x${height})`, async () => {
      const p = await road({width, height, installed, document: {widgets: {files: {on: true}}}})
      for (const [key, items] of Object.entries(everything)) picture(p, key, items)
      const big = (start) => {
        const h = hits(p).find((x) => x.label.startsWith(start))
        assert.ok(h && h.width >= 44 && h.height >= 44, `${start}: ${h && `${h.width}x${h.height}`}`)
      }
      for (const [card, choices] of [
        ["digest failed", ["Retry run", "Open runs"]],
        ["Approval in Trip", ["Open AQUA"]],
        ["Maps waits for your grant", ["Review grant"]],
        ["Silo", ["Open settings"]],
        ["Archive", ["Open files"]],
      ]) {
        big(card)
        tap(p, card)
        for (const choice of choices) big(choice)
      }
    })
  }

  test("the plain page lists the new parts too, says how each stands, and offers Retry", async () => {
    const p = await road({installed})
    for (const [key, items] of Object.entries(everything)) picture(p, key, items)
    push(p, "vault.changes", {event: "stale", at: "2026-11-10T14:20:00Z"})
    p.win.RoadList.show()
    const sections = p.ids.lists.children.filter((c) => c.tagName === "SECTION").map((sec) => {
      const [title, list] = sec.children
      return {title: title.textContent, items: (list.children || []).map((li) => ({text: li.textContent, buttons: li.children}))}
    })
    const titles = sections.map((sec) => sec.title)
    for (const title of ["Runs", "Files", "CYFR", "Vault (as of 14:20)"]) assert.ok(titles.includes(title), titles.join(" | "))
    const digest = sections.find((sec) => sec.title === "Runs").items.find((i) => i.text.startsWith("digest failed"))
    assert.deepEqual(digest.buttons.map((b) => b.textContent), ["Retry run"])
    digest.buttons[0].dispatch("click")
    await settle()
    assert.deepEqual(p.calls.press, [["retry-run", "e1"]])
    assert.ok(sections.find((sec) => sec.title === "CYFR").items.some((i) => i.text === "Storage: 92 GB of 100 GB"))
  })
})
