// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The passkey road against a real CYFR whose account service is another
// origin (../README.md), on the proofs' shared entry (../lib.js) and the
// account road's steps (../account.js). The app runs with the passkey road
// on, as on macOS and Windows; its account window gets a virtual
// authenticator standing in for this computer's platform authenticator.
// This computer's device is enrolled on the six-word road first: it is the
// trusted device that approves the passkey the account window makes.

import {BrowserWindow, powerMonitor} from "electron"

import {accountAndDevice, accountAt, accountWindow, answerWith, armWindow, devicePrism, held,
  offered, passkeyFor, signedInPrism, startSignIn, toSignIn, usePasskey} from "../account.js"
import {DIRECTORY, HOME, LOOPBACK, NAME, appWindows, arm, atDevice, bare, content, contentAt, decided, decisions, fault,
  harvest, inputs, js, literal, load, lockDetail, lockedOut, opens, passkeys, reachedSince, row, run, section, seen,
  sessionCookie, signedOut, submit, waitFor} from "../lib.js"

const OTHER = "desk-b"

// The refusal the app's policy gives both passkey calls in a document.
const policyRefuses = (answers) => /^NotAllowedError: .*'publickey-credentials-get' feature is not enabled/.test(answers[0]) &&
  /^NotAllowedError: .*'publickey-credentials-create' feature is not enabled/.test(answers[1])

// Both passkey calls, made in `where` (a window expression) of the page in
// `wc`, each bounded: no answer within the bound is no refusal.
const bothCalls = (wc, where) => js(wc, `(async () => { const w = ${where}; const c = new Uint8Array(32)
  const bound = new Promise((done) => setTimeout(() => done("no answer"), 10000))
  const r = (p) => Promise.race([p.then(() => "allowed", (e) => e.name + ": " + e.message), bound])
  return [await r(w.navigator.credentials.get({publicKey: {challenge: c, rpId: location.hostname, timeout: 3000, userVerification: "discouraged"}})),
    await r(w.navigator.credentials.create({publicKey: {challenge: c, rp: {name: "proof", id: location.hostname},
      user: {id: c.slice(0, 16), name: "proof", displayName: "proof"}, pubKeyCredParams: [{type: "public-key", alg: -7}], timeout: 3000}}))] })()`)

// The account page's error in `a`, once shown.
const askError = (a) => waitFor(() => js(a.webContents, `document.querySelector("#ask-error")?.textContent.trim() || null`), "the account page's error")

// The codes of the keys @NAME's account's log adds, read from the
// directory by the second client, whose page is the directory's own: a
// key's code is the first 16 hex digits of its kid.
const addedKeys = (second) => js(second, `(async () => {
  const get = async (at) => {
    const r = await fetch(at, {cache: "no-store"})
    if (r.status !== 200) throw new Error("the directory answered " + r.status)
    return r.json()
  }
  const {identifier} = await get(${literal(`${DIRECTORY}/v1/handles/${NAME}`)})
  const codes = []
  for (let after = null; ;) {
    const page = await get(${literal(`${DIRECTORY}/directory/v1/`)} + identifier + (after === null ? "" : "?after=" + after))
    for (const entry of page.entries) if (entry.kind === "add_key") codes.push(entry.key.kid.replace("sha256:", "").slice(0, 16))
    if (page.next === null || page.next === undefined) return codes
    after = page.next
  }
})()`)

async function passkeyPhase() {
  // The account @desk-a made and the CYFR set up on the second client;
  // this computer's device enrolled on the six-word road; and a second
  // account, @desk-b, whose passkey this computer will also hold.
  const {second, passphrase, recovery} = await accountAndDevice(inputs)
  let w = await signedInPrism()
  row("device", true, "this computer's device is enrolled on the six-word road and opens Prism", {})
  const beforeOther = new Set(passkeys.keys())
  await load(second, `${DIRECTORY}/account/new#name=${OTHER}`)
  await arm()
  await section(second, ["choose"])
  await js(second, `document.querySelector("#name").value = ${literal(OTHER)};
    document.querySelector("#name").dispatchEvent(new Event("input", {bubbles: true}));
    const a = document.querySelector("#acceptance:not([hidden]) #accept"); if (a) a.click();
    document.querySelector("#create").click(); 1`)
  await section(second, ["show-code"])
  await js(second, `document.querySelector("#saved").click(); 1`)
  await section(second, ["done", "done-return"])
  await harvest()
  const otherPasskeys = [...passkeys.values()].filter((c) => !beforeOther.has(c.credentialId))

  // The sign-in page, signed out: the device locked.
  powerMonitor.emit("lock-screen")
  await contentAt(atDevice, "the device's pages after the lock")
  w = await toSignIn()

  // passkeys_policy: with an authenticator that holds a passkey for the
  // CYFR in the content window, both passkey calls are refused by the app's
  // policy in the CYFR's page and in a frame of it, before any
  // authenticator is asked.
  await armWindow(w, [passkeyFor(new URL(HOME).hostname)])
  await js(w.webContents, `new Promise((done) => { const f = document.createElement("iframe"); f.id = "proof-frame";
    f.srcdoc = "<p>a frame</p>"; f.onload = () => done(); document.body.appendChild(f) })`)
  const calls = {page: await bothCalls(w.webContents, "window"),
    frame: await bothCalls(w.webContents, `document.querySelector("#proof-frame").contentWindow`)}
  row("passkeys_policy", policyRefuses(calls.page) && policyRefuses(calls.frame),
    "with a usable authenticator in the content window, both passkey calls in the CYFR's page and its frame are refused by the app's policy", calls)

  // no_passkey: the hop opens the app's account window at the account
  // service; with no passkey on this computer the page says so and offers
  // to make one.
  w = await toSignIn()
  let a = await startSignIn(w)
  const hop = {account: new URL(a.webContents.getURL()).origin, content: bare(content().webContents.getURL())}
  await armWindow(a, [])
  await usePasskey(a)
  const none = await askError(a)
  const offer = await waitFor(() => js(a.webContents, `!document.querySelector("#ways").hidden && !document.querySelector("#offer-way").hidden`),
    "the offer to make a passkey")
  row("no_passkey", hop.account === DIRECTORY && none === "The passkey was not used. Try again when you are ready." && offer,
    "Sign in opens the app's account window at the account service; with no passkey there it says so and offers to make one", {hop, none})

  // offer: a passkey made in the account window for @desk-a; the answer
  // returns to the CYFR's sign-in page in the content window, which shows
  // the code to approve.
  await js(a.webContents, `document.querySelector("#offer-start").click(); 1`)
  await section(a.webContents, ["offer"])
  await js(a.webContents, `document.querySelector("#offer-name").value = ${literal(NAME)};
    document.querySelector("#offer-make").click(); 1`)
  w = await contentAt((u) => u.startsWith(HOME + "/login"), "the sign-in page with the answer")
  const waiting = await waitFor(() => js(w.webContents, `document.querySelector('[data-test="passkey-code"]')?.textContent.trim() || null`),
    "the code to approve")
  const made = [...held.values()].filter((c) => c.rpId === new URL(DIRECTORY).hostname)
  row("offer", /^[0-9a-f]{16}$/.test(waiting) && made.length === 1 && !accountWindow(),
    "a passkey made in the account window for @desk-a returns to the CYFR's sign-in page, which shows its code to approve", {waiting, made: made.length})

  // matched_code: on this computer's device, unlocked with its passphrase,
  // Prism's Your devices shows the same code; Approve opens the device's own
  // window, which shows it again and adds the passkey with the passphrase:
  // the account's log, without that key before, then holds it. That window
  // saying so, or closing, is no evidence of it.
  const listedBefore = await addedKeys(second)
  w = await devicePrism(passphrase)
  await js(w.webContents, `document.querySelector('[data-test="shell-devices"]').click(); 1`)
  const listed = await waitFor(() => js(w.webContents, `document.querySelector('[data-test="pairing-waiting-code"]')?.textContent.trim() || null`),
    "the passkey waiting in Your devices")
  await js(w.webContents, `document.querySelector('[data-test="pairing-approve"]').click(); 1`)
  const approve = await waitFor(() => appWindows().find((x) => x.getParentWindow() === w && x.webContents.getURL().startsWith(LOOPBACK + "/passkey")),
    "the device's approval window")
  await waitFor(() => js(approve.webContents, `!!document.querySelector('form[action="/passkey/decide"]')`), "the approval page")
  const shownThere = await js(approve.webContents, `document.querySelector("p.code")?.textContent.trim() || null`)
  await submit(approve.webContents, "/passkey/decide", {secret: passphrase}, 'button[value="approve"]')
  const added = await waitFor(async () => (await addedKeys(second)).includes(waiting), "the passkey in the account's log", 20_000)
    .catch(() => false)
  row("matched_code", listed === waiting && shownThere === waiting && !listedBefore.includes(waiting) && added,
    "the device's Prism and its own window show the same code, and with the passphrase the passkey is added to the account's log",
    {listed, shownThere, before: listedBefore.includes(waiting), added})

  // passkey_sign_in: locked, then signed in again with the new passkey
  // alone: the account window's assertion returns and Prism opens.
  powerMonitor.emit("lock-screen")
  await contentAt(atDevice, "the device's pages after the lock")
  answerWith(() => 0)
  w = await toSignIn()
  a = await startSignIn(w)
  await armWindow(a, made.map((c) => held.get(c.credentialId)))
  await usePasskey(a)
  w = await signedInPrism()
  const cookie = await sessionCookie(w)
  row("passkey_sign_in", !!cookie && offered.at(-1)?.length === 1 && !accountWindow(),
    "the new passkey signs in: the account window's assertion returns and Prism opens signed in", {offered: offered.at(-1)})

  // devices: Your devices lists this sign-in as a passkey with its
  // description.
  await js(w.webContents, `document.querySelector('[data-test="shell-devices"]').click(); 1`)
  const listedAs = await waitFor(() => js(w.webContents, `[...document.querySelectorAll('[data-test="pairing-client"]')].map((li) => ({
    name: li.querySelector('[data-test="pairing-client-name"]')?.textContent.trim(),
    holder: li.querySelector('[data-test="pairing-holder"]')?.textContent.trim()})).filter((c) => c.name === "Passkey")[0] || null`),
  "a passkey in Your devices")
  row("devices", listedAs.holder === "Signs in and confirms with your face, fingerprint or screen lock.",
    "Your devices lists the passkey and how it signs in", listedAs)
  await js(w.webContents, `location.assign(${literal(HOME + "/")}); 1`)
  w = await signedInPrism()

  // confirm: a key asked for in Prism is confirmed with the passkey: the
  // account window opens for the confirmation, and its answer returns in a
  // window of the content's session, which confirms it.
  const segment = await js(w.webContents, `(() => { const l = [...document.querySelectorAll("a[href^='/a/']")][0];
    return l ? l.getAttribute("href").split("/")[2] : null })()`)
  await js(w.webContents, `location.assign(${literal(`/a/${segment}/api-keys`)}); 1`)
  await waitFor(() => w.webContents.getURL().includes("/api-keys") && js(w.webContents, `!!document.querySelector(".phx-connected")`),
    "the API keys page")
  await js(w.webContents, `[...document.querySelectorAll("button")].find((b) => b.textContent.includes("Create Key")).click(); 1`)
  await waitFor(() => js(w.webContents, `!!document.querySelector('#api-key-form input[name="name"]')`), "the key's form")
  await js(w.webContents, `(() => { const i = document.querySelector('#api-key-form input[name="name"]'); i.value = "desktop-passkey";
    i.dispatchEvent(new Event("input", {bubbles: true})); document.querySelector('#api-key-form button[type="submit"]').click(); return 1 })()`)
  const confirmButton = `#system-layer-dialog [data-test="confirmation"][data-own="true"] [data-test="confirm-passkey"]`
  await waitFor(() => js(w.webContents, `!!document.querySelector(${literal(confirmButton)})`), "Confirm with a passkey")
  await js(w.webContents, `document.querySelector(${literal(confirmButton)}).click(); 1`)
  a = await accountAt(["ask"])
  const what = await js(a.webContents, `document.querySelector("#what").textContent.trim()`)
  await armWindow(a)
  await usePasskey(a)
  const shownKey = await waitFor(async () => (await js(w.webContents, `document.body.innerText`)).includes("It will not be shown again"),
    "the key shown")
  row("confirm", what === `Confirm a change at ${HOME}` && shownKey,
    "a key asked for in Prism is confirmed with the passkey in the account window, and Prism shows it", {what})

  // sign_out_alone: a lock signs the passkey's session out, acknowledged;
  // on this road there is no device channel, so the cookie that opened a
  // page before is refused by the sign-out alone.
  let out = await lockedOut(w, "the computer's lock", async () => powerMonitor.emit("lock-screen"))
  row("sign_out_alone", signedOut(out),
    "the computer's lock signs the passkey's session out, acknowledged, and with no device channel its cookie opens nothing after", lockDetail(out))

  // resume: the CYFR opens to no one after the lock: its pages send the
  // content to its sign-in, and a fresh assertion signs in again.
  await js(content().webContents, `location.assign(${literal(HOME + "/")}); 1`)
  w = await contentAt((u) => u.startsWith(HOME + "/login"), "the sign-in page after the lock")
  a = await startSignIn(await toSignIn())
  await armWindow(a)
  await usePasskey(a)
  w = await signedInPrism()
  const again = await sessionCookie(w)
  row("resume", !!again && again !== out.cookie && !(await opens(out.cookie)).opens,
    "after the lock the CYFR sends the content to its sign-in, and only a fresh assertion opens Prism", {})

  // choose_cancel: with two accounts' passkeys on this computer the app
  // offers both; Cancel signs no one in and the page says so; choosing
  // @desk-a signs in as @desk-a.
  out = await lockedOut(w, "the computer's lock", async () => powerMonitor.emit("lock-screen"))
  w = await toSignIn()
  a = await startSignIn(w)
  await armWindow(a, [...held.values(), ...otherPasskeys])
  answerWith((buttons) => buttons.length - 1)
  await usePasskey(a)
  const cancelled = await askError(a)
  const offeredBoth = offered.at(-1)
  answerWith((buttons) => buttons.findIndex((b) => b === `@${NAME}`))
  await usePasskey(a)
  w = await signedInPrism()
  const who = await js(w.webContents, `document.body.innerText.includes(${literal("@" + NAME)})`)
  row("choose_cancel", offeredBoth.length === 2 && offeredBoth.includes(`@${NAME}`) && offeredBoth.includes(`@${OTHER}`) &&
    cancelled === "The passkey was not used. Try again when you are ready." && who,
  "the app offers both accounts' passkeys; Cancel signs no one in, and choosing @desk-a signs in as @desk-a", {offered: offeredBoth, cancelled})

  // account_window: the account window holds the account service's sign-in
  // and recovery pages alone. A frame there is refused by main: the engine
  // reports, for that frame's address, the policy main adds to the page
  // (frame-src 'none'), beside and apart from the account service's own
  // policy, and nothing of the frame reaches the service. The CYFR's own
  // pages are refused at once, by navigation or by a redirect, and either
  // ends the ceremony.
  out = await lockedOut(w, "the computer's lock", async () => powerMonitor.emit("lock-screen"))
  a = await startSignIn(await toSignIn())
  const xFrom = (await seen(new URL(HOME).hostname)).length
  const frameURL = DIRECTORY + "/account/devices"
  const dirHost = new URL(DIRECTORY).hostname
  const dirFrom = (await seen(dirHost)).length
  await js(a.webContents, `(() => { window.proofRefused = []
    addEventListener("securitypolicyviolation", (e) => proofRefused.push({policy: e.originalPolicy, directive: e.effectiveDirective,
      blocked: e.blockedURI, disposition: e.disposition}))
    const f = document.createElement("iframe"); f.src = ${literal(frameURL)}; document.body.appendChild(f); return 1 })()`)
  const refusals = () => js(a.webContents, "window.proofRefused")
  const byMain = (r) => r.policy === "frame-src 'none'" && r.directive === "frame-src" && r.disposition === "enforce" && r.blocked === frameURL
  const frameRefused = await waitFor(async () => (await refusals()).some(byMain), "main's refusal of the frame's load", 20_000)
    .catch(() => false)
  const frame = {refusedByMain: frameRefused, refusals: await refusals(),
    reached: (await seen(dirHost)).slice(dirFrom).filter((r) => r.path === "/account/devices").length}
  const stillOpen = !!accountWindow()
  let account = {id: a.webContents.id}
  await js(a.webContents, `location.href = ${literal(HOME + "/")}; 1`)
  const homeRefused = await decided(account, HOME + "/", false, "main's decision on the CYFR's page in the account window")
  const endedByHome = await waitFor(() => !accountWindow(), "the ceremony ended")
  w = content()
  a = await startSignIn(await toSignIn())
  await fault(new URL(DIRECTORY).hostname, "redirect", {from: "/account/recover", to: HOME + "/"})
  account = {id: a.webContents.id}
  await js(a.webContents, `location.href = ${literal(DIRECTORY + "/account/recover")}; 1`)
  const redirectRefused = await waitFor(() => decisions.find((d) => d.window === account.id && d.name === "will-redirect" &&
    d.url === HOME + "/"), "main's decision on the redirect to the CYFR")
  const endedByRedirect = await waitFor(() => !accountWindow(), "the ceremony ended by the redirect")
  await fault(new URL(DIRECTORY).hostname, "none")
  const reachedX = (await reachedSince(new URL(HOME).hostname, xFrom)).filter((r) => r.path === "/").length
  row("account_window", frame.refusedByMain && frame.reached === 0 && stillOpen && homeRefused && endedByHome &&
    redirectRefused.prevented && endedByRedirect && reachedX === 0,
  "main refuses a frame's load in the account window, and the CYFR's own page by navigation and by redirect, either ending the ceremony",
  {frame, homeRefused, redirectRefused: redirectRefused.prevented, reachedX})

  // recovery: with no passkey on this computer, the recovery code adds one
  // in the account window's recovery page, which returns to the sign-in and
  // signs in with it.
  a = await startSignIn(await toSignIn())
  await armWindow(a, [])
  await usePasskey(a)
  await askError(a)
  await js(a.webContents, `document.querySelector("#recover-link").click(); 1`)
  await waitFor(() => new URL(a.webContents.getURL()).pathname === "/account/recover", "the recovery page")
  await section(a.webContents, ["enter"])
  await js(a.webContents, `document.querySelector("#code-input").value = ${literal(recovery)};
    document.querySelector("#enter-code").click(); 1`)
  await section(a.webContents, ["account"])
  await armWindow(a, [])
  const before = held.size
  await js(a.webContents, `document.querySelector("#passkey-name").value = ${literal(NAME)};
    document.querySelector("#add-passkey").click(); 1`)
  await waitFor(() => js(a.webContents, `!document.querySelector("#return").hidden`), "the way back to the sign-in")
  const fresh = [...held.values()].slice(before)
  await js(a.webContents, `document.querySelector("#return-link").click(); 1`)
  await section(a.webContents, ["ask"])
  await armWindow(a, fresh)
  answerWith(() => 0)
  await usePasskey(a)
  w = await signedInPrism()
  row("recovery", fresh.length === 1 && !!(await sessionCookie(w)),
    "the recovery code adds a passkey in the account window, which returns to the sign-in and signs in with it", {added: fresh.length})

  // wrong_window: an answer made for another browser's sign-in, given to
  // the content window, signs no one in: the CYFR binds it to the browser
  // that asked. This is the CYFR's binding holding in the app.
  out = await lockedOut(w, "the computer's lock", async () => powerMonitor.emit("lock-screen"))
  const other = await otherBrowserAnswer(fresh[0])
  await js(content().webContents, `location.assign(${literal(other)}); 1`)
  w = await contentAt((u) => u.startsWith(HOME + "/login"), "the sign-in page with the other browser's answer")
  const refusedAnswer = await waitFor(() => js(w.webContents, `document.querySelector('[data-test="sign-in-error"]')?.textContent.trim() || null`),
    "the sign-in's refusal")
  const visitor = await sessionCookie(w)
  const opened = visitor ? await opens(visitor) : {opens: false}
  row("wrong_window", /nobody was signed in|different browser/.test(refusedAnswer) && !opened.opens,
    "an answer made for another browser's sign-in signs no one in when given to the content window", {refusedAnswer, opened})
}

// The answer a browser of the proof's own (a fresh session, outside the
// app, holding @desk-a's passkey `credential`) got from the account service
// for its own sign-in at the CYFR, stopped before it reached the CYFR.
async function otherBrowserAnswer(credential) {
  const b = new BrowserWindow({show: true, width: 900, height: 700, webPreferences: {partition: "proof-other-browser"}})
  try {
    let answer = null
    b.webContents.on("will-navigate", (event) => {
      if (event.url.startsWith(HOME + "/login#")) {
        answer = event.url
        event.preventDefault()
      }
    })
    b.webContents.session.on("select-webauthn-account", (event, details, callback) => {
      event.preventDefault()
      callback(details.accounts.find((x) => x.name === `@${NAME}`)?.credentialId ?? null)
    })
    await b.loadURL(HOME + "/login")
    await waitFor(() => js(b.webContents, `!!document.querySelector(".phx-connected") && !!document.querySelector('[data-test="sign-in"]')`), "its sign-in")
    await js(b.webContents, `document.querySelector('[data-test="sign-in"]').click(); 1`)
    await waitFor(() => new URL(b.webContents.getURL()).pathname === "/account/sign", "its account page")
    await section(b.webContents, ["ask"])
    await armWindow(b, [credential])
    await js(b.webContents, `document.querySelector("#use-passkey").click(); 1`)
    return await waitFor(() => answer, "its answer")
  } finally {
    b.destroy()
  }
}

run("passkey", {passkey: passkeyPhase}, {accountRoad: true})
