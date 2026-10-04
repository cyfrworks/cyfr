// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict"
import {describe, test} from "node:test"

import {SVG_NS, VIEW, renderChart} from "../../js/toolkit/chart.js"
import {parseTime, validateTree} from "../../js/toolkit/tree.js"
import {StandInDocument, all, feedEnvelopes} from "./support.mjs"

const doc = new StandInDocument({url: "https://cyfr.example/"})

const chart = (node) => {
  const result = validateTree({type: "chart", ...node})
  assert.equal(result.ok, true, JSON.stringify(result.error))
  return renderChart(doc, result.tree, parseTime)
}

const drawn = (figure, tag) => all(figure, (element) => element.localName === tag)
const numbers = (element, names) => names.map((name) => Number(element.getAttribute(name)))

const inside = (x, y) => {
  assert.ok(x >= 0 && x <= VIEW.width, `x ${x}`)
  assert.ok(y >= 0 && y <= VIEW.height, `y ${y}`)
}

describe("the chart element", () => {
  test("is SVG in the toolkit's own coordinates, with each series named as text", () => {
    const figure = chart({kind: "line", series: [{name: "BTC <b>", points: [{x: 1, y: 1}]}, {name: "ETH", points: []}]})
    const [drawing] = drawn(figure, "svg")
    assert.equal(drawing.namespaceURI, SVG_NS)
    assert.equal(drawing.getAttribute("viewBox"), `0 0 ${VIEW.width} ${VIEW.height}`)
    assert.equal(drawing.getAttribute("role"), "img")

    const keys = all(figure, (element) => element.classes.includes("cyfr-chart-key"))
    assert.deepEqual(keys.map((key) => key.textContent), ["BTC <b>", "ETH"])
    assert.ok(keys.every((key) => key.children.length === 0))
  })

  test("a line is one polyline per series, its points in order, higher values higher up", () => {
    const figure = chart({
      kind: "line",
      series: [
        {name: "a", points: [{x: 0, y: 0}, {x: 5, y: 10}, {x: 10, y: 5}]},
        {name: "b", points: [{x: 0, y: -5}, {x: 10, y: 20}]}
      ]
    })
    const lines = drawn(figure, "polyline")
    assert.equal(lines.length, 2)
    assert.ok(lines[0].classes.includes("cyfr-series-0") && lines[1].classes.includes("cyfr-series-1"))

    const points = lines[0].getAttribute("points").split(" ").map((pair) => pair.split(",").map(Number))
    assert.equal(points.length, 3)
    for (const [x, y] of points) inside(x, y)
    assert.ok(points[0][0] < points[1][0] && points[1][0] < points[2][0])
    assert.ok(points[1][1] < points[2][1] && points[2][1] < points[0][1])
  })

  test("line points at times are placed by time, and other strings as categories in order", () => {
    const timed = chart({
      kind: "line",
      series: [{name: "a", points: [{x: "2026-10-04T10:00:00Z", y: 1}, {x: "2026-10-04T11:00:00Z", y: 1}, {x: "2026-10-04T14:00:00Z", y: 1}]}]
    })
    const xs = drawn(timed, "polyline")[0].getAttribute("points").split(" ").map((pair) => Number(pair.split(",")[0]))
    // Four hours apart: the first gap is a quarter of the whole.
    assert.ok(Math.abs((xs[1] - xs[0]) / (xs[2] - xs[0]) - 0.25) < 0.01)

    const named = chart({kind: "line", series: [{name: "a", points: [{x: "Mon", y: 1}, {x: "Tue", y: 2}, {x: "Wed", y: 3}]}]})
    const ys = drawn(named, "polyline")[0].getAttribute("points").split(" ").map((pair) => Number(pair.split(",")[0]))
    assert.ok(Math.abs(ys[1] - ys[0] - (ys[2] - ys[1])) < 0.01)
  })

  test("bars stand on zero, one slot per series in each category", () => {
    const figure = chart({
      kind: "bar",
      series: [
        {name: "a", points: [{x: "Mon", y: 4}, {x: "Tue", y: -2}]},
        {name: "b", points: [{x: "Mon", y: 1}]}
      ]
    })
    const bars = drawn(figure, "rect")
    assert.equal(bars.length, 3)
    const [mon, tue, monB] = bars.map((bar) => numbers(bar, ["x", "y", "width", "height"]))
    for (const [x, y, w, h] of [mon, tue, monB]) {
      inside(x, y)
      inside(x + w, y + h)
    }
    // Mon's bar rises from the zero line Tue's falls from.
    assert.ok(Math.abs(mon[1] + mon[3] - tue[1]) < 0.01)
    assert.ok(monB[0] > mon[0] && monB[0] < tue[0])
  })

  test("candles draw a wick and a body, up when the close is at or above the open", () => {
    const {envelope} = feedEnvelopes[0]
    const figure = chart({
      kind: "candle",
      series: [{name: envelope.result.symbol, points: [...envelope.result.candles, {t: "2026-10-04T12:00:00Z", o: 42000.5, h: 42050, l: 41700, c: 41750}]}]
    })
    const wicks = drawn(figure, "line")
    const bodies = drawn(figure, "rect")
    assert.equal(wicks.length, 2)
    assert.equal(bodies.length, 2)
    assert.ok(bodies[0].classes.includes("cyfr-up") && bodies[1].classes.includes("cyfr-down"))

    for (const [wick, body] of [[wicks[0], bodies[0]], [wicks[1], bodies[1]]]) {
      const [x1, y1, x2, y2] = numbers(wick, ["x1", "y1", "x2", "y2"])
      const [x, y, w, h] = numbers(body, ["x", "y", "width", "height"])
      inside(x1, y1)
      inside(x2, y2)
      assert.equal(x1, x2)
      // The body sits on its wick, between the high and the low.
      assert.ok(x < x1 && x + w > x1)
      assert.ok(y >= y1 - 0.01 && y + h <= y2 + 0.01)
    }
  })

  test("an empty series or one value draws inside the drawing", () => {
    assert.equal(drawn(chart({kind: "line", series: [{name: "a", points: []}]}), "polyline").length, 0)
    assert.equal(drawn(chart({kind: "bar", series: [{name: "a", points: []}]}), "rect").length, 0)
    assert.equal(drawn(chart({kind: "candle", series: [{name: "a", points: []}]}), "rect").length, 0)

    const flat = drawn(chart({kind: "line", series: [{name: "a", points: [{x: 1, y: 3}, {x: 1, y: 3}]}]}), "polyline")[0]
    for (const pair of flat.getAttribute("points").split(" ")) inside(...pair.split(",").map(Number))
  })
})
