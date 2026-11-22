// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {createHash} from "node:crypto"
import {existsSync, mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync, writeFileSync} from "node:fs"
import {tmpdir} from "node:os"
import path from "node:path"
import {test} from "node:test"
import {fileURLToPath} from "node:url"

import {createPackage, extractFile} from "@electron/asar"

import {PROOF_MARKER, Refused, checkPackage, packaged} from "../scripts/check-package.mjs"

const main = Buffer.from("startApp({cyfr: path.join(process.resourcesPath, 'cyfr')})\n")
const pkg = Buffer.from('{"name":"cyfr-desktop","main":"main.js"}\n')
const cyfr = Buffer.from("the verified cyfr")
// Electron's distribution as electron-builder extracts it, before the
// executable takes the product's name.
const distribution = ["LICENSE.electron.txt", "chrome-sandbox", "electron", "locales/en-US.pak", "resources.pak"]
const staged = {files: {"package.json": pkg, "main.js": main}, product: "CYFR", distribution,
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
  for (const file of distribution) {
    const at = path.join(out, file === "electron" ? "CYFR" : file)
    mkdirSync(path.dirname(at), {recursive: true})
    writeFileSync(at, `Electron's ${file}`)
  }
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
  const beside = await unpacked(t)
  writeFileSync(path.join(beside, "helper"), "an inert executable")
  assert.throws(() => checkPackage(beside, staged, "linux"), Refused, "a file beside resources")
  const deeper = await unpacked(t)
  writeFileSync(path.join(deeper, "locales", "proof.js"), "x")
  assert.throws(() => checkPackage(deeper, staged, "linux"), Refused, "a file among Electron's")
  // Renamed rather than made beside, which a filesystem that folds case
  // cannot hold.
  const cased = await unpacked(t)
  renameSync(path.join(cased, "locales"), path.join(cased, "LOCALES"))
  assert.throws(() => checkPackage(cased, staged, "linux"), Refused, "a file differing from Electron's in case alone")
  const renamed = await unpacked(t)
  writeFileSync(path.join(renamed, "Electron"), "x")
  assert.throws(() => checkPackage(renamed, staged, "linux"), Refused, "Electron's executable under its own name beside the app's")
  const unread = await unpacked(t)
  assert.throws(() => checkPackage(unread, {...staged, distribution: null}, "linux"), Refused, "no distribution read")
  const swapped = await unpacked(t)
  writeFileSync(path.join(swapped, "resources", "cyfr"), "another program")
  assert.throws(() => checkPackage(swapped, staged, "linux"), Refused, "another cyfr")
})

test("electron-builder's renames are each named, and nothing else is renamed", () => {
  assert.equal(packaged("electron", "linux", "CYFR"), "CYFR")
  assert.equal(packaged("locales/en-US.pak", "linux", "CYFR"), "locales/en-US.pak")
  assert.equal(packaged("electron.exe", "windows", "CYFR"), "CYFR.exe")
  assert.equal(packaged("Electron.app/Contents/MacOS/Electron", "darwin", "CYFR"), "CYFR.app/Contents/MacOS/CYFR")
  assert.equal(packaged("Electron.app/Contents/Frameworks/Electron Helper (GPU).app/Contents/MacOS/Electron Helper (GPU)", "darwin", "CYFR"),
    "CYFR.app/Contents/Frameworks/CYFR Helper (GPU).app/Contents/MacOS/CYFR Helper (GPU)")
  assert.equal(packaged("Electron.app/Contents/Frameworks/Electron Helper.app/Contents/Info.plist", "darwin", "CYFR"),
    "CYFR.app/Contents/Frameworks/CYFR Helper.app/Contents/Info.plist")
  assert.equal(packaged("Electron.app/Contents/Frameworks/Electron Framework.framework/Electron Framework", "darwin", "CYFR"),
    "CYFR.app/Contents/Frameworks/Electron Framework.framework/Electron Framework")
})

// The real-CYFR proofs replace the app's entry with a bundle of their own
// (tests/desktop-proof/pack.mjs). Each such bundle carries the proof-only
// marker, so a package holding it is refused even where the bundle is the
// one staged: the swap cannot ship.
test("every proof entry's bundle is refused in a package", async (t) => {
  const {pack} = await import("../../../../tests/desktop-proof/pack.mjs")
  const proofs = fileURLToPath(new URL("../../../../tests/desktop-proof/", import.meta.url))
  const entries = readdirSync(proofs, {withFileTypes: true}).filter((d) => d.isDirectory())
    .map((d) => path.join(proofs, d.name, "proof.js")).filter((f) => existsSync(f))
  assert.ok(entries.length > 0, "no proof entry found")
  for (const entry of entries) {
    const dir = mkdtempSync(path.join(tmpdir(), "cyfr-proof-bundle-"))
    t.after(() => rmSync(dir, {recursive: true, force: true}))
    await pack(entry, path.join(dir, "app.asar"))
    const bundled = extractFile(path.join(dir, "app.asar"), "main.js")
    const out = await unpacked(t, ({files}) => { files["main.js"] = bundled })
    assert.throws(() => checkPackage(out, {...staged, files: {...staged.files, "main.js": bundled}}, "linux"),
      (e) => e instanceof Refused && /proof-only marker/.test(e.message), entry)
  }
})
