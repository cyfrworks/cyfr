// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The built SDK, priv/static/sdk/cyfr.js, run as a canvas's page runs it: a
// classic script after the page's `<base>`, before any script of the
// page's own. Its source's behaviour is the other tests' (client, wire);
// these hold the bundle to it: `window.cyfr` is there once the script has
// run, the shell's handshake and the page's uncaught errors reach it, and
// its stream connection resolves against the page's base.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {afterEach, describe, test} from "node:test"
import vm from "node:vm"

import {CREDENTIAL, HANDSHAKE, toFrameMessage} from "../../js/sdk/wire.js"
import {eventually, fixture, stubSockets} from "./support.mjs"

const BUNDLE = readFileSync(new URL("../../../priv/static/sdk/cyfr.js", import.meta.url), "utf8")

const [{frame: CANVAS, reply: OPEN}] = fixture.canvas.handshake.valid
const [{socket_path: SOCKET_PATH}] = fixture.canvas.paths.valid.filter(({frame}) => frame === CANVAS)
const DECLARED = OPEN.canvas.streams[0]
const BASE = "https://cyfr.test/_s/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/local/canvas/0.4.0/dist/"

const ports = []
afterEach(() => {
  for (const port of ports.splice(0)) port.close()
})

// A canvas's page with the bundle run in it: its window (an event target
// whose parent is the shell's), a document whose base is the page's
// `<base>`, and a WebSocket whose endpoint opens each subscription and
// ends it.
function page() {
  const win = new EventTarget()
  win.parent = {name: "shell"}
  win.location = {pathname: `/_c/v1/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/${CANVAS}`}
  win.fetch = async () => assert.fail("the page made no request")
  const endpoint = stubSockets({
    answer: ({type, sub}) =>
      type === "subscribe"
        ? [
            {v: 1, type: "subscribed", sub},
            {v: 1, type: "ended", sub}
          ]
        : []
  })
  win.WebSocket = function WebSocket(url) {
    return endpoint.socketFn(url)
  }

  const context = vm.createContext({
    window: win,
    document: {baseURI: BASE},
    URL,
    queueMicrotask,
    setTimeout,
    clearTimeout
  })
  vm.runInContext(BUNDLE, context, {filename: "cyfr.js"})
  return {win, sockets: endpoint.sockets}
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

  test("takes the shell's handshake from the window, and streams over the data path's connection under the page's base", async () => {
    const {win, sockets} = page()
    handshake(win)

    const handle = await win.cyfr.stream(DECLARED.name, DECLARED.subject, () => {})
    await handle.closed

    assert.equal(sockets.length, 1)
    assert.equal(sockets[0].url, new URL(SOCKET_PATH, BASE.replace(/^https:/, "wss:")).href)
    assert.equal(new URL(sockets[0].url).host, "cyfr.test")
    assert.deepEqual(sockets[0].sent, [
      {v: 1, type: "subscribe", sub: 1, credential: OPEN.credential, stream: DECLARED.name, subject: DECLARED.subject}
    ])
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
