// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {coveredRects, postureFor, swipeDirection} from "./geometry.js"
import {
  CREDENTIAL_CLOSED_EVENT,
  DISCONNECTED,
  FRAME_BEARER_EVENT,
  FRAME_STATE_EVENT,
  RECONNECTED,
  TO_CANVAS_EVENT,
  bearerSignal,
  credentialSignal,
  frameSignal,
  installedSignal
} from "./signals.js"
import {WindowGestures} from "./windows.js"

const SHELF = "#canvas-shelf"

// What a canvas is told covers it: the windows over it. A tile narrows its
// frame instead, and a full app's cover is the frozen state.
const COVERING = ["window"]

/**
 * Canvas hook — the client's half of `PrismWeb.CanvasLive`.
 *
 * It reports the posture (`posture`, `hand` under 768 CSS pixels wide and
 * `desk` otherwise) to the canvas on mount, whenever it changes and when
 * the socket comes back; turns the window chrome's gestures and the keys
 * into the shell's arrangement events (`./windows.js`); relays the shell's `frame_state`
 * signals to each frame's bridge as a `cyfr:frame-state` event on the
 * frame's element, its `frame_credential` signals (a credential prompt a
 * frame asked for closed) as `cyfr:credential-closed`, its `frame_bearer`
 * pushes (a frame's rotated credential) as `cyfr:frame-bearer` on the one
 * frame they name, and its `canvas_installed` pushes to the canvas frame
 * they name.
 *
 * Each canvas frame (`data-frame-kind="canvas"`, a canvas or a validation
 * frame) is told, through its bridge (`cyfr:to-canvas`), the posture and
 * the rectangles of the shown windows over it, in its own pixels,
 * whenever either changes; its bridge holds the latest until the frame's
 * handshake and posts it then.
 *
 * The keys are heard here, on the shell's own page, never in a frame: the
 * window chords (`windowChord`), Ctrl+Alt with an arrow, M or W acting on
 * the active app, with 1 to 8 showing that canvas, and with no active app
 * the arrows switching canvases as `switch_canvas` (`previous` or `next`).
 * A horizontal swipe on the shelf switches too, leftward `next` and
 * rightward `previous`. A frame's keys and pointer stay in the frame's
 * document and never reach it.
 *
 * While the socket is down the connection is marked, and every frame's
 * bridge is told the socket is down so no frame acts until it is back.
 *
 * The hook sits on an empty element of its own inside the canvas layer,
 * which carries `data-posture`. LiveView locks the
 * element an event is pushed from until its reply, and a locked element
 * around the frames would bring back a frame the layer discarded meanwhile;
 * so every push goes from the hook's own element, and the layer, read as
 * that element's parent, is where the pointer is heard, its size measured,
 * its stylesheet scoped and its frames, hosts and shelf found.
 */
const Canvas = {
  mounted() {
    this._layer = this.el.parentElement
    this._posture = null
    this._connected = true
    this._style = null
    this._told = new Map()
    this._swipe = null

    this._onResize = () => this._layout()
    globalThis.window?.addEventListener("resize", this._onResize)

    this._onKeydown = (event) => {
      this._windowKey(event)
    }
    globalThis.window?.addEventListener("keydown", this._onKeydown)

    this._onPointerDown = (event) => this._swipeStart(event)
    this._onPointerUp = (event) => this._swipeEnd(event)
    this._onPointerCancel = () => (this._swipe = null)
    this._layer.addEventListener?.("pointerdown", this._onPointerDown)
    this._layer.addEventListener?.("pointerup", this._onPointerUp)
    this._layer.addEventListener?.("pointercancel", this._onPointerCancel)

    this.handleEvent("frame_state", (payload) => this._relay(payload))
    this.handleEvent("frame_credential", (payload) => this._credentialClosed(payload))
    this.handleEvent("frame_bearer", (payload) => this._bearer(payload))
    this.handleEvent("canvas_installed", (payload) => this._installed(payload))

    this._windowsMount()
    this._watchFrames()
    this._layout()
  },

  updated() {
    this._layout()
  },

  disconnected() {
    this._connected = false
    this._windowsDisconnected()
    this._mark()
    this._broadcast(DISCONNECTED)
  },

  reconnected() {
    this._connected = true
    this._mark()
    this._broadcast(RECONNECTED)
    // A new socket is a new view, which assumes `desk` until told.
    this._posture = null
    this._layout()
  },

  destroyed() {
    if (this._frameWatch) this._frameWatch.disconnect()
    this._windowsDestroy()
    globalThis.window?.removeEventListener("resize", this._onResize)
    globalThis.window?.removeEventListener("keydown", this._onKeydown)
    this._layer.removeEventListener?.("pointerdown", this._onPointerDown)
    this._layer.removeEventListener?.("pointerup", this._onPointerUp)
    this._layer.removeEventListener?.("pointercancel", this._onPointerCancel)
  },

  // A frame opened, stood elsewhere, shown or hidden after the hook mounted
  // changes the frames' container, not the hook's element, so the hook
  // watches the container and tells the canvases again, at most once a
  // frame: a canvas opened after the hook hears its posture and what
  // covers it, and every canvas hears it again when a window settles.
  _watchFrames() {
    const Observer = globalThis.MutationObserver
    const frames = this._layer.querySelector?.(`#${this._layer.id}-frames`)
    if (typeof Observer !== "function" || !frames) return
    this._frameWatch = new Observer(() => this._relayout())
    this._frameWatch.observe(frames, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["style", "class", "data-canvas-shown", "data-canvas-place"]
    })
  },

  _relayout() {
    if (this._relayoutPending) return
    this._relayoutPending = true
    const later = globalThis.requestAnimationFrame || ((fn) => setTimeout(fn, 16))
    later(() => {
      this._relayoutPending = false
      this._layout()
    })
  },

  _layout() {
    const posture = postureFor(globalThis.window?.innerWidth)

    if (this._connected && posture !== this._posture) {
      this._posture = posture
      this.pushEventTo(this.el, "posture", {posture})
    }

    this._tellCanvases(posture)
  },

  // Each canvas frame's posture and what covers it, each sent only when it
  // changed for that frame.
  _tellCanvases(posture) {
    const covering = this._covering()

    for (const frame of this._canvasFrames()) {
      this._tell(frame, "posture", {posture})
      const box = boxOf(frame)
      if (box) this._tell(frame, "covered", {rects: coveredRects(box, covering)})
    }
  },

  _covering() {
    const shown = Array.from(this._layer.querySelectorAll('[data-canvas-shown="true"]'))
    return shown
      .filter((element) => COVERING.includes(element.dataset?.canvasPlace))
      .map(boxOf)
      .filter((box) => box !== null)
  },

  _tell(frame, verb, args) {
    const id = frame.dataset.frameId
    const told = this._told.get(id) || {}
    const value = JSON.stringify(args)
    if (told[verb] === value) return
    this._told.set(id, {...told, [verb]: value})
    frame.dispatchEvent(new CustomEvent(TO_CANVAS_EVENT, {detail: {verb, args}}))
  },

  // The stylesheet that holds a wrapper where a gesture put it lives in the
  // layer's `-geometry` element, which the server renders empty with
  // `phx-update="ignore"`, so no patch touches it.
  _stylesheet() {
    if (this._style && this._style.isConnected) return this._style
    const host = this._layer.querySelector(`#${this._layer.id}-geometry`)
    if (!host) return null
    this._style = this._layer.ownerDocument.createElement("style")
    host.appendChild(this._style)
    return this._style
  },

  _mark() {
    const marker = this._layer.querySelector(`#${this._layer.id}-status [data-canvas-connection]`)
    if (!marker) return
    marker.dataset.canvasConnection = this._connected ? "connected" : "disconnected"
    marker.hidden = this._connected
  },

  _frames() {
    return Array.from(this._layer.querySelectorAll("iframe[data-frame-id]"))
  },

  _canvasFrames() {
    return this._frames().filter((frame) => frame.dataset.frameKind === "canvas")
  },

  _relay(payload) {
    const signal = frameSignal(payload)
    if (!signal) return
    const frame = this._frames().find((el) => el.dataset.frameId === signal.frame)
    if (frame) frame.dispatchEvent(stateEvent(signal.state))
  },

  _credentialClosed(payload) {
    const signal = credentialSignal(payload)
    if (!signal) return
    const frame = this._frames().find((el) => el.dataset.frameId === signal.frame)
    if (frame) frame.dispatchEvent(new CustomEvent(CREDENTIAL_CLOSED_EVENT, {detail: {saved: signal.saved}}))
  },

  _bearer(payload) {
    const signal = bearerSignal(payload)
    if (!signal) return
    const frame = this._frames().find((el) => el.dataset.frameId === signal.frame)
    if (frame) frame.dispatchEvent(new CustomEvent(FRAME_BEARER_EVENT, {detail: {credential: signal.credential}}))
  },

  _installed(payload) {
    const signal = installedSignal(payload)
    if (!signal) return
    const frame = this._canvasFrames().find((el) => el.dataset.frameId === signal.frame)
    if (frame) {
      frame.dispatchEvent(
        new CustomEvent(TO_CANVAS_EVENT, {detail: {verb: "installed", args: {tinctures: signal.tinctures}}})
      )
    }
  },

  _swipeStart(event) {
    const strip = event.target && typeof event.target.closest === "function" ? event.target.closest(SHELF) : null
    if (!strip) return
    this._swipe = {pointer: event.pointerId, x: event.clientX, y: event.clientY}
    // A press on one of the shelf's buttons keeps its click, which a
    // capture by the shelf would take.
    if (event.target.closest("button")) return
    if (typeof strip.setPointerCapture === "function") strip.setPointerCapture(event.pointerId)
  },

  _swipeEnd(event) {
    const start = this._swipe
    this._swipe = null
    if (!start || event.pointerId !== start.pointer) return
    const direction = swipeDirection(start, {x: event.clientX, y: event.clientY})
    if (direction !== null && this._connected) this.pushEvent("switch_canvas", {direction})
  },

  _broadcast(state) {
    for (const frame of this._frames()) frame.dispatchEvent(stateEvent(state))
  }
}

function stateEvent(state) {
  return new CustomEvent(FRAME_STATE_EVENT, {detail: {state}})
}

// An element's box in the page's pixels, or null for one that has none.
function boxOf(element) {
  if (!element || typeof element.getBoundingClientRect !== "function") return null
  const {x, y, width, height} = element.getBoundingClientRect()
  return [x, y, width, height].every(Number.isFinite) ? {x, y, width, height} : null
}

Object.assign(Canvas, WindowGestures)

export default Canvas
