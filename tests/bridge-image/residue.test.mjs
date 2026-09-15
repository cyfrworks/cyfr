// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// A pooled uid hands nothing to its next holder. Under the mcp-bridge
// service's settings no location outside a backend's home is writable to it
// but the home root, which it cannot list; the spawner refuses to start when
// a shared /tmp or /dev/shm or a writable root would give it one. What a
// backend does leave — an entry in the home root, a directory tree it made
// unwritable, System V shared memory, a semaphore set, a message queue and a
// POSIX message queue — is gone once its owner is released, before a second
// owner runs under the same uid (the pool holds one).
//
// Run: node --test tests/bridge-image/residue.test.mjs
// BRIDGE_IMAGE names an image already built from Dockerfile.node's mcp-bridge
// target; without it the test builds cyfr-mcp-bridge:isolation first.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { rmSync } from "node:fs";
import { IMAGE, PROBE, Stack, buildCanary, eventually, exec, processes, run } from "./harness.mjs";

const PROJECT = "cyfr-bridge-residue";
const HOME_ROOT = "/var/lib/cyfr-bridge/homes";
const UID = 20001;
const TAG = "cyfr-residue-canary";
const SHARED = [`/tmp/${TAG}`, `/var/tmp/${TAG}`, `/dev/shm/${TAG}`, `/run/${TAG}`, `/run/cyfr-bridge/${TAG}`];
const LEFT = [`${HOME_ROOT}/${TAG}`, `${HOME_ROOT}/${TAG}-tree/`];
const IPC = ["shm", "sem", "msg", "mqueue"];

const canaryDir = buildCanary();
const stack = new Stack(PROJECT, { overrides: ["compose.residue.yml"], env: { CANARY_DIR: canaryDir } });
let c;

before(async () => {
  await stack.start();
  c = stack.controller();
  assert.equal((await c.hello()).status, 200);
  assert.equal((await c.reconcile([])).status, 200);
});

after(() => {
  stack.stop();
  rmSync(canaryDir, { recursive: true, force: true });
});

const ownerOf = (label) => ({ athanor: `ath_${label}`, server: `mcp_${label}`, e: 1 });

async function syncProbe(owner) {
  const answer = await c.sync({ ...owner, backends: [{ name: "probe", command: PROBE, env: {} }] });
  assert.equal(answer.status, 200, JSON.stringify(answer.body));
  assert.deepEqual(answer.body.backends.map((b) => b.status), ["ready"], JSON.stringify(answer.body));
  return c.tool(owner, "probe__whoami");
}

async function canary(owner, verb) {
  const answer = await c.tool(owner, "probe__run", { argv: ["/canary/canary", verb, TAG, ...SHARED, ...LEFT] });
  assert.equal(answer.status, 0, JSON.stringify(answer));
  return JSON.parse(answer.stdout);
}

// What the kernel holds for the uid, read as root inside the container.
function heldByUid() {
  const script = `
    find ${HOME_ROOT} /dev/mqueue -mindepth 1 -maxdepth 1 -user ${UID} 2>/dev/null
    for t in shm sem msg; do awk -v u=${UID} 'NR > 1 { for (i = 1; i <= NF; i++) if (h[i] == "uid" || h[i] == "cuid") if ($i == u) { print FILENAME ": " $2; next } } NR == 1 { for (i = 1; i <= NF; i++) h[i] = $i }' /proc/sysvipc/$t; done`;
  return exec(stack.container, script).stdout.split("\n").filter(Boolean);
}

test("a backend can write outside its home only into the home root, and leaves IPC objects", async () => {
  const first = await syncProbe(ownerOf("first"));
  assert.equal(first.uid, UID);

  const planted = await canary(ownerOf("first"), "plant");
  assert.equal(planted.uid, UID);
  assert.deepEqual(planted.files, {
    [`/tmp/${TAG}`]: "EROFS",
    [`/var/tmp/${TAG}`]: "EROFS",
    [`/dev/shm/${TAG}`]: "ENOENT",
    [`/run/${TAG}`]: "EROFS",
    [`/run/cyfr-bridge/${TAG}`]: "EACCES",
    [`${HOME_ROOT}/${TAG}`]: "ok",
    [`${HOME_ROOT}/${TAG}-tree/`]: "ok",
  });
  for (const kind of IPC) assert.equal(planted[kind], "ok", `${kind}: ${JSON.stringify(planted)}`);

  const held = heldByUid();
  assert.ok(held.includes(`${HOME_ROOT}/${TAG}`) && held.includes(`${HOME_ROOT}/${TAG}-tree`), held.join("\n"));
  assert.ok(held.includes(`/dev/mqueue/${TAG}`), held.join("\n"));
  for (const table of ["shm", "sem", "msg"]) {
    assert.ok(held.some((line) => line.startsWith(`/proc/sysvipc/${table}:`)), `no ${table} object: ${held.join("\n")}`);
  }
});

test("releasing the owner removes all of it before the uid runs the next owner", async () => {
  const released = await c.release([ownerOf("first")]);
  assert.equal(released.status, 200);
  await eventually(() => processes(stack.container).every((p) => !p.uids.includes(UID)), `no process of uid ${UID}`);
  await eventually(() => heldByUid().length === 0, `nothing held by uid ${UID}`);

  const second = await syncProbe(ownerOf("second"));
  assert.equal(second.uid, UID, "the second owner does not run under the released uid");

  const probed = await canary(ownerOf("second"), "probe");
  assert.equal(probed.uid, UID);
  assert.deepEqual(probed.files, {
    [`/tmp/${TAG}`]: "absent",
    [`/var/tmp/${TAG}`]: "absent",
    [`/dev/shm/${TAG}`]: "absent",
    [`/run/${TAG}`]: "absent",
    [`/run/cyfr-bridge/${TAG}`]: "denied",
    [`${HOME_ROOT}/${TAG}`]: "absent",
    [`${HOME_ROOT}/${TAG}-tree/`]: "absent",
  });
  for (const kind of IPC) assert.equal(probed[kind], "absent", `${kind}: ${JSON.stringify(probed)}`);
  assert.deepEqual(heldByUid(), [second.home], "the uid holds something besides the second owner's home");

  const logs = stack.compose("logs", "--no-color", "mcp-bridge").stdout;
  assert.doesNotMatch(logs, /quarantined|outlived retirement|could not be removed/);
});

test("the spawner refuses to start where a pooled uid could write a shared location", () => {
  const settings = [
    "--rm", "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
    "--security-opt", "no-new-privileges:true", "-e", `CYFR_MCP_BRIDGE_KEY=${stack.keyHex}`,
    "--tmpfs", `${HOME_ROOT}:mode=1733`, "--tmpfs", "/run/cyfr-bridge:uid=10001,gid=10001,mode=0700",
  ];
  for (const [flags, refusal] of [
    [["--ipc", "none"], /the root filesystem is writable/],
    [["--read-only", "--ipc", "none", "--tmpfs", "/tmp:mode=1777"], /mount \/tmp .* is writable by pooled uids/],
    [["--read-only"], /mount \/dev\/shm .* is writable by pooled uids/],
  ]) {
    const result = run("docker", ["run", ...settings, ...flags, IMAGE], { allowFailure: true });
    assert.equal(result.status, 78, `${flags.join(" ")}: ${result.stderr}`);
    assert.match(result.stderr, refusal);
  }
});
