// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The account road's steps the passkey proofs share (README.md): the
// app's own account window, given a virtual authenticator as this
// computer's platform authenticator; the passkeys this computer holds;
// the person's answer in the app's "Sign in as" dialog; and this
// computer's device enrolled on the six-word road, the one device that
// can approve a passkey made in the account window.

import {createHash, generateKeyPairSync, randomBytes} from "node:crypto"

import {BrowserWindow, dialog, session} from "electron"

import {DIRECTORY, HOME, LOOPBACK, NAME, arm, atBootstrap, atDevice, atHome, content, contentAt, harvest, js, literal,
  load, lockedOut, log, openCYFR, section, secondClient, submit, waitFor} from "./lib.js"

// The account window's kept storage: the CYFR's and its account
// service's own (src/policy.js accountPartition).
const digest = (origin) => createHash("sha256").update(origin, "ascii").digest("hex")
export const ACCOUNT_PARTITION = `persist:cyfr-account-v2-${digest(HOME)}-${digest(new URL(DIRECTORY).origin)}`

// ---- the person's answer in the app's "Sign in as" dialog ----

// Every list of accounts the dialog offered, in order, without its
// Cancel.
export const offered = []
let choose = () => 0

/** Answer the next dialogs with `pick(buttons)`: an index, Cancel's included. */
export function answerWith(pick) {
  choose = pick
}

// The app shows the dialog through Electron's own; the person's click is
// stood in for here, with what the dialog offered recorded.
dialog.showMessageBox = async (...args) => {
  const options = args.length > 1 ? args[1] : args[0]
  offered.push(options.buttons.slice(0, -1))
  const response = choose(options.buttons)
  log(`sign in as: offered ${JSON.stringify(options.buttons)}, answered ${options.buttons[response]}`)
  return {response, checkboxChecked: false}
}

// ---- the account window and this computer's passkeys ----

// The passkeys this computer's platform authenticator holds, as each
// ceremony left them (CDP's credentialAdded and credentialAsserted): an
// authenticator lives in the page it was added to, so each ceremony's is
// armed afresh with these.
export const held = new Map()

function keep(credential) {
  const known = held.get(credential.credentialId)
  if (!known || credential.signCount >= known.signCount) held.set(credential.credentialId, credential)
}

/** The app's account window, or undefined. */
export function accountWindow() {
  const account = session.fromPartition(ACCOUNT_PARTITION)
  return BrowserWindow.getAllWindows().find((w) => !w.isDestroyed() && w.webContents.session === account)
}

/** The account window once it shows the account page's section `ids`. */
export async function accountAt(ids) {
  const w = await waitFor(() => accountWindow(), "the app's account window")
  await section(w.webContents, ids)
  return w
}

// The authenticator each window was armed with last, by its contents' id:
// a window holds one internal authenticator at a time.
const armed = new Map()

const AUTHENTICATOR = {protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true,
  isUserVerified: true, automaticPresenceSimulation: true}

/**
 * Give window `w` a fresh virtual authenticator holding `credentials`
 * (this computer's passkeys by default), focused, as a ceremony needs.
 */
export async function armWindow(w, credentials = [...held.values()]) {
  const wc = w.webContents
  // A view of the app's window has no show or focus of its own: its page
  // is focused.
  w.show?.()
  w.focus?.()
  wc.focus()
  const cdp = wc.debugger
  if (!cdp.isAttached()) {
    cdp.attach("1.3")
    cdp.on("message", (_event, method, params) => {
      if (method === "WebAuthn.credentialAdded" || method === "WebAuthn.credentialAsserted") keep(params.credential)
    })
  }
  if (armed.has(wc.id)) {
    await cdp.sendCommand("WebAuthn.removeVirtualAuthenticator", {authenticatorId: armed.get(wc.id)}).catch(() => {})
  }
  await cdp.sendCommand("WebAuthn.enable", {enableUI: false})
  const {authenticatorId} = await cdp.sendCommand("WebAuthn.addVirtualAuthenticator", {options: AUTHENTICATOR})
  armed.set(wc.id, authenticatorId)
  for (const credential of credentials) await cdp.sendCommand("WebAuthn.addCredential", {authenticatorId, credential})
  log(`armed window ${wc.id} with ${credentials.length} passkey(s)`)
}

/** A discoverable passkey of the proof's own for `rpId`, usable by an authenticator. */
export function passkeyFor(rpId) {
  const {privateKey} = generateKeyPairSync("ec", {namedCurve: "P-256"})
  return {credentialId: randomBytes(16).toString("base64"), isResidentCredential: true, rpId,
    privateKey: privateKey.export({type: "pkcs8", format: "der"}).toString("base64"),
    userHandle: randomBytes(16).toString("base64"), signCount: 0}
}

// ---- the account road from the CYFR's sign-in page ----

/**
 * The content window at the CYFR's sign-in page: by the chooser's Sign in
 * with your passkey where the chooser shows, and otherwise by an address
 * the content window is given.
 */
export async function toSignIn() {
  const w = content()
  await js(w.webContents, atBootstrap(w.webContents.getURL())
    ? `document.querySelector("#passkey").click(); 1`
    : `location.assign(${literal(HOME + "/login")}); 1`)
  const at = await contentAt((u) => u.startsWith(HOME + "/login"), "the CYFR's sign-in page")
  await waitFor(() => js(at.webContents, `!!document.querySelector(".phx-connected") && !!document.querySelector('[data-test="sign-in"]')`),
    "Sign in with your account")
  return at
}

/** The chooser with both ways on in sight. */
export async function bothWays() {
  return waitFor(async () => {
    const w = content()
    if (!w || w.webContents.isLoading() || !atBootstrap(w.webContents.getURL())) return null
    return await js(w.webContents, `["#passkey", "#words"].every((id) => document.querySelector(id).getClientRects().length > 0)`) ? w : null
  }, "the chooser with both ways on")
}

/** Sign out pressed in Prism's top bar: the lock it led to (lockedOut), at the chooser's ways on. */
export function signOutOfPrism(w) {
  return lockedOut(w, "Prism's Sign out", async () => {
    const link = `[phx-click-away="close_popover"] a[href="/auth/logout"][data-method="post"]`
    if (!await js(w.webContents, `!!document.querySelector(${literal(link)})`)) {
      await js(w.webContents, `document.querySelector('button[phx-click="toggle_popover"][phx-value-name="user"]').click(); 1`)
    }
    await waitFor(() => js(w.webContents, `!!document.querySelector(${literal(link)})`), "Sign out")
    await js(w.webContents, `document.querySelector(${literal(link)}).click(); 1`)
  }, {onward: false})
}

/** Lock pressed in Prism's top bar: the lock it led to, at the chooser's ways on. */
export function lockDevice(w) {
  return lockedOut(w, "the device's Lock", () => js(w.webContents, `document.querySelector('[data-test="device-lock"]').click(); 1`),
    {onward: false})
}

/** Sign in with your account, pressed: the hop to the account window. */
export async function startSignIn(w) {
  await js(w.webContents, `document.querySelector('[data-test="sign-in"]').click(); 1`)
  return accountAt(["ask"])
}

/** Use your passkey, pressed in the account window `a`. */
export async function usePasskey(a) {
  await js(a.webContents, `document.querySelector("#use-passkey").click(); 1`)
}

/** Prism, signed in, once the account road has returned. */
export async function signedInPrism() {
  const w = await contentAt(atHome, "Prism signed in")
  await waitFor(() => js(w.webContents, `!!document.querySelector(".phx-connected")`), "Prism's page connected")
  return w
}

// ---- the device, enrolled on the six-word road ----

/**
 * The account @NAME made at the directory on the second client, and the
 * CYFR set up with it there: answers the second client and the account's
 * recovery code.
 */
export async function accountAndSetup(inputs) {
  const second = await secondClient()
  await load(second, `${DIRECTORY}/account/new#name=${NAME}`)
  await arm()
  await section(second, ["choose"])
  await js(second, `document.querySelector("#name").value = ${literal(NAME)};
    document.querySelector("#name").dispatchEvent(new Event("input", {bubbles: true}));
    const a = document.querySelector("#acceptance:not([hidden]) #accept"); if (a) a.click();
    document.querySelector("#create").click(); 1`)
  await section(second, ["show-code"])
  const recovery = await js(second, `document.querySelector("#show-code:not([hidden]) #code").textContent.trim()`)
  await js(second, `document.querySelector("#saved").click(); 1`)
  await section(second, ["done", "done-return"])
  await harvest()
  await load(second, `${HOME}/setup#${inputs.setup_token}`)
  await waitFor(() => js(second, `!!document.querySelector('[data-test="setup-sign-in"]')`), "the setup page")
  await js(second, `document.querySelector('[data-test="setup-sign-in"]').click(); 1`)
  await waitFor(() => new URL(second.getURL()).pathname === "/account/sign", "the sign page")
  await arm()
  await section(second, ["ask"])
  await js(second, `document.querySelector("#use-passkey").click(); 1`)
  await waitFor(() => second.getURL().startsWith(HOME + "/") && !second.getURL().startsWith(HOME + "/login"),
    "the second client at the CYFR")
  return {second, recovery}
}

// The app's Connect to the CYFR, its account service approved.
async function approve() {
  const w = await contentAt((u) => u.startsWith(LOOPBACK + "/bootstrap/"), "the chooser")
  await waitFor(() => js(w.webContents, `!document.querySelector("#choose").hidden`), "the chooser's form")
  await js(w.webContents, `document.querySelector("#address").value = ${literal(HOME)};
    document.querySelector("#connect").requestSubmit(); 1`)
  await waitFor(() => js(w.webContents, `!document.querySelector("#confirm").hidden`), "the account service asked about")
  await js(w.webContents, `document.querySelector("#approve").click(); 1`)
}

/** Connect on the six-word road, which goes on to the device's pages by itself. */
export async function connectOnward() {
  await approve()
  return contentAt(atDevice, "the device's pages")
}

/**
 * Connect on the passkey road: the CYFR opened, which sends who is not
 * signed in to the chooser's ways on, and from there the device's pages.
 */
export async function connectApproved() {
  await approve()
  await js((await bothWays()).webContents, `document.querySelector("#words").click(); 1`)
  return contentAt(atDevice, "the device's pages")
}

/**
 * The device's key made on the device's pages in `w` and added to the
 * account on the second client: answers the passphrase. The device is
 * then asked into the CYFR (/enroll).
 */
export async function enrolDevice(w, second) {
  await submit(w.webContents, "/passphrase")
  const passphrase = await waitFor(() => js(w.webContents, `document.querySelector("p.code")?.textContent.trim() || null`), "the passphrase")
  await submit(w.webContents, "/make", {secret: passphrase, again: passphrase})
  const add = await waitFor(() => js(w.webContents, `[...document.querySelectorAll("h1")].some((h) => h.textContent === "Add this device to your account") &&
    document.querySelector("p.code")?.textContent.trim()`), "the enrolment page")
  await load(second, add)
  await arm()
  await section(second, ["ask"])
  await js(second, `document.querySelector("#add").click(); 1`)
  await section(second, ["added"])
  await submit(w.webContents, "/enroll", {name: NAME})
  return passphrase
}

/**
 * The account and the CYFR set up on the second client, and this
 * computer's device enrolled through the app's Connect, Prism opened:
 * answers the second client, the passphrase and the recovery code.
 */
export async function accountAndDevice(inputs, connect = connectApproved) {
  const {second, recovery} = await accountAndSetup(inputs)
  const w = await connect()
  const passphrase = await enrolDevice(w, second)
  await openCYFR(w, passphrase)
  return {second, passphrase, recovery}
}

/** The device's pages unlocked with `passphrase` and Prism opened in a session of the device. */
export async function devicePrism(passphrase) {
  const w = content()
  if (!atDevice(w.webContents.getURL())) {
    await js(w.webContents, `location.assign(${literal(LOOPBACK + "/")}); 1`)
  }
  await openCYFR(await contentAt(atDevice, "the device's pages"), passphrase)
  return signedInPrism()
}
