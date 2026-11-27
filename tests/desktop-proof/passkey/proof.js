// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The passkey road against a real CYFR whose account service is another
// origin (../README.md), on the proofs' shared entry (../lib.js) and the
// account road's steps (../account.js). The app runs with the passkey road
// on, as on macOS and Windows; its account window gets a virtual
// authenticator standing in for this computer's platform authenticator.
// This computer's device is enrolled on the six-word road first: it is the
// trusted device that approves the passkey the account window makes.
//
// The app is launched four times: `passkey`, the road itself, killed right
// after a sign-in; `kept`, which is still signed in and then quits;
// `closed`, still signed in after that, and then cyfr is lost; `left`,
// still signed in after that, and then signed out, for another CYFR. The
// last two end as the system ends the app.

import {readFileSync, writeFileSync} from "node:fs"
import path from "node:path"

import {createHash} from "node:crypto"

import {BrowserWindow, session} from "electron"

import {accountAndDevice, accountAt, accountWindow, answerWith, armWindow, bothWays, devicePrism, held, lockDevice,
  offered, passkeyFor, signOutOfPrism, signedInPrism, startSignIn, toSignIn, usePasskey} from "../account.js"
import {DIRECTORY, HOME, LOOPBACK, NAME, OUT, appWindows, arm, childOfFrame, rail, atBootstrap, atHome, bare, childOfThis, content, contentAt, decided,
  decisions, fault, frontLength, harvest, history, inputs, js, judged, literal, load, lockDetail, opens, pageKilled, passkeys,
  reachedSince, refused, row, run, section, seen, sessionCookie, sessionMark, shownAgain, signOutsSince, signedOutToWays,
  submit, throughComputerLock, toldUnanswered, UNANSWERED, unansweredLoad, undisturbed, waitFor} from "../lib.js"

const OTHER = "desk-b"
// The session the first launch left, as its mark alone (sessionMark).
const SESSION = path.join(OUT, "passkey-session.json")

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

// A frame of `frameURL` made in the account window `a`'s page, and what
// the engine reported refused it: whether main's own policy (frame-src
// 'none') did, beside and apart from the account service's.
async function frameRefusal(a, frameURL) {
  await js(a.webContents, `(() => { window.proofRefused = []
    addEventListener("securitypolicyviolation", (e) => proofRefused.push({policy: e.originalPolicy, directive: e.effectiveDirective,
      blocked: e.blockedURI, disposition: e.disposition}))
    const f = document.createElement("iframe"); f.src = ${literal(frameURL)}; document.body.appendChild(f); return 1 })()`)
  const refusals = () => js(a.webContents, "window.proofRefused")
  const byMain = (r) => r.policy === "frame-src 'none'" && r.directive === "frame-src" && r.disposition === "enforce" && r.blocked === frameURL
  const refusedByMain = await waitFor(async () => (await refusals()).some(byMain), "main's refusal of the frame's load", 20_000)
    .catch(() => false)
  return {refusedByMain, refusals: await refusals()}
}

async function passkeyPhase() {
  // The account @desk-a made and the CYFR set up on the second client;
  // this computer's device enrolled on the six-word road; and a second
  // account, @desk-b, whose passkey this computer will also hold.
  const {second, passphrase, recovery} = await accountAndDevice(inputs)
  let w = await signedInPrism()
  // first_open: a CYFR just connected opens at its own root, which sends
  // who is not signed in to its sign-in page; main refuses that redirect,
  // and the chooser shows both ways on (connectApproved took one).
  const sent = decisions.find((d) => d.name === "will-redirect" && d.main && new URL(d.url).origin === HOME &&
    new URL(d.url).pathname === "/login")
  row("first_open", history.includes(HOME + "/") && !!sent?.prevented,
    "a CYFR just connected opens at its root; sent from there to sign in, the app shows both ways on", {sent})
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

  // device_lock: the device's Lock ends its session, which the app
  // forgets, and the chooser shows both ways on; its passkey button goes on
  // to the sign-in page.
  let out = await lockDevice(w)
  row("device_lock", signedOutToWays(out) && out.left === null && out.signOuts.length === 0,
    "the device's Lock ends its session, the app forgets it and the chooser shows both ways on", lockDetail(out))
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
  const approve = await waitFor(() => appWindows().find((x) => childOfFrame(x) && x.webContents.getURL().startsWith(LOOPBACK + "/passkey")),
    "the device's approval window")
  await waitFor(() => js(approve.webContents, `!!document.querySelector('form[action="/passkey/decide"]')`), "the approval page")
  const shownThere = await js(approve.webContents, `document.querySelector("p.code")?.textContent.trim() || null`)
  await submit(approve.webContents, "/passkey/decide", {secret: passphrase}, 'button[value="approve"]')
  const added = await waitFor(async () => (await addedKeys(second)).includes(waiting), "the passkey in the account's log", 20_000)
    .catch(() => false)
  row("matched_code", listed === waiting && shownThere === waiting && !listedBefore.includes(waiting) && added,
    "the device's Prism and its own window show the same code, and with the passphrase the passkey is added to the account's log",
    {listed, shownThere, before: listedBefore.includes(waiting), added})

  // lock_forgets: locked while a request of the page's, which outlives
  // it, is held until the lock is over: once the engine has received that
  // very request's 200 and ended it, no cookie is left, and the chooser
  // tells of no failure. How the engine ends a request whose page is gone
  // (completed, or aborted after its 200, as a loaded runner shows) is not
  // the row's claim; an end with no 200 received fails it. What a closing
  // page's scripts write is the app's own tests' (main.test): here those
  // writes end before the engine's clear does.
  await judged("lock_forgets", "a lock forgets all of the content's storage, and the closing page's request, answered afterwards, puts nothing back", async () => {
    const ses = w.webContents.session
    const held = HOME + "/login?held"
    let send = null
    let id = null
    let ended = null
    ses.webRequest.onBeforeRequest({urls: [held]}, (details, callback) => {
      id = details.id
      send = () => callback({})
    })
    const end = (how) => (details) => { if (details.id === id) ended = {how, status: details.statusCode ?? null, error: details.error ?? null} }
    ses.webRequest.onCompleted({urls: [held]}, end("completed"))
    ses.webRequest.onErrorOccurred({urls: [held]}, end("failed"))
    try {
      await js(w.webContents, `fetch(${literal(held)}, {keepalive: true}).catch(() => {}); 1`)
      await waitFor(() => send, "the page's request held")
      const locked = await lockDevice(w)
      send()
      send = null
      const answered = await waitFor(() => ended, "the engine's end of that request", 20_000)
      const left = (await ses.cookies.get({})).map((c) => `${c.name} at ${c.domain}`)
      return [signedOutToWays(locked) && answered.status === 200 && left.length === 0,
        {left, answered, chooser: locked.chooser}]
    } finally {
      send?.()
      for (const hook of ["onBeforeRequest", "onCompleted", "onErrorOccurred"]) ses.webRequest[hook](null)
    }
  })

  // passkey_sign_in: locked, then signed in again with the new passkey
  // alone: the account window's assertion returns and Prism opens.
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

  // computer_lock: the computer's lock and sleep are not the app's.
  const through = await throughComputerLock(w)
  row("computer_lock", undisturbed(through),
    "the computer's lock and sleep leave Prism open under the passkey's session", through)

  // sign_out: Prism's Sign out ends the passkey's session: the CYFR's
  // redirect to its sign-in page is refused and the chooser shows both
  // ways on; the one sign-out posted is the person's.
  out = await signOutOfPrism(w)
  row("sign_out", signedOutToWays(out) && out.signOuts.length === 1 && out.signOuts[0].status === 302,
    "Prism's Sign out ends the session, and the chooser shows both ways on", lockDetail(out))

  // signed_out_root: the CYFR opens to no one after that: the old cookie
  // is sent from its root to sign in; and the chooser, whose view keeps
  // nothing, loads no page of the CYFR (its sign-in is main's to open in
  // the CYFR's own view): main refuses the root there and the chooser
  // stays with the ways on.
  const root = HOME + "/"
  await js(out.back.webContents, `location.assign(${literal(root)}); 1`)
  const chooserRefused = await decided(out.back.webContents, root, false, "main's decision on the CYFR's root in the chooser")
  await bothWays()
  const oldCookie = await opens(out.cookie)
  row("signed_out_root", chooserRefused && refused(oldCookie),
    "after signing out the old cookie is sent from the CYFR's root to sign in, and the chooser loads no page of the CYFR", {chooserRefused, oldCookie})

  // sign_in_again: from the chooser's passkey button a fresh assertion
  // signs in again, under a new session.
  a = await startSignIn(await toSignIn())
  await armWindow(a)
  await usePasskey(a)
  w = await signedInPrism()
  const again = await sessionCookie(w)
  row("sign_in_again", !!again && again !== out.cookie && !(await opens(out.cookie)).opens,
    "after signing out only a fresh assertion opens Prism", {})

  // choose_cancel: with two accounts' passkeys on this computer the app
  // offers both; Cancel signs no one in and the page says so; choosing
  // @desk-a signs in as @desk-a.
  out = await signOutOfPrism(w)
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

  // account_unavailable: with the account service unreachable (its front
  // takes every connection down), the account window's page does not
  // load and main ends the hop, closing that window; the CYFR's sign-in
  // page stays as it was, and once the service answers again its Sign in
  // opens the account page, which no worker controls: in the app no
  // worker serves a stored copy (worker-src 'none').
  out = await signOutOfPrism(w)
  const service = new URL(DIRECTORY).hostname
  await judged("account_unavailable",
    "with the account service unreachable main closes the account window whose page did not load, the sign-in page stays, and once the service answers its Sign in opens the account page, no worker in it",
    async () => {
      const toService = await toSignIn()
      await fault(service, "down")
      const downFrom = (await seen(service)).length
      let closedByMain = false
      try {
        await js(toService.webContents, `document.querySelector('[data-test="sign-in"]').click(); 1`)
        await waitFor(async () => (await seen(service)).slice(downFrom).some((r) => r.path === "/account/sign"), "the account page asked for")
        closedByMain = await waitFor(() => !accountWindow(), "the account window closed by main", 30_000).catch(() => false)
      } finally {
        await fault(service, "none")
      }
      const asked = (await seen(service)).slice(downFrom).filter((r) => r.path === "/account/sign")
      const unanswered = asked.length > 0 && asked.every((r) => r.fault === "down" && r.status === null)
      const stays = content() === toService && toService.webContents.getURL().startsWith(HOME + "/login")
      await js(toService.webContents, `document.querySelector('[data-test="sign-in"]').click(); 1`)
      a = await accountAt(["ask"])
      const noWorker = await js(a.webContents, `!navigator.serviceWorker.controller`)
      a.close()
      await waitFor(() => !accountWindow(), "the account window closed")
      return [closedByMain && unanswered && stays && noWorker,
        {closedByMain, asked: asked.map((r) => ({status: r.status, fault: r.fault})), stays, noWorker}]
    })
  w = content()

  // account_window: the account window holds the account service's sign-in
  // and recovery pages alone. A frame there is refused by main: the engine
  // reports, for that frame's address, the policy main adds to the page
  // (frame-src 'none'), beside and apart from the account service's own
  // policy, and nothing of the frame reaches the service. The CYFR's own
  // pages are refused at once, by navigation or by a redirect, and either
  // ends the ceremony.
  a = await startSignIn(await toSignIn())
  const xFrom = (await seen(new URL(HOME).hostname)).length
  const frameURL = DIRECTORY + "/account/devices"
  const dirHost = new URL(DIRECTORY).hostname
  const dirFrom = (await seen(dirHost)).length
  const frame = {...await frameRefusal(a, frameURL),
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
  // the CYFR's sign-in page in the app (opened by the chooser's Sign in
  // with your passkey, in the CYFR's own view), signs no one in: the CYFR
  // binds it to the browser that asked. This is the CYFR's binding holding
  // in the app.
  out = await signOutOfPrism(w)
  const other = await otherBrowserAnswer(fresh[0])
  // The page reads an answer as it loads: given to the sign-in page showing,
  // the answer changes the fragment alone, so the page is loaded again
  // with it.
  const page = await toSignIn()
  await js(page.webContents, `location.assign(${literal(other)}); 1`)
  await waitFor(() => page.webContents.getURL() === other, "the other browser's answer in the address")
  page.webContents.reload()
  w = await contentAt((u) => u.startsWith(HOME + "/login"), "the sign-in page with the other browser's answer")
  const refusedAnswer = await waitFor(() => js(w.webContents, `document.querySelector('[data-test="sign-in-error"]')?.textContent.trim() || null`),
    "the sign-in's refusal")
  const visitor = await sessionCookie(w)
  const opened = visitor ? await opens(visitor) : {opens: false}
  row("wrong_window", /nobody was signed in|different browser/.test(refusedAnswer) && !opened.opens,
    "an answer made for another browser's sign-in signs no one in when given to the content window", {refusedAnswer, opened})

  // The last sign-in, and the app killed right after it: a cookie the
  // engine had not yet written would be lost with it.
  a = await startSignIn(await toSignIn())
  await armWindow(a, fresh.map((c) => held.get(c.credentialId) ?? c))
  await usePasskey(a)
  w = await signedInPrism()
  writeFileSync(SESSION, JSON.stringify(await sessionMark(w)))
  return "kill"
}

// The launch opened Prism by itself under the session the first launch
// left, nothing asked: the same cookie, its end where it was, so no later
// request renews it.
async function stillSignedIn(name, what) {
  const w = await signedInPrism()
  const [was, is] = [JSON.parse(readFileSync(SESSION, "utf8")), await sessionMark(w)]
  const opened = await opens(await sessionCookie(w))
  row(name, opened.opens && is.digest === was.digest && is.expires === was.expires && !accountWindow(), what, {was, is, opened})
  return w
}

async function keptPhase() {
  let w = await stillSignedIn("kept_after_kill",
    "killed right after a sign-in and launched again, the app opens Prism by itself, signed in as before")

  // renderer_killed: a lost page is shown again and signs nobody out.
  const killed = await pageKilled(w)
  row("renderer_killed", shownAgain(killed), "Prism's page's process killed: the page is shown again, signed in as before", killed)

  // kept_policy: the kept session's documents still carry the app's
  // passkey refusal.
  await armWindow(w, [passkeyFor(new URL(HOME).hostname)])
  const calls = await bothCalls(w.webContents, "window")
  row("kept_policy", policyRefuses(calls), "in a kept session too, both passkey calls in Prism's page are refused by the app's policy", {calls})

  // unanswered, try_again: a page of the CYFR that did not load gives way
  // to the chooser, and its Try again opens Prism on the same sign-in.
  let cookie
  await judged("unanswered",
    "a page of the CYFR that did not load gives way to the chooser in the same window, naming the CYFR and offering it again, signed in as before",
    async () => {
      const {cookie: kept, ...detail} = await unansweredLoad(w)
      cookie = kept
      return [toldUnanswered({cookie, ...detail}, true), detail]
    })
  // notice_kept: a reload over the chooser keeping that notice, as Ctrl+R
  // does, leaves the same words and the same Try again in the same view.
  await judged("notice_kept", "a reload over the chooser that is keeping a notice leaves the same words and its Try again there",
    async () => {
      const chooser = content()
      const loaded = new Promise((resolve) => chooser.webContents.once("did-finish-load", resolve))
      chooser.webContents.reload()
      await loaded
      const kept = await waitFor(() => js(chooser.webContents, `(() => { const inSight = (id) => {
        const e = document.querySelector(id); return !!e && e.getClientRects().length > 0 }
        return {words: inSight("#notice") ? document.querySelector("#notice").textContent : "",
          again: inSight("#again"), onward: inSight("#words")} })()`), "the chooser after its reload")
      const same = content() === chooser
      return [same && kept.words === UNANSWERED && kept.again && kept.onward, {...kept, same}]
    })
  // On the passkey road the chooser is in a view of its own, in memory;
  // Try again there opens the CYFR's root in a view of the CYFR's own
  // store, Prism shown again.
  let back = null
  await judged("try_again", "Try again asks cyfr, then for the CYFR's root, and Prism opens signed in as before, in the CYFR's own store", async () => {
    const pressedAt = history.length
    const frontAt = await frontLength()
    const chooser = content()
    // When the chooser asked cyfr, by the engine's loads made by then.
    let connectAt = null
    const ses = chooser.webContents.session
    ses.webRequest.onBeforeRequest({urls: [LOOPBACK + "/bootstrap/connect"]}, (_details, callback) => {
      connectAt ??= history.length
      callback({})
    })
    try {
      await js(chooser.webContents, `document.querySelector("#again").click(); 1`)
      back = await waitFor(async () => {
        const v = content()
        return v && v !== chooser && atHome(v.webContents.getURL()) && !v.webContents.isLoading() &&
          await js(v.webContents, `!!document.querySelector(".phx-connected")`) ? v : null
      }, "Prism after Try again", 30_000).catch(() => null)
    } finally {
      ses.webRequest.onBeforeRequest(null)
    }
    // What the retry asked for: the engine's first load of the CYFR after
    // the press, and that request at the front.
    const asked = history.slice(pressedAt).find((url) => !url.startsWith(LOOPBACK + "/")) ?? null
    const askedFirst = connectAt !== null && !history.slice(pressedAt, connectAt).some((url) => !url.startsWith(LOOPBACK + "/"))
    const answered = (await reachedSince(new URL(HOME).hostname, frontAt)).find((r) => r.method === "GET" && r.path === "/")?.status ?? null
    const own = !!back && back.webContents.session === keptSession()
    return [askedFirst && asked === HOME + "/" && answered !== null && own && cookie !== null && (await sessionCookie(back)) === cookie,
      {askedFirst, asked: asked && bare(asked), answered, back: !!back, own}]
  })
  await choosersWord(back)
  return "quit"
}

// What the chooser says on main's behalf is main's alone to decide.
// chooser_refused: Prism's page in `w` cannot send the window to the
// chooser with a notice, by a navigation or by a redirect of a load of the
// CYFR's, and its history holds no entry of the chooser's to go back to:
// on the passkey road the chooser showed the failure in a view of its own,
// and Try again opened the CYFR in a new view of the CYFR's own store. The
// redirect is the engine's answer in the CYFR's place (the session's
// request hook, which the app does not use): the front sends a load to
// https alone.
async function choosersWord(w) {
  const to = `${LOOPBACK}/bootstrap/#road=passkey&notice=unanswered`
  const hop = "/proof-chooser"
  await judged("chooser_refused",
    "Prism's page cannot send the window to the chooser, by a navigation or a redirect, and its history holds no chooser to go back to: main refuses each and the page stays",
    async () => {
      const wc = w.webContents
      await js(wc, "window.proofStays = true; 1")
      const from = history.length
      const before = decisions.length
      await js(wc, `location.assign(${literal(to)}); 1`)
      const navigated = await decided(wc, to, false, "main's decision on the page's load of the chooser")
      // Each decision ends the look where main allowed it: what follows
      // would be another page's.
      if (navigated !== true) return [false, {navigated}]
      let redirected
      wc.session.webRequest.onBeforeRequest({urls: [HOME + hop]}, (_details, callback) => callback({redirectURL: to}))
      try {
        await js(wc, `location.assign(${literal(hop)}); 1`)
        redirected = await waitFor(() => decisions.slice(before).find((d) => d.window === wc.id && d.name === "will-redirect" && d.main &&
          atBootstrap(d.url)), "main's decision on the redirect to the chooser", 30_000)
      } finally {
        wc.session.webRequest.onBeforeRequest(null)
      }
      if (redirected.prevented !== true) return [false, {navigated, redirected: redirected.prevented}]
      await waitFor(() => !wc.isLoading(), "the window at rest")
      const stayed = await js(wc, "window.proofStays === true")
      const entries = wc.navigationHistory.getAllEntries().map((e) => e.url)
      return [stayed === true && atHome(wc.getURL()) && entries.length > 0 && entries.every(atHome),
        {navigated, redirected: redirected.prevented, stayed, url: bare(wc.getURL()), entries: entries.map(bare), asked: history.slice(from).map(bare)}]
    })
}

async function closedPhase() {
  const w = await stillSignedIn("kept_after_quit", "quit and launched again, the app is still signed in")

  // process_loss: cyfr's loss closes the content and signs nobody out.
  const cookie = await sessionCookie(w)
  const from = await frontLength()
  process.kill(childOfThis("desktop-serve"), "SIGKILL")
  const message = await waitFor(() => appWindows().find((x) => x.webContents.getURL().startsWith("data:")), "the app's message")
  const told = decodeURIComponent(message.webContents.getURL()).replace(/^.*<p>/, "").replace(/<\/p>$/, "")
  const after = await opens(cookie)
  const signOuts = await signOutsSince(from)
  row("process_loss", told.startsWith("CYFR stopped") && !content() && after.opens && signOuts.length === 0,
    "cyfr's loss closes the content and tells the person, and signs nobody out", {told, after, signOuts})
  // system_quit_lost: the system ends the app that lost its cyfr.
  return {system: ["system_quit_lost",
    "ended by the system after cyfr's loss, the app quits, and never from inside the engine's before-quit"]}
}

async function leftPhase() {
  const w = await stillSignedIn("kept_after_loss", "launched again after cyfr's loss, the app is still signed in")

  // left: with marks of the proof's own in the CYFR's kept storage,
  // Connect on the rail leaves the CYFR open: the chooser's form shows, the
  // marks are still kept, and main keeps to that CYFR no more.
  await plant(w)
  const kept = keptSession()
  const planted = await storageOf(kept)
  await press("/rail/connect")
  const form = await chooserForm(w)
  const away = HOME + "/?from=left"
  await js(form.webContents, `location.assign(${literal(away)}); 1`)
  const leftRefused = await decided(form.webContents, away, false, "main's decision on the CYFR left")
  const still = await storageOf(kept)
  const marked = (got) => got.cookies.includes(MARK) && got.local === "kept"
  row("left", marked(planted) && marked(still) && leftRefused,
    "Connect on the rail leaves the CYFR open: its sign-in stays kept on this computer, and main keeps to it no more",
    {planted, still, leftRefused})

  // forget_unerased: while the engine cannot clear, Forget in the row's
  // menu, confirmed, leaves the CYFR on the rail as not forgotten, its
  // marks still there; forgot: forgotten again once it can, nothing of it
  // is kept and the rail lists it no more.
  answerWith((buttons) => buttons.indexOf("Forget"))
  await judged("forget_unerased", "Forget that could not erase leaves the CYFR on the rail, not forgotten, and its sign-in as it was", async () => {
    const failed = await unclearableSession(kept, async () => {
      await press("/rail/menu?cyfr=" + encodeURIComponent(HOME))
      return waitFor(() => railRow(HOME).then((r) => r?.failed ? r : null), "the rail's row not forgotten")
    })
    const unerased = await storageOf(kept)
    return [failed.failed && marked(unerased), {failed, unerased}]
  })
  await press("/rail/menu?cyfr=" + encodeURIComponent(HOME))
  await waitFor(() => railRow(HOME).then((r) => r ? null : true), "the rail without the CYFR")
  const gone = await storageOf(kept)
  row("forgot", gone.cookies.length === 0 && gone.local === null,
    "Forget again erases all this computer kept of the CYFR, and the rail lists it no more", {gone})
  // system_quit: the system ends the app at the chooser.
  return {system: ["system_quit",
    "ended by the system at the chooser, the app quits, and never from inside the engine's before-quit"]}
}

// The CYFR's kept content storage (src/policy.js homePartition).
const keptSession = () => session.fromPartition(`persist:cyfr-home-v2-${createHash("sha256").update(HOME, "ascii").digest("hex")}`)

// A press on the rail: its own top frame going to `path`, which main
// answers; a row's menu is answered by the proof's stand-in for the
// person (lib.js menuPicks), Forget first.
async function press(path) {
  const r = await waitFor(() => rail(), "the rail")
  await js(r.webContents, `location.assign(${literal(path)}); 1`)
}

// The rail's row of the CYFR at `address`, as the rail shows it, or null.
async function railRow(address) {
  const r = rail()
  if (!r) return null
  return js(r.webContents, `(() => { const a = [...document.querySelectorAll("#cyfrs a")].find((x) => x.title === ${literal(address)})
    return a ? {failed: a.classList.contains("failed"), forgetting: a.classList.contains("gone")} : null })()`)
}

// The chooser's form in a content other than `before`.
function chooserForm(before) {
  return waitFor(async () => {
    const at = content()
    if (!at || at === before || at.webContents.isLoading() || !atBootstrap(at.webContents.getURL())) return null
    return await js(at.webContents, `document.querySelector("#address").getClientRects().length > 0`) ? at : null
  }, "the chooser's form")
}

// `act` done while the engine cannot clear `ses`.
async function unclearableSession(ses, act) {
  const own = ses.clearStorageData
  ses.clearStorageData = () => Promise.reject(new Error("the proof: nothing can be cleared"))
  try {
    return await act()
  } finally {
    ses.clearStorageData = own
  }
}

const MARK = "proof_left"

// Marks of the proof's own in what the content keeps of the CYFR showing.
async function plant(w) {
  await w.webContents.session.cookies.set({url: HOME, name: MARK, value: "1", secure: true,
    expirationDate: Math.floor(Date.now() / 1000) + 3600})
  await js(w.webContents, `localStorage.setItem(${literal(MARK)}, "kept"); 1`)
}

// What session `ses` keeps: every cookie's name, whatever its site, and
// the mark in the CYFR's local storage, read by a window of the proof's
// own in that session on a document of that origin that sets no cookie.
async function storageOf(ses) {
  const cookies = (await ses.cookies.get({})).map((c) => c.name)
  const probe = new BrowserWindow({show: false, webPreferences: {session: ses}})
  try {
    await probe.loadURL(HOME + "/favicon.ico")
    return {cookies, local: await js(probe.webContents, `localStorage.getItem(${literal(MARK)})`)}
  } finally {
    probe.destroy()
  }
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

run("passkey", {passkey: passkeyPhase, kept: keptPhase, closed: closedPhase, left: leftPhase}, {accountRoad: true})
