// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The wire between a canvas's frame and the shell, as `Prima.CanvasWire`
// defines it, and the toolkit's own protocol between its host script and its
// two workers, which never reaches the shell.
//
// `tests/fixtures/canvas_wire.json` pins the canvas wire on both sides: every
// message `Prima.CanvasWire.decode/1` accepts, `decode` here accepts, and
// every one it refuses, `decode` refuses.

import {isFrameId} from "../sdk/wire.js"

export {isFrameId}

export const VERSION = 1

export const TO_PRISM_VERBS = Object.freeze(["ready", "tree", "open", "press", "failed"])
export const TO_TOOLKIT_VERBS = Object.freeze(["boot", "posture", "covered", "installed", "state", "credential"])

// The toolkit majors this toolkit draws.
export const TOOLKIT_MAJORS = Object.freeze([1])

const MODES = ["live", "validation"]
const STAGES = ["load", "tree", "runtime"]
const POSTURES = ["desk", "hand"]
const STATES = ["live", "frozen"]

const MAX_RECTS = 64
const RECT_KEYS = ["height", "width", "x", "y"]
const MAX_TINCTURES = 512
const MAX_NAME = 128
const MAX_STREAMS = 64

const DATA_PREFIX = "/_f/v1/o/"
const ASSET_PREFIX = "_s"

// The one data route under a canvas open's data path.
const STREAM_ROUTE = "stream"

// The stream whose events carry a feed's binding: its subject is the feed's
// name (`Opus.Providers.Feed`).
export const FEED_STREAM = "feed.results"

// ---- grammars ----------------------------------------------------------------

// `Prima.TinctureUrl.credential?/1`.
const ASSET_CREDENTIAL = /^[A-Za-z0-9_-][A-Za-z0-9_.-]{15,1023}$/
// `Prima.Feed.name?/1`: a feed's name, and an action's.
const NAME = /^[a-z0-9][a-z0-9-]{0,47}$/
// `Prima.Feed.binding_id?/1`.
const BINDING_ID = /^feed_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
// `Prima.Manifest.Tincture.stream_name?/1`.
const STREAM_NAME = /^[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+$/
// `Prima.ComponentRef`'s strict semver.
const SEMVER =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?$/
// The characters Elixir's `String.trim/1` removes, which differ from
// JavaScript's: U+0085 is one of them and U+FEFF is not.
const ELIXIR_SPACE = "[\\t\\n\\v\\f\\r \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]"
const TRIM = new RegExp(`^${ELIXIR_SPACE}+|${ELIXIR_SPACE}+$`, "g")
const TYPE_PREFIXES = ["catalyst", "reagent", "formula", "tincture", "agent", "c", "r", "f", "t"]
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/
const CONTROL = /[\u0000-\u001F\u007F-\u009F]/
// A served path segment as `Prima.TinctureUrl.asset_path/2` writes it: the
// unreserved characters as themselves, every other byte as `%XX`.
const CANONICAL_SEGMENT = /^(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+$/
const UNRESERVED_BYTE = /^[A-Za-z0-9._~-]$/

export const isPlainObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value) &&
  Object.prototype.toString.call(value) === "[object Object]"

const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key)

// Whether `value` is text: a string with no lone surrogate, which is what
// a string of valid UTF-8 is on the other side.
export const isText = (value) => typeof value === "string" && !LONE_SURROGATE.test(value)

export const codePoints = (value) => Array.from(value).length

// Text of `min` to `max` code points with no control character: the rule a
// feed's labels follow (`Prima.Feed`).
export const isLabel = (value, min, max) =>
  isText(value) && !CONTROL.test(value) && codePoints(value) >= min && codePoints(value) <= max

export const isCredential = (value) => typeof value === "string" && ASSET_CREDENTIAL.test(value)
export const isName = (value) => typeof value === "string" && NAME.test(value)
export const isBindingId = (value) => typeof value === "string" && BINDING_ID.test(value)
export const isStreamName = (value) => typeof value === "string" && STREAM_NAME.test(value)

// A reference `Prima.ComponentRef.parse/1` reads as a tincture's, parsed as
// it parses: trimmed, a known type prefix before the first `:`, the last `:`
// before a version, and the last `.` between namespace and name.
export function isTinctureRef(ref) {
  if (!isText(ref)) return false
  const trimmed = ref.replace(TRIM, "")
  const colon = trimmed.indexOf(":")
  if (trimmed === "" || colon === -1) return false

  const prefix = trimmed.slice(0, colon)
  if (prefix.includes(".") || !TYPE_PREFIXES.includes(prefix)) return false
  if (prefix !== "t" && prefix !== "tincture") return false

  const remainder = trimmed.slice(colon + 1)
  const last = remainder.lastIndexOf(":")
  const nsName = last === -1 ? remainder : remainder.slice(0, last)
  const version = last === -1 || last === remainder.length - 1 ? null : remainder.slice(last + 1)
  if (version === "latest") return false
  if (version !== null && !SEMVER.test(version)) return false

  const dot = nsName.lastIndexOf(".")
  return dot > 0 && dot < nsName.length - 1
}

// A path `Prima.TinctureUrl.asset_path/2` writes, spelt exactly as it writes
// it: `/_s/<credential>/<segments>`, each segment canonically encoded, none
// empty, `.` or `..`, and none decoding to a separator or a NUL.
function assetPath(path) {
  if (typeof path !== "string" || !path.startsWith("/")) return null
  const parts = path.slice(1).split("/")
  if (parts.length < 3 || parts[0] !== ASSET_PREFIX || !isCredential(parts[1])) return null
  const segments = parts.slice(2)
  return segments.every(canonicalSegment) ? {credential: parts[1], segments} : null
}

function canonicalSegment(segment) {
  if (!CANONICAL_SEGMENT.test(segment) || segment === "." || segment === "..") return false

  for (const [, hex] of segment.matchAll(/%([0-9A-F]{2})/g)) {
    const byte = parseInt(hex, 16)
    // An unreserved byte is written as itself, never encoded; a separator,
    // a backslash or a NUL is no segment's.
    if (UNRESERVED_BYTE.test(String.fromCharCode(byte))) return false
    if (byte === 0x2f || byte === 0x5c || byte === 0x00) return false
  }
  return true
}

function isModuleUrl(url) {
  const path = assetPath(url)
  if (path === null) return false
  const file = path.segments[path.segments.length - 1]
  return file.endsWith(".js") || file.endsWith(".mjs")
}

// The version's served prefix of a module URL `decode` accepted:
// `/_s/<credential>/`.
export function servedPrefix(moduleUrl) {
  const path = assetPath(moduleUrl)
  if (path === null) throw new TypeError("not a served module path")
  return `/${ASSET_PREFIX}/${path.credential}/`
}

// ---- paths -------------------------------------------------------------------

// The data prefix of a canvas open, the one its policy names.
export function dataPath(frame) {
  return DATA_PREFIX + frameOf(frame) + "/"
}

// The URL a canvas open's streams post to, under its data URL.
export function streamUrlOf(dataUrl) {
  return dataUrl + STREAM_ROUTE
}

function frameOf(frame) {
  if (!isFrameId(frame)) throw new TypeError("a frame id is 8 to 64 URL-safe characters")
  return frame
}

// ---- messages ------------------------------------------------------------------

// A message read back, of either direction: `{ok: true, message: {verb,
// frame, args}}`, or `{ok: false, error}` for anything `Prima.CanvasWire`
// refuses. A receiver holds the verb to its own direction's set.
export function decode(message) {
  if (!isPlainObject(message)) return refuse("the message must be an object")
  const error =
    exact(message, ["args", "frame", "v", "verb"], "the message") ||
    (message.v === VERSION ? null : `the message carries no wire version ${VERSION}`) ||
    (verbOf(message.verb) ? null : "verb must be one of " + verbs().join(", ")) ||
    (isFrameId(message.frame) ? null : "frame must be a frame id") ||
    (isPlainObject(message.args) ? null : "args must be an object") ||
    argsError(message.verb, message.args, message.frame)

  return error === null
    ? {ok: true, message: {verb: message.verb, frame: message.frame, args: message.args}}
    : refuse(error)
}

// The envelope of a message the toolkit posts; a message `decode` would
// refuse throws, with a sentence that names no value it carries.
export function encode(verb, frame, args) {
  const envelope = {v: VERSION, verb, frame, args}
  const decoded = decode(envelope)
  if (!decoded.ok) throw new TypeError("not a canvas wire message: " + decoded.error)
  return envelope
}

// Whether a `boot` `decode` refused is refused for its `streams` alone: such
// a boot is the toolkit's terminal load failure, never one to wait past or
// to read as "every stream allowed".
export function bootStreamsRefused(message, frame) {
  if (!isPlainObject(message) || message.verb !== "boot" || message.frame !== frame) return false
  if (!isPlainObject(message.args) || decode(message).ok) return false
  const args = {...message.args, streams: []}
  return decode({...message, args}).ok
}

const refuse = (error) => ({ok: false, error})
const verbs = () => [...TO_PRISM_VERBS, ...TO_TOOLKIT_VERBS]
const verbOf = (verb) => typeof verb === "string" && verbs().includes(verb)

function argsError(verb, args, frame) {
  switch (verb) {
    case "ready":
    case "tree":
      return exact(args, [], verb)
    case "open":
      return exact(args, ["ref"], "open") || check(isTinctureRef(args.ref), "open names a tincture reference")
    case "press":
      return (
        exact(args, ["action", "binding"], "press") ||
        check(isBindingId(args.binding), "press names a binding id") ||
        check(isName(args.action), "press names an action by its name")
      )
    case "failed":
      return exact(args, ["stage"], "failed") || check(STAGES.includes(args.stage), "failed names a stage")
    case "boot":
      return (
        exact(args, ["credential", "data_path", "mode", "module_url", "streams", "toolkit"], "boot") ||
        check(MODES.includes(args.mode), "boot's mode is live or validation") ||
        check(typeof args.credential === "string" && args.credential !== "", "boot carries the frame credential") ||
        check(args.data_path === dataPath(frame), "boot's data path is its frame's") ||
        check(isModuleUrl(args.module_url), "boot's module is a served .js or .mjs") ||
        check(Number.isInteger(args.toolkit) && args.toolkit > 0, "boot's toolkit is a major, a positive integer") ||
        check(isStreams(args.streams), `boot names at most ${MAX_STREAMS} distinct streams of name and subject`)
      )
    case "posture":
      return exact(args, ["posture"], "posture") || check(POSTURES.includes(args.posture), "posture is desk or hand")
    case "covered":
      return (
        exact(args, ["rects"], "covered") ||
        check(bounded(args.rects, MAX_RECTS, isRect), "covered names at most 64 rects of x, y, width and height")
      )
    case "installed":
      return (
        exact(args, ["tinctures"], "installed") ||
        check(bounded(args.tinctures, MAX_TINCTURES, isInstalled), "installed names at most 512 tinctures of ref and name")
      )
    case "state":
      return exact(args, ["state"], "state") || check(STATES.includes(args.state), "state is live or frozen")
    case "credential":
      return (
        exact(args, ["credential"], "credential") ||
        check(typeof args.credential === "string" && args.credential !== "", "credential carries the frame credential")
      )
    default:
      return "unknown verb"
  }
}

const check = (ok, sentence) => (ok ? null : sentence)

const bounded = (list, max, each) => Array.isArray(list) && list.length <= max && list.every(each)

const isRect = (rect) =>
  isPlainObject(rect) &&
  sameKeys(rect, RECT_KEYS) &&
  RECT_KEYS.every((key) => typeof rect[key] === "number" && Number.isFinite(rect[key]) && rect[key] >= 0)

const isInstalled = (tincture) =>
  isPlainObject(tincture) &&
  sameKeys(tincture, ["name", "ref"]) &&
  isTinctureRef(tincture.ref) &&
  isText(tincture.name) &&
  codePoints(tincture.name) >= 1 &&
  codePoints(tincture.name) <= MAX_NAME

// The streams a version declares, as Prism hands them over: distinct
// `{name, subject}` pairs, `subject` a string or null.
function isStreams(streams) {
  if (!bounded(streams, MAX_STREAMS, isStream)) return false
  const pairs = new Set(streams.map(pairKey))
  return pairs.size === streams.length
}

const isStream = (stream) =>
  isPlainObject(stream) &&
  sameKeys(stream, ["name", "subject"]) &&
  isStreamName(stream.name) &&
  (stream.subject === null || isText(stream.subject))

export const pairKey = ({name, subject}) => JSON.stringify([name, subject])

const sameKeys = (object, keys) => {
  const present = Object.keys(object).sort()
  return present.length === keys.length && present.every((key, i) => key === keys[i])
}

function exact(object, keys, where) {
  const present = Object.keys(object)
  const extra = present.filter((key) => !keys.includes(key))
  const missing = keys.filter((key) => !has(object, key))
  if (extra.length > 0) return `${where} carries an unknown key`
  if (missing.length > 0) return `${where} lacks ${missing.join(", ")}`
  return null
}

// ---- the toolkit's own protocol ------------------------------------------------
//
// The host starts two classic workers from the one inert bundle and fixes
// each one's role by the name it starts it under, before any module is
// imported. Every message is authenticated by the channel it arrives on:
//
//   * the module worker's own channel (its `Worker` object) carries only
//     `tree` and `failed` to the host, and the host's `boot`, `posture`,
//     `covered`, `installed`, `surface` and relayed `stream` messages to it;
//   * the streams worker's own channel carries the host's `boot`, with the
//     bearer, to it, and `relay` messages, the only source of binding
//     records, to the host;
//   * one `MessageChannel` between the two carries the module worker's
//     `open` and `close` requests and the answers of streams that carry no
//     binding.
//
// A feed's stream answers go through the host, which installs the binding
// record an event carries before it hands that event to the module worker,
// so no tree drawn from an event can reach the host ahead of the event's
// binding.

export const ROLES = Object.freeze({module: "cyfr-toolkit-module", streams: "cyfr-toolkit-streams"})

const MODULE_KINDS = ["posture", "covered", "installed"]
export const ON_KINDS = Object.freeze([...MODULE_KINDS])

// Host to the module worker.
export const toModule = Object.freeze({
  boot: (mode, moduleUrl, port) => ({t: "boot", mode, module_url: moduleUrl, port}),
  value: (kind, value) => ({t: kind, value}),
  surface: (id, canvas) => ({t: "surface", id, canvas}),
  stream: (m) => ({t: "stream", m})
})

// Host to the streams worker: its boot, then each renewed credential.
export const toStreams = Object.freeze({
  boot: (credential, dataUrl, streams, port) => ({t: "boot", credential, data_url: dataUrl, streams, port}),
  credential: (credential) => ({t: "credential", credential})
})

// Module worker to host.
export const fromModule = Object.freeze({
  tree: (json) => ({t: "tree", json}),
  failed: (stage) => ({t: "failed", stage})
})

// What the host reads on the module worker's channel: `{kind: "tree", json}`
// (json a string, or null for a tree that did not serialize), `{kind:
// "failed", stage}`, or null for anything else, which is a protocol
// violation.
export function decodeFromModule(data) {
  if (!isPlainObject(data)) return null
  if (data.t === "tree" && sameKeys(data, ["json", "t"]) && (data.json === null || typeof data.json === "string")) {
    return {kind: "tree", json: data.json}
  }
  if (data.t === "failed" && sameKeys(data, ["stage", "t"]) && (data.stage === "load" || data.stage === "runtime")) {
    return {kind: "failed", stage: data.stage}
  }
  return null
}

// Streams worker to host: an answer for the module worker, with the binding
// record the event it carries makes, if any.
export const fromStreams = Object.freeze({
  relay: (m, record = null) => ({t: "relay", m, record}),
  lost: () => ({t: "lost"})
})

// What the host reads on the streams worker's channel: `{kind: "relay", m,
// record}`, `{kind: "lost"}`, or null.
export function decodeFromStreams(data) {
  if (!isPlainObject(data)) return null
  if (data.t === "lost" && sameKeys(data, ["t"])) return {kind: "lost"}
  if (data.t !== "relay" || !sameKeys(data, ["m", "record", "t"]) || decodeAnswer(data.m) === null) return null
  if (data.record === null) return {kind: "relay", m: data.m, record: null}
  const record = decodeRecord(data.record)
  return record === null ? null : {kind: "relay", m: data.m, record}
}

// Module worker to streams worker, over their channel.
export const request = Object.freeze({
  open: (sub, name, subject) => ({t: "open", sub, name, subject}),
  close: (sub) => ({t: "close", sub})
})

const isSub = (sub) => Number.isSafeInteger(sub) && sub >= 0

export function decodeRequest(data) {
  if (!isPlainObject(data) || !isSub(data.sub)) return null
  if (data.t === "open" && sameKeys(data, ["name", "sub", "subject", "t"])) {
    if (typeof data.name !== "string" || !(data.subject === null || typeof data.subject === "string")) return null
    return {kind: "open", sub: data.sub, name: data.name, subject: data.subject}
  }
  if (data.t === "close" && sameKeys(data, ["sub", "t"])) return {kind: "close", sub: data.sub}
  return null
}

// Streams worker to module worker, directly or relayed by the host.
export const answer = Object.freeze({
  opened: (sub) => ({t: "opened", sub}),
  refused: (sub, code, message, stage = null) => ({t: "refused", sub, code, message, stage}),
  event: (sub, event) => ({t: "event", sub, event}),
  closed: (sub, error = null) => ({t: "closed", sub, error})
})

export function decodeAnswer(data) {
  if (!isPlainObject(data) || !isSub(data.sub)) return null
  switch (data.t) {
    case "opened":
      return sameKeys(data, ["sub", "t"]) ? data : null
    case "refused":
      return sameKeys(data, ["code", "message", "stage", "sub", "t"]) &&
        typeof data.code === "string" &&
        typeof data.message === "string" &&
        (data.stage === null || typeof data.stage === "string")
        ? data
        : null
    case "event":
      return sameKeys(data, ["event", "sub", "t"]) && isPlainObject(data.event) ? data : null
    case "closed":
      return sameKeys(data, ["error", "sub", "t"]) && (data.error === null || typeof data.error === "string")
        ? data
        : null
    default:
      return null
  }
}

// What the host reads on the module worker's own channel from the host:
// boot, the shell's values, a surface or a relayed answer.
export function decodeToModule(data) {
  if (!isPlainObject(data)) return null
  if (data.t === "boot" && sameKeys(data, ["mode", "module_url", "port", "t"])) {
    return MODES.includes(data.mode) && typeof data.module_url === "string" && isPort(data.port) ? data : null
  }
  if (MODULE_KINDS.includes(data.t) && sameKeys(data, ["t", "value"])) return data
  if (data.t === "surface" && sameKeys(data, ["canvas", "id", "t"]) && isName(data.id)) return data
  if (data.t === "stream" && sameKeys(data, ["m", "t"]) && decodeAnswer(data.m) !== null) return data
  return null
}

// What the streams worker reads on its own channel: a boot, a renewed
// credential (`{t: "credential", credential}`), or null.
export function decodeToStreams(data) {
  if (!isPlainObject(data)) return null
  if (data.t === "credential" && sameKeys(data, ["credential", "t"])) {
    return typeof data.credential === "string" && data.credential !== "" ? data : null
  }
  if (data.t !== "boot" || !sameKeys(data, ["credential", "data_url", "port", "streams", "t"])) return null
  if (typeof data.credential !== "string" || data.credential === "" || typeof data.data_url !== "string") return null
  return isStreams(data.streams) && isPort(data.port) ? data : null
}

const isPort = (port) => port !== null && typeof port === "object" && typeof port.postMessage === "function"

// ---- binding records ---------------------------------------------------------

const MAX_ACTIONS = 8
const BINDING_LABEL_MAX = 80
const ACTION_LABEL_MAX = 40

// The record a feed's stream event makes for the subscription's own feed:
// the binding id, its revision, and the labels the binding declares. An
// event that is not that feed's envelope (`Prima.Feed.envelope/5`) makes
// none.
export function recordFromEnvelope(data, feed) {
  if (!isPlainObject(data) || !isName(feed) || data.feed !== feed) return null
  return decodeRecord({
    feed,
    binding: data.binding,
    revision: data.revision,
    label: data.label,
    actions: data.actions
  })
}

export function decodeRecord(record) {
  if (!isPlainObject(record) || !sameKeys(record, ["actions", "binding", "feed", "label", "revision"])) return null
  const {feed, binding, revision, label, actions} = record
  if (!isName(feed) || !isBindingId(binding)) return null
  if (!Number.isSafeInteger(revision) || revision < 0) return null
  if (!isLabel(label, 1, BINDING_LABEL_MAX)) return null
  if (!Array.isArray(actions) || actions.length > MAX_ACTIONS) return null

  const names = new Set()
  const read = []
  for (const action of actions) {
    if (!isPlainObject(action) || !isName(action.name) || names.has(action.name)) return null
    if (!isLabel(action.label, 1, ACTION_LABEL_MAX)) return null
    names.add(action.name)
    read.push({name: action.name, label: action.label})
  }
  return {feed, binding, revision, label, actions: read}
}

// Whether `next` replaces `stored`: every later envelope does, but one of the
// same binding at a revision no higher than the stored one's.
export const replacesRecord = (stored, next) =>
  !stored || stored.binding !== next.binding || next.revision > stored.revision
