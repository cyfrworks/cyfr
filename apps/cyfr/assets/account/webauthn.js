// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A passkey's signature, Prima.Identity.WebAuthn's check in the browser:
// the raw bytes a WebAuthn assertion returned, verified over an expected
// challenge at the directory's origin and host. The steps and their
// refusals are the Elixir module's, in its order: client data (type,
// challenge, origin, crossOrigin), authenticator data (size, rpIdHash,
// user presence, user verification), then the DER ECDSA P-256 signature
// over `authenticator_data ‖ SHA-256(client_data)`.

import {b64, concat, isObject, sha256} from "./encoding.js"

const FIXED_BYTES = 37
const USER_PRESENT = 0x01
const USER_VERIFIED = 0x04

/**
 * Check `assertion` (`{authenticator_data, client_data, signature}` as
 * bytes) made by the passkey whose 65-byte point is `pub` over the
 * `challenge` bytes at `origin` and relying party `rpId`. Resolves to
 * "ok" or the refusal of the first check that fails.
 */
export async function verifyAssertion(assertion, pub, challenge, origin, rpId) {
  const client = clientData(assertion.client_data)
  if (!client) return "malformed"
  if (client.type !== "webauthn.get") return "wrong_type"
  if (client.challenge !== b64(challenge)) return "wrong_challenge"
  if (client.origin !== origin) return "wrong_origin"
  if (client.crossOrigin === true) return "cross_origin"

  const data = assertion.authenticator_data
  if (data.length < FIXED_BYTES) return "malformed"
  if (!same(data.subarray(0, 32), await sha256(rpId))) return "wrong_rp"
  if ((data[32] & USER_PRESENT) === 0) return "user_not_present"
  if ((data[32] & USER_VERIFIED) === 0) return "user_not_verified"

  return (await signed(assertion, pub)) ? "ok" : "bad_signature"
}

function clientData(bytes) {
  try {
    const client = JSON.parse(new TextDecoder("utf-8", {fatal: true}).decode(bytes))
    return isObject(client) ? client : null
  } catch (_error) {
    return null
  }
}

function same(a, b) {
  return a.length === b.length && a.every((byte, i) => byte === b[i])
}

async function signed(assertion, pub) {
  const raw = derToRaw(assertion.signature)
  if (!raw) return false
  const message = concat(assertion.authenticator_data, await sha256(assertion.client_data))
  try {
    const key = await crypto.subtle.importKey("raw", pub, {name: "ECDSA", namedCurve: "P-256"}, false, ["verify"])
    return await crypto.subtle.verify({name: "ECDSA", hash: "SHA-256"}, key, raw, message)
  } catch (_error) {
    return false
  }
}

// WebCrypto takes an ECDSA signature as r ‖ s, 32 bytes each; WebAuthn
// returns the DER SEQUENCE of two INTEGERs. Anything but exactly that
// sequence, in short-form lengths, is no signature.
function derToRaw(der) {
  if (der.length < 8 || der[0] !== 0x30 || der[1] !== der.length - 2) return null
  const r = integer(der, 2)
  const s = r && integer(der, r.next)
  if (!s || s.next !== der.length) return null
  return concat(r.value, s.value)
}

function integer(der, at) {
  if (der[at] !== 0x02) return null
  const size = der[at + 1]
  if (size < 1 || size > 33 || at + 2 + size > der.length) return null
  let value = der.subarray(at + 2, at + 2 + size)
  while (value.length > 1 && value[0] === 0) value = value.subarray(1)
  if (value.length > 32) return null
  const padded = new Uint8Array(32)
  padded.set(value, 32 - value.length)
  return {value: padded, next: at + 2 + size}
}
