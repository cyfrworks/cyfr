// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The cyfr and mcp-bridge images, run by docker compose with the services'
// own settings and a 5 s bridge lease (compose.e2e.yml), driven as an
// operator drives them: vault entries and stdio servers over cyfr's /mcp
// with a session, and a server's tools through the console's catalog entry
// and the in-chain dispatch (`bin/cyfr rpc`), since the wire serves no
// external tool. Each failure of the design's table, from both sides:
//
//   * cyfr crashes between an update's commit and its sync: no backend at
//     the old epoch outlives its lease, and the next boot greets the bridge
//     under a higher generation and runs the new definition;
//   * a sync held back across a bridge restart is refused as stale_boot,
//     and cyfr syncs its live owners again unprompted;
//   * a revoked credential's tool is refused at once: with the control
//     channel up its backends are released, and with it lost they end
//     within the lease;
//   * a dead controller's backends are retired within the lease;
//   * killing the spawner takes the container, and every backend, down with
//     it, compose restarts it and cyfr syncs its owners again; a
//     crash-looping backend ends failed with no uid quarantined.
//
// And leaks: a canary vault entry bound to a backend's env, echoed by the
// backend to stdout and stderr, comes back as [REDACTED] and is in neither
// container's log, no request-log row, no execution payload and nothing
// under cyfr's data volume.
//
// Run: node --test tests/bridge-image/e2e.test.mjs
// CYFR_IMAGE names an image built from Dockerfile and BRIDGE_IMAGE one built
// from Dockerfile.node's mcp-bridge target; without them the test builds
// cyfr:bridge-e2e and cyfr-mcp-bridge:bridge-e2e first.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import * as auth from "../../apps/mcp-bridge/auth.mjs";
import { PROTOCOL_VERSION } from "./controller.mjs";
import { HERE, ROOT_DIR, eventually, exec, processes, run, sleep } from "./harness.mjs";

const PROJECT = "cyfr-bridge-e2e";
const CYFR_IMAGE = process.env.CYFR_IMAGE || "cyfr:bridge-e2e";
const BRIDGE_IMAGE = process.env.BRIDGE_IMAGE || "cyfr-mcp-bridge:bridge-e2e";
const PROBE = "node /probe/probe-backend.mjs";
const OPERATOR = "operator@bridge-e2e.test";

// compose.e2e.yml sets CYFR_MCP_BRIDGE_LEASE_MS to this.
const LEASE_MS = 5_000;
// A backend whose lease is not renewed is gone within the lease, the
// bridge's one-second lease check and the two-second grace its retirement
// gives, with a second for the spawner's scan.
const RETIRED_WITHIN_MS = LEASE_MS + 4_000;
const POOL = { first: 20001, last: 20032 };

const CANARY = `canary-${randomBytes(24).toString("hex")}`;
const RPC_MARK = "e2e-rpc:";

const inPool = (uid) => uid >= POOL.first && uid <= POOL.last;
const elixirJson = (value) => `Jason.decode!(Base.decode64!("${Buffer.from(JSON.stringify(value)).toString("base64")}"))`;

// `eventually` for checks that call cyfr's /mcp, paced under its per-client
// rate limit (120 requests a minute).
async function paced(check, what, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(1_000);
  }
}

/**
 * One compose project running the cyfr and mcp-bridge services. Container
 * ids are kept from the start, so a stopped container can still be read.
 */
class Stack {
  constructor() {
    this.root = randomBytes(32);
    this.projectDir = null;
    this.env = null;
    this.cyfr = null;
    this.bridge = null;
    this.base = null;
    this.network = `${PROJECT}_default`;
  }

  compose(...args) {
    return run(
      "docker",
      [
        "compose",
        "--project-name", PROJECT,
        "--project-directory", this.projectDir,
        "-f", path.join(ROOT_DIR, "docker-compose.yml"),
        "-f", path.join(HERE, "compose.e2e.yml"),
        ...args,
      ],
      { env: this.env },
    );
  }

  async start() {
    if (!process.env.CYFR_IMAGE) run("docker", ["build", "-f", path.join(ROOT_DIR, "Dockerfile"), "-t", CYFR_IMAGE, ROOT_DIR]);
    if (!process.env.BRIDGE_IMAGE) {
      run("docker", ["build", "-f", path.join(ROOT_DIR, "Dockerfile.node"), "--target", "mcp-bridge", "-t", BRIDGE_IMAGE, ROOT_DIR]);
    }
    this.projectDir = mkdtempSync(path.join(tmpdir(), `${PROJECT}-`));
    writeFileSync(
      path.join(this.projectDir, ".env"),
      [
        `CYFR_SECRET_KEY_BASE=${randomBytes(48).toString("base64")}`,
        `CYFR_MCP_BRIDGE_KEY=${this.root.toString("hex")}`,
        `CYFR_PLATFORM_ADMIN_EMAILS=${OPERATOR}`,
        // Nothing here reaches a registry.
        "CYFR_REGISTRY_URL=none",
        "",
      ].join("\n"),
    );
    this.env = {
      ...process.env,
      CYFR_IMAGE,
      BRIDGE_IMAGE,
      PROBE_DIR: path.join(ROOT_DIR, "apps", "mcp-bridge", "test", "fixtures"),
    };

    this.compose("down", "--volumes", "--remove-orphans");
    this.compose("up", "--detach", "--no-build", "cyfr", "mcp-bridge");
    this.cyfr = this.compose("ps", "--quiet", "cyfr").stdout.trim();
    this.bridge = this.compose("ps", "--quiet", "mcp-bridge").stdout.trim();
    assert.ok(this.cyfr && this.bridge, "compose did not start both services");
    await this.cyfrReady();
    await this.bridgeReady();
  }

  // Reads cyfr's published port, which a restart may change, and waits for readiness.
  async cyfrReady() {
    await eventually(
      async () => {
        const port = run("docker", ["port", this.cyfr, "4000"], { allowFailure: true }).stdout.trim().split("\n")[0];
        if (!port) return false;
        this.base = `http://${port}`;
        try {
          return (await fetch(`${this.base}/api/health/ready`)).ok;
        } catch {
          return false;
        }
      },
      "cyfr to be ready",
      180_000,
    );
  }

  async bridgeReady() {
    await eventually(() => exec(this.bridge, "wget -q -O /dev/null http://127.0.0.1:8001/health").status === 0, "the bridge to answer /health", 60_000);
  }

  inspect(container, format) {
    return run("docker", ["inspect", "--format", format, container]).stdout.trim();
  }

  logs(container) {
    const result = run("docker", ["logs", container]);
    return result.stdout + result.stderr;
  }

  stop() {
    if (!this.projectDir) return;
    if (process.env.CI) {
      for (const container of [this.cyfr, this.bridge].filter(Boolean)) process.stdout.write(this.logs(container));
    }
    this.compose("down", "--volumes", "--remove-orphans");
    rmSync(this.projectDir, { recursive: true, force: true });
    this.projectDir = null;
  }
}

const stack = new Stack();
let session;

// Evaluates Elixir in the running release; the snippet prints its answer
// as one JSON line after RPC_MARK.
function rpc(code) {
  const result = run("docker", ["exec", "-u", "app", stack.cyfr, "/app/bin/cyfr", "rpc", code], { allowFailure: true });
  const line = result.stdout.split("\n").find((l) => l.startsWith(RPC_MARK));
  assert.ok(line, `rpc answered nothing:\n${result.stdout}\n${result.stderr}`);
  return JSON.parse(line.slice(RPC_MARK.length));
}

// A person admitted at the door as a platform admin, their athanor, and a
// session token — what the sign-in paths do once the identity provider has
// answered (`Sanctum.Auth.DeviceFlow`).
function signIn() {
  return rpc(`
    info = %{id: Sanctum.Auth.Identity.builtin_key(:github, "bridge-e2e-operator"), provider: "github",
             email: ${JSON.stringify(OPERATOR)}, verified: true, name: "Bridge E2E Operator"}
    {:ok, :admin} = Sanctum.Door.admit_identity(info.id, info)
    {:ok, user} = Sanctum.SignIn.admitted(info, :admin)
    ctx = Sanctum.Context.build(user_id: user.id, email: info.email, provider: "github", athanor_id: nil,
                                permissions: Sanctum.Context.person_permissions())
    {:ok, ctx} = Sanctum.Tenancy.resolve_status(ctx, force: true)
    {:ok, session} = Sanctum.Session.create(ctx)
    IO.puts(${JSON.stringify(RPC_MARK)} <> Jason.encode!(%{token: session.token, athanor: ctx.athanor_id}))
  `);
}

/** Posts one tools/call to cyfr's /mcp with the session; answers the parsed result or throws its refusal. */
async function tool(name, args) {
  const body = JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: {
      name,
      arguments: args,
      _meta: {
        "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
        "io.modelcontextprotocol/clientCapabilities": {},
      },
    },
  });
  const res = await fetch(`${stack.base}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      "mcp-protocol-version": PROTOCOL_VERSION,
      "mcp-method": "tools/call",
      "mcp-name": name,
      authorization: `Bearer ${session.token}`,
    },
    body,
  });
  const answer = await res.json();
  const result = answer.result;
  if (res.status !== 200 || !result || result.isError) throw new Error(`${name} ${JSON.stringify(args)}: ${res.status} ${JSON.stringify(answer)}`);
  return JSON.parse(result.content[0].text);
}

/**
 * Calls a stdio server's tool as `plane` does: `console` through the
 * catalog's external entry (`Cyfr.Ops.Catalog.call_external/4`, which logs
 * the call), `in_chain` through the dispatch a chain's call reaches past its
 * authority (`Emissary.MCP.ExternalProvider.try_handle/5`, which keeps it as
 * a tool_call execution with its payloads). Answers `{ok: result}` or
 * `{error: text}`.
 */
function callTool(name, args = {}, plane = "console") {
  return rpc(`
    args = ${elixirJson({ token: session.token, name, arguments: args, plane })}
    {:ok, ctx} = Sanctum.Caller.establish(args["token"])

    reply =
      case args["plane"] do
        "console" -> Cyfr.Ops.Catalog.call_external(args["name"], ctx, args["arguments"])
        "in_chain" -> Emissary.MCP.ExternalProvider.try_handle(args["name"], ctx, args["arguments"], :in_chain)
      end

    answer =
      case reply do
        {:ok, result} -> %{ok: result}
        {:error, reason} when is_binary(reason) -> %{error: reason}
        {:error, reason} -> %{error: inspect(reason)}
      end

    IO.puts(${JSON.stringify(RPC_MARK)} <> Jason.encode!(answer))
  `);
}

/** A probe tool's JSON answer; fails on a refusal. */
function probe(server, toolName, args = {}, plane = "console") {
  const answer = callTool(`${server}:probe__${toolName}`, args, plane);
  assert.ok(answer.ok, `${server}:probe__${toolName}: ${JSON.stringify(answer)}`);
  return JSON.parse(answer.ok.content[0].text);
}

async function stdioServer(name, env) {
  const created = await tool("mcp_servers", {
    action: "create",
    name,
    config: { transport: "stdio", console: true, backends: [{ name: "probe", command: PROBE, env }] },
  });
  assert.equal(created.status, "ready", JSON.stringify(created));
  return created;
}

const poolProcesses = () => processes(stack.bridge).filter((p) => p.uids.some(inPool));
const underUid = (uid) => processes(stack.bridge).filter((p) => p.uids.includes(uid));

// The bridge's log from its latest lifetime on: everything after the last
// line that names a boot id.
function currentLifetimeLog() {
  const text = stack.logs(stack.bridge);
  const lines = text.split("\n");
  const start = lines.findLastIndex((l) => /\/control and \/mcp on :8001 \(boot bb_/.test(l));
  return lines.slice(Math.max(start, 0)).join("\n");
}

function lastHello(text = stack.logs(stack.bridge)) {
  const hellos = [...text.matchAll(/hello from (\S+) at generation (\d+)/g)];
  assert.ok(hellos.length, "the bridge was never greeted");
  const [, cyfrBoot, generation] = hellos.at(-1);
  return { cyfrBoot, generation: Number(generation) };
}

// The bridge's boot id, as cyfr reaches it on the compose network.
function bridgeBoot() {
  const result = exec(stack.cyfr, "curl -s -D - -o /dev/null http://mcp-bridge:8001/health");
  const boot = result.stdout.match(/^cyfr-bridge-boot:\s*(\S+)/im)?.[1];
  assert.ok(boot, `no boot id from the bridge: ${result.stdout}${result.stderr}`);
  return boot;
}

// POSTs a signed control message to the bridge from cyfr's container.
function postControl(header, body) {
  const result = spawnSync(
    "docker",
    [
      "exec", "-i", stack.cyfr,
      "curl", "-s", "-D", "-", "-H", "content-type: application/json", "-H", `cyfr-bridge-auth: ${header}`,
      "--data-binary", "@-", "http://mcp-bridge:8001/control",
    ],
    { input: body, encoding: "utf8" },
  );
  const [head, ...rest] = result.stdout.split(/\r?\n\r?\n/);
  return {
    status: Number(head.match(/^HTTP\/\S+ (\d+)/)?.[1]),
    boot: head.match(/^cyfr-bridge-boot:\s*(\S+)/im)?.[1],
    body: JSON.parse(rest.join("\n\n")),
  };
}

async function retiredWithin(uid, since, what) {
  await eventually(() => underUid(uid).length === 0, `${what}: no process of uid ${uid}`, RETIRED_WITHIN_MS * 2);
  const elapsed = Date.now() - since;
  assert.ok(elapsed <= RETIRED_WITHIN_MS, `${what}: uid ${uid} was retired after ${elapsed} ms`);
  return elapsed;
}

function disconnectBridge() {
  run("docker", ["network", "disconnect", stack.network, stack.bridge]);
}

function reconnectBridge() {
  run("docker", ["network", "connect", "--alias", "mcp-bridge", stack.network, stack.bridge]);
}

before(async () => {
  await stack.start();
  session = signIn();
  assert.match(session.athanor, /^ath_/);
});

after(() => stack.stop());

let leak;

test("a canary bound to a backend's env reaches the backend and comes back only as [REDACTED]", async () => {
  await tool("vault", { action: "create", name: "probe-canary", kind: "api_key", fields: { value: CANARY } });
  leak = await stdioServer("leak", { PROBE_SECRET: "vault:probe-canary" });

  const who = probe("leak", "whoami");
  assert.ok(inPool(who.uid), `the backend runs as uid ${who.uid}`);
  const environ = exec(stack.bridge, `tr '\\0' '\\n' < /proc/${who.pid}/environ`, { user: String(who.uid) }).stdout;
  assert.ok(environ.includes(`PROBE_SECRET=${CANARY}`), "the backend does not hold the canary, so its absence elsewhere proves nothing");

  for (const plane of ["console", "in_chain"]) {
    assert.deepEqual(probe("leak", "echo_env", { name: "PROBE_SECRET", stderr: true }, plane), { value: "[REDACTED]" }, plane);
  }

  const described = await tool("mcp_servers", { action: "get", name: "leak" });
  const [backend] = described.backends;
  assert.equal(backend.status, "ready");
  assert.ok(backend.stderr_tail.includes("PROBE_SECRET=[REDACTED]"), `stderr tail: ${JSON.stringify(backend.stderr_tail)}`);
});

test("a sync held back across a bridge restart is refused as stale_boot, and cyfr syncs its live owners again", async (t) => {
  probe("leak", "whoami");
  const { epoch } = await tool("mcp_servers", { action: "get", name: "leak" });
  const { cyfrBoot, generation } = lastHello();
  const oldBoot = bridgeBoot();

  // A sync for the live owner, signed and sealed as the controller signs
  // them for this lifetime, above any sequence number cyfr has sent.
  const owner = { athanor: session.athanor, server: leak.id, generation, epoch };
  const sealed = auth.seal(auth.sealKey(stack.root), owner, oldBoot, Buffer.from(JSON.stringify({ probe: { PROBE_SECRET: "held-back-value" } })), randomBytes(12));
  const body = JSON.stringify({
    type: "sync",
    owner: { athanor: owner.athanor, server: owner.server },
    e: epoch,
    lease_ms: LEASE_MS,
    idle_ms: 900_000,
    backends: [{ name: "probe", command: PROBE, env_names: ["PROBE_SECRET"] }],
    sealed,
  });
  const signedAt = Date.now();
  const header = auth.controlHeader(auth.controlKey(stack.root), { generation, seq: 2 ** 52, cyfr_boot: cyfrBoot, boot: oldBoot, ts: signedAt }, body);

  run("docker", ["restart", stack.bridge]);
  await stack.bridgeReady();

  const held = postControl(header, body);
  t.diagnostic(`held-back sync for boot ${oldBoot}: ${held.status} ${JSON.stringify(held.body)} from boot ${held.boot}`);
  assert.deepEqual([held.status, held.body], [409, { error: "stale_boot" }]);
  assert.notEqual(held.boot, oldBoot);
  assert.ok(Date.now() - signedAt < 30_000, "the sync fell outside the timestamp window, so its refusal proves nothing");

  // Unprompted: cyfr's next renewal meets the new lifetime and greets it.
  await eventually(
    () => new RegExp(`\\[owner ${session.athanor}/${leak.id} probe\\] ready`).test(currentLifetimeLog()),
    "cyfr to sync the live owner into the restarted bridge",
    30_000,
  );
  assert.equal(lastHello(currentLifetimeLog()).cyfrBoot, cyfrBoot);
  assert.ok(poolProcesses().length >= 1, "no backend runs in the restarted bridge");
  assert.ok(probe("leak", "whoami").pid > 0);
});

test("a crash-looping backend ends failed, and no uid it held is quarantined", async (t) => {
  await tool("mcp_servers", {
    action: "create",
    name: "crashloop",
    config: { transport: "stdio", backends: [{ name: "boom", command: "echo crashing >&2; exit 3", env: {} }] },
  });
  const { id } = await tool("mcp_servers", { action: "get", name: "crashloop" });

  const failed = await paced(
    async () => {
      const [backend] = (await tool("mcp_servers", { action: "get", name: "crashloop" })).backends || [];
      return backend?.status === "failed" ? backend : null;
    },
    "the crash-looping backend to be marked failed",
    60_000,
  );
  t.diagnostic(`crash-looping backend: ${JSON.stringify(failed)}`);
  assert.equal(failed.restarts, 4);
  assert.match(failed.error, /exited code=3/);

  const log = currentLifetimeLog();
  assert.match(log, new RegExp(`\\[owner ${session.athanor}/${id} boom\\] failed after 5 crashes`));
  assert.doesNotMatch(log, /quarantined|did not finish/);
  const live = probe("leak", "whoami").uid;
  assert.deepEqual([...new Set(poolProcesses().flatMap((p) => p.uids.filter(inPool)))], [live], "a uid outside the live backend's still runs");

  await tool("mcp_servers", { action: "delete", name: "crashloop" });
});

test("with the control channel up, a revoked credential's tool is refused at once and its backends are released rather than left to lapse", async (t) => {
  const { entry } = await tool("vault", { action: "create", name: "revocable-up", kind: "api_key", fields: { value: `revocable-up-${randomBytes(16).toString("hex")}` } });
  const revocable = await stdioServer("revocable-up", { PROBE_SECRET: "vault:revocable-up" });
  const who = probe("revocable-up", "whoami");

  const revoked = Date.now();
  await tool("vault", { action: "revoke", id: entry.id });

  const asked = Date.now();
  const refused = callTool("revocable-up:probe__whoami");
  const answeredIn = Date.now() - asked;
  assert.ok(refused.error, `the tool answered after its credential was revoked: ${JSON.stringify(refused)}`);
  assert.ok(answeredIn < LEASE_MS, `the refusal took ${answeredIn} ms`);

  const retired = await retiredWithin(who.uid, revoked, "the revoked owner");
  t.diagnostic(`refused in ${answeredIn} ms: ${refused.error}; uid ${who.uid} retired ${retired} ms after the revoke`);
  // Released by cyfr's message: the bridge never saw the lease lapse.
  assert.doesNotMatch(currentLifetimeLog(), new RegExp(`\\[owner ${session.athanor}/${revocable.id}\\] lease lapsed`));
  assert.ok(probe("leak", "whoami").pid > 0, "the revoke disturbed another server");
});

test("with the control channel lost, a revoked credential's tool is refused at once and its backends end within the lease", async (t) => {
  const { entry } = await tool("vault", { action: "create", name: "revocable", kind: "api_key", fields: { value: `revocable-${randomBytes(16).toString("hex")}` } });
  const revocable = await stdioServer("revocable", { PROBE_SECRET: "vault:revocable" });
  const who = probe("revocable", "whoami");

  disconnectBridge();
  try {
    const lost = Date.now();
    await tool("vault", { action: "revoke", id: entry.id });

    const asked = Date.now();
    const refused = callTool("revocable:probe__whoami");
    const answeredIn = Date.now() - asked;
    assert.ok(refused.error, `the tool answered after its credential was revoked: ${JSON.stringify(refused)}`);
    assert.ok(answeredIn < LEASE_MS, `the refusal took ${answeredIn} ms`);

    const retired = await retiredWithin(who.uid, lost, "the revoked owner");
    t.diagnostic(`refused in ${answeredIn} ms: ${refused.error}; uid ${who.uid} retired ${retired} ms after the channel was lost`);
    assert.match(stack.logs(stack.bridge), new RegExp(`\\[owner ${session.athanor}/${revocable.id}\\] lease lapsed`));
  } finally {
    reconnectBridge();
  }
  await eventually(() => callTool("leak:probe__whoami").ok, "cyfr to reach the bridge again", 30_000);
});

test("a crash of cyfr between an update's commit and its sync leaves no backend at the old epoch", async (t) => {
  await stdioServer("updatable", { LOG_LEVEL: "info" });
  const old = probe("updatable", "whoami");
  const { epoch } = await tool("mcp_servers", { action: "get", name: "updatable" });
  const { generation } = lastHello();

  // Neither the release nor the sync the update sends reaches the bridge.
  disconnectBridge();
  let committed;
  try {
    const updated = await tool("mcp_servers", {
      action: "update",
      name: "updatable",
      epoch,
      config: { transport: "stdio", console: true, backends: [{ name: "probe", command: PROBE, env: { LOG_LEVEL: "debug" } }] },
    });
    committed = Date.now();
    assert.equal(updated.epoch, epoch + 1);
    run("docker", ["kill", "--signal", "KILL", stack.cyfr]);
  } finally {
    reconnectBridge();
  }

  const retired = await retiredWithin(old.uid, committed, "the old epoch's backend");
  t.diagnostic(`epoch ${epoch} backend (uid ${old.uid}) retired ${retired} ms after epoch ${epoch + 1} committed`);

  run("docker", ["start", stack.cyfr]);
  await stack.cyfrReady();
  await eventually(() => lastHello().generation > generation, "the new boot to greet the bridge under a higher generation", 30_000);
  t.diagnostic(`generation ${generation} -> ${lastHello().generation}`);
  assert.equal(underUid(old.uid).filter((p) => p.pid === old.pid).length, 0);

  const now = probe("updatable", "whoami");
  assert.notEqual(now.home, old.home);
  assert.deepEqual(probe("updatable", "echo_env", { name: "LOG_LEVEL" }), { value: "debug" });
  assert.equal((await tool("mcp_servers", { action: "get", name: "updatable" })).epoch, epoch + 1);
});

test("killing the spawner takes every backend down with the container, compose restarts it, and cyfr syncs again", async (t) => {
  const before = probe("updatable", "whoami");
  const restarts = Number(stack.inspect(stack.bridge, "{{.RestartCount}}"));
  const spawner = processes(stack.bridge).find((p) => p.cmdline.startsWith("cyfr-spawn serve"));
  assert.ok(spawner, "no cyfr-spawn serve process");

  run("docker", ["exec", stack.bridge, "kill", "-KILL", String(spawner.pid)]);

  await eventually(() => Number(stack.inspect(stack.bridge, "{{.RestartCount}}")) === restarts + 1, "compose to restart the bridge", 60_000);
  await stack.bridgeReady();

  const after = await eventually(() => {
    const answer = callTool("updatable:probe__whoami");
    // Until cyfr has synced the owner into the restarted bridge the call is
    // answered, but with the bridge's own sentence about a backend it does
    // not hold yet rather than the probe's JSON: that is the state this
    // waits out, so it is not an answer, not a parse error.
    if (!answer.ok) return null;
    try {
      return JSON.parse(answer.ok.content[0].text);
    } catch {
      return null;
    }
  }, "cyfr to sync the owner into the restarted bridge", 30_000);
  assert.notEqual(after.home, before.home);
  t.diagnostic(`restart ${restarts} -> ${restarts + 1}; home ${before.home} -> ${after.home}`);

  for (const p of poolProcesses()) {
    const uid = p.uids.find(inPool);
    const home = exec(stack.bridge, `tr '\\0' '\\n' < /proc/${p.pid}/environ | sed -n 's/^HOME=//p'`, { user: String(uid) }).stdout.trim();
    assert.notEqual(home, before.home, `process ${p.pid} of the killed spawner's lifetime survived`);
  }
});

test("the canary is in no request-log row, no execution payload and nothing under cyfr's data volume", () => {
  const stored = rpc(`
    rows = fn sql ->
      result = Arca.Repo.query!(sql)
      Enum.map(result.rows, fn row -> result.columns |> Enum.zip(row) |> Map.new() end)
    end

    args = ${elixirJson({ token: session.token })}
    {:ok, ctx} = Sanctum.Caller.establish(args["token"])

    payloads =
      for row <- rows.("SELECT * FROM execution_payloads") do
        {:ok, _row, bytes} = Arca.ExecutionPayloads.get(ctx, row["execution_id"], row["kind"])
        Map.put(row, "bytes_read", bytes)
      end

    IO.puts(${JSON.stringify(RPC_MARK)} <> Jason.encode!(%{
      request_log: rows.("SELECT * FROM mcp_logs"),
      payloads: payloads,
      executions: rows.("SELECT id, kind, reference FROM executions")
    }))
  `);

  const logged = JSON.stringify(stored.request_log);
  assert.ok(stored.request_log.some((r) => r.tool === "leak:probe__echo_env" && r.output.includes("[REDACTED]")), "the console call left no request-log row");
  assert.ok(!logged.includes(CANARY), "the canary is in the request log");

  const execution = stored.executions.find((e) => e.kind === "tool_call" && e.reference === "leak:probe__echo_env");
  assert.ok(execution, "the in-chain call left no execution");
  const result = stored.payloads.find((p) => p.execution_id === execution.id && p.kind === "result");
  assert.ok(result?.bytes_read.includes("[REDACTED]"), `the call's result payload: ${JSON.stringify(result)}`);
  assert.ok(!JSON.stringify(stored.payloads).includes(CANARY), "the canary is in an execution payload");

  const grep = exec(stack.cyfr, `grep -rlF '${CANARY}' /app/data`);
  assert.equal(grep.status, 1, `the canary is under /app/data: ${grep.stdout}${grep.stderr}`);
});

test("a dead controller's backends are retired within the lease", async (t) => {
  const who = probe("updatable", "whoami");
  const { id, epoch } = await tool("mcp_servers", { action: "get", name: "updatable" });

  run("docker", ["kill", "--signal", "KILL", stack.cyfr]);
  const died = Date.now();

  const retired = await retiredWithin(who.uid, died, "the dead controller's backend");
  t.diagnostic(`uid ${who.uid} retired ${retired} ms after cyfr was killed`);
  assert.equal(stack.inspect(stack.cyfr, "{{.State.Status}}"), "exited");
  assert.match(currentLifetimeLog(), new RegExp(`\\[owner ${session.athanor}/${id}\\] lease lapsed at g=\\d+ e=${epoch}`));
});

test("the canary is in neither container's log", () => {
  const cyfrLog = stack.logs(stack.cyfr);
  const bridgeLog = stack.logs(stack.bridge);
  assert.match(bridgeLog, new RegExp(`\\[owner ${session.athanor}/${leak.id} probe\\] ready`), "the bridge's log does not cover the canary's owner");
  assert.ok(!cyfrLog.includes(CANARY), "the canary is in cyfr's log");
  assert.ok(!bridgeLog.includes(CANARY), "the canary is in the bridge's log");
});
