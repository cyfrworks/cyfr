// The desktop's arrangement edits, as pure functions over the layout
// document (`Prima.Layout`'s JSON form). Every edit answers a whole new
// document; the page publishes it through `layout.edit` with the revision
// it read, and nothing here talks to anything.

export const DEFAULT_DESKTOP = "tincture:local.desktop"
export const POSTURES = ["hand", "desk"]
const SLOT_ID = /^[a-z0-9][a-z0-9_-]{0,63}$/

// A versionless tincture reference, spelt as the layout spells it.
export function refOf(publisher, name) {
  return `tincture:${publisher}.${name}`
}

// The installed tinctures of a `component.list` answer, by reference.
export function installedByRef(components) {
  const byRef = new Map()
  for (const row of components || []) {
    if (!row || row.component_type !== "tincture") continue
    if (typeof row.publisher !== "string" || typeof row.name !== "string") continue
    const ref = refOf(row.publisher, row.name)
    if (!byRef.has(ref)) byRef.set(ref, row)
  }
  return byRef
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

// The posture's arrangement: the document's own, or the one `layout.get`
// answered for it (the shipped default's when the document names none).
export function arrangementOf(document, posture, answered) {
  const own = document && document.postures && document.postures[posture]
  const base = own || answered || {desktop: DEFAULT_DESKTOP, slots: [], floating: []}
  return {
    desktop: base.desktop || DEFAULT_DESKTOP,
    slots: Array.isArray(base.slots) ? base.slots : [],
    floating: Array.isArray(base.floating) ? base.floating : []
  }
}

// Slots in the order the desktop draws them: by order, then id.
export function orderedSlots(arrangement) {
  return [...arrangement.slots].sort((a, b) =>
    a.order !== b.order ? a.order - b.order : a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  )
}

// The document with the posture's slots replaced, renumbered from 0 in the
// order given; a slot that is not card-size names no card.
function withSlots(document, posture, answered, slots) {
  const next = clone(document || {version: 1, postures: {}})
  next.version = 1
  next.postures = next.postures || {}
  const arrangement = arrangementOf(document, posture, answered)
  next.postures[posture] = {
    desktop: arrangement.desktop,
    floating: clone(arrangement.floating),
    slots: slots.map((slot, index) => {
      const kept = {id: slot.id, tincture: slot.tincture, size: slot.size, order: index}
      if (slot.size === "card" && typeof slot.card === "string") kept.card = slot.card
      return kept
    })
  }
  return next
}

function edit(document, posture, answered, change) {
  const slots = orderedSlots(arrangementOf(document, posture, answered))
  return withSlots(document, posture, answered, change(slots))
}

// Move the slot `id` by `delta` places, clamped to the strip.
export function move(document, posture, answered, id, delta) {
  return edit(document, posture, answered, (slots) => {
    const from = slots.findIndex((slot) => slot.id === id)
    if (from < 0) return slots
    const to = Math.max(0, Math.min(slots.length - 1, from + delta))
    const [slot] = slots.splice(from, 1)
    slots.splice(to, 0, slot)
    return slots
  })
}

// Remove the slot `id`; the tincture stays installed.
export function remove(document, posture, answered, id) {
  return edit(document, posture, answered, (slots) => slots.filter((slot) => slot.id !== id))
}

// Draw the slot `id` as an icon or a card. A full slot is the tincture's
// own frame and is not the desktop's to resize.
export function resize(document, posture, answered, id, size) {
  if (size !== "icon" && size !== "card") throw new Error("a slot is resized to icon or card")
  return edit(document, posture, answered, (slots) =>
    slots.map((slot) =>
      slot.id === id && slot.size !== "full" ? {...slot, size, card: size === "card" ? slot.card : undefined} : slot
    )
  )
}

// Place the tincture `ref` at the end of the strip as an icon, under an id
// no slot of the posture uses.
export function add(document, posture, answered, ref) {
  return edit(document, posture, answered, (slots) => {
    const used = new Set(slots.map((slot) => slot.id))
    let n = slots.length
    while (used.has(`s${n}`)) n += 1
    const id = `s${n}`
    if (!SLOT_ID.test(id)) throw new Error("no slot id is free")
    return [...slots, {id, tincture: ref, size: "icon"}]
  })
}
