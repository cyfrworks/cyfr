// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The spawner client speaks the protocol cyfr-spawn validates: its frames
// and requests match the shared vectors, it understands every reply, a
// backend's stdio flows through a relay that presents the spawn's token,
// and exit, refusal, release and loss of the channel settle as documented.

import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { chmod, mkdtemp, mkdir, rm } from "node:fs/promises";
import { readFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  FrameDecoder,
  MAX_FRAME_PAYLOAD,
  STREAM_ATTACH,
  STREAM_STDERR,
  STREAM_STDIN,
  STREAM_STDOUT,
  SpawnerClient,
  encodeFrame,
} from "../spawn-client.mjs";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const V = JSON.parse(readFileSync(path.join(DIR, "..", "..", "..", "tests", "fixtures", "spawn_protocol.json"), "utf8"));

const SPAWN_ID = "00112233445566778899aabbccddeeff";

// A fake spawner peer: the test's end of the channel, reading requests as
// JSON lines and writing replies.
class Peer {
  requests = [];
  #waiters = [];
  #buffer = "";

  constructor(socket) {
    this.socket = socket;
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      this.#buffer += chunk;
      let i;
      while ((i = this.#buffer.indexOf("\n")) >= 0) {
        const message = JSON.parse(this.#buffer.slice(0, i));
        this.#buffer = this.#buffer.slice(i + 1);
        this.requests.push(message);
        this.#waiters.shift()?.(message);
      }
    });
  }

  next() {
    return new Promise((resolve) => this.#waiters.push(resolve));
  }

  reply(message) {
    this.socket.write(JSON.stringify(message) + "\n");
  }
}

let dir;
let channelServer;
let client;
let peer;

beforeEach(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "spawn-client-"));
  channelServer = net.createServer();
  await new Promise((resolve) => channelServer.listen(path.join(dir, "channel.sock"), resolve));
  const accepted = once(channelServer, "connection");
  const channel = net.connect(path.join(dir, "channel.sock"));
  const [socket] = await accepted;
  peer = new Peer(socket);
  client = new SpawnerClient({ channel, attachDir: path.join(dir, "attach"), pool: "backends" });
  await client.listen();
});

afterEach(async () => {
  await client.close();
  peer.socket.destroy();
  await new Promise((resolve) => channelServer.close(resolve));
  await rm(dir, { recursive: true, force: true });
});

// Connects as a relay would and presents a token.
async function attachRelay(token) {
  const conn = net.connect(client.attachPath);
  await once(conn, "connect");
  conn.write(encodeFrame(STREAM_ATTACH, Buffer.from(token, "latin1")));
  const decoder = new FrameDecoder();
  const frames = [];
  const waiters = [];
  conn.on("data", (chunk) => {
    for (const frame of decoder.push(chunk)) {
      frames.push(frame);
      waiters.shift()?.(frame);
    }
  });
  let read = 0;
  return {
    conn,
    async frame() {
      while (frames.length <= read) await new Promise((r) => waiters.push(r));
      return frames[read++];
    },
  };
}

async function spawned(argv = ["node", "probe.mjs"], env = {}) {
  const proc = client.spawn({ argv, env });
  const request = await peer.next();
  peer.reply({ v: 1, type: "spawned", id: request.id, spawn_id: SPAWN_ID, uid: 20007, pid: 41 });
  await once(proc, "spawn");
  return { proc, request };
}

test("frames encode and decode as the shared vectors say", () => {
  for (const f of V.frames) {
    const payload = Buffer.from(f.payload_hex, "hex");
    const encoded = encodeFrame(f.stream, payload);
    assert.equal(encoded.toString("hex"), f.encoded_hex);

    // Byte at a time, so a frame split across reads still decodes.
    const decoder = new FrameDecoder();
    const out = [];
    for (const byte of encoded) out.push(...decoder.push(Buffer.from([byte])));
    assert.equal(out.length, 1);
    assert.equal(out[0][0], f.stream);
    assert.equal(Buffer.from(out[0][1]).toString("hex"), f.payload_hex);
  }
  assert.throws(() => encodeFrame(STREAM_STDIN, Buffer.alloc(MAX_FRAME_PAYLOAD + 1)));
  assert.throws(() => new FrameDecoder().push(Buffer.from("0700000000", "hex")));
  assert.throws(() => new FrameDecoder().push(Buffer.from("0100010001", "hex")));
});

test("a spawn request has the shape the spawner validates", async () => {
  const argv = ["/bin/sh", "-c", "npx -y @modelcontextprotocol/server-everything"];
  const env = { GITHUB_TOKEN: "ghp_example", NODE_ENV: "production" };
  client.spawn({ argv, env });
  const request = await peer.next();

  const vector = V.valid_requests[0];
  assert.deepEqual(Object.keys(request).sort(), Object.keys(vector).sort());
  assert.deepEqual(Object.keys(request.attach).sort(), Object.keys(vector.attach).sort());
  assert.equal(request.v, 1);
  assert.equal(request.type, "spawn");
  assert.equal(request.pool, "backends");
  assert.deepEqual(request.argv, argv);
  assert.deepEqual(request.env, env);
  assert.equal(request.attach.path, path.join(dir, "attach", "attach.sock"));
  assert.match(request.attach.token, /^[0-9a-f]{64}$/);
  assert.match(request.id, /^[A-Za-z0-9._:-]{1,64}$/);
});

test("stdio flows through the relay; exit, signal and release follow the protocol", async () => {
  const { proc, request } = await spawned();
  assert.equal(proc.uid, 20007);
  assert.equal(proc.pid, 41);

  // Written before the relay attaches, delivered once it does.
  proc.stdin.write("before\n");
  const relay = await attachRelay(request.attach.token);
  const [s1, p1] = await relay.frame();
  assert.equal(s1, STREAM_STDIN);
  assert.equal(p1.toString(), "before\n");

  proc.stdin.write("after\n");
  const [s2, p2] = await relay.frame();
  assert.equal(s2, STREAM_STDIN);
  assert.equal(p2.toString(), "after\n");

  const stdout = [];
  proc.stdout.on("data", (c) => stdout.push(c.toString()));
  const stderr = [];
  proc.stderr.on("data", (c) => stderr.push(c.toString()));
  const streamErrors = [];
  proc.stdout.on("error", (err) => streamErrors.push(err));
  // A frame after a stream's end marker, in the same read, is dropped.
  relay.conn.write(
    Buffer.concat([
      encodeFrame(STREAM_STDOUT, Buffer.from("hello\n")),
      encodeFrame(STREAM_STDERR, Buffer.from("warn\n")),
      encodeFrame(STREAM_STDOUT),
      encodeFrame(STREAM_STDOUT, Buffer.from("late\n")),
    ]),
  );
  await once(proc.stdout, "end");
  assert.deepEqual(stdout, ["hello\n"]);
  assert.deepEqual(streamErrors, []);

  assert.equal(proc.signal("SIGTERM"), true);
  assert.deepEqual(await peer.next(), { v: 1, type: "signal", spawn_id: SPAWN_ID, sig: "SIGTERM" });

  proc.stdin.end();
  const [s3, p3] = await relay.frame();
  assert.equal(s3, STREAM_STDIN);
  assert.equal(p3.length, 0, "ending stdin did not send the end marker");

  const exited = once(proc, "exit");
  peer.reply({ v: 1, type: "exited", spawn_id: SPAWN_ID, code: 3, signal: null });
  assert.deepEqual(await exited, [3, null]);
  assert.equal(proc.signal("SIGTERM"), false, "an exited leader was signalled");

  const released = proc.release(500);
  assert.deepEqual(await peer.next(), { v: 1, type: "release", spawn_id: SPAWN_ID, grace_ms: 500 });
  peer.reply({ v: 1, type: "released", spawn_id: SPAWN_ID });
  await released;
  assert.deepEqual(stderr, ["warn\n"]);
  relay.conn.destroy();
});

test("a release asked for before the spawn is acknowledged is sent once it is", async () => {
  const proc = client.spawn({ argv: ["x"], env: {} });
  const request = await peer.next();
  const released = proc.release(0);
  peer.reply({ v: 1, type: "spawned", id: request.id, spawn_id: SPAWN_ID, uid: 20001, pid: 7 });
  assert.deepEqual(await peer.next(), { v: 1, type: "release", spawn_id: SPAWN_ID, grace_ms: 0 });
  peer.reply({ v: 1, type: "error", spawn_id: SPAWN_ID, code: "unknown_spawn" });
  await released;
});

test("a refused spawn emits its code, fails stdin and needs no release", async () => {
  const proc = client.spawn({ argv: ["x"], env: {} });
  const request = await peer.next();
  const failed = once(proc, "error");
  peer.reply({ v: 1, type: "error", id: request.id, code: "capacity" });
  const [err] = await failed;
  assert.equal(err.code, "capacity");

  const written = new Promise((resolve) => proc.stdin.write("x\n", resolve));
  proc.stdin.on("error", () => {});
  assert.match(String(await written), /stdin unavailable/);
  await proc.release(1000);
  assert.equal(peer.requests.filter((r) => r.type === "release").length, 0);
});

test("a relay presenting an unknown token is disconnected, and a token works once", async () => {
  const stranger = await attachRelay("f".repeat(64));
  await once(stranger.conn, "close");

  const { request } = await spawned();
  const first = await attachRelay(request.attach.token);
  const second = await attachRelay(request.attach.token);
  await once(second.conn, "close");
  assert.equal(first.conn.destroyed, false, "the first relay was disconnected by the second");
  first.conn.destroy();
});

test("the pool reply and an exit by signal are understood", async () => {
  const stats = client.pool();
  const request = await peer.next();
  assert.deepEqual(request, { v: 1, type: "pool", id: request.id, pool: "backends" });
  const vector = V.replies.find((r) => r.type === "pool");
  peer.reply({ ...vector, id: request.id });
  assert.deepEqual(await stats, { size: 32, free: 30, quarantined: 1 });

  const { proc } = await spawned();
  const exited = once(proc, "exit");
  peer.reply(V.replies.find((r) => r.type === "exited" && r.signal));
  assert.deepEqual(await exited, [null, "SIGKILL"]);
});

test("losing the channel is reported and settles what was pending", async () => {
  const { proc } = await spawned();
  const pending = client.spawn({ argv: ["x"], env: {} });
  await peer.next();
  const failed = once(pending, "error");
  const lost = once(client, "lost");
  peer.socket.destroy();
  await lost;
  assert.equal((await failed)[0].code, "channel_lost");
  await proc.release(0);

  const late = client.spawn({ argv: ["x"], env: {} });
  assert.equal((await once(late, "error"))[0].code, "channel_lost");
});

test("the attach directory must be private to this user", async () => {
  const open = path.join(dir, "open");
  await mkdir(open, { mode: 0o755 });
  await chmod(open, 0o755);
  const other = new SpawnerClient({ channel: new net.Socket(), attachDir: open, pool: "backends" });
  await assert.rejects(other.listen(), /mode 0700/);
});
