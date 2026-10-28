// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The sign-in carry's browser half (`js/hooks/carry.js`): every fragment
// is read and cleared from the address at once; a carry reaches the
// destination's page only after the person named their home there, once
// and while that expectation is fresh; nothing over the fragment bound is
// handed on; what arrives for the signing home before its person signed in
// is kept through the sign-in, then taken once; the actions a tab began are
// remembered with their destination and key_epoch. The fragments and
// returns of `tests/fixtures/carry.json`, which the homes read too, are
// held to the hook first.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {dirname, resolve} from "node:path"
import {describe, test} from "node:test"
import {fileURLToPath} from "node:url"

import Carry, {
  EXPECT_KEY,
  LIFETIME_MS,
  MAX_FRAGMENT_BYTES,
  SOURCE_KEY,
  classify,
  decodeObject,
  resume,
  sourceState
} from "../../js/hooks/carry.js"

const here = dirname(fileURLToPath(import.meta.url))
const vectors = JSON.parse(readFileSync(resolve(here, "../../../../../tests/fixtures/carry.json"), "utf8"))

const b64url = (object) => Buffer.from(JSON.stringify(object)).toString("base64url")

const challenge = (actionId = "car_1") =>
  b64url({
    protocol: "cyfr-carry/v1",
    action_id: actionId,
    audience: "https://hub.example",
    challenge: Buffer.alloc(32, 7).toString("base64url")
  })

const returned = (actionId = "car_1", outcome = "admitted") =>
  b64url({protocol: "cyfr-carry/v1", action_id: actionId, outcome})

const carry = "carry=" + b64url({envelope: {source: "https://a.example"}, payload: {}})

function memoryStorage() {
  const items = new Map()
  return {
    items,
    getItem: (key) => (items.has(key) ? items.get(key) : null),
    setItem: (key, value) => items.set(key, String(value)),
    removeItem: (key) => items.delete(key)
  }
}

// A window at `pathname` with `hash`, its history and its tab's storage.
function fakeWindow(pathname, hash = "", storage = memoryStorage()) {
  const win = {
    sessionStorage: storage,
    assigned: [],
    replaced: [],
    location: {
      pathname,
      search: "",
      hash,
      assign: (to) => win.assigned.push(to)
    },
    history: {
      state: {live: true},
      replaceState: (state, _title, url) => {
        win.replaced.push({state, url})
        win.location.hash = ""
      }
    }
  }
  return win
}

// The hook mounted on `win` as `role` ("login" or "source") at `now`.
function mount(win, role, now = 1_000_000) {
  const pushed = []
  const handlers = {}
  const hook = Object.assign(Object.create(Carry), {
    win,
    el: {dataset: {carry: role, lifetimeMs: String(LIFETIME_MS), maxFragment: String(MAX_FRAGMENT_BYTES)}},
    now: () => now,
    pushEvent: (event, payload) => pushed.push({event, payload}),
    handleEvent: (event, handler) => (handlers[event] = handler)
  })
  hook.mounted()
  return {hook, pushed, handlers}
}

const events = (pushed) => pushed.map(({event}) => event)

// A fragment vector's text: the fragment it names, or a repeat of a char.
const fragmentOf = (vector) => (vector.repeat ? vector.repeat.char.repeat(vector.repeat.length) : vector.fragment)

describe("carry.json", () => {
  test("the hook's bound is the homes' fragment bound", () => {
    assert.equal(MAX_FRAGMENT_BYTES, vectors.max_fragment_bytes)
  })

  test("a carry fragment over the bound is never handed on; within it, the home decides it, whole", () => {
    const parse = vectors.fragments.parse
    assert.ok(parse.some((vector) => vector.error === "carry_too_large"))
    assert.ok(parse.some((vector) => vector.error !== "carry_too_large"))

    for (const vector of parse) {
      const fragment = fragmentOf(vector)
      const storage = memoryStorage()
      storage.setItem(EXPECT_KEY, JSON.stringify({home: "https://alice.example", at: 1_000_000}))
      const {pushed} = mount(fakeWindow("/login", "#carry=" + fragment, storage), "login")

      if (vector.error === "carry_too_large") {
        assert.deepEqual(classify("carry=" + fragment), {kind: "too_large"}, vector.name)
        assert.deepEqual(pushed, [{event: "cyfr_oversized", payload: {}}], vector.name)
      } else {
        // Within the bound the homes refuse it when they parse it: the hook
        // hands the fragment on exactly, never truncated or repaired.
        assert.deepEqual(classify("carry=" + fragment), {kind: "carry", value: fragment}, vector.name)
        assert.deepEqual(
          pushed,
          [{event: "cyfr_carry", payload: {fragment, expected_source: "https://alice.example"}}],
          vector.name
        )
      }
    }
  })

  test("the valid fragment is handed on as the home wrote it, and reads back as its payload", () => {
    const {fragment, payload} = vectors.fragments.valid
    assert.ok(new TextEncoder().encode(fragment).length <= vectors.max_fragment_bytes)
    assert.deepEqual(classify("carry=" + fragment), {kind: "carry", value: fragment})
    assert.deepEqual(decodeObject(fragment).payload, payload)
  })

  test("each return is read as a return of its action and handed to /carry exactly", () => {
    for (const name of ["admitted", "refused"]) {
      const {fragment, return: returned} = vectors.returns[name]
      assert.deepEqual(decodeObject(fragment), returned, name)
      assert.deepEqual(classify(fragment), {kind: "return", fragment, actionId: returned.action_id}, name)

      const {pushed} = mount(fakeWindow("/carry", "#" + fragment), "source")
      assert.deepEqual(pushed, [{event: "carry_return", payload: {fragment}}], name)
    }
  })

  test("a malformed return: one without its action is nothing here, any other the home refuses", () => {
    const refusals = vectors.returns.refusals
    assert.ok(refusals.some(({return: returned}) => !("action_id" in returned)))

    for (const {name, return: returned} of refusals) {
      const fragment = b64url(returned)
      const {pushed} = mount(fakeWindow("/carry", "#" + fragment), "source")

      if (typeof returned.action_id !== "string") {
        // No action to return to: the hook hands nothing on.
        assert.equal(classify(fragment).kind, "unknown", name)
        assert.deepEqual(pushed, [], name)
      } else {
        // Its fields are the home's to refuse (`Prima.Carry.Return`): the
        // hook hands it on whole, never a reading of its own.
        assert.deepEqual(classify(fragment), {kind: "return", fragment, actionId: returned.action_id}, name)
        assert.deepEqual(pushed, [{event: "carry_return", payload: {fragment}}], name)
      }
    }
  })

  test("a return over the bound is never handed on", () => {
    const fragment = "A".repeat(vectors.max_fragment_bytes + 1)
    assert.deepEqual(classify(fragment), {kind: "too_large"})
    const {pushed} = mount(fakeWindow("/carry", "#" + fragment), "source")
    assert.deepEqual(pushed, [{event: "carry_oversized", payload: {}}])
  })
})

describe("reading a fragment", () => {
  test("each kind is told apart, and the bound is checked before anything is decoded", () => {
    assert.deepEqual(classify(carry), {kind: "carry", value: carry.slice(6)})
    assert.deepEqual(classify("cyfr=abc"), {kind: "assertion", value: "abc"})
    assert.deepEqual(classify("destination=https%3A%2F%2Fhub.example"), {
      kind: "destination",
      destination: "https://hub.example"
    })
    assert.deepEqual(classify(challenge()), {kind: "challenge", fragment: challenge(), actionId: "car_1"})
    assert.deepEqual(classify(returned()), {kind: "return", fragment: returned(), actionId: "car_1"})
    assert.equal(classify("not base64 !").kind, "unknown")
    assert.equal(classify(b64url([1, 2])).kind, "unknown")
    assert.equal(classify("carry=").kind, "unknown")
    assert.equal(classify("").kind, "none")
    assert.equal(classify("carry=" + "A".repeat(MAX_FRAGMENT_BYTES + 1)).kind, "too_large")
    // The bound is the encoded carry's, after its key, as the homes hold it.
    assert.equal(classify("carry=" + "A".repeat(MAX_FRAGMENT_BYTES)).kind, "carry")
    assert.equal(classify("A".repeat(MAX_FRAGMENT_BYTES + 1)).kind, "too_large")
  })

  test("a base64url JSON object decodes; anything else is nothing", () => {
    assert.deepEqual(decodeObject(b64url({a: 1})), {a: 1})
    assert.equal(decodeObject("A"), null)
    assert.equal(decodeObject("e30="), null)
  })
})

describe("at the destination's sign-in page", () => {
  test("naming a home keeps the expectation, then goes there", () => {
    const win = fakeWindow("/login")
    const {handlers} = mount(win, "login", 5_000)

    handlers["cyfr:expect"]({home: "https://a.example", to: "https://a.example/carry#destination=x"})

    assert.deepEqual(JSON.parse(win.sessionStorage.getItem(EXPECT_KEY)), {home: "https://a.example", at: 5_000})
    assert.deepEqual(win.assigned, ["https://a.example/carry#destination=x"])
  })

  test("a carry after the person named their home is handed on once, naming that home, and cleared from the address", () => {
    const storage = memoryStorage()
    storage.setItem(EXPECT_KEY, JSON.stringify({home: "https://a.example", at: 1_000_000 - 1_000}))
    const win = fakeWindow("/login", "#" + carry, storage)

    const {pushed} = mount(win, "login")

    assert.deepEqual(pushed, [
      {event: "cyfr_carry", payload: {fragment: carry.slice(6), expected_source: "https://a.example"}}
    ])
    assert.equal(win.location.hash, "")
    assert.deepEqual(win.replaced, [{state: {live: true}, url: "/login"}])
    assert.equal(storage.getItem(EXPECT_KEY), null, "the expectation is used once")

    // The same carry again: the expectation is gone.
    const again = mount(fakeWindow("/login", "#" + carry, storage), "login")
    assert.deepEqual(events(again.pushed), ["cyfr_unsolicited"])
  })

  test("an unsolicited carry raises no cyfr_carry", () => {
    const {pushed} = mount(fakeWindow("/login", "#" + carry), "login")
    assert.ok(!events(pushed).includes("cyfr_carry"))
    assert.deepEqual(events(pushed), ["cyfr_unsolicited"])
  })

  test("a stale expectation raises no cyfr_carry, and is cleared", () => {
    const storage = memoryStorage()
    storage.setItem(EXPECT_KEY, JSON.stringify({home: "https://a.example", at: 1_000_000 - LIFETIME_MS}))

    const {pushed} = mount(fakeWindow("/login", "#" + carry, storage), "login")

    assert.ok(!events(pushed).includes("cyfr_carry"))
    assert.equal(storage.getItem(EXPECT_KEY), null)
  })

  test("an expectation from the future is no expectation", () => {
    const storage = memoryStorage()
    storage.setItem(EXPECT_KEY, JSON.stringify({home: "https://a.example", at: 2_000_000}))
    const {pushed} = mount(fakeWindow("/login", "#" + carry, storage), "login")
    assert.ok(!events(pushed).includes("cyfr_carry"))
  })

  test("the person's home's assertion is handed on to be posted", () => {
    const {pushed} = mount(fakeWindow("/login", "#cyfr=abc"), "login")
    assert.deepEqual(pushed, [{event: "cyfr_assertion", payload: {fragment: "abc"}}])
  })

  test("an oversized fragment posts nothing, and leaves the expectation for the carry's own retry", () => {
    const storage = memoryStorage()
    storage.setItem(EXPECT_KEY, JSON.stringify({home: "https://a.example", at: 1_000_000}))
    const win = fakeWindow("/login", "#carry=" + "A".repeat(MAX_FRAGMENT_BYTES + 1), storage)

    const {pushed} = mount(win, "login")

    assert.deepEqual(events(pushed), ["cyfr_oversized"])
    assert.equal(win.location.hash, "", "the fragment is cleared all the same")
    assert.notEqual(storage.getItem(EXPECT_KEY), null, "nothing used it")
  })

  test("a missing fragment hands nothing on", () => {
    const {pushed} = mount(fakeWindow("/login"), "login")
    assert.deepEqual(pushed, [])
  })
})

describe("at the signing home, through its sign-in", () => {
  test("what arrives for /carry before the person signed in is kept, not handed on", () => {
    for (const fragment of [challenge(), returned(), "destination=https%3A%2F%2Fhub.example"]) {
      const storage = memoryStorage()
      const {pushed} = mount(fakeWindow("/login", "#" + fragment, storage), "login")

      assert.deepEqual(pushed, [])
      assert.equal(sourceState(storage).transport.fragment, fragment)
    }
  })

  test("after the sign-in, any page goes back to /carry once, which takes it and clears it", () => {
    const storage = memoryStorage()
    mount(fakeWindow("/login", "#" + challenge("car_9"), storage), "login", 1_000_000)

    // The sign-in page itself and /carry do not go anywhere.
    assert.equal(resume(fakeWindow("/login", "", storage), 1_000_100), false)

    const landed = fakeWindow("/chat", "", storage)
    assert.equal(resume(landed, 1_000_100), true)
    assert.deepEqual(landed.assigned, ["/carry"])

    const {pushed} = mount(fakeWindow("/carry", "", storage), "source", 1_000_200)
    assert.deepEqual(pushed, [{event: "carry_challenge", payload: {fragment: challenge("car_9"), own: false}}])
    assert.equal(sourceState(storage).transport, null)
    assert.equal(resume(fakeWindow("/chat", "", storage), 1_000_300), false, "kept only across that sign-in")
  })

  test("a kept fragment past the carry's lifetime is dropped, and nobody is sent anywhere", () => {
    const storage = memoryStorage()
    mount(fakeWindow("/login", "#" + challenge(), storage), "login", 1_000_000)

    const late = fakeWindow("/chat", "", storage)
    assert.equal(resume(late, 1_000_000 + LIFETIME_MS), false)
    assert.deepEqual(late.assigned, [])
    assert.equal(storage.getItem(SOURCE_KEY), null)
  })
})

describe("at the signing home's /carry", () => {
  test("a destination only fills the form", () => {
    const {pushed} = mount(fakeWindow("/carry", "#destination=https%3A%2F%2Fhub.example"), "source")
    assert.deepEqual(pushed, [{event: "carry_destination", payload: {destination: "https://hub.example"}}])
  })

  test("a begun carry is remembered with its destination and key_epoch, then taken there", () => {
    const storage = memoryStorage()
    const win = fakeWindow("/carry", "", storage)
    const {handlers} = mount(win, "source", 2_000)
    const to = "https://hub.example/login#carry=" + "x".repeat(100)

    handlers["carry:begun"]({action_id: "car_1", destination: "https://hub.example", key_epoch: "sha256:ab", to})

    assert.deepEqual(win.assigned, [to])
    assert.deepEqual(sourceState(storage).actions, {
      car_1: {destination: "https://hub.example", key_epoch: "sha256:ab", at: 2_000}
    })

    // Its challenge comes back to this tab: asked for at once.
    const back = mount(fakeWindow("/carry", "#" + challenge("car_1"), storage), "source", 3_000)
    assert.deepEqual(back.pushed, [{event: "carry_challenge", payload: {fragment: challenge("car_1"), own: true}}])
  })

  test("a challenge for an action this tab did not begin, or began too long ago, is not its own", () => {
    const storage = memoryStorage()
    const {handlers} = mount(fakeWindow("/carry", "", storage), "source", 0)
    handlers["carry:begun"]({action_id: "car_1", destination: "https://hub.example", key_epoch: "k", to: "x"})

    const crafted = mount(fakeWindow("/carry", "#" + challenge("car_2"), storage), "source", 10)
    assert.equal(crafted.pushed[0].payload.own, false)

    const late = mount(fakeWindow("/carry", "#" + challenge("car_1"), storage), "source", LIFETIME_MS)
    assert.equal(late.pushed[0].payload.own, false)
  })

  test("an oversized carry is not taken anywhere", () => {
    const storage = memoryStorage()
    const win = fakeWindow("/carry", "", storage)
    const {handlers, pushed} = mount(win, "source")

    handlers["carry:begun"]({
      action_id: "car_1",
      destination: "https://hub.example",
      key_epoch: "k",
      to: "https://hub.example/login#carry=" + "A".repeat(MAX_FRAGMENT_BYTES + 1)
    })

    assert.deepEqual(win.assigned, [])
    assert.deepEqual(events(pushed), ["carry_oversized"])
    assert.deepEqual(sourceState(storage).actions, {})
  })

  test("a return is handed on, and a recorded one forgotten", () => {
    const storage = memoryStorage()
    const {handlers} = mount(fakeWindow("/carry", "", storage), "source", 0)
    handlers["carry:begun"]({action_id: "car_1", destination: "https://hub.example", key_epoch: "k", to: "x"})

    const back = mount(fakeWindow("/carry", "#" + returned("car_1"), storage), "source", 10)
    assert.deepEqual(back.pushed, [{event: "carry_return", payload: {fragment: returned("car_1")}}])

    back.handlers["carry:forget"]({action_id: "car_1"})
    assert.equal(storage.getItem(SOURCE_KEY), null)
  })

  test("a carry or an assertion meant for a destination's page is nothing here", () => {
    for (const fragment of [carry, "cyfr=abc"]) {
      const {pushed} = mount(fakeWindow("/carry", "#" + fragment), "source")
      assert.deepEqual(pushed, [])
    }
  })

  test("the address's fragment is cleared, and goes where the page says when within the bound", () => {
    const win = fakeWindow("/carry", "#" + challenge())
    const {handlers, pushed} = mount(win, "source")
    assert.equal(win.location.hash, "")

    handlers["carry:go"]({to: "https://hub.example/login#cyfr=abc"})
    assert.deepEqual(win.assigned, ["https://hub.example/login#cyfr=abc"])

    handlers["carry:go"]({to: "https://hub.example/login#cyfr=" + "A".repeat(MAX_FRAGMENT_BYTES + 1)})
    assert.equal(win.assigned.length, 1)
    assert.equal(events(pushed).at(-1), "carry_oversized")
  })

  test("a store that refuses every write keeps nothing and breaks nothing", () => {
    const refusing = {
      getItem: () => null,
      setItem: () => {
        throw new Error("quota")
      },
      removeItem: () => {}
    }
    const win = fakeWindow("/carry", "", refusing)
    const {handlers} = mount(win, "source")
    handlers["carry:begun"]({action_id: "car_1", destination: "https://hub.example", key_epoch: "k", to: "x"})
    assert.deepEqual(win.assigned, ["x"])
  })
})

const certify = "certify=" + b64url({audience: "https://hub.example", athanor: "ath_hub", client_id: "pcl_hub", device_key: "k"})

describe("what the first carry tests left open", () => {
  test("a kept fragment /carry takes past the carry's lifetime is dropped, and hands nothing on", () => {
    const storage = memoryStorage()
    mount(fakeWindow("/login", "#" + challenge("car_9"), storage), "login", 1_000_000)

    const late = mount(fakeWindow("/carry", "", storage), "source", 1_000_000 + LIFETIME_MS)
    assert.deepEqual(late.pushed, [])
    assert.equal(storage.getItem(SOURCE_KEY), null)

    // Within the lifetime, the same fragment is handed on.
    mount(fakeWindow("/login", "#" + challenge("car_9"), storage), "login", 2_000_000)
    const fresh = mount(fakeWindow("/carry", "", storage), "source", 2_000_000 + LIFETIME_MS - 1)
    assert.deepEqual(events(fresh.pushed), ["carry_challenge"])
  })

  test("the informational events carry nothing of the fragment", () => {
    assert.deepEqual(mount(fakeWindow("/login", "#" + carry), "login").pushed, [{event: "cyfr_unsolicited", payload: {}}])

    const oversized = "#carry=" + "A".repeat(MAX_FRAGMENT_BYTES + 1)
    assert.deepEqual(mount(fakeWindow("/login", oversized), "login").pushed, [{event: "cyfr_oversized", payload: {}}])
    assert.deepEqual(mount(fakeWindow("/carry", oversized), "source").pushed, [{event: "carry_oversized", payload: {}}])

    const {handlers, pushed} = mount(fakeWindow("/carry"), "source")
    handlers["carry:go"]({to: "https://hub.example/login#cyfr=" + "A".repeat(MAX_FRAGMENT_BYTES + 1)})
    assert.deepEqual(pushed, [{event: "carry_oversized", payload: {}}])
  })

  test("a resumed exchange goes back to its home keeping no expectation, so no carry can use one", () => {
    const storage = memoryStorage()
    const win = fakeWindow("/login", "", storage)
    const {handlers} = mount(win, "login", 5_000)

    handlers["cyfr:go"]({to: "/auth/cyfr?ticket=abc"})
    assert.deepEqual(win.assigned, ["/auth/cyfr?ticket=abc"])
    assert.equal(storage.getItem(EXPECT_KEY), null)

    // A carry arriving after it is unsolicited.
    const after = mount(fakeWindow("/login", "#" + carry, storage), "login", 6_000)
    assert.deepEqual(events(after.pushed), ["cyfr_unsolicited"])
  })
})

describe("a device to certify", () => {
  test("is its own kind, bounded like the others", () => {
    assert.deepEqual(classify(certify), {kind: "certify", value: certify.slice(8)})
    assert.equal(classify("certify=").kind, "unknown")
    assert.equal(classify("certify=" + "A".repeat(MAX_FRAGMENT_BYTES + 1)).kind, "too_large")
  })

  test("is kept through the signing home's sign-in, then handed to /carry once, only to show", () => {
    const storage = memoryStorage()
    const atLogin = mount(fakeWindow("/login", "#" + certify, storage), "login", 1_000_000)
    assert.deepEqual(atLogin.pushed, [])
    assert.equal(sourceState(storage).transport.fragment, certify)

    const landed = fakeWindow("/", "", storage)
    assert.equal(resume(landed, 1_000_100), true)
    assert.deepEqual(landed.assigned, ["/carry"])

    const {pushed} = mount(fakeWindow("/carry", "", storage), "source", 1_000_200)
    assert.deepEqual(pushed, [{event: "carry_certify", payload: {fragment: certify.slice(8)}}])
    assert.equal(sourceState(storage).transport, null)
  })

  test("arriving at /carry signed in, it is handed on and cleared from the address", () => {
    const win = fakeWindow("/carry", "#" + certify)
    const {pushed} = mount(win, "source")
    assert.deepEqual(events(pushed), ["carry_certify"])
    assert.equal(win.location.hash, "")
  })
})
