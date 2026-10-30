// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The canvas's pure layout: the posture a viewport reports, where a
// window lands when it is dragged, resized or dropped on a screen edge,
// where a tile's divider leaves it, what the shown windows cover of a
// canvas's frame, and which way a swipe on the shelf switches. Every box
// is `{x, y, width, height}` in CSS pixels of the apps' area (the layer
// above the shelf), from its top left corner; every geometry the shell is
// sent is `{x, y, w, h}` in hundredths of a percent of that area, as the
// layout keeps it (`Prima.Layout`). Nothing here reads or writes the DOM,
// so Node tests it as it is.

import {MAX_RECTS} from "../sdk/wire.js"

// A viewport narrower than this is held in the hand.
export const HAND_BELOW_PX = 768

export const POSTURES = Object.freeze(["hand", "desk"])

// How far a pointer travels along the shelf, more across than down, to
// switch canvases.
export const SWIPE_MIN_PX = 48

// The most rectangles a canvas is told it is covered by: the wire's limit.
export const MAX_COVERED = MAX_RECTS

// A window's title bar, which a window keeps on screen: its height, and
// how much of its width stays inside the area however far it is dragged.
export const TITLE_PX = 34
export const KEEP_PX = 96

// The smallest a window is resized to (or the whole area, when that is
// smaller), and the narrowest a tile's divider leaves the tile or the
// canvas beside it.
export const MIN_WINDOW = Object.freeze({width: 240, height: 160})

// A window dropped with the pointer this close to the area's left or right
// edge becomes a tile there, and to its top edge becomes full.
export const SNAP_PX = 16

// How far a press on a title bar travels before it is a drag, not a click.
export const DRAG_MIN_PX = 3

// The layout's whole: geometry and shares are hundredths of a percent.
export const WHOLE = 10000

const FRAME_ID = /^[A-Za-z0-9_-]{8,64}$/
const ELEMENT_ID = /^[A-Za-z][A-Za-z0-9_-]*$/

// `hand` under HAND_BELOW_PX CSS pixels wide, `desk` otherwise, and for a
// width that is not a number.
export function postureFor(width) {
  return typeof width === "number" && Number.isFinite(width) && width < HAND_BELOW_PX
    ? "hand"
    : "desk"
}

// A geometry the server rendered (`data-canvas-geometry`, `x y w h` in
// hundredths), or null for anything that is not four whole numbers.
export function parseGeometry(text) {
  if (typeof text !== "string" || !/^\d{1,5} \d{1,5} \d{1,5} \d{1,5}$/.test(text)) return null
  const [x, y, w, h] = text.split(" ").map((n) => Number.parseInt(n, 10))
  return {x, y, w, h}
}

// The box a geometry stands at in `area` (`{width, height}`).
export function boxOf(geometry, area) {
  return {
    x: (geometry.x * area.width) / WHOLE,
    y: (geometry.y * area.height) / WHOLE,
    width: (geometry.w * area.width) / WHOLE,
    height: (geometry.h * area.height) / WHOLE
  }
}

// The geometry a box stands at in `area`, as the layout bounds it: `x` and
// `y` from 0, `w` and `h` from 1, each to WHOLE.
export function geometryOf(box, area) {
  const part = (px, of, low) => bound(Math.round((px * WHOLE) / Math.max(1, of)), low, WHOLE)
  return {
    x: part(box.x, area.width, 0),
    y: part(box.y, area.height, 0),
    w: part(box.width, area.width, 1),
    h: part(box.height, area.height, 1)
  }
}

// A share of the area's width in pixels, as the layout bounds it.
export function shareOf(width, area) {
  return bound(Math.round((width * WHOLE) / Math.max(1, area.width)), 1, WHOLE)
}

// `start` dragged by `dx`, `dy`: it keeps its size, and its title bar stays
// in the area: its left edge from 0 (the layout keeps no window left of
// the area) to where KEEP_PX of it is still inside, its top from 0 to
// where the title bar still is.
export function moved(start, dx, dy, area) {
  const keep = Math.min(start.width, KEEP_PX)
  return {
    ...start,
    x: bound(start.x + dx, 0, Math.max(0, area.width - keep)),
    y: bound(start.y + dy, 0, Math.max(0, area.height - TITLE_PX))
  }
}

// `start` resized from `edge` (n, s, e, w, ne, nw, se or sw) by `dx`, `dy`:
// the opposite edges stay where they are, and a side stops at the minimum
// and at the area's edge.
export function resized(start, edge, dx, dy, area) {
  const minW = Math.min(MIN_WINDOW.width, area.width)
  const minH = Math.min(MIN_WINDOW.height, area.height)
  let {x, y, width, height} = start
  const right = x + width
  const bottom = y + height

  if (edge.includes("e")) width = bound(width + dx, minW, Math.max(minW, area.width - x))
  if (edge.includes("w")) {
    x = bound(x + dx, 0, right - minW)
    width = right - x
  }
  if (edge.includes("s")) height = bound(height + dy, minH, Math.max(minH, area.height - y))
  if (edge.includes("n")) {
    y = bound(y + dy, 0, bottom - minH)
    height = bottom - y
  }
  return {x, y, width, height}
}

// Where a window dropped with the pointer at `point` (in the area's
// pixels) goes: `left` or `right`, a tile at that edge, within SNAP_PX of
// it; `full`, within SNAP_PX of the top edge; null anywhere else.
export function snapAt(point, area) {
  if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return null
  if (point.x <= SNAP_PX) return "left"
  if (point.x >= area.width - SNAP_PX) return "right"
  if (point.y <= SNAP_PX) return "full"
  return null
}

// The box a snap shows as it is offered: a tile of `share` at its edge,
// or the whole area.
export function snapBox(snap, share, area) {
  const width = (bound(share, 1, WHOLE) * area.width) / WHOLE
  if (snap === "left") return {x: 0, y: 0, width, height: area.height}
  if (snap === "right") return {x: area.width - width, y: 0, width, height: area.height}
  if (snap === "full") return {x: 0, y: 0, width: area.width, height: area.height}
  return null
}

// A tile `width` pixels wide at `side`, its inner divider dragged by `dx`:
// its new width, leaving MIN_WINDOW.width of the tile and of the area.
export function dividerWidth(width, side, dx, area) {
  const low = Math.min(MIN_WINDOW.width, area.width)
  const high = Math.max(low, area.width - MIN_WINDOW.width)
  return bound(side === "left" ? width + dx : width - dx, low, high)
}

// The rules that hold elements where a gesture under way has put them,
// above the style the server rendered: one per `{id, box}` (an element id
// and the CSS pixel properties to set). An id outside its grammar, or a
// property that is not a finite number, writes nothing.
export function overrides(entries) {
  return entries
    .filter(({id}) => typeof id === "string" && ELEMENT_ID.test(id))
    .map(({id, box}) => {
      const props = Object.entries(box)
        .filter(([name, value]) => /^(left|right|top|bottom|width|height)$/.test(name) && Number.isFinite(value))
        .map(([name, value]) => `${name}:${Math.round(value)}px!important`)
      return props.length > 0 ? `#${id}{${props.join(";")}}` : ""
    })
    .filter((rule) => rule !== "")
    .join("\n")
}

// Whether `id` is a frame id this canvas draws.
export function frameId(id) {
  return typeof id === "string" && FRAME_ID.test(id)
}

function bound(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// What `boxes` (the shown windows' boxes, `{x, y, width, height}` in the
// page's pixels) cover of the canvas frame whose box is `canvas`, in the
// canvas frame's own pixels: each box clipped to the canvas, an empty
// overlap left out, at most MAX_COVERED of them.
export function coveredRects(canvas, boxes) {
  if (!isBox(canvas)) return []
  const rects = []

  for (const box of boxes) {
    if (!isBox(box)) continue
    const left = Math.max(canvas.x, box.x)
    const top = Math.max(canvas.y, box.y)
    const right = Math.min(canvas.x + canvas.width, box.x + box.width)
    const bottom = Math.min(canvas.y + canvas.height, box.y + box.height)
    if (right <= left || bottom <= top) continue
    rects.push({x: left - canvas.x, y: top - canvas.y, width: right - left, height: bottom - top})
    if (rects.length === MAX_COVERED) break
  }

  return rects
}

const isBox = (box) =>
  box !== null &&
  typeof box === "object" &&
  ["x", "y", "width", "height"].every((key) => typeof box[key] === "number" && Number.isFinite(box[key])) &&
  box.width >= 0 &&
  box.height >= 0

// The switch a pointer's travel on the shelf asks for: `next` for a
// leftward swipe and `previous` for a rightward one, of at least
// SWIPE_MIN_PX and more across than down; null for anything else.
export function swipeDirection(start, end) {
  if (!isPoint(start) || !isPoint(end)) return null
  const dx = end.x - start.x
  const dy = end.y - start.y
  if (Math.abs(dx) < SWIPE_MIN_PX || Math.abs(dx) <= Math.abs(dy)) return null
  return dx < 0 ? "next" : "previous"
}

const isPoint = (point) =>
  point !== null &&
  typeof point === "object" &&
  Number.isFinite(point.x) &&
  Number.isFinite(point.y)
