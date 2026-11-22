// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// What a proof against a real CYFR writes holds no credential, wherever in
// an address it sits (tests/desktop-proof/scrub.mjs, the one scrub).

import assert from "node:assert/strict"
import {execFileSync} from "node:child_process"
import {test} from "node:test"
import {fileURLToPath} from "node:url"

import {scrub, scrubbed} from "../../../../tests/desktop-proof/scrub.mjs"

const SECRET = "SFMyNTY.g2gDbQAAAB-c2VjcmV0_dGlja2V0.Zm9yZ2Vk"
const HOME = "https://x.test"
const CARRIERS = {
  "a sign-in's ticket": `${HOME}/auth/passkey/complete/${SECRET}`,
  "a ticket's path alone, as a front records it": `GET /auth/passkey/complete/${SECRET} 302`,
  "a canvas's page": `${HOME}/_c/v1/${SECRET}/frm_1`,
  "a canvas's address cut short": `${HOME}/_c/v1/${SECRET}`,
  "a served file": `${HOME}/_s/${SECRET}/alice/board/1.0.0/index.html`,
  "a fragment": `${HOME}/login#${SECRET}`,
  "a fragment with closing marks in it": `${HOME}/login#(${SECRET})]`,
  "a query": `wss://x.test/live/websocket?_csrf_token=${SECRET}&vsn=2.0.0`,
  "a path's own query": `POST /confirm?ref=${SECRET}`,
  "the engine's failed load": `(node:1) electron: Failed to load URL: ${HOME}/auth/passkey/complete/${SECRET} with error: ERR_ABORTED`,
  "an error's quote": `Error: ERR_ABORTED (-3) loading '${HOME}/login#${SECRET}'`
}

test("the scrub leaves no credential, wherever in an address it sits, and says the same again", () => {
  for (const [what, line] of Object.entries(CARRIERS)) {
    const out = scrub(line)
    assert.ok(!out.includes(SECRET), `${what}: ${out}`)
    assert.equal(scrub(out), out, what)
  }
})

test("the scrub keeps what carries none", () => {
  for (const line of [`GET ${HOME}/login 200`, `${HOME}/_c/v1/sdk/canvas.abc.js`, "|/usr/share/apport/apport -p%p -s%s -- %E",
    "a page at http://127.0.0.1:7340/bootstrap/ stopped"]) assert.equal(scrub(line), line)
})

test("a record stays JSON with every string in it scrubbed, however quoted", () => {
  const out = scrubbed({rows: [{detail: Object.values(CARRIERS), stopped: `timed out ("still on ${CARRIERS["a fragment"]}")`}]})
  assert.ok(!out.includes(SECRET), out)
  assert.equal(JSON.parse(out).rows.length, 1)
})

test("the app's own output is scrubbed line by line as it is written", () => {
  const cli = fileURLToPath(new URL("../../../../tests/desktop-proof/scrub-lines.mjs", import.meta.url))
  const out = execFileSync(process.execPath, [cli], {input: Object.values(CARRIERS).join("\n"), encoding: "utf8"})
  assert.ok(!out.includes(SECRET), out)
  assert.equal(out.trimEnd().split("\n").length, Object.keys(CARRIERS).length)
})
