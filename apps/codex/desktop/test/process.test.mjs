// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"

import {MAX_LINE, Refused, VERSION, lines, readFromCyfr, selection, toCyfr} from "../src/process.js"

const vectors = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/desktop-process.json", import.meta.url)))

test("main speaks the vectors' version", () => {
  assert.equal(vectors["version"], VERSION)
})

test("main reads each message cyfr sends as pinned", () => {
  for (const {name, message} of vectors["go_to_main"]) {
    assert.deepEqual(readFromCyfr(JSON.stringify(message)), message, name)
  }
})

test("main writes each message it sends as pinned, one line each", () => {
  for (const {name, message} of vectors["main_to_go"]) {
    const {version, type, ...fields} = message
    assert.equal(version, VERSION)
    const line = toCyfr(type, fields)
    assert.ok(line.endsWith("\n") && line.indexOf("\n") === line.length - 1, name)
    assert.deepEqual(JSON.parse(line), message, name)
  }
})

test("main refuses each line refused to it, with its reason", () => {
  const mine = vectors["refused"].filter((r) => r.to === "main")
  assert.ok(mine.length > 0)
  for (const {name, line, reason} of mine) {
    assert.throws(() => readFromCyfr(line), (e) => e instanceof Refused && e.reason === reason, name)
  }
  assert.throws(() => readFromCyfr(" ".repeat(MAX_LINE + 1)), (e) => e.reason === "size")
})

test("main sends nothing cyfr sends", () => {
  for (const type of ["ready", "home", "opened", "locked", "pick-folder", "unlock"]) {
    assert.throws(() => toCyfr(type, {}))
  }
})

test("lines are whole lines, however the stream cuts them", () => {
  const got = []
  const feed = lines((l) => got.push(l))
  feed('{"version":1,"type":"lo')
  feed('cked"}\n{"version":1,')
  feed('"type":"locked"}\n')
  assert.deepEqual(got, ['{"version":1,"type":"locked"}', '{"version":1,"type":"locked"}'])
  assert.throws(() => lines(() => {})("x".repeat(MAX_LINE + 1)), (e) => e.reason === "size")
})

// cyfr's messages in an interrupted Connect (internal/desktop's
// TestALockEndsASelectionWaitingForMain): home, a lock before cyfr
// commits it, then home again for the same CYFR, which opens.
test("main holds a CYFR as selected only once cyfr says it opened it", () => {
  const home = {version: 1, type: "home", home: "https://cyfr.example.com", account: "https://cyfr.run"}
  const chosen = selection()
  assert.equal(chosen.propose(home), true)
  assert.equal(chosen.home, home.home)
  chosen.cancel()
  assert.equal(chosen.home, "", "a lock ends the proposal cyfr did not commit")
  assert.equal(chosen.propose(home), true, "the same CYFR proposed again")
  assert.equal(chosen.opened("https://another.example.com"), false)
  assert.equal(chosen.opened(home.home), true)
  chosen.cancel()
  assert.equal(chosen.home, home.home, "a lock keeps the CYFR cyfr committed")
  assert.equal(chosen.propose({...home, home: "https://another.example.com"}), false)
  assert.equal(chosen.opened(home.home), false, "opened twice")

  const failed = selection()
  failed.propose(home)
  assert.equal(failed.propose({...home, home: "https://another.example.com"}), true, "after a failure, another CYFR")
  assert.equal(failed.opened("https://another.example.com"), true)
})
