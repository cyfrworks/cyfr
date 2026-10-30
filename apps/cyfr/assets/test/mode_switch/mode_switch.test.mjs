// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The mode switch's key: exactly Ctrl+Alt+` by the key's place on the
// keyboard, and it follows the link to the mode the page is not in.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import ModeSwitch, {isModeKey, otherMode} from "../../js/hooks/mode_switch.js"

const key = (fields) => ({ctrlKey: false, altKey: false, metaKey: false, shiftKey: false, code: "", ...fields})

describe("the mode switch's key", () => {
  test("is Ctrl+Alt+` and nothing near it", () => {
    assert.equal(isModeKey(key({ctrlKey: true, altKey: true, code: "Backquote"})), true)

    for (const near of [
      {ctrlKey: true, code: "Backquote"},
      {altKey: true, code: "Backquote"},
      {ctrlKey: true, altKey: true, metaKey: true, code: "Backquote"},
      {ctrlKey: true, altKey: true, shiftKey: true, code: "Backquote"},
      {ctrlKey: true, altKey: true, code: "KeyS"},
      {ctrlKey: true, altKey: true, code: "ArrowLeft"}
    ]) {
      assert.equal(isModeKey(key(near)), false, JSON.stringify(near))
    }
  })

  test("follows the link to the other mode, and only on its key", () => {
    const links = [
      {dataset: {mode: "dashboard"}, current: "page", clicked: 0},
      {dataset: {mode: "canvas"}, current: null, clicked: 0}
    ]
    for (const link of links) link.click = () => (link.clicked += 1)

    const root = {
      querySelector: (selector) => {
        assert.equal(selector, '[data-mode]:not([aria-current="page"])')
        return links.find((link) => link.current !== "page") || null
      }
    }

    assert.equal(otherMode(root), links[1])

    const listeners = {}
    globalThis.window = {
      addEventListener: (type, fun) => (listeners[type] = fun),
      removeEventListener: (type) => delete listeners[type]
    }

    try {
      const hook = {el: root, ...ModeSwitch}
      hook.mounted()

      let prevented = 0
      listeners.keydown({...key({ctrlKey: true, code: "Backquote"}), preventDefault: () => (prevented += 1)})
      assert.deepEqual([links[0].clicked, links[1].clicked, prevented], [0, 0, 0])

      listeners.keydown({
        ...key({ctrlKey: true, altKey: true, code: "Backquote"}),
        preventDefault: () => (prevented += 1)
      })
      assert.deepEqual([links[0].clicked, links[1].clicked, prevented], [0, 1, 1])

      hook.destroyed()
      assert.equal(listeners.keydown, undefined)
    } finally {
      delete globalThis.window
    }
  })
})
