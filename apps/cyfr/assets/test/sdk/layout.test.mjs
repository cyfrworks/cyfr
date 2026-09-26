// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {createHash} from "node:crypto"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

// The vectors `Prima.Layout`'s and `Prima.ConfirmationClass`'s tests read too.
const fixture = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/layout.json", import.meta.url), "utf8")
)

// RFC 8785 over the layout's domain (strings, integers, booleans, arrays,
// objects): keys in UTF-16 code-unit order, which is what `sort()` compares,
// and strings as `JSON.stringify` writes them.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`
  if (value !== null && typeof value === "object") {
    const keys = Object.keys(value).sort()
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`
  }
  return JSON.stringify(value)
}

describe("the layout document agrees with the fixture", () => {
  test("the valid document's canonical bytes and digest are the fixture's", () => {
    assert.equal(canonical(fixture.valid), fixture.canonical)
    const digest = "sha256:" + createHash("sha256").update(fixture.canonical, "utf8").digest("hex")
    assert.equal(digest, fixture.digest)
  })

  test("every refused document says why", () => {
    assert.ok(fixture.invalid.length > 0)
    for (const {why, document} of fixture.invalid) {
      assert.equal(typeof why, "string")
      assert.equal(typeof document, "object")
    }
  })

  test("the confirmation classes are the four, least first", () => {
    assert.deepEqual(fixture.confirmation_classes, ["none", "session", "paired", "strong"])
  })
})
