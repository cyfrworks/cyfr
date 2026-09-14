// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Test framing, response correlation, and the backend lifecycle through the
// spawner: spawn, exit, restart and release.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { lstat, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createBridge } from "../server.mjs";
import { FakeSpawner } from "./fake-spawner.mjs";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(DIR, "..", "server.mjs");
const CHILD = path.join(DIR, "fake-child.mjs");
const TOKEN = "test-token";

let dataDir;
let spawner;
let bridge;
let base;

// Generous: a loaded CI runner spawning node children can take seconds.
const TIMEOUTS = { initTimeoutMs: 15_000, rpcTimeoutMs: 15_000 };

async function startBridge(options) {
  const instance = createBridge({ token: TOKEN, ...TIMEOUTS, ...options });
  const server = await new Promise((resolve) => {
    const s = instance.app.listen(0, "127.0.0.1", () => resolve(s));
  });
  return { instance, server, base: `http://127.0.0.1:${server.address().port}` };
}

async function stopBridge({ instance, server }) {
  await instance.close();
  await new Promise((resolve) => server.close(() => resolve()));
}

const rpcAt = async (url, method, params) => {
  const res = await fetch(`${url}/mcp`, {
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

const rpc = (method, params) => rpcAt(base, method, params);

const callTool = async (name, args = {}, url = base) => {
  const { body } = await rpcAt(url, "tools/call", { name, arguments: args });
  return body.result;
};

const addBackend = (name, mode, env) =>
  callTool("add_backend", { name, command: `node ${CHILD} ${mode}`, ...(env ? { env } : {}) });

const payload = (result) => JSON.parse(result.content[0].text);

const listed = async (url = base) => payload(await callTool("list_backends", {}, url)).backends;

const toolNames = async () => (await rpc("tools/list", {})).body.result.tools.map((t) => t.name);

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

before(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), "bridge-test-"));
  spawner = new FakeSpawner();
  const started = await startBridge({ spawner, persistPath: path.join(dataDir, "backends.json") });
  bridge = started;
  base = started.base;
});

after(async () => {
  await stopBridge(bridge);
  await rm(dataDir, { recursive: true, force: true });
});

test("a child's own request does not resolve the bridge's pending call", async () => {
  // The child emits `{"id":1,"method":"roots/list"}` before answering
  // `initialize` — which the bridge also sent as id 1. Matching on id
  // alone resolved the handshake with `undefined`, leaving a backend
  // marked ready with no tools and every later id off by one.
  const added = payload(await addBackend("rogue", "rogue-request"));

  assert.equal(added.status, "ready", `handshake did not complete: ${JSON.stringify(added)}`);
  assert.equal(added.tool_count, 1, "the child's tools/list answer was lost to id confusion");
});

test("a call to a child that has died is refused, and the bridge keeps serving", async () => {
  // The child exits 20ms after its handshake, so whether add_backend reads
  // "ready" or already "crashed" is a race the test does not care about —
  // only that the handshake happened and the bridge is still standing.
  const added = payload(await addBackend("dying", "die-after-handshake"));
  assert.ok(["ready", "crashed"].includes(added.status), `unexpected status ${added.status}`);

  await new Promise((r) => setTimeout(r, 200));
  const call = await rpc("tools/call", { name: "dying__ping", arguments: {} });

  assert.equal(call.status, 200, "the call should be refused, not dropped");
  assert.equal(call.body.result.isError, true);

  const list = await rpc("tools/list", {});
  assert.equal(list.status, 200, "the bridge stopped serving after a child died");
});

test("a string-typed response id still matches its pending call", async () => {
  assert.equal(payload(await addBackend("stringy", "well-behaved")).status, "ready");

  const call = await rpc("tools/call", { name: "stringy__ping", arguments: {} });

  assert.equal(call.status, 200);
  assert.ok(
    JSON.stringify(call.body).includes("pong"),
    `a "1" echoed for 1 was dropped and the call hung: ${JSON.stringify(call.body)}`,
  );
});

test("a backend is spawned as `/bin/sh -c <command>` with its own env block and nothing else", async () => {
  const added = payload(await addBackend("envprobe", "env-probe", { PROBE_OWN: "mine" }));
  assert.equal(added.status, "ready");

  const request = spawner.spawns.at(-1);
  assert.deepEqual(request.argv, ["/bin/sh", "-c", `node ${CHILD} env-probe`]);
  assert.deepEqual(request.env, { PROBE_OWN: "mine" }, "the spawn request carried more than the backend's env block");

  const seen = JSON.parse((await callTool("envprobe__ping")).content[0].text);
  assert.equal(seen.own, "mine", "the backend's own env block was dropped");
});

test("removing a backend releases its spawn, ends its process and withdraws its tools", async () => {
  assert.equal(payload(await addBackend("gone", "well-behaved")).status, "ready");
  const { proc } = spawner.spawns.at(-1);
  assert.ok((await toolNames()).includes("gone__ping"));

  assert.deepEqual(payload(await callTool("remove_backend", { name: "gone" })), { removed: "gone" });

  assert.equal(proc.released, true, "remove_backend answered before the spawn was released");
  assert.equal(alive(proc.pid), false, "the backend's process outlived its removal");
  assert.ok(!(await toolNames()).includes("gone__ping"));
  assert.ok(!(await listed()).some((b) => b.name === "gone"));
});

test("a crashed backend is reported, and restarting it releases the old spawn before the new one", async () => {
  assert.equal(payload(await addBackend("flaky", "die-on-call")).status, "ready");
  const first = spawner.spawns.length;
  const oldProc = spawner.spawns.at(-1).proc;

  const call = await callTool("flaky__ping");
  assert.equal(call.isError, true, "a call to a crashing backend was not refused");
  await new Promise((r) => setTimeout(r, 100));
  const crashed = (await listed()).find((b) => b.name === "flaky");
  assert.equal(crashed.status, "crashed");
  assert.match(crashed.error, /exited code=3/);
  assert.equal(oldProc.released, true, "the crashed backend's spawn was not retired");

  const restarted = payload(await callTool("restart_backend", { name: "flaky" }));
  assert.equal(restarted.status, "ready");
  assert.equal(spawner.spawns.length, first + 1);
  const events = spawner.events;
  assert.ok(
    events.indexOf(`released:${first}`) < events.indexOf(`spawn:${first + 1}`),
    `the new spawn started before the old one was released: ${events.join(" ")}`,
  );
});

test("restarting a running backend waits for its release before spawning again", async () => {
  assert.equal(payload(await addBackend("again", "well-behaved")).status, "ready");
  const n = spawner.spawns.length;
  const oldPid = spawner.spawns.at(-1).proc.pid;

  assert.equal(payload(await callTool("restart_backend", { name: "again" })).status, "ready");

  const events = spawner.events;
  assert.ok(events.indexOf(`release:${n}`) < events.indexOf(`released:${n}`));
  assert.ok(events.indexOf(`released:${n}`) < events.indexOf(`spawn:${n + 1}`), events.join(" "));
  assert.equal(alive(oldPid), false);
  assert.ok(JSON.stringify(await callTool("again__ping")).includes("pong"));
});

test("a spawn the spawner refuses fails add_backend and leaves nothing behind", async () => {
  spawner.capacity = spawner.live();
  try {
    const result = await addBackend("overflow", "well-behaved");
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /backend 'overflow' failed to start: spawn refused: capacity/);
    assert.ok(!(await listed()).some((b) => b.name === "overflow"));
  } finally {
    spawner.capacity = Infinity;
  }
});

test("persisted backends are revived through the spawner, and close releases them all", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "bridge-revive-"));
  const persistPath = path.join(dir, "backends.json");
  await writeFile(
    persistPath,
    JSON.stringify({
      backends: [
        { name: "one", command: `node ${CHILD} well-behaved` },
        { name: "two", command: `node ${CHILD} well-behaved`, env: { KEY: "v" } },
        { name: "bad__name", command: `node ${CHILD} well-behaved` },
      ],
    }),
  );
  const own = new FakeSpawner();
  const revived = await startBridge({ spawner: own, persistPath });
  try {
    await revived.instance.revive();
    assert.deepEqual(
      own.spawns.map((s) => s.env),
      [{}, { KEY: "v" }],
      "a routing-ambiguous name was spawned, or an env block was altered",
    );

    for (let i = 0; i < 100; i++) {
      const statuses = (await listed(revived.base)).map((b) => b.status);
      if (statuses.every((s) => s === "ready")) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    assert.deepEqual((await listed(revived.base)).map((b) => b.status), ["ready", "ready"]);
  } finally {
    await stopBridge(revived);
    await rm(dir, { recursive: true, force: true });
  }
  assert.ok(own.spawns.every(({ proc }) => proc.released), "close left a spawn unreleased");
  assert.ok(own.spawns.every(({ proc }) => !alive(proc.pid)), "close left a backend process running");
});

test("persistence neither follows a planted symlink nor revives one", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "bridge-persist-"));
  const persistPath = path.join(dir, "backends.json");
  const decoy = path.join(dir, "decoy.json");
  await writeFile(decoy, JSON.stringify({ backends: [{ name: "planted", command: `node ${CHILD} well-behaved` }] }));
  await symlink(decoy, persistPath);
  const leak = path.join(dir, "leak");
  await writeFile(leak, "");
  await symlink(leak, `${persistPath}.tmp`);

  const own = new FakeSpawner();
  const started = await startBridge({ spawner: own, persistPath });
  try {
    await started.instance.revive();
    assert.equal(own.spawns.length, 0, "a symlinked persistence file was revived");

    const added = await callTool("add_backend", { name: "kept", command: `node ${CHILD} well-behaved`, env: { KEY: "secret" } }, started.base);
    assert.equal(payload(added).status, "ready");
    assert.equal(await readFile(leak, "utf8"), "", "persist wrote through a planted symlink");
    const saved = JSON.parse(await readFile(persistPath, "utf8"));
    assert.deepEqual(saved.backends.map((b) => b.name), ["kept"]);
    assert.equal((await lstat(persistPath)).isSymbolicLink(), false);
  } finally {
    await stopBridge(started);
    await rm(dir, { recursive: true, force: true });
  }
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

test("/mcp refuses a missing or wrong bearer and /health answers open", async () => {
  const health = await fetch(`${base}/health`);
  assert.equal(health.status, 200);

  for (const authorization of [undefined, "Bearer wrong"]) {
    const res = await fetch(`${base}/mcp`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(authorization ? { authorization } : {}),
        "mcp-protocol-version": "2026-07-28",
        "mcp-method": "tools/list",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
    });
    assert.equal(res.status, 401);
  }
});

function runServer(stdio, env) {
  return new Promise((resolve) => {
    const proc = spawn(process.execPath, [SERVER], {
      stdio,
      env: { PATH: process.env.PATH, MCP_BRIDGE_PORT: "0", ...env },
    });
    let stderr = "";
    proc.stderr.on("data", (c) => (stderr += c));
    const timer = setTimeout(() => proc.kill("SIGKILL"), 10_000);
    proc.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code, stderr });
    });
  });
}

test("server.mjs refuses to start unless fd 3 is the spawner's socket", async () => {
  const { code, stderr } = await runServer(["ignore", "ignore", "pipe"], { MCP_BRIDGE_TOKEN: TOKEN });
  assert.equal(code, 1);
  assert.match(stderr, /fd 3 is not the spawner channel/);
});

test("server.mjs refuses to start without a token even with the spawner's socket", async () => {
  // A 'pipe' at index 3 is a socketpair end in the child.
  const { code, stderr } = await runServer(["ignore", "ignore", "pipe", "pipe"], { MCP_BRIDGE_TOKEN: "" });
  assert.equal(code, 1);
  assert.match(stderr, /MCP_BRIDGE_TOKEN is unset/);
});
