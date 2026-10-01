// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import SystemLayer from "../../js/system_layer/index.js"
import {
  assert as assertPasskey,
  assertionJSON,
  b64urlToBytes,
  bytesToB64url,
  creationOptions,
  register,
  requestOptions
} from "../../js/system_layer/webauthn.js"

const bytes = (...values) => new Uint8Array(values).buffer
const equalBytes = (left, right) =>
  assert.deepEqual(Array.from(new Uint8Array(left)), Array.from(new Uint8Array(right)))

// An authenticator's answers, as the browser hands them over: every
// binary field an ArrayBuffer.
function assertion(overrides = {}) {
  return {
    id: "AQID_w",
    rawId: bytes(1, 2, 3, 255),
    type: "public-key",
    response: {
      clientDataJSON: bytes(123, 125),
      authenticatorData: bytes(9, 8, 7),
      signature: bytes(251, 239),
      userHandle: bytes(4, 5)
    },
    ...overrides
  }
}

function created() {
  return {
    id: "AQID_w",
    rawId: bytes(1, 2, 3, 255),
    type: "public-key",
    response: {
      clientDataJSON: bytes(123, 125),
      attestationObject: bytes(163, 1, 2),
      getTransports: () => ["internal"]
    }
  }
}

describe("base64url", () => {
  test("round-trips every byte, unpadded", () => {
    const all = new Uint8Array(256).map((_value, index) => index).buffer
    const text = bytesToB64url(all)
    assert.doesNotMatch(text, /[+/=]/)
    equalBytes(b64urlToBytes(text), all)
  })

  test("reads a padded spelling, and refuses what is not base64url", () => {
    equalBytes(b64urlToBytes("-_8="), bytes(251, 255))
    assert.throws(() => b64urlToBytes("a+b/"), TypeError)
    assert.throws(() => b64urlToBytes(42), TypeError)
  })
})

describe("the home's options", () => {
  test("creation options decode the challenge, the user handle and every excluded id", () => {
    const options = creationOptions({
      rp: {id: "home.example", name: "home.example"},
      user: {id: "BAU", name: "ada@example.com", displayName: "Ada"},
      challenge: "AQID",
      pubKeyCredParams: [{type: "public-key", alg: -7}],
      excludeCredentials: [{type: "public-key", id: "AQID_w"}],
      authenticatorSelection: {residentKey: "required", userVerification: "required"},
      attestation: "none"
    })

    equalBytes(options.challenge, bytes(1, 2, 3))
    equalBytes(options.user.id, bytes(4, 5))
    assert.equal(options.user.name, "ada@example.com")
    equalBytes(options.excludeCredentials[0].id, bytes(1, 2, 3, 255))
    assert.equal(options.authenticatorSelection.userVerification, "required")
    assert.equal(options.attestation, "none")
  })

  test("request options decode the challenge and every allowed id, and keep user verification", () => {
    const options = requestOptions({
      challenge: "-_8",
      rpId: "home.example",
      allowCredentials: [{type: "public-key", id: "AQID_w"}],
      userVerification: "required"
    })

    equalBytes(options.challenge, bytes(251, 255))
    equalBytes(options.allowCredentials[0].id, bytes(1, 2, 3, 255))
    assert.equal(options.rpId, "home.example")
    assert.equal(options.userVerification, "required")
  })

  test("a sign-in names no credential, and asks the authenticator which", () => {
    assert.deepEqual(requestOptions({challenge: "AQID"}).allowCredentials, [])
  })
})

describe("the ceremonies", () => {
  test("a registration answers the home's token beside the credential, in base64url", async () => {
    const asked = []
    const credentials = {create: async (options) => (asked.push(options), created())}

    const answer = await register(
      {challenge: "AQID", user: {id: "BAU", name: "a", displayName: "a"}},
      "token-1",
      credentials
    )

    equalBytes(asked[0].publicKey.challenge, bytes(1, 2, 3))
    assert.deepEqual(answer, {
      id: "AQID_w",
      rawId: "AQID_w",
      type: "public-key",
      registration: "token-1",
      response: {clientDataJSON: "e30", attestationObject: "owEC", transports: ["internal"]}
    })
  })

  test("an assertion answers the authenticator's fields, in base64url", async () => {
    const asked = []
    const credentials = {get: async (options) => (asked.push(options), assertion())}

    const answer = await assertPasskey({challenge: "AQID", allowCredentials: []}, credentials)

    equalBytes(asked[0].publicKey.challenge, bytes(1, 2, 3))
    assert.deepEqual(answer, {
      id: "AQID_w",
      rawId: "AQID_w",
      type: "public-key",
      response: {
        clientDataJSON: "e30",
        authenticatorData: "CQgH",
        signature: "--8",
        userHandle: "BAU"
      }
    })
  })

  test("an assertion with no user handle carries none", () => {
    const answer = assertionJSON(assertion({response: {...assertion().response, userHandle: null}}))
    assert.equal("userHandle" in answer.response, false)
  })

  test("a cancelled or refused ceremony rejects, and sends nothing", async () => {
    const refusing = {get: async () => Promise.reject(new Error("NotAllowedError"))}
    await assert.rejects(assertPasskey({challenge: "AQID"}, refusing))

    const empty = {get: async () => null, create: async () => null}
    await assert.rejects(assertPasskey({challenge: "AQID"}, empty))
    await assert.rejects(register({challenge: "AQID", user: {id: "AQ"}}, "t", empty))
  })
})

describe("the sign-in page's hook", () => {
  let original

  beforeEach(() => {
    original = Object.getOwnPropertyDescriptor(globalThis.navigator, "credentials")
  })

  afterEach(() => {
    if (original) Object.defineProperty(globalThis.navigator, "credentials", original)
    else delete globalThis.navigator.credentials
  })

  function signInHook(pushed) {
    const el = new EventTarget()
    el.dataset = {webauthn: "sign-in"}
    const hook = Object.create(SystemLayer)
    hook.el = el
    hook.pushEvent = (event, payload, reply) => {
      pushed.push({event, payload})
      if (event === "passkey_start" && reply) reply({public_key: {challenge: "AQID"}})
    }
    hook.mounted()
    return {hook, el}
  }

  function clickStart(el) {
    const start = {closest: (selector) => (selector === "[data-webauthn-start]" ? start : null)}
    const event = new Event("click")
    Object.defineProperty(event, "target", {value: start})
    el.dispatchEvent(event)
  }

  const settled = () => new Promise((resolve) => setTimeout(resolve, 0))

  test("asks the page for a challenge and answers it once, drawing no prompt", async () => {
    Object.defineProperty(globalThis.navigator, "credentials", {
      configurable: true,
      value: {get: async () => assertion()}
    })

    const pushed = []
    const {hook, el} = signInHook(pushed)
    assert.equal(hook.dialog, undefined)

    clickStart(el)
    await settled()

    assert.deepEqual(
      pushed.map((entry) => entry.event),
      ["passkey_start", "passkey_assertion"]
    )
    assert.equal(pushed[1].payload.credential.rawId, "AQID_w")

    hook.updated()
    hook.destroyed()
  })

  test("says the ceremony did not finish when the person cancels it", async () => {
    Object.defineProperty(globalThis.navigator, "credentials", {
      configurable: true,
      value: {get: async () => Promise.reject(new Error("NotAllowedError"))}
    })

    const pushed = []
    const {el} = signInHook(pushed)
    clickStart(el)
    await settled()

    assert.deepEqual(
      pushed.map((entry) => entry.event),
      ["passkey_start", "passkey_error"]
    )
  })

  test("a click elsewhere on the page starts nothing", () => {
    const pushed = []
    const {el} = signInHook(pushed)
    const event = new Event("click")
    Object.defineProperty(event, "target", {value: {closest: () => null}})
    el.dispatchEvent(event)
    assert.deepEqual(pushed, [])
  })
})
