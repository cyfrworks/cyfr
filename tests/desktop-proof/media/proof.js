// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Camera and microphone against a real CYFR (../README.md), on the proofs'
// shared entry (../lib.js): first refused, as the shipped app refuses
// them, then granted by this entry alone to the top page of the CYFR in
// the one content window it pins, where the composer's own capture makes
// the files a send stores. This file is bundled with the proof-only marker
// the package guard refuses (../pack.mjs); the shipped app has no grant.

import {createServer} from "node:http"

import {BrowserWindow, app} from "electron"

import api from "../../fixtures/worker_api.json"
import {accountAndDevice, connectOnward} from "../account.js"
import {HOME, atBootstrap, atHome, chooserWindow, contentAt, inputs, js, literal, log, row, run, sleep, waitFor} from "../lib.js"

// ---- the grant: this entry's alone ----

// The content window's page the proof lets have the devices, once it does.
let pinned = null

const originOf = (url) => {
  try {
    return new URL(url).origin
  } catch {
    return ""
  }
}

// `media` to the pinned window, for its top frame, when the asking
// document's security origin is the CYFR's. An ask that names no security
// origin is refused: an address says what a frame loaded, not whose
// document asks. Everything else is the app's own answer.
const allows = (permission, contents, details) =>
  permission === "media" && pinned !== null && contents === pinned && details.isMainFrame === true &&
  originOf(details.securityOrigin) === HOME

// Each session's two permission handlers as the app sets them, with the
// grant asked first, and kept as installed.
const installed = new Map()
app.on("session-created", (ses) => {
  const handlers = {}
  installed.set(ses, handlers)
  const onRequest = ses.setPermissionRequestHandler.bind(ses)
  ses.setPermissionRequestHandler = (own) => {
    handlers.request = (contents, permission, callback, details) =>
      allows(permission, contents, details) ? callback(true) : own(contents, permission, callback, details)
    return onRequest(handlers.request)
  }
  const onCheck = ses.setPermissionCheckHandler.bind(ses)
  ses.setPermissionCheckHandler = (own) => {
    handlers.check = (contents, permission, origin, details) =>
      allows(permission, contents, details) || own(contents, permission, origin, details)
    return onCheck(handlers.check)
  }
})

// What both installed handlers answer an ask of the pinned page's top
// frame at the CYFR's address, with `securityOrigin` or none.
async function handlersAnswer(wc, permission, securityOrigin) {
  const {request, check} = installed.get(wc.session)
  const details = {isMainFrame: true, requestingUrl: `${HOME}/`, ...(securityOrigin && {securityOrigin})}
  return {request: await new Promise((answer) => request(wc, permission, answer, details)),
    check: check(wc, permission, `${HOME}/`, details)}
}

// ---- the worker's status, stood in for ----

// A send is admitted only while a worker service answers its status. This
// one answers that alone, as the contract's vectors write it; it starts
// nothing, so no brain's turn runs here.
async function workerStatus() {
  const idle = api["status"].valid.find(({wire}) => wire.refusal === null && wire.attempts.length === 0).wire
  const answer = JSON.stringify({v: api["version"], ok: {...idle, service: "wrk_proof"}})
  const server = createServer((request, response) => {
    request.resume()
    if (request.url !== api["routes"].status) {
      response.writeHead(404).end()
      return
    }
    response.writeHead(200, {"content-type": "application/json"}).end(answer)
  })
  await new Promise((resolve, reject) => server.once("error", reject).listen(inputs.worker_port, "127.0.0.1", resolve))
}

// ---- in Prism's page ----

const COMPOSER = `document.querySelector('#aqua-panel-pane-textarea')`
const UPLOAD = `${COMPOSER}.form.querySelector("input[data-phx-upload-ref]")`
const SENT = `[...new Set([...document.querySelectorAll('a[href*="/attachments/"], img[src*="/attachments/"]')]
  .map((e) => e.getAttribute("href") || e.getAttribute("src")))]`

// getUserMedia for each device, its tracks stopped: "granted" or the refusal's name.
const DEVICES = `Promise.all([{audio: true}, {video: true}].map((c) => navigator.mediaDevices.getUserMedia(c)
  .then((m) => { m.getTracks().forEach((t) => t.stop()); return "granted" }, (e) => e.name)))`

// The engine's answer to every ask of the page's, with the tracks it gave.
const WATCH = `(() => {
  if (window.proofAsks) return true
  const devices = navigator.mediaDevices
  const ask = devices.getUserMedia.bind(devices)
  window.proofAsks = []
  devices.getUserMedia = async (wants) => {
    const seen = {wants: wants.video ? "video" : "audio", outcome: null, tracks: []}
    window.proofAsks.push(seen)
    try {
      const stream = await ask(wants)
      seen.outcome = "granted"
      seen.tracks = stream.getTracks()
      return stream
    } catch (e) {
      seen.outcome = e.name
      throw e
    }
  }
  return true
})()`

const asks = (wc) => js(wc, `window.proofAsks.map((a) => ({wants: a.wants, outcome: a.outcome, live: a.tracks.filter((t) => t.readyState === "live").length}))`)

const capture = (wc, kind) => js(wc,
  `${COMPOSER}.dispatchEvent(new CustomEvent("cyfr:capture", {detail: {kind: ${literal(kind)}}})); true`)

// The files waiting in the composer's upload, those uploaded, and those
// the page shows as sent.
const draft = (wc) => js(wc, `(() => {
  const refs = (name) => (${UPLOAD}.getAttribute(name) || "").split(",").filter(Boolean).length
  return {waiting: refs("data-phx-active-refs"), uploaded: refs("data-phx-done-refs"), sent: (${SENT}).length}
})()`)

async function openComposer(wc) {
  await waitFor(() => js(wc, `!!document.querySelector("#aqua-panel-button")`), "Aqua's button")
  await js(wc, `if (!${COMPOSER}) document.querySelector("#aqua-panel-button").click(); true`)
  await waitFor(() => js(wc, `!!${COMPOSER} && !${COMPOSER}.disabled`), "Aqua's composer")
}

// A clip under way: the engine's answer, once its track is live.
async function recording(wc) {
  const from = (await asks(wc)).length
  await capture(wc, "clip")
  return waitFor(async () => {
    const seen = (await asks(wc))[from]
    return seen?.live === 1 ? {at: from} : null
  }, "a clip recording")
}

// ---- the proof ----

async function mediaPhase() {
  await workerStatus()

  // grant_chooser: the chooser itself, in the content window, pinned: its
  // origin is all that refuses it.
  const chooser = await chooserWindow()
  pinned = chooser.webContents
  const atChooser = {chooser: atBootstrap(chooser.webContents.getURL()), got: await js(chooser.webContents, DEVICES)}
  pinned = null
  row("grant_chooser", atChooser.chooser && atChooser.got.every((o) => o === "NotAllowedError"),
    "granted, the chooser in the same content window is refused them", atChooser)

  await accountAndDevice(inputs, connectOnward)
  const w = await contentAt(atHome, "Prism")
  const wc = w.webContents
  await waitFor(() => js(wc, `!!document.querySelector(".phx-connected")`), "Prism's page connected")
  await openComposer(wc)
  await js(wc, WATCH)

  // media_shipped: the app's rules with nothing granted: the page's asks
  // and the composer's own capture are each refused.
  const page = await js(wc, DEVICES)
  const from = (await asks(wc)).length
  await capture(wc, "still")
  const still = await waitFor(async () => (await asks(wc))[from]?.outcome, "the still's answer")
  if (still !== "granted") {
    // The refusal was read in a later task than it was given in, and the
    // hook is free within that task's microtasks: the clip is asked once.
    await capture(wc, "clip")
    await waitFor(async () => (await asks(wc))[from + 1]?.outcome, "the clip's answer")
  }
  const composer = (await asks(wc)).slice(from)
  const refusedDraft = await draft(wc)
  row("media_shipped", [...page, ...composer.map((a) => a.outcome)].every((o) => o === "NotAllowedError") &&
    composer.length === 2 && refusedDraft.waiting === 0,
  "with the shipped app's rules the page and the composer's own capture are refused both devices, and no file is made",
  {page, composer, draft: refusedDraft})

  // no_control: the composer holds its file input, its box and Send, and
  // no control anywhere on the page names a camera, a microphone or a recording.
  const controls = await js(wc, `({
    composer: [...${COMPOSER}.form.querySelectorAll("button, input, select, textarea, [role=button]")]
      .map((e) => e.tagName.toLowerCase() + ":" + (e.type || "") + ":" + (e.tagName === "BUTTON" ? e.textContent.trim() : "")),
    naming: [...document.querySelectorAll("button, input, label, [role=button]")]
      .map((e) => [e.getAttribute("aria-label"), e.title, e.tagName === "INPUT" ? e.getAttribute("capture") : e.textContent].join(" ").replace(/\\s+/g, " ").trim())
      .filter((s) => /camera|microphone|\\brecord(ing)?\\b|take a photo/i.test(s))})`)
  row("no_control", controls.composer.join() === "input:file:,textarea:textarea:,button:submit:Send" && controls.naming.length === 0,
    "Prism draws no control that captures: the composer holds its file input, its box and Send", controls)

  // ---- from here this entry grants the pinned page the devices ----
  pinned = wc

  const granted = await js(wc, DEVICES)
  row("media_granted", granted.every((o) => o === "granted"),
    "granted by the proof's entry, the CYFR's top page in the content window gets both devices", {granted})

  // grant_security_origin: asked of both installed handlers, since the
  // engine names a security origin on every media ask it makes: with none
  // the CYFR's address grants nothing, and with the CYFR's both allow.
  const unnamed = await handlersAnswer(wc, "media")
  const named = await handlersAnswer(wc, "media", `${HOME}/`)
  row("grant_security_origin", !unnamed.request && !unnamed.check && named.request && named.check,
    "granted, an ask with no security origin is refused by both handlers, whatever address it names", {unnamed, named})

  // grant_frame: a frame the page writes, which takes the page's origin,
  // so its not being the top frame is all that refuses it.
  await js(wc, `(() => { const f = document.createElement("iframe"); f.name = "proof-media"; f.id = "proof-media";
    f.allow = "camera; microphone"; document.body.appendChild(f)
    f.contentDocument.open(); f.contentDocument.write("<p>a frame</p>"); f.contentDocument.close(); return true })()`)
  const written = wc.mainFrame.frames.find((f) => f.name === "proof-media")
  const frame = {at: await written.executeJavaScript("location.origin", true), got: await written.executeJavaScript(DEVICES, true)}
  await js(wc, `document.querySelector("#proof-media").remove(); true`)
  row("grant_frame", frame.at === HOME && frame.got.every((o) => o === "NotAllowedError"),
    "granted, a frame of the page's own origin that the page allows both devices is refused them", frame)

  // grant_window: the CYFR's own page, in another window of the same session.
  const other = new BrowserWindow({parent: w, show: false, webPreferences: {sandbox: true, contextIsolation: true, session: wc.session}})
  await other.loadURL(`${HOME}/`).catch((e) => log(`second window: ${e.message}`))
  const elsewhere = {at: originOf(other.webContents.getURL()), got: await js(other.webContents, DEVICES)}
  other.destroy()
  row("grant_window", elsewhere.at === HOME && elsewhere.got.every((o) => o === "NotAllowedError"),
    "granted, the CYFR's page in another window of the same session is refused them", elsewhere)

  // grant_kind: the grant is for media, and for no other permission.
  const otherKind = {page: await js(wc, `Notification.requestPermission()`), handlers: await handlersAnswer(wc, "notifications", `${HOME}/`)}
  row("grant_kind", otherKind.page === "denied" && !otherKind.handlers.request && !otherKind.handlers.check,
    "granted the devices, the page is still refused another permission", otherKind)

  // screen_refused: by Prism's own policy before anyone is asked, and by
  // the other road the engine has to a screen.
  const screen = await js(wc, `(async () => ({
    display: await navigator.mediaDevices.getDisplayMedia({video: true}).then(() => "granted", (e) => e.name + ": " + e.message),
    desktop: await navigator.mediaDevices.getUserMedia({audio: false, video: {mandatory: {chromeMediaSource: "desktop"}}})
      .then((m) => { m.getTracks().forEach((t) => t.stop()); return "granted" }, (e) => e.name)}))()`)
  row("screen_refused", /^NotAllowedError: .*display-capture.*permissions policy/.test(screen.display) && screen.desktop === "NotAllowedError",
    "granted the devices, screen capture is refused: by Prism's policy, and by way of getUserMedia too", screen)

  // capture_sends_nothing: a still and a clip land in the composer's draft.
  const before = await draft(wc)
  await capture(wc, "still")
  const afterStill = await waitFor(async () => {
    const d = await draft(wc)
    return d.uploaded === 1 || d.sent > before.sent ? d : null
  }, "the still in the composer")
  await recording(wc)
  const afterClip = await waitFor(async () => {
    const d = await draft(wc)
    return d.uploaded === 2 || d.sent > before.sent ? d : null
  }, "the clip in the composer")
  row("capture_sends_nothing", before.sent === 0 && afterStill.sent === 0 && afterClip.sent === 0 && afterClip.waiting === 2,
    "a still and a clip wait in the composer's draft, and capturing sends nothing", {before, afterStill, afterClip})

  // capture_files: the person's Send stores them, and what the thread
  // serves back decodes: a patterned PNG and sound of at most ten seconds.
  await js(wc, `${COMPOSER}.form.requestSubmit(); true`)
  try {
    await waitFor(() => js(wc, `(${SENT}).length >= 2`), "the sent files in the thread", 30_000)
  } catch (e) {
    log(`send: ${e.message}`) // capture_files says it
  }
  const files = await js(wc, `(async () => {
    const out = []
    for (const address of ${SENT}) {
      const response = await fetch(address)
      const bytes = await response.arrayBuffer()
      const file = {status: response.status, name: address.split("/").pop(), bytes: bytes.byteLength}
      const head = [...new Uint8Array(bytes.slice(0, 4))].join()
      try {
        if (head === "137,80,78,71") {
          const image = await createImageBitmap(new Blob([bytes], {type: "image/png"}))
          const canvas = new OffscreenCanvas(image.width, image.height)
          canvas.getContext("2d").drawImage(image, 0, 0)
          const pixels = canvas.getContext("2d").getImageData(0, 0, image.width, image.height).data
          const colours = new Set()
          for (let i = 0; i < pixels.length; i += 388) colours.add(pixels[i] + "," + pixels[i + 1] + "," + pixels[i + 2])
          file.png = {width: image.width, height: image.height, colours: colours.size}
        } else {
          const audio = new AudioContext()
          const sound = await audio.decodeAudioData(bytes)
          let peak = 0
          for (const v of sound.getChannelData(0)) peak = Math.max(peak, Math.abs(v))
          file.sound = {seconds: sound.duration, peak}
          await audio.close()
        }
      } catch (e) {
        file.undecoded = e.name
      }
      out.push(file)
    }
    return out
  })()`)
  const photo = files.find((f) => f.png && /photo-.+\.png$/.test(f.name))
  const clip = files.find((f) => f.sound && /recording-.+\.webm$/.test(f.name))
  row("capture_files", files.length === 2 && files.every((f) => f.status === 200) && photo?.png.colours > 1 &&
    clip?.sound.seconds > 9 && clip?.sound.seconds <= 10 && clip?.sound.peak > 0,
  "sent, both are stored, fetched back and decoded: the camera's patterned PNG and sound of at most ten seconds", {files})
  const released = await asks(wc)
  row("capture_released", released.every((a) => a.live === 0),
    "a finished still and a finished clip each stopped the track they were given", {released})

  // cancel: a clip under way ends at once and attaches nothing.
  const cancelled = await recording(wc)
  await capture(wc, "cancel")
  const atCancel = (await asks(wc))[cancelled.at]
  await sleep(1500) // sleep-ok: an absence, that the cancelled clip makes no file, has no event to wait on
  const afterCancel = await draft(wc)
  row("cancel", atCancel.live === 0 && afterCancel.waiting === 0,
    "a cancel stops a recording's track at once and attaches nothing", {atCancel, afterCancel})

  // composer_closed: the panel closed, the composer's hook ends.
  const closing = await recording(wc)
  await js(wc, `document.querySelector("#aqua-panel-close").click(); true`)
  await waitFor(() => js(wc, `!${COMPOSER}`), "the composer closed")
  const atClose = (await asks(wc))[closing.at]
  row("composer_closed", atClose.live === 0, "the composer closing stops a recording's track", {atClose})

  // lock: the device's Lock ends a recording with the page that holds it.
  await openComposer(wc)
  await recording(wc)
  const renderer = wc.getOSProcessId()
  await js(wc, `document.querySelector('[data-test="device-lock"]').click(); true`).catch((e) => log(`lock: ${e.message}`))
  const ended = {}
  try {
    // Sooner than the clip would end by itself.
    ended.closed = await waitFor(() => w.isDestroyed() && !app.getAppMetrics().some((m) => m.pid === renderer), "the recording's page ended", 5000)
  } catch (e) {
    ended.stopped = e.message
  }
  row("lock", ended.closed === true, "the device's Lock ends a recording: its window closed and its page's process gone", ended)
}

run("media", {media: mediaPhase})
