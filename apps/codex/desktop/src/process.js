// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The private messages between this main process and the cyfr it starts
// (tests/fixtures/desktop-process.json): one JSON object a line, each with
// version 2, its type and exactly its type's fields: text, but for attempt,
// the proposal's number, and id, a departure's or an erase's, whole ones
// from 1, erased's ok, true or false, erase's home and account, each an
// origin in its one spelling,
// folder-picked's path, a
// folder spelled from a root (absolute) or null, and its epoch and pick,
// whole numbers from 0, the chooser's own as it asked for the pick.

export const VERSION = 2

export const MAX_LINE = 64 * 1024

// The header of the chooser's requests that carries the run token, which
// main adds to those of the chooser's own top document alone (app.js
// runHeader) and cyfr reads nowhere else (internal/desktop RunHeader).
export const RUN_HEADER = "Cyfr-Run"

const FIELDS = {
  ready: {required: ["url"], optional: ["rail"]},
  home: {required: ["home", "account", "attempt"], optional: ["proxy", "setup"]},
  opened: {required: ["home", "attempt"]},
  locked: {required: [], optional: ["home", "account", "proxy"], together: ["home", "account"]},
  ending: {required: []},
  left: {required: ["id"]},
  erase: {required: ["id", "home"], optional: ["account"]},
  "home-ready": {required: ["home", "attempt"]},
  lock: {required: []},
  leave: {required: ["id"]},
  shutdown: {required: []},
  "folder-picked": {required: ["path", "epoch", "pick"]},
  forget: {required: ["home"]},
  erased: {required: ["id", "ok"]}
}

const FROM_CYFR = ["ready", "home", "opened", "locked", "ending", "left", "erase"]
const FROM_MAIN = ["home-ready", "lock", "leave", "shutdown", "folder-picked", "forget", "erased"]

/**
 * Whether `path` is a folder spelled from a root on any system the app
 * runs on: /, a drive's letter, colon and separator, or a share's two
 * backslashes (process.go absolute).
 */
export const absolute = (path) => typeof path === "string" && /^(\/|\\\\|[A-Za-z]:[\\/])/.test(path)

export class Refused extends Error {
  constructor(reason) {
    super(`not a message from cyfr: ${reason}`)
    this.reason = reason
  }
}

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v)

/** Whether `v` is an origin in its one spelling, as URL writes it. */
export function isOrigin(v) {
  if (typeof v !== "string") return false
  try {
    return new URL(v).origin === v
  } catch {
    return false
  }
}
// The fields that are a number, a whole one from 1.
const whole = (key) => key === "attempt" || key === "id"

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
    const valid = whole(key) ? Number.isSafeInteger(m[key]) && m[key] > 0 : typeof m[key] === "string" && m[key] !== ""
    if (!valid) throw new Refused("fields")
  }
  // Fields that come together or not at all, and a route only beside them.
  const {together = []} = FIELDS[m.type]
  const named = together.filter((k) => Object.hasOwn(m, k)).length
  if (named !== 0 && named !== together.length) throw new Refused("fields")
  if (together.length && named === 0 && Object.hasOwn(m, "proxy")) throw new Refused("fields")
  // A setup token in its one form, which the CYFR's setup page reads.
  if (Object.hasOwn(m, "setup") && !/^[0-9a-f]{64}$/.test(m.setup)) throw new Refused("fields")
  // What an erase names is erased by its origin: nothing else is one.
  if (m.type === "erase" && ![m.home, m.account ?? m.home].every(isOrigin)) throw new Refused("fields")
  return m
}

/** One line of a message main sends cyfr. */
export function toCyfr(type, fields = {}) {
  if (!FROM_MAIN.includes(type)) throw new Error(`main does not send ${type}`)
  const {required} = FIELDS[type]
  const m = {version: VERSION, type}
  for (const key of required) {
    if (!Object.hasOwn(fields, key)) throw new Error(`${type} needs ${key}`)
    if (key === "path" && fields.path !== null && !absolute(fields.path)) throw new Error(`${type} names no absolute folder`)
    if ((key === "epoch" || key === "pick") && !(Number.isSafeInteger(fields[key]) && fields[key] >= 0)) throw new Error(`${type} needs ${key} as a whole number`)
    if (whole(key) && !(Number.isSafeInteger(fields[key]) && fields[key] > 0)) throw new Error(`${type} needs ${key} as a whole number from 1`)
    if (key === "ok" && typeof fields.ok !== "boolean") throw new Error(`${type} needs ok as true or false`)
    if (type === "forget" && key === "home" && !isOrigin(fields.home)) throw new Error(`forget needs home as an origin`)
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

