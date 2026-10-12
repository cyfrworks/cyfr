// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {parseMarkdown} from "../../js/hooks/markdown_content.js"

// The hook's parse step with the vendored marked and the hook's own
// options (line breaks kept, the code and link renderers), before the
// sanitizer: what marked hands DOMPurify for each shape of message. The
// sanitized result, checkbox inputs removed, needs a browser's DOM and is
// tests/markdown-proof's.
describe("the markdown hook's parse step", () => {
  const cases = [
    ["a list", "- one\n- two\n- three", "<ul>\n<li>one</li>\n<li>two</li>\n<li>three</li>\n</ul>\n"],
    ["an ordered list", "1. first\n2. second", "<ol>\n<li>first</li>\n<li>second</li>\n</ol>\n"],
    ["a loose list", "- one\n\n- two", "<ul>\n<li><p>one</p>\n</li>\n<li><p>two</p>\n</li>\n</ul>\n"],
    [
      "a nested list",
      "- outer\n  - inner a\n  - inner b\n- after",
      "<ul>\n<li>outer<ul>\n<li>inner a</li>\n<li>inner b</li>\n</ul>\n</li>\n<li>after</li>\n</ul>\n"
    ],
    [
      "a nested ordered list",
      "1. a\n   1. a.i\n2. b",
      "<ol>\n<li>a<ol>\n<li>a.i</li>\n</ol>\n</li>\n<li>b</li>\n</ol>\n"
    ],
    [
      "paragraphs, a single newline kept as a break",
      "first line\nsecond line\n\nnext paragraph",
      "<p>first line<br>second line</p>\n<p>next paragraph</p>\n"
    ],
    [
      "task items",
      "- [ ] todo\n- [x] done\n- plain",
      '<ul>\n<li><input disabled="" type="checkbox"> todo</li>\n<li><input checked="" disabled="" type="checkbox"> done</li>\n<li>plain</li>\n</ul>\n'
    ],
    [
      "loose task items",
      "- [ ] todo\n\n- [x] done",
      '<ul>\n<li><p><input disabled="" type="checkbox"> todo</p>\n</li>\n<li><p><input checked="" disabled="" type="checkbox"> done</p>\n</li>\n</ul>\n'
    ],
    [
      "a task item with a paragraph after it",
      "- [x] done\n\n  more text",
      '<ul>\n<li><p><input checked="" disabled="" type="checkbox"> done</p>\n<p>more text</p>\n</li>\n</ul>\n'
    ],
    [
      "nested task items",
      "- [ ] parent\n  - [x] child",
      '<ul>\n<li><input disabled="" type="checkbox"> parent<ul>\n<li><input checked="" disabled="" type="checkbox"> child</li>\n</ul>\n</li>\n</ul>\n'
    ],
    ["trailing blank lines", "text\n\n\n", "<p>text</p>\n"],
    ["a list with trailing blank lines", "- a\n- b\n\n\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"],
    ["a list then a paragraph", "- a\n- b\n\nafter", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<p>after</p>\n"],
    [
      "an HTML block with blank lines in it",
      "<details><summary>s</summary>\n\nbody\n\n</details>",
      "<details><summary>s</summary><p>body</p>\n</details>"
    ],
    [
      "a link, which opens apart",
      '[t](http://e.com "title")',
      '<p><a href="http://e.com" title="title" target="_blank" rel="noopener noreferrer">t</a></p>\n'
    ]
  ]

  for (const [name, raw, html] of cases) {
    test(name, () => assert.equal(parseMarkdown(raw), html))
  }

  test("a fenced code block is highlighted in the hook's own code element", () => {
    assert.equal(
      parseMarkdown("```js\nconst x = 1\n```\n\n\n"),
      '<pre><code class="hljs language-js"><span class="hljs-keyword">const</span> x = <span class="hljs-number">1</span></code></pre>'
    )
  })
})
