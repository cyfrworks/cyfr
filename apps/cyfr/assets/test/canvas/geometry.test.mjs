// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {
  COLUMNS,
  EDGE_STRIP_PX,
  HAND_BELOW_PX,
  MAX_COVERED,
  MODES,
  SWIPE_MIN_PX,
  columnGeometry,
  coveredRects,
  isPosture,
  parseColumns,
  postureFor,
  stylesheet,
  swipeDirection
} from "../../js/canvas/geometry.js"

const A = "frm_aaaaaaaaaa"
const B = "frm_bbbbbbbbbb"
const C = "frm_cccccccccc"

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

  test("only hand and desk are postures, and an app is full or a column", () => {
    assert.ok(isPosture("hand") && isPosture("desk"))
    for (const value of ["tablet", "", null, undefined, 1]) assert.equal(isPosture(value), false)
    assert.deepEqual(MODES, ["full", "column"])
  })
})

describe("the column list the server rendered", () => {
  test("is read in order, the frame id breaking a tie, and anything that is not a column is left out", () => {
    const columns = parseColumns(
      JSON.stringify([
        {frame: B, order: 1},
        {frame: A, order: 1},
        {frame: C, order: 0},
        {frame: "bad id", order: 2},
        {frame: "short", order: 2},
        {frame: A, order: -1},
        {frame: C, order: 2.5},
        {frame: B, order: 3, size: "dropped"},
        {id: "slot", size: "icon", order: 0},
        null
      ])
    )

    assert.deepEqual(columns, [
      {frame: C, order: 0},
      {frame: A, order: 1},
      {frame: B, order: 1},
      {frame: B, order: 3}
    ])
  })

  test("text that is not a JSON list reads as nothing, so the last list stays", () => {
    for (const text of [undefined, "", "{", "{}", "null", "3"]) assert.equal(parseColumns(text), null)
    assert.deepEqual(parseColumns("[]"), [])
  })
})

describe("column geometry", () => {
  test("on the desk the columns stand side by side against the right edge, in order", () => {
    const [first, second] = columnGeometry(
      [
        {frame: A, order: 0},
        {frame: B, order: 1}
      ],
      1600,
      900,
      "desk"
    )

    assert.equal(first.width, COLUMNS.width)
    assert.equal(second.width, COLUMNS.width)
    assert.equal(second.left + second.width, 1600 - COLUMNS.pad)
    assert.equal(first.left + first.width + COLUMNS.gap, second.left)
    assert.equal(first.top, COLUMNS.pad)
    assert.equal(first.height, 900 - 2 * COLUMNS.pad)
  })

  test("a canvas with no room narrows its columns, never below the least width", () => {
    const columns = [A, B, C].map((frame, order) => ({frame, order}))
    const narrow = columnGeometry(columns, 1000, 800, "desk")
    const room = Math.floor((1000 - 2 * COLUMNS.pad - 2 * COLUMNS.gap) / 3)

    assert.ok(room < COLUMNS.width)
    assert.ok(narrow.every((column) => column.width === room))

    const tiny = columnGeometry(columns, 300, 800, "desk")
    assert.ok(tiny.every((column) => column.width === COLUMNS.min))
  })

  test("in the hand each column spans the width and they share the height, top to bottom", () => {
    const [top, bottom] = columnGeometry(
      [
        {frame: A, order: 0},
        {frame: B, order: 1}
      ],
      400,
      800,
      "hand"
    )

    assert.equal(top.left, COLUMNS.pad)
    assert.equal(top.width, 400 - 2 * COLUMNS.pad)
    assert.equal(top.top, COLUMNS.pad)
    assert.equal(bottom.top, top.top + top.height + COLUMNS.gap)
    assert.ok(bottom.top + bottom.height <= 800 - COLUMNS.pad)
  })

  test("no columns lay out nothing", () => {
    assert.deepEqual(columnGeometry([], 1600, 900, "desk"), [])
  })
})

describe("the stylesheet", () => {
  test("places each column's frame by data-canvas-column, inside the canvas", () => {
    const css = stylesheet("canvas", [{frame: A, left: 24, top: 12, width: 420, height: 876}])
    assert.equal(
      css,
      `#canvas [data-canvas-column="${A}"]{left:24px;top:12px;width:420px;height:876px}`
    )
  })

  test("a scope or a frame id outside its grammar writes no rule", () => {
    const place = {left: 0, top: 0, width: 1, height: 1}
    assert.equal(stylesheet("canvas", [{frame: '"]{}*{display:none', ...place}]), "")
    assert.equal(stylesheet("a b", [{frame: A, ...place}]), "")
    assert.equal(stylesheet(undefined, [{frame: A, ...place}]), "")
  })
})

describe("what covers a canvas", () => {
  test("is each shown box clipped to the canvas, in the canvas frame's own pixels", () => {
    const canvas = {x: 0, y: 40, width: 1000, height: 600}
    const rects = coveredRects(canvas, [
      {x: 700, y: 52, width: 288, height: 576},
      {x: 900, y: 600, width: 300, height: 200},
      {x: 2000, y: 0, width: 10, height: 10}
    ])

    assert.deepEqual(rects, [
      {x: 700, y: 12, width: 288, height: 576},
      {x: 900, y: 560, width: 100, height: 40}
    ])
  })

  test("is at most 64 rects, and a box that is not one covers nothing", () => {
    const canvas = {x: 0, y: 0, width: 100, height: 100}
    const many = Array.from({length: 70}, () => ({x: 0, y: 0, width: 1, height: 1}))
    assert.equal(coveredRects(canvas, many).length, MAX_COVERED)
    assert.deepEqual(coveredRects(canvas, [null, {x: "0", y: 0, width: 1, height: 1}]), [])
    assert.deepEqual(coveredRects(null, many), [])
  })
})

describe("a swipe on the edge strip", () => {
  test("leftward is next and rightward previous, from 48 pixels across and more across than down", () => {
    assert.equal(EDGE_STRIP_PX, 16)
    assert.equal(SWIPE_MIN_PX, 48)
    assert.equal(swipeDirection({x: 300, y: 5}, {x: 252, y: 10}), "next")
    assert.equal(swipeDirection({x: 300, y: 5}, {x: 348, y: 0}), "previous")
  })

  test("a short, a steep or an unreadable travel switches nothing", () => {
    assert.equal(swipeDirection({x: 300, y: 5}, {x: 253, y: 5}), null)
    assert.equal(swipeDirection({x: 300, y: 0}, {x: 240, y: 70}), null)
    assert.equal(swipeDirection({x: 300, y: 0}, {x: 240, y: 60}), null)
    assert.equal(swipeDirection(null, {x: 0, y: 0}), null)
    assert.equal(swipeDirection({x: NaN, y: 0}, {x: 0, y: 0}), null)
  })
})
