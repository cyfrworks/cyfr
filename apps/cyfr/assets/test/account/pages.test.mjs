// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {b64, concat, jcs, sha256, unb64, utf8} from "../../account/encoding.js"
import {extend, walk} from "../../account/identity.js"
import {Unreachable} from "../../account/network.js"
import {readDevice, adding} from "../../account/pages/add.js"
import {here} from "../../account/pages/common.js"
import {listing, removal} from "../../account/pages/devices.js"
import {Creation} from "../../account/pages/new.js"
import {Recovery} from "../../account/pages/recover.js"
import {describe as describeRequest, readSigned, sign} from "../../account/pages/sign.js"
import {digest, fragment, parseFragment} from "../../account/sign_in.js"

const read = (name) => JSON.parse(readFileSync(new URL(`../../../../../tests/fixtures/${name}`, import.meta.url), "utf8"))
const signIn = read("sign_in.json")
const identity = read("identity.json")

const ORIGIN = signIn.directory
const RP_ID = new URL(ORIGIN).hostname
const DAY = 24 * 60 * 60 * 1000

// A passkey that answers with the canned assertion a vector holds, after
// checking what the page asked of it.
function cannedPasskey(vector, expect) {
  const asked = []
  return {
    asked,
    async assert(options) {
      asked.push(options)
      expect(options)
      const answer = vector.answer
      return {
        identifier: answer.identifier,
        credentialId: unb64(answer.credential_id, 1, 1023),
        authenticatorData: unb64(answer.authenticator_data, 1, 16384),
        clientData: unb64(answer.client_data, 1, 16384),
        signature: unb64(answer.signature, 1, 16384)
      }
    }
  }
}

// An authenticator holding one of the vectors' P-256 passkeys: it makes
// real assertions at ORIGIN, so the entries the pages sign verify.
async function authenticator(passkey, identifier) {
  const point = unb64(passkey.public, 65)
  const key = await crypto.subtle.importKey(
    "jwk",
    {kty: "EC", crv: "P-256", d: passkey.private, x: b64(point.subarray(1, 33)), y: b64(point.subarray(33))},
    {name: "ECDSA", namedCurve: "P-256"},
    false,
    ["sign"]
  )
  const credentialId = unb64(passkey.credential_id, 1, 1023)
  const calls = []
  return {
    calls,
    identifier,
    async create(options) {
      calls.push({create: options})
      return {credentialId, pub: point}
    },
    async assert({challenge, allow}) {
      calls.push({assert: {challenge, allow}})
      if (allow && !allow.some((id) => b64(id) === passkey.credential_id)) throw Object.assign(new Error("no credential"), {name: "NotAllowedError"})
      const clientData = utf8(JSON.stringify({type: "webauthn.get", challenge: b64(challenge), origin: ORIGIN, crossOrigin: false}))
      const authenticatorData = concat(await sha256(RP_ID), new Uint8Array([0x05, 0, 0, 0, 1]))
      const raw = new Uint8Array(
        await crypto.subtle.sign({name: "ECDSA", hash: "SHA-256"}, key, concat(authenticatorData, await sha256(clientData)))
      )
      return {identifier: this.identifier, credentialId, authenticatorData, clientData, signature: der(raw)}
    }
  }
}

function der(raw) {
  const integer = (bytes) => {
    let value = bytes
    while (value.length > 1 && value[0] === 0 && value[1] < 0x80) value = value.subarray(1)
    if (value[0] >= 0x80) value = concat(new Uint8Array([0]), value)
    return concat(new Uint8Array([0x02, value.length]), value)
  }
  const body = concat(integer(raw.subarray(0, 32)), integer(raw.subarray(32)))
  return concat(new Uint8Array([0x30, body.length]), body)
}

// The directory and registry at ORIGIN, in memory: every write is checked
// as cyfr.run checks it (a genesis walked, an entry extended onto the
// head), and `lose(path)` drops the answer to the next write on a path
// after applying it, as a network that fails on the way back does.
function world({policy = {version: "v1", url: `${ORIGIN}/terms`}} = {}) {
  const logs = new Map()
  const handles = new Map()
  const sent = []
  const losing = new Set()
  const json = (status, body) => ({status, text: async () => (typeof body === "string" ? body : JSON.stringify(body))})
  const envelope = (status, code) => json(status, {errors: [{code, message: code}]})

  async function directoryWrite(path, body) {
    const entry = JSON.parse(body)
    if (path === "/directory/v1/register") {
      const walked = await walk([entry])
      if (walked.error) return json(422, {error: "invalid"})
      const known = logs.get(walked.state.identifier)
      if (!known) logs.set(walked.state.identifier, [entry])
      return json(200, {identifier: walked.state.identifier, seq: 0, entry_hash: walked.state.head, result: known ? "exists" : "created"})
    }
    const identifier = path.split("/")[3]
    const entries = logs.get(identifier)
    const {state} = await walk(entries)
    if (entry.seq <= state.seq && jcs(entries[entry.seq]) === jcs(entry)) return json(200, {identifier, seq: entry.seq, result: "exists", head: state.head})
    if (entry.prev !== state.head) return json(409, {error: "stale_head", head: state.head})
    try {
      await extend(state, entry)
    } catch (error) {
      return json(422, {error: "unverified", reason: error.reason})
    }
    entries.push(entry)
    return json(200, {identifier, seq: entry.seq, result: "accepted"})
  }

  async function registryWrite(path, body) {
    const request = JSON.parse(body)
    const {state} = await walk(logs.get(request.identifier))
    const pub = state.recovery[0]
    const key = await crypto.subtle.importKey("raw", unb64(pub, 32), {name: "Ed25519"}, false, ["verify"])
    const {sig, ...unsigned} = request
    if (!(await crypto.subtle.verify("Ed25519", key, unb64(sig, 64), utf8(jcs(unsigned))))) return envelope(401, "BAD_SIGNATURE")
    sent.push(request)
    if (path === "/v1/legal/accept") return json(200, {accepted: request.body.policy_version})
    const holder = handles.get(request.body.handle)
    if (holder && holder !== request.identifier) return envelope(409, "SLUG_TAKEN")
    handles.set(request.body.handle, request.identifier)
    return json(200, {handle: request.body.handle})
  }

  async function fetch(url, init = {}) {
    const {pathname, search} = new URL(url)
    if (pathname === "/account/config.json") return json(200, {directory: ORIGIN, registry: ORIGIN, policy})
    if (pathname.startsWith("/v1/handles/")) {
      const name = decodeURIComponent(pathname.slice("/v1/handles/".length))
      const holder = handles.get(name)
      if (!holder) return envelope(404, "HANDLE_NOT_FOUND")
      return json(200, {protocol: "cyfr-handle/v1", registry: RP_ID, handle: name, identifier: holder, directory: ORIGIN})
    }
    if (init.method === "POST") {
      const answer = pathname.startsWith("/directory/") ? await directoryWrite(pathname, init.body) : await registryWrite(pathname, init.body)
      if (losing.delete(pathname)) throw new TypeError("network")
      return answer
    }
    const identifier = pathname.split("/")[3]
    const entries = logs.get(identifier)
    if (!entries) return json(404, {error: "not_found"})
    const after = Number(new URLSearchParams(search).get("after"))
    const {state} = await walk(entries)
    return json(200, {identifier, from: after + 1, next: null, head: state.head, length: entries.length, entries: entries.slice(after + 1)})
  }

  return {fetch, logs, handles, sent, lose: (path) => losing.add(path)}
}

function memoryStorage() {
  const items = new Map()
  return {
    get length() {
      return items.size
    },
    key: (i) => [...items.keys()][i] ?? null,
    getItem: (key) => items.get(key) ?? null,
    setItem: (key, value) => items.set(key, String(value)),
    removeItem: (key) => items.delete(key)
  }
}

function environment(passkeys, net, {storage = memoryStorage(), now = 1790000000000} = {}) {
  const clock = {now}
  return {
    clock,
    origin: ORIGIN,
    passkeys,
    fetch: net.fetch,
    storage,
    now: () => clock.now,
    random: (size) => crypto.getRandomValues(new Uint8Array(size))
  }
}

async function accountWithPasskey(net, name = "alice") {
  const passkey = await authenticator(identity.keys.passkey_1, null)
  const env = environment(passkey, net)
  const creation = await Creation.open(env)
  await creation.check(name)
  const code = await creation.begin(name)
  passkey.identifier = creation.attempt.identifier
  await creation.savedCode()
  await creation.submit()
  return {env, passkey, code, identifier: creation.attempt.identifier}
}

describe("/account/sign", () => {
  const now = signIn.verify.find((c) => c.name === "a passkey signs in").now_ms

  test("answers a sign-in and a confirmation at their return, the passkey asked over the digest at this host", async () => {
    for (const [name, answerName] of [["sign_in", "passkey_sign_in"], ["confirm", "passkey_confirm"]]) {
      const {request, digest} = signIn.requests[name]
      const passkey = cannedPasskey(signIn.answers[answerName], (options) => {
        assert.equal(b64(options.challenge), digest, name)
        assert.equal(options.allow, undefined, name)
      })
      const read = readSigned(signIn.fragments.requests[name], now)
      assert.deepEqual(read, request)
      const url = await sign(read, {passkeys: passkey})
      assert.equal(url, `${request.return}#${signIn.fragments.answers[answerName]}`, name)
    }
  })

  test("signs a registry request with the account's one passkey, its kid the signer", async () => {
    const net = world()
    net.logs.set(signIn.identity.identifiers.alice, signIn.identity.entries)
    const vector = signIn.answers.passkey_registry
    const passkey = cannedPasskey(vector, (options) => {
      assert.equal(b64(options.challenge), vector.digest)
      assert.deepEqual(options.allow.map(b64), [signIn.keys.passkey_1.credential_id])
    })
    const {request} = signIn.requests.registry
    const url = await sign(request, {passkeys: passkey, origin: ORIGIN, fetch: net.fetch})
    assert.equal(url, `${request.return}#${signIn.fragments.answers.passkey_registry}`)
    assert.equal(passkey.asked.length, 1)
    assert.equal(describeRequest(request), "Claim the name @alice at cyfr.run")
  })

  test("with several passkeys listed, asks the person to pick one, then signs as that passkey", async () => {
    const net = world()
    const {env, code, identifier} = await accountWithPasskey(net)
    const second = await authenticator(identity.keys.passkey_2, identifier)
    const recovery = await Recovery.open({...env, passkeys: second}, await here(env), code)
    await recovery.addPasskey("alice")

    const registryRequest = {...signIn.requests.registry.request.registry_request, identifier}
    const request = {...signIn.requests.registry.request, registry_request: registryRequest}
    second.calls.length = 0
    const url = await sign(request, {...env, passkeys: second})
    const listedIds = [identity.keys.passkey_1.credential_id, identity.keys.passkey_2.credential_id]
    assert.deepEqual(second.calls[0].assert.allow.map(b64), listedIds, "the pick is among the account's passkeys")
    assert.deepEqual(second.calls[1].assert.allow.map(b64), [identity.keys.passkey_2.credential_id])
    const made = parseFragment(url.split("#")[1])
    assert.equal(made.signer, identity.keys.passkey_2.kid)
    assert.equal(b64(second.calls[1].assert.challenge), b64(await digest(request, made.signer)))
  })

  test("refuses a request at its expiry, and takes one the millisecond before", () => {
    const {request} = signIn.requests.sign_in
    assert.throws(() => readSigned(fragment(request), request.expires_at), {reason: "expired"})
    assert.deepEqual(readSigned(fragment(request), request.expires_at - 1), request)
  })

  test("refuses a fragment past the bound before reading it", () => {
    assert.throws(() => readSigned("A".repeat(signIn.max_fragment_bytes + 1), now), {reason: "too_large"})
  })

  test("says what is signed, naming no account", () => {
    assert.equal(describeRequest(signIn.requests.sign_in.request), "Sign in to https://alice.example")
    assert.equal(describeRequest(signIn.requests.confirm.request), "Confirm a change at https://alice.example")
  })
})

describe("/account/new", () => {
  test("registers the genesis, appends the passkey, accepts the policy, then claims the name", async () => {
    const net = world()
    const {identifier, code} = await accountWithPasskey(net)
    const {state} = await walk(net.logs.get(identifier))
    assert.equal(state.keys.length, 1)
    assert.equal(state.keys[0].credential_id, identity.keys.passkey_1.credential_id)
    assert.deepEqual(
      net.sent.map((request) => request.operation),
      ["policy.accept", "handle.claim"]
    )
    assert.equal(net.handles.get("alice"), identifier)
    assert.match(code, /^CYFR(-[0-9A-HJKMNP-TV-Z]{8}){14}$/)
  })

  test("sends no policy acceptance before the claim when the registry names no policy", async () => {
    const net = world({policy: null})
    const {identifier} = await accountWithPasskey(net)
    assert.deepEqual(
      net.sent.map((request) => request.operation),
      ["handle.claim"]
    )
    assert.equal(net.handles.get("alice"), identifier)
  })

  test("creates the passkey for the account's digest bytes, named by its name", async () => {
    const net = world()
    const {passkey, identifier} = await accountWithPasskey(net)
    const {create} = passkey.calls.find((call) => call.create)
    assert.equal(create.name, "@alice")
    assert.equal("per_" + Buffer.from(create.userId).toString("hex"), identifier)
  })

  test("resends the same register and append after a lost response, and the directory's exists is success", async () => {
    for (const path of ["/directory/v1/register", "append"]) {
      const net = world()
      const passkey = await authenticator(identity.keys.passkey_1, null)
      const env = environment(passkey, net)
      const creation = await Creation.open(env)
      await creation.begin("alice")
      await creation.savedCode()
      net.lose(path === "append" ? `/directory/v1/${creation.attempt.identifier}/append` : path)
      await assert.rejects(creation.submit(), Unreachable)
      await creation.submit()
      assert.equal(net.logs.get(creation.attempt.identifier).length, 2, path)
      assert.equal(net.handles.get("alice"), creation.attempt.identifier, path)
    }
  })

  test("reconciles a claim whose response was lost by reading the name, and claims once", async () => {
    const net = world()
    const passkey = await authenticator(identity.keys.passkey_1, null)
    const creation = await Creation.open(environment(passkey, net))
    await creation.begin("alice")
    await creation.savedCode()
    net.lose("/v1/namespaces/personal/claim")
    await assert.rejects(creation.submit(), Unreachable)
    await creation.submit()
    assert.equal(net.sent.filter((request) => request.operation === "handle.claim").length, 1)
    assert.equal(net.handles.get("alice"), creation.attempt.identifier)
  })

  test("asks for another name when the name was taken meanwhile, and claims it with a fresh signature", async () => {
    const net = world()
    const passkey = await authenticator(identity.keys.passkey_1, null)
    const creation = await Creation.open(environment(passkey, net))
    await creation.check("alice")
    await creation.begin("alice")
    await creation.savedCode()
    net.handles.set("alice", "per_" + "0".repeat(64))
    await assert.rejects(creation.submit(), {reason: "name_taken"})
    assert.equal(net.logs.get(creation.attempt.identifier).length, 2, "the account is made whatever its name")
    await assert.rejects(creation.check("alice"), {reason: "name_taken"})
    creation.rename("alice2")
    await creation.submit()
    assert.equal(net.handles.get("alice2"), creation.attempt.identifier)
  })

  test("resumes in a new tab from the attempt this browser kept, once the person types the code", async () => {
    const net = world()
    const storage = memoryStorage()
    const passkey = await authenticator(identity.keys.passkey_1, null)
    const first = await Creation.open(environment(passkey, net, {storage}))
    const code = await first.begin("alice")
    await first.savedCode()
    net.lose("/directory/v1/register")
    await assert.rejects(first.submit(), Unreachable)

    const env = environment(passkey, net, {storage})
    const second = await Creation.open(env)
    const [kept] = second.attempts.list()
    assert.equal(kept.identifier, first.attempt.identifier)
    assert.equal(JSON.stringify(kept).includes(code), false, "the code is never stored")
    const other = await accountWithPasskey(world(), "bob")
    await assert.rejects(second.resume(kept, other.code), {reason: "other_code"})
    await assert.rejects(second.resume(kept, code.slice(0, -1) + (code.endsWith("0") ? "1" : "0")), {reason: "typo"})
    await second.resume(kept, code.toLowerCase().replaceAll("-", " "))
    await second.submit()
    assert.equal(net.handles.get("alice"), kept.identifier)
    assert.deepEqual(second.attempts.list(), [], "the attempt is removed once done")
  })

  test("drops an attempt after 24 hours", async () => {
    const net = world()
    const storage = memoryStorage()
    const passkey = await authenticator(identity.keys.passkey_1, null)
    const env = environment(passkey, net, {storage})
    const creation = await Creation.open(env)
    await creation.begin("alice")
    await creation.savedCode()
    env.clock.now += DAY - 1
    assert.equal(creation.attempts.list().length, 1)
    env.clock.now += 1
    assert.equal(creation.attempts.list().length, 0)
  })

  test("a tab closed before I saved it made nothing", async () => {
    const net = world()
    const storage = memoryStorage()
    const creation = await Creation.open(environment(await authenticator(identity.keys.passkey_1, null), net, {storage}))
    await creation.begin("alice")
    assert.equal(net.logs.size, 0)
    assert.equal(storage.length, 0)
  })
})

describe("/account/add and /account/devices", () => {
  test("adds the device a link names with two ceremonies, the second restricted to the passkey", async () => {
    const net = world()
    const {env, passkey, identifier} = await accountWithPasskey(net)
    const device = identity.keys.device_1
    const params = new URLSearchParams({key: device.public, alg: "ed25519", kind: "device", code: device.kid.slice(7, 23)})
    const key = await readDevice(params)
    const flow = adding(env, await here(env), key)
    passkey.calls.length = 0
    assert.equal(await flow.sign(), "signed")
    assert.equal(passkey.calls[0].assert.allow, undefined)
    assert.deepEqual(passkey.calls[1].assert.allow.map(b64), [identity.keys.passkey_1.credential_id])
    net.lose(`/directory/v1/${identifier}/append`)
    await assert.rejects(flow.send(), Unreachable)
    await flow.send()
    const {state} = await walk(net.logs.get(identifier))
    assert.deepEqual(state.keys[1], {kid: device.kid, alg: "ed25519", kind: "device", pub: device.public})
    assert.equal(await adding(env, await here(env), key).sign(), "listed")
  })

  test("refuses a link whose code is not its key's, or that names another kind", async () => {
    const device = identity.keys.device_1
    const good = {key: device.public, alg: "ed25519", kind: "device", code: device.kid.slice(7, 23)}
    for (const bad of [{code: "0000000000000000"}, {alg: "es256"}, {kind: "passkey"}, {key: device.public + "A"}]) {
      await assert.rejects(readDevice(new URLSearchParams({...good, ...bad})), {reason: "bad_link"}, JSON.stringify(bad))
    }
  })

  test("lists the keys by kind and short code and removes another key with the passkey", async () => {
    const net = world()
    const {env, identifier} = await accountWithPasskey(net)
    const device = identity.keys.device_1
    const flow = adding(env, await here(env), await readDevice(new URLSearchParams({key: device.public, alg: "ed25519", kind: "device", code: device.kid.slice(7, 23)})))
    await flow.sign()
    await flow.send()

    const place = await here(env)
    const {namedByPasskey} = await import("../../account/pages/common.js")
    const session = await namedByPasskey(env, place.directory)
    assert.deepEqual(
      listing(session).map(({kind, code, current}) => ({kind, code, current})),
      [
        {kind: "passkey", code: identity.keys.passkey_1.kid.slice(7, 23), current: true},
        {kind: "device", code: device.kid.slice(7, 23), current: false}
      ]
    )
    await place.directory.append(identifier, await removal(env, session, device.kid))
    const {state} = await walk(net.logs.get(identifier))
    assert.deepEqual(state.keys.map((key) => key.kind), ["passkey"])
  })
})

describe("/account/recover", () => {
  test("removes a key, adds a second code, then replaces everything with a new code, each signed by the code", async () => {
    const net = world()
    const {env, code, identifier} = await accountWithPasskey(net)
    const place = await here(env)
    const recovery = await Recovery.open(env, place, code)
    await recovery.removeKey(identity.keys.passkey_1.kid)
    assert.deepEqual(recovery.state.keys, [])

    const second = await recovery.drawCode()
    await recovery.addCode()
    assert.equal(recovery.state.recovery.length, 2)
    assert.ok(await Recovery.open(env, place, second), "the second code recovers too")

    const replacement = await recovery.drawCode()
    net.lose(`/directory/v1/${identifier}/append`)
    await assert.rejects(recovery.replace(), Unreachable)
    await recovery.submit()
    assert.equal(recovery.state.recovery.length, 1)
    await assert.rejects(Recovery.open(env, place, code), {reason: "code_replaced"})
    const fresh = await Recovery.open(env, place, replacement)
    assert.equal(fresh.identifier, identifier)
  })

  test("adds a passkey labelled with the account's own name, and refuses another account's name", async () => {
    const net = world()
    const {env, code, identifier} = await accountWithPasskey(net)
    const place = await here(env)
    const recovery = await Recovery.open(env, place, code)
    await recovery.removeKey(identity.keys.passkey_1.kid)
    net.handles.set("bob", "per_" + "1".repeat(64))
    await assert.rejects(recovery.addPasskey("bob"), {reason: "name_elsewhere"})
    await recovery.addPasskey("alice")
    const {state} = await walk(net.logs.get(identifier))
    assert.equal(state.keys[0].credential_id, identity.keys.passkey_1.credential_id)
  })
})
