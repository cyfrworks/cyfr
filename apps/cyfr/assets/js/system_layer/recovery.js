// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * Recovery material in the browser: the system layer's recovery prompts
 * (`PrismWeb.SystemLayer.Recovery`) and the restore page
 * (`PrismWeb.RestoreLive`).
 *
 * In a recovery prompt, the seed of a new kit is drawn here, 32 bytes from
 * the browser's cryptographic random source, with the request id its
 * attempt goes under, and held in this page's memory for that one pending
 * request (`Material`): submitted to the layer under `recovery_secret`,
 * submitted again, the same, when the layer says its record was confirmed
 * or the person tries again, and forgotten once a kit answers or the
 * prompt ends. An added kit is signed by a kit the person holds: its
 * secret is typed into the prompt's form and held the same way. A kit's
 * three lines arrive in a push to this layer alone and are drawn into the
 * prompt's own place as text, then emptied when the prompt ends.
 *
 * On the restore page, the installation token and the kit's three lines
 * are typed into a form whose inputs have no name, and posted straight to
 * this origin's restore ingress (`POST /restore`): the token in the
 * `authorization` header, the kit in the JSON body. While the restore
 * stands at a phase it resumes from, the page asks again under the same
 * token after the time the answer names; it clears the token and the kit
 * once the restore completes or the person clears the form.
 *
 * None of this material is ever put in an address, in cookies, in local
 * or session storage, in IndexedDB, or in anything logged.
 */

import {bytesToB64url} from "./webauthn.js"

export const SEED_BYTES = 32

/** How many times the restore page asks again while a restore stands at a phase. */
export const RESTORE_RETRIES = 30

// The longest wait between two asks, whatever an answer names.
const MAX_RETRY_S = 60

/** A new kit's seed: 32 bytes from the cryptographic random source, unpadded base64url. */
export function drawSeed(crypto = globalThis.crypto) {
  const bytes = new Uint8Array(SEED_BYTES)
  crypto.getRandomValues(bytes)
  return bytesToB64url(bytes)
}

/** A request id for a new attempt: `req_` and 32 hexadecimal digits. */
export function drawRequestId(crypto = globalThis.crypto) {
  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)
  return "req_" + Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

/**
 * The material each open recovery prompt holds, by prompt id, in memory
 * alone. `submission` answers what the prompt's form submits: material it
 * already holds is reused, so a retry or the confirmed repeat is the same
 * request, and otherwise it is drawn (and, for an added kit, typed).
 */
export class Material {
  constructor(crypto = globalThis.crypto) {
    this.crypto = crypto
    this.held = new Map()
  }

  /**
   * The event payload for `kind` (`enrollment`, `holder` or `kit`) of the
   * prompt `promptId`, `typed` the signing kit's secret an added kit
   * needs; or null when an added kit has none to sign with.
   */
  submission(promptId, kind, typed = "") {
    switch (kind) {
      case "enrollment": {
        const held = this.hold(promptId, () => ({seed: drawSeed(this.crypto), requestId: drawRequestId(this.crypto)}))
        return {prompt_id: promptId, recovery_secret: held.seed, request_id: held.requestId}
      }
      case "holder": {
        const signer = (this.held.get(promptId)?.signer) || (typeof typed === "string" ? typed.trim() : "")
        if (!signer) return null
        const held = this.hold(promptId, () => ({seed: drawSeed(this.crypto), requestId: drawRequestId(this.crypto), signer}))
        return {
          prompt_id: promptId,
          recovery_secret: held.signer,
          holder: {kind: "kit", recovery_secret: held.seed},
          request_id: held.requestId
        }
      }
      case "kit":
        return {prompt_id: promptId}
      default:
        return null
    }
  }

  hold(promptId, draw) {
    if (!this.held.has(promptId)) this.held.set(promptId, draw())
    return this.held.get(promptId)
  }

  holds(promptId) {
    return this.held.has(promptId)
  }

  forget(promptId) {
    this.held.delete(promptId)
  }

  forgetAll() {
    this.held.clear()
  }
}

/** A kit's three lines, as the prompt draws them: label, value and test name. */
export function kitRows(kit) {
  return [
    ["Identifier", kit.identifier, "kit-identifier"],
    ["Directory", kit.directory_url, "kit-directory"],
    ["Recovery secret", kit.recovery_secret, "kit-secret"]
  ]
}

/** Draw `kit` into `slot`, each value as text, and show it. */
export function drawKit(doc, slot, kit) {
  if (!slot || typeof slot.replaceChildren !== "function" || !kit) return
  const rows = kitRows(kit).map(([label, value, test]) => {
    const row = doc.createElement("div")
    const name = doc.createElement("dt")
    name.textContent = label
    const text = doc.createElement("dd")
    text.textContent = value
    text.setAttribute("data-test", test)
    text.setAttribute("class", "font-mono break-all")
    row.append(name, text)
    return row
  })
  const list = doc.createElement("dl")
  list.setAttribute("class", "space-y-1 rounded-md border border-gray-600 p-3 text-sm")
  list.append(...rows)
  slot.replaceChildren(list)
  slot.hidden = false
}

/** Empty `slot` of whatever kit it showed. */
export function clearKit(slot) {
  if (!slot || typeof slot.replaceChildren !== "function") return
  slot.replaceChildren()
  slot.hidden = true
}

/** The value a form's input named by `data-field` holds, trimmed. */
export function fieldValue(form, field) {
  const input = form && typeof form.querySelector === "function" ? form.querySelector(`[data-field="${field}"]`) : null
  return input && typeof input.value === "string" ? input.value.trim() : ""
}

/** Empty every input of `form` that names a field. */
export function clearFields(form) {
  if (!form || typeof form.querySelectorAll !== "function") return
  for (const input of form.querySelectorAll("[data-field]")) input.value = ""
}

// ---------------------------------------------------------------------------
// The restore page
// ---------------------------------------------------------------------------

/**
 * The request the restore page makes to `path` (`/restore`,
 * `/restore/challenge` or `/restore/reproof`): the token as a bearer
 * authorization, the body as JSON, on this origin with its cookies, and
 * kept in no cache.
 */
export function restoreRequest(path, token, body = {}) {
  return {
    url: path,
    init: {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
      redirect: "error",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        accept: "application/json"
      },
      body: JSON.stringify(body)
    }
  }
}

const REFUSALS = {
  restore_disabled: "This installation is not set up for a restore. Its operator sets CYFR_RESTORE_TOKEN first.",
  invalid_token: "That installation token is not this installation's. Nothing was sent on.",
  invalid_kit: "Those lines are not a kit. Check the identifier, the directory and the recovery secret.",
  unknown_identity: "The kit's directory knows no such identity.",
  not_a_holder: "That recovery secret is not one of this identity's kits now.",
  token_claimed: "Another restore holds this installation, or this token's restore is another kit's.",
  token_spent: "This token was spent by an ended restore. The operator sets a new one to start again.",
  not_empty: "This installation already holds a person: a restore runs only on an empty one.",
  superseded: "A later recovery replaced the keys this restore introduced, so nothing was activated. Restore again from your kit, under a new token.",
  refused: "The directory refused this recovery. Nothing was activated.",
  not_restored: "No restore has completed under this token.",
  closed: "A first sign-in method exists already: sign in with it.",
  challenge_refused: "The challenge expired or was used. Prove the kit again."
}

/**
 * What an answer of the restore ingress means for the page: `state`
 * (`completed`, `retry`, `restored` or `refused`), the sentence it shows,
 * and for `retry` the seconds before the page asks again.
 */
export function restoreOutcome(status, body) {
  const answer = body && typeof body === "object" ? body : {}
  if (status === 200 && answer.status === "completed") {
    return {state: "completed", text: "Restored. Your identity is back on this installation; register a passkey on your home's settings page to sign in again."}
  }
  if (status === 503 && typeof answer.status === "string") {
    const seconds = Math.min(Math.max(Number(answer.retry_after) || 1, 1), MAX_RETRY_S)
    return {state: "retry", retryAfter: seconds, text: `The restore stands at ${answer.status}; it resumes in ${seconds} s.`}
  }
  if (answer.error === "restored") {
    return {state: "restored", text: "This installation was restored already. If no passkey was registered in time, prove the kit again to sign in."}
  }
  if (status === 429) return {state: "retry", retryAfter: 60, text: "Too many tries from here; it asks again in a minute."}
  const text = REFUSALS[answer.error] || "The restore did not go through. Try again shortly."
  return {state: "refused", text}
}

/**
 * The restore page's form (`data-restore="page"`), driven from its own
 * element. `fetch` and the timers are the page's own unless a caller
 * hands others.
 */
export class RestorePage {
  // The page's own `fetch` and timers are called as functions, never as
  // methods of this object, which a browser refuses ("Illegal invocation").
  constructor(el, {fetch = (url, init) => globalThis.fetch(url, init), setTimeout: later = (fn, ms) => globalThis.setTimeout(fn, ms), clearTimeout: cancel = (id) => globalThis.clearTimeout(id)} = {}) {
    this.el = el
    this.fetch = fetch
    this.later = later
    this.cancel = cancel
    this.pending = null
    this.timer = null
    this.tries = 0
    this.form = el.querySelector("[data-restore-form]")
    this.status = el.querySelector('[data-test="restore-status"]')
    this.reproofButton = el.querySelector("[data-restore-reproof]")
    this.continueLink = el.querySelector("[data-restore-continue]")

    this.onSubmit = (event) => {
      event.preventDefault()
      this.begin()
    }
    this.onClick = (event) => {
      const target = event.target && event.target.closest ? event.target.closest("[data-restore-clear], [data-restore-reproof]") : null
      if (!target) return
      event.preventDefault()
      if (target.hasAttribute("data-restore-clear")) this.clear("idle", "")
      else this.reproof()
    }
    if (this.form) this.form.addEventListener("submit", this.onSubmit)
    el.addEventListener("click", this.onClick)
  }

  // The four values, read from the form at the moment of asking, or null
  // when one is missing.
  read() {
    const token = fieldValue(this.form, "token")
    const kit = {
      identifier: fieldValue(this.form, "identifier"),
      directory_url: fieldValue(this.form, "directory_url"),
      recovery_secret: fieldValue(this.form, "recovery_secret")
    }
    return token && kit.identifier && kit.directory_url && kit.recovery_secret ? {token, kit} : null
  }

  begin() {
    const values = this.read()
    if (!values) return this.show("refused", "Type the installation token and all three lines of the kit.")
    this.stopTimer()
    this.tries = 0
    this.pending = values
    return this.ask()
  }

  // One ask of the ingress under the held values; a retryable answer asks
  // again after its time, under the same token, until the tries run out.
  async ask() {
    const values = this.pending
    if (!values) return
    const {url, init} = restoreRequest("/restore", values.token, values.kit)
    const outcome = await this.post(url, init)
    if (this.pending !== values) return
    this.settle(outcome)
  }

  async reproof() {
    const values = this.read()
    if (!values) return this.show("refused", "Type the installation token and all three lines of the kit.")
    this.stopTimer()
    this.tries = 0
    this.pending = values
    const asked = restoreRequest("/restore/challenge", values.token)
    const challenge = await this.post(asked.url, asked.init, true)
    if (this.pending !== values) return
    if (!challenge.body || typeof challenge.body.challenge !== "string") return this.settle(challenge)
    const proof = restoreRequest("/restore/reproof", values.token, {...values.kit, challenge: challenge.body.challenge})
    const outcome = await this.post(proof.url, proof.init)
    if (this.pending !== values) return
    this.settle(outcome)
  }

  // The answer read as JSON; a body that is not JSON, or a network that
  // failed, reads as a refusal the person can try again from.
  async post(url, init, raw = false) {
    try {
      const response = await this.fetch(url, init)
      let body = null
      try {
        body = await response.json()
      } catch (_error) {
        body = null
      }
      return raw ? {status: response.status, body, ...restoreOutcome(response.status, body)} : restoreOutcome(response.status, body)
    } catch (_error) {
      return {state: "refused", text: "This installation could not be reached. Try again shortly."}
    }
  }

  settle(outcome) {
    switch (outcome.state) {
      case "completed":
        this.clear("completed", outcome.text)
        if (this.continueLink) this.continueLink.hidden = false
        return
      case "retry":
        this.tries += 1
        if (this.tries > RESTORE_RETRIES) {
          this.pending = null
          return this.show("refused", "The restore has not finished yet. It resumes when you restore again under the same token.")
        }
        this.show("retry", outcome.text)
        this.timer = this.later(() => {
          this.timer = null
          return this.ask()
        }, outcome.retryAfter * 1000)
        return
      case "restored":
        // The form keeps what was typed, for the reproof; nothing else holds it.
        this.pending = null
        if (this.reproofButton) this.reproofButton.hidden = false
        return this.show("restored", outcome.text)
      default:
        // The form keeps what was typed, so a mistyped line can be mended;
        // nothing else holds it, and nothing asks again.
        this.pending = null
        return this.show("refused", outcome.text)
    }
  }

  show(state, text) {
    if (!this.status) return
    this.status.setAttribute("data-state", state)
    this.status.textContent = text
  }

  stopTimer() {
    if (this.timer !== null) this.cancel(this.timer)
    this.timer = null
  }

  // The token and the kit leave this page: the held values, the form's
  // inputs, and any ask still to come.
  clear(state, text) {
    this.stopTimer()
    this.pending = null
    clearFields(this.form)
    if (this.reproofButton) this.reproofButton.hidden = true
    this.show(state, text)
  }

  destroy() {
    this.clear("idle", "")
    if (this.form) this.form.removeEventListener("submit", this.onSubmit)
    this.el.removeEventListener("click", this.onClick)
  }
}
