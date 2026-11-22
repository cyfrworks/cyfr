// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Both roads against a real CYFR that requires a company sign-in
// (../README.md): it serves its own account pages and names an OIDC
// issuer, idp.test, whose front records whatever reaches it and has
// nothing behind it. The app does not offer company sign-in: on either
// road a person learns it only once the CYFR says so, and is sent to a
// browser, with nothing of the app reaching the issuer.

import {powerMonitor} from "electron"

import {accountAndSetup, armWindow, connectApproved, enrolDevice, startSignIn, toSignIn, usePasskey} from "../account.js"
import {HOME, atBootstrap, atDevice, content, contentAt, fromApp, history, inputs, js, passkeys, row, run, seen, submit,
  text, waitFor} from "../lib.js"

const COMPANY = "This CYFR requires company sign-in. Open its address in a browser to continue. " +
  "The CYFR app does not support company sign-in yet."

// What of the app reached the issuer: requests from a browser or from
// cyfr, not the CYFR's own server (which reads the issuer with no agent).
const issuerReached = async () => (await seen("idp.test")).filter((r) => fromApp(r) && r.agent).map((r) => `${r.method} ${r.path}`)

async function passkeyPhase() {
  const {second} = await accountAndSetup(inputs)
  const mine = [...passkeys.values()].filter((c) => c.rpId === new URL(HOME).hostname)
  let w = await connectApproved()

  // account_road: the account's passkey signs in at the CYFR, which then
  // asks for its company sign-in: the app closes the CYFR and its chooser
  // sends the person to a browser.
  const shownBefore = history.length
  const a = await startSignIn(await toSignIn())
  await armWindow(a, mine)
  await usePasskey(a)
  await waitFor(() => history.slice(shownBefore).some((u) => atBootstrap(u) &&
    (new URLSearchParams(new URL(u).hash.slice(1)).get("notice") ?? "").split(",").includes("company")), "the chooser with the company notice")
  w = await contentAt(atDevice, "the device's pages after the company page")
  const chooserNotice = history.slice(shownBefore).filter((u) => atBootstrap(u))
    .map((u) => new URLSearchParams(new URL(u).hash.slice(1)).get("notice") ?? "")
  const reachedAfterAccount = await issuerReached()
  row("account_road", chooserNotice.some((n) => n.split(",").includes("company")) && reachedAfterAccount.length === 0,
    "on the passkey road the CYFR's company sign-in closes it in the app, which sends the person to a browser, and nothing of the app reaches the issuer",
    {chooserNotice, reached: reachedAfterAccount})

  // device_road: the six-word road's device, added to the account, is
  // refused by the CYFR for its company sign-in, and its page says so.
  powerMonitor.emit("lock-screen")
  w = await contentAt(atDevice, "the device's pages after the lock")
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
  const reachedAfterDevice = await issuerReached()
  row("device_road", said && reachedAfterDevice.length === 0,
    "on the six-word road the CYFR refuses the device for its company sign-in, its page sends the person to a browser, and nothing of the app reaches the issuer",
    {reached: reachedAfterDevice})
}

run("passkey-company", {passkey: passkeyPhase}, {accountRoad: true})
