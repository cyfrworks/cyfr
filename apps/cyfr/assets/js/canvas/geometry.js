// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The canvas's pure layout: the posture a viewport reports, and where each
// slot of an arrangement sits. Nothing here reads or writes the DOM, so
// Node tests it as it is.

// A viewport narrower than this is held in the hand.
export const HAND_BELOW_PX = 768

export const POSTURES = Object.freeze(["hand", "desk"])

export const SIZES = Object.freeze(["icon", "card", "full"])

// Each posture's grid: the cell side, the gap between cells and the
// padding around the grid, in CSS pixels, and each size's span in columns
// and rows. A column span of null is every column.
export const GRIDS = Object.freeze({
  desk: Object.freeze({
    cell: 88,
    gap: 16,
    pad: 24,
    spans: Object.freeze({icon: [1, 1], card: [3, 2], full: [null, 4]})
  }),
  hand: Object.freeze({
    cell: 72,
    gap: 12,
    pad: 12,
    spans: Object.freeze({icon: [1, 1], card: [null, 2], full: [null, 5]})
  })
})

const SLOT_ID = /^[a-z0-9][a-z0-9_-]{0,63}$/
const SCOPE = /^[A-Za-z][A-Za-z0-9_-]*$/

export function isPosture(value) {
  return POSTURES.includes(value)
}

// `hand` under HAND_BELOW_PX CSS pixels wide, `desk` otherwise, and for a
// width that is not a number.
export function postureFor(width) {
  return typeof width === "number" && Number.isFinite(width) && width < HAND_BELOW_PX
    ? "hand"
    : "desk"
}

// The slots the server rendered as JSON (`data-slots`), each `{id, size,
// order}`, in `{order, id}` order; an entry that is not a slot is left
// out. `null` for text that is not a JSON list, so a caller keeps the last
// arrangement it read.
export function parseSlots(text) {
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch (_error) {
    return null
  }
  if (!Array.isArray(parsed)) return null

  return parsed
    .filter(
      (slot) =>
        slot !== null &&
        typeof slot === "object" &&
        typeof slot.id === "string" &&
        SLOT_ID.test(slot.id) &&
        SIZES.includes(slot.size) &&
        Number.isInteger(slot.order) &&
        slot.order >= 0
    )
    .map(({id, size, order}) => ({id, size, order}))
    .sort((a, b) => a.order - b.order || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
}

// Where each slot sits in a canvas `width` pixels wide under `posture`:
// `{id, left, top, width, height}` in pixels. Slots fill the grid's rows
// in order, a slot too wide for what is left of a row starting the next
// one below the row's tallest slot.
export function slotGeometry(slots, width, posture) {
  const grid = GRIDS[posture] || GRIDS.desk
  const step = grid.cell + grid.gap
  const inner = Math.max(0, (Number.isFinite(width) ? width : 0) - 2 * grid.pad)
  const columns = Math.max(1, Math.floor((inner + grid.gap) / step))

  let column = 0
  let row = 0
  let shelf = 0

  return slots.map(({id, size}) => {
    const [spanColumns, spanRows] = grid.spans[size] || grid.spans.icon
    const across = spanColumns === null ? columns : Math.min(spanColumns, columns)

    if (column + across > columns) {
      row += shelf
      column = 0
      shelf = 0
    }

    const placed = {
      id,
      left: grid.pad + column * step,
      top: grid.pad + row * step,
      width: across * grid.cell + (across - 1) * grid.gap,
      height: spanRows * grid.cell + (spanRows - 1) * grid.gap
    }

    column += across
    shelf = Math.max(shelf, spanRows)
    return placed
  })
}

// The rules that put each slot's elements — its tile, or its frame — where
// `slotGeometry` placed it, scoped to the canvas element `scope` names.
// A scope or slot id outside its grammar writes no rule.
export function stylesheet(scope, geometry) {
  if (typeof scope !== "string" || !SCOPE.test(scope)) return ""

  return geometry
    .filter(({id}) => SLOT_ID.test(id))
    .map(
      ({id, left, top, width, height}) =>
        `#${scope} [data-canvas-place="slot:${id}"]` +
        `{left:${left}px;top:${top}px;width:${width}px;height:${height}px}`
    )
    .join("\n")
}
