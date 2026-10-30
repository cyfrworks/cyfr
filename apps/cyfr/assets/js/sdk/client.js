// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {
  BEARER_HEADER,
  CANVAS_EVENTS,
  CANVAS_VERBS,
  CREDENTIAL,
  HANDSHAKE,
  ROUTES,
  STREAM_CONTENT_TYPE,
  VERSION,
  bearer,
  decodeAnswer,
  decodeCredentialClosed,
  decodeToFrame,
  isFrameId,
  pairKey,
  publicIdentity,
  request,
  shellMessage,
  sseParser,
  streamPath
} from "./wire.js"

const HANDSHAKE_TIMEOUT_MS = 30000
const MAX_QUEUED_VERBS = 32

// No failure: the two messages, whole, that browsers report when a
// ResizeObserver callback resizes what it observes (Chromium, Firefox and
// WebKit today, with its period; Chromium before, without one). An error
// whose message merely contains either is the page's own.
const BENIGN_ERRORS = Object.freeze([
  "ResizeObserver loop completed with undelivered notifications.",
  "ResizeObserver loop limit exceeded"
])

// The value a page hears, through `on`, of what the shell told its canvas.
const heard = (verb, args) =>
  verb === "covered" ? args.rects : verb === "installed" ? args.tinctures : verb === "posture" ? args.posture : args.state

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

// A stream open the endpoint gave no answer on: it answered a server
// error (5xx), whatever its body said, so the open may succeed later. It
// rejects as an unreachable endpoint does, `unavailable` with no stage,
// keeping the endpoint's own sentence when it sent a refusal. A read
// replays safely; an invoke or an action is not read this way, since a
// server error's class says what became of its run.
const unanswered = (status, rejection) =>
  status >= 500
    ? new CyfrError(rejection.code === "invalid_answer" ? unreachable().message : rejection.message, "unavailable")
    : rejection

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
// The shell renews the credential while the frame runs and sends each new
// one over the same port: a later request is made under the newest, and a
// request or a stream already sent keeps the one it was sent with.
//
// A page that is not a frame has no shell and no credential. A public
// tincture's page (`/t/…`) names itself in each request instead
// (`wire.publicIdentity/1`) and sends no bearer; any other page's data
// calls are refused here as `no_frame`.
//
// A canvas's page learns it is one from the first message on its port,
// `canvas`, which comes before its credential and names its open's mode,
// data path and declared streams; any other frame's first message is its
// credential. Until the first of the two, shell verbs wait, since what
// reaches the shell depends on which the page is. A canvas's streams go to
// its data path's stream route, only the pairs it declares and only once
// the shell has told it `state` `live`; what the shell tells it after
// (`posture`, `covered`, `installed`, `state`) reaches the page through
// `on`. A canvas reports its own failure once: an uncaught error or
// unhandled rejection before `ready()` as `failed` at stage `load`, after
// it at stage `runtime`, and a canvas that failed to load sends no `ready`.
// Any other page reports none, and sends no `press`.
export function createClient({win, fetchFn, base, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS}) {
  const framed = win.parent !== win && win.parent !== null && win.parent !== undefined
  const standalone = framed ? null : publicIdentity(win.location && win.location.pathname)
  let frame = null
  let port = null
  let credential = null
  // `canvas` or `frame` once the port's first message says which the page
  // is, null before.
  let kind = null
  // A canvas's open: `{streams}`, its declared streams as pair keys.
  let canvas = null
  let readyCalled = false
  // The stage of the one failure this page reports, once it has failed.
  let failure = null
  // The resolver of the one credential prompt this frame has asked for and
  // the shell has not yet closed.
  let prompt = null
  const queued = []
  const latest = new Map()
  const handlers = new Map(CANVAS_EVENTS.map((event) => [event, new Set()]))
  // The resolvers of a canvas's stream opens waiting for it to be shown.
  const unshown = []

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

    const told = decodeToFrame(data)
    if (told.ok) {
      if (told.message.frame === frame) onTold(told.message)
      return
    }

    if (data.v !== VERSION || data.type !== CREDENTIAL || data.frame !== frame) return
    if (typeof data.credential !== "string" || data.credential === "") return
    const first = credential === null
    credential = data.credential
    if (kind === null) known("frame")
    if (first) settle()
  }

  // A canvas's open is taken once, before the credential; what the shell
  // tells a canvas after it is held as the latest of its kind and handed
  // to the page.
  function onTold({verb: told, args}) {
    if (told === "canvas") {
      if (kind !== null) return
      canvas = {streams: new Set(args.streams.map(pairKey))}
      return known("canvas")
    }
    if (kind !== "canvas") return

    const value = heard(told, args)
    latest.set(told, value)
    if (told === "state" && value === "live") for (const resolve of unshown.splice(0)) resolve()
    for (const entry of handlers.get(told)) deliver(told, entry, value)
  }

  // Settles once the shell's last word on this canvas is `live`. The
  // bridge tells a canvas its state right after its credential, so one
  // opened hidden is known to be hidden before anything is sent.
  function shown() {
    return latest.get("state") === "live" ? Promise.resolve() : new Promise((resolve) => unshown.push(resolve))
  }

  // Each handler is called on its own, so one that throws stops no other,
  // and its error is the page's own uncaught error.
  function deliver(event, entry, value) {
    queueMicrotask(() => {
      if (handlers.get(event).has(entry)) entry.handler(value)
    })
  }

  // The page is now known to be a canvas or another frame: the verbs it
  // asked for meanwhile go, in order.
  function known(which) {
    kind = which
    for (const [name, args] of queued.splice(0)) send(name, args)
  }

  function post(name, args) {
    port.postMessage(shellMessage(name, frame, args))
  }

  // What reaches the shell: a canvas that failed to load sends no `ready`,
  // and a page that is no canvas sends no `press` and no `failed`.
  function send(name, args) {
    if (kind === "canvas" ? name === "ready" && failure === "load" : CANVAS_VERBS.includes(name)) return
    post(name, args)
  }

  // Shell verbs before the page's kind is known wait for it, a bounded
  // number of them, though never its one failure; outside a frame there is
  // no shell and they do nothing.
  function verb(name, args = {}) {
    if (!framed) return
    if (kind !== null) send(name, args)
    else if (queued.length < MAX_QUEUED_VERBS || name === "failed") queued.push([name, args])
  }

  // An uncaught error or unhandled rejection of the page (the window's
  // `error` and `unhandledrejection`). Nothing of it leaves but its stage.
  function onPageError(event) {
    if (failure !== null) return
    if (event && BENIGN_ERRORS.includes(event.message)) return
    failure = readyCalled ? "runtime" : "load"
    verb("failed", {stage: failure})
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

  // Where a request goes: its kind's route, but a canvas's streams go to
  // its open's stream route, and only the pairs the canvas declares.
  function routeOf(requestKind, fields) {
    if (canvas === null || requestKind !== "stream_open") return ROUTES[requestKind]
    if (!canvas.streams.has(pairKey({name: fields.stream, subject: fields.subject}))) {
      throw new CyfrError("This canvas does not declare that stream.", "forbidden", "admission")
    }
    return streamPath(frame)
  }

  async function postRequest(requestKind, fields, signal) {
    let who = await identity()
    const path = routeOf(requestKind, fields)
    if (canvas !== null && requestKind === "stream_open") {
      // A hidden canvas reads nothing: it opens once shown, and the refresh it opens with covers what it missed.
      await shown()
      who = await identity()
    }
    const headers = {"content-type": "application/json"}
    if (who.credential) headers[BEARER_HEADER] = bearer(who.credential)

    try {
      return await fetchFn(new URL(path, base).toString(), {
        method: "POST",
        headers,
        body: JSON.stringify(request(requestKind, fields, who.public || null)),
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
  async function answer(requestKind, response) {
    let body
    try {
      body = await response.json()
    } catch (_error) {
      throw unreadable()
    }

    const decoded = decodeAnswer(requestKind, body)
    if (decoded.ok) return decoded.value
    if (decoded.refusal) {
      const {message, class: code, stage} = decoded.refusal
      throw new CyfrError(message, code, stage)
    }
    throw unreadable()
  }

  async function call(requestKind, fields) {
    return answer(requestKind, await postRequest(requestKind, fields))
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
      // a stream; and a server error is no answer on the open.
      let rejection = unreadable()
      try {
        await answer("stream_open", response)
      } catch (error) {
        rejection = error
      } finally {
        controller.abort()
      }
      throw unanswered(response.status, rejection)
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
    // A broken stream the page never waits on is no failure of the page.
    closed.catch(() => {})

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
      return call("invoke", {ref, operation, args})
    },

    /**
     * Run a system action the tincture declares.
     * @param {string} name - the action, "tool.action"
     * @param {object} [args] - its arguments
     */
    action(name, args = {}) {
      if (typeof name !== "string" || name === "") return invalid("an action is tool.action")
      if (!isPlainObject(args)) return invalid("args must be an object")
      return call("action", {operation: name, args})
    },

    /**
     * Open a stream the tincture declares and deliver its events. On a
     * canvas it opens on the canvas's data path, and a pair the canvas does
     * not declare is refused as `forbidden` before anything is sent; asked
     * for while the canvas is hidden, it sends nothing and opens once the
     * canvas is shown.
     * @param {string} name - the stream's name
     * @param {string|null} subject - a literal subject, or null for a stream that takes none
     * @param {function} onEvent - called with {id, event, data} per event
     * @returns {Promise<{close: function, closed: Promise}>} once the stream is open;
     *   a refusal rejects with a CyfrError of its class. An open the endpoint
     *   gave no answer on (it could not be reached, the connection broke or
     *   timed out, or it answered a server error) rejects `unavailable`, and
     *   may succeed if opened again later; opened again after any other
     *   refusal, it meets the same refusal until something changes.
     */
    stream(name, subject, onEvent) {
      if (typeof name !== "string" || name === "") return invalid("stream must be a stream name")
      if (subject !== null && typeof subject !== "string") {
        return invalid("subject must be a literal subject or null")
      }
      if (typeof onEvent !== "function") return invalid("onEvent must be a function")
      return openStream({stream: name, subject}, onEvent)
    },

    /**
     * Ask the shell to open a tincture: a tincture reference, e.g. "t:local.weather".
     * From a canvas the shell acts on it only within moments of the person's
     * own input, never from a script on its own.
     */
    open(ref) {
      verb("open", {ref})
    },

    /**
     * On a canvas, press a feed's action: the binding id a `feed.results`
     * event carries, and the action's name. The shell acts on it only within
     * moments of the person's own input, never from a script on its own, and
     * only for a feed the canvas declares.
     */
    press(binding, action) {
      verb("press", {binding, action})
    },

    /**
     * On a canvas, ask the person to grant a component: a component
     * reference, e.g. "c:local.openai". The person confirms in CYFR's own
     * prompt, never in the canvas. The shell acts on it only within moments
     * of the person's own input, never from a script on its own, and only
     * for a component the athanor has installed.
     */
    grant(ref) {
      verb("grant", {ref})
    },

    /**
     * On a canvas, hear what the shell tells it: `installed` (the installed
     * tinctures, `[{ref, name, icon, open}]`), `posture` (`desk` or
     * `hand`), `covered` (the rects of it, `{x, y, width, height}` in its
     * own pixels, that the shown apps cover) or `state` (`live` or
     * `frozen`). The latest value, if one has come, is handed to a new
     * handler first.
     * @returns {function} stops the handler hearing more
     */
    on(event, handler) {
      if (!CANVAS_EVENTS.includes(event)) throw new TypeError("cyfr.on takes installed, posture, covered or state")
      if (typeof handler !== "function") throw new TypeError("cyfr.on takes a function")
      const entry = {handler}
      handlers.get(event).add(entry)
      if (latest.has(event)) deliver(event, entry, latest.get(event))
      return () => {
        handlers.get(event).delete(entry)
      }
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
      readyCalled = true
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

  return {api: Object.freeze(api), onWindowMessage, onPageError}
}
