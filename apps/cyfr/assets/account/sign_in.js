// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The request a CYFR sends to /account/sign and the answer the page sends
// back, `cyfr-sign-in/v1`, Prima.SignIn's in the browser, held to
// tests/fixtures/sign_in.json. The page reads the request out of its
// fragment, refuses one that is malformed or past its expiry, signs its
// digest with the passkey the person picks, and puts the answer in the
// fragment of the request's `return`. Checking the answer is the CYFR's.

import {fromB64url} from "./base64url.js"
import {Refusal, b64, binary, check, directoryOrigin, fields, isDigest, isDirectoryUrl, isHome, isMs, isObject, jcs, protocol, refuse, sha256, utf8} from "./encoding.js"
import {readToSign} from "./registry.js"

export const PROTOCOL = "cyfr-sign-in/v1"
export const CHALLENGE_BYTES = 32
export const MAX_FRAGMENT_BYTES = 32768

const REQUIRED = ["protocol", "purpose", "audience", "challenge", "expires_at", "return"]
const BY_PURPOSE = {sign_in: [], confirm: ["subject"], registry: ["registry_request"]}

/**
 * Read a request from its JSON map in Prima.SignIn.decode's order.
 * Resolves nothing: returns the map, or throws its `Refusal`.
 */
export function readRequest(map) {
  if (!isObject(map)) refuse("invalid_field", {field: "request"})
  protocol(map, PROTOCOL)
  if (!Object.hasOwn(map, "purpose")) refuse("missing_field", {field: "purpose"})
  if (!Object.hasOwn(BY_PURPOSE, map.purpose)) refuse("invalid_field", {field: "purpose"})
  fields(map, [...REQUIRED, ...BY_PURPOSE[map.purpose]])
  check(map, "audience", isHome)
  binary(map, "challenge", CHALLENGE_BYTES)
  check(map, "expires_at", isMs)
  check(map, "return", (value) => isDirectoryUrl(value) && directoryOrigin(value).origin === map.audience)
  if (Object.hasOwn(map, "subject")) check(map, "subject", isDigest)
  if (Object.hasOwn(map, "registry_request")) {
    try {
      readToSign(map.registry_request)
    } catch (error) {
      if (error instanceof Refusal) refuse("invalid_field", {field: "registry_request"})
      throw error
    }
  }
  return map
}

/**
 * The 32 bytes the passkey signs: SHA-256 of the request's JCS bytes for
 * `sign_in` and `confirm`, and of the registry request's with `signer`
 * set to the passkey's kid for `registry`.
 */
export function digest(request, signer) {
  if (request.purpose === "registry") return sha256(utf8(jcs({...request.registry_request, signer})))
  return sha256(utf8(jcs(request)))
}

/**
 * The page's answer from the assertion the passkey made: the request's
 * challenge, the identifier its user handle names, the credential's raw
 * id and the three signed byte fields, and the signer for `registry`.
 */
export function answer(request, {identifier, credentialId, authenticatorData, clientData, signature}, signer) {
  return {
    challenge: request.challenge,
    identifier,
    credential_id: b64(credentialId),
    authenticator_data: b64(authenticatorData),
    client_data: b64(clientData),
    signature: b64(signature),
    ...(request.purpose === "registry" ? {signer} : {})
  }
}

/** The fragment that carries a request or an answer: unpadded base64url of its JCS bytes. */
export function fragment(object) {
  return b64(utf8(jcs(object)))
}

/**
 * The JSON object a fragment carries, its length checked before it is
 * decoded: throws `too_large` past `MAX_FRAGMENT_BYTES`, and
 * `invalid_fragment` for anything that is not unpadded base64url, in its
 * one spelling, of a JSON object's JCS bytes.
 */
export function parseFragment(text) {
  if (typeof text !== "string") refuse("invalid_fragment")
  if (text.length > MAX_FRAGMENT_BYTES || utf8(text).length > MAX_FRAGMENT_BYTES) refuse("too_large")
  try {
    const bytes = fromB64url(text)
    if (b64(bytes) !== text) refuse("invalid_fragment")
    const json = new TextDecoder("utf-8", {fatal: true}).decode(bytes)
    const object = JSON.parse(json)
    if (!isObject(object) || jcs(object) !== json) refuse("invalid_fragment")
    return object
  } catch (_error) {
    return refuse("invalid_fragment")
  }
}
