// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {readFileSync, readdirSync} from "node:fs"
import {describe, test} from "node:test"

import {ELEMENTS, STYLESHEET, formatNumber, formatTime} from "../../js/toolkit/elements.js"
import {GRAMMAR_ELEMENTS, MAX_BYTES, parseTime, parseTree, validateTree} from "../../js/toolkit/tree.js"
import {ASSET, NONCE, all, byClass, playedHost} from "./support.mjs"

// The time grammar's vector, which `Prima.Canvas.Shape`'s test reads too.
const times = JSON.parse(readFileSync(new URL("../../../../../tests/fixtures/canvas_shape.json", import.meta.url), "utf8")).times

const valid = (tree) => {
  const result = validateTree(tree)
  assert.equal(result.ok, true, JSON.stringify(result.error))
  return result.tree
}

const refused = (tree, why) => {
  const result = validateTree(tree)
  assert.equal(result.ok, false, why)
  return result.error
}

const text = (value) => ({type: "text", value})
const stack = (children) => ({type: "stack", children})

// One of every element.
const EVERY = stack([
  {type: "grid", columns: 2, gap: "s", children: [text("a"), {type: "spacer"}]},
  {type: "text", value: "Prices", tone: "accent", size: "l", weight: "strong"},
  {type: "number", value: 0.125, format: "percent", digits: 1},
  {type: "time", value: "2026-10-04T11:00:00Z", format: "relative"},
  {type: "list", items: [text("one"), text("two")]},
  {
    type: "table",
    columns: [
      {key: "symbol", title: "Symbol"},
      {key: "price", title: "Price"}
    ],
    rows: [
      {symbol: "BTC", price: 42000.5, extra: true},
      {symbol: "ETH", price: null}
    ]
  },
  {type: "chart", kind: "line", series: [{name: "BTC", points: [{x: 1, y: 2}, {x: 2, y: 3}]}]},
  {type: "image", src: "img/logo.png", alt: "Logo"},
  {type: "control", effect: {open: "tincture:local.vault"}, tone: "accent"},
  {type: "control", effect: {press: {feed: "btc", action: "buy"}}},
  {type: "surface", id: "sky", width: 320, height: 200}
])

describe("the tree grammar", () => {
  test("the grammar's elements are the renderers'", () => {
    assert.deepEqual([...GRAMMAR_ELEMENTS].sort(), [...ELEMENTS].sort())
  })

  test("a tree of every element validates, every optional field written with its default", () => {
    const tree = valid(EVERY)
    assert.equal(tree.direction, "column")
    assert.equal(tree.gap, "m")
    assert.deepEqual(tree.children[1], {type: "text", value: "Prices", tone: "accent", size: "l", weight: "strong"})
    assert.deepEqual(tree.children[2], {type: "number", value: 0.125, format: "percent", digits: 1, tone: "plain", size: "m"})
    assert.deepEqual(tree.children[9], {type: "control", effect: {press: {feed: "btc", action: "buy"}}, tone: "plain", size: "m"})
    assert.deepEqual(valid(text("hi")), {type: "text", value: "hi", tone: "plain", size: "m", weight: "normal"})
    assert.deepEqual(valid({type: "number", value: 1}).digits, null)
    assert.deepEqual(valid({type: "spacer"}), {type: "spacer"})
  })

  test("a field that names a label, markup, style, a handler or a link refuses the whole tree", () => {
    const effect = {open: "tincture:local.vault"}
    for (const [why, node] of [
      ["a control with a label", {type: "control", effect, label: "Refresh"}],
      ["a control with text", {type: "control", effect, text: "Refresh"}],
      ["a control with a title", {type: "control", effect, title: "Refresh"}],
      ["an effect with a label", {type: "control", effect: {open: "tincture:local.vault", label: "Vault"}}],
      ["a press with a label", {type: "control", effect: {press: {feed: "btc", action: "buy", label: "Refresh"}}}],
      ["an href", {type: "text", value: "x", href: "https://example.com/"}],
      ["a style string", {type: "text", value: "x", style: "position: fixed"}],
      ["a class", {type: "stack", children: [], class: "cyfr-control"}],
      ["an html field", {type: "text", value: "x", html: "<b>x</b>"}],
      ["an on* field", {type: "control", effect, onclick: "alert(1)"}],
      ["a url field", {type: "image", src: "a.png", alt: "", url: "https://example.com/"}]
    ]) {
      const error = refused(stack([text("kept"), node]), why)
      assert.equal(error.reason, "field", why)
    }
  })

  test("an image's source is a path inside the version or an image data URL, nothing else", () => {
    for (const src of ["a.png", "img/logo.webp", "deep/er/x~y_z-1.jpeg", "data:image/png;base64,iVBORw0KGgo=", "data:image/webp;base64,"]) {
      valid({type: "image", src, alt: ""})
    }
    for (const src of [
      "https://example.com/a.png",
      "//example.com/a.png",
      "javascript:alert(1)",
      "blob:null/1",
      "/_s/other/a.png",
      "../a.png",
      "img/../../a.png",
      "./a.png",
      "img//a.png",
      "img/a.png?x=1",
      "img/a%2e.png",
      "",
      "data:image/svg+xml;base64,PHN2Zz4=",
      "data:text/html;base64,PHNjcmlwdD4=",
      "data:image/png,raw",
      "data:image/png;base64," + "A".repeat(262144)
    ]) {
      assert.equal(refused({type: "image", src, alt: ""}, src).reason, "value", src)
    }
  })

  test("2000 nodes and depth 24 are drawn; 2001 nodes and depth 25 are not", () => {
    const wide = (n) => stack(Array.from({length: n - 1}, () => ({type: "spacer"})))
    valid(wide(2000))
    assert.equal(refused(wide(2001)).reason, "nodes")

    const deep = (depth) => (depth === 1 ? {type: "spacer"} : stack([deep(depth - 1)]))
    valid(deep(24))
    assert.equal(refused(deep(25)).reason, "depth")
  })

  test("an unknown element, field or value refuses the whole tree, at its pointer", () => {
    assert.deepEqual(refused(stack([text("a"), {type: "iframe"}])), {path: "/children/1/type", reason: "element"})
    assert.deepEqual(refused(stack([{type: "text", value: "a", tone: "neon"}])), {path: "/children/0/tone", reason: "value"})
    assert.deepEqual(refused({type: "text"}), {path: "/value", reason: "required"})
    assert.deepEqual(refused({type: "text", value: "a", size: null}), {path: "/size", reason: "value"})
    assert.deepEqual(refused({value: "a"}), {path: "/type", reason: "element"})
    assert.deepEqual(refused("text"), {path: "", reason: "node"})

    for (const [why, node] of [
      ["a direction", {type: "stack", direction: "diagonal", children: []}],
      ["thirteen columns", {type: "grid", columns: 13, children: []}],
      ["no columns", {type: "grid", columns: 0, children: []}],
      ["fractional columns", {type: "grid", columns: 1.5, children: []}],
      ["a weight", {type: "text", value: "x", weight: "bold"}],
      ["a number as text", {type: "number", value: "1"}],
      ["nine digits", {type: "number", value: 1, digits: 9}],
      ["a currency in lower case", {type: "number", value: 1, format: "currency:usd"}],
      ["a format", {type: "number", value: 1, format: "scientific"}],
      ["a time without an offset", {type: "time", value: "2026-10-04T12:00:00"}],
      ["a time format", {type: "time", value: "2026-10-04T12:00:00Z", format: "ago"}],
      ["501 list items", {type: "list", items: Array.from({length: 501}, () => ({type: "spacer"}))}],
      ["children not a list", {type: "stack", children: {}}],
      ["text past 4096 code points", {type: "text", value: "😀".repeat(4097)}],
      ["no table columns", {type: "table", columns: [], rows: []}],
      ["seventeen table columns", {type: "table", columns: Array.from({length: 17}, (_, i) => ({key: `k${i}`, title: ""})), rows: []}],
      ["a repeated column key", {type: "table", columns: [{key: "a", title: ""}, {key: "a", title: ""}], rows: []}],
      ["a column with a width", {type: "table", columns: [{key: "a", title: "", width: 3}], rows: []}],
      ["a row of objects", {type: "table", columns: [{key: "a", title: ""}], rows: [{a: {b: 1}}]}],
      ["a cell past 1024 code points", {type: "table", columns: [{key: "a", title: ""}], rows: [{a: "x".repeat(1025)}]}],
      ["501 rows", {type: "table", columns: [{key: "a", title: ""}], rows: Array.from({length: 501}, () => ({}))}],
      ["a chart kind", {type: "chart", kind: "pie", series: [{name: "a", points: []}]}],
      ["no series", {type: "chart", kind: "line", series: []}],
      ["nine series", {type: "chart", kind: "line", series: Array.from({length: 9}, () => ({name: "a", points: []}))}],
      ["2001 points", {type: "chart", kind: "line", series: [{name: "a", points: Array.from({length: 2001}, () => ({x: 1, y: 1}))}]}],
      ["a line point with a colour", {type: "chart", kind: "line", series: [{name: "a", points: [{x: 1, y: 1, color: "red"}]}]}],
      ["a candle point as a line's", {type: "chart", kind: "candle", series: [{name: "a", points: [{x: 1, y: 1}]}]}],
      ["a candle time outside the grammar", {type: "chart", kind: "candle", series: [{name: "a", points: [{t: "noon", o: 1, h: 1, l: 1, c: 1}]}]}],
      ["an alt past 256 code points", {type: "image", src: "a.png", alt: "x".repeat(257)}],
      ["an open of a catalyst", {type: "control", effect: {open: "catalyst:local.markets"}}],
      ["two effects", {type: "control", effect: {open: "tincture:local.vault", press: {feed: "btc", action: "buy"}}}],
      ["a press of a feed outside the grammar", {type: "control", effect: {press: {feed: "BTC", action: "buy"}}}],
      ["a navigate effect", {type: "control", effect: {navigate: "/"}}],
      ["a surface id outside the grammar", {type: "surface", id: "Sky", width: 1, height: 1}],
      ["a surface past 4096", {type: "surface", id: "sky", width: 4097, height: 1}],
      ["a spacer with a size", {type: "spacer", size: "l"}]
    ]) {
      assert.notEqual(refused(stack([text("kept"), node]), why).reason, undefined, why)
    }

    assert.equal(refused(stack([{type: "surface", id: "sky", width: 1, height: 1}, {type: "surface", id: "sky", width: 1, height: 1}])).reason, "value")
  })

  test("bounds are counted in code points and a tree's serialized bytes", () => {
    valid({type: "text", value: "😀".repeat(4096)})
    valid({type: "table", columns: [{key: "😀".repeat(64), title: "😀".repeat(256)}], rows: []})

    const json = JSON.stringify({type: "text", value: "x".repeat(4096)})
    assert.equal(parseTree(json).ok, true)
    assert.deepEqual(parseTree(" ".repeat(MAX_BYTES) + json), {ok: false, error: {path: "", reason: "size"}})
    assert.deepEqual(parseTree(" ".repeat(MAX_BYTES - json.length) + json).ok, true)
    // A character outside ASCII counts its UTF-8 bytes.
    assert.deepEqual(parseTree(" ".repeat(MAX_BYTES - json.length - 2) + JSON.stringify({type: "text", value: "é" + "x".repeat(4095)})).ok, true)
    assert.deepEqual(parseTree(" ".repeat(MAX_BYTES - json.length) + JSON.stringify({type: "text", value: "é" + "x".repeat(4095)})).error.reason, "size")
    assert.deepEqual(parseTree("{"), {ok: false, error: {path: "", reason: "json"}})
    assert.deepEqual(parseTree(null), {ok: false, error: {path: "", reason: "json"}})
    assert.deepEqual(parseTree('{"type":"spacer","__proto__":{"x":1}}'), {ok: false, error: {path: "/__proto__", reason: "field"}})
  })

  test("a time is what Prima.Canvas.Shape's time takes", () => {
    for (const {value, unix_ms} of times.valid) {
      assert.equal(parseTime(value), unix_ms, value)
    }
    for (const value of times.invalid) {
      assert.equal(parseTime(value), null, value)
    }
  })
})

describe("drawing a tree", () => {
  test("text holding <script> is drawn as text, and nothing is written as markup", () => {
    const host = playedHost()
    host.boot()
    const hostile = '<script>alert(1)</script><img src=x onerror="alert(2)">'
    host.render(stack([text(hostile), {type: "table", columns: [{key: "a", title: hostile}], rows: [{a: hostile}]}]))

    const drawnText = byClass(host.root(), "cyfr-text")[0]
    assert.equal(drawnText.textContent, hostile)
    assert.equal(drawnText.children.length, 0)
    assert.deepEqual(all(host.root(), (element) => ["script", "img", "iframe", "a"].includes(element.localName)), [])
  })

  test("every element is drawn with the toolkit's classes and attributes, never a style, handler or link", () => {
    const host = playedHost()
    host.boot()
    host.shell.send("installed", {tinctures: [{ref: "tincture:local.vault", name: "Vault"}]})
    host.render(EVERY)

    const drawn = all(host.root(), () => true)
    assert.ok(drawn.length > 20)
    for (const element of drawn) {
      for (const name of element.attributes.keys()) {
        assert.ok(!["style", "href", "xlink:href", "srcdoc", "action", "formaction"].includes(name), name)
        assert.ok(!name.startsWith("on"), name)
      }
      for (const name of element.classes) assert.ok(name.startsWith("cyfr-"), name)
    }

    const image = all(host.root(), (element) => element.localName === "img")[0]
    assert.equal(image.getAttribute("src"), `https://cyfr.example/_s/${ASSET}/img/logo.png`)
    assert.equal(image.getAttribute("alt"), "Logo")
  })

  test("the toolkit's sources write no markup, set no style attribute and evaluate nothing", () => {
    const dir = new URL("../../js/toolkit/", import.meta.url)
    for (const file of readdirSync(dir)) {
      const source = readFileSync(new URL(file, dir), "utf8")
      for (const forbidden of [
        "innerHTML",
        "outerHTML",
        "insertAdjacentHTML",
        "document.write",
        "createContextualFragment",
        "DOMParser",
        "eval(",
        "new Function",
        'setAttribute("style"',
        ".style.cssText",
        "srcdoc",
        "location.",
        "window.open",
        "importScripts"
      ]) {
        assert.ok(!source.includes(forbidden), `${file} uses ${forbidden}`)
      }
    }
  })

  test("the stylesheet is one style element under the host script's nonce", () => {
    const host = playedHost()
    host.boot()
    const styles = all(host.doc.documentElement, (element) => element.localName === "style")
    assert.equal(styles.length, 1)
    assert.equal(styles[0].getAttribute("nonce"), NONCE)
    assert.equal(styles[0].textContent, STYLESHEET)
    assert.equal(styles[0].parentNode, host.doc.head)
    // Only a control is positioned.
    assert.deepEqual(STYLESHEET.match(/position:\s*[a-z]+/g), ["position: relative"])
  })

  test("an invalid tree is dropped and the last valid one stays, with nothing sent to the shell", () => {
    const host = playedHost()
    host.boot()
    host.render(text("first"))
    const sent = host.shell.posted.length

    host.render(stack([text("second"), {type: "control", effect: {open: "tincture:local.vault"}, label: "x"}]))
    host.render(stack([text("third"), {type: "image", src: "https://example.com/x.png", alt: ""}]))
    host.workers.module().emit({t: "tree", json: null})
    host.frames()

    assert.equal(host.root().textContent, "first")
    assert.equal(host.shell.posted.length, sent)
  })

  test("only the newest tree pending at a frame is drawn", () => {
    const host = playedHost()
    host.boot()
    host.render(text("one"), {draw: false})
    host.render(text("two"), {draw: false})
    host.render(text("three"), {draw: false})
    assert.equal(host.root().textContent, "")
    host.frames()
    assert.equal(host.root().textContent, "three")
  })

  test("numbers and times are formatted, never written as markup", () => {
    assert.equal(formatNumber(1234.5, "plain", null, "en-US"), "1,234.5")
    assert.equal(formatNumber(1234.5, "plain", 0, "en-US"), "1,235")
    assert.equal(formatNumber(0.125, "percent", 1, "en-US"), "12.5%")
    assert.equal(formatNumber(1500000, "compact", null, "en-US"), "1.5M")
    assert.equal(formatNumber(42000.5, "currency:USD", 2, "en-US"), "$42,000.50")

    const ctx = {locale: "en-US", timeZone: "UTC", now: () => Date.parse("2026-10-04T12:00:00Z")}
    assert.equal(formatTime(Date.parse("2026-10-04T11:00:00Z"), "relative", ctx), "1 hour ago")
    assert.equal(formatTime(Date.parse("2026-10-04T11:00:00Z"), "date", ctx), "Oct 4, 2026")
    assert.equal(formatTime(Date.parse("2026-10-04T11:00:00Z"), "datetime", ctx), "Oct 4, 2026, 11:00 AM")
  })
})

describe("surfaces", () => {
  const surfaceTree = (width = 320) => stack([{type: "surface", id: "sky", width, height: 200}])
  const transfers = (host) => host.workers.module().posted.filter(({data}) => data.t === "surface")

  test("a surface is handed to the module worker once, and kept across trees of the same size", () => {
    const host = playedHost({offscreen: true})
    host.boot()
    host.render(surfaceTree())
    host.render(stack([text("again"), {type: "surface", id: "sky", width: 320, height: 200}]))

    assert.equal(transfers(host).length, 1)
    const [{data, transfer}] = transfers(host)
    assert.equal(data.id, "sky")
    assert.deepEqual(transfer, [data.canvas])

    host.render(surfaceTree(640))
    assert.equal(transfers(host).length, 2)
  })

  test("a new generation of workers gets fresh canvases for the surfaces still drawn", () => {
    const host = playedHost({offscreen: true})
    host.boot()
    host.render(surfaceTree())
    const before = all(host.root(), (element) => element.localName === "canvas")[0]

    host.shell.send("state", {state: "frozen"})
    host.shell.send("state", {state: "live"})

    const after = all(host.root(), (element) => element.localName === "canvas")[0]
    assert.notEqual(after, before)
    assert.equal(transfers(host).length, 1)
    assert.equal(after.getAttribute("width"), "320")
  })
})
