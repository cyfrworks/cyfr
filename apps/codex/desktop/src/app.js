// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The CYFR app's main process: it starts cyfr desktop-serve, owns every
// window the app has, and holds each to its rules (policy.js).
//
// cyfr serves the chooser and the device's pages on loopback and selects
// one CYFR a run; main shows them in a content window whose session is
// memory-only and new at every unlock, and, once it keeps to the CYFR cyfr
// names in home, says home-ready. On macOS and Windows a person may sign in
// with the account's passkey instead: the CYFR's own sign-in page hops to
// its account service, which opens in the one account window, and the
// answer returns only to the content session that hopped. Any lock, the
// computer's, sleep, the device's own, a window or a renderer lost, closes
// the content first, signs the CYFR's session out where the passkey opened
// one, and shows the chooser again; cyfr's exit, or a message from it that
// is not one, closes the content for good.

import {spawn} from "node:child_process"

import {BrowserWindow, app, dialog, powerMonitor, session} from "electron"

import {lines, readFromCyfr, toCyfr} from "./process.js"
import {
  LOOPBACK, accountLoad, contentLoad, contentOpen, documentHeaders, grants, homeMessage, readHop, relyingParty, retired
} from "./policy.js"

const READY_WITHIN_MS = 20_000
const ACCOUNT_PARTITION = "persist:cyfr-account"

// The switches that open a debugging port, run main's code otherwise, or
// lift the renderers' sandbox or web security: the app refuses to start
// under any of them.
const DEBUGGING = ["remote-debugging-port", "remote-debugging-pipe", "inspect", "inspect-brk", "inspect-port", "js-flags",
  "no-sandbox", "disable-web-security", "disable-site-isolation-trials"]

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

/**
 * Start the app around the cyfr at `cyfr` (an absolute path). `say`
 * reports what happens, one line a step, for whoever started the app.
 */
export function startApp({cyfr, accountRoad = process.platform === "darwin" || process.platform === "win32",
  touchIdGroup = "", say = (line) => process.stderr.write(`CYFR: ${line}\n`)}) {
  for (const s of DEBUGGING) {
    if (app.commandLine.hasSwitch(s)) {
      say(`refused: --${s} is not taken`)
      app.exit(2)
      return
    }
  }
  app.enableSandbox()
  if (!app.requestSingleInstanceLock()) {
    say("another CYFR app runs for this account: it is shown instead")
    app.exit(0)
    return
  }

  const state = {home: "", account: "", accountRoad, readyURL: ""}
  let child = null
  let send = () => {}
  let content = null // the one content window
  const children = new Set() // its confirmation windows
  let accountWindow = null
  let hop = null // {kind, request, from, timer}
  let generation = 0
  let ended = false
  let quitting = false

  // ---- the window owner: every window the app has is made here ----

  function contentSession() {
    generation++
    const ses = session.fromPartition(`cyfr-${process.pid}-${generation}`)
    guard(ses, "content")
    return ses
  }

  function guard(ses, kind) {
    ses.webRequest.onHeadersReceived((details, callback) => {
      callback({responseHeaders: documentHeaders(kind, details.resourceType, details.responseHeaders ?? {})})
    })
    ses.setPermissionRequestHandler((_wc, permission, callback) => callback(grants(permission)))
    ses.setPermissionCheckHandler((_wc, permission) => grants(permission))
    ses.setDevicePermissionHandler(() => false)
    ses.setDisplayMediaRequestHandler((_request, callback) => callback({}))
  }

  function window(ses, options = {}) {
    const w = new BrowserWindow({
      width: 1280, height: 860, show: false, title: "CYFR", autoHideMenuBar: true, ...options,
      webPreferences: {...SECURE, session: ses}
    })
    w.once("ready-to-show", () => w.show())
    w.webContents.on("will-attach-webview", (event) => event.preventDefault())
    return w
  }

  function openContent(address) {
    const ses = contentSession()
    const w = window(ses)
    content = w
    const contents = w.webContents
    const load = (event, url) => {
      const where = contentLoad(url, state)
      if (where === "allow") return
      event.preventDefault()
      if (where === "hop") startHop(url, "sign-in", w)
      if (where === "company") lock("company")
    }
    contents.on("will-navigate", load)
    contents.on("will-redirect", load)
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame && contentLoad(event.url, state) !== "allow" && !/^(about|blob|data):/.test(event.url)) {
        event.preventDefault()
      }
    })
    contents.setWindowOpenHandler(({url}) => {
      const what = contentOpen(url, state)
      if (what === "hop") startHop(url, "confirmation", w)
      if (what !== "child") return {action: "deny"}
      return {action: "allow", overrideBrowserWindowOptions: {
        width: 520, height: 640, parent: w, autoHideMenuBar: true, webPreferences: {...SECURE, session: ses}
      }}
    })
    contents.on("did-create-window", (child) => {
      children.add(child)
      child.on("closed", () => children.delete(child))
      child.webContents.setWindowOpenHandler(() => ({action: "deny"}))
      const confine = (event, url) => {
        if (contentLoad(url, state) !== "allow") event.preventDefault()
      }
      child.webContents.on("will-navigate", confine)
      child.webContents.on("will-redirect", confine)
      child.webContents.on("render-process-gone", () => lock("a window's page stopped"))
    })
    contents.on("render-process-gone", () => lock("the page stopped"))
    w.on("closed", () => {
      if (content === w) {
        content = null
        if (!quitting && !ended) app.quit()
      }
    })
    w.loadURL(address)
  }

  function openAccount(address) {
    const ses = session.fromPartition(ACCOUNT_PARTITION)
    const w = window(ses, {width: 560, height: 760, parent: content ?? undefined})
    accountWindow = w
    const contents = w.webContents
    const load = (event, url) => {
      const where = accountLoad(url, state)
      if (where === "allow") return
      event.preventDefault()
      if (where === "return") finishHop(url)
      else endHop()
    }
    contents.on("will-navigate", load)
    contents.on("will-redirect", load)
    contents.on("did-start-navigation", (details) => {
      if (details.isMainFrame && accountLoad(details.url, state) === "block") endHop()
    })
    contents.setWindowOpenHandler(() => ({action: "deny"}))
    contents.on("render-process-gone", () => lock("the sign-in page stopped"))
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
    const w = window(ses, {width: 560, height: 320})
    const block = (event) => event.preventDefault()
    w.webContents.on("will-navigate", block)
    w.webContents.on("will-redirect", block)
    w.webContents.setWindowOpenHandler(() => ({action: "deny"}))
    w.on("closed", () => app.quit())
    const page = "<!doctype html><meta charset=utf-8><meta http-equiv=Content-Security-Policy content=\"default-src 'none'; style-src 'unsafe-inline'\">" +
      "<title>CYFR</title><style>body{background:#0b1418;color:#e8f1f2;font:1.1rem system-ui,sans-serif;margin:2rem}</style>" +
      `<h1>CYFR</h1><p>${text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)}</p>`
    w.loadURL("data:text/html;charset=utf-8," + encodeURIComponent(page))
  }

  // ---- the account road: a hop, its window, its return ----

  function startHop(url, kind, from) {
    const request = readHop(url, state)
    if (!request || hop) return
    hop = {kind, request, from, timer: setTimeout(endHop, Math.max(0, request.expires_at - Date.now()))}
    openAccount(url)
  }

  function finishHop(url) {
    const h = hop
    endHop()
    if (!h || h.from !== content || !content) return
    if (h.kind === "sign-in") {
      content.loadURL(url)
      return
    }
    const w = new BrowserWindow({
      width: 520, height: 640, parent: content, autoHideMenuBar: true, show: true,
      webPreferences: {...SECURE, session: content.webContents.session}
    })
    children.add(w)
    w.on("closed", () => children.delete(w))
    const confine = (event, next) => {
      if (contentLoad(next, state) !== "allow") event.preventDefault()
    }
    w.webContents.on("will-navigate", confine)
    w.webContents.on("will-redirect", confine)
    w.webContents.setWindowOpenHandler(() => ({action: "deny"}))
    w.loadURL(url)
  }

  function endHop() {
    if (!hop) return
    clearTimeout(hop.timer)
    hop = null
    const w = accountWindow
    accountWindow = null
    if (w && !w.isDestroyed()) w.destroy()
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
      accountLoad(f.url, state) === "allow"
    const current = hop && top(frame) && details.relyingPartyId === relyingParty(state.account) && details.accounts.length > 0
    if (!current) return answer(null)
    const names = details.accounts.map((a) => a.displayName || a.name || "A passkey")
    dialog.showMessageBox(accountWindow, {
      type: "question", title: "CYFR", message: "Sign in as",
      buttons: [...names, "Cancel"], cancelId: names.length, defaultId: 0, noLink: true
    }).then(({response}) => {
      answer(hop && top(frame) && response < names.length ? details.accounts[response].credentialId : null)
    }, () => answer(null))
  }

  // ---- lock: close the content, sign out, show the chooser again ----

  async function signOut(w) {
    if (!state.accountRoad || !state.home || !w || w.isDestroyed()) return "none"
    const url = w.webContents.getURL()
    if (!url.startsWith(state.home + "/")) return "none"
    const ses = w.webContents.session
    let token = ""
    try {
      token = await Promise.race([
        w.webContents.executeJavaScript("document.querySelector('meta[name=\"csrf-token\"]')?.content ?? ''", false),
        new Promise((resolve) => setTimeout(() => resolve(""), 1000))
      ])
    } catch {
      token = ""
    }
    return {ses, token}
  }

  async function retire({ses, token}) {
    try {
      if (!token) return false
      const answer = await ses.fetch(state.home + "/auth/logout", {
        method: "POST", redirect: "manual", credentials: "include",
        headers: {"content-type": "application/x-www-form-urlencoded"},
        body: "_csrf_token=" + encodeURIComponent(token),
        signal: AbortSignal.timeout(10_000)
      })
      return retired(answer.status, answer.headers)
    } catch {
      return false
    } finally {
      await ses.clearStorageData().catch(() => {})
    }
  }

  let locking = null

  function closeContent() {
    endHop()
    const windows = [...children, content].filter((w) => w && !w.isDestroyed())
    children.clear()
    content = null
    for (const w of windows) w.destroy()
  }

  async function settle(notice) {
    const w = content
    const out = await signOut(w)
    closeContent()
    let note = notice
    if (out !== "none" && !(await retire(out))) note = note || "unconfirmed"
    if (!ended) openContent(state.readyURL + (note ? `&notice=${note}` : ""))
  }

  // A lock of the app: close the content and sign out here, and lock cyfr,
  // whose locked brings the chooser back. Without cyfr, the content stays
  // closed.
  function lock(why) {
    if (ended || !state.readyURL) return
    say(`locked: ${why}`)
    if (!locking) {
      locking = settle(why === "company" ? "company" : "").finally(() => { locking = null })
    }
    send("lock")
  }

  function locked() {
    if (!locking) locking = settle("").finally(() => { locking = null })
  }

  // ---- cyfr ----

  function end(why) {
    if (ended) return
    ended = true
    say(`cyfr ended: ${why}`)
    closeContent()
    if (child && child.exitCode === null) child.kill()
    if (!quitting) message(`CYFR stopped: ${why}. Quit the app and open it again.`)
  }

  function heard(m) {
    switch (m.type) {
      case "ready":
        if (state.readyURL || !m.url.startsWith(LOOPBACK + "/bootstrap/#token=")) return end("its first page was not the chooser")
        clearTimeout(readiness)
        state.readyURL = m.url
        say("ready")
        openContent(m.url)
        return
      case "home": {
        if (!state.readyURL || state.home || !homeMessage(m)) return end("it named a CYFR this app does not open")
        const proxy = m.proxy ?? "", resolver = m.resolver ?? ""
        if (proxy !== app.commandLine.getSwitchValue("proxy-server") ||
            resolver !== app.commandLine.getSwitchValue("host-resolver-rules")) {
          say("starting again with the CYFR's route")
          const args = process.argv.slice(1).filter((a) => !/^--(proxy-server|host-resolver-rules)=/.test(a))
          if (proxy) args.push(`--proxy-server=${proxy}`, `--host-resolver-rules=${resolver}`)
          app.relaunch({args})
          quitting = true
          app.exit(0)
          return
        }
        state.home = m.home
        state.account = m.account
        say(`home: ${m.home}`)
        send("home-ready", {home: m.home})
        return
      }
      case "locked":
        locked()
        return
      case "pick-folder":
        send("folder-picked", {id: m.id, path: null})
        return
    }
  }

  let readiness = null

  function startCyfr() {
    child = spawn(cyfr, ["desktop-serve"], {stdio: ["pipe", "pipe", "pipe"], windowsHide: true})
    send = (type, fields) => {
      if (child.stdin.writable) child.stdin.write(toCyfr(type, fields))
    }
    readiness = setTimeout(() => end("it did not get ready"), READY_WITHIN_MS)
    child.stdout.setEncoding("utf8")
    const feed = lines((line) => {
      let m
      try {
        m = readFromCyfr(line)
      } catch (e) {
        return end(`it sent ${e.reason === "size" ? "a line too long" : "something that is not its message"}`)
      }
      heard(m)
    })
    child.stdout.on("data", (chunk) => {
      try {
        feed(chunk)
      } catch {
        end("it sent a line too long")
      }
    })
    // cyfr's own refusal, its "Error: " line, says why it ended.
    let last = ""
    let held = ""
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk) => {
      process.stderr.write(chunk)
      held += chunk
      const whole = held.split("\n")
      held = whole.pop()
      for (const line of whole) if (line.startsWith("Error: ")) last = line
    })
    child.on("error", (e) => end(`it could not start (${e.message})`))
    child.on("exit", (code, signal) => end(last.replace(/^Error: /, "") || `it exited (${signal ?? code})`))
  }

  // ---- the app ----

  app.on("second-instance", () => {
    if (content && !content.isDestroyed()) {
      if (content.isMinimized()) content.restore()
      content.focus()
    }
  })
  app.on("web-contents-created", (_event, contents) => {
    contents.on("will-attach-webview", (event) => event.preventDefault())
  })
  // Closing the content window quits (openContent); a lock or cyfr's end
  // closes every window before it opens the next, which must not.
  app.on("window-all-closed", () => {})
  app.on("before-quit", (event) => {
    if (quitting || ended) return
    event.preventDefault()
    quitting = true
    const out = signOut(content)
    out.then(async (o) => {
      closeContent()
      if (o !== "none") await retire(o)
      if (child && child.exitCode === null) {
        send("shutdown")
        child.stdin.end()
      }
      app.quit()
    })
  })

  app.whenReady().then(() => {
    const account = session.fromPartition(ACCOUNT_PARTITION)
    guard(account, "account")
    account.on("select-webauthn-account", chooseAccount)
    if (touchIdGroup && process.platform === "darwin") app.configureWebAuthn({touchID: {keychainAccessGroup: touchIdGroup}})
    for (const signal of ["lock-screen", "suspend"]) powerMonitor.on(signal, () => lock(signal))
    startCyfr()
  })
}
