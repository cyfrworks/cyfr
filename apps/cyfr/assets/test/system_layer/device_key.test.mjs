// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The glass's side of the device protocol, held to the vectors every side
// reads: `tests/fixtures/device.json` (the messages) and
// `tests/fixtures/device_cert.json` (certificates, challenges and proofs).
// Then the glass's key, its connection's order of things — nothing sent
// before `standing`, renewal before expiry and after sleep, the pairing's
// end — the prompt it draws, and the system layer hook's part in a
// confirmed change's repeat.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {dirname, resolve} from "node:path"
import {describe, test} from "node:test"
import {fileURLToPath} from "node:url"

import {
  b64url,
  capabilitiesMessage,
  codeFromFragment,
  CONFIRMATIONS,
  LISTEN_RETRY_MS,
  CONTINUOUS_FIELDS,
  connectMessage,
  decodeHome,
  expired,
  fromB64url,
  GLASS_TYPES,
  Glass,
  generateKeyPair,
  HOME_TYPES,
  intentMessage,
  jcs,
  memoryStore,
  openingPlan,
  pairRequestMessage,
  promptModel,
  proofMessage,
  prove,
  publicKeyB64,
  renewAt,
  renewMessage,
  signedBytes
} from "../../js/system_layer/device_key.js"
import SystemLayer, {clearAllMarked, clearForms, clearMarked, glassStatus, markForm, resubmit} from "../../js/system_layer/index.js"

const here = dirname(fileURLToPath(import.meta.url))
const fixture = (name) => JSON.parse(readFileSync(resolve(here, "../../../../../tests/fixtures", name), "utf8"))
const device = fixture("device.json")
const certs = fixture("device_cert.json")
const subtle = globalThis.crypto.subtle

const named = (name) => device.messages.find((vector) => vector.name === name).message

async function privateKey(name) {
  const {seed, public: x} = certs.keys[name]
  return subtle.importKey("jwk", {kty: "OKP", crv: "Ed25519", d: seed, x}, {name: "Ed25519"}, false, ["sign"])
}

async function publicKey(name) {
  return subtle.importKey("raw", fromB64url(certs.keys[name].public), {name: "Ed25519"}, false, ["verify"])
}

// ---------------------------------------------------------------------------
// The vectors
// ---------------------------------------------------------------------------

describe("device_cert.json", () => {
  test("each proof is the named device key's signature over its challenge, reproduced", async () => {
    for (const [name, proof] of Object.entries(certs.proofs)) {
      const signer = name === "by_another_key" ? "device_2" : "device_1"
      const remade = await prove(proof, await privateKey(signer))
      assert.equal(remade.sig, proof.sig, name)
      assert.deepEqual(remade, proof, name)
    }
  })

  test("a proof by another key does not verify under the key its challenge names", async () => {
    const proof = certs.proofs.by_another_key
    assert.equal(proof.device_key, certs.keys.device_1.public)
    const verified = await subtle.verify({name: "Ed25519"}, await publicKey("device_1"), fromB64url(proof.sig), signedBytes(proof))
    assert.equal(verified, false)
  })

  test("each certificate whose signer is named re-signs to its sig: JCS over nested fields", async () => {
    for (const [name, {certificate, signer}] of Object.entries(certs.certificates)) {
      if (!signer) continue
      const {sig, ...fields} = certificate
      const remade = await subtle.sign({name: "Ed25519"}, await privateKey(signer), new TextEncoder().encode(jcs(fields)))
      assert.equal(b64url(remade), sig, name)
    }
  })

  test("expiry is strict on the clock: the last millisecond stands, expires_at does not", () => {
    const certificate = certs.certificates.local.certificate

    for (const vector of certs.verify.filter((row) => row.certificate === "local" && row.key === "alice_live_1")) {
      const ended = vector.error === "expired"
      if (vector.result === "ok" || ended) assert.equal(expired(certificate, vector.opts.now), ended, vector.name)
    }
  })

  test("renewal falls at half the certificate's life", () => {
    const certificate = certs.certificates.local.certificate
    assert.equal(renewAt(certificate), certificate.not_before + (certificate.expires_at - certificate.not_before) / 2)
  })
})

describe("device.json", () => {
  test("the glass and the home send the vector's types", () => {
    assert.deepEqual(GLASS_TYPES, device.types.glass)
    assert.deepEqual(HOME_TYPES, device.types.home)
    assert.deepEqual(CONTINUOUS_FIELDS, device.continuous_fields)
  })

  test("each message the glass sends is written as the vector writes it", () => {
    const connect = named("a connect")
    assert.deepEqual(connectMessage(connect.client_id, connect.certificate), connect)
    assert.deepEqual(proofMessage(named("its proof").proof), named("its proof"))
    assert.deepEqual(capabilitiesMessage(["display", "touch", "camera"]), named("a capability announcement"))
    assert.deepEqual(renewMessage(connect.client_id), named("a renewal, locating by client"))

    const located = device.messages.find((vector) => vector.message.type === "renew" && vector.message.certificate).message
    assert.deepEqual(renewMessage(located.client_id, located.certificate), located)

    const pair = named("a pairing request")
    assert.deepEqual(pairRequestMessage(pair.invitation_secret, pair.device_key), pair)

    const intent = named("a discrete intent")
    assert.deepEqual(intentMessage(intent.id, intent.operation, intent.args), intent)

    const repeated = named("an intent repeated under its confirmation")
    assert.deepEqual(intentMessage(repeated.id, repeated.operation, repeated.args, repeated.confirmation_id), repeated)
  })

  test("each message the home sends is read, and no other", () => {
    for (const {message, name, sender} of device.messages) {
      const read = decodeHome(message)

      if (sender === "home") {
        assert.equal(read.type, message.type, name)
        assert.deepEqual({protocol: device.protocol, type: read.type, ...read.body}, message, name)
      } else {
        assert.equal(read.error, "wrong_sender", name)
      }
    }
  })

  test("the home's refusals are refused, each for its reason", () => {
    for (const {message, name, error, sender} of device.refusals) {
      if (sender !== "home") continue
      assert.equal(decodeHome(message).error, error, name)
    }

    assert.equal(decodeHome({type: "standing"}).error, "missing_field")
    assert.equal(decodeHome({...named("a standing announcement"), protocol: "cyfr-device/v2"}).error, "wrong_protocol")
    assert.equal(decodeHome({protocol: device.protocol, type: "stream_frame"}).error, "unknown_type")
  })

  test("an intent the glass writes carries no continuous data and names tool.action", () => {
    const intent = intentMessage("int_9", "vault.create", {name: "x"})
    for (const field of CONTINUOUS_FIELDS) assert.equal(field in intent, false)
    assert.throws(() => intentMessage("int_9", "vault", {}))
    assert.throws(() => intentMessage("int_9", "vault.create", ["x"]))
    assert.throws(() => intentMessage("", "vault.create", {}))
  })
})

// ---------------------------------------------------------------------------
// The key
// ---------------------------------------------------------------------------

describe("the device key", () => {
  test("is made with a private key that cannot be exported, and proves a challenge", async () => {
    const {privateKey: key, publicKey: pub} = await generateKeyPair(subtle)
    assert.equal(key.extractable, false)
    await assert.rejects(subtle.exportKey("pkcs8", key))

    const encoded = await publicKeyB64(pub, subtle)
    assert.equal(fromB64url(encoded).length, 32)

    const challenge = {...certs.challenges.connect, device_key: encoded}
    const proof = await prove(challenge, key, subtle)
    assert.equal(await subtle.verify({name: "Ed25519"}, pub, fromB64url(proof.sig), signedBytes(proof)), true)
  })

  test("the pairing code is read from the fragment's code alone", () => {
    const code = "UjcQhGOiIAu_9xjWI7A-Fw"
    assert.equal(codeFromFragment(`#code=${code}`), code)
    assert.equal(codeFromFragment(`code=${code}`), code)
    assert.equal(codeFromFragment("#code=short"), null)
    assert.equal(codeFromFragment(""), null)
    assert.equal(codeFromFragment(undefined), null)
  })
})

// ---------------------------------------------------------------------------
// The connection
// ---------------------------------------------------------------------------

// A socket the test answers for the home, and a clock and timers it moves.
function harness({certificate, clock = certificate.not_before + 1_000}) {
  const sockets = []
  const timers = []
  let now = clock

  const makeSocket = (url) => {
    const socket = {
      url,
      sent: [],
      closed: false,
      send(text) {
        this.sent.push(JSON.parse(text))
      },
      close() {
        this.closed = true
      }
    }
    sockets.push(socket)
    return socket
  }

  return {
    sockets,
    timers,
    socket: () => sockets.at(-1),
    advance: (ms) => (now += ms),
    now: () => now,
    makeSocket,
    setTimer: (fun, ms) => {
      const timer = {fun, at: now + ms}
      timers.push(timer)
      return timer
    },
    clearTimer: (timer) => {
      const i = timers.indexOf(timer)
      if (i >= 0) timers.splice(i, 1)
    }
  }
}

const settle = () => new Promise((resolve) => setImmediate(resolve))

// Until `check` holds: the proof is signed by WebCrypto, off this turn.
async function until(check, label) {
  for (let i = 0; i < 200; i++) {
    if (check()) return
    await new Promise((resolve) => setTimeout(resolve, 2))
  }
  assert.fail(`never: ${label}`)
}

// The glass answered a challenge: its proof is the last message sent.
async function proved(socket, deviceKey, purpose = "connect") {
  const before = socket.sent.length
  home(socket, challengeFor(purpose, deviceKey))
  await until(() => socket.sent.length > before, "the proof")
  return socket.sent.at(-1)
}

async function glassWith({certificate, clock}) {
  const keys = await generateKeyPair(subtle)
  const deviceKey = await publicKeyB64(keys.publicKey, subtle)
  const record = {privateKey: keys.privateKey, publicKey: deviceKey, clientId: certificate.client_id, certificate: {...certificate, device_key: deviceKey}}
  const store = memoryStore(record)
  const h = harness({certificate, clock})
  const changes = []
  const glass = new Glass({
    url: "wss://alice.example/device/websocket",
    socket: h.makeSocket,
    store,
    subtle,
    now: h.now,
    setTimer: h.setTimer,
    clearTimer: h.clearTimer,
    onChange: (g) => changes.push(g.status)
  })
  return {glass, store, h, keys, deviceKey, changes}
}

const home = (socket, message) => socket.onmessage({data: JSON.stringify(message)})

const challengeFor = (purpose, deviceKey) => ({
  protocol: device.protocol,
  type: "challenge",
  challenge: {...certs.challenges[purpose], device_key: deviceKey}
})

const standing = (certificate) => ({
  protocol: device.protocol,
  type: "standing",
  client_id: certificate.client_id,
  athanor: certificate.athanor,
  expires_at: certificate.expires_at
})

// Each intent the socket carried, as operation names.
const intents = (socket) => socket.sent.filter((m) => m.type === "intent").map((m) => m.operation)

describe("the connection", () => {
  const certificate = certs.certificates.local.certificate

  test("connects under its certificate, proves, and sends nothing before standing", async () => {
    const {glass, h, keys, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    assert.equal(socket.url, "wss://alice.example/device/websocket")

    socket.onopen()
    assert.deepEqual(socket.sent.map((m) => m.type), ["connect"])
    assert.equal(glass.status, "connecting")
    await assert.rejects(glass.request("confirmation.pending", {}))

    const proof = await proved(socket, deviceKey)
    assert.equal(proof.type, "proof")
    assert.equal(await subtle.verify({name: "Ed25519"}, keys.publicKey, fromB64url(proof.proof.sig), signedBytes(proof.proof)), true)
    assert.deepEqual(intents(socket), [])

    // Standing: only now the stream opens and the pending list is read.
    home(socket, standing(certificate))
    await settle()
    assert.equal(glass.status, "ready")
    assert.deepEqual(intents(socket), ["streams.open", "confirmation.pending"])
    assert.deepEqual(socket.sent.find((m) => m.operation === "streams.open").args, {stream: CONFIRMATIONS})
  })

  test("on the browser's own timers, standing schedules its renewal and opens its stream", async () => {
    // A browser refuses its timers called as a method of anything but the
    // window; these refuse the same way.
    const own = {setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout}
    const scheduled = []
    const strict = (name, act) =>
      function (...args) {
        if (this !== undefined && this !== globalThis) throw new TypeError(`Illegal invocation of ${name}`)
        return act(...args)
      }
    globalThis.setTimeout = strict("setTimeout", (fun, ms) => {
      scheduled.push(ms)
      return own.setTimeout(fun, ms)
    })
    globalThis.clearTimeout = strict("clearTimeout", (timer) => own.clearTimeout(timer))

    try {
      const keys = await generateKeyPair(subtle)
      const deviceKey = await publicKeyB64(keys.publicKey, subtle)
      const record = {privateKey: keys.privateKey, publicKey: deviceKey, clientId: certificate.client_id, certificate: {...certificate, device_key: deviceKey}}
      const h = harness({certificate})
      const glass = new Glass({url: "wss://alice.example/device/websocket", socket: h.makeSocket, store: memoryStore(record), subtle, now: h.now})
      await glass.start()
      const socket = h.socket()
      socket.onopen()
      home(socket, challengeFor("connect", deviceKey))
      await new Promise((resolve) => own.setTimeout(resolve, 20))

      home(socket, standing(certificate))
      await new Promise((resolve) => own.setTimeout(resolve, 20))
      assert.equal(glass.status, "ready")
      assert.equal(scheduled.length, 1, "the renewal is scheduled")
      assert.deepEqual(intents(socket), ["streams.open", "confirmation.pending"])

      await glass.unpair()
      assert.equal(glass.status, "unpaired")
    } finally {
      globalThis.setTimeout = own.setTimeout
      globalThis.clearTimeout = own.clearTimeout
    }
  })

  test("after sleeping past its certificate it renews first, and sends no intent until the replacement stands", async () => {
    const {glass, h, store, deviceKey} = await glassWith({certificate, clock: certificate.expires_at + 60_000})
    await glass.start()
    const socket = h.socket()
    socket.onopen()

    // The expired certificate only locates the client.
    const [renew] = socket.sent
    assert.equal(renew.type, "renew")
    assert.equal(renew.client_id, certificate.client_id)
    assert.equal(glass.status, "renewing")

    const proof = await proved(socket, deviceKey, "renew")
    assert.equal(proof.type, "proof")
    assert.equal(proof.proof.purpose, "renew")
    assert.deepEqual(intents(socket), [])

    const replacement = {...certificate, not_before: h.now(), expires_at: h.now() + 3_600_000}
    home(socket, {protocol: device.protocol, type: "certificate", certificate: replacement})
    await settle()
    assert.deepEqual(intents(socket), [])
    assert.equal((await store.load()).certificate.expires_at, replacement.expires_at)

    home(socket, standing(replacement))
    await settle()
    assert.deepEqual(intents(socket), ["streams.open", "confirmation.pending"])
  })

  test("renews over the open connection at half the certificate's life, and opens no second stream", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    const timer = h.timers.find((t) => t.at === renewAt(certificate))
    assert.ok(timer, "a renewal is scheduled at half the life")
    timer.fun()
    assert.deepEqual(socket.sent.at(-1), {protocol: device.protocol, type: "renew", client_id: certificate.client_id})

    await proved(socket, deviceKey, "renew")
    home(socket, {protocol: device.protocol, type: "certificate", certificate})
    home(socket, standing(certificate))
    await settle()
    assert.equal(intents(socket).filter((op) => op === "streams.open").length, 1)
  })

  test("woken past its certificate, an open connection starts again through renewal", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const first = h.socket()
    first.onopen()
    await proved(first, deviceKey)
    home(first, standing(certificate))
    await settle()

    h.advance(certificate.expires_at - h.now() + 1)
    glass.wake()
    assert.equal(first.closed, true)
    const second = h.socket()
    assert.notEqual(second, first)
    second.onopen()
    assert.equal(second.sent[0].type, "renew")
    await assert.rejects(glass.request("confirmation.pending", {}))
  })

  test("a close 4408 comes straight back through renewal", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const first = h.socket()
    first.onopen()
    await proved(first, deviceKey)
    home(first, standing(certificate))
    await settle()

    first.onclose({code: 4408, reason: "unauthenticated"})
    assert.equal(glass.status, "waiting")
    h.timers.at(-1).fun()
    const second = h.socket()
    second.onopen()
    assert.equal(second.sent[0].type, "renew")
  })

  test("its pairing's end, by a close 4403 or a revoke naming no grant, erases the stored key", async () => {
    for (const end of ["close", "revoke"]) {
      const {glass, h, store, deviceKey} = await glassWith({certificate})
      await glass.start()
      const socket = h.socket()
      socket.onopen()
      home(socket, challengeFor("connect", deviceKey))
      await settle()
      home(socket, standing(certificate))
      await settle()

      if (end === "close") socket.onclose({code: 4403, reason: "forbidden"})
      else home(socket, {protocol: device.protocol, type: "revoke", client_id: certificate.client_id})
      await settle()

      assert.equal(glass.status, "revoked", end)
      assert.equal(await store.load(), null, end)
      assert.equal(h.sockets.length, 1, end)
    }
  })

  test("each fact of the stream reads the pending list again; a grant's end opens it again", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    const reads = () => intents(socket).filter((op) => op === "confirmation.pending").length
    const opens = () => socket.sent.filter((m) => m.operation === "streams.open")
    assert.equal(reads(), 1, "the read at standing")

    home(socket, {protocol: device.protocol, type: "answer", id: opens()[0].id, result: {grant_id: "sgr_1"}})
    home(socket, {protocol: device.protocol, type: "grant", grant_id: "sgr_1", stream: CONFIRMATIONS, projection: ["ref", "kind"], expires_at: certificate.expires_at})
    await settle()
    assert.equal(reads(), 2, "read again at the grant: a fact before it was never delivered")

    home(socket, {protocol: device.protocol, type: "event", grant_id: "sgr_1", payload: {ref: "cnr_x", kind: "opened"}})
    await settle()
    assert.equal(reads(), 3)

    home(socket, {protocol: device.protocol, type: "revoke", client_id: certificate.client_id, grant_id: "sgr_1"})
    assert.equal(opens().length, 2)
    assert.equal(glass.status, "ready")

    // The stream granted again: what waited while it was down is read.
    home(socket, {protocol: device.protocol, type: "answer", id: opens()[1].id, result: {grant_id: "sgr_2"}})
    home(socket, {protocol: device.protocol, type: "grant", grant_id: "sgr_2", stream: CONFIRMATIONS, projection: ["ref", "kind"], expires_at: certificate.expires_at})
    await settle()
    assert.equal(reads(), 4)
  })

  test("an open the home could not admit is tried again shortly, and not once the connection is gone", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    const opens = () => socket.sent.filter((m) => m.operation === "streams.open")
    home(socket, {protocol: device.protocol, type: "answer", id: opens()[0].id, error: {class: "unavailable", message: "open it again shortly"}})
    await settle()
    const retry = h.timers.find((t) => t.at === h.now() + LISTEN_RETRY_MS)
    assert.ok(retry, "a retry is scheduled")
    h.timers.splice(h.timers.indexOf(retry), 1)
    retry.fun()
    assert.equal(opens().length, 2)

    // Refused again, then the connection drops before the retry is due: the
    // retry is dropped with it, and the next standing opens the stream.
    home(socket, {protocol: device.protocol, type: "answer", id: opens()[1].id, error: {class: "unavailable", message: "again"}})
    await settle()
    socket.onclose({code: 1006})
    await settle()
    assert.equal(h.timers.some((t) => t.at === h.now() + LISTEN_RETRY_MS), false)
    assert.equal(glass.listenTimer, null)
    assert.equal(glass.listening, false)
  })

  test("proves a record by its ref through a device intent, and shows how it ended", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    const confirming = glass.confirmWithCode("cnr_ref", "123456")
    const intent = socket.sent.at(-1)
    assert.equal(intent.operation, "confirmation.confirm")
    assert.deepEqual(intent.args, {ref: "cnr_ref", code: "123456"})
    assert.equal("confirmation_id" in intent, false)

    home(socket, {protocol: device.protocol, type: "answer", id: intent.id, result: {ref: "cnr_ref", state: "confirmed"}})
    await confirming
    assert.equal(glass.outcome.cnr_ref.ok, true)

    const cancelling = glass.cancel("cnr_other")
    const cancel = socket.sent.at(-1)
    home(socket, {protocol: device.protocol, type: "answer", id: cancel.id, error: {class: "conflict", message: "no longer waiting"}})
    await cancelling
    assert.deepEqual(glass.outcome.cnr_other, {ok: false, text: "no longer waiting"})
  })
})

// ---------------------------------------------------------------------------
// The prompt
// ---------------------------------------------------------------------------

describe("the glass's prompt", () => {
  const entry = {
    ref: "cnr_x",
    operation: "vault.create",
    preview: {home: "https://alice.example", athanor: "Alice", operation: "vault.create", resource: "github", details: {scopes: ["a", "b"]}},
    asker: {kind: "session", name: "github"},
    webauthn: {challenge: "AAAA"},
    methods: ["passkey", "oidc", "email"]
  }

  test("shows the home's preview and the asker, and offers what a glass can carry out", () => {
    const model = promptModel(entry)
    assert.deepEqual(model.rows, [
      ["Change", "vault.create"],
      ["Concerning", "github"],
      ["In", "Alice at https://alice.example"],
      ["scopes", "a, b"]
    ])
    assert.equal(model.asker, "a browser signed in with github")
    assert.deepEqual(model.offers, ["passkey", "email"])
    assert.equal(model.signInElsewhere, true)
  })

  test("offers no passkey where the browser has none, and nothing the record does not offer", () => {
    assert.deepEqual(promptModel(entry, {webauthn: false}).offers, ["email"])
    assert.deepEqual(promptModel({...entry, methods: []}).offers, [])
    assert.equal(promptModel({...entry, methods: ["passkey"]}).signInElsewhere, false)
  })

  test("names its connection's state", () => {
    assert.equal(glassStatus({status: "renewing"}).state, "renewing")
    assert.equal(glassStatus({status: "revoked"}).state, "revoked")
    assert.deepEqual(glassStatus({status: "starting"}, {state: "pairing", text: "Pairing"}), {state: "pairing", text: "Pairing"})
  })
})

// ---------------------------------------------------------------------------
// The system layer hook's part in a repeat
// ---------------------------------------------------------------------------

describe("a confirmed change's repeat in the browser", () => {
  test("the form that typed it is submitted again, as typed", () => {
    const submitted = []
    const doc = {getElementById: (id) => (id === "system-layer-credential" ? {requestSubmit: () => submitted.push(id)} : null)}

    resubmit(doc, "system-layer-credential")
    resubmit(doc, "gone")
    assert.deepEqual(submitted, ["system-layer-credential"])
  })

  test("every form in a prompt is emptied as it closes", () => {
    const reset = []
    const dialog = {querySelectorAll: (selector) => (selector === "form" ? [{reset: () => reset.push(1)}, {reset: () => reset.push(2)}] : [])}

    clearForms(dialog)
    assert.deepEqual(reset, [1, 2])
  })
})

describe("a page's typed form, marked with its prompt", () => {
  function fakeForms() {
    const make = (id) => ({
      id,
      resets: 0,
      reset() {
        this.resets += 1
      }
    })
    const forms = [make("vault-client-form"), make("vault-create-form"), make("vault-rotate-form")]
    const doc = {getElementById: (id) => forms.find((form) => form.id === id) || null}
    return {doc, forms}
  }

  test("is emptied when that prompt ends, and no other form is", () => {
    const {doc, forms} = fakeForms()
    const marks = new Map()
    markForm(marks, "vault-client-form", "confirmation-cnr_a")
    markForm(marks, "vault-create-form", "confirmation-cnr_b")
    markForm(marks, "gone", "confirmation-cnr_c")

    clearMarked(doc, marks, "confirmation-cnr_a", "vault-client-form")
    assert.equal(forms[0].resets, 1)
    assert.equal(forms[1].resets, 0)
    assert.equal(marks.has("confirmation-cnr_a"), false)
    assert.equal(marks.has("confirmation-cnr_b"), true)

    // A form that is gone from the page is skipped.
    clearMarked(doc, marks, "confirmation-cnr_c", "gone")
    assert.equal(forms[1].resets, 0)
  })

  test("the mark is held apart from the form, so a re-render that drops the form's attributes keeps it", () => {
    const {doc, forms} = fakeForms()
    const marks = new Map()
    markForm(marks, "vault-create-form", "confirmation-cnr_b")

    // The form carries no mark of its own a LiveView patch could remove;
    // the prompt's end clears it by the id the mark holds.
    assert.equal(Object.keys(forms[1]).includes("attributes"), false)
    clearMarked(doc, marks, "confirmation-cnr_b")
    assert.equal(forms[1].resets, 1)
  })

  test("the form a prompt's end names is emptied even with no mark here", () => {
    const {doc, forms} = fakeForms()
    clearMarked(doc, new Map(), "confirmation-cnr_z", "vault-rotate-form")
    assert.equal(forms[2].resets, 1)
  })

  test("a reconnect empties every marked form: its prompts ended with the old page process", () => {
    const {doc, forms} = fakeForms()
    const marks = new Map()
    markForm(marks, "vault-client-form", "confirmation-cnr_a")
    markForm(marks, "vault-rotate-form", "confirmation-cnr_b")

    clearAllMarked(doc, marks)
    assert.deepEqual(forms.map((form) => form.resets), [1, 0, 1])
    assert.equal(marks.size, 0)

    SystemLayer.reconnected.call({marks: undefined})
  })
})

// ---------------------------------------------------------------------------
// No silent rebinding
// ---------------------------------------------------------------------------

describe("a glass that holds a device, opened on a pairing link", () => {
  test("its opening plan asks before a code replaces a stored device", () => {
    const stored = {certificate: certs.certificates.local.certificate}
    assert.equal(openingPlan("UjcQhGOiIAu_9xjWI7A-Fw", null), "pair")
    assert.equal(openingPlan("UjcQhGOiIAu_9xjWI7A-Fw", stored), "ask")
    assert.equal(openingPlan(null, stored), "connect")
    assert.equal(openingPlan(null, null), "unpaired")
  })

  test("unpairing closes its connection and erases its key and certificate here", async () => {
    const certificate = certs.certificates.local.certificate
    const {glass, h, store, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    await glass.unpair()
    assert.equal(socket.closed, true)
    assert.equal(glass.status, "unpaired")
    assert.equal(await store.load(), null)
  })

  // A page as small as the hook needs: elements with attributes, children
  // and the nearest `[data-action]`.
  class Node {
    constructor(tag) {
      Object.assign(this, {tag, attributes: {}, children: [], parent: null, listeners: {}})
    }
    setAttribute(name, value) {
      this.attributes[name] = String(value)
    }
    getAttribute(name) {
      return name in this.attributes ? this.attributes[name] : null
    }
    removeAttribute(name) {
      delete this.attributes[name]
    }
    append(...nodes) {
      for (const node of nodes) {
        node.parent = this
        this.children.push(node)
      }
    }
    replaceChildren(...nodes) {
      this.children = []
      this.append(...nodes)
    }
    get dataset() {
      const data = {}
      for (const [name, value] of Object.entries(this.attributes)) {
        if (name.startsWith("data-")) data[name.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value
      }
      return data
    }
    closest() {
      for (let node = this; node; node = node.parent) if (node.getAttribute && node.getAttribute("data-action") !== null) return node
      return null
    }
    addEventListener(type, fun) {
      this.listeners[type] = fun
    }
    removeEventListener() {}
    find(test) {
      for (const child of this.children) {
        if (child.getAttribute && child.getAttribute("data-test") === test) return child
        const found = child.find && child.find(test)
        if (found) return found
      }
      return null
    }
  }

  async function mountGlassPage({stored, replies}) {
    const saved = {document: globalThis.document, location: globalThis.location, history: globalThis.history, WebSocket: globalThis.WebSocket}
    const sockets = []
    const pushed = []
    const replaced = []

    globalThis.document = {
      visibilityState: "visible",
      createElement: (tag) => new Node(tag),
      createTextNode: (text) => ({text}),
      addEventListener() {},
      removeEventListener() {}
    }
    globalThis.location = {hash: "#code=UjcQhGOiIAu_9xjWI7A-Fw", pathname: "/pair", search: "", protocol: "https:", host: "alice.example"}
    globalThis.history = {replaceState: (...args) => replaced.push(args)}
    globalThis.WebSocket = class {
      constructor(url) {
        Object.assign(this, {url, sent: [], closed: false})
        sockets.push(this)
      }
      send(text) {
        this.sent.push(JSON.parse(text))
      }
      close() {
        this.closed = true
      }
    }

    const el = new Node("div")
    el.setAttribute("data-glass", "pair")
    const store = memoryStore(stored)
    const hook = Object.assign(Object.create(SystemLayer), {
      el,
      store,
      pushEvent(event, payload, reply) {
        pushed.push({event, payload})
        reply(replies[event](payload))
      }
    })

    await hook.mounted()
    const restore = () => Object.assign(globalThis, saved)
    return {hook, el, store, sockets, pushed, replaced, restore}
  }

  const certificate = certs.certificates.local.certificate
  const storedDevice = {clientId: certificate.client_id, certificate, publicKey: certificate.device_key}
  const replies = {
    pair_start: ({device_key}) => ({challenge: {...certs.challenges.pair, device_key}}),
    pair_proof: () => ({client_id: "pcl_new", certificate: {...certificate, client_id: "pcl_new"}})
  }

  test("nothing is sent and nothing replaced until the person chooses", async () => {
    const page = await mountGlassPage({stored: storedDevice, replies})
    try {
      // The code left the address at once.
      assert.equal(page.replaced.length, 1)
      assert.ok(page.el.find("glass-replace-ask"))
      assert.ok(page.el.find("glass-replace"))
      assert.ok(page.el.find("glass-keep"))
      assert.deepEqual(page.pushed, [])
      assert.deepEqual(page.sockets, [])
      assert.equal((await page.store.load()).clientId, certificate.client_id)
    } finally {
      page.restore()
    }
  })

  test("replacing is explicit: the stored device is unpaired first, then the code pairs", async () => {
    const page = await mountGlassPage({stored: storedDevice, replies})
    try {
      await page.hook.glassClick({target: page.el.find("glass-replace"), preventDefault() {}})

      assert.deepEqual(
        page.pushed.map((push) => push.event),
        ["pair_start", "pair_proof"]
      )
      assert.equal(page.pushed[0].payload.invitation_secret, "UjcQhGOiIAu_9xjWI7A-Fw")
      const record = await page.store.load()
      assert.equal(record.clientId, "pcl_new")
      assert.notEqual(record.publicKey, certificate.device_key)
      assert.equal(page.el.find("glass-replace-ask"), null)
      assert.equal(page.sockets.at(-1).url, "wss://alice.example/device/websocket")
    } finally {
      page.restore()
    }
  })

  test("keeping the device forgets the code and connects as before", async () => {
    const page = await mountGlassPage({stored: storedDevice, replies})
    try {
      await page.hook.glassClick({target: page.el.find("glass-keep"), preventDefault() {}})

      assert.deepEqual(page.pushed, [])
      assert.equal((await page.store.load()).clientId, certificate.client_id)
      assert.equal(page.sockets.length, 1)
      assert.equal(page.el.find("glass-replace-ask"), null)
    } finally {
      page.restore()
    }
  })

  test("a glass holding nothing pairs from the link at once", async () => {
    const page = await mountGlassPage({stored: null, replies})
    try {
      assert.deepEqual(
        page.pushed.map((push) => push.event),
        ["pair_start", "pair_proof"]
      )
      assert.equal((await page.store.load()).clientId, "pcl_new")
    } finally {
      page.restore()
    }
  })
})
