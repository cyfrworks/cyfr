// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"

import {fragment} from "../../../cyfr/assets/account/sign_in.js"
import {
  LOOPBACK, SWITCHES, accountLoad, contentNavigation, contentOpen, documentHeaders, grants, homeMessage, readHop,
  relyingParty, retired, unlistedSwitch
} from "../src/policy.js"

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
  assert.equal(top(LOOPBACK + "/bootstrap/", before, ""), "allow")
  assert.equal(top(home + "/", before), "block", "the CYFR before main keeps to it")
  assert.equal(top(home + "/threads?x=1", ready), "allow")
  assert.equal(top(home + "/company-login", ready), "company")
  assert.equal(top(account + "/account/new#x", ready), "block")
  for (const elsewhere of ["https://evil.example/", "http://127.0.0.1:7341/", "http://localhost:7340/", "file:///etc/passwd",
    "javascript:alert(1)", "data:text/html,x", home.replace("https", "http") + "/", "not a url"]) {
    assert.equal(top(elsewhere, ready), "block", elsewhere)
  }
})

test("only the content window's top frame, showing the selected CYFR's page, hops, to the sign-in route alone", () => {
  assert.equal(top(account + "/account/sign#x", ready), "hop")
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
    for (const route of ["/account/sign#x", "/account/recover"]) {
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

test("the account window loads the sign-in page and its recovery continuation, and returns only to the CYFR's /login", () => {
  assert.equal(accountLoad(account + "/account/sign#x", ready), "allow")
  assert.equal(accountLoad(account + "/account/recover", ready), "allow")
  assert.equal(accountLoad(home + "/login#answer", ready), "return")
  assert.equal(accountLoad(home + "/login?next=/x#answer", ready), "block")
  for (const elsewhere of [home + "/", home + "/threads", account + "/account/new", account + "/", "https://idp.example/authorize"]) {
    assert.equal(accountLoad(elsewhere, ready), "block", elsewhere)
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

test("the account window's document frames nothing, keeping its own policies, whichever response it is made of", () => {
  // The account pages' service worker fetches a page as an xhr and answers
  // the next visit's document with that response, or with its kept copy.
  for (const resourceType of ["mainFrame", "subFrame", "xhr", "other"]) {
    const got = documentHeaders("account", resourceType, {"Content-Security-Policy": ["script-src 'self'"]})
    assert.deepEqual(got["Content-Security-Policy"], ["script-src 'self'", "frame-src 'none'"], resourceType)
    assert.ok(!("Permissions-Policy" in got), resourceType)
  }
})

test("a sign-out is retired only by the selected CYFR's own signed-out redirect that says so", () => {
  const h = (o) => new Headers(o)
  const ack = {"cyfr-session-retired": "1"}
  assert.equal(retired(303, h({"location": "/login?error=signed_out", ...ack}), home), true)
  assert.equal(retired(302, h({"location": home + "/login?error=signed_out", ...ack}), home), true)
  assert.equal(retired(303, h({"location": "/login?error=signed_out"}), home), false, "an anonymous sign-out")
  assert.equal(retired(503, h(ack), home), false)
  assert.equal(retired(200, h(ack), home), false)
  assert.equal(retired(303, h({"location": "/", ...ack}), home), false)
  for (const elsewhere of ["/archive/login?error=signed_out", "https://evil.example/login?error=signed_out",
    "/login?error=signed_out&x=1", "/login?error=signed_out#x", "//evil.example/login?error=signed_out"]) {
    assert.equal(retired(303, h({"location": elsewhere, ...ack}), home), false, elsewhere)
  }
})

test("the app takes its route's switches and refuses every other switch", () => {
  assert.deepEqual(SWITCHES, ["proxy-server", "host-resolver-rules"])
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

test("home names a CYFR and an https account service", () => {
  assert.equal(homeMessage({home, account}), true)
  assert.equal(homeMessage({home, account: "http://accounts.example.com"}), false)
  assert.equal(homeMessage({home: "javascript:x", account}), false)
  assert.equal(relyingParty("https://accounts.example.com:8443"), "accounts.example.com")
})
