// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The private messages between this main process and the cyfr it starts
// (tests/fixtures/desktop-process.json): one JSON object a line, each with
// version 1, its type and exactly its type's fields.

export const VERSION = 1

export const MAX_LINE = 64 * 1024

const FIELDS = {
  ready: {required: ["url"]},
  home: {required: ["home", "account"], optional: ["proxy", "resolver"]},
  opened: {required: ["home"]},
  locked: {required: [], optional: ["home", "account", "proxy", "resolver"], together: ["home", "account"]},
  "pick-folder": {required: ["id", "suggested"]},
  "home-ready": {required: ["home"]},
  lock: {required: []},
  leave: {required: []},
  shutdown: {required: []},
  "folder-picked": {required: ["id", "path"]}
}

const FROM_CYFR = ["ready", "home", "opened", "locked", "pick-folder"]
const FROM_MAIN = ["home-ready", "lock", "leave", "shutdown", "folder-picked"]

export class Refused extends Error {
  constructor(reason) {
    super(`not a message from cyfr: ${reason}`)
    this.reason = reason
  }
}

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v)

/** Read one line cyfr sent, or throw `Refused` with its reason. */
export function readFromCyfr(line) {
  if (typeof line !== "string" || line.length > MAX_LINE) throw new Refused("size")
  let m
  try {
    m = JSON.parse(line)
  } catch {
    throw new Refused("shape")
  }
  if (!isObject(m)) throw new Refused("shape")
  if (!Object.hasOwn(m, "version") || m.version !== VERSION) throw new Refused("version")
  if (!FROM_CYFR.includes(m.type)) throw new Refused("type")
  const {required, optional = []} = FIELDS[m.type]
  for (const key of Object.keys(m)) {
    if (!["version", "type", ...required, ...optional].includes(key)) throw new Refused("fields")
  }
  for (const key of [...required, ...optional.filter((k) => Object.hasOwn(m, k))]) {
    if (typeof m[key] !== "string" || m[key] === "") throw new Refused("fields")
  }
  // Fields that come together or not at all, and a route only beside them.
  const {together = []} = FIELDS[m.type]
  const named = together.filter((k) => Object.hasOwn(m, k)).length
  if (named !== 0 && named !== together.length) throw new Refused("fields")
  if (together.length && named === 0 && (Object.hasOwn(m, "proxy") || Object.hasOwn(m, "resolver"))) throw new Refused("fields")
  return m
}

/** One line of a message main sends cyfr. */
export function toCyfr(type, fields = {}) {
  if (!FROM_MAIN.includes(type)) throw new Error(`main does not send ${type}`)
  const {required} = FIELDS[type]
  const m = {version: VERSION, type}
  for (const key of required) {
    if (!Object.hasOwn(fields, key)) throw new Error(`${type} needs ${key}`)
    m[key] = fields[key]
  }
  return JSON.stringify(m) + "\n"
}

/**
 * Lines as they arrive on a stream: `feed` takes each chunk and calls
 * `line` for every whole line; a line past MAX_LINE is refused.
 */
export function lines(line) {
  let held = ""
  return (chunk) => {
    held += chunk
    let at
    while ((at = held.indexOf("\n")) >= 0) {
      const one = held.slice(0, at)
      held = held.slice(at + 1)
      line(one)
    }
    if (held.length > MAX_LINE) throw new Refused("size")
  }
}

