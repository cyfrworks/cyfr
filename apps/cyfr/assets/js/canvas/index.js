// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {parseSlots, postureFor, slotGeometry, stylesheet} from "./geometry.js"
import {DISCONNECTED, FRAME_STATE_EVENT, RECONNECTED, frameSignal} from "./signals.js"

/**
 * Canvas hook — the client's half of `PrismWeb.CanvasLive`.
 *
 * It reports the posture (`posture`, `hand` under 768 CSS pixels wide and
 * `desk` otherwise) to the canvas on mount, whenever it changes and when
 * the socket comes back; lays each slot out from the slot list the server
 * rendered (`data-slots`) into a stylesheet it owns, inside an element the
 * server never patches; and relays the shell's `frame_state` signals to
 * each frame's bridge as a `cyfr:frame-state` event on the frame's element.
 *
 * The last slot list read is kept for as long as the tab is open, so while
 * the socket is down the last layout stays drawn and follows the window,
 * marked disconnected, and every frame's bridge is told the socket is down
 * so no frame acts until it is back.
 */
const Canvas = {
  mounted() {
    this._slots = []
    this._posture = null
    this._connected = true
    this._style = null

    this._onResize = () => this._layout()
    globalThis.window?.addEventListener("resize", this._onResize)

    this.handleEvent("frame_state", (payload) => this._relay(payload))

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
  },

  // The last slot list that parses is the one drawn.
  _read() {
    const slots = parseSlots(this.el.dataset.slots)
    if (slots !== null) this._slots = slots
  },

  _layout() {
    const posture = postureFor(globalThis.window?.innerWidth)

    if (this._connected && posture !== this._posture) {
      this._posture = posture
      this.pushEventTo(this.el, "posture", {posture})
    }

    const width = this.el.getBoundingClientRect().width
    const style = this._stylesheet()
    if (style) style.textContent = stylesheet(this.el.id, slotGeometry(this._slots, width, posture))
  },

  // The stylesheet lives in the canvas's `-geometry` element, which the
  // server renders empty with `phx-update="ignore"`, so no patch touches it.
  _stylesheet() {
    if (this._style && this._style.isConnected) return this._style
    const host = this.el.querySelector(`#${this.el.id}-geometry`)
    if (!host) return null
    this._style = this.el.ownerDocument.createElement("style")
    host.appendChild(this._style)
    return this._style
  },

  _mark() {
    const marker = this.el.querySelector(`#${this.el.id}-status [data-canvas-connection]`)
    if (!marker) return
    marker.dataset.canvasConnection = this._connected ? "connected" : "disconnected"
    marker.hidden = this._connected
  },

  _frames() {
    return Array.from(this.el.querySelectorAll("iframe[data-frame-id]"))
  },

  _relay(payload) {
    const signal = frameSignal(payload)
    if (!signal) return
    const frame = this._frames().find((el) => el.dataset.frameId === signal.frame)
    if (frame) frame.dispatchEvent(stateEvent(signal.state))
  },

  _broadcast(state) {
    for (const frame of this._frames()) frame.dispatchEvent(stateEvent(state))
  }
}

function stateEvent(state) {
  return new CustomEvent(FRAME_STATE_EVENT, {detail: {state}})
}

export default Canvas
