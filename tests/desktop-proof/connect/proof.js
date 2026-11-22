// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The six-word road against a real CYFR (../README.md), on the proofs'
// shared entry (../lib.js). The app is launched three times: `connect`,
// the road itself, then `remembered` and `changed`, which read the
// account service this computer approved.

import {powerMonitor} from "electron"

import {DIRECTORY, HOME, LOOPBACK, NAME, appWindows, arm, atBootstrap, atDevice, atHome, bare, childOfThis, chooserWindow, content, contentAt, decided, decisions, fault, fromApp, harvest, history, inputs, js, literal, load, lockDetail, lockedOut, log, machine, openCYFR, opens, processState, question, reachedSince, record, refused, row, run, said, secondClient, section, seen, sessionCookie, signedOut, sleep, submit, submitConnect, text, waitFor} from "../lib.js"

// An account service the CYFR names once reconfigured (the front's
// directory fault); nothing answers at it.
const OTHER_DIRECTORY = "https://other.test"
const UNCONFIRMED = "CYFR locked, but the CYFR did not confirm that it signed this computer out. " +
  "That sign-in ends when it expires, or when you sign it out under Settings, Keys on your account."

async function connectPhase() {
  const second = await secondClient()

  // account: @desk-a made at the account directory with the passkey.
  await load(second, `${DIRECTORY}/account/new#name=${NAME}`)
  await arm()
  await section(second, ["choose"])
  await js(second, `document.querySelector("#name").value = ${literal(NAME)};
    document.querySelector("#name").dispatchEvent(new Event("input", {bubbles: true}));
    const a = document.querySelector("#acceptance:not([hidden]) #accept"); if (a) a.click();
    document.querySelector("#create").click()`)
  const code = await section(second, ["show-code"])
  await js(second, `document.querySelector("#saved").click()`)
  const made = await section(second, ["done", "done-return"])
  await harvest()
  row("account", made.section?.startsWith("done") && code.section === "show-code",
    `@${NAME} made at ${DIRECTORY}'s pages with a passkey, on the second client`, made)

  // setup: x.test set up by signing in with that account through its link.
  await load(second, `${HOME}/setup#${inputs.setup_token}`)
  await waitFor(() => js(second, `!!document.querySelector('[data-test="setup-sign-in"]')`), "the setup page")
  await js(second, `document.querySelector('[data-test="setup-sign-in"]').click()`)
  await waitFor(() => new URL(second.getURL()).pathname === "/account/sign", "the sign page")
  await arm()
  await section(second, ["ask"])
  await js(second, `document.querySelector("#use-passkey").click()`)
  const landed = await waitFor(() => atHome(second.getURL()) && second.getURL(), "the second client to land at the CYFR")
  row("setup", !!landed, `${HOME} set up by @${NAME}, signed in on the second client`, {at: bare(landed)})

  // media_control: this run's camera and microphone are there to grant: a
  // browser that grants them, the second client on the CYFR's page, gets
  // both.
  const ask = (where) => `Promise.all([{audio: true}, {video: true}].map((c) => ${where}.navigator.mediaDevices.getUserMedia(c)
    .then((m) => { m.getTracks().forEach((t) => t.stop()); return "granted" }, (e) => e.name)))`
  const control = await js(second, ask("window"))
  row("media_control", control.every((m) => m === "granted"),
    "the run's camera and microphone are granted to a page by a browser that allows them", {control})

  // chooser: the app's first page, saying where this computer's lock goes
  // unheard (the container has no system bus).
  let w = await contentAt(atBootstrap, "the chooser")
  const chooser = await waitFor(async () => {
    const c = await js(w.webContents, `({choose: !document.querySelector("#choose").hidden, warning: document.querySelector("#warning").textContent})`)
    return c.choose && c.warning ? c : null
  }, "the chooser with its warning")
  row("chooser", chooser.warning.startsWith("CYFR cannot tell when this computer locks or sleeps here"),
    "the app opens at Connect to a CYFR and says in one sentence that it cannot hear this computer's lock", chooser)

  // custom_directory: an account service other than cyfr.run is shown
  // whole and asked about.
  const dirBefore = (await seen("dir.test")).length
  await submitConnect(w.webContents)
  const asked = await question(w.webContents)
  row("custom_directory", asked.home === HOME && asked.service === DIRECTORY,
    "a CYFR on another account service than cyfr.run shows it whole and asks about it", asked)
  await js(w.webContents, `document.querySelector("#decline").click()`)
  const declined = await waitFor(() => js(w.webContents, `document.querySelector("#notice").textContent || null`), "the decline")

  // lock_during_connect: a lock while a Connect runs (cyfr's request for
  // the CYFR's sign-in page seen held at its front) ends it: cyfr gives
  // that request up, the chooser comes back and cyfr runs on.
  await fault("x.test", "hold")
  const xFrom = (await seen("x.test")).length
  await submitConnect(w.webContents)
  const inFlight = await waitFor(async () => {
    const all = await seen("x.test")
    const i = all.findIndex((r, n) => n >= xFrom && fromApp(r) && r.path === "/login" && r.fault === "hold" && !r.aborted)
    return i >= 0 ? {index: i} : null
  }, "cyfr's Connect to ask the CYFR")
  const lockedAt = Date.now()
  powerMonitor.emit("lock-screen")
  // Given up after the lock, and before cyfr's own bound on reading a
  // CYFR's sign-in page (10 s from its request) would have.
  const held = await waitFor(async () => {
    const r = (await seen("x.test"))[inFlight.index]
    return r.aborted ? r : null
  }, "cyfr to give the Connect's request up")
  const givenUp = held.abortedAt >= lockedAt && held.abortedAt - held.at < 10_000
  const relocked = await chooserWindow()
  await fault("x.test", "none")
  row("lock_during_connect", givenUp && said.includes("locked: lock-screen") && !said.some((l) => l.startsWith("cyfr ended")),
    "a lock while cyfr's Connect is in flight ends it: cyfr gives its request up, the chooser comes back and cyfr runs on",
  {said, heldFor: held.abortedAt - held.at, afterLock: held.abortedAt - lockedAt})
  w = relocked

  // decline: Cancel said nothing was sent, and from the first question to
  // the approval below nothing of the app reached the account service.
  const again = await (async () => { await submitConnect(w.webContents); return question(w.webContents) })()
  const reached = (await reachedSince("dir.test", dirBefore)).map((r) => `${r.method} ${r.path}`)
  row("decline", declined === "Nothing was sent to that account service." && again.service === DIRECTORY && reached.length === 0,
    "Cancel says nothing was sent; until the account service is approved nothing of the app reaches it, and the next Connect asks again",
    {declined, reached})

  // device_pages: approved, the device's pages.
  await js(w.webContents, `document.querySelector("#approve").click()`)
  w = await contentAt(atDevice, "the device's pages")
  const setupPage = await waitFor(async () => (await text(w.webContents)).includes("Set up CYFR"), "the setup page")
  row("device_pages", setupPage, "once approved, the device's pages open in the content window", {url: bare(w.webContents.getURL())})

  // enrolment_page: the passphrase drawn and given, the enrolment page
  // with the key's code beside the account service's address. That the
  // key is made under the passphrase is the holder's tests' to show.
  await submit(w.webContents, "/passphrase")
  const passphrase = await waitFor(() => js(w.webContents, `document.querySelector("p.code")?.textContent.trim() || null`), "the passphrase")
  await submit(w.webContents, "/make", {secret: passphrase, again: passphrase})
  const enroll = await waitFor(() => js(w.webContents, `(() => {
    const h = [...document.querySelectorAll("h1")].map((x) => x.textContent)
    if (!h.includes("Add this device to your account")) return null
    const b = [...document.querySelectorAll("p b")].map((x) => x.textContent)
    return {code: b[0], service: b[1], add: document.querySelector("p.code")?.textContent.trim()}
  })()`), "the enrolment page")
  row("enrolment_page", enroll.service === DIRECTORY && /^[0-9a-z]{16}$/i.test(enroll.code) && enroll.add.startsWith(DIRECTORY + "/account/add#"),
    "with a passphrase given, the enrolment page shows the key's code beside the account service's address", {...enroll, add: bare(enroll.add)})

  // admission_refused: "I approved it" before any approval is refused.
  await submit(w.webContents, "/enroll", {name: NAME})
  const refusal = await waitFor(() => js(w.webContents, `document.querySelector(".notice")?.textContent.trim() || null`), "a refusal")
  row("admission_refused", /not on @?desk-a|not .*account/i.test(refusal), "a device not yet approved is refused, and says so", {refusal})

  // approved: the second client approves the key with the account's passkey.
  await load(second, enroll.add)
  await arm()
  await section(second, ["ask"])
  const secondCode = await js(second, `document.querySelector("#device-code").textContent.trim()`)
  await js(second, `document.querySelector("#add").click()`)
  const added = await section(second, ["added"])
  row("approved", added.section === "added" && secondCode === enroll.code,
    "the second client shows the same code and adds the key with the passkey", {secondCode, added})

  // prism: the device is admitted and opens Prism in the content window.
  await submit(w.webContents, "/enroll", {name: NAME})
  await openCYFR(w, passphrase)
  w = await contentAt(atHome, "Prism")
  await waitFor(() => js(w.webContents, `!!document.querySelector(".phx-connected")`), "Prism's page connected")
  const first = await sessionCookie(w)
  row("prism", !!first, "the admitted device opens Prism in the content window, signed in", {url: bare(w.webContents.getURL())})

  // A frame of Prism's page, of its own origin, which the page allows the
  // camera and the microphone. Prism's page names no permissions policy of
  // its own: what refuses here is the app's.
  await js(w.webContents, `new Promise((done) => { const f = document.createElement("iframe"); f.id = "proof-frame"; f.name = "proof-frame";
    f.allow = "camera; microphone"; f.srcdoc = "<p>a frame</p>"; f.onload = () => done(); document.body.appendChild(f) })`)

  // passkeys: both passkey calls, made in Prism's page and in its frame,
  // are refused by the permissions policy the app gives every content
  // document, before any authenticator is asked.
  const passkey = (where) => `(async () => { const w = ${where}; const c = new Uint8Array(32)
    // Where nothing refuses the call it waits on an authenticator the
    // content window has none of: no answer within the bound is no refusal.
    const bound = new Promise((done) => setTimeout(() => done("no answer"), 10000)) // sleep-ok: a bound on a call that may never answer
    const r = (p) => Promise.race([p.then(() => "allowed", (e) => e.name + ": " + e.message), bound])
    return [await r(w.navigator.credentials.get({publicKey: {challenge: c, rpId: location.hostname, timeout: 3000, userVerification: "discouraged"}})),
      await r(w.navigator.credentials.create({publicKey: {challenge: c, rp: {name: "proof", id: location.hostname},
        user: {id: c.slice(0, 16), name: "proof", displayName: "proof"}, pubKeyCredParams: [{type: "public-key", alg: -7}], timeout: 3000}}))] })()`
  const calls = {page: await js(w.webContents, passkey("window")), frame: await js(w.webContents, passkey(`document.querySelector("#proof-frame").contentWindow`))}
  const policy = await js(w.webContents, `(() => { const p = (d) => ["publickey-credentials-get", "publickey-credentials-create"]
    .map((f) => d.featurePolicy.allowsFeature(f)); return {page: p(document), frame: p(document.querySelector("#proof-frame").contentDocument)} })()`)
  const byPolicy = (answers) => /^NotAllowedError: .*'publickey-credentials-get' feature is not enabled/.test(answers[0]) &&
    /^NotAllowedError: .*'publickey-credentials-create' feature is not enabled/.test(answers[1])
  row("passkeys", byPolicy(calls.page) && byPolicy(calls.frame) && [...policy.page, ...policy.frame].every((a) => a === false),
    "both passkey calls, in Prism's page and in its frame, are refused by the app's permissions policy", {calls, policy})

  // media: the camera and the microphone, there to grant (media_control),
  // are refused to Prism's page and to its frame.
  const media = {page: await js(w.webContents, ask("window")),
    frame: await js(w.webContents, ask(`document.querySelector("#proof-frame").contentWindow`))}
  row("media", [...media.page, ...media.frame].every((m) => m === "NotAllowedError"),
    "the camera and the microphone are refused to Prism's page and to its frame", media)

  // navigation: each request below is one Prism's page and the frame's
  // own rules let through, so main's decision, read on its event, is what
  // refuses it: the top frame sent elsewhere, a window opened elsewhere,
  // the frame sent to the CYFR's company sign-in, and the frame sending
  // the top frame on, asked from inside the frame (the engine's initiator
  // is the frame).
  const opened = await js(w.webContents, `window.open(${literal(DIRECTORY + "/")}) === null`)
  const windowAnswer = (await waitFor(() => decisions.find((d) => d.window === w.webContents.id && d.name === "window-open" &&
    d.url === DIRECTORY + "/"), "main's decision on the window asked for elsewhere")).action
  const away = DIRECTORY + "/account/devices"
  await js(w.webContents, `location.href = ${literal(away)}; "asked"`)
  const awayPrevented = await decided(w.webContents, away, false, "main's decision on the top frame sent elsewhere")
  const xBefore = (await seen("x.test")).length
  const frame = (name) => w.webContents.mainFrame.frames.find((f) => f.name === name)
  const companyAsked = await frame("proof-frame").executeJavaScript(`location.href = ${literal(HOME + "/company-login")}; "asked"`, true)
  const companyPrevented = await decided(w.webContents, HOME + "/company-login", true, "main's decision on the frame sent to the company sign-in")
  const fromFrame = HOME + "/?from=frame"
  const topAsked = await frame("proof-frame").executeJavaScript(`top.location.href = ${literal(fromFrame)}; "asked"`, true)
  const topPrevented = await decided(w.webContents, fromFrame, false, "main's decision on the frame sending the top frame on")
  const company = (await reachedSince("x.test", xBefore)).filter((r) => r.path === "/company-login").length
  const nav = {opened, windowAnswer, awayPrevented, companyAsked, companyPrevented, company,
    topAsked, topPrevented, showing: bare(w.webContents.getURL())}
  row("navigation", opened && windowAnswer === "deny" && awayPrevented && companyAsked === "asked" && companyPrevented && company === 0 &&
    topAsked === "asked" && topPrevented && atHome(w.webContents.getURL()),
    "main refuses the top frame elsewhere, a window elsewhere, a frame at the company sign-in and a frame moving the top frame", nav)

  // confirm: an API key asked for in Prism waits on a confirmation on this
  // device, in a window of the device's own, with the passphrase again.
  const segment = await js(w.webContents, `(() => { const a = [...document.querySelectorAll("a[href^='/a/']")][0];
    return a ? a.getAttribute("href").split("/")[2] : null })()`)
  await js(w.webContents, `location.assign(${literal(`/a/${segment}/api-keys`)})`)
  await waitFor(() => w.webContents.getURL().includes("/api-keys") && js(w.webContents, `!!document.querySelector(".phx-connected")`),
    "the API keys page")
  // prism_frame_rules: a frame Prism serves (a canvas, /_c/v1/) asking for
  // a window or for the top frame gets neither. Prism's own sandbox on
  // that frame refuses both, as the engine answers the frame at once; this
  // row shows the app keeps Prism's refusal, not a refusal of its own.
  const canvas = await waitFor(() => w.webContents.mainFrame.framesInSubtree.find((f) => f.url.includes("/_c/v1/")), "a frame Prism serves")
  const childrenBefore = appWindows().length
  const canvasAsked = await canvas.executeJavaScript(`(() => { let w; try { w = window.open(${literal(LOOPBACK + "/confirm?ref=cnr_proof")}) }
    catch (e) { return "threw " + e.name } return w === null ? "null" : "a window" })()`, true)
  const canvasTop = await canvas.executeJavaScript(`(() => { try { top.location.href = ${literal(HOME + "/?from=canvas")} }
    catch (e) { return "threw " + e.name } return "asked" })()`, true)
  const prismFrame = {asked: canvasAsked, top: canvasTop, windows: appWindows().length - childrenBefore,
    reached: decisions.some((d) => d.url === HOME + "/?from=canvas")}
  row("prism_frame_rules", canvasAsked === "null" && canvasTop.startsWith("threw") && prismFrame.windows === 0 && !prismFrame.reached,
    "Prism's own frame rules hold in the app: its canvas frame is given no window and cannot move the top frame", prismFrame)

  await js(w.webContents, `[...document.querySelectorAll("button")].find((b) => b.textContent.includes("Create Key")).click()`)
  await waitFor(() => js(w.webContents, `!!document.querySelector('#api-key-form input[name="name"]')`), "the key's form")
  await js(w.webContents, `(() => { const i = document.querySelector('#api-key-form input[name="name"]'); i.value = "desktop-proof";
    i.dispatchEvent(new Event("input", {bubbles: true})); document.querySelector('#api-key-form button[type="submit"]').click() })()`)
  await waitFor(() => js(w.webContents, `!!document.querySelector('[data-test="confirm-device"]')`), "Confirm on this device")
  await js(w.webContents, `document.querySelector('[data-test="confirm-device"]').click()`)
  const confirm = await waitFor(() => appWindows().find((x) => x.getParentWindow() === w && x.webContents.getURL().startsWith(LOOPBACK + "/confirm")),
    "the device's confirmation window")
  const confirmForm = () => js(confirm.webContents, `!!document.querySelector('form[action="/confirm/decide"]')`)
  await waitFor(confirmForm, "the confirmation page")
  // A wrong passphrase first: refused, the same confirmation asked again,
  // and no key shown in Prism.
  const loads = () => history.length
  const loadsBefore = loads()
  await submit(confirm.webContents, "/confirm/decide", {secret: passphrase + " wrong"}, 'button[value="confirm"]')
  const wrong = await waitFor(async () => loads() > loadsBefore && !confirm.webContents.isLoading() && await confirmForm() &&
    js(confirm.webContents, `document.querySelector(".notice")?.textContent.trim() || null`), "the wrong passphrase's refusal")
  const keyAfterWrong = (await text(w.webContents)).includes("It will not be shown again")
  await submit(confirm.webContents, "/confirm/decide", {secret: passphrase}, 'button[value="confirm"]')
  const shownKey = await waitFor(async () => (await text(w.webContents)).includes("It will not be shown again"), "the key shown")
  row("confirm", !!wrong && !keyAfterWrong && shownKey,
    "a key asked for in Prism waits on this device's own window: a wrong passphrase is refused and asked again, the right one confirms it",
    {wrong, keyAfterWrong, child: confirm.isDestroyed() ? "closed" : bare(confirm.webContents.getURL())})

  // The lock rows. On this road cyfr's lock also retires the session
  // through the device's channel, so the cookie refused afterwards does
  // not tell which retired it; the sign-out's own acknowledgement, read
  // at the CYFR's front, shows main's sign-out ran and was confirmed. The
  // passkey road, with no device channel, shows the sign-out alone
  // retiring the session.

  // lock: the device's Lock in Prism's top bar.
  let out = await lockedOut(w, "the device's Lock", () => js(w.webContents, `document.querySelector('[data-test="device-lock"]').click()`))
  row("lock", signedOut(out),
    "the device's Lock closes Prism; main's sign-out of a session that opened a page is acknowledged, and its cookie opens nothing", lockDetail(out))

  // reconnect: unlocked again with the passphrase, a new session.
  const start = await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")
  const renewed = await sessionCookie(w)
  row("reconnect", start[0] === "locked" && !!renewed && renewed !== out.cookie,
    "the lock left the device locked; its passphrase opens Prism again under a new session", {start})

  // system_lock: the computer's lock closes Prism at once, before anything
  // is awaited, and signs its session out.
  const prism = w
  out = await lockedOut(w, "the computer's lock", async () => {
    powerMonitor.emit("lock-screen")
    row("system_lock_at_once", prism.isDestroyed(), "the computer's lock closes Prism's window at once", {})
  })
  row("system_lock", signedOut(out),
    "after the computer's lock main's sign-out is acknowledged and the cookie that opened a page opens nothing", lockDetail(out))
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // offline_lock: with the CYFR's front down (its control answered so),
  // the lock still closes Prism and the chooser says the sign-out is
  // unconfirmed.
  // Over the chooser keeping that notice: a second lock, as a computer
  // that locks and then sleeps sends, and a reload of it, as Ctrl+R does.
  const over = [async () => powerMonitor.emit("suspend"), async (chooser) => {
    const loaded = new Promise((resolve) => chooser.webContents.once("did-finish-load", resolve))
    chooser.webContents.reload()
    await loaded
  }]
  out = await lockedOut(w, "a lock while the CYFR is unreachable", async () => {
    await fault("x.test", "down")
    powerMonitor.emit("lock-screen")
  }, () => fault("x.test", "none"), over)
  row("offline_lock", out.before.opens && out.chooser.told?.words === UNCONFIRMED && out.chooser.told.stayed &&
    out.signOuts.every((r) => r.fault === "down"),
  "a lock while the CYFR cannot be reached closes Prism, and the chooser stays with the words that the sign-out is unconfirmed until the person goes on",
  lockDetail(out))
  // notice_kept: neither that second lock nor that reload erased what
  // nobody had yet gone on from. That going on clears it is renderer_killed's
  // to show, whose confirmed lock then goes on by itself.
  row("notice_kept", out.chooser.kept.length === over.length && out.chooser.kept.every((told) => told?.words === UNCONFIRMED && told.stayed),
    "a second lock and a reload over the chooser that is keeping a notice leave the notice there", {kept: out.chooser.kept})
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // renderer_killed: Prism's page's process ended by the kill signal, as
  // the kernel ends one when memory runs out: the engine reports the page
  // gone, the app locks at once, and its sign-out is acknowledged.
  const killed = {pid: w.webContents.getOSProcessId()}
  out = await lockedOut(w, "Prism's page's process killed", async () => {
    const prism = w
    const start = Date.now()
    prism.webContents.once("render-process-gone", (_e, details) => {
      // Main's own handler ran first (it was added as the window was made).
      Object.assign(killed, {reason: details.reason, reportedMs: Date.now() - start, closedAtOnce: prism.isDestroyed()})
    })
    log(`killing the renderer of window ${prism.webContents.id}, pid ${killed.pid}`)
    process.kill(killed.pid, "SIGKILL")
  })
  row("renderer_killed", killed.reason === "killed" && killed.closedAtOnce && said.includes("locked: the page stopped") && signedOut(out),
    "Prism's page's process killed: the engine reports it gone, the app closes Prism at once and its sign-out is acknowledged",
    {...lockDetail(out), killed})
  await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")

  // The forced crash, recorded and not asserted (../README.md): the
  // engine's own crash of Prism's page, which on some machines begins and
  // does not finish, so that the engine reports nothing. The record keeps
  // whether and when the engine reported the page gone; when it did not
  // within 15 s, the process's state and this machine's core pattern, and
  // then the proof ends that process itself and goes on.
  record.forcedCrash = await forcedCrash(w)
  log(`forced crash: ${JSON.stringify(record.forcedCrash)}`)
  await openCYFR(await contentAt(atDevice, "the device's pages after the forced crash"), passphrase)
  w = await contentAt(atHome, "Prism again")

  // process_loss: cyfr killed while Prism holds a session: the app closes
  // its content for good, signs the session out, confirmed, and says why.
  const cookie = await sessionCookie(w)
  const before = await opens(cookie)
  const from = (await seen("x.test")).length
  process.kill(childOfThis("desktop-serve"), "SIGKILL")
  const message = await waitFor(() => appWindows().find((x) => x.webContents.getURL().startsWith("data:")), "the app's message")
  const told = decodeURIComponent(message.webContents.getURL())
  const signOuts = (await reachedSince("x.test", from)).filter((r) => r.method === "POST" && r.path === "/auth/logout")
    .map((r) => ({status: r.status, retired: r.retired}))
  const after = await opens(cookie)
  row("process_loss", before.opens && told.includes("CYFR stopped") && !told.includes("did not confirm") && !content() &&
    signOuts.length === 1 && signOuts[0].retired === "1" && refused(after),
  "cyfr's loss while Prism holds a session closes the content, signs it out, confirmed, and tells the person",
  {told: told.replace(/^.*<p>/, "").replace(/<\/p>$/, ""), before, after, signOuts})
}

// The engine's forced crash of window `w`'s page, and what followed.
async function forcedCrash(w) {
  const wc = w.webContents
  const pid = wc.getOSProcessId()
  const start = Date.now()
  const gone = new Promise((resolve) => wc.once("render-process-gone", (_e, details) =>
    resolve({reason: details.reason, afterMs: Date.now() - start})))
  const within = (ms) => Promise.race([gone, sleep(ms).then(() => null)]) // sleep-ok: how long the record waits on the engine's report
  wc.forcefullyCrashRenderer()
  const reported = await within(15_000)
  if (reported) return {pid, reported}
  const state = processState(pid)
  try {
    process.kill(pid, "SIGKILL")
  } catch (e) {
    return {pid, reported: null, state, machine: machine(), killed: e.code}
  }
  return {pid, reported: null, state, machine: machine(), afterKill: await within(15_000)}
}

// What a Connect in the chooser `w` led to: the question about an
// account service, or the device's pages without one.
async function connected(w) {
  await submitConnect(w.webContents)
  return waitFor(async () => {
    const c = content()
    if (!c || c.webContents.isLoading()) return null
    if (atDevice(c.webContents.getURL())) return {next: "the device's pages"}
    if (!atBootstrap(c.webContents.getURL())) return null
    return js(c.webContents, `document.querySelector("#confirm").hidden ? null :
      ({next: "asked", home: document.querySelector("#home").textContent, service: document.querySelector("#service").textContent})`)
  }, "the device's pages or a question")
}

// remembered: launched again, the account service this computer approved
// for the CYFR is not asked about again; Connect opens the device's pages.
async function rememberedPhase() {
  const next = await connected(await chooserWindow())
  row("remembered", next.next === "the device's pages", "launched again, the CYFR's approved account service is not asked about again", next)
}

// changed: the CYFR now names another account service (its front
// rewrites the account directory its sign-in page names): Connect asks
// about that one though the earlier was approved, and the earlier
// approval has ended: named again, it is asked about again.
async function changedPhase() {
  const w = await chooserWindow()
  await fault("x.test", "directory", {directory: OTHER_DIRECTORY})
  const other = await connected(w)
  row("directory_changed", other.next === "asked" && other.service === OTHER_DIRECTORY,
    "a CYFR that names another account service than the one approved is asked about afresh", other)
  await js(w.webContents, `document.querySelector("#decline").click()`)
  await waitFor(() => js(w.webContents, `document.querySelector("#notice").textContent || null`), "the decline")
  await fault("x.test", "none")
  const dirBefore = (await seen("dir.test")).length
  const back = await connected(w)
  const reached = (await reachedSince("dir.test", dirBefore)).length
  row("approval_ended", back.next === "asked" && back.service === DIRECTORY && reached === 0,
    "once the CYFR named another, the earlier approval has ended: named again, it is asked about again, and nothing reached it", {...back, reached})
}

run("connect", {connect: connectPhase, remembered: rememberedPhase, changed: changedPhase})
