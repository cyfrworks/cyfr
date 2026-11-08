// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {markdown} from "../../account/markdown.js"

// A document whose nodes record their tag, attributes and children, and
// `html` writing them out with their text escaped, as a browser would show
// them.
const doc = {
  createElement: (tag) => ({
    tag,
    attributes: {},
    children: [],
    append(...children) {
      this.children.push(...children)
    },
    setAttribute(name, value) {
      this.attributes[name] = value
    }
  }),
  createTextNode: (text) => ({text})
}

const escape = (text) => text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")

function html(nodes) {
  return nodes
    .map((node) => {
      if (!node.tag) return escape(node.text)
      const attributes = Object.entries(node.attributes).map(([name, value]) => ` ${name}="${escape(value)}"`)
      return `<${node.tag}${attributes.join("")}>${html(node.children)}</${node.tag}>`
    })
    .join("")
}

const ALLOWED = new Set(["h2", "h3", "h4", "h5", "h6", "p", "ul", "ol", "li", "blockquote", "strong", "em", "a"])

// Every element is one the renderer allows, and every link opens an
// http(s) or mailto address apart from this page.
function assertStrict(nodes) {
  for (const node of nodes) {
    if (!node.tag) continue
    assert.ok(ALLOWED.has(node.tag), `drew <${node.tag}>`)
    if (node.tag === "a") {
      assert.match(node.attributes.href, /^(https?:\/\/|mailto:)/i)
      assert.equal(node.attributes.rel, "noopener noreferrer")
      assert.equal(node.attributes.target, "_blank")
    } else {
      assert.deepEqual(node.attributes, {})
    }
    assertStrict(node.children)
  }
}

const render = (text) => {
  const nodes = markdown(doc, text)
  assertStrict(nodes)
  return html(nodes)
}

describe("the terms' markdown", () => {
  test("draws headings, paragraphs, lists, blockquotes, emphasis and links", () => {
    const text = [
      "# Terms of Service",
      "",
      "> **Placeholder.** Lawyer-drafted copy replaces this.",
      "",
      "## Summary",
      "",
      "cyfr.run is a registry",
      "operated by _Cyfrworks_. See [the policy](https://cyfr.run/policy).",
      "",
      "- one",
      "- two *words*",
      "  continued",
      "",
      "1. first",
      "2) second",
      "",
      "Write to [us](mailto:report@cyfr.run), snake_case_name stays, \\*not emphasis\\*."
    ].join("\n")
    assert.equal(
      render(text),
      "<h2>Terms of Service</h2>" +
        "<blockquote><p><strong>Placeholder.</strong> Lawyer-drafted copy replaces this.</p></blockquote>" +
        "<h3>Summary</h3>" +
        '<p>cyfr.run is a registry operated by <em>Cyfrworks</em>. See <a href="https://cyfr.run/policy" target="_blank" rel="noopener noreferrer">the policy</a>.</p>' +
        "<ul><li>one</li><li>two <em>words</em> continued</li></ul>" +
        "<ol><li>first</li><li>second</li></ol>" +
        '<p>Write to <a href="mailto:report@cyfr.run" target="_blank" rel="noopener noreferrer">us</a>, snake_case_name stays, *not emphasis*.</p>'
    )
  })

  test("draws <script> as text", () => {
    assert.equal(render("<script>alert(1)</script>"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
    assert.equal(render('# <img src=x onerror="alert(1)">'), "<h2>&lt;img src=x onerror=&quot;alert(1)&quot;&gt;</h2>")
    assert.equal(render("- <a href=\"javascript:alert(1)\">x</a>"), "<ul><li>&lt;a href=&quot;javascript:alert(1)&quot;&gt;x&lt;/a&gt;</li></ul>")
  })

  test("draws a javascript: link as its text alone", () => {
    assert.equal(render("[click](javascript:alert)"), "<p>click</p>")
    assert.equal(render("[click](JavaScript:alert)"), "<p>click</p>")
    assert.equal(render("[click](javascript:alert(1))"), "<p>[click](javascript:alert(1))</p>")
    assert.equal(render("[click](data:text/html,x)"), "<p>click</p>")
    assert.equal(render("[click](//evil.example)"), "<p>click</p>")
    assert.equal(render("[**click**](vbscript:x)"), "<p><strong>click</strong></p>")
  })

  test("draws a link inside a link's text as text", () => {
    assert.equal(render("[a [b](https://x.example)](https://y.example)"), '<p>[a <a href="https://x.example" target="_blank" rel="noopener noreferrer">b</a>](https://y.example)</p>')
  })

  test("bounds how deep quotes and emphasis nest", () => {
    assertStrict(markdown(doc, ">".repeat(5000) + " deep"))
    assertStrict(markdown(doc, "*".repeat(5000) + "x" + "*".repeat(5000)))
  })
})
