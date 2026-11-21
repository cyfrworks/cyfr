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
  locked: {required: []},
  "pick-folder": {required: ["id", "suggested"]},
  "home-ready": {required: ["home"]},
  lock: {required: []},
  shutdown: {required: []},
  "folder-picked": {required: ["id", "path"]}
}

const FROM_CYFR = ["ready", "home", "opened", "locked", "pick-folder"]
const FROM_MAIN = ["home-ready", "lock", "shutdown", "folder-picked"]

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

/**
 * The CYFR main keeps to. cyfr proposes one with home, and holds it as
 * selected only once it has committed it, which opened says: until then
 * a lock (`cancel`) or a failure leaves main able to take cyfr's next
 * proposal, for the same CYFR or another. Once one is selected, another
 * proposal is not a message cyfr sends.
 */
export function selection() {
  const s = {home: "", account: "", selected: false}
  return {
    get home() { return s.home },
    get account() { return s.account },
    get selected() { return s.selected },
    /** Take home's proposal; false once a CYFR is selected. */
    propose(m) {
      if (s.selected) return false
      s.home = m.home
      s.account = m.account
      return true
    },
    /** cyfr committed `home`; false unless it is the one proposed. */
    opened(home) {
      if (s.selected || !s.home || home !== s.home) return false
      s.selected = true
      return true
    },
    /** A lock ends a proposal cyfr has not committed. */
    cancel() {
      if (!s.selected) s.home = s.account = ""
    }
  }
}
