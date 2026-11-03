// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The unlock page's script: it posts a ticket of the shape the shared
// vectors give (`tests/fixtures/device_unlock.json`'s `exchange`), takes it
// out of the address and the history before anything else, and posts
// nothing for a fragment that is not a ticket or a page without the form.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {dirname, resolve} from "node:path"
import {describe, test} from "node:test"
import {fileURLToPath} from "node:url"

import {completeUnlock, TICKET} from "../../js/device_unlock.js"

const here = dirname(fileURLToPath(import.meta.url))
const vectors = JSON.parse(readFileSync(resolve(here, "../../../../../tests/fixtures/device_unlock.json"), "utf8"))
const exchange = vectors.exchange

function page({hash, form = true}) {
  const events = []
  const input = {value: ""}
  const formEl = {
    querySelector: (selector) => (selector === "input[name='ticket']" ? input : null),
    submit: () => events.push(["submit", input.value])
  }

  const win = {
    document: {querySelector: (selector) => (form && selector === "form[data-device-unlock]" ? formEl : null)},
    location: {hash, pathname: exchange.http.unlock_complete.get},
    history: {replaceState: (_state, _title, url) => events.push(["replace", url])}
  }

  return {win, events, input}
}

describe("the unlock page", () => {
  const ticket = Buffer.alloc(exchange.ticket_bytes, 7).toString("base64url")

  test("a ticket is the exchange's 32 bytes in unpadded base64url", () => {
    assert.equal(exchange.units.ticket, "base64url_unpadded")
    assert.equal(TICKET.test(ticket), true)
    assert.equal(TICKET.test(ticket + "="), false)
    assert.equal(TICKET.test(ticket.slice(1)), false)
  })

  test("posts the fragment's ticket after removing it from the address and the history", () => {
    const {win, events} = page({hash: "#" + ticket})
    assert.equal(completeUnlock(win), true)
    assert.deepEqual(events, [
      ["replace", exchange.http.unlock_complete.get],
      ["submit", ticket]
    ])
    assert.deepEqual(exchange.http.unlock_complete.form.toSorted(), ["_csrf_token", "ticket"])
  })

  test("posts nothing for a fragment that is not a ticket, and still clears it", () => {
    for (const hash of ["", "#", "#short", "#" + ticket + "x", "#" + ticket.replace("B", "+")]) {
      const {win, events} = page({hash})
      assert.equal(completeUnlock(win), false, hash)
      assert.deepEqual(events, [["replace", exchange.http.unlock_complete.get]], hash)
    }
  })

  test("a page without the unlock form is left alone", () => {
    const {win, events} = page({hash: "#" + ticket, form: false})
    assert.equal(completeUnlock(win), false)
    assert.deepEqual(events, [])
  })
})
