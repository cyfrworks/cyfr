// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import Canvas from "../../js/canvas/index.js"
import {windowChord} from "../../js/canvas/signals.js"

const WIN = "frm_window00001"
const OTHER = "frm_window00002"
const TILE = "frm_tile0000001"
const CANVAS = "frm_canvas00001"

// The apps' area stands at (0, 48) in the page, 1600 by 900.
const AREA = {left: 0, top: 48, width: 1600, height: 900}

let listeners
beforeEach(() => {
  listeners = {}
  globalThis.window = {
    innerWidth: 1600,
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type) => delete listeners[type]
  }
})
afterEach(() => {
  delete globalThis.window
  delete globalThis.document
})

// An element the hook creates in the geometry host: the shield, its preview.
function created() {
  return {hidden: false, dataset: {}, style: {}, children: [], appendChild(child) { this.children.push(child) }}
}

// An app's wrapper as the server renders it, at `box` in the area.
function wrapper(frame, {place = "window", box, active = false, ...data} = {}) {
  return {
    id: `canvas-frame-${frame}`,
    dataset: {canvasFrame: frame, canvasPlace: place, canvasActive: String(active), canvasShown: "true", ...data},
    getBoundingClientRect: () => ({left: AREA.left + box.x, top: AREA.top + box.y, width: box.width, height: box.height})
  }
}

// The canvas layer: its frames container, geometry host and wrappers, and
// the shelf's canvas dots.
function layerOf({wrappers = [], dots = []} = {}) {
  const events = new EventTarget()
  const style = {textContent: "", isConnected: true}
  const host = {children: [], appendChild(child) { this.children.push(child) }}
  const container = {getBoundingClientRect: () => ({...AREA})}
  const marker = {dataset: {}, hidden: true}
  const ownerDocument = {createElement: (tag) => (tag === "style" ? style : created())}

  const layer = {
    id: "canvas",
    ownerDocument,
    getBoundingClientRect: () => ({width: 1600, height: 952}),
    querySelector(selector) {
      if (selector === "#canvas-geometry") return host
      if (selector === "#canvas-frames") return container
      if (selector === "#canvas-status [data-canvas-connection]") return marker
      if (selector === '[data-canvas-frame][data-canvas-active="true"]') {
        return wrappers.find((w) => w.dataset.canvasActive === "true") ?? null
      }
      if (selector === '[data-canvas-place="canvas"][data-canvas-shown="true"]') {
        return wrappers.find((w) => w.dataset.canvasPlace === "canvas") ?? null
      }
      return null
    },
    querySelectorAll(selector) {
      if (selector === "#canvas-switcher button[data-canvas]") return dots.map((canvas) => ({dataset: {canvas}}))
      return []
    },
    addEventListener: (type, fn) => events.addEventListener(type, fn),
    removeEventListener: (type, fn) => events.removeEventListener(type, fn),
    dispatch: (event) => events.dispatchEvent(event),
    style,
    host
  }
  layer.hook = {id: "canvas-hook", parentElement: layer, dataset: {posture: "desk"}, ownerDocument}
  return layer
}

function mount(layer) {
  const pushed = []
  const replies = []
  const hook = Object.assign(Object.create(Canvas), {
    el: layer.hook,
    pushEventTo() {},
    pushEvent: (event, payload, onReply) => {
      pushed.push({event, payload})
      if (onReply) replies.push(onReply)
    },
    handleEvent() {}
  })
  hook.mounted()
  return {hook, pushed, replies}
}

// What a press lands on in `wrapper`: its title bar, an edge, or a control.
function on(w, part, edge = null) {
  let captured = null
  return {
    closest(selector) {
      if (selector === "[data-canvas-frame]") return w
      if (selector === "[data-canvas-grip]") return part === "grip" ? {} : null
      if (selector === "[data-canvas-edge]") return part === "edge" ? {dataset: {canvasEdge: edge}} : null
      if (selector === "button, a, input, select, textarea") return part === "control" ? {} : null
      return null
    },
    setPointerCapture: (id) => (captured = id),
    hasPointerCapture: (id) => captured === id,
    releasePointerCapture: () => (captured = null),
    captured: () => captured
  }
}

function pointer(layer, type, target, x, y, pointerId = 1) {
  const event = new Event(type)
  Object.assign(event, {button: 0, clientX: x, clientY: y, pointerId})
  Object.defineProperty(event, "target", {value: target})
  layer.dispatch(event)
}

// A drag from (x, y) to (x + dx, y + dy), released there.
function drag(layer, target, [x, y], [dx, dy], end = "pointerup") {
  pointer(layer, "pointerdown", target, x, y)
  pointer(layer, "pointermove", target, x + dx / 2, y + dy / 2)
  pointer(layer, "pointermove", target, x + dx, y + dy)
  if (end) pointer(layer, end, target, x + dx, y + dy)
}

const shield = (layer) => layer.host.children.find((child) => child !== layer.style)

describe("a window dragged by its title bar", () => {
  test("follows the pointer behind a shield, held over the server's style, and settles as one frame_move", () => {
    const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true, canvasTileShare: "3000"})
    const layer = layerOf({wrappers: [w]})
    const {pushed, replies} = mount(layer)
    const grip = on(w, "grip")

    // A press of a pixel or two is a click: no shield, nothing held.
    pointer(layer, "pointerdown", grip, 200, 120)
    pointer(layer, "pointermove", grip, 202, 121)
    assert.equal(shield(layer), undefined)
    assert.equal(layer.style.textContent, "")

    pointer(layer, "pointermove", grip, 300, 170)
    assert.equal(shield(layer).hidden, false)
    assert.equal(shield(layer).dataset.gesture, "drag")
    assert.equal(grip.captured(), 1)
    assert.equal(
      layer.style.textContent,
      `#canvas-frame-${WIN}{left:200px!important;top:100px!important;width:480px!important;height:360px!important}`
    )
    assert.deepEqual(pushed, [], "nothing is sent mid-drag")

    pointer(layer, "pointerup", grip, 300, 170)
    assert.equal(shield(layer).hidden, true)
    assert.equal(grip.captured(), null)
    assert.deepEqual(pushed, [{event: "frame_move", payload: {frame: WIN, geometry: {x: 1250, y: 1111, w: 3000, h: 4000}}}])

    // Held until the shell answers, then the server's style again.
    assert.notEqual(layer.style.textContent, "")
    replies[0]({ok: true})
    assert.equal(layer.style.textContent, "")
  })

  test("a press on a window that is not the active one raises it, and a click sends nothing more", () => {
    const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)
    drag(layer, on(w, "grip"), [200, 120], [0, 0])
    assert.deepEqual(pushed, [{event: "frame_raise", payload: {frame: WIN}}])
  })

  test("a press on a control of the title bar is the control's", () => {
    const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)
    drag(layer, on(w, "control"), [200, 120], [100, 100])
    assert.deepEqual(pushed, [])
  })

  test("is kept with its title bar on screen", () => {
    const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)
    // Far down: its title bar stops above the bottom. (Far right, the
    // pointer reaches the edge first and the window becomes a tile.)
    drag(layer, on(w, "grip"), [200, 120], [1300, 3000])
    assert.deepEqual(pushed[0].payload.geometry, {x: 8750, y: 9622, w: 3000, h: 4000})
  })

  test("dropped at the left or right edge becomes a tile there at its share, at the top full; the shield shows it first", () => {
    const w = wrapper(WIN, {box: {x: 400, y: 200, width: 480, height: 360}, active: true, canvasTileShare: "3000"})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)

    pointer(layer, "pointerdown", on(w, "grip"), 500, 260)
    pointer(layer, "pointermove", on(w, "grip"), 8, 400)
    const preview = shield(layer).children[0]
    assert.equal(preview.hidden, false)
    assert.deepEqual(preview.style, {left: "0px", top: "48px", width: "480px", height: "900px"})
    pointer(layer, "pointerup", on(w, "grip"), 8, 400)

    drag(layer, on(w, "grip"), [500, 260], [1095, 140])
    drag(layer, on(w, "grip"), [500, 260], [100, -250])

    assert.deepEqual(pushed, [
      {event: "frame_tile", payload: {frame: WIN, side: "left", share: 3000}},
      {event: "frame_tile", payload: {frame: WIN, side: "right", share: 3000}},
      {event: "frame_full", payload: {frame: WIN}}
    ])
  })

  test("a double click on its title bar makes it full", () => {
    const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)
    pointer(layer, "dblclick", on(w, "control"), 200, 60)
    pointer(layer, "dblclick", on(w, "grip"), 200, 60)
    assert.deepEqual(pushed, [{event: "frame_full", payload: {frame: WIN}}])
  })
})

describe("a resize", () => {
  test("from a corner settles as one frame_resize, no smaller than the minimum", () => {
    const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)
    drag(layer, on(w, "edge", "se"), [580, 458], [80, 90])
    drag(layer, on(w, "edge", "se"), [580, 458], [-1000, -1000])
    assert.equal(shield(layer).hidden, true)
    assert.deepEqual(pushed, [
      {event: "frame_resize", payload: {frame: WIN, geometry: {x: 625, y: 556, w: 3500, h: 5000}}},
      {event: "frame_resize", payload: {frame: WIN, geometry: {x: 625, y: 556, w: 1500, h: 1778}}}
    ])
  })

  test("of a tile's divider settles as its share, the canvas beside it held narrower meanwhile", () => {
    const tile = wrapper(TILE, {place: "tile", box: {x: 1200, y: 0, width: 400, height: 900}, canvasSide: "right", canvasShare: "2500"})
    const canvas = wrapper(CANVAS, {place: "canvas", box: {x: 0, y: 0, width: 1200, height: 900}})
    const layer = layerOf({wrappers: [tile, canvas]})
    const {pushed} = mount(layer)

    drag(layer, on(tile, "edge", "w"), [1200, 400], [-100, 0], null)
    assert.equal(shield(layer).dataset.gesture, "divider")
    assert.match(layer.style.textContent, new RegExp(`#canvas-frame-${TILE}\\{left:1100px!important;width:500px!important\\}`))
    assert.match(layer.style.textContent, new RegExp(`#canvas-frame-${CANVAS}\\{left:0px!important;width:1100px!important\\}`))
    pointer(layer, "pointerup", on(tile, "edge", "w"), 1100, 400)

    assert.deepEqual(pushed, [{event: "frame_resize", payload: {frame: TILE, share: 3125}}])
  })
})

describe("an interrupted gesture", () => {
  const box = {x: 100, y: 50, width: 480, height: 360}

  for (const [name, interrupt] of [
    ["is cancelled", (layer, target) => pointer(layer, "pointercancel", target, 300, 170)],
    ["loses its capture", (layer, target) => pointer(layer, "lostpointercapture", target, 300, 170)],
    ["loses the window's focus", () => listeners.blur()],
    ["has its socket drop", (_layer, _target, hook) => hook.disconnected()]
  ]) {
    test(`ends with nothing sent and the window where it was when it ${name}`, () => {
      const w = wrapper(WIN, {box, active: true})
      const layer = layerOf({wrappers: [w]})
      const {hook, pushed} = mount(layer)
      const grip = on(w, "grip")
      drag(layer, grip, [200, 120], [100, 50], null)
      assert.notEqual(layer.style.textContent, "")

      interrupt(layer, grip, hook)
      assert.equal(shield(layer).hidden, true)
      assert.equal(layer.style.textContent, "")
      assert.equal(grip.captured(), null)
      assert.deepEqual(pushed, [])
      assert.equal(listeners.pointerup, undefined, "the release listener goes with the gesture")
    })
  }

  test("a cancel of another pointer leaves it running, and a release outside the window settles it", () => {
    const w = wrapper(WIN, {box, active: true})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)
    drag(layer, on(w, "grip"), [200, 120], [100, 50], null)
    pointer(layer, "pointercancel", on(w, "grip"), 0, 0, 9)
    assert.equal(shield(layer).hidden, false)

    listeners.pointerup({pointerId: 1, clientX: 300, clientY: 170})
    assert.deepEqual(pushed.map((p) => p.event), ["frame_move"])
  })

  test("the socket dropping also lets go of a wrapper still waiting for the shell's answer", () => {
    const w = wrapper(WIN, {box, active: true})
    const layer = layerOf({wrappers: [w]})
    const {hook} = mount(layer)
    drag(layer, on(w, "grip"), [200, 120], [100, 50])
    assert.notEqual(layer.style.textContent, "")
    hook.disconnected()
    assert.equal(layer.style.textContent, "")
  })
})

describe("in the hand", () => {
  test("no window is dragged or resized", () => {
    globalThis.window.innerWidth = 600
    const w = wrapper(WIN, {box: {x: 0, y: 0, width: 600, height: 800}, active: true})
    const layer = layerOf({wrappers: [w]})
    const {pushed} = mount(layer)
    drag(layer, on(w, "grip"), [100, 60], [100, 100])
    drag(layer, on(w, "edge", "se"), [590, 790], [-100, -100])
    assert.deepEqual(pushed, [])
  })
})

describe("focus moving into an app's frame", () => {
  test("raises that window or tile when it is not the active one", async () => {
    const w = wrapper(WIN, {box: {x: 0, y: 0, width: 400, height: 400}, active: true})
    const other = wrapper(OTHER, {box: {x: 500, y: 0, width: 400, height: 400}})
    const layer = layerOf({wrappers: [w, other]})
    const {pushed} = mount(layer)
    const iframeIn = (wrap) => ({tagName: "IFRAME", closest: () => wrap})

    globalThis.document = {activeElement: iframeIn(other)}
    listeners.blur()
    await new Promise((resolve) => setTimeout(resolve, 0))
    globalThis.document = {activeElement: iframeIn(w)}
    listeners.blur()
    await new Promise((resolve) => setTimeout(resolve, 0))

    assert.deepEqual(pushed, [{event: "frame_raise", payload: {frame: OTHER}}])
  })
})

describe("the keys", () => {
  const press = (keys) => {
    let prevented = false
    listeners.keydown({ctrlKey: true, altKey: true, ...keys, preventDefault: () => (prevented = true)})
    return prevented
  }

  test("act on the active window: tile at either side, full, minimise and close", () => {
    const w = wrapper(WIN, {box: {x: 0, y: 0, width: 400, height: 400}, active: true, canvasTileShare: "2800"})
    const {pushed} = mount(layerOf({wrappers: [w]}))
    press({key: "ArrowLeft"})
    press({key: "ArrowRight"})
    press({key: "ArrowUp"})
    press({key: "ArrowDown"})
    press({key: "m", code: "KeyM"})
    press({key: "w", code: "KeyW"})
    assert.deepEqual(pushed, [
      {event: "frame_tile", payload: {frame: WIN, side: "left", share: 2800}},
      {event: "frame_tile", payload: {frame: WIN, side: "right", share: 2800}},
      {event: "frame_full", payload: {frame: WIN}},
      {event: "frame_minimise", payload: {frame: WIN}},
      {event: "frame_close", payload: {frame: WIN}}
    ])
  })

  test("ArrowDown makes the active tile or full app a window where the server says it stands", () => {
    const tile = wrapper(TILE, {
      place: "tile",
      box: {x: 0, y: 0, width: 400, height: 900},
      active: true,
      canvasShare: "2500",
      canvasWindow: "200 800 3000 7000"
    })
    const {pushed} = mount(layerOf({wrappers: [tile]}))
    press({key: "ArrowDown"})
    press({key: "ArrowRight"})
    assert.deepEqual(pushed, [
      {event: "frame_move", payload: {frame: TILE, geometry: {x: 200, y: 800, w: 3000, h: 7000}}},
      {event: "frame_tile", payload: {frame: TILE, side: "right", share: 2500}}
    ])
  })

  test("with no active app the arrows switch canvases; 1 to 8 show that canvas", () => {
    const {pushed} = mount(layerOf({dots: ["home", "work", "play"]}))
    assert.equal(press({key: "ArrowLeft"}), true)
    press({key: "ArrowRight"})
    press({key: "2", code: "Digit2"})
    press({key: "8", code: "Digit8"})
    press({key: "ArrowUp"})
    assert.deepEqual(pushed, [
      {event: "switch_canvas", payload: {direction: "previous"}},
      {event: "switch_canvas", payload: {direction: "next"}},
      {event: "switch_canvas", payload: {canvas: "work"}}
    ])
  })

  test("a key that is no chord is the page's", () => {
    const {pushed} = mount(layerOf())
    assert.equal(press({key: "ArrowLeft", shiftKey: true}), false)
    assert.equal(press({key: "x", code: "KeyX"}), false)
    assert.equal(press({key: "9", code: "Digit9"}), false)
    assert.deepEqual(pushed, [])
  })

  test("the chord's grammar", () => {
    const chord = (keys) => windowChord({ctrlKey: true, altKey: true, ...keys})
    assert.deepEqual(chord({key: "ArrowLeft"}), {act: "tile", side: "left"})
    assert.deepEqual(chord({key: "ArrowUp"}), {act: "full"})
    assert.deepEqual(chord({key: "ArrowDown"}), {act: "window"})
    // By code, so Alt's own characters change nothing.
    assert.deepEqual(chord({key: "µ", code: "KeyM"}), {act: "minimise"})
    assert.deepEqual(chord({key: "∑", code: "KeyW"}), {act: "close"})
    assert.deepEqual(chord({key: "¡", code: "Digit1"}), {act: "canvas", index: 0})
    assert.equal(chord({key: "ArrowLeft", metaKey: true}), null)
    assert.equal(windowChord({key: "ArrowLeft", ctrlKey: true}), null)
    assert.equal(windowChord(null), null)
  })
})
