// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The bridge over HTTP with an in-process fake spawner: /control and /mcp
// accept only requests signed for this lifetime, in order and within the
// window, and refuse an unauthenticated one before reading its body; an
// owner runs exactly the backends its sync defined, at exactly its
// version, while its lease lives; each owner sees only its own backends; what
// leaves the bridge is masked; and stdio framing, crashes and release behave
// through the spawner.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as auth from "../auth.mjs";
import { CONTROL_BODY_LIMIT, MCP_BODY_LIMIT, createBridge } from "../server.mjs";
import { Controller } from "../../../tests/bridge-image/controller.mjs";
import { FakeSpawner } from "./fake-spawner.mjs";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const SERVER = path.join(DIR, "..", "server.mjs");
const CHILD = path.join(DIR, "fake-child.mjs");
const ROOT = randomBytes(32);

// Generous: a loaded CI runner spawning node children can take seconds.
const TIMEOUTS = { initTimeoutMs: 15_000, rpcTimeoutMs: 15_000 };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function eventually(check, what, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(25);
  }
}

async function startBridge(options = {}) {
  const spawner = options.spawner || new FakeSpawner();
  const instance = createBridge({ root: ROOT, ...TIMEOUTS, ...options, spawner });
  const server = await new Promise((resolve) => {
    const s = instance.app.listen(0, "127.0.0.1", () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  const controller = new Controller({ base, root: ROOT });
  assert.equal((await controller.hello()).status, 200);
  return { instance, server, base, spawner, controller };
}

async function stopBridge({ instance, server }) {
  await instance.close();
  await new Promise((resolve) => server.close(() => resolve()));
}

let n = 0;
const newOwner = (e = 1) => ({ athanor: `ath_${++n}`, server: `mcp_${n}`, e });
const backend = (mode, env = {}, name = "b") => ({ name, command: `node ${CHILD} ${mode}`, env });

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

let shared;
let c;

before(async () => {
  shared = await startBridge();
  c = shared.controller;
});

after(async () => {
  await stopBridge(shared);
});

async function synced(owner, backends, options) {
  const answer = await c.sync({ ...owner, backends }, options);
  assert.equal(answer.status, 200, JSON.stringify(answer.body));
  return answer.body;
}

// ============================================================================
// Authentication and ordering
// ============================================================================

test("/health answers without authentication, and every response names this lifetime", async () => {
  const res = await fetch(`${shared.base}/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
  assert.match(res.headers.get("cyfr-bridge-boot"), /^bb_[0-9a-f]{32}$/);
  assert.equal(res.headers.get("cyfr-bridge-boot"), shared.instance.boot);
  assert.equal(c.boot, shared.instance.boot);
});

test("hello answers the lifetime and the pool", async () => {
  const answer = await c.hello();
  assert.equal(answer.status, 200);
  assert.deepEqual(answer.body.pool, { size: 32, free: 32 - shared.spawner.live() });
  assert.equal(answer.boot, answer.body.boot);

  const mismatch = await c.control({ type: "hello", g: 2, cyfr_boot: c.cyfrBoot });
  assert.deepEqual([mismatch.status, mismatch.body], [400, { error: "bad_request" }]);
});

test("a control message that is unsigned, forged or outside the window is refused and moves nothing", async () => {
  const unsigned = await fetch(`${shared.base}/control`, { method: "POST", body: JSON.stringify({ type: "hello" }) });
  assert.equal(unsigned.status, 401);
  assert.deepEqual(await unsigned.json(), { error: "unauthorized" });

  const forged = await c.hello({ key: randomBytes(32), seq: 1_000_000 });
  assert.deepEqual([forged.status, forged.body], [401, { error: "unauthorized" }]);

  const late = await c.hello({ ts: Date.now() - 31_000, seq: 1_000_001 });
  assert.deepEqual([late.status, late.body], [401, { error: "unauthorized" }]);
  const early = await c.hello({ ts: Date.now() + 31_000, seq: 1_000_002 });
  assert.equal(early.status, 401);

  // None of the refused sequence numbers raised the high-water mark.
  assert.equal((await c.hello()).status, 200);
});

test("a control message must name this lifetime, and hello must name none", async () => {
  const hello = await c.hello({ boot: shared.instance.boot });
  assert.deepEqual([hello.status, hello.body], [409, { error: "stale_boot" }]);

  for (const boot of ["-", "bb_00000000000000000000000000000000"]) {
    const renew = await c.renew([], 30_000, { boot });
    assert.deepEqual([renew.status, renew.body], [409, { error: "stale_boot" }]);
  }
});

test("a control message at or below the high-water mark is refused", async () => {
  const { instance, server, controller } = await startBridge();
  try {
    assert.equal((await controller.renew([], 30_000, { seq: 10 })).status, 200);
    for (const seq of [10, 9]) {
      const again = await controller.renew([], 30_000, { seq });
      assert.deepEqual([again.status, again.body], [409, { error: "stale_control" }]);
    }
    const olderGeneration = await controller.renew([], 30_000, { generation: 0, seq: 99 });
    assert.deepEqual([olderGeneration.status, olderGeneration.body], [409, { error: "stale_control" }]);

    // A higher generation starts its own sequence.
    assert.equal((await controller.renew([], 30_000, { generation: 2, seq: 1 })).status, 200);
    const previousGeneration = await controller.renew([], 30_000, { generation: 1, seq: 11 });
    assert.equal(previousGeneration.status, 409);
  } finally {
    await stopBridge({ instance, server });
  }
});

test("a control message with an unknown type or invalid fields is refused as a bad request", async () => {
  const owner = newOwner();
  const cases = [
    { type: "launch" },
    { type: "renew", owners: [{ athanor: "a b", server: "s", e: 1 }], lease_ms: 1000 },
    { type: "renew", owners: [], lease_ms: 60_001 },
    { type: "release", owners: [{ athanor: "a", server: "s", e: 0 }] },
    { type: "reconcile", keep: "all" },
  ];
  for (const message of cases) {
    const answer = await c.control(message);
    assert.deepEqual([answer.status, answer.body], [400, { error: "bad_request" }], JSON.stringify(message));
  }

  const badBackends = [
    [{ name: "Bad", command: "node x", env: {} }],
    [{ name: "b", command: "node x --token vault:gh", env: {} }],
    [{ name: "b", command: "", env: {} }],
    [{ name: "b", command: "node x", env: { PATH: "/tmp" } }],
    [{ name: "b", command: "node x", env: { CYFR_SECRET: "x" } }],
    [{ name: "b", command: "node x", env: { MCP_BRIDGE_PORT: "1" } }],
    [{ name: "b", command: "node x", env: { lower: "x" } }],
    [backend("well-behaved"), backend("well-behaved")],
    [],
  ];
  const before = shared.spawner.spawns.length;
  for (const backends of badBackends) {
    const answer = await c.sync({ ...owner, backends });
    assert.deepEqual([answer.status, answer.body], [400, { error: "bad_request" }], JSON.stringify(backends));
  }

  // An environment sealed for another lifetime, another epoch or another owner does not open.
  const env = Buffer.from(JSON.stringify({ b: {} }));
  const target = { athanor: owner.athanor, server: owner.server, generation: 1, epoch: 1 };
  for (const [sealedOwner, boot] of [
    [target, "bb_00000000000000000000000000000000"],
    [{ ...target, epoch: 2 }, c.boot],
    [{ ...target, server: "mcp_other" }, c.boot],
  ]) {
    const sealed = auth.seal(auth.sealKey(ROOT), sealedOwner, boot, env, randomBytes(12));
    const answer = await c.sync({ ...owner, backends: [backend("well-behaved")], sealed });
    assert.deepEqual([answer.status, answer.body], [400, { error: "bad_request" }]);
  }
  assert.equal(shared.spawner.spawns.length, before, "a refused sync spawned something");
});

test("a sync's environment must name exactly its backends and their variables", async () => {
  const owner = newOwner();
  const definitions = { type: "sync", owner: { athanor: owner.athanor, server: owner.server }, e: 1, lease_ms: 30_000 };
  const seal = (env) =>
    auth.seal(
      auth.sealKey(ROOT),
      { athanor: owner.athanor, server: owner.server, generation: 1, epoch: 1 },
      c.boot,
      Buffer.from(JSON.stringify(env)),
      randomBytes(12),
    );
  const backends = [{ name: "b", command: `node ${CHILD} well-behaved`, env_names: ["KEY"] }];
  for (const env of [{}, { b: {} }, { b: { KEY: "v", OTHER: "w" } }, { b: { KEY: 1 } }, { b: { KEY: "v" }, c: {} }]) {
    const answer = await c.control({ ...definitions, backends, sealed: seal(env) });
    assert.deepEqual([answer.status, answer.body], [400, { error: "bad_request" }], JSON.stringify(env));
  }
  const good = await c.control({ ...definitions, backends, sealed: seal({ b: { KEY: "v" } }) });
  assert.equal(good.status, 200, JSON.stringify(good.body));
  await c.release([owner]);
});

// ============================================================================
// Reading bodies
// ============================================================================

// Sends a request head declaring `declared` bytes of body and `sent` of them,
// and answers the status line of the response and whether it came before
// the rest of the body was sent.
function partialPost(base, endpoint, headers, declared, sent) {
  const { hostname, port } = new URL(base);
  return new Promise((resolve, reject) => {
    const socket = net.connect(Number(port), hostname);
    let response = "";
    socket.setEncoding("latin1");
    socket.on("data", (chunk) => {
      response += chunk;
      const line = response.split("\r\n")[0];
      if (response.includes("\r\n\r\n")) {
        socket.destroy();
        resolve({ status: Number(line.split(" ")[1]), head: response.split("\r\n\r\n")[0].toLowerCase() });
      }
    });
    socket.on("error", reject);
    socket.on("connect", () => {
      const head = [`POST /${endpoint} HTTP/1.1`, `host: ${hostname}`, `content-length: ${declared}`, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`)];
      socket.write(`${head.join("\r\n")}\r\n\r\n`);
      socket.write(Buffer.alloc(sent, 0x7b));
    });
    setTimeout(() => {
      socket.destroy();
      reject(new Error(`no answer from /${endpoint} before the body was sent`));
    }, 5_000).unref();
  });
}

test("a request whose header does not authenticate is refused before any of its body is read", async () => {
  const declared = 28 * 1024 * 1024;
  const forgedControl = auth.controlHeader(randomBytes(32), { generation: 1, seq: 1, cyfr_boot: c.cyfrBoot, boot: c.boot, ts: Date.now() }, "{}");
  const forgedInvoke = auth.invokeHeader(randomBytes(32), { athanor: "ath_x", server: "mcp_x", generation: 1, epoch: 1, boot: c.boot, ts: Date.now(), nonce: "n_1" }, "{}");
  for (const [endpoint, headers] of [
    ["control", {}],
    ["control", { "cyfr-bridge-auth": forgedControl }],
    ["mcp", { "cyfr-bridge-auth": forgedInvoke }],
  ]) {
    const answer = await partialPost(shared.base, endpoint, headers, declared, 1024);
    assert.equal(answer.status, 401, endpoint);
    assert.match(answer.head, /connection: close/);
  }

  // An authenticated invoke for an owner the bridge does not run is refused unread as well.
  const invoke = c.signInvoke(newOwner(), "tools/list");
  const unknown = await partialPost(shared.base, "mcp", { "cyfr-bridge-auth": invoke.headers["cyfr-bridge-auth"] }, declared, 1024);
  assert.equal(unknown.status, 409);
});

test("a body past its endpoint's limit is refused, and one that is not the body the header signed is unauthorized", async () => {
  const owner = newOwner();
  await synced(owner, [backend("well-behaved")]);

  const fields = { generation: 1, seq: ++c.seq, cyfr_boot: c.cyfrBoot, boot: c.boot, ts: Date.now() };
  const bigControl = await partialPost(shared.base, "control", { "cyfr-bridge-auth": auth.controlHeader(auth.controlKey(ROOT), fields, "{}") }, CONTROL_BODY_LIMIT + 1, 16);
  assert.equal(bigControl.status, 413);

  const invoke = c.signInvoke(owner, "tools/list");
  const bigInvoke = await partialPost(shared.base, "mcp", { "cyfr-bridge-auth": invoke.headers["cyfr-bridge-auth"] }, MCP_BODY_LIMIT + 1, 16);
  assert.equal(bigInvoke.status, 413);

  // The header verifies but the body is another: refused, and the nonce stays unused.
  const signed = c.signInvoke(owner, "tools/list");
  const tampered = await c.resend({ ...signed, body: signed.body.replace('"id":1', '"id":2') });
  assert.deepEqual([tampered.status, tampered.body?.error?.message], [401, "unauthorized"]);
  assert.equal((await c.resend(signed)).status, 200);

  const renew = JSON.stringify({ type: "renew", owners: [], lease_ms: 30_000 });
  const header = auth.controlHeader(auth.controlKey(ROOT), { ...fields, seq: ++c.seq, ts: Date.now() }, renew);
  const res = await fetch(`${shared.base}/control`, { method: "POST", headers: { "cyfr-bridge-auth": header }, body: renew.replace("30000", "30001") });
  assert.equal(res.status, 401);
  await c.release([owner]);
});

// ============================================================================
// Owners
// ============================================================================

test("a sync spawns each backend as `/bin/sh -c <command>` with its own env block and nothing else", async () => {
  const owner = newOwner();
  const body = await synced(owner, [backend("env-probe", { PROBE_OWN: "mine" })]);
  assert.deepEqual(body, { status: "running", backends: [{ name: "b", status: "ready", tools: 1 }] });

  const request = shared.spawner.spawns.at(-1);
  assert.deepEqual(request.argv, ["/bin/sh", "-c", `node ${CHILD} env-probe`]);
  assert.deepEqual(request.env, { PROBE_OWN: "mine" });

  const seen = await c.tool(owner, "b__ping");
  assert.equal(seen.own, "mine");
  assert.deepEqual(seen.cyfr, []);
  await c.release([owner]);
});

test("an owner sees only its own backends", async () => {
  const one = newOwner();
  const two = newOwner();
  await synced(one, [backend("well-behaved", {}, "alpha")]);
  await synced(two, [backend("well-behaved", {}, "beta"), backend("well-behaved", {}, "gamma")]);

  const names = async (owner) => (await c.invoke(owner, "tools/list")).body.result.tools.map((t) => t.name);
  assert.deepEqual(await names(one), ["alpha__ping"]);
  assert.deepEqual(await names(two), ["beta__ping", "gamma__ping"]);

  const across = await c.invoke(one, "tools/call", { name: "beta__ping", arguments: {} });
  assert.equal(across.body.result.isError, true);
  assert.match(across.body.result.content[0].text, /unknown tool/);
  await c.release([one, two]);
});

test("an MCP request is refused unless signed for this lifetime, the owner's version and a fresh nonce", async () => {
  const owner = newOwner(2);
  await synced(owner, [backend("well-behaved")]);

  const unsigned = await fetch(`${shared.base}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", "mcp-protocol-version": "2026-07-28", "mcp-method": "tools/list" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  assert.equal(unsigned.status, 401);
  assert.deepEqual(await unsigned.json(), { jsonrpc: "2.0", id: null, error: { code: -33001, message: "unauthorized" } });

  const refused = async (options, status, body, target = owner) => {
    const answer = await c.invoke(target, "tools/list", {}, options);
    assert.deepEqual([answer.status, answer.body], [status, body], JSON.stringify(options));
    return answer;
  };
  const unauthorized = { jsonrpc: "2.0", id: null, error: { code: -33001, message: "unauthorized" } };
  await refused({ key: randomBytes(32) }, 401, unauthorized);
  await refused({ ts: Date.now() - 31_000 }, 401, unauthorized);
  await refused({ boot: "bb_ffffffffffffffffffffffffffffffff" }, 409, { error: "stale_boot" });
  await refused({}, 409, { error: "unknown_owner" }, newOwner());
  await refused({}, 409, { error: "stale_epoch" }, { ...owner, e: 1 });
  await refused({ generation: 0 }, 409, { error: "stale_epoch" });
  await refused({}, 409, { error: "epoch_ahead" }, { ...owner, e: 3 });
  await refused({ generation: 2 }, 409, { error: "epoch_ahead" });

  const first = await c.invoke(owner, "tools/list");
  assert.equal(first.status, 200);
  const replay = await c.resend(first.request);
  assert.deepEqual([replay.status, replay.body], [409, { error: "replay" }]);

  // A refused request records no nonce.
  const forgedNonce = "n_forged";
  await refused({ key: randomBytes(32), nonce: forgedNonce }, 401, unauthorized);
  assert.equal((await c.invoke(owner, "tools/list", {}, { nonce: forgedNonce })).status, 200);
  await c.release([owner]);
});

test("an owner whose lease lapses is retired, answering lapsed and then unknown_owner", async () => {
  const { instance, server, controller, spawner } = await startBridge({ leaseCheckMs: 20 });
  try {
    const owner = newOwner();
    const answer = await controller.sync({ ...owner, leaseMs: 300, backends: [backend("well-behaved")] });
    assert.equal(answer.status, 200);
    const { proc } = spawner.spawns.at(-1);

    const lapsed = await eventually(async () => {
      const r = await controller.invoke(owner, "tools/list");
      return r.status === 409 ? r : null;
    }, "the lease to lapse");
    assert.ok(["lapsed", "unknown_owner"].includes(lapsed.body.error));
    await eventually(() => proc.released, "the lapsed owner's spawn to be released");
    await eventually(async () => (await controller.invoke(owner, "tools/list")).body.error === "unknown_owner", "the owner to be gone");

    const renew = await controller.renew([owner]);
    assert.deepEqual(renew.body, { renewed: [], unknown: [owner] });
  } finally {
    await stopBridge({ instance, server });
  }
});

test("a sync whose backend is still starting answers within half its lease, and the owner lives on renewal", async () => {
  const { instance, server, controller } = await startBridge({ leaseCheckMs: 20 });
  try {
    const owner = newOwner();
    const started = Date.now();
    const answer = await controller.sync({ ...owner, leaseMs: 1_000, backends: [backend("never-ready")] });
    assert.equal(answer.status, 200, JSON.stringify(answer.body));
    assert.ok(Date.now() - started < 1_000, "the sync waited past its lease");
    assert.deepEqual(answer.body, { status: "running", backends: [{ name: "b", status: "initializing", tools: 0 }] });

    for (let i = 0; i < 4; i++) {
      await sleep(400);
      assert.deepEqual((await controller.renew([owner], 1_000)).body, { renewed: [owner], unknown: [] });
    }
    const listed = await controller.invoke(owner, "tools/list");
    assert.deepEqual([listed.status, listed.body.result.tools], [200, []]);
    await controller.release([owner]);
  } finally {
    await stopBridge({ instance, server });
  }
});

test("renew extends exactly the owners running at the version named", async () => {
  const owner = newOwner(4);
  await synced(owner, [backend("well-behaved")]);
  const other = newOwner();

  const answer = await c.renew([owner, { ...owner, e: 3 }, other], 45_000);
  assert.deepEqual(answer.body, { renewed: [owner], unknown: [{ ...owner, e: 3 }, other] });
  const [status] = (await c.status([owner])).body.owners;
  assert.ok(status.lease_ms_left > 30_000 && status.lease_ms_left <= 45_000);
  await c.release([owner]);
});

test("a sync at the same version extends the lease only; another definition at it conflicts; a lower one is stale", async () => {
  const owner = newOwner(5);
  const definition = [backend("well-behaved")];
  await synced(owner, definition);
  const spawned = shared.spawner.spawns.length;

  const again = await synced(owner, definition);
  assert.deepEqual(again, { status: "running", backends: [{ name: "b", status: "ready", tools: 1 }] });
  assert.equal(shared.spawner.spawns.length, spawned, "a same-version sync spawned again");

  const different = await c.sync({ ...owner, backends: [backend("rogue-request")] });
  assert.deepEqual([different.status, different.body], [409, { error: "conflict" }]);

  const lower = await c.sync({ ...owner, e: 4, backends: definition });
  assert.deepEqual([lower.status, lower.body], [409, { error: "stale_epoch" }]);
  await c.release([owner]);
});

test("a sync at a higher version retires the old spawns before it starts the new ones", async () => {
  const owner = newOwner(1);
  await synced(owner, [backend("well-behaved")]);
  const index = shared.spawner.spawns.length;
  const old = shared.spawner.spawns.at(-1).proc;

  await synced({ ...owner, e: 2 }, [backend("well-behaved", {}, "renamed")]);
  const events = shared.spawner.events;
  assert.ok(events.indexOf(`released:${index}`) < events.indexOf(`spawn:${index + 1}`), events.join(" "));
  assert.equal(alive(old.pid), false);

  assert.equal((await c.invoke(owner, "tools/list")).body.error, "stale_epoch");
  const listed = await c.invoke({ ...owner, e: 2 }, "tools/list");
  assert.deepEqual(listed.body.result.tools.map((t) => t.name), ["renamed__ping"]);
  await c.release([{ ...owner, e: 2 }]);
});

test("a sync the pool cannot hold spawns nothing, and one the spawner refuses part-way leaves nothing", async () => {
  const { instance, server, controller, spawner } = await startBridge({ spawner: new FakeSpawner({ capacity: 1 }) });
  try {
    const full = await controller.sync({ ...newOwner(), backends: [backend("well-behaved", {}, "a"), backend("well-behaved", {}, "b")] });
    assert.deepEqual([full.status, full.body], [409, { error: "capacity" }]);
    assert.equal(spawner.spawns.length, 0);

    // The pool reports room the spawner then does not have.
    spawner.pool = async () => ({ size: 4, free: 4, quarantined: 0 });
    const owner = newOwner();
    const partial = await controller.sync({ ...owner, backends: [backend("well-behaved", {}, "a"), backend("well-behaved", {}, "b")] });
    assert.deepEqual([partial.status, partial.body], [409, { error: "capacity" }]);
    await eventually(() => spawner.live() === 0, "the spawn that started to be released");
    assert.equal((await controller.invoke(owner, "tools/list")).body.error, "unknown_owner");
    assert.deepEqual((await controller.status([owner])).body, { owners: [] });
  } finally {
    await stopBridge({ instance, server });
  }
});

test("release retires an owner at or below the version named; reconcile retires every owner not kept", async () => {
  const one = newOwner(3);
  const two = newOwner(1);
  const three = newOwner(1);
  await synced(one, [backend("well-behaved")]);
  const oneProc = shared.spawner.spawns.at(-1).proc;
  await synced(two, [backend("well-behaved")]);
  await synced(three, [backend("well-behaved")]);

  assert.deepEqual((await c.release([{ ...one, e: 2 }])).body, { released: [] });
  assert.deepEqual((await c.release([one])).body, { released: [{ athanor: one.athanor, server: one.server, g: 1, e: 3 }] });
  assert.equal((await c.invoke(one, "tools/list")).body.error, "unknown_owner");
  await eventually(() => oneProc.released && !alive(oneProc.pid), "the released owner's process to end");

  const reconciled = await c.reconcile([{ ...two }, { ...three, e: 2 }]);
  assert.deepEqual(
    reconciled.body.released.map((r) => r.athanor),
    [three.athanor],
    "reconcile kept an owner at another epoch or released a kept one",
  );
  assert.equal((await c.invoke(two, "tools/list")).status, 200);

  // A later generation keeps nothing of an earlier one it does not name at its own generation.
  const { instance, server, controller } = await startBridge();
  try {
    const owner = newOwner();
    assert.equal((await controller.sync({ ...owner, backends: [backend("well-behaved")] })).status, 200);
    controller.generation = 2;
    const next = await controller.reconcile([owner]);
    assert.deepEqual(next.body.released, [{ athanor: owner.athanor, server: owner.server, g: 1, e: 1 }]);
  } finally {
    await stopBridge({ instance, server });
  }
  await c.release([two]);
});

// ============================================================================
// Masking
// ============================================================================

test("results, errors, status and stderr are masked with the owner's credential values", async () => {
  const secret = "sk-canary-0123456789";
  const owner = newOwner();
  await synced(owner, [
    backend("echo-env", { PROBE_OWN: secret, SHORT: "tiny", NODE_ENV: "production", AUTH: `Bearer ${secret}-2` }, "echo"),
    backend("error-env", { PROBE_OWN: secret }, "err"),
    backend("stderr-env", { PROBE_OWN: secret }, "noisy"),
  ]);

  assert.deepEqual(await c.tool(owner, "echo__echo", { name: "PROBE_OWN" }), { value: "[REDACTED]" });
  assert.deepEqual(await c.tool(owner, "echo__echo", { name: "AUTH" }), { value: "[REDACTED]" });
  assert.deepEqual(await c.tool(owner, "echo__echo", { name: "SHORT" }), { value: "tiny" });
  assert.deepEqual(await c.tool(owner, "echo__echo", { name: "NODE_ENV" }), { value: "production" });

  const refused = await c.invoke(owner, "tools/call", { name: "err__ping", arguments: {} });
  assert.equal(refused.body.result.isError, true);
  assert.equal(refused.body.result.content[0].text, "refused with [REDACTED]");

  const status = await eventually(async () => {
    const [entry] = (await c.status([owner])).body.owners;
    const noisy = entry.backends.find((b) => b.name === "noisy");
    return noisy.stderr_tail.includes("starting with") ? entry : null;
  }, "stderr to be kept");
  const noisy = status.backends.find((b) => b.name === "noisy");
  assert.equal(noisy.stderr_tail, "starting with [REDACTED]\n");
  assert.ok(!JSON.stringify(status).includes(secret));
  await c.release([owner]);
});

// ============================================================================
// Stdio framing and backend lifecycle
// ============================================================================

test("a child's own request does not resolve the bridge's pending call", async () => {
  const owner = newOwner();
  const body = await synced(owner, [backend("rogue-request")]);
  assert.deepEqual(body.backends, [{ name: "b", status: "ready", tools: 1 }]);
  await c.release([owner]);
});

test("a string-typed response id still matches its pending call", async () => {
  const owner = newOwner();
  await synced(owner, [backend("well-behaved")]);
  const call = await c.invoke(owner, "tools/call", { name: "b__ping", arguments: {} });
  assert.equal(call.status, 200);
  assert.equal(call.body.result.content[0].text, "pong");
  await c.release([owner]);
});

test("a backend that crashes is reported, restarts after its backoff, and fails after five crashes", async () => {
  const { instance, server, controller, spawner } = await startBridge({ restartBackoffMs: [50, 50, 50, 50, 50] });
  try {
    const owner = newOwner();
    assert.equal((await controller.sync({ ...owner, backends: [backend("die-on-call")] })).status, 200);
    const first = spawner.spawns.at(-1).proc;
    const call = await controller.invoke(owner, "tools/call", { name: "b__ping", arguments: {} });
    assert.equal(call.body.result.isError, true);

    await eventually(() => first.released, "the crashed backend's spawn to be retired");
    const restarted = await eventually(async () => {
      const [entry] = (await controller.status([owner])).body.owners;
      return entry.backends[0].status === "ready" && entry.backends[0].restarts === 1 ? entry : null;
    }, "the backend to restart");
    assert.equal(restarted.backends[0].error, null);

    const failing = newOwner();
    const sync = await controller.sync({ ...failing, backends: [backend("exit-at-start")] });
    assert.equal(sync.status, 200);
    const failed = await eventually(async () => {
      const [entry] = (await controller.status([failing])).body.owners;
      return entry.backends[0].status === "failed" ? entry.backends[0] : null;
    }, "the backend to be marked failed");
    assert.equal(failed.restarts, 4);
    assert.match(failed.error, /exited code=4/);
    assert.equal(failed.tools, 0);
    await sleep(200);
    assert.equal(spawner.spawns.filter((s) => s.argv[2].includes("exit-at-start")).length, 5, "a failed backend was restarted");
  } finally {
    await stopBridge({ instance, server });
  }
});

test("a call to a backend that has died is refused, and the bridge keeps serving", async () => {
  const owner = newOwner();
  await synced(owner, [backend("die-after-handshake")]);
  await sleep(200);
  const call = await c.invoke(owner, "tools/call", { name: "b__ping", arguments: {} });
  assert.equal(call.status, 200);
  assert.equal(call.body.result.isError, true);
  assert.equal((await c.invoke(owner, "tools/list")).status, 200);
  await c.release([owner]);
});

test("an explicit null id is a request, a notification is accepted, and GET is not allowed", async () => {
  const owner = newOwner();
  await synced(owner, [backend("well-behaved")]);
  const nullId = await c.invoke(owner, "tools/list", {}, { id: null });
  assert.equal(nullId.status, 200);
  assert.equal(nullId.body.id, null);

  const notification = await c.invoke(owner, "notifications/cancelled", {}, { notification: true });
  assert.equal(notification.status, 202);

  const get = await fetch(`${shared.base}/mcp`);
  assert.equal(get.status, 405);
  await c.release([owner]);
});

test("close releases every owner's spawns and ends their processes", async () => {
  const started = await startBridge();
  await started.controller.sync({ ...newOwner(), backends: [backend("well-behaved", {}, "a"), backend("well-behaved", {}, "b")] });
  await started.controller.sync({ ...newOwner(), backends: [backend("well-behaved")] });
  await stopBridge(started);
  assert.equal(started.spawner.spawns.length, 3);
  assert.ok(started.spawner.spawns.every(({ proc }) => proc.released), "close left a spawn unreleased");
  assert.ok(started.spawner.spawns.every(({ proc }) => !alive(proc.pid)), "close left a backend process running");
});

// ============================================================================
// Boot
// ============================================================================

function runServer(stdio, env) {
  return new Promise((resolve) => {
    const proc = spawn(process.execPath, [SERVER], {
      stdio,
      env: { PATH: process.env.PATH, MCP_BRIDGE_PORT: "0", ...env },
    });
    let stderr = "";
    proc.stderr.on("data", (chunk) => (stderr += chunk));
    const timer = setTimeout(() => proc.kill("SIGKILL"), 10_000);
    proc.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code, stderr });
    });
  });
}

test("server.mjs refuses to start unless fd 3 is the spawner's socket", async () => {
  const { code, stderr } = await runServer(["ignore", "ignore", "pipe"], { CYFR_MCP_BRIDGE_KEY: ROOT.toString("hex") });
  assert.equal(code, 1);
  assert.match(stderr, /fd 3 is not the spawner channel/);
});

test("server.mjs refuses to start without a valid key even with the spawner's socket", async () => {
  // A 'pipe' at index 3 is a socketpair end in the child.
  for (const key of [undefined, "", "not-hex", ROOT.toString("base64")]) {
    const { code, stderr } = await runServer(["ignore", "ignore", "pipe", "pipe"], key === undefined ? {} : { CYFR_MCP_BRIDGE_KEY: key });
    assert.equal(code, 1, String(key));
    assert.match(stderr, /CYFR_MCP_BRIDGE_KEY must be 64 hexadecimal digits/);
  }
});
