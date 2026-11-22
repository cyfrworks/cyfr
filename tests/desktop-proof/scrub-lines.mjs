// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The app's own output as a proof's record keeps it (home.sh): its standard
// input, each line scrubbed (scrub.mjs) before it is written. It reads the
// output raw, so it holds the row `unprinted`, which home.sh's exit takes:
// no line the app printed had anything for the scrub to cut, and none held
// the proofs' marker.
//
// Usage: node tests/desktop-proof/scrub-lines.mjs <APP_OUTPUT >RECORD

import {createInterface} from "node:readline"

import {MARKER, scrub} from "./scrub.mjs"

let read = 0
let failedLoads = 0
let carried = 0
for await (const line of createInterface({input: process.stdin, crlfDelay: Infinity})) {
  const clean = scrub(line)
  read++
  if (line.includes("Failed to load URL")) failedLoads++
  if (clean !== line || line.includes(MARKER)) carried++
  process.stdout.write(clean + "\n")
}
process.stdout.write(`${carried ? "FAIL" : "PASS"} unprinted: of ${read} lines the app printed, ${failedLoads} of them a failed load's, ` +
  `${carried} carried an address's fragment or query or a credential\n`)
if (carried) {
  process.stderr.write(`FAIL unprinted: ${carried} of the app's lines carried an address's fragment or query or a credential\n`)
  process.exitCode = 1
}
