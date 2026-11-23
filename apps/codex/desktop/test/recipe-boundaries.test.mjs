// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Two of the Mac distribution's boundaries: the recipe starts a process in
// one place alone (scripts/run.mjs run), and the worker that packs and
// signs takes only its owner's word (scripts/build.mjs --worker).

import assert from "node:assert/strict"
import {spawnSync} from "node:child_process"
import {existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync} from "node:fs"
import {createRequire} from "node:module"
import {tmpdir} from "node:os"
import path from "node:path"
import {test} from "node:test"
import {fileURLToPath, pathToFileURL} from "node:url"

const desktop = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
// The packages build.mjs imports, as it resolves them, for their stand-ins.
const needs = createRequire(path.join(desktop, "package.json"))
const esbuild = pathToFileURL(needs.resolve("esbuild")).href
const builder = pathToFileURL(needs.resolve("electron-builder")).href
const scripts = path.join(desktop, "scripts")

test("the recipe starts a process in one place alone", () => {
  const starts = /node:child_process|["']child_process["']|\bspawn(Sync)?\s*\(|\bexecFile(Sync)?\s*\(|\bexecSync\s*\(|\bfork\s*\(/g
  const found = {}
  for (const name of readdirSync(scripts).filter((n) => /\.(mjs|js|cjs)$/.test(n))) {
    const text = readFileSync(path.join(scripts, name), "utf8")
    const hits = [...text.matchAll(starts)].map((m) => m[0])
    if (hits.length) found[name] = hits
  }
  // run.mjs imports spawn and calls it once.
  assert.deepEqual(found, {"run.mjs": ["node:child_process", "spawn("]})
})

// build.mjs as a worker, on a stand-in Mac: its platform is darwin, and
// esbuild and electron-builder are stand-ins, the packer writing a marker
// if it is ever reached.
function worker(t, {config, env = {}, args = ["--distribution"]}) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-worker-"))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  const file = path.join(dir, "config.json")
  writeFileSync(file, typeof config === "string" ? config : JSON.stringify(config))
  const reached = path.join(dir, "reached")
  const out = path.join(dir, "out")
  mkdirSync(out)
  const script = `
import {writeFileSync} from "node:fs"
import {mock} from "node:test"
Object.defineProperty(process, "platform", {value: "darwin"})
mock.module(${JSON.stringify(esbuild)}, {namedExports: {build: async ({outfile}) => writeFileSync(outfile, "")}})
mock.module(${JSON.stringify(builder)}, {namedExports: {Arch: {arm64: 1, x64: 0}, Platform: {MAC: {createTarget: () => []}},
  build: async () => writeFileSync(${JSON.stringify(reached)}, "the packer ran")}})
process.argv = [process.execPath, ${JSON.stringify(path.join(scripts, "build.mjs"))}, "--cyfr", "/bin/sh", "--version", "1.2.3",
  "--arch", "arm64", "--out", ${JSON.stringify(out)}, ...${JSON.stringify(args)}, "--worker", ${JSON.stringify(file)}]
await import(${JSON.stringify(new URL("../scripts/build.mjs", import.meta.url).href)})
`
  const base = Object.fromEntries(Object.entries(process.env).filter(([n]) => !n.startsWith("CYFR_BUILD_")))
  const entry = path.join(dir, "entry.mjs")
  writeFileSync(entry, script)
  const r = spawnSync(process.execPath, ["--experimental-test-module-mocks", "--no-warnings", entry], {env: {...base, ...env}, encoding: "utf8"})
  return {status: r.status, err: r.stderr, reached: existsSync(reached)}
}

const complete = (over = {}) => ({phase: "app", owner: "the-owners-word", ownerPid: process.pid, identity: "CYFR Works Inc. (AB12CD34EF)",
  team: "AB12CD34EF", group: "AB12CD34EF.com.cyfrworks.cyfr.webauthn", profile: "/nowhere/embedded.provisionprofile",
  keychain: "/nowhere/signing.keychain-db", rehearsed: true, result: "/nowhere/result.json", ...over})

test("the worker takes only its owner's word: a null, partial or foreign configuration is refused before anything packs",
  {skip: process.platform === "win32"}, (t) => {
    const word = {CYFR_BUILD_OWNER: "the-owners-word"}
    const cases = {
      "Sol's null configuration": [{config: "null", env: word}, "the worker's configuration is not complete"],
      "a configuration that is not JSON": [{config: "{", env: word}, "the worker's configuration is not the owner's"],
      "a configuration missing its keychain": [{config: complete({keychain: undefined}), env: word}, "the worker's configuration is not complete"],
      "a DMG phase without its app": [{config: complete({phase: "dmg"}), env: word}, "the worker's configuration is not complete"],
      "no owner's word": [{config: complete()}, "the worker was not started by its owner"],
      "another owner's word": [{config: complete(), env: {CYFR_BUILD_OWNER: "someone-else"}}, "the worker was not started by its owner"],
      "an owner that is not its parent": [{config: complete({ownerPid: 1}), env: word}, "the worker was not started by its owner"],
      "a worker outside a distribution": [{config: complete(), env: word, args: []}, "--worker is a Mac distribution's own, started by its owner"]
    }
    for (const [name, [given, said]] of Object.entries(cases)) {
      const r = worker(t, given)
      assert.equal(r.status, 1, `${name}: ${r.err}`)
      assert.equal(r.err.trim(), `refused: ${said}`, name)
      assert.equal(r.reached, false, `${name}: the packer ran`)
    }
    // The owner's own word, from its own process, reaches the packer.
    assert.equal(worker(t, {config: complete(), env: word}).reached, true, "the owner's worker did not reach the packer")
  })
