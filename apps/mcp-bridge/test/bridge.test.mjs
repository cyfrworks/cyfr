// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Test framing, response correlation, and child-process lifecycle.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(DIR, "..", "server.mjs");
const CHILD = path.join(DIR, "fake-child.mjs");
const TOKEN = "test-token";

let proc;
let base;

const rpc = async (method, params) => {
  const res = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${TOKEN}`,
      "mcp-protocol-version": "2026-07-28",
      "mcp-method": method,
      ...(params?.name ? { "mcp-name": params.name } : {}),
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: Math.floor(Math.random() * 1e6),
      method,
      params: {
        ...params,
        _meta: {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
    }),
  });

  return { status: res.status, body: await res.json().catch(() => null) };
};

const addBackend = (name, mode) =>
  rpc("tools/call", {
    name: "add_backend",
    arguments: { name, command: `node ${CHILD} ${mode}` },
  });

before(async () => {
  const port = 18000 + Math.floor(Math.random() * 1000);

  proc = spawn("node", [SERVER], {
    env: {
      ...process.env,
      MCP_BRIDGE_TOKEN: TOKEN,
      MCP_BRIDGE_PORT: String(port),
      MCP_BRIDGE_DATA: path.join(DIR, `backends.${port}.json`),
      // Generous: a loaded CI runner spawning node children took the old
      // 4s budget to the wire and the suite flaked on timing alone.
      MCP_BRIDGE_INIT_TIMEOUT_MS: "15000",
      MCP_BRIDGE_RPC_TIMEOUT_MS: "15000",
      // Planted app secrets: what the compose stack's project .env carries.
      // A child must never see them.
      CYFR_CRYPTO_KEYRING: "planted-keyring",
      CYFR_DATABASE_URL: "planted-dsn",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  base = `http://127.0.0.1:${port}`;

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("bridge did not start")), 10_000);
    // The boot line is `[mcp-bridge] /mcp on :<port>`, on stdout.
    proc.stdout.on("data", (c) => {
      if (String(c).includes("/mcp on")) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.on("exit", (code) => reject(new Error(`bridge exited early: ${code}`)));
  });
});

after(async () => {
  if (proc && proc.exitCode === null) proc.kill("SIGKILL");
  await fs_rm(path.join(DIR));
});

async function fs_rm(dir) {
  const { readdir, rm } = await import("node:fs/promises");
  for (const f of await readdir(dir)) {
    if (f.startsWith("backends.")) await rm(path.join(dir, f), { force: true });
  }
}

test("a child's own request does not resolve the bridge's pending call", async () => {
  // The child emits `{"id":1,"method":"roots/list"}` before answering
  // `initialize` — which the bridge also sent as id 1. Matching on id
  // alone resolved the handshake with `undefined`, leaving a backend
  // marked ready with no tools and every later id off by one.
  const { body } = await addBackend("rogue", "rogue-request");
  const payload = JSON.parse(body.result.content[0].text);

  assert.equal(payload.status, "ready", `handshake did not complete: ${JSON.stringify(payload)}`);
  assert.equal(payload.tool_count, 1, "the child's tools/list answer was lost to id confusion");
});

test("a call to a child that has died is refused, and the bridge keeps serving", async () => {
  // Scope, honestly: this covers the child-died-between-handshake-and-call
  // path end to end — the call is refused rather than dropped, and the
  // process survives to serve the other backends.
  //
  // It does NOT reproduce the asynchronous EPIPE that motivated the stream
  // 'error' listeners in `spawnBackend`: whether a write to a closing pipe
  // throws synchronously (caught by `writeFrame`) or emits 'error' a turn
  // later depends on how far teardown has progressed, and forcing the
  // second is not something this harness can do deterministically. The
  // listeners are the guard for it — an unhandled stream 'error' becomes
  // an uncaughtException, and this file answers that with process.exit(1).
  // The child exits 20ms after its handshake, so whether add_backend reads
  // "ready" or already "crashed" is a race the test does not care about —
  // only that the handshake happened and the bridge is still standing.
  const { body } = await addBackend("dying", "die-after-handshake");
  const added = JSON.parse(body.result.content[0].text);
  assert.ok(["ready", "crashed"].includes(added.status), `unexpected status ${added.status}`);

  await new Promise((r) => setTimeout(r, 200));
  const call = await rpc("tools/call", { name: "dying__ping", arguments: {} });

  assert.equal(call.status, 200, "the call should be refused, not dropped");
  assert.equal(proc.exitCode, null, "the bridge died when one child went away");

  const list = await rpc("tools/list", {});
  assert.equal(list.status, 200, "the bridge stopped serving after a child died");
});

test("a string-typed response id still matches its pending call", async () => {
  const { body } = await addBackend("stringy", "well-behaved");
  assert.equal(JSON.parse(body.result.content[0].text).status, "ready");

  const call = await rpc("tools/call", { name: "stringy__ping", arguments: {} });

  assert.equal(call.status, 200);
  assert.ok(
    JSON.stringify(call.body).includes("pong"),
    `a "1" echoed for 1 was dropped and the call hung: ${JSON.stringify(call.body)}`,
  );
});

test("a child inherits a toolchain path and its own env block, never the bridge's secrets", async () => {
  // The bridge runs beside cyfr and, pointed at the project .env, held the
  // app's keyring, key base and database URL. Passing its whole
  // environment to `sh -c <command>` handed those to every backend a
  // member registered.
  const { body } = await rpc("tools/call", {
    name: "add_backend",
    arguments: { name: "envprobe", command: `node ${CHILD} env-probe`, env: { PROBE_OWN: "mine" } },
  });
  assert.equal(JSON.parse(body.result.content[0].text).status, "ready");

  const call = await rpc("tools/call", { name: "envprobe__ping", arguments: {} });
  assert.equal(call.status, 200);
  const seen = JSON.parse(call.body.result.content[0].text);

  assert.equal(seen.keyring, null, "CYFR_CRYPTO_KEYRING reached a child");
  assert.equal(seen.dsn, null, "CYFR_DATABASE_URL reached a child");
  assert.equal(seen.token, null, "MCP_BRIDGE_TOKEN reached a child");
  assert.deepEqual(seen.cyfr, [], `application variables reached a child: ${seen.cyfr}`);
  assert.equal(seen.own, "mine", "the backend's own env block was dropped");
  assert.ok(seen.path, "PATH was dropped; npx cannot run without it");
});

test("an explicit null id is a request, not a notification", async () => {
  const res = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${TOKEN}`,
      "mcp-protocol-version": "2026-07-28",
      "mcp-method": "tools/list",
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: null, method: "tools/list", params: {} }),
  });

  assert.notEqual(res.status, 202, "an id:null request was answered as a notification and hung");
});
