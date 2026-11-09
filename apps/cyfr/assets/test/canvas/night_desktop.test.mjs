// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The shipped night desktop (seed/components/tinctures/local/night): its
// model, run as the page runs it, and how it squares with its manifest.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"
import vm from "node:vm"

const dir = new URL("../../../../../seed/components/tinctures/local/night/0.1.0/", import.meta.url)
const manifest = JSON.parse(readFileSync(new URL("cyfr-manifest.json", dir), "utf8"))
const desk = manifest.tincture.desktop

// model.js sets `Night` on the global it runs in.
const sandbox = {Intl, Date, Math, Number, String, JSON, Map, Set, Object, Array}
vm.runInNewContext(readFileSync(new URL("model.js", dir), "utf8"), sandbox)
const N = sandbox.Night

// The stream a part's key names, as the manifest declares it.
const declared = (key) => (key.startsWith("feed:") ? desk.feeds.includes(key.slice(5)) : desk.data.includes(key))

describe("the night desktop", () => {
  test("the parts that start lit read five streams, what waits first", () => {
    const {open, held} = N.wantedStreams({})
    assert.deepEqual([...open], ["attention.changes", "threads.changes", "schedules.changes", "runs.changes", "components.changes"])
    assert.deepEqual([...held], [])
  })

  test("whatever parts are lit, at most five streams are open at once", () => {
    const ids = N.ORDER
    for (let mask = 0; mask < 1 << ids.length; mask++) {
      const widgets = Object.fromEntries(ids.map((id, i) => [id, {on: (mask & (1 << i)) !== 0}]))
      const {open, held} = N.wantedStreams({widgets})
      assert.ok(open.length <= 5, `${open.length} open for ${mask}`)
      assert.equal(open[0], "attention.changes")
      assert.equal(new Set([...open, ...held]).size, open.length + held.length)
    }
  })

  test("every stream a part reads is declared, and every declared stream is read", () => {
    const read = new Set(["attention.changes", ...N.ORDER.flatMap((id) => N.PARTS[id].streams)])
    for (const key of read) assert.ok(declared(key), key)
    for (const name of desk.data) assert.ok(read.has(name), name)
    for (const feed of desk.feeds) assert.ok(read.has(`feed:${feed}`), feed)
  })

  test("each part is a widget of the preferences, and the controls are the schedules' pause and resume", () => {
    assert.deepEqual(Object.keys(desk.prefs.widgets).sort(), [...N.ORDER].sort())
    assert.deepEqual(desk.controls.map((c) => [c.id, c.operation]), [
      ["pause-schedule", "schedule.pause"],
      ["resume-schedule", "schedule.resume"],
    ])
    const street = readFileSync(new URL("street.js", dir), "utf8")
    for (const id of street.match(/control: '([a-z-]+)'/g).map((m) => m.slice(10, -1))) {
      assert.ok(desk.controls.some((c) => c.id === id), id)
    }
  })

  test("a flip writes the part's whole entry; a move writes every part in its new place", () => {
    assert.deepEqual(JSON.parse(JSON.stringify(N.flipDoc({}, "crew"))), {widgets: {crew: {on: true, place: 3}}})
    const moved = N.moveDoc({}, "board", -1).widgets
    assert.equal(moved.board.place, 0)
    assert.equal(moved.threads.place, 1)
    assert.equal(moved.vault.on, false)
    assert.equal(N.moveDoc({}, "threads", -1), null)
    const prefs = JSON.parse(JSON.stringify({widgets: moved}))
    assert.deepEqual([...N.order(prefs)].slice(0, 2), ["board", "threads"])
  })

  test("what waits lights the sign it is about, and goes out when it is removed", () => {
    const s = N.EMPTY()
    N.fold(s, "attention.changes", {kind: "approval", id: "apr_1", label: "Trip", since: "2026-11-09T10:00:00Z", destination: {kind: "page", page: "chat", ref: "thr_1"}}, 0)
    N.fold(s, "attention.changes", {kind: "failed_run", id: "catalyst:local.openai:1.4.1", label: "catalyst:local.openai:1.4.1", since: "2026-11-09T09:00:00Z", destination: {kind: "page", page: "executions", ref: "exe_1"}}, 0)
    const lit = N.litTable(N.waiting(s, null))
    assert.equal(lit.get("thread:thr_1").word, "approve")
    assert.equal(lit.get("failed:catalyst:local.openai:1.4.1").label, "openai")
    N.fold(s, "attention.changes", {kind: "removed", id: "apr_1"}, 0)
    assert.equal(N.waiting(s, null).length, 1)
  })

  test("the page reads nothing but its streams and loads only its own files", () => {
    for (const name of ["index.html", "model.js", "scene.js", "street.js", "styles.css"]) {
      const source = readFileSync(new URL(name, dir), "utf8")
      assert.doesNotMatch(source, /\b(fetch|XMLHttpRequest|localStorage|sessionStorage)\b/, name)
      assert.doesNotMatch(source, /https?:\/\/(?!www\.w3\.org\/2000\/svg)/, name)
    }
  })
})
