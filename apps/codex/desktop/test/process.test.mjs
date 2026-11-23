// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"

import {MAX_LINE, Refused, VERSION, absolute, lines, readFromCyfr, toCyfr} from "../src/process.js"

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

// The folders cyfr refuses in a folder-picked, which main writes none of.
test("main names no folder or pick cyfr refuses, and every folder cyfr reads", () => {
  const object = (line) => { try { return JSON.parse(line) } catch { return null } }
  const whole = (n) => Number.isSafeInteger(n) && n >= 0
  const picks = vectors["refused"].filter((r) => r.to === "go").map((r) => object(r.line))
    .filter((m) => m?.type === "folder-picked" && Object.keys(m).length === 5 && ["path", "epoch", "pick"].every((k) => Object.hasOwn(m, k)))
  const refused = picks.filter((m) => whole(m.epoch) && whole(m.pick))
  assert.ok(refused.length >= 5)
  for (const {path, epoch, pick} of refused) {
    assert.equal(absolute(path), false, JSON.stringify(path))
    assert.throws(() => toCyfr("folder-picked", {path, epoch, pick}), JSON.stringify(path))
  }
  const misnumbered = picks.filter((m) => !whole(m.epoch) || !whole(m.pick))
  assert.ok(misnumbered.length >= 3)
  for (const {path, epoch, pick} of misnumbered) {
    assert.throws(() => toCyfr("folder-picked", {path, epoch, pick}), JSON.stringify({epoch, pick}))
  }
  const read = vectors["main_to_go"].filter(({message}) => message.type === "folder-picked" && message.path !== null)
  assert.ok(read.length >= 3)
  for (const {message: {path}} of read) assert.equal(absolute(path), true, path)
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

