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
const UNCLEARED = "The app could not clear the sign-in it kept on this computer, so it opened no other CYFR: try again."
const OPEN = {home: HOME, next: "/"}
// The passkey road, as main says it in the chooser's address.
const ROAD = "#token=t&road=passkey"

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
  went.stored = stored
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
      went.tokens = [...(went.tokens ?? []), token]
      if (path !== "/bootstrap/state") stored.clear() // main cleared the storage while it waited
      return {ok: true, json: async () => (path === "/bootstrap/state" ? state : connected)}
    }
  })
  await settled()
  return {$: (id) => elements.get(id), went}
}

const settled = () => new Promise((resolve) => setImmediate(resolve))

test("with a notice to show the chooser stays, says it, and offers its way on to the device's pages", async () => {
  for (const [notice, words] of [["company", COMPANY], ["uncleared", UNCLEARED], ["company,uncleared", `${COMPANY} ${UNCLEARED}`],
    ["nothing-it-knows,company", COMPANY]]) {
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
  const first = await chooser("company,uncleared", OPEN)
  assert.doesNotMatch(first.went.address, /token/)
  const again = await chooser("", OPEN, OPEN, new URL(first.went.address, "http://127.0.0.1:7340").hash)
  assert.deepEqual(again.went.byItself, [], "the reload did not move on")
  assert.equal(again.$("notice").textContent, `${COMPANY} ${UNCLEARED}`)
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
    const {$, went} = await chooser(notice, OPEN, OPEN, ROAD + (notice ? `&notice=${notice}` : ""))
    assert.deepEqual(went.byItself, [], notice)
    assert.deepEqual([$("road").hidden, $("passkey").hidden, $("either").hidden, $("another").hidden], [false, false, false, false], notice)
    assert.equal($("notice").textContent, notice ? COMPANY : "")
    assert.deepEqual(went.asked, [], "it connects nothing by itself")
    $("passkey").onclick()
    assert.deepEqual(went.pressed, [], "not before the CYFR answered")
    await settled()
    assert.deepEqual(went.asked, [["/bootstrap/connect", {address: HOME}]], "the press asks")
    assert.deepEqual(went.pressed, [PASSKEY])
  }
})

test("the passkey's way on goes nowhere when its press is not answered with a way on", async () => {
  for (const said of [{home: HOME, error: "It did not answer."}, {error: "CYFR locked. Connect again."}]) {
    const {$, went} = await chooser("", OPEN, said, ROAD)
    $("passkey").onclick()
    await settled()
    assert.deepEqual([went.byItself, went.pressed], [[], []])
    assert.equal($("notice").textContent, said.error)
    assert.deepEqual([$("road").hidden, $("passkey").hidden, $("words").hidden], [false, false, false], "both ways on stay")
  }
})

test("a reload keeps the road main said", async () => {
  const first = await chooser("", OPEN, OPEN, ROAD)
  assert.equal(first.went.address, "/bootstrap/#road=passkey")
  const again = await chooser("", OPEN, OPEN, "#road=passkey")
  assert.equal(again.$("passkey").hidden, false)
})

test("as the app starts on the passkey road the CYFR remembered connects by itself, and main opens it", async () => {
  const {$, went} = await chooser("", {home: HOME, resume: HOME}, OPEN, ROAD)
  await settled()
  assert.deepEqual(went.asked, [["/bootstrap/connect", {address: HOME}]])
  assert.deepEqual([went.byItself, went.pressed], [[], []], "the window is main's to send to the root")
  assert.equal($("road").hidden, true, "and no way on shows meanwhile")
})

test("on the six-word road a CYFR remembered waits for Connect", async () => {
  const {$, went} = await chooser("", {home: HOME, resume: HOME}, OPEN)
  assert.deepEqual(went.asked, [])
  assert.deepEqual([$("choose").hidden, $("address").value], [false, HOME])
})

test("a Connect the person makes on the passkey road leaves the opening to main", async () => {
  const {$, went} = await chooser("", {home: HOME}, OPEN, ROAD)
  assert.deepEqual(went.asked, [], "nothing by itself")
  $("connect").fire("submit")
  await settled()
  assert.deepEqual([went.byItself, went.pressed], [[], []])
})

test("a Connect main cleared the storage under keeps the run token", async () => {
  const {$, went} = await chooser("", {home: HOME}, {error: "It did not answer."}, ROAD)
  $("connect").fire("submit")
  await settled()
  assert.equal(went.stored.get("token"), "t", "put back for a reload")
  $("connect").fire("submit")
  await settled()
  assert.deepEqual(went.tokens, ["t", "t", "t"])
})

test("with a notice to show the chooser connects nothing by itself", async () => {
  const {went} = await chooser("company", {home: HOME, resume: HOME}, OPEN, ROAD + "&notice=company")
  assert.deepEqual(went.asked, [])
  assert.deepEqual(went.byItself, [])
})

test("Connect to another CYFR is asked of main, and cyfr is asked nothing", async () => {
  const {$, went} = await chooser("", OPEN, OPEN, ROAD)
  $("another").fire("click")
  await settled()
  assert.deepEqual(went.pressed, ["/bootstrap/another"])
  assert.deepEqual(went.asked, [])
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

test("an answer to a Connect whose clear failed says the sentence on the form and goes nowhere", async () => {
  for (const hash of ["#token=t", ROAD]) {
    const {$, went} = await chooser("", {home: HOME}, {home: HOME, notice: "uncleared"}, hash)
    $("connect").fire("submit")
    await settled()
    assert.equal($("notice").textContent, UNCLEARED, hash)
    assert.deepEqual([$("choose").hidden, $("road").hidden], [false, true], "Connect again")
    assert.deepEqual([went.byItself, went.pressed], [[], []], hash)
    assert.equal(went.stored.get("token"), "t", "and a reload still has the run token")
  }
})

test("an answer that is an error says the error and goes nowhere", async () => {
  const {$, went} = await chooser("company", {error: "The record could not be read."})
  assert.equal($("notice").textContent, "The record could not be read.")
  assert.deepEqual(went.byItself, [])
})
