// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The canvas's pure layout: the posture a viewport reports, where each
// column app sits beside the canvas, what the shown apps cover of a
// canvas's frame, and which way a swipe on the edge strip switches. Nothing
// here reads or writes the DOM, so Node tests it as it is.

// A viewport narrower than this is held in the hand.
export const HAND_BELOW_PX = 768

export const POSTURES = Object.freeze(["hand", "desk"])

// How an app is shown over its canvas: `full`, the whole screen while it
// is shown (the shell's own class places it), or a `column`, laid out here.
export const MODES = Object.freeze(["full", "column"])

// The columns on the desk: each `width` CSS pixels wide (narrower, down to
// `min`, when the canvas has no room for them all), `gap` apart and `pad`
// in from the canvas's right edge, top and bottom. In the hand a column
// spans the canvas's width, and the columns share its height.
export const COLUMNS = Object.freeze({width: 420, min: 240, gap: 12, pad: 12})

// How far a pointer travels along the bottom edge strip, more across than
// down, to switch canvases.
export const SWIPE_MIN_PX = 48

// The most rectangles a canvas is told it is covered by (`Prima.CanvasWire`).
export const MAX_COVERED = 64

const FRAME_ID = /^[A-Za-z0-9_-]{8,64}$/
const SCOPE = /^[A-Za-z][A-Za-z0-9_-]*$/

// `hand` under HAND_BELOW_PX CSS pixels wide, `desk` otherwise, and for a
// width that is not a number.
export function postureFor(width) {
  return typeof width === "number" && Number.isFinite(width) && width < HAND_BELOW_PX
    ? "hand"
    : "desk"
}

// The shown columns the server rendered as JSON (`data-columns`), each
// `{frame, order}`, in `{order, frame}` order; an entry that is not a
// column is left out. `null` for text that is not a JSON list, so a
// caller keeps the last columns it read.
export function parseColumns(text) {
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch (_error) {
    return null
  }
  if (!Array.isArray(parsed)) return null

  return parsed
    .filter(
      (column) =>
        column !== null &&
        typeof column === "object" &&
        typeof column.frame === "string" &&
        FRAME_ID.test(column.frame) &&
        Number.isInteger(column.order) &&
        column.order >= 0
    )
    .map(({frame, order}) => ({frame, order}))
    .sort((a, b) => a.order - b.order || (a.frame < b.frame ? -1 : a.frame > b.frame ? 1 : 0))
}

// Where each column sits in a canvas `width` by `height` pixels under
// `posture`: `{frame, left, top, width, height}` in pixels. On the desk the
// columns stand side by side against the canvas's right edge, in order
// from left to right; in the hand each spans the width and they share the
// height, in order from top to bottom.
export function columnGeometry(columns, width, height, posture) {
  const across = Math.max(0, Number.isFinite(width) ? width : 0)
  const down = Math.max(0, Number.isFinite(height) ? height : 0)
  const n = columns.length
  if (n === 0) return []
  const {gap, pad} = COLUMNS

  if (posture === "hand") {
    const each = Math.max(0, Math.floor((down - 2 * pad - (n - 1) * gap) / n))
    return columns.map(({frame}, i) => ({
      frame,
      left: pad,
      top: pad + i * (each + gap),
      width: Math.max(0, across - 2 * pad),
      height: each
    }))
  }

  const room = Math.floor((across - 2 * pad - (n - 1) * gap) / n)
  const each = Math.max(COLUMNS.min, Math.min(COLUMNS.width, room))
  const strip = n * each + (n - 1) * gap
  const start = across - pad - strip

  return columns.map(({frame}, i) => ({
    frame,
    left: start + i * (each + gap),
    top: pad,
    width: each,
    height: Math.max(0, down - 2 * pad)
  }))
}

// The rules that put each column's frame where `columnGeometry` placed it,
// scoped to the canvas element `scope` names. A scope or frame id outside
// its grammar writes no rule.
export function stylesheet(scope, geometry) {
  if (typeof scope !== "string" || !SCOPE.test(scope)) return ""

  return geometry
    .filter(({frame}) => typeof frame === "string" && FRAME_ID.test(frame))
    .map(
      ({frame, left, top, width, height}) =>
        `#${scope} [data-canvas-column="${frame}"]` +
        `{left:${left}px;top:${top}px;width:${width}px;height:${height}px}`
    )
    .join("\n")
}

// What `boxes` (the shown apps' and floating frames' boxes, `{x, y,
// width, height}` in the page's pixels) cover of the canvas frame whose box
// is `canvas`, in the canvas frame's own pixels: each box clipped to the
// canvas, an empty overlap left out, at most MAX_COVERED of them.
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

// The switch a pointer's travel on the edge strip asks for: `next` for a
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
