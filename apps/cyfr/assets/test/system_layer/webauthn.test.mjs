// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import SystemLayer from "../../js/system_layer/index.js"
import {
  assert as assertPasskey,
  assertionJSON,
  creationOptions,
  register,
  requestOptions
} from "../../js/system_layer/webauthn.js"
import {b64url, fromB64url} from "../../js/system_layer/base64url.js"

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
    const text = b64url(all)
    assert.doesNotMatch(text, /[+/=]/)
    equalBytes(fromB64url(text), all)
  })

  test("reads an unpadded spelling, and refuses a padded one and what is not base64url", () => {
    equalBytes(fromB64url("-_8"), bytes(251, 255))
    assert.throws(() => fromB64url("-_8="), TypeError)
    assert.throws(() => fromB64url("a+b/"), TypeError)
    assert.throws(() => fromB64url(42), TypeError)
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

// A newcomer's `<mode>_passkey` payload: the credential, and the recovery
// secret (32 bytes, unpadded base64url) and request id the hook drew at
// the tap; the name is the page's, never sent from here.
function assertMaterial(payload) {
  assert.deepEqual(Object.keys(payload).sort(), ["credential", "recovery_secret", "request_id"])
  assert.match(payload.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
  assert.equal(fromB64url(payload.recovery_secret).byteLength, 32)
  assert.match(payload.request_id, /^req_[0-9a-f]{32}$/)
}

for (const [mode, page] of [["setup", "the setup page"], ["invite", "the invitation page"]]) {
  describe(`${page}'s hook`, () => {
    let original, location

    beforeEach(() => {
      original = Object.getOwnPropertyDescriptor(globalThis.navigator, "credentials")
      location = Object.getOwnPropertyDescriptor(globalThis, "location")
      Object.defineProperty(globalThis, "location", {configurable: true, value: {hash: "#ab12"}})
    })

    afterEach(() => {
      if (original) Object.defineProperty(globalThis.navigator, "credentials", original)
      else delete globalThis.navigator.credentials
      if (location) Object.defineProperty(globalThis, "location", location)
      else delete globalThis.location
    })

    function newcomerHook(pushed) {
      const el = new EventTarget()
      el.dataset = {webauthn: mode}
      const hook = Object.create(SystemLayer)
      hook.el = el
      hook.pushEvent = (event, payload, reply) => {
        pushed.push({event, payload})
        if (event === `${mode}_start` && reply)
          reply({public_key: {challenge: "AQID", user: {id: "BAU", name: "a", displayName: "a"}}, registration: "token-1"})
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

    test("hands the page the fragment's token, then registers under the options it answers, drawing no prompt", async () => {
      Object.defineProperty(globalThis.navigator, "credentials", {
        configurable: true,
        value: {create: async () => created()}
      })

      const pushed = []
      const {hook, el} = newcomerHook(pushed)
      assert.equal(hook.dialog, undefined)
      assert.deepEqual(pushed, [{event: `${mode}_token`, payload: {token: "ab12"}}])

      clickStart(el)
      await settled()

      assert.deepEqual(
        pushed.map((entry) => entry.event),
        [`${mode}_token`, `${mode}_start`, `${mode}_passkey`]
      )
      assert.equal(pushed[2].payload.credential.registration, "token-1")
      assertMaterial(pushed[2].payload)
      assert.deepEqual(pushed[1].payload, {}, "the start sends no material")

      hook.updated()
      hook.destroyed()
    })

    test("draws a new recovery secret and request id at each tap", async () => {
      Object.defineProperty(globalThis.navigator, "credentials", {
        configurable: true,
        value: {create: async () => created()}
      })

      const pushed = []
      const {el} = newcomerHook(pushed)
      clickStart(el)
      await settled()
      clickStart(el)
      await settled()

      const [first, second] = pushed.filter((entry) => entry.event === `${mode}_passkey`)
      assertMaterial(first.payload)
      assertMaterial(second.payload)
      assert.notEqual(first.payload.recovery_secret, second.payload.recovery_secret)
      assert.notEqual(first.payload.request_id, second.payload.request_id)
    })

    test("hands the token over again to the page process a reconnect starts", () => {
      const pushed = []
      const {hook} = newcomerHook(pushed)
      hook.reconnected()
      assert.deepEqual(
        pushed.map((entry) => entry.event),
        [`${mode}_token`, `${mode}_token`]
      )
    })

    test("says the ceremony did not finish when the person cancels it", async () => {
      Object.defineProperty(globalThis.navigator, "credentials", {
        configurable: true,
        value: {create: async () => Promise.reject(new Error("NotAllowedError"))}
      })

      const pushed = []
      const {el} = newcomerHook(pushed)
      clickStart(el)
      await settled()

      assert.deepEqual(
        pushed.map((entry) => entry.event),
        [`${mode}_token`, `${mode}_start`, `${mode}_error`]
      )
    })
  })
}

describe("the sign-in page's newcomer hook", () => {
  let original, location

  beforeEach(() => {
    original = Object.getOwnPropertyDescriptor(globalThis.navigator, "credentials")
    location = Object.getOwnPropertyDescriptor(globalThis, "location")
    // A carry's fragment, which this hook never reads.
    Object.defineProperty(globalThis, "location", {configurable: true, value: {hash: "#carry=abc"}})
  })

  afterEach(() => {
    if (original) Object.defineProperty(globalThis.navigator, "credentials", original)
    else delete globalThis.navigator.credentials
    if (location) Object.defineProperty(globalThis, "location", location)
    else delete globalThis.location
  })

  function createHook(pushed) {
    const el = new EventTarget()
    el.dataset = {webauthn: "create"}
    const hook = Object.create(SystemLayer)
    hook.el = el
    hook.pushEvent = (event, payload, reply) => {
      pushed.push({event, payload})
      if (event === "create_start" && reply)
        reply({public_key: {challenge: "AQID", user: {id: "BAU", name: "a", displayName: "a"}}, registration: "token-2"})
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

  test("hands the page nothing of the address, then registers under the options it answers, drawing no prompt", async () => {
    Object.defineProperty(globalThis.navigator, "credentials", {
      configurable: true,
      value: {create: async () => created()}
    })

    const pushed = []
    const {hook, el} = createHook(pushed)
    assert.equal(hook.dialog, undefined)
    assert.deepEqual(pushed, [])

    clickStart(el)
    await settled()

    assert.deepEqual(
      pushed.map((entry) => entry.event),
      ["create_start", "create_passkey"]
    )
    assert.equal(pushed[1].payload.credential.registration, "token-2")
    assertMaterial(pushed[1].payload)

    hook.reconnected()
    hook.updated()
    hook.destroyed()
    assert.equal(pushed.length, 2, "a reconnect hands nothing over")
  })

  test("says the ceremony did not finish when the person cancels it", async () => {
    Object.defineProperty(globalThis.navigator, "credentials", {
      configurable: true,
      value: {create: async () => Promise.reject(new Error("NotAllowedError"))}
    })

    const pushed = []
    const {el} = createHook(pushed)
    clickStart(el)
    await settled()

    assert.deepEqual(
      pushed.map((entry) => entry.event),
      ["create_start", "create_error"]
    )
  })
})
