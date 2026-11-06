// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The registry's side of the account pages, held to
// tests/fixtures/registry_wire.json: the signed request that carries an
// operation (`cyfr-registry-request/v2`, Prima.RegistryRequest), the
// answer for one handle (`cyfr-handle/v1`, Prima.HandleAnswer) and the
// error envelope a refusal comes in. At an account's birth the page signs
// `policy.accept` and `handle.claim` with the recovery key; a CYFR hands a
// passkey a request to sign (`readToSign`) through /account/sign.

import {Refusal, b64, binary, check, fields, isHost, isIdentifier, isDirectoryUrl, isMs, isObject, jcs, utf8} from "./encoding.js"

export const PROTOCOL = "cyfr-registry-request/v2"
export const HANDLE_PROTOCOL = "cyfr-handle/v1"
export const MAX_BYTES = 16384
export const NONCE_BYTES = 16
export const LIFETIME_MS = 120000

/** The route the registry takes each operation at. */
export const ROUTES = {
  "handle.claim": "/v1/namespaces/personal/claim",
  "policy.accept": "/v1/legal/accept"
}

const ENVELOPE = ["protocol", "registry", "operation", "identifier", "nonce", "expires_at", "body"]
const PERSONAL = /^[a-z0-9]+(-[a-z0-9]+)*$/
const PUBLISHER_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/
const LABEL = /^[\x20-\x7E]{1,64}$/
const BLANK = /^[ \t\r\n]*$/

// Text as Prima's text fields hold it: non-empty, at most `max` UTF-8
// bytes, no control character.
const control = (value) => Array.from(value).some((char) => char.charCodeAt(0) < 0x20 || char.charCodeAt(0) === 0x7f)
const text = (max) => (value) => typeof value === "string" && value !== "" && utf8(value).length <= max && !control(value)
const slug = (value) =>
  typeof value === "string" && value.includes(".") && value.length <= 253 && value.split(".").every((label) => PUBLISHER_LABEL.test(label))

// Each operation's body keys, each value checked by its key.
const BODIES = {
  "handle.claim": ["handle"],
  "tokens.mint": ["label"],
  "policy.accept": ["policy_version"],
  "appeal.file": ["action_type", "action_ref", "argument"],
  "publisher.claim": ["slug"],
  "publisher.verify": ["slug", "label"]
}
const VALID = {
  handle: (value) => isHandle(value),
  label: (value) => typeof value === "string" && LABEL.test(value),
  policy_version: text(128),
  action_type: (value) => value === "takedown" || value === "ban",
  action_ref: text(256),
  argument: (value) => typeof value === "string" && utf8(value).length <= 4000 && !BLANK.test(value),
  slug
}

/** Every refusal the registry writes: CYFR's name by the registry's code. */
export const REFUSALS = {
  REQUEST_MALFORMED: "request_malformed",
  WRONG_PROTOCOL: "wrong_protocol",
  WRONG_REGISTRY: "wrong_registry",
  UNKNOWN_OPERATION: "unknown_operation",
  REQUEST_EXPIRED: "expired",
  EXPIRY_TOO_FAR: "expiry_too_far",
  UNKNOWN_IDENTITY: "unknown_identity",
  DIRECTORY_UNAVAILABLE: "directory_unavailable",
  WRONG_DIRECTORY: "wrong_directory",
  BAD_SIGNATURE: "bad_signature",
  REPLAYED: "replayed",
  IDENTITY_BANNED: "banned",
  NOT_APPELLANT_OF_RECORD: "not_appellant",
  ACTION_NOT_FOUND: "action_not_found",
  APPEAL_TOO_EARLY: "appeal_too_early",
  NAMESPACE_UNOWNED: "namespace_unowned",
  SLUG_TAKEN: "handle_taken",
  ALREADY_CLAIMED: "has_other_handle",
  INVALID_USERNAME: "handle_invalid",
  RESERVED: "handle_reserved",
  NAMESPACE_RESERVED: "namespace_reserved",
  CLAIM_NOT_PENDING: "claim_not_pending",
  DNS_UNVERIFIED: "dns_unverified",
  DNS_TIMEOUT: "dns_timeout",
  POLICY_ACCEPTANCE_REQUIRED: "policy_required",
  RATE_LIMITED: "rate_limited",
  HANDLE_NOT_FOUND: "handle_not_found"
}

/** Whether `value` is a name a person can claim: 1 to 39 of `a-z`, `0-9` and single inner hyphens. */
export function isHandle(value) {
  return typeof value === "string" && value.length <= 39 && PERSONAL.test(value)
}

/**
 * Read the request a CYFR hands a passkey to sign: every field but
 * `signer` and `sig`, a known operation and exactly its body. Throws a
 * `Refusal` for anything else.
 */
export function readToSign(map) {
  if (!isObject(map)) throw new Refusal("request_malformed")
  fields(map, ENVELOPE)
  jcs(map)
  check(map, "protocol", (value) => typeof value === "string")
  check(map, "registry", isHost)
  check(map, "operation", (value) => typeof value === "string")
  check(map, "identifier", isIdentifier)
  binary(map, "nonce", NONCE_BYTES)
  check(map, "expires_at", isMs)
  check(map, "body", isObject)
  if (map.protocol !== PROTOCOL) throw new Refusal("wrong_protocol")
  const keys = BODIES[map.operation]
  if (!keys) throw new Refusal("unknown_operation")
  fields(map.body, keys)
  for (const key of keys) check(map.body, key, VALID[key])
  return map
}

/** A request to sign, unsigned, from its fields; `nonce` as its 16 bytes. */
export function compose({registry, operation, identifier, signer, nonce, now, body}) {
  return {
    protocol: PROTOCOL,
    registry,
    operation,
    identifier,
    signer,
    nonce: b64(nonce),
    expires_at: now + LIFETIME_MS,
    body
  }
}

/** The bytes a request's signer signs: its JCS form without `sig`. */
export function signingBytes(request) {
  const {sig: _sig, ...unsigned} = request
  return utf8(jcs(unsigned))
}

/**
 * A request signed by an Ed25519 key (`ed25519Key`): the bytes sent, its
 * JCS form with `sig`. Throws `request_malformed` past `MAX_BYTES`, as the
 * registry would refuse it.
 */
export async function signWith(request, key) {
  const signed = {...request, sig: b64(await key.sign(signingBytes(request)))}
  return sent(signed)
}

/** The bytes of a request carrying its signer's passkey assertion as `sig`, bounded as `signWith`'s. */
export function sent(signed) {
  const bytes = jcs(signed)
  if (utf8(bytes).length > MAX_BYTES) throw new Refusal("request_malformed")
  return bytes
}

/**
 * The refusal an error envelope names, or "malformed_answer": its first
 * error carries a code of the table and a string message, and it holds no
 * null.
 */
export function refusal(bytes) {
  const envelope = parse(bytes)
  const first = isObject(envelope) && Array.isArray(envelope.errors) ? envelope.errors[0] : null
  if (!isObject(first) || !Object.hasOwn(REFUSALS, first.code) || typeof first.message !== "string") return "malformed_answer"
  try {
    jcs(envelope)
  } catch (_error) {
    return "malformed_answer"
  }
  return REFUSALS[first.code]
}

/**
 * Read the registry's answer for `handle` asked of `registry` (its host):
 * `{answer: {registry, handle, identifier, directory}}`, or `{error}`, the
 * envelope's refusal or "malformed_answer".
 */
export function handleAnswer(bytes, handle, registry) {
  const answer = parse(bytes)
  if (isObject(answer) && Object.hasOwn(answer, "errors")) return {error: refusal(bytes)}
  try {
    if (!isObject(answer)) throw new Refusal("malformed_answer")
    fields(answer, ["protocol", "registry", "handle", "identifier", "directory"])
    const ok =
      answer.protocol === HANDLE_PROTOCOL &&
      answer.registry === registry &&
      answer.handle === handle &&
      isHost(registry) &&
      isHandle(handle) &&
      isIdentifier(answer.identifier) &&
      isDirectoryUrl(answer.directory)
    if (!ok) throw new Refusal("malformed_answer")
  } catch (error) {
    if (error instanceof Refusal) return {error: "malformed_answer"}
    throw error
  }
  const {protocol: _protocol, ...result} = answer
  return {answer: result}
}

function parse(bytes) {
  try {
    return JSON.parse(bytes)
  } catch (_error) {
    return null
  }
}
