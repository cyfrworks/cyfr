// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Markdown rendering hook — parses the element's data-raw-content with
// marked, highlights code blocks with highlight.js, and sanitizes the
// result with DOMPurify before it touches innerHTML. The allow/forbid
// lists below are the whole sanitizer policy for assistant- and
// user-authored markdown; loosen them only with the XSS surface in mind.

import {marked} from "../../vendor/marked.esm.js"
import DOMPurify from "../../vendor/purify.es.mjs"
import hljs from "../../vendor/highlight.min.js"

// Configure marked renderer once (v15 API: marked.use, not new Renderer)
let markedConfigured = false
function ensureMarkedConfig() {
  if (markedConfigured) return
  markedConfigured = true
  marked.use({
    breaks: true,
    renderer: {
      code({ text, lang }) {
        let highlighted
        if (lang && hljs.getLanguage(lang)) {
          highlighted = hljs.highlight(text, { language: lang }).value
        } else {
          highlighted = hljs.highlightAuto(text).value
        }
        return `<pre><code class="hljs${lang ? ` language-${lang}` : ""}">${highlighted}</code></pre>`
      },
      link({ href, title, tokens }) {
        const text = this.parser.parseInline(tokens)
        const titleAttr = title ? ` title="${title}"` : ""
        return `<a href="${href}"${titleAttr} target="_blank" rel="noopener noreferrer">${text}</a>`
      }
    }
  })
}

function renderMarkdownToHTML(raw) {
  ensureMarkedConfig()
  const html = marked.parse(raw)
  return DOMPurify.sanitize(html, {
    ALLOWED_TAGS: [
      "h1","h2","h3","h4","h5","h6","p","br","hr","blockquote",
      "ul","ol","li","a","strong","em","del","code","pre",
      "table","thead","tbody","tr","th","td",
      "div","span","img","sup","sub","details","summary"
    ],
    ALLOWED_ATTR: ["href","src","alt","title","class","target","rel","open"],
    FORBID_TAGS: ["script","style","iframe","form","input","button","textarea"],
    FORBID_ATTR: ["onclick","onerror","onload","onmouseover"]
  })
}

const MarkdownContent = {
  mounted() { this._render() },
  updated() { this._render() },
  _render() {
    const raw = this.el.getAttribute("data-raw-content")
    if (!raw) return
    try {
      this.el.innerHTML = renderMarkdownToHTML(raw)
    } catch (e) {
      console.error('[MarkdownContent] render failed:', e)
    }
  }
}

export default MarkdownContent
