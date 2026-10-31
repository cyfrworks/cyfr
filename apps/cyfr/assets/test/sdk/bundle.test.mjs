// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The built SDK, priv/static/sdk/cyfr.js, run as a canvas's page runs it: a
// classic script after the page's `<base>`, before any script of the
// page's own. Its source's behaviour is the other tests' (client, wire);
// these hold the bundle to it: `window.cyfr` is there once the script has
// run, the shell's handshake and the page's uncaught errors reach it, and
// its requests resolve against the page's base.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {afterEach, describe, test} from "node:test"
import vm from "node:vm"

import {CREDENTIAL, HANDSHAKE, toFrameMessage} from "../../js/sdk/wire.js"
import {eventually, fixture} from "./support.mjs"

const BUNDLE = readFileSync(new URL("../../../priv/static/sdk/cyfr.js", import.meta.url), "utf8")

const [{frame: CANVAS, reply: OPEN}] = fixture.canvas.handshake.valid
const [{stream_path: STREAM_PATH}] = fixture.canvas.paths.valid.filter(({frame}) => frame === CANVAS)
const DECLARED = OPEN.canvas.streams[0]
const BASE = "https://cyfr.test/_s/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/local/canvas/0.3.0/dist/"

const ports = []
afterEach(() => {
  for (const port of ports.splice(0)) port.close()
})

// A canvas's page with the bundle run in it: its window (an event target
// whose parent is the shell's), a document whose base is the page's
// `<base>`, and a fetch that records each request and answers it with an
// empty event stream.
function page() {
  const win = new EventTarget()
  win.parent = {name: "shell"}
  win.location = {pathname: `/_c/v1/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/${CANVAS}`}
  const requests = []
  win.fetch = async (url, options) => {
    requests.push({url, options})
    return new Response("", {headers: {"content-type": "text/event-stream"}})
  }

  const context = vm.createContext({
    window: win,
    document: {baseURI: BASE},
    URL,
    TextDecoder,
    AbortController,
    queueMicrotask,
    setTimeout,
    clearTimeout
  })
  vm.runInContext(BUNDLE, context, {filename: "cyfr.js"})
  return {win, requests}
}

// The shell's handshake for a shown canvas, as the bridge posts it: the
// port on the window, then over it the canvas message, the credential and
// its state. Answers the shell's end of the port and every message heard
// on it.
function handshake(win) {
  const channel = new MessageChannel()
  ports.push(channel.port1)
  const heard = []
  channel.port1.onmessage = (event) => heard.push(event.data)
  win.dispatchEvent(
    Object.assign(new Event("message"), {
      source: win.parent,
      data: {v: 1, type: HANDSHAKE, frame: CANVAS},
      ports: [channel.port2]
    })
  )
  channel.port1.postMessage(toFrameMessage("canvas", CANVAS, OPEN.canvas))
  channel.port1.postMessage({v: 1, type: CREDENTIAL, frame: CANVAS, credential: OPEN.credential})
  channel.port1.postMessage(toFrameMessage("state", CANVAS, {state: "live"}))
  return heard
}

const failed = (stage) => ({v: 1, verb: "failed", frame: CANVAS, args: {stage}})

describe("the built SDK in a canvas's page", () => {
  test("sets window.cyfr as it runs, with the canvas's surface", () => {
    const {win} = page()
    assert.ok(Object.isFrozen(win.cyfr))
    for (const name of ["stream", "open", "press", "on", "ready"]) {
      assert.equal(typeof win.cyfr[name], "function", name)
    }
  })

  test("takes the shell's handshake from the window, and streams to the data path under the page's base", async () => {
    const {win, requests} = page()
    handshake(win)

    const handle = await win.cyfr.stream(DECLARED.name, DECLARED.subject, () => {})
    await handle.closed

    assert.equal(requests.length, 1)
    assert.equal(requests[0].url, new URL(STREAM_PATH, BASE).href)
    assert.equal(new URL(requests[0].url).origin, "https://cyfr.test")
    assert.deepEqual(JSON.parse(requests[0].options.body), {v: 1, stream: DECLARED.name, subject: DECLARED.subject})
  })

  test("hears the page's uncaught error before ready() as a failure to load", async () => {
    const {win} = page()
    win.dispatchEvent(Object.assign(new Event("error"), {message: "Uncaught TypeError: x is undefined"}))
    const heard = handshake(win)

    await eventually(() => heard.length === 1)
    assert.deepEqual(heard, [failed("load")])
  })

  test("hears nothing of the page's unhandled rejection after ready()", async () => {
    const {win} = page()
    const heard = handshake(win)
    win.cyfr.ready()
    await eventually(() => heard.length === 1)

    win.dispatchEvent(Object.assign(new Event("unhandledrejection"), {reason: new Error("no")}))
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.deepEqual(heard, [{v: 1, verb: "ready", frame: CANVAS, args: {}}])
  })
})
