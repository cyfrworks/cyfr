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
// fronts record one.

/** What a proof puts in an address's query and fragment to see that the app prints neither. */
export const MARKER = "cyfr-proof-unprinted"

const IN_PATH = /(\/+auth\/+passkey\/+complete\/+|\/+_s\/+|\/+_c\/+v1\/+(?!sdk\/))[^\s/?#"'`<>\\()[\]]+/g
const AFTER_PATH = /((?:\b[a-z][a-z0-9+.-]*:\/\/|\bdata:|(?<![\w.:/~-])\/)[^\s"'`<>\\?#]*)([?#])[^\s"'`<>\\]*/gi

/** `text` with every address in it cut at its query or fragment and without the credential in its path. */
export function scrub(text) {
  return String(text).replace(IN_PATH, "$1[REDACTED]").replace(AFTER_PATH, "$1$2")
}

/** The JSON of `value` with every string in it scrubbed. */
export function scrubbed(value, space) {
  return JSON.stringify(value, (_key, v) => typeof v === "string" ? scrub(v) : v, space)
}
