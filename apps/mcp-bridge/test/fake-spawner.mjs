// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// An in-process spawner for the bridge's tests. It runs each backend as an
// ordinary child process of the test, in a process group of its own, and
// reproduces the spawner's contract: a refusal when the pool is full, `exit`
// when the leader ends, and retirement (SIGTERM, grace, SIGKILL to the
// group, then `released`) on release or on the leader's exit. It records
// every spawn and release in order.

import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import { Readable, Writable } from "node:stream";

export class FakeSpawner {
  /** Every spawn request, in order: `{ argv, env, proc }`. */
  spawns = [];
  /** A log of `spawn:<n>`, `release:<n>` and `released:<n>` events. */
  events = [];
  /** How many spawns may be live at once. */
  capacity;

  constructor({ capacity = Infinity } = {}) {
    this.capacity = capacity;
  }

  /** Spawns not yet released. */
  live() {
    return this.spawns.filter(({ proc }) => !proc.released).length;
  }

  spawn({ argv, env }) {
    const index = this.spawns.length + 1;
    const refused = this.live() >= this.capacity;
    const proc = new FakeProcess(this, index, argv, env, refused);
    this.spawns.push({ argv, env, proc });
    return proc;
  }
}

class FakeProcess extends EventEmitter {
  pid = null;
  exitCode = null;
  signalCode = null;
  released = false;
  stdin;
  stdout;
  stderr;

  #spawner;
  #index;
  #child = null;
  #releasePromise = null;
  #resolveRelease = null;
  #killTimer = null;

  constructor(spawner, index, argv, env, refused) {
    super();
    this.#spawner = spawner;
    this.#index = index;
    spawner.events.push(`spawn:${index}`);

    if (refused) {
      this.stdin = new Writable({ write: (_c, _e, cb) => cb(new Error("backend stdin unavailable")) });
      this.stdout = Readable.from([]);
      this.stderr = Readable.from([]);
      process.nextTick(() => {
        this.#markReleased();
        const err = new Error("spawn refused: capacity");
        err.code = "capacity";
        this.emit("error", err);
      });
      return;
    }

    const child = spawn(argv[0], argv.slice(1), {
      env: { PATH: process.env.PATH, ...env },
      stdio: ["pipe", "pipe", "pipe"],
      detached: true,
    });
    this.#child = child;
    this.pid = child.pid;
    this.stdin = child.stdin;
    this.stdout = child.stdout;
    this.stderr = child.stderr;
    child.on("spawn", () => this.emit("spawn"));
    child.on("error", (err) => this.emit("error", err));
    child.on("exit", (code, signal) => {
      this.exitCode = code;
      this.signalCode = signal;
      this.emit("exit", code, signal);
      // The leader's exit retires whatever else its group still runs.
      this.#killGroup("SIGKILL");
      clearTimeout(this.#killTimer);
      this.#markReleased();
    });
  }

  signal(sig) {
    if (this.released || this.exitCode !== null || this.signalCode !== null) return false;
    this.#killGroup(sig);
    return true;
  }

  release(graceMs) {
    if (!this.#releasePromise) {
      this.#spawner.events.push(`release:${this.#index}`);
      this.#releasePromise = new Promise((resolve) => (this.#resolveRelease = resolve));
      if (this.released) {
        this.#resolveRelease();
      } else {
        this.#killGroup("SIGTERM");
        this.#killTimer = setTimeout(() => this.#killGroup("SIGKILL"), graceMs);
      }
    }
    return this.#releasePromise;
  }

  #killGroup(sig) {
    try {
      process.kill(-this.#child.pid, sig);
    } catch {
      // The group is already gone.
    }
  }

  #markReleased() {
    if (this.released) return;
    this.released = true;
    this.#spawner.events.push(`released:${this.#index}`);
    this.#resolveRelease?.();
    this.emit("released");
  }
}
