// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {afterEach, describe, test} from "node:test"

import {parseTree} from "../../js/toolkit/tree.js"
import {ROLES, answer, decodeRequest, pairKey} from "../../js/toolkit/wire.js"
import {startModuleWorker} from "../../js/toolkit/worker.js"
import {ASSET, eventually, pause, workerScope} from "../toolkit/support.mjs"

// The shipped canvas, run through the toolkit's module API as the module
// worker runs any canvas's module: the test plays the host on the worker's
// own channel and the streams worker on the port between the two.
const seed = new URL("../../../../../seed/components/tinctures/local/canvas/0.1.0/", import.meta.url)
const manifest = JSON.parse(readFileSync(new URL("cyfr-manifest.json", seed), "utf8"))
const declared = new Set(
  manifest.tincture.streams.map(({name, subject}) => pairKey({name, subject: subject === undefined ? null : subject}))
)

const INSTALLED = [
  {ref: "tincture:local.vault", name: "vault"},
  {ref: "tincture:local.flappy-bird", name: "flappy-bird"},
  {ref: "tincture:example.com.notes", name: "Notes"}
]

// A change of `runs.changes`, in the shape `Crucible.Providers.Feed`
// declares for it: every field required, the nullable ones null where a
// run has none.
const change = (executionId, kind, fields = {}) => ({
  kind,
  execution_id: executionId,
  parent_execution_id: null,
  reference: "catalyst:local.claude:0.2.0",
  component_type: "catalyst",
  duration_ms: kind === "started" ? null : 120,
  error: null,
  ...fields
})

const event = (data) => ({id: null, event: "runs.changes", data})

const cleanups = []
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup()
})

function run() {
  const module = workerScope(ROLES.module)
  startModuleWorker(module, {importModule: () => import(new URL("canvas.js", seed).href)})

  const channel = new MessageChannel()
  cleanups.push(() => channel.port1.close())
  const requests = []
  channel.port1.onmessage = (message) => requests.push(decodeRequest(message.data))

  module.deliver({
    t: "boot",
    mode: "live",
    module_url: `https://cyfr.example/_s/${ASSET}/canvas.js`,
    port: channel.port2
  })

  const trees = () => module.posted.filter((m) => m.t === "tree").map((m) => parseTree(m.json))
  return {module, port: channel.port1, requests, trees}
}

// Every node of a parsed tree, depth first.
function nodes(tree) {
  const kids = tree.children || tree.items || []
  return [tree, ...kids.flatMap(nodes)]
}

const controls = (tree) => nodes(tree).filter((node) => node.type === "control")

describe("the shipped canvas", () => {
  test("answers a tree the toolkit accepts at once, before anything reaches it", async () => {
    const {module, trees} = run()

    await eventually(() => trees().length > 0)
    const [first] = trees()
    assert.equal(first.ok, true, JSON.stringify(first.error))
    assert.deepEqual(controls(first.tree), [])
    assert.equal(module.posted.some((m) => m.t === "failed"), false)
  })

  test("draws one open control per installed tincture, and no press control", async () => {
    const {module, trees} = run()
    await eventually(() => trees().length > 0)

    module.deliver({t: "installed", value: INSTALLED})
    await eventually(() => controls(trees().at(-1).tree || {}).length === INSTALLED.length)

    const last = trees().at(-1)
    assert.equal(last.ok, true, JSON.stringify(last.error))

    const effects = controls(last.tree).map((control) => control.effect)
    assert.deepEqual(
      effects,
      INSTALLED.map(({ref}) => ({open: ref}))
    )
    assert.equal(effects.some((effect) => "press" in effect), false)

    // The posture lays the launchers out, and labels none of them.
    module.deliver({t: "posture", value: "hand"})
    await eventually(() => nodes(trees().at(-1).tree).some((node) => node.type === "grid" && node.columns === 2))
    assert.equal(controls(trees().at(-1).tree).length, INSTALLED.length)
    assert.equal(nodes(trees().at(-1).tree).some((node) => node.type === "text" && node.value === "vault"), false)
  })

  test("reads no stream it does not declare, and draws its runs from the refresh and live changes, each once", async () => {
    const {module, port, requests, trees} = run()

    await eventually(() => requests.length > 0)
    for (const request of requests) {
      assert.equal(request.kind, "open")
      assert.ok(declared.has(pairKey(request)), `reads ${request.name} ${request.subject}`)
    }
    assert.equal(requests.length, 1)
    const [{sub}] = requests

    port.postMessage(answer.opened(sub))
    // The refresh, oldest first, then a live change racing it: the first
    // completion is delivered twice and drawn once.
    port.postMessage(answer.event(sub, event({...change("exec_1", "completed"), refresh: true})))
    port.postMessage(answer.event(sub, event({...change("exec_2", "started"), refresh: true})))
    port.postMessage(answer.event(sub, event(change("exec_1", "completed"))))
    port.postMessage(
      answer.event(
        sub,
        event(change("exec_2", "failed", {error: {class: "invalid_argument", message: "The input was refused."}}))
      )
    )

    await eventually(() => {
      const table = nodes(trees().at(-1).tree || {}).find((node) => node.type === "table")
      return table !== undefined && table.rows[0].status === "failed"
    })
    await pause(20)

    for (const tree of trees()) assert.equal(tree.ok, true, JSON.stringify(tree.error))

    const table = nodes(trees().at(-1).tree).find((node) => node.type === "table")
    assert.deepEqual(table.rows, [
      {
        component: "catalyst:local.claude:0.2.0",
        status: "failed",
        duration: 120,
        error: "The input was refused."
      },
      {component: "catalyst:local.claude:0.2.0", status: "completed", duration: 120, error: null}
    ])

    // Nothing but the one open went to the streams worker, and nothing failed.
    assert.equal(requests.length, 1)
    assert.equal(module.posted.some((m) => m.t === "failed"), false)
  })

  test("a refused stream leaves the launchers drawn", async () => {
    const {module, port, requests, trees} = run()
    await eventually(() => requests.length > 0)

    port.postMessage(answer.refused(requests[0].sub, "forbidden", "Not here.", "admission"))
    module.deliver({t: "installed", value: INSTALLED})

    await eventually(() => controls(trees().at(-1).tree || {}).length === INSTALLED.length)
    await pause(20)
    assert.equal(module.posted.some((m) => m.t === "failed"), false)
    for (const tree of trees()) assert.equal(tree.ok, true)
  })
})
