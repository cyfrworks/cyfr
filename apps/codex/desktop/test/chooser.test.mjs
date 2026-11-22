// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The chooser cyfr serves (internal/desktop/bootstrap.go): its own script,
// run over the elements its own page has. It stays while it has a notice to
// show, with its way on, and moves on by itself only when it has none.

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
const UNCONFIRMED = "CYFR locked, but the CYFR did not confirm that it signed this computer out. That sign-in ends when it expires, or when you sign it out under Settings, Keys on your account."
const PASSKEY = HOME + "/login"
const OPEN = {home: HOME, next: "/"}

// The chooser opened with `notice` while cyfr answers `state`: its
// elements, each as hidden as the page starts it, and where it went.
async function chooser(notice, state, connected = OPEN) {
  const elements = new Map()
  for (const [tag, id] of page.matchAll(/<[a-z0-9]+\b[^>]*\bid="([a-z]+)"[^>]*>/g)) {
    const listeners = {}
    elements.set(id, {hidden: /\shidden[\s>]/.test(tag), textContent: "", value: "", onclick: null,
      addEventListener: (type, f) => { listeners[type] = f },
      fire: (type) => listeners[type]?.({preventDefault() {}})})
  }
  const went = {byItself: [], pressed: []}
  const stored = new Map()
  vm.runInNewContext(script, {
    URLSearchParams,
    document: {getElementById: (id) => elements.get(id)},
    sessionStorage: {getItem: (k) => stored.get(k) ?? null, setItem: (k, v) => stored.set(k, v)},
    history: {replaceState() {}},
    location: {pathname: "/bootstrap/", hash: "#token=t" + (notice ? `&notice=${notice}` : ""),
      replace: (to) => went.byItself.push(to), assign: (to) => went.pressed.push(to)},
    fetch: async (path) => ({ok: true, json: async () => (path === "/bootstrap/state" ? state : connected)})
  })
  await settled()
  return {$: (id) => elements.get(id), went}
}

const settled = () => new Promise((resolve) => setImmediate(resolve))

test("with a notice to show the chooser stays, says it, and offers its way on to the device's pages", async () => {
  for (const [notice, words] of [["unconfirmed", UNCONFIRMED], ["company", COMPANY], ["company,unconfirmed", `${COMPANY} ${UNCONFIRMED}`]]) {
    const {$, went} = await chooser(notice, OPEN)
    assert.deepEqual(went.byItself, [], notice)
    assert.equal($("notice").textContent, words)
    assert.deepEqual([$("choose").hidden, $("road").hidden, $("words").hidden], [true, false, false], notice)
    assert.deepEqual([$("passkey").hidden, $("either").hidden], [true, true], "no passkey road where cyfr offers none")
    assert.equal($("open").textContent, HOME)
    $("words").onclick()
    assert.deepEqual(went.pressed, ["/"], "Use this computer's key goes on")
  }
})

test("with no notice to show the chooser moves on by itself", async () => {
  for (const notice of ["", "nothing-it-knows"]) {
    const {$, went} = await chooser(notice, OPEN)
    assert.deepEqual(went.byItself, ["/"], notice)
    assert.equal($("notice").textContent, "")
    assert.equal($("road").hidden, true, notice)
  }
})

test("on the passkey road the chooser stays with both ways on, a notice or none", async () => {
  for (const notice of ["", "unconfirmed"]) {
    const {$, went} = await chooser(notice, {...OPEN, passkey: PASSKEY})
    assert.deepEqual(went.byItself, [], notice)
    assert.deepEqual([$("road").hidden, $("passkey").hidden, $("either").hidden], [false, false, false], notice)
    assert.equal($("notice").textContent, notice ? UNCONFIRMED : "")
    $("passkey").onclick()
    assert.deepEqual(went.pressed, [PASSKEY])
  }
})

test("with no CYFR open a notice shows on Connect, and a Connect the person makes goes on", async () => {
  const {$, went} = await chooser("unconfirmed", {})
  assert.deepEqual([$("choose").hidden, $("road").hidden], [false, true])
  assert.equal($("notice").textContent, UNCONFIRMED)
  assert.deepEqual(went.byItself, [])
  $("connect").fire("submit")
  await settled()
  assert.deepEqual(went.byItself, ["/"])
})

test("an answer that is an error says the error and goes nowhere", async () => {
  const {$, went} = await chooser("unconfirmed", {error: "The record could not be read."})
  assert.equal($("notice").textContent, "The record could not be read.")
  assert.deepEqual(went.byItself, [])
})
