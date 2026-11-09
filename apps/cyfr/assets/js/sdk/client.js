// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import {
  ANSWER_OF,
  BEARER_HEADER,
  CANVAS_EVENTS,
  CLOSE_CODES,
  CANVAS_VERBS,
  CREDENTIAL,
  HANDSHAKE,
  NO_ANSWER_CLASSES,
  REFUSAL_EVENT,
  ROUTES,
  SOCKET_PATH,
  VERSION,
  bearer,
  decodeAnswer,
  decodeConnectionMessage,
  decodeCredentialClosed,
  decodeToFrame,
  isDesktopId,
  isFrameId,
  isPressValue,
  isRequest,
  isSubject,
  pairKey,
  publicIdentity,
  request,
  shellMessage,
  socketPath,
  subscribeMessage,
  unsubscribeMessage
} from "./wire.js"

const HANDSHAKE_TIMEOUT_MS = 30000
const MAX_QUEUED_VERBS = 32
// How long a canvas's stream that lost its connection, or that the
// endpoint ended for want of an answer, waits before it opens again: a
// second, doubling with each try that brings no picture, to half a minute.
const REOPEN_FIRST_MS = 1000
const REOPEN_MOST_MS = 30000
// How long a press of a control, a write of the preferences or a request
// waits for the shell's answer before it settles as uncertain: the shell
// answers at once, so only a socket that went away leaves one unanswered.
// Once the shell says the person is asked (`requested`), it waits for
// their decision as long as a person may take.
const ANSWER_TIMEOUT_MS = 30000
const DECISION_TIMEOUT_MS = 10 * 60 * 1000

// `Prima.Feed.binding_id?/1` and `Prima.Feed.name?/1`: a press whose first
// argument is a binding id presses a feed's action.
const BINDING_ID = /^feed_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const ACTION_NAME = /^[a-z0-9][a-z0-9-]{0,47}$/

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

const UNCERTAIN = Object.freeze({outcome: "refused", reason: "uncertain"})
const CANCELLED = Object.freeze({outcome: "cancelled"})

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
const noFrame = () => new CyfrError("This page is not a frame the shell opened.", "no_frame")

// How a subscription the endpoint ended before it opened rejects: as its
// refusal, but as `unavailable` with no stage, keeping the endpoint's
// sentence, when it got no answer, so it may open if asked for again later.
// A read replays safely; an invoke or an action is not read this way, since
// a server error's class says what became of its run.
const refusedOpen = (error) =>
  error === null
    ? unreachable()
    : NO_ANSWER_CLASSES.includes(error.class)
      ? new CyfrError(error.message, "unavailable")
      : new CyfrError(error.message, error.class, error.stage)

const SOCKET_SCHEMES = Object.freeze({"http:": "ws:", "https:": "wss:"})

// The SDK of one page. `win` is its window (its `parent` and `location`),
// `fetchFn` its fetch, `socketFn(url)` opens its WebSocket and `base` is
// the URL the endpoint's routes resolve against (the document's).
//
// A frame's only peer for shell verbs is the shell that created it: the
// shell posts one handshake from the parent window with a MessagePort, and
// then the frame credential over that port. Every other window message is
// ignored, and a second handshake too, so no other window can hand the
// frame a port or a credential. Requests go to the endpoint under that
// credential as a bearer, and each subscription to a stream carries it in
// its `subscribe` message; it never travels over the port or in a URL.
//
// The shell renews the credential while the frame runs and sends each new
// one over the same port: a later request or subscription is made under
// the newest, and one already sent keeps the one it was sent with.
//
// A frame reads every stream it opens over one WebSocket, its stream
// connection, opened by the first subscription ready to send and reused
// until it closes; the next subscription after that opens a new one. Each
// subscription is numbered by the client, and the endpoint's answers name
// it by that number. A closed connection ends every subscription it
// carried.
//
// A page that is not a frame has no shell and no credential. A public
// tincture's page (`/t/…`) names itself in each request instead
// (`wire.publicIdentity/1`) and sends no bearer, and opens no stream; any
// other page's data calls are refused here as `no_frame`.
//
// A canvas's page learns it is one from the first message on its port,
// `canvas`, which comes before its credential and names its open's mode,
// data path and declared streams, and the desktop's preferences,
// appearance and person (`desktop`, and the `desktop` event); any other
// frame's first message is its credential, or the subject it was opened
// on before it (`subject`).
//
// A canvas presses a control it declares (`press`) and writes its
// preferences (`prefs`), and any frame asks the person for an act
// (`request`), each sent with a call number of its own and answered by the
// shell, or its bridge, with its outcome and that number: the promise each
// answers settles with the answer carrying its number, whatever order
// answers arrive in, and one never answered settles as refused `uncertain`
// after a while, never tried again; a request, or a press the person
// approves first, waits longer once the shell says the person is asked. A
// write's answer carries the document and the revision the shell now
// holds, which `desktop` and its event follow, so a stale write is
// answered with the document to write over. Until the first of the two, shell verbs wait, since what
// reaches the shell depends on which the page is. A canvas's streams go
// over its data path's stream connection, only the pairs it declares and
// only once the shell has told it `state` `live`; what the shell tells it after
// (`posture`, `covered`, `installed`, `state`) reaches the page through
// `on`. A canvas reports its own failure once: an uncaught error or
// unhandled rejection before `ready()` as `failed` at stage `load`, and a
// canvas that failed to load sends no `ready`. One after `ready()` is no
// failure, since a page error after the canvas started never costs the
// person their canvas; nothing is reported. Any other page reports none,
// and sends no `press`.
export function createClient({
  win,
  fetchFn,
  socketFn = (url) => new win.WebSocket(url),
  base,
  handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS
}) {
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
  // The stage of the one failure this page reports, `load`, once it has
  // failed.
  let failure = null
  // The resolver of the one credential prompt this frame has asked for and
  // the shell has not yet closed.
  let prompt = null
  const queued = []
  const latest = new Map()
  const handlers = new Map(CANVAS_EVENTS.map((event) => [event, new Set()]))
  // The resolvers of a canvas's subscriptions waiting for it to be shown.
  const unshown = []
  // The stream connection while it is not closed, and the number the next
  // subscription takes.
  let connection = null
  let nextSubscription = 1
  // A canvas's preferences, appearance and person, from its open and the
  // shell's answers to its writes; an app's subject.
  let desktop = null
  let subject = null
  // The presses, writes and requests waiting for their answer, by the call
  // number each was sent with and its answers carry back, with the answer
  // verbs it hears.
  let nextCall = 1
  const calls = new Map()

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
    if (told === "subject") {
      if (kind === "canvas") return
      subject = Object.freeze({kind: args.kind, id: args.id})
      if (kind === null) return
      latest.set("subject", subject)
      for (const entry of handlers.get("subject")) deliver("subject", entry, subject)
      return
    }
    if (told === "canvas") {
      if (kind !== null) return
      canvas = {streams: new Set(args.streams.map(pairKey))}
      desktop = {prefs: args.prefs, appearance: args.appearance, person: args.person}
      known("canvas")
      return tellDesktop()
    }
    if (told === "requested") return asked(args.call, args.request)
    if (told === "decided") return answered(told, args.call, answerOf(args))
    if (kind !== "canvas") return
    if (told === "pressed") return answered(told, args.call, answerOf(args))
    if (told === "prefs") {
      // Only the answer to a write still waiting moves the preferences: one
      // to a call answered already or never made would roll them back.
      const settle = take(told, args.call)
      if (!settle) return
      desktop = {...desktop, prefs: {document: args.document, revision: args.revision}}
      tellDesktop()
      return settle(answerOf(args))
    }

    const value = heard(told, args)
    latest.set(told, value)
    if (told === "state" && value === "live") for (const resolve of unshown.splice(0)) resolve()
    for (const entry of handlers.get(told)) deliver(told, entry, value)
  }

  function tellDesktop() {
    const value = desktopValue()
    latest.set("desktop", value)
    for (const entry of handlers.get("desktop")) deliver("desktop", entry, value)
  }

  function desktopValue() {
    return desktop === null ? null : Object.freeze({...desktop})
  }

  // An answer as the page reads it: the outcome, its reason when refused,
  // and for a write the document and revision the shell holds.
  function answerOf(args) {
    const answer = {outcome: args.outcome}
    if ("reason" in args) answer.reason = args.reason
    if ("document" in args) Object.assign(answer, {document: args.document, revision: args.revision})
    return Object.freeze(answer)
  }

  // The call `call` waiting for a `verb` answer settles with `answer`; an
  // answer to a call that waits no longer, or that hears no such verb,
  // settles nothing.
  function answered(verb, call, answer) {
    const settle = take(verb, call)
    if (settle) settle(answer)
  }

  function take(verb, call) {
    const waiting = calls.get(call)
    if (!waiting || !waiting.answers.includes(verb)) return null
    calls.delete(call)
    return waiting.settle
  }

  // The person is asked for the call `call`, as the request `request`: it
  // waits on for their decision. Only the first such answer counts.
  function asked(call, request) {
    const waiting = calls.get(call)
    if (!waiting || !waiting.answers.includes("requested") || waiting.asked) return
    waiting.asked = true
    waiting.requested(request)
  }

  // A press, a write or a request is sent with a call number of its own and
  // waits, a bounded while, for the answer that carries it back;
  // `onRequested` hears the request's id once the person is asked, or null
  // once it settles without.
  function awaitAnswer(name, args, onRequested = () => {}) {
    const call = nextCall++
    return new Promise((resolve) => {
      let timer = null
      const settle = (answer) => {
        clearTimeout(timer)
        onRequested(null)
        resolve(answer)
      }
      const wait = (ms) => {
        clearTimeout(timer)
        timer = setTimeout(() => {
          calls.delete(call)
          settle(UNCERTAIN)
        }, ms)
      }
      wait(ANSWER_TIMEOUT_MS)
      calls.set(call, {
        answers: ANSWER_OF[name],
        asked: false,
        requested: (request) => {
          wait(DECISION_TIMEOUT_MS)
          onRequested(request)
        },
        settle
      })
      verb(name, {...args, call})
    })
  }

  // A request's handle: its decision, carrying `requested`, the request's
  // id once the person is asked, or null when it was decided without.
  function requestHandle(decision, requested) {
    decision.requested = requested
    return decision
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
  // and a page that is no canvas sends none of a canvas's verbs, so a
  // press of a control or a write it asked for did not run.
  function send(name, args) {
    if (kind === "canvas" ? name === "ready" && failure === "load" : CANVAS_VERBS.includes(name)) {
      if (name === "press" && "control" in args) answered("pressed", args.call, CANCELLED)
      if (name === "prefs") answered("prefs", args.call, CANCELLED)
      return
    }
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
  // `error` and `unhandledrejection`) before `ready()`. Nothing of it
  // leaves but its stage.
  function onPageError(event) {
    if (failure !== null || readyCalled) return
    if (event && BENIGN_ERRORS.includes(event.message)) return
    failure = "load"
    verb("failed", {stage: failure})
  }

  // Who a request is made as: the frame's bearer, or a public page's
  // identity; a page that is neither makes none.
  function identity() {
    if (standalone) return Promise.resolve({public: standalone})
    if (credential !== null) return Promise.resolve({credential})
    if (!framed) return Promise.reject(noFrame())

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

  async function call(requestKind, fields) {
    const who = await identity()
    const headers = {"content-type": "application/json"}
    if (who.credential) headers[BEARER_HEADER] = bearer(who.credential)

    let response
    try {
      response = await fetchFn(new URL(ROUTES[requestKind], base).toString(), {
        method: "POST",
        headers,
        body: JSON.stringify(request(requestKind, fields, who.public || null)),
        credentials: "omit",
        cache: "no-store",
        redirect: "error"
      })
    } catch (_error) {
      throw unreachable()
    }

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

  // A subscription is `waiting` until it may be sent, `asked` once it is on
  // the connection (its `subscribe` sent as soon as the connection opens),
  // `open` once the endpoint answers `subscribed`, and `over` once it has
  // ended, been refused or been closed. A canvas's stream that has opened
  // once is the page's until it is denied, ends or is closed: a lost
  // connection, or an end for want of an answer, makes it `waiting` again
  // and it opens again under a new number (`reopen`), its `delivery` the
  // state the page reads (`STREAM_STATES`).
  function subscribe(name, subject, onEvent) {
    const subscription = {
      name,
      subject,
      onEvent,
      state: "waiting",
      held: null,
      number: null,
      sent: false,
      delivery: "live",
      opened: false,
      tries: 0,
      timer: null
    }
    const opened = new Promise((resolve, reject) => Object.assign(subscription, {resolve, reject}))
    const closed = new Promise((resolve, reject) => (subscription.closed = {resolve, reject}))
    // A broken stream the page never waits on is no failure of the page.
    closed.catch(() => {})
    const close = () => unsubscribe(subscription)
    subscription.handle = {
      /** Settles when the stream ends; rejects if the connection broke. */
      closed,
      /** End the stream: nothing more of it is delivered. */
      close,
      /**
       * On a canvas, the stream's state: `live`, `unavailable` (it opens
       * again at the time its last `unavailable` event named), `stale`,
       * `denied` or `ended`.
       */
      get state() {
        return subscription.delivery
      }
    }
    sendable(subscription).then(
      () => attach(subscription),
      (error) => refuse(subscription, error)
    )
    opened.close = close
    return opened
  }

  // Resolves once `subscription` may be sent: the frame holds its
  // credential and, on a canvas, the pair is declared and the canvas shown.
  async function sendable({name, subject}) {
    if (!framed) throw noFrame()
    await identity()
    if (canvas === null) return
    if (!canvas.streams.has(pairKey({name, subject}))) {
      throw new CyfrError("This canvas does not declare that stream.", "forbidden", "admission")
    }
    // A hidden canvas reads nothing: it subscribes once shown, and the refresh it opens with covers what it missed.
    await shown()
  }

  function refuse(subscription, error) {
    if (subscription.state !== "waiting") return
    if (subscription.opened) return deny(subscription, {class: error.code, message: error.message, stage: error.stage || "admission"})
    subscription.state = "over"
    subscription.reject(error)
  }

  function attach(subscription) {
    if (subscription.state !== "waiting") return
    let held
    try {
      held = connect()
    } catch (_error) {
      if (subscription.opened) return reopen(subscription)
      return refuse(subscription, unreachable())
    }
    subscription.state = "asked"
    subscription.held = held
    subscription.number = nextSubscription++
    held.subscriptions.set(subscription.number, subscription)
    if (held.open) ask(held, subscription)
  }

  // The stream connection, opened at the frame's own path: a canvas's under
  // its data path, any other frame's the app path.
  function connect() {
    if (connection !== null) return connection
    const url = new URL(canvas !== null ? socketPath(frame) : SOCKET_PATH, base)
    url.protocol = SOCKET_SCHEMES[url.protocol] || url.protocol
    const held = {socket: socketFn(url.toString()), open: false, subscriptions: new Map()}
    held.socket.onopen = () => {
      held.open = true
      for (const subscription of held.subscriptions.values()) ask(held, subscription)
    }
    held.socket.onmessage = (event) => onConnectionMessage(held, event.data)
    held.socket.onclose = (event) => lost(held, event && event.code)
    held.socket.onerror = () => lost(held)
    connection = held
    return held
  }

  // Sent under the newest credential, read now.
  function ask(held, subscription) {
    const {number, name, subject} = subscription
    subscription.sent = true
    held.socket.send(JSON.stringify(subscribeMessage(number, credential, name, subject)))
  }

  // What the endpoint says of a subscription the connection still carries;
  // an answer that does not read, or names no such subscription, moves
  // nothing.
  function onConnectionMessage(held, data) {
    let message
    try {
      message = JSON.parse(data)
    } catch (_error) {
      return
    }
    const decoded = decodeConnectionMessage(message)
    const subscription = decoded.ok ? held.subscriptions.get(decoded.message.sub) : undefined
    if (subscription === undefined) return

    if (message.type === "subscribed") {
      if (subscription.state !== "asked") return
      subscription.state = "open"
      subscription.delivery = "live"
      // Opened again, its picture replaces the one the page holds.
      if (subscription.opened) return told(subscription, "resync")
      subscription.opened = true
      subscription.resolve(subscription.handle)
    } else if (message.type === "event") {
      if (subscription.state === "open") hear(subscription, heardEvent(message))
    } else if (message.type === "ended") {
      held.subscriptions.delete(subscription.number)
      end(subscription, "error" in message ? message.error : null, null)
    } else if (subscription.state === "open" && canvas !== null) {
      // `snapshot`, `resync` and `stale`, a canvas-readable stream's alone.
      if (message.type === "snapshot") Object.assign(subscription, {delivery: "live", tries: 0})
      if (message.type === "stale") subscription.delivery = "stale"
      told(subscription, message.type, null, "at" in message ? message.at : null)
    }
  }

  // An event as the page hears it; on a canvas, with its change's revision
  // and time (the delivery contract, `Compendium.Canvas.catalog/1`).
  function heardEvent({id, stream, data}) {
    if (canvas === null) return {id, event: stream, data}
    const revision = isPlainObject(data) && Number.isInteger(data.revision) ? data.revision : null
    const at = isPlainObject(data) && typeof data.at === "string" ? data.at : null
    return {id, event: stream, data, revision, at}
  }

  // A delivery event the page hears, `name` one of `DELIVERY_EVENTS`.
  function told(subscription, name, data = null, at = null) {
    hear(subscription, {id: null, event: name, data, revision: null, at})
  }

  // Every subscription a closed connection carried ends with it. A canvas's
  // stream opens again, unless the endpoint closed the connection for what
  // this frame sent or for a newer connection of the same frame, which
  // opening again would only repeat.
  function lost(held, code) {
    if (connection === held) connection = null
    const carried = [...held.subscriptions.values()]
    held.subscriptions.clear()
    const final = [CLOSE_CODES.unreadable, CLOSE_CODES.too_big, CLOSE_CODES.replaced].includes(code)
    for (const subscription of carried) {
      if (final && subscription.opened) {
        // Open, or opening again: it ends as a broken stream does.
        Object.assign(subscription, {state: "over", delivery: "ended"})
        subscription.closed.reject(unreachable())
      } else {
        end(subscription, null, unreachable())
      }
    }
  }

  // A subscription ends by the endpoint's `ended`, `error` its refusal or
  // null, or as its connection broke, `broke` the rejection. One not yet
  // open is refused; an open one's handler hears the endpoint's refusal as
  // its last event, and then its `closed` settles. A canvas's stream that
  // opened once opens again when no answer ended it (a broken connection,
  // a refusal of a class `NO_ANSWER_CLASSES` names), is denied for any
  // other refusal, and ends when the endpoint ended it with none.
  function end(subscription, error, broke) {
    const was = subscription.state
    subscription.state = "over"
    if (canvas !== null && subscription.opened) {
      if (broke !== null || (error !== null && NO_ANSWER_CLASSES.includes(error.class))) return reopen(subscription)
      if (error === null && was === "asked") return reopen(subscription)
      if (error !== null) return deny(subscription, error)
      subscription.delivery = "ended"
      return subscription.closed.resolve()
    }
    if (was === "asked") return subscription.reject(broke || refusedOpen(error))
    subscription.delivery = "ended"
    if (error !== null) hear(subscription, {id: null, event: REFUSAL_EVENT, data: error})
    if (broke) subscription.closed.reject(broke)
    else subscription.closed.resolve()
  }

  // The frame's grant no longer covers the stream: the page hears `denied`,
  // the refusal as its data, and the stream ends; it opens again only when
  // the page asks under a new grant.
  function deny(subscription, error) {
    subscription.state = "over"
    subscription.delivery = "denied"
    told(subscription, "denied", error)
    subscription.closed.resolve()
  }

  // A canvas's stream with no answer: the page hears `unavailable` with
  // when it opens again, and it opens then under a new number, its fresh
  // picture announced by `resync`.
  function reopen(subscription) {
    const wait = Math.min(REOPEN_FIRST_MS * 2 ** subscription.tries, REOPEN_MOST_MS)
    subscription.tries += 1
    Object.assign(subscription, {state: "waiting", held: null, number: null, sent: false, delivery: "unavailable"})
    told(subscription, "unavailable", {retry_at: new Date(Date.now() + wait).toISOString()})
    subscription.timer = setTimeout(() => {
      subscription.timer = null
      if (subscription.state !== "waiting") return
      sendable(subscription).then(
        () => attach(subscription),
        (error) => refuse(subscription, error)
      )
    }, wait)
  }

  function hear(subscription, event) {
    try {
      subscription.onEvent(event)
    } catch (_error) {
      // The page's handler failing ends nothing: the next event still comes.
    }
  }

  // Ends `subscription` from the page's side, at once: the endpoint is told
  // only of one it was asked for.
  function unsubscribe(subscription) {
    const was = subscription.state
    if (was === "over") return
    subscription.state = "over"
    subscription.delivery = "ended"
    if (subscription.timer !== null) clearTimeout(subscription.timer)
    if (subscription.held !== null) {
      subscription.held.subscriptions.delete(subscription.number)
      if (subscription.sent) subscription.held.socket.send(JSON.stringify(unsubscribeMessage(subscription.number)))
    }
    if (was === "open" || subscription.opened) subscription.closed.resolve()
    else subscription.reject(new CyfrError("The stream was closed before it opened.", "cancelled"))
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
     * On a canvas, its desktop as the shell told it: `prefs` (the person's
     * preferences document for this canvas and its `revision`),
     * `appearance` (`mode`, `accent`, `locale`, `time_zone`, `safe_areas`)
     * and `person` (`name`, their display name, or null). Null until the
     * canvas's open arrives; `cyfr.on("desktop", …)` hears it then and
     * after each write.
     */
    get desktop() {
      return desktopValue()
    },

    /**
     * On an app opened on a subject, that subject, `{kind, id}`, or null;
     * an app opened again on another hears it through `cyfr.on("subject")`.
     */
    get subject() {
      return subject
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
     * Open a stream the tincture declares and deliver its events, over the
     * frame's one stream connection. On a canvas, a pair the canvas does
     * not declare is refused as `forbidden` before anything is sent; asked
     * for while the canvas is hidden, it sends nothing and opens once the
     * canvas is shown. A page that is not a frame, a public page among
     * them, opens no stream: it is refused as `no_frame`.
     * @param {string} name - the stream's name
     * @param {string|null} subject - a literal subject, or null for a stream that takes none
     * @param {function} onEvent - called with {id, event, data} per event; a stream the
     *   endpoint ends with a refusal delivers it last, as {id: null, event: "refusal", data}.
     *   On a canvas, a stream keeps the delivery contract (`Compendium.Canvas.catalog`):
     *   each event also carries the change's `revision` and `at`, and the handler hears
     *   `snapshot` (`at`, its picture is whole), `resync` (a fresh picture follows and
     *   replaces it), `stale` (`at`, the picture's time), `unavailable` (`data.retry_at`,
     *   when the SDK opens it again, after a lost connection or an end for want of an
     *   answer) and `denied` (`data`, the refusal; the stream ended), each as
     *   {id: null, event, data, revision: null, at}
     * @returns {Promise<{close: function, closed: Promise, state: string}>} once the stream is open,
     *   carrying `close()` itself, the handle's: closed before it opened, the
     *   promise rejects `cancelled`. A refusal rejects with a CyfrError of
     *   its class. An open that got no answer (the connection could not
     *   open, or broke or closed before an answer, or the endpoint could not
     *   answer) rejects `unavailable`, and may succeed if opened again later;
     *   opened again after any other refusal, it meets the same refusal
     *   until something changes.
     */
    stream(name, subject, onEvent) {
      if (typeof name !== "string" || name === "") return invalid("stream must be a stream name")
      if (subject !== null && typeof subject !== "string") {
        return invalid("subject must be a literal subject or null")
      }
      if (typeof onEvent !== "function") return invalid("onEvent must be a function")
      return subscribe(name, subject, onEvent)
    },

    /**
     * Ask the shell to open a tincture: a tincture reference, e.g.
     * "t:local.weather", and optionally what to open it on, `{kind, id}`,
     * a kind the app declares in `tincture.subjects` (run, thread,
     * schedule, component or file). The app is handed the subject at its
     * open (`cyfr.subject`); opening it does nothing more. From a canvas
     * the shell acts on it only for an input of the person's, never from a
     * script on its own.
     */
    open(ref, on = null) {
      if (on !== null && !isSubject(on)) return
      verb("open", on === null ? {ref} : {ref, subject: on})
    },

    /**
     * On a canvas, press a control it declares: the control's id, and for
     * a control with a pick the value picked, one the picked stream
     * publishes. The shell runs it as the person, only for an input of the
     * person's, and answers its outcome: `{outcome: "accepted"}`,
     * `{outcome: "refused", reason}` with the refusal's class, or
     * `{outcome: "cancelled"}` when no input of the person's carried it or
     * the canvas was not shown, with `reason: "too_soon"` when it came
     * within a few seconds of the last spend of the activation. A control
     * whose operation the person approves first settles once they decide,
     * as `cyfr.request` does: `{outcome: "approved"}`, `{outcome:
     * "refused", reason}` (`declined` when the person refused it, or a
     * refusal's class) or `{outcome: "cancelled"}`, perhaps with its
     * `reason`. Nothing is tried again.
     *
     * Its first argument a binding id (as a `feed.results` event carries
     * one) and its second an action's name, it presses that feed's action
     * instead, answering nothing.
     * @returns {Promise<{outcome: string, reason?: string}> | undefined}
     */
    press(control, value = null) {
      if (typeof control === "string" && BINDING_ID.test(control) && typeof value === "string" && ACTION_NAME.test(value)) {
        verb("press", {binding: control, action: value})
        return undefined
      }
      if (!isDesktopId(control)) return invalid("a control is named by its id")
      if (value !== null && !isPressValue(value)) return invalid("a pressed value is text of 1 to 256 code points")
      if (!framed) return Promise.resolve(CANCELLED)
      return awaitAnswer("press", value === null ? {control} : {control, value})
    },

    /**
     * On a canvas, write the person's preferences for it: `document`,
     * `{widgets: {<id>: {on, rect, <field>…}}, desktop: {<field>…}}`, each
     * widget it names replacing that widget's whole entry, over the
     * revision the canvas holds. Answers `{outcome, document, revision}`:
     * `saved`, `stale` (another write came first; the document is the
     * current one, to write over), `refused` with its `reason`, or
     * `cancelled` when no input of the person's carried it, with `reason`
     * `too_soon` when it came within a few seconds of the last spend.
     * @returns {Promise<{outcome: string, document: object, revision: number, reason?: string}>}
     */
    prefs(document) {
      if (document === null || typeof document !== "object" || Array.isArray(document)) {
        return invalid("preferences are an object")
      }
      if (!framed) return Promise.resolve(CANCELLED)
      return awaitAnswer("prefs", {document})
    },

    /**
     * On a canvas, ask AQUA about one of its widgets, by the widget's id:
     * AQUA's panel opens with a sentence CYFR writes naming the widget and
     * the desktop, after the person's draft, and sends nothing. Only for
     * an input of the person's.
     */
    ask(widget) {
      verb("ask", {widget})
    },

    /**
     * On a canvas, open one of CYFR's own pages by its key, e.g.
     * "schedules" or "vault", and optionally at one record on it, by its
     * id, e.g. a thread's. Only for an input of the person's.
     */
    settings(page, ref = null) {
      verb("settings", ref === null ? {page} : {page, ref})
    },

    /**
     * Ask the person for an act only they may do: an operation by its
     * name, "tool.action", with its arguments, or "grant" with `{ref}`, a
     * component reference, e.g. "c:local.openai". The person decides in
     * CYFR's own prompt, never in the frame, and the frame performs
     * nothing: CYFR runs what they approve. Which operations a frame may
     * ask for, and what the person is shown, are CYFR's. Only for an input
     * of the person's, from any frame.
     * @param {string} operation - "tool.action", or "grant"
     * @param {object} [args] - its arguments; for "grant" exactly `{ref}`
     * @returns {Promise<{outcome: string, reason?: string}> & {requested: Promise<string|null>}}
     *   the decision: `{outcome: "approved"}` once it ran, `{outcome:
     *   "refused", reason}` (`declined` when the person refused it, or a
     *   refusal's class when CYFR did), or `{outcome: "cancelled"}`, as
     *   when no input of the person's carried it, with `reason`
     *   `too_soon`, `busy`, `expired` or `dismissed` when CYFR says why.
     *   One that got no answer settles refused `uncertain`.
     *   `requested` resolves with the request's id once the person is
     *   asked, or with null when it was decided without asking them.
     *   Arguments outside the wire reject `invalid_argument`.
     */
    request(operation, args = {}) {
      if (!isRequest(operation, args)) {
        const refused = invalid("a request names tool.action with an object of arguments, or grant with exactly a ref")
        return requestHandle(refused, Promise.resolve(null))
      }
      if (!framed) return requestHandle(Promise.resolve(CANCELLED), Promise.resolve(null))
      let heard
      const requested = new Promise((resolve) => (heard = resolve))
      return requestHandle(awaitAnswer("request", {operation, args}, heard), requested)
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
     * own pixels, that the shown apps cover), `state` (`live` or
     * `frozen`) or `desktop` (as `cyfr.desktop` reads it); on an app,
     * `subject`, what it was opened on again. The latest value, if one has
     * come, is handed to a new handler first.
     * @returns {function} stops the handler hearing more
     */
    on(event, handler) {
      if (!CANVAS_EVENTS.includes(event)) {
        throw new TypeError("cyfr.on takes installed, posture, covered, state, desktop or subject")
      }
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
      if (!framed) return Promise.reject(noFrame())
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
