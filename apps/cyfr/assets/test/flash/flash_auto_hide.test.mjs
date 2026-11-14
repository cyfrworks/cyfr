// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, mock, test} from "node:test"

import FlashAutoHide, {FADE_MS, SHOWN_MS} from "../../js/hooks/flash_auto_hide.js"

const CLEAR = '[["push",{"event":"lv:clear-flash","value":{"key":"error"}}]]'

beforeEach(() => mock.timers.enable({apis: ["setTimeout"]}))
afterEach(() => mock.timers.reset())

// The hook as LiveView mounts it on a flash: the element with its
// phx-click, what the hook runs of it, and whether the element was
// removed behind the server's back.
function mount() {
  const ran = []
  const el = {
    style: {},
    removed: false,
    getAttribute: (name) => (name === "phx-click" ? CLEAR : null),
    remove() {
      this.removed = true
    }
  }
  const hook = Object.create(FlashAutoHide)
  Object.assign(hook, {el, js: () => ({exec: (encoded) => ran.push(encoded)})})
  hook.mounted()
  return {hook, el, ran}
}

test("a shown flash fades, then is cleared by its own click, which asks the server", () => {
  const {el, ran} = mount()

  mock.timers.tick(SHOWN_MS - 1)
  assert.deepEqual({opacity: el.style.opacity, ran, removed: el.removed}, {opacity: undefined, ran: [], removed: false})

  mock.timers.tick(1)
  assert.deepEqual({opacity: el.style.opacity, ran, removed: el.removed}, {opacity: "0", ran: [], removed: false})

  mock.timers.tick(FADE_MS)
  assert.deepEqual({opacity: el.style.opacity, ran, removed: el.removed}, {opacity: "0", ran: [CLEAR], removed: false})
})

test("a flash the server removed first clears nothing", () => {
  const {hook, ran} = mount()
  mock.timers.tick(SHOWN_MS)
  hook.destroyed()
  mock.timers.tick(FADE_MS)
  assert.deepEqual(ran, [])
})
