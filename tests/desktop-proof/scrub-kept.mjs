// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The folder a proof run uploads, built once at the run's end
// (tests/setup-proof/app.sh): each file the run kept, through the one scrub
// (scrub.mjs), with every value the run withholds known to it before its
// first line is read. It writes OUT/<the file's name> for each, then prints
// how often the scrub met a withheld value in all it read, "met N", and the
// names it built, "built NAME…". A file it cannot read or write ends it with
// status 1, and the caller leaves OUT empty.
//
// Usage: node tests/desktop-proof/scrub-kept.mjs WITHHELD OUT FILE…
// WITHHELD holds one value a line; values shorter than 16 are not secrets
// and are not read as such.

import {readFileSync, writeFileSync} from "node:fs"
import path from "node:path"

import {scrub} from "./scrub.mjs"

const [withheldFile, out, ...files] = process.argv.slice(2)
const withheld = [...new Set(readFileSync(withheldFile, "utf8").split("\n").filter((v) => v.length >= 16))]
let met = 0
const built = []
for (const file of files) {
  const text = readFileSync(file, "utf8")
  for (const v of withheld) met += text.split(v).length - 1
  const name = path.basename(file)
  writeFileSync(path.join(out, name), text.split("\n").map((line) => scrub(line, withheld)).join("\n"))
  built.push(name)
}
process.stdout.write(`met ${met}\nbuilt ${built.join(" ")}\n`)
