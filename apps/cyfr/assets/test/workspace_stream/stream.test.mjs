// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The workspace thread's window of Aqua's browser, the page's side: the
// person's pointer, wheel and keys become the events
// tests/fixtures/browser_frames.json's `input` accepts, a place a fraction
// of the drawn image; at most MAX_EVENTS go in one push, one push a frame;
// each image is drawn before the hook says it drew it; the size asked is
// the canvas's, bounded. Only the DOM, the image decoder, the frame clock
// and the server are stood in for.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"

import {IN_FLIGHT, MAX_EVENTS, Queue, WorkspaceStream, key, mouse, size, wheel} from "../../js/hooks/workspace_stream.js"

const all = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/browser_frames.json", import.meta.url), "utf8")
)
const vectors = all.input

// The fields each kind of event holds, as the vectors' accepted events show them.
const fields = {}
for (const {event} of vectors.accept) fields[event.k] = Object.keys(event).sort()

function accepted(event) {
  assert.deepEqual(Object.keys(event).sort(), fields[event.k], `the fields of ${JSON.stringify(event)}`)
  for (const name of ["x", "y"]) if (name in event) assert.ok(event[name] >= 0 && event[name] <= 1, name)
  assert.ok(Number.isInteger(event.mods) && event.mods >= 0 && event.mods <= 15)
  return event
}

const rect = {left: 100, top: 50, width: 400, height: 300}

test("the bounds are the vectors'", () => {
  assert.equal(MAX_EVENTS, vectors.max_events)
  assert.equal(IN_FLIGHT, all.input_in_flight)
})

test("a press, a move and a release are where the image shows them, within it", () => {
  const down = accepted(mouse("down", {clientX: 200, clientY: 125, button: 0, detail: 2, shiftKey: true}, rect))
  assert.deepEqual(down, {k: "mouse", type: "down", x: 0.25, y: 0.25, button: "left", clicks: 2, mods: 8})
  const move = accepted(mouse("move", {clientX: 900, clientY: 0, button: 0}, rect, "left"))
  assert.deepEqual([move.x, move.y, move.button, move.clicks], [1, 0, "left", 0])
  const up = accepted(mouse("up", {clientX: 300, clientY: 200, button: 2}, rect))
  assert.deepEqual([up.button, up.clicks], ["right", 1])
})

test("a wheel is in pixels, a line or a page counted as one, within its bound", () => {
  assert.deepEqual(accepted(wheel({clientX: 300, clientY: 200, deltaX: 0, deltaY: 3, deltaMode: 1}, rect)), {
    k: "wheel",
    x: 0.5,
    y: 0.5,
    dx: 0,
    dy: 120,
    mods: 0
  })
  assert.equal(wheel({clientX: 0, clientY: 0, deltaX: 0, deltaY: 999, deltaMode: 2}, rect).dy, 10000)
})

test("a key types its text unless Control or Meta is held; Enter types a return; one the events cannot carry is none", () => {
  const a = accepted(key("down", {key: "a", code: "KeyA", keyCode: 65}))
  assert.deepEqual([a.text, a.vk, a.mods], ["a", 65, 0])
  assert.equal(accepted(key("down", {key: "a", code: "KeyA", keyCode: 65, ctrlKey: true})).text, "")
  assert.equal(accepted(key("down", {key: "Enter", code: "Enter", keyCode: 13})).text, "\r")
  assert.equal(accepted(key("up", {key: "a", code: "KeyA", keyCode: 65})).text, "")
  assert.equal(accepted(key("down", {key: "é", code: "Key-?", keyCode: 0})).code, "")
  assert.equal(key("down", {key: "Unidentified", code: "", keyCode: 229}), null)
  assert.equal(key("down", {key: "x".repeat(33), code: "", keyCode: 0}), null)
})

test("moves since the last push fold into one, and no push holds more than the bound", () => {
  const q = new Queue()
  q.add({k: "mouse", type: "move", x: 0.1})
  q.add({k: "mouse", type: "move", x: 0.2})
  q.add({k: "mouse", type: "down", x: 0.2})
  q.add({k: "mouse", type: "move", x: 0.3})
  assert.deepEqual(q.take().map((e) => [e.type, e.x]), [["move", 0.2], ["down", 0.2], ["move", 0.3]])
  for (let i = 0; i < MAX_EVENTS + 10; i++) q.add({k: "key", type: "down"})
  assert.equal(q.take().length, MAX_EVENTS)
  assert.deepEqual(q.take(), [])
})

test("the size asked is the canvas's in device pixels, no denser than two to one and no wider than the window", () => {
  assert.deepEqual(size(390, 3), {width: 780, height: 780})
  assert.deepEqual(size(1600, 1), {width: 1280, height: 1280})
  assert.deepEqual(size(4, 1), {width: 16, height: 16})
})

// A canvas and a root element that record what is asked of them.
function mount() {
  const listeners = {}
  const drawn = []
  const canvas = {
    width: 0,
    height: 0,
    parentElement: {clientWidth: 390},
    addEventListener: (type, fn) => (listeners[type] = fn),
    getBoundingClientRect: () => rect,
    focus() {},
    setPointerCapture() {},
    getContext: () => ({drawImage: (image) => drawn.push(image)})
  }
  const rootListeners = {}
  const el = {
    clientWidth: 390,
    dataset: {},
    querySelector: () => canvas,
    addEventListener: (type, fn) => (rootListeners[type] = fn),
    removeEventListener() {}
  }
  const frames = []
  const pushed = []
  const handlers = {}
  const hook = Object.create(
    WorkspaceStream({
      createImageBitmap: async (blob) => ({width: 780, height: 548, size: blob.size, close() {}}),
      requestAnimationFrame: (fn) => frames.push(fn),
      devicePixelRatio: () => 2
    })
  )
  Object.assign(hook, {
    el,
    handleEvent: (event, fn) => (handlers[event] = fn),
    pushEvent: (event, payload) => pushed.push({event, payload})
  })
  hook.mounted()
  const frame = () => frames.splice(0).forEach((fn) => fn())
  // The view names the watch the page holds, or none, and patches it.
  const watch = (id) => {
    if (id) el.dataset.watch = id
    else delete el.dataset.watch
    hook.updated()
  }
  return {hook, canvas, listeners, rootListeners, pushed, handlers, drawn, frame, watch}
}

test("nothing is asked until a watch button is pressed, then the canvas's size is", () => {
  const {rootListeners, pushed} = mount()
  assert.deepEqual(pushed, [])
  rootListeners.click({target: {closest: () => null}})
  assert.deepEqual(pushed, [])
  rootListeners.click({target: {closest: (selector) => (selector === "[data-browser-watch]" ? {} : null)}})
  assert.deepEqual(pushed, [{event: "browser_watch", payload: {width: 780, height: 780}}])
})

test("an image is drawn before the hook says it drew it", async () => {
  const {handlers, pushed, drawn, canvas} = mount()
  await handlers.browser_image({n: 4, jpeg: Buffer.from([0xff, 0xd8, 1, 2]).toString("base64")})
  assert.equal(drawn.length, 1)
  assert.deepEqual([canvas.width, canvas.height, drawn[0].size], [780, 548, 4])
  assert.deepEqual(pushed, [{event: "browser_drawn", payload: {n: 4}}])
})

test("the person's input goes in one push a frame, each event one the vectors accept", () => {
  const {listeners, pushed, frame, watch} = mount()
  watch("w1")
  const stop = () => {}
  listeners.pointerdown({pointerType: "mouse", clientX: 300, clientY: 200, button: 0, detail: 1, preventDefault: stop})
  listeners.pointermove({pointerType: "mouse", clientX: 310, clientY: 200})
  listeners.pointermove({pointerType: "mouse", clientX: 320, clientY: 200})
  listeners.pointerup({pointerType: "mouse", clientX: 320, clientY: 200, button: 0, detail: 1})
  listeners.keydown({key: "h", code: "KeyH", keyCode: 72, preventDefault: stop, stopPropagation: stop})
  listeners.wheel({clientX: 300, clientY: 200, deltaX: 0, deltaY: 50, deltaMode: 0, preventDefault: stop})
  assert.deepEqual(pushed, [])
  frame()
  assert.equal(pushed.length, 1)
  assert.equal(pushed[0].payload.watch, "w1")
  const events = pushed[0].payload.browser_input
  events.forEach(accepted)
  assert.deepEqual(
    events.map((e) => [e.k, e.type]),
    [["mouse", "down"], ["mouse", "move"], ["mouse", "up"], ["key", "down"], ["wheel", undefined]]
  )
  assert.deepEqual([events[1].x, events[1].button], [0.55, "left"])
})

test("a tap is a click where the finger lifted, and a finger drawn across scrolls", () => {
  const {listeners, pushed, frame, canvas, watch} = mount()
  watch("w1")
  canvas.width = 800
  listeners.pointerdown({pointerType: "touch", clientX: 300, clientY: 200})
  listeners.pointerup({pointerType: "touch", clientX: 300, clientY: 200, button: 0, detail: 1})
  listeners.pointerdown({pointerType: "touch", clientX: 300, clientY: 200})
  listeners.pointermove({pointerType: "touch", clientX: 300, clientY: 150})
  listeners.pointerup({pointerType: "touch", clientX: 300, clientY: 150, button: 0})
  frame()
  const events = pushed[0].payload.browser_input
  events.forEach(accepted)
  assert.deepEqual(events.map((e) => [e.k, e.type]), [["mouse", "down"], ["mouse", "up"], ["wheel", undefined]])
  assert.equal(events[2].dy, 100)
})

test("one push is on its way at a time: what comes meanwhile waits here until the server took the last", () => {
  const {listeners, handlers, pushed, frame, watch} = mount()
  watch("w1")
  const stop = () => {}
  const press = (x) => ({pointerType: "mouse", clientX: x, clientY: 200, button: 0, detail: 1, preventDefault: stop})
  listeners.pointerdown(press(300))
  frame()
  assert.equal(pushed.length, 1)
  listeners.pointerup(press(300))
  listeners.keydown({key: "i", code: "KeyI", keyCode: 73, preventDefault: stop, stopPropagation: stop})
  frame()
  assert.equal(pushed.length, 1, "nothing more goes while the first is on its way")
  handlers.browser_input_taken({watch: "w1"})
  frame()
  assert.equal(pushed.length, 2)
  assert.deepEqual(
    pushed[1].payload.browser_input.map((e) => [e.k, e.type]),
    [["mouse", "up"], ["key", "down"]]
  )
})

const typed = (key) => ({key, code: "KeyX", keyCode: 88, preventDefault() {}, stopPropagation() {}})

test("with no watch nothing is kept or sent", () => {
  const {listeners, pushed, frame} = mount()
  listeners.keydown(typed("x"))
  frame()
  assert.deepEqual(pushed, [])
})

// Review round two, finding 6: what the hook holds for a watch ends with it.
test("closing a watch drops what waited for it: nothing goes at the next frame", () => {
  const {listeners, pushed, frame, watch} = mount()
  watch("w1")
  listeners.keydown(typed("x"))
  watch(null)
  frame()
  assert.deepEqual(pushed, [], "a closed watch's waiting input must not go")
})

test("a push on its way when its watch ended holds nothing back from the next watch", () => {
  const {listeners, pushed, frame, watch} = mount()
  watch("w1")
  listeners.keydown(typed("a"))
  frame()
  assert.equal(pushed.length, 1)
  // The watch closed before the server answered the push, so no answer comes.
  watch(null)
  watch("w2")
  listeners.keydown(typed("b"))
  frame()
  assert.equal(pushed.length, 2, "the new watch's input goes")
  assert.deepEqual([pushed[1].payload.watch, pushed[1].payload.browser_input[0].key], ["w2", "b"])
})

test("an answer for another watch lets no second push go", () => {
  const {listeners, handlers, pushed, frame, watch} = mount()
  watch("w2")
  listeners.keydown(typed("a"))
  frame()
  listeners.keydown(typed("b"))
  handlers.browser_input_taken({watch: "w1"})
  frame()
  assert.equal(pushed.length, 1, "the old watch's answer is passed over")
  handlers.browser_input_taken({watch: "w2"})
  frame()
  assert.equal(pushed.length, 2)
})
