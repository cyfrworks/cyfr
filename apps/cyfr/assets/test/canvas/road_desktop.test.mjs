// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The road desktop (seed/components/tinctures/local/road): its own page files, run here as the
// page runs them, in a context of their own with a stand-in for window.cyfr, the few DOM calls
// the page makes and a 2D context that draws nothing. What it opens, and what its Plan offers.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

const VERSION = new URL("../../../../../seed/components/tinctures/local/road/0.1.0/", import.meta.url)
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
  dispatch(type) {
    for (const handler of this.listeners[type] || []) handler({stopPropagation() {}, preventDefault() {}})
  }
  setPointerCapture() {}
  getBoundingClientRect() {
    return {left: 0, top: 0, x: 0, y: 0, width: this.clientWidth, height: this.clientHeight}
  }
  getContext() {
    return context2d()
  }
}

// The page at `width` by `height` CSS pixels, its document served over `protocol`, the person's
// preferences `document`. Answers the context, the streams the page opened and a pump that runs
// the page's queued frames.
function page({width = 1024, height = 600, protocol = "http/1.1", document: prefs = {}, scripts = SCRIPTS} = {}) {
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
  let stored = {document: prefs, revision: 1}
  const cyfr = {
    get desktop() {
      return {prefs: stored, appearance: {mode: "dark", accent: "#36c9c0", locale: "en", time_zone: "UTC", safe_areas: {}}, person: {name: "Noor"}}
    },
    on(event, handler) {
      if (event === "state") handler("live")
      if (event === "posture") handler(width < 768 ? "hand" : "desk")
      return () => {}
    },
    stream(name, subject) {
      opened.push(subject ? `feed:${subject}` : name)
      return Promise.resolve({close() {}, closed: new Promise(() => {})})
    },
    async prefs({widgets}) {
      const document = {...stored.document, widgets: {...(stored.document.widgets || {}), ...widgets}}
      stored = {document, revision: stored.revision + 1}
      return {outcome: "saved", document, revision: stored.revision}
    },
    press: async () => ({outcome: "accepted"}),
    ask() {},
    settings() {},
    open() {},
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
    matchMedia: () => ({matches: false}),
    requestAnimationFrame: (f) => frames.push(f),
    addEventListener() {},
    setTimeout: (f, ms) => {
      const t = setTimeout(f, ms)
      t.unref()
      return t
    },
    clearTimeout,
  }
  win.window = win
  win.self = win
  const ctx = vm.createContext(win)
  for (const file of scripts) vm.runInContext(readFileSync(new URL(file, VERSION), "utf8"), ctx, {filename: file})
  let now = 1000
  const pump = (n = 3) => {
    for (let i = 0; i < n; i++) {
      const due = frames.splice(0)
      now += 100
      for (const f of due) f(now)
    }
  }
  return {win, ids, opened, pump}
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
