// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {
  BEARER_HEADER,
  CREDENTIAL,
  HANDSHAKE,
  ROUTES,
  STREAM_CONTENT_TYPE,
  VERSION,
  bearer,
  decodeAnswer,
  decodeCredentialClosed,
  isFrameId,
  publicIdentity,
  request,
  shellMessage,
  sseParser
} from "./wire.js"

const HANDSHAKE_TIMEOUT_MS = 30000
const MAX_QUEUED_VERBS = 32

// A refusal or a failure, as a frame reads it: the sentence as the message,
// the class as `code`, and the stage when the endpoint named one.
export class CyfrError extends Error {
  constructor(message, code, stage) {
    super(message)
    this.name = "CyfrError"
    this.code = code
    if (stage) this.stage = stage
  }
}

const isPlainObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value)

const unreadable = () => new CyfrError("The endpoint's answer could not be read.", "invalid_answer")
const unreachable = () => new CyfrError("The endpoint could not be reached.", "unavailable")

// The SDK of one page. `win` is its window (its `parent` and `location`),
// `fetchFn` its fetch and `base` the URL the endpoint's routes resolve
// against (the document's).
//
// A frame's only peer for shell verbs is the shell that created it: the
// shell posts one handshake from the parent window with a MessagePort, and
// then the frame credential over that port. Every other window message is
// ignored, and a second handshake too, so no other window can hand the
// frame a port or a credential. Data goes to the endpoint under that
// credential as a bearer; it never travels over the port or in a URL.
//
// A page that is not a frame has no shell and no credential. A public
// tincture's page (`/t/…`) names itself in each request instead
// (`wire.publicIdentity/1`) and sends no bearer; any other page's data
// calls are refused here as `no_frame`.
export function createClient({win, fetchFn, base, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS}) {
  const framed = win.parent !== win && win.parent !== null && win.parent !== undefined
  const standalone = framed ? null : publicIdentity(win.location && win.location.pathname)
  let frame = null
  let port = null
  let credential = null
  // The resolver of the one credential prompt this frame has asked for and
  // the shell has not yet closed.
  let prompt = null
  const queued = []

  let settle
  const credentialArrived = new Promise((resolve) => {
    settle = resolve
  })

  function onWindowMessage(event) {
    if (!framed || port !== null || event.source !== win.parent) return
    const data = event.data
    if (!isPlainObject(data) || data.v !== VERSION || data.type !== HANDSHAKE) return
    if (!isFrameId(data.frame) || !event.ports || event.ports.length !== 1) return

    frame = data.frame
    port = event.ports[0]
    port.onmessage = onPortMessage
    for (const [verb, args] of queued.splice(0)) post(verb, args)
  }

  function onPortMessage(event) {
    const data = event.data
    if (!isPlainObject(data)) return

    const closed = decodeCredentialClosed(data, frame)
    if (closed.ok) {
      const waiting = prompt
      prompt = null
      if (waiting) waiting({saved: closed.saved})
      return
    }

    if (credential !== null) return
    if (data.v !== VERSION || data.type !== CREDENTIAL || data.frame !== frame) return
    if (typeof data.credential !== "string" || data.credential === "") return
    credential = data.credential
    settle()
  }

  function post(verb, args) {
    port.postMessage(shellMessage(verb, frame, args))
  }

  // Shell verbs before the handshake wait for it, a bounded number of them;
  // outside a frame there is no shell and they do nothing.
  function verb(name, args = {}) {
    if (!framed) return
    if (port !== null) post(name, args)
    else if (queued.length < MAX_QUEUED_VERBS) queued.push([name, args])
  }

  // Who a request is made as: the frame's bearer, or a public page's
  // identity; a page that is neither makes none.
  function identity() {
    if (standalone) return Promise.resolve({public: standalone})
    if (credential !== null) return Promise.resolve({credential})
    if (!framed) {
      return Promise.reject(new CyfrError("This page is not a frame the shell opened.", "no_frame"))
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new CyfrError("The shell did not hand this frame its credential.", "no_frame")),
        handshakeTimeoutMs
      )
      credentialArrived.then(() => {
        clearTimeout(timer)
        resolve({credential})
      })
    })
  }

  async function postRequest(kind, fields, signal) {
    const who = await identity()
    const headers = {"content-type": "application/json"}
    if (who.credential) headers[BEARER_HEADER] = bearer(who.credential)

    try {
      return await fetchFn(new URL(ROUTES[kind], base).toString(), {
        method: "POST",
        headers,
        body: JSON.stringify(request(kind, fields, who.public || null)),
        credentials: "omit",
        cache: "no-store",
        redirect: "error",
        signal
      })
    } catch (_error) {
      throw unreachable()
    }
  }

  // A JSON answer read to its value, or thrown as its refusal.
  async function answer(kind, response) {
    let body
    try {
      body = await response.json()
    } catch (_error) {
      throw unreadable()
    }

    const decoded = decodeAnswer(kind, body)
    if (decoded.ok) return decoded.value
    if (decoded.refusal) {
      const {message, class: code, stage} = decoded.refusal
      throw new CyfrError(message, code, stage)
    }
    throw unreadable()
  }

  async function send(kind, fields) {
    return answer(kind, await postRequest(kind, fields))
  }

  // The stream is the response body, read as it arrives: an EventSource
  // cannot carry the bearer. It ends when the grant's deadline passes, when
  // the endpoint closes it, or on `close()`, which aborts the request; a
  // reconnect is a new `stream` call, a new open under the gate.
  async function openStream(fields, onEvent) {
    const controller = new AbortController()
    const response = await postRequest("stream_open", fields, controller.signal)
    const type = (response.headers.get("content-type") || "").split(";")[0].trim()

    if (type !== STREAM_CONTENT_TYPE) {
      // A refusal is thrown as itself; a JSON answer that is not one is not
      // a stream.
      try {
        await answer("stream_open", response)
      } finally {
        controller.abort()
      }
      throw unreadable()
    }

    const parser = sseParser((event) => {
      try {
        onEvent(event)
      } catch (_error) {
        // The page's handler failing ends nothing: the next event still comes.
      }
    })

    let closing = false
    const closed = (async () => {
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      try {
        for (;;) {
          const {done, value} = await reader.read()
          if (done) break
          parser.push(decoder.decode(value, {stream: true}))
        }
        parser.push(decoder.decode())
      } catch (_error) {
        if (!closing) throw unreachable()
      } finally {
        parser.end()
      }
    })()

    return {
      /** Settles when the stream ends; rejects if the connection broke. */
      closed,
      /** End the stream: the request is aborted and no further event is delivered. */
      close() {
        closing = true
        controller.abort()
      }
    }
  }

  const invalid = (sentence) => Promise.reject(new CyfrError(sentence, "invalid_argument"))

  const api = {
    /** The frame id the shell handed this frame, or null before the handshake. */
    get frame() {
      return frame
    },

    /** The public tincture a top-level `/t/…` page names itself as, or null. */
    get public() {
      return standalone
    },

    /**
     * Run an operation of a component the tincture declares.
     * @param {string} ref - a component reference, e.g. "c:local.weather:1.0.0"
     * @param {string} operation - the operation's name
     * @param {object} [args] - its arguments
     * @returns {Promise<any>} the result; a refusal rejects with a CyfrError
     */
    invoke(ref, operation, args = {}) {
      if (typeof ref !== "string" || ref === "") return invalid("ref must be a component reference")
      if (typeof operation !== "string" || operation === "") return invalid("operation must be a name")
      if (!isPlainObject(args)) return invalid("args must be an object")
      return send("invoke", {ref, operation, args})
    },

    /**
     * Run a system action the tincture declares.
     * @param {string} name - the action, "tool.action"
     * @param {object} [args] - its arguments
     */
    action(name, args = {}) {
      if (typeof name !== "string" || name === "") return invalid("an action is tool.action")
      if (!isPlainObject(args)) return invalid("args must be an object")
      return send("action", {operation: name, args})
    },

    /**
     * Open a stream the tincture declares and deliver its events.
     * @param {string} name - the stream's name
     * @param {string|null} subject - a literal subject, or null for a stream that takes none
     * @param {function} onEvent - called with {id, event, data} per event
     * @returns {Promise<{close: function, closed: Promise}>} once the stream is open;
     *   a refusal rejects with a CyfrError
     */
    stream(name, subject, onEvent) {
      if (typeof name !== "string" || name === "") return invalid("stream must be a stream name")
      if (subject !== null && typeof subject !== "string") {
        return invalid("subject must be a literal subject or null")
      }
      if (typeof onEvent !== "function") return invalid("onEvent must be a function")
      return openStream({stream: name, subject}, onEvent)
    },

    /** Ask the shell to open a tincture: a tincture reference, e.g. "t:local.weather". */
    open(ref) {
      verb("open", {ref})
    },

    /** Close this frame. */
    close() {
      verb("close")
    },

    /** Set this frame's title. */
    title(title) {
      verb("title", {title})
    },

    /** Tell the shell the tincture is ready. */
    ready() {
      verb("ready")
    },

    /**
     * Ask the person for a secret through the shell's own prompt, stored in
     * the vault as the entry `name`. The frame never sees the value.
     * @param {string} name - the vault entry's name
     * @returns {Promise<{saved: boolean}>} once the prompt closes: whether an
     *   entry was saved, and nothing else. One prompt at a time: a second ask
     *   while one is open rejects as `pending`.
     */
    credential(name) {
      if (typeof name !== "string" || name === "") return invalid("a vault entry has a name")
      if (!framed) {
        return Promise.reject(new CyfrError("This page is not a frame the shell opened.", "no_frame"))
      }
      if (prompt !== null) {
        return Promise.reject(new CyfrError("A credential prompt is already open.", "pending"))
      }
      return new Promise((resolve) => {
        prompt = resolve
        verb("credential", {name})
      })
    }
  }

  return {api: Object.freeze(api), onWindowMessage}
}
