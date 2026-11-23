// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The one scrub of whatever a proof against a real CYFR writes (README.md):
// lib.js's writers and, through scrub-lines.mjs, the app's own output.
//
// A credential sits in an address in three places:
//   its fragment  the run token, a sign-in's answer, an enrolment offer
//   its query     a socket's forgery token, a confirmation's reference
//   its path      the segment after each prefix below: a sign-in's one-use
//                 ticket (apps/cyfr/lib/prism/router.ex) and the asset
//                 credential of served files and of a canvas's page, where
//                 CyfrWeb.Plugs.ScrubTinctureCredentials redacts it too
// An address is one with an origin or a path standing by itself, as the
// fronts record one. A credential a proof knows by its value, such as the
// setup token, is cut wherever it stands: the file CYFR_PROOF_WITHHELD
// names holds one such value a line, read again at each scrub, since the
// proof learns it during the run.

import {readFileSync} from "node:fs"

/** What a proof puts in an address's query and fragment to see that the app prints neither. */
export const MARKER = "cyfr-proof-unprinted"

// The values the proof withholds, as its file holds them now.
function withheld() {
  const file = process.env.CYFR_PROOF_WITHHELD
  if (!file) return []
  try {
    return readFileSync(file, "utf8").split("\n").filter((v) => v.length >= 16)
  } catch {
    return []
  }
}

const IN_PATH = /(\/+auth\/+passkey\/+complete\/+|\/+_s\/+|\/+_c\/+v1\/+(?!sdk\/))[^\s/?#"'`<>\\()[\]]+/g
const AFTER_PATH = /((?:\b[a-z][a-z0-9+.-]*:\/\/|\bdata:|(?<![\w.:/~-])\/)[^\s"'`<>\\?#]*)([?#])[^\s"'`<>\\]*/gi

/** `text` without a value the proof withholds, and with every address in it cut at its query or fragment and without the credential in its path. */
export function scrub(text) {
  const cut = withheld().reduce((t, v) => t.split(v).join("[WITHHELD]"), String(text))
  return cut.replace(IN_PATH, "$1[REDACTED]").replace(AFTER_PATH, "$1$2")
}

/** The JSON of `value` with every string in it scrubbed. */
export function scrubbed(value, space) {
  return JSON.stringify(value, (_key, v) => typeof v === "string" ? scrub(v) : v, space)
}
