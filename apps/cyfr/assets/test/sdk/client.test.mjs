// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, describe, test} from "node:test"

import {CyfrError, createClient} from "../../js/sdk/client.js"
import {CREDENTIAL, HANDSHAKE, credentialClosed, toFrameMessage} from "../../js/sdk/wire.js"
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
async function frameClient({answer, framed = true, pathname, handshakeTimeoutMs, fetchFn = fetch} = {}) {
  const server = await stubServer(answer || fixtureAnswer)
  cleanups.push(server.close)
  const win = frameWindow({framed, pathname})
  const {api, onWindowMessage, onPageError} = createClient({win, fetchFn, base: server.base, handshakeTimeoutMs})

  const handshake = ({source = win.parent, frame = FRAME, credential = CREDENTIAL_VALUE} = {}) => {
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    onWindowMessage({source, data: {v: 1, type: HANDSHAKE, frame}, ports: [channel.port2]})
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame, credential})
    return channel.port1
  }

  return {api, onWindowMessage, onPageError, handshake, server, win}
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

describe("the shell replaces the credential over the port", () => {
  const RENEWED = "frm.v2.cmVuZXdlZC1mcmFtZS1jcmVkZW50aWFs"
  const renewal = (credential = RENEWED, frame = FRAME) => ({v: 1, type: CREDENTIAL, frame, credential})

  // Everything posted on the shell's end of the port before this has been
  // read once it resolves: a port delivers in order, and a closed prompt
  // is the next thing the SDK answers.
  async function settled(api, shell) {
    const closed = api.credential("sync")
    shell.postMessage(credentialClosed(FRAME, false))
    await closed
  }

  const authorizations = (server) => server.requests.map((request) => credentialOf(request.headers.authorization))

  test("a later request is made under the replacement", async () => {
    const {api, handshake, server} = await frameClient()
    const shell = handshake()
    const [invoke] = fixture.requests.map((vector) => vector.body)

    await api.invoke(invoke.ref, invoke.operation, invoke.args)
    shell.postMessage(renewal())
    await settled(api, shell)
    await api.invoke(invoke.ref, invoke.operation, invoke.args)

    assert.deepEqual(authorizations(server), [CREDENTIAL_VALUE, RENEWED])
    assert.equal(server.requests[1].headers.authorization, `Bearer ${RENEWED}`)
  })

  test("one for another frame, or not on the port, is ignored; the same one addressed rightly is taken", async () => {
    const {api, handshake, onWindowMessage, server, win} = await frameClient()
    const shell = handshake()
    const [invoke] = fixture.requests.map((vector) => vector.body)

    shell.postMessage(renewal("frm.v2.another-frames", "frm_someone_else"))
    shell.postMessage(renewal(""))
    shell.postMessage({...renewal(), v: 2})
    onWindowMessage({source: win.parent, data: renewal("frm.v2.from-the-window"), ports: []})
    await settled(api, shell)
    await api.invoke(invoke.ref, invoke.operation, invoke.args)

    // The positive control: the same message, on the port, for this frame.
    shell.postMessage(renewal("frm.v2.another-frames"))
    await settled(api, shell)
    await api.invoke(invoke.ref, invoke.operation, invoke.args)

    assert.deepEqual(authorizations(server), [CREDENTIAL_VALUE, "frm.v2.another-frames"])
  })

  test("a request or a stream already sent keeps the credential it was sent with", async () => {
    const sent = []
    const fetchFn = (url, options) => {
      sent.push(credentialOf(options.headers.authorization))
      return fetch(url, options)
    }
    const {api, handshake, server} = await frameClient({fetchFn})
    const shell = handshake()
    const [invoke, , stream] = fixture.requests.map((vector) => vector.body)

    const events = []
    const opened = api.stream(stream.stream, stream.subject, (event) => events.push(event))
    const inFlight = api.invoke(invoke.ref, invoke.operation, invoke.args)
    await eventually(() => sent.length === 2)

    shell.postMessage(renewal())
    await settled(api, shell)

    assert.deepEqual(await inFlight, {temperature: 21})
    const handle = await opened
    await handle.closed
    assert.deepEqual(events, EVENTS)

    await api.invoke(invoke.ref, invoke.operation, invoke.args)
    assert.deepEqual(sent, [CREDENTIAL_VALUE, CREDENTIAL_VALUE, RENEWED])
    assert.deepEqual(authorizations(server).sort(), [CREDENTIAL_VALUE, CREDENTIAL_VALUE, RENEWED].sort())
  })
})

describe("shell verbs go over the port", () => {
  // A canvas's own verbs, `press` and `failed`, are its page's alone (below).
  test("each verb is the wire's message for this frame", async () => {
    const {api, handshake} = await frameClient()
    const shell = handshake()
    await eventually(() => api.frame === FRAME)

    for (const {verb, message} of fixture.shell.filter(({verb}) => verb !== "press" && verb !== "failed")) {
      const received = nextMessage(shell)
      if (verb === "open") api.open(message.args.ref)
      else if (verb === "title") api.title(message.args.title)
      else if (verb === "credential") api.credential(message.args.name)
      else api[verb]()
      assert.deepEqual(await received, message, verb)
    }
  })

  test("a page that is no canvas sends no press and no failure", async () => {
    const {api, handshake, onPageError} = await frameClient()
    const shell = handshake()
    const received = []
    shell.onmessage = (event) => received.push(event.data)
    const press = fixture.shell.find((vector) => vector.verb === "press").message.args

    onPageError({message: "the page's own bug"})
    api.press(press.binding, press.action)
    // The positive control: a verb after them arrives, alone.
    api.ready()

    await eventually(() => received.length === 1)
    await new Promise((resolve) => setTimeout(resolve, 20))
    assert.deepEqual(received, [{v: 1, verb: "ready", frame: FRAME, args: {}}])
  })

  test("there is no verb that raises the frame", async () => {
    const {api} = await frameClient()
    assert.equal(api.focus, undefined)
  })
})

describe("a credential is asked for through the shell's prompt", () => {
  test("the prompt's close resolves with whether an entry was saved, and nothing else", async () => {
    const {api, handshake} = await frameClient()
    const shell = handshake()
    await eventually(() => api.frame === FRAME)

    const asked = nextMessage(shell)
    const answer = api.credential("weather-api")
    assert.deepEqual(await asked, fixture.shell.find((vector) => vector.verb === "credential").message)

    // Another frame's close, a close carrying more, and an unknown type are ignored.
    shell.postMessage(credentialClosed("frm_someone_else", true))
    shell.postMessage({...credentialClosed(FRAME, true), value: "s3cret"})
    shell.postMessage({v: 1, type: "cyfr:credential-value", frame: FRAME, value: "s3cret"})
    shell.postMessage(credentialClosed(FRAME, false))

    assert.deepEqual(await answer, {saved: false})

    // The next ask is its own.
    const again = api.credential("weather-api")
    shell.postMessage(credentialClosed(FRAME, true))
    assert.deepEqual(await again, {saved: true})
  })

  test("one prompt at a time, a name is required, and a page that is no frame has no shell", async () => {
    const {api, handshake} = await frameClient()
    handshake()
    const first = api.credential("one")
    await assert.rejects(api.credential("two"), {code: "pending"})
    await assert.rejects(api.credential(""), {code: "invalid_argument"})
    assert.ok(first instanceof Promise)

    const outside = await frameClient({framed: false})
    await assert.rejects(outside.api.credential("one"), {code: "no_frame"})
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

// ---- a canvas's page ----------------------------------------------------------

// The fixture's canvas open: its frame, credential and canvas block, as the
// shell's handshake reply carries them, and the route its streams take.
const [{frame: CANVAS, reply: OPEN}] = fixture.canvas.handshake.valid
const [{stream_path: STREAM_PATH}] = fixture.canvas.paths.valid.filter(({frame}) => frame === CANVAS)
const DECLARED = OPEN.canvas.streams[0]
const PRESS = fixture.shell.find((vector) => vector.verb === "press").message.args

// A canvas page's SDK. `open()` plays the bridge for a canvas: the
// handshake from the parent window, then over the port the canvas message,
// the credential and anything in `told`; `heard` is every message the page
// posts the shell.
async function canvasClient({block = OPEN.canvas} = {}) {
  const answer = (request) => (request.url === STREAM_PATH ? {stream: streamEvents} : fixtureAnswer(request))
  const client = await frameClient({answer})
  const heard = []

  const open = (told = []) => {
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    channel.port1.onmessage = (event) => heard.push(event.data)
    client.onWindowMessage({source: client.win.parent, data: {v: 1, type: HANDSHAKE, frame: CANVAS}, ports: [channel.port2]})
    channel.port1.postMessage(toFrameMessage("canvas", CANVAS, block))
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame: CANVAS, credential: OPEN.credential})
    for (const [verb, args] of told) channel.port1.postMessage(toFrameMessage(verb, CANVAS, args))
    return channel.port1
  }

  return {...client, open, heard}
}

// Everything posted on the port before this has been read once it resolves:
// a port delivers in order, and the SDK's own verbs answer in order too.
async function settled({api, heard}) {
  const count = heard.length
  api.ready()
  await eventually(() => heard.length > count)
}

// What the page heard of what the shell told it, after the port drained.
const tick = () => new Promise((resolve) => setTimeout(resolve, 20))

describe("a canvas's streams go to its open's data path", () => {
  test("a declared stream posts the stream body to the stream route, under the canvas's credential", async () => {
    const {api, open, server} = await canvasClient()
    open()

    const events = []
    const handle = await api.stream(DECLARED.name, DECLARED.subject, (event) => events.push(event))
    await handle.closed

    assert.deepEqual(events, EVENTS)
    assert.equal(server.requests.length, 1)
    const [request] = server.requests
    assert.equal(request.method, "POST")
    assert.equal(request.url, STREAM_PATH)
    assert.equal(request.headers.authorization, `Bearer ${OPEN.credential}`)
    assert.deepEqual(request.body, {v: 1, stream: DECLARED.name, subject: DECLARED.subject})
  })

  test("a stream asked for before the handshake goes there once the canvas is open", async () => {
    const {api, open, server} = await canvasClient()
    const opened = api.stream(DECLARED.name, DECLARED.subject, () => {})
    await tick()
    assert.equal(server.requests.length, 0)

    open()
    await (await opened).closed
    assert.deepEqual(
      server.requests.map((request) => request.url),
      [STREAM_PATH]
    )
  })

  test("a pair the canvas does not declare is refused before anything is sent", async () => {
    const {api, open, server} = await canvasClient()
    open()

    for (const [name, subject] of [
      ["executions.deltas", null],
      [DECLARED.name, "doge"],
      [DECLARED.name, null]
    ]) {
      await assert.rejects(api.stream(name, subject, () => {}), (error) => {
        assert.ok(error instanceof CyfrError)
        assert.equal(error.code, "forbidden")
        assert.equal(error.stage, "admission")
        return true
      })
    }
    assert.equal(server.requests.length, 0)
  })

  test("a canvas that declares nothing opens no stream", async () => {
    const {api, open, server} = await canvasClient({block: {...OPEN.canvas, streams: []}})
    open()
    await assert.rejects(api.stream(DECLARED.name, DECLARED.subject, () => {}), {code: "forbidden"})
    assert.equal(server.requests.length, 0)
  })

  test("a second canvas message, or one for another frame, changes nothing", async () => {
    const {api, open, server} = await canvasClient()
    const shell = open()
    shell.postMessage(toFrameMessage("canvas", CANVAS, {...OPEN.canvas, streams: [{name: "executions.deltas", subject: null}]}))
    shell.postMessage(
      toFrameMessage("canvas", "frm_00aa11bb22", {
        mode: "live",
        data_path: "/_f/v1/o/frm_00aa11bb22/",
        streams: [{name: "executions.deltas", subject: null}]
      })
    )
    await tick()

    await assert.rejects(api.stream("executions.deltas", null, () => {}), {code: "forbidden"})
    await (await api.stream(DECLARED.name, DECLARED.subject, () => {})).closed
    assert.deepEqual(
      server.requests.map((request) => request.url),
      [STREAM_PATH]
    )
  })
})

describe("a canvas asks the shell", () => {
  test("press is the wire's press for this frame", async () => {
    const {api, open, heard} = await canvasClient()
    open()
    await eventually(() => api.frame === CANVAS)

    api.press(PRESS.binding, PRESS.action)
    api.open("t:local.weather-lookup")
    api.ready()

    await eventually(() => heard.length === 3)
    assert.deepEqual(heard, [
      {v: 1, verb: "press", frame: CANVAS, args: PRESS},
      {v: 1, verb: "open", frame: CANVAS, args: {ref: "t:local.weather-lookup"}},
      {v: 1, verb: "ready", frame: CANVAS, args: {}}
    ])
  })
})

describe("a canvas hears what the shell tells it", () => {
  const [installed] = fixture.canvas.to_frame.valid.filter(({message}) => message.verb === "installed")
  const [covered] = fixture.canvas.to_frame.valid.filter(
    ({message}) => message.verb === "covered" && message.args.rects.length > 0
  )

  test("each of installed, posture, covered and state, as its value", async () => {
    const {api, open} = await canvasClient()
    const seen = []
    for (const event of ["installed", "posture", "covered", "state"]) {
      api.on(event, (value) => seen.push([event, value]))
    }

    open([
      ["installed", installed.message.args],
      ["posture", {posture: "hand"}],
      ["covered", covered.message.args],
      ["state", {state: "frozen"}]
    ])

    await eventually(() => seen.length === 4)
    assert.deepEqual(seen, [
      ["installed", installed.message.args.tinctures],
      ["posture", "hand"],
      ["covered", covered.message.args.rects],
      ["state", "frozen"]
    ])
  })

  test("a handler that comes late is handed the latest value first, then each after", async () => {
    const client = await canvasClient()
    const shell = client.open([
      ["posture", {posture: "desk"}],
      ["posture", {posture: "hand"}]
    ])
    await settled(client)
    await tick()

    const {api} = client
    const late = []
    api.on("posture", (value) => late.push(value))
    await tick()
    assert.deepEqual(late, ["hand"])

    shell.postMessage(toFrameMessage("posture", CANVAS, {posture: "desk"}))
    await eventually(() => late.length === 2)
    assert.deepEqual(late, ["hand", "desk"])

    // Nothing told yet: a handler hears nothing until something comes.
    const none = []
    api.on("installed", (value) => none.push(value))
    await tick()
    assert.deepEqual(none, [])
  })

  test("the function on returns stops its handler alone", async () => {
    const {api, open} = await canvasClient()
    const shell = open()
    const kept = []
    const stopped = []
    api.on("state", (value) => kept.push(value))
    const stop = api.on("state", (value) => stopped.push(value))

    shell.postMessage(toFrameMessage("state", CANVAS, {state: "frozen"}))
    await eventually(() => kept.length === 1 && stopped.length === 1)
    stop()
    shell.postMessage(toFrameMessage("state", CANVAS, {state: "live"}))
    await eventually(() => kept.length === 2)
    await tick()

    assert.deepEqual(kept, ["frozen", "live"])
    assert.deepEqual(stopped, ["frozen"])
  })

  test("what the wire refuses, another frame's, and anything told a page that is no canvas reach no handler", async () => {
    const {api, open} = await canvasClient()
    const shell = open()
    const seen = []
    api.on("posture", (value) => seen.push(value))

    shell.postMessage({v: 1, verb: "posture", frame: CANVAS, args: {posture: "lap"}})
    shell.postMessage({v: 1, verb: "posture", frame: "frm_00aa11bb22", args: {posture: "hand"}})
    shell.postMessage(toFrameMessage("posture", CANVAS, {posture: "hand"}))
    await eventually(() => seen.length === 1)
    await tick()
    assert.deepEqual(seen, ["hand"])

    const plain = await frameClient()
    const port = plain.handshake()
    const unheard = []
    plain.api.on("posture", (value) => unheard.push(value))
    port.postMessage(toFrameMessage("posture", FRAME, {posture: "hand"}))
    await tick()
    assert.deepEqual(unheard, [])
  })

  test("on takes the four events and a function", async () => {
    const {api} = await canvasClient()
    assert.throws(() => api.on("canvas", () => {}), TypeError)
    assert.throws(() => api.on("tree", () => {}), TypeError)
    assert.throws(() => api.on("posture"), TypeError)
  })
})

describe("a canvas reports its own failure, once", () => {
  const failed = (stage) => ({v: 1, verb: "failed", frame: CANVAS, args: {stage}})
  const uncaught = (message = "TypeError: x is undefined") => ({message})
  const rejected = () => ({reason: new Error("no")})

  test("an uncaught error before ready() is a failure to load", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    open()
    await eventually(() => api.frame === CANVAS)

    onPageError(uncaught())
    onPageError(uncaught())
    await eventually(() => heard.length === 1)
    await tick()
    assert.deepEqual(heard, [failed("load")])
  })

  test("an unhandled rejection before ready() is a failure to load", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    open()
    await eventually(() => api.frame === CANVAS)

    onPageError(rejected())
    await eventually(() => heard.length === 1)
    assert.deepEqual(heard, [failed("load")])
  })

  test("one while the page loads, before its handshake, is reported once the canvas is open, and its ready() never", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    onPageError(uncaught())
    api.ready()
    api.open("t:local.weather-lookup")

    open()
    await eventually(() => heard.length === 2)
    await tick()
    assert.deepEqual(heard, [failed("load"), {v: 1, verb: "open", frame: CANVAS, args: {ref: "t:local.weather-lookup"}}])
  })

  test("an uncaught error after ready() is a failure at runtime", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    open()
    api.ready()
    await eventually(() => heard.length === 1)

    onPageError(uncaught())
    onPageError(rejected())
    await eventually(() => heard.length === 2)
    await tick()
    assert.deepEqual(heard, [{v: 1, verb: "ready", frame: CANVAS, args: {}}, failed("runtime")])
  })

  test("an unhandled rejection after ready() is a failure at runtime", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    open()
    api.ready()
    onPageError(rejected())
    await eventually(() => heard.length === 2)
    assert.deepEqual(heard.at(-1), failed("runtime"))
  })

  test("ready() then an error, both before the handshake, arrive in that order", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    api.ready()
    onPageError(uncaught())
    open()
    await eventually(() => heard.length === 2)
    assert.deepEqual(heard, [{v: 1, verb: "ready", frame: CANVAS, args: {}}, failed("runtime")])
  })

  test("the browser's ResizeObserver loop reports are no failure; any other error after them still is", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    open()
    api.ready()
    await eventually(() => heard.length === 1)

    onPageError(uncaught("ResizeObserver loop completed with undelivered notifications."))
    onPageError(uncaught("ResizeObserver loop limit exceeded"))
    await tick()
    assert.equal(heard.length, 1)

    // Only those two: a message that merely names ResizeObserver is a failure.
    onPageError(uncaught("ResizeObserver is not defined"))
    await eventually(() => heard.length === 2)
    assert.deepEqual(heard.at(-1), failed("runtime"))
  })

  test("before ready() too, a ResizeObserver loop report is no failure, and the canvas still becomes ready", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    open()
    onPageError(uncaught("ResizeObserver loop completed with undelivered notifications."))
    api.ready()
    await eventually(() => heard.length === 1)
    await tick()
    assert.deepEqual(heard, [{v: 1, verb: "ready", frame: CANVAS, args: {}}])
  })
})
