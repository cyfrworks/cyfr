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
//              locked has arrived (`barrier`), naming what main keeps to
//              after it, and the session's sign-out has finished
//              (`signedOut`)
//   ended      cyfr is gone or the app quits; nothing opens again
//
// The effects (app.js carries each out at once, in order):
//   close                    destroy every content, confirmation and
//                            account window and cancel any ceremony
//   retire                   sign out the session the content held, if
//                            one was, then clear its storage; answers a
//                            signed-out event
//   send {type, fields}      a message to cyfr
//   chooser {notices}        open the content window at the chooser
//   relaunch {proxy, resolver}
//   end {why}                kill cyfr; once retire has answered, tell the
//                            person, with the unconfirmed sentence if so
//   quit                     once retire has answered, shut cyfr down and
//                            quit
//   hold                     the content holds a session of the CYFR main
//                            keeps to: keep what signing it out needs
//   hop {url, kind}, return {url}, unhop
//   say {line}

import {LOOPBACK, accountLoad, contentNavigation, contentOpen, homeMessage, parse} from "./policy.js"

/** The state main starts in. */
export function initial(accountRoad, route = {proxy: "", resolver: ""}) {
  return {name: "starting", accountRoad, readyURL: "", home: "", account: "", route}
}

/** What main keeps to in state `s`, as the policies read it. */
export const kept = (s) => ["proposed", "open"].includes(s.name)
  ? {home: s.home, account: s.account, accountRoad: s.accountRoad}
  : {home: "", account: "", accountRoad: s.accountRoad}

const ending = (s, why) => ({state: {...s, name: "ended"}, do: [{close: true}, {retire: true}, {end: why}]})
const same = (s, effects = []) => ({state: s, do: effects})

// A home or locked naming a CYFR on another route than main's: main must
// start again with it before it keeps to it.
const rerouted = (s, m) => (m.proxy ?? "") !== s.route.proxy || (m.resolver ?? "") !== s.route.resolver

// A lock from state s: the content closes at once and the sign-out
// starts; cyfr is told unless it said locked itself (`heard`, its
// message), which is then the barrier passed.
function lock(s, why, notice, heard = null) {
  const next = {...s, name: "locking", from: s.name, notices: notice ? [notice] : [], barrier: heard !== null,
    keep: heard, signedOut: false}
  return {state: next, do: [{say: `locked: ${why}`}, {close: true}, ...(heard ? [] : [{send: {type: "lock"}}]), {retire: true}]}
}

// A lock that has both its barrier and its sign-out: main keeps to what
// cyfr's locked named, or to none, and shows the chooser.
function settle(s) {
  if (!s.barrier || !s.signedOut) return same(s)
  const m = s.keep
  const next = {name: m.home ? "open" : "chooser", accountRoad: s.accountRoad, readyURL: s.readyURL,
    home: m.home ?? "", account: m.account ?? "", route: s.route}
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
        return ending(s, "its first page was not the chooser")
      }
      return {state: {...s, name: "chooser", readyURL: e.url}, do: [{say: "ready"}, {chooser: []}]}
    case "home": {
      const m = e.message
      if (s.name === "locking") return same(s) // from before the lock
      if (!["chooser", "proposed"].includes(s.name) || !homeMessage(m)) {
        return ending(s, "it named a CYFR this app does not open")
      }
      if (rerouted(s, m)) return {state: {...s, name: "ended"}, do: [{relaunch: {proxy: m.proxy ?? "", resolver: m.resolver ?? ""}}]}
      return {state: {...s, name: "proposed", home: m.home, account: m.account},
        do: [{say: `home: ${m.home}`}, {send: {type: "home-ready", fields: {home: m.home}}}]}
    }
    case "opened":
      if (s.name === "locking") return same(s) // from before the lock
      if (s.name !== "proposed" || e.home !== s.home) return ending(s, "it opened a CYFR this app was not keeping to")
      return same({...s, name: "open"})
    case "locked": {
      const m = e.message
      if (m.home && (!homeMessage(m) || rerouted(s, m))) return ending(s, "it locked keeping to a CYFR this app does not open")
      if (s.name === "starting") return same(s)
      if (s.name === "locking") return settle({...s, barrier: true, keep: m})
      return lock(s, "the device locked", "", m)
    }
    case "pick-folder":
      return same(s, [{send: {type: "folder-picked", fields: {id: e.id, path: null}}}])
    case "gone":
      return ending(s, e.why)

    // ---- the system, the windows, the person ----
    case "lock":
      if (s.name === "starting") return same(s)
      if (s.name === "locking") return same(s, [{close: true}])
      return lock(s, e.why, e.notice ?? "")
    case "signed-out":
      if (s.name !== "locking") return same(s)
      return settle({...s, signedOut: true, notices: e.confirmed ? s.notices : [...s.notices, "unconfirmed"]})
    case "quit":
      return {state: {...s, name: "ended"}, do: [{close: true}, {retire: true}, {quit: true}]}

    // A load in a window of the content's own (the content window or a
    // confirmation window): a hop or the company page acts, from the
    // content window alone.
    case "navigate": {
      if (s.name === "locking") return {state: s, allow: false, do: []}
      const where = contentNavigation(e, kept(s))
      if (where === "allow") return {state: s, allow: true, do: []}
      if (where === "hop" && e.window === "content") return {state: s, allow: false, do: [{hop: {url: e.url, kind: "sign-in"}}]}
      if (where === "company" && e.window === "content") {
        const locked = lock(s, "the CYFR asks for a company sign-in", "company")
        return {...locked, allow: false}
      }
      return {state: s, allow: false, do: []}
    }
    // The content window's top frame committed a page: one of the CYFR
    // main keeps to means its session may hold a sign-in.
    case "page":
      return same(s, kept(s).home && parse(e.url)?.origin === kept(s).home ? [{hold: true}] : [])
    case "open-window": {
      if (s.name === "locking") return {state: s, open: "deny", do: []}
      const what = contentOpen(e.url, kept(s))
      return {state: s, open: what === "child" ? "child" : "deny", do: what === "hop" ? [{hop: {url: e.url, kind: "confirmation"}}] : []}
    }
    // A load in the account window: its top frame shows the ceremony or
    // returns; anything else ends the ceremony, and a frame loads nothing.
    case "account-navigate": {
      if (e.target !== "top") return {state: s, allow: false, do: []}
      const where = s.name === "locking" ? "block" : accountLoad(e.url, kept(s))
      if (where === "allow") return {state: s, allow: true, do: []}
      return {state: s, allow: false, do: [where === "return" ? {return: {url: e.url}} : {unhop: true}]}
    }
  }
  return same(s)
}
