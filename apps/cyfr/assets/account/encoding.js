// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The encodings every shape the account pages read or write shares, the
// browser's copy of Prima.Identity.Encoding: JCS bytes, unpadded base64url
// in its one spelling, digests, identifiers, origins and directory URLs,
// and exact field sets. A refusal is thrown as a `Refusal` carrying the
// reason and, where the shape names one, the field; each reader catches
// it at its own boundary.

import {b64url, fromB64url} from "./base64url.js"

export class Refusal extends Error {
  constructor(reason, detail = {}) {
    super(detail.field ? `${reason}: ${detail.field}` : reason)
    this.reason = reason
    this.detail = detail
  }

  /** The refusal as the vectors spell it: `{reason}` plus `field` or `kind` when it names one. */
  toJSON() {
    return {reason: this.reason, ...this.detail}
  }
}

export const refuse = (reason, detail) => {
  throw new Refusal(reason, detail)
}
export const invalid = (field) => refuse("invalid_field", {field})

const MAX_INTEGER = Number.MAX_SAFE_INTEGER
const DEFAULT_PORTS = {http: 80, https: 443}
const HOST = /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/
const DIGEST = /^sha256:[0-9a-f]{64}$/
const IDENTIFIER = /^per_[0-9a-f]{64}$/
const PATH = /^(?:\/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)*$/
const ORIGIN = /^(https?):\/\/([^/:?#@]+)(?::(0|[1-9][0-9]{0,4}))?/
const MAX_URL_BYTES = 2048
const MAX_HOME_BYTES = 300

export const utf8 = (text) => new TextEncoder().encode(text)

export const b64 = b64url

/**
 * The bytes unpadded base64url `value` spells when it is `min` to `max`
 * bytes long and that spelling is its one spelling, else null.
 */
export function unb64(value, min, max = min) {
  if (typeof value !== "string") return null
  let bytes
  try {
    bytes = fromB64url(value)
  } catch (_error) {
    return null
  }
  if (bytes.length < min || bytes.length > max || b64url(bytes) !== value) return null
  return bytes
}

export function hex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

export function fromHex(text) {
  return new Uint8Array(text.match(/../g).map((pair) => parseInt(pair, 16)))
}

export async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", typeof bytes === "string" ? utf8(bytes) : bytes))
}

/** `sha256:<hex>` over `bytes`: an entry's hash, a key's kid. */
export async function digestOf(bytes) {
  return "sha256:" + hex(await sha256(bytes))
}

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((size, part) => size + part.length, 0))
  let at = 0
  for (const part of parts) {
    out.set(part, at)
    at += part.length
  }
  return out
}

export const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value)
export const isDigest = (value) => typeof value === "string" && DIGEST.test(value)
export const isIdentifier = (value) => typeof value === "string" && IDENTIFIER.test(value)
export const isHost = (value) => typeof value === "string" && HOST.test(value)
export const isMs = (value) => Number.isSafeInteger(value) && value >= 0 && value <= MAX_INTEGER

/**
 * The JCS (RFC 8785) text of a JSON value: object members sorted by their
 * names' UTF-16 code units, no whitespace. JCS has no null and these
 * protocols no fractional number: either, or anything that is not JSON,
 * is refused as an invalid field named by the top-level member it sits in.
 */
export function jcs(value) {
  return write(value, [])
}

function write(value, path) {
  if (typeof value === "boolean" || typeof value === "string") return JSON.stringify(value)
  if (typeof value === "number" && Number.isSafeInteger(value)) return JSON.stringify(value)
  if (Array.isArray(value)) return "[" + value.map((item) => write(item, path)).join(",") + "]"
  if (isObject(value)) {
    const names = Object.keys(value).sort()
    return "{" + names.map((name) => JSON.stringify(name) + ":" + write(value[name], path.length ? path : [name])).join(",") + "}"
  }
  return invalid(path[0] ?? "")
}

/**
 * Hold `map` to exactly `required` and `optional` fields: an unknown field
 * first, in sorted order, then a missing one, in `required`'s order.
 */
export function fields(map, required, optional = []) {
  const allowed = new Set([...required, ...optional])
  const unknown = Object.keys(map).sort().find((name) => !allowed.has(name))
  if (unknown !== undefined) refuse("unknown_field", {field: unknown})
  const missing = required.find((name) => !Object.hasOwn(map, name))
  if (missing !== undefined) refuse("missing_field", {field: missing})
}

/** `map[field]` when `valid` holds of it, else an invalid field. */
export function check(map, field, valid) {
  return valid(map[field]) ? map[field] : invalid(field)
}

/** A base64url field of `min` to `max` bytes, else an invalid field. */
export function binary(map, field, min, max = min) {
  return unb64(map[field], min, max) ?? invalid(field)
}

/** The protocol field: absent is missing, any other value is `wrong_protocol`. */
export function protocol(map, expected) {
  if (!Object.hasOwn(map, "protocol")) refuse("missing_field", {field: "protocol"})
  if (map.protocol !== expected) refuse("wrong_protocol")
}

/**
 * A URL's origin, host and the rest after them, or null when it does not
 * start with an http or https origin in its one spelling.
 */
function splitOrigin(value) {
  const match = ORIGIN.exec(value)
  if (!match || !HOST.test(match[2])) return null
  const [whole, scheme, host, port] = match
  if (port !== undefined && (Number(port) > 65535 || Number(port) === DEFAULT_PORTS[scheme])) return null
  return {origin: whole, host, rest: value.slice(whole.length)}
}

/** Whether `value` names a home (a CYFR's origin) in its one spelling. */
export function isHome(value) {
  if (typeof value !== "string" || utf8(value).length > MAX_HOME_BYTES) return false
  const split = splitOrigin(value)
  return split !== null && split.rest === ""
}

/**
 * Whether `value` is a directory URL, or a return URL: a home's origin and
 * an optional path of `/`-separated segments with no trailing `/`, no
 * user, query or fragment, at most 2048 bytes.
 */
export function isDirectoryUrl(value) {
  if (typeof value !== "string" || utf8(value).length > MAX_URL_BYTES) return false
  const split = splitOrigin(value)
  return split !== null && PATH.test(split.rest) && !/%(?![0-9A-Fa-f]{2})/.test(split.rest)
}

/** A directory URL's origin, which serves its pages, and host, its passkeys' relying party. */
export function directoryOrigin(url) {
  const {origin, host} = splitOrigin(url)
  return {origin, host}
}
