// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// CYFR mcp-bridge: runs the stdio MCP servers CYFR registers with transport
// `stdio`, one owner per (athanor, server row), and serves each owner's
// tools over HTTP MCP.
//
// Two endpoints, both authenticated with `Cyfr-Bridge-Auth` (auth.mjs) under
// keys derived from CYFR_MCP_BRIDGE_KEY:
//
//   POST /control  CYFR's controller: hello, reconcile, sync, renew, release
//                  and status, signed with the control key. A sync carries
//                  the owner's backend definitions and their environment
//                  sealed to the owner and this bridge lifetime. Control
//                  messages are applied one at a time, in sequence order,
//                  and each is answered without waiting on a backend: a
//                  sync is answered once its version is admitted, and the
//                  owner's state and rev (owners.mjs) in every later renew
//                  and status say when its backends are ready. A status
//                  names a bounded set of owners and its answer is bounded
//                  in bytes; past either bound it is refused whole, never
//                  cut.
//   POST /mcp      One owner's MCP requests (server/discover, tools/list,
//                  tools/call), signed with that owner's key for the
//                  generation and epoch it runs at. It reaches that owner's
//                  backends only.
//
// A request's header is authenticated, and its lifetime, sequence or owner
// version and nonce checked, before its body is read; a request refused
// there has its connection closed with the body unread. The body is then
// read up to its endpoint's limit and must hash to the hash the header
// signed.
//
// Every response carries `Cyfr-Bridge-Boot`, the id this process minted at
// start; a request naming another lifetime is refused. Nothing is persisted:
// keys are derived, and owners, versions and leases arrive in messages.
//
// Backends are started only through the spawner (`createBridge({ spawner })`):
// in the image that is cyfr-spawn, which starts this process with its channel
// on fd 3 and runs each backend under a uid of its own with a 0700 home and
// an environment built from nothing but the backend's own block
// (spawn-client.mjs). The port is reachable from the compose network only.

import express from "express";
import { fstatSync, readFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes, randomUUID } from "node:crypto";
import * as auth from "./auth.mjs";
import { MAX_IDLE_MS, MAX_LEASE_MS, Owners, Refusal, RpcRefusal, validateBackends } from "./owners.mjs";
import { SpawnerClient } from "./spawn-client.mjs";

// Single source for the bridge version: package.json.
const VERSION = JSON.parse(
  readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "package.json"), "utf8"),
).version;

const PORT = Number(process.env.MCP_BRIDGE_PORT || 8001);

// The spawner's channel, the directory of the attach socket its relays
// connect to, and the uid pool backends are spawned from.
const SPAWNER_FD = 3;
const ATTACH_DIR = "/run/cyfr-bridge";
const SPAWN_POOL = "backends";

// Inbound /mcp uses the current stateless protocol with per-request metadata.
const PROTOCOL_VERSION = "2026-07-28";

// Outbound stdio uses the shared fallback protocol revision (owners.mjs
// initializes each backend with it).
const CHILD_PROTOCOL_VERSION = "2025-03-26";

// Reverse-DNS `_meta` keys defined by the specification.
const META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion";
const META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities";
const META_SERVER_INFO = "io.modelcontextprotocol/serverInfo";

// The request header a signed request carries, and the response header
// naming this lifetime.
const AUTH_HEADER = "cyfr-bridge-auth";
const BOOT_HEADER = "cyfr-bridge-boot";

// A request's timestamp may differ from this clock by at most this much.
const TIMESTAMP_WINDOW_MS = 30_000;

// The most body each endpoint reads. A control message is at most a sync of
// sixteen backend definitions and their sealed environment; CYFR refuses to
// send a larger one (Emissary.MCP.Bridge). An MCP request carries one tool
// call's arguments, at most the 10 MiB request ceiling of a CYFR call
// (Cyfr.Limits.Ceiling), and its JSON-RPC envelope.
export const CONTROL_BODY_LIMIT = 1024 * 1024;
export const MCP_BODY_LIMIT = 10 * 1024 * 1024 + 64 * 1024;

// A status names at most this many owners, and its answer — each named
// owner's backends with their stderr tails — is at most the control limit,
// which is also the most CYFR reads of any control answer. A status past
// the owner bound is refused as `too_many_owners`, and one whose answer
// would pass the byte bound as `status_too_large`; neither is truncated.
// CYFR mirrors the owner bound (Emissary.MCP.Bridge) and never sends more.
export const MAX_STATUS_OWNERS = 64;
export const STATUS_ANSWER_LIMIT = CONTROL_BODY_LIMIT;

// A tool catalogue changes only when an owner is synced or a backend
// restarts. `private`: each owner's catalogue is its own.
const TOOLS_TTL_MS = 60_000;
const RPC_TIMEOUT_MS = Number(process.env.MCP_BRIDGE_RPC_TIMEOUT_MS || 30_000);
const INIT_TIMEOUT_MS = Number(process.env.MCP_BRIDGE_INIT_TIMEOUT_MS || 15_000);

// Ceiling on calls awaiting one backend at a time.
const MAX_IN_FLIGHT = Number(process.env.MCP_BRIDGE_MAX_IN_FLIGHT || 32);

class UnknownMethod extends Error {}

const isObject = (value) => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const positiveInteger = (value) => Number.isSafeInteger(value) && value > 0;

// An owner reference as a message names it: valid auth fields, and an epoch
// where one is required.
function ownerRef(value, { epoch }) {
  if (!isObject(value)) throw new Refusal("bad_request", 400);
  const { athanor, server, e } = value;
  if (!auth.validField(athanor) || !auth.validField(server)) throw new Refusal("bad_request", 400);
  if (epoch && !positiveInteger(e)) throw new Refusal("bad_request", 400);
  return epoch ? { athanor, server, e } : { athanor, server };
}

// The owner references a message lists; a list past `max` is refused as
// `too_many_owners` before any entry is read.
function ownerRefs(value, options, { max = Infinity } = {}) {
  if (!Array.isArray(value)) throw new Refusal("bad_request", 400);
  if (value.length > max) throw new Refusal("too_many_owners", 400);
  return value.map((entry) => ownerRef(entry, options));
}

function milliseconds(value, max) {
  if (!Number.isSafeInteger(value) || value < 1 || value > max) throw new Refusal("bad_request", 400);
  return value;
}

class BodyTooLarge extends Error {}

// Reads a request's body, refusing one past `limit` bytes as soon as it is.
function readBody(req, limit) {
  const declared = req.get("content-length");
  if (declared !== undefined && !(Number(declared) <= limit)) return Promise.reject(new BodyTooLarge());
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const finish = (err) => {
      req.off("data", onData);
      req.off("end", onEnd);
      req.off("error", finish);
      req.off("close", onClose);
      if (err) reject(err);
      else resolve(Buffer.concat(chunks, size));
    };
    const onData = (chunk) => {
      size += chunk.length;
      if (size > limit) finish(new BodyTooLarge());
      else chunks.push(chunk);
    };
    const onEnd = () => finish();
    const onClose = () => finish(new Error("the request closed before its body was read"));
    req.on("data", onData);
    req.on("end", onEnd);
    req.on("error", finish);
    req.on("close", onClose);
  });
}

/**
 * Builds the bridge around a spawner and the root key.
 *
 * The spawner starts a backend with `spawn({ argv, env })`, answers `pool()`
 * with `{size, free, quarantined}`, and returns a handle shaped like a ChildProcess —
 * `stdin`, `stdout`, `stderr`, `spawn`, `error` and `exit` events — plus
 * `release(graceMs)`, which retires every process of the backend and
 * resolves once that is done. `env` is the backend's whole environment
 * block; the spawner adds only HOME, USER, LOGNAME, TMPDIR and PATH.
 *
 * Returns the express `app`, this lifetime's `boot` id, the `owners` table
 * and `close()`, which releases every owner. `statusAnswerLimit` is the
 * most bytes a status answer may be (the control limit unless set).
 */
export function createBridge({
  spawner,
  root,
  now = Date.now,
  boot = `bb_${randomBytes(16).toString("hex")}`,
  rpcTimeoutMs = RPC_TIMEOUT_MS,
  initTimeoutMs = INIT_TIMEOUT_MS,
  maxInFlight = MAX_IN_FLIGHT,
  statusAnswerLimit = STATUS_ANSWER_LIMIT,
  ...ownerOptions
}) {
  const rootKey = Buffer.from(root);
  const controlKey = auth.controlKey(rootKey);
  const sealKey = auth.sealKey(rootKey);
  const owners = new Owners({ spawner, now, rpcTimeoutMs, initTimeoutMs, maxInFlight, ...ownerOptions });

  // The highest (generation, seq) a control message has carried, and the
  // tail of the control messages being applied.
  let highWater = { generation: 0, seq: 0 };
  let controlTail = Promise.resolve();

  const above = ({ generation, seq }) =>
    generation > highWater.generation || (generation === highWater.generation && seq > highWater.seq);

  // Applies control messages one at a time, in the order their bodies were
  // verified; `apply` raises the high-water mark as it starts.
  function inOrder(apply) {
    const run = controlTail.then(apply);
    controlTail = run.then(
      () => {},
      () => {},
    );
    return run;
  }

  const app = express();
  app.disable("x-powered-by");

  app.use((req, res, next) => {
    res.set(BOOT_HEADER, boot);
    next();
  });

  // Unauthenticated: it carries no data and the container healthcheck needs it.
  app.get("/health", (_req, res) => {
    res.json({ ok: true });
  });

  // The parsed header of a request carrying one of `kind` whose MAC verifies
  // within the window, or null.
  function authenticate(req, kind, keyFor) {
    const parsed = auth.parseHeader(kind, req.get(AUTH_HEADER));
    if (!parsed) return null;
    const { fields } = parsed;
    if (Math.abs(now() - fields.ts) > TIMESTAMP_WINDOW_MS) return null;
    let key;
    try {
      key = keyFor(fields);
    } catch {
      return null;
    }
    return auth.verify(key, parsed) ? parsed : null;
  }

  function unauthorized(req, endpoint) {
    console.warn(`[mcp-bridge] ${endpoint} refused an unauthenticated request (request=${req.get("x-request-id") ?? "-"})`);
  }

  const refuse = (res, refusal) => res.status(refusal.status).json({ error: refusal.code });

  // A request answered before its body is read closes its connection, so
  // the body is never read.
  const unread = (res) => res.set("connection", "close");

  // The request's body once it is read within `limit` and hashes to what
  // its header signed; otherwise null, with the refusal answered by
  // `tooLarge` or `mismatch`.
  async function verifiedBody(req, res, parsed, limit, { tooLarge, mismatch }) {
    let body;
    try {
      body = await readBody(req, limit);
    } catch (err) {
      if (err instanceof BodyTooLarge && !res.headersSent) tooLarge(unread(res));
      return null;
    }
    if (!auth.bodyMatches(parsed, body)) {
      mismatch(res);
      return null;
    }
    return body;
  }

  // ==========================================================================
  // /control
  // ==========================================================================

  app.post("/control", async (req, res) => {
    const parsed = authenticate(req, "control", () => controlKey);
    if (!parsed) {
      unauthorized(req, "/control");
      return unread(res).status(401).json({ error: "unauthorized" });
    }
    const { fields } = parsed;
    if (fields.boot !== "-" && fields.boot !== boot) return refuse(unread(res), new Refusal("stale_boot"));
    if (!above(fields)) return refuse(unread(res), new Refusal("stale_control"));

    const body = await verifiedBody(req, res, parsed, CONTROL_BODY_LIMIT, {
      tooLarge: (r) => r.status(413).json({ error: "too_large" }),
      mismatch: (r) => {
        unauthorized(req, "/control");
        r.status(401).json({ error: "unauthorized" });
      },
    });
    if (!body) return;

    let message;
    try {
      message = JSON.parse(body.toString("utf8"));
    } catch {
      message = null;
    }
    if (!isObject(message) || typeof message.type !== "string") return refuse(res, new Refusal("bad_request", 400));

    const expectedBoot = message.type === "hello" ? "-" : boot;
    if (fields.boot !== expectedBoot) return refuse(res, new Refusal("stale_boot"));

    try {
      const answer = await inOrder(() => {
        if (!above(fields)) throw new Refusal("stale_control");
        highWater = { generation: fields.generation, seq: fields.seq };
        return control(message, fields);
      });
      return res.json(answer);
    } catch (err) {
      if (err instanceof Refusal) return refuse(res, err);
      console.error("[mcp-bridge] control error:", err);
      return res.status(500).json({ error: "internal" });
    }
  });

  async function control(message, { generation: g, cyfr_boot: cyfrBoot }) {
    switch (message.type) {
      case "hello": {
        if (message.g !== g || message.cyfr_boot !== cyfrBoot) throw new Refusal("bad_request", 400);
        let pool;
        try {
          pool = await owners.pool();
        } catch {
          throw new Refusal("unavailable", 503);
        }
        console.log(`[mcp-bridge] hello from ${cyfrBoot} at generation ${g}`);
        return { boot, pool: { size: pool.size, free: pool.free } };
      }
      case "reconcile":
        return owners.reconcile(ownerRefs(message.keep, { epoch: true }), g);
      case "sync": {
        const { athanor, server } = ownerRef(message.owner, { epoch: false });
        const e = message.e;
        if (!positiveInteger(e) || typeof message.sealed !== "string") throw new Refusal("bad_request", 400);
        const leaseMs = milliseconds(message.lease_ms, MAX_LEASE_MS);
        const idleMs = milliseconds(message.idle_ms, MAX_IDLE_MS);
        const backends = validateBackends(message.backends);
        const openEnv = () => {
          const plaintext = auth.open(sealKey, { athanor, server, generation: g, epoch: e }, boot, message.sealed);
          if (!plaintext) throw new Refusal("bad_request", 400);
          try {
            return JSON.parse(plaintext.toString("utf8"));
          } catch {
            throw new Refusal("bad_request", 400);
          }
        };
        return owners.sync({ athanor, server, g, e, leaseMs, idleMs, backends, openEnv });
      }
      case "renew":
        return owners.renew(ownerRefs(message.owners, { epoch: true }), g, milliseconds(message.lease_ms, MAX_LEASE_MS));
      case "release":
        return owners.release(ownerRefs(message.owners, { epoch: true }), g);
      case "status": {
        const answer = owners.status(ownerRefs(message.owners, { epoch: false }, { max: MAX_STATUS_OWNERS }));
        // Measured as `res.json` will send it; an answer past the bound is
        // refused whole rather than sent or cut.
        if (Buffer.byteLength(JSON.stringify(answer)) > statusAnswerLimit) throw new Refusal("status_too_large");
        return answer;
      }
      default:
        throw new Refusal("bad_request", 400);
    }
  }

  // ==========================================================================
  // /mcp
  // ==========================================================================

  // GET and DELETE are unsupported and return 405.
  app.all("/mcp", (req, res, next) => {
    if (req.method === "POST" || req.method === "OPTIONS") return next();
    res.set("mcp-protocol-version", PROTOCOL_VERSION);
    res.set("allow", "POST, OPTIONS");
    return rpcError(res, 405, null, -32600, `${req.method} is not supported on the MCP endpoint.`);
  });

  app.post("/mcp", async (req, res) => {
    res.set("mcp-protocol-version", PROTOCOL_VERSION);

    // One correlation id per request, echoed back and stamped on error logs —
    // cyfr sends x-request-id on every call it makes.
    const requestId = req.get("x-request-id") || randomUUID();
    res.set("x-request-id", requestId);

    const parsed = authenticate(req, "invoke", (f) =>
      auth.ownerKey(rootKey, { athanor: f.athanor, server: f.server, generation: f.generation, epoch: f.epoch }),
    );
    if (!parsed) {
      unauthorized(req, "/mcp");
      return rpcError(unread(res), 401, null, -33001, "unauthorized");
    }
    const { fields } = parsed;
    if (fields.boot !== boot) return refuse(unread(res), new Refusal("stale_boot"));

    const invoke = {
      athanor: fields.athanor,
      server: fields.server,
      g: fields.generation,
      e: fields.epoch,
      ts: fields.ts,
      nonce: fields.nonce,
    };
    try {
      owners.admit(invoke);
    } catch (err) {
      if (err instanceof Refusal) return refuse(unread(res), err);
      throw err;
    }

    const body = await verifiedBody(req, res, parsed, MCP_BODY_LIMIT, {
      tooLarge: (r) => rpcError(r, 413, null, -32600, "Request body too large"),
      mismatch: (r) => {
        unauthorized(req, "/mcp");
        rpcError(r, 401, null, -33001, "unauthorized");
      },
    });
    if (!body) return;

    // Admitted again with its body verified, which records its nonce.
    let owner;
    try {
      owner = owners.admit(invoke, { record: true });
    } catch (err) {
      if (err instanceof Refusal) return refuse(res, err);
      throw err;
    }

    let msg;
    try {
      msg = JSON.parse(body.toString("utf8"));
    } catch {
      return rpcError(res, 400, null, -32700, "Parse error: body is not valid JSON");
    }
    if (!isObject(msg)) {
      // "The body of the HTTP POST MUST be a single JSON-RPC request or
      // notification" — an array is a batch and has no handler.
      return rpcError(res, 400, null, -32600, "Expected a single JSON-RPC message");
    }

    // Notifications omit id and receive an empty 202 response.
    // An explicit null id is a request and must receive a JSON-RPC response.
    if (msg.id === undefined) {
      return res.status(202).end();
    }

    const conformance = checkConformance(req, msg);
    if (conformance) {
      return rpcError(res, 400, msg.id, conformance.code, conformance.message, conformance.data);
    }

    try {
      const result = await handleRpc(owner, msg);
      return res.json({ jsonrpc: "2.0", id: msg.id, result: stampResult(result) });
    } catch (err) {
      if (err instanceof UnknownMethod) {
        // 404, not 400: a dual-era client reads the status to tell a modern
        // server missing one method from a legacy server missing the endpoint.
        return rpcError(res, 404, msg.id, -32601, err.message);
      }
      if (err instanceof RpcRefusal) {
        return res.json({ jsonrpc: "2.0", id: msg.id, error: { code: -32603, message: err.message } });
      }
      // Anything else is an internal fault; the wire gets a generic sentence.
      console.error(`[mcp] request=${requestId} error:`, err);
      return rpcError(res, 500, msg.id, -32603, "internal error");
    }
  });

  // Render a handler's failure as a JSON-RPC error. Express error middleware
  // must be registered after the routes.
  app.use((err, req, res, next) => {
    if (res.headersSent) return next(err);
    console.error("[mcp-bridge] request error:", err);
    // Never the error's own message — at this layer it is an internal term.
    return rpcError(res, 500, null, -32603, "internal error");
  });

  function rpcError(res, status, id, code, message, data) {
    return res.status(status).json({
      jsonrpc: "2.0",
      id: id ?? null,
      error: { code, message, ...(data !== undefined ? { data } : {}) },
    });
  }

  // Every result declares its type and this server's identity. A client that
  // cannot tell a finished answer from one asking for more input has to guess.
  function stampResult(result) {
    return {
      ...result,
      resultType: "complete",
      _meta: {
        ...(result._meta || {}),
        [META_SERVER_INFO]: { name: "cyfr-mcp-bridge", version: VERSION },
      },
    };
  }

  // The per-request checks that replace the handshake. Returns null when the
  // request is well-formed, or the JSON-RPC error to answer with.
  function checkConformance(req, msg) {
    const meta = (msg.params && msg.params._meta) || {};
    const header = req.get("mcp-protocol-version");
    const declared = meta[META_PROTOCOL_VERSION];

    if (!header) {
      return { code: -32020, message: "Missing required MCP-Protocol-Version header." };
    }
    if (!declared) {
      return { code: -32020, message: `Missing required ${META_PROTOCOL_VERSION} in params._meta.` };
    }
    if (header !== declared) {
      // A gateway may route on the header, so it must not be able to disagree
      // with what this server will actually execute.
      return {
        code: -32020,
        message: `MCP-Protocol-Version header (${header}) does not match ${META_PROTOCOL_VERSION} (${declared}).`,
      };
    }
    if (header !== PROTOCOL_VERSION) {
      return {
        code: -32022,
        message: `Unsupported protocol version ${header}.`,
        data: { supported: [PROTOCOL_VERSION], requested: header },
      };
    }
    if (typeof meta[META_CLIENT_CAPABILITIES] !== "object" || meta[META_CLIENT_CAPABILITIES] === null) {
      return { code: -32602, message: `Missing required ${META_CLIENT_CAPABILITIES} in params._meta.` };
    }

    const methodHeader = req.get("mcp-method");
    if (methodHeader !== msg.method) {
      return {
        code: -32020,
        message: `Mcp-Method header (${methodHeader ?? "absent"}) does not match the request body.`,
      };
    }

    const subject = namedSubject(msg);
    if (subject !== null) {
      const nameHeader = decodeHeaderValue(req.get("mcp-name"));
      if (nameHeader !== subject) {
        return {
          code: -32020,
          message: `Mcp-Name header (${nameHeader ?? "absent"}) does not match the request body.`,
        };
      }
    }

    return null;
  }

  // `tools/call` names its subject in `params.name`. The bridge serves no
  // resources or prompts, so there is nothing else that names one.
  function namedSubject(msg) {
    if (msg.method === "tools/call" && typeof msg.params?.name === "string") {
      return msg.params.name;
    }
    return null;
  }

  // A value outside visible ASCII travels as `=?base64?<encoded>?=`, and the
  // comparison has to happen after decoding or every legitimate encoded name is
  // rejected.
  function decodeHeaderValue(value) {
    if (typeof value !== "string") return value ?? null;
    if (!value.startsWith("=?base64?") || !value.endsWith("?=")) return value;
    try {
      return Buffer.from(value.slice(9, -2), "base64").toString("utf8");
    } catch {
      return null;
    }
  }

  async function handleRpc(owner, msg) {
    switch (msg.method) {
      // Version and capability discovery that establishes nothing.
      // `initialize`, `notifications/initialized` and `ping` are not in this
      // revision and answer 404 like any other unknown method.
      case "server/discover":
        return {
          supportedVersions: [PROTOCOL_VERSION],
          capabilities: { tools: { listChanged: false }, extensions: {} },
          instructions:
            "Runs this server's stdio MCP backends; every backend tool appears as `<backend>__<tool>`.",
          ttlMs: TOOLS_TTL_MS,
          cacheScope: "private",
        };
      case "tools/list":
        return { tools: owners.tools(owner), ttlMs: TOOLS_TTL_MS, cacheScope: "private" };
      case "tools/call": {
        const { name, arguments: args } = msg.params || {};
        if (!name) throw new RpcRefusal("tools/call: missing 'name'");
        try {
          return await owners.callTool(owner, name, args || {});
        } catch (err) {
          // Tool refusals return isError=true; only a refusal's text is
          // client-safe.
          if (err instanceof RpcRefusal) return { content: [{ type: "text", text: err.message }], isError: true };
          console.error(`[tools/call] internal error: ${err?.stack || err}`);
          return { content: [{ type: "text", text: "tool call failed" }], isError: true };
        }
      }
      default:
        throw new UnknownMethod(`unsupported method: ${msg.method}`);
    }
  }

  return { app, boot, owners, close: () => owners.close() };
}

// ============================================================================
// Boot
// ============================================================================

// fd 3 is the spawner's channel only when cyfr-spawn started this process.
function spawnerChannelPresent() {
  try {
    return fstatSync(SPAWNER_FD).isSocket();
  } catch {
    return false;
  }
}

async function main() {
  // CYFR_LOG_FORMAT=json enables structured logs; otherwise use text logs.
  if (process.env.CYFR_LOG_FORMAT === "json") {
    const jsonLine = (level, args) => {
      const message = args
        .map((a) => (typeof a === "string" ? a : (a && a.stack) || String(a)))
        .join(" ");
      process.stderr.write(
        JSON.stringify({ timestamp: new Date().toISOString(), level, message, service: "mcp-bridge" }) +
          "\n",
      );
    };
    console.log = (...args) => jsonLine("info", args);
    console.warn = (...args) => jsonLine("warning", args);
    console.error = (...args) => jsonLine("error", args);
  }

  // Backends are started only through the spawner, which hands this process
  // its channel as fd 3. Without it there is no way to run a backend under a
  // uid of its own, so the bridge does not start.
  if (!spawnerChannelPresent()) {
    console.error(
      "[mcp-bridge] FATAL: fd 3 is not the spawner channel. Start the bridge through " +
        "`cyfr-spawn serve … -- node server.mjs` (the image's entrypoint).",
    );
    process.exit(1);
  }

  let root;
  try {
    root = auth.decodeRoot(process.env.CYFR_MCP_BRIDGE_KEY);
  } catch {
    console.error(
      "[mcp-bridge] FATAL: CYFR_MCP_BRIDGE_KEY must be 64 hexadecimal digits (32 random bytes), " +
        "the same value CYFR is configured with. `cyfr init` generates it into .env.",
    );
    process.exit(1);
  }

  // This process supervises children and is itself supervised (compose
  // restart: unless-stopped): an unexpected failure crashes loudly and lets
  // the supervisor restart a clean instance.
  process.on("uncaughtException", (err) => {
    console.error("[mcp-bridge] FATAL uncaught exception:", err);
    process.exit(1);
  });
  process.on("unhandledRejection", (reason) => {
    console.error("[mcp-bridge] FATAL unhandled rejection:", reason);
    process.exit(1);
  });

  const channel = new net.Socket({ fd: SPAWNER_FD, readable: true, writable: true });
  const spawner = new SpawnerClient({ channel, attachDir: ATTACH_DIR, pool: SPAWN_POOL });
  // The spawner retires every backend when its channel closes; nothing this
  // process started can be managed after that.
  spawner.on("lost", () => {
    console.error("[mcp-bridge] FATAL: the spawner channel closed");
    process.exit(1);
  });
  await spawner.listen();

  const bridge = createBridge({ spawner, root });

  let httpServer = null;
  let stopping = false;
  async function shutdown(signal) {
    if (stopping) return;
    stopping = true;
    console.log(`[mcp-bridge] ${signal} — stopping ${bridge.owners.size} owners`);
    // Hard stop inside compose's stop_grace_period if a request never drains.
    setTimeout(() => process.exit(0), 12_000).unref();
    // Stop accepting and let in-flight requests drain while the backends are
    // retired in parallel, so pending calls against them fail promptly.
    const drained = new Promise((resolve) => (httpServer ? httpServer.close(() => resolve()) : resolve()));
    await Promise.all([drained, bridge.close()]);
    process.exit(0);
  }
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));

  httpServer = bridge.app.listen(PORT, "0.0.0.0", () => {
    console.log(`[mcp-bridge] /control and /mcp on :${PORT} (boot ${bridge.boot}, child protocol ${CHILD_PROTOCOL_VERSION})`);
  });
}

if (import.meta.main) main();
