// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Two CYFRs in one app window (../README.md, the `pair` shape): A, x.test,
// whose people's accounts are at dir.test, and B, dir.test itself, its own
// account service, both set up by one account @desk-a. The app runs with
// the passkey road on, as on macOS and Windows; its account window is
// given that account's passkey, as the person's platform keeps it.
//
// A CYFR's public address carries no port (CYFR_PUBLIC_URL is exactly
// https://<CYFR_HOST>), so two real CYFRs on one hostname cannot be run:
// the two here differ by name, and dir.test is at once B and A's account
// service, so B's pages and A's sign-in ceremonies share one origin in
// two stores of their own. Stores that differ by port alone are main's
// own tests' (apps/codex/desktop/test/main.test.mjs).
//
// The app is launched three times: `pair`, A and B signed in and moved
// between, ended by a kill while B is being selected; `selected`, A open
// again by itself, then B forgotten and the app killed while it is
// erased; `resumed`, the Forget finished at the next start, then a cyfr
// that does not let go in time ended and started afresh.

import {createHash} from "node:crypto"
import {readFileSync, writeFileSync} from "node:fs"
import path from "node:path"

import {BrowserWindow, session} from "electron"

import {answerWith, armWindow, signOutOfPrism} from "../account.js"
import {DIRECTORY, HOME, NAME, OUT, PROBE, arm, atBootstrap, childOfThis, content, contentAt, harvest, history,
  client, inputs, js, literal, load, opens, passkeys, rail, refused, row, run, said, secondClient, section, seen, sessionCookie,
  sessionMark, waitFor} from "../lib.js"

// B, its account service its own.
const SECOND = inputs.second
const A_HOST = new URL(HOME).hostname
const B_HOST = new URL(SECOND).hostname
// Where each CYFR's people's accounts are.
const ACCOUNT_OF = {[HOME]: DIRECTORY, [SECOND]: SECOND}

// Each CYFR's stores, as main names them (src/policy.js homePartition,
// accountPartition).
const digest = (origin) => createHash("sha256").update(origin, "ascii").digest("hex")
const contentStore = (home) => session.fromPartition(`persist:cyfr-home-v2-${digest(home)}`)
const accountStore = (home) => session.fromPartition(`persist:cyfr-account-v2-${digest(home)}-${digest(ACCOUNT_OF[home])}`)

// The marks of the proof's own each CYFR's content store keeps, and one in
// A's ceremony store at the account service, which is B's origin too.
const MARK = {[HOME]: "proof_a", [SECOND]: "proof_b"}
const CEREMONY_MARK = "proof_ceremony"
// What the first launch left for the next: each session's mark alone.
const SESSIONS = path.join(OUT, "pair-sessions.json")
const UNLEFT = "The CYFR you left did not let go in time, so the app started again and opened nothing. Choose a CYFR on the left to open it."

const at = (home) => (url) => url.startsWith(home + "/") && !/^\/(login|setup|auth\/|account\/)/.test(new URL(url).pathname)

// Prism at `home`, signed in and connected, in the content.
async function prismAt(home) {
  const w = await contentAt(at(home), `Prism at ${home}`)
  await waitFor(() => js(w.webContents, `!!document.querySelector(".phx-connected")`), `Prism's page at ${home} connected`)
  return w
}

// The CYFR at `home` set up with @NAME on the second client, signing in
// there at its account service with the account's passkey.
async function setUp(second, home, token) {
  await load(second, `${home}/setup#${token}`)
  await waitFor(() => js(second, `!!document.querySelector('[data-test="setup-sign-in"]')`), `the setup page at ${home}`)
  await js(second, `document.querySelector('[data-test="setup-sign-in"]').click(); 1`)
  await waitFor(() => new URL(second.getURL()).pathname === "/account/sign", `the sign page for ${home}`)
  await arm()
  await section(second, ["ask"])
  await js(second, `document.querySelector("#use-passkey").click(); 1`)
  await waitFor(() => at(home)(second.getURL()), `the second client at ${home}`)
}

// The account @NAME made at the account service on the second client, and
// both CYFRs set up with it there.
async function accountAndBoth() {
  const second = await secondClient()
  await load(second, `${DIRECTORY}/account/new#name=${NAME}`)
  await arm()
  await section(second, ["choose"])
  await js(second, `document.querySelector("#name").value = ${literal(NAME)};
    document.querySelector("#name").dispatchEvent(new Event("input", {bubbles: true}));
    const a = document.querySelector("#acceptance:not([hidden]) #accept"); if (a) a.click();
    document.querySelector("#create").click(); 1`)
  await section(second, ["show-code"])
  await js(second, `document.querySelector("#saved").click(); 1`)
  await section(second, ["done", "done-return"])
  await harvest()
  await setUp(second, HOME, inputs.setup_token)
  await setUp(second, SECOND, inputs.second_setup_token)
  await harvest()
  return second
}

// The chooser's form in a content other than `before`.
function chooserForm(before = null) {
  return waitFor(async () => {
    const w = content()
    if (!w || w === before || w.webContents.isLoading() || !atBootstrap(w.webContents.getURL())) return null
    return await js(w.webContents, `!document.querySelector("#choose").hidden && document.querySelector("#address").getClientRects().length > 0`) ? w : null
  }, "the chooser's form")
}

// The chooser with both ways on in sight, for `home`.
function bothWays(home) {
  return waitFor(async () => {
    const w = content()
    if (!w || w.webContents.isLoading() || !atBootstrap(w.webContents.getURL())) return null
    return await js(w.webContents, `["#passkey", "#words"].every((id) => document.querySelector(id).getClientRects().length > 0) &&
      document.querySelector("#open").textContent === ${literal(home)}`) ? w : null
  }, `the chooser with both ways on for ${home}`)
}

// Connect to `home` on the chooser's form, its account service approved:
// it opens at its root, which sends who is not signed in to the chooser's
// ways on.
async function connect(home, before) {
  const w = await chooserForm(before)
  await js(w.webContents, `document.querySelector("#address").value = ${literal(home)};
    document.querySelector("#connect").requestSubmit(); 1`)
  await waitFor(() => js(w.webContents, `!document.querySelector("#confirm").hidden`), `the account service of ${home} asked about`)
  await js(w.webContents, `document.querySelector("#approve").click(); 1`)
  return bothWays(home)
}

// Sign in with your passkey on the chooser of `home`: the CYFR's own view
// at its sign-in page, in its own store; its Sign in with your account in
// the app's account window, found by the page it shows and given the
// account's passkey; Prism signed in. Answers the content and the store
// the ceremony used.
async function signIn(home) {
  const chooser = await bothWays(home)
  await js(chooser.webContents, `document.querySelector("#passkey").click(); 1`)
  const page = await contentAt((u) => u.startsWith(home + "/login"), `the sign-in page at ${home}`)
  const own = page !== chooser && page.webContents.session === contentStore(home)
  await waitFor(() => js(page.webContents, `!!document.querySelector(".phx-connected") && !!document.querySelector('[data-test="sign-in"]')`),
    `Sign in with your account at ${home}`)
  await js(page.webContents, `document.querySelector('[data-test="sign-in"]').click(); 1`)
  const account = await waitFor(() => BrowserWindow.getAllWindows().find((x) => !x.isDestroyed() && x !== client &&
    x.webContents.getURL().startsWith(ACCOUNT_OF[home] + "/account/")), `the account window for ${home}`)
  const ceremony = account.webContents.session
  await section(account.webContents, ["ask"])
  await armWindow(account, [...passkeys.values()])
  await js(account.webContents, `document.querySelector("#use-passkey").click(); 1`)
  const w = await prismAt(home)
  return {w, own, ceremony}
}

// Marks of the proof's own in what `home`'s content store keeps.
async function plant(w, home) {
  await w.webContents.session.cookies.set({url: home, name: MARK[home], value: "1", secure: true,
    expirationDate: Math.floor(Date.now() / 1000) + 3600})
  await js(w.webContents, `localStorage.setItem("proof", ${literal(MARK[home])}); 1`)
}

// What store `ses` keeps: every cookie's name and site, and the proof's
// mark in the local storage of each CYFR's origin, read by a window of the
// proof's own in that store on a document that sets no cookie.
async function storageOf(ses) {
  const cookies = (await ses.cookies.get({})).map((c) => `${c.name}@${c.domain}`)
  const local = {}
  const probe = new BrowserWindow({show: false, webPreferences: {session: ses}})
  probe.webContents.setUserAgent(PROBE)
  try {
    for (const home of [HOME, SECOND]) {
      await probe.loadURL(home + "/favicon.ico")
      local[home] = await js(probe.webContents, `localStorage.getItem("proof")`)
    }
    return {cookies, local}
  } finally {
    probe.destroy()
  }
}
const holds = (got, name, host) => got.cookies.includes(`${name}@${host}`)

// A press on the rail: its own top frame going to `path`, which main
// answers; a row's menu is answered by the proof's stand-in for the
// person (lib.js), Forget first.
async function press(path) {
  const r = await waitFor(() => rail(), "the rail")
  await js(r.webContents, `location.assign(${literal(path)}); 1`)
}
const select = (home) => press("/rail/select?cyfr=" + encodeURIComponent(home))

// The rail's rows, as it shows them.
const rows = () => js(rail().webContents, `[...document.querySelectorAll("#cyfrs a")].map((a) => ({cyfr: a.title,
  open: a.getAttribute("aria-current") === "page", failed: a.classList.contains("failed"), forgetting: a.classList.contains("gone")}))`)

// The app's requests `host`'s front saw: every one but the second
// client's, the proof's probes' and the CYFRs' own servers'.
const fromApp = (r) => !/desktop proof/.test(r.agent ?? "") && !/^CYFR\/\d/.test(r.agent ?? "")
const appSeen = async (host) => (await seen(host)).filter(fromApp)

// What the rail's page holds and what its credential may do: each
// change cyfr serves, asked with the rail's read credential from the
// rail's own page.
const railTries = (home) => js(rail().webContents, `(async () => {
  const read = sessionStorage.getItem("read") || ""
  const post = (p, body) => fetch(p, {method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({token: read, epoch: 0, ...body})}).then((r) => r.status, () => "failed")
  const tried = {}
  for (const [p, body] of [["/bootstrap/state", {}], ["/bootstrap/connect", {address: ${literal(home)}}],
    ["/bootstrap/approve", {cyfr: ${literal(home)}, directory: ${literal(DIRECTORY)}}], ["/bootstrap/start", {picks: 0, run: 0}],
    ["/bootstrap/open", {picks: 0, run: 0}], ["/bootstrap/docker", {}]]) tried[p] = await post(p, body)
  return {tried, kept: Object.keys(sessionStorage), url: location.href, history: history.length}
})()`)

async function pairPhase() {
  await accountAndBoth()
  row("two_set_up", true, "one account set up both CYFRs on the second client", {})

  // a_signed_in: Connect to A, then Sign in with your passkey on its
  // chooser: A's sign-in page opens in A's own view and store, and Prism
  // opens signed in there.
  answerWith(() => 0)
  await connect(HOME)
  const a = await signIn(HOME)
  await plant(a.w, HOME)
  await a.ceremony.cookies.set({url: SECOND, name: CEREMONY_MARK, value: "1", secure: true,
    expirationDate: Math.floor(Date.now() / 1000) + 3600})
  const aCookie = await sessionCookie(a.w)
  row("a_signed_in", a.own && !!aCookie, "A's sign-in page opens in A's own view and store, and Prism opens signed in there", {own: a.own})

  // b_signed_in, a_socket_first: Connect on the rail leaves A; A's live
  // socket is closed at A's front before the app asks anything of B; B is
  // signed in in its own store.
  const pressed = Date.now()
  await press("/rail/connect")
  await connect(SECOND, a.w)
  const b = await signIn(SECOND)
  await plant(b.w, SECOND)
  const bCookie = await sessionCookie(b.w, SECOND)
  row("b_signed_in", b.own && !!bCookie, "Connect on the rail leaves A; B's sign-in opens in B's own view and store, and Prism opens there", {own: b.own})
  // The upgrades open at the press.
  const live = (await appSeen(A_HOST)).filter((r) => r.upgrade && r.at < pressed && (r.closedAt === undefined || r.closedAt > pressed))
  const firstAtB = Math.min(...(await appSeen(B_HOST)).filter((r) => r.at >= pressed).map((r) => r.at))
  row("a_socket_first", live.length > 0 && Number.isFinite(firstAtB) && live.every((r) => r.closedAt !== undefined && r.closedAt < firstAtB),
    "A's live socket was closed at A's front before B's first request", {live: live.map((r) => ({path: r.path, at: r.at, closedAt: r.closedAt ?? null})), firstAtB})

  // apart: each store holds its own CYFR's alone, and each front saw only
  // its own CYFR's cookies: B's pages, at the account service's origin,
  // never carry what A's sign-in ceremonies keep there.
  const [aStore, bStore, aCeremony] = await Promise.all([storageOf(contentStore(HOME)), storageOf(contentStore(SECOND)), storageOf(a.ceremony)])
  const bPages = (await appSeen(B_HOST)).filter((r) => r.at >= pressed && !r.path.startsWith("/account/") && !r.path.startsWith("/.well-known/"))
  const carried = bPages.filter((r) => (r.cookies ?? []).includes(CEREMONY_MARK) || (r.cookies ?? []).includes(MARK[HOME]))
  const aSaw = (await appSeen(A_HOST)).filter((r) => (r.cookies ?? []).includes(MARK[SECOND]))
  row("apart", holds(aStore, MARK[HOME], A_HOST) && !holds(aStore, MARK[SECOND], B_HOST) && !holds(aStore, CEREMONY_MARK, B_HOST) &&
    holds(bStore, MARK[SECOND], B_HOST) && !holds(bStore, MARK[HOME], A_HOST) && !holds(bStore, CEREMONY_MARK, B_HOST) &&
    aStore.local[HOME] === MARK[HOME] && aStore.local[SECOND] === null && bStore.local[SECOND] === MARK[SECOND] && bStore.local[HOME] === null &&
    holds(aCeremony, CEREMONY_MARK, B_HOST) && bPages.length > 0 && carried.length === 0 && aSaw.length === 0,
  "each CYFR's store holds its own alone, and B's pages, at A's account service's origin, carry nothing of A's",
  {aStore, bStore, aCeremony: aCeremony.cookies, bPages: bPages.length, carried: carried.map((r) => r.path), aSaw: aSaw.map((r) => r.path)})

  // a_again: A on the rail opens A again, signed in under the very session
  // it had, asking nothing.
  const aMark = (await markIn(HOME)).mark
  await select(HOME)
  const again = await prismAt(HOME)
  const aMarkAgain = await sessionMark(again)
  row("a_again", aMarkAgain?.digest === aMark?.digest && aMarkAgain?.expires === aMark?.expires && again.webContents.session === contentStore(HOME),
    "A on the rail opens A again, signed in under the session it had", {aMark, aMarkAgain})

  // read_only: the rail's page holds its read credential alone, in no
  // address, and cyfr refuses that credential every change.
  const tries = await railTries(SECOND)
  row("read_only", Object.values(tries.tried).every((s) => s === 403) && tries.kept.join() === "read" && !/#|token|read=/.test(tries.url),
    "the rail's page keeps its read credential alone and in no address, and cyfr refuses it every change", tries)

  // sign_out_alone: Sign out in A's Prism ends A's session; B's is
  // untouched.
  const out = await signOutOfPrism(again)
  const bStill = await opens(bCookie, SECOND)
  row("sign_out_alone", refused(out.after) && bStill.opens && holds(await storageOf(contentStore(SECOND)), "_cyfr_key", B_HOST),
    "Sign out at A ends A's session alone: B's still opens B", {after: out.after, bStill})

  // A signed in again for the next launch, its session's mark kept.
  answerWith(() => 0)
  const a2 = await signIn(HOME)
  writeFileSync(SESSIONS, JSON.stringify({[HOME]: await sessionMark(a2.w), [SECOND]: (await markIn(SECOND)).mark}))

  // Killed while B is being selected: A left, B not yet open.
  const saidBefore = said.length
  await select(SECOND)
  await waitFor(() => said.slice(saidBefore).some((l) => l.startsWith("left: ")), "the departure from A")
  return "kill"
}

// What tells `home`'s session in its own store from another, and when it
// ends, with nothing of the cookie itself (lib.js sessionMark), read from
// the store: a view of a CYFR left is closed.
async function markIn(home) {
  const [cookie] = await contentStore(home).cookies.get({url: home, name: "_cyfr_key"})
  return {cookie, mark: cookie ? {digest: createHash("sha256").update(cookie.value).digest("hex").slice(0, 16), expires: cookie.expirationDate ?? null} : null}
}

// Still signed in at `home` as the first launch left it, from its store.
async function stillSigned(home) {
  const was = JSON.parse(readFileSync(SESSIONS, "utf8"))[home]
  const {cookie, mark: is} = await markIn(home)
  return {was, is, same: !!is && is.digest === was?.digest && is.expires === was?.expires, opens: !!cookie && (await opens(cookie.value, home)).opens}
}

async function selectedPhase() {
  // kill_selecting: killed while B was being selected, the app opens A by
  // itself, the last one opened, signed in as before; B is still listed
  // and still signed in.
  const w = await prismAt(HOME)
  const listed = await waitFor(async () => (await rows()).length === 2 ? rows() : null, "both CYFRs on the rail")
  const [a, b] = [await stillSigned(HOME), await stillSigned(SECOND)]
  row("kill_selecting", w.webContents.session === contentStore(HOME) && a.same && a.opens && b.same && b.opens &&
    listed.find((r) => r.cyfr === HOME)?.open,
  "killed while B was being selected, the app opens A again by itself, and both stay signed in", {a, b, listed})

  // Forget B, killed while its store is being erased: the erase is held.
  const bStore = contentStore(SECOND)
  bStore.clearStorageData = () => new Promise(() => {})
  answerWith((buttons) => buttons.indexOf("Forget"))
  await press("/rail/menu?cyfr=" + encodeURIComponent(SECOND))
  await waitFor(async () => (await rows()).find((r) => r.cyfr === SECOND)?.forgetting, "B being forgotten")
  return "kill"
}

async function resumedPhase() {
  // forget_resumed: the Forget the kill interrupted is finished at this
  // start: B is listed no more and nothing of it is kept, A's and its
  // ceremonies' left as they were.
  await prismAt(HOME)
  const gone = await waitFor(async () => (await rows()).some((r) => r.cyfr === SECOND) ? null : rows(), "the rail without B")
  const [bStore, bCeremony, aStore] = await Promise.all([storageOf(contentStore(SECOND)), storageOf(accountStore(SECOND)), storageOf(contentStore(HOME))])
  const a = await stillSigned(HOME)
  row("forget_resumed", bStore.cookies.length === 0 && bStore.local[SECOND] === null && bCeremony.cookies.length === 0 &&
    holds(aStore, MARK[HOME], A_HOST) && a.same && a.opens && gone.length === 1,
  "the Forget a kill interrupted is finished at the next start: nothing of B is kept, and A is as it was", {bStore, bCeremony, aStore, a, gone})

  // unleft: a cyfr that does not let go of A in time is ended and a fresh
  // one started, which opens nothing; A's sign-in is kept.
  const old = childOfThis("desktop-serve")
  process.kill(old, "SIGSTOP")
  const pressed = Date.now()
  const shownBefore = history.length
  await press("/rail/connect")
  const told = await waitFor(async () => {
    const w = content()
    if (!w || w.webContents.isLoading() || !atBootstrap(w.webContents.getURL())) return null
    const notice = await js(w.webContents, `document.querySelector("#notice").textContent`)
    return notice === UNLEFT ? notice : null
  }, "the chooser after a cyfr that did not let go", 60_000)
  const waited = Date.now() - pressed
  let fresh = null
  try {
    fresh = childOfThis("desktop-serve")
  } catch {
    fresh = null
  }
  const kept = await stillSigned(HOME)
  const homeOpened = history.slice(shownBefore).some((url) => url.startsWith(HOME + "/"))
  row("unleft", told === UNLEFT && waited >= 20_000 && fresh !== null && fresh !== old && kept.same && kept.opens && !homeOpened,
    "a cyfr that did not let go in 20 s is ended and a fresh one opens nothing; A's sign-in is kept", {waited, fresh: fresh !== null && fresh !== old, kept})
  return {system: ["system_quit", "ended by the system at the chooser, the app quits, and never from inside the engine's before-quit"]}
}

run("pair", {pair: pairPhase, selected: selectedPhase, resumed: resumedPhase}, {accountRoad: true})
