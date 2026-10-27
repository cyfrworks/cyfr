// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {
  CREDENTIAL,
  HANDSHAKE,
  VERSION,
  credentialClosed,
  decodeCanvasHandshake,
  decodeShellMessage,
  toFrameMessage
} from "../sdk/wire.js"
import {
  CREDENTIAL_CLOSED_EVENT,
  FRAME_BEARER_EVENT,
  FRAME_STATE_EVENT,
  SHELL_STATES,
  TO_CANVAS_EVENT,
  acting,
  nextStanding
} from "../canvas/signals.js"

// What a canvas's frame may send the shell, by its open's mode: a
// validation frame only whether it came up.
const FROM_CANVAS = Object.freeze({
  live: Object.freeze(["ready", "failed", "open", "press"]),
  validation: Object.freeze(["ready", "failed"])
})

// The verbs of a canvas that act for the person, forwarded only within
// moments of the person's own input, on the shown canvas.
const PERSON_VERBS = Object.freeze(["open", "press"])

// What the shell tells a canvas after its open, the latest of each held
// and posted again after its handshake, in this order.
const TOLD = Object.freeze(["posture", "covered", "installed", "state"])

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
 * counted in `data-dropped`, and what is not dropped reaches the view as
 * `frame_verb`.
 *
 * A canvas's frame (`data-frame-kind="canvas"`, a canvas or a validation
 * frame) is answered a canvas block beside its credential
 * (`decodeCanvasHandshake`); a reply the wire refuses hands the frame
 * nothing. Over the port it is posted its open as the `canvas` message,
 * then its credential as every frame is, then the latest `posture`,
 * `covered`, `installed` and `state` the shell told it, and each one
 * after as it comes: the canvas hook's (`cyfr:to-canvas`), and each change
 * of its shell state. A value the wire refuses is never posted. From a
 * canvas only `ready`, `failed`, `open` and `press` reach the view, and
 * from a validation frame only `ready` and `failed`. A canvas's `open` or
 * `press` is forwarded only within moments of the person's own input,
 * never from a script on its own: while the shell document holds transient
 * user activation (which only the person's input gives it, never a
 * script), the canvas's frame is its active element, and the frame is
 * shown, live and not inert. Neither condition names the input as the
 * canvas's: a click elsewhere in the shell, or in a sibling frame,
 * followed by the canvas focusing itself within the activation window
 * passes. Several inside one activation are each forwarded.
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
 * `cyfr:credential` message. One that arrives before the handshake or
 * after a later load goes nowhere.
 *
 * When the credential prompt a frame's `credential` verb asked for closes,
 * the canvas signals `cyfr:credential-closed` on the frame's element with
 * whether an entry was saved, and the bridge tells the frame that over the
 * port and nothing more.
 */
const IframeBridge = {
  mounted() {
    this._frameId = this.el.dataset.frameId
    this._canvas = this.el.dataset.frameKind === "canvas"
    // A canvas's open mode, once its handshake is handed over.
    this._mode = null
    this._loads = 0
    this._port = null
    this._told = new Map()
    this.dropped = 0

    this._standing = {state: "live", connected: true}
    this._apply(this.el.dataset.frameState === "frozen" ? "frozen" : "live")

    this._onLoad = () => this._handshake()
    this.el.addEventListener("load", this._onLoad)

    this._onState = (event) => this._apply(event.detail && event.detail.state)
    this.el.addEventListener(FRAME_STATE_EVENT, this._onState)

    this._onCredentialClosed = (event) => this._credentialClosed(event.detail && event.detail.saved)
    this.el.addEventListener(CREDENTIAL_CLOSED_EVENT, this._onCredentialClosed)

    this._onToCanvas = (event) => event.detail && this._tell(event.detail.verb, event.detail.args)
    this.el.addEventListener(TO_CANVAS_EVENT, this._onToCanvas)

    this._onBearer = (event) => this._replace(event.detail && event.detail.credential)
    this.el.addEventListener(FRAME_BEARER_EVENT, this._onBearer)
  },

  _replace(credential) {
    if (!this._port || typeof credential !== "string" || credential === "") return
    this._sendCredential(credential)
  },

  _credentialClosed(saved) {
    if (this._port) this._port.postMessage(credentialClosed(this._frameId, saved === true))
  },

  _apply(signal) {
    this._standing = nextStanding(this._standing, signal)
    this.el.inert = !acting(this._standing)
    if (SHELL_STATES.includes(signal)) this._tell("state", {state: signal})
  },

  // Hold what the shell tells a canvas as the latest of its kind, and post
  // it once the canvas has its open; one the wire refuses is neither.
  _tell(verb, args) {
    if (!this._canvas || !TOLD.includes(verb)) return
    let message
    try {
      message = toFrameMessage(verb, this._frameId, args)
    } catch (_error) {
      return
    }
    this._told.set(verb, message)
    if (this._port && this._mode !== null) this._port.postMessage(message)
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
      if (this._canvas) this._handOverCanvas(frame, reply)
      else if (typeof reply.credential === "string") this._handOver(frame, reply.credential)
    })
  },

  _handOver(frame, credential) {
    this._openPort(frame)
    this._sendCredential(credential)
  },

  // A canvas's frame is handed its port, its open, its credential and the
  // latest the shell told it, in that order, so the page knows it is a
  // canvas before it holds a credential to send anything with.
  _handOverCanvas(frame, reply) {
    const decoded = decodeCanvasHandshake(reply, this._frameId)
    if (!decoded.ok) return

    this._openPort(frame)
    this._mode = decoded.canvas.mode
    this._port.postMessage(toFrameMessage("canvas", this._frameId, decoded.canvas))
    this._sendCredential(decoded.credential)
    for (const verb of TOLD) {
      if (this._told.has(verb)) this._port.postMessage(this._told.get(verb))
    }
  },

  _openPort(frame) {
    const channel = new MessageChannel()
    this._port = channel.port1
    this._port.onmessage = (event) => this._receive(event.data)

    // The frame is sandboxed without allow-same-origin, so its origin is
    // opaque and no targetOrigin but "*" matches it. What this message
    // carries is the port and the frame id; the credential goes over the
    // port, which only the document that received it holds.
    frame.postMessage({v: VERSION, type: HANDSHAKE, frame: this._frameId}, "*", [channel.port2])
  },

  _sendCredential(credential) {
    this._port.postMessage({v: VERSION, type: CREDENTIAL, frame: this._frameId, credential})
  },

  _receive(data) {
    const decoded = decodeShellMessage(data)

    if (
      !decoded.ok ||
      decoded.message.frame !== this._frameId ||
      !acting(this._standing) ||
      !this._forwards(decoded.message.verb)
    ) {
      this._drop()
      return
    }

    this.pushEvent("frame_verb", {frame: this._frameId, message: decoded.message})
  },

  // Whether a verb this frame posted reaches the view: every verb of a
  // tincture's frame; of a canvas's, those its mode sends, and an `open` or
  // a `press` only within moments of the person's input, on the shown canvas.
  _forwards(verb) {
    if (!this._canvas) return true
    if (!(FROM_CANVAS[this._mode] || []).includes(verb)) return false
    return !PERSON_VERBS.includes(verb) || (this._shown() && this._personActed())
  },

  // The frame is drawn for the person: its wrapper shown, and neither it
  // nor anything around it inert.
  _shown() {
    const el = this.el
    if (el.inert === true || typeof el.closest !== "function") return false
    const wrapper = el.closest("[data-canvas-shown]")
    return wrapper !== null && wrapper.dataset.canvasShown === "true" && el.closest("[inert]") === null
  },

  // The person gave input within the activation window: the shell document
  // holds transient user activation, which no script can give it, and the
  // frame is its active element. Reading the activation consumes nothing.
  // Where the browser has no activation API, nothing counts.
  _personActed() {
    if (typeof window === "undefined") return false
    const {navigator, document: doc} = window
    if (!navigator || !navigator.userActivation || navigator.userActivation.isActive !== true) return false
    return Boolean(doc) && doc.activeElement === this.el
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
    this._mode = null
  },

  destroyed() {
    this.el.removeEventListener("load", this._onLoad)
    this.el.removeEventListener(FRAME_STATE_EVENT, this._onState)
    this.el.removeEventListener(CREDENTIAL_CLOSED_EVENT, this._onCredentialClosed)
    this.el.removeEventListener(TO_CANVAS_EVENT, this._onToCanvas)
    this.el.removeEventListener(FRAME_BEARER_EVENT, this._onBearer)
    this._closePort()
  }
}

export default IframeBridge
