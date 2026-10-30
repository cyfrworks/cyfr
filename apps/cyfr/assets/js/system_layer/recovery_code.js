// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A person's recovery code as the browser reads it: `CYFR-` and 112
// Crockford base32 symbols spelling the 32-byte digest of their
// identifier, their 32-byte recovery secret and a 6-byte check, the first
// 6 bytes of SHA-256 over "cyfr-recovery-code/v1", a zero byte, the
// digest and the secret. The reader beside Prima.RecoveryCode, held to
// the same tests/fixtures/recovery_code.json; the steps are the module
// documentation's there. There is no encoder here: the server composes
// every code a page shows.

import {b64url} from "./base64url.js"

const PROTOCOL = "cyfr-recovery-code/v1"
const PREFIX = "CYFR"
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const DIGEST_BYTES = 32
const SECRET_BYTES = 32
const CHECK_BYTES = 6
const SYMBOLS = ((DIGEST_BYTES + SECRET_BYTES + CHECK_BYTES) * 8) / 5

/**
 * Reads `text` as a person copied it. Resolves to `{identifier, secret}`,
 * the secret as its 32 bytes in unpadded base64url, or to
 * `{error: "not_a_code"}` or `{error: "typo"}`. It never rejects for
 * input; it rejects only when there is no WebCrypto to check the code
 * with.
 */
export async function decodeRecoveryCode(text, crypto = globalThis.crypto) {
  if (typeof crypto?.subtle?.digest !== "function") throw new TypeError("no WebCrypto")
  const bytes = symbols(text)
  if (!bytes) return {error: "not_a_code"}

  const digest = bytes.subarray(0, DIGEST_BYTES)
  const secret = bytes.subarray(DIGEST_BYTES, DIGEST_BYTES + SECRET_BYTES)
  const check = bytes.subarray(DIGEST_BYTES + SECRET_BYTES)
  const expected = new Uint8Array(await crypto.subtle.digest("SHA-256", checked(digest, secret))).subarray(0, CHECK_BYTES)
  if (!check.every((byte, i) => byte === expected[i])) return {error: "typo"}
  return {identifier: `per_${hex(digest)}`, secret: b64url(secret)}
}

// The 70 bytes `text` spells, or null when it is not a code: separators
// removed, ASCII only, ASCII letters uppercased, the prefix, then exactly
// 112 symbols with O read as 0 and I and L as 1.
function symbols(text) {
  if (typeof text !== "string") return null
  const stripped = text.replace(/[ \t\n\r-]/g, "")
  if (/[\u0080-\uffff]/.test(stripped)) return null
  const upper = stripped.replace(/[a-z]/g, (letter) => letter.toUpperCase())
  if (!upper.startsWith(PREFIX)) return null
  const body = upper.slice(PREFIX.length).replace(/O/g, "0").replace(/[IL]/g, "1")
  if (body.length !== SYMBOLS) return null

  const bytes = new Uint8Array((SYMBOLS * 5) / 8)
  let held = 0
  let bits = 0
  let at = 0
  for (const symbol of body) {
    const value = ALPHABET.indexOf(symbol)
    if (value < 0) return null
    held = (held << 5) | value
    bits += 5
    if (bits >= 8) {
      bits -= 8
      bytes[at++] = (held >> bits) & 0xff
      held &= (1 << bits) - 1
    }
  }
  return bytes
}

// What the check hashes: the protocol string, a zero byte, the digest and
// the secret.
function checked(digest, secret) {
  const protocol = new TextEncoder().encode(PROTOCOL)
  const bytes = new Uint8Array(protocol.length + 1 + digest.length + secret.length)
  bytes.set(protocol)
  bytes.set(digest, protocol.length + 1)
  bytes.set(secret, protocol.length + 1 + digest.length)
  return bytes
}

function hex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}
