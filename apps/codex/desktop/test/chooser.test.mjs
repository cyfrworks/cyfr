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

import {initial, step} from "../src/states.js"

const source = readFileSync(new URL("../../internal/desktop/bootstrap.go", import.meta.url), "utf8")
const script = /bootstrapScript = `([^`]*)`/.exec(source)?.[1]
const page = /const bootstrapPage = `([\s\S]*)/.exec(source)?.[1]
assert.ok(script && page, "bootstrap.go's script and page")

const HOME = "https://cyfr.example.com"
const COMPANY = "This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet."
const PASSKEY = HOME + "/login"
const UNCLEARED = "The app could not clear the sign-in it kept on this computer, so it opened no other CYFR: try again."
const UNFORGOTTEN = "The app locked, and could not clear the sign-in it kept on this computer. To clear it, press Connect to another CYFR, which clears it first."
const OPEN = {home: HOME, next: "/"}
// The passkey road, as main says it in the chooser's address.
const ROAD = "#token=t&road=passkey"

// The chooser opened with `notice` while cyfr answers `state`: its
// elements, each as hidden as the page starts it, and where it went. Its
// document came by a navigation of `type`, at an entry of the history that
// holds `saved`; the tab holds the run token, as it does once main's first
// load ran, and cyfr refuses any other.
async function chooser(notice, state, connected = OPEN, hash = "#token=t" + (notice ? `&notice=${notice}` : ""),
  {type = "navigate", saved = null} = {}) {
  const elements = new Map()
  for (const [tag, id] of page.matchAll(/<[a-z0-9]+\b[^>]*\bid="([a-z]+)"[^>]*>/g)) {
    const listeners = {}
    elements.set(id, {hidden: /\shidden[\s>]/.test(tag), textContent: "", value: "", onclick: null,
      addEventListener: (type, f) => { listeners[type] = f },
      fire: (type) => listeners[type]?.({preventDefault() {}})})
  }
  const went = {byItself: [], pressed: [], asked: []}
  const stored = new Map([["token", "t"]])
  went.stored = stored
  vm.runInNewContext(script, {
    URLSearchParams,
    document: {getElementById: (id) => elements.get(id)},
    sessionStorage: {getItem: (k) => stored.get(k) ?? null, setItem: (k, v) => stored.set(k, v)},
    history: {state: saved, replaceState: (entry, _title, to) => { went.entry = entry; went.address = to }},
    performance: {getEntriesByType: () => [{type}]},
    location: {pathname: "/bootstrap/", hash,
      replace: (to) => went.byItself.push(to), assign: (to) => went.pressed.push(to)},
    fetch: async (path, init) => {
      const {token, ...body} = JSON.parse(init.body)
      if (token !== "t") return {ok: false}
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
// The chooser that `went` showed, reloaded.
const reload = (went) => chooser("", OPEN, OPEN, new URL(went.address, "http://127.0.0.1:7340").hash,
  {type: "reload", saved: went.entry})

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
  const again = await reload(first.went)
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

const UNANSWERED = `The CYFR at ${HOME} did not answer.`

test("a chooser told that the CYFR did not answer names it and offers it again", async () => {
  const keys = await chooser("", OPEN, OPEN, ROAD + "&notice=unanswered")
  assert.deepEqual(keys.went.byItself, [])
  assert.equal(keys.$("notice").textContent, UNANSWERED)
  assert.deepEqual([keys.$("road").hidden, keys.$("again").hidden, keys.$("passkey").hidden], [false, false, false])
  assert.deepEqual(keys.went.asked, [], "it connects nothing by itself")
  keys.$("again").onclick()
  assert.deepEqual(keys.went.pressed, [], "not before the CYFR answered")
  await settled()
  assert.deepEqual(keys.went.asked, [["/bootstrap/connect", {address: HOME}]], "the press asks, as the passkey's way on does")
  assert.deepEqual(keys.went.pressed, ["/bootstrap/again"], "main's to open")

  const words = await chooser("unanswered", OPEN)
  assert.deepEqual(words.went.byItself, [], "it stays to say so")
  assert.equal(words.$("notice").textContent, UNANSWERED)
  assert.deepEqual([words.$("road").hidden, words.$("again").hidden, words.$("words").hidden], [false, true, false])
  words.$("words").onclick()
  assert.deepEqual(words.went.pressed, ["/"], "the device's pages, which offer it")
})

test("Try again loads nothing until a Connect at that CYFR answered with a way on", async () => {
  const local = {home: "http://localhost:4000", next: "/"}
  for (const said of [{home: local.home, error: "The CYFR in /srv/cyfr does not answer."}, {error: "CYFR locked. Connect again."}]) {
    const {$, went} = await chooser("", local, said, ROAD + "&notice=unanswered")
    $("again").onclick()
    await settled()
    assert.deepEqual([went.byItself, went.pressed], [[], []], said.error)
    assert.deepEqual(went.asked, [["/bootstrap/connect", {address: local.home}]])
    assert.equal($("notice").textContent, said.error)
    assert.deepEqual([$("road").hidden, $("again").hidden, $("words").hidden], [false, false, false], "every way on stays")
  }
})

test("Try again shows only where main says the CYFR did not answer, and after a reload there", async () => {
  for (const notice of ["", "company", "uncleared"]) {
    const {$} = await chooser("", OPEN, OPEN, ROAD + (notice ? `&notice=${notice}` : ""))
    assert.equal($("again").hidden, true, notice)
  }
  const first = await chooser("", OPEN, OPEN, ROAD + "&notice=unanswered")
  const again = await reload(first.went)
  assert.deepEqual([again.$("again").hidden, again.$("notice").textContent], [false, UNANSWERED])
})

test("a reload and the history keep the road main said, and the address keeps nothing", async () => {
  const first = await chooser("", OPEN, OPEN, ROAD)
  assert.equal(first.went.address, "/bootstrap/")
  for (const type of ["reload", "back_forward"]) {
    const again = await chooser("", OPEN, OPEN, "", {type, saved: first.went.entry})
    assert.equal(again.$("passkey").hidden, false, type)
  }
  const said = await chooser("", OPEN, OPEN, "#road=passkey")
  assert.deepEqual(said.went.byItself, ["/"], "an address without main's token says no road")
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

// ---- what the chooser says on main's behalf is main's alone to decide ----

const ACCOUNT = "https://cyfr.run"
const LOOPBACK = "http://127.0.0.1:7340"
const CHOOSER = LOOPBACK + "/bootstrap/"
const at = (url, showing, over = {}) => ({type: "navigate", window: "content", url, target: "top", asker: "top", showing, by: showing, ...over})
const open = [{type: "ready", url: CHOOSER + "#token=t"},
  {type: "home", message: {type: "home", home: HOME, account: ACCOUNT, attempt: 1}},
  {type: "taken", taken: true}, {type: "opened", home: HOME}]
const locked = {type: "locked", message: {type: "locked", home: HOME, account: ACCOUNT}}

// Every notice, by name: its words, and what main observed that makes it
// load the chooser with it.
const NOTICES = {
  company: {words: COMPANY, observed: [at(HOME + "/company-login", HOME + "/login"), locked]},
  uncleared: {words: UNCLEARED, observed: [at(CHOOSER + "another", CHOOSER), {type: "forgot", cleared: false}, locked]},
  unforgotten: {words: UNFORGOTTEN, observed: [locked, {type: "forgot", cleared: false}]},
  unanswered: {words: UNANSWERED, observed: [{type: "load-failed", code: -106, url: HOME + "/threads"}]}
}

// Every way a load of the chooser can begin that is not main's, as main is
// asked about it.
const PAGES_WAYS = {
  "a navigation of the CYFR's page": (url) => at(url, HOME + "/threads"),
  "a navigation of the device's pages": (url) => at(url, LOOPBACK + "/"),
  "a navigation of the chooser's own page": (url) => at(url, CHOOSER),
  "a navigation no frame began": (url) => at(url, HOME + "/threads", {asker: "none", by: ""}),
  "a redirect of the CYFR's": (url) => at(url, HOME + "/threads", {redirect: true}),
  "a redirect of main's own load": (url) => at(url, CHOOSER, {redirect: true, asker: "none", by: ""}),
  "a frame's own": (url) => at(url, HOME + "/threads", {target: "frame", asker: "frame-inside", by: ""}),
  "the page's, of a frame": (url) => at(url, HOME + "/threads", {target: "frame"}),
  "a frame's, of the page": (url) => at(url, HOME + "/threads", {asker: "frame-inside", by: ""}),
  "a frame's redirect": (url) => at(url, HOME + "/threads", {target: "frame", redirect: true}),
  "a new window": (url) => ({type: "open-window", url}),
  "a confirmation window's navigation": (url) => at(url, LOOPBACK + "/confirm?ref=c", {window: "child"}),
  "a confirmation window's redirect": (url) => at(url, LOOPBACK + "/confirm?ref=c", {window: "child", redirect: true}),
  "a confirmation window's frame": (url) => at(url, LOOPBACK + "/confirm?ref=c", {window: "child", target: "frame"}),
  "the account window's navigation": (url) => ({...at(url, ACCOUNT + "/account/sign"), type: "account-navigate", window: "account"})
}

// The chooser's address as a page can write it: it has no run token.
const written = (notice) => [CHOOSER, CHOOSER + "?x=1", LOOPBACK + "/%62ootstrap/", LOOPBACK + "/%2Fbootstrap/../bootstrap/",
  LOOPBACK + "/bootstrap%2F", LOOPBACK + "/x/../bootstrap/", "http://2130706433:7340/bootstrap/"]
  .flatMap((base) => ["", "token=&", "token=a-guess&"].map((token) => `${base}#${token}road=passkey&notice=${notice}`))

test("every notice the chooser has is in this table", () => {
  const all = vm.runInNewContext(`(${/const notices=(\{[^;]*\});/.exec(script)[1]})`)
  assert.deepEqual(Object.keys(NOTICES).sort(), Object.keys(all).sort())
})

test("every notice against every way a load of the chooser can begin: main's alone shows it", async () => {
  for (const [notice, {words, observed}] of Object.entries(NOTICES)) {
    let s = initial(true)
    const effects = []
    for (const e of [...open, ...observed]) {
      const r = step(s, e)
      s = r.state
      effects.push(...r.do)
    }
    const load = effects.filter((e) => e.chooser || e.back).at(-1)
    const told = load.chooser ?? load.back
    assert.deepEqual([...told], [notice], "main loads the chooser with it for what it observed")
    const mains = await chooser("", OPEN, OPEN, `#token=t&road=passkey&notice=${told.join(",")}`)
    assert.equal(mains.$("notice").textContent, words, `${notice}: main's load`)

    for (const road of [true, false]) {
      let o = initial(road)
      for (const e of open) o = step(o, e).state
      for (const state of [o, {...o, notices: [notice]}, step(initial(road), open[0]).state]) {
        for (const [way, event] of Object.entries(PAGES_WAYS)) {
          for (const url of written(notice)) {
            const r = step(state, event(url))
            assert.ok(r.open === "deny" || r.allow === false, `${notice}: ${way} to ${url} is refused`)
            assert.deepEqual(r.do.filter((e) => e.chooser || e.back || e.root), [], `${notice}: ${way} has main load nothing`)
          }
        }
      }
    }

    // A document of the chooser that main's load did not make, which the
    // history can bring, says nothing on main's behalf, whatever its
    // address says.
    const saved = mains.went.entry
    for (const token of ["", "token=&", "token=a-guess&"]) {
      for (const [type, entry] of [["navigate", null], ["navigate", saved], ["back_forward", saved], ["reload", null]]) {
        const {$} = await chooser("", OPEN, OPEN, `#${token}road=passkey&notice=${notice}`, {type, saved: entry})
        assert.ok(!$("notice").textContent.includes(words), `${notice}: ${type}, ${token}`)
        assert.equal($("again").hidden, true, `${notice}: ${type}, ${token}: no Try again`)
      }
    }
    const back = await chooser("", OPEN, OPEN, "", {type: "back_forward", saved})
    assert.equal((await reload(back.went)).$("notice").textContent, "", `${notice}: a reload after the history brought it back`)
    assert.equal((await reload(mains.went)).$("notice").textContent, words, `${notice}: main's load, reloaded`)
  }
})
