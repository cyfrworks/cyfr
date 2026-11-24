// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The main process (src/app.js) itself, with Electron and the cyfr it
// starts stood in for: each window, view, session and page main makes is
// a plain object that records what main did to it, and cyfr is a child
// whose lines the test writes and whose input it reads. What a person
// meets on real pages is part D's proof; this pins main's order and its
// decisions.

import assert from "node:assert/strict"
import {createHash} from "node:crypto"
import {EventEmitter} from "node:events"
import {mkdtempSync, readFileSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import path from "node:path"
import {PassThrough} from "node:stream"
import {after, mock, test} from "node:test"

import {fragment} from "../../../cyfr/assets/account/sign_in.js"
import {VERSION} from "../src/process.js"
import {DEPARTURE_MS} from "../src/states.js"

const signIn = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/sign_in.json", import.meta.url)))
const HOME = signIn["home"]
const ACCOUNT = "https://accounts.example.com"
const READY = "http://127.0.0.1:7340/bootstrap/#token=dG9rZW4"
const RAIL = "http://127.0.0.1:7340/rail/#read=cmFpbHRva2Vu"
const UPDATE = "http://127.0.0.1:7340/update/#read=cmFpbHRva2Vu"
// The rail's width, at the window's left.
const RAIL_WIDTH = 72

// The kept stores, by their names as main gives them: a CYFR's content and
// its account service's ceremonies, each by the hex SHA-256 of an origin.
const digest = (origin) => createHash("sha256").update(origin).digest("hex")
const contentStore = (home) => `persist:cyfr-home-v2-${digest(home)}`
const accountStore = (home, account) => `persist:cyfr-account-v2-${digest(home)}-${digest(account)}`
const RAIL_SESSION = `cyfr-app-${process.pid}`

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
  world.frames = []
  world.log = []
  world.holdPages = false
  world.heldPages = []
  world.connections = []
  world.closingConnections = () => Promise.resolve()
  world.popups = []
  world.boxes = []
  world.messageBox = async () => ({response: 0})
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
  world.dialogs = []
  world.opened = []
  world.app.removeAllListeners()
  world.powerMonitor.removeAllListeners()
  world.quit = false
  world.endedSelf = []
  world.trace = []
  world.menus = []
  world.spawnedIn = []
  world.lockAsked = []
  world.lockHeld = false
}

// A page: a window's or a view's (`owner`), in session `ses`.
class Contents extends EventEmitter {
  constructor(owner, ses) {
    super()
    this.owner = owner
    this.session = ses
    this.url = ""
    this.gone = false
    this.mainFrame = {processId: 1, routingId: owner.id, get url() { return owner.webContents.url }}
  }
  getURL() { return this.url }
  // As the engine has it: destroyed once its destroyed event is emitted.
  isDestroyed() { return this.gone }
  async executeJavaScript(script) { world.scripted.push(script) }
  // As Electron 45 makes a load: its navigation starts within the call. A
  // load of the page shown with a fragment, the same one included, changes
  // the fragment alone, and still lands after another navigation that
  // started since; unless the engine makes it a document (wholeDocument).
  // Its promise resolves once that has landed or committed, or, with
  // another load of the page still pending (refuseLoad), rejects first,
  // sends no did-fail-load, and lands afterwards all the same.
  loadURL(url) {
    const ses = this.session
    if (/^https?:/.test(url) && !url.startsWith("http://127.0.0.1:7340/")) {
      world.loads.push({url, cookies: ses.jar.map((c) => c.value)})
    }
    const inPage = !world.wholeDocument && !!this.url && url.includes("#") && this.url.split("#")[0] === url.split("#")[0]
    this.emit("did-start-navigation", {url, isMainFrame: true, isSameDocument: inPage})
    this.url = url
    const land = () => {
      if (inPage) return this.emit("did-navigate-in-page", {}, url, true)
      this.emit("did-navigate", {}, url)
      this.emit("did-finish-load")
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
  reload() {
    this.reloaded = [...(this.reloaded ?? []), this.url]
    this.emit("did-start-navigation", {url: this.url, isMainFrame: true, isSameDocument: false})
    queueMicrotask(() => {
      this.emit("did-navigate", {}, this.url)
      this.emit("did-finish-load")
    })
  }
  setWindowOpenHandler(h) { this.opens = h }
  // A view's page closed: gone from its window at once, destroyed once
  // the engine says so (end).
  close() {
    if (this.owner.destroyed) return
    this.owner.destroyed = true
    world.log.push(`closed ${this.owner.id}`)
    this.end()
  }
  // Its destroyed event: at once, or once the test lets it go (holdPages).
  end() {
    if (this.ended) return
    this.ended = true
    const gone = () => {
      this.gone = true
      this.emit("destroyed")
    }
    if (world.holdPages) world.heldPages.push(gone)
    else gone()
  }
}

// The pages held (holdPages) let go, each emitting destroyed.
const letPagesGo = () => world.heldPages.splice(0).forEach((gone) => gone())

class BrowserWindow extends EventEmitter {
  constructor(options) {
    super()
    this.id = world.windows.length + 1
    this.webContents = new Contents(this, options.webPreferences.session)
    this.options = options
    this.maximized = false
    this.destroyed = false
    world.windows.push(this)
  }
  loadURL(url) { return this.webContents.loadURL(url) }
  destroy() {
    if (this.destroyed) return
    this.destroyed = true
    world.log.push(`closed ${this.id}`)
    this.webContents.end()
    this.emit("closed")
  }
  isDestroyed() { return this.destroyed }
  isMinimized() { return false }
  show() {}
  maximize() { this.maximized = true }
  restore() {}
  focus() {}
}

// A view, in world.windows beside the windows: the rail's or the
// content's. It has no load of its own: its page has.
class WebContentsView {
  constructor(options) {
    this.id = world.windows.length + 1
    this.webContents = new Contents(this, options.webPreferences.session)
    this.options = options
    this.destroyed = false
    this.bounds = []
    world.windows.push(this)
  }
  setBounds(bounds) { this.bounds.push(bounds) }
}

// The app's one window, where the screen has it.
const AT = {x: 100, y: 50}
class BaseWindow extends EventEmitter {
  constructor(options) {
    super()
    this.options = options
    this.at = {...AT, width: options.width, height: options.height}
    this.maximized = false
    this.shown = false
    this.destroyed = false
    this.minimized = false
    this.focused = 0
    const views = []
    this.contentView = {
      children: views,
      addChildView(v) { views.push(v) },
      removeChildView(v) {
        const i = views.indexOf(v)
        if (i >= 0) views.splice(i, 1)
      }
    }
    world.frames.push(this)
  }
  getContentBounds() { return {...this.at} }
  // The person resizing it.
  resize(width, height) {
    this.at = {...this.at, width, height}
    this.emit("resize")
  }
  // The person closing it.
  close() {
    if (this.destroyed) return
    this.emit("close", {preventDefault() {}})
    this.destroy()
  }
  destroy() {
    if (this.destroyed) return
    this.destroyed = true
    this.emit("closed")
  }
  isDestroyed() { return this.destroyed }
  isMinimized() { return this.minimized }
  show() { this.shown = true }
  maximize() { this.maximized = true }
  restore() { this.minimized = false }
  focus() { this.focused++ }
}

function fromPartition(partition) {
  if (!world.sessions.has(partition)) {
    const ses = new EventEmitter()
    Object.assign(ses, {
      partition,
      webRequest: {onHeadersReceived(handler) { ses.received = handler }},
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
      // Its connections closed, once the test lets them (closingConnections).
      closeAllConnections() {
        world.connections.push(partition)
        return world.closingConnections(partition)
      },
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
  commandLine: {getSwitchValue: (name) => ({"screen-project": world.screen, "setup-project": world.setup})[name] ?? "",
    hasSwitch: (name) => ({"screen-project": world.screen, "setup-project": world.setup, quit: world.quitSwitch})[name] !== undefined,
    appendSwitch: (...a) => world.switches.push(a)},
  enableSandbox() {}, configureWebAuthn() {},
  // Taken unless another app of this account holds it (world.lockHeld).
  requestSingleInstanceLock(data) {
    world.lockAsked.push(data)
    return !world.lockHeld
  },
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
    stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(), exitCode: null, signalCode: null, killed: false,
    kill(signal = "SIGTERM") { child.killed = signal }
  })
  child.heard = []
  // What main writes it, in the order of everything main does (log), and
  // what main tells cyfr and its input's end, in the order main does them,
  // beside what it says (world.trace): heard reads them a turn later.
  const write = child.stdin.write.bind(child.stdin)
  const end = child.stdin.end.bind(child.stdin)
  child.stdin.write = (chunk, ...rest) => {
    for (const line of String(chunk).split("\n").filter(Boolean)) {
      world.log.push(`to cyfr: ${JSON.parse(line).type}`)
      world.trace.push(`told ${JSON.parse(line).type}`)
    }
    return write(chunk, ...rest)
  }
  child.stdin.end = (...rest) => {
    world.trace.push("input ended")
    return end(...rest)
  }
  child.stdin.setEncoding("utf8")
  child.stdin.on("data", (chunk) => {
    for (const line of chunk.split("\n").filter(Boolean)) child.heard.push(JSON.parse(line))
  })
  child.say = (m) => child.stdout.write(JSON.stringify({version: VERSION, ...m}) + "\n")
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
  BaseWindow, BrowserWindow, WebContentsView, app: world.app,
  dialog: {
    // A message box, answered as the test has it answer (messageBox).
    showMessageBox: (parent, options) => {
      world.boxes.push({parent, options})
      return world.messageBox(parent, options)
    },
    // The system's folder dialog, open until the test answers it.
    showOpenDialog: (parent, options) => new Promise((answer) => world.dialogs.push({parent, options, answer}))},
  Menu: {setApplicationMenu: (menu) => world.menus.push(menu),
    // A menu main pops up: its items, for the test to press one, and where.
    buildFromTemplate: (items) => {
      const menu = {items, popped: [], popup(options) { menu.popped.push(options) }}
      world.popups.push(menu)
      return menu
    }},
  powerMonitor: world.powerMonitor, session: {fromPartition}, net: {request},
  shell: {openExternal: async (url) => { world.opened.push(url) }}
}})
let child = null
mock.module("node:child_process", {exports: {spawn: (_program, args, options) => {
  world.spawned.push(args)
  world.spawnedIn.push(options.cwd ?? null)
  return (child = cyfr())
}}})
const {RESTART_WAIT_MS, startApp} = await import("../src/app.js")

// A turn of the event loop: what main does on a line or an event is done.
const settled = () => new Promise((resolve) => setImmediate(resolve))

async function started(accountRoad, launch) {
  reset(launch)
  const said = []
  startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad, say: (line) => said.push(line)})
  await settled()
  child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
  await settled()
  return said
}

// The rail's view, which is no window of the content's.
const isRail = (w) => w.webContents.session.partition === RAIL_SESSION
const rail = () => world.windows.find((w) => isRail(w) && !w.destroyed)
const live = () => world.windows.filter((w) => !w.destroyed && !isRail(w))
const content = () => live().find((w) => w.webContents.url.startsWith("http"))
const frame = () => world.frames.at(-1)

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
  child.say({type: "opened", home, attempt: child.attempts})
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
  w.webContents.loadURL(HOME + "/")
  await settled()
}

// A press on the rail: a navigation of its top frame to `url`, asked for
// by the rail's own page.
const press = (url) => navigate(rail(), url)
const select = (home) => press(`http://127.0.0.1:7340/rail/select?cyfr=${encodeURIComponent(home)}`)
// The leaves cyfr has heard.
const leaves = () => child.heard.filter((m) => m.type === "leave")

// Turns enough for a departure's teardown and its answer to be done.
async function turns(n = 4) {
  for (let i = 0; i < n; i++) await settled()
}

// The CYFR open left by selecting `home` on the rail, and cyfr's left
// said: the chooser connecting to it shows.
async function departsFor(home) {
  assert.ok(select(home).prevented, "a press on the rail loads nothing")
  await settled()
  child.say({type: "left", id: leaves().at(-1).id})
  await turns()
  assert.equal(content().webContents.url, READY + "&road=passkey&connect=" + encodeURIComponent(home))
}

test("an interrupted Connect, through main: a proposal a lock ended gives way to the next, a committed one to none", async () => {
  const said = await started(false)
  child.proposes(HOME)
  await settled()
  assert.deepEqual(child.heard.at(-1), {version: VERSION, type: "home-ready", home: HOME, attempt: 1})
  child.say({type: "locked"})
  await settled()
  await settled()
  child.proposes(HOME)
  await settled()
  assert.deepEqual(child.heard.filter((m) => m.type === "home-ready").length, 2, "the same CYFR proposed again")
  assert.ok(!child.killed, said.join("\n"))
  child.say({type: "opened", home: HOME, attempt: child.attempts})
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
  assert.deepEqual(child.heard.at(-1), {version: VERSION, type: "lock"}, "and cyfr told, before anything is awaited")
  await settled()
  assert.equal(content(), undefined, "no chooser before cyfr's locked")
  await saysLocked()
  assert.match(content().webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\/.*notice=company$/)
  signedNobodyOut()
})

test("signing out in Prism, and a kept sign-in that is over, show the chooser and forget nothing", async () => {
  for (const [name, showing, url] of [["signed out", HOME + "/threads", HOME + "/login?error=signed_out"],
    ["over, as the app opens it in a view of its own", "", HOME + "/login"]]) {
    await signedIn()
    const page = content()
    page.webContents.url = showing
    assert.ok(redirected(page, url).prevented, name)
    assert.ok(page.destroyed, name)
    await settled()
    assert.deepEqual(child.heard.at(-1), {version: VERSION, type: "lock"}, name)
    await saysLocked()
    const chooser = content()
    assert.match(chooser.webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\//, name)
    assert.doesNotMatch(chooser.webContents.url, /notice=/, name)
    assert.ok(navigate(chooser, HOME + "/login").prevented, "no CYFR's page in the chooser's view: its sign-in is main's to open")
    signedNobodyOut()
  }
})

test("on the passkey road a CYFR's pages are in its own store kept on disk, through a lock and the next start; the chooser in memory", async () => {
  await signedIn()
  const kept = content().webContents.session
  assert.equal(kept.partition, contentStore(HOME))
  redirected(content(), HOME + "/login?error=signed_out")
  await saysLocked({})
  assert.doesNotMatch(content().webContents.session.partition, /^persist:/, "the chooser after the lock is memory's")
  assert.ok(await opens())
  assert.equal(content().webContents.session.partition, kept.partition, "the CYFR again after a lock")
  await started(true, {relaunch: true})
  assert.doesNotMatch(content().webContents.session.partition, /^persist:/, "the chooser at the next start")
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

// Two CYFRs on one host, on two ports.
const PORT_A = "https://cyfr.example.com"
const PORT_B = "https://cyfr.example.com:8443"
const cookiesOnDisk = (home) => (world.disk.get(contentStore(home)) ?? []).map((c) => c.value)
// Every store kept on disk main has made.
const stores = () => [...world.sessions.keys()].filter((p) => p.startsWith("persist:"))

// The CYFR at `home` opened and `who` signed in there, written out.
async function signsIn(home, who) {
  assert.ok(await opens(home))
  const ses = content().webContents.session
  ses.jar = [...ses.jar, {name: "_cyfr_key", value: who}]
  ses.cookies.emit("changed")
  await settled()
  assert.deepEqual(cookiesOnDisk(home), [who])
}

test("two CYFRs on two ports of one host each open in a store of their own: A, B and A again, nothing cleared", async () => {
  await started(true)
  await signsIn(PORT_A, "ada at A")
  assert.equal(content().webContents.session.partition, contentStore(PORT_A))
  await departsFor(PORT_B)
  await signsIn(PORT_B, "bea at B")
  assert.equal(content().webContents.session.partition, contentStore(PORT_B))
  assert.notEqual(contentStore(PORT_A), contentStore(PORT_B), "the port is part of the store's name")
  await departsFor(PORT_A)
  assert.ok(await opens(PORT_A))
  assert.equal(content().webContents.session.partition, contentStore(PORT_A))
  assert.deepEqual(world.loads, [{url: PORT_A + "/", cookies: []}, {url: PORT_B + "/", cookies: []},
    {url: PORT_A + "/", cookies: ["ada at A"]}], "A again still signed in, and B never saw A's")
  assert.deepEqual(world.cleared, [], "nothing cleared on a switch")
  assert.deepEqual(cookiesOnDisk(PORT_A), ["ada at A"])
  assert.deepEqual(cookiesOnDisk(PORT_B), ["bea at B"])

  await started(true, {relaunch: true})
  assert.ok(await opens(PORT_B))
  assert.deepEqual(world.loads, [{url: PORT_B + "/", cookies: ["bea at B"]}], "and at the next start")
  assert.deepEqual(world.cleared, [])
})

test("Sign in with your passkey, on the chooser of a CYFR that asked for a sign-in, signs in in that CYFR's own store, kept at the next start", async () => {
  await signedIn()
  assert.ok(redirected(content(), HOME + "/login?error=signed_out").prevented)
  await settled()
  await saysLocked()
  const chooser = content()
  assert.doesNotMatch(chooser.webContents.session.partition, /^persist:/, "the chooser is memory's")
  assert.ok(navigate(chooser, "http://127.0.0.1:7340/bootstrap/signin").prevented, "main's to open, never loaded")
  await settled()
  assert.ok(chooser.destroyed)
  const page = content()
  assert.equal(page.webContents.url, HOME + "/login")
  assert.equal(page.webContents.session.partition, contentStore(HOME))
  // The CYFR's sign-in page signs the person in: its cookie.
  page.webContents.session.jar = [...page.webContents.session.jar, {name: "_cyfr_key", value: "ada"}]
  page.webContents.session.cookies.emit("changed")
  await settled()
  assert.deepEqual(cookiesOnDisk(HOME), ["ada"], "in the CYFR's own store, written out")
  await started(true, {relaunch: true})
  assert.ok(await opens())
  assert.deepEqual(world.loads.at(-1), {url: HOME + "/", cookies: ["ada"]}, "signed in at the next start")
})

test("another scheme or host is another store too", async () => {
  for (const [from, to] of [["https://localhost:4000", "http://localhost:4000"], [HOME, "https://bob.example"]]) {
    await started(true)
    await signsIn(from, "ada")
    await started(true, {relaunch: true})
    assert.ok(await opens(to), to)
    assert.notEqual(contentStore(from), contentStore(to), to)
    assert.equal(content().webContents.session.partition, contentStore(to), to)
    assert.deepEqual(world.loads, [{url: to + "/", cookies: []}], to)
    assert.deepEqual(world.cleared, [], to)
    assert.deepEqual(cookiesOnDisk(from), ["ada"], `${to}: the other's kept as it was`)
  }
})

test("a proposal is answered home-ready at once, and nothing of that CYFR loads or is kept until cyfr commits it", async () => {
  await started(true)
  const chooser = content()
  child.proposes(PORT_B)
  await settled()
  assert.deepEqual(child.heard, [{version: VERSION, type: "home-ready", home: PORT_B, attempt: 1}])
  for (const url of [PORT_B + "/", PORT_B + "/login", PORT_B + "/auth/device/complete/x"]) {
    assert.ok(navigate(chooser, url).prevented, url)
  }
  assert.deepEqual(stores(), [], "no store made for a proposal")
  child.say({type: "opened", home: PORT_B, attempt: 1})
  await settled()
  await settled()
  assert.deepEqual(world.loads, [{url: PORT_B + "/", cookies: []}])
  assert.deepEqual(stores(), [contentStore(PORT_B)])
  assert.ok(chooser.destroyed, "the chooser's view gave way to the CYFR's own")
  assert.deepEqual(world.cleared, [])
})

test("overlapping proposals are each answered at once for their own CYFR, and the one committed opens alone", async () => {
  await started(true)
  for (const home of [PORT_A, PORT_B, PORT_A]) child.proposes(home)
  await settled()
  await settled()
  assert.deepEqual(child.heard, [PORT_A, PORT_B, PORT_A].map((home, i) =>
    ({version: VERSION, type: "home-ready", home, attempt: i + 1})))
  child.say({type: "opened", home: PORT_A, attempt: 3})
  await settled()
  await settled()
  assert.ok(!child.killed)
  assert.deepEqual(world.loads, [{url: PORT_A + "/", cookies: []}])
  assert.deepEqual(stores(), [contentStore(PORT_A)])
})

// ---- the rail ----

test("the rail shows ready's rail address in a memory session of its own, at the window's left, the content beside it as it is resized", async () => {
  await started(true)
  const r = rail()
  assert.equal(r.webContents.url, RAIL)
  assert.equal(r.webContents.session.partition, RAIL_SESSION)
  assert.equal(typeof r.webContents.session.received, "function", "its session has the rules every page's has")
  assert.equal(world.frames.length, 1, "one window")
  const f = frame()
  const chooser = content()
  assert.deepEqual(f.contentView.children, [r, chooser])
  assert.deepEqual(r.bounds.at(-1), {x: 0, y: 0, width: RAIL_WIDTH, height: 860})
  assert.deepEqual(chooser.bounds.at(-1), {x: RAIL_WIDTH, y: 0, width: 1280 - RAIL_WIDTH, height: 860})
  f.resize(1000, 700)
  assert.deepEqual(r.bounds.at(-1), {x: 0, y: 0, width: RAIL_WIDTH, height: 700})
  assert.deepEqual(chooser.bounds.at(-1), {x: RAIL_WIDTH, y: 0, width: 1000 - RAIL_WIDTH, height: 700})
  assert.ok(await opens())
  const page = content()
  assert.deepEqual(page.bounds.at(-1), {x: RAIL_WIDTH, y: 0, width: 1000 - RAIL_WIDTH, height: 700}, "a new view takes the same place")
  assert.deepEqual(f.contentView.children, [r, page], "the chooser's view taken out")
  assert.ok(chooser.webContents.isDestroyed(), "and its page closed")
})

test("a ready with no rail or no Update CYFR, or with another address for either, ends cyfr", async () => {
  for (const extra of [{}, {rail: "http://127.0.0.1:7340/bootstrap/#read=cmFpbHRva2Vu", update: UPDATE}, {rail: RAIL},
    {rail: RAIL, update: "http://127.0.0.1:7340/rail/#read=cmFpbHRva2Vu"}]) {
    reset()
    startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad: true, say: () => {}})
    await settled()
    child.say({type: "ready", url: READY, ...extra})
    await settled()
    assert.ok(child.killed, JSON.stringify(extra))
    assert.equal(rail(), undefined, JSON.stringify(extra))
    assert.equal(content(), undefined, JSON.stringify(extra))
    assert.ok(live().some((w) => decodeURIComponent(w.webContents.url).includes("CYFR stopped")), JSON.stringify(extra))
  }
})

// Update CYFR's window: the app's own store's window at its page.
const updateWindow = () => world.windows.find((w) => isRail(w) && !w.destroyed && w.webContents.url.startsWith("http://127.0.0.1:7340/update/"))
const sent = (type) => child.heard.filter((m) => m.type === type)

test("Update CYFR opens from the rail's foot in a window of the app's own store over the CYFR open, which stays; a second press brings it forward", async () => {
  await signedIn()
  const page = content()
  const e = press("http://127.0.0.1:7340/rail/update")
  await settled()
  assert.ok(e.prevented, "the rail's press loads nothing")
  const u = updateWindow()
  assert.ok(u, "Update CYFR's window opened")
  assert.equal(u.webContents.url, UPDATE)
  assert.equal(u.webContents.session.partition, RAIL_SESSION, "in the app's own store, never a CYFR's")
  assert.equal(u.options.parent, frame(), "over the app's window")
  assert.equal(content(), page, "the CYFR open stays as it is")
  assert.ok(!page.destroyed)
  assert.deepEqual(leaves(), [], "nothing is left")
  const count = world.windows.length
  press("http://127.0.0.1:7340/rail/update")
  await settled()
  assert.equal(world.windows.length, count, "a second press opens no second window")
  assert.equal(updateWindow(), u)
})

test("Update CYFR's yes is sent as update with the offer its page names, from its own page alone; its Close and its close are told to cyfr", async () => {
  await signedIn()
  press("http://127.0.0.1:7340/rail/update")
  await settled()
  const u = updateWindow()
  for (const no of [HOME + "/", "http://127.0.0.1:7340/update/start", "http://127.0.0.1:7340/update/start?offer=3&target=9.9.9",
    "http://127.0.0.1:7340/", "http://127.0.0.1:7340/bootstrap/#token=x"]) {
    assert.ok(navigate(u, no).prevented, no)
  }
  assert.ok(redirected(u, "http://127.0.0.1:7340/update/start?offer=3").prevented)
  await settled()
  assert.deepEqual(sent("update"), [], "no load and no redirect of its says yes")
  assert.ok(navigate(content(), "http://127.0.0.1:7340/update/start?offer=3").prevented, "the CYFR's page")
  assert.ok(navigate(rail(), "http://127.0.0.1:7340/update/start?offer=3").prevented, "the rail")
  await settled()
  assert.deepEqual(sent("update"), [], "no other page says yes")
  assert.ok(navigate(u, "http://127.0.0.1:7340/update/start?offer=3").prevented, "the yes loads nothing")
  await settled()
  assert.deepEqual(sent("update"), [{version: VERSION, type: "update", offer: 3}])
  assert.ok(navigate(u, "http://127.0.0.1:7340/update/close").prevented)
  await settled()
  assert.ok(u.destroyed, "Close closes it")
  assert.deepEqual(sent("update-closed"), [{version: VERSION, type: "update-closed"}])
  press("http://127.0.0.1:7340/rail/update")
  await settled()
  updateWindow().destroy()
  await settled()
  assert.equal(sent("update-closed").length, 2, "the window's own close is told too")
})

test("a record waiting to be shown opens Update CYFR as cyfr is ready, over the chooser", async () => {
  reset()
  startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad: true, say: () => {}})
  await settled()
  child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE, record: true})
  await settled()
  assert.ok(updateWindow(), "Update CYFR opened by itself")
  assert.ok(content().webContents.url.startsWith(READY), "beside the chooser")
  reset()
  startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad: true, say: () => {}})
  await settled()
  child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
  await settled()
  assert.equal(updateWindow(), undefined, "no record, no window")
})

test("a navigation of the rail that is no press, a redirect or a frame's among them, is refused and does nothing", async () => {
  await signedIn()
  const page = content()
  const r = rail()
  const views = world.windows.length
  for (const url of ["https://evil.example/", HOME + "/", "http://127.0.0.1:7340/rail/", "http://127.0.0.1:7340/bootstrap/",
    "http://127.0.0.1:7340/rail/select?cyfr=nonsense", "http://127.0.0.1:7340/rail/connect?x=1"]) {
    assert.ok(press(url).prevented, url)
  }
  const to = "http://127.0.0.1:7340/rail/select?cyfr=" + encodeURIComponent(PORT_B)
  assert.ok(redirected(r, to).prevented, "a redirect keeps the rail's top frame as its initiator and is no press")
  const asked = (over) => {
    const event = {url: to, isMainFrame: true, initiator: r.webContents.mainFrame, prevented: false,
      preventDefault() { this.prevented = true }, ...over}
    r.webContents.emit(event.isMainFrame ? "will-navigate" : "will-frame-navigate", event)
    return event
  }
  assert.ok(asked({initiator: {processId: 9, routingId: 9}}).prevented, "asked by another frame")
  assert.ok(asked({isMainFrame: false}).prevented, "a frame of the rail's")
  await turns()
  assert.ok(!page.destroyed, "the CYFR stays open")
  assert.equal(world.windows.length, views, "nothing opened")
  assert.deepEqual(leaves(), [])
  assert.deepEqual(world.popups, [])
  assert.equal(r.webContents.url, RAIL)
  assert.deepEqual(world.loads, [{url: HOME + "/", cookies: []}], "nothing loaded but the CYFR's own root")
})

test("a press on the rail at the chooser shows the chooser at once: connecting to the CYFR selected, at Connect, at Set up", async () => {
  await started(true)
  const at = (url, then) => {
    const before = content()
    assert.ok(press(url).prevented, url)
    assert.ok(before.destroyed, `${url}: its view replaced`)
    assert.equal(content().webContents.url, READY + "&road=passkey" + then, url)
    assert.doesNotMatch(content().webContents.session.partition, /^persist:/, url)
  }
  at("http://127.0.0.1:7340/rail/select?cyfr=" + encodeURIComponent(PORT_B), "&connect=" + encodeURIComponent(PORT_B))
  at("http://127.0.0.1:7340/rail/connect", "")
  at("http://127.0.0.1:7340/rail/setup", "&way=setup")
  await settled()
  assert.deepEqual(leaves(), [], "nothing open, nothing left")
  assert.deepEqual(world.cleared, [])
})

test("selecting the CYFR open on the rail brings the window forward and leaves nothing", async () => {
  await signedIn()
  const page = content()
  const focused = frame().focused
  assert.ok(select(HOME).prevented)
  await turns()
  assert.ok(!page.destroyed)
  assert.equal(frame().focused, focused + 1)
  assert.deepEqual(leaves(), [])
})

// ---- a departure: the CYFR open left for another ----

test("a departure closes every page of the CYFR at once, then has cyfr leave, and shows the next chooser only once cyfr left and those pages and their connections ended", async () => {
  for (const last of ["left", "parted"]) {
    const {page} = await hopped()
    const opened = confirmationOpened(page)
    const account = live().find((w) => w.webContents.url.startsWith(ACCOUNT + "/account/sign"))
    world.holdPages = true
    const connections = []
    world.closingConnections = () => new Promise((end) => connections.push(end))
    world.log = []
    assert.ok(select(PORT_B).prevented, last)
    assert.ok(page.destroyed && opened.destroyed && account.destroyed, `${last}: closed at once`)
    assert.deepEqual(world.log, [`closed ${account.id}`, `closed ${opened.id}`, `closed ${page.id}`, "to cyfr: leave"],
      `${last}: leave only after its pages closed`)
    await settled()
    assert.deepEqual(leaves(), [{version: VERSION, type: "leave", id: 1}], last)
    assert.equal(content(), undefined, `${last}: no chooser at once`)
    if (last === "parted") {
      child.say({type: "left", id: 1})
      await turns()
      assert.equal(content(), undefined, "no chooser before the pages are gone")
    }
    assert.deepEqual(world.connections, [], `${last}: no connection closed before the pages are gone`)
    letPagesGo()
    await turns()
    for (const store of [contentStore(HOME), accountStore(HOME, ACCOUNT)]) {
      assert.ok(world.connections.includes(store), `${last}: ${store}'s connections closed`)
    }
    assert.equal(content(), undefined, `${last}: no chooser before the connections are closed`)
    connections.forEach((end) => end())
    await turns()
    if (last === "left") {
      assert.equal(content(), undefined, "no chooser before cyfr left")
      child.say({type: "left", id: 1})
      await turns()
    }
    assert.equal(content().webContents.url, READY + "&road=passkey&connect=" + encodeURIComponent(PORT_B), last)
    assert.doesNotMatch(content().webContents.session.partition, /^persist:/, last)
    assert.deepEqual(world.cleared, [], `${last}: nothing of the CYFR left is forgotten`)
    assert.ok(!child.killed, last)
  }
})

test("a left of another id, a locked, and a second left change nothing of a departure", async () => {
  await signedIn()
  assert.ok(select(PORT_B).prevented)
  await turns()
  child.say({type: "left", id: 2})
  await turns()
  assert.equal(content(), undefined, "another id's left")
  await saysLocked({})
  assert.equal(content(), undefined, "the leave's own locked")
  child.say({type: "left", id: 1})
  await turns()
  const chooser = content()
  assert.equal(chooser.webContents.url, READY + "&road=passkey&connect=" + encodeURIComponent(PORT_B))
  const views = world.windows.length
  child.say({type: "left", id: 1})
  await turns()
  assert.equal(content(), chooser, "a second left")
  assert.equal(world.windows.length, views)
  assert.ok(!child.killed)
})

test("a departure cyfr does not answer in time ends that cyfr and starts a fresh one, whose ready shows the chooser saying so; the old one's lines do nothing", async () => {
  const said = await signedIn()
  const old = child
  const RAIL_2 = "http://127.0.0.1:7340/rail/#read=YW5vdGhlcg"
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    assert.ok(select(PORT_B).prevented)
    await turns()
    mock.timers.tick(DEPARTURE_MS - 1)
    await turns()
    assert.ok(!old.killed, "not before the deadline")
    assert.equal(world.spawned.length, 1)
    mock.timers.tick(1)
    await turns()
    assert.equal(old.killed, "SIGKILL", "the cyfr that did not let go is killed outright")
    assert.equal(world.spawned.length, 1, "no fresh one while the old one holds the port")
    assert.ok(said.some((line) => /did not let go/.test(line)), said.join("; "))
    old.say({type: "left", id: 1})
    old.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
    old.proposes(PORT_A)
    old.exitCode = null
    old.emit("exit", null, "SIGKILL")
    await turns()
    assert.deepEqual(world.spawned, [["desktop-serve"], ["desktop-serve"]], "a fresh one once the old one exited")
    assert.notEqual(child, old)
    assert.equal(content(), undefined, "nothing of the old one's lines")
    assert.ok(!live().some((w) => w.webContents.url.startsWith("data:")), "and its exit ends nothing")
    assert.deepEqual(child.heard, [], "nothing answered to them")
    child.say({type: "ready", url: READY, rail: RAIL_2, update: UPDATE})
    await turns()
    assert.equal(content().webContents.url, READY + "&road=passkey&notice=unleft", "no connect: it resumes none")
    assert.equal(rail().webContents.url, RAIL_2, "the rail of the fresh one")
    assert.equal(world.frames.length, 1, "in the same window")
    assert.deepEqual(world.cleared, [])
  } finally {
    mock.timers.reset()
  }
})

test("a killed cyfr that never exits is given RESTART_WAIT_MS, then a fresh one starts all the same; none once the app is ending", async () => {
  for (const quit of [false, true]) {
    await signedIn()
    const old = child
    mock.timers.enable({apis: ["setTimeout"]})
    try {
      select(PORT_B)
      await turns()
      mock.timers.tick(DEPARTURE_MS)
      await turns()
      assert.equal(old.killed, "SIGKILL")
      if (quit) {
        world.app.emit("before-quit", {preventDefault() {}})
        await turns()
      }
      mock.timers.tick(RESTART_WAIT_MS - 1)
      await turns()
      assert.equal(world.spawned.length, 1, "not before the wait is up")
      mock.timers.tick(1)
      await turns()
      assert.equal(world.spawned.length, quit ? 1 : 2, quit ? "none once the app is ending" : "a fresh one, the wait up")
    } finally {
      mock.timers.reset()
    }
  }
})

test("a departure that ended in time leaves its deadline doing nothing", async () => {
  await signedIn()
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    await departsFor(PORT_B)
    const chooser = content()
    mock.timers.tick(DEPARTURE_MS)
    await turns()
    assert.ok(!child.killed)
    assert.equal(world.spawned.length, 1)
    assert.equal(content(), chooser)
  } finally {
    mock.timers.reset()
  }
})

// ---- Forget, in a row's menu on the rail ----

const menuOf = (home) => `http://127.0.0.1:7340/rail/menu?cyfr=${encodeURIComponent(home)}`
const forgets = () => child.heard.filter((m) => m.type === "forget")

test("Forget in a row's menu has cyfr forget that CYFR only once the person confirmed it; Cancel, or a dialog that failed, forgets nothing", async () => {
  await started(true)
  for (const [name, answer, forgot] of [["Cancel", () => ({response: 1}), false],
    ["a dialog that failed", () => Promise.reject(new Error("no")), false], ["Forget", () => ({response: 0}), true]]) {
    let answered
    world.messageBox = () => new Promise((resolve) => { answered = resolve })
    assert.ok(press(menuOf(PORT_B)).prevented, name)
    const menu = world.popups.at(-1)
    assert.deepEqual(menu.popped, [{window: frame()}], `${name}: over the app's window`)
    assert.deepEqual(menu.items.map((i) => i.label), ["Forget this CYFR on this computer"], name)
    menu.items[0].click()
    const {parent, options} = world.boxes.at(-1)
    assert.equal(parent, frame(), name)
    assert.equal(options.message, `Forget the CYFR at ${PORT_B} on this computer?`, `${name}: the dialog names the CYFR`)
    assert.deepEqual([options.buttons, options.cancelId, options.defaultId], [["Forget", "Cancel"], 1, 1], name)
    await turns()
    assert.deepEqual(forgets(), [], `${name}: not before the dialog answers`)
    answered(answer())
    await turns()
    assert.deepEqual(forgets(), forgot ? [{version: VERSION, type: "forget", home: PORT_B}] : [], name)
  }
  assert.deepEqual(leaves(), [], "nothing open, nothing left")
  assert.deepEqual(world.cleared, [], "main clears nothing of its own: cyfr asks for each store (erase)")
})

test("Forget of the CYFR open leaves it first: forget is sent only once cyfr left it", async () => {
  await signedIn()
  const page = content()
  press(menuOf(HOME))
  world.popups.at(-1).items[0].click()
  await turns()
  assert.ok(page.destroyed, "its pages closed")
  assert.deepEqual(leaves(), [{version: VERSION, type: "leave", id: 1}])
  assert.deepEqual(forgets(), [], "not while cyfr holds it")
  child.say({type: "left", id: 1})
  await turns()
  assert.deepEqual(forgets(), [{version: VERSION, type: "forget", home: HOME}])
  assert.equal(content().webContents.url, READY + "&road=passkey")
  assert.deepEqual(world.cleared, [])
})

// ---- erase: a store cyfr forgets ----

// cyfr asking for the store of `home`, or of its account service
// `account` for it, to be erased, as erase `id`.
// An answer belongs to the cyfr run that asked: a teardown or an erase
// begun under a cyfr that has ended, held past the fresh cyfr's start,
// releases nothing of the fresh run's departure and answers nobody, though
// the fresh run's ids start again at 1.
test("a teardown begun under a cyfr that has ended releases nothing of the fresh cyfr's departure of the same id", async () => {
  await signedIn()
  const held = []
  world.closingConnections = () => new Promise((end) => held.push(end))
  const old = child
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    assert.ok(select(PORT_B).prevented)
    await turns()
    const before = held.length
    assert.ok(before > 0, "the old run's teardown is held")
    mock.timers.tick(DEPARTURE_MS)
    await turns()
    assert.equal(old.killed, "SIGKILL")
    old.emit("exit", null, "SIGKILL")
    await turns()
    child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
    await turns()
    assert.ok(await opens())
    assert.ok(select(PORT_B).prevented)
    await turns()
    assert.ok(held.length > before, "the fresh run's teardown is held too")
    assert.deepEqual(leaves().at(-1), {version: VERSION, type: "leave", id: 1}, "the fresh run's departure is id 1 again")
    child.say({type: "left", id: 1})
    await turns()
    held.slice(0, before).forEach((end) => end())
    await turns(6)
    assert.equal(content(), undefined, "the old run's teardown released nothing")
    held.slice(before).forEach((end) => end())
    await turns(6)
    assert.equal(content().webContents.url, READY + "&road=passkey&connect=" + encodeURIComponent(PORT_B), "the fresh run's own teardown does")
  } finally {
    mock.timers.reset()
  }
})

test("an erase begun under a cyfr that has ended answers nobody, and the fresh cyfr's erase of the same id is answered alone", async () => {
  await signedIn()
  const pending = []
  world.clearing = () => new Promise((end) => pending.push(end))
  const old = child
  erases(1, PORT_A)
  await turns()
  assert.equal(pending.length, 1)
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    assert.ok(select(PORT_B).prevented)
    mock.timers.tick(DEPARTURE_MS)
    assert.equal(old.killed, "SIGKILL")
    old.emit("exit", null, "SIGKILL")
    await turns()
    child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
    erases(1, PORT_B)
    await turns()
    pending[0]()
    await turns(8)
    assert.equal(pending.length, 2, "the fresh run's erase is still being done")
    assert.deepEqual(erasedAnswers(), [], "the old run's erase answers nobody")
    pending[1]()
    await turns(8)
    assert.deepEqual(erasedAnswers(), [{version: VERSION, type: "erased", id: 1, ok: true}], "the fresh run's own erase is answered")
  } finally {
    mock.timers.reset()
  }
})

const erases = (id, home, account) => child.say({type: "erase", id, home, ...(account ? {account} : {})})
const erasedAnswers = () => child.heard.filter((m) => m.type === "erased")
const cookie = (value) => ({name: "_cyfr_key", domain: "cyfr.example.com", value})

test("erase clears exactly the store it names, a CYFR's or its account service's, and answers erased ok", async () => {
  await started(true)
  const kept = {[contentStore(PORT_A)]: "ada at A", [contentStore(PORT_B)]: "bea at B", [accountStore(PORT_A, ACCOUNT)]: "ada's ceremony",
    [accountStore(PORT_B, ACCOUNT)]: "bea's ceremony"}
  for (const [store, value] of Object.entries(kept)) world.disk.set(store, [cookie(value)])
  erases(1, PORT_A)
  await turns()
  assert.deepEqual(world.cleared, [contentStore(PORT_A)])
  assert.deepEqual(erasedAnswers(), [{version: VERSION, type: "erased", id: 1, ok: true}])
  erases(2, PORT_A, ACCOUNT)
  await turns()
  assert.deepEqual(world.cleared, [contentStore(PORT_A), accountStore(PORT_A, ACCOUNT)])
  assert.deepEqual(erasedAnswers().at(-1), {version: VERSION, type: "erased", id: 2, ok: true})
  assert.deepEqual(world.disk.get(contentStore(PORT_A)), [], "gone on disk")
  assert.deepEqual(world.disk.get(accountStore(PORT_A, ACCOUNT)), [], "gone on disk")
  assert.deepEqual(world.disk.get(contentStore(PORT_B)), [cookie("bea at B")], "another CYFR's untouched")
  assert.deepEqual(world.disk.get(accountStore(PORT_B, ACCOUNT)), [cookie("bea's ceremony")], "another CYFR's untouched")
  const account = world.sessions.get(accountStore(PORT_A, ACCOUNT))
  assert.equal(typeof account.received, "function", "the account store has its rules")
  assert.equal(account.listenerCount("select-webauthn-account"), 1, "and the passkey picker")
  assert.equal(world.sessions.get(contentStore(PORT_A)).listenerCount("select-webauthn-account"), 0)
  erases(3, PORT_A)
  erases(4, PORT_A, ACCOUNT)
  await turns(6)
  assert.deepEqual(erasedAnswers().slice(-2).map((m) => [m.id, m.ok]), [[3, true], [4, true]], "an erase again is answered the same")
  assert.equal(account.listenerCount("select-webauthn-account"), 1, "given its rules once")
})

test("an erase that leaves a cookie, or whose clear throws, answers ok false and says which, and nothing it was handed", async () => {
  for (const [fail, why] of [[() => { world.unclearable = true }, /^not cleared: left _cyfr_key at cyfr\.example\.com$/],
    [() => { world.clearing = () => Promise.reject(new Error("cookie=a-secret")) }, /^not cleared: clearStorageData threw$/]]) {
    const said = await started(true)
    world.disk.set(contentStore(PORT_A), [cookie("a-secret")])
    fail()
    erases(1, PORT_A)
    await turns(6)
    assert.deepEqual(erasedAnswers(), [{version: VERSION, type: "erased", id: 1, ok: false}], String(why))
    assert.ok(said.some((line) => why.test(line)), said.join("; "))
    assert.ok(!said.some((line) => /a-secret/.test(line)), said.join("; "))
  }
})

test("off the passkey road an erase answers ok and touches nothing, nothing being kept", async () => {
  await started(false)
  erases(1, PORT_A)
  erases(2, PORT_A, ACCOUNT)
  await turns()
  assert.deepEqual(erasedAnswers().map((m) => [m.id, m.ok]), [[1, true], [2, true]])
  assert.deepEqual(world.cleared, [])
  assert.deepEqual(stores(), [])
})

test("an erase of the CYFR open, or of the one a departure is leaving, answers ok false and clears nothing", async () => {
  await signedIn()
  const page = content()
  erases(1, HOME)
  await turns()
  assert.deepEqual(erasedAnswers(), [{version: VERSION, type: "erased", id: 1, ok: false}])
  assert.ok(!page.destroyed)
  assert.ok(select(PORT_B).prevented)
  erases(2, HOME)
  await turns()
  assert.deepEqual(erasedAnswers().at(-1), {version: VERSION, type: "erased", id: 2, ok: false})
  assert.deepEqual(world.cleared, [])
})

test("the engine's pending address is not the document that began a navigation", async () => {
  await signedIn()
  const page = content()
  const views = world.windows.length
  const event = {url: "http://127.0.0.1:7340/bootstrap/again", isMainFrame: true, initiator: page.webContents.mainFrame, prevented: false,
    preventDefault() { this.prevented = true }}
  page.webContents.getURL = () => "http://127.0.0.1:7340/bootstrap/"
  page.webContents.emit("will-navigate", event)
  await settled()
  assert.ok(event.prevented && !page.destroyed)
  assert.equal(world.windows.length, views, "the CYFR's document pressed nothing of the chooser's")
  assert.deepEqual(world.loads, [{url: HOME + "/", cookies: []}])
})

// cyfr's locked over the CYFR open at PORT_A, and the forgetting ended.
async function locksAndForgets() {
  const said = await started(true)
  await signsIn(PORT_A, "ada at A")
  return async () => {
    await saysLocked({home: PORT_A, account: ACCOUNT})
    for (let i = 0; i < 12; i++) await settled()
    return said
  }
}

test("what a closing page writes after the lock's clear began is cleared with the rest", async () => {
  const lock = await locksAndForgets()
  const ses = content().webContents.session
  let writes = 1
  world.step = (at) => {
    if (at === "cleared" && writes-- > 0) ses.jar = [{name: "__phoenix_flash__", domain: "cyfr.example.com", value: "late"}]
  }
  const said = await lock()
  assert.deepEqual(ses.jar, [])
  assert.deepEqual(cookiesOnDisk(PORT_A), [], "written out")
  assert.ok(!said.some((line) => line.startsWith("not cleared")), said.join("; "))
  assert.doesNotMatch(content().webContents.url, /notice=/)
})

test("a lock's clear that truly fails says which cookie was left or which call threw, and nothing it was handed", async () => {
  const handed = () => Promise.reject(new Error("cookie=a-secret at /private/file"))
  for (const [fail, why] of [
    [(ses) => { world.unclearable = true; ses.jar = [{name: "_cyfr_key", domain: "cyfr.example.com", value: "a-secret"}] },
      /^not cleared: left _cyfr_key at cyfr\.example\.com$/],
    [() => { world.clearing = handed }, /^not cleared: clearStorageData threw$/],
    [() => { world.step = (at) => { if (at === "cache cleared") throw new Error("cookie=a-secret at /private/file") } }, /^not cleared: clearCache threw$/],
    [() => { world.step = (at) => { if (at === "flushed") throw new Error("cookie=a-secret at /private/file") } }, /^not cleared: flushStore threw$/],
    [() => { world.step = (at) => { if (at === "read") throw new Error("cookie=a-secret at /private/file") } }, /^not cleared: cookies.get threw$/]]) {
    const lock = await locksAndForgets()
    fail(content().webContents.session)
    const said = await lock()
    assert.ok(said.some((line) => why.test(line)), `${why}: ${said.join("; ")}`)
    assert.ok(!said.some((line) => /a-secret|private/.test(line)), said.join("; "))
    assert.match(content().webContents.url, /notice=unforgotten$/)
  }
})

test("a response to a page the lock closed sets no cookie, and the next page's own does", async () => {
  const lock = await locksAndForgets()
  const page = content()
  await lock()
  const answered = (webContents) => {
    let out
    page.webContents.session.received({webContents, resourceType: "xhr", responseHeaders: {"set-cookie": ["a=1"]}},
      (r) => { out = r.responseHeaders })
    return out
  }
  assert.ok(page.destroyed)
  assert.equal(answered(page.webContents)["set-cookie"], undefined, "the closed page's")
  assert.equal(answered(undefined)["set-cookie"], undefined, "no page's")
  assert.deepEqual(answered(content().webContents)["set-cookie"], ["a=1"], "the page showing")
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

// Each clear a kept storage is asked for waits for the test: its ends, in
// order.
function heldClears() {
  const held = []
  world.clearing = () => new Promise((end, fail) => held.push({end, fail}))
  return held
}

test("the app's end never waits without end on a clear or a flush", async () => {
  const stuck = () => new Promise(() => {})
  for (const [name, hang, act] of [
    ["an erase's clear", () => { world.clearing = stuck }, async () => erases(1, PORT_B)],
    ["an erase's flush", () => { fromPartition(contentStore(PORT_B)).cookies.flushStore = stuck }, async () => erases(1, PORT_B)],
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
      hang()
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
      assert.ok(world.loads.every((l) => new URL(l.url).origin === PORT_A), `${name}, ${how}: nothing of another loads`)
    }
  }
})

test("an erase that ends after the app's end gave up is answered to nobody", async () => {
  await started(true)
  const held = heldClears()
  erases(1, PORT_B)
  await settled()
  assert.equal(held.length, 1)
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
  await turns()
  assert.deepEqual(erasedAnswers(), [], "cyfr asks for it again at its next start")
  assert.deepEqual(world.loads, [])
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
  assert.ok(frame().destroyed, "the app's window closed by main")
  assert.equal(rail(), undefined, "and the rail with it")
  await settled()
  assert.equal(world.quit, false, "which is no quit: the message stands")
  signedNobodyOut()
})

test("closing the app's window, and quitting, quit and sign nobody out", async () => {
  for (const end of [() => frame().close(), () => world.app.quit()]) {
    await signedIn()
    end()
    await settled()
    await settled()
    assert.equal(world.quit, true)
    assert.deepEqual(child.heard.at(-1), {version: VERSION, type: "shutdown"})
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

// The engine reporting that `w`'s load of `url` failed, its error page
// committed there (no did-navigate says so).
function fails(w, url, code = -106, isMainFrame = true) {
  if (isMainFrame) w.webContents.url = url
  w.webContents.emit("did-fail-load", {}, code, "", url, isMainFrame)
}

test("a CYFR's page that did not load gives way to the chooser: in its own view and session off the passkey road, in one of memory on it", async () => {
  for (const road of [true, false]) {
    const said = await signedIn(road)
    const page = content()
    const ses = page.webContents.session
    const windows = world.windows.length
    fails(page, HOME + "/threads")
    assert.equal(page.webContents.url, HOME + "/threads", "not from inside the engine's report")
    assert.equal(world.windows.length, windows, "nothing opened from inside it either")
    await settled()
    const chooser = content()
    assert.equal(chooser.webContents.url, READY + (road ? "&road=passkey" : "") + "&notice=unanswered")
    if (road) {
      assert.ok(page.destroyed && chooser !== page, "no kept store holds the chooser: a view of its own")
      assert.doesNotMatch(chooser.webContents.session.partition, /^persist:/)
      assert.equal(page.webContents.url, HOME + "/threads", "nothing loaded into the CYFR's view")
    } else {
      assert.ok(chooser === page && !page.destroyed && world.windows.length === windows, "the same window")
      assert.equal(page.webContents.session, ses, "the same session")
    }
    assert.ok(!child.heard.some((m) => m.type === "lock"))
    assert.ok(!said.some((line) => line.startsWith("locked:")))
    signedNobodyOut()
  }
})

test("a frame's failed load, and a load given up, leave the page", async () => {
  await signedIn()
  const page = content()
  fails(page, HOME + "/frame", -106, false)
  fails(page, HOME + "/", -3)
  await settled()
  assert.equal(page.webContents.url, HOME + "/")
})

test("a lock in the turn of a failed load loads nothing into the window it closed", async () => {
  await signedIn()
  const page = content()
  fails(page, HOME + "/threads")
  await saysLocked()
  assert.ok(page.destroyed)
  assert.equal(page.webContents.url, HOME + "/threads")
  assert.doesNotMatch(content().webContents.url, /unanswered/)
})

test("a lock in the turn of a failed load shows no chooser while what it forgets is being forgotten", async () => {
  for (const road of [true, false]) {
    await signedIn(road)
    const page = content()
    const held = heldClears()
    fails(page, HOME + "/threads")
    await saysLocked()
    assert.ok(page.destroyed, road)
    assert.equal(content(), undefined, `${road}: no chooser while it is being forgotten`)
    held.forEach(({end}) => end())
    await turns()
    assert.match(content().webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\//, road)
    assert.doesNotMatch(content().webContents.url, /unanswered/, road)
  }
})

test("Try again opens the CYFR's root in its own store, in a view of its own, loading nothing into the chooser that asked", async () => {
  await signedIn()
  const page = content()
  fails(page, HOME + "/threads")
  await settled()
  const chooser = content()
  const at = chooser.webContents.url
  assert.ok(navigate(chooser, "http://127.0.0.1:7340/bootstrap/again").prevented)
  assert.equal(chooser.webContents.url, at, "not from inside the engine's question")
  await settled()
  assert.ok(chooser.destroyed)
  assert.equal(content().webContents.url, HOME + "/")
  assert.equal(content().webContents.session.partition, contentStore(HOME))
  assert.deepEqual(world.loads.at(-1), {url: HOME + "/", cookies: []})
  signedNobodyOut()
})

// What `act` has main write to its stderr.
async function printing(act) {
  const own = process.stderr.write
  let out = ""
  process.stderr.write = (chunk) => {
    out += chunk
    return true
  }
  try {
    await act()
  } finally {
    process.stderr.write = own
  }
  return out
}

test("the engine's warning of a failed load prints no fragment or query", async () => {
  await signedIn()
  const out = await printing(async () => {
    process.emitWarning("Failed to load URL: https://x.test/complete?q=a-marker#a-marker with error: ERR_EMPTY_RESPONSE", "electron")
    await settled()
    await settled()
  })
  assert.match(out, /^CYFR: warning: electron: Failed to load URL: https:\/\/x\.test with error: ERR_EMPTY_RESPONSE$/m)
  assert.doesNotMatch(out, /marker/)
  assert.equal(process.listenerCount("warning"), 1, "the app's printer alone")
})

test("every other warning still prints, its code and detail with it, by the same rule", async () => {
  await signedIn()
  const out = await printing(async () => {
    process.emitWarning("old() is deprecated", {type: "DeprecationWarning", code: "DEP0001",
      detail: "see https://x.test/why?q=a-marker#a-marker"})
    process.emitWarning("a warning of no kind of its own")
    await settled()
    await settled()
  })
  assert.match(out, /^CYFR: warning: \[DEP0001\] DeprecationWarning: old\(\) is deprecated\nsee https:\/\/x\.test$/m)
  assert.match(out, /^CYFR: warning: Warning: a warning of no kind of its own$/m)
  assert.doesNotMatch(out, /marker/)
})

test("what main says is printed by the same rule where nobody else takes it", async () => {
  reset()
  const out = await printing(async () => {
    startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad: true})
    await settled()
    child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
    await settled()
    child.stderr.write("Error: https://x.test/auth/passkey/complete/a-marker did not answer\n")
    await settled()
    child.emit("exit", 1, null)
    await settled()
  })
  assert.match(out, /^CYFR: cyfr ended: https:\/\/x\.test did not answer$/m)
  assert.doesNotMatch(out, /marker/)
})

test("cyfr's own lines are printed whole lines at a time, with no fragment or query", async () => {
  await started(true)
  const out = await printing(async () => {
    child.stderr.write("Error: Get \"https://x.te")
    await settled()
    child.stderr.write("st/login?t=a-marker\": EOF\nlast, unended: https://x.test/#a-marker")
    child.stderr.end()
    await settled()
    await settled()
  })
  assert.doesNotMatch(out, /marker/)
  assert.match(out, /https:\/\/x\.test/)
  assert.match(out, /last, unended/)
})

test("the engine's logging switch in the environment is dropped as the app starts", async () => {
  process.env.ELECTRON_ENABLE_LOGGING = "1"
  await started(true)
  assert.equal(process.env.ELECTRON_ENABLE_LOGGING, undefined)
})

// A confirmation window the engine made for a page, opened.
function confirmationOpened(page) {
  page.webContents.opens({url: "http://127.0.0.1:7340/confirm?ref=cfm_1"})
  const opened = new BrowserWindow({webPreferences: {session: page.webContents.session}})
  page.webContents.emit("did-create-window", opened)
  return opened
}

// Its two ends: its page lost, and a load of its top frame that failed.
const CONFIRMATION_ENDS = {
  lost: (w) => w.webContents.emit("render-process-gone", {}, {reason: "killed"}),
  failed: (w) => fails(w, "http://127.0.0.1:7340/confirm?ref=cfm_1")
}

test("a confirmation window whose page is lost or failed to load closes alone, the person back on the CYFR's page", async () => {
  for (const [end, made] of Object.entries(CONFIRMATION_ENDS)) {
    await signedIn()
    const page = content()
    const opened = confirmationOpened(page)
    made(opened)
    await settled()
    assert.ok(opened.destroyed, `${end}: it closed`)
    assert.ok(!page.destroyed, end)
    assert.equal(page.webContents.reloaded, undefined, end)
    assert.ok(!child.heard.some((m) => m.type === "lock"), `${end}: nothing locked`)
  }
})

test("a confirmation window's load given up, or a frame's that failed, leaves it open", async () => {
  await signedIn()
  const opened = confirmationOpened(content())
  fails(opened, "http://127.0.0.1:7340/confirm?ref=cfm_1", -3)
  fails(opened, "http://127.0.0.1:7340/frame", -106, false)
  await settled()
  assert.ok(!opened.destroyed)
})

test("opened and cyfr's locked read in one go leave cyfr running and the chooser ready", async () => {
  await started(false)
  child.proposes(HOME)
  await settled()
  assert.ok(navigate(content(), HOME + "/company-login").prevented, "nothing of it before it is open")
  assert.ok(!child.heard.some((m) => m.type === "lock"), "and so no lock of it")
  child.say({type: "opened", home: HOME, attempt: child.attempts})
  await saysLocked()
  assert.equal(child.killed, false)
  assert.match(content().webContents.url, /^http:\/\/127\.0\.0\.1:7340\/bootstrap\//)
  // The chooser goes on to the device's pages, which give the CYFR.
  await content().webContents.loadURL("http://127.0.0.1:7340/")
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
  page.webContents.loadURL(HOME + "/login")
  await settled()
  const request = {...signIn["requests"]["another_sign_in"]["request"], return: HOME + "/login", expires_at: Date.now() + 60_000}
  const hop = `${ACCOUNT}/account/sign#${fragment(request)}`
  assert.ok(navigate(page, hop).prevented, "the hop leaves the content window at the sign-in page")
  const account = live().find((w) => w.webContents.url === hop)
  // The page's own navigation to the answer, as the engine raises it:
  // did-start-navigation first, then will-navigate.
  const answer = () => {
    const back = {url: ANSWER, isMainFrame: true, initiator: account.webContents.mainFrame, prevented: false,
      preventDefault() { this.prevented = true }}
    account.webContents.emit("did-start-navigation", {url: ANSWER, isMainFrame: true, isSameDocument: false})
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

test("an account window whose page is lost or failed to load ends the ceremony, the person back on the CYFR's sign-in page", async () => {
  for (const [end, made] of Object.entries({
    lost: (w) => w.webContents.emit("render-process-gone", {}, {reason: "killed"}),
    failed: (w) => fails(w, ACCOUNT + "/account/sign")
  })) {
    const {page} = await hopped()
    const account = live().find((w) => w.webContents.url.startsWith(ACCOUNT + "/account/sign"))
    made(account)
    await settled()
    assert.ok(account.destroyed, `${end}: the ceremony ended`)
    assert.ok(!page.destroyed && page.webContents.url === HOME + "/login", end)
  }
})

test("the account window and a confirmation window are the app's window's own, centred over the content beside the rail", async () => {
  const {page} = await hopped()
  const account = live().find((w) => w.webContents.url.startsWith(ACCOUNT + "/account/sign"))
  const f = frame()
  // The content's rectangle on the screen: the window's content area at
  // AT, less the rail.
  const over = (width, height) => ({width, height, x: AT.x + RAIL_WIDTH + (1280 - RAIL_WIDTH - width) / 2, y: AT.y + (860 - height) / 2})
  const {parent, x, y, width, height} = account.options
  assert.equal(parent, f)
  assert.deepEqual({x, y, width, height}, over(560, 760))
  assert.equal(account.webContents.session.partition, accountStore(HOME, ACCOUNT), "in the store of that CYFR and account service")
  const opened = page.webContents.opens({url: "http://127.0.0.1:7340/confirm?ref=cfm_1"})
  assert.equal(opened.action, "allow")
  const o = opened.overrideBrowserWindowOptions
  assert.equal(o.parent, f)
  assert.deepEqual({x: o.x, y: o.y, width: o.width, height: o.height}, over(520, 640))
  assert.equal(o.webPreferences.session, page.webContents.session, "in the content's own session")
  account.destroy() // the ceremony ended, its timer with it
})

test("the account store's passkey picker answers the ceremony the account window shows, and nothing else", async () => {
  await hopped()
  const account = live().find((w) => w.webContents.url.startsWith(ACCOUNT + "/account/sign"))
  const ses = account.webContents.session
  assert.equal(ses.listenerCount("select-webauthn-account"), 1)
  const picks = (frame) => {
    const chosen = []
    ses.emit("select-webauthn-account", {preventDefault() {}},
      {frame, relyingPartyId: new URL(ACCOUNT).hostname, accounts: [{credentialId: "cred-1", displayName: "Ada"}]},
      (id) => chosen.push(id))
    return chosen
  }
  const shown = picks(account.webContents.mainFrame)
  const other = picks({processId: 9, routingId: 9, url: account.webContents.url})
  await turns()
  assert.deepEqual(shown, ["cred-1"], "the person's choice, asked over the account window")
  assert.equal(world.boxes.at(-1).parent, account)
  assert.deepEqual(other, [null], "another frame's ceremony is refused")
  account.destroy() // the ceremony ended, its timer with it
})

// Each way the account window's top frame reaches a page, as the pinned
// engine reports it (measured on Electron 45.4.1 by a probe of the
// recheck): the events it raises, in order, for a navigation to `url`.
const ENGINE = {
  "a history move": (w, url) => [["did-start-navigation", {url, isMainFrame: true, isSameDocument: false}]],
  "a move within the page's history": (w, url) => [["did-start-navigation", {url, isMainFrame: true, isSameDocument: true}],
    ["did-navigate-in-page", {}, url, true]],
  "a reload by main": (w, url) => [["did-start-navigation", {url, isMainFrame: true, isSameDocument: false}]],
  "a reload by the page": (w, url) => [["did-start-navigation", {url, isMainFrame: true, isSameDocument: false}],
    ["will-frame-navigate", pageNavigation(w, url)], ["will-navigate", pageNavigation(w, url)]],
  "a redirect": (w, url) => [["will-redirect", pageNavigation(w, url)]],
}
function pageNavigation(w, url) {
  return {url, isMainFrame: true, initiator: w.webContents.mainFrame, prevented: false, preventDefault() { this.prevented = true }}
}

test("every way the account window reaches a page that takes a request is read by the one reader, and a refused one ends the ceremony", async () => {
  const current = {...signIn["requests"]["another_sign_in"]["request"], return: HOME + "/login", expires_at: Date.now() + 60_000}
  const refused = {
    "no request": `${ACCOUNT}/account/new`,
    "an expired request": `${ACCOUNT}/account/new#name=&request=${fragment({...current, expires_at: Date.now() - 1})}`,
    "another CYFR's request": `${ACCOUNT}/account/new#name=&request=${fragment({...current, audience: "https://bob.example", return: "https://bob.example/login"})}`,
  }
  for (const [how, events] of Object.entries(ENGINE)) {
    for (const [why, url] of Object.entries(refused)) {
      const {page} = await hopped()
      const account = live().find((w) => w.webContents.url.startsWith(ACCOUNT + "/account/sign"))
      for (const [name, ...args] of events(account, url)) account.webContents.emit(name, ...args)
      await settled()
      assert.ok(account.destroyed, `${how}, ${why}: the ceremony ended`)
      assert.equal(page.webContents.url, HOME + "/login", `${how}, ${why}: nothing was delivered`)
    }
  }
  // Its own page, as the reader reads it, stays: a reload of it by main or
  // by the page, and a move within it.
  for (const how of ["a reload by main", "a reload by the page", "a move within the page's history"]) {
    await hopped()
    const account = live().find((w) => w.webContents.url.startsWith(ACCOUNT + "/account/sign"))
    const own = `${ACCOUNT}/account/new#name=&request=${fragment(current)}`
    for (const [name, ...args] of ENGINE[how](account, own)) account.webContents.emit(name, ...args)
    await settled()
    assert.ok(!account.destroyed, `${how} of a page the reader reads: the ceremony goes on`)
  }
})

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
  chooser.webContents.loadURL("http://127.0.0.1:7340/")
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

// ---- the folder CYFR is set up in on this computer ----

// Change…, as the chooser shown in epoch 1 asks for its pick 0.
const PICK = "http://127.0.0.1:7340/bootstrap/pick?epoch=1&pick=0"
const folders = () => child.heard.filter((m) => m.type === "folder-picked")

test("Change… opens the system's folder dialog over the app's window, never loads, and cyfr hears the folder once", async () => {
  for (const road of [false, true]) {
    await started(road)
    const w = content()
    assert.ok(navigate(w, PICK).prevented, "its address never loads")
    assert.equal(world.dialogs.length, 1)
    const [{parent, options}] = world.dialogs
    assert.equal(parent, frame(), "over the app's window")
    assert.deepEqual(options.properties, ["openDirectory", "createDirectory"])
    assert.ok(navigate(w, PICK).prevented)
    assert.equal(world.dialogs.length, 1, "one pick at a time")
    world.dialogs[0].answer({canceled: false, filePaths: ["/home/ada/elsewhere"]})
    await settled()
    assert.deepEqual(folders(), [{version: VERSION, type: "folder-picked", path: "/home/ada/elsewhere", epoch: 1, pick: 0}])
    navigate(w, PICK)
    world.dialogs[1].answer({canceled: true, filePaths: []})
    await settled()
    assert.deepEqual(folders().at(-1), {version: VERSION, type: "folder-picked", path: null, epoch: 1, pick: 0}, "cancelled")
    assert.equal(content(), w, "the chooser stands")
    assert.deepEqual(world.fetched, [])
  }
})

test("a redirect, or a page other than the chooser, opens no dialog", async () => {
  await started(false)
  const w = content()
  assert.ok(redirected(w, PICK).prevented)
  assert.ok(await opens())
  await give(w)
  assert.ok(navigate(w, PICK).prevented)
  assert.equal(world.dialogs.length, 0)
  assert.deepEqual(folders(), [])
})

test("a lock, or the chooser leaving, answers the pick with none at once, and the dialog's folder after is dropped", async () => {
  const ends = {
    "cyfr's lock": async () => saysLocked({}),
    "the chooser loading again": async (w) => { w.webContents.reload(); await settled() },
    "a dialog that failed": async () => { world.dialogs[0].answer(Promise.reject(new Error("no portal"))); await settled() }
  }
  for (const [name, end] of Object.entries(ends)) {
    await started(false)
    navigate(content(), PICK)
    await end(content())
    assert.deepEqual(folders(), [{version: VERSION, type: "folder-picked", path: null, epoch: 1, pick: 0}], name)
    world.dialogs[0].answer({canceled: false, filePaths: ["/home/ada/elsewhere"]})
    await settled()
    assert.deepEqual(folders(), [{version: VERSION, type: "folder-picked", path: null, epoch: 1, pick: 0}], `${name}: the late folder is dropped`)
  }
})

test("Docker's page, linked from the chooser, opens in the person's browser and never in the app's window", async () => {
  for (const page of ["https://www.docker.com/products/docker-desktop/", "https://docs.docker.com/engine/install/"]) {
    await started(false)
    const w = content()
    assert.ok(navigate(w, page).prevented, "the window does not go there")
    await settled()
    assert.deepEqual(world.opened, [page])
    assert.equal(content(), w)
    assert.deepEqual(world.loads, [], "nothing of it loads in the app")
  }
  await started(false)
  assert.ok(navigate(content(), "https://www.docker.com/").prevented)
  assert.ok(redirected(content(), "https://docs.docker.com/engine/install/").prevented)
  await settled()
  assert.deepEqual(world.opened, [], "any other page, or a redirect, opens nothing")
})

const TOKEN = "cd".repeat(32)

test("on macOS and Windows a CYFR no one is set up at opens at its setup page, the token in the fragment alone", async () => {
  const platform = Object.getOwnPropertyDescriptor(process, "platform"), argv = process.argv
  for (const system of ["darwin", "win32"]) {
    Object.defineProperty(process, "platform", {...platform, value: system})
    // The app as a person starts it, with no switch: this test's path
    // reads as one on Windows.
    process.argv = argv.slice(0, 1)
    try {
      reset()
      // The road is the system's, as the app is started on it.
      const said = []
      startApp({cyfr: "/opt/cyfr/resources/cyfr", say: (line) => said.push(line)})
      await settled()
      child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
      await settled()
      assert.equal(content().webContents.url, READY + "&road=passkey", system)
      const attempt = child.proposes(HOME, {setup: TOKEN})
      await settled()
      await settled()
      assert.ok(child.heard.some((m) => m.type === "home-ready" && m.attempt === attempt), system)
      child.say({type: "opened", home: HOME, attempt: child.attempts})
      await settled()
      await settled()
      assert.deepEqual(world.loads.map((l) => l.url), [`${HOME}/setup#${TOKEN}`], `${system}: the CYFR's setup page`)
      assert.ok(!said.some((line) => line.includes(TOKEN)), `${system}: no line the app printed carries the token`)
    } finally {
      Object.defineProperty(process, "platform", platform)
      process.argv = argv
    }
  }
})

// ---- --quit: cyfr update and uninstall asking the running app to end ----

// A launch of the app with --quit, by its own command line, with another
// app of this account running (`held`) or none: its exit, what it said
// and what it asked the lock.
function quitLaunch(held) {
  const argv = process.argv
  reset()
  world.quitSwitch = ""
  world.lockHeld = held
  world.exited = undefined
  process.argv = [argv[0], "--quit"]
  const said = []
  try {
    startApp({cyfr: "/opt/cyfr/resources/cyfr", say: (line) => said.push(line)})
  } finally {
    process.argv = argv
    world.quitSwitch = undefined
  }
  return {exited: world.exited, said, asked: world.lockAsked}
}

test("the app started with --quit asks the one this account runs to end and exits 3, or exits 0 with none, starting nothing", async () => {
  for (const [held, exited, line] of [[true, 3, "the CYFR app that runs for this account was asked to quit"],
    [false, 0, "no CYFR app runs for this account"]]) {
    const launch = quitLaunch(held)
    await settled()
    assert.deepEqual(launch, {exited, said: [line], asked: [{quit: true}]}, `another running: ${held}`)
    assert.deepEqual(world.spawned, [], "no cyfr")
    assert.deepEqual(world.frames, [], "no window")
  }
  world.exited = undefined
})

test("a running app asked by a launch of --quit ends as a quit does, telling its cyfr; a plain second launch shows it", async () => {
  await started(true)
  const focused = frame().focused
  world.app.emit("second-instance", {}, [], "/", {})
  await settled()
  await settled()
  assert.equal(world.quit, false, "a plain second launch")
  assert.equal(frame().focused, focused + 1, "is shown")
  world.trace = []
  world.app.emit("second-instance", {}, [], "/", {quit: true})
  await settled()
  await settled()
  assert.equal(world.quit, true)
  assert.deepEqual(world.trace, ["told shutdown", "input ended"], "cyfr told, then its input ended")
})

// ---- the box's screen ----

const SCREEN = "/home/ana/cyfr"
// The screen road is Linux's alone (policy.js screenProject): on macOS and
// Windows the switch is refused, which the last test of these shows there.
const ON_LINUX = {skip: process.platform !== "linux" && "the box's screen runs on Linux alone"}
const SHELL_PAGE = "http://127.0.0.1:7340/"

// The screen's end by the kernel, recorded: the turn it came in, and what
// main had done by then: quit or exited, and what it had told cyfr and
// said, in order, since the test last cleared world.trace.
const endSelf = () => { world.endedSelf.push({quit: world.quit, exited: world.exited, trace: [...world.trace]}) }
const sayTraced = (said) => (line) => {
  said.push(line)
  world.trace.push(`said ${line}`)
}
// What the screen's one end has done by the instant it ends: cyfr told to
// shut down, its input ended, then the sentence.
const ENDS = ["told shutdown", "input ended", "said ended: the app's process ends itself, without the toolkit's teardown"]

// The app started as the box's screen for SCREEN (or `project`), on
// whatever road the platform would give, its shell said ready.
async function screenStarted(project = SCREEN) {
  reset()
  world.screen = project
  world.exited = undefined
  const said = []
  try {
    startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad: true, say: sayTraced(said), endSelf})
    await settled()
    if (world.exited === undefined) {
      child.say({type: "ready", url: SHELL_PAGE})
      await settled()
    }
  } finally {
    world.screen = undefined
  }
  return said
}

test("as the box's screen the app runs the screen shell in that project, in one frameless maximized window with no menu", ON_LINUX, async () => {
  await screenStarted()
  assert.deepEqual(world.spawned, [["screen", "shell"]])
  assert.deepEqual(world.spawnedIn, [SCREEN])
  assert.deepEqual(world.menus, [null], "no menu")
  const w = content()
  assert.equal(w.webContents.url, SHELL_PAGE, "the shell's own page, no chooser")
  assert.equal(world.frames.length, 1)
  assert.equal(frame().options.frame, false)
  assert.ok(frame().maximized)
  assert.deepEqual(stores(), [], "nothing kept on disk")
  assert.equal(world.windows.find(isRail), undefined, "no rail")
  assert.deepEqual(w.bounds.at(-1), {x: 0, y: 0, width: 1280, height: 860}, "the content the whole window")
})

test("the box's screen asked by a launch of --quit is shown and goes on: its service is stopped instead", ON_LINUX, async () => {
  await screenStarted()
  const focused = frame().focused
  world.app.emit("second-instance", {}, [], "/", {quit: true})
  await settled()
  await settled()
  assert.deepEqual({quit: world.quit, endedSelf: world.endedSelf, focused: frame().focused}, {quit: false, endedSelf: [], focused: focused + 1})
  assert.ok(!child.heard.some((m) => m.type === "shutdown"), "cyfr goes on")
})

test("only an explicit project makes the app a screen; another switch value is refused", ON_LINUX, async () => {
  await started(true)
  assert.deepEqual(world.spawned, [["desktop-serve"]], "no switch, no screen")
  for (const value of ["", "cyfr", "/home/ana/../cyfr"]) {
    const said = await screenStarted(value)
    assert.equal(world.exited, 2, value)
    assert.deepEqual(world.spawned, [], value)
    assert.ok(said.some((l) => l.startsWith("refused: --screen-project")), value)
  }
  world.exited = undefined
})

test("the folder cyfr setup opened the app in is the one its cyfr suggests; a switch naming no folder is refused", async () => {
  const folder = process.platform === "win32" ? "C:\\Users\\ana\\setup-here" : "/home/ana/setup-here"
  world.setup = folder
  try {
    await started(true)
    assert.deepEqual(world.spawned, [["desktop-serve", folder]])
    for (const value of ["", "setup-here", process.platform === "win32" ? "C:\\Users\\..\\ana" : "/home/ana/../bob"]) {
      world.setup = value
      world.exited = undefined
      const said = await started(true)
      assert.equal(world.exited, 2, value)
      assert.deepEqual(world.spawned, [], value)
      assert.ok(said.some((l) => l.startsWith("refused: --setup-project")), value)
    }
  } finally {
    world.setup = undefined
    world.exited = undefined
  }
  await started(true)
  assert.deepEqual(world.spawned, [["desktop-serve"]], "no switch, ~/cyfr")
})

test("the screen's first page is the shell's own: a chooser there ends the app", ON_LINUX, async () => {
  reset()
  world.screen = SCREEN
  startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad: false, say: () => {}, endSelf})
  world.screen = undefined
  await settled()
  child.say({type: "ready", url: READY})
  await settled()
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.equal(content(), undefined)
  assert.equal(world.endedSelf.length, 1, "the app ends itself")
  assert.ok(child.heard.some((m) => m.type === "shutdown"), "cyfr is shut down")
})

test("a lock on the screen hides the page at once and shows the shell's page again, in a new session", ON_LINUX, async () => {
  await screenStarted()
  assert.ok(await opens())
  await give(content())
  const before = content()
  const session = before.webContents.session
  child.say({type: "locked", home: HOME, account: ACCOUNT})
  assert.ok(before.destroyed, "hidden as locked is heard")
  await settled()
  await settled()
  const after = content()
  assert.equal(after.webContents.url, SHELL_PAGE)
  assert.notEqual(after.webContents.session, session)
})

test("on the screen a lost page locks, a failed load shows the shell's page, and cyfr's end ends the app with no message", ON_LINUX, async () => {
  await screenStarted()
  assert.ok(await opens())
  await give(content())
  fails(content(), HOME + "/", -106)
  await settled()
  await settled()
  assert.equal(content().webContents.url, SHELL_PAGE, "the shell's page, from which Open CYFR tries again")
  content().webContents.emit("render-process-gone", {}, {reason: "crashed"})
  await settled()
  await settled()
  assert.ok(child.heard.some((m) => m.type === "lock"), "a lost page locks")
  child.emit("exit", 1, null)
  await settled()
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.equal(live().length, 0, "no message window")
  assert.equal(world.endedSelf.length, 1, "the app ends itself, to be started again locked")
})


// On the box's screen a lock is confirmed by the compositor's list of
// windows, every window shown at the lock closed (internal/wayland): the
// lock closes the app's window, which ends nothing of the app, and the
// locked screen's page comes up in a fresh one, whose own close is still
// the app's end.
test("on the screen a lock closes the app's window, ending nothing, and the locked page shows in a fresh one", ON_LINUX, async () => {
  await screenStarted()
  assert.ok(await opens())
  await give(content())
  const before = frame()
  child.say({type: "locked"})
  await turns()
  assert.ok(before.isDestroyed(), "the window shown at the lock is closed, for the compositor to confirm the hide")
  assert.deepEqual(world.endedSelf, [], "its close ends nothing")
  assert.notEqual(frame(), before, "a fresh window")
  assert.ok(!frame().isDestroyed())
  assert.equal(content().webContents.url, SHELL_PAGE, "showing the locked screen's page")
  frame().emit("closed")
  await turns()
  assert.equal(world.endedSelf.length, 1, "the fresh window's own close is the app's end")
})

test("on the screen cyfr's end ends the app's process in its own turn, after its sentence, with no quit and no exit of the engine's", ON_LINUX, async () => {
  const said = await screenStarted()
  assert.ok(await opens())
  await give(content())
  const quits = []
  world.app.on("before-quit", () => quits.push("before-quit"))
  world.exited = undefined
  world.trace = []
  // The turn the line from cyfr is read in, and nothing after it: the
  // toolkit's teardown would run in a later one.
  child.emit("exit", 0, null)
  assert.deepEqual(world.endedSelf, [{quit: false, exited: undefined, trace: ["said cyfr ended: it exited (0)", ...ENDS]}],
    "ended in that turn, cyfr told and its input ended before the sentence, no quit or exit asked")
  assert.deepEqual(quits, [])
  assert.ok(said.length > 0)
})

test("on the screen the shell's ending ends the app's process once cyfr is told", ON_LINUX, async () => {
  const said = await screenStarted()
  assert.ok(await opens())
  await give(content())
  world.trace = []
  child.say({type: "ending"})
  await settled()
  assert.deepEqual(world.endedSelf, [{quit: false, exited: undefined, trace: ["said cyfr ended: the screen shell is ending", ...ENDS]}],
    "cyfr told and its input ended before the sentence")
  assert.ok(said.length > 0)
})

// Every road by which the screen's app ends is its one end: cyfr told and
// its input ended, the sentence, then the process's own end, in the turn
// the cause came in; none reaches the engine's quit, exit or relaunch. A
// route other than the one the app started on is its launcher's to start
// it on (cmd/screen.go, cyfr screen app), never the app's own.
test("on the screen every end of the app is its one end, and none is the engine's quit, exit or relaunch", ON_LINUX, async () => {
  const roads = {
    "cyfr's exit": [() => child.emit("exit", 1, null), "cyfr ended: it exited (1)"],
    "the shell's ending": [() => child.say({type: "ending"}), "cyfr ended: the screen shell is ending"],
    "the system's quit": [() => world.app.quit(), null],
    "the window closed": [() => frame().emit("closed"), null],
    "a route the app was not started on": [() => child.proposes(HOME, {proxy: "socks5://127.0.0.1:1055", resolver: "MAP * ~NOTFOUND"}),
      "cyfr ended: it named a route the app was not started on, which the screen's launcher starts it on"],
    "a CYFR this app does not open": [() => child.say({type: "home", home: "not an address", account: ACCOUNT, attempt: 9}),
      "cyfr ended: it named a CYFR this app does not open"],
    "a CYFR it was not keeping to opened": [() => child.say({type: "opened", home: "https://other.example", attempt: 1}),
      "cyfr ended: it opened a CYFR this app was not keeping to"]
  }
  for (const [road, [cause, sentence]] of Object.entries(roads)) {
    await screenStarted()
    world.exited = undefined
    world.trace = []
    cause()
    await settled()
    await settled()
    assert.deepEqual(world.endedSelf, [{quit: false, exited: undefined, trace: [...(sentence ? [`said ${sentence}`] : []), ...ENDS]}], road)
    assert.equal(world.relaunched, null, road)
  }
  // Its first page not the shell's own, the same.
  reset()
  world.screen = SCREEN
  startApp({cyfr: "/opt/cyfr/resources/cyfr", accountRoad: false, say: sayTraced([]), endSelf})
  world.screen = undefined
  await settled()
  world.trace = []
  child.say({type: "ready", url: READY})
  await settled()
  assert.deepEqual(world.endedSelf, [{quit: false, exited: undefined, trace: ["said cyfr ended: its first page was not the chooser", ...ENDS]}])
})

test("on the screen a failed load of the shell's own page locks, and so does a confirmation lost or failed", ON_LINUX, async () => {
  await screenStarted()
  assert.ok(await opens())
  await give(content())
  let locks = child.heard.filter((m) => m.type === "lock").length
  fails(content(), SHELL_PAGE, -102)
  await settled()
  assert.equal(child.heard.filter((m) => m.type === "lock").length, locks + 1, "a failed load of the shell's page locks")
  child.say({type: "locked"})
  await settled()
  await settled()
  assert.equal(content().webContents.url, SHELL_PAGE)
  assert.ok(await opens())
  await give(content())
  for (const [end, made] of Object.entries(CONFIRMATION_ENDS)) {
    const opened = confirmationOpened(content())
    locks = child.heard.filter((m) => m.type === "lock").length
    made(opened)
    await settled()
    assert.ok(opened.destroyed, end)
    assert.equal(child.heard.filter((m) => m.type === "lock").length, locks + 1, `a confirmation ${end} locks`)
    child.say({type: "locked"})
    await settled()
    await settled()
    assert.ok(await opens(), end)
    await give(content())
  }
})

test("on macOS and Windows the screen road is refused", {skip: process.platform === "linux" && "it runs there"}, async () => {
  const said = await screenStarted()
  assert.equal(world.exited, 2)
  assert.deepEqual(world.spawned, [])
  assert.ok(said.some((l) => l.startsWith("refused: --screen-project")))
  world.exited = undefined
})

// Its pages' destruction held past the departure's deadline, a teardown
// whose cyfr was ended goes on after the fresh cyfr opened the same CYFR
// again: the store is that fresh run's now, and its connections too.
test("a teardown begun under a cyfr that has ended closes no connection of a store the fresh cyfr opened again", async () => {
  await signedIn()
  const old = child
  world.holdPages = true
  mock.timers.enable({apis: ["setTimeout"]})
  try {
    assert.ok(select(PORT_B).prevented)
    await turns()
    assert.ok(world.heldPages.length > 0)
    assert.deepEqual(world.connections, [])
    mock.timers.tick(DEPARTURE_MS)
    await turns()
    assert.equal(old.killed, "SIGKILL")
    old.emit("exit", null, "SIGKILL")
    await turns()
    world.holdPages = false
    child.say({type: "ready", url: READY, rail: RAIL, update: UPDATE})
    await turns()
    assert.ok(await opens())
    assert.equal(content().webContents.session.partition, contentStore(HOME))
    letPagesGo()
    await turns(6)
    assert.ok(!world.connections.includes(contentStore(HOME)), "the old teardown closed the freshly opened partition's connections")
  } finally {
    mock.timers.reset()
  }
})
