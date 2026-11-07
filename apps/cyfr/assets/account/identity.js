// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// An account's log in the browser, `cyfr-identity/v2`: Prima.Identity's
// composition, hashing and walk, held to tests/fixtures/identity.json. The
// pages compose and sign the entries they append, and walk the log they
// read to the state they act on (the head and seq a next entry names, the
// keys and recovery set it may name), so they never act on a log that
// does not verify from its genesis. Which signer each kind takes, and
// every refusal, are the Elixir module's.

import {
  Refusal,
  b64,
  binary,
  check,
  digestOf,
  directoryOrigin,
  fields,
  fromHex,
  hex,
  invalid,
  isDigest,
  isDirectoryUrl,
  isIdentifier,
  isMs,
  isObject,
  jcs,
  protocol,
  refuse,
  sha256,
  unb64,
  utf8
} from "./encoding.js"
import {verifyAssertion} from "./webauthn.js"

export const PROTOCOL = "cyfr-identity/v2"
export const MAX_ENTRY_BYTES = 16384
export const MAX_RECOVERY = 8
export const MAX_KEYS = 64
export const KINDS = ["genesis", "add_key", "remove_key", "recover", "add_recovery"]

const KEY_BYTES = 32
const SIGNATURE_BYTES = 64
const POINT_BYTES = 65
const MAX_CREDENTIAL_ID_BYTES = 1023
const MAX_ASSERTION_BYTES = 16384
const SIGNER = /^(?:recovery:)?sha256:[0-9a-f]{64}$/
const COMMON = ["protocol", "kind", "seq", "at", "signer"]
const KIND_FIELDS = {
  genesis: ["directory", "recovery"],
  add_key: ["prev", "key"],
  remove_key: ["prev", "kid"],
  recover: ["prev", "keys", "recovery"],
  add_recovery: ["prev", "recovery"]
}

// An Ed25519 private key as WebCrypto imports it: the PKCS #8 prefix of
// RFC 8410 before the 32-byte seed.
const PKCS8_ED25519 = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]

/** A key's kid: `sha256:<hex>` over its public bytes. */
export const kid = (pub) => digestOf(pub)

/** The signer a recovery public key signs as. */
export const recoverySigner = async (pub) => "recovery:" + (await kid(pub))

/**
 * The Ed25519 key a 32-byte seed is (a recovery code's secret, or a
 * device's seed): `{pub, sign}`, `sign` resolving to the 64-byte
 * signature of the bytes it is given. Null for a seed of another size.
 */
export async function ed25519Key(seed) {
  if (!(seed instanceof Uint8Array) || seed.length !== KEY_BYTES) return null
  const pkcs8 = new Uint8Array([...PKCS8_ED25519, ...seed])
  const exported = await crypto.subtle.importKey("pkcs8", pkcs8, {name: "Ed25519"}, true, ["sign"])
  const pub = unb64((await crypto.subtle.exportKey("jwk", exported)).x, KEY_BYTES)
  const key = await crypto.subtle.importKey("pkcs8", pkcs8, {name: "Ed25519"}, false, ["sign"])
  pkcs8.fill(0)
  return {pub, sign: async (bytes) => new Uint8Array(await crypto.subtle.sign("Ed25519", key, bytes))}
}

/** The identifier's 32 digest bytes, a passkey's WebAuthn `user.id`, or null. */
export function userId(identifier) {
  return isIdentifier(identifier) ? fromHex(identifier.slice(4)) : null
}

/** The identifier a passkey's user handle names, or null. */
export function identifierForUserId(bytes) {
  return bytes instanceof Uint8Array && bytes.length === 32 ? "per_" + hex(bytes) : null
}

/** A listed key's JSON map from its public bytes: a device's Ed25519 key, or a passkey's point and credential id. */
export async function keyOf({pub, credentialId}) {
  return credentialId
    ? {kid: await kid(pub), alg: "es256", kind: "passkey", pub: b64(pub), credential_id: b64(credentialId)}
    : {kid: await kid(pub), alg: "ed25519", kind: "device", pub: b64(pub)}
}

/** The genesis an account begins with, unsigned: signed by its first recovery key. */
export function genesis({directory, recovery, at, signer}) {
  return {protocol: PROTOCOL, kind: "genesis", seq: 0, at, signer, directory, recovery}
}

/** The entry after `state`'s head, unsigned: `kind` with its own fields. */
export function next(state, kind, own, {at, signer}) {
  return {protocol: PROTOCOL, kind, prev: state.head, seq: state.seq + 1, at, signer, ...own}
}

/** The bytes an entry's signer signs: its JCS form without `sig`. */
export function signingBytes(entry) {
  const {sig: _sig, ...unsigned} = entry
  return utf8(jcs(unsigned))
}

/** A passkey's WebAuthn challenge for an entry: SHA-256 of its signing bytes. */
export const challenge = (entry) => sha256(signingBytes(entry))

/** The entry signed by an Ed25519 key (`ed25519Key`). */
export async function signWith(entry, key) {
  return {...entry, sig: b64(await key.sign(signingBytes(entry)))}
}

/** The entry with a passkey's assertion over `challenge(entry)` as its `sig`. */
export function attach(entry, assertion) {
  return {...entry, sig: assertionJSON(assertion)}
}

/** An assertion's three byte fields as unpadded base64url. */
export function assertionJSON({authenticator_data, client_data, signature}) {
  return {authenticator_data: b64(authenticator_data), client_data: b64(client_data), signature: b64(signature)}
}

/** An entry's hash, `sha256:<hex>` over its JCS bytes. */
export const hash = (entry) => digestOf(utf8(jcs(entry)))

/** The identifier a genesis hashes to. */
export async function identifier(genesisEntry) {
  return "per_" + hex(await sha256(utf8(jcs(genesisEntry))))
}

/**
 * Walk a log from its genesis. Resolves to `{state}`, the state its head
 * reaches, or `{error: {index, reason}}` naming the first entry refused,
 * with the field or kind the refusal names.
 */
export async function walk(entries) {
  if (!Array.isArray(entries) || entries.length === 0) return {error: {index: 0, reason: "empty"}}
  let state
  for (const [index, entry] of entries.entries()) {
    try {
      state = index === 0 ? await begin(entry) : await extend(state, entry)
    } catch (error) {
      if (error instanceof Refusal) return {error: {index, ...error.toJSON()}}
      throw error
    }
  }
  return {state}
}

/** One more entry on a walked state: throws its `Refusal`. */
export async function extend(state, map) {
  const entry = await read(map)
  if (entry.kind === "genesis") refuse("unexpected_genesis")
  if (map.prev !== state.head || map.seq !== state.seq + 1) refuse("broken_link")
  await authorized(map, state)
  await signed(entry, await signerKey(map.signer, state), state.directory)
  const after = await applied(map, state)
  return {...after, head: await hash(map), seq: map.seq}
}

async function begin(map) {
  const entry = await read(map)
  if (entry.kind !== "genesis") refuse("not_genesis")
  const pub = await listedRecovery(map.recovery, map.signer)
  await signed(entry, pub && {recovery: pub}, map.directory)
  return {
    identifier: await identifier(map),
    directory: map.directory,
    head: await hash(map),
    seq: 0,
    keys: [],
    recovery: map.recovery
  }
}

// A code alone recovers or adds a code, and a key never removes itself.
async function authorized(map, state) {
  const {kind, signer} = map
  if (signer.startsWith("recovery:")) {
    if (await listedRecovery(state.recovery, signer)) return
  } else if (kind === "add_key" || (kind === "remove_key" && signer !== map.kid)) {
    if (listed(state, signer)) return
  }
  refuse("wrong_signer")
}

const listed = (state, kidValue) => state.keys.find((key) => key.kid === kidValue)

async function listedRecovery(recovery, signer) {
  for (const pub of recovery) if ((await recoverySigner(unb64(pub, KEY_BYTES))) === signer) return unb64(pub, KEY_BYTES)
  return null
}

async function signerKey(signer, state) {
  if (signer.startsWith("recovery:")) {
    const pub = await listedRecovery(state.recovery, signer)
    return pub && {recovery: pub}
  }
  const key = listed(state, signer)
  return key && {key}
}

async function signed(entry, signer, directory) {
  const sig = entry.sig
  let ok = false
  if (signer?.recovery && sig instanceof Uint8Array) ok = await ed25519(entry.map, sig, signer.recovery)
  else if (signer?.key?.alg === "ed25519" && sig instanceof Uint8Array) ok = await ed25519(entry.map, sig, unb64(signer.key.pub, KEY_BYTES))
  else if (signer?.key?.alg === "es256" && sig && !(sig instanceof Uint8Array)) {
    const {origin, host} = directoryOrigin(directory)
    ok = (await verifyAssertion(sig, unb64(signer.key.pub, POINT_BYTES), await challenge(entry.map), origin, host)) === "ok"
  }
  if (!ok) refuse("wrong_signer")
}

async function ed25519(map, sig, pub) {
  try {
    const key = await crypto.subtle.importKey("raw", pub, {name: "Ed25519"}, false, ["verify"])
    return await crypto.subtle.verify("Ed25519", key, sig, signingBytes(map))
  } catch (_error) {
    return false
  }
}

async function applied(map, state) {
  switch (map.kind) {
    case "add_key":
      if (listed(state, map.key.kid)) refuse("duplicate_key")
      return {...state, keys: [...state.keys, map.key]}
    case "remove_key":
      if (!listed(state, map.kid)) invalid("kid")
      return {...state, keys: state.keys.filter((key) => key.kid !== map.kid)}
    case "recover":
      if (new Set(map.keys.map((key) => key.kid)).size !== map.keys.length) refuse("duplicate_key")
      return {...state, keys: map.keys, recovery: map.recovery}
    case "add_recovery": {
      const after = new Set(map.recovery)
      if (!state.recovery.every((pub) => after.has(pub)) || map.recovery.length <= state.recovery.length) invalid("recovery")
      return {...state, recovery: map.recovery}
    }
  }
}

// Read a signed entry's map in Prima.Identity.Entry's order: size,
// protocol, kind, exact fields, then each field. Resolves to the map and
// its decoded signature (the Ed25519 bytes, or an assertion's bytes).
async function read(map) {
  if (!isObject(map)) invalid("entry")
  if (utf8(jcs(map)).length > MAX_ENTRY_BYTES) refuse("too_large")
  protocol(map, PROTOCOL)
  if (!Object.hasOwn(map, "kind")) refuse("missing_field", {field: "kind"})
  if (!KINDS.includes(map.kind)) refuse("unknown_kind", {kind: map.kind})
  const kind = map.kind
  fields(map, [...COMMON, ...KIND_FIELDS[kind], "sig"])
  check(map, "seq", kind === "genesis" ? (seq) => seq === 0 : isMs)
  check(map, "at", isMs)
  check(map, "signer", (signer) => typeof signer === "string" && SIGNER.test(signer))
  if (kind !== "genesis") check(map, "prev", isDigest)

  if (kind === "genesis") {
    check(map, "directory", isDirectoryUrl)
    recovery(map)
  } else if (kind === "add_key") {
    if (!(await decodeKey(map.key))) invalid("key")
  } else if (kind === "remove_key") {
    check(map, "kid", isDigest)
  } else if (kind === "recover") {
    await keys(map)
    recovery(map)
  } else {
    recovery(map)
  }
  return {map, kind, sig: signature(map.sig)}
}

function recovery(map) {
  const list = map.recovery
  if (!Array.isArray(list) || list.length === 0 || list.length > MAX_RECOVERY) invalid("recovery")
  if (list.some((pub) => !unb64(pub, KEY_BYTES)) || new Set(list).size !== list.length) invalid("recovery")
}

async function keys(map) {
  const list = map.keys
  if (!Array.isArray(list) || list.length > MAX_KEYS) invalid("keys")
  for (const key of list) if (!(await decodeKey(key))) invalid("keys")
}

/** Whether `map` is a key in one of its two shapes, its kid its public key's. */
export async function decodeKey(map) {
  if (!isObject(map)) return false
  try {
    if (map.alg === "ed25519" && map.kind === "device") {
      fields(map, ["kid", "alg", "kind", "pub"])
      const pub = unb64(map.pub, KEY_BYTES)
      return pub !== null && map.kid === (await kid(pub))
    }
    if (map.alg === "es256" && map.kind === "passkey") {
      fields(map, ["kid", "alg", "kind", "pub", "credential_id"])
      const pub = unb64(map.pub, POINT_BYTES)
      return pub !== null && pub[0] === 4 && unb64(map.credential_id, 1, MAX_CREDENTIAL_ID_BYTES) !== null && map.kid === (await kid(pub))
    }
  } catch (error) {
    if (error instanceof Refusal) return false
    throw error
  }
  return false
}

function signature(sig) {
  if (typeof sig === "string") return unb64(sig, SIGNATURE_BYTES) ?? invalid("sig")
  if (!isObject(sig)) invalid("sig")
  try {
    fields(sig, ["authenticator_data", "client_data", "signature"])
    return {
      authenticator_data: binary(sig, "authenticator_data", 1, MAX_ASSERTION_BYTES),
      client_data: binary(sig, "client_data", 1, MAX_ASSERTION_BYTES),
      signature: binary(sig, "signature", 1, MAX_ASSERTION_BYTES)
    }
  } catch (error) {
    if (error instanceof Refusal) invalid("sig")
    throw error
  }
}
