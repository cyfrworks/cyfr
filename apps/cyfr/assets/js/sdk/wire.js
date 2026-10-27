// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The wire between a tincture's frame, the endpoint and the shell, as
// `Prima.TinctureWire` defines it: the frame posts `invoke`, `action` and
// `stream_open` requests to the endpoint under its credential, and shell
// verbs to the shell over its MessagePort. `tests/fixtures/tincture_wire.json`
// pins both sides; the SDK's tests read it.
//
// Beside it, the messages the shell sends the frame over the port: its port
// and its credential, and to a canvas its open (`canvas`) and what the
// shell tells it (`posture`, `covered`, `installed`, `state`). They pass
// only between the shell's bridge and the SDK, so they are defined here,
// once; the canvas's are pinned by the fixture's `canvas` section, whose
// `handshake` rows are the server's reply the bridge reads them from.

export const VERSION = 1

export const BEARER_HEADER = "authorization"

export const ROUTES = Object.freeze({
  invoke: "/_f/v1/invoke",
  action: "/_f/v1/action",
  stream_open: "/_f/v1/stream"
})

export const VERBS = Object.freeze(["open", "close", "title", "ready", "credential", "press", "failed"])

// Where a frame that posts `failed` failed: before its `ready`, or after.
export const STAGES = Object.freeze(["load", "runtime"])

// Shell to frame, over `window.postMessage` with the port transferred: the
// frame id, and nothing else.
export const HANDSHAKE = "cyfr:handshake"

// Shell to frame, over the port only: the frame credential.
export const CREDENTIAL = "cyfr:credential"

// Shell to frame, over the port only: the credential prompt the frame's
// `credential` verb asked for closed, and whether an entry was saved
// (`saved`, a boolean). Nothing else of the prompt reaches the frame: not
// the value, not why it was not saved.
export const CREDENTIAL_CLOSED = "cyfr:credential-closed"

// The message the bridge posts for a closed prompt.
export function credentialClosed(frame, saved) {
  return {v: VERSION, type: CREDENTIAL_CLOSED, frame, saved: saved === true}
}

// A closed-prompt message read back: `{ok: true, saved}` for this frame's,
// `{ok: false}` for anything else.
export function decodeCredentialClosed(data, frame) {
  if (!isObject(data) || data.v !== VERSION || data.type !== CREDENTIAL_CLOSED) return {ok: false}
  if (!only(data, ["v", "type", "frame", "saved"]) || data.frame !== frame) return {ok: false}
  if (typeof data.saved !== "boolean") return {ok: false}
  return {ok: true, saved: data.saved}
}

const FRAME_ID = /^[A-Za-z0-9_-]{8,64}$/
const TINCTURE_REF = /^(t|tincture):\S+$/
const MAX_TITLE = 120
// `Prima.Feed.binding_id?/1`.
const BINDING_ID = /^feed_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
// `Prima.Feed.name?/1`: a feed's name, and an action's.
const ACTION_NAME = /^[a-z0-9][a-z0-9-]{0,47}$/
// `Prima.Manifest.Tincture.stream_name?/1`.
const STREAM_NAME = /^[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+$/
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/

const isObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value)

const only = (object, keys) => Object.keys(object).every((key) => keys.includes(key))

// Exactly `keys`, each present once.
const sameKeys = (object, keys) => {
  const present = Object.keys(object).sort()
  const wanted = [...keys].sort()
  return present.length === wanted.length && present.every((key, i) => key === wanted[i])
}

// A string with no lone surrogate: what a string of valid UTF-8 is on the
// server's side.
const isText = (value) => typeof value === "string" && !LONE_SURROGATE.test(value)

const isTinctureRef = (ref) => typeof ref === "string" && TINCTURE_REF.test(ref)

export function isFrameId(id) {
  return typeof id === "string" && FRAME_ID.test(id)
}

export function bearer(credential) {
  if (typeof credential !== "string" || credential === "" || /\s/.test(credential)) {
    throw new TypeError("a frame credential is a non-empty string without whitespace")
  }
  return "Bearer " + credential
}

// The JSON body of a `kind` request, from the kind's fields; a public page's
// request also names the tincture (`publicIdentity/1`) as `public`.
export function request(kind, fields, publicIdentity = null) {
  let body
  switch (kind) {
    case "invoke":
      body = {v: VERSION, ref: fields.ref, operation: fields.operation, args: fields.args}
      break
    case "action":
      body = {v: VERSION, operation: fields.operation, args: fields.args}
      break
    case "stream_open":
      body = {v: VERSION, stream: fields.stream, subject: fields.subject}
      break
    default:
      throw new TypeError("unknown request kind: " + kind)
  }
  if (publicIdentity) body.public = publicIdentity
  return body
}

// A public tincture opened as a top-level page has no shell and so no frame
// credential: its requests carry no bearer and name the tincture instead,
// as `public: {athanor, publisher, name}`, read from the page's own path
// (`/t/<athanor>/<publisher>/<name>/…`). The endpoint admits such a request
// only for a tincture that is public, under its public profile. Any other
// path — a private version's `/_s/` path among them — names no identity.
const ATHANOR_SEGMENT = /^@?[a-z0-9]+(-[a-z0-9]+)*$/
const PUBLISHER_SEGMENT = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/
const NAME_SEGMENT = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/

export function publicIdentity(pathname) {
  if (typeof pathname !== "string") return null
  const [empty, prefix, ...rest] = pathname.split("/")
  if (empty !== "" || prefix !== "t" || rest.length < 3) return null

  let athanor, publisher, name
  try {
    ;[athanor, publisher, name] = rest.slice(0, 3).map(decodeURIComponent)
  } catch (_error) {
    return null
  }

  return ATHANOR_SEGMENT.test(athanor) && PUBLISHER_SEGMENT.test(publisher) && NAME_SEGMENT.test(name)
    ? {athanor, publisher, name}
    : null
}

// The stream a `stream_open` request opens is answered as `text/event-stream`
// under the grant: one event per group of lines ended by a blank line, `id`
// the topic's sequence number where it carries one, `event` the projection
// name and `data` the projected payload as JSON (several `data` lines join
// with a newline). A line starting with `:` is a comment; any other field is
// ignored. `sseParser(onEvent)` answers `{push(text), end()}` and calls
// `onEvent({id, event, data})` for each complete event, `id` a number or
// null; an event whose data is not JSON, or that has no data, is dropped.
export const STREAM_CONTENT_TYPE = "text/event-stream"

export function sseParser(onEvent) {
  let buffer = ""
  let pendingCR = false
  let frame = {id: null, event: "message", data: []}

  const dispatch = () => {
    const {id, event, data} = frame
    frame = {id: null, event: "message", data: []}
    if (data.length === 0) return
    let payload
    try {
      payload = JSON.parse(data.join("\n"))
    } catch (_error) {
      return
    }
    onEvent({id, event, data: payload})
  }

  const line = (text) => {
    if (text === "") return dispatch()
    if (text.startsWith(":")) return
    const colon = text.indexOf(":")
    const field = colon === -1 ? text : text.slice(0, colon)
    let value = colon === -1 ? "" : text.slice(colon + 1)
    if (value.startsWith(" ")) value = value.slice(1)

    if (field === "data") frame.data.push(value)
    else if (field === "event") frame.event = value
    else if (field === "id") frame.id = /^\d+$/.test(value) ? Number(value) : null
  }

  return {
    // Lines end with LF, CRLF or CR, and a chunk may end anywhere, a CRLF
    // pair split between two chunks included.
    push(text) {
      if (pendingCR && text.startsWith("\n")) text = text.slice(1)
      pendingCR = false
      buffer += text

      let match
      while ((match = /\r\n|\r|\n/.exec(buffer)) !== null) {
        if (match[0] === "\r" && match.index === buffer.length - 1) {
          pendingCR = true
        }
        line(buffer.slice(0, match.index))
        buffer = buffer.slice(match.index + match[0].length)
      }
    },

    // A stream that ends mid-event dispatches nothing more: an event is
    // complete only at its blank line.
    end() {
      buffer = ""
      frame = {id: null, event: "message", data: []}
    }
  }
}

// An answer read back: {ok: true, value} for a result or a stream grant,
// {ok: false, refusal} for a refusal the frame may read, and
// {ok: false, invalid: true} for anything else. Which refusal classes exist
// is the server's (`Prima.Refusal`); the frame reads the class as a name.
export function decodeAnswer(kind, body) {
  const invalid = {ok: false, invalid: true}
  if (!isObject(body) || body.v !== VERSION || !(kind in ROUTES)) return invalid
  const keys = Object.keys(body)

  if (body.ok === true && keys.length === 3) {
    if ((kind === "invoke" || kind === "action") && "result" in body) {
      return {ok: true, value: body.result}
    }
    if (kind === "stream_open" && isObject(body.stream)) return decodeGrant(body.stream)
    return invalid
  }

  if (body.ok === false && keys.length === 3 && isObject(body.error)) {
    const {class: cls, message, stage} = body.error
    if (
      Object.keys(body.error).length === 3 &&
      typeof cls === "string" &&
      cls !== "" &&
      typeof message === "string" &&
      (stage === "admission" || stage === "execution")
    ) {
      return {ok: false, refusal: {class: cls, message, stage}}
    }
  }

  return invalid
}

function decodeGrant(stream) {
  const {grant_id, stream: name, subject, projection, deadline} = stream
  const at = typeof deadline === "string" ? new Date(deadline) : null
  if (
    Object.keys(stream).length === 5 &&
    typeof grant_id === "string" &&
    typeof name === "string" &&
    (subject === null || typeof subject === "string") &&
    Array.isArray(projection) &&
    projection.every((field) => typeof field === "string") &&
    at !== null &&
    !Number.isNaN(at.getTime())
  ) {
    return {ok: true, value: {grant_id, stream: name, subject, projection, deadline: at}}
  }
  return {ok: false, invalid: true}
}

// The message the frame `frame` posts for `verb`.
export function shellMessage(verb, frame, args = {}) {
  if (!VERBS.includes(verb)) throw new TypeError("unknown shell verb: " + verb)
  return {v: VERSION, verb, frame, args}
}

// A shell message read back: {ok: true, message} or {ok: false, error}.
// A verb that carries anything its arguments do not name — data among
// them — does not decode.
export function decodeShellMessage(message) {
  if (!isObject(message)) return {ok: false, error: "the message must be an object"}
  if (message.v !== VERSION) return {ok: false, error: "the message carries no wire version 1"}
  if (!only(message, ["v", "verb", "frame", "args"])) return {ok: false, error: "unknown field"}
  if (!VERBS.includes(message.verb)) return {ok: false, error: "unknown verb"}
  if (!isFrameId(message.frame)) return {ok: false, error: "frame must be a frame id"}

  const args = message.args === undefined ? {} : message.args
  if (!isObject(args)) return {ok: false, error: "args must be an object"}
  const error = argsError(message.verb, args)
  if (error) return {ok: false, error}

  return {ok: true, message: {v: VERSION, verb: message.verb, frame: message.frame, args}}
}

function argsError(verb, args) {
  const keys = Object.keys(args)
  switch (verb) {
    case "open":
      return keys.length === 1 && isTinctureRef(args.ref) ? null : "open names a tincture reference"
    case "title":
      return keys.length === 1 &&
        typeof args.title === "string" &&
        args.title !== "" &&
        Array.from(args.title).length <= MAX_TITLE
        ? null
        : "title names a title"
    case "credential":
      return keys.length === 1 && typeof args.name === "string" && args.name !== ""
        ? null
        : "credential names a vault entry"
    case "press":
      return sameKeys(args, ["binding", "action"]) &&
        typeof args.binding === "string" &&
        BINDING_ID.test(args.binding) &&
        typeof args.action === "string" &&
        ACTION_NAME.test(args.action)
        ? null
        : "press names a binding id and an action"
    case "failed":
      return sameKeys(args, ["stage"]) && STAGES.includes(args.stage) ? null : "failed names a stage"
    default:
      return keys.length === 0 ? null : verb + " takes no arguments"
  }
}

// ---- a canvas ----------------------------------------------------------------

// The one data route under a canvas open's data path, and the path's
// prefix: a canvas's credential reaches only `<data path>stream`.
const DATA_PREFIX = "/_f/v1/o/"
const STREAM_ROUTE = "stream"

// A canvas open's data path, the one its page's policy names in
// `connect-src`: `/_f/v1/o/<frame>/`.
export function dataPath(frame) {
  if (!isFrameId(frame)) throw new TypeError("a frame id is 8 to 64 URL-safe characters")
  return DATA_PREFIX + frame + "/"
}

// The route a canvas's streams are opened on, under its data path.
export function streamPath(frame) {
  return dataPath(frame) + STREAM_ROUTE
}

// A canvas open is `live` (the person's canvas) or `validation` (a new
// version trialled in a hidden frame).
export const MODES = Object.freeze(["live", "validation"])

// Shell to a canvas, over its port: its open, then what the shell tells it.
export const TO_FRAME_VERBS = Object.freeze(["canvas", "posture", "covered", "installed", "state"])

// What the shell tells a canvas, which its page hears through `cyfr.on`.
export const CANVAS_EVENTS = Object.freeze(["installed", "posture", "covered", "state"])

const POSTURES = ["desk", "hand"]
const SHELL_STATES = ["live", "frozen"]
const MAX_STREAMS = 64
export const MAX_RECTS = 64
const RECT_KEYS = ["x", "y", "width", "height"]
const MAX_TINCTURES = 512
const MAX_NAME = 128

// The key one declared stream is held under: its name and its subject.
export const pairKey = ({name, subject}) => JSON.stringify([name, subject])

const bounded = (list, max, each) => Array.isArray(list) && list.length <= max && list.every(each)

const isStream = (stream) =>
  isObject(stream) &&
  sameKeys(stream, ["name", "subject"]) &&
  typeof stream.name === "string" &&
  STREAM_NAME.test(stream.name) &&
  (stream.subject === null || isText(stream.subject))

// The streams a canvas version declares: at most 64 distinct pairs of a
// stream name and a subject, a string or null.
const isStreams = (streams) =>
  bounded(streams, MAX_STREAMS, isStream) && new Set(streams.map(pairKey)).size === streams.length

const isRect = (rect) =>
  isObject(rect) &&
  sameKeys(rect, RECT_KEYS) &&
  RECT_KEYS.every((key) => typeof rect[key] === "number" && Number.isFinite(rect[key]) && rect[key] >= 0)

const codePoints = (value) => Array.from(value).length

const isInstalled = (tincture) =>
  isObject(tincture) &&
  sameKeys(tincture, ["ref", "name"]) &&
  isTinctureRef(tincture.ref) &&
  isText(tincture.name) &&
  codePoints(tincture.name) >= 1 &&
  codePoints(tincture.name) <= MAX_NAME

// A canvas block, as the handshake reply carries it and the `canvas`
// message's args are: the open's mode, its frame's data path and the
// version's declared streams.
function canvasError(block, frame) {
  if (!isObject(block) || !sameKeys(block, ["mode", "data_path", "streams"])) {
    return "a canvas is exactly mode, data_path and streams"
  }
  if (!MODES.includes(block.mode)) return "a canvas's mode is live or validation"
  if (block.data_path !== dataPath(frame)) return "a canvas's data path is its frame's"
  if (!isStreams(block.streams)) {
    return `a canvas names at most ${MAX_STREAMS} distinct streams of name and subject`
  }
  return null
}

function toFrameArgsError(verb, args, frame) {
  switch (verb) {
    case "canvas":
      return canvasError(args, frame)
    case "posture":
      return sameKeys(args, ["posture"]) && POSTURES.includes(args.posture) ? null : "posture is desk or hand"
    case "covered":
      return sameKeys(args, ["rects"]) && bounded(args.rects, MAX_RECTS, isRect)
        ? null
        : `covered names at most ${MAX_RECTS} rects of x, y, width and height`
    case "installed":
      return sameKeys(args, ["tinctures"]) && bounded(args.tinctures, MAX_TINCTURES, isInstalled)
        ? null
        : `installed names at most ${MAX_TINCTURES} tinctures of ref and name`
    case "state":
      return sameKeys(args, ["state"]) && SHELL_STATES.includes(args.state) ? null : "state is live or frozen"
    default:
      return "unknown verb"
  }
}

// A message the shell posts a canvas read back: `{ok: true, message}` for
// exactly `{v, verb, frame, args}` the wire takes, `{ok: false, error}` for
// anything else.
export function decodeToFrame(message) {
  if (!isObject(message)) return {ok: false, error: "the message must be an object"}
  if (!sameKeys(message, ["v", "verb", "frame", "args"])) {
    return {ok: false, error: "the message is v, verb, frame and args"}
  }
  if (message.v !== VERSION) return {ok: false, error: "the message carries no wire version 1"}
  if (!TO_FRAME_VERBS.includes(message.verb)) return {ok: false, error: "unknown verb"}
  if (!isFrameId(message.frame)) return {ok: false, error: "frame must be a frame id"}
  if (!isObject(message.args)) return {ok: false, error: "args must be an object"}

  const error = toFrameArgsError(message.verb, message.args, message.frame)
  if (error) return {ok: false, error}
  return {ok: true, message: {v: VERSION, verb: message.verb, frame: message.frame, args: message.args}}
}

// The message the bridge posts a canvas for `verb`; one the wire refuses
// throws, with a sentence that names no value it carries.
export function toFrameMessage(verb, frame, args) {
  const message = {v: VERSION, verb, frame, args}
  const decoded = decodeToFrame(message)
  if (!decoded.ok) throw new TypeError("not a message to a canvas: " + decoded.error)
  return message
}

// The shell's reply to a canvas frame's handshake read back, for the frame
// `frame`: `{ok: true, credential, canvas}` for exactly a credential and a
// canvas block, `{ok: false, error}` for anything else.
export function decodeCanvasHandshake(reply, frame) {
  if (!isFrameId(frame)) return {ok: false, error: "frame must be a frame id"}
  if (!isObject(reply) || !sameKeys(reply, ["credential", "canvas"])) {
    return {ok: false, error: "a canvas's handshake is exactly credential and canvas"}
  }
  if (typeof reply.credential !== "string" || reply.credential === "") {
    return {ok: false, error: "a canvas's handshake carries the frame credential"}
  }
  const error = canvasError(reply.canvas, frame)
  if (error) return {ok: false, error}
  return {ok: true, credential: reply.credential, canvas: reply.canvas}
}
