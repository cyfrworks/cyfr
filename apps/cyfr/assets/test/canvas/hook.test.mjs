// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import Canvas from "../../js/canvas/index.js"
import {FRAME_STATE_EVENT, acting, frameSignal, nextStanding} from "../../js/canvas/signals.js"
import IframeBridge from "../../js/hooks/iframe_bridge.js"

const FRAME = "frm_01a09fee2e4f"
const OTHER = "frm_02b10aaa3f5e"

// A window the hook reads its width from and listens to for resizes.
let listeners
beforeEach(() => {
  listeners = {}
  globalThis.window = {
    innerWidth: 1280,
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type) => delete listeners[type]
  }
})
afterEach(() => {
  delete globalThis.window
})

// A frame element: an event target carrying the bridge's data attributes.
function frameElement(id, state = "live") {
  const el = new EventTarget()
  el.dataset = {frameId: id, frameState: state}
  el.contentWindow = {postMessage() {}}
  return el
}

// The canvas element as the server renders it: its slot list, its
// geometry and status hosts, and the frames inside it.
function canvasElement({slots = [], frames = []} = {}) {
  const style = {textContent: "", isConnected: true}
  const geometry = {appended: [], appendChild: (child) => geometry.appended.push(child)}
  const marker = {dataset: {canvasConnection: "connected"}, hidden: true}

  return {
    id: "canvas",
    dataset: {slots: JSON.stringify(slots)},
    ownerDocument: {createElement: () => style},
    getBoundingClientRect: () => ({width: 1024, height: 768}),
    querySelector(selector) {
      if (selector === "#canvas-geometry") return geometry
      if (selector === "#canvas-status [data-canvas-connection]") return marker
      return null
    },
    querySelectorAll: (selector) => (selector === "iframe[data-frame-id]" ? frames : []),
    style,
    marker
  }
}

function mountCanvas(el) {
  const pushed = []
  const handlers = {}
  const hook = Object.assign(Object.create(Canvas), {
    el,
    pushEventTo: (target, event, payload) => pushed.push({target, event, payload}),
    handleEvent: (event, fn) => (handlers[event] = fn)
  })
  hook.mounted()
  return {hook, pushed, handlers}
}

function mountBridge(el) {
  const events = []
  const hook = Object.assign(Object.create(IframeBridge), {
    el,
    pushEvent: (event, payload) => events.push({event, payload})
  })
  hook.mounted()
  return {hook, events}
}

describe("the posture report", () => {
  test("is desk on a wide viewport, sent to the canvas itself on mount", () => {
    const el = canvasElement()
    const {pushed} = mountCanvas(el)
    assert.deepEqual(pushed, [{target: el, event: "posture", payload: {posture: "desk"}}])
  })

  test("is sent again only when the posture changes", () => {
    const {pushed} = mountCanvas(canvasElement())

    globalThis.window.innerWidth = 1100
    listeners.resize()
    globalThis.window.innerWidth = 600
    listeners.resize()
    globalThis.window.innerWidth = 500
    listeners.resize()

    assert.deepEqual(
      pushed.map(({payload}) => payload.posture),
      ["desk", "hand"]
    )
  })

  test("is not sent while the socket is down, and is sent again when it is back", () => {
    const {hook, pushed} = mountCanvas(canvasElement())
    hook.disconnected()

    globalThis.window.innerWidth = 600
    listeners.resize()
    assert.equal(pushed.length, 1)

    hook.reconnected()
    assert.deepEqual(pushed.at(-1).payload, {posture: "hand"})
  })
})

describe("the slot layout", () => {
  test("is written from the rendered slot list into the canvas's own stylesheet", () => {
    const el = canvasElement({slots: [{id: "notes", size: "icon", order: 0}]})
    mountCanvas(el)
    assert.match(el.style.textContent, /\[data-canvas-place="slot:notes"\]\{left:24px;top:24px;/)
  })

  test("the last list stays drawn while the socket is down, and follows the window", () => {
    const el = canvasElement({slots: [{id: "notes", size: "card", order: 0}]})
    const {hook} = mountCanvas(el)
    const desk = el.style.textContent

    hook.disconnected()
    assert.equal(el.marker.dataset.canvasConnection, "disconnected")
    assert.equal(el.marker.hidden, false)

    // A patch that no longer parses leaves the last list in place.
    el.dataset.slots = "not json"
    hook.updated()
    assert.equal(el.style.textContent, desk)

    globalThis.window.innerWidth = 600
    listeners.resize()
    assert.match(el.style.textContent, /slot:notes/)
    assert.notEqual(el.style.textContent, desk)

    hook.reconnected()
    assert.equal(el.marker.dataset.canvasConnection, "connected")
    assert.equal(el.marker.hidden, true)
  })
})

describe("frame signals", () => {
  test("a frame_state signal reaches only the frame it names", () => {
    const frame = frameElement(FRAME)
    const other = frameElement(OTHER)
    const seen = []
    frame.addEventListener(FRAME_STATE_EVENT, (event) => seen.push([FRAME, event.detail.state]))
    other.addEventListener(FRAME_STATE_EVENT, (event) => seen.push([OTHER, event.detail.state]))

    const {handlers} = mountCanvas(canvasElement({frames: [frame, other]}))
    handlers.frame_state({frame: FRAME, state: "frozen"})
    handlers.frame_state({frame: OTHER, state: "melted"})
    handlers.frame_state({frame: "short", state: "live"})
    handlers.frame_state(null)

    assert.deepEqual(seen, [[FRAME, "frozen"]])
  })

  test("a frozen frame is inert and its verbs are dropped; live again, they pass", () => {
    const frame = frameElement(FRAME)
    const {hook: bridge, events} = mountBridge(frame)
    const {handlers} = mountCanvas(canvasElement({frames: [frame]}))
    const ready = {v: 1, verb: "ready", frame: FRAME, args: {}}

    handlers.frame_state({frame: FRAME, state: "frozen"})
    assert.equal(frame.inert, true)
    bridge._receive(ready)
    assert.deepEqual(events, [])
    assert.equal(frame.dataset.dropped, "1")

    handlers.frame_state({frame: FRAME, state: "live"})
    assert.equal(frame.inert, false)
    bridge._receive(ready)
    assert.deepEqual(events, [{event: "frame_verb", payload: {frame: FRAME, message: ready}}])
    bridge.destroyed()
  })

  test("a frame rendered frozen starts inert", () => {
    const frame = frameElement(FRAME, "frozen")
    const {hook: bridge, events} = mountBridge(frame)

    assert.equal(frame.inert, true)
    bridge._receive({v: 1, verb: "ready", frame: FRAME, args: {}})
    assert.deepEqual(events, [])
    bridge.destroyed()
  })

  test("while the socket is down no frame acts, live or not", () => {
    const frame = frameElement(FRAME)
    const {hook: bridge, events} = mountBridge(frame)
    const {hook: canvas} = mountCanvas(canvasElement({frames: [frame]}))
    const ready = {v: 1, verb: "ready", frame: FRAME, args: {}}

    canvas.disconnected()
    assert.equal(frame.inert, true)
    bridge._receive(ready)
    assert.deepEqual(events, [])

    canvas.reconnected()
    assert.equal(frame.inert, false)
    bridge._receive(ready)
    assert.equal(events.length, 1)
    bridge.destroyed()
  })
})

describe("the signal grammar", () => {
  test("a frame_state payload is a frame id and live or frozen, and nothing else", () => {
    assert.deepEqual(frameSignal({frame: FRAME, state: "live"}), {frame: FRAME, state: "live"})
    assert.equal(frameSignal({frame: FRAME, state: "disconnected"}), null)
    assert.equal(frameSignal({frame: "x", state: "live"}), null)
    assert.equal(frameSignal("frozen"), null)
  })

  test("a frame acts only live with the socket up", () => {
    let standing = {state: "live", connected: true}
    assert.equal(acting(standing), true)
    standing = nextStanding(standing, "disconnected")
    assert.equal(acting(standing), false)
    standing = nextStanding(standing, "frozen")
    standing = nextStanding(standing, "reconnected")
    assert.equal(acting(standing), false)
    standing = nextStanding(standing, "live")
    assert.equal(acting(standing), true)
    assert.deepEqual(nextStanding(standing, "bogus"), standing)
  })
})
