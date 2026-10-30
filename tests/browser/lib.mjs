// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// What the browser harness's experiments share: the proxy every browser
// reaches the servers through and its TLS front for the homes, the
// browsers launched to trust the run's authority, the attacker's receiver,
// the signed-in shell, the harness's own pages and the checks made with
// them, Chromium's virtual WebAuthn authenticator, the percentiles of a
// measurement, the recovery code the system layer shows, and a proof's
// asks of its run.sh and the redaction of what it writes.
//
// Every cell of a run is a home (tests/browser/harness.sh `browser_home`):
// a public home of a `.test` hostname of its own, reached at https://HOST,
// one or several at once. A proof of one cell runs it as the home
// `cyfr.test` (`browser_cell`), so the origin the browsers see is the
// origin the server derives its policies for: a tincture document's
// `frame-ancestors` and `connect-src` name it. A browser asks the proxy
// for a tunnel to HOST (a name no browser exempts from its proxy, as each
// exempts loopback addresses differently), and the proxy hands the tunnel
// to its TLS front, which presents the certificate the run's authority
// issued for HOST and forwards each request and WebSocket upgrade to the
// home's proxy listener, the one that trusts forwarded headers, as the
// stack's Caddy forwards to cyfr's, with X-Forwarded-For, -Proto and
// -Host. The front answers the harness's own pages (HARNESS) on every home
// itself, and accounts for every request, the cookies it carried and the
// cookies its answer set. A name the proxy does not route gets no tunnel,
// and a home answers HTTPS alone. An experiment may answer a path of a
// home itself (`answer`), as the frame-facts experiment answers a redirect
// no route makes.
//
// The attacker's receiver is reached under the name `attacker.test`, over
// HTTPS through the front with the certificate the run's authority issued
// for it (`browser_attacker`), and over plain HTTP, as an origin a page
// may name either way; it is handed every request exactly as the browser
// sent it. The proxy keeps an account of each request that reached the
// network, a tunnel asked for among them.

import { createServer, request as forward } from "node:http";
import { createServer as createFront } from "node:https";
import { createSecureContext } from "node:tls";
import { existsSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { randomBytes } from "node:crypto";
import { connect } from "node:net";

// Playwright's library, where it is installed (harness.sh `playwright_run`
// mounts it). A run that launches no browser, such as the canvas proof's
// check of a saved record, uses this file without it, and any use of a
// browser type then throws the import's own error.
export const { chromium, firefox, webkit } = await import("playwright-core").catch((error) => {
  const absent = new Proxy({}, { get() { throw error; } });
  return { chromium: absent, firefox: absent, webkit: absent };
});

export const SITE = "cyfr.test";
export const ATTACKER = "attacker.test";
// Where the run's authority is mounted (harness.sh `playwright_run`).
const AUTHORITY = "/authority";
// The harness's own pages, which the front answers on every home.
export const HARNESS = "/__harness";

// The LiveView socket's long-poll transport, which the client falls back to
// when its WebSocket is refused.
const LONGPOLL = /^\/live\/longpoll/;
const MAX_BODY = 256 * 1024;
// How long a home has to answer the check that it answers at all.
const HOME_ANSWER_MS = 10_000;

// The run's homes, the names its authority did not sign and the attacker's
// name when the run has one (/authority/homes.json, harness.sh
// `browser_homes_file`): each with its name, hostname, origin and the
// certificate and key the front presents for it, and a home's and an
// unsigned name's the port of the proxy listener its requests go to.
export function readHomes(file = `${AUTHORITY}/homes.json`) {
  const { homes, unsigned, attacker = null } = JSON.parse(readFileSync(file, "utf8"));
  const site = (row) => ({ ...row, origin: `https://${row.host}` });
  return { homes: homes.map(site), unsigned: unsigned.map(site), attacker: attacker && site(attacker) };
}

// The home of `host` among `homes` (`readHomes`), or a throw naming it.
export function homeOf(homes, host = SITE) {
  const home = homes.find((h) => h.host === host);
  if (!home) throw new Error(`the run has no home named ${host}`);
  return home;
}

// Keep a listener for the socket's whole lifetime, including the idle
// interval after a response and the interval after HTTP hands off an
// upgrade. Only operations still using it are failed by a peer's reset.
const sockets = new WeakMap();
function watchSocket(socket, errors, peer, fail = null) {
  let state = sockets.get(socket);
  if (!state) {
    state = { active: new Set(), errors, peer };
    sockets.set(socket, state);
    // Observe the active owners before HTTP propagates the error and
    // settles their requests.
    socket.prependListener("error", (error) => {
      const entry = { at: Date.now(), peer: state.peer, code: error.code ?? null, message: error.message, active: state.active.size > 0 };
      state.errors.push(entry);
      console.error(`browser harness: ${entry.peer}: ${error.message} (${entry.active ? "request failed" : "idle connection"})`);
      for (const reject of [...state.active]) reject(error);
      socket.destroy();
    });
  }
  // An agent may reuse a readiness-check socket for a forwarded request.
  // Its current owner receives the record, including a later idle reset.
  state.errors = errors;
  state.peer = peer;
  if (fail) state.active.add(fail);
  return () => state.active.delete(fail);
}

function watchServer(server, errors, peer) {
  server.on("connection", (socket) => watchSocket(socket, errors, peer));
  server.on("secureConnection", (socket) => watchSocket(socket, errors, `${peer} TLS`));
  server.on("request", (req, res) => {
    const stop = watchSocket(req.socket, errors, peer, (error) => res.destroy(error));
    req.on("error", (error) => res.destroy(error));
    res.on("error", () => req.destroy());
    res.once("finish", stop);
    res.once("close", stop);
  });
}

// Both forwarding paths own the incoming streams, the outgoing request
// and its response. A partial response fails the request too; an error
// listener on ClientRequest alone does not cover IncomingMessage.
function relay(req, res, account, errors, options, peer, answered = () => {}) {
  let done = false;
  let outbound;
  const release = [watchSocket(req.socket, errors, "browser", fail)];
  function finish() {
    done = true;
    for (const stop of release) stop();
  }
  function fail(error) {
    if (done) return;
    account.error = error.message;
    finish();
    outbound?.destroy();
    if (res.destroyed) return;
    if (res.headersSent) res.destroy(error);
    else {
      account.status = 502;
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(`proxy: ${peer}: ${error.message}`);
    }
  }
  req.on("error", fail);
  res.on("error", fail);
  res.once("finish", finish);
  res.once("close", () => {
    if (!done) outbound?.destroy();
    finish();
  });
  outbound = forward(options, (upstream) => {
    upstream.on("error", fail);
    upstream.once("close", () => {
      if (!upstream.complete) fail(new Error("the upstream response closed before completing"));
    });
    if (done) {
      upstream.resume();
      return;
    }
    answered(upstream);
    account.status = upstream.statusCode;
    res.writeHead(upstream.statusCode, upstream.rawHeaders);
    upstream.pipe(res);
  });
  outbound.on("socket", (socket) => {
    const stop = watchSocket(socket, errors, peer, fail);
    if (done) stop();
    else release.push(stop);
  });
  outbound.on("error", fail);
  req.pipe(outbound);
}

// The harness's proxy. `answer(req, url)` may answer a request for a home
// itself by returning [status, headers, body]; anything else goes to its
// home. With `bodies`, each request's body (its first 256 KiB, as text) is
// kept in its account as `body`. `proxy.cut(host)` refuses the LiveView
// socket of `host`, or of every host without one — every WebSocket tunnel
// open or asked for, and its long-poll fallback — until
// `proxy.restore(host)`; every other request still goes through.
//
// `homes` and `unsigned` are `readHomes`'s; the proxy is returned once
// every home answers on its hostname, and otherwise throws naming each cell
// that does not. With `receiver` (`startReceiver`), every request for
// `attacker.test` over plain HTTP goes to it, and with `attacker` too
// (`readHomes`), every one over HTTPS. `proxy.refusals` lists each TLS
// handshake a browser broke off, with the name it asked for. `proxy.errors`
// records socket errors, including whether a request or WebSocket was
// active; a failed forwarded request also carries `error` in `proxy.seen`.
export async function startProxy({
  receiver = null, answer = () => null, bodies = false, homes = [], unsigned = [], attacker = null,
} = {}) {
  const routes = new Map([...homes, ...unsigned].map((route) => [route.host, route]));
  if (attacker && receiver) routes.set(attacker.host, { ...attacker, receiver });
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
  // Plain HTTP reaches the receiver alone: a home answers HTTPS alone, and
  // the run has no server for any other name.
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
    if (url.hostname !== ATTACKER || !receiver) {
      account.status = 421;
      res.writeHead(421, { "content-type": "text/plain" });
      res.end(`proxy: ${url.hostname} is not answered over plain HTTP`);
      req.resume();
      return;
    }
    toReceiver(receiver, req, res, url, account, proxy.errors);
  });
  proxy.seen = [];
  proxy.refusals = [];
  proxy.errors = [];
  watchServer(proxy, proxy.errors, "proxy");
  // A browser tunnels HTTPS and a WebSocket through an HTTP proxy with
  // CONNECT: a routed name's tunnel goes to the TLS front, and no other is
  // opened.
  const front = startFront(proxy, routes, { answer, bodies, isCut, hold });
  proxy.on("connect", (req, socket, head) => {
    const [host] = req.url.split(":");
    if (!routes.has(host)) {
      socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
      return;
    }
    proxy.seen.push({ at: Date.now(), method: "CONNECT", url: req.url, host, origin: null, referer: null, conditional: false });
    socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head && head.length) socket.unshift(head);
    front.emit("connection", socket);
  });
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
// certificate the harness made for it, and forwards a home's requests to
// its proxy listener and the attacker's to the receiver, as they came. A
// request whose Host is not the name its handshake asked for is
// misdirected (421).
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
    if (route.receiver) {
      toReceiver(route.receiver, req, res, url, account, proxy.errors);
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
    relay(req, res, account, proxy.errors,
      {
        host: "127.0.0.1", port: route.port, method: req.method, path: url.pathname + url.search,
        headers: { ...own(req.headers), ...forwarded(req) },
      },
      `the cell ${route.name} on ${host} (127.0.0.1:${route.port})`, (upstream) => {
        account.setCookies = cookiePairs(upstream.headers["set-cookie"]);
        account.answered = {
          policy: upstream.headers["content-security-policy"] ?? null,
          frameOptions: upstream.headers["x-frame-options"] ?? null,
        };
      });
  });
  watchServer(front, proxy.errors, "front");
  // A home's LiveView socket, inside its TLS tunnel.
  front.on("upgrade", (req, socket, head) => {
    const host = hostOf(req);
    const url = new URL(req.url, `https://${host}`);
    const route = routed(req);
    const account = {
      at: Date.now(), method: "UPGRADE", url: url.href, host, home: route ? route.name : null,
      origin: req.headers.origin ?? null, referer: null, cookie: !!req.headers.cookie,
      cookies: cookiePairs(req.headers.cookie), conditional: false, setCookies: [],
    };
    proxy.seen.push(account);
    if (!route || route.receiver || isCut(host)) {
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
    const stopUpstream = watchSocket(upstream, proxy.errors, `the ${host} WebSocket`, (error) => {
      account.error = error.message;
      socket.destroy();
    });
    const stopSocket = watchSocket(socket, proxy.errors, "browser WebSocket", (error) => {
      account.error = error.message;
      upstream.destroy();
    });
    const finished = () => {
      stopUpstream();
      stopSocket();
    };
    upstream.once("close", finished);
    socket.once("close", finished);
  });
  // A browser that refuses the certificate breaks the handshake off.
  front.on("tlsClientError", (error, socket) => {
    watchSocket(socket, proxy.errors, "front TLS handshake");
    proxy.refusals.push({ at: Date.now(), host: socket.servername || null, error: error.code || error.message });
  });
  return front;
}

// A request for the attacker's name handed to `receiver` exactly as the
// browser sent it, its answer back the same.
function toReceiver(receiver, req, res, url, account, errors) {
  relay(req, res, account, errors,
    { host: "127.0.0.1", port: receiver.address().port, method: req.method, path: url.pathname + url.search, headers: req.headers },
    "the receiver");
}

// Whether `home`'s cell answers its readiness check as its hostname on its
// proxy listener, as the front would ask it: nothing when it does, and why
// not when it does not.
async function answers(home) {
  try {
    const { status } = await askHome(home, "/api/health/ready", {}, { timeoutMs: HOME_ANSWER_MS });
    return status === 200 ? null : `its readiness check answered ${status}`;
  } catch (error) {
    return error.message;
  }
}

// A GET of `path` from `home`'s cell as the front forwards a browser's
// request for it, with `headers` beside the front's own: its status, its
// headers and its body as text. A check of the server itself, which no
// browser makes.
export function askHome(home, path, headers = {}, { timeoutMs = 30_000 } = {}) {
  return new Promise((resolve, reject) => {
    const errors = [];
    let stop = () => {};
    let done = false;
    const finish = (error, answer) => {
      if (done) return;
      done = true;
      stop();
      if (error) reject(error);
      else resolve(answer);
    };
    const req = forward({
      host: "127.0.0.1", port: home.port, method: "GET", path,
      headers: {
        ...headers, host: home.host,
        "x-forwarded-for": "127.0.0.1", "x-forwarded-proto": "https", "x-forwarded-host": home.host,
      },
      timeout: timeoutMs,
    }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("error", (error) => finish(error));
      res.on("end", () => finish(null, { status: res.statusCode, headers: res.headers, body }));
    });
    req.on("socket", (socket) => {
      stop = watchSocket(socket, errors, `askHome ${home.host}`, (error) => finish(error));
      if (done) stop();
    });
    req.on("timeout", () => req.destroy(new Error(`no answer within ${timeoutMs} ms`)));
    req.on("error", (error) => finish(error));
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
  receiver.errors = [];
  watchServer(receiver, receiver.errors, "receiver");
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
  const url = `${base}/a/${encodeURIComponent(segment)}/canvas?publisher=local&tincture_name=${encodeURIComponent(name)}`;
  await page.goto(url);
  await page.waitForSelector(".phx-connected", { timeout: 30_000 });
  await launchButton(page, name).waitFor({ timeout: 30_000 });
}

const launchButton = (page, name) =>
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

// ---------------------------------------------------------------------------
// The glass, shared by the proofs that pair one
// ---------------------------------------------------------------------------

// The glass's device channel, watched from inside its own page: an init
// script (`context.addInitScript(instrumentDevice)`) that logs, on
// `window.__device`, each frame of every device socket, in or out, as its
// type, id and error class, and each socket's close.
export function instrumentDevice() {
  const Native = window.WebSocket;
  const device = { log: [], sockets: 0 };
  window.__device = device;
  const describe = (data) => {
    try {
      const map = JSON.parse(data);
      return { type: map.type, id: map.id, error: map.error ? (map.error.class || "error") : undefined };
    } catch {
      return { type: "unreadable" };
    }
  };
  class Watched extends Native {
    constructor(url, protocols) {
      super(url, protocols);
      if (!/\/device\/websocket/.test(String(url))) return;
      this.__serial = ++device.sockets;
      super.addEventListener("message", (event) => device.log.push({ socket: this.__serial, dir: "in", ...describe(event.data) }));
      super.addEventListener("close", (event) => device.log.push({ socket: this.__serial, event: "close", code: event.code }));
    }
    send(data) {
      if (this.__serial) device.log.push({ socket: this.__serial, dir: "out", ...describe(data) });
      return super.send(data);
    }
  }
  window.WebSocket = Watched;
}

// ---------------------------------------------------------------------------
// The recovery code the system layer shows
// ---------------------------------------------------------------------------

// The system layer's own reader of a recovery code, imported the first time
// a proof reads one: from the checkout beside this file, or, inside the
// Playwright container, which runs a copy of tests/browser apart from the
// checkout, from the console's assets it mounts at /assets (harness.sh
// `playwright_run`).
const READER = "js/system_layer/recovery_code.js";
let reader = null;
function recoveryCodeReader() {
  if (!reader) {
    const beside = new URL(`../../apps/cyfr/assets/${READER}`, import.meta.url);
    reader = import(existsSync(beside) ? beside.href : pathToFileURL(`/assets/${READER}`).href);
  }
  return reader;
}

// The recovery code the system layer's prompt shows, read as the person
// reads it, and decoded by that reader: `{code, identifier, secret}`, the
// code as shown, the identifier it names and its 32-byte secret in
// unpadded base64url. `secrets` is the proof's list of what it handled
// and never writes (`redact`): the code joins it as soon as it is read,
// before it is decoded, and its secret once decoded. A code that does not
// read throws, naming its refusal and never the code.
export async function readCode(page, secrets) {
  const shown = '#system-layer-dialog [data-recovery-code]:not([hidden]) [data-test="recovery-code"]';
  await page.waitForSelector(shown, { timeout: 60_000 });
  const code = (await page.locator(shown).textContent()).trim();
  secrets.push(code);
  const { decodeRecoveryCode } = await recoveryCodeReader();
  const read = await decodeRecoveryCode(code);
  if (read.error) throw new Error(`the recovery code the system layer shows does not read: ${read.error}`);
  secrets.push(read.secret);
  return { code, identifier: read.identifier, secret: read.secret };
}

// Say the recovery code the system layer shows is saved ("I saved it"),
// and wait for the layer to close.
export async function saveCode(page) {
  await page.locator('#system-layer-dialog [data-test="recovery-ack"]').click();
  await page.waitForFunction(() => !document.getElementById("system-layer-dialog")?.open, null, { timeout: 30_000 });
}

// ---------------------------------------------------------------------------
// A proof's asks of its run.sh, and what it may write
// ---------------------------------------------------------------------------

let asks = 0;

// The server's part of a step, asked of the proof's run.sh through the
// output directory `outDir`: `request` is written as ask-N.json,
// whole once it appears, and the answer is read from answer-N.json, which
// run.sh writes aside and renames (harness.sh `answer_asks`, which removes
// the ask first). N counts this process's asks from 1. Where proofs ask
// differently, the difference is an option: `timeoutMs`, how long run.sh
// has to answer; `secret`, the answer is removed once read; `refuseError`,
// an answer naming an `error` throws unless the request says `tolerate`;
// `answers`, a list each answer's text is added to as read.
export async function ask(request, { outDir, timeoutMs = 120_000, secret = false, refuseError = false, answers = null } = {}) {
  const id = ++asks;
  const answer = join(outDir, `answer-${id}.json`);
  writeFileSync(join(outDir, `ask-${id}.part`), JSON.stringify(request));
  renameSync(join(outDir, `ask-${id}.part`), join(outDir, `ask-${id}.json`));
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(answer)) {
    if (Date.now() > deadline) throw new Error(`run.sh never answered ${request.op} within ${timeoutMs} ms`);
    await sleep(100);
  }
  const text = readFileSync(answer, "utf8");
  if (secret) {
    rmSync(answer, { force: true });
    rmSync(join(outDir, `ask-${id}.json`), { force: true });
  }
  if (answers) answers.push(text);
  const answered = JSON.parse(text);
  if (refuseError && answered.error && !request.tolerate) throw new Error(`run.sh: ${request.op}: ${answered.error}`);
  return answered;
}

// The marker a known secret, and a secret-named value, is replaced by.
export const MARKER = "[secret]";

const SECRET_KEYS = ["session", "static", "_csrf_token", "token", "plan_token", "proof"];
const KEYED = new RegExp(`((?:\\\\)?"(?:${SECRET_KEYS.join("|")})(?:\\\\)?"\\s*:\\s*(?:\\\\)?")(?:[^"\\\\]|\\\\(?!"))*`, "g");
const SECRET_ATTRIBUTES = ["data-phx-session", "data-phx-static", "data-csrf"];
const ATTRIBUTE = new RegExp(`((?:${SECRET_ATTRIBUTES.join("|")})=(?:\\\\)?")(?:[^"\\\\]|\\\\(?!"))*`, "g");
// The shortest part of a known value, at the text's end, that is replaced.
const TAIL = 4;

// `text` as a proof may write it, in a record, a log line or a failed run's
// frames. Every value of `secrets` is replaced by MARKER, and so is its
// first four or more characters where the text ends with them (a line or
// frame cut short may end inside one). So is the value of a `session`,
// `static`, `_csrf_token`, `token`, `plan_token` or `proof` key, and of a
// `data-phx-session`, `data-phx-static` or `data-csrf` attribute, quoted
// plainly or escaped inside JSON, to its closing quote or the text's end.
// A served prefix's or a host page's asset credential (`/_s/…`,
// `/_c/v1/…`), whole or cut short, becomes `[credential]`, a signed token
// `[signed token]`, and a bearer's credential MARKER. None of those three
// values takes a backslash, so a value before an escaped quote leaves the
// escape, and JSON text stays JSON. Applied again, it changes nothing.
export function redact(text, secrets = []) {
  let out = String(text);
  for (const secret of secrets) {
    if (!secret) continue;
    out = out.split(secret).join(MARKER);
    for (let n = secret.length - 1; n >= TAIL; n--) {
      if (out.endsWith(secret.slice(0, n))) {
        out = out.slice(0, -n) + MARKER;
        break;
      }
    }
  }
  return out
    .replace(KEYED, `$1${MARKER}`)
    .replace(ATTRIBUTE, `$1${MARKER}`)
    .replace(/\/_s\/(?!\[credential\])[^/"'\s\\]+/g, "/_s/[credential]")
    .replace(/\/_c\/v1\/(?!\[credential\])[^/"'\s\\]+/g, "/_c/v1/[credential]")
    .replace(/SFMyNTY\.[A-Za-z0-9_\-.]*/g, "[signed token]")
    .replace(/(Bearer\s+)(?!\[secret\])[^\s"'\\]+/gi, `$1${MARKER}`);
}

// The tokens a page holds as its frames are written, each a value a reply
// may have carried: its CSRF meta tag, a form's hidden `_csrf_token`, and
// each view's `data-phx-session`, `data-phx-static` and `data-csrf`. A
// page that cannot answer within five seconds gives none, and what is
// written keeps only what `redact`'s rules by name replace.
export async function pageTokens(page) {
  const read = page.evaluate(() =>
    [...document.querySelectorAll(
      "meta[name='csrf-token'], input[name='_csrf_token'], [data-phx-session], [data-phx-static], [data-csrf]",
    )].flatMap((el) => ["content", "value", "data-phx-session", "data-phx-static", "data-csrf"]
      .map((name) => el.getAttribute(name))));
  const late = new Promise((resolve) => setTimeout(() => resolve([]), 5_000).unref());
  const values = await Promise.race([read, late]).catch(() => []);
  return values.filter((v) => typeof v === "string" && v.length >= 8);
}

// A page's socket frames as a failed run writes them.
export function redactFrames(frames, secrets) {
  return frames.map((frame) => ({ ...frame, data: redact(frame.data, secrets) }));
}

// A record as any run writes it: a step's answer may carry what the frames
// do (a preview's `proof`), so the record passes the same rule.
export function recordText(value, secrets) {
  return redact(JSON.stringify(value, null, 2), secrets);
}
