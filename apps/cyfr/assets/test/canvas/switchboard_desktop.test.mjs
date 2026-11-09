// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The switchboard desktop (seed/components/tinctures/local/switchboard): its
// model, run here as the page runs it, in a context of its own with a
// stand-in for window.cyfr. How many stream requests it has in flight when
// the person's preferences turn parts off while their streams are opening.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

const MODEL = readFileSync(
  new URL("../../../../../seed/components/tinctures/local/switchboard/0.1.0/model.js", import.meta.url),
  "utf8"
)

// Preferences that turn off the parts four of the first five streams serve,
// and turn on two parts that wait in the spares.
const MOVED = {
  threads: {on: false},
  apps: {on: false},
  components: {on: false},
  runs: {on: false},
  vault: {on: true},
  crew: {on: true}
}

// The model started on a stand-in SDK whose opens answer after `answerMs`
// (never, when null), then handed MOVED; answers what it sent and the most
// requests that were ever in flight at once.
async function moved(answerMs) {
  const handlers = {}
  const sent = []
  let inFlight = 0
  let most = 0
  const sdk = {
    desktop: null,
    on(event, handler) {
      handlers[event] = handler
    },
    stream(name, subject) {
      sent.push(subject ? `feed:${subject}` : name)
      inFlight += 1
      most = Math.max(most, inFlight)
      if (answerMs === null) return new Promise(() => {})
      return new Promise((resolve) =>
        setTimeout(() => {
          resolve({
            close() {
              inFlight -= 1
            },
            closed: new Promise(() => {})
          })
        }, answerMs)
      )
    }
  }

  const page = {Map, Set, Object, Array, String, Number, Math, Promise, setTimeout, clearTimeout, requestAnimationFrame() {}}
  page.window = page
  vm.createContext(page)
  vm.runInContext(MODEL, page)
  page.SB.start(sdk, () => {})
  handlers.desktop({prefs: {document: {widgets: MOVED, desktop: {}}, revision: 1}})
  await new Promise((resolve) => setTimeout(resolve, 300))
  return {sent, inFlight, most, SB: page.SB}
}

test("a part turned off while its stream is opening keeps the requests in flight within five", async () => {
  const {sent, inFlight, most} = await moved(null)
  assert.equal(most, 5, `requests in flight at once: ${sent.join(", ")}`)
  assert.equal(inFlight, 5)
  assert.deepEqual(sent, ["attention.changes", "threads.changes", "components.changes", "runs.changes", "schedules.changes"])
})

test("once the stopped opens have their answers, the parts turned on open theirs, within five", async () => {
  const {inFlight, most, SB} = await moved(50)
  assert.equal(most, 5)
  assert.equal(inFlight, 4)
  for (const key of ["attention.changes", "schedules.changes", "vault.changes", "activity.changes"]) {
    assert.ok(SB.reading(key), key)
  }
  for (const key of ["threads.changes", "components.changes", "runs.changes"]) {
    assert.ok(!SB.reading(key), key)
  }
})

// The canvas wire's vectors: `stream_events["threads.changes"]`, a shared
// thread with its unread count and an own thread with none.
const WIRE = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/tincture_wire.json", import.meta.url), "utf8")
)

test("folds the wire's thread events, a shared thread's unread count and an own thread's null, whole", async () => {
  const events = WIRE.stream_events["threads.changes"].map(({event}) => event)
  assert.equal(events.length, 2)

  const handlers = {}
  const delivered = {}
  const sdk = {
    desktop: null,
    on(event, handler) {
      handlers[event] = handler
    },
    stream(name, _subject, onEvent) {
      delivered[name] = onEvent
      return Promise.resolve({close() {}, closed: new Promise(() => {})})
    }
  }

  const page = {Map, Set, Object, Array, String, Number, Math, Promise, setTimeout, clearTimeout, requestAnimationFrame() {}}
  page.window = page
  vm.createContext(page)
  vm.runInContext(MODEL, page)
  page.SB.start(sdk, () => {})
  handlers.desktop({prefs: {document: {widgets: {}, desktop: {}}, revision: 1}})
  await new Promise((resolve) => setTimeout(resolve, 50))

  assert.ok(delivered["threads.changes"], "the model reads threads.changes")
  for (const data of events) delivered["threads.changes"]({data})

  assert.deepEqual(JSON.parse(JSON.stringify(page.SB.threads())), events)
})
