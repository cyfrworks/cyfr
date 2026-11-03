// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The two pages a confirmation crosses between homes, as the fixture names
// them (`tests/fixtures/confirmation_assertion.json`): the person's own
// CYFR's `/carry` takes the deciding CYFR's request under `exchange.home`'s
// fragment key (`hooks/carry.js`), and the deciding CYFR's `/confirm` takes
// the certified assertion back under `exchange.deciding`'s callback
// fragment (`hooks/home_confirm.js`), read and cleared from the address
// before anything else.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {classify} from "../../js/hooks/carry.js"
import HomeConfirm, {homeAssertionFromFragment} from "../../js/hooks/home_confirm.js"

const vectors = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/confirmation_assertion.json", import.meta.url))
)
const b64 = (object) => Buffer.from(JSON.stringify(object)).toString("base64url")
const assertion = b64(vectors.assertions.valid.assertion)

function fakeWindow(pathname, hash = "") {
  const win = {
    location: {pathname, search: "", hash},
    history: {
      state: null,
      replaceState: (_state, _title, url) => {
        win.replaced = url
        win.location.hash = ""
      }
    }
  }
  return win
}

function mount(win) {
  const pushed = []
  const hook = Object.assign(Object.create(HomeConfirm), {win, el: {dataset: {}}, pushEvent: (event, payload) => pushed.push({event, payload})})
  hook.mounted()
  return pushed
}

describe("the deciding CYFR's /confirm", () => {
  test("is the fixture's callback, and the hook hands on the assertion its fragment carries", () => {
    const {path, fragment} = vectors.exchange.deciding.callback
    assert.equal(path, "/confirm")
    const win = fakeWindow(path, `#${fragment}=${assertion}`)
    assert.deepEqual(mount(win), [{event: "home_assertion", payload: {assertion}}])
    assert.equal(win.location.hash, "")
    assert.equal(win.replaced, path)
  })

  test("a fragment with no assertion, or one that is not base64url, hands on none", () => {
    assert.deepEqual(mount(fakeWindow("/confirm")), [{event: "home_assertion", payload: {assertion: null}}])
    assert.equal(homeAssertionFromFragment("home_assertion=a b"), null)
    assert.equal(homeAssertionFromFragment("other=abc"), null)
  })
})

describe("the person's own CYFR's /carry", () => {
  test("takes the request under the fixture's fragment key, as a change to confirm", () => {
    const {path, fragment} = vectors.exchange.home.page
    assert.equal(path, "/carry")
    const request = b64({audience: "https://hub.example", athanor: "ath_x", ref: "cnr_x", digest: "sha256:00", expires_at: 1, preview: {}})
    assert.deepEqual(classify(`${fragment}=${request}`), {kind: "confirm", value: request})
  })
})
