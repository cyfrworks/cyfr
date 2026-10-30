// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The AQUA panel's pure placement: where it opens, how a drag moves it and
// a resize sizes it inside the area it may cover, where it sits docked to
// the right edge, and how high it stands as a sheet in the hand. Every
// rectangle is `{x, y, w, h}` in CSS pixels of the viewport. Nothing here
// reads or writes the DOM, so Node tests it as it is.

import {HAND_BELOW_PX, postureFor} from "../canvas/geometry.js"

export {HAND_BELOW_PX, postureFor}

// The panel's size when it opens with nothing kept, and the smallest a
// resize leaves it. An area smaller than the minimum gives the panel the
// whole area instead.
export const SIZE = Object.freeze({w: 380, h: 520})
export const MIN = Object.freeze({w: 300, h: 360})

// The largest a side grows, however large the screen: the server refuses a
// placement with a longer one (PrismWeb.AquaPanelLive).
export const MAX = Object.freeze({w: 4000, h: 4000})

// How far the panel opens above its button.
export const GAP = 8

// The sheet's heights in the hand, as shares of the area: where it rests
// when it opens and where a pull up takes it.
export const SHEET = Object.freeze({rest: 0.75, full: 1})

// What the panel may cover: the viewport `width` by `height` below `top`,
// the bottom of the top bar, so the bar stays reachable.
export function area(width, height, top = 0) {
  const across = finite(width)
  const down = finite(height)
  const below = Math.min(down, finite(top))
  return {x: 0, y: below, w: across, h: down - below}
}

// A placement as the server keeps it (`data-x`, `data-y`, `data-w`,
// `data-h`, decimal text), or null when any side is missing, not a whole
// number, or smaller than the minimum, so the panel opens where it would
// with nothing kept.
export function parseKept({x, y, w, h} = {}) {
  const rect = {x: whole(x), y: whole(y), w: whole(w), h: whole(h)}
  if (Object.values(rect).some((side) => side === null)) return null
  if (rect.w < MIN.w || rect.h < MIN.h || rect.w > MAX.w || rect.h > MAX.h) return null
  return rect
}

// `rect` moved and sized to lie inside `space`: no smaller than the
// minimum (or the whole space, when that is smaller), no larger than the
// space or the maximum.
export function clamp(rect, space) {
  const w = bound(rect.w, Math.min(MIN.w, space.w), Math.min(MAX.w, space.w))
  const h = bound(rect.h, Math.min(MIN.h, space.h), Math.min(MAX.h, space.h))
  return {
    x: bound(rect.x, space.x, space.x + space.w - w),
    y: bound(rect.y, space.y, space.y + space.h - h),
    w,
    h
  }
}

// Where the panel opens with nothing kept: its default size, its right
// edge on the button's and its bottom GAP above the button's top. With no
// button, the area's bottom right corner.
export function initial(button, space) {
  const right = button ? button.right : space.x + space.w - GAP
  const bottom = button ? button.top - GAP : space.y + space.h - GAP
  return clamp({x: right - SIZE.w, y: bottom - SIZE.h, w: SIZE.w, h: SIZE.h}, space)
}

// Where the panel opens: the kept placement brought inside the area, or
// the initial one.
export function opened(kept, button, space) {
  return kept ? clamp(kept, space) : initial(button, space)
}

// `rect` dragged by `dx`, `dy`, kept inside the area.
export function moved(rect, dx, dy, space) {
  return clamp({...rect, x: rect.x + dx, y: rect.y + dy}, space)
}

// `rect` resized from `edge` (n, s, e, w, ne, nw, se or sw) by `dx`, `dy`.
// The opposite edges stay where they are; a side stops at the minimum, at
// the maximum and at the area's edge, so a resize below the minimum is
// refused.
export function resized(rect, edge, dx, dy, space) {
  const start = clamp(rect, space)
  const minW = Math.min(MIN.w, space.w)
  const minH = Math.min(MIN.h, space.h)
  let {x, y, w, h} = start
  const right = x + w
  const bottom = y + h

  if (edge.includes("e")) w = bound(w + dx, minW, Math.min(MAX.w, space.x + space.w - x))
  if (edge.includes("w")) {
    x = bound(x + dx, Math.max(space.x, right - MAX.w), right - minW)
    w = right - x
  }
  if (edge.includes("s")) h = bound(h + dy, minH, Math.min(MAX.h, space.y + space.h - y))
  if (edge.includes("n")) {
    y = bound(y + dy, Math.max(space.y, bottom - MAX.h), bottom - minH)
    h = bottom - y
  }
  return {x, y, w, h}
}

// The panel docked: against the area's right edge, its whole height, as
// wide as `rect` (within the minimum, the maximum and the area).
export function docked(rect, space) {
  const w = bound(rect.w, Math.min(MIN.w, space.w), Math.min(MAX.w, space.w))
  return {x: space.x + space.w - w, y: space.y, w, h: space.h}
}

// A docked panel resized from its left edge by `dx`: `rect` with only its
// width changed, which is the width it keeps for when it floats again.
export function dockResized(rect, dx, space) {
  const shown = docked(rect, space)
  const w = bound(shown.w - dx, Math.min(MIN.w, space.w), Math.min(MAX.w, space.w))
  return {...rect, w}
}

// The sheet in the hand at `level` (rest or full): the area's width, from
// the bottom up.
export function sheet(level, space) {
  return sheetOf(Math.round(space.h * (SHEET[level] ?? SHEET.rest)), space)
}

// The sheet at `level` while its handle is pulled down by `dy` (up when
// negative), between nothing and the area's height.
export function pulled(level, dy, space) {
  return sheetOf(bound(sheet(level, space).h - dy, 0, space.h), space)
}

// Where a pull of `dy` from `level` settles: `full` past halfway between
// rest and full, `closed` under half the area's height, `rest` between.
export function settled(level, dy, space) {
  const h = pulled(level, dy, space).h
  if (h >= space.h * ((SHEET.rest + SHEET.full) / 2)) return "full"
  if (h < space.h / 2) return "closed"
  return "rest"
}

// The rectangle the panel is drawn in: a sheet in the hand, docked or
// floating on the desk.
export function shown({rect, docked: isDocked, level}, posture, space) {
  if (posture === "hand") return sheet(level, space)
  return isDocked ? docked(rect, space) : clamp(rect, space)
}

function sheetOf(h, space) {
  return {x: space.x, y: space.y + space.h - h, w: space.w, h}
}

function bound(value, low, high) {
  return Math.round(Math.max(low, Math.min(high, value)))
}

function finite(value) {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0
}

function whole(text) {
  if (typeof text !== "string" || !/^-?[0-9]{1,6}$/.test(text)) return null
  return Number.parseInt(text, 10)
}
