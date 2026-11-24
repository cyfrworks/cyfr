// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The setup proof in the installed app (../app.sh): the app's own setup
// of CYFR on this computer, from no Docker to Prism, driven from inside its
// main process (tests/desktop-proof/lib.js). The system's folder dialog is
// stood in for, answering the folder the run seeded (inputs.folder): the
// real dialog is a person's to check. Everything else is real: Docker,
// sg, Compose, the CYFR set up and the app.
import electron from "electron"
import {createHash} from "node:crypto"
import {existsSync, readFileSync, writeFileSync} from "node:fs"
import path from "node:path"

import * as lib from "../../desktop-proof/lib.js"
import {accountAt, accountWindow, armWindow} from "../../desktop-proof/account.js"

const {FIXTURE, inputs, row, judged, waitFor, js, submit, contentAt, atBootstrap, atDevice, atHome} = lib
const FOLDER = inputs.folder
electron.dialog.showOpenDialog = async () => ({canceled: false, filePaths: [FOLDER]})

// The passkey launch records the network service's events from its start
// (each session's record is the service's whole), for app.sh to read what
// was sent: no request line or header, a referrer among them, carries the
// setup token. The record keeps each request's address as the engine holds
// it, fragment and all, so it stays in the fixture and is not uploaded.
// The stores are the CYFR's own and its account service's, as main names
// them (src/policy.js homePartition, accountPartition).
const digest = (origin) => createHash("sha256").update(origin, "ascii").digest("hex")
const PARTITIONS = [`persist:cyfr-home-v2-${digest(lib.HOME)}`,
  `persist:cyfr-account-v2-${digest(lib.HOME)}-${digest(new URL(lib.DIRECTORY).origin)}`]
const sessions = () => [electron.session.defaultSession, ...PARTITIONS.map((p) => electron.session.fromPartition(p))]
if (lib.PHASE === "passkey") {
  electron.app.whenReady().then(() => Promise.all(sessions().map((ses, i) => ses.netLog.startLogging(path.join(FIXTURE, `netlog-${i}.json`)))))
}

// A word with app.sh, which acts on the host: the proof asks, app.sh does
// it and answers.
async function ask(what) {
  writeFileSync(path.join(FIXTURE, `asked-${what}`), "")
  await waitFor(() => existsSync(path.join(FIXTURE, `done-${what}`)), `app.sh to ${what}`, 120_000)
}

// What the chooser shows, read within 5 s: a read the page does not
// answer is logged and counts as none, so no wait outlives its bound on a
// page that stopped answering.
const shown = (w) => new Promise((resolve, reject) => {
  const wc = w.webContents
  const bound = setTimeout(() => {
    lib.log(`no answer in 5 s from the chooser (crashed ${wc.isCrashed()}, loading ${wc.isLoading()}, at ${wc.getURL().split("#")[0]})`)
    reject(new Error("the chooser did not answer within 5 s"))
  }, 5000)
  read(w).then(resolve, reject).finally(() => clearTimeout(bound))
})
// A launch's steps and the main process's own pace, in its log: each step
// as it begins, and any second main's loop was held past 1.5 s.
const step = (what) => lib.log(`step: ${what}`)
let beat = Date.now()
setInterval(() => {
  const now = Date.now()
  if (now - beat > 1500) lib.log(`main's loop was held ${now - beat} ms`)
  beat = now
}, 1000).unref()
// The lost renderer's process until it is gone, within 60 s: each
// state it passes through (/proc/PID/stat), so a slow end shows what held it.
function watchEnd(pid) {
  let last = ""
  const until = Date.now() + 60_000
  const look = () => {
    let now
    try {
      now = readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1].split(" ")[0]
    } catch {
      now = "gone"
    }
    if (now !== last) lib.log(`renderer ${pid}: ${now}`)
    last = now
    if (now !== "gone" && Date.now() < until) setTimeout(look, 250).unref()
  }
  look()
}
const read = (w) => js(w.webContents, `(() => {
  const $ = (i) => document.querySelector("#" + i)
  return {docker: $("docker").textContent, commands: $("commands").hidden ? "" : $("commands").textContent,
    start: !$("start").hidden, folder: $("folder").textContent, progress: $("progress").hidden ? [] : $("progress").textContent.split("\\n"),
    notice: $("notice").textContent, go: !$("go").hidden, retry: !$("retry").hidden}
})()`)
const answered = (w) => waitFor(async () => {
  const s = await shown(w)
  return s.docker && !s.docker.startsWith("Checking") ? s : null
}, "Docker's answer")
const press = (w, id) => js(w.webContents, `document.querySelector("#${id}").click(); 1`)
const envHash = () => createHash("sha256").update(readFileSync(path.join(FOLDER, ".env"))).digest("hex")

// The folder picked through Change…, as main's answer names it.
async function pick(w) {
  await press(w, "change")
  await waitFor(async () => (await shown(w)).folder === FOLDER || null, "the folder picked")
}

async function prism(at = atHome) {
  const w = await contentAt(at, "Prism")
  return waitFor(() => js(w.webContents, `!!document.querySelector("[data-phx-main].phx-connected") || null`), "Prism's live connection")
}

// Prism of the CYFR at `home`, live in the content.
const atCYFR = (home) => (url) => url.startsWith(home + "/") && !/^\/(login|setup|auth\/|account\/)/.test(new URL(url).pathname)

// The CYFR's setup page, once a setup that made `token` opened it, its
// first person `name` made with a passkey in the app's account window:
// whether it opened there, at which account page, and Prism live after.
async function firstByPasskey(token, name) {
  const setup = await waitFor(() => {
    const c = lib.content()
    return c && !c.webContents.isLoading() && c.webContents.getURL().startsWith(lib.HOME + "/setup") ? c : null
  }, "the CYFR's setup page", 300_000)
  const opened = setup.webContents.getURL() === `${lib.HOME}/setup#${token}`
  await waitFor(() => js(setup.webContents, `!!document.querySelector('[data-test="setup-create"]') && !!document.querySelector(".phx-connected")`),
    "Create your account")
  await js(setup.webContents, `document.querySelector('[data-test="setup-create"]').click(); 1`)
  const a = await waitFor(() => accountWindow(), "the app's account window")
  await armWindow(a)
  await lib.section(a.webContents, ["choose"])
  const at = new URL(a.webContents.getURL()).pathname
  await js(a.webContents, `document.querySelector("#name").value = ${JSON.stringify(name)};
    document.querySelector("#name").dispatchEvent(new Event("input", {bubbles: true}));
    const ok = document.querySelector("#acceptance:not([hidden]) #accept"); if (ok) ok.click();
    document.querySelector("#create").click(); 1`)
  await lib.section(a.webContents, ["show-code"])
  await js(a.webContents, `document.querySelector("#saved").click(); 1`)
  await lib.section(a.webContents, ["done-return"])
  await armWindow(a)
  await js(a.webContents, `document.querySelector("#continue").click(); 1`)
  const live = await prism()
  return {ok: opened && at === "/account/new" && !!live && !accountWindow(), detail: {opened, at}}
}

// The folder's setup token, once its .env holds it.
const tokenIn = (folder) => waitFor(() => existsSync(path.join(folder, ".env")) &&
  /^CYFR_SETUP_TOKEN=([0-9a-f]{64})$/m.exec(readFileSync(path.join(folder, ".env"), "utf8"))?.[1], "the folder's setup token")

// A press on the rail: its own top frame going to `to`, which main answers.
async function railTo(to) {
  const r = await waitFor(() => lib.rail(), "the rail")
  await js(r.webContents, `location.assign(${JSON.stringify(to)}); 1`)
}
const rows = () => js(lib.rail().webContents, `[...document.querySelectorAll("#cyfrs a")].map((a) => ({cyfr: a.title,
  open: a.getAttribute("aria-current") === "page"}))`)

// The session cookie each folder's CYFR keeps in its own store, and
// whether it opens that CYFR and not the other: two stores of one host,
// localhost, apart only by port.
const store = (home) => electron.session.fromPartition(`persist:cyfr-home-v2-${digest(home)}`)
async function signIns(homes) {
  const out = {}
  for (const home of homes) {
    const kept = await store(home).cookies.get({name: "_cyfr_key"})
    const value = kept.length === 1 ? kept[0].value : null
    out[home] = {kept: kept.map((c) => `${c.name}@${c.domain}`), digest: value && createHash("sha256").update(value).digest("hex").slice(0, 16),
      opens: Object.fromEntries(await Promise.all(homes.map(async (at) => [at, value ? (await lib.opens(value, at)).opens : null])))}
  }
  return out
}

lib.run("setup", {
  async first() {
    const w = await contentAt(atBootstrap, "the chooser")
    await waitFor(async () => (await shown(w)).folder || null, "the folder shown")
    await press(w, "here")
    const id = w.webContents.id
    // Check again's own answer is missing_to_ready's; what it says, the
    // socket given to an app process without the group, is stale's.
    let after = null
    await judged("missing_to_ready", "with no Docker the setup screen says so and shows the commands to run, then Check again in the same window answers again",
      async () => {
        const missing = await answered(w)
        await ask("give-docker")
        await press(w, "check")
        after = await waitFor(async () => {
          const s = await shown(w)
          return s.docker && !s.docker.startsWith("Checking") && s.docker !== missing.docker ? s : null
        }, "Check again's answer")
        const same = lib.content()?.webContents.id === id
        return [missing.docker === "Docker does not answer this account: the Docker daemon is not reachable." && missing.commands.includes("sudo systemctl enable --now docker") &&
          !missing.start && same, {missing, after, same}]
      })
    const groups = process.getgroups()
    row("stale", after?.docker === "Docker answers on this computer." && after.start && !groups.includes(inputs.docker_gid),
      "Docker answers and Set up and start is offered, though the app's own process lacks the docker group its account has: through sg",
      {after, groups, docker_gid: inputs.docker_gid})
    await pick(w)
    await press(w, "start")
    await judged("downloading", "Set up and start shows each of its steps as it begins, in order, up to the download", async () => {
      const s = await waitFor(async () => {
        const t = await shown(w)
        return t.progress.at(-1) === "Downloading CYFR…" ? t : null
      }, "the download")
      const steps = [`Setting up CYFR in ${FOLDER}`, "Getting CYFR's files", "Writing its settings", "Downloading CYFR…"]
      return [s.progress.join("|") === steps.join("|"), {progress: s.progress}]
    })
    // The person quits while CYFR downloads: app.sh then holds the `quit` row.
    return "quit"
  },
  async again() {
    const w = await contentAt(atBootstrap, "the chooser")
    await waitFor(async () => (await shown(w)).folder || null, "the folder shown")
    await press(w, "here")
    await answered(w)
    await pick(w)
    const before = envHash()
    step("Set up and start pressed")
    await press(w, "start")
    const first = await waitFor(async () => {
      const s = await shown(w)
      return s.progress.length > 0 ? s : null
    }, "the setup's progress")
    step(`the progress shown: ${JSON.stringify(first.progress.slice(1))}`)
    // The renderer lost mid-run: on a desktop nothing locks with no CYFR
    // open, so this is the one way a chooser is shown anew during a run.
    // It is killed, which dumps no core: a crash's core, where the host
    // pipes it to systemd-coredump told no limit (GitHub's arm64 runners),
    // keeps the renderer until its dump is taken, minutes on end.
    step("the renderer killed")
    const pid = w.webContents.getOSProcessId()
    watchEnd(pid)
    process.kill(pid, "SIGKILL")
    await judged("reshown", "the chooser shown again mid-run shows the setup's progress while its start is held, and once it is released and done offers Open CYFR, opening nothing by itself",
      async () => {
        const c = await contentAt(atBootstrap, "the chooser shown again")
        // The start is held (app.sh's docker): the page in the lost one's
        // place shows the run so far while the work is still pending.
        // Both are waited for together: the page can show the start before
        // the held docker has recorded it.
        const pending = await waitFor(async () => {
          const s = await shown(c).catch(() => null)
          const held = readFileSync("/tmp/docker-calls", "utf8").split("\n").some((l) => / up( |$)/.test(l)) && !existsSync("/tmp/up-go")
          return held && s?.progress.join("|") === `Setting up CYFR in ${FOLDER}|Starting CYFR…` ? s : null
        }, "the progress on the page shown again, with the start held")
        step("the start released")
        writeFileSync("/tmp/up-go", "")
        const done = await waitFor(async () => {
          const s = await shown(c)
          return s.notice.startsWith("CYFR is set up in") ? s : null
        }, "the setup done", 300_000)
        await lib.sleep(2000) // sleep-ok: nothing should open by itself in this time
        const still = atBootstrap(lib.content()?.webContents.getURL() ?? "")
        return [!pending.go && done.go && still && done.notice === `CYFR is set up in ${FOLDER} and started.`, {pending, done, still}]
      })
    const c = lib.content()
    const s = await shown(c)
    row("partial", s.progress.join("|") === `Setting up CYFR in ${FOLDER}|Starting CYFR` && envHash() === before,
      "a folder whose setup stopped in its download goes on from what is there: its one step is the start, and .env is as it was",
      {progress: s.progress, envUnchanged: envHash() === before})
    await press(c, "go")
    await judged("first_person", "Open CYFR opens it at its first person's page, and the first person's setup ends in Prism, live", async () => {
      const d = await contentAt(atDevice, "the device's pages")
      const offered = (await lib.text(d.webContents)).includes("Set up CYFR")
      await submit(d.webContents, "/passphrase")
      const passphrase = await waitFor(() => js(d.webContents, `document.querySelector("p.code")?.textContent.trim() || null`), "the passphrase")
      await submit(d.webContents, "/setup", {name: "desk-setup", secret: passphrase, again: passphrase})
      await waitFor(() => js(d.webContents, `[...document.querySelectorAll("h1")].some((h) => h.textContent === "Your recovery code") || null`), "the recovery code")
      await submit(d.webContents, "/saved")
      return [offered && await prism(), {offered}]
    })
  },
  // The passkey road, as on macOS and Windows, on a second folder: its
  // CYFR opens at its own setup page, whose Create your account makes the
  // account with a passkey in the app's account window (a virtual
  // authenticator stands in for the computer's), and that account is its
  // first person.
  async passkey() {
    const w = await contentAt(atBootstrap, "the chooser")
    await waitFor(async () => (await shown(w)).folder || null, "the folder shown")
    await press(w, "here")
    await answered(w)
    await pick(w)
    await press(w, "start")
    const token = await tokenIn(FOLDER)
    writeFileSync(path.join(FIXTURE, "setup-token"), token)
    // The row is app.sh's, decided once the app has quit: this launch's
    // part of it (what the person sees) is written for it here. A whole
    // setup first, files, settings, download and start.
    const part = await firstByPasskey(token, "desk-first").catch((e) => ({ok: false, threw: String(e?.message ?? e)}))
    writeFileSync(path.join(FIXTURE, "first-passkey.json"), JSON.stringify(part))
    await Promise.all(sessions().map((ses) => ses.netLog.stopLogging()))
    return "quit"
  },
  // Two folders on two ports of one host, both running: the one set up
  // in the passkey launch (inputs.other) and a third, set up here. The app
  // opens the one selected last by itself, signed in as it was; Set up on
  // the rail adds the other as a row of its own; each keeps its own
  // sign-in in its own store, though both are at localhost; pressing each
  // row switches to it, still signed in.
  async two() {
    const OTHER = inputs.other
    // Which store is two_apart's to read; this row, that the one opened is
    // kept on disk.
    await judged("two_reopened", "the folder's CYFR selected last opens by itself as the app starts, signed in as before, in a store kept on disk",
      async () => {
        const w = await contentAt(atCYFR(OTHER), "the CYFR selected last")
        const live = await waitFor(() => js(w.webContents, `!!document.querySelector("[data-phx-main].phx-connected") || null`), "Prism live")
        const kept = !!w.webContents.session.getStoragePath()
        return [!!live && kept, {at: w.webContents.getURL().split("#")[0], kept}]
      })
    await judged("two_set_up", "Set up on the rail sets CYFR up in a second folder on its own port, its first person made with a passkey, and adds it as a row of its own beside the first",
      async () => {
        await railTo("/rail/setup")
        const w = await contentAt(atBootstrap, "the chooser at Set up")
        await answered(w)
        await pick(w)
        await press(w, "start")
        const first = await firstByPasskey(await tokenIn(FOLDER), "desk-second")
        const listed = await waitFor(async () => (await rows()).length === 2 ? rows() : null, "both folders on the rail")
        return [first.ok && listed.some((r) => r.cyfr === OTHER) && listed.find((r) => r.cyfr === lib.HOME)?.open, {first, listed}]
      })
    const homes = [OTHER, lib.HOME]
    await judged("two_apart", "each folder's CYFR keeps its own sign-in in its own store, though both are at localhost: each one's cookie opens its own CYFR and not the other's",
      async () => {
        const got = await signIns(homes)
        const own = homes.every((h) => got[h].kept.length === 1 && got[h].opens[h] === true && homes.every((o) => o === h || got[h].opens[o] === false))
        return [own && got[OTHER].digest !== got[lib.HOME].digest, got]
      })
    await judged("two_back", "pressing each folder's row switches to its CYFR, still signed in there, in its own store", async () => {
      const before = await signIns(homes)
      const seen = []
      for (const home of [OTHER, lib.HOME]) {
        await railTo("/rail/select?cyfr=" + encodeURIComponent(home))
        const w = await contentAt(atCYFR(home), `Prism at ${home}`)
        const live = await waitFor(() => js(w.webContents, `!!document.querySelector("[data-phx-main].phx-connected") || null`), `Prism live at ${home}`)
        seen.push({home, live: !!live, own: w.webContents.session === store(home)})
      }
      const after = await signIns(homes)
      return [seen.every((v) => v.live && v.own) && homes.every((h) => after[h].digest === before[h].digest), {seen, before, after}]
    })
    return "quit"
  },
}, {accountRoad: ["passkey", "two"].includes(lib.PHASE)})
