// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// CYFR mcp-bridge: wraps stdio MCP servers behind one HTTP MCP endpoint.
//
// Architecture: a single Streamable-HTTP-compatible /mcp endpoint. Tools
// surfaced through it are (a) admin tools — add_backend / remove_backend /
// list_backends / restart_backend — that manage the set of stdio children,
// and (b) every running child's tools, renamed `<backend>__<tool>`. cyfr
// registers this bridge as a normal HTTP MCP server (`mcp_servers create`)
// and sees all of the above under the `bridge:` namespace.
//
// Children run `/bin/sh -c <command>` (typically `npx -y <pkg>`) and speak
// MCP JSON-RPC over their stdin/stdout in newline-delimited frames. The
// bridge starts, signals and retires them only through its spawner
// (`createBridge({ spawner })`). In the image that is cyfr-spawn, which
// starts this process with its channel on fd 3 and runs each child under a
// uid of its own with a 0700 home and an environment built from nothing
// but the child's own env block (spawn-client.mjs).

import express from "express";
import { promises as fs, constants as fsConstants, fstatSync, readFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { timingSafeEqual, randomUUID } from "node:crypto";
import { SpawnerClient } from "./spawn-client.mjs";

// Single source for the bridge version: package.json.
const VERSION = JSON.parse(
  readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "package.json"), "utf8"),
).version;

// SECURITY / TRUST BOUNDARY
// -------------------------
// This bridge runs arbitrary `sh -c <command>` on behalf of `add_backend`,
// so anything that can POST to /mcp gets remote code execution *by design*. It
// is meant to run on a trusted container network only — docker-compose uses
// `expose` (never `ports:`), so the port is reachable from sibling containers
// (cyfr) but not the host. Binding 0.0.0.0 is required for that
// cross-container reachability; do NOT change it to loopback and do NOT publish
// the port to the host.
//
// Defense-in-depth against a compromised sibling container: /mcp requires a
// matching `Authorization: Bearer` header. cyfr supplies it via the registered
// server's headers (e.g. `Authorization: vault:mcp_bridge_token`). `cyfr init`
// generates the token so the bridge boots closed; without a token the bridge
// refuses to start unless MCP_BRIDGE_ALLOW_INSECURE=1 explicitly accepts an
// unauthenticated, shell-spawning endpoint on an isolated network.
//
// Each backend runs under its own uid, so backends cannot read each other's
// files or /proc environ, signal each other, or reach this process's memory,
// files or environment. They share the network, CPU and memory, and command
// lines are visible to every process in the container.

const PORT = Number(process.env.MCP_BRIDGE_PORT || 8001);
const AUTH_TOKEN = process.env.MCP_BRIDGE_TOKEN || "";
const PERSIST = process.env.MCP_BRIDGE_DATA || "/data/backends.json";

// The spawner's channel, the directory of the attach socket its relays
// connect to, and the uid pool backends are spawned from.
const SPAWNER_FD = 3;
const ATTACH_DIR = "/run/cyfr-bridge";
const SPAWN_POOL = "backends";

// Inbound /mcp uses the current stateless protocol with per-request metadata.
const PROTOCOL_VERSION = "2026-07-28";

// Outbound stdio uses the shared fallback protocol revision and initializes child servers.
const CHILD_PROTOCOL_VERSION = "2025-03-26";

// Ceiling on one child stdout frame (a single line). RPC_TIMEOUT_MS bounds
// how long a pending call waits, but nothing bounded how much an unhinged
// child could write into the framing buffer before the first newline.
const MAX_FRAME_BYTES = 10 * 1024 * 1024;

// Reverse-DNS `_meta` keys defined by the specification.
const META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion";
const META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities";
const META_SERVER_INFO = "io.modelcontextprotocol/serverInfo";

// The tool catalogue changes only when a backend is added, removed or
// restarted. `private` because the aggregate is per-caller in principle and a
// shared cache must never serve one caller's view to another.
const TOOLS_TTL_MS = 60_000;
const RPC_TIMEOUT_MS = Number(process.env.MCP_BRIDGE_RPC_TIMEOUT_MS || 30_000);
const INIT_TIMEOUT_MS = Number(process.env.MCP_BRIDGE_INIT_TIMEOUT_MS || 15_000);

// Ceiling on calls awaiting one child at a time. RPC_TIMEOUT_MS drains the
// queue eventually, but until it fired nothing bounded how many pending
// entries a flood could park against a slow child.
const MAX_IN_FLIGHT = Number(process.env.MCP_BRIDGE_MAX_IN_FLIGHT || 32);

// Ceiling on the number of backends. Every other resource here is bounded
// (frames, in-flight calls, body size, timeouts); this bounds the one that
// spawns OS processes. The spawner's uid pool is a second, image-wide bound.
const MAX_BACKENDS = Number(process.env.MCP_BRIDGE_MAX_BACKENDS || 32);

// A stopping backend's processes get this long after SIGTERM before SIGKILL.
const STOP_GRACE_MS = 2000;

// Bound on waiting for the spawner to confirm a backend retired, beyond its grace.
const RELEASE_TIMEOUT_MS = 15_000;

const ADMIN_TOOLS = [
  {
    name: "add_backend",
    description:
      "Spawn a new stdio MCP backend (typically an npx package). Its tools will appear prefixed as `<name>__<tool>` after the next tools/list. Persisted to /data/backends.json so it survives restarts.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Backend identifier; cannot contain `__` or `:`.",
        },
        command: {
          type: "string",
          description:
            "Shell command, e.g. `npx -y @modelcontextprotocol/server-filesystem ./data`.",
        },
        env: {
          type: "object",
          description: "Optional env vars for the child process.",
          additionalProperties: { type: "string" },
        },
      },
      required: ["name", "command"],
    },
  },
  {
    name: "remove_backend",
    description: "Stop and remove a stdio backend; its forwarded tools disappear.",
    inputSchema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  },
  {
    name: "list_backends",
    description:
      "List all stdio backends with their status (`ready` | `starting` | `error` | `crashed`) and tool counts.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "restart_backend",
    description: "Stop and respawn a stdio backend.",
    inputSchema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  },
];

class UnknownMethod extends Error {}

// A deliberate refusal whose message is written for the caller — the only
// thrown errors whose text may reach the wire. Everything else is answered
// with a generic sentence and logged.
class RpcRefusal extends Error {}

function withTimeout(promise, ms) {
  let timer;
  return Promise.race([
    promise,
    new Promise((resolve) => {
      timer = setTimeout(resolve, ms);
      timer.unref?.();
    }),
  ]).finally(() => clearTimeout(timer));
}

/**
 * Builds the bridge around a spawner.
 *
 * The spawner starts a backend with `spawn({ argv, env })` and returns a
 * handle shaped like a ChildProcess — `stdin`, `stdout`, `stderr`, `error`
 * and `exit` events — plus `release(graceMs)`, which retires every process
 * of the backend and resolves once that is done. `env` is the backend's
 * whole environment block; the spawner adds only HOME, USER, LOGNAME,
 * TMPDIR and PATH.
 *
 * Returns the express `app`, `revive()` to respawn the persisted backends,
 * and `close()` to release every backend.
 */
export function createBridge({
  spawner,
  token = "",
  persistPath = PERSIST,
  rpcTimeoutMs = RPC_TIMEOUT_MS,
  initTimeoutMs = INIT_TIMEOUT_MS,
  maxInFlight = MAX_IN_FLIGHT,
  maxBackends = MAX_BACKENDS,
  stopGraceMs = STOP_GRACE_MS,
}) {
  const backends = new Map();

  // The one name rule, asserted at BOTH doors (admin add and the revival
  // loop): `__` is the tool-routing separator (`dispatchToolCall` splits on
  // the first one) and `:` collides with cyfr's namespaced-tool spelling. A
  // duplicate would make `backends.set` silently replace an earlier entry,
  // leaking its child process.
  function validateBackendName(name) {
    if (!name) throw new RpcRefusal("name is required");
    if (name.includes("__") || name.includes(":")) {
      throw new RpcRefusal("backend name cannot contain `__` or `:`");
    }
    if (backends.has(name)) throw new RpcRefusal(`backend '${name}' already exists`);
    if (backends.size >= maxBackends) {
      throw new RpcRefusal(`backend limit reached (${maxBackends})`);
    }
  }

  // ==========================================================================
  // Stdio MCP client (one per child)
  // ==========================================================================

  function spawnBackend(name, command, env) {
    validateBackendName(name);

    const proc = spawner.spawn({ argv: ["/bin/sh", "-c", command], env: env || {} });
    const backend = {
      name,
      command,
      env: env || {},
      proc,
      status: "starting",
      tools: [],
      error: null,
      nextId: 0,
      pending: new Map(),
      buffer: "",
    };
    backends.set(name, backend);

    proc.stdout.setEncoding("utf8");
    proc.stdout.on("data", (chunk) => {
      backend.buffer += chunk;

      let idx;
      while ((idx = backend.buffer.indexOf("\n")) >= 0) {
        const line = backend.buffer.slice(0, idx).trim();
        backend.buffer = backend.buffer.slice(idx + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch (e) {
          console.error(`[${name}] non-JSON stdout: ${line.slice(0, 200)}`);
          continue;
        }

        // A `method` means the child is TALKING, not answering: MCP servers
        // are bidirectional peers and send their own requests
        // (sampling/createMessage, roots/list, elicitation/create) with their
        // own id counter, which — like ours — starts at 1. Matching on id
        // alone resolved our pending `initialize` with a child's `roots/list`,
        // handing `undefined` to the handshake and skewing every id after it.
        if (msg.method !== undefined) {
          // A request expects an answer; a notification does not.
          if (msg.id != null) {
            writeFrame(backend, {
              jsonrpc: "2.0",
              id: msg.id,
              error: { code: -32601, message: `method not supported by bridge: ${msg.method}` },
            });
          }
          continue;
        }

        // Pending calls are keyed by the NUMBER we minted (`++nextId`), and
        // `Map.has` is strict. Ids round-trip through a string type in more
        // than one stdio server, so an echoed "1" for 1 matched nothing and
        // the call hung for the full RPC timeout with no log line.
        let key = msg.id;

        if (!backend.pending.has(key) && typeof key === "string" && key.trim() !== "") {
          const asNumber = Number(key);
          if (Number.isFinite(asNumber) && backend.pending.has(asNumber)) key = asNumber;
        }

        if (msg.id != null && backend.pending.has(key)) {
          const { resolve, reject, timer } = backend.pending.get(key);
          backend.pending.delete(key);
          if (timer) clearTimeout(timer);
          if (msg.error) reject(new Error(msg.error.message || JSON.stringify(msg.error)));
          else resolve(msg.result);
        } else if (msg.id != null) {
          console.error(`[${name}] response for unknown id ${JSON.stringify(msg.id)}; dropped`);
        }
        // Unsolicited notifications from the child are ignored.
      }

      // Checked AFTER draining, on what is left: this bounds a partial frame
      // with no newline, which is what the cap is for. Applied to the whole
      // buffer it also killed healthy backends mid-answer — a large
      // legitimate result arrives across many chunks and only becomes a
      // frame once its newline lands.
      if (backend.buffer.length > MAX_FRAME_BYTES) {
        console.error(
          `[${name}] stdout frame exceeded ${MAX_FRAME_BYTES} bytes without a newline; killing backend`
        );
        backend.buffer = "";
        backend.status = "error";
        backend.error = "stdout frame overflow";
        proc.signal("SIGKILL");
      }
    });

    proc.stderr.setEncoding("utf8");
    proc.stderr.on("data", (chunk) => {
      process.stderr.write(`[${name}] ${chunk}`);
    });

    // Handle errors on every child stream. A closed stdin can raise an error
    // before the child's exit event changes its status; a status the child
    // already reached (error, crashed, removed) keeps its own reason.
    for (const [label, stream] of [
      ["stdin", proc.stdin],
      ["stdout", proc.stdout],
      ["stderr", proc.stderr],
    ]) {
      stream.on("error", (err) => {
        if (backend.status === "starting" || backend.status === "ready") {
          backend.status = "error";
          backend.error = `${label}: ${err.message}`;
        }
        console.error(`[${name}] ${label} error: ${err.message}`);
        failPending(backend, new Error(backend.error || `${label} error`));
      });
    }

    // The spawner refused or could not start the child (a full uid pool, a
    // failed exec, a relay that never attached).
    proc.on("error", (err) => {
      if (backend.status !== "removed") {
        backend.status = "error";
        backend.error = err.message;
      }
      failPending(backend, new Error(backend.error || err.message));
    });

    proc.on("exit", (code, signal) => {
      if (backend.status !== "removed") {
        backend.status = "crashed";
        backend.error = `exited code=${code} signal=${signal}`;
      }
      failPending(backend, new Error(backend.error || "child exited"));
    });

    return backend;
  }

  function failPending(backend, err) {
    for (const { reject, timer } of backend.pending.values()) {
      if (timer) clearTimeout(timer);
      reject(err);
    }
    backend.pending.clear();
  }

  // Centralize child writes so both synchronous failures and asynchronous stream errors are handled.
  function writeFrame(backend, msg) {
    try {
      backend.proc.stdin.write(JSON.stringify(msg) + "\n");
      return true;
    } catch (e) {
      console.error(`[${backend.name}] stdin write failed: ${e.message}`);
      return false;
    }
  }

  function rpc(backend, method, params, timeoutMs = rpcTimeoutMs) {
    return new Promise((resolve, reject) => {
      if (backend.status === "removed" || backend.status === "crashed") {
        reject(new Error(`backend not running (${backend.status})`));
        return;
      }
      if (backend.pending.size >= maxInFlight) {
        reject(new Error(`backend busy: ${backend.pending.size} calls in flight`));
        return;
      }
      const id = ++backend.nextId;
      const timer = setTimeout(() => {
        if (backend.pending.has(id)) {
          backend.pending.delete(id);
          reject(new Error(`timeout: ${method}`));
        }
      }, timeoutMs);
      backend.pending.set(id, { resolve, reject, timer });
      const req = {
        jsonrpc: "2.0",
        id,
        method,
        ...(params !== undefined ? { params } : {}),
      };
      if (!writeFrame(backend, req)) {
        backend.pending.delete(id);
        clearTimeout(timer);
        reject(new Error(`backend stdin unavailable: ${method}`));
      }
    });
  }

  function notify(backend, method, params) {
    const msg = {
      jsonrpc: "2.0",
      method,
      ...(params !== undefined ? { params } : {}),
    };
    writeFrame(backend, msg);
  }

  async function initializeBackend(name) {
    const backend = backends.get(name);
    if (!backend) throw new RpcRefusal(`backend '${name}' not found`);
    try {
      await rpc(
        backend,
        "initialize",
        {
          protocolVersion: CHILD_PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: { name: "cyfr-mcp-bridge", version: VERSION },
        },
        initTimeoutMs,
      );
      notify(backend, "notifications/initialized");
      const toolsRes = await rpc(backend, "tools/list", undefined, initTimeoutMs);
      backend.tools = toolsRes?.tools || [];
      backend.status = "ready";
      backend.error = null;
      console.log(`[${name}] ready, ${backend.tools.length} tools`);
    } catch (e) {
      backend.status = "error";
      backend.error = backend.error || e.message;
      console.error(`[${name}] init failed: ${backend.error}`);
    }
  }

  // Retires the backend's processes: SIGTERM, `stopGraceMs` to exit, then
  // SIGKILL for every process of its uid, including any it detached. The
  // promise settles once the spawner reports the uid retired, or after a
  // bound if it never does.
  function stopBackend(name, markRemoved = true) {
    const backend = backends.get(name);
    if (!backend) return Promise.resolve();
    if (markRemoved) backend.status = "removed";
    failPending(backend, new Error("backend stopped"));
    return withTimeout(backend.proc.release(stopGraceMs), stopGraceMs + RELEASE_TIMEOUT_MS);
  }

  // ==========================================================================
  // Persistence
  // ==========================================================================

  // Backends run under other uids in the same container, so the file is read
  // only if it is not a symlink and this process owns it.
  async function loadPersisted() {
    let file;
    try {
      file = await fs.open(persistPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
      const st = await file.stat();
      if (!st.isFile() || st.uid !== process.getuid()) {
        console.error(`[persist] ${persistPath} is not a file owned by uid ${process.getuid()}; not reviving it`);
        return [];
      }
      const data = JSON.parse(await file.readFile("utf8"));
      return Array.isArray(data?.backends) ? data.backends : [];
    } catch (e) {
      if (e.code === "ENOENT") return [];
      console.error(`[persist] load error: ${e.message}`);
      return [];
    } finally {
      await file?.close();
    }
  }

  let persistQueued = false;
  let persisting = false;
  async function persist() {
    if (persisting) {
      persistQueued = true;
      return;
    }
    persisting = true;
    try {
      const data = { backends: [] };
      for (const [name, b] of backends) {
        if (b.status === "removed") continue;
        data.backends.push({
          name,
          command: b.command,
          ...(b.env && Object.keys(b.env).length ? { env: b.env } : {}),
        });
      }
      await fs.mkdir(path.dirname(persistPath), { recursive: true });
      const tmp = persistPath + ".tmp";
      // Backend env blocks carry third-party API keys — owner-only on disk.
      // The temporary file is created exclusively, so a name planted in the
      // directory (a symlink included) is never followed or written through.
      const body = JSON.stringify(data, null, 2);
      try {
        await fs.writeFile(tmp, body, { mode: 0o600, flag: "wx" });
      } catch (e) {
        if (e.code !== "EEXIST") throw e;
        await fs.unlink(tmp);
        await fs.writeFile(tmp, body, { mode: 0o600, flag: "wx" });
      }
      await fs.rename(tmp, persistPath);
    } catch (e) {
      console.error(`[persist] write error: ${e.message}`);
    } finally {
      persisting = false;
      if (persistQueued) {
        persistQueued = false;
        persist();
      }
    }
  }

  // ==========================================================================
  // Tool aggregation + dispatch
  // ==========================================================================

  function aggregatedTools() {
    const out = ADMIN_TOOLS.map((t) => ({ ...t }));
    for (const [name, b] of backends) {
      if (b.status !== "ready") continue;
      for (const t of b.tools) {
        out.push({
          name: `${name}__${t.name}`,
          description: t.description ? `[${name}] ${t.description}` : `[${name}]`,
          inputSchema: t.inputSchema || { type: "object" },
        });
      }
    }
    return out;
  }

  async function dispatchToolCall(toolName, args) {
    // Admin tools
    if (toolName === "add_backend") return await adminAddBackend(args);
    if (toolName === "remove_backend") return await adminRemoveBackend(args);
    if (toolName === "list_backends") return adminListBackends();
    if (toolName === "restart_backend") return await adminRestartBackend(args);

    // Forwarded child tool: `<backend>__<tool>`
    const sep = toolName.indexOf("__");
    if (sep > 0) {
      const backendName = toolName.slice(0, sep);
      const remoteName = toolName.slice(sep + 2);
      const b = backends.get(backendName);
      if (!b) throw new RpcRefusal(`backend '${backendName}' not found`);
      if (b.status !== "ready") {
        throw new RpcRefusal(`backend '${backendName}' not ready: ${b.error || b.status}`);
      }
      return await rpc(b, "tools/call", { name: remoteName, arguments: args || {} });
    }

    throw new RpcRefusal(`unknown tool: ${toolName}`);
  }

  async function adminAddBackend(args) {
    const name = String(args?.name || "").trim();
    const command = String(args?.command || "").trim();
    const env = args?.env && typeof args.env === "object" ? args.env : undefined;

    if (!command) throw new RpcRefusal("command is required");
    validateBackendName(name);

    spawnBackend(name, command, env);
    await initializeBackend(name);

    // A handshake that failed leaves a live child nobody manages, an entry
    // that blocks re-adding the same name, and — once persisted — a row the
    // revival loop re-spawns on every restart, walking `backends` toward
    // MAX_BACKENDS with corpses. `initializeBackend` swallows its error and
    // only sets status, so this is where it has to be caught: retire the
    // child, drop the entry, persist nothing, and tell the caller.
    const b = backends.get(name);

    if (b.status === "error") {
      const reason = b.error || "initialize failed";
      await stopBackend(name);
      backends.delete(name);
      throw new RpcRefusal(`backend '${name}' failed to start: ${reason}`);
    }

    await persist();

    return wrapResult({
      name,
      status: b.status,
      tool_count: b.tools.length,
      error: b.error,
    });
  }

  async function adminRemoveBackend(args) {
    const name = String(args?.name || "").trim();
    if (!name) throw new RpcRefusal("name is required");
    if (!backends.has(name)) throw new RpcRefusal(`backend '${name}' not found`);
    await stopBackend(name);
    backends.delete(name);
    await persist();
    return wrapResult({ removed: name });
  }

  function adminListBackends() {
    const out = [];
    for (const [name, b] of backends) {
      out.push({
        name,
        command: b.command,
        status: b.status,
        tool_count: b.tools.length,
        error: b.error,
      });
    }
    return wrapResult({ backends: out, count: out.length });
  }

  async function adminRestartBackend(args) {
    const name = String(args?.name || "").trim();
    if (!name) throw new RpcRefusal("name is required");
    const existing = backends.get(name);
    if (!existing) throw new RpcRefusal(`backend '${name}' not found`);
    const { command, env } = existing;
    // The old child's uid is retired before the new child takes one, so a
    // restart never needs two uids from the pool.
    await stopBackend(name);
    backends.delete(name);
    spawnBackend(name, command, env);
    await initializeBackend(name);
    const b = backends.get(name);
    return wrapResult({
      name,
      status: b.status,
      tool_count: b.tools.length,
      error: b.error,
    });
  }

  // MCP `tools/call` result is `{ content: [...], isError?: bool }`.
  function wrapResult(value) {
    return {
      content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    };
  }

  function wrapError(message) {
    return {
      content: [{ type: "text", text: message }],
      isError: true,
    };
  }

  // ==========================================================================
  // HTTP / MCP transport
  // ==========================================================================

  const app = express();
  // Match the server’s 28 MB body limit, including base64-encoded attachments.
  // Parse all content types so malformed bodies reach JSON-RPC error handling.
  app.use(express.json({ limit: "28mb", type: () => true }));

  // Constant-time bearer check. Returns true when no token is configured
  // (open mode) or when the request carries the matching bearer.
  function authorized(req) {
    if (!token) return true;

    const header = req.get("authorization") || "";
    const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
    const a = Buffer.from(presented);
    const b = Buffer.from(token);
    return a.length === b.length && timingSafeEqual(a, b);
  }

  // /health is intentionally unauthenticated — it carries no sensitive data and
  // the container healthcheck needs it.
  app.get("/health", (_req, res) => {
    res.json({ ok: true, backends: backends.size });
  });

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

    if (!authorized(req)) {
      // Return a JSON-RPC error and a WWW-Authenticate challenge for HTTP 401 (RFC 9110).
      res.set("www-authenticate", "Bearer");
      const id =
        req.body && typeof req.body === "object" && !Array.isArray(req.body)
          ? (req.body.id ?? null)
          : null;
      return rpcError(res, 401, id, -33001, "unauthorized");
    }

    const msg = req.body;
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) {
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
      const result = await handleRpc(msg);
      return res.json({ jsonrpc: "2.0", id: msg.id, result: stampResult(result) });
    } catch (err) {
      if (err instanceof UnknownMethod) {
        // 404, not 400: a dual-era client reads the status to tell a modern
        // server missing one method from a legacy server missing the endpoint.
        return rpcError(res, 404, msg.id, -32601, err.message);
      }
      if (err instanceof RpcRefusal) {
        // A crafted refusal — the message is client-safe by construction
        // (a backend name, a limit, a missing argument). Same wire shape as
        // before the split, so existing callers keep parsing it.
        return res.json({
          jsonrpc: "2.0",
          id: msg.id,
          error: {
            // -32603 (internal error) — the code cyfr's own fallback uses for
            // the same condition; -32000 was a second spelling of it.
            code: -32603,
            message: err.message,
          },
        });
      }
      // Anything else is an internal fault: a child-process failure or a bug,
      // whose message can carry paths, spawn arguments, or upstream stderr.
      // The detail goes to the log; the wire gets a 500 and a generic sentence.
      console.error(`[mcp] request=${requestId} error:`, err);
      return rpcError(res, 500, msg.id, -32603, "internal error");
    }
  });

  // Render JSON parser failures as JSON-RPC errors. Express error middleware
  // must be registered after the routes.
  app.use((err, req, res, next) => {
    if (res.headersSent) return next(err);

    if (err?.type === "entity.too.large") {
      return rpcError(res, 413, null, -32600, "Request body too large");
    }
    if (err?.status === 400 || err instanceof SyntaxError) {
      return rpcError(res, 400, null, -32700, "Parse error: body is not valid JSON");
    }
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

  async function handleRpc(msg) {
    switch (msg.method) {
      // Replaces `initialize`: version and capability discovery that establishes
      // nothing. `initialize`, `notifications/initialized` and `ping` are gone
      // from this revision and answer 404 like any other unknown method.
      case "server/discover":
        return {
          supportedVersions: [PROTOCOL_VERSION],
          capabilities: { tools: { listChanged: false }, extensions: {} },
          instructions:
            "Wraps stdio MCP servers behind one HTTP endpoint. " +
            "add_backend/remove_backend/list_backends/restart_backend manage the " +
            "children; every child tool appears as `<backend>__<tool>`.",
          ttlMs: TOOLS_TTL_MS,
          cacheScope: "private",
        };
      case "tools/list":
        return { tools: aggregatedTools(), ttlMs: TOOLS_TTL_MS, cacheScope: "private" };
      case "tools/call": {
        const { name, arguments: args } = msg.params || {};
        if (!name) throw new RpcRefusal("tools/call: missing 'name'");
        try {
          return await dispatchToolCall(name, args || {});
        } catch (err) {
          // Return tool refusals with isError=true. Only Refusal messages are safe
          // for clients; other errors may contain internal paths, arguments or stderr.
          if (err instanceof RpcRefusal) return wrapError(err.message);

          console.error(`[tools/call ${name}] internal error: ${err?.stack || err}`);
          return wrapError("tool call failed");
        }
      }
      default:
        throw new UnknownMethod(`unsupported method: ${msg.method}`);
    }
  }

  // Respawns every persisted backend. Children come online in parallel.
  async function revive() {
    const persisted = await loadPersisted();
    for (const entry of persisted) {
      if (!entry?.name || !entry?.command) continue;
      console.log(`[mcp-bridge] reviving '${entry.name}': ${entry.command}`);
      // The revival loop is the second door into spawnBackend: a hand-edited
      // persistence file with a routing-ambiguous or duplicate name must be
      // refused here exactly as the admin door refuses it, not spawned.
      try {
        spawnBackend(entry.name, entry.command, entry.env);
      } catch (e) {
        console.error(`[mcp-bridge] not reviving '${entry.name}': ${e.message}`);
        continue;
      }
      initializeBackend(entry.name).catch(() => {});
    }
  }

  // Releases every backend in parallel.
  async function close() {
    await Promise.allSettled([...backends.keys()].map((name) => stopBackend(name)));
  }

  return { app, revive, close, backends };
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

  // Validate the admin token before reading or starting persisted backend commands.
  if (!AUTH_TOKEN) {
    // add_backend spawns arbitrary `sh -c`, so an unauthenticated /mcp is
    // remote code execution for anyone who can reach the port. Refuse to
    // boot open unless the operator explicitly opts in — `cyfr init`
    // always provisions MCP_BRIDGE_TOKEN, so the happy path never hits this.
    if (process.env.MCP_BRIDGE_ALLOW_INSECURE === "1") {
      console.warn(
        "[mcp-bridge] WARNING: MCP_BRIDGE_TOKEN is unset and " +
          "MCP_BRIDGE_ALLOW_INSECURE=1 — /mcp is unauthenticated and relies " +
          "solely on network isolation."
      );
    } else {
      console.error(
        "[mcp-bridge] FATAL: MCP_BRIDGE_TOKEN is unset. /mcp dispatches " +
          "shell-spawning admin tools, so running without a bearer token is " +
          "remote code execution for anything that can reach this port. Set " +
          "MCP_BRIDGE_TOKEN (cyfr init generates one), or set " +
          "MCP_BRIDGE_ALLOW_INSECURE=1 to accept that risk on an isolated network."
      );
      process.exit(1);
    }
  }

  // This process supervises children and is itself supervised (compose
  // restart: unless-stopped): an unexpected failure crashes loudly and lets
  // the supervisor restart a clean instance, rather than limping on with
  // unknown state.
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

  const bridge = createBridge({ spawner, token: AUTH_TOKEN });

  let httpServer = null;
  let stopping = false;
  async function shutdown(signal) {
    if (stopping) return;
    stopping = true;
    console.log(`[mcp-bridge] ${signal} — stopping ${bridge.backends.size} backends`);
    // Hard stop inside compose's stop_grace_period if a request never drains.
    setTimeout(() => process.exit(0), 12_000).unref();
    // Stop accepting and let in-flight requests drain while the children are
    // retired in parallel, so pending calls against them fail promptly.
    const drained = new Promise((resolve) => (httpServer ? httpServer.close(() => resolve()) : resolve()));
    await Promise.all([drained, bridge.close()]);
    process.exit(0);
  }
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));

  try {
    await fs.access(path.dirname(PERSIST), fsConstants.W_OK);
  } catch {
    console.warn(
      `[mcp-bridge] WARNING: ${path.dirname(PERSIST)} is not writable by uid ${process.getuid()}; ` +
        "backends will not persist across restarts. A host directory mounted there must be writable by that uid.",
    );
  }

  await bridge.revive();

  httpServer = bridge.app.listen(PORT, "0.0.0.0", () => {
    console.log(`[mcp-bridge] /mcp on :${PORT} (data: ${PERSIST}, auth: ${AUTH_TOKEN ? "on" : "off"})`);
  });
}

if (import.meta.main) main();
