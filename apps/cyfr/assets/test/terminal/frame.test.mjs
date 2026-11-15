// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import {
  MAX_PENDING_UNITS,
  PIECE_UNITS,
  SWALLOWED_OSC,
  TerminalHook,
  decode,
  openLink,
  pieces
} from "../../js/terminal/frame.js"

// A terminal that records what the hook asks of it: its options, the OSC
// handlers registered, the addons loaded, every listener attached and
// every write.
class FakeTerminal {
  constructor(options) {
    this.options = options
    this.rows = 24
    this.cols = 80
    this.osc = new Map()
    this.addons = []
    this.listeners = new Set()
    this.written = []
    this.parser = {registerOscHandler: (n, fn) => this.osc.set(n, fn)}
    FakeTerminal.last = this
  }
  loadAddon(addon) { this.addons.push(addon) }
  open(screen) { this.screen = screen }
  onData(fn) { this.listeners.add("data"); this.data = fn }
  onBell() { this.listeners.add("bell") }
  onTitleChange() { this.listeners.add("title") }
  onBinary() { this.listeners.add("binary") }
  write(bytes, drawn) {
    this.written.push(bytes)
    if (drawn) drawn()
  }
  reset() { this.written.push("reset") }
  focus() {}
  dispose() { this.disposed = true }
}

class FakeFit {
  fit() { FakeTerminal.last.rows = fitted.rows; FakeTerminal.last.cols = fitted.cols }
}

class FakeWebLinks {
  constructor(handler) { this.handler = handler }
}

let fitted
let opened
let windowListeners

beforeEach(() => {
  fitted = {rows: 30, cols: 100}
  opened = []
  windowListeners = {}
  globalThis.window = {
    addEventListener: (type, fn) => (windowListeners[type] = fn),
    removeEventListener: (type) => delete windowListeners[type]
  }
})
afterEach(() => delete globalThis.window)

function mount() {
  const pushed = []
  const handlers = {}
  const hook = Object.create(
    TerminalHook({
      Terminal: FakeTerminal,
      FitAddon: FakeFit,
      WebLinksAddon: FakeWebLinks,
      open: (...args) => opened.push(args)
    })
  )
  const screen = {}
  Object.assign(hook, {
    el: {dataset: {session: "trm_1"}, querySelector: (s) => (s === "[data-terminal-screen]" ? screen : null)},
    pushEvent: (event, payload, reply) => pushed.push({event, payload, reply}),
    handleEvent: (event, fn) => (handlers[event] = fn)
  })
  hook.mounted()
  return {hook, term: FakeTerminal.last, pushed, handlers, screen}
}

const bytes = (text) => Buffer.from(text).toString("base64")

describe("the terminal acts on nothing the program writes", () => {
  test("a clipboard write (OSC 52) is swallowed, and no clipboard addon is loaded", () => {
    const {term} = mount()
    assert.ok(SWALLOWED_OSC.includes(52))
    assert.equal(term.osc.get(52)("c;aGVsbG8="), true)
    assert.deepEqual(term.addons.map((a) => a.constructor.name), ["FakeFit", "FakeWebLinks"])
  })

  test("a title (OSC 0, 1 and 2) is swallowed and no title listener is attached", () => {
    const {term} = mount()
    for (const osc of [0, 1, 2]) assert.equal(term.osc.get(osc)("pwned"), true)
    assert.equal(term.listeners.has("title"), false)
  })

  test("no bell listener is attached", () => {
    const {term} = mount()
    assert.equal(term.listeners.has("bell"), false)
  })

  test("an address opens only on the person's click, http and https alone, with no opener", () => {
    const {term} = mount()
    // Mounting, and the program writing an address, open nothing.
    assert.deepEqual(opened, [])

    const click = term.addons.find((a) => a instanceof FakeWebLinks).handler
    assert.equal(click({}, "https://claude.ai/oauth/authorize?code=1"), true)
    assert.deepEqual(opened, [["https://claude.ai/oauth/authorize?code=1", "_blank", "noopener,noreferrer"]])

    for (const uri of ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "vscode://x", "not a url"]) {
      assert.equal(click({}, uri), false, uri)
      assert.equal(term.options.linkHandler.activate({}, uri), false, uri)
    }
    assert.equal(opened.length, 1)

    // An OSC 8 hyperlink goes the same way, on activation (the click) only.
    assert.equal(term.options.linkHandler.allowNonHttpProtocols, false)
    assert.equal(term.options.linkHandler.activate({}, "http://example.test/"), true)
    assert.deepEqual(opened[1], ["http://example.test/", "_blank", "noopener,noreferrer"])
  })
})

describe("the terminal carries the person's keys and the program's bytes", () => {
  test("attaches once standing at its fitted size and writes what was printed before", () => {
    const {term, pushed} = mount()
    assert.deepEqual(pushed.map((p) => [p.event, p.payload]), [["terminal_ready", {session: "trm_1", rows: 30, cols: 100}]])
    pushed[0].reply({data: bytes("earlier\r\n")})
    assert.equal(Buffer.from(term.written[0]).toString(), "earlier\r\n")
  })

  test("types what the person types, and draws only its own session's output", () => {
    const {term, pushed, handlers} = mount()
    term.data("code-1234\r")
    assert.equal(pushed[1].event, "terminal_input")
    assert.deepEqual(pushed[1].payload, {session: "trm_1", terminal_input: "code-1234\r"})

    handlers.terminal_output({session: "trm_other", data: bytes("not mine")})
    handlers.terminal_output({session: "trm_1", data: bytes("\u001b[32mmine\u001b[0m")})
    assert.equal(term.written.length, 1)
    assert.equal(Buffer.from(term.written[0]).toString(), "\u001b[32mmine\u001b[0m")
  })

  // The server hands the next output only once the last is drawn: the
  // acknowledgement comes from the write's own callback, so the bound
  // holds for the socket too. A tail replaces what is shown.
  // At the end the screen stays to be read, and takes nothing more.
  test("once its program ended, the screen keeps what it shows and sends nothing more", () => {
    const {hook, term, pushed, handlers} = mount()
    handlers.terminal_output({session: "trm_1", delivery: "t-1", data: bytes("why it failed")})
    const before = pushed.length
    handlers.terminal_ended({session: "trm_other"})
    assert.equal(hook.ended, false)

    handlers.terminal_ended({session: "trm_1"})
    assert.equal(term.options.disableStdin, true)
    assert.equal(windowListeners.resize, undefined)
    assert.equal(Buffer.from(term.written.at(-1)).toString(), "why it failed")
    assert.notEqual(term.written.at(-1), "reset")

    term.data("typed after\r")
    handlers.terminal_output({session: "trm_1", delivery: "t-2", data: bytes("late")})
    assert.equal(pushed.length, before)
    assert.equal(term.disposed, undefined)
  })

  test("acknowledges each output by its token once drawn, and a tail replaces the screen", () => {
    const {term, pushed, handlers} = mount()
    handlers.terminal_output({session: "trm_other", delivery: "t-other", data: bytes("not mine")})
    assert.equal(pushed.filter((p) => p.event === "terminal_written").length, 0)

    handlers.terminal_output({session: "trm_1", delivery: "t-1", data: bytes("one")})
    assert.deepEqual(pushed.at(-1), {
      event: "terminal_written",
      payload: {session: "trm_1", delivery: "t-1"},
      reply: undefined
    })

    handlers.terminal_tail({session: "trm_1", delivery: "t-2", data: bytes("the last of it")})
    assert.equal(term.written.at(-2), "reset")
    assert.equal(Buffer.from(term.written.at(-1)).toString(), "the last of it")
    assert.deepEqual(pushed.at(-1).payload, {session: "trm_1", delivery: "t-2"})
    assert.equal(pushed.filter((p) => p.event === "terminal_written").length, 2)
  })

  // A paste goes a piece at a time, each answered before the next leaves,
  // and one past what may wait is not sent at all.
  test("sends a paste a piece at a time, and keeps no more than its bound waiting", () => {
    const {term, pushed} = mount()
    const paste = "x".repeat(PIECE_UNITS * 2 + 5)
    term.data(paste)

    const inputs = () => pushed.filter((p) => p.event === "terminal_input")
    assert.equal(inputs().length, 1)
    assert.equal(inputs()[0].payload.terminal_input.length, PIECE_UNITS)
    inputs()[0].reply({})
    assert.equal(inputs().length, 2)
    inputs()[1].reply({})
    assert.equal(inputs()[2].payload.terminal_input.length, 5)
    inputs()[2].reply({})
    assert.equal(inputs().length, 3)

    term.data("y".repeat(MAX_PENDING_UNITS + 1))
    assert.equal(inputs().length, 3)
  })

  test("never cuts a character's two halves apart", () => {
    const text = "a".repeat(3) + "\u{1F600}" + "b"
    const cut = pieces(text, 4)
    assert.equal(cut.join(""), text)
    assert.deepEqual(cut.map((p) => p.length), [3, 3])
  })

  test("tells the program a new size only when the frame's size changed", () => {
    const {pushed} = mount()
    windowListeners.resize()
    assert.equal(pushed.length, 1)
    fitted = {rows: 40, cols: 120}
    windowListeners.resize()
    assert.deepEqual(pushed[1].payload, {session: "trm_1", rows: 40, cols: 120})
  })

  test("decodes any byte, not only text", () => {
    assert.deepEqual([...decode(Buffer.from([0, 255, 27]).toString("base64"))], [0, 255, 27])
  })

  test("a destroyed frame lets go of its terminal and the window", () => {
    const {hook, term} = mount()
    hook.destroyed()
    assert.equal(term.disposed, true)
    assert.equal(windowListeners.resize, undefined)
  })
})

test("openLink refuses what is no address", () => {
  const open = () => assert.fail("opened")
  assert.equal(openLink("", open), false)
  assert.equal(openLink("//example.test", open), false)
})
