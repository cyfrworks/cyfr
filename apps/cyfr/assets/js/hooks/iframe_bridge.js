// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {
  ANSWER_OF,
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

// The person's verbs an app's frame sends, held to the person's input as a
// canvas's are; an app's other verbs reach the view while it acts.
const FROM_APP_PERSON = Object.freeze(["request"])

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
 * of its shell state. The shell's answers to its press of a control, its
 * write of its preferences and its request (`pressed`, `prefs`,
 * `requested`, `decided`) are posted once as they come, never held for a
 * later handshake. An app's frame is posted the answers to its request
 * (`requested`, `decided`) once its port is open, and nothing else of a
 * canvas's messages. A value the wire refuses is never posted. An app's
 * frame opened on a subject is posted it (`subject`) before its
 * credential, and a new one as the app is opened again on it
 * (`cyfr:to-canvas` with `subject`).
 *
 * From a canvas only `ready`, `failed` and the person's verbs (`open`,
 * `press`, `grant`, `prefs`, `ask`, `settings`, `request`) reach the view,
 * and from a validation frame only `ready` and `failed`. A canvas's
 * `ready` and `failed` are forwarded whatever its shown state, needing no
 * input. From an app every verb reaches the view while it acts, its
 * `request` held to the person's input as a canvas's person's verb is.
 *
 * A person's verb is forwarded once per input of the person's, never from
 * a script on its own. The bridge sees no input made inside a frame, and in
 * a browser that runs a frame in a process of its own it sees neither the
 * pointer entering it nor a click in it: only the shell document's
 * transient user activation, which an input anywhere on the page gives it
 * for a few seconds (`ACTIVATION_LIFESPAN_MS`), and every input the
 * shell's own page hears (a press, a touch, a key). So an input of the
 * person's carries a verb only while the shell document holds activation
 * that nothing has spent: an input the shell's page heard spends it, as
 * do the frame's opening (activation the page holds as the bridge mounts)
 * and each verb the bridge forwards. A verb is forwarded only while the
 * document holds activation, the frame is its active element and shown,
 * live and not inert, and the last spend is past the activation's
 * lifespan; one sent within that lifespan is dropped at once, never held,
 * and the verb forwarded carries the ordinal of the input it came with
 * (`input`), by which the view honours one verb per input too. A person's
 * verb dropped is counted, and a press of a control, a write of the
 * preferences or a request is answered `cancelled` over the port (as
 * `pressed`, `prefs` or `decided`), under its call number, naming
 * `too_soon` when it came within that lifespan; one whose call number is
 * no higher than the last the frame used is a replay or a forgery of
 * another call's, and is dropped first, unanswered and never forwarded.
 * So a press in the chrome followed by the frame focusing itself passes
 * nothing, two verbs from one input pass one, and a person's press in the
 * frame within a few seconds of a press in the chrome or of the frame's
 * last verb is dropped, `too_soon`, for the person to press again. What
 * stays open: an input in another frame followed by this frame taking
 * focus within that input's activation counts as this frame's.
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

    // The person's input: the ordinal of the last verb forwarded and when
    // the activation last was spent.
    this.lifespan = ACTIVATION_LIFESPAN_MS
    this._input = 0
    // A frame opens on an input of the chrome's (a switch, an open) or with
    // the page: activation the page holds as the bridge mounts was given by
    // no input in this frame, so it starts spent.
    this._spentAt = activated() ? now() : -Infinity
    // The highest call number the frame has numbered a press, a write or a
    // request with: a frame numbers its calls upward, so one not above it
    // was used already, pending or answered.
    this._lastCall = 0
    // The preferences the frame holds as the shell last told it, for a
    // write the bridge answers itself.
    this._prefs = null
    this._listen()
  },

  _listen() {
    const win = typeof window === "undefined" ? null : window
    if (!win || typeof win.addEventListener !== "function") return
    // The activation an input the shell's own page heard gives is not the
    // frame's: it is spent as it is given.
    this._onChromeInput = () => (this._spentAt = now())
    for (const type of CHROME_INPUTS) win.addEventListener(type, this._onChromeInput, true)
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
  // but the preferences it carries, to a canvas once it has its open and
  // to an app once its port is open. One the wire refuses is neither.
  _tell(verb, args) {
    if (!this._canvas && verb === "subject") return this._retell(args)
    const takes = this._canvas ? TOLD.includes(verb) || ANSWER_VERBS.includes(verb) : ANSWER_OF.request.includes(verb)
    if (!takes) return
    let message
    try {
      message = toFrameMessage(verb, this._frameId, args)
    } catch (_error) {
      return
    }
    if (verb === "prefs") this._prefs = {document: args.document, revision: args.revision}
    if (TOLD.includes(verb)) this._told.set(verb, message)
    if (this._port && (this._mode !== null || !this._canvas)) this._port.postMessage(message)
  },

  // An app opened again on another subject is posted it, once its port is
  // open; one the wire refuses is not.
  _retell(subject) {
    if (!this._port) return
    try {
      this._port.postMessage(toFrameMessage("subject", this._frameId, subject))
    } catch (_error) {
      // Not a subject the wire carries.
    }
  },

  // A person's verb the bridge dropped: a press of a control, a write of
  // the preferences and a request are told they did not run, and why when
  // `reason` names it (`too_soon`).
  _cancelled(message, reason = null) {
    const {verb, args} = message
    const why = reason === null ? {} : {reason}
    if (verb === "request") {
      this._tell("decided", {call: args.call, outcome: "cancelled", ...why})
    } else if (verb === "press" && "control" in args) {
      this._tell("pressed", {control: args.control, call: args.call, outcome: "cancelled", ...why})
    } else if (verb === "prefs" && this._prefs) {
      this._tell("prefs", {call: args.call, outcome: "cancelled", ...why, ...this._prefs})
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
    const person = (this._canvas ? PERSON_VERBS : FROM_APP_PERSON).includes(message.verb)

    // A call number used already is a replay or a forgery, and an answer
    // under it, the bridge's or the shell's, would settle the call that
    // number belongs to: it is dropped and answered nothing.
    if (person && "call" in message.args) {
      if (message.args.call <= this._lastCall) {
        this._drop()
        return
      }
      this._lastCall = message.args.call
    }

    if (!this._forwards(message.verb, person)) {
      this._drop()
      if (person) this._cancelled(message)
      return
    }

    if (!person) {
      this.pushEvent("frame_verb", {frame: this._frameId, message})
      return
    }

    // The activation it came on was spent within its lifespan, by an
    // input in the chrome, the frame's opening or an earlier verb, so no
    // input of its own is proven: it is dropped at once.
    if (now() - this._spentAt < this.lifespan) {
      this._drop()
      this._cancelled(message, "too_soon")
      return
    }

    // One input, one verb: forwarding spends the activation that carried it.
    this._input += 1
    this._spentAt = now()
    this.pushEvent("frame_verb", {frame: this._frameId, message, input: this._input})
  },

  // Whether a verb this frame posted reaches the view, which it can only
  // while the socket is up: of a live tincture's frame, every verb but its
  // request; of a canvas's, those its mode sends, `ready` and `failed`
  // whether it is shown or hidden; and a person's verb, `person`, only for
  // an input of the person's in it, on the shown, live frame.
  _forwards(verb, person) {
    if (!this._standing.connected) return false
    if (this._canvas && !(FROM_CANVAS[this._mode] || []).includes(verb)) return false
    if (!person) return this._canvas || acting(this._standing)
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

  // The person gave input: the shell document holds transient user
  // activation, which no script can give it, and the frame is its active
  // element. Whether that activation is the frame's own is `_receive`'s.
  // Reading the activation consumes nothing.
  _personActed() {
    if (!activated()) return false
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
    if (this._onChromeInput && win && typeof win.removeEventListener === "function") {
      for (const type of CHROME_INPUTS) win.removeEventListener(type, this._onChromeInput, true)
    }
    this.el.removeEventListener("load", this._onLoad)
    this.el.removeEventListener(FRAME_STATE_EVENT, this._onState)
    this.el.removeEventListener(CREDENTIAL_CLOSED_EVENT, this._onCredentialClosed)
    this.el.removeEventListener(TO_CANVAS_EVENT, this._onToCanvas)
    this.el.removeEventListener(FRAME_BEARER_EVENT, this._onBearer)
    this._closePort()
  }
}

// How long one input's transient user activation lasts: five seconds in
// Chromium and Firefox, and a little more. A verb within it of the last
// spend is dropped `too_soon`. The canvas proof waits it out before a
// person's click in a frame (tests/canvas-proof/proof.mjs).
export const ACTIVATION_LIFESPAN_MS = 5000 + 150

// The shell page's own inputs that give it activation: a press, a touch's
// end, a key. Each spends the activation it gives.
const CHROME_INPUTS = Object.freeze(["pointerdown", "pointerup", "touchend", "keydown"])

const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now())

// Whether the shell document holds transient user activation, which only
// the person's input gives it. Where the browser has no activation API,
// nothing counts.
function activated() {
  if (typeof window === "undefined") return false
  const {navigator} = window
  return Boolean(navigator && navigator.userActivation && navigator.userActivation.isActive === true)
}

export default IframeBridge
