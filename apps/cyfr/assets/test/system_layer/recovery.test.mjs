// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {afterEach, beforeEach, describe, test} from "node:test"

import {jcs} from "../../js/system_layer/device_key.js"
import SystemLayer from "../../js/system_layer/index.js"
import {
  clearCode,
  copyCode,
  drawCode,
  drawRequestId,
  drawSeed,
  endsRecovery,
  exactBytes,
  KIT_OPERATIONS,
  KIT_PROTOCOL,
  kitFields,
  kitItemText,
  kitProof,
  kitRefusal,
  kitRequest,
  kitSignedBytes,
  KitStep,
  Material,
  reenableBody,
  RESTORE_RETRIES,
  restoreOutcome,
  restoreRequest,
  RestorePage,
  SEED_BYTES
} from "../../js/system_layer/recovery.js"

const restoreKit = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/restore_kit.json", import.meta.url), "utf8"))
const codes = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/recovery_code.json", import.meta.url), "utf8"))

// A recovery code a person holds, and the identifier and secret it spells.
const held = codes.valid[0]

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

// The few element members the code under test touches. `closest` and
// `querySelector` read one attribute selector, `[name]` or `[name="value"]`.
function node(tag = "div", attrs = {}) {
  const adopt = (nodes) => {
    for (const child of nodes) child.parent = element
  }
  const element = {
    tag,
    attrs: {...attrs},
    parent: null,
    children: [],
    hidden: Boolean(attrs.hidden),
    own: "",
    // As a browser's: the text of every child, or the element's own; set,
    // it replaces the children.
    get textContent() {
      return element.children.length ? element.children.map((child) => child.textContent).join("") : element.own
    },
    set textContent(text) {
      element.own = String(text)
      element.children = []
    },
    value: "",
    dataset: {},
    listeners: {},
    setAttribute(name, value) {
      element.attrs[name] = String(value)
    },
    getAttribute: (name) => element.attrs[name],
    hasAttribute: (name) => name in element.attrs,
    append(...nodes) {
      adopt(nodes)
      element.children.push(...nodes)
    },
    replaceChildren(...nodes) {
      adopt(nodes)
      element.children = nodes
    },
    closest(selector) {
      for (let at = element; at; at = at.parent) if (matches(at, selector)) return at
      return null
    },
    querySelector: (selector) => walk(element).slice(1).find((child) => matches(child, selector)) ?? null,
    addEventListener(event, listener) {
      element.listeners[event] = listener
    },
    removeEventListener(event) {
      delete element.listeners[event]
    }
  }
  return element
}

function matches(element, selector) {
  const [, name, value] = selector.match(/^\[([\w-]+)(?:="([^"]*)")?\]$/) || []
  if (!name) throw new Error(`the fake document reads no selector ${selector}`)
  return name in element.attrs && (value === undefined || element.attrs[name] === value)
}

const fakeDoc = {createElement: (tag) => node(tag), createTextNode: (text) => ({tag: "#text", textContent: text, children: []})}

// Every text a drawn node holds, by element: a node's text, its
// children's included.
function texts(element) {
  if (element.children.every((child) => child.tag === "#text" || child.tag === "wbr"))
    return [element.textContent].filter(Boolean)
  return element.children.flatMap((child) => texts(child))
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

describe("the secret of a new recovery code", () => {
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
  test("another code draws once and sends the same secret and request id again", () => {
    const crypto = countingCrypto()
    const material = new Material(crypto)

    const first = material.submission("recovery-1", "holder", held.code)
    const again = material.submission("recovery-1", "holder", held.code)
    assert.deepEqual(again, first)
    assert.equal(crypto.draws, 2, "one secret and one request id")
    assert.match(first.holder.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
    assert.match(first.request_id, /^req_/)

    const other = material.submission("recovery-2", "holder", held.code)
    assert.notEqual(other.holder.recovery_secret, first.holder.recovery_secret)
  })

  test("forgotten, nothing of it remains, and a new submission is a new request", () => {
    const material = new Material(countingCrypto())
    const first = material.submission("recovery-1", "holder", held.code)
    material.forget("recovery-1")
    assert.equal(material.holds("recovery-1"), false)
    assert.notEqual(material.submission("recovery-1", "holder", held.code).request_id, first.request_id)

    material.forgetAll()
    assert.equal(material.held.size, 0)
  })

  test("a prompt kind with no material, enrollment among them, draws nothing and sends nothing", () => {
    const crypto = countingCrypto()
    const material = new Material(crypto)
    assert.equal(material.submission("recovery-1", "enrollment"), null)
    assert.equal(material.submission("recovery-1", "pairing"), null)
    assert.equal(crypto.draws, 0)
    assert.equal(material.holds("recovery-1"), false)
  })

  test("another code needs the recovery code that signs it, and keeps it with the drawn secret", () => {
    const material = new Material(countingCrypto())
    assert.equal(material.submission("recovery-3", "holder", "   "), null)
    assert.equal(material.holds("recovery-3"), false)

    const sent = material.submission("recovery-3", "holder", ` ${held.code} `)
    assert.deepEqual(sent, {
      prompt_id: "recovery-3",
      recovery_code: held.code,
      holder: {recovery_secret: sent.holder.recovery_secret},
      request_id: sent.request_id
    })
    assert.match(sent.holder.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
    assert.notEqual(sent.holder.recovery_secret, held.secret)
    assert.match(sent.request_id, /^req_[0-9a-f]{32}$/)

    // The confirmed repeat sends the same request, whatever the form holds now.
    assert.deepEqual(material.submission("recovery-3", "holder", ""), sent)
  })

  test("showing a code again sends nothing but its prompt", () => {
    assert.deepEqual(new Material(countingCrypto()).submission("recovery-4", "kit"), {prompt_id: "recovery-4"})
  })
})

describe("a recovery code", () => {
  const codeSlot = () => {
    const slot = node("div", {"data-recovery-code": "recovery-9"})
    slot.hidden = true
    return slot
  }

  test("is drawn as the text of one element with a Copy button into the prompt's own place, and emptied with it", () => {
    const slot = codeSlot()
    drawCode(fakeDoc, slot, held.code)
    assert.equal(slot.hidden, false)
    const [shown, copy] = slot.children
    assert.equal(slot.children.length, 2)
    assert.deepEqual([shown.tag, shown.attrs, shown.textContent], ["p", {"data-test": "recovery-code", class: "font-mono break-normal"}, held.code])
    // A line breaks only after a hyphen: a <wbr> follows each, and nothing
    // else, and every group is whole.
    const groups = held.code.split("-")
    assert.deepEqual(
      shown.children.map((child) => (child.tag === "wbr" ? "<wbr>" : child.textContent)),
      groups.flatMap((group, i) => (i < groups.length - 1 ? [`${group}-`, "<wbr>"] : [group]))
    )
    assert.deepEqual(
      [copy.tag, copy.attrs.type, copy.attrs["data-recovery-copy"], copy.attrs["data-test"], copy.textContent],
      ["button", "button", "", "recovery-copy", "Copy"]
    )
    assert.deepEqual(texts(slot), [held.code, "Copy"])

    clearCode(slot)
    assert.equal(slot.hidden, true)
    assert.deepEqual(texts(slot), [])
  })

  test("that is absent draws nothing", () => {
    for (const code of [undefined, null, "", {code: held.code}]) {
      const slot = codeSlot()
      drawCode(fakeDoc, slot, code)
      assert.equal(slot.hidden, true)
      assert.deepEqual(slot.children, [])
    }
  })

  test("is written to the clipboard by its Copy button, which then says so", async () => {
    const slot = codeSlot()
    drawCode(fakeDoc, slot, held.code)
    const copy = slot.children[1]
    const written = []
    await copyCode(copy, {writeText: async (text) => written.push(text)})
    assert.deepEqual(written, [held.code])
    assert.equal(copy.textContent, "Copied.")
  })

  test("without a clipboard, or with the write refused, the Copy button stays as it was", async () => {
    for (const clipboard of [undefined, null, {}, {writeText: async () => Promise.reject(new Error("denied"))}, {writeText: () => {
      throw new Error("denied")
    }}]) {
      const slot = codeSlot()
      drawCode(fakeDoc, slot, held.code)
      const copy = slot.children[1]
      await copyCode(copy, clipboard)
      assert.equal(copy.textContent, "Copy")
    }
  })

  test("emptied, leaves its Copy button nothing to write", async () => {
    const slot = codeSlot()
    drawCode(fakeDoc, slot, held.code)
    const copy = slot.children[1]
    clearCode(slot)
    const written = []
    await copyCode(copy, {writeText: async (text) => written.push(text)})
    assert.deepEqual(written, [])
  })
})

describe("the restore ingress's request", () => {
  test("carries the token in its authorization header and the recovery code in its body, never its address", () => {
    const {url, init} = restoreRequest("/restore", "a".repeat(64), {recovery_code: held.code})
    assert.equal(url, "/restore")
    assert.equal(init.method, "POST")
    assert.equal(init.credentials, "same-origin")
    assert.equal(init.cache, "no-store")
    assert.equal(init.headers.authorization, `Bearer ${"a".repeat(64)}`)
    assert.deepEqual(JSON.parse(init.body), {recovery_code: held.code})
    assert.doesNotMatch(url + init.body, /aaaa/)
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
    assert.match(restoreOutcome(401, {error: "invalid_token"}).text, /not this CYFR's/)
    assert.match(restoreOutcome(404, {error: "restore_disabled"}).text, /CYFR_RESTORE_TOKEN/)
    assert.equal(restoreOutcome(500, null).state, "refused")
  })
})

// The restore page's element: its form of two unnamed inputs, its status,
// the reproof control and the link onward.
function restorePage(values) {
  const inputs = Object.fromEntries(["token", "recovery_code"].map((field) => {
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

const restoreValues = {token: "f".repeat(64), recovery_code: held.code}

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
    const page = restorePage(restoreValues)
    const {fetch, asked} = scripted([[503, {status: "submitted", retry_after: 2}], [200, {status: "completed"}]])
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    assert.equal(page.status.attrs["data-state"], "retry")
    assert.equal(timers.timers[0].ms, 2000)

    await timers.fire()
    assert.equal(asked.length, 2)
    assert.deepEqual(asked.map((entry) => entry.init.headers.authorization), [`Bearer ${"f".repeat(64)}`, `Bearer ${"f".repeat(64)}`])
    assert.deepEqual(JSON.parse(asked[0].init.body), {recovery_code: held.code})
    assert.equal(asked[0].init.body, asked[1].init.body)
    assert.ok(asked.every((entry) => entry.url === "/restore"))

    assert.equal(page.status.attrs["data-state"], "completed")
    assert.equal(page.onward.hidden, false)
    assert.ok(Object.values(page.inputs).every((input) => input.value === ""), "the token and the code leave the form")
    assert.equal(restore.pending, null)
  })

  test("cleared, it forgets the token and the code and asks nothing more", async () => {
    const page = restorePage(restoreValues)
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
    const typed = restorePage(restoreValues)
    new RestorePage(typed.el, {fetch: scripted([]).fetch, ...manualTimers()}).destroy()
    assert.ok(Object.values(typed.inputs).every((input) => input.value === ""), "what was typed leaves the form")

    // Sent, with an ask still to come.
    const page = restorePage(restoreValues)
    const {fetch, asked} = scripted([[503, {status: "submitted", retry_after: 1}]])
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    restore.destroy()
    assert.ok(Object.values(page.inputs).every((input) => input.value === ""), "the token and the code leave the form")
    assert.equal(restore.pending, null)
    assert.equal(timers.timers[0], null, "the ask still to come is cancelled")
    assert.equal(page.form.listeners.submit, undefined)
    assert.equal(page.el.listeners.click, undefined)
    assert.equal(asked.length, 1)
  })

  test("a refusal keeps nothing but what the form shows, and asks nothing again", async () => {
    const page = restorePage(restoreValues)
    const {fetch, asked} = scripted([[401, {error: "invalid_token"}]])
    const timers = manualTimers()
    const restore = new RestorePage(page.el, {fetch, ...timers})

    await restore.begin()
    assert.equal(page.status.attrs["data-state"], "refused")
    assert.match(page.status.textContent, /not this CYFR's/)
    assert.equal(restore.pending, null)
    assert.equal(timers.timers.length, 0)
    assert.equal(asked.length, 1)
    assert.equal(page.inputs.recovery_code.value, held.code, "the form keeps the code to mend")
  })

  test("says each refusal of the ingress in its own sentence", async () => {
    const refusals = [
      [422, "not_a_code", "That is not a recovery code. A recovery code starts with CYFR-."],
      [422, "typo", "That recovery code has a typo. Check it against the one you saved."],
      [404, "no_directory", "This CYFR does not reach cyfr.run, so it cannot restore. Ask whoever runs this CYFR."],
      [422, "unknown_identity", "cyfr.run knows no identity with that recovery code."],
      [422, "not_a_holder", "That recovery code is not one of this identity's codes now."],
      [409, "token_claimed", "Another restore holds this CYFR, or this token's restore is another code's."],
      [409, "superseded", "A later recovery replaced the keys this restore introduced, so nothing was activated. Restore again with your recovery code, under a new token."],
      [502, "refused", "cyfr.run refused this recovery. Nothing was activated."],
      [409, "challenge_refused", "The challenge expired or was used. Check your recovery code again."],
      [404, "restore_disabled", "This CYFR is not set up for a restore. Its operator sets CYFR_RESTORE_TOKEN first."],
      [409, "not_empty", "This CYFR already holds a person: a restore runs only on an empty one."]
    ]
    for (const [status, error, sentence] of refusals) {
      const page = restorePage(restoreValues)
      const {fetch, asked} = scripted([[status, {error}]])
      await new RestorePage(page.el, {fetch, ...manualTimers()}).begin()
      assert.deepEqual(JSON.parse(asked[0].init.body), {recovery_code: held.code}, error)
      assert.deepEqual([page.status.attrs["data-state"], page.status.textContent], ["refused", sentence], error)
    }
    assert.equal(restoreOutcome(200, {status: "completed"}).text, "Restored. Your identity is back on this CYFR; register a passkey on your CYFR's settings page to sign in again.")
    assert.equal(restoreOutcome(409, {error: "restored"}).text, "This CYFR was restored already. If no passkey was registered in time, check your recovery code again to sign in.")
  })

  test("a missing token or code sends nothing", async () => {
    for (const values of [{...restoreValues, recovery_code: ""}, {...restoreValues, token: "  "}]) {
      const page = restorePage(values)
      const {fetch, asked} = scripted([])
      const restore = new RestorePage(page.el, {fetch, ...manualTimers()})
      await restore.begin()
      await restore.reproof()
      assert.equal(asked.length, 0)
      assert.deepEqual([page.status.attrs["data-state"], page.status.textContent], ["refused", "Type the installation token and your recovery code."])
    }
  })

  test("a completed restore is checked again with the recovery code under a new challenge", async () => {
    const page = restorePage(restoreValues)
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
    assert.deepEqual(JSON.parse(asked[1].init.body), {}, "the challenge asks for the token alone")
    assert.deepEqual(JSON.parse(asked[2].init.body), {recovery_code: held.code, challenge: "Y2hhbGxlbmdl"})
    assert.ok(asked.every((entry) => entry.init.headers.authorization === `Bearer ${"f".repeat(64)}`))
    assert.equal(page.status.attrs["data-state"], "completed")
    assert.equal(page.reproof.hidden, true)
  })

  test("calls the page's own fetch as a function, as a browser requires, never as its method", async () => {
    const page = restorePage(restoreValues)
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
    const page = restorePage(restoreValues)
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

  // A layer whose prompt holds a recovery form and the code's place.
  function layer(id, kind = "holder") {
    const form = node("form")
    form.dataset = {recovery: kind, prompt: "recovery-9"}
    const signer = node("input")
    form.querySelector = (selector) => (selector === '[data-field="recovery_code"]' ? signer : null)
    form.querySelectorAll = () => [signer]
    const slot = node("div", {"data-recovery-code": "recovery-9"})
    slot.hidden = true
    const dialog = node("dialog")
    Object.assign(dialog, {open: false, showModal() {}, close() {}, matches: () => false, querySelectorAll: () => []})
    const el = node("div")
    el.id = id
    el.dataset = {open: "false", mode: "modal"}
    el.querySelector = (selector) => {
      if (selector === "dialog") return dialog
      if (selector === 'form[data-recovery][data-prompt="recovery-9"]') return form
      if (selector === '[data-recovery-code="recovery-9"]') return slot
      return null
    }
    el.querySelectorAll = (selector) => (selector === "[data-recovery-code]" ? [slot] : selector === "form[data-recovery]" ? [form] : [])
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

  test("a submit draws the secret in the browser and sends it, never letting the form submit itself", () => {
    const page = layer("system-layer")
    page.signer.value = held.code
    assert.equal(submit(page), true)

    assert.equal(pushed.length, 1)
    const [{target, event, payload}] = pushed
    assert.deepEqual([target, event], ["system-layer", "recovery_submit"])
    assert.equal(payload.prompt_id, "recovery-9")
    assert.match(payload.holder.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
    assert.match(payload.request_id, /^req_[0-9a-f]{32}$/)
  })

  test("once confirmed, the same material is sent again, by the layer the event names alone", () => {
    const page = layer("system-layer")
    layer("system-layer-panel")
    page.signer.value = held.code
    submit(page)

    push("recovery:resubmit", {layer: "system-layer", prompt: "recovery-9"})
    push("recovery:resubmit", {layer: "elsewhere", prompt: "recovery-9"})

    const sent = pushed.filter((entry) => entry.event === "recovery_submit")
    assert.equal(sent.length, 2)
    assert.deepEqual(sent[1].payload, sent[0].payload)
  })

  test("another code sends the typed recovery code that signs it beside a drawn secret", () => {
    const page = layer("system-layer", "holder")
    page.signer.value = ` ${held.code} `
    submit(page)
    const [{event, payload}] = pushed
    assert.equal(event, "recovery_submit")
    assert.deepEqual(payload, {
      prompt_id: "recovery-9",
      recovery_code: held.code,
      holder: {recovery_secret: payload.holder.recovery_secret},
      request_id: payload.request_id
    })
    assert.match(payload.holder.recovery_secret, /^[A-Za-z0-9_-]{43}$/)
  })

  test("a code is drawn for the layer that asked, copied by its button, and forgotten with the prompt", async (t) => {
    const navigator = Object.getOwnPropertyDescriptor(globalThis, "navigator")
    t.after(() => (navigator ? Object.defineProperty(globalThis, "navigator", navigator) : delete globalThis.navigator))
    const written = []
    Object.defineProperty(globalThis, "navigator", {configurable: true, value: {clipboard: {writeText: async (text) => written.push(text)}}})

    const page = layer("system-layer")
    const panel = layer("system-layer-panel")
    page.signer.value = held.code
    submit(page)

    push("recovery:code", {layer: "system-layer", prompt: "recovery-9", code: held.code})
    assert.equal(page.slot.hidden, false)
    assert.deepEqual(texts(page.slot), [held.code, "Copy"])
    assert.equal(page.slot.children[0].attrs["data-test"], "recovery-code")
    assert.equal(panel.slot.hidden, true, "another layer draws nothing")
    assert.equal(page.form.hidden, true)
    assert.equal(page.hook.material.holds("recovery-9"), false, "the drawn secret is let go once answered")

    const copy = page.slot.children[1]
    let prevented = false
    await page.el.listeners.click({target: copy, preventDefault: () => (prevented = true)})
    assert.equal(prevented, true)
    assert.deepEqual(written, [held.code])
    assert.equal(copy.textContent, "Copied.")

    // A click anywhere else in the layer writes nothing.
    await page.el.listeners.click({target: page.slot.children[0], preventDefault: () => assert.fail("not the Copy button")})
    assert.equal(written.length, 1)

    push("recovery:clear", {layer: "system-layer", prompt: "recovery-9"})
    assert.equal(page.slot.hidden, true)
    assert.deepEqual(texts(page.slot), [])
    assert.equal(page.form.hidden, false)
  })

  test("a reconnect, or the layer going, forgets the material: the next submit is a new request", () => {
    const page = layer("system-layer", "holder")
    page.signer.value = held.code
    submit(page)
    const first = pushed[0].payload
    push("recovery:code", {layer: "system-layer", prompt: "recovery-9", code: held.code})

    page.hook.reconnected()
    assert.equal(page.signer.value, "", "the typed code is emptied")
    assert.deepEqual(texts(page.slot), [], "the drawn code is emptied")
    assert.equal(page.hook.material.held.size, 0)

    page.signer.value = held.code
    submit(page)
    assert.notEqual(pushed[1].payload.request_id, first.request_id)

    page.hook.destroyed()
    layers.splice(layers.indexOf(page.hook), 1)
    assert.equal(page.hook.material.held.size, 0)
    assert.equal(page.el.listeners.submit, undefined)
  })
})

// ---------------------------------------------------------------------------
// The recovery step: the kit proof of tests/fixtures/restore_kit.json,
// signed by the secret of a code from tests/fixtures/recovery_code.json
// ---------------------------------------------------------------------------

const validKit = restoreKit.valid
const kitFieldsOf = ({restore_id: restoreId, identifier, challenge}) => ({restoreId, identifier, challenge})

describe("the kit proof", () => {
  test("its protocol and challenge length are the fixture's", () => {
    assert.equal(KIT_PROTOCOL, restoreKit.protocol)
    assert.equal(restoreKit.challenge_bytes, 32)
  })

  test("signs the fixture's JCS bytes and reproduces its sig from the seed", async () => {
    const fields = kitFields(kitFieldsOf(validKit.fields))
    assert.equal(new TextDecoder().decode(kitSignedBytes(fields)), validKit.signed)
    assert.equal(new TextDecoder().decode(kitSignedBytes(validKit.proof)), validKit.signed)

    const proof = await kitProof({seed: restoreKit.kit.seed, ...kitFieldsOf(validKit.fields)})
    assert.deepEqual(proof, validKit.proof)
    assert.equal(jcs(proof), jcs(validKit.proof))

    const digest = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(jcs(proof)))).toString("hex")
    assert.equal(`sha256:${digest}`, validKit.digest)
  })

  test("the proof verifies under the kit's public key, and another seed's under its own alone", async () => {
    const verify = async (map, publicKey) => {
      const key = await crypto.subtle.importKey("raw", Buffer.from(publicKey, "base64url"), {name: "Ed25519"}, false, ["verify"])
      return crypto.subtle.verify({name: "Ed25519"}, key, Buffer.from(map.sig, "base64url"), kitSignedBytes(map))
    }
    assert.equal(await verify(validKit.proof, restoreKit.kit.public), true)

    const other = await kitProof({seed: restoreKit.other_kit.seed, ...kitFieldsOf(validKit.fields)})
    const refused = restoreKit.refused.find((entry) => entry.name === "a signature by another seed")
    assert.deepEqual(other, refused.proof)
    assert.equal(await verify(other, restoreKit.kit.public), false)
    assert.equal(await verify(other, restoreKit.other_kit.public), true)
  })

  test("a seed or challenge that is not exactly 32 bytes in unpadded base64url signs nothing", async () => {
    const challenge = validKit.fields.challenge
    for (const seed of [restoreKit.kit.seed + "=", restoreKit.kit.seed.slice(1), "", "not base64!"]) {
      await assert.rejects(kitProof({seed, restoreId: "rst_1", identifier: validKit.fields.identifier, challenge}))
    }
    for (const entry of restoreKit.refused.filter((refused) => refused.error.field === "challenge" && refused.proof.challenge)) {
      assert.equal(exactBytes(entry.proof.challenge, 32), null, entry.name)
      await assert.rejects(kitProof({seed: restoreKit.kit.seed, restoreId: "rst_1", identifier: validKit.fields.identifier, challenge: entry.proof.challenge}), entry.name)
    }
  })
})

describe("the kit ingress's requests", () => {
  test("carry the credential only in the authorization header, once held", () => {
    const asked = kitRequest("/restore/kit/challenge", {identifier: "per_x"})
    assert.equal(asked.init.headers.authorization, undefined)
    assert.equal(asked.init.method, "POST")
    assert.equal(asked.init.cache, "no-store")

    const listed = kitRequest("/restore/kit/reenable", reenableBody("key.reenable"), "rkc_usr_1.secret")
    assert.equal(listed.url, "/restore/kit/reenable")
    assert.equal(listed.init.headers.authorization, "Bearer rkc_usr_1.secret")
    assert.doesNotMatch(listed.url + listed.init.body, /rkc_/)
  })

  test("each operation names its item by its own argument", () => {
    assert.deepEqual(Object.entries(KIT_OPERATIONS), [
      ["key.reenable", "key_id"],
      ["webhook.reenable", "webhook_id"],
      ["pairing.reenable", "client_id"],
      ["passkey.reenable", "passkey_id"]
    ])
    assert.deepEqual(reenableBody("webhook.reenable"), {operation: "webhook.reenable"})
    assert.deepEqual(reenableBody("pairing.reenable", "pcl_1"), {operation: "pairing.reenable", client_id: "pcl_1"})
    assert.throws(() => reenableBody("member.add"))
    assert.deepEqual(Object.keys(KIT_OPERATIONS).filter(endsRecovery), ["pairing.reenable", "passkey.reenable"])
  })

  test("its refusals read as sentences, and an ended credential says so", () => {
    assert.match(kitRefusal(404, {error: "not_recovering"}).text, /no open recovery/)
    assert.equal(kitRefusal(409, {error: "not_a_holder"}).text, "That recovery code is not one of this identity's codes now.")
    assert.match(kitRefusal(409, {error: "challenge_refused"}).text, /expired or was used/)
    assert.equal(kitRefusal(422, {error: "invalid_proof"}).text, "That recovery code did not make a proof this CYFR reads. Check your recovery code.")
    assert.equal(
      kitRefusal(401, {error: "invalid_credential"}).text,
      "This recovery has ended: it lasts ten minutes and ends once a passkey or device is re-enabled. Recover again with your recovery code, or sign in with the method you re-enabled."
    )
    assert.match(kitRefusal(503, null).text, /cyfr\.run could not be reached/)
    assert.match(kitRefusal(409, {error: "revoked"}).text, /never re-enabled/)
    assert.deepEqual([kitRefusal(401, {error: "invalid_credential"}).ended, kitRefusal(403, {error: "operation_not_permitted"}).ended], [true, false])
    assert.equal(kitRefusal(500, null).ended, false)
  })

  test("an item is shown by its name or label", () => {
    assert.equal(kitItemText("key.reenable", {id: "k1", name: "ci", prefix: "cyfr_ab"}), "ci (cyfr_ab…)")
    assert.equal(kitItemText("pairing.reenable", {id: "pcl_1", label: "Phone"}), "Phone")
    assert.equal(kitItemText("passkey.reenable", {id: "pk_1", label: "Laptop", rp_id: "home.test"}), "Laptop (home.test)")
    assert.equal(kitItemText("webhook.reenable", {id: "wh_1"}), "wh_1")
  })
})

// The recovery step's element: its form of one unnamed input, its list
// and its status, with the few members the code touches.
function kitPage(values) {
  const inputs = Object.fromEntries(["recovery_code"].map((field) => {
    const input = node("input")
    input.value = values[field] ?? ""
    return [field, input]
  }))
  const form = node("form")
  form.querySelector = (selector) => inputs[selector.match(/data-field="([^"]+)"/)[1]]
  form.querySelectorAll = () => Object.values(inputs)
  const list = node("div", {hidden: true})
  list.hidden = true
  const status = node("p")
  const el = node("section")
  el.querySelector = (selector) =>
    ({"[data-restore-kit-form]": form, "[data-restore-kit-items]": list, '[data-test="restore-kit-status"]': status})[selector]
  return {el, form, inputs, list, status}
}

// Every element a drawn node holds, its own included.
function walk(element) {
  return [element, ...element.children.flatMap((child) => walk(child))]
}

const kitTyped = {recovery_code: held.code}

// The proof the held code's secret signs over the fixture's challenge.
const heldProof = () => kitProof({seed: held.secret, restoreId: validKit.fields.restore_id, identifier: held.identifier, challenge: validKit.fields.challenge})
const credential = "rkc_usr_01a09fee-0000-7000-8000-000000000001.c2VjcmV0LWNyZWRlbnRpYWwtYnl0ZXMtMzItbG9uZy4"

// A kit ingress that answers by route, recording every request.
function kitIngress({items = {}, reenabled = () => [200, {reenabled: {}}], challenge = [200, {challenge: validKit.fields.challenge, restore_id: validKit.fields.restore_id, expires_at: "2026-10-16T00:05:00Z"}], grant = [200, {credential, expires_at: "2026-10-16T00:10:00Z"}]} = {}) {
  const asked = []
  const fetch = async (url, init) => {
    asked.push({url, init})
    const body = JSON.parse(init.body)
    let answer
    if (url === "/restore/kit/challenge") answer = challenge
    else if (url === "/restore/kit") answer = grant
    else if (url === "/restore/kit/reenable") {
      const argument = KIT_OPERATIONS[body.operation]
      answer = body[argument] ? reenabled(body) : [200, {items: items[body.operation] || []}]
    } else answer = [404, {error: "not_found"}]
    return {status: answer[0], json: async () => answer[1]}
  }
  return {fetch, asked}
}

// Fails the test when anything is logged while `run` runs.
async function silently(run) {
  const said = []
  const saved = {}
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    saved[level] = console[level]
    console[level] = (...args) => said.push(args)
  }
  try {
    return await run()
  } finally {
    Object.assign(console, saved)
    assert.deepEqual(said, [], "nothing is logged")
  }
}

const suspended = {
  "key.reenable": [{id: "key_1", name: "ci", prefix: "cyfr_ab", athanor_id: "ath_1"}],
  "webhook.reenable": [{id: "wh_1", name: "deploys", athanor_id: "ath_1"}],
  "pairing.reenable": [{id: "pcl_1", label: "Phone", athanor_id: "ath_1"}],
  "passkey.reenable": [{id: "pk_1", label: "Laptop", rp_id: "home.test"}]
}

describe("the restore page's recovery step", () => {
  test("reads the recovery code, proves its secret over the home's challenge, then lists each class's suspended items under the credential", async () => {
    const page = kitPage(kitTyped)
    const {fetch, asked} = kitIngress({items: suspended})
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})

    await silently(() => step.begin())

    assert.deepEqual(asked.map((entry) => entry.url), [
      "/restore/kit/challenge",
      "/restore/kit",
      "/restore/kit/reenable",
      "/restore/kit/reenable",
      "/restore/kit/reenable",
      "/restore/kit/reenable"
    ])
    assert.deepEqual(JSON.parse(asked[0].init.body), {identifier: held.identifier})
    assert.deepEqual(JSON.parse(asked[1].init.body), {proof: await heldProof()})
    assert.equal(asked[0].init.headers.authorization, undefined)
    assert.equal(asked[1].init.headers.authorization, undefined)
    assert.deepEqual(asked.slice(2).map((entry) => JSON.parse(entry.init.body)), Object.keys(KIT_OPERATIONS).map((operation) => ({operation})))
    assert.ok(asked.slice(2).every((entry) => entry.init.headers.authorization === `Bearer ${credential}`))

    // Neither the code nor its secret is ever sent, and the code leaves the
    // form once the proof is accepted.
    for (const entry of asked) {
      const sent = entry.url + entry.init.body + JSON.stringify(entry.init.headers)
      assert.ok(!sent.includes(held.secret) && !sent.includes(held.code) && !sent.includes(held.code.slice(5, 13)))
    }
    assert.equal(page.inputs.recovery_code.value, "")

    assert.equal(page.status.attrs["data-state"], "listed")
    assert.equal(page.list.hidden, false)
    const buttons = walk(page.list).filter((element) => element.attrs["data-test"] === "restore-kit-reenable")
    assert.deepEqual(buttons.map((button) => [button.attrs["data-operation"], button.attrs["data-id"]]), [
      ["key.reenable", "key_1"],
      ["webhook.reenable", "wh_1"],
      ["pairing.reenable", "pcl_1"],
      ["passkey.reenable", "pk_1"]
    ])
    assert.ok(texts(page.list).includes("ci (cyfr_ab…)"))
  })

  test("re-enabling a key keeps the recovery; re-enabling a passkey ends it and forgets the credential", async () => {
    const page = kitPage(kitTyped)
    const {fetch, asked} = kitIngress({items: suspended})
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})
    await step.begin()

    await silently(() => step.reenable("key.reenable", "key_1"))
    const keyAsk = asked.at(-1)
    assert.deepEqual(JSON.parse(keyAsk.init.body), {operation: "key.reenable", key_id: "key_1"})
    assert.equal(keyAsk.init.headers.authorization, `Bearer ${credential}`)
    assert.equal(page.status.attrs["data-state"], "reenabled")
    assert.equal(step.credential, credential)
    assert.ok(!texts(page.list).includes("ci (cyfr_ab…)"), "the re-enabled key leaves the list")

    await silently(() => step.reenable("passkey.reenable", "pk_1"))
    assert.deepEqual(JSON.parse(asked.at(-1).init.body), {operation: "passkey.reenable", passkey_id: "pk_1"})
    assert.equal(page.status.attrs["data-state"], "done")
    assert.match(page.status.textContent, /Laptop \(home\.test\) is active again.*Sign in with it/)
    assert.equal(step.credential, null)
    assert.deepEqual(texts(page.list), [])
    assert.equal(page.list.hidden, true)
    assert.ok(Object.values(page.inputs).every((input) => input.value === ""))

    const before = asked.length
    await step.reenable("webhook.reenable", "wh_1")
    assert.equal(asked.length, before, "nothing is asked once the credential is gone")
  })

  test("re-enabling a device ends the recovery too", async () => {
    const page = kitPage(kitTyped)
    const {fetch, asked} = kitIngress({items: suspended})
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})
    await step.begin()
    await step.reenable("pairing.reenable", "pcl_1")
    assert.deepEqual(JSON.parse(asked.at(-1).init.body), {operation: "pairing.reenable", client_id: "pcl_1"})
    assert.equal(page.status.attrs["data-state"], "done")
    assert.equal(step.credential, null)
  })

  test("a refusal of the proof is said, and the form keeps what was typed to mend it", async () => {
    const page = kitPage(kitTyped)
    const {fetch, asked} = kitIngress({grant: [409, {error: "not_a_holder"}]})
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})
    await step.begin()
    assert.equal(asked.length, 2)
    assert.equal(page.status.attrs["data-state"], "refused")
    assert.equal(page.status.textContent, "That recovery code is not one of this identity's codes now.")
    assert.equal(step.credential, null)
    assert.equal(page.inputs.recovery_code.value, held.code)
  })

  test("a home with no open recovery is said, and nothing is signed", async () => {
    const page = kitPage(kitTyped)
    const {fetch, asked} = kitIngress({challenge: [404, {error: "not_recovering"}]})
    await new KitStep(page.el, {fetch, doc: fakeDoc}).begin()
    assert.deepEqual(asked.map((entry) => entry.url), ["/restore/kit/challenge"])
    assert.match(page.status.textContent, /no open recovery/)
  })

  test("an answer that is not a kit challenge is signed over by nothing", async () => {
    const short = restoreKit.refused.find((entry) => entry.name === "a challenge of 31 bytes").proof.challenge
    for (const challenge of [[200, {challenge: short, restore_id: "rst_1"}], [200, {challenge: validKit.fields.challenge}]]) {
      const page = kitPage(kitTyped)
      const {fetch, asked} = kitIngress({challenge})
      await new KitStep(page.el, {fetch, doc: fakeDoc}).begin()
      assert.deepEqual(asked.map((entry) => entry.url), ["/restore/kit/challenge"])
      assert.equal(page.status.attrs["data-state"], "refused")
    }
  })

  test("an ended credential forgets what the page holds", async () => {
    const page = kitPage(kitTyped)
    const {fetch} = kitIngress({items: suspended, reenabled: () => [401, {error: "invalid_credential"}]})
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})
    await step.begin()
    await step.reenable("webhook.reenable", "wh_1")
    assert.equal(step.credential, null)
    assert.equal(page.status.attrs["data-state"], "refused")
    assert.match(page.status.textContent, /recovery has ended/)
    assert.deepEqual(texts(page.list), [])
  })

  test("a refused re-enablement keeps the credential and the list", async () => {
    const page = kitPage(kitTyped)
    const {fetch} = kitIngress({items: suspended, reenabled: () => [409, {error: "revoked"}]})
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})
    await step.begin()
    await step.reenable("key.reenable", "key_1")
    assert.equal(step.credential, credential)
    assert.match(page.status.textContent, /never re-enabled/)
    assert.ok(texts(page.list).includes("ci (cyfr_ab…)"))
  })

  test("a code that does not read, or none, sends nothing and says why", async () => {
    const sentences = {
      not_a_code: "That is not a recovery code. A recovery code starts with CYFR-.",
      typo: "That recovery code has a typo. Check it against the one you saved."
    }
    const cases = [["", "Type your recovery code."], ...codes.refused.map(({text, error}) => [text, sentences[error]])]
    assert.deepEqual(new Set(codes.refused.map(({error}) => error)), new Set(Object.keys(sentences)))
    for (const [text, sentence] of cases) {
      const page = kitPage({recovery_code: text})
      let asked = 0
      const fetch = async () => {
        asked += 1
        throw new Error("nothing is asked")
      }
      await new KitStep(page.el, {fetch, doc: fakeDoc}).begin()
      assert.equal(asked, 0, text)
      assert.deepEqual([page.status.attrs["data-state"], page.status.textContent], ["refused", sentence], text)
      assert.equal(page.inputs.recovery_code.value, text.trim(), "the form keeps the code to mend")
    }
  })

  test("a code that does not read leaves the credential and the list it holds", async () => {
    const page = kitPage(kitTyped)
    const {fetch, asked} = kitIngress({items: suspended})
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})
    await step.begin()
    const before = asked.length

    page.inputs.recovery_code.value = codes.refused.find(({error}) => error === "typo").text
    await step.begin()
    assert.equal(asked.length, before)
    assert.equal(step.credential, credential)
    assert.ok(texts(page.list).includes("ci (cyfr_ab…)"))
  })

  test("a browser without WebCrypto reads no code, and says to use a current one", async () => {
    for (const crypto of [null, {}]) {
      const page = kitPage(kitTyped)
      const {fetch, asked} = kitIngress()
      await new KitStep(page.el, {fetch, crypto, doc: fakeDoc}).begin()
      assert.equal(asked.length, 0)
      assert.deepEqual([page.status.attrs["data-state"], page.status.textContent], ["refused", "This browser cannot read your recovery code. Use a current browser."])
    }
  })

  test("cleared while the code is read, it asks nothing", async () => {
    const page = kitPage(kitTyped)
    const {fetch, asked} = kitIngress()
    let release
    const gate = new Promise((resolve) => (release = resolve))
    const slow = {subtle: {digest: async (algorithm, bytes) => {
      await gate
      return globalThis.crypto.subtle.digest(algorithm, bytes)
    }}}
    const step = new KitStep(page.el, {fetch, crypto: slow, doc: fakeDoc})
    const running = step.begin()
    step.clear("idle", "")
    release()
    await running
    assert.equal(asked.length, 0)
    assert.equal(page.status.attrs["data-state"], "idle")
  })

  test("cleared while an answer is awaited, it forgets the code and the credential and drops the answer", async () => {
    const page = kitPage(kitTyped)
    let release
    const gate = new Promise((resolve) => (release = resolve))
    const {fetch: answer, asked} = kitIngress({items: suspended})
    let granting
    const reached = new Promise((resolve) => (granting = resolve))
    const fetch = async (url, init) => {
      if (url === "/restore/kit") {
        granting()
        await gate
      }
      return answer(url, init)
    }
    const step = new KitStep(page.el, {fetch, doc: fakeDoc})
    const running = step.begin()
    await reached

    step.clear("idle", "")
    release()
    await running
    assert.equal(step.credential, null)
    assert.ok(Object.values(page.inputs).every((input) => input.value === ""))
    assert.deepEqual(asked.map((entry) => entry.url), ["/restore/kit/challenge", "/restore/kit"], "no list is asked under a credential the clear dropped")
    assert.equal(page.status.attrs["data-state"], "idle")
  })

  test("the restore page drives the recovery step its element holds, and destroys it with itself", async () => {
    const kit = kitPage(kitTyped)
    const page = restorePage(restoreValues)
    const outer = page.el.querySelector
    page.el.querySelector = (selector) => (selector === "[data-restore-kit]" ? kit.el : outer(selector))
    const {fetch, asked} = kitIngress({items: suspended})
    const restore = new RestorePage(page.el, {fetch, doc: fakeDoc, ...manualTimers()})
    assert.ok(restore.kit instanceof KitStep)

    await restore.kit.begin()
    assert.equal(asked[0].url, "/restore/kit/challenge")
    assert.equal(restore.kit.credential, credential)

    restore.destroy()
    assert.equal(restore.kit.credential, null)
    assert.ok(Object.values(kit.inputs).every((input) => input.value === ""))
    assert.equal(kit.form.listeners.submit, undefined)
    assert.equal(kit.el.listeners.click, undefined)
  })
})
