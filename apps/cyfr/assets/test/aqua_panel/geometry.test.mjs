// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {HAND_BELOW_PX as CANVAS_HAND} from "../../js/canvas/geometry.js"
import {
  GAP,
  HAND_BELOW_PX,
  MIN,
  SIZE,
  area,
  clamp,
  dockResized,
  docked,
  initial,
  moved,
  opened,
  parseKept,
  postureFor,
  pulled,
  resized,
  settled,
  sheet,
  shown
} from "../../js/aqua_panel/geometry.js"

// A 1280 by 800 desk under a 48 pixel top bar.
const DESK = area(1280, 800, 48)
// The button's box as the layout places it: 16 from the right, 80 up.
const BUTTON = {left: 1190, top: 684, right: 1264, bottom: 720}

describe("the area", () => {
  test("is the viewport under the top bar", () => {
    assert.deepEqual(DESK, {x: 0, y: 48, w: 1280, h: 752})
  })

  test("a size or top that is not a number counts as nothing", () => {
    assert.deepEqual(area(undefined, NaN, "48"), {x: 0, y: 0, w: 0, h: 0})
    assert.deepEqual(area(1280, 800), {x: 0, y: 0, w: 1280, h: 800})
  })
})

describe("the posture", () => {
  test("is the canvas's: hand under 768 CSS pixels", () => {
    assert.equal(HAND_BELOW_PX, CANVAS_HAND)
    assert.equal(postureFor(767), "hand")
    assert.equal(postureFor(768), "desk")
  })
})

describe("where the panel opens", () => {
  test("with nothing kept: 380 by 520, its right edge on the button's, GAP above it", () => {
    assert.deepEqual(SIZE, {w: 380, h: 520})
    assert.deepEqual(initial(BUTTON, DESK), {x: 1264 - 380, y: 684 - GAP - 520, w: 380, h: 520})
    assert.deepEqual(opened(null, BUTTON, DESK), initial(BUTTON, DESK))
  })

  test("with no button, in the area's bottom right corner", () => {
    assert.deepEqual(initial(null, DESK), {x: 1280 - GAP - 380, y: 800 - GAP - 520, w: 380, h: 520})
  })

  test("a short screen keeps the default inside the area, under the top bar", () => {
    const short = area(1024, 600, 48)
    const rect = initial({left: 940, top: 484, right: 1008, bottom: 520}, short)
    assert.equal(rect.y, 48)
    assert.equal(rect.h, 520)
  })

  test("a kept placement inside the viewport opens where it was", () => {
    const kept = {x: 100, y: 120, w: 420, h: 480}
    assert.deepEqual(opened(kept, BUTTON, DESK), kept)
  })

  test("a kept placement outside the current viewport is brought inside it", () => {
    // Kept on a wider, taller screen.
    assert.deepEqual(opened({x: 2400, y: 1300, w: 500, h: 600}, BUTTON, DESK), {
      x: 1280 - 500,
      y: 800 - 600,
      w: 500,
      h: 600
    })
    // Larger than the whole area: it takes the area.
    assert.deepEqual(opened({x: 0, y: 0, w: 3000, h: 3000}, BUTTON, DESK), DESK)
    // Above the top bar: brought down under it.
    assert.equal(opened({x: 10, y: 0, w: 400, h: 400}, BUTTON, DESK).y, 48)
  })
})

describe("the kept placement the server renders", () => {
  test("reads four whole numbers", () => {
    assert.deepEqual(parseKept({x: "10", y: "60", w: "400", h: "500"}), {x: 10, y: 60, w: 400, h: 500})
  })

  test("is nothing when a side is missing, not whole, or under the minimum", () => {
    for (const kept of [
      {},
      {x: "10", y: "60", w: "400"},
      {x: "10", y: "60", w: "400.5", h: "500"},
      {x: "10", y: "60", w: "4e2", h: "500"},
      {x: "10", y: "60", w: "299", h: "500"},
      {x: "10", y: "60", w: "400", h: "359"},
      {x: "", y: "60", w: "400", h: "500"}
    ]) {
      assert.equal(parseKept(kept), null, JSON.stringify(kept))
    }
    assert.equal(parseKept(), null)
  })
})

describe("a drag", () => {
  const rect = {x: 400, y: 200, w: 380, h: 520}

  test("moves the panel by the pointer's travel", () => {
    assert.deepEqual(moved(rect, -50, 30, DESK), {x: 350, y: 230, w: 380, h: 520})
  })

  test("stops at the viewport's edges and under the top bar", () => {
    assert.deepEqual(moved(rect, -1000, -1000, DESK), {x: 0, y: 48, w: 380, h: 520})
    assert.deepEqual(moved(rect, 5000, 5000, DESK), {x: 1280 - 380, y: 800 - 520, w: 380, h: 520})
  })
})

describe("a resize", () => {
  const rect = {x: 400, y: 200, w: 380, h: 520}

  test("from a corner moves that corner and leaves the opposite one", () => {
    assert.deepEqual(resized(rect, "se", 40, 20, DESK), {x: 400, y: 200, w: 420, h: 540})
    assert.deepEqual(resized(rect, "nw", -40, -20, DESK), {x: 360, y: 180, w: 420, h: 540})
    assert.deepEqual(resized(rect, "ne", 10, -10, DESK), {x: 400, y: 190, w: 390, h: 530})
    assert.deepEqual(resized(rect, "sw", -10, 10, DESK), {x: 390, y: 200, w: 390, h: 530})
  })

  test("from an edge changes that side alone", () => {
    assert.deepEqual(resized(rect, "e", 30, 99, DESK), {x: 400, y: 200, w: 410, h: 520})
    assert.deepEqual(resized(rect, "n", 99, -30, DESK), {x: 400, y: 170, w: 380, h: 550})
  })

  test("below 300 by 360 is refused: the side stops at the minimum", () => {
    assert.deepEqual(MIN, {w: 300, h: 360})
    assert.deepEqual(resized(rect, "se", -500, -500, DESK), {x: 400, y: 200, w: 300, h: 360})
    // From the left and top, the right and bottom edges stay put.
    assert.deepEqual(resized(rect, "nw", 500, 500, DESK), {x: 480, y: 360, w: 300, h: 360})
  })

  test("stops at the viewport's edges", () => {
    assert.deepEqual(resized(rect, "se", 5000, 5000, DESK), {x: 400, y: 200, w: 880, h: 600})
    assert.deepEqual(resized(rect, "nw", -5000, -5000, DESK), {x: 0, y: 48, w: 780, h: 672})
  })
})

describe("docked", () => {
  test("against the right edge, under the top bar, the area's whole height, as wide as the panel", () => {
    assert.deepEqual(docked({x: 100, y: 120, w: 420, h: 480}, DESK), {x: 860, y: 48, w: 420, h: 752})
  })

  test("sized from its left edge, keeping the floating placement, within the minimum", () => {
    const rect = {x: 100, y: 120, w: 420, h: 480}
    assert.deepEqual(dockResized(rect, -80, DESK), {x: 100, y: 120, w: 500, h: 480})
    assert.deepEqual(dockResized(rect, 400, DESK), {x: 100, y: 120, w: 300, h: 480})
    assert.deepEqual(dockResized(rect, -5000, DESK), {x: 100, y: 120, w: 1280, h: 480})
  })
})

describe("the sheet in the hand", () => {
  const HAND = area(390, 844, 48)

  test("rests at three-quarters of the area from the bottom, and full is the whole area", () => {
    assert.deepEqual(sheet("rest", HAND), {x: 0, y: 844 - 597, w: 390, h: 597})
    assert.deepEqual(sheet("full", HAND), HAND)
  })

  test("follows its handle, between nothing and the area", () => {
    assert.equal(pulled("rest", 100, HAND).h, 497)
    assert.equal(pulled("rest", -5000, HAND).h, 796)
    assert.equal(pulled("full", 5000, HAND).h, 0)
  })

  test("settles full past halfway up, closed under half the area, at rest between", () => {
    assert.equal(settled("rest", -120, HAND), "full")
    assert.equal(settled("rest", -50, HAND), "rest")
    assert.equal(settled("rest", 150, HAND), "rest")
    assert.equal(settled("rest", 220, HAND), "closed")
    assert.equal(settled("full", 120, HAND), "rest")
    assert.equal(settled("full", 500, HAND), "closed")
  })

  test("is what the hand shows, docked or not", () => {
    const state = {rect: {x: 10, y: 60, w: 400, h: 500}, docked: true, level: "rest"}
    assert.deepEqual(shown(state, "hand", HAND), sheet("rest", HAND))
  })
})

describe("what the desk shows", () => {
  const rect = {x: 2000, y: 60, w: 400, h: 500}

  test("floating: the placement inside the area", () => {
    assert.deepEqual(shown({rect, docked: false, level: "rest"}, "desk", DESK), clamp(rect, DESK))
  })

  test("docked: the docked rectangle", () => {
    assert.deepEqual(shown({rect, docked: true, level: "rest"}, "desk", DESK), docked(rect, DESK))
  })
})
