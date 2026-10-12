// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {afterEach, describe, test} from "node:test"

import {parseTree} from "../../js/toolkit/tree.js"
import {ROLES, answer, decodeRequest} from "../../js/toolkit/wire.js"
import {startModuleWorker} from "../../js/toolkit/worker.js"
import {ASSET, eventually, pause, workerScope} from "../toolkit/support.mjs"

// The example module the shipped canvas skill teaches AQUA, run through the
// toolkit's module API as the module worker runs a written canvas: a canvas
// AQUA writes from the example behaves as the example does.
const skill = readFileSync(new URL("../../../../../seed/aqua/skills/canvas/SKILL.md", import.meta.url), "utf8")
const [, example] = skill.match(/```js\n([\s\S]*?)```/)
const exampleUrl = "data:text/javascript," + encodeURIComponent(example)

const change = (executionId, kind) => ({
  kind,
  execution_id: executionId,
  parent_execution_id: null,
  reference: `catalyst:local.${executionId}:0.1.0`,
  component_type: "catalyst",
  duration_ms: kind === "started" ? null : 120,
  error: null
})

const event = (data) => ({id: null, event: "runs.changes", data})

const cleanups = []
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup()
})

// The worker's scope, with this process's unhandled rejections delivered to
// it as a browser delivers a worker's, so a rejection the example leaves
// unhandled fails the canvas here as it does in a glass.
function run() {
  const module = workerScope(ROLES.module)
  const onRejection = []
  const addEventListener = module.addEventListener
  module.addEventListener = (type, listener) => {
    if (type === "unhandledrejection") onRejection.push(listener)
    addEventListener(type, listener)
  }
  const forward = () => {
    for (const listener of onRejection) listener({type: "unhandledrejection", isTrusted: true})
  }
  process.on("unhandledRejection", forward)
  cleanups.push(() => process.off("unhandledRejection", forward))

  startModuleWorker(module, {importModule: () => import(exampleUrl)})

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
  const failed = () => module.posted.some((m) => m.t === "failed")
  return {port: channel.port1, requests, trees, failed}
}

const list = (tree) => (tree.children || []).find((node) => node.type === "list")

describe("the canvas skill's example", () => {
  test("a refused stream open leaves the canvas drawn, never failed", async () => {
    const {port, requests, trees, failed} = run()
    await eventually(() => requests.length > 0 && trees().length > 0)

    port.postMessage(answer.refused(requests[0].sub, "forbidden", "Not here.", "admission"))
    await pause(50)

    assert.equal(failed(), false)
    for (const tree of trees()) assert.equal(tree.ok, true, JSON.stringify(tree.error))
  })

  test("draws a change racing the refresh once, and each run as its last change", async () => {
    const {port, requests, trees, failed} = run()
    await eventually(() => requests.length > 0)
    const [{sub}] = requests

    port.postMessage(answer.opened(sub))
    // The refresh, oldest first, then live changes, the first racing it.
    port.postMessage(answer.event(sub, event({...change("one", "completed"), refresh: true})))
    port.postMessage(answer.event(sub, event({...change("two", "started"), refresh: true})))
    port.postMessage(answer.event(sub, event(change("one", "completed"))))
    port.postMessage(answer.event(sub, event(change("two", "completed"))))

    // The last tree drawn shows each run once, newest first.
    const drawn = () => (list(trees().at(-1)?.tree || {})?.items || []).map((item) => item.value)
    const expected = ["catalyst:local.two:0.1.0 completed", "catalyst:local.one:0.1.0 completed"]
    await eventually(() => JSON.stringify(drawn()) === JSON.stringify(expected)).catch(() => {})

    assert.deepEqual(drawn(), expected)
    for (const tree of trees()) assert.equal(tree.ok, true, JSON.stringify(tree.error))
    assert.equal(failed(), false)
  })
})
