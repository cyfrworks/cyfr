// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"

import {fragment} from "../../../cyfr/assets/account/sign_in.js"
import {
  LOOPBACK, SWITCHES, accountLoad, contentNavigation, contentOpen, documentHeaders, grants, homeMessage, printed, readHop,
  relyingParty, screenProject, setupProject, unlistedSwitch
} from "../src/policy.js"

const processes = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/desktop-process.json", import.meta.url)))
const signIn = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/sign_in.json", import.meta.url)))
const home = signIn["home"]
const account = "https://accounts.example.com"
const ready = {home, account, accountRoad: true}
const linux = {home, account, accountRoad: false}
const before = {home: "", account: "", accountRoad: true}

// A navigation of a content window's top frame from `from`, or of a frame.
const top = (url, state, showing = home + "/login", asker = "top") => contentNavigation({url, target: "top", asker, showing}, state)
const frame = (url, state, asker = "frame-inside") => contentNavigation({url, target: "frame", asker, showing: home + "/"}, state)

test("a content window loads the device's pages, then the selected CYFR, and nothing else", () => {
  assert.equal(top(LOOPBACK + "/bootstrap/", before, ""), "block", "the chooser is main's alone to load")
  assert.equal(top(LOOPBACK + "/", before, ""), "allow", "the device's pages")
  assert.equal(top(home + "/", before), "block", "the CYFR before main keeps to it")
  assert.equal(top(home + "/threads?x=1", ready), "allow")
  assert.equal(top(home + "/company-login", ready), "company")
  assert.equal(top(account + "/account/new#x", ready), "hop", "the page that makes an account, a hop")
  assert.equal(top(account + "/account/new#x", linux), "block", "no account road on Linux")
  for (const elsewhere of ["https://evil.example/", "http://127.0.0.1:7341/", "http://localhost:7340/", "file:///etc/passwd",
    "javascript:alert(1)", "data:text/html,x", home.replace("https", "http") + "/", "not a url"]) {
    assert.equal(top(elsewhere, ready), "block", elsewhere)
  }
})

test("only the content window's top frame, showing the selected CYFR's page, hops, to the sign-in route and the page that makes an account alone", () => {
  assert.equal(top(account + "/account/sign#x", ready), "hop")
  assert.equal(top(account + "/account/new#x", ready), "hop")
  for (const [showing, asker, why] of [[home + "/setup", "none", "asked by no frame"], [LOOPBACK + "/bootstrap/", "top", "from the device's pages"],
    ["https://evil.example/", "top", "from another page"]]) {
    assert.equal(top(account + "/account/new#x", ready, showing, asker), "block", `the page that makes an account, ${why}`)
  }
  assert.equal(top(account + "/account/recover#x", ready), "block", "recovery is reached inside the account window")
  assert.equal(top(account + "/account/sign#x", ready, home + "/login", "none"), "block", "asked by no frame")
  assert.equal(top(account + "/account/sign#x", linux), "block", "no account road on Linux")
  assert.equal(top(account + "/account/sign#x", ready, LOOPBACK + "/bootstrap/"), "block", "from the device's pages")
  assert.equal(top(account + "/account/sign#x", ready, "https://evil.example/"), "block", "from another page")
})

test("a CYFR that serves its own account pages hops to them, never loads them as its page", () => {
  const same = {home, account: home, accountRoad: true}
  assert.equal(top(home + "/account/sign#x", same), "hop")
  assert.equal(top(home + "/account/recover", same), "block")
  assert.equal(top(home + "/account/sign#x", {...same, accountRoad: false}), "block")
  assert.equal(top(home + "/threads", same), "allow")
})

test("a frame navigates itself or a frame inside it to what a frame may load, and never the top frame or another frame", () => {
  for (const url of [account + "/account/sign#x", home + "/threads", home + "/company-login", LOOPBACK + "/lock"]) {
    for (const asker of ["frame-inside", "frame-outside"]) {
      assert.equal(top(url, ready, home + "/", asker), "block", `${asker}: the top frame to ${url}`)
    }
  }
  assert.equal(frame(home + "/threads", ready, "frame-outside"), "block", "a sibling frame")
  assert.equal(frame(home + "/threads", ready, "frame-inside"), "allow", "itself, to an address a frame may load")
  assert.equal(frame(home + "/threads", ready, "top"), "allow", "the top frame's own frame")
  assert.equal(frame("https://evil.example/", ready, "frame-inside"), "block", "itself, to an address no frame loads")
})

test("a frame never hops and never loads a ceremony's route, by navigation or by redirect", () => {
  const same = {home, account: home, accountRoad: true}
  for (const state of [ready, same, linux]) {
    for (const route of ["/account/sign#x", "/account/new#x", "/account/recover"]) {
      assert.equal(frame(state.account + route, state), "block", `${state.account}${route}`)
    }
  }
  assert.equal(frame(home + "/company-login", ready), "block")
  assert.equal(frame(home + "/threads", ready), "allow")
  assert.equal(frame("about:blank", ready), "allow")
  assert.equal(frame("https://evil.example/", ready), "block")
  assert.equal(frame(home + "/", before), "block")
})

test("a content page opens the device's confirmations in a window of their own, a confirmation hop, and nothing else", () => {
  assert.equal(contentOpen(LOOPBACK + "/confirm?ref=cfm_1", ready), "child")
  assert.equal(contentOpen(LOOPBACK + "/passkey?ref=pk_1", before), "child")
  assert.equal(contentOpen(LOOPBACK + "/unlock", ready), "deny")
  assert.equal(contentOpen(account + "/account/sign#x", ready), "hop")
  assert.equal(contentOpen(account + "/account/sign#x", linux), "deny")
  assert.equal(contentOpen(account + "/account/new#x", ready), "deny", "an account is made by a hop of the top frame alone")
  assert.equal(contentOpen(home + "/", ready), "deny")
  assert.equal(contentOpen("https://evil.example/", ready), "deny")
})

const hop = (request) => `${account}/account/sign#${fragment(request)}`

test("a hop carries a current sign-in or confirmation the selected CYFR issued for its own /login", () => {
  const now = 1790000000000
  let read = 0
  for (const [name, {request}] of Object.entries(signIn["requests"])) {
    const forHome = {...request, return: home + "/login"}
    if (request.purpose === "registry") {
      assert.equal(readHop(hop(forHome), ready, now), null, name)
      continue
    }
    read++
    const kind = request.purpose === "sign_in" ? "sign-in" : "confirmation"
    const other = kind === "sign-in" ? "confirmation" : "sign-in"
    assert.deepEqual(readHop(hop(forHome), ready, kind, now), forHome, name)
    assert.equal(readHop(hop(forHome), ready, other, now), null, `${name}, as a ${other}`)
    assert.equal(readHop(hop(request), ready, kind, now), null, `${name}, returning elsewhere`)
    assert.equal(readHop(hop(forHome), ready, kind, request.expires_at), null, `${name}, expired`)
    assert.equal(readHop(hop(forHome), {...ready, home: "https://bob.example"}, kind, now), null, `${name}, for another CYFR`)
    assert.equal(readHop(hop(forHome).replace(account, "https://evil.example"), ready, kind, now), null, `${name}, at another service`)
    assert.equal(readHop(hop(forHome).replace("/account/sign#", "/account/sign?x=1#"), ready, kind, now), null, `${name}, with a query`)
  }
  assert.ok(read > 0)
  assert.equal(readHop(`${account}/account/sign#${"A".repeat(signIn["max_fragment_bytes"] + 1)}`, ready, "sign-in", now), null)
  assert.equal(readHop(`${account}/account/sign#not-a-request`, ready, "sign-in", now), null)
})

// The page that makes an account, as a CYFR's Create your account sends
// the person there: the name it offers, then the sign-in's request.
const made = (request, name = "") => `${account}/account/new#name=${name}&request=${fragment(request)}`

test("a hop to the page that makes an account carries a current sign-in the selected CYFR issued for its own /login, read by the one reader", () => {
  const now = 1790000000000
  let read = 0
  for (const [name, {request}] of Object.entries(signIn["requests"])) {
    const forHome = {...request, return: home + "/login"}
    if (request.purpose !== "sign_in") {
      assert.equal(readHop(made(forHome), ready, "confirmation", now), null, `${name}: no confirmation makes an account`)
      continue
    }
    read++
    assert.deepEqual(readHop(made(forHome), ready, "sign-in", now), forHome, name)
    assert.deepEqual(readHop(made(forHome, "mira"), ready, "sign-in", now), forHome, `${name}, a name offered`)
    assert.equal(readHop(made(forHome), ready, "confirmation", now), null, `${name}, as a confirmation`)
    assert.equal(readHop(made(request), ready, "sign-in", now), null, `${name}, returning elsewhere`)
    assert.equal(readHop(made(forHome), ready, "sign-in", request.expires_at), null, `${name}, expired`)
    assert.equal(readHop(made(forHome), {...ready, home: "https://bob.example"}, "sign-in", now), null, `${name}, for another CYFR`)
    assert.equal(readHop(made(forHome).replace(account, "https://evil.example"), ready, "sign-in", now), null, `${name}, at another service`)
    assert.equal(readHop(made(forHome).replace("/account/new#", "/account/new?x=1#"), ready, "sign-in", now), null, `${name}, with a query`)
    assert.equal(readHop(made(forHome) + "&more=1", ready, "sign-in", now), null, `${name}, with another field`)
    assert.equal(readHop(made(forHome).replace("#name=&", "#"), ready, "sign-in", now), null, `${name}, with no name field`)
    assert.equal(readHop(`${account}/account/new#${fragment(forHome)}`, ready, "sign-in", now), null, `${name}, as the sign-in's fragment`)
  }
  assert.ok(read > 0)
})

test("the account window loads the sign-in page and the page that makes an account with a request the one reader reads for its ceremony, the recovery continuation, and returns only to the CYFR's /login", () => {
  const now = 1790000000000
  const signing = {...signIn["requests"]["sign_in"].request, return: home + "/login"}
  const confirming = {...signIn["requests"]["confirm"].request, return: home + "/login"}
  assert.equal(accountLoad(hop(signing), ready, "sign-in", now), "allow")
  assert.equal(accountLoad(made(signing), ready, "sign-in", now), "allow")
  assert.equal(accountLoad(hop(confirming), ready, "confirmation", now), "allow")
  // A page that takes a request, at any load of the window, whatever
  // ceremony it shows: with no request, an expired one or another CYFR's.
  for (const kind of ["sign-in", "confirmation", null]) {
    for (const [address, why] of [[account + "/account/new", "no request"], [account + "/account/sign", "no request"],
      [account + "/account/new#x", "no request read"], [made(signing).replace("/account/new", "/account/sign"), "not its page's fragment"],
      [made(signing), "expired", signing.expires_at], [hop(signing), "expired", signing.expires_at],
      [made({...signing, audience: "https://bob.example", return: "https://bob.example/login"}), "another CYFR's"],
      [hop({...confirming, audience: "https://bob.example", return: "https://bob.example/login"}), "another CYFR's"]]) {
      const at = why === "expired" ? signing.expires_at : now
      assert.equal(accountLoad(address, ready, kind, at), "block", `${kind}: ${why}: ${address.split("#")[0]}`)
    }
  }
  assert.equal(accountLoad(made(signing), ready, "confirmation", now), "block", "a confirmation makes no account")
  assert.equal(accountLoad(made(signing), ready, null, now), "block", "no ceremony")
  assert.equal(accountLoad(hop(signing), ready, "confirmation", now), "block", "a sign-in's request in a confirmation")
  assert.equal(accountLoad(account + "/account/recover", ready), "allow")
  assert.equal(accountLoad(home + "/login#answer", ready), "return")
  assert.equal(accountLoad(home + "/login?next=/x#answer", ready), "block")
  for (const elsewhere of [home + "/", home + "/threads", account + "/account/devices", account + "/account/add", account + "/", "https://idp.example/authorize"]) {
    assert.equal(accountLoad(elsewhere, ready, "sign-in", now), "block", elsewhere)
  }
  const same = {home: account, account, accountRoad: true}
  assert.equal(accountLoad(account + "/login#a", same), "return", "a CYFR that is its own account service")
  assert.equal(accountLoad(account + "/", same), "block")
})

test("no page is granted a device, a capture or a credential", () => {
  for (const p of ["media", "display-capture", "geolocation", "notifications", "midi", "hid", "serial", "usb",
    "clipboard-read", "openExternal", "pointerLock", "keyboardLock", "idle-detection", "speaker-selection"]) {
    assert.equal(grants(p), false, p)
  }
  assert.equal(grants("clipboard-sanitized-write"), true)
})

test("content documents deny both passkey calls and workers, keeping their own policies", () => {
  const got = documentHeaders("content", "mainFrame", {
    "permissions-policy": ["camera=(), publickey-credentials-get=(self)"],
    "Content-Security-Policy": ["default-src 'self'"],
    "X-Frame-Options": ["DENY"]
  })
  assert.deepEqual(got["Permissions-Policy"], ["camera=(), publickey-credentials-get=(), publickey-credentials-create=()"])
  assert.deepEqual(got["Content-Security-Policy"], ["default-src 'self'", "worker-src 'none'"])
  assert.deepEqual(got["X-Frame-Options"], ["DENY"])
  assert.ok(!("permissions-policy" in got))
  const frame = documentHeaders("content", "subFrame", {})
  assert.deepEqual(frame["Permissions-Policy"], ["publickey-credentials-get=(), publickey-credentials-create=()"])
  // A tincture frame's document as Prism sends it keeps every grant, its
  // pointer lock among them: the app adds the two denials and nothing more.
  const tincture = documentHeaders("content", "subFrame", {
    "Content-Security-Policy": ["sandbox allow-scripts allow-pointer-lock; default-src 'none'"],
    "Permissions-Policy": ["fullscreen=(self)"]
  })
  assert.deepEqual(tincture["Content-Security-Policy"], ["sandbox allow-scripts allow-pointer-lock; default-src 'none'", "worker-src 'none'"])
  assert.deepEqual(tincture["Permissions-Policy"], ["fullscreen=(self), publickey-credentials-get=(), publickey-credentials-create=()"])
  const script = {"Content-Type": ["text/javascript"]}
  assert.equal(documentHeaders("content", "script", script), script)
})

test("a response to a content page that is gone sets no cookie, and a page's own keeps what it sets", () => {
  for (const type of ["mainFrame", "subFrame", "xhr"]) {
    const sent = () => ({"set-cookie": ["a=1"], "Set-Cookie": ["b=2"], "Content-Type": ["text/html"]})
    const gone = documentHeaders("content", type, sent(), {pageGone: true})
    assert.deepEqual(Object.keys(gone).filter((k) => k.toLowerCase() === "set-cookie"), [], type)
    assert.deepEqual(gone["Content-Type"], ["text/html"], type)
    assert.deepEqual(documentHeaders("content", type, sent(), {pageGone: false})["set-cookie"], ["a=1"], type)
  }
  assert.deepEqual(documentHeaders("account", "xhr", {"set-cookie": ["a=1"]}, {pageGone: true})["set-cookie"], ["a=1"],
    "the account service's storage is not the content's")
})

test("the account window's document frames nothing, keeping its own policies, whichever response it is made of", () => {
  // The account pages' service worker fetches a page as an xhr and answers
  // the next visit's document with that response, or with its kept copy.
  for (const resourceType of ["mainFrame", "subFrame", "xhr", "other"]) {
    const got = documentHeaders("account", resourceType, {"Content-Security-Policy": ["script-src 'self'"]})
    assert.deepEqual(got["Content-Security-Policy"], ["script-src 'self'", "frame-src 'none'"], resourceType)
    assert.ok(!("Permissions-Policy" in got), resourceType)
  }
})

test("the app takes its route's switches, the screen's project and setup's folder, and refuses every other switch", () => {
  assert.deepEqual(SWITCHES, ["proxy-server", "host-resolver-rules", "screen-project", "setup-project"])
  assert.equal(unlistedSwitch(["--screen-project=/home/ana/cyfr"], "linux"), null)
  assert.equal(unlistedSwitch(["--setup-project=/home/ana/setup-here"], "linux"), null)
  assert.equal(unlistedSwitch([], "linux"), null)
  assert.equal(unlistedSwitch(["--proxy-server=socks5://127.0.0.1:1055", "--host-resolver-rules=MAP * ~NOTFOUND"], "linux"), null)
  assert.equal(unlistedSwitch(["https://cyfr.example.com"], "linux"), null, "an address is no switch")
  for (const [args, platform, name] of [
    [["--ignore-certificate-errors"], "linux", "ignore-certificate-errors"],
    [["--enable-logging=stderr"], "linux", "enable-logging"],
    [["--remote-debugging-port=9222"], "darwin", "remote-debugging-port"],
    [["-no-sandbox"], "linux", "no-sandbox"],
    [["--Inspect"], "linux", "inspect"],
    [["/inspect"], "win32", "inspect"],
    [["--proxy-server=x", "--user-data-dir=/tmp/x"], "linux", "user-data-dir"]
  ]) {
    assert.equal(unlistedSwitch(args, platform), name, args.join(" "))
  }
  assert.equal(unlistedSwitch(["--", "--no-sandbox"], "linux"), null, "after --, no switch")
})

test("only --screen-project makes the app a screen, and only for a project it names explicitly", () => {
  assert.equal(screenProject(false, "", "linux"), "", "no switch, no screen")
  assert.equal(screenProject(true, "/home/ana/cyfr", "linux"), "/home/ana/cyfr")
  for (const value of ["", "cyfr", "./cyfr", "~/cyfr", "/home/ana/../bob/cyfr", "/home/ana/./cyfr"]) {
    assert.equal(screenProject(true, value, "linux"), null, `--screen-project=${value}`)
  }
  for (const platform of ["darwin", "win32"]) assert.equal(screenProject(true, "/home/ana/cyfr", platform), null, platform)
})

test("--setup-project names the folder to suggest explicitly, on every system", () => {
  assert.equal(setupProject(false, "", "linux"), "", "no switch, ~/cyfr")
  assert.equal(setupProject(true, "/home/ana/setup-here", "linux"), "/home/ana/setup-here")
  assert.equal(setupProject(true, "/Users/ana/setup here", "darwin"), "/Users/ana/setup here")
  assert.equal(setupProject(true, "C:\\Users\\ana\\setup-here", "win32"), "C:\\Users\\ana\\setup-here")
  for (const value of ["", "setup-here", "./setup-here", "~/setup-here", "/home/ana/../bob", "/home/ana/./setup-here"]) {
    assert.equal(setupProject(true, value, "linux"), null, `--setup-project=${value}`)
  }
  for (const value of ["/Users/ana", "setup-here", "C:setup-here", "C:\\Users\\..\\bob", "C:\\Users/./ana"]) {
    assert.equal(setupProject(true, value, "win32"), null, `--setup-project=${value} on Windows`)
  }
})

test("home names a CYFR and an https account service", () => {
  assert.equal(homeMessage({home, account}), true)
  assert.equal(homeMessage({home, account: "http://accounts.example.com"}), false)
  assert.equal(homeMessage({home: "javascript:x", account}), false)
  assert.equal(relyingParty("https://accounts.example.com:8443"), "accounts.example.com")
})

test("nothing the app prints carries an address's fragment or query, or a path's credential", () => {
  const MARK = "marker'in)it"
  for (const line of [
    `Failed to load URL: https://x.test/auth/passkey/complete#${MARK} with error: ERR_EMPTY_RESPONSE`,
    `Failed to load URL: https://x.test/auth/passkey/complete/${MARK} with error: ERR_EMPTY_RESPONSE`,
    `Failed to load URL: https://x.test/?q=${MARK} with error: ERR_NETWORK_CHANGED`,
    `Failed to load URL: http://127.0.0.1:7340/bootstrap/#token=${MARK} with error: ERR_FAILED`,
    `Error: Get "https://x.test/login?t=${MARK}": EOF`,
    `https://x.test did not answer as a CYFR (wss://x.test/live?t=${MARK}).`,
    `https://user:${MARK}@x.test/p`, `POST /confirm?ref=${MARK}`, `(/login#${MARK})`, `data:text/html,${MARK}`,
    `two https://a.test/#${MARK} and https://b.test/#${MARK}`
  ]) assert.ok(!printed(line).includes("marker"), printed(line))
})

test("what the app prints keeps what is no address's fragment, query or credential", () => {
  for (const line of ["cyfr ended: another program holds 127.0.0.1:7340: close the app using port 7340, then open CYFR again",
    "home: https://cyfr.example.com", "refused: --inspect is not taken", "cannot open /opt/cyfr/resources/cyfr: no such file"]) {
    assert.equal(printed(line), line)
  }
  assert.equal(printed("Failed to load URL: https://x.test:8443/threads#t with error: ERR_FAILED"),
    "Failed to load URL: https://x.test:8443 with error: ERR_FAILED")
})

test("main takes a home's account service by the rule cyfr holds", () => {
  assert.ok(processes.account_services.length > 0)
  for (const s of processes.account_services) assert.equal(homeMessage({home: s.home, account: s.account}), s.accepted, s.name)
})

test("a local CYFR serving its own accounts hops to its sign-in route and the page that makes an account alone, and nothing else of this computer loads", () => {
  const origin = "http://localhost:4000"
  const local = {home: origin, account: origin, accountRoad: true}
  assert.equal(top(origin + "/threads", local, LOOPBACK + "/"), "allow")
  assert.equal(top(origin + "/account/sign#x", local, origin + "/login"), "hop")
  assert.equal(top(origin + "/account/new#x", local, origin + "/setup"), "hop", "Create your account, from its setup page")
  assert.equal(top(origin + "/account/new#x", {...local, account: "https://cyfr.run"}, origin + "/login"), "allow", "the CYFR's own page")
  const now = 1790000000000
  const signing = {...signIn["requests"]["sign_in"].request, audience: origin, return: origin + "/login"}
  assert.equal(accountLoad(`${origin}/account/sign#${fragment(signing)}`, local, "sign-in", now), "allow")
  assert.equal(accountLoad(origin + "/account/sign", local, "sign-in", now), "block", "a sign-in page with no request")
  assert.equal(accountLoad(origin + "/login#answer=x", local), "return")
  assert.equal(accountLoad(origin + "/threads", local), "block")
  for (const elsewhere of ["http://localhost:4100/", "http://127.0.0.1:4000/", "http://localhost:4100/account/sign"]) {
    assert.equal(top(elsewhere, local, origin + "/login"), "block", elsewhere)
    assert.equal(accountLoad(elsewhere, local), "block", elsewhere)
  }
})

test("main reads a CYFR's address and its account service's by the one grammar every side reads", () => {
  const addresses = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/addresses.json", import.meta.url))).addresses
  assert.ok(addresses.length > 0)
  for (const a of addresses) {
    assert.equal(homeMessage({home: a.value, account: "https://cyfr.run"}), a.home, a.value)
    if (a.value.startsWith("https://")) assert.equal(homeMessage({home: "https://cyfr.example.com", account: a.value}), a.home, a.value)
  }
})
