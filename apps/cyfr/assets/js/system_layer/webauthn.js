// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * The browser half of a passkey ceremony, called only by the system layer
 * and the sign-in page: the home's JSON options in, the authenticator's
 * answer out, as the JSON the home verifies (`Sanctum.Passkeys`).
 *
 * Binary fields travel as unpadded base64url both ways: the challenge,
 * the user handle and credential ids in the options; the client data,
 * attestation object, authenticator data, signature and user handle in
 * the answer. A registration's answer carries the home's opaque
 * `registration` token back beside it, unchanged.
 *
 * Nothing here decides: the home checks the origin, the RP ID, the
 * challenge (for a confirmation, the raw bytes of its digest), user
 * verification and the signature. A ceremony the person cancels or the
 * browser refuses rejects its promise; the caller says so and sends
 * nothing.
 */

/** Unpadded base64url of `buffer` (an ArrayBuffer or a view of one). */
export function bytesToB64url(buffer) {
  const bytes = buffer instanceof ArrayBuffer ? new Uint8Array(buffer) : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength)
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** The bytes unpadded (or padded) base64url `text` spells, as an ArrayBuffer. */
export function b64urlToBytes(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]*={0,2}$/.test(text)) {
    throw new TypeError("not base64url")
  }
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "")
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4)
  const binary = atob(padded)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes.buffer
}

function descriptors(list) {
  return (list || []).map((descriptor) => ({...descriptor, id: b64urlToBytes(descriptor.id)}))
}

/**
 * The home's creation options (`passkey.register` without a credential)
 * as `navigator.credentials.create` takes them.
 */
export function creationOptions(json) {
  return {
    ...json,
    challenge: b64urlToBytes(json.challenge),
    user: {...json.user, id: b64urlToBytes(json.user.id)},
    excludeCredentials: descriptors(json.excludeCredentials)
  }
}

/**
 * The home's request options (a sign-in challenge, or a pending
 * confirmation's `webauthn`) as `navigator.credentials.get` takes them.
 */
export function requestOptions(json) {
  return {
    ...json,
    challenge: b64urlToBytes(json.challenge),
    allowCredentials: descriptors(json.allowCredentials)
  }
}

/** A created credential as the home reads it, with its registration token. */
export function registrationJSON(credential, registration) {
  const response = credential.response
  const answer = {
    id: credential.id,
    rawId: bytesToB64url(credential.rawId),
    type: credential.type,
    registration,
    response: {
      clientDataJSON: bytesToB64url(response.clientDataJSON),
      attestationObject: bytesToB64url(response.attestationObject)
    }
  }
  if (typeof response.getTransports === "function") answer.response.transports = response.getTransports()
  return answer
}

/** An assertion as the home reads it. */
export function assertionJSON(credential) {
  const response = credential.response
  const answer = {
    id: credential.id,
    rawId: bytesToB64url(credential.rawId),
    type: credential.type,
    response: {
      clientDataJSON: bytesToB64url(response.clientDataJSON),
      authenticatorData: bytesToB64url(response.authenticatorData),
      signature: bytesToB64url(response.signature)
    }
  }
  if (response.userHandle) answer.response.userHandle = bytesToB64url(response.userHandle)
  return answer
}

/** Whether this browser can hold a passkey ceremony at all. */
export function supported(scope = globalThis) {
  return Boolean(scope.PublicKeyCredential && scope.navigator?.credentials?.get && scope.isSecureContext !== false)
}

/**
 * Register: create a credential for the home's options (`publicKey`) and
 * answer it with the home's `registration` token.
 */
export async function register(publicKey, registration, credentials = globalThis.navigator.credentials) {
  const credential = await credentials.create({publicKey: creationOptions(publicKey)})
  if (!credential) throw new Error("no credential")
  return registrationJSON(credential, registration)
}

/**
 * Assert: answer the home's request options (`publicKey`) with a passkey
 * registered there, with user verification.
 */
export async function assert(publicKey, credentials = globalThis.navigator.credentials) {
  const credential = await credentials.get({publicKey: requestOptions(publicKey)})
  if (!credential) throw new Error("no credential")
  return assertionJSON(credential)
}
