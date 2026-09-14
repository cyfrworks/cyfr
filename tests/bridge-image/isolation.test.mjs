// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The mcp-bridge image, run by docker compose with the mcp-bridge service's
// own settings, isolates its backends from each other and from the bridge:
// each runs under its own pooled uid with a private home and an environment
// built from nothing; none can read another's home or /proc environ, or the
// bridge's, nor signal another backend, a relay, the bridge or the spawner;
// the spawner holds exactly SETUID, SETGID and KILL and no inet socket, and
// the bridge holds no capability; retiring a backend leaves no process of
// its uid, a detached daemon that ignores SIGTERM included, and no home.
//
// Run: node --test tests/bridge-image/isolation.test.mjs
// BRIDGE_IMAGE names an image already built from Dockerfile.node's mcp-bridge
// target; without it the test builds cyfr-mcp-bridge:isolation first.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const IMAGE = process.env.BRIDGE_IMAGE || "cyfr-mcp-bridge:isolation";
const PROJECT = "cyfr-bridge-isolation";
const TOKEN = "isolation-test-token";
const PLANTED = "planted-keyring-value";
const HOME_ROOT = "/var/lib/cyfr-bridge/homes";
const POOL_FIRST = 20001;
const POOL_LAST = 20032;
const BRIDGE_UID = 10001;
const SPAWNER_CAPS = "00000000000000e0";

let projectDir;
let composeEnv;
let container;
let base;

function run(cmd, args, { env, allowFailure = false } = {}) {
  const result = spawnSync(cmd, args, { env: env || process.env, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (!allowFailure && result.status !== 0) {
    throw new Error(`${cmd} ${args.join(" ")} exited ${result.status}\n${result.stdout}\n${result.stderr}`);
  }
  return result;
}

function compose(...args) {
  return run(
    "docker",
    [
      "compose",
      "--project-name",
      PROJECT,
      "--project-directory",
      projectDir,
      "-f",
      path.join(ROOT, "docker-compose.yml"),
      "-f",
      path.join(HERE, "compose.isolation.yml"),
      ...args,
    ],
    { env: composeEnv, allowFailure: args[0] === "run" },
  );
}

function exec(script, { user, target = container } = {}) {
  return run("docker", ["exec", ...(user ? ["-u", user] : []), target, "sh", "-c", script], { allowFailure: true });
}

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
      "--pid", `container:${container}`, "--network", `container:${container}`,
      "--cap-add", "SYS_PTRACE", "--entrypoint", "sh", IMAGE, "-c", script,
    ],
    { allowFailure: true },
  );
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function eventually(check, what, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(100);
  }
}

// Every process in the container: pid, session, uids, capability sets,
// no_new_privs and command line, read as root inside the container.
function processes(target = container) {
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
  const out = exec(script, { target }).stdout;
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

const underUid = (uid) => processes().filter((p) => p.uids.includes(uid));

async function mcp(method, params, url = base) {
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
      id: 1,
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
  return { status: res.status, body: await res.json() };
}

async function tool(name, args = {}, url = base) {
  const { body } = await mcp("tools/call", { name, arguments: args }, url);
  assert.ok(body.result, `${name}: ${JSON.stringify(body)}`);
  assert.notEqual(body.result.isError, true, `${name}: ${body.result.content?.[0]?.text}`);
  return JSON.parse(body.result.content[0].text);
}

const addProbe = (name, env, url = base) =>
  tool("add_backend", { name, command: "node /probe/probe-backend.mjs", env }, url);

const relays = (target) => processes(target).filter((p) => p.cmdline.startsWith("cyfr-spawn relay"));

async function healthy(url) {
  await eventually(async () => {
    try {
      return (await fetch(`${url}/health`)).ok;
    } catch {
      return false;
    }
  }, `${url}/health`, 30_000);
}

before(async () => {
  if (!process.env.BRIDGE_IMAGE) {
    run("docker", ["build", "-f", path.join(ROOT, "Dockerfile.node"), "--target", "mcp-bridge", "-t", IMAGE, ROOT]);
  }

  // A project directory of its own, with the empty .env the rest of the
  // stack's definition names.
  projectDir = mkdtempSync(path.join(tmpdir(), "bridge-isolation-"));
  writeFileSync(path.join(projectDir, ".env"), "");
  composeEnv = {
    ...process.env,
    BRIDGE_IMAGE: IMAGE,
    PROBE_DIR: path.join(ROOT, "apps", "mcp-bridge", "test", "fixtures"),
    MCP_BRIDGE_TOKEN: TOKEN,
  };

  compose("down", "--volumes", "--remove-orphans");
  compose("up", "--detach", "--no-build", "mcp-bridge");
  container = compose("ps", "--quiet", "mcp-bridge").stdout.trim();
  assert.ok(container, "compose started no mcp-bridge container");
  const published = compose("port", "mcp-bridge", "8001").stdout.trim();
  base = `http://${published}`;

  await healthy(base);
});

after(() => {
  if (projectDir) {
    if (process.env.CI) process.stdout.write(compose("logs", "--no-color", "mcp-bridge").stdout);
    compose("down", "--volumes", "--remove-orphans");
    rmSync(projectDir, { recursive: true, force: true });
  }
});

let spawner;
let bridge;
let alpha;
let beta;

test("the spawner holds exactly SETUID, SETGID and KILL and no inet socket; the bridge holds no capability", () => {
  const procs = processes();
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

test("/health answers and /mcp refuses a missing bearer", async () => {
  assert.equal((await fetch(`${base}/health`)).status, 200);
  const res = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", "mcp-protocol-version": "2026-07-28", "mcp-method": "tools/list" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  assert.equal(res.status, 401);
});

test("each backend runs under its own pooled uid, alone in its group, with a private home and an environment built from nothing", async () => {
  assert.equal((await addProbe("alpha", { PROBE_SECRET: "alpha-secret" })).status, "ready");
  assert.equal((await addProbe("beta", { PROBE_SECRET: "beta-secret" })).status, "ready");
  alpha = await tool("alpha__whoami");
  beta = await tool("beta__whoami");

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

  assert.deepEqual(await tool("alpha__echo_env", { name: "PROBE_SECRET" }), { value: "alpha-secret" });
  assert.deepEqual(await tool("alpha__echo_env", { name: "MCP_BRIDGE_TOKEN" }), { value: null });
  assert.deepEqual(await tool("alpha__echo_env", { name: "CYFR_CRYPTO_KEYRING" }), { value: null });
  assert.ok(
    exec(`tr '\\0' '\\n' < /proc/${bridge.pid}/environ`, { user: "cyfr-bridge" }).stdout.includes(PLANTED),
    "the planted secret is not in the bridge's environment, so its absence from a backend proves nothing",
  );
});

test("a backend cannot read another's home or environ, nor the bridge's, nor signal another backend, a relay, the bridge or the spawner", async () => {
  const relayProcs = relays();
  assert.equal(relayProcs.length, 2, "not one relay per backend");
  assert.ok(relayProcs.every((p) => p.uids.every((u) => u === BRIDGE_UID)), "a relay does not run as the bridge's user");

  for (const [self, other] of [["alpha", beta], ["beta", alpha]]) {
    const refused = async (toolName, args, code) => {
      const result = await tool(`${self}__${toolName}`, args);
      assert.deepEqual(result, { ok: false, code }, `${self} ${toolName} ${JSON.stringify(args)}`);
    };
    await refused("read_path", { path: other.marker }, "EACCES");
    await refused("read_path", { path: other.home }, "EACCES");
    await refused("read_path", { path: HOME_ROOT }, "EACCES");
    await refused("read_environ", { pid: other.pid }, "EACCES");
    await refused("read_environ", { pid: bridge.pid }, "EACCES");
    await refused("read_path", { path: "/data" }, "EACCES");
    await refused("read_path", { path: "/run/cyfr-bridge" }, "EACCES");
    await refused("signal", { pid: other.pid, sig: "SIGKILL" }, "EPERM");
    await refused("signal", { pid: bridge.pid, sig: "SIGKILL" }, "EPERM");
    await refused("signal", { pid: spawner.pid, sig: "SIGKILL" }, "EPERM");
    for (const relay of relayProcs) await refused("signal", { pid: relay.pid, sig: "SIGKILL" }, "EPERM");
  }

  assert.equal((await tool("alpha__whoami")).pid, alpha.pid, "alpha did not survive beta's attempts");
  assert.equal((await tool("beta__whoami")).pid, beta.pid, "beta did not survive alpha's attempts");
});

test("removing a backend retires every process of its uid, a detached daemon that ignores SIGTERM included, its relay and its home", async () => {
  const { pid: daemon } = await tool("alpha__spawn_daemon");
  const daemonProc = await eventually(() => processes().find((p) => p.pid === daemon), "the daemon to start");
  assert.ok(daemonProc.uids.includes(alpha.uid), "the daemon does not run as alpha's uid");
  const leader = processes().find((p) => p.pid === alpha.pid);
  assert.notEqual(daemonProc.sid, leader.sid, "the daemon did not leave the backend's session");

  assert.deepEqual(await tool("remove_backend", { name: "alpha" }), { removed: "alpha" });

  await eventually(() => underUid(alpha.uid).length === 0, `no process of uid ${alpha.uid}`);
  await eventually(() => relays().length === 1, "alpha's relay to end");
  assert.equal(exec(`test -e ${alpha.home}`).status, 1, "alpha's home outlived its removal");
  assert.equal((await tool("beta__whoami")).pid, beta.pid, "removing alpha disturbed beta");
});

test("a backend that exits is reported crashed with its uid retired, and restarts to ready", async () => {
  await tool("beta__exit", { code: 7 });
  await eventually(async () => {
    const { backends } = await tool("list_backends");
    const entry = backends.find((b) => b.name === "beta");
    return entry?.status === "crashed" && /exited code=7/.test(entry.error);
  }, "beta to be reported crashed");
  await eventually(() => underUid(beta.uid).length === 0, `no process of uid ${beta.uid}`);
  await eventually(() => relays().length === 0, "beta's relay to end");
  assert.equal(exec(`test -e ${beta.home}`).status, 1, "beta's home outlived its exit");

  assert.equal((await tool("restart_backend", { name: "beta" })).status, "ready");
  const again = await tool("beta__whoami");
  assert.ok(again.uid >= POOL_FIRST && again.uid <= POOL_LAST);
  assert.notEqual(again.home, beta.home);
});

test("backends persist to /data as the bridge's user", () => {
  const stat = exec("stat -c '%u %a' /data/backends.json", { user: "cyfr-bridge" });
  assert.equal(stat.stdout.trim(), `${BRIDGE_UID} 600`, stat.stderr);
});

test("the bridge refuses to start without a token", () => {
  const result = compose("run", "--rm", "--no-deps", "-T", "-e", "MCP_BRIDGE_TOKEN=", "mcp-bridge");
  assert.notEqual(result.status, 0);
  assert.match(result.stdout + result.stderr, /MCP_BRIDGE_TOKEN is unset/);
});

test("when the bridge dies, the spawner retires every backend and exits 70", async () => {
  const name = `${PROJECT}-lost`;
  run("docker", ["rm", "--force", name], { allowFailure: true });
  compose("run", "--detach", "--name", name, "--no-deps", "--service-ports", "mcp-bridge");
  try {
    const url = `http://${run("docker", ["port", name, "8001"]).stdout.trim().split("\n")[0]}`;
    await healthy(url);
    assert.equal((await addProbe("orphan", {}, url)).status, "ready");
    const orphan = await tool("orphan__whoami", {}, url);
    const { pid: daemon } = await tool("orphan__spawn_daemon", {}, url);
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
  const result = run("docker", ["run", "--rm", "--name", name, IMAGE], { allowFailure: true });
  assert.equal(result.status, 78);
  assert.match(result.stderr, /refusing to start: CapEff/);
});

test("stopping the service retires every backend and the spawner exits 0", async () => {
  assert.equal((await addProbe("last", {})).status, "ready");
  const last = await tool("last__whoami");
  await tool("last__spawn_daemon");

  compose("stop", "mcp-bridge");

  assert.equal(run("docker", ["inspect", "--format", "{{.State.ExitCode}}", container]).stdout.trim(), "0");
  const text = compose("logs", "--no-color", "mcp-bridge").stdout;
  assert.match(text, /SIGTERM — stopping/);
  assert.match(text, /\[cyfr-spawn\] info: stopped/);
  assert.doesNotMatch(text, /quarantined|did not finish/, `uid ${last.uid} was not retired cleanly`);
});
