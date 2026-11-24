// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Update CYFR's page cyfr serves (internal/desktop/assets/update.js), run
// over the elements its own page has: it says how an update ended, in its
// status and its window's title, only for a run its own yes started and it
// saw run, or when the update reopened the app on it (updated); any other
// record, a terminal's update's last one among them, stays under What the
// last update said, with its time.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

const asset = (name) => readFileSync(new URL(`../../internal/desktop/assets/${name}`, import.meta.url), "utf8")
const script = asset("update.js")
const page = asset("update.html")

// The page opened at hash, its elements as its markup starts them; its
// reads never answer, and show is called as they would.
function opened(hash = "#read=r") {
  const elements = new Map()
  for (const [tag, id] of page.matchAll(/<[a-z0-9]+\b[^>]*\bid="([a-z]+)"[^>]*>/g)) {
    const listeners = {}
    elements.set(id, {hidden: /\shidden[\s>]/.test(tag), textContent: "", href: "", replaceChildren() {}, focus() {},
      addEventListener: (type, f) => { listeners[type] = f }, fire: (type) => listeners[type]?.({})})
  }
  const stored = new Map()
  const document = {title: "Update CYFR", getElementById: (id) => elements.get(id), createElement: () => ({}), addEventListener() {}}
  const context = vm.createContext({URLSearchParams, document, location: {hash}, history: {replaceState() {}},
    sessionStorage: {getItem: (k) => stored.get(k) ?? null, setItem: (k, v) => stored.set(k, v)}, fetch: () => new Promise(() => {})})
  vm.runInContext(script, context)
  return {show: (r) => context.show(r), $: (id) => elements.get(id), document}
}

const EARLIER = "The CYFR app is release 1.0.0."
const read = {offer: {offer: 1, app: "1.0.0", target: "1.1.0", step: "app", says: []}, record: EARLIER, outcome: EARLIER, at: "2026-11-24 12:00 UTC", seq: 2}

test("a record this page's yes did not start stays under its time, an update run at a terminal meanwhile or not", () => {
  const p = opened()
  p.show(read)
  p.show({...read, running: true, seq: 3})
  p.show({...read, seq: 4})
  assert.equal(p.document.title, "Update CYFR — release 1.1.0")
  assert.equal(p.$("status").hidden, true)
  assert.equal(p.$("when").textContent, "What the last update said, last written 2026-11-24 12:00 UTC")
})

test("the run this page's yes started, and saw run, is said once it ends", () => {
  const p = opened()
  p.show(read)
  p.$("yes").fire("click")
  p.show({...read, running: true, seq: 3})
  const ended = "The CYFR app of release 1.1.0 did not verify (x); nothing was changed and CYFR runs as it did"
  p.show({...read, record: ended, outcome: ended, seq: 4})
  assert.equal(p.document.title, `Update CYFR — ${ended} — release 1.1.0`)
  assert.equal(p.$("status").textContent, ended)
})

test("the app the update reopened on this page says how that update ended", () => {
  const p = opened("#read=r&updated=1")
  p.show({...read, offer: {offer: 1, app: "1.1.0", says: []}, outcome: "The CYFR app is release 1.1.0."})
  assert.equal(p.document.title, "Update CYFR — The CYFR app is release 1.1.0.")
})
