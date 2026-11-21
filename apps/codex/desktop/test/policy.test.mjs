// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"

import {fragment} from "../../../cyfr/assets/account/sign_in.js"
import {
  LOOPBACK, accountLoad, contentLoad, contentOpen, documentHeaders, grants, homeMessage, readHop, relyingParty, retired
} from "../src/policy.js"

const signIn = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/sign_in.json", import.meta.url)))
const home = signIn["home"]
const account = "https://accounts.example.com"
const ready = {home, account, accountRoad: true}
const linux = {home, account, accountRoad: false}
const before = {home: "", account: "", accountRoad: true}

test("a content window loads the device's pages, then the selected CYFR, and nothing else", () => {
  assert.equal(contentLoad(LOOPBACK + "/bootstrap/", before), "allow")
  assert.equal(contentLoad(home + "/", before), "block", "the CYFR before main is ready for it")
  assert.equal(contentLoad(home + "/threads?x=1", ready), "allow")
  assert.equal(contentLoad(home + "/company-login", ready), "company")
  assert.equal(contentLoad(account + "/account/sign#x", ready), "hop")
  assert.equal(contentLoad(account + "/account/sign#x", linux), "block", "no account road on Linux")
  assert.equal(contentLoad(account + "/account/new#x", ready), "block")
  assert.equal(contentLoad(account + "/account/recover", ready), "block", "recovery only within the account window")
  for (const elsewhere of ["https://evil.example/", "http://127.0.0.1:7341/", "http://localhost:7340/", "file:///etc/passwd",
    "javascript:alert(1)", "data:text/html,x", home.replace("https", "http") + "/", "not a url"]) {
    assert.equal(contentLoad(elsewhere, ready), "block", elsewhere)
  }
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
    assert.deepEqual(readHop(hop(forHome), ready, now), forHome, name)
    assert.equal(readHop(hop(request), ready, now), null, `${name}, returning elsewhere`)
    assert.equal(readHop(hop(forHome), ready, request.expires_at), null, `${name}, expired`)
    assert.equal(readHop(hop(forHome), {...ready, home: "https://bob.example"}, now), null, `${name}, for another CYFR`)
    assert.equal(readHop(hop(forHome).replace(account, "https://evil.example"), ready, now), null, `${name}, at another service`)
    assert.equal(readHop(hop(forHome).replace("/account/sign#", "/account/sign?x=1#"), ready, now), null, `${name}, with a query`)
  }
  assert.ok(read > 0)
  assert.equal(readHop(`${account}/account/sign#${"A".repeat(signIn["max_fragment_bytes"] + 1)}`, ready, now), null)
  assert.equal(readHop(`${account}/account/sign#not-a-request`, ready, now), null)
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
  const script = {"Content-Type": ["text/javascript"]}
  assert.equal(documentHeaders("content", "script", script), script)
})

test("the account window's document frames nothing, keeping its own policies", () => {
  const got = documentHeaders("account", "mainFrame", {"Content-Security-Policy": ["script-src 'self'"]})
  assert.deepEqual(got["Content-Security-Policy"], ["script-src 'self'", "frame-src 'none'"])
  assert.ok(!("Permissions-Policy" in got))
})

test("a sign-out is retired only by the signed-out redirect that says so", () => {
  const h = (o) => new Headers(o)
  assert.equal(retired(303, h({"location": "/login?error=signed_out", "cyfr-session-retired": "1"})), true)
  assert.equal(retired(302, h({"location": "https://alice.example/login?error=signed_out", "cyfr-session-retired": "1"})), true)
  assert.equal(retired(303, h({"location": "/login?error=signed_out"})), false, "an anonymous sign-out")
  assert.equal(retired(503, h({"cyfr-session-retired": "1"})), false)
  assert.equal(retired(200, h({"cyfr-session-retired": "1"})), false)
  assert.equal(retired(303, h({"location": "/", "cyfr-session-retired": "1"})), false)
})

test("home names a CYFR and an https account service", () => {
  assert.equal(homeMessage({home, account}), true)
  assert.equal(homeMessage({home, account: "http://accounts.example.com"}), false)
  assert.equal(homeMessage({home: "javascript:x", account}), false)
  assert.equal(relyingParty("https://accounts.example.com:8443"), "accounts.example.com")
})
