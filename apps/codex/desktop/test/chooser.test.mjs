// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The chooser cyfr serves (internal/desktop/bootstrap.go): its own script,
// run over the elements its own page has. It stays while it has a notice to
// show, with its way on, and moves on by itself only when it has none. On
// the passkey road it opens the CYFR remembered by itself, and otherwise
// shows both ways on and the way to another CYFR.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

const source = readFileSync(new URL("../../internal/desktop/bootstrap.go", import.meta.url), "utf8")
const script = /bootstrapScript = `([^`]*)`/.exec(source)?.[1]
const page = /const bootstrapPage = `([\s\S]*)/.exec(source)?.[1]
assert.ok(script && page, "bootstrap.go's script and page")

const HOME = "https://cyfr.example.com"
const COMPANY = "This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet."
const PASSKEY = HOME + "/login"
const OPEN = {home: HOME, next: "/"}
const BOTH = {...OPEN, passkey: PASSKEY}
const OPENED = {...BOTH, open: HOME + "/"}

// The chooser opened with `notice` while cyfr answers `state`: its
// elements, each as hidden as the page starts it, and where it went.
async function chooser(notice, state, connected = OPEN, hash = "#token=t" + (notice ? `&notice=${notice}` : "")) {
  const elements = new Map()
  for (const [tag, id] of page.matchAll(/<[a-z0-9]+\b[^>]*\bid="([a-z]+)"[^>]*>/g)) {
    const listeners = {}
    elements.set(id, {hidden: /\shidden[\s>]/.test(tag), textContent: "", value: "", onclick: null,
      addEventListener: (type, f) => { listeners[type] = f },
      fire: (type) => listeners[type]?.({preventDefault() {}})})
  }
  const went = {byItself: [], pressed: [], asked: []}
  const stored = new Map()
  vm.runInNewContext(script, {
    URLSearchParams,
    document: {getElementById: (id) => elements.get(id)},
    sessionStorage: {getItem: (k) => stored.get(k) ?? null, setItem: (k, v) => stored.set(k, v)},
    history: {replaceState: (_state, _title, to) => { went.address = to }},
    location: {pathname: "/bootstrap/", hash,
      replace: (to) => went.byItself.push(to), assign: (to) => went.pressed.push(to)},
    fetch: async (path, init) => {
      const {token, ...body} = JSON.parse(init.body)
      if (path !== "/bootstrap/state") went.asked.push([path, body])
      return {ok: true, json: async () => (path === "/bootstrap/state" ? state : path === "/bootstrap/another" ? {} : connected)}
    }
  })
  await settled()
  return {$: (id) => elements.get(id), went}
}

const settled = () => new Promise((resolve) => setImmediate(resolve))

test("with a notice to show the chooser stays, says it, and offers its way on to the device's pages", async () => {
  for (const [notice, words] of [["company", COMPANY], ["nothing-it-knows,company", COMPANY]]) {
    const {$, went} = await chooser(notice, OPEN)
    assert.deepEqual(went.byItself, [], notice)
    assert.equal($("notice").textContent, words)
    assert.deepEqual([$("choose").hidden, $("road").hidden, $("words").hidden], [true, false, false], notice)
    assert.deepEqual([$("passkey").hidden, $("either").hidden, $("another").hidden], [true, true, true],
      "no passkey road where cyfr offers none")
    assert.equal($("open").textContent, HOME)
    $("words").onclick()
    assert.deepEqual(went.pressed, ["/"], "Use this computer's key goes on")
  }
})

test("a reload of a chooser that stays keeps its notice, and its address never keeps the token", async () => {
  const first = await chooser("company", OPEN)
  assert.doesNotMatch(first.went.address, /token/)
  const again = await chooser("", OPEN, OPEN, new URL(first.went.address, "http://127.0.0.1:7340").hash)
  assert.deepEqual(again.went.byItself, [], "the reload did not move on")
  assert.equal(again.$("notice").textContent, COMPANY)
  assert.equal((await chooser("", OPEN)).went.address, "/bootstrap/", "with none, the bare address")
})

test("with no notice to show the chooser moves on by itself", async () => {
  for (const notice of ["", "nothing-it-knows"]) {
    const {$, went} = await chooser(notice, OPEN)
    assert.deepEqual(went.byItself, ["/"], notice)
    assert.equal($("notice").textContent, "")
    assert.equal($("road").hidden, true, notice)
  }
})

test("on the passkey road the chooser stays with both ways on and the way to another CYFR, a notice or none", async () => {
  for (const notice of ["", "company"]) {
    const {$, went} = await chooser(notice, BOTH)
    assert.deepEqual(went.byItself, [], notice)
    assert.deepEqual([$("road").hidden, $("passkey").hidden, $("either").hidden, $("another").hidden], [false, false, false, false], notice)
    assert.equal($("notice").textContent, notice ? COMPANY : "")
    $("passkey").onclick()
    assert.deepEqual(went.pressed, [PASSKEY])
    assert.deepEqual(went.asked, [], "it connects nothing by itself")
  }
})

test("as the app starts on the passkey road the CYFR remembered connects by itself and opens at its root", async () => {
  const {went} = await chooser("", {home: HOME, resume: HOME}, OPENED)
  await settled()
  assert.deepEqual(went.asked, [["/bootstrap/connect", {address: HOME}]])
  assert.deepEqual(went.byItself, [HOME + "/"], "a kept sign-in lands in the CYFR")
})

test("a Connect the person makes on the passkey road opens that CYFR at its root", async () => {
  const {$, went} = await chooser("", {home: HOME}, OPENED)
  assert.deepEqual(went.asked, [], "nothing by itself")
  $("connect").fire("submit")
  await settled()
  assert.deepEqual(went.byItself, [HOME + "/"])
})

test("with a notice to show the chooser connects nothing by itself", async () => {
  const {went} = await chooser("company", {home: HOME, resume: HOME}, OPENED)
  assert.deepEqual(went.asked, [])
  assert.deepEqual(went.byItself, [])
})

test("Connect to another CYFR leaves the one open for the chooser's Connect", async () => {
  const {$, went} = await chooser("", BOTH)
  $("another").fire("click")
  await settled()
  assert.deepEqual(went.asked, [["/bootstrap/another", {}]])
  assert.deepEqual([$("choose").hidden, $("road").hidden], [false, true])
  assert.deepEqual(went.byItself, [])
})

test("with no CYFR open a notice shows on Connect, and a Connect the person makes goes on", async () => {
  const {$, went} = await chooser("company", {})
  assert.deepEqual([$("choose").hidden, $("road").hidden], [false, true])
  assert.equal($("notice").textContent, COMPANY)
  assert.deepEqual(went.byItself, [])
  $("connect").fire("submit")
  await settled()
  assert.deepEqual(went.byItself, ["/"])
})

test("an answer that is an error says the error and goes nowhere", async () => {
  const {$, went} = await chooser("company", {error: "The record could not be read."})
  assert.equal($("notice").textContent, "The record could not be read.")
  assert.deepEqual(went.byItself, [])
})
