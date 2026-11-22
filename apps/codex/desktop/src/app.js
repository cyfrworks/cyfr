// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The CYFR app's main process: it starts cyfr desktop-serve, owns every
// window the app has, and holds each to its rules (policy.js).
//
// What main does is decided in one place, states.js: every event, from
// cyfr, from a window or from the system, goes through its `step`, and
// this file carries out the effects it answers, in order, and nothing
// else. cyfr serves the chooser and the device's pages on loopback; main
// shows them in a content window whose session is memory-only and new at
// every unlock. On macOS and Windows a person may sign in with the
// account's passkey instead: the CYFR's own sign-in page hops to its
// account service, which opens in the one account window, and the answer
// returns only to the content session that hopped.

import {spawn} from "node:child_process"

import {BrowserWindow, app, dialog, net, powerMonitor, session} from "electron"

import {lines, readFromCyfr, toCyfr} from "./process.js"
import {accountLoad, documentHeaders, grants, readHop, relyingParty, retired, unlistedSwitch} from "./policy.js"
import {initial, kept, step} from "./states.js"

const READY_WITHIN_MS = 20_000
const UNCONFIRMED = "The CYFR did not confirm that it signed this computer out. That sign-in ends when it expires, or when you sign it out under Settings, Keys on your account."
const ACCOUNT_PARTITION = "persist:cyfr-account"

// Every window's pages run under these: sandboxed, their context isolated,
// no Node integration and web security on.
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

  let state = initial(accountRoad, {
    proxy: app.commandLine.getSwitchValue("proxy-server"),
    resolver: app.commandLine.getSwitchValue("host-resolver-rules")
  })
  let child = null
  let content = null // the one content window
  const children = new Set() // its confirmation windows
  let accountWindow = null
  let hop = null // {kind, request, from, timer}
  // The forgery token of the last page of the CYFR main keeps to, held
  // apart from the content window so that closing it at once loses
  // nothing; step says when the session is held (states.js `held`).
  let holder = null
  let contentSession = null
  let generation = 0
  // The sign-out a lock, cyfr's loss or quitting started: whether the
  // CYFR confirmed it.
  let retiring = Promise.resolve(true)

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
    if (effect.send) send(effect.send.type, effect.send.fields)
    if (effect.retire) {
      const out = {held: effect.retire.held ? holder ?? {token: ""} : null, ses: contentSession}
      holder = null
      // A sign-out still running from before is waited for too. Once a
      // lock has told the person its answer, the next answers for itself.
      const before = retiring
      const now = retire(out).then(async (confirmed) => (await before) && confirmed)
      retiring = now
      if (state.name === "locking") {
        now.then((confirmed) => {
          if (retiring === now) retiring = Promise.resolve(true)
          on({type: "signed-out", confirmed})
        })
      }
    }
    if (effect.chooser) openContent(state.readyURL + (effect.chooser.length ? `&notice=${effect.chooser.join(",")}` : ""))
    if (effect.relaunch) {
      say("starting again with the CYFR's route")
      const args = process.argv.slice(1).filter((a) => !/^--(proxy-server|host-resolver-rules)=/.test(a))
      if (effect.relaunch.proxy) args.push(`--proxy-server=${effect.relaunch.proxy}`, `--host-resolver-rules=${effect.relaunch.resolver}`)
      retiring.then(() => {
        if (child && child.exitCode === null) child.kill()
        app.relaunch({args})
        app.exit(0)
      })
    }
    if (effect.end) {
      say(`cyfr ended: ${effect.end}`)
      if (child && child.exitCode === null) child.kill()
      retiring.then((confirmed) => message(`CYFR stopped: ${effect.end}. Quit the app and open it again.` +
        (confirmed ? "" : ` ${UNCONFIRMED}`)))
    }
    if (effect.quit) {
      retiring.then(() => {
        if (child && child.exitCode === null) {
          send("shutdown")
          child.stdin.end()
        }
        quitting = true
        app.quit()
      })
    }
    if (effect.hold) holder = holder ?? {token: ""}
    if (effect.token && content && holder) {
      const keep = holder
      content.webContents.executeJavaScript("document.querySelector('meta[name=\"csrf-token\"]')?.content ?? ''", false)
        .then((token) => { if (typeof token === "string" && token) keep.token = token }, () => {})
    }
    if (effect.hop) startHop(effect.hop.url, effect.hop.kind)
    if (effect.return) finishHop(effect.return.url)
    if (effect.unhop) endHop()
  }

  // ---- the window owner: every window the app has is made here ----

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

  // A window of the content's own (`which`: the content window or a
  // confirmation window) asks step about each of its loads. A
  // confirmation window's first load is of the address the window handler
  // opened it for (`first`), which that handler decided: the engine names
  // some frame of the opener as its initiator, not reliably the top one.
  function confine(contents, which, lost, first = null) {
    const ask = (event) => {
      const opening = first !== null && event.isMainFrame && event.url === first
      if (event.isMainFrame) first = null
      const decided = on({type: "navigate", window: which, url: event.url, target: event.isMainFrame ? "top" : "frame",
        asker: opening ? "top" : askerOf(event, contents), showing: contents.getURL()})
      if (!decided.allow) event.preventDefault()
    }
    contents.on("will-navigate", ask)
    contents.on("will-redirect", ask)
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame) ask(event)
    })
    contents.setWindowOpenHandler(() => ({action: "deny"}))
    contents.on("render-process-gone", () => on({type: "lock", why: lost}))
  }

  function openContent(address) {
    generation++
    contentSession = session.fromPartition(`cyfr-${process.pid}-${generation}`)
    guard(contentSession, "content")
    const w = window(contentSession)
    content = w
    const contents = w.webContents
    confine(contents, "content", "the page stopped")
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
        width: 520, height: 640, parent: w, autoHideMenuBar: true, webPreferences: {...SECURE, session: contentSession}
      }}
    })
    contents.on("did-create-window", (opened) => {
      const first = opening
      opening = null
      children.add(opened)
      opened.on("closed", () => children.delete(opened))
      confine(opened.webContents, "child", "a window's page stopped", first)
    })
    contents.on("did-finish-load", () => {
      if (content === w) on({type: "page", url: contents.getURL()})
    })
    w.on("closed", () => {
      if (content === w) {
        content = null
        on({type: "quit"})
      }
    })
    w.loadURL(address)
  }

  function openAccount(address) {
    const ses = session.fromPartition(ACCOUNT_PARTITION)
    const w = window(ses, {width: 560, height: 760, parent: content ?? undefined})
    accountWindow = w
    const contents = w.webContents
    const ask = (event) => {
      const decided = on({type: "account-navigate", url: event.url, target: event.isMainFrame ? "top" : "frame"})
      if (!decided.allow) event.preventDefault()
    }
    contents.on("will-navigate", ask)
    contents.on("will-redirect", ask)
    contents.on("will-frame-navigate", (event) => {
      if (!event.isMainFrame) ask(event)
    })
    contents.setWindowOpenHandler(() => ({action: "deny"}))
    contents.on("render-process-gone", () => on({type: "lock", why: "the sign-in page stopped"}))
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
    w.on("closed", () => {
      quitting = true
      app.quit()
    })
    const page = "<!doctype html><meta charset=utf-8><meta http-equiv=Content-Security-Policy content=\"default-src 'none'; style-src 'unsafe-inline'\">" +
      "<title>CYFR</title><style>body{background:#0b1418;color:#e8f1f2;font:1.1rem system-ui,sans-serif;margin:2rem}</style>" +
      `<h1>CYFR</h1><p>${text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)}</p>`
    w.loadURL("data:text/html;charset=utf-8," + encodeURIComponent(page))
  }

  // Close the content at once: the ceremony cancelled and every content
  // and confirmation window destroyed, whatever a page does.
  function closeContent() {
    endHop()
    const windows = [...children, content].filter((w) => w && !w.isDestroyed())
    children.clear()
    content = null
    for (const w of windows) w.destroy()
  }

  // ---- the account road: a hop, its window, its return ----

  function startHop(url, kind) {
    const request = readHop(url, kept(state), kind)
    if (!request || hop || !content) return
    hop = {kind, request, from: content, timer: setTimeout(endHop, Math.max(0, request.expires_at - Date.now()))}
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
      webPreferences: {...SECURE, session: contentSession}
    })
    children.add(w)
    w.on("closed", () => children.delete(w))
    confine(w.webContents, "child", "a window's page stopped")
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

  // ---- the sign-out ----

  // Sign out the session `out.held` held at the CYFR main keeps to, then
  // clear the content session's storage, always: whether the CYFR
  // confirmed it. No session held is nothing to confirm; a missing
  // forgery token, a failed request or any answer but the signed-out
  // acknowledgement is unconfirmed (policy.js retired).
  async function retire({held: out, ses}) {
    const home = kept(state).home || state.home
    try {
      if (!out) return true
      if (!out.token || !home) return false
      const answer = await direct(ses, home + "/auth/logout", "_csrf_token=" + encodeURIComponent(out.token))
      return !!answer && retired(answer.status, answer.headers, home)
    } catch {
      return false
    } finally {
      await ses?.clearStorageData().catch(() => {})
    }
  }

  // The direct answer to a form POST of `body` to `url` in session `ses`,
  // with its cookies, a redirect answered rather than followed: {status,
  // headers}, or null when none came within 10 s. net.request, since
  // session.fetch rejects a manual redirect rather than answer it.
  function direct(ses, url, body) {
    return new Promise((resolve) => {
      const request = net.request({method: "POST", url, session: ses, useSessionCookies: true, redirect: "manual"})
      const timer = setTimeout(() => done(null), 10_000)
      function done(answer) {
        clearTimeout(timer)
        resolve(answer)
        request.abort()
      }
      const headers = (raw) => new Headers(Object.entries(raw ?? {}).flatMap(([k, v]) => (Array.isArray(v) ? v : [v]).map((x) => [k, x])))
      request.on("redirect", (status, _method, _location, raw) => done({status, headers: headers(raw)}))
      request.on("response", (response) => {
        done({status: response.statusCode, headers: headers(response.headers)})
        response.resume?.()
      })
      request.on("error", () => done(null))
      request.setHeader("content-type", "application/x-www-form-urlencoded")
      request.end(body)
    })
  }

  // ---- cyfr ----

  let send = () => {}
  let readiness = null
  let quitting = false

  function startCyfr() {
    child = spawn(cyfr, ["desktop-serve"], {stdio: ["pipe", "pipe", "pipe"], windowsHide: true})
    send = (type, fields) => {
      if (child.stdin.writable) child.stdin.write(toCyfr(type, fields))
    }
    readiness = setTimeout(() => on({type: "gone", why: "it did not get ready"}), READY_WITHIN_MS)
    child.stdout.setEncoding("utf8")
    const feed = lines((line) => {
      let m
      try {
        m = readFromCyfr(line)
      } catch (e) {
        return on({type: "gone", why: `it sent ${e.reason === "size" ? "a line too long" : "something that is not its message"}`})
      }
      if (m.type === "ready") clearTimeout(readiness)
      on({type: m.type, url: m.url, home: m.home, id: m.id, message: m})
    })
    child.stdout.on("data", (chunk) => {
      try {
        feed(chunk)
      } catch {
        on({type: "gone", why: "it sent a line too long"})
      }
    })
    // cyfr's own refusal, its "Error: " line, says why it ended.
    let last = ""
    let pending = ""
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk) => {
      process.stderr.write(chunk)
      pending += chunk
      const whole = pending.split("\n")
      pending = whole.pop()
      for (const line of whole) if (line.startsWith("Error: ")) last = line
    })
    child.on("error", (e) => on({type: "gone", why: `it could not start (${e.message})`}))
    child.on("exit", (code, signal) => {
      if (!quitting) on({type: "gone", why: last.replace(/^Error: /, "") || `it exited (${signal ?? code})`})
    })
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
  // A lock or cyfr's end closes every window before it opens the next,
  // which must not quit; closing the content window quits (openContent).
  app.on("window-all-closed", () => {})
  app.on("before-quit", (event) => {
    if (quitting) return
    event.preventDefault()
    on({type: "quit"})
  })

  app.whenReady().then(() => {
    const account = session.fromPartition(ACCOUNT_PARTITION)
    guard(account, "account")
    account.on("select-webauthn-account", chooseAccount)
    if (touchIdGroup && process.platform === "darwin") app.configureWebAuthn({touchID: {keychainAccessGroup: touchIdGroup}})
    // The app locks on the system's lock or sleep, as on any window's page
    // lost and on cyfr's locked; the desktop's idle alone does not.
    for (const signal of ["lock-screen", "suspend"]) powerMonitor.on(signal, () => on({type: "lock", why: signal}))
    startCyfr()
  })

}
