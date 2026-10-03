// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * The system layer's show and hide, as a state machine with no DOM access.
 * The hook feeds it events and performs the effects it answers, in order.
 *
 * Phases: `hidden`, `opening` (fullscreen and pointer lock are being left)
 * and `shown`. A prompt is never shown before the fullscreen exit it asked
 * for has settled: `ready` for the attempt in flight is the only way from
 * `opening` to `shown`.
 *
 * Modes: a prompt is `modal` (everything else inert, focus trapped in it);
 * safe mode is a `popover`, in the top layer as well but leaving the page
 * operable, so the assistant's panel is neither covered nor disabled.
 *
 * Events:
 *   {type: "sync", open, promptId, dismissable, mode}  what the server renders now
 *   {type: "ready", attempt}                     the fullscreen exit settled
 *   {type: "cancel"}                             Escape, or the dialog's cancel
 *   {type: "closed"}                             the dialog closed on its own
 *   {type: "escalated"}                          fullscreen or pointer lock was
 *                                                entered while shown
 *
 * Effects (strings the hook performs; `show` shows in the state's mode,
 * `close` closes whatever shows):
 *   remember-focus, exit-pointer-lock, exit-fullscreen, show, focus-first,
 *   close, restore-focus, push-dismiss
 */

export const initial = Object.freeze({
  phase: "hidden",
  promptId: null,
  dismissable: false,
  mode: "modal",
  attempt: 0
})

const leave = ["exit-pointer-lock", "exit-fullscreen"]

export function transition(state, event) {
  switch (event.type) {
    case "sync":
      return sync(state, event)

    case "ready":
      if (state.phase === "opening" && event.attempt === state.attempt) {
        return {state: {...state, phase: "shown"}, effects: ["show", "focus-first"]}
      }
      return {state, effects: []}

    case "cancel":
      // Safe mode has no dismissal; the server closes every prompt itself.
      return {state, effects: state.phase === "shown" && state.dismissable ? ["push-dismiss"] : []}

    case "closed":
      // Only the server closes a prompt: one the browser closed while it is
      // still open is shown again, after leaving fullscreen again.
      if (state.phase === "shown") return reopen(state)
      return {state, effects: []}

    case "escalated":
      // A frame that took fullscreen or pointer lock while a prompt shows
      // could cover it; leave both and show the prompt above them again.
      if (state.phase === "shown") return reopen(state, ["close"])
      return {state, effects: []}

    default:
      return {state, effects: []}
  }
}

function sync(state, {open, promptId, dismissable, mode = "modal"}) {
  if (!open) {
    switch (state.phase) {
      case "shown":
        return {state: {...initial, attempt: state.attempt}, effects: ["close", "restore-focus"]}
      case "opening":
        return {state: {...initial, attempt: state.attempt}, effects: ["restore-focus"]}
      default:
        return {state, effects: []}
    }
  }

  switch (state.phase) {
    case "hidden": {
      const attempt = state.attempt + 1
      return {
        state: {phase: "opening", promptId, dismissable, mode, attempt},
        effects: ["remember-focus", ...leave]
      }
    }

    case "opening":
      return {state: {...state, promptId, dismissable, mode}, effects: []}

    default:
      // A prompt in the other mode is closed and shown again in its own.
      if (mode !== state.mode) {
        return reopen({...state, promptId, dismissable, mode}, ["close"])
      }
      if (promptId === state.promptId) return {state: {...state, dismissable}, effects: []}
      // The next prompt in the queue: focus moves to its first control.
      return {state: {...state, promptId, dismissable}, effects: ["focus-first"]}
  }
}

function reopen(state, first = []) {
  const attempt = state.attempt + 1
  return {state: {...state, phase: "opening", attempt}, effects: [...first, ...leave]}
}
