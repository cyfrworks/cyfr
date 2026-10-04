// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The renderers of the tree's elements (`tree.js`), which build the frame's
// document from a validated tree. A value is only ever set as text
// (`textContent`), a number or an attribute the toolkit owns, and styling is
// only ever one of the toolkit's own classes: nothing here writes markup or
// a `style` attribute, and no element navigates.

import {renderChart} from "./chart.js"

// The element names toolkit major 1 draws.
export const ELEMENTS = Object.freeze([
  "stack",
  "grid",
  "text",
  "number",
  "time",
  "list",
  "table",
  "chart",
  "image",
  "control",
  "surface",
  "spacer"
])

// `ctx` carries what an element needs beyond its node:
//   doc          the document;
//   locale       the formatting locale (undefined for the browser's own);
//   timeZone     the time zone times are shown in (undefined for the browser's own);
//   now          the current time in milliseconds, for relative times;
//   parseTime    the grammar's time reader (`tree.js`);
//   imageSource  the URL an image's `src` names;
//   control      the bound control element of a `control` node (`controls.js`);
//   surface      the canvas element of a `surface` node.
export function draw(node, ctx) {
  return RENDERERS[node.type](node, ctx)
}

function element(doc, tag, classes) {
  const created = doc.createElement(tag)
  created.setAttribute("class", classes.join(" "))
  return created
}

const appendAll = (parent, nodes, ctx) => {
  for (const child of nodes) parent.appendChild(draw(child, ctx))
  return parent
}

const RENDERERS = {
  stack: (n, ctx) =>
    appendAll(element(ctx.doc, "div", ["cyfr-stack", `cyfr-direction-${n.direction}`, `cyfr-gap-${n.gap}`]), n.children, ctx),

  grid: (n, ctx) =>
    appendAll(element(ctx.doc, "div", ["cyfr-grid", `cyfr-columns-${n.columns}`, `cyfr-gap-${n.gap}`]), n.children, ctx),

  text(n, ctx) {
    const text = element(ctx.doc, "div", [
      "cyfr-text",
      `cyfr-tone-${n.tone}`,
      `cyfr-size-${n.size}`,
      `cyfr-weight-${n.weight}`
    ])
    text.textContent = n.value
    return text
  },

  number(n, ctx) {
    const number = element(ctx.doc, "div", ["cyfr-number", `cyfr-tone-${n.tone}`, `cyfr-size-${n.size}`])
    number.textContent = formatNumber(n.value, n.format, n.digits, ctx.locale)
    return number
  },

  time(n, ctx) {
    const time = element(ctx.doc, "time", ["cyfr-time"])
    time.setAttribute("datetime", n.value)
    time.textContent = formatTime(ctx.parseTime(n.value), n.format, ctx)
    return time
  },

  list(n, ctx) {
    const list = element(ctx.doc, "ul", ["cyfr-list"])
    for (const item of n.items) {
      const entry = element(ctx.doc, "li", ["cyfr-list-item"])
      entry.appendChild(draw(item, ctx))
      list.appendChild(entry)
    }
    return list
  },

  table(n, ctx) {
    const wrap = element(ctx.doc, "div", ["cyfr-table-wrap"])
    const table = element(ctx.doc, "table", ["cyfr-table"])
    const head = ctx.doc.createElement("thead")
    const titles = ctx.doc.createElement("tr")
    for (const column of n.columns) {
      const title = ctx.doc.createElement("th")
      title.setAttribute("scope", "col")
      title.textContent = column.title
      titles.appendChild(title)
    }
    head.appendChild(titles)

    const body = ctx.doc.createElement("tbody")
    for (const row of n.rows) {
      const line = ctx.doc.createElement("tr")
      for (const column of n.columns) {
        const cell = ctx.doc.createElement("td")
        const value = Object.prototype.hasOwnProperty.call(row, column.key) ? row[column.key] : null
        cell.textContent = formatCell(value, ctx.locale)
        line.appendChild(cell)
      }
      body.appendChild(line)
    }

    table.appendChild(head)
    table.appendChild(body)
    wrap.appendChild(table)
    return wrap
  },

  chart: (n, ctx) => renderChart(ctx.doc, n, ctx.parseTime),

  image(n, ctx) {
    const image = element(ctx.doc, "img", ["cyfr-image"])
    image.setAttribute("src", ctx.imageSource(n.src))
    image.setAttribute("alt", n.alt)
    image.setAttribute("decoding", "async")
    image.setAttribute("draggable", "false")
    return image
  },

  control: (n, ctx) => ctx.control(n),

  surface: (n, ctx) => ctx.surface(n),

  spacer: (_n, ctx) => element(ctx.doc, "div", ["cyfr-spacer"])
}

export function formatNumber(value, format, digits, locale) {
  const options = {}
  if (format === "percent") options.style = "percent"
  else if (format === "compact") options.notation = "compact"
  else if (format.startsWith("currency:")) {
    options.style = "currency"
    options.currency = format.slice("currency:".length)
  }
  if (digits !== null && digits !== undefined) {
    options.minimumFractionDigits = digits
    options.maximumFractionDigits = digits
  }

  try {
    return new Intl.NumberFormat(locale, options).format(value)
  } catch (_error) {
    return String(value)
  }
}

const RELATIVE_UNITS = [
  ["year", 365 * 24 * 3600],
  ["month", 30 * 24 * 3600],
  ["week", 7 * 24 * 3600],
  ["day", 24 * 3600],
  ["hour", 3600],
  ["minute", 60],
  ["second", 1]
]

export function formatTime(millis, format, {locale, timeZone, now}) {
  const date = new Date(millis)
  try {
    if (format === "date") return new Intl.DateTimeFormat(locale, {dateStyle: "medium", timeZone}).format(date)
    if (format === "datetime") {
      return new Intl.DateTimeFormat(locale, {dateStyle: "medium", timeStyle: "short", timeZone}).format(date)
    }

    const seconds = (millis - now()) / 1000
    const [unit, size] = RELATIVE_UNITS.find(([, size]) => Math.abs(seconds) >= size) || ["second", 1]
    return new Intl.RelativeTimeFormat(locale, {numeric: "auto"}).format(Math.round(seconds / size), unit)
  } catch (_error) {
    return date.toISOString()
  }
}

function formatCell(value, locale) {
  if (value === null) return ""
  if (typeof value === "number") return formatNumber(value, "plain", null, locale)
  return String(value)
}

const TONE_COLORS = `
  --cyfr-bg: #f6f7f9; --cyfr-fg: #15181d; --cyfr-muted: #4f5866; --cyfr-line: #d5dae1;
  --cyfr-panel: #ffffff; --cyfr-accent: #0b5cad; --cyfr-good: #1d6b35; --cyfr-warn: #8a5300;
  --cyfr-bad: #b0242c; --cyfr-on-strong: #ffffff;
  --cyfr-series-0: #0b5cad; --cyfr-series-1: #b0242c; --cyfr-series-2: #1d6b35; --cyfr-series-3: #8a5300;
  --cyfr-series-4: #6b3fa0; --cyfr-series-5: #00727a; --cyfr-series-6: #a3366d; --cyfr-series-7: #4f5866;`

const DARK_COLORS = `
  --cyfr-bg: #111418; --cyfr-fg: #eef1f5; --cyfr-muted: #aab3c0; --cyfr-line: #2e353f;
  --cyfr-panel: #1a1f26; --cyfr-accent: #7cb7f2; --cyfr-good: #7dd39a; --cyfr-warn: #f0bc63;
  --cyfr-bad: #f59298; --cyfr-on-strong: #111418;
  --cyfr-series-0: #7cb7f2; --cyfr-series-1: #f59298; --cyfr-series-2: #7dd39a; --cyfr-series-3: #f0bc63;
  --cyfr-series-4: #c3a3ec; --cyfr-series-5: #6fd3da; --cyfr-series-6: #ee9cc4; --cyfr-series-7: #aab3c0;`

const range = (n) => Array.from({length: n}, (_, i) => i)

// The toolkit's one stylesheet, inserted by the host script under its own
// nonce. Only a control is positioned, and it is lifted over its
// neighbours, so no element of a tree can cover a control's label; nothing
// clips one, and a long word wraps.
export const STYLESHEET = `
html, body { margin: 0; min-height: 100%; }
body { background: #f6f7f9; color-scheme: light dark; }
.cyfr-canvas {${TONE_COLORS}
  box-sizing: border-box; min-height: 100vh; padding: 1rem;
  background: var(--cyfr-bg); color: var(--cyfr-fg);
  font: 1rem/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
@media (prefers-color-scheme: dark) { body { background: #111418; } .cyfr-canvas {${DARK_COLORS} } }
.cyfr-canvas[data-posture="hand"] { padding: 0.75rem; }
.cyfr-canvas *, .cyfr-canvas *::before, .cyfr-canvas *::after { box-sizing: border-box; min-width: 0; overflow-wrap: anywhere; }
.cyfr-stack { display: flex; flex-direction: column; }
.cyfr-direction-row { flex-direction: row; flex-wrap: wrap; align-items: center; }
.cyfr-grid { display: grid; align-items: start; }
${range(12).map((i) => `.cyfr-columns-${i + 1} { grid-template-columns: repeat(${i + 1}, minmax(0, 1fr)); }`).join("\n")}
.cyfr-gap-none { gap: 0; } .cyfr-gap-s { gap: 0.25rem; } .cyfr-gap-m { gap: 0.75rem; } .cyfr-gap-l { gap: 1.5rem; }
.cyfr-text { white-space: pre-wrap; }
.cyfr-number { font-variant-numeric: tabular-nums; }
.cyfr-size-s { font-size: 0.875rem; } .cyfr-size-m { font-size: 1rem; }
.cyfr-size-l { font-size: 1.25rem; } .cyfr-size-xl { font-size: 1.75rem; line-height: 1.2; }
.cyfr-weight-normal { font-weight: 400; } .cyfr-weight-strong { font-weight: 650; }
.cyfr-tone-plain { color: var(--cyfr-fg); } .cyfr-tone-muted { color: var(--cyfr-muted); }
.cyfr-tone-accent { color: var(--cyfr-accent); } .cyfr-tone-good { color: var(--cyfr-good); }
.cyfr-tone-warn { color: var(--cyfr-warn); } .cyfr-tone-bad { color: var(--cyfr-bad); }
.cyfr-time { color: var(--cyfr-muted); }
.cyfr-list { margin: 0; padding-left: 1.25rem; display: flex; flex-direction: column; gap: 0.5rem; }
.cyfr-table-wrap { overflow-x: auto; }
.cyfr-table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
.cyfr-table th, .cyfr-table td { text-align: left; padding: 0.375rem 0.5rem; border-bottom: 1px solid var(--cyfr-line); vertical-align: top; }
.cyfr-table th { color: var(--cyfr-muted); font-weight: 600; }
.cyfr-image, .cyfr-surface { display: block; max-width: 100%; height: auto; }
.cyfr-spacer { flex: 1 1 auto; min-height: 0.5rem; }
.cyfr-chart { width: 100%; }
.cyfr-chart-drawing { display: block; width: 100%; height: 12rem; overflow: visible; }
.cyfr-chart-line { fill: none; stroke-width: 2; stroke-linejoin: round; }
${range(8).map((i) => `.cyfr-series-${i} { stroke: var(--cyfr-series-${i}); fill: var(--cyfr-series-${i}); }`).join("\n")}
.cyfr-chart-line.cyfr-series-0, ${range(7).map((i) => `.cyfr-chart-line.cyfr-series-${i + 1}`).join(", ")} { fill: none; }
.cyfr-chart-wick { stroke-width: 1; }
.cyfr-up { stroke: var(--cyfr-good); fill: var(--cyfr-good); }
.cyfr-down { stroke: var(--cyfr-bad); fill: var(--cyfr-bad); }
.cyfr-chart-legend { display: flex; flex-wrap: wrap; gap: 0.75rem; font-size: 0.875rem; margin-top: 0.25rem; }
.cyfr-chart-key::before { content: ""; display: inline-block; width: 0.75rem; height: 0.75rem; margin-right: 0.375rem; border-radius: 2px; background: currentColor; vertical-align: -0.1rem; }
${range(8).map((i) => `.cyfr-chart-key.cyfr-series-${i} { color: var(--cyfr-series-${i}); }`).join("\n")}
.cyfr-control {
  position: relative; z-index: 1; display: inline-flex; align-items: center; justify-content: center;
  min-height: 2.75rem; min-width: 2.75rem; max-width: 100%; padding: 0.5rem 1rem;
  border: 1px solid var(--cyfr-line); border-radius: 0.5rem; background: var(--cyfr-panel); color: var(--cyfr-fg);
  font-size: 1rem; font-weight: 600; line-height: 1.25; text-align: center; white-space: normal;
  cursor: pointer; user-select: none; -webkit-user-select: none; opacity: 1; visibility: visible;
}
.cyfr-control.cyfr-size-s, .cyfr-control.cyfr-size-m { font-size: 1rem; }
.cyfr-control.cyfr-size-l { font-size: 1.25rem; } .cyfr-control.cyfr-size-xl { font-size: 1.5rem; }
.cyfr-control.cyfr-tone-plain, .cyfr-control.cyfr-tone-muted { color: var(--cyfr-fg); }
.cyfr-control.cyfr-tone-accent { background: var(--cyfr-accent); border-color: var(--cyfr-accent); color: var(--cyfr-on-strong); }
.cyfr-control.cyfr-tone-good { background: var(--cyfr-good); border-color: var(--cyfr-good); color: var(--cyfr-on-strong); }
.cyfr-control.cyfr-tone-warn { background: var(--cyfr-warn); border-color: var(--cyfr-warn); color: var(--cyfr-on-strong); }
.cyfr-control.cyfr-tone-bad { background: var(--cyfr-bad); border-color: var(--cyfr-bad); color: var(--cyfr-on-strong); }
.cyfr-control:focus-visible { outline: 3px solid var(--cyfr-accent); outline-offset: 2px; }
.cyfr-control[aria-disabled="true"] { cursor: not-allowed; background: var(--cyfr-panel); border-style: dashed; border-color: var(--cyfr-muted); color: var(--cyfr-muted); }
`
