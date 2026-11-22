// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The app's own output as a proof's record keeps it (home.sh): its standard
// input, each line scrubbed (scrub.mjs) before it is written.
//
// Usage: node tests/desktop-proof/scrub-lines.mjs <APP_OUTPUT >RECORD

import {createInterface} from "node:readline"

import {scrub} from "./scrub.mjs"

for await (const line of createInterface({input: process.stdin, crlfDelay: Infinity})) process.stdout.write(scrub(line) + "\n")
