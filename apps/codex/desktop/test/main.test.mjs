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
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {tmpdir} from "node:os"
import path from "node:path"
import {PassThrough} from "node:stream"
import {after, mock, test} from "node:test"

import {fragment} from "../../../cyfr/assets/account/sign_in.js"

const signIn = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/sign_in.json", import.meta.url)))
const HOME = signIn["home"]
const ACCOUNT = "https://accounts.example.com"
const READY = "http://127.0.0.1:7340/bootstrap/#token=dG9rZW4"

// ---- Electron, stood in for ----

const world = {disk: new Map(), profiles: mkdtempSync(path.join(tmpdir(), "cyfr-main-test-")), profileCount: 0}
after(() => rmSync(world.profiles, {recursive: true, force: true}))

// A launch: on a profile of its own, or on the one the last launch left
// (`relaunch`), which holds of the cookies what had been written out, as
// after a kill.
function reset({relaunch = false} = {}) {
  if (!relaunch) {
    world.disk = new Map()
    world.profile = path.join(world.profiles, String(++world.profileCount))
  }
  world.switches = []
  world.loads = []
  world.step = () => {}
  world.unclearable = false
  world.windows = []
  world.sessions = new Map()
  world.fetched = []
  world.scripted = []
  world.cleared = []
  world.clearing = () => Promise.resolve()
  world.flushed = []
  world.spawned = []
  world.relaunched = null
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
  async executeJavaScript(script) { world.scripted.push(script) }
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
    const ses = this.webContents.session
    if (/^https?:/.test(url) && !url.startsWith("http://127.0.0.1:7340/")) {
      world.loads.push({url, cookies: ses.jar.map((c) => c.value)})
    }
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
      jar: [...(world.disk.get(partition) ?? [])],
      cookies: Object.assign(new EventEmitter(), {
        async flushStore() {
          world.flushed.push(partition)
          world.disk.set(partition, [...ses.jar])
          world.step("flushed")
        },
        async get() {
          world.step("read")
          return [...ses.jar]
        }
      }),
      async clearCache() { world.step("cache cleared") },
      async fetch(url) {
        world.fetched.push(url)
        throw new Error("main asks the CYFR nothing")
      },
      async clearStorageData() {
        world.cleared.push(partition)
        await world.clearing()
        if (!world.unclearable) ses.jar = []
        world.step("cleared")
      }
    })
    world.sessions.set(partition, ses)
  }
  return world.sessions.get(partition)
}

world.app = Object.assign(new EventEmitter(), {
  commandLine: {getSwitchValue: () => "", hasSwitch: () => false, appendSwitch: (...a) => world.switches.push(a)},
  enableSandbox() {}, requestSingleInstanceLock: () => true, configureWebAuthn() {},
  relaunch(options) { world.relaunched = options },
  whenReady: () => Promise.resolve(),
  getPath(name) {
    assert.equal(name, "userData")
    return world.profile
  },
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
  child.attempts = 0
  // A proposal, numbered as cyfr numbers them: its number.
  child.proposes = (home, fields = {}) => {
    child.say({type: "home", home, account: ACCOUNT, attempt: ++child.attempts, ...fields})
    return child.attempts
  }
  return child
}

// Main makes no request of its own: one it made is recorded.
function request({url}) {
  world.fetched.push(url)
  throw new Error("main asks the CYFR nothing")
}

mock.module("electron", {exports: {
  BrowserWindow, app: world.app, dialog: {showMessageBox: async () => ({response: 0})},
  powerMonitor: world.powerMonitor, session: {fromPartition}, net: {request}
}})
let child = null
mock.module("node:child_process", {exports: {spawn: (_program, args) => {
  world.spawned.push(args)
  return (child = cyfr())
}}})
const {startApp} = await import("../src/app.js")

// A turn of the event loop: what main does on a line or an event is done.
const settled = () => new Promise((resolve) => setImmediate(resolve))

async function started(accountRoad, launch) {
  reset(launch)
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
function navigate(w, url, how = "will-navigate") {
  const event = {url, isMainFrame: true, initiator: w.webContents.mainFrame, prevented: false,
    preventDefault() { this.prevented = true }}
  w.webContents.emit(how, event)
  return event
}

// The CYFR sending `w`'s top frame on to `url`.
const redirected = (w, url) => navigate(w, url, "will-redirect")

// cyfr's answer to main's lock, or its own lock, all that follows done.
async function saysLocked(message = {home: HOME, account: ACCOUNT}) {
  child.say({type: "locked", ...message})
  await settled()
  await settled()
}

// Nothing of the person's sign-in was touched.
function signedNobodyOut() {
  assert.deepEqual(world.fetched, [], "no request of main's own")
  assert.deepEqual(world.scripted, [], "no script run in a page")
  assert.deepEqual(world.cleared, [], "nothing cleared")
}

// cyfr proposing `home`, and committing it once main answered home-ready:
// whether it did.
async function opens(home = HOME) {
  const attempt = child.proposes(home)
  await settled()
  await settled()
  if (!child.heard.some((m) => m.type === "home-ready" && m.home === home && m.attempt === attempt)) return false
  child.say({type: "opened", home})
  await settled()
  await settled()
  return true
}

// The CYFR at HOME opened, its page showing: main's own load on the
// passkey road, the device's pages' on the six-word road. What opening
// took is forgotten by the stand-in.
async function signedIn(accountRoad = true) {
  const said = await started(accountRoad)
  assert.ok(await opens())
  if (!accountRoad) await give(content())
  assert.equal(content().webContents.url, HOME + "/")
  world.cleared = []
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
  child.proposes(HOME)
  await settled()
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "home-ready", home: HOME, attempt: 1})
  child.say({type: "locked"})
  await settled()
  await settled()
  child.proposes(HOME)
  await settled()
  assert.deepEqual(child.heard.filter((m) => m.type === "home-ready").length, 2, "the same CYFR proposed again")
  assert.ok(!child.killed, said.join("\n"))
  child.say({type: "opened", home: HOME})
  child.proposes("https://bob.example")
  await settled()
  assert.ok(child.killed, "another proposal after a committed CYFR ends cyfr")
})

test("the road is main's word, in the chooser's address, and cyfr is started with no flag", async () => {
  await started(true)
  assert.deepEqual(world.spawned, [["desktop-serve"]])
  assert.equal(content().webContents.url, READY + "&road=passkey")
  await started(false)
  assert.deepEqual(world.spawned, [["desktop-serve"]])
  assert.equal(content().webContents.url, READY)
})

test("the computer's lock and sleep leave everything as it was", async () => {
  for (const road of [true, false]) {
    await signedIn(road)
    const page = content()
    for (const signal of ["lock-screen", "suspend", "shutdown"]) world.powerMonitor.emit(signal)
    await settled()
    assert.ok(!page.destroyed, "the page stays")
    assert.equal(page.webContents.url, HOME + "/")
    assert.ok(!child.heard.some((m) => m.type === "lock"), "cyfr is not told to lock")
    signedNobodyOut()
  }
})

test("a lock closes the content and the ceremony before anything is awaited, and the chooser waits for cyfr's locked", async () => {
  await signedIn()
  const request = {...signIn["requests"]["another_sign_in"]["request"], return: HOME + "/login", expires_at: Date.now() + 60_000}
  const hop = `${ACCOUNT}/account/sign#${fragment(request)}`
  const page = content()
  page.webContents.url = HOME + "/login"
  navigate(page, hop)
  const account = live().find((w) => w.webContents.url === hop)
  assert.ok(account, "the hop opened the account window")
  assert.ok(navigate(page, HOME + "/company-login").prevented)
  assert.ok(page.destroyed && account.destroyed, "both closed at once")
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "lock"}, "and cyfr told, before anything is awaited")
  await settled()
  assert.equal(content(), undefined, "no chooser before cyfr's locked")
  await saysLocked()
  assert.match(content().webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\/.*notice=company$/)
  signedNobodyOut()
})

test("signing out in Prism, and a kept sign-in that is over, show the chooser and forget nothing", async () => {
  for (const [name, showing, url] of [["signed out", HOME + "/threads", HOME + "/login?error=signed_out"],
    ["over, as the app opens it", "http://127.0.0.1:7340/bootstrap/", HOME + "/login"]]) {
    await signedIn()
    const page = content()
    page.webContents.url = showing
    assert.ok(redirected(page, url).prevented, name)
    assert.ok(page.destroyed, name)
    await settled()
    assert.deepEqual(child.heard.at(-1), {version: 1, type: "lock"}, name)
    await saysLocked()
    const chooser = content()
    assert.match(chooser.webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\//, name)
    assert.doesNotMatch(chooser.webContents.url, /notice=/, name)
    assert.ok(!navigate(chooser, HOME + "/login").prevented, "the chooser's passkey goes on to the sign-in page")
    signedNobodyOut()
  }
})

test("on the passkey road the content session is one kept on disk, through a lock and the next start", async () => {
  await signedIn()
  const kept = content().webContents.session
  assert.match(kept.partition, /^persist:/)
  redirected(content(), HOME + "/login?error=signed_out")
  await saysLocked()
  assert.equal(content().webContents.session.partition, kept.partition, "after a lock")
  await started(true, {relaunch: true})
  assert.ok(await opens())
  assert.equal(content().webContents.session.partition, kept.partition, "at the next start")
})

test("on the six-word road the content session is memory's alone and new at every lock", async () => {
  await signedIn(false)
  const first = content().webContents.session.partition
  assert.doesNotMatch(first, /^persist:/)
  await saysLocked()
  const next = content().webContents.session.partition
  assert.doesNotMatch(next, /^persist:/)
  assert.notEqual(next, first)
})

test("a changed cookie of the kept session is written out at once", async () => {
  await signedIn()
  const {session} = content().webContents
  world.flushed = []
  session.cookies.emit("changed")
  assert.deepEqual(world.flushed, [session.partition])
})

test("the device's session ending forgets the content's storage, and the chooser waits until it is forgotten", async () => {
  for (const road of [true, false]) {
    await signedIn(road)
    const page = content()
    let cleared
    world.clearing = () => new Promise((resolve) => { cleared = resolve })
    await saysLocked()
    assert.ok(page.destroyed, "closed at once")
    assert.deepEqual(world.cleared, [page.webContents.session.partition])
    assert.equal(content(), undefined, "no chooser while it is being forgotten")
    assert.ok(!child.heard.some((m) => m.type === "lock"), "nothing sent back")
    cleared()
    await settled()
    assert.match(content().webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\//)
  }
})

// Two CYFRs on two ports of one host share their cookies.
const PORT_A = "https://cyfr.example.com:8443"
const PORT_B = "https://cyfr.example.com:9443"
const CONTENT = "persist:cyfr-content"
const ownerOnDisk = () => {
  try {
    return readFileSync(path.join(world.profile, "content-owner"), "utf8")
  } catch {
    return ""
  }
}
const cookiesOnDisk = () => (world.disk.get(CONTENT) ?? []).map((c) => c.value)

// The CYFR at `home` opened and `who` signed in there, written out.
async function signsIn(home, who) {
  assert.ok(await opens(home))
  const ses = content().webContents.session
  ses.jar = [...ses.jar, {name: "_cyfr_key", value: who}]
  ses.cookies.emit("changed")
  await settled()
  assert.deepEqual(cookiesOnDisk(), [who])
}

test("two CYFRs on two ports of one host never see the same storage across launches", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  assert.equal(ownerOnDisk(), PORT_A, "the owner is the origin, its port with it")

  await started(true, {relaunch: true})
  assert.ok(await opens(PORT_A))
  assert.deepEqual(world.cleared, [], "its own CYFR again: nothing cleared")
  assert.deepEqual(world.loads, [{url: PORT_A + "/", cookies: ["ada at A"]}], "still signed in")

  await started(true, {relaunch: true})
  assert.ok(await opens(PORT_B))
  assert.deepEqual(world.cleared, [CONTENT], "another origin: cleared once")
  assert.deepEqual(world.loads, [{url: PORT_B + "/", cookies: []}], "nothing of A's")
  assert.equal(ownerOnDisk(), PORT_B)
  assert.deepEqual(cookiesOnDisk(), [])

  await started(true, {relaunch: true})
  assert.ok(await opens(PORT_A))
  assert.deepEqual(world.cleared, [CONTENT], "and back again: cleared again")
})

test("another scheme or host is another owner too", async () => {
  for (const [from, to] of [["https://localhost:4000", "http://localhost:4000"], [HOME, "https://bob.example"]]) {
    await started(true)
    await signsIn(from, "ada")
    await started(true, {relaunch: true})
    await opens(to)
    assert.deepEqual(world.cleared, [CONTENT], to)
    assert.deepEqual(cookiesOnDisk(), [], to)
  }
})

test("a storage with no owner recorded is cleared before any CYFR is kept to", async () => {
  await started(true)
  world.disk.set(CONTENT, [{name: "_cyfr_key", value: "nobody's"}])
  await started(true, {relaunch: true})
  assert.ok(await opens(PORT_A))
  assert.deepEqual(world.loads, [{url: PORT_A + "/", cookies: []}])
})

test("nothing of a CYFR loads, and cyfr hears no home-ready, while the storage is being cleared for it", async () => {
  await started(true)
  let cleared
  world.clearing = () => new Promise((resolve) => { cleared = resolve })
  child.proposes(PORT_B)
  await settled()
  assert.deepEqual(child.heard, [])
  for (const url of [PORT_B + "/", PORT_B + "/login", PORT_B + "/auth/device/complete/x"]) {
    assert.ok(navigate(content(), url).prevented, url)
  }
  assert.equal(ownerOnDisk(), "", "recorded only once cleared")
  cleared()
  await settled()
  assert.deepEqual(child.heard, [{version: 1, type: "home-ready", home: PORT_B, attempt: 1}])
  assert.equal(ownerOnDisk(), PORT_B)
})

test("a clear that fails opens nothing, keeps the old owner and says so", async () => {
  for (const [name, fail] of [
    ["clearStorageData rejects", () => { world.clearing = () => Promise.reject(new Error("no")) }],
    ["the cookies stay", () => { world.unclearable = true }],
    ["the cache stays", () => { world.step = (at) => { if (at === "cache cleared") throw new Error("no") } }],
    ["the store is not written out", () => { world.step = (at) => { if (at === "flushed") throw new Error("no") } }]]) {
    await started(true)
    await signsIn(PORT_A, "ada at A")
    await started(true, {relaunch: true})
    fail()
    const chooser = content()
    assert.equal(await opens(PORT_B), false, name)
    assert.deepEqual(world.loads, [], name)
    assert.ok(!child.killed, name)
    assert.deepEqual(child.heard, [{version: 1, type: "home-failed", home: PORT_B, attempt: 1}], `${name}: cyfr is told, and nothing locks`)
    assert.equal(ownerOnDisk(), PORT_A, name)
    assert.ok(!chooser.destroyed, `${name}: the chooser stands, for cyfr's answer to say so`)
    assert.ok(navigate(chooser, PORT_B + "/").prevented, name)
  }
})

test("a crash between the clear and the record leaves no session the new origin can reach", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  await started(true, {relaunch: true})
  // The whole of what is on disk at each step, as a kill would leave it.
  const snapshot = (at) => ({at, owner: ownerOnDisk(), disk: new Map(world.disk)})
  const crashes = [snapshot("before")]
  world.step = (at) => crashes.push(snapshot(at))
  assert.ok(await opens(PORT_B))
  crashes.push(snapshot("after"))
  assert.deepEqual(crashes.map((c) => c.at), ["before", "cleared", "cache cleared", "flushed", "read", "after"])
  const profile = world.profile
  for (const {at, owner, disk} of crashes) {
    assert.ok(owner === PORT_A || (owner === PORT_B && disk.get(CONTENT).length === 0), `at ${at}: ${owner}`)
    world.profile = profile
    world.disk = new Map(disk)
    writeFileSync(path.join(profile, "content-owner"), owner)
    await started(true, {relaunch: true})
    assert.ok(await opens(PORT_B), at)
    assert.deepEqual(world.loads, [{url: PORT_B + "/", cookies: []}], `started again after a crash at ${at}`)
  }
})

test("a root is loaded only while the record says that CYFR owns the storage", async () => {
  await started(true)
  child.proposes(PORT_B)
  await settled()
  writeFileSync(path.join(world.profile, "content-owner"), PORT_A)
  child.say({type: "opened", home: PORT_B})
  await settled()
  assert.deepEqual(world.loads, [])
  assert.ok(child.killed)
})

// Each clear the kept storage is asked for waits for the test: its ends,
// in order.
function heldClears() {
  const held = []
  world.clearing = () => new Promise((end, fail) => held.push({end, fail}))
  return held
}

test("an old clear acknowledges no selection but the current one: A, B, then A again", async () => {
  await started(true)
  const held = heldClears()
  const chooser = content()
  for (const home of [PORT_A, PORT_B, PORT_A]) {
    child.proposes(home)
    await settled()
    assert.deepEqual(child.heard, [], "nobody is answered while the clear runs")
    for (const url of [PORT_A + "/", PORT_B + "/"]) assert.ok(navigate(chooser, url).prevented, url)
  }
  assert.equal(held.length, 1, "one clear in flight")
  held[0].end()
  await settled()
  assert.equal(held.length, 1, "and no second for the newer proposal")
  assert.deepEqual(child.heard, [{version: 1, type: "home-ready", home: PORT_A, attempt: 3}])
  assert.equal(ownerOnDisk(), PORT_A)
  assert.ok(navigate(chooser, PORT_A + "/").prevented, "nothing of it before it is open")
  child.say({type: "opened", home: PORT_A})
  await settled()
  assert.deepEqual(world.loads, [{url: PORT_A + "/", cookies: []}])
  assert.equal(ownerOnDisk(), PORT_A, "the record names the CYFR that is open")
})

test("no proposal comes between the owner being recorded or read and its answer", async () => {
  for (const [owner, first] of [["", PORT_A], [PORT_A, PORT_A]]) {
    await started(true)
    if (owner) {
      await signsIn(owner, "ada at A")
      await started(true, {relaunch: true})
    }
    child.proposes(first)
    // The next proposal comes as soon as main has let go of the thread
    // after the owner is recorded, or read.
    if (owner) process.nextTick(() => child.proposes(PORT_B))
    else world.step = (at) => { if (at === "read" && child.attempts === 1) process.nextTick(() => child.proposes(PORT_B)) }
    await settled()
    await settled()
    await settled()
    for (const {type, home, attempt} of child.heard) {
      assert.equal(type, "home-ready")
      assert.equal(home, attempt === 1 ? first : PORT_B, "each number answered for its own CYFR")
    }
    assert.equal(child.heard.at(-1).attempt, 2)
    assert.equal(ownerOnDisk(), PORT_B, "the last answered is the owner")
    child.say({type: "opened", home: PORT_B})
    await settled()
    assert.deepEqual(world.loads, [{url: PORT_B + "/", cookies: []}])
  }
})

test("a clear that fails under overlapping proposals fails the current one alone, locking nothing", async () => {
  await started(true)
  const held = heldClears()
  child.proposes(PORT_A)
  await settled()
  child.proposes(PORT_B)
  await settled()
  held[0].fail(new Error("no"))
  await settled()
  assert.deepEqual(child.heard, [{version: 1, type: "home-failed", home: PORT_B, attempt: 2}])
  assert.ok(content(), "the chooser stands")
  assert.equal(ownerOnDisk(), "")
  world.clearing = () => Promise.resolve()
  assert.ok(await opens(PORT_A), "and the next is taken")
  assert.equal(ownerOnDisk(), PORT_A)
})

test("a kill between any two steps under overlapping proposals leaves no CYFR open under another's record", async () => {
  const C = "https://cyfr.example.com:10443"
  const steps = ["cleared", "cache cleared", "flushed", "read"]
  for (const at of ["before the clear", ...steps]) {
    for (const next of [[PORT_A], [PORT_B, PORT_A], [C], [C, PORT_B]]) {
      const what = `${next.join(", ")} proposed at ${at}`
      await started(true)
      await signsIn(PORT_A, "ada at A")
      await started(true, {relaunch: true})
      const held = heldClears()
      const overlap = () => next.forEach((home) => child.proposes(home))
      const snapshot = (step) => ({step, owner: ownerOnDisk(), disk: new Map(world.disk), loads: [...world.loads]})
      const kills = [snapshot("before")]
      world.step = (step) => {
        kills.push(snapshot(step))
        if (step === at) overlap()
      }
      child.proposes(PORT_B)
      await settled()
      if (at === "before the clear") overlap()
      await settled()
      assert.equal(held.length, 1, what)
      held[0].end()
      await settled()
      await settled()
      kills.push(snapshot("answered"))
      // Whom main answered is whom cyfr may open.
      assert.deepEqual(child.heard, [{version: 1, type: "home-ready", home: next.at(-1), attempt: child.attempts}], what)
      child.say({type: "opened", home: next.at(-1)})
      await settled()
      await settled()
      kills.push(snapshot("after"))
      assert.ok(!child.killed, what)
      assert.deepEqual(world.loads.map((l) => l.url), [next.at(-1) + "/"], what)
      const profile = world.profile
      for (const {step, owner, disk, loads} of kills) {
        for (const {url, cookies} of loads) {
          assert.equal(new URL(url).origin, owner, `${what}, killed at ${step}: open under another's record`)
          assert.deepEqual(cookies, [], `${what}, killed at ${step}`)
        }
        if (owner !== PORT_A) assert.deepEqual(disk.get(CONTENT), [], `${what}, killed at ${step}: A's storage under ${owner}`)
        for (const home of [PORT_A, PORT_B, C]) {
          world.profile = profile
          world.disk = new Map(disk)
          writeFileSync(path.join(profile, "content-owner"), owner)
          await started(true, {relaunch: true})
          assert.ok(await opens(home), what)
          const kept = home === owner && owner === PORT_A ? (disk.get(CONTENT) ?? []).map((c) => c.value) : []
          assert.deepEqual(world.loads, [{url: home + "/", cookies: kept}], `${what}, killed at ${step}, then ${home}`)
          assert.equal(ownerOnDisk(), home, "the record names the CYFR that is open")
        }
      }
    }
  }
})

// The chooser's ways on at `home`, whoever was signed in signed out.
async function atWays(home) {
  redirected(content(), home + "/login?error=signed_out")
  await saysLocked({home, account: ACCOUNT})
  return content()
}
const ANOTHER = "http://127.0.0.1:7340/bootstrap/another"

test("Connect to another CYFR clears what was kept and only then has cyfr leave", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  const chooser = await atWays(PORT_A)
  let cleared
  world.cleared = []
  world.clearing = () => new Promise((resolve) => { cleared = resolve })
  assert.ok(navigate(chooser, ANOTHER).prevented)
  assert.ok(chooser.destroyed, "closed at once")
  await settled()
  assert.ok(!child.heard.some((m) => m.type === "leave"), "not before the clear")
  cleared()
  await settled()
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "leave"})
  assert.deepEqual(cookiesOnDisk(), [], "gone on disk before cyfr is told")
  await saysLocked({})
  assert.deepEqual(world.cleared, [CONTENT])
  assert.ok(navigate(content(), PORT_A + "/").prevented, "main keeps to A no more")
})

test("a redirect keeps the chooser's top frame as its initiator and is no press of Connect to another CYFR", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  const chooser = await atWays(PORT_A)
  world.cleared = []
  assert.ok(redirected(chooser, ANOTHER).prevented)
  await settled()
  assert.ok(!chooser.destroyed, "the chooser stands")
  assert.deepEqual(world.cleared, [], "nothing is cleared")
  assert.ok(!child.heard.some((m) => m.type === "leave"))
})

test("the engine's pending address is not the document that began a navigation", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  const page = content()
  world.cleared = []
  const event = {url: ANOTHER, isMainFrame: true, initiator: page.webContents.mainFrame, prevented: false,
    preventDefault() { this.prevented = true }}
  page.webContents.getURL = () => "http://127.0.0.1:7340/bootstrap/"
  page.webContents.emit("will-navigate", event)
  await settled()
  assert.ok(event.prevented && !page.destroyed)
  assert.deepEqual(world.cleared, [], "the CYFR's document pressed nothing of the chooser's")
})

test("Connect to another CYFR does not advance past a failed clear", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  const chooser = await atWays(PORT_A)
  world.clearing = () => Promise.reject(new Error("no"))
  navigate(chooser, ANOTHER)
  await settled()
  assert.ok(!child.heard.some((m) => m.type === "leave"), "cyfr still holds A")
  assert.deepEqual(child.heard.at(-1), {version: 1, type: "lock"})
  await saysLocked({home: PORT_A, account: ACCOUNT})
  assert.match(content().webContents.url, /notice=uncleared$/)
  assert.equal(ownerOnDisk(), PORT_A)
  assert.deepEqual(cookiesOnDisk(), ["ada at A"])
})

test("a quit the system begins is never answered from inside the engine's before-quit", async () => {
  // SIGTERM, Cmd+Q and a logout reach Browser::Quit natively: the engine
  // runs the microtasks before that event returns, and a quit made there
  // re-enters the one under way.
  for (const before of [() => {}, () => child.emit("exit", null, "SIGKILL")]) {
    await signedIn()
    before()
    await settled()
    const event = {prevented: false, preventDefault() { this.prevented = true }}
    world.app.emit("before-quit", event)
    assert.ok(event.prevented)
    for (let turn = 0; turn < 20; turn++) await Promise.resolve()
    assert.equal(world.quit, false, "not in the event's own turn")
    await settled()
    assert.equal(world.quit, true, "in the next")
  }
})

const BOUND = 5000

test("the app's end never waits without end on a clear, a take or a flush, and keeps clear before record", async () => {
  const stuck = () => new Promise(() => {})
  for (const [name, hang, act] of [
    ["a take's clear", () => { world.clearing = stuck }, async () => { child.proposes(PORT_B) }],
    ["a take's flush", (ses) => { ses.cookies.flushStore = stuck }, async () => { child.proposes(PORT_B) }],
    ["a lock's clear", () => { world.clearing = stuck }, async () => {
      assert.ok(await opens(PORT_A))
      child.say({type: "locked", home: PORT_A, account: ACCOUNT})
    }]]) {
    for (const [how, end, ended] of [
      ["quit", () => world.app.emit("before-quit", {preventDefault() {}}), () => world.quit],
      ["relaunch", () => child.proposes(HOME, {proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"}),
        () => !!world.relaunched]]) {
      if (how === "relaunch" && name === "a lock's clear") continue // no proposal is taken while locking
      await started(true)
      await signsIn(PORT_A, "ada at A")
      await started(true, {relaunch: true})
      hang(content().webContents.session)
      await act()
      await settled()
      await settled()
      mock.timers.enable({apis: ["setTimeout"]})
      try {
        end()
        await settled()
        await settled()
        mock.timers.tick(BOUND - 1)
        await settled()
        await settled()
        assert.ok(!ended(), `${name}, ${how}: it waits for what is under way`)
        mock.timers.tick(1)
        await settled()
        await settled()
        assert.ok(ended(), `${name}, ${how}: and no longer`)
      } finally {
        mock.timers.reset()
      }
      assert.equal(ownerOnDisk(), PORT_A, `${name}, ${how}: nothing recorded for a clear that did not end`)
      assert.ok(world.loads.every((l) => new URL(l.url).origin === PORT_A), `${name}, ${how}: nothing of another loads`)
      await started(true, {relaunch: true})
      assert.ok(await opens(PORT_B))
      assert.deepEqual(world.loads, [{url: PORT_B + "/", cookies: []}], `${name}, ${how}: the next start clears first`)
    }
  }
})

test("a clear that ends after the app's end gave up opens nothing and records only what it cleared", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  await started(true, {relaunch: true})
  const held = heldClears()
  child.proposes(PORT_B)
  await settled()
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    world.app.emit("before-quit", {preventDefault() {}})
    await settled()
    mock.timers.tick(BOUND)
    await settled()
    await settled()
  } finally {
    mock.timers.reset()
  }
  assert.equal(world.quit, true)
  held[0].end()
  await settled()
  await settled()
  assert.deepEqual(world.loads, [])
  assert.ok(!child.heard.some((m) => m.type === "home-ready"), "nobody is answered")
  assert.ok(ownerOnDisk() === PORT_A || cookiesOnDisk().length === 0, "the new owner never over the old storage")
})

test("closing the window that says cyfr stopped takes the same way out, and waits as it does", async () => {
  await signedIn()
  let cleared
  world.clearing = () => new Promise((resolve) => { cleared = resolve })
  await saysLocked()
  child.emit("exit", null, "SIGKILL")
  await settled()
  live().find((w) => w.webContents.url.startsWith("data:")).destroy()
  await settled()
  await settled()
  assert.equal(world.quit, false, "not over what is being forgotten")
  cleared()
  await settled()
  await settled()
  assert.equal(world.quit, true)
})

test("quitting waits for what a lock is forgetting", async () => {
  await signedIn()
  let cleared
  world.clearing = () => new Promise((resolve) => { cleared = resolve })
  await saysLocked()
  world.app.quit()
  // Two turns: main never quits in the turn it is free to.
  await settled()
  await settled()
  assert.equal(world.quit, false)
  cleared()
  await settled()
  await settled()
  assert.equal(world.quit, true)
})

test("cyfr's loss closes the windows, says so and signs nobody out", async () => {
  await signedIn()
  const page = content()
  child.emit("exit", null, "SIGKILL")
  await settled()
  assert.ok(page.destroyed)
  const told = live().map((w) => decodeURIComponent(w.webContents.url)).find((u) => u.startsWith("data:"))
  assert.match(told, /CYFR stopped/)
  assert.doesNotMatch(told, /sign/, "nothing about a sign-out")
  signedNobodyOut()
})

test("closing the content window, and quitting, quit and sign nobody out", async () => {
  for (const end of [() => content().destroy(), () => world.app.quit()]) {
    await signedIn()
    end()
    await settled()
    await settled()
    assert.equal(world.quit, true)
    assert.deepEqual(child.heard.at(-1), {version: 1, type: "shutdown"})
    assert.ok(!child.heard.some((m) => m.type === "lock"))
    signedNobodyOut()
  }
})

test("a lost page is shown again in its own window, its session as it was", async () => {
  for (const road of [true, false]) {
    await signedIn(road)
    const page = content()
    page.webContents.emit("render-process-gone", {}, {reason: "killed"})
    assert.equal(page.webContents.reloaded, undefined, "not from inside the engine's report")
    await settled()
    assert.ok(!page.destroyed)
    assert.deepEqual(page.webContents.reloaded, [HOME + "/"])
    assert.ok(!child.heard.some((m) => m.type === "lock"))
    signedNobodyOut()
  }
})

test("a lost confirmation window closes alone", async () => {
  await signedIn()
  const page = content()
  page.webContents.opens({url: "http://127.0.0.1:7340/confirm?ref=cfm_1"})
  const opened = new BrowserWindow({webPreferences: {session: page.webContents.session}})
  page.webContents.emit("did-create-window", opened)
  opened.webContents.emit("render-process-gone", {}, {reason: "killed"})
  await settled()
  assert.ok(opened.destroyed)
  assert.ok(!page.destroyed)
  assert.equal(page.webContents.reloaded, undefined)
})

test("opened and cyfr's locked read in one go leave cyfr running and the chooser ready", async () => {
  await started(false)
  child.proposes(HOME)
  await settled()
  assert.ok(navigate(content(), HOME + "/company-login").prevented, "nothing of it before it is open")
  assert.ok(!child.heard.some((m) => m.type === "lock"), "and so no lock of it")
  child.say({type: "opened", home: HOME})
  await saysLocked()
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

test("a CYFR rerouted is a relaunch only after the content closed, and signs nobody out", async () => {
  await started(true)
  child.proposes(HOME)
  await settled()
  world.cleared = []
  const page = content()
  child.proposes("https://bob.example", {proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"})
  await settled()
  await settled()
  assert.ok(page.destroyed)
  signedNobodyOut()
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

const ANSWER = HOME + "/login#answer"

// The content window at the CYFR's sign-in page, hopped to the account
// window, which then sends the answer back (`answer`).
async function hopped() {
  await started(true)
  assert.ok(await opens())
  const page = content()
  page.webContents.url = "http://127.0.0.1:7340/bootstrap/#road=passkey"
  navigate(page, HOME + "/login")
  page.loadURL(HOME + "/login")
  await settled()
  const request = {...signIn["requests"]["another_sign_in"]["request"], return: HOME + "/login", expires_at: Date.now() + 60_000}
  const hop = `${ACCOUNT}/account/sign#${fragment(request)}`
  assert.ok(navigate(page, hop).prevented, "the hop leaves the content window at the sign-in page")
  const account = live().find((w) => w.webContents.url === hop)
  const answer = () => {
    const back = {url: ANSWER, isMainFrame: true, initiator: account.webContents.mainFrame, prevented: false,
      preventDefault() { this.prevented = true }}
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

test("a redirect in the account window is no answer of a sign-in's", async () => {
  const {page} = await hopped()
  const account = live().find((w) => w.webContents.url.startsWith(ACCOUNT + "/account/sign"))
  assert.ok(redirected(account, ANSWER).prevented)
  await settled()
  assert.ok(account.destroyed, "the ceremony ended")
  assert.equal(page.webContents.url, HOME + "/login", "and nothing was delivered")
})

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
  navigate(content(), HOME + "/company-login")
  await saysLocked()
  assert.match(content().webContents.url, /notice=company$/)
  await saysLocked() // the device's own
  assert.match(content().webContents.url, /notice=company$/, "kept through the lock over it")
  const chooser = content()
  assert.ok(!navigate(chooser, "http://127.0.0.1:7340/").prevented)
  chooser.loadURL("http://127.0.0.1:7340/")
  await settled()
  await saysLocked()
  assert.doesNotMatch(content().webContents.url, /notice=/, "told once the person went on")
})

test("with no route localhost is 127.0.0.1 alone, and that is no route a CYFR is restarted for", async () => {
  await started(false)
  assert.deepEqual(world.switches, [["host-resolver-rules", "MAP localhost 127.0.0.1"]])
  world.relaunched = null
  child.say({type: "home", home: "http://localhost:4000", account: "https://cyfr.run", attempt: 1})
  await settled()
  await settled()
  assert.equal(world.relaunched, null)
  assert.ok(child.heard.some((m) => m.type === "home-ready" && m.home === "http://localhost:4000" && m.attempt === 1))
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
