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
//   taking     cyfr proposed `home` as its `attempt`, and the kept storage
//              is being made that CYFR's own (owner.js), which is the one
//              way in for every road that names a CYFR. One take runs at a
//              time: a proposal meanwhile replaces what is wanted and
//              nothing else, and only the current attempt is answered,
//              home-ready or home-failed, as the take ends
//   proposed   main answered `attempt` home-ready; it still keeps to none
//   open       cyfr committed `home`; main keeps to it, and takes no other
//   locking    a lock runs: the content is closed; it ends once cyfr's
//              locked has arrived (`barrier`) and what the lock forgets
//              is forgotten (`forgotten`); main then keeps to the CYFR it
//              kept to before the lock if locked names that same one, and
//              to none otherwise
//   ended      cyfr is gone, the app quits or starts again on another
//              route; nothing opens again
//
// A lock is the device's, never the computer's: the app does not lock
// when the computer locks or sleeps, when a page is lost (it is shown
// again) or as it quits. There are four:
//   cyfr's locked, unasked   the device's session ended (its Lock, or its
//                            connection lost): the content's storage is
//                            forgotten with it
//   the company page         the app offers no company sign-in
//   sent to sign in          on the passkey road, the CYFR sent the
//                            content to its sign-in page: nobody is signed
//                            in, so the chooser shows both ways on
//   Connect to another CYFR  on the passkey road, the chooser's: the
//                            storage is cleared first, and only then is
//                            cyfr told to leave the CYFR open; uncleared,
//                            cyfr is told to lock and keeps it
// Only the first and the fourth forget, and no end does: on the passkey
// road the sign-in is the CYFR's ordinary browser session, kept across
// quitting and starting again and ended by signing out in Prism or by
// that CYFR. A clear that fails says so on the chooser. Where it was for
// another CYFR it is `uncleared`: as the Connect's answer where it was for
// a proposal (home-failed), which is no lock and touches no other attempt,
// or after Connect to another CYFR. Where a lock forgot it is
// `unforgotten`, which speaks of no other CYFR.
//
// The box's screen (`screen`, its project; app.js) is the six-word road
// with no chooser: cyfr's first page is the device's own, at loopback's
// root, and the content window shows it again wherever the chooser would
// show, after every lock and after a failed load of the CYFR's. There
// every lost or failed page ends on that page or in a lock: a page lost,
// the content's or a confirmation's, and a failed load of the device's own
// page are each a lock, and so is cyfr's end, after which the app quits,
// to be started again locked; on a desktop a lost page is shown again and
// a lost confirmation is closed alone. cyfr proposes its CYFR again after
// every lock (cmd/screen_app.go), and its locked there names none: a
// proposal heard while a lock runs is `wanted`, taken once the lock has
// settled, so whatever order the messages and the takes and clears come
// in, main ends keeping to that CYFR on the device's page. Its last lock,
// at its end, says ending in place of locked: main closes at once and
// ends as at cyfr's end, settling no lock, so whatever is still to arrive
// (a forget answered, the exit), no window opens for a cyfr that is going.
//
// A CYFR's page whose load failed, as the engine reports it, is no lock:
// the content window shows the chooser saying so (`unanswered`), and
// nothing is closed or forgotten. That notice is that chooser's alone: a
// lock's own load can fail just before the lock is heard, and the lock's
// chooser has nothing of it to tell.
//
// What the chooser tells is main's alone to decide: a notice comes with a
// load of the chooser main makes for what it observed (chooser, back) or
// as cyfr's answer to main's home-failed, and no page can make such a
// load (policy.js chooserPath, bootstrap.go's script).
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
//                            account window and cancel any ceremony
//   forget                   clear the content session's storage; answers
//                            a forgot event, saying whether it is cleared
//   take                     make the kept storage the CYFR's that is
//                            wanted when the take ends; answers a taken
//                            event, saying whether it is
//   root {home}              load that CYFR's root into the content window,
//                            the kept storage being its own
//   send {type, fields}      a message to cyfr
//   chooser {notices}        open the content window at the chooser
//   back {notices}           show the chooser in the content window as it
//                            stands, its session as it is
//   relaunch {proxy, resolver}  once forgotten, or the wait for it is up
//                            (never on the box's screen)
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

import {LOOPBACK, accountLoad, contentNavigation, contentOpen, homeMessage, parse} from "./policy.js"
import {absolute} from "./process.js"

/** The state main starts in. */
export function initial(accountRoad, route = {proxy: "", resolver: ""}, screen = "") {
  return {name: "starting", accountRoad: accountRoad && !screen, screen, readyURL: "", home: "", account: "", route, returning: null,
    notices: [], picks: 0, picking: 0, pickFor: null}
}

/** What main keeps to in state `s`, as the policies read it. */
export const kept = (s) => s.name === "open"
  ? {home: s.home, account: s.account, accountRoad: s.accountRoad}
  : {home: "", account: "", accountRoad: s.accountRoad}

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
const withdrawn = (s, effects = []) => same(s.returning ? {...s, returning: null} : s, effects)
const adding = (notices, notice) => !notice || notices.includes(notice) ? notices : [...notices, notice]
const atChooser = (url) => {
  const u = parse(url)
  return !!u && u.origin === LOOPBACK && u.pathname === "/bootstrap/"
}
// The chooser's Connect to another CYFR: an address main alone answers,
// never loaded.
const ANOTHER = LOOPBACK + "/bootstrap/another"
// Its Try again, the same way: the CYFR open, at its root.
const AGAIN = LOOPBACK + "/bootstrap/again"
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

/**
 * Every decision main takes from a navigation as the person pressing
 * something, by name: the window it is pressed in, the document that
 * offers it (`by`, asked of the one that began the navigation), where it
 * goes (`to`) and what follows (`then`). `pressed` is their one rule.
 */
export const ACTS = {
  // Connect to another CYFR, on the chooser.
  another: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => s.accountRoad && s.name === "open" && e.url === ANOTHER,
    then: (s) => ({...leave(s), allow: false})},
  // Try again, on the chooser of a CYFR whose page did not load, which
  // comes here only once cyfr answered at the press (bootstrap.go onward).
  again: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => s.accountRoad && s.name === "open" && e.url === AGAIN,
    then: (s) => ({state: {...s, notices: []}, allow: false, do: [{root: {home: s.home}}]})},
  // Change…, the folder CYFR is set up in on this computer, on the
  // chooser: the system's dialog, one at a time. The box's screen has no
  // chooser, and none of its acts.
  pick: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => !s.screen && pickAsked(e.url) !== null,
    then: (s, e) => s.picking ? {state: s, allow: false, do: []}
      : {state: {...s, picks: s.picks + 1, picking: s.picks + 1, pickFor: pickAsked(e.url)}, allow: false, do: [{pick: {id: s.picks + 1}}]}},
  // Docker's page on installing it, linked from the chooser.
  external: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => !s.screen && EXTERNAL.includes(e.url),
    then: (s, e) => ({state: s, allow: false, do: [{external: {url: e.url}}]})},
  // A way on from the chooser: the passkey's, or this computer's key's.
  onward: {window: "content", by: (_, url) => atChooser(url),
    to: (s, e) => contentNavigation(e, kept(s)) === "allow",
    then: (s) => ({state: {...s, notices: []}, allow: true, do: []})},
  // Sign in with your account, on a page of the CYFR: the account hop.
  hop: {window: "content", by: (s, url) => s.name === "open" && parse(url)?.origin === s.home,
    to: (s, e) => contentNavigation(e, kept(s)) === "hop",
    then: (s, e) => ({state: s, allow: false, do: [{hop: {url: e.url, kind: "sign-in"}}]})},
  // A ceremony's answer, from the account service's page.
  answer: {window: "account", by: (s, url) => accountLoad(url, kept(s)) === "allow",
    to: (s, e) => !!e.kind && accountLoad(e.url, kept(s)) === "return",
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
  return Object.values(ACTS).find((act) => act.window === e.window && act.by(s, e.by) && act.to(s, e))
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

// A home naming a CYFR on another route than main's: main must start
// again with it before it keeps to it.
const rerouted = (s, m) => (m.proxy ?? "") !== s.route.proxy || (m.resolver ?? "") !== s.route.resolver

// A lock from state s: the content closes at once. cyfr is told, unless
// it said locked itself (`heard`, its message): that is then the barrier
// passed and the device's session ended, which is forgotten.
function lock(s, why, notice, heard = null) {
  const [t, answer] = unpicked(s)
  const next = {...t, name: "locking", before: kept(s), notices: adding(s.notices, notice), barrier: heard !== null,
    keep: heard, forgotten: heard === null, returning: null}
  return {state: next, do: [{say: `locked: ${why}`}, ...answer, {close: true}, heard ? {forget: true} : {send: {type: "lock"}}]}
}

// Connect to another CYFR: the content closes and its storage is cleared
// before cyfr is told anything (the forgot event tells it).
function leave(s) {
  const [t, answer] = unpicked(s)
  const next = {...t, name: "locking", before: kept(s), barrier: false, keep: null, forgotten: false, leaving: true,
    returning: null}
  return {state: next, do: [{say: "locked: the person left this CYFR"}, ...answer, {close: true}, {forget: true}]}
}

// A lock past its barrier that has forgotten what it forgets: main keeps to the
// CYFR it kept to before the lock when cyfr's locked names that same one,
// and to none otherwise, and shows the chooser. A locked never gives main
// a CYFR it did not keep to already.
function settle(s) {
  if (!s.barrier || !s.forgotten) return same(s)
  const m = s.keep
  const again = !!m.home && m.home === s.before.home && m.account === s.before.account
  const next = {name: again ? "open" : "chooser", accountRoad: s.accountRoad, screen: s.screen, readyURL: s.readyURL,
    home: again ? m.home : "", account: again ? m.account : "", route: s.route, returning: null, notices: s.notices,
    picks: s.picks, picking: 0, pickFor: null}
  if (!s.wanted) return {state: next, do: [{chooser: s.notices}]}
  const taken = step(next, {type: "home", message: s.wanted})
  return {state: taken.state, do: [{chooser: s.notices}, ...taken.do]}
}

/**
 * The state after event `e` in state `s`, and the effects that carry it
 * out: {state, do: [effect]}.
 */
export function step(s, e) {
  // Once ended, only quitting does anything: the app goes.
  if (s.name === "ended") return same(s, e.type === "quit" ? [{quit: true}] : [])
  switch (e.type) {
    // ---- cyfr ----
    case "ready":
      if (s.name !== "starting" || (s.screen ? e.url !== LOOPBACK + "/" : !e.url.startsWith(LOOPBACK + "/bootstrap/#token="))) {
        return stopped(s, "its first page was not the chooser")
      }
      return {state: {...s, name: "chooser", readyURL: e.url}, do: [{say: "ready"}, {chooser: []}]}
    case "home": {
      const m = e.message
      // From before the lock; on the screen, the proposal after it.
      if (s.name === "locking") return s.screen ? same({...s, wanted: m}) : same(s)
      if (!["chooser", "taking", "proposed"].includes(s.name) || !homeMessage(m)) {
        return stopped(s, "it named a CYFR this app does not open")
      }
      if (rerouted(s, m)) {
        // The screen's app is started on its CYFR's route by its launcher
        // (cmd/screen.go, cyfr screen app), never by itself.
        return s.screen ? stopped(s, "it named a route the app was not started on, which the screen's launcher starts it on")
          : ending(s, {relaunch: {proxy: m.proxy ?? "", resolver: m.resolver ?? ""}})
      }
      return {state: {...s, name: "taking", home: m.home, account: m.account, attempt: m.attempt, device: m.road === "device", returning: null},
        do: [{say: `home: ${m.home}`}, ...(s.name === "taking" ? [] : [{take: true}])]}
    }
    case "taken": {
      if (s.name !== "taking") return same(s) // locked away, or ended
      const fields = {home: s.home, attempt: s.attempt}
      if (e.taken) return {state: {...s, name: "proposed"}, do: [{send: {type: "home-ready", fields}}]}
      return {state: {...s, name: "chooser", home: "", account: ""},
        do: [{say: "not taken: the kept sign-in could not be cleared"}, {send: {type: "home-failed", fields}}]}
    }
    case "opened":
      if (s.name === "locking") return same(s) // from before the lock
      if (s.name !== "proposed" || e.home !== s.home) return stopped(s, "it opened a CYFR this app was not keeping to")
      // A CYFR that opens at the device's pages (home's road) loads none
      // of its own: the chooser goes to those pages, on either road.
      return s.accountRoad && !s.device ? same({...s, name: "open", notices: []}, [{root: {home: s.home}}]) : same({...s, name: "open"})
    case "locked": {
      const m = e.message
      if (s.name === "starting") return same(s)
      if (s.name === "locking") return settle({...s, barrier: true, keep: m})
      return lock(s, "the device locked", "", m)
    }
    case "ending":
      return step(s, {type: "gone", why: "the screen shell is ending"})
    case "gone":
      return stopped(s, e.why)

    // ---- the system, the windows, the person ----
    case "forgot": {
      if (s.name !== "locking") return same(s)
      const notices = e.cleared ? s.notices : adding(s.notices, s.leaving ? "uncleared" : "unforgotten")
      if (!s.leaving) return settle({...s, forgotten: true, notices})
      // cyfr answers what it is sent now with a locked of its own.
      return same({...s, leaving: false, forgotten: true, notices: e.cleared ? [] : notices},
        [{send: {type: e.cleared ? "leave" : "lock"}}])
    }
    case "lost":
      if (!s.screen) return same(s, e.window === "child" ? [] : [{reload: true}])
      return ["starting", "locking"].includes(s.name) ? same(s)
        : lock(s, e.window === "child" ? "a confirmation's page was lost" : "the page was lost", "")
    case "quit":
      return ending(s, {quit: true})
    case "second-instance":
      return same(s, [{show: true}])
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
    case "load-failed":
      if (s.screen && e.code !== ABORTED && parse(e.url)?.origin === LOOPBACK && !["starting", "locking"].includes(s.name)) {
        return lock(s, `the device's own page did not load (${e.code})`, "")
      }
      if (e.code === ABORTED || s.name !== "open" || parse(e.url)?.origin !== s.home) return withdrawn(s)
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
    case "account-navigate": {
      if (e.target !== "top") return {state: s, allow: false, do: []}
      if (["starting", "locking"].includes(s.name)) return {state: s, allow: false, do: [{unhop: true}]}
      if (accountLoad(e.url, kept(s)) === "allow") return {state: s, allow: true, do: []}
      const act = pressed(s, e)
      return act ? act.then(s, e) : {state: s, allow: false, do: [{unhop: true}]}
    }
  }
  return same(s)
}
