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

import {b64url, fromB64url} from "./base64url.js"

function descriptors(list) {
  return (list || []).map((descriptor) => ({...descriptor, id: fromB64url(descriptor.id)}))
}

/**
 * The home's creation options (`passkey.register` without a credential)
 * as `navigator.credentials.create` takes them.
 */
export function creationOptions(json) {
  return {
    ...json,
    challenge: fromB64url(json.challenge),
    user: {...json.user, id: fromB64url(json.user.id)},
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
    challenge: fromB64url(json.challenge),
    allowCredentials: descriptors(json.allowCredentials)
  }
}

/** A created credential as the home reads it, with its registration token. */
export function registrationJSON(credential, registration) {
  const response = credential.response
  const answer = {
    id: credential.id,
    rawId: b64url(credential.rawId),
    type: credential.type,
    registration,
    response: {
      clientDataJSON: b64url(response.clientDataJSON),
      attestationObject: b64url(response.attestationObject)
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
    rawId: b64url(credential.rawId),
    type: credential.type,
    response: {
      clientDataJSON: b64url(response.clientDataJSON),
      authenticatorData: b64url(response.authenticatorData),
      signature: b64url(response.signature)
    }
  }
  if (response.userHandle) answer.response.userHandle = b64url(response.userHandle)
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
