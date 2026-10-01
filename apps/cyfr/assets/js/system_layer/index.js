// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {nextStop, tabOrder} from "./focus.js"
import {initial, transition} from "./state.js"
import {assert as assertPasskey, register as registerPasskey} from "./webauthn.js"

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
 * The show and hide decisions are `state.js`'s and the tab order is
 * `focus.js`'s; this hook only performs their effects.
 *
 * The same hook holds the passkey ceremony (`webauthn.js`), the one piece
 * of the browser a proof comes from:
 *
 *   * On the system layer, the server asks for a ceremony with the pushed
 *     events `webauthn:get` (`{purpose, id, public_key}`, request options)
 *     and `webauthn:create` (`{purpose, public_key, registration}`,
 *     creation options and the home's registration token); the hook
 *     answers `webauthn_result` (`{purpose, id, credential}`) or
 *     `webauthn_error` (`{purpose, id}`) to the layer.
 *   * On the sign-in page, an element with `data-webauthn="sign-in"` is
 *     a passkey sign-in: a click on its `[data-webauthn-start]` asks the
 *     page for a challenge (`passkey_start`, whose reply carries
 *     `public_key`), and answers it (`passkey_assertion`, `{credential}`)
 *     or says the ceremony did not finish (`passkey_error`). Such an
 *     element draws no prompt.
 */

const FOCUSABLE = "a[href], button, input, select, textarea, [tabindex]"

export default {
  mounted() {
    if (this.el.dataset.webauthn === "sign-in") return this.mountSignIn()

    this.handleCeremonies()
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
    if (this.el.dataset.webauthn === "sign-in") return
    this.dialog = this.el.querySelector("dialog")
    this.sync()
  },

  destroyed() {
    if (this.onSignIn) {
      this.el.removeEventListener("click", this.onSignIn)
      return
    }

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
  // from their answers, the home does.
  handleCeremonies() {
    if (typeof this.handleEvent !== "function") return

    this.handleEvent("webauthn:get", ({purpose, id, public_key: publicKey}) => {
      assertPasskey(publicKey, globalThis.navigator.credentials)
        .then((credential) => this.pushEventTo(this.el, "webauthn_result", {purpose, id, credential}))
        .catch(() => this.pushEventTo(this.el, "webauthn_error", {purpose, id}))
    })

    this.handleEvent("webauthn:create", ({purpose, public_key: publicKey, registration}) => {
      registerPasskey(publicKey, registration, globalThis.navigator.credentials)
        .then((credential) => this.pushEventTo(this.el, "webauthn_result", {purpose, credential}))
        .catch(() => this.pushEventTo(this.el, "webauthn_error", {purpose}))
    })
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

  dispatch(event) {
    const {state, effects} = transition(this.layer, event)
    this.layer = state
    for (const effect of effects) this.perform(effect)
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
        leaveFullscreen(doc).then(() => this.dispatch({type: "ready", attempt}))
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
