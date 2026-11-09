// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A desktop's chrome on Prism's own page (js/canvas/chrome.js): what the
// shell pushes is worn as the variables and data attributes
// css/canvas_chrome.css is written against, each value held to its
// token's grammar, and taken off again for Prism's default; and the
// stylesheet reads exactly those, with the console's look as each default.

import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import Canvas from "../../js/canvas/index.js"
import {KEYWORDS, LENGTHS, ROLES, TEXTURES, fontFamily, wear, worn} from "../../js/canvas/chrome.js"

const CSS = readFileSync(new URL("../../css/canvas_chrome.css", import.meta.url), "utf8")

const SERVED = "/_s/ast.v1.c2lnbmVk/local/styled/1.0.0"

const FULL = {
  colours: {ground: "#f4f1ea", surface: "#ffffff", ink: "#1d1b16", accent: "#8a3b12"},
  lengths: {radius: 4, border: 2, edge: 6, "title-height": 40},
  keywords: {controls: "left", "title-align": "center", glyphs: "round"},
  font: {family: "Inter", src: `${SERVED}/fonts/inter.woff2`},
  textures: {title: `${SERVED}/paper.png`, shelf: `${SERVED}/felt.svg`}
}

// A page root: its style's custom properties and its dataset.
function root() {
  const properties = new Map()
  return {
    properties,
    dataset: {},
    style: {
      setProperty: (name, value) => properties.set(name, value),
      removeProperty: (name) => properties.delete(name)
    }
  }
}

describe("the chrome a desktop wears", () => {
  test("every token is worn as its variable or its data attribute", () => {
    const look = worn(FULL)
    assert.deepEqual(look.properties, {
      "--chrome-ground": "#f4f1ea",
      "--chrome-surface": "#ffffff",
      "--chrome-ink": "#1d1b16",
      "--chrome-accent": "#8a3b12",
      "--chrome-radius": "4px",
      "--chrome-border": "2px",
      "--chrome-edge": "6px",
      "--chrome-title-height": "40px",
      "--chrome-font": `"${fontFamily("Inter")}"`,
      "--chrome-texture-title": `url("${SERVED}/paper.png")`,
      "--chrome-texture-shelf": `url("${SERVED}/felt.svg")`
    })
    assert.deepEqual(look.attributes, {
      chromeColours: "true",
      chromeControls: "left",
      chromeTitleAlign: "center",
      chromeGlyphs: "round"
    })
    assert.deepEqual(look.font, {family: fontFamily("Inter"), src: `${SERVED}/fonts/inter.woff2`})
  })

  test("a value outside its token's grammar is left out, and a mode's colours go together or not at all", () => {
    const look = worn({
      colours: {...FULL.colours, ink: "red"},
      lengths: {radius: 25, border: -1, edge: 6.5, "title-height": "40px"},
      keywords: {controls: "top", glyphs: "pixel"},
      font: {family: "Inter; color: red", src: `${SERVED}/inter.woff2`},
      textures: {title: "https://example.com/x.png", shelf: `${SERVED}/../x.png`}
    })
    assert.deepEqual(look, {properties: {}, attributes: {chromeGlyphs: "pixel"}, font: null})
    assert.equal(worn(null), null)
    assert.equal(worn({}), null)
  })

  test("wearing takes off what was worn before, and none is Prism's default", () => {
    const el = root()
    const held = wear(el, null, FULL)
    assert.equal(el.properties.get("--chrome-radius"), "4px")
    assert.equal(el.dataset.chromeControls, "left")

    const next = wear(el, null, {lengths: {radius: 8}}, held)
    assert.deepEqual([...el.properties], [["--chrome-radius", "8px"]])
    assert.deepEqual(el.dataset, {})

    assert.equal(wear(el, null, null, next), null)
    assert.equal(el.properties.size, 0)
  })

  test("the stylesheet reads exactly the variables and attributes the chrome is worn as, each with a default", () => {
    const variables = new Set([...CSS.matchAll(/var\((--chrome-[a-z-]+)/g)].map((match) => match[1]))
    const expected = new Set([
      ...ROLES.map((role) => `--chrome-${role}`),
      ...Object.keys(LENGTHS).map((name) => `--chrome-${name}`),
      "--chrome-font",
      ...TEXTURES.map((side) => `--chrome-texture-${side}`)
    ])
    assert.deepEqual([...variables].sort(), [...expected].sort())

    const attributes = new Set([...CSS.matchAll(/data-(chrome-[a-z-]+)/g)].map((match) => match[1]))
    assert.deepEqual(
      [...attributes].sort(),
      ["chrome-colours", ...Object.keys(KEYWORDS).map((name) => `chrome-${name}`)].sort()
    )

    // Outside the rules that need a desktop's colours, every variable falls
    // back to the console's own look.
    const outside = CSS.replace(/:root\[data-chrome-colours\][^{]*\{[^}]*\}/g, "")
    for (const [, name, fallback] of outside.matchAll(/var\((--chrome-[a-z-]+)(,?)/g)) {
      assert.equal(fallback, ",", `${name} has a default where no desktop chrome is worn`)
    }
  })
})

describe("the canvas hook", () => {
  test("wears the chrome the shell pushes on the page's root, and takes it off when it goes", () => {
    const el = root()
    const layer = {
      id: "canvas",
      ownerDocument: {documentElement: el, fonts: null},
      querySelector: () => null,
      querySelectorAll: () => [],
      addEventListener() {},
      removeEventListener() {}
    }
    const handlers = {}
    const previous = globalThis.window
    globalThis.window = {innerWidth: 1280, addEventListener() {}, removeEventListener() {}}

    try {
      const hook = Object.assign(Object.create(Canvas), {
        el: {parentElement: layer},
        pushEventTo() {},
        pushEvent() {},
        handleEvent: (event, fn) => (handlers[event] = fn)
      })
      hook.mounted()

      handlers.chrome({chrome: FULL})
      assert.equal(el.properties.get("--chrome-ink"), "#1d1b16")
      handlers.chrome({chrome: null})
      assert.equal(el.properties.size, 0)

      handlers.chrome({chrome: FULL})
      hook.destroyed()
      assert.equal(el.properties.size, 0)
      assert.deepEqual(el.dataset, {})
    } finally {
      globalThis.window = previous
    }
  })
})
