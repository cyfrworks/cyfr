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

import {lines, readFromCyfr, selection, toCyfr} from "./process.js"
import {
  LOOPBACK, accountLoad, contentNavigation, contentOpen, documentHeaders, grants, homeMessage, readHop, relyingParty,
  retired, unlistedSwitch
} from "./policy.js"

const READY_WITHIN_MS = 20_000
const UNCONFIRMED = "The CYFR did not confirm that it signed this computer out. That sign-in ends when it expires, or when you sign it out under Settings, Keys on your account."
const ACCOUNT_PARTITION = "persist:cyfr-account"

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
  // Every switch but the few the app takes (policy.js SWITCHES) is
  // refused: the engine would open a debugging port, lift the sandbox or
  // web security, or trust any certificate for one.
  const unlisted = unlistedSwitch(process.argv.slice(1), process.platform)
  if (unlisted !== null) {
    say(`refused: --${unlisted} is not taken`)
    app.exit(2)
    return
  }
  app.enableSandbox()
  if (!app.requestSingleInstanceLock()) {
    say("another CYFR app runs for this account: it is shown instead")
    app.exit(0)
    return
  }

  // The CYFR main keeps to is cyfr's proposal until cyfr says it opened
  // it (process.js selection); the policies read it through `state`.
  const chosen = selection()
  const state = {get home() { return chosen.home }, get account() { return chosen.account }, accountRoad, readyURL: ""}
  let child = null
  let send = () => {}
  let content = null // the one content window
  const children = new Set() // its confirmation windows
  let accountWindow = null
  let hop = null // {kind, request, from, timer}
  // What signing the content's session out needs, held apart from its
  // window so that closing the window at once loses nothing: the session
  // and the forgery token of the CYFR's last page, where the passkey road
  // opened a session.
  let held = null
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
    held = state.accountRoad ? {ses, token: ""} : null
    const contents = w.webContents
    // A top frame's navigation may hop or meet the company sign-in; a
    // frame's is allowed or refused, never more (policy.js).
    const load = (event) => {
      const where = contentNavigation({url: event.url, mainFrame: event.isMainFrame, from: contents.getURL()}, state)
      if (where === "allow") return
      event.preventDefault()
      if (!event.isMainFrame) return
      if (where === "hop") startHop(event.url, "sign-in", w)
      if (where === "company") lock("company")
    }
    contents.on("will-navigate", load)
    contents.on("will-redirect", load)
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame) load(event)
    })
    contents.on("did-finish-load", () => {
      if (!held || !contents.getURL().startsWith(state.home + "/")) return
      const keep = held
      contents.executeJavaScript("document.querySelector('meta[name=\"csrf-token\"]')?.content ?? ''", false)
        .then((token) => { if (held === keep && typeof token === "string" && token) keep.token = token }, () => {})
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
      confine(child.webContents)
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

  // A window of the content's own: the CYFR's pages and the device's, no
  // hop and no other address, in any frame.
  function confine(contents) {
    const stay = (event) => {
      const where = contentNavigation({url: event.url, mainFrame: event.isMainFrame, from: contents.getURL()}, state)
      if (where !== "allow") event.preventDefault()
    }
    contents.on("will-navigate", stay)
    contents.on("will-redirect", stay)
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame) stay(event)
    })
  }

  function openAccount(address) {
    const ses = session.fromPartition(ACCOUNT_PARTITION)
    const w = window(ses, {width: 560, height: 760, parent: content ?? undefined})
    accountWindow = w
    const contents = w.webContents
    // Only its top frame returns; a frame there loads nothing.
    const load = (event) => {
      const where = accountLoad(event.url, state, event.isMainFrame)
      if (where === "allow") return
      event.preventDefault()
      if (!event.isMainFrame) return
      if (where === "return") finishHop(event.url)
      else endHop()
    }
    contents.on("will-navigate", load)
    contents.on("will-redirect", load)
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame) load(event)
    })
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
    const request = readHop(url, state, kind)
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
    confine(w.webContents)
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

  // Sign out the session `out` held, at the selected CYFR's /auth/logout,
  // and forget it: whether the CYFR said it retired it (policy.js
  // retired). Without a token there is nothing to send, and nothing
  // confirmed.
  async function retire(out) {
    try {
      if (!out.token) return false
      const answer = await out.ses.fetch(state.home + "/auth/logout", {
        method: "POST", redirect: "manual", credentials: "include",
        headers: {"content-type": "application/x-www-form-urlencoded"},
        body: "_csrf_token=" + encodeURIComponent(out.token),
        signal: AbortSignal.timeout(10_000)
      })
      return retired(answer.status, answer.headers, state.home)
    } catch {
      return false
    } finally {
      await out.ses.clearStorageData().catch(() => {})
    }
  }

  // Close the content at once: the ceremony cancelled and every content
  // window destroyed, before anything is awaited and whatever a page
  // does. What the sign-out needs is answered, for whoever closes.
  function closeContent() {
    endHop()
    const windows = [...children, content].filter((w) => w && !w.isDestroyed())
    children.clear()
    content = null
    for (const w of windows) w.destroy()
    const out = held
    held = null
    return out
  }

  // Whether the session `out` held is signed out, or there was none.
  const signedOut = async (out) => !out || !out.token || await retire(out)

  // Each lock's sign-out and chooser, one after another.
  let locking = Promise.resolve()
  // The locked answers owed for locks main sent cyfr: each is that lock's
  // echo, whose content is closed already.
  let echoes = 0

  // A lock of the app, the system's, a lost page or window, or cyfr's own
  // (`ours` false): the content closes now, cyfr is told (`ours`), and
  // then the session is signed out and the chooser shown, with the
  // unconfirmed notice when the CYFR did not say it retired the session.
  function lock(why, ours = true) {
    if (ended || !state.readyURL) return
    if (ours) say(`locked: ${why}`)
    const out = closeContent()
    chosen.cancel()
    if (ours) {
      echoes++
      send("lock")
    }
    locking = locking.then(async () => {
      const note = why === "company" ? "company" : (await signedOut(out)) ? "" : "unconfirmed"
      if (!ended && !content) openContent(state.readyURL + (note ? `&notice=${note}` : ""))
    })
  }

  // ---- cyfr ----

  // cyfr's end: the content closes now and stays closed, the session is
  // signed out as at a lock, and the person is told, with the unconfirmed
  // sentence when the CYFR did not say it retired the session.
  function end(why) {
    if (ended) return
    ended = true
    say(`cyfr ended: ${why}`)
    const out = closeContent()
    if (child && child.exitCode === null) child.kill()
    if (quitting) return
    signedOut(out).then((done) => message(`CYFR stopped: ${why}. Quit the app and open it again.` +
      (done ? "" : ` ${UNCONFIRMED}`)))
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
        if (!state.readyURL || chosen.selected || !homeMessage(m)) return end("it named a CYFR this app does not open")
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
        chosen.propose(m)
        say(`home: ${m.home}`)
        send("home-ready", {home: m.home})
        return
      }
      case "opened":
        if (!chosen.opened(m.home)) return end("it opened a CYFR this app was not keeping to")
        return
      case "locked":
        if (echoes > 0) echoes--
        else lock("the device locked", false)
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
  // Quitting closes the content at once and signs its session out before
  // the app ends; there is no chooser left to tell an unconfirmed one.
  app.on("before-quit", (event) => {
    if (quitting || ended) return
    event.preventDefault()
    quitting = true
    signedOut(closeContent()).then(() => {
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
