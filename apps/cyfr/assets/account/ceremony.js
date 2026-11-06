// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The two passkey ceremonies the pages run, over the browser's
// `navigator.credentials` (or whatever stands in for it in a test): an
// assertion over a challenge, and a passkey's creation for an account.
// Every ceremony runs at this page's host as the relying party with
// `userVerification: "required"`. A ceremony the person cancels, or the
// browser refuses, rejects; the page says so and sends nothing.

import {identifierForUserId} from "./identity.js"

const ES256 = -7

// The DER prefix of a P-256 public key's SubjectPublicKeyInfo, before its
// 65-byte uncompressed point.
const P256_SPKI = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
  0x03, 0x42, 0x00
]

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
     * id and its 65-byte P-256 point; rejects for any other algorithm.
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
      if (!p256) throw new Error("the passkey is not a P-256 key")
      return {credentialId: bytes(credential.rawId), pub: spki.subarray(P256_SPKI.length)}
    }
  }
}
