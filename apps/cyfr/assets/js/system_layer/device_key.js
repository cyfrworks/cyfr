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
 *
 * A device of a person whose keys are at another home holds a certificate
 * that home issued (`issuer`). This home does not renew it: the glass
 * renews it at the issuer (`renewElsewhere`, `POST <issuer>/certify/v1/renew`,
 * by `fetch`, with no credentials), proving its device key over the
 * issuer's challenge, and connects again under the replacement. When the
 * issuer answers that the certification ended (the person's keys changed),
 * or, after this home refused the certificate, it could not renew it three
 * times in a row, the glass offers to certify the device again at the
 * person's home (`<home>/carry#certify=<…>`), which needs the person's
 * fresh confirmation; that home sends the browser back with the new
 * certificate in the fragment (`/pair#certificate=<…>`). A pairing that
 * waits for its first such certificate keeps its code and key pair, for
 * the invitation's five minutes at most, as the store's pending record.
 *
 * The device key signs only a challenge the glass asked for, naming its
 * own key and client: a `connect` of this home, a `renew` of the home that
 * issued its certificate, a `pair` of this home, and only one shaped as a
 * home issues it (`cyfr-device-proof/v1`, one of the three purposes, a
 * 32-byte nonce), so it signs nothing the home would refuse to read. A
 * certificate in the fragment is taken only while the person's request to
 * their home stands (made as they name it, five minutes at most) and only
 * when it answers it: that home's, for this device, its client, this home
 * and the athanor. It replaces the stored one only once this home stands
 * it.
 */

export const PROTOCOL = "cyfr-device/v1"
// A challenge as a home issues it (`Prima.DeviceCert.Challenge`): its
// protocol, its purposes and its nonce's length in bytes.
export const PROOF_PROTOCOL = "cyfr-device-proof/v1"
export const PURPOSES = ["connect", "renew", "pair"]
export const NONCE_BYTES = 32
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

// Unpadded base64url of exactly `size` bytes, spelled the one way the home
// reads it (`Prima.Identity.Encoding.unb64/2`): no padding, no stray bits.
function exactB64url(text, size) {
  try {
    const bytes = fromB64url(text)
    return bytes.length === size && b64url(bytes) === text
  } catch (_error) {
    return false
  }
}

/**
 * Whether `challenge` is the one this device asked for: shaped as a home
 * issues one (its protocol, one of its purposes, a nonce of `NONCE_BYTES`),
 * and naming the device's own key and client, the purpose it asked for,
 * and the home it asked: `connect` at the home this page is at, `renew` at
 * the home that issued the certificate it holds, `pair` at this home.
 */
export function expectedChallenge(challenge, expected) {
  const {purpose, home, deviceKey, clientId} = expected || {}
  return Boolean(
    challenge &&
      typeof challenge === "object" &&
      !Array.isArray(challenge) &&
      challenge.protocol === PROOF_PROTOCOL &&
      PURPOSES.includes(challenge.purpose) &&
      exactB64url(challenge.nonce, NONCE_BYTES) &&
      typeof purpose === "string" &&
      challenge.purpose === purpose &&
      typeof home === "string" &&
      challenge.home === home &&
      typeof deviceKey === "string" &&
      challenge.device_key === deviceKey &&
      typeof clientId === "string" &&
      challenge.client_id === clientId
  )
}

/**
 * The proof of possession answering `challenge` (the JSON map the home
 * sent): the challenge's fields and the device key's signature over them.
 * Only a challenge the device asked for (`expectedChallenge`) is signed;
 * any other is refused, with an error whose `refused` is true, and nothing
 * is signed: a challenge relayed from another home, or for another
 * purpose, buys no proof.
 */
export async function prove(challenge, privateKey, expected, subtle = globalThis.crypto.subtle) {
  if (!expectedChallenge(challenge, expected)) {
    throw Object.assign(new Error("The challenge is not one this device asked for, so it was not signed."), {refused: true})
  }
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
// A device certified at another home
// ---------------------------------------------------------------------------

/** How long a pairing waiting for its person's home keeps its code and key: the invitation's life. */
export const PENDING_MS = 5 * 60 * 1000
/** How long the glass waits before asking the issuer again after it could not answer. */
export const RENEW_RETRY_MS = 15_000
/** How many renewals in a row the issuer could not give, after this home refused the certificate, before the person is offered to certify again. */
export const UNREACHABLE_OFFER = 3

/** The certificate a person's home sent back in the fragment's `certificate`, or null. */
export function certificateFromFragment(hash) {
  const fragment = (hash || "").replace(/^#/, "")
  if (!fragment.startsWith("certificate=")) return null
  return decodeObject(fragment.slice("certificate=".length))
}

/** An unpadded base64url JSON object, or null. */
export function decodeObject(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]+$/.test(text)) return null
  try {
    const object = JSON.parse(new TextDecoder("utf-8", {fatal: true}).decode(fromB64url(text)))
    return object && typeof object === "object" && !Array.isArray(object) ? object : null
  } catch (_error) {
    return null
  }
}

/** Whether `certificate` was issued by another home than `home`, the origin this page is at. */
export const issuedElsewhere = (certificate, home) =>
  Boolean(certificate && typeof certificate.issuer === "string" && certificate.issuer !== home)

/**
 * Whether a certificate is this device's at `home`: its device key, its
 * client and this home as audience, and, when they are given, the issuer
 * and the athanor the device asked for.
 */
export function certifies(certificate, {deviceKey, clientId, home, issuer, athanor}) {
  return Boolean(
    certificate &&
      typeof certificate === "object" &&
      typeof deviceKey === "string" &&
      certificate.device_key === deviceKey &&
      typeof clientId === "string" &&
      certificate.client_id === clientId &&
      typeof home === "string" &&
      certificate.audience === home &&
      typeof certificate.issuer === "string" &&
      (issuer === undefined || certificate.issuer === issuer) &&
      (athanor === undefined || certificate.athanor === athanor) &&
      typeof certificate.expires_at === "number"
  )
}

/**
 * A home's origin from the address a person typed (`https://` when it
 * names no scheme), or null when it is none: no credentials, no other
 * scheme than http or https.
 */
export function homeOrigin(text) {
  const value = String(text || "").trim()
  if (value === "") return null
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(value) ? value : `https://${value}`
  let url
  try {
    url = new URL(withScheme)
  } catch (_error) {
    return null
  }
  if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || !url.hostname) return null
  return url.origin
}

/**
 * The address that asks the person's home `issuer` to certify this
 * device for `request`: this home as `audience`, the `athanor`, the
 * `client_id` this home reserved and the `device_key`. Only the person's
 * click there certifies it.
 */
export function certifyUrl(issuer, request) {
  const body = {audience: request.audience, athanor: request.athanor, client_id: request.client_id, device_key: request.device_key}
  return `${issuer}/carry#certify=${b64url(new TextEncoder().encode(jcs(body)))}`
}

/**
 * Renew `certificate`, the one the device holds, at the home that issued
 * it: the certificate locates its certification there, the home answers a
 * challenge, and the device key's proof over it is answered with the
 * replacement. Only a `renew` challenge of that home for this device's own
 * key and client is signed; any other is refused before anything more is
 * sent. Sent with no credentials. Answers the replacement, or throws an
 * error whose `ended` says the certification ended there (the device is
 * certified again) rather than that the home could not answer now (it is
 * asked again).
 */
export async function renewElsewhere({certificate, privateKey, deviceKey, clientId, fetch, subtle = globalThis.crypto.subtle}) {
  const url = `${certificate.issuer}/certify/v1/renew`
  const {challenge} = await askIssuer(fetch, url, {certificate})
  let proof
  try {
    proof = await prove(challenge, privateKey, {purpose: "renew", home: certificate.issuer, deviceKey, clientId}, subtle)
  } catch (error) {
    throw Object.assign(new Error("The home that certified this device answered a challenge this device did not ask for."), {
      ended: false,
      refused: Boolean(error.refused)
    })
  }
  const answer = await askIssuer(fetch, url, {certificate, proof})
  return answer.certificate
}

// One renewal call. A refusal that ends the certification (404, 409), and
// one that refuses this device (401, 403), mean certifying it again; any
// other is asked again later.
async function askIssuer(fetchFn, url, body) {
  let response
  try {
    response = await fetchFn(url, {
      method: "POST",
      mode: "cors",
      credentials: "omit",
      cache: "no-store",
      headers: {"content-type": "application/json", accept: "application/json"},
      body: JSON.stringify(body)
    })
  } catch (_error) {
    throw Object.assign(new Error("The home that certified this device could not be reached."), {ended: false})
  }

  let answer = null
  try {
    answer = await response.json()
  } catch (_error) {
    answer = null
  }
  if (response.ok && answer && typeof answer === "object") return answer
  const ended = [401, 403, 404, 409].includes(response.status)
  const message = answer && typeof answer.message === "string" ? answer.message : `The home that certified this device answered ${response.status}.`
  throw Object.assign(new Error(message), {ended, status: response.status})
}

// ---------------------------------------------------------------------------
// The stored key and certificate
// ---------------------------------------------------------------------------

/**
 * The glass's store in IndexedDB: one record, the key pair (the private
 * key unexportable), the public key's encoding, the client id and the
 * certificate. `load` answers it or null. Beside it, the pending record of
 * a pairing that waits for the person's own home to certify it: the
 * invitation's code, the key pair, what to certify and when it began
 * (`loadPending`, `savePending`, `clearPending`); and the certification
 * the person asked of their home when they named it: that home, the
 * client, this home as audience, the athanor and when (`loadCertify`,
 * `saveCertify`, `clearCertify`). A certificate coming back is taken only
 * while that request stands, and only when it answers it.
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
    clear: () => run("readwrite", (store) => store.delete("device")).then(() => null),
    loadPending: () => run("readonly", (store) => store.get("pending")).then((value) => value || null),
    savePending: (record) => run("readwrite", (store) => store.put(record, "pending")).then(() => record),
    clearPending: () => run("readwrite", (store) => store.delete("pending")).then(() => null),
    loadCertify: () => run("readonly", (store) => store.get("certify")).then((value) => value || null),
    saveCertify: (record) => run("readwrite", (store) => store.put(record, "certify")).then(() => record),
    clearCertify: () => run("readwrite", (store) => store.delete("certify")).then(() => null)
  }
}

/** A store in memory, with the same calls. */
export function memoryStore(record = null, pendingRecord = null, certifyRecord = null) {
  let held = record
  let pending = pendingRecord
  let asked = certifyRecord
  return {
    load: async () => held,
    save: async (next) => (held = next),
    clear: async () => (held = null),
    loadPending: async () => pending,
    savePending: async (next) => (pending = next),
    clearPending: async () => (pending = null),
    loadCertify: async () => asked,
    saveCertify: async (next) => (asked = next),
    clearCertify: async () => (asked = null)
  }
}

// A record within `PENDING_MS` of `now`; a stale one is erased.
async function fresh(record, clear, now) {
  if (!record) return null
  if (typeof record.at === "number" && now >= record.at && now - record.at < PENDING_MS) return record
  await clear()
  return null
}

/** The pending pairing in `store` while it is within `PENDING_MS` of `now`; a stale one is erased. */
export async function freshPending(store, now) {
  return fresh(await store.loadPending(), () => store.clearPending(), now)
}

/** The certification the person asked of their home, while it is within `PENDING_MS` of `now`; a stale one is erased. */
export async function freshCertify(store, now) {
  return fresh(await store.loadCertify(), () => store.clearCertify(), now)
}

/**
 * Whether `certificate`, come back in the fragment, answers `asked`, the
 * certification the person asked of their home, for the device key
 * `deviceKey` at this home, `home`: issued by that home, for that client,
 * this home and that athanor.
 */
export function answersCertify(certificate, asked, {deviceKey, home}) {
  return Boolean(
    asked &&
      asked.audience === home &&
      certifies(certificate, {deviceKey, clientId: asked.client, home, issuer: asked.home, athanor: asked.athanor})
  )
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
 * `waiting` (closed, about to try again), `recertify` (its person's home
 * ended the certification: certify it again there) or `revoked`.
 *
 * `home` is the origin this page is at (by default, the device channel's),
 * and `fetch` reaches the home that issued a certificate this home did not.
 *
 * `certifyAgain` says the person is offered to certify the device again at
 * their home, and `certifyReason` why: `ended`, that home ended the
 * certification, or `unreachable`, this home refused the certificate
 * (`4408`) and that home could not renew it `UNREACHABLE_OFFER` times in a
 * row, as when it was lost and the person restored elsewhere; then it is
 * still asked again in the background.
 */
export class Glass {
  // The browser's timers are called unbound: a browser refuses its own
  // `setTimeout` called as a method of anything else (Illegal invocation).
  constructor({url, socket, store, home = null, fetch = (resource, init) => globalThis.fetch(resource, init), subtle = globalThis.crypto?.subtle, now = () => Date.now(), setTimer = (act, ms) => setTimeout(act, ms), clearTimer = (timer) => clearTimeout(timer), onChange = () => {}}) {
    Object.assign(this, {url, makeSocket: socket, store, home: home || socketOrigin(url), fetch, subtle, now, setTimer, clearTimer, onChange})
    this.certifyAgain = false
    this.certifyReason = null
    // What this glass last asked of the home it is connected to (`connect`
    // or `renew`): the one challenge it answers.
    this.asked = null
    // A certificate the person's home just issued, presented in place of
    // the stored one until this home stands it.
    this.candidate = null
    // This home refused the certificate (`4408`), and the issuer's renewals
    // that could not be had since.
    this.refusedHere = false
    this.unreachable = 0
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

  /**
   * Connect the stored device under its certificate, or, given
   * `candidate`, under a certificate the person's home just issued for it,
   * which replaces the stored one only once this home stands it.
   */
  async start(candidate = null) {
    this.device = await this.store.load()
    if (!this.device || !this.device.certificate) return this.set("unpaired")
    this.candidate = candidate
    this.connect()
  }

  // A new connection: `renew` under an expired certificate, `connect`
  // otherwise. Nothing is sent but the exchange until `standing`. A
  // certificate another home issued is renewed there first.
  connect() {
    this.closeSocket()
    this.dropRequests()
    const candidate = this.candidate
    const renewing = !candidate && (this.mustRenew || expired(this.device.certificate, this.now()))
    if (renewing && this.remote()) return this.renewAtIssuer()
    this.set(renewing ? "renewing" : "connecting")
    const ws = this.makeSocket(this.url)
    this.ws = ws
    ws.onopen = () => {
      const certificate = candidate || this.device.certificate
      this.asked = renewing ? "renew" : "connect"
      this.send(renewing ? renewMessage(this.device.clientId, certificate) : connectMessage(this.device.clientId, certificate))
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
        return this.answer(body.challenge)

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

  // The one challenge this glass asked for, answered: a `connect` of this
  // home, or a `renew` of the home that issued its certificate, for its own
  // key and client. Any other is left unanswered and nothing is signed;
  // the home closes the connection.
  async answer(challenge) {
    const asked = this.asked
    this.asked = null
    if (!asked || !this.device) return
    const home = asked === "renew" ? this.device.certificate.issuer : this.home
    const expected = {purpose: asked, home, deviceKey: this.device.publicKey, clientId: this.device.clientId}
    let proof
    try {
      proof = await prove(challenge, this.device.privateKey, expected, this.subtle)
    } catch (_error) {
      return
    }
    this.send(proofMessage(proof))
  }

  async standing() {
    if (this.candidate) {
      // This home stood the certificate the person's home just issued: it
      // replaces the stored one now, and not before.
      this.device = {...this.device, certificate: this.candidate}
      this.candidate = null
      this.offer(null)
      try {
        await this.store.save(this.device)
      } catch (_error) {
        // Kept for this page; the next page asks the person again.
      }
    }
    this.attempts = 0
    this.refusedHere = false
    this.unreachable = 0
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
  // keeps working under the old one until the replacement stands; one
  // another home issued is renewed there, and presented on a new
  // connection.
  scheduleRenewal() {
    if (this.renewTimer) this.clearTimer(this.renewTimer)
    const wait = Math.max(renewAt(this.device.certificate) - this.now(), 1_000)
    this.renewTimer = this.setTimer(() => {
      this.renewTimer = null
      if (this.status !== "ready") return
      if (this.remote()) return this.refreshAtIssuer()
      this.asked = "renew"
      this.send(renewMessage(this.device.clientId))
    }, wait)
  }

  /** Whether the certificate this glass holds was issued by another home than this one. */
  remote() {
    return Boolean(this.home && this.device && issuedElsewhere(this.device.certificate, this.home))
  }

  /** What its person's home certifies this device for: this home, its athanor, its client and its key. */
  certifyRequest() {
    if (!this.device || !this.device.certificate) return null
    return {audience: this.home, athanor: this.device.certificate.athanor, client_id: this.device.clientId, device_key: this.device.publicKey}
  }

  // An expired certificate, or one this home refused, renewed at the home
  // that issued it before any connection: the replacement, or the offer to
  // certify again, or another try shortly. After this home refused the
  // certificate, an issuer that cannot renew it `UNREACHABLE_OFFER` times
  // in a row may be lost for good: the offer is made, and the issuer is
  // still asked again in the background.
  async renewAtIssuer() {
    const device = this.device
    this.set("renewing")
    try {
      const certificate = await this.fromIssuer(device)
      if (this.device !== device) return
      this.device = {...device, certificate}
      this.mustRenew = false
      this.unreachable = 0
      this.offer(null)
      await this.store.save(this.device)
      this.connect()
    } catch (error) {
      if (this.device !== device || this.status === "revoked") return
      if (error.ended) {
        this.offer("ended")
        return this.set("recertify")
      }
      if (this.refusedHere && ++this.unreachable >= UNREACHABLE_OFFER && !this.certifyAgain) this.offer("unreachable")
      return this.retry(Math.min(30_000, 1_000 * 2 ** Math.min(this.attempts, 5)))
    }
  }

  // At half the certificate's life, while connected: the replacement from
  // the issuing home is presented on a new connection; until then, and if
  // the issuer cannot answer, the connection stands under the old one.
  async refreshAtIssuer() {
    const device = this.device
    try {
      const certificate = await this.fromIssuer(device)
      if (this.device !== device) return
      this.device = {...device, certificate}
      this.offer(null)
      await this.store.save(this.device)
      this.connect()
    } catch (error) {
      if (this.device !== device || this.status === "revoked") return
      if (error.ended) {
        this.offer("ended")
        return this.onChange(this)
      }
      if (this.renewTimer) this.clearTimer(this.renewTimer)
      this.renewTimer = this.setTimer(() => {
        this.renewTimer = null
        if (this.status === "ready") this.refreshAtIssuer()
      }, RENEW_RETRY_MS)
    }
  }

  // The replacement from the home that issued the certificate held: this
  // device's, for this home, from that same home and for the same athanor.
  async fromIssuer(device) {
    const held = device.certificate
    const certificate = await renewElsewhere({
      certificate: held,
      privateKey: device.privateKey,
      deviceKey: device.publicKey,
      clientId: device.clientId,
      fetch: this.fetch,
      subtle: this.subtle
    })
    if (!certifies(certificate, {deviceKey: device.publicKey, clientId: device.clientId, home: this.home, issuer: held.issuer, athanor: held.athanor})) {
      throw Object.assign(new Error("The home that certified this device answered another device's certificate."), {ended: false})
    }
    return certificate
  }

  // The offer to certify the device again at its person's home, and why;
  // `null` withdraws it.
  offer(reason) {
    this.certifyAgain = Boolean(reason)
    this.certifyReason = reason || null
  }

  // Requests on a connection being replaced are never answered there.
  dropRequests() {
    for (const {reject} of this.requests.values()) reject(new Error("closed"))
    this.requests.clear()
  }

  /**
   * Forget the device this glass holds: its connection closed, its key and
   * certificate erased here. The home still lists the client until it is
   * revoked.
   */
  async unpair() {
    this.closeSocket()
    this.offer(null)
    this.candidate = null
    this.asked = null
    this.refusedHere = false
    this.unreachable = 0
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
    this.asked = null
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
        // One just brought from the person's home that this home refused
        // is dropped, and the stored one stays.
        this.candidate = null
        this.mustRenew = true
        this.refusedHere = true
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

// The origin of the home whose device channel is at `url`.
function socketOrigin(url) {
  try {
    const parsed = new URL(url)
    const scheme = {"wss:": "https:", "ws:": "http:"}[parsed.protocol]
    return scheme ? `${scheme}//${parsed.host}` : null
  } catch (_error) {
    return null
  }
}

// The seconds a `1013` close says to wait, or thirty.
function retryAfter(reason) {
  const match = /retry_after_s=(\d+)/.exec(reason || "")
  return (match ? Number(match[1]) : 30) * 1_000
}
