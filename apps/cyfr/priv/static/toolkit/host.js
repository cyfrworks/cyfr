// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
// Built from apps/cyfr/assets/js/toolkit by `mix esbuild toolkit_host`.
(() => {
  // js/sdk/wire.js
  var VERSION = 1;
  var ROUTES = Object.freeze({
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action",
    stream_open: "/_f/v1/stream"
  });
  var VERBS = Object.freeze(["open", "close", "title", "ready", "credential"]);
  var HANDSHAKE = "cyfr:handshake";
  var FRAME_ID = /^[A-Za-z0-9_-]{8,64}$/;
  function isFrameId(id) {
    return typeof id === "string" && FRAME_ID.test(id);
  }

  // js/toolkit/controls.js
  var UNAVAILABLE = "Unavailable";
  var PRESS_KEYS = ["Enter", " ", "Spacebar"];
  function resolveEffect(effect2, { installed, records }) {
    if (Object.prototype.hasOwnProperty.call(effect2, "open")) {
      const entry = installed.find((tincture) => tincture.ref === effect2.open);
      return entry ? { kind: "open", ref: entry.ref, label: entry.name } : null;
    }
    const record = records.get(effect2.press.feed);
    if (!record) return null;
    const action = record.actions.find((one) => one.name === effect2.press.action);
    return action ? { kind: "press", binding: record.binding, action: action.name, label: action.label } : null;
  }
  function createControls({ doc, dispatch }) {
    const consumed = /* @__PURE__ */ new WeakSet();
    let drawn = [];
    function disable(control) {
      control.setAttribute("aria-disabled", "true");
    }
    return {
      // The element of a validated control node bound to `resolved`: a
      // focusable button whose accessible name is its label, the
      // declaration's or the toolkit's own word.
      element(node2, resolved) {
        const label = resolved === null ? UNAVAILABLE : resolved.label;
        const control = doc.createElement("div");
        control.setAttribute("class", `cyfr-control cyfr-tone-${node2.tone} cyfr-size-${node2.size}`);
        control.setAttribute("role", "button");
        control.setAttribute("tabindex", "0");
        control.setAttribute("aria-label", label);
        control.textContent = label;
        if (resolved === null) {
          disable(control);
          return control;
        }
        const press = (event) => {
          if (event.isTrusted !== true) return;
          if (event.type === "keydown") {
            if (!PRESS_KEYS.includes(event.key) || event.repeat) return;
            event.preventDefault();
          }
          if (consumed.has(event)) return;
          consumed.add(event);
          if (control.getAttribute("aria-disabled") === "true") return;
          dispatch(resolved);
        };
        control.addEventListener("click", press);
        control.addEventListener("keydown", press);
        drawn.push(control);
        return control;
      },
      // A new tree replaces every control.
      reset() {
        drawn = [];
      },
      // The canvas failed: its controls stay drawn, and none acts again.
      disableAll() {
        for (const control of drawn) disable(control);
      }
    };
  }

  // js/toolkit/chart.js
  var SVG_NS = "http://www.w3.org/2000/svg";
  var VIEW = Object.freeze({ width: 600, height: 300, pad: 8 });
  var round = (value) => String(Math.round(value * 100) / 100);
  function svg(doc, tag, attributes) {
    const element2 = doc.createElementNS(SVG_NS, tag);
    for (const [name, value] of Object.entries(attributes)) element2.setAttribute(name, value);
    return element2;
  }
  function renderChart(doc, node2, parseTime2) {
    const figure = doc.createElement("div");
    figure.setAttribute("class", "cyfr-chart");
    const drawing = svg(doc, "svg", {
      class: "cyfr-chart-drawing",
      viewBox: `0 0 ${VIEW.width} ${VIEW.height}`,
      preserveAspectRatio: "none",
      role: "img",
      "aria-label": `${node2.kind} chart`
    });
    const ys = yDomain(node2);
    const y = scale(ys.min, ys.max, VIEW.height - VIEW.pad, VIEW.pad);
    if (node2.kind === "line") drawLines(doc, drawing, node2.series, y, parseTime2);
    else if (node2.kind === "bar") drawBars(doc, drawing, node2.series, y, ys);
    else drawCandles(doc, drawing, node2.series, y);
    const legend = doc.createElement("div");
    legend.setAttribute("class", "cyfr-chart-legend");
    node2.series.forEach((series, i) => {
      const item = doc.createElement("span");
      item.setAttribute("class", `cyfr-chart-key cyfr-series-${i}`);
      item.textContent = series.name;
      legend.appendChild(item);
    });
    figure.appendChild(drawing);
    figure.appendChild(legend);
    return figure;
  }
  function scale(d0, d1, r0, r1) {
    if (d0 === d1) return () => (r0 + r1) / 2;
    return (value) => r0 + (value - d0) / (d1 - d0) * (r1 - r0);
  }
  function yDomain(node2) {
    const values = [];
    for (const series of node2.series) {
      for (const point of series.points) {
        if (node2.kind === "candle") values.push(point.o, point.h, point.l, point.c);
        else values.push(point.y);
      }
    }
    if (node2.kind === "bar") values.push(0);
    if (values.length === 0) return { min: 0, max: 1 };
    return { min: Math.min(...values), max: Math.max(...values) };
  }
  function xPositions(series, parseTime2) {
    const all = series.flatMap((one) => one.points.map((point) => point.x));
    let keyed;
    if (all.every((x2) => typeof x2 === "number")) {
      keyed = (x2) => x2;
    } else if (all.every((x2) => typeof x2 === "string" && parseTime2(x2) !== null)) {
      keyed = (x2) => parseTime2(x2);
    } else {
      const order = /* @__PURE__ */ new Map();
      for (const x2 of all) {
        const key = typeof x2 + ":" + String(x2);
        if (!order.has(key)) order.set(key, order.size);
      }
      keyed = (x2) => order.get(typeof x2 + ":" + String(x2));
    }
    const values = all.map(keyed);
    const x = scale(Math.min(...values), Math.max(...values), VIEW.pad, VIEW.width - VIEW.pad);
    return (point) => x(keyed(point.x));
  }
  function drawLines(doc, drawing, series, y, parseTime2) {
    if (series.every((one) => one.points.length === 0)) return;
    const x = xPositions(series, parseTime2);
    series.forEach((one, i) => {
      if (one.points.length === 0) return;
      const points = one.points.map((point) => `${round(x(point))},${round(y(point.y))}`).join(" ");
      drawing.appendChild(
        svg(doc, "polyline", {
          class: `cyfr-chart-line cyfr-series-${i}`,
          points,
          fill: "none",
          "vector-effect": "non-scaling-stroke"
        })
      );
    });
  }
  function drawBars(doc, drawing, series, y, ys) {
    const order = /* @__PURE__ */ new Map();
    for (const one of series) {
      for (const point of one.points) {
        const key = typeof point.x + ":" + String(point.x);
        if (!order.has(key)) order.set(key, order.size);
      }
    }
    if (order.size === 0) return;
    const plot = VIEW.width - 2 * VIEW.pad;
    const group = plot / order.size;
    const slot = group * 0.8 / series.length;
    const zero = y(Math.max(ys.min, Math.min(0, ys.max)));
    series.forEach((one, i) => {
      for (const point of one.points) {
        const index = order.get(typeof point.x + ":" + String(point.x));
        const top = y(point.y);
        drawing.appendChild(
          svg(doc, "rect", {
            class: `cyfr-chart-bar cyfr-series-${i}`,
            x: round(VIEW.pad + index * group + group * 0.1 + i * slot),
            y: round(Math.min(top, zero)),
            width: round(Math.max(slot, 0.5)),
            height: round(Math.max(Math.abs(zero - top), 0.5))
          })
        );
      }
    });
  }
  function drawCandles(doc, drawing, series, y) {
    const longest = Math.max(...series.map((one) => one.points.length));
    if (longest === 0) return;
    const step = (VIEW.width - 2 * VIEW.pad) / longest;
    const body = Math.max(step * 0.6, 0.5);
    for (const one of series) {
      one.points.forEach((point, index) => {
        const center = VIEW.pad + step * (index + 0.5);
        const direction = point.c >= point.o ? "up" : "down";
        drawing.appendChild(
          svg(doc, "line", {
            class: `cyfr-chart-wick cyfr-${direction}`,
            x1: round(center),
            x2: round(center),
            y1: round(y(point.h)),
            y2: round(y(point.l)),
            "vector-effect": "non-scaling-stroke"
          })
        );
        const open = y(point.o);
        const close = y(point.c);
        drawing.appendChild(
          svg(doc, "rect", {
            class: `cyfr-chart-candle cyfr-${direction}`,
            x: round(center - body / 2),
            y: round(Math.min(open, close)),
            width: round(body),
            height: round(Math.max(Math.abs(open - close), 0.5))
          })
        );
      });
    }
  }

  // js/toolkit/elements.js
  var ELEMENTS = Object.freeze([
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
  ]);
  function draw(node2, ctx) {
    return RENDERERS[node2.type](node2, ctx);
  }
  function element(doc, tag, classes) {
    const created = doc.createElement(tag);
    created.setAttribute("class", classes.join(" "));
    return created;
  }
  var appendAll = (parent, nodes, ctx) => {
    for (const child of nodes) parent.appendChild(draw(child, ctx));
    return parent;
  };
  var RENDERERS = {
    stack: (n, ctx) => appendAll(element(ctx.doc, "div", ["cyfr-stack", `cyfr-direction-${n.direction}`, `cyfr-gap-${n.gap}`]), n.children, ctx),
    grid: (n, ctx) => appendAll(element(ctx.doc, "div", ["cyfr-grid", `cyfr-columns-${n.columns}`, `cyfr-gap-${n.gap}`]), n.children, ctx),
    text(n, ctx) {
      const text = element(ctx.doc, "div", [
        "cyfr-text",
        `cyfr-tone-${n.tone}`,
        `cyfr-size-${n.size}`,
        `cyfr-weight-${n.weight}`
      ]);
      text.textContent = n.value;
      return text;
    },
    number(n, ctx) {
      const number = element(ctx.doc, "div", ["cyfr-number", `cyfr-tone-${n.tone}`, `cyfr-size-${n.size}`]);
      number.textContent = formatNumber(n.value, n.format, n.digits, ctx.locale);
      return number;
    },
    time(n, ctx) {
      const time = element(ctx.doc, "time", ["cyfr-time"]);
      time.setAttribute("datetime", n.value);
      time.textContent = formatTime(ctx.parseTime(n.value), n.format, ctx);
      return time;
    },
    list(n, ctx) {
      const list = element(ctx.doc, "ul", ["cyfr-list"]);
      for (const item of n.items) {
        const entry = element(ctx.doc, "li", ["cyfr-list-item"]);
        entry.appendChild(draw(item, ctx));
        list.appendChild(entry);
      }
      return list;
    },
    table(n, ctx) {
      const wrap = element(ctx.doc, "div", ["cyfr-table-wrap"]);
      const table = element(ctx.doc, "table", ["cyfr-table"]);
      const head = ctx.doc.createElement("thead");
      const titles = ctx.doc.createElement("tr");
      for (const column of n.columns) {
        const title = ctx.doc.createElement("th");
        title.setAttribute("scope", "col");
        title.textContent = column.title;
        titles.appendChild(title);
      }
      head.appendChild(titles);
      const body = ctx.doc.createElement("tbody");
      for (const row of n.rows) {
        const line = ctx.doc.createElement("tr");
        for (const column of n.columns) {
          const cell = ctx.doc.createElement("td");
          const value = Object.prototype.hasOwnProperty.call(row, column.key) ? row[column.key] : null;
          cell.textContent = formatCell(value, ctx.locale);
          line.appendChild(cell);
        }
        body.appendChild(line);
      }
      table.appendChild(head);
      table.appendChild(body);
      wrap.appendChild(table);
      return wrap;
    },
    chart: (n, ctx) => renderChart(ctx.doc, n, ctx.parseTime),
    image(n, ctx) {
      const image = element(ctx.doc, "img", ["cyfr-image"]);
      image.setAttribute("src", ctx.imageSource(n.src));
      image.setAttribute("alt", n.alt);
      image.setAttribute("decoding", "async");
      image.setAttribute("draggable", "false");
      return image;
    },
    control: (n, ctx) => ctx.control(n),
    surface: (n, ctx) => ctx.surface(n),
    spacer: (_n, ctx) => element(ctx.doc, "div", ["cyfr-spacer"])
  };
  function formatNumber(value, format, digits, locale) {
    const options = {};
    if (format === "percent") options.style = "percent";
    else if (format === "compact") options.notation = "compact";
    else if (format.startsWith("currency:")) {
      options.style = "currency";
      options.currency = format.slice("currency:".length);
    }
    if (digits !== null && digits !== void 0) {
      options.minimumFractionDigits = digits;
      options.maximumFractionDigits = digits;
    }
    try {
      return new Intl.NumberFormat(locale, options).format(value);
    } catch (_error) {
      return String(value);
    }
  }
  var RELATIVE_UNITS = [
    ["year", 365 * 24 * 3600],
    ["month", 30 * 24 * 3600],
    ["week", 7 * 24 * 3600],
    ["day", 24 * 3600],
    ["hour", 3600],
    ["minute", 60],
    ["second", 1]
  ];
  function formatTime(millis, format, { locale, timeZone, now }) {
    const date = new Date(millis);
    try {
      if (format === "date") return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeZone }).format(date);
      if (format === "datetime") {
        return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short", timeZone }).format(date);
      }
      const seconds = (millis - now()) / 1e3;
      const [unit, size] = RELATIVE_UNITS.find(([, size2]) => Math.abs(seconds) >= size2) || ["second", 1];
      return new Intl.RelativeTimeFormat(locale, { numeric: "auto" }).format(Math.round(seconds / size), unit);
    } catch (_error) {
      return date.toISOString();
    }
  }
  function formatCell(value, locale) {
    if (value === null) return "";
    if (typeof value === "number") return formatNumber(value, "plain", null, locale);
    return String(value);
  }
  var TONE_COLORS = `
  --cyfr-bg: #f6f7f9; --cyfr-fg: #15181d; --cyfr-muted: #4f5866; --cyfr-line: #d5dae1;
  --cyfr-panel: #ffffff; --cyfr-accent: #0b5cad; --cyfr-good: #1d6b35; --cyfr-warn: #8a5300;
  --cyfr-bad: #b0242c; --cyfr-on-strong: #ffffff;
  --cyfr-series-0: #0b5cad; --cyfr-series-1: #b0242c; --cyfr-series-2: #1d6b35; --cyfr-series-3: #8a5300;
  --cyfr-series-4: #6b3fa0; --cyfr-series-5: #00727a; --cyfr-series-6: #a3366d; --cyfr-series-7: #4f5866;`;
  var DARK_COLORS = `
  --cyfr-bg: #111418; --cyfr-fg: #eef1f5; --cyfr-muted: #aab3c0; --cyfr-line: #2e353f;
  --cyfr-panel: #1a1f26; --cyfr-accent: #7cb7f2; --cyfr-good: #7dd39a; --cyfr-warn: #f0bc63;
  --cyfr-bad: #f59298; --cyfr-on-strong: #111418;
  --cyfr-series-0: #7cb7f2; --cyfr-series-1: #f59298; --cyfr-series-2: #7dd39a; --cyfr-series-3: #f0bc63;
  --cyfr-series-4: #c3a3ec; --cyfr-series-5: #6fd3da; --cyfr-series-6: #ee9cc4; --cyfr-series-7: #aab3c0;`;
  var range = (n) => Array.from({ length: n }, (_, i) => i);
  var STYLESHEET = `
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
`;

  // js/toolkit/wire.js
  var VERSION2 = 1;
  var TO_PRISM_VERBS = Object.freeze(["ready", "tree", "open", "press", "failed"]);
  var TO_TOOLKIT_VERBS = Object.freeze(["boot", "posture", "covered", "installed", "state"]);
  var TOOLKIT_MAJORS = Object.freeze([1]);
  var MODES = ["live", "validation"];
  var STAGES = ["load", "tree", "runtime"];
  var POSTURES = ["desk", "hand"];
  var STATES = ["live", "frozen"];
  var MAX_RECTS = 64;
  var RECT_KEYS = ["height", "width", "x", "y"];
  var MAX_TINCTURES = 512;
  var MAX_NAME = 128;
  var MAX_STREAMS = 64;
  var DATA_PREFIX = "/_f/v1/o/";
  var ASSET_PREFIX = "_s";
  var ASSET_CREDENTIAL = /^[A-Za-z0-9_-][A-Za-z0-9_.-]{15,1023}$/;
  var NAME = /^[a-z0-9][a-z0-9-]{0,47}$/;
  var BINDING_ID = /^feed_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  var STREAM_NAME = /^[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+$/;
  var SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?$/;
  var ELIXIR_SPACE = "[\\t\\n\\v\\f\\r \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]";
  var TRIM = new RegExp(`^${ELIXIR_SPACE}+|${ELIXIR_SPACE}+$`, "g");
  var TYPE_PREFIXES = ["catalyst", "reagent", "formula", "tincture", "agent", "c", "r", "f", "t"];
  var LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
  var CONTROL = /[\u0000-\u001F\u007F-\u009F]/;
  var CANONICAL_SEGMENT = /^(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+$/;
  var UNRESERVED_BYTE = /^[A-Za-z0-9._~-]$/;
  var isPlainObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value) && Object.prototype.toString.call(value) === "[object Object]";
  var has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  var isText = (value) => typeof value === "string" && !LONE_SURROGATE.test(value);
  var codePoints = (value) => Array.from(value).length;
  var isLabel = (value, min, max) => isText(value) && !CONTROL.test(value) && codePoints(value) >= min && codePoints(value) <= max;
  var isCredential = (value) => typeof value === "string" && ASSET_CREDENTIAL.test(value);
  var isName = (value) => typeof value === "string" && NAME.test(value);
  var isBindingId = (value) => typeof value === "string" && BINDING_ID.test(value);
  var isStreamName = (value) => typeof value === "string" && STREAM_NAME.test(value);
  function isTinctureRef(ref) {
    if (!isText(ref)) return false;
    const trimmed = ref.replace(TRIM, "");
    const colon = trimmed.indexOf(":");
    if (trimmed === "" || colon === -1) return false;
    const prefix = trimmed.slice(0, colon);
    if (prefix.includes(".") || !TYPE_PREFIXES.includes(prefix)) return false;
    if (prefix !== "t" && prefix !== "tincture") return false;
    const remainder = trimmed.slice(colon + 1);
    const last = remainder.lastIndexOf(":");
    const nsName = last === -1 ? remainder : remainder.slice(0, last);
    const version = last === -1 || last === remainder.length - 1 ? null : remainder.slice(last + 1);
    if (version === "latest") return false;
    if (version !== null && !SEMVER.test(version)) return false;
    const dot = nsName.lastIndexOf(".");
    return dot > 0 && dot < nsName.length - 1;
  }
  function assetPath(path) {
    if (typeof path !== "string" || !path.startsWith("/")) return null;
    const parts = path.slice(1).split("/");
    if (parts.length < 3 || parts[0] !== ASSET_PREFIX || !isCredential(parts[1])) return null;
    const segments = parts.slice(2);
    return segments.every(canonicalSegment) ? { credential: parts[1], segments } : null;
  }
  function canonicalSegment(segment) {
    if (!CANONICAL_SEGMENT.test(segment) || segment === "." || segment === "..") return false;
    for (const [, hex] of segment.matchAll(/%([0-9A-F]{2})/g)) {
      const byte = parseInt(hex, 16);
      if (UNRESERVED_BYTE.test(String.fromCharCode(byte))) return false;
      if (byte === 47 || byte === 92 || byte === 0) return false;
    }
    return true;
  }
  function isModuleUrl(url) {
    const path = assetPath(url);
    if (path === null) return false;
    const file = path.segments[path.segments.length - 1];
    return file.endsWith(".js") || file.endsWith(".mjs");
  }
  function servedPrefix(moduleUrl) {
    const path = assetPath(moduleUrl);
    if (path === null) throw new TypeError("not a served module path");
    return `/${ASSET_PREFIX}/${path.credential}/`;
  }
  function dataPath(frame) {
    return DATA_PREFIX + frameOf(frame) + "/";
  }
  function frameOf(frame) {
    if (!isFrameId(frame)) throw new TypeError("a frame id is 8 to 64 URL-safe characters");
    return frame;
  }
  function decode(message) {
    if (!isPlainObject(message)) return refuse("the message must be an object");
    const error = exact(message, ["args", "frame", "v", "verb"], "the message") || (message.v === VERSION2 ? null : `the message carries no wire version ${VERSION2}`) || (verbOf(message.verb) ? null : "verb must be one of " + verbs().join(", ")) || (isFrameId(message.frame) ? null : "frame must be a frame id") || (isPlainObject(message.args) ? null : "args must be an object") || argsError(message.verb, message.args, message.frame);
    return error === null ? { ok: true, message: { verb: message.verb, frame: message.frame, args: message.args } } : refuse(error);
  }
  function encode(verb, frame, args) {
    const envelope = { v: VERSION2, verb, frame, args };
    const decoded = decode(envelope);
    if (!decoded.ok) throw new TypeError("not a canvas wire message: " + decoded.error);
    return envelope;
  }
  function bootStreamsRefused(message, frame) {
    if (!isPlainObject(message) || message.verb !== "boot" || message.frame !== frame) return false;
    if (!isPlainObject(message.args) || decode(message).ok) return false;
    const args = { ...message.args, streams: [] };
    return decode({ ...message, args }).ok;
  }
  var refuse = (error) => ({ ok: false, error });
  var verbs = () => [...TO_PRISM_VERBS, ...TO_TOOLKIT_VERBS];
  var verbOf = (verb) => typeof verb === "string" && verbs().includes(verb);
  function argsError(verb, args, frame) {
    switch (verb) {
      case "ready":
      case "tree":
        return exact(args, [], verb);
      case "open":
        return exact(args, ["ref"], "open") || check(isTinctureRef(args.ref), "open names a tincture reference");
      case "press":
        return exact(args, ["action", "binding"], "press") || check(isBindingId(args.binding), "press names a binding id") || check(isName(args.action), "press names an action by its name");
      case "failed":
        return exact(args, ["stage"], "failed") || check(STAGES.includes(args.stage), "failed names a stage");
      case "boot":
        return exact(args, ["credential", "data_path", "mode", "module_url", "streams", "toolkit"], "boot") || check(MODES.includes(args.mode), "boot's mode is live or validation") || check(typeof args.credential === "string" && args.credential !== "", "boot carries the frame credential") || check(args.data_path === dataPath(frame), "boot's data path is its frame's") || check(isModuleUrl(args.module_url), "boot's module is a served .js or .mjs") || check(Number.isInteger(args.toolkit) && args.toolkit > 0, "boot's toolkit is a major, a positive integer") || check(isStreams(args.streams), `boot names at most ${MAX_STREAMS} distinct streams of name and subject`);
      case "posture":
        return exact(args, ["posture"], "posture") || check(POSTURES.includes(args.posture), "posture is desk or hand");
      case "covered":
        return exact(args, ["rects"], "covered") || check(bounded(args.rects, MAX_RECTS, isRect), "covered names at most 64 rects of x, y, width and height");
      case "installed":
        return exact(args, ["tinctures"], "installed") || check(bounded(args.tinctures, MAX_TINCTURES, isInstalled), "installed names at most 512 tinctures of ref and name");
      case "state":
        return exact(args, ["state"], "state") || check(STATES.includes(args.state), "state is live or frozen");
      default:
        return "unknown verb";
    }
  }
  var check = (ok, sentence) => ok ? null : sentence;
  var bounded = (list, max, each) => Array.isArray(list) && list.length <= max && list.every(each);
  var isRect = (rect) => isPlainObject(rect) && sameKeys(rect, RECT_KEYS) && RECT_KEYS.every((key) => typeof rect[key] === "number" && Number.isFinite(rect[key]) && rect[key] >= 0);
  var isInstalled = (tincture) => isPlainObject(tincture) && sameKeys(tincture, ["name", "ref"]) && isTinctureRef(tincture.ref) && isText(tincture.name) && codePoints(tincture.name) >= 1 && codePoints(tincture.name) <= MAX_NAME;
  function isStreams(streams) {
    if (!bounded(streams, MAX_STREAMS, isStream)) return false;
    const pairs = new Set(streams.map(pairKey));
    return pairs.size === streams.length;
  }
  var isStream = (stream) => isPlainObject(stream) && sameKeys(stream, ["name", "subject"]) && isStreamName(stream.name) && (stream.subject === null || isText(stream.subject));
  var pairKey = ({ name, subject }) => JSON.stringify([name, subject]);
  var sameKeys = (object, keys) => {
    const present = Object.keys(object).sort();
    return present.length === keys.length && present.every((key, i) => key === keys[i]);
  };
  function exact(object, keys, where) {
    const present = Object.keys(object);
    const extra = present.filter((key) => !keys.includes(key));
    const missing = keys.filter((key) => !has(object, key));
    if (extra.length > 0) return `${where} carries an unknown key`;
    if (missing.length > 0) return `${where} lacks ${missing.join(", ")}`;
    return null;
  }
  var ROLES = Object.freeze({ module: "cyfr-toolkit-module", streams: "cyfr-toolkit-streams" });
  var MODULE_KINDS = ["posture", "covered", "installed"];
  var ON_KINDS = Object.freeze([...MODULE_KINDS]);
  var toModule = Object.freeze({
    boot: (mode, moduleUrl, port) => ({ t: "boot", mode, module_url: moduleUrl, port }),
    value: (kind, value) => ({ t: kind, value }),
    surface: (id, canvas) => ({ t: "surface", id, canvas }),
    stream: (m) => ({ t: "stream", m })
  });
  var toStreams = Object.freeze({
    boot: (credential, dataUrl, streams, port) => ({ t: "boot", credential, data_url: dataUrl, streams, port })
  });
  var fromModule = Object.freeze({
    tree: (json) => ({ t: "tree", json }),
    failed: (stage) => ({ t: "failed", stage })
  });
  function decodeFromModule(data) {
    if (!isPlainObject(data)) return null;
    if (data.t === "tree" && sameKeys(data, ["json", "t"]) && (data.json === null || typeof data.json === "string")) {
      return { kind: "tree", json: data.json };
    }
    if (data.t === "failed" && sameKeys(data, ["stage", "t"]) && (data.stage === "load" || data.stage === "runtime")) {
      return { kind: "failed", stage: data.stage };
    }
    return null;
  }
  var fromStreams = Object.freeze({
    relay: (m, record = null) => ({ t: "relay", m, record }),
    lost: () => ({ t: "lost" })
  });
  function decodeFromStreams(data) {
    if (!isPlainObject(data)) return null;
    if (data.t === "lost" && sameKeys(data, ["t"])) return { kind: "lost" };
    if (data.t !== "relay" || !sameKeys(data, ["m", "record", "t"]) || decodeAnswer(data.m) === null) return null;
    if (data.record === null) return { kind: "relay", m: data.m, record: null };
    const record = decodeRecord(data.record);
    return record === null ? null : { kind: "relay", m: data.m, record };
  }
  var request = Object.freeze({
    open: (sub, name, subject) => ({ t: "open", sub, name, subject }),
    close: (sub) => ({ t: "close", sub })
  });
  var isSub = (sub) => Number.isSafeInteger(sub) && sub >= 0;
  var answer = Object.freeze({
    opened: (sub) => ({ t: "opened", sub }),
    refused: (sub, code, message, stage = null) => ({ t: "refused", sub, code, message, stage }),
    event: (sub, event) => ({ t: "event", sub, event }),
    closed: (sub, error = null) => ({ t: "closed", sub, error })
  });
  function decodeAnswer(data) {
    if (!isPlainObject(data) || !isSub(data.sub)) return null;
    switch (data.t) {
      case "opened":
        return sameKeys(data, ["sub", "t"]) ? data : null;
      case "refused":
        return sameKeys(data, ["code", "message", "stage", "sub", "t"]) && typeof data.code === "string" && typeof data.message === "string" && (data.stage === null || typeof data.stage === "string") ? data : null;
      case "event":
        return sameKeys(data, ["event", "sub", "t"]) && isPlainObject(data.event) ? data : null;
      case "closed":
        return sameKeys(data, ["error", "sub", "t"]) && (data.error === null || typeof data.error === "string") ? data : null;
      default:
        return null;
    }
  }
  var MAX_ACTIONS = 8;
  var BINDING_LABEL_MAX = 80;
  var ACTION_LABEL_MAX = 40;
  function decodeRecord(record) {
    if (!isPlainObject(record) || !sameKeys(record, ["actions", "binding", "feed", "label", "revision"])) return null;
    const { feed, binding, revision, label, actions } = record;
    if (!isName(feed) || !isBindingId(binding)) return null;
    if (!Number.isSafeInteger(revision) || revision < 0) return null;
    if (!isLabel(label, 1, BINDING_LABEL_MAX)) return null;
    if (!Array.isArray(actions) || actions.length > MAX_ACTIONS) return null;
    const names = /* @__PURE__ */ new Set();
    const read = [];
    for (const action of actions) {
      if (!isPlainObject(action) || !isName(action.name) || names.has(action.name)) return null;
      if (!isLabel(action.label, 1, ACTION_LABEL_MAX)) return null;
      names.add(action.name);
      read.push({ name: action.name, label: action.label });
    }
    return { feed, binding, revision, label, actions: read };
  }
  var replacesRecord = (stored, next) => !stored || stored.binding !== next.binding || next.revision > stored.revision;

  // js/toolkit/tree.js
  var MAX_NODES = 2e3;
  var MAX_DEPTH = 24;
  var MAX_BYTES = 1048576;
  var TONES = Object.freeze(["plain", "muted", "accent", "good", "warn", "bad"]);
  var SIZES = Object.freeze(["s", "m", "l", "xl"]);
  var GAPS = Object.freeze(["none", "s", "m", "l"]);
  var DIRECTIONS = Object.freeze(["row", "column"]);
  var WEIGHTS = Object.freeze(["normal", "strong"]);
  var TIME_FORMATS = Object.freeze(["relative", "date", "datetime"]);
  var CHART_KINDS = Object.freeze(["line", "bar", "candle"]);
  var MAX_TEXT = 4096;
  var MAX_LIST_ITEMS = 500;
  var MAX_COLUMNS = 16;
  var MAX_COLUMN_KEY = 64;
  var MAX_COLUMN_TITLE = 256;
  var MAX_ROWS = 500;
  var MAX_ROW_KEYS = 64;
  var MAX_CELL = 1024;
  var MAX_SERIES = 8;
  var MAX_SERIES_NAME = 128;
  var MAX_POINTS = 2e3;
  var MAX_X_TEXT = 64;
  var MAX_PATH = 1024;
  var MAX_DATA_URL = 262144;
  var MAX_ALT = 256;
  var MAX_GRID_COLUMNS = 12;
  var MAX_DIGITS = 8;
  var MAX_SURFACE_SIDE = 4096;
  var NUMBER_FORMAT = /^(plain|percent|compact|currency:[A-Z]{3})$/;
  var PATH_SEGMENT = /^[A-Za-z0-9._~-]+$/;
  var DATA_URL = /^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]*={0,2}$/;
  var TIME = /^([+-]?)(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?(Z|[+-]\d{2}(?::\d{2}|\d{2})?)$/;
  var RULES = {
    stack: { required: ["children"], optional: { direction: "column", gap: "m" } },
    grid: { required: ["columns", "children"], optional: { gap: "m" } },
    text: { required: ["value"], optional: { tone: "plain", size: "m", weight: "normal" } },
    number: { required: ["value"], optional: { format: "plain", digits: null, tone: "plain", size: "m" } },
    time: { required: ["value"], optional: { format: "datetime" } },
    list: { required: ["items"], optional: {} },
    table: { required: ["columns", "rows"], optional: {} },
    chart: { required: ["kind", "series"], optional: {} },
    image: { required: ["src", "alt"], optional: {} },
    control: { required: ["effect"], optional: { tone: "plain", size: "m" } },
    surface: { required: ["id", "width", "height"], optional: {} },
    spacer: { required: [], optional: {} }
  };
  var GRAMMAR_ELEMENTS = Object.freeze(Object.keys(RULES));
  var Refusal = class {
    constructor(path, reason) {
      this.path = path;
      this.reason = reason;
    }
  };
  var refuse2 = (path, reason) => {
    throw new Refusal(path, reason);
  };
  var own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  var pointer = (path, key) => path + "/" + String(key).replace(/~/g, "~0").replace(/\//g, "~1");
  function parseTree(json) {
    if (typeof json !== "string") return { ok: false, error: { path: "", reason: "json" } };
    if (json.length > MAX_BYTES || utf8Length(json) > MAX_BYTES) {
      return { ok: false, error: { path: "", reason: "size" } };
    }
    let value;
    try {
      value = JSON.parse(json);
    } catch (_error) {
      return { ok: false, error: { path: "", reason: "json" } };
    }
    return validateTree(value);
  }
  function validateTree(value) {
    const state = { nodes: 0, surfaces: [] };
    try {
      const tree = node(value, "", 1, state);
      return { ok: true, tree, surfaces: state.surfaces };
    } catch (error) {
      if (error instanceof Refusal) return { ok: false, error: { path: error.path, reason: error.reason } };
      throw error;
    }
  }
  function node(value, path, depth, state) {
    if (depth > MAX_DEPTH) refuse2(path, "depth");
    state.nodes += 1;
    if (state.nodes > MAX_NODES) refuse2(path, "nodes");
    if (!isPlainObject(value)) refuse2(path, "node");
    const type = value.type;
    if (typeof type !== "string" || !ELEMENTS.includes(type) || !own(RULES, type)) {
      refuse2(pointer(path, "type"), "element");
    }
    const rule = RULES[type];
    for (const key of Object.keys(value)) {
      if (key !== "type" && !rule.required.includes(key) && !own(rule.optional, key)) refuse2(pointer(path, key), "field");
    }
    for (const key of rule.required) {
      if (!own(value, key)) refuse2(pointer(path, key), "required");
    }
    const normal = { type };
    for (const [key, fallback] of Object.entries(rule.optional)) {
      if (own(value, key) && value[key] === null) refuse2(pointer(path, key), "value");
      normal[key] = own(value, key) ? value[key] : fallback;
    }
    for (const key of rule.required) normal[key] = value[key];
    READERS[type](normal, path, depth, state);
    return normal;
  }
  var at = (path, key) => pointer(path, key);
  var oneOf = (node2, key, values, path) => {
    if (!values.includes(node2[key])) refuse2(at(path, key), "value");
  };
  var textOf = (value, max, path, min = 0) => {
    if (!isText(value)) refuse2(path, "value");
    const length = codePoints(value);
    if (length < min || length > max) refuse2(path, "value");
  };
  var finite = (value, path) => {
    if (typeof value !== "number" || !Number.isFinite(value)) refuse2(path, "value");
  };
  var integerIn = (value, min, max, path) => {
    if (!Number.isInteger(value) || value < min || value > max) refuse2(path, "value");
  };
  var children = (list, path, depth, state, max = Infinity) => {
    if (!Array.isArray(list) || list.length > max) refuse2(path, "value");
    return list.map((child, i) => node(child, pointer(path, i), depth + 1, state));
  };
  var READERS = {
    stack(n, path, depth, state) {
      oneOf(n, "direction", DIRECTIONS, path);
      oneOf(n, "gap", GAPS, path);
      n.children = children(n.children, at(path, "children"), depth, state);
    },
    grid(n, path, depth, state) {
      integerIn(n.columns, 1, MAX_GRID_COLUMNS, at(path, "columns"));
      oneOf(n, "gap", GAPS, path);
      n.children = children(n.children, at(path, "children"), depth, state);
    },
    text(n, path) {
      textOf(n.value, MAX_TEXT, at(path, "value"));
      oneOf(n, "tone", TONES, path);
      oneOf(n, "size", SIZES, path);
      oneOf(n, "weight", WEIGHTS, path);
    },
    number(n, path) {
      finite(n.value, at(path, "value"));
      if (typeof n.format !== "string" || !NUMBER_FORMAT.test(n.format)) refuse2(at(path, "format"), "value");
      if (n.digits !== null) integerIn(n.digits, 0, MAX_DIGITS, at(path, "digits"));
      oneOf(n, "tone", TONES, path);
      oneOf(n, "size", SIZES, path);
    },
    time(n, path) {
      if (parseTime(n.value) === null) refuse2(at(path, "value"), "value");
      oneOf(n, "format", TIME_FORMATS, path);
    },
    list(n, path, depth, state) {
      n.items = children(n.items, at(path, "items"), depth, state, MAX_LIST_ITEMS);
    },
    table(n, path) {
      const columnsPath = at(path, "columns");
      if (!Array.isArray(n.columns) || n.columns.length < 1 || n.columns.length > MAX_COLUMNS) {
        refuse2(columnsPath, "value");
      }
      const keys = /* @__PURE__ */ new Set();
      n.columns = n.columns.map((column, i) => {
        const columnPath = pointer(columnsPath, i);
        exactly(column, ["key", "title"], columnPath);
        textOf(column.key, MAX_COLUMN_KEY, at(columnPath, "key"), 1);
        textOf(column.title, MAX_COLUMN_TITLE, at(columnPath, "title"));
        if (keys.has(column.key)) refuse2(at(columnPath, "key"), "value");
        keys.add(column.key);
        return { key: column.key, title: column.title };
      });
      const rowsPath = at(path, "rows");
      if (!Array.isArray(n.rows) || n.rows.length > MAX_ROWS) refuse2(rowsPath, "value");
      n.rows = n.rows.map((row, i) => {
        const rowPath = pointer(rowsPath, i);
        if (!isPlainObject(row) || Object.keys(row).length > MAX_ROW_KEYS) refuse2(rowPath, "value");
        for (const [key, cell] of Object.entries(row)) scalar(cell, pointer(rowPath, key));
        return row;
      });
    },
    chart(n, path) {
      oneOf(n, "kind", CHART_KINDS, path);
      const seriesPath = at(path, "series");
      if (!Array.isArray(n.series) || n.series.length < 1 || n.series.length > MAX_SERIES) refuse2(seriesPath, "value");
      n.series = n.series.map((series, i) => {
        const onePath = pointer(seriesPath, i);
        exactly(series, ["name", "points"], onePath);
        textOf(series.name, MAX_SERIES_NAME, at(onePath, "name"), 1);
        const pointsPath = at(onePath, "points");
        if (!Array.isArray(series.points) || series.points.length > MAX_POINTS) refuse2(pointsPath, "value");
        const points = series.points.map(
          (point, j) => n.kind === "candle" ? candle(point, pointer(pointsPath, j)) : xy(point, pointer(pointsPath, j))
        );
        return { name: series.name, points };
      });
    },
    image(n, path) {
      if (!isImageSource(n.src)) refuse2(at(path, "src"), "value");
      textOf(n.alt, MAX_ALT, at(path, "alt"));
    },
    control(n, path) {
      n.effect = effect(n.effect, at(path, "effect"));
      oneOf(n, "tone", TONES, path);
      oneOf(n, "size", SIZES, path);
    },
    surface(n, path, _depth, state) {
      if (!isName(n.id) || state.surfaces.includes(n.id)) refuse2(at(path, "id"), "value");
      integerIn(n.width, 1, MAX_SURFACE_SIDE, at(path, "width"));
      integerIn(n.height, 1, MAX_SURFACE_SIDE, at(path, "height"));
      state.surfaces.push(n.id);
    },
    spacer() {
    }
  };
  function exactly(value, keys, path) {
    if (!isPlainObject(value)) refuse2(path, "value");
    for (const key of Object.keys(value)) if (!keys.includes(key)) refuse2(pointer(path, key), "field");
    for (const key of keys) if (!own(value, key)) refuse2(pointer(path, key), "required");
  }
  function scalar(value, path) {
    if (value === null || typeof value === "boolean") return;
    if (typeof value === "number") return finite(value, path);
    textOf(value, MAX_CELL, path);
  }
  function xy(point, path) {
    exactly(point, ["x", "y"], path);
    if (typeof point.x === "number") finite(point.x, at(path, "x"));
    else textOf(point.x, MAX_X_TEXT, at(path, "x"));
    finite(point.y, at(path, "y"));
    return { x: point.x, y: point.y };
  }
  function candle(point, path) {
    exactly(point, ["c", "h", "l", "o", "t"], path);
    if (typeof point.t === "number") finite(point.t, at(path, "t"));
    else if (parseTime(point.t) === null) refuse2(at(path, "t"), "value");
    for (const key of ["o", "h", "l", "c"]) finite(point[key], at(path, key));
    return { t: point.t, o: point.o, h: point.h, l: point.l, c: point.c };
  }
  function effect(value, path) {
    if (!isPlainObject(value)) refuse2(path, "value");
    for (const key of Object.keys(value)) if (key !== "open" && key !== "press") refuse2(pointer(path, key), "field");
    if (Object.keys(value).length !== 1) refuse2(path, "value");
    if (own(value, "open")) {
      if (!isTinctureRef(value.open)) refuse2(at(path, "open"), "value");
      return { open: value.open };
    }
    const pressPath = at(path, "press");
    exactly(value.press, ["action", "feed"], pressPath);
    if (!isName(value.press.feed)) refuse2(at(pressPath, "feed"), "value");
    if (!isName(value.press.action)) refuse2(at(pressPath, "action"), "value");
    return { press: { feed: value.press.feed, action: value.press.action } };
  }
  function isImageSource(src) {
    if (typeof src !== "string") return false;
    if (src.startsWith("data:")) return src.length <= MAX_DATA_URL && DATA_URL.test(src);
    if (src.length < 1 || src.length > MAX_PATH) return false;
    return src.split("/").every((segment) => PATH_SEGMENT.test(segment) && segment !== "." && segment !== "..");
  }
  function parseTime(value) {
    if (typeof value !== "string") return null;
    const match = TIME.exec(value);
    if (match === null) return null;
    const [, sign, y, mo, d, h, mi, s, fraction, offset] = match;
    const year = Number(y) * (sign === "-" ? -1 : 1);
    const month = Number(mo);
    const day = Number(d);
    const hour = Number(h);
    const minute = Number(mi);
    const second = Number(s);
    if (month < 1 || month > 12 || day < 1 || day > daysIn(year, month)) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;
    let offsetMinutes = 0;
    if (offset !== "Z") {
      if (offset === "-00:00") return null;
      const hours = Number(offset.slice(1, 3));
      const minutes = offset.length > 3 ? Number(offset.slice(-2)) : 0;
      if (hours > 23 || minutes > 59) return null;
      offsetMinutes = (offset[0] === "-" ? -1 : 1) * (hours * 60 + minutes);
    }
    const millis = fraction ? Number((fraction + "00").slice(0, 3)) : 0;
    const date = /* @__PURE__ */ new Date(0);
    date.setUTCFullYear(year, month - 1, day);
    date.setUTCHours(hour, minute, second, millis);
    return date.getTime() - offsetMinutes * 6e4;
  }
  var leap = (year) => year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  function daysIn(year, month) {
    if (month === 2) return leap(year) ? 29 : 28;
    return [4, 6, 9, 11].includes(month) ? 30 : 31;
  }
  function utf8Length(text) {
    let bytes = 0;
    for (let i = 0; i < text.length; i++) {
      const unit = text.charCodeAt(i);
      if (unit < 128) bytes += 1;
      else if (unit < 2048) bytes += 2;
      else if (unit >= 55296 && unit <= 56319 && i + 1 < text.length) {
        const next = text.charCodeAt(i + 1);
        if (next >= 56320 && next <= 57343) {
          bytes += 4;
          i += 1;
        } else {
          bytes += 3;
        }
      } else bytes += 3;
    }
    return bytes;
  }

  // js/toolkit/host.js
  var WORKER_ELEMENT_ID = "cyfr-toolkit-worker";
  function createHost(env) {
    const { window: win, document: doc, Worker: Worker2, Blob: Blob2, URL: URL2, MessageChannel: MessageChannel2 } = env;
    const schedule = env.schedule;
    const now = env.now || (() => Date.now());
    let frame = null;
    let port = null;
    let boot = null;
    let bootAccepted = false;
    let failed = false;
    let frozen = false;
    let readyPosted = false;
    let decided = false;
    let blobUrl = null;
    let root = null;
    let generation = 0;
    let current = null;
    const values = {};
    let installed = [];
    let records = /* @__PURE__ */ new Map();
    let pending = null;
    let scheduled = false;
    const surfaces = /* @__PURE__ */ new Map();
    const controls = createControls({ doc, dispatch });
    function onWindowMessage(event) {
      const framed = win.parent !== win && win.parent !== null && win.parent !== void 0;
      if (!framed || port !== null || event.source !== win.parent) return;
      const data = event.data;
      if (!isPlainObject(data) || data.v !== VERSION || data.type !== HANDSHAKE) return;
      if (!isFrameId(data.frame) || !event.ports || event.ports.length !== 1) return;
      frame = data.frame;
      port = event.ports[0];
      win.removeEventListener("message", onWindowMessage);
      port.onmessage = onPortMessage;
    }
    function onPortMessage(event) {
      if (failed) return;
      const decoded = decode(event.data);
      if (!decoded.ok) {
        if (!bootAccepted && bootStreamsRefused(event.data, frame)) {
          bootAccepted = true;
          fail("load");
        }
        return;
      }
      const { verb, frame: to, args } = decoded.message;
      if (to !== frame || !TO_TOOLKIT_VERBS.includes(verb)) return;
      if (!bootAccepted) {
        if (verb === "boot") start(args);
        return;
      }
      switch (verb) {
        case "posture":
          return value("posture", args.posture);
        case "covered":
          return value("covered", args.rects);
        case "installed":
          return value("installed", args.tinctures);
        case "state":
          return args.state === "frozen" ? freeze() : thaw();
        default:
          return;
      }
    }
    function post(verb, args) {
      port.postMessage(encode(verb, frame, args));
    }
    function start(args) {
      bootAccepted = true;
      if (!TOOLKIT_MAJORS.includes(args.toolkit)) return fail("load");
      let source;
      try {
        source = workerSource();
      } catch (_error) {
        return fail("load");
      }
      boot = {
        mode: args.mode,
        credential: args.credential,
        dataUrl: new URL2(args.data_path, doc.URL).href,
        moduleUrl: new URL2(args.module_url, doc.URL).href,
        prefixUrl: new URL2(servedPrefix(args.module_url), doc.URL).href,
        streams: args.streams
      };
      mount();
      try {
        blobUrl = URL2.createObjectURL(new Blob2([source], { type: "text/javascript" }));
      } catch (_error) {
        return fail("load");
      }
      startWorkers();
    }
    function workerSource() {
      const element2 = doc.getElementById(WORKER_ELEMENT_ID);
      if (!element2 || element2.tagName !== "SCRIPT" || element2.getAttribute("type") !== "application/json") {
        throw new Error("no worker bundle");
      }
      const source = JSON.parse(element2.textContent);
      if (typeof source !== "string") throw new Error("no worker bundle");
      return source;
    }
    function mount() {
      const style = doc.createElement("style");
      if (env.nonce) style.setAttribute("nonce", env.nonce);
      style.textContent = STYLESHEET;
      (doc.head || doc.documentElement).appendChild(style);
      root = doc.createElement("div");
      root.setAttribute("class", "cyfr-canvas");
      (doc.body || doc.documentElement).appendChild(root);
    }
    function value(kind, latest) {
      values[kind] = latest;
      if (kind === "installed") installed = latest;
      if (kind === "posture") root.setAttribute("data-posture", latest);
      if (current) current.module.postMessage(toModule.value(kind, latest));
    }
    function startWorkers() {
      generation += 1;
      const gen = generation;
      const started = [];
      try {
        const channel = new MessageChannel2();
        const streams = new Worker2(blobUrl, { name: ROLES.streams });
        started.push(streams);
        const module = new Worker2(blobUrl, { name: ROLES.module });
        started.push(module);
        current = { gen, module, streams };
        streams.onmessage = (event) => onStreamsMessage(gen, event);
        streams.onerror = () => onWorkerError(gen);
        module.onmessage = (event) => onModuleMessage(gen, event);
        module.onerror = () => onWorkerError(gen);
        streams.postMessage(toStreams.boot(boot.credential, boot.dataUrl, boot.streams, channel.port1), [channel.port1]);
        module.postMessage(toModule.boot(boot.mode, boot.moduleUrl, channel.port2), [channel.port2]);
        for (const kind of ON_KINDS) {
          if (Object.prototype.hasOwnProperty.call(values, kind)) module.postMessage(toModule.value(kind, values[kind]));
        }
        renewSurfaces();
      } catch (_error) {
        current = null;
        for (const worker of started) {
          worker.onmessage = null;
          worker.onerror = null;
          try {
            worker.terminate();
          } catch (_ignored) {
          }
        }
        fail("load");
      }
    }
    function stopWorkers() {
      if (current === null) return;
      const { module, streams } = current;
      current = null;
      pending = null;
      for (const worker of [module, streams]) {
        worker.onmessage = null;
        worker.onerror = null;
        worker.terminate();
      }
    }
    const live = (gen) => current !== null && current.gen === gen;
    function onWorkerError(gen) {
      if (live(gen)) fail("runtime");
    }
    function onModuleMessage(gen, event) {
      if (!live(gen)) return;
      const message = decodeFromModule(event.data);
      if (message === null) return fail("runtime");
      if (message.kind === "failed") return fail(message.stage);
      receiveTree(message.json);
    }
    function onStreamsMessage(gen, event) {
      if (!live(gen)) return;
      const message = decodeFromStreams(event.data);
      if (message === null || message.kind === "lost") return fail("runtime");
      if (message.record !== null) install(message.record);
      current.module.postMessage(toModule.stream(message.m));
    }
    function install(record) {
      if (!replacesRecord(records.get(record.feed), record)) return;
      records = new Map(records);
      records.set(record.feed, record);
    }
    function freeze() {
      if (frozen) return;
      frozen = true;
      stopWorkers();
    }
    function thaw() {
      if (!frozen) return;
      frozen = false;
      startWorkers();
    }
    function fail(stage) {
      if (failed) return;
      failed = true;
      stopWorkers();
      controls.disableAll();
      post("failed", { stage });
    }
    function receiveTree(json) {
      const answered = { json, installed, records };
      if (boot.mode === "validation" && !decided) {
        decided = true;
        const parsed = json === null ? null : parseTree(json);
        if (parsed === null || !parsed.ok) return fail("tree");
        render(parsed, answered);
        return post("tree", {});
      }
      pending = answered;
      if (!scheduled) {
        scheduled = true;
        schedule(flush);
      }
    }
    function flush() {
      scheduled = false;
      const next = pending;
      pending = null;
      if (next === null || failed || current === null) return;
      const parsed = next.json === null ? null : parseTree(next.json);
      if (parsed === null || !parsed.ok) return;
      render(parsed, next);
      if (boot.mode === "live" && !readyPosted) {
        readyPosted = true;
        post("ready", {});
      }
    }
    function render(parsed, answered) {
      controls.reset();
      const ctx = {
        doc,
        locale: env.locale,
        timeZone: env.timeZone,
        now,
        parseTime,
        imageSource: (src) => src.startsWith("data:") ? src : new URL2(src, boot.prefixUrl).href,
        control: (node2) => controls.element(node2, resolveEffect(node2.effect, answered)),
        surface: surfaceElement
      };
      const drawn = draw(parsed.tree, ctx);
      for (const id of [...surfaces.keys()]) if (!parsed.surfaces.includes(id)) surfaces.delete(id);
      root.replaceChildren(drawn);
    }
    function surfaceElement(node2) {
      const kept = surfaces.get(node2.id);
      if (kept && kept.width === node2.width && kept.height === node2.height) return kept.element;
      const element2 = newSurface(node2.width, node2.height);
      surfaces.set(node2.id, { element: element2, width: node2.width, height: node2.height });
      transfer(node2.id, element2);
      return element2;
    }
    function newSurface(width, height) {
      const element2 = doc.createElement("canvas");
      element2.setAttribute("class", "cyfr-surface");
      element2.setAttribute("width", String(width));
      element2.setAttribute("height", String(height));
      return element2;
    }
    function transfer(id, element2) {
      if (current === null || typeof element2.transferControlToOffscreen !== "function") return;
      let offscreen;
      try {
        offscreen = element2.transferControlToOffscreen();
      } catch (_error) {
        return;
      }
      current.module.postMessage(toModule.surface(id, offscreen), [offscreen]);
    }
    function renewSurfaces() {
      for (const [id, kept] of [...surfaces.entries()]) {
        const element2 = newSurface(kept.width, kept.height);
        if (kept.element.parentNode) kept.element.parentNode.replaceChild(element2, kept.element);
        surfaces.set(id, { element: element2, width: kept.width, height: kept.height });
        transfer(id, element2);
      }
    }
    function dispatch(resolved) {
      if (failed || frozen || current === null || port === null) return;
      if (resolved.kind === "open") post("open", { ref: resolved.ref });
      else post("press", { binding: resolved.binding, action: resolved.action });
    }
    win.addEventListener("message", onWindowMessage);
    return { onWindowMessage };
  }
  if (typeof window === "object" && window !== null && typeof document === "object" && window.document === document) {
    const script = document.currentScript;
    createHost({
      window,
      document,
      Worker,
      Blob,
      URL,
      MessageChannel,
      nonce: script ? script.nonce : "",
      schedule: (callback) => {
        let done = false;
        const run = () => {
          if (done) return;
          done = true;
          callback();
        };
        window.requestAnimationFrame(run);
        window.setTimeout(run, 250);
      }
    });
  }
})();
