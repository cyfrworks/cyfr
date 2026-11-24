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

const {FIXTURE, inputs, row, judged, waitFor, js, submit, contentAt, atBootstrap, atDevice, atHome} = lib
const FOLDER = inputs.folder
electron.dialog.showOpenDialog = async () => ({canceled: false, filePaths: [FOLDER]})

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
})
