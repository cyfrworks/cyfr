// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import {AquaPanel, AquaPanelKeys, isToggle} from "../../js/aqua_panel/index.js"

// A window of `width` by `height`, with no document: no top bar and no
// button, so the area is the whole viewport.
let windowListeners
function screen(width, height) {
  windowListeners = {}
  globalThis.window = {
    innerWidth: width,
    innerHeight: height,
    addEventListener: (type, fn) => (windowListeners[type] = fn),
    removeEventListener: (type) => delete windowListeners[type]
  }
}
beforeEach(() => screen(1280, 800))
afterEach(() => delete globalThis.window)

// The panel as the server renders it: its data attributes, its style the
// hook writes, its listeners, its pointer capture, and the thread's menu
// (hidden) with the header's toggle.
function panel(dataset = {}) {
  const props = {}
  const listeners = {}
  let captured = null
  const menu = {hidden: true}
  const toggle = {attributes: {}, focused: false, setAttribute(k, v) { this.attributes[k] = v }, focus() { this.focused = true }}
  const el = {
    dataset: {docked: "false", ...dataset},
    style: {setProperty: (name, value) => (props[name] = value)},
    addEventListener: (type, fn) => (listeners[type] = fn),
    querySelector: (selector) =>
      selector === "#aqua-panel-pane-menu" ? menu : selector === "[data-aqua-menu-toggle]" ? toggle : null,
    setPointerCapture: (id) => (captured = id),
    hasPointerCapture: (id) => captured === id,
    releasePointerCapture: () => (captured = null)
  }
  const pushed = []
  const hook = Object.create(AquaPanel)
  Object.assign(hook, {el, pushEvent: (event, payload) => pushed.push({event, payload})})
  hook.mounted()

  const drawn = () => ({
    x: parseInt(props["--aqua-x"], 10),
    y: parseInt(props["--aqua-y"], 10),
    w: parseInt(props["--aqua-w"], 10),
    h: parseInt(props["--aqua-h"], 10)
  })
  const fire = (type, event) => listeners[type]({pointerId: 1, button: 0, preventDefault() {}, type, ...event})
  return {el, hook, pushed, drawn, fire, menu, toggle, captured: () => captured}
}

const TOGGLE = {closest: (selector) => (selector.includes("[data-aqua-menu-toggle]") ? {} : null)}
const IN_MENU = {closest: (selector) => (selector.includes("#aqua-panel-pane-menu") ? {} : null)}
const OUTSIDE = {closest: () => null}

// What a press lands on: an element inside the panel that answers
// `closest` for the selectors it matches.
function target(...matches) {
  return {closest: (selector) => (selector.split(", ").some((s) => matches.includes(s)) ? {dataset: {}} : null)}
}

function edge(which) {
  const box = {dataset: {aquaEdge: which}}
  return {closest: (selector) => (selector === "[data-aqua-edge]" || selector.includes("[data-aqua-edge]") ? box : null)}
}

const GRIP = target("[data-aqua-grip]")
const HANDLE = target("[data-aqua-handle]")

function gesture(p, on, from, to, end = "pointerup") {
  p.fire("pointerdown", {target: on, clientX: from[0], clientY: from[1]})
  p.fire("pointermove", {clientX: to[0], clientY: to[1]})
  p.fire(end, {clientX: to[0], clientY: to[1]})
}

describe("on the desk", () => {
  test("opens where the server kept it, brought inside the viewport", () => {
    assert.deepEqual(panel({x: "100", y: "100", w: "400", h: "500"}).drawn(), {x: 100, y: 100, w: 400, h: 500})
    assert.deepEqual(panel({x: "5000", y: "5000", w: "400", h: "500"}).drawn(), {x: 880, y: 300, w: 400, h: 500})
  })

  test("a header drag moves it under pointer capture and sends the settled placement once", () => {
    const p = panel({x: "100", y: "100", w: "400", h: "500"})
    p.fire("pointerdown", {target: GRIP, clientX: 200, clientY: 120})
    assert.equal(p.captured(), 1)
    // The value the stylesheet shows the shield over every frame for.
    assert.equal(p.el.dataset.aquaMoving, "drag")
    p.fire("pointermove", {clientX: 260, clientY: 150})
    assert.deepEqual(p.drawn(), {x: 160, y: 130, w: 400, h: 500})
    assert.deepEqual(p.pushed, [], "nothing is sent mid-drag")
    p.fire("pointerup", {clientX: 300, clientY: 160})
    assert.equal(p.captured(), null)
    assert.equal(p.el.dataset.aquaMoving, undefined)
    assert.deepEqual(p.pushed, [{event: "place", payload: {x: 200, y: 140, w: 400, h: 500}}])
  })

  test("a press on a header control is not a drag", () => {
    const p = panel({x: "100", y: "100", w: "400", h: "500"})
    gesture(p, target("[data-aqua-grip]", "select"), [200, 120], [260, 150])
    assert.deepEqual(p.drawn(), {x: 100, y: 100, w: 400, h: 500})
    assert.deepEqual(p.pushed, [])
  })

  test("an edge resizes it, and a resize below the minimum stops there", () => {
    const p = panel({x: "100", y: "100", w: "400", h: "500"})
    p.fire("pointerdown", {target: edge("se"), clientX: 500, clientY: 600})
    assert.equal(p.el.dataset.aquaMoving, "resize-se")
    p.fire("pointermove", {clientX: 300, clientY: 300})
    p.fire("pointerup", {clientX: 300, clientY: 300})
    assert.deepEqual(p.pushed, [{event: "place", payload: {x: 100, y: 100, w: 300, h: 360}}])
  })

  test("a cancelled gesture puts the panel back and sends nothing", () => {
    const p = panel({x: "100", y: "100", w: "400", h: "500"})
    gesture(p, GRIP, [200, 120], [400, 400], "pointercancel")
    assert.deepEqual(p.drawn(), {x: 100, y: 100, w: 400, h: 500})
    assert.deepEqual(p.pushed, [])
  })

  test("docked, it stands against the right edge and sizes from its left edge alone", () => {
    const p = panel({x: "100", y: "100", w: "400", h: "500", docked: "true"})
    assert.deepEqual(p.drawn(), {x: 880, y: 0, w: 400, h: 800})
    gesture(p, GRIP, [900, 10], [500, 300])
    gesture(p, edge("n"), [1000, 0], [1000, 300])
    assert.deepEqual(p.pushed, [], "no drag and no other edge while docked")
    gesture(p, edge("w"), [880, 300], [780, 300])
    assert.deepEqual(p.drawn(), {x: 780, y: 0, w: 500, h: 800})
    assert.deepEqual(p.pushed, [{event: "place", payload: {x: 100, y: 100, w: 500, h: 500}}])
  })

  test("undocked by the server, it floats where it was kept", () => {
    const p = panel({x: "100", y: "100", w: "400", h: "500", docked: "true"})
    p.el.dataset.docked = "false"
    p.hook.updated()
    assert.deepEqual(p.drawn(), {x: 100, y: 100, w: 400, h: 500})
  })

  test("a smaller window brings it inside", () => {
    const p = panel({x: "800", y: "200", w: "400", h: "500"})
    window.innerWidth = 1000
    window.innerHeight = 600
    windowListeners.resize()
    assert.deepEqual(p.drawn(), {x: 600, y: 100, w: 400, h: 500})
  })
})

describe("Escape", () => {
  test("from anywhere inside closes the panel, unless something inside took it", () => {
    const p = panel()
    let prevented = false
    p.fire("keydown", {key: "Escape", preventDefault: () => (prevented = true)})
    p.fire("keydown", {key: "Escape", defaultPrevented: true})
    p.fire("keydown", {key: "Escape", isComposing: true})
    p.fire("keydown", {key: "Enter"})
    assert.equal(prevented, true)
    assert.deepEqual(p.pushed, [{event: "close", payload: {}}])
  })

  test("with the thread's menu open, closes the menu alone and gives focus to its toggle", () => {
    const p = panel()
    p.fire("click", {target: TOGGLE})
    p.fire("keydown", {key: "Escape"})
    assert.equal(p.menu.hidden, true)
    assert.equal(p.toggle.focused, true)
    assert.deepEqual(p.pushed, [])
  })
})

describe("the thread's menu", () => {
  test("opens and closes from the header's toggle, which says so", () => {
    const p = panel()
    p.fire("click", {target: TOGGLE})
    assert.equal(p.menu.hidden, false)
    assert.equal(p.toggle.attributes["aria-expanded"], "true")
    p.fire("click", {target: TOGGLE})
    assert.equal(p.menu.hidden, true)
    assert.equal(p.toggle.attributes["aria-expanded"], "false")
  })

  test("a press outside it closes it; a press inside it or on the toggle does not", () => {
    const p = panel()
    p.fire("click", {target: TOGGLE})
    windowListeners.pointerdown({target: IN_MENU})
    windowListeners.pointerdown({target: TOGGLE})
    assert.equal(p.menu.hidden, false)
    windowListeners.pointerdown({target: OUTSIDE})
    assert.equal(p.menu.hidden, true)
  })

  test("the window losing focus, to a frame whose presses the page never hears, closes it", () => {
    const p = panel()
    p.fire("click", {target: TOGGLE})
    windowListeners.blur()
    assert.equal(p.menu.hidden, true)
  })

  test("the command palette opening closes it", () => {
    let observed = null
    const palette = {dataset: {open: "false"}}
    globalThis.document = {getElementById: (id) => (id === "command-palette" ? palette : null), addEventListener() {}, removeEventListener() {}}
    globalThis.MutationObserver = class {
      constructor(callback) { this.callback = callback }
      observe(el, options) { observed = {el, options, callback: this.callback} }
      disconnect() {}
    }
    try {
      const p = panel()
      assert.equal(observed.el, palette)
      p.fire("click", {target: TOGGLE})
      observed.callback()
      assert.equal(p.menu.hidden, false, "a change that leaves the palette closed leaves the menu")
      palette.dataset.open = "true"
      observed.callback()
      assert.equal(p.menu.hidden, true)
    } finally {
      delete globalThis.document
      delete globalThis.MutationObserver
    }
  })
})

describe("an interrupted gesture", () => {
  const KEPT = {x: "100", y: "100", w: "400", h: "500"}

  // A drag under way, 60 by 30 from where it started.
  function dragging() {
    const p = panel(KEPT)
    p.fire("pointerdown", {target: GRIP, clientX: 200, clientY: 120})
    p.fire("pointermove", {clientX: 260, clientY: 150})
    assert.equal(p.el.dataset.aquaMoving, "drag")
    assert.deepEqual(p.drawn(), {x: 160, y: 130, w: 400, h: 500})
    return p
  }

  // The shield is down, the panel back where it was, nothing sent, and the
  // next drag settles and is sent.
  function recovered(p) {
    assert.equal(p.el.dataset.aquaMoving, undefined)
    assert.equal(p.captured(), null)
    assert.deepEqual(p.drawn(), {x: 100, y: 100, w: 400, h: 500})
    assert.deepEqual(p.pushed, [])
    p.fire("pointerdown", {target: GRIP, pointerId: 2, clientX: 150, clientY: 120})
    p.fire("pointermove", {pointerId: 2, clientX: 200, clientY: 170})
    p.fire("pointerup", {pointerId: 2, clientX: 200, clientY: 170})
    assert.deepEqual(p.pushed, [{event: "place", payload: {x: 150, y: 150, w: 400, h: 500}}])
  }

  for (const [name, interrupt] of [
    ["is cancelled", (p) => p.fire("pointercancel", {})],
    ["loses its capture", (p) => p.fire("lostpointercapture", {})],
    ["loses the window's focus", () => windowListeners.blur()],
    ["has its socket drop", (p) => p.hook.disconnected()]
  ]) {
    test(`ends when it ${name}`, () => {
      const p = dragging()
      interrupt(p)
      recovered(p)
    })
  }

  test("ends when the page is hidden", () => {
    let onVisibility = null
    globalThis.document = {
      visibilityState: "visible",
      getElementById: () => null,
      addEventListener: (type, fn) => type === "visibilitychange" && (onVisibility = fn),
      removeEventListener() {}
    }
    try {
      const p = dragging()
      onVisibility()
      assert.equal(p.el.dataset.aquaMoving, "drag", "visible again is no interruption")
      globalThis.document.visibilityState = "hidden"
      onVisibility()
      recovered(p)
    } finally {
      delete globalThis.document
    }
  })

  test("a cancel of another pointer leaves it running", () => {
    const p = dragging()
    p.fire("pointercancel", {pointerId: 9})
    assert.equal(p.el.dataset.aquaMoving, "drag")
  })

  test("a release anywhere, outside the window included, settles it", () => {
    const p = dragging()
    windowListeners.pointerup({pointerId: 1, clientX: 300, clientY: 160})
    assert.equal(p.el.dataset.aquaMoving, undefined)
    assert.deepEqual(p.pushed, [{event: "place", payload: {x: 200, y: 140, w: 400, h: 500}}])
    assert.equal(windowListeners.pointerup, undefined, "the release listener goes with the gesture")
  })

  test("a pull in the hand ends at its level", () => {
    screen(390, 800)
    const p = panel()
    p.fire("pointerdown", {target: HANDLE, clientX: 195, clientY: 205})
    p.fire("pointermove", {clientX: 195, clientY: 60})
    windowListeners.blur()
    assert.deepEqual(p.drawn(), {x: 0, y: 200, w: 390, h: 600})
    assert.deepEqual(p.pushed, [])
  })
})

describe("in the hand", () => {
  beforeEach(() => screen(390, 800))

  test("a sheet at three-quarters height from the bottom, with no drag or edge", () => {
    const p = panel({x: "100", y: "100", w: "400", h: "500", docked: "true"})
    assert.deepEqual(p.drawn(), {x: 0, y: 200, w: 390, h: 600})
    gesture(p, GRIP, [200, 220], [100, 100])
    gesture(p, edge("se"), [380, 790], [200, 500])
    assert.deepEqual(p.drawn(), {x: 0, y: 200, w: 390, h: 600})
    assert.deepEqual(p.pushed, [])
  })

  test("its handle pulls it to full height and back", () => {
    const p = panel()
    gesture(p, HANDLE, [195, 205], [195, 60])
    assert.deepEqual(p.drawn(), {x: 0, y: 0, w: 390, h: 800})
    gesture(p, HANDLE, [195, 5], [195, 200])
    assert.deepEqual(p.drawn(), {x: 0, y: 200, w: 390, h: 600})
    assert.deepEqual(p.pushed, [])
  })

  test("pulled down, it closes", () => {
    const p = panel()
    gesture(p, HANDLE, [195, 205], [195, 500])
    assert.deepEqual(p.pushed, [{event: "close", payload: {}}])
  })
})

describe("Ctrl+J", () => {
  const key = (event) => ({ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, key: "j", ...event})

  test("is Ctrl and J alone", () => {
    assert.equal(isToggle(key({ctrlKey: true})), true)
    assert.equal(isToggle(key({ctrlKey: true, key: "J"})), true)
    assert.equal(isToggle(key({})), false)
    assert.equal(isToggle(key({metaKey: true})), false)
    assert.equal(isToggle(key({ctrlKey: true, shiftKey: true})), false)
    assert.equal(isToggle(key({ctrlKey: true, altKey: true})), false)
    assert.equal(isToggle(key({ctrlKey: true, key: "k"})), false)
  })

  test("sends toggle and keeps the browser's own binding off it", () => {
    const pushed = []
    const hook = Object.create(AquaPanelKeys)
    Object.assign(hook, {el: {querySelector: () => null}, pushEvent: (event) => pushed.push(event)})
    hook.mounted()
    let prevented = false
    windowListeners.keydown(key({ctrlKey: true, preventDefault: () => (prevented = true)}))
    windowListeners.keydown(key({preventDefault: () => assert.fail("a plain j is the page's")}))
    assert.deepEqual(pushed, ["toggle"])
    assert.equal(prevented, true)
    hook.destroyed()
    assert.equal(windowListeners.keydown, undefined)
  })
})
