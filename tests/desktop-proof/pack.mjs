// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A proof's entry bundled as the app's archive, for a real-CYFR proof
// alone (home.sh): the entry ENTRY (a script's proof.js, which runs the
// production startApp of apps/codex/desktop/src/app.js) bundled as the
// production entry is (scripts/build.mjs), into OUT, an app.asar of
// package.json and main.js. The bundle carries the proof-only marker, so
// the package guard refuses it in any package that ships.
//
// Usage: node tests/desktop-proof/pack.mjs ENTRY OUT
// It uses apps/codex/desktop's own esbuild and @electron/asar, installed
// with npm ci there.

import {mkdtempSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {createRequire} from "node:module"
import {tmpdir} from "node:os"
import path from "node:path"
import {fileURLToPath, pathToFileURL} from "node:url"

const desktop = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "apps", "codex", "desktop")
const need = createRequire(path.join(desktop, "package.json"))
const {build} = need("esbuild")
const {createPackage} = need("@electron/asar")
const {PROOF_MARKER} = await import(pathToFileURL(path.join(desktop, "scripts", "check-package.mjs")).href)

/** Bundle `entry` into the app archive at `out`. */
export async function pack(entry, out) {
  const stage = mkdtempSync(path.join(tmpdir(), "cyfr-desktop-proof-pack-"))
  try {
    await build({
      entryPoints: [entry], outfile: path.join(stage, "main.js"), bundle: true, platform: "node", format: "cjs",
      target: "node22", external: ["electron"], legalComments: "none", banner: {js: `// ${PROOF_MARKER}`}
    })
    if (!readFileSync(path.join(stage, "main.js"), "utf8").includes(PROOF_MARKER)) throw new Error("the bundle lacks the proof-only marker")
    const pkg = JSON.parse(readFileSync(path.join(desktop, "package.json"), "utf8"))
    writeFileSync(path.join(stage, "package.json"), JSON.stringify({name: pkg.name, productName: "CYFR", version: "0.0.0-proof",
      main: "main.js"}, null, 2) + "\n")
    await createPackage(stage, out)
  } finally {
    rmSync(stage, {recursive: true, force: true})
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [entry, out] = process.argv.slice(2)
  if (!entry || !out) {
    console.error("usage: node tests/desktop-proof/pack.mjs ENTRY OUT")
    process.exit(64)
  }
  await pack(path.resolve(entry), path.resolve(out))
}
