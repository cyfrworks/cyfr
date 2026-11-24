// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The production package's guard: the unpacked app, before it is signed
// or packed, holds exactly the pinned Electron distribution, the staged
// app and the verified cyfr. Every file of the package is one of three:
// a file of the Electron distribution as electron-builder extracted it
// (`distribution`, read at its afterExtract step), under exactly its path
// or, for the files electron-builder renames, the one name `packaged`
// gives it; the archive, exactly
// package.json and main.js, byte for byte the staged ones; or cyfr, whose
// SHA-256 is the verified one, with electron-builder's AppArmor profile
// on Linux and the app's icon on macOS. Nothing else, loose app code and
// a second archive among it, and nothing of the app carries the
// proof-only marker, which only a disposable proof build contains.

import {createHash} from "node:crypto"
import {existsSync, lstatSync, readFileSync, readdirSync} from "node:fs"
import path from "node:path"

import {extractFile, listPackage} from "@electron/asar"

export const PROOF_MARKER = "CYFR_DESKTOP_PROOF_ONLY"

// The values no sentence may carry: what hide() was given, whole, line by
// line and word by word (each run of four or more letters, digits, "+" or
// "/" between other characters), so a value printed quoted, escaped,
// wrapped or cut into its words is hidden all the same.
let hidden = []

/** Hide `values` (strings; empty ones ignored) in every later sentence. */
export function hide(values) {
  const parts = new Set(hidden)
  for (const value of values) {
    if (typeof value !== "string" || value === "") continue
    parts.add(value)
    for (const line of value.split(/\r?\n/)) if (line.trim().length >= 4) parts.add(line.trim())
    for (const word of value.split(/[^A-Za-z0-9+/]+/)) if (word.length >= 4) parts.add(word)
  }
  hidden = [...parts].sort((a, b) => b.length - a.length)
}

/** `text` with every hidden value, and every part of one, as "***". */
export function redact(text) {
  let out = String(text)
  for (const part of hidden) out = out.split(part).join("***")
  return out
}

/** A refusal: its sentence never carries a hidden value. */
export class Refused extends Error {
  constructor(message) {
    super(redact(message))
  }
}

/** Every file under dir (links as files), as paths relative to it with "/". */
export function filesOf(dir) {
  const out = []
  const walk = (at) => {
    for (const name of readdirSync(at)) {
      const p = path.join(at, name)
      if (lstatSync(p).isDirectory()) walk(p)
      else out.push(path.relative(dir, p).replaceAll("\\", "/"))
    }
  }
  walk(dir)
  return out.sort()
}

function resourcesOf(appOutDir, os) {
  if (os !== "darwin") return "resources"
  const bundle = readdirSync(appOutDir).find((n) => n.endsWith(".app"))
  if (!bundle) throw new Refused("no app bundle")
  return `${bundle}/Contents/Resources`
}

// The macOS helper apps Electron ships, each renamed with the bundle.
const HELPERS = ["Helper", "Helper (GPU)", "Helper (Plugin)", "Helper (Renderer)"]

/**
 * Where the package holds Electron's distribution file `file` on `os`:
 * electron-builder names Electron's executable, and on macOS its bundle
 * and helper apps, after the product. Each such file is named here; every
 * other keeps its path, exactly.
 */
export function packaged(file, os, product) {
  if (os === "linux") return file === "electron" ? product : file
  if (os === "windows") return file === "electron.exe" ? `${product}.exe` : file
  if (!file.startsWith("Electron.app/")) return file
  const inside = file.slice("Electron.app/".length)
  if (inside === "Contents/MacOS/Electron") return `${product}.app/Contents/MacOS/${product}`
  for (const helper of HELPERS) {
    const from = `Contents/Frameworks/Electron ${helper}.app/`
    if (!inside.startsWith(from)) continue
    const rest = inside.slice(from.length)
    const to = `${product}.app/Contents/Frameworks/${product} ${helper}.app/`
    return to + (rest === `Contents/MacOS/Electron ${helper}` ? `Contents/MacOS/${product} ${helper}` : rest)
  }
  return `${product}.app/${inside}`
}

/**
 * Check the unpacked app at appOutDir (os: linux, darwin or windows)
 * against `staged`: {files: {"package.json": bytes, "main.js": bytes},
 * helper: {name, sha256}, product, distribution: [paths]}. Throws Refused
 * naming the first difference.
 */
export function checkPackage(appOutDir, staged, os) {
  const resources = resourcesOf(appOutDir, os)
  const archive = path.join(appOutDir, resources, "app.asar")
  if (!existsSync(archive)) throw new Refused("no app.asar")
  const listed = listPackage(archive, {isPack: false}).map((p) => p.replace(/^[\\/]/, "").replaceAll("\\", "/")).sort()
  const want = Object.keys(staged.files).sort()
  if (JSON.stringify(listed) !== JSON.stringify(want)) throw new Refused(`app.asar holds ${listed.join(", ")}`)
  for (const name of want) {
    const bytes = extractFile(archive, name)
    if (!bytes.equals(Buffer.from(staged.files[name]))) throw new Refused(`app.asar's ${name} is not the staged one`)
    if (bytes.includes(PROOF_MARKER)) throw new Refused(`app.asar's ${name} carries the proof-only marker`)
  }
  const helper = path.join(appOutDir, resources, staged.helper.name)
  if (!existsSync(helper) || createHash("sha256").update(readFileSync(helper)).digest("hex") !== staged.helper.sha256) {
    throw new Refused(`${resources}/${staged.helper.name} is not the verified cyfr`)
  }
  const own = new Set([`${resources}/app.asar`, `${resources}/${staged.helper.name}`,
    ...(os === "linux" ? [`${resources}/apparmor-profile`] : []), ...(os === "darwin" ? [`${resources}/icon.icns`] : [])])
  if (!Array.isArray(staged.distribution)) throw new Refused("Electron's distribution was not read")
  const distribution = new Set(staged.distribution.map((f) => packaged(f, os, staged.product)))
  for (const file of filesOf(appOutDir)) {
    if (own.has(file)) continue
    if (!distribution.has(file)) throw new Refused(`${file} is neither the app's nor Electron's`)
    if (/\.(js|mjs|cjs|asar)$/.test(file) && readFileSync(path.join(appOutDir, file)).includes(PROOF_MARKER)) {
      throw new Refused(`${file} carries the proof-only marker`)
    }
  }
}
