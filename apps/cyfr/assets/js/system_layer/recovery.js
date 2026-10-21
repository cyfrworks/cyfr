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
 * The restore page's second form (`KitStep`) serves a home restored from a
 * backup, whose methods the restore suspended: the person types their
 * identifier and the kit's recovery secret, the page asks the kit ingress
 * for a challenge (`POST /restore/kit/challenge`), signs a kit proof over
 * it with the seed in this page (`kitProof`, `cyfr/restore-kit/v1`,
 * `tests/fixtures/restore_kit.json`) and trades the proof for a recovery
 * credential (`POST /restore/kit`). The seed leaves the form once the
 * proof is accepted; it is never sent. The credential, held in this page's
 * memory alone and sent only in the `authorization` header, lists each
 * class's suspended items and re-enables the one the person picks
 * (`POST /restore/kit/reenable`). Re-enabling a passkey or a paired device
 * ends the person's recovery, so the page forgets the credential and sends
 * them to sign in with it; clearing the form forgets the seed and the
 * credential too.
 *
 * None of this material is ever put in an address, in cookies, in local
 * or session storage, in IndexedDB, or in anything logged.
 */

import {b64url, fromB64url} from "./base64url.js"
import {jcs} from "./device_key.js"

export const SEED_BYTES = 32

/** How many times the restore page asks again while a restore stands at a phase. */
export const RESTORE_RETRIES = 30

// The longest wait between two asks, whatever an answer names.
const MAX_RETRY_S = 60

/** A new kit's seed: 32 bytes from the cryptographic random source, unpadded base64url. */
export function drawSeed(crypto = globalThis.crypto) {
  const bytes = new Uint8Array(SEED_BYTES)
  crypto.getRandomValues(bytes)
  return b64url(bytes)
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
 * element, and the kit step (`KitStep`) its `data-restore-kit` section
 * holds. `fetch`, the timers, `crypto` and the document are the page's
 * own unless a caller hands others.
 */
export class RestorePage {
  // The page's own `fetch` and timers are called as functions, never as
  // methods of this object, which a browser refuses ("Illegal invocation").
  constructor(el, {fetch = (url, init) => globalThis.fetch(url, init), setTimeout: later = (fn, ms) => globalThis.setTimeout(fn, ms), clearTimeout: cancel = (id) => globalThis.clearTimeout(id), crypto = globalThis.crypto, doc = el.ownerDocument || globalThis.document} = {}) {
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
    const kitEl = el.querySelector("[data-restore-kit]")
    this.kit = kitEl ? new KitStep(kitEl, {fetch, crypto, doc}) : null

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
    if (this.kit) this.kit.destroy()
    if (this.form) this.form.removeEventListener("submit", this.onSubmit)
    this.el.removeEventListener("click", this.onClick)
  }
}

// ---------------------------------------------------------------------------
// The kit step: recovering on a home restored from a backup
// ---------------------------------------------------------------------------

/** The kit proof's protocol (`Prima.Identity.RestoreKit`). */
export const KIT_PROTOCOL = "cyfr/restore-kit/v1"

/** The length of a kit challenge, in bytes. */
export const KIT_CHALLENGE_BYTES = 32

/** The re-enable operations the kit's credential admits, each with the argument naming its item. */
export const KIT_OPERATIONS = Object.freeze({
  "key.reenable": "key_id",
  "webhook.reenable": "webhook_id",
  "pairing.reenable": "client_id",
  "passkey.reenable": "passkey_id"
})

// Re-enabling one of these, a sign-in method, closes the person's recovery.
const KIT_METHODS = ["pairing.reenable", "passkey.reenable"]

const KIT_CLASSES = {
  "key.reenable": "API keys",
  "webhook.reenable": "Webhooks",
  "pairing.reenable": "Paired devices",
  "passkey.reenable": "Passkeys"
}

const IDENTIFIER = /^per_[0-9a-f]{64}$/

// PKCS #8 for an Ed25519 private key (RFC 8410), before its 32-byte seed.
const PKCS8_ED25519_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])

/**
 * The bytes unpadded base64url `text` spells when it spells exactly `size`
 * of them the one way the home reads (`Prima.Identity.Encoding.unb64/2`),
 * or null.
 */
export function exactBytes(text, size) {
  try {
    const bytes = fromB64url(text)
    return bytes.length === size && b64url(bytes) === text ? bytes : null
  } catch (_error) {
    return null
  }
}

/** The fields a kit proof signs, in the shape the home reads. */
export function kitFields({restoreId, identifier, challenge}) {
  return {protocol: KIT_PROTOCOL, restore_id: restoreId, identifier, challenge}
}

/** The JCS bytes a kit proof's `sig` covers: every field but `sig`. */
export function kitSignedBytes(fields) {
  const {sig: _sig, ...signed} = fields
  return new TextEncoder().encode(jcs(signed))
}

/**
 * The signed kit proof for the home's challenge: the Ed25519 signature by
 * the kit's seed (32 bytes, unpadded base64url) over the JCS bytes of
 * `{protocol, restore_id, identifier, challenge}`. The seed becomes a
 * private key that cannot be exported, and the bytes it was imported from
 * are overwritten once it is. A seed or challenge that is not exactly 32
 * bytes rejects.
 */
export async function kitProof({seed, restoreId, identifier, challenge}, crypto = globalThis.crypto) {
  const seedBytes = exactBytes(seed, 32)
  if (!seedBytes) throw new TypeError("not a recovery secret")
  if (!exactBytes(challenge, KIT_CHALLENGE_BYTES)) throw new TypeError("not a kit challenge")

  const pkcs8 = new Uint8Array(PKCS8_ED25519_PREFIX.length + seedBytes.length)
  pkcs8.set(PKCS8_ED25519_PREFIX)
  pkcs8.set(seedBytes, PKCS8_ED25519_PREFIX.length)
  let key
  try {
    key = await crypto.subtle.importKey("pkcs8", pkcs8, {name: "Ed25519"}, false, ["sign"])
  } finally {
    pkcs8.fill(0)
    seedBytes.fill(0)
  }

  const fields = kitFields({restoreId, identifier, challenge})
  const sig = await crypto.subtle.sign({name: "Ed25519"}, key, kitSignedBytes(fields))
  return {...fields, sig: b64url(sig)}
}

/**
 * The request the kit step makes to `path` (`/restore/kit/challenge`,
 * `/restore/kit` or `/restore/kit/reenable`): the body as JSON, the
 * recovery credential, once held, as a bearer authorization, on this
 * origin and kept in no cache.
 */
export function kitRequest(path, body, credential = null) {
  const headers = {"content-type": "application/json", accept: "application/json"}
  if (credential) headers.authorization = `Bearer ${credential}`
  return {
    url: path,
    init: {method: "POST", credentials: "same-origin", cache: "no-store", redirect: "error", headers, body: JSON.stringify(body)}
  }
}

/** The body that lists `operation`'s suspended items, or re-enables the one `id` names. */
export function reenableBody(operation, id = null) {
  const argument = KIT_OPERATIONS[operation]
  if (!argument) throw new TypeError("not a re-enable operation")
  return id === null || id === undefined ? {operation} : {operation, [argument]: id}
}

/** Whether re-enabling through `operation` ends the person's recovery: a passkey or a paired device. */
export const endsRecovery = (operation) => KIT_METHODS.includes(operation)

/** The words an item of `operation`'s class is shown with. */
export function kitItemText(operation, item) {
  const named = (item && (item.name || item.label)) || (item && item.id) || ""
  if (operation === "key.reenable" && item && item.prefix) return `${named} (${item.prefix}…)`
  if (operation === "passkey.reenable" && item && item.rp_id) return `${named} (${item.rp_id})`
  return named
}

const ENDED = "This recovery has ended: it lasts ten minutes and ends once a passkey or device is re-enabled. Recover again from your kit, or sign in with the method you re-enabled."

const KIT_REFUSALS = {
  not_recovering: "This home holds no open recovery for that identifier: it was not restored from a backup with you enrolled, or your recovery has ended. Sign in with a method you re-enabled, or ask this home's administrator.",
  invalid_proof: "That recovery secret did not make a proof this home reads. Check the kit's recovery secret.",
  challenge_refused: "The challenge expired or was used. Recover again.",
  not_a_holder: "That recovery secret is not one of this identity's kits now.",
  invalid_credential: ENDED,
  not_standing: ENDED,
  operation_not_permitted: "Your recovery covers re-enabling what the restore suspended, and nothing else.",
  not_found: "That item is no longer on this home.",
  revoked: "That item was revoked, and a revoked item is never re-enabled.",
  not_suspended: "That item is active already.",
  directory_unavailable: "Your identity's directory could not be reached. Try again shortly."
}

/**
 * The sentence an answer of the kit ingress that is not a success shows,
 * and whether it ends what the page holds (`ended`: the credential no
 * longer stands).
 */
export function kitRefusal(status, body) {
  const answer = body && typeof body === "object" ? body : {}
  const ended = status === 401 || answer.error === "invalid_credential" || answer.error === "not_standing"
  if (KIT_REFUSALS[answer.error]) return {text: KIT_REFUSALS[answer.error], ended}
  if (status === 429) return {text: "Too many tries from here. Try again in a minute.", ended}
  if (status === 503) return {text: KIT_REFUSALS.directory_unavailable, ended}
  if (typeof answer.message === "string" && answer.message) return {text: answer.message, ended}
  return {text: "The recovery did not go through. Try again shortly.", ended}
}

/**
 * The kit step of the restore page (`data-restore-kit`): its form of two
 * unnamed inputs, the list of suspended items it draws, and the status it
 * says each answer in.
 */
export class KitStep {
  constructor(el, {fetch = (url, init) => globalThis.fetch(url, init), crypto = globalThis.crypto, doc = el.ownerDocument || globalThis.document} = {}) {
    this.el = el
    this.fetch = fetch
    this.crypto = crypto
    this.doc = doc
    this.credential = null
    this.run = null
    this.items = {}
    this.form = el.querySelector("[data-restore-kit-form]")
    this.list = el.querySelector("[data-restore-kit-items]")
    this.status = el.querySelector('[data-test="restore-kit-status"]')

    this.onSubmit = (event) => {
      event.preventDefault()
      this.begin()
    }
    this.onClick = (event) => {
      const target = event.target && event.target.closest ? event.target.closest("[data-restore-kit-clear], [data-restore-kit-reenable]") : null
      if (!target) return
      event.preventDefault()
      if (target.hasAttribute("data-restore-kit-clear")) this.clear("idle", "")
      else this.reenable(target.getAttribute("data-operation"), target.getAttribute("data-id"))
    }
    if (this.form) this.form.addEventListener("submit", this.onSubmit)
    el.addEventListener("click", this.onClick)
  }

  // The identifier and the seed, read from the form at the moment of
  // asking, or a sentence saying what is missing.
  read() {
    const identifier = fieldValue(this.form, "identifier")
    const seed = fieldValue(this.form, "recovery_secret")
    if (!identifier || !seed) return {refused: "Type your identifier and your kit's recovery secret."}
    if (!IDENTIFIER.test(identifier)) return {refused: "That identifier is not one: it is per_ and 64 hexadecimal digits, the kit's first line."}
    if (!exactBytes(seed, 32)) return {refused: "That recovery secret is not one: it is the kit's third line, 43 characters."}
    return {identifier, seed}
  }

  // Challenge, proof, credential, then the suspended items. A clear or a
  // newer start while an answer is awaited drops that answer.
  async begin() {
    const values = this.read()
    if (values.refused) return this.show("refused", values.refused)
    const run = this.start()
    this.show("working", "Proving your kit to this home…")

    const challenge = await this.post(kitRequest("/restore/kit/challenge", {identifier: values.identifier}))
    if (this.run !== run) return
    if (challenge.status !== 200 || !challenge.body || typeof challenge.body.challenge !== "string") return this.refuse(challenge)
    if (typeof challenge.body.restore_id !== "string" || !exactBytes(challenge.body.challenge, KIT_CHALLENGE_BYTES)) {
      return this.show("refused", "This home's answer was not a kit challenge. Try again shortly.")
    }

    let proof
    try {
      proof = await kitProof({seed: values.seed, restoreId: challenge.body.restore_id, identifier: values.identifier, challenge: challenge.body.challenge}, this.crypto)
    } catch (_error) {
      if (this.run !== run) return
      return this.show("refused", "This browser could not sign with the kit. Use a current browser.")
    }
    values.seed = null
    if (this.run !== run) return

    const granted = await this.post(kitRequest("/restore/kit", {proof}))
    if (this.run !== run) return
    if (granted.status !== 200 || !granted.body || typeof granted.body.credential !== "string") return this.refuse(granted)

    // The seed's work is done: it leaves the form, and only the credential
    // is held from here.
    this.credential = granted.body.credential
    clearSecret(this.form)
    return this.load(run)
  }

  // Each class's suspended items, under the held credential.
  async load(run) {
    const items = {}
    for (const operation of Object.keys(KIT_OPERATIONS)) {
      const answer = await this.post(kitRequest("/restore/kit/reenable", reenableBody(operation), this.credential))
      if (this.run !== run) return
      if (answer.status !== 200 || !answer.body || !Array.isArray(answer.body.items)) return this.refuse(answer)
      items[operation] = answer.body.items
    }
    this.items = items
    this.draw()
    const none = Object.values(items).every((list) => list.length === 0)
    return this.show("listed", none ? "Nothing of yours is suspended on this home." : "Re-enable what is yours. Re-enabling a passkey or a device ends this recovery: then sign in with it.")
  }

  async reenable(operation, id) {
    if (!this.credential || !KIT_OPERATIONS[operation] || !id) return
    const run = this.run
    this.show("working", "Re-enabling…")
    const answer = await this.post(kitRequest("/restore/kit/reenable", reenableBody(operation, id), this.credential))
    if (this.run !== run) return
    if (answer.status !== 200 || !answer.body || !answer.body.reenabled) return this.refuse(answer)

    const item = (this.items[operation] || []).find((entry) => entry.id === id)
    const text = kitItemText(operation, item || {id})
    if (endsRecovery(operation)) {
      return this.clear("done", `${text} is active again, and your recovery has ended. Sign in with it now.`)
    }
    this.items[operation] = (this.items[operation] || []).filter((entry) => entry.id !== id)
    this.draw()
    return this.show("reenabled", `${text} is active again.`)
  }

  // The answer read as JSON; a body that is not JSON reads as none, and a
  // network that failed as a refusal the person can try again from.
  async post({url, init}) {
    try {
      const response = await this.fetch(url, init)
      let body = null
      try {
        body = await response.json()
      } catch (_error) {
        body = null
      }
      return {status: response.status, body}
    } catch (_error) {
      return {status: 0, body: {message: "This home could not be reached. Try again shortly."}}
    }
  }

  // A refusal is said; one that ends the credential forgets it and the
  // list. The form keeps what is still typed, so a mistyped line can be
  // mended.
  refuse({status, body}) {
    const {text, ended} = kitRefusal(status, body)
    if (ended) return this.clear("refused", text)
    return this.show("refused", text)
  }

  start() {
    this.credential = null
    this.items = {}
    this.draw()
    this.run = {}
    return this.run
  }

  // The suspended items, each as text with a button that re-enables it.
  draw() {
    if (!this.list || typeof this.list.replaceChildren !== "function") return
    const sections = []
    for (const operation of Object.keys(KIT_OPERATIONS)) {
      const items = this.items[operation] || []
      if (items.length === 0) continue
      const section = this.doc.createElement("section")
      const heading = this.doc.createElement("h3")
      heading.textContent = KIT_CLASSES[operation]
      heading.setAttribute("class", "text-sm font-semibold")
      const list = this.doc.createElement("ul")
      list.setAttribute("class", "space-y-1")
      for (const item of items) {
        const row = this.doc.createElement("li")
        row.setAttribute("class", "flex items-center justify-between gap-2 text-sm")
        const name = this.doc.createElement("span")
        name.textContent = kitItemText(operation, item)
        const button = this.doc.createElement("button")
        button.setAttribute("type", "button")
        button.setAttribute("data-restore-kit-reenable", "")
        button.setAttribute("data-test", "restore-kit-reenable")
        button.setAttribute("data-operation", operation)
        button.setAttribute("data-id", String(item.id))
        button.setAttribute("class", "rounded-md border border-gray-600 px-2 py-1 text-xs font-semibold hover:bg-gray-800")
        button.textContent = "Re-enable"
        row.append(name, button)
        list.append(row)
      }
      section.append(heading, list)
      sections.push(section)
    }
    this.list.replaceChildren(...sections)
    this.list.hidden = sections.length === 0
  }

  show(state, text) {
    if (!this.status) return
    this.status.setAttribute("data-state", state)
    this.status.textContent = text
  }

  // The seed and the credential leave this page: the form's inputs, the
  // held credential, the drawn list and any answer still awaited.
  clear(state, text) {
    this.run = null
    this.credential = null
    this.items = {}
    clearFields(this.form)
    this.draw()
    this.show(state, text)
  }

  destroy() {
    this.clear("idle", "")
    if (this.form) this.form.removeEventListener("submit", this.onSubmit)
    this.el.removeEventListener("click", this.onClick)
  }
}

// Empty the form's recovery secret alone.
function clearSecret(form) {
  const input = form && typeof form.querySelector === "function" ? form.querySelector('[data-field="recovery_secret"]') : null
  if (input) input.value = ""
}
