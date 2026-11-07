// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// A test device: a client of a CYFR's device channel (`/device/websocket`,
// the wire `cyfr login` and a box's screen speak, `Emissary.Web.DeviceChannel`)
// that a proof drives frame by frame, in the proof's own process. It makes
// an Ed25519 key in memory, which never leaves this process, and shows its
// `pub` and `kid` so the proof puts the key on an account's log. Its first
// connection is its hello (`Prima.Device`, tests/fixtures/device.json): it
// names its kid, the account and, when it brings one, the setup token or
// an invitation's code, as a software-held device (an honest client's
// report: the CYFR cannot see where a key is held); it answers the CYFR's
// sign-in request with Ed25519 over the request's digest
// (tests/fixtures/sign_in.json), takes the client and certificate it is
// admitted with, and connects under them on the same connection. It
// renews the certificate when the CYFR will not take it, or on an open
// connection when asked, and sends intents. Every frame either way, and the close with its code, is logged
// by type; no signature, nonce, token, code or argument is kept in the
// log. A proof reaches the CYFR as the browsers do: an HTTP CONNECT through
// the run's proxy to the CYFR's name, TLS under the run's authority
// (/authority/authority.pem), then the request or the WebSocket upgrade.
//
// The proof uses it where a device's channel is what is proven (an intent's
// time, a certificate's expiry, a revocation's close); a person's own
// device steps run the real `cyfr` binary.

import { createHash, generateKeyPairSync, randomBytes, sign as edSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { connect as tlsConnect } from "node:tls";

export const DEVICE_PROTOCOL = "cyfr-device/v1";
const PROOF_PROTOCOL = "cyfr-device-proof/v1";
const b64url = (bytes) => Buffer.from(bytes).toString("base64url");

// The JCS bytes of a JSON value (RFC 8785) for the values a challenge
// holds: objects with ASCII keys, strings, integers and booleans.
export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

// A key's kid as an account's log lists it: `sha256:` and the lowercase
// hex of SHA-256 over its 32 raw bytes.
export const kidOf = (raw) => `sha256:${createHash("sha256").update(raw).digest("hex")}`;

// A TLS connection to the home `host` through the proxy at `proxyPort`.
function tunnel(proxyPort, host) {
  return new Promise((resolve, reject) => {
    const connect = httpRequest({ host: "127.0.0.1", port: proxyPort, method: "CONNECT", path: `${host}:443` });
    connect.on("connect", (res, socket) => {
      if (res.statusCode !== 200) return reject(new Error(`the proxy refused ${host}: ${res.statusCode}`));
      const tls = tlsConnect({ socket, servername: host, ca: readFileSync("/authority/authority.pem") }, () => resolve(tls));
      tls.on("error", reject);
    });
    connect.on("error", reject);
    connect.end();
  });
}

// One HTTPS request to the home at `base`, answered `{status, headers, body}`.
async function fetchVia(proxyPort, base, path, { method = "GET", headers = {}, body = "" } = {}) {
  const host = new URL(base).hostname;
  const socket = await tunnel(proxyPort, host);
  return new Promise((resolve, reject) => {
    const req = httpsRequest({
      host, path, method, createConnection: () => socket,
      headers: { host, "content-length": Buffer.byteLength(body), ...headers },
    }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: text }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

// A tool called anonymously over the CYFR's `/mcp`, as the command line's
// own client calls one: its result, or `{error}`.
export async function mcpCall(proxyPort, base, tool, args) {
  // The request metadata the protocol version asks of every request, as
  // the command line's client sends it.
  const _meta = {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": { name: "cyfr-proof-test-device", version: "0" },
    "io.modelcontextprotocol/clientCapabilities": {},
  };
  const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool, arguments: args, _meta } });
  const res = await fetchVia(proxyPort, base, "/mcp", {
    method: "POST", body,
    headers: {
      "content-type": "application/json", accept: "application/json, text/event-stream",
      "mcp-protocol-version": "2026-07-28", "mcp-method": "tools/call", "mcp-name": tool,
    },
  });
  const text = String(res.headers["content-type"] || "").startsWith("text/event-stream")
    ? res.body.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).at(-1)
    : res.body;
  const answer = JSON.parse(text || "{}");
  if (answer.error) return { error: answer.error };
  const result = answer.result || {};
  const content = (result.content || []).find((c) => c.type === "text");
  const parsed = content ? JSON.parse(content.text) : result.structuredContent || {};
  return result.isError ? { error: parsed } : parsed;
}

// A new test device: its key, made here and held in memory alone. `pub`
// (unpadded base64url of the 32 raw bytes) and `kid` are what an account's
// `add_key` names; `name` is the name its hello shows.
export function newDevice({ name = "proof test device" } = {}) {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url");
  const pub = b64url(raw);
  return { name, privateKey, pub, kid: kidOf(raw), clientId: null, certificate: null };
}

// The challenge `challenge`, held to what this device asked for, signed:
// its fields and `sig` over their JCS bytes.
export function prove(device, challenge, expect) {
  for (const [field, value] of Object.entries({ protocol: PROOF_PROTOCOL, device_key: device.pub, ...expect })) {
    if (challenge[field] !== value) throw new Error(`the home's ${challenge.purpose} challenge names another ${field}`);
  }
  const sig = edSign(null, Buffer.from(canonical(challenge)), device.privateKey);
  return { ...challenge, sig: b64url(sig) };
}

// The device's answer to the CYFR's request `request` of the purpose it
// expects (`sign_in` for a hello, `confirm` for a confirmation it was
// asked to give), held to what this device asked for: Ed25519 over SHA-256
// of the request's JCS bytes, by this device's key, named by its kid.
export function answer(device, request, { home, purpose = "sign_in" }) {
  if (request.purpose !== purpose) throw new Error(`the CYFR asked a ${request.purpose} request, not ${purpose}`);
  if (request.audience !== home) throw new Error(`the CYFR's ${purpose} request names another audience`);
  const digest = createHash("sha256").update(canonical(request)).digest();
  return { challenge: request.challenge, kid: device.kid, sig: b64url(edSign(null, digest, device.privateKey)) };
}

// The WebSocket upgrade of `/device/websocket`, through the proxy.
async function upgrade(proxyPort, base) {
  const host = new URL(base).hostname;
  const socket = await tunnel(proxyPort, host);
  return new Promise((resolve, reject) => {
    const req = httpsRequest({
      host, path: "/device/websocket", createConnection: () => socket,
      headers: {
        host, connection: "Upgrade", upgrade: "websocket", "sec-websocket-version": "13",
        "sec-websocket-key": randomBytes(16).toString("base64"),
      },
    });
    req.on("upgrade", (_res, upgraded, head) => resolve({ socket: upgraded, head }));
    req.on("response", (res) => reject(new Error(`the home answered the upgrade ${res.statusCode}`)));
    req.on("error", reject);
    req.end();
  });
}

// A client frame: masked, as RFC 6455 requires of a client.
function frame(opcode, payload) {
  const data = Buffer.from(payload);
  const mask = randomBytes(4);
  const length = data.length < 126 ? Buffer.from([0x80 | data.length])
    : data.length < 65536 ? Buffer.from([0x80 | 126, data.length >> 8, data.length & 255])
      : (() => { const b = Buffer.alloc(9); b[0] = 0x80 | 127; b.writeBigUInt64BE(BigInt(data.length), 1); return b; })();
  const masked = Buffer.from(data.map((byte, i) => byte ^ mask[i % 4]));
  return Buffer.concat([Buffer.from([0x80 | opcode]), length, mask, masked]);
}

// A device channel: `purpose` `connect` (or `renew`) under the device's
// certificate, its challenge held to the CYFR `home` names (`base` unless
// named: a proof that presents a certificate at another CYFR names the one
// it was issued for, so that CYFR's verdict is the one recorded), answered
// when the CYFR stands it (`opened`) or closes it (`closed`, the close
// code). With `hello` (`{identifier, admission}`, the account the device's
// key is listed in and the setup token or invitation code it brings, as
// `{setup: token}` or `{invitation: code}`, or none) the connection opens
// with the device's hello instead, answers the sign-in request, keeps the
// client and certificate `admitted` names, and connects under them.
// `intent` sends one and answers `{ok, result, error, ms}`; `asleep` stops
// reading frames, so nothing is answered, until `wake`. `log` holds every
// frame by direction and type, and each close and wake.
export function channel(device, { proxyPort, base, purpose = "connect", home = base, hello = null }) {
  const log = [];
  const waiting = new Map();
  let socket = null;
  let buffer = Buffer.alloc(0);
  let asleep = false;
  let socketClosed = false;
  let next = 0;
  let standing = null;
  // The purpose the next challenge must name: the connection's own, or
  // `renew` once the device asks to renew on it.
  let expecting = purpose;
  let renewed = null;
  let settle;
  const opened = new Promise((resolve) => { settle = resolve; });
  let closedWith;
  const closed = new Promise((resolve) => { closedWith = resolve; });
  const at = () => Date.now();

  const send = (message) => {
    const m = { protocol: DEVICE_PROTOCOL, ...message };
    log.push({ at: at(), dir: "out", type: m.type, operation: m.operation });
    socket.write(frame(1, JSON.stringify(m)));
  };

  const handle = (m) => {
    log.push({ at: at(), dir: "in", type: m.type, code: m.code, grant_id: m.grant_id, expires_at: m.expires_at });
    switch (m.type) {
      case "challenge":
        // A challenge this device would not sign ends the connection here,
        // as a device that refuses it closes its own.
        try {
          send({ type: "proof", proof: prove(device, m.challenge, { purpose: expecting, home, client_id: device.clientId }) });
        } catch (error) {
          log.push({ at: at(), event: "challenge_refused", error: error.message });
          socket.end();
          closedWith("challenge refused");
        }
        break;
      case "sign_in_request":
        // A request this device would not sign ends the connection here.
        try {
          send({ type: "sign_in_answer", answer: answer(device, m.request, { home }) });
        } catch (error) {
          log.push({ at: at(), event: "request_refused", error: error.message });
          socket.end();
          closedWith("request refused");
        }
        break;
      case "admitted":
        device.clientId = m.client_id;
        device.certificate = m.certificate;
        send({ type: "connect", client_id: device.clientId, certificate: device.certificate });
        break;
      case "certificate":
        device.certificate = m.certificate;
        expecting = purpose;
        if (renewed) {
          renewed({ certificate: m.certificate });
          renewed = null;
        }
        break;
      case "standing":
        standing = m;
        if (purpose && settle) {
          send({ type: "capabilities", capabilities: ["root_unknown", "data_unknown"] });
          settle({ standing: m });
          settle = null;
        }
        break;
      case "answer": {
        const w = waiting.get(m.id);
        if (w) {
          waiting.delete(m.id);
          w({ ok: !m.error, result: m.result, error: m.error || null, ms: at() - w.sent });
        }
        break;
      }
      default:
        break;
    }
  };

  const read = () => {
    while (!asleep && buffer.length >= 2) {
      const opcode = buffer[0] & 0x0f;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      if (buffer.length < offset + length) return;
      const payload = buffer.subarray(offset, offset + length);
      buffer = buffer.subarray(offset + length);
      if (opcode === 1) handle(JSON.parse(payload.toString("utf8")));
      else if (opcode === 9) socket.write(frame(10, payload));
      else if (opcode === 8) {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : null;
        log.push({ at: at(), event: "close", code });
        socket.end();
        closedWith(code);
      }
    }
  };

  (async () => {
    const up = await upgrade(proxyPort, base);
    socket = up.socket;
    buffer = Buffer.from(up.head || []);
    socket.on("data", (chunk) => { buffer = Buffer.concat([buffer, chunk]); read(); });
    // A connection the home ended while this device slept is read on
    // waking: its close frame is in the buffer.
    socket.on("close", () => {
      log.push({ at: at(), event: "socket_closed" });
      socketClosed = true;
      if (!asleep) closedWith(null);
    });
    socket.on("error", () => closedWith(null));
    if (hello) {
      send({
        type: "hello", kid: device.kid, identifier: hello.identifier, holder_kind: "software",
        display_name: device.name, ...(hello.admission ? { admission: hello.admission } : {}),
      });
    } else {
      send({ type: purpose, client_id: device.clientId, certificate: device.certificate });
    }
    read();
  })().catch((error) => { log.push({ at: at(), event: "error", error: error.message }); closedWith(null); });

  return {
    log, opened, closed,
    get standing() { return standing; },
    intent(operation, args = {}) {
      const id = `int_${++next}`;
      return new Promise((resolve) => {
        const w = (answer) => resolve(answer);
        w.sent = at();
        waiting.set(id, w);
        send({ type: "intent", id, operation, args });
      });
    },
    // The certificate renewed on this connection: `renew`, the challenge
    // signed, and the replacement the CYFR answers, which the device keeps.
    renew() {
      expecting = "renew";
      return new Promise((resolve) => {
        renewed = resolve;
        send({ type: "renew", client_id: device.clientId, certificate: device.certificate });
      });
    },
    sleep() { asleep = true; log.push({ at: at(), event: "sleep" }); },
    wake() {
      asleep = false;
      log.push({ at: at(), event: "wake" });
      read();
      if (socketClosed) closedWith(null);
    },
    close() { if (socket) socket.end(frame(8, Buffer.from([0x03, 0xe8]))); },
  };
}

// The device's first connection (`channel/2` with `hello`): admitted to
// the account `identifier` under `admission`, connected on the same
// connection; answers the channel that stands, or the code that closed it.
export async function helloDevice(device, { identifier, admission = null, ...options }) {
  const ch = channel(device, { ...options, purpose: "connect", hello: { identifier, admission } });
  const outcome = await Promise.race([ch.opened.then(() => "open"), ch.closed]);
  return outcome === "open" ? { channel: ch } : { code: outcome, log: ch.log };
}

// A channel opened for this device: `connect` first, and `renew` on a new
// connection when the CYFR will not take the certificate (4408), as a
// device renews; answers the channel that stands, or the code that closed
// the last.
export async function connectDevice(device, options) {
  let ch = channel(device, { ...options, purpose: "connect" });
  let outcome = await Promise.race([ch.opened.then(() => "open"), ch.closed]);
  if (outcome === 4408) {
    ch = channel(device, { ...options, purpose: "renew" });
    outcome = await Promise.race([ch.opened.then(() => "open"), ch.closed]);
  }
  return outcome === "open" ? { channel: ch } : { code: outcome, log: ch.log };
}
