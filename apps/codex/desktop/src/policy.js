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
 * Where a content window's top-level load of `address` goes: "allow",
 * "hop" (the account service's sign-in page, opened in the account
 * window), "company" (the CYFR's company sign-in, which the app does not
 * offer) or "block". `state` names the selected CYFR, once main is ready
 * for it, and its account service.
 */
export function contentLoad(address, state) {
  const u = parse(address)
  if (!u) return "block"
  if (u.origin === LOOPBACK) return "allow"
  if (!state.home) return "block"
  if (u.origin === state.home) return u.pathname === "/company-login" ? "company" : "allow"
  if (state.accountRoad && u.origin === state.account && u.pathname === "/account/sign") return "hop"
  return "block"
}

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

/**
 * The sign-in or confirmation a hop to `address` carries, when it is one
 * the selected CYFR issued for itself and still current: the request read
 * as the account pages read it, for that CYFR, returning to its /login,
 * not expired. Anything else is null.
 */
export function readHop(address, state, now = Date.now()) {
  const u = parse(address)
  if (!u || u.origin !== state.account || u.pathname !== "/account/sign" || u.search !== "") return null
  try {
    const request = readRequest(parseFragment(u.hash.slice(1)))
    const purposeOK = request.purpose === "sign_in" || request.purpose === "confirm"
    if (!purposeOK || request.audience !== state.home || request.return !== state.home + "/login" ||
        request.expires_at <= now) return null
    return request
  } catch {
    return null
  }
}

/**
 * Where the account window's top-level load of `address` goes: "allow"
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
 * A document's response headers as a session of `kind` ("content" or
 * "account") keeps them. Content documents, frames among them, deny both
 * passkey calls, with any feature they named first kept, and run no
 * worker; the account window's document frames nothing. Each adds to the
 * document's own policies, which keep restricting it.
 */
export function documentHeaders(kind, resourceType, headers) {
  if (resourceType !== "mainFrame" && resourceType !== "subFrame") return headers
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
    out["Content-Security-Policy"] = resourceType === "mainFrame" ? [...csp, "frame-src 'none'"] : csp
  }
  return out
}

/**
 * Whether a sign-out's direct answer says the CYFR retired the session
 * it was sent under: the signed-out redirect with cyfr-session-retired: 1.
 */
export function retired(status, headers) {
  const location = headers.get("location") || ""
  return (status === 302 || status === 303) && headers.get("cyfr-session-retired") === "1" &&
    (location === "/login?error=signed_out" || location.endsWith("/login?error=signed_out"))
}

/** Whether `home` and `account` name a CYFR and an account service's origin. */
export function homeMessage(m) {
  return isHome(m.home) && isHome(m.account) && parse(m.account)?.protocol === "https:"
}

/** The relying party of the account service at `account`: its host. */
export function relyingParty(account) {
  return parse(account)?.hostname ?? ""
}
