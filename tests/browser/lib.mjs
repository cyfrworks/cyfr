// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// What the browser harness's experiments share: the proxy every browser
// reaches the servers through and its TLS front for the homes, the
// browsers launched to trust the run's authority, the attacker's receiver,
// the signed-in shell, the harness's own pages and the checks made with
// them, Chromium's virtual WebAuthn authenticator, and the percentiles of a
// measurement.
//
// A single cell is reached under the name `cyfr.test` over plain HTTP (a
// name no browser exempts from its proxy, as each exempts loopback
// addresses differently), and the server is started with
// CYFR_HOST=cyfr.test, so the origin the browsers see is the origin the
// server derives its policies for: a tincture document's `frame-ancestors`
// and `connect-src` name it. The proxy forwards every request and WebSocket
// upgrade for `cyfr.test` to the server unchanged, hands every request for
// `attacker.test` to the receiver, and keeps an account of each request
// that reached the network. An experiment may answer a path itself
// (`answer`), as the frame-facts experiment answers a redirect no route
// makes.
//
// The homes of a run (tests/browser/harness.sh `browser_home`) are cells on
// `.test` hostnames of their own, several at once, reached at https://HOST:
// a browser asks the proxy for a tunnel to HOST, and the proxy hands the
// tunnel to its TLS front, which presents the certificate the run's
// authority issued for HOST and forwards each request and WebSocket upgrade
// to the home's listener as the stack's Caddy forwards to cyfr, with
// X-Forwarded-For, -Proto and -Host. The front answers the harness's own
// pages (HARNESS) on every home itself, and accounts for every request, the
// cookies it carried and the cookies its answer set. A name the proxy does
// not route gets no tunnel, and a home answers HTTPS alone.

import { createServer, request as forward } from "node:http";
import { createServer as createFront } from "node:https";
import { createSecureContext } from "node:tls";
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { chromium, firefox, webkit } from "playwright-core";
import { connect } from "node:net";

export { chromium, firefox, webkit };

export const SITE = "cyfr.test";
export const ATTACKER = "attacker.test";
// Where the run's authority is mounted (harness.sh `playwright_run`).
export const AUTHORITY = "/authority";
// The harness's own pages, which the front answers on every home.
export const HARNESS = "/__harness";

// The LiveView socket's long-poll transport, which the client falls back to
// when its WebSocket is refused.
const LONGPOLL = /^\/live\/longpoll/;
const MAX_BODY = 256 * 1024;
// How long a home has to answer the check that it answers at all.
const HOME_ANSWER_MS = 10_000;

// The run's homes and the names its authority did not sign
// (/authority/homes.json, harness.sh `browser_homes_file`): each with its
// name, hostname, origin, the port of the listener its requests go to, and
// the certificate and key the front presents for it.
export function readHomes(file = `${AUTHORITY}/homes.json`) {
  const { homes, unsigned } = JSON.parse(readFileSync(file, "utf8"));
  const site = (row) => ({ ...row, origin: `https://${row.host}` });
  return { homes: homes.map(site), unsigned: unsigned.map(site) };
}

// The harness's proxy. `answer(req, url)` may answer a request itself by
// returning [status, headers, body]; anything else goes to its host. With
// `bodies`, each request's body (its first 256 KiB, as text) is kept in its
// account as `body`. `proxy.cut(host)` refuses the LiveView socket of
// `host`, or of every host without one — every WebSocket tunnel open or
// asked for, and its long-poll fallback — until `proxy.restore(host)`;
// every other request still goes through.
//
// `server` is the single cell's URL, or null when the run has homes alone.
// With `homes` (and `unsigned`, from `readHomes`), the proxy is returned
// once every home answers on its hostname, and otherwise throws naming each
// cell that does not. `proxy.refusals` lists each TLS handshake a browser
// broke off, with the name it asked for.
export async function startProxy(server, {
  receiver = null, answer = () => null, bodies = false, homes = [], unsigned = [],
} = {}) {
  const target = server ? new URL(server) : null;
  const routes = new Map([...homes, ...unsigned].map((route) => [route.host, route]));
  const tunnels = new Set();
  const cuts = new Set();
  const isCut = (host) => cuts.has("*") || cuts.has(host);
  // A tunnel's two ends, so a cut closes the server's end too and the
  // server sees the socket go, and a server that goes closes the browser's
  // end as its own connection's close would.
  const hold = (socket, upstream, host) => {
    const pair = { socket, upstream, host };
    tunnels.add(pair);
    socket.on("close", () => {
      tunnels.delete(pair);
      upstream.destroy();
    });
    upstream.on("close", () => socket.destroy());
  };
  const proxy = createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const account = {
      at: Date.now(),
      method: req.method,
      url: url.href,
      host: url.hostname,
      origin: req.headers.origin ?? null,
      referer: req.headers.referer ?? null,
      cookie: !!req.headers.cookie,
      fetch: {
        site: req.headers["sec-fetch-site"] ?? null,
        dest: req.headers["sec-fetch-dest"] ?? null,
        mode: req.headers["sec-fetch-mode"] ?? null,
      },
      conditional: !!(req.headers["if-none-match"] || req.headers["if-modified-since"]),
    };
    proxy.seen.push(account);
    if (bodies) {
      account.body = "";
      req.on("data", (chunk) => {
        if (account.body.length < MAX_BODY) account.body += chunk.toString("utf8");
      });
    }
    if (isCut(SITE) && url.hostname === SITE && LONGPOLL.test(url.pathname)) {
      account.status = 503;
      res.writeHead(503, { "content-type": "text/plain" });
      res.end("proxy: the socket is cut");
      req.resume();
      return;
    }
    const own = answer(req, url);
    if (own) {
      const [status, headers, body] = own;
      res.writeHead(status, headers);
      res.end(body ?? "");
      return;
    }
    const upstream = url.hostname === ATTACKER && receiver ? receiver.address() : null;
    // A home answers HTTPS alone, and a run of homes alone has no server
    // for any other name.
    if (!upstream && (!target || routes.has(url.hostname))) {
      account.status = 421;
      res.writeHead(421, { "content-type": "text/plain" });
      res.end(`proxy: ${url.hostname} is not answered over plain HTTP`);
      req.resume();
      return;
    }
    const options = upstream
      ? { host: "127.0.0.1", port: upstream.port }
      : { host: target.hostname, port: target.port };
    const outbound = forward(
      { ...options, method: req.method, path: url.pathname + url.search, headers: req.headers },
      (reply) => {
        const seen = proxy.seen.findLast((r) => r.url === url.href);
        if (seen) seen.status = reply.statusCode;
        res.writeHead(reply.statusCode, reply.rawHeaders);
        // An answer the server cut off mid-way is cut off for the browser
        // too, as the server's own connection would be.
        reply.on("close", () => {
          if (!reply.complete) res.destroy();
        });
        reply.pipe(res);
      });
    outbound.on("error", (error) => {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`proxy: ${error.message}`);
    });
    req.pipe(outbound);
  });
  // The shell's LiveView socket: the upgrade request goes to the server
  // as it came, and the two sockets are joined.
  proxy.on("upgrade", (req, socket, head) => {
    if (!target || isCut(SITE)) {
      socket.destroy();
      return;
    }
    const upstream = connect(Number(target.port), target.hostname, () => {
      const lines = [`${req.method} ${new URL(req.url, `http://${req.headers.host}`).pathname +
        (new URL(req.url, `http://${req.headers.host}`).search)} HTTP/1.1`];
      for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
      upstream.write(lines.join("\r\n") + "\r\n\r\n");
      if (head && head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
    hold(socket, upstream, SITE);
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });
  // A browser tunnels HTTPS and a WebSocket through an HTTP proxy with
  // CONNECT: a home's tunnel goes to the TLS front, and any other to the
  // named host's listener.
  const front = startFront(proxy, routes, { answer, bodies, isCut, hold });
  proxy.on("connect", (req, socket, head) => {
    const [host] = req.url.split(":");
    const toAttacker = host === ATTACKER && receiver;
    if (routes.has(host)) {
      proxy.seen.push({ at: Date.now(), method: "CONNECT", url: req.url, host, origin: null, referer: null, conditional: false });
      socket.on("error", () => socket.destroy());
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head && head.length) socket.unshift(head);
      front.emit("connection", socket);
      return;
    }
    if (!target && !toAttacker) {
      socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
      return;
    }
    const port = toAttacker ? receiver.address().port : Number(target.port);
    const address = toAttacker ? "127.0.0.1" : target.hostname;
    proxy.seen.push({ at: Date.now(), method: "CONNECT", url: req.url, host, origin: null, referer: null, conditional: false });
    if (isCut(SITE) && host === SITE) {
      socket.destroy();
      return;
    }
    const upstream = connect(port, address, () => {
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head && head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
    if (host === SITE) hold(socket, upstream, SITE);
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });
  proxy.seen = [];
  proxy.refusals = [];
  proxy.cut = (host = "*") => {
    cuts.add(host);
    for (const pair of tunnels) {
      if (host !== "*" && pair.host !== host) continue;
      pair.socket.destroy();
      pair.upstream.destroy();
      tunnels.delete(pair);
    }
  };
  proxy.restore = (host = "*") => {
    if (host === "*") cuts.clear();
    else cuts.delete(host);
  };
  await new Promise((resolve) => proxy.listen(0, "127.0.0.1", resolve));

  const silent = (await Promise.all(homes.map(async (home) => [home, await answers(home)])))
    .filter(([, why]) => why);
  if (silent.length) {
    proxy.close();
    throw new Error(silent.map(([home, why]) =>
      `the cell ${home.name} does not answer on its hostname ${home.host} (127.0.0.1:${home.port}): ${why}`).join("; "));
  }
  return proxy;
}

// The front that terminates TLS for every routed name, with the
// certificate the harness made for it, and forwards to the name's
// listener. A request whose Host is not the name its handshake asked for
// is misdirected (421).
function startFront(proxy, routes, { answer, bodies, isCut, hold }) {
  const contexts = new Map([...routes.values()].map((route) =>
    [route.host, createSecureContext({ cert: readFileSync(route.cert), key: readFileSync(route.key) })]));
  const hostOf = (req) => (req.headers.host ?? "").replace(/:\d+$/, "");
  const routed = (req) => {
    const host = hostOf(req);
    const route = routes.get(host);
    return route && req.socket.servername === host ? route : null;
  };
  // What the stack's Caddy sends beside the request: the browser's address,
  // the scheme and the host it asked for, never a browser's own claim.
  const forwarded = (req) => ({
    "x-forwarded-for": (req.socket.remoteAddress ?? "127.0.0.1").replace(/^::ffff:/, ""),
    "x-forwarded-proto": "https",
    "x-forwarded-host": req.headers.host,
  });
  const own = (headers) => Object.fromEntries(
    Object.entries(headers).filter(([name]) => !name.startsWith("x-forwarded-")));

  const front = createFront({ SNICallback: (name, done) => done(null, contexts.get(name)) }, (req, res) => {
    const host = hostOf(req);
    const url = new URL(req.url, `https://${host}`);
    const route = routed(req);
    const account = {
      at: Date.now(),
      method: req.method,
      url: url.href,
      host,
      home: route ? route.name : null,
      origin: req.headers.origin ?? null,
      referer: req.headers.referer ?? null,
      cookie: !!req.headers.cookie,
      cookies: cookiePairs(req.headers.cookie),
      fetch: {
        site: req.headers["sec-fetch-site"] ?? null,
        dest: req.headers["sec-fetch-dest"] ?? null,
        mode: req.headers["sec-fetch-mode"] ?? null,
      },
      conditional: !!(req.headers["if-none-match"] || req.headers["if-modified-since"]),
      setCookies: [],
    };
    proxy.seen.push(account);
    if (bodies) {
      account.body = "";
      req.on("data", (chunk) => {
        if (account.body.length < MAX_BODY) account.body += chunk.toString("utf8");
      });
    }
    const reply = (status, headers, body) => {
      account.status = status;
      res.writeHead(status, headers);
      res.end(body ?? "");
      req.resume();
    };
    if (!route) {
      reply(421, { "content-type": "text/plain" }, `proxy: ${host} is not the name this connection asked for`);
      return;
    }
    if (url.pathname.startsWith(`${HARNESS}/`)) {
      account.harness = url.pathname.slice(HARNESS.length + 1);
      reply(...harnessPage(url));
      return;
    }
    if (isCut(host) && LONGPOLL.test(url.pathname)) {
      reply(503, { "content-type": "text/plain" }, "proxy: the socket is cut");
      return;
    }
    const answered = answer(req, url);
    if (answered) {
      reply(...answered);
      return;
    }
    const outbound = forward(
      {
        host: "127.0.0.1", port: route.port, method: req.method, path: url.pathname + url.search,
        headers: { ...own(req.headers), ...forwarded(req) },
      },
      (upstream) => {
        account.setCookies = cookiePairs(upstream.headers["set-cookie"]);
        account.answered = {
          policy: upstream.headers["content-security-policy"] ?? null,
          frameOptions: upstream.headers["x-frame-options"] ?? null,
        };
        account.status = upstream.statusCode;
        res.writeHead(upstream.statusCode, upstream.rawHeaders);
        upstream.on("close", () => {
          if (!upstream.complete) res.destroy();
        });
        upstream.pipe(res);
      });
    outbound.on("error", (error) => {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      account.status = 502;
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`proxy: the cell ${route.name} does not answer on ${host} (127.0.0.1:${route.port}): ${error.message}`);
    });
    req.pipe(outbound);
  });
  // A home's LiveView socket, inside its TLS tunnel.
  front.on("upgrade", (req, socket, head) => {
    const host = hostOf(req);
    const url = new URL(req.url, `https://${host}`);
    const route = routed(req);
    proxy.seen.push({
      at: Date.now(), method: "UPGRADE", url: url.href, host, home: route ? route.name : null,
      origin: req.headers.origin ?? null, referer: null, cookie: !!req.headers.cookie,
      cookies: cookiePairs(req.headers.cookie), conditional: false, setCookies: [],
    });
    if (!route || isCut(host)) {
      socket.destroy();
      return;
    }
    const upstream = connect(route.port, "127.0.0.1", () => {
      const lines = [`${req.method} ${url.pathname}${url.search} HTTP/1.1`];
      for (let i = 0; i < req.rawHeaders.length; i += 2) {
        if (!req.rawHeaders[i].toLowerCase().startsWith("x-forwarded-")) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
      }
      for (const [name, value] of Object.entries(forwarded(req))) lines.push(`${name}: ${value}`);
      upstream.write(lines.join("\r\n") + "\r\n\r\n");
      if (head && head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
    hold(socket, upstream, host);
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });
  // A browser that refuses the certificate breaks the handshake off.
  front.on("tlsClientError", (error, socket) => {
    proxy.refusals.push({ at: Date.now(), host: socket.servername || null, error: error.code || error.message });
  });
  return front;
}

// Whether `home`'s cell answers its readiness check as its hostname, as the
// front would ask it: nothing when it does, and why not when it does not.
function answers(home) {
  return new Promise((resolve) => {
    const req = forward({
      host: "127.0.0.1", port: home.port, method: "GET", path: "/api/health/ready",
      headers: { host: home.host, "x-forwarded-for": "127.0.0.1", "x-forwarded-proto": "https", "x-forwarded-host": home.host },
      timeout: HOME_ANSWER_MS,
    }, (res) => {
      res.resume();
      resolve(res.statusCode === 200 ? null : `its readiness check answered ${res.statusCode}`);
    });
    req.on("timeout", () => req.destroy(new Error(`no answer within ${HOME_ANSWER_MS} ms`)));
    req.on("error", (error) => resolve(error.message));
    req.end();
  });
}

// Each `name=value` pair of a Cookie header, or of every Set-Cookie line.
function cookiePairs(header) {
  if (!header) return [];
  const lines = Array.isArray(header) ? header.map((line) => line.split(";")[0]) : header.split(";");
  return lines.map((pair) => pair.trim()).filter(Boolean).map((pair) => {
    const at = pair.indexOf("=");
    return at < 0 ? ["", pair] : [pair.slice(0, at), pair.slice(at + 1)];
  });
}

// The harness's own pages, which the front answers on every home and no
// cell ever serves: `page`, an empty document under no policy, which an
// experiment fills; `fragment`, which carries its fragment on to `?next=`
// by a top-level navigation of its own and, without `next`, is titled
// `arrived`.
function harnessPage(url) {
  const headers = { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" };
  const html = (title, script = "") =>
    `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title>${script}</head><body></body></html>`;
  switch (url.pathname) {
    case `${HARNESS}/page`:
      return [200, headers, html("harness")];
    case `${HARNESS}/fragment`:
      return [200, headers, html("relay", `<script>
        const next = new URLSearchParams(location.search).get("next");
        if (next) location.assign(next + location.hash);
        else document.title = "arrived";
      </script>`)];
    default:
      return [404, { "content-type": "text/plain" }, "no such harness page"];
  }
}

// A browser of the matrix, reaching everything through `proxy`. Inside a
// container with the run's authority every browser trusts it
// (harness.sh `playwright_run`); Chromium is launched as its full build,
// which reads the managed policy that says so, where its headless shell
// reads none.
export function launchBrowser(name, proxy, options = {}) {
  const type = { chromium, firefox, webkit }[name];
  if (!type) throw new Error(`no browser named ${name}`);
  return type.launch({
    ...(name === "chromium" ? { channel: "chromium" } : {}),
    ...options,
    proxy: { server: `http://127.0.0.1:${proxy.address().port}` },
  });
}

// Chromium's virtual WebAuthn authenticator for `page`: a platform
// authenticator that holds resident keys and verifies its user, present at
// every ceremony, as a passkey needs. `credentials()` lists what it holds;
// `add(credential)` gives it a credential another authenticator listed, as
// a synced passkey reaches another device of the person's, its count
// carried along so no home sees it fall; `remove()` takes it away.
// Chromium's alone: neither Firefox nor WebKit offers one to Playwright.
export async function virtualAuthenticator(page, options = {}) {
  const name = page.context().browser()?.browserType().name();
  if (name !== "chromium") throw new Error(`the virtual WebAuthn authenticator is Chromium's, not ${name}'s`);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("WebAuthn.enable", { enableUI: false });
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true,
      isUserVerified: true, automaticPresenceSimulation: true, ...options,
    },
  });
  return {
    id: authenticatorId,
    credentials: async () => (await cdp.send("WebAuthn.getCredentials", { authenticatorId })).credentials,
    add: (credential) => cdp.send("WebAuthn.addCredential", { authenticatorId, credential }),
    remove: async () => {
      await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
      await cdp.detach();
    },
  };
}

// What makes the page a secure context whose WebCrypto works: its
// protocol, `isSecureContext`, `crypto.subtle`, and a digest made with it.
export function secureContext(page) {
  return page.evaluate(async () => {
    let digest = false;
    try {
      digest = (await crypto.subtle.digest("SHA-256", new TextEncoder().encode("cyfr"))).byteLength === 32;
    } catch {
      digest = false;
    }
    return {
      url: location.href, protocol: location.protocol, secure: self.isSecureContext === true,
      subtle: !!(self.crypto && self.crypto.subtle), digest,
    };
  });
}

// The harness's fragment fixture: a fragment of `size` bytes carried from
// home `from` to home `to` and back by top-level navigations each page
// makes itself, as a carry travels, and read where it arrived. `intact`
// when what arrived is what was sent; `leaked` when any request the proxy
// saw carried it, in its address or its referrer.
export async function roundTripFragment(page, proxy, from, to, { size = 16 * 1024, timeoutMs = 30_000 } = {}) {
  const fragment = randomBytes(size).toString("base64url").slice(0, size);
  const relay = (home, next) => `${home.origin}${HARNESS}/fragment${next ? `?next=${encodeURIComponent(next)}` : ""}`;
  const home = relay(from);
  const mark = proxy.seen.length;
  await page.goto(`${relay(from, relay(to, home))}#${fragment}`, { waitUntil: "commit", timeout: timeoutMs });
  await page.waitForURL((url) => `${url.origin}${url.pathname}${url.search}` === home, { timeout: timeoutMs });
  await page.waitForFunction(() => document.title === "arrived", null, { timeout: timeoutMs });
  const arrived = (await page.evaluate(() => location.hash)).slice(1);
  const since = proxy.seen.slice(mark);
  const probe = fragment.slice(0, 64);
  return {
    size,
    intact: arrived === fragment,
    arrived: arrived.length,
    hops: since.filter((r) => r.harness === "fragment").map((r) => `${r.host} (${r.fetch.site})`),
    leaked: since.some((r) => r.url.includes(probe) || (r.referer ?? "").includes(probe)),
  };
}

// The request a page of `parent` makes for `path` of `target` into a
// frame, as the proxy saw it: its destination and site, the status the
// cell answered, and the names of the cookies that answer set.
export async function framedRequest(page, proxy, parent, target, path, { timeoutMs = 30_000 } = {}) {
  await page.goto(`${parent.origin}${HARNESS}/page`);
  const src = `${target.origin}${path}`;
  const mark = proxy.seen.length;
  await page.evaluate((url) => {
    const frame = document.createElement("iframe");
    frame.src = url;
    document.body.append(frame);
  }, src);
  const seen = await waitFor(
    () => proxy.seen.slice(mark).find((r) => r.url === src && r.method === "GET" && r.status !== undefined),
    { timeoutMs, what: `the framed request for ${src}` });
  return {
    url: src, dest: seen.fetch.dest, site: seen.fetch.site, status: seen.status,
    sets: seen.setCookies.map(([name]) => name),
  };
}

// Every request to one host that carried a cookie another host set, by
// its answer (a Set-Cookie the proxy saw) or by its script (`scripted`,
// each `{ host, name, value }`): `{ to, name, from }` for each.
export function crossedCookies(seen, scripted = []) {
  const setters = new Map();
  const set = (host, name, value) => {
    const key = `${name}=${value}`;
    if (!setters.has(key)) setters.set(key, new Set());
    setters.get(key).add(host);
  };
  for (const r of seen) for (const [name, value] of r.setCookies ?? []) set(r.host, name, value);
  for (const { host, name, value } of scripted) set(host, name, value);
  const crossed = [];
  for (const r of seen) {
    for (const [name, value] of r.cookies ?? []) {
      const hosts = setters.get(`${name}=${value}`);
      if (hosts && !hosts.has(r.host)) crossed.push({ to: r.host, name, from: [...hosts] });
    }
  }
  return crossed;
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
// leaves it (Secure on an https origin, as the server sets it there).
export async function signedIn(browser, base, cookie) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await context.addCookies([{
    name: "_cyfr_key", value: cookie, url: base, httpOnly: true, secure: new URL(base).protocol === "https:",
    sameSite: "Lax",
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
