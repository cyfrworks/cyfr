// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What the canvas tells a frame's bridge, as a DOM event on the frame's
// element: the shell froze the frame or made it live again
// (`frame_state`, pushed by `PrismWeb.ShellLive`), or the view's socket
// dropped or came back. A frame acts — its verbs reach the shell — only
// while it is live and the socket is up.

export const FRAME_STATE_EVENT = "cyfr:frame-state"

// The states the shell signals.
export const SHELL_STATES = Object.freeze(["live", "frozen"])

// The socket's.
export const DISCONNECTED = "disconnected"
export const RECONNECTED = "reconnected"

const FRAME_ID = /^[A-Za-z0-9_-]{8,64}$/

// A `frame_state` payload read back: `{frame, state}` for a frame id and a
// shell state, `null` for anything else.
export function frameSignal(payload) {
  if (payload === null || typeof payload !== "object") return null
  const {frame, state} = payload
  return typeof frame === "string" && FRAME_ID.test(frame) && SHELL_STATES.includes(state)
    ? {frame, state}
    : null
}

// The bridge's standing after `signal`, from `standing` (`{state,
// connected}`): a shell state replaces the state, the socket's replaces
// whether it is up, and anything else changes nothing.
export function nextStanding(standing, signal) {
  if (SHELL_STATES.includes(signal)) return {...standing, state: signal}
  if (signal === DISCONNECTED) return {...standing, connected: false}
  if (signal === RECONNECTED) return {...standing, connected: true}
  return standing
}

// Whether a frame in `standing` may act.
export function acting(standing) {
  return standing.state === "live" && standing.connected === true
}
