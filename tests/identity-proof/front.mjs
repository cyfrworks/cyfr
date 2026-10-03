// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The directory's front for the cells (front.sh): a TLS listener on the
// proof's own loopback address, port 443, presenting the certificate the
// run's authority issued for the directory's name, and forwarding each
// request to the directory cell's listener as the stack's Caddy forwards
// to cyfr (X-Forwarded-For, -Proto and -Host). The homes' directory
// client reaches it at https://dir.test, the name each cell's ERL_INETRC
// maps to this address, and trusts it through the run's authority.
//
// A control listener beside it (plain HTTP, the same address) lets the
// proof break the directory on purpose, and reports what reached it:
//
//   POST /fault {"mode": …}   none | down | drop-recover | block-reads-after-recover
//     down                       every connection is closed before it is
//                                answered: the directory is unreachable
//     drop-recover               the next recovery is forwarded, and its
//                                answer is never delivered: a lost reply
//     block-reads-after-recover  once a recovery is answered, every read of
//                                a log is closed unanswered until cleared
//   GET /seen                 every request: method, path, status, fault
//   GET /health               200 once listening
//
// Usage: node front.mjs LISTEN_HOST:PORT CONTROL_PORT NAME CERT KEY UPSTREAM_PORT

import { createServer as createHttp, request as forward } from "node:http";
import { createServer as createTls } from "node:https";
import { readFileSync } from "node:fs";

const [listen, controlPort, name, cert, key, upstreamPort] = process.argv.slice(2);
if (!listen || !controlPort || !name || !cert || !key || !upstreamPort) {
  console.error("usage: node front.mjs LISTEN_HOST:PORT CONTROL_PORT NAME CERT KEY UPSTREAM_PORT");
  process.exit(64);
}
const [host, port] = listen.split(":");
let mode = "none";
let readsBlocked = false;
const seen = [];

const isRecover = (req) => req.method === "POST" && /^\/directory\/v1\/[^/]+\/recover$/.test(req.url.split("?")[0]);
const isRead = (req) => req.method === "GET" && /^\/directory\/v1\/[^/]+$/.test(req.url.split("?")[0]);

const front = createTls({ cert: readFileSync(cert), key: readFileSync(key) }, (req, res) => {
  const account = { at: Date.now(), method: req.method, path: req.url.split("?")[0], host: req.headers.host, status: null, fault: null };
  seen.push(account);

  if (mode === "down" || (readsBlocked && isRead(req))) {
    account.fault = mode === "down" ? "down" : "read-blocked";
    req.socket.destroy();
    return;
  }

  const dropping = mode === "drop-recover" && isRecover(req);
  if (dropping) mode = "none";

  const outbound = forward({
    host: "127.0.0.1",
    port: Number(upstreamPort),
    method: req.method,
    path: req.url,
    headers: {
      ...Object.fromEntries(Object.entries(req.headers).filter(([header]) => !header.startsWith("x-forwarded-"))),
      "x-forwarded-for": "127.0.0.1",
      "x-forwarded-proto": "https",
      "x-forwarded-host": req.headers.host,
    },
  }, (upstream) => {
    account.status = upstream.statusCode;
    if (dropping) {
      // The directory answered; the answer never reaches the home.
      account.fault = "reply-dropped";
      upstream.resume();
      upstream.on("end", () => req.socket.destroy());
      return;
    }
    if (mode === "block-reads-after-recover" && isRecover(req) && upstream.statusCode === 200) readsBlocked = true;
    res.writeHead(upstream.statusCode, upstream.rawHeaders);
    upstream.pipe(res);
  });
  outbound.on("error", (error) => {
    account.status = 502;
    if (res.headersSent) return res.destroy();
    res.writeHead(502, { "content-type": "text/plain" });
    res.end(`front: the directory does not answer: ${error.message}`);
  });
  req.pipe(outbound);
});

const control = createHttp((req, res) => {
  const reply = (status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };
  if (req.method === "GET" && req.url === "/health") return reply(200, { name, mode });
  if (req.method === "GET" && req.url === "/seen") return reply(200, { seen });
  if (req.method === "POST" && req.url === "/fault") {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      try {
        const next = JSON.parse(body).mode;
        if (!["none", "down", "drop-recover", "block-reads-after-recover"].includes(next)) return reply(422, { error: "unknown mode" });
        mode = next;
        readsBlocked = false;
        return reply(200, { mode });
      } catch {
        return reply(400, { error: "unreadable" });
      }
    });
    return undefined;
  }
  return reply(404, { error: "no such control" });
});

front.listen(Number(port), host, () => {
  control.listen(Number(controlPort), host, () => console.log(`front ${name} on ${host}:${port}, control on ${controlPort}`));
});

for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => process.exit(0));
