// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The shipped canvas (seed/components/tinctures/local/canvas): its model,
// everything the page does apart from drawing, run here as the page runs
// it (Node strips its types), against a stand-in for window.cyfr; and what
// its sources hold.

import assert from "node:assert/strict"
import {readFileSync, readdirSync} from "node:fs"
import {describe, mock, test} from "node:test"

import {
  EMPTY,
  MAX_RUNS,
  MAX_SCHEDULE_RUNS,
  RETRY_MS,
  STREAMS,
  byNextFire,
  failedFirst,
  fold,
  installed,
  openApp,
  scheduleName,
  start,
  text,
  when
} from "../../../../../seed/components/tinctures/local/canvas/0.2.0/src/model.ts"

const VERSION = new URL("../../../../../seed/components/tinctures/local/canvas/0.2.0/", import.meta.url)
const SCAFFOLD = new URL("../../../lib/compendium/scaffold.ex", import.meta.url)

// Every pending reaction runs: a promise's handlers, then theirs.
const settle = () => new Promise((resolve) => setImmediate(resolve))

// window.cyfr as the canvas uses it. Each stream open waits for the test
// to open it (`accept`) or refuse it (`refuse`), and an open stream ends
// when the test ends it (`end`).
function sdk() {
  const opens = []
  const calls = {ready: 0, open: [], installed: null}
  const cyfr = {
    on(event, handler) {
      assert.equal(event, "installed")
      calls.installed = handler
      return () => {
        calls.installed = null
      }
    },
    stream(name, subject, onEvent) {
      return new Promise((resolve, reject) => {
        const open = {name, subject, closedByPage: false}
        open.send = (data) => onEvent({id: null, event: "message", data})
        open.refuse = (error) => reject(error)
        open.accept = () => {
          let end
          const closed = new Promise((r) => (end = r))
          open.end = end
          resolve({
            closed,
            close() {
              open.closedByPage = true
              end()
            }
          })
        }
        opens.push(open)
      })
    },
    open(ref) {
      calls.open.push(ref)
    },
    ready() {
      calls.ready += 1
    }
  }
  const latest = (name) => opens.filter((open) => open.name === name).at(-1)
  return {cyfr, opens, calls, latest}
}

function started() {
  const shell = sdk()
  const states = []
  const stop = start(shell.cyfr, (state) => states.push(state))
  return {...shell, stop, state: () => states.at(-1) ?? EMPTY}
}

const run = (execution_id, kind, extra = {}) => ({kind, execution_id, reference: `catalyst:local.${execution_id}:1.0.0`, ...extra})

describe("ready()", () => {
  test("is called once, after every stream's open has settled, a refused one among them", async () => {
    const page = started()
    await settle()
    assert.deepEqual(page.opens.map((open) => [open.name, open.subject]), STREAMS.map((name) => [name, null]))
    assert.deepEqual(STREAMS, ["runs.changes", "schedules.changes", "schedule_runs.changes"])

    page.latest("runs.changes").accept()
    page.latest("schedules.changes").refuse(new Error("schedules.changes is not a stream this canvas may read."))
    await settle()
    assert.equal(page.calls.ready, 0, "ready before the last open settled")

    page.latest("schedule_runs.changes").accept()
    await settle()
    assert.equal(page.calls.ready, 1)
    assert.deepEqual(page.state().refusals, {"schedules.changes": "schedules.changes is not a stream this canvas may read."})

    page.latest("runs.changes").send(run("a", "started"))
    await settle()
    assert.equal(page.calls.ready, 1)
    page.stop()
  })

  test("is called when every open is refused, and a refusal with no sentence gets one", async () => {
    const page = started()
    await settle()
    page.latest("runs.changes").refuse(new Error(""))
    page.latest("schedules.changes").refuse("not an error")
    page.latest("schedule_runs.changes").refuse(new Error("Refused."))
    await settle()
    assert.equal(page.calls.ready, 1)
    assert.deepEqual(page.state().refusals, {
      "runs.changes": "This stream could not be opened.",
      "schedules.changes": "This stream could not be opened.",
      "schedule_runs.changes": "Refused."
    })
    page.stop()
  })

  test("is not called once the page stopped before its streams settled", async () => {
    const page = started()
    await settle()
    page.stop()
    for (const open of page.opens) open.accept()
    await settle()
    assert.equal(page.calls.ready, 0)
    assert.ok(page.opens.every((open) => open.closedByPage), "a stream opened after the stop stayed open")
  })
})

describe("the installed apps", () => {
  test("are the shell's list, each with a ref and a name", async () => {
    const page = started()
    page.calls.installed([{ref: "tincture:local.notes", name: "Notes"}, {ref: 1, name: "x"}, null, "t", {name: "y"}])
    assert.deepEqual(page.state().apps, [{ref: "tincture:local.notes", name: "Notes"}])
    page.calls.installed("not a list")
    assert.deepEqual(page.state().apps, [])
    page.stop()
    assert.equal(page.calls.installed, null, "the stopped page still hears the installed apps")
  })

  test("opening one asks the shell to open its ref", () => {
    const shell = sdk()
    openApp(shell.cyfr, {ref: "tincture:local.notes", name: "Notes"})
    assert.deepEqual(shell.calls.open, ["tincture:local.notes"])
  })
})

describe("runs.changes", () => {
  const folded = (...items) => items.reduce((state, item) => fold(state, "runs.changes", item, 1), EMPTY)

  test("keeps the latest kind of each run, newest first, and shows failed runs first", () => {
    const state = folded(
      run("a", "completed", {refresh: true, duration_ms: 12}),
      run("b", "failed", {refresh: true, error: {class: "runtime", message: "it broke"}}),
      run("c", "started", {refresh: true}),
      run("c", "completed"),
      run("d", "started")
    )
    assert.deepEqual(state.runs.map((r) => [r.execution_id, r.kind]), [["d", "started"], ["c", "completed"], ["b", "failed"], ["a", "completed"]])
    assert.deepEqual(failedFirst(state).map((r) => r.execution_id), ["b", "d", "c", "a"])
  })

  test("a start that arrives after the run finished leaves its outcome", () => {
    const state = folded(run("a", "failed", {refresh: true}), run("a", "started"))
    assert.deepEqual(state.runs.map((r) => r.kind), ["failed"])
  })

  test("holds the newest runs alone, and nothing that names no run", () => {
    const items = Array.from({length: MAX_RUNS + 5}, (_, i) => run(`r${i}`, "completed"))
    const state = folded(...items, {kind: "completed"}, {kind: "failed", execution_id: 7})
    assert.equal(state.runs.length, MAX_RUNS)
    assert.equal(state.runs[0].execution_id, `r${MAX_RUNS + 4}`)
    assert.equal(state.runs.at(-1).execution_id, "r5")
  })
})

describe("schedules.changes", () => {
  const schedule = (id, next, extra = {}) => ({kind: "changed", schedule_id: id, name: `Schedule ${id}`, next_run_at: next, ...extra})

  test("keeps each schedule by id, sorted by its next fire, and drops a removed one", () => {
    const items = [
      schedule("s1", "2026-10-28T10:00:00Z"),
      schedule("s2", "2026-10-27T12:00:00Z"),
      schedule("s3", null, {status: "paused"}),
      schedule("s4", "2026-10-27T09:00:00Z"),
      schedule("s1", "2026-10-27T13:00:00Z"),
      {kind: "removed", schedule_id: "s4", name: "Schedule s4", next_run_at: "2026-10-27T09:00:00Z"}
    ]
    const state = items.reduce((s, item) => fold(s, "schedules.changes", item, 1), EMPTY)
    assert.deepEqual(byNextFire(state).map((s) => [s.schedule_id, s.next_run_at]), [
      ["s2", "2026-10-27T12:00:00Z"],
      ["s1", "2026-10-27T13:00:00Z"],
      ["s3", null]
    ])
  })

  test("a reopened stream keeps only the schedules its refresh delivers", async (t) => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    const page = started()
    await settle()
    for (const open of page.opens) open.accept()
    const first = page.latest("schedules.changes")
    first.send(schedule("s1", "2026-10-28T10:00:00Z", {refresh: true}))
    first.send(schedule("s2", "2026-10-29T10:00:00Z", {refresh: true}))
    await settle()
    assert.deepEqual(byNextFire(page.state()).map((s) => s.schedule_id), ["s1", "s2"])

    // The stream ends; s1 is removed while it is away.
    first.end()
    await settle()
    assert.equal(page.opens.filter((open) => open.name === "schedules.changes").length, 1, "reopened before its pause")
    t.mock.timers.tick(RETRY_MS[0])
    await settle()
    const second = page.latest("schedules.changes")
    assert.notEqual(second, first, "the ended stream was not opened again")

    // Its refresh can arrive before the open resolves.
    second.send(schedule("s2", "2026-10-29T10:00:00Z", {refresh: true}))
    second.accept()
    await settle()
    assert.deepEqual(byNextFire(page.state()).map((s) => s.schedule_id), ["s2"])
    assert.equal(page.calls.ready, 1, "a reopen called ready() again")
    page.stop()
    assert.ok(second.closedByPage)
  })

  test("a reopen that fails is tried again later, and the page keeps what it shows", async (t) => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    const page = started()
    await settle()
    for (const open of page.opens) open.accept()
    page.latest("schedules.changes").send(schedule("s1", "2026-10-28T10:00:00Z", {refresh: true}))
    page.latest("schedules.changes").end()
    await settle()
    t.mock.timers.tick(RETRY_MS[0])
    await settle()
    page.latest("schedules.changes").refuse(new Error("unreachable"))
    await settle()
    assert.deepEqual(byNextFire(page.state()).map((s) => s.schedule_id), ["s1"])
    assert.deepEqual(page.state().refusals, {}, "a failed reopen replaced the section")
    const before = page.opens.length
    t.mock.timers.tick(RETRY_MS[1])
    await settle()
    assert.equal(page.opens.length, before + 1)
    page.stop()
  })
})

describe("schedule_runs.changes", () => {
  test("keeps the last runs, newest first, one per occurrence, named by their schedule", () => {
    let state = fold(EMPTY, "schedules.changes", {kind: "changed", schedule_id: "s1", name: "Morning report"}, 1)
    const fired = (occurrence, extra = {}) => ({kind: "fired", schedule_id: "s1", occurrence_id: occurrence, scheduled_for: "2026-10-27T08:00:00Z", ...extra})
    for (let i = 0; i < MAX_SCHEDULE_RUNS + 3; i++) state = fold(state, "schedule_runs.changes", fired(`o${i}`), 1)
    state = fold(state, "schedule_runs.changes", fired("o12", {kind: "failed", reason: "timeout"}), 1)
    assert.equal(state.scheduleRuns.length, MAX_SCHEDULE_RUNS)
    assert.deepEqual(state.scheduleRuns.slice(0, 2).map((r) => [r.occurrence_id, r.kind]), [["o12", "failed"], ["o11", "fired"]])
    assert.equal(state.scheduleRuns.at(-1).occurrence_id, "o3")
    assert.equal(scheduleName(state, "s1"), "Morning report")
    assert.equal(scheduleName(state, "s9"), "s9")
    assert.equal(scheduleName(state, null), "")
  })
})

describe("every value is drawn as text", () => {
  test("a string as itself, a finite number as its digits, anything else as nothing", () => {
    assert.equal(text("a"), "a")
    assert.equal(text(42), "42")
    for (const value of [null, undefined, {a: 1}, ["x"], NaN, Infinity, true]) assert.equal(text(value), "")
    assert.equal(when(null, "never"), "never")
    assert.equal(when("not a time", "never"), "never")
  })

  test("no source of the page sets markup, and none reaches another origin", () => {
    const sources = files(new URL("src/", VERSION)).concat([new URL("index.html", VERSION)])
    assert.ok(sources.some((file) => file.pathname.endsWith("/App.tsx")))
    for (const file of sources) {
      const body = readFileSync(file, "utf8")
      assert.doesNotMatch(body, /dangerouslySetInnerHTML|innerHTML|outerHTML|insertAdjacentHTML/, file.pathname)
      assert.doesNotMatch(body, /https?:\/\/|@import|url\(/, file.pathname)
    }
  })

  test("the page and its manifest use none of the words a person never reads", () => {
    const manifest = readFileSync(new URL("cyfr-manifest.json", VERSION), "utf8")
    const sources = files(new URL("src/", VERSION)).map((file) => readFileSync(file, "utf8"))
    for (const body of [manifest, ...sources]) {
      assert.doesNotMatch(body, /\b(homes?|glass(es)?|hubs?|cells?|nodes?|doors?)\b/i)
    }
  })
})

describe("the package", () => {
  test("its dependencies are exactly the react template's, and its lockfile's root names the same", () => {
    const template = reactTemplatePackages()
    assert.ok(Object.keys(template.dependencies).includes("react"))
    const manifest = JSON.parse(readFileSync(new URL("package.json", VERSION), "utf8"))
    assert.deepEqual(manifest.dependencies, template.dependencies)
    assert.deepEqual(manifest.devDependencies, template.devDependencies)
    const lock = JSON.parse(readFileSync(new URL("package-lock.json", VERSION), "utf8"))
    assert.deepEqual(lock.packages[""].dependencies, template.dependencies)
    assert.deepEqual(lock.packages[""].devDependencies, template.devDependencies)
  })
})

// The files under a directory, recursively.
function files(dir) {
  return readdirSync(dir, {withFileTypes: true}).flatMap((entry) => {
    const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), dir)
    return entry.isDirectory() ? files(url) : [url]
  })
}

// `@react_packages` in Compendium.Scaffold, the react template's packages.
function reactTemplatePackages() {
  const source = readFileSync(SCAFFOLD, "utf8")
  const block = source.match(/^ {2}@react_packages %\{\n([\s\S]*?)^ {2}\}$/m)
  assert.ok(block, "Compendium.Scaffold names no @react_packages")
  const group = (name) => {
    const body = block[1].match(new RegExp(`"${name}" => %\\{([^}]*)\\}`))
    assert.ok(body, `@react_packages names no ${name}`)
    return Object.fromEntries([...body[1].matchAll(/"([^"]+)" => "([^"]+)"/g)].map((m) => [m[1], m[2]]))
  }
  return {dependencies: group("dependencies"), devDependencies: group("devDependencies")}
}
