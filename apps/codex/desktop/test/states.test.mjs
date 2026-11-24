// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What main does (src/states.js): each event in each state, as the
// effects step answers.

import assert from "node:assert/strict"
import {test} from "node:test"

import {readFileSync} from "node:fs"

import {fragment} from "../../../cyfr/assets/account/sign_in.js"
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

const RAIL = "http://127.0.0.1:7340/rail/#read=cmVhZA"
const UPDATE = "http://127.0.0.1:7340/update/#read=cmVhZA"
const ready = {type: "ready", url: READY, message: {type: "ready", url: READY, rail: RAIL, update: UPDATE}}
// Begun by the document showing, unless `over` says another began it.
const navigate = (over) => ({type: "navigate", window: "content", url: HOME + "/", target: "top", asker: "top", showing: READY,
  by: over.showing ?? READY, ...over})
// A request HOME issued for its own /login, current for an hour: a
// sign-in's or a confirmation's, at the account page that takes it.
const REQUESTS = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/sign_in.json", import.meta.url)))["requests"]
const requestFor = (kind, over = {}) => ({...REQUESTS[kind === "confirmation" ? "confirm" : "sign_in"].request,
  audience: HOME, return: HOME + "/login", expires_at: Date.now() + 3_600_000, ...over})
const signed = (kind, over) => `${ACCOUNT}/account/sign#${fragment(requestFor(kind, over))}`
// The account window's top-frame load, begun by the account's own page,
// which shows the ceremony's request.
const accountNavigate = (over) => ({type: "account-navigate", window: "account", target: "top", asker: "top",
  by: signed(over.kind ?? "sign-in"), ...over})
// The content window's top frame given HOME, as the device's pages open it.
const given = navigate({showing: "http://127.0.0.1:7340/"})
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
  assert.equal(run([...open, home("https://bob.example", 2)]).s.name, "ended", "a proposal after a commit")
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
  assert.equal(run([...open, locked(), forgot]).s.name, "chooser", "a locked naming none")
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
    ["a kept sign-in that is over, as the app opens it in a view of its own", {url: HOME + "/login", showing: ""}],
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
    ["the chooser loading the sign-in page, which only main opens", true, {url: login, showing: "http://127.0.0.1:7340/bootstrap/", redirect: false}, false],
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

test("main answers a proposal home-ready at once and keeps to a CYFR only once cyfr opened it, whichever road", () => {
  for (const road of [false, true]) {
    const waiting = run([ready, home()], road)
    assert.deepEqual(waiting.effects.at(-1), {send: {type: "home-ready", fields: {home: HOME, attempt: 1}}})
    assert.ok(!waiting.effects.some((e) => e.root || e.forget), "nothing opened or cleared for a proposal")
    for (const url of [HOME + "/", HOME + "/login", HOME + "/auth/device/complete/x"]) {
      assert.equal(step(waiting.s, navigate({url})).allow, false, url)
    }
    assert.equal(step(waiting.s, navigate({url: HOME + "/", target: "frame", asker: "frame-inside"})).allow, false, "nor a frame")
    assert.equal(step(step(waiting.s, openedAt(HOME)).state, given).allow, true)
  }
})

test("each proposal is answered as it comes, and only the last one's opened opens", () => {
  const bob = "https://bob.example"
  const over = run([ready, home(HOME, 1), home(bob, 2), home(HOME, 3)], true)
  assert.deepEqual(over.effects.filter((e) => e.send).map((e) => e.send.fields.attempt), [1, 2, 3])
  assert.equal(step(over.s, openedAt(HOME, 1)).state.name, "ended", "an opened of an earlier proposal")
  assert.equal(step(over.s, openedAt(HOME, 3)).state.name, "open")
})

test("main alone opens a CYFR committed at its root, on the passkey road, and the notices are told by then", () => {
  assert.deepEqual(run(open, true).effects.at(-1), {root: {home: HOME, path: "/"}})
  assert.ok(!run(open, false).effects.some((e) => e.root))
  const told = run([...open, company, locked()], true)
  assert.deepEqual(told.s.notices, ["company"])
  assert.deepEqual(run([...open, company, locked(), home(HOME, 2), taken, openedAt(HOME, 2)], true).s.notices, [])
})

test("a CYFR no one is set up at opens at its setup page on the passkey road, the token held no longer, and the next home without one at its root", () => {
  const first = {type: "home", message: {...home().message, setup: "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"}}
  const opened = run([ready, first, taken, openedAt(HOME)], true)
  assert.equal(opened.s.name, "open")
  assert.deepEqual(opened.effects.filter((e) => e.root), [{root: {home: HOME, path: "/", setup: "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"}}], "its setup page")
  assert.equal(opened.s.setup, "", "main holds the token until it is used, and no longer")
  assert.ok(!opened.effects.some((e) => e.say?.includes("cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd")), "nothing said carries it")
  const again = run([ready, first, taken, openedAt(HOME), locked(), forgot, home(HOME, 2), taken, openedAt(HOME, 2)], true)
  assert.deepEqual(again.effects.filter((e) => e.root).at(-1), {root: {home: HOME, path: "/"}}, "a home with no token: its root")
  const sixWords = run([ready, first, taken, openedAt(HOME)], false)
  assert.ok(!sixWords.effects.some((e) => e.root), "on the six-word road main loads none: the device's pages make the first person")
  assert.equal(step(sixWords.s, given).allow, true, "the device's pages give the CYFR")
})

const atWays = "http://127.0.0.1:7340/bootstrap/#road=passkey"
const BOB = "https://bob.example:8443"
const RAIL_DOC = "http://127.0.0.1:7340/rail/"
// A press on the rail: a navigation of its page to `path`, which main
// answers.
const railed = (path, over = {}) => ({type: "navigate", window: "rail", url: "http://127.0.0.1:7340" + path, target: "top",
  asker: "top", showing: RAIL_DOC, by: RAIL_DOC, ...over})
const selects = (h) => railed("/rail/select?cyfr=" + encodeURIComponent(h))
const UPDATE_DOC = "http://127.0.0.1:7340/update/"
// A press on Update CYFR: a navigation of its page to `path`, which main
// answers.
const updated = (path, over = {}) => ({type: "navigate", window: "update", url: "http://127.0.0.1:7340" + path, target: "top",
  asker: "top", showing: UPDATE_DOC, by: UPDATE_DOC, ...over})
const parted = (id) => ({type: "parted", id})

test("a press on the rail for another CYFR leaves the one open, and the chooser connects to it once both left and parted", () => {
  for (const road of [false, true]) {
    const leaving = run([...open, selects(BOB)], road)
    assert.equal(leaving.s.name, "locking")
    assert.deepEqual(leaving.effects.slice(-4), [{close: true}, {part: {id: 1}}, {send: {type: "leave", fields: {id: 1}}},
      {deadline: {id: 1}}])
    assert.ok(!leaving.kinds.includes("forget"), "nothing of the CYFR left is forgotten")
    assert.equal(run([...open, selects(BOB), leftOf(1)], road).s.name, "locking", "left alone")
    assert.equal(run([...open, selects(BOB), parted(1)], road).s.name, "locking", "parted alone")
    for (const order of [[leftOf(1), parted(1)], [parted(1), leftOf(1)]]) {
      const done = run([...open, selects(BOB), ...order], road)
      assert.equal(done.s.name, "chooser")
      assert.equal(done.s.home, "", "main keeps to none")
      assert.deepEqual(done.effects.at(-1), {chooser: [], connect: BOB})
    }
  }
  const at = run([ready, selects(BOB)], true)
  assert.deepEqual(at.effects.slice(-2), [{close: true}, {chooser: [], connect: BOB}], "from the chooser, at once")
  assert.ok(!at.effects.some((e) => e.send), "with nothing to leave")
  assert.deepEqual(step(run(open, true).s, selects(HOME)).do, [{show: true}], "the CYFR open is shown")
})

test("a departure ends at its own left and parted alone, and the next is numbered after it", () => {
  const waiting = [...open, selects(BOB), parted(1)]
  for (const [what, events] of Object.entries({
    "a locked": [parted(1), locked()],
    "an unasked locked naming the CYFR": [parted(1), locked(HOME)],
    "a left of another id": [parted(1), leftOf(2)],
    "a left of none": [parted(1), {type: "left", message: {type: "left"}}],
    "a parted of another id": [leftOf(1), parted(2)],
  })) {
    assert.equal(run([...open, selects(BOB), ...events], true).s.name, "locking", what)
  }
  assert.equal(run([...waiting, leftOf(1), leftOf(1)], true).s.name, "chooser", "a duplicate left does nothing")
  assert.equal(run([...open, leftOf(1)], true).s.name, "open", "a left with no departure does nothing")
  const second = run([...waiting, leftOf(1), home(HOME, 2), openedAt(HOME, 2), selects(BOB)], true)
  assert.deepEqual(second.effects.filter((e) => e.send?.type === "leave").at(-1), {send: {type: "leave", fields: {id: 2}}})
  assert.equal(run([...waiting, leftOf(1), home(HOME, 2), openedAt(HOME, 2), selects(BOB), parted(2), leftOf(1)], true).s.name,
    "locking", "the first departure's left, late, ends no second")
})

test("a departure past its deadline ends cyfr and starts a fresh one, which opens nothing by itself", () => {
  const late = run([...open, selects(BOB), parted(1), {type: "late", id: 1}], true)
  assert.equal(late.s.name, "starting")
  assert.deepEqual(late.effects.at(-1), {restart: true})
  assert.deepEqual(late.s.notices, ["unleft"])
  const fresh = run([...open, selects(BOB), {type: "late", id: 1}, ready], true)
  assert.deepEqual(fresh.effects.slice(-2), [{rail: {url: RAIL}}, {chooser: ["unleft"]}], "the chooser says why, and resumes none")
  assert.ok(!fresh.effects.some((e) => e.connect), "the CYFR pressed is not opened")
  for (const [what, events] of Object.entries({
    "a deadline of another id": [selects(BOB), {type: "late", id: 2}],
    "a deadline after the departure ended": [selects(BOB), parted(1), leftOf(1), {type: "late", id: 1}],
  })) {
    assert.ok(!run([...open, ...events], true).kinds.includes("restart"), what)
  }
})

test("Forget is a row's menu, which main draws; confirmed, the CYFR open is left first and only then forgotten", () => {
  const menu = railed("/rail/menu?cyfr=" + encodeURIComponent(BOB))
  assert.deepEqual(step(run(open, true).s, menu).do, [{menu: {home: BOB}}])
  assert.deepEqual(step(run(open, true).s, menu).state, run(open, true).s, "the menu changes nothing")
  const other = step(run(open, true).s, {type: "forget-confirmed", home: BOB})
  assert.deepEqual(other.do, [{send: {type: "forget", fields: {home: BOB}}}], "another CYFR, at once")
  assert.equal(other.state.name, "open")
  const own = run([...open, {type: "forget-confirmed", home: HOME}], true)
  assert.equal(own.s.name, "locking")
  assert.ok(!own.effects.some((e) => e.send?.type === "forget"), "nothing forgotten before it is left")
  const done = run([...open, {type: "forget-confirmed", home: HOME}, parted(1), leftOf(1)], true)
  assert.deepEqual(done.effects.slice(-2), [{send: {type: "forget", fields: {home: HOME}}}, {chooser: []}])
  for (const before of [[ready, home()], [...open, selects(BOB)]]) {
    assert.deepEqual(step(run(before, true).s, {type: "forget-confirmed", home: BOB}).do, [], "not while a proposal or a departure waits")
  }
})

test("cyfr's erase is carried out, but never of the CYFR open", () => {
  const erase = (h, account) => ({type: "erase", message: {type: "erase", id: 4, home: h, ...(account ? {account} : {})}})
  assert.deepEqual(step(run(open, true).s, erase(BOB)).do, [{erase: {id: 4, home: BOB, account: ""}}])
  assert.deepEqual(step(run(open, true).s, erase(BOB, ACCOUNT)).do, [{erase: {id: 4, home: BOB, account: ACCOUNT}}])
  for (const before of [open, [ready, home()], [...open, selects(BOB)]]) {
    assert.deepEqual(step(run(before, true).s, erase(HOME)).do, [{send: {type: "erased", fields: {id: 4, ok: false}}}])
  }
})

test("the rail's page loads nothing, and only its own top frame's presses act", () => {
  const s = run(open, true).s
  for (const [what, e] of Object.entries({
    "an address that is no press": railed("/"),
    "a press with more": railed("/rail/select?cyfr=" + encodeURIComponent(BOB) + "&x=1"),
    "a press of no CYFR's origin": railed("/rail/select?cyfr=" + encodeURIComponent(BOB + "/")),
    "the CYFR's page": railed("", {url: HOME + "/"}),
    "a redirect": {...selects(BOB), redirect: true},
    "a frame": {...selects(BOB), target: "frame", asker: "frame-inside"},
    "another document": {...selects(BOB), by: CHOOSER_DOC},
    "the content window": {...selects(BOB), window: "content"},
  })) {
    const r = step(s, e)
    assert.equal(r.allow, false, what)
    assert.ok(!r.do.some((x) => x.send || x.close || x.menu || x.chooser), `${what}: ${JSON.stringify(r.do)}`)
  }
  for (const before of [[], [ready, home()], [...open, selects(BOB)]]) {
    assert.deepEqual(step(run(before, true).s, selects(BOB)).do, [], "not while cyfr starts, a proposal or a departure waits")
  }
})

test("Update CYFR opens from the rail's foot over the CYFR open, which stays; by itself at the first ready of an app the update opened again; never on the box's screen", () => {
  const r = step(run(open, true).s, railed("/rail/update"))
  assert.deepEqual(r.do, [{update: {url: UPDATE}}])
  assert.equal(r.allow, false)
  assert.equal(r.state.name, "open", "the CYFR open is left as it is")
  assert.equal(r.state.home, HOME)
  const updated = step(initial(true, {proxy: "", resolver: ""}, "", true), ready)
  assert.deepEqual(updated.do.slice(-2), [{chooser: []}, {update: {url: UPDATE + "&updated=1"}}], "the update's reopen opens it, over the chooser")
  assert.equal(updated.state.updated, false, "once")
  assert.ok(!run([ready], true).effects.some((e) => e.update), "opened plainly, nothing opens")
  for (const before of [[], [ready, home()], [...open, selects(BOB)]]) {
    assert.deepEqual(step(run(before, true).s, railed("/rail/update")).do, [], "not while cyfr starts, a proposal or a departure waits")
  }
  const SCREEN_PAGE = "http://127.0.0.1:7340/"
  const screen = initial(false, {proxy: "", resolver: ""}, "/home/ana/cyfr", true)
  assert.ok(!step(screen, {type: "ready", url: SCREEN_PAGE, message: {type: "ready", url: SCREEN_PAGE}}).do.some((e) => e.update),
    "the box's screen opens no Update CYFR, --updated or not")
})

test("Update CYFR's page loads nothing; its yes sends the offer it names, from its own top frame alone; its close is told to cyfr", () => {
  const s = run(open, true).s
  for (const [what, e] of Object.entries({
    "an address that is no press": updated("/update/"),
    "a yes naming no offer": updated("/update/start"),
    "a yes naming offer 0": updated("/update/start?offer=0"),
    "a yes with more": updated("/update/start?offer=4&target=9.9.9"),
    "a yes naming its offer twice": updated("/update/start?offer=4&offer=5"),
    "a yes past a safe number": updated("/update/start?offer=99999999999999999"),
    "the read": updated("/update/read"),
    "a redirect": {...updated("/update/start?offer=4"), redirect: true},
    "a frame": {...updated("/update/start?offer=4"), target: "frame", asker: "frame-inside"},
    "the rail's document": {...updated("/update/start?offer=4"), by: RAIL_DOC},
    "the rail's window": {...updated("/update/start?offer=4"), window: "rail"},
    "the content window": {...updated("/update/start?offer=4"), window: "content", by: UPDATE_DOC},
    "a CYFR's page": {...updated("/update/start?offer=4"), window: "content", by: HOME + "/", showing: HOME + "/"},
  })) {
    const r = step(s, e)
    assert.equal(r.allow, false, what)
    assert.ok(!r.do.some((x) => x.send || x.update || x.unupdate), `${what}: ${JSON.stringify(r.do)}`)
  }
  assert.deepEqual(step(s, updated("/update/start?offer=4")).do, [{send: {type: "update", fields: {offer: 4}}}])
  assert.deepEqual(step(s, updated("/update/close")).do, [{unupdate: true}])
  assert.deepEqual(step(s, {type: "update-closed"}).do, [{send: {type: "update-closed"}}])
  assert.deepEqual(step(run([ready], true).s, updated("/update/start?offer=4")).do, [{send: {type: "update", fields: {offer: 4}}}],
    "from the chooser too: the offer is cyfr's to judge")
  for (const before of [[], [...open, selects(BOB)]]) {
    assert.deepEqual(step(run(before, true).s, updated("/update/start?offer=4")).do, [], "not while cyfr starts or a departure runs")
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

test("Try again and Sign in with your passkey are the passkey road's alone, with a CYFR open, and their addresses never load", () => {
  for (const [events, road] of [[open, false], [proposed, true], [[ready], true]]) {
    const s = run(events, road).s
    for (const url of [AGAIN, SIGNIN]) assert.deepEqual(step(s, navigate({url, showing: CHOOSER_DOC})), {state: s, allow: false, do: []}, url)
  }
})

test("the chooser loads no page of the CYFR open: its sign-in is the CYFR's own view's, at its sign-in page", () => {
  // The lock of being sent to sign in keeps the CYFR open, and the chooser shows.
  const signIn = navigate({url: HOME + "/login", showing: HOME + "/threads", redirect: true})
  const {s, effects} = run([...open, signIn, locked(HOME)], true)
  assert.equal(s.name, "open")
  assert.deepEqual(effects.at(-1), {chooser: []})
  for (const url of [HOME + "/login", HOME + "/"]) {
    assert.deepEqual(step(s, navigate({url, showing: CHOOSER_DOC})), {state: s, allow: false, do: []}, url)
  }
  assert.deepEqual(step(s, navigate({url: SIGNIN, showing: CHOOSER_DOC})).do, [{root: {home: HOME, path: "/login"}}])
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
  for (const [name, way] of [["Use this computer's key", from({})], ["Sign in with your passkey", from({url: SIGNIN})]]) {
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

// cyfr update and uninstall ask the app to end with a launch of --quit
// (cmd/app_update.go askAppToQuit), until a launch finds none running.
test("a second launch with --quit ends the app as a quit does, from every state; the box's screen is shown, never ended", () => {
  const asked = {type: "second-instance", quit: true}
  for (const [name, events] of Object.entries({"starting": [], "the chooser": [ready], "proposed": proposed, "open": open,
    "after cyfr ended": [...open, {type: "gone", why: "it exited (1)"}]})) {
    const quit = step(run(events).s, {type: "quit"})
    const next = step(run(events).s, asked)
    assert.deepEqual(next, quit, name)
    assert.equal(next.state.name, "ended", name)
    assert.deepEqual(next.do.at(-1), {quit: true}, name)
  }
  const SCREEN_PAGE = "http://127.0.0.1:7340/"
  let s = initial(false, {proxy: "", resolver: ""}, "/home/ana/cyfr")
  for (const e of [{type: "ready", url: SCREEN_PAGE}, home(), taken, openedAt(HOME)]) s = step(s, e).state
  assert.deepEqual(step(s, asked), {state: s, do: [{show: true}]}, "the box's screen")
})

// One row or more for each act of ACTS: where it is pressed, and what
// follows only a press. An act with no row fails.
const CHOOSER_DOC = "http://127.0.0.1:7340/bootstrap/"
const AGAIN = CHOOSER_DOC + "again"
const SIGNIN = CHOOSER_DOC + "signin"
const SIGN_IN = signed("sign-in")
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
  reopen: [
    {name: "Try again", event: navigate({url: AGAIN, showing: atWays}),
      acted: (r) => r.do.some((e) => e.root?.home === HOME && e.root.path === "/") && r.state.notices.length === 0},
    {name: "Sign in with your passkey", event: navigate({url: SIGNIN, showing: atWays}),
      acted: (r) => r.do.some((e) => e.root?.home === HOME && e.root.path === "/login") && r.state.notices.length === 0}],
  select: [
    {name: "a CYFR on the rail", event: selects(BOB), acted: (r) => r.do.some((e) => e.send?.type === "leave")}],
  connect: [
    {name: "Connect on the rail", event: railed("/rail/connect"), acted: (r) => r.do.some((e) => e.send?.type === "leave")},
    {name: "Set up on the rail", event: railed("/rail/setup"), acted: (r) => r.do.some((e) => e.send?.type === "leave")}],
  menu: [
    {name: "a row's menu on the rail", event: railed("/rail/menu?cyfr=" + encodeURIComponent(BOB)), acted: (r) => r.do.some((e) => e.menu)}],
  update: [
    {name: "Update CYFR on the rail", event: railed("/rail/update"), acted: (r) => r.do.some((e) => e.update?.url === UPDATE)}],
  start: [
    {name: "Update CYFR's yes", event: updated("/update/start?offer=4"),
      acted: (r) => r.do.some((e) => e.send?.type === "update" && e.send.fields.offer === 4)}],
  close: [
    {name: "Update CYFR's Close", event: updated("/update/close"), acted: (r) => r.do.some((e) => e.unupdate)}],
  onward: [
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
    "the rail": RAIL_DOC, "the rail's path on another port": "http://127.0.0.1:7341/rail/", "Update CYFR": UPDATE_DOC,
    "Update CYFR's path on another port": "http://127.0.0.1:7341/update/", none: ""}
  const offers = {external: ["chooser", "the chooser with its road"], pick: ["chooser", "the chooser with its road"], reopen: ["chooser", "the chooser with its road"], select: ["the rail"], connect: ["the rail"], menu: ["the rail"], onward: ["chooser", "the chooser with its road"],
    update: ["the rail"], start: ["Update CYFR"], close: ["Update CYFR"],
    hop: ["the CYFR's page", "the chooser's path at the CYFR"], answer: ["the account's page"]}
  for (const [act, rows] of Object.entries(PRESSES)) {
    for (const {name, event, acted} of rows) {
      for (const redirect of [false, true]) {
        for (const asker of askers) {
          for (const [whose, by] of Object.entries(documents)) {
            // The engine's shape of a redirect: the first document's frame is
            // still the initiator, and the window still shows it.
            // The account's page shows the request of its ceremony.
            const r = step(s, {...event, redirect, asker, by: whose === "the account's page" ? signed(event.kind ?? "sign-in") : by})
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
    for (const act of ["pick", "external", "reopen", "select", "connect", "menu", "update", "start"]) {
      for (const {name, event, acted} of PRESSES[act]) {
        for (const by of [SCREEN_PAGE, CHOOSER_DOC, atWays, RAIL_DOC, UPDATE_DOC]) {
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

test("the chooser leaving, a lock, a press on the rail and an end answer the pick with none, and the dialog's result after is dropped", () => {
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
  const leaving = run([...open, change, selects(BOB), picked(1, "/a")], true)
  assert.deepEqual(answers(leaving.effects), [of(null)], "a CYFR pressed on the rail")
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
    if (w.ended) return out
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
      assert.ok(!w.ended, `it ended (${w.ended}) after ${w.trace.join(" > ")}`)
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

test("every load of a page that takes a request, at any load of the account window, is the one reader's: none with no request, an expired one or another CYFR's", () => {
  const s = run(open, true).s
  for (const kind of ["sign-in", "confirmation"]) {
    const ok = kind === "sign-in" ? `${ACCOUNT}/account/new#name=&request=${fragment(requestFor(kind))}` : signed(kind)
    assert.deepEqual(step(s, accountNavigate({url: ok, kind})), {state: s, allow: true, do: []}, `${kind}: its own request`)
    for (const [url, why] of [[ACCOUNT + "/account/new", "no request"], [ACCOUNT + "/account/sign", "no request"],
      [`${ACCOUNT}/account/new#name=&request=${fragment(requestFor("sign-in", {expires_at: Date.now() - 1}))}`, "expired"],
      [signed(kind, {expires_at: Date.now() - 1}), "expired"],
      [`${ACCOUNT}/account/new#name=&request=${fragment(requestFor("sign-in", {audience: "https://bob.example", return: "https://bob.example/login"}))}`, "another CYFR's"],
      [signed(kind, {audience: "https://bob.example", return: "https://bob.example/login"}), "another CYFR's"]]) {
      assert.deepEqual(step(s, accountNavigate({url, kind})), {state: s, allow: false, do: [{unhop: true}]}, `${kind}: ${why}: ${url.split("#")[0]}`)
    }
  }
  assert.deepEqual(step(s, accountNavigate({url: signed("sign-in"), kind: null})), {state: s, allow: false, do: [{unhop: true}]},
    "no ceremony the content window now showing began")
})

const TOKEN = "ab".repeat(32)
const withSetup = (attempt = 1, setup = TOKEN) => ({type: "home", message: {...home(HOME, attempt).message, setup}})

test("main holds a setup token for its attempt alone, however that attempt ends", () => {
  const holding = [ready, withSetup()]
  assert.equal(run(holding, true).s.setup, TOKEN, "while it is proposed")
  const ends = {
    opened: [...holding, openedAt(HOME)],
    "a lock while proposed": [...holding, locked()],
    "cyfr gone": [...holding, {type: "gone", why: "it ended"}],
    "the screen shell ending": [...holding, {type: "ending"}],
    "a quit while proposed": [...holding, {type: "quit"}],
    "a quit once ended": [...holding, {type: "gone", why: "it ended"}, {type: "quit"}],
  }
  for (const [end, events] of Object.entries(ends)) {
    const {s} = run(events, true)
    assert.ok(!s.setup, `${end}: no token held (${s.name})`)
    assert.ok(!JSON.stringify(s).includes(TOKEN), `${end}: nowhere in main's state`)
  }
  assert.equal(run([...holding, withSetup(2, "cd".repeat(32))], true).s.setup, "cd".repeat(32), "a newer proposal's replaces it")
  assert.equal(run([...holding, home(HOME, 2)], true).s.setup, "", "a newer proposal with none ends it")
})

test("an attempt's number only goes up: a home not above the highest proposed changes nothing, after a lock or a departure to the chooser too", () => {
  const newer = run([ready, withSetup(2)], true).s
  for (const older of [withSetup(1, "cd".repeat(32)), home(HOME, 1), withSetup(2, "cd".repeat(32))]) {
    assert.deepEqual(step(newer, older), {state: newer, do: []}, `${newer.name}: attempt ${older.message.attempt}`)
  }
  const ends = {
    "a lock while proposed and its end": [ready, withSetup(2), locked(), forgot],
    "a lock and its end": [ready, withSetup(2), openedAt(HOME, 2), locked(), forgot],
    "a departure": [ready, withSetup(2), openedAt(HOME, 2), selects(BOB), parted(1), leftOf(1)],
  }
  for (const [end, events] of Object.entries(ends)) {
    const back = run(events, true).s
    assert.equal(back.name, "chooser", end)
    for (const older of [withSetup(2, "cd".repeat(32)), withSetup(1, "cd".repeat(32))]) {
      assert.deepEqual(step(back, older), {state: back, do: []}, `${end}, at ${back.name}: attempt ${older.message.attempt} again`)
    }
    assert.equal(step(back, withSetup(3)).state.name, "proposed", `${end}: the next attempt is proposed`)
  }
})

test("on the box's screen a home's setup token is dropped as it arrives, so nothing queued holds one, and an older home never replaces the queued next", () => {
  const SCREEN = {type: "ready", url: "http://127.0.0.1:7340/"}
  const onScreen = (events) => {
    let s = initial(false, {proxy: "", resolver: ""}, "/home/alice/cyfr")
    for (const e of events) s = step(s, e).state
    return s
  }
  assert.ok(!JSON.stringify(onScreen([SCREEN, withSetup(1)])).includes(TOKEN), "taken: no token")
  const queued = [SCREEN, withSetup(1), taken, openedAt(HOME), locked(HOME), withSetup(3)]
  const s = onScreen(queued)
  assert.equal(s.name, "locking")
  assert.equal(s.wanted.attempt, 3, "the next attempt queued")
  assert.ok(!JSON.stringify(s).includes(TOKEN), "queued: no token")
  assert.deepEqual(step(s, withSetup(2, "cd".repeat(32))), {state: s, do: []}, "an older home over the queued next changes nothing")
  for (const [end, e] of [["quit", {type: "quit"}], ["gone", {type: "gone", why: "it ended"}], ["ending", {type: "ending"}]]) {
    const after = step(s, e).state
    assert.ok(!JSON.stringify(after).includes(TOKEN), `${end} with a home queued: no token`)
  }
})
