// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {parseMarkdown, resolveLinks} from "../../js/hooks/markdown_content.js"

// The account service's address, as a legal page's element names it.
const BASE = "https://cyfr.run"

// A rendered root holding anchors with these hrefs: the two calls
// resolveLinks makes on an element and its anchors, nothing else. The
// sanitized render that hands it real anchors is tests/markdown-proof's.
function rootOf(hrefs) {
  const anchors = hrefs.map((href) => {
    const attrs = {href}
    return {attrs, getAttribute: (name) => attrs[name], setAttribute: (name, value) => (attrs[name] = value)}
  })
  return {anchors, querySelectorAll: (selector) => (selector === "a[href]" ? anchors : [])}
}

describe("a legal page's links", () => {
  // Each form a page may name a path in becomes an anchor whose href is
  // the path, which resolveLinks then reads.
  const forms = [
    ["an inline link", "Report [it](/legal/ncii/report)."],
    ["a reference link with its definition", "Report [it][r].\n\n[r]: /legal/ncii/report"],
    ["the angle-bracket form", "Report [it](</legal/ncii/report>)."]
  ]
  for (const [name, raw] of forms) {
    test(`${name} renders as an anchor on the path`, () =>
      assert.equal(
        parseMarkdown(raw),
        '<p>Report <a href="/legal/ncii/report" target="_blank" rel="noopener noreferrer">it</a>.</p>\n'
      ))
  }

  test("a single-quoted HTML href passes to the sanitizer as written", () =>
    assert.equal(
      parseMarkdown("Report <a href='/legal/ncii/report'>it</a>."),
      "<p>Report <a href='/legal/ncii/report'>it</a>.</p>\n"
    ))

  test("code that shows a link stays text: no anchor, the source as written", () =>
    assert.equal(
      parseMarkdown("An example: `[it](/legal/ncii/report)`"),
      "<p>An example: <code>[it](/legal/ncii/report)</code></p>\n"
    ))

  test("a path, a relative path and a query resolve against the base", () => {
    const root = rootOf(["/legal/ncii/report", "legal/dmca", "?page=2"])
    resolveLinks(root, BASE)
    assert.deepEqual(
      root.anchors.map((a) => a.attrs.href),
      [`${BASE}/legal/ncii/report`, `${BASE}/legal/dmca`, `${BASE}/?page=2`]
    )
  })

  test("a link with an address of its own is left as it is", () => {
    const hrefs = ["https://example.com/x", "mailto:a@b.c", "#top", "//example.com/x"]
    const root = rootOf(hrefs)
    resolveLinks(root, BASE)
    assert.deepEqual(root.anchors.map((a) => a.attrs.href), hrefs)
  })
})
