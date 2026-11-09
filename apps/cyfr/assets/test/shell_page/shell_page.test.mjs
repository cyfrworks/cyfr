// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import ShellPage, {desktopKey, focusOf} from "../../js/hooks/shell_page.js"

const ORIGIN = "https://cyfr.example"
let windowListeners
function at(href) {
  windowListeners = {}
  globalThis.window = {
    location: {origin: ORIGIN, href: ORIGIN + href},
    addEventListener: (type, fn) => (windowListeners[type] = fn),
    removeEventListener: (type, fn) => {
      if (windowListeners[type] === fn) delete windowListeners[type]
    }
  }
}
beforeEach(() => at("/a/@alice"))
afterEach(() => delete globalThis.window)

// The hook as LiveView mounts it: the shell's pushes it handles, the
// events it pushes, and the page moves it asks for.
function mount() {
  const handlers = {}
  const pushed = []
  const moves = []
  const hook = Object.create(ShellPage)
  Object.assign(hook, {
    el: {},
    handleEvent: (event, fn) => (handlers[event] = fn),
    pushEvent: (event, payload) => pushed.push({event, payload}),
    js: () => ({navigate: (to) => moves.push(to)})
  })
  hook.mounted()
  return {hook, handlers, pushed, moves}
}

describe("the shell's navigate", () => {
  test("moves the page to the Dashboard page the shell names", () => {
    const {handlers, moves} = mount()
    handlers.navigate({to: "/a/@alice/schedules"})
    assert.deepEqual(moves, ["/a/@alice/schedules"])
  })

  test("moves nowhere for an address off this origin or of another shape", () => {
    const {handlers, moves} = mount()
    handlers.navigate({to: "https://example.com/a"})
    handlers.navigate({to: "//example.com/a"})
    handlers.navigate({to: 42})
    handlers.navigate({})
    assert.deepEqual(moves, [])
  })
})

describe("a desktop address naming a tincture", () => {
  test("is handed to the shell when the hook mounts on it", () => {
    at("/a/@alice?publisher=local&tincture_name=palette-app")
    const {pushed} = mount()
    assert.deepEqual(pushed, [{event: "focus_named", payload: {publisher: "local", name: "palette-app"}}])
  })

  test("is handed to the shell when the page moves to it", () => {
    const {pushed} = mount()
    assert.deepEqual(pushed, [])
    windowListeners["phx:page-loading-stop"]({detail: {kind: "redirect", to: ORIGIN + "/?publisher=local&tincture_name=w"}})
    assert.deepEqual(pushed, [{event: "focus_named", payload: {publisher: "local", name: "w"}}])
  })

  test("is no longer heard once the hook is gone", () => {
    const {hook} = mount()
    hook.destroyed()
    assert.equal(windowListeners["phx:page-loading-stop"], undefined)
  })
})

describe("focusOf", () => {
  test("reads the desktop's addresses alone", () => {
    for (const path of ["/", "/a", "/a/@alice", "/a/@alice/"]) {
      assert.deepEqual(focusOf(path + "?publisher=p&tincture_name=n", ORIGIN), {publisher: "p", name: "n"}, path)
    }
    assert.equal(focusOf("/a/@alice/components?publisher=p&tincture_name=n", ORIGIN), null)
    assert.equal(focusOf("https://other.example/?publisher=p&tincture_name=n", ORIGIN), null)
  })

  test("needs both names", () => {
    assert.equal(focusOf("/?publisher=p", ORIGIN), null)
    assert.equal(focusOf("/?tincture_name=n", ORIGIN), null)
  })
})

// An element at `path`, a list of the selectors it sits inside.
const el = (inside = [], extra = {}) => ({
  closest: (selector) => (selector.split(",").map((s) => s.trim()).some((s) => inside.includes(s)) ? {} : null),
  ...extra
})

describe("the desktop's keys", () => {
  test("an arrow, Enter or Escape typed on the desktop is the shell's keynav", () => {
    const {pushed} = mount()
    windowListeners.keydown({key: "Enter", target: el()})
    windowListeners.keydown({key: "ArrowLeft", target: el()})
    windowListeners.keydown({key: "a", target: el()})
    assert.deepEqual(pushed, [
      {event: "keynav", payload: {key: "Enter"}},
      {event: "keynav", payload: {key: "ArrowLeft"}}
    ])
  })

  test("a key typed in a field or over the desktop stays there", () => {
    for (const inside of [["input"], ["textarea"], ["#page-layer"], ["#chat-sheet"], ["#aqua-panel-sheet"], ["dialog[open]"]]) {
      assert.equal(desktopKey({key: "Enter", target: el(inside)}), false, inside[0])
    }
    assert.equal(desktopKey({key: "Enter", target: el([], {isContentEditable: true})}), false)
  })

  test("a key with a modifier held is not the picker's", () => {
    for (const mod of ["ctrlKey", "altKey", "metaKey"]) {
      assert.equal(desktopKey({key: "ArrowLeft", [mod]: true, target: el()}), false, mod)
    }
  })

  test("is no longer heard once the hook is gone", () => {
    const {hook} = mount()
    hook.destroyed()
    assert.equal(windowListeners.keydown, undefined)
  })
})
