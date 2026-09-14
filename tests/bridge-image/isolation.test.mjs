// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The mcp-bridge image, run by docker compose with the mcp-bridge service's
// own settings and driven only by requests signed as CYFR signs them,
// isolates its backends from each other and from the bridge: each runs under
// its own pooled uid with a private home and an environment built from
// nothing but its sealed block; none can read another's home or /proc
// environ, or the bridge's, nor signal another backend, a relay, the bridge
// or the spawner; the spawner holds exactly SETUID, SETGID and KILL and no
// inet socket, and the bridge holds no capability; releasing an owner leaves
// no process of its uid, a detached daemon that ignores SIGTERM included, and
// no home. The bridge refuses to start without a valid key.
//
// Run: node --test tests/bridge-image/isolation.test.mjs
// BRIDGE_IMAGE names an image already built from Dockerfile.node's mcp-bridge
// target; without it the test builds cyfr-mcp-bridge:isolation first.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { IMAGE, PROBE, Stack, eventually, exec, healthy, processes, run } from "./harness.mjs";
import { Controller } from "./controller.mjs";
import { ownerKey } from "../../apps/mcp-bridge/auth.mjs";

const PROJECT = "cyfr-bridge-isolation";
const PLANTED = "planted-keyring-value";
const HOME_ROOT = "/var/lib/cyfr-bridge/homes";
const POOL_FIRST = 20001;
const POOL_LAST = 20032;
const BRIDGE_UID = 10001;
const SPAWNER_CAPS = "00000000000000e0";

const stack = new Stack(PROJECT);
let c;

const underUid = (uid) => processes(stack.container).filter((p) => p.uids.includes(uid));
const relays = (target = stack.container) => processes(target).filter((p) => p.cmdline.startsWith("cyfr-spawn relay"));

// Runs a script in a separate container sharing the bridge's PID and
// network namespaces with CAP_SYS_PTRACE, which reading another process's
// descriptors needs: the spawner is not dumpable, so root inside the bridge
// container cannot list them.
function inspect(script) {
  const name = `${PROJECT}-inspect`;
  run("docker", ["rm", "--force", name], { allowFailure: true });
  return run(
    "docker",
    [
      "run", "--rm", "--name", name,
      "--pid", `container:${stack.container}`, "--network", `container:${stack.container}`,
      "--cap-add", "SYS_PTRACE", "--entrypoint", "sh", IMAGE, "-c", script,
    ],
    { allowFailure: true },
  );
}

const ownerOf = (label) => ({ athanor: `ath_${label}`, server: `mcp_${label}`, e: 1 });

async function syncProbe(controller, owner, env = {}) {
  const answer = await controller.sync({ ...owner, backends: [{ name: "probe", command: PROBE, env }] });
  assert.equal(answer.status, 200, JSON.stringify(answer.body));
  assert.deepEqual(answer.body.backends.map((b) => b.status), ["ready"], JSON.stringify(answer.body));
  return answer.body;
}

before(async () => {
  await stack.start();
  c = stack.controller();
  assert.equal((await c.hello()).status, 200);
  assert.equal((await c.reconcile([])).status, 200);
});

after(() => stack.stop());

let spawner;
let bridge;
let alpha;
let beta;
const ALPHA = ownerOf("alpha");
const BETA = ownerOf("beta");
const ALPHA_SECRET = "alpha-secret-value";

test("the spawner holds exactly SETUID, SETGID and KILL and no inet socket; the bridge holds no capability", () => {
  const procs = processes(stack.container);
  spawner = procs.find((p) => p.cmdline.startsWith("cyfr-spawn serve"));
  bridge = procs.find((p) => p.cmdline === "node server.mjs");
  assert.ok(spawner, "no cyfr-spawn serve process");
  assert.ok(bridge, "no bridge process");

  assert.deepEqual(spawner.uids, [0, 0, 0, 0]);
  assert.equal(spawner.capEff, SPAWNER_CAPS);
  assert.equal(spawner.capPrm, SPAWNER_CAPS);
  assert.equal(spawner.capBnd, SPAWNER_CAPS);
  assert.equal(spawner.noNewPrivs, true);

  assert.deepEqual(bridge.uids, [BRIDGE_UID, BRIDGE_UID, BRIDGE_UID, BRIDGE_UID]);
  assert.equal(bridge.capEff, "0000000000000000");
  assert.equal(bridge.capPrm, "0000000000000000");
  assert.equal(bridge.noNewPrivs, true);

  const fds = inspect(`ls -l /proc/${spawner.pid}/fd`);
  const sockets = fds.stdout
    .split("\n")
    .map((line) => line.match(/socket:\[(\d+)\]/)?.[1])
    .filter(Boolean);
  assert.ok(sockets.length >= 1, `the spawner holds no channel socket: ${fds.stdout}${fds.stderr}`);
  const table = (name) => inspect(`cat /proc/${spawner.pid}/net/${name} 2>/dev/null`).stdout;
  const inet = ["tcp", "tcp6", "udp", "udp6"].map(table).join("\n");
  const unix = table("unix");
  for (const inode of sockets) {
    assert.ok(!new RegExp(`\\b${inode}\\b`).test(inet), `the spawner holds inet socket ${inode}`);
    assert.match(unix, new RegExp(`\\b${inode}\\b`), `spawner socket ${inode} is not a unix socket`);
  }
});

test("/health answers, the root is read-only, and an unsigned request to /control or /mcp is refused", async () => {
  assert.equal((await fetch(`${stack.base}/health`)).status, 200);
  for (const endpoint of ["control", "mcp"]) {
    const res = await fetch(`${stack.base}/${endpoint}`, {
      method: "POST",
      headers: { "content-type": "application/json", "mcp-protocol-version": "2026-07-28", "mcp-method": "tools/list" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
    });
    assert.equal(res.status, 401, endpoint);
  }
  const write = exec(stack.container, "touch /app/planted 2>&1; echo status=$?");
  assert.match(write.stdout, /Read-only file system/);
});

test("each backend runs under its own pooled uid, alone in its group, with a private home and an environment built from nothing", async () => {
  await syncProbe(c, ALPHA, { PROBE_SECRET: ALPHA_SECRET });
  await syncProbe(c, BETA, { PROBE_SECRET: "beta-secret-value" });
  alpha = await c.tool(ALPHA, "probe__whoami");
  beta = await c.tool(BETA, "probe__whoami");

  assert.notEqual(alpha.uid, beta.uid, "two backends share a uid");
  for (const [name, who] of [["alpha", alpha], ["beta", beta]]) {
    assert.ok(who.uid >= POOL_FIRST && who.uid <= POOL_LAST, `${name} runs as uid ${who.uid}, outside the pool`);
    assert.notEqual(who.uid, 0);
    assert.notEqual(who.uid, BRIDGE_UID);
    assert.equal(who.gid, who.uid, `${name} is not alone in its group`);
    assert.ok(who.groups.every((g) => g === who.gid), `${name} has supplementary groups ${who.groups}`);
    assert.match(who.home, new RegExp(`^${HOME_ROOT}/${who.uid}-[0-9a-f]{32}$`));
    assert.equal(who.home_mode, "700");
    assert.equal(who.marker_mode, "600", `${name}'s umask lets others read its files`);
    assert.equal(who.tmpdir, `${who.home}/tmp`);
    assert.equal(who.cwd, who.home);
    // PWD and SHLVL are set by the backend's own `sh -c`.
    assert.deepEqual(who.env_names, ["HOME", "LOGNAME", "PATH", "PROBE_SECRET", "PWD", "SHLVL", "TMPDIR", "USER"]);
    assert.deepEqual(who.limits, {
      nofile: { soft: "1024", hard: "1024" },
      nproc: { soft: "128", hard: "128" },
      core: { soft: "0", hard: "0" },
      fsize: { soft: "268435456", hard: "268435456" },
    });

    const procs = underUid(who.uid);
    assert.ok(procs.some((p) => p.pid === who.pid));
    for (const p of procs) {
      assert.equal(p.capEff, "0000000000000000", `${name} process ${p.pid} holds capabilities`);
      assert.equal(p.noNewPrivs, true);
    }
  }

  // The backend holds its sealed value; what it answers with is masked.
  assert.deepEqual(await c.tool(ALPHA, "probe__echo_env", { name: "PROBE_SECRET" }), { value: "[REDACTED]" });
  const environ = exec(stack.container, `tr '\\0' '\\n' < /proc/${alpha.pid}/environ`, { user: String(alpha.uid) }).stdout;
  assert.ok(environ.includes(`PROBE_SECRET=${ALPHA_SECRET}`), "the backend's environment lacks its sealed value");
  assert.deepEqual(await c.tool(ALPHA, "probe__echo_env", { name: "CYFR_MCP_BRIDGE_KEY" }), { value: null });
  assert.deepEqual(await c.tool(ALPHA, "probe__echo_env", { name: "CYFR_CRYPTO_KEYRING" }), { value: null });
  const bridgeEnviron = exec(stack.container, `tr '\\0' '\\n' < /proc/${bridge.pid}/environ`, { user: "cyfr-bridge" }).stdout;
  assert.ok(
    bridgeEnviron.includes(PLANTED) && bridgeEnviron.includes(stack.keyHex),
    "the planted secret or the key is not in the bridge's environment, so its absence from a backend proves nothing",
  );

  // One owner's key does not reach another owner's backends.
  const betaKey = ownerKey(stack.root, { athanor: BETA.athanor, server: BETA.server, generation: 1, epoch: 1 });
  const across = await c.invoke(ALPHA, "tools/call", { name: "probe__whoami", arguments: {} }, { key: betaKey });
  assert.equal(across.status, 401);
  const listed = await c.invoke(BETA, "tools/list");
  assert.deepEqual(listed.body.result.tools.map((t) => t.name).sort(), [
    "probe__echo_env", "probe__exit", "probe__read_environ", "probe__read_path", "probe__signal", "probe__spawn_daemon", "probe__whoami",
  ]);
});

test("a backend cannot read another's home or environ, nor the bridge's, nor signal another backend, a relay, the bridge or the spawner", async () => {
  const relayProcs = relays();
  assert.equal(relayProcs.length, 2, "not one relay per backend");
  assert.ok(relayProcs.every((p) => p.uids.every((u) => u === BRIDGE_UID)), "a relay does not run as the bridge's user");

  for (const [self, other] of [[ALPHA, beta], [BETA, alpha]]) {
    const refused = async (toolName, args, code) => {
      const result = await c.tool(self, `probe__${toolName}`, args);
      assert.deepEqual(result, { ok: false, code }, `${self.athanor} ${toolName} ${JSON.stringify(args)}`);
    };
    await refused("read_path", { path: other.marker }, "EACCES");
    await refused("read_path", { path: other.home }, "EACCES");
    await refused("read_path", { path: HOME_ROOT }, "EACCES");
    await refused("read_environ", { pid: other.pid }, "EACCES");
    await refused("read_environ", { pid: bridge.pid }, "EACCES");
    await refused("read_path", { path: "/run/cyfr-bridge" }, "EACCES");
    await refused("signal", { pid: other.pid, sig: "SIGKILL" }, "EPERM");
    await refused("signal", { pid: bridge.pid, sig: "SIGKILL" }, "EPERM");
    await refused("signal", { pid: spawner.pid, sig: "SIGKILL" }, "EPERM");
    for (const relay of relayProcs) await refused("signal", { pid: relay.pid, sig: "SIGKILL" }, "EPERM");
  }

  assert.equal((await c.tool(ALPHA, "probe__whoami")).pid, alpha.pid, "alpha did not survive beta's attempts");
  assert.equal((await c.tool(BETA, "probe__whoami")).pid, beta.pid, "beta did not survive alpha's attempts");
});

test("releasing an owner retires every process of its uid, a detached daemon that ignores SIGTERM included, its relay and its home", async () => {
  const { pid: daemon } = await c.tool(ALPHA, "probe__spawn_daemon");
  const daemonProc = await eventually(() => processes(stack.container).find((p) => p.pid === daemon), "the daemon to start");
  assert.ok(daemonProc.uids.includes(alpha.uid), "the daemon does not run as alpha's uid");
  const leader = processes(stack.container).find((p) => p.pid === alpha.pid);
  assert.notEqual(daemonProc.sid, leader.sid, "the daemon did not leave the backend's session");

  const released = await c.release([ALPHA]);
  assert.deepEqual(released.body, { released: [{ athanor: ALPHA.athanor, server: ALPHA.server, g: 1, e: 1 }] });
  assert.equal((await c.invoke(ALPHA, "tools/list")).body.error, "unknown_owner");

  await eventually(() => underUid(alpha.uid).length === 0, `no process of uid ${alpha.uid}`);
  await eventually(() => relays().length === 1, "alpha's relay to end");
  assert.equal(exec(stack.container, `test -e ${alpha.home}`).status, 1, "alpha's home outlived its release");
  assert.equal((await c.tool(BETA, "probe__whoami")).pid, beta.pid, "releasing alpha disturbed beta");
});

test("a backend that exits is reported, its uid and home retired, and it restarts to ready in a new home", async () => {
  await c.tool(BETA, "probe__exit", { code: 7 });
  await eventually(() => !processes(stack.container).some((p) => p.pid === beta.pid), "beta's process to end");
  const restarted = await eventually(async () => {
    const [owner] = (await c.status([BETA])).body.owners;
    const [backend] = owner.backends;
    return backend.status === "ready" && backend.restarts === 1 ? backend : null;
  }, "beta to restart");
  assert.equal(restarted.tools, 7);
  assert.equal(exec(stack.container, `test -e ${beta.home}`).status, 1, "beta's home outlived its exit");

  const again = await c.tool(BETA, "probe__whoami");
  assert.ok(again.uid >= POOL_FIRST && again.uid <= POOL_LAST);
  assert.notEqual(again.home, beta.home);
  assert.notEqual(again.pid, beta.pid);
  await eventually(() => relays().length === 1, "one relay for beta's new process");
});

test("the bridge refuses to start without a key or with a malformed one", () => {
  for (const key of ["", "not-a-key", stack.root.toString("base64")]) {
    const result = stack.compose("run", "--rm", "--no-deps", "-T", "-e", `CYFR_MCP_BRIDGE_KEY=${key}`, "mcp-bridge");
    assert.notEqual(result.status, 0, `started with key ${JSON.stringify(key)}`);
    assert.match(result.stdout + result.stderr, /CYFR_MCP_BRIDGE_KEY must be 64 hexadecimal digits/);
  }
});

test("when the bridge dies, the spawner retires every backend and exits 70", async () => {
  const name = `${PROJECT}-lost`;
  run("docker", ["rm", "--force", name], { allowFailure: true });
  stack.compose("run", "--detach", "--name", name, "--no-deps", "--service-ports", "mcp-bridge");
  try {
    const url = `http://${run("docker", ["port", name, "8001"]).stdout.trim().split("\n")[0]}`;
    await healthy(url);
    const controller = new Controller({ base: url, root: stack.root });
    assert.equal((await controller.hello()).status, 200);
    const orphanOwner = ownerOf("orphan");
    await syncProbe(controller, orphanOwner);
    const orphan = await controller.tool(orphanOwner, "probe__whoami");
    const { pid: daemon } = await controller.tool(orphanOwner, "probe__spawn_daemon");
    await eventually(() => processes(name).some((p) => p.pid === daemon), "the daemon to start");

    const node = processes(name).find((p) => p.cmdline === "node server.mjs");
    run("docker", ["exec", name, "kill", "-KILL", String(node.pid)]);

    assert.equal(run("docker", ["wait", name]).stdout.trim(), "70");
    const logs = run("docker", ["logs", name]);
    const text = logs.stdout + logs.stderr;
    assert.match(text, /client channel lost; every spawn retired/);
    assert.doesNotMatch(text, /quarantined|did not finish/, `uid ${orphan.uid} was not retired cleanly`);
  } finally {
    run("docker", ["rm", "--force", name], { allowFailure: true });
  }
});

test("the spawner refuses to start with Docker's default capabilities", () => {
  const name = `${PROJECT}-defaults`;
  run("docker", ["rm", "--force", name], { allowFailure: true });
  const result = run("docker", ["run", "--rm", "--name", name, "-e", `CYFR_MCP_BRIDGE_KEY=${stack.keyHex}`, IMAGE], { allowFailure: true });
  assert.equal(result.status, 78);
  assert.match(result.stderr, /refusing to start: CapEff/);
});

test("stopping the service retires every backend and the spawner exits 0", async () => {
  const last = ownerOf("last");
  await syncProbe(c, last);
  const who = await c.tool(last, "probe__whoami");
  await c.tool(last, "probe__spawn_daemon");

  stack.compose("stop", "mcp-bridge");

  assert.equal(run("docker", ["inspect", "--format", "{{.State.ExitCode}}", stack.container]).stdout.trim(), "0");
  const text = stack.compose("logs", "--no-color", "mcp-bridge").stdout;
  assert.match(text, /SIGTERM — stopping/);
  assert.match(text, /\[cyfr-spawn\] info: stopped/);
  assert.doesNotMatch(text, /quarantined|did not finish/, `uid ${who.uid} was not retired cleanly`);
  // The sealed values never reach the bridge's log.
  assert.ok(!text.includes(ALPHA_SECRET), "a backend's credential reached the bridge's log");
});
