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
import {CREDENTIAL, HANDSHAKE, toFrameMessage} from "../../js/sdk/wire.js"
import {eventually, fixture, stubSockets} from "../sdk/support.mjs"

import {
  EMPTY,
  GRANTABLE,
  GRANT_CAUSES,
  MAX_RUNS,
  MAX_SCHEDULE_RUNS,
  MONOGRAM_HUES,
  PAUSE,
  RESUME,
  RETRY_MS,
  STREAMS,
  WIDGETS,
  attentionColumn,
  byNextFire,
  causes,
  componentName,
  componentRef,
  covered,
  desktop,
  fold,
  grantable,
  grantComponent,
  hidden,
  installed,
  isShown,
  monogram,
  openApp,
  postured,
  pressSchedule,
  recentRows,
  relative,
  scheduleRows,
  shortReason,
  showWidget,
  start,
  strip,
  text,
  today,
  week
} from "../../../../../seed/components/tinctures/local/canvas/0.5.0/src/model.ts"

const VERSION = new URL("../../../../../seed/components/tinctures/local/canvas/0.5.0/", import.meta.url)
const SCAFFOLD = new URL("../../../lib/compendium/scaffold.ex", import.meta.url)

// Every pending reaction runs: a promise's handlers, then theirs.
const settle = () => new Promise((resolve) => setImmediate(resolve))

// window.cyfr as the canvas uses it. Each stream open waits for the test
// to open it (`accept`) or refuse it (`refuse`), and an open stream ends
// when the test ends it (`end`). A press or a write of the preferences is
// answered with the next of `answers`' for it.
function sdk() {
  const opens = []
  const calls = {ready: 0, open: [], grant: [], press: [], prefs: [], installed: null, covered: null, posture: null, desktop: null}
  const answers = {press: [], prefs: []}
  const cyfr = {
    desktop: null,
    on(event, handler) {
      assert.ok(["installed", "covered", "posture", "desktop"].includes(event), event)
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
    press(control, value) {
      calls.press.push([control, value])
      return Promise.resolve(answers.press.shift())
    },
    prefs(document) {
      calls.prefs.push(document)
      return Promise.resolve(answers.prefs.shift())
    },
    ready() {
      calls.ready += 1
    }
  }
  const latest = (name) => opens.filter((open) => open.name === name).at(-1)
  return {cyfr, opens, calls, answers, latest}
}

function started() {
  const shell = sdk()
  const states = []
  const stop = start(shell.cyfr, (state) => states.push(state))
  return {...shell, stop, state: () => states.at(-1) ?? EMPTY}
}

// What the SDK rejects a stream open with for `answer`, one of
// tests/fixtures/tincture_wire.json's stream_rejections: its own
// rejection, as the page meets it. No answer is a connection that closes
// before it opens.
async function rejection(answer) {
  const win = {location: {pathname: "/"}, parent: {}}
  const endpoint = stubSockets({answer: () => [answer], opens: answer !== null})
  const {api, onWindowMessage} = createClient({win, socketFn: endpoint.socketFn, base: "https://cyfr.test/"})
  const channel = new MessageChannel()
  onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: "frm_shipped_canvas"}, ports: [channel.port2]})
  channel.port1.postMessage({v: 1, type: CREDENTIAL, frame: "frm_shipped_canvas", credential: "frm.v2.shipped"})
  try {
    const opened = api.stream("runs.changes", null, () => {})
    if (answer === null) {
      await eventually(() => endpoint.sockets.length === 1)
      endpoint.sockets[0].drop()
    }
    await opened
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
    for (const event of ["installed", "covered", "posture", "desktop"]) {
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
      run("b", "failed", {refresh: true, error: {class: "internal", cause: "failed"}}),
      run("c", "started", {refresh: true}),
      run("c", "completed"),
      run("d", "started")
    )
    assert.deepEqual(state.runs.map((r) => [r.execution_id, r.kind]), [["d", "started"], ["c", "completed"], ["b", "failed"], ["a", "completed"]])
  })

  test("folds the wire's run events, a running run and an ended one, whole", () => {
    const events = fixture.stream_events["runs.changes"].map(({event}) => event)
    assert.equal(events.length, 2)
    const state = folded(...events)
    assert.deepEqual(state.runs, [...events].reverse())
    assert.equal(state.runs.find((r) => r.kind === "started").ended_at, null)
    assert.ok(state.runs.every((r) => typeof r.started_at === "string"))
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
    state = fold(state, "schedule_runs.changes", fired("o12", {kind: "failed", reason: {class: "timeout", cause: "timed_out"}}), 1)
    assert.equal(state.scheduleRuns.length, MAX_SCHEDULE_RUNS)
    assert.deepEqual(state.scheduleRuns.slice(0, 2).map((r) => [r.occurrence_id, r.kind]), [["o12", "failed"], ["o11", "fired"]])
    assert.equal(state.scheduleRuns.at(-1).occurrence_id, "o3")
    // A schedule's row carries the outcome of its last run heard of.
    assert.equal(scheduleRows(state, new Date("2026-10-27T09:00:00Z"))[0].lastOutcome, "bad")
  })
})

describe("what needs attention", () => {
  const failed = (id, reference, cls, cause) => run(id, "failed", {reference, error: {class: cls, cause}})
  const folded = (...items) => items.reduce((state, item) => fold(state, "runs.changes", item, 1), EMPTY)

  // 17 of 20 failed: 15 for want of a grant across five catalysts, two for
  // want of something unavailable; three finished.
  const day = () => {
    const items = []
    const names = ["openai", "openrouter", "gemini", "grok", "claude"]
    for (let i = 0; i < 15; i++) {
      items.push(failed(`g${i}`, `catalyst:local.${names[i % 5]}:1.4.1`, "setup_required", "needs_setup"))
    }
    items.push(failed("c1", "catalyst:local.gemini:1.4.1", "unavailable", "unavailable"))
    items.push(failed("c2", "catalyst:local.openrouter:1.4.1", "unavailable", "unavailable"))
    for (let i = 0; i < 3; i++) items.push(run(`ok${i}`, "completed", {reference: "catalyst:local.claude:1.4.1", duration_ms: 289}))
    return folded(...items)
  }

  test("groups failures by class and cause, each stated once with the components it hit and their counts", () => {
    const [grant, unavailable, ...rest] = causes(day())
    assert.deepEqual(rest, [])
    assert.equal(grant.count, 15)
    assert.equal(grant.class, "setup_required")
    assert.equal(grant.cause, "needs_setup")
    assert.equal(grant.shown, "setup_required")
    assert.equal(grant.grantable, true)
    assert.equal(grant.short, "Needs setup")
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
    assert.equal(unavailable.count, 2)
    assert.equal(unavailable.grantable, false)
    assert.equal(unavailable.short, "Unavailable")
    assert.deepEqual(unavailable.components.map((c) => [c.name, c.count]), [["gemini", 1], ["openrouter", 1]])
  })

  test("two classes one cause reads as are two causes, and a failure without an error is its own", () => {
    const state = folded(
      failed("a", "catalyst:local.x:1.0.0", "forbidden", "refused"),
      failed("b", "catalyst:local.x:1.0.0", "not_owner", "refused"),
      failed("c", "catalyst:local.x:1.0.0", "not_owner", "refused"),
      failed("d", "catalyst:local.y:1.0.0", "internal", "failed"),
      run("e", "failed", {reference: "catalyst:local.z:1.0.0"})
    )
    assert.deepEqual(
      causes(state).map((c) => [c.shown, c.cause, c.short, c.count]),
      [
        ["not_owner", "refused", "Refused", 2],
        ["forbidden", "refused", "Refused", 1],
        ["internal", "", "Failed", 1],
        ["internal", "failed", "Failed", 1]
      ]
    )
  })

  test("what the page shows of a cause is its class and the canvas's few words for it, never a sentence", () => {
    const page = readFileSync(new URL("src/App.tsx", VERSION), "utf8")
    assert.match(page, /\{cause\.shown\}/)
    assert.match(page, /cause\.short/)
    assert.doesNotMatch(page, /message/)
    const model = readFileSync(new URL("src/model.ts", VERSION), "utf8")
    assert.doesNotMatch(model, /text\(error\??\.message\)/)
  })

  test("a grant is offered by a grant's class, or by the cause a missing or lapsed grant reads as", () => {
    assert.deepEqual(GRANTABLE, ["consent_required", "setup_required"])
    assert.deepEqual(GRANT_CAUSES, ["needs_setup"])
    assert.equal(grantable("consent_required", ""), true)
    assert.equal(grantable("internal", "needs_setup"), true)
    for (const [cls, cause] of [["timeout", "timed_out"], ["internal", "failed"], ["unavailable", "unavailable"], ["forbidden", "refused"], ["internal", ""]]) {
      assert.equal(grantable(cls, cause), false, `${cls} ${cause}`)
    }
    const state = folded(
      failed("a", "catalyst:local.x:1.0.0", "consent_required", "needs_setup"),
      failed("b", "catalyst:local.y:1.0.0", "timeout", "timed_out"),
      run("c", "failed", {reference: "catalyst:local.z:1.0.0"})
    )
    const byClass = Object.fromEntries(causes(state).map((c) => [c.class + c.cause, c]))
    assert.equal(byClass.consent_requiredneeds_setup.grantable, true)
    assert.equal(byClass.timeouttimed_out.grantable, false)
    assert.equal(byClass.internal.grantable, false)
    assert.equal(today(state, new Date("2026-10-30T09:00:00Z")).sentence, "All of your last 3 runs failed. One grant fixes 1 of them.")
  })

  test("a failure no grant fixes offers none and promises no fix", () => {
    const state = folded(failed("a", "catalyst:local.claude:1.4.1", "internal", "failed"))
    assert.equal(causes(state)[0].grantable, false)
    assert.doesNotMatch(today(state, new Date()).sentence, /grant/)
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
      failed("a", "catalyst:local.openai:1.0.0", "setup_required", "needs_setup"),
      failed("b", "catalyst:local.openai:1.0.0", "setup_required", "needs_setup"),
      run("c", "completed")
    )
    assert.equal(today(one, now).sentence, "2 of your last 3 runs failed. One grant fixes all of them.")
    assert.equal(today(folded(run("a", "completed"), run("b", "completed")), now).sentence, "None of your last 2 runs failed.")
    assert.equal(today(folded(run("a", "started")), now).sentence, "No runs yet.")
    assert.equal(today(EMPTY, now).sentence, "No runs yet.")
    assert.match(today(EMPTY, now).date, /30/)
  })

  test("short reasons come from the cause, and a cause the canvas has no words for reads as failed", () => {
    assert.equal(shortReason("needs_setup"), "Needs setup")
    assert.equal(shortReason("timed_out"), "Timed out")
    assert.equal(shortReason("waits_for_you"), "Waits for you")
    for (const cause of ["failed", "uncertain", "", "constructor", "a cause from a later server"]) {
      assert.equal(shortReason(cause), "Failed", cause)
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
        error: i % 2 ? {class: "timeout", cause: "timed_out"} : null
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
      schedule("s1", {status: "active", next_run_at: "2026-10-30T09:30:00Z", last_run_at: "2026-10-29T09:00:00Z", run_count: 12, error_count: 1}),
      schedule("s2", {status: "paused", next_run_at: null, last_run_at: null}),
      schedule("s3", {status: "needs_consent", next_run_at: null, last_run_at: null})
    )
    const [first, second, third] = scheduleRows(state, now)
    // Pause while it is active, Resume while it is paused, and neither in
    // any other status.
    assert.deepEqual([first.control, second.control, third.control], [PAUSE, RESUME, null])
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

describe("a schedule's Pause and Resume", () => {
  const now = new Date("2026-10-30T09:00:00Z")
  const rows = () =>
    scheduleRows(
      [
        {kind: "changed", schedule_id: "sch_1", name: "Morning", status: "active"},
        {kind: "changed", schedule_id: "sch_2", name: "Evening", status: "paused"},
        {kind: "changed", schedule_id: "sch_3", name: "Waiting", status: "needs_consent"}
      ].reduce((state, item) => fold(state, "schedules.changes", item, 1), EMPTY),
      now
    )

  test("presses the declared control with the schedule's id as its pick, and says nothing of an accepted press", async () => {
    const shell = sdk()
    const [active, paused, waiting] = rows()
    shell.answers.press.push({outcome: "accepted"}, {outcome: "cancelled"})
    assert.equal(await pressSchedule(shell.cyfr, active), null)
    assert.equal(await pressSchedule(shell.cyfr, paused), null)
    assert.equal(await pressSchedule(shell.cyfr, waiting), null)
    assert.deepEqual(shell.calls.press, [
      [PAUSE, "sch_1"],
      [RESUME, "sch_2"]
    ])
  })

  test("a refused press answers its reason, to show for a moment", async () => {
    const shell = sdk()
    const [active] = rows()
    shell.answers.press.push({outcome: "refused", reason: "not_found"}, {outcome: "refused"})
    assert.equal(await pressSchedule(shell.cyfr, active), "not_found")
    assert.equal(await pressSchedule(shell.cyfr, active), "refused")
    const page = readFileSync(new URL("src/App.tsx", VERSION), "utf8")
    assert.match(page, /Refused · \{refused\}/)
  })

  test("the manifest declares both controls, each picking a schedule's id from schedules.changes", () => {
    const {desktop: block} = JSON.parse(readFileSync(new URL("cyfr-manifest.json", VERSION), "utf8")).tincture
    const pick = {stream: "schedules.changes", field: "/schedule_id", arg: "schedule_id"}
    assert.deepEqual(block.controls, [
      {id: PAUSE, label: "Pause", operation: "schedule.pause", pick},
      {id: RESUME, label: "Resume", operation: "schedule.resume", pick}
    ])
    assert.deepEqual(block.data, STREAMS)
  })
})

describe("the sections the person hides", () => {
  const prefs = (widgets, revision = 1) => ({prefs: {document: {widgets, desktop: {}}, revision}})

  test("are the document's widgets whose entry says on: false, from the open and each desktop event", async () => {
    const shell = sdk()
    shell.cyfr.desktop = prefs({apps: {on: false}, runs: {on: true}})
    const states = []
    const stop = start(shell.cyfr, (state) => states.push(state))
    shell.calls.installed([])
    assert.deepEqual(hidden(states.at(-1)), ["apps"])

    shell.calls.desktop(prefs({attention: {on: false}, schedules: {on: false, rect: {x: 0, y: 0, w: 10, h: 10}}}, 2))
    assert.deepEqual(hidden(states.at(-1)), ["attention", "schedules"])
    // What reads as no document leaves the one held.
    for (const value of [null, {prefs: null}, {prefs: {document: "x", revision: 3}}]) shell.calls.desktop(value)
    assert.deepEqual(hidden(states.at(-1)), ["attention", "schedules"])
    stop()

    assert.deepEqual(hidden(EMPTY), [])
    assert.equal(isShown({widgets: {runs: {on: "false"}}}, "runs"), true)
    assert.equal(isShown(null, "runs"), true)
    assert.deepEqual(hidden(desktop(EMPTY, prefs({runs: {on: false}}))), ["runs"])
  })

  test("a hide or a show writes that widget's on alone", async () => {
    const shell = sdk()
    shell.answers.prefs.push({outcome: "saved", document: {widgets: {runs: {on: false}}, desktop: {}}, revision: 2})
    assert.equal((await showWidget(shell.cyfr, "runs", false)).outcome, "saved")
    shell.answers.prefs.push({outcome: "refused", reason: "invalid_argument", document: {widgets: {}, desktop: {}}, revision: 2})
    assert.equal((await showWidget(shell.cyfr, "runs", true)).outcome, "refused")
    shell.answers.prefs.push({outcome: "cancelled"})
    assert.equal((await showWidget(shell.cyfr, "apps", false)).outcome, "cancelled")
    assert.deepEqual(shell.calls.prefs, [
      {widgets: {runs: {on: false}}},
      {widgets: {runs: {on: true}}},
      {widgets: {apps: {on: false}}}
    ])
  })

  test("a stale write is not written again: one tap, one write, its answer the document now held", async () => {
    const shell = sdk()
    const current = {widgets: {apps: {on: false}}, desktop: {}}
    shell.answers.prefs.push({outcome: "stale", document: current, revision: 7})
    const answer = await showWidget(shell.cyfr, "runs", false)
    assert.deepEqual(answer, {outcome: "stale", document: current, revision: 7})
    assert.deepEqual(shell.calls.prefs, [{widgets: {runs: {on: false}}}])
  })

  test("the manifest declares a widget for each section, with no fields of its own", () => {
    const {desktop: block} = JSON.parse(readFileSync(new URL("cyfr-manifest.json", VERSION), "utf8")).tincture
    assert.deepEqual(block.prefs, {widgets: Object.fromEntries(WIDGETS.map((widget) => [widget, {}]))})
    assert.equal(block.chrome, "chrome.css")
  })
})

describe("nothing is pressed or written but by the page's own handlers", () => {
  test("no stream event, no word of the shell and no reopen presses a control or writes the preferences", async (t) => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    const page = started()
    await settle()
    for (const open of page.opens) open.accept()
    page.latest("schedules.changes").send({kind: "changed", schedule_id: "sch_1", name: "Morning", status: "active", refresh: true})
    page.latest("schedules.changes").send({kind: "changed", schedule_id: "sch_2", name: "Evening", status: "paused"})
    page.latest("runs.changes").send(run("a", "failed", {error: {class: "setup_required", cause: "needs_setup"}}))
    page.latest("schedule_runs.changes").send({kind: "failed", schedule_id: "sch_1", occurrence_id: "o1", reason: {class: "timeout", cause: "timed_out"}})
    page.calls.installed([{ref: "tincture:local.notes", name: "Notes", icon: null, open: false}])
    page.calls.covered([{x: 0, y: 0, width: 10, height: 10}])
    page.calls.posture("hand")
    page.calls.desktop({prefs: {document: {widgets: {runs: {on: false}}, desktop: {}}, revision: 4}})
    page.latest("schedules.changes").end()
    await settle()
    t.mock.timers.tick(RETRY_MS[0])
    await settle()
    page.latest("schedules.changes").accept()
    await settle()
    assert.deepEqual(hidden(page.state()), ["runs"])
    assert.deepEqual([page.calls.press, page.calls.prefs, page.calls.open, page.calls.grant], [[], [], [], []])
    page.stop()
  })

  test("the page presses and writes only from a tap's handler, and the model only in the two calls a handler makes", () => {
    const app = readFileSync(new URL("src/App.tsx", VERSION), "utf8")
    const taps = [...app.matchAll(/(pressSchedule|showWidget)\(cyfr/g)]
    assert.equal(taps.length, 3)
    for (const tap of taps) assert.match(app.slice(0, tap.index), /onClick=\{\(\) => $/)
    assert.doesNotMatch(app, /cyfr\.(press|prefs)\(/)

    const model = readFileSync(new URL("src/model.ts", VERSION), "utf8")
    const outside = model
      .replace(/^export async function pressSchedule\([\s\S]*?^\}$/m, "")
      .replace(/^export async function showWidget\([\s\S]*?^\}$/m, "")
    assert.notEqual(outside, model)
    assert.doesNotMatch(outside, /\.(press|prefs)\(/)
  })
})

describe("on the SDK itself", () => {
  // A canvas page's SDK, opened as the shell opens one: the fixture's
  // canvas block, whose document hides apps, and `heard`, every message
  // the page posts the shell. Its streams wait to be shown, so no
  // connection opens.
  async function opened() {
    const [{frame, reply}] = fixture.canvas.handshake.valid
    const win = {location: {pathname: "/"}, parent: {}}
    const socketFn = () => assert.fail("the canvas connected before it was shown")
    const {api, onWindowMessage} = createClient({win, socketFn, base: "https://cyfr.test/"})
    const channel = new MessageChannel()
    const heard = []
    channel.port1.onmessage = (event) => heard.push(event.data)
    onWindowMessage({source: win.parent, data: {v: 1, type: HANDSHAKE, frame}, ports: [channel.port2]})
    channel.port1.postMessage(toFrameMessage("canvas", frame, reply.canvas))
    channel.port1.postMessage({v: 1, type: CREDENTIAL, frame, credential: reply.credential})
    await eventually(() => api.desktop !== null)
    const tell = (verb, args) => channel.port1.postMessage(toFrameMessage(verb, frame, args))
    return {api, heard, tell, frame, close: () => channel.port1.close()}
  }

  const verbs = (heard, verb) => heard.filter((message) => message.verb === verb).map((message) => message.args)

  test("the open's document hides its sections, and a stale write's answer is the document the page then shows", async () => {
    const shell = await opened()
    try {
      const states = []
      const stop = start(shell.api, (state) => states.push(state))
      await eventually(() => states.length > 0)
      assert.deepEqual(hidden(states.at(-1)), ["apps"])

      const write = showWidget(shell.api, "runs", false)
      await eventually(() => verbs(shell.heard, "prefs").length === 1)
      const current = {widgets: {apps: {on: false}, schedules: {on: false}}, desktop: {}}
      shell.tell("prefs", {call: 1, outcome: "stale", document: current, revision: 7})
      assert.deepEqual(await write, {outcome: "stale", document: current, revision: 7})
      await eventually(() => hidden(states.at(-1)).length === 2)
      assert.deepEqual(hidden(states.at(-1)), ["apps", "schedules"])
      await new Promise((resolve) => setTimeout(resolve, 20))
      assert.deepEqual(verbs(shell.heard, "prefs"), [{document: {widgets: {runs: {on: false}}}, call: 1}])

      // The person's next tap writes over it.
      const again = showWidget(shell.api, "runs", false)
      await eventually(() => verbs(shell.heard, "prefs").length === 2)
      const saved = {widgets: {apps: {on: false}, schedules: {on: false}, runs: {on: false}}, desktop: {}}
      shell.tell("prefs", {call: 2, outcome: "saved", document: saved, revision: 8})
      assert.deepEqual(await again, {outcome: "saved", document: saved, revision: 8})
      await eventually(() => hidden(states.at(-1)).length === 3)
      stop()
    } finally {
      shell.close()
    }
  })

  test("a press goes as the control and the picked id, and a refusal answers its reason", async () => {
    const shell = await opened()
    try {
      const row = scheduleRows(fold(EMPTY, "schedules.changes", {kind: "changed", schedule_id: "sch_1", name: "Morning", status: "active"}, 1), new Date())[0]
      const pressed = pressSchedule(shell.api, row)
      await eventually(() => verbs(shell.heard, "press").length === 1)
      assert.deepEqual(verbs(shell.heard, "press"), [{control: PAUSE, value: "sch_1", call: 1}])
      shell.tell("pressed", {control: PAUSE, call: 1, outcome: "refused", reason: "not_found"})
      assert.equal(await pressed, "not_found")
    } finally {
      shell.close()
    }
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
