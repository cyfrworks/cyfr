// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Stand-ins for what a canvas's page gets from the browser, so the toolkit
// runs under `node --test` with no dependency: a minimal DOM, a frame's
// window, `Blob` and `URL`, a shell's port, two kinds of `Worker` (one the
// test plays itself, one running the built worker bundle in a thread), and
// a stub endpoint answering a canvas's stream route.

import {readFileSync} from "node:fs"
import {createServer} from "node:http"
import {Worker as NodeWorker} from "node:worker_threads"

import {HANDSHAKE} from "../../js/sdk/wire.js"
import {createHost} from "../../js/toolkit/host.js"
import {ROLES} from "../../js/toolkit/wire.js"

const repo = (path) => new URL(`../../../../../${path}`, import.meta.url)

// The vectors `Prima.CanvasWire`'s and `Prima.Feed`'s tests read too.
export const canvasWire = JSON.parse(readFileSync(repo("tests/fixtures/canvas_wire.json"), "utf8"))
// Only the stream payloads are read from the feed vectors.
export const feedEnvelopes = JSON.parse(readFileSync(repo("tests/fixtures/feed.json"), "utf8")).envelopes

// The built bundles, as the page embeds them.
export const builtWorker = () => readFileSync(new URL("../../../priv/static/toolkit/worker.js", import.meta.url), "utf8")

export const FRAME = "frm_8f3c2a1b9d"
export const ASSET = "ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw"
export const CREDENTIAL = "frm.v1.c2lnbmVkLWZyYW1lLWNyZWRlbnRpYWw"
export const NONCE = "bm9uY2Utb2YtdGhlLXBhZ2U"

// ---- a minimal DOM -------------------------------------------------------------

const HTML_NS = "http://www.w3.org/1999/xhtml"

class TextNode {
  constructor(data) {
    this.data = data
    this.parentNode = null
  }

  get textContent() {
    return this.data
  }
}

export class StandInElement {
  constructor(doc, tag, namespaceURI = HTML_NS) {
    this.ownerDocument = doc
    this.namespaceURI = namespaceURI
    this.localName = tag
    this.tagName = namespaceURI === HTML_NS ? tag.toUpperCase() : tag
    this.attributes = new Map()
    this.childNodes = []
    this.parentNode = null
    this.listeners = new Map()
    if (tag === "canvas" && doc.offscreen) {
      this.transferControlToOffscreen = () => {
        if (this.transferred) throw new Error("InvalidStateError")
        this.transferred = {offscreen: true, width: Number(this.getAttribute("width"))}
        return this.transferred
      }
    }
  }

  setAttribute(name, value) {
    this.attributes.set(String(name), String(value))
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null
  }

  hasAttribute(name) {
    return this.attributes.has(name)
  }

  removeAttribute(name) {
    this.attributes.delete(name)
  }

  get id() {
    return this.getAttribute("id") || ""
  }

  get classes() {
    return (this.getAttribute("class") || "").split(" ").filter(Boolean)
  }

  get children() {
    return this.childNodes.filter((node) => node instanceof StandInElement)
  }

  get textContent() {
    return this.childNodes.map((node) => node.textContent).join("")
  }

  set textContent(value) {
    for (const node of this.childNodes) node.parentNode = null
    const text = String(value)
    this.childNodes = text === "" ? [] : [new TextNode(text)]
    for (const node of this.childNodes) node.parentNode = this
  }

  // Markup is never written; a stand-in that took it would hide a renderer
  // that did.
  set innerHTML(_markup) {
    throw new Error("the toolkit wrote markup")
  }

  set outerHTML(_markup) {
    throw new Error("the toolkit wrote markup")
  }

  insertAdjacentHTML() {
    throw new Error("the toolkit wrote markup")
  }

  appendChild(node) {
    if (node.parentNode) node.parentNode.childNodes = node.parentNode.childNodes.filter((n) => n !== node)
    node.parentNode = this
    this.childNodes.push(node)
    return node
  }

  replaceChildren(...nodes) {
    for (const node of this.childNodes) node.parentNode = null
    this.childNodes = []
    for (const node of nodes) this.appendChild(node)
  }

  replaceChild(next, previous) {
    const i = this.childNodes.indexOf(previous)
    if (i === -1) throw new Error("not a child")
    if (next.parentNode) next.parentNode.childNodes = next.parentNode.childNodes.filter((n) => n !== next)
    this.childNodes[i] = next
    next.parentNode = this
    previous.parentNode = null
    return previous
  }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, [])
    this.listeners.get(type).push(listener)
  }

  removeEventListener(type, listener) {
    this.listeners.set(type, (this.listeners.get(type) || []).filter((l) => l !== listener))
  }

  // What a page's own script can do: its events are never trusted.
  dispatchEvent(event) {
    for (const listener of this.listeners.get(event.type) || []) listener.call(this, event)
    return !event.defaultPrevented
  }

  // What the browser does for the person's own input.
  fire(event) {
    for (const listener of this.listeners.get(event.type) || []) listener.call(this, event)
    return event
  }
}

// An event the browser made from the person's input.
export function trusted(type, init = {}) {
  return {
    type,
    isTrusted: true,
    repeat: false,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
    ...init
  }
}

export class StandInDocument {
  constructor({url, workerSource = null, offscreen = false}) {
    this.URL = url
    this.offscreen = offscreen
    this.documentElement = this.createElement("html")
    this.head = this.documentElement.appendChild(this.createElement("head"))
    this.body = this.documentElement.appendChild(this.createElement("body"))

    if (workerSource !== null) {
      const inert = this.createElement("script")
      inert.setAttribute("type", "application/json")
      inert.setAttribute("id", "cyfr-toolkit-worker")
      inert.textContent = JSON.stringify(workerSource)
      this.body.appendChild(inert)
    }
  }

  createElement(tag) {
    return new StandInElement(this, tag)
  }

  createElementNS(namespaceURI, tag) {
    return new StandInElement(this, tag, namespaceURI)
  }

  getElementById(id) {
    return find(this.documentElement, (element) => element.id === id)
  }
}

export function all(root, predicate) {
  const found = []
  const walk = (element) => {
    if (predicate(element)) found.push(element)
    for (const child of element.children) walk(child)
  }
  walk(root)
  return found
}

export const find = (root, predicate) => all(root, predicate)[0] || null

export const byClass = (root, name) => all(root, (element) => element.classes.includes(name))

// ---- a frame's window, its shell and its port ------------------------------------

export function frameWindow() {
  let listeners = []
  const win = {
    parent: {name: "shell"},
    addEventListener(type, listener) {
      if (type === "message") listeners.push(listener)
    },
    removeEventListener(type, listener) {
      if (type === "message") listeners = listeners.filter((l) => l !== listener)
    },
    deliver(event) {
      for (const listener of [...listeners]) listener(event)
    },
    get listening() {
      return listeners.length
    }
  }
  return win
}

// The shell's end of a canvas's port: what the toolkit posts is recorded at
// once, in the call that posts it.
export function shellPort() {
  const posted = []
  const port = {
    onmessage: null,
    postMessage(message) {
      posted.push(message)
    }
  }
  return {
    port,
    posted,
    verbs: () => posted.map((message) => message.verb),
    send: (verb, args, frame = FRAME) => port.onmessage({data: {v: 1, verb, frame, args}}),
    raw: (data) => port.onmessage({data})
  }
}

export const bootArgs = (overrides = {}) => ({
  mode: "live",
  credential: CREDENTIAL,
  data_path: `/_f/v1/o/${FRAME}/`,
  module_url: `/_s/${ASSET}/canvas.js`,
  toolkit: 1,
  streams: [{name: "feed.results", subject: "btc"}],
  ...overrides
})

// ---- Blob and URL ------------------------------------------------------------------

export function blobs() {
  const registry = new Map()
  let count = 0

  class StandInBlob {
    constructor(parts, options = {}) {
      this.parts = parts
      this.type = options.type
    }
  }

  class StandInURL extends URL {
    static createObjectURL(blob) {
      count += 1
      const url = `blob:null/stand-in-${count}`
      registry.set(url, blob)
      return url
    }

    static revokeObjectURL(url) {
      registry.delete(url)
    }
  }

  return {Blob: StandInBlob, URL: StandInURL, registry}
}

// A channel whose ports the test never uses: the workers it is handed to
// are the test's own.
export class InertChannel {
  constructor() {
    this.port1 = {side: 1, postMessage() {}}
    this.port2 = {side: 2, postMessage() {}}
  }
}

// ---- workers the test plays --------------------------------------------------------

// Each `new Worker` the host makes is recorded with what it was posted. The
// test speaks for the code inside: `emit` is a message the worker posts,
// `crash` its error event. A handler the host once set stays reachable as
// `lastOnmessage`, so a message from a worker the host has let go can be
// delivered all the same, as a late one would be.
export function playedWorkers() {
  const started = []
  // Set `refuse(name)` to make the next start of a worker of that role
  // throw, as a browser's `new Worker` does when it cannot start one.
  let refuse = () => false

  class PlayedWorker {
    constructor(url, options = {}) {
      if (refuse(options.name)) throw new Error("SecurityError: the worker could not be started")
      this.url = url
      this.name = options.name
      this.options = options
      this.posted = []
      this.terminated = false
      this._onmessage = null
      this._onerror = null
      this.lastOnmessage = null
      this.lastOnerror = null
      this.onPost = null
      started.push(this)
    }

    set onmessage(handler) {
      this._onmessage = handler
      if (handler) this.lastOnmessage = handler
    }

    get onmessage() {
      return this._onmessage
    }

    set onerror(handler) {
      this._onerror = handler
      if (handler) this.lastOnerror = handler
    }

    get onerror() {
      return this._onerror
    }

    postMessage(data, transfer = []) {
      if (this.terminated) return
      this.posted.push({data, transfer})
      if (this.onPost) this.onPost(data)
    }

    terminate() {
      this.terminated = true
    }

    emit(data) {
      if (this._onmessage) this._onmessage({data})
    }

    emitLate(data) {
      if (this.lastOnmessage) this.lastOnmessage({data})
    }

    crash() {
      if (this._onerror) this._onerror({message: "the worker died"})
    }

    crashLate() {
      if (this.lastOnerror) this.lastOnerror({message: "the worker died"})
    }
  }

  return {
    Worker: PlayedWorker,
    started,
    refuse(predicate) {
      refuse = predicate
    },
    module: () => started.filter((w) => w.name === ROLES.module).at(-1),
    streams: () => started.filter((w) => w.name === ROLES.streams).at(-1)
  }
}

// A host in a stand-in page, handshaken, with workers the test plays.
// `frames()` draws the pending tree, as the next animation frame would.
export function playedHost({offscreen = false, workerSource = "/* the worker bundle */", handshake = true} = {}) {
  const doc = new StandInDocument({url: `https://cyfr.example/_c/v1/${ASSET}/${FRAME}`, workerSource, offscreen})
  const win = frameWindow()
  const workers = playedWorkers()
  const {Blob, URL} = blobs()
  const queued = []
  const shell = shellPort()

  createHost({
    window: win,
    document: doc,
    Worker: workers.Worker,
    Blob,
    URL,
    MessageChannel: InertChannel,
    nonce: NONCE,
    schedule: (callback) => queued.push(callback),
    now: () => Date.parse("2026-10-04T12:00:00Z"),
    locale: "en-US",
    timeZone: "UTC"
  })

  if (handshake) win.deliver({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [shell.port]})

  const root = () => find(doc.body, (element) => element.classes.includes("cyfr-canvas"))

  return {
    doc,
    win,
    workers,
    shell,
    root,
    frames() {
      for (const callback of queued.splice(0)) callback()
    },
    boot(overrides) {
      shell.send("boot", bootArgs(overrides))
    },
    // The module worker answers a tree, and the frame draws it.
    render(tree, {draw = true} = {}) {
      workers.module().emit({t: "tree", json: JSON.stringify(tree)})
      if (draw) this.frames()
    },
    // The streams worker relays a feed's event with the record it makes.
    feedEvent(envelope, sub = 0) {
      const record = {
        feed: envelope.feed,
        binding: envelope.binding,
        revision: envelope.revision,
        label: envelope.label,
        actions: envelope.actions.map(({name, label}) => ({name, label}))
      }
      workers.streams().emit({
        t: "relay",
        m: {t: "event", sub, event: {id: envelope.revision, event: "feed.results", data: envelope}},
        record
      })
    },
    controls: () => byClass(root(), "cyfr-control")
  }
}

// ---- a worker's scope in the test's own thread ---------------------------------------

// A dedicated worker's global scope as the toolkit's worker code reads it,
// for that code run here rather than in a thread: what it posts to the host
// is recorded, and `deliver` hands it a message event, trusted unless said
// otherwise, as the browser's own are and a page's script's never are.
export function workerScope(name) {
  const listeners = new Map()
  const posted = []
  return {
    name,
    posted,
    postMessage(data) {
      posted.push(data)
    },
    addEventListener(type, listener) {
      listeners.set(type, [...(listeners.get(type) || []), listener])
    },
    close() {},
    deliver(data, {isTrusted = true} = {}) {
      for (const listener of listeners.get("message") || []) listener({type: "message", data, isTrusted})
    }
  }
}

// ---- the built worker bundle in a thread -------------------------------------------

// The worker scope a browser gives a dedicated worker, as far as the bundle
// reads it: `self` and its `name`, `postMessage`, event listeners, `close`,
// a message event per message from the host (trusted, as the browser's
// are), and error and unhandled-rejection events. Modules at `http` URLs
// are served from `workerData.modules`, and each import is reported on the
// control port, beside the worker's error events.
const SCOPE_SHIM = `
const {parentPort, workerData} = process.getBuiltinModule("node:worker_threads")
const {registerHooks} = process.getBuiltinModule("node:module")
const control = workerData.control
const served = /^https?:/
registerHooks({
  resolve(specifier, context, next) {
    if (served.test(specifier)) return {url: specifier, format: "module", shortCircuit: true}
    if (context.parentURL && served.test(context.parentURL)) {
      return {url: new URL(specifier, context.parentURL).href, format: "module", shortCircuit: true}
    }
    return next(specifier, context)
  },
  load(url, context, next) {
    if (!served.test(url)) return next(url, context)
    control.postMessage({t: "import", url})
    const source = workerData.modules[url]
    if (typeof source !== "string") throw new Error("404 " + url)
    return {format: "module", source, shortCircuit: true}
  }
})
const listeners = new Map()
const listening = (type) => listeners.get(type) || []
globalThis.self = globalThis
Object.defineProperty(globalThis, "name", {value: workerData.name, configurable: true})
globalThis.addEventListener = (type, listener) => listeners.set(type, [...listening(type), listener])
globalThis.removeEventListener = (type, listener) => listeners.set(type, listening(type).filter((l) => l !== listener))
globalThis.dispatchEvent = (event) => { for (const l of listening(event.type)) l(event); return true }
globalThis.postMessage = (data, transfer) => parentPort.postMessage(data, transfer)
globalThis.close = () => process.exit(0)
parentPort.on("message", (data) => {
  for (const l of listening("message")) l({type: "message", data, isTrusted: true})
})
process.on("uncaughtException", (error) => {
  for (const l of listening("error")) l({type: "error", message: String(error), isTrusted: true})
  control.postMessage({t: "error"})
})
process.on("unhandledRejection", () => {
  for (const l of listening("unhandledrejection")) l({type: "unhandledrejection", isTrusted: true})
})
`

// Workers that run the bundle the host was given in a thread each, under
// the scope shim. `terminate` ends the thread; `exited` settles when it has.
export function threadWorkers({registry, modules}) {
  const started = []
  const imports = []

  class ThreadWorker {
    constructor(url, options = {}) {
      const blob = registry.get(url)
      if (!blob) throw new Error("no such blob: " + url)
      const {port1, port2} = new MessageChannel()
      this.name = options.name
      this.options = options
      this.terminated = false
      this.onmessage = null
      this.onerror = null
      this.control = port1
      // Every message the thread posts, whether or not the host still listens.
      this.received = 0

      this.thread = new NodeWorker(SCOPE_SHIM + "\n;\n" + blob.parts.join(""), {
        eval: true,
        execArgv: [],
        workerData: {name: options.name, modules, control: port2},
        transferList: [port2]
      })
      this.exited = new Promise((resolve) => this.thread.once("exit", resolve))
      this.thread.on("message", (data) => {
        this.received += 1
        if (this.onmessage) this.onmessage({data})
      })
      this.thread.on("error", () => this.onerror && this.onerror({message: "the worker died"}))
      port1.on("message", (message) => {
        if (message.t === "import") imports.push({worker: this, url: message.url})
        if (message.t === "error" && this.onerror) this.onerror({message: "uncaught"})
      })
      started.push(this)
    }

    postMessage(data, transfer = []) {
      if (!this.terminated) this.thread.postMessage(data, transfer)
    }

    terminate() {
      this.terminated = true
      this.control.close()
      this.thread.terminate()
    }
  }

  return {
    Worker: ThreadWorker,
    started,
    imports,
    stopAll: () => within(Promise.all(started.map((w) => (w.terminate(), w.exited))), "the threads' exit")
  }
}

// A host in a stand-in page at `origin`, running the built worker bundle
// in threads, with modules served at their `http` URLs.
export function threadedHost({origin, modules}) {
  const doc = new StandInDocument({url: `${origin}/_c/v1/${ASSET}/${FRAME}`, workerSource: builtWorker()})
  const win = frameWindow()
  const {Blob, URL, registry} = blobs()
  const workers = threadWorkers({registry, modules})
  const shell = shellPort()

  createHost({
    window: win,
    document: doc,
    Worker: workers.Worker,
    Blob,
    URL,
    MessageChannel,
    nonce: NONCE,
    schedule: (callback) => setTimeout(callback, 0),
    locale: "en-US",
    timeZone: "UTC"
  })
  win.deliver({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [shell.port]})

  const root = () => find(doc.body, (element) => element.classes.includes("cyfr-canvas"))
  return {doc, shell, workers, root, text: () => (root() ? root().textContent : "")}
}

export const moduleUrl = (origin, file) => `${origin}/_s/${ASSET}/${file}`

// ---- a stub endpoint ------------------------------------------------------------------

// Records each request to the canvas's stream route and answers it from
// `answer(request)`: `{status, body}`, or `{stream}` whose function writes
// the `text/event-stream` answer itself.
export async function stubEndpoint(answer) {
  const requests = []
  const responses = new Set()

  const server = createServer((req, res) => {
    let raw = ""
    req.on("data", (chunk) => (raw += chunk))
    req.on("end", () => {
      let body = null
      try {
        body = JSON.parse(raw)
      } catch (_error) {
        body = raw
      }
      const request = {method: req.method, url: req.url, headers: req.headers, body}
      requests.push(request)
      responses.add(res)
      res.on("close", () => responses.delete(res))
      const {status = 200, body: answerBody, stream} = answer(request)
      if (stream) {
        res.writeHead(200, {"content-type": "text/event-stream; charset=utf-8"})
        stream(res, request)
      } else {
        res.writeHead(status, {"content-type": "application/json"})
        res.end(JSON.stringify(answerBody))
      }
    })
  })

  await within(new Promise((resolve) => server.listen(0, "127.0.0.1", resolve)), "the stub endpoint's listen")
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    requests,
    close() {
      for (const res of responses) res.destroy()
      return within(new Promise((resolve) => server.close(resolve)), "the stub endpoint's close")
    }
  }
}

export const sse = ({id, event, data}) => `id: ${id}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`

// `promise`, or a failure naming `what` once `ms` pass without it settling:
// no test waits on anything without a bound.
export const WAIT_MS = 5000

export function within(promise, what, ms = WAIT_MS) {
  let timer
  const deadline = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not settle within ${ms} ms`)), ms)
  })
  return Promise.race([Promise.resolve(promise), deadline]).finally(() => clearTimeout(timer))
}

// Wait for a condition, in bounded steps.
export async function eventually(check, {tries = 1000, stepMs = 10} = {}) {
  for (let i = 0; i < tries; i++) {
    if (check()) return
    await new Promise((resolve) => setTimeout(resolve, stepMs))
  }
  throw new Error("the condition never held")
}

export const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
