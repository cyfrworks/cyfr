// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The chooser cyfr serves (internal/desktop/assets): its own script,
// run over the elements its own page has. It stays while it has a notice to
// show, with its way on, and moves on by itself only when it has none. On
// the passkey road it opens the CYFR remembered by itself, and otherwise
// shows both ways on. Main's address may name a CYFR the rail selected,
// which it connects to, or the way to set up CYFR on this computer.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

import {initial, step} from "../src/states.js"

const asset = (name) => readFileSync(new URL(`../../internal/desktop/assets/${name}`, import.meta.url), "utf8")
const script = asset("chooser.js")
const page = asset("chooser.html")
assert.ok(script && page, "the chooser's script and page")

const HOME = "https://cyfr.example.com"
const COMPANY = "This CYFR requires company sign-in. Open its address in a browser to continue. The CYFR app does not support company sign-in yet."
// The passkey's way on: an address main alone answers, opening the CYFR's
// own view at its sign-in page.
const PASSKEY = "/bootstrap/signin"
const UNFORGOTTEN = "The app locked, and could not clear the sign-in it kept on this computer. To clear it, forget this CYFR on this computer from its menu on the left."
const UNLEFT = "The CYFR you left did not let go in time, so the app started again and opened nothing. Choose a CYFR on the left to open it."
const OPEN = {cyfr: HOME, next: "/"}
// The passkey road, as main says it in the chooser's address.
const ROAD = "#token=t&road=passkey"

// The chooser opened with `notice` while cyfr answers `state`: its
// elements, each as hidden as the page starts it, and where it went. Its
// document came by a navigation of `type`, at an entry of the history that
// holds `saved`; the tab holds the run token, as it does once main's first
// load ran, and cyfr refuses any other.
async function chooser(notice, state, connected = OPEN, hash = "#token=t" + (notice ? `&notice=${notice}` : ""),
  {type = "navigate", saved = null, picked = {}, docker = [], setup = {}} = {}) {
  const elements = new Map()
  for (const [tag, id] of page.matchAll(/<[a-z0-9]+\b[^>]*\bid="([a-z]+)"[^>]*>/g)) {
    const listeners = {}
    elements.set(id, {hidden: /\shidden[\s>]/.test(tag), textContent: "", value: "", onclick: null,
      addEventListener: (type, f) => { listeners[type] = f },
      fire: (type) => listeners[type]?.({preventDefault() {}})})
  }
  const went = {byItself: [], pressed: [], asked: []}
  const stored = new Map([["token", "t"]])
  went.stored = stored
  vm.runInNewContext(script, {
    URLSearchParams,
    document: {getElementById: (id) => elements.get(id)},
    sessionStorage: {getItem: (k) => stored.get(k) ?? null, setItem: (k, v) => stored.set(k, v)},
    history: {state: saved, replaceState: (entry, _title, to) => { went.entry = entry; went.address = to }},
    performance: {getEntriesByType: () => [{type}]},
    location: {pathname: "/bootstrap/", hash,
      replace: (to) => went.byItself.push(to), assign: (to) => went.pressed.push(to)},
    fetch: async (path, init) => {
      const {token, epoch, ...body} = JSON.parse(init.body)
      if (token !== "t") return {ok: false}
      // The epoch the page was shown in, which every request carries.
      went.epochs = [...(went.epochs ?? []), epoch]
      if (path !== "/bootstrap/state") went.asked.push([path, body])
      went.tokens = [...(went.tokens ?? []), token]
      if (path !== "/bootstrap/state") stored.clear() // main cleared the storage while it waited
      return {ok: true, json: async () => (path === "/bootstrap/state" ? state : path === "/bootstrap/folder" ? picked : path === "/bootstrap/docker" ? docker.shift() : setup[path] ? setup[path].shift() : connected)}
    }
  })
  await settled()
  return {$: (id) => elements.get(id), went}
}

const settled = () => new Promise((resolve) => setImmediate(resolve))
// The chooser that `went` showed, reloaded.
const reload = (went) => chooser("", OPEN, OPEN, new URL(went.address, "http://127.0.0.1:7340").hash,
  {type: "reload", saved: went.entry})

test("with a notice to show the chooser stays, says it, and offers its way on to the device's pages", async () => {
  for (const [notice, words] of [["company", COMPANY], ["unleft", UNLEFT], ["company,unleft", `${COMPANY} ${UNLEFT}`],
    ["nothing-it-knows,company", COMPANY]]) {
    const {$, went} = await chooser(notice, OPEN)
    assert.deepEqual(went.byItself, [], notice)
    assert.equal($("notice").textContent, words)
    assert.deepEqual([$("choose").hidden, $("road").hidden, $("words").hidden], [true, false, false], notice)
    assert.deepEqual([$("passkey").hidden, $("either").hidden], [true, true],
      "no passkey road where cyfr offers none")
    assert.equal($("open").textContent, HOME)
    $("words").onclick()
    assert.deepEqual(went.pressed, ["/"], "Use this computer's key goes on")
  }
})

test("a reload of a chooser that stays keeps its notice, and its address never keeps the token", async () => {
  const first = await chooser("company,unleft", OPEN)
  assert.doesNotMatch(first.went.address, /token/)
  const again = await reload(first.went)
  assert.deepEqual(again.went.byItself, [], "the reload did not move on")
  assert.equal(again.$("notice").textContent, `${COMPANY} ${UNLEFT}`)
  assert.equal((await chooser("", OPEN)).went.address, "/bootstrap/", "with none, the bare address")
})

test("with no notice to show the chooser moves on by itself", async () => {
  for (const notice of ["", "nothing-it-knows"]) {
    const {$, went} = await chooser(notice, OPEN)
    assert.deepEqual(went.byItself, ["/"], notice)
    assert.equal($("notice").textContent, "")
    assert.equal($("road").hidden, true, notice)
  }
})

test("on the passkey road the chooser stays with both ways on, a notice or none", async () => {
  for (const notice of ["", "company"]) {
    const {$, went} = await chooser(notice, OPEN, OPEN, ROAD + (notice ? `&notice=${notice}` : ""))
    assert.deepEqual(went.byItself, [], notice)
    assert.deepEqual([$("road").hidden, $("passkey").hidden, $("either").hidden], [false, false, false], notice)
    assert.equal($("notice").textContent, notice ? COMPANY : "")
    assert.deepEqual(went.asked, [], "it connects nothing by itself")
    $("passkey").onclick()
    assert.deepEqual(went.pressed, [], "not before the CYFR answered")
    await settled()
    assert.deepEqual(went.asked, [["/bootstrap/connect", {address: HOME}]], "the press asks")
    assert.deepEqual(went.pressed, [PASSKEY])
  }
})

test("the passkey's way on goes nowhere when its press is not answered with a way on", async () => {
  for (const said of [{cyfr: HOME, error: "It did not answer."}, {error: "CYFR locked. Connect again."}]) {
    const {$, went} = await chooser("", OPEN, said, ROAD)
    $("passkey").onclick()
    await settled()
    assert.deepEqual([went.byItself, went.pressed], [[], []])
    assert.equal($("notice").textContent, said.error)
    assert.deepEqual([$("road").hidden, $("passkey").hidden, $("words").hidden], [false, false, false], "both ways on stay")
  }
})

const UNANSWERED = `The CYFR at ${HOME} did not answer.`

test("a chooser told that the CYFR did not answer names it and offers it again", async () => {
  const keys = await chooser("", OPEN, OPEN, ROAD + "&notice=unanswered")
  assert.deepEqual(keys.went.byItself, [])
  assert.equal(keys.$("notice").textContent, UNANSWERED)
  assert.deepEqual([keys.$("road").hidden, keys.$("again").hidden, keys.$("passkey").hidden], [false, false, false])
  assert.deepEqual(keys.went.asked, [], "it connects nothing by itself")
  keys.$("again").onclick()
  assert.deepEqual(keys.went.pressed, [], "not before the CYFR answered")
  await settled()
  assert.deepEqual(keys.went.asked, [["/bootstrap/connect", {address: HOME}]], "the press asks, as the passkey's way on does")
  assert.deepEqual(keys.went.pressed, ["/bootstrap/again"], "main's to open")

  const words = await chooser("unanswered", OPEN)
  assert.deepEqual(words.went.byItself, [], "it stays to say so")
  assert.equal(words.$("notice").textContent, UNANSWERED)
  assert.deepEqual([words.$("road").hidden, words.$("again").hidden, words.$("words").hidden], [false, true, false])
  words.$("words").onclick()
  assert.deepEqual(words.went.pressed, ["/"], "the device's pages, which offer it")
})

test("Try again loads nothing until a Connect at that CYFR answered with a way on", async () => {
  const local = {cyfr: "http://localhost:4000", next: "/"}
  for (const said of [{cyfr: local.cyfr, error: "The CYFR in /srv/cyfr does not answer."}, {error: "CYFR locked. Connect again."}]) {
    const {$, went} = await chooser("", local, said, ROAD + "&notice=unanswered")
    $("again").onclick()
    await settled()
    assert.deepEqual([went.byItself, went.pressed], [[], []], said.error)
    assert.deepEqual(went.asked, [["/bootstrap/connect", {address: local.cyfr}]])
    assert.equal($("notice").textContent, said.error)
    assert.deepEqual([$("road").hidden, $("again").hidden, $("words").hidden], [false, false, false], "every way on stays")
  }
})

test("Try again shows only where main says the CYFR did not answer, and after a reload there", async () => {
  for (const notice of ["", "company", "unleft"]) {
    const {$} = await chooser("", OPEN, OPEN, ROAD + (notice ? `&notice=${notice}` : ""))
    assert.equal($("again").hidden, true, notice)
  }
  const first = await chooser("", OPEN, OPEN, ROAD + "&notice=unanswered")
  const again = await reload(first.went)
  assert.deepEqual([again.$("again").hidden, again.$("notice").textContent], [false, UNANSWERED])
})

test("a reload and the history keep the road main said, and the address keeps nothing", async () => {
  const first = await chooser("", OPEN, OPEN, ROAD)
  assert.equal(first.went.address, "/bootstrap/")
  for (const type of ["reload", "back_forward"]) {
    const again = await chooser("", OPEN, OPEN, "", {type, saved: first.went.entry})
    assert.equal(again.$("passkey").hidden, false, type)
  }
  const said = await chooser("", OPEN, OPEN, "#road=passkey")
  assert.deepEqual(said.went.byItself, ["/"], "an address without main's token says no road")
})

test("as the app starts on the passkey road the CYFR remembered connects by itself, and main opens it", async () => {
  const {$, went} = await chooser("", {cyfr: HOME, resume: HOME}, OPEN, ROAD)
  await settled()
  assert.deepEqual(went.asked, [["/bootstrap/connect", {address: HOME}]])
  assert.deepEqual([went.byItself, went.pressed], [[], []], "the window is main's to send to the root")
  assert.equal($("road").hidden, true, "and no way on shows meanwhile")
})

test("on the six-word road a CYFR remembered waits for Connect", async () => {
  const {$, went} = await chooser("", {cyfr: HOME, resume: HOME}, OPEN)
  assert.deepEqual(went.asked, [])
  assert.deepEqual([$("choose").hidden, $("address").value], [false, HOME])
})

test("a Connect the person makes on the passkey road leaves the opening to main", async () => {
  const {$, went} = await chooser("", {cyfr: HOME}, OPEN, ROAD)
  assert.deepEqual(went.asked, [], "nothing by itself")
  $("connect").fire("submit")
  await settled()
  assert.deepEqual([went.byItself, went.pressed], [[], []])
})

test("a Connect main cleared the storage under keeps the run token", async () => {
  const {$, went} = await chooser("", {cyfr: HOME}, {error: "It did not answer."}, ROAD)
  $("connect").fire("submit")
  await settled()
  assert.equal(went.stored.get("token"), "t", "put back for a reload")
  $("connect").fire("submit")
  await settled()
  assert.deepEqual(went.tokens, ["t", "t", "t"])
})

test("with a notice to show the chooser connects nothing by itself", async () => {
  const {went} = await chooser("company", {cyfr: HOME, resume: HOME}, OPEN, ROAD + "&notice=company")
  assert.deepEqual(went.asked, [])
  assert.deepEqual(went.byItself, [])
})

test("a CYFR main's address names is connected to, in place of the one remembered, and the address keeps none", async () => {
  const BOB = "https://bob.example:8443"
  for (const hash of [`#token=t&connect=${encodeURIComponent(BOB)}`, `${ROAD}&connect=${encodeURIComponent(BOB)}`]) {
    const {$, went} = await chooser("", {cyfr: HOME, resume: HOME}, {cyfr: BOB}, hash)
    assert.deepEqual(went.asked, [["/bootstrap/connect", {address: BOB}]], hash)
    assert.equal($("address").value, BOB)
    assert.equal(went.address, "/bootstrap/", "the address keeps none")
    const again = await reload(went)
    assert.deepEqual(again.went.asked, [], "a reload connects nothing")
  }
})

test("set up, as main's address names it, opens at setting up on this computer", async () => {
  const {$, went} = await chooser("", {}, OPEN, "#token=t&way=setup", {docker: [{docker: {ready: true}}]})
  assert.deepEqual([$("choose").hidden, $("setup").hidden], [true, false])
  assert.deepEqual(went.asked, [["/bootstrap/docker", {}]])
})

test("with no CYFR open a notice shows on Connect, and a Connect the person makes goes on", async () => {
  const {$, went} = await chooser("company", {})
  assert.deepEqual([$("choose").hidden, $("road").hidden], [false, true])
  assert.equal($("notice").textContent, COMPANY)
  assert.deepEqual(went.byItself, [])
  $("connect").fire("submit")
  await settled()
  assert.deepEqual(went.byItself, ["/"])
})

test("an answer to a Connect that names its CYFR beside an error says the error on the form and goes nowhere", async () => {
  const UNPREPARED = "The app did not get ready to open " + HOME + ". Connect again."
  for (const hash of ["#token=t", ROAD]) {
    const {$, went} = await chooser("", {cyfr: HOME}, {cyfr: HOME, error: UNPREPARED}, hash)
    $("connect").fire("submit")
    await settled()
    assert.equal($("notice").textContent, UNPREPARED, hash)
    assert.deepEqual([$("choose").hidden, $("road").hidden], [false, true], "Connect again")
    assert.deepEqual([went.byItself, went.pressed], [[], []], hash)
    assert.equal(went.stored.get("token"), "t", "and a reload still has the run token")
  }
})

test("an answer that is an error says the error and goes nowhere", async () => {
  const {$, went} = await chooser("company", {error: "The record could not be read."})
  assert.equal($("notice").textContent, "The record could not be read.")
  assert.deepEqual(went.byItself, [])
})

// ---- what the chooser says on main's behalf is main's alone to decide ----

const ACCOUNT = "https://cyfr.run"
const LOOPBACK = "http://127.0.0.1:7340"
const CHOOSER = LOOPBACK + "/bootstrap/"
const at = (url, showing, over = {}) => ({type: "navigate", window: "content", url, target: "top", asker: "top", showing, by: showing, ...over})
const ready = {type: "ready", url: CHOOSER + "#token=t", message: {type: "ready", url: CHOOSER + "#token=t", rail: LOOPBACK + "/rail/#read=r"}}
const open = [ready, {type: "home", message: {type: "home", home: HOME, account: ACCOUNT, attempt: 1}},
  {type: "opened", home: HOME, message: {type: "opened", home: HOME, attempt: 1}}]
const locked = {type: "locked", message: {type: "locked", home: HOME, account: ACCOUNT}}

// Every notice, by name: its words, and what main observed that makes it
// load the chooser with it.
const NOTICES = {
  company: {words: COMPANY, observed: [at(HOME + "/company-login", HOME + "/login"), locked]},
  unleft: {words: UNLEFT, observed: [{type: "navigate", window: "rail", url: LOOPBACK + "/rail/select?cyfr=https%3A%2F%2Fbob.example",
    target: "top", asker: "top", showing: LOOPBACK + "/rail/", by: LOOPBACK + "/rail/"}, {type: "late", id: 1}, ready]},
  unforgotten: {words: UNFORGOTTEN, observed: [locked, {type: "forgot", cleared: false}]},
  unanswered: {words: UNANSWERED, observed: [{type: "load-failed", code: -106, url: HOME + "/threads"}]}
}

// Every way a load of the chooser can begin that is not main's, as main is
// asked about it.
const PAGES_WAYS = {
  "a navigation of the CYFR's page": (url) => at(url, HOME + "/threads"),
  "a navigation of the device's pages": (url) => at(url, LOOPBACK + "/"),
  "a navigation of the chooser's own page": (url) => at(url, CHOOSER),
  "a navigation no frame began": (url) => at(url, HOME + "/threads", {asker: "none", by: ""}),
  "a redirect of the CYFR's": (url) => at(url, HOME + "/threads", {redirect: true}),
  "a redirect of main's own load": (url) => at(url, CHOOSER, {redirect: true, asker: "none", by: ""}),
  "a frame's own": (url) => at(url, HOME + "/threads", {target: "frame", asker: "frame-inside", by: ""}),
  "the page's, of a frame": (url) => at(url, HOME + "/threads", {target: "frame"}),
  "a frame's, of the page": (url) => at(url, HOME + "/threads", {asker: "frame-inside", by: ""}),
  "a frame's redirect": (url) => at(url, HOME + "/threads", {target: "frame", redirect: true}),
  "a new window": (url) => ({type: "open-window", url}),
  "a confirmation window's navigation": (url) => at(url, LOOPBACK + "/confirm?ref=c", {window: "child"}),
  "a confirmation window's redirect": (url) => at(url, LOOPBACK + "/confirm?ref=c", {window: "child", redirect: true}),
  "a confirmation window's frame": (url) => at(url, LOOPBACK + "/confirm?ref=c", {window: "child", target: "frame"}),
  "the account window's navigation": (url) => ({...at(url, ACCOUNT + "/account/sign"), type: "account-navigate", window: "account"})
}

// The chooser's address as a page can write it: it has no run token.
const written = (notice) => [CHOOSER, CHOOSER + "?x=1", LOOPBACK + "/%62ootstrap/", LOOPBACK + "/%2Fbootstrap/../bootstrap/",
  LOOPBACK + "/bootstrap%2F", LOOPBACK + "/x/../bootstrap/", "http://2130706433:7340/bootstrap/"]
  .flatMap((base) => ["", "token=&", "token=a-guess&"].map((token) => `${base}#${token}road=passkey&notice=${notice}`))

test("every notice the chooser has is in this table", () => {
  const all = vm.runInNewContext(`(${/const notices=(\{[^;]*\});/.exec(script)[1]})`)
  assert.deepEqual(Object.keys(NOTICES).sort(), Object.keys(all).sort())
})

test("every notice against every way a load of the chooser can begin: main's alone shows it", async () => {
  for (const [notice, {words, observed}] of Object.entries(NOTICES)) {
    let s = initial(true)
    const effects = []
    for (const e of [...open, ...observed]) {
      const r = step(s, e)
      s = r.state
      effects.push(...r.do)
    }
    const load = effects.filter((e) => e.chooser || e.back).at(-1)
    const told = load.chooser ?? load.back
    assert.deepEqual([...told], [notice], "main loads the chooser with it for what it observed")
    const mains = await chooser("", OPEN, OPEN, `#token=t&road=passkey&notice=${told.join(",")}`)
    assert.equal(mains.$("notice").textContent, words, `${notice}: main's load`)

    for (const road of [true, false]) {
      let o = initial(road)
      for (const e of open) o = step(o, e).state
      for (const state of [o, {...o, notices: [notice]}, step(initial(road), open[0]).state]) {
        for (const [way, event] of Object.entries(PAGES_WAYS)) {
          for (const url of written(notice)) {
            const r = step(state, event(url))
            assert.ok(r.open === "deny" || r.allow === false, `${notice}: ${way} to ${url} is refused`)
            assert.deepEqual(r.do.filter((e) => e.chooser || e.back || e.root), [], `${notice}: ${way} has main load nothing`)
          }
        }
      }
    }

    // A document of the chooser that main's load did not make, which the
    // history can bring, says nothing on main's behalf, whatever its
    // address says.
    const saved = mains.went.entry
    for (const token of ["", "token=&", "token=a-guess&"]) {
      for (const [type, entry] of [["navigate", null], ["navigate", saved], ["back_forward", saved], ["reload", null]]) {
        const {$} = await chooser("", OPEN, OPEN, `#${token}road=passkey&notice=${notice}`, {type, saved: entry})
        assert.ok(!$("notice").textContent.includes(words), `${notice}: ${type}, ${token}`)
        assert.equal($("again").hidden, true, `${notice}: ${type}, ${token}: no Try again`)
      }
    }
    const back = await chooser("", OPEN, OPEN, "", {type: "back_forward", saved})
    assert.equal((await reload(back.went)).$("notice").textContent, "", `${notice}: a reload after the history brought it back`)
    assert.equal((await reload(mains.went)).$("notice").textContent, words, `${notice}: main's load, reloaded`)
  }
})

// Setting up CYFR on this computer: the folder is cyfr's word, and Change…
// asks main, never naming one.
test("the chooser shows the folder cyfr names, and Change… asks main, then shows the folder cyfr answers", async () => {
  for (const [seen, state] of [[0, {folder: "/home/ada/cyfr"}], [3, {folder: "/home/ada/there", picks: 3, epoch: 2}]]) {
    const {$, went} = await chooser("", state, OPEN, "#token=t", {picked: {folder: "/home/ada/elsewhere", picks: seen + 1}})
    assert.equal($("choose").hidden, false)
    assert.equal($("folder").textContent, state.folder)
    $("change").fire("click")
    assert.deepEqual(went.pressed, [`/bootstrap/pick?epoch=${state.epoch ?? 0}&pick=${seen}`],
      "main is asked by its own address, naming the time the page was shown in and the picks it has seen")
    assert.deepEqual(went.asked, [["/bootstrap/folder", {picks: seen}]], "cyfr is asked for the answer after the picks seen")
    await settled()
    assert.equal($("folder").textContent, "/home/ada/elsewhere")
    $("change").fire("click")
    await settled()
    assert.deepEqual(went.asked.at(-1), ["/bootstrap/folder", {picks: seen + 1}], "the next waits for the next answer")
  }
})

test("the chooser never names a folder, and says why a pick went unanswered", async () => {
  const {$, went} = await chooser("", {folder: "/home/ada/cyfr"}, OPEN, "#token=t", {picked: {error: "CYFR locked. Connect again."}})
  $("change").fire("click")
  await settled()
  assert.equal($("folder").textContent, "/home/ada/cyfr")
  assert.equal($("notice").textContent, "CYFR locked. Connect again.")
  for (const [, body] of went.asked) assert.ok(!JSON.stringify(body).includes("/home/ada"), JSON.stringify(body))
})

// The Docker check: shown once the person chose to set up here, asked of
// cyfr at that press and at each Check again, its commands text to copy
// and its page a link.
test("Set up CYFR on this computer shows its screen and asks whether Docker answers; Check again asks again", async () => {
  const docker = [{docker: {sentence: "Docker does not answer this account", commands: ["apt-get update", "usermod -aG docker ada"]}},
    {docker: {ready: true}}]
  const {$, went} = await chooser("", {folder: "/home/ada/cyfr"}, {}, "#token=t", {docker})
  assert.deepEqual([$("choose").hidden, $("setup").hidden], [false, true], "the first screen offers it")
  assert.deepEqual(went.asked, [], "nothing asks Docker before the press")
  $("here").fire("click")
  assert.deepEqual([$("choose").hidden, $("setup").hidden], [true, false])
  assert.equal($("docker").textContent, "Checking whether Docker answers\u2026")
  await settled()
  assert.deepEqual(went.asked, [["/bootstrap/docker", {}]])
  assert.equal($("docker").textContent, "Docker does not answer this account.")
  assert.deepEqual([$("run").hidden, $("commands").hidden, $("install").hidden, $("check").hidden], [false, false, true, false])
  assert.equal($("start").hidden, true, "no Set up and start while Docker does not answer")
  assert.equal($("commands").textContent, "sudo apt-get update\nsudo usermod -aG docker ada", "text to copy")
  $("check").fire("click")
  await settled()
  assert.equal(went.asked.length, 2, "Check again asks again")
  assert.equal($("docker").textContent, "Docker answers on this computer.")
  assert.deepEqual([$("run").hidden, $("commands").hidden, $("install").hidden, $("check").hidden], [true, true, true, true])
  assert.equal($("start").hidden, false, "Set up and start once it does")
  assert.deepEqual(went.pressed, [], "the app goes nowhere and runs nothing")
  $("back").fire("click")
  assert.deepEqual([$("choose").hidden, $("setup").hidden], [false, true])
})

test("where Docker is to be installed from its page, the chooser links to it; a Docker elsewhere or a login missing is its sentence alone", async () => {
  const page = "https://www.docker.com/products/docker-desktop/"
  const docker = [{docker: {sentence: "Docker did not say where it runs containers", page}},
    {docker: {sentence: "Docker does not answer this account until you log out and in again"}},
    {error: "CYFR locked. Connect again."}]
  const {$} = await chooser("", {folder: "/home/ada/cyfr"}, {}, "#token=t", {docker})
  $("here").fire("click")
  await settled()
  assert.equal($("page").href, page)
  assert.deepEqual([$("install").hidden, $("commands").hidden], [false, true])
  $("check").fire("click")
  await settled()
  assert.equal($("docker").textContent, "Docker does not answer this account until you log out and in again.")
  assert.deepEqual([$("install").hidden, $("commands").hidden, $("check").hidden], [true, true, false])
  $("check").fire("click")
  await settled()
  assert.equal($("docker").textContent, "CYFR locked. Connect again.")
})

// Set up and start: offered once Docker answers, its progress shown step
// by step, then the first person's page; its failure in its sentence with
// Try again; and after a lock, its progress again with nothing opened by
// itself.
const SETUP_WORDS = ["Getting CYFR's files", "Writing its settings", "Downloading CYFR", "Starting CYFR"]
const running = (steps, seq) => ({setup: {run: 1, folder: "/home/ada/cyfr", steps, seq}})
const progressOf = ($) => $("progress").textContent.split("\n")

test("Set up and start shows its steps as they begin, then opens the CYFR set up as Connect does", async () => {
  const setup = {
    "/bootstrap/start": [running([], 1)],
    "/bootstrap/setup": [running(["files"], 2), running(["files", "settings", "images", "start"], 5),
      {setup: {run: 1, folder: "/home/ada/cyfr", steps: ["files", "settings", "images", "start"], done: true, seq: 6}}],
    "/bootstrap/open": [{cyfr: "http://localhost:4000", next: "/"}]
  }
  const {$, went} = await chooser("", {folder: "/home/ada/cyfr"}, {}, "#token=t", {docker: [{docker: {ready: true}}], setup})
  $("here").fire("click")
  await settled()
  assert.equal($("start").hidden, false, "offered once Docker answers")
  $("start").fire("click")
  await settled()
  assert.deepEqual(went.asked.map(([p]) => p), ["/bootstrap/docker", "/bootstrap/start", "/bootstrap/setup", "/bootstrap/setup",
    "/bootstrap/setup", "/bootstrap/open"])
  assert.deepEqual(went.asked.filter(([p]) => p === "/bootstrap/setup").map(([, b]) => b), [{seen: 1}, {seen: 2}, {seen: 5}],
    "each wait is for the step after the one shown")
  assert.deepEqual(went.asked.find(([p]) => p === "/bootstrap/start")[1], {picks: 0, run: 0}, "the page names no folder: the pick and the setup it shows")
  assert.deepEqual(progressOf($), ["Setting up CYFR in /home/ada/cyfr", ...SETUP_WORDS])
  assert.deepEqual(went.byItself, ["/"], "then the first person's page")
})

test("a setup that failed says why and offers Try again, which starts it again", async () => {
  const failed = {setup: {folder: "/home/ada", steps: [], error: "CYFR cannot be set up in /home/ada itself. Nothing was changed", seq: 2}}
  const setup = {"/bootstrap/start": [running([], 1), running([], 3)], "/bootstrap/setup": [failed, running(["files"], 4), {error: "CYFR locked. Connect again."}]}
  const {$, went} = await chooser("", {folder: "/home/ada"}, {}, "#token=t", {docker: [{docker: {ready: true}}], setup})
  $("here").fire("click")
  await settled()
  $("start").fire("click")
  await settled()
  assert.equal($("notice").textContent, "CYFR cannot be set up in /home/ada itself. Nothing was changed.")
  assert.deepEqual([$("retry").hidden, $("change").hidden, $("go").hidden], [false, false, true])
  $("retry").fire("click")
  await settled()
  assert.equal(went.asked.filter(([p]) => p === "/bootstrap/start").length, 2)
  assert.equal($("retry").hidden, true)
  assert.deepEqual(went.byItself, [], "nothing opened")
})

test("after a lock the chooser shows the setup's progress again, and once it is done opens nothing by itself", async () => {
  const done = {setup: {run: 1, folder: "/home/ada/cyfr", steps: ["files", "settings", "images", "start"], done: true, seq: 6}}
  const setup = {"/bootstrap/setup": [done], "/bootstrap/open": [{cyfr: "http://localhost:4000", next: "/"}]}
  for (const road of ["#token=t", ROAD]) {
    const {$, went} = await chooser("", {folder: "/home/ada/cyfr", ...running(["files", "settings"], 3), resume: HOME}, {}, road,
      {setup: {...setup, "/bootstrap/setup": [done], "/bootstrap/open": [{cyfr: "http://localhost:4000", next: "/"}]}})
    assert.deepEqual([$("choose").hidden, $("setup").hidden], [true, false], road)
    await settled()
    assert.deepEqual(progressOf($), ["Setting up CYFR in /home/ada/cyfr", ...SETUP_WORDS])
    assert.equal($("notice").textContent, "CYFR is set up in /home/ada/cyfr and started.")
    assert.equal($("go").hidden, false, "Open CYFR is offered")
    assert.deepEqual(went.asked.map(([p]) => p), ["/bootstrap/setup"], `${road}: nothing opened or connected by itself`)
    assert.deepEqual(went.byItself, [])
    $("go").fire("click")
    await settled()
    assert.deepEqual(went.asked.at(-1), ["/bootstrap/open", {picks: 0, run: 1}], "Open CYFR is the press, for the folder and the setup shown")
  }
})

test("the CYFR set up opens at the device's pages on the six-word road, through main on the passkey road, and every request says the time its page was shown in", async () => {
  const done = {setup: {run: 1, folder: "/home/ada/cyfr", steps: ["files", "settings", "images", "start"], done: true, seq: 2}}
  for (const [road, byItself] of [["#token=t", ["/"]], [ROAD, []]]) {
    const setup = {"/bootstrap/start": [running([], 1)], "/bootstrap/setup": [done], "/bootstrap/open": [{cyfr: "http://localhost:4000", next: "/"}]}
    const {$, went} = await chooser("", {folder: "/home/ada/cyfr", picks: 1, epoch: 4}, {}, road, {docker: [{docker: {ready: true}}], setup})
    $("here").fire("click")
    await settled()
    $("start").fire("click")
    await settled()
    assert.deepEqual(went.asked.find(([p]) => p === "/bootstrap/start")[1], {picks: 1, run: 0}, road)
    assert.deepEqual(went.asked.at(-1), ["/bootstrap/open", {picks: 1, run: 1}], road)
    // The device's pages make the first person on the six-word road; on
    // the passkey road main opens the CYFR's setup page itself.
    assert.deepEqual(went.byItself, byItself, road)
    assert.deepEqual(went.epochs, [0, 4, 4, 4, 4], "the state asked first, then each request in the time it answered")
  }
})

test("a Start refused because the folder changed shows the folder now and its sentence, and the next press is for it", async () => {
  const changed = "The folder changed to /home/ada/other. Check it, then press Set up and start again."
  const setup = {"/bootstrap/start": [{folder: "/home/ada/other", picks: 2, error: changed}, running([], 1)]}
  const {$, went} = await chooser("", {folder: "/home/ada/cyfr", picks: 1}, {}, "#token=t", {docker: [{docker: {ready: true}}], setup})
  $("here").fire("click")
  await settled()
  $("start").fire("click")
  await settled()
  assert.equal($("folder").textContent, "/home/ada/other")
  assert.equal($("notice").textContent, changed)
  assert.equal($("start").hidden, false, "Set up and start is still offered")
  $("start").fire("click")
  await settled()
  assert.deepEqual(went.asked.filter(([p]) => p === "/bootstrap/start").map(([, b]) => b), [{picks: 1, run: 0}, {picks: 2, run: 0}])
})

test("a refused Open of the CYFR set up says why", async () => {
  const done = {folder: "/home/ada/cyfr", setup: {run: 1, folder: "/home/ada/cyfr", steps: [], done: true, seq: 2}}
  for (const [answered, words] of [[{error: "CYFR locked. Connect again."}, "CYFR locked. Connect again."], [{}, "CYFR did not open."]]) {
    const {$, went} = await chooser("", done, {}, ROAD, {setup: {"/bootstrap/open": [answered]}})
    $("go").fire("click")
    await settled()
    assert.equal($("notice").textContent, words)
    assert.equal($("go").hidden, false, "Open CYFR is offered again")
    assert.deepEqual(went.byItself, [])
  }
})

test("a folder set up already offers Open CYFR on the setup screen, and none is offered for one that is not or while a setup runs", async () => {
  for (const [state, offered] of [[{folder: "/home/ada/cyfr", found: true}, true], [{folder: "/home/ada/cyfr"}, false],
    [{folder: "/home/ada/cyfr", found: true, ...running(["files"], 2)}, false]]) {
    const {$, went} = await chooser("", state, {}, "#token=t", {docker: [{docker: {ready: true}}],
      setup: {"/bootstrap/setup": [new Promise(() => {})], "/bootstrap/open": [{cyfr: "http://localhost:4000", next: "/"}]}})
    $("here").fire("click")
    await settled()
    assert.equal($("go").hidden, !offered, JSON.stringify(state))
    if (!offered) continue
    $("go").fire("click")
    await settled()
    assert.deepEqual(went.asked.at(-1), ["/bootstrap/open", {picks: 0, run: 0}])
    assert.deepEqual(went.byItself, ["/"])
  }
})

test("a setup done says so, and offers Open CYFR", async () => {
  const done = {setup: {run: 1, folder: "/home/ada/cyfr", steps: ["files", "settings", "images", "start"], done: true, seq: 6}}
  const {$} = await chooser("", {folder: "/home/ada/cyfr", ...done}, {}, "#token=t", {})
  assert.equal($("notice").textContent, "CYFR is set up in /home/ada/cyfr and started.")
  assert.equal($("go").hidden, false, "Open CYFR is offered")
})

test("the chooser names setup's steps as the setup pages do", () => {
  const pages = readFileSync(new URL("../../internal/setup/assets/setup.js", import.meta.url), "utf8")
  const names = (src, pattern) => JSON.parse(JSON.stringify(vm.runInNewContext(`(${pattern.exec(src)[1]})`)))
  assert.deepEqual(names(script, /const steps=(\{[^}]*\})/), names(pages, /const stepNames = (\{[^}]*\})/))
})
