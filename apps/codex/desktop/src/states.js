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
//   taking     cyfr proposed `home`; main keeps to none until the kept
//              storage is that CYFR's own (owner.js), which is the one way
//              in for every road that names a CYFR
//   proposed   cyfr proposed `home`; main answered home-ready and keeps to it
//   open       cyfr committed `home`; main keeps to it
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
// again) or as it quits. There are five:
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
//   not taken                the kept storage could not be made the
//                            proposed CYFR's: nothing of it loads
// Only the first and the fourth forget, and no end does: on the passkey
// road the sign-in is the CYFR's ordinary browser session, kept across
// quitting and starting again and ended by signing out in Prism or by
// that CYFR. A clear that fails says so on the chooser (`uncleared`).
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
//   take {home}              make the kept storage that CYFR's own; answers
//                            a taken event, saying whether it is
//   root {home}              load that CYFR's root into the content window,
//                            the kept storage being its own
//   send {type, fields}      a message to cyfr
//   chooser {notices}        open the content window at the chooser
//   relaunch {proxy, resolver}  once forgotten
//   end {why}                kill cyfr and tell the person
//   quit                     once forgotten, shut cyfr down and quit
//   hop {url, kind}, unhop
//   deliver {url}            load a sign-in's answer into the content
//                            window; answers delivered as that call
//                            returns, and load-ended as its promise settles
//   reload                   load the content window's page again
//   confirmation {url}       open a confirmation's answer in a window of
//                            the content's session
//   show                     bring the content window forward
//   say {line}

import {LOOPBACK, accountLoad, contentNavigation, contentOpen, homeMessage, parse} from "./policy.js"

/** The state main starts in. */
export function initial(accountRoad, route = {proxy: "", resolver: ""}) {
  return {name: "starting", accountRoad, readyURL: "", home: "", account: "", route, returning: null, notices: []}
}

/** What main keeps to in state `s`, as the policies read it. */
export const kept = (s) => ["proposed", "open"].includes(s.name)
  ? {home: s.home, account: s.account, accountRoad: s.accountRoad}
  : {home: "", account: "", accountRoad: s.accountRoad}

// Into ended, the way every end goes: close, then `last`.
const ending = (s, last) => ({state: {...s, name: "ended", returning: null}, do: [{close: true}, last]})
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
const tookWayOn = (e) => e.window === "content" && e.target === "top" && atChooser(e.showing) && !atChooser(e.url)

// Whether a load main allows is the CYFR sending the content's top frame
// to its sign-in page: by a redirect, or by one of its other pages. A way
// on taken to that page (the chooser's), and that page's own loads, are
// not.
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
  const next = {...s, name: "locking", before: kept(s), notices: adding(s.notices, notice), barrier: heard !== null,
    keep: heard, forgotten: heard === null, returning: null}
  return {state: next, do: [{say: `locked: ${why}`}, {close: true}, heard ? {forget: true} : {send: {type: "lock"}}]}
}

// Connect to another CYFR: the content closes and its storage is cleared
// before cyfr is told anything (the forgot event tells it).
function leave(s) {
  const next = {...s, name: "locking", before: kept(s), barrier: false, keep: null, forgotten: false, leaving: true,
    returning: null}
  return {state: next, do: [{say: "locked: the person left this CYFR"}, {close: true}, {forget: true}]}
}

// A lock past its barrier that has forgotten what it forgets: main keeps to the
// CYFR it kept to before the lock when cyfr's locked names that same one,
// and to none otherwise, and shows the chooser. A locked never gives main
// a CYFR it did not keep to already.
function settle(s) {
  if (!s.barrier || !s.forgotten) return same(s)
  const m = s.keep
  const again = !!m.home && m.home === s.before.home && m.account === s.before.account
  const next = {name: again ? "open" : "chooser", accountRoad: s.accountRoad, readyURL: s.readyURL,
    home: again ? m.home : "", account: again ? m.account : "", route: s.route, returning: null, notices: s.notices}
  return {state: next, do: [{chooser: s.notices}]}
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
      if (s.name !== "starting" || !e.url.startsWith(LOOPBACK + "/bootstrap/#token=")) {
        return ending(s, {end: "its first page was not the chooser"})
      }
      return {state: {...s, name: "chooser", readyURL: e.url}, do: [{say: "ready"}, {chooser: []}]}
    case "home": {
      const m = e.message
      if (s.name === "locking") return same(s) // from before the lock
      if (!["chooser", "taking", "proposed"].includes(s.name) || !homeMessage(m)) {
        return ending(s, {end: "it named a CYFR this app does not open"})
      }
      if (rerouted(s, m)) return ending(s, {relaunch: {proxy: m.proxy ?? "", resolver: m.resolver ?? ""}})
      return {state: {...s, name: "taking", home: m.home, account: m.account, returning: null},
        do: [{say: `home: ${m.home}`}, {take: {home: m.home}}]}
    }
    case "taken":
      if (s.name !== "taking" || e.home !== s.home) return same(s) // for a proposal since replaced or locked away
      if (!e.taken) return lock(s, "the kept sign-in could not be cleared", "uncleared")
      return {state: {...s, name: "proposed"}, do: [{send: {type: "home-ready", fields: {home: s.home}}}]}
    case "opened":
      if (s.name === "locking") return same(s) // from before the lock
      if (s.name !== "proposed" || e.home !== s.home) return ending(s, {end: "it opened a CYFR this app was not keeping to"})
      return s.accountRoad ? same({...s, name: "open", notices: []}, [{root: {home: s.home}}]) : same({...s, name: "open"})
    case "locked": {
      const m = e.message
      if (s.name === "starting") return same(s)
      if (s.name === "locking") return settle({...s, barrier: true, keep: m})
      return lock(s, "the device locked", "", m)
    }
    case "pick-folder":
      return same(s, [{send: {type: "folder-picked", fields: {id: e.id, path: null}}}])
    case "gone":
      return ending(s, {end: e.why})

    // ---- the system, the windows, the person ----
    case "forgot": {
      if (s.name !== "locking") return same(s)
      const notices = e.cleared ? s.notices : adding(s.notices, "uncleared")
      if (!s.leaving) return settle({...s, forgotten: true, notices})
      // cyfr answers what it is sent now with a locked of its own.
      return same({...s, leaving: false, forgotten: true, notices: e.cleared ? [] : notices},
        [{send: {type: e.cleared ? "leave" : "lock"}}])
    }
    case "lost":
      return same(s, [{reload: true}])
    case "quit":
      return ending(s, {quit: true})
    case "second-instance":
      return same(s, [{show: true}])

    // The content window's top frame, as the engine reports it, read for
    // the answer on its way there (`returning`) alone.
    case "started":
      return s.returning?.at === "sent" && e.sameDocument && e.url === s.returning.url
        ? same({...s, returning: {url: e.url, at: "landing"}}) : withdrawn(s)
    case "delivered":
      return s.returning?.at === "landing" ? same(s) : withdrawn(s)
    case "landed":
      return withdrawn(s, s.returning?.at === "landing" && e.url === s.returning.url ? [{reload: true}] : [])
    case "committed":
    case "load-failed":
      return withdrawn(s)
    case "load-ended":
      return e.url === s.returning?.url ? withdrawn(s) : same(s)

    // A load in a window of the content's own (the content window or a
    // confirmation window): a hop, the company page or being sent to
    // sign in acts, from the content window alone. Nothing loads before
    // ready or while locking.
    case "navigate": {
      if (["starting", "locking"].includes(s.name)) return {state: s, allow: false, do: []}
      const where = contentNavigation(e, kept(s))
      if (where === "allow") {
        if (e.target === "top" && e.url === ANOTHER) {
          const pressed = s.accountRoad && s.name === "open" && e.window === "content" && e.asker === "top" && atChooser(e.showing)
          return {...(pressed ? leave(s) : same(s)), allow: false}
        }
        if (sentToSignIn(s, e)) return {...lock(s, "the CYFR asks for a sign-in", ""), allow: false}
        return {state: tookWayOn(e) ? {...s, notices: []} : s, allow: true, do: []}
      }
      if (where === "hop" && e.window === "content") return {state: s, allow: false, do: [{hop: {url: e.url, kind: "sign-in"}}]}
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
    // returns, as the kind of ceremony the content window now showing began
    // (`kind`, none otherwise); anything else ends the ceremony, and so
    // does every top-frame load before ready and while locking, when no
    // ceremony may go on. A frame loads nothing and ends nothing, ever.
    case "account-navigate": {
      if (e.target !== "top") return {state: s, allow: false, do: []}
      const where = ["starting", "locking"].includes(s.name) ? "block" : accountLoad(e.url, kept(s))
      if (where === "allow") return {state: s, allow: true, do: []}
      if (where !== "return" || !e.kind) return {state: s, allow: false, do: [{unhop: true}]}
      if (e.kind === "confirmation") return {state: s, allow: false, do: [{unhop: true}, {confirmation: {url: e.url}}]}
      return {state: {...s, returning: {url: e.url, at: "sent"}}, allow: false, do: [{unhop: true}, {deliver: {url: e.url}}]}
    }
  }
  return same(s)
}
