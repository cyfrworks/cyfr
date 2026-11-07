// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {unb64} from "../../account/encoding.js"
import {ed25519Key} from "../../account/identity.js"
import {REFUSALS, compose, handleAnswer, readToSign, refusal, signWith} from "../../account/registry.js"

const vectors = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/registry_wire.json", import.meta.url), "utf8"))

describe("registry_wire.json", () => {
  test("signs each request an account's birth sends with its recovery key, byte for byte", async () => {
    for (const name of ["birth_policy_accept", "birth_handle_claim"]) {
      const {request, signer} = vectors.requests[name]
      const key = await ed25519Key(unb64(vectors.keys[signer].seed, 32))
      const unsigned = compose({
        registry: request.registry,
        operation: request.operation,
        identifier: request.identifier,
        signer: request.signer,
        nonce: unb64(request.nonce, 16),
        now: request.expires_at - 120000,
        body: request.body
      })
      const {sig: _sig, ...expected} = request
      assert.deepEqual(unsigned, expected, name)
      assert.equal(await signWith(unsigned, key), JSON.stringify(Object.fromEntries(Object.entries(request).sort())), name)
    }
  })

  test("reads every Ed25519-signed request, without its signer and sig, as one to sign", () => {
    for (const [name, {request}] of Object.entries(vectors.requests)) {
      if (typeof request.sig !== "string") continue
      const {signer: _signer, sig: _sig, ...toSign} = request
      assert.equal(readToSign(toSign), toSign, name)
    }
  })

  test("reads each handle answer for the handle and registry asked, or its refusal", () => {
    for (const {name, bytes, handle, registry, result, error} of vectors.answers) {
      assert.deepEqual(handleAnswer(bytes, handle, registry), result ? {answer: result} : {error}, name)
    }
  })

  test("reads each envelope to its refusal and holds the registry's whole table", () => {
    for (const {name, bytes, refusal: expected, error} of vectors.envelopes) assert.equal(refusal(bytes), expected ?? error, name)
    assert.deepEqual(REFUSALS, Object.fromEntries(vectors.codes.map(({code, refusal: name}) => [code, name])))
  })
})
