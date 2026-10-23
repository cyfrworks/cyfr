// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { errorMonitor, once } from "node:events";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer, globalAgent, request } from "node:http";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { connect as secureConnect } from "node:tls";
import { askHome, startProxy, startReceiver, waitFor } from "./lib.mjs";

let authority;
let cert;
let key;
before(() => {
  authority = mkdtempSync(join(tmpdir(), "cyfr-browser-sockets-"));
  cert = join(authority, "cert.pem");
  key = join(authority, "key.pem");
  execFileSync("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
    "-nodes", "-days", "1", "-subj", "/CN=cyfr.test", "-addext", "subjectAltName=DNS:cyfr.test,DNS:attacker.test",
    "-keyout", key, "-out", cert], { stdio: "ignore" });
});
after(() => rmSync(authority, { recursive: true, force: true }));

async function listening(t, server) {
  const sockets = new Set();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("error", () => {});
    socket.once("close", () => sockets.delete(socket));
  });
  t.after(() => {
    for (const socket of sockets) socket.destroy();
    return new Promise((resolve) => server.close(resolve));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return server;
}

async function proxyFor(t, handler = (_req, res) => res.end("ok")) {
  const cell = await listening(t, createServer(handler));
  const home = { name: "home", host: "cyfr.test", port: cell.address().port, cert, key };
  const proxy = await startProxy({ homes: [home] });
  closeProxy(t, proxy);
  return { cell, home, proxy };
}

function closeProxy(t, proxy) {
  const sockets = new Set();
  proxy.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  t.after(() => {
    for (const socket of sockets) socket.destroy();
    return new Promise((resolve) => proxy.close(resolve));
  });
}

async function connection(t, proxy, host) {
  const socket = connect({ port: proxy.address().port, host: "127.0.0.1", allowHalfOpen: true });
  socket.on("error", () => {});
  t.after(() => socket.destroy());
  await once(socket, "connect");
  const answer = once(socket, "data");
  socket.write(`CONNECT ${host}:443 HTTP/1.1\r\nHost: ${host}:443\r\n\r\n`);
  const [data] = await answer;
  return { socket, data: String(data) };
}

async function tunnel(t, proxy, host = "cyfr.test") {
  const { socket, data } = await connection(t, proxy, host);
  assert.match(data, /^HTTP\/1.1 200 /);
  const tls = secureConnect({ socket, servername: host, ca: readFileSync(cert) });
  tls.on("error", () => {});
  t.after(() => tls.destroy());
  await once(tls, "secureConnect");
  return tls;
}

function get(options) {
  return new Promise((resolve, reject) => {
    const req = request(options, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("error", reject);
      res.on("end", () => resolve({ status: res.statusCode, body }));
    });
    req.on("error", reject);
    req.end();
  });
}

function through(tls, path = "/") {
  return get({ host: "cyfr.test", path, createConnection: () => tls });
}

test("a peer reset after a refused CONNECT is recorded and the process keeps serving", { timeout: 10_000 }, async (t) => {
  const proxy = await startProxy();
  closeProxy(t, proxy);
  // errorMonitor observes the actual reset without handling it: the
  // unguarded harness still raises an uncaught Socket error here.
  const resetObserved = new Promise((resolve) => proxy.once("connection", (socket) => socket.once(errorMonitor, resolve)));
  const { socket, data } = await connection(t, proxy, "unrouted.test");
  assert.match(data, /^HTTP\/1.1 403 /);
  // HTTP has handed the socket to CONNECT; its parser's error listener
  // is gone. Reset after reading the refusal, while the server still
  // awaits our half-close, rather than relying on a timing sleep.
  socket.resetAndDestroy();
  assert.equal((await resetObserved).code, "ECONNRESET");
  const reset = proxy.errors.find((e) => e.code === "ECONNRESET");
  assert.equal(reset.active, false);
  const next = await get({ host: "127.0.0.1", port: proxy.address().port, path: "http://unrouted.test/", agent: false });
  assert.equal(next.status, 421);
});

test("a reset during a cell request returns its message as a failed request", { timeout: 10_000 }, async (t) => {
  const { proxy } = await proxyFor(t, (req, res) => {
    if (req.url === "/reset") req.socket.resetAndDestroy();
    else res.end("ok");
  });
  const answer = await through(await tunnel(t, proxy), "/reset");
  assert.equal(answer.status, 502);
  assert.match(answer.body, /socket hang up|ECONNRESET/);
  assert.match(proxy.seen.find((r) => r.url === "https://cyfr.test/reset").error, /socket hang up|ECONNRESET/);
  assert.equal((await through(await tunnel(t, proxy))).body, "ok");
});

test("a reset during a cell response fails the response instead of leaving it open", { timeout: 10_000 }, async (t) => {
  let reset;
  const { proxy } = await proxyFor(t, (req, res) => {
    if (req.url !== "/partial") return res.end("ok");
    reset = () => req.socket.resetAndDestroy();
    res.writeHead(200, { "content-length": "100" });
    res.write("partial");
  });
  const tls = await tunnel(t, proxy);
  const response = new Promise((resolve, reject) => {
    const req = request({ host: "cyfr.test", path: "/partial", createConnection: () => tls }, (res) => {
      res.on("error", reject);
      res.on("end", resolve);
      res.once("data", () => reset());
    });
    req.on("error", reject);
    req.end();
  });
  await assert.rejects(response, /aborted|ECONNRESET/);
  assert.match(proxy.seen.find((r) => r.url === "https://cyfr.test/partial").error, /ECONNRESET|aborted/);
});

test("a reset of an upgraded upstream is recorded and closes both tunnel ends", { timeout: 10_000 }, async (t) => {
  const { cell, proxy } = await proxyFor(t);
  let upgraded;
  const accepted = new Promise((resolve) => {
    cell.once("upgrade", (_req, socket) => {
      upgraded = socket;
      socket.write("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
      resolve();
    });
  });
  const tls = await tunnel(t, proxy);
  const answer = once(tls, "data");
  tls.write("GET /live/websocket HTTP/1.1\r\nHost: cyfr.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
  await accepted;
  assert.match(String((await answer)[0]), /^HTTP\/1.1 101 /);
  const closed = new Promise((resolve) => {
    tls.once("end", resolve);
    tls.once("close", resolve);
  });
  upgraded.resetAndDestroy();
  tls.resume();
  await closed;
  tls.destroy();
  const reset = proxy.errors.find((e) => e.code === "ECONNRESET" && e.peer.includes("WebSocket"));
  assert.equal(reset.active, true);
  assert.match(proxy.seen.find((r) => r.method === "UPGRADE").error, /ECONNRESET/);
});

test("askHome rejects a truncated reply with its transport error", { timeout: 10_000 }, async (t) => {
  const cell = await listening(t, createServer((req, res) => {
    res.writeHead(200, { "content-length": "100" });
    res.write("partial", () => req.socket.resetAndDestroy());
  }));
  await assert.rejects(askHome({ host: "cyfr.test", port: cell.address().port }, "/"), /aborted|ECONNRESET|socket hang up/);
});

test("an idle askHome reset leaves its completed answer intact", { timeout: 10_000 }, async (t) => {
  const messages = [];
  t.mock.method(console, "error", (message) => messages.push(message));
  const cell = await listening(t, createServer((_req, res) => res.end("complete")));
  const home = { host: "cyfr.test", port: cell.address().port };
  const answer = await askHome(home, "/");
  const idle = await waitFor(() => Object.values(globalAgent.freeSockets).flat()
    .find((socket) => socket.remotePort === home.port), { timeoutMs: 1_000 });
  // An idle socket may be paused by its agent, so a real TCP reset can
  // surface only as close. Inject its error event after response completion
  // to check this lifetime deterministically; CONNECT above uses a real reset.
  idle.emit("error", Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" }));
  assert.ok(messages.some((message) => /ECONNRESET.*idle connection/.test(message)));
  assert.equal(answer.body, "complete");
  assert.equal((await askHome(home, "/")).body, "complete");
});

test("the receiver still receives plain HTTP and HTTPS through the proxy", { timeout: 10_000 }, async (t) => {
  const receiver = await startReceiver();
  t.after(() => new Promise((resolve) => receiver.close(resolve)));
  const proxy = await startProxy({ receiver, attacker: { host: "attacker.test", name: "attacker", cert, key } });
  closeProxy(t, proxy);
  const plain = await get({ host: "127.0.0.1", port: proxy.address().port, path: "http://attacker.test/plain", agent: false });
  const tls = await tunnel(t, proxy, "attacker.test");
  const secure = await get({ host: "attacker.test", path: "/secure", createConnection: () => tls });
  assert.equal(plain.status, 200);
  assert.equal(secure.status, 200);
  assert.deepEqual(receiver.log.map((r) => r.path), ["/plain", "/secure"]);
});

test("the receiver survives a reset during an incoming body", { timeout: 10_000 }, async (t) => {
  const receiver = await startReceiver();
  t.after(() => new Promise((resolve) => receiver.close(resolve)));
  const socket = connect(receiver.address().port, "127.0.0.1");
  socket.on("error", () => {});
  t.after(() => socket.destroy());
  await once(socket, "connect");
  const received = new Promise((resolve) => receiver.once("request", (req) => req.once("data", resolve)));
  socket.write("POST / HTTP/1.1\r\nHost: attacker.test\r\nContent-Length: 100\r\n\r\npartial");
  await received;
  socket.resetAndDestroy();
  const reset = await waitFor(() => receiver.errors.find((e) => e.code === "ECONNRESET"));
  assert.equal(reset.active, true);
  assert.equal((await get({ host: "127.0.0.1", port: receiver.address().port, agent: false })).status, 200);
});
