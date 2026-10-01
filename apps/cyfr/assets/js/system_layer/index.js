// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {codeFromFragment, Glass, generateKeyPair, openingPlan, openStore, promptModel, prove, publicKeyB64} from "./device_key.js"
import {nextStop, tabOrder} from "./focus.js"
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
 *
 * A change that waits on a fresh confirmation repeats once its record is
 * confirmed. A typed value is never held by the server meanwhile: the
 * form keeps it, and the server asks the browser to submit that form
 * again (`system_layer:resubmit`, `{form}`, the form's id). Every form in
 * a prompt is cleared when the prompt closes. A page's own form that
 * typed a credential, outside the prompt, is marked with the prompt it
 * asks under (`system_layer:mark`, `{form, prompt}`), the mark held here
 * by form id, and every form so marked is cleared when that prompt ends
 * (`system_layer:clear`, `{prompt, form}`) or when the page reconnects,
 * since its waiting requests ended with the old page process. Keys typed
 * into a prompt stay in it: none drives the page behind it.
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
 * Its controls carry `data-test` names: `glass-status` (with
 * `data-state`), `glass-error`, `glass-replace-ask`, `glass-replace`,
 * `glass-keep`, `glass-prompt` (with `data-ref`), `glass-preview`,
 * `glass-asker`, `glass-passkey`, `glass-email`, `glass-code-form`,
 * `glass-code`, `glass-code-submit`, `glass-reauth-note`, `glass-cancel`
 * and `glass-outcome` (with `data-ok`).
 */

const FOCUSABLE = "a[href], button, input, select, textarea, [tabindex]"

export default {
  mounted() {
    if (this.el.dataset.webauthn === "sign-in") return this.mountSignIn()
    if (this.el.dataset.glass === "pair") return this.mountGlass()

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
    this.dialog = this.el.querySelector("dialog")
    this.sync()
  },

  destroyed() {
    if (this.onSignIn) {
      this.el.removeEventListener("click", this.onSignIn)
      return
    }

    if (this.glass) return this.destroyGlass()

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

    // A change confirmed: the form that typed it, which still holds what
    // was typed, is submitted again.
    this.handleEvent("system_layer:resubmit", ({form}) => resubmit(globalThis.document, form))

    // A page's form marked with the prompt it asks under, and emptied when
    // that prompt ends.
    this.marks = new Map()
    this.handleEvent("system_layer:mark", ({form, prompt}) => markForm(this.marks, form, prompt))
    this.handleEvent("system_layer:clear", ({prompt, form}) => clearMarked(globalThis.document, this.marks, prompt, form))
  },

  // A reconnect is a new page process: every request this page was waiting
  // on ended with the old one, so every form it typed for is emptied.
  reconnected() {
    clearAllMarked(globalThis.document, this.marks)
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
        clearForms(this.dialog)
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
    // The code is a bearer secret: it leaves the address at once.
    if (location && location.hash && globalThis.history) {
      globalThis.history.replaceState(null, "", location.pathname + location.search)
    }

    this.store = this.store || openStore()
    this.codeSent = new Set()
    const scheme = location && location.protocol === "https:" ? "wss:" : "ws:"
    this.glass = new Glass({
      url: `${scheme}//${location && location.host}/device/websocket`,
      socket: (url) => new globalThis.WebSocket(url),
      store: this.store,
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
      switch (openingPlan(code, stored)) {
        case "ask":
          // A device is paired here already: nothing changes until the
          // person chooses.
          this.pendingCode = code
          return this.drawGlass(this.glass)
        case "pair":
          return this.pairGlass(code).then(() => this.glass.start())
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
      await this.pairGlass(code)
    }
    return this.glass.start()
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

      const proof = await prove(started.challenge, privateKey)
      const paired = await this.pushAsync("pair_proof", {invitation_secret: code, device_key: deviceKey, proof})
      if (!paired || paired.error) return this.pairRefused((paired && paired.error) || "The pairing did not finish.")

      await this.store.save({privateKey, publicKey: deviceKey, clientId: paired.client_id, certificate: paired.certificate})
    } catch (_error) {
      this.pairRefused("This browser cannot hold a device key here.")
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
    if (!form || !form.dataset || !form.dataset.ref) return
    event.preventDefault()
    const code = form.elements && form.elements.code ? form.elements.code.value.trim() : ""
    if (code) this.glass.confirmWithCode(form.dataset.ref, code)
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
