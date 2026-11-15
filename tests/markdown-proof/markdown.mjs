// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The console's markdown hook (apps/cyfr/assets/js/hooks/markdown_content.js)
// mounted in Chromium on a page of its own, with the vendored marked,
// highlight.js and DOMPurify it imports: what a message's markdown becomes
// in the page, after the sanitizer. Each case sets the element's
// data-raw-content and runs the hook's mounted or updated callback, as
// LiveView does, and compares the element's innerHTML with the expected
// markup exactly; a case with a base names it on the element as
// data-link-base, as Legal does, and one without removes it. A render the hook catches and logs fails the run, as does
// any console error. Writes markdown.json to /out and exits non-zero on a
// mismatch.

import { readFileSync, writeFileSync } from "node:fs";
import { chromium } from "../browser/lib.mjs";

const ORIGIN = "http://markdown.test";
// The account service's address, as a legal page's element names it.
const BASE = "https://cyfr.run";
const ASSETS = "/assets";
// The hook and the vendored modules it imports; nothing else is served.
const SERVED = /^\/(js\/hooks|vendor)\/[\w.-]+\.(m?js)$/;

const PAGE = `<!doctype html>
<meta charset="utf-8">
<div id="message"></div>
<script type="module">
  import MarkdownContent from "/js/hooks/markdown_content.js";
  const el = document.getElementById("message");
  const hook = Object.assign(Object.create(MarkdownContent), {el});
  let mounted = false;
  window.render = (raw, base) => {
    if (base) el.setAttribute("data-link-base", base); else el.removeAttribute("data-link-base");
    el.setAttribute("data-raw-content", raw);
    if (mounted) hook.updated(); else { mounted = true; hook.mounted(); }
    return el.innerHTML;
  };
  // An image's error, seen before any handler on the image runs.
  document.addEventListener("error", (event) => {
    if (event.target.tagName === "IMG") window.imageErrors = (window.imageErrors || 0) + 1;
  }, true);
  window.ready = true;
</script>`;

const CASES = [
  ["a list", "- one\n- two\n- three",
    "<ul>\n<li>one</li>\n<li>two</li>\n<li>three</li>\n</ul>\n"],
  ["a nested list", "- outer\n  - inner a\n  - inner b\n- after",
    "<ul>\n<li>outer<ul>\n<li>inner a</li>\n<li>inner b</li>\n</ul>\n</li>\n<li>after</li>\n</ul>\n"],
  ["paragraphs, a single newline kept as a break", "first line\nsecond line\n\nnext paragraph",
    "<p>first line<br>second line</p>\n<p>next paragraph</p>\n"],
  ["task items, their checkbox inputs removed", "- [ ] todo\n- [x] done\n- plain",
    "<ul>\n<li> todo</li>\n<li> done</li>\n<li>plain</li>\n</ul>\n"],
  ["loose task items, their checkbox inputs removed", "- [ ] todo\n\n- [x] done",
    "<ul>\n<li><p> todo</p>\n</li>\n<li><p> done</p>\n</li>\n</ul>\n"],
  ["nested task items, their checkbox inputs removed", "- [ ] parent\n  - [x] child",
    "<ul>\n<li> parent<ul>\n<li> child</li>\n</ul>\n</li>\n</ul>\n"],
  ["trailing blank lines", "text\n\n\n", "<p>text</p>\n"],
  ["a link, which opens apart", "[t](http://e.com)",
    '<p><a href="http://e.com" target="_blank" rel="noopener noreferrer">t</a></p>\n'],
  ["a script element, removed", "before\n\n<script>window.ran = true</script>\n\nafter",
    "<p>before</p>\n<p>after</p>\n"],
  // x.png is answered 404, so the image fails and a handler left on it runs.
  ["an event handler attribute, removed", '<img src="x.png" onerror="window.ran = true">',
    '<img src="x.png">', { imageError: true }],
  ["a javascript: link, its href removed", "[x](javascript:window.ran=true)",
    '<p><a target="_blank" rel="noopener noreferrer">x</a></p>\n'],
  // DOMPurify keeps a removed element's text.
  ["a form and its controls, removed, their text kept", "<form><input value=\"a\"><button>b</button></form>", "b"],
  ["an iframe, removed", '<iframe src="http://e.com"></iframe>', ""],
  // A legal page's links, against the account service's address.
  ["an inline link on a path, resolved against the base", "[it](/legal/ncii/report)",
    `<p><a href="${BASE}/legal/ncii/report" target="_blank" rel="noopener noreferrer">it</a></p>\n`, { base: BASE }],
  ["a reference link on a path, resolved against the base", "[it][r]\n\n[r]: /legal/ncii/report",
    `<p><a href="${BASE}/legal/ncii/report" target="_blank" rel="noopener noreferrer">it</a></p>\n`, { base: BASE }],
  ["an angle-bracket link on a path, resolved against the base", "[it](</legal/ncii/report>)",
    `<p><a href="${BASE}/legal/ncii/report" target="_blank" rel="noopener noreferrer">it</a></p>\n`, { base: BASE }],
  ["a single-quoted HTML link on a path, resolved against the base", "<a href='/legal/ncii/report'>it</a>",
    `<p><a href="${BASE}/legal/ncii/report">it</a></p>\n`, { base: BASE }],
  ["links with an address of their own, left as they are", "[a](https://e.com/x) [b](#top) [c](//e.com/y)",
    '<p><a href="https://e.com/x" target="_blank" rel="noopener noreferrer">a</a> <a href="#top" target="_blank" rel="noopener noreferrer">b</a> <a href="//e.com/y" target="_blank" rel="noopener noreferrer">c</a></p>\n', { base: BASE }],
  ["code that shows a link, unchanged", "`[it](/legal/ncii/report)`",
    "<p><code>[it](/legal/ncii/report)</code></p>\n", { base: BASE }],
  ["a base the page names itself, never read", '<div data-link-base="https://e.com"><a href="/legal/x">it</a></div>',
    `<div data-link-base="https://e.com"><a href="${BASE}/legal/x">it</a></div>`, { base: BASE }],
  ["a link on a path with no base named, as it was", "[it](/legal/ncii/report)",
    '<p><a href="/legal/ncii/report" target="_blank" rel="noopener noreferrer">it</a></p>\n'],
];

const browser = await chromium.launch({ channel: "chromium" });
const results = [];
let failed = 0;
try {
  const page = await browser.newPage();
  const errors = [];
  // The one failure the page is meant to have: the 404 for x.png.
  page.on("console", (message) => {
    if (message.type() === "error" && message.location().url !== `${ORIGIN}/x.png`) errors.push(message.text());
  });
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.route(`${ORIGIN}/**`, (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/") return route.fulfill({ contentType: "text/html", body: PAGE });
    if (!SERVED.test(path)) return route.fulfill({ status: 404, body: "" });
    return route.fulfill({ contentType: "text/javascript", body: readFileSync(`${ASSETS}${path}`) });
  });
  await page.goto(`${ORIGIN}/`);
  await page.waitForFunction(() => window.ready === true, null, { timeout: 30_000 });

  for (const [name, raw, expected, { imageError = false, base } = {}] of CASES) {
    const actual = await page.evaluate(([text, b]) => window.render(text, b), [raw, base]);
    // Wait for the image to fail only when it is in the page to fail.
    if (imageError && actual.includes("<img")) {
      await page.waitForFunction(() => window.imageErrors >= 1, null, { timeout: 30_000 });
    }
    const ok = actual === expected;
    if (!ok) failed++;
    results.push({ name, raw, expected, actual, ok });
    console.log(`${ok ? "ok" : "FAIL"}: ${name}${ok ? "" : `\n  expected ${JSON.stringify(expected)}\n  actual   ${JSON.stringify(actual)}`}`);
  }

  // No markup the cases offered ran, the handler on the failing image
  // included; the javascript: link is never followed, and its markup case
  // shows its href gone.
  const ran = await page.evaluate(() => window.ran === true);
  if (ran) { failed++; console.log("FAIL: markup the sanitizer should have removed ran"); }
  if (errors.length) { failed++; console.log(`FAIL: console errors: ${JSON.stringify(errors)}`); }
  results.push({ name: "nothing ran", ok: !ran }, { name: "no console error", ok: !errors.length, errors });
} finally {
  await browser.close();
}

writeFileSync("/out/markdown.json", JSON.stringify({ browser: "chromium", results }, null, 2));
console.log(failed ? `${failed} check(s) failed` : `all ${results.length} checks passed`);
process.exit(failed ? 1 : 0);
