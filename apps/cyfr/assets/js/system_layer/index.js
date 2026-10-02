// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {
  answersCertify,
  certificateFromFragment,
  certifyUrl,
  codeFromFragment,
  freshCertify,
  freshPending,
  Glass,
  generateKeyPair,
  homeOrigin,
  openingPlan,
  openStore,
  promptModel,
  prove,
  publicKeyB64
} from "./device_key.js"
import {nextStop, tabOrder} from "./focus.js"
import {clearFields, clearKit, drawKit, fieldValue, Material, RestorePage} from "./recovery.js"
import {initial, transition} from "./state.js"
import {assert as assertPasskey, register as registerPasskey, supported as passkeysSupported} from "./webauthn.js"

/**
 * SystemLayer hook — the browser half of the layer Prism alone draws above
 * every frame (`PrismWeb.SystemLayer`). Registered as `Hooks.SystemLayer`
 * on the component's root, which carries `data-open`, `data-prompt-id`,
 * `data-dismissable` and `data-mode`; the prompt is the `<dialog>` inside
 * it.
 *
 * A prompt is shown in the browser's top layer — `showModal()`, or for
 * safe mode `showPopover()`, which leaves the assistant's panel operable —
 * only after the document has been asked to leave pointer lock and its
 * fullscreen exit has settled, so no frame's fullscreen covers it. While
 * it shows, a frame that takes fullscreen or pointer lock again is made to
 * leave them and the prompt is shown above it again. Focus moves into the
 * prompt and returns to where it was when the prompt closes; in a modal
 * prompt Tab and Shift+Tab wrap inside it. Escape dismisses every prompt
 * but safe mode; only the server closes a prompt.
 *
 * While a modal prompt is open, from the step that leaves fullscreen until
 * it closes, every frame on the page is hidden (`visibility: hidden`, by a
 * stylesheet the layer owns) and `inert`, a frame added meanwhile too: it
 * cannot draw over the prompt, take its input or act on it. On a page that
 * is not fullscreen the frames are hidden at once; on one that is, once the
 * exit has settled and the frames have had a moment to see it
 * (`framesSee`), and only then is the prompt shown: a frame hidden before
 * it saw the exit keeps its fullscreen and takes it back, with no gesture,
 * as soon as it is shown again. A page may hold two layers (the page's and
 * the person's own panel's); the frames stay hidden while either has a
 * modal prompt open. When the last one closes the stylesheet goes, and
 * each frame keeps the `inert` its server and its bridge last gave it: the
 * layer removes only the `inert` it added and nobody wrote since. Safe
 * mode's popover hides nothing: no app runs then.
 *
 * A frame's pointer lock is its own: no document can release a lock
 * another frame holds. Hiding a frame ends the lock in Chromium, but a
 * frame still holding its person's activation can take it again while
 * hidden. Escape always ends it, and focus stays in the prompt.
 *
 * The show and hide decisions are `state.js`'s and the tab order is
 * `focus.js`'s; this hook only performs their effects.
 *
 * The same hook holds the passkey ceremony (`webauthn.js`), the one piece
 * of the browser a proof comes from:
 *
 *   * On the system layer, the server asks for a ceremony with the pushed
 *     events `webauthn:get` (`{layer, purpose, id, public_key}`, request
 *     options) and `webauthn:create` (`{layer, purpose, public_key,
 *     registration}`, creation options and the home's registration
 *     token); the hook answers `webauthn_result` (`{purpose, id,
 *     credential}`) or `webauthn_error` (`{purpose, id}`) to the layer.
 *     Every event the layer pushes names it (`layer`, its element's id),
 *     and a layer's hook acts only on its own: a page may hold two layers
 *     (the page's and the person's own panel's), each its own element in
 *     the top layer, and every hook on a page hears every push.
 *   * On the sign-in page, an element with `data-webauthn="sign-in"` is
 *     a passkey sign-in: a click on its `[data-webauthn-start]` asks the
 *     page for a challenge (`passkey_start`, whose reply carries
 *     `public_key`), and answers it (`passkey_assertion`, `{credential}`)
 *     or says the ceremony did not finish (`passkey_error`). Such an
 *     element draws no prompt.
 *
 * A change that waits on a fresh confirmation repeats once its record is
 * confirmed. A typed value is never held by the server meanwhile: the
 * form keeps it, and the server asks the browser to submit that form
 * again (`system_layer:resubmit`, `{layer, form}`, the form's id). Every
 * form in a prompt is cleared when the prompt closes. A page's own form
 * that typed a credential, outside the prompt, is marked with the prompt
 * it asks under (`system_layer:mark`, `{layer, form, prompt}`), the mark
 * held here by form id, and every form so marked is cleared when that
 * prompt ends (`system_layer:clear`, `{layer, prompt, form}`) or when the
 * page reconnects,
 * since its waiting requests ended with the old page process. Keys typed
 * into a prompt stay in it: none drives the page behind it.
 *
 * A recovery prompt's form (`data-recovery`, `PrismWeb.SystemLayer.Recovery`)
 * is the browser's: a submit draws the new kit's seed and its request id
 * here (`recovery.js`'s `Material`), held in memory for that one request,
 * and sends them to the layer (`recovery_submit`); the same is sent again
 * on `recovery:resubmit` (`{layer, prompt}`), once its record is
 * confirmed, and on a retry. A kit's lines arrive on `recovery:kit`
 * (`{layer, prompt, kit}`) and are drawn as text into the prompt's own
 * place (`data-recovery-kit`); `recovery:clear` (`{layer, prompt}`), the
 * prompt's close and a reconnect forget the material and empty it.
 *
 * On the restore page (`/restore`), an element with `data-restore="page"`
 * holds the restore form (`recovery.js`'s `RestorePage`), which posts the
 * installation token and the kit to the restore ingress from the browser.
 *
 * On the glass's own page (`/pair`), an element with `data-glass="pair"`
 * is the glass. It reads a pairing code from the address's fragment and
 * clears it from the address, makes the device key pair
 * (`device_key.js`, kept across reloads), completes the pairing through
 * the page (`pair_start`, answered with the challenge; `pair_proof`,
 * answered with the client and its certificate), and then keeps the
 * device channel connected (`Glass`), renewing the certificate before it
 * expires and, after the device wakes, before anything else is sent. It
 * draws its own confirmation prompts from `confirmation.pending`, read
 * again on each fact of `confirmation.changes`, and proves them by their
 * ref with a passkey or an emailed code through device intents. A fresh
 * sign-in needs a signed-in browser, so the glass only says so.
 *
 * A glass that already holds a paired device, opened on a pairing link,
 * asks before it replaces that device: keeping it connects as before;
 * replacing it is an explicit choice that unpairs the stored device here
 * first (its key and certificate are erased; the home still lists it
 * until it is revoked), so someone else's link never silently rebinds a
 * glass.
 *
 * A pairing for a person whose keys are at another home is answered, with
 * its challenge, what their home is to certify (`certify`). The glass
 * keeps the code and its key pair as the pending pairing, for the
 * invitation's five minutes at most, asks for the address of their home,
 * keeps what it asked of that home (the store's certify record, as long),
 * and goes there (`<home>/carry#certify=…`). Their home sends the browser
 * back with the certificate (`/pair#certificate=…`), which is taken only
 * while that request stands and only when it answers it: issued by that
 * home, for this device's key and client, this home and the athanor. It
 * completes the pending pairing, or is presented in place of the
 * certificate of the device the glass holds, which it replaces once this
 * home stands it; any other changes nothing. The same address form is
 * offered whenever `Glass` offers to certify again: the person's home
 * ended the certification, or could not renew it after this home refused
 * it.
 *
 * Its controls carry `data-test` names: `glass-status` (with
 * `data-state`), `glass-error`, `glass-replace-ask`, `glass-replace`,
 * `glass-keep`, `glass-certify`, `glass-home`, `glass-home-submit`,
 * `glass-prompt` (with `data-ref`), `glass-preview`,
 * `glass-asker`, `glass-passkey`, `glass-email`, `glass-code-form`,
 * `glass-code`, `glass-code-submit`, `glass-reauth-note`, `glass-cancel`
 * and `glass-outcome` (with `data-ok`).
 */

const FOCUSABLE = "a[href], button, input, select, textarea, [tabindex]"

// ---------------------------------------------------------------------------
// The frames, hidden while any layer on the page has a modal prompt open
// ---------------------------------------------------------------------------

// Every layer of the page with a modal prompt open; shared by every layer's
// hook. While one does, a stylesheet the layer owns hides every frame, and
// each frame is `inert`. A frame's own `inert` belongs to the server's
// render and to the frame's bridge (`hooks/iframe_bridge.js`, which makes a
// frozen frame inert), so the layer adds the attribute only where it is
// absent, and gives back only what it added: a write of `inert` by anyone
// else while the page is covered is the frame's latest state, kept as its
// state when the last layer closes.
const covering = new Set()
const added = new Set()
let coverStyle = null
let frameWatch = null

// Whether a layer in `state` covers the page: a modal prompt opening or shown.
export const covers = (state) => state.phase !== "hidden" && state.mode === "modal"

// How long after the page left fullscreen its frames are given to see it,
// beyond two of the page's animation frames: each sees it at its own next
// rendering.
export const FRAMES_SEE_MS = 100

/** Resolves once the page's frames have had their moment to see a fullscreen exit. */
export function framesSee(wait = FRAMES_SEE_MS) {
  const raf = globalThis.requestAnimationFrame
  const twice = typeof raf === "function" ? new Promise((resolve) => raf(() => raf(resolve))) : Promise.resolve()
  return twice.then(() => new Promise((resolve) => setTimeout(resolve, wait)))
}

/**
 * `layer` (a hook) covers the page, or no longer does. The first to cover
 * hides every frame and makes it inert, and watches the page for frames
 * added and for anyone else's writes of a frame's `inert`; the last to stop
 * removes the stylesheet and the `inert` it added and nobody has written
 * since.
 */
export function cover(layer, on, doc = globalThis.document) {
  if (on) {
    const first = covering.size === 0
    covering.add(layer)
    if (first && doc && typeof doc.querySelectorAll === "function") {
      hideFrames(doc)
      for (const frame of doc.querySelectorAll("iframe")) inertFrame(frame)
      watchFrames(doc)
    }
  } else if (covering.delete(layer) && covering.size === 0) {
    if (frameWatch) frameWatch.disconnect()
    frameWatch = null
    if (coverStyle && typeof coverStyle.remove === "function") coverStyle.remove()
    coverStyle = null
    for (const frame of added) frame.removeAttribute("inert")
    added.clear()
  }
}

// The layer's own stylesheet, outside every frame and every dialog: no
// render of the server's touches it, and removing it gives each frame back
// whatever visibility its own attributes say.
function hideFrames(doc) {
  if (typeof doc.createElement !== "function") return
  const parent = doc.head || doc.documentElement
  if (!parent) return
  coverStyle = doc.createElement("style")
  coverStyle.setAttribute("data-system-layer-cover", "")
  coverStyle.textContent = "iframe { visibility: hidden !important; }"
  parent.appendChild(coverStyle)
}

function inertFrame(frame) {
  if (frame.hasAttribute("inert")) return
  frame.setAttribute("inert", "")
  added.add(frame)
}

// A frame added while the page is covered is made inert as it arrives; a
// write of a frame's `inert` by anyone else is its latest state: inert, it
// is the writer's to keep; not, the layer makes it inert again and gives
// that back when the page is uncovered. The layer's own writes are taken
// off the queue as it makes them.
function watchFrames(doc) {
  const Observer = globalThis.MutationObserver
  if (!Observer || !doc.body) return
  frameWatch = new Observer((records) => {
    for (const record of records) {
      if (record.type === "attributes") {
        const frame = record.target
        if (!frame || frame.nodeName !== "IFRAME") continue
        if (frame.hasAttribute("inert")) added.delete(frame)
        else inertFrame(frame)
      } else {
        for (const node of record.addedNodes || []) {
          if (node.nodeName === "IFRAME") inertFrame(node)
          else if (node.querySelectorAll) for (const frame of node.querySelectorAll("iframe")) inertFrame(frame)
        }
      }
    }
    if (frameWatch) frameWatch.takeRecords()
  })
  frameWatch.observe(doc.body, {childList: true, subtree: true, attributes: true, attributeFilter: ["inert"]})
}

export default {
  mounted() {
    if (this.el.dataset.webauthn === "sign-in") return this.mountSignIn()
    if (this.el.dataset.glass === "pair") return this.mountGlass()
    if (this.el.dataset.restore === "page") {
      this.restorePage = new RestorePage(this.el)
      return
    }

    this.handleCeremonies()
    this.gone = false
    this.layer = initial
    this.returnFocus = null
    this.dialog = this.el.querySelector("dialog")

    this.onCancel = (event) => {
      event.preventDefault()
      this.dispatch({type: "cancel"})
    }
    this.onClose = () => this.dispatch({type: "closed"})
    this.onKeydown = (event) => {
      if (event.key === "Tab") this.trap(event)
      // A key typed into a prompt is the prompt's alone.
      if (event.stopPropagation) event.stopPropagation()
    }
    this.onEscalated = () => {
      const doc = globalThis.document
      if (doc.fullscreenElement || doc.pointerLockElement) this.dispatch({type: "escalated"})
    }

    this.dialog.addEventListener("cancel", this.onCancel)
    this.dialog.addEventListener("close", this.onClose)
    this.dialog.addEventListener("keydown", this.onKeydown)
    globalThis.document.addEventListener("fullscreenchange", this.onEscalated)
    globalThis.document.addEventListener("pointerlockchange", this.onEscalated)

    this.sync()
  },

  updated() {
    if (this.el.dataset.webauthn === "sign-in" || this.el.dataset.glass === "pair") return
    if (this.el.dataset.restore === "page") return
    this.dialog = this.el.querySelector("dialog")
    this.sync()
  },

  destroyed() {
    if (this.onSignIn) {
      this.el.removeEventListener("click", this.onSignIn)
      return
    }

    if (this.glass) return this.destroyGlass()

    if (this.restorePage) {
      this.restorePage.destroy()
      return
    }

    // A layer that goes covers nothing and does nothing more: its state
    // machine ends, and a fullscreen exit still settling finds it gone.
    // The recovery material it held goes with it.
    this.gone = true
    this.forgetAllRecovery()
    if (this.onRecoverySubmit && typeof this.el.removeEventListener === "function") {
      this.el.removeEventListener("submit", this.onRecoverySubmit)
      this.el.removeEventListener("click", this.onRecoveryClick)
    }
    this.layer = {...initial, attempt: this.layer ? this.layer.attempt + 1 : 0}
    this.cover(false)
    this.dialog.removeEventListener("cancel", this.onCancel)
    this.dialog.removeEventListener("close", this.onClose)
    this.dialog.removeEventListener("keydown", this.onKeydown)
    globalThis.document.removeEventListener("fullscreenchange", this.onEscalated)
    globalThis.document.removeEventListener("pointerlockchange", this.onEscalated)
  },

  // A passkey sign-in: ask the page for its challenge, answer it once.
  mountSignIn() {
    this.onSignIn = (event) => {
      const start = event.target && event.target.closest ? event.target.closest("[data-webauthn-start]") : null
      if (!start) return
      event.preventDefault()
      this.pushEvent("passkey_start", {}, (reply) => {
        if (!reply || !reply.public_key) return
        assertPasskey(reply.public_key, globalThis.navigator.credentials)
          .then((credential) => this.pushEvent("passkey_assertion", {credential}))
          .catch(() => this.pushEvent("passkey_error", {}))
      })
    }
    this.el.addEventListener("click", this.onSignIn)
  },

  // The ceremonies the system layer asks for; the layer decides nothing
  // from their answers, the home does. Every hook on a page hears every
  // push, and a page may hold two layers (the page's and the panel's), so
  // each event names the layer it is for (`layer`, the layer's id) and
  // only that layer's hook acts on it: a ceremony runs once, and a form is
  // submitted again once.
  handleCeremonies() {
    if (typeof this.handleEvent !== "function") return
    this.marks = new Map()

    const on = (event, act) => this.handleEvent(event, (payload) => {
      if (payload && payload.layer === this.el.id) act(payload)
    })

    on("webauthn:get", ({purpose, id, public_key: publicKey}) => {
      assertPasskey(publicKey, globalThis.navigator.credentials)
        .then((credential) => this.pushEventTo(this.el, "webauthn_result", {purpose, id, credential}))
        .catch(() => this.pushEventTo(this.el, "webauthn_error", {purpose, id}))
    })

    on("webauthn:create", ({purpose, public_key: publicKey, registration}) => {
      registerPasskey(publicKey, registration, globalThis.navigator.credentials)
        .then((credential) => this.pushEventTo(this.el, "webauthn_result", {purpose, credential}))
        .catch(() => this.pushEventTo(this.el, "webauthn_error", {purpose}))
    })

    // A change confirmed: the form that typed it, which still holds what
    // was typed, is submitted again.
    on("system_layer:resubmit", ({form}) => resubmit(globalThis.document, form))

    // A page's form marked with the prompt it asks under, and emptied when
    // that prompt ends.
    on("system_layer:mark", ({form, prompt}) => markForm(this.marks, form, prompt))
    on("system_layer:clear", ({prompt, form}) => clearMarked(globalThis.document, this.marks, prompt, form))

    this.handleRecovery(on)
  },

  // ---------------------------------------------------------------------------
  // Recovery material
  // ---------------------------------------------------------------------------

  // A recovery prompt's form is submitted here, never by the browser: the
  // material is drawn or typed, held, and sent to the layer. The kit's
  // lines are drawn into the prompt's own place, and forgotten with it.
  handleRecovery(on) {
    this.material = new Material()

    on("recovery:resubmit", ({prompt}) => this.recoverySubmit(prompt))
    on("recovery:kit", ({prompt, kit}) => {
      // The request answered: the seed now lives in the kit's lines alone.
      this.material.forget(prompt)
      const form = this.recoveryForm(prompt)
      if (form) form.hidden = true
      drawKit(globalThis.document, this.kitSlot(prompt), kit)
    })
    on("recovery:clear", ({prompt}) => this.forgetRecovery(prompt))

    if (typeof this.el.addEventListener !== "function") return

    this.onRecoverySubmit = (event) => {
      const form = event.target
      if (!form || !form.dataset || !form.dataset.recovery) return
      event.preventDefault()
      this.recoverySubmit(form.dataset.prompt)
    }
    this.onRecoveryClick = (event) => {
      const target = event.target && event.target.closest ? event.target.closest("[data-recovery-print]") : null
      if (!target) return
      event.preventDefault()
      if (typeof globalThis.print === "function") globalThis.print()
    }
    this.el.addEventListener("submit", this.onRecoverySubmit)
    this.el.addEventListener("click", this.onRecoveryClick)
  },

  // What the prompt's form submits: the material held for it, or drawn now.
  recoverySubmit(promptId) {
    const form = this.recoveryForm(promptId)
    if (!form || !this.material) return
    const payload = this.material.submission(promptId, form.dataset.recovery, fieldValue(form, "recovery_secret"))
    this.pushEventTo(this.el, "recovery_submit", payload || {prompt_id: promptId})
  },

  recoveryForm(promptId) {
    if (typeof promptId !== "string" || typeof this.el.querySelector !== "function") return null
    return this.el.querySelector(`form[data-recovery][data-prompt="${promptId}"]`)
  },

  kitSlot(promptId) {
    if (typeof promptId !== "string" || typeof this.el.querySelector !== "function") return null
    return this.el.querySelector(`[data-recovery-kit="${promptId}"]`)
  },

  // The prompt's material forgotten, its kit's lines and typed secret
  // emptied, its form ready again.
  forgetRecovery(promptId) {
    if (this.material) this.material.forget(promptId)
    clearKit(this.kitSlot(promptId))
    const form = this.recoveryForm(promptId)
    if (form) {
      clearFields(form)
      form.hidden = false
    }
  },

  forgetAllRecovery() {
    forgetAllRecovery(this)
  },

  // A reconnect is a new page process: every request this page was waiting
  // on ended with the old one, so every form it typed for is emptied, and
  // the recovery material it held is forgotten.
  reconnected() {
    clearAllMarked(globalThis.document, this.marks)
    forgetAllRecovery(this)
  },

  sync() {
    this.dispatch({
      type: "sync",
      open: this.el.dataset.open === "true",
      promptId: this.el.dataset.promptId || null,
      dismissable: this.el.dataset.dismissable === "true",
      mode: this.el.dataset.mode === "popover" ? "popover" : "modal"
    })
  },

  // A modal prompt hides the page's frames before it shows, and gives them
  // back only once its dialog has closed. On a page that is not fullscreen
  // they are hidden before anything else it does; on one that is, once the
  // exit has settled and the frames saw it (`exit-fullscreen`). Focus goes
  // back only after the frames do: a browser may refuse to focus a frame
  // that is still hidden and inert, and Firefox does.
  dispatch(event) {
    const {state, effects} = transition(this.layer, event)
    this.layer = state
    const on = covers(state)
    if (on && !globalThis.document.fullscreenElement) this.cover(true)

    for (const effect of effects) {
      if (effect === "restore-focus" && !on) this.cover(false)
      this.perform(effect)
    }

    if (!on) this.cover(false)
  },

  cover(on) {
    cover(this, on, globalThis.document)
  },

  perform(effect) {
    const doc = globalThis.document

    switch (effect) {
      case "remember-focus":
        this.returnFocus = doc.activeElement || null
        break

      case "exit-pointer-lock":
        if (doc.pointerLockElement && doc.exitPointerLock) doc.exitPointerLock()
        break

      case "exit-fullscreen": {
        const attempt = this.layer.attempt
        const wasFullscreen = Boolean(doc.fullscreenElement)
        const see = this.framesSee || framesSee
        // Settled after the layer went, it does nothing: a destroyed hook
        // never covers the page again.
        leaveFullscreen(doc)
          .then(() => (wasFullscreen && covers(this.layer) ? see() : undefined))
          .then(() => {
            if (this.gone) return
            if (covers(this.layer) && this.layer.attempt === attempt) this.cover(true)
            this.dispatch({type: "ready", attempt})
          })
        break
      }

      case "show":
        if (this.layer.mode === "popover") {
          if (!popoverOpen(this.dialog)) this.dialog.showPopover()
        } else if (!this.dialog.open) {
          this.dialog.showModal()
        }
        break

      case "focus-first": {
        const [first] = this.stops()
        if (first) first.focus()
        break
      }

      case "close":
        clearForms(this.dialog)
        this.forgetAllRecovery()
        if (popoverOpen(this.dialog)) this.dialog.hidePopover()
        if (this.dialog.open) this.dialog.close()
        break

      case "restore-focus": {
        const target = this.returnFocus
        this.returnFocus = null
        if (target && target.isConnected !== false && target.focus) target.focus()
        break
      }

      case "push-dismiss":
        this.pushEventTo(this.el, "dismiss", {id: this.layer.promptId})
        break
    }
  },

  // The prompt's controls in the order Tab reaches them.
  stops() {
    const elements = Array.from(this.dialog.querySelectorAll(FOCUSABLE))
    const order = tabOrder(elements.map(describe))
    return order.map((position) => elements[position])
  },

  // ---------------------------------------------------------------------------
  // The glass
  // ---------------------------------------------------------------------------

  mountGlass() {
    const doc = globalThis.document
    const location = globalThis.location
    const code = codeFromFragment(location && location.hash)
    const returned = certificateFromFragment(location && location.hash)
    // The code is a bearer secret: it leaves the address at once.
    if (location && location.hash && globalThis.history) {
      globalThis.history.replaceState(null, "", location.pathname + location.search)
    }

    this.store = this.store || openStore()
    this.codeSent = new Set()
    this.home = `${location && location.protocol}//${location && location.host}`
    const scheme = location && location.protocol === "https:" ? "wss:" : "ws:"
    this.glass = new Glass({
      url: `${scheme}//${location && location.host}/device/websocket`,
      socket: (url) => new globalThis.WebSocket(url),
      store: this.store,
      home: this.home,
      onChange: (glass) => this.drawGlass(glass)
    })

    this.onWake = () => {
      if (doc.visibilityState !== "hidden") this.glass.wake()
    }
    this.onGlassClick = (event) => this.glassClick(event)
    this.onGlassSubmit = (event) => this.glassSubmit(event)
    doc.addEventListener("visibilitychange", this.onWake)
    if (globalThis.addEventListener) globalThis.addEventListener("online", this.onWake)
    this.el.addEventListener("click", this.onGlassClick)
    this.el.addEventListener("submit", this.onGlassSubmit)

    return this.store.load().then((stored) => {
      if (returned) return this.certificateReturned(returned, stored)
      switch (openingPlan(code, stored)) {
        case "ask":
          // A device is paired here already: nothing changes until the
          // person chooses.
          this.pendingCode = code
          return this.drawGlass(this.glass)
        case "pair":
          return this.pairGlass(code).then((outcome) => (outcome === "certify" ? undefined : this.glass.start()))
        default:
          return this.glass.start()
      }
    }).catch(() =>
      // The browser would not open this device's store (storage blocked or
      // cleared, or a private window): nothing starts, and the page says so.
      this.pairRefused("This browser would not open the store that keeps this device's key. Allow site storage for this page and reload.")
    )
  },

  // Keep the stored device and forget the code, or unpair the stored
  // device and pair under the code.
  async replaceDevice(replace) {
    const code = this.pendingCode
    this.pendingCode = null
    if (replace && code) {
      await this.glass.unpair()
      if ((await this.pairGlass(code)) === "certify") return
    }
    return this.glass.start()
  },

  // The certificate the person's home sent back, taken only while what
  // the person asked of that home stands and only when it answers it: the
  // pending pairing it completes, or the certificate of the device this
  // glass holds, which this home must stand before it is kept. Anything
  // else, a link no request of this device led to included, changes
  // nothing.
  async certificateReturned(certificate, stored) {
    const now = Date.now()
    const asked = await freshCertify(this.store, now)
    const pending = await freshPending(this.store, now)

    if (asked && pending && asked.client === pending.certify.client_id && answersCertify(certificate, asked, {deviceKey: pending.publicKey, home: this.home})) {
      await this.store.clearCertify()
      await this.pairRemote(pending, certificate)
      return this.glass.start()
    }

    if (asked && stored && asked.client === stored.clientId && answersCertify(certificate, asked, {deviceKey: stored.publicKey, home: this.home})) {
      await this.store.clearCertify()
      return this.glass.start(certificate)
    }

    this.pairRefused("That certificate is not one this device asked its home for, so nothing changed.")
    return stored ? this.glass.start() : this.drawGlass(this.glass)
  },

  // The pending pairing completed under its person's home's certificate:
  // the same two steps, each bringing the certificate.
  async pairRemote(pending, certificate) {
    this.drawStatus("pairing", "Pairing this device…")

    try {
      const base = {invitation_secret: pending.code, device_key: pending.publicKey, certificate}
      const started = await this.pushAsync("pair_start", base)
      if (!started || started.error) return this.endPending((started && started.error) || "The pairing did not start.")

      const expected = {purpose: "pair", home: this.home, deviceKey: pending.publicKey, clientId: pending.certify.client_id}
      const proof = await prove(started.challenge, pending.privateKey, expected)
      const paired = await this.pushAsync("pair_proof", {...base, proof})
      if (!paired || paired.error) return this.endPending((paired && paired.error) || "The pairing did not finish.")

      await this.store.save({privateKey: pending.privateKey, publicKey: pending.publicKey, clientId: paired.client_id, certificate: paired.certificate})
      await this.store.clearPending()
      this.certifyAsk = null
    } catch (error) {
      await this.endPending(error.refused ? error.message : "This browser cannot hold a device key here.")
    }
  },

  // A pending pairing that cannot finish holds its code no longer.
  async endPending(text) {
    await this.store.clearPending()
    await this.store.clearCertify()
    this.certifyAsk = null
    this.pairRefused(text)
  },

  destroyGlass() {
    globalThis.document.removeEventListener("visibilitychange", this.onWake)
    if (globalThis.removeEventListener) globalThis.removeEventListener("online", this.onWake)
    this.el.removeEventListener("click", this.onGlassClick)
    this.el.removeEventListener("submit", this.onGlassSubmit)
    this.glass.closeSocket()
  },

  // The pairing, in two steps through the page: the key pair is made here
  // and its private key never leaves; the secret goes only to this home.
  async pairGlass(code) {
    this.drawStatus("pairing", "Pairing this device…")

    try {
      const {privateKey, publicKey} = await generateKeyPair()
      const deviceKey = await publicKeyB64(publicKey)
      const started = await this.pushAsync("pair_start", {invitation_secret: code, device_key: deviceKey})
      if (!started || started.error) return this.pairRefused((started && started.error) || "The pairing did not start.")

      // The person's keys are at another home, which certifies this device:
      // the code and key pair wait for its certificate, at most the
      // invitation's life, while the person goes there.
      if (started.certify) {
        await this.store.savePending({code, privateKey, publicKey: deviceKey, certify: started.certify, at: Date.now()})
        this.certifyAsk = {request: {...started.certify, device_key: deviceKey}, home: ""}
        this.drawStatus("certify", "Your keys are held at another home. Certify this device there to pair it here.")
        return "certify"
      }

      // This home's own pairing challenge, for the key just made: the
      // client it names is the one this home's invitation reserved for the
      // device, which the device learns here first.
      const reserved = started.challenge && started.challenge.client_id
      const proof = await prove(started.challenge, privateKey, {purpose: "pair", home: this.home, deviceKey, clientId: reserved})
      const paired = await this.pushAsync("pair_proof", {invitation_secret: code, device_key: deviceKey, proof})
      if (!paired || paired.error) return this.pairRefused((paired && paired.error) || "The pairing did not finish.")

      await this.store.save({privateKey, publicKey: deviceKey, clientId: paired.client_id, certificate: paired.certificate})
      return "paired"
    } catch (error) {
      this.pairRefused(error.refused ? error.message : "This browser cannot hold a device key here.")
    }
  },

  // A pairing the home refused says so, and why; the person shows a new
  // code to try again.
  pairRefused(text) {
    this.pairError = text
    this.drawGlass(this.glass)
  },

  pushAsync(event, payload) {
    return new Promise((resolve) => this.pushEvent(event, payload, (reply) => resolve(reply)))
  },

  glassClick(event) {
    const target = event.target && event.target.closest ? event.target.closest("[data-action]") : null
    if (!target) return
    event.preventDefault()
    if (target.dataset.action === "replace") return this.replaceDevice(true)
    if (target.dataset.action === "keep") return this.replaceDevice(false)
    const ref = target.dataset.ref
    const entry = this.glass.pending.find((pending) => pending.ref === ref)
    if (!entry) return

    switch (target.dataset.action) {
      case "passkey":
        return assertPasskey(entry.webauthn, globalThis.navigator.credentials)
          .then((credential) => this.glass.confirmWithPasskey(ref, credential))
          .catch(() => this.glass.note(ref, false, "The passkey did not answer. Nothing was confirmed."))
      case "email":
        this.codeSent.add(ref)
        return this.glass.sendCode(ref)
      case "cancel":
        return this.glass.cancel(ref)
    }
  },

  glassSubmit(event) {
    const form = event.target
    if (form && form.dataset && form.dataset.form === "certify-home") {
      event.preventDefault()
      return this.certifyAt(form.elements && form.elements.home ? form.elements.home.value : "")
    }
    if (!form || !form.dataset || !form.dataset.ref) return
    event.preventDefault()
    const code = form.elements && form.elements.code ? form.elements.code.value.trim() : ""
    if (code) this.glass.confirmWithCode(form.dataset.ref, code)
  },

  // The person named their own home: there, they certify this device for
  // what this home reserved, under a fresh confirmation. What was asked of
  // that home is kept first: only a certificate answering it is taken when
  // the browser comes back.
  async certifyAt(typed) {
    const ask = this.certifyOffer()
    const home = homeOrigin(typed)
    if (!ask || !home) {
      this.pairError = "That is not a home's address, like https://home.example."
      return this.drawGlass(this.glass)
    }
    if (home === this.home) {
      this.pairError = "That is this home's address; name the home that holds your keys."
      return this.drawGlass(this.glass)
    }
    const {request} = ask
    try {
      await this.store.saveCertify({home, client: request.client_id, audience: request.audience, athanor: request.athanor, at: Date.now()})
    } catch (_error) {
      this.pairError = "This browser would not keep what this device asks of your home. Allow site storage for this page and try again."
      return this.drawGlass(this.glass)
    }
    globalThis.location.assign(certifyUrl(home, request))
  },

  // What to certify, and the home to suggest: a pending pairing's, or the
  // held device's once its certification ended at the home that issued it.
  certifyOffer() {
    if (this.certifyAsk) return this.certifyAsk
    const glass = this.glass
    if (glass && glass.certifyAgain && glass.device) {
      return {request: glass.certifyRequest(), home: glass.device.certificate.issuer}
    }
    return null
  },

  drawStatus(state, text) {
    this.status = {state, text}
    this.drawGlass(this.glass)
  },

  // The glass's page, drawn from its state alone, every value as text.
  drawGlass(glass) {
    const doc = globalThis.document
    const status = glassStatus(glass, this.status)
    const nodes = [element(doc, "p", {"data-test": "glass-status", "data-state": status.state, class: "text-sm"}, status.text)]
    if (this.pairError) nodes.push(element(doc, "p", {"data-test": "glass-error", role: "alert", class: "text-sm"}, this.pairError))

    if (this.pendingCode) {
      nodes.push(
        element(doc, "section", {"data-test": "glass-replace-ask", class: "space-y-2"}, [
          element(
            doc,
            "p",
            {class: "text-sm"},
            "This device is already paired with this home. Pairing it under this code forgets the device it holds and pairs it as whoever showed the code."
          ),
          element(doc, "button", {type: "button", "data-test": "glass-replace", "data-action": "replace"}, "Forget this device and pair again"),
          element(doc, "button", {type: "button", "data-test": "glass-keep", "data-action": "keep"}, "Keep this device")
        ])
      )
    }
    const offer = this.certifyOffer()
    if (offer) {
      nodes.push(
        element(doc, "section", {"data-test": "glass-certify", class: "space-y-2"}, [
          element(
            doc,
            "p",
            {class: "text-sm"},
            this.certifyAsk
              ? "Your keys are held at another home. Name it to certify this device there; you confirm it there, then come back here."
              : glass.certifyReason === "unreachable"
                ? "Your home could not be reached to renew this device's certificate. If your keys are now held at another home, name it; you confirm it there, then come back here. This device keeps trying meanwhile."
                : "Your home ended this device's certification, as it does when your keys change. Certify it again there; you confirm it there, then come back here."
          ),
          element(doc, "form", {"data-form": "certify-home", class: "flex gap-2"}, [
            element(doc, "input", {"data-test": "glass-home", name: "home", type: "text", inputmode: "url", autocomplete: "url", value: offer.home || "", "aria-label": "The address of the home that holds your keys"}),
            element(doc, "button", {type: "submit", "data-test": "glass-home-submit"}, this.certifyAsk ? "Certify at my home" : "Certify this device again at your home")
          ])
        ])
      )
    }
    const webauthn = passkeysSupported(globalThis)

    for (const entry of (glass && glass.status === "ready" && glass.pending) || []) {
      const model = promptModel(entry, {webauthn})
      const outcome = glass.outcome[model.ref]
      const children = [
        element(doc, "h2", {class: "text-lg font-semibold"}, `Confirm ${model.operation}`),
        element(
          doc,
          "dl",
          {"data-test": "glass-preview", class: "grid grid-cols-3 gap-1 text-sm"},
          model.rows.flatMap(([name, value]) => [element(doc, "dt", {class: "text-gray-400"}, name), element(doc, "dd", {class: "col-span-2 break-all"}, value)])
        ),
        element(doc, "p", {"data-test": "glass-asker", class: "text-sm"}, `Asked by ${model.asker}.`)
      ]

      if (model.offers.includes("passkey")) {
        children.push(button(doc, "glass-passkey", "passkey", model.ref, "Confirm with a passkey"))
      }
      if (model.offers.includes("email")) {
        if (this.codeSent.has(model.ref)) {
          children.push(
            element(doc, "form", {"data-test": "glass-code-form", "data-ref": model.ref, class: "flex gap-2"}, [
              element(doc, "input", {"data-test": "glass-code", name: "code", inputmode: "numeric", autocomplete: "one-time-code", "aria-label": "The code sent to your email"}),
              element(doc, "button", {type: "submit", "data-test": "glass-code-submit"}, "Confirm")
            ])
          )
        } else {
          children.push(button(doc, "glass-email", "email", model.ref, "Email me a code"))
        }
      }
      if (model.signInElsewhere) {
        children.push(element(doc, "p", {"data-test": "glass-reauth-note", class: "text-xs text-gray-400"}, "To confirm with a fresh sign-in, use a browser signed in to this home."))
      }
      children.push(button(doc, "glass-cancel", "cancel", model.ref, "Cancel this request"))
      if (outcome) children.push(element(doc, "p", {"data-test": "glass-outcome", "data-ok": String(outcome.ok), role: "status", class: "text-sm"}, outcome.text))

      nodes.push(element(doc, "section", {"data-test": "glass-prompt", "data-ref": model.ref, class: "space-y-2 rounded-md border border-gray-700 p-3"}, children))
    }

    this.el.replaceChildren(...nodes)
  },

  // Only a modal prompt holds focus; safe mode leaves the page reachable.
  trap(event) {
    if (this.layer.phase !== "shown" || this.layer.mode !== "modal") return
    const stops = this.stops()
    const current = stops.indexOf(globalThis.document.activeElement)
    const next = nextStop(stops.length, current, event.shiftKey)
    event.preventDefault()
    if (next >= 0) stops[next].focus()
  }
}

// Every recovery prompt of the layer `hook` forgotten: the material it
// holds, each kit's lines and each typed secret.
export function forgetAllRecovery(hook) {
  if (!hook) return
  if (hook.material) hook.material.forgetAll()
  const el = hook.el
  const all = (selector) => (el && typeof el.querySelectorAll === "function" ? el.querySelectorAll(selector) : [])
  for (const slot of all("[data-recovery-kit]")) clearKit(slot)
  for (const form of all("form[data-recovery]")) clearFields(form)
}

// Submit the form `id` names again, as its own submit would.
export function resubmit(doc, id) {
  const form = doc && typeof doc.getElementById === "function" ? doc.getElementById(id) : null
  if (form && typeof form.requestSubmit === "function") form.requestSubmit()
}

// A page's form, marked with the prompt it asks under. The mark is held
// here, by form id, never on the form: LiveView's patch of an ignored
// element drops every data attribute its render lacks, so a mark on the
// form would not outlive the page's next render.
export function markForm(marks, id, prompt) {
  if (!marks || typeof id !== "string" || id === "" || typeof prompt !== "string") return
  const ids = marks.get(prompt) || new Set()
  ids.add(id)
  marks.set(prompt, ids)
}

// The forms `prompt` asked under, and the one its end names, emptied and
// unmarked.
export function clearMarked(doc, marks, prompt, form) {
  const ids = new Set(marks && marks.get(prompt))
  if (typeof form === "string" && form !== "") ids.add(form)
  if (marks) marks.delete(prompt)
  for (const id of ids) resetForm(doc, id)
}

// Every marked form emptied: their prompts ended with the page process.
export function clearAllMarked(doc, marks) {
  if (!marks) return
  for (const ids of marks.values()) for (const id of ids) resetForm(doc, id)
  marks.clear()
}

function resetForm(doc, id) {
  const form = doc && typeof doc.getElementById === "function" ? doc.getElementById(id) : null
  if (form && typeof form.reset === "function") form.reset()
}

// Every form in a prompt, emptied as the prompt closes.
export function clearForms(dialog) {
  const forms = dialog && typeof dialog.querySelectorAll === "function" ? dialog.querySelectorAll("form") : []
  for (const form of forms) if (typeof form.reset === "function") form.reset()
}

// What the glass says of its connection.
export function glassStatus(glass, drawn) {
  switch (glass && glass.status) {
    case "unpaired":
      return {state: "unpaired", text: "This device is not paired. Open a pairing code from a browser signed in to this home."}
    case "connecting":
      return {state: "connecting", text: "Connecting…"}
    case "renewing":
      return {state: "renewing", text: "Renewing this device's certificate before anything else is sent…"}
    case "ready":
      return {state: "ready", text: "Connected. A change that needs your confirmation appears here."}
    case "waiting":
      return {state: "waiting", text: "Disconnected; trying again."}
    case "revoked":
      return {state: "revoked", text: "This device's pairing was revoked. Pair it again from a signed-in browser."}
    case "recertify":
      return {state: "recertify", text: "This device's certification at your home ended. Certify it again there."}
    default:
      return drawn || {state: "starting", text: "Starting…"}
  }
}

function element(doc, tag, attrs = {}, children = []) {
  const node = doc.createElement(tag)
  for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value)
  for (const child of Array.isArray(children) ? children : [children]) {
    if (child === null || child === undefined) continue
    node.append(typeof child === "string" ? doc.createTextNode(child) : child)
  }
  return node
}

function button(doc, test, action, ref, text) {
  return element(doc, "button", {type: "button", "data-test": test, "data-action": action, "data-ref": ref}, text)
}

function popoverOpen(dialog) {
  try {
    return dialog.matches(":popover-open")
  } catch (_error) {
    return false
  }
}

// A control as `focus.js` reads it.
function describe(element) {
  return {
    tabIndex: element.tabIndex,
    disabled: Boolean(element.disabled),
    hidden: element.type === "hidden" || Boolean(element.hidden)
  }
}

// Leave fullscreen and answer once the exit settled, or at once when the
// document is not fullscreen. A refused exit still settles: the prompt
// then shows in the top layer above the fullscreen element, which the
// escalation guard leaves again.
function leaveFullscreen(doc) {
  if (!doc.fullscreenElement) return Promise.resolve()

  try {
    const exit = doc.exitFullscreen ? doc.exitFullscreen() : doc.webkitExitFullscreen?.()
    return Promise.resolve(exit).catch(() => undefined)
  } catch (_error) {
    return Promise.resolve()
  }
}
