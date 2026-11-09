// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A desktop's chrome on Prism's own page (`Prism.Appearance.chrome/2`,
// pushed by `PrismWeb.ShellLive` as `chrome`): its tokens set as the
// variables `canvas_chrome.css` is written against, on the page's root,
// while that desktop is the visible canvas, and taken off again for
// Prism's default. Every value is held to its token's grammar here as
// well: a colour `#rrggbb`, a length whole pixels in its bound, a keyword
// one of its own, a font a family the declaration named and a path the
// shell served, and nothing else reaches the page. The keywords are data
// attributes on the root, which the stylesheet selects on.

const COLOUR = /^#[0-9a-f]{6}$/
const FAMILY = /^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$/
// A version's file, served under an asset credential (`Prima.TinctureUrl`).
const SERVED = /^\/_s\/[A-Za-z0-9._~-]+(\/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+$/

export const ROLES = Object.freeze(["ground", "surface", "ink", "accent"])

export const LENGTHS = Object.freeze({
  radius: [0, 24],
  border: [0, 4],
  edge: [4, 16],
  "title-height": [28, 56]
})

export const KEYWORDS = Object.freeze({
  controls: ["left", "right"],
  "title-align": ["left", "center"],
  glyphs: ["plain", "round", "square", "pixel"]
})

export const TEXTURES = Object.freeze(["title", "shelf"])

// The family a desktop's font is registered under, apart from any font of
// Prism's own.
export const fontFamily = (family) => "cyfr-chrome-" + family

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value)

// The chrome as the page wears it: `{properties, attributes, font}`, the
// custom properties to set, the root's data attributes and the font face
// to load, or null for Prism's default. A value outside its grammar is
// left out.
export function worn(chrome) {
  if (!isObject(chrome)) return null
  const properties = {}
  const attributes = {}
  let font = null

  const colours = isObject(chrome.colours) ? chrome.colours : {}
  if (ROLES.every((role) => typeof colours[role] === "string" && COLOUR.test(colours[role]))) {
    for (const role of ROLES) properties[`--chrome-${role}`] = colours[role]
    attributes.chromeColours = "true"
  }

  const lengths = isObject(chrome.lengths) ? chrome.lengths : {}
  for (const [name, [low, high]] of Object.entries(LENGTHS)) {
    const value = lengths[name]
    if (Number.isInteger(value) && value >= low && value <= high) properties[`--chrome-${name}`] = `${value}px`
  }

  const keywords = isObject(chrome.keywords) ? chrome.keywords : {}
  for (const [name, values] of Object.entries(KEYWORDS)) {
    if (values.includes(keywords[name])) attributes[attribute(name)] = keywords[name]
  }

  const face = chrome.font
  if (isObject(face) && typeof face.family === "string" && FAMILY.test(face.family) && served(face.src)) {
    font = {family: fontFamily(face.family), src: face.src}
    properties["--chrome-font"] = `"${font.family}"`
  }

  const textures = isObject(chrome.textures) ? chrome.textures : {}
  for (const side of TEXTURES) {
    if (served(textures[side])) properties[`--chrome-texture-${side}`] = `url("${textures[side]}")`
  }

  if (Object.keys(properties).length === 0 && Object.keys(attributes).length === 0) return null
  return {properties, attributes, font}
}

const served = (path) => typeof path === "string" && SERVED.test(path)

// `title-align` as a data attribute's dataset key: `chromeTitleAlign`.
const attribute = (name) =>
  "chrome" + name.split("-").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join("")

const ALL_PROPERTIES = [
  ...ROLES.map((role) => `--chrome-${role}`),
  ...Object.keys(LENGTHS).map((name) => `--chrome-${name}`),
  "--chrome-font",
  ...TEXTURES.map((side) => `--chrome-texture-${side}`)
]
const ALL_ATTRIBUTES = ["chromeColours", ...Object.keys(KEYWORDS).map(attribute)]

// Wear `chrome` on `root` (the page's root element) in `doc`, after taking
// off whatever was worn before; `held` is what the last call answered.
// Answers what is worn now, for the next call.
export function wear(root, doc, chrome, held = null) {
  for (const property of ALL_PROPERTIES) root.style.removeProperty(property)
  for (const name of ALL_ATTRIBUTES) delete root.dataset[name]
  if (held && held.face && doc && doc.fonts && typeof doc.fonts.delete === "function") doc.fonts.delete(held.face)

  const look = worn(chrome)
  if (look === null) return null

  for (const [property, value] of Object.entries(look.properties)) root.style.setProperty(property, value)
  for (const [name, value] of Object.entries(look.attributes)) root.dataset[name] = value

  let face = null
  const FontFace = globalThis.FontFace
  if (look.font && typeof FontFace === "function" && doc && doc.fonts && typeof doc.fonts.add === "function") {
    face = new FontFace(look.font.family, `url("${look.font.src}") format("woff2")`)
    doc.fonts.add(face)
    face.load().catch(() => {})
  }
  return {face}
}
