#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""A build cannot take more memory than its bound, run as docker-compose.yml's builder service.

cyfr-locus bounds every spawn by its place's kind, a build at a build's
bound (Prima.LocusPool's, 1 GiB), with a cgroup of its own
(apps/locus/keeper/internal/cgroup): the kernel never lets the spawn's whole
process tree, the tmpfs pages of its home and the kernel memory charged to
it pass the bound, kills every process of the spawn when they cannot stay
under it, and cyfr-locus reports that end as `memory` `cap`. It can do
so only where the service mounts the container's cgroup writable
(`security_opt: writable-cgroups=true`); anywhere else it can make no
role's group and refuses its own boot, so no build runs at all
(tests/builder-image/isolation.py proves that refusal).

`keeper` drives a second cyfr-locus inside the running service, over its
own uids, with a client that speaks the keeper's protocol
(tests/fixtures/keeper_protocol.json) and places every spawn before it
sends it:

- a real build of an athanor whose id holds an `@`, a tincture's `npm run
  build` holding what it built from, is placed `build` of that athanor;
  while it runs, once the keeper has read its group, every measure of its
  place answers a reading above zero naming `build` and exactly that
  athanor, and the reading taken after
  the build holds its memory counts it; after its `release`, a measure sent
  with it is still answered with a reading before `released`, and one after
  `released` is `unmeasured`;
- a spawn naming its own memory bound or CPU quota, which the keeper sets
  by its kind, is refused as a bad request and nothing is spawned; the
  client drops its place;
- every other place is answered `placed` with a build's bound, and its
  spawn's group is bounded at exactly that;
- beside a sibling spawn that holds 64 MiB under its bound and completes,
  three hostile spawns end at theirs, reported `memory` `cap` with
  SIGKILL: one process allocating without end, with a daemon in a session
  of its own that ignores SIGTERM; processes of 16 MiB, none of them
  large, twice the bound together; and one filling its home, which no
  process holds;
- no group's peak, as the kernel accounts it, passed its bound; no process
  of their uids, no home and no group is left; the release and the
  container were not touched;
- where the service gives cyfr-locus no writable cgroup, cyfr-locus
  refuses its boot, the builds service never answers, and this suite fails
  with the service's log, which says what could not be made.

`room` drives a second cyfr-locus as `keeper` does, its pool's work sized
at ROOM_WORK, which holds one build's allowance and not two, to show the
keeper's one admission (apps/locus/keeper/internal/admission) on the
image:

- a holder build of an athanor holds more than a build's allowance, and
  once the keeper's reading of its place counts it, two builds are placed,
  one of the holder's athanor and one of another;
- while the holder holds the room neither is placed, and each is refused
  `no_memory` between the room's wait and two seconds after it, its `held`
  whole: what a build needs, its allowance; what is free, the work less
  the holder's charge; and the holder, charged its reading above its
  allowance, among the asking athanor's own places with its kind and
  subject, or, for the other athanor, only in the sum of everyone else's;
- once the holder is released, the first of them placed again is placed
  at once with a build's bound.

The build cases run the same hostile work through the builder's own build
path, each beside a sibling build: `javascript` (a build script allocating
without end), `rust` (a build.rs doing so), `tree` (100 processes of
64 MiB) and `home` (files until the home is full). Each must be answered
with the build wire's `memory` class (`Prima.BuilderProtocol`), leave no
process of its uid and no home, and leave its sibling, the release and the
container as they were. cyfr-locus bounds every build the builder places
at a build's bound; a build ended by the container's own limit or the
deadline instead fails its case here.

Every case prints what it measured: the peak of the hostile tree (the
resident sets of its uid's processes, sampled from /proc about ten times a
second, and its group's memory.peak where it has one), what ended it and
when, what it left, the sibling's end, and the container's memory before,
at its peak and after, its OOM counters and whether the release or the
container was started again. `--measure` prints without judging a build's
end, to see what a build does at its bound. The hostile work is bounded
by the container's own memory limit, which the suite reads from the
container and refuses to run without.

Usage: tests/builder-image/memory.py IMAGE [--measure] [keeper|room|javascript|rust|tree|home]...
"""

import copy
import json
import os
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stack import (  # noqa: E402
    POOL_FIRST, POOL_LAST, RELEASE, ROLE, ROOT, Stack, expect, run, tincture,
)
# stack puts tests/, which holds the shared plumbing, on the path.
import imagesuite  # noqa: E402

MIB = 1 << 20
# A build nothing else ends is ended by this deadline.
DEADLINE_MS = 60_000
# The second cyfr-locus's uids, one for each spawn of its scenario that
# runs: the last of the image's pool, which the service's own keeper is
# started without, as a pool of their own the builds role names.
PROBE_FIRST, PROBE_LAST = POOL_LAST - 4, POOL_LAST
PROBE_POOL = "probe"
# The builds role's group in the pool's work, which holds every build's
# group, and the group above it, rest, whose memory.max bounds the hostile
# work beside every other role's but the floor's.
ROLE_GROUP = imagesuite.work_group(ROLE)
BOUND_GROUP = imagesuite.bound_group(ROLE)
# The bound the keeper sets on every build (Prima.LocusPool), which the
# keeper cases' hostile spawns pass.
BOUND = imagesuite.BUILD_CAP_BYTES
# The tree case's processes, each holding 16 MiB: twice the bound together.
TREE_EACH = 16 * MIB
TREE_PROCESSES = 2 * BOUND // TREE_EACH
# The measured build: a tincture's `npm run build`, the image's npm running
# node, which builds dist/index.html from HELD bytes it touches once and keeps
# until it is released, so its use is steady rather than a compiler's phases
# rising and falling; it prints HOLDING once it holds them. The client
# measures it every MEASURE poll_ms until a reading the keeper took margin_ms
# after the client saw HOLDING, and releases it with no grace, as the builder
# ends a build. Its athanor holds an `@`, as an athanor's id may on every
# Locus wire (1 to 256 printable ASCII characters, no space), and every
# reading names exactly it.
ATHANOR = "family@example"
HELD = 32 * MIB
HOLDING = "holding what it built from"
MEASURED_BUILD = """set -eu
export npm_config_cache="$HOME/npm" npm_config_update_notifier=false
mkdir -p "$HOME/src"
cd "$HOME/src"
cat > package.json <<'EOF'
{"name": "measured", "private": true, "version": "0.0.1", "scripts": {"build": "node build.mjs"}}
EOF
cat > build.mjs <<'EOF'
import fs from "node:fs";
const held = Buffer.alloc(%d, 1);
fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/index.html", "measured " + held[5]);
console.log("%s");
setInterval(() => held[5], 60000);
EOF
exec npm run build
""" % (HELD, HOLDING)
MEASURE = {"holding": HOLDING, "poll_ms": 200, "margin_ms": 100, "grace_ms": 0}
# The keeper's protocol: every line carries its version.
V = 7

# The room case. A build's allowance (Prima.LocusPool), the room it needs
# and its least charge until ten seconds after its spawn; the pool's work,
# which holds one and not two; and the holder's bytes, more than the
# allowance, so the room it leaves is less than a build needs both before
# its reading, at its allowance, and after, at its reading.
BUILD_ALLOWANCE = imagesuite.ALLOWANCE_BYTES["build"]
ROOM_WORK = 1280 * MIB
ROOM_HELD = BUILD_ALLOWANCE + 64 * MIB
# Its places: the holder's, an athanor's with a subject; the asker of that
# athanor, whose `held` names the holder; and the asker of another, whose
# `held` counts it only among everyone else's.
ROOM_HOLDER = {"place": "holder", "athanor": ATHANOR, "subject": "holder"}
ROOM_ASKERS = [{"name": "mine", "place": "ask-mine", "athanor": ATHANOR},
               {"name": "other", "place": "ask-other", "athanor": "neighbour@example"}]
# How long a start waits for room before it is refused (Prima.LocusPool).
# The refusal is sent at the ledger's first second after it; two seconds
# bound that second and the line's way to the client.
ROOM_WAIT_MS = imagesuite.ROOM_WAIT_MS
ROOM_LATE_MS = 2000
# A start placed into an empty pool is answered by the step its place
# makes, well within this.
ROOM_AT_ONCE_MS = 1000

# One line per sample: `uid:rss_kb:processes,...|memory.current|shmem|uid:memory.peak:memory.max,...`.
SAMPLER = r"""
while :; do
  cat /proc/[0-9]*/status 2>/dev/null | awk -v first=%d -v last=%d '
    /^Name:/ { uid = -1 }
    /^Uid:/ { uid = $2; if (uid >= first && uid <= last) n[uid]++ }
    /^VmRSS:/ { if (uid >= first && uid <= last) rss[uid] += $2 }
    END { for (u in n) printf "%%s:%%d:%%d,", u, rss[u], n[u] }'
  groups=""
  for d in %s/keeper-*; do
    peak="$(cat "$d/bound/memory.peak" 2>/dev/null)" && max="$(cat "$d/bound/memory.max" 2>/dev/null)" \
      && groups="$groups${d##*keeper-}:$peak:$max,"
  done
  printf '|%%s|%%s|%%s\n' "$(cat %s/memory.current)" "$(awk '$1 == "shmem" {print $2}' %s/memory.stat)" "$groups"
  sleep 0.1
done
""" % (POOL_FIRST, POOL_LAST, ROLE_GROUP, BOUND_GROUP, BOUND_GROUP)

# Touches every page it allocates, outside V8's heap, until something stops it.
NODE_ALLOCATOR = "const held = []; for (;;) held.push(Buffer.alloc(16 << 20, 1));"
DAEMON = "setsid sh -c \"trap '' TERM; exec sleep 1000\" </dev/null >/dev/null 2>&1 &\n"
FILL_HOME = 'i=0; while head -c 50000000 /dev/zero > "$HOME/fill-$i"; do i=$((i + 1)); done\nsleep 120\n'

# Holds the MiB it is told to and waits: one thread, so the tree case can
# fork nearly as many as a build may have tasks.
HOLDER_C = """
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    size_t bytes = (size_t)atol(argv[1]) << 20;
    char *held = malloc(bytes);
    if (held == NULL) return 3;
    memset(held, 1, bytes);
    sleep(600);
    return held[5];
}
"""

SIBLING = tincture(
    "node -e \"const held = Buffer.alloc(64 << 20, 1); setTimeout(() => {"
    " require('fs').mkdirSync('dist', {recursive: true});"
    " require('fs').writeFileSync('dist/index.html', 'sibling ' + held[5]); }, 20000)\"\n"
)

HOSTILE_BUILD_RS = """
fn main() {
    let mut held: Vec<Vec<u8>> = Vec::new();
    loop {
        held.push(vec![1u8; 16 << 20]);
    }
}
"""

LIB_RS = """#[allow(warnings)]
mod bindings;

use bindings::exports::cyfr::reagent::compute::Guest;

struct Hostile;
bindings::export!(Hostile with_types_in bindings);

impl Guest for Hostile {
    fn compute(input: String) -> String {
        input
    }
}
"""

# The keeper cases' client: cyfr-locus starts it as the release's user with
# the channel on fd 3. It places every spawn of the scenario and sends each
# spawn once its place is answered, attaches their relays, and prints what
# the keeper answered for each. A spawn with `extra` members, which the
# protocol does not know, is refused before the keeper reads its id: such
# refusals are taken in the order those spawns were sent, and each one's
# place is dropped. The spawn marked `measure` is measured until a reading
# the keeper took after the build said it holds its memory, then released
# with a measure in the same write, and measured once more after its
# `released`.
CLIENT = r"""
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import crypto from "node:crypto";

const scenario = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const v = scenario.v;
const dir = fs.mkdtempSync(path.join(process.env.RELEASE_TMP, "memory-"));
const attach = path.join(dir, "attach.sock");
const spawns = scenario.spawns.map((s, i) => ({
  ...s, id: String(i + 1), place: "p" + (i + 1), token: crypto.randomBytes(32).toString("hex"), stdout: "", replies: [],
  measures: [], done: false, drained: false,
}));
// Each measure's spawn and its entry in that spawn's `measures`, by the measure's id.
const measures = new Map();
// The spawns sent with members the protocol does not know, in the order sent, until each is refused.
const refusable = [];
const started = Date.now();
// The number of the keeper's last line, so the report says in what order every reply came.
let seq = 0;
let channel = null;

function finish(timedOut) {
  if (!timedOut && !spawns.every((s) => s.done && (!s.spawn_id || s.drained))) return;
  const report = spawns.map(({ name, place, uid, replies, measures, holding_ms, bound, stdout, done }) => (
    { name, place, uid, replies, measures, holding_ms, bound, stdout: stdout.slice(-400), done }));
  process.stdout.write("<<<" + JSON.stringify({ timed_out: timedOut, spawns: report }) + ">>>\n", () => {
    fs.rmSync(dir, { recursive: true, force: true });
    // A role's process that ends is started again by its keeper, which
    // would run the scenario twice: one that `stays` waits to be stopped.
    if (scenario.stay) setInterval(() => {}, 1 << 30);
    else process.exit(timedOut ? 1 : 0);
  });
}

function measure(spawn, phase, before = "") {
  const id = "m" + (measures.size + 1);
  const entry = { phase, id, sent_ms: Date.now() - started };
  measures.set(id, { spawn, entry });
  spawn.measures.push(entry);
  channel.write(before + JSON.stringify({ v, type: "measure", id, place: spawn.place }) + "\n");
}

function measured(spawn, entry, reply) {
  Object.assign(entry, { reply, at_ms: Date.now() - started, seq });
  if (entry.phase === "after") {
    spawn.done = true;
    return finish(false);
  }
  if (entry.phase !== "running" || spawn.replies.some((r) => r.type === "released")) return;
  const readAt = reply.type === "measured" ? entry.at_ms - reply.age_ms : -Infinity;
  if (spawn.holding_ms !== undefined && readAt > spawn.holding_ms + scenario.measure.margin_ms) {
    const release = { v, type: "release", spawn_id: spawn.spawn_id, grace_ms: scenario.measure.grace_ms };
    measure(spawn, "release", JSON.stringify(release) + "\n");
  } else {
    setTimeout(() => measure(spawn, "running"), scenario.measure.poll_ms);
  }
}

function settle(spawn, reply) {
  spawn.replies.push({ ...reply, at_ms: Date.now() - started, seq });
  if (reply.type === "placed") {
    const request = {
      v, type: "spawn", id: spawn.id, place: spawn.place, pool: scenario.pool, argv: spawn.argv, env: {},
      attach: { path: attach, token: spawn.token }, ...(spawn.extra || {}),
    };
    if (spawn.extra) refusable.push(spawn);
    channel.write(JSON.stringify(request) + "\n");
  }
  if (reply.type === "spawned") {
    spawn.uid = reply.uid;
    spawn.spawn_id = reply.spawn_id;
    if (spawn.measure) measure(spawn, "running");
  }
  if (reply.type === "released" && spawn.measure) measure(spawn, "after");
  else if (reply.type === "released" || (reply.type === "error" && reply.id)) spawn.done = true;
  finish(false);
}

const server = net.createServer((conn) => {
  let buffer = Buffer.alloc(0);
  let spawn = null;
  conn.on("error", () => {});
  conn.on("end", () => { if (spawn) { spawn.drained = true; finish(false); } });
  conn.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 5 && buffer.length >= 5 + buffer.readUInt32BE(1)) {
      const stream = buffer[0];
      const payload = buffer.subarray(5, 5 + buffer.readUInt32BE(1));
      buffer = buffer.subarray(5 + payload.length);
      if (stream === 3) {
        spawn = spawns.find((s) => s.token === payload.toString("latin1"));
        if (!spawn) return conn.destroy();
      } else if (stream === 1 && spawn) {
        spawn.stdout += payload.toString("utf8");
        const bound = /^bound:(\S+)$/m.exec(spawn.stdout);
        if (bound && spawn.bound === undefined) spawn.bound = bound[1];
        if (spawn.measure && spawn.holding_ms === undefined && spawn.stdout.includes(scenario.measure.holding)) {
          spawn.holding_ms = Date.now() - started;
        }
      }
    }
  });
});

server.listen(attach, () => {
  channel = new net.Socket({ fd: 3, readable: true, writable: true });
  let lines = "";
  channel.on("data", (chunk) => {
    lines += chunk.toString("utf8");
    for (let at = lines.indexOf("\n"); at >= 0; at = lines.indexOf("\n")) {
      const reply = JSON.parse(lines.slice(0, at));
      lines = lines.slice(at + 1);
      seq += 1;
      const asked = reply.id === undefined ? undefined : measures.get(reply.id);
      if (asked) {
        measured(asked.spawn, asked.entry, reply);
        continue;
      }
      // A request with a member the protocol does not know is refused
      // without its id, in the order the keeper read it, and frees nothing:
      // its place is dropped.
      const unnamed = reply.type === "error" && !reply.id && !reply.spawn_id;
      const spawn = unnamed
        ? refusable.shift()
        : spawns.find((s) => s.id === reply.id || s.place === reply.id || (reply.spawn_id && s.spawn_id === reply.spawn_id));
      if (spawn && unnamed) channel.write(JSON.stringify({ v, type: "drop", place: spawn.place }) + "\n");
      if (spawn) settle(spawn, unnamed ? { ...reply, id: spawn.id } : reply);
    }
  });
  for (const s of spawns) {
    const place = { v, type: "place", id: s.place, kind: "build" };
    if (s.athanor) place.athanor = s.athanor;
    channel.write(JSON.stringify(place) + "\n");
  }
});

setTimeout(() => finish(true), scenario.timeout_ms);
"""

# The room case's client, started as CLIENT is. It places the holder and
# spawns it once placed, measures its place every poll_ms until a reading
# holds `held` bytes, then places every asker in one write; once each asker
# is answered it releases the holder (an asker answered `placed` is dropped
# first), and after the holder's `released` places the first asker again
# under its own place and drops it once answered. It reports every reply
# with when it came and its number among the keeper's lines, and when each
# place was sent.
ROOM_CLIENT = r"""
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import crypto from "node:crypto";

const scenario = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const v = scenario.v;
const dir = fs.mkdtempSync(path.join(process.env.RELEASE_TMP, "room-"));
const attach = path.join(dir, "attach.sock");
const token = crypto.randomBytes(32).toString("hex");
const started = Date.now();
const holder = { ...scenario.holder, replies: [], measures: [], spawn_id: null };
const askers = scenario.askers.map((a) => ({ ...a, replies: [] }));
const again = { ...scenario.askers[0], replies: [] };
const measures = new Map();
let phase = "holding";
let seq = 0;
let ended = false;
let channel = null;

function send(message) { channel.write(JSON.stringify({ v, ...message }) + "\n"); }
function stamp(reply) { return { ...reply, at_ms: Date.now() - started, seq }; }

function finish(timedOut) {
  if (ended) return;
  ended = true;
  const report = { timed_out: timedOut, holder, askers, again };
  process.stdout.write("<<<" + JSON.stringify(report) + ">>>\n", () => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (scenario.stay) setInterval(() => {}, 1 << 30);
    else process.exit(timedOut ? 1 : 0);
  });
}

function measure() {
  const id = "m" + (measures.size + 1);
  const entry = { id, sent_ms: Date.now() - started };
  measures.set(id, entry);
  holder.measures.push(entry);
  send({ type: "measure", id, place: holder.place });
}

function place(who) {
  who.sent_ms = Date.now() - started;
  const request = { type: "place", id: who.place, kind: "build", athanor: who.athanor };
  if (who.subject) request.subject = who.subject;
  return request;
}

function onReply(reply) {
  const asked = reply.id === undefined ? undefined : measures.get(reply.id);
  if (asked) {
    Object.assign(asked, { reply, at_ms: Date.now() - started, seq });
    if (phase !== "holding") return;
    if (reply.type === "measured" && reply.bytes >= scenario.held) {
      phase = "asking";
      channel.write(askers.map((a) => JSON.stringify({ v, ...place(a) })).join("\n") + "\n");
    } else {
      setTimeout(measure, scenario.poll_ms);
    }
    return;
  }
  if (reply.id === holder.place || reply.id === holder.spawn || (reply.spawn_id && reply.spawn_id === holder.spawn_id)) {
    holder.replies.push(stamp(reply));
    if (reply.type === "placed") {
      send({ type: "spawn", id: holder.spawn, place: holder.place, pool: scenario.pool, argv: holder.argv, env: {},
             attach: { path: attach, token } });
    } else if (reply.type === "spawned") {
      holder.spawn_id = reply.spawn_id;
      measure();
    } else if (reply.type === "released" && phase === "asking") {
      phase = "again";
      send(place(again));
    }
    return;
  }
  if (phase === "again" && reply.id === again.place) {
    again.replies.push(stamp(reply));
    if (reply.type === "placed") send({ type: "drop", place: again.place });
    return finish(false);
  }
  const asker = askers.find((a) => a.place === reply.id);
  if (!asker || phase !== "asking") return;
  asker.replies.push(stamp(reply));
  if (reply.type === "placed") send({ type: "drop", place: asker.place });
  if (askers.every((a) => a.replies.length > 0)) {
    send({ type: "release", spawn_id: holder.spawn_id, grace_ms: 0 });
  }
}

// The holder's relay is read and its bytes thrown away: the case reads its place, not its output.
const server = net.createServer((conn) => { conn.on("error", () => {}); conn.resume(); });

server.listen(attach, () => {
  channel = new net.Socket({ fd: 3, readable: true, writable: true });
  let lines = "";
  channel.on("data", (chunk) => {
    lines += chunk.toString("utf8");
    for (let at = lines.indexOf("\n"); at >= 0; at = lines.indexOf("\n")) {
      const reply = JSON.parse(lines.slice(0, at));
      lines = lines.slice(at + 1);
      seq += 1;
      onReply(reply);
    }
  });
  send(place(holder));
});

setTimeout(() => finish(true), scenario.timeout_ms);
"""


def shell(script):
    return ["/bin/sh", "-c", script]


# The first act of every bounded build: it reads its own group's bound from
# inside its space, where the space's cgroup root is that group, before it
# does anything that could end it. A hostile build is ended at its bound
# within a second, often before a sampler outside reads its group; this
# read cannot miss it.
READ_BOUND = 'echo "bound:$(cat /sys/fs/cgroup/memory.max)"\n'


def bounded(script, *args):
    """A build's command: READ_BOUND, then `script` with `args` as its $0 on."""
    return shell(READ_BOUND + script) + list(args)


# The spawns that name a bound of their own, which the keeper refuses: it sets every bound by the place's kind.
REFUSED = ("a spawn naming its memory bound", "a spawn naming its CPU quota")
# The spawns the keeper bounds at a build's bound.
BOUNDED = ("sibling", "process", "tree", "home", "build")


def scenario():
    holders = (f"for i in $(seq 1 {TREE_PROCESSES}); do perl -e '$held = \"x\" x {TREE_EACH}; sleep 120' & done\n"
               "wait\n")
    sibling = "const held = Buffer.alloc(64 << 20, 1); setTimeout(() => console.log('held ' + held[5]), 8000);"
    return [
        {"name": REFUSED[0], "argv": ["true"], "extra": {"memory_bytes": BOUND}},
        {"name": REFUSED[1], "argv": ["true"], "extra": {"cpu_quota": 100_000}},
        {"name": "sibling", "argv": bounded('exec node -e "$0"', sibling)},
        {"name": "process", "argv": bounded(DAEMON + f"exec node -e '{NODE_ALLOCATOR}'")},
        {"name": "tree", "argv": bounded(holders)},
        {"name": "home", "argv": bounded(FILL_HOME)},
        {"name": "build", "athanor": ATHANOR, "measure": True, "argv": bounded(MEASURED_BUILD, "measured-build")},
    ]


def reading(entry, athanor):
    """Whether a measure's entry was answered with a reading above zero of a `build` of `athanor`, and nothing else."""
    reply = entry.get("reply")
    if not isinstance(reply, dict):
        return False
    owner = {"v": V, "type": "measured", "id": entry["id"], "kind": "build", "athanor": athanor}
    return ({key: value for key, value in reply.items() if key not in ("bytes", "lesser", "age_ms")} == owner
            and type(reply.get("bytes")) is int and reply["bytes"] > 0 and type(reply.get("lesser")) is bool
            and type(reply.get("age_ms")) is int and reply["age_ms"] >= 0)


def unmeasured(entry):
    return entry.get("reply") == {"v": V, "type": "error", "id": entry["id"], "code": "unmeasured"}


def judge_build(spawn):
    """The measured build's verdict, from what the client reported of it: its replies and its measures, each by phase."""
    replies = spawn["replies"]
    types = [reply["type"] for reply in replies]
    expect(types[:2] == ["placed", "spawned"] and types[-1:] == ["released"] and set(types[2:-1]) <= {"exited"}
           and {key: value for key, value in replies[0].items() if key not in ("at_ms", "seq")}
           == {"v": V, "type": "placed", "id": spawn["place"], "memory_bytes": BOUND},
           "the build's place is placed with a build's bound before its spawn names it, and the build is released", spawn)
    released = replies[-1]["seq"]
    phases = {phase: [entry for entry in spawn["measures"] if entry["phase"] == phase] for phase in ("running", "release", "after")}
    running = phases["running"]
    first = next((n for n, entry in enumerate(running) if entry.get("reply", {}).get("type") == "measured"), len(running))
    expect(running[first:] and all(unmeasured(entry) for entry in running[:first]) and all(reading(entry, ATHANOR) for entry in running[first:]),
           f"while the build runs, once the keeper has read its group, every measure of its place answers a reading above zero naming build "
           f"and {ATHANOR} (before that, unmeasured)", running)
    last = running[-1]
    expect(spawn.get("holding_ms") is not None and last["at_ms"] - last["reply"]["age_ms"] > spawn["holding_ms"]
           and last["reply"]["bytes"] >= HELD,
           f"the reading the keeper took after the build said it holds {HELD // MIB} MiB counts them: "
           f"{last['reply']['bytes'] / MIB:.0f} MiB", {"holding_ms": spawn.get("holding_ms"), "last": last})
    release = (phases["release"] or [{"id": None}])[0]
    expect(len(phases["release"]) == 1 and reading(release, ATHANOR) and release["seq"] < released,
           "after its release, the build's place is still read above zero, answered before its released", [phases["release"], replies[-1]])
    after = (phases["after"] or [{"id": None}])[0]
    expect(len(phases["after"]) == 1 and unmeasured(after) and after["seq"] > released,
           "after its released, the build's place is free: its measure is unmeasured", [phases["after"], replies[-1]])


def room_scenario():
    """The room case's scenario: the holder, which touches ROOM_HELD bytes and keeps them until it is released, and
    the askers."""
    holder = dict(ROOM_HOLDER, spawn="holder-spawn",
                  argv=["node", "-e", f"const held = Buffer.alloc({ROOM_HELD}, 1); setInterval(() => held[5], 60000);"])
    return {"v": V, "pool": PROBE_POOL, "timeout_ms": 60_000, "poll_ms": 200, "held": ROOM_HELD, "holder": holder,
            "askers": ROOM_ASKERS, "stay": True}


def unstamped(reply):
    return {key: value for key, value in reply.items() if key not in ("at_ms", "seq")}


def judge_room(report, work=ROOM_WORK):
    """The room case's verdict, from what its client reported: each asker refused for room after the room's wait with
    its `held` whole while the holder holds the room, and the first placed at once after the holder's release."""
    expect(not report["timed_out"], "the room case's client was answered at every step", report)
    holder = report["holder"]
    replies = holder["replies"]
    types = [reply["type"] for reply in replies]
    expect(types[:2] == ["placed", "spawned"] and types[-1:] == ["released"] and set(types[2:-1]) <= {"exited"}
           and unstamped(replies[0]) == {"v": V, "type": "placed", "id": holder["place"], "memory_bytes": BOUND},
           "the holder is placed with a build's bound, spawned, and released", replies)
    readings = [entry for entry in holder["measures"] if entry.get("reply", {}).get("type") == "measured"]
    expect(readings and readings[-1]["reply"]["bytes"] >= ROOM_HELD,
           f"the keeper's reading of the holder's place counts the {mib(ROOM_HELD)} it holds before any asker is placed",
           holder["measures"])
    released = replies[-1]["seq"]
    for asker in report["askers"]:
        answers = asker["replies"]
        expect(len(answers) == 1 and answers[0]["type"] == "error" and answers[0].get("code") == "no_memory",
               f"the {asker['name']} asker is not placed while the holder holds the room: it is refused no_memory", answers)
        refusal = answers[0]
        waited = refusal["at_ms"] - asker["sent_ms"]
        expect(ROOM_WAIT_MS <= waited < ROOM_WAIT_MS + ROOM_LATE_MS and refusal["seq"] < released,
               f"the {asker['name']} asker is refused after the room's wait of {ROOM_WAIT_MS} ms and within "
               f"{ROOM_LATE_MS} ms of it, while the holder holds the room: {waited} ms", [asker, replies[-1]])
        held = refusal.get("held") if isinstance(refusal.get("held"), dict) else {}
        same = asker["athanor"] == holder["athanor"]
        if same:
            mine = held.get("mine")
            charge = mine[0].get("bytes") if isinstance(mine, list) and mine and isinstance(mine[0], dict) else None
            expected = {"mine": [{"kind": "build", "subject": holder["subject"], "bytes": charge}], "others_bytes": 0}
        else:
            charge = held.get("others_bytes")
            expected = {"mine": [], "others_bytes": charge}
        # The holder's charge is its reading, which holds ROOM_HELD, more than a build's allowance, and never its bound.
        expect(type(charge) is int and ROOM_HELD <= charge <= BOUND,
               f"the {asker['name']} asker's refusal charges the holder its reading, at least the {mib(ROOM_HELD)} it "
               f"holds, more than a build's allowance of {mib(BUILD_ALLOWANCE)}", refusal)
        expect(unstamped(refusal) == {"v": V, "type": "error", "id": asker["place"], "code": "no_memory",
                                      "held": {"need": BUILD_ALLOWANCE, "free": work - charge, **expected}},
               f"the {asker['name']} asker's held is whole: a build's allowance needed, the work less the holder's "
               f"charge free, and the holder " + ("among its own athanor's places, with its kind and subject" if same
                                                   else "only in the sum of everyone else's"), refusal)
    again = report["again"]
    answers = again["replies"]
    expect(len(answers) == 1 and answers[0]["seq"] > released and answers[0]["at_ms"] - again["sent_ms"] < ROOM_AT_ONCE_MS
           and unstamped(answers[0]) == {"v": V, "type": "placed", "id": again["place"], "memory_bytes": BOUND},
           f"once the holder is released, the {again['name']} asker placed again is placed at once with a build's bound",
           [again, replies[-1]])


def hostile_sources(case):
    if case == "javascript":
        return tincture(DAEMON + f"node -e '{NODE_ALLOCATOR}'\n"), "javascript", "tincture"
    if case == "rust":
        # The builder writes the manifest of a build that brings none, and
        # cargo runs a build.rs it finds beside it.
        return {"src/lib.rs": LIB_RS, "build.rs": HOSTILE_BUILD_RS}, "rust", "reagent"
    if case == "tree":
        # 100 processes of 64 MiB: no one of them is large, the tree is 6.25 GiB.
        script = "cc -O1 -o hold hold.c\nfor i in $(seq 1 100); do ./hold 64 & done\nwait\n"
        return tincture(script, {"hold.c": HOLDER_C}), "javascript", "tincture"
    if case == "home":
        return tincture(FILL_HOME), "javascript", "tincture"
    sys.exit(f"unknown case {case}\n{__doc__}")


class Sampler(threading.Thread):
    """Reads the in-container sampler's lines, stamping each on arrival."""

    def __init__(self, container):
        super().__init__(daemon=True)
        self.process = subprocess.Popen(
            ["docker", "exec", container, "sh", "-c", SAMPLER], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.samples = []
        self.group_peaks = {}
        # Each group's memory.max, every value it was read at.
        self.group_bounds = {}

    def run(self):
        for line in self.process.stdout:
            try:
                uids, current, shmem, groups = line.strip().split("|")
                tree = {}
                for entry in filter(None, uids.split(",")):
                    uid, rss_kb, count = entry.split(":")
                    tree[int(uid)] = (int(rss_kb) * 1024, int(count))
                for entry in filter(None, groups.split(",")):
                    uid, peak, bound = entry.split(":")
                    self.group_peaks[int(uid)] = max(self.group_peaks.get(int(uid), 0), int(peak))
                    self.group_bounds.setdefault(int(uid), set()).add(bound)
                self.samples.append((time.monotonic(), tree, int(current), int(shmem or 0)))
            except ValueError:
                continue

    def stop(self):
        self.process.kill()
        self.process.wait()

    def container_peak(self):
        return max((current for _, _, current, _ in self.samples), default=0)

    def shmem_peak(self):
        return max((shmem for _, _, _, shmem in self.samples), default=0)

    def tree_peak(self, uid):
        """The uid's largest sampled resident set, its process count then, and when."""
        best = (0, 0, None)
        for at, tree, _, _ in self.samples:
            if uid in tree and tree[uid][0] > best[0]:
                best = (tree[uid][0], tree[uid][1], at)
        return best


def container_state(stack):
    """The container as Docker and its own cgroup report it; a container that is down reports what it can.

    A container started again gives its init and its release the pids they
    had, and Docker's own start time can lag the restart, so each is named by
    its pid and the kernel's start time for it (field 22 of /proc/<pid>/stat).
    """
    inspect = json.loads(run("docker", "inspect", stack.container).stdout)[0]
    events = {}
    for line in imagesuite.read_output(stack.exec(f"cat {BOUND_GROUP}/memory.events"),
                                       "the builds' bound's memory events").splitlines():
        name, count = line.split()
        events[name] = int(count)
    pids = [1] + [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]]
    # Each start time is read by a cut that exits 0, chained so a failed read ends the script with its status: a
    # process that has gone fails the state rather than reading as an empty start time.
    started = imagesuite.read_output(stack.exec(" && ".join(
        f"x=$(cut -d' ' -f22 /proc/{pid}/stat) && echo {pid}:$x" for pid in pids)),
        "the start times of the container's processes").split()
    return {
        "oom_killed": inspect["State"]["OOMKilled"],
        "init": started[:1],
        "events": events,
        "release": started[1:],
        "current": int(imagesuite.read_output(stack.exec(f"cat {BOUND_GROUP}/memory.current"),
                                              "the builds' bound's memory use").strip()),
    }


def mib(count):
    return f"{count / MIB:.0f} MiB"


def brief(answer):
    """A build's answer with each of its files by its size, its error cut to its end."""
    if not isinstance(answer, dict):
        return str(answer)[:900]
    answer = {key: value for key, value in answer.items() if key not in ("output_files", "outputs", "wasm_base64", "logs", "diagnostics")}
    if "files" in answer:
        answer["files"] = {path: f"{len(data)} bytes" for path, data in answer["files"].items()}
    if isinstance(answer.get("error"), str):
        answer["error"] = answer["error"][-500:]
    return json.dumps(answer)[:900]


def print_container(limit, before, after, sampler):
    again = after["init"] != before["init"]
    delta = {name: count - (0 if again else before["events"].get(name, 0)) for name, count in after["events"].items()}
    print(f"container: limit {mib(limit)}; {mib(before['current'])} before, {mib(sampler.container_peak())} at its peak "
          f"({mib(sampler.shmem_peak())} of it tmpfs), {mib(after['current'])} after")
    print(f"container: cgroup events {delta}{' since it started again' if again else ''}; Docker's OOMKilled flag "
          f"{after['oom_killed']}; container started again {again}; release (pid:start) {before['release']} -> {after['release']}")
    return again


def own_limit_writable(stack):
    """Whether uid 0 in the container can rewrite the container's own limit, by writing its value back."""
    result = stack.exec('v="$(cat /sys/fs/cgroup/memory.max)" && echo "$v" > /sys/fs/cgroup/memory.max')
    if result.returncode == 0:
        return ("writable from inside: this host mounts cgroup2 without nsdelegate, so uid 0 in the container "
                "(cyfr-locus and the container's init, nothing else) can rewrite the container's own limits")
    return "not writable from inside: " + (result.stderr.strip().rsplit(": ", 1)[-1] or "refused")


def keeper_groups(stack):
    """The keeper cgroup groups the container holds, read in word form: `absent` alone from a command that exits 0.

    `find` exits 0 with no output when no group matches, and non-zero on a
    read error, so the word is printed only after the enumeration succeeded.
    """
    script = (f'groups="$(find {ROLE_GROUP} -maxdepth 1 -name \'keeper-*\')" || exit 3; '
              'if [ -n "$groups" ]; then echo present; echo "$groups"; else echo absent; fi')
    return imagesuite.read_listing(stack.exec(script), "the keeper cgroups the container holds")


def keeper_report(name, timeout_s=300):
    """The scenario client's report, once the one-off container's log holds it whole, and the log."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        logs = run("docker", "logs", name, check=False)
        if ">>>" in logs.stdout.split("<<<", 1)[-1] and "<<<" in logs.stdout:
            return logs
        if run("docker", "inspect", "--format", "{{.State.Running}}", name, check=False).stdout.strip() != "true":
            return logs
        time.sleep(0.5)
    return run("docker", "logs", name, check=False)


def write_client(canary, client, source, scenario_file, scenario_value):
    """Writes a client and its scenario into the canary directory, which the probe mounts at /canary."""
    with open(os.path.join(canary, client), "w") as out:
        out.write(source)
    with open(os.path.join(canary, scenario_file), "w") as out:
        json.dump(scenario_value, out)
    # The container's user reads them, whatever the caller's umask.
    os.chmod(os.path.join(canary, client), 0o644)
    os.chmod(os.path.join(canary, scenario_file), 0o644)
    os.chmod(canary, 0o755)


def start_probe(stack, guard, canary, name, client, scenario_file, work, total):
    """A second cyfr-locus, in a container of its own under the service's options behind a guard of its own, whose
    builds role is the client over the probe pool, relay spaces that need no route, its pool's work `work` bytes: the
    machine's memory, `total`, less a reserve, with no share and no floor. Answers its container's id."""
    if total <= work:
        sys.exit(f"FAIL: this machine's {total} bytes do not hold a pool of {work} bytes")
    return run("docker", "run", "--detach", *imagesuite.run_name(name), *guard.keeper_args(),
               "-v", f"{canary}:/canary:ro",
               "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
               "--security-opt", "no-new-privileges:true", "--security-opt", "writable-cgroups=true",
               "--security-opt", f"seccomp={os.path.join(ROOT, 'apps', 'locus', 'keeper', 'seccomp', 'keeper.json')}",
               "--security-opt", f"apparmor={imagesuite.APPARMOR}", "--security-opt", "systempaths=unconfined",
               "--read-only", "--ipc", "none", "--init", *imagesuite.role_mounts(RELEASE, ROLE),
               "-e", f"{ROLE['key']}={stack.key}", "-e", f"LOCUS_CORE_RESERVE_BYTES={total - work}",
               "-e", "LOCUS_SERVICE_BYTES=0",
               "--entrypoint", "cyfr-locus", stack.image, "serve",
               "--role", imagesuite.role_spec(dict(ROLE, pool=PROBE_POOL)),
               "--pool", f"{PROBE_POOL}:{PROBE_FIRST}-{PROBE_LAST}:relay", "--home-root", RELEASE["home_root"],
               "--guard", imagesuite.Guard.CONTROL, "--", "node", f"/canary/{client}",
               f"/canary/{scenario_file}").stdout.strip()


def await_probe(stack, container, work):
    """The stack as an observer of the probe's container, once rest is bounded at `work`, which the keeper writes as it
    boots, before the role starts."""
    probe = copy.copy(stack)
    probe.container = container
    deadline = time.monotonic() + 60
    while probe.exec(f"test -f {ROLE_GROUP}/memory.events && grep -qx {work} {BOUND_GROUP}/memory.max").returncode != 0:
        expect(time.monotonic() < deadline, "the second cyfr-locus makes the builds role's group and bounds rest",
               run("docker", "logs", container, check=False).stderr[-2000:])
        time.sleep(0.2)  # sleep-ok: polling for the group the keeper makes as it boots
    return probe


def test_keeper(stack, limit, canary):
    write_client(canary, "memory-client.mjs", CLIENT, "memory-scenario.json",
                 {"v": V, "pool": PROBE_POOL, "timeout_ms": 90_000, "measure": MEASURE, "spawns": scenario(), "stay": True})
    # The pool's bound at the service's, which the hostile work meets beside its own.
    guard = imagesuite.Guard(stack.image, f"{stack.project}-keeper-guard")
    name = None
    try:
        name = start_probe(stack, guard, canary, f"{stack.project}-keeper", "memory-client.mjs", "memory-scenario.json",
                           limit, mem_total(stack))
        probe = await_probe(stack, name, limit)
        before = container_state(probe)
        sampler = Sampler(name)
        sampler.start()
        result = keeper_report(name)
        time.sleep(1)  # sleep-ok: the sampler's last tenth-second readings of the scenario's end
        sampler.stop()
        expect("<<<" in result.stdout, "the second cyfr-locus ran the scenario's client", result.stdout + result.stderr)
        after = container_state(probe)
        left = probe.pool_processes()
        homes = probe.homes()
        groups = keeper_groups(probe)
    finally:
        if name:
            run("docker", "rm", "--force", name, check=False)
        guard.down()
    report = json.loads(result.stdout.split("<<<", 1)[1].rsplit(">>>", 1)[0])
    spawns = {spawn["name"]: spawn for spawn in report["spawns"]}

    def reply(name, kind):
        return next((r for r in spawns[name]["replies"] if r["type"] == kind), None)

    print("--- keeper")
    print(f"the container's own memory.max is {own_limit_writable(stack)}")
    again = print_container(limit, before, after, sampler)
    for name, spawn in spawns.items():
        uid = spawn.get("uid")
        exited, error = reply(name, "exited"), reply(name, "error")
        resident, processes, _ = sampler.tree_peak(uid)
        end = (f"exited {({k: exited[k] for k in ('code', 'signal', 'memory')})} {exited['at_ms'] / 1000:.1f} s in"
               if exited else f"refused as {error['code']}" if error else "no answer")
        peak = sampler.group_peaks.get(uid)
        measured = f"; uid {uid}, group peak {mib(peak) if peak else 'unseen'}, {mib(resident)} resident over {processes} processes" if uid else ""
        print(f"{name}: {end}{measured}")
    for entry in spawns["build"]["measures"]:
        answer = entry.get("reply") or {}
        print(f"build: {entry['phase']} measure {entry['id']}: " + (
            f"{answer['bytes'] / MIB:.0f} MiB of {answer.get('kind')} {answer.get('athanor')}, read {answer['age_ms']} ms before"
            if answer.get("type") == "measured" else str(answer.get("code", "no answer"))))
    for line in result.stderr.splitlines():
        if "memory" in line:
            print("  keeper: " + line.split("] ", 1)[-1][:300])

    expect(not report["timed_out"], "every spawn of the scenario was answered and released", report)
    for name in REFUSED:
        expect(reply(name, "error") and reply(name, "error")["code"] == "bad_request" and not reply(name, "spawned"),
               f"{name}, which the keeper sets by its kind, is refused as a bad request", spawns[name])

    placed = {name: reply(name, "placed") for name in BOUNDED}
    expect(all(answer and answer.get("memory_bytes") == BOUND for answer in placed.values()),
           f"every build's place is answered placed with a build's bound, {mib(BOUND)}", placed)
    # Each build read its own group's bound from inside before anything
    # else, so none is missed; a hostile group may live for less than one
    # of the sampler's reads from outside, which must agree wherever it read.
    inside = {name: spawns[name].get("bound") for name in BOUNDED}
    expect(all(bound == str(BOUND) for bound in inside.values()),
           f"every build's group is bounded at exactly {BOUND} bytes, as each read it from inside its space", inside)
    outside = {name: sampler.group_bounds.get(spawns[name]["uid"]) for name in BOUNDED}
    expect(all(bound in (None, {str(BOUND)}) for bound in outside.values()),
           f"every build's group the sampler read is bounded at exactly {BOUND} bytes", outside)
    sibling = reply("sibling", "exited")
    expect(sibling and sibling["code"] == 0 and sibling["memory"] is None and "held 1" in spawns["sibling"]["stdout"],
           "a sibling spawn holding 64 MiB under its bound completes", spawns["sibling"])
    for name in ("process", "tree", "home"):
        exited = reply(name, "exited")
        expect(exited and exited["signal"] == "SIGKILL" and exited["code"] is None and exited["memory"] == "cap",
               f"the hostile {name} is ended at its bound and reported so", spawns[name])
        expect(reply(name, "released"), f"the hostile {name}'s uid is reported retired", spawns[name])
    judge_build(spawns["build"])
    # A hostile group lives for less than a second, so the sampler may miss
    # its last pages; that it reached its bound is the kernel's own count,
    # which `memory` `cap` reports. What was sampled never passed it.
    seen = {name: sampler.group_peaks.get(spawns[name]["uid"]) for name in BOUNDED}
    expect(seen["sibling"] and all(peak is None or peak <= BOUND for peak in seen.values()),
           "no group's peak, as the kernel accounts it, passed its bound", {"bound": BOUND, "seen": seen})

    expect(left == [], "no process of any spawn's uid is left, the daemon included", left)
    expect(homes == [], "no home is left", homes)
    expect(groups == [], "no spawn's cgroup is left", groups)
    expect(not again, "the container was not started again", {"before": before, "after": after})


def test_room(stack, canary):
    write_client(canary, "memory-room-client.mjs", ROOM_CLIENT, "memory-room.json", room_scenario())
    # The probe alone: the builds service is not needed, and its pool's work is the case's own.
    guard = imagesuite.Guard(stack.image, f"{stack.project}-room-guard")
    name = None
    try:
        name = start_probe(stack, guard, canary, f"{stack.project}-room", "memory-room-client.mjs", "memory-room.json",
                           ROOM_WORK, imagesuite.mem_total(stack.image))
        probe = await_probe(stack, name, ROOM_WORK)
        result = keeper_report(name, timeout_s=120)
        expect("<<<" in result.stdout, "the second cyfr-locus ran the room case's client", result.stdout + result.stderr)
        left = probe.pool_processes()
        homes = probe.homes()
        groups = keeper_groups(probe)
    finally:
        if name:
            run("docker", "rm", "--force", name, check=False)
        guard.down()
    report = json.loads(result.stdout.split("<<<", 1)[1].rsplit(">>>", 1)[0])

    print("--- room")
    print(f"the pool's work {mib(ROOM_WORK)}, a build's allowance {mib(BUILD_ALLOWANCE)}; the holder holds {mib(ROOM_HELD)}")
    for asker in report["askers"] + [report["again"]]:
        for answer in asker["replies"]:
            print(f"{asker['name']} ({asker['athanor']}): {answer['type']} {answer.get('code', '')} "
                  f"{answer['at_ms'] - asker['sent_ms']} ms after its place {json.dumps(answer.get('held'))}")
    for line in result.stderr.splitlines():
        if "refused" in line or "the pool:" in line:
            print("  keeper: " + line.split("] ", 1)[-1][:300])

    judge_room(report)
    expect(left == [] and homes == [] and groups == [], "the holder left no process, home or group",
           {"processes": left, "homes": homes, "groups": groups})


def test_build(stack, case, limit, measure):
    sources, language, target_type = hostile_sources(case)
    before = container_state(stack)
    sampler = Sampler(stack.container)
    sampler.start()
    results = {}

    def build(name, *args):
        started = time.monotonic()
        try:
            status, answer = stack.build(*args)
        except OSError as error:
            status, answer = None, f"the builder gave no answer: {error!r}"
        results[name] = (status, answer, started, time.monotonic())

    sibling = threading.Thread(target=build, args=("sibling", SIBLING, "javascript", "tincture"))
    sibling.start()
    time.sleep(3)
    sibling_uids = {uid for _, tree, _, _ in sampler.samples for uid in tree}
    hostile = threading.Thread(target=build, args=("hostile", sources, language, target_type))
    hostile.start()
    hostile.join()
    survivors = stack.pool_processes()
    homes = stack.homes()
    sibling.join()
    time.sleep(1)
    sampler.stop()
    after = container_state(stack)

    status, answer, started, ended = results["hostile"]
    sibling_status, sibling_answer, _, _ = results["sibling"]
    # The hostile build's uid is the one the sibling did not run under.
    uids = {uid for _, tree, _, _ in sampler.samples for uid in tree} - sibling_uids
    uid = max(uids, key=lambda candidate: sampler.tree_peak(candidate)[0], default=None)
    resident, processes, peak_at = sampler.tree_peak(uid)
    last_seen = max((at for at, tree, _, _ in sampler.samples if uid in tree), default=ended)
    group_peak = sampler.group_peaks.get(uid)
    left = [p for p in survivors if uid in p["uids"]]
    left_homes = [home for home in homes if home.startswith(f"{uid}-")]

    print(f"--- {case}")
    again = print_container(limit, before, after, sampler)
    print(f"hostile build: uid {uid}; its tree's peak {mib(resident)} resident over {processes} processes, "
          f"{(peak_at or ended) - started:.1f} s after it started; its group's peak "
          f"{mib(group_peak) if group_peak else 'none: it ran in no group of its own'}")
    print(f"ended by: HTTP {status} {brief(answer)}")
    print(f"ended {ended - started:.1f} s after it started, {ended - (peak_at or ended):.1f} s after the sample at its peak; "
          f"a process of its uid was last seen {last_seen - (peak_at or ended):.1f} s after that sample")
    print(f"when its answer arrived: processes of its uid {left}, homes of its uid {left_homes}")
    print(f"sibling: HTTP {sibling_status} {'completed' if sibling_status == 200 else brief(sibling_answer)}")
    if measure:
        return

    expect(isinstance(answer, dict) and answer.get("class") == "memory",
           f"{case}: the hostile build is answered with the memory class", {"status": status, "answer": brief(answer)})
    expect(left == [] and left_homes == [], f"{case}: no process of its uid and no home of its is left", [left, left_homes])
    expect(sibling_status == 200, f"{case}: the sibling build completes", brief(sibling_answer))
    expect(not again and after["release"] == before["release"] and after["release"],
           f"{case}: the release and the container were not touched", {"before": before, "after": after})


def container_limit(stack):
    """Rest's memory.max, the pool's bound over the builds, which bounds the hostile work: the container carries no
    limit of its own."""
    return imagesuite.read_output(stack.exec(f"cat {BOUND_GROUP}/memory.max"), "rest's memory.max").strip()


def mem_total(stack):
    """The machine's memory, in bytes, as the container's /proc/meminfo reads it."""
    out = imagesuite.read_output(stack.exec("awk '$1 == \"MemTotal:\" {print $2}' /proc/meminfo"), "MemTotal").strip()
    expect(out.isdigit(), "/proc/meminfo names the machine's memory", out)
    return int(out) * 1024


def main(image, measure, cases):
    # Registered for removal at exit as soon as it exists, so a signal
    # before the `try` leaves no directory behind.
    canary = imagesuite.temporary_directory("locus-builds-memory-")
    stack = Stack("locus-builds-memory", image, canary)
    try:
        for case in cases:
            if case == "room":
                test_room(stack, canary)
                continue
            # A fresh container per case, so one case's damage is not the next one's start.
            stack.up(pool=f"{POOL_FIRST}-{PROBE_FIRST - 1}", timeout_ms=DEADLINE_MS)
            limit = container_limit(stack)
            expect(limit.isdigit() and int(limit) > 0, "rest has a memory bound, which bounds the hostile work", limit)
            if case == "keeper":
                test_keeper(stack, int(limit), canary)
            else:
                test_build(stack, case, int(limit), measure)
    finally:
        stack.down()
        imagesuite.remove_directory(canary)


if __name__ == "__main__":
    arguments = [argument for argument in sys.argv[1:] if argument != "--measure"]
    if not arguments:
        sys.exit(__doc__)
    main(arguments[0], "--measure" in sys.argv, arguments[1:] or ["keeper", "room", "javascript", "rust", "tree", "home"])
