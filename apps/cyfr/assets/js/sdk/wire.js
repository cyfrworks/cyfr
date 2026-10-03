// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The wire between a tincture's frame, the endpoint and the shell, as
// `Prima.TinctureWire` defines it: the frame posts `invoke`, `action` and
// `stream_open` requests to the endpoint under its credential, and shell
// verbs to the shell over its MessagePort. `tests/fixtures/tincture_wire.json`
// pins both sides; the SDK's tests read it.
//
// Beside it, the two messages the shell sends the frame to hand it its port
// and its credential. They pass only between the shell's bridge and the SDK,
// so they are defined here, once.

export const VERSION = 1

export const BEARER_HEADER = "authorization"

export const ROUTES = Object.freeze({
  invoke: "/_f/v1/invoke",
  action: "/_f/v1/action",
  stream_open: "/_f/v1/stream"
})

export const VERBS = Object.freeze(["open", "close", "title", "ready", "credential"])

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

const isObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value)

const only = (object, keys) => Object.keys(object).every((key) => keys.includes(key))

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
      return keys.length === 1 && typeof args.ref === "string" && TINCTURE_REF.test(args.ref)
        ? null
        : "open names a tincture reference"
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
    default:
      return keys.length === 0 ? null : verb + " takes no arguments"
  }
}
