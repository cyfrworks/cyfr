// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The wire between a tincture's frame, the endpoint and the shell, as
// `Prima.TinctureWire` defines it: the frame posts `invoke`, `action` and
// `stream_open` requests to the endpoint under its credential, and shell
// verbs to the shell over its MessagePort. `tests/fixtures/tincture_wire.json`
// pins both sides; the SDK's tests read it.
//
// Beside it, the messages the shell sends the frame over the port: its port
// and its credential, an app's subject, and to a canvas its open
// (`canvas`), what the shell tells it (`posture`, `covered`, `installed`,
// `state`) and its answers (`pressed`, `prefs`). They pass only between
// the shell's bridge and the SDK, so they are defined here, once; the
// canvas's are pinned by the fixture's `canvas` section, whose `handshake`
// rows are the server's reply the bridge reads them from.

export const VERSION = 1

export const BEARER_HEADER = "authorization"

export const ROUTES = Object.freeze({
  invoke: "/_f/v1/invoke",
  action: "/_f/v1/action",
  stream_open: "/_f/v1/stream"
})

export const VERBS = Object.freeze([
  "open",
  "close",
  "title",
  "ready",
  "credential",
  "press",
  "failed",
  "grant",
  "prefs",
  "ask",
  "settings"
])

// The verbs only a canvas sends: from any other frame the SDK sends none
// of them, and the shell drops them.
export const CANVAS_VERBS = Object.freeze(["press", "failed", "grant", "prefs", "ask", "settings"])

// The verbs a canvas sends for the person, which the shell honours only
// within moments of the person's own input, one per input.
export const PERSON_VERBS = Object.freeze(["open", "press", "grant", "prefs", "ask", "settings"])

// The kinds of subject an app is opened on (`Prima.Manifest.Tincture`).
export const SUBJECT_KINDS = Object.freeze(["run", "thread", "schedule", "component", "file"])

// What a control's press, and a write of the preferences, come to.
export const PRESS_OUTCOMES = Object.freeze(["accepted", "refused", "cancelled"])
export const PREFS_OUTCOMES = Object.freeze(["saved", "stale", "refused", "cancelled"])

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
// A component reference a `grant` names: a catalyst, reagent, formula or
// tincture, in full or by its shorthand (`Prima.ComponentRef`).
const COMPONENT_REF = /^(c|catalyst|r|reagent|f|formula|t|tincture):\S+$/
const MAX_TITLE = 120
// A desktop control's or widget's id (`Prima.TinctureWire.control?/1`).
const DESKTOP_ID = /^[a-z][a-z0-9_-]{0,62}$/
// A page's key, as Prism names its pages (`Prima.TinctureWire.page?/1`).
const PAGE = /^[a-z][a-z0-9_]{0,31}$/
// What an app is opened on (`Prima.TinctureWire.subject_id?/1`).
const SUBJECT_ID = /^[A-Za-z0-9][A-Za-z0-9_.:@/-]{0,255}$/
const MAX_PRESS_VALUE = 256
const MAX_CALL = 2147483647
const ACCENT = /^#[0-9a-f]{6}$/
const LOCALE = /^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8}){0,7}$/
const TIME_ZONE = /^[A-Za-z][A-Za-z0-9_+-]{0,31}(\/[A-Za-z0-9][A-Za-z0-9_+-]{0,31}){0,2}$/
const APPEARANCE_MODES = ["light", "dark"]
const MAX_SAFE_AREA = 512
const MAX_PERSON_NAME = 128
// A refusal's class, as the server names its classes (`Prima.Refusal`).
const REFUSAL_CLASS = /^[a-z][a-z_]{0,63}$/
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

const codePointCount = (value) => Array.from(value).length

// A C0 or C1 control character, or DEL.
const isControl = (character) => {
  const code = character.codePointAt(0)
  return code <= 0x1f || (code >= 0x7f && code <= 0x9f)
}

// Text of 1 to `max` code points with no control character.
const isBoundedText = (value, max) =>
  isText(value) && value !== "" && codePointCount(value) <= max && !Array.from(value).some(isControl)

export const isDesktopId = (id) => typeof id === "string" && DESKTOP_ID.test(id)

export const isPressValue = (value) => isBoundedText(value, MAX_PRESS_VALUE)

// The number a frame gives a press or a write, which its answer carries
// back (`Prima.TinctureWire.call?/1`).
export const isCall = (call) => Number.isInteger(call) && call >= 1 && call <= MAX_CALL

// What an app is opened on: exactly a kind the apps accept and an id.
export const isSubject = (subject) =>
  isObject(subject) &&
  sameKeys(subject, ["kind", "id"]) &&
  SUBJECT_KINDS.includes(subject.kind) &&
  typeof subject.id === "string" &&
  SUBJECT_ID.test(subject.id)

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
const ATHANOR_SEGMENT = /^@[a-z0-9]+(-[a-z0-9]+)*$/
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
      if (!isTinctureRef(args.ref)) return "open names a tincture reference"
      if (keys.length === 1) return null
      return keys.length === 2 && isSubject(args.subject)
        ? null
        : "open's subject is exactly a kind the apps accept and an id"
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
      if (sameKeys(args, ["binding", "action"])) {
        return typeof args.binding === "string" &&
          BINDING_ID.test(args.binding) &&
          typeof args.action === "string" &&
          ACTION_NAME.test(args.action)
          ? null
          : "press names a binding id and an action"
      }
      if (sameKeys(args, ["control", "call"])) {
        return isDesktopId(args.control) && isCall(args.call) ? null : "press names a control and its call"
      }
      if (sameKeys(args, ["control", "value", "call"])) {
        return isDesktopId(args.control) && isCall(args.call) && isPressValue(args.value)
          ? null
          : `a press names a control, its call and a value of 1 to ${MAX_PRESS_VALUE} code points`
      }
      return "press names a binding id and an action, or a control and its call"
    case "prefs":
      return sameKeys(args, ["document", "call"]) && isObject(args.document) && isCall(args.call)
        ? null
        : "prefs carries exactly a document and its call"
    case "ask":
      return sameKeys(args, ["widget"]) && isDesktopId(args.widget) ? null : "ask names a widget by its id"
    case "settings":
      return sameKeys(args, ["page"]) && typeof args.page === "string" && PAGE.test(args.page)
        ? null
        : "settings names a page by its key"
    case "failed":
      return sameKeys(args, ["stage"]) && STAGES.includes(args.stage) ? null : "failed names a stage"
    case "grant":
      return keys.length === 1 && typeof args.ref === "string" && COMPONENT_REF.test(args.ref)
        ? null
        : "grant names a component reference"
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

// Shell to a frame, over its port: a canvas's open, what the shell tells
// it, its answers, and an app's subject.
export const TO_FRAME_VERBS = Object.freeze([
  "canvas",
  "posture",
  "covered",
  "installed",
  "state",
  "pressed",
  "prefs",
  "subject"
])

// What the shell tells a canvas, held as the latest of each and posted
// again after its handshake.
export const TOLD_VERBS = Object.freeze(["posture", "covered", "installed", "state"])

// The shell's answers to a canvas's press of a control and write, each
// posted once, by the verb each answers.
export const ANSWER_OF = Object.freeze({press: "pressed", prefs: "prefs"})
export const ANSWER_VERBS = Object.freeze(Object.values(ANSWER_OF))

// What a page hears through `cyfr.on`: on a canvas what the shell tells
// it and `desktop`, its preferences, appearance and person; on an app,
// `subject`, what it was opened on again.
export const CANVAS_EVENTS = Object.freeze(["installed", "posture", "covered", "state", "desktop", "subject"])

const POSTURES = ["desk", "hand"]
const SHELL_STATES = ["live", "frozen"]
const MAX_STREAMS = 64
export const MAX_RECTS = 64
const RECT_KEYS = ["x", "y", "width", "height"]
const MAX_TINCTURES = 512
const MAX_NAME = 128
const MAX_ICON = 16

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

const isIcon = (icon) =>
  icon === null || (isText(icon) && codePoints(icon) >= 1 && codePoints(icon) <= MAX_ICON)

// One installed tincture: its reference, its name, its emoji or null, and
// whether it is open over the canvas.
const isInstalled = (tincture) =>
  isObject(tincture) &&
  sameKeys(tincture, ["ref", "name", "icon", "open"]) &&
  isTinctureRef(tincture.ref) &&
  isText(tincture.name) &&
  codePoints(tincture.name) >= 1 &&
  codePoints(tincture.name) <= MAX_NAME &&
  isIcon(tincture.icon) &&
  typeof tincture.open === "boolean"

const isRevision = (revision) => Number.isInteger(revision) && revision >= 0

const isPrefs = (prefs) =>
  isObject(prefs) && sameKeys(prefs, ["document", "revision"]) && isObject(prefs.document) && isRevision(prefs.revision)

const SIDES = ["top", "right", "bottom", "left"]

const isSafeAreas = (areas) =>
  isObject(areas) &&
  sameKeys(areas, SIDES) &&
  SIDES.every((side) => Number.isInteger(areas[side]) && areas[side] >= 0 && areas[side] <= MAX_SAFE_AREA)

const isAppearance = (appearance) =>
  isObject(appearance) &&
  sameKeys(appearance, ["mode", "accent", "locale", "time_zone", "safe_areas"]) &&
  APPEARANCE_MODES.includes(appearance.mode) &&
  typeof appearance.accent === "string" &&
  ACCENT.test(appearance.accent) &&
  typeof appearance.locale === "string" &&
  appearance.locale.length <= 64 &&
  LOCALE.test(appearance.locale) &&
  typeof appearance.time_zone === "string" &&
  TIME_ZONE.test(appearance.time_zone) &&
  isSafeAreas(appearance.safe_areas)

const isPerson = (person) =>
  isObject(person) &&
  sameKeys(person, ["name"]) &&
  (person.name === null || isBoundedText(person.name, MAX_PERSON_NAME))

const CANVAS_KEYS = ["mode", "data_path", "streams", "prefs", "appearance", "person"]

// A canvas block, as the handshake reply carries it and the `canvas`
// message's args are: the open's mode, its frame's data path, the
// version's declared streams, and the desktop's preferences, appearance
// and person.
function canvasError(block, frame) {
  if (!isObject(block) || !sameKeys(block, CANVAS_KEYS)) {
    return "a canvas is exactly mode, data_path, streams, prefs, appearance and person"
  }
  if (!MODES.includes(block.mode)) return "a canvas's mode is live or validation"
  if (block.data_path !== dataPath(frame)) return "a canvas's data path is its frame's"
  if (!isStreams(block.streams)) {
    return `a canvas names at most ${MAX_STREAMS} distinct streams of name and subject`
  }
  if (!isPrefs(block.prefs)) return "a canvas's prefs are exactly a document and its revision"
  if (!isAppearance(block.appearance)) {
    return "a canvas's appearance is exactly mode, accent, locale, time_zone and safe_areas"
  }
  if (!isPerson(block.person)) return "a canvas's person is exactly a name, or none"
  return null
}

// An answer's outcome, with a reason exactly when it was refused.
const isOutcome = (args, outcomes) =>
  outcomes.includes(args.outcome) &&
  (args.outcome === "refused"
    ? typeof args.reason === "string" && REFUSAL_CLASS.test(args.reason)
    : !("reason" in args))

function pressedError(args) {
  const keys = ["control", "call", "outcome", ...(args.outcome === "refused" ? ["reason"] : [])]
  return sameKeys(args, keys) && isDesktopId(args.control) && isCall(args.call) && isOutcome(args, PRESS_OUTCOMES)
    ? null
    : "pressed is exactly a control, its call and its outcome, with a reason when refused"
}

function prefsAnswerError(args) {
  const keys = ["call", "outcome", "document", "revision", ...(args.outcome === "refused" ? ["reason"] : [])]
  return sameKeys(args, keys) &&
    isCall(args.call) &&
    isObject(args.document) &&
    isRevision(args.revision) &&
    isOutcome(args, PREFS_OUTCOMES)
    ? null
    : "prefs is exactly a call, an outcome, a document and its revision, with a reason when refused"
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
        : `installed names at most ${MAX_TINCTURES} tinctures of ref, name, icon and open`
    case "state":
      return sameKeys(args, ["state"]) && SHELL_STATES.includes(args.state) ? null : "state is live or frozen"
    case "pressed":
      return pressedError(args)
    case "prefs":
      return prefsAnswerError(args)
    case "subject":
      return isSubject(args) ? null : "subject is exactly a kind and an id"
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

// The shell's reply to an app frame's handshake read back: `{ok: true,
// credential, subject}`, the subject null when it was opened on none, or
// `{ok: false, error}`.
export function decodeFrameHandshake(reply) {
  if (!isObject(reply) || typeof reply.credential !== "string" || reply.credential === "") {
    return {ok: false, error: "a frame's handshake carries the frame credential"}
  }
  if (sameKeys(reply, ["credential"])) return {ok: true, credential: reply.credential, subject: null}
  if (sameKeys(reply, ["credential", "subject"]) && isSubject(reply.subject)) {
    return {ok: true, credential: reply.credential, subject: reply.subject}
  }
  return {ok: false, error: "a frame's handshake is exactly a credential and a subject"}
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
