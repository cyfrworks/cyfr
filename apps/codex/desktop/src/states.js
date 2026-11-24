// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What main does: its states, and for each event in each state what
// follows. Every event main hears, from cyfr, from a window or from the
// system, goes through `step`, which answers the next state and the
// effects main carries out in order (app.js); nothing else decides.
//
// The states:
//   starting   cyfr runs and has not said ready
//   chooser    the chooser or the device's pages show; main keeps to no CYFR
//   proposed   cyfr proposed `home` as its `attempt` and main answered it
//              home-ready at once: what main keeps of a CYFR is that
//              CYFR's own by its address (policy.js homePartition), so
//              nothing is made or cleared for a proposal, and a storage is
//              opened only once cyfr committed it. It still keeps to none
//   open       cyfr committed `home`; main keeps to it, and takes no other
//   locking    a lock runs: the content is closed; it ends once cyfr's
//              locked has arrived (`barrier`) and what the lock forgets
//              is forgotten (`forgotten`); main then keeps to the CYFR it
//              kept to before the lock if locked names that same one, and
//              to none otherwise. A departure, a press on the rail that
//              leaves the CYFR open, waits instead for both cyfr's left
//              answering its leave's id (`departing`) and the end of every
//              page of that CYFR and of its connections (`parted`): no
//              locked, no left of another id and no other teardown ends
//              it. Its deadline (DEPARTURE_MS) passed first, main does not
//              trust that cyfr to have let go: it ends it and starts a
//              fresh one, which opens nothing by itself (`unleft`)
//   ended      cyfr is gone and the app quits; nothing opens again
//
// A lock is the device's, never the computer's: the app does not lock
// when the computer locks or sleeps, when a page is lost (it is shown
// again) or as it quits. There are three:
//   cyfr's locked, unasked   the device's session ended (its Lock, or its
//                            connection lost): the content's storage is
//                            forgotten with it
//   the company page         the app offers no company sign-in
//   sent to sign in          on the passkey road, the CYFR sent the
//                            content to its sign-in page: nobody is signed
//                            in, so the chooser shows both ways on
// Only the first forgets, and no end and no departure does: on the
// passkey road the sign-in is the CYFR's ordinary browser session, one
// for each CYFR, kept across quitting, starting again and switching to
// another CYFR, and ended by signing out in Prism, by that CYFR, or by
// Forget on the rail, which cyfr carries out by asking main to erase each
// store (erase). A clear that fails says so on the chooser
// (`unforgotten`).
//
// The rail, the list of CYFRs beside the content, is main's: cyfr serves
// its page and its read alone, and every press there is a navigation main
// answers (ACTS, window "rail") and never loads. Selecting another CYFR
// leaves the one open (a departure) and then shows the chooser connecting
// to it; Connect and Set up leave it the same way; Forget is the row's
// menu, which main draws and confirms with the person, then leaves that
// CYFR if it is open, and only then tells cyfr to forget it.
//
// The box's screen (`screen`, its project; app.js) is the six-word road
// with the same rail and chooser, and what only the box has: This box on
// the rail (`box`), the CYFR its folder names, opened by the chooser; no
// setup on this computer and no folder dialog. There every lost or failed
// page ends in a lock: a page lost, the content's or a confirmation's, and
// a failed load of the device's own page are each a lock, and so is cyfr's
// end, after which the app quits, to be started again locked; on a desktop
// a lost page is shown again and a lost confirmation is closed alone. Its
// last lock, at cyfr's end, says ending in place of locked: main closes at
// once and ends as at cyfr's end, settling no lock, so whatever is still to
// arrive (a forget answered, the exit), no window opens for a cyfr that is
// going.
//
// A CYFR's page whose load failed, as the engine reports it, is no lock:
// the content window shows the chooser saying so (`unanswered`), and
// nothing is closed or forgotten. A CYFR whose route could not be set on
// the store that would load it loads nothing there, and the chooser says
// that (`unrouted`): once it was committed as that page's load failing,
// before (on the six-word road and the box's screen, where the route is
// set as cyfr proposes it) as the proposal failing, offered again. That notice is that chooser's alone: a
// lock's own load can fail just before the lock is heard, and the lock's
// chooser has nothing of it to tell.
//
// What the chooser tells is main's alone to decide: a notice comes with a
// load of the chooser main makes for what it observed (chooser, back),
// and no page can make such a load (policy.js chooserPath, bootstrap.go's
// script).
//
// What main takes for the person pressing something is in ACTS, and
// nowhere else.
//
// `picking` is the pick of a folder main has asked the system for (the
// chooser's Change…), numbered, or 0: one at a time, and each answered to
// cyfr once with folder-picked, the folder the dialog gave or none where
// the person cancelled, with the chooser's epoch and pick its address
// named (`pickFor`). A document committing in the content window, a lock
// and an end answer it at once with none, and a dialog's result for any
// other pick than the one outstanding is dropped.
//
// `notices` is what main has to tell and the person has not yet gone on
// from: every lock adds to it and carries it, and the chooser shows it and
// stays. Only a way on taken from the chooser, its top frame leaving it,
// clears it.
//
// `returning` is a sign-in's answer on its way into the content window,
// from its deliver effect to the one navigation that made:
//   sent       main's load is being made; the engine says that navigation
//              started within the call that makes it, so before delivered
//   landing    it started as a change of the fragment alone, which leaves
//              Prism's page standing though Prism reads an answer only as
//              its page loads: that navigation landing is the one reload
// Every other outcome withdraws it, and nothing reloads: another
// navigation starting (main's started as a whole document, or one that
// supersedes it, whatever its address), a document committing, a load
// failing, none started within the call, main's load call ending before
// it landed (resolved or rejected), another CYFR, a lock, an end.
//
// The effects (app.js carries each out at once, in order):
//   close                    destroy every content, confirmation and
//                            account view and cancel any ceremony
//   part {id}                once every page close destroyed is gone and
//                            its sessions' connections are closed,
//                            answers parted with id
//   deadline {id}            answers late with id after DEPARTURE_MS
//   restart                  end cyfr and start a fresh one
//   forget                   clear the content session's storage; answers
//                            a forgot event, saying whether it is cleared
//   erase {id, home, account}  clear that store, idempotently, and tell
//                            cyfr erased with id and whether it is empty
//   rail {url}               show the rail's page beside the content
//   menu {home}              the row's menu of the CYFR at home, which
//                            answers forget-confirmed once the person
//                            chose Forget and confirmed it
//   root {home, path, setup}  open the content at that CYFR's path, its
//                            root or its sign-in page, in its own kept
//                            storage, or with setup its setup page, the
//                            token in the fragment alone
//   send {type, fields}      a message to cyfr
//   prepare {home, attempt, proxy}  answer home-ready: on the six-word
//                            road and the box's screen once that CYFR's
//                            route (its proxy, none when empty) is set
//                            on the content's store showing, at once on
//                            the passkey road
//   chooser {notices}        open the content at the chooser; with
//                            connect, connecting to that CYFR; with way
//                            "setup", at setting up on this computer
//   back {notices, retry}    show the chooser in the content window as it
//                            stands, its session as it is; with retry,
//                            offering that CYFR again
//   end {why}                kill cyfr and tell the person (never on the
//                            box's screen)
//   quit                     once forgotten, or the wait for it is up,
//                            shut cyfr down and quit; on the box's screen
//                            the app's one end, at once (app.js)
//   hop {url, kind}, unhop
//   deliver {url}            load a sign-in's answer into the content
//                            window; answers delivered as that call
//                            returns, and load-ended as its promise settles
//   reload                   load the content window's page again
//   confirmation {url}       open a confirmation's answer in a window of
//                            the content's session
//   show                     bring the content window forward
//   external {url}           open url in the person's browser
//   pick {id}                ask the system for a folder in a dialog of
//                            the content window; answers picked with id
//   say {line}

import {LOOPBACK, accountLoad, contentNavigation, contentOpen, homeMessage, parse, railPress} from "./policy.js"
import {absolute} from "./process.js"

/** How long a departure waits for cyfr's left and the old pages' end. */
export const DEPARTURE_MS = 20_000

/** The state main starts in. */
export function initial(accountRoad, screen = "") {
  return {name: "starting", accountRoad: accountRoad && !screen, screen, readyURL: "", home: "", account: "", proxy: "", returning: null,
    notices: [], picks: 0, picking: 0, pickFor: null, leaves: 0, seen: 0}
}

/** What main keeps to in state `s`, as the policies read it. */
export const kept = (s) => s.name === "open"
  ? {home: s.home, account: s.account, proxy: s.proxy ?? "", accountRoad: s.accountRoad}
  : {home: "", account: "", proxy: "", accountRoad: s.accountRoad}

// The pick outstanding, if any, answered with none: the state without it
// and the answer.
const unpicked = (s) => s.picking
  ? [{...s, picking: 0, pickFor: null}, [{send: {type: "folder-picked", fields: {path: null, ...s.pickFor}}}]]
  : [s, []]

// Into ended, the way every end goes: close, then `last`.
function ending(s, last) {
  const [t, answer] = unpicked(s)
  return {state: {...t, name: "ended", returning: null}, do: [...answer, {close: true}, last]}
}
// cyfr's end, or the app's at what cyfr said, for why: on the box's screen
// the app's one end (quit), after the sentence, which its launcher answers
// with a start, locked; elsewhere cyfr is killed and a message says why.
const stopped = (s, why) => ending(s, s.screen ? {say: `cyfr ended: ${why}`, quit: true} : {end: why})
const same = (s, effects = []) => ({state: s, do: effects})
// A second launch with --quit (app.js), which ends the app as a quit
// does; on the box's screen its service is stopped instead, and the app is
// shown as at any second launch.
const askedToQuit = (s, e) => e.type === "second-instance" && e.quit === true && !s.screen
const withdrawn = (s, effects = []) => same(s.returning ? {...s, returning: null} : s, effects)
const adding = (notices, notice) => !notice || notices.includes(notice) ? notices : [...notices, notice]
export const atChooser = (url) => {
  const u = parse(url)
  return !!u && u.origin === LOOPBACK && u.pathname === "/bootstrap/"
}
const atRail = (url) => {
  const u = parse(url)
  return !!u && u.origin === LOOPBACK && u.pathname === "/rail/"
}
// What a press on the rail may do now: nothing while cyfr starts, a lock
// or a departure runs, or a proposal waits for its commit.
const railFree = (s) => ["chooser", "open"].includes(s.name)
// The rail's ways at the foot, by place: Set up CYFR on this computer on a
// desktop, This box on the box's screen.
const railWays = (s) => s.screen ? ["connect", "box"] : ["connect", "setup"]
// The chooser's Try again and its Sign in with your passkey: addresses
// main alone answers, never loaded, each the CYFR open in its own kept
// storage, at its root or at its sign-in page. A CYFR's page never loads
// in the chooser's view, whose storage is memory's (policy.js
// contentNavigation): a sign-in there would be lost at the next start.
const REOPEN = {[LOOPBACK + "/bootstrap/again"]: "/", [LOOPBACK + "/bootstrap/signin"]: "/login"}
// Its Change…, the same way: a folder of the system's dialog, for the
// pick the chooser shows, named in its address as the epoch it was shown
// in and the picks answered before it, which the answer carries back.
function pickAsked(url) {
  const u = parse(url)
  if (!u || u.origin !== LOOPBACK || u.pathname !== "/bootstrap/pick" || u.hash) return null
  const q = u.searchParams, whole = (v) => /^(0|[1-9][0-9]{0,15})$/.test(v ?? "") && Number(v) <= Number.MAX_SAFE_INTEGER
  if ([...q.keys()].length !== 2 || !whole(q.get("epoch")) || !whole(q.get("pick"))) return null
  return {epoch: Number(q.get("epoch")), pick: Number(q.get("pick"))}
}

/**
 * The pages the chooser may link to, Docker's own on installing it, each
 * opened in the person's browser and never in the app's window
 * (tests/fixtures/desktop-process.json external_pages).
 */
export const EXTERNAL = ["https://www.docker.com/products/docker-desktop/", "https://docs.docker.com/engine/install/"]
// The engine's code for a load given up: replaced, stopped or refused.
export const ABORTED = -3
// A load main did not begin because the route of the CYFR it is for could
// not be set on its store (app.js routedThen).
export const UNROUTED = "unrouted"

/**
 * Every decision main takes from a navigation as the person pressing
 * something, by name: the window it is pressed in, the document that
 * offers it (`by`, asked of the one that began the navigation), where it
 * goes (`to`) and what follows (`then`). `pressed` is their one rule.
 */
export const ACTS = {
  // A CYFR of the rail, selected: the one open is shown; another is
  // opened by the chooser, connecting to it, once the one open is left.
  select: {window: "rail", by: (_, url) => atRail(url),
    to: (s, e) => railFree(s) && railPress(e.url)?.act === "select",
    then: (s, e) => {
      const home = railPress(e.url).home
      if (s.name === "open" && s.home === home) return {state: s, allow: false, do: [{show: true}]}
      return {...away(s, {connect: home}), allow: false}
    }},
  // Connect, Set up CYFR on this computer and This box, on the rail: the
  // chooser at that way, once the CYFR open is left.
  connect: {window: "rail", by: (_, url) => atRail(url),
    to: (s, e) => railFree(s) && railWays(s).includes(railPress(e.url)?.act),
    then: (s, e) => {
      const act = railPress(e.url).act
      return {...away(s, act === "connect" ? {} : {way: act}), allow: false}
    }},
  // A row's menu on the rail, which main draws: its Forget is confirmed
  // there (forget-confirmed).
  menu: {window: "rail", by: (_, url) => atRail(url),
    to: (s, e) => railFree(s) && railPress(e.url)?.act === "menu",
    then: (s, e) => ({state: s, allow: false, do: [{menu: {home: railPress(e.url).home}}]})},
  // Try again, on the chooser of a CYFR whose page did not load, and Sign
  // in with your passkey, on the chooser of a CYFR that asked for a
  // sign-in: each comes here only once cyfr answered at the press
  // (bootstrap.go onward), and opens the CYFR open in its own view.
  reopen: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => s.accountRoad && s.name === "open" && Object.hasOwn(REOPEN, e.url),
    then: (s, e) => ({state: {...s, notices: []}, allow: false, do: [{root: {home: s.home, path: REOPEN[e.url]}}]})},
  // Change…, the folder CYFR is set up in on this computer, on the
  // chooser: the system's dialog, one at a time. The box's screen sets
  // nothing up, and has neither this nor Docker's page.
  pick: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => !s.screen && pickAsked(e.url) !== null,
    then: (s, e) => s.picking ? {state: s, allow: false, do: []}
      : {state: {...s, picks: s.picks + 1, picking: s.picks + 1, pickFor: pickAsked(e.url)}, allow: false, do: [{pick: {id: s.picks + 1}}]}},
  // Docker's page on installing it, linked from the chooser.
  external: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => !s.screen && EXTERNAL.includes(e.url),
    then: (s, e) => ({state: s, allow: false, do: [{external: {url: e.url}}]})},
  // A way on from the chooser: this computer's key's, the device's pages.
  onward: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => contentNavigation(e, kept(s)) === "allow",
    then: (s) => ({state: {...s, notices: []}, allow: true, do: []})},
  // Sign in with your account, on a page of the CYFR: the account hop.
  hop: {window: "content", by: (s, url) => s.name === "open" && parse(url)?.origin === s.home,
    to: (s, e) => contentNavigation(e, kept(s)) === "hop",
    then: (s, e) => ({state: s, allow: false, do: [{hop: {url: e.url, kind: "sign-in"}}]})},
  // A ceremony's answer, from the account service's page.
  answer: {window: "account", by: (s, url, e) => accountLoad(url, kept(s), e.kind) === "allow",
    to: (s, e) => !!e.kind && accountLoad(e.url, kept(s), e.kind) === "return",
    then: (s, e) => e.kind === "confirmation"
      ? {state: s, allow: false, do: [{unhop: true}, {confirmation: {url: e.url}}]}
      : {state: {...s, returning: {url: e.url, at: "sent"}}, allow: false, do: [{unhop: true}, {deliver: {url: e.url}}]}}
}

// The act navigation `e` is, if any: none is a redirect, and each is begun
// by the top frame's own document, the one that offers it, at its origin.
// The engine keeps naming that frame as a redirect's initiator, so the
// initiator alone proves no press.
function pressed(s, e) {
  if (e.redirect || e.target !== "top" || e.asker !== "top") return undefined
  return Object.values(ACTS).find((act) => act.window === e.window && act.by(s, e.by, e) && act.to(s, e))
}

// Whether a load main allows is the CYFR sending the content's top frame
// to its sign-in page: by a redirect, or by one of its other pages. That
// page's own loads are not, nor is a way on taken to it (ACTS, read first).
function sentToSignIn(s, e) {
  if (!s.accountRoad || e.window !== "content" || e.target !== "top") return false
  const signIn = (u) => !!u && u.origin === kept(s).home && u.pathname === "/login"
  const [to, from] = [parse(e.url), parse(e.showing)]
  return signIn(to) && !signIn(from) && (!!e.redirect || from?.origin === kept(s).home)
}

// A lock from state s: the content closes at once. cyfr is told, unless
// it said locked itself (`heard`, its message): that is then the barrier
// passed and the device's session ended, which is forgotten. A lock while
// a CYFR is proposed holds on to that proposal, its route included: cyfr
// may have committed it as the lock began, its opened crossing the lock,
// and its locked then names it, which main keeps to (settle) as cyfr does.
function lock(s, why, notice, heard = null) {
  const [t, answer] = unpicked(s)
  const before = s.name === "proposed" ? {home: s.home, account: s.account, proxy: s.proxy ?? "", accountRoad: s.accountRoad} : kept(s)
  const next = {...t, name: "locking", before, notices: adding(s.notices, notice), barrier: heard !== null,
    keep: heard, forgotten: heard === null, returning: null}
  return {state: next, do: [{say: `locked: ${why}`}, ...answer, {close: true}, heard ? {forget: true} : {send: {type: "lock"}}]}
}

// Away from what the content shows, to `then`: the chooser, connecting to
// a CYFR (connect) or at a way (way), or a CYFR forgotten (forget). From a
// CYFR open that is a departure: its pages close at once, cyfr is told to
// leave it, numbered as this run's next departure, and `then` follows
// only once cyfr's left names that number and those pages and their
// connections have ended (parted), within DEPARTURE_MS. Nothing of that
// CYFR's is forgotten. From the chooser `then` follows at once.
function away(s, then) {
  const [t, answer] = unpicked(s)
  if (s.name !== "open") return beyond({...t, returning: null}, then, [...answer, {close: true}])
  const id = s.leaves + 1
  const next = {...t, name: "locking", before: kept(s), barrier: false, keep: null, forgotten: true, returning: null,
    leaves: id, departing: id, parted: false, then}
  return {state: next, do: [{say: "left: the person chose another"}, ...answer, {close: true}, {part: {id}},
    {send: {type: "leave", fields: {id}}}, {deadline: {id}}]}
}

// What follows a way away from the content, in chooser state `s`.
function beyond(s, then, effects = []) {
  const next = {...s, name: "chooser", home: "", account: "", proxy: "", notices: []}
  if (then.forget) return {state: next, do: [...effects, {send: {type: "forget", fields: {home: then.forget}}}, {chooser: []}]}
  return {state: next, do: [...effects, {chooser: [], ...then}]}
}

// A lock past its barrier that has forgotten what it forgets: main keeps to the
// CYFR it kept to before the lock when cyfr's locked names that same one,
// and to none otherwise, and shows the chooser. A locked never gives main
// a CYFR it did not keep to already.
function settle(s) {
  if (s.departing) return s.departed && s.parted ? beyond(chooserOf(s), s.then) : same(s)
  if (!s.barrier || !s.forgotten) return same(s)
  const m = s.keep
  const again = !!m.home && m.home === s.before.home && m.account === s.before.account
  const next = {name: again ? "open" : "chooser", accountRoad: s.accountRoad, screen: s.screen, readyURL: s.readyURL,
    railURL: s.railURL, home: again ? m.home : "", account: again ? m.account : "", proxy: again ? s.before.proxy : "", returning: null, notices: s.notices,
    picks: s.picks, picking: 0, pickFor: null, leaves: s.leaves, seen: s.seen}
  return {state: next, do: [{chooser: s.notices}]}
}

// The chooser's state after a departure: main keeps to none.
const chooserOf = (s) => ({name: "chooser", accountRoad: s.accountRoad, screen: s.screen, readyURL: s.readyURL, railURL: s.railURL,
  home: "", account: "", proxy: "", returning: null, notices: s.notices, picks: s.picks, picking: 0, pickFor: null,
  leaves: s.leaves, seen: s.seen})

/**
 * The state after event `e` in state `s`, and the effects that carry it
 * out: {state, do: [effect]}. A home's setup token lives for its attempt
 * alone: from that home message while it is proposed, and no longer,
 * however the attempt ends (opened, a lock, an end or a quit); it travels
 * on only in the root effect of its opening.
 */
export function step(s, e) {
  const next = advance(s, e)
  return next.state.setup && next.state.name !== "proposed" ? {...next, state: {...next.state, setup: ""}} : next
}

function advance(s, e) {
  // Once ended, only quitting does anything: the app goes.
  if (s.name === "ended") return same(s, e.type === "quit" || askedToQuit(s, e) ? [{quit: true}] : [])
  switch (e.type) {
    // ---- cyfr ----
    case "ready": {
      const rail = e.message?.rail ?? ""
      if (s.name !== "starting" || !e.url.startsWith(LOOPBACK + "/bootstrap/#token=") || !rail.startsWith(LOOPBACK + "/rail/#read=")) {
        return stopped(s, "its first page was not the chooser")
      }
      return {state: {...s, name: "chooser", readyURL: e.url, railURL: rail},
        do: [{say: "ready"}, {rail: {url: rail}}, {chooser: s.notices}]}
    }
    case "home": {
      // The box's screen makes its first person by the device's pages: a
      // home's setup token is dropped as it arrives, so none is ever held.
      const {setup: _dropped, ...rest} = e.message
      const m = s.screen ? rest : e.message
      // An attempt's number only goes up: a home not above the highest
      // proposed, and the one queued, changes nothing, in any state.
      if (Number.isSafeInteger(m.attempt) && m.attempt <= s.seen) return same(s)
      const seen = Number.isSafeInteger(m.attempt) ? m.attempt : s.seen
      // From before the lock.
      if (s.name === "locking") return same({...s, seen})
      if (!["chooser", "proposed"].includes(s.name) || !homeMessage(m)) {
        return stopped(s, "it named a CYFR this app does not open")
      }
      return {state: {...s, name: "proposed", home: m.home, account: m.account, proxy: m.proxy ?? "", attempt: m.attempt, seen, setup: m.setup ?? "",
        returning: null},
        do: [{say: `home: ${m.home}`}, {prepare: {home: m.home, attempt: m.attempt, proxy: m.proxy ?? ""}}]}
    }
    case "opened":
      if (s.name === "locking") return same(s) // from before the lock
      if (s.name !== "proposed" || e.home !== s.home || e.message.attempt !== s.attempt) {
        return stopped(s, "it opened a CYFR this app was not keeping to")
      }
      // On the passkey road main loads the CYFR's own page: its setup page
      // while no one is set up there (home's setup token, held until here
      // and no longer), else its root. On the six-word road the chooser
      // goes to the device's pages.
      return s.accountRoad
        ? same({...s, name: "open", setup: "", notices: []}, [{root: {home: s.home, path: "/", ...(s.setup ? {setup: s.setup} : {})}}])
        : same({...s, name: "open", setup: ""})
    case "locked": {
      const m = e.message
      if (s.name === "starting") return same(s)
      // The lock a leave makes says it too: the departure waits for left.
      if (s.name === "locking" && s.departing) return same(s)
      if (s.name === "locking") return settle({...s, barrier: true, keep: m})
      return lock(s, "the device locked", "", m)
    }
    case "left":
      if (s.name !== "locking" || !s.departing || s.departed || e.message.id !== s.departing) return same(s)
      return settle({...s, departed: true})
    // The pages of the CYFR left, and their connections, have ended.
    case "parted":
      if (s.name !== "locking" || !s.departing || s.parted || e.id !== s.departing) return same(s)
      return settle({...s, parted: true})
    // The departure's deadline: a cyfr that did not answer in time is ended
    // and a fresh one started, which reads the list and opens nothing by
    // itself: the chooser it shows says why (unleft), so it resumes none.
    case "late":
      if (s.name !== "locking" || !s.departing || e.id !== s.departing) return same(s)
      return {state: {...initial(s.accountRoad, s.screen), notices: adding(s.notices, "unleft")},
        do: [{say: "cyfr did not let go of the CYFR left in time: starting it again"}, {restart: true}]}
    // cyfr asks for a store of a CYFR it forgets to be erased; never the
    // open one's, which cyfr does not forget.
    case "erase": {
      const m = e.message
      const open = ["open", "proposed"].includes(s.name) && s.home === m.home || s.name === "locking" && s.before?.home === m.home
      return same(s, open ? [{send: {type: "erased", fields: {id: m.id, ok: false}}}]
        : [{erase: {id: m.id, home: m.home, account: m.account ?? ""}}])
    }
    case "ending":
      return step(s, {type: "gone", why: "the screen shell is ending"})
    case "gone":
      return stopped(s, e.why)

    // ---- the system, the windows, the person ----
    case "forgot": {
      if (s.name !== "locking" || s.departing) return same(s)
      return settle({...s, forgotten: true, notices: e.cleared ? s.notices : adding(s.notices, "unforgotten")})
    }
    // The person chose Forget in a row's menu and confirmed it: the CYFR
    // is left first if it is open. On the box's screen the CYFR open is
    // not forgotten from its own row (cyfr refuses it): from This box.
    case "forget-confirmed":
      if (!railFree(s) || !e.home) return same(s)
      if (s.screen && s.name === "open" && s.home === e.home) return same(s)
      return s.name === "open" && s.home === e.home ? away(s, {forget: e.home})
        : same(s, [{send: {type: "forget", fields: {home: e.home}}}])
    case "lost":
      if (!s.screen) return same(s, e.window === "child" ? [] : [{reload: true}])
      return ["starting", "locking"].includes(s.name) ? same(s)
        : lock(s, e.window === "child" ? "a confirmation's page was lost" : "the page was lost", "")
    case "quit":
      return ending(s, {quit: true})
    case "second-instance":
      return askedToQuit(s, e) ? ending(s, {quit: true}) : same(s, [{show: true}])
    // The system's dialog answered pick `id`: the folder, or null.
    case "picked":
      if (!s.picking || e.id !== s.picking) return same(s)
      return same({...s, picking: 0, pickFor: null},
        [{send: {type: "folder-picked", fields: {path: absolute(e.path) ? e.path : null, ...s.pickFor}}}])

    // The content window's top frame, as the engine reports it, read for
    // the answer on its way there (`returning`) alone.
    case "started":
      return s.returning?.at === "sent" && e.sameDocument && e.url === s.returning.url
        ? same({...s, returning: {url: e.url, at: "landing"}}) : withdrawn(s)
    case "delivered":
      return s.returning?.at === "landing" ? same(s) : withdrawn(s)
    case "landed":
      return withdrawn(s, s.returning?.at === "landing" && e.url === s.returning.url ? [{reload: true}] : [])
    case "committed": {
      const [t, answer] = unpicked(s)
      return withdrawn(t, answer)
    }
    // The proposal's route could not be set on the store that would load
    // it (app.js prepare): no home-ready went, nothing of it loaded, and
    // the chooser says why, offering it again.
    case "unrouted":
      if (s.name !== "proposed" || e.home !== s.home || e.attempt !== s.attempt) return same(s)
      return same({...s, name: "chooser", home: "", account: "", proxy: "", setup: ""},
        [{say: `unrouted: the route of ${e.home} could not be set`}, {back: adding(s.notices, "unrouted"), retry: e.home}])
    case "load-failed":
      if (s.screen && e.code !== ABORTED && parse(e.url)?.origin === LOOPBACK && !["starting", "locking"].includes(s.name)) {
        return lock(s, `the device's own page did not load (${e.code})`, "")
      }
      if (e.code === ABORTED || s.name !== "open" || parse(e.url)?.origin !== s.home) return withdrawn(s)
      if (e.code === UNROUTED) return withdrawn(s, [{say: "unrouted: the CYFR's route could not be set"}, {back: adding(s.notices, "unrouted")}])
      return withdrawn(s, [{say: `unanswered: the CYFR's page did not load (${e.code})`}, {back: adding(s.notices, "unanswered")}])
    case "load-ended":
      return e.url === s.returning?.url ? withdrawn(s) : same(s)

    // A load in a window of the content's own (the content window or a
    // confirmation window): a hop, the company page or being sent to
    // sign in acts, from the content window alone. Nothing loads before
    // ready or while locking.
    case "navigate": {
      if (["starting", "locking"].includes(s.name)) return {state: s, allow: false, do: []}
      const act = pressed(s, e)
      if (act) return act.then(s, e)
      // The rail's page loads nothing: a press is an act or nothing.
      if (e.window === "rail") return {state: s, allow: false, do: []}
      const where = contentNavigation(e, kept(s))
      if (where === "allow") {
        if (sentToSignIn(s, e)) return {...lock(s, "the CYFR asks for a sign-in", ""), allow: false}
        return {state: s, allow: true, do: []}
      }
      if (where === "company" && e.window === "content") {
        return {...lock(s, "the CYFR asks for a company sign-in", "company"), allow: false}
      }
      return {state: s, allow: false, do: []}
    }
    case "open-window": {
      if (["starting", "locking"].includes(s.name)) return {state: s, open: "deny", do: []}
      const what = contentOpen(e.url, kept(s))
      return {state: s, open: what === "child" ? "child" : "deny", do: what === "hop" ? [{hop: {url: e.url, kind: "confirmation"}}] : []}
    }
    // A load in the account window: its top frame shows the ceremony or
    // answers (ACTS), as the kind of ceremony the content window now showing
    // began (`kind`, none otherwise); anything else ends the ceremony, and so
    // does every top-frame load before ready and while locking, when no
    // ceremony may go on. A frame loads nothing and ends nothing, ever.
    // A navigation the account window's top frame started, however it
    // began: a page that takes a request goes on only as the one reader
    // reads it for the ceremony shown; anything else ends the ceremony but
    // the CYFR's /login, the answer's address. Only the page's own
    // navigation reaches that (main cancels it every time, so it never
    // lands here for a history move or a reload to find), and the engine
    // raises will-navigate after this, where the act takes it or ends the
    // ceremony.
    case "account-started": {
      const where = ["starting", "locking"].includes(s.name) ? "block" : accountLoad(e.url, kept(s), e.kind)
      return where === "allow" || where === "return" ? same(s) : same(s, [{unhop: true}])
    }
    case "account-navigate": {
      if (e.target !== "top") return {state: s, allow: false, do: []}
      if (["starting", "locking"].includes(s.name)) return {state: s, allow: false, do: [{unhop: true}]}
      if (accountLoad(e.url, kept(s), e.kind) === "allow") return {state: s, allow: true, do: []}
      const act = pressed(s, e)
      return act ? act.then(s, e) : {state: s, allow: false, do: [{unhop: true}]}
    }
  }
  return same(s)
}
