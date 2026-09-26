// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The frame-facts experiment: what a sandboxed frame on today's /t/ page
// may do, per browser.
//
// Run inside the official Playwright image (tests/browser/run.sh), against a
// `cyfr` release serving two public tinctures, frame-probe and
// frame-neighbour (tests/browser/tinctures/). For every browser the image
// ships (Chromium, Firefox, WebKit), a page on the server's own origin — the
// origin the Prism shell frames tinctures from — holds frame-probe's /t/
// page in an <iframe sandbox="allow-scripts">, as the shell does, and the
// probe (tinctures/frame-probe/probe.js) makes nine attempts from inside it:
//
//   self_navigation    the frame navigates itself to its own page
//   fetch              fetch() of an asset of its own
//   form_post          a form POSTed to its own path
//   message_to_parent  postMessage to the page that frames it
//   neighbour_script   a <script> from another tincture's path on the origin
//   module_script      a module script of its own
//   blob_worker        a Worker from a blob: URL
//   wasm_instantiate   WebAssembly.instantiate of the smallest module
//   redirect_fetch     fetch() of an asset answered with a 302 to another
//                      asset, and of a route the server redirects itself
//
// Each attempt is recorded as allowed or refused with what was observed:
// the frame's own view, the requests that reached the network with the
// Origin they carried, the messages that arrived, the CSP violations the
// frame reported and the browser's console. No outcome is asserted — the
// experiment establishes facts — and the run fails only when an attempt
// could not be observed.
//
// Every browser reaches the server through a proxy of the harness's own,
// under the name `cyfr.test` (a name no browser exempts from its proxy, as
// each exempts loopback addresses differently). The proxy answers two
// requests itself — the page that frames the probe, and a 302 from
// frame-probe's moved.json to its asset.json, since no /t/ route redirects
// today and not every engine lets a harness answer a redirect in the page
// — and forwards every other request, unchanged, to the server.
//
// Usage: node frame-facts.mjs SERVER_URL PROBE_PATH OUT_DIR

import { chromium, firefox, webkit } from "playwright-core";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer, request as forward } from "node:http";
import { join } from "node:path";

const PROBES = [
  "self_navigation",
  "fetch",
  "form_post",
  "message_to_parent",
  "neighbour_script",
  "module_script",
  "blob_worker",
  "wasm_instantiate",
  "redirect_fetch",
];

// Evaluated in the frame and the page, never here.
const DONE = () => {
  const r = document.getElementById("results");
  return !!r && r.dataset.done === "yes";
};
const READ = () => document.getElementById("results").textContent;

function hostPage(probePath) {
  return `<!doctype html>
<html><head><title>frame-facts host</title></head>
<body>
<script>
  window.__messages = [];
  window.addEventListener("message", function (event) {
    var frame = document.getElementById("frame");
    window.__messages.push({
      origin: event.origin,
      data: event.data,
      from_frame: !!frame && event.source === frame.contentWindow
    });
  });
</script>
<iframe id="frame" sandbox="allow-scripts" src="${probePath}" width="800" height="600"></iframe>
</body></html>
`;
}

// The origin the browsers see the server at, through the proxy.
const NAME = "cyfr.test";

// The harness's proxy: the two answers of its own, and every other request
// forwarded to `server` as it came.
function startProxy(server, probePath) {
  const target = new URL(server);
  const proxy = createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    // What reached the network, and with which Origin: the one account of
    // a request leaving that every engine gives alike.
    proxy.seen.push({ method: req.method, url: url.href, origin: req.headers.origin ?? null });
    if (url.pathname === "/__frame_facts/host") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(hostPage(probePath));
      return;
    }
    // The 302 carries the CORS header today's asset answers carry
    // (`access-control-allow-origin: *`); its bare twin carries none.
    if (url.pathname === `${probePath}/moved.json` || url.pathname === `${probePath}/moved-bare.json`) {
      const headers = { location: `${probePath}/asset.json`, "content-length": "0" };
      if (url.pathname.endsWith("/moved.json")) headers["access-control-allow-origin"] = "*";
      res.writeHead(302, headers);
      res.end();
      return;
    }
    const upstream = forward(
      { host: target.hostname, port: target.port, method: req.method, path: url.pathname + url.search, headers: req.headers },
      (answer) => {
        res.writeHead(answer.statusCode, answer.rawHeaders);
        answer.pipe(res);
      });
    upstream.on("error", (error) => {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`proxy: ${error.message}`);
    });
    req.pipe(upstream);
  });
  proxy.seen = [];
  return new Promise((resolve) => proxy.listen(0, "127.0.0.1", () => resolve(proxy)));
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFrame(page, accept, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const frame = page.frames().find((f) => accept(f.url()));
    if (frame) return frame;
    await sleep(100);
  }
  return null;
}

// One browser's run: the frame's results, the requests that left and the
// messages that arrived.
async function observe(browserType, base, proxy, probePath) {
  proxy.seen = [];
  const consoleLines = [];
  const browser = await browserType.launch({ proxy: { server: `http://127.0.0.1:${proxy.address().port}` } });
  try {
    const page = await browser.newPage();
    page.on("console", (message) => {
      if (message.type() === "error" || message.type() === "warning") {
        consoleLines.push({ type: message.type(), text: message.text(), url: message.location().url });
      }
    });
    await page.goto(`${base}/__frame_facts/host`);

    const frame = await waitFrame(page, (url) => url.includes(probePath) && !url.includes("navigated=1"));
    if (!frame) throw new Error(`no frame loaded ${probePath}`);
    await frame.waitForFunction(DONE, null, { timeout: 60_000 });
    const results = JSON.parse(await frame.evaluate(READ));
    const messages = await page.evaluate(() => window.__messages);

    // The ninth attempt: the frame navigates itself once told to.
    await page.evaluate(() =>
      document.getElementById("frame").contentWindow.postMessage({ frameFacts: "navigate" }, "*"));
    let navigated = null;
    const moved = await waitFrame(page, (url) => url.includes(probePath) && url.includes("navigated=1"), 10_000);
    if (moved) {
      try {
        await moved.waitForFunction(DONE, null, { timeout: 10_000 });
        navigated = JSON.parse(await moved.evaluate(READ));
      } catch (error) {
        navigated = { error: error.message };
      }
    }
    const after = page.frames().find((f) => f.url().includes(probePath));
    // A request still in flight reaches the proxy's account.
    await sleep(250);
    return {
      version: browser.version(),
      results,
      messages,
      requests: proxy.seen,
      console: consoleLines,
      navigated,
      frame_url_after: after ? after.url() : null,
    };
  } finally {
    await browser.close();
  }
}

const bare = (url) => url.split("?")[0];
const requestsTo = (observed, suffix, method) =>
  observed.requests.filter((r) => bare(r.url).endsWith(suffix) && (!method || r.method === method));
const violationsFor = (results, fragment) =>
  (results.violations || []).filter((v) => (v.blocked || "").includes(fragment) || v.directive === fragment);

// Each probe as allowed or refused, with the facts it rests on.
function decide(observed) {
  const r = observed.results;
  const facts = {};
  const navigated = observed.navigated;
  facts.self_navigation = {
    allowed: !!(navigated && navigated.navigated),
    observed: { frame: r.self_navigation ?? null, frame_url_after: observed.frame_url_after, second_document: navigated },
  };
  const fetched = r.fetch || {};
  facts.fetch = { allowed: !!fetched.ok, observed: { frame: fetched, requests: requestsTo(observed, "/asset.json").slice(0, 1) } };
  facts.form_post = {
    allowed: requestsTo(observed, "/form-target.json", "POST").length > 0,
    observed: { frame: r.form_post ?? null, requests: requestsTo(observed, "/form-target.json") },
  };
  const arrived = (observed.messages || []).filter((m) => m.data && m.data.frameFacts === "hello from the frame");
  facts.message_to_parent = { allowed: arrived.length > 0, observed: { frame: r.message_to_parent ?? null, arrived } };
  const neighbour = r.neighbour_script || {};
  facts.neighbour_script = {
    allowed: !!neighbour.ran,
    observed: { frame: neighbour, requests: requestsTo(observed, "/neighbour.js"), violations: violationsFor(r, "neighbour.js") },
  };
  const module = r.module_script || {};
  facts.module_script = {
    allowed: !!module.ran,
    observed: { frame: module, requests: requestsTo(observed, "/module.js"), violations: violationsFor(r, "module.js") },
  };
  const worker = r.blob_worker || {};
  facts.blob_worker = { allowed: !!worker.ran, observed: { frame: worker, violations: violationsFor(r, "blob") } };
  const wasm = r.wasm_instantiate || {};
  facts.wasm_instantiate = {
    allowed: !!wasm.instantiated,
    observed: { frame: wasm, violations: [...violationsFor(r, "wasm-eval"), ...violationsFor(r, "script-src")] },
  };
  const redirect = r.redirect_fetch || {};
  facts.redirect_fetch = {
    allowed: !!(redirect.asset && redirect.asset.ok),
    observed: {
      frame: redirect,
      requests: [
        ...requestsTo(observed, "/moved.json"),
        ...requestsTo(observed, "/moved-bare.json"),
        ...requestsTo(observed, "/asset.json").slice(1),
        ...requestsTo(observed, "/chat"),
        ...requestsTo(observed, "/login"),
      ],
    },
  };
  return facts;
}

const unnonced = (text) => String(text).replace(/'nonce-[^']+'/g, "'nonce-…'").replace(/\s+/g, " ");

function fetchOutcome(result) {
  if (!result) return "not attempted";
  if (result.detail) return result.detail;
  return `status ${result.status}, type ${result.type}, redirected=${result.redirected}`;
}

// The browser's own words for a refusal: the first console line naming
// what the probe attempted.
const CONSOLE_MARKS = {
  fetch: "asset.json",
  form_post: "form",
  neighbour_script: "neighbour.js",
  module_script: "module.js",
  blob_worker: "blob:",
  wasm_instantiate: "WebAssembly",
  redirect_fetch: "moved",
};

function consoleReason(observed, name) {
  const mark = CONSOLE_MARKS[name];
  const line = mark && observed.console.find((c) => c.text.includes(mark));
  if (!line) return "";
  const text = line.text.replace(/\s+/g, " ").replace(/'nonce-[^']+'/g, "'nonce-…'");
  return text.length > 220 ? `${text.slice(0, 217)}...` : text;
}

// One line per probe: the outcome and the shortest fact that shows it.
function summary(facts, observed) {
  const lines = {};
  for (const name of PROBES) {
    const fact = facts[name];
    const frame = fact.observed.frame || {};
    const csp = (fact.observed.violations || []).map((v) => v.directive);
    const cspText = csp.length ? `CSP ${[...new Set(csp)].join(", ")}` : "no CSP report";
    let detail = frame.detail || "";
    switch (name) {
      case "self_navigation":
        detail = fact.allowed ? "the frame loaded its own page again" : `the frame stayed at ${fact.observed.frame_url_after}`;
        break;
      case "fetch": {
        const request = fact.observed.requests[0];
        detail = `${request ? `reached the server with Origin ${request.origin}` : "nothing reached the server"}; ${fetchOutcome(frame)}`;
        break;
      }
      case "form_post":
        detail = fact.allowed ? "the POST reached the server" : "nothing reached the server";
        break;
      case "message_to_parent":
        detail = fact.allowed ? `arrived with origin ${fact.observed.arrived[0].origin}` : "nothing arrived";
        break;
      case "neighbour_script":
      case "module_script": {
        const origins = [...new Set(fact.observed.requests.map((r) => String(r.origin)))];
        detail = `${fact.observed.requests.length ? `reached the server with Origin ${origins.join(", ")}` : "nothing reached the server"}; ` +
          `loaded=${frame.loaded} ran=${frame.ran}; ${cspText}`;
        break;
      }
      case "blob_worker":
      case "wasm_instantiate":
        detail = `${frame.detail ? unnonced(frame.detail) : fact.allowed ? "ran" : "no answer"}; ${cspText}`;
        break;
      case "redirect_fetch":
        detail = `asset 302 with ACAO *: ${fetchOutcome(frame.asset)}; asset 302 without: ${fetchOutcome(frame.bare)}; ` +
          `server /chat 302: ${fetchOutcome(frame.server)}`;
        break;
    }
    const reason = fact.allowed ? "" : consoleReason(observed, name);
    lines[name] = `${fact.allowed ? "allowed" : "refused"}: ${detail}${reason ? ` (console: ${reason})` : ""}`;
  }
  return lines;
}

async function main() {
  const [server, probePath, outDir] = process.argv.slice(2);
  if (!server || !probePath || !outDir) {
    console.error("usage: node frame-facts.mjs SERVER_URL PROBE_PATH OUT_DIR");
    process.exit(64);
  }
  mkdirSync(outDir, { recursive: true });
  const proxy = await startProxy(server, probePath);
  const base = `http://${NAME}:${new URL(server).port || 80}`;
  const record = {};
  for (const [name, browserType] of [["chromium", chromium], ["firefox", firefox], ["webkit", webkit]]) {
    const observed = await observe(browserType, base, proxy, probePath);
    const facts = decide(observed);
    record[name] = { version: observed.version, facts, summary: summary(facts, observed), observed };
    console.log(`== ${name} ${observed.version}`);
    for (const [probe, line] of Object.entries(record[name].summary)) console.log(`  ${probe}: ${line}`);
  }
  proxy.close();
  writeFileSync(join(outDir, "frame-facts.json"), JSON.stringify(record, null, 2));

  const browsers = Object.keys(record);
  const table = [
    `| probe | ${browsers.map((b) => `${b} ${record[b].version}`).join(" | ")} |`,
    `|---|${browsers.map(() => "---|").join("")}`,
    ...PROBES.map((p) => `| ${p} | ${browsers.map((b) => record[b].summary[p].replaceAll("|", "\\|")).join(" | ")} |`),
  ];
  writeFileSync(join(outDir, "frame-facts.md"), table.join("\n") + "\n");
  console.log(table.join("\n"));

  const missing = browsers.flatMap((b) => PROBES.filter((p) => !(p in record[b].facts)).map((p) => `${b}/${p}`));
  if (missing.length) {
    console.error(`FAIL: attempts not observed: ${missing.join(", ")}`);
    process.exit(1);
  }
  console.log("ok: every attempt was observed in every browser");
}

main().catch((error) => {
  console.error(`FAIL: ${error.stack || error}`);
  process.exit(1);
});
