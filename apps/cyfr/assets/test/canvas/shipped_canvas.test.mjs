// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The shipped canvas (seed/components/tinctures/local/canvas): its model,
// everything the page does apart from drawing, run here as the page runs
// it (Node strips its types), against a stand-in for window.cyfr; and what
// its sources hold.

import assert from "node:assert/strict"
import {readFileSync, readdirSync} from "node:fs"
import {describe, mock, test} from "node:test"

import {createClient} from "../../js/sdk/client.js"
import {CREDENTIAL, HANDSHAKE} from "../../js/sdk/wire.js"
import {fixture} from "../sdk/support.mjs"

import {
  EMPTY,
  GRANTABLE,
  MAX_RUNS,
  MAX_SCHEDULE_RUNS,
  MONOGRAM_HUES,
  RETRY_MS,
  STREAMS,
  attentionColumn,
  byNextFire,
  causes,
  componentName,
  componentRef,
  covered,
  fold,
  grantable,
  grantComponent,
  installed,
  monogram,
  openApp,
  postured,
  recentRows,
  relative,
  scheduleRows,
  shortReason,
  start,
  strip,
  text,
  today,
  week
} from "../../../../../seed/components/tinctures/local/canvas/0.3.0/src/model.ts"

const VERSION = new URL("../../../../../seed/components/tinctures/local/canvas/0.3.0/", import.meta.url)
const SCAFFOLD = new URL("../../../lib/compendium/scaffold.ex", import.meta.url)

// Every pending reaction runs: a promise's handlers, then theirs.
const settle = () => new Promise((resolve) => setImmediate(resolve))

// window.cyfr as the canvas uses it. Each stream open waits for the test
// to open it (`accept`) or refuse it (`refuse`), and an open stream ends
// when the test ends it (`end`).
function sdk() {
  const opens = []
  const calls = {ready: 0, open: [], grant: [], installed: null, covered: null, posture: null}
  const cyfr = {
    on(event, handler) {
      assert.ok(["installed", "covered", "posture"].includes(event), event)
      calls[event] = handler
      return () => {
        calls[event] = null
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
    grant(ref) {
      calls.grant.push(ref)
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

// What the SDK rejects a stream open with for `answer`, one of
// tests/fixtures/tincture_wire.json's stream_rejections: its own
// rejection, as the page meets it.
async function rejection(answer) {
  const win = {location: {pathname: "/"}, parent: {}}
  const fetchFn = async () => {
    if (answer === null) throw new TypeError("Failed to fetch")
    const body = answer.text ?? JSON.stringify(answer.body)
    return new Response(body, {status: answer.status, headers: {"content-type": "application/json"}})
  }
  const {api, onWindowMessage} = createClient({win, fetchFn, base: "https://cyfr.test/"})
  const channel = new MessageChannel()
  onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: "frm_shipped_canvas"}, ports: [channel.port2]})
  channel.port1.postMessage({v: 1, type: CREDENTIAL, frame: "frm_shipped_canvas", credential: "frm.v2.shipped"})
  try {
    await api.stream("runs.changes", null, () => {})
  } catch (error) {
    return error
  } finally {
    channel.port1.close()
  }
  assert.fail(`the SDK opened a stream on ${JSON.stringify(answer)}`)
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

describe("a stream's first open", () => {
  test("one the endpoint could not be reached for is opened again on the retry pauses, and the page is ready meanwhile", async (t) => {
    const unreachable = await rejection(null)
    t.mock.timers.enable({apis: ["setTimeout"]})
    const page = started()
    await settle()

    for (const open of page.opens) open.refuse(unreachable)
    await settle()
    assert.equal(page.calls.ready, 1)
    assert.deepEqual(page.state().refusals, {})
    assert.equal(page.opens.length, STREAMS.length)

    // Opened again after the first pause, and after the next one when that
    // open fails too.
    t.mock.timers.tick(RETRY_MS[0] - 1)
    await settle()
    assert.equal(page.opens.length, STREAMS.length, "opened again before its pause")
    t.mock.timers.tick(1)
    await settle()
    assert.equal(page.opens.length, 2 * STREAMS.length, "no retry was scheduled after the first open's network failure")

    for (const open of page.opens.slice(STREAMS.length)) open.refuse(unreachable)
    await settle()
    t.mock.timers.tick(RETRY_MS[1])
    await settle()
    assert.equal(page.opens.length, 3 * STREAMS.length)

    // The server is back: each stream opens and delivers.
    for (const open of page.opens.slice(2 * STREAMS.length)) open.accept()
    page.latest("runs.changes").send(run("a", "failed", {refresh: true}))
    await settle()
    assert.deepEqual(page.state().runs.map((r) => r.execution_id), ["a"])
    assert.deepEqual(page.state().refusals, {})
    assert.equal(page.calls.ready, 1)
    page.stop()
  })

  test("each SDK rejection the wire vectors list is tried again when unanswered and final when refused", async (t) => {
    const cases = []
    for (const vector of fixture.stream_rejections.cases) cases.push({...vector, error: await rejection(vector.answer)})
    assert.ok(cases.some(({rejects}) => rejects.class === "unavailable"))
    assert.ok(cases.some(({rejects}) => rejects.class !== "unavailable"))

    t.mock.timers.enable({apis: ["setTimeout"]})
    for (const {answer, rejects, error} of cases) {
      const label = JSON.stringify(answer)
      assert.equal(error.code, rejects.class, label)
      const page = started()
      await settle()
      for (const open of page.opens) open.refuse(error)
      await settle()
      assert.equal(page.calls.ready, 1, label)

      if (rejects.class === "unavailable") {
        assert.deepEqual(page.state().refusals, {}, label)
        t.mock.timers.tick(RETRY_MS[0])
        await settle()
        assert.equal(page.opens.length, 2 * STREAMS.length, label)
      } else {
        assert.deepEqual(page.state().refusals, Object.fromEntries(STREAMS.map((name) => [name, rejects.message])), label)
        t.mock.timers.tick(RETRY_MS.at(-1))
        await settle()
        assert.equal(page.opens.length, STREAMS.length, `${label} was opened again`)
      }
      page.stop()
    }
  })

  test("a refusal met on a retry of an unanswered first open is final and shown", async (t) => {
    const unreachable = await rejection(null)
    const refusal = await rejection(fixture.stream_rejections.cases.find(({rejects}) => rejects.class === "forbidden").answer)
    t.mock.timers.enable({apis: ["setTimeout"]})
    const page = started()
    await settle()

    for (const open of page.opens) open.refuse(unreachable)
    await settle()
    t.mock.timers.tick(RETRY_MS[0])
    await settle()
    for (const open of page.opens.slice(STREAMS.length)) open.refuse(refusal)
    await settle()

    assert.deepEqual(page.state().refusals, Object.fromEntries(STREAMS.map((name) => [name, refusal.message])))
    t.mock.timers.tick(RETRY_MS.at(-1))
    await settle()
    assert.equal(page.opens.length, 2 * STREAMS.length)
    page.stop()
  })
})

describe("the installed apps", () => {
  test("are the shell's list, each with a ref, a name, its emoji or none, and whether it is open", async () => {
    const page = started()
    page.calls.installed([
      {ref: "tincture:local.notes", name: "Notes", icon: "📝", open: true},
      {ref: "tincture:local.vault", name: "vault", icon: null, open: false},
      {ref: "tincture:local.odd", name: "odd", icon: "", open: "yes"},
      {ref: 1, name: "x"},
      null,
      "t",
      {name: "y"}
    ])
    assert.deepEqual(page.state().apps, [
      {ref: "tincture:local.notes", name: "Notes", icon: "📝", open: true},
      {ref: "tincture:local.vault", name: "vault", icon: null, open: false},
      {ref: "tincture:local.odd", name: "odd", icon: null, open: false}
    ])
    page.calls.installed("not a list")
    assert.deepEqual(page.state().apps, [])
    page.stop()
    for (const event of ["installed", "covered", "posture"]) {
      assert.equal(page.calls[event], null, `the stopped page still hears ${event}`)
    }
  })

  test("opening one asks the shell to open its ref", () => {
    const shell = sdk()
    openApp(shell.cyfr, {ref: "tincture:local.notes", name: "Notes", icon: null, open: false})
    assert.deepEqual(shell.calls.open, ["tincture:local.notes"])
  })

  test("an app with no emoji gets a monogram, its colour the same for the same name", () => {
    assert.deepEqual(monogram("vault"), monogram("vault"))
    assert.equal(monogram("vault").letter, "V")
    assert.ok(MONOGRAM_HUES.includes(monogram("weather-lookup").hue))
    assert.equal(monogram("").letter, "?")
  })
})

describe("what the shell tells the canvas", () => {
  test("covered keeps the rects that are rects, and a posture only desk or hand", async () => {
    const page = started()
    const rect = {x: 10, y: 20, width: 300, height: 200}
    page.calls.covered([rect, {x: 1}, null, {x: 0, y: 0, width: NaN, height: 1}])
    assert.deepEqual(page.state().covered, [rect])
    page.calls.covered("nothing")
    assert.deepEqual(page.state().covered, [])
    page.calls.posture("hand")
    assert.equal(page.state().posture, "hand")
    page.calls.posture("lap")
    assert.equal(page.state().posture, "hand")
    assert.deepEqual(covered(EMPTY, [rect]).covered, [rect])
    assert.equal(postured(EMPTY, "desk").posture, "desk")
    page.stop()
  })
})

describe("runs.changes", () => {
  const folded = (...items) => items.reduce((state, item) => fold(state, "runs.changes", item, 1), EMPTY)

  test("keeps the latest kind of each run, newest first", () => {
    const state = folded(
      run("a", "completed", {refresh: true, duration_ms: 12}),
      run("b", "failed", {refresh: true, error: {class: "runtime", message: "it broke"}}),
      run("c", "started", {refresh: true}),
      run("c", "completed"),
      run("d", "started")
    )
    assert.deepEqual(state.runs.map((r) => [r.execution_id, r.kind]), [["d", "started"], ["c", "completed"], ["b", "failed"], ["a", "completed"]])
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
    // A schedule's row carries the outcome of its last run heard of.
    assert.equal(scheduleRows(state, new Date("2026-10-27T09:00:00Z"))[0].lastOutcome, "bad")
  })
})

describe("what needs attention", () => {
  const failed = (id, reference, cls, message) =>
    run(id, "failed", {reference, error: {class: cls, message}})
  const NOT_GRANTED = "This account is not granted to the component; grant it first."
  const CAPACITY = "the execution worker refused the start: cyfr-locus refused to start a runner (capacity)"
  const folded = (...items) => items.reduce((state, item) => fold(state, "runs.changes", item, 1), EMPTY)

  // 17 of 20 failed: 15 for want of a grant across five catalysts, two for
  // want of a runner; three finished.
  const day = () => {
    const items = []
    const names = ["openai", "openrouter", "gemini", "grok", "claude"]
    for (let i = 0; i < 15; i++) {
      items.push(failed(`g${i}`, `catalyst:local.${names[i % 5]}:1.4.1`, "setup_required", NOT_GRANTED))
    }
    items.push(failed("c1", "catalyst:local.gemini:1.4.1", "unavailable", CAPACITY))
    items.push(failed("c2", "catalyst:local.openrouter:1.4.1", "unavailable", CAPACITY))
    for (let i = 0; i < 3; i++) items.push(run(`ok${i}`, "completed", {reference: "catalyst:local.claude:1.4.1", duration_ms: 289}))
    return folded(...items)
  }

  test("groups failures by cause, each stated once with the components it hit and their counts", () => {
    const [grant, capacity, ...rest] = causes(day())
    assert.deepEqual(rest, [])
    assert.equal(grant.count, 15)
    assert.equal(grant.message, NOT_GRANTED)
    assert.equal(grant.grantable, true)
    assert.equal(grant.short, "Not granted")
    assert.deepEqual(
      grant.components.map((c) => [c.ref, c.name, c.count]),
      [
        ["catalyst:local.claude", "claude", 3],
        ["catalyst:local.gemini", "gemini", 3],
        ["catalyst:local.grok", "grok", 3],
        ["catalyst:local.openai", "openai", 3],
        ["catalyst:local.openrouter", "openrouter", 3]
      ]
    )
    assert.equal(capacity.count, 2)
    assert.equal(capacity.grantable, false)
    assert.equal(capacity.short, "No runner free")
    assert.deepEqual(capacity.components.map((c) => [c.name, c.count]), [["gemini", 1], ["openrouter", 1]])
  })

  test("a run's stored error, which reads back internal, offers a grant when its sentence asks for one", () => {
    const state = folded(
      failed("a", "catalyst:local.openai:1.4.1", "internal", NOT_GRANTED),
      failed("b", "catalyst:local.openai:1.4.1", "internal", "The grant for this account has expired; grant it again."),
      failed("c", "catalyst:local.openai:1.4.1", "internal", "Granted elsewhere, it says nothing to do here.")
    )
    const byMessage = Object.fromEntries(causes(state).map((c) => [c.message, c]))
    assert.equal(byMessage[NOT_GRANTED].grantable, true)
    assert.equal(byMessage[NOT_GRANTED].short, "Not granted")
    assert.equal(byMessage["The grant for this account has expired; grant it again."].grantable, true)
    assert.equal(byMessage["Granted elsewhere, it says nothing to do here."].grantable, false)
    assert.equal(today(state, new Date("2026-10-30T09:00:00Z")).sentence, "All of your last 3 runs failed. One grant fixes 2 of them.")
  })

  test("only a grant's absence or lapse offers a grant", () => {
    assert.deepEqual(GRANTABLE, ["consent_required", "setup_required"])
    const state = folded(
      failed("a", "catalyst:local.x:1.0.0", "consent_required", "The grant for this account has expired; grant it again."),
      failed("b", "catalyst:local.y:1.0.0", "timeout", "It took too long."),
      run("c", "failed", {reference: "catalyst:local.z:1.0.0"})
    )
    const byMessage = Object.fromEntries(causes(state).map((c) => [c.message, c]))
    assert.equal(byMessage["The grant for this account has expired; grant it again."].grantable, true)
    assert.equal(byMessage["It took too long."].grantable, false)
    assert.equal(byMessage["The run failed without saying why."].short, "Failed")
  })

  test("a Grant asks the shell to grant the component, by its reference without a version", () => {
    const shell = sdk()
    grantComponent(shell.cyfr, causes(day())[0].components[0].ref)
    assert.deepEqual(shell.calls.grant, ["catalyst:local.claude"])
    assert.equal(componentRef("catalyst:local.openai:1.4.1"), "catalyst:local.openai")
    assert.equal(componentRef("catalyst:local.openai"), "catalyst:local.openai")
    assert.equal(componentName("catalyst:local.openai"), "openai")
  })

  test("the day says how many runs failed and how many one grant fixes", () => {
    const now = new Date("2026-10-30T09:00:00Z")
    assert.equal(today(day(), now).sentence, "17 of your last 20 runs failed. Five grants fix 15 of them.")
    const one = folded(
      failed("a", "catalyst:local.openai:1.0.0", "setup_required", NOT_GRANTED),
      failed("b", "catalyst:local.openai:1.0.0", "setup_required", NOT_GRANTED),
      run("c", "completed")
    )
    assert.equal(today(one, now).sentence, "2 of your last 3 runs failed. One grant fixes all of them.")
    assert.equal(today(folded(run("a", "completed"), run("b", "completed")), now).sentence, "None of your last 2 runs failed.")
    assert.equal(today(folded(run("a", "started")), now).sentence, "No runs yet.")
    assert.equal(today(EMPTY, now).sentence, "No runs yet.")
    assert.match(today(EMPTY, now).date, /30/)
  })

  test("short reasons come from the class, and a grant's from its sentence", () => {
    assert.equal(shortReason("setup_required", "This component needs its secrets set."), "Needs setup")
    assert.equal(shortReason("unavailable", "The store did not answer."), "Unavailable")
    assert.equal(shortReason("internal", CAPACITY), "No runner free")
    assert.equal(shortReason("internal", ""), "Failed")
  })
})

describe("the grant a failure offers", () => {
  const FIRST = "This account is not granted to the component; grant it first."

  test("a message that is CYFR's own sentence offers a grant, whatever its class", () => {
    assert.equal(grantable("internal", FIRST), true)
    assert.equal(grantable("internal", "The grant for this account has expired; grant it again."), true)
  })

  test("an internal error quoting the words, or one sentence of CYFR's with more around it, offers no grant and promises no fix", () => {
    for (const message of [
      'The reply did not contain the required words "grant it first".',
      `${FIRST} (while reading the model)`,
      FIRST.toLowerCase()
    ]) {
      const state = fold(
        EMPTY,
        "runs.changes",
        {kind: "failed", execution_id: "r", reference: "catalyst:local.claude:1.4.1", error: {class: "internal", message}},
        1
      )
      assert.equal(causes(state)[0].grantable, false, message)
      assert.notEqual(causes(state)[0].short, "Not granted", message)
      assert.doesNotMatch(today(state, new Date()).sentence, /grant.*fix/, message)
    }
  })
})

describe("recent runs", () => {
  const folded = (...items) => items.reduce((state, item) => fold(state, "runs.changes", item, 1), EMPTY)

  test("a strip of each held run, newest first, by its outcome", () => {
    const state = folded(run("a", "completed"), run("b", "failed"), run("c", "cancelled"), run("d", "started"))
    assert.deepEqual(strip(state), ["run", "warn", "bad", "ok"])
  })

  test("rows with a name, a short reason and a duration, then how many more", () => {
    const items = Array.from({length: 12}, (_, i) =>
      run(`r${i}`, i % 2 ? "failed" : "completed", {
        duration_ms: 1500,
        error: i % 2 ? {class: "timeout", message: "It took too long."} : null
      })
    )
    const {rows, more} = recentRows(folded(...items), 8)
    assert.equal(rows.length, 8)
    assert.equal(more, 4)
    assert.deepEqual(rows[0], {
      id: "r11",
      status: "bad",
      name: "r11",
      detail: "catalyst · 1.0.0",
      reason: "Timed out",
      duration: "1.5 s"
    })
    assert.equal(rows[1].reason, "Finished")
  })
})

describe("schedules", () => {
  const now = new Date("2026-10-30T09:00:00Z")
  const schedule = (id, extra) => ({kind: "changed", schedule_id: id, name: `Schedule ${id}`, ...extra})
  const held = (...items) => items.reduce((state, item) => fold(state, "schedules.changes", item, 1), EMPTY)

  test("each row says when it runs next and last, and its runs and errors", () => {
    const state = held(
      schedule("s1", {next_run_at: "2026-10-30T09:30:00Z", last_run_at: "2026-10-29T09:00:00Z", run_count: 12, error_count: 1}),
      schedule("s2", {status: "paused", next_run_at: null, last_run_at: null})
    )
    const [first, second] = scheduleRows(state, now)
    assert.equal(first.next, relative("2026-10-30T09:30:00Z", now, ""))
    assert.match(first.next, /30 minutes/)
    assert.match(first.last, /yesterday|1 day|24 hours/)
    assert.equal(first.runs, "12")
    assert.equal(first.errors, "1")
    assert.equal(first.lastOutcome, null)
    assert.equal(second.next, "paused")
    assert.equal(second.last, "never")
  })

  test("the week ahead shows each live schedule's next run on its day, by name, and reads no cron", () => {
    const state = held(
      schedule("daily", {cron_expression: "0 7 * * *", next_run_at: "2026-10-31T07:00:00Z"}),
      schedule("odd", {cron_expression: "not cron", next_run_at: "2026-11-01T12:00:00Z"}),
      schedule("every-minute", {cron_expression: "* * * * *", next_run_at: "2026-10-30T09:01:00Z"}),
      schedule("later", {cron_expression: "0 0 1 1 *", next_run_at: "2027-01-01T00:00:00Z"}),
      schedule("unplanned", {cron_expression: "0 7 * * *"}),
      schedule("paused", {status: "paused", cron_expression: "* * * * *", next_run_at: "2026-10-30T09:01:00Z"})
    )
    const days = week(state, now)
    assert.equal(days.length, 7)
    assert.equal(days[0].today, true)
    // The next run alone, on its day: a schedule that fires every minute
    // shows once, today; the daily one on the day of its next run only.
    assert.deepEqual(
      days.map((d) => d.next),
      [["Schedule every-minute"], ["Schedule daily"], ["Schedule odd"], [], [], [], []]
    )
  })

  test("relative times read in words, and no time reads as the given word", () => {
    assert.equal(relative(null, now, "never"), "never")
    assert.equal(relative("garbage", now, "never"), "never")
    assert.equal(relative("2026-10-30T08:59:50Z", now, ""), "just now")
    assert.match(relative("2026-10-30T06:00:00Z", now, ""), /3 hours ago/)
  })
})

describe("the desk's layout", () => {
  const columns = [{x: 32, width: 600}, {x: 654, width: 480}]

  test("Needs attention stays in its own column while no window covers it there", () => {
    assert.equal(attentionColumn(columns, [], 80, 200), 0)
    // A window over the other column, or below it, leaves it.
    assert.equal(attentionColumn(columns, [{x: 700, y: 60, width: 300, height: 400}], 80, 200), 0)
    assert.equal(attentionColumn(columns, [{x: 40, y: 400, width: 300, height: 200}], 80, 200), 0)
  })

  test("moves to the first column no window covers, and else to the least covered", () => {
    assert.equal(attentionColumn(columns, [{x: 100, y: 50, width: 300, height: 300}], 80, 200), 1)
    assert.equal(
      attentionColumn(columns, [{x: 0, y: 0, width: 640, height: 900}, {x: 900, y: 100, width: 100, height: 50}], 80, 200),
      1
    )
    assert.equal(
      attentionColumn(columns, [{x: 0, y: 0, width: 100, height: 900}, {x: 650, y: 0, width: 500, height: 900}], 80, 200),
      0
    )
    assert.equal(attentionColumn([], [], 0, 0), 0)
  })
})

describe("every value is drawn as text", () => {
  test("a string as itself, a finite number as its digits, anything else as nothing", () => {
    assert.equal(text("a"), "a")
    assert.equal(text(42), "42")
    for (const value of [null, undefined, {a: 1}, ["x"], NaN, Infinity, true]) assert.equal(text(value), "")
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
