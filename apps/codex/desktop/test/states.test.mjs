// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What main does (src/states.js): each event in each state, as the
// effects step answers.

import assert from "node:assert/strict"
import {test} from "node:test"

import {initial, step} from "../src/states.js"

const READY = "http://127.0.0.1:7340/bootstrap/#token=dG9rZW4"
const HOME = "https://cyfr.example.com"
const ACCOUNT = "https://cyfr.run"
const home = (h = HOME) => ({type: "home", message: {type: "home", home: h, account: ACCOUNT}})
const locked = (h = "") => ({type: "locked", message: h ? {type: "locked", home: h, account: ACCOUNT} : {type: "locked"}})

// The state after events from the start, and every effect on the way.
function run(events, accountRoad = false) {
  let s = initial(accountRoad)
  const effects = []
  for (const e of events) {
    const next = step(s, e)
    s = next.state
    effects.push(...next.do)
  }
  return {s, effects, kinds: effects.map((e) => Object.keys(e)[0])}
}

const ready = {type: "ready", url: READY}
// The content window's top frame given HOME, as the device's pages open it.
const given = {type: "navigate", window: "content", url: HOME + "/", target: "top", asker: "top", showing: READY}
const proposed = [ready, home()]
const open = [...proposed, {type: "opened", home: HOME}]

test("cyfr's ready shows the chooser; a second ready, or another first page, ends cyfr", () => {
  assert.deepEqual(run([ready]).s.name, "chooser")
  assert.ok(run([ready]).kinds.includes("chooser"))
  assert.equal(run([ready, ready]).s.name, "ended")
  assert.equal(run([{type: "ready", url: "https://evil.example/"}]).s.name, "ended")
})

test("a proposal is answered home-ready and replaced by the next until cyfr says it opened", () => {
  const {s, effects} = run(proposed)
  assert.equal(s.name, "proposed")
  assert.deepEqual(effects.at(-1), {send: {type: "home-ready", fields: {home: HOME}}})
  assert.equal(run([...proposed, home("https://bob.example")]).s.home, "https://bob.example", "after a failure")
  assert.equal(run(open).s.name, "open")
  assert.equal(run([...open, home("https://bob.example")]).s.name, "ended", "a proposal after a commit")
  assert.equal(run([...proposed, {type: "opened", home: "https://bob.example"}]).s.name, "ended")
  assert.equal(run([ready, {type: "opened", home: HOME}]).s.name, "ended", "opened with nothing proposed")
})

test("a home on another route starts the app again with it, closing and signing out first", () => {
  const rerouted = {type: "home", message: {type: "home", home: "https://bob.example", account: ACCOUNT,
    proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"}}
  const {s, effects} = run([...proposed, given, rerouted])
  assert.equal(s.name, "ended")
  assert.deepEqual(effects.slice(-3), [{close: true}, {retire: {held: true}},
    {relaunch: {proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"}}])
})

test("nothing loads and no window opens before ready", () => {
  const s = initial(false)
  for (const e of [{type: "navigate", window: "content", url: READY, target: "top", asker: "top", showing: ""},
    {type: "account-navigate", url: HOME + "/login", target: "top"}]) {
    assert.equal(step(s, e).allow, false, e.type)
  }
  assert.equal(step(s, {type: "open-window", url: "http://127.0.0.1:7340/confirm?ref=c"}).open, "deny")
})

test("a lock from any state closes the content first, then tells cyfr and signs out, and waits for both", () => {
  for (const before of [[ready], proposed, open]) {
    const {s, effects} = run([...before, {type: "lock", why: "lock-screen"}])
    assert.equal(s.name, "locking")
    const at = effects.findIndex((e) => e.say === "locked: lock-screen")
    assert.deepEqual(effects.slice(at + 1).map((e) => Object.keys(e)[0]), ["close", "send", "retire"])
    assert.deepEqual(effects[at + 2], {send: {type: "lock"}})
  }
  const waiting = run([...open, {type: "lock", why: "x"}, {type: "signed-out", confirmed: true}])
  assert.equal(waiting.s.name, "locking", "the sign-out alone does not end the lock")
  assert.ok(!waiting.kinds.slice(-1).includes("chooser"))
  const barrier = run([...open, {type: "lock", why: "x"}, locked(HOME)])
  assert.equal(barrier.s.name, "locking", "cyfr's locked alone does not end it")
})

test("the lock is a barrier: what cyfr sent before its locked is dropped, and its locked says what main keeps to", () => {
  // cyfr committed before it read the lock: opened and its locked were on
  // the pipe already. cyfr runs on and main keeps to what it committed.
  const committed = run([...proposed, {type: "lock", why: "lock-screen"}, {type: "opened", home: HOME}, locked(HOME),
    {type: "signed-out", confirmed: true}])
  assert.equal(committed.s.name, "open")
  assert.equal(committed.s.home, HOME)
  assert.ok(!committed.kinds.includes("end"))
  assert.deepEqual(committed.effects.at(-1), {chooser: []})
  const cancelled = run([...proposed, {type: "lock", why: "x"}, home(), locked(), {type: "signed-out", confirmed: true}])
  assert.equal(cancelled.s.name, "chooser")
  const unasked = run([ready, {type: "lock", why: "x"}, locked(HOME), {type: "signed-out", confirmed: true}])
  assert.equal(unasked.s.name, "chooser", "a locked naming a CYFR main kept to none before")
  assert.equal(unasked.s.home, "")
  const other = run([...open, {type: "lock", why: "x"}, locked("https://bob.example"), {type: "signed-out", confirmed: true}])
  assert.equal(other.s.name, "chooser", "a locked naming another CYFR")
  const own = run([ready, locked(HOME), {type: "signed-out", confirmed: true}])
  assert.equal(own.s.name, "chooser", "cyfr's own locked naming a CYFR main never kept to")
  assert.equal(cancelled.s.home, "")
  assert.equal(run([...proposed, {type: "lock", why: "x"}, locked(), {type: "signed-out", confirmed: true}, home()]).s.name, "proposed",
    "the next proposal after the lock")
})

test("cyfr's own locked is a lock whose barrier is passed: nothing is sent back", () => {
  const {s, kinds} = run([...open, locked(HOME)])
  assert.equal(s.name, "locking")
  assert.ok(!kinds.slice(kinds.indexOf("close")).includes("send"))
  assert.equal(run([...open, locked(HOME), {type: "signed-out", confirmed: true}]).s.name, "open")
})

test("an unconfirmed sign-out, and the company page, are said on the chooser", () => {
  assert.deepEqual(run([...open, {type: "lock", why: "x"}, locked(HOME), {type: "signed-out", confirmed: false}]).effects.at(-1),
    {chooser: ["unconfirmed"]})
  const company = run([...open, {type: "navigate", window: "content", url: HOME + "/company-login", target: "top", asker: "top",
    showing: HOME + "/login"}], true)
  assert.equal(company.s.name, "locking")
  assert.ok(company.kinds.includes("retire"), "the company page's lock signs the session out")
  assert.deepEqual(step(company.s, locked(HOME)).state.notices, ["company"])
})

test("cyfr's loss ends main from any state, closing first and signing out", () => {
  for (const before of [[], [ready], proposed, open, [...open, {type: "lock", why: "x"}]]) {
    const {s, kinds} = run([...before, {type: "gone", why: "it exited (1)"}])
    assert.equal(s.name, "ended")
    assert.deepEqual(kinds.slice(-3), ["close", "retire", "end"])
  }
  assert.deepEqual(run([...open, {type: "gone", why: "x"}, {type: "lock", why: "y"}, ready]).kinds.slice(-3), ["close", "retire", "end"],
    "nothing more once ended")
  assert.deepEqual(run([...open, {type: "gone", why: "x"}, {type: "quit"}]).effects.at(-1), {quit: true}, "but quitting, which goes")
})

test("quitting closes, signs out and quits, from any state", () => {
  for (const before of [[ready], proposed, open, [...open, {type: "lock", why: "x"}]]) {
    assert.deepEqual(run([...before, {type: "quit"}]).kinds.slice(-3), ["close", "retire", "quit"])
  }
})

test("the session is held from the moment the content window is given the CYFR, and then a lock signs it out", () => {
  assert.deepEqual(run([...open, given]).effects.at(-1), {hold: true})
  assert.equal(run([...open, given]).s.held, true)
  assert.equal(run([...open, {...given, url: READY}]).s.held, false, "the device's pages hold nothing")
  assert.equal(run([...open, {...given, target: "frame", asker: "top"}]).s.held, false, "a frame is not the window")
  // A lock before any page committed: the sign-out is tried, unconfirmed
  // without a token, and the storage cleared (app.js retire).
  const early = run([...open, given, {type: "lock", why: "lock-screen"}])
  assert.deepEqual(early.effects.at(-1), {retire: {held: true}})
  assert.deepEqual(run([...open, given, {type: "page", url: HOME + "/"}]).effects.at(-1), {token: true})
  assert.deepEqual(run([...open, {type: "page", url: HOME + "/"}]).effects, run(open).effects, "no token without the session held")
  assert.equal(run([...open, given, {type: "lock", why: "x"}, locked(HOME), {type: "signed-out", confirmed: false}]).s.held, false,
    "a new content window holds nothing yet")
})

test("a hop is the content window's top frame asking; a frame asking, or a confirmation window, is refused", () => {
  const nav = (over) => ({type: "navigate", window: "content", url: ACCOUNT + "/account/sign#x", target: "top", asker: "top",
    showing: HOME + "/login", ...over})
  const s = run(open, true).s
  assert.deepEqual(step(s, nav({})).do, [{hop: {url: ACCOUNT + "/account/sign#x", kind: "sign-in"}}])
  for (const refused of [{asker: "frame-inside"}, {asker: "frame-outside"}, {target: "frame"}, {window: "child"}, {asker: "none"}]) {
    const r = step(s, nav(refused))
    assert.equal(r.allow, false, JSON.stringify(refused))
    assert.deepEqual(r.do, [], JSON.stringify(refused))
  }
  const locking = step(s, {type: "lock", why: "x"}).state
  assert.equal(step(locking, nav({url: HOME + "/"})).allow, false, "nothing loads while locking")
})

test("the account window's top frame returns; its frames load nothing and end nothing", () => {
  const s = run(open, true).s
  const back = (kind) => step(s, {type: "account-navigate", url: HOME + "/login#a", target: "top", kind})
  assert.deepEqual(back("sign-in").do, [{unhop: true}, {hold: true}, {deliver: {url: HOME + "/login#a"}}])
  assert.deepEqual(back("confirmation").do, [{unhop: true}, {hold: true}, {confirmation: {url: HOME + "/login#a"}}])
  assert.equal(back("confirmation").state.returning, null, "a confirmation's answer reloads nothing")
  assert.deepEqual(back(null), {state: s, allow: false, do: [{unhop: true}]}, "no ceremony of the content window showing: nothing is delivered or held")
  assert.deepEqual(step(s, {type: "account-navigate", url: HOME + "/login#a", target: "frame"}), {state: s, allow: false, do: []})
  assert.deepEqual(step(s, {type: "account-navigate", url: HOME + "/", target: "top"}).do, [{unhop: true}])
})

const ANSWER = HOME + "/login#a"
const returned = [...open, {type: "account-navigate", url: ANSWER, target: "top", kind: "sign-in"}]
const ownStart = {type: "started", url: ANSWER, sameDocument: true}
const reloads = (events) => run([...returned, ...events], true).kinds.filter((k) => k === "reload").length

test("a sign-in's return reloads once, when the navigation main made for it lands as a change of fragment", () => {
  const landed = {type: "landed", url: ANSWER}
  assert.equal(reloads([ownStart, {type: "delivered"}, landed]), 1)
  assert.equal(reloads([ownStart, {type: "delivered"}, landed, ownStart, landed]), 1, "once")
})

test("every other outcome withdraws a sign-in's return, and no later landing at its address reloads", () => {
  const later = [ownStart, {type: "landed", url: ANSWER}]
  const landing = [ownStart, {type: "delivered"}]
  const outcomes = {
    "no navigation started within main's call": [{type: "delivered"}],
    "main's load started as a whole document": [{...ownStart, sameDocument: false}, {type: "delivered"}],
    "superseded by another address": [...landing, {type: "started", url: HOME + "/elsewhere", sameDocument: false}],
    "superseded by the same address": [...landing, ownStart],
    "a document committed": [...landing, {type: "committed"}],
    "the load failed": [...landing, {type: "load-failed"}],
    "main's load call ended before it landed": [...landing, {type: "load-ended", url: ANSWER}],
    "another fragment landed": [...landing, {type: "landed", url: HOME + "/login#b"}],
    "a lock": [...landing, {type: "lock", why: "lock-screen"}],
    "cyfr's own lock": [...landing, locked(HOME)],
    "the window gone": [...landing, {type: "quit"}],
    "cyfr gone": [...landing, {type: "gone", why: "it exited"}]
  }
  for (const [name, events] of Object.entries(outcomes)) {
    assert.equal(run([...returned, ...events], true).s.returning, null, name)
    assert.equal(reloads([...events, ...later]), 0, name)
  }
})

test("an earlier load call's end leaves the return on its way", () => {
  assert.equal(reloads([ownStart, {type: "delivered"}, {type: "load-ended", url: HOME + "/login#before"}, {type: "landed", url: ANSWER}]), 1)
})

test("before ready and while locking, a top-frame load in the account window is refused and ends any ceremony; a frame's ends nothing", () => {
  const states = {starting: initial(true), locking: run([...open, {type: "lock", why: "lock-screen"}], true).s}
  for (const [name, s] of Object.entries(states)) {
    for (const url of [ACCOUNT + "/account/sign", ANSWER, HOME + "/"]) {
      const at = {type: "account-navigate", url, kind: "sign-in"}
      assert.deepEqual(step(s, {...at, target: "top"}), {state: s, allow: false, do: [{unhop: true}]}, `${name}: ${url}`)
      assert.deepEqual(step(s, {...at, target: "frame"}), {state: s, allow: false, do: []}, `${name}, a frame: ${url}`)
    }
  }
})

const CHOOSER = "http://127.0.0.1:7340/bootstrap/#notice=unconfirmed"
const unconfirmedLock = [...open, given, {type: "lock", why: "lock-screen"}, {type: "signed-out", confirmed: false}, locked(HOME)]
const lockAgain = [{type: "lock", why: "suspend"}, {type: "signed-out", confirmed: true}, locked(HOME)]
const shownNotices = (events) => run(events).effects.filter((x) => x.chooser).at(-1).chooser

test("a lock over a chooser that is keeping a notice leaves the notice there", () => {
  assert.deepEqual(shownNotices([...unconfirmedLock, ...lockAgain]), ["unconfirmed"], "a second lock")
  assert.deepEqual(shownNotices([...unconfirmedLock, ...lockAgain, ...lockAgain]), ["unconfirmed"], "a third")
  assert.deepEqual(shownNotices([...unconfirmedLock, locked(HOME), {type: "signed-out", confirmed: true}]), ["unconfirmed"], "cyfr's own lock")
  assert.deepEqual(shownNotices([...unconfirmedLock, {type: "lock", why: "suspend"}, {type: "signed-out", confirmed: false}, locked(HOME)]),
    ["unconfirmed"], "unconfirmed again is said once")
  assert.deepEqual(shownNotices([...unconfirmedLock, {type: "lock", why: "x", notice: "company"}, {type: "signed-out", confirmed: true}, locked(HOME)]),
    ["unconfirmed", "company"], "another notice joins it")
})

test("only a way on taken from the chooser clears what it was keeping", () => {
  const from = (over) => ({type: "navigate", window: "content", url: "http://127.0.0.1:7340/", target: "top", asker: "top", showing: CHOOSER, ...over})
  for (const [name, way] of [["Use this computer's key", from({})], ["Sign in with your passkey", from({url: HOME + "/login"})]]) {
    assert.deepEqual(shownNotices([...unconfirmedLock, way, ...lockAgain]), [], name)
  }
  for (const [name, event] of [["a frame's load", from({target: "frame"})], ["a load refused", from({url: "https://evil.example/"})],
    ["a confirmation window's", from({window: "child"})], ["the chooser itself again", from({url: CHOOSER})],
    ["its page finishing", {type: "page", url: CHOOSER}], ["a second launch", {type: "second-instance"}]]) {
    assert.deepEqual(shownNotices([...unconfirmedLock, event, ...lockAgain]), ["unconfirmed"], name)
  }
})

test("a second launch shows the content window, and nothing once ended", () => {
  assert.deepEqual(step(run(open).s, {type: "second-instance"}).do, [{show: true}])
  assert.deepEqual(step(run([...open, {type: "quit"}]).s, {type: "second-instance"}).do, [])
})
