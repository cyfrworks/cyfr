// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, test} from "node:test"

import Canvas from "../../js/canvas/index.js"

// One arrangement event per settled gesture, and an answer that releases
// only what its own gesture holds: a press raises nothing until it settles
// as a click, a drag sends its move alone, and a late answer to one gesture
// never moves what a newer one holds.

const WIN = "frm_window00001"
const TILE = "frm_tile0000001"

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


test("an inactive window's cancelled drag sends no arrangement event", () => {
  const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}})
  const layer = layerOf({wrappers: [w]})
  const {pushed} = mount(layer)
  drag(layer, on(w, "grip"), [200, 120], [100, 50], "pointercancel")
  assert.equal(shield(layer).hidden, true)
  assert.equal(layer.style.textContent, "")
  assert.deepEqual(pushed, [])
})

test("an inactive window's settled drag sends exactly one arrangement event", () => {
  const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}})
  const layer = layerOf({wrappers: [w]})
  const {pushed} = mount(layer)
  drag(layer, on(w, "grip"), [200, 120], [100, 50])
  assert.deepEqual(pushed.map(p => p.event), ["frame_move"])
})

test("a previous gesture's delayed reply does not erase a newer gesture's position", () => {
  const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true})
  const layer = layerOf({wrappers: [w]})
  const {replies} = mount(layer)
  const grip = on(w, "grip")
  drag(layer, grip, [200, 120], [100, 50])
  drag(layer, grip, [300, 170], [200, 70], null)
  const secondPosition = layer.style.textContent
  assert.notEqual(secondPosition, "")
  assert.equal(shield(layer).hidden, false)
  replies[0]({ok: true})
  assert.equal(layer.style.textContent, secondPosition)
})

test("hiding the page cancels an active drag and removes the shield", () => {
  const docEvents = new EventTarget()
  globalThis.document = {
    visibilityState: "visible",
    addEventListener: (...args) => docEvents.addEventListener(...args),
    removeEventListener: (...args) => docEvents.removeEventListener(...args)
  }
  const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true})
  const layer = layerOf({wrappers: [w]})
  const {pushed} = mount(layer)
  drag(layer, on(w, "grip"), [200, 120], [100, 50], null)
  globalThis.document.visibilityState = "hidden"
  docEvents.dispatchEvent(new Event("visibilitychange"))
  assert.equal(shield(layer).hidden, true)
  assert.equal(layer.style.textContent, "")
  assert.deepEqual(pushed, [])
})

test("a refused gesture removes its preview and leaves the server's geometry", () => {
  const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true})
  const layer = layerOf({wrappers: [w]})
  const {pushed, replies} = mount(layer)
  drag(layer, on(w, "grip"), [200, 120], [100, 50])
  assert.notEqual(layer.style.textContent, "")
  replies[0]({error: "hidden"})
  assert.equal(shield(layer).hidden, true)
  assert.equal(layer.style.textContent, "")
  assert.equal(pushed.length, 1)
})

test("a click on an inactive tile's title bar raises it once, on release", () => {
  const t = wrapper(TILE, {place: "tile", box: {x: 1200, y: 0, width: 400, height: 900}, canvasSide: "right"})
  const layer = layerOf({wrappers: [t]})
  const {pushed} = mount(layer)
  const grip = on(t, "grip")
  pointer(layer, "pointerdown", grip, 1300, 15)
  assert.deepEqual(pushed, [])
  pointer(layer, "pointerup", grip, 1300, 15)
  assert.deepEqual(pushed, [{event: "frame_raise", payload: {frame: TILE}}])
})

test("a click on the active window's title bar, or on an edge without travel, sends nothing", () => {
  const w = wrapper(WIN, {box: {x: 100, y: 50, width: 480, height: 360}, active: true})
  const layer = layerOf({wrappers: [w]})
  const {pushed} = mount(layer)
  pointer(layer, "pointerdown", on(w, "grip"), 200, 60)
  pointer(layer, "pointerup", on(w, "grip"), 201, 60)
  pointer(layer, "pointerdown", on(w, "edge", "se"), 578, 408)
  pointer(layer, "pointerup", on(w, "edge", "se"), 578, 408)
  assert.deepEqual(pushed, [])
  assert.equal(layer.style.textContent, "")
})
