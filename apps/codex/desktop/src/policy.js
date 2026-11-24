// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What the app's windows may load, open and be granted: decisions on
// addresses and headers alone, so each is tested without a window.
//
// Three kinds of session hold pages. The app's own, in memory, holds the
// rail and the chooser. A content session holds the device's pages on
// loopback and, once cyfr opened it, the CYFR selected: on the passkey
// road one kept across launches for each CYFR (homePartition), as a
// browser's is, and otherwise memory-only and new at each lock. An
// account session, kept across launches, one for each CYFR and account
// service (accountPartition), holds that account service's sign-in page,
// its page that makes an account and the sign-in's recovery continuation
// alone, opened when a page of that CYFR hops there with a sign-in or
// confirmation it issued; the answer comes back only to the session that
// hopped.

import {createHash} from "node:crypto"

import {isHome} from "../../../cyfr/assets/account/encoding.js"
import {parseFragment, readRequest} from "../../../cyfr/assets/account/sign_in.js"

export const LOOPBACK = "http://127.0.0.1:7340"

// The pages a hop opens, each with the request its fragment carries: the
// sign-in's, the whole fragment; the account made's, its request beside
// the name it offers, a sign-in's alone. The recovery continuation is
// reached from the sign-in inside the account window, never by a hop.
const HOPS = {
  "/account/sign": {kinds: ["sign-in", "confirmation"], request: (fragment) => fragment},
  "/account/new": {kinds: ["sign-in"], request: (fragment) => {
    const params = new URLSearchParams(fragment)
    return [...params.keys()].join(",") === "name,request" ? params.get("request") : null
  }},
}
const ACCOUNT_PAGES = [...Object.keys(HOPS), "/account/recover"]

// An origin's name in a partition: the lowercase hex SHA-256 of its one
// spelling, so two CYFRs differing in scheme, host or port never share
// one, and a partition never changes its owner.
const digest = (origin) => createHash("sha256").update(origin, "ascii").digest("hex")

/** The kept content storage of the CYFR at `home`, on the passkey road. */
export const homePartition = (home) => `persist:cyfr-home-v2-${digest(home)}`

/** The kept storage of account service `account`'s ceremonies for the CYFR at `home`. */
export const accountPartition = (home, account) => `persist:cyfr-account-v2-${digest(home)}-${digest(account)}`

/**
 * What a press on the rail asks of main, from the address the rail's page
 * navigates to, which main answers and never loads: select or menu (the
 * row's menu) of a CYFR, named by its origin, or connect, setup or box
 * (This box, the box's own CYFR, whatever its folder names now). Any other
 * address is none (null).
 */
export function railPress(address) {
  const u = parse(address)
  if (!u || u.origin !== LOOPBACK || u.hash || u.username || u.password) return null
  const act = {"/rail/select": "select", "/rail/menu": "menu", "/rail/connect": "connect", "/rail/setup": "setup",
    "/rail/box": "box"}[u.pathname]
  if (!act) return null
  const keys = [...u.searchParams.keys()]
  if (act === "connect" || act === "setup" || act === "box") return u.search === "" ? {act} : null
  const home = u.searchParams.get("cyfr")
  return keys.length === 1 && keys[0] === "cyfr" && isHome(home) ? {act, home} : null
}


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
 * sends itself to the account service's sign-in route or the page that
 * makes an account, which open in the account window, also where the CYFR
 * serves that route itself) or
 * "company" (the CYFR's company sign-in, which the app does not offer).
 * The chooser is main's alone to show (chooserPath): no navigation, no
 * redirect and no frame loads it, in any window.
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
  if (chooserPath(u) || railPath(u)) return "block"
  if (u.origin === LOOPBACK) return "allow"
  // The chooser goes on to the device's pages alone: its view's storage is
  // memory's, so a CYFR's page there, its sign-in above all, would be lost
  // at the next start. Main opens the CYFR in its own view (states.js
  // ACTS reopen).
  const from = parse(showing)
  if (!state.home || (from && chooserPath(from))) return "block"
  if (ceremony(u, state)) {
    return Object.hasOwn(HOPS, u.pathname) && state.accountRoad && asker === "top" &&
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
  if (chooserPath(u) || railPath(u)) return "block"
  if (u.origin === LOOPBACK) return "allow"
  if (!state.home || ceremony(u, state)) return "block"
  return u.origin === state.home && u.pathname !== "/company-login" ? "allow" : "block"
}

// Whether u is one of the chooser's addresses, or the rail's, as cyfr
// reads them, which is unescaped: main alone loads those pages (its loads
// ask no policy), the rail in a view of its own, so what one says on
// main's behalf comes with main's load and no other.
const chooserPath = (u) => cyfrsOwn(u, "/bootstrap")
const railPath = (u) => cyfrsOwn(u, "/rail")
function cyfrsOwn(u, prefix) {
  if (u.origin !== LOOPBACK) return false
  try {
    return decodeURIComponent(u.pathname).startsWith(prefix)
  } catch {
    return true // not readable here, and cyfr may read it as the page's
  }
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
 * returning to its /login, not expired, at a page that takes that kind
 * (the page that makes an account takes a sign-in alone). Anything else
 * is null. This is the one reader of every hop.
 */
export function readHop(address, state, kind, now = Date.now()) {
  const u = parse(address)
  const page = u && Object.hasOwn(HOPS, u.pathname) ? HOPS[u.pathname] : null
  if (!u || !page || !page.kinds.includes(kind) || u.origin !== state.account || u.search !== "") return null
  try {
    const request = readRequest(parseFragment(page.request(u.hash.slice(1))))
    if (!PURPOSE[kind] || request.purpose !== PURPOSE[kind] || request.audience !== state.home || request.return !== state.home + "/login" ||
        request.expires_at <= now) return null
    return request
  } catch {
    return null
  }
}

/**
 * Where the account window's top-frame load of `address`, in a ceremony
 * of `kind` ("sign-in", "confirmation", or none), goes: "allow" (the
 * account service's sign-in page or its page that makes an account,
 * carrying a request readHop reads for that kind, or the sign-in's
 * recovery continuation), "return" (the selected CYFR's /login, which
 * carries the answer back to the session that hopped) or "block". A page
 * that takes a request is decided by readHop alone, at every load.
 */
export function accountLoad(address, state, kind = null, now = Date.now()) {
  const u = parse(address)
  if (!u) return "block"
  if (u.origin === state.account && Object.hasOwn(HOPS, u.pathname)) return readHop(address, state, kind, now) ? "allow" : "block"
  if (u.origin === state.account && u.pathname === "/account/recover") return "allow"
  if (u.origin === state.home && u.pathname === "/login" && u.search === "") return "return"
  return "block"
}

/** Whether a page may be granted `permission`: never a device, a capture or a credential. */
export function grants(permission) {
  return permission === "clipboard-sanitized-write" || permission === "fullscreen"
}

/**
 * `text` as the app prints it: no address in it carries a fragment or a
 * query. One with a scheme keeps its origin alone, since a path carries a
 * credential too (a sign-in's ticket, a served file's); what follows an
 * address up to the next space goes with it, as either may hold any mark
 * a sentence would end an address with.
 */
export function printed(text) {
  return String(text)
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/)(?:[^\s/?#@]*@)?([^\s/?#"'`<>\\]*)\S*/gi, "$1$2")
    .replace(/\bdata:\S*/gi, "data:")
    .replace(/(^|[^\w.:/~-])(\/[^\s?#]*)[?#]\S*/g, "$1$2")
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
 * A response in a content session to a page that is gone (`pageGone`:
 * closed by a lock, or none, as a keepalive request's is once its page
 * went) sets no cookie, so none arrives in storage being forgotten.
 */
export function documentHeaders(kind, resourceType, headers, {pageGone = false} = {}) {
  if (kind === "content" && pageGone) {
    headers = Object.fromEntries(Object.entries(headers).filter(([name]) => name.toLowerCase() !== "set-cookie"))
  }
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
    out["Content-Security-Policy"] = [...csp, "frame-src 'none'", "worker-src 'none'"]
  }
  return out
}

/**
 * The switches the app takes on its command line: the box's screen's
 * project (screenProject), the folder cyfr setup opened the app in
 * (setupProject) and --quit, which asks the app this account runs to end
 * (app.js). The engine takes every other switch, from opening a
 * debugging port to trusting any certificate, so the app refuses them
 * all. A CYFR's route is no switch: main sets it on that CYFR's own
 * stores.
 */
export const SWITCHES = ["screen-project", "setup-project", "quit"]

/**
 * Whether `value` names a folder explicitly on `platform`, as the system
 * calls a path absolute with nothing after its volume to resolve: on
 * Windows a drive's letter, a colon and a separator, or a network share's
 * two backslashes, server and share (\\?\ and \\.\ among them),
 * elsewhere a "/". Each form is in tests/fixtures/setup-folders.json.
 */
function explicitFolder(value, platform) {
  const volume = platform === "win32"
    ? /^(?:[A-Za-z]:(?=[\\/])|\\\\[^\\/]+[\\/][^\\/]+(?=[\\/]|$))/.exec(value)
    : /^(?=\/)/.exec(value)
  if (!volume) return false
  return !value.slice(volume[0].length).split(platform === "win32" ? /[\\/]/ : "/").some((p) => p === "." || p === "..")
}

/**
 * The project the app is the box's screen for, as `--screen-project`
 * names it (`present`, and its `value`): "" for no screen, null for a
 * switch that names no project explicitly, which the app refuses. Only
 * this switch makes the app a screen, and only for an absolute path with
 * nothing to resolve, on Linux, where the screen runs.
 */
export function screenProject(present, value, platform) {
  if (!present) return ""
  return platform === "linux" && explicitFolder(value, platform) ? value : null
}

/**
 * The folder the chooser suggests for setting CYFR up on this computer,
 * as `--setup-project` names it (cyfr setup gives its working directory):
 * "" for none, so ~/cyfr, and null for a switch that names no folder
 * explicitly, which the app refuses.
 */
export function setupProject(present, value, platform) {
  if (!present) return ""
  return explicitFolder(value, platform) ? value : null
}

/**
 * The engine's resolver rule, the app's whole run: localhost is 127.0.0.1 alone, where Docker publishes a local CYFR, and
 * never ::1, where any other program may listen on the same port and be
 * given that CYFR's pages, tickets and cookies (cmd/local.go).
 */
export const LOCALHOST_IS_IPV4 = "MAP localhost 127.0.0.1"

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
