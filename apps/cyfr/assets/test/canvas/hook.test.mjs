// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import Canvas from "../../js/canvas/index.js"
import {
  CANVAS_MESSAGE_EVENT,
  CREDENTIAL_CLOSED_EVENT,
  FRAME_STATE_EVENT,
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
import {HANDSHAKE} from "../../js/sdk/wire.js"
import {decode} from "../../js/toolkit/wire.js"

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

// A canvas frame, with the box it is drawn in.
function canvasFrame(id, box = {x: 0, y: 0, width: 1024, height: 768}, state = "live") {
  const el = frameElement(id, state, {frameWire: "canvas"})
  el.getBoundingClientRect = () => box
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
function canvasElement({columns = [], frames = [], containers = [], id = "canvas"} = {}) {
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
    dataset: {columns: JSON.stringify(columns), posture: "desk"},
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
  frame.addEventListener(CANVAS_MESSAGE_EVENT, (event) => seen.push(event.detail))
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
    value: {closest: (selector) => (onStrip && selector === "#canvas-edge-strip" ? strip : null)}
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
    const layer = canvasElement({id: "layer-x", columns: [{frame: OTHER, order: 0}], frames: [frame]})
    const {hook, pushed, pushedToView} = mountCanvas(layer)

    // The stylesheet lives in the layer's geometry host, scoped by its id,
    // and the columns are laid out in the layer's size.
    assert.deepEqual(layer.geometry.appended, [layer.style])
    assert.match(layer.style.textContent, new RegExp(`^#layer-x \\[data-canvas-column="${OTHER}"\\]\\{left:592px;`))

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

describe("the column layout", () => {
  test("is written from the rendered column list into the canvas's own stylesheet", () => {
    const el = canvasElement({columns: [{frame: FRAME, order: 0}]})
    mountCanvas(el)
    assert.match(el.style.textContent, new RegExp(`\\[data-canvas-column="${FRAME}"\\]\\{left:592px;top:12px;`))
  })

  test("the last list stays drawn while the socket is down, and follows the window", () => {
    const el = canvasElement({columns: [{frame: FRAME, order: 0}]})
    const {hook} = mountCanvas(el)
    const desk = el.style.textContent

    hook.disconnected()
    assert.equal(el.marker.dataset.canvasConnection, "disconnected")
    assert.equal(el.marker.hidden, false)

    // A patch that no longer parses leaves the last list in place.
    el.hook.dataset.columns = "not json"
    hook.updated()
    assert.equal(el.style.textContent, desk)

    globalThis.window.innerWidth = 600
    listeners.resize()
    assert.match(el.style.textContent, new RegExp(FRAME))
    assert.notEqual(el.style.textContent, desk)

    hook.reconnected()
    assert.equal(el.marker.dataset.canvasConnection, "connected")
    assert.equal(el.marker.hidden, true)
  })
})

describe("what a canvas frame is told", () => {
  test("its posture and what the shown apps and floating frames cover of it, each when it changes", () => {
    const frame = canvasFrame(FRAME, {x: 0, y: 40, width: 1000, height: 600})
    const seen = told(frame)
    const column = container("column", true, {x: 700, y: 52, width: 288, height: 576})
    const hidden = container("float", false, {x: 0, y: 40, width: 100, height: 100})
    const el = canvasElement({frames: [frame], containers: [column, hidden]})

    const {hook} = mountCanvas(el)
    assert.deepEqual(seen, [
      {verb: "posture", args: {posture: "desk"}},
      {verb: "covered", args: {rects: [{x: 700, y: 12, width: 288, height: 576}]}}
    ])

    // Nothing moved: nothing is told again.
    hook.updated()
    assert.equal(seen.length, 2)

    // The column closed; the hand posture.
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
    assert.equal(press({key: "ArrowUp", ctrlKey: true, altKey: true}), false)

    assert.deepEqual(pushedToView, [
      {event: "switch_canvas", payload: {direction: "previous"}},
      {event: "switch_canvas", payload: {direction: "next"}}
    ])

    hook.disconnected()
    press({key: "ArrowLeft", ctrlKey: true, altKey: true})
    assert.equal(pushedToView.length, 2)
  })

  test("a horizontal swipe on the edge strip asks for the next canvas leftward and the previous rightward", () => {
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
  const BOOT = {
    mode: "live",
    credential: "frm.v1.c2lnbmVkLWZyYW1lLWNyZWRlbnRpYWw",
    data_path: `/_f/v1/o/${FRAME}/`,
    module_url: "/_s/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/local/canvas/0.1.0/canvas.js",
    toolkit: 1,
    streams: [{name: "runs.changes", subject: null}]
  }

  // The canvas frame's window: the handshake it is posted, and its end of
  // the port.
  function connect(state = "live", reply = {boot: BOOT}) {
    const frame = canvasFrame(FRAME, undefined, state)
    const posted = []
    frame.contentWindow = {postMessage: (data, origin, transfer) => posted.push({data, origin, transfer})}
    const bridge = mountBridge(frame, reply)
    return {frame, posted, ...bridge}
  }

  async function received(posted, count) {
    const [{transfer}] = posted
    const port = transfer[0]
    const messages = []
    port.onmessage = (event) => messages.push(event.data)
    for (let i = 0; i < 100 && messages.length < count; i++) await new Promise((r) => setTimeout(r, 5))
    return {port, messages}
  }

  test("posts the handshake, then boot over the port with the bearer inside it, and never cyfr:credential", async () => {
    const {frame, posted, events, hook} = connect()
    frame.dispatchEvent(new CustomEvent(CANVAS_MESSAGE_EVENT, {detail: {verb: "posture", args: {posture: "hand"}}}))
    frame.dispatchEvent(new Event("load"))

    assert.deepEqual(events, [{event: "frame_handshake", payload: {frame: FRAME}}])
    assert.equal(posted.length, 1)
    assert.deepEqual(posted[0].data, {v: 1, type: HANDSHAKE, frame: FRAME})
    assert.ok(!JSON.stringify(posted[0].data).includes(BOOT.credential))

    const {port, messages} = await received(posted, 2)
    assert.deepEqual(messages[0], {v: 1, verb: "boot", frame: FRAME, args: BOOT})
    // What the glass said before the boot follows it, the latest first.
    assert.deepEqual(messages[1], {v: 1, verb: "posture", frame: FRAME, args: {posture: "hand"}})
    assert.ok(messages.every((message) => decode(message).ok))
    assert.ok(messages.every((message) => message.type !== "cyfr:credential"))
    hook.destroyed()
    port.close()
  })

  test("a reply without a boot the wire takes hands nothing", () => {
    for (const reply of [{error: "no_credential"}, {credential: "a-bearer"}, {boot: {...BOOT, module_url: "x.js"}}]) {
      const {frame, posted, hook} = connect("live", reply)
      frame.dispatchEvent(new Event("load"))
      assert.equal(posted.length, 0)
      hook.destroyed()
    }
  })

  test("its verbs reach the view as canvas_verb; another direction's, another frame's or a shell verb are dropped", () => {
    const {hook, events} = connect()
    const ready = {v: 1, verb: "ready", frame: FRAME, args: {}}

    hook._receiveCanvas(ready)
    hook._receiveCanvas({v: 1, verb: "open", frame: FRAME, args: {ref: "tincture:local.vault", extra: 1}})
    hook._receiveCanvas({v: 1, verb: "posture", frame: FRAME, args: {posture: "desk"}})
    hook._receiveCanvas({v: 1, verb: "ready", frame: OTHER, args: {}})
    hook._receiveCanvas({v: 1, verb: "close", frame: FRAME, args: {}})

    assert.deepEqual(events, [{event: "canvas_verb", payload: {frame: FRAME, message: ready}}])
    assert.equal(hook.dropped, 4)
    hook.destroyed()
  })

  test("its state reaches the toolkit over the port once booted, and a frame booted frozen is told so", async () => {
    const {frame, posted, hook} = connect("frozen")
    frame.dispatchEvent(new Event("load"))
    const {port, messages} = await received(posted, 2)
    assert.deepEqual(messages.slice(1), [{v: 1, verb: "state", frame: FRAME, args: {state: "frozen"}}])

    frame.dispatchEvent(new CustomEvent(FRAME_STATE_EVENT, {detail: {state: "live"}}))
    frame.dispatchEvent(new CustomEvent(FRAME_STATE_EVENT, {detail: {state: "disconnected"}}))
    await new Promise((r) => setTimeout(r, 20))
    assert.deepEqual(messages.slice(2), [{v: 1, verb: "state", frame: FRAME, args: {state: "live"}}])
    hook.destroyed()
    port.close()
  })

  test("a second load closes its port and reports the frame gone", async () => {
    const {frame, posted, events, hook} = connect()
    frame.dispatchEvent(new Event("load"))
    const {port} = await received(posted, 1)

    frame.dispatchEvent(new Event("load"))
    assert.deepEqual(events.at(-1), {event: "frame_gone", payload: {frame: FRAME}})
    assert.equal(hook._port, null)
    assert.equal(posted.length, 1)
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

  test("a canvas's frame is never handed one", async () => {
    const boot = {
      mode: "live",
      credential: "frm.v1.c2lnbmVkLWZyYW1lLWNyZWRlbnRpYWw",
      data_path: `/_f/v1/o/${FRAME}/`,
      module_url: "/_s/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/local/canvas/0.1.0/canvas.js",
      toolkit: 1,
      streams: [{name: "runs.changes", subject: null}]
    }
    const canvas = handshaken(FRAME, {frameWire: "canvas"}, {boot})

    try {
      await eventually(() => canvas.heard.length >= 1)
      const {handlers} = mountCanvas(canvasElement({frames: [canvas.el]}))
      handlers.frame_bearer({frame: FRAME, credential: RENEWED})

      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.ok(canvas.heard.every((message) => message.type !== "cyfr:credential"))
      assert.ok(!JSON.stringify(canvas.heard).includes(RENEWED))
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
