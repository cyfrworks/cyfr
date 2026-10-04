// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The chart element: lines, bars and candles drawn as SVG from a validated
// `chart` node (`tree.js`). Every value becomes a number in an attribute the
// toolkit owns; a series' name is set as text. `parseTime` is the tree
// grammar's (`tree.js`), handed in so this module imports nothing of the
// grammar's.

export const SVG_NS = "http://www.w3.org/2000/svg"

// The drawing's own coordinate space; CSS sizes the drawing to its box.
export const VIEW = Object.freeze({width: 600, height: 300, pad: 8})

const round = (value) => String(Math.round(value * 100) / 100)

function svg(doc, tag, attributes) {
  const element = doc.createElementNS(SVG_NS, tag)
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value)
  return element
}

// `node` a validated chart node: `{kind, series: [{name, points}]}`.
export function renderChart(doc, node, parseTime) {
  const figure = doc.createElement("div")
  figure.setAttribute("class", "cyfr-chart")

  const drawing = svg(doc, "svg", {
    class: "cyfr-chart-drawing",
    viewBox: `0 0 ${VIEW.width} ${VIEW.height}`,
    preserveAspectRatio: "none",
    role: "img",
    "aria-label": `${node.kind} chart`
  })

  const ys = yDomain(node)
  const y = scale(ys.min, ys.max, VIEW.height - VIEW.pad, VIEW.pad)

  if (node.kind === "line") drawLines(doc, drawing, node.series, y, parseTime)
  else if (node.kind === "bar") drawBars(doc, drawing, node.series, y, ys)
  else drawCandles(doc, drawing, node.series, y)

  const legend = doc.createElement("div")
  legend.setAttribute("class", "cyfr-chart-legend")
  node.series.forEach((series, i) => {
    const item = doc.createElement("span")
    item.setAttribute("class", `cyfr-chart-key cyfr-series-${i}`)
    item.textContent = series.name
    legend.appendChild(item)
  })

  figure.appendChild(drawing)
  figure.appendChild(legend)
  return figure
}

// A linear map of [d0, d1] onto [r0, r1]; a domain of one value maps to the
// middle of the range.
function scale(d0, d1, r0, r1) {
  if (d0 === d1) return () => (r0 + r1) / 2
  return (value) => r0 + ((value - d0) / (d1 - d0)) * (r1 - r0)
}

function yDomain(node) {
  const values = []
  for (const series of node.series) {
    for (const point of series.points) {
      if (node.kind === "candle") values.push(point.o, point.h, point.l, point.c)
      else values.push(point.y)
    }
  }
  // Bars stand on zero.
  if (node.kind === "bar") values.push(0)
  if (values.length === 0) return {min: 0, max: 1}
  return {min: Math.min(...values), max: Math.max(...values)}
}

// The x of each line point: numbers on a number axis, times on a time axis,
// and anything else, mixed axes included, as categories in order of first
// appearance.
function xPositions(series, parseTime) {
  const all = series.flatMap((one) => one.points.map((point) => point.x))
  let keyed

  if (all.every((x) => typeof x === "number")) {
    keyed = (x) => x
  } else if (all.every((x) => typeof x === "string" && parseTime(x) !== null)) {
    keyed = (x) => parseTime(x)
  } else {
    const order = new Map()
    for (const x of all) {
      const key = typeof x + ":" + String(x)
      if (!order.has(key)) order.set(key, order.size)
    }
    keyed = (x) => order.get(typeof x + ":" + String(x))
  }

  const values = all.map(keyed)
  const x = scale(Math.min(...values), Math.max(...values), VIEW.pad, VIEW.width - VIEW.pad)
  return (point) => x(keyed(point.x))
}

function drawLines(doc, drawing, series, y, parseTime) {
  if (series.every((one) => one.points.length === 0)) return
  const x = xPositions(series, parseTime)

  series.forEach((one, i) => {
    if (one.points.length === 0) return
    const points = one.points.map((point) => `${round(x(point))},${round(y(point.y))}`).join(" ")
    drawing.appendChild(
      svg(doc, "polyline", {
        class: `cyfr-chart-line cyfr-series-${i}`,
        points,
        fill: "none",
        "vector-effect": "non-scaling-stroke"
      })
    )
  })
}

// Bars group by category, in order of first appearance; each series takes
// its own slot in every group.
function drawBars(doc, drawing, series, y, ys) {
  const order = new Map()
  for (const one of series) {
    for (const point of one.points) {
      const key = typeof point.x + ":" + String(point.x)
      if (!order.has(key)) order.set(key, order.size)
    }
  }
  if (order.size === 0) return

  const plot = VIEW.width - 2 * VIEW.pad
  const group = plot / order.size
  const slot = (group * 0.8) / series.length
  const zero = y(Math.max(ys.min, Math.min(0, ys.max)))

  series.forEach((one, i) => {
    for (const point of one.points) {
      const index = order.get(typeof point.x + ":" + String(point.x))
      const top = y(point.y)
      drawing.appendChild(
        svg(doc, "rect", {
          class: `cyfr-chart-bar cyfr-series-${i}`,
          x: round(VIEW.pad + index * group + group * 0.1 + i * slot),
          y: round(Math.min(top, zero)),
          width: round(Math.max(slot, 0.5)),
          height: round(Math.max(Math.abs(zero - top), 0.5))
        })
      )
    }
  })
}

// Candles are spaced evenly in their order; a candle closing at or above its
// open is `up`.
function drawCandles(doc, drawing, series, y) {
  const longest = Math.max(...series.map((one) => one.points.length))
  if (longest === 0) return

  const step = (VIEW.width - 2 * VIEW.pad) / longest
  const body = Math.max(step * 0.6, 0.5)

  for (const one of series) {
    one.points.forEach((point, index) => {
      const center = VIEW.pad + step * (index + 0.5)
      const direction = point.c >= point.o ? "up" : "down"
      drawing.appendChild(
        svg(doc, "line", {
          class: `cyfr-chart-wick cyfr-${direction}`,
          x1: round(center),
          x2: round(center),
          y1: round(y(point.h)),
          y2: round(y(point.l)),
          "vector-effect": "non-scaling-stroke"
        })
      )
      const open = y(point.o)
      const close = y(point.c)
      drawing.appendChild(
        svg(doc, "rect", {
          class: `cyfr-chart-candle cyfr-${direction}`,
          x: round(center - body / 2),
          y: round(Math.min(open, close)),
          width: round(body),
          height: round(Math.max(Math.abs(open - close), 0.5))
        })
      )
    })
  }
}
