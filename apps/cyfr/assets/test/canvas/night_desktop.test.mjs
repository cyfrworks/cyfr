// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The night desktop (seed/components/tinctures/local/night): its own page
// files, run here as the page runs them, in a context of their own with the
// SDK's client over a stand-in fetch and the few DOM calls the page makes.
// What it keeps in flight while its parts change.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

import {createClient} from "../../js/sdk/client.js"
import {CREDENTIAL, HANDSHAKE, toFrameMessage} from "../../js/sdk/wire.js"

const VERSION = new URL("../../../../../seed/components/tinctures/local/night/0.1.0/", import.meta.url)
const WIRE = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/tincture_wire.json", import.meta.url), "utf8"))
const MANIFEST = JSON.parse(readFileSync(new URL("cyfr-manifest.json", VERSION), "utf8"))

const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

// An element that takes every call the page makes and lays nothing out.
function element() {
  return {
    dataset: {},
    style: {setProperty() {}},
    classList: {add() {}, remove() {}, toggle() {}, contains: () => false},
    addEventListener() {},
    setAttribute() {},
    removeAttribute() {},
    getBoundingClientRect: () => ({left: 0, top: 0, right: 1024, bottom: 600, width: 1024, height: 600}),
    hidden: true,
    innerHTML: "",
  }
}

// The page's model.js and street.js under the SDK's client, whose stream
// opens never answer until the test settles them; answers every request
// the page made, by stream, with whether it is still in flight.
async function night(widgets) {
  const requests = []
  const win = {location: {pathname: "/_c/v1/review/frm_1"}, parent: {}}
  const {api, onWindowMessage} = createClient({
    win,
    base: "http://127.0.0.1:4000/",
    fetchFn: (_url, args) =>
      new Promise((_resolve, reject) => {
        const request = {stream: JSON.parse(args.body).stream, settled: false, signal: args.signal}
        request.settle = () => {
          request.settled = true
          reject(new TypeError("closed"))
        }
        args.signal.addEventListener("abort", () => request.settle())
        requests.push(request)
      }),
  })
  const elements = new Map(["street", "header", "wall", "level", "puddle-index", "plate", "fusebox"].map((id) => [`#${id}`, element()]))
  const document = {
    readyState: "complete",
    documentElement: element(),
    querySelector: (query) => elements.get(query) || null,
    querySelectorAll: () => [],
    addEventListener() {},
  }
  const page = {
    Intl, Date, Math, Number, String, JSON, Map, Set, Object, Array, Promise,
    document,
    cyfr: api,
    matchMedia: () => ({matches: true}),
    innerWidth: 1024,
    requestAnimationFrame: () => 1,
    setTimeout: () => 1,
    clearTimeout() {},
    setInterval: () => 1,
    addEventListener() {},
    performance: {now: () => 0},
  }
  page.window = page
  vm.createContext(page)
  for (const file of ["model.js", "street.js"]) vm.runInContext(readFileSync(new URL(file, VERSION), "utf8"), page)

  // The shell's open: the canvas block, with the stored preferences arriving
  // while the page's first opens are still in flight.
  const [{frame, reply}] = WIRE.canvas.handshake.valid
  const desk = MANIFEST.tincture.desktop
  const block = {
    ...reply.canvas,
    streams: [...desk.data.map((name) => ({name, subject: null})), ...desk.feeds.map((subject) => ({name: "feed.results", subject}))],
    prefs: {document: {widgets, desktop: {}}, revision: 1},
  }
  const channel = new MessageChannel()
  channel.port1.onmessage = () => {}
  onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame}, ports: [channel.port2]})
  channel.port1.postMessage(toFrameMessage("canvas", frame, block))
  channel.port1.postMessage({v: 1, type: CREDENTIAL, frame, credential: reply.credential})
  channel.port1.postMessage(toFrameMessage("state", frame, {state: "live"}))
  for (let i = 0; i < 20; i++) await tick()
  return {requests, close: () => (channel.port1.close(), channel.port2.close())}
}

const inFlight = (requests) => requests.filter((r) => !r.settled && !r.signal.aborted)

describe("the night desktop", () => {
  test("parts turned off while their streams still open keep no more than five opens in flight, and what waits opens once they settle", async () => {
    // The page opens the five the shipped parts read; the stored preferences
    // then cut the threads and the board and light the crew and the vault.
    const {requests, close} = await night({threads: {on: false}, board: {on: false}, crew: {on: true}, vault: {on: true}})
    try {
      assert.ok(requests.length <= 5, `${requests.length} opens sent: ${requests.map((r) => r.stream).join(", ")}`)
      assert.ok(inFlight(requests).length <= 5)

      // The cut parts' opens settle: the crew's and the vault's open then,
      // and no more than five are ever in flight.
      for (const r of requests.filter((r) => ["threads.changes", "schedules.changes", "runs.changes"].includes(r.stream))) r.settle()
      for (let i = 0; i < 20; i++) await tick()
      assert.ok(inFlight(requests).length <= 5)
      assert.deepEqual(inFlight(requests).map((r) => r.stream).sort(), ["activity.changes", "attention.changes", "components.changes", "vault.changes"])
    } finally {
      close()
    }
  })
})
