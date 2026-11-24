// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The directory's front for the cells (front.sh): a TLS listener on the
// proof's own loopback address, port 443, presenting the certificate the
// run's authority issued for the directory's name, and forwarding each
// request to the directory cell's proxy listener as the stack's Caddy
// forwards to cyfr's (X-Forwarded-For, -Proto and -Host), a WebSocket
// upgrade included. The homes' directory client reaches it at
// https://dir.test, the name each cell's ERL_INETRC maps to this address,
// and trusts it through the run's authority. The CYFR app's proof
// (tests/desktop-proof) fronts a CYFR the same way.
//
// A control listener beside it (plain HTTP, the same address) lets the
// proof break the directory on purpose, and reports what reached it:
//
//   POST /fault {"mode": …}   none | down | hold | directory | redirect
//     down                       every connection is closed before it is
//                                answered: the directory is unreachable
//     hold                       every request but an upgrade waits,
//                                unanswered, until the mode changes; one
//                                its client gives up on first is recorded
//                                as aborted
//     directory {"directory": U} the sign-in page (GET /login) names U as
//                                its account directory: the CYFR as it
//                                would be configured with another
//     redirect {"from": P, "to": U}  a request for the path P is answered
//                                with a redirect to U
//   GET /seen                 every request: method, path, user agent,
//                             the names of the cookies it carried (never
//                             their values), when it came, status, fault,
//                             and whether and when its client gave up
//                             before the answer; an upgrade is marked so,
//                             with when its connection closed
//   GET /health               200 once listening, with the TOKEN it was
//                             started with, so front.sh accepts readiness
//                             from its own container alone
//
// Usage: node front.mjs LISTEN_HOST:PORT CONTROL_PORT NAME CERT KEY UPSTREAM_PORT TOKEN

import { createServer as createHttp, request as forward } from "node:http";
import { connect } from "node:net";
import { createServer as createTls } from "node:https";
import { readFileSync } from "node:fs";

const [listen, controlPort, name, cert, key, upstreamPort, token] = process.argv.slice(2);
if (!listen || !controlPort || !name || !cert || !key || !upstreamPort || !token) {
  console.error("usage: node front.mjs LISTEN_HOST:PORT CONTROL_PORT NAME CERT KEY UPSTREAM_PORT TOKEN");
  process.exit(64);
}
const [host, port] = listen.split(":");
let mode = "none";
let directory = "";
let redirect = null;
const seen = [];
// The requests hold keeps waiting, each released when the mode changes.
let held = [];

// The names of the cookies a request carried, never their values.
const cookieNames = (req) => (req.headers.cookie ?? "").split(";").map((c) => c.split("=")[0].trim()).filter(Boolean);

const front = createTls({ cert: readFileSync(cert), key: readFileSync(key) }, (req, res) => {
  const account = { at: Date.now(), method: req.method, path: req.url.split("?")[0], host: req.headers.host, agent: req.headers["user-agent"] ?? null, cookies: cookieNames(req), status: null, fault: null, aborted: false };
  seen.push(account);
  res.on("close", () => {
    if (!res.writableFinished) {
      account.aborted = true;
      account.abortedAt = Date.now();
    }
  });

  if (mode === "down") {
    account.fault = "down";
    req.socket.destroy();
    return;
  }
  if (mode === "hold") {
    account.fault = "hold";
    held.push(() => pass(req, res, account));
    return;
  }
  pass(req, res, account);
});

function pass(req, res, account) {
  if (account.aborted) return;
  if (mode === "redirect" && account.path === redirect.from) {
    account.fault = "redirect";
    account.status = 302;
    res.writeHead(302, { location: redirect.to, "content-length": 0 });
    res.end();
    return;
  }
  // The sign-in page named another directory: read whole, unencoded, so
  // its one attribute can be rewritten.
  const rewrite = mode === "directory" && req.method === "GET" && account.path === "/login";
  const outbound = forward({
    host: "127.0.0.1",
    port: Number(upstreamPort),
    method: req.method,
    path: req.url,
    headers: {
      ...Object.fromEntries(Object.entries(req.headers).filter(([header]) => !header.startsWith("x-forwarded-") &&
        !(rewrite && header === "accept-encoding"))),
      "x-forwarded-for": "127.0.0.1",
      "x-forwarded-proto": "https",
      "x-forwarded-host": req.headers.host,
    },
  }, (upstream) => {
    account.status = upstream.statusCode;
    if (!rewrite) {
      res.writeHead(upstream.statusCode, upstream.rawHeaders);
      upstream.pipe(res);
      return;
    }
    account.fault = "directory";
    const chunks = [];
    upstream.on("data", (chunk) => chunks.push(chunk));
    upstream.on("end", () => {
      const page = Buffer.from(Buffer.concat(chunks).toString("utf8")
        .replace(/data-account-directory="[^"]*"/g, `data-account-directory="${directory}"`), "utf8");
      const headers = Object.fromEntries(Object.entries(upstream.headers)
        .filter(([header]) => !["content-length", "transfer-encoding", "connection"].includes(header)));
      res.writeHead(upstream.statusCode, { ...headers, "content-length": page.length });
      res.end(page);
    });
  });
  outbound.on("error", (error) => {
    account.status = 502;
    if (res.headersSent) return res.destroy();
    res.writeHead(502, { "content-type": "text/plain" });
    res.end(`front: the directory does not answer: ${error.message}`);
  });
  req.pipe(outbound);
}

// An upgrade (a WebSocket) goes through whole: its request head as the
// front forwards any request's, then both ways byte for byte. Its status
// is the one the upstream's answer begins with.
front.on("upgrade", (req, socket, head) => {
  const account = { at: Date.now(), method: req.method, path: req.url.split("?")[0], host: req.headers.host, agent: req.headers["user-agent"] ?? null, cookies: cookieNames(req), status: null, fault: null, aborted: false };
  account.upgrade = true;
  seen.push(account);
  socket.on("close", () => { account.closedAt = Date.now(); });
  if (mode === "down") {
    account.fault = "down";
    socket.destroy();
    return;
  }
  const headers = {
    ...Object.fromEntries(Object.entries(req.headers).filter(([header]) => !header.startsWith("x-forwarded-"))),
    "x-forwarded-for": "127.0.0.1",
    "x-forwarded-proto": "https",
    "x-forwarded-host": req.headers.host,
  };
  const upstream = connect(Number(upstreamPort), "127.0.0.1", () => {
    upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n` +
      Object.entries(headers).flatMap(([k, v]) => (Array.isArray(v) ? v : [v]).map((one) => `${k}: ${one}\r\n`)).join("") + "\r\n");
    upstream.write(head);
    upstream.once("data", (chunk) => {
      account.status = Number(/^HTTP\/1\.[01] (\d{3})/.exec(chunk.toString("latin1"))?.[1]) || null;
    });
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});

const control = createHttp((req, res) => {
  const reply = (status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };
  if (req.method === "GET" && req.url === "/health") return reply(200, { name, mode, token });
  if (req.method === "GET" && req.url === "/seen") return reply(200, { seen });
  if (req.method === "POST" && req.url === "/fault") {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      try {
        const asked = JSON.parse(body);
        const next = asked.mode;
        if (!["none", "down", "hold", "directory", "redirect"].includes(next)) return reply(422, { error: "unknown mode" });
        if (next === "redirect" && !(/^\/[^\s?#]*$/.test(asked.from ?? "") && /^https:\/\/[^\s"<>]+$/.test(asked.to ?? ""))) {
          return reply(422, { error: "no redirect" });
        }
        if (next === "directory" && !/^https:\/\/[^"<>\s]+$/.test(asked.directory ?? "")) return reply(422, { error: "no directory" });
        mode = next;
        directory = next === "directory" ? asked.directory : "";
        redirect = next === "redirect" ? { from: asked.from, to: asked.to } : null;
        const release = held;
        held = [];
        for (const go of release) go();
        return reply(200, { mode, directory, redirect });
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
