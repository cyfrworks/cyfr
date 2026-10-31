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

// The credential prompt a frame asked for closed (`frame_credential`,
// pushed by `PrismWeb.ShellLive`), as a DOM event on the frame's element
// whose detail is `{saved}`.
export const CREDENTIAL_CLOSED_EVENT = "cyfr:credential-closed"

// A `frame_credential` payload read back: `{frame, saved}` for a frame id
// and a boolean, `null` for anything else.
export function credentialSignal(payload) {
  if (payload === null || typeof payload !== "object") return null
  const {frame, saved} = payload
  return typeof frame === "string" && FRAME_ID.test(frame) && typeof saved === "boolean"
    ? {frame, saved}
    : null
}

// A frame's credential was rotated (`frame_bearer`, pushed by
// `PrismWeb.ShellLive` as it renews or resumes the frame), as a DOM event
// on that frame's element alone whose detail is `{credential}`.
export const FRAME_BEARER_EVENT = "cyfr:frame-bearer"

// A `frame_bearer` payload read back: `{frame, credential}` for a frame id
// and a credential that is a non-empty string, `null` for anything else.
export function bearerSignal(payload) {
  if (payload === null || typeof payload !== "object") return null
  const {frame, credential} = payload
  return typeof frame === "string" && FRAME_ID.test(frame) && typeof credential === "string" && credential !== ""
    ? {frame, credential}
    : null
}

// The canvas switch a keydown asks for: `previous` for Ctrl+Alt+ArrowLeft,
// `next` for Ctrl+Alt+ArrowRight, null for anything else. Heard on the
// shell's page alone, since a frame's keys stay in the frame's document;
// with a window active, the same arrows tile it instead (`windowChord`).
export function switchChord(event) {
  if (!chord(event)) return null
  if (event.key === "ArrowLeft") return "previous"
  if (event.key === "ArrowRight") return "next"
  return null
}

// What a keydown asks of the windows, heard on the shell's page alone (a
// frame's keys stay in the frame): with Ctrl+Alt held, ArrowLeft and
// ArrowRight tile the active window at that side (`{act: "tile", side}`),
// ArrowUp makes it full (`{act: "full"}`), ArrowDown makes it a window
// (`{act: "window"}`), M minimises it and W closes it (`{act:
// "minimise"}`, `{act: "close"}`), and 1 to 8 show that canvas (`{act:
// "canvas", index}`, from 0). Null for anything else. The keys are read
// by `code`, so a layout or Alt's own characters do not change them.
export function windowChord(event) {
  if (!chord(event)) return null
  switch (event.key) {
    case "ArrowLeft":
      return {act: "tile", side: "left"}
    case "ArrowRight":
      return {act: "tile", side: "right"}
    case "ArrowUp":
      return {act: "full"}
    case "ArrowDown":
      return {act: "window"}
  }
  if (event.code === "KeyM") return {act: "minimise"}
  if (event.code === "KeyW") return {act: "close"}
  const digit = /^Digit([1-8])$/.exec(typeof event.code === "string" ? event.code : "")
  if (digit) return {act: "canvas", index: Number(digit[1]) - 1}
  return null
}

// Ctrl and Alt held, and neither Meta nor Shift.
function chord(event) {
  return (
    event !== null &&
    typeof event === "object" &&
    event.ctrlKey === true &&
    event.altKey === true &&
    event.metaKey !== true &&
    event.shiftKey !== true
  )
}

// What the canvas hook tells a canvas frame's bridge to post over its port,
// as a DOM event on the frame's element whose detail is `{verb, args}`: its
// `posture`, what `covered` it, or the `installed` tinctures. The bridge
// posts it as the wire's message to a canvas (`sdk/wire.js`), and posts
// nothing the wire refuses.
export const TO_CANVAS_EVENT = "cyfr:to-canvas"

// A `canvas_installed` payload read back (pushed by `PrismWeb.ShellLive`):
// `{frame, tinctures}` for a frame id and a list, `null` for anything
// else. The bridge holds each tincture to the wire before it posts.
export function installedSignal(payload) {
  if (payload === null || typeof payload !== "object") return null
  const {frame, tinctures} = payload
  return typeof frame === "string" && FRAME_ID.test(frame) && Array.isArray(tinctures)
    ? {frame, tinctures}
    : null
}
