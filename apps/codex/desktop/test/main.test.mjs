// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The main process (src/app.js) itself, with Electron and the cyfr it
// starts stood in for: each window, session and page main makes is a
// plain object that records what main did to it, and cyfr is a child
// whose lines the test writes and whose input it reads. What a person
// meets on real pages is part D's proof; this pins main's order and its
// decisions.

import assert from "node:assert/strict"
import {EventEmitter} from "node:events"
import {readFileSync} from "node:fs"
import {PassThrough} from "node:stream"
import {mock, test} from "node:test"

import {fragment} from "../../../cyfr/assets/account/sign_in.js"

const signIn = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/sign_in.json", import.meta.url)))
const HOME = signIn["home"]
const ACCOUNT = "https://accounts.example.com"
const READY = "http://127.0.0.1:7340/bootstrap/#token=dG9rZW4"

// ---- Electron, stood in for ----

const world = {}

function reset() {
  world.windows = []
  world.sessions = new Map()
  world.fetched = []
  world.cleared = []
  world.answer = () => ({status: 503, headers: new Headers()})
  world.page = () => Promise.resolve("forgery-token")
  world.app.removeAllListeners()
  world.powerMonitor.removeAllListeners()
  world.quit = false
}

class Contents extends EventEmitter {
  constructor(win, ses) {
    super()
    this.session = ses
    this.url = ""
    this.mainFrame = {processId: 1, routingId: win.id, get url() { return win.webContents.url }}
  }
  getURL() { return this.url }
  executeJavaScript() { return world.page(this) }
  setWindowOpenHandler(h) { this.opens = h }
}

class BrowserWindow extends EventEmitter {
  constructor(options) {
    super()
    this.id = world.windows.length + 1
    this.webContents = new Contents(this, options.webPreferences.session)
    this.destroyed = false
    world.windows.push(this)
  }
  loadURL(url) {
    this.webContents.url = url
    queueMicrotask(() => {
      this.webContents.emit("did-navigate", {}, url)
      this.webContents.emit("did-finish-load")
    })
  }
  destroy() {
    if (this.destroyed) return
    this.destroyed = true
    this.emit("closed")
  }
  isDestroyed() { return this.destroyed }
  isMinimized() { return false }
  show() {}
  restore() {}
  focus() {}
}

function fromPartition(partition) {
  if (!world.sessions.has(partition)) {
    const ses = new EventEmitter()
    Object.assign(ses, {
      partition,
      webRequest: {onHeadersReceived() {}},
      setPermissionRequestHandler() {}, setPermissionCheckHandler() {}, setDevicePermissionHandler() {},
      setDisplayMediaRequestHandler() {},
      // As Electron's session.fetch does with a manual redirect, which the
      // real-CYFR proof met: it rejects rather than answer it.
      async fetch(_url, init) {
        if (init?.redirect === "manual") throw new TypeError("Redirect was cancelled")
        throw new Error("no fetch in this stand-in")
      },
      async clearStorageData() { world.cleared.push(partition) }
    })
    world.sessions.set(partition, ses)
  }
  return world.sessions.get(partition)
}

world.app = Object.assign(new EventEmitter(), {
  commandLine: {getSwitchValue: () => "", hasSwitch: () => false},
  enableSandbox() {}, requestSingleInstanceLock: () => true, relaunch() {}, configureWebAuthn() {},
  whenReady: () => Promise.resolve(),
  exit(code) { world.exited = code },
  quit() {
    const event = {prevented: false, preventDefault() { this.prevented = true }}
    world.app.emit("before-quit", event)
    if (!event.prevented) world.quit = true
  }
})
world.powerMonitor = new EventEmitter()

// ---- cyfr, stood in for ----

function cyfr() {
  const child = new EventEmitter()
  Object.assign(child, {
    stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(), exitCode: null, killed: false,
    kill() { child.killed = true }
  })
  child.heard = []
  child.stdin.setEncoding("utf8")
  child.stdin.on("data", (chunk) => {
    for (const line of chunk.split("\n").filter(Boolean)) child.heard.push(JSON.parse(line))
  })
  child.say = (m) => child.stdout.write(JSON.stringify({version: 1, ...m}) + "\n")
  return child
}

// net.request, answering as world.answer says: a 3xx as a redirect, which
// the app must answer rather than follow, anything else as a response.
function request({method, url, session: ses, redirect}) {
  const r = new EventEmitter()
  let body = ""
  Object.assign(r, {
    setHeader() {},
    abort() { r.aborted = true },
    end(data) {
      body = data
      world.fetched.push({partition: ses.partition, url, body, method, redirect})
      Promise.resolve(world.answer(url)).then((answer) => {
        const raw = Object.fromEntries([...answer.headers].map(([k, v]) => [k, [v]]))
        if (answer.status >= 300 && answer.status < 400) r.emit("redirect", answer.status, method, answer.headers.get("location"), raw)
        else r.emit("response", {statusCode: answer.status, headers: raw, resume() {}})
      })
    }
  })
  return r
}

mock.module("electron", {exports: {
  BrowserWindow, app: world.app, dialog: {showMessageBox: async () => ({response: 0})},
  powerMonitor: world.powerMonitor, session: {fromPartition}, net: {request}
}})
let child = null
mock.module("node:child_process", {exports: {spawn: () => (child = cyfr())}})
const {startApp} = await import("../src/app.js")

// A turn of the event loop: what main does on a line or an event is done.
const settled = () => new Promise((resolve) => setImmediate(resolve))

async function started(accountRoad) {
  reset()
  const said = []
  startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad, say: (line) => said.push(line)})
  await settled()
  child.say({type: "ready", url: READY})
  await settled()
  return said
}

const live = () => world.windows.filter((w) => !w.destroyed)
const content = () => live().find((w) => w.webContents.url.startsWith("http"))

// A navigation of `w`'s top frame to `url`, asked for by its top frame.
function navigate(w, url) {
  const event = {url, isMainFrame: true, initiator: w.webContents.mainFrame, prevented: false,
    preventDefault() { this.prevented = true }}
  w.webContents.emit("will-navigate", event)
  return event
}

// The CYFR at HOME opened on the passkey road, its page showing and its
// forgery token read.
async function signedIn() {
  const said = await started(true)
  child.say({type: "home", home: HOME, account: ACCOUNT})
  child.say({type: "opened", home: HOME})
  await settled()
  await give(content())
  return said
}

// The content window given HOME, as the device's pages open it, and its
// page loaded.
async function give(w) {
  navigate(w, HOME + "/")
  w.loadURL(HOME + "/")
  await settled()
}

test("an interrupted Connect, through main: a proposal a lock ended gives way to the next, a committed one to none", async () => {
  const said = await started(false)
  child.say({type: "home", home: HOME, account: ACCOUNT})
  await settled()
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "home-ready", home: HOME})
  child.say({type: "locked"})
  await settled()
  await settled()
  child.say({type: "home", home: HOME, account: ACCOUNT})
  await settled()
  assert.deepEqual(child.heard.filter((m) => m.type === "home-ready").length, 2, "the same CYFR proposed again")
  assert.ok(!child.killed, said.join("\n"))
  child.say({type: "opened", home: HOME})
  child.say({type: "home", home: "https://bob.example", account: ACCOUNT})
  await settled()
  assert.ok(child.killed, "another proposal after a committed CYFR ends cyfr")
})

test("a lock closes the content and the ceremony before anything is awaited, and signs out with what it held", async () => {
  await signedIn()
  const request = {...signIn["requests"]["another_sign_in"]["request"], return: HOME + "/login", expires_at: Date.now() + 60_000}
  const hop = `${ACCOUNT}/account/sign#${fragment(request)}`
  const page = content()
  page.webContents.url = HOME + "/login"
  navigate(page, hop)
  const account = live().find((w) => w.webContents.url === hop)
  assert.ok(account, "the hop opened the account window")
  world.page = () => new Promise(() => {}) // a page that never answers again
  world.powerMonitor.emit("lock-screen")
  assert.ok(page.destroyed && account.destroyed, "both closed at once")
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "lock"})
  await settled()
  assert.deepEqual(world.fetched.map((f) => [f.url, f.body]), [[HOME + "/auth/logout", "_csrf_token=forgery-token"]])
  assert.equal(content(), undefined, "no chooser before cyfr's locked")
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  assert.match(content().webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\/.*notice=unconfirmed$/)
})

test("cyfr's loss signs out what the content held, and says when it is unconfirmed", async () => {
  await signedIn()
  child.emit("exit", 1, null)
  await settled()
  await settled()
  assert.deepEqual(world.fetched.map((f) => f.url), [HOME + "/auth/logout"])
  const told = live().map((w) => decodeURIComponent(w.webContents.url)).find((u) => u.startsWith("data:"))
  assert.match(told, /CYFR stopped/)
  assert.match(told, /did not confirm that it signed this computer out/)
})

test("closing the content window signs out with what was held for it", async () => {
  await signedIn()
  world.answer = () => ({status: 303, headers: new Headers({"location": "/login?error=signed_out", "cyfr-session-retired": "1"})})
  content().destroy()
  await settled()
  await settled()
  assert.deepEqual(world.fetched.map((f) => f.url), [HOME + "/auth/logout"])
  assert.equal(world.quit, true)
})

test("a lock on the company page signs its session out", async () => {
  await signedIn()
  const event = navigate(content(), HOME + "/company-login")
  assert.ok(event.prevented)
  await settled()
  assert.deepEqual(world.fetched.map((f) => f.url), [HOME + "/auth/logout"])
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  assert.match(content().webContents.url, /notice=company,unconfirmed$/)
})

test("a lock in open H before any page committed is unconfirmed, and the session's storage is cleared", async () => {
  await started(true)
  world.page = () => new Promise(() => {}) // the token never arrives
  child.say({type: "home", home: HOME, account: ACCOUNT})
  child.say({type: "opened", home: HOME})
  await settled()
  const page = content()
  navigate(page, HOME + "/") // given the CYFR; no page has committed
  world.powerMonitor.emit("lock-screen")
  await settled()
  assert.deepEqual(world.fetched, [], "nothing to send without the token")
  assert.ok(world.cleared.includes(page.webContents.session.partition), "the session's storage cleared")
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  assert.match(content().webContents.url, /notice=unconfirmed$/)
})

test("a lock after cyfr committed and before main read opened leaves cyfr running and the chooser ready", async () => {
  await started(false)
  child.say({type: "home", home: HOME, account: ACCOUNT})
  await settled()
  world.powerMonitor.emit("lock-screen")
  child.say({type: "opened", home: HOME})
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  await settled()
  assert.equal(child.killed, false)
  assert.match(content().webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\//)
  const next = navigate(content(), HOME + "/threads")
  assert.equal(next.prevented, false, "main keeps to the CYFR cyfr committed")
})

test("a frame asking the top frame to go to the sign-in route is refused and opens nothing", async () => {
  await signedIn()
  const page = content()
  const request = {...signIn["requests"]["another_sign_in"]["request"], return: HOME + "/login", expires_at: Date.now() + 60_000}
  const event = {url: `${ACCOUNT}/account/sign#${fragment(request)}`, isMainFrame: true, initiator: {processId: 9, routingId: 9},
    prevented: false, preventDefault() { this.prevented = true }}
  page.webContents.emit("will-navigate", event)
  assert.ok(event.prevented)
  assert.equal(live().length, 1, "no account window")
})

test("a CYFR rerouted is a relaunch only after the content closed and its session was signed out", async () => {
  await started(true)
  child.say({type: "home", home: HOME, account: ACCOUNT})
  await settled()
  await give(content())
  world.relaunched = null
  world.app.relaunch = (options) => { world.relaunched = options }
  const page = content()
  child.say({type: "home", home: "https://bob.example", account: ACCOUNT, proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"})
  await settled()
  assert.ok(page.destroyed)
  assert.deepEqual(world.fetched.map((f) => f.url), [HOME + "/auth/logout"])
  await settled()
  assert.ok(world.relaunched?.args.includes("--proxy-server=socks5://127.0.0.1:1055"))
})

test("cyfr's own locked naming a CYFR main never kept to leaves it keeping to none", async () => {
  await started(false)
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  await settled()
  const chooser = content()
  assert.match(chooser.webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\//)
  assert.equal(navigate(chooser, HOME + "/threads").prevented, true)
})

test("a confirmation window loads the address it was opened for, whatever frame the engine names, and nothing else", async () => {
  await signedIn()
  const page = content()
  const url = "http://127.0.0.1:7340/confirm?ref=cfm_1"
  assert.equal(page.webContents.opens({url}).action, "allow")
  const child = new BrowserWindow({webPreferences: {session: page.webContents.session}})
  page.webContents.emit("did-create-window", child)
  const load = (to, initiator) => {
    const event = {url: to, isMainFrame: true, initiator, prevented: false, preventDefault() { this.prevented = true }}
    child.webContents.emit("will-navigate", event)
    return !event.prevented
  }
  const canvas = {processId: 1, routingId: 20} // a frame of the opener, as the engine named it
  assert.equal(load(url, canvas), true, "its first load, of the address the handler opened it for")
  assert.equal(load("http://127.0.0.1:7340/passkey?ref=pk_1", canvas), false, "a later load a frame asks for")
  assert.equal(page.webContents.opens({url: "https://evil.example/"}).action, "deny")
})

test("the sign-out reads the redirect the CYFR answers, and an acknowledged one is confirmed", async () => {
  await signedIn()
  world.answer = () => ({status: 302, headers: new Headers({"location": "/login?error=signed_out", "cyfr-session-retired": "1"})})
  world.powerMonitor.emit("lock-screen")
  await settled()
  assert.deepEqual(world.fetched.map((f) => [f.method, f.redirect]), [["POST", "manual"]])
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  assert.doesNotMatch(content().webContents.url, /unconfirmed/)
})

test("a lock's notice is its own sign-out's: one unconfirmed before does not make a later acknowledged one unconfirmed", async () => {
  await signedIn()
  world.powerMonitor.emit("lock-screen") // the CYFR answers 503: unconfirmed
  await settled()
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  await settled()
  assert.match(content().webContents.url, /notice=unconfirmed$/)
  await give(content())
  world.answer = () => ({status: 303, headers: new Headers({"location": "/login?error=signed_out", "cyfr-session-retired": "1"})})
  world.powerMonitor.emit("lock-screen")
  await settled()
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  await settled()
  await settled()
  assert.equal(world.fetched.length, 2, "each lock sent its sign-out")
  assert.doesNotMatch(content().webContents.url, /unconfirmed/)
})
