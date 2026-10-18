// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {CREDENTIAL, HANDSHAKE, VERSION, credentialClosed, decodeShellMessage} from "../sdk/wire.js"
import {
  CANVAS_MESSAGE_EVENT,
  CANVAS_VERBS,
  CREDENTIAL_CLOSED_EVENT,
  FRAME_BEARER_EVENT,
  FRAME_STATE_EVENT,
  SHELL_STATES,
  acting,
  nextStanding
} from "../canvas/signals.js"
import {TO_PRISM_VERBS, decode as decodeCanvas, encode as encodeCanvas, isPlainObject} from "../toolkit/wire.js"

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
 * A canvas's frame (`data-frame-wire="canvas"`, a canvas or a validation
 * frame) speaks `Prima.CanvasWire` instead, through the toolkit's one
 * definition of it (`../toolkit/wire.js`). Its handshake is answered with
 * the frame's `boot`, which the bridge posts over the port, the bearer
 * inside it, and never as `cyfr:credential`. What the canvas posts must be
 * a verb of the toolkit's direction for this frame, and reaches the view as
 * `canvas_verb`. The `posture`, `covered` and `installed` the canvas hook
 * relays (`cyfr:canvas-message`), and each change of its shell state as
 * `state`, are posted over the port once it has booted, the latest of each
 * first; a value the wire refuses is never posted.
 *
 * A later load (a reload, or the frame navigating itself) gets no second
 * handshake: the port is closed and the frame is spent until the person
 * opens the tincture again. A canvas's frame that loads again is reported
 * to the view as `frame_gone`.
 *
 * A frame acts only while it is live and the view's socket is up. The
 * shell renders the frame's state in `data-frame-state` and signals each
 * change through the canvas (`cyfr:frame-state`, `assets/js/canvas/`); a
 * frozen frame, or any frame while the socket is down, is made inert and
 * every verb it posts is dropped and counted. Its port stays open, so the
 * frame acts again once it is live and the socket is back.
 *
 * When the shell rotates a frame's credential, renewing it while the frame
 * runs or resuming it once shown again, the canvas signals
 * `cyfr:frame-bearer` on that frame's element, and the bridge sends the
 * new credential over the port it handed the frame, as the handshake's
 * `cyfr:credential` message, or to a canvas's frame as the canvas wire's
 * `credential` once it has booted. One that arrives before the handshake
 * or after a later load goes nowhere.
 *
 * When the credential prompt a frame's `credential` verb asked for closes,
 * the canvas signals `cyfr:credential-closed` on the frame's element with
 * whether an entry was saved, and the bridge tells the frame that over the
 * port and nothing more.
 */
const IframeBridge = {
  mounted() {
    this._frameId = this.el.dataset.frameId
    this._canvas = this.el.dataset.frameWire === "canvas"
    this._loads = 0
    this._port = null
    this._booted = false
    this._latest = new Map()
    this.dropped = 0

    this._standing = {state: "live", connected: true}
    this._apply(this.el.dataset.frameState === "frozen" ? "frozen" : "live")

    this._onLoad = () => this._handshake()
    this.el.addEventListener("load", this._onLoad)

    this._onState = (event) => this._apply(event.detail && event.detail.state)
    this.el.addEventListener(FRAME_STATE_EVENT, this._onState)

    this._onCredentialClosed = (event) => this._credentialClosed(event.detail && event.detail.saved)
    this.el.addEventListener(CREDENTIAL_CLOSED_EVENT, this._onCredentialClosed)

    this._onCanvasMessage = (event) => this._canvasMessage(event.detail)
    this.el.addEventListener(CANVAS_MESSAGE_EVENT, this._onCanvasMessage)

    this._onBearer = (event) => this._replace(event.detail && event.detail.credential)
    this.el.addEventListener(FRAME_BEARER_EVENT, this._onBearer)
  },

  _replace(credential) {
    if (!this._port || typeof credential !== "string" || credential === "") return
    if (this._canvas) return this._post("credential", {credential})
    this._port.postMessage({v: VERSION, type: CREDENTIAL, frame: this._frameId, credential})
  },

  _credentialClosed(saved) {
    if (this._port && !this._canvas) this._port.postMessage(credentialClosed(this._frameId, saved === true))
  },

  _apply(signal) {
    this._standing = nextStanding(this._standing, signal)
    this.el.inert = !acting(this._standing)
    if (this._canvas && SHELL_STATES.includes(signal)) this._post("state", {state: signal})
  },

  _handshake() {
    this._loads += 1

    if (this._loads > 1) {
      this._closePort()
      if (this._canvas) this.pushEvent("frame_gone", {frame: this._frameId})
      return
    }

    this.pushEvent("frame_handshake", {frame: this._frameId}, (reply) => {
      const frame = this.el.contentWindow
      if (!reply || !frame || this._loads !== 1) return
      if (this._canvas) this._bootCanvas(frame, reply)
      else this._handOver(frame, reply)
    })
  },

  _handOver(frame, reply) {
    if (typeof reply.credential !== "string") return

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
  },

  // A canvas's frame is handed its boot, bearer and all, over the port
  // alone; a boot the wire refuses hands nothing.
  _bootCanvas(frame, reply) {
    if (!isPlainObject(reply.boot)) return

    let boot
    try {
      boot = encodeCanvas("boot", this._frameId, reply.boot)
    } catch (_error) {
      return
    }

    const channel = new MessageChannel()
    this._port = channel.port1
    this._port.onmessage = (event) => this._receiveCanvas(event.data)

    frame.postMessage({v: VERSION, type: HANDSHAKE, frame: this._frameId}, "*", [channel.port2])
    this._port.postMessage(boot)
    this._booted = true

    for (const verb of CANVAS_VERBS) {
      if (this._latest.has(verb)) this._post(verb, this._latest.get(verb))
    }
    if (this._standing.state === "frozen") this._post("state", {state: "frozen"})
  },

  _canvasMessage(detail) {
    if (!this._canvas || !isPlainObject(detail) || !CANVAS_VERBS.includes(detail.verb)) return
    this._latest.set(detail.verb, detail.args)
    this._post(detail.verb, detail.args)
  },

  // Post a canvas wire message, once the frame has booted; one the wire
  // refuses is not posted.
  _post(verb, args) {
    if (!this._booted || !this._port) return
    let message
    try {
      message = encodeCanvas(verb, this._frameId, args)
    } catch (_error) {
      return
    }
    this._port.postMessage(message)
  },

  _receive(data) {
    const decoded = decodeShellMessage(data)

    if (!decoded.ok || decoded.message.frame !== this._frameId || !acting(this._standing)) {
      this._drop()
      return
    }

    this.pushEvent("frame_verb", {frame: this._frameId, message: decoded.message})
  },

  _receiveCanvas(data) {
    const decoded = decodeCanvas(data)

    if (
      !decoded.ok ||
      decoded.message.frame !== this._frameId ||
      !TO_PRISM_VERBS.includes(decoded.message.verb) ||
      !acting(this._standing)
    ) {
      this._drop()
      return
    }

    const {verb, frame, args} = decoded.message
    this.pushEvent("canvas_verb", {frame, message: encodeCanvas(verb, frame, args)})
  },

  _drop() {
    this.dropped += 1
    this.el.dataset.dropped = String(this.dropped)
  },

  _closePort() {
    if (this._port) {
      this._port.onmessage = null
      this._port.close()
      this._port = null
    }
    this._booted = false
  },

  destroyed() {
    this.el.removeEventListener("load", this._onLoad)
    this.el.removeEventListener(FRAME_STATE_EVENT, this._onState)
    this.el.removeEventListener(CREDENTIAL_CLOSED_EVENT, this._onCredentialClosed)
    this.el.removeEventListener(CANVAS_MESSAGE_EVENT, this._onCanvasMessage)
    this.el.removeEventListener(FRAME_BEARER_EVENT, this._onBearer)
    this._closePort()
  }
}

export default IframeBridge
