// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// What a shared worker and a service worker read and send of the browser's
// name at their first read, the two surfaces the browser's driver never
// holds at their start (apps/locus/keeper/cmd/cyfr-browser/person.go): run
// by browser.py in a container of the image with no network, as
//   node agent-probe.mjs CHROMIUM USER_AGENT
// it serves a page on localhost, an origin of its own, which makes a
// shared worker and registers a service worker, and starts the shell on it
// by --user-agent=USER_AGENT, the switch the driver starts Chrome by. Each
// worker reports its navigator.userAgent, userAgentData's brands and its
// high-entropy hints in a request; the server records the User-Agent
// header of that request and of the worker's script. It prints one JSON
// object, {surface: {agent, brands, hints, header, script}}, once both
// have reported, and exits 1 if they do not within 30 seconds.

import { spawn } from "node:child_process";
import { createServer } from "node:http";

const [chromium, userAgent] = process.argv.slice(2);
const report = (surface) => `navigator.userAgentData.getHighEntropyValues(["architecture", "bitness", "formFactors",
  "fullVersionList", "uaFullVersion"]).then(hints => fetch("/report?" + encodeURIComponent(JSON.stringify({surface:
  "${surface}", agent: navigator.userAgent, brands: navigator.userAgentData.brands.map(b => b.brand), hints}))));`;
const files = {
  "/": ["text/html", `<script>new SharedWorker("/shared.js"); navigator.serviceWorker.register("/service.js")</script>`],
  "/shared.js": ["text/javascript", report("shared")],
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
    if (seen.shared && seen.service) {
      for (const surface of ["shared", "service"]) seen[surface].script = scripts[surface];
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
setTimeout(() => done(1, JSON.stringify({ error: "the workers did not report within 30 seconds", seen })), 30_000);
