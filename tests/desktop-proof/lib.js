// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What every proof against a real CYFR shares (README.md): a disposable
// entry, bundled from a script's proof.js, that runs the production app,
// startApp of apps/codex/desktop/src/app.js with the installed cyfr, and
// drives it from inside its own main process through each window's
// webContents. No port opens. Beside the app, one window of the proof's
// own is the person's second client: another browser with the account's
// passkey on Chromium's virtual authenticator, attached in process
// through its webContents.debugger.
//
// Each row is a claim about the running app, and fails when the behaviour
// it names is broken; the proof stops at the first row that fails. A
// script's run.sh starts the app once for each of its phases through
// launch.sh (CYFR_DESKTOP_PROOF_PHASE); each launch appends its rows to
// FIXTURE/out/NAME.txt (a PASS or FAIL line a row, then RESULT PHASE
// passed or failed) and writes NAME-PHASE.json. Nothing it records holds
// a credential: no page text, only addresses, headings and notices, and
// everything it writes is scrubbed first (write, scrub.mjs).

import {appendFileSync, readFileSync, readdirSync, writeFileSync} from "node:fs"
import path from "node:path"

import {BrowserWindow, app, net, powerMonitor, session} from "electron"

import {startApp} from "../../apps/codex/desktop/src/app.js"
import {scrub, scrubbed} from "./scrub.mjs"

export const FIXTURE = process.env.CYFR_DESKTOP_PROOF_FIXTURE
export const PHASE = process.env.CYFR_DESKTOP_PROOF_PHASE
export const OUT = path.join(FIXTURE, "out")
export const inputs = JSON.parse(readFileSync(path.join(FIXTURE, "inputs.json"), "utf8"))
export const HOME = inputs.home
export const DIRECTORY = inputs.directory
export const LOOPBACK = "http://127.0.0.1:7340"
export const NAME = "desk-a"
export const STEP_MS = 60_000
export const SECOND_CLIENT = "CYFR desktop proof second client"
export const PROBE = "CYFR desktop proof probe"

// Camera and microphone that a page granted them would get: the media rows
// show the app's refusal, not a missing device (the second client's media
// row is the control).
app.commandLine.appendSwitch("use-fake-device-for-media-stream")

export const said = []
export const record = {rows: [], stopped: null}
// Every line the proof writes goes through here, and its record through
// scrubbed (finish), so that a credential is gone before a byte is written.
const write = (file, line) => appendFileSync(path.join(OUT, file), `${scrub(line)}\n`)
export const log = (line) => write(`${proof}.log`, `${new Date().toISOString()} ${line}`)

export function row(name, ok, what, detail = {}) {
  record.rows.push({name, ok: !!ok, what, detail})
  write(`${proof}.txt`, `${ok ? "PASS" : "FAIL"} ${name}: ${what}${ok ? "" : ` ${scrubbed(detail)}`}`)
  log(`${ok ? "PASS" : "FAIL"} ${name} ${scrubbed(detail)}`)
  if (!ok) throw new Stop(name)
}

export class Stop extends Error {}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) // sleep-ok: the proof's polling interval

export async function waitFor(check, what, ms = STEP_MS) {
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
export const literal = (value) => JSON.stringify(value).replace(/[<>\/\u2028\u2029]/g,
  (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`)

export const js = (wc, code) => wc.executeJavaScript(code, true)
export const text = (wc) => js(wc, "document.body ? document.body.innerText : ''")

// ---- the app's windows, as the person sees them ----

export let client = null // the person's second client, the proof's own window

export function appWindows() {
  return BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed() && w !== client)
}

// The content window: the app's one window with no parent showing a page
// of the device or the CYFR.
export function content() {
  return appWindows().find((w) => !w.getParentWindow() && /^https?:/.test(w.webContents.getURL()))
}

export async function contentAt(test, what) {
  return waitFor(() => {
    const w = content()
    return w && !w.webContents.isLoading() && test(w.webContents.getURL()) ? w : null
  }, what)
}

export const atBootstrap = (url) => url.startsWith(LOOPBACK + "/bootstrap/")
export const atDevice = (url) => url.startsWith(LOOPBACK + "/") && !atBootstrap(url)
export const atHome = (url) => url.startsWith(HOME + "/") && !/^\/(login|setup|auth\/)/.test(new URL(url).pathname)

// A form of the device's pages, by its action, its fields set, submitted.
export async function submit(wc, action, fields = {}, button = null) {
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

export async function seen(host) {
  const r = await fetch(`${inputs.fronts[host]}/seen`)
  return (await r.json()).seen
}

// Whether a request the front recorded came from the app: anything but
// the second client, the proof's probe and the CYFR's own server, which
// reads its accounts there as CYFR/<version>.
export const fromApp = (r) => r.agent !== SECOND_CLIENT && r.agent !== PROBE && !/^CYFR\/\d/.test(r.agent ?? "")

// What of the app reached `host` since `from` requests had.
export async function reachedSince(host, from) {
  return (await seen(host)).slice(from).filter(fromApp)
}

// The front of `host` set to `mode` (front.mjs): it must answer that it took it.
export async function fault(host, mode, fields = {}) {
  const r = await fetch(`${inputs.fronts[host]}/fault`, {method: "POST", headers: {"content-type": "application/json"},
    body: JSON.stringify({mode, ...fields})})
  const answer = await r.json()
  if (r.status !== 200 || answer.mode !== mode) throw new Error(`the front of ${host} did not take ${mode}: ${r.status} ${JSON.stringify(answer)}`)
  return answer
}

export let probes = 0

// Whether the session cookie `value` still opens a page of the CYFR, asked
// from a session of the proof's own holding that cookie alone.
export async function opens(value) {
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
export const refused = (answer) => !answer.opens && [302, 303].includes(answer.status) && new URL(answer.location, HOME).pathname === "/login"

export async function sessionCookie(w) {
  const cookies = await w.webContents.session.cookies.get({url: HOME, name: "_cyfr_key"})
  return cookies[0]?.value ?? null
}

// ---- the second client ----

export async function secondClient() {
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
export const passkeys = new Map()
export let authenticator = null

// A ceremony runs in the focused document alone: the second client is
// brought to the front, as the person brings the browser they sign in
// with, and given a fresh authenticator holding the passkeys.
export async function arm() {
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

export async function harvest() {
  if (!authenticator) return
  const got = await client.webContents.debugger.sendCommand("WebAuthn.getCredentials", {authenticatorId: authenticator})
    .catch(() => ({credentials: []}))
  for (const c of got.credentials) {
    const known = passkeys.get(c.credentialId)
    if (!known || c.signCount >= known.signCount) passkeys.set(c.credentialId, c)
  }
}

// The account pages' shown section and the error it says.
export const shown = (wc) => js(wc, `(() => {
  const s = [...document.querySelectorAll("main > section")].find((x) => !x.hidden)
  const e = s && [...s.querySelectorAll(".error, #refused-text")].map((x) => x.hidden ? "" : x.textContent.trim()).find(Boolean)
  return {section: s ? s.id : null, error: e || null}
})()`)

export async function section(wc, ids) {
  return waitFor(async () => {
    const s = await shown(wc)
    return ids.includes(s.section) || s.error ? s : null
  }, `the account page to show ${ids.join(" or ")}`)
}

export async function load(wc, url) {
  if (wc.getURL().split("#")[0] === url.split("#")[0]) await wc.loadURL("about:blank")
  await wc.loadURL(url).catch(() => {})
}

// From the device's pages to Prism, as a person goes: the passphrase
// where the device is locked, Open CYFR where it is unlocked, until the
// content window shows the CYFR.
export async function openCYFR(w, passphrase) {
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

// ---- steps the proofs share ----

// The chooser's Connect for the CYFR, submitted.
export async function submitConnect(wc) {
  await js(wc, `document.querySelector("#address").value = ${literal(HOME)};
    document.querySelector("#connect").requestSubmit()`)
}

// The chooser's question about an account service, once shown.
export const question = (wc) => waitFor(() => js(wc, `document.querySelector("#confirm").hidden ? null :
  ({home: document.querySelector("#home").textContent, service: document.querySelector("#service").textContent})`),
"the account service to be asked about")

export async function chooserWindow() {
  const w = await contentAt(atBootstrap, "the chooser")
  await waitFor(() => js(w.webContents, `!document.querySelector("#choose").hidden`), "the chooser's form")
  return w
}

// The decision main took on a navigation to `url` in window `wc` (its
// event, as the proof's listener reads it after main's): whether main
// prevented it.
export async function decided(wc, url, frame, what) {
  const d = await waitFor(() => decisions.find((x) => x.window === wc.id && x.url === url &&
    x.name === (frame ? "will-frame-navigate" : "will-navigate") && x.main === !frame), what)
  return d.prevented
}

// The chooser a lock since `shownBefore` (history's length before it)
// brought back: with nothing to tell it goes on to the device's pages by
// itself (told: null); with a notice it stays, the notice's words and its
// way on in sight (told: {words, stayed}, stayed false had it started to
// go on), until Use this computer's key is pressed here. Answers that and
// the device's pages it led to.
export async function afterLock(shownBefore, why) {
  const seenNow = await waitFor(async () => {
    const w = content()
    if (!w || w.webContents.isLoading()) return null
    if (atDevice(w.webContents.getURL())) return {w, told: null}
    if (!atBootstrap(w.webContents.getURL())) return null
    const shows = await js(w.webContents, `(() => { const inSight = (id) => {
      const e = document.querySelector(id); return !!e && e.getClientRects().length > 0 }
      return {onward: inSight("#words"), words: inSight("#notice") ? document.querySelector("#notice").textContent : ""} })()`)
    return shows.onward && w.isVisible() ? {w, told: {words: shows.words}} : null
  }, `the chooser or the device's pages after ${why}`)
  const shown = history.slice(shownBefore).some(atBootstrap)
  if (!seenNow.told) return {shown, told: null, back: seenNow.w}
  // Asked once more of the page, so a move it began has been heard.
  await js(seenNow.w.webContents, "1").catch(() => {})
  const opened = history.findLastIndex(atBootstrap)
  seenNow.told.stayed = !history.slice(opened + 1).some(atDevice)
  if (seenNow.told.stayed) await js(seenNow.w.webContents, `document.querySelector("#words").click(); 1`)
  return {shown, told: seenNow.told, back: await contentAt(atDevice, `the device's pages after ${why}`)}
}

// A lock by `act`, seen whole: the session's cookie opening a page of the
// CYFR before it; the chooser after it and what it told (afterLock); the
// device's pages it led to; the sign-out main sent, as the CYFR's front
// saw it answered; and the cookie after.
export async function lockedOut(w, why, act, then = async () => {}) {
  const cookie = await sessionCookie(w)
  const before = await opens(cookie)
  const from = (await seen("x.test")).length
  const shownBefore = history.length
  await act()
  const {back, shown, told} = await afterLock(shownBefore, why)
  await then()
  const after = await opens(cookie)
  const signOuts = (await reachedSince("x.test", from)).filter((r) => r.method === "POST" && r.path === "/auth/logout")
    .map((r) => ({status: r.status, retired: r.retired, fault: r.fault}))
  return {back, before, after, chooser: {shown, told}, signOuts, cookie}
}

// The sign-out main sent was answered with the CYFR's acknowledgement,
// the chooser came back and, with nothing to tell, went on by itself, and
// the cookie that opened a page before opens nothing now.
export const signedOut = (out) => out.before.opens && refused(out.after) &&
  out.signOuts.length === 1 && [302, 303].includes(out.signOuts[0].status) && out.signOuts[0].retired === "1" &&
  out.chooser.shown && out.chooser.told === null
export const lockDetail = (out) => ({before: out.before, after: out.after, signOuts: out.signOuts, chooser: out.chooser})

// A process's state as /proc shows it: its state line, what it waits in,
// and its core size limit; or why it could not be read.
export function processState(pid) {
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
export function machine() {
  let corePattern
  try {
    corePattern = readFileSync("/proc/sys/kernel/core_pattern", "utf8").trim()
  } catch (e) {
    corePattern = `unreadable: ${e.code}`
  }
  return {corePattern, coreLimit: processState(process.pid).coreLimit}
}

// Every address a window of the app was sent to, in order.
export const history = []
// Main's decision on each navigation: the proof's listeners are added as
// a window is made, before main's, and read the event a tick later.
export const decisions = []
// An address as a row's detail keeps it, scrubbed before it is cut short.
export const bare = (url) => scrub(url).split("#")[0].slice(0, 120)
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
export function childOfThis(word) {
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

// The proof's name: its folder, and the stem of every file it writes.
export let proof = "proof"

export function finish(code) {
  write(`${proof}.txt`, `RESULT ${PHASE} ${code === 0 ? "passed" : "failed"}`)
  writeFileSync(path.join(OUT, `${proof}-${PHASE}.json`), scrubbed(record, 2))
  app.exit(code)
}

// Where every window stood when the proof stopped: its address without
// its fragment, its headings and its notices; never its text, which may
// show a recovery code, a passphrase or a new key.
export async function where() {
  const all = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed())
  return Promise.all(all.map(async (w) => ({
    window: w === client ? "second client" : w.getParentWindow() ? "child" : "app",
    url: bare(w.webContents.getURL()),
    shows: await Promise.race([js(w.webContents, `({headings: [...document.querySelectorAll("h1, h2")].map((h) => h.textContent.trim().slice(0, 120)),
      notices: [...document.querySelectorAll("#notice, .notice, .error, #refused-text")].map((n) => n.textContent.trim().slice(0, 240)).filter(Boolean)})`)
      .catch((e) => `unreadable: ${e.message}`), sleep(3000).then(() => "no answer")]) // sleep-ok: a bound on a page that does not answer
  })))
}

/**
 * Run the proof `name` (its folder): the production app started with
 * `options` beside startApp's own (accountRoad), then the phase this
 * launch is (CYFR_DESKTOP_PROOF_PHASE) of `phases`, writing
 * FIXTURE/out/NAME.txt, NAME.log and NAME-PHASE.json.
 */
export function run(name, phases, options = {}) {
  proof = name
  startApp({...options, cyfr: path.join(process.resourcesPath, "cyfr"), say: (line) => {
    said.push(line)
    log(`app: ${line}`)
  }})
  if (!phases[PHASE]) throw new Error(`no phase ${PHASE}`)
  app.whenReady().then(phases[PHASE]).then(() => finish(record.rows.every((r) => r.ok) ? 0 : 1), async (e) => {
    if (!(e instanceof Stop)) {
      record.stopped = e.stack ?? String(e)
      write(`${proof}.txt`, `FAIL stopped: ${e.message}`)
    }
    record.where = await where().catch((x) => String(x))
    record.processes = app.getAppMetrics().map((m) => ({pid: m.pid, type: m.type, name: m.name ?? null}))
    record.machine = machine()
    record.agents = await Promise.all(Object.keys(inputs.fronts).map(async (h) =>
      [h, [...new Set((await seen(h).catch(() => [])).map((r) => r.agent))]])).catch(() => null)
    log(`where: ${JSON.stringify(record.where)}`)
    finish(1)
  })
}
