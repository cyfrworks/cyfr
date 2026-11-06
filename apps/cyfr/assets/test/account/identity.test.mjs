// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {b64, fromHex, unb64} from "../../account/encoding.js"
import {
  ed25519Key,
  hash,
  identifier,
  identifierForUserId,
  kid,
  recoverySigner,
  signWith,
  userId,
  walk
} from "../../account/identity.js"
import {verifyAssertion} from "../../account/webauthn.js"

const vectors = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/identity.json", import.meta.url), "utf8"))

describe("identity.json", () => {
  test("derives each Ed25519 key from its seed and each kid from its public key", async () => {
    for (const [name, key] of Object.entries(vectors.keys)) {
      if (key.alg === "ed25519") assert.equal(b64((await ed25519Key(unb64(key.seed, 32))).pub), key.public, name)
      assert.equal(await kid(unb64(key.public, key.alg === "es256" ? 65 : 32)), key.kid, name)
    }
  })

  test("derives each recovery key from its seed and refuses a seed of another size", async () => {
    for (const {seed, public: pub} of vectors.kits.valid) assert.equal(b64((await ed25519Key(unb64(seed, 32))).pub), pub)
    for (const seed of vectors.kits.invalid) {
      const bytes = unb64(seed, 0, 64)
      assert.ok(bytes, seed)
      assert.equal(await ed25519Key(bytes), null, seed)
    }
  })

  test("re-signs every entry an Ed25519 key signs, byte for byte, and reproduces every hash", async () => {
    let resigned = 0
    for (const [name, {entry, hash: expected, signer}] of Object.entries(vectors.entries)) {
      assert.equal(await hash(entry), expected, name)
      const key = signer && vectors.keys[signer]
      if (!key || key.alg !== "ed25519" || typeof entry.sig !== "string") continue
      const signing = await ed25519Key(unb64(key.seed, 32))
      const {sig: _sig, ...unsigned} = entry
      assert.deepEqual(await signWith(unsigned, signing), entry, name)
      if (entry.signer.startsWith("recovery:")) assert.equal(await recoverySigner(signing.pub), entry.signer, name)
      resigned++
    }
    assert.ok(resigned > 30, `re-signed ${resigned}`)
  })

  test("reproduces each identifier from its genesis, and maps it to its user id and back", async () => {
    for (const [name, {identifier: expected, user_id}] of Object.entries(vectors.identifiers)) {
      const genesis = vectors.entries[`${name}_genesis`].entry
      assert.equal(await identifier(genesis), expected, name)
      assert.equal(b64(userId(expected)), user_id, name)
      assert.equal(identifierForUserId(unb64(user_id, 32)), expected, name)
    }
  })

  test("refuses what is no identifier and no user id", () => {
    for (const refused of vectors.user_ids.refused_identifiers) assert.equal(userId(refused), null, refused)
    for (const refused of vectors.user_ids.refused_user_ids) assert.equal(identifierForUserId(unb64(refused, 0, 64)), null, refused)
  })

  test("walks every chain to its state, or to the first entry refused and why", async () => {
    for (const chain of vectors.chains) {
      const entries = chain.entries.map((name) => vectors.entries[name].entry)
      const walked = await walk(entries)
      if (chain.state) assert.deepEqual(walked, {state: chain.state}, chain.name)
      else assert.deepEqual(walked, {error: chain.error}, chain.name)
    }
  })

  test("checks every WebAuthn assertion at its origin and relying party", async () => {
    for (const c of vectors.webauthn) {
      const assertion = Object.fromEntries(Object.entries(c.assertion).map(([field, value]) => [field, unb64(value, 1, 16384)]))
      const pub = unb64(vectors.keys[c.key].public, 65)
      const result = await verifyAssertion(assertion, pub, unb64(c.challenge, 32), c.origin, c.rp_id)
      assert.equal(result, c.result ?? c.error, c.name)
    }
  })

  test("refuses a signature whose DER integers are not in their fewest bytes, or are negative", async () => {
    const c = vectors.webauthn.find((v) => v.result === "ok")
    const bytes = Object.fromEntries(Object.entries(c.assertion).map(([field, value]) => [field, unb64(value, 1, 16384)]))
    const pub = unb64(vectors.keys[c.key].public, 65)
    const check = (signature) => verifyAssertion({...bytes, signature}, pub, unb64(c.challenge, 32), c.origin, c.rp_id)
    const der = bytes.signature
    assert.equal(await check(der), "ok")

    const rStart = 4
    const rSize = der[3]
    const sStart = rStart + rSize + 2
    const sSize = der[rStart + rSize + 1]
    const padded = (start) => {
      const out = new Uint8Array([...der.subarray(0, start), 0, ...der.subarray(start)])
      out[1]++
      out[start - 1]++
      return out
    }
    assert.equal(await check(padded(rStart)), "bad_signature", "a redundant zero before r")
    assert.equal(await check(padded(sStart)), "bad_signature", "a redundant zero before s")

    const [start, size] = der[rStart] === 0 ? [rStart, rSize] : [sStart, sSize]
    assert.equal(der[start], 0, "one integer of the vector needs its leading zero")
    const negative = new Uint8Array([...der.subarray(0, start), ...der.subarray(start + 1)])
    negative[1]--
    negative[start - 1]--
    assert.ok(size === 33)
    assert.equal(await check(negative), "bad_signature", "an integer whose high bit makes it negative")
  })

  test("a hex identifier and its digest bytes are one value", () => {
    const {identifier: alice} = vectors.identifiers.alice
    assert.deepEqual(userId(alice), fromHex(alice.slice(4)))
  })
})
