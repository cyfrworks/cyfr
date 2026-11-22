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
  world.switches = []
  world.windows = []
  world.sessions = new Map()
  world.fetched = []
  world.cleared = []
  world.answer = () => ({status: 503, headers: new Headers()})
  world.page = () => Promise.resolve("forgery-token")
  world.wholeDocument = false
  world.refuseLoad = false
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
  reload() {
    this.reloaded = [...(this.reloaded ?? []), this.url]
    this.emit("did-start-navigation", {url: this.url, isMainFrame: true, isSameDocument: false})
    queueMicrotask(() => {
      this.emit("did-navigate", {}, this.url)
      this.emit("did-finish-load")
    })
  }
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
  // As Electron 45 makes a load: its navigation starts within the call. A
  // load of the page shown with a fragment, the same one included, changes
  // the fragment alone, and still lands after another navigation that
  // started since; unless the engine makes it a document (wholeDocument).
  // Its promise resolves once that has landed or committed, or, with
  // another load of the page still pending (refuseLoad), rejects first,
  // sends no did-fail-load, and lands afterwards all the same.
  loadURL(url) {
    const inPage = !world.wholeDocument && !!this.webContents.url && url.includes("#") &&
      this.webContents.url.split("#")[0] === url.split("#")[0]
    this.webContents.emit("did-start-navigation", {url, isMainFrame: true, isSameDocument: inPage})
    this.webContents.url = url
    const land = () => {
      if (inPage) return this.webContents.emit("did-navigate-in-page", {}, url, true)
      this.webContents.emit("did-navigate", {}, url)
      this.webContents.emit("did-finish-load")
    }
    if (world.refuseLoad) {
      setImmediate(land)
      const refused = Promise.reject(new Error("ERR_FAILED"))
      refused.catch(() => {}) // as Electron silences one nobody reads
      return refused
    }
    return new Promise((resolve) => queueMicrotask(() => {
      land()
      resolve()
    }))
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
  commandLine: {getSwitchValue: () => "", hasSwitch: () => false, appendSwitch: (...a) => world.switches.push(a)},
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

const ANSWER = HOME + "/login#answer"

// The content window at the CYFR's sign-in page, hopped to the account
// window, which then sends the answer back (`answer`).
async function hopped() {
  await started(true)
  child.say({type: "home", home: HOME, account: ACCOUNT})
  child.say({type: "opened", home: HOME})
  await settled()
  const page = content()
  navigate(page, HOME + "/login")
  page.loadURL(HOME + "/login")
  await settled()
  const request = {...signIn["requests"]["another_sign_in"]["request"], return: HOME + "/login", expires_at: Date.now() + 60_000}
  const hop = `${ACCOUNT}/account/sign#${fragment(request)}`
  assert.ok(navigate(page, hop).prevented, "the hop leaves the content window at the sign-in page")
  const account = live().find((w) => w.webContents.url === hop)
  const answer = () => {
    const back = {url: ANSWER, isMainFrame: true, prevented: false, preventDefault() { this.prevented = true }}
    account.webContents.emit("will-navigate", back)
    assert.ok(back.prevented, "the account window does not load the return")
  }
  return {page, answer}
}

// The page's own change of its fragment to `url`, as the engine reports it.
function fragmentTo(page, url) {
  page.webContents.emit("did-start-navigation", {url, isMainFrame: true, isSameDocument: true})
  page.webContents.url = url
  page.webContents.emit("did-navigate-in-page", {}, url, true)
}

test("a sign-in's answer returns as a document of its own, though the content window still shows the CYFR's sign-in page", async () => {
  const {page, answer} = await hopped()
  answer()
  await settled()
  await settled()
  assert.equal(page.webContents.url, ANSWER)
  assert.deepEqual(page.webContents.reloaded, [ANSWER], "the page loaded again with the answer, as Prism reads it on loading")
  fragmentTo(page, ANSWER)
  await settled()
  assert.deepEqual(page.webContents.reloaded, [ANSWER], "one reload a return")
})

test("a sign-in's answer that committed as a whole document reloads nothing, then or at a later fragment of that same address", async () => {
  const {page, answer} = await hopped()
  world.wholeDocument = true // the engine's choice, whatever the two addresses
  answer()
  await settled()
  assert.equal(page.webContents.reloaded, undefined)
  fragmentTo(page, ANSWER)
  await settled()
  assert.equal(page.webContents.reloaded, undefined, "a later fragment change to that address is the page's own")
})

test("a superseded sign-in's answer reloads nothing, as it lands or at a later fragment of that same address", async () => {
  const {page, answer} = await hopped()
  answer()
  // Another navigation starts before the answer lands, which it still does.
  page.webContents.emit("did-start-navigation", {url: HOME + "/elsewhere", isMainFrame: true, isSameDocument: false})
  await settled()
  assert.equal(page.webContents.reloaded, undefined, "the answer landing after it was superseded")
  fragmentTo(page, ANSWER)
  await settled()
  assert.equal(page.webContents.reloaded, undefined, "a later fragment change to that address is the page's own")
})

test("a sign-in's answer whose load call rejects reloads nothing as it lands, or at a later fragment of that same address", async () => {
  const {page, answer} = await hopped()
  let landed = false
  page.webContents.on("did-navigate-in-page", () => { landed = true })
  world.refuseLoad = true
  answer()
  await settled()
  await settled()
  assert.ok(landed, "the fragment landed after the call rejected")
  assert.equal(page.webContents.reloaded, undefined, "the rejection withdrew the return")
  fragmentTo(page, ANSWER)
  await settled()
  assert.equal(page.webContents.reloaded, undefined, "a later fragment change to that address is the page's own")
})

test("a lock over a chooser that is keeping a notice leaves the notice there, until a way on is taken from it", async () => {
  await signedIn()
  const lockNow = async (signal) => {
    world.powerMonitor.emit(signal)
    await settled()
    child.say({type: "locked", home: HOME, account: ACCOUNT})
    await settled()
    await settled()
  }
  await lockNow("lock-screen") // the CYFR answers 503: unconfirmed
  assert.match(content().webContents.url, /notice=unconfirmed$/)
  await lockNow("suspend")
  assert.match(content().webContents.url, /notice=unconfirmed$/, "kept through the lock over it")
  const chooser = content()
  assert.ok(!navigate(chooser, "http://127.0.0.1:7340/").prevented)
  chooser.loadURL("http://127.0.0.1:7340/")
  await settled()
  await lockNow("lock-screen")
  assert.doesNotMatch(content().webContents.url, /notice=/, "told once the person went on")
})

test("with no route localhost is 127.0.0.1 alone, and that is no route a CYFR is restarted for", async () => {
  await started(false)
  assert.deepEqual(world.switches, [["host-resolver-rules", "MAP localhost 127.0.0.1"]])
  world.relaunched = null
  world.app.relaunch = (options) => { world.relaunched = options }
  child.say({type: "home", home: "http://localhost:4000", account: "https://cyfr.run"})
  await settled()
  await settled()
  assert.equal(world.relaunched, null)
  assert.ok(child.heard.some((m) => m.type === "home-ready" && m.home === "http://localhost:4000"))
})

test("started on a route main keeps that route's rules alone", async () => {
  const bare = world.app.commandLine.getSwitchValue
  world.app.commandLine.getSwitchValue = (name) => (name === "host-resolver-rules" ? "MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" : "")
  try {
    await started(false)
    assert.deepEqual(world.switches, [])
  } finally {
    world.app.commandLine.getSwitchValue = bare
  }
})
