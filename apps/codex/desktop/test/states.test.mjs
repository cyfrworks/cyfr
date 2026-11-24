// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What main does (src/states.js): each event in each state, as the
// effects step answers.

import assert from "node:assert/strict"
import {test} from "node:test"

import {readFileSync} from "node:fs"

import {ACTS, EXTERNAL, initial, step} from "../src/states.js"

const READY = "http://127.0.0.1:7340/bootstrap/#token=dG9rZW4"
const HOME = "https://cyfr.example.com"
const ACCOUNT = "https://cyfr.run"
const home = (h = HOME, attempt = 1) => ({type: "home", message: {type: "home", home: h, account: ACCOUNT, attempt}})
// cyfr's left answering the leave numbered id.
const leftOf = (id) => ({type: "left", message: {type: "left", id}})
// cyfr's opened of h, the proposal numbered attempt.
const openedAt = (h = HOME, attempt = 1) => ({type: "opened", home: h, message: {type: "opened", home: h, attempt}})
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
// Begun by the document showing, unless `over` says another began it.
const navigate = (over) => ({type: "navigate", window: "content", url: HOME + "/", target: "top", asker: "top", showing: READY,
  by: over.showing ?? READY, ...over})
// The account window's top-frame load, begun by the account's own page.
const accountNavigate = (over) => ({type: "account-navigate", window: "account", target: "top", asker: "top",
  by: ACCOUNT + "/account/sign#x", ...over})
// The content window's top frame given HOME, as the device's pages open it.
const given = navigate({})
// What main locks for: the company page, on either road, and being sent to
// sign in, on the passkey road.
const company = navigate({url: HOME + "/company-login", showing: HOME + "/login"})
const signedOut = navigate({url: HOME + "/login?error=signed_out", showing: HOME + "/threads", redirect: true})
const forgot = {type: "forgot", cleared: true}
const notForgot = {type: "forgot", cleared: false}
const taken = {type: "taken", taken: true}
const notTaken = {type: "taken", taken: false}
const proposed = [ready, home(), taken]
const open = [...proposed, openedAt(HOME)]

test("cyfr's ready shows the chooser; a second ready, or another first page, ends cyfr", () => {
  assert.deepEqual(run([ready]).s.name, "chooser")
  assert.ok(run([ready]).kinds.includes("chooser"))
  assert.equal(run([ready, ready]).s.name, "ended")
  assert.equal(run([{type: "ready", url: "https://evil.example/"}]).s.name, "ended")
})

test("a proposal is answered home-ready and replaced by the next until cyfr says it opened", () => {
  const {s, effects} = run(proposed)
  assert.equal(s.name, "proposed")
  assert.deepEqual(effects.at(-1), {send: {type: "home-ready", fields: {home: HOME, attempt: 1}}})
  assert.equal(run([...proposed, home("https://bob.example", 2), taken]).s.home, "https://bob.example", "after a failure")
  assert.equal(run(open).s.name, "open")
  assert.equal(run([...open, home("https://bob.example")]).s.name, "ended", "a proposal after a commit")
  assert.equal(run([...proposed, openedAt("https://bob.example")]).s.name, "ended")
  assert.equal(run([...proposed, openedAt(HOME, 2)]).s.name, "ended", "an opened of another attempt")
  assert.equal(run([ready, openedAt(HOME)]).s.name, "ended", "opened with nothing proposed")
})

test("a home on another route starts the app again with it, closing first and forgetting nothing", () => {
  const rerouted = {type: "home", message: {type: "home", home: "https://bob.example", account: ACCOUNT,
    proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"}}
  const {s, effects} = run([...proposed, given, rerouted])
  assert.equal(s.name, "ended")
  assert.deepEqual(effects.slice(-2), [{close: true},
    {relaunch: {proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"}}])
  assert.ok(!effects.some((e) => e.forget))
})

test("nothing loads and no window opens before ready", () => {
  const s = initial(false)
  for (const e of [{type: "navigate", window: "content", url: READY, target: "top", asker: "top", showing: ""},
    {type: "account-navigate", url: HOME + "/login", target: "top"}]) {
    assert.equal(step(s, e).allow, false, e.type)
  }
  assert.equal(step(s, {type: "open-window", url: "http://127.0.0.1:7340/confirm?ref=c"}).open, "deny")
})

test("the computer's lock and sleep are no events of main's, which locks for neither", () => {
  for (const before of [[ready], proposed, open]) {
    for (const type of ["lock", "lock-screen", "suspend"]) {
      assert.deepEqual(run([...before, {type, why: type}], true), run(before, true), type)
    }
  }
})

test("main's own lock closes the content first, then tells cyfr, waits for its locked and forgets nothing", () => {
  for (const [road, event, why] of [[false, company, "company sign-in"], [true, company, "company sign-in"], [true, signedOut, "sign-in"]]) {
    const waiting = step(run(proposed, road).s, event)
    assert.equal(waiting.allow, false, `${why}: nothing of a CYFR not yet open`)
    assert.deepEqual(waiting.do, [], `${why}: and so no lock of it`)
    for (const before of [open]) {
      const locking = run([...before, event], road)
      assert.equal(locking.s.name, "locking", why)
      const at = locking.kinds.lastIndexOf("say")
      assert.match(locking.effects[at].say, new RegExp(`^locked: the CYFR asks for a ${why}$`))
      assert.deepEqual(locking.effects.slice(at + 1), [{close: true}, {send: {type: "lock"}}])
      assert.equal(step(locking.s, given).allow, false, "nothing loads while locking")
      assert.deepEqual(run([...before, event, forgot], road).s.name, "locking", "only cyfr's locked ends it")
      const past = run([...before, event, locked(HOME)], road)
      assert.equal(past.s.name, "open", why)
      assert.ok("chooser" in past.effects.at(-1), why)
      assert.ok(!past.kinds.includes("forget"), why)
    }
  }
})

test("cyfr's own locked is the device's session ending: forgotten, with nothing sent back, before the chooser shows", () => {
  for (const road of [false, true]) {
    for (const before of [[ready], proposed, open]) {
      const locking = run([...before, locked(HOME)], road)
      assert.equal(locking.s.name, "locking")
      assert.deepEqual(locking.effects.slice(-3), [{say: "locked: the device locked"}, {close: true}, {forget: true}])
      assert.equal(run([...before, locked(HOME), locked(HOME)], road).s.name, "locking", "the chooser waits for what is forgotten")
      assert.deepEqual(run([...before, locked(HOME), forgot], road).effects.at(-1), {chooser: []})
    }
  }
  assert.equal(run([...open, locked(HOME), forgot]).s.name, "open")
  assert.equal(run([...open, locked(), forgot]).s.name, "chooser", "Connect to another CYFR: a locked naming none")
})

test("the lock is a barrier: what cyfr sent before its locked is dropped, and its locked says what main keeps to", () => {
  // What was on the pipe before cyfr read main's lock is dropped: cyfr
  // runs on and main keeps to what it committed.
  const committed = run([...open, company, home("https://bob.example", 2), openedAt(HOME), locked(HOME)])
  assert.equal(committed.s.name, "open")
  assert.equal(committed.s.home, HOME)
  assert.ok(!committed.kinds.includes("end"))
  assert.deepEqual(committed.effects.at(-1), {chooser: ["company"]})
  const cancelled = run([...proposed, locked(), home(), openedAt(HOME), forgot])
  assert.equal(cancelled.s.name, "chooser")
  assert.equal(cancelled.s.home, "")
  const other = run([...open, company, locked("https://bob.example")])
  assert.equal(other.s.name, "chooser", "a locked naming another CYFR")
  const own = run([ready, locked(HOME), forgot])
  assert.equal(own.s.name, "chooser", "cyfr's own locked naming a CYFR main never kept to")
  assert.equal(own.s.home, "")
  assert.equal(run([...proposed, locked(), forgot, home(HOME, 2), taken]).s.name, "proposed", "the next proposal after the lock")
})

test("on the passkey road the content sent to the CYFR's sign-in page locks and shows both ways on", () => {
  for (const [name, over] of [
    ["signing out in Prism", {}],
    ["a kept sign-in that is over, as the app opens it", {url: HOME + "/login", showing: "http://127.0.0.1:7340/bootstrap/"}],
    ["one of the CYFR's pages going there", {url: HOME + "/login", redirect: false}]]) {
    const at = {...signedOut, ...over, by: over.showing ?? signedOut.by}
    const r = step(run(open, true).s, at)
    assert.equal(r.allow, false, name)
    assert.deepEqual(r.do.slice(1), [{close: true}, {send: {type: "lock"}}], name)
    assert.deepEqual(run([...open, at, locked(HOME)], true).effects.at(-1), {chooser: []}, name)
  }
})

test("the sign-in page as a way on, its own loads, and the six-word road are never sent to sign in", () => {
  const login = HOME + "/login"
  for (const [name, road, over, allow] of [
    ["the chooser's passkey", true, {url: login, showing: "http://127.0.0.1:7340/bootstrap/", redirect: false}, true],
    ["the sign-in page loading itself", true, {url: login, showing: login, redirect: false}, true],
    ["the sign-in page's redirect to itself", true, {url: login + "?error=refused", showing: login}, true],
    ["the six-word road", false, {}, true],
    ["a page that is not the sign-in", true, {url: HOME + "/login/else"}, true],
    ["a frame's load", true, {target: "frame", asker: "frame-inside"}],
    ["a frame asking the top frame", true, {asker: "frame-outside"}, false],
    ["a confirmation window", true, {window: "child"}]]) {
    const r = step(run(open, road).s, {...signedOut, ...over, by: over.showing ?? signedOut.by})
    assert.equal(r.state.name, "open", name)
    assert.ok(!r.do.some((e) => e.close || e.send), name)
    if (allow !== undefined) assert.equal(r.allow, allow, name)
  }
})

test("main keeps to a CYFR only once the kept storage is its own and cyfr opened it, whichever road", () => {
  for (const road of [false, true]) {
    const waiting = run([ready, home()], road)
    assert.deepEqual(waiting.effects.at(-1), {take: true})
    assert.ok(!waiting.effects.some((e) => e.send), "no home-ready before it is its own")
    for (const url of [HOME + "/", HOME + "/login", HOME + "/auth/device/complete/x"]) {
      assert.equal(step(waiting.s, navigate({url})).allow, false, url)
    }
    assert.equal(step(waiting.s, navigate({url: HOME + "/", target: "frame", asker: "frame-inside"})).allow, false, "nor a frame")
    const own = step(waiting.s, taken)
    assert.deepEqual(own.do, [{send: {type: "home-ready", fields: {home: HOME, attempt: 1}}}])
    assert.equal(step(own.state, given).allow, false, "nothing of it loads before it is open")
    assert.equal(step(own.state, navigate({target: "frame", asker: "frame-inside"})).allow, false, "nor a frame")
    assert.equal(step(step(own.state, openedAt(HOME)).state, given).allow, true)
  }
})

test("a proposal during a take only replaces what is wanted, and the current number alone is answered", () => {
  const bob = "https://bob.example"
  for (const [answer, type, state] of [[taken, "home-ready", "proposed"], [notTaken, "home-failed", "chooser"]]) {
    const over = run([ready, home(HOME, 1), home(bob, 2), home(HOME, 3)], true)
    assert.equal(over.kinds.filter((k) => k === "take").length, 1, "one take in flight")
    assert.ok(!over.effects.some((e) => e.send), "and nobody answered")
    const ended = step(over.s, answer)
    assert.equal(ended.state.name, state, type)
    assert.deepEqual(ended.do.filter((e) => e.send), [{send: {type, fields: {home: HOME, attempt: 3}}}], type)
    assert.deepEqual(step(ended.state, answer), {state: ended.state, do: []}, "answered once")
  }
  const next = run([...proposed, home(bob, 2)], true)
  assert.equal(next.kinds.filter((k) => k === "take").length, 2, "a proposal after a take ended takes again")
})

test("a kept storage that could not be made the CYFR's loads nothing of it and fails that attempt alone, with no lock", () => {
  const refused = run([ready, home(HOME, 7), notTaken], true)
  assert.equal(refused.s.name, "chooser")
  assert.equal(refused.s.home, "", "main keeps to none")
  assert.deepEqual(refused.effects.at(-1), {send: {type: "home-failed", fields: {home: HOME, attempt: 7}}})
  assert.ok(!refused.effects.some((e) => e.send?.type === "home-ready" || e.send?.type === "lock" || e.close || e.root))
  assert.equal(step(refused.s, given).allow, false)
})

test("main alone opens a CYFR committed at its root, on the passkey road, and the notices are told by then", () => {
  assert.deepEqual(run(open, true).effects.at(-1), {root: {home: HOME}})
  assert.ok(!run(open, false).effects.some((e) => e.root))
  const told = run([...open, company, locked()], true)
  assert.deepEqual(told.s.notices, ["company"])
  assert.deepEqual(run([...open, company, locked(), home(), taken, openedAt(HOME)], true).s.notices, [])
})

test("a CYFR that opens at the device's pages loads none of its own on the passkey road, and the next home without that road does", () => {
  const device = {type: "home", message: {...home().message, road: "device"}}
  const opened = run([ready, device, taken, openedAt(HOME)], true)
  assert.equal(opened.s.name, "open")
  assert.ok(!opened.effects.some((e) => e.root), "no root loaded")
  assert.equal(step(opened.s, given).allow, true, "the device's pages give the CYFR")
  const again = run([ready, device, taken, openedAt(HOME), locked(), forgot, home(), taken, openedAt(HOME)], true)
  assert.deepEqual(again.effects.filter((e) => e.root), [{root: {home: HOME}}], "a home on the passkey road again")
})

const atWays = "http://127.0.0.1:7340/bootstrap/#road=passkey"
const another = navigate({url: "http://127.0.0.1:7340/bootstrap/another", showing: atWays})

test("Connect to another CYFR clears first and only then tells cyfr to leave", () => {
  const clearing = run([...open, another], true)
  assert.equal(clearing.s.name, "locking")
  assert.deepEqual(clearing.effects.slice(-2), [{close: true}, {forget: true}])
  assert.ok(!clearing.effects.some((e) => ["leave", "lock"].includes(e.send?.type)), "cyfr is told nothing before the clear")
  assert.deepEqual(run([...open, another, forgot], true).effects.at(-1), {send: {type: "leave", fields: {id: 1}}})
  const left = run([...open, another, forgot, locked(), leftOf(1)], true)
  assert.equal(left.s.name, "chooser")
  assert.deepEqual(left.effects.at(-1), {chooser: []})
  const own = run([...open, another, locked(HOME), forgot], true)
  assert.equal(own.s.name, "locking", "a lock of cyfr's own meanwhile does not stand for its answer")
  assert.equal(run([...open, another, locked(HOME), forgot, locked(), leftOf(1)], true).s.name, "chooser")
})

test("a departure ends at the left of its own id alone, and the next is numbered after it", () => {
  const waiting = [...open, another, forgot]
  for (const [what, events] of Object.entries({
    "the lock's locked": [locked()],
    "an unasked locked naming the CYFR": [locked(HOME)],
    "a left of another id": [leftOf(2)],
    "a left of none": [{type: "left", message: {type: "left"}}],
  })) {
    assert.equal(run([...waiting, ...events], true).s.name, "locking", what)
  }
  const done = run([...waiting, locked(), leftOf(1)], true)
  assert.equal(done.s.name, "chooser")
  assert.deepEqual(run([...waiting, leftOf(1), leftOf(1)], true).s.name, "chooser", "a duplicate left does nothing")
  assert.equal(run([...open, leftOf(1)], true).s.name, "open", "a left with no departure does nothing")
  const second = run([...waiting, leftOf(1), home(), taken, openedAt(), another, forgot], true)
  assert.deepEqual(second.effects.at(-1), {send: {type: "leave", fields: {id: 2}}})
  assert.equal(run([...waiting, leftOf(1), home(), taken, openedAt(), another, forgot, leftOf(1)], true).s.name, "locking",
    "the first departure's left, late, ends no second")
})

test("Connect to another CYFR does not advance past a failed clear", () => {
  assert.deepEqual(run([...open, another, notForgot], true).effects.at(-1), {send: {type: "lock"}}, "cyfr is never told to leave")
  const stayed = run([...open, another, notForgot, locked(HOME)], true)
  assert.equal(stayed.s.name, "open")
  assert.equal(stayed.s.home, HOME)
  assert.deepEqual(stayed.effects.at(-1), {chooser: ["uncleared"]})
  assert.deepEqual(run([...open, company, locked(HOME), another, notForgot, locked(HOME)], true).effects.at(-1),
    {chooser: ["company", "uncleared"]}, "beside what it was keeping")
})

test("only the chooser's own button on the passkey road leaves a CYFR", () => {
  for (const [name, road, before, over] of [
    ["the six-word road", false, open, {}],
    ["a CYFR's page", true, open, {showing: HOME + "/threads"}],
    ["a device's page", true, open, {showing: "http://127.0.0.1:7340/"}],
    ["a frame asking the top frame", true, open, {asker: "frame-outside"}],
    ["an asker the engine does not name", true, open, {asker: "none"}],
    ["a confirmation window", true, open, {window: "child"}],
    ["no CYFR open", true, [ready], {}]]) {
    const r = step(run(before, road).s, {...another, ...over, by: over.showing ?? another.by})
    assert.equal(r.allow, false, name)
    assert.deepEqual(r.do, [], name)
  }
})

test("a lock's forgetting that failed says that, and never another CYFR's words", () => {
  assert.deepEqual(run([...open, locked(HOME), notForgot], true).effects.at(-1), {chooser: ["unforgotten"]})
})

test("a lost page is shown again and locks nothing", () => {
  for (const road of [false, true]) {
    const s = run(open, road).s
    assert.deepEqual(step(s, {type: "lost"}), {state: s, do: [{reload: true}]})
  }
})

test("cyfr's loss ends main from any state, closing first, and signs nobody out", () => {
  for (const before of [[], [ready], proposed, open, [...open, company]]) {
    const {s, kinds} = run([...before, {type: "gone", why: "it exited (1)"}], true)
    assert.equal(s.name, "ended")
    assert.deepEqual(kinds.slice(-2), ["close", "end"])
    assert.ok(!kinds.includes("forget"))
  }
  assert.deepEqual(run([...open, {type: "gone", why: "x"}, company, ready, locked(HOME)]).kinds.slice(-2), ["close", "end"],
    "nothing more once ended, a lock neither")
  assert.deepEqual(run([...open, {type: "gone", why: "x"}, {type: "quit"}]).effects.at(-1), {quit: true}, "but quitting, which goes")
})

test("the screen shell's ending closes at once and quits, settling no lock, so nothing opens after it", () => {
  const screen = (events) => {
    let st = initial(false, {proxy: "", resolver: ""}, "/home/alice/cyfr")
    const effects = []
    for (const e of events) {
      const next = step(st, e)
      st = next.state
      effects.push(...next.do)
    }
    return {s: st, effects}
  }
  const LOOP = {type: "ready", url: "http://127.0.0.1:7340/"}
  const LOCAL = "http://localhost:4000"
  const mine = (attempt) => ({type: "home", message: {type: "home", home: LOCAL, account: LOCAL, attempt}})
  const shown = [LOOP, mine(1), taken, openedAt(LOCAL)]
  const ending = {type: "ending", message: {type: "ending"}}
  for (const [name, before] of Object.entries({"open": shown, "locking, the forget still running": [...shown, locked()],
    "locking, its proposal wanted": [...shown, locked(), mine(2)], "taking": [LOOP, mine(1)], "at the device's page": [LOOP]})) {
    const {s, effects} = screen([...before, ending])
    const last = effects.slice(-2)
    assert.equal(s.name, "ended", name)
    assert.deepEqual(last, [{close: true}, {say: "cyfr ended: the screen shell is ending", quit: true}], name)
    const after = screen([...before, ending, forgot, taken, mine(3), locked(), {type: "gone", why: "it exited (0)"}])
    assert.deepEqual(after.effects.slice(effects.length), [], `${name}: nothing after the ending`)
  }
})

test("quitting closes and quits, from any state, and signs nobody out", () => {
  for (const before of [[ready], proposed, open, [...open, company]]) {
    const {kinds} = run([...before, {type: "quit"}], true)
    assert.deepEqual(kinds.slice(-2), ["close", "quit"])
    assert.ok(!kinds.includes("forget"))
  }
})

test("a hop is the content window's top frame asking; a frame asking, or a confirmation window, is refused", () => {
  const nav = (over) => ({type: "navigate", window: "content", url: ACCOUNT + "/account/sign#x", target: "top", asker: "top",
    showing: HOME + "/login", by: HOME + "/login", ...over})
  const s = run(open, true).s
  assert.deepEqual(step(s, nav({})).do, [{hop: {url: ACCOUNT + "/account/sign#x", kind: "sign-in"}}])
  for (const refused of [{asker: "frame-inside"}, {asker: "frame-outside"}, {target: "frame"}, {window: "child"}, {asker: "none"}]) {
    const r = step(s, nav(refused))
    assert.equal(r.allow, false, JSON.stringify(refused))
    assert.deepEqual(r.do, [], JSON.stringify(refused))
  }
  const locking = step(s, company).state
  assert.equal(step(locking, nav({url: HOME + "/"})).allow, false, "nothing loads while locking")
})

test("the account window's top frame returns; its frames load nothing and end nothing", () => {
  const s = run(open, true).s
  const back = (kind) => step(s, accountNavigate({url: HOME + "/login#a", kind}))
  assert.deepEqual(back("sign-in").do, [{unhop: true}, {deliver: {url: HOME + "/login#a"}}])
  assert.deepEqual(back("confirmation").do, [{unhop: true}, {confirmation: {url: HOME + "/login#a"}}])
  assert.equal(back("confirmation").state.returning, null, "a confirmation's answer reloads nothing")
  assert.deepEqual(back(null), {state: s, allow: false, do: [{unhop: true}]}, "no ceremony of the content window showing: nothing is delivered")
  assert.deepEqual(step(s, {type: "account-navigate", url: HOME + "/login#a", target: "frame"}), {state: s, allow: false, do: []})
  assert.deepEqual(step(s, {type: "account-navigate", url: HOME + "/", target: "top"}).do, [{unhop: true}])
})

const ANSWER = HOME + "/login#a"
const returned = [...open, accountNavigate({url: ANSWER, kind: "sign-in"})]
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
    "a lock": [...landing, company],
    "cyfr's own lock": [...landing, locked(HOME)],
    "the window gone": [...landing, {type: "quit"}],
    "cyfr gone": [...landing, {type: "gone", why: "it exited"}]
  }
  for (const [name, events] of Object.entries(outcomes)) {
    assert.equal(run([...returned, ...events], true).s.returning, null, name)
    assert.equal(reloads([...events, ...later]), 0, name)
  }
})

const failed = (over) => ({type: "load-failed", code: -106, url: HOME + "/threads", ...over})

test("a CYFR's page whose load failed shows the chooser saying so, and locks, closes and forgets nothing", () => {
  for (const road of [true, false]) {
    for (const code of [-21, -106, -202, -324, -379]) {
      const before = {...run(open, road).s, notices: ["company"]}
      const r = step(before, failed({code}))
      assert.deepEqual(r.do, [{say: `unanswered: the CYFR's page did not load (${code})`}, {back: ["company", "unanswered"]}])
      assert.deepEqual(r.state, before, "nothing of main's changes")
    }
  }
})

test("a load given up, one elsewhere and one with no CYFR open are no failure of the CYFR's", () => {
  const cases = {
    "given up": [open, failed({code: -3})],
    "the chooser's own": [open, failed({url: "http://127.0.0.1:7340/bootstrap/"})],
    "the account service's": [open, failed({url: ACCOUNT + "/account/sign"})],
    "another port of its host": [open, failed({url: HOME + ":9443/"})],
    "no CYFR": [[ready], failed({})],
    "being taken": [[ready, home()], failed({})],
    "proposed": [proposed, failed({})],
    "locking": [[...open, company], failed({})],
    "ended": [[...open, {type: "quit"}], failed({})]
  }
  for (const [name, [events, event]] of Object.entries(cases)) {
    const s = run(events, true).s
    assert.deepEqual(step(s, event), {state: s, do: []}, name)
  }
})

test("a lock that follows a load's failure has nothing of it to tell", () => {
  const {effects} = run([...open, failed({}), locked(HOME), forgot], true)
  assert.deepEqual(effects.filter((e) => e.chooser).at(-1), {chooser: []})
})

test("Try again is the passkey road's alone, and its address never loads", () => {
  for (const [events, road] of [[open, false], [proposed, true], [[ready], true]]) {
    const s = run(events, road).s
    assert.deepEqual(step(s, navigate({url: AGAIN, showing: CHOOSER_DOC})), {state: s, allow: false, do: []})
  }
})

test("an earlier load call's end leaves the return on its way", () => {
  assert.equal(reloads([ownStart, {type: "delivered"}, {type: "load-ended", url: HOME + "/login#before"}, {type: "landed", url: ANSWER}]), 1)
})

test("before ready and while locking, a top-frame load in the account window is refused and ends any ceremony; a frame's ends nothing", () => {
  const states = {starting: initial(true), locking: run([...open, company], true).s}
  for (const [name, s] of Object.entries(states)) {
    for (const url of [ACCOUNT + "/account/sign", ANSWER, HOME + "/"]) {
      const at = {type: "account-navigate", url, kind: "sign-in"}
      assert.deepEqual(step(s, {...at, target: "top"}), {state: s, allow: false, do: [{unhop: true}]}, `${name}: ${url}`)
      assert.deepEqual(step(s, {...at, target: "frame"}), {state: s, allow: false, do: []}, `${name}, a frame: ${url}`)
    }
  }
})

const CHOOSER = "http://127.0.0.1:7340/bootstrap/#notice=company"
const companyLock = [...open, company, locked(HOME)]
const deviceLock = [locked(HOME), forgot]
const shownNotices = (events) => run(events, true).effects.filter((x) => x.chooser).at(-1).chooser

test("a lock over a chooser that is keeping a notice leaves the notice there", () => {
  assert.deepEqual(shownNotices([...companyLock, ...deviceLock]), ["company"], "cyfr's own lock")
  assert.deepEqual(shownNotices([...companyLock, ...deviceLock, ...deviceLock]), ["company"], "and another")
  assert.deepEqual(shownNotices([...companyLock, company, locked(HOME)]), ["company"], "the company page again is said once")
})

test("only a way on taken from the chooser clears what it was keeping", () => {
  const from = (over) => navigate({url: "http://127.0.0.1:7340/", showing: CHOOSER, ...over})
  for (const [name, way] of [["Use this computer's key", from({})], ["Sign in with your passkey", from({url: HOME + "/login"})]]) {
    assert.deepEqual(shownNotices([...companyLock, way, ...deviceLock]), [], name)
  }
  for (const [name, event] of [["a frame's load", from({target: "frame"})], ["a load refused", from({url: "https://evil.example/"})],
    ["a confirmation window's", from({window: "child"})], ["the chooser itself again", from({url: CHOOSER})],
    ["a lost page shown again", {type: "lost"}], ["a second launch", {type: "second-instance"}]]) {
    assert.deepEqual(shownNotices([...companyLock, event, ...deviceLock]), ["company"], name)
  }
})

test("a second launch shows the content window, and nothing once ended", () => {
  assert.deepEqual(step(run(open).s, {type: "second-instance"}).do, [{show: true}])
  assert.deepEqual(step(run([...open, {type: "quit"}]).s, {type: "second-instance"}).do, [])
})

// One row or more for each act of ACTS: where it is pressed, and what
// follows only a press. An act with no row fails.
const CHOOSER_DOC = "http://127.0.0.1:7340/bootstrap/"
const AGAIN = CHOOSER_DOC + "again"
const SIGN_IN = ACCOUNT + "/account/sign#x"
// The chooser's Change…, naming the epoch it was shown in and the picks
// answered before it.
const PICK = CHOOSER_DOC + "pick?epoch=3&pick=2"
const DOCKER_PAGE = "https://docs.docker.com/engine/install/"
const PRESSES = {
  external: [
    {name: "Docker's page", event: navigate({url: DOCKER_PAGE, showing: atWays}),
      acted: (r) => r.do.some((e) => e.external?.url === DOCKER_PAGE)}],
  pick: [
    {name: "Change…", event: navigate({url: PICK, showing: atWays}),
      acted: (r) => r.do.some((e) => e.pick) && r.state.picking > 0}],
  again: [
    {name: "Try again", event: navigate({url: AGAIN, showing: atWays}),
      acted: (r) => r.do.some((e) => e.root?.home === HOME) && r.state.notices.length === 0}],
  another: [
    {name: "Connect to another CYFR", event: navigate({url: another.url, showing: atWays}),
      acted: (r) => r.do.some((e) => e.forget) && r.state.leaving === true}],
  onward: [
    {name: "Sign in with your passkey", event: navigate({url: HOME + "/login", showing: atWays}),
      acted: (r) => r.state.notices.length === 0},
    {name: "Use this computer's key", event: navigate({url: "http://127.0.0.1:7340/", showing: atWays}),
      acted: (r) => r.state.notices.length === 0}],
  hop: [
    {name: "Sign in with your account", event: navigate({url: SIGN_IN, showing: HOME + "/login"}),
      acted: (r) => r.do.some((e) => e.hop)}],
  answer: [
    {name: "a sign-in's answer", event: accountNavigate({url: HOME + "/login#a", kind: "sign-in"}),
      acted: (r) => r.do.some((e) => e.deliver) && !!r.state.returning},
    {name: "a confirmation's answer", event: accountNavigate({url: HOME + "/login#a", kind: "confirmation"}),
      acted: (r) => r.do.some((e) => e.confirmation)}]
}

test("every act the person presses is in this table", () => {
  assert.deepEqual(Object.keys(PRESSES).sort(), Object.keys(ACTS).sort())
})

test("an act is no redirect, and is begun by the top frame's own document that offers it, at its origin", () => {
  const s = {...run(open, true).s, notices: ["company"]}
  const askers = ["top", "frame-inside", "frame-outside", "none"]
  const documents = {chooser: CHOOSER_DOC, "the chooser with its road": atWays, "the device's pages": "http://127.0.0.1:7340/",
    "the CYFR's page": HOME + "/login", "the account's page": SIGN_IN, "another site": "https://evil.example/bootstrap/",
    "the chooser's path at the CYFR": HOME + "/bootstrap/", "the chooser's path on another port": "http://127.0.0.1:7341/bootstrap/",
    "the CYFR's host on another port": HOME + ":9443/login", "the account's path on another port": ACCOUNT + ":9443/account/sign",
    none: ""}
  const offers = {external: ["chooser", "the chooser with its road"], pick: ["chooser", "the chooser with its road"], again: ["chooser", "the chooser with its road"], another: ["chooser", "the chooser with its road"], onward: ["chooser", "the chooser with its road"],
    hop: ["the CYFR's page", "the chooser's path at the CYFR"], answer: ["the account's page"]}
  for (const [act, rows] of Object.entries(PRESSES)) {
    for (const {name, event, acted} of rows) {
      for (const redirect of [false, true]) {
        for (const asker of askers) {
          for (const [whose, by] of Object.entries(documents)) {
            // The engine's shape of a redirect: the first document's frame is
            // still the initiator, and the window still shows it.
            const r = step(s, {...event, redirect, asker, by})
            const press = !redirect && asker === "top" && offers[act].includes(whose)
            assert.equal(acted(r), press, `${name}: redirect ${redirect}, by ${asker} of ${whose}`)
            if (!press && act !== "onward") assert.equal(r.allow, false, `${name}, refused: ${redirect} ${asker} ${whose}`)
          }
        }
      }
    }
  }
})

test("on the box's screen none of the chooser's acts is offered or accepted, from any page of it", () => {
  const SCREEN_PAGE = "http://127.0.0.1:7340/"
  const screen = (events) => {
    let s = initial(false, {proxy: "", resolver: ""}, "/home/ana/cyfr")
    for (const e of [{type: "ready", url: SCREEN_PAGE}, ...events]) s = step(s, e).state
    return s
  }
  const states = {"the shell's page": screen([]), "a CYFR open": screen([home(), taken, openedAt(HOME)])}
  for (const [where, s] of Object.entries(states)) {
    for (const act of ["pick", "external", "another", "again"]) {
      for (const {name, event, acted} of PRESSES[act]) {
        for (const by of [SCREEN_PAGE, CHOOSER_DOC, atWays]) {
          const r = step(s, {...event, by, showing: by})
          assert.ok(!acted(r), `${where}: ${name} from ${by} acted`)
          assert.equal(r.allow, false, `${where}: ${name} from ${by} loaded`)
          assert.ok(!r.do.some((e) => e.pick || e.external || e.root || e.forget), `${where}: ${name} from ${by}: ${JSON.stringify(r.do)}`)
        }
      }
    }
  }
})

// The chooser's Change…, pressed on the chooser with no CYFR open.
const change = navigate({url: PICK, showing: CHOOSER_DOC, by: CHOOSER_DOC})
const picked = (id, path) => ({type: "picked", id, path})
const answers = (effects) => effects.filter((e) => e.send?.type === "folder-picked").map((e) => e.send.fields)
// The answer to the pick PICK names.
const of = (path, epoch = 3, pick = 2) => ({path, epoch, pick})

test("Change… asks the system once, never loads, and cyfr hears the folder it gave, or none", () => {
  for (const road of [false, true]) {
    const asked = run([ready, change], road)
    assert.deepEqual(asked.effects.at(-1), {pick: {id: 1}})
    assert.equal(step(run([ready], road).s, change).allow, false, "its address never loads")
    assert.deepEqual(answers(run([ready, change, picked(1, "/home/ada/elsewhere")], road).effects), [of("/home/ada/elsewhere")])
    assert.deepEqual(answers(run([ready, change, picked(1, "C:\\Users\\ada\\cyfr")], road).effects), [of("C:\\Users\\ada\\cyfr")])
    assert.deepEqual(answers(run([ready, change, picked(1, null)], road).effects), [of(null)], "cancelled")
    assert.deepEqual(answers(run([ready, change, picked(1, "elsewhere")], road).effects), [of(null)], "a folder from no root is none")
    const next = navigate({url: CHOOSER_DOC + "pick?epoch=3&pick=3", showing: CHOOSER_DOC, by: CHOOSER_DOC})
    const twice = run([ready, change, picked(1, "/a"), next, picked(2, "/b")], road)
    assert.deepEqual(answers(twice.effects), [of("/a"), of("/b", 3, 3)], "each pick is its own, with what the chooser named for it")
    assert.deepEqual(twice.effects.filter((e) => e.pick), [{pick: {id: 1}}, {pick: {id: 2}}])
  }
})

test("Change… is a pick only at the chooser's own address for it, naming its epoch and pick as whole numbers and nothing else", () => {
  for (const tail of ["pick", "pick?epoch=3", "pick?pick=2", "pick?epoch=3&pick=2&x=1", "pick?epoch=-1&pick=2", "pick?epoch=3&pick=02",
    "pick?epoch=3&pick=2.5", "pick?epoch=3&pick=9007199254740992", "pick?epoch=3&pick=2#x", "pick/?epoch=3&pick=2", "pick?epoch=3&epoch=4&pick=2"]) {
    const r = step(run([ready]).s, navigate({url: CHOOSER_DOC + tail, showing: CHOOSER_DOC, by: CHOOSER_DOC}))
    assert.ok(!r.do.some((e) => e.pick) && r.state.picking === 0, tail)
    assert.equal(r.allow, false, `${tail} never loads`)
  }
})

test("one pick at a time: Change… again while the dialog is open asks nothing, and a result for another pick is dropped", () => {
  const again = run([ready, change, change])
  assert.deepEqual(again.effects.filter((e) => e.pick), [{pick: {id: 1}}])
  assert.deepEqual(answers(run([ready, change, change, picked(1, "/a"), picked(1, "/b")]).effects), [of("/a")], "answered once")
  assert.deepEqual(answers(run([ready, change, picked(2, "/a")]).effects), [], "a result for no pick asked")
  assert.deepEqual(answers(run([ready, picked(1, "/a")]).effects), [], "a result with nothing asked")
})

test("the chooser leaving, a lock, Connect to another CYFR and an end answer the pick with none, and the dialog's result after is dropped", () => {
  const ends = {
    "a document committing": [{type: "committed"}],
    "a lost page shown again": [{type: "lost"}, {type: "committed"}],
    "cyfr's lock": [locked()],
    "a lock of the company page": [...open.slice(1), company],
    "the window closing": [{type: "quit"}],
    "cyfr gone": [{type: "gone", why: "it exited (1)"}]
  }
  for (const [name, events] of Object.entries(ends)) {
    for (const road of [false, true]) {
      const r = run([ready, change, ...events, picked(1, "/home/ada/elsewhere")], road)
      assert.deepEqual(answers(r.effects), [of(null)], `${name}: answered with none, once`)
      assert.equal(r.s.picking, 0, name)
    }
  }
  const leaving = run([...open, change, another, picked(1, "/a")], true)
  assert.deepEqual(answers(leaving.effects), [of(null)], "Connect to another CYFR")
  const said = run([ready, change, locked()]).effects
  assert.ok(said.findIndex((e) => e.send?.type === "folder-picked") < said.findIndex((e) => e.close), "answered before the content closes")
  assert.deepEqual(answers(run([ready, change, {type: "landed", url: CHOOSER_DOC + "#x"}, {type: "started", url: HOME}]).effects), [],
    "a fragment, or a navigation that has not committed, leaves the pick")
})

test("the chooser's links open in the person's browser: Docker's pages, as the vectors name them, and none other", () => {
  const vectors = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/desktop-process.json", import.meta.url)))
  assert.deepEqual(EXTERNAL, vectors["external_pages"])
  const s = run([ready]).s
  for (const url of EXTERNAL) {
    assert.deepEqual(step(s, navigate({url, showing: CHOOSER_DOC, by: CHOOSER_DOC})), {state: s, allow: false, do: [{external: {url}}]})
  }
  for (const url of ["https://www.docker.com/", "https://docs.docker.com/engine/install/ubuntu/", "https://evil.example/",
    "http://docs.docker.com/engine/install/", DOCKER_PAGE + "#x"]) {
    const r = step(s, navigate({url, showing: CHOOSER_DOC, by: CHOOSER_DOC}))
    assert.equal(r.allow, false, url)
    assert.deepEqual(r.do, [], url)
  }
})

// The box's screen and its shell agree from any order of their messages
// (cmd/screen_app.go is the shell's side, modelled here as it is written):
// from nothing said, the shell's first message is ready, with its proposal
// of its CYFR as attempt 1 in the same step (one hold of its mutex); it
// answers opened to the current attempt's home-ready alone and once, and
// on every lock after ready, its own or main's, says locked naming no CYFR
// and proposes again as the next attempt, while a lock before ready says
// nothing (the page ready names says it). Every order of the shell's
// ready, of delivering either side's messages, of the takes and clears
// ending (in the order they were asked, as app.js chains them), and of up
// to two locks of the shell's own, a keyboard that ends (before ready or
// after it) and one lost page of main's (every state they reach, each
// walked once), ends with main keeping to the CYFR on the device's own
// page: never stranded keeping to none, never ended. The shell's own end,
// at any point, is its last lock, saying ending and nothing after it, and
// then its exit reaching main, in either order with what is still on the
// way: main ends showing nothing, and opens no window once it read ending.
test("the screen ends on its CYFR whatever the order of its messages", () => {
  const LOOP = "http://127.0.0.1:7340/"
  const CYFR = "http://localhost:4000"
  const initialWorld = (endable) => ({
    main: initial(false, {proxy: "", resolver: ""}, "/home/alice/cyfr"),
    shell: {ready: false, attempt: 0, answered: false, locks: 2, keyboard: 1, gone: false, ending: false, exited: false, endable},
    toMain: [],
    toShell: [], pending: [], showing: "", lost: 1, trace: [],
    // The chooser's moves that reach main (the setup's answers are the
    // page's and cyfr's, never main's, and main reads no folder-picked):
    // Change… pressed on what the screen shows, and a dialog's result, each
    // once, at any point, after main ended too.
    presses: 1, results: 1
  })
  const clone = (w) => structuredClone(w)
  const propose = (w) => {
    w.shell.attempt++
    w.shell.answered = false
    w.toMain.push({type: "home", message: {type: "home", home: CYFR, account: CYFR, attempt: w.shell.attempt}})
  }
  const hide = (w) => {
    if (!w.shell.ready || w.shell.ending) return
    w.shell.attempt++
    w.shell.answered = false
    w.toMain.push({type: "locked", message: {type: "locked"}},
      {type: "home", message: {type: "home", home: CYFR, account: CYFR, attempt: w.shell.attempt}})
  }
  const carry = (w, next) => {
    w.main = next.state
    for (const effect of next.do) {
      if (effect.send) w.toShell.push({type: effect.send.type, ...(effect.send.fields ?? {})})
      if (effect.take) w.pending.push({type: "taken", taken: true})
      if (effect.forget) w.pending.push({type: "forgot", cleared: true})
      if (effect.chooser) w.showing = w.main.readyURL
      if ((effect.chooser || effect.root) && w.endingRead) w.openedForEnding = true
      if (effect.close) w.showing = ""
      if (effect.end || effect.quit) w.ended = JSON.stringify(effect)
      if (effect.pick || effect.external || effect.send?.type === "folder-picked") w.picked = JSON.stringify(effect)
    }
  }
  const chooserMoves = (w, out) => {
    if (w.presses > 0) {
      out.push(["Change… is pressed", (x) => {
        x.presses--
        const shown = x.showing || LOOP
        carry(x, step(x.main, {type: "navigate", window: "content", url: LOOP + "bootstrap/pick?epoch=0&pick=0", target: "top", asker: "top",
          showing: shown, by: shown}))
      }])
    }
    if (w.results > 0) out.push(["a dialog's result arrives", (x) => { x.results--; carry(x, step(x.main, {type: "picked", id: 1, path: "/home/a"})) }])
  }
  const moves = (w) => {
    const out = []
    chooserMoves(w, out)
    if (w.ended || w.shell.gone) return out
    if (w.toMain.length) {
      out.push(["to main", (x) => {
        const m = x.toMain.shift()
        if (m.type === "ending") x.endingRead = true
        carry(x, step(x.main, m.type === "ready" ? m : {type: m.type, home: m.home, message: m.message}))
      }])
    }
    if (w.toShell.length) {
      out.push(["to the shell", (x) => {
        const m = x.toShell.shift()
        if (x.shell.ending) return
        if (m.type === "home-ready" && m.attempt === x.shell.attempt && !x.shell.answered) {
          x.shell.answered = true
          x.toMain.push(openedAt(CYFR, x.shell.attempt))
        }
        if (m.type === "home-failed" && m.attempt === x.shell.attempt) x.shell.gone = true
        if (m.type === "lock" || m.type === "leave") hide(x)
      }])
    }
    if (w.pending.length) out.push(["a take or clear ends", (x) => carry(x, step(x.main, x.pending.shift()))])
    if (!w.shell.ready) {
      out.push(["the shell says ready", (x) => {
        x.shell.ready = true
        x.toMain.push({type: "ready", url: LOOP})
        propose(x)
      }])
    }
    if (w.shell.endable && !w.shell.ending) {
      out.push(["the shell ends", (x) => {
        // Its last lock: ending in place of locked, and nothing after it.
        x.shell.ending = true
        if (x.shell.ready) x.toMain.push({type: "ending", message: {type: "ending"}})
      }])
    } else if (w.shell.ending && !w.shell.exited) {
      out.push(["cyfr's exit reaches main", (x) => { x.shell.exited = true; carry(x, step(x.main, {type: "gone", why: "it exited (0)"})) }])
    }
    if (w.shell.locks > 0 && !w.shell.ending) out.push(["the shell locks", (x) => { x.shell.locks--; hide(x) }])
    if (w.shell.keyboard > 0 && !w.shell.ending) out.push(["the keyboard ends", (x) => { x.shell.keyboard--; hide(x) }])
    if (w.lost > 0 && w.main.name !== "starting") out.push(["main's page is lost", (x) => { x.lost--; carry(x, step(x.main, {type: "lost"})) }])
    return out
  }
  const seen = new Set()
  let ends = 0
  let endings = 0
  const walk = (w) => {
    const key = JSON.stringify({...w, trace: undefined})
    if (seen.has(key)) return
    seen.add(key)
    const next = moves(w)
    if (next.length === 0) {
      ends++
      assert.ok(!w.picked, `the screen asked for or answered a pick (${w.picked}) after ${w.trace.join(" > ")}`)
      if (w.shell.ending) {
        assert.ok(!w.openedForEnding, `a window opened once main read the shell's ending, after ${w.trace.join(" > ")}`)
        assert.ok(w.ended && w.showing === "", `it ended ${w.main.name} showing "${w.showing}" after ${w.trace.join(" > ")}`)
        endings++
        return
      }
      assert.ok(!w.ended && !w.shell.gone, `it ended (${w.ended ?? "the shell gone"}) after ${w.trace.join(" > ")}`)
      assert.ok(w.main.name === "open" && w.main.home === CYFR && w.showing === LOOP,
        `it ended ${w.main.name} keeping to "${w.main.home}" showing "${w.showing}" after ${w.trace.join(" > ")}`)
      return
    }
    for (const [name, move] of next) {
      const x = clone(w)
      x.trace.push(name)
      move(x)
      walk(x)
    }
  }
  walk(initialWorld(false))
  assert.ok(ends > 0 && endings === 0 && seen.size > 500, `only ${seen.size} states were walked`)
  walk(initialWorld(true))
  assert.ok(endings > 0, "no walk ended with the shell's end")
})

test("ending is the last word of a run: after it main ends, and a left, which the vectors say never follows, changes nothing", () => {
  const vectors = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/desktop-process.json", import.meta.url)))
  assert.ok(vectors["endings"].length > 0)
  for (const {name, from_cyfr: said} of vectors["endings"]) {
    let s = initial(false, {proxy: "", resolver: ""}, "/home/ana/cyfr")
    for (const e of [{type: "ready", url: "http://127.0.0.1:7340/"}, home(), taken, openedAt(HOME)]) s = step(s, e).state
    const effects = []
    for (const m of said) {
      const r = step(s, {type: m.type, message: m})
      s = r.state
      effects.push(...r.do)
    }
    assert.equal(s.name, "ended", name)
    assert.ok(effects.some((e) => e.quit), name)
    const after = step(s, leftOf(7))
    assert.deepEqual([after.state, after.do], [s, []], name)
  }
})
