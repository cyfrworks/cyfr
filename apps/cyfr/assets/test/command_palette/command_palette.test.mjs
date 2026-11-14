// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, test} from "node:test"

import CommandPalette from "../../js/hooks/command_palette.js"

beforeEach(() => {
  globalThis.window = {addEventListener: () => {}, removeEventListener: () => {}}
})
afterEach(() => delete globalThis.window)

// The hook on a palette element whose search field records each focus.
function mount(open) {
  const focused = []
  const field = {focus: () => focused.push("input")}
  const el = {dataset: {open: open ? "true" : "false"}, querySelector: (sel) => (sel === "input" ? field : null)}
  const hook = Object.create(CommandPalette)
  Object.assign(hook, {el, pushEventTo: () => {}})
  hook.mounted()
  return {hook, el, focused}
}

test("opening the palette puts the focus in its search field", () => {
  const {hook, el, focused} = mount(false)
  el.dataset.open = "true"
  hook.updated()
  assert.deepEqual(focused, ["input"])
})

test("a patch while the palette stays open moves no focus, and a closed palette takes none", () => {
  const {hook, el, focused} = mount(false)
  hook.updated()
  assert.deepEqual(focused, [])
  el.dataset.open = "true"
  hook.updated()
  hook.updated()
  assert.deepEqual(focused, ["input"])
  el.dataset.open = "false"
  hook.updated()
  el.dataset.open = "true"
  hook.updated()
  assert.deepEqual(focused, ["input", "input"])
})
