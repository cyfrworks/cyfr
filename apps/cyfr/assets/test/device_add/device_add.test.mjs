// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// `/devices/add`'s hook (`js/hooks/device_add.js`): the key digest a new
// device's QR code carries in its fragment (the fixture's
// `exchange.pairing.approve_url`) is read and cleared from the address
// before anything else, and handed to the page; anything that is no
// digest is handed on as none.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import DeviceAdd, {keyDigestFromFragment} from "../../js/hooks/device_add.js"

const vectors = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/device_unlock.json", import.meta.url))
)
const digest = "VuvwnjcI5bKkUvYLeH7B7Y-xHIrpKvaDLettMxKZg2c"

function fakeWindow(pathname, hash = "") {
  const win = {
    replaced: [],
    sessionStorage: null,
    document: {addEventListener: () => {}, removeEventListener: () => {}},
    location: {pathname, search: "", hash, assign: () => {}},
    history: {
      state: {live: true},
      replaceState: (state, _title, url) => {
        win.replaced.push({state, url})
        win.location.hash = ""
      }
    }
  }
  return win
}

function mount(win) {
  const pushed = []
  const hook = Object.assign(Object.create(DeviceAdd), {
    win,
    el: {dataset: {}},
    pushEvent: (event, payload) => pushed.push({event, payload})
  })
  hook.mounted()
  return pushed
}

describe("the new device's QR address", () => {
  test("the fixture's address carries the digest the hook reads", () => {
    const url = new URL(
      vectors.exchange.pairing.approve_url
        .replace("{home}", "https://alice.example")
        .replace("{key_digest}", digest)
    )
    assert.equal(url.pathname, "/devices/add")
    assert.equal(keyDigestFromFragment(url.hash), digest)
  })

  test("hands the page the digest and clears it from the address at once", () => {
    const win = fakeWindow("/devices/add", "#key=" + digest)
    assert.deepEqual(mount(win), [{event: "device_key", payload: {key_digest: digest}}])
    assert.equal(win.location.hash, "")
    assert.deepEqual(win.replaced.map(({url}) => url), ["/devices/add"])
  })

  test("hands on none for an address with no fragment, or one that names no digest", () => {
    assert.deepEqual(mount(fakeWindow("/devices/add")), [{event: "device_key", payload: {key_digest: null}}])

    for (const hash of ["#key=short", "#key=" + digest + "x", "#code=" + digest, "#key=" + "+".repeat(43)]) {
      const win = fakeWindow("/devices/add", hash)
      assert.deepEqual(mount(win), [{event: "device_key", payload: {key_digest: null}}], hash)
      assert.equal(win.location.hash, "", hash)
    }
  })
})
