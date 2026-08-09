// CYFR mcp-bridge: wraps stdio MCP servers behind one HTTP MCP endpoint.
//
// Architecture: a single Streamable-HTTP-compatible /mcp endpoint. Tools
// surfaced through it are (a) admin tools — add_backend / remove_backend /
// list_backends / restart_backend — that manage the set of stdio children,
// and (b) every running child's tools, renamed `<backend>__<tool>`. cyfr
// registers this bridge as a normal HTTP MCP server (`mcp_servers create`)
// and sees all of the above under the `bridge:` namespace.
//
// The children are spawned as `sh -c <command>` (typically `npx -y <pkg>`)
// and speak MCP JSON-RPC over their stdin/stdout in newline-delimited frames.

import express from "express";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { timingSafeEqual } from "node:crypto";

// Single source for the bridge version: package.json.
const VERSION = JSON.parse(
  readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "package.json"), "utf8"),
).version;

// SECURITY / TRUST BOUNDARY
// -------------------------
// This bridge executes arbitrary `sh -c <command>` on behalf of `add_backend`,
// so anything that can POST to /mcp gets remote code execution *by design*. It
// is meant to run on a trusted container network only — docker-compose uses
// `expose` (never `ports:`), so the port is reachable from sibling containers
// (cyfr, neko) but not the host. Binding 0.0.0.0 is required for that
// cross-container reachability; do NOT change it to loopback and do NOT publish
// the port to the host.
//
// Defense-in-depth against a compromised sibling container: when
// MCP_BRIDGE_TOKEN is set, /mcp requires a matching `Authorization: Bearer`
// header. cyfr supplies it via the registered server's headers (e.g.
// `Authorization: vault:mcp_bridge_token`). `cyfr init` generates the token so
// the bridge boots closed; when unset, the bridge runs open and logs a warning
// at boot.

const PORT = Number(process.env.MCP_BRIDGE_PORT || 8001);
const AUTH_TOKEN = process.env.MCP_BRIDGE_TOKEN || "";
const PERSIST = process.env.MCP_BRIDGE_DATA || "/data/backends.json";
const PROTOCOL_VERSION = "2024-11-05";
const RPC_TIMEOUT_MS = Number(process.env.MCP_BRIDGE_RPC_TIMEOUT_MS || 30_000);
const INIT_TIMEOUT_MS = Number(process.env.MCP_BRIDGE_INIT_TIMEOUT_MS || 15_000);

const backends = new Map();

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

// ============================================================================
// Stdio MCP client (one per child)
// ============================================================================

function spawnBackend(name, command, env) {
  const proc = spawn("sh", ["-c", command], {
    env: { ...process.env, ...(env || {}) },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const backend = {
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
      if (msg.id != null && backend.pending.has(msg.id)) {
        const { resolve, reject, timer } = backend.pending.get(msg.id);
        backend.pending.delete(msg.id);
        if (timer) clearTimeout(timer);
        if (msg.error) reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else resolve(msg.result);
      }
      // Ignore unsolicited notifications from the child for now.
    }
  });

  proc.stderr.setEncoding("utf8");
  proc.stderr.on("data", (chunk) => {
    process.stderr.write(`[${name}] ${chunk}`);
  });

  proc.on("error", (err) => {
    backend.status = "error";
    backend.error = `spawn error: ${err.message}`;
    failPending(backend, new Error(backend.error));
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

function rpc(backend, method, params, timeoutMs = RPC_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    if (backend.status === "removed" || backend.status === "crashed") {
      reject(new Error(`backend not running (${backend.status})`));
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
    try {
      backend.proc.stdin.write(JSON.stringify(req) + "\n");
    } catch (e) {
      backend.pending.delete(id);
      clearTimeout(timer);
      reject(e);
    }
  });
}

function notify(backend, method, params) {
  const msg = {
    jsonrpc: "2.0",
    method,
    ...(params !== undefined ? { params } : {}),
  };
  try {
    backend.proc.stdin.write(JSON.stringify(msg) + "\n");
  } catch (e) {
    console.error(`[notify ${method}] write failed: ${e.message}`);
  }
}

async function initializeBackend(name) {
  const backend = backends.get(name);
  if (!backend) throw new Error(`backend '${name}' not found`);
  try {
    await rpc(
      backend,
      "initialize",
      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "cyfr-mcp-bridge", version: VERSION },
      },
      INIT_TIMEOUT_MS,
    );
    notify(backend, "notifications/initialized");
    const toolsRes = await rpc(backend, "tools/list", undefined, INIT_TIMEOUT_MS);
    backend.tools = toolsRes?.tools || [];
    backend.status = "ready";
    backend.error = null;
    console.log(`[${name}] ready, ${backend.tools.length} tools`);
  } catch (e) {
    backend.status = "error";
    backend.error = e.message;
    console.error(`[${name}] init failed: ${e.message}`);
  }
}

function stopBackend(name, markRemoved = true) {
  const backend = backends.get(name);
  if (!backend) return;
  if (markRemoved) backend.status = "removed";
  failPending(backend, new Error("backend stopped"));
  try {
    backend.proc.kill("SIGTERM");
  } catch {}
  // Hard-kill if it ignores SIGTERM.
  setTimeout(() => {
    try {
      if (!backend.proc.killed) backend.proc.kill("SIGKILL");
    } catch {}
  }, 2000).unref();
}

// ============================================================================
// Persistence
// ============================================================================

async function loadPersisted() {
  try {
    const text = await fs.readFile(PERSIST, "utf8");
    const data = JSON.parse(text);
    return Array.isArray(data?.backends) ? data.backends : [];
  } catch (e) {
    if (e.code === "ENOENT") return [];
    console.error(`[persist] load error: ${e.message}`);
    return [];
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
    await fs.mkdir(path.dirname(PERSIST), { recursive: true });
    const tmp = PERSIST + ".tmp";
    await fs.writeFile(tmp, JSON.stringify(data, null, 2));
    await fs.rename(tmp, PERSIST);
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

// ============================================================================
// Tool aggregation + dispatch
// ============================================================================

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
    if (!b) throw new Error(`backend '${backendName}' not found`);
    if (b.status !== "ready") {
      throw new Error(`backend '${backendName}' not ready: ${b.error || b.status}`);
    }
    return await rpc(b, "tools/call", { name: remoteName, arguments: args || {} });
  }

  throw new Error(`unknown tool: ${toolName}`);
}

async function adminAddBackend(args) {
  const name = String(args?.name || "").trim();
  const command = String(args?.command || "").trim();
  const env = args?.env && typeof args.env === "object" ? args.env : undefined;

  if (!name) throw new Error("name is required");
  if (!command) throw new Error("command is required");
  if (name.includes("__") || name.includes(":")) {
    throw new Error("backend name cannot contain `__` or `:`");
  }
  if (backends.has(name)) throw new Error(`backend '${name}' already exists`);

  spawnBackend(name, command, env);
  await initializeBackend(name);
  await persist();
  const b = backends.get(name);
  return wrapResult({
    name,
    status: b.status,
    tool_count: b.tools.length,
    error: b.error,
  });
}

async function adminRemoveBackend(args) {
  const name = String(args?.name || "").trim();
  if (!name) throw new Error("name is required");
  if (!backends.has(name)) throw new Error(`backend '${name}' not found`);
  stopBackend(name);
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
  if (!name) throw new Error("name is required");
  const existing = backends.get(name);
  if (!existing) throw new Error(`backend '${name}' not found`);
  const { command, env } = existing;
  stopBackend(name);
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

// ============================================================================
// HTTP / MCP transport
// ============================================================================

const app = express();
app.use(express.json({ limit: "10mb" }));

// Constant-time bearer check. Returns true when no token is configured
// (open mode) or when the request carries the matching bearer.
function authorized(req) {
  if (!AUTH_TOKEN) return true;

  const header = req.get("authorization") || "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  const a = Buffer.from(presented);
  const b = Buffer.from(AUTH_TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}

// /health is intentionally unauthenticated — it carries no sensitive data and
// the container healthcheck needs it.
app.get("/health", (_req, res) => {
  res.json({ ok: true, backends: backends.size });
});

app.post("/mcp", async (req, res) => {
  if (!authorized(req)) {
    return res.status(401).json({ error: "unauthorized" });
  }

  const msg = req.body;
  if (!msg || typeof msg !== "object") {
    return res.status(400).json({ error: "expected JSON-RPC body" });
  }

  // Notifications (no id) — return 204.
  if (msg.id === undefined || msg.id === null) {
    return res.status(204).end();
  }

  try {
    const result = await handleRpc(msg);
    return res.json({ jsonrpc: "2.0", id: msg.id, result });
  } catch (err) {
    console.error("[mcp] error:", err);
    return res.json({
      jsonrpc: "2.0",
      id: msg.id,
      error: {
        code: -32000,
        message: err?.message || String(err),
      },
    });
  }
});

async function handleRpc(msg) {
  switch (msg.method) {
    case "initialize":
      return {
        protocolVersion: PROTOCOL_VERSION,
        serverInfo: { name: "cyfr-mcp-bridge", version: VERSION },
        capabilities: { tools: {} },
      };
    case "ping":
      return {};
    case "tools/list":
      return { tools: aggregatedTools() };
    case "tools/call": {
      const { name, arguments: args } = msg.params || {};
      if (!name) throw new Error("tools/call: missing 'name'");
      try {
        return await dispatchToolCall(name, args || {});
      } catch (err) {
        // Surface tool-level failures as a successful JSON-RPC result with
        // isError=true so the upstream MCP client (cyfr) reports it to the
        // caller without treating the whole RPC as a protocol error.
        return wrapError(err?.message || String(err));
      }
    }
    default:
      throw new Error(`unsupported method: ${msg.method}`);
  }
}

// ============================================================================
// Boot
// ============================================================================

async function shutdown(signal) {
  console.log(`[mcp-bridge] ${signal} — stopping ${backends.size} backends`);
  for (const name of [...backends.keys()]) stopBackend(name);
  setTimeout(() => process.exit(0), 500).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

(async () => {
  const persisted = await loadPersisted();
  for (const entry of persisted) {
    if (!entry?.name || !entry?.command) continue;
    console.log(`[mcp-bridge] reviving '${entry.name}': ${entry.command}`);
    spawnBackend(entry.name, entry.command, entry.env);
    // Fire-and-forget — children come online in parallel.
    initializeBackend(entry.name).catch(() => {});
  }
  if (!AUTH_TOKEN) {
    console.warn(
      "[mcp-bridge] WARNING: MCP_BRIDGE_TOKEN is unset — /mcp is unauthenticated " +
        "and relies solely on network isolation. Set MCP_BRIDGE_TOKEN to require a bearer."
    );
  }
  app.listen(PORT, "0.0.0.0", () => {
    console.log(`[mcp-bridge] /mcp on :${PORT} (data: ${PERSIST}, auth: ${AUTH_TOKEN ? "on" : "off"})`);
  });
})();
