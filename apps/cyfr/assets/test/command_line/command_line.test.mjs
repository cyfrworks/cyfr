// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// `/cli`'s hook (`js/hooks/command_line.js`): the approval secret a
// command line's link carries in its fragment is read and cleared from
// the address before anything else, and handed to the page; anything that
// is no secret is handed on as none. The sign-in page a person not signed
// in is sent to clears the fragment the redirect carried there too.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import CommandLine from "../../js/hooks/command_line.js"
import Carry from "../../js/hooks/carry.js"

const secret = "q2mTb0yU7aKpXv1ZcR4n8w"

// A window at `pathname` with `hash` and its history.
function fakeWindow(pathname, hash = "") {
  const win = {
    replaced: [],
    sessionStorage: null,
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
  const hook = Object.assign(Object.create(CommandLine), {
    win,
    el: {dataset: {}},
    pushEvent: (event, payload) => pushed.push({event, payload})
  })
  hook.mounted()
  return pushed
}

describe("the command line's link", () => {
  test("hands the page its secret and clears it from the address at once", () => {
    const win = fakeWindow("/cli", "#code=" + secret)
    assert.deepEqual(mount(win), [{event: "cli_code", payload: {code: secret}}])
    assert.equal(win.location.hash, "")
    assert.deepEqual(win.replaced.map(({url}) => url), ["/cli"])
  })

  test("hands on none for an address with no fragment, and replaces nothing", () => {
    const win = fakeWindow("/cli")
    assert.deepEqual(mount(win), [{event: "cli_code", payload: {code: null}}])
    assert.deepEqual(win.replaced, [])
  })

  test("hands on none for a fragment that is no secret, and still clears it", () => {
    for (const hash of ["#code=short", "#code=" + secret + "x", "#token=" + secret, "#code=" + "+".repeat(22)]) {
      const win = fakeWindow("/cli", hash)
      assert.deepEqual(mount(win), [{event: "cli_code", payload: {code: null}}], hash)
      assert.equal(win.location.hash, "", hash)
    }
  })

  test("the sign-in page a redirect carried it to clears it and hands it nowhere", () => {
    const win = fakeWindow("/login", "#code=" + secret)
    const pushed = []
    const hook = Object.assign(Object.create(Carry), {
      win,
      el: {dataset: {carry: "login"}},
      now: () => 1_000_000,
      pushEvent: (event, payload) => pushed.push({event, payload}),
      handleEvent: () => {}
    })
    hook.mounted()
    assert.equal(win.location.hash, "")
    assert.deepEqual(pushed, [])
  })
})
