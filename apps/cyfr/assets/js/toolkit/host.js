// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The toolkit's host script: the one script a canvas's page runs, admitted
// by the page's nonce. It talks to Prism over the port Prism hands it, starts
// the canvas's two workers from the page's inert worker bundle, and draws
// the trees the canvas's module answers. It loads no other script, executes
// no data and writes no markup.
//
// Its two workers come from the one bundle, each started under its role:
//
//   * the module worker imports the canvas's module and runs the `canvas`
//     API; it never holds the bearer;
//   * the streams worker holds the bearer, and each one Prism renews it
//     with, and opens only the streams the version declares
//     (`boot.streams`); it never imports a module, and it is the only
//     source of the binding records controls are labelled from.
//
// Every message is authenticated by the channel it arrives on. A binding
// record, or anything else but a tree or a failure, on the module worker's
// channel is a protocol violation, and fails the canvas. Freezing
// terminates both workers; thawing starts a new generation of both, and
// the earlier generation's messages are rejected. `failed` is posted at most
// once and is terminal.

import {HANDSHAKE, VERSION as HANDSHAKE_VERSION} from "../sdk/wire.js"
import {createControls, resolveEffect} from "./controls.js"
import {STYLESHEET, draw} from "./elements.js"
import {parseTime, parseTree} from "./tree.js"
import {
  ON_KINDS,
  ROLES,
  TOOLKIT_MAJORS,
  TO_TOOLKIT_VERBS,
  bootStreamsRefused,
  decode,
  decodeFromModule,
  decodeFromStreams,
  encode,
  isFrameId,
  isPlainObject,
  replacesRecord,
  servedPrefix,
  toModule,
  toStreams
} from "./wire.js"

// The page's inert element holding the worker bundle as one JSON string
// (`Emissary.Web.CanvasController`).
export const WORKER_ELEMENT_ID = "cyfr-toolkit-worker"

// `env` is the one seam through which the host reaches its globals:
//   window, document, Worker, Blob, URL, MessageChannel  the page's;
//   nonce     the host script's own nonce, for its stylesheet;
//   schedule  runs a callback once at the next frame (only the newest
//             pending tree is drawn per frame);
//   now, locale, timeZone  for drawing times and numbers.
export function createHost(env) {
  const {window: win, document: doc, Worker, Blob, URL, MessageChannel} = env
  const schedule = env.schedule
  const now = env.now || (() => Date.now())

  let frame = null
  let port = null
  let boot = null
  let bootAccepted = false
  let failed = false
  let frozen = false
  let readyPosted = false
  let decided = false
  let blobUrl = null
  let root = null

  let generation = 0
  let current = null

  // The shell's latest values, forwarded to every new module worker.
  const values = {}
  let installed = []
  // Binding records by feed name. Replaced, never changed in place, so a
  // tree keeps the records that stood when it was answered.
  let records = new Map()

  let pending = null
  let scheduled = false
  const surfaces = new Map()

  const controls = createControls({doc, dispatch})

  // ---- the shell ---------------------------------------------------------------

  function onWindowMessage(event) {
    const framed = win.parent !== win && win.parent !== null && win.parent !== undefined
    if (!framed || port !== null || event.source !== win.parent) return
    const data = event.data
    if (!isPlainObject(data) || data.v !== HANDSHAKE_VERSION || data.type !== HANDSHAKE) return
    if (!isFrameId(data.frame) || !event.ports || event.ports.length !== 1) return

    frame = data.frame
    port = event.ports[0]
    win.removeEventListener("message", onWindowMessage)
    port.onmessage = onPortMessage
  }

  function onPortMessage(event) {
    if (failed) return
    const decoded = decode(event.data)

    if (!decoded.ok) {
      // A boot refused for its streams alone is never waited past: the
      // version's declaration did not reach the toolkit.
      if (!bootAccepted && bootStreamsRefused(event.data, frame)) {
        bootAccepted = true
        fail("load")
      }
      return
    }

    const {verb, frame: to, args} = decoded.message
    if (to !== frame || !TO_TOOLKIT_VERBS.includes(verb)) return

    if (!bootAccepted) {
      if (verb === "boot") start(args)
      return
    }

    switch (verb) {
      case "posture":
        return value("posture", args.posture)
      case "covered":
        return value("covered", args.rects)
      case "installed":
        return value("installed", args.tinctures)
      case "state":
        return args.state === "frozen" ? freeze() : thaw()
      case "credential":
        return renew(args.credential)
      default:
        return
    }
  }

  // A renewed credential goes to the streams worker alone, and is the one a
  // thawed generation starts with.
  function renew(credential) {
    boot.credential = credential
    if (current) current.streams.postMessage(toStreams.credential(credential))
  }

  function post(verb, args) {
    port.postMessage(encode(verb, frame, args))
  }

  function start(args) {
    bootAccepted = true
    if (!TOOLKIT_MAJORS.includes(args.toolkit)) return fail("load")

    let source
    try {
      source = workerSource()
    } catch (_error) {
      return fail("load")
    }

    boot = {
      mode: args.mode,
      credential: args.credential,
      dataUrl: new URL(args.data_path, doc.URL).href,
      moduleUrl: new URL(args.module_url, doc.URL).href,
      prefixUrl: new URL(servedPrefix(args.module_url), doc.URL).href,
      streams: args.streams
    }

    mount()
    try {
      blobUrl = URL.createObjectURL(new Blob([source], {type: "text/javascript"}))
    } catch (_error) {
      return fail("load")
    }
    startWorkers()
  }

  function workerSource() {
    const element = doc.getElementById(WORKER_ELEMENT_ID)
    if (!element || element.tagName !== "SCRIPT" || element.getAttribute("type") !== "application/json") {
      throw new Error("no worker bundle")
    }
    const source = JSON.parse(element.textContent)
    if (typeof source !== "string") throw new Error("no worker bundle")
    return source
  }

  function mount() {
    const style = doc.createElement("style")
    if (env.nonce) style.setAttribute("nonce", env.nonce)
    style.textContent = STYLESHEET
    ;(doc.head || doc.documentElement).appendChild(style)

    root = doc.createElement("div")
    root.setAttribute("class", "cyfr-canvas")
    ;(doc.body || doc.documentElement).appendChild(root)
  }

  function value(kind, latest) {
    values[kind] = latest
    if (kind === "installed") installed = latest
    if (kind === "posture") root.setAttribute("data-posture", latest)
    if (current) current.module.postMessage(toModule.value(kind, latest))
  }

  // ---- workers -------------------------------------------------------------------

  // A generation that cannot be started is a canvas that cannot load:
  // whatever of it did start is stopped, and the failure is terminal.
  function startWorkers() {
    generation += 1
    const gen = generation
    const started = []

    try {
      const channel = new MessageChannel()
      const streams = new Worker(blobUrl, {name: ROLES.streams})
      started.push(streams)
      const module = new Worker(blobUrl, {name: ROLES.module})
      started.push(module)
      current = {gen, module, streams}

      streams.onmessage = (event) => onStreamsMessage(gen, event)
      streams.onerror = () => onWorkerError(gen)
      module.onmessage = (event) => onModuleMessage(gen, event)
      module.onerror = () => onWorkerError(gen)

      // The bearer and the streams worker's own channel go to the streams
      // worker alone; the module worker gets only its end of the channel
      // between the two.
      streams.postMessage(toStreams.boot(boot.credential, boot.dataUrl, boot.streams, channel.port1), [channel.port1])
      module.postMessage(toModule.boot(boot.mode, boot.moduleUrl, channel.port2), [channel.port2])
      for (const kind of ON_KINDS) {
        if (Object.prototype.hasOwnProperty.call(values, kind)) module.postMessage(toModule.value(kind, values[kind]))
      }
      renewSurfaces()
    } catch (_error) {
      current = null
      for (const worker of started) {
        worker.onmessage = null
        worker.onerror = null
        try {
          worker.terminate()
        } catch (_ignored) {
          // Already gone.
        }
      }
      fail("load")
    }
  }

  // Both workers end together, and the ports between them with them.
  function stopWorkers() {
    if (current === null) return
    const {module, streams} = current
    current = null
    pending = null
    for (const worker of [module, streams]) {
      worker.onmessage = null
      worker.onerror = null
      worker.terminate()
    }
  }

  const live = (gen) => current !== null && current.gen === gen

  function onWorkerError(gen) {
    if (live(gen)) fail("runtime")
  }

  function onModuleMessage(gen, event) {
    if (!live(gen)) return
    const message = decodeFromModule(event.data)
    // Only trees and failures travel this channel: a binding record, or
    // anything else, from the module's worker fails the canvas and labels
    // nothing.
    if (message === null) return fail("runtime")
    if (message.kind === "failed") return fail(message.stage)
    receiveTree(message.json)
  }

  function onStreamsMessage(gen, event) {
    if (!live(gen)) return
    const message = decodeFromStreams(event.data)
    if (message === null || message.kind === "lost") return fail("runtime")

    // The record is installed before its event reaches the module worker,
    // so no tree drawn from that event can overtake it.
    if (message.record !== null) install(message.record)
    current.module.postMessage(toModule.stream(message.m))
  }

  function install(record) {
    if (!replacesRecord(records.get(record.feed), record)) return
    records = new Map(records)
    records.set(record.feed, record)
  }

  function freeze() {
    if (frozen) return
    frozen = true
    stopWorkers()
  }

  function thaw() {
    if (!frozen) return
    frozen = false
    startWorkers()
  }

  function fail(stage) {
    if (failed) return
    failed = true
    stopWorkers()
    controls.disableAll()
    post("failed", {stage})
  }

  // ---- trees ---------------------------------------------------------------------

  function receiveTree(json) {
    // What a control binds to is fixed when its tree is answered.
    const answered = {json, installed, records}

    if (boot.mode === "validation" && !decided) {
      decided = true
      const parsed = json === null ? null : parseTree(json)
      if (parsed === null || !parsed.ok) return fail("tree")
      render(parsed, answered)
      return post("tree", {})
    }

    pending = answered
    if (!scheduled) {
      scheduled = true
      schedule(flush)
    }
  }

  function flush() {
    scheduled = false
    const next = pending
    pending = null
    if (next === null || failed || current === null) return

    const parsed = next.json === null ? null : parseTree(next.json)
    // An invalid tree is dropped and the last valid one stays.
    if (parsed === null || !parsed.ok) return

    render(parsed, next)
    if (boot.mode === "live" && !readyPosted) {
      readyPosted = true
      post("ready", {})
    }
  }

  function render(parsed, answered) {
    controls.reset()
    const ctx = {
      doc,
      locale: env.locale,
      timeZone: env.timeZone,
      now,
      parseTime,
      imageSource: (src) => (src.startsWith("data:") ? src : new URL(src, boot.prefixUrl).href),
      control: (node) => controls.element(node, resolveEffect(node.effect, answered)),
      surface: surfaceElement
    }

    const drawn = draw(parsed.tree, ctx)
    for (const id of [...surfaces.keys()]) if (!parsed.surfaces.includes(id)) surfaces.delete(id)
    root.replaceChildren(drawn)
  }

  // A surface keeps its canvas, and the module worker its `OffscreenCanvas`,
  // across trees while its id and size stay the same.
  function surfaceElement(node) {
    const kept = surfaces.get(node.id)
    if (kept && kept.width === node.width && kept.height === node.height) return kept.element

    const element = newSurface(node.width, node.height)
    surfaces.set(node.id, {element, width: node.width, height: node.height})
    transfer(node.id, element)
    return element
  }

  function newSurface(width, height) {
    const element = doc.createElement("canvas")
    element.setAttribute("class", "cyfr-surface")
    element.setAttribute("width", String(width))
    element.setAttribute("height", String(height))
    return element
  }

  function transfer(id, element) {
    if (current === null || typeof element.transferControlToOffscreen !== "function") return
    let offscreen
    try {
      offscreen = element.transferControlToOffscreen()
    } catch (_error) {
      return
    }
    current.module.postMessage(toModule.surface(id, offscreen), [offscreen])
  }

  // A new generation's module worker gets fresh canvases for the surfaces
  // still drawn; the earlier ones went with the workers that held them.
  function renewSurfaces() {
    for (const [id, kept] of [...surfaces.entries()]) {
      const element = newSurface(kept.width, kept.height)
      if (kept.element.parentNode) kept.element.parentNode.replaceChild(element, kept.element)
      surfaces.set(id, {element, width: kept.width, height: kept.height})
      transfer(id, element)
    }
  }

  // ---- presses -------------------------------------------------------------------

  // Called synchronously inside the press's own handler. A press while the
  // canvas is frozen, failed or not yet started is dropped.
  function dispatch(resolved) {
    if (failed || frozen || current === null || port === null) return
    if (resolved.kind === "open") post("open", {ref: resolved.ref})
    else post("press", {binding: resolved.binding, action: resolved.action})
  }

  win.addEventListener("message", onWindowMessage)

  return {onWindowMessage}
}

// In the canvas's page, the host starts itself. Its nonce is read while the
// script runs, the only time `document.currentScript` names it.
if (typeof window === "object" && window !== null && typeof document === "object" && window.document === document) {
  const script = document.currentScript
  createHost({
    window,
    document,
    Worker,
    Blob,
    URL,
    MessageChannel,
    nonce: script ? script.nonce : "",
    schedule: (callback) => {
      let done = false
      const run = () => {
        if (done) return
        done = true
        callback()
      }
      // A frame the browser does not paint gets no animation frame; the
      // timer draws its tree all the same.
      window.requestAnimationFrame(run)
      window.setTimeout(run, 250)
    }
  })
}
