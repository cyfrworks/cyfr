// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {columnGeometry, coveredRects, parseColumns, postureFor, stylesheet, swipeDirection} from "./geometry.js"
import {
  CANVAS_MESSAGE_EVENT,
  CREDENTIAL_CLOSED_EVENT,
  DISCONNECTED,
  FRAME_STATE_EVENT,
  RECONNECTED,
  credentialSignal,
  frameSignal,
  installedSignal,
  safeModeChord,
  switchChord
} from "./signals.js"

const EDGE_STRIP = "#canvas-edge-strip"
const COVERING = ["column", "float", "full"]

/**
 * Canvas hook — the client's half of `PrismWeb.CanvasLive`.
 *
 * It reports the posture (`posture`, `hand` under 768 CSS pixels wide and
 * `desk` otherwise) to the canvas on mount, whenever it changes and when
 * the socket comes back; lays each shown column app out from the list the
 * server rendered (`data-columns`) into a stylesheet it owns, inside an
 * element the server never patches; relays the shell's `frame_state`
 * signals to each frame's bridge as a `cyfr:frame-state` event on the
 * frame's element, its `frame_credential` signals (a credential prompt a
 * frame asked for closed) as `cyfr:credential-closed`, and its
 * `canvas_installed` pushes to the canvas frame they name.
 *
 * Each canvas frame (`data-frame-wire="canvas"`) is told, through its
 * bridge (`cyfr:canvas-message`), the posture and what the shown apps and
 * floating frames cover of it, in its own pixels, whenever either changes;
 * its bridge holds the latest until the frame's handshake and posts it
 * then.
 *
 * The safe mode chord, Ctrl+Alt+S, and the switch chords,
 * Ctrl+Alt+ArrowLeft and Ctrl+Alt+ArrowRight, are heard here, on the
 * shell's own page, and sent to the shell as `safe_mode` and
 * `switch_canvas` (`previous` or `next`); so is a horizontal swipe on the
 * edge strip, leftward `next` and rightward `previous`. A frame's keys and
 * pointer stay in the frame's document and never reach it.
 *
 * The last columns read are kept for as long as the tab is open, so while
 * the socket is down the last layout stays drawn and follows the window,
 * marked disconnected, and every frame's bridge is told the socket is down
 * so no frame acts until it is back.
 *
 * The hook sits on an empty element of its own inside the canvas layer,
 * which carries `data-posture` and `data-columns`. LiveView locks the
 * element an event is pushed from until its reply, and a locked element
 * around the frames would bring back a frame the layer discarded meanwhile;
 * so every push goes from the hook's own element, and the layer, read as
 * that element's parent, is where the pointer is heard, its size measured,
 * its stylesheet scoped and its frames, hosts and edge strip found.
 */
const Canvas = {
  mounted() {
    this._layer = this.el.parentElement
    this._columns = []
    this._posture = null
    this._connected = true
    this._style = null
    this._told = new Map()
    this._swipe = null

    this._onResize = () => this._layout()
    globalThis.window?.addEventListener("resize", this._onResize)

    this._onKeydown = (event) => {
      if (safeModeChord(event)) {
        event.preventDefault()
        if (this._connected) this.pushEvent("safe_mode", {})
        return
      }
      const direction = switchChord(event)
      if (direction === null) return
      event.preventDefault()
      if (this._connected) this.pushEvent("switch_canvas", {direction})
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
    this.handleEvent("canvas_installed", (payload) => this._installed(payload))

    this._read()
    this._layout()
  },

  updated() {
    this._read()
    this._layout()
  },

  disconnected() {
    this._connected = false
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
    globalThis.window?.removeEventListener("resize", this._onResize)
    globalThis.window?.removeEventListener("keydown", this._onKeydown)
    this._layer.removeEventListener?.("pointerdown", this._onPointerDown)
    this._layer.removeEventListener?.("pointerup", this._onPointerUp)
    this._layer.removeEventListener?.("pointercancel", this._onPointerCancel)
  },

  // The last column list that parses is the one drawn.
  _read() {
    const columns = parseColumns(this.el.dataset.columns)
    if (columns !== null) this._columns = columns
  },

  _layout() {
    const posture = postureFor(globalThis.window?.innerWidth)

    if (this._connected && posture !== this._posture) {
      this._posture = posture
      this.pushEventTo(this.el, "posture", {posture})
    }

    const {width, height} = this._layer.getBoundingClientRect()
    const style = this._stylesheet()
    if (style) style.textContent = stylesheet(this._layer.id, columnGeometry(this._columns, width, height, posture))

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
    frame.dispatchEvent(new CustomEvent(CANVAS_MESSAGE_EVENT, {detail: {verb, args}}))
  },

  // The stylesheet lives in the layer's `-geometry` element, which the
  // server renders empty with `phx-update="ignore"`, so no patch touches it.
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
    return this._frames().filter((frame) => frame.dataset.frameWire === "canvas")
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

  _installed(payload) {
    const signal = installedSignal(payload)
    if (!signal) return
    const frame = this._canvasFrames().find((el) => el.dataset.frameId === signal.frame)
    if (frame) {
      frame.dispatchEvent(
        new CustomEvent(CANVAS_MESSAGE_EVENT, {detail: {verb: "installed", args: {tinctures: signal.tinctures}}})
      )
    }
  },

  _swipeStart(event) {
    const strip = event.target && typeof event.target.closest === "function" ? event.target.closest(EDGE_STRIP) : null
    if (!strip) return
    this._swipe = {pointer: event.pointerId, x: event.clientX, y: event.clientY}
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

export default Canvas
