// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Both roads against a real CYFR that requires a company sign-in
// (../README.md): it serves its own account pages and names an OIDC
// issuer, idp.test, whose front records whatever reaches it and has
// nothing behind it. Only this client is told that front's address, so
// each request there is this client's and counts, whatever headers it
// carries; the proof's second client never starts a company sign-in. The
// app does not offer company sign-in: on either road a person learns it
// only once the CYFR says so, and is sent to a browser, with no company
// sign-in started and nothing reaching the issuer.

import {app} from "electron"

import {accountAndSetup, armWindow, connectApproved, enrolDevice, startSignIn, toSignIn, usePasskey} from "../account.js"
import {HOME, LOOPBACK, atBootstrap, atDevice, content, contentAt, inputs, js, log, passkeys, reachedSince, row, run, seen,
  submit, text, waitFor} from "../lib.js"

const COMPANY = "This CYFR requires company sign-in. Open its address in a browser to continue. " +
  "The CYFR app does not support company sign-in yet."

// Every request of the company sign-in's: at the issuer's front, and at
// the CYFR's, whose start of one is the only road to the issuer.
async function companySignIn() {
  const issuer = (await seen("idp.test")).map((r) => `${r.method} ${r.path}`)
  const started = (await seen(new URL(HOME).hostname)).filter((r) => r.path.startsWith("/auth/company")).map((r) => `${r.method} ${r.path}`)
  return {issuer, started, none: issuer.length === 0 && started.length === 0}
}

// While set, the chooser in each content window opened is the one a person
// on the passkey road has. cyfr offers that road on macOS and Windows
// alone (Service.opened: the CYFR's sign-in page beside the device's
// pages) and the chooser then stays; on Linux it goes on to the device's
// pages at once. cyfr's answer to the chooser is given that one field;
// the page, its script and its words are cyfr's own, untouched.
let passkeyChooser = false
app.on("browser-window-created", (_event, win) => {
  if (!passkeyChooser || win.getParentWindow()) return
  const cdp = win.webContents.debugger
  cdp.attach("1.3")
  cdp.on("message", async (_e, method, p) => {
    if (method !== "Fetch.requestPaused") return
    try {
      const {body, base64Encoded} = await cdp.sendCommand("Fetch.getResponseBody", {requestId: p.requestId})
      const state = JSON.parse(Buffer.from(body, base64Encoded ? "base64" : "utf8").toString("utf8"))
      if (state.next) state.passkey = `${HOME}/login`
      await cdp.sendCommand("Fetch.fulfillRequest", {requestId: p.requestId, responseCode: 200,
        responseHeaders: [{name: "content-type", value: "application/json"}], body: Buffer.from(JSON.stringify(state)).toString("base64")})
    } catch (e) {
      log(`the chooser's answer was not given the passkey road: ${e.message}`)
    }
  })
  cdp.sendCommand("Fetch.enable", {patterns: [{urlPattern: `${LOOPBACK}/bootstrap/state`, requestStage: "Response"}]})
    .catch((e) => log(`the chooser's answers could not be read: ${e.message}`))
})

// What the app's sign-out since `from` was answered, and what that says of
// the forgery token it had: none sent is none to send, 403 is one the CYFR
// no longer takes.
async function signOut(from) {
  const answers = (await reachedSince(new URL(HOME).hostname, from)).filter((r) => r.method === "POST" && r.path === "/auth/logout")
    .map((r) => ({status: r.status, retired: r.retired}))
  const token = answers.length === 0 ? "missing" : answers.some((a) => a.status === 403) ? "stale" : "taken"
  return {answers, token}
}

async function passkeyPhase() {
  const {second} = await accountAndSetup(inputs)
  const mine = [...passkeys.values()].filter((c) => c.rpId === new URL(HOME).hostname)
  let w = await connectApproved()

  // account_road: the account's passkey signs in at the CYFR, which then
  // asks for its company sign-in: the app closes the CYFR, and the chooser
  // a person on that road has shows the words that send them to a browser.
  // The sign-out's answer is recorded, not asserted (../README.md).
  const a = await startSignIn(await toSignIn())
  await armWindow(a, mine)
  passkeyChooser = true
  const from = (await seen(new URL(HOME).hostname)).length
  await usePasskey(a)
  const chooser = await contentAt(atBootstrap, "the chooser after the company page")
  const shows = () => js(chooser.webContents, `({road: document.querySelector("#road").getClientRects().length > 0,
    words: document.querySelector("#notice").getClientRects().length > 0 ? document.querySelector("#notice").textContent : ""})`)
  const worded = await waitFor(async () => {
    const now = await shows()
    return now.road && now.words.includes(COMPANY) ? now : null
  }, "the company sign-in's words on the chooser", 20_000).catch(() => null)
  const afterAccount = await companySignIn()
  row("account_road", !!worded && afterAccount.none,
    "on the passkey road the company sign-in closes the CYFR in the app, the chooser's words send the person to a browser, and no company sign-in starts or reaches the issuer",
    {chooser: worded ?? await shows().catch((e) => e.message), ...afterAccount, signOut: await signOut(from)})
  passkeyChooser = false
  await js(chooser.webContents, `document.querySelector("#words").click(); 1`)

  // device_road: the six-word road's device, added to the account, is
  // refused by the CYFR for its company sign-in, and its page says so.
  w = await contentAt(atDevice, "the device's pages, by Use this computer's key")
  const passphrase = await enrolDevice(w, second)
  // Unlocked and opened as a person opens it, until the device's page
  // says what the CYFR answered.
  const acted = new Set()
  const said = await waitFor(async () => {
    const page = content()
    if (!page || !atDevice(page.webContents.getURL()) || page.webContents.isLoading()) return null
    if ((await text(page.webContents)).includes(COMPANY)) return true
    const form = await js(page.webContents, `document.querySelector('form[action="/open"]') ? "/open" :
      document.querySelector('form[action="/unlock"]') ? "/unlock" : null`)
    if (form && !acted.has(form + page.webContents.getURL())) {
      acted.add(form + page.webContents.getURL())
      await submit(page.webContents, form, form === "/unlock" ? {secret: passphrase} : {})
    }
    return null
  }, "the device's page saying the CYFR requires a company sign-in")
  const afterDevice = await companySignIn()
  row("device_road", said && afterDevice.none,
    "on the six-word road the CYFR refuses the device for its company sign-in, its page sends the person to a browser, and no company sign-in starts or reaches the issuer",
    afterDevice)
}

run("passkey-company", {passkey: passkeyPhase}, {accountRoad: true})
