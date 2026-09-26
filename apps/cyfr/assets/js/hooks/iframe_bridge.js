// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {CREDENTIAL, HANDSHAKE, VERSION, decodeShellMessage} from "../sdk/wire.js"

/**
 * IframeBridge hook — the shell's end of a tincture frame's MessagePort.
 *
 * On the frame's first load the shell asks the view for the frame's
 * credential, posts the frame one handshake carrying a fresh MessagePort and
 * the frame id, and sends the credential over that port only. From then on
 * the port is the frame's only way to the shell: this hook listens to no
 * window message at all, so a message from any other window, the frame's
 * own window included, reaches nothing. What arrives on the port must be a
 * shell verb for this frame (`Prima.TinctureWire`); anything else — another
 * frame's id, an unknown verb, a verb carrying data — is dropped and
 * counted in `data-dropped`.
 *
 * A later load (a reload, or the frame navigating itself) gets no second
 * handshake: the port is closed and the frame is spent until the person
 * opens the tincture again.
 */
const IframeBridge = {
  mounted() {
    this._frameId = this.el.dataset.frameId
    this._loads = 0
    this._port = null
    this.dropped = 0

    this._onLoad = () => this._handshake()
    this.el.addEventListener("load", this._onLoad)
  },

  _handshake() {
    this._loads += 1

    if (this._loads > 1) {
      this._closePort()
      return
    }

    this.pushEvent("frame_handshake", {frame: this._frameId}, (reply) => {
      const frame = this.el.contentWindow
      if (!reply || typeof reply.credential !== "string" || !frame || this._loads !== 1) return

      const channel = new MessageChannel()
      this._port = channel.port1
      this._port.onmessage = (event) => this._receive(event.data)

      // The frame is sandboxed without allow-same-origin, so its origin is
      // opaque and no targetOrigin but "*" matches it. What this message
      // carries is the port and the frame id; the credential goes over the
      // port, which only the document that received it holds.
      frame.postMessage({v: VERSION, type: HANDSHAKE, frame: this._frameId}, "*", [channel.port2])
      this._port.postMessage({
        v: VERSION,
        type: CREDENTIAL,
        frame: this._frameId,
        credential: reply.credential
      })
    })
  },

  _receive(data) {
    const decoded = decodeShellMessage(data)

    if (!decoded.ok || decoded.message.frame !== this._frameId) {
      this.dropped += 1
      this.el.dataset.dropped = String(this.dropped)
      return
    }

    this.pushEvent("frame_verb", {frame: this._frameId, message: decoded.message})
  },

  _closePort() {
    if (this._port) {
      this._port.onmessage = null
      this._port.close()
      this._port = null
    }
  },

  destroyed() {
    this.el.removeEventListener("load", this._onLoad)
    this._closePort()
  }
}

export default IframeBridge
