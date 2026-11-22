// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A bound a proof against a real CYFR holds is measured from its cause
// (tests/desktop-proof/bound.mjs): the rows' own steps, run on a clock of
// the test's own.

import assert from "node:assert/strict"
import {test} from "node:test"

import {fromCause, processLoss} from "../../../../tests/desktop-proof/bound.mjs"

const MINUTE = 60_000

// A clock that stands until everything waits on it, and then moves to the
// first of their times.
function testClock() {
  let now = 1_000_000
  const due = []
  return {
    now: () => now,
    sleep: (ms) => new Promise((wake) => due.push({at: now + ms, wake})),
    async run(work) {
      let done = false
      work.then(() => { done = true }, () => { done = true })
      for (;;) {
        await new Promise((resolve) => setImmediate(resolve))
        if (done) return work
        assert.ok(due.length, "the work waits on nothing")
        due.sort((a, b) => a.at - b.at)
        const next = due.shift()
        now = Math.max(now, next.at)
        next.wake()
      }
    }
  }
}

test("process_loss counts from the kill to the first refusal seen, and takes a minute or less", async () => {
  for (const [name, {windowAt = 0, killing = 0, looking = 0, refusedAt}, within] of [
    ["refused at once", {refusedAt: 0}, true],
    ["refused at the minute, the window at 8 s", {windowAt: 8000, refusedAt: MINUTE}, true],
    ["the window at 8 s and the refusal at 64 s", {windowAt: 8000, refusedAt: 64_000}, false],
    ["refused just past the minute", {refusedAt: MINUTE + 1}, false],
    ["a kill that itself takes time", {killing: 8000, refusedAt: 64_000}, false],
    ["a refusal seen past it by a look begun before it", {looking: 5000, refusedAt: 61_000}, false],
    ["never refused", {refusedAt: Infinity}, false]]) {
    const clock = testClock()
    let killed = null
    const got = await clock.run(processLoss({
      kill: async () => {
        killed = clock.now()
        if (killing) await clock.sleep(killing)
      },
      message: async () => {
        await clock.sleep(windowAt)
        return "CYFR stopped"
      },
      refusal: async () => {
        if (looking) await clock.sleep(looking)
        if (clock.now() - killed < refusedAt) throw new Error("still opens")
        return "refused"
      }
    }, MINUTE, clock))
    assert.equal(got.message, "CYFR stopped", name)
    assert.equal(got.ended.within, within, `${name}: ${JSON.stringify(got.ended)}`)
    if (within) assert.equal(got.ended.seen, "refused", name)
    if (!got.ended.seen) assert.equal(got.ended.last, "still opens", `${name}: why nothing was seen`)
  }
})

test("a bound counts from before its cause, however long that takes", async () => {
  const clock = testClock()
  const got = await clock.run(fromCause(() => clock.sleep(61_000), () => "refused", MINUTE, clock))
  assert.deepEqual(got, {seen: "refused", took: 61_000, within: false})
})
