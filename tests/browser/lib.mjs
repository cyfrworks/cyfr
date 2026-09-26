// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// What the browser harness's experiments share: the proxy every browser
// reaches the server through, the attacker's receiver, the signed-in
// shell, and the percentiles of a measurement.
//
// Every browser reaches the server under the name `cyfr.test` (a name no
// browser exempts from its proxy, as each exempts loopback addresses
// differently), and the server is started with CYFR_HOST=cyfr.test, so the
// origin the browsers see is the origin the server derives its policies
// for: a tincture document's `frame-ancestors` and `connect-src` name it.
// The proxy forwards every request and WebSocket upgrade for `cyfr.test`
// to the server unchanged, hands every request for `attacker.test` to the
// receiver, and keeps an account of each request that reached the
// network. An experiment may answer a path itself (`answer`), as the
// frame-facts experiment answers a redirect no route makes.

import { createServer, request as forward } from "node:http";
export { chromium, firefox, webkit } from "playwright-core";
import { connect } from "node:net";

export const SITE = "cyfr.test";
export const ATTACKER = "attacker.test";

// The harness's proxy. `answer(req, url)` may answer a request itself by
// returning [status, headers, body]; anything else goes to its host.
export function startProxy(server, { receiver = null, answer = () => null } = {}) {
  const target = new URL(server);
  const proxy = createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    proxy.seen.push({
      at: Date.now(),
      method: req.method,
      url: url.href,
      host: url.hostname,
      origin: req.headers.origin ?? null,
      referer: req.headers.referer ?? null,
      conditional: !!(req.headers["if-none-match"] || req.headers["if-modified-since"]),
    });
    const own = answer(req, url);
    if (own) {
      const [status, headers, body] = own;
      res.writeHead(status, headers);
      res.end(body ?? "");
      return;
    }
    const upstream = url.hostname === ATTACKER && receiver ? receiver.address() : null;
    const options = upstream
      ? { host: "127.0.0.1", port: upstream.port }
      : { host: target.hostname, port: target.port };
    const outbound = forward(
      { ...options, method: req.method, path: url.pathname + url.search, headers: req.headers },
      (reply) => {
        const seen = proxy.seen.findLast((r) => r.url === url.href);
        if (seen) seen.status = reply.statusCode;
        res.writeHead(reply.statusCode, reply.rawHeaders);
        reply.pipe(res);
      });
    outbound.on("error", (error) => {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`proxy: ${error.message}`);
    });
    req.pipe(outbound);
  });
  // The shell's LiveView socket: the upgrade request goes to the server
  // as it came, and the two sockets are joined.
  proxy.on("upgrade", (req, socket, head) => {
    const upstream = connect(Number(target.port), target.hostname, () => {
      const lines = [`${req.method} ${new URL(req.url, `http://${req.headers.host}`).pathname +
        (new URL(req.url, `http://${req.headers.host}`).search)} HTTP/1.1`];
      for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
      upstream.write(lines.join("\r\n") + "\r\n\r\n");
      if (head && head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });
  // A browser tunnels a WebSocket through an HTTP proxy with CONNECT: the
  // tunnel is joined to the named host's listener.
  proxy.on("connect", (req, socket, head) => {
    const [host] = req.url.split(":");
    const port = host === ATTACKER && receiver ? receiver.address().port : Number(target.port);
    const address = host === ATTACKER && receiver ? "127.0.0.1" : target.hostname;
    proxy.seen.push({ at: Date.now(), method: "CONNECT", url: req.url, host, origin: null, referer: null, conditional: false });
    const upstream = connect(port, address, () => {
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head && head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });
  proxy.seen = [];
  return new Promise((resolve) => proxy.listen(0, "127.0.0.1", () => resolve(proxy)));
}

// The attacker's receiver: every request that reaches it is recorded with
// what it carried. A refused attack must leave nothing here.
export function startReceiver() {
  const receiver = createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      receiver.log.push({
        at: Date.now(),
        method: req.method,
        path: url.pathname,
        query: Object.fromEntries(url.searchParams),
        headers: req.headers,
        body: body.slice(0, 4096),
      });
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end("<!doctype html><title>received</title><p>received</p>");
    });
  });
  receiver.log = [];
  return new Promise((resolve) => receiver.listen(0, "127.0.0.1", () => resolve(receiver)));
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A browser context signed in as the fixture's person: the session cookie
// the server minted for the session the fixture created, as a sign-in
// leaves it.
export async function signedIn(browser, base, cookie) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await context.addCookies([{
    name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: false, sameSite: "Lax",
  }]);
  return context;
}

// The shell's picker focused on one tincture, its LiveView connected.
export async function openShell(page, base, segment, name) {
  const url = `${base}/a/${encodeURIComponent(segment)}/tinctures?publisher=local&tincture_name=${encodeURIComponent(name)}`;
  await page.goto(url);
  await page.waitForSelector(".phx-connected", { timeout: 30_000 });
  await launchButton(page, name).waitFor({ timeout: 30_000 });
}

export const launchButton = (page, name) =>
  page.locator(`button[phx-click="select_tincture"][phx-value-tincture="iframe_${name}"]`, { hasText: "Launch" });

// Launch `name` from the picker and answer its frame's element handle and
// Playwright frame once the frame navigated to its page.
export async function launch(page, name, { timeoutMs = 30_000 } = {}) {
  const known = new Set(await page.$$eval("iframe[phx-hook=IframeBridge]", (els) => els.map((e) => e.id)));
  await launchButton(page, name).click();
  return awaitFrame(page, known, timeoutMs);
}

// The newest frame the shell created that `known` does not hold.
export async function awaitFrame(page, known, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const ids = await page.$$eval("iframe[phx-hook=IframeBridge]", (els) => els.map((e) => e.id));
    const fresh = ids.find((id) => !known.has(id));
    if (fresh) {
      const element = await page.$(`iframe[id="${fresh}"]`);
      const frame = await element.contentFrame();
      if (frame && frame.url() && frame.url() !== "about:blank") {
        const attributes = await element.evaluate((e) => ({
          id: e.id, src: e.getAttribute("src"), sandbox: e.getAttribute("sandbox"), allow: e.getAttribute("allow"),
        }));
        return { element, frame, attributes };
      }
    }
    await sleep(20);
  }
  throw new Error("no frame opened");
}

// Close the shown frame `id` from the shell's capsule: the shell revokes
// its credential and removes it.
export async function closeFrame(page, id) {
  await page.locator('button[phx-click="close_active_tincture"]:visible').click();
  await page.waitForFunction((frameId) => !document.getElementById(frameId), id, { timeout: 30_000 });
}

export async function waitFor(check, { timeoutMs = 30_000, stepMs = 25, what = "a condition" } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(stepMs);
  }
}

// p50, p95 and p99 of `values` (nearest rank), with the count.
export function percentiles(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const rank = (p) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))];
  return sorted.length
    ? { n: sorted.length, p50: rank(50), p95: rank(95), p99: rank(99) }
    : { n: 0, p50: null, p95: null, p99: null };
}

export const BROWSERS = ["chromium", "firefox", "webkit"];
