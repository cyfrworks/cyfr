// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {decodeRecoveryCode} from "../../js/system_layer/recovery_code.js"

const vectors = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/recovery_code.json", import.meta.url), "utf8"))

describe("decodeRecoveryCode", () => {
  test("reads each valid code to its identifier and secret", async () => {
    for (const {name, identifier, secret, code} of vectors.valid) {
      assert.deepEqual(await decodeRecoveryCode(code), {identifier, secret}, name)
    }
  })

  test("reads each spelling as its code", async () => {
    for (const {name, text, code} of vectors.spellings) {
      const read = await decodeRecoveryCode(code)
      assert.ok(read.identifier, name)
      assert.deepEqual(await decodeRecoveryCode(text), read, name)
    }
  })

  test("refuses each refused text with its error, and never rejects for input", async () => {
    for (const {name, text, error} of vectors.refused) {
      assert.deepEqual(await decodeRecoveryCode(text), {error}, name)
    }
    for (const input of [undefined, null, 42, {}, [], "", "CYFR"]) {
      assert.deepEqual(await decodeRecoveryCode(input), {error: "not_a_code"}, String(input))
    }
  })

  test("rejects only when there is no WebCrypto", async () => {
    const {code} = vectors.valid[0]
    await assert.rejects(decodeRecoveryCode(code, null), TypeError)
    await assert.rejects(decodeRecoveryCode(code, {}), TypeError)
    await assert.rejects(decodeRecoveryCode("not a code", {}), TypeError)
  })
})
