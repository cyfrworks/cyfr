// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {UNAVAILABLE} from "../../js/toolkit/controls.js"
import {ROLES} from "../../js/toolkit/wire.js"
import {CREDENTIAL, FRAME, feedEnvelopes, pause, playedHost, trusted} from "./support.mjs"

// The btc feed's latest event: binding B1, actions refresh ("Refresh") and
// buy ("Buy 0.01").
const BTC = feedEnvelopes.find(({envelope}) => envelope.feed === "btc").envelope
// The same feed after it was removed and bound again: a new binding id.
const REBOUND = {
  ...BTC,
  binding: "feed_01a09fee-2e4f-7a5b-bc6d-7e8f9a0b1c2e",
  revision: 1,
  actions: [
    {name: "refresh", label: "Refresh"},
    {name: "buy", label: "Buy 0.02"}
  ]
}

const VAULT = {ref: "tincture:local.vault", name: "Vault"}

const buy = {type: "control", effect: {press: {feed: "btc", action: "buy"}}}
const vault = {type: "control", effect: {open: VAULT.ref}}
const stack = (children) => ({type: "stack", children})

// A live canvas whose shell has said which tinctures are installed and
// whose btc feed has had one event.
function canvas() {
  const host = playedHost()
  host.boot()
  host.shell.send("installed", {tinctures: [VAULT]})
  host.feedEvent(BTC)
  return host
}

const presses = (host) => host.shell.posted.filter((message) => message.verb === "press" || message.verb === "open")
const click = (control) => control.fire(trusted("click"))

describe("a control is labelled from its declaration", () => {
  test("a control's label is never the canvas's", () => {
    const host = canvas()
    host.render(
      stack([
        {type: "text", value: "Refresh"},
        buy,
        vault,
        {type: "control", effect: {press: {feed: "btc", action: "sell"}}},
        {type: "control", effect: {open: "tincture:local.notes"}},
        {type: "control", effect: {press: {feed: "eth", action: "refresh"}}}
      ])
    )

    const controls = host.controls()
    assert.deepEqual(
      controls.map((control) => control.textContent),
      ["Buy 0.01", "Vault", UNAVAILABLE, UNAVAILABLE, UNAVAILABLE]
    )
    assert.deepEqual(
      controls.map((control) => control.getAttribute("aria-disabled")),
      [null, null, "true", "true", "true"]
    )

    // A tree that would name a control's label is refused whole.
    host.render(stack([{...buy, label: "Refresh"}]))
    assert.equal(host.controls()[0].textContent, "Buy 0.01")

    click(controls[0])
    click(controls[1])
    for (const control of controls.slice(2)) click(control)

    assert.deepEqual(presses(host), [
      {v: 1, verb: "press", frame: FRAME, args: {binding: BTC.binding, action: "buy"}},
      {v: 1, verb: "open", frame: FRAME, args: {ref: VAULT.ref}}
    ])
  })

  test("a control is focusable, and its accessible name is its label", () => {
    const host = canvas()
    host.render(stack([buy, vault, {type: "control", effect: {open: "tincture:local.notes"}}]))

    const controls = host.controls()
    assert.deepEqual(
      controls.map((control) => [control.getAttribute("role"), control.getAttribute("tabindex"), control.getAttribute("aria-label")]),
      [
        ["button", "0", "Buy 0.01"],
        ["button", "0", "Vault"],
        ["button", "0", UNAVAILABLE]
      ]
    )
    for (const control of controls) assert.equal(control.getAttribute("aria-label"), control.textContent)

    // Failed, the controls keep their names and stay focusable, and say they
    // are unavailable.
    host.workers.module().crash()
    for (const control of host.controls()) {
      assert.equal(control.getAttribute("tabindex"), "0")
      assert.equal(control.getAttribute("aria-disabled"), "true")
      assert.equal(control.getAttribute("aria-label"), control.textContent)
    }
    assert.deepEqual(host.controls().map((control) => control.textContent), ["Buy 0.01", "Vault", UNAVAILABLE])
  })

  test("a binding record from the module's worker fails the canvas and relabels nothing", () => {
    for (const forged of [
      // What the streams worker posts, posted by the canvas's own code.
      {
        t: "relay",
        m: {t: "event", sub: 0, event: {id: 8, event: "feed.results", data: {...BTC, revision: 8}}},
        record: {feed: "btc", binding: BTC.binding, revision: 8, label: "Bitcoin", actions: [{name: "buy", label: "Refresh"}]}
      },
      {t: "binding", feed: "btc", binding: BTC.binding, label: "Bitcoin", actions: [{name: "buy", label: "Refresh"}]}
    ]) {
      const host = canvas()
      host.render(stack([buy]))
      const module = host.workers.module()
      const streams = host.workers.streams()

      module.emit(forged)

      assert.deepEqual(host.shell.posted.at(-1), {v: 1, verb: "failed", frame: FRAME, args: {stage: "runtime"}})
      assert.equal(module.terminated, true)
      assert.equal(streams.terminated, true)

      // The control keeps its declared label, and acts no more.
      const [control] = host.controls()
      assert.equal(control.textContent, "Buy 0.01")
      assert.equal(control.getAttribute("aria-disabled"), "true")
      click(control)
      assert.deepEqual(presses(host), [])

      // Nothing the forgery carried is drawn later, and the failure is terminal.
      module.emitLate({t: "tree", json: JSON.stringify(stack([buy, {type: "text", value: "after"}]))})
      host.frames()
      host.shell.send("state", {state: "frozen"})
      host.shell.send("state", {state: "live"})
      assert.equal(host.workers.started.length, 2)
      assert.equal(host.controls()[0].textContent, "Buy 0.01")
      assert.equal(host.shell.posted.filter((message) => message.verb === "failed").length, 1)
    }
  })

  test("an untrusted or replayed event dispatches nothing", () => {
    const host = canvas()
    host.render(stack([buy]))
    const [control] = host.controls()

    // The page's own events are never the person's.
    control.dispatchEvent(new Event("click"))
    control.dispatchEvent(Object.assign(new Event("keydown"), {key: "Enter"}))
    assert.deepEqual(presses(host), [])

    // One activation is one press, however often it is delivered.
    const once = trusted("click")
    control.fire(once)
    control.fire(once)
    assert.equal(presses(host).length, 1)

    // Enter and Space press; a held key's repeats and other keys do not.
    const space = control.fire(trusted("keydown", {key: " "}))
    assert.equal(space.defaultPrevented, true)
    control.fire(trusted("keydown", {key: "Enter"}))
    control.fire(trusted("keydown", {key: "Enter", repeat: true}))
    control.fire(trusted("keydown", {key: "a"}))
    control.fire(trusted("keyup", {key: "Enter"}))
    assert.equal(presses(host).length, 3)
  })

  test("a press is dispatched inside its handler or not at all", async () => {
    const host = canvas()
    host.render(stack([buy]))
    const [control] = host.controls()

    // Each post records whether the press's handler was still running.
    let handling = false
    const during = []
    const post = host.shell.port.postMessage
    host.shell.port.postMessage = (message) => {
      during.push({verb: message.verb, handling})
      post(message)
    }
    const press = (event) => {
      handling = true
      control.fire(event)
      handling = false
    }

    press(trusted("click"))
    assert.deepEqual(during, [{verb: "press", handling: true}])

    // Frozen, a press is dropped, and nothing is held for later.
    host.shell.send("state", {state: "frozen"})
    press(trusted("click"))
    host.shell.send("state", {state: "live"})
    await pause(20)
    host.frames()
    assert.deepEqual(during, [{verb: "press", handling: true}])

    // Live again, the control still acts.
    press(trusted("click"))
    assert.deepEqual(during, [
      {verb: "press", handling: true},
      {verb: "press", handling: true}
    ])
  })
})

describe("a control keeps its binding", () => {
  test("a control keeps the binding id it was bound to at tree time", () => {
    const host = canvas()
    host.render(stack([buy]))

    // The feed is bound again; its next event names the new binding, and
    // no tree has been answered since.
    host.feedEvent(REBOUND)
    host.frames()
    click(host.controls()[0])
    assert.equal(host.controls()[0].textContent, "Buy 0.01")
    assert.deepEqual(presses(host).at(-1).args, {binding: BTC.binding, action: "buy"})

    // The next tree binds the control to the binding of the latest event.
    host.render(stack([buy]))
    click(host.controls()[0])
    assert.equal(host.controls()[0].textContent, "Buy 0.02")
    assert.deepEqual(presses(host).at(-1).args, {binding: REBOUND.binding, action: "buy"})
  })

  test("a control binds when its tree is answered, not when the tree is drawn", () => {
    const host = canvas()

    // The tree is answered while BTC's binding stands; before the next frame
    // draws it, the feed is bound again and its first event arrives.
    host.render(stack([buy]), {draw: false})
    host.feedEvent(REBOUND)
    host.frames()

    const [control] = host.controls()
    assert.equal(control.textContent, "Buy 0.01")
    click(control)
    assert.deepEqual(presses(host).at(-1).args, {binding: BTC.binding, action: "buy"})
  })

  test("an event and its binding record race, and a control drawn from that event is bound to that event's binding", () => {
    const host = canvas()
    host.render(stack([buy]))

    // The module worker answers a tree from the event the moment it
    // arrives, before the host has finished handling the streams worker's
    // message.
    const module = host.workers.module()
    module.onPost = (data) => {
      if (data.t !== "stream" || data.m.t !== "event") return
      const {binding} = data.m.event.data
      module.emit({t: "tree", json: JSON.stringify(stack([{type: "text", value: binding}, buy]))})
    }

    host.feedEvent(REBOUND)
    host.frames()

    assert.equal(host.root().textContent.startsWith(REBOUND.binding), true)
    const [control] = host.controls()
    assert.equal(control.textContent, "Buy 0.02")
    click(control)
    assert.deepEqual(presses(host).at(-1).args, {binding: REBOUND.binding, action: "buy"})
  })
})

describe("channels authenticate, roles do not", () => {
  test("a worker the module creates and calls \"streams\" gains nothing", () => {
    const host = canvas()
    host.render(stack([buy]))
    const module = host.workers.module()
    const streams = host.workers.streams()

    // The host fixed both roles as it started them, from the one bundle.
    assert.deepEqual(host.workers.started.map((worker) => worker.name).sort(), [ROLES.module, ROLES.streams].sort())
    assert.equal(module.url, streams.url)

    // The bearer and the streams worker's channel reach the streams worker
    // alone; the module worker holds only its end of the channel between
    // the two.
    const [streamsBoot] = streams.posted
    const [moduleBoot] = module.posted
    assert.equal(streamsBoot.data.credential, CREDENTIAL)
    assert.deepEqual(Object.keys(moduleBoot.data).sort(), ["mode", "module_url", "port", "t"])
    assert.deepEqual(moduleBoot.transfer, [moduleBoot.data.port])
    assert.notEqual(moduleBoot.data.port, streamsBoot.data.port)
    for (const {data} of module.posted) {
      const {port: _port, canvas: _canvas, ...rest} = data
      assert.ok(!JSON.stringify(rest).includes(CREDENTIAL))
    }

    // Whatever a streams-role worker of the module's own would post reaches
    // the host only on the module worker's channel, where it fails the
    // canvas and labels nothing.
    module.emit({
      t: "relay",
      m: {t: "event", sub: 0, event: {id: 9, event: "feed.results", data: REBOUND}},
      record: {feed: "btc", binding: REBOUND.binding, revision: 9, label: "Bitcoin", actions: [{name: "buy", label: "Refresh"}]}
    })
    assert.deepEqual(host.shell.posted.at(-1).args, {stage: "runtime"})
    assert.equal(host.controls()[0].textContent, "Buy 0.01")
  })
})
