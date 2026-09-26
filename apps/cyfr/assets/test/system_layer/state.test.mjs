// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {nextStop, tabOrder} from "../../js/system_layer/focus.js"
import {initial, transition} from "../../js/system_layer/state.js"

// Feed events in order; answer the final state and every effect, in order.
function run(events, state = initial) {
  const effects = []
  for (const event of events) {
    const next = transition(state, event)
    state = next.state
    effects.push(...next.effects)
  }
  return {state, effects}
}

const open = (promptId, dismissable = true, mode = "modal") => ({
  type: "sync",
  open: true,
  promptId,
  dismissable,
  mode
})
const closed = {type: "sync", open: false, promptId: null, dismissable: false}

describe("the tab order", () => {
  test("positive tabindex first, ascending, then tabindex 0 in document order", () => {
    const order = tabOrder([
      {tabIndex: 0},
      {tabIndex: 2},
      {tabIndex: 0},
      {tabIndex: 1},
      {tabIndex: 2}
    ])
    assert.deepEqual(order, [3, 1, 4, 0, 2])
  })

  test("a negative tabindex, a disabled control and a hidden one are never reached", () => {
    const order = tabOrder([
      {tabIndex: -1},
      {tabIndex: 0, disabled: true},
      {tabIndex: 0, hidden: true},
      {tabIndex: 0}
    ])
    assert.deepEqual(order, [3])
  })

  test("Tab and Shift+Tab wrap at both ends", () => {
    assert.equal(nextStop(3, 0, false), 1)
    assert.equal(nextStop(3, 2, false), 0)
    assert.equal(nextStop(3, 0, true), 2)
    assert.equal(nextStop(3, 1, true), 0)
  })

  test("from outside the prompt focus enters it; an empty prompt has no stop", () => {
    assert.equal(nextStop(3, -1, false), 0)
    assert.equal(nextStop(3, -1, true), 2)
    assert.equal(nextStop(0, -1, false), -1)
  })
})

describe("show and hide", () => {
  test("opening leaves pointer lock and fullscreen, and shows nothing yet", () => {
    const {state, effects} = run([open("p1")])
    assert.equal(state.phase, "opening")
    assert.deepEqual(effects, ["remember-focus", "exit-pointer-lock", "exit-fullscreen"])
  })

  test("the prompt shows once the fullscreen exit it asked for settles", () => {
    const {state: opening} = run([open("p1")])
    const {state, effects} = run([{type: "ready", attempt: opening.attempt}], opening)
    assert.equal(state.phase, "shown")
    assert.deepEqual(effects, ["show", "focus-first"])
  })

  test("a settled exit for an earlier attempt shows nothing", () => {
    const {state: opening} = run([open("p1")])
    const {state, effects} = run([{type: "ready", attempt: opening.attempt - 1}], opening)
    assert.equal(state.phase, "opening")
    assert.deepEqual(effects, [])
  })

  test("closing closes the dialog and returns focus", () => {
    const {state: opening} = run([open("p1")])
    const {state, effects} = run([{type: "ready", attempt: opening.attempt}, closed], opening)
    assert.equal(state.phase, "hidden")
    assert.deepEqual(effects, ["show", "focus-first", "close", "restore-focus"])
  })

  test("a prompt cleared before it showed only returns focus", () => {
    const {state, effects} = run([open("p1"), closed])
    assert.equal(state.phase, "hidden")
    assert.deepEqual(effects, ["remember-focus", "exit-pointer-lock", "exit-fullscreen", "restore-focus"])
  })

  test("the next prompt in the queue takes focus without closing the dialog", () => {
    const {state: opening} = run([open("p1")])
    const {state: shown} = run([{type: "ready", attempt: opening.attempt}], opening)
    const {state, effects} = run([open("p2")], shown)
    assert.equal(state.phase, "shown")
    assert.equal(state.promptId, "p2")
    assert.deepEqual(effects, ["focus-first"])
  })

  test("a prompt in the other mode closes the shown one and opens again, leaving fullscreen first", () => {
    const {state: opening} = run([open("p1")])
    const {state: shown} = run([{type: "ready", attempt: opening.attempt}], opening)
    const {state, effects} = run([open("safe", false, "popover")], shown)
    assert.equal(state.phase, "opening")
    assert.equal(state.mode, "popover")
    assert.deepEqual(effects, ["close", "exit-pointer-lock", "exit-fullscreen"])

    const {state: reshown, effects: after} = run([{type: "ready", attempt: state.attempt}], state)
    assert.equal(reshown.phase, "shown")
    assert.deepEqual(after, ["show", "focus-first"])
  })

  test("the same prompt rendered again does nothing", () => {
    const {state: opening} = run([open("p1")])
    const {state: shown} = run([{type: "ready", attempt: opening.attempt}], opening)
    assert.deepEqual(run([open("p1")], shown).effects, [])
  })
})

describe("dismissal", () => {
  const shownWith = (dismissable) => {
    const {state: opening} = run([open("p1", dismissable, dismissable ? "modal" : "popover")])
    return run([{type: "ready", attempt: opening.attempt}], opening).state
  }

  test("Escape dismisses a dismissable prompt", () => {
    assert.deepEqual(run([{type: "cancel"}], shownWith(true)).effects, ["push-dismiss"])
  })

  test("Escape does nothing in safe mode", () => {
    assert.deepEqual(run([{type: "cancel"}], shownWith(false)).effects, [])
  })

  test("a dialog the browser closed while it is open is shown again, after leaving fullscreen", () => {
    const {state, effects} = run([{type: "closed"}], shownWith(false))
    assert.equal(state.phase, "opening")
    assert.deepEqual(effects, ["exit-pointer-lock", "exit-fullscreen"])
  })

  test("fullscreen or pointer lock taken while a prompt shows is left, and the prompt shown above it", () => {
    const {state, effects} = run([{type: "escalated"}], shownWith(true))
    assert.equal(state.phase, "opening")
    assert.deepEqual(effects, ["close", "exit-pointer-lock", "exit-fullscreen"])
  })
})
