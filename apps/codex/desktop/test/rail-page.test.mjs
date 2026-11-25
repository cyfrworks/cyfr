// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {test} from "node:test"
import vm from "node:vm"

// The rail's own script (internal/desktop/assets/rail.js), run against
// stand-ins for its page: the elements it reads by id, and its list's
// reads, each answer in turn, then the cyfr that served it gone (503).
const script = readFileSync(new URL("../../internal/desktop/assets/rail.js", import.meta.url), "utf8")

function element() {
  return {hidden: false, textContent: "", className: "", style: {setProperty() {}}, setAttribute() {}, append() {},
    addEventListener() {}, replaceChildren() {}, parentElement: {hidden: false}}
}

async function railShowing(answers) {
  const ids = {cyfrs: element(), said: element(), setup: element(), update: element()}
  const left = [...answers]
  const read = async () => {
    const answer = left.shift()
    return answer ? {status: 200, ok: true, text: async () => JSON.stringify(answer)} : {status: 503, ok: false}
  }
  let ended
  const done = new Promise((resolve) => { ended = resolve })
  const fetch = async (...args) => {
    const r = await read(...args)
    if (r.status === 503) ended()
    return r
  }
  vm.runInNewContext(script, {
    location: {hash: "#read=r", assign() {}}, history: {replaceState() {}},
    sessionStorage: {setItem() {}, getItem: () => "r"}, URL, URLSearchParams, JSON, String, Promise, setTimeout, clearTimeout, fetch,
    document: {getElementById: (id) => ids[id], createElement: () => element()}
  })
  await done
  return {setup: ids.setup.parentElement.hidden, update: ids.update.parentElement.hidden}
}

const BOX = {cyfr: "http://127.0.0.1:7340", box: true, folder: "/home/ana/cyfr"}

// On a box's screen the rail offers no Set up, and Update only while the
// box is unlocked: nothing of Update CYFR shows on a locked box. On a
// desktop both show.
test("the rail's foot offers Update on a box only while it is unlocked, and Set up never", async () => {
  assert.deepEqual(await railShowing([{cyfrs: [BOX], locked: true, seq: 1}]), {setup: true, update: true}, "a locked box")
  assert.deepEqual(await railShowing([{cyfrs: [BOX], locked: true, seq: 1}, {cyfrs: [BOX], seq: 2}]), {setup: true, update: false},
    "the box unlocked")
  assert.deepEqual(await railShowing([{cyfrs: [BOX], seq: 1}, {cyfrs: [BOX], locked: true, seq: 2}]), {setup: true, update: true},
    "the box locked again")
  assert.deepEqual(await railShowing([{cyfrs: [], seq: 1}]), {setup: false, update: false}, "a desktop")
})
