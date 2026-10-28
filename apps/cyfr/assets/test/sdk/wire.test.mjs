// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {
  BEARER_HEADER,
  ROUTES,
  STAGES,
  TO_FRAME_VERBS,
  VERBS,
  VERSION,
  bearer,
  dataPath,
  decodeAnswer,
  decodeCanvasHandshake,
  decodeShellMessage,
  decodeToFrame,
  publicIdentity,
  request,
  shellMessage,
  sseParser,
  streamPath,
  toFrameMessage
} from "../../js/sdk/wire.js"
// `fixture` is tests/fixtures/tincture_wire.json, which Prima's test reads
// too: its shell, shell_invalid and canvas sections are held here.
import {credentialOf, fixture} from "./support.mjs"

// The tincture URL grammar `Prima.TinctureWire`'s test reads too.
const tinctureUrls = JSON.parse(
  readFileSync(new URL("../../../../../tests/fixtures/component_refs.json", import.meta.url), "utf8")
).tincture_urls

describe("the wire agrees with the fixture", () => {
  test("version, bearer header and routes", () => {
    assert.equal(VERSION, fixture.version)
    assert.equal(BEARER_HEADER, fixture.bearer_header)
    assert.deepEqual({...ROUTES}, fixture.routes)
    assert.deepEqual([...VERBS].sort(), [...new Set(fixture.shell.map((vector) => vector.verb))].sort())
  })

  test("every request body is the one the SDK builds, under the fixture's bearer", () => {
    for (const {kind, headers, body} of fixture.requests) {
      const fields =
        kind === "invoke"
          ? {ref: body.ref, operation: body.operation, args: body.args}
          : kind === "action"
            ? {operation: body.operation, args: body.args}
            : {stream: body.stream, subject: body.subject}

      assert.deepEqual(request(kind, fields), body, kind)
      assert.equal(bearer(credentialOf(headers.authorization)), headers.authorization)
    }
  })

  test("every answer reads back", () => {
    for (const {kind, body} of fixture.answers) {
      const decoded = decodeAnswer(kind, body)
      assert.equal(decoded.ok, true, kind)

      if (kind === "stream_open") {
        assert.equal(decoded.value.grant_id, body.stream.grant_id)
        assert.deepEqual(decoded.value.projection, body.stream.projection)
        assert.equal(decoded.value.deadline.toISOString(), "2026-09-26T12:00:00.000Z")
      } else {
        assert.deepEqual(decoded.value, body.result)
      }
    }
  })

  test("the refusal reads back as its projection, never its reason", () => {
    const {kind, refusal, body} = fixture.refusal
    const decoded = decodeAnswer(kind, body)

    assert.deepEqual(decoded, {
      ok: false,
      refusal: {class: refusal.class, message: refusal.message, stage: refusal.stage}
    })
  })

  test("every shell message decodes, and is the one the SDK builds", () => {
    for (const {verb, message} of fixture.shell) {
      assert.deepEqual(decodeShellMessage(message), {ok: true, message}, verb)
      assert.deepEqual(shellMessage(verb, message.frame, message.args), message, verb)
    }
  })
})

describe("the canvas's part of the wire agrees with the fixture", () => {
  const {canvas} = fixture

  test("every shell message the fixture refuses is refused", () => {
    assert.ok(fixture.shell_invalid.length > 0)
    for (const {why, message} of fixture.shell_invalid) {
      assert.equal(decodeShellMessage(message).ok, false, why)
    }
  })

  test("a failure's stages are the fixture's", () => {
    assert.deepEqual([...STAGES], canvas.stages)
  })

  test("every handshake reply reads back as its credential and canvas block", () => {
    assert.ok(canvas.handshake.valid.length > 0)
    for (const {frame, reply} of canvas.handshake.valid) {
      assert.deepEqual(decodeCanvasHandshake(reply, frame), {ok: true, credential: reply.credential, canvas: reply.canvas})
    }
  })

  test("every handshake reply the fixture refuses is refused", () => {
    assert.ok(canvas.handshake.invalid.length > 0)
    for (const {why, frame, reply} of canvas.handshake.invalid) {
      assert.equal(decodeCanvasHandshake(reply, frame).ok, false, why)
    }
  })

  test("every message to a canvas decodes, and is the one the bridge builds", () => {
    const verbs = new Set()
    for (const {message} of canvas.to_frame.valid) {
      verbs.add(message.verb)
      assert.deepEqual(decodeToFrame(message), {ok: true, message}, message.verb)
      assert.deepEqual(toFrameMessage(message.verb, message.frame, message.args), message, message.verb)
    }
    assert.deepEqual([...verbs].sort(), [...TO_FRAME_VERBS].sort())
  })

  test("every message to a canvas the fixture refuses is refused, and never built", () => {
    assert.ok(canvas.to_frame.invalid.length > 0)
    // The encoder builds the envelope itself, so only a row whose envelope
    // is the wire's (v 1, verb, frame and args) is one it could be asked for.
    let built = 0
    for (const {why, message} of canvas.to_frame.invalid) {
      assert.equal(decodeToFrame(message).ok, false, why)
      const envelope =
        message !== null &&
        typeof message === "object" &&
        !Array.isArray(message) &&
        message.v === VERSION &&
        Object.keys(message).sort().join() === "args,frame,v,verb"
      if (envelope) {
        built += 1
        assert.throws(() => toFrameMessage(message.verb, message.frame, message.args), TypeError, why)
      }
    }
    assert.ok(built > 0)
  })

  test("the canvas block a handshake carries is the canvas message's args", () => {
    for (const {frame, reply} of canvas.handshake.valid) {
      assert.equal(decodeToFrame(toFrameMessage("canvas", frame, reply.canvas)).ok, true)
    }
  })

  test("a canvas open's data path and stream route are the fixture's", () => {
    for (const row of canvas.paths.valid) {
      assert.equal(dataPath(row.frame), row.data_path)
      assert.equal(streamPath(row.frame), row.stream_path)
    }
  })

  // The page's path, which also names the asset credential, is the
  // server's alone; the frame id is the part of a path the SDK builds.
  test("a frame id the fixture refuses has no data path", () => {
    const refused = canvas.paths.invalid.filter(({why}) => why.includes("frame id"))
    assert.equal(refused.length, 2)
    for (const {why, frame} of refused) {
      assert.throws(() => dataPath(frame), TypeError, why)
      assert.throws(() => streamPath(frame), TypeError, why)
    }
  })
})

describe("what does not decode", () => {
  const frame = fixture.shell[0].message.frame

  test("an answer at another version, with an extra field, or of the wrong kind", () => {
    const [invoke] = fixture.answers
    assert.equal(decodeAnswer("invoke", {...invoke.body, v: 2}).invalid, true)
    assert.equal(decodeAnswer("invoke", {...invoke.body, extra: 1}).invalid, true)
    assert.equal(decodeAnswer("stream_open", invoke.body).invalid, true)
    assert.equal(decodeAnswer("invoke", "nope").invalid, true)
  })

  test("a verb carrying data", () => {
    for (const verb of ["ready", "close"]) {
      const decoded = decodeShellMessage({v: 1, verb, frame, args: {payload: {secret: 1}}})
      assert.equal(decoded.ok, false, verb)
    }

    assert.equal(
      decodeShellMessage({v: 1, verb: "credential", frame, args: {name: "api", value: "s3cret"}}).ok,
      false
    )

    assert.equal(
      decodeShellMessage({v: 1, verb: "title", frame, args: {title: "t", data: [1, 2]}}).ok,
      false
    )

    assert.equal(
      decodeShellMessage({v: 1, verb: "ready", frame, args: {}, payload: {input: 1}}).ok,
      false
    )
  })

  test("a data request posted as a verb, an old bridge request, a bad frame or version", () => {
    assert.equal(decodeShellMessage({v: 1, verb: "invoke", frame, args: {}}).ok, false)
    assert.equal(
      decodeShellMessage({type: "cyfr:request", action: "invoke", id: "req_1", payload: {}}).ok,
      false
    )
    assert.equal(decodeShellMessage({v: 1, verb: "ready", frame: "short", args: {}}).ok, false)
    assert.equal(decodeShellMessage({v: 2, verb: "ready", frame, args: {}}).ok, false)
    assert.equal(decodeShellMessage({v: 1, verb: "open", frame, args: {ref: "c:local.x"}}).ok, false)
    assert.equal(
      decodeShellMessage({v: 1, verb: "title", frame, args: {title: "x".repeat(121)}}).ok,
      false
    )
    for (const args of [{}, {name: ""}, {name: 7}]) {
      assert.equal(decodeShellMessage({v: 1, verb: "credential", frame, args}).ok, false)
    }
  })

  test("no verb raises a frame: focus is no verb", () => {
    assert.equal(decodeShellMessage({v: 1, verb: "focus", frame, args: {}}).ok, false)
    assert.throws(() => shellMessage("focus", frame))
  })

  test("a credential that is empty or carries whitespace is no bearer", () => {
    assert.throws(() => bearer(""))
    assert.throws(() => bearer("a b"))
  })
})

describe("a public page's identity", () => {
  test("is every public vector's tincture, read from its path and from a page under it", () => {
    assert.ok(tinctureUrls.public.length > 0)

    for (const {athanor, publisher, name, path} of tinctureUrls.public) {
      assert.deepEqual(publicIdentity(path), {athanor, publisher, name}, path)
      assert.deepEqual(publicIdentity(`${path}/index.html`), {athanor, publisher, name}, path)
    }
  })

  test("is none for any served-file vector, whatever it parses as", () => {
    assert.ok(tinctureUrls.served.length > 0)

    for (const {path} of tinctureUrls.served) {
      assert.equal(publicIdentity(path), null, path)
    }
  })

  test("is decoded: an escaped athanor and a publisher with dots", () => {
    assert.deepEqual(publicIdentity("/t/%40alice/stripe.com/pay-desk"), {
      athanor: "@alice",
      publisher: "stripe.com",
      name: "pay-desk"
    })
  })

  test("is none for any other path", () => {
    for (const path of [
      "/t/home/local",
      "/t//local/weather",
      "/t/home/Local/weather",
      "/t/home/local/../weather",
      "/t/%E0%A4%A/local/weather",
      "/tinctures",
      "/",
      null
    ]) {
      assert.equal(publicIdentity(path), null, String(path))
    }
  })

  test("travels in the body as public, beside the kind's fields", () => {
    const identity = {athanor: "home", publisher: "local", name: "weather"}
    const [invoke] = fixture.requests

    assert.deepEqual(
      request("invoke", {ref: invoke.body.ref, operation: invoke.body.operation, args: invoke.body.args}, identity),
      {...invoke.body, public: identity}
    )
    assert.deepEqual(request("stream_open", {stream: "executions.deltas", subject: null}, identity), {
      v: 1,
      stream: "executions.deltas",
      subject: null,
      public: identity
    })
  })
})

describe("the event stream's grammar", () => {
  const parse = (chunks) => {
    const events = []
    const parser = sseParser((event) => events.push(event))
    for (const chunk of chunks) parser.push(chunk)
    parser.end()
    return events
  }

  test("id, event and JSON data per blank-line-ended group", () => {
    assert.deepEqual(parse(['id: 7\nevent: delta\ndata: {"seq":7}\n\n']), [
      {id: 7, event: "delta", data: {seq: 7}}
    ])
  })

  test("comments, other fields and a missing id are ignored; data lines join", () => {
    const text = ': keepalive\nretry: 10\nevent: kind\ndata: {"a":\ndata: 1}\n\n'
    assert.deepEqual(parse([text]), [{id: null, event: "kind", data: {a: 1}}])
  })

  test("CRLF and CR end lines, even split between chunks", () => {
    assert.deepEqual(parse(["id: 1\r", "\ndata: 1\r\n\r", "\n", "id:2\rdata:2\r\r"]), [
      {id: 1, event: "message", data: 1},
      {id: 2, event: "message", data: 2}
    ])
  })

  test("any split of a stream delivers the same events", () => {
    const text = 'id: 1\nevent: delta\ndata: {"seq":1}\n\nid: 2\nevent: delta\ndata: {"seq":2}\n\n'
    const whole = parse([text])

    for (let cut = 1; cut < text.length; cut++) {
      assert.deepEqual(parse([text.slice(0, cut), text.slice(cut)]), whole, `cut at ${cut}`)
    }
  })

  test("data that is not JSON, an event with no data, and an unfinished event are dropped", () => {
    assert.deepEqual(parse(["data: not json\n\n", "event: x\n\n", 'data: {"late":1}']), [])
  })

  test("an id that is not a sequence number reads as none", () => {
    assert.deepEqual(parse(["id: abc\ndata: 1\n\n"]), [{id: null, event: "message", data: 1}])
  })
})
