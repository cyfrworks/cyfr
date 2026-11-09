// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import SystemLayer, {clearAllMarked, clearForms, clearMarked, heldInDocument, hop, markForm, openTab, resubmit, takeFragment, tellHeld} from "../../js/system_layer/index.js"

// A document with a frame in fullscreen and pointer lock. Every call the
// hook makes on it, and on the dialog, is recorded in `calls`, in order.
// The fullscreen exit settles only when the test says so (`settle`).
function fakeDocument(calls) {
  const doc = new EventTarget()
  const frame = {name: "frame", focus: () => (doc.activeElement = frame)}
  let settle

  Object.assign(doc, {
    frame,
    activeElement: frame,
    fullscreenElement: frame,
    pointerLockElement: frame,
    exitPointerLock() {
      calls.push("exitPointerLock")
      doc.pointerLockElement = null
    },
    exitFullscreen() {
      calls.push("exitFullscreen")
      return new Promise((resolve) => {
        settle = () => {
          doc.fullscreenElement = null
          resolve()
        }
      })
    },
    settle: () => settle()
  })

  return doc
}

function control(doc, name, attrs = {}) {
  const element = {
    name,
    tabIndex: 0,
    disabled: false,
    type: "button",
    ...attrs,
    focus() {
      doc.activeElement = element
    }
  }
  return element
}

function fakeDialog(doc, calls, controls) {
  const dialog = new EventTarget()
  const now = () => ({fullscreen: doc.fullscreenElement, pointerLock: doc.pointerLockElement})
  Object.assign(dialog, {
    open: false,
    showModal() {
      calls.push({showModal: now()})
      dialog.open = true
    },
    close() {
      calls.push("close")
      dialog.open = false
    },
    querySelectorAll: () => controls
  })
  return dialog
}

let doc, calls, dialog, controls, hook, pushed

beforeEach(() => {
  calls = []
  pushed = []
  doc = fakeDocument(calls)
  globalThis.document = doc
  controls = [
    control(doc, "prompt_id", {type: "hidden"}),
    control(doc, "secret", {type: "password"}),
    control(doc, "dismiss"),
    control(doc, "confirm")
  ]
  dialog = fakeDialog(doc, calls, controls)
})

afterEach(() => {
  hook?.destroyed()
  hook = null
  delete globalThis.document
})

// The frames' moment to see a fullscreen exit, taken at once here; the
// frame tests below hold it open.
const seenAtOnce = () => Promise.resolve()

function mount(dataset) {
  const el = {dataset, querySelector: () => dialog}
  hook = Object.assign(Object.create(SystemLayer), {
    el,
    framesSee: seenAtOnce,
    pushEventTo(target, event, payload) {
      pushed.push({target, event, payload})
    }
  })
  hook.mounted()
  return hook
}

const flush = () => new Promise((resolve) => setImmediate(resolve))

const openPrompt = (id = "p1") => ({open: "true", promptId: id})

async function shown(dataset = openPrompt()) {
  mount(dataset)
  doc.settle()
  await flush()
}

describe("showing a prompt", () => {
  test("pointer lock and fullscreen are left before the prompt shows", async () => {
    mount(openPrompt())

    assert.deepEqual(calls, ["exitPointerLock", "exitFullscreen"])
    assert.equal(dialog.open, false, "shown before the fullscreen exit settled")

    doc.settle()
    await flush()

    assert.deepEqual(calls, [
      "exitPointerLock",
      "exitFullscreen",
      {showModal: {fullscreen: null, pointerLock: null}}
    ])
    assert.equal(dialog.open, true)
  })

  test("a document that is not fullscreen shows the prompt without an exit", async () => {
    doc.fullscreenElement = null
    doc.pointerLockElement = null
    mount(openPrompt())
    await flush()

    assert.deepEqual(calls, [{showModal: {fullscreen: null, pointerLock: null}}])
  })

  test("a frame that takes fullscreen again while the prompt shows is made to leave it", async () => {
    await shown()
    calls.length = 0

    doc.fullscreenElement = doc.frame
    doc.dispatchEvent(new Event("fullscreenchange"))
    assert.deepEqual(calls, ["close", "exitFullscreen"])

    doc.settle()
    await flush()
    assert.deepEqual(calls.at(-1), {showModal: {fullscreen: null, pointerLock: null}})
  })
})

describe("focus", () => {
  test("focus moves to the prompt's first control, skipping hidden inputs", async () => {
    await shown()
    assert.equal(doc.activeElement.name, "secret")
  })

  const tab = (shiftKey) => {
    let prevented = false
    hook.onKeydown({key: "Tab", shiftKey, preventDefault: () => (prevented = true)})
    return prevented
  }

  test("Tab and Shift+Tab wrap inside the prompt", async () => {
    await shown()

    doc.activeElement = controls[3]
    assert.equal(tab(false), true)
    assert.equal(doc.activeElement.name, "secret")

    assert.equal(tab(true), true)
    assert.equal(doc.activeElement.name, "confirm")

    doc.activeElement = doc.frame
    tab(false)
    assert.equal(doc.activeElement.name, "secret", "focus outside the prompt is brought back in")
  })

  test("focus returns to where it was when the prompt closes", async () => {
    await shown()
    assert.notEqual(doc.activeElement, doc.frame)

    hook.el.dataset = {open: "false", promptId: ""}
    hook.updated()

    assert.equal(dialog.open, false)
    assert.equal(doc.activeElement, doc.frame)
  })
})

describe("Escape", () => {
  test("dismisses a prompt, naming the prompt it was drawn for", async () => {
    await shown(openPrompt("p7"))

    const cancel = new Event("cancel", {cancelable: true})
    dialog.dispatchEvent(cancel)

    assert.equal(cancel.defaultPrevented, true, "the browser does not close it; the server does")
    assert.deepEqual(pushed, [{target: hook.el, event: "dismiss", payload: {id: "p7"}}])
  })

  test("a prompt the browser closed anyway is shown again", async () => {
    await shown()
    dialog.open = false
    dialog.dispatchEvent(new Event("close"))
    await flush()

    assert.equal(dialog.open, true)
  })
})

describe("two layers on one page", () => {
  // Every hook on a page hears every pushed event, as LiveView delivers
  // them (`window` events): the page's layer and the person's own panel's
  // each act only on the events that name them.
  let listeners, layers

  beforeEach(() => {
    listeners = []
    layers = []
  })

  afterEach(() => {
    for (const layer of layers) layer.destroyed()
  })

  const push = (event, payload) => {
    for (const listener of listeners) if (listener.event === event) listener.callback(payload)
  }

  // A layer element of its own id, its prompt shown in the top layer.
  function layer(id) {
    const own = fakeDialog(doc, calls, controls)
    const layerHook = Object.assign(Object.create(SystemLayer), {
      el: {id, dataset: openPrompt(`${id}-prompt`), querySelector: () => own},
      framesSee: seenAtOnce,
      handleEvent(event, callback) {
        listeners.push({event, callback})
      },
      pushEventTo(target, event, payload) {
        pushed.push({target: target.id, event, payload})
      }
    })
    layerHook.mounted()
    layers.push(layerHook)
    return {hook: layerHook, dialog: own}
  }

  test("each is its own element in the top layer, shown after the same exits", async () => {
    // Both layers ask the document to leave fullscreen; the one exit
    // settles them both.
    const exits = []
    doc.exitFullscreen = () => {
      calls.push("exitFullscreen")
      return new Promise((resolve) => exits.push(resolve))
    }
    const page = layer("system-layer")
    const panel = layer("system-layer-panel")
    assert.equal(page.dialog.open || panel.dialog.open, false, "shown before fullscreen was left")

    doc.fullscreenElement = null
    for (const settle of exits) settle()
    await flush()

    assert.equal(page.dialog.open, true)
    assert.equal(panel.dialog.open, true)
    assert.deepEqual(calls.filter((call) => call.showModal).map((call) => call.showModal), [
      {fullscreen: null, pointerLock: null},
      {fullscreen: null, pointerLock: null}
    ])
  })

  test("a form is submitted again by the layer the event names, once", () => {
    const submitted = []
    doc.getElementById = (id) => ({requestSubmit: () => submitted.push(id)})
    layer("system-layer")
    layer("system-layer-panel")

    push("system_layer:resubmit", {layer: "system-layer", form: "system-layer-credential"})
    push("system_layer:resubmit", {layer: "elsewhere", form: "vault-create-form"})
    push("system_layer:resubmit", {form: "unnamed-form"})

    assert.deepEqual(submitted, ["system-layer-credential"])
  })

  test("a confirmation's hop opens the account pages in a new tab, for the layer the event names", () => {
    const opened = []
    const open = globalThis.open
    globalThis.open = (url, target, features) => opened.push([url, target, features])
    try {
      layer("system-layer")
      layer("system-layer-panel")
      const url = "https://cyfr.run/account/sign#eyJh"

      push("system_layer:hop", {layer: "system-layer-panel", url})
      push("system_layer:hop", {layer: "elsewhere", url})

      assert.deepEqual(opened, [[url, "_blank", "noopener"]])
    } finally {
      globalThis.open = open
    }
  })

  test("a form is marked and emptied by its own layer alone", () => {
    const resets = []
    doc.getElementById = (id) => ({reset: () => resets.push(id)})
    const page = layer("system-layer")
    const panel = layer("system-layer-panel")

    push("system_layer:mark", {layer: "system-layer", form: "vault-create-form", prompt: "confirmation-cnr_a"})
    assert.equal(page.hook.marks.size, 1)
    assert.equal(panel.hook.marks.size, 0)

    push("system_layer:clear", {layer: "system-layer-panel", prompt: "confirmation-cnr_a", form: "other-form"})
    assert.equal(page.hook.marks.size, 1, "another layer's end clears nothing of this one's")

    push("system_layer:clear", {layer: "system-layer", prompt: "confirmation-cnr_a", form: "vault-create-form"})
    assert.equal(page.hook.marks.size, 0)
    assert.deepEqual(resets, ["other-form", "vault-create-form"])
  })
})

describe("the page's frames while a modal prompt is open", () => {
  // A frame element: its attributes, and `inert` as its bridge sets it
  // (`hooks/iframe_bridge.js`: `this.el.inert = ...`), each write by anyone
  // recorded where a MutationObserver would see it.
  function fakeFrame(name, attrs = {}) {
    const attributes = new Map(Object.entries(attrs))
    const frame = {
      nodeName: "IFRAME",
      name,
      attributes,
      hasAttribute: (attr) => attributes.has(attr),
      getAttribute: (attr) => (attributes.has(attr) ? attributes.get(attr) : null),
      setAttribute(attr, value) {
        attributes.set(attr, String(value))
        written(frame, attr)
      },
      removeAttribute(attr) {
        attributes.delete(attr)
        written(frame, attr)
      },
      set inert(value) {
        if (value) frame.setAttribute("inert", "")
        else frame.removeAttribute("inert")
      },
      get inert() {
        return attributes.has("inert")
      }
    }
    return frame
  }

  // A MutationObserver over the fake page: it hears every attribute write
  // and every added node, and is told of them when the test says so.
  let queue = []
  let observers = []
  function written(target, attributeName) {
    for (const observer of observers) {
      if (observer.watching && observer.options.attributes && observer.options.attributeFilter.includes(attributeName)) {
        queue.push({observer, record: {type: "attributes", target, attributeName}})
      }
    }
  }
  class FakeObserver {
    constructor(callback) {
      this.callback = callback
      this.watching = false
      observers.push(this)
    }
    observe(target, options) {
      this.target = target
      this.options = options
      this.watching = true
    }
    disconnect() {
      this.watching = false
      queue = queue.filter((entry) => entry.observer !== this)
    }
    takeRecords() {
      const mine = queue.filter((entry) => entry.observer === this).map((entry) => entry.record)
      queue = queue.filter((entry) => entry.observer !== this)
      return mine
    }
  }
  // What a browser does at the end of the task: each observer is handed
  // the records queued for it.
  const deliver = () => {
    for (const observer of observers) {
      const records = observer.takeRecords()
      if (records.length && observer.watching) observer.callback(records)
    }
  }
  const added = (observer, nodes) => observer.callback([{type: "childList", addedNodes: nodes}])

  let frames, styles, layers

  beforeEach(() => {
    queue = []
    observers = []
    globalThis.MutationObserver = FakeObserver
    frames = [fakeFrame("live"), fakeFrame("frozen", {inert: "", style: "color: red"})]
    styles = []
    doc.querySelectorAll = (selector) => (selector === "iframe" ? frames : [])
    doc.body = {}
    doc.head = {
      appendChild(node) {
        styles.push(node)
        node.remove = () => styles.splice(styles.indexOf(node), 1)
      }
    }
    doc.createElement = (tag) => ({tag, attributes: {}, setAttribute(name, value) { this.attributes[name] = value }})
    layers = []
  })

  afterEach(() => {
    for (const layer of layers) layer.destroyed()
    delete globalThis.MutationObserver
    delete doc.body
    delete doc.head
    delete doc.createElement
  })

  // A layer's hook on its own element and dialog, and the frames' moment to
  // see a fullscreen exit `see`.
  function layer(id, dataset, see = seenAtOnce) {
    const own = fakeDialog(doc, calls, controls)
    const layerHook = Object.assign(Object.create(SystemLayer), {
      el: {id, dataset, querySelector: () => own},
      framesSee: see,
      pushEventTo() {}
    })
    layerHook.mounted()
    layers.push(layerHook)
    return {hook: layerHook, dialog: own}
  }

  const closeLayer = (hook) => {
    hook.el.dataset = {open: "false", promptId: ""}
    hook.updated()
  }

  // The layer's stylesheet hides every frame; each frame is inert.
  const covered = () => styles.length === 1 && /iframe\s*\{\s*visibility:\s*hidden !important;\s*\}/.test(styles[0].textContent)
  const hidden = (frame) => covered() && frame.hasAttribute("inert")
  const untouched = (frame, attrs) => JSON.stringify([...frame.attributes]) === JSON.stringify(Object.entries(attrs))

  test("on a page that is not fullscreen, every frame is hidden and inert before anything else, and so before the prompt shows", async () => {
    doc.fullscreenElement = null
    doc.pointerLockElement = null
    const {dialog: shown} = layer("system-layer", openPrompt())

    assert.ok(frames.every(hidden))
    assert.equal(calls.length, 0, "hidden before the dialog is shown")
    assert.equal(frames[1].getAttribute("style"), "color: red", "no attribute the server renders is written")

    await flush()
    assert.equal(shown.open, true)
    assert.ok(frames.every(hidden), "still hidden while the prompt shows")
  })

  test("on a fullscreen page, the frames are hidden once the exit settled and they saw it, and only then is the prompt shown", async () => {
    let seen
    const see = () => new Promise((resolve) => (seen = resolve))
    const {dialog: shown} = layer("system-layer", openPrompt(), see)

    assert.deepEqual(calls, ["exitPointerLock", "exitFullscreen"])
    assert.ok(!covered(), "a frame hidden before it saw the exit would keep its fullscreen")

    doc.settle()
    await flush()
    assert.ok(!covered())
    assert.equal(shown.open, false, "not shown while the frames are still to see the exit")

    seen()
    await flush()
    assert.ok(frames.every(hidden))
    assert.equal(shown.open, true)
  })

  test("when the prompt closes, each frame is left as its server and bridge last made it", async () => {
    doc.fullscreenElement = null
    const {hook} = layer("system-layer", openPrompt())
    await flush()

    closeLayer(hook)
    const [live, frozen] = frames
    assert.equal(styles.length, 0, "the stylesheet is gone")
    assert.ok(untouched(live, {}))
    assert.ok(untouched(frozen, {inert: "", style: "color: red"}), "a frozen frame stays inert")
  })

  test("a frame its bridge thawed while a prompt was open is live once it closes, as the review's probe showed", () => {
    doc.fullscreenElement = null
    const canvas = fakeFrame("canvas", {inert: ""})
    frames = [canvas]
    const {hook} = layer("system-layer", openPrompt())
    assert.ok(hidden(canvas))

    // The app over it closed itself: the bridge thawed the canvas.
    canvas.inert = false
    deliver()
    assert.ok(hidden(canvas), "inert again while the prompt shows")

    closeLayer(hook)
    assert.equal(canvas.inert, false, "the live canvas was left inert by the restore")
  })

  test("the review's probe: with no observer at all, a frame thawed during the prompt is never made inert again", async () => {
    const {cover} = await import("../../js/system_layer/index.js")
    delete globalThis.MutationObserver
    // Frozen behind a full app when the prompt opened; and a live frame,
    // which shows the page was covered.
    const canvas = fakeFrame("canvas", {inert: ""})
    const live = fakeFrame("live")
    const page = {querySelectorAll: () => [canvas, live]}
    const probeLayer = {}

    cover(probeLayer, true, page)
    assert.equal(live.inert, true, "the page was covered")
    canvas.inert = false // the app closed itself; the canvas thawed: IframeBridge._apply("live")
    cover(probeLayer, false, page)
    assert.equal(canvas.inert, false, "the live canvas was left inert by the restore")
    assert.equal(live.inert, false)
  })

  test("focus goes back to the frame that had it only once the frame is shown and live again", () => {
    doc.fullscreenElement = null
    const [live] = frames
    let seenAtFocus = null
    live.focus = () => {
      seenAtFocus = {hidden: hidden(live), inert: live.inert}
      doc.activeElement = live
    }
    doc.activeElement = live

    const {hook} = layer("system-layer", openPrompt())
    assert.ok(hidden(live))

    closeLayer(hook)
    assert.deepEqual(seenAtFocus, {hidden: false, inert: false})
    assert.equal(doc.activeElement, live)
  })

  test("a shown prompt closes its dialog with the frames still hidden, then gives them back, then focus", async () => {
    doc.fullscreenElement = null
    const [live] = frames
    const order = []
    live.focus = () => {
      order.push({focus: {hidden: hidden(live), inert: live.inert}})
      doc.activeElement = live
    }
    doc.activeElement = live

    const {hook, dialog} = layer("system-layer", openPrompt())
    await flush()
    assert.equal(dialog.open, true, "the prompt is shown")

    const close = dialog.close.bind(dialog)
    dialog.close = () => {
      order.push({close: {hidden: hidden(live)}})
      close()
    }

    closeLayer(hook)
    assert.deepEqual(order, [{close: {hidden: true}}, {focus: {hidden: false, inert: false}}])
  })

  test("a frame frozen while a prompt was open stays inert once it closes", () => {
    doc.fullscreenElement = null
    const {hook} = layer("system-layer", openPrompt())
    const [live] = frames

    // The shell froze it: the bridge made it inert, over the layer's own.
    live.inert = true
    deliver()

    closeLayer(hook)
    assert.equal(live.inert, true)
  })

  test("a render that drops the layer's inert from a live frame finds it inert again until the prompt closes", () => {
    doc.fullscreenElement = null
    const {hook} = layer("system-layer", openPrompt())
    const [live] = frames

    live.removeAttribute("inert")
    deliver()
    assert.ok(hidden(live))

    closeLayer(hook)
    assert.ok(untouched(live, {}))
  })

  test("with two layers on the page, a frame stays hidden while either has a modal prompt open", async () => {
    const page = layer("system-layer", openPrompt("page"))
    const panel = layer("system-layer-panel", openPrompt("panel"))
    doc.settle()
    await flush()
    assert.ok(frames.every(hidden))

    closeLayer(page.hook)
    assert.ok(frames.every(hidden), "the panel's prompt is still open")

    closeLayer(panel.hook)
    assert.equal(styles.length, 0)
    assert.ok(untouched(frames[0], {}))
  })

  test("a frame added while a prompt is open is made inert as it arrives, and given back", () => {
    doc.fullscreenElement = null
    const {hook} = layer("system-layer", openPrompt())
    const [observer] = observers
    assert.deepEqual(observer.options, {childList: true, subtree: true, attributes: true, attributeFilter: ["inert"]})

    const arrived = fakeFrame("arrived")
    const wrapper = {nodeName: "DIV", querySelectorAll: (selector) => (selector === "iframe" ? [arrived] : [])}
    added(observer, [wrapper])
    assert.ok(hidden(arrived))

    closeLayer(hook)
    assert.equal(observer.watching, false)
    assert.equal(arrived.hasAttribute("inert"), false)
  })

  test("a layer that goes while its prompt is open gives the frames back", () => {
    doc.fullscreenElement = null
    const {hook} = layer("system-layer", openPrompt())
    assert.ok(frames.every(hidden))

    hook.destroyed()
    layers.splice(layers.indexOf(hook), 1)
    assert.equal(styles.length, 0)
    assert.ok(untouched(frames[0], {}))
    assert.ok(untouched(frames[1], {inert: "", style: "color: red"}))
  })

  test("a layer destroyed while its frames are still to see the exit never hides them, as the review's probe showed", async () => {
    let seen
    const {hook} = layer("system-layer", openPrompt(), () => new Promise((resolve) => (seen = resolve)))
    doc.settle()
    await flush()
    assert.equal(typeof seen, "function", "the frames' moment is running")
    assert.ok(!covered(), "not yet hidden")

    // The layer goes (its view unmounted, a navigation) before the moment ends.
    hook.destroyed()
    layers.splice(layers.indexOf(hook), 1)
    seen()
    await flush()
    assert.ok(!covered(), "a destroyed layer hid the frames")
    assert.equal(hook.layer.phase, "hidden", "its state machine ended")

    // Another layer opens and closes a prompt later on a page that is not fullscreen.
    doc.fullscreenElement = null
    const other = layer("system-layer-panel", openPrompt("later"))
    await flush()
    assert.ok(frames.every(hidden))
    closeLayer(other.hook)
    await flush()

    assert.ok(!covered())
    assert.ok(untouched(frames[0], {}))
    assert.ok(untouched(frames[1], {inert: "", style: "color: red"}))
  })
})

// ---------------------------------------------------------------------------
// The newcomer pages' screen 2: the recovery code the page pushes once, and
// Copy
// ---------------------------------------------------------------------------

describe("the account pages' hop and return", () => {
  let location, history

  beforeEach(() => {
    location = Object.getOwnPropertyDescriptor(globalThis, "location")
    history = Object.getOwnPropertyDescriptor(globalThis, "history")
  })

  afterEach(() => {
    if (location) Object.defineProperty(globalThis, "location", location)
    else delete globalThis.location
    if (history) Object.defineProperty(globalThis, "history", history)
    else delete globalThis.history
  })

  // The address, with its fragment, and the history entry it rewrites.
  function address(hash) {
    const replaced = []
    const assigned = []
    Object.defineProperty(globalThis, "location", {
      configurable: true,
      value: {hash, pathname: "/login", search: "", assign: (url) => assigned.push(url)}
    })
    Object.defineProperty(globalThis, "history", {
      configurable: true,
      value: {state: null, replaceState: (_state, _title, url) => replaced.push(url)}
    })
    return {replaced, assigned}
  }

  // An element of the hop and return, in `mode`, with the events it hands
  // its page and the events its page pushes to it.
  function account(mode) {
    const events = []
    const listeners = {}
    const el = {dataset: {account: mode}}
    const page = Object.assign(Object.create(SystemLayer), {
      el,
      pushEvent: (event, payload) => events.push({event, payload}),
      handleEvent: (event, callback) => (listeners[event] = callback)
    })
    page.mounted()
    return {page, events, listeners}
  }

  test("the return hands its page the answer once, and takes it from the address", () => {
    const {replaced} = address("#eyJhbnN3ZXIiOjF9")
    const {page, events} = account("return")

    assert.deepEqual(events, [{event: "account_answer", payload: {answer: "eyJhbnN3ZXIiOjF9"}}])
    assert.deepEqual(replaced, ["/login"])

    // A reconnect hands nothing again.
    page.reconnected()
    assert.equal(events.length, 1)
  })

  test("a return with no fragment hands nothing", () => {
    address("")
    const {events} = account("return")
    assert.deepEqual(events, [])
  })

  for (const mode of ["setup", "invite"]) {
    test(`the ${mode} page hands its page the fragment's token, again on a reconnect`, () => {
      address("#ab12")
      const {page, events} = account(mode)
      page.reconnected()
      assert.deepEqual(events, [
        {event: "account_token", payload: {token: "ab12"}},
        {event: "account_token", payload: {token: "ab12"}}
      ])
    })
  }

  test("the hop sends the browser to the account pages alone", () => {
    const {assigned} = address("")
    const {listeners} = account("return")

    listeners["account:hop"]({url: "https://cyfr.run/account/sign#eyJh"})
    listeners["account:hop"]({url: "http://localhost:4000/account/new#name=mira&request=eyJh"})
    listeners["account:hop"]({url: "javascript:alert(1)"})
    listeners["account:hop"]({url: "https://cyfr.run/elsewhere#eyJh"})
    listeners["account:hop"]({url: null})

    assert.deepEqual(assigned, [
      "https://cyfr.run/account/sign#eyJh",
      "http://localhost:4000/account/new#name=mira&request=eyJh"
    ])
  })

  test("hop, openTab and takeFragment ask nothing of what is not there", () => {
    assert.doesNotThrow(() => hop(null, "https://cyfr.run/account/sign#x"))
    assert.doesNotThrow(() => openTab({}, "https://cyfr.run/account/sign#x"))
    assert.equal(takeFragment(null, null, null), "")
    assert.equal(takeFragment({hash: "#x", pathname: "/login", search: ""}, null, null), "x")
  })
})

describe("a confirmed change's repeat in the browser", () => {
  test("the form that typed it is submitted again, as typed", () => {
    const submitted = []
    const doc = {getElementById: (id) => (id === "system-layer-credential" ? {requestSubmit: () => submitted.push(id)} : null)}

    resubmit(doc, "system-layer-credential")
    resubmit(doc, "gone")
    assert.deepEqual(submitted, ["system-layer-credential"])
  })

  test("every form in a prompt is emptied as it closes", () => {
    const reset = []
    const dialog = {querySelectorAll: (selector) => (selector === "form" ? [{reset: () => reset.push(1)}, {reset: () => reset.push(2)}] : [])}

    clearForms(dialog)
    assert.deepEqual(reset, [1, 2])
  })
})

describe("a page's typed form, marked with its prompt", () => {
  function fakeForms() {
    const make = (id) => ({
      id,
      resets: 0,
      reset() {
        this.resets += 1
      }
    })
    const forms = [make("vault-client-form"), make("vault-create-form"), make("vault-rotate-form")]
    const doc = {getElementById: (id) => forms.find((form) => form.id === id) || null}
    return {doc, forms}
  }

  test("is emptied when that prompt ends, and no other form is", () => {
    const {doc, forms} = fakeForms()
    const marks = new Map()
    markForm(marks, "vault-client-form", "confirmation-cnr_a")
    markForm(marks, "vault-create-form", "confirmation-cnr_b")
    markForm(marks, "gone", "confirmation-cnr_c")

    clearMarked(doc, marks, "confirmation-cnr_a", "vault-client-form")
    assert.equal(forms[0].resets, 1)
    assert.equal(forms[1].resets, 0)
    assert.equal(marks.has("confirmation-cnr_a"), false)
    assert.equal(marks.has("confirmation-cnr_b"), true)

    // A form that is gone from the page is skipped.
    clearMarked(doc, marks, "confirmation-cnr_c", "gone")
    assert.equal(forms[1].resets, 0)
  })

  test("the mark is held apart from the form, so a re-render that drops the form's attributes keeps it", () => {
    const {doc, forms} = fakeForms()
    const marks = new Map()
    markForm(marks, "vault-create-form", "confirmation-cnr_b")

    // The form carries no mark of its own a LiveView patch could remove;
    // the prompt's end clears it by the id the mark holds.
    assert.equal(Object.keys(forms[1]).includes("attributes"), false)
    clearMarked(doc, marks, "confirmation-cnr_b")
    assert.equal(forms[1].resets, 1)
  })

  test("the form a prompt's end names is emptied even with no mark here", () => {
    const {doc, forms} = fakeForms()
    clearMarked(doc, new Map(), "confirmation-cnr_z", "vault-rotate-form")
    assert.equal(forms[2].resets, 1)
  })

  test("a reconnect empties every marked form: its prompts ended with the old page process", () => {
    const {doc, forms} = fakeForms()
    const marks = new Map()
    markForm(marks, "vault-client-form", "confirmation-cnr_a")
    markForm(marks, "vault-rotate-form", "confirmation-cnr_b")

    clearAllMarked(doc, marks)
    assert.deepEqual(forms.map((form) => form.resets), [1, 0, 1])
    assert.equal(marks.size, 0)

    SystemLayer.reconnected.call({marks: undefined})
  })
})

describe("a record another layer of the document holds", () => {
  afterEach(() => heldInDocument.clear())

  test("is handed to every other layer, and not to the layer that holds it", () => {
    const pushed = []
    const layer = (id) => ({el: {id}, pushEventTo: (target, event, payload) => pushed.push({id: target.id, event, payload})})

    tellHeld(layer("system-layer"), "system-layer-desktop", "cnf_a")
    tellHeld(layer("system-layer-desktop"), "system-layer-desktop", "cnf_a")

    assert.deepEqual(pushed, [{id: "system-layer", event: "held_elsewhere", payload: {ref: "cnf_a"}}])
    assert.equal(heldInDocument.get("cnf_a"), "system-layer-desktop")
  })

  test("is handed to a layer that mounts after it was told, as the page moves", () => {
    heldInDocument.set("cnf_b", "system-layer-desktop")
    const pushed = []
    const el = {id: "system-layer", dataset: {}, querySelector: () => dialog}
    const later = Object.assign(Object.create(SystemLayer), {
      el,
      framesSee: seenAtOnce,
      pushEventTo: (target, event, payload) => pushed.push({event, payload})
    })
    later.mounted()

    assert.deepEqual(pushed, [{event: "held_elsewhere", payload: {ref: "cnf_b"}}])
  })

  test("of another shape is handed to nobody", () => {
    const pushed = []
    tellHeld({el: {id: "system-layer"}, pushEventTo: () => pushed.push(1)}, "system-layer-desktop", 7)
    tellHeld({el: {id: "system-layer"}, pushEventTo: () => pushed.push(1)}, null, "cnf_c")
    assert.deepEqual(pushed, [])
    assert.equal(heldInDocument.size, 0)
  })
})
