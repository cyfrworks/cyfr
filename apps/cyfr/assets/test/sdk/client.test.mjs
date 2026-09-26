// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, describe, test} from "node:test"

import {CyfrError, createClient} from "../../js/sdk/client.js"
import {CREDENTIAL, HANDSHAKE} from "../../js/sdk/wire.js"
import {credentialOf, eventually, fixture, frameWindow, nextMessage, stubServer} from "./support.mjs"

const FRAME = "frm_01a09fee2e4f"
const CREDENTIAL_VALUE = credentialOf(fixture.requests[0].headers.authorization)

const cleanups = []
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup()
})

// A frame's SDK against a stub endpoint answering each route from the
// fixture. `handshake()` plays the shell: it posts the handshake from the
// parent window and the credential over the port, and answers the shell's
// end of the port.
async function frameClient({answer, framed = true, pathname, handshakeTimeoutMs} = {}) {
  const server = await stubServer(answer || fixtureAnswer)
  cleanups.push(server.close)
  const win = frameWindow({framed, pathname})
  const {api, onWindowMessage} = createClient({win, fetchFn: fetch, base: server.base, handshakeTimeoutMs})

  const handshake = ({source = win.parent, frame = FRAME, credential = CREDENTIAL_VALUE} = {}) => {
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    onWindowMessage({source, data: {v: 1, type: HANDSHAKE, frame}, ports: [channel.port2]})
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame, credential})
    return channel.port1
  }

  return {api, onWindowMessage, handshake, server, win}
}

const route = (url) => Object.entries(fixture.routes).find(([, path]) => path === url)?.[0]

// A private version's page, which names no public tincture.
const PRIVATE_PATH = "/_s/SFMyNTY.c2lnbmVkLWFzc2V0/local/weather/1.0.0/index.html"

// The events a stream delivers, as the endpoint writes them: `id` the
// sequence number, `event` the projection, `data` the projected payload.
const EVENTS = [
  {id: 1, event: "delta", data: {seq: 1, delta: "Lis"}},
  {id: 2, event: "delta", data: {seq: 2, delta: "bon"}}
]

const sse = ({id, event, data}) => `id: ${id}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`

// Each event split across two writes, so the parser meets a chunk that ends
// mid-line; then the endpoint ends the stream, as its deadline does.
function streamEvents(res) {
  const text = ": open\n\n" + EVENTS.map(sse).join("")
  const cut = Math.floor(text.length / 2)
  res.write(text.slice(0, cut))
  setTimeout(() => res.end(text.slice(cut)), 5)
}

function fixtureAnswer(request) {
  const kind = route(request.url)
  if (kind === "stream_open") return {stream: streamEvents}
  return {body: fixture.answers.find((vector) => vector.kind === kind).body}
}

describe("data goes to the endpoint under the handshake's credential", () => {
  test("invoke, action and stream post the fixture's bodies with the bearer", async () => {
    const {api, handshake, server} = await frameClient()
    handshake()

    const [invoke, action, stream] = fixture.requests.map((vector) => vector.body)

    assert.deepEqual(await api.invoke(invoke.ref, invoke.operation, invoke.args), {temperature: 21})
    assert.deepEqual(await api.action(action.operation, action.args), {executions: []})

    const events = []
    const handle = await api.stream(stream.stream, stream.subject, (event) => events.push(event))
    await handle.closed
    assert.deepEqual(events, EVENTS)

    assert.equal(server.requests.length, 3)

    for (const [i, request] of server.requests.entries()) {
      const vector = fixture.requests[i]
      assert.equal(request.method, "POST")
      assert.equal(request.url, fixture.routes[vector.kind])
      assert.equal(request.headers.authorization, vector.headers.authorization)
      assert.deepEqual(request.body, vector.body)
      // The credential is a header, never in the URL or the body.
      assert.ok(!request.url.includes(CREDENTIAL_VALUE))
      assert.ok(!JSON.stringify(request.body).includes(CREDENTIAL_VALUE))
    }
  })

  test("a call made before the handshake waits for it", async () => {
    const {api, handshake, server} = await frameClient()
    const pending = api.action("execution.list", {limit: 5})

    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.equal(server.requests.length, 0)

    handshake()
    assert.deepEqual(await pending, {executions: []})
  })

  test("a refusal rejects with its class, sentence and stage", async () => {
    const {api, handshake} = await frameClient({answer: () => ({status: 403, body: fixture.refusal.body})})
    handshake()

    await assert.rejects(api.action("execution.list", {}), (error) => {
      assert.ok(error instanceof CyfrError)
      assert.equal(error.code, "forbidden")
      assert.equal(error.message, "This tincture does not declare that action.")
      assert.equal(error.stage, "admission")
      return true
    })
  })

  test("an answer that does not read is refused as such", async () => {
    const {api, handshake} = await frameClient({answer: () => ({body: "not json"})})
    handshake()
    await assert.rejects(api.invoke("c:local.weather:1.0.0", "run"), {code: "invalid_answer"})
  })

  test("arguments that are not the wire's are refused before anything is sent", async () => {
    const {api, handshake, server} = await frameClient()
    handshake()

    await assert.rejects(api.invoke("", "run"), {code: "invalid_argument"})
    await assert.rejects(api.invoke("c:local.weather", "run", [1]), {code: "invalid_argument"})
    await assert.rejects(api.stream("executions.deltas", 7, () => {}), {code: "invalid_argument"})
    await assert.rejects(api.stream("executions.deltas", null), {code: "invalid_argument"})
    assert.equal(server.requests.length, 0)
  })
})

describe("only the shell that created the frame hands it a port and a credential", () => {
  test("a top-level private page has no credential", async () => {
    const {api, server} = await frameClient({framed: false, pathname: PRIVATE_PATH})
    assert.equal(api.public, null)
    await assert.rejects(api.invoke("c:local.weather:1.0.0", "run"), {code: "no_frame"})
    await assert.rejects(api.stream("executions.deltas", null, () => {}), {code: "no_frame"})
    assert.equal(server.requests.length, 0)
  })

  test("a handshake from another window is ignored", async () => {
    const {api, handshake, server} = await frameClient({handshakeTimeoutMs: 50})
    handshake({source: {name: "another window"}})

    await assert.rejects(api.invoke("c:local.weather:1.0.0", "run"), {code: "no_frame"})
    assert.equal(api.frame, null)
    assert.equal(server.requests.length, 0)
  })

  test("a credential posted to the window rather than the port is ignored", async () => {
    const {api, onWindowMessage, win, server} = await frameClient({handshakeTimeoutMs: 50})
    onWindowMessage({
      source: win.parent,
      data: {v: 1, type: CREDENTIAL, frame: FRAME, credential: CREDENTIAL_VALUE},
      ports: []
    })

    await assert.rejects(api.action("execution.list", {}), {code: "no_frame"})
    assert.equal(server.requests.length, 0)
  })

  test("a second handshake changes nothing", async () => {
    const {api, handshake, server} = await frameClient()
    handshake()
    await api.action("execution.list", {})

    handshake({frame: "frm_someone_else", credential: "frm.v1.another"})
    await api.action("execution.list", {})

    assert.equal(api.frame, FRAME)
    assert.deepEqual(
      server.requests.map((request) => request.headers.authorization),
      [`Bearer ${CREDENTIAL_VALUE}`, `Bearer ${CREDENTIAL_VALUE}`]
    )
  })

  test("a credential for another frame, on the port, is ignored", async () => {
    const {api, onWindowMessage, win} = await frameClient({handshakeTimeoutMs: 50})
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [channel.port2]})
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame: "frm_someone_else", credential: "x"})

    await assert.rejects(api.action("execution.list", {}), {code: "no_frame"})
  })
})

describe("shell verbs go over the port", () => {
  test("each verb is the wire's message for this frame", async () => {
    const {api, handshake} = await frameClient()
    const shell = handshake()
    await eventually(() => api.frame === FRAME)

    for (const {verb, message} of fixture.shell) {
      const received = nextMessage(shell)
      if (verb === "open") api.open(message.args.ref)
      else if (verb === "title") api.title(message.args.title)
      else api[verb]()
      assert.deepEqual(await received, message, verb)
    }
  })

  test("verbs called before the handshake are sent once the port arrives", async () => {
    const {api, handshake} = await frameClient()
    api.ready()
    api.title("Lisbon")

    const shell = handshake()
    const received = []
    shell.onmessage = (event) => received.push(event.data)

    await eventually(() => received.length === 2)
    assert.deepEqual(
      received.map((message) => message.verb),
      ["ready", "title"]
    )
    assert.ok(received.every((message) => message.frame === FRAME))
  })

  test("outside a frame a verb does nothing", async () => {
    const {api} = await frameClient({framed: false})
    assert.equal(api.ready(), undefined)
  })
})

describe("a stream is delivered as the response's event stream", () => {
  async function opened(answer) {
    const client = await frameClient({answer})
    client.handshake()
    return client
  }

  test("each event reaches onEvent, and the stream ends with the endpoint's", async () => {
    const {api, server} = await opened(fixtureAnswer)
    const events = []
    const handle = await api.stream("executions.deltas", "exec_1", (event) => events.push(event))

    await handle.closed
    assert.deepEqual(events, EVENTS)
    assert.equal(server.requests[0].headers.authorization, `Bearer ${CREDENTIAL_VALUE}`)
  })

  test("close() aborts the request and delivers nothing more", async () => {
    let res
    const {api, server} = await opened(() => ({stream: (r) => (res = r).write(sse(EVENTS[0]))}))
    const events = []
    const handle = await api.stream("executions.deltas", null, (event) => events.push(event))

    await eventually(() => events.length === 1)
    handle.close()
    await handle.closed
    await eventually(() => server.requests[0].closed)

    res.write(sse(EVENTS[1]))
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.deepEqual(events, [EVENTS[0]])
  })

  test("a refusal rejects the open with its class, and delivers nothing", async () => {
    const {api} = await opened(() => ({status: 403, body: fixture.refusal.body}))
    const events = []

    await assert.rejects(api.stream("executions.deltas", null, (event) => events.push(event)), {
      code: "forbidden",
      stage: "admission"
    })
    assert.deepEqual(events, [])
  })

  test("a JSON answer that is not a refusal is no stream", async () => {
    const grant = fixture.answers.find((vector) => vector.kind === "stream_open").body
    const {api} = await opened(() => ({body: grant}))
    await assert.rejects(api.stream("executions.deltas", null, () => {}), {code: "invalid_answer"})
  })

  test("a handler that throws does not end the stream", async () => {
    const {api} = await opened(fixtureAnswer)
    const seen = []
    const handle = await api.stream("executions.deltas", null, (event) => {
      seen.push(event.id)
      throw new Error("the page's own bug")
    })

    await handle.closed
    assert.deepEqual(seen, [1, 2])
  })
})

describe("a public tincture's top-level page names itself", () => {
  test("its requests carry public and no bearer, and its streams too", async () => {
    const {api, server} = await frameClient({framed: false})
    const identity = {athanor: "home", publisher: "local", name: "weather"}
    assert.deepEqual(api.public, identity)

    const [invoke] = fixture.requests.map((vector) => vector.body)
    assert.deepEqual(await api.invoke(invoke.ref, invoke.operation, invoke.args), {temperature: 21})
    const handle = await api.stream("executions.deltas", null, () => {})
    await handle.closed

    for (const request of server.requests) {
      assert.equal(request.headers.authorization, undefined)
      assert.deepEqual(request.body.public, identity)
    }

    assert.deepEqual(server.requests[0].body, {...invoke, public: identity})
  })

  test("a personal athanor's segment and an encoded path read the same", async () => {
    const {api} = await frameClient({framed: false, pathname: "/t/%40alice/stripe.com/pay-desk/"})
    assert.deepEqual(api.public, {athanor: "@alice", publisher: "stripe.com", name: "pay-desk"})
  })

  test("a framed page waits for its shell even at a /t/ path", async () => {
    const {api, server} = await frameClient({handshakeTimeoutMs: 50})
    assert.equal(api.public, null)
    await assert.rejects(api.action("execution.list", {}), {code: "no_frame"})
    assert.equal(server.requests.length, 0)
  })
})
