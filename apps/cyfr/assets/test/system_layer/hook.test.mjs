// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import SystemLayer from "../../js/system_layer/index.js"

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
    popover: false,
    showModal() {
      calls.push({showModal: now()})
      dialog.open = true
    },
    close() {
      calls.push("close")
      dialog.open = false
    },
    showPopover() {
      calls.push({showPopover: now()})
      dialog.popover = true
    },
    hidePopover() {
      calls.push("hidePopover")
      dialog.popover = false
    },
    matches: (selector) => selector === ":popover-open" && dialog.popover,
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

function mount(dataset) {
  const el = {dataset, querySelector: () => dialog}
  hook = Object.assign(Object.create(SystemLayer), {
    el,
    pushEventTo(target, event, payload) {
      pushed.push({target, event, payload})
    }
  })
  hook.mounted()
  return hook
}

const flush = () => new Promise((resolve) => setImmediate(resolve))

const openPrompt = (id = "p1", dismissable = "true") => ({open: "true", promptId: id, dismissable, mode: "modal"})
const safeMode = {open: "true", promptId: "safe", dismissable: "false", mode: "popover"}

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

  test("safe mode is a popover in the top layer, shown after the same exits", async () => {
    mount(safeMode)
    assert.deepEqual(calls, ["exitPointerLock", "exitFullscreen"])

    doc.settle()
    await flush()

    assert.deepEqual(calls.at(-1), {showPopover: {fullscreen: null, pointerLock: null}})
    assert.equal(dialog.open, false, "safe mode is not modal")
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

  test("safe mode takes focus but does not hold it, so the page stays reachable", async () => {
    await shown(safeMode)
    assert.equal(doc.activeElement.name, "secret")

    doc.activeElement = controls[3]
    assert.equal(tab(false), false, "Tab leaves safe mode for the rest of the page")
    assert.equal(doc.activeElement.name, "confirm")
  })

  test("focus returns to where it was when the prompt closes", async () => {
    await shown()
    assert.notEqual(doc.activeElement, doc.frame)

    hook.el.dataset = {open: "false", promptId: "", dismissable: "false"}
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

  test("does nothing in safe mode", async () => {
    await shown(safeMode)

    const cancel = new Event("cancel", {cancelable: true})
    dialog.dispatchEvent(cancel)

    assert.equal(cancel.defaultPrevented, true)
    assert.deepEqual(pushed, [])
    assert.equal(dialog.popover, true)
  })

  test("a prompt the browser closed anyway is shown again", async () => {
    await shown()
    dialog.open = false
    dialog.dispatchEvent(new Event("close"))
    await flush()

    assert.equal(dialog.open, true)
  })
})
