// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {
  DRAG_MIN_PX,
  HAND_BELOW_PX,
  KEEP_PX,
  MAX_COVERED,
  MIN_WINDOW,
  POSTURES,
  SNAP_PX,
  SWIPE_MIN_PX,
  TITLE_PX,
  WHOLE,
  boxOf,
  coveredRects,
  dividerWidth,
  frameId,
  geometryOf,
  moved,
  overrides,
  parseGeometry,
  postureFor,
  resized,
  shareOf,
  snapAt,
  snapBox,
  swipeDirection
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
    assert.deepEqual(POSTURES, ["hand", "desk"])
  })
})

// The apps' area: 1600 by 900 above the shelf.
const AREA = {width: 1600, height: 900}

describe("geometry in hundredths", () => {
  test("a rendered geometry is four whole numbers, and anything else is none", () => {
    assert.deepEqual(parseGeometry("2500 5000 3000 4000"), {x: 2500, y: 5000, w: 3000, h: 4000})
    for (const text of [undefined, "", "1 2 3", "1 2 3 4 5", "1.5 2 3 4", "-1 2 3 4", "a b c d", "100000 1 1 1"]) {
      assert.equal(parseGeometry(text), null, String(text))
    }
  })

  test("a geometry's box in the area, and a box's geometry, as the layout bounds it", () => {
    assert.equal(WHOLE, 10000)
    assert.deepEqual(boxOf({x: 2500, y: 5000, w: 3000, h: 4000}, AREA), {x: 400, y: 450, width: 480, height: 360})
    assert.deepEqual(geometryOf({x: 400, y: 450, width: 480, height: 360}, AREA), {x: 2500, y: 5000, w: 3000, h: 4000})
    // x and y from 0, w and h from 1, each to the whole.
    assert.deepEqual(geometryOf({x: -10, y: 5000, width: 0.01, height: 99999}, AREA), {x: 0, y: 10000, w: 1, h: 10000})
  })

  test("a width's share of the area, from 1 to the whole", () => {
    assert.equal(shareOf(400, AREA), 2500)
    assert.equal(shareOf(0, AREA), 1)
    assert.equal(shareOf(5000, AREA), 10000)
  })
})

describe("a dragged window", () => {
  const start = {x: 400, y: 300, width: 480, height: 360}

  test("moves by the pointer's travel", () => {
    assert.deepEqual(moved(start, -100, 50, AREA), {x: 300, y: 350, width: 480, height: 360})
  })

  test("keeps its title bar on screen: no further left or up than the area, its title's KEEP_PX inside on the right, its title bar above the bottom", () => {
    assert.equal(TITLE_PX, 34)
    assert.deepEqual(moved(start, -5000, -5000, AREA), {x: 0, y: 0, width: 480, height: 360})
    assert.deepEqual(moved(start, 5000, 5000, AREA), {x: 1600 - KEEP_PX, y: 900 - TITLE_PX, width: 480, height: 360})
    // A window narrower than KEEP_PX keeps all of its width inside.
    assert.equal(moved({...start, width: 60}, 5000, 0, AREA).x, 1540)
  })
})

describe("a resized window", () => {
  const start = {x: 400, y: 300, width: 480, height: 360}

  test("moves the edge or corner it is resized from, and the opposite ones stay", () => {
    assert.deepEqual(resized(start, "se", 40, 20, AREA), {x: 400, y: 300, width: 520, height: 380})
    assert.deepEqual(resized(start, "nw", -40, -20, AREA), {x: 360, y: 280, width: 520, height: 380})
    assert.deepEqual(resized(start, "e", 30, 99, AREA), {x: 400, y: 300, width: 510, height: 360})
    assert.deepEqual(resized(start, "n", 99, -30, AREA), {x: 400, y: 270, width: 480, height: 390})
  })

  test("stops at the minimum and at the area's edges", () => {
    assert.deepEqual(MIN_WINDOW, {width: 240, height: 160})
    assert.deepEqual(resized(start, "se", -5000, -5000, AREA), {x: 400, y: 300, width: 240, height: 160})
    assert.deepEqual(resized(start, "nw", 5000, 5000, AREA), {x: 640, y: 500, width: 240, height: 160})
    assert.deepEqual(resized(start, "se", 5000, 5000, AREA), {x: 400, y: 300, width: 1200, height: 600})
    assert.deepEqual(resized(start, "nw", -5000, -5000, AREA), {x: 0, y: 0, width: 880, height: 660})
  })
})

describe("a drop on a screen edge", () => {
  test("within 16 pixels of the left or right edge is a tile there, of the top edge full, anywhere else nothing", () => {
    assert.equal(SNAP_PX, 16)
    assert.equal(snapAt({x: 16, y: 400}, AREA), "left")
    assert.equal(snapAt({x: 1584, y: 400}, AREA), "right")
    assert.equal(snapAt({x: 800, y: 16}, AREA), "full")
    assert.equal(snapAt({x: 17, y: 17}, AREA), null)
    assert.equal(snapAt({x: 1583, y: 400}, AREA), null)
    // Past the edge is at the edge.
    assert.equal(snapAt({x: -40, y: 400}, AREA), "left")
    assert.equal(snapAt({x: 800, y: -3}, AREA), "full")
    assert.equal(snapAt(null, AREA), null)
    assert.equal(snapAt({x: NaN, y: 0}, AREA), null)
  })

  test("shows where it would go: a tile of its share at that edge, or the whole area", () => {
    assert.deepEqual(snapBox("left", 2500, AREA), {x: 0, y: 0, width: 400, height: 900})
    assert.deepEqual(snapBox("right", 2500, AREA), {x: 1200, y: 0, width: 400, height: 900})
    assert.deepEqual(snapBox("full", 2500, AREA), {x: 0, y: 0, width: 1600, height: 900})
    assert.equal(snapBox(null, 2500, AREA), null)
  })
})

describe("a tile's divider", () => {
  test("follows the pointer outward or inward, by its side", () => {
    assert.equal(dividerWidth(400, "left", 100, AREA), 500)
    assert.equal(dividerWidth(400, "right", 100, AREA), 300)
    assert.equal(dividerWidth(400, "right", -100, AREA), 500)
  })

  test("leaves at least 240 pixels to the tile and to the area beside it", () => {
    assert.equal(dividerWidth(400, "left", -5000, AREA), 240)
    assert.equal(dividerWidth(400, "left", 5000, AREA), 1360)
  })
})

describe("the held style", () => {
  test("is one rule per element over the server's style, in whole pixels", () => {
    assert.equal(
      overrides([{id: "canvas-frame-frm_aaaaaaaaaa", box: {left: 10.4, top: 20, width: 300, height: 200}}]),
      "#canvas-frame-frm_aaaaaaaaaa{left:10px!important;top:20px!important;width:300px!important;height:200px!important}"
    )
  })

  test("an id outside its grammar, a property not a length's, or a value not a number writes nothing", () => {
    assert.equal(overrides([{id: '"]{}*{display:none', box: {left: 1}}]), "")
    assert.equal(overrides([{id: "ok-id", box: {color: 1, left: NaN}}]), "")
    assert.equal(overrides([]), "")
  })

  test("a frame id is the shell's grammar", () => {
    assert.equal(frameId("frm_aaaaaaaaaa"), true)
    assert.equal(frameId("x"), false)
    assert.equal(frameId(undefined), false)
  })
})

describe("a press on a title bar", () => {
  test("becomes a drag past a few pixels", () => {
    assert.equal(DRAG_MIN_PX, 3)
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

describe("a swipe on the shelf", () => {
  test("leftward is next and rightward previous, from 48 pixels across and more across than down", () => {
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
