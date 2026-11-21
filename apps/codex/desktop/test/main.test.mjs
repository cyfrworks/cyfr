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
    queueMicrotask(() => this.webContents.emit("did-finish-load"))
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
      async fetch(url, init) {
        world.fetched.push({partition, url, body: init.body})
        return world.answer(url)
      },
      async clearStorageData() {}
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

mock.module("electron", {exports: {
  BrowserWindow, app: world.app, dialog: {showMessageBox: async () => ({response: 0})},
  powerMonitor: world.powerMonitor, session: {fromPartition}
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

// The CYFR at HOME opened on the passkey road, its page showing and its
// forgery token read.
async function signedIn() {
  const said = await started(true)
  child.say({type: "home", home: HOME, account: ACCOUNT})
  child.say({type: "opened", home: HOME})
  await settled()
  content().loadURL(HOME + "/")
  await settled()
  return said
}

test("an interrupted Connect, through main: a proposal a lock ended gives way to the next, a committed one to none", async () => {
  const said = await started(false)
  child.say({type: "home", home: HOME, account: ACCOUNT})
  await settled()
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "home-ready", home: HOME})
  child.say({type: "locked"})
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
  page.webContents.emit("will-navigate", {url: hop, isMainFrame: true, preventDefault() {}})
  const account = live().find((w) => w.webContents.url === hop)
  assert.ok(account, "the hop opened the account window")
  world.page = () => new Promise(() => {}) // a page that never answers again
  world.powerMonitor.emit("lock-screen")
  assert.ok(page.destroyed && account.destroyed, "both closed at once")
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "lock"})
  await settled()
  await settled()
  assert.deepEqual(world.fetched.map((f) => [f.url, f.body]), [[HOME + "/auth/logout", "_csrf_token=forgery-token"]])
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
