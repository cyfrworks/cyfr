// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The toolkit's worker bundle: one classic script the host starts twice from
// the page's inert copy of it, each time under a role it fixes at start
// (`ROLES`), before any module is imported.
//
//   * The module worker imports the canvas's module, the toolkit's only
//     dynamic `import()`, and calls its default export with the `canvas`
//     object. It holds no bearer: it asks the streams worker for a stream by
//     name and subject, over the channel the host handed both.
//   * The streams worker holds the bearer and opens a stream only for a
//     `(name, subject)` pair the version declares (`boot.streams`), at the
//     canvas's data path with `Prima.TinctureWire`'s stream request. It
//     never imports a module. A feed's events go to the module worker
//     through the host, each with the binding record it makes, so the host
//     installs the record first.
//
// Each worker takes its boot from the host alone: the first trusted message
// on its own global channel, never a port. After its boot the streams worker
// reads only a renewed credential there.

import {
  BEARER_HEADER,
  STREAM_CONTENT_TYPE,
  bearer,
  decodeAnswer as decodeHttpAnswer,
  request as httpRequest,
  sseParser
} from "../sdk/wire.js"
import {
  FEED_STREAM,
  ON_KINDS,
  ROLES,
  STREAM_ROUTE,
  answer,
  decodeAnswer,
  decodeRequest,
  decodeToModule,
  decodeToStreams,
  fromModule,
  fromStreams,
  pairKey,
  recordFromEnvelope,
  request
} from "./wire.js"

// A refusal or a failure, as a canvas's module reads it, in the shape the
// SDK's `CyfrError` has.
export class CanvasError extends Error {
  constructor(message, code, stage) {
    super(message)
    this.name = "CyfrError"
    this.code = code
    if (stage) this.stage = stage
  }
}

const invalid = (sentence) => Promise.reject(new CanvasError(sentence, "invalid_argument"))

// A worker that closed itself would end unseen by the host, which learns of
// a worker's end only through its error event; the module worker's scope
// therefore has no `close` once the toolkit has started.
function sealClose(scope) {
  for (let object = scope; object !== null; object = Object.getPrototypeOf(object)) {
    const descriptor = Object.getOwnPropertyDescriptor(object, "close")
    if (descriptor && descriptor.configurable) delete object.close
  }
}

// ---- the module worker -----------------------------------------------------------

export function startModuleWorker(scope, {importModule}) {
  // Captured before the module runs, so nothing it replaces reaches the host.
  const post = scope.postMessage.bind(scope)
  const listen = scope.addEventListener.bind(scope)
  sealClose(scope)

  let booted = false
  let port = null
  let failed = false
  let nextSub = 0
  const subs = new Map()
  const latest = new Map()
  const handlers = new Map(ON_KINDS.map((kind) => [kind, []]))
  const surfaces = new Map()
  const waiting = new Map()

  function fail(stage) {
    if (failed) return
    failed = true
    post(fromModule.failed(stage))
  }

  function call(fn, value) {
    try {
      fn(value)
    } catch (_error) {
      fail("runtime")
    }
  }

  listen("error", () => fail("runtime"))
  listen("unhandledrejection", () => fail("runtime"))
  listen("message", (event) => {
    if (event.isTrusted !== true) return
    const message = decodeToModule(event.data)
    if (message === null) return

    if (!booted) {
      if (message.t === "boot") boot(message)
      return
    }

    if (message.t === "surface") return surface(message.id, message.canvas)
    if (message.t === "stream") return onAnswer(message.m)
    if (handlers.has(message.t)) {
      latest.set(message.t, message.value)
      for (const fn of handlers.get(message.t)) call(fn, message.value)
    }
  })

  function boot(message) {
    booted = true
    port = message.port
    port.onmessage = (event) => {
      const m = decodeAnswer(event.data)
      if (m !== null) onAnswer(m)
    }

    let loading
    try {
      loading = importModule(message.module_url)
    } catch (_error) {
      return fail("load")
    }
    Promise.resolve(loading).then(load, () => fail("load"))
  }

  function load(namespace) {
    let main
    let result
    try {
      main = namespace && namespace.default
      if (typeof main !== "function") return fail("load")
      result = main(canvas)
    } catch (_error) {
      return fail("load")
    }
    Promise.resolve(result).then(undefined, () => fail("runtime"))
  }

  function surface(id, offscreen) {
    surfaces.set(id, offscreen)
    const resolvers = waiting.get(id) || []
    waiting.delete(id)
    for (const resolve of resolvers) resolve(offscreen)
  }

  function onAnswer(m) {
    const entry = subs.get(m.sub)
    if (!entry) return

    switch (m.t) {
      case "opened":
        if (entry.open) return
        entry.open = true
        return entry.resolve(entry.handle)
      case "refused":
        subs.delete(m.sub)
        return entry.reject(new CanvasError(m.message, m.code, m.stage))
      case "event":
        if (entry.open) call(entry.onEvent, m.event)
        return
      case "closed":
        subs.delete(m.sub)
        if (!entry.open) return entry.reject(new CanvasError("The stream could not be opened.", m.error || "unavailable"))
        if (m.error) return entry.end(new CanvasError("The endpoint could not be reached.", m.error))
        return entry.end(null)
      default:
        return
    }
  }

  function openStream(name, subject, onEvent) {
    const sub = nextSub++
    return new Promise((resolve, reject) => {
      let end
      const closed = new Promise((settle, broke) => {
        end = (error) => (error ? broke(error) : settle())
      })
      // A broken stream the module never waits on fails nothing.
      closed.catch(() => {})

      const handle = Object.freeze({
        closed,
        close() {
          if (!subs.has(sub)) return
          subs.delete(sub)
          port.postMessage(request.close(sub))
          end(null)
        }
      })

      subs.set(sub, {onEvent, resolve, reject, end, handle, open: false})
      port.postMessage(request.open(sub, name, subject))
    })
  }

  const canvas = Object.freeze({
    /** Draw `tree`: an element tree of toolkit major 1. */
    render(tree) {
      let json = null
      try {
        json = JSON.stringify(tree)
      } catch (_error) {
        json = null
      }
      post(fromModule.tree(typeof json === "string" ? json : null))
    },

    /**
     * Open a stream the canvas declares and deliver its events, as the SDK's
     * `cyfr.stream`: resolves to `{closed, close()}` once open, calls
     * `onEvent({id, event, data})` for each event, and rejects with the
     * refusal's `code` and `stage`.
     */
    stream(name, subject, onEvent) {
      if (typeof name !== "string" || name === "") return invalid("stream must be a stream name")
      if (subject !== null && typeof subject !== "string") return invalid("subject must be a literal subject or null")
      if (typeof onEvent !== "function") return invalid("onEvent must be a function")
      return openStream(name, subject, onEvent)
    },

    /** Call `fn` with each `posture`, `covered` or `installed` value, the latest one first. */
    on(kind, fn) {
      if (!handlers.has(kind)) throw new TypeError("canvas.on takes posture, covered or installed")
      if (typeof fn !== "function") throw new TypeError("canvas.on takes a function")
      handlers.get(kind).push(fn)
      if (latest.has(kind)) {
        const value = latest.get(kind)
        queueMicrotask(() => call(fn, value))
      }
    },

    /** The `OffscreenCanvas` of a drawn `surface` element, once it is drawn. */
    surface(id) {
      if (surfaces.has(id)) return Promise.resolve(surfaces.get(id))
      return new Promise((resolve) => {
        waiting.set(id, [...(waiting.get(id) || []), resolve])
      })
    }
  })
}

// ---- the streams worker ----------------------------------------------------------

export function startStreamsWorker(scope, {fetchFn}) {
  const post = scope.postMessage.bind(scope)
  let booted = false
  let credential = null
  let streamUrl = null
  let declared = new Set()
  let port = null
  const subs = new Map()

  // The boot is the first trusted message on the worker's own channel; after
  // it, only a renewed credential is read there.
  scope.addEventListener("message", (event) => {
    if (event.isTrusted !== true) return
    if (booted) return renewed(decodeToStreams(event.data))
    const boot = decodeToStreams(event.data)
    if (boot === null || boot.t !== "boot") return

    booted = true
    credential = boot.credential
    streamUrl = boot.data_url + STREAM_ROUTE
    declared = new Set(boot.streams.map(pairKey))
    port = boot.port
    port.onmessage = (message) => onRequest(message.data)
    // The module worker's end of the channel closing means that worker is
    // gone; where the platform says so, the host hears of it.
    if (typeof port.addEventListener === "function") port.addEventListener("close", () => post(fromStreams.lost()))
  })

  // A renewed credential opens every later stream, and every stream already
  // open is opened again under it: the new connection takes over once the
  // endpoint answers it, and only then is the old one let go, so a stream
  // outlives the deadline of the bearer it was first opened under. The
  // module worker hears nothing of it but the events the new connection
  // carries, its refresh among them. The endpoint counts the new connection
  // against the old one's slot until the old one ends, so a move fits the
  // frame's stream cap. A takeover the endpoint refuses leaves the old
  // connection as it was, ending at its own deadline.
  function renewed(message) {
    if (message === null || message.t !== "credential") return
    credential = message.credential
    for (const sub of subs.values()) if (sub.opened) takeOver(sub)
  }

  function onRequest(data) {
    const req = decodeRequest(data)
    if (req === null) return

    if (req.kind === "close") {
      const sub = subs.get(req.sub)
      if (sub) {
        subs.delete(req.sub)
        sub.closing = true
        sub.attempt.controller.abort()
        if (sub.pending) sub.pending.controller.abort()
      }
      return
    }

    // A feed's answers go through the host, which installs each event's
    // binding record before the module worker receives the event.
    const viaHost = req.name === FEED_STREAM
    const send = (m, record = null) => (viaHost ? post(fromStreams.relay(m, record)) : port.postMessage(m))

    if (subs.has(req.sub)) return send(answer.refused(req.sub, "invalid_argument", "That stream is already open."))
    if (!declared.has(pairKey(req))) {
      return send(answer.refused(req.sub, "forbidden", "This canvas does not declare that stream.", "admission"))
    }

    const sub = {req, send, viaHost, attempt: attempt(), pending: null, opened: false, closing: false}
    subs.set(req.sub, sub)
    open(sub).catch(() => {
      // Whatever broke, the stream ends here and its reader hears of it.
      sub.attempt.controller.abort()
      if (sub.pending) sub.pending.controller.abort()
      if (subs.get(req.sub) === sub) subs.delete(req.sub)
      if (!sub.closing) send(answer.closed(req.sub, "unavailable"))
      sub.closing = true
    })
  }

  // One connection of a stream, under the credential held when it is made.
  const attempt = () => ({controller: new AbortController(), credential})

  // A stream that ends takes a replacement still being opened with it: a
  // subscription its reader has heard end holds no connection at all.
  function ended(sub, error) {
    if (subs.get(sub.req.sub) === sub) subs.delete(sub.req.sub)
    if (sub.pending) {
      sub.pending.controller.abort()
      sub.pending = null
    }
    if (!sub.closing) sub.send(answer.closed(sub.req.sub, error))
  }

  async function open(sub) {
    const first = sub.attempt
    const answered = await connect(sub.req, first)
    if (!answered.ok) {
      if (subs.get(sub.req.sub) === sub) subs.delete(sub.req.sub)
      if (!sub.closing) sub.send(answer.refused(sub.req.sub, answered.code, answered.message, answered.stage))
      return
    }

    if (sub.closing) return first.controller.abort()
    sub.opened = true
    sub.send(answer.opened(sub.req.sub))
    // A credential renewed while this connection was being made opens it
    // again under the newest.
    if (first.credential !== credential) takeOver(sub)
    await pump(sub, first, answered.response)
  }

  function takeOver(sub) {
    if (sub.pending) sub.pending.controller.abort()
    const next = attempt()
    sub.pending = next
    connect(sub.req, next)
      .then((answered) => {
        if (sub.pending !== next) return
        sub.pending = null
        if (!answered.ok || sub.closing || subs.get(sub.req.sub) !== sub) return next.controller.abort()
        const previous = sub.attempt
        sub.attempt = next
        previous.controller.abort()
        if (next.credential !== credential) takeOver(sub)
        return pump(sub, next, answered.response)
      })
      .catch(() => {
        next.controller.abort()
        if (sub.pending === next) sub.pending = null
        if (sub.attempt === next) ended(sub, "unavailable")
      })
  }

  // The stream request under `conn`'s credential: `{ok: true, response}` for
  // a stream, or the refusal its reader hears.
  async function connect(req, conn) {
    let response
    try {
      response = await fetchFn(streamUrl, {
        method: "POST",
        headers: {"content-type": "application/json", [BEARER_HEADER]: bearer(conn.credential)},
        body: JSON.stringify(httpRequest("stream_open", {stream: req.name, subject: req.subject})),
        credentials: "omit",
        cache: "no-store",
        redirect: "error",
        signal: conn.controller.signal
      })
    } catch (_error) {
      return {ok: false, code: "unavailable", message: "The endpoint could not be reached.", stage: null}
    }

    const type = (response.headers.get("content-type") || "").split(";")[0].trim()
    if (type === STREAM_CONTENT_TYPE) return {ok: true, response}

    let body = null
    try {
      body = await response.json()
    } catch (_error) {
      body = null
    }
    conn.controller.abort()
    const decoded = decodeHttpAnswer("stream_open", body)
    if (decoded.refusal) {
      return {ok: false, code: decoded.refusal.class, message: decoded.refusal.message, stage: decoded.refusal.stage}
    }
    return {ok: false, code: "invalid_answer", message: "The endpoint's answer could not be read.", stage: null}
  }

  // A connection's events reach the stream's reader only while it is the
  // stream's own; one taken over or let go says nothing more.
  async function pump(sub, conn, response) {
    const own = () => sub.attempt === conn && !sub.closing

    // A record is made only here: from an event of a feed's stream this
    // worker opened for a declared pair, and only for that pair's feed,
    // whatever feed the event's own data names.
    const parser = sseParser((event) => {
      if (!own()) return
      const record = sub.viaHost ? recordFromEnvelope(event.data, sub.req.subject) : null
      sub.send(answer.event(sub.req.sub, event), record)
    })

    const decoder = new TextDecoder()
    try {
      // An answer with no body is a stream that broke as it opened.
      const reader = response.body.getReader()
      for (;;) {
        const {done, value} = await reader.read()
        if (done) break
        parser.push(decoder.decode(value, {stream: true}))
      }
      parser.push(decoder.decode())
      if (sub.attempt === conn) ended(sub, null)
    } catch (_error) {
      conn.controller.abort()
      if (sub.attempt === conn) ended(sub, "unavailable")
    } finally {
      parser.end()
    }
  }
}

// In a worker the host started, the bundle starts the role it was started
// under; anywhere else it does nothing.
if (typeof window === "undefined" && typeof self === "object" && self !== null) {
  if (self.name === ROLES.module) {
    // The one dynamic import in the toolkit.
    startModuleWorker(self, {importModule: (url) => import(url)})
  } else if (self.name === ROLES.streams) {
    startStreamsWorker(self, {fetchFn: self.fetch.bind(self)})
  }
}
