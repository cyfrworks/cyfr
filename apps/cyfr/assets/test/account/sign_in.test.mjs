// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {b64, directoryOrigin, unb64} from "../../account/encoding.js"
import {identifierForUserId, userId, walk} from "../../account/identity.js"
import {sent} from "../../account/registry.js"
import {answer, digest, fragment, parseFragment, readRequest} from "../../account/sign_in.js"
import {verifyAssertion} from "../../account/webauthn.js"

const vectors = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/sign_in.json", import.meta.url), "utf8"))

const refusalOf = (fn) => {
  try {
    fn()
  } catch (error) {
    return error.toJSON()
  }
  return null
}

const passkeyAnswers = Object.entries(vectors.answers).filter(([, v]) => v.kind === "passkey")

describe("sign_in.json", () => {
  test("reads every request, writes it back as its fragment, and reproduces each digest", async () => {
    for (const [name, {request, digest: expected}] of Object.entries(vectors.requests)) {
      assert.equal(readRequest(request), request, name)
      assert.equal(fragment(request), vectors.fragments.requests[name], name)
      assert.deepEqual(parseFragment(vectors.fragments.requests[name]), request, name)
      if (expected) assert.equal(b64(await digest(request)), expected, name)
    }
  })

  test("refuses each malformed request with its reason and field", () => {
    for (const {name, request, error, field} of vectors.request_refusals) {
      assert.deepEqual(refusalOf(() => readRequest(request)), field ? {reason: error, field} : {reason: error}, name)
    }
  })

  test("reproduces each registry answer's digest from its signer", async () => {
    for (const [name, v] of passkeyAnswers.filter(([, v]) => v.digest)) {
      const {request} = vectors.requests[v.request]
      assert.equal(b64(await digest(request, v.answer.signer)), v.digest, name)
    }
  })

  test("composes each answer the page makes from its assertion, and its fragment", async () => {
    let composed = 0
    for (const [name, v] of passkeyAnswers) {
      const {request} = vectors.requests[v.request]
      const madeByPage = v.answer.challenge === request.challenge && (request.purpose === "registry") === Object.hasOwn(v.answer, "signer")
      if (!madeByPage) continue
      const assertion = {
        identifier: identifierForUserId(userId(v.answer.identifier)),
        credentialId: unb64(v.answer.credential_id, 1, 1023),
        authenticatorData: unb64(v.answer.authenticator_data, 1, 16384),
        clientData: unb64(v.answer.client_data, 1, 16384),
        signature: unb64(v.answer.signature, 1, 16384)
      }
      const made = answer(request, assertion, v.answer.signer)
      assert.deepEqual(made, v.answer, name)
      assert.equal(fragment(made), vectors.fragments.answers[name], name)
      composed++
    }
    assert.ok(composed >= 15, `composed ${composed}`)
  })

  test("parses every answer's fragment back to the answer", () => {
    for (const [name, text] of Object.entries(vectors.fragments.answers)) {
      assert.deepEqual(parseFragment(text), vectors.answers[name].answer, name)
    }
  })

  test("refuses a fragment past the bound before decoding it, and every other spelling", () => {
    for (const {name, error, fragment: text, repeat} of vectors.fragments.parse) {
      const input = text ?? repeat.char.repeat(repeat.length)
      assert.deepEqual(refusalOf(() => parseFragment(input)), {reason: error}, name)
    }
    assert.equal(vectors.max_fragment_bytes, 32768)
  })

  test("makes the passkey's registry answer into the bytes the registry verifies", async () => {
    const output = vectors.registry_output
    const {request} = vectors.requests[output.request]
    const made = vectors.answers[output.answer].answer
    const assertion = {authenticator_data: made.authenticator_data, client_data: made.client_data, signature: made.signature}
    const bytes = sent({...request.registry_request, signer: made.signer, sig: assertion})
    assert.equal(bytes, output.bytes)

    const {state} = await walk(vectors.identity.entries)
    assert.equal(state.directory, output.registry.directory)
    const key = state.keys.find((listed) => listed.kid === made.signer)
    const {origin, host} = directoryOrigin(state.directory)
    assert.equal(host, output.registry.host)
    const bytesOf = (field) => unb64(assertion[field], 1, 16384)
    const result = await verifyAssertion(
      {authenticator_data: bytesOf("authenticator_data"), client_data: bytesOf("client_data"), signature: bytesOf("signature")},
      unb64(key.pub, 65),
      await digest(request, made.signer),
      origin,
      host
    )
    assert.equal(result, "ok")
  })
})
