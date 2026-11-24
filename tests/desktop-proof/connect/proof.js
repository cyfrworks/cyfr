// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The six-word road against a real CYFR (../README.md), on the proofs'
// shared entry (../lib.js). The app is launched three times: `connect`,
// the road itself, then `remembered` and `changed`, which read the
// account service this computer approved.

import {fromCause, processLoss} from "../bound.mjs"
import {DIRECTORY, HOME, LOOPBACK, NAME, appWindows, arm, childOfFrame, atBootstrap, atDevice, atHome, bare, childOfThis, chooserWindow, content, contentAt, decided, decisions, fault, frontLength, afterLock, closedAtLock, harvest, history, historyAtLock, inputs, js, judged, literal, load, lockDetail, lockedOut, log, machine, openCYFR, opens, pageKilled, processState, question, reachedSince, record, refused, reloaded, row, run, secondClient, section, seen, sessionCookie, shownAgain, signOutsSince, signedOutOnward, sleep, submit, submitConnect, text, throughComputerLock, toldUnanswered, unansweredLoad, undisturbed, waitFor} from "../lib.js"

// An account service the CYFR names once reconfigured (the front's
// directory fault); nothing answers at it.
const OTHER_DIRECTORY = "https://other.test"
// How long a session may outlive its device's channel.
const ONE_MINUTE = 60_000

// The answer refusing session cookie `value`, or null while it still opens.
async function refusalOf(value) {
  const answer = await opens(value)
  return refused(answer) ? answer : null
}

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

  // chooser: the app's first page, with nothing to tell and, on this
  // road, no passkey.
  let w = await contentAt(atBootstrap, "the chooser")
  const chooser = await waitFor(async () => {
    const c = await js(w.webContents, `({choose: !document.querySelector("#choose").hidden, notice: document.querySelector("#notice").textContent,
      ways: ["#passkey"].filter((id) => document.querySelector(id).getClientRects().length > 0)})`)
    return c.choose ? c : null
  }, "the chooser")
  row("chooser", chooser.notice === "" && chooser.ways.length === 0,
    "the app opens at Connect to a CYFR, with nothing to tell", chooser)

  // custom_directory: an account service other than cyfr.run is shown
  // whole and asked about.
  const dirBefore = (await seen("dir.test")).length
  await submitConnect(w.webContents)
  const asked = await question(w.webContents)
  row("custom_directory", asked.home === HOME && asked.service === DIRECTORY,
    "a CYFR on another account service than cyfr.run shows it whole and asks about it", asked)
  await js(w.webContents, `document.querySelector("#decline").click()`)
  const declined = await waitFor(() => js(w.webContents, `document.querySelector("#notice").textContent || null`), "the decline")

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
  // camera and the microphone. Prism's own permissions policy leaves both
  // to its origin and names neither passkey call: what refuses here is the
  // app's.
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
  const confirm = await waitFor(() => appWindows().find((x) => childOfFrame(x) && x.webContents.getURL().startsWith(LOOPBACK + "/confirm")),
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

  // lock: the device's Lock in Prism's top bar. cyfr's lock ends the
  // session through the device's channel; the app posts no sign-out.
  let out = await lockedOut(w, "the device's Lock", () => js(w.webContents, `document.querySelector('[data-test="device-lock"]').click(); 1`))
  row("lock", signedOutOnward(out) && out.signOuts.length === 0 && out.left === null,
    "the device's Lock closes Prism, the session that opened a page opens nothing, and the app forgot it", lockDetail(out))

  // reconnect: unlocked again with the passphrase, a new session.
  const start = await openCYFR(out.back, passphrase)
  w = await contentAt(atHome, "Prism again")
  await waitFor(() => js(w.webContents, `!!document.querySelector(".phx-connected")`), "Prism's page connected")
  const renewed = await sessionCookie(w)
  row("reconnect", start[0] === "locked" && !!renewed && renewed !== out.cookie,
    "the lock left the device locked; its passphrase opens Prism again under a new session", {start})

  // computer_lock: the computer's lock and sleep are not the app's.
  const through = await throughComputerLock(w)
  row("computer_lock", undisturbed(through),
    "the computer's lock and sleep leave Prism open under the same session", through)

  // renderer_killed: Prism's page's process ended by the kill signal: the
  // page is shown again, in its window and under its session.
  const killed = await pageKilled(w)
  row("renderer_killed", shownAgain(killed),
    "Prism's page's process killed: the page is shown again in its window, signed in as before", killed)

  // unanswered, opened_again: a page of the CYFR that did not load gives
  // way to the chooser, and its way on opens Prism with the device unlocked
  // all along.
  await judged("unanswered",
    "a page of the CYFR that did not load gives way to the chooser in the same window, naming the CYFR, the device's session as it was",
    async () => {
      const {cookie, ...detail} = await unansweredLoad(w)
      return [toldUnanswered({cookie, ...detail}, false), detail]
    })
  await judged("opened_again",
    "the chooser's way on shows the device's unlocked page, and Open CYFR there opens Prism with no passphrase asked",
    async () => {
      await js(w.webContents, `document.querySelector("#words").click(); 1`)
      const reopenedPast = await openCYFR(w, passphrase)
      const reopened = await waitFor(async () => content() === w && js(w.webContents, `!!document.querySelector(".phx-connected")`),
        "Prism opened again", 30_000)
      return [JSON.stringify(reopenedPast) === '["unlocked"]' && reopened === true, {reopenedPast, reopened}]
    })

  // offline_lock: with the CYFR's front down (its control answered so) the
  // lock still closes Prism at once and, with nothing to tell, the chooser
  // goes on to the locked device's page; the session ends with the channel.
  let unreached
  await judged("offline_lock",
    "a lock while the CYFR cannot be reached closes Prism at once and goes on to the locked device's page, and the session ends with the channel",
    async () => {
      const offline = {cookie: await sessionCookie(w), from: await frontLength(),
        lockedBefore: closedAtLock.length}
      offline.before = await opens(offline.cookie)
      let ended, lockedPage
      try {
        await fault("x.test", "down")
        ended = fromCause(() => js(w.webContents, `document.querySelector('[data-test="device-lock"]').click(); 1`),
          () => refusalOf(offline.cookie), ONE_MINUTE)
        // The lock's own load of the CYFR fails before cyfr says locked: the
        // chooser that tells of it goes with the content the lock closes.
        await waitFor(() => closedAtLock.length > offline.lockedBefore, "main's lock")
        // The failure's chooser is in history before the lock and is not the lock's.
        unreached = await afterLock(historyAtLock[offline.lockedBefore], "a lock while the CYFR is unreachable")
        lockedPage = await waitFor(() => js(unreached.back.webContents, `!!document.querySelector('form[action="/unlock"]')`),
          "the locked device's page")
      } finally {
        await fault("x.test", "none")
      }
      const atOnce = closedAtLock.slice(offline.lockedBefore)
      const offlineEnded = await ended
      return [offline.before.opens && atOnce.length > 0 && atOnce.every(Boolean) && unreached.shown &&
        unreached.told === null && lockedPage && offlineEnded.within &&
        (await signOutsSince(offline.from)).length === 0,
      {before: offline.before, ended: offlineEnded, atOnce, chooser: unreached.told}]
    })
  await openCYFR(unreached.back, passphrase)
  w = await contentAt(atHome, "Prism again")
  await waitFor(() => js(w.webContents, `!!document.querySelector(".phx-connected")`), "Prism's page connected")

  // The forced crash, recorded and not asserted (../README.md): the
  // engine's own crash of Prism's page, which on some machines begins and
  // does not finish, so that the engine reports nothing. The record keeps
  // whether and when the engine reported the page gone; when it did not
  // within 15 s, the process's state and this machine's core pattern, and
  // then the proof ends that process itself and goes on.
  record.forcedCrash = await forcedCrash(w)
  log(`forced crash: ${JSON.stringify(record.forcedCrash)}`)

  // process_loss: cyfr killed while Prism holds a session: the app closes
  // its content for good and says why, posting no sign-out; the session
  // rested on cyfr's channel and ends with it, within one minute of the
  // kill: the refusal is looked for from the kill on, whenever the message
  // shows.
  const cookie = await sessionCookie(w)
  const before = await opens(cookie)
  const from = await frontLength()
  const child = childOfThis("desktop-serve")
  const {message, ended: sessionLost} = await processLoss({kill: () => process.kill(child, "SIGKILL"),
    message: () => waitFor(() => appWindows().find((x) => x.webContents.getURL().startsWith("data:")), "the app's message"),
    refusal: () => refusalOf(cookie)}, ONE_MINUTE)
  const told = decodeURIComponent(message.webContents.getURL())
  const signOuts = await signOutsSince(from)
  row("process_loss", before.opens && told.includes("CYFR stopped") && !/sign/.test(told.replace(/^.*<p>/, "")) && !content() &&
    signOuts.length === 0 && sessionLost.within,
  "cyfr's loss closes the content and tells the person; the device's session ends with its channel, with no sign-out of the app's",
  {told: told.replace(/^.*<p>/, "").replace(/<\/p>$/, ""), before, ended: sessionLost, signOuts})
}

// The engine's forced crash of window `w`'s page, and what followed.
async function forcedCrash(w) {
  const wc = w.webContents
  const pid = wc.getOSProcessId()
  const start = Date.now()
  const again = reloaded(w)
  const gone = new Promise((resolve) => wc.once("render-process-gone", (_e, details) =>
    resolve({reason: details.reason, afterMs: Date.now() - start})))
  const within = (ms) => Promise.race([gone, sleep(ms).then(() => null)]) // sleep-ok: how long the record waits on the engine's report
  wc.forcefullyCrashRenderer()
  const reported = await within(15_000)
  if (reported) {
    await again
    return {pid, reported}
  }
  const state = processState(pid)
  try {
    process.kill(pid, "SIGKILL")
  } catch (e) {
    await again
    return {pid, reported: null, state, machine: machine(), killed: e.code}
  }
  const afterKill = await within(15_000)
  await again
  return {pid, reported: null, state, machine: machine(), afterKill}
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
      ({next: "asked", home: document.querySelector("#named").textContent, service: document.querySelector("#service").textContent})`)
  }, "the device's pages or a question")
}

// remembered: launched again, the account service this computer approved
// for the CYFR is not asked about again; Connect opens the device's pages,
// which ask for the passphrase again: this road keeps no sign-in.
async function rememberedPhase() {
  const next = await connected(await chooserWindow())
  row("remembered", next.next === "the device's pages", "launched again, the CYFR's approved account service is not asked about again", next)
  const locked = await js(content().webContents, `!!document.querySelector('form[action="/unlock"]')`)
  row("asks_again", locked && !(await sessionCookie(content())),
    "launched again, the six-word road keeps no session and asks for the passphrase again", {locked})
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
