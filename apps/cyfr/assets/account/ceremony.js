// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The two passkey ceremonies the pages run, over the browser's
// `navigator.credentials` (or whatever stands in for it in a test): an
// assertion over a challenge, and a passkey's creation for an account.
// Every ceremony runs at this page's host as the relying party with
// `userVerification: "required"`. A ceremony the person cancels, or the
// browser refuses, rejects; the page says so and sends nothing.

import {hex, refuse} from "./encoding.js"
import {identifierForUserId} from "./identity.js"

const ES256 = -7

// The DER prefix of a P-256 public key's SubjectPublicKeyInfo, before its
// 65-byte uncompressed point.
const P256_SPKI = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
  0x03, 0x42, 0x00
]

// The attested credential data's flag in the authenticator data, and where
// its AAGUID sits: after the 32-byte rpIdHash, the flags and the counter.
const ATTESTED = 0x40
const AAGUID_AT = 37
const AAGUID_BYTES = 16

// The passkey's maker as its authenticator reported it at creation: its
// AAGUID as a lowercase hyphenated UUID, or undefined when the browser
// cannot say (no getAuthenticatorData) or reports zeros, as a browser may
// for attestation "none".
function makerOf(response) {
  const data = typeof response.getAuthenticatorData === "function" ? bytes(response.getAuthenticatorData()) : null
  if (!data || data.length < AAGUID_AT + AAGUID_BYTES || !(data[32] & ATTESTED)) return undefined
  const aaguid = data.subarray(AAGUID_AT, AAGUID_AT + AAGUID_BYTES)
  if (aaguid.every((byte) => byte === 0)) return undefined
  const h = hex(aaguid)
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

function bytes(buffer) {
  if (!buffer) return null
  return buffer instanceof ArrayBuffer ? new Uint8Array(buffer.slice(0)) : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength).slice()
}

/** The ceremonies at `rpId` over `credentials`. */
export function passkeys(credentials, rpId) {
  return {
    rpId,

    /**
     * An assertion over `challenge` (bytes) by a passkey of this host,
     * restricted to the credential ids in `allow` when given. Resolves to
     * the identifier its user handle names (null when it names none), the
     * credential's raw id and the three signed byte fields.
     */
    async assert({challenge, allow}) {
      const publicKey = {challenge, rpId, userVerification: "required"}
      if (allow) publicKey.allowCredentials = allow.map((id) => ({type: "public-key", id}))
      const credential = await credentials.get({publicKey})
      const response = credential.response
      const userHandle = bytes(response.userHandle)
      return {
        identifier: userHandle ? identifierForUserId(userHandle) : null,
        credentialId: bytes(credential.rawId),
        authenticatorData: bytes(response.authenticatorData),
        clientData: bytes(response.clientDataJSON),
        signature: bytes(response.signature)
      }
    },

    /**
     * A new discoverable passkey for the account whose identifier's digest
     * bytes are `userId`, shown as `name`. Resolves to its raw credential
     * id, its 65-byte P-256 point and, when the browser reports one, its
     * maker's `aaguid`; rejects for any other algorithm.
     */
    async create({userId, name, challenge}) {
      const credential = await credentials.create({
        publicKey: {
          challenge,
          rp: {id: rpId, name: "CYFR"},
          user: {id: userId, name, displayName: name},
          pubKeyCredParams: [{type: "public-key", alg: ES256}],
          authenticatorSelection: {residentKey: "required", requireResidentKey: true, userVerification: "required"},
          attestation: "none"
        }
      })
      const response = credential.response
      const spki = bytes(response.getPublicKey())
      const p256 = response.getPublicKeyAlgorithm() === ES256 && spki?.length === P256_SPKI.length + 65 && P256_SPKI.every((byte, i) => spki[i] === byte)
      if (!p256) refuse("no_public_key")
      const made = {credentialId: bytes(credential.rawId), pub: spki.subarray(P256_SPKI.length)}
      const aaguid = makerOf(response)
      return aaguid ? {...made, aaguid} : made
    }
  }
}
