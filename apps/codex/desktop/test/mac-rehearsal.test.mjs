// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {spawnSync} from "node:child_process"
import {test} from "node:test"
import {fileURLToPath} from "node:url"

const script = fileURLToPath(new URL("../../../../tests/desktop-proof/native/mac-rehearsal.sh", import.meta.url))

// The rehearsal trusts a certificate of its own making and leaves the
// trust behind, so off a GitHub-hosted runner it refuses before it reads
// its arguments, let alone trusts or signs anything.
// Windows' own bash may be another system's; the rule is the same there.
test("the Mac rehearsal refuses to run anywhere but GitHub's own runners", {skip: process.platform === "win32"}, () => {
  const base = {PATH: process.env.PATH, SYSTEMROOT: process.env.SYSTEMROOT}
  for (const env of [{}, {GITHUB_ACTIONS: "true"}, {GITHUB_ACTIONS: "true", RUNNER_ENVIRONMENT: "self-hosted"},
    {RUNNER_ENVIRONMENT: "github-hosted"}]) {
    const r = spawnSync("bash", [script, "/bin/sh", "arm64"], {env: {...base, ...env}, encoding: "utf8"})
    assert.equal(r.status, 64, JSON.stringify(env))
    assert.equal(r.stderr, "rehearsal: refused: it trusts a certificate of its own making and leaves the trust behind, so it runs on a GitHub-hosted runner alone\n",
      JSON.stringify(env))
  }
})
