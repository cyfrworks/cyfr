// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * Carry hook — the browser half of the CYFR sign-in carry, the same code at
 * every home. A person's own home (the signing home, A) and the home they
 * sign in at (the destination, B) never talk to each other: the browser
 * carries the exchange between them in URL fragments, which never reach a
 * server, and this hook reads each one and clears it from the address at
 * once.
 *
 * The fragments, by where they arrive:
 *
 *   * at B's `/login`, `#carry=<…>`, A's signed carry (`cyfr_carry`), and
 *     `#cyfr=<…>`, A's assertion (`cyfr_assertion`);
 *   * at A's `/carry`, `#destination=<B>` (B's entry, which only fills the
 *     form), B's challenge, and B's return (`Prima.Carry.Return`); the
 *     last two are unpadded base64url JSON, told apart by their fields;
 *     and `#certify=<…>`, a glass at B asking A to certify its device
 *     key, which only shows the request until the person certifies it.
 *
 * The hook is mounted with `data-carry="login"` on the sign-in page and
 * `data-carry="source"` on `/carry`; `data-lifetime-ms` is the carry's
 * lifetime and `data-max-fragment` the largest fragment (16 KiB). A
 * fragment over that bound is never handed on, never truncated.
 *
 * What it keeps, in this tab's `sessionStorage` and nowhere else, and only
 * for the carry's lifetime:
 *
 *   * `cyfr:carry:expect` at B: `{home, at}`, written when the person
 *     names their home in B's entry, just before going there. A carry is
 *     handed to B's page only while this expectation is fresh, once, and
 *     names that home as the source B must find in the carry: a carry the
 *     person did not ask for here signs nobody in. It is cleared when it
 *     is used, or found expired.
 *   * `cyfr:carry:source` at A: the actions this tab began, each with its
 *     destination, `key_epoch` and time, and the transport fragment (a
 *     destination, a challenge, a return or a device to certify, meant for
 *     `/carry`) that
 *     arrived before the person signed in at A and was sent to `/login`
 *     with it, with its time. `/carry` takes the fragment once the person
 *     is signed in, and `resume()`, which the bundle runs once at every
 *     page load, goes back to `/carry` while one is held.
 *
 * No list of homes is kept: no saved addresses, no history of visits.
 */

export const EXPECT_KEY = "cyfr:carry:expect"
export const SOURCE_KEY = "cyfr:carry:source"
export const MAX_FRAGMENT_BYTES = 16384
export const LIFETIME_MS = 5 * 60 * 1000
// The most actions one tab remembers beginning, as A holds at most twenty
// pending a person.
export const MAX_ACTIONS = 20

// ---------------------------------------------------------------------------
// Fragments
// ---------------------------------------------------------------------------

/** The address's fragment, without its `#`, cleared from the address; null when there is none. */
export function takeFragment(win) {
  const hash = win.location.hash || ""
  if (hash.length <= 1) return null
  const {pathname, search} = win.location
  win.history.replaceState(win.history.state, "", pathname + (search || ""))
  return hash.slice(1)
}

const byteLength = (text) => new TextEncoder().encode(text).length

/** An unpadded base64url JSON object, or null. */
export function decodeObject(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]+$/.test(text)) return null
  try {
    const base64 = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4)
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0))
    const object = JSON.parse(new TextDecoder("utf-8", {fatal: true}).decode(bytes))
    return object && typeof object === "object" && !Array.isArray(object) ? object : null
  } catch {
    return null
  }
}

/**
 * What a fragment is: `{kind}` of `carry`, `assertion` and `certify` (with
 * `value`, the part after the key), `destination` (with `destination`),
 * `challenge` and `return` (with `fragment` and `actionId`), `too_large`,
 * `unknown` or `none`.
 */
export function classify(fragment, max = MAX_FRAGMENT_BYTES) {
  if (typeof fragment !== "string" || fragment === "") return {kind: "none"}
  if (byteLength(unkeyed(fragment)) > max) return {kind: "too_large"}

  if (fragment.startsWith("carry=")) return keyed("carry", fragment.slice(6))
  if (fragment.startsWith("cyfr=")) return keyed("assertion", fragment.slice(5))
  if (fragment.startsWith("certify=")) return keyed("certify", fragment.slice(8))

  if (fragment.startsWith("destination=")) {
    const destination = new URLSearchParams(fragment).get("destination")
    return destination ? {kind: "destination", destination} : {kind: "unknown"}
  }

  const object = decodeObject(fragment)
  if (object && typeof object.action_id === "string") {
    if (typeof object.challenge === "string" && typeof object.audience === "string") {
      return {kind: "challenge", fragment, actionId: object.action_id}
    }
    if (typeof object.outcome === "string") return {kind: "return", fragment, actionId: object.action_id}
  }
  return {kind: "unknown"}
}

const keyed = (kind, value) => (value ? {kind, value} : {kind: "unknown"})

// What the bound is held against: the encoded carry or assertion after its
// key, as the homes bound it (`Prima.Carry.bounded/1`), or the whole
// fragment when it has no key.
const unkeyed = (fragment) => fragment.replace(/^(carry|cyfr|certify)=/, "")

// Whether a fragment's navigation stays within the bound: the part after
// its `#` is what the other page reads.
function withinBound(to, max) {
  if (typeof to !== "string" || to === "") return false
  const at = to.indexOf("#")
  return at < 0 || byteLength(unkeyed(to.slice(at + 1))) <= max
}

// ---------------------------------------------------------------------------
// Storage: this tab's sessionStorage, which a blocked store makes empty
// ---------------------------------------------------------------------------

export function sessionStorageOf(win) {
  try {
    return win && win.sessionStorage ? win.sessionStorage : null
  } catch {
    return null
  }
}

function read(storage, key) {
  if (!storage) return null
  try {
    const raw = storage.getItem(key)
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

function write(storage, key, value) {
  if (!storage) return
  try {
    storage.setItem(key, JSON.stringify(value))
  } catch {
    // A store that refuses a write keeps nothing; the carry then resumes
    // from the source's own action.
  }
}

function remove(storage, key) {
  if (!storage) return
  try {
    storage.removeItem(key)
  } catch {
    // Nothing to remove from a store that cannot be read.
  }
}

const fresh = (at, now, lifetimeMs) => typeof at === "number" && now >= at && now - at < lifetimeMs

/** B's expectation: the person named `home` in this page's entry, now. */
export function expectHome(storage, home, now) {
  write(storage, EXPECT_KEY, {home, at: now})
}

/**
 * The home B's entry named, while that expectation is fresh; it is taken
 * either way, so it is used once at most, and an expired one is gone.
 */
export function takeExpectation(storage, now, lifetimeMs) {
  const held = read(storage, EXPECT_KEY)
  remove(storage, EXPECT_KEY)
  if (!held || typeof held.home !== "string" || !fresh(held.at, now, lifetimeMs)) return null
  return held.home
}

/** A's state: `{actions: {id: {destination, key_epoch, at}}, transport: {fragment, at, ttl} | null}`. */
export function sourceState(storage) {
  const held = read(storage, SOURCE_KEY)
  const actions = held && held.actions && typeof held.actions === "object" ? held.actions : {}
  const transport = held && held.transport && typeof held.transport === "object" ? held.transport : null
  return {actions, transport}
}

function keepSource(storage, state) {
  if (Object.keys(state.actions).length === 0 && !state.transport) remove(storage, SOURCE_KEY)
  else write(storage, SOURCE_KEY, state)
}

// The actions still within the carry's lifetime, the newest MAX_ACTIONS.
function current(actions, now, lifetimeMs) {
  const kept = Object.entries(actions)
    .filter(([, action]) => action && fresh(action.at, now, lifetimeMs))
    .sort(([, a], [, b]) => b.at - a.at)
    .slice(0, MAX_ACTIONS)
  return Object.fromEntries(kept)
}

/** A begins an action in this tab: remembered with its destination and key_epoch. */
export function rememberAction(storage, {action_id, destination, key_epoch}, now, lifetimeMs) {
  const state = sourceState(storage)
  const actions = current(state.actions, now, lifetimeMs)
  actions[action_id] = {destination, key_epoch, at: now}
  keepSource(storage, {...state, actions: current(actions, now, lifetimeMs)})
}

/** Whether this tab began the action, within its lifetime. */
export function began(storage, actionId, now, lifetimeMs) {
  const action = sourceState(storage).actions[actionId]
  return Boolean(action && fresh(action.at, now, lifetimeMs))
}

export function forgetAction(storage, actionId) {
  const state = sourceState(storage)
  if (!(actionId in state.actions)) return
  delete state.actions[actionId]
  keepSource(storage, state)
}

/** A fragment meant for A's `/carry` that arrived at A's `/login`: kept through the sign-in. */
export function keepTransport(storage, fragment, now, lifetimeMs) {
  const state = sourceState(storage)
  keepSource(storage, {...state, transport: {fragment, at: now, ttl: lifetimeMs}})
}

/** The kept fragment while it is fresh; taken either way. */
export function takeTransport(storage, now) {
  const state = sourceState(storage)
  const transport = state.transport
  if (!transport) return null
  keepSource(storage, {...state, transport: null})
  const ttl = typeof transport.ttl === "number" && transport.ttl > 0 ? transport.ttl : LIFETIME_MS
  return typeof transport.fragment === "string" && fresh(transport.at, now, Math.min(ttl, LIFETIME_MS))
    ? transport.fragment
    : null
}

function heldTransport(storage, now) {
  const transport = sourceState(storage).transport
  if (!transport) return false
  const ttl = typeof transport.ttl === "number" && transport.ttl > 0 ? transport.ttl : LIFETIME_MS
  if (fresh(transport.at, now, Math.min(ttl, LIFETIME_MS))) return true
  takeTransport(storage, now)
  return false
}

/**
 * Run once at every page load: a fragment meant for A's `/carry` that was
 * kept through the person's sign-in here takes them back to `/carry`,
 * where the hook hands it on. Answers whether it navigated.
 */
export function resume(win = globalThis.window, now = Date.now()) {
  if (!win || !win.location) return false
  const path = win.location.pathname
  if (path === "/carry" || path === "/login") return false
  if (!heldTransport(sessionStorageOf(win), now)) return false
  win.location.assign("/carry")
  return true
}

// ---------------------------------------------------------------------------
// The hook
// ---------------------------------------------------------------------------

const positive = (value, fallback) => {
  const number = Number.parseInt(value, 10)
  return Number.isFinite(number) && number > 0 ? number : fallback
}

const Carry = {
  mounted() {
    this.win = this.win || globalThis.window
    this.storage = sessionStorageOf(this.win)
    this.lifetimeMs = positive(this.el.dataset.lifetimeMs, LIFETIME_MS)
    this.maxFragment = positive(this.el.dataset.maxFragment, MAX_FRAGMENT_BYTES)

    const fragment = takeFragment(this.win)

    if (this.el.dataset.carry === "login") {
      this.handleEvent("cyfr:expect", ({home, to}) => this.expect(home, to))
      // A resumed exchange: back to its home, keeping no expectation, since
      // what comes back is its assertion and never a carry.
      this.handleEvent("cyfr:go", ({to}) => this.go(to))
      this.atLogin(fragment)
    } else if (this.el.dataset.carry === "source") {
      this.handleEvent("carry:begun", (begun) => this.begun(begun))
      this.handleEvent("carry:go", ({to}) => this.go(to))
      this.handleEvent("carry:forget", ({action_id}) => forgetAction(this.storage, action_id))
      this.atSource(fragment)
    }
  },

  now() {
    return Date.now()
  },

  // B's sign-in page, or A's while its person signs in.
  atLogin(fragment) {
    const now = this.now()
    const found = classify(fragment, this.maxFragment)

    switch (found.kind) {
      case "carry": {
        const home = takeExpectation(this.storage, now, this.lifetimeMs)
        if (home) this.pushEvent("cyfr_carry", {fragment: found.value, expected_source: home})
        else this.pushEvent("cyfr_unsolicited", {})
        return
      }
      case "assertion":
        this.pushEvent("cyfr_assertion", {fragment: found.value})
        return
      case "destination":
      case "challenge":
      case "return":
      case "certify":
        keepTransport(this.storage, fragment, now, this.lifetimeMs)
        return
      case "too_large":
        this.pushEvent("cyfr_oversized", {})
        return
      default:
        return
    }
  },

  // A's `/carry`: the address's fragment, or the one kept through sign-in,
  // which is taken either way.
  atSource(fragment) {
    const now = this.now()
    const kept = takeTransport(this.storage, now)
    const found = classify(fragment || kept, this.maxFragment)

    switch (found.kind) {
      case "destination":
        this.pushEvent("carry_destination", {destination: found.destination})
        return
      case "challenge":
        this.pushEvent("carry_challenge", {
          fragment: found.fragment,
          own: began(this.storage, found.actionId, now, this.lifetimeMs)
        })
        return
      case "return":
        this.pushEvent("carry_return", {fragment: found.fragment})
        return
      case "certify":
        this.pushEvent("carry_certify", {fragment: found.value})
        return
      case "too_large":
        this.pushEvent("carry_oversized", {})
        return
      default:
        return
    }
  },

  // B's entry named a home: expect a carry from it, then go there.
  expect(home, to) {
    if (typeof home !== "string" || typeof to !== "string") return
    expectHome(this.storage, home, this.now())
    this.win.location.assign(to)
  },

  begun({action_id, destination, key_epoch, to}) {
    if (!withinBound(to, this.maxFragment)) {
      this.pushEvent("carry_oversized", {})
      return
    }
    rememberAction(this.storage, {action_id, destination, key_epoch}, this.now(), this.lifetimeMs)
    this.win.location.assign(to)
  },

  go(to) {
    if (withinBound(to, this.maxFragment)) this.win.location.assign(to)
    else this.pushEvent("carry_oversized", {})
  }
}

export default Carry
