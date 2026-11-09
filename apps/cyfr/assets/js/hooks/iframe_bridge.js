// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {
  ANSWER_VERBS,
  CREDENTIAL,
  HANDSHAKE,
  PERSON_VERBS,
  TOLD_VERBS,
  VERSION,
  credentialClosed,
  decodeCanvasHandshake,
  decodeFrameHandshake,
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
  live: Object.freeze(["ready", "failed", ...PERSON_VERBS]),
  validation: Object.freeze(["ready", "failed"])
})

// What the shell tells a canvas after its open, the latest of each held
// and posted again after its handshake, in this order.
const TOLD = TOLD_VERBS

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
 * `frame_verb`. The count is the hook's: a patch of the frame's element
 * takes the view's attributes, which carry none, so it is written again
 * after every patch.
 *
 * A canvas's frame (`data-frame-kind="canvas"`, a canvas or a validation
 * frame) is answered a canvas block beside its credential
 * (`decodeCanvasHandshake`); a reply the wire refuses hands the frame
 * nothing. Over the port it is posted its open as the `canvas` message,
 * then its credential as every frame is, then the latest `posture`,
 * `covered`, `installed` and `state` the shell told it, and each one
 * after as it comes: the canvas hook's (`cyfr:to-canvas`), and each change
 * of its shell state. The shell's answers to its press of a control and
 * its write of its preferences (`pressed`, `prefs`) are posted once as
 * they come, never held for a later handshake. A value the wire refuses
 * is never posted. An app's frame opened on a subject is posted it
 * (`subject`) before its credential.
 *
 * From a canvas only `ready`, `failed` and the person's verbs (`open`,
 * `press`, `grant`, `prefs`, `ask`, `settings`) reach the view, and from
 * a validation frame only `ready` and `failed`. A canvas's `ready` and
 * `failed` are forwarded whatever its shown state, needing no input.
 *
 * A person's verb is forwarded once per input of the person's in the
 * frame, never from a script on its own. The bridge sees no input made
 * inside a frame; it sees the frame take focus, and every input the
 * shell's own page hears. So an input in the frame is the frame taking
 * focus while the shell document holds transient user activation (which
 * only the person's input gives it) and either the pointer is over the
 * frame or the person moved focus into it with the Tab key; that arms
 * the frame for one verb. The verb is forwarded only while the frame is
 * armed, is the document's active element, and is shown, live and not
 * inert, and it carries the input's ordinal (`input`), by which the view
 * honours one verb per input too. Forwarding one disarms the frame and
 * takes focus off it, so the person's next press in it is a new input.
 * Any input the shell's own page hears (a pointer press, a key) disarms
 * every frame, as does focus leaving it: a click in the chrome followed by
 * the frame focusing itself arms nothing, since the pointer is not over
 * it. A person's verb dropped for want of input is counted, and a press
 * of a control or a write of the preferences is answered `cancelled`
 * over the port. What stays open: a frame that focuses itself again while
 * the pointer rests on it, within the activation the person's last input
 * gave, is armed again; and a person working by keyboard moves focus back
 * into the frame with Tab after each verb.
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
 * every verb it posts is dropped and counted, except a frozen canvas's
 * `ready` and `failed`: those report how its page loaded and runs, not an
 * act, and reach the view whether the canvas is shown or hidden while the
 * socket is up. Its port stays open, so the frame acts again once it is
 * live and the socket is back.
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

    // The person's input: the ordinal of the last one that armed the
    // frame, whether it is unspent, where the pointer is, and a Tab whose
    // focus has not landed yet.
    this._input = 0
    this._armed = false
    this._inside = false
    this._tabbed = false
    // The preferences the frame holds as the shell last told it, for a
    // write the bridge answers itself.
    this._prefs = null
    if (this._canvas) this._listen()
  },

  _listen() {
    const win = typeof window === "undefined" ? null : window
    this._onPointerEnter = () => (this._inside = true)
    this._onPointerLeave = () => (this._inside = false)
    this._onFocus = () => this._focused()
    this._onBlur = () => (this._armed = false)
    this.el.addEventListener("pointerenter", this._onPointerEnter)
    this.el.addEventListener("pointerleave", this._onPointerLeave)
    this.el.addEventListener("focus", this._onFocus)
    this.el.addEventListener("blur", this._onBlur)

    if (!win || typeof win.addEventListener !== "function") return
    this._onChromePointer = () => this._chromeInput(false)
    this._onChromeKey = (event) => this._chromeInput(event && event.key === "Tab")
    this._onFocusIn = (event) => this._focusMoved(event && event.target)
    this._onWindowBlur = () => this._focusMoved(win.document && win.document.activeElement)
    win.addEventListener("pointerdown", this._onChromePointer, true)
    win.addEventListener("keydown", this._onChromeKey, true)
    win.addEventListener("focusin", this._onFocusIn, true)
    win.addEventListener("blur", this._onWindowBlur)
  },

  // An input the shell's own page heard: it is not the frame's.
  _chromeInput(tab) {
    this._armed = false
    this._tabbed = tab
  },

  // Focus moved to `target` on the shell's page: into this frame, or
  // elsewhere, where a Tab landed and is spent.
  _focusMoved(target) {
    if (target === this.el) this._focused()
    else this._tabbed = false
  },

  // The frame took focus: an input of the person's in it when the
  // document holds activation and the pointer is over the frame or a Tab
  // moved focus into it.
  _focused() {
    const tabbed = this._tabbed
    this._tabbed = false
    if (this._armed || !activated() || !(this._inside || tabbed)) return
    this._input += 1
    this._armed = true
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
  // it once the canvas has its open; post an answer once, holding nothing
  // but the preferences it carries. One the wire refuses is neither.
  _tell(verb, args) {
    if (!this._canvas || !(TOLD.includes(verb) || ANSWER_VERBS.includes(verb))) return
    let message
    try {
      message = toFrameMessage(verb, this._frameId, args)
    } catch (_error) {
      return
    }
    if (verb === "prefs") this._prefs = {document: args.document, revision: args.revision}
    if (TOLD.includes(verb)) this._told.set(verb, message)
    if (this._port && this._mode !== null) this._port.postMessage(message)
  },

  // A person's verb the bridge dropped: a press of a control and a write
  // of the preferences are told they did not run.
  _cancelled(message) {
    if (!this._canvas || !this._port || this._mode === null) return
    const {verb, args} = message
    if (verb === "press" && "control" in args) {
      this._tell("pressed", {control: args.control, outcome: "cancelled"})
    } else if (verb === "prefs" && this._prefs) {
      this._tell("prefs", {outcome: "cancelled", ...this._prefs})
    }
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
      else this._handOver(frame, reply)
    })
  },

  // An app's frame is handed its port, the subject it was opened on, if
  // any, and its credential.
  _handOver(frame, reply) {
    const decoded = decodeFrameHandshake(reply)
    if (!decoded.ok) return
    this._openPort(frame)
    if (decoded.subject) this._port.postMessage(toFrameMessage("subject", this._frameId, decoded.subject))
    this._sendCredential(decoded.credential)
  },

  // A canvas's frame is handed its port, its open, its credential and the
  // latest the shell told it, in that order, so the page knows it is a
  // canvas before it holds a credential to send anything with.
  _handOverCanvas(frame, reply) {
    const decoded = decodeCanvasHandshake(reply, this._frameId)
    if (!decoded.ok) return

    this._openPort(frame)
    this._mode = decoded.canvas.mode
    this._prefs = decoded.canvas.prefs
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

    if (!decoded.ok || decoded.message.frame !== this._frameId) {
      this._drop()
      return
    }

    const {message} = decoded
    const person = this._canvas && PERSON_VERBS.includes(message.verb)

    if (!this._forwards(message.verb)) {
      this._drop()
      if (person) this._cancelled(message)
      return
    }

    if (!person) {
      this.pushEvent("frame_verb", {frame: this._frameId, message})
      return
    }

    // One input, one verb: the input is spent, and focus leaves the frame
    // so the person's next press in it is an input of its own.
    this._armed = false
    this.pushEvent("frame_verb", {frame: this._frameId, message, input: this._input})
    if (typeof this.el.blur === "function") this.el.blur()
  },

  // Whether a verb this frame posted reaches the view, which it can only
  // while the socket is up: every verb of a live tincture's frame; of a
  // canvas's, those its mode sends, `ready` and `failed` whether it is
  // shown or hidden, and a person's verb only for an input of the
  // person's in it, on the shown, live canvas.
  _forwards(verb) {
    if (!this._standing.connected) return false
    if (!this._canvas) return acting(this._standing)
    if (!(FROM_CANVAS[this._mode] || []).includes(verb)) return false
    if (!PERSON_VERBS.includes(verb)) return true
    return acting(this._standing) && this._shown() && this._personActed()
  },

  // The frame is drawn for the person: its wrapper shown, and neither it
  // nor anything around it inert.
  _shown() {
    const el = this.el
    if (el.inert === true || typeof el.closest !== "function") return false
    const wrapper = el.closest("[data-canvas-shown]")
    return wrapper !== null && wrapper.dataset.canvasShown === "true" && el.closest("[inert]") === null
  },

  // An input of the person's in the frame is unspent: the frame is armed,
  // the shell document still holds the activation it gave, and the frame
  // is its active element. Reading the activation consumes nothing.
  _personActed() {
    if (!this._armed || !activated()) return false
    const doc = typeof window === "undefined" ? null : window.document
    return Boolean(doc) && doc.activeElement === this.el
  },

  _drop() {
    this.dropped += 1
    this.el.dataset.dropped = String(this.dropped)
  },

  updated() {
    if (this.dropped > 0) this.el.dataset.dropped = String(this.dropped)
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
    const win = typeof window === "undefined" ? null : window
    if (this._canvas && win && typeof win.removeEventListener === "function") {
      win.removeEventListener("pointerdown", this._onChromePointer, true)
      win.removeEventListener("keydown", this._onChromeKey, true)
      win.removeEventListener("focusin", this._onFocusIn, true)
      win.removeEventListener("blur", this._onWindowBlur)
    }
    this.el.removeEventListener("pointerenter", this._onPointerEnter)
    this.el.removeEventListener("pointerleave", this._onPointerLeave)
    this.el.removeEventListener("focus", this._onFocus)
    this.el.removeEventListener("blur", this._onBlur)
    this.el.removeEventListener("load", this._onLoad)
    this.el.removeEventListener(FRAME_STATE_EVENT, this._onState)
    this.el.removeEventListener(CREDENTIAL_CLOSED_EVENT, this._onCredentialClosed)
    this.el.removeEventListener(TO_CANVAS_EVENT, this._onToCanvas)
    this.el.removeEventListener(FRAME_BEARER_EVENT, this._onBearer)
    this._closePort()
  }
}

// Whether the shell document holds transient user activation, which only
// the person's input gives it. Where the browser has no activation API,
// nothing counts.
function activated() {
  if (typeof window === "undefined") return false
  const {navigator} = window
  return Boolean(navigator && navigator.userActivation && navigator.userActivation.isActive === true)
}

export default IframeBridge
