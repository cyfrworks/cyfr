// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

/**
 * The JCS (RFC 8785) text of a JSON value: object members sorted by their
 * names' UTF-16 code units, no whitespace, numbers and strings as
 * ECMAScript writes them. Integers are all a challenge carries.
 */
export function jcs(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") return JSON.stringify(value)
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("not a JSON number")
    return JSON.stringify(value)
  }
  if (Array.isArray(value)) return "[" + value.map(jcs).join(",") + "]"
  if (typeof value === "object") {
    const names = Object.keys(value).filter((name) => value[name] !== undefined).sort()
    return "{" + names.map((name) => JSON.stringify(name) + ":" + jcs(value[name])).join(",") + "}"
  }
  throw new TypeError("not a JSON value")
}
