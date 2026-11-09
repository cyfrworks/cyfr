// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The shipped line desktop (seed/components/tinctures/local/line): its page
// run as the browser runs it, in a context of its own, against a stand-in
// for window.cyfr and the few parts of the document it touches; and what
// its stylesheet holds its controls to.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

const VERSION = new URL("../../../../../seed/components/tinctures/local/line/0.1.0/", import.meta.url)
const source = readFileSync(new URL("app.js", VERSION), "utf8")
const stylesheet = readFileSync(new URL("style.css", VERSION), "utf8")

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

// Each declaration of a rule whose selectors name `selector`, in the order
// the stylesheet has them, @media rules included.
function declarations(selector) {
  const css = stylesheet.replace(/\/\*[\s\S]*?\*\//g, "")
  const found = []
  for (const [, selectors, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (!selectors.split(",").some((s) => s.trim() === selector)) continue
    for (const declaration of body.split(";")) {
      const at = declaration.indexOf(":")
      if (at !== -1) found.push([declaration.slice(0, at).trim(), declaration.slice(at + 1).trim()])
    }
  }
  return found
}

test("main_controls_meet_44px", () => {
  const SIZES = ["height", "min-height", "width", "min-width"]
  const controls = [".btn", ".btn.sm", ".ib", ".row-btn", ".switch", ".chip", ".link"]
  for (const control of controls) {
    for (const [property, value] of declarations(control)) {
      const px = /^(\d+)px$/.exec(value)
      if (SIZES.includes(property) && px) assert.ok(Number(px[1]) >= 44, `${control} ${property}: ${value}`)
    }
  }

  // Each stands at least 44 pixels high of its own (a small button is a
  // button's height), and the square ones as wide.
  const tall = (control) =>
    declarations(control).some(([p, v]) => ["height", "min-height"].includes(p) && parseInt(v, 10) >= 44)
  for (const control of controls.filter((c) => c !== ".btn.sm")) assert.ok(tall(control), `${control} has no 44px height`)
  for (const control of [".btn", ".ib", ".switch", ".link"]) {
    assert.ok(
      declarations(control).some(([p, v]) => ["width", "min-width"].includes(p) && parseInt(v, 10) >= 44),
      `${control} has no 44px width`
    )
  }
})
