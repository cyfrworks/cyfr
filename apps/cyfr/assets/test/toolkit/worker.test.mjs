// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, describe, test} from "node:test"

import {HANDSHAKE} from "../../js/sdk/wire.js"
import {startModuleWorker, startStreamsWorker} from "../../js/toolkit/worker.js"
import {ROLES, decode} from "../../js/toolkit/wire.js"
import {
  ASSET,
  CREDENTIAL,
  FRAME,
  blobs,
  bootArgs,
  builtWorker,
  canvasWire,
  eventually,
  feedEnvelopes,
  moduleUrl,
  pause,
  playedHost,
  shellPort,
  sse,
  stubEndpoint,
  threadWorkers,
  threadedHost,
  within,
  workerScope
} from "./support.mjs"

const cleanups = []
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await within(cleanup(), "a cleanup")
})

const failedWith = (host) => host.shell.posted.filter((message) => message.verb === "failed").map((m) => m.args.stage)
const text = (value) => ({type: "text", value})

// ---- the host and its two workers ------------------------------------------------------

describe("the host starts its workers for one boot over the one port", () => {
  test("a second handshake, and a message from anywhere but the port, are ignored", () => {
    const host = playedHost()
    const other = shellPort()

    host.win.deliver({source: host.win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [other.port]})
    host.win.deliver({source: {name: "a sibling"}, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [other.port]})
    assert.equal(other.port.onmessage, null)
    assert.equal(host.win.listening, 0)

    // A boot arriving as a window message reaches nothing.
    host.win.deliver({source: host.win.parent, data: {v: 1, verb: "boot", frame: FRAME, args: bootArgs()}, ports: []})
    assert.equal(host.workers.started.length, 0)

    host.boot()
    assert.equal(host.workers.started.length, 2)
  })

  test("a handshake must come from the parent with exactly one port", () => {
    for (const event of [
      (win, port) => ({source: {name: "elsewhere"}, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [port]}),
      (win, port) => ({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [port, port]}),
      (win) => ({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: []}),
      (win, port) => ({source: win.parent, data: {v: 1, type: HANDSHAKE, frame: "../x"}, ports: [port]}),
      (win, port) => ({source: win.parent, data: {v: 2, type: HANDSHAKE, frame: FRAME}, ports: [port]})
    ]) {
      const host = playedHost({handshake: false})
      const other = shellPort()
      host.win.deliver(event(host.win, other.port))
      assert.equal(other.port.onmessage, null)
      assert.equal(host.win.listening, 1)

      host.win.deliver({source: host.win.parent, data: {v: 1, type: HANDSHAKE, frame: FRAME}, ports: [host.shell.port]})
      assert.equal(typeof host.shell.port.onmessage, "function")
      assert.equal(host.win.listening, 0)
    }
  })

  test("anything before an accepted boot is dropped, and only one boot is accepted", () => {
    const host = playedHost()
    host.shell.send("posture", {posture: "hand"})
    host.shell.send("boot", {...bootArgs(), worker_url: `/_s/${ASSET}/worker.js`})
    host.shell.send("boot", bootArgs({data_path: "/_f/v1/o/frm_00aa11bb22/"}))
    host.shell.send("boot", bootArgs(), "frm_00aa11bb22")
    assert.equal(host.workers.started.length, 0)
    assert.deepEqual(host.shell.posted, [])

    host.boot()
    host.boot({mode: "validation"})
    assert.equal(host.workers.started.length, 2)
    assert.deepEqual(
      host.workers.module().posted.map(({data}) => data.t),
      ["boot"]
    )
    assert.equal(host.workers.module().posted[0].data.mode, "live")
  })

  test("a boot without streams, or with malformed ones, fails at load and is never read as every stream allowed", () => {
    const {streams: _streams, ...lacking} = bootArgs()
    for (const args of [
      lacking,
      bootArgs({streams: [{name: "feed.results", subject: "btc"}, {name: "feed.results", subject: "btc"}]}),
      bootArgs({streams: [{name: "feed.results", subject: "btc", all: true}]}),
      bootArgs({streams: "*"})
    ]) {
      const host = playedHost()
      host.shell.send("boot", args)
      assert.deepEqual(failedWith(host), ["load"])
      assert.equal(host.workers.started.length, 0)

      // Terminal: a well-formed boot after it starts nothing.
      host.boot()
      assert.equal(host.workers.started.length, 0)
    }
  })

  test("an empty list of streams starts the workers with none declared", () => {
    const host = playedHost()
    host.boot({streams: []})
    const [boot] = host.workers.streams().posted
    assert.deepEqual(boot.data.streams, [])
    assert.equal(boot.data.credential, CREDENTIAL)
    assert.equal(boot.data.data_url, `https://cyfr.example/_f/v1/o/${FRAME}/`)
    assert.deepEqual(boot.transfer, [boot.data.port])
    assert.deepEqual(failedWith(host), [])
  })

  test("every boot the vector refuses starts nothing, and one refused for its streams alone fails at load", () => {
    const boots = canvasWire.messages.invalid.filter(({message}) => message && message.verb === "boot")
    assert.ok(boots.length > 0)
    let streamsOnly = 0

    for (const {why, message} of boots) {
      const host = playedHost()
      host.shell.raw({...message, frame: FRAME})

      // Refused for its streams alone: everything else about it is a boot.
      const repaired = {...message, frame: FRAME, args: {...message.args, streams: bootArgs().streams}}
      if (message.frame === FRAME && decode(repaired).ok) {
        streamsOnly += 1
        assert.deepEqual(failedWith(host), ["load"], why)
      } else {
        assert.deepEqual(host.shell.posted, [], why)
      }
      assert.equal(host.workers.started.length, 0, why)
    }
    assert.ok(streamsOnly >= 8, `${streamsOnly} boots refused for their streams alone`)
  })

  test("a boot of a toolkit major this toolkit does not draw fails at load", () => {
    const host = playedHost()
    host.boot({toolkit: 2})
    assert.deepEqual(failedWith(host), ["load"])
    assert.equal(host.workers.started.length, 0)
  })

  test("a worker that cannot be started fails at load, terminally, and stops the one that did start", () => {
    const neither = playedHost()
    neither.workers.refuse(() => true)
    neither.boot()
    assert.deepEqual(failedWith(neither), ["load"])
    assert.equal(neither.workers.started.length, 0)

    const second = playedHost()
    second.workers.refuse((name) => name === ROLES.module)
    second.boot()
    assert.deepEqual(failedWith(second), ["load"])
    assert.deepEqual(second.workers.started.map((worker) => [worker.name, worker.terminated]), [[ROLES.streams, true]])
    assert.equal(second.workers.started[0].onmessage, null)

    // At a thaw, too; and nothing starts again after it.
    const thawed = playedHost()
    thawed.boot()
    thawed.shell.send("state", {state: "frozen"})
    thawed.workers.refuse(() => true)
    thawed.shell.send("state", {state: "live"})
    assert.deepEqual(failedWith(thawed), ["load"])
    thawed.workers.refuse(() => false)
    thawed.shell.send("state", {state: "frozen"})
    thawed.shell.send("state", {state: "live"})
    assert.equal(thawed.workers.started.length, 2)
    assert.deepEqual(failedWith(thawed), ["load"])
  })

  test("a page without its worker bundle fails at load", () => {
    const host = playedHost({workerSource: null})
    host.boot()
    assert.deepEqual(failedWith(host), ["load"])
    assert.equal(host.workers.started.length, 0)
  })

  test("both workers start from the page's bundle, the module resolved against the page's URL", () => {
    const host = playedHost()
    host.boot()
    const module = host.workers.module()
    assert.equal(module.url, host.workers.streams().url)
    assert.match(module.url, /^blob:/)
    assert.deepEqual(module.options, {name: ROLES.module})
    assert.equal(module.posted[0].data.module_url, `https://cyfr.example/_s/${ASSET}/canvas.js`)
  })
})

describe("the shell's values and the canvas's answers", () => {
  test("posture, covered and installed reach the module worker, the latest of each again after a thaw", () => {
    const host = playedHost()
    host.boot()
    host.shell.send("posture", {posture: "hand"})
    host.shell.send("covered", {rects: [{x: 0, y: 0, width: 10, height: 10}]})
    host.shell.send("installed", {tinctures: [{ref: "tincture:local.vault", name: "Vault"}]})
    host.shell.send("posture", {posture: "desk"})
    assert.equal(host.root().getAttribute("data-posture"), "desk")

    const values = (worker) => worker.posted.map(({data}) => data).filter((data) => data.t !== "boot")
    assert.deepEqual(values(host.workers.module()), [
      {t: "posture", value: "hand"},
      {t: "covered", value: [{x: 0, y: 0, width: 10, height: 10}]},
      {t: "installed", value: [{ref: "tincture:local.vault", name: "Vault"}]},
      {t: "posture", value: "desk"}
    ])

    host.shell.send("state", {state: "frozen"})
    host.shell.send("state", {state: "live"})
    assert.deepEqual(values(host.workers.module()), [
      {t: "posture", value: "desk"},
      {t: "covered", value: [{x: 0, y: 0, width: 10, height: 10}]},
      {t: "installed", value: [{ref: "tincture:local.vault", name: "Vault"}]}
    ])
  })

  test("in live mode, ready is posted once, at the first tree drawn", () => {
    const host = playedHost()
    host.boot()
    host.render({type: "text", value: "x", tone: "neon"})
    assert.deepEqual(host.shell.verbs(), [])
    host.render(text("one"))
    host.render(text("two"))
    assert.deepEqual(host.shell.verbs(), ["ready"])
  })

  test("in validation mode the first tree decides, and ready is never posted", () => {
    const passing = playedHost()
    passing.boot({mode: "validation"})
    passing.render(text("one"), {draw: false})
    assert.deepEqual(passing.shell.verbs(), ["tree"])
    passing.render(text("two"))
    assert.deepEqual(passing.shell.verbs(), ["tree"])
    assert.equal(passing.root().textContent, "two")

    const failing = playedHost()
    failing.boot({mode: "validation"})
    failing.render({type: "image", src: "../x.png", alt: ""}, {draw: false})
    failing.render(text("too late"))
    assert.deepEqual(failing.shell.verbs(), ["failed"])
    assert.deepEqual(failedWith(failing), ["tree"])
    assert.equal(failing.workers.module().terminated, true)
  })

  test("a failure the module worker reports is posted once, with its stage", () => {
    const host = playedHost()
    host.boot()
    host.workers.module().emit({t: "failed", stage: "load"})
    host.workers.module().emitLate({t: "failed", stage: "runtime"})
    assert.deepEqual(failedWith(host), ["load"])
  })
})

describe("lifecycle", () => {
  test("freezing terminates both workers; thawing starts a new generation and rejects the earlier one's messages", () => {
    const host = playedHost()
    host.boot()
    host.shell.send("installed", {tinctures: [{ref: "tincture:local.vault", name: "Vault"}]})
    const {envelope} = feedEnvelopes[0]
    host.feedEvent(envelope)
    const [oldModule, oldStreams] = [host.workers.module(), host.workers.streams()]

    host.shell.send("state", {state: "frozen"})
    assert.equal(oldModule.terminated, true)
    assert.equal(oldStreams.terminated, true)
    assert.equal(oldModule.onmessage, null)

    host.shell.send("state", {state: "live"})
    assert.equal(host.workers.started.length, 4)
    const [module, streams] = [host.workers.module(), host.workers.streams()]
    assert.notEqual(module, oldModule)
    assert.equal(module.posted[0].data.module_url, oldModule.posted[0].data.module_url)
    assert.equal(streams.posted[0].data.credential, CREDENTIAL)

    // The earlier generation's late messages: a tree, a binding record, an
    // error. None is drawn, installed or taken as a death.
    oldModule.emitLate({t: "tree", json: JSON.stringify(text("stale"))})
    oldStreams.emitLate({
      t: "relay",
      m: {t: "event", sub: 0, event: {id: 9, event: "feed.results", data: envelope}},
      record: {feed: "btc", binding: envelope.binding, revision: 9, label: "Bitcoin", actions: [{name: "buy", label: "Stale"}]}
    })
    oldModule.crashLate()
    oldStreams.crashLate()
    host.frames()
    assert.equal(host.root().textContent, "")
    assert.deepEqual(failedWith(host), [])
    assert.deepEqual(module.posted.filter(({data}) => data.t === "stream"), [])

    host.render({type: "control", effect: {press: {feed: "btc", action: "buy"}}})
    assert.equal(host.controls()[0].textContent, "Buy 0.01")
  })

  test("either worker dying, or erroring at top level, is a terminal runtime failure", () => {
    for (const end of [
      (host) => host.workers.module().crash(),
      (host) => host.workers.streams().crash(),
      (host) => host.workers.streams().emit({t: "lost"}),
      (host) => host.workers.streams().emit({t: "relay", m: {t: "nonsense"}, record: null})
    ]) {
      const host = playedHost()
      host.boot()
      host.render(text("drawn"))
      const [module, streams] = [host.workers.module(), host.workers.streams()]

      end(host)

      assert.deepEqual(failedWith(host), ["runtime"])
      assert.equal(module.terminated, true)
      assert.equal(streams.terminated, true)
      assert.equal(host.root().textContent, "drawn")

      host.shell.send("state", {state: "frozen"})
      host.shell.send("state", {state: "live"})
      assert.equal(host.workers.started.length, 2)
      assert.deepEqual(failedWith(host), ["runtime"])
    }
  })
})

// ---- the built worker bundle -------------------------------------------------------------

const COUNTER = `
export default function (canvas) {
  let n = 0
  setInterval(() => canvas.render({type: "text", value: String(n++)}), 5)
}
`

async function threaded(modules, answer = () => ({status: 404, body: {}})) {
  const endpoint = await stubEndpoint(answer)
  cleanups.push(() => endpoint.close())
  const served = Object.fromEntries(Object.entries(modules).map(([file, source]) => [moduleUrl(endpoint.origin, file), source]))
  const host = threadedHost({origin: endpoint.origin, modules: served})
  cleanups.push(() => host.workers.stopAll())
  return {host, endpoint, url: (file) => moduleUrl(endpoint.origin, file)}
}

const boot = (host, file, overrides = {}) =>
  host.shell.send("boot", bootArgs({module_url: `/_s/${ASSET}/${file}`, ...overrides}))

describe("the built worker bundle runs the module and stops with it", () => {
  test("freezing terminates the worker and a counter stops; resuming imports the module again", async () => {
    const {host, url} = await threaded({"counter.js": COUNTER})
    boot(host, "counter.js", {streams: []})

    await eventually(() => Number(host.text()) >= 3)
    assert.deepEqual(host.shell.verbs(), ["ready"])
    const first = [...host.workers.started]
    assert.deepEqual(first.map((worker) => worker.name).sort(), [ROLES.module, ROLES.streams].sort())

    host.shell.send("state", {state: "frozen"})
    assert.ok(first.every((worker) => worker.terminated))
    await within(Promise.all(first.map((worker) => worker.exited)), "the frozen workers' exit")
    // The counter's own worker posts nothing more: its timer went with it.
    const module = first.find((worker) => worker.name === ROLES.module)
    const posted = module.received
    const stopped = host.text()
    await pause(100)
    assert.equal(module.received, posted)
    assert.equal(host.text(), stopped)

    host.shell.send("state", {state: "live"})
    await eventually(() => host.workers.imports.filter((entry) => entry.url === url("counter.js")).length === 2)
    assert.equal(host.workers.started.length, 4)
    const second = host.workers.started.slice(2)
    assert.ok(host.workers.imports.at(-1).worker === second.find((worker) => worker.name === ROLES.module))

    await eventually(() => host.text() !== stopped)
    const resumed = Number(host.text())
    await eventually(() => Number(host.text()) > resumed)
    assert.deepEqual(host.shell.verbs(), ["ready"])
  })

  test("the module's scope cannot close its own worker", async () => {
    const {host} = await threaded({
      "closer.js": `export default (canvas) => canvas.render({type: "text", value: typeof self.close})`
    })
    boot(host, "closer.js", {streams: []})
    await eventually(() => host.text() !== "")
    assert.equal(host.text(), "undefined")
  })

  test("a module that throws on import, has no default function or throws in it fails at load", async () => {
    for (const source of [
      `throw new Error("on import")`,
      `export const canvas = 1`,
      `export default 7`,
      `export default function () { throw new Error("at once") }`,
      null
    ]) {
      const modules = source === null ? {} : {"broken.js": source}
      const {host} = await threaded(modules)
      boot(host, "broken.js", {streams: []})
      await eventually(() => failedWith(host).length > 0)
      assert.deepEqual(failedWith(host), ["load"], String(source))
      assert.ok(host.workers.started.every((worker) => worker.terminated))
    }
  })

  test("a module whose promise rejects or whose handler throws fails at runtime", async () => {
    for (const [source, poke] of [
      [`export default async function () { throw new Error("later") }`, () => {}],
      [`export default (canvas) => { canvas.on("posture", () => { throw new Error("in a handler") }) }`, (host) => host.shell.send("posture", {posture: "hand"})],
      [`export default (canvas) => { setTimeout(() => { throw new Error("uncaught") }, 5) }`, () => {}],
      [`export default (canvas) => { Promise.reject(new Error("unhandled")) }`, () => {}]
    ]) {
      const {host} = await threaded({"broken.js": source})
      boot(host, "broken.js", {streams: []})
      await pause(30)
      poke(host)
      await eventually(() => failedWith(host).length > 0)
      assert.deepEqual(failedWith(host), ["runtime"], source)
      assert.ok(host.workers.started.every((worker) => worker.terminated))
    }
  })
})

describe("the streams worker opens only the version's declared streams", () => {
  const {envelope} = feedEnvelopes.find((row) => row.envelope.feed === "btc")

  const FEED_MODULE = `
const state = {event: null, refusals: []}
export default async function (canvas) {
  const draw = () => canvas.render({type: "stack", children: [
    {type: "text", value: JSON.stringify(state)},
    {type: "control", effect: {press: {feed: "btc", action: "buy"}}}
  ]})
  for (const [name, subject] of [["runs.changes", null], ["feed.results", "eth"]]) {
    try {
      await canvas.stream(name, subject, () => {})
      state.refusals.push("opened " + name)
    } catch (error) {
      state.refusals.push(error.code + "/" + error.stage)
    }
  }
  await canvas.stream("feed.results", "btc", (event) => {
    state.event = event
    draw()
  })
  draw()
}
`

  const feedAnswer = (request) => ({stream: (res) => res.write(sse({id: envelope.revision, event: "feed.results", data: envelope}))})

  test("a declared feed is opened with the bearer, and its event binds the control the module draws from it", async () => {
    const {host, endpoint} = await threaded({"feed.js": FEED_MODULE}, feedAnswer)
    boot(host, "feed.js")

    await eventually(() => host.text().includes('"event":{'))
    const state = JSON.parse(host.root().children[0].children[0].textContent)

    // The event as the SDK delivers one, the feed vector's envelope its data.
    assert.deepEqual(state.event, {id: envelope.revision, event: "feed.results", data: envelope})
    assert.deepEqual(state.refusals, ["forbidden/admission", "forbidden/admission"])

    // One request, the declared pair's, at the canvas's own route, under the bearer.
    assert.equal(endpoint.requests.length, 1)
    const [request] = endpoint.requests
    assert.equal(request.method, "POST")
    assert.equal(request.url, `/_f/v1/o/${FRAME}/stream`)
    assert.equal(request.headers.authorization, `Bearer ${CREDENTIAL}`)
    assert.deepEqual(request.body, {v: 1, stream: "feed.results", subject: "btc"})

    // The control is labelled from the binding, and presses that binding.
    await eventually(() => host.root().textContent.endsWith("Buy 0.01"))
    const control = host.root().children[0].children[1]
    control.fire({type: "click", isTrusted: true, preventDefault() {}})
    assert.deepEqual(host.shell.posted.at(-1), {v: 1, verb: "press", frame: FRAME, args: {binding: envelope.binding, action: "buy"}})
    assert.ok(!host.text().includes(CREDENTIAL))
  })

  test("an empty list of declared streams opens nothing", async () => {
    const {host, endpoint} = await threaded(
      {
        "none.js": `export default async (canvas) => {
          try { await canvas.stream("feed.results", "btc", () => {}); canvas.render({type: "text", value: "opened"}) }
          catch (error) { canvas.render({type: "text", value: error.code + "/" + error.stage}) }
        }`
      },
      feedAnswer
    )
    boot(host, "none.js", {streams: []})
    await eventually(() => host.text() !== "")
    assert.equal(host.text(), "forbidden/admission")
    assert.equal(endpoint.requests.length, 0)
  })

  test("a streams worker takes its boot from the host's channel alone, once, and never from its port", async () => {
    const endpoint = await stubEndpoint(feedAnswer)
    cleanups.push(() => endpoint.close())
    const {Blob, URL, registry} = blobs()
    const workers = threadWorkers({registry, modules: {}})
    cleanups.push(() => workers.stopAll())
    const streams = new workers.Worker(URL.createObjectURL(new Blob([builtWorker()])), {name: ROLES.streams})
    const relayed = []
    streams.onmessage = ({data}) => relayed.push(data)

    const boot = (credential, declared, port) => ({
      t: "boot",
      credential,
      data_url: `${endpoint.origin}/_f/v1/o/${FRAME}/`,
      streams: declared,
      port
    })
    const btc = [{name: "feed.results", subject: "btc"}]

    // The host's boot declares runs.changes alone.
    const channel = new MessageChannel()
    const answers = []
    channel.port1.on("message", (data) => answers.push(data))
    streams.postMessage(boot(CREDENTIAL, [{name: "runs.changes", subject: null}], channel.port2), [channel.port2])

    // A boot from the module's end of the channel, and a second one on the
    // worker's own, declare btc's feed under another bearer: neither is taken.
    const spare = new MessageChannel()
    channel.port1.postMessage(boot("frm.v1.forged", btc, spare.port2), [spare.port2])
    const again = new MessageChannel()
    streams.postMessage(boot("frm.v1.forged", btc, again.port2), [again.port2])

    channel.port1.postMessage({t: "open", sub: 0, name: "feed.results", subject: "btc"})
    channel.port1.postMessage({t: "open", sub: 1, name: "runs.changes", subject: null})

    await eventually(() => relayed.length > 0 && answers.length > 0)
    assert.deepEqual(relayed[0], {
      t: "relay",
      m: {t: "refused", sub: 0, code: "forbidden", message: "This canvas does not declare that stream.", stage: "admission"},
      record: null
    })
    assert.deepEqual(answers[0], {t: "opened", sub: 1})
    assert.equal(endpoint.requests.length, 1)
    assert.equal(endpoint.requests[0].headers.authorization, `Bearer ${CREDENTIAL}`)
    assert.deepEqual(endpoint.requests[0].body, {v: 1, stream: "runs.changes", subject: null})

    for (const port of [channel.port1, spare.port1, again.port1]) port.close()
  })

  test("the endpoint's refusal reaches the module as its code and stage", async () => {
    const {host} = await threaded(
      {
        "refused.js": `export default async (canvas) => {
          try { await canvas.stream("feed.results", "btc", () => {}) }
          catch (error) { canvas.render({type: "text", value: error.code + "/" + error.stage + "/" + error.message}) }
        }`
      },
      () => ({status: 403, body: {v: 1, ok: false, error: {class: "forbidden", message: "Not granted.", stage: "admission"}}})
    )
    boot(host, "refused.js")
    await eventually(() => host.text() !== "")
    assert.equal(host.text(), "forbidden/admission/Not granted.")
  })
})

// ---- the workers' code, run in the test's own thread -------------------------------------

describe("the streams worker makes binding records only from its own feed subscriptions", () => {
  const btc = feedEnvelopes.find((row) => row.envelope.feed === "btc").envelope
  const other = feedEnvelopes.find((row) => row.envelope.feed !== "btc").envelope

  // A streams worker booted with `declared`, against an endpoint whose every
  // stream sends `data` as one event and stays open. `direct` records what
  // reaches the module worker's end of the channel without the host;
  // `scope.posted` what the worker posts to the host.
  async function streamsWorker({declared, data}) {
    const endpoint = await stubEndpoint(() => ({stream: (res) => res.write(sse({id: 1, event: "x", data}))}))
    cleanups.push(() => endpoint.close())
    const scope = workerScope(ROLES.streams)
    startStreamsWorker(scope, {fetchFn: fetch})

    const channel = new MessageChannel()
    const direct = []
    channel.port1.onmessage = ({data: message}) => direct.push(message)
    cleanups.push(() => channel.port1.close())
    scope.deliver({t: "boot", credential: CREDENTIAL, data_url: `${endpoint.origin}/_f/v1/o/${FRAME}/`, streams: declared, port: channel.port2})
    return {scope, endpoint, direct, ask: (message) => channel.port1.postMessage(message)}
  }

  const relayedEvents = (scope) => scope.posted.filter((message) => message.t === "relay" && message.m.t === "event")

  test("an envelope naming another feed makes no record, for that feed or the subscription's", async () => {
    const {scope, ask} = await streamsWorker({declared: [{name: "feed.results", subject: "btc"}], data: other})
    ask({t: "open", sub: 0, name: "feed.results", subject: "btc"})
    await eventually(() => relayedEvents(scope).length === 1)

    const [relay] = relayedEvents(scope)
    assert.equal(relay.record, null)
    assert.deepEqual(relay.m.event.data, other)
  })

  test("the subscription's own feed's envelope makes that feed's record", async () => {
    const {scope, ask} = await streamsWorker({declared: [{name: "feed.results", subject: "btc"}], data: btc})
    ask({t: "open", sub: 0, name: "feed.results", subject: "btc"})
    await eventually(() => relayedEvents(scope).length === 1)
    assert.deepEqual(relayedEvents(scope)[0].record, {
      feed: "btc",
      binding: btc.binding,
      revision: btc.revision,
      label: btc.label,
      actions: btc.actions
    })
  })

  test("a feed-shaped event on another declared stream makes no record and never reaches the host", async () => {
    const {scope, direct, ask} = await streamsWorker({declared: [{name: "runs.changes", subject: "btc"}], data: btc})
    ask({t: "open", sub: 0, name: "runs.changes", subject: "btc"})
    await eventually(() => direct.some((message) => message.t === "event"))

    assert.deepEqual(direct.map((message) => message.t), ["opened", "event"])
    assert.deepEqual(direct[1].event.data, btc)
    assert.deepEqual(scope.posted, [])
  })

  test("a boot in an event the browser did not deliver is no boot", async () => {
    const endpoint = await stubEndpoint(() => ({stream: (res) => res.write(sse({id: 1, event: "x", data: btc}))}))
    cleanups.push(() => endpoint.close())
    const scope = workerScope(ROLES.streams)
    startStreamsWorker(scope, {fetchFn: fetch})
    const boot = (port) => ({
      t: "boot",
      credential: CREDENTIAL,
      data_url: `${endpoint.origin}/_f/v1/o/${FRAME}/`,
      streams: [{name: "runs.changes", subject: null}],
      port
    })

    const forged = new MessageChannel()
    const forgedAnswers = []
    forged.port1.onmessage = ({data}) => forgedAnswers.push(data)
    cleanups.push(() => forged.port1.close())
    scope.deliver(boot(forged.port2), {isTrusted: false})
    forged.port1.postMessage({t: "open", sub: 0, name: "runs.changes", subject: null})

    const real = new MessageChannel()
    const answers = []
    real.port1.onmessage = ({data}) => answers.push(data)
    cleanups.push(() => real.port1.close())
    scope.deliver(boot(real.port2))
    real.port1.postMessage({t: "open", sub: 0, name: "runs.changes", subject: null})

    await eventually(() => answers.length > 0)
    await pause(30)
    assert.deepEqual(answers[0], {t: "opened", sub: 0})
    assert.deepEqual(forgedAnswers, [])
    assert.equal(endpoint.requests.length, 1)
  })
})

describe("a stream that breaks as it opens is reported", () => {
  test("an answer with no body ends the stream, and the module's closed rejects", async () => {
    // The endpoint answers as a stream, with no body to read.
    const fetchFn = async () => new Response(null, {headers: {"content-type": "text/event-stream"}})
    const streams = workerScope(ROLES.streams)
    startStreamsWorker(streams, {fetchFn})

    const module = workerScope(ROLES.module)
    const canvas = {}
    startModuleWorker(module, {importModule: async () => ({default: (api) => Object.assign(canvas, {api})})})

    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())
    streams.deliver({
      t: "boot",
      credential: CREDENTIAL,
      data_url: `https://cyfr.example/_f/v1/o/${FRAME}/`,
      streams: [{name: "runs.changes", subject: null}],
      port: channel.port1
    })
    module.deliver({t: "boot", mode: "live", module_url: `https://cyfr.example/_s/${ASSET}/canvas.js`, port: channel.port2})
    await eventually(() => canvas.api !== undefined)

    const handle = await within(canvas.api.stream("runs.changes", null, () => {}), "the stream's open")
    await assert.rejects(within(handle.closed, "the stream's closed"), {code: "unavailable"})
    assert.deepEqual(module.posted, [])
  })

  test("a module's boot in an event the browser did not deliver imports nothing", async () => {
    const module = workerScope(ROLES.module)
    const imported = []
    startModuleWorker(module, {
      importModule: async (url) => {
        imported.push(url)
        return {default: () => {}}
      }
    })
    const channel = new MessageChannel()
    cleanups.push(() => channel.port1.close())

    module.deliver({t: "boot", mode: "live", module_url: `https://cyfr.example/_s/${ASSET}/a.js`, port: channel.port2}, {isTrusted: false})
    await pause(20)
    assert.deepEqual(imported, [])

    module.deliver({t: "boot", mode: "live", module_url: `https://cyfr.example/_s/${ASSET}/b.js`, port: channel.port2})
    await eventually(() => imported.length === 1)
    assert.deepEqual(imported, [`https://cyfr.example/_s/${ASSET}/b.js`])
  })
})
