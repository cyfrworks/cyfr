// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, mock, test} from "node:test"

import FlashAutoHide, {FADE_MS, SHOWN_MS} from "../../js/hooks/flash_auto_hide.js"

// A timer set while another fires runs on a later tick, as in a browser:
// each step below is its own tick.

// The flash's phx-click for a message: the dismissal naming it.
const click = (shown) => `[["push",{"event":"flash:dismiss","value":{"key":"error","shown":"${shown}"}}]]`

beforeEach(() => mock.timers.enable({apis: ["setTimeout"]}))
afterEach(() => mock.timers.reset())

// The hook as LiveView mounts it on a flash: the element with its
// phx-click, what the hook runs of it, and whether the element was
// removed behind the server's back.
function mount(shown) {
  const ran = []
  const el = {
    style: {},
    removed: false,
    attrs: {"phx-click": click(shown)},
    getAttribute(name) {
      return this.attrs[name] ?? null
    },
    remove() {
      this.removed = true
    }
  }
  const hook = Object.create(FlashAutoHide)
  Object.assign(hook, {el, js: () => ({exec: (encoded) => ran.push(encoded)})})
  hook.mounted()
  return {hook, el, ran}
}

const state = ({el, ran}) => ({opacity: el.style.opacity, ran: [...ran], removed: el.removed})

test("a shown flash fades, then is dismissed by its own click, which asks the server", () => {
  const flash = mount("A")

  mock.timers.tick(SHOWN_MS - 1)
  assert.deepEqual(state(flash), {opacity: "", ran: [], removed: false})

  mock.timers.tick(1)
  assert.deepEqual(state(flash), {opacity: "0", ran: [], removed: false})

  mock.timers.tick(FADE_MS)
  assert.deepEqual(state(flash), {opacity: "0", ran: [click("A")], removed: false})
})

test("a new message in the flash's place shows again and is dismissed after its own time, " +
  "never by the old message's fade", () => {
  const flash = mount("A")
  mock.timers.tick(SHOWN_MS)
  assert.deepEqual(state(flash), {opacity: "0", ran: [], removed: false})

  flash.el.attrs["phx-click"] = click("B")
  flash.hook.updated()
  assert.deepEqual(state(flash), {opacity: "", ran: [], removed: false})

  mock.timers.tick(FADE_MS)
  assert.deepEqual(state(flash), {opacity: "", ran: [], removed: false})

  mock.timers.tick(SHOWN_MS - FADE_MS)
  assert.deepEqual(state(flash), {opacity: "0", ran: [], removed: false})

  mock.timers.tick(FADE_MS)
  assert.deepEqual(state(flash), {opacity: "0", ran: [click("B")], removed: false})
})

test("a patch that keeps the message keeps its fade", () => {
  const flash = mount("A")
  mock.timers.tick(SHOWN_MS - 1)
  flash.hook.updated()
  mock.timers.tick(1)
  mock.timers.tick(FADE_MS)
  assert.deepEqual(state(flash), {opacity: "0", ran: [click("A")], removed: false})
})

test("a flash the server removed first dismisses nothing", () => {
  const flash = mount("A")
  mock.timers.tick(SHOWN_MS)
  flash.hook.destroyed()
  mock.timers.tick(FADE_MS)
  assert.deepEqual(flash.ran, [])
})
