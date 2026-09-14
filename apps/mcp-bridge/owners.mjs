// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The bridge's owners: one per (athanor, server row), running at the
// control-plane generation `g` and owner epoch `e` its last sync named, each
// with the stdio MCP backends that sync defined. An owner lives while its
// lease does; nothing about it is persisted.
//
// Owner states: starting (a sync is spawning its backends) → running →
// draining (its spawns are being retired) → gone. A backend is spawning →
// initializing → ready; a backend that exits is crashed and restarts after
// 1, 2, 4, 8 then 16 s, and its fifth exit within ten minutes marks it
// failed, with its tools withdrawn, until a sync at a new version replaces
// the owner.
//
// A backend's stdout carries MCP JSON-RPC frames and nothing of it is
// logged; its stderr is kept in memory (the last 64 KiB) and never logged.
// Everything an owner's backends produce that leaves the bridge passes
// through `mask`, which replaces the owner's credential values.

import { createRequire } from "node:module";

const VERSION = createRequire(import.meta.url)("./package.json").version;

// Outbound stdio uses the shared fallback protocol revision and initializes child servers.
const CHILD_PROTOCOL_VERSION = "2025-03-26";

// Ceiling on one child stdout frame (a single line without its newline).
const MAX_FRAME_BYTES = 10 * 1024 * 1024;

export const STDERR_TAIL_BYTES = 64 * 1024;
// Raw stderr kept beyond the tail, so a credential split by the cut is
// masked before the cut is taken.
const STDERR_SLACK_BYTES = 4 * 1024;

export const MAX_LEASE_MS = 60_000;
export const SYNC_READY_TIMEOUT_MS = 15_000;
export const NONCE_WINDOW_MS = 30_000;
export const MAX_NONCES = 8192;
export const MAX_BACKENDS = 16;
export const MAX_COMMAND_BYTES = 4096;

export const RESTART_BACKOFF_MS = [1000, 2000, 4000, 8000, 16000];
export const CRASH_WINDOW_MS = 10 * 60_000;
export const MAX_CRASHES = 5;

// Names CYFR lets hold a literal value. Every other environment value is a
// credential from the vault and is masked in everything returned.
export const LITERAL_ENV_NAMES = new Set(["NODE_ENV", "LOG_LEVEL", "TZ", "LANG", "LC_ALL", "NO_COLOR", "DEBUG"]);
const RESERVED_ENV_NAMES = new Set(["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PWD"]);
const RESERVED_ENV_PREFIXES = ["CYFR_", "MCP_BRIDGE_"];

const BACKEND_NAME = /^[a-z0-9][a-z0-9-]{0,31}$/;
const ENV_NAME = /^[A-Z_][A-Z0-9_]{0,63}$/;
const MIN_MASKED_BYTES = 8;

/** A refusal answered to CYFR as `{error: code}` with an HTTP status. */
export class Refusal extends Error {
  constructor(code, status = 409) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

const badRequest = () => new Refusal("bad_request", 400);

// A refusal whose message is written for the caller: the only thrown text
// that reaches the wire as a tool error.
export class RpcRefusal extends Error {}

// An error a backend answered with; its text is the backend's own and is
// returned masked, never logged.
class ChildError extends Error {}

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

/** Compares two (g, e) versions lexicographically. */
export function compareVersions(a, b) {
  if (a.g !== b.g) return a.g < b.g ? -1 : 1;
  if (a.e !== b.e) return a.e < b.e ? -1 : 1;
  return 0;
}

/**
 * Validates a sync's backend definitions; throws a 400 refusal. Returns the
 * definitions in a canonical shape: `[{name, command, env_names}]`, each
 * backend's env_names sorted.
 */
export function validateBackends(backends) {
  if (!Array.isArray(backends) || backends.length < 1 || backends.length > MAX_BACKENDS) throw badRequest();
  const names = new Set();
  return backends.map((backend) => {
    if (!backend || typeof backend !== "object" || Array.isArray(backend)) throw badRequest();
    const keys = Object.keys(backend).sort();
    if (keys.join(",") !== "command,env_names,name") throw badRequest();
    const { name, command, env_names: envNames } = backend;
    if (typeof name !== "string" || !BACKEND_NAME.test(name) || names.has(name)) throw badRequest();
    names.add(name);
    if (
      typeof command !== "string" ||
      command === "" ||
      Buffer.byteLength(command) > MAX_COMMAND_BYTES ||
      command.includes("\0") ||
      command.includes("vault:")
    ) {
      throw badRequest();
    }
    if (!Array.isArray(envNames)) throw badRequest();
    const seen = new Set();
    for (const envName of envNames) {
      if (typeof envName !== "string" || !ENV_NAME.test(envName) || seen.has(envName)) throw badRequest();
      if (RESERVED_ENV_NAMES.has(envName) || RESERVED_ENV_PREFIXES.some((p) => envName.startsWith(p))) {
        throw badRequest();
      }
      seen.add(envName);
    }
    return { name, command, env_names: [...envNames].sort() };
  });
}

/**
 * Validates a sync's opened environment against its definitions: an object
 * whose keys are exactly the backend names, each an object whose keys are
 * exactly that backend's env_names, with string values. Throws a 400.
 */
export function validateEnvironment(definitions, env) {
  if (!env || typeof env !== "object" || Array.isArray(env)) throw badRequest();
  const backendNames = definitions.map((d) => d.name).sort();
  if (Object.keys(env).sort().join("\n") !== backendNames.join("\n")) throw badRequest();
  for (const definition of definitions) {
    const block = env[definition.name];
    if (!block || typeof block !== "object" || Array.isArray(block)) throw badRequest();
    if (Object.keys(block).sort().join("\n") !== definition.env_names.join("\n")) throw badRequest();
    if (Object.values(block).some((value) => typeof value !== "string")) throw badRequest();
  }
}

/** The values `mask` replaces for an environment: `{backend: {NAME: value}}`. */
export function secretValues(env) {
  const values = new Set();
  for (const block of Object.values(env)) {
    for (const [name, value] of Object.entries(block)) {
      if (LITERAL_ENV_NAMES.has(name)) continue;
      // A scheme-prefixed value ("Bearer <token>") is masked whole and as
      // its token.
      const parts = [value, value.split(" ").at(-1)];
      for (const part of parts) if (Buffer.byteLength(part) >= MIN_MASKED_BYTES) values.add(part);
    }
  }
  // Longest first, so a value containing another is replaced whole.
  return [...values].sort((a, b) => b.length - a.length);
}

/** Replaces every secret in every string of `value`, recursively. */
export function mask(value, secrets) {
  if (secrets.length === 0) return value;
  if (typeof value === "string") {
    let out = value;
    for (const secret of secrets) out = out.split(secret).join("[REDACTED]");
    return out;
  }
  if (Array.isArray(value)) return value.map((item) => mask(item, secrets));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [mask(k, secrets), mask(v, secrets)]));
  }
  return value;
}

const ownerKey = (athanor, server) => `${athanor}/${server}`;

/**
 * The owner table over a spawner. The spawner starts a backend with
 * `spawn({ argv, env })`, answers `pool()` with `{size, free}`, and returns a
 * handle shaped like a ChildProcess (`stdin`, `stdout`, `stderr`, `spawn`,
 * `error` and `exit` events) plus `release(graceMs)`, which retires every
 * process of the backend and resolves once that is done.
 */
export class Owners {
  #spawner;
  #now;
  #log;
  #owners = new Map();
  #locks = new Map();
  #leaseTimer;
  #options;

  constructor({
    spawner,
    now = Date.now,
    log = console,
    rpcTimeoutMs = 30_000,
    initTimeoutMs = 15_000,
    readyTimeoutMs = SYNC_READY_TIMEOUT_MS,
    maxInFlight = 32,
    stopGraceMs = 2000,
    releaseTimeoutMs = 15_000,
    spawnTimeoutMs = 15_000,
    leaseCheckMs = 1000,
    restartBackoffMs = RESTART_BACKOFF_MS,
  }) {
    this.#spawner = spawner;
    this.#now = now;
    this.#log = log;
    this.#options = {
      rpcTimeoutMs,
      initTimeoutMs,
      readyTimeoutMs,
      maxInFlight,
      stopGraceMs,
      releaseTimeoutMs,
      spawnTimeoutMs,
      restartBackoffMs,
    };
    this.#leaseTimer = setInterval(() => this.#expireLeases(), leaseCheckMs);
    this.#leaseTimer.unref?.();
  }

  /** The owner of (athanor, server), draining ones included. */
  get(athanor, server) {
    return this.#owners.get(ownerKey(athanor, server));
  }

  get size() {
    return this.#owners.size;
  }

  /**
   * Starts, replaces or extends an owner. `backends` come from
   * `validateBackends`; `openEnv()` answers the opened environment
   * (`{backend: {NAME: value}}`) and is called only for a new version.
   * Syncs of one owner run one at a time. Resolves to `{status, backends}`;
   * throws a Refusal.
   */
  sync({ athanor, server, g, e, leaseMs, backends, openEnv }) {
    return this.#locked(ownerKey(athanor, server), () =>
      this.#sync({ athanor, server, g, e, leaseMs, backends, openEnv }),
    );
  }

  async #sync({ athanor, server, g, e, leaseMs, backends, openEnv }) {
    const key = ownerKey(athanor, server);
    const existing = this.#owners.get(key);
    const definition = JSON.stringify(backends);

    if (existing) {
      const order = compareVersions({ g, e }, existing);
      if (order < 0) throw new Refusal("stale_epoch");
      if (order === 0) {
        if (existing.definition !== definition) throw new Refusal("conflict");
        if (existing.state === "draining") throw new Refusal("lapsed");
        existing.leaseUntil = this.#now() + leaseMs;
        return this.#answer(existing);
      }
    }

    const env = openEnv();
    validateEnvironment(backends, env);

    if (existing) {
      this.#unroute(existing);
      await this.#drain(existing);
    }

    let pool;
    try {
      pool = await this.#spawner.pool();
    } catch {
      throw new Refusal("capacity");
    }
    if (!(pool.free >= backends.length)) throw new Refusal("capacity");

    const owner = {
      athanor,
      server,
      key,
      g,
      e,
      definition,
      state: "starting",
      leaseUntil: this.#now() + leaseMs,
      secrets: secretValues(env),
      nonces: new Map(),
      backends: new Map(),
      drained: null,
    };
    for (const { name, command } of backends) {
      owner.backends.set(name, this.#newBackend(owner, name, command, env[name]));
    }
    this.#owners.set(key, owner);

    const started = await Promise.allSettled([...owner.backends.values()].map((b) => this.#spawn(b)));
    const refused = started.find((r) => r.status === "rejected");
    if (refused) {
      this.#unroute(owner);
      await this.#drain(owner);
      const code = refused.reason?.code === "capacity" ? "capacity" : "spawn_failed";
      throw new Refusal(code);
    }

    await withTimeout(
      Promise.all([...owner.backends.values()].map((b) => b.settled)),
      this.#options.readyTimeoutMs,
    );

    if (this.#owners.get(key) !== owner || owner.state === "draining") throw new Refusal("conflict");
    owner.state = "running";
    owner.leaseUntil = this.#now() + leaseMs;
    return this.#answer(owner);
  }

  #answer(owner) {
    return {
      status: owner.state,
      backends: [...owner.backends.values()].map((b) => ({ name: b.name, status: b.status, tools: b.tools.length })),
    };
  }

  /** Extends the leases of the owners running at exactly (g, e). */
  renew(entries, g, leaseMs) {
    const renewed = [];
    const unknown = [];
    const now = this.#now();
    for (const { athanor, server, e } of entries) {
      const owner = this.#owners.get(ownerKey(athanor, server));
      if (owner && owner.state !== "draining" && owner.g === g && owner.e === e && owner.leaseUntil > now) {
        owner.leaseUntil = now + leaseMs;
        renewed.push({ athanor, server, e });
      } else {
        unknown.push({ athanor, server, e });
      }
    }
    return { renewed, unknown };
  }

  /** Drains every owner at or below (g, e); they leave routing at once. */
  release(entries, g) {
    const released = [];
    for (const { athanor, server, e } of entries) {
      const owner = this.#owners.get(ownerKey(athanor, server));
      if (!owner || owner.state === "draining") continue;
      if (compareVersions(owner, { g, e }) > 0) continue;
      released.push(this.#describeVersion(owner));
      this.#unroute(owner);
      this.#drain(owner);
    }
    return { released };
  }

  /** Drains every owner not running at exactly (g, its kept e). */
  reconcile(keep, g) {
    const kept = new Map(keep.map(({ athanor, server, e }) => [ownerKey(athanor, server), e]));
    const released = [];
    for (const owner of [...this.#owners.values()]) {
      if (owner.state === "draining") continue;
      if (owner.g === g && kept.get(owner.key) === owner.e) continue;
      released.push(this.#describeVersion(owner));
      this.#unroute(owner);
      this.#drain(owner);
    }
    return { released };
  }

  /** What each named owner present is running, masked. */
  status(entries) {
    const now = this.#now();
    const owners = [];
    for (const { athanor, server } of entries) {
      const owner = this.#owners.get(ownerKey(athanor, server));
      if (!owner) continue;
      owners.push({
        athanor,
        server,
        g: owner.g,
        e: owner.e,
        state: owner.state,
        lease_ms_left: Math.max(0, owner.leaseUntil - now),
        backends: [...owner.backends.values()].map((b) => ({
          name: b.name,
          status: b.status,
          restarts: b.restarts,
          tools: b.tools.length,
          error: mask(b.error, owner.secrets),
          stderr_tail: mask(stderrTail(b), owner.secrets).slice(-STDERR_TAIL_BYTES),
        })),
      });
    }
    return { owners };
  }

  /**
   * The owner an invoke at (g, e) with `nonce` and timestamp `ts` may use;
   * throws a Refusal. Records the nonce.
   */
  admit({ athanor, server, g, e, ts, nonce }) {
    const owner = this.#owners.get(ownerKey(athanor, server));
    if (!owner) throw new Refusal("unknown_owner");
    const order = compareVersions({ g, e }, owner);
    if (order < 0) throw new Refusal("stale_epoch");
    if (order > 0) throw new Refusal("epoch_ahead");
    if (owner.state === "draining" || owner.leaseUntil <= this.#now()) {
      if (owner.state !== "draining") this.#lapse(owner);
      throw new Refusal("lapsed");
    }
    const now = this.#now();
    const seen = owner.nonces.get(nonce);
    if (seen !== undefined && seen > now) throw new Refusal("replay");
    if (owner.nonces.size >= MAX_NONCES) {
      for (const [n, expires] of owner.nonces) if (expires <= now) owner.nonces.delete(n);
      if (owner.nonces.size >= MAX_NONCES) throw new Refusal("nonce_cache_full", 503);
    }
    owner.nonces.set(nonce, ts + NONCE_WINDOW_MS);
    return owner;
  }

  /** The owner's ready backends' tools, renamed `<backend>__<tool>` and masked. */
  tools(owner) {
    const out = [];
    for (const b of owner.backends.values()) {
      if (b.status !== "ready") continue;
      for (const t of b.tools) {
        out.push({
          name: `${b.name}__${t.name}`,
          description: t.description ? `[${b.name}] ${t.description}` : `[${b.name}]`,
          inputSchema: t.inputSchema || { type: "object" },
        });
      }
    }
    return mask(out, owner.secrets);
  }

  /** Calls `<backend>__<tool>` on one of the owner's backends; the result is masked. */
  async callTool(owner, toolName, args) {
    const sep = toolName.indexOf("__");
    if (sep <= 0) throw new RpcRefusal(`unknown tool: ${toolName}`);
    const backend = owner.backends.get(toolName.slice(0, sep));
    if (!backend) throw new RpcRefusal(`unknown tool: ${toolName}`);
    if (backend.status !== "ready") {
      throw new RpcRefusal(mask(`backend '${backend.name}' not ready: ${backend.error || backend.status}`, owner.secrets));
    }
    try {
      const result = await this.#rpc(backend, "tools/call", { name: toolName.slice(sep + 2), arguments: args || {} });
      return mask(result, owner.secrets);
    } catch (err) {
      if (err instanceof RpcRefusal) throw err;
      // A backend's own error text, or the bridge's account of a call that
      // did not finish (a timeout, an exit).
      const text = err instanceof ChildError ? err.message : `backend '${backend.name}' call failed: ${err.message}`;
      throw new RpcRefusal(mask(text, owner.secrets));
    }
  }

  /** Drains every owner and resolves once each is retired. */
  async close() {
    clearInterval(this.#leaseTimer);
    const owners = [...this.#owners.values()];
    for (const owner of owners) this.#unroute(owner);
    await Promise.allSettled(owners.map((owner) => this.#drain(owner)));
  }

  #describeVersion(owner) {
    return { athanor: owner.athanor, server: owner.server, g: owner.g, e: owner.e };
  }

  // Serializes syncs for one owner.
  #locked(key, fn) {
    const previous = this.#locks.get(key) || Promise.resolve();
    const run = previous.then(fn, fn);
    const tail = run.catch(() => {});
    this.#locks.set(key, tail);
    tail.then(() => {
      if (this.#locks.get(key) === tail) this.#locks.delete(key);
    });
    return run;
  }

  #unroute(owner) {
    if (this.#owners.get(owner.key) === owner) this.#owners.delete(owner.key);
  }

  #expireLeases() {
    const now = this.#now();
    for (const owner of this.#owners.values()) {
      if (owner.state !== "draining" && owner.leaseUntil <= now) this.#lapse(owner);
    }
  }

  // A lapsed owner answers `lapsed` while it retires, then is gone.
  #lapse(owner) {
    this.#log.log(`[owner ${owner.key}] lease lapsed at g=${owner.g} e=${owner.e}; retiring`);
    this.#drain(owner).then(() => this.#unroute(owner));
  }

  // Retires every spawn of the owner; resolves once each is released or its
  // bound passes.
  #drain(owner) {
    if (owner.drained) return owner.drained;
    owner.state = "draining";
    owner.drained = Promise.allSettled([...owner.backends.values()].map((b) => this.#stopBackend(b))).then(() => {});
    return owner.drained;
  }

  // ==========================================================================
  // Backends
  // ==========================================================================

  #newBackend(owner, name, command, env) {
    let settle;
    const settled = new Promise((resolve) => (settle = resolve));
    return {
      owner,
      name,
      command,
      env,
      label: `${owner.key} ${name}`,
      proc: null,
      status: "spawning",
      tools: [],
      error: null,
      initError: null,
      restarts: 0,
      crashes: [],
      stopped: false,
      restartTimer: null,
      nextId: 0,
      pending: new Map(),
      buffer: "",
      stderr: [],
      stderrBytes: 0,
      settled,
      settle,
    };
  }

  // Spawns the backend's process and starts its handshake. Resolves once the
  // spawner confirms the process started; rejects with its refusal.
  #spawn(backend) {
    backend.status = "spawning";
    backend.tools = [];
    backend.buffer = "";
    backend.nextId = 0;
    const proc = this.#spawner.spawn({ argv: ["/bin/sh", "-c", backend.command], env: backend.env });
    backend.proc = proc;

    const confirmed = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Object.assign(new Error("spawn timed out"), { code: "timeout" })), this.#options.spawnTimeoutMs);
      timer.unref?.();
      proc.once("spawn", () => {
        clearTimeout(timer);
        resolve();
      });
      proc.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });

    proc.stdout.setEncoding("utf8");
    proc.stdout.on("data", (chunk) => this.#onStdout(backend, proc, chunk));
    proc.stderr.on("data", (chunk) => this.#onStderr(backend, proc, chunk));

    for (const [label, stream] of [["stdin", proc.stdin], ["stdout", proc.stdout], ["stderr", proc.stderr]]) {
      stream.on("error", (err) => {
        if (backend.proc !== proc) return;
        this.#failPending(backend, new Error(`${label}: ${err.message}`));
      });
    }

    let started = false;
    proc.once("spawn", () => (started = true));
    proc.on("error", (err) => {
      if (backend.proc !== proc) return;
      // A first spawn the spawner refuses fails the sync, which retires the owner.
      if (!started && backend.restarts === 0) return;
      this.#crashed(backend, proc, err.code ? `spawn refused: ${err.code}` : err.message);
    });

    proc.on("exit", (code, signal) => {
      if (backend.proc !== proc) return;
      this.#crashed(backend, proc, `exited code=${code} signal=${signal}`);
    });

    return confirmed.then(() => {
      if (backend.proc === proc && !backend.stopped) this.#initialize(backend, proc);
    });
  }

  async #initialize(backend, proc) {
    backend.status = "initializing";
    try {
      await this.#rpc(
        backend,
        "initialize",
        {
          protocolVersion: CHILD_PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: { name: "cyfr-mcp-bridge", version: VERSION },
        },
        this.#options.initTimeoutMs,
      );
      this.#notify(backend, "notifications/initialized");
      const listed = await this.#rpc(backend, "tools/list", undefined, this.#options.initTimeoutMs);
      if (backend.proc !== proc || backend.stopped) return;
      backend.tools = Array.isArray(listed?.tools) ? listed.tools : [];
      backend.status = "ready";
      backend.error = null;
      this.#log.log(`[owner ${backend.label}] ready, ${backend.tools.length} tools`);
      backend.settle();
    } catch (err) {
      // A process that already exited was counted as crashed when it did.
      if (backend.proc !== proc || backend.stopped || backend.status !== "initializing") return;
      // A handshake that did not finish ends the process; its exit counts as a crash.
      backend.initError = err instanceof ChildError ? `initialize refused: ${err.message}` : err.message;
      this.#log.error(`[owner ${backend.label}] initialize failed`);
      proc.release(0);
    }
  }

  #crashed(backend, proc, reason) {
    if (backend.stopped || backend.status === "crashed" || backend.status === "failed") {
      this.#failPending(backend, new Error("backend stopped"));
      return;
    }
    backend.status = "crashed";
    backend.error = backend.initError ? `${backend.initError}; ${reason}` : reason;
    backend.initError = null;
    backend.tools = [];
    this.#failPending(backend, new Error(reason));
    proc.release(0);

    const now = this.#now();
    backend.crashes = backend.crashes.filter((at) => now - at < CRASH_WINDOW_MS);
    backend.crashes.push(now);
    if (backend.crashes.length >= MAX_CRASHES) {
      backend.status = "failed";
      this.#log.error(`[owner ${backend.label}] failed after ${backend.crashes.length} crashes`);
      backend.settle();
      return;
    }
    const backoff = this.#options.restartBackoffMs;
    const delay = backoff[Math.min(backend.crashes.length - 1, backoff.length - 1)];
    this.#log.error(`[owner ${backend.label}] crashed; restarting in ${delay} ms`);
    backend.restartTimer = setTimeout(() => {
      backend.restartTimer = null;
      if (backend.stopped) return;
      backend.restarts += 1;
      this.#spawn(backend).catch(() => {});
    }, delay);
    backend.restartTimer.unref?.();
  }

  // Retires the backend's processes: SIGTERM, the grace period, then SIGKILL
  // for every process of its uid. Settles once the spawner reports the uid
  // retired, or after a bound if it never does.
  #stopBackend(backend) {
    backend.stopped = true;
    clearTimeout(backend.restartTimer);
    backend.restartTimer = null;
    backend.tools = [];
    this.#failPending(backend, new Error("backend stopped"));
    backend.settle();
    const proc = backend.proc;
    if (!proc) return Promise.resolve();
    const { stopGraceMs, releaseTimeoutMs } = this.#options;
    return withTimeout(proc.release(stopGraceMs), stopGraceMs + releaseTimeoutMs);
  }

  #onStdout(backend, proc, chunk) {
    if (backend.proc !== proc) return;
    backend.buffer += chunk;

    let idx;
    while ((idx = backend.buffer.indexOf("\n")) >= 0) {
      const line = backend.buffer.slice(0, idx).trim();
      backend.buffer = backend.buffer.slice(idx + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (!msg || typeof msg !== "object") continue;

      // A `method` means the backend is sending its own request or
      // notification, with an id counter of its own that may collide with
      // the bridge's: it is never matched against a pending call.
      if (msg.method !== undefined) {
        if (msg.id != null) {
          this.#write(backend, {
            jsonrpc: "2.0",
            id: msg.id,
            error: { code: -32601, message: `method not supported by bridge: ${msg.method}` },
          });
        }
        continue;
      }

      // Pending calls are keyed by the number the bridge minted; an id echoed
      // as a string matches its number.
      let key = msg.id;
      if (!backend.pending.has(key) && typeof key === "string" && key.trim() !== "") {
        const asNumber = Number(key);
        if (Number.isFinite(asNumber) && backend.pending.has(asNumber)) key = asNumber;
      }

      if (msg.id != null && backend.pending.has(key)) {
        const { resolve, reject, timer } = backend.pending.get(key);
        backend.pending.delete(key);
        clearTimeout(timer);
        if (msg.error) {
          const text = typeof msg.error.message === "string" ? msg.error.message : JSON.stringify(msg.error);
          reject(new ChildError(text));
        } else {
          resolve(msg.result);
        }
      }
    }

    // Bounds a partial frame with no newline, checked on what is left after
    // draining the complete frames.
    if (backend.buffer.length > MAX_FRAME_BYTES) {
      this.#log.error(`[owner ${backend.label}] stdout frame exceeded ${MAX_FRAME_BYTES} bytes; killing backend`);
      backend.buffer = "";
      backend.error = "stdout frame overflow";
      proc.signal("SIGKILL");
    }
  }

  #onStderr(backend, proc, chunk) {
    if (backend.proc !== proc) return;
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    backend.stderr.push(bytes);
    backend.stderrBytes += bytes.length;
    const keep = STDERR_TAIL_BYTES + STDERR_SLACK_BYTES;
    while (backend.stderrBytes - backend.stderr[0].length >= keep) {
      backend.stderrBytes -= backend.stderr.shift().length;
    }
  }

  #failPending(backend, err) {
    for (const { reject, timer } of backend.pending.values()) {
      clearTimeout(timer);
      reject(err);
    }
    backend.pending.clear();
  }

  #write(backend, msg) {
    try {
      backend.proc.stdin.write(JSON.stringify(msg) + "\n");
      return true;
    } catch {
      return false;
    }
  }

  #rpc(backend, method, params, timeoutMs = this.#options.rpcTimeoutMs) {
    return new Promise((resolve, reject) => {
      if (!backend.proc || backend.stopped || backend.status === "crashed" || backend.status === "failed") {
        reject(new Error(`backend not running (${backend.status})`));
        return;
      }
      if (backend.pending.size >= this.#options.maxInFlight) {
        reject(new RpcRefusal(`backend busy: ${backend.pending.size} calls in flight`));
        return;
      }
      const id = ++backend.nextId;
      const timer = setTimeout(() => {
        if (backend.pending.delete(id)) reject(new Error(`timeout: ${method}`));
      }, timeoutMs);
      timer.unref?.();
      backend.pending.set(id, { resolve, reject, timer });
      if (!this.#write(backend, { jsonrpc: "2.0", id, method, ...(params !== undefined ? { params } : {}) })) {
        backend.pending.delete(id);
        clearTimeout(timer);
        reject(new Error(`backend stdin unavailable: ${method}`));
      }
    });
  }

  #notify(backend, method, params) {
    this.#write(backend, { jsonrpc: "2.0", method, ...(params !== undefined ? { params } : {}) });
  }
}

function stderrTail(backend) {
  return Buffer.concat(backend.stderr).toString("utf8");
}
