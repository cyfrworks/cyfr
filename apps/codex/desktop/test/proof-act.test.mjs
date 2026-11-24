// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The proofs' one way to run a script in a page (tests/desktop-proof/act.mjs),
// on a stand-in page whose engine answers as each case says.

import assert from "node:assert/strict"
import {test} from "node:test"

import {js} from "../../../../tests/desktop-proof/act.mjs"

const DISPOSED = new Error("Render frame was disposed before the request completed")
const page = (outcome) => ({executeJavaScript: () => outcome()})
const ends = (error) => page(() => Promise.reject(error))

test("an act takes its page's end as its outcome; a script that asks for an answer, or an act's other error, still rejects", async () => {
  assert.equal(await js(ends(DISPOSED), `document.querySelector("#approve").click(); 1`), undefined)
  assert.equal(await js(ends(DISPOSED), `location.href = "https://x.test/";  1 `), undefined)
  await assert.rejects(js(ends(DISPOSED), `document.title`), DISPOSED)
  await assert.rejects(js(ends(DISPOSED), `location.href = "https://x.test/"; "asked"`), DISPOSED)
  const gone = new Error("WebFrame was removed before script could run. This normally means the underlying frame was destroyed")
  await assert.rejects(js(ends(gone), `document.querySelector("#approve").click(); 1`), gone)
  assert.equal(await js(page(() => Promise.resolve("CYFR")), `document.title`), "CYFR")
})
