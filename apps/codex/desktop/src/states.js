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
//   proposed   cyfr proposed `home`; main answered home-ready and keeps to it
//   open       cyfr committed `home`; main keeps to it
//   locking    a lock runs: the content is closed; it ends once cyfr's
//              locked has arrived (`barrier`) and the session's sign-out
//              has finished (`signedOut`); main then keeps to the CYFR it
//              kept to before the lock if locked names that same one, and
//              to none otherwise
//   ended      cyfr is gone, the app quits or starts again on another
//              route; nothing opens again
//
// Every way into ended, as every lock, closes the content and signs its
// session out first. `held` is whether the content window was given the
// CYFR main keeps to to load, so its session may hold a sign-in: from
// then on a lock signs it out, unconfirmed without a forgery token.
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
//   retire {held}            sign out the session the content held, if
//                            `held`, then clear its storage, always;
//                            answers a signed-out event
//   send {type, fields}      a message to cyfr
//   chooser {notices}        open the content window at the chooser
//   relaunch {proxy, resolver}  once retire has answered
//   end {why}                kill cyfr; once retire has answered, tell the
//                            person, with the unconfirmed sentence if so
//   quit                     once retire has answered, shut cyfr down and
//                            quit
//   hold                     the content was given the CYFR main keeps to:
//                            begin keeping what signing it out needs
//   token                    read the forgery token of the page shown
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
  return {name: "starting", accountRoad, readyURL: "", home: "", account: "", route, held: false, returning: null}
}

/** What main keeps to in state `s`, as the policies read it. */
export const kept = (s) => ["proposed", "open"].includes(s.name)
  ? {home: s.home, account: s.account, accountRoad: s.accountRoad}
  : {home: "", account: "", accountRoad: s.accountRoad}

// Into ended, the way every end goes: close, sign out, then `last`.
const ending = (s, last) => ({state: {...s, name: "ended", returning: null}, do: [{close: true}, {retire: {held: s.held}}, last]})
const same = (s, effects = []) => ({state: s, do: effects})
const withdrawn = (s, effects = []) => same(s.returning ? {...s, returning: null} : s, effects)

// A home naming a CYFR on another route than main's: main must start
// again with it before it keeps to it.
const rerouted = (s, m) => (m.proxy ?? "") !== s.route.proxy || (m.resolver ?? "") !== s.route.resolver

// A lock from state s: the content closes at once and the sign-out
// starts; cyfr is told unless it said locked itself (`heard`, its
// message), which is then the barrier passed.
function lock(s, why, notice, heard = null) {
  const next = {...s, name: "locking", before: kept(s), notices: notice ? [notice] : [], barrier: heard !== null,
    keep: heard, signedOut: false, held: false, returning: null}
  return {state: next, do: [{say: `locked: ${why}`}, {close: true}, ...(heard ? [] : [{send: {type: "lock"}}]),
    {retire: {held: s.held}}]}
}

// A lock that has both its barrier and its sign-out: main keeps to the
// CYFR it kept to before the lock when cyfr's locked names that same one,
// and to none otherwise, and shows the chooser. A locked never gives main
// a CYFR it did not keep to already.
function settle(s) {
  if (!s.barrier || !s.signedOut) return same(s)
  const m = s.keep
  const again = !!m.home && m.home === s.before.home && m.account === s.before.account
  const next = {name: again ? "open" : "chooser", accountRoad: s.accountRoad, readyURL: s.readyURL,
    home: again ? m.home : "", account: again ? m.account : "", route: s.route, held: false, returning: null}
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
      if (!["chooser", "proposed"].includes(s.name) || !homeMessage(m)) {
        return ending(s, {end: "it named a CYFR this app does not open"})
      }
      if (rerouted(s, m)) return ending(s, {relaunch: {proxy: m.proxy ?? "", resolver: m.resolver ?? ""}})
      return {state: {...s, name: "proposed", home: m.home, account: m.account, returning: null},
        do: [{say: `home: ${m.home}`}, {send: {type: "home-ready", fields: {home: m.home}}}]}
    }
    case "opened":
      if (s.name === "locking") return same(s) // from before the lock
      if (s.name !== "proposed" || e.home !== s.home) return ending(s, {end: "it opened a CYFR this app was not keeping to"})
      return same({...s, name: "open"})
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
    case "lock":
      if (s.name === "starting") return same(s)
      if (s.name === "locking") return same(s, [{close: true}])
      return lock(s, e.why, e.notice ?? "")
    case "signed-out":
      if (s.name !== "locking") return same(s)
      return settle({...s, signedOut: true, notices: e.confirmed ? s.notices : [...s.notices, "unconfirmed"]})
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
    // confirmation window): a hop or the company page acts, from the
    // content window alone. Its top frame given the CYFR main keeps to,
    // the session is held from then on. Nothing loads before ready or
    // while locking.
    case "navigate": {
      if (["starting", "locking"].includes(s.name)) return {state: s, allow: false, do: []}
      const where = contentNavigation(e, kept(s))
      if (where === "allow") {
        const given = e.target === "top" && !!kept(s).home && parse(e.url)?.origin === kept(s).home
        return given ? {state: {...s, held: true}, allow: true, do: [{hold: true}]} : {state: s, allow: true, do: []}
      }
      if (where === "hop" && e.window === "content") return {state: s, allow: false, do: [{hop: {url: e.url, kind: "sign-in"}}]}
      if (where === "company" && e.window === "content") {
        const locked = lock(s, "the CYFR asks for a company sign-in", "company")
        return {...locked, allow: false}
      }
      return {state: s, allow: false, do: []}
    }
    // The content window finished loading a page: one of the CYFR main
    // keeps to, its session held, carries the forgery token to read.
    case "page":
      return same(s, s.held && kept(s).home && parse(e.url)?.origin === kept(s).home ? [{token: true}] : [])
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
      // The return gives the content window the CYFR: its session is held.
      const given = {...s, held: true}
      const effects = [{unhop: true}, {hold: true}]
      if (e.kind === "confirmation") return {state: given, allow: false, do: [...effects, {confirmation: {url: e.url}}]}
      return {state: {...given, returning: {url: e.url, at: "sent"}}, allow: false, do: [...effects, {deliver: {url: e.url}}]}
    }
  }
  return same(s)
}
