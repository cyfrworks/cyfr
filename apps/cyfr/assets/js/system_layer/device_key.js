// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * The glass's half of the device protocol (`Prima.Device`,
 * `cyfr-device/v1`, `tests/fixtures/device.json`): its key pair, the proof
 * of possession it answers a challenge with (`Prima.DeviceCert.Proof`,
 * `tests/fixtures/device_cert.json`), the messages it sends and reads, and
 * the connection it keeps to its home's device channel.
 *
 * The key pair is Ed25519 through WebCrypto, made with a private key that
 * cannot be exported, and kept across page reloads in the browser's
 * IndexedDB, where a `CryptoKey` keeps that property. A proof is the
 * device key's signature over the JCS bytes of the challenge the home
 * held for the connection, every field but `sig`.
 *
 * The connection (`Glass`) sends `connect` under the certificate it
 * holds, or `renew` when that certificate has expired by this device's
 * clock, answers each challenge with a proof, and is ready only once the
 * home answers `standing`: no intent leaves before that, on a first
 * connection, on a reconnect or after waking, so a certificate that
 * expired while the device slept is replaced and validated before any
 * work. A ready connection renews at half the certificate's life, opens
 * the `confirmation.changes` stream, reads `confirmation.pending` again on
 * each of its facts, and opens the stream again when a grant ends. A
 * close `4408` reconnects through the renewal; a close `4403`, or a
 * `revoke` naming no grant, means the pairing ended: the stored key and
 * certificate are erased.
 */

export const PROTOCOL = "cyfr-device/v1"
export const CONFIRMATIONS = "confirmation.changes"
// How long the glass waits before opening the stream again after an open
// was refused.
export const LISTEN_RETRY_MS = 5_000

export const GLASS_TYPES = ["capabilities", "connect", "intent", "pair_request", "proof", "renew"]
export const HOME_TYPES = [
  "answer",
  "certificate",
  "challenge",
  "event",
  "grant",
  "pair_answer",
  "revoke",
  "standing"
]
export const CONTINUOUS_FIELDS = ["stream", "frames", "chunks", "samples", "continuous"]

// Each home message's fields: required, then optional.
const HOME_FIELDS = {
  pair_answer: [["client_id", "certificate"], []],
  challenge: [["challenge"], []],
  standing: [["client_id", "athanor", "expires_at"], []],
  certificate: [["certificate"], []],
  answer: [["id"], ["result", "error"]],
  grant: [["grant_id", "stream", "projection", "expires_at"], ["subject"]],
  event: [["grant_id", "payload"], []],
  revoke: [["client_id"], ["grant_id"]]
}

const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/

// ---------------------------------------------------------------------------
// Encodings
// ---------------------------------------------------------------------------

/** Unpadded base64url of `bytes` (an ArrayBuffer or a view of one). */
export function b64url(bytes) {
  const view = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let binary = ""
  for (const byte of view) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** The bytes unpadded base64url `text` spells. */
export function fromB64url(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]*$/.test(text)) throw new TypeError("not base64url")
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/")
  const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

/**
 * The JCS (RFC 8785) text of a JSON value: object members sorted by their
 * names' UTF-16 code units, no whitespace, numbers and strings as
 * ECMAScript writes them. Integers are all a challenge carries.
 */
export function jcs(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") return JSON.stringify(value)
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("not a JSON number")
    return JSON.stringify(value)
  }
  if (Array.isArray(value)) return "[" + value.map(jcs).join(",") + "]"
  if (typeof value === "object") {
    const names = Object.keys(value).filter((name) => value[name] !== undefined).sort()
    return "{" + names.map((name) => JSON.stringify(name) + ":" + jcs(value[name])).join(",") + "}"
  }
  throw new TypeError("not a JSON value")
}

// ---------------------------------------------------------------------------
// The key pair and the proof
// ---------------------------------------------------------------------------

const ED25519 = {name: "Ed25519"}

/** A new device key pair whose private key cannot be exported. */
export async function generateKeyPair(subtle = globalThis.crypto.subtle) {
  return subtle.generateKey(ED25519, false, ["sign", "verify"])
}

/** The device public key as the home reads it: 32 raw bytes, base64url. */
export async function publicKeyB64(publicKey, subtle = globalThis.crypto.subtle) {
  return b64url(await subtle.exportKey("raw", publicKey))
}

/** The challenge's fields as a proof signs them: everything but `sig`. */
export function signedBytes(challenge) {
  const {sig: _sig, ...fields} = challenge
  return new TextEncoder().encode(jcs(fields))
}

/**
 * The proof of possession answering `challenge` (the JSON map the home
 * sent): the challenge's fields and the device key's signature over them.
 */
export async function prove(challenge, privateKey, subtle = globalThis.crypto.subtle) {
  const {sig: _sig, ...fields} = challenge
  const sig = await subtle.sign(ED25519, privateKey, signedBytes(fields))
  return {...fields, sig: b64url(sig)}
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

function message(type, fields) {
  const out = {protocol: PROTOCOL, type}
  for (const [name, value] of Object.entries(fields)) if (value !== undefined && value !== null) out[name] = value
  return out
}

export const connectMessage = (clientId, certificate) => message("connect", {client_id: clientId, certificate})
export const renewMessage = (clientId, certificate) => message("renew", {client_id: clientId, certificate})
export const proofMessage = (proof) => message("proof", {proof})
export const capabilitiesMessage = (capabilities) => message("capabilities", {capabilities})

export const pairRequestMessage = (invitationSecret, deviceKey) =>
  message("pair_request", {invitation_secret: invitationSecret, device_key: deviceKey})

/**
 * One discrete operation. An intent never carries continuous data, so
 * `args` holding a field that marks it as such is refused here, before it
 * is sent, as the home would refuse it by its shape.
 */
export function intentMessage(id, operation, args, confirmationId) {
  if (!ID.test(id)) throw new TypeError("an intent's id is an identifier")
  if (!/^[a-z][a-z0-9_-]{0,62}\.[a-z][a-z0-9_-]{0,62}$/.test(operation)) throw new TypeError("an intent names tool.action")
  if (args === null || typeof args !== "object" || Array.isArray(args)) throw new TypeError("an intent's args are an object")
  return message("intent", {id, operation, args, confirmation_id: confirmationId})
}

/**
 * A message the home sent, read: `{type, body}`, or `{error}` naming why
 * it is not one: another protocol, a type the home does not send, or a
 * field its type does not carry.
 */
export function decodeHome(map) {
  if (map === null || typeof map !== "object" || Array.isArray(map)) return {error: "invalid_field"}
  if (!("protocol" in map) || !("type" in map)) return {error: "missing_field"}
  if (map.protocol !== PROTOCOL) return {error: "wrong_protocol"}
  if (GLASS_TYPES.includes(map.type)) return {error: "wrong_sender"}
  const fields = HOME_FIELDS[map.type]
  if (!fields) return {error: "unknown_type"}

  const [required, optional] = fields
  for (const name of Object.keys(map)) {
    if (name !== "protocol" && name !== "type" && !required.includes(name) && !optional.includes(name)) return {error: "unknown_field"}
  }
  for (const name of required) if (!(name in map)) return {error: "missing_field"}
  if (map.type === "answer" && ("result" in map) === ("error" in map)) return {error: "invalid_field"}
  if (map.type === "grant" && map.subject === "*") return {error: "invalid_field"}

  const {protocol: _protocol, type, ...body} = map
  return {type, body}
}

// ---------------------------------------------------------------------------
// Certificates and the pairing code
// ---------------------------------------------------------------------------

/** Whether `certificate` has expired at `now` (Unix ms): strict, as the home holds it. */
export const expired = (certificate, now) => now >= certificate.expires_at

/** When to renew `certificate`: half its life. */
export const renewAt = (certificate) => certificate.not_before + Math.floor((certificate.expires_at - certificate.not_before) / 2)

/**
 * What the glass does as its page opens: `pair` under a code it holds no
 * device for, `ask` before a code replaces a device it holds, `connect`
 * the device it holds, or stay `unpaired`.
 */
export function openingPlan(code, stored) {
  const paired = Boolean(stored && stored.certificate)
  if (code) return paired ? "ask" : "pair"
  return paired ? "connect" : "unpaired"
}

/** The invitation's secret a pairing link carries in its fragment's `code`, or null. */
export function codeFromFragment(hash) {
  const fragment = (hash || "").replace(/^#/, "")
  const code = new URLSearchParams(fragment).get("code")
  return code && /^[A-Za-z0-9_-]{22}$/.test(code) ? code : null
}

// ---------------------------------------------------------------------------
// The stored key and certificate
// ---------------------------------------------------------------------------

/**
 * The glass's store in IndexedDB: one record, the key pair (the private
 * key unexportable), the public key's encoding, the client id and the
 * certificate. `load` answers it or null.
 */
export function openStore(indexedDB = globalThis.indexedDB, name = "cyfr-glass") {
  const open = () =>
    new Promise((resolve, reject) => {
      const request = indexedDB.open(name, 1)
      request.onupgradeneeded = () => request.result.createObjectStore("glass")
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })

  const run = (mode, act) =>
    open().then(
      (db) =>
        new Promise((resolve, reject) => {
          const tx = db.transaction("glass", mode)
          const request = act(tx.objectStore("glass"))
          tx.oncomplete = () => resolve(request && request.result)
          tx.onerror = () => reject(tx.error)
        })
    )

  return {
    load: () => run("readonly", (store) => store.get("device")).then((value) => value || null),
    save: (record) => run("readwrite", (store) => store.put(record, "device")).then(() => record),
    clear: () => run("readwrite", (store) => store.delete("device")).then(() => null)
  }
}

/** A store in memory, with the same three calls. */
export function memoryStore(record = null) {
  let held = record
  return {
    load: async () => held,
    save: async (next) => (held = next),
    clear: async () => (held = null)
  }
}

// ---------------------------------------------------------------------------
// A pending confirmation as the glass shows it
// ---------------------------------------------------------------------------

/**
 * What the glass draws for one `confirmation.pending` entry: the home's
 * preview and the client that asked, and the proofs it can carry out
 * here. A fresh sign-in needs a signed-in browser, which a glass is not,
 * so it is never offered; it is named instead.
 */
export function promptModel(entry, {webauthn = true} = {}) {
  const preview = entry.preview || {}
  const rows = [["Change", preview.operation || entry.operation]]
  if (preview.resource) rows.push(["Concerning", preview.resource])
  if (preview.athanor) rows.push(["In", `${preview.athanor} at ${preview.home}`])
  for (const name of Object.keys(preview.details || {}).sort()) {
    const value = preview.details[name]
    rows.push([name, Array.isArray(value) ? value.join(", ") : value])
  }

  const methods = entry.methods || []
  const offers = []
  if (methods.includes("passkey") && webauthn && entry.webauthn) offers.push("passkey")
  if (methods.includes("email")) offers.push("email")

  return {
    ref: entry.ref,
    operation: entry.operation,
    rows,
    asker: askerName(entry.asker),
    offers,
    signInElsewhere: methods.includes("oidc")
  }
}

/** The client that asked, as the home named it. */
export function askerName(asker) {
  const named = asker && asker.name ? ` named ${asker.name}` : ""
  switch (asker && asker.kind) {
    case "client":
      return `a paired device${named}`
    case "key":
      return `an API key${named}`
    case "frame":
      return `an app${named}`
    case "unbound":
      return "this home"
    case "session":
      return `a browser signed in${asker.name ? ` with ${asker.name}` : ""}`
    default:
      return "a client of yours"
  }
}

// ---------------------------------------------------------------------------
// The connection
// ---------------------------------------------------------------------------

/**
 * The glass's connection to its home's device channel. Everything it
 * touches is given: `socket(url)` makes a WebSocket-like object,
 * `store` holds the device record, `subtle` signs, `now()` reads the
 * clock in Unix ms, `setTimer`/`clearTimer` schedule, and `onChange(glass)`
 * hears each change of `status`, `pending` or `outcome`.
 *
 * `status` is `starting`, `unpaired`, `connecting`, `renewing`, `ready`,
 * `waiting` (closed, about to try again) or `revoked`.
 */
export class Glass {
  constructor({url, socket, store, subtle = globalThis.crypto?.subtle, now = () => Date.now(), setTimer = setTimeout, clearTimer = clearTimeout, onChange = () => {}}) {
    Object.assign(this, {url, makeSocket: socket, store, subtle, now, setTimer, clearTimer, onChange})
    this.status = "starting"
    this.device = null
    this.ws = null
    this.seq = 0
    this.requests = new Map()
    this.grants = new Map()
    this.pending = []
    this.outcome = {}
    this.renewTimer = null
    this.retryTimer = null
    this.attempts = 0
    this.mustRenew = false
    this.listening = false
    this.listenTimer = null
  }

  async start() {
    this.device = await this.store.load()
    if (!this.device || !this.device.certificate) return this.set("unpaired")
    this.connect()
  }

  // A new connection: `renew` under an expired certificate, `connect`
  // otherwise. Nothing is sent but the exchange until `standing`.
  connect() {
    this.closeSocket()
    const renewing = this.mustRenew || expired(this.device.certificate, this.now())
    this.set(renewing ? "renewing" : "connecting")
    const ws = this.makeSocket(this.url)
    this.ws = ws
    ws.onopen = () => {
      const opening = renewing
        ? renewMessage(this.device.clientId, this.device.certificate)
        : connectMessage(this.device.clientId, this.device.certificate)
      this.send(opening)
    }
    ws.onmessage = (event) => this.receive(event.data)
    ws.onclose = (event) => this.closed(ws, event)
  }

  // On wake, or when the network returns: a connection that is gone, or
  // whose certificate expired while the device slept, starts again, and
  // sends nothing until the replacement stands.
  wake() {
    if (!this.device || this.status === "revoked" || this.status === "unpaired") return
    if (!this.ws || this.status === "waiting" || expired(this.device.certificate, this.now())) this.connect()
  }

  /** Send one intent once the connection stands: a promise of its answer. */
  request(operation, args = {}) {
    if (this.status !== "ready") return Promise.reject(new Error("not connected"))
    const id = `int_${++this.seq}`
    return new Promise((resolve, reject) => {
      this.requests.set(id, {resolve, reject})
      this.send(intentMessage(id, operation, args))
    })
  }

  send(map) {
    if (this.ws) this.ws.send(JSON.stringify(map))
  }

  async receive(text) {
    let map
    try {
      map = JSON.parse(text)
    } catch (_error) {
      return
    }
    const {type, body, error} = decodeHome(map)
    if (error) return

    switch (type) {
      case "challenge":
        return this.send(proofMessage(await prove(body.challenge, this.device.privateKey, this.subtle)))

      case "certificate":
        this.device = {...this.device, certificate: body.certificate}
        this.mustRenew = false
        await this.store.save(this.device)
        return

      case "standing":
        return this.standing()

      case "answer":
        return this.answered(body)

      case "grant":
        this.grants.set(body.grant_id, body.stream)
        // Facts between a grant that ended and this one were never
        // delivered, nor those between the read at standing and the first
        // grant: what is waiting is read again.
        if (body.stream === CONFIRMATIONS) return this.refresh()
        return

      case "event":
        if (this.grants.get(body.grant_id) === CONFIRMATIONS) return this.refresh()
        return

      case "revoke":
        if (body.grant_id) {
          const stream = this.grants.get(body.grant_id)
          this.grants.delete(body.grant_id)
          if (stream === CONFIRMATIONS) {
            this.listening = false
            if (this.status === "ready") this.listen()
          }
          return
        }
        return this.revoked()
    }
  }

  standing() {
    this.attempts = 0
    this.set("ready")
    this.scheduleRenewal()
    this.listen()
    this.refresh()
  }

  answered({id, result, error}) {
    const request = this.requests.get(id)
    if (!request) return
    this.requests.delete(id)
    if (error) request.reject(Object.assign(new Error(error.message || "refused"), {refusal: error}))
    else request.resolve(result)
  }

  // One grant of the stream at a time: a renewal's `standing` opens none.
  // An open the home refused or could not admit just now is tried again
  // shortly, while the connection stands.
  listen() {
    if (this.listening) return
    this.listening = true
    this.request("streams.open", {stream: CONFIRMATIONS}).catch(() => {
      this.listening = false
      this.stopListenRetry()
      this.listenTimer = this.setTimer(() => {
        this.listenTimer = null
        if (this.status === "ready") this.listen()
      }, LISTEN_RETRY_MS)
    })
  }

  stopListenRetry() {
    if (this.listenTimer) this.clearTimer(this.listenTimer)
    this.listenTimer = null
  }

  // The person's open confirmations, read again: the glass shows the
  // home's record, never a fact's word.
  async refresh() {
    try {
      const {confirmations} = await this.request("confirmation.pending", {})
      this.pending = confirmations || []
      this.onChange(this)
    } catch (_error) {
      // A refused read leaves what was shown; the next fact reads again.
    }
  }

  // Half the certificate's life: renewed over the open connection, which
  // keeps working under the old one until the replacement stands.
  scheduleRenewal() {
    if (this.renewTimer) this.clearTimer(this.renewTimer)
    const wait = Math.max(renewAt(this.device.certificate) - this.now(), 1_000)
    this.renewTimer = this.setTimer(() => {
      this.renewTimer = null
      if (this.status === "ready") this.send(renewMessage(this.device.clientId))
    }, wait)
  }

  /**
   * Forget the device this glass holds: its connection closed, its key and
   * certificate erased here. The home still lists the client until it is
   * revoked.
   */
  async unpair() {
    this.closeSocket()
    this.stopListenRetry()
    if (this.renewTimer) this.clearTimer(this.renewTimer)
    if (this.retryTimer) this.clearTimer(this.retryTimer)
    this.renewTimer = null
    this.retryTimer = null
    this.device = null
    this.pending = []
    await this.store.clear()
    this.set("unpaired")
  }

  async revoked() {
    this.set("revoked")
    this.stopListenRetry()
    this.device = null
    await this.store.clear()
    this.closeSocket()
  }

  closed(ws, event) {
    if (ws !== this.ws) return
    this.ws = null
    for (const {reject} of this.requests.values()) reject(new Error("closed"))
    this.requests.clear()
    this.grants.clear()
    this.listening = false
    this.stopListenRetry()
    if (this.renewTimer) this.clearTimer(this.renewTimer)
    this.renewTimer = null
    if (this.status === "revoked") return

    switch (event && event.code) {
      case 4403:
        return this.revoked()
      case 4408:
        // The certificate must be replaced: straight back, through renewal.
        this.mustRenew = true
        return this.retry(0)
      case 1013:
        return this.retry(retryAfter(event.reason))
      default:
        return this.retry(Math.min(30_000, 1_000 * 2 ** Math.min(this.attempts, 5)))
    }
  }

  retry(wait) {
    this.attempts += 1
    this.set("waiting")
    if (this.retryTimer) this.clearTimer(this.retryTimer)
    this.retryTimer = this.setTimer(() => {
      this.retryTimer = null
      if (this.status === "waiting") this.connect()
    }, wait)
  }

  closeSocket() {
    if (!this.ws) return
    const ws = this.ws
    this.ws = null
    try {
      ws.close()
    } catch (_error) {
      // Already closed.
    }
  }

  // The proofs the glass gives, each a device intent naming the record by
  // its ref; the outcome is shown until the next read.
  async confirmWithPasskey(ref, assertion) {
    return this.act(ref, "confirmation.confirm", {ref, assertion}, "Confirmed. The client that asked completes the change.")
  }

  async sendCode(ref) {
    return this.act(ref, "confirmation.reauth", {ref, method: "email"}, "A code was sent to your email.")
  }

  async confirmWithCode(ref, code) {
    return this.act(ref, "confirmation.confirm", {ref, code}, "Confirmed. The client that asked completes the change.")
  }

  async cancel(ref) {
    return this.act(ref, "confirmation.cancel", {ref}, "Cancelled. Nothing was changed.")
  }

  /** Say how an action on `ref` ended, without asking the home. */
  note(ref, ok, text) {
    this.outcome = {...this.outcome, [ref]: {ok, text}}
    this.onChange(this)
  }

  async act(ref, operation, args, done) {
    try {
      await this.request(operation, args)
      this.outcome = {...this.outcome, [ref]: {ok: true, text: done}}
    } catch (error) {
      this.outcome = {...this.outcome, [ref]: {ok: false, text: error.message}}
    }
    this.onChange(this)
  }

  set(status) {
    this.status = status
    this.onChange(this)
  }
}

// The seconds a `1013` close says to wait, or thirty.
function retryAfter(reason) {
  const match = /retry_after_s=(\d+)/.exec(reason || "")
  return (match ? Number(match[1]) : 30) * 1_000
}
