// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

// The shipped desktop's arrangement edits, read from the seed version the
// install media carries.
const dir = new URL(
  "../../../../../seed/components/tinctures/local/desktop/0.1.0/",
  import.meta.url
)
const {add, arrangementOf, installedByRef, move, orderedSlots, refOf, remove, resize} =
  await import(new URL("layout.js", dir))

const document = {
  version: 1,
  postures: {
    desk: {
      desktop: "tincture:local.desktop",
      slots: [
        {id: "b", tincture: "tincture:local.weather", size: "card", order: 5, card: "today"},
        {id: "a", tincture: "tincture:local.notes", size: "icon", order: 5},
        {id: "c", tincture: "tincture:local.game", size: "full", order: 9}
      ],
      floating: [{tincture: "tincture:local.clock", position: {x: 100, y: 200}}]
    }
  }
}

const ids = (doc, posture = "desk") =>
  orderedSlots(arrangementOf(doc, posture, null)).map((slot) => slot.id)

describe("the desktop's arrangement", () => {
  test("slots are drawn by order, then id", () => {
    assert.deepEqual(ids(document), ["a", "b", "c"])
  })

  test("a move reorders and renumbers, clamped to the strip, and leaves the rest alone", () => {
    const moved = move(document, "desk", null, "c", -1)
    assert.deepEqual(ids(moved), ["a", "c", "b"])
    assert.deepEqual(
      moved.postures.desk.slots.map((slot) => slot.order),
      [0, 1, 2]
    )
    assert.deepEqual(moved.postures.desk.floating, document.postures.desk.floating)
    assert.deepEqual(ids(move(document, "desk", null, "a", -5)), ["a", "b", "c"])
    // The document read is never changed in place.
    assert.equal(document.postures.desk.slots[0].order, 5)
  })

  test("a remove drops the slot; a resize moves between icon and card and names no card on an icon", () => {
    assert.deepEqual(ids(remove(document, "desk", null, "b")), ["a", "c"])

    const icon = resize(document, "desk", null, "b", "icon")
    const b = icon.postures.desk.slots.find((slot) => slot.id === "b")
    assert.equal(b.size, "icon")
    assert.equal("card" in b, false)

    const full = resize(document, "desk", null, "c", "icon")
    assert.equal(full.postures.desk.slots.find((slot) => slot.id === "c").size, "full")
    assert.throws(() => resize(document, "desk", null, "a", "full"))
  })

  test("an add places an icon at the end under a free id, in a posture the document did not name", () => {
    const answered = {desktop: "tincture:local.desktop", slots: [], floating: []}
    const added = add(document, "hand", answered, "tincture:local.notes")
    assert.deepEqual(added.postures.hand.slots, [
      {id: "s0", tincture: "tincture:local.notes", size: "icon", order: 0}
    ])
    assert.deepEqual(added.postures.desk, document.postures.desk)
  })

  test("the installed tinctures are read from the component listing by reference", () => {
    const byRef = installedByRef([
      {component_type: "tincture", publisher: "local", name: "notes"},
      {component_type: "reagent", publisher: "local", name: "echo"},
      {component_type: "tincture", publisher: 7, name: "bad"}
    ])
    assert.deepEqual([...byRef.keys()], [refOf("local", "notes")])
  })
})

describe("the desktop page", () => {
  const html = readFileSync(new URL("index.html", dir), "utf8")
  const script = readFileSync(new URL("desktop.js", dir), "utf8")

  test("sets no card text as markup and makes no request of its own", () => {
    assert.equal(/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(script), false)
    assert.equal(/fetch\(|XMLHttpRequest|WebSocket|EventSource|https?:\/\//.test(script), false)
    assert.equal(/https?:\/\//.test(html), false)
  })

  test("labels its strip and its controls", () => {
    assert.match(html, /<ol id="strip"[^>]*aria-label=/)
    assert.match(html, /<label for="add-select">/)
  })
})
