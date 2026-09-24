// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The bridge's side of cyfr-keeper (apps/keeper). The spawner starts this
// process with a socketpair on fd 3 and starts, signals and retires every
// backend on request over it, one JSON object per line. Each backend's stdio
// reaches the bridge through a relay: a helper running as the bridge's own
// user that holds the backend's pipes, connects to the attach socket, sends
// the spawn's token and then carries stdin, stdout and stderr as frames of
// a 1-byte stream id, a 4-byte big-endian length and the payload. The bridge
// never runs as a backend's uid and holds no descriptor a backend holds.

import { EventEmitter } from "node:events";
import { randomBytes } from "node:crypto";
import { promises as fs } from "node:fs";
import net from "node:net";
import path from "node:path";
import { Readable, Writable } from "node:stream";

export const SPAWNER_PROTOCOL_VERSION = 1;

export const STREAM_STDIN = 0;
export const STREAM_STDOUT = 1;
export const STREAM_STDERR = 2;
export const STREAM_ATTACH = 3;
export const FRAME_HEADER_BYTES = 5;
export const MAX_FRAME_PAYLOAD = 64 * 1024;

// A spawner line longer than this is a protocol fault.
const MAX_LINE_BYTES = 1024 * 1024;

// How long a spawned backend's relay has to attach.
const ATTACH_TIMEOUT_MS = 10_000;

const EMPTY = Buffer.alloc(0);

/** Encodes one frame. */
export function encodeFrame(stream, payload = EMPTY) {
  if (payload.length > MAX_FRAME_PAYLOAD) throw new RangeError("frame payload exceeds the maximum");
  const header = Buffer.alloc(FRAME_HEADER_BYTES);
  header[0] = stream;
  header.writeUInt32BE(payload.length, 1);
  return Buffer.concat([header, payload]);
}

/** Splits a byte stream into [stream, payload] frames; throws on a malformed frame. */
export class FrameDecoder {
  #buffer = EMPTY;

  push(chunk) {
    this.#buffer = this.#buffer.length ? Buffer.concat([this.#buffer, chunk]) : chunk;
    const frames = [];
    while (this.#buffer.length >= FRAME_HEADER_BYTES) {
      const stream = this.#buffer[0];
      const length = this.#buffer.readUInt32BE(1);
      if (stream > STREAM_ATTACH) throw new Error("unknown frame stream");
      if (length > MAX_FRAME_PAYLOAD) throw new Error("frame payload exceeds the maximum");
      if (this.#buffer.length < FRAME_HEADER_BYTES + length) break;
      frames.push([stream, this.#buffer.subarray(FRAME_HEADER_BYTES, FRAME_HEADER_BYTES + length)]);
      this.#buffer = this.#buffer.subarray(FRAME_HEADER_BYTES + length);
    }
    return frames;
  }
}

/** A refusal from the spawner, carrying its protocol code. */
export class SpawnError extends Error {
  constructor(code) {
    super(`spawn refused: ${code}`);
    this.code = code;
  }
}

/**
 * The client of the spawner channel. `listen()` opens the attach socket;
 * `spawn()` returns a SpawnedProcess at once. Emits `lost` when the channel
 * closes, after which nothing it started can be managed.
 */
export class SpawnerClient extends EventEmitter {
  #channel;
  #attachDir;
  #attachPath;
  #pool;
  #server = null;
  #nextId = 0;
  #lineBuffer = EMPTY;
  #lost = false;
  #bySpawnId = new Map();
  #byRequestId = new Map();
  #byToken = new Map();
  #poolRequests = new Map();

  /**
   * @param {object} options
   * @param {import("node:stream").Duplex} options.channel the socket to the spawner (fd 3)
   * @param {string} options.attachDir a directory this user owns, mode 0700, for the attach socket
   * @param {string} options.pool the pool backends are spawned from
   */
  constructor({ channel, attachDir, pool }) {
    super();
    this.#channel = channel;
    this.#attachDir = attachDir;
    this.#attachPath = path.join(attachDir, "attach.sock");
    this.#pool = pool;
    channel.on("data", (chunk) => this.#onChannelData(chunk));
    channel.on("error", (err) => this.#onLost(err));
    channel.on("close", () => this.#onLost());
    channel.on("end", () => this.#onLost());
  }

  get attachPath() {
    return this.#attachPath;
  }

  /** Creates the attach directory and socket. Refuses a directory another user could reach. */
  async listen() {
    try {
      await fs.mkdir(this.#attachDir, { mode: 0o700 });
    } catch (err) {
      if (err.code !== "EEXIST") throw err;
    }
    const st = await fs.lstat(this.#attachDir);
    if (!st.isDirectory() || st.uid !== process.getuid() || (st.mode & 0o077) !== 0) {
      throw new Error(`${this.#attachDir} must be a directory owned by uid ${process.getuid()} with mode 0700`);
    }
    await fs.rm(this.#attachPath, { force: true });
    this.#server = net.createServer((conn) => this.#onAttach(conn));
    await new Promise((resolve, reject) => {
      this.#server.once("error", reject);
      this.#server.listen(this.#attachPath, () => {
        this.#server.off("error", reject);
        resolve();
      });
    });
  }

  /** Starts a backend; `argv` is executed directly and `env` is its whole environment block. */
  spawn({ argv, env = {}, rlimits }) {
    const id = String(++this.#nextId);
    const token = randomBytes(32).toString("hex");
    const proc = new SpawnedProcess(this, token);
    this.#byToken.set(token, proc);
    if (this.#lost) {
      process.nextTick(() => proc._failed(new SpawnError("channel_lost")));
      return proc;
    }
    this.#byRequestId.set(id, proc);
    this._send({
      type: "spawn",
      id,
      pool: this.#pool,
      argv,
      env,
      ...(rlimits ? { rlimits } : {}),
      attach: { path: this.#attachPath, token },
    });
    return proc;
  }

  /** Resolves to the pool's `{size, free, quarantined}`. */
  pool() {
    const id = String(++this.#nextId);
    return new Promise((resolve, reject) => {
      if (this.#lost) return reject(new SpawnError("channel_lost"));
      this.#poolRequests.set(id, { resolve, reject });
      this._send({ type: "pool", id, pool: this.#pool });
    });
  }

  /** Closes the attach socket. */
  async close() {
    if (this.#server) await new Promise((resolve) => this.#server.close(() => resolve()));
  }

  _send(message) {
    if (this.#lost) return false;
    this.#channel.write(JSON.stringify({ v: SPAWNER_PROTOCOL_VERSION, ...message }) + "\n");
    return true;
  }

  _forget(proc) {
    this.#byToken.delete(proc._token);
    if (proc.spawnId) this.#bySpawnId.delete(proc.spawnId);
  }

  #onChannelData(chunk) {
    this.#lineBuffer = this.#lineBuffer.length ? Buffer.concat([this.#lineBuffer, chunk]) : chunk;
    let newline;
    while ((newline = this.#lineBuffer.indexOf(0x0a)) >= 0) {
      const line = this.#lineBuffer.subarray(0, newline).toString("utf8");
      this.#lineBuffer = this.#lineBuffer.subarray(newline + 1);
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.#channel.destroy(new Error("spawner sent a line that is not JSON"));
        return;
      }
      this.#dispatch(message);
    }
    if (this.#lineBuffer.length > MAX_LINE_BYTES) {
      this.#channel.destroy(new Error("spawner line exceeds the maximum"));
    }
  }

  #dispatch(message) {
    if (message?.v !== SPAWNER_PROTOCOL_VERSION) return;
    switch (message.type) {
      case "spawned": {
        const proc = this.#byRequestId.get(message.id);
        if (!proc) return;
        this.#byRequestId.delete(message.id);
        this.#bySpawnId.set(message.spawn_id, proc);
        proc._spawned(message.spawn_id, message.uid, message.pid);
        return;
      }
      case "error": {
        if (message.id !== undefined) {
          const pending = this.#poolRequests.get(message.id);
          if (pending) {
            this.#poolRequests.delete(message.id);
            pending.reject(new SpawnError(message.code));
            return;
          }
          const proc = this.#byRequestId.get(message.id);
          if (proc) {
            this.#byRequestId.delete(message.id);
            proc._failed(new SpawnError(message.code));
          }
          return;
        }
        // A release or signal for a spawn the spawner no longer has: its
        // retirement already finished.
        if (message.code === "unknown_spawn") this.#bySpawnId.get(message.spawn_id)?._released();
        return;
      }
      case "exited":
        this.#bySpawnId.get(message.spawn_id)?._exited(message.code, message.signal);
        return;
      case "released":
        this.#bySpawnId.get(message.spawn_id)?._released();
        return;
      case "pool": {
        const pending = this.#poolRequests.get(message.id);
        if (!pending) return;
        this.#poolRequests.delete(message.id);
        pending.resolve({ size: message.size, free: message.free, quarantined: message.quarantined });
        return;
      }
      default:
        return;
    }
  }

  #onAttach(conn) {
    const decoder = new FrameDecoder();
    let proc = null;
    const timer = setTimeout(() => conn.destroy(), ATTACH_TIMEOUT_MS);
    conn.on("error", () => {});
    conn.on("close", () => {
      clearTimeout(timer);
      proc?._detached();
    });
    conn.on("data", (chunk) => {
      let frames;
      try {
        frames = decoder.push(chunk);
      } catch {
        conn.destroy();
        return;
      }
      for (const [stream, payload] of frames) {
        if (proc) {
          if (!proc._frame(stream, payload)) {
            conn.destroy();
            return;
          }
          continue;
        }
        const candidate = stream === STREAM_ATTACH ? this.#byToken.get(payload.toString("latin1")) : undefined;
        if (!candidate || !candidate._attach(conn)) {
          conn.destroy();
          return;
        }
        this.#byToken.delete(candidate._token);
        clearTimeout(timer);
        proc = candidate;
      }
    });
  }

  #onLost(err) {
    if (this.#lost) return;
    this.#lost = true;
    for (const pending of this.#poolRequests.values()) pending.reject(new SpawnError("channel_lost"));
    this.#poolRequests.clear();
    for (const proc of this.#byRequestId.values()) proc._failed(new SpawnError("channel_lost"));
    this.#byRequestId.clear();
    for (const proc of this.#bySpawnId.values()) proc._released();
    this.#bySpawnId.clear();
    this.emit("lost", err);
  }
}

/**
 * One backend started through the spawner, shaped like a ChildProcess:
 * `stdin`, `stdout` and `stderr` streams, `spawn`, `error` and `exit`
 * events, and `released` once its uid has been retired.
 */
export class SpawnedProcess extends EventEmitter {
  pid = null;
  uid = null;
  spawnId = null;
  exitCode = null;
  signalCode = null;
  stdin;
  stdout;
  stderr;
  _token;

  #client;
  #conn = null;
  #queued = [];
  #failed = false;
  #detached = false;
  #released = false;
  #releaseGraceMs = null;
  #releasePromise = null;
  #resolveRelease = null;
  #attachTimer = null;
  #ended = new Set();

  constructor(client, token) {
    super();
    this.#client = client;
    this._token = token;
    this.stdout = new Readable({ read() {} });
    this.stderr = new Readable({ read() {} });
    this.stdin = new Writable({
      write: (chunk, _encoding, callback) => this.#write(chunk, callback),
      final: (callback) => this.#write(null, callback),
    });
  }

  /** Signals the backend's process group while its leader runs. */
  signal(sig) {
    if (!this.spawnId || this.exitCode !== null || this.signalCode !== null || this.#released) return false;
    return this.#client._send({ type: "signal", spawn_id: this.spawnId, sig });
  }

  /**
   * Retires the backend: SIGTERM to every process of its uid, `graceMs` to
   * exit, then SIGKILL and removal of its home. Resolves once the spawner
   * reports the uid retired, or at once if the spawn never started.
   */
  release(graceMs) {
    if (!this.#releasePromise) {
      this.#releasePromise = new Promise((resolve) => {
        this.#resolveRelease = resolve;
      });
      if (this.#failed || this.#released) this.#resolveRelease();
      else if (this.spawnId) this.#client._send({ type: "release", spawn_id: this.spawnId, grace_ms: graceMs });
      else this.#releaseGraceMs = graceMs;
    }
    return this.#releasePromise;
  }

  _spawned(spawnId, uid, pid) {
    this.spawnId = spawnId;
    this.uid = uid;
    this.pid = pid;
    if (!this.#conn && !this.#detached) {
      this.#attachTimer = setTimeout(() => {
        this.#abandonStdio(new Error("the backend's relay did not attach"));
        if (this.listenerCount("error") > 0) this.emit("error", new SpawnError("attach_timeout"));
        this.release(0);
      }, ATTACH_TIMEOUT_MS);
      this.#attachTimer.unref?.();
    }
    this.emit("spawn");
    if (this.#releaseGraceMs !== null) {
      this.#client._send({ type: "release", spawn_id: spawnId, grace_ms: this.#releaseGraceMs });
    }
  }

  _failed(err) {
    if (this.#failed) return;
    this.#failed = true;
    this.#client._forget(this);
    this.#abandonStdio(err);
    this.#resolveRelease?.();
    // A handle nobody listens to must not throw from the channel's handlers.
    if (this.listenerCount("error") > 0) this.emit("error", err);
  }

  _exited(code, signal) {
    this.exitCode = code ?? null;
    this.signalCode = signal ?? null;
    this.emit("exit", this.exitCode, this.signalCode);
  }

  _released() {
    if (this.#released) return;
    this.#released = true;
    this.#client._forget(this);
    clearTimeout(this.#attachTimer);
    this.#resolveRelease?.();
    this.emit("released");
  }

  _attach(conn) {
    if (this.#conn || this.#detached || this.#failed) return false;
    this.#conn = conn;
    clearTimeout(this.#attachTimer);
    for (const { chunk, callback } of this.#queued.splice(0)) this.#send(chunk, callback);
    return true;
  }

  // Returns false for a frame a relay may not send.
  _frame(stream, payload) {
    const target = stream === STREAM_STDOUT ? this.stdout : stream === STREAM_STDERR ? this.stderr : null;
    if (!target) return false;
    if (payload.length === 0) this.#end(target);
    else if (!this.#ended.has(target)) target.push(Buffer.from(payload));
    return true;
  }

  _detached() {
    this.#conn = null;
    this.#abandonStdio(new Error("backend stdin unavailable"));
  }

  #abandonStdio(err) {
    this.#detached = true;
    clearTimeout(this.#attachTimer);
    for (const { callback } of this.#queued.splice(0)) callback(err);
    if (this.#conn) {
      this.#conn.destroy();
      this.#conn = null;
    }
    this.#end(this.stdout);
    this.#end(this.stderr);
  }

  #end(stream) {
    if (this.#ended.has(stream)) return;
    this.#ended.add(stream);
    stream.push(null);
  }

  #write(chunk, callback) {
    if (this.#conn) return this.#send(chunk, callback);
    if (this.#detached || this.#failed) return callback(new Error("backend stdin unavailable"));
    this.#queued.push({ chunk, callback });
  }

  // `chunk` null ends stdin.
  #send(chunk, callback) {
    const conn = this.#conn;
    if (chunk === null) return conn.write(encodeFrame(STREAM_STDIN), (err) => callback(err));
    // A zero-length frame would end stdin.
    if (chunk.length === 0) return callback();
    const frames = [];
    for (let offset = 0; offset < chunk.length; offset += MAX_FRAME_PAYLOAD) {
      frames.push(encodeFrame(STREAM_STDIN, chunk.subarray(offset, offset + MAX_FRAME_PAYLOAD)));
    }
    conn.write(Buffer.concat(frames), (err) => callback(err));
  }
}
