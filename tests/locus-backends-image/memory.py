#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Every program's process in the backends image is held to its memory bound, alone.

Run as docker-compose.yml's locus-backends service with the service's own
bound (LOCUS_BACKENDS_MEMORY_BYTES) set low, and driven only by requests
signed as CYFR signs them (harness.py):

- Every session's process runs in a cgroup of its own whose memory.max is
  the bound, inside the backends role's own bound; a program whose row names
  its own `memory_bytes` is bounded at that instead.
- A process that holds less than its bound answers.
- A process that reaches past its bound is ended there by the kernel: its
  session ends before it answers, its status counts the crash and names
  the kill, and the next call starts the program again under a new
  process, initialized afresh; nothing of its uid outlives the kill but
  what the new start started.
- Its sibling, another owner's program, runs on untouched, and the service
  answers throughout.

And the service's own memory has a bound, in a service started afresh:

- As many sessions as it admits, up to its pool's uids, open silent, and
  the group it runs in (the keeper's, `keeper`) peaks at its idle figure.
  Then all but one write 8 MiB of lines each that nobody reads, while one
  is read as it comes. The group's peak stays within its idle peak and the
  allowance `allowance/1` computes from the role table as harness.py reads
  it (`Prima.LocusRoles`, `Locus.Output`'s table): the factor of
  resident bytes to a byte held times what the service counts, its unread
  and answering bounds, and the keeper reads its sessions' spawns hold, and
  the kernel's queue of each spawn's relay; the suite prints the peak beside
  the allowance whether it holds or not. The kernel kills nothing in the container,
  every session runs on, the service answers health and renewals
  throughout, the session read as it comes loses no line, and each unread
  session kept its newest lines, whole and in order, its oldest dropped and
  counted, within the unread bound together.
- A person stops a program while it floods, deaf to the stop's SIGTERM, so
  it writes through the stop grace until it is killed: once with its
  session taking as it comes, once with the session slow, masking every
  line against many credentials. In a service started afresh each time,
  the stop is answered, nothing of the program outlives it, the kernel
  kills nothing, and the service leaf's peak stays within its idle peak and
  the allowance of one session, printed beside it.

Prerequisites: harness.py's. Usage: tests/locus-backends-image/memory.py IMAGE
"""

import os
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import (  # noqa: E402
    POOL_FIRST, POOL_LAST, RELEASE, ROLE, Stack, eventually, expect, health, owner_of, probe, require_docker,
    wait_healthy,
)
import imagesuite  # noqa: E402

BOUND = 128 * 1024 * 1024
# A row's own bound, which the service passes to the keeper in place of its own.
ROW_BOUND = 96 * 1024 * 1024
HOG, SIBLING, OWN = owner_of("hog"), owner_of("sibling"), owner_of("own")

MIB = 1024 * 1024
# The backends role's own memory and the release's shared figures
# (Prima.LocusRoles): what the service keeps unread over every session and
# answers at once, and what each spawn holds beside them.
MEMORY, SHARED = ROLE["memory"], RELEASE["memory"]
UNREAD_BOUND = MEMORY["unread"]
ANSWERING_BOUND = MEMORY["answering"]
# A flood's line: 992 bytes and its newline, which the service charges 1,024
# with its framing, so 8,192 of them leave a session's 8 MiB unread.
FLOOD_TEXT = 992
FLOOD_LINES = 8192
LINE_CHARGE = FLOOD_TEXT + 32
# The most sessions the service runs at once: its pool's uids. An owner
# holds at most 16 (Prima.LocusBackends.max_sessions/0), so two hold them.
SESSIONS = POOL_LAST - POOL_FIRST + 1
FLOODED = [owner_of("flood-a"), owner_of("flood-b")]
ROUND = 64
# A program holding this many credentials has each line it writes masked
# against every one of them, so its session takes its output about twenty
# times slower than one holding none.
CREDENTIALS = 200


def allowance(spawns):
    """What the flood may raise the service's group by, over its idle peak, with `spawns` sessions open.

    The factor of resident bytes to a byte held times what the service counts
    (its unread and answering bounds) and the one keeper read each spawn
    holds, at most its copies at once; and beside them the kernel's queue of
    each spawn's relay. No session writes stderr or an unfinished line, and
    what the service writes its sessions is a line at a time.
    """
    held = UNREAD_BOUND + ANSWERING_BOUND + spawns * SHARED["keeper_read_bytes"] * SHARED["keeper_read_copies"]
    return int(SHARED["byte_cost"] * held) + spawns * SHARED["relay_queue_bytes"]


def cgroup_limit(stack, pid):
    """The memory.max of the cgroup `pid` runs in, and that cgroup's path, read as root in the container."""
    path = imagesuite.read_output(stack.exec(f"sed -n 's/^0:://p' /proc/{pid}/cgroup"), f"the cgroup of pid {pid}").strip()
    limit = imagesuite.read_output(stack.exec(f"cat /sys/fs/cgroup{path}/memory.max"), f"memory.max of the cgroup {path}").strip()
    return path, limit


# The backends role's group, which the keeper bounds at the role's
# LOCUS_BACKENDS_MEMORY_LIMIT: every backend's group inside it, beside its
# leaf `service`, the role's process and its relays.
ROLE_GROUP = f"role-{ROLE['name']}"


def container_limit(stack):
    """The backends role's memory.max, which every backend's bound must sit inside."""
    return imagesuite.read_output(stack.exec(f"cat /sys/fs/cgroup/{ROLE_GROUP}/memory.max"),
                                  "the backends role's memory.max").strip()


def bounds_each_program(stack):
    """Every program's process held to its bound, alone, its sibling and the service untouched."""
    stack.up(memory_bytes=BOUND)
    c = stack.controller()
    expect(c.hello()[0] == 200, "the service is greeted")
    for owner in [HOG, SIBLING]:
        status, answer, _ = c.sync(owner, [probe()])
        expect(status == 200, f"{owner['athanor']} is synced", answer)
        c.running(owner)

    hog, sibling = c.tool(HOG, "probe__whoami"), c.tool(SIBLING, "probe__whoami")
    container = container_limit(stack)
    hogged = stack.outside(hog)
    for name, who in [("hog", hog), ("sibling", sibling)]:
        path, limit = cgroup_limit(stack, stack.outside(who)["pid"])
        expect(path not in ("", "/") and limit == str(BOUND),
               f"the {name} backend runs in a cgroup of its own bounded at {BOUND} bytes", [path, limit])
    expect(container.isdigit() and int(container) > BOUND,
           "the bound sits inside the backends role's own bound", container)

    held = c.tool(HOG, "probe__hog", {"bytes": BOUND // 4})
    expect(held == {"held": BOUND // 4}, "a backend below its bound answers", held)

    client = c.mcp(HOG, "probe")
    status, answer = c.call(HOG, "probe__hog", {"bytes": BOUND * 2})
    expect(status == 200 and answer.get("ended") == "before_answer",
           "a call past the bound ends the session before the program answers", answer)
    eventually(lambda: not any(p["pid"] == hogged["pid"] for p in stack.processes()),
               "the kernel to end the process at its bound")

    crashed = eventually(lambda: (lambda p: p if p["restarts"] >= 1 and p["sessions"] == 0 else None)(
        c.program(HOG)), "the kill to be reported")
    expect(crashed["status"] == "idle" and "SIGKILL" in (crashed.get("error") or ""),
           "the program's status counts the crash, names the kill and runs nothing", crashed)
    initialized = client.initializations
    again = c.tool(HOG, "probe__whoami")
    # A pid namespace's number may be the ended one's again: the container's
    # numbering tells the two processes apart.
    restarted = stack.outside(again)
    expect(restarted and restarted["pid"] != hogged["pid"] and client.initializations == initialized + 1
           and client.resumed is False, "the next call starts the program again under a new process, initialized afresh", again)
    expect(c.program(HOG)["status"] == "running", "the program runs again")
    expect(cgroup_limit(stack, restarted["pid"])[1] == str(BOUND), "the restarted process is bounded again")
    leftover = [p for p in stack.under_uid(hog["uid"]) if hog["uid"] != again["uid"] or p["pid"] == hogged["pid"]]
    expect(not leftover, "nothing of the killed process's uid outlives it but what the restart started", leftover)

    expect(c.tool(SIBLING, "probe__whoami")["pid"] == sibling["pid"], "the sibling runs on untouched")

    status, answer, _ = c.sync(OWN, [probe(memory_bytes=ROW_BOUND)])
    expect(status == 200, "a program whose row names its own bound is synced", answer)
    own = c.tool(OWN, "probe__whoami")
    expect(cgroup_limit(stack, stack.outside(own)["pid"])[1] == str(ROW_BOUND),
           f"a row's own bound, {ROW_BOUND} bytes, bounds its process in place of the service's", own)
    wait_healthy(stack.base)
    expect(c.renew([{**HOG}, {**SIBLING}, {**OWN}])[0] == 200, "the service answers throughout")


def group_memory(stack, group=f"{ROLE_GROUP}/service"):
    """A cgroup's memory.current, memory.peak and the oom and oom_kill counts of its memory.events, each read or failed."""
    def value(name):
        text = imagesuite.read_output(stack.exec(f"cat /sys/fs/cgroup/{group}/{name}"), f"{group}/{name}").strip()
        if not text.isdigit():
            sys.exit(f"FAIL: {group}/{name} reads {text!r}, no count of bytes")
        return int(text)

    events = imagesuite.read_counters(stack.exec(f"cat /sys/fs/cgroup/{group}/memory.events"), ("oom", "oom_kill"),
                                      f"{group}/memory.events")
    return {"current": value("memory.current"), "peak": value("memory.peak"), "events": events}


def flood_command(text_bytes, lines):
    """A program that waits for one line, then writes `lines` lines of `text_bytes` bytes and stays."""
    return f'read go && yes "$(printf \'%0{text_bytes}d\' 0)" | head -n {lines}; exec sleep 3600'


def endless_flood_command(text_bytes):
    """A program that waits for one line, then writes lines of `text_bytes` bytes until it is killed, deaf to SIGTERM."""
    return f'trap "" TERM; read go && exec yes "$(printf \'%0{text_bytes}d\' 0)"'


def kept(answer, lines, text_bytes):
    """What an unread session kept, read from `answer` with `after` 0: (dropped, kept), or None until its last line is in.

    The lines it kept must be its newest, whole and in order, every one before
    them counted in `dropped`; anything else fails the suite.
    """
    seqs = [line["seq"] for line in answer["lines"]]
    if not seqs or seqs[-1] < lines:
        return None
    dropped = answer["dropped"]
    expect(seqs == list(range(dropped + 1, lines + 1)) and
           all(line["text"] == "0" * text_bytes for line in answer["lines"]),
           f"an unread session kept its newest lines whole and in order, its {dropped} oldest dropped and counted",
           {"dropped": dropped, "first": seqs[0], "last": seqs[-1], "count": len(seqs)})
    return dropped, len(seqs)


class Answering(threading.Thread):
    """Asks the service's health and renews the flooded owners until stopped, keeping every failure."""

    def __init__(self, base, controller):
        super().__init__(daemon=True)
        self.base, self.controller = base, controller
        self.stopped = threading.Event()
        self.failures = []
        self.asked = 0

    def run(self):
        renewed = 0.0
        while not self.stopped.is_set():
            try:
                status, answer = health(self.base)
                if status != 200:
                    self.failures.append(("health", status, answer))
                if time.monotonic() - renewed > 5:
                    status, answer, _boot = self.controller.renew([dict(o) for o in FLOODED], lease_ms=60_000)
                    if status != 200:
                        self.failures.append(("renew", status, answer))
                    renewed = time.monotonic()
                self.asked += 1
            except OSError as error:
                self.failures.append(("unanswered", repr(error)))
            self.stopped.wait(0.2)


def read_round(c, owner, session, after, round_number):
    """One round of the session read as it comes: ROUND lines sent and read back, every answer telling no drop.

    Answers the last sequence number read; any refusal, drop or line out of
    place fails the suite.
    """
    sent = [f"{round_number}:{i}:".ljust(FLOOD_TEXT, "r") for i in range(ROUND)]
    status, answer = c.send(owner, session, sent)
    if status != 200 or answer["status"] != "running":
        sys.exit(f"FAIL: the session read as it comes refused its lines in round {round_number}: {status} {answer}")
    read = []
    deadline = time.monotonic() + 30
    while len(read) < ROUND:
        status, answer = c.recv(owner, session, after, 5_000)
        if status != 200 or answer["dropped"] != 0:
            told = answer if status != 200 else {k: v for k, v in answer.items() if k != "lines"}
            sys.exit(f"FAIL: the session read as it comes lost lines or was refused in round {round_number}: "
                     f"{status} {told}")
        read += [line["text"] for line in answer["lines"]]
        after = answer["lines"][-1]["seq"] if answer["lines"] else after
        if time.monotonic() > deadline:
            sys.exit(f"FAIL: the session read as it comes answered {len(read)} of {ROUND} lines in 30 s")
    if read != sent:
        sys.exit(f"FAIL: the session read as it comes answered other lines than it was sent in round {round_number}")
    return after


def bounds_the_service(stack):
    """The service's own memory, with as many sessions as it admits leaving 8 MiB each unread."""
    stack.up()
    c = stack.controller()
    expect(c.hello()[0] == 200, "a fresh service is greeted")
    programs = [{"name": "flood", "command": flood_command(FLOOD_TEXT, FLOOD_LINES), "env": {}},
                {"name": "echo", "command": "exec cat", "env": {}}]
    for owner in FLOODED:
        status, answer, _ = c.sync(owner, programs, lease_ms=60_000)
        expect(status == 200, f"{owner['athanor']} is synced", answer)

    answering = Answering(stack.base, c)
    answering.start()
    try:
        status, answer = c.open(FLOODED[0], "echo", key="read")
        expect(status == 200, "the session read as it comes is open", answer)
        reader = answer["session"]
        floods = []
        for index in range(SESSIONS - 1):
            owner = FLOODED[(index + 1) // 16]
            status, answer = c.open(owner, "flood", key=f"flood-{index}")
            if status != 200:
                print(f"the service admits {len(floods) + 1} sessions: the next open is answered {status} {answer}")
                break
            floods.append((owner, answer["session"]))
        expect(len(floods) * FLOOD_LINES * LINE_CHARGE > 2 * UNREAD_BOUND,
               f"{len(floods)} unread sessions of 8 MiB each are more than twice the unread bound", len(floods))

        beam = [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]]
        idle = group_memory(stack)
        allowed = allowance(len(floods) + 1)
        print(f"idle with {len(floods) + 1} silent sessions: the service leaf holds {idle['current'] // MIB} MiB, "
              f"its peak {idle['peak'] // MIB} MiB; the bound is that peak and {allowed // MIB} MiB "
              f"({allowed} bytes)")

        for owner, session in floods:
            status, answer = c.send(owner, session, ["go"])
            expect(status == 200 and answer["status"] == "running", "an unread session starts writing", answer)

        # The session read as it comes is read while the others write, and on
        # after every one has written all its lines and waits (its program's
        # last command), each of its rounds pushing the count past its bound
        # for the one holding most to drop.
        after, rounds = 0, 0
        deadline = time.monotonic() + 300
        while True:
            after = read_round(c, FLOODED[0], reader, after, rounds)
            rounds += 1
            waiting = [p for p in stack.pool_processes() if p["cmd"].startswith("sleep 3600")]
            if len(waiting) == len(floods) and rounds >= 8:
                break
            if time.monotonic() > deadline:
                sys.exit(f"FAIL: {len(floods) - len(waiting)} unread sessions still write after 300 s")
        after = read_round(c, FLOODED[0], reader, after, rounds)

        def settled():
            reads = []
            for owner, session in floods:
                status, answer = c.recv(owner, session, 0, 0)
                expect(status == 200 and answer["running"], "an unread session runs on and is answered", status)
                held = kept(answer, FLOOD_LINES, FLOOD_TEXT)
                if held is None:
                    return None
                reads.append(held)
            return reads if sum(k for _d, k in reads) * LINE_CHARGE <= UNREAD_BOUND else None

        reads = eventually(settled, "every unread session's lines to be in and the unread bound to hold", 60)
    finally:
        answering.stopped.set()
        answering.join()

    after_flood = group_memory(stack)
    container = imagesuite.read_counters(stack.exec(f"cat /sys/fs/cgroup/{ROLE_GROUP}/memory.events"), ("oom", "oom_kill"),
                                         "the backends role's memory.events")
    unread = sum(k for _d, k in reads) * LINE_CHARGE
    print(f"{len(floods)} unread sessions of {FLOOD_LINES * LINE_CHARGE // MIB} MiB: they keep {unread // MIB} MiB "
          f"together, {sum(d for d, _k in reads)} lines dropped; the service leaf holds "
          f"{after_flood['current'] // MIB} MiB, its peak {after_flood['peak'] // MIB} MiB "
          f"({(after_flood['peak'] - idle['peak']) // MIB} MiB past idle, {after_flood['peak'] - idle['peak']} bytes, "
          f"of the {allowed} allowed: {SHARED['byte_cost']} x ({UNREAD_BOUND} unread + {ANSWERING_BOUND} answering + "
          f"{len(floods) + 1} x {SHARED['keeper_read_copies']} x {SHARED['keeper_read_bytes']} keeper reads) + "
          f"{len(floods) + 1} x {SHARED['relay_queue_bytes']} relay queues); keeper events {after_flood['events']}, "
          f"container events {container}; {answering.asked} health asks, {rounds + 1} rounds read as they came")

    expect(rounds >= 8, f"the session read as it comes answered every line of its {rounds + 1} rounds, in order")
    expect(all(dropped > 0 for dropped, _kept in reads), "every unread session dropped its oldest", reads)
    expect(after_flood["peak"] <= idle["peak"] + allowed,
           f"the service leaf's peak stays within its idle peak and {allowed // MIB} MiB",
           {"idle_peak": idle["peak"], "peak": after_flood["peak"], "allowance": allowed})
    expect(imagesuite.no_kills(after_flood["events"]) and imagesuite.no_kills(container),
           "the kernel killed nothing in the container", {"keeper": after_flood["events"], "container": container})
    expect(beam and [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]] == beam,
           "the service runs on, the same release", beam)
    expect(not answering.failures and answering.asked > 0,
           "the service answers health and renewals throughout", answering.failures[:5])


def stops_a_flood(stack, label, env):
    """A person stops a program while it floods, its session taking as it does with `env`'s values to mask.

    The service's group rises over its idle peak by no more than the
    allowance of one session.
    """
    stack.up()
    c = stack.controller()
    expect(c.hello()[0] == 200, "a fresh service is greeted")
    owner = owner_of("stop")
    program = {"name": "flood", "command": endless_flood_command(FLOOD_TEXT), "env": env}
    status, answer, _ = c.sync(owner, [program], lease_ms=60_000)
    expect(status == 200, f"{owner['athanor']} is synced", answer)
    status, answer = c.open(owner, "flood", key="flood")
    expect(status == 200, "the flooding session is open", answer)
    session = answer["session"]
    idle = group_memory(stack)
    allowed = allowance(1)
    status, answer = c.send(owner, session, ["go"])
    expect(status == 200 and answer["status"] == "running", "the session starts writing", answer)

    def dropping():
        status, answer = c.recv(owner, session, 0, 0)
        expect(status == 200, "the flooding session is answered", status)
        return answer["dropped"] or None

    eventually(dropping, "the session to take past its bound, dropping its oldest", 60)
    expect(any(p["cmd"].startswith("yes") for p in stack.pool_processes()),
           "the program still floods when its stop is asked")
    status, answer = c.close(owner, session)
    expect(status == 200 and answer.get("status") == "closed", "the stop is answered", [status, answer])
    eventually(lambda: not stack.pool_processes(), "nothing of the program to outlive its stop")

    after = group_memory(stack)
    container = imagesuite.read_counters(stack.exec(f"cat /sys/fs/cgroup/{ROLE_GROUP}/memory.events"), ("oom", "oom_kill"),
                                         "the backends role's memory.events")
    rise = after["peak"] - idle["peak"]
    print(f"a stop while the program floods, its session {label}: the service leaf's idle peak "
          f"{idle['peak'] // MIB} MiB, its peak {after['peak'] // MIB} MiB ({rise // MIB} MiB past idle, {rise} bytes, "
          f"of the {allowed} allowed for one session); keeper events {after['events']}, container events {container}")
    expect(rise <= allowed, f"the service leaf's peak stays within its idle peak and {allowed // MIB} MiB",
           {"idle_peak": idle["peak"], "peak": after["peak"], "allowance": allowed})
    expect(imagesuite.no_kills(after["events"]) and imagesuite.no_kills(container),
           "the kernel killed nothing in the container", {"keeper": after["events"], "container": container})
    wait_healthy(stack.base)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: memory.py IMAGE")
    require_docker()
    stack = Stack("locus-backends-memory", sys.argv[1])
    try:
        bounds_each_program(stack)
        bounds_the_service(stack)
        stops_a_flood(stack, "taking as it comes", {})
        stops_a_flood(stack, f"masking {CREDENTIALS} credentials in every line",
                      {f"TOKEN_{i:03d}": f"credential-{i:03d}-{'k' * 20}" for i in range(CREDENTIALS)})
    finally:
        stack.down()


if __name__ == "__main__":
    main()
