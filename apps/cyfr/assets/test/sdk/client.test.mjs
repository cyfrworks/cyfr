// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, describe, test} from "node:test"

import {CyfrError, createClient} from "../../js/sdk/client.js"
import {CANVAS_VERBS, CREDENTIAL, HANDSHAKE, SOCKET_PATH, credentialClosed, toFrameMessage} from "../../js/sdk/wire.js"
import {credentialOf, eventually, fixture, frameWindow, nextMessage, stubServer, stubSockets} from "./support.mjs"

const GRANT = fixture.shell.find((vector) => vector.verb === "grant").message.args.ref

const FRAME = "frm_01a09fee2e4f"
const CREDENTIAL_VALUE = credentialOf(fixture.requests[0].headers.authorization)

const cleanups = []
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup()
})

// A frame's SDK against a stub endpoint answering each route from the
// fixture, and its stream connection answering each subscription with
// `streams` (`stubSockets`). `handshake()` plays the shell: it posts the
// handshake from the parent window and the credential over the port, and
// answers the shell's end of the port.
async function frameClient({
  answer,
  streams = fixtureStreams,
  opens,
  socketFn,
  framed = true,
  pathname,
  handshakeTimeoutMs,
  fetchFn = fetch
} = {}) {
  const server = await stubServer(answer || fixtureAnswer)
  cleanups.push(server.close)
  const endpoint = stubSockets({answer: streams, opens})
  const win = frameWindow({framed, pathname})
  const {api, onWindowMessage, onPageError} = createClient({
    win,
    fetchFn,
    socketFn: socketFn || endpoint.socketFn,
    base: server.base,
    handshakeTimeoutMs
  })

  const handshake = ({source = win.parent, frame = FRAME, credential = CREDENTIAL_VALUE} = {}) => {
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    onWindowMessage({source, data: {v: 1, type: HANDSHAKE, frame}, ports: [channel.port2]})
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame, credential})
    return channel.port1
  }

  return {api, onWindowMessage, onPageError, handshake, server, win, sockets: endpoint.sockets, sent: endpoint.sent}
}

const route = (url) => Object.entries(fixture.routes).find(([, path]) => path === url)?.[0]

// A private version's page, which names no public tincture.
const PRIVATE_PATH = "/_s/SFMyNTY.c2lnbmVkLWFzc2V0/local/weather/1.0.0/index.html"

function fixtureAnswer(request) {
  return {body: fixture.answers.find((vector) => vector.kind === route(request.url)).body}
}

// The fixture's stream connection: what the frame sends, what the endpoint
// answers and what the page's handler hears of it.
const CONNECTION = fixture.connection
const SUBJECT = CONNECTION.from_frame[0].subject

// The events of the fixture's first subscription, as its handler hears
// them, but for its last, the refusal it ended with.
const EVENTS = CONNECTION.heard[0].events.filter(({event}) => event !== "refusal")

// The endpoint answering each subscription: it opens, carries EVENTS as its
// stream's, and the endpoint ends it.
function fixtureStreams({type, sub, stream, subject}) {
  if (type !== "subscribe") return []
  return [
    {v: 1, type: "subscribed", sub},
    ...EVENTS.map(({id, data}) => ({v: 1, type: "event", sub, stream, subject, id, data})),
    {v: 1, type: "ended", sub}
  ]
}

// EVENTS as the handler of a subscription to `stream` hears them.
const eventsOf = (stream) => EVENTS.map((event) => ({...event, event: stream}))

// The same, as a canvas hears them: each with its change's revision and
// time, null for a payload that carries neither.
const canvasEventsOf = (stream) => eventsOf(stream).map((event) => ({...event, revision: null, at: null}))

const subscribes = (sent) => sent().filter((message) => message.type === "subscribe")

describe("data goes to the endpoint under the handshake's credential", () => {
  test("invoke and action post the fixture's bodies with the bearer", async () => {
    const {api, handshake, server} = await frameClient()
    handshake()

    const [invoke, action] = fixture.requests.map((vector) => vector.body)

    assert.deepEqual(await api.invoke(invoke.ref, invoke.operation, invoke.args), {temperature: 21})
    assert.deepEqual(await api.action(action.operation, action.args), {executions: []})

    assert.equal(server.requests.length, 2)

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
    const {api, handshake, server, sockets} = await frameClient()
    handshake()

    await assert.rejects(api.invoke("", "run"), {code: "invalid_argument"})
    await assert.rejects(api.invoke("c:local.weather", "run", [1]), {code: "invalid_argument"})
    await assert.rejects(api.stream("executions.deltas", 7, () => {}), {code: "invalid_argument"})
    await assert.rejects(api.stream("executions.deltas", null), {code: "invalid_argument"})
    assert.equal(server.requests.length, 0)
    assert.equal(sockets.length, 0)
  })
})

describe("only the shell that created the frame hands it a port and a credential", () => {
  test("a top-level private page has no credential", async () => {
    const {api, server, sockets} = await frameClient({framed: false, pathname: PRIVATE_PATH})
    assert.equal(api.public, null)
    await assert.rejects(api.invoke("c:local.weather:1.0.0", "run"), {code: "no_frame"})
    await assert.rejects(api.stream("executions.deltas", null, () => {}), {code: "no_frame"})
    assert.equal(server.requests.length, 0)
    assert.equal(sockets.length, 0)
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

  test("a request or a subscription already sent keeps the credential it was sent with; the next takes the newest", async () => {
    const posted = []
    const fetchFn = (url, options) => {
      posted.push(credentialOf(options.headers.authorization))
      return fetch(url, options)
    }
    const {api, handshake, server, sent} = await frameClient({fetchFn})
    const shell = handshake()
    const [invoke] = fixture.requests.map((vector) => vector.body)

    const events = []
    const opened = api.stream("executions.deltas", SUBJECT, (event) => events.push(event))
    const inFlight = api.invoke(invoke.ref, invoke.operation, invoke.args)
    await eventually(() => posted.length === 1 && subscribes(sent).length === 1)

    shell.postMessage(renewal())
    await settled(api, shell)

    assert.deepEqual(await inFlight, {temperature: 21})
    await (await opened).closed
    assert.deepEqual(events, eventsOf("executions.deltas"))

    await api.invoke(invoke.ref, invoke.operation, invoke.args)
    await (await api.stream("runs.changes", null, () => {})).closed
    assert.deepEqual(posted, [CREDENTIAL_VALUE, RENEWED])
    assert.deepEqual(authorizations(server), [CREDENTIAL_VALUE, RENEWED])
    assert.deepEqual(
      subscribes(sent).map((message) => message.credential),
      [CREDENTIAL_VALUE, RENEWED]
    )
  })

  test("a subscription waiting for its connection to open is sent under the credential the shell handed last", async () => {
    const {api, handshake, sockets} = await frameClient({opens: false})
    const shell = handshake()
    const opened = api.stream("runs.changes", null, () => {})
    await eventually(() => sockets.length === 1)

    shell.postMessage(renewal())
    await settled(api, shell)
    sockets[0].open()
    await (await opened).closed
    assert.deepEqual(
      sockets[0].sent.map((message) => message.credential),
      [RENEWED]
    )
  })
})

describe("shell verbs go over the port", () => {
  // A canvas's own verbs, `press`, `failed` and `grant`, are its page's alone (below).
  test("each verb is the wire's message for this frame", async () => {
    const {api, handshake} = await frameClient()
    const shell = handshake()
    await eventually(() => api.frame === FRAME)

    for (const {verb, message} of fixture.shell.filter(({verb}) => !CANVAS_VERBS.includes(verb))) {
      const received = nextMessage(shell)
      if (verb === "open") api.open(message.args.ref, message.args.subject ?? null)
      else if (verb === "title") api.title(message.args.title)
      else if (verb === "credential") api.credential(message.args.name)
      else api[verb]()
      assert.deepEqual(await received, message, verb)
    }
  })

  test("a page that is no canvas sends no press, no failure and no grant", async () => {
    const {api, handshake, onPageError} = await frameClient()
    const shell = handshake()
    const received = []
    shell.onmessage = (event) => received.push(event.data)
    const press = fixture.shell.find((vector) => vector.verb === "press").message.args

    onPageError({message: "the page's own bug"})
    api.press(press.binding, press.action)
    api.grant(GRANT)
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

describe("a stream is delivered over the frame's stream connection", () => {
  async function opened(options) {
    const client = await frameClient(options)
    client.handshake()
    return client
  }

  test("each event reaches onEvent, and the stream ends with the endpoint's", async () => {
    const {api, sockets} = await opened()
    const events = []
    const handle = await api.stream("executions.deltas", SUBJECT, (event) => events.push(event))

    await handle.closed
    assert.deepEqual(events, eventsOf("executions.deltas"))
    assert.equal(sockets.length, 1)
  })

  test("what the frame sends is the fixture's: a subscribe per stream, numbered from 1, and an unsubscribe", async () => {
    const [first, second] = CONNECTION.from_frame
    const {api, sockets, sent} = await opened({streams: () => []})

    api.stream(first.stream, first.subject, () => {})
    const later = api.stream(second.stream, second.subject, () => {})
    await eventually(() => sent().length === 2)
    sockets[0].say({v: 1, type: "subscribed", sub: second.sub})
    ;(await later).close()

    assert.deepEqual(sent(), CONNECTION.from_frame)
    assert.equal(sockets.length, 1)
  })

  test("the endpoint's answers, in the fixture's order, are heard as the fixture's events", async () => {
    const {api, sockets, sent} = await opened({streams: () => []})
    const reads = CONNECTION.heard.map(({sub}) => {
      const {stream, subject} = CONNECTION.from_frame.find((message) => message.sub === sub)
      const read = {sub, events: [], ended: false}
      read.opened = api.stream(stream, subject, (event) => read.events.push(event))
      return read
    })
    await eventually(() => sent().length === reads.length)
    assert.deepEqual(
      sent().map((message) => message.sub),
      reads.map(({sub}) => sub)
    )

    for (const message of CONNECTION.to_frame) sockets[0].say(message)
    for (const read of reads) {
      await (await read.opened).closed
      read.ended = true
    }

    assert.deepEqual(
      reads.map(({sub, events, ended}) => ({sub, events, ended})),
      CONNECTION.heard
    )
    assert.equal(sockets.length, 1)
  })

  test("a handler that throws does not end the stream", async () => {
    const {api} = await opened()
    const seen = []
    const handle = await api.stream("executions.deltas", null, (event) => {
      seen.push(event.id)
      throw new Error("the page's own bug")
    })

    await handle.closed
    assert.deepEqual(seen, [1, 2])
  })

  test("closed before its subscribe is sent, it sends nothing and rejects cancelled", async () => {
    const cancelled = {code: "cancelled", message: "The stream was closed before it opened."}

    // Before the shell handed the frame its credential.
    const early = await frameClient()
    const waiting = early.api.stream("runs.changes", null, () => {})
    waiting.close()
    await assert.rejects(waiting, cancelled)
    early.handshake()
    await tick()
    assert.equal(early.sockets.length, 0)

    // While the connection opens.
    const {api, sockets} = await opened({opens: false})
    const opening = api.stream("runs.changes", null, () => {})
    await eventually(() => sockets.length === 1)
    opening.close()
    await assert.rejects(opening, cancelled)
    sockets[0].open()
    await tick()
    assert.deepEqual(sockets[0].sent, [])
  })

  test("closed while it waits for its answer, it sends unsubscribe and rejects cancelled; the answer moves nothing", async () => {
    const {api, sockets, sent} = await opened({streams: () => []})
    const events = []
    const pending = api.stream("runs.changes", null, (event) => events.push(event))
    await eventually(() => sent().length === 1)

    pending.close()
    await assert.rejects(pending, {code: "cancelled"})
    pending.close()
    sockets[0].say({v: 1, type: "subscribed", sub: 1})
    sockets[0].say({v: 1, type: "event", sub: 1, stream: "runs.changes", subject: null, id: null, data: {kind: "failed"}})
    await tick()

    assert.deepEqual(sent(), [
      {...CONNECTION.from_frame[1], sub: 1},
      {...CONNECTION.from_frame[2], sub: 1}
    ])
    assert.deepEqual(events, [])
  })

  test("closed when open, it sends unsubscribe, its closed resolves and nothing more is delivered; the promise's close is the handle's", async () => {
    const {api, sockets, sent} = await opened({streams: ({type, sub}) => (type === "subscribe" ? [{v: 1, type: "subscribed", sub}] : [])})
    const events = []
    const pending = api.stream("runs.changes", null, (event) => events.push(event))
    const handle = await pending
    const event = (id) => ({v: 1, type: "event", sub: 1, stream: "runs.changes", subject: null, id, data: {kind: "failed"}})

    sockets[0].say(event(1))
    handle.close()
    await handle.closed
    sockets[0].say(event(2))
    pending.close()
    handle.close()
    await tick()

    assert.deepEqual(events, [{id: 1, event: "runs.changes", data: {kind: "failed"}}])
    assert.deepEqual(
      sent().map(({type, sub}) => [type, sub]),
      [
        ["subscribe", 1],
        ["unsubscribe", 1]
      ]
    )
  })

  test("a closed connection ends every subscription it carried, and the next stream opens a new one", async () => {
    const {api, sockets, sent} = await opened({
      streams: ({type, sub, stream}) => (type === "subscribe" && stream === "runs.changes" ? [{v: 1, type: "subscribed", sub}] : [])
    })
    const open = await api.stream("runs.changes", null, () => {})
    const pending = api.stream("executions.deltas", SUBJECT, () => {})
    await eventually(() => sent().length === 2)

    sockets[0].drop()
    const unreachable = {code: "unavailable", message: "The endpoint could not be reached."}
    await assert.rejects(open.closed, unreachable)
    await assert.rejects(pending, unreachable)

    const again = await api.stream("runs.changes", null, () => {})
    assert.equal(sockets.length, 2)
    assert.deepEqual(
      sockets.map((socket) => socket.sent.map(({sub}) => sub)),
      [[1, 2], [3]]
    )
    again.close()
  })

  test("a refusal rejects the open with its class, and delivers nothing", async () => {
    const {error} = fixture.refusal.body
    const {api} = await opened({streams: ({sub}) => [{v: 1, type: "ended", sub, error}]})
    const events = []

    await assert.rejects(api.stream("executions.deltas", null, (event) => events.push(event)), {
      code: "forbidden",
      message: error.message,
      stage: "admission"
    })
    assert.deepEqual(events, [])
  })

  // tests/fixtures/tincture_wire.json's stream_rejections: each answer a
  // subscription can get that opens no stream, and how the SDK rejects it.
  // No answer is the connection that never opened, that the SDK could not
  // open, or that closed after the subscribe went.
  test("a subscription that got no answer rejects unavailable with no stage; any other, as its refusal", async () => {
    const {cases} = fixture.stream_rejections
    assert.ok(cases.some(({answer}) => answer === null))
    assert.ok(cases.some(({answer}) => answer?.error && fixture.stream_rejections.no_answer_classes.includes(answer.error.class)))
    assert.ok(cases.some(({rejects}) => rejects.stage === "admission"))

    const unanswered = {
      "the connection never opens": async () => {
        const client = await opened({opens: false})
        const pending = client.api.stream("executions.deltas", null, () => {})
        await eventually(() => client.sockets.length === 1)
        client.sockets[0].drop()
        return pending
      },
      "the connection cannot be made": async () => {
        const client = await opened({
          socketFn: () => {
            throw new SyntaxError("The URL's scheme must be either 'ws' or 'wss'.")
          }
        })
        return client.api.stream("executions.deltas", null, () => {})
      },
      "the connection closes after the subscribe": async () => {
        const drop = (_message, socket) => {
          setTimeout(() => socket.drop(), 0)
          return []
        }
        return (await opened({streams: drop})).api.stream("executions.deltas", null, () => {})
      }
    }

    for (const {answer, rejects} of cases) {
      // The fixture's answer names the first subscription a frame makes.
      const answered = async () => (await opened({streams: () => [answer]})).api.stream("executions.deltas", null, () => {})
      const ways = answer === null ? Object.entries(unanswered) : [[JSON.stringify(answer), answered]]
      for (const [way, open] of ways) {
        await assert.rejects(open(), (error) => {
          assert.ok(error instanceof CyfrError, way)
          const read = {class: error.code, message: error.message}
          if ("stage" in error) read.stage = error.stage
          assert.deepEqual(read, rejects, way)
          return true
        })
      }
    }
  })

  test("a message that does not read, names no live subscription, or comes before it opened, moves nothing", async () => {
    const {api} = await opened({
      streams: ({type, sub, stream, subject}) =>
        type !== "subscribe"
          ? []
          : [
              "not json",
              {v: 1, type: "ended", sub, error: {class: "forbidden", message: "no"}},
              {v: 1, type: "subscribed", sub: sub + 1},
              {v: 1, type: "subscribed", sub, origin: "elsewhere"},
              {v: 2, type: "subscribed", sub},
              {v: 1, type: "event", sub, stream, subject, id: 0, data: {early: true}},
              {v: 1, type: "subscribed", sub},
              {v: 1, type: "event", sub, stream, subject, id: "1", data: {}},
              {v: 1, type: "ended", sub: sub + 1},
              ...fixtureStreams({type, sub, stream, subject}).slice(1)
            ]
    })
    const events = []
    await (await api.stream("executions.deltas", SUBJECT, (event) => events.push(event))).closed
    assert.deepEqual(events, eventsOf("executions.deltas"))
  })

  test("the connection is the app's, at the base's host, ws for http and wss for https, the credential never in it", async () => {
    const {api, sockets, server} = await opened()
    await (await api.stream("runs.changes", null, () => {})).closed
    assert.equal(sockets[0].url, new URL(CONNECTION.paths.app, server.base.replace(/^http:/, "ws:")).href)
    assert.equal(new URL(sockets[0].url).pathname, SOCKET_PATH)

    const endpoint = stubSockets({answer: fixtureStreams})
    const win = frameWindow()
    const {api: secure, onWindowMessage} = createClient({win, fetchFn: fetch, socketFn: endpoint.socketFn, base: "https://cyfr.test/_s/x/index.html"})
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [channel.port2]})
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame: FRAME, credential: CREDENTIAL_VALUE})
    await (await secure.stream("runs.changes", null, () => {})).closed
    assert.equal(endpoint.sockets[0].url, "wss://cyfr.test/_f/v1/socket")

    for (const socket of [...sockets, ...endpoint.sockets]) assert.ok(!socket.url.includes(CREDENTIAL_VALUE))
  })
})

describe("a public tincture's top-level page names itself", () => {
  test("its requests carry public and no bearer, and it opens no stream", async () => {
    const {api, server, sockets} = await frameClient({framed: false})
    const identity = {athanor: "@home", publisher: "local", name: "weather"}
    assert.deepEqual(api.public, identity)

    const [invoke] = fixture.requests.map((vector) => vector.body)
    assert.deepEqual(await api.invoke(invoke.ref, invoke.operation, invoke.args), {temperature: 21})
    await assert.rejects(api.stream("executions.deltas", null, () => {}), {code: "no_frame"})

    assert.equal(server.requests.length, 1)
    assert.equal(server.requests[0].headers.authorization, undefined)
    assert.deepEqual(server.requests[0].body, {...invoke, public: identity})
    assert.equal(sockets.length, 0)
  })

  test("an encoded path reads as its decoded one", async () => {
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
// shell's handshake reply carries them, and its stream connection's path.
const [{frame: CANVAS, reply: OPEN}] = fixture.canvas.handshake.valid
const [{socket_path: SOCKET}] = fixture.canvas.paths.valid.filter(({frame}) => frame === CANVAS)
const DECLARED = OPEN.canvas.streams[0]
const PRESS = fixture.shell.find((vector) => vector.verb === "press").message.args

// What the bridge tells a shown canvas after its credential: its state.
const SHOWN = [["state", {state: "live"}]]

// A canvas page's SDK. `open()` plays the bridge for a canvas: the
// handshake from the parent window, then over the port the canvas message,
// the credential and anything in `told`; `heard` is every message the page
// posts the shell.
async function canvasClient({block = OPEN.canvas, streams} = {}) {
  const client = await frameClient({streams})
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

// The path of each connection a canvas's SDK opened.
const paths = (sockets) => sockets.map((socket) => new URL(socket.url).pathname)

describe("a canvas's streams go over its open's own connection", () => {
  test("a declared stream subscribes on the data path's connection, under the canvas's credential", async () => {
    const {api, open, server, sockets} = await canvasClient()
    open(SHOWN)

    const events = []
    const handle = await api.stream(DECLARED.name, DECLARED.subject, (event) => events.push(event))
    await handle.closed

    assert.deepEqual(events, canvasEventsOf(DECLARED.name))
    assert.equal(sockets.length, 1)
    assert.equal(sockets[0].url, new URL(SOCKET, server.base.replace(/^http:/, "ws:")).href)
    assert.deepEqual(sockets[0].sent, [
      {v: 1, type: "subscribe", sub: 1, credential: OPEN.credential, stream: DECLARED.name, subject: DECLARED.subject}
    ])
    assert.equal(server.requests.length, 0)
  })

  test("a stream asked for before the handshake goes there once the canvas is open", async () => {
    const {api, open, sockets} = await canvasClient()
    const opened = api.stream(DECLARED.name, DECLARED.subject, () => {})
    await tick()
    assert.equal(sockets.length, 0)

    open(SHOWN)
    await (await opened).closed
    assert.deepEqual(paths(sockets), [SOCKET])
  })

  test("a pair the canvas does not declare is refused before anything is sent", async () => {
    const {api, open, sockets} = await canvasClient()
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
    assert.equal(sockets.length, 0)
  })

  test("a canvas that declares nothing opens no stream", async () => {
    const {api, open, sockets} = await canvasClient({block: {...OPEN.canvas, streams: []}})
    open()
    await assert.rejects(api.stream(DECLARED.name, DECLARED.subject, () => {}), {code: "forbidden"})
    assert.equal(sockets.length, 0)
  })

  test("a second canvas message, or one for another frame, changes nothing", async () => {
    const {api, open, sockets} = await canvasClient()
    const shell = open(SHOWN)
    shell.postMessage(toFrameMessage("canvas", CANVAS, {...OPEN.canvas, streams: [{name: "executions.deltas", subject: null}]}))
    shell.postMessage(
      toFrameMessage("canvas", "frm_00aa11bb22", {
        ...OPEN.canvas,
        mode: "live",
        data_path: "/_f/v1/o/frm_00aa11bb22/",
        streams: [{name: "executions.deltas", subject: null}]
      })
    )
    await tick()

    await assert.rejects(api.stream("executions.deltas", null, () => {}), {code: "forbidden"})
    await (await api.stream(DECLARED.name, DECLARED.subject, () => {})).closed
    assert.deepEqual(paths(sockets), [SOCKET])
    assert.deepEqual(
      sockets[0].sent.map(({stream}) => stream),
      [DECLARED.name]
    )
  })
})

// A canvas the layout holds hidden, a second canvas or one behind a full
// frame, is opened frozen: the bridge hands it its open, its credential and
// then `state` `frozen`, and its credential is suspended, so the endpoint
// answers its subscription as tests/fixtures/tincture_wire.json's
// suspended-frame stream rejection (`ended` with `forbidden`,
// `admission`, and `reason` `frame_suspended`), a refusal a page opening
// again meets again.
// The delivery contract's vectors: one canvas connection, each
// subscription answered with its messages of `delivery.to_frame`.
const DELIVERY = fixture.delivery
const PICTURED = {name: "schedules.changes", subject: null}
const deliveryOf = (sub) => DELIVERY.to_frame.filter((message) => message.sub === sub)

describe("a canvas's stream keeps the delivery contract", () => {
  test("it hears each vector's picture, changes, resync and states, and reads its state", async () => {
    const block = {...OPEN.canvas, streams: [PICTURED]}
    const {api, open, sent} = await canvasClient({
      block,
      streams: (message) => (message.type === "subscribe" ? deliveryOf(message.sub) : [])
    })
    open(SHOWN)

    const heard = new Map(DELIVERY.heard.map(({sub}) => [sub, []]))
    const handles = []
    for (const {sub} of DELIVERY.heard) {
      handles.push(await api.stream(PICTURED.name, PICTURED.subject, (event) => heard.get(sub).push(event)))
    }
    await eventually(() =>
      DELIVERY.heard.every(({sub, events, state}, index) => heard.get(sub).length === events.length && handles[index].state === state)
    )

    for (const [index, vector] of DELIVERY.heard.entries()) {
      const events = heard.get(vector.sub).map((event) => {
        if (event.event !== "unavailable") return event
        // When it opens again is the SDK's own: a time within its first wait.
        const wait = Date.parse(event.data.retry_at) - Date.now()
        assert.ok(wait > 0 && wait <= 1000, `retry_at ${event.data.retry_at} is within a second`)
        return {...event, data: {retry_at: "retry_at"}}
      })
      assert.deepEqual(events, vector.events, `subscription ${vector.sub}`)
      assert.equal(handles[index].state, vector.state, `subscription ${vector.sub}'s state`)
    }

    // Denied, the stream ended and is not asked for again; with no answer,
    // or suspended while the canvas is shown, it is, under a new number,
    // once its wait is over.
    await handles[1].closed
    const reopens = DELIVERY.heard.filter((vector) => vector.reopens).length
    const reopened = () =>
      sent().filter((message) => message.type === "subscribe" && message.sub > DELIVERY.heard.length)
    await eventually(() => reopened().length === reopens, {tries: 40, stepMs: 50})
    await tick()
    assert.equal(reopened().length, reopens)
    assert.ok(reopened().every((message) => message.stream === PICTURED.name))
    for (const handle of handles) handle.close()
    assert.deepEqual(
      handles.map((handle) => handle.state),
      ["ended", "denied", "ended", "ended"]
    )
  })

  test("a lost connection opens each stream again, its fresh picture announced as a resync", async () => {
    const block = {...OPEN.canvas, streams: [PICTURED]}
    const picture = deliveryOf(1).slice(0, 3)
    const {api, open, sockets} = await canvasClient({
      block,
      streams: (message) =>
        message.type === "subscribe" ? picture.map((reply) => ({...reply, sub: message.sub})) : []
    })
    open(SHOWN)

    const events = []
    const handle = await api.stream(PICTURED.name, PICTURED.subject, (event) => events.push(event.event))
    await eventually(() => events.length === 2)
    sockets[0].drop()

    assert.equal(handle.state, "unavailable")
    await eventually(() => events.length >= 6, {tries: 40, stepMs: 50})
    assert.deepEqual(events, [
      "schedules.changes",
      "snapshot",
      "unavailable",
      "resync",
      "schedules.changes",
      "snapshot"
    ])
    assert.equal(handle.state, "live")
    assert.equal(sockets.length, 2)
    handle.close()
  })

  test("a connection the endpoint closed for a newer one of the same frame opens nothing again", async () => {
    const block = {...OPEN.canvas, streams: [PICTURED]}
    const {api, open, sockets} = await canvasClient({
      block,
      streams: (message) => (message.type === "subscribe" ? deliveryOf(1).slice(0, 3) : [])
    })
    open(SHOWN)

    const handle = await api.stream(PICTURED.name, PICTURED.subject, () => {})
    sockets[0].drop(fixture.connection.close_codes.replaced)
    await assert.rejects(handle.closed, {code: "unavailable"})
    assert.equal(handle.state, "ended")
    await tick()
    assert.equal(sockets.length, 1)
  })

  test("a stream opening again on a connection closed for a newer one ends too, its closed settled", async () => {
    const block = {...OPEN.canvas, streams: [PICTURED]}
    // The first connection answers the picture; the second never answers.
    const {api, open, sockets} = await canvasClient({
      block,
      streams: (message, socket) =>
        message.type === "subscribe" && socket === sockets[0] ? deliveryOf(1).slice(0, 3) : []
    })
    open(SHOWN)

    const handle = await api.stream(PICTURED.name, PICTURED.subject, () => {})
    sockets[0].drop()
    await eventually(() => sockets.length === 2 && sockets[1].sent.length === 1, {tries: 40, stepMs: 50})
    sockets[1].drop(fixture.connection.close_codes.replaced)

    // Bounded: a closed that never settles fails here rather than hanging.
    const never = new Promise((_resolve, reject) => setTimeout(() => reject(new Error("closed never settled")), 2000))
    await assert.rejects(Promise.race([handle.closed, never]), {code: "unavailable"})
    assert.equal(handle.state, "ended")
  })
})

describe("a hidden canvas's stream opens once it is shown", () => {
  const SUSPENDED = fixture.stream_rejections.cases.find(({rejects}) => /suspended/.test(rejects.message)).answer

  // A canvas opened frozen, whose endpoint refuses its subscriptions while
  // its credential is suspended. As the shell does, `show(shell)` resumes
  // the credential and then tells the canvas `live`, and `hide(shell)`
  // suspends it and then tells it `frozen`; `states` is every state the
  // page heard.
  async function hiddenCanvas() {
    let suspended = true
    const streams = (message) => (suspended ? [{...SUSPENDED, sub: message.sub}] : fixtureStreams(message))
    const client = await canvasClient({streams})
    const states = []
    client.api.on("state", (state) => states.push(state))
    const tell = (shell, state) => {
      suspended = state === "frozen"
      shell.postMessage(toFrameMessage("state", CANVAS, {state}))
    }
    return {...client, states, show: (shell) => tell(shell, "live"), hide: (shell) => tell(shell, "frozen")}
  }

  // How an open has settled so far: `pending`, `opened`, or its rejection.
  const outcome = (promise) => {
    const read = {outcome: "pending"}
    promise.then(
      () => (read.outcome = "opened"),
      (error) => (read.outcome = `rejected ${error.code}: ${error.message}`)
    )
    return read
  }

  test("asked for before it is shown it sends nothing, and opens once, as any open, when it is shown", async () => {
    const RENEWED = "frm.v2.cmVuZXdlZC1oaWRkZW4tY2FudmFz"
    const {api, open, sockets, sent, states, show, hide} = await hiddenCanvas()
    const events = {early: [], late: []}

    // As a page asks at its load, before the handshake, and again once it
    // has heard it is frozen.
    const early = api.stream(DECLARED.name, DECLARED.subject, (event) => events.early.push(event))
    const reads = [outcome(early)]
    const shell = open([["state", {state: "frozen"}]])
    await eventually(() => states.length === 1)
    const late = api.stream(DECLARED.name, DECLARED.subject, (event) => events.late.push(event))
    reads.push(outcome(late))

    // A pair it does not declare is still refused at once.
    await assert.rejects(api.stream("executions.deltas", null, () => {}), {code: "forbidden", stage: "admission"})

    shell.postMessage({v: 1, type: CREDENTIAL, frame: CANVAS, credential: RENEWED})
    await tick()
    assert.deepEqual(states, ["frozen"])
    assert.deepEqual(
      reads.map((read) => read.outcome),
      ["pending", "pending"]
    )
    assert.equal(sockets.length, 0)

    show(shell)
    const handles = await Promise.all([early, late])
    await Promise.all(handles.map((handle) => handle.closed))

    assert.deepEqual(events, {early: canvasEventsOf(DECLARED.name), late: canvasEventsOf(DECLARED.name)})
    assert.deepEqual(paths(sockets), [SOCKET])
    assert.deepEqual(sent(), [
      {v: 1, type: "subscribe", sub: 1, credential: RENEWED, stream: DECLARED.name, subject: DECLARED.subject},
      {v: 1, type: "subscribe", sub: 2, credential: RENEWED, stream: DECLARED.name, subject: DECLARED.subject}
    ])

    // Hidden and shown again, nothing it asked for before opens again.
    hide(shell)
    show(shell)
    await eventually(() => states.length === 4)
    await tick()
    assert.deepEqual(states, ["frozen", "live", "frozen", "live"])
    assert.equal(sent().length, 2)
  })

  test("asked for while hidden again after it was shown, it waits for the next showing", async () => {
    const {api, open, sent, states, show, hide} = await hiddenCanvas()
    const shell = open([["state", {state: "frozen"}]])
    show(shell)
    await eventually(() => states.length === 2)
    await (await api.stream(DECLARED.name, DECLARED.subject, () => {})).closed
    assert.equal(sent().length, 1)

    hide(shell)
    await eventually(() => states.length === 3)
    const again = api.stream(DECLARED.name, DECLARED.subject, () => {})
    const read = outcome(again)
    await tick()
    assert.equal(read.outcome, "pending")
    assert.equal(sent().length, 1)

    show(shell)
    await (await again).closed
    assert.equal(sent().length, 2)
  })

  test("closed before it is ever shown, it has sent nothing", async () => {
    const {api, open, sockets, states} = await hiddenCanvas()
    const opened = outcome(api.stream(DECLARED.name, DECLARED.subject, () => {}))
    const shell = open([["state", {state: "frozen"}]])
    await eventually(() => states.length === 1)

    shell.close()
    await tick()
    assert.equal(opened.outcome, "pending")
    assert.equal(sockets.length, 0)
  })

  test("closed by the page while it waits to be shown, it rejects cancelled and sends nothing once shown", async () => {
    const {api, open, sockets, states, show} = await hiddenCanvas()
    const shell = open([["state", {state: "frozen"}]])
    await eventually(() => states.length === 1)
    const waiting = api.stream(DECLARED.name, DECLARED.subject, () => {})

    waiting.close()
    await assert.rejects(waiting, {code: "cancelled"})
    show(shell)
    await eventually(() => states.length === 2)
    await tick()
    assert.equal(sockets.length, 0)
  })
})

// A shown canvas's open streams when the layout hides it: the shell
// suspends its credential, so the endpoint ends each with the delivery
// vectors' suspended end, and then tells it `frozen`; the end may come
// before `frozen` or after it. Shown again, the shell resumes the
// credential and tells it `live`.
describe("a canvas hidden with its streams open has them again once it is shown", () => {
  const SUSPENDED_END = deliveryOf(4).find(({type}) => type === "ended")
  const SUSPENDED_OPEN = fixture.stream_rejections.cases.find(({why}) => why === "the frame is suspended").answer
  const REVOKED = fixture.stream_rejections.cases.find(({answer}) => answer && answer.error.class === "consent_required").answer
  const picture = (sub) => deliveryOf(1).slice(0, 3).map((reply) => ({...reply, sub}))

  // `answer` is how the endpoint answers a subscribe while the canvas is
  // shown; hidden, it answers each as a suspended frame's.
  async function shownCanvas() {
    const endpoint = {suspended: false, answer: picture}
    const client = await canvasClient({
      block: {...OPEN.canvas, streams: [PICTURED]},
      streams: (message) =>
        message.type !== "subscribe"
          ? []
          : endpoint.suspended
            ? [{...SUSPENDED_OPEN, sub: message.sub}]
            : endpoint.answer(message.sub)
    })
    const shell = client.open(SHOWN)
    const states = []
    client.api.on("state", (state) => states.push(state))
    const tell = (state) => shell.postMessage(toFrameMessage("state", CANVAS, {state}))
    const hide = async (order) => {
      endpoint.suspended = true
      const open = subscribes(client.sent).at(-1).sub
      if (order === "frozen first") tell("frozen")
      await tick()
      client.sockets.at(-1).say({...SUSPENDED_END, sub: open})
      if (order === "end first") tell("frozen")
      await eventually(() => states.at(-1) === "frozen")
    }
    const show = () => {
      endpoint.suspended = false
      tell("live")
    }
    return {...client, endpoint, hide, show, tell, states}
  }

  for (const order of ["end first", "frozen first"]) {
    test(`hidden (${order}) it is suspended and hears nothing; shown again it opens again and hears a resync`, async () => {
      const {api, sent, sockets, hide, show} = await shownCanvas()
      const events = []
      const handle = await api.stream(PICTURED.name, PICTURED.subject, (event) => events.push(event.event))
      await eventually(() => events.length === 2)
      let closed = "pending"
      handle.closed.then(() => (closed = "resolved"), () => (closed = "rejected"))

      await hide(order)
      assert.equal(handle.state, "suspended")

      // Hidden past the SDK's first wait: nothing heard, nothing sent, not ended.
      await new Promise((resolve) => setTimeout(resolve, 1300))
      assert.equal(handle.state, "suspended")
      assert.deepEqual(events, ["schedules.changes", "snapshot"])
      assert.equal(subscribes(sent).length, 1)
      assert.equal(closed, "pending")

      show()
      await eventually(() => events.length === 5)
      assert.deepEqual(events, ["schedules.changes", "snapshot", "resync", "schedules.changes", "snapshot"])
      assert.equal(handle.state, "live")
      assert.deepEqual(
        subscribes(sent).map(({sub, stream}) => [sub, stream]),
        [
          [1, PICTURED.name],
          [2, PICTURED.name]
        ]
      )
      assert.equal(sockets.length, 1)
      assert.equal(closed, "pending")
      handle.close()
      assert.equal(handle.state, "ended")
    })
  }

  // `frozen` and the endpoint's end travel apart: from `frozen` on, a change
  // already on its way is not heard, and shown again with no end ever come,
  // the stream that missed it opens again and hears a fresh picture.
  test("a canvas hears no in-flight stream event after frozen, and shown again it hears a fresh picture", async () => {
    const {api, sent, sockets, tell, states} = await shownCanvas()
    const events = []
    const handle = await api.stream(PICTURED.name, PICTURED.subject, (event) => events.push(event.event))
    await eventually(() => events.length === 2)

    tell("frozen")
    await eventually(() => states.at(-1) === "frozen")
    const change = deliveryOf(1).find((reply) => reply.type === "event" && reply.data.status === "paused")
    sockets[0].say({...change, sub: 1})
    sockets[0].say({v: 1, type: "stale", sub: 1, at: change.data.at})
    await tick()
    assert.deepEqual(events, ["schedules.changes", "snapshot"])

    tell("live")
    await eventually(() => events.length === 5)
    assert.deepEqual(events, ["schedules.changes", "snapshot", "resync", "schedules.changes", "snapshot"])
    assert.equal(handle.state, "live")
    assert.deepEqual(
      sent().map(({type, sub}) => [type, sub]),
      [
        ["subscribe", 1],
        ["unsubscribe", 1],
        ["subscribe", 2]
      ]
    )
    assert.equal(sockets.length, 1)
    handle.close()
  })

  test("a denial while frozen is told once the canvas is shown", async () => {
    const {api, sockets, tell, states} = await shownCanvas()
    const events = []
    const handle = await api.stream(PICTURED.name, PICTURED.subject, (event) => events.push(event))
    await eventually(() => events.length === 2)

    tell("frozen")
    await eventually(() => states.at(-1) === "frozen")
    sockets[0].say({...REVOKED, sub: 1})
    await handle.closed
    assert.equal(handle.state, "denied")
    await tick()
    assert.equal(events.length, 2)

    tell("live")
    await eventually(() => events.length === 3)
    assert.deepEqual(events.at(-1), {id: null, event: "denied", data: REVOKED.error, revision: null, at: null})
  })

  test("a grant revoked while it was hidden is denied once it is shown", async () => {
    const {api, sent, endpoint, hide, show} = await shownCanvas()
    const events = []
    const handle = await api.stream(PICTURED.name, PICTURED.subject, (event) => events.push(event))
    await eventually(() => events.length === 2)

    await hide("end first")
    endpoint.answer = (sub) => [{...REVOKED, sub}]
    await new Promise((resolve) => setTimeout(resolve, 1100))
    assert.equal(handle.state, "suspended")

    show()
    await handle.closed
    assert.equal(handle.state, "denied")
    assert.deepEqual(events.at(-1), {id: null, event: "denied", data: REVOKED.error, revision: null, at: null})
    assert.equal(events.length, 3)
    await new Promise((resolve) => setTimeout(resolve, 1100))
    assert.equal(subscribes(sent).length, 2)
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

  test("grant is the wire's grant for this frame", async () => {
    const {api, open, heard} = await canvasClient()
    open()
    await eventually(() => api.frame === CANVAS)

    api.grant(GRANT)
    api.ready()

    await eventually(() => heard.length === 2)
    assert.deepEqual(heard, [
      {v: 1, verb: "grant", frame: CANVAS, args: {ref: GRANT}},
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

  test("an uncaught error or an unhandled rejection after ready() is no failure: nothing is reported", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    open()
    api.ready()
    await eventually(() => heard.length === 1)

    onPageError(uncaught())
    onPageError(rejected())
    await tick()
    assert.deepEqual(heard, [{v: 1, verb: "ready", frame: CANVAS, args: {}}])
  })

  test("ready() then an error, both before the handshake: only ready arrives", async () => {
    const {open, heard, onPageError, api} = await canvasClient()
    api.ready()
    onPageError(uncaught())
    open()
    await eventually(() => heard.length === 1)
    await tick()
    assert.deepEqual(heard, [{v: 1, verb: "ready", frame: CANVAS, args: {}}])
  })

  test("a canvas the shell holds frozen still posts its ready and its failure, which no showing replays", async () => {
    for (const report of ["ready", "failed"]) {
      const {open, heard, onPageError, api} = await canvasClient()
      const states = []
      api.on("state", (state) => states.push(state))
      const shell = open([["state", {state: "live"}]])

      shell.postMessage(toFrameMessage("state", CANVAS, {state: "frozen"}))
      await eventually(() => states.at(-1) === "frozen")

      if (report === "failed") onPageError(uncaught())
      else api.ready()
      const expected = report === "failed" ? failed("load") : {v: 1, verb: "ready", frame: CANVAS, args: {}}
      await eventually(() => heard.at(-1)?.verb === report)
      assert.deepEqual(heard.at(-1), expected)

      // Shown again, the page posts nothing more: the report it made while
      // hidden is the only one.
      const count = heard.length
      shell.postMessage(toFrameMessage("state", CANVAS, {state: "live"}))
      await eventually(() => states.at(-1) === "live")
      await tick()
      assert.equal(heard.length, count, report)
    }
  })

  test("the browser's ResizeObserver loop reports are no failure; any other error after them still is", async () => {
    const {open, heard, onPageError} = await canvasClient()
    open()

    onPageError(uncaught("ResizeObserver loop completed with undelivered notifications."))
    onPageError(uncaught("ResizeObserver loop limit exceeded"))
    await tick()
    assert.equal(heard.length, 0)

    // Only those two: a message that merely names ResizeObserver is a failure.
    onPageError(uncaught("ResizeObserver is not defined"))
    await eventually(() => heard.length === 1)
    assert.deepEqual(heard, [failed("load")])
  })

  test("an error whose message is not one of those two, whole, is a failure, though it contains one", async () => {
    for (const message of [
      "Uncaught Error: Saving failed after ResizeObserver loop limit exceeded",
      "Uncaught ResizeObserver loop limit exceeded",
      "ResizeObserver loop limit exceeded.",
      "ResizeObserver loop completed with undelivered notifications",
      "ResizeObserver loop completed with undelivered notifications. Saving failed"
    ]) {
      const {open, heard, onPageError} = await canvasClient()
      open()

      onPageError({type: "error", message, error: new Error("Saving failed")})
      await eventually(() => heard.length === 1)
      assert.deepEqual(heard, [failed("load")], message)
    }
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

// ---- a desktop's verbs and what its open tells it --------------------------------

describe("a desktop's verbs and data", () => {
  const answerOn = (port, verb, args) => port.postMessage(toFrameMessage(verb, CANVAS, args))
  const sent = (heard, verb) => heard.filter((message) => message.verb === verb)

  test("its preferences, appearance and person come with its open, read through desktop and its event", async () => {
    const {api, open} = await canvasClient()
    const seen = []
    api.on("desktop", (desktop) => seen.push(desktop))
    assert.equal(api.desktop, null)

    open(SHOWN)
    await eventually(() => seen.length === 1)

    const expected = {prefs: OPEN.canvas.prefs, appearance: OPEN.canvas.appearance, person: OPEN.canvas.person}
    assert.deepEqual({...api.desktop}, expected)
    assert.deepEqual({...seen[0]}, expected)
  })

  test("a press of a control posts the wire's message and settles with the shell's answer; a feed's press answers nothing", async () => {
    const client = await canvasClient()
    const port = client.open(SHOWN)
    const {api, heard} = client

    const accepted = api.press("pause-digest")
    const picked = api.press("vpn-connect", "lisbon-1")
    await eventually(() => sent(heard, "press").length === 2)
    assert.deepEqual(
      sent(heard, "press").map(({args}) => args),
      [
        {control: "pause-digest", call: 1},
        {control: "vpn-connect", value: "lisbon-1", call: 2}
      ]
    )

    answerOn(port, "pressed", {control: "vpn-connect", call: 2, outcome: "refused", reason: "invalid_argument"})
    answerOn(port, "pressed", {control: "pause-digest", call: 1, outcome: "accepted"})
    assert.deepEqual({...(await accepted)}, {outcome: "accepted"})
    assert.deepEqual({...(await picked)}, {outcome: "refused", reason: "invalid_argument"})

    assert.equal(api.press(PRESS.binding, PRESS.action), undefined)
    await eventually(() => sent(heard, "press").length === 3)
    assert.deepEqual(sent(heard, "press")[2].args, PRESS)

    await assert.rejects(api.press("Not An Id"), {code: "invalid_argument"})
    await assert.rejects(api.press("pause-digest", ""), {code: "invalid_argument"})
  })

  test("a write of the preferences settles with the answer, and desktop follows the document the shell holds", async () => {
    const client = await canvasClient()
    const port = client.open(SHOWN)
    const {api, heard} = client
    const seen = []
    api.on("desktop", (desktop) => seen.push(desktop))
    await eventually(() => seen.length === 1)

    const writing = api.prefs({widgets: {runs: {on: false}}})
    await eventually(() => sent(heard, "prefs").length === 1)
    assert.deepEqual(sent(heard, "prefs")[0].args, {document: {widgets: {runs: {on: false}}}, call: 1})

    const current = {widgets: {runs: {on: true}, apps: {on: false}}, desktop: {}}
    answerOn(port, "prefs", {call: 1, outcome: "stale", document: current, revision: 8})
    assert.deepEqual({...(await writing)}, {outcome: "stale", document: current, revision: 8})
    await eventually(() => seen.length === 2)
    assert.deepEqual(api.desktop.prefs, {document: current, revision: 8})

    await assert.rejects(api.prefs([]), {code: "invalid_argument"})
  })

  test("a cancelled later press cannot answer an earlier press of the same control still running", async () => {
    const client = await canvasClient()
    const port = client.open(SHOWN)
    const {api, heard} = client

    const first = api.press("pause-digest", "sch_first")
    const second = api.press("pause-digest", "sch_second")
    await eventually(() => sent(heard, "press").length === 2)
    const [one, two] = sent(heard, "press").map(({args}) => args.call)

    // The second is told it did not run before the first's run ends.
    answerOn(port, "pressed", {control: "pause-digest", call: two, outcome: "cancelled"})
    answerOn(port, "pressed", {control: "pause-digest", call: one, outcome: "accepted"})

    assert.deepEqual(
      (await Promise.all([first, second])).map((answer) => ({...answer})),
      [{outcome: "accepted"}, {outcome: "cancelled"}]
    )
  })

  test("a cancelled later write cannot answer an earlier write still pending", async () => {
    const client = await canvasClient()
    const port = client.open(SHOWN)
    const {api, heard} = client
    const document = {widgets: {runs: {on: false}}, desktop: {}}

    const first = api.prefs({widgets: document.widgets})
    const second = api.prefs({widgets: {apps: {on: false}}})
    await eventually(() => sent(heard, "prefs").length === 2)
    const [one, two] = sent(heard, "prefs").map(({args}) => args.call)

    // The second is told it did not run before the first's write is answered.
    answerOn(port, "prefs", {call: two, outcome: "cancelled", ...OPEN.canvas.prefs})
    answerOn(port, "prefs", {call: one, outcome: "saved", document, revision: 1})

    assert.deepEqual(
      (await Promise.all([first, second])).map(({outcome}) => outcome),
      ["saved", "cancelled"]
    )
  })

  test("stale completed prefs call cannot roll back a later saved revision", async () => {
    const client = await canvasClient()
    const port = client.open(SHOWN)
    const {api, heard} = client
    const seen = []
    api.on("desktop", (desktop) => seen.push(desktop))
    await eventually(() => seen.length === 1)
    const older = {widgets: {runs: {on: false}}, desktop: {}}
    const newer = {widgets: {runs: {on: true}}, desktop: {}}

    const first = api.prefs(older)
    await eventually(() => sent(heard, "prefs").length === 1)
    const one = sent(heard, "prefs")[0].args.call
    answerOn(port, "prefs", {call: one, outcome: "saved", document: older, revision: 4})
    await first
    const second = api.prefs(newer)
    await eventually(() => sent(heard, "prefs").length === 2)
    answerOn(port, "prefs", {call: sent(heard, "prefs")[1].args.call, outcome: "saved", document: newer, revision: 5})
    await second
    await eventually(() => seen.length === 3)

    // The first write's answer comes again.
    answerOn(port, "prefs", {call: one, outcome: "saved", document: older, revision: 4})
    await tick()
    assert.deepEqual(api.desktop.prefs, {document: newer, revision: 5})
    assert.equal(seen.length, 3)
  })

  test("unknown prefs reply leaves desktop and desktop events untouched", async () => {
    const client = await canvasClient()
    const port = client.open(SHOWN)
    const {api} = client
    const seen = []
    api.on("desktop", (desktop) => seen.push(desktop))
    await eventually(() => seen.length === 1)
    const before = {...api.desktop}

    const document = {widgets: {runs: {on: false}}, desktop: {}}
    answerOn(port, "prefs", {call: 999, outcome: "saved", document, revision: 99})
    await tick()
    assert.deepEqual({...api.desktop}, before)
    assert.equal(seen.length, 1)
  })

  test("ask, settings and an open on a subject post the wire's messages; an open on a subject outside it posts nothing", async () => {
    const client = await canvasClient()
    client.open(SHOWN)
    const {api, heard} = client
    const subject = {kind: "run", id: "exec_0190f3a2"}

    api.ask("runs")
    api.settings("schedules")
    api.open("t:local.runs", {kind: "url", id: "x"})
    api.open("t:local.runs", subject)
    await settled(client)

    assert.deepEqual(
      heard.filter(({verb}) => ["ask", "settings", "open"].includes(verb)).map(({verb, args}) => [verb, args]),
      [
        ["ask", {widget: "runs"}],
        ["settings", {page: "schedules"}],
        ["open", {ref: "t:local.runs", subject}]
      ]
    )
  })

  test("an app opened on a subject reads it; a page that is no canvas presses no control and writes nothing", async () => {
    const {api, onWindowMessage, win} = await frameClient()
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    const heard = []
    channel.port1.onmessage = (event) => heard.push(event.data)
    const subject = {kind: "thread", id: "thr_0190f3a2"}

    onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [channel.port2]})
    channel.port1.postMessage(toFrameMessage("subject", FRAME, subject))
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame: FRAME, credential: CREDENTIAL_VALUE})
    await eventually(() => api.frame === FRAME && api.subject !== null)

    assert.deepEqual({...api.subject}, subject)
    assert.deepEqual({...(await api.press("pause-digest"))}, {outcome: "cancelled"})
    assert.deepEqual({...(await api.prefs({widgets: {}}))}, {outcome: "cancelled"})
    api.ready()
    await eventually(() => heard.length === 1)
    assert.deepEqual(heard, [{v: 1, verb: "ready", frame: FRAME, args: {}}])
  })
})
