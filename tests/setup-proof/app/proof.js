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
async function ask(what, ms = 120_000) {
  writeFileSync(path.join(FIXTURE, `asked-${what}`), "")
  await waitFor(() => existsSync(path.join(FIXTURE, `done-${what}`)), `app.sh to ${what}`, ms)
  return readFileSync(path.join(FIXTURE, `done-${what}`), "utf8").trim()
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
const said = (w) => js(w.webContents, `document.querySelector("#notice").textContent`)
// The docker calls made on this computer, as the wrapper logs them, and
// those of them from the `from`th on that start anything.
const calls = () => readFileSync("/tmp/docker-times", "utf8").split("\n").filter((l) => /^\S/.test(l))
const starts = (from) => calls().slice(from).filter((l) => !/^\S+ exit /.test(l) && /(^| )(up|start|run)( |$)/.test(l.replace(/^\S+ /, "")))
// Prism of the launch's CYFR, the store main keeps it in (src/policy.js
// homePartition), and the digest of the sign-in that store keeps.
const atCYFR = (url) => url.startsWith(lib.HOME + "/") && !/^\/(login|setup|auth\/|account\/)/.test(new URL(url).pathname)
const store = () => electron.session.fromPartition(PARTITIONS[0])
async function signedIn() {
  const kept = await store().cookies.get({name: "_cyfr_key"})
  return kept.length === 1 ? createHash("sha256").update(kept[0].value).digest("hex").slice(0, 16) : ""
}
// A press on the rail: its own top frame going to `to`, which main answers.
async function railTo(to) {
  const r = await waitFor(() => lib.rail(), "the rail")
  await js(r.webContents, `location.assign(${JSON.stringify(to)}); 1`)
}
const rows = () => js(lib.rail().webContents, `[...document.querySelectorAll("#cyfrs a")].map((a) => ({cyfr: a.title,
  open: a.getAttribute("aria-current") === "page"}))`)
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

async function prism() {
  const w = await contentAt(atHome, "Prism")
  return waitFor(() => js(w.webContents, `!!document.querySelector("[data-phx-main].phx-connected") || null`), "Prism's live connection")
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
    const token = await waitFor(() => existsSync(path.join(FOLDER, ".env")) &&
      /^CYFR_SETUP_TOKEN=([0-9a-f]{64})$/m.exec(readFileSync(path.join(FOLDER, ".env"), "utf8"))?.[1], "the folder's setup token")
    writeFileSync(path.join(FIXTURE, "setup-token"), token)
    // The row is app.sh's, decided once the app has quit: this launch's
    // part of it (what the person sees) is written for it here.
    const part = await (async () => {
      // A whole setup first, files, settings, download and start.
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
      await js(a.webContents, `document.querySelector("#name").value = "desk-first";
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
    })().catch((e) => ({ok: false, threw: String(e?.message ?? e)}))
    writeFileSync(path.join(FIXTURE, "first-passkey.json"), JSON.stringify(part))
    // The sign-in it leaves, by digest, which the later launches' CYFR is
    // to be opened under.
    writeFileSync(path.join(FIXTURE, "passkey-session"), await signedIn())
    await Promise.all(sessions().map((ses) => ses.netLog.stopLogging()))
    return "quit"
  },
  // The passkey launch's folder, the one a person has on this computer,
  // its CYFR stopped by cyfr down there (app.sh): the CYFR selected last
  // does not open as the app starts, and says why; after cyfr up there,
  // Try again opens it, signed in from its own store on disk.
  async stopped() {
    const from = calls().length
    const w = await contentAt(atBootstrap, "the chooser")
    await judged("stopped_reopen", "the folder's CYFR selected last, stopped by cyfr down in its folder, does not open as the app starts: the chooser says why, naming the folder, and offers Try again, the rail lists it, and nothing of its stack starts",
      async () => {
        const notice = await waitFor(async () => (await said(w)).includes(FOLDER) && said(w), "the reason, naming the folder")
        const again = await js(w.webContents, `!document.querySelector("#reopen").hidden`)
        const listed = await waitFor(async () => lib.rail() && (await rows()).length ? rows() : null, "the rail's rows")
        const started = starts(from)
        return [again && listed.some((r) => r.cyfr === lib.HOME) && started.length === 0, {notice, again, listed, started}]
      })
    await judged("try_again", "after cyfr up in its folder, Try again opens it, signed in as the passkey launch left it, from its own store kept on disk",
      async () => {
        const up = await ask("up", 330_000)
        await press(w, "reopen")
        const c = await contentAt(atCYFR, "the CYFR's Prism")
        const live = await waitFor(() => js(c.webContents, `!!document.querySelector("[data-phx-main].phx-connected") || null`), "Prism live")
        const own = c.webContents.session === store() && !!store().getStoragePath()
        const session = await signedIn()
        const before = readFileSync(path.join(FIXTURE, "passkey-session"), "utf8")
        return [up === "0" && !!live && own && !!session && session === before, {up, at: c.webContents.getURL().split("#")[0], own, same: session === before}]
      })
    return "quit"
  },
  // Stopped again by cyfr down: its row pressed on the rail says why and
  // starts nothing.
  async pressed() {
    const w = await contentAt(atBootstrap, "the chooser")
    await waitFor(() => js(w.webContents, `!document.querySelector("#reopen").hidden || null`), "the reopen's answer")
    await judged("stopped_press", "pressing the folder's row on the rail while its CYFR is stopped by cyfr down says why, naming the folder, and nothing of its stack starts",
      async () => {
        await js(w.webContents, `document.querySelector("#notice").textContent = ""; 1`)
        const from = calls().length
        await railTo("/rail/select?cyfr=" + encodeURIComponent(lib.HOME))
        const notice = await waitFor(async () => {
          const c = lib.content()
          return c && atBootstrap(c.webContents.getURL()) && (await said(c)).includes(FOLDER) ? said(c) : null
        }, "the reason, naming the folder")
        const started = starts(from)
        return [started.length === 0, {notice, started}]
      })
    return "quit"
  },
}, {accountRoad: ["passkey", "stopped", "pressed"].includes(lib.PHASE)})
