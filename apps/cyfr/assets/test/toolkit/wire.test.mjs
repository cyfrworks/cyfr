// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {
  ROLES,
  TOOLKIT_MAJORS,
  TO_PRISM_VERBS,
  TO_TOOLKIT_VERBS,
  VERSION,
  answer,
  bootStreamsRefused,
  dataPath,
  decode,
  decodeAnswer,
  decodeFromModule,
  decodeFromStreams,
  decodeRecord,
  decodeRequest,
  encode,
  isTinctureRef,
  recordFromEnvelope,
  replacesRecord,
  servedPrefix
} from "../../js/toolkit/wire.js"
import {CREDENTIAL, FRAME, bootArgs, canvasWire, feedEnvelopes} from "./support.mjs"

const boot = (args) => ({v: 1, verb: "boot", frame: FRAME, args})

describe("the canvas wire is Prima.CanvasWire's", () => {
  test("version and verbs", () => {
    assert.equal(VERSION, canvasWire.version)
    assert.deepEqual([...TO_PRISM_VERBS], canvasWire.to_prism_verbs)
    assert.deepEqual([...TO_TOOLKIT_VERBS], canvasWire.to_toolkit_verbs)
    assert.deepEqual([...TOOLKIT_MAJORS], [1])
  })

  test("every valid message decodes, is of its direction, and encodes back to itself", () => {
    for (const {direction, message} of canvasWire.messages.valid) {
      const decoded = decode(message)
      assert.equal(decoded.ok, true, `${message.verb}: ${decoded.error}`)
      const verbs = direction === "to_prism" ? TO_PRISM_VERBS : TO_TOOLKIT_VERBS
      assert.ok(verbs.includes(decoded.message.verb), message.verb)
      assert.deepEqual(encode(message.verb, message.frame, message.args), message)
    }
  })

  test("every invalid message is refused, and encoding its verb, frame and arguments throws when they are what is wrong", () => {
    for (const {why, message} of canvasWire.messages.invalid) {
      assert.equal(decode(message).ok, false, why)
      if (message && typeof message === "object" && !Array.isArray(message)) {
        const {verb, frame, args} = message
        if (decode({v: 1, verb, frame, args}).ok) continue
        assert.throws(() => encode(verb, frame, args), TypeError, why)
      }
    }
  })

  test("a refusal names no value the message carries", () => {
    const message = boot({...bootArgs(), extra: CREDENTIAL})
    assert.equal(decode(message).ok, false)
    assert.ok(!decode(message).error.includes(CREDENTIAL))
    assert.throws(
      () => encode("boot", FRAME, {...bootArgs(), toolkit: 0}),
      (error) => !String(error.message).includes(CREDENTIAL)
    )
  })

  test("the data path is the vector's, and a frame id outside its grammar throws", () => {
    for (const row of canvasWire.paths.valid) assert.equal(dataPath(row.frame), row.data_path)
    assert.throws(() => dataPath("not a frame id"), TypeError)
  })

  test("a module's served prefix is its credential's", () => {
    assert.equal(servedPrefix("/_s/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/lib/canvas.mjs"), "/_s/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/")
    assert.throws(() => servedPrefix("/assets/canvas.js"), TypeError)
  })
})

describe("a boot names the version's declared streams", () => {
  test("streams are at most 64 distinct pairs of a stream name and a subject or null", () => {
    assert.equal(decode(boot(bootArgs({streams: []}))).ok, true)
    assert.equal(decode(boot(bootArgs({streams: [{name: "runs.changes", subject: null}]}))).ok, true)

    const pairs = (n) => Array.from({length: n}, (_, i) => ({name: "feed.results", subject: `feed-${i}`}))
    assert.equal(decode(boot(bootArgs({streams: pairs(64)}))).ok, true)

    for (const [why, streams] of [
      ["65 pairs", pairs(65)],
      ["a duplicate pair", [{name: "feed.results", subject: "btc"}, {name: "feed.results", subject: "btc"}]],
      ["an extra key", [{name: "feed.results", subject: "btc", filter: "feed"}]],
      ["no subject", [{name: "feed.results"}]],
      ["a name outside the grammar", [{name: "feed", subject: "btc"}]],
      ["a subject of another type", [{name: "feed.results", subject: 7}]],
      ["not a list", {name: "feed.results", subject: "btc"}]
    ]) {
      assert.equal(decode(boot(bootArgs({streams}))).ok, false, why)
    }
  })

  test("a boot without streams is refused, and read as refused for its streams alone", () => {
    const {streams: _streams, ...lacking} = bootArgs()
    assert.equal(decode(boot(lacking)).ok, false)
    assert.equal(bootStreamsRefused(boot(lacking), FRAME), true)
    assert.equal(bootStreamsRefused(boot(bootArgs({streams: [{name: "feed.results"}]})), FRAME), true)

    // A boot refused for anything else, or another frame's, is not.
    assert.equal(bootStreamsRefused(boot({...lacking, toolkit: 0}), FRAME), false)
    assert.equal(bootStreamsRefused(boot(bootArgs({data_path: "/_f/v1/o/frm_00aa11bb22/", streams: 1})), FRAME), false)
    assert.equal(bootStreamsRefused(boot(lacking), "frm_00aa11bb22"), false)
    assert.equal(bootStreamsRefused(boot(bootArgs()), FRAME), false)
  })
})

describe("a tincture reference is read as Prima.ComponentRef reads one", () => {
  test("shorthand, pinned, padded and multi-dot references are tinctures'; others are not", () => {
    for (const ref of [
      "tincture:local.vault",
      "t:local.vault",
      "tincture:local.vault:1.0.0",
      "tincture:stripe.com.api",
      " tincture:local.vault\u0085",
      "tincture:local.vault:"
    ]) {
      assert.equal(isTinctureRef(ref), true, ref)
    }
    for (const ref of [
      "catalyst:local.markets",
      "agent:local.aqua",
      "local.vault",
      "tincture:vault",
      "tincture:.vault",
      "tincture:local.",
      "tincture:local.vault:latest",
      "tincture:local.vault:1.0",
      "﻿tincture:local.vault",
      "tincture:local.vault\uD800",
      "https://example.com/",
      7
    ]) {
      assert.equal(isTinctureRef(ref), false, String(ref))
    }
  })
})

describe("the toolkit's own protocol", () => {
  const {envelope} = feedEnvelopes[0]

  test("the roles are the names the host starts its workers under", () => {
    assert.deepEqual(ROLES, {module: "cyfr-toolkit-module", streams: "cyfr-toolkit-streams"})
  })

  test("the module worker's channel carries only trees and failures", () => {
    assert.deepEqual(decodeFromModule({t: "tree", json: "{}"}), {kind: "tree", json: "{}"})
    assert.deepEqual(decodeFromModule({t: "tree", json: null}), {kind: "tree", json: null})
    assert.deepEqual(decodeFromModule({t: "failed", stage: "load"}), {kind: "failed", stage: "load"})

    for (const data of [
      {t: "failed", stage: "tree"},
      {t: "tree", json: {}},
      {t: "tree", json: "{}", extra: 1},
      {t: "relay", m: answer.event(0, {id: 1, event: "feed.results", data: envelope}), record: null},
      {t: "binding", feed: "btc", binding: envelope.binding},
      null,
      "tree"
    ]) {
      assert.equal(decodeFromModule(data), null, JSON.stringify(data))
    }
  })

  test("the streams worker's channel carries relays and the module worker's loss", () => {
    const m = answer.event(0, {id: 7, event: "feed.results", data: envelope})
    const record = recordFromEnvelope(envelope, "btc")
    assert.deepEqual(decodeFromStreams({t: "relay", m, record}), {kind: "relay", m, record})
    assert.deepEqual(decodeFromStreams({t: "relay", m, record: null}), {kind: "relay", m, record: null})
    assert.deepEqual(decodeFromStreams({t: "lost"}), {kind: "lost"})
    assert.equal(decodeFromStreams({t: "relay", m}), null)
    assert.equal(decodeFromStreams({t: "relay", m: {t: "event"}, record: null}), null)
    assert.equal(decodeFromStreams({t: "relay", m, record: {...record, label: ""}}), null)
  })

  test("requests and answers between the workers", () => {
    assert.deepEqual(decodeRequest({t: "open", sub: 0, name: "feed.results", subject: "btc"}), {
      kind: "open",
      sub: 0,
      name: "feed.results",
      subject: "btc"
    })
    assert.deepEqual(decodeRequest({t: "close", sub: 3}), {kind: "close", sub: 3})
    assert.equal(decodeRequest({t: "open", sub: -1, name: "feed.results", subject: null}), null)
    assert.equal(decodeRequest({t: "open", sub: 0, name: "feed.results", subject: null, credential: "x"}), null)

    for (const m of [answer.opened(1), answer.refused(1, "forbidden", "No.", "admission"), answer.closed(1, null)]) {
      assert.deepEqual(decodeAnswer(m), m)
    }
    assert.equal(decodeAnswer({t: "opened", sub: 1, bearer: CREDENTIAL}), null)
  })
})

describe("binding records come from a feed's own envelope", () => {
  test("every vector envelope makes the record of its own feed, and of no other", () => {
    for (const {envelope} of feedEnvelopes) {
      const record = recordFromEnvelope(envelope, envelope.feed)
      assert.deepEqual(record, {
        feed: envelope.feed,
        binding: envelope.binding,
        revision: envelope.revision,
        label: envelope.label,
        actions: envelope.actions
      })
      assert.equal(recordFromEnvelope(envelope, "another-feed"), null)
    }
  })

  test("an envelope outside the binding's grammar makes none", () => {
    const {envelope} = feedEnvelopes[0]
    for (const [why, broken] of [
      ["no binding id", {...envelope, binding: "btc"}],
      ["a negative revision", {...envelope, revision: -1}],
      ["a label past 80 code points", {...envelope, label: "x".repeat(81)}],
      ["an action label past 40 code points", {...envelope, actions: [{name: "buy", label: "x".repeat(41)}]}],
      ["an action label with a control character", {...envelope, actions: [{name: "buy", label: "Buy\u0007"}]}],
      ["two actions of one name", {...envelope, actions: [{name: "buy", label: "A"}, {name: "buy", label: "B"}]}],
      ["nine actions", {...envelope, actions: Array.from({length: 9}, (_, i) => ({name: `a${i}`, label: "A"}))}]
    ]) {
      assert.equal(recordFromEnvelope(broken, envelope.feed), null, why)
    }
    assert.equal(decodeRecord({...recordFromEnvelope(envelope, envelope.feed), extra: 1}), null)
  })

  test("a later envelope replaces the record, but an earlier revision of the same binding does not", () => {
    const stored = {binding: "feed_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d", revision: 7}
    assert.equal(replacesRecord(undefined, stored), true)
    assert.equal(replacesRecord(stored, {...stored, revision: 8}), true)
    assert.equal(replacesRecord(stored, {...stored, revision: 7}), false)
    assert.equal(replacesRecord(stored, {...stored, revision: 6}), false)
    // A rebound feed's first result replaces the old binding's, whatever its revision.
    assert.equal(replacesRecord(stored, {binding: "feed_01a09fee-2e4f-7a5b-bc6d-7e8f9a0b1c2e", revision: 1}), true)
  })
})
