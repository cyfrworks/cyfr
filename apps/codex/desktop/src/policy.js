// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What the app's windows may load, open and be granted: decisions on
// addresses and headers alone, so each is tested without a window.
//
// Two kinds of session hold pages. A content session, memory-only and new
// at each unlock, holds the device's pages on loopback and, once main is
// ready for it, the CYFR selected. The account session, kept across
// launches, holds the selected CYFR's account service's sign-in page and
// its recovery continuation alone, opened when a page of that CYFR hops
// there with a sign-in or confirmation it issued; the answer comes back
// only to the session that hopped.

import {isHome} from "../../../cyfr/assets/account/encoding.js"
import {parseFragment, readRequest} from "../../../cyfr/assets/account/sign_in.js"

export const LOOPBACK = "http://127.0.0.1:7340"

const ACCOUNT_PAGES = ["/account/sign", "/account/recover"]

/** The address parsed, or null. */
export function parse(address) {
  try {
    return new URL(address)
  } catch {
    return null
  }
}

/**
 * What a window of the content's own does with a navigation to `url`:
 * of its top frame or of a frame (`target`), asked for by its top frame,
 * by a frame for itself or a frame inside it, by a frame for any other,
 * or by no frame (`asker`: "top", "frame-inside", "frame-outside",
 * "none", as the engine reports the initiator), while its top frame shows
 * `showing`. "allow", "block",
 * "hop" (a ceremony: the top frame, showing the selected CYFR's page,
 * sends itself to the account service's sign-in route, which opens in
 * the account window, also where the CYFR serves that route itself) or
 * "company" (the CYFR's company sign-in, which the app does not offer).
 * What a frame may ask, once: it may navigate itself or a frame inside it
 * to an address a frame may load, and never the top frame or a frame not
 * inside it; it never hops or returns. A frame loads no ceremony route. The recovery route is reached from the sign-in inside
 * the account window, never from here. `state` names the CYFR main keeps
 * to and its account service.
 */
export function contentNavigation({url, target, asker, showing}, state) {
  const u = parse(url)
  if (!u) return "block"
  if (target !== "top") return asker === "frame-outside" ? "block" : frameLoad(u, state)
  if (asker === "frame-inside" || asker === "frame-outside") return "block"
  if (u.origin === LOOPBACK) return "allow"
  if (!state.home) return "block"
  if (ceremony(u, state)) {
    return u.pathname === "/account/sign" && state.accountRoad && asker === "top" &&
      parse(showing)?.origin === state.home ? "hop" : "block"
  }
  if (u.origin === state.home) return u.pathname === "/company-login" ? "company" : "allow"
  return "block"
}

// A frame of a content page: the device's pages and the selected CYFR's,
// none of its ceremony or company sign-in routes, and documents of no
// origin.
function frameLoad(u, state) {
  if (["about:", "blob:", "data:"].includes(u.protocol)) return "allow"
  if (u.origin === LOOPBACK) return "allow"
  if (!state.home || ceremony(u, state)) return "block"
  return u.origin === state.home && u.pathname !== "/company-login" ? "allow" : "block"
}

// Whether u is one of the account service's ceremony routes.
const ceremony = (u, state) => u.origin === state.account && ACCOUNT_PAGES.includes(u.pathname)

/**
 * What a content page's window.open of `address` opens: "child" (the
 * device's own confirmation and passkey pages, in a window of their own),
 * "hop" (a confirmation at the account service) or "deny".
 */
export function contentOpen(address, state) {
  const u = parse(address)
  if (!u) return "deny"
  if (u.origin === LOOPBACK && (u.pathname === "/confirm" || u.pathname === "/passkey")) return "child"
  if (state.home && state.accountRoad && u.origin === state.account && u.pathname === "/account/sign") return "hop"
  return "deny"
}

// The request purpose each kind of hop carries: a sign-in hops the top
// frame, a confirmation opens a window.
const PURPOSE = {"sign-in": "sign_in", "confirmation": "confirm"}

/**
 * The sign-in or confirmation a hop of `kind` ("sign-in" or
 * "confirmation") to `address` carries, when it is one the selected CYFR
 * issued for itself and still current: the request read as the account
 * pages read it, of the purpose its kind carries, for that CYFR,
 * returning to its /login, not expired. Anything else is null.
 */
export function readHop(address, state, kind, now = Date.now()) {
  const u = parse(address)
  if (!u || u.origin !== state.account || u.pathname !== "/account/sign" || u.search !== "") return null
  try {
    const request = readRequest(parseFragment(u.hash.slice(1)))
    if (!PURPOSE[kind] || request.purpose !== PURPOSE[kind] || request.audience !== state.home || request.return !== state.home + "/login" ||
        request.expires_at <= now) return null
    return request
  } catch {
    return null
  }
}

/**
 * Where the account window's top-frame load of `address` goes: "allow"
 * (the account service's sign-in page or its recovery continuation),
 * "return" (the selected CYFR's /login, which carries the answer back to
 * the session that hopped) or "block".
 */
export function accountLoad(address, state) {
  const u = parse(address)
  if (!u) return "block"
  if (u.origin === state.account && ACCOUNT_PAGES.includes(u.pathname)) return "allow"
  if (u.origin === state.home && u.pathname === "/login" && u.search === "") return "return"
  return "block"
}

/** Whether a page may be granted `permission`: never a device, a capture or a credential. */
export function grants(permission) {
  return permission === "clipboard-sanitized-write" || permission === "fullscreen"
}

const PASSKEYS_DENIED = "publickey-credentials-get=(), publickey-credentials-create=()"

/**
 * A response's headers as a session of `kind` ("content" or "account")
 * keeps them, for the documents made of them. Content documents, frames
 * among them, deny both passkey calls, with any feature they named first
 * kept, and run no worker, so only a document's own response makes one.
 * The account window's documents frame nothing, and each response of that
 * session says so: the account pages' service worker makes a document of
 * what it fetched or kept, which the engine calls no document. Each adds
 * to the document's own policies, which keep restricting it.
 */
export function documentHeaders(kind, resourceType, headers) {
  if (kind === "content" && resourceType !== "mainFrame" && resourceType !== "subFrame") return headers
  const out = {}
  const policies = []
  const csp = []
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase()
    if (lower === "permissions-policy") policies.push(...value)
    else if (lower === "content-security-policy") csp.push(...value)
    else out[name] = value
  }
  if (kind === "content") {
    const kept = policies.flatMap((p) => p.split(",")).map((m) => m.trim())
      .filter((m) => m && !/^publickey-credentials-(get|create)\s*=/.test(m))
    out["Permissions-Policy"] = [[...kept, PASSKEYS_DENIED].join(", ")]
    out["Content-Security-Policy"] = [...csp, "worker-src 'none'"]
  } else {
    if (policies.length) out["Permissions-Policy"] = policies
    out["Content-Security-Policy"] = [...csp, "frame-src 'none'"]
  }
  return out
}

/**
 * Whether a sign-out's direct answer says the selected CYFR at `home`
 * retired the session it was sent under: a redirect whose location,
 * resolved against `home`, is exactly its signed-out address, with
 * cyfr-session-retired: 1.
 */
export function retired(status, headers, home) {
  let to = ""
  try {
    to = new URL(headers.get("location") ?? "", home + "/auth/logout").href
  } catch {
    return false
  }
  return (status === 302 || status === 303) && headers.get("cyfr-session-retired") === "1" &&
    to === home + "/login?error=signed_out"
}

/**
 * The switches the app takes on its command line: the selected CYFR's
 * route, which main relaunches itself with. They move where traffic goes
 * and nothing more: the origin checks and certificate validation still
 * decide what loads. The engine takes every other switch, from opening a
 * debugging port to trusting any certificate, so the app refuses them
 * all.
 */
export const SWITCHES = ["proxy-server", "host-resolver-rules"]

/**
 * The first switch of `args` (the command line after the executable) the
 * app does not take, as the engine reads switches on `platform`: "-" or
 * "--" before a name, "/" too on Windows, up to an "=" and its value,
 * until a bare "--". null when every switch is one the app takes.
 */
export function unlistedSwitch(args, platform) {
  for (const arg of args) {
    if (arg === "--") return null
    const prefix = /^--?/.exec(arg) ?? (platform === "win32" ? /^\//.exec(arg) : null)
    if (!prefix) continue
    const name = arg.slice(prefix[0].length).split("=")[0].toLowerCase()
    if (!SWITCHES.includes(name)) return name || arg
  }
  return null
}

/**
 * Whether `home` and `account` name a CYFR and an account service's origin
 * main takes for it: https, or plain http for a local CYFR alone
 * (http://localhost, with its port) and only at exactly that CYFR's own
 * origin. cyfr holds the same rule (internal/account ServiceOf;
 * tests/fixtures/desktop-process.json, account_services).
 */
export function homeMessage(m) {
  if (!isHome(m.home) || !isHome(m.account)) return false
  if (parse(m.account)?.protocol === "https:") return true
  return m.account === m.home && parse(m.home)?.hostname === "localhost"
}

/** The relying party of the account service at `account`: its host. */
export function relyingParty(account) {
  return parse(account)?.hostname ?? ""
}
