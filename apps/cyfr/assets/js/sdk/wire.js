// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The wire between a tincture's frame, the endpoint and the shell, as
// `Prima.TinctureWire` defines it: the frame posts `invoke` and `action`
// requests to the endpoint under its credential, reads its streams over one
// WebSocket, its stream connection, and sends shell verbs to the shell over
// its MessagePort. `tests/fixtures/tincture_wire.json` pins both sides; the
// SDK's tests read it.
//
// Beside it, the messages the shell sends the frame over the port: its port
// and its credential, an app's subject, and to a canvas its open
// (`canvas`), what the shell tells it (`posture`, `covered`, `installed`,
// `state`) and its answers (`pressed`, `prefs`), and to any frame the
// answers to its request (`requested`, `decided`). They pass only between
// the shell's bridge and the SDK, so they are defined here, once; the
// frame's are pinned by the fixture's `canvas` section, whose `handshake`
// rows are the server's reply the bridge reads them from.

export const VERSION = 1

export const BEARER_HEADER = "authorization"

export const ROUTES = Object.freeze({
  invoke: "/_f/v1/invoke",
  action: "/_f/v1/action"
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
  "settings",
  "request"
])

// The verbs only a canvas sends: from any other frame the SDK sends none
// of them, and the shell drops them.
export const CANVAS_VERBS = Object.freeze(["press", "failed", "grant", "prefs", "ask", "settings"])

// The verbs a frame sends for the person, which the shell honours only
// within moments of the person's own input, one per input: a canvas's, and
// `request`, which any frame sends.
export const PERSON_VERBS = Object.freeze(["open", "press", "grant", "prefs", "ask", "settings", "request"])

// The kinds of subject an app is opened on (`Prima.Manifest.Tincture`).
export const SUBJECT_KINDS = Object.freeze(["run", "thread", "schedule", "component", "file"])

// What a control's press, and a write of the preferences, come to.
export const PRESS_OUTCOMES = Object.freeze(["accepted", "refused", "cancelled"])
export const PREFS_OUTCOMES = Object.freeze(["saved", "stale", "refused", "cancelled"])
// Why a press or a write was cancelled, when the answer says: `too_soon`,
// sent while the activation its input gave was spent already.
export const CANCEL_REASONS = Object.freeze(["too_soon"])
// What a request comes to, as `decided` says: approved and run, refused
// (`declined` by the person, or a refusal's class) or cancelled, perhaps
// naming why: `too_soon`, `busy` (another request of the frame waited),
// `expired` or `dismissed`.
export const REQUEST_OUTCOMES = Object.freeze(["approved", "refused", "cancelled"])
export const REQUEST_CANCEL_REASONS = Object.freeze(["too_soon", "busy", "expired", "dismissed"])

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
// An operation's name, `tool.action` (`Prima.Manifest.Tincture`), and the
// operation a request for a grant names instead.
const OPERATION = /^[a-z][a-z0-9_-]{0,62}\.[a-z][a-z0-9_-]{0,62}$/
const GRANT_OPERATION = "grant"
// `Prima.TinctureWire.request_id?/1`.
const REQUEST_ID = /^req_[A-Za-z0-9_-]{16,64}$/
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

const isGrantArgs = (args) =>
  isObject(args) && sameKeys(args, ["ref"]) && typeof args.ref === "string" && COMPONENT_REF.test(args.ref)

// What a request may ask for by its form: `grant` with exactly a component
// reference, or an operation's name with an object of arguments. Which the
// shell asks the person for is the shell's.
export const isRequest = (operation, args) =>
  operation === GRANT_OPERATION
    ? isGrantArgs(args)
    : typeof operation === "string" && OPERATION.test(operation) && isObject(args)

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

// A refusal's projection, as a frame may read one: exactly a class, a
// sentence and a stage. Which refusal classes exist is the server's
// (`Prima.Refusal`); the frame reads the class as a name.
const isRefusal = (error) =>
  isObject(error) &&
  sameKeys(error, ["class", "message", "stage"]) &&
  typeof error.class === "string" &&
  error.class !== "" &&
  typeof error.message === "string" &&
  (error.stage === "admission" || error.stage === "execution")

// An answer read back: {ok: true, value} for a result, {ok: false, refusal}
// for a refusal the frame may read, and {ok: false, invalid: true} for
// anything else.
export function decodeAnswer(kind, body) {
  const invalid = {ok: false, invalid: true}
  if (!isObject(body) || body.v !== VERSION || !(kind in ROUTES)) return invalid
  if (sameKeys(body, ["v", "ok", "result"]) && body.ok === true) return {ok: true, value: body.result}
  if (sameKeys(body, ["v", "ok", "error"]) && body.ok === false && isRefusal(body.error)) {
    const {class: cls, message, stage} = body.error
    return {ok: false, refusal: {class: cls, message, stage}}
  }
  return invalid
}

// ---- the stream connection ---------------------------------------------------

// An app's stream connection; a canvas's is `socketPath/1`.
export const SOCKET_PATH = "/_f/v1/socket"

// The WebSocket close codes a stream connection ends with
// (`Prima.TinctureWire.close_code/1`).
export const CLOSE_CODES = Object.freeze({unreadable: 4400, too_big: 1009, replaced: 4409, idle: 1000})

// The name of the last event an open stream's handler hears when the
// endpoint ended it with a refusal, its data the refusal's projection.
export const REFUSAL_EVENT = "refusal"

// What a canvas's stream handler hears beside its changes, by the delivery
// contract (`Compendium.Canvas.catalog/1`): its picture is whole
// (`snapshot`), a fresh picture follows (`resync`), it cannot be read now
// (`unavailable`), it is older than its bound (`stale`), or its grant no
// longer covers it (`denied`). The last three, and `live` and `ended`, are
// the states a canvas's stream handle is in.
export const DELIVERY_EVENTS = Object.freeze(["snapshot", "resync", "unavailable", "stale", "denied"])
export const STREAM_STATES = Object.freeze(["live", "unavailable", "stale", "denied", "ended"])

// The refusal classes that leave a subscription unanswered: those a request
// is answered with a server error for. A subscription refused with one
// rejects as `unavailable`, as one that got no answer does, and may open if
// asked for again later.
export const NO_ANSWER_CLASSES = Object.freeze([
  "cancelled",
  "corrupt",
  "internal",
  "setup_required",
  "timeout",
  "uncertain",
  "unavailable"
])

// The messages a frame sends over its stream connection: a subscription,
// numbered by the frame, under the newest frame credential; and its end.
export function subscribeMessage(sub, credential, stream, subject) {
  return {v: VERSION, type: "subscribe", sub, credential, stream, subject}
}

export function unsubscribeMessage(sub) {
  return {v: VERSION, type: "unsubscribe", sub}
}

const isEvent = ({stream, subject, id}) =>
  typeof stream === "string" &&
  (subject === null || typeof subject === "string") &&
  (id === null || (Number.isInteger(id) && id >= 0))

// An ISO 8601 time, as the endpoint stamps a picture.
const isTime = (at) => typeof at === "string" && at !== "" && !Number.isNaN(Date.parse(at))

// What the endpoint sends over the stream connection read back: `{ok: true,
// message}` for exactly a `subscribed`, an `event`, a `snapshot` or a
// `stale` with its `at`, a `resync` or an `ended`, the last with `error`, a
// refusal's projection, when the endpoint said why; `{ok: false}` for
// anything else. A subscription's number has a call's grammar
// (`Prima.TinctureWire.subscription?/1`).
export function decodeConnectionMessage(message) {
  if (!isObject(message) || message.v !== VERSION || !isCall(message.sub)) return {ok: false}
  const head = ["v", "type", "sub"]
  let read
  switch (message.type) {
    case "subscribed":
      read = sameKeys(message, head)
      break
    case "event":
      read = sameKeys(message, [...head, "stream", "subject", "id", "data"]) && isEvent(message)
      break
    case "snapshot":
    case "stale":
      read = sameKeys(message, [...head, "at"]) && isTime(message.at)
      break
    case "resync":
      read = sameKeys(message, head)
      break
    case "ended":
      read = sameKeys(message, head) || (sameKeys(message, [...head, "error"]) && isRefusal(message.error))
      break
    default:
      read = false
  }
  return read ? {ok: true, message} : {ok: false}
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
      if (typeof args.page !== "string" || !PAGE.test(args.page)) return "settings names a page by its key"
      if (sameKeys(args, ["page"])) return null
      return sameKeys(args, ["page", "ref"]) && typeof args.ref === "string" && SUBJECT_ID.test(args.ref)
        ? null
        : "settings names a page by its key, and perhaps a record on it by its id"
    case "request":
      return sameKeys(args, ["operation", "args", "call"]) && isRequest(args.operation, args.args) && isCall(args.call)
        ? null
        : "request carries exactly grant or an operation, its args and its call"
    case "failed":
      return sameKeys(args, ["stage"]) && STAGES.includes(args.stage) ? null : "failed names a stage"
    case "grant":
      return isGrantArgs(args) ? null : "grant names a component reference"
    default:
      return keys.length === 0 ? null : verb + " takes no arguments"
  }
}

// ---- a canvas ----------------------------------------------------------------

// The one data route under a canvas open's data path, and the path's
// prefix: a canvas's credential reaches only `<data path>socket`.
const DATA_PREFIX = "/_f/v1/o/"
const SOCKET_ROUTE = "socket"

// A canvas open's data path, the one its page's policy names in
// `connect-src`: `/_f/v1/o/<frame>/`.
export function dataPath(frame) {
  if (!isFrameId(frame)) throw new TypeError("a frame id is 8 to 64 URL-safe characters")
  return DATA_PREFIX + frame + "/"
}

// A canvas open's stream connection, under its data path.
export function socketPath(frame) {
  return dataPath(frame) + SOCKET_ROUTE
}

// A canvas open is `live` (the person's canvas) or `validation` (a new
// version trialled in a hidden frame).
export const MODES = Object.freeze(["live", "validation"])

// Shell to a frame, over its port: a canvas's open, what the shell tells
// it, its answers, the answers to any frame's request, and an app's
// subject.
export const TO_FRAME_VERBS = Object.freeze([
  "canvas",
  "posture",
  "covered",
  "installed",
  "state",
  "pressed",
  "prefs",
  "requested",
  "decided",
  "subject"
])

// What the shell tells a canvas, held as the latest of each and posted
// again after its handshake.
export const TOLD_VERBS = Object.freeze(["posture", "covered", "installed", "state"])

// The shell's answers, each posted once under the call it answers, by the
// verb each answers: a request is answered `requested` once the person is
// asked, then `decided`, or `decided` alone when it ended before; a
// canvas's write `prefs`; and its press of a control `pressed`, or as a
// request is when the person approves the control's operation first. Only
// a request's answers reach a frame that is no canvas.
export const ANSWER_OF = Object.freeze({
  press: Object.freeze(["pressed", "requested", "decided"]),
  prefs: Object.freeze(["prefs"]),
  request: Object.freeze(["requested", "decided"])
})
export const ANSWER_VERBS = Object.freeze([...new Set(Object.values(ANSWER_OF).flat())])

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

// An answer's outcome, with a reason exactly when it was refused (the
// refusal's class, or a request's `declined`) and, when it was cancelled,
// perhaps one of `cancelReasons`.
const isOutcome = (args, outcomes, cancelReasons = CANCEL_REASONS) => {
  if (!outcomes.includes(args.outcome)) return false
  if (args.outcome === "refused") return typeof args.reason === "string" && REFUSAL_CLASS.test(args.reason)
  if (args.outcome === "cancelled") return !("reason" in args) || cancelReasons.includes(args.reason)
  return !("reason" in args)
}

const withReason = (args, keys) => ("reason" in args ? [...keys, "reason"] : keys)

function pressedError(args) {
  const keys = withReason(args, ["control", "call", "outcome"])
  return sameKeys(args, keys) && isDesktopId(args.control) && isCall(args.call) && isOutcome(args, PRESS_OUTCOMES)
    ? null
    : "pressed is exactly a control, its call and its outcome, with a reason when refused or cancelled too soon"
}

function prefsAnswerError(args) {
  const keys = withReason(args, ["call", "outcome", "document", "revision"])
  return sameKeys(args, keys) &&
    isCall(args.call) &&
    isObject(args.document) &&
    isRevision(args.revision) &&
    isOutcome(args, PREFS_OUTCOMES)
    ? null
    : "prefs is exactly a call, an outcome, a document and its revision, with a reason when refused or cancelled too soon"
}

function decidedError(args) {
  return sameKeys(args, withReason(args, ["call", "outcome"])) &&
    isCall(args.call) &&
    isOutcome(args, REQUEST_OUTCOMES, REQUEST_CANCEL_REASONS)
    ? null
    : "decided is exactly a call and its outcome, with a reason when refused and perhaps when cancelled"
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
    case "requested":
      return sameKeys(args, ["call", "request"]) &&
        isCall(args.call) &&
        typeof args.request === "string" &&
        REQUEST_ID.test(args.request)
        ? null
        : "requested is exactly a call and its request's id"
    case "decided":
      return decidedError(args)
    case "subject":
      return isSubject(args) ? null : "subject is exactly a kind and an id"
    default:
      return "unknown verb"
  }
}

// A message the shell posts a frame read back: `{ok: true, message}` for
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

// The message the bridge posts a frame for `verb`; one the wire refuses
// throws, with a sentence that names no value it carries.
export function toFrameMessage(verb, frame, args) {
  const message = {v: VERSION, verb, frame, args}
  const decoded = decodeToFrame(message)
  if (!decoded.ok) throw new TypeError("not a message to a frame: " + decoded.error)
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
