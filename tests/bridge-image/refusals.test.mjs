// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The mcp-bridge image refuses, before any state changes, every request it
// cannot attribute to the lifetime, order, owner version and nonce it names:
// a forged MAC and a timestamp outside the window (401), answered before a
// large body is sent; a control message at or below the high-water mark, an
// invoke at a stale or future epoch, a replayed nonce, and a captured invoke
// sent again after the container restarts (409). A sync the uid pool cannot
// hold spawns nothing.
//
// Run: node --test tests/bridge-image/refusals.test.mjs
// BRIDGE_IMAGE names an image already built from Dockerfile.node's mcp-bridge
// target; without it the test builds cyfr-mcp-bridge:isolation first.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import net from "node:net";
import * as auth from "../../apps/mcp-bridge/auth.mjs";
import { Controller } from "./controller.mjs";
import { PROBE, Stack, eventually, processes, run } from "./harness.mjs";

const POOL = [20001, 20002, 20003];
const stack = new Stack("cyfr-bridge-refusals", { overrides: ["compose.refusals.yml"] });
let c;

const MAIN = { athanor: "ath_main", server: "mcp_main", e: 2 };
const probe = (name = "probe") => ({ name, command: PROBE, env: { PROBE_SECRET: "refusal-secret-value" } });
const unauthorizedRpc = { jsonrpc: "2.0", id: null, error: { code: -33001, message: "unauthorized" } };

const poolProcesses = () => processes(stack.container).filter((p) => p.uids.some((uid) => POOL.includes(uid)));

before(async () => {
  await stack.start();
  c = stack.controller();
  assert.equal((await c.hello()).status, 200);
  const synced = await c.sync({ ...MAIN, backends: [probe()] });
  assert.equal(synced.status, 200, JSON.stringify(synced.body));
  await c.running(MAIN);
});

after(() => stack.stop());

test("a forged MAC is refused on both endpoints", async () => {
  const control = await c.renew([MAIN], 30_000, { key: randomBytes(32) });
  assert.deepEqual([control.status, control.body], [401, { error: "unauthorized" }]);
  const invoke = await c.invoke(MAIN, "tools/list", {}, { key: randomBytes(32) });
  assert.deepEqual([invoke.status, invoke.body], [401, unauthorizedRpc]);

  // A valid signature over another body does not carry to this one, and
  // spends no nonce.
  const signed = c.signInvoke(MAIN, "tools/list");
  const tampered = await c.resend({ ...signed, body: signed.body.replace('"id":1', '"id":2') });
  assert.deepEqual([tampered.status, tampered.body], [401, unauthorizedRpc]);
  assert.equal((await c.resend(signed)).status, 200);
});

test("a request refused by its header is answered before its body is sent", async () => {
  const declared = 28 * 1024 * 1024;
  const { hostname, port } = new URL(stack.base);
  for (const [endpoint, header] of [
    ["control", auth.controlHeader(randomBytes(32), { generation: 1, seq: 1, cyfr_boot: c.cyfrBoot, boot: c.boot, ts: Date.now() }, "{}")],
    ["mcp", c.signInvoke(MAIN, "tools/list", {}, { key: randomBytes(32) }).headers["cyfr-bridge-auth"]],
  ]) {
    const status = await new Promise((resolve, reject) => {
      const socket = net.connect(Number(port), hostname, () => {
        socket.write(`POST /${endpoint} HTTP/1.1\r\nhost: ${hostname}\r\ncontent-length: ${declared}\r\ncyfr-bridge-auth: ${header}\r\n\r\n`);
        socket.write(Buffer.alloc(1024, 0x7b));
      });
      let head = "";
      socket.setEncoding("latin1");
      socket.on("data", (chunk) => {
        head += chunk;
        if (head.includes("\r\n")) {
          socket.destroy();
          resolve(Number(head.split(" ")[1]));
        }
      });
      socket.on("error", reject);
      setTimeout(() => reject(new Error(`/${endpoint} did not answer before the body was sent`)), 5_000).unref();
    });
    assert.equal(status, 401, endpoint);
  }
});

test("a timestamp outside the 30 s window is refused on both endpoints", async () => {
  for (const ts of [Date.now() - 31_000, Date.now() + 31_000]) {
    const control = await c.renew([MAIN], 30_000, { ts });
    assert.deepEqual([control.status, control.body], [401, { error: "unauthorized" }]);
    const invoke = await c.invoke(MAIN, "tools/list", {}, { ts });
    assert.deepEqual([invoke.status, invoke.body], [401, unauthorizedRpc]);
  }
});

test("a control message at or below the high-water mark is refused", async () => {
  const accepted = await c.renew([MAIN]);
  assert.deepEqual(accepted.body.unknown, []);
  assert.deepEqual(accepted.body.renewed.map(({ athanor, server, e }) => ({ athanor, server, e })), [MAIN]);
  const seq = c.seq;
  for (const options of [{ seq }, { seq: seq - 1 }, { generation: 0, seq: seq + 100 }]) {
    const stale = await c.renew([MAIN], 30_000, options);
    assert.deepEqual([stale.status, stale.body], [409, { error: "stale_control" }], JSON.stringify(options));
  }
  assert.equal((await c.renew([MAIN])).status, 200);
});

test("an invoke at a stale or a future epoch is refused", async () => {
  const stale = await c.invoke({ ...MAIN, e: 1 }, "tools/list");
  assert.deepEqual([stale.status, stale.body], [409, { error: "stale_epoch" }]);
  const ahead = await c.invoke({ ...MAIN, e: 3 }, "tools/list");
  assert.deepEqual([ahead.status, ahead.body], [409, { error: "epoch_ahead" }]);
  const unknown = await c.invoke({ ...MAIN, server: "mcp_none" }, "tools/list");
  assert.deepEqual([unknown.status, unknown.body], [409, { error: "unknown_owner" }]);
});

test("a replayed nonce is refused", async () => {
  const first = await c.invoke(MAIN, "tools/call", { name: "probe__whoami", arguments: {} });
  assert.equal(first.status, 200);
  const replay = await c.resend(first.request);
  assert.deepEqual([replay.status, replay.body], [409, { error: "replay" }]);
});

test("a sync the uid pool cannot hold spawns nothing", async () => {
  const fill = { athanor: "ath_fill", server: "mcp_fill", e: 1 };
  const filled = await c.sync({ ...fill, backends: [probe("one"), probe("two")] });
  assert.equal(filled.status, 200, JSON.stringify(filled.body));
  await c.running(fill);
  assert.equal((await c.hello()).body.pool.free, 0);
  const before = poolProcesses().map((p) => p.pid).sort();

  const extra = { athanor: "ath_extra", server: "mcp_extra", e: 1 };
  const refused = await c.sync({ ...extra, backends: [probe()] });
  assert.deepEqual([refused.status, refused.body], [409, { error: "capacity" }]);
  assert.deepEqual(poolProcesses().map((p) => p.pid).sort(), before, "a refused sync started a process");
  assert.deepEqual((await c.status([extra])).body, { owners: [] });

  // A replacement that needs more than the pool frees keeps nothing running for it either.
  const bigger = await c.sync({ ...fill, e: 2, backends: [probe("one"), probe("two"), probe("three"), probe("four")] });
  assert.deepEqual([bigger.status, bigger.body], [409, { error: "capacity" }]);
  await eventually(async () => (await c.hello()).body.pool.free === 2, "the replaced owner's uids to return");
  assert.deepEqual((await c.status([fill])).body, { owners: [] });
});

test("a captured invoke sent again after the container restarts is refused as stale_boot", async () => {
  const captured = await c.invoke(MAIN, "tools/call", { name: "probe__whoami", arguments: {} });
  assert.equal(captured.status, 200);
  const oldBoot = captured.boot;

  run("docker", ["restart", stack.container]);
  const base = await stack.published();

  const again = await c.resend(captured.request, base);
  assert.deepEqual([again.status, again.body], [409, { error: "stale_boot" }]);
  assert.notEqual(again.boot, oldBoot);
  const signedAt = Number(captured.request.headers["cyfr-bridge-auth"].match(/ts=(\d+)/)[1]);
  assert.ok(Date.now() - signedAt < 30_000, "the resend fell outside the window, so it proves nothing");

  // A control message for the old lifetime is refused the same way.
  const restarted = new Controller({ base, root: stack.root, cyfrBoot: c.cyfrBoot });
  const control = await restarted.renew([MAIN], 30_000, { boot: oldBoot, seq: c.seq + 1 });
  assert.deepEqual([control.status, control.body], [409, { error: "stale_boot" }]);
});
