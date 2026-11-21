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
// Each row is a claim about the running app; the proof stops at the first
// row a later one rests on. It writes FIXTURE/out/connect.txt (a PASS or
// FAIL line a row, then RESULT passed or failed) and connect.json.

import {appendFileSync, readFileSync, readdirSync, writeFileSync} from "node:fs"
import path from "node:path"

import {BrowserWindow, app, net, powerMonitor, session} from "electron"

import {startApp} from "../../../apps/codex/desktop/src/app.js"

const FIXTURE = process.env.CYFR_DESKTOP_PROOF_FIXTURE
const OUT = path.join(FIXTURE, "out")
const inputs = JSON.parse(readFileSync(path.join(FIXTURE, "inputs.json"), "utf8"))
const HOME = inputs.home
const DIRECTORY = inputs.directory
const LOOPBACK = "http://127.0.0.1:7340"
const NAME = "desk-a"
const STEP_MS = 60_000
const SECOND_CLIENT = "CYFR desktop proof second client"

const said = []
const record = {rows: [], stopped: null}
const log = (line) => appendFileSync(path.join(OUT, "connect.log"), `${new Date().toISOString()} ${line}\n`)

function row(name, ok, what, detail = {}) {
  record.rows.push({name, ok: !!ok, what, detail})
  appendFileSync(path.join(OUT, "connect.txt"), `${ok ? "PASS" : "FAIL"} ${name}: ${what}${ok ? "" : ` ${JSON.stringify(detail)}`}\n`)
  log(`${ok ? "PASS" : "FAIL"} ${name} ${JSON.stringify(detail)}`)
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
    if (!f) throw new Error("no form ${action} on " + location.href)
    for (const [k, v] of Object.entries(${JSON.stringify(fields)})) {
      const inputs = f.querySelectorAll('[name="' + k + '"]')
      if (!inputs.length) throw new Error("no field " + k)
      for (const i of inputs) i.value = v
    }
    const b = ${button ? `f.querySelector(${JSON.stringify(button)})` : "null"}
    f.requestSubmit(b || undefined)
  })()`)
}

// ---- the fronts and the CYFR, from outside the app ----

async function seen(host) {
  const r = await fetch(`${inputs.fronts[host]}/seen`)
  return (await r.json()).seen
}

// What of the app reached `host` since `from` requests had: anything but
// the second client and the CYFR's own server, which reads its accounts
// there as CYFR/<version>.
async function reachedSince(host, from) {
  return (await seen(host)).slice(from).filter((r) => r.agent !== SECOND_CLIENT && !/^CYFR\/\d/.test(r.agent ?? ""))
}

async function fault(host, mode) {
  await fetch(`${inputs.fronts[host]}/fault`, {method: "POST", headers: {"content-type": "application/json"},
    body: JSON.stringify({mode})})
}

let probes = 0

// Whether the session cookie `value` still opens a page of the CYFR, asked
// from a session of the proof's own holding that cookie alone.
async function opens(value) {
  const probe = session.fromPartition(`proof-probe-${++probes}`)
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
  await waitFor(async () => {
    const win = content()
    if (!win) return null
    if (atHome(win.webContents.getURL())) return true
    if (!atDevice(win.webContents.getURL()) || win.webContents.isLoading()) return null
    const page = await js(win.webContents, `document.querySelector('form[action="/open"]') ? "unlocked" :
      document.querySelector('form[action="/unlock"]') ? "locked" : null`)
    if (page && !acted.has(page + win.webContents.getURL())) {
      acted.add(page + win.webContents.getURL())
      if (page === "locked") await submit(win.webContents, "/unlock", {secret: passphrase})
      else await submit(win.webContents, "/open")
    }
    return null
  }, "Prism, from the device's pages")
}

// ---- the proof ----

async function proof() {
  const second = await secondClient()

  // account: @desk-a made at the account directory with the passkey.
  await load(second, `${DIRECTORY}/account/new#name=${NAME}`)
  await arm()
  await section(second, ["choose"])
  await js(second, `document.querySelector("#name").value = ${JSON.stringify(NAME)};
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
  row("setup", !!landed, `${HOME} set up by @${NAME}, signed in on the second client`, {at: landed})

  // chooser: the app's first page, saying where this computer's lock goes
  // unheard (the container has no system bus).
  let w = await contentAt(atBootstrap, "the chooser")
  const chooser = await waitFor(async () => {
    const c = await js(w.webContents, `({choose: !document.querySelector("#choose").hidden, warning: document.querySelector("#warning").textContent})`)
    return c.choose && c.warning ? c : null
  }, "the chooser with its warning")
  row("chooser", chooser.warning.startsWith("CYFR cannot tell when this computer locks or sleeps here"),
    "the app opens at Connect to a CYFR and says in one sentence that it cannot hear this computer's lock", chooser)

  // custom_directory: one confirmation, the account service shown whole,
  // before anything reaches it; Cancel sends nothing there.
  const before = (await seen("dir.test")).length
  const connect = async () => {
    await js(w.webContents, `document.querySelector("#address").value = ${JSON.stringify(HOME)};
      document.querySelector("#connect").requestSubmit()`)
    return waitFor(() => js(w.webContents, `document.querySelector("#confirm").hidden ? null :
      ({home: document.querySelector("#home").textContent, service: document.querySelector("#service").textContent})`),
      "the account service to be asked about")
  }
  const asked = await connect()
  const reached = (await reachedSince("dir.test", before)).length
  row("custom_directory", asked.home === HOME && asked.service === DIRECTORY && reached === 0,
    "a CYFR on another account service than cyfr.run shows it whole and asks once, and nothing reaches it before",
    {...asked, reached})
  await js(w.webContents, `document.querySelector("#decline").click()`)
  const declined = await waitFor(() => js(w.webContents, `document.querySelector("#notice").textContent || null`), "the decline")
  const reachedAfter = (await reachedSince("dir.test", before)).length
  row("decline", declined === "Nothing was sent to that account service." && reachedAfter === 0,
    "Cancel says nothing was sent, and nothing reached the account service", {declined, reached: reachedAfter})

  // lock_during_connect: a lock while the approved Connect runs ends it;
  // the app and cyfr go on, and the next Connect asks again.
  await connect()
  await js(w.webContents, `document.querySelector("#approve").click()`)
  powerMonitor.emit("lock-screen")
  const relocked = await contentAt(atBootstrap, "the chooser again after the lock")
  const again = await waitFor(() => js(relocked.webContents, `!document.querySelector("#choose").hidden`), "the chooser's form")
  row("lock_during_connect", again && said.some((l) => l === "locked: lock-screen") && !said.some((l) => l.startsWith("cyfr ended")),
    "a lock during a Connect closes it; the chooser comes back and cyfr runs on", {said})
  w = relocked

  // connect: asked again, approved, the device's pages.
  const second2 = await connect()
  await js(w.webContents, `document.querySelector("#approve").click()`)
  w = await contentAt(atDevice, "the device's pages")
  const setupPage = await waitFor(async () => (await text(w.webContents)).includes("Set up CYFR") && text(w.webContents), "the setup page")
  row("device_pages", !!setupPage && second2.service === DIRECTORY, "once approved, the device's pages open in the content window",
    {url: bare(w.webContents.getURL())})

  // device_key: the passphrase drawn, the device's key made under it, and
  // its code shown beside the account service's address.
  await submit(w.webContents, "/passphrase")
  const passphrase = await waitFor(() => js(w.webContents, `document.querySelector("p.code")?.textContent.trim() || null`), "the passphrase")
  await submit(w.webContents, "/make", {secret: passphrase, again: passphrase})
  const enroll = await waitFor(() => js(w.webContents, `(() => {
    const h = [...document.querySelectorAll("h1")].map((x) => x.textContent)
    if (!h.includes("Add this device to your account")) return null
    const b = [...document.querySelectorAll("p b")].map((x) => x.textContent)
    return {code: b[0], service: b[1], add: document.querySelector("p.code")?.textContent.trim()}
  })()`), "the enrolment page")
  row("device_key", enroll.service === DIRECTORY && /^[0-9a-z]{16}$/i.test(enroll.code) && enroll.add.startsWith(DIRECTORY + "/account/add#"),
    "the key is made under the passphrase; the page shows its code at the account service's address", enroll)

  // admission_refused: "I approved it" before any approval is refused.
  await submit(w.webContents, "/enroll", {name: NAME})
  const refused = await waitFor(() => js(w.webContents, `document.querySelector(".notice")?.textContent.trim() || null`), "a refusal")
  row("admission_refused", /not on @?desk-a|not .*account/i.test(refused), "a device not yet approved is refused, and says so", {refused})

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

  // headers: Prism's real page and a frame of it deny both passkey calls.
  await js(w.webContents, `new Promise((done) => { const f = document.createElement("iframe"); f.id = "proof-frame"; f.name = "proof-frame";
    f.allow = "camera; microphone"; f.srcdoc = "<p>a frame</p>"; f.onload = () => done(); document.body.appendChild(f) })`)
  const policy = await js(w.webContents, `(() => { const p = (d) => ["publickey-credentials-get", "publickey-credentials-create"]
    .map((f) => d.featurePolicy.allowsFeature(f)); return {page: p(document), frame: p(document.querySelector("#proof-frame").contentDocument)} })()`)
  row("headers", [...policy.page, ...policy.frame].every((a) => a === false),
    "Prism's page and its frame are denied both passkey calls", policy)

  // media: the camera and the microphone denied in the page and in a frame
  // the page allows them to.
  const ask = (where) => `Promise.all([{audio: true}, {video: true}].map((c) => ${where}.navigator.mediaDevices.getUserMedia(c)
    .then(() => "granted", (e) => e.name)))`
  const media = {page: await js(w.webContents, ask("window")),
    frame: await js(w.webContents, ask(`document.querySelector("#proof-frame").contentWindow`))}
  row("media", [...media.page, ...media.frame].every((m) => m !== "granted"),
    "the camera and the microphone are refused to Prism's page and to its frame", media)

  // navigation: the top frame's own request elsewhere, a window elsewhere
  // and a frame loading elsewhere are refused; a frame's own request for
  // the top frame is refused, asked from inside the frame (the engine's
  // initiator is the frame).
  const windowsBefore = appWindows().length
  const dirBefore = (await seen("dir.test")).length
  const opened = await js(w.webContents, `window.open(${JSON.stringify(DIRECTORY + "/")}) === null`)
  await js(w.webContents, `location.href = ${JSON.stringify(DIRECTORY + "/account/devices")}`)
  await js(w.webContents, `new Promise((done) => { const f = document.createElement("iframe"); f.name = "proof-away";
    f.src = ${JSON.stringify(DIRECTORY + "/")}; document.body.appendChild(f); setTimeout(done, 1500) })`)
  const frame = (name) => w.webContents.mainFrame.frames.find((f) => f.name === name)
  // A frame Prism's own policy lets the page make, which the app's frame
  // rule refuses: the CYFR's company sign-in. Nothing of it reaches the
  // CYFR from the app.
  const xBefore = (await seen("x.test")).length
  await js(w.webContents, `new Promise((done) => { const f = document.createElement("iframe"); f.name = "proof-company";
    f.src = ${JSON.stringify(HOME + "/company-login")}; document.body.appendChild(f); setTimeout(done, 1500) })`)
  const company = (await reachedSince("x.test", xBefore)).filter((r) => r.path === "/company-login").length
  const awayFrame = frame("proof-away")
  const away = {url: awayFrame?.url ?? null, origin: awayFrame?.origin ?? null,
    reached: (await reachedSince("dir.test", dirBefore)).map((r) => `${r.method} ${r.path} ${r.status}`)}
  await frame("proof-frame").executeJavaScript(`top.location.href = ${JSON.stringify(HOME + "/?from=frame")}`, true).catch(() => {})
  await sleep(2000)
  const stayed = w.webContents.getURL()
  const nav = {opened, windows: appWindows().length - windowsBefore, away, company, stayed}
  row("navigation", opened && nav.windows === 0 && away.reached.length === 0 && away.origin !== DIRECTORY && company === 0 && atHome(stayed) &&
    !stayed.includes("from=frame"),
    "the top frame cannot leave the CYFR or open a window elsewhere, a frame loads neither elsewhere nor the company sign-in, and a frame cannot move the top frame", nav)

  // confirm: an API key asked for in Prism waits on a confirmation on this
  // device, in a window of the device's own, with the passphrase again.
  const segment = await js(w.webContents, `(() => { const a = [...document.querySelectorAll("a[href^='/a/']")][0];
    return a ? a.getAttribute("href").split("/")[2] : null })()`)
  await js(w.webContents, `location.assign(${JSON.stringify(`/a/${segment}/api-keys`)})`)
  await waitFor(() => w.webContents.getURL().includes("/api-keys") && js(w.webContents, `!!document.querySelector(".phx-connected")`),
    "the API keys page")
  // prism_frame: a frame Prism serves (a canvas, /_c/v1/) asks for a
  // window and for the top frame, and gets neither.
  const canvas = await waitFor(() => w.webContents.mainFrame.framesInSubtree.find((f) => f.url.includes("/_c/v1/")), "a frame Prism serves")
  const childrenBefore = appWindows().length
  const canvasAsked = await canvas.executeJavaScript(`(() => { let w; try { w = window.open(${JSON.stringify(LOOPBACK + "/confirm?ref=cnr_proof")}) }
    catch (e) { return "threw " + e.name } return w === null ? "null" : "a window" })()`, true).catch((e) => `failed: ${e.message}`)
  await canvas.executeJavaScript(`try { top.location.href = ${JSON.stringify(HOME + "/?from=canvas")} } catch (e) {}`, true).catch(() => {})
  await sleep(2000)
  const prismFrame = {asked: canvasAsked, windows: appWindows().length - childrenBefore, top: bare(w.webContents.getURL())}
  row("prism_frame", prismFrame.windows === 0 && canvasAsked !== "a window" && !prismFrame.top.includes("from=canvas"),
    "a frame Prism serves asking for a window or for the top frame gets neither", prismFrame)

  await js(w.webContents, `[...document.querySelectorAll("button")].find((b) => b.textContent.includes("Create Key")).click()`)
  await waitFor(() => js(w.webContents, `!!document.querySelector('#api-key-form input[name="name"]')`), "the key's form")
  await js(w.webContents, `(() => { const i = document.querySelector('#api-key-form input[name="name"]'); i.value = "desktop-proof";
    i.dispatchEvent(new Event("input", {bubbles: true})); document.querySelector('#api-key-form button[type="submit"]').click() })()`)
  await waitFor(() => js(w.webContents, `!!document.querySelector('[data-test="confirm-device"]')`), "Confirm on this device")
  await js(w.webContents, `document.querySelector('[data-test="confirm-device"]').click()`)
  const confirm = await waitFor(() => appWindows().find((x) => x.getParentWindow() === w && x.webContents.getURL().startsWith(LOOPBACK + "/confirm")),
    "the device's confirmation window")
  await waitFor(() => js(confirm.webContents, `!!document.querySelector('form[action="/confirm/decide"]')`), "the confirmation page")
  await submit(confirm.webContents, "/confirm/decide", {secret: passphrase}, 'button[value="confirm"]')
  const shownKey = await waitFor(async () => (await text(w.webContents)).includes("It will not be shown again"), "the key shown")
  row("confirm", shownKey, "a key asked for in Prism is confirmed on this device in a window of its own, with the passphrase again",
    {child: confirm.isDestroyed() ? "closed" : bare(confirm.webContents.getURL())})

  // lock: the device's Lock in Prism's top bar closes Prism; the session it
  // held is signed out, confirmed, and its cookie opens nothing more.
  const lockedOut = async (why, act, then = async () => {}) => {
    const cookie = await sessionCookie(w)
    const shownBefore = history.length
    await act()
    const back = await contentAt(atDevice, `the device's pages after ${why}`)
    await then()
    const after = await opens(cookie)
    const notices = history.slice(shownBefore).filter((u) => atBootstrap(u))
      .map((u) => new URLSearchParams(new URL(u).hash.slice(1)).get("notice") ?? "")
    return {back, after, notices, cookie}
  }
  let out = await lockedOut("the device's Lock", () => js(w.webContents, `document.querySelector('[data-test="device-lock"]').click()`))
  log(`lock: ${JSON.stringify({after: out.after, notices: out.notices})}`)
  row("lock", !out.after.opens && out.notices.length > 0 && out.notices.every((n) => !n.includes("unconfirmed")),
    "the device's Lock closes Prism; the session's sign-out is confirmed and its cookie opens nothing", {after: out.after, notices: out.notices})

  // reconnect: unlocked again with the passphrase, a new session.
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")
  const renewed = await sessionCookie(w)
  row("reconnect", !!renewed && renewed !== out.cookie, "the passphrase opens Prism again under a new session", {})

  // system_lock: the computer's lock closes Prism at once, before anything
  // is awaited, and signs its session out.
  const prism = w
  out = await lockedOut("the computer's lock", async () => {
    powerMonitor.emit("lock-screen")
    out = {closedAtOnce: prism.isDestroyed()}
    row("system_lock_at_once", out.closedAtOnce, "the computer's lock closes Prism's window at once", {})
  })
  row("system_lock", !out.after.opens && out.notices.every((n) => !n.includes("unconfirmed")),
    "after the computer's lock the session is signed out, confirmed, and its cookie opens nothing", {after: out.after, notices: out.notices})
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // offline_lock: with the CYFR unreachable, the lock still closes Prism
  // and the chooser says the sign-out is unconfirmed.
  await fault("x.test", "down")
  out = await lockedOut("a lock while the CYFR is unreachable", async () => powerMonitor.emit("lock-screen"),
    () => fault("x.test", "none"))
  row("offline_lock", out.notices.some((n) => n.includes("unconfirmed")),
    "a lock while the CYFR cannot be reached closes Prism and says the sign-out is unconfirmed", {notices: out.notices, after: out.after})
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // renderer_loss: Prism's page stopping locks the app.
  out = await lockedOut("Prism's page stopping", async () => w.webContents.forcefullyCrashRenderer())
  row("renderer_loss", said.includes("locked: the page stopped") && !out.after.opens,
    "Prism's page stopping locks the app and signs its session out", {after: out.after})

  // process_loss: cyfr killed, the app closes its content for good and
  // says why.
  const cyfr = childOfThis("desktop-serve")
  process.kill(cyfr, "SIGKILL")
  const message = await waitFor(() => appWindows().find((x) => x.webContents.getURL().startsWith("data:")), "the app's message")
  const told = decodeURIComponent(message.webContents.getURL())
  row("process_loss", told.includes("CYFR stopped") && !content(), "cyfr's loss closes the content and tells the person", {told})

  record.done = true
}

// Every address a window of the app was sent to, in order.
const history = []
// An address as the log keeps it: without its fragment, which carries the
// run token or an unlock ticket.
const bare = (url) => url.split("#")[0].slice(0, 120)
app.on("browser-window-created", (_event, win) => {
  const wc = win.webContents
  const id = wc.id
  log(`window ${id} created${win.getParentWindow() ? ` with parent ${win.getParentWindow().webContents.id}` : ""}`)
  wc.on("did-start-navigation", (details) => {
    if (details.isMainFrame) history.push(details.url)
    if (details.isMainFrame) log(`window ${id} starts ${bare(details.url)}`)
  })
  wc.on("did-fail-load", (_e, code, description, url, isMainFrame) => {
    if (isMainFrame) log(`window ${id} failed ${code} ${description} ${bare(url)}`)
  })
  wc.on("did-finish-load", () => log(`window ${id} loaded ${bare(wc.getURL())}`))
  for (const name of ["will-navigate", "will-redirect", "will-frame-navigate"]) {
    wc.on(name, (e) => process.nextTick(() => log(`window ${id} ${name} ${bare(e.url)} main=${e.isMainFrame} ` +
      `initiator=${e.initiator ? `${e.initiator.processId}/${e.initiator.routingId}` : "none"} prevented=${e.defaultPrevented}`)))
  }
})

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
  appendFileSync(path.join(OUT, "connect.txt"), `RESULT ${code === 0 ? "passed" : "failed"}\n`)
  writeFileSync(path.join(OUT, "connect.json"), JSON.stringify(record, null, 2))
  app.exit(code)
}

startApp({cyfr: path.join(process.resourcesPath, "cyfr"), say: (line) => {
  said.push(line)
  log(`app: ${line}`)
}})

// Where every window stood when the proof stopped: its address and what
// it showed.
async function where() {
  const all = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed())
  return Promise.all(all.map(async (w) => ({
    window: w === client ? "second client" : w.getParentWindow() ? "child" : "app",
    url: bare(w.webContents.getURL()),
    text: (await Promise.race([text(w.webContents).catch((e) => `unreadable: ${e.message}`), sleep(3000).then(() => "no answer")]))
      .slice(0, 1500)
  })))
}

app.whenReady().then(proof).then(() => finish(record.rows.every((r) => r.ok) ? 0 : 1), async (e) => {
  if (!(e instanceof Stop)) {
    record.stopped = e.stack ?? String(e)
    appendFileSync(path.join(OUT, "connect.txt"), `FAIL stopped: ${e.message}\n`)
  }
  record.where = await where().catch((x) => String(x))
  record.agents = await Promise.all(Object.keys(inputs.fronts).map(async (h) =>
    [h, [...new Set((await seen(h).catch(() => [])).map((r) => r.agent))]])).catch(() => null)
  log(`where: ${JSON.stringify(record.where)}`)
  finish(1)
})

