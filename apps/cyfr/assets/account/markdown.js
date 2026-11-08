// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The terms' markdown drawn as DOM nodes, never parsed as HTML: every
// character of the input lands in a text node, so markup in it shows as
// text. Only headings, paragraphs, lists, blockquotes, emphasis and links
// are drawn; anything else is a paragraph's text. A link is drawn only to
// an http(s) or mailto address, opening in a new tab with
// rel="noopener noreferrer"; any other target is drawn as its text alone.

const HEADING = /^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/
const QUOTE = /^ {0,3}> ?/
const ITEM = /^ {0,3}(?:[-*+]|(\d{1,9})[.)])[ \t]+(.*)$/
const LINK_TARGET = /^(?:https?:\/\/|mailto:)/i

const ESCAPED = /\\([!-/:-@[-`{-~])/y
const LINKED = /\[([^[\]\n]*)\]\(([^()\s]*)\)/y
const STRONG = /(\*\*|__)(?=\S)([\s\S]*?\S)\1/y
const EMPHASIS = /([*_])(?=\S)([\s\S]*?\S)\1/y

// Deeper quotes or emphasis than this are drawn as text, so no input
// recurses without bound.
const MAX_DEPTH = 8

/** `text`'s markdown as an array of nodes made by `doc`. */
export function markdown(doc, text) {
  return blocks(doc, String(text).split(/\r\n|\r|\n/), 0)
}

const starts = (line, depth) => HEADING.test(line) || (depth < MAX_DEPTH && QUOTE.test(line)) || ITEM.test(line)

function blocks(doc, lines, depth) {
  const out = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    const heading = HEADING.exec(line)
    const item = ITEM.exec(line)
    if (line.trim() === "") {
      i++
    } else if (heading) {
      out.push(element(doc, `h${Math.min(heading[1].length + 1, 6)}`, inline(doc, heading[2], 0, true)))
      i++
    } else if (depth < MAX_DEPTH && QUOTE.test(line)) {
      const quoted = []
      while (i < lines.length && QUOTE.test(lines[i])) quoted.push(lines[i++].replace(QUOTE, ""))
      out.push(element(doc, "blockquote", blocks(doc, quoted, depth + 1)))
    } else if (item) {
      // One list of the same kind of item; an indented line that starts
      // no item continues the one before.
      const ordered = item[1] !== undefined
      const items = []
      while (i < lines.length) {
        const next = ITEM.exec(lines[i])
        if (next && (next[1] !== undefined) === ordered) items.push([next[2]])
        else if (!next && /^[ \t]+\S/.test(lines[i])) items.at(-1).push(lines[i].trim())
        else break
        i++
      }
      out.push(element(doc, ordered ? "ol" : "ul", items.map((parts) => element(doc, "li", inline(doc, parts.join(" "), 0, true)))))
    } else {
      const words = []
      while (i < lines.length && lines[i].trim() !== "" && !starts(lines[i], depth)) words.push(lines[i++].trim())
      out.push(element(doc, "p", inline(doc, words.join(" "), 0, true)))
    }
  }
  return out
}

// `text`'s escapes, links (when `links`) and emphasis as nodes; everything
// else is text.
function inline(doc, text, depth, links) {
  const nodes = []
  let plain = ""
  const flush = () => {
    if (plain) nodes.push(doc.createTextNode(plain))
    plain = ""
  }
  let at = 0
  while (at < text.length) {
    const char = text[at]
    const intraword = char === "_" && at > 0 && /[\p{L}\p{N}]/u.test(text[at - 1])
    const match =
      char === "\\" ? sticky(ESCAPED, text, at)
      : char === "[" && links ? sticky(LINKED, text, at)
      : (char === "*" || char === "_") && !intraword && depth < MAX_DEPTH ? sticky(STRONG, text, at) ?? sticky(EMPHASIS, text, at)
      : null
    if (!match) {
      plain += char
      at++
      continue
    }
    at += match[0].length
    if (char === "\\") {
      plain += match[1]
      continue
    }
    flush()
    if (char === "[") nodes.push(...link(doc, match[1], match[2], depth))
    else nodes.push(element(doc, match[1].length === 2 ? "strong" : "em", inline(doc, match[2], depth + 1, links)))
  }
  flush()
  return nodes
}

function link(doc, label, target, depth) {
  const text = inline(doc, label, depth + 1, false)
  if (!LINK_TARGET.test(target)) return text
  const a = element(doc, "a", text)
  a.setAttribute("href", target)
  a.setAttribute("target", "_blank")
  a.setAttribute("rel", "noopener noreferrer")
  return [a]
}

function sticky(pattern, text, at) {
  pattern.lastIndex = at
  return pattern.exec(text)
}

function element(doc, tag, children) {
  const made = doc.createElement(tag)
  made.append(...children)
  return made
}
