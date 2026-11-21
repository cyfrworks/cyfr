// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The production package's guard: the unpacked app, before it is signed
// or packed, holds exactly the staged app and the verified cyfr. Its
// archive is exactly package.json and main.js, byte for byte the staged
// ones; no app code lies beside it, loose or in another archive; the
// resources hold the archive, cyfr, whose SHA-256 is the verified one,
// and, on Linux, electron-builder's AppArmor profile; and nothing of the
// app carries the proof-only marker, which only a disposable proof build
// contains.

import {createHash} from "node:crypto"
import {existsSync, readFileSync, readdirSync, statSync} from "node:fs"
import path from "node:path"

import {extractFile, listPackage} from "@electron/asar"

export const PROOF_MARKER = "CYFR_DESKTOP_PROOF_ONLY"

export class Refused extends Error {}

function resourcesOf(appOutDir, os) {
  if (os !== "darwin") return path.join(appOutDir, "resources")
  const bundle = readdirSync(appOutDir).find((n) => n.endsWith(".app"))
  if (!bundle) throw new Refused("no app bundle")
  return path.join(appOutDir, bundle, "Contents", "Resources")
}

function* filesUnder(dir) {
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name)
    if (statSync(p).isDirectory()) yield* filesUnder(p)
    else yield p
  }
}

const APP_CODE = /\.(js|mjs|cjs|node|asar)$/

/**
 * Check the unpacked app at appOutDir (os: linux, darwin or windows)
 * against `staged`: {files: {"package.json": bytes, "main.js": bytes},
 * helper: {name, sha256}}. Throws Refused naming the first difference.
 */
export function checkPackage(appOutDir, staged, os) {
  const resources = resourcesOf(appOutDir, os)
  const archive = path.join(resources, "app.asar")
  if (!existsSync(archive)) throw new Refused("no app.asar")
  const listed = listPackage(archive, {isPack: false}).map((p) => p.replace(/^[\\/]/, "").replaceAll("\\", "/")).sort()
  const want = Object.keys(staged.files).sort()
  if (JSON.stringify(listed) !== JSON.stringify(want)) throw new Refused(`app.asar holds ${listed.join(", ")}`)
  for (const name of want) {
    const bytes = extractFile(archive, name)
    if (!bytes.equals(Buffer.from(staged.files[name]))) throw new Refused(`app.asar's ${name} is not the staged one`)
    if (bytes.includes(PROOF_MARKER)) throw new Refused(`app.asar's ${name} carries the proof-only marker`)
  }
  for (const loose of ["app", "app.asar.unpacked"]) {
    if (existsSync(path.join(resources, loose))) throw new Refused(`resources/${loose} lies beside the archive`)
  }
  const helper = path.join(resources, staged.helper.name)
  if (!existsSync(helper) || createHash("sha256").update(readFileSync(helper)).digest("hex") !== staged.helper.sha256) {
    throw new Refused(`resources/${staged.helper.name} is not the verified cyfr`)
  }
  const allowed = new Set(["app.asar", staged.helper.name, ...(os === "linux" ? ["apparmor-profile"] : [])])
  for (const file of filesUnder(resources)) {
    const name = path.relative(resources, file).replaceAll("\\", "/")
    if (allowed.has(name)) continue
    if (os !== "darwin" || APP_CODE.test(name)) throw new Refused(`resources/${name} is not the app's`)
    if (readFileSync(file).includes(PROOF_MARKER)) throw new Refused(`resources/${name} carries the proof-only marker`)
  }
}
