// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The six-word road against a real CYFR (../README.md): a disposable entry
// that runs the production app, startApp of apps/codex/desktop/src/app.js
// with the installed cyfr, and drives it from inside its own main process
// through each window's webContents. No port opens. Beside the app, one
// window of the proof's own is the person's second client: another browser
// with the account's passkey on Chromium's virtual authenticator, attached
// in process through its webContents.debugger.
//
// Each row is a claim about the running app, and fails when the behaviour
// it names is broken; the proof stops at the first row that fails. The
// app is launched three times (CYFR_DESKTOP_PROOF_PHASE): `connect`, the
// road itself, then `remembered` and `changed`, which read the account
// service this computer approved. Each launch appends its rows to
// FIXTURE/out/connect.txt (a PASS or FAIL line a row, then RESULT PHASE
// passed or failed) and writes connect-PHASE.json. Nothing it records
// holds a credential: no page text, only addresses without their
// fragments, headings and notices.

import {appendFileSync, readFileSync, readdirSync, writeFileSync} from "node:fs"
import path from "node:path"

import {BrowserWindow, app, net, powerMonitor, session} from "electron"

import {startApp} from "../../../apps/codex/desktop/src/app.js"

const FIXTURE = process.env.CYFR_DESKTOP_PROOF_FIXTURE
const PHASE = process.env.CYFR_DESKTOP_PROOF_PHASE || "connect"
const OUT = path.join(FIXTURE, "out")
const inputs = JSON.parse(readFileSync(path.join(FIXTURE, "inputs.json"), "utf8"))
const HOME = inputs.home
const DIRECTORY = inputs.directory
const LOOPBACK = "http://127.0.0.1:7340"
const NAME = "desk-a"
const STEP_MS = 60_000
const SECOND_CLIENT = "CYFR desktop proof second client"
const PROBE = "CYFR desktop proof probe"
// An account service the CYFR names once reconfigured (the front's
// directory fault); nothing answers at it.
const OTHER_DIRECTORY = "https://other.test"

// Camera and microphone that a page granted them would get: the media rows
// show the app's refusal, not a missing device (the second client's media
// row is the control).
app.commandLine.appendSwitch("use-fake-device-for-media-stream")

const said = []
const record = {rows: [], stopped: null}
// What the proof writes carries no address's fragment, which may hold the
// run token, an unlock ticket or an enrolment offer: every address in it
// ends at its "#".
const scrub = (text) => String(text).replace(/((?:https?|data):[^\s"'#<>\\]*)#[^\s"'<>)\]\\]*/g, "$1#")
// JSON of `value` with every string in it scrubbed.
const scrubbed = (value, space) => JSON.stringify(value, (_key, v) => typeof v === "string" ? scrub(v) : v, space)
const log = (line) => appendFileSync(path.join(OUT, "connect.log"), `${new Date().toISOString()} ${scrub(line)}\n`)

function row(name, ok, what, detail = {}) {
  record.rows.push({name, ok: !!ok, what, detail})
  appendFileSync(path.join(OUT, "connect.txt"), `${ok ? "PASS" : "FAIL"} ${name}: ${what}${ok ? "" : ` ${scrubbed(detail)}`}\n`)
  log(`${ok ? "PASS" : "FAIL"} ${name} ${scrubbed(detail)}`)
  if (!ok) throw new Stop(name)
}

class Stop extends Error {}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) // sleep-ok: the proof's polling interval

async function waitFor(check, what, ms = STEP_MS) {
  const until = Date.now() + ms
  let last
  while (Date.now() < until) {
    try {
      last = await check()
      if (last) return last
    } catch (e) {
      last = e.message
    }
    await sleep(200)
  }
  throw new Error(`timed out waiting for ${what} (${JSON.stringify(last)})`)
}

// A value written into a script the proof runs in a page: JSON, with the
// characters that could end a script or a line in it escaped.
const literal = (value) => JSON.stringify(value).replace(/[<>\/\u2028\u2029]/g,
  (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`)

const js = (wc, code) => wc.executeJavaScript(code, true)
const text = (wc) => js(wc, "document.body ? document.body.innerText : ''")

// ---- the app's windows, as the person sees them ----

let client = null // the person's second client, the proof's own window

function appWindows() {
  return BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed() && w !== client)
}

// The content window: the app's one window with no parent showing a page
// of the device or the CYFR.
function content() {
  return appWindows().find((w) => !w.getParentWindow() && /^https?:/.test(w.webContents.getURL()))
}

async function contentAt(test, what) {
  return waitFor(() => {
    const w = content()
    return w && !w.webContents.isLoading() && test(w.webContents.getURL()) ? w : null
  }, what)
}

const atBootstrap = (url) => url.startsWith(LOOPBACK + "/bootstrap/")
const atDevice = (url) => url.startsWith(LOOPBACK + "/") && !atBootstrap(url)
const atHome = (url) => url.startsWith(HOME + "/") && !/^\/(login|setup|auth\/)/.test(new URL(url).pathname)

// A form of the device's pages, by its action, its fields set, submitted.
async function submit(wc, action, fields = {}, button = null) {
  await js(wc, `(() => {
    const f = document.querySelector('form[action="${action}"]')
    if (!f) throw new Error("no form ${action} on " + location.origin + location.pathname)
    for (const [k, v] of Object.entries(${literal(fields)})) {
      const inputs = f.querySelectorAll('[name="' + k + '"]')
      if (!inputs.length) throw new Error("no field " + k)
      for (const i of inputs) i.value = v
    }
    const b = ${button ? `f.querySelector(${literal(button)})` : "null"}
    f.requestSubmit(b || undefined)
  })()`)
}

// ---- the fronts and the CYFR, from outside the app ----

async function seen(host) {
  const r = await fetch(`${inputs.fronts[host]}/seen`)
  return (await r.json()).seen
}

// Whether a request the front recorded came from the app: anything but
// the second client, the proof's probe and the CYFR's own server, which
// reads its accounts there as CYFR/<version>.
const fromApp = (r) => r.agent !== SECOND_CLIENT && r.agent !== PROBE && !/^CYFR\/\d/.test(r.agent ?? "")

// What of the app reached `host` since `from` requests had.
async function reachedSince(host, from) {
  return (await seen(host)).slice(from).filter(fromApp)
}

// The front of `host` set to `mode` (front.mjs): it must answer that it took it.
async function fault(host, mode, fields = {}) {
  const r = await fetch(`${inputs.fronts[host]}/fault`, {method: "POST", headers: {"content-type": "application/json"},
    body: JSON.stringify({mode, ...fields})})
  const answer = await r.json()
  if (r.status !== 200 || answer.mode !== mode) throw new Error(`the front of ${host} did not take ${mode}: ${r.status} ${JSON.stringify(answer)}`)
  return answer
}

let probes = 0

// Whether the session cookie `value` still opens a page of the CYFR, asked
// from a session of the proof's own holding that cookie alone.
async function opens(value) {
  const probe = session.fromPartition(`proof-probe-${++probes}`)
  probe.setUserAgent(PROBE)
  await probe.cookies.set({url: HOME, name: "_cyfr_key", value, secure: true})
  return new Promise((resolve, reject) => {
    const r = net.request({url: HOME + "/", session: probe, useSessionCookies: true, redirect: "manual"})
    r.on("redirect", (status, _method, location) => {
      resolve({status, location, opens: false})
      r.abort()
    })
    r.on("response", (answer) => {
      resolve({status: answer.statusCode, location: null, opens: answer.statusCode === 200})
      answer.resume()
    })
    r.on("error", reject)
    r.end()
  })
}

// A probe's answer is a refusal when the CYFR sends it to its sign-in.
const refused = (answer) => !answer.opens && [302, 303].includes(answer.status) && new URL(answer.location, HOME).pathname === "/login"

async function sessionCookie(w) {
  const cookies = await w.webContents.session.cookies.get({url: HOME, name: "_cyfr_key"})
  return cookies[0]?.value ?? null
}

// ---- the second client ----

async function secondClient() {
  client = new BrowserWindow({show: true, width: 1000, height: 800, webPreferences: {partition: "persist:proof-second-client"}})
  // Its own user agent, so the fronts tell its requests from the app's.
  client.webContents.session.setUserAgent(SECOND_CLIENT)
  client.webContents.setUserAgent(SECOND_CLIENT)
  // The control for the media rows: this browser grants a page the camera
  // and the microphone.
  client.webContents.session.setPermissionRequestHandler((_wc, permission, callback) => callback(permission === "media"))
  client.webContents.session.setPermissionCheckHandler((_wc, permission) => permission === "media")
  client.webContents.debugger.attach("1.3")
  client.webContents.on("console-message", (event) => log(`second client console: ${event.message}`))
  // Electron answers a discoverable sign-in only through this event: the
  // person's one account is the one they pick.
  client.webContents.session.on("select-webauthn-account", (event, details, callback) => {
    event.preventDefault()
    callback(details.accounts[0]?.credentialId ?? null)
  })
  return client.webContents
}

// The person's passkeys, as their platform keeps them: the credentials
// each authenticator made, read back after each ceremony and given to the
// fresh authenticator armed before the next (an authenticator lives in
// the page it was added to).
const passkeys = new Map()
let authenticator = null

// A ceremony runs in the focused document alone: the second client is
// brought to the front, as the person brings the browser they sign in
// with, and given a fresh authenticator holding the passkeys.
async function arm() {
  client.show()
  client.focus()
  client.webContents.focus()
  const cdp = client.webContents.debugger
  await harvest()
  if (authenticator) await cdp.sendCommand("WebAuthn.removeVirtualAuthenticator", {authenticatorId: authenticator}).catch(() => {})
  await cdp.sendCommand("WebAuthn.enable", {enableUI: false})
  authenticator = (await cdp.sendCommand("WebAuthn.addVirtualAuthenticator", {options: {protocol: "ctap2",
    transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true,
    automaticPresenceSimulation: true}})).authenticatorId
  for (const credential of passkeys.values()) {
    await cdp.sendCommand("WebAuthn.addCredential", {authenticatorId: authenticator, credential})
  }
  log(`armed with ${passkeys.size} passkey(s): ${[...passkeys.values()].map((c) => `${c.rpId} resident=${c.isResidentCredential}`).join(", ")}`)
}

async function harvest() {
  if (!authenticator) return
  const got = await client.webContents.debugger.sendCommand("WebAuthn.getCredentials", {authenticatorId: authenticator})
    .catch(() => ({credentials: []}))
  for (const c of got.credentials) {
    const known = passkeys.get(c.credentialId)
    if (!known || c.signCount >= known.signCount) passkeys.set(c.credentialId, c)
  }
}

// The account pages' shown section and the error it says.
const shown = (wc) => js(wc, `(() => {
  const s = [...document.querySelectorAll("main > section")].find((x) => !x.hidden)
  const e = s && [...s.querySelectorAll(".error, #refused-text")].map((x) => x.hidden ? "" : x.textContent.trim()).find(Boolean)
  return {section: s ? s.id : null, error: e || null}
})()`)

async function section(wc, ids) {
  return waitFor(async () => {
    const s = await shown(wc)
    return ids.includes(s.section) || s.error ? s : null
  }, `the account page to show ${ids.join(" or ")}`)
}

async function load(wc, url) {
  if (wc.getURL().split("#")[0] === url.split("#")[0]) await wc.loadURL("about:blank")
  await wc.loadURL(url).catch(() => {})
}

// From the device's pages to Prism, as a person goes: the passphrase
// where the device is locked, Open CYFR where it is unlocked, until the
// content window shows the CYFR.
async function openCYFR(w, passphrase) {
  const acted = new Set()
  const pages = []
  await waitFor(async () => {
    const win = content()
    if (!win) return null
    if (atHome(win.webContents.getURL())) return true
    if (!atDevice(win.webContents.getURL()) || win.webContents.isLoading()) return null
    const page = await js(win.webContents, `document.querySelector('form[action="/open"]') ? "unlocked" :
      document.querySelector('form[action="/unlock"]') ? "locked" : null`)
    if (page && !acted.has(page + win.webContents.getURL())) {
      acted.add(page + win.webContents.getURL())
      pages.push(page)
      if (page === "locked") await submit(win.webContents, "/unlock", {secret: passphrase})
      else await submit(win.webContents, "/open")
    }
    return null
  }, "Prism, from the device's pages")
  return pages
}

// ---- the proof ----

// The chooser's Connect for the CYFR, submitted.
async function submitConnect(wc) {
  await js(wc, `document.querySelector("#address").value = ${literal(HOME)};
    document.querySelector("#connect").requestSubmit()`)
}

// The chooser's question about an account service, once shown.
const question = (wc) => waitFor(() => js(wc, `document.querySelector("#confirm").hidden ? null :
  ({home: document.querySelector("#home").textContent, service: document.querySelector("#service").textContent})`),
"the account service to be asked about")

async function chooserWindow() {
  const w = await contentAt(atBootstrap, "the chooser")
  await waitFor(() => js(w.webContents, `!document.querySelector("#choose").hidden`), "the chooser's form")
  return w
}

// The decision main took on a navigation to `url` in window `wc` (its
// event, as the proof's listener reads it after main's): whether main
// prevented it.
async function decided(wc, url, frame, what) {
  const d = await waitFor(() => decisions.find((x) => x.window === wc.id && x.url === url &&
    x.name === (frame ? "will-frame-navigate" : "will-navigate") && x.main === !frame), what)
  return d.prevented
}

// A lock by `act`, seen whole: the session's cookie opening a page of the
// CYFR before it; the device's pages back after it; the sign-out main
// sent, as the CYFR's front saw it answered; the cookie after; and the
// notices the chooser was opened with.
async function lockedOut(w, why, act, then = async () => {}) {
  const cookie = await sessionCookie(w)
  const before = await opens(cookie)
  const from = (await seen("x.test")).length
  const shownBefore = history.length
  await act()
  const back = await contentAt(atDevice, `the device's pages after ${why}`)
  await then()
  const after = await opens(cookie)
  const notices = history.slice(shownBefore).filter((u) => atBootstrap(u))
    .map((u) => new URLSearchParams(new URL(u).hash.slice(1)).get("notice") ?? "")
  const signOuts = (await reachedSince("x.test", from)).filter((r) => r.method === "POST" && r.path === "/auth/logout")
    .map((r) => ({status: r.status, retired: r.retired, fault: r.fault}))
  return {back, before, after, notices, signOuts, cookie}
}

// The sign-out main sent was answered with the CYFR's acknowledgement,
// the chooser was opened and says nothing unconfirmed, and the cookie
// that opened a page before opens nothing now.
const signedOut = (out) => out.before.opens && refused(out.after) &&
  out.signOuts.length === 1 && [302, 303].includes(out.signOuts[0].status) && out.signOuts[0].retired === "1" &&
  out.notices.length > 0 && out.notices.every((n) => !n.split(",").includes("unconfirmed"))
const lockDetail = (out) => ({before: out.before, after: out.after, signOuts: out.signOuts, notices: out.notices})

async function connectPhase() {
  const second = await secondClient()

  // account: @desk-a made at the account directory with the passkey.
  await load(second, `${DIRECTORY}/account/new#name=${NAME}`)
  await arm()
  await section(second, ["choose"])
  await js(second, `document.querySelector("#name").value = ${literal(NAME)};
    document.querySelector("#name").dispatchEvent(new Event("input", {bubbles: true}));
    const a = document.querySelector("#acceptance:not([hidden]) #accept"); if (a) a.click();
    document.querySelector("#create").click()`)
  const code = await section(second, ["show-code"])
  await js(second, `document.querySelector("#saved").click()`)
  const made = await section(second, ["done", "done-return"])
  await harvest()
  row("account", made.section?.startsWith("done") && code.section === "show-code",
    `@${NAME} made at ${DIRECTORY}'s pages with a passkey, on the second client`, made)

  // setup: x.test set up by signing in with that account through its link.
  await load(second, `${HOME}/setup#${inputs.setup_token}`)
  await waitFor(() => js(second, `!!document.querySelector('[data-test="setup-sign-in"]')`), "the setup page")
  await js(second, `document.querySelector('[data-test="setup-sign-in"]').click()`)
  await waitFor(() => new URL(second.getURL()).pathname === "/account/sign", "the sign page")
  await arm()
  await section(second, ["ask"])
  await js(second, `document.querySelector("#use-passkey").click()`)
  const landed = await waitFor(() => atHome(second.getURL()) && second.getURL(), "the second client to land at the CYFR")
  row("setup", !!landed, `${HOME} set up by @${NAME}, signed in on the second client`, {at: bare(landed)})

  // media_control: this run's camera and microphone are there to grant: a
  // browser that grants them, the second client on the CYFR's page, gets
  // both.
  const ask = (where) => `Promise.all([{audio: true}, {video: true}].map((c) => ${where}.navigator.mediaDevices.getUserMedia(c)
    .then((m) => { m.getTracks().forEach((t) => t.stop()); return "granted" }, (e) => e.name)))`
  const control = await js(second, ask("window"))
  row("media_control", control.every((m) => m === "granted"),
    "the run's camera and microphone are granted to a page by a browser that allows them", {control})

  // chooser: the app's first page, saying where this computer's lock goes
  // unheard (the container has no system bus).
  let w = await contentAt(atBootstrap, "the chooser")
  const chooser = await waitFor(async () => {
    const c = await js(w.webContents, `({choose: !document.querySelector("#choose").hidden, warning: document.querySelector("#warning").textContent})`)
    return c.choose && c.warning ? c : null
  }, "the chooser with its warning")
  row("chooser", chooser.warning.startsWith("CYFR cannot tell when this computer locks or sleeps here"),
    "the app opens at Connect to a CYFR and says in one sentence that it cannot hear this computer's lock", chooser)

  // custom_directory: an account service other than cyfr.run is shown
  // whole and asked about.
  const dirBefore = (await seen("dir.test")).length
  await submitConnect(w.webContents)
  const asked = await question(w.webContents)
  row("custom_directory", asked.home === HOME && asked.service === DIRECTORY,
    "a CYFR on another account service than cyfr.run shows it whole and asks about it", asked)
  await js(w.webContents, `document.querySelector("#decline").click()`)
  const declined = await waitFor(() => js(w.webContents, `document.querySelector("#notice").textContent || null`), "the decline")

  // lock_during_connect: a lock while a Connect runs (cyfr's request for
  // the CYFR's sign-in page seen held at its front) ends it: cyfr gives
  // that request up, the chooser comes back and cyfr runs on.
  await fault("x.test", "hold")
  const xFrom = (await seen("x.test")).length
  await submitConnect(w.webContents)
  const inFlight = await waitFor(async () => {
    const all = await seen("x.test")
    const i = all.findIndex((r, n) => n >= xFrom && fromApp(r) && r.path === "/login" && r.fault === "hold" && !r.aborted)
    return i >= 0 ? {index: i} : null
  }, "cyfr's Connect to ask the CYFR")
  const lockedAt = Date.now()
  powerMonitor.emit("lock-screen")
  // Given up after the lock, and before cyfr's own bound on reading a
  // CYFR's sign-in page (10 s from its request) would have.
  const held = await waitFor(async () => {
    const r = (await seen("x.test"))[inFlight.index]
    return r.aborted ? r : null
  }, "cyfr to give the Connect's request up")
  const givenUp = held.abortedAt >= lockedAt && held.abortedAt - held.at < 10_000
  const relocked = await chooserWindow()
  await fault("x.test", "none")
  row("lock_during_connect", givenUp && said.includes("locked: lock-screen") && !said.some((l) => l.startsWith("cyfr ended")),
    "a lock while cyfr's Connect is in flight ends it: cyfr gives its request up, the chooser comes back and cyfr runs on",
  {said, heldFor: held.abortedAt - held.at, afterLock: held.abortedAt - lockedAt})
  w = relocked

  // decline: Cancel said nothing was sent, and from the first question to
  // the approval below nothing of the app reached the account service.
  const again = await (async () => { await submitConnect(w.webContents); return question(w.webContents) })()
  const reached = (await reachedSince("dir.test", dirBefore)).map((r) => `${r.method} ${r.path}`)
  row("decline", declined === "Nothing was sent to that account service." && again.service === DIRECTORY && reached.length === 0,
    "Cancel says nothing was sent; until the account service is approved nothing of the app reaches it, and the next Connect asks again",
    {declined, reached})

  // device_pages: approved, the device's pages.
  await js(w.webContents, `document.querySelector("#approve").click()`)
  w = await contentAt(atDevice, "the device's pages")
  const setupPage = await waitFor(async () => (await text(w.webContents)).includes("Set up CYFR"), "the setup page")
  row("device_pages", setupPage, "once approved, the device's pages open in the content window", {url: bare(w.webContents.getURL())})

  // enrolment_page: the passphrase drawn and given, the enrolment page
  // with the key's code beside the account service's address. That the
  // key is made under the passphrase is the holder's tests' to show.
  await submit(w.webContents, "/passphrase")
  const passphrase = await waitFor(() => js(w.webContents, `document.querySelector("p.code")?.textContent.trim() || null`), "the passphrase")
  await submit(w.webContents, "/make", {secret: passphrase, again: passphrase})
  const enroll = await waitFor(() => js(w.webContents, `(() => {
    const h = [...document.querySelectorAll("h1")].map((x) => x.textContent)
    if (!h.includes("Add this device to your account")) return null
    const b = [...document.querySelectorAll("p b")].map((x) => x.textContent)
    return {code: b[0], service: b[1], add: document.querySelector("p.code")?.textContent.trim()}
  })()`), "the enrolment page")
  row("enrolment_page", enroll.service === DIRECTORY && /^[0-9a-z]{16}$/i.test(enroll.code) && enroll.add.startsWith(DIRECTORY + "/account/add#"),
    "with a passphrase given, the enrolment page shows the key's code beside the account service's address", {...enroll, add: bare(enroll.add)})

  // admission_refused: "I approved it" before any approval is refused.
  await submit(w.webContents, "/enroll", {name: NAME})
  const refusal = await waitFor(() => js(w.webContents, `document.querySelector(".notice")?.textContent.trim() || null`), "a refusal")
  row("admission_refused", /not on @?desk-a|not .*account/i.test(refusal), "a device not yet approved is refused, and says so", {refusal})

  // approved: the second client approves the key with the account's passkey.
  await load(second, enroll.add)
  await arm()
  await section(second, ["ask"])
  const secondCode = await js(second, `document.querySelector("#device-code").textContent.trim()`)
  await js(second, `document.querySelector("#add").click()`)
  const added = await section(second, ["added"])
  row("approved", added.section === "added" && secondCode === enroll.code,
    "the second client shows the same code and adds the key with the passkey", {secondCode, added})

  // prism: the device is admitted and opens Prism in the content window.
  await submit(w.webContents, "/enroll", {name: NAME})
  await openCYFR(w, passphrase)
  w = await contentAt(atHome, "Prism")
  await waitFor(() => js(w.webContents, `!!document.querySelector(".phx-connected")`), "Prism's page connected")
  const first = await sessionCookie(w)
  row("prism", !!first, "the admitted device opens Prism in the content window, signed in", {url: bare(w.webContents.getURL())})

  // A frame of Prism's page, of its own origin, which the page allows the
  // camera and the microphone. Prism's page names no permissions policy of
  // its own: what refuses here is the app's.
  await js(w.webContents, `new Promise((done) => { const f = document.createElement("iframe"); f.id = "proof-frame"; f.name = "proof-frame";
    f.allow = "camera; microphone"; f.srcdoc = "<p>a frame</p>"; f.onload = () => done(); document.body.appendChild(f) })`)

  // passkeys: both passkey calls, made in Prism's page and in its frame,
  // are refused by the permissions policy the app gives every content
  // document, before any authenticator is asked.
  const passkey = (where) => `(async () => { const w = ${where}; const c = new Uint8Array(32)
    // Where nothing refuses the call it waits on an authenticator the
    // content window has none of: no answer within the bound is no refusal.
    const bound = new Promise((done) => setTimeout(() => done("no answer"), 10000)) // sleep-ok: a bound on a call that may never answer
    const r = (p) => Promise.race([p.then(() => "allowed", (e) => e.name + ": " + e.message), bound])
    return [await r(w.navigator.credentials.get({publicKey: {challenge: c, rpId: location.hostname, timeout: 3000, userVerification: "discouraged"}})),
      await r(w.navigator.credentials.create({publicKey: {challenge: c, rp: {name: "proof", id: location.hostname},
        user: {id: c.slice(0, 16), name: "proof", displayName: "proof"}, pubKeyCredParams: [{type: "public-key", alg: -7}], timeout: 3000}}))] })()`
  const calls = {page: await js(w.webContents, passkey("window")), frame: await js(w.webContents, passkey(`document.querySelector("#proof-frame").contentWindow`))}
  const policy = await js(w.webContents, `(() => { const p = (d) => ["publickey-credentials-get", "publickey-credentials-create"]
    .map((f) => d.featurePolicy.allowsFeature(f)); return {page: p(document), frame: p(document.querySelector("#proof-frame").contentDocument)} })()`)
  const byPolicy = (answers) => /^NotAllowedError: .*'publickey-credentials-get' feature is not enabled/.test(answers[0]) &&
    /^NotAllowedError: .*'publickey-credentials-create' feature is not enabled/.test(answers[1])
  row("passkeys", byPolicy(calls.page) && byPolicy(calls.frame) && [...policy.page, ...policy.frame].every((a) => a === false),
    "both passkey calls, in Prism's page and in its frame, are refused by the app's permissions policy", {calls, policy})

  // media: the camera and the microphone, there to grant (media_control),
  // are refused to Prism's page and to its frame.
  const media = {page: await js(w.webContents, ask("window")),
    frame: await js(w.webContents, ask(`document.querySelector("#proof-frame").contentWindow`))}
  row("media", [...media.page, ...media.frame].every((m) => m === "NotAllowedError"),
    "the camera and the microphone are refused to Prism's page and to its frame", media)

  // navigation: each request below is one Prism's page and the frame's
  // own rules let through, so main's decision, read on its event, is what
  // refuses it: the top frame sent elsewhere, a window opened elsewhere,
  // the frame sent to the CYFR's company sign-in, and the frame sending
  // the top frame on, asked from inside the frame (the engine's initiator
  // is the frame).
  const opened = await js(w.webContents, `window.open(${literal(DIRECTORY + "/")}) === null`)
  const windowAnswer = (await waitFor(() => decisions.find((d) => d.window === w.webContents.id && d.name === "window-open" &&
    d.url === DIRECTORY + "/"), "main's decision on the window asked for elsewhere")).action
  const away = DIRECTORY + "/account/devices"
  await js(w.webContents, `location.href = ${literal(away)}; "asked"`)
  const awayPrevented = await decided(w.webContents, away, false, "main's decision on the top frame sent elsewhere")
  const xBefore = (await seen("x.test")).length
  const frame = (name) => w.webContents.mainFrame.frames.find((f) => f.name === name)
  const companyAsked = await frame("proof-frame").executeJavaScript(`location.href = ${literal(HOME + "/company-login")}; "asked"`, true)
  const companyPrevented = await decided(w.webContents, HOME + "/company-login", true, "main's decision on the frame sent to the company sign-in")
  const fromFrame = HOME + "/?from=frame"
  const topAsked = await frame("proof-frame").executeJavaScript(`top.location.href = ${literal(fromFrame)}; "asked"`, true)
  const topPrevented = await decided(w.webContents, fromFrame, false, "main's decision on the frame sending the top frame on")
  const company = (await reachedSince("x.test", xBefore)).filter((r) => r.path === "/company-login").length
  const nav = {opened, windowAnswer, awayPrevented, companyAsked, companyPrevented, company,
    topAsked, topPrevented, showing: bare(w.webContents.getURL())}
  row("navigation", opened && windowAnswer === "deny" && awayPrevented && companyAsked === "asked" && companyPrevented && company === 0 &&
    topAsked === "asked" && topPrevented && atHome(w.webContents.getURL()),
    "main refuses the top frame elsewhere, a window elsewhere, a frame at the company sign-in and a frame moving the top frame", nav)

  // confirm: an API key asked for in Prism waits on a confirmation on this
  // device, in a window of the device's own, with the passphrase again.
  const segment = await js(w.webContents, `(() => { const a = [...document.querySelectorAll("a[href^='/a/']")][0];
    return a ? a.getAttribute("href").split("/")[2] : null })()`)
  await js(w.webContents, `location.assign(${literal(`/a/${segment}/api-keys`)})`)
  await waitFor(() => w.webContents.getURL().includes("/api-keys") && js(w.webContents, `!!document.querySelector(".phx-connected")`),
    "the API keys page")
  // prism_frame_rules: a frame Prism serves (a canvas, /_c/v1/) asking for
  // a window or for the top frame gets neither. Prism's own sandbox on
  // that frame refuses both, as the engine answers the frame at once; this
  // row shows the app keeps Prism's refusal, not a refusal of its own.
  const canvas = await waitFor(() => w.webContents.mainFrame.framesInSubtree.find((f) => f.url.includes("/_c/v1/")), "a frame Prism serves")
  const childrenBefore = appWindows().length
  const canvasAsked = await canvas.executeJavaScript(`(() => { let w; try { w = window.open(${literal(LOOPBACK + "/confirm?ref=cnr_proof")}) }
    catch (e) { return "threw " + e.name } return w === null ? "null" : "a window" })()`, true)
  const canvasTop = await canvas.executeJavaScript(`(() => { try { top.location.href = ${literal(HOME + "/?from=canvas")} }
    catch (e) { return "threw " + e.name } return "asked" })()`, true)
  const prismFrame = {asked: canvasAsked, top: canvasTop, windows: appWindows().length - childrenBefore,
    reached: decisions.some((d) => d.url === HOME + "/?from=canvas")}
  row("prism_frame_rules", canvasAsked === "null" && canvasTop.startsWith("threw") && prismFrame.windows === 0 && !prismFrame.reached,
    "Prism's own frame rules hold in the app: its canvas frame is given no window and cannot move the top frame", prismFrame)

  await js(w.webContents, `[...document.querySelectorAll("button")].find((b) => b.textContent.includes("Create Key")).click()`)
  await waitFor(() => js(w.webContents, `!!document.querySelector('#api-key-form input[name="name"]')`), "the key's form")
  await js(w.webContents, `(() => { const i = document.querySelector('#api-key-form input[name="name"]'); i.value = "desktop-proof";
    i.dispatchEvent(new Event("input", {bubbles: true})); document.querySelector('#api-key-form button[type="submit"]').click() })()`)
  await waitFor(() => js(w.webContents, `!!document.querySelector('[data-test="confirm-device"]')`), "Confirm on this device")
  await js(w.webContents, `document.querySelector('[data-test="confirm-device"]').click()`)
  const confirm = await waitFor(() => appWindows().find((x) => x.getParentWindow() === w && x.webContents.getURL().startsWith(LOOPBACK + "/confirm")),
    "the device's confirmation window")
  const confirmForm = () => js(confirm.webContents, `!!document.querySelector('form[action="/confirm/decide"]')`)
  await waitFor(confirmForm, "the confirmation page")
  // A wrong passphrase first: refused, the same confirmation asked again,
  // and no key shown in Prism.
  const loads = () => history.length
  const loadsBefore = loads()
  await submit(confirm.webContents, "/confirm/decide", {secret: passphrase + " wrong"}, 'button[value="confirm"]')
  const wrong = await waitFor(async () => loads() > loadsBefore && !confirm.webContents.isLoading() && await confirmForm() &&
    js(confirm.webContents, `document.querySelector(".notice")?.textContent.trim() || null`), "the wrong passphrase's refusal")
  const keyAfterWrong = (await text(w.webContents)).includes("It will not be shown again")
  await submit(confirm.webContents, "/confirm/decide", {secret: passphrase}, 'button[value="confirm"]')
  const shownKey = await waitFor(async () => (await text(w.webContents)).includes("It will not be shown again"), "the key shown")
  row("confirm", !!wrong && !keyAfterWrong && shownKey,
    "a key asked for in Prism waits on this device's own window: a wrong passphrase is refused and asked again, the right one confirms it",
    {wrong, keyAfterWrong, child: confirm.isDestroyed() ? "closed" : bare(confirm.webContents.getURL())})

  // The lock rows. On this road cyfr's lock also retires the session
  // through the device's channel, so the cookie refused afterwards does
  // not tell which retired it; the sign-out's own acknowledgement, read
  // at the CYFR's front, shows main's sign-out ran and was confirmed. The
  // passkey road, with no device channel, shows the sign-out alone
  // retiring the session.

  // lock: the device's Lock in Prism's top bar.
  let out = await lockedOut(w, "the device's Lock", () => js(w.webContents, `document.querySelector('[data-test="device-lock"]').click()`))
  row("lock", signedOut(out),
    "the device's Lock closes Prism; main's sign-out of a session that opened a page is acknowledged, and its cookie opens nothing", lockDetail(out))

  // reconnect: unlocked again with the passphrase, a new session.
  const start = await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")
  const renewed = await sessionCookie(w)
  row("reconnect", start[0] === "locked" && !!renewed && renewed !== out.cookie,
    "the lock left the device locked; its passphrase opens Prism again under a new session", {start})

  // system_lock: the computer's lock closes Prism at once, before anything
  // is awaited, and signs its session out.
  const prism = w
  out = await lockedOut(w, "the computer's lock", async () => {
    powerMonitor.emit("lock-screen")
    row("system_lock_at_once", prism.isDestroyed(), "the computer's lock closes Prism's window at once", {})
  })
  row("system_lock", signedOut(out),
    "after the computer's lock main's sign-out is acknowledged and the cookie that opened a page opens nothing", lockDetail(out))
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // offline_lock: with the CYFR's front down (its control answered so),
  // the lock still closes Prism and the chooser says the sign-out is
  // unconfirmed.
  out = await lockedOut(w, "a lock while the CYFR is unreachable", async () => {
    await fault("x.test", "down")
    powerMonitor.emit("lock-screen")
  }, () => fault("x.test", "none"))
  row("offline_lock", out.before.opens && out.notices.some((n) => n.split(",").includes("unconfirmed")) &&
    out.signOuts.every((r) => r.fault === "down"),
  "a lock while the CYFR cannot be reached closes Prism and says the sign-out is unconfirmed", lockDetail(out))
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // renderer_killed: Prism's page's process ended by the kill signal, as
  // the kernel ends one when memory runs out: the engine reports the page
  // gone, the app locks at once, and its sign-out is acknowledged.
  const killed = {pid: w.webContents.getOSProcessId()}
  out = await lockedOut(w, "Prism's page's process killed", async () => {
    const prism = w
    const start = Date.now()
    prism.webContents.once("render-process-gone", (_e, details) => {
      // Main's own handler ran first (it was added as the window was made).
      Object.assign(killed, {reason: details.reason, reportedMs: Date.now() - start, closedAtOnce: prism.isDestroyed()})
    })
    log(`killing the renderer of window ${prism.webContents.id}, pid ${killed.pid}`)
    process.kill(killed.pid, "SIGKILL")
  })
  row("renderer_killed", killed.reason === "killed" && killed.closedAtOnce && said.includes("locked: the page stopped") && signedOut(out),
    "Prism's page's process killed: the engine reports it gone, the app closes Prism at once and its sign-out is acknowledged",
    {...lockDetail(out), killed})
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // The forced crash, recorded and not asserted (../README.md): the
  // engine's own crash of Prism's page, which on some machines begins and
  // does not finish, so that the engine reports nothing. The record keeps
  // whether and when the engine reported the page gone; when it did not
  // within 15 s, the process's state and this machine's core pattern, and
  // then the proof ends that process itself and goes on.
  record.forcedCrash = await forcedCrash(w)
  log(`forced crash: ${JSON.stringify(record.forcedCrash)}`)
  await openCYFR(await contentAt(atDevice, "the device's pages after the forced crash"), passphrase)
  w = await contentAt(atHome, "Prism again")

  // process_loss: cyfr killed while Prism holds a session: the app closes
  // its content for good, signs the session out, confirmed, and says why.
  const cookie = await sessionCookie(w)
  const before = await opens(cookie)
  const from = (await seen("x.test")).length
  process.kill(childOfThis("desktop-serve"), "SIGKILL")
  const message = await waitFor(() => appWindows().find((x) => x.webContents.getURL().startsWith("data:")), "the app's message")
  const told = decodeURIComponent(message.webContents.getURL())
  const signOuts = (await reachedSince("x.test", from)).filter((r) => r.method === "POST" && r.path === "/auth/logout")
    .map((r) => ({status: r.status, retired: r.retired}))
  const after = await opens(cookie)
  row("process_loss", before.opens && told.includes("CYFR stopped") && !told.includes("did not confirm") && !content() &&
    signOuts.length === 1 && signOuts[0].retired === "1" && refused(after),
  "cyfr's loss while Prism holds a session closes the content, signs it out, confirmed, and tells the person",
  {told: told.replace(/^.*<p>/, "").replace(/<\/p>$/, ""), before, after, signOuts})
}

// The engine's forced crash of window `w`'s page, and what followed.
async function forcedCrash(w) {
  const wc = w.webContents
  const pid = wc.getOSProcessId()
  const start = Date.now()
  const gone = new Promise((resolve) => wc.once("render-process-gone", (_e, details) =>
    resolve({reason: details.reason, afterMs: Date.now() - start})))
  const within = (ms) => Promise.race([gone, sleep(ms).then(() => null)]) // sleep-ok: how long the record waits on the engine's report
  wc.forcefullyCrashRenderer()
  const reported = await within(15_000)
  if (reported) return {pid, reported}
  const state = processState(pid)
  try {
    process.kill(pid, "SIGKILL")
  } catch (e) {
    return {pid, reported: null, state, machine: machine(), killed: e.code}
  }
  return {pid, reported: null, state, machine: machine(), afterKill: await within(15_000)}
}

// A process's state as /proc shows it: its state line, what it waits in,
// and its core size limit; or why it could not be read.
function processState(pid) {
  const read = (file) => {
    try {
      return readFileSync(`/proc/${pid}/${file}`, "utf8")
    } catch (e) {
      return `unreadable: ${e.code}`
    }
  }
  return {state: /^State:\s*(.*)$/m.exec(read("status"))?.[1] ?? read("status"), waits: read("wchan").trim(),
    coreLimit: /^Max core file size.*$/m.exec(read("limits"))?.[0]?.replace(/\s+/g, " ") ?? read("limits")}
}

// What this machine does with a crashing process: its core pattern and
// this process's core size limit.
function machine() {
  let corePattern
  try {
    corePattern = readFileSync("/proc/sys/kernel/core_pattern", "utf8").trim()
  } catch (e) {
    corePattern = `unreadable: ${e.code}`
  }
  return {corePattern, coreLimit: processState(process.pid).coreLimit}
}

// What a Connect in the chooser `w` led to: the question about an
// account service, or the device's pages without one.
async function connected(w) {
  await submitConnect(w.webContents)
  return waitFor(async () => {
    const c = content()
    if (!c || c.webContents.isLoading()) return null
    if (atDevice(c.webContents.getURL())) return {next: "the device's pages"}
    if (!atBootstrap(c.webContents.getURL())) return null
    return js(c.webContents, `document.querySelector("#confirm").hidden ? null :
      ({next: "asked", home: document.querySelector("#home").textContent, service: document.querySelector("#service").textContent})`)
  }, "the device's pages or a question")
}

// remembered: launched again, the account service this computer approved
// for the CYFR is not asked about again; Connect opens the device's pages.
async function rememberedPhase() {
  const next = await connected(await chooserWindow())
  row("remembered", next.next === "the device's pages", "launched again, the CYFR's approved account service is not asked about again", next)
}

// changed: the CYFR now names another account service (its front
// rewrites the account directory its sign-in page names): Connect asks
// about that one though the earlier was approved, and the earlier
// approval has ended: named again, it is asked about again.
async function changedPhase() {
  const w = await chooserWindow()
  await fault("x.test", "directory", {directory: OTHER_DIRECTORY})
  const other = await connected(w)
  row("directory_changed", other.next === "asked" && other.service === OTHER_DIRECTORY,
    "a CYFR that names another account service than the one approved is asked about afresh", other)
  await js(w.webContents, `document.querySelector("#decline").click()`)
  await waitFor(() => js(w.webContents, `document.querySelector("#notice").textContent || null`), "the decline")
  await fault("x.test", "none")
  const dirBefore = (await seen("dir.test")).length
  const back = await connected(w)
  const reached = (await reachedSince("dir.test", dirBefore)).length
  row("approval_ended", back.next === "asked" && back.service === DIRECTORY && reached === 0,
    "once the CYFR named another, the earlier approval has ended: named again, it is asked about again, and nothing reached it", {...back, reached})
}

const PHASES = {connect: connectPhase, remembered: rememberedPhase, changed: changedPhase}

// Every address a window of the app was sent to, in order.
const history = []
// Main's decision on each navigation: the proof's listeners are added as
// a window is made, before main's, and read the event a tick later.
const decisions = []
// An address as the record keeps it: without its fragment, which carries
// the run token, an unlock ticket or an enrolment offer.
const bare = (url) => String(url).split("#")[0].slice(0, 120)
app.on("browser-window-created", (_event, win) => {
  const wc = win.webContents
  const id = wc.id
  log(`window ${id} created${win.getParentWindow() ? ` with parent ${win.getParentWindow().webContents.id}` : ""}`)
  wc.on("did-start-navigation", (details) => {
    if (details.isMainFrame) history.push(details.url)
    if (details.isMainFrame) log(`window ${id} starts ${bare(details.url)}`)
  })
  // Main's window handler, set after this, answers through this wrapper,
  // which records each answer as main's decision on that request.
  const setHandler = wc.setWindowOpenHandler.bind(wc)
  wc.setWindowOpenHandler = (handler) => setHandler((details) => {
    const answer = handler(details)
    decisions.push({window: id, name: "window-open", url: details.url, action: answer.action})
    log(`window ${id} window-open ${bare(details.url)} ${answer.action}`)
    return answer
  })
  wc.on("did-fail-load", (_e, code, description, url, isMainFrame) => {
    if (isMainFrame) log(`window ${id} failed ${code} ${description} ${bare(url)}`)
  })
  wc.on("did-finish-load", () => log(`window ${id} loaded ${bare(wc.getURL())}`))
  wc.on("render-process-gone", (_e, details) => log(`window ${id} renderer gone ${JSON.stringify(details)}`))
  wc.on("unresponsive", () => log(`window ${id} unresponsive`))
  wc.on("responsive", () => log(`window ${id} responsive`))
  for (const name of ["will-navigate", "will-redirect", "will-frame-navigate"]) {
    wc.on(name, (e) => process.nextTick(() => {
      decisions.push({window: id, name, url: e.url, main: e.isMainFrame, prevented: e.defaultPrevented})
      log(`window ${id} ${name} ${bare(e.url)} main=${e.isMainFrame} ` +
        `initiator=${e.initiator ? `${e.initiator.processId}/${e.initiator.routingId}` : "none"} prevented=${e.defaultPrevented}`)
    }))
  }
})

app.on("child-process-gone", (_e, details) => log(`process gone ${JSON.stringify(details)}`))

// The process this one started whose command line holds `word`.
function childOfThis(word) {
  for (const pid of readdirSync("/proc").filter((d) => /^\d+$/.test(d))) {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8")
      const ppid = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1])
      if (ppid === process.pid && readFileSync(`/proc/${pid}/cmdline`, "utf8").includes(word)) return Number(pid)
    } catch {
      // gone meanwhile
    }
  }
  throw new Error(`no child of the app runs ${word}`)
}

// ---- the run ----

function finish(code) {
  appendFileSync(path.join(OUT, "connect.txt"), `RESULT ${PHASE} ${code === 0 ? "passed" : "failed"}\n`)
  writeFileSync(path.join(OUT, `connect-${PHASE}.json`), scrubbed(record, 2))
  app.exit(code)
}

startApp({cyfr: path.join(process.resourcesPath, "cyfr"), say: (line) => {
  said.push(line)
  log(`app: ${line}`)
}})

// Where every window stood when the proof stopped: its address without
// its fragment, its headings and its notices; never its text, which may
// show a recovery code, a passphrase or a new key.
async function where() {
  const all = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed())
  return Promise.all(all.map(async (w) => ({
    window: w === client ? "second client" : w.getParentWindow() ? "child" : "app",
    url: bare(w.webContents.getURL()),
    shows: await Promise.race([js(w.webContents, `({headings: [...document.querySelectorAll("h1, h2")].map((h) => h.textContent.trim().slice(0, 120)),
      notices: [...document.querySelectorAll("#notice, .notice, .error, #refused-text")].map((n) => n.textContent.trim().slice(0, 240)).filter(Boolean)})`)
      .catch((e) => `unreadable: ${e.message}`), sleep(3000).then(() => "no answer")]) // sleep-ok: a bound on a page that does not answer
  })))
}

if (!PHASES[PHASE]) throw new Error(`no phase ${PHASE}`)
app.whenReady().then(PHASES[PHASE]).then(() => finish(record.rows.every((r) => r.ok) ? 0 : 1), async (e) => {
  if (!(e instanceof Stop)) {
    record.stopped = scrub(e.stack ?? String(e))
    appendFileSync(path.join(OUT, "connect.txt"), `FAIL stopped: ${scrub(e.message)}\n`)
  }
  record.where = await where().catch((x) => String(x))
  record.processes = app.getAppMetrics().map((m) => ({pid: m.pid, type: m.type, name: m.name ?? null}))
  record.machine = machine()
  record.agents = await Promise.all(Object.keys(inputs.fronts).map(async (h) =>
    [h, [...new Set((await seen(h).catch(() => [])).map((r) => r.agent))]])).catch(() => null)
  log(`where: ${JSON.stringify(record.where)}`)
  finish(1)
})
