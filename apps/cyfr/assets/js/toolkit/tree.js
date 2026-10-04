// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The tree a canvas's module answers, toolkit major 1: this module is the
// grammar's one definition. A node is `{"type": <element>, …its fields}`, the
// root is any single node, and an unknown element, field or value refuses
// the whole tree. A valid tree is answered normalized, every optional field
// written with its default, so the renderers read no absent field.
//
// No field carries CSS, a class, markup or a URL of its own choosing: an
// image's path is resolved under the version's served prefix, and a
// control's effect names a tincture or a feed's action, never a label.

import {ELEMENTS} from "./elements.js"
import {codePoints, isName, isPlainObject, isText, isTinctureRef} from "./wire.js"

export const MAX_NODES = 2000
export const MAX_DEPTH = 24
export const MAX_BYTES = 1048576

export const TONES = Object.freeze(["plain", "muted", "accent", "good", "warn", "bad"])
export const SIZES = Object.freeze(["s", "m", "l", "xl"])
export const GAPS = Object.freeze(["none", "s", "m", "l"])
export const DIRECTIONS = Object.freeze(["row", "column"])
export const WEIGHTS = Object.freeze(["normal", "strong"])
export const TIME_FORMATS = Object.freeze(["relative", "date", "datetime"])
export const CHART_KINDS = Object.freeze(["line", "bar", "candle"])

const MAX_TEXT = 4096
const MAX_LIST_ITEMS = 500
const MAX_COLUMNS = 16
const MAX_COLUMN_KEY = 64
const MAX_COLUMN_TITLE = 256
const MAX_ROWS = 500
const MAX_ROW_KEYS = 64
const MAX_CELL = 1024
const MAX_SERIES = 8
const MAX_SERIES_NAME = 128
const MAX_POINTS = 2000
const MAX_X_TEXT = 64
const MAX_PATH = 1024
const MAX_DATA_URL = 262144
const MAX_ALT = 256
const MAX_GRID_COLUMNS = 12
const MAX_DIGITS = 8
const MAX_SURFACE_SIDE = 4096

const NUMBER_FORMAT = /^(plain|percent|compact|currency:[A-Z]{3})$/
const PATH_SEGMENT = /^[A-Za-z0-9._~-]+$/
const DATA_URL = /^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]*={0,2}$/

// `Prima.Canvas.Shape`'s `time`: what `DateTime.from_iso8601/1` accepts, an
// offset included.
const TIME = /^([+-]?)(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?(Z|[+-]\d{2}(?::\d{2}|\d{2})?)$/

// The fields of each element: `required` ones, and optional ones with their
// defaults. Each element's values are read by its reader below.
const RULES = {
  stack: {required: ["children"], optional: {direction: "column", gap: "m"}},
  grid: {required: ["columns", "children"], optional: {gap: "m"}},
  text: {required: ["value"], optional: {tone: "plain", size: "m", weight: "normal"}},
  number: {required: ["value"], optional: {format: "plain", digits: null, tone: "plain", size: "m"}},
  time: {required: ["value"], optional: {format: "datetime"}},
  list: {required: ["items"], optional: {}},
  table: {required: ["columns", "rows"], optional: {}},
  chart: {required: ["kind", "series"], optional: {}},
  image: {required: ["src", "alt"], optional: {}},
  control: {required: ["effect"], optional: {tone: "plain", size: "m"}},
  surface: {required: ["id", "width", "height"], optional: {}},
  spacer: {required: [], optional: {}}
}

// The element names the grammar defines, for the test that holds them to
// the renderers' `ELEMENTS`.
export const GRAMMAR_ELEMENTS = Object.freeze(Object.keys(RULES))

class Refusal {
  constructor(path, reason) {
    this.path = path
    this.reason = reason
  }
}

const refuse = (path, reason) => {
  throw new Refusal(path, reason)
}

const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key)

const pointer = (path, key) => path + "/" + String(key).replace(/~/g, "~0").replace(/\//g, "~1")

// A tree the module answered as JSON text: `{ok: true, tree, surfaces}`,
// the normalized tree and the ids of its surfaces in order, or `{ok:
// false, error: {path, reason}}` for the first refusal, `path` an RFC 6901
// pointer into the tree.
export function parseTree(json) {
  if (typeof json !== "string") return {ok: false, error: {path: "", reason: "json"}}
  if (json.length > MAX_BYTES || utf8Length(json) > MAX_BYTES) {
    return {ok: false, error: {path: "", reason: "size"}}
  }

  let value
  try {
    value = JSON.parse(json)
  } catch (_error) {
    return {ok: false, error: {path: "", reason: "json"}}
  }
  return validateTree(value)
}

export function validateTree(value) {
  const state = {nodes: 0, surfaces: []}
  try {
    const tree = node(value, "", 1, state)
    return {ok: true, tree, surfaces: state.surfaces}
  } catch (error) {
    if (error instanceof Refusal) return {ok: false, error: {path: error.path, reason: error.reason}}
    throw error
  }
}

function node(value, path, depth, state) {
  if (depth > MAX_DEPTH) refuse(path, "depth")
  state.nodes += 1
  if (state.nodes > MAX_NODES) refuse(path, "nodes")
  if (!isPlainObject(value)) refuse(path, "node")

  const type = value.type
  if (typeof type !== "string" || !ELEMENTS.includes(type) || !own(RULES, type)) {
    refuse(pointer(path, "type"), "element")
  }

  const rule = RULES[type]
  for (const key of Object.keys(value)) {
    if (key !== "type" && !rule.required.includes(key) && !own(rule.optional, key)) refuse(pointer(path, key), "field")
  }
  for (const key of rule.required) {
    if (!own(value, key)) refuse(pointer(path, key), "required")
  }

  // An optional field is absent or a value of its own; null is no field's.
  const normal = {type}
  for (const [key, fallback] of Object.entries(rule.optional)) {
    if (own(value, key) && value[key] === null) refuse(pointer(path, key), "value")
    normal[key] = own(value, key) ? value[key] : fallback
  }
  for (const key of rule.required) normal[key] = value[key]

  READERS[type](normal, path, depth, state)
  return normal
}

const at = (path, key) => pointer(path, key)

const oneOf = (node, key, values, path) => {
  if (!values.includes(node[key])) refuse(at(path, key), "value")
}

const textOf = (value, max, path, min = 0) => {
  if (!isText(value)) refuse(path, "value")
  const length = codePoints(value)
  if (length < min || length > max) refuse(path, "value")
}

const finite = (value, path) => {
  if (typeof value !== "number" || !Number.isFinite(value)) refuse(path, "value")
}

const integerIn = (value, min, max, path) => {
  if (!Number.isInteger(value) || value < min || value > max) refuse(path, "value")
}

const children = (list, path, depth, state, max = Infinity) => {
  if (!Array.isArray(list) || list.length > max) refuse(path, "value")
  return list.map((child, i) => node(child, pointer(path, i), depth + 1, state))
}

const READERS = {
  stack(n, path, depth, state) {
    oneOf(n, "direction", DIRECTIONS, path)
    oneOf(n, "gap", GAPS, path)
    n.children = children(n.children, at(path, "children"), depth, state)
  },

  grid(n, path, depth, state) {
    integerIn(n.columns, 1, MAX_GRID_COLUMNS, at(path, "columns"))
    oneOf(n, "gap", GAPS, path)
    n.children = children(n.children, at(path, "children"), depth, state)
  },

  text(n, path) {
    textOf(n.value, MAX_TEXT, at(path, "value"))
    oneOf(n, "tone", TONES, path)
    oneOf(n, "size", SIZES, path)
    oneOf(n, "weight", WEIGHTS, path)
  },

  number(n, path) {
    finite(n.value, at(path, "value"))
    if (typeof n.format !== "string" || !NUMBER_FORMAT.test(n.format)) refuse(at(path, "format"), "value")
    if (n.digits !== null) integerIn(n.digits, 0, MAX_DIGITS, at(path, "digits"))
    oneOf(n, "tone", TONES, path)
    oneOf(n, "size", SIZES, path)
  },

  time(n, path) {
    if (parseTime(n.value) === null) refuse(at(path, "value"), "value")
    oneOf(n, "format", TIME_FORMATS, path)
  },

  list(n, path, depth, state) {
    n.items = children(n.items, at(path, "items"), depth, state, MAX_LIST_ITEMS)
  },

  table(n, path) {
    const columnsPath = at(path, "columns")
    if (!Array.isArray(n.columns) || n.columns.length < 1 || n.columns.length > MAX_COLUMNS) {
      refuse(columnsPath, "value")
    }
    const keys = new Set()
    n.columns = n.columns.map((column, i) => {
      const columnPath = pointer(columnsPath, i)
      exactly(column, ["key", "title"], columnPath)
      textOf(column.key, MAX_COLUMN_KEY, at(columnPath, "key"), 1)
      textOf(column.title, MAX_COLUMN_TITLE, at(columnPath, "title"))
      if (keys.has(column.key)) refuse(at(columnPath, "key"), "value")
      keys.add(column.key)
      return {key: column.key, title: column.title}
    })

    const rowsPath = at(path, "rows")
    if (!Array.isArray(n.rows) || n.rows.length > MAX_ROWS) refuse(rowsPath, "value")
    n.rows = n.rows.map((row, i) => {
      const rowPath = pointer(rowsPath, i)
      if (!isPlainObject(row) || Object.keys(row).length > MAX_ROW_KEYS) refuse(rowPath, "value")
      for (const [key, cell] of Object.entries(row)) scalar(cell, pointer(rowPath, key))
      return row
    })
  },

  chart(n, path) {
    oneOf(n, "kind", CHART_KINDS, path)
    const seriesPath = at(path, "series")
    if (!Array.isArray(n.series) || n.series.length < 1 || n.series.length > MAX_SERIES) refuse(seriesPath, "value")

    n.series = n.series.map((series, i) => {
      const onePath = pointer(seriesPath, i)
      exactly(series, ["name", "points"], onePath)
      textOf(series.name, MAX_SERIES_NAME, at(onePath, "name"), 1)
      const pointsPath = at(onePath, "points")
      if (!Array.isArray(series.points) || series.points.length > MAX_POINTS) refuse(pointsPath, "value")
      const points = series.points.map((point, j) =>
        n.kind === "candle" ? candle(point, pointer(pointsPath, j)) : xy(point, pointer(pointsPath, j))
      )
      return {name: series.name, points}
    })
  },

  image(n, path) {
    if (!isImageSource(n.src)) refuse(at(path, "src"), "value")
    textOf(n.alt, MAX_ALT, at(path, "alt"))
  },

  control(n, path) {
    n.effect = effect(n.effect, at(path, "effect"))
    oneOf(n, "tone", TONES, path)
    oneOf(n, "size", SIZES, path)
  },

  surface(n, path, _depth, state) {
    if (!isName(n.id) || state.surfaces.includes(n.id)) refuse(at(path, "id"), "value")
    integerIn(n.width, 1, MAX_SURFACE_SIDE, at(path, "width"))
    integerIn(n.height, 1, MAX_SURFACE_SIDE, at(path, "height"))
    state.surfaces.push(n.id)
  },

  spacer() {}
}

function exactly(value, keys, path) {
  if (!isPlainObject(value)) refuse(path, "value")
  for (const key of Object.keys(value)) if (!keys.includes(key)) refuse(pointer(path, key), "field")
  for (const key of keys) if (!own(value, key)) refuse(pointer(path, key), "required")
}

function scalar(value, path) {
  if (value === null || typeof value === "boolean") return
  if (typeof value === "number") return finite(value, path)
  textOf(value, MAX_CELL, path)
}

function xy(point, path) {
  exactly(point, ["x", "y"], path)
  if (typeof point.x === "number") finite(point.x, at(path, "x"))
  else textOf(point.x, MAX_X_TEXT, at(path, "x"))
  finite(point.y, at(path, "y"))
  return {x: point.x, y: point.y}
}

function candle(point, path) {
  exactly(point, ["c", "h", "l", "o", "t"], path)
  if (typeof point.t === "number") finite(point.t, at(path, "t"))
  else if (parseTime(point.t) === null) refuse(at(path, "t"), "value")
  for (const key of ["o", "h", "l", "c"]) finite(point[key], at(path, key))
  return {t: point.t, o: point.o, h: point.h, l: point.l, c: point.c}
}

// A control's one effect: exactly `{open: <tincture reference>}` or exactly
// `{press: {feed, action}}`. A label is the declaration's, so no other key
// is taken.
function effect(value, path) {
  if (!isPlainObject(value)) refuse(path, "value")
  for (const key of Object.keys(value)) if (key !== "open" && key !== "press") refuse(pointer(path, key), "field")
  if (Object.keys(value).length !== 1) refuse(path, "value")

  if (own(value, "open")) {
    if (!isTinctureRef(value.open)) refuse(at(path, "open"), "value")
    return {open: value.open}
  }

  const pressPath = at(path, "press")
  exactly(value.press, ["action", "feed"], pressPath)
  if (!isName(value.press.feed)) refuse(at(pressPath, "feed"), "value")
  if (!isName(value.press.action)) refuse(at(pressPath, "action"), "value")
  return {press: {feed: value.press.feed, action: value.press.action}}
}

// An image's source: a path inside the version (plain segments, none `.` or
// `..`, no scheme and no leading `/`), or a base64 `data:` URL of a PNG,
// JPEG or WebP image.
export function isImageSource(src) {
  if (typeof src !== "string") return false
  if (src.startsWith("data:")) return src.length <= MAX_DATA_URL && DATA_URL.test(src)
  if (src.length < 1 || src.length > MAX_PATH) return false
  return src.split("/").every((segment) => PATH_SEGMENT.test(segment) && segment !== "." && segment !== "..")
}

// A time in `Prima.Canvas.Shape`'s grammar, as milliseconds since the epoch,
// or null.
export function parseTime(value) {
  if (typeof value !== "string") return null
  const match = TIME.exec(value)
  if (match === null) return null

  const [, sign, y, mo, d, h, mi, s, fraction, offset] = match
  const year = Number(y) * (sign === "-" ? -1 : 1)
  const month = Number(mo)
  const day = Number(d)
  const hour = Number(h)
  const minute = Number(mi)
  const second = Number(s)

  if (month < 1 || month > 12 || day < 1 || day > daysIn(year, month)) return null
  if (hour > 23 || minute > 59 || second > 59) return null

  let offsetMinutes = 0
  if (offset !== "Z") {
    // `DateTime.from_iso8601/1` refuses this one spelling of a zero offset
    // and takes the others.
    if (offset === "-00:00") return null
    const hours = Number(offset.slice(1, 3))
    const minutes = offset.length > 3 ? Number(offset.slice(-2)) : 0
    if (hours > 23 || minutes > 59) return null
    offsetMinutes = (offset[0] === "-" ? -1 : 1) * (hours * 60 + minutes)
  }

  const millis = fraction ? Number((fraction + "00").slice(0, 3)) : 0
  const date = new Date(0)
  date.setUTCFullYear(year, month - 1, day)
  date.setUTCHours(hour, minute, second, millis)
  return date.getTime() - offsetMinutes * 60000
}

const leap = (year) => year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)

function daysIn(year, month) {
  if (month === 2) return leap(year) ? 29 : 28
  return [4, 6, 9, 11].includes(month) ? 30 : 31
}

// The UTF-8 length of a string, counting a lone surrogate as the three bytes
// of its replacement character.
export function utf8Length(text) {
  let bytes = 0
  for (let i = 0; i < text.length; i++) {
    const unit = text.charCodeAt(i)
    if (unit < 0x80) bytes += 1
    else if (unit < 0x800) bytes += 2
    else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1)
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4
        i += 1
      } else {
        bytes += 3
      }
    } else bytes += 3
  }
  return bytes
}
