// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// What a service worker reads and sends of the browser's name at its first
// read, before the browser's driver names it
// (apps/locus/keeper/cmd/cyfr-browser/person.go). No page the driver shows
// can register one, so browser.py runs this in a container of the image
// with no network, as
//   node agent-probe.mjs CHROMIUM USER_AGENT
// It serves a page on localhost, an origin of its own, which registers a
// service worker, and starts the shell on it alone by
// --user-agent=USER_AGENT, the switch the driver's Chrome runs by. The
// worker reports its navigator.userAgent, userAgentData's brands and its
// high-entropy hints in a request; the server records the User-Agent
// header of that request and of the worker's script. It prints one JSON
// object, {service: {agent, brands, hints, header, script}}, once the
// worker has reported, and exits 1 if it does not within 30 seconds.

import { spawn } from "node:child_process";
import { createServer } from "node:http";

const [chromium, userAgent] = process.argv.slice(2);
const report = (surface) => `navigator.userAgentData.getHighEntropyValues(["architecture", "bitness", "formFactors",
  "fullVersionList", "uaFullVersion"]).then(hints => fetch("/report?" + encodeURIComponent(JSON.stringify({surface:
  "${surface}", agent: navigator.userAgent, brands: navigator.userAgentData.brands.map(b => b.brand), hints}))));`;
const files = {
  "/": ["text/html", `<script>navigator.serviceWorker.register("/service.js")</script>`],
  "/service.js": ["text/javascript", report("service")],
};
const seen = {};
const scripts = {};
let shell;
const done = (code, text) => {
  if (shell) shell.kill("SIGKILL");
  process.stdout.write(text + "\n");
  process.exit(code);
};
const server = createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname === "/report") {
    const read = JSON.parse(decodeURIComponent(url.search.slice(1)));
    seen[read.surface] = { ...read, header: req.headers["user-agent"] };
    res.writeHead(204).end();
    if (seen.service) {
      seen.service.script = scripts.service;
      done(0, JSON.stringify(seen));
    }
    return;
  }
  const file = files[url.pathname];
  if (!file) return res.writeHead(404).end();
  if (url.pathname !== "/") scripts[url.pathname.slice(1, -3)] = req.headers["user-agent"];
  res.writeHead(200, { "Content-Type": file[0] }).end(file[1]);
});
server.listen(8080, "127.0.0.1", () => {
  shell = spawn(chromium, ["--no-sandbox", "--disable-dev-shm-usage", "--user-data-dir=/tmp/agent-probe",
    "--host-resolver-rules=MAP localhost 127.0.0.1", "--user-agent=" + userAgent, "http://localhost:8080/"],
    { stdio: "ignore" });
  shell.on("exit", (code) => done(1, JSON.stringify({ error: `the shell exited ${code}`, seen })));
});
setTimeout(() => done(1, JSON.stringify({ error: "the service worker did not report within 30 seconds", seen })), 30_000);
