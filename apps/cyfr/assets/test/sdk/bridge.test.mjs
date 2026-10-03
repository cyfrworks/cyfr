// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, describe, test} from "node:test"

import IframeBridge from "../../js/hooks/iframe_bridge.js"
import {createClient} from "../../js/sdk/client.js"
import {CREDENTIAL, HANDSHAKE} from "../../js/sdk/wire.js"
import {credentialOf, eventually, fixture, frameWindow} from "./support.mjs"

const FRAME = "frm_01a09fee2e4f"
const CREDENTIAL_VALUE = credentialOf(fixture.requests[0].headers.authorization)

const hooks = []
afterEach(() => {
  for (const hook of hooks.splice(0)) hook.destroyed()
})

// The hook mounted on a frame element, with the view played by `pushEvent`:
// the handshake is answered with `reply`, and every event is recorded. What
// the shell posts to the frame's window is recorded in `posted`.
function mountBridge({reply = {credential: CREDENTIAL_VALUE}} = {}) {
  const posted = []
  const events = []
  const el = new EventTarget()
  el.dataset = {frameId: FRAME}
  el.contentWindow = {postMessage: (data, origin, transfer) => posted.push({data, origin, transfer})}

  const hook = Object.assign(Object.create(IframeBridge), {
    el,
    pushEvent(event, payload, onReply) {
      events.push({event, payload})
      if (event === "frame_handshake" && onReply) onReply(reply)
    }
  })

  hook.mounted()
  hooks.push(hook)
  return {hook, el, posted, events, load: () => el.dispatchEvent(new Event("load"))}
}

// The frame's end of the handshake: its port and the first message on it.
async function frameEnd(posted) {
  const [{transfer}] = posted
  const port = transfer[0]
  const first = new Promise((resolve) => {
    port.onmessage = (event) => resolve(event.data)
  })
  return {port, first: await first}
}

describe("the handshake", () => {
  test("the first load posts a port and the frame id; the credential goes over the port", async () => {
    const {posted, events, load} = mountBridge()
    load()

    assert.deepEqual(events, [{event: "frame_handshake", payload: {frame: FRAME}}])
    assert.equal(posted.length, 1)

    const [{data, origin, transfer}] = posted
    assert.deepEqual(data, {v: 1, type: HANDSHAKE, frame: FRAME})
    assert.equal(origin, "*")
    assert.equal(transfer.length, 1)
    assert.ok(!JSON.stringify(data).includes(CREDENTIAL_VALUE))

    const {port, first} = await frameEnd(posted)
    assert.deepEqual(first, {v: 1, type: CREDENTIAL, frame: FRAME, credential: CREDENTIAL_VALUE})
    port.close()
  })

  test("a view that answers no credential gets no handshake", () => {
    const {posted, load} = mountBridge({reply: {error: "no_credential"}})
    load()
    assert.equal(posted.length, 0)
  })

  test("a later load gets no second handshake, and the port is closed", async () => {
    const {hook, posted, events, load} = mountBridge()
    load()
    const {port} = await frameEnd(posted)

    load()
    assert.equal(events.length, 1)
    assert.equal(posted.length, 1)
    assert.equal(hook._port, null)

    // A verb on the closed port reaches nothing.
    port.postMessage(fixture.shell[3].message)
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.equal(events.length, 1)
    port.close()
  })

  test("the bridge listens to no window message", () => {
    const added = []
    const previous = globalThis.window
    globalThis.window = {addEventListener: (type) => added.push(type)}

    try {
      mountBridge().load()
      assert.deepEqual(added, [])
    } finally {
      if (previous === undefined) delete globalThis.window
      else globalThis.window = previous
    }
  })
})

describe("what the port carries", () => {
  async function connected() {
    const bridge = mountBridge()
    bridge.load()
    const {port} = await frameEnd(bridge.posted)
    return {...bridge, port}
  }

  test("each shell verb reaches the view as frame_verb for this frame", async () => {
    const {port, events} = await connected()

    for (const {message} of fixture.shell) port.postMessage(message)

    await eventually(() => events.length === 1 + fixture.shell.length)
    assert.deepEqual(
      events.slice(1),
      fixture.shell.map(({message}) => ({event: "frame_verb", payload: {frame: FRAME, message}}))
    )
    port.close()
  })

  test("a verb carrying data, another frame's verb and a data request are dropped and counted", async () => {
    const {hook, el, port, events} = await connected()

    port.postMessage({v: 1, verb: "ready", frame: FRAME, args: {payload: {input: 1}}})
    port.postMessage({v: 1, verb: "ready", frame: "frm_another_frame", args: {}})
    port.postMessage({type: "cyfr:request", action: "invoke", id: "req_1", payload: {}})
    port.postMessage({v: 1, verb: "invoke", frame: FRAME, args: {}})

    await eventually(() => hook.dropped === 4)
    assert.equal(el.dataset.dropped, "4")
    assert.equal(events.length, 1)
    port.close()
  })
})

describe("the SDK and the bridge together", () => {
  test("a frame's ready() reaches the view through the port the bridge handed it", async () => {
    const {posted, events, load} = mountBridge()
    const win = frameWindow()
    const {api, onWindowMessage} = createClient({win, fetchFn: fetch, base: "http://127.0.0.1/"})

    load()
    const [{data, transfer}] = posted
    onWindowMessage({source: win.parent, data, ports: transfer})
    await eventually(() => api.frame === FRAME)

    api.ready()
    await eventually(() => events.length === 2)
    assert.deepEqual(events[1], {
      event: "frame_verb",
      payload: {frame: FRAME, message: {v: 1, verb: "ready", frame: FRAME, args: {}}}
    })
    transfer[0].close()
  })
})
