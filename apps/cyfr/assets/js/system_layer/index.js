// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {nextStop, tabOrder} from "./focus.js"
import {
  clearCode,
  clearFields,
  codeNodes,
  copyCode,
  drawCode,
  drawRequestId,
  drawSeed,
  fieldValue,
  Material,
  RestorePage
} from "./recovery.js"
import {initial, transition} from "./state.js"
import {assert as assertPasskey, register as registerPasskey} from "./webauthn.js"

/**
 * SystemLayer hook — the browser half of the layer Prism alone draws above
 * every frame (`PrismWeb.SystemLayer`). Registered as `Hooks.SystemLayer`
 * on the component's root, which carries `data-open` and `data-prompt-id`;
 * the prompt is the `<dialog>` inside it.
 *
 * A prompt is shown modal in the browser's top layer (`showModal()`) only
 * after the document has been asked to leave pointer lock and its
 * fullscreen exit has settled, so no frame's fullscreen covers it. While
 * it shows, a frame that takes fullscreen or pointer lock again is made to
 * leave them and the prompt is shown above it again. Focus moves into the
 * prompt and returns to where it was when the prompt closes; Tab and
 * Shift+Tab wrap inside it. Escape dismisses every prompt; only the server
 * closes a prompt.
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
 * layer removes only the `inert` it added and nobody wrote since.
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
 *   * On the setup page, an element with `data-webauthn="setup"` is the
 *     first person's passkey, and on the invitation page one with
 *     `data-webauthn="invite"` is the invited newcomer's; each names its
 *     events by that mode (`setup_…`, `invite_…`). On mount it hands the
 *     page the setup token or the invitation code the address carries in
 *     its fragment (`<mode>_token`, `{token}`), which no server log
 *     records, and a click on its `[data-webauthn-start]` draws the new
 *     person's recovery secret (32 bytes, `drawSeed`) and its request id
 *     (`drawRequestId`), asks the page for creation options
 *     (`<mode>_start`, whose reply carries `public_key` and
 *     `registration`), creates the passkey and answers it with the two
 *     (`<mode>_passkey`, `{credential, recovery_secret, request_id}`;
 *     the page adds the name it holds), or says the ceremony did not
 *     finish (`<mode>_error`). The secret is held for that one ceremony
 *     alone. Such an element draws no prompt.
 *   * On the sign-in page, an element with `data-webauthn="create"` is a
 *     newcomer's passkey under an open admission: as the setup page's,
 *     with no fragment read, through `create_start`, `create_passkey` and
 *     `create_error`. Such an element draws no prompt.
 *   * On those three, once the person is admitted, the page pushes their
 *     recovery code once (`admission_code`, `{code}`): it is drawn as the
 *     text of the screen's `[data-test="recovery-code"]`, which the page's
 *     markup leaves empty and keeps the browser's, and is held nowhere
 *     else, so it goes when that element goes. A click on
 *     `[data-test="admission-copy"]` writes it to the clipboard and says
 *     "Copied.".
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
 * is the browser's: a submit draws the new recovery code's secret and its
 * request id here (`recovery.js`'s `Material`), with the typed recovery
 * code that signs an added one, held in memory for that one request, and
 * sends them to the layer (`recovery_submit`); the same is sent again on
 * `recovery:resubmit` (`{layer, prompt}`), once its record is confirmed,
 * and on a retry. A recovery code arrives on `recovery:code`
 * (`{layer, prompt, code}`) and is drawn as text into the prompt's own
 * place (`data-recovery-code`) with a Copy button, whose click writes the
 * code to the clipboard; `recovery:clear` (`{layer, prompt}`), the
 * prompt's close and a reconnect forget the material and empty it.
 *
 * On the restore page (`/restore`), an element with `data-restore="page"`
 * holds the restore form (`recovery.js`'s `RestorePage`), which posts the
 * installation token and the recovery code to the restore ingress from the
 * browser.
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

// Whether a layer in `state` covers the page: a prompt opening or shown.
export const covers = (state) => state.phase !== "hidden"

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

// The pages whose link carries a token in its fragment, by their
// `data-webauthn` mode; with `create`, the pages whose passkey makes a
// newcomer.
const NEWCOMER_MODES = new Set(["setup", "invite"])

export default {
  mounted() {
    if (this.el.dataset.webauthn === "sign-in") return this.mountSignIn()
    if (NEWCOMER_MODES.has(this.el.dataset.webauthn)) return this.mountNewcomer()
    if (this.el.dataset.webauthn === "create") return this.mountRegistration("create")
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
    if (this.el.dataset.webauthn) return
    if (this.el.dataset.restore === "page") return
    this.dialog = this.el.querySelector("dialog")
    this.sync()
  },

  destroyed() {
    if (this.onSignIn) {
      this.el.removeEventListener("click", this.onSignIn)
      clearAdmissionCode(this.el)
      return
    }

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

  // A newcomer's passkey: the fragment's token to the page, then a
  // registration under the options the page answers, once per click.
  pushFragment() {
    const hash = globalThis.location ? globalThis.location.hash : ""
    this.pushEvent(`${this.el.dataset.webauthn}_token`, {token: hash.startsWith("#") ? hash.slice(1) : hash})
  },

  mountNewcomer() {
    this.pushFragment()
    this.mountRegistration(this.el.dataset.webauthn)
  },

  // A newcomer's passkey, once per click: the recovery secret and request
  // id drawn at the tap, `<mode>_start` for the creation options, then
  // `<mode>_passkey` with the two, or `<mode>_error`. Once admitted, the
  // page's recovery code is drawn into the screen, and Copy writes it.
  mountRegistration(mode) {
    this.onSignIn = (event) => {
      const target = event.target && event.target.closest ? event.target : null
      const copy = target ? target.closest('[data-test="admission-copy"]') : null
      if (copy) {
        event.preventDefault()
        return copyCode(copy, globalThis.navigator?.clipboard)
      }
      const start = target ? target.closest("[data-webauthn-start]") : null
      if (!start) return
      event.preventDefault()
      const material = {recovery_secret: drawSeed(), request_id: drawRequestId()}
      this.pushEvent(`${mode}_start`, {}, (reply) => {
        if (!reply || !reply.public_key) return
        registerPasskey(reply.public_key, reply.registration, globalThis.navigator.credentials)
          .then((credential) => this.pushEvent(`${mode}_passkey`, {credential, ...material}))
          .catch(() => this.pushEvent(`${mode}_error`, {}))
      })
    }
    this.el.addEventListener("click", this.onSignIn)
    if (typeof this.handleEvent === "function")
      this.handleEvent("admission_code", ({code}) => drawAdmissionCode(this.el, code))
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
  // material is drawn or typed, held, and sent to the layer. The recovery
  // code is drawn into the prompt's own place, and forgotten with it.
  handleRecovery(on) {
    this.material = new Material()

    on("recovery:resubmit", ({prompt}) => this.recoverySubmit(prompt))
    on("recovery:code", ({prompt, code}) => {
      // The request answered: the secret now lives in the drawn code alone.
      this.material.forget(prompt)
      const form = this.recoveryForm(prompt)
      if (form) form.hidden = true
      drawCode(globalThis.document, this.codeSlot(prompt), code)
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
      const target = event.target && event.target.closest ? event.target.closest("[data-recovery-copy]") : null
      if (!target) return
      event.preventDefault()
      return copyCode(target, globalThis.navigator?.clipboard)
    }
    this.el.addEventListener("submit", this.onRecoverySubmit)
    this.el.addEventListener("click", this.onRecoveryClick)
  },

  // What the prompt's form submits: the material held for it, or drawn now.
  recoverySubmit(promptId) {
    const form = this.recoveryForm(promptId)
    if (!form || !this.material) return
    const payload = this.material.submission(promptId, form.dataset.recovery, fieldValue(form, "recovery_code"))
    this.pushEventTo(this.el, "recovery_submit", payload || {prompt_id: promptId})
  },

  recoveryForm(promptId) {
    if (typeof promptId !== "string" || typeof this.el.querySelector !== "function") return null
    return this.el.querySelector(`form[data-recovery][data-prompt="${promptId}"]`)
  },

  codeSlot(promptId) {
    if (typeof promptId !== "string" || typeof this.el.querySelector !== "function") return null
    return this.el.querySelector(`[data-recovery-code="${promptId}"]`)
  },

  // The prompt's material forgotten, its drawn code and typed code
  // emptied, its form ready again.
  forgetRecovery(promptId) {
    if (this.material) this.material.forget(promptId)
    clearCode(this.codeSlot(promptId))
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
    // A newcomer page's new process holds no token: hand it over again.
    if (this.el && NEWCOMER_MODES.has(this.el.dataset.webauthn)) return this.pushFragment()
    clearAllMarked(globalThis.document, this.marks)
    forgetAllRecovery(this)
  },

  sync() {
    this.dispatch({
      type: "sync",
      open: this.el.dataset.open === "true",
      promptId: this.el.dataset.promptId || null
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
        if (!this.dialog.open) this.dialog.showModal()
        break

      case "focus-first": {
        const [first] = this.stops()
        if (first) first.focus()
        break
      }

      case "close":
        clearForms(this.dialog)
        this.forgetAllRecovery()
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

  // A shown prompt holds focus.
  trap(event) {
    if (this.layer.phase !== "shown") return
    const stops = this.stops()
    const current = stops.indexOf(globalThis.document.activeElement)
    const next = nextStop(stops.length, current, event.shiftKey)
    event.preventDefault()
    if (next >= 0) stops[next].focus()
  }
}

// The recovery code an admission pushed, drawn as the text of the screen's
// own place under `root`; nothing else holds it.
export function drawAdmissionCode(root, code) {
  const slot = root && typeof root.querySelector === "function" ? root.querySelector('[data-test="recovery-code"]') : null
  if (!slot || typeof code !== "string" || !code) return
  const doc = slot.ownerDocument
  if (!doc || typeof slot.replaceChildren !== "function") {
    slot.textContent = code
    return
  }
  slot.replaceChildren(...codeNodes(doc, code))
}

// The screen's drawn recovery code under `root`, emptied.
export function clearAdmissionCode(root) {
  const slot = root && typeof root.querySelector === "function" ? root.querySelector('[data-test="recovery-code"]') : null
  if (slot) slot.textContent = ""
}

// Every recovery prompt of the layer `hook` forgotten: the material it
// holds, each drawn code and each typed code.
export function forgetAllRecovery(hook) {
  if (!hook) return
  if (hook.material) hook.material.forgetAll()
  const el = hook.el
  const all = (selector) => (el && typeof el.querySelectorAll === "function" ? el.querySelectorAll(selector) : [])
  for (const slot of all("[data-recovery-code]")) clearCode(slot)
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
