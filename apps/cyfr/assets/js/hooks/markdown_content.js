// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Markdown rendering hook — parses the element's data-raw-content with
// marked, highlights code blocks with highlight.js, and sanitizes the
// result with DOMPurify before it touches innerHTML. The allow/forbid
// lists below are the whole sanitizer policy for assistant- and
// user-authored markdown; loosen them only with the XSS surface in mind.
// An element that names data-link-base has its rendered links that name
// no address of their own resolved against that base (resolveLinks).

import {marked} from "../../vendor/marked.esm.js"
import DOMPurify from "../../vendor/purify.es.mjs"
import hljs from "../../vendor/highlight.min.js"

// Configure marked's renderer once, through marked.use.
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

// The configured parse step: marked's HTML with highlighted code and links
// that open apart, before the sanitizer. Its output is never put in the
// page; renderMarkdownToHTML sanitizes it first.
export function parseMarkdown(raw) {
  ensureMarkedConfig()
  return marked.parse(raw)
}

function renderMarkdownToHTML(raw) {
  return DOMPurify.sanitize(parseMarkdown(raw), {
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

// A link that names an address of its own: a scheme, a fragment of the
// page, or a host (//host/path).
const OWN_ADDRESS = /^\s*(?:[a-z][a-z0-9+.-]*:|#|\/\/)/i

// Resolves every anchor's href under root that names no address of its
// own against base; other anchors and every other element are left as
// they are. It reads the rendered anchors, never the markdown, so a link
// in a code example stays text. The base is the hosting element's, never
// the content's.
export function resolveLinks(root, base) {
  for (const a of root.querySelectorAll("a[href]")) {
    const href = a.getAttribute("href")
    if (!OWN_ADDRESS.test(href)) a.setAttribute("href", new URL(href, base).href)
  }
}

const MarkdownContent = {
  mounted() { this._render() },
  updated() { this._render() },
  _render() {
    const raw = this.el.getAttribute("data-raw-content")
    if (!raw) return
    try {
      this.el.innerHTML = renderMarkdownToHTML(raw)
      const base = this.el.getAttribute("data-link-base")
      if (base) resolveLinks(this.el, base)
    } catch (e) {
      console.error('[MarkdownContent] render failed:', e)
    }
  }
}

export default MarkdownContent
