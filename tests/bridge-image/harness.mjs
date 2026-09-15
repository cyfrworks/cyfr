// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Runs the mcp-bridge image under docker compose with the mcp-bridge
// service's own settings (docker-compose.yml, layered with
// compose.isolation.yml), for the image tests. BRIDGE_IMAGE names an image
// already built from Dockerfile.node's mcp-bridge target; without it the
// harness builds cyfr-mcp-bridge:isolation first.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Controller } from "./controller.mjs";

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT_DIR = path.resolve(HERE, "..", "..");
export const IMAGE = process.env.BRIDGE_IMAGE || "cyfr-mcp-bridge:isolation";
export const PROBE = "node /probe/probe-backend.mjs";

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function run(cmd, args, { env, allowFailure = false } = {}) {
  const result = spawnSync(cmd, args, { env: env || process.env, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (!allowFailure && result.status !== 0) {
    throw new Error(`${cmd} ${args.join(" ")} exited ${result.status}\n${result.stdout}\n${result.stderr}`);
  }
  return result;
}

export async function eventually(check, what, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(100);
  }
}

export async function healthy(url) {
  await eventually(
    async () => {
      try {
        return (await fetch(`${url}/health`)).ok;
      } catch {
        return false;
      }
    },
    `${url}/health`,
    30_000,
  );
}

// Every process in a container: pid, session, uids, capability sets,
// no_new_privs and command line, read as root inside the container.
export function processes(target) {
  const script = `
    for d in /proc/[0-9]*; do
      pid="\${d#/proc/}"
      status="$(cat "$d/status" 2>/dev/null)" || continue
      stat="$(cat "$d/stat" 2>/dev/null)" || continue
      cmd="$(tr '\\0\\n|' '   ' < "$d/cmdline" 2>/dev/null)"
      uids="$(printf '%s\\n' "$status" | awk '/^Uid:/ {print $2","$3","$4","$5}')"
      state="$(printf '%s\\n' "$status" | awk '/^State:/ {print $2}')"
      eff="$(printf '%s\\n' "$status" | awk '/^CapEff:/ {print $2}')"
      prm="$(printf '%s\\n' "$status" | awk '/^CapPrm:/ {print $2}')"
      bnd="$(printf '%s\\n' "$status" | awk '/^CapBnd:/ {print $2}')"
      nnp="$(printf '%s\\n' "$status" | awk '/^NoNewPrivs:/ {print $2}')"
      sid="$(printf '%s\\n' "\${stat##*) }" | awk '{print $4}')"
      printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' "$pid" "$sid" "$uids" "$state" "$eff" "$prm" "$bnd" "$nnp" "$cmd"
    done`;
  const out = exec(target, script).stdout;
  return out
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [pid, sid, uids, state, capEff, capPrm, capBnd, nnp, cmdline] = line.split("|");
      return {
        pid: Number(pid),
        sid: Number(sid),
        uids: uids.split(",").map(Number),
        state,
        capEff,
        capPrm,
        capBnd,
        noNewPrivs: nnp === "1",
        cmdline: cmdline.trim(),
      };
    });
}

/**
 * Builds tests/fixtures/residue-canary.go for Linux on the host's
 * architecture, in a Go container pinned to the release apps/spawn/go.mod
 * names, and answers the directory holding `canary`.
 */
export function buildCanary() {
  const dir = mkdtempSync(path.join(tmpdir(), "cyfr-canary-"));
  // The read-only fixture mount must be traversable by pooled backend UIDs.
  chmodSync(dir, 0o755);
  run("docker", [
    "run", "--rm",
    "-v", `${path.join(ROOT_DIR, "tests", "fixtures")}:/src:ro`,
    "-v", `${dir}:/out`,
    "-e", "CGO_ENABLED=0", "-e", "GOCACHE=/tmp/go-cache", "-e", "GOFLAGS=-buildvcs=false",
    "-w", "/src",
    "golang:1.26.6-alpine", "go", "build", "-o", "/out/canary", "residue-canary.go",
  ]);
  return dir;
}

export function exec(target, script, { user } = {}) {
  return run("docker", ["exec", ...(user ? ["-u", user] : []), target, "sh", "-c", script], { allowFailure: true });
}

/**
 * One compose project running the mcp-bridge service. `start()` builds the
 * image when BRIDGE_IMAGE is unset, brings the service up and answers once
 * /health does; `stop()` removes every container, volume and network it
 * created.
 */
export class Stack {
  constructor(project, { overrides = [], env = {} } = {}) {
    this.project = project;
    this.overrides = overrides;
    this.extraEnv = env;
    this.root = randomBytes(32);
    this.keyHex = this.root.toString("hex");
    this.projectDir = null;
    this.env = null;
    this.container = null;
    this.base = null;
  }

  compose(...args) {
    return run(
      "docker",
      [
        "compose",
        "--project-name",
        this.project,
        "--project-directory",
        this.projectDir,
        "-f",
        path.join(ROOT_DIR, "docker-compose.yml"),
        "-f",
        path.join(HERE, "compose.isolation.yml"),
        ...this.overrides.flatMap((file) => ["-f", path.join(HERE, file)]),
        ...args,
      ],
      { env: this.env, allowFailure: args[0] === "run" },
    );
  }

  async start() {
    if (!process.env.BRIDGE_IMAGE) {
      run("docker", ["build", "-f", path.join(ROOT_DIR, "Dockerfile.node"), "--target", "mcp-bridge", "-t", IMAGE, ROOT_DIR]);
    }
    // A project directory of its own, with the empty .env the rest of the
    // stack's definition names.
    this.projectDir = mkdtempSync(path.join(tmpdir(), `${this.project}-`));
    writeFileSync(path.join(this.projectDir, ".env"), "");
    this.env = {
      ...process.env,
      BRIDGE_IMAGE: IMAGE,
      PROBE_DIR: path.join(ROOT_DIR, "apps", "mcp-bridge", "test", "fixtures"),
      CYFR_MCP_BRIDGE_KEY: this.keyHex,
      ...this.extraEnv,
    };

    this.compose("down", "--volumes", "--remove-orphans");
    this.compose("up", "--detach", "--no-build", "mcp-bridge");
    this.container = this.compose("ps", "--quiet", "mcp-bridge").stdout.trim();
    assert.ok(this.container, "compose started no mcp-bridge container");
    await this.published();
  }

  // Reads the published port (which a container restart may change) and waits for /health.
  async published() {
    this.base = `http://${this.compose("port", "mcp-bridge", "8001").stdout.trim()}`;
    await healthy(this.base);
    return this.base;
  }

  controller(options = {}) {
    return new Controller({ base: this.base, root: this.root, ...options });
  }

  stop() {
    if (!this.projectDir) return;
    if (process.env.CI) process.stdout.write(this.compose("logs", "--no-color", "mcp-bridge").stdout);
    this.compose("down", "--volumes", "--remove-orphans");
    rmSync(this.projectDir, { recursive: true, force: true });
    this.projectDir = null;
  }
}
