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

import {accountAndSetup, armWindow, connectApproved, enrolDevice, startSignIn, toSignIn, usePasskey} from "../account.js"
import {HOME, afterLock, atDevice, content, history, inputs, js, passkeys, reachedSince, row, run, seen, submit, text,
  waitFor} from "../lib.js"

const COMPANY = "This CYFR requires company sign-in. Open its address in a browser to continue. " +
  "The CYFR app does not support company sign-in yet."

// Every request of the company sign-in's: at the issuer's front, and at
// the CYFR's, whose start of one is the only road to the issuer.
async function companySignIn() {
  const issuer = (await seen("idp.test")).map((r) => `${r.method} ${r.path}`)
  const started = (await seen(new URL(HOME).hostname)).filter((r) => r.path.startsWith("/auth/company")).map((r) => `${r.method} ${r.path}`)
  return {issuer, started, none: issuer.length === 0 && started.length === 0}
}

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
  await connectApproved()

  // account_road: the account's passkey signs in at the CYFR, which then
  // asks for its company sign-in: the app closes the CYFR, and the chooser
  // stays with the words that send the person to a browser.
  // The sign-out's answer is recorded, not asserted (../README.md).
  const a = await startSignIn(await toSignIn())
  await armWindow(a, mine)
  const from = (await seen(new URL(HOME).hostname)).length
  const shownBefore = history.length
  await usePasskey(a)
  const {back, told} = await afterLock(shownBefore, "the company page")
  const afterAccount = await companySignIn()
  row("account_road", !!told?.words.includes(COMPANY) && told.stayed && afterAccount.none,
    "on the passkey road the company sign-in closes the CYFR in the app, the chooser stays with the words that send the person to a browser, and no company sign-in starts or reaches the issuer",
    {chooser: told, ...afterAccount, signOut: await signOut(from)})

  // device_road: the six-word road's device, added to the account, is
  // refused by the CYFR for its company sign-in, and its page says so.
  const passphrase = await enrolDevice(back, second)
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
