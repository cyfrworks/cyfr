// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {
  GRIDS,
  HAND_BELOW_PX,
  isPosture,
  parseSlots,
  postureFor,
  slotGeometry,
  stylesheet
} from "../../js/canvas/geometry.js"

describe("the posture", () => {
  test("under 768 CSS pixels wide is hand, and 768 or wider is desk", () => {
    assert.equal(HAND_BELOW_PX, 768)
    assert.equal(postureFor(375), "hand")
    assert.equal(postureFor(767.5), "hand")
    assert.equal(postureFor(768), "desk")
    assert.equal(postureFor(1440), "desk")
  })

  test("a width that is not a number is desk", () => {
    for (const width of [undefined, null, NaN, Infinity, "400"]) {
      assert.equal(postureFor(width), "desk")
    }
  })

  test("only hand and desk are postures", () => {
    assert.ok(isPosture("hand") && isPosture("desk"))
    for (const value of ["tablet", "", null, undefined, 1]) assert.equal(isPosture(value), false)
  })
})

describe("the slot list the server rendered", () => {
  test("is read in order, id breaking a tie, and anything that is not a slot is left out", () => {
    const slots = parseSlots(
      JSON.stringify([
        {id: "b", size: "icon", order: 1},
        {id: "a", size: "card", order: 1},
        {id: "z", size: "full", order: 0},
        {id: "Bad id", size: "icon", order: 2},
        {id: "x", size: "huge", order: 2},
        {id: "y", size: "icon", order: -1},
        {id: "w", size: "icon", order: 2, extra: "dropped"},
        null
      ])
    )

    assert.deepEqual(slots, [
      {id: "z", size: "full", order: 0},
      {id: "a", size: "card", order: 1},
      {id: "b", size: "icon", order: 1},
      {id: "w", size: "icon", order: 2}
    ])
  })

  test("text that is not a JSON list reads as nothing, so the last list stays", () => {
    for (const text of [undefined, "", "{", "{}", "null", "3"]) assert.equal(parseSlots(text), null)
    assert.deepEqual(parseSlots("[]"), [])
  })
})

describe("slot geometry", () => {
  const desk = GRIDS.desk

  test("icons fill a row cell by cell from the padding", () => {
    const geometry = slotGeometry(
      [
        {id: "a", size: "icon"},
        {id: "b", size: "icon"}
      ],
      1024,
      "desk"
    )

    assert.deepEqual(geometry, [
      {id: "a", left: desk.pad, top: desk.pad, width: desk.cell, height: desk.cell},
      {
        id: "b",
        left: desk.pad + desk.cell + desk.gap,
        top: desk.pad,
        width: desk.cell,
        height: desk.cell
      }
    ])
  })

  test("a slot too wide for the rest of its row starts the next, below the row's tallest", () => {
    // 1024 wide: (1024 - 48 + 16) / 104 = 9 columns.
    const slots = [
      {id: "a", size: "card"},
      {id: "b", size: "icon"},
      {id: "c", size: "full"}
    ]
    const [card, icon, full] = slotGeometry(slots, 1024, "desk")
    const step = desk.cell + desk.gap

    assert.equal(card.width, 3 * desk.cell + 2 * desk.gap)
    assert.equal(card.height, 2 * desk.cell + desk.gap)
    assert.equal(icon.left, desk.pad + 3 * step)
    assert.equal(icon.top, desk.pad)

    // A full slot spans every column, so it starts a row below the card.
    assert.equal(full.left, desk.pad)
    assert.equal(full.top, desk.pad + 2 * step)
    assert.equal(full.width, 9 * desk.cell + 8 * desk.gap)
    assert.equal(full.height, 4 * desk.cell + 3 * desk.gap)
  })

  test("in the hand a card spans the whole row", () => {
    const hand = GRIDS.hand
    const [card] = slotGeometry([{id: "a", size: "card"}], 375, "hand")
    const columns = Math.floor((375 - 2 * hand.pad + hand.gap) / (hand.cell + hand.gap))

    assert.equal(card.left, hand.pad)
    assert.equal(card.width, columns * hand.cell + (columns - 1) * hand.gap)
  })

  test("a canvas narrower than one cell still lays out one column", () => {
    const geometry = slotGeometry(
      [
        {id: "a", size: "card"},
        {id: "b", size: "icon"}
      ],
      10,
      "desk"
    )

    assert.equal(geometry[0].width, desk.cell)
    assert.equal(geometry[1].left, desk.pad)
    assert.equal(geometry[1].top, desk.pad + 2 * (desk.cell + desk.gap))
  })
})

describe("the stylesheet", () => {
  test("places each slot's elements by data-canvas-place, inside the canvas", () => {
    const css = stylesheet("canvas", [{id: "notes", left: 24, top: 24, width: 88, height: 88}])
    assert.equal(
      css,
      '#canvas [data-canvas-place="slot:notes"]{left:24px;top:24px;width:88px;height:88px}'
    )
  })

  test("a scope or an id outside its grammar writes no rule", () => {
    const place = {left: 0, top: 0, width: 1, height: 1}
    assert.equal(stylesheet("canvas", [{id: '"]{}*{display:none', ...place}]), "")
    assert.equal(stylesheet("a b", [{id: "ok", ...place}]), "")
    assert.equal(stylesheet(undefined, [{id: "ok", ...place}]), "")
  })
})
