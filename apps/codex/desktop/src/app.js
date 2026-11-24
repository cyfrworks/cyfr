// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The CYFR app's main process: it starts cyfr desktop-serve (or, as the
// box's screen, cyfr screen shell), owns every
// window the app has, and holds each to its rules (policy.js).
//
// What main does is decided in one place, states.js: every event, from
// cyfr, from a window or from the system, goes through its `step`, and
// this file carries out the effects it answers, in order, and nothing
// else. cyfr serves the chooser, the rail and the device's pages on
// loopback. main shows them in its one window: the rail, the list of CYFRs,
// in a view of its own at the window's left, and the content beside it,
// in a view that is replaced whenever what it shows changes owner. The
// chooser and the device's pages have a memory-only session, new at every
// lock. On macOS and Windows a person may sign in with the account's
// passkey instead, and is then kept signed in as a browser keeps them:
// each CYFR's pages open in a session kept on disk that is that CYFR's
// alone, by its address (policy.js homePartition). The CYFR's own sign-in
// page hops to its account service, which opens in the account window, in
// a session of that CYFR and account service alone, and the answer
// returns only to the content session that hopped.

import {spawn} from "node:child_process"
import os from "node:os"
import path from "node:path"

import {BaseWindow, BrowserWindow, Menu, WebContentsView, app, dialog, session, shell} from "electron"

import {lines, readFromCyfr, toCyfr} from "./process.js"
import {LOCALHOST_IS_IPV4, accountLoad, accountPartition, documentHeaders, grants, homePartition, printed, readHop, relyingParty,
  screenProject, unlistedSwitch} from "./policy.js"
import {ABORTED, DEPARTURE_MS, initial, kept, step} from "./states.js"

const READY_WITHIN_MS = 20_000
// How long the app's end waits for a clear or a flush under way.
const END_WAITS_MS = 5000
// The rail's width, at the window's left.
const RAIL = 72
// How many times a clear goes over a kept storage. A closing page's
// scripts write until its process has gone, also after a clear that began
// once its view was destroyed, and no header rule sees those writes: the
// second pass takes them, and no measured case had any left after it. A
// response to such a page sets nothing (policy.js documentHeaders).
const PASSES = 2

const SECURE = {
  sandbox: true,
  contextIsolation: true,
  nodeIntegration: false,
  nodeIntegrationInSubFrames: false,
  webSecurity: true,
  allowRunningInsecureContent: false,
  webviewTag: false,
  navigateOnDragDrop: false,
  spellcheck: false,
  safeDialogs: true,
  devTools: false
}

// All the app prints: no address with its fragment or query (printed).
const print = (line) => process.stderr.write(`${printed(line)}\n`)

// The two roads by which the engine prints an address whole, each closed
// before it has loaded one. It reports every failed load as a process
// warning, which Node's own printer writes as it is, whoever listens for
// the failure or handles the load's promise: that printer is replaced.
// And ELECTRON_ENABLE_LOGGING has it print each page's console with the
// page's address: the engine reads it again after main's first turn, so
// dropping it here drops it.
function ownOutput() {
  delete process.env.ELECTRON_ENABLE_LOGGING
  process.removeAllListeners("warning")
  process.on("warning", ({name, code, message, detail}) =>
    print(`CYFR: warning: ${code ? `[${code}] ` : ""}${name}: ${message}${detail ? `\n${detail}` : ""}`))
}

// Who began a navigation of `contents` (`asker`) and, where that was its
// top frame, the address of the document committed there (`by`): never one
// still loading, and never where a redirect goes.
function begun(event, contents) {
  const asker = askerOf(event, contents)
  return {asker, by: asker === "top" ? contents.mainFrame.url : ""}
}

// Who asked for a navigation of `contents`, as the engine reports its
// initiator: its top frame ("top"), a frame asking for itself or a frame
// inside it ("frame-inside"), a frame asking for any other
// ("frame-outside"), or none.
function askerOf(event, contents) {
  const i = event.initiator
  if (!i) return "none"
  const same = (a, b) => !!a && !!b && a.processId === b.processId && a.routingId === b.routingId
  if (same(i, contents.mainFrame)) return "top"
  for (let f = event.frame; f; f = f.parent) if (same(f, i)) return "frame-inside"
  return "frame-outside"
}

/**
 * Start the app around the cyfr at `cyfr` (an absolute path). `say`
 * reports what happens, one line a step, for whoever started the app.
 */
export function startApp({cyfr, accountRoad = process.platform === "darwin" || process.platform === "win32",
  touchIdGroup = "", say = (line) => print(`CYFR: ${line}`)}) {
  ownOutput()
  // Every switch but the few the app takes (policy.js SWITCHES) is
  // refused: the engine would open a debugging port, lift the sandbox or
  // web security, or trust any certificate for one.
  const unlisted = unlistedSwitch(process.argv.slice(1), process.platform)
  if (unlisted !== null) {
    say(`refused: --${unlisted} is not taken`)
    app.exit(2)
    return
  }
  // The box's screen (cmd/screen_app.go): one frameless, maximized window
  // with no menu, the six-word road's memory-only storage and no chooser,
  // shown by the screen shell cyfr runs in that project's folder.
  const screen = screenProject(app.commandLine.hasSwitch("screen-project"), app.commandLine.getSwitchValue("screen-project"),
    process.platform)
  if (screen === null) {
    say("refused: --screen-project names no project: give its absolute path, on Linux")
    app.exit(2)
    return
  }
  accountRoad = accountRoad && !screen
  app.enableSandbox()
  if (!app.requestSingleInstanceLock()) {
    say("another CYFR app runs for this account: it is shown instead")
    app.exit(0)
    return
  }

  const route = {
    proxy: app.commandLine.getSwitchValue("proxy-server"),
    resolver: app.commandLine.getSwitchValue("host-resolver-rules")
  }
  // Not a route of a CYFR's, so not part of the one main was started on.
  if (!route.resolver) app.commandLine.appendSwitch("host-resolver-rules", LOCALHOST_IS_IPV4)
  let state = initial(accountRoad, route, screen)
  let child = null
  let frame = null // the app's one window, holding the rail and the content
  let rail = null // the rail's view
  let content = null // the content's view
  let contentSession = null
  let contentKept = false // whether contentSession is a CYFR's kept one
  const children = new Set() // the content's confirmation windows
  let accountWindow = null
  let hop = null // {kind, request, from, timer}
  let generation = 0
  // Every page closed and not yet gone, and the sessions it used, which a
  // departure waits for (part).
  let closing = {pages: [], sessions: new Set()}
  // What is being forgotten or erased, one after the other, which quitting
  // waits for, so long (ending).
  let forgetting = Promise.resolve()
  const guarded = new Set() // the partitions given their rules

  // ---- the one place: every event goes through step ----

  function on(event) {
    const next = step(state, event)
    state = next.state
    for (const effect of next.do) carry(effect)
    return next
  }

  function carry(effect) {
    if (effect.say) say(effect.say)
    if (effect.close) closeContent()
    if (effect.part) part(effect.part.id)
    if (effect.deadline) {
      const {id} = effect.deadline
      setTimeout(() => on({type: "late", id}), DEPARTURE_MS).unref?.()
    }
    if (effect.restart) restartCyfr()
    if (effect.send) send(effect.send.type, effect.send.fields)
    if (effect.forget) {
      // A session in memory is never used again, cleared or not.
      const ses = contentSession
      const done = forgetting.then(() => contentKept ? clear(ses) : discard(ses))
      forgetting = done
      done.then((cleared) => on({type: "forgot", cleared}))
    }
    if (effect.erase) erase(effect.erase)
    if (effect.rail) openRail(effect.rail.url)
    if (effect.menu) rowMenu(effect.menu.home)
    if (effect.root) openHome(effect.root.home, effect.root.path)
    if (effect.chooser) openContent(chooserAddress(effect.chooser, effect), freshSession())
    if (effect.back) back(chooserAddress(effect.back))
    if (effect.relaunch) {
      say("starting again with the CYFR's route")
      const args = process.argv.slice(1).filter((a) => !/^--(proxy-server|host-resolver-rules)=/.test(a))
      if (effect.relaunch.proxy) args.push(`--proxy-server=${effect.relaunch.proxy}`, `--host-resolver-rules=${effect.relaunch.resolver}`)
      ending(() => {
        if (child && child.exitCode === null) child.kill()
        app.relaunch({args})
        app.exit(0)
      })
    }
    if (effect.end) {
      say(`cyfr ended: ${effect.end}`)
      if (child && child.exitCode === null) child.kill()
      closeFrame()
      message(`CYFR stopped: ${effect.end}. Quit the app and open it again.`)
    }
    if (effect.quit) {
      ending(() => {
        if (child && child.exitCode === null) {
          send("shutdown")
          child.stdin.end()
        }
        quitting = true
        app.quit()
      })
    }
    if (effect.hop) startHop(effect.hop.url, effect.hop.kind)
    if (effect.unhop) endHop()
    if (effect.deliver && content) {
      const {url} = effect.deliver
      // The engine settles the call after its landing when it succeeds;
      // it may reject before one, with no did-fail-load.
      const ended = () => on({type: "load-ended", url})
      content.webContents.loadURL(url).then(ended, ended)
      // That load's navigation has started by now, and been heard.
      on({type: "delivered"})
    }
    if (effect.reload && content) content.webContents.reload()
    if (effect.confirmation && content) openConfirmation(effect.confirmation.url)
    if (effect.pick) pickFolder(effect.pick.id)
    if (effect.external) shell.openExternal(effect.external.url).catch(() => say("the person's browser did not open"))
    if (effect.show && frame && !frame.isDestroyed()) {
      if (frame.isMinimized()) frame.restore()
      frame.focus()
    }
  }

  // The system's folder dialog over the window, for pick `id`: whatever it
  // gives, or a failure, is the answer, which step drops once the pick is
  // no longer the one outstanding.
  function pickFolder(id) {
    const answer = (path) => on({type: "picked", id, path})
    if (!content || !frame || frame.isDestroyed()) return setImmediate(() => answer(null))
    dialog.showOpenDialog(frame, {title: "Set up CYFR in", defaultPath: os.homedir(), buttonLabel: "Choose",
      properties: ["openDirectory", "createDirectory"]})
      .then(({canceled, filePaths}) => answer(canceled ? null : filePaths?.[0] ?? null), () => answer(null))
  }

  // A row's menu on the rail, drawn by main: Forget, confirmed by the
  // person in a dialog that names the CYFR's address and what it loses.
  // The context key or a long press opens it as a right-click does.
  function rowMenu(home) {
    if (!frame || frame.isDestroyed()) return
    const confirm = () => dialog.showMessageBox(frame, {
      type: "warning", title: "CYFR", message: `Forget the CYFR at ${home} on this computer?`,
      detail: "This computer's sign-in there, its approval and its admission are removed. Your account, the CYFR itself " +
        "and this computer's key stay as they are.",
      buttons: ["Forget", "Cancel"], cancelId: 1, defaultId: 1, noLink: true
    }).then(({response}) => {
      if (response === 0) on({type: "forget-confirmed", home})
    }, () => {})
    Menu.buildFromTemplate([{label: "Forget this CYFR on this computer", click: confirm}]).popup({window: frame})
  }

  // The app's one way out, `end`. It waits END_WAITS_MS at the most for
  // what is being forgotten or erased, and never runs in the turn that
  // asked for it: where the system began the quit (SIGTERM, Cmd+Q, a
  // logout) the engine runs the microtasks before its before-quit returns,
  // and a quit made there re-enters the one under way, which then never
  // ends. An erase the bound cuts off is answered by nobody, so cyfr asks
  // for it again at its next start.
  function ending(end) {
    let timer
    const bound = new Promise((resolve) => { timer = setTimeout(resolve, END_WAITS_MS) })
    const go = () => {
      clearTimeout(timer)
      setImmediate(end)
    }
    Promise.race([forgetting, bound]).then(go, go)
  }

  // The chooser's address: cyfr's own, with the road this app offers,
  // which is main's alone to say, what main has to tell, and where it goes
  // on: connecting to a CYFR the rail selected, or setting up.
  const chooserAddress = (notices, {connect = "", way = ""} = {}) => screen ? state.readyURL
    : state.readyURL + (accountRoad ? "&road=passkey" : "") + (notices.length ? `&notice=${notices.join(",")}` : "") +
      (connect ? `&connect=${encodeURIComponent(connect)}` : "") + (way ? `&way=${way}` : "")

  const discard = (ses) => Promise.resolve(ses?.clearStorageData()).then(() => true, () => true)

  /**
   * Whether all a kept storage holds is gone, on disk too; `say` hears why
   * a clear failed in what the app itself knows: the name of the call that
   * threw, never the text of its error, or each cookie left by its name and
   * site, never its value.
   */
  async function clear(ses) {
    let call
    let left
    try {
      for (let pass = 0; pass < PASSES; pass++) {
        call = "clearStorageData"
        await ses.clearStorageData()
        call = "clearCache"
        await ses.clearCache()
        call = "flushStore"
        await ses.cookies.flushStore()
        // The engine's promise does not say that it deleted: the cookies do.
        call = "cookies.get"
        left = await ses.cookies.get({})
        if (left.length === 0) return true
      }
      say(`not cleared: left ${left.map((c) => `${c.name} at ${c.domain}`).join(", ")}`)
    } catch {
      say(`not cleared: ${call} threw`)
    }
    return false
  }

  // cyfr's erase: the store it names emptied, after whatever is being
  // forgotten, and erased told. Off the passkey road nothing is kept on
  // disk, so there is nothing to erase.
  function erase({id, home, account}) {
    const done = forgetting.then(() => {
      if (!accountRoad) return true
      return clear(account ? kept_(accountPartition(home, account), "account") : kept_(homePartition(home)))
    })
    forgetting = done.then(() => {}, () => {})
    done.then((ok) => send("erased", {id, ok}), () => send("erased", {id, ok: false}))
  }

  // ---- the window owner: every window and view the app has is made here ----

  function guard(ses, kind) {
    ses.webRequest.onHeadersReceived((details, callback) => {
      const page = details.webContents
      callback({responseHeaders: documentHeaders(kind, details.resourceType, details.responseHeaders ?? {},
        {pageGone: !page || page.isDestroyed()})})
    })
    ses.setPermissionRequestHandler((_wc, permission, callback) => callback(grants(permission)))
    ses.setPermissionCheckHandler((_wc, permission) => grants(permission))
    ses.setDevicePermissionHandler(() => false)
    ses.setDisplayMediaRequestHandler((_request, callback) => callback({}))
  }

  // A kept storage, given its rules before anything loads in it, once.
  // The engine writes cookies within half a minute, which an app that is
  // killed does not have.
  function kept_(partition, kind = "content") {
    const ses = session.fromPartition(partition)
    if (!guarded.has(partition)) {
      guarded.add(partition)
      guard(ses, kind)
      const {cookies} = ses
      cookies.on("changed", () => cookies.flushStore().catch(() => {}))
      if (kind === "account") ses.on("select-webauthn-account", chooseAccount)
    }
    return ses
  }

  // A content session of memory alone, new for each content opened: the
  // chooser's, the device's pages', the six-word road's.
  function freshSession() {
    const ses = session.fromPartition(`cyfr-${process.pid}-${++generation}`)
    guard(ses, "content")
    return ses
  }

  // The app's one window, made once: the rail at its left (none on the
  // box's screen, in this part) and the content beside it, both laid out
  // again as it is resized, the on-screen keyboard's too.
  function ensureFrame() {
    if (frame && !frame.isDestroyed()) return frame
    frame = new BaseWindow({width: 1280, height: 860, show: false, title: "CYFR", autoHideMenuBar: true, backgroundColor: "#071013",
      ...(screen ? {frame: false} : {})})
    frame.on("resize", layout)
    frame.on("closed", () => {
      frame = null
      if (!closingFrame) on({type: "quit"})
    })
    if (screen) frame.maximize()
    frame.show()
    return frame
  }
  let closingFrame = false
  function closeFrame() {
    closingFrame = true
    const f = frame
    frame = null
    if (rail && !rail.webContents.isDestroyed()) rail.webContents.close()
    rail = null
    if (f && !f.isDestroyed()) f.destroy()
  }

  // Where the content is: the window's content area beside the rail.
  function contentRect() {
    const {width, height} = frame.getContentBounds()
    const left = rail ? RAIL : 0
    return {x: left, y: 0, width: Math.max(0, width - left), height}
  }
  function layout() {
    if (!frame || frame.isDestroyed()) return
    const {height} = frame.getContentBounds()
    if (rail) rail.setBounds({x: 0, y: 0, width: RAIL, height})
    if (content) content.setBounds(contentRect())
  }
  // A window over the content: centred in its rectangle, on the screen.
  function overContent(width, height) {
    if (!frame || frame.isDestroyed()) return {width, height}
    const at = frame.getContentBounds()
    const r = contentRect()
    const w = Math.min(width, r.width), h = Math.min(height, r.height)
    return {width: w, height: h, x: Math.round(at.x + r.x + (r.width - w) / 2), y: Math.round(at.y + r.y + (r.height - h) / 2)}
  }

  // Every view and window the app makes has two ends for its page, which
  // endsOf names (ends): `failed`, a load of its top frame that failed,
  // with the engine's code and the address, and `lost`, its page's process
  // gone. A confirmation window the engine made for a page gets the same
  // two (confirmationEnds).
  function window(ses, options, endsOf) {
    const w = new BrowserWindow({
      width: 1280, height: 860, show: false, title: "CYFR", autoHideMenuBar: true, ...(screen ? {frame: false} : {}), ...options,
      webPreferences: {...SECURE, session: ses}
    })
    w.once("ready-to-show", () => w.show())
    w.webContents.on("will-attach-webview", (event) => event.preventDefault())
    ends(w.webContents, endsOf(w))
    return w
  }

  // The engine takes no load from inside its report of a loss, nor a
  // window's close from inside its report of a failed load (closingLoad).
  function ends(contents, {failed, lost}) {
    contents.on("did-fail-load", (_event, code, _why, url, isMainFrame) => {
      if (isMainFrame) failed(code, url)
    })
    contents.on("render-process-gone", () => setImmediate(lost))
  }
  function closingLoad(end) {
    return (code) => {
      if (code !== ABORTED) setImmediate(end)
    }
  }

  // A confirmation window's two ends are one: its page failed (a refused
  // or replaced load, ABORTED, is none) or lost, it is closed, and main
  // hears it: on the screen that locks; on a desktop the person is back on
  // the CYFR's page.
  function confirmationEnds(w) {
    const end = () => {
      if (w.isDestroyed()) return
      w.destroy()
      on({type: "lost", window: "child"})
    }
    return {failed: closingLoad(end), lost: end}
  }

  // A view or window of the content's own (`which`: the content or a
  // confirmation window) asks step about each of its loads; so does the
  // rail's ("rail"). A confirmation window's first load is of the address
  // the window handler opened it for (`first`), which that handler
  // decided: the engine names some frame of the opener as its initiator,
  // not reliably the top one.
  function confine(contents, which, first = null) {
    const ask = (event, redirect = false) => {
      const opening = first !== null && event.isMainFrame && event.url === first
      if (event.isMainFrame) first = null
      const {asker, by} = begun(event, contents)
      const decided = on({type: "navigate", window: which, url: event.url, target: event.isMainFrame ? "top" : "frame",
        asker: opening ? "top" : asker, by, showing: contents.getURL(), redirect})
      if (!decided.allow) event.preventDefault()
    }
    contents.on("will-navigate", (event) => ask(event))
    contents.on("will-redirect", (event) => ask(event, true))
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame) ask(event)
    })
    contents.on("will-attach-webview", (event) => event.preventDefault())
    contents.setWindowOpenHandler(() => ({action: "deny"}))
  }

  // The rail's view, in the app's own memory session, which holds nothing
  // but the rail: loaded again at each ready, whose read token is new.
  function openRail(url) {
    if (screen) return
    ensureFrame()
    if (!rail) {
      const ses = session.fromPartition(`cyfr-app-${process.pid}`)
      guard(ses, "content")
      rail = new WebContentsView({webPreferences: {...SECURE, session: ses}})
      confine(rail.webContents, "rail")
      // A lost rail is shown again; one that failed to load is tried again
      // at the next ready.
      ends(rail.webContents, {failed: () => {}, lost: () => rail?.webContents.reload()})
      frame.contentView.addChildView(rail)
      layout()
    }
    rail.webContents.loadURL(url).catch(() => {})
  }

  // The content's view, at `address` in session `ses`: what showed before
  // is closed already (close), or is closed now.
  function openContent(address, ses, kept = false) {
    ensureFrame()
    if (content) dropContent()
    contentSession = ses
    contentKept = kept
    const v = new WebContentsView({webPreferences: {...SECURE, session: ses}})
    const heard = (event) => {
      if (content === v) on(event)
    }
    content = v
    const contents = v.webContents
    ends(contents, {failed: (code, url) => heard({type: "load-failed", code, url}), lost: () => heard({type: "lost"})})
    confine(contents, "content")
    // The window handler opens only the device's two loopback confirmation
    // routes and the confirmation hop (step's open-window). Electron does
    // not say which frame asked; Prism's own frame rules refuse every frame
    // it serves a window and the top frame (Compendium.Tincture.Rules), and
    // the asker check refuses a frame's navigation of the top frame.
    let opening = null
    contents.setWindowOpenHandler(({url}) => {
      if (on({type: "open-window", url}).open !== "child") return {action: "deny"}
      opening = url
      return {action: "allow", overrideBrowserWindowOptions: {
        ...overContent(520, 640), parent: frame, autoHideMenuBar: true, webPreferences: {...SECURE, session: ses}
      }}
    })
    contents.on("did-create-window", (opened) => {
      const first = opening
      opening = null
      children.add(opened)
      opened.on("closed", () => children.delete(opened))
      ends(opened.webContents, confirmationEnds(opened))
      confine(opened.webContents, "child", first)
    })
    contents.on("did-start-navigation", (details) => {
      if (details.isMainFrame) heard({type: "started", url: details.url, sameDocument: details.isSameDocument})
    })
    contents.on("did-navigate", () => heard({type: "committed"}))
    contents.on("did-navigate-in-page", (_event, url, isMainFrame) => {
      if (isMainFrame) heard({type: "landed", url})
    })
    frame.contentView.addChildView(v)
    layout()
    contents.loadURL(address).catch(() => {})
  }

  // The CYFR at `home`, opened at `path` in its own kept storage, which
  // is made only now that cyfr committed it.
  function openHome(home, path) {
    openContent(home + path, kept_(homePartition(home)), true)
  }

  // The chooser shown in place of a CYFR's page that did not load: in the
  // content as it stands where that is memory's, and otherwise in a view
  // of its own, so no kept storage holds the chooser. Either only while
  // that content still stands: a lock or a departure in between closed it.
  function back(address) {
    const v = content
    const memory = !contentKept
    setImmediate(() => {
      if (!v || content !== v) return
      if (memory) v.webContents.loadURL(address).catch(() => {})
      else openContent(address, freshSession())
    })
  }

  function openAccount(address) {
    const {home, account} = kept(state)
    const ses = kept_(accountPartition(home, account), "account")
    // Its page failed or lost, the hop ends, which closes it.
    const w = window(ses, {...overContent(560, 760), parent: frame ?? undefined}, (w) => {
      const gone = () => {
        if (accountWindow === w) endHop()
      }
      return {failed: closingLoad(gone), lost: gone}
    })
    accountWindow = w
    const contents = w.webContents
    const ask = (event, redirect = false) => {
      const decided = on({type: "account-navigate", window: "account", url: event.url, target: event.isMainFrame ? "top" : "frame",
        ...begun(event, contents), redirect,
        kind: hop && content && hop.from === content ? hop.kind : null})
      if (!decided.allow) event.preventDefault()
    }
    contents.on("will-navigate", (event) => ask(event))
    contents.on("will-redirect", (event) => ask(event, true))
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame) ask(event)
    })
    contents.setWindowOpenHandler(() => ({action: "deny"}))
    w.on("closed", () => {
      if (accountWindow === w) {
        accountWindow = null
        endHop()
      }
    })
    w.loadURL(address)
  }

  function message(text) {
    const ses = session.fromPartition(`cyfr-message-${process.pid}`)
    guard(ses, "content")
    // Its page failed or lost, the app ends as at the window's close.
    const quit = () => on({type: "quit"})
    const w = window(ses, {width: 560, height: 320}, () => ({failed: closingLoad(quit), lost: quit}))
    const block = (event) => event.preventDefault()
    w.webContents.on("will-navigate", block)
    w.webContents.on("will-redirect", block)
    w.webContents.setWindowOpenHandler(() => ({action: "deny"}))
    w.on("closed", () => on({type: "quit"}))
    const page = "<!doctype html><meta charset=utf-8><meta http-equiv=Content-Security-Policy content=\"default-src 'none'; style-src 'unsafe-inline'\">" +
      "<title>CYFR</title><style>body{background:#0b1418;color:#e8f1f2;font:1.1rem system-ui,sans-serif;margin:2rem}</style>" +
      `<h1>CYFR</h1><p>${text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)}</p>`
    w.loadURL("data:text/html;charset=utf-8," + encodeURIComponent(page))
  }

  // A page closed, and the session it used, for the next departure to
  // wait on.
  function closed(contents) {
    if (!contents || contents.isDestroyed()) return
    closing.sessions.add(contents.session)
    closing.pages.push(new Promise((resolve) => contents.once("destroyed", resolve)))
  }

  // The content's view taken from the window and destroyed.
  function dropContent() {
    const v = content
    content = null
    if (!v) return
    closed(v.webContents)
    frame?.contentView.removeChildView(v)
    if (!v.webContents.isDestroyed()) v.webContents.close()
  }

  // Close the content at once: the ceremony cancelled and every content
  // view and confirmation window destroyed, whatever a page does.
  function closeContent() {
    endHop()
    const windows = [...children].filter((w) => !w.isDestroyed())
    children.clear()
    for (const w of windows) {
      closed(w.webContents)
      w.destroy()
    }
    dropContent()
  }

  // A departure's teardown: every page closed has gone, and the
  // connections of the sessions they used, live sockets among them, are
  // closed; then parted, with the departure's id.
  function part(id) {
    const {pages, sessions} = closing
    closing = {pages: [], sessions: new Set()}
    Promise.all(pages)
      .then(() => Promise.all([...sessions].map((ses) => ses.closeAllConnections())))
      .then(() => on({type: "parted", id}), () => {})
  }

  // ---- the account road: a hop, its window, its return ----

  function startHop(url, kind) {
    const request = readHop(url, kept(state), kind)
    if (!request || hop || !content) return
    hop = {kind, request, from: content, timer: setTimeout(endHop, Math.max(0, request.expires_at - Date.now()))}
    openAccount(url)
  }

  function openConfirmation(url) {
    const w = window(contentSession, {...overContent(520, 640), parent: frame, show: true}, confirmationEnds)
    children.add(w)
    w.on("closed", () => children.delete(w))
    confine(w.webContents, "child")
    w.loadURL(url)
  }

  function endHop() {
    if (!hop) return
    clearTimeout(hop.timer)
    hop = null
    const w = accountWindow
    accountWindow = null
    if (w && !w.isDestroyed()) {
      closed(w.webContents)
      w.destroy()
    }
  }

  function chooseAccount(event, details, callback) {
    event.preventDefault()
    let answered = false
    const answer = (id) => {
      if (answered) return
      answered = true
      callback(id ?? null)
    }
    const frame = details.frame
    const top = (f) => accountWindow && !accountWindow.isDestroyed() && f &&
      f.processId === accountWindow.webContents.mainFrame.processId &&
      f.routingId === accountWindow.webContents.mainFrame.routingId &&
      accountLoad(f.url, kept(state)) === "allow"
    const current = hop && top(frame) && details.relyingPartyId === relyingParty(kept(state).account) &&
      details.accounts.length > 0
    if (!current) return answer(null)
    const names = details.accounts.map((a) => a.displayName || a.name || "A passkey")
    dialog.showMessageBox(accountWindow, {
      type: "question", title: "CYFR", message: "Sign in as",
      buttons: [...names, "Cancel"], cancelId: names.length, defaultId: 0, noLink: true
    }).then(({response}) => {
      answer(hop && top(frame) && response < names.length ? details.accounts[response].credentialId : null)
    }, () => answer(null))
  }

  // ---- cyfr ----

  let send = () => {}
  let readiness = null
  let quitting = false

  // A fresh cyfr in place of one that did not answer a departure in time:
  // what it says from here is the old one's no more.
  function restartCyfr() {
    const old = child
    child = null
    clearTimeout(readiness)
    if (old && old.exitCode === null) old.kill()
    startCyfr()
  }

  function startCyfr() {
    const mine = screen
      ? spawn(cyfr, ["screen", "shell"], {cwd: screen, stdio: ["pipe", "pipe", "pipe"]})
      : spawn(cyfr, ["desktop-serve"], {stdio: ["pipe", "pipe", "pipe"], windowsHide: true})
    child = mine
    const heard = (event) => {
      if (child === mine) on(event)
    }
    send = (type, fields) => {
      if (child === mine && mine.stdin.writable) mine.stdin.write(toCyfr(type, fields))
    }
    readiness = setTimeout(() => heard({type: "gone", why: "it did not get ready"}), READY_WITHIN_MS)
    mine.stdout.setEncoding("utf8")
    const feed = lines((line) => {
      let m
      try {
        m = readFromCyfr(line)
      } catch (e) {
        return heard({type: "gone", why: `it sent ${e.reason === "size" ? "a line too long" : "something that is not its message"}`})
      }
      if (m.type === "ready" && child === mine) clearTimeout(readiness)
      heard({type: m.type, url: m.url, home: m.home, message: m})
    })
    mine.stdout.on("data", (chunk) => {
      try {
        feed(chunk)
      } catch {
        heard({type: "gone", why: "it sent a line too long"})
      }
    })
    // cyfr's own refusal, its "Error: " line, says why it ended.
    let last = ""
    let pending = ""
    mine.stderr.setEncoding("utf8")
    mine.stderr.on("data", (chunk) => {
      pending += chunk
      const whole = pending.split("\n")
      pending = whole.pop()
      for (const line of whole) {
        print(line)
        if (line.startsWith("Error: ")) last = line
      }
    })
    mine.stderr.on("end", () => {
      if (pending) print(pending)
      pending = ""
    })
    mine.on("error", (e) => heard({type: "gone", why: `it could not start (${e.message})`}))
    mine.on("exit", (code, signal) => {
      if (!quitting) heard({type: "gone", why: last.replace(/^Error: /, "") || `it exited (${signal ?? code})`})
    })
  }

  // ---- the app ----

  app.on("second-instance", () => on({type: "second-instance"}))
  app.on("web-contents-created", (_event, contents) => {
    contents.on("will-attach-webview", (event) => event.preventDefault())
  })
  // A lock or cyfr's end closes every view before it opens the next, which
  // must not quit; closing the app's window quits (ensureFrame).
  app.on("window-all-closed", () => {})
  app.on("before-quit", (event) => {
    if (quitting) return
    event.preventDefault()
    on({type: "quit"})
  })

  app.whenReady().then(() => {
    // No menu: its accelerators would close the window or cover the
    // on-screen keyboard (full screen).
    if (screen) Menu.setApplicationMenu(null)
    if (touchIdGroup && process.platform === "darwin") app.configureWebAuthn({touchID: {keychainAccessGroup: touchIdGroup}})
    startCyfr()
  })

}
