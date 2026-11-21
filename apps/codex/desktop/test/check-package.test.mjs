// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {createHash} from "node:crypto"
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from "node:fs"
import {tmpdir} from "node:os"
import path from "node:path"
import {test} from "node:test"

import {createPackage} from "@electron/asar"

import {PROOF_MARKER, Refused, checkPackage} from "../scripts/check-package.mjs"

const main = Buffer.from("startApp({cyfr: path.join(process.resourcesPath, 'cyfr')})\n")
const pkg = Buffer.from('{"name":"cyfr-desktop","main":"main.js"}\n')
const cyfr = Buffer.from("the verified cyfr")
const staged = {files: {"package.json": pkg, "main.js": main},
  helper: {name: "cyfr", sha256: createHash("sha256").update(cyfr).digest("hex")}}

// An unpacked Linux app as electron-builder leaves it, changed by `spoil`.
async function unpacked(t, spoil = () => {}) {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-package-"))
  t.after(() => rmSync(dir, {recursive: true, force: true}))
  const src = path.join(dir, "src")
  mkdirSync(src)
  const files = {"package.json": pkg, "main.js": main}
  spoil({files, dir})
  for (const [name, bytes] of Object.entries(files)) writeFileSync(path.join(src, name), bytes)
  const out = path.join(dir, "out")
  mkdirSync(path.join(out, "resources"), {recursive: true})
  await createPackage(src, path.join(out, "resources", "app.asar"))
  writeFileSync(path.join(out, "resources", "cyfr"), cyfr)
  writeFileSync(path.join(out, "resources", "apparmor-profile"), "profile CYFR {}\n")
  writeFileSync(path.join(out, "CYFR"), "the Electron executable")
  return out
}

test("the staged app and the verified cyfr pass", async (t) => {
  checkPackage(await unpacked(t), staged, "linux")
})

test("a contaminated package is refused", async (t) => {
  const cases = {
    "a third file in the archive": ({files}) => { files["proof.js"] = Buffer.from("x") },
    "the proof-only marker in main.js": ({files}) => { files["main.js"] = Buffer.concat([main, Buffer.from(`// ${PROOF_MARKER}\n`)]) },
    "another main.js": ({files}) => { files["main.js"] = Buffer.from("other") }
  }
  for (const [name, spoil] of Object.entries(cases)) {
    const out = await unpacked(t, spoil)
    assert.throws(() => checkPackage(out, staged, "linux"), Refused, name)
  }
  const loose = await unpacked(t)
  mkdirSync(path.join(loose, "resources", "app"))
  writeFileSync(path.join(loose, "resources", "app", "main.js"), main)
  assert.throws(() => checkPackage(loose, staged, "linux"), Refused, "loose app code beside the archive")
  const second = await unpacked(t)
  writeFileSync(path.join(second, "resources", "proof.asar"), "x")
  assert.throws(() => checkPackage(second, staged, "linux"), Refused, "a second archive")
  const swapped = await unpacked(t)
  writeFileSync(path.join(swapped, "resources", "cyfr"), "another program")
  assert.throws(() => checkPackage(swapped, staged, "linux"), Refused, "another cyfr")
})
