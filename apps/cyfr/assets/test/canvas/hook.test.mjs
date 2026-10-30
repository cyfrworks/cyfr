// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import Canvas from "../../js/canvas/index.js"
import {
  CREDENTIAL_CLOSED_EVENT,
  FRAME_STATE_EVENT,
  TO_CANVAS_EVENT,
  acting,
  bearerSignal,
  credentialSignal,
  frameSignal,
  installedSignal,
  nextStanding,
  safeModeChord,
  switchChord
} from "../../js/canvas/signals.js"
import IframeBridge from "../../js/hooks/iframe_bridge.js"
import {createClient} from "../../js/sdk/client.js"
import {CREDENTIAL, HANDSHAKE, decodeToFrame} from "../../js/sdk/wire.js"
// The fixture is tests/fixtures/tincture_wire.json: the bridge reads its
// canvas.handshake rows and posts its canvas.to_frame messages.
import {eventually, fixture, frameWindow} from "../sdk/support.mjs"

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
function frameElement(id, state = "live", dataset = {}) {
  const el = new EventTarget()
  el.dataset = {frameId: id, frameState: state, ...dataset}
  el.contentWindow = {postMessage() {}}
  return el
}

// A canvas frame, with the box it is drawn in, inside its wrapper as the
// layer draws it: shown unless told otherwise, and inert only as set.
function canvasFrame(id, box = {x: 0, y: 0, width: 1024, height: 768}, state = "live") {
  const el = frameElement(id, state, {frameKind: "canvas"})
  el.getBoundingClientRect = () => box
  el.wrapper = {dataset: {canvasShown: "true"}, inert: false}
  el.closest = (selector) => {
    if (selector === "[data-canvas-shown]") return el.wrapper
    if (selector === "[inert]") return el.inert ? el : el.wrapper.inert ? el.wrapper : null
    return null
  }
  return el
}

// A frame's container as the canvas renders it: where it is placed, whether
// it is shown, and its box.
function container(place, shown, box) {
  return {dataset: {canvasPlace: place}, shown, getBoundingClientRect: () => box}
}

// The canvas layer as the server renders it: its geometry and status
// hosts, the frames inside it, the containers of the shown frames and the
// edge strip, and, as `hook`, the hook's own element inside it, which
// carries the column list and holds nothing. Anything read of the layer
// through the hook's element fails.
function canvasElement({frames = [], containers = [], id = "canvas"} = {}) {
  const style = {textContent: "", isConnected: true}
  const geometry = {appended: [], appendChild: (child) => geometry.appended.push(child)}
  const marker = {dataset: {canvasConnection: "connected"}, hidden: true}
  const events = new EventTarget()
  const ownerDocument = {createElement: () => style}
  const notTheLayer = () => {
    throw new Error("the hook's own element is not the layer")
  }

  const layer = {
    id,
    ownerDocument,
    getBoundingClientRect: () => ({width: 1024, height: 768}),
    querySelector(selector) {
      if (selector === `#${id}-geometry`) return geometry
      if (selector === `#${id}-status [data-canvas-connection]`) return marker
      return null
    },
    querySelectorAll(selector) {
      if (selector === "iframe[data-frame-id]") return frames
      if (selector === '[data-canvas-shown="true"]') return containers.filter((c) => c.shown)
      return []
    },
    addEventListener: (type, fn) => events.addEventListener(type, fn),
    removeEventListener: (type, fn) => events.removeEventListener(type, fn),
    dispatch: (event) => events.dispatchEvent(event),
    style,
    geometry,
    marker
  }

  layer.hook = {
    id: `${id}-hook`,
    parentElement: layer,
    dataset: {posture: "desk"},
    ownerDocument,
    getBoundingClientRect: notTheLayer,
    querySelector: notTheLayer,
    querySelectorAll: notTheLayer,
    addEventListener: notTheLayer,
    removeEventListener: notTheLayer
  }

  return layer
}

function mountCanvas(layer) {
  const pushed = []
  const pushedToView = []
  const handlers = {}
  const hook = Object.assign(Object.create(Canvas), {
    el: layer.hook,
    pushEventTo: (target, event, payload) => pushed.push({target, event, payload}),
    pushEvent: (event, payload) => pushedToView.push({event, payload}),
    handleEvent: (event, fn) => (handlers[event] = fn)
  })
  hook.mounted()
  return {hook, pushed, pushedToView, handlers}
}

function mountBridge(el, reply) {
  const events = []
  const hook = Object.assign(Object.create(IframeBridge), {
    el,
    pushEvent: (event, payload, onReply) => {
      events.push({event, payload})
      if (event === "frame_handshake" && onReply) onReply(reply)
    }
  })
  hook.mounted()
  return {hook, events}
}

// What a canvas frame is told through its bridge, recorded on its element.
function told(frame) {
  const seen = []
  frame.addEventListener(TO_CANVAS_EVENT, (event) => seen.push(event.detail))
  return seen
}

// A pointer event on the edge strip, or elsewhere in the canvas layer.
function pointer(type, {x, y, pointerId = 1, onStrip = true}) {
  const event = new Event(type)
  const strip = {setPointerCapture() {}}
  event.pointerId = pointerId
  event.clientX = x
  event.clientY = y
  Object.defineProperty(event, "target", {
    value: {closest: (selector) => (onStrip && selector === "#canvas-shelf" ? strip : null)}
  })
  return event
}

describe("the posture report", () => {
  test("is desk on a wide viewport, sent to the canvas from the hook's own element on mount", () => {
    const el = canvasElement()
    const {pushed} = mountCanvas(el)
    assert.deepEqual(pushed, [{target: el.hook, event: "posture", payload: {posture: "desk"}}])
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

describe("the hook's element", () => {
  test("the layer is read from the hook's parent, and pushes go from the hook's own element", () => {
    const frame = canvasFrame(FRAME)
    const seen = told(frame)
    const layer = canvasElement({id: "layer-x", frames: [frame]})
    const {hook, pushed, pushedToView} = mountCanvas(layer)

    // The layer's frames are told; the posture goes from the hook's element.
    assert.deepEqual(seen[0], {verb: "posture", args: {posture: "desk"}})
    assert.deepEqual(pushed, [{target: layer.hook, event: "posture", payload: {posture: "desk"}}])

    // The pointer is read on the layer.
    layer.dispatch(pointer("pointerdown", {x: 400, y: 760}))
    layer.dispatch(pointer("pointerup", {x: 300, y: 765}))
    assert.deepEqual(pushedToView, [{event: "switch_canvas", payload: {direction: "next"}}])

    // The connection is marked in the layer's status host.
    hook.disconnected()
    assert.equal(layer.marker.dataset.canvasConnection, "disconnected")

    hook.destroyed()
    layer.dispatch(pointer("pointerdown", {x: 400, y: 760}))
    layer.dispatch(pointer("pointerup", {x: 300, y: 765}))
    assert.equal(pushedToView.length, 1)
  })
})

describe("what a canvas frame is told", () => {
  test("its posture and what the shown windows cover of it, each when it changes; a tile or a full app is never reported", () => {
    const frame = canvasFrame(FRAME, {x: 0, y: 40, width: 1000, height: 600})
    const seen = told(frame)
    const column = container("window", true, {x: 700, y: 52, width: 288, height: 576})
    const hidden = container("window", false, {x: 0, y: 40, width: 100, height: 100})
    const tile = container("tile", true, {x: 0, y: 40, width: 200, height: 600})
    const full = container("full", true, {x: 0, y: 0, width: 1000, height: 700})
    const el = canvasElement({frames: [frame], containers: [column, hidden, tile, full]})

    const {hook} = mountCanvas(el)
    assert.deepEqual(seen, [
      {verb: "posture", args: {posture: "desk"}},
      {verb: "covered", args: {rects: [{x: 700, y: 12, width: 288, height: 576}]}}
    ])

    // Nothing moved: nothing is told again.
    hook.updated()
    assert.equal(seen.length, 2)

    // The window closed; the hand posture.
    column.shown = false
    globalThis.window.innerWidth = 600
    listeners.resize()
    assert.deepEqual(seen.slice(2), [
      {verb: "posture", args: {posture: "hand"}},
      {verb: "covered", args: {rects: []}}
    ])
  })

  test("the tinctures the shell names reach only the canvas frame it names", () => {
    const frame = canvasFrame(FRAME)
    const app = frameElement(OTHER)
    const seen = told(frame)
    const elsewhere = told(app)
    const {handlers} = mountCanvas(canvasElement({frames: [frame, app]}))
    const tinctures = [{ref: "tincture:local.vault", name: "vault"}]

    seen.splice(0)
    handlers.canvas_installed({frame: FRAME, tinctures})
    handlers.canvas_installed({frame: OTHER, tinctures})
    handlers.canvas_installed({frame: FRAME, tinctures: "all"})
    handlers.canvas_installed(null)

    assert.deepEqual(seen, [{verb: "installed", args: {tinctures}}])
    assert.deepEqual(elsewhere, [])
  })
})

describe("switching canvases", () => {
  test("Ctrl+Alt+ArrowLeft and ArrowRight ask the shell for the previous and next canvas", () => {
    const {hook, pushedToView} = mountCanvas(canvasElement())
    const press = (keys) => {
      let prevented = false
      listeners.keydown({...keys, preventDefault: () => (prevented = true)})
      return prevented
    }

    assert.equal(press({key: "ArrowLeft", ctrlKey: true, altKey: true}), true)
    assert.equal(press({key: "ArrowRight", ctrlKey: true, altKey: true}), true)
    assert.equal(press({key: "ArrowRight", ctrlKey: true, altKey: false}), false)
    assert.equal(press({key: "ArrowRight", ctrlKey: true, altKey: true, shiftKey: true}), false)
    // With no active app, ArrowUp is the canvas's key and asks nothing.
    assert.equal(press({key: "ArrowUp", ctrlKey: true, altKey: true}), true)

    assert.deepEqual(pushedToView, [
      {event: "switch_canvas", payload: {direction: "previous"}},
      {event: "switch_canvas", payload: {direction: "next"}}
    ])

    hook.disconnected()
    press({key: "ArrowLeft", ctrlKey: true, altKey: true})
    assert.equal(pushedToView.length, 2)
  })

  test("a horizontal swipe on the shelf asks for the next canvas leftward and the previous rightward", () => {
    const el = canvasElement()
    const {hook, pushedToView} = mountCanvas(el)

    el.dispatch(pointer("pointerdown", {x: 400, y: 760}))
    el.dispatch(pointer("pointerup", {x: 300, y: 765}))
    el.dispatch(pointer("pointerdown", {x: 300, y: 760}))
    el.dispatch(pointer("pointerup", {x: 360, y: 760}))

    // Too short, too steep, begun off the strip, or another pointer's end.
    el.dispatch(pointer("pointerdown", {x: 300, y: 760}))
    el.dispatch(pointer("pointerup", {x: 260, y: 760}))
    el.dispatch(pointer("pointerdown", {x: 300, y: 760}))
    el.dispatch(pointer("pointerup", {x: 220, y: 660}))
    el.dispatch(pointer("pointerdown", {x: 300, y: 300, onStrip: false}))
    el.dispatch(pointer("pointerup", {x: 100, y: 300}))
    el.dispatch(pointer("pointerdown", {x: 300, y: 760, pointerId: 1}))
    el.dispatch(pointer("pointerup", {x: 100, y: 760, pointerId: 2}))

    assert.deepEqual(pushedToView, [
      {event: "switch_canvas", payload: {direction: "next"}},
      {event: "switch_canvas", payload: {direction: "previous"}}
    ])

    hook.destroyed()
    el.dispatch(pointer("pointerdown", {x: 400, y: 760}))
    el.dispatch(pointer("pointerup", {x: 300, y: 760}))
    assert.equal(pushedToView.length, 2)
  })

  test("the chord reads only Ctrl+Alt with an arrow", () => {
    assert.equal(switchChord({key: "ArrowLeft", ctrlKey: true, altKey: true}), "previous")
    assert.equal(switchChord({key: "ArrowRight", ctrlKey: true, altKey: true}), "next")
    assert.equal(switchChord({key: "ArrowRight", ctrlKey: true, altKey: true, metaKey: true}), null)
    assert.equal(switchChord(null), null)
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

describe("a canvas frame's bridge", () => {
  const {handshake: HANDSHAKES, to_frame: TO_FRAME} = fixture.canvas
  const [{frame: CANVAS, reply: LIVE}] = HANDSHAKES.valid
  const VALIDATION = HANDSHAKES.valid.find(({reply}) => reply.canvas.mode === "validation").reply
  const PRESS = fixture.shell.find((vector) => vector.verb === "press").message.args
  const OPEN = {ref: "tincture:local.vault"}

  // A canvas frame whose bridge is answered `reply` for its handshake: the
  // window posts, the view's events, and once loaded its end of the port
  // and every message heard there.
  function connect({reply = LIVE, state = "live", frame = CANVAS} = {}) {
    const el = canvasFrame(frame, undefined, state)
    const posted = []
    el.contentWindow = {postMessage: (data, origin, transfer) => posted.push({data, origin, transfer})}
    const {hook, events} = mountBridge(el, reply)
    const heard = []
    let port = null
    const load = () => {
      el.dispatchEvent(new Event("load"))
      if (posted.length > 0 && port === null) {
        port = posted[0].transfer[0]
        port.onmessage = (event) => heard.push(event.data)
      }
      return port
    }
    const close = () => {
      hook.destroyed()
      port?.close()
    }
    return {el, hook, events, posted, heard, load, close}
  }

  // Post `message` from the frame's end of the port and wait until the
  // bridge has forwarded or dropped it.
  async function send(bridge, port, message) {
    const before = bridge.hook.dropped + bridge.events.length
    port.postMessage(message)
    await eventually(() => bridge.hook.dropped + bridge.events.length > before)
  }

  const forwarded = (events) => events.filter(({event}) => event === "frame_verb").map(({payload}) => payload.message)

  // The shell's document as the bridge reads it: its active element, and
  // every listener anything adds to it, by type.
  let documentListeners
  beforeEach(() => {
    documentListeners = []
    globalThis.window.document = {
      activeElement: null,
      addEventListener: (type) => documentListeners.push(type)
    }
  })

  // The shell document's transient activation: active, inactive, or a
  // browser with no such API; and its active element.
  function activation(state) {
    if (state === "absent") delete globalThis.window.navigator
    else globalThis.window.navigator = {userActivation: {isActive: state === "active"}}
  }
  const focus = (element) => (globalThis.window.document.activeElement = element)

  const stateEvent = (state) => new CustomEvent(FRAME_STATE_EVENT, {detail: {state}})

  // The frame live and shown with the socket up, then put in `standing`:
  // hidden (frozen, its wrapper not shown, as the layer holds a canvas it
  // does not show) or disconnected (the view's socket down).
  function stand(el, standing) {
    el.dispatchEvent(stateEvent("reconnected"))
    el.dispatchEvent(stateEvent("live"))
    el.wrapper.dataset.canvasShown = "true"
    if (standing === "hidden") {
      el.dispatchEvent(stateEvent("frozen"))
      el.wrapper.dataset.canvasShown = "false"
    }
    if (standing === "disconnected") el.dispatchEvent(stateEvent("disconnected"))
  }

  test("each handshake reply the fixture takes is handed over: the port, the canvas message, the credential", async () => {
    for (const {frame, reply} of HANDSHAKES.valid) {
      const bridge = connect({reply, frame})
      const port = bridge.load()
      try {
        assert.deepEqual(bridge.events, [{event: "frame_handshake", payload: {frame}}])
        assert.equal(bridge.posted.length, 1)
        assert.deepEqual(bridge.posted[0].data, {v: 1, type: HANDSHAKE, frame})
        assert.equal(bridge.posted[0].origin, "*")
        assert.ok(!JSON.stringify(bridge.posted[0].data).includes(reply.credential))

        await eventually(() => bridge.heard.length === 3)
        const canvasMessage = TO_FRAME.valid.find(
          ({message}) => message.verb === "canvas" && JSON.stringify(message.args) === JSON.stringify(reply.canvas)
        ).message
        assert.deepEqual(bridge.heard, [
          canvasMessage,
          {v: 1, type: CREDENTIAL, frame, credential: reply.credential},
          {v: 1, verb: "state", frame, args: {state: "live"}}
        ])
      } finally {
        bridge.close()
        port.close()
      }
    }
  })

  test("a reply the fixture refuses, or one with no canvas, hands nothing over", () => {
    const replies = [
      ...HANDSHAKES.invalid.map(({reply}) => reply),
      {credential: LIVE.credential},
      {error: "no_credential"}
    ]
    for (const reply of replies) {
      const bridge = connect({reply})
      bridge.load()
      assert.equal(bridge.posted.length, 0, JSON.stringify(reply).slice(0, 80))
      assert.equal(bridge.hook._port, null)
      bridge.close()
    }
  })

  test("what the shell told it before the handshake follows it, the latest of each, and each change after", async () => {
    const bridge = connect({state: "frozen"})
    const {el} = bridge
    const tell = (verb, args) => el.dispatchEvent(new CustomEvent(TO_CANVAS_EVENT, {detail: {verb, args}}))
    const installed = TO_FRAME.valid.find(({message}) => message.verb === "installed").message.args

    tell("posture", {posture: "desk"})
    tell("posture", {posture: "hand"})
    tell("installed", installed)
    // Refused by the wire: never held, never posted.
    tell("posture", {posture: "lap"})
    tell("canvas", LIVE.canvas)
    const port = bridge.load()

    try {
      await eventually(() => bridge.heard.length === 5)
      assert.deepEqual(bridge.heard.slice(2), [
        {v: 1, verb: "posture", frame: CANVAS, args: {posture: "hand"}},
        {v: 1, verb: "installed", frame: CANVAS, args: installed},
        {v: 1, verb: "state", frame: CANVAS, args: {state: "frozen"}}
      ])

      tell("covered", {rects: []})
      el.dispatchEvent(stateEvent("live"))
      el.dispatchEvent(stateEvent("disconnected"))
      await eventually(() => bridge.heard.length === 7)
      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.deepEqual(bridge.heard.slice(5), [
        {v: 1, verb: "covered", frame: CANVAS, args: {rects: []}},
        {v: 1, verb: "state", frame: CANVAS, args: {state: "live"}}
      ])
      assert.ok(bridge.heard.every((message) => message.type === CREDENTIAL || decodeToFrame(message).ok))
    } finally {
      bridge.close()
      port.close()
    }
  })

  test("an open or a press reaches the view only under the shell's activation with the frame focused, live and shown", async () => {
    const bridge = connect()
    const port = bridge.load()
    const other = {id: "another element"}
    const asks = [
      {v: 1, verb: "open", frame: CANVAS, args: OPEN},
      {v: 1, verb: "press", frame: CANVAS, args: PRESS}
    ]

    try {
      for (const state of ["active", "inactive", "absent"]) {
        for (const focused of ["frame", "other"]) {
          for (const standing of ["live", "hidden", "disconnected"]) {
            for (const message of asks) {
              activation(state)
              focus(focused === "frame" ? bridge.el : other)
              stand(bridge.el, standing)
              const before = forwarded(bridge.events).length
              await send(bridge, port, message)

              const expected = state === "active" && focused === "frame" && standing === "live" ? 1 : 0
              assert.equal(
                forwarded(bridge.events).length - before,
                expected,
                `${message.verb}: activation ${state}, ${focused} focused, ${standing}`
              )
            }
          }
        }
      }
      // The one combination that forwards, for each verb, and nothing else.
      assert.deepEqual(forwarded(bridge.events), asks)
      // Those two conditions are the whole check: the bridge tracks no
      // input of its own, on the shell's document or its window.
      assert.deepEqual(documentListeners, [])
      assert.deepEqual(Object.keys(listeners), [])
    } finally {
      bridge.close()
      port.close()
    }
  })

  test("inside one activation every open and press is forwarded, and none once it has passed", async () => {
    const bridge = connect()
    const port = bridge.load()
    const asks = [
      {v: 1, verb: "press", frame: CANVAS, args: PRESS},
      {v: 1, verb: "press", frame: CANVAS, args: PRESS},
      {v: 1, verb: "open", frame: CANVAS, args: OPEN},
      {v: 1, verb: "press", frame: CANVAS, args: {...PRESS, action: "buy"}}
    ]

    try {
      activation("active")
      focus(bridge.el)
      for (const message of asks) await send(bridge, port, message)
      assert.deepEqual(forwarded(bridge.events), asks)

      activation("inactive")
      await send(bridge, port, asks[0])
      assert.equal(forwarded(bridge.events).length, asks.length)
    } finally {
      bridge.close()
      port.close()
    }
  })

  test("a canvas covered by an inert layer, or not shown, acts on nothing however it is pressed", async () => {
    const bridge = connect()
    const port = bridge.load()
    const press = {v: 1, verb: "press", frame: CANVAS, args: PRESS}

    try {
      activation("active")
      focus(bridge.el)
      bridge.el.wrapper.inert = true
      await send(bridge, port, press)
      bridge.el.wrapper.inert = false
      bridge.el.wrapper.dataset.canvasShown = "false"
      await send(bridge, port, press)
      assert.equal(forwarded(bridge.events).length, 0)

      // The positive control: shown and not inert, the same press passes.
      bridge.el.wrapper.dataset.canvasShown = "true"
      await send(bridge, port, press)
      assert.deepEqual(forwarded(bridge.events), [press])
    } finally {
      bridge.close()
      port.close()
    }
  })

  test("ready and failed need no press; close, title, credential and anything undecodable are dropped", async () => {
    const bridge = connect()
    const port = bridge.load()
    const passes = [
      {v: 1, verb: "ready", frame: CANVAS, args: {}},
      {v: 1, verb: "failed", frame: CANVAS, args: {stage: "load"}},
      {v: 1, verb: "failed", frame: CANVAS, args: {stage: "runtime"}}
    ]
    const dropped = [
      {v: 1, verb: "close", frame: CANVAS, args: {}},
      {v: 1, verb: "title", frame: CANVAS, args: {title: "Mine"}},
      {v: 1, verb: "credential", frame: CANVAS, args: {name: "weather-api"}},
      {v: 1, verb: "ready", frame: "frm_00aa11bb22", args: {}},
      {v: 1, verb: "posture", frame: CANVAS, args: {posture: "desk"}},
      ...fixture.shell_invalid.map(({message}) => ({...message, frame: CANVAS}))
    ]

    try {
      activation("inactive")
      for (const message of [...passes, ...dropped]) await send(bridge, port, message)
      assert.deepEqual(forwarded(bridge.events), passes)
      assert.equal(bridge.hook.dropped, dropped.length)
      assert.equal(bridge.el.dataset.dropped, String(dropped.length))
    } finally {
      bridge.close()
      port.close()
    }
  })

  test("ready and failed reach the view shown or hidden, and are dropped only while the socket is down", async () => {
    const bridge = connect()
    const port = bridge.load()
    const reports = [
      {v: 1, verb: "ready", frame: CANVAS, args: {}},
      {v: 1, verb: "failed", frame: CANVAS, args: {stage: "runtime"}}
    ]

    try {
      activation("inactive")
      for (const standing of ["live", "hidden", "disconnected"]) {
        for (const message of reports) {
          stand(bridge.el, standing)
          const before = forwarded(bridge.events).length
          await send(bridge, port, message)
          assert.equal(
            forwarded(bridge.events).length - before,
            standing === "disconnected" ? 0 : 1,
            `${message.verb}, ${standing}`
          )
        }
      }
      assert.deepEqual(forwarded(bridge.events), [...reports, ...reports])
      assert.equal(bridge.hook.dropped, reports.length)
    } finally {
      bridge.close()
      port.close()
    }
  })

  // A canvas page's SDK behind the bridge, the page reporting while the
  // canvas is hidden: its report reaches the view then, not lost until
  // the canvas is shown again.
  for (const verb of ["ready", "failed"]) {
    test(`a hidden canvas page's ${verb} reaches the view while it is hidden`, async () => {
      const bridge = connect()
      const win = frameWindow()
      const {api, onWindowMessage, onPageError} = createClient({win, fetchFn: fetch, base: "http://127.0.0.1/"})
      const states = []
      api.on("state", (state) => states.push(state))

      bridge.el.contentWindow = {
        postMessage: (data, _origin, transfer) => onWindowMessage({source: win.parent, data, ports: transfer})
      }
      const {handlers} = mountCanvas(canvasElement({frames: [bridge.el]}))
      bridge.el.dispatchEvent(new Event("load"))
      const reported = () => forwarded(bridge.events).filter((message) => message.verb === verb)

      try {
        await eventually(() => states.length === 1)
        if (verb === "failed") {
          api.ready()
          await eventually(() => forwarded(bridge.events).length === 1)
        }

        handlers.frame_state({frame: CANVAS, state: "frozen"})
        bridge.el.wrapper.dataset.canvasShown = "false"
        await eventually(() => states.length === 2)

        if (verb === "failed") onPageError({type: "error", message: "Uncaught Error: drawing failed"})
        else api.ready()
        await eventually(() => reported().length === 1)

        assert.deepEqual(states, ["live", "frozen"])
        assert.deepEqual(reported(), [{v: 1, verb, frame: CANVAS, args: verb === "failed" ? {stage: "runtime"} : {}}])
        assert.equal(bridge.hook.dropped, 0)
      } finally {
        bridge.close()
        bridge.hook._port?.close()
      }
    })
  }

  test("a validation frame's open and press are dropped, pressed or not; its ready and failed reach the view", async () => {
    const bridge = connect({reply: VALIDATION})
    const port = bridge.load()
    const asks = [
      {v: 1, verb: "open", frame: CANVAS, args: OPEN},
      {v: 1, verb: "press", frame: CANVAS, args: PRESS}
    ]
    const passes = [
      {v: 1, verb: "ready", frame: CANVAS, args: {}},
      {v: 1, verb: "failed", frame: CANVAS, args: {stage: "load"}}
    ]

    try {
      activation("active")
      focus(bridge.el)
      for (const message of [...asks, ...passes]) await send(bridge, port, message)
      assert.deepEqual(forwarded(bridge.events), passes)
      assert.equal(bridge.hook.dropped, asks.length)
    } finally {
      bridge.close()
      port.close()
    }
  })

  test("a hidden canvas's page hears it frozen, acts on nothing, and shown again hears it live once", async () => {
    const bridge = connect()
    const win = frameWindow()
    const {api, onWindowMessage} = createClient({win, fetchFn: fetch, base: "http://127.0.0.1/"})
    const states = []
    api.on("state", (state) => states.push(state))

    bridge.el.contentWindow = {
      postMessage: (data, _origin, transfer) => onWindowMessage({source: win.parent, data, ports: transfer})
    }
    const {handlers} = mountCanvas(canvasElement({frames: [bridge.el]}))
    bridge.el.dispatchEvent(new Event("load"))
    const pressed = () => {
      activation("active")
      focus(bridge.el)
      api.press(PRESS.binding, PRESS.action)
    }

    try {
      await eventually(() => states.length === 1)

      handlers.frame_state({frame: CANVAS, state: "frozen"})
      bridge.el.wrapper.dataset.canvasShown = "false"
      await eventually(() => states.length === 2)
      pressed()
      await eventually(() => bridge.hook.dropped === 1)

      handlers.frame_state({frame: CANVAS, state: "live"})
      bridge.el.wrapper.dataset.canvasShown = "true"
      await eventually(() => states.length === 3)
      pressed()
      await eventually(() => forwarded(bridge.events).length === 1)
      await new Promise((resolve) => setTimeout(resolve, 20))

      assert.deepEqual(states, ["live", "frozen", "live"])
      assert.deepEqual(forwarded(bridge.events), [{v: 1, verb: "press", frame: CANVAS, args: PRESS}])
      assert.equal(bridge.hook.dropped, 1)
    } finally {
      bridge.close()
      bridge.hook._port?.close()
    }
  })

  test("a second load closes its port and reports the frame gone", async () => {
    const bridge = connect()
    const port = bridge.load()
    await eventually(() => bridge.heard.length === 3)

    bridge.el.dispatchEvent(new Event("load"))
    assert.deepEqual(bridge.events.at(-1), {event: "frame_gone", payload: {frame: CANVAS}})
    assert.equal(bridge.hook._port, null)
    assert.equal(bridge.posted.length, 1)
    bridge.close()
    port.close()
  })
})

describe("a closed credential prompt", () => {
  test("reaches only the frame it names, whose bridge tells the frame whether it was saved", async () => {
    const frame = frameElement(FRAME)
    const other = frameElement(OTHER)
    const {hook: bridge} = mountBridge(frame)
    const channel = new MessageChannel()
    bridge._port = channel.port1
    const heard = []
    channel.port2.onmessage = (event) => heard.push(event.data)
    const elsewhere = []
    other.addEventListener(CREDENTIAL_CLOSED_EVENT, (event) => elsewhere.push(event.detail))

    // The ports are closed however the test ends: an open port keeps the
    // runner's process alive.
    try {
      const {handlers} = mountCanvas(canvasElement({frames: [frame, other]}))
      handlers.frame_credential({frame: FRAME, saved: true})
      handlers.frame_credential({frame: FRAME, saved: "yes"})
      handlers.frame_credential({frame: "short", saved: false})
      handlers.frame_credential(null)

      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.deepEqual(heard, [{v: 1, type: "cyfr:credential-closed", frame: FRAME, saved: true}])
      assert.deepEqual(elsewhere, [])
    } finally {
      bridge.destroyed()
      channel.port2.close()
    }
  })
})

describe("a rotated credential", () => {
  // Wait for a condition, in bounded steps.
  async function eventually(check) {
    for (let i = 0; i < 100 && !check(); i++) await new Promise((resolve) => setTimeout(resolve, 5))
    assert.ok(check(), "the condition never held")
  }

  const RENEWED = "frm.v2.cmVuZXdlZC1mcmFtZS1jcmVkZW50aWFs"

  // A frame whose bridge has taken its handshake: its port's far end, and
  // every message it hears.
  function handshaken(id, dataset = {}, reply = {credential: "frm.v2.first"}) {
    const el = frameElement(id, "live", dataset)
    const transfers = []
    el.contentWindow = {postMessage: (_data, _origin, transfer) => transfers.push(...(transfer || []))}
    const {hook} = mountBridge(el, reply)
    el.dispatchEvent(new Event("load"))
    const heard = []
    const port = transfers[0]
    if (port) port.onmessage = (event) => heard.push(event.data)
    return {el, hook, port, heard}
  }

  test("reaches only the frame it names: frame A's never reaches frame B's port", async () => {
    const a = handshaken(FRAME)
    const b = handshaken(OTHER)

    try {
      await eventually(() => a.heard.length === 1 && b.heard.length === 1)
      const {handlers} = mountCanvas(canvasElement({frames: [a.el, b.el]}))

      handlers.frame_bearer({frame: FRAME, credential: RENEWED})
      handlers.frame_bearer({frame: FRAME, credential: ""})
      handlers.frame_bearer({frame: "short", credential: RENEWED})
      handlers.frame_bearer({frame: FRAME})
      handlers.frame_bearer(null)

      await eventually(() => a.heard.length === 2)
      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.deepEqual(a.heard.slice(1), [{v: 1, type: "cyfr:credential", frame: FRAME, credential: RENEWED}])
      assert.equal(b.heard.length, 1)
      assert.ok(!JSON.stringify(b.heard).includes(RENEWED))
    } finally {
      for (const {hook, port} of [a, b]) {
        hook.destroyed()
        port?.close()
      }
    }
  })

  test("a canvas's frame is handed one as every frame is", async () => {
    const [{frame, reply}] = fixture.canvas.handshake.valid
    const canvas = handshaken(frame, {frameKind: "canvas"}, reply)

    try {
      await eventually(() => canvas.heard.some((message) => message.type === CREDENTIAL))
      const {handlers} = mountCanvas(canvasElement({frames: [canvas.el]}))
      handlers.frame_bearer({frame, credential: RENEWED})
      handlers.frame_bearer({frame, credential: ""})

      await eventually(() => canvas.heard.filter((message) => message.type === CREDENTIAL).length === 2)
      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.deepEqual(
        canvas.heard.filter((message) => message.type === CREDENTIAL),
        [
          {v: 1, type: CREDENTIAL, frame, credential: reply.credential},
          {v: 1, type: CREDENTIAL, frame, credential: RENEWED}
        ]
      )
    } finally {
      canvas.hook.destroyed()
      canvas.port?.close()
    }
  })
})

describe("the safe mode chord", () => {
  test("Ctrl+Alt+S on the shell's page asks the shell for safe mode; nothing else does", () => {
    const pushed = []
    const hook = Object.assign(Object.create(Canvas), {
      el: canvasElement().hook,
      pushEventTo: () => {},
      pushEvent: (event, payload) => pushed.push({event, payload}),
      handleEvent: () => {}
    })
    hook.mounted()

    const press = (keys) => {
      let prevented = false
      listeners.keydown({...keys, preventDefault: () => (prevented = true)})
      return prevented
    }

    assert.equal(press({key: "s", code: "KeyS", ctrlKey: true, altKey: false}), false)
    assert.equal(press({key: "s", code: "KeyS", ctrlKey: false, altKey: true}), false)
    assert.equal(press({key: "x", code: "KeyX", ctrlKey: true, altKey: true}), false)
    assert.equal(press({key: "ß", code: "KeyS", ctrlKey: true, altKey: true}), true)
    assert.deepEqual(pushed, [{event: "safe_mode", payload: {}}])

    hook.disconnected()
    press({key: "S", code: "KeyS", ctrlKey: true, altKey: true})
    assert.equal(pushed.length, 1)

    hook.destroyed()
    assert.equal(listeners.keydown, undefined)
    assert.equal(safeModeChord(null), false)
  })
})

describe("the signal grammar", () => {
  test("a frame_credential payload is a frame id and a boolean, and nothing else", () => {
    assert.deepEqual(credentialSignal({frame: FRAME, saved: false}), {frame: FRAME, saved: false})
    assert.equal(credentialSignal({frame: FRAME, saved: 1}), null)
    assert.equal(credentialSignal({frame: FRAME}), null)
    assert.equal(credentialSignal("saved"), null)
  })

  test("a frame_bearer payload is a frame id and a non-empty credential, and nothing else", () => {
    assert.deepEqual(bearerSignal({frame: FRAME, credential: "x"}), {frame: FRAME, credential: "x"})
    assert.equal(bearerSignal({frame: FRAME, credential: ""}), null)
    assert.equal(bearerSignal({frame: FRAME, credential: 1}), null)
    assert.equal(bearerSignal({frame: "x", credential: "y"}), null)
    assert.equal(bearerSignal(null), null)
  })

  test("a frame_state payload is a frame id and live or frozen, and nothing else", () => {
    assert.deepEqual(frameSignal({frame: FRAME, state: "live"}), {frame: FRAME, state: "live"})
    assert.equal(frameSignal({frame: FRAME, state: "disconnected"}), null)
    assert.equal(frameSignal({frame: "x", state: "live"}), null)
    assert.equal(frameSignal("frozen"), null)
  })

  test("a canvas_installed payload is a frame id and a list, and nothing else", () => {
    assert.deepEqual(installedSignal({frame: FRAME, tinctures: []}), {frame: FRAME, tinctures: []})
    assert.equal(installedSignal({frame: FRAME, tinctures: {}}), null)
    assert.equal(installedSignal({frame: "x", tinctures: []}), null)
    assert.equal(installedSignal(null), null)
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
