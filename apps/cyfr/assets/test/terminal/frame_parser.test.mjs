// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The hook with the vendored xterm.js's own parser: what a program prints
// is parsed for real, and what the terminal sends the program in answer is
// what the hook pushes as input. Only the DOM, focus, fitting and the
// server are stood in for.

import assert from "node:assert/strict"
import {afterEach, beforeEach, test} from "node:test"

import {Terminal as Xterm} from "../../vendor/xterm-6.0.0/xterm.mjs"
import {TerminalHook} from "../../js/terminal/frame.js"

class Terminal extends Xterm {
  open() {}
  focus() {}
}

class Addon {
  activate() {}
  dispose() {}
  fit() {}
}

beforeEach(() => {
  globalThis.window = {addEventListener() {}, removeEventListener() {}}
})
afterEach(() => delete globalThis.window)

function mount() {
  const pushed = []
  const hook = Object.create(
    TerminalHook({Terminal, FitAddon: Addon, WebLinksAddon: Addon, open: () => {}})
  )
  Object.assign(hook, {
    el: {dataset: {session: "trm_1"}, querySelector: () => ({})},
    handleEvent() {},
    pushEvent: (event, payload, reply) => {
      pushed.push({event, payload})
      reply?.({})
    }
  })
  hook.mounted()
  return {hook, pushed}
}

// What the program prints, parsed, and what the terminal sent it back.
async function answers(printed) {
  const {hook, pushed} = mount()
  try {
    await new Promise((resolve) => hook.term.write(printed, resolve))
    return pushed.filter((p) => p.event === "terminal_input").map((p) => p.payload.terminal_input)
  } finally {
    hook.destroyed()
  }
}

test("the standard reports a program asks for are sent to it", async () => {
  assert.deepEqual(await answers("\x1b[6n\x1b[c\x1b[>c"), [
    "\x1b[1;1R",
    "\x1b[?1;2c",
    "\x1b[>0;276;0c"
  ])
})

// A title is text the program chose: asked for, it would be typed back to
// whatever reads the terminal, a shell among them.
test("a title or icon label set and then asked for sends nothing", async () => {
  assert.deepEqual(
    await answers("\x1b]0;rm -rf ~\r\x07\x1b]2;evil\r\x07\x1b]1;evil\r\x07\x1b[21t\x1b[20t"),
    []
  )
})

test("every window operation is off and its reports send nothing", async () => {
  const {hook} = mount()
  try {
    assert.deepEqual(hook.term.options.windowOptions, {})
  } finally {
    hook.destroyed()
  }
  assert.deepEqual(await answers("\x1b[11t\x1b[13t\x1b[14t\x1b[16t\x1b[18t\x1b[19t\x1b[22;0t\x1b[23;0t"), [])
})

test("a settings query answers a value, never the words it was asked", async () => {
  assert.deepEqual(await answers("\x1bP$qrm -rf ~\x1b\\"), ["\x1bP0$r\x1b\\"])
  assert.deepEqual(await answers("\x1bP$qm\x1b\\"), ["\x1bP1$r0m\x1b\\"])
})

test("an answerback request (ENQ) sends nothing", async () => {
  assert.deepEqual(await answers("\x05"), [])
})
