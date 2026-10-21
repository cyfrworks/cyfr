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
  codeFromFragment,
  CONFIRMATIONS,
  LISTEN_RETRY_MS,
  connectMessage,
  decodeHome,
  expired,
  GLASS_TYPES,
  Glass,
  generateKeyPair,
  HOME_TYPES,
  intentMessage,
  jcs,
  keyCode,
  keyDigest,
  openingPlan,
  promptModel,
  sealText,
  proofMessage,
  prove,
  publicKeyB64,
  renewAt,
  renewMessage,
  signedBytes,
  answersCertify,
  certificateFromFragment,
  certifies,
  certifyUrl,
  expectedChallenge,
  homeOrigin,
  issuedElsewhere,
  NONCE_BYTES,
  PENDING_MS,
  PROOF_PROTOCOL,
  PURPOSES,
  RENEW_RETRY_MS,
  renewElsewhere,
  UNREACHABLE_OFFER
} from "../../js/system_layer/device_key.js"
import {b64url, fromB64url} from "../../js/system_layer/base64url.js"
import {memoryStore} from "./memory_store.mjs"
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
      const asked = {purpose: proof.purpose, home: proof.home, deviceKey: proof.device_key, clientId: proof.client_id}
      const remade = await prove(proof, await privateKey(signer), asked)
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

  // What the glass asks for when it would take `challenge` as asked: its
  // purpose, its home, its key and its client. What it refuses then, it
  // refuses by the challenge's own shape.
  const askedFor = (challenge) => ({
    purpose: challenge.purpose,
    home: challenge.home,
    deviceKey: challenge.device_key,
    clientId: challenge.client_id
  })

  test("a challenge is read as the home issues one: its protocol, purposes and nonce length", () => {
    assert.equal(PROOF_PROTOCOL, certs.proof_protocol)
    assert.deepEqual(PURPOSES, certs.purposes)

    for (const [name, challenge] of Object.entries(certs.challenges)) {
      assert.equal(challenge.protocol, PROOF_PROTOCOL, name)
      assert.equal(fromB64url(challenge.nonce).length, NONCE_BYTES, name)
      assert.equal(expectedChallenge(challenge, askedFor(challenge)), true, name)
    }
  })

  test("the glass refuses to sign each challenge the home refuses to read", async () => {
    const key = await privateKey("device_1")
    assert.ok(certs.challenge_refusals.length > 0)

    for (const {name, challenge} of certs.challenge_refusals) {
      assert.equal(expectedChallenge(challenge, askedFor(challenge)), false, name)
      await assert.rejects(prove(challenge, key, askedFor(challenge), subtle), (error) => error.refused === true, name)
    }

    // A nonce the home reads only one way: padded, or one byte short.
    const connect = certs.challenges.connect
    for (const nonce of [connect.nonce + "=", connect.nonce.slice(0, -2), "", 7]) {
      const challenge = {...connect, nonce}
      await assert.rejects(prove(challenge, key, askedFor(challenge), subtle), (error) => error.refused === true, String(nonce))
    }
  })

  // The glass decides a proof case when the proof answers a challenge it
  // did not ask for: another purpose, home, key or client. Another athanor
  // or nonce, a signature and an expiry are the home's to judge.
  const glassCompares = ["purpose", "home", "device_key", "client_id"]

  test("each proof case the glass decides: it signs what the home takes, and nothing it asked otherwise", async () => {
    const decided = certs.proof_cases.filter(({result, error, field}) => result === "ok" || (error === "challenge_mismatch" && glassCompares.includes(field)))
    assert.ok(decided.some(({result}) => result === "ok"))
    assert.ok(decided.some(({error}) => error === "challenge_mismatch"))

    for (const {name, held, proof: proofName, result} of decided) {
      const proof = certs.proofs[proofName]
      const asked = askedFor(certs.challenges[held])
      const signer = proofName === "by_another_key" ? "device_2" : "device_1"

      if (result === "ok") {
        assert.deepEqual(await prove(proof, await privateKey(signer), asked, subtle), proof, name)
      } else {
        await assert.rejects(prove(proof, await privateKey(signer), asked, subtle), (error) => error.refused === true, name)
      }
    }
  })

  // The certificate refusals the glass decides: one that names another
  // device key, client, audience, issuer or athanor than the glass's own is
  // never taken as its certificate. The rest are the home's to refuse when
  // the glass presents it.
  test("a certificate refusal naming another device, home or issuer is not taken as this device's", () => {
    const own = certs.certificates.local.certificate
    const expected = {deviceKey: own.device_key, clientId: own.client_id, home: own.audience, issuer: own.issuer, athanor: own.athanor}
    assert.equal(certifies(own, expected), true)

    const decided = certs.refusals.filter(
      ({certificate: c}) =>
        c.device_key !== own.device_key ||
        c.client_id !== own.client_id ||
        c.audience !== own.audience ||
        c.issuer !== own.issuer ||
        c.athanor !== own.athanor
    )
    assert.ok(decided.length > 0)

    for (const {name, certificate} of decided) assert.equal(certifies(certificate, expected), false, name)
  })
})

describe("device.json", () => {
  test("the glass sends the vector's types", () => {
    assert.deepEqual(GLASS_TYPES, device.types.glass)
  })

  test("each message the glass sends is written as the vector writes it", () => {
    const connect = named("a connect")
    assert.deepEqual(connectMessage(connect.client_id, connect.certificate), connect)
    assert.deepEqual(proofMessage(named("its proof").proof), named("its proof"))
    assert.deepEqual(renewMessage(connect.client_id), named("a renewal, locating by client"))

    const located = device.messages.find((vector) => vector.message.type === "renew" && vector.message.certificate).message
    assert.deepEqual(renewMessage(located.client_id, located.certificate), located)

    const intent = named("a discrete intent")
    assert.deepEqual(intentMessage(intent.id, intent.operation, intent.args), intent)

    const repeated = named("an intent repeated under its confirmation")
    assert.deepEqual(intentMessage(repeated.id, repeated.operation, repeated.args, repeated.confirmation_id), repeated)
  })

  test("a pairing request names its key's digest, and the code a person types is that digest's", async () => {
    const {device_key, key_digest, code} = device.key_digest
    assert.equal(await keyDigest(device_key, subtle), key_digest)
    assert.equal(await keyDigest(device_key), key_digest)
    assert.equal(keyCode(key_digest), code)
    assert.equal(code.replace(/ /g, ""), key_digest)

    // The pairing request's digest is the digest of the key it carries.
    const pair = named("a pairing request")
    assert.equal(await keyDigest(pair.device_key, subtle), pair.key_digest)

    // The two pairing requests the protocol refuses: another key's digest,
    // and none.
    const refused = Object.fromEntries(device.refusals.map(({name, error}) => [name, error]))
    assert.equal(refused["a pairing request naming another key's digest"], "invalid_field")
    assert.equal(refused["a pairing request naming no key digest"], "missing_field")
  })

  test("the home sends the vector's types, and a name it does not send is unknown, a prototype's name too", () => {
    assert.deepEqual([...HOME_TYPES].sort(), device.types.home)
    for (const type of ["constructor", "__proto__", "toString"]) {
      assert.equal(decodeHome({protocol: device.protocol, type}).error, "unknown_type", type)
    }
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
    for (const field of device.continuous_fields) assert.equal(field in intent, false)
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
    const asked = {purpose: "connect", home: challenge.home, deviceKey: encoded, clientId: challenge.client_id}
    const proof = await prove(challenge, key, asked, subtle)
    assert.equal(await subtle.verify({name: "Ed25519"}, pub, fromB64url(proof.sig), signedBytes(proof)), true)
  })

  test("signs only the challenge it asked for: its own key and client, the purpose and the home", async () => {
    const {privateKey: key, publicKey: pub} = await generateKeyPair(subtle)
    const encoded = await publicKeyB64(pub, subtle)
    const own = (name) => ({...certs.challenges[name], device_key: encoded})
    const asked = {purpose: "connect", home: certs.challenges.connect.home, deviceKey: encoded, clientId: certs.challenges.connect.client_id}

    assert.equal(expectedChallenge(own("connect"), asked), true)
    for (const [name, challenge] of [
      ["another purpose", own("renew")],
      ["another home", own("other_home")],
      ["another client", own("other_client")],
      ["another device key", certs.challenges.other_device_key],
      ["a pairing", own("pair")],
      ["nothing", null]
    ]) {
      assert.equal(expectedChallenge(challenge, asked), false, name)
      await assert.rejects(prove(challenge, key, asked, subtle), (error) => error.refused === true, name)
    }
    await assert.rejects(prove(own("connect"), key, undefined, subtle), (error) => error.refused === true)
    await assert.rejects(prove(own("connect"), key, {...asked, home: undefined}, subtle), (error) => error.refused === true)
  })

  test("a key prepared for a pairing is kept beside the device, and cleared alone", async () => {
    const {privateKey: key, publicKey: pub} = await generateKeyPair(subtle)
    const deviceKey = await publicKeyB64(pub, subtle)
    const prepared = {privateKey: key, publicKey: deviceKey, keyDigest: await keyDigest(deviceKey, subtle)}

    const empty = memoryStore()
    assert.equal(await empty.loadPrepared(), null)
    await empty.savePrepared(prepared)
    assert.deepEqual(await empty.loadPrepared(), prepared)
    assert.equal(await empty.load(), null)
    await empty.clearPrepared()
    assert.equal(await empty.loadPrepared(), null)

    const record = {clientId: "pcl_1"}
    const held = memoryStore(record, null, null, prepared)
    assert.deepEqual(await held.loadPrepared(), prepared)
    assert.deepEqual(await held.load(), record)
    await held.clearPrepared()
    assert.deepEqual(await held.load(), record)
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

  test("a fresh sign-in begun here asks the home for the issuer's address and says where to approve it", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    const asked = glass.reauthenticate("cnr_ref")
    const intent = socket.sent.at(-1)
    assert.equal(intent.operation, "confirmation.reauth")
    assert.deepEqual(intent.args, {ref: "cnr_ref", method: "oidc"})
    home(socket, {protocol: device.protocol, type: "answer", id: intent.id, result: {method: "oidc", url: "https://idp.example/authorize?x=1"}})
    assert.equal(await asked, "https://idp.example/authorize?x=1")
    assert.equal(glass.outcome.cnr_ref.ok, true)
    assert.match(glass.outcome.cnr_ref.text, /approve the change there in a browser signed in/)

    // A refusal opens nothing, and says why.
    const refused = glass.reauthenticate("cnr_other")
    const second = socket.sent.at(-1)
    home(socket, {protocol: device.protocol, type: "answer", id: second.id, error: {class: "invalid_argument", message: "No OpenID Connect sign-in of this server is yours"}})
    assert.equal(await refused, null)
    assert.deepEqual(glass.outcome.cnr_other, {ok: false, text: "No OpenID Connect sign-in of this server is yours"})
  })

  test("answers only the challenge it asked for, and once: another purpose, home, client or key is left unsigned", async () => {
    for (const [name, challenge] of [
      ["a renewal it did not ask for", (key) => ({...certs.challenges.renew, device_key: key})],
      ["another home's", (key) => ({...certs.challenges.other_home, device_key: key})],
      ["another client's", (key) => ({...certs.challenges.other_client, device_key: key})],
      ["another device's", () => certs.challenges.other_device_key]
    ]) {
      const {glass, h, deviceKey} = await glassWith({certificate})
      await glass.start()
      const socket = h.socket()
      socket.onopen()
      home(socket, {protocol: device.protocol, type: "challenge", challenge: challenge(deviceKey)})
      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.deepEqual(socket.sent.map((m) => m.type), ["connect"], name)
    }

    // The one it asked for is answered; a second on the same connection is not.
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, challengeFor("connect", deviceKey))
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.deepEqual(socket.sent.map((m) => m.type), ["connect", "proof"])
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

  test("reads the person's seal after each pending list, and shows none for a read that fails", async () => {
    const {glass, h, deviceKey} = await glassWith({certificate})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    const answer = (intent, body) => home(socket, {protocol: device.protocol, type: "answer", id: intent.id, ...body})
    const last = (operation) => socket.sent.filter((m) => m.operation === operation).at(-1)
    const entry = {ref: "cnr_x", operation: "vault.create"}

    answer(last("confirmation.pending"), {result: {confirmations: [entry]}})
    await settle()
    const read = last("seal.read")
    assert.deepEqual(read.args, {})
    // The list is shown with the seal read for it, not before.
    assert.deepEqual(glass.pending, [])

    answer(read, {result: {seal: {text: "quill zephyr", glyph: "✈"}}})
    await settle()
    assert.deepEqual(glass.seal, {text: "quill zephyr", glyph: "✈"})
    assert.deepEqual(glass.pending, [entry])

    // Read again with the next list: a refused read shows none, and the
    // list still shows.
    const again = glass.refresh()
    answer(last("confirmation.pending"), {result: {confirmations: [entry]}})
    await settle()
    answer(last("seal.read"), {error: {class: "forbidden", message: "no"}})
    await again
    assert.equal(glass.seal, null)
    assert.deepEqual(glass.pending, [entry])
    assert.equal(socket.sent.filter((m) => m.operation === "seal.read").length, 2)
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
    assert.deepEqual(model.offers, ["passkey", "email", "oidc"])
  })

  test("names a command line's request by the machine it runs on", () => {
    assert.equal(promptModel({...entry, asker: {kind: "command_line", name: "laptop"}}).asker,
      "the command line on laptop")
    assert.equal(promptModel({...entry, asker: {kind: "command_line"}}).asker, "the command line")
  })

  test("offers no passkey where the browser has none, and nothing the record does not offer", () => {
    assert.deepEqual(promptModel(entry, {webauthn: false}).offers, ["email", "oidc"])
    assert.deepEqual(promptModel({...entry, methods: []}).offers, [])
    assert.deepEqual(promptModel({...entry, methods: ["passkey"]}).offers, ["passkey"])
  })

  test("begins with the person's seal, or says that none is chosen, never a default", () => {
    assert.equal(sealText({text: "quill zephyr", glyph: "✈"}), "quill zephyr ✈")
    assert.equal(sealText({text: "oak", glyph: null}), "oak")
    for (const none of [null, undefined, {}, {text: ""}, {text: 7, glyph: "✈"}]) {
      assert.equal(sealText(none), "No seal chosen yet.", JSON.stringify(none))
    }
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

  test("each prompt the glass draws begins with the person's seal, or the line that none is chosen", () => {
    const saved = globalThis.document
    globalThis.document = {createElement: (tag) => new Node(tag), createTextNode: (text) => ({text})}

    try {
      const entry = {ref: "cnr_x", operation: "vault.create", preview: {operation: "vault.create"}, methods: []}
      const hook = Object.assign(Object.create(SystemLayer), {el: new Node("div"), codeSent: new Set()})

      for (const [seal, text, state] of [
        [{text: "quill zephyr", glyph: "✈"}, "quill zephyr ✈", "set"],
        [null, "No seal chosen yet.", "none"]
      ]) {
        hook.drawGlass({status: "ready", pending: [entry, {...entry, ref: "cnr_y"}], outcome: {}, seal})
        const prompts = hook.el.children.filter((node) => node.getAttribute("data-test") === "glass-prompt")
        assert.equal(prompts.length, 2)

        for (const prompt of prompts) {
          const [first] = prompt.children
          assert.equal(first.getAttribute("data-test"), "glass-seal")
          assert.equal(first.getAttribute("data-seal"), state)
          assert.deepEqual(first.children.map((node) => node.text), [text])
        }
      }
    } finally {
      globalThis.document = saved
    }
  })

  async function mountGlassPage({stored, replies, prepared = null, hash = "#code=UjcQhGOiIAu_9xjWI7A-Fw"}) {
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
    globalThis.location = {hash, pathname: "/pair", search: "", protocol: "https:", host: "alice.example"}
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
    const store = memoryStore(stored, null, null, prepared)
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
    prepared: () => ({}),
    pair_start: ({device_key}) => ({challenge: {...certs.challenges.pair, device_key}}),
    pair_proof: () => ({client_id: "pcl_new", certificate: {...certificate, client_id: "pcl_new"}})
  }

  // The key the glass made before the invitation, as its page prepared it.
  async function preparedKey() {
    const keys = await generateKeyPair(subtle)
    const deviceKey = await publicKeyB64(keys.publicKey, subtle)
    return {privateKey: keys.privateKey, publicKey: deviceKey, keyDigest: await keyDigest(deviceKey, subtle)}
  }

  for (const pairing of ["local", "remote"]) {
    test(`a ${pairing} replacement whose new device cannot be saved keeps the old device as it was`, async () => {
      const prepared = await preparedKey()
      const page = await mountGlassPage({stored: storedDevice, replies, prepared})
      let writes = 0
      page.store.save = async () => {
        writes++
        throw new DOMException("Injected IndexedDB write failure", "QuotaExceededError")
      }
      try {
        if (pairing === "local") {
          await page.hook.glassClick({target: page.el.find("glass-replace"), preventDefault() {}})
        } else {
          await page.hook.pairRemote(
            {...prepared, code: "UjcQhGOiIAu_9xjWI7A-Fw", certify: {client_id: certs.challenges.pair.client_id}},
            certificate
          )
        }

        // The home issued the replacement and saving it was tried once.
        assert.deepEqual(page.pushed.map(({event}) => event), ["pair_start", "pair_proof"])
        assert.equal(writes, 1)
        // The device the browser held is still stored, whole.
        assert.deepEqual(await page.store.load(), storedDevice)
        assert.ok(page.el.find("glass-error"))
      } finally {
        page.hook.destroyGlass()
        page.restore()
      }
    })
  }

  test("a revocation the old connection receives while the replacement's write is in flight leaves the replacement stored", async () => {
    const prepared = await preparedKey()
    const page = await mountGlassPage({stored: storedDevice, replies, prepared})
    const deferred = () => {
      let resolve
      const promise = new Promise((done) => (resolve = done))
      return {promise, resolve}
    }
    const saveEntered = deferred()
    const allowSave = deferred()
    const saveCommitted = deferred()
    const eraseEntered = deferred()
    const allowErase = deferred()
    const eraseCommitted = deferred()
    // Two readwrite transactions, as IndexedDB orders them: the
    // replacement's put begins first, and the old connection's erasure,
    // whichever call makes it, waits for it and then commits.
    const gated = (write) => async (...args) => {
      eraseEntered.resolve()
      await allowErase.promise
      const answer = await write(...args)
      eraseCommitted.resolve()
      return answer
    }
    const save = page.store.save
    page.store.save = async (record) => {
      saveEntered.resolve()
      await allowSave.promise
      await save(record)
      saveCommitted.resolve()
      return record
    }
    page.store.clear = gated(page.store.clear)
    if (page.store.clearIf) page.store.clearIf = gated(page.store.clearIf)
    try {
      await page.hook.glass.start()
      const oldSocket = page.sockets.at(-1)
      const replacing = page.hook.glassClick({target: page.el.find("glass-replace"), preventDefault() {}})
      await saveEntered.promise
      const revoking = oldSocket.onmessage({data: JSON.stringify({protocol: device.protocol, type: "revoke", client_id: storedDevice.clientId})})
      await eraseEntered.promise
      allowSave.resolve()
      await saveCommitted.promise
      allowErase.resolve()
      await Promise.all([replacing, revoking, eraseCommitted.promise])

      assert.equal((await page.store.load())?.clientId, "pcl_new")
    } finally {
      allowSave.resolve()
      allowErase.resolve()
      page.hook.destroyGlass()
      page.restore()
    }
  })

  test("a device's own writes and erasure leave a record another device wrote", async () => {
    const store = memoryStore({...storedDevice, clientId: "pcl_new"})
    assert.equal(await store.saveIf(storedDevice.clientId, storedDevice), false)
    assert.equal(await store.clearIf(storedDevice.clientId), false)
    assert.equal((await store.load()).clientId, "pcl_new")
    assert.equal(await store.saveIf("pcl_new", {...storedDevice, clientId: "pcl_new", certificate: {renewed: true}}), true)
    assert.deepEqual((await store.load()).certificate, {renewed: true})
    assert.equal(await store.clearIf("pcl_new"), true)
    assert.equal(await store.load(), null)
    assert.equal(await store.saveIf("pcl_new", storedDevice), false, "an erased record is not written back")
  })

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

  test("a replacement in a browser that made no key for the code keeps the working device and makes a key to approve", async () => {
    const page = await mountGlassPage({stored: storedDevice, replies})
    try {
      assert.equal(await page.store.loadPrepared(), null)
      await page.hook.glassClick({target: page.el.find("glass-replace"), preventDefault() {}})

      // The device it held stands, connected as before; nothing was asked
      // of the home under the code, and a key was made whose code the page
      // shows to approve.
      assert.equal((await page.store.load()).clientId, certificate.client_id)
      assert.deepEqual(page.pushed.map((push) => push.event), ["prepared"])
      const prepared = await page.store.loadPrepared()
      assert.ok(prepared)
      assert.deepEqual(page.pushed[0].payload, {key_digest: prepared.keyDigest})
      assert.match(page.el.find("glass-error").children.map((child) => child.text).join(""), /keeps the device it holds/)
      assert.equal(page.sockets.length, 1)

      // That key's code approved, its link opened on this page: the
      // replacement now pairs with it, and only then the old device goes.
      globalThis.location.hash = "#code=UjcQhGOiIAu_9xjWI7A-Fw"
      await page.hook.onHash()
      assert.ok(page.el.find("glass-replace-ask"))
      await page.hook.glassClick({target: page.el.find("glass-replace"), preventDefault() {}})
      assert.deepEqual(page.pushed.map((push) => push.event), ["prepared", "pair_start", "pair_proof"])
      const record = await page.store.load()
      assert.equal(record.clientId, "pcl_new")
      assert.equal(record.publicKey, prepared.publicKey)
    } finally {
      page.restore()
    }
  })

  test("a replacement the home refuses keeps the working device", async () => {
    const prepared = await preparedKey()
    const refusing = {...replies, pair_start: () => ({error: "This device is not the one the pairing was approved for"})}
    const page = await mountGlassPage({stored: storedDevice, replies: refusing, prepared})
    try {
      await page.hook.glassClick({target: page.el.find("glass-replace"), preventDefault() {}})
      assert.deepEqual(page.pushed.map((push) => push.event), ["pair_start"])
      assert.equal((await page.store.load()).clientId, certificate.client_id)
      assert.equal(await page.store.loadPrepared(), prepared)
      assert.ok(page.el.find("glass-error"))
      assert.equal(page.sockets.at(-1).url, "wss://alice.example/device/websocket")
    } finally {
      page.restore()
    }
  })

  test("replacing is explicit: under the key made for the code, the new device pairs and only then replaces the stored one", async () => {
    const prepared = await preparedKey()
    const page = await mountGlassPage({stored: storedDevice, replies, prepared})
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
      assert.equal(record.publicKey, prepared.publicKey)
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

  test("a glass holding nothing pairs from the link at once, with the key it prepared", async () => {
    const prepared = await preparedKey()
    const page = await mountGlassPage({stored: null, replies, prepared})
    try {
      assert.deepEqual(
        page.pushed.map((push) => push.event),
        ["pair_start", "pair_proof"]
      )
      // Both steps name the prepared key and its digest, the one the code
      // approved.
      for (const {payload} of page.pushed) {
        assert.equal(payload.device_key, prepared.publicKey)
        assert.equal(payload.key_digest, prepared.keyDigest)
      }
      const record = await page.store.load()
      assert.equal(record.clientId, "pcl_new")
      assert.equal(record.publicKey, prepared.publicKey)
      assert.equal(record.privateKey, prepared.privateKey)
      assert.equal(await page.store.loadPrepared(), null, "the prepared key is used once")
    } finally {
      page.restore()
    }
  })

  test("a link opened on a browser that prepared no key sends nothing and says where to begin", async () => {
    const page = await mountGlassPage({stored: null, replies})
    try {
      assert.deepEqual(page.pushed, [])
      assert.equal(await page.store.load(), null)
      const error = page.el.find("glass-error")
      assert.ok(error)
      assert.match(error.children.map((child) => child.text).join(""), /made no key for this pairing/)
    } finally {
      page.restore()
    }
  })

  test("a page opened with no device and no code prepares a key once and sends its digest", async () => {
    const page = await mountGlassPage({stored: null, replies, hash: ""})
    try {
      assert.deepEqual(page.pushed.map((push) => push.event), ["prepared"])
      const prepared = await page.store.loadPrepared()
      assert.ok(prepared)
      assert.equal(prepared.privateKey.extractable, false)
      assert.equal(prepared.keyDigest, await keyDigest(prepared.publicKey, subtle))
      assert.deepEqual(page.pushed[0].payload, {key_digest: prepared.keyDigest})
      assert.equal(await page.store.load(), null)
      assert.deepEqual(page.sockets, [])
    } finally {
      page.restore()
    }

    // Opened again, the same key's digest: nothing new is made.
    const prepared = await page.store.loadPrepared()
    const again = await mountGlassPage({stored: null, replies, hash: "", prepared})
    try {
      assert.deepEqual(again.pushed, [{event: "prepared", payload: {key_digest: prepared.keyDigest}}])
      assert.equal(await again.store.loadPrepared(), prepared)
    } finally {
      again.restore()
    }
  })

  test("a link opened on the page that shows the code, a fragment change alone, pairs with the prepared key", async () => {
    const page = await mountGlassPage({stored: null, replies, hash: ""})
    try {
      const prepared = await page.store.loadPrepared()
      assert.deepEqual(page.pushed.map((push) => push.event), ["prepared"])

      // The page does not load again: only the address's fragment changes.
      globalThis.location.hash = "#code=UjcQhGOiIAu_9xjWI7A-Fw"
      await page.hook.onHash()

      assert.deepEqual(page.pushed.map((push) => push.event), ["prepared", "pair_start", "pair_proof"])
      assert.equal(page.pushed[1].payload.invitation_secret, "UjcQhGOiIAu_9xjWI7A-Fw")
      assert.equal(page.pushed[1].payload.key_digest, prepared.keyDigest)
      // The code left the address at once.
      assert.equal(page.replaced.at(-1)[2], "/pair")
      const record = await page.store.load()
      assert.equal(record.clientId, "pcl_new")
      assert.equal(record.publicKey, prepared.publicKey)
      assert.equal(page.sockets.at(-1).url, "wss://alice.example/device/websocket")

      // A fragment naming no code changes nothing.
      globalThis.location.hash = "#other"
      await page.hook.onHash()
      assert.equal(page.pushed.length, 3)
    } finally {
      page.restore()
    }
  })

  test("a refused pairing keeps the prepared key, so the person can approve its code again", async () => {
    const prepared = await preparedKey()
    const refusing = {...replies, pair_start: () => ({error: "This device is not the one the pairing was approved for: approve the code this device shows"})}
    const page = await mountGlassPage({stored: null, replies: refusing, prepared})
    try {
      assert.deepEqual(page.pushed.map((push) => push.event), ["pair_start"])
      assert.equal(page.pushed[0].payload.key_digest, prepared.keyDigest)
      assert.equal(await page.store.load(), null)
      assert.equal(await page.store.loadPrepared(), prepared)
      assert.ok(page.el.find("glass-error"))
    } finally {
      page.restore()
    }
  })
})

// ---------------------------------------------------------------------------
// A device certified at another home
// ---------------------------------------------------------------------------

const HOME = "https://alice.example"
const ISSUER = "https://a.example"
const EVIL = "https://evil.example"

// A certificate the person's own home issued for this device, for this home.
function remoteCertificate(deviceKey, overrides = {}) {
  return {
    ...certs.certificates.local.certificate,
    device_key: deviceKey,
    issuer: ISSUER,
    audience: HOME,
    subject: {kind: "identity", identifier: "per_" + "ab".repeat(32), key_epoch: "sha256:" + "0".repeat(64)},
    ...overrides
  }
}

// A fetch answering as the issuer's renewal does, recording each call.
function issuerFetch({refuse = null, unreachable = false, replacement} = {}) {
  const calls = []
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body)
    calls.push({url, init, body})
    if (unreachable) throw new TypeError("failed to fetch")
    if (refuse) {
      return {ok: false, status: refuse, json: async () => ({code: "conflict", message: "Your keys changed since this device was certified; certify it again at your home."})}
    }
    if (!body.proof) {
      return {ok: true, status: 200, json: async () => ({challenge: {...certs.challenges.renew, home: ISSUER, device_key: body.certificate.device_key}})}
    }
    return {ok: true, status: 200, json: async () => ({certificate: replacement(body)})}
  }
  return {fetch, calls}
}

async function remoteGlass({clock, expiresAt, fetchOptions = {}}) {
  const keys = await generateKeyPair(subtle)
  const deviceKey = await publicKeyB64(keys.publicKey, subtle)
  const certificate = remoteCertificate(deviceKey, expiresAt ? {expires_at: expiresAt} : {})
  const later = (body) => ({...body.certificate, not_before: certificate.expires_at - 1_000, expires_at: certificate.expires_at + 3_600_000})
  const issuer = issuerFetch({replacement: later, ...fetchOptions})
  const store = memoryStore({privateKey: keys.privateKey, publicKey: deviceKey, clientId: certificate.client_id, certificate})
  const h = harness({certificate, clock})
  const glass = new Glass({
    url: "wss://alice.example/device/websocket",
    home: HOME,
    fetch: issuer.fetch,
    socket: h.makeSocket,
    store,
    subtle,
    now: h.now,
    setTimer: h.setTimer,
    clearTimer: h.clearTimer
  })
  return {glass, store, h, keys, deviceKey, certificate, issuer}
}

describe("a certificate another home issued", () => {
  test("the helpers read what comes back, tell the issuer apart, and name a home", () => {
    const certificate = remoteCertificate("k")
    assert.deepEqual(certificateFromFragment("#certificate=" + b64url(new TextEncoder().encode(JSON.stringify(certificate)))), certificate)
    assert.equal(certificateFromFragment("#code=x"), null)
    assert.equal(certificateFromFragment("#certificate=not json"), null)

    assert.equal(issuedElsewhere(certificate, HOME), true)
    assert.equal(issuedElsewhere({...certificate, issuer: HOME}, HOME), false)

    assert.equal(certifies(certificate, {deviceKey: "k", clientId: certificate.client_id, home: HOME}), true)
    assert.equal(certifies(certificate, {deviceKey: "other", clientId: certificate.client_id, home: HOME}), false)
    assert.equal(certifies(certificate, {deviceKey: "k", clientId: "pcl_other", home: HOME}), false)
    assert.equal(certifies(certificate, {deviceKey: "k", clientId: certificate.client_id, home: "https://elsewhere.example"}), false)
    assert.equal(certifies(certificate, {deviceKey: "k", clientId: certificate.client_id, home: HOME, issuer: ISSUER, athanor: certificate.athanor}), true)
    assert.equal(certifies(certificate, {deviceKey: "k", clientId: certificate.client_id, home: HOME, issuer: EVIL}), false)
    assert.equal(certifies(certificate, {deviceKey: "k", clientId: certificate.client_id, home: HOME, athanor: "ath_other"}), false)
    assert.equal(certifies(certificate, {deviceKey: undefined, clientId: certificate.client_id, home: HOME}), false)

    const asked = {home: ISSUER, client: certificate.client_id, audience: HOME, athanor: certificate.athanor, at: 1}
    assert.equal(answersCertify(certificate, asked, {deviceKey: "k", home: HOME}), true)
    assert.equal(answersCertify(certificate, null, {deviceKey: "k", home: HOME}), false)
    assert.equal(answersCertify(certificate, {...asked, home: EVIL}, {deviceKey: "k", home: HOME}), false)
    assert.equal(answersCertify(certificate, {...asked, athanor: "ath_other"}, {deviceKey: "k", home: HOME}), false)
    assert.equal(answersCertify(certificate, {...asked, client: "pcl_other"}, {deviceKey: "k", home: HOME}), false)
    assert.equal(answersCertify(certificate, {...asked, audience: "https://elsewhere.example"}, {deviceKey: "k", home: HOME}), false)
    assert.equal(answersCertify(certificate, asked, {deviceKey: "other", home: HOME}), false)

    assert.equal(homeOrigin("a.example"), "https://a.example")
    assert.equal(homeOrigin(" https://A.example/carry?x=1 "), "https://a.example")
    assert.equal(homeOrigin("javascript:alert(1)"), null)
    assert.equal(homeOrigin("https://user:pass@a.example"), null)
    assert.equal(homeOrigin(""), null)

    const url = certifyUrl(ISSUER, {audience: HOME, athanor: "ath_hub", client_id: "pcl_hub", device_key: "k", extra: "dropped"})
    assert.ok(url.startsWith(ISSUER + "/carry#certify="))
    const request = JSON.parse(new TextDecoder().decode(fromB64url(url.split("#certify=")[1])))
    assert.deepEqual(request, {athanor: "ath_hub", audience: HOME, client_id: "pcl_hub", device_key: "k"})
  })

  test("is renewed at its issuer with no credentials: the device key proves the issuer's challenge", async () => {
    const keys = await generateKeyPair(subtle)
    const deviceKey = await publicKeyB64(keys.publicKey, subtle)
    const certificate = remoteCertificate(deviceKey)
    const replacement = {...certificate, expires_at: certificate.expires_at + 1}
    const {fetch, calls} = issuerFetch({replacement: () => replacement})

    assert.deepEqual(await renewElsewhere({certificate, privateKey: keys.privateKey, deviceKey, clientId: certificate.client_id, fetch, subtle}), replacement)
    assert.deepEqual(calls.map((call) => call.url), [`${ISSUER}/certify/v1/renew`, `${ISSUER}/certify/v1/renew`])
    for (const {init} of calls) {
      assert.equal(init.credentials, "omit")
      assert.equal(init.method, "POST")
      assert.equal(init.headers["content-type"], "application/json")
    }
    assert.deepEqual(calls[0].body, {certificate})
    const proof = calls[1].body.proof
    assert.equal(await subtle.verify({name: "Ed25519"}, keys.publicKey, fromB64url(proof.sig), signedBytes(proof)), true)
  })

  test("a refusal that ends the certification is told apart from a home that could not answer", async () => {
    const keys = await generateKeyPair(subtle)
    const deviceKey = await publicKeyB64(keys.publicKey, subtle)
    const certificate = remoteCertificate(deviceKey)
    const ask = (options) =>
      renewElsewhere({certificate, privateKey: keys.privateKey, deviceKey, clientId: certificate.client_id, fetch: issuerFetch(options).fetch, subtle})

    for (const status of [401, 403, 404, 409]) await assert.rejects(ask({refuse: status}), (error) => error.ended === true)
    for (const status of [429, 500, 503]) await assert.rejects(ask({refuse: status}), (error) => error.ended === false)
    await assert.rejects(ask({unreachable: true}), (error) => error.ended === false)
  })

  test("a challenge the issuer answers that is not its renewal of this device is not signed, and nothing more is sent", async () => {
    const keys = await generateKeyPair(subtle)
    const deviceKey = await publicKeyB64(keys.publicKey, subtle)
    const certificate = remoteCertificate(deviceKey)

    for (const [name, relayed] of [
      // A hub's own `connect` challenge, relayed: the proof would let
      // whoever relays it connect there as this device.
      ["this home's connect challenge", {...certs.challenges.connect, home: HOME, device_key: deviceKey}],
      ["a renewal of another home", {...certs.challenges.renew, home: EVIL, device_key: deviceKey}],
      ["a renewal for another client", {...certs.challenges.renew, home: ISSUER, client_id: "pcl_other", device_key: deviceKey}],
      ["a renewal for another key", {...certs.challenges.renew, home: ISSUER}]
    ]) {
      const calls = []
      const fetch = async (url, init) => {
        calls.push({url, body: JSON.parse(init.body)})
        return {ok: true, status: 200, json: async () => ({challenge: relayed})}
      }
      await assert.rejects(
        renewElsewhere({certificate, privateKey: keys.privateKey, deviceKey, clientId: certificate.client_id, fetch, subtle}),
        (error) => error.ended === false && error.refused === true,
        name
      )
      assert.equal(calls.length, 1, name)
      assert.equal("proof" in calls[0].body, false, name)
    }
  })

  test("a replacement the issuer answers for another device, client, home, issuer or athanor is neither kept nor presented", async () => {
    for (const [name, change] of [
      ["another device key", {device_key: "another-key"}],
      ["another client", {client_id: "pcl_other"}],
      ["another home", {audience: "https://elsewhere.example"}],
      ["another issuer", {issuer: EVIL}],
      ["another athanor", {athanor: "ath_other"}]
    ]) {
      const replacement = (body) => ({...body.certificate, expires_at: body.certificate.expires_at + 3_600_000, ...change})
      const {glass, h, store, certificate, issuer} = await remoteGlass({clock: 0, expiresAt: 1, fetchOptions: {replacement}})
      h.advance(10)
      await glass.start()
      await until(() => issuer.calls.length === 2 && glass.status === "waiting", `the refused replacement: ${name}`)
      assert.deepEqual((await store.load()).certificate, certificate, name)
      assert.equal(h.sockets.length, 0, name)
    }
  })

  test("expired, it is renewed at the issuer before any connection, which then presents the replacement", async () => {
    const {glass, h, store, certificate, issuer} = await remoteGlass({clock: 0, expiresAt: 1})
    h.advance(10)
    await glass.start()
    await until(() => h.sockets.length === 1, "the connection after the renewal")

    assert.equal(issuer.calls.length, 2)
    const socket = h.socket()
    socket.onopen()
    assert.deepEqual(socket.sent.map((m) => m.type), ["connect"])
    assert.equal(socket.sent[0].certificate.expires_at, certificate.expires_at + 3_600_000)
    assert.equal((await store.load()).certificate.expires_at, certificate.expires_at + 3_600_000)
  })

  test("at half its life it is renewed at the issuer and presented on a new connection; never `renew` to this home", async () => {
    const {glass, h, deviceKey, certificate, issuer} = await remoteGlass({})
    await glass.start()
    const first = h.socket()
    first.onopen()
    await proved(first, deviceKey)
    home(first, standing(certificate))
    await settle()

    h.timers.find((t) => t.at === renewAt(certificate)).fun()
    await until(() => h.sockets.length === 2, "the new connection")
    assert.equal(first.closed, true)
    assert.equal(issuer.calls.length, 2)
    const second = h.socket()
    second.onopen()
    assert.deepEqual(second.sent.map((m) => m.type), ["connect"])
    assert.ok(!first.sent.some((m) => m.type === "renew"))
  })

  test("a certification the issuer ended offers to certify again; a close 4408 renews there, not here", async () => {
    const {glass, h, deviceKey, certificate} = await remoteGlass({fetchOptions: {refuse: 409}})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    // At half its life: the connection stands, and the offer is made.
    h.timers.find((t) => t.at === renewAt(certificate)).fun()
    await until(() => glass.certifyAgain, "the offer")
    assert.equal(glass.status, "ready")
    assert.deepEqual(glass.certifyRequest(), {audience: HOME, athanor: certificate.athanor, client_id: certificate.client_id, device_key: deviceKey})

    // This home refused the certificate: renewed at its issuer, which ended it.
    socket.onclose({code: 4408, reason: "unauthenticated"})
    h.timers.at(-1).fun()
    await until(() => glass.status === "recertify", "recertify")
    assert.equal(h.sockets.length, 1, "no connection is opened under a certificate the issuer ended")
    assert.equal(glassStatus(glass).state, "recertify")
  })

  test("an issuer that cannot answer is asked again shortly, the connection standing meanwhile", async () => {
    const {glass, h, deviceKey, certificate, issuer} = await remoteGlass({fetchOptions: {unreachable: true}})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()

    h.timers.find((t) => t.at === renewAt(certificate)).fun()
    await until(() => issuer.calls.length === 1 && h.timers.some((t) => t.at === h.now() + RENEW_RETRY_MS), "the retry")
    assert.equal(glass.status, "ready")
    assert.equal(glass.certifyAgain, false)
    assert.equal(socket.closed, false)
  })

  // The review's lost-home case: the person's home was lost, and they
  // restored elsewhere; this home refuses the certificate, and the home
  // that issued it never answers again.
  test("after a close 4408, an issuer unreachable three times in a row offers to certify again, and is still asked", async () => {
    const {glass, h, deviceKey, certificate, issuer} = await remoteGlass({fetchOptions: {unreachable: true}})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()
    socket.onclose({code: 4408, reason: "unauthenticated"})

    for (let round = 0; round < 8; round++) {
      const timer = h.timers.at(-1)
      if (timer) timer.fun()
      await until(() => issuer.calls.length >= round + 1, `a renewal try ${round}`)
      await settle()
      assert.equal(glass.certifyAgain, round + 1 >= UNREACHABLE_OFFER, `the offer after ${round + 1} tries`)
    }
    assert.ok(issuer.calls.length >= 8, "the glass keeps asking the unreachable issuer")
    assert.equal(glass.certifyReason, "unreachable")
    assert.deepEqual(glass.certifyRequest(), {audience: HOME, athanor: certificate.athanor, client_id: certificate.client_id, device_key: deviceKey})
    assert.equal(h.sockets.length, 1, "no connection is opened under the refused certificate")
  })

  // The threshold by its number, not the constant: two unreachable
  // renewals after a 4408 are not yet a lost home, and the third is.
  test("after a close 4408, two unreachable renewals make no offer; the third does", async () => {
    assert.equal(UNREACHABLE_OFFER, 3)
    const {glass, h, deviceKey, certificate, issuer} = await remoteGlass({fetchOptions: {unreachable: true}})
    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()
    socket.onclose({code: 4408, reason: "unauthenticated"})

    for (const tries of [1, 2]) {
      h.timers.at(-1).fun()
      await until(() => issuer.calls.length >= tries && glass.status === "waiting", `renewal try ${tries}`)
      await settle()
      assert.equal(glass.certifyAgain, false, `no offer after ${tries} unreachable renewals`)
      assert.equal(glass.certifyReason, null)
    }

    h.timers.at(-1).fun()
    await until(() => issuer.calls.length >= 3, "renewal try 3")
    await settle()
    assert.equal(glass.certifyAgain, true, "the offer after 3 unreachable renewals")
    assert.equal(glass.certifyReason, "unreachable")
  })

  // An issuer this home never refused the certificate for is only slow:
  // the glass keeps asking it, and does not offer to certify again.
  test("without a close 4408, an issuer unreachable however often makes no offer", async () => {
    const {glass, h, issuer} = await remoteGlass({clock: 0, expiresAt: 1, fetchOptions: {unreachable: true}})
    h.advance(10)
    await glass.start()
    await until(() => issuer.calls.length >= 1 && glass.status === "waiting", "the first renewal at the issuer")

    for (let tries = 2; tries <= 6; tries++) {
      h.timers.at(-1).fun()
      await until(() => issuer.calls.length >= tries && glass.status === "waiting", `renewal try ${tries}`)
      await settle()
    }

    assert.ok(issuer.calls.length >= 6, "the issuer was asked six times")
    assert.equal(glass.refusedHere, false, "this home never refused the certificate")
    assert.equal(glass.certifyAgain, false)
    assert.equal(glass.certifyReason, null)
    assert.equal(h.sockets.length, 0, "no connection is opened under the expired certificate")
  })

  test("the offer made while the issuer could not be reached is withdrawn once it renews", async () => {
    const keys = await generateKeyPair(subtle)
    const deviceKey = await publicKeyB64(keys.publicKey, subtle)
    const certificate = remoteCertificate(deviceKey)
    let reachable = false
    const calls = []
    const fetch = async (url, init) => {
      const body = JSON.parse(init.body)
      calls.push(body)
      if (!reachable) throw new TypeError("failed to fetch")
      if (!body.proof) return {ok: true, status: 200, json: async () => ({challenge: {...certs.challenges.renew, home: ISSUER, device_key: deviceKey}})}
      return {ok: true, status: 200, json: async () => ({certificate: {...certificate, expires_at: certificate.expires_at + 3_600_000}})}
    }
    const store = memoryStore({privateKey: keys.privateKey, publicKey: deviceKey, clientId: certificate.client_id, certificate})
    const h = harness({certificate})
    const glass = new Glass({url: "wss://alice.example/device/websocket", fetch, socket: h.makeSocket, store, subtle, now: h.now, setTimer: h.setTimer, clearTimer: h.clearTimer})
    assert.equal(glass.home, HOME, "the home is the device channel's origin")

    await glass.start()
    const socket = h.socket()
    socket.onopen()
    await proved(socket, deviceKey)
    home(socket, standing(certificate))
    await settle()
    socket.onclose({code: 4408, reason: "unauthenticated"})
    for (let round = 0; round < UNREACHABLE_OFFER; round++) {
      h.timers.at(-1).fun()
      await until(() => calls.length >= round + 1, `a renewal try ${round}`)
      await settle()
    }
    assert.equal(glass.certifyAgain, true)

    reachable = true
    h.timers.at(-1).fun()
    await until(() => h.sockets.length === 2, "the connection under the replacement")
    assert.equal(glass.certifyAgain, false)
    assert.equal((await store.load()).certificate.expires_at, certificate.expires_at + 3_600_000)
  })
})

describe("the glass's page, for a person whose keys are at another home", () => {
  // A page as small as the hook needs, as above.
  class Node {
    constructor(tag) {
      Object.assign(this, {tag, attributes: {}, children: [], parent: null})
    }
    setAttribute(name, value) {
      this.attributes[name] = String(value)
    }
    getAttribute(name) {
      return name in this.attributes ? this.attributes[name] : null
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
    addEventListener() {}
    removeEventListener() {}
    closest() {
      for (let node = this; node; node = node.parent) if (node.getAttribute && node.getAttribute("data-action") !== null) return node
      return null
    }
    find(test) {
      for (const child of this.children) {
        if (child.getAttribute && child.getAttribute("data-test") === test) return child
        const found = child.find && child.find(test)
        if (found) return found
      }
      return null
    }
    text() {
      return this.children.map((child) => (child.text !== undefined && typeof child.text === "string" ? child.text : child.text ? child.text() : "")).join("")
    }
  }

  async function mountPage({hash, stored = null, pending = null, asked = null, prepared = null, replies = {}, fetch = null}) {
    const saved = {document: globalThis.document, location: globalThis.location, history: globalThis.history, WebSocket: globalThis.WebSocket, fetch: globalThis.fetch}
    if (fetch) globalThis.fetch = fetch
    const sockets = []
    const pushed = []
    const assigned = []

    globalThis.document = {
      visibilityState: "visible",
      createElement: (tag) => new Node(tag),
      createTextNode: (text) => ({text}),
      addEventListener() {},
      removeEventListener() {}
    }
    globalThis.location = {hash, pathname: "/pair", search: "", protocol: "https:", host: "alice.example", assign: (to) => assigned.push(to)}
    globalThis.history = {replaceState: () => {}}
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
    const store = memoryStore(stored, pending, asked, prepared)
    const hook = Object.assign(Object.create(SystemLayer), {
      el,
      store,
      pushEvent(event, payload, reply) {
        pushed.push({event, payload})
        reply(replies[event](payload))
      }
    })

    await hook.mounted()
    const restore = () => {
      for (const timer of [hook.glass.retryTimer, hook.glass.renewTimer]) if (timer) hook.glass.clearTimer(timer)
      hook.glass.device = null
      Object.assign(globalThis, saved)
    }
    return {hook, el, store, sockets, pushed, assigned, restore}
  }

  const certify = {audience: HOME, athanor: "ath_hub", client_id: "pcl_new"}
  // What the person asked of their home as they named it.
  const askedOf = (request, at = Date.now()) => ({home: ISSUER, client: request.client_id, audience: request.audience, athanor: request.athanor, at})
  const fragmentOf = (certificate) => "#certificate=" + b64url(new TextEncoder().encode(JSON.stringify(certificate)))
  const challengeMessage = (challenge) => ({data: JSON.stringify({protocol: device.protocol, type: "challenge", challenge})})

  test("a link opened on the page already showing the code, for a person whose keys are elsewhere, says to certify there", async () => {
    const page = await mountPage({
      hash: "",
      replies: {
        prepared: () => ({}),
        pair_start: ({device_key}) => ({challenge: {...certs.challenges.pair, device_key}, certify})
      }
    })
    try {
      assert.equal(page.el.find("glass-status").getAttribute("data-state"), "unpaired")
      const prepared = await page.store.loadPrepared()

      globalThis.location.hash = "#code=UjcQhGOiIAu_9xjWI7A-Fw"
      await page.hook.onHash()

      assert.deepEqual(page.pushed.map((p) => p.event), ["prepared", "pair_start"])
      assert.equal((await page.store.loadPending()).keyDigest, prepared.keyDigest)
      assert.ok(page.el.find("glass-certify"))
      assert.equal(page.el.find("glass-status").getAttribute("data-state"), "certify")
    } finally {
      page.restore()
    }

    // A refused pairing says so, and the page reads unpaired again.
    const refused = await mountPage({
      hash: "",
      replies: {prepared: () => ({}), pair_start: () => ({error: "This device is not the one the pairing was approved for"})}
    })
    try {
      globalThis.location.hash = "#code=UjcQhGOiIAu_9xjWI7A-Fw"
      await refused.hook.onHash()
      assert.ok(refused.el.find("glass-error"))
      assert.equal(refused.el.find("glass-status").getAttribute("data-state"), "unpaired")
    } finally {
      refused.restore()
    }
  })

  test("the pairing keeps its code and key for the invitation's life, asks for their home, and goes there to certify", async () => {
    const keys = await generateKeyPair(subtle)
    const deviceKey = await publicKeyB64(keys.publicKey, subtle)
    const prepared = {privateKey: keys.privateKey, publicKey: deviceKey, keyDigest: await keyDigest(deviceKey, subtle)}
    const page = await mountPage({
      hash: "#code=UjcQhGOiIAu_9xjWI7A-Fw",
      prepared,
      replies: {pair_start: ({device_key}) => ({challenge: {...certs.challenges.pair, device_key}, certify})}
    })
    try {
      assert.deepEqual(page.pushed.map((p) => p.event), ["pair_start"])
      assert.equal(page.pushed[0].payload.key_digest, prepared.keyDigest)
      const pending = await page.store.loadPending()
      assert.equal(pending.code, "UjcQhGOiIAu_9xjWI7A-Fw")
      assert.deepEqual(pending.certify, certify)
      // The prepared key moves to the pending pairing, with its digest.
      assert.equal(pending.publicKey, prepared.publicKey)
      assert.equal(pending.keyDigest, prepared.keyDigest)
      assert.equal(await page.store.loadPrepared(), null)
      assert.equal(await page.store.load(), null)
      assert.ok(page.el.find("glass-certify"))
      assert.equal(page.el.find("glass-status").getAttribute("data-state"), "certify")
      assert.deepEqual(page.sockets, [])

      page.hook.certifyAt("not a home!")
      page.hook.certifyAt("alice.example")
      assert.deepEqual(page.assigned, [])
      assert.ok(page.el.find("glass-error"))

      // The person's click on the form's button submits it: no glass
      // action claims the click.
      const submit = page.el.find("glass-home-submit")
      let prevented = false
      await page.hook.glassClick({target: submit, preventDefault: () => (prevented = true)})
      assert.equal(prevented, false)
      assert.equal(await page.store.loadCertify(), null, "nothing is asked of a home that is none")
      submit.parent.elements = {home: {value: "a.example"}}
      await page.hook.glassSubmit({target: submit.parent, preventDefault() {}})
      assert.equal(page.assigned.length, 1)
      const [to] = page.assigned
      assert.ok(to.startsWith("https://a.example/carry#certify="))
      const request = JSON.parse(new TextDecoder().decode(fromB64url(to.split("#certify=")[1])))
      assert.deepEqual(request, {...certify, device_key: pending.publicKey})

      // What was asked of that home is kept, before the browser goes there.
      const asked = await page.store.loadCertify()
      assert.deepEqual({...asked, at: 0}, {...askedOf(certify), at: 0})
      assert.equal(typeof asked.at, "number")
    } finally {
      page.restore()
    }
  })

  test("the certificate their home sends back completes the pending pairing, with it, and connects", async () => {
    const keys = await generateKeyPair(subtle)
    const publicKey = await publicKeyB64(keys.publicKey, subtle)
    const pending = {code: "UjcQhGOiIAu_9xjWI7A-Fw", privateKey: keys.privateKey, publicKey, keyDigest: await keyDigest(publicKey, subtle), certify, at: Date.now()}
    const certificate = remoteCertificate(publicKey, {client_id: "pcl_new", athanor: "ath_hub", not_before: Date.now(), expires_at: Date.now() + 3_600_000})

    const page = await mountPage({
      hash: fragmentOf(certificate),
      pending,
      asked: askedOf(certify),
      replies: {
        pair_start: ({device_key}) => ({challenge: {...certs.challenges.pair, client_id: "pcl_new", device_key}}),
        pair_proof: () => ({client_id: "pcl_new", certificate})
      }
    })
    try {
      assert.deepEqual(page.pushed.map((p) => p.event), ["pair_start", "pair_proof"])
      for (const {payload} of page.pushed) {
        assert.deepEqual(payload.certificate, certificate)
        assert.equal(payload.invitation_secret, pending.code)
        assert.equal(payload.device_key, publicKey)
        assert.equal(payload.key_digest, pending.keyDigest)
      }
      assert.deepEqual((await page.store.load()).certificate, certificate)
      assert.equal(await page.store.loadPending(), null)
      assert.equal(await page.store.loadCertify(), null)
      assert.equal(page.sockets.length, 1)
    } finally {
      page.restore()
    }
  })

  test("a pairing challenge for another client than the one reserved is not signed, and the pairing ends", async () => {
    const keys = await generateKeyPair(subtle)
    const publicKey = await publicKeyB64(keys.publicKey, subtle)
    const pending = {code: "UjcQhGOiIAu_9xjWI7A-Fw", privateKey: keys.privateKey, publicKey, certify, at: Date.now()}
    const certificate = remoteCertificate(publicKey, {client_id: "pcl_new", athanor: "ath_hub", not_before: Date.now(), expires_at: Date.now() + 3_600_000})

    const page = await mountPage({
      hash: fragmentOf(certificate),
      pending,
      asked: askedOf(certify),
      replies: {
        pair_start: ({device_key}) => ({challenge: {...certs.challenges.pair_other_client, device_key}}),
        pair_proof: () => assert.fail("no proof is sent")
      }
    })
    try {
      assert.deepEqual(page.pushed.map((p) => p.event), ["pair_start"])
      assert.equal(await page.store.load(), null)
      assert.equal(await page.store.loadPending(), null)
      assert.ok(page.el.find("glass-error"))
    } finally {
      page.restore()
    }
  })

  test("a certificate that does not answer the pending pairing's request, or with no request standing, completes nothing", async () => {
    const keys = await generateKeyPair(subtle)
    const publicKey = await publicKeyB64(keys.publicKey, subtle)
    const replies = {pair_start: () => assert.fail("nothing is sent"), pair_proof: () => assert.fail("nothing is sent")}
    const pending = (at = Date.now()) => ({code: "c", privateKey: keys.privateKey, publicKey, certify, at})
    const answering = remoteCertificate(publicKey, {client_id: "pcl_new", athanor: "ath_hub"})

    for (const [name, record, asked, certificate] of [
      ["another device", pending(), askedOf(certify), {...answering, device_key: "another-key"}],
      ["another issuer", pending(), askedOf(certify), {...answering, issuer: EVIL}],
      ["another athanor", pending(), askedOf(certify), {...answering, athanor: "ath_other"}],
      ["no request", pending(), null, answering],
      ["a request past its life", pending(), askedOf(certify, Date.now() - PENDING_MS), answering],
      ["a pairing past its life", pending(Date.now() - PENDING_MS), askedOf(certify), answering]
    ]) {
      const page = await mountPage({hash: fragmentOf(certificate), pending: record, asked, replies})
      try {
        assert.deepEqual(page.pushed, [], name)
        assert.equal(await page.store.load(), null, name)
        assert.ok(page.el.find("glass-error"), name)
      } finally {
        page.restore()
      }
    }
  })

  test("a certificate for the device the glass holds is presented in place of its own, and kept once this home stands it", async () => {
    const keys = await generateKeyPair(subtle)
    const publicKey = await publicKeyB64(keys.publicKey, subtle)
    const old = remoteCertificate(publicKey, {expires_at: 2})
    const fresh = remoteCertificate(publicKey, {not_before: Date.now(), expires_at: Date.now() + 3_600_000})
    const stored = {privateKey: keys.privateKey, publicKey, clientId: old.client_id, certificate: old}
    const asked = askedOf({client_id: old.client_id, audience: HOME, athanor: old.athanor})

    const page = await mountPage({hash: fragmentOf(fresh), stored, asked})
    try {
      assert.deepEqual(page.pushed, [])
      assert.equal(await page.store.loadCertify(), null)
      assert.deepEqual((await page.store.load()).certificate, old, "not kept before this home stands it")

      const [socket] = page.sockets
      socket.onopen()
      assert.deepEqual(socket.sent.map((m) => m.type), ["connect"])
      assert.deepEqual(socket.sent[0].certificate, fresh)
      socket.onmessage(challengeMessage({...certs.challenges.connect, home: HOME, client_id: old.client_id, device_key: publicKey}))
      await until(() => socket.sent.length === 2, "the proof")
      socket.onmessage({data: JSON.stringify(standing(fresh))})
      await until(() => page.hook.glass.status === "ready", "standing")
      assert.deepEqual((await page.store.load()).certificate, fresh)
    } finally {
      page.restore()
    }
  })

  test("a certificate this home refuses is dropped, and the stored one stays", async () => {
    const keys = await generateKeyPair(subtle)
    const publicKey = await publicKeyB64(keys.publicKey, subtle)
    const old = remoteCertificate(publicKey, {not_before: Date.now() - 1_000, expires_at: Date.now() + 3_600_000})
    const fresh = remoteCertificate(publicKey, {not_before: Date.now(), expires_at: Date.now() + 7_200_000})
    const stored = {privateKey: keys.privateKey, publicKey, clientId: old.client_id, certificate: old}
    const asked = askedOf({client_id: old.client_id, audience: HOME, athanor: old.athanor})

    const page = await mountPage({hash: fragmentOf(fresh), stored, asked, fetch: async () => new Promise(() => {})})
    try {
      const [socket] = page.sockets
      socket.onopen()
      assert.deepEqual(socket.sent[0].certificate, fresh)
      socket.onclose({code: 4408, reason: "unauthenticated"})
      assert.equal(page.hook.glass.candidate, null)
      assert.deepEqual((await page.store.load()).certificate, old)
    } finally {
      page.restore()
    }
  })

  // The stored device's half of the adoption: only a certificate answering
  // what the person asked of their home is presented, and none is kept
  // before this home stands it.
  test("a certificate that does not answer the request this device made is neither presented nor kept", async () => {
    const keys = await generateKeyPair(subtle)
    const publicKey = await publicKeyB64(keys.publicKey, subtle)
    const old = remoteCertificate(publicKey, {not_before: Date.now() - 1_000, expires_at: Date.now() + 3_600_000})
    const stored = {privateKey: keys.privateKey, publicKey, clientId: old.client_id, certificate: old}
    const asked = askedOf({client_id: old.client_id, audience: HOME, athanor: old.athanor})
    const fresh = {...old, not_before: Date.now(), expires_at: Date.now() + 7_200_000}

    for (const [name, certificate] of [
      ["another device key", {...fresh, device_key: "another-key"}],
      ["another issuer", {...fresh, issuer: EVIL}],
      ["another athanor", {...fresh, athanor: "ath_other"}],
      ["another client", {...fresh, client_id: "pcl_other"}],
      ["another home", {...fresh, audience: "https://elsewhere.example"}]
    ]) {
      const page = await mountPage({hash: fragmentOf(certificate), stored, asked})
      try {
        assert.deepEqual((await page.store.load()).certificate, old, name)
        assert.deepEqual(await page.store.loadCertify(), asked, `${name}: the request still stands`)
        const [socket] = page.sockets
        socket.onopen()
        assert.deepEqual(socket.sent[0].certificate, old, name)
        assert.ok(page.el.find("glass-error"), name)
      } finally {
        page.restore()
      }
    }
  })

  // The review's oracle: a crafted `/pair#certificate=` link at this home,
  // naming another issuer, once made the glass take that issuer and sign
  // this home's own `connect` challenge for it.
  test("a crafted certificate link adopts no issuer, posts nothing and signs nothing", async () => {
    const keys = await generateKeyPair(subtle)
    const publicKey = await publicKeyB64(keys.publicKey, subtle)
    const legit = remoteCertificate(publicKey, {client_id: "pcl_hub", not_before: Date.now() - 1_000, expires_at: Date.now() + 3_600_000})
    // Knows only the device key, the client id and the home: no signature.
    const crafted = {...legit, issuer: EVIL, not_before: 1, expires_at: 2, sig: "x"}
    const stored = {privateKey: keys.privateKey, publicKey, clientId: "pcl_hub", certificate: legit}
    // This home's own `connect` challenge, as its device channel issues it
    // to whoever opens a socket.
    const hConnect = {...certs.challenges.connect, home: HOME, client_id: "pcl_hub", device_key: publicKey}
    const calls = []
    const fetch = async (url, init) => {
      const body = JSON.parse(init.body)
      calls.push({url, body})
      if (!body.proof) return {ok: true, status: 200, json: async () => ({challenge: hConnect})}
      return {ok: false, status: 503, json: async () => ({})}
    }

    // With no request of this device standing, and with one that named
    // the person's own home.
    for (const asked of [null, askedOf({client_id: "pcl_hub", audience: HOME, athanor: legit.athanor})]) {
      const page = await mountPage({hash: fragmentOf(crafted), stored, asked, fetch, replies: {}})
      try {
        await new Promise((resolve) => setTimeout(resolve, 50))
        assert.deepEqual(calls, [], "nothing is posted to any issuer")
        assert.deepEqual((await page.store.load()).certificate, legit, "the stored certificate and its issuer stand")
        assert.deepEqual(await page.store.loadCertify(), asked, "a request still standing stays")
        assert.ok(page.el.find("glass-error"))

        // The glass connects under the certificate it holds, and a challenge
        // naming the crafted issuer as home is left unsigned.
        const [socket] = page.sockets
        socket.onopen()
        assert.equal(socket.sent[0].certificate.issuer, ISSUER)
        socket.onmessage(challengeMessage({...hConnect, home: EVIL}))
        await new Promise((resolve) => setTimeout(resolve, 20))
        assert.deepEqual(socket.sent.map((m) => m.type), ["connect"], "nothing signed")
      } finally {
        page.restore()
      }
    }
  })
})
