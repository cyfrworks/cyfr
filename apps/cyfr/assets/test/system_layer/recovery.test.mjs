// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {afterEach, beforeEach, describe, test} from "node:test"

import SystemLayer from "../../js/system_layer/index.js"
import {
  clearKit,
  drawKit,
  drawRequestId,
  drawSeed,
  kitRows,
  Material,
  RESTORE_RETRIES,
  restoreOutcome,
  restoreRequest,
  RestorePage,
  SEED_BYTES
} from "../../js/system_layer/recovery.js"

// A cryptographic source that counts its draws and fills each from a
// counter, so every draw is distinct and reproducible.
function countingCrypto() {
  let next = 1
  const source = {
    draws: 0,
    getRandomValues(bytes) {
      source.draws += 1
      for (let i = 0; i < bytes.length; i++) bytes[i] = (next + i) % 256
      next += 7
      return bytes
    }
  }
  return source
}

// The few element members the code under test touches.
function node(tag = "div", attrs = {}) {
  const element = {
    tag,
    attrs: {...attrs},
    children: [],
    hidden: Boolean(attrs.hidden),
    textContent: "",
    value: "",
    dataset: {},
    listeners: {},
    setAttribute(name, value) {
      element.attrs[name] = String(value)
    },
    getAttribute: (name) => element.attrs[name],
    hasAttribute: (name) => name in element.attrs,
    append(...nodes) {
      element.children.push(...nodes)
    },
    replaceChildren(...nodes) {
      element.children = nodes
    },
    addEventListener(event, listener) {
      element.listeners[event] = listener
    },
    removeEventListener(event) {
      delete element.listeners[event]
    }
  }
  return element
}

const fakeDoc = {createElement: (tag) => node(tag)}

// Every text a drawn node holds, its children's included.
function texts(element) {
  return [element.textContent, ...element.children.flatMap((child) => texts(child))].filter(Boolean)
}

// Storage that fails the test if anything reads or writes it.
function forbiddenStorage(name) {
  return new Proxy({}, {
    get(_target, key) {
      throw new Error(`${name}.${String(key)} was touched`)
    },
    set(_target, key) {
      throw new Error(`${name}.${String(key)} was written`)
    }
  })
}

let saved

beforeEach(() => {
  saved = {
    localStorage: Object.getOwnPropertyDescriptor(globalThis, "localStorage"),
    sessionStorage: Object.getOwnPropertyDescriptor(globalThis, "sessionStorage"),
    indexedDB: Object.getOwnPropertyDescriptor(globalThis, "indexedDB")
  }
  for (const name of ["localStorage", "sessionStorage", "indexedDB"]) {
    Object.defineProperty(globalThis, name, {configurable: true, value: forbiddenStorage(name)})
  }
})

afterEach(() => {
  for (const [name, descriptor] of Object.entries(saved)) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor)
    else delete globalThis[name]
  }
})

describe("the seed of a new kit", () => {
  test("is 32 bytes from the cryptographic source, as unpadded base64url", () => {
    const crypto = countingCrypto()
    const seed = drawSeed(crypto)
    assert.equal(crypto.draws, 1)
    assert.match(seed, /^[A-Za-z0-9_-]{43}$/)
    assert.equal(Buffer.from(seed, "base64url").length, SEED_BYTES)
  })

  test("a request id is req_ and 32 hexadecimal digits, as the home's id grammar takes it", () => {
    assert.match(drawRequestId(countingCrypto()), /^req_[0-9a-f]{32}$/)
  })
})

describe("the material a recovery prompt holds", () => {
  test("enrollment draws once and sends the same seed and request id again", () => {
    const crypto = countingCrypto()
    const material = new Material(crypto)

    const first = material.submission("recovery-1", "enrollment")
    const again = material.submission("recovery-1", "enrollment")
    assert.deepEqual(again, first)
    assert.equal(crypto.draws, 2, "one seed and one request id")
    assert.match(first.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
    assert.match(first.request_id, /^req_/)

    const other = material.submission("recovery-2", "enrollment")
    assert.notEqual(other.recovery_secret, first.recovery_secret)
  })

  test("forgotten, nothing of it remains, and a new submission is a new request", () => {
    const material = new Material(countingCrypto())
    const first = material.submission("recovery-1", "enrollment")
    material.forget("recovery-1")
    assert.equal(material.holds("recovery-1"), false)
    assert.notEqual(material.submission("recovery-1", "enrollment").request_id, first.request_id)

    material.forgetAll()
    assert.equal(material.held.size, 0)
  })

  test("another kit needs the signing kit's secret, and keeps it with the drawn one", () => {
    const material = new Material(countingCrypto())
    assert.equal(material.submission("recovery-3", "holder", "   "), null)
    assert.equal(material.holds("recovery-3"), false)

    const sent = material.submission("recovery-3", "holder", " signer-line ")
    assert.equal(sent.recovery_secret, "signer-line")
    assert.equal(sent.holder.kind, "kit")
    assert.notEqual(sent.holder.recovery_secret, "signer-line")

    // The confirmed repeat sends the same request, whatever the form holds now.
    assert.deepEqual(material.submission("recovery-3", "holder", ""), sent)
  })

  test("a kit again sends nothing but its prompt", () => {
    assert.deepEqual(new Material(countingCrypto()).submission("recovery-4", "kit"), {prompt_id: "recovery-4"})
  })
})

describe("a kit's lines", () => {
  const kit = {identifier: "per_abc", directory_url: "https://dir.test", recovery_secret: "c2VlZA"}

  test("are drawn as text into the prompt's own place, and emptied with it", () => {
    const slot = node("div", {hidden: true})
    drawKit(fakeDoc, slot, kit)
    assert.equal(slot.hidden, false)
    assert.deepEqual(texts(slot), ["Identifier", "per_abc", "Directory", "https://dir.test", "Recovery secret", "c2VlZA"])
    assert.deepEqual(kitRows(kit).map(([, , name]) => name), ["kit-identifier", "kit-directory", "kit-secret"])

    clearKit(slot)
    assert.equal(slot.hidden, true)
    assert.deepEqual(texts(slot), [])
  })
})

describe("the restore ingress's request", () => {
  test("carries the token in its authorization header and the kit in its body, never its address", () => {
    const {url, init} = restoreRequest("/restore", "a".repeat(64), {identifier: "per_abc", directory_url: "https://dir.test", recovery_secret: "s"})
    assert.equal(url, "/restore")
    assert.equal(init.method, "POST")
    assert.equal(init.credentials, "same-origin")
    assert.equal(init.cache, "no-store")
    assert.equal(init.headers.authorization, `Bearer ${"a".repeat(64)}`)
    assert.deepEqual(JSON.parse(init.body), {identifier: "per_abc", directory_url: "https://dir.test", recovery_secret: "s"})
    assert.doesNotMatch(init.body, /aaaa/)
  })

  test("its answers read as the page's states", () => {
    assert.equal(restoreOutcome(200, {status: "completed"}).state, "completed")
    assert.deepEqual(
      [restoreOutcome(503, {status: "submitted", retry_after: 2}).state, restoreOutcome(503, {status: "submitted", retry_after: 2}).retryAfter],
      ["retry", 2]
    )
    assert.equal(restoreOutcome(503, {status: "accepted", retry_after: 9999}).retryAfter, 60)
    assert.equal(restoreOutcome(409, {error: "restored"}).state, "restored")
    assert.match(restoreOutcome(409, {error: "superseded"}).text, /nothing was activated/)
    assert.match(restoreOutcome(401, {error: "invalid_token"}).text, /not this installation's/)
    assert.match(restoreOutcome(404, {error: "restore_disabled"}).text, /CYFR_RESTORE_TOKEN/)
    assert.equal(restoreOutcome(500, null).state, "refused")
  })
})

// The restore page's element: its form of four unnamed inputs, its status,
// the reproof control and the link onward.
function restorePage(values) {
  const inputs = Object.fromEntries(["token", "identifier", "directory_url", "recovery_secret"].map((field) => {
    const input = node("input")
    input.value = values[field] ?? ""
    return [field, input]
  }))
  const form = node("form")
  form.querySelector = (selector) => inputs[selector.match(/data-field="([^"]+)"/)[1]]
  form.querySelectorAll = () => Object.values(inputs)
  const status = node("p")
  const reproof = node("button", {hidden: true})
  reproof.hidden = true
  const onward = node("a")
  onward.hidden = true
  const el = node("div")
  el.querySelector = (selector) =>
    ({"[data-restore-form]": form, '[data-test="restore-status"]': status, "[data-restore-reproof]": reproof, "[data-restore-continue]": onward})[selector]
  return {el, form, inputs, status, reproof, onward}
}

const kitValues = {token: "f".repeat(64), identifier: "per_abc", directory_url: "https://dir.test", recovery_secret: "seed-line"}

function scripted(answers) {
  const asked = []
  const fetch = async (url, init) => {
    asked.push({url, init})
    const [status, body] = answers.shift()
    return {status, json: async () => body}
  }
  return {fetch, asked}
}

function manualTimers() {
  const timers = []
  return {
    timers,
    setTimeout: (fn, ms) => timers.push({fn, ms}) - 1,
    clearTimeout: (id) => {
      timers[id] = null
    },
    fire: async () => {
      const timer = timers.findLast((entry) => entry)
      timers[timers.indexOf(timer)] = null
      await timer.fn()
    }
  }
}

describe("the restore page", () => {
  test("asks again under the same token while the restore stands at a phase, then clears what was typed", async () => {
    const page = restorePage(kitValues)
    const {fetch, asked} = scripted([[503, {status: "submitted", retry_after: 2}], [200, {status: "completed"}]])
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    assert.equal(page.status.attrs["data-state"], "retry")
    assert.equal(timers.timers[0].ms, 2000)

    await timers.fire()
    assert.equal(asked.length, 2)
    assert.deepEqual(asked.map((entry) => entry.init.headers.authorization), [`Bearer ${"f".repeat(64)}`, `Bearer ${"f".repeat(64)}`])
    assert.equal(asked[0].init.body, asked[1].init.body)
    assert.ok(asked.every((entry) => entry.url === "/restore"))

    assert.equal(page.status.attrs["data-state"], "completed")
    assert.equal(page.onward.hidden, false)
    assert.ok(Object.values(page.inputs).every((input) => input.value === ""), "the token and the kit leave the form")
    assert.equal(restore.pending, null)
  })

  test("cleared, it forgets the token and the kit and asks nothing more", async () => {
    const page = restorePage(kitValues)
    const {fetch, asked} = scripted([[503, {status: "accepted", retry_after: 1}]])
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    restore.clear("idle", "")
    assert.equal(timers.timers[0], null, "the ask still to come is cancelled")
    assert.equal(restore.pending, null)
    assert.ok(Object.values(page.inputs).every((input) => input.value === ""))
    assert.equal(asked.length, 1)
  })

  test("destroyed with its page, it empties the form and asks nothing more", async () => {
    // Typed and never sent.
    const typed = restorePage(kitValues)
    new RestorePage(typed.el, {fetch: scripted([]).fetch, ...manualTimers()}).destroy()
    assert.ok(Object.values(typed.inputs).every((input) => input.value === ""), "what was typed leaves the form")

    // Sent, with an ask still to come.
    const page = restorePage(kitValues)
    const {fetch, asked} = scripted([[503, {status: "submitted", retry_after: 1}]])
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    restore.destroy()
    assert.ok(Object.values(page.inputs).every((input) => input.value === ""), "the token and the kit leave the form")
    assert.equal(restore.pending, null)
    assert.equal(timers.timers[0], null, "the ask still to come is cancelled")
    assert.equal(page.form.listeners.submit, undefined)
    assert.equal(page.el.listeners.click, undefined)
    assert.equal(asked.length, 1)
  })

  test("a refusal keeps nothing but what the form shows, and asks nothing again", async () => {
    const page = restorePage(kitValues)
    const {fetch, asked} = scripted([[401, {error: "invalid_token"}]])
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    assert.equal(page.status.attrs["data-state"], "refused")
    assert.match(page.status.textContent, /not this installation's/)
    assert.equal(restore.pending, null)
    assert.equal(timers.timers.length, 0)
    assert.equal(asked.length, 1)
  })

  test("a missing line sends nothing", async () => {
    const page = restorePage({...kitValues, recovery_secret: ""})
    const {fetch, asked} = scripted([])
    await new RestorePage(page.el, {fetch, ...manualTimers()}).begin()
    assert.equal(asked.length, 0)
    assert.equal(page.status.attrs["data-state"], "refused")
  })

  test("a completed restore is proven again from the kit under a new challenge", async () => {
    const page = restorePage(kitValues)
    const {fetch, asked} = scripted([
      [409, {error: "restored"}],
      [200, {challenge: "Y2hhbGxlbmdl", expires_at: "2026-10-01T00:05:00Z"}],
      [200, {status: "completed"}]
    ])
    const restore = new RestorePage(page.el, {fetch, ...manualTimers()})

    await restore.begin()
    assert.equal(page.reproof.hidden, false)

    await restore.reproof()
    assert.deepEqual(asked.map((entry) => entry.url), ["/restore", "/restore/challenge", "/restore/reproof"])
    assert.equal(JSON.parse(asked[2].init.body).challenge, "Y2hhbGxlbmdl")
    assert.equal(JSON.parse(asked[1].init.body).recovery_secret, undefined, "the challenge asks for the token alone")
    assert.equal(page.status.attrs["data-state"], "completed")
    assert.equal(page.reproof.hidden, true)
  })

  test("calls the page's own fetch as a function, as a browser requires, never as its method", async () => {
    const page = restorePage(kitValues)
    const original = globalThis.fetch
    const asked = []
    // A browser's fetch refuses any receiver but the window ("Illegal invocation").
    globalThis.fetch = function (url, init) {
      if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation")
      asked.push(url)
      return Promise.resolve({status: 200, json: async () => ({status: "completed"})})
    }
    try {
      await new RestorePage(page.el, manualTimers()).begin()
    } finally {
      globalThis.fetch = original
    }
    assert.deepEqual(asked, ["/restore"])
    assert.equal(page.status.attrs["data-state"], "completed")
  })

  test("gives up asking after its bound of tries", async () => {
    const page = restorePage(kitValues)
    const answers = Array.from({length: RESTORE_RETRIES + 1}, () => [503, {status: "minted", retry_after: 1}])
    const {fetch} = scripted(answers)
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    for (let i = 0; i < RESTORE_RETRIES; i++) await timers.fire()
    assert.equal(page.status.attrs["data-state"], "refused")
    assert.equal(restore.pending, null)
  })
})

describe("the layer's recovery prompts", () => {
  let listeners, pushed, layers

  beforeEach(() => {
    listeners = []
    pushed = []
    layers = []
    globalThis.document = Object.assign(new EventTarget(), fakeDoc, {activeElement: null})
  })

  afterEach(() => {
    for (const layer of layers) layer.destroyed()
    delete globalThis.document
  })

  const push = (event, payload) => {
    for (const listener of listeners) if (listener.event === event) listener.callback(payload)
  }

  // A layer whose prompt holds an enrollment form and the kit's place.
  function layer(id, kind = "enrollment") {
    const form = node("form")
    form.dataset = {recovery: kind, prompt: "recovery-9"}
    const signer = node("input")
    form.querySelector = () => signer
    form.querySelectorAll = () => [signer]
    const slot = node("div", {hidden: true})
    slot.hidden = true
    const dialog = node("dialog")
    Object.assign(dialog, {open: false, showModal() {}, close() {}, matches: () => false, querySelectorAll: () => []})
    const el = node("div")
    el.id = id
    el.dataset = {open: "false", mode: "modal"}
    el.querySelector = (selector) => {
      if (selector === "dialog") return dialog
      if (selector.startsWith("form[data-recovery]")) return form
      if (selector.startsWith("[data-recovery-kit")) return slot
      return null
    }
    el.querySelectorAll = (selector) => (selector === "[data-recovery-kit]" ? [slot] : selector === "form[data-recovery]" ? [form] : [])
    const hook = Object.assign(Object.create(SystemLayer), {
      el,
      framesSee: () => Promise.resolve(),
      handleEvent(event, callback) {
        listeners.push({event, callback})
      },
      pushEventTo(target, event, payload) {
        pushed.push({target: target.id, event, payload})
      }
    })
    hook.mounted()
    layers.push(hook)
    return {hook, el, form, signer, slot}
  }

  const submit = ({el, form}) => {
    let prevented = false
    el.listeners.submit({target: form, preventDefault: () => (prevented = true)})
    return prevented
  }

  test("a submit draws the seed in the browser and sends it, never letting the form submit itself", () => {
    const page = layer("system-layer")
    assert.equal(submit(page), true)

    assert.equal(pushed.length, 1)
    const [{target, event, payload}] = pushed
    assert.deepEqual([target, event], ["system-layer", "recovery_submit"])
    assert.equal(payload.prompt_id, "recovery-9")
    assert.match(payload.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
    assert.match(payload.request_id, /^req_[0-9a-f]{32}$/)
  })

  test("once confirmed, the same material is sent again, by the layer the event names alone", () => {
    const page = layer("system-layer")
    layer("system-layer-panel")
    submit(page)

    push("recovery:resubmit", {layer: "system-layer", prompt: "recovery-9"})
    push("recovery:resubmit", {layer: "elsewhere", prompt: "recovery-9"})

    const sent = pushed.filter((entry) => entry.event === "recovery_submit")
    assert.equal(sent.length, 2)
    assert.deepEqual(sent[1].payload, sent[0].payload)
  })

  test("another kit sends the typed signing secret beside a drawn one", () => {
    const page = layer("system-layer", "holder")
    page.signer.value = " the-signing-line "
    submit(page)
    const [{payload}] = pushed
    assert.equal(payload.recovery_secret, "the-signing-line")
    assert.equal(payload.holder.kind, "kit")
    assert.match(payload.holder.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
  })

  test("a kit's lines are drawn for the layer that asked, and forgotten with the prompt", () => {
    const page = layer("system-layer")
    const panel = layer("system-layer-panel")
    submit(page)
    const kit = {identifier: "per_abc", directory_url: "https://dir.test", recovery_secret: pushed[0].payload.recovery_secret}

    push("recovery:kit", {layer: "system-layer", prompt: "recovery-9", kit})
    assert.equal(page.slot.hidden, false)
    assert.ok(texts(page.slot).includes(kit.recovery_secret))
    assert.equal(panel.slot.hidden, true, "another layer draws nothing")
    assert.equal(page.form.hidden, true)
    assert.equal(page.hook.material.holds("recovery-9"), false, "the drawn seed is let go once answered")

    push("recovery:clear", {layer: "system-layer", prompt: "recovery-9"})
    assert.equal(page.slot.hidden, true)
    assert.deepEqual(texts(page.slot), [])
    assert.equal(page.form.hidden, false)
  })

  test("a reconnect, or the layer going, forgets the material: the next submit is a new request", () => {
    const page = layer("system-layer", "holder")
    page.signer.value = "the-signing-line"
    submit(page)
    const first = pushed[0].payload

    page.hook.reconnected()
    assert.equal(page.signer.value, "", "the typed secret is emptied")
    assert.equal(page.hook.material.held.size, 0)

    page.signer.value = "the-signing-line"
    submit(page)
    assert.notEqual(pushed[1].payload.request_id, first.request_id)

    page.hook.destroyed()
    layers.splice(layers.indexOf(page.hook), 1)
    assert.equal(page.hook.material.held.size, 0)
    assert.equal(page.el.listeners.submit, undefined)
  })
})
