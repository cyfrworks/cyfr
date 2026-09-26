// The shipped desktop: a strip of the person's slots in layout order.
// Icons open their tincture; cards are drawn from what `card.refresh`
// answers and `cards.refreshed` delivers; a tincture nobody installed is a
// placeholder. Every text a card supplies is set as text, never as markup.
// Arranging publishes the whole document through `layout.edit` with the
// revision it was read at.

import {add, arrangementOf, installedByRef, move, orderedSlots, remove, resize} from "./layout.js"

const cyfr = window.cyfr
const strip = document.getElementById("strip")
const status = document.getElementById("status")
const addSelect = document.getElementById("add-select")
const addButton = document.getElementById("add-button")

const state = {
  posture: window.matchMedia("(max-width: 700px)").matches ? "hand" : "desk",
  document: null,
  answered: null,
  revision: 0,
  installed: new Map(),
  cards: new Map(),
  cardErrors: new Map()
}

function say(text) {
  status.textContent = text || ""
}

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined && text !== null) node.textContent = String(text)
  return node
}

function button(label, text, onClick) {
  const node = el("button", "control", text)
  node.type = "button"
  node.setAttribute("aria-label", label)
  node.addEventListener("click", onClick)
  return node
}

function titleOf(slot) {
  const row = state.installed.get(slot.tincture)
  return (row && (row.description || row.name)) || slot.tincture
}

// ---- reading -------------------------------------------------------------

async function read() {
  const [layout, listing] = await Promise.all([
    cyfr.action("layout.get", {posture: state.posture}),
    cyfr.action("component.list", {type: "tincture", limit: 1000})
  ])

  state.document = layout.document
  state.answered = layout.arrangement
  state.revision = layout.revision
  state.installed = installedByRef(listing && listing.components)
}

async function load() {
  try {
    await read()
    render()
    refreshAll()
  } catch (error) {
    say(`Your desktop could not be read: ${error.message}`)
  }
}

// ---- arranging -----------------------------------------------------------

async function publish(next) {
  try {
    const answer = await cyfr.action("layout.edit", {document: next, revision: state.revision})
    state.document = next
    state.answered = null
    state.revision = answer.revision
    say("")
    render()
    refreshAll()
  } catch (error) {
    if (error.code === "conflict") {
      await load()
      say("Your layout changed elsewhere, so it was read again. Arrange it from here.")
    } else {
      say(`That change was not made: ${error.message}`)
    }
  }
}

function arrange(change) {
  return () => publish(change(state.document, state.posture, state.answered))
}

// ---- cards ---------------------------------------------------------------

async function refresh(slot) {
  try {
    const card = await cyfr.action("card.refresh", {slot: slot.id, posture: state.posture})
    state.cards.set(slot.id, card)
    state.cardErrors.delete(slot.id)
  } catch (error) {
    state.cardErrors.set(slot.id, error.message)
  }
  redrawCard(slot)
}

function refreshAll() {
  for (const slot of slots()) {
    if (slot.size === "card" && state.installed.has(slot.tincture)) refresh(slot)
  }
}

async function press(slot, index) {
  try {
    await cyfr.action("card.press", {slot: slot.id, posture: state.posture, button: index})
    state.cardErrors.delete(slot.id)
    await refresh(slot)
  } catch (error) {
    state.cardErrors.set(slot.id, error.message)
    redrawCard(slot)
  }
}

// A refresh made anywhere for this person, delivered on their own stream.
async function listen() {
  try {
    await cyfr.stream("cards.refreshed", null, ({data}) => {
      if (!data || typeof data.slot !== "string") return
      state.cards.set(data.slot, data.data)
      state.cardErrors.delete(data.slot)
      const slot = slots().find((each) => each.id === data.slot)
      if (slot) redrawCard(slot)
    })
  } catch (_error) {
    // Without the stream a card still refreshes when the desktop asks.
  }
}

// ---- drawing -------------------------------------------------------------

function slots() {
  if (!state.document && !state.answered) return []
  return orderedSlots(arrangementOf(state.document, state.posture, state.answered))
}

function drawCardBody(body, card, error) {
  body.replaceChildren()
  if (!card) {
    body.append(el("p", "card-note", error || "Refreshing…"))
    return
  }

  body.append(el("h3", "card-title", card.title))
  if (card.number !== undefined && card.number !== null) {
    body.append(el("p", "card-number", card.number))
  }
  if (Array.isArray(card.list) && card.list.length > 0) {
    const list = el("ul", "card-list")
    for (const entry of card.list) list.append(el("li", null, entry))
    body.append(list)
  }
  if (typeof card.image === "string") {
    const image = el("div", "card-image", card.title.slice(0, 1))
    image.setAttribute("aria-hidden", "true")
    body.append(image)
  }
  if (error) body.append(el("p", "card-note", error))
}

function redrawCard(slot) {
  const item = strip.querySelector(`[data-slot="${CSS.escape(slot.id)}"]`)
  if (!item) return
  const body = item.querySelector(".card-body")
  const actions = item.querySelector(".card-buttons")
  if (!body || !actions) return

  const card = state.cards.get(slot.id)
  drawCardBody(body, card, state.cardErrors.get(slot.id))

  actions.replaceChildren()
  const buttons = (card && Array.isArray(card.buttons) && card.buttons) || []
  buttons.forEach((declared, index) => {
    actions.append(button(`${declared.label} (${card.title})`, declared.label, () => press(slot, index)))
  })
  actions.append(button(`Refresh ${card ? card.title : titleOf(slot)}`, "Refresh", () => refresh(slot)))
}

function drawSlot(slot, index, count) {
  const item = el("li", `slot slot-${slot.size}`)
  item.dataset.slot = slot.id
  const installed = state.installed.get(slot.tincture)
  const title = titleOf(slot)

  if (!installed) {
    item.classList.add("placeholder")
    item.append(el("p", "placeholder-title", slot.tincture))
    item.append(el("p", "placeholder-note", "Not installed"))
  } else if (slot.size === "card") {
    const card = el("article", "card")
    card.setAttribute("aria-label", title)
    card.append(el("div", "card-body"), el("div", "card-buttons"))
    item.append(card)
  } else {
    const open = button(`Open ${title}`, null, () => cyfr.open(slot.tincture))
    open.className = "icon"
    open.append(el("span", "icon-glyph", title.slice(0, 1).toUpperCase()), el("span", "icon-label", title))
    item.append(open)
  }

  const controls = el("div", "controls")
  controls.setAttribute("role", "group")
  controls.setAttribute("aria-label", `Arrange ${title}`)
  const earlier = button(`Move ${title} earlier`, "‹", arrange((d, p, a) => move(d, p, a, slot.id, -1)))
  earlier.disabled = index === 0
  const later = button(`Move ${title} later`, "›", arrange((d, p, a) => move(d, p, a, slot.id, 1)))
  later.disabled = index === count - 1
  controls.append(earlier, later)

  if (slot.size !== "full") {
    const other = slot.size === "card" ? "icon" : "card"
    controls.append(
      button(`Show ${title} as ${other === "card" ? "a card" : "an icon"}`, other === "card" ? "Card" : "Icon",
        arrange((d, p, a) => resize(d, p, a, slot.id, other)))
    )
  }
  controls.append(button(`Remove ${title} from the desktop`, "Remove", arrange((d, p, a) => remove(d, p, a, slot.id))))
  item.append(controls)
  return item
}

function drawAdd(placed) {
  addSelect.replaceChildren()
  const choices = [...state.installed.keys()].filter(
    (ref) => ref !== "tincture:local.desktop" && !placed.has(ref)
  )
  for (const ref of choices.sort()) {
    const option = el("option", null, titleOf({tincture: ref}))
    option.value = ref
    addSelect.append(option)
  }
  addSelect.disabled = choices.length === 0
  addButton.disabled = choices.length === 0
}

function render() {
  const current = slots()
  strip.replaceChildren(...current.map((slot, index) => drawSlot(slot, index, current.length)))
  for (const slot of current) if (slot.size === "card" && state.installed.has(slot.tincture)) redrawCard(slot)
  drawAdd(new Set(current.map((slot) => slot.tincture)))
  if (current.length === 0) say("Nothing is on your desktop yet. Add an app below.")
}

addButton.addEventListener("click", () => {
  const ref = addSelect.value
  if (ref) publish(add(state.document, state.posture, state.answered, ref))
})

if (cyfr) {
  cyfr.ready()
  load()
  listen()
} else {
  say("This page runs inside the shell.")
}
