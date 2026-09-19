#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The locus-builds container's memory limit holds its builds' bounds and the service itself.

Every build runs in a cgroup of its own, bounded at
LOCUS_BUILDS_MEMORY_BYTES (tests/builder-image/memory.py proves that
bound). What is not a build runs in the group cyfr-spawn keeps for itself,
`keeper`: cyfr-spawn, the locus release and the relays. Nothing bounds
that group but the container's own limit, so docker-compose.yml's limit
must hold LOCUS_BUILDS_MAX_CONCURRENT bounds and the most the service
takes, or a build the kernel kills for the container's limit is lost
without being over its own.

The service takes the most when it answers the largest result the wire
allows (`Cyfr.BuilderProtocol.max_output_bytes/0`): it holds the build's
output archive, the files unpacked from it, their base64 and the line that
carries them, all at once. This measures it, in one container, the kernel's
own high-water marks read after each step:

- idle, once the service answers health;
- one build answering a largest result;
- as many builds as the service runs at once, each holding memory close to
  its bound until it ends and each answering a largest result, together.

It prints every figure and fails unless every build answered its result
intact, each build's group stayed within its bound while coming close to
it, the kernel killed nothing for the container's limit, and the `keeper`
group's peak fits in what the container's limit leaves beside the
concurrent builds' bounds. The limit, the bound and the concurrency are
read from the running service, so the shipped defaults are what is judged;
settings named after the image are judged in their place, the service's
given to it as .env.locus gives them and the container's limits
(LOCUS_BUILDS_MEMORY_LIMIT, LOCUS_BUILDS_CPU_LIMIT) to compose as .env
gives them.

Usage: tests/builder-image/headroom.py IMAGE [LOCUS_BUILDS_NAME=VALUE]...
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stack import RELEASE_BIN, RELEASE_USER, WIRE, Stack, brief, expect, output_bytes, tincture  # noqa: E402

MIB = 1 << 20
# A little under the wire's bound on a result's outputs, index.html beside it.
LARGEST = WIRE["bounds"]["max_output_bytes"] - 4096
# How close to its bound a holding build must have come for the pair to count.
CLOSE = 0.85
# The settings docker-compose.yml interpolates, which the service never sees.
COMPOSE_SETTINGS = {"LOCUS_BUILDS_MEMORY_LIMIT", "LOCUS_BUILDS_CPU_LIMIT"}

# One line per sample: `keeper's memory.current|its anon|its file|the container's memory.current|uid:current:peak,...`.
SAMPLER = r"""
while :; do
  groups=""
  for d in /sys/fs/cgroup/spawn-*; do
    [ -d "$d" ] && groups="$groups${d##*spawn-}:$(cat "$d/memory.current" 2>/dev/null):$(cat "$d/memory.peak" 2>/dev/null),"
  done
  printf '%s|%s|%s|%s\n' "$(cat /sys/fs/cgroup/keeper/memory.current)" \
    "$(awk '$1 == "anon" {a = $2} $1 == "file" {f = $2} END {print a "|" f}' /sys/fs/cgroup/keeper/memory.stat)" \
    "$(cat /sys/fs/cgroup/memory.current)" "$groups"
  sleep 0.1
done
"""


def largest(hold_mib):
    """A tincture answering a largest result; with `hold_mib`, a daemon of its uid holds that much until the build's end."""
    holder = (f"setsid node -e 'const held = Buffer.alloc({hold_mib} * 1048576, 1); setTimeout(() => held[5], 3600000)' "
              "</dev/null >/dev/null 2>&1 &\nsleep 6\n") if hold_mib else ""
    return tincture(f"{holder}mkdir -p dist\nhead -c {LARGEST} /dev/urandom > dist/blob.bin\necho largest > dist/index.html\n")


class Sampler(threading.Thread):
    def __init__(self, container):
        super().__init__(daemon=True)
        self.process = subprocess.Popen(
            ["docker", "exec", container, "sh", "-c", SAMPLER], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.keeper = self.container = self.together = 0
        # The keeper group's anonymous and file pages at its largest sample.
        self.keeper_anon = self.keeper_file = 0
        self.groups = {}

    def run(self):
        for line in self.process.stdout:
            try:
                keeper, anon, file, container, groups = line.strip().split("|")
                if int(keeper) > self.keeper:
                    self.keeper, self.keeper_anon, self.keeper_file = int(keeper), int(anon), int(file)
                self.container = max(self.container, int(container))
                current = 0
                for entry in filter(None, groups.split(",")):
                    uid, now, peak = entry.split(":")
                    self.groups[int(uid)] = max(self.groups.get(int(uid), 0), int(peak or 0))
                    current += int(now or 0)
                self.together = max(self.together, current)
            except ValueError:
                continue

    def stop(self):
        self.process.kill()
        self.process.wait()


def mib(count):
    return f"{count / MIB:.0f} MiB"


def read(stack, path):
    return stack.exec(f"cat /sys/fs/cgroup/{path}").stdout.strip()


def events(stack, path):
    return {name: int(count) for name, count in (line.split() for line in read(stack, path).splitlines())}


def setting(stack, accessor):
    out = stack.exec(f"""{RELEASE_BIN} eval 'IO.puts("<<<#{{Locus.Config.{accessor}()}}>>>")'""", user=RELEASE_USER).stdout
    return int(out.split("<<<", 1)[1].split(">>>", 1)[0])


def builds(stack, sources):
    """Runs the builds together and answers each one's (status, terminal line)."""
    results = [None] * len(sources)

    def build(index):
        try:
            results[index] = stack.build(sources[index], "javascript", "tincture")
        except OSError as error:
            results[index] = (None, f"the builder gave no answer: {error!r}")

    threads = [threading.Thread(target=build, args=(index,)) for index in range(len(sources))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results


def main(image, settings):
    empty = tempfile.mkdtemp(prefix="cyfr-builder-headroom-")
    stack = Stack("cyfr-builder-headroom", image, empty)
    try:
        # The container's limits are compose's to read; the rest is the service's.
        for name in COMPOSE_SETTINGS & settings.keys():
            os.environ[name] = settings.pop(name)
        with open(os.path.join(stack.project_dir, ".env.locus"), "w") as out:
            out.writelines(f"{name}={value}\n" for name, value in settings.items())
        stack.up()
        limit = read(stack, "memory.max")
        expect(limit.isdigit(), "the container has a memory limit of its own", limit)
        limit = int(limit)
        bound, concurrent = setting(stack, "memory_bytes"), setting(stack, "max_concurrent")
        headroom = limit - concurrent * bound
        release = [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]]
        print(f"the container's limit is {mib(limit)}; the service runs {concurrent} builds at once, each bounded at {mib(bound)}: "
              f"{mib(headroom)} is left for the service")
        expect(headroom > 0, "the container's limit is more than its concurrent builds' bounds", {"limit": limit, "bounds": concurrent * bound})

        time.sleep(3)
        idle = int(read(stack, "keeper/memory.peak"))
        print(f"idle: the keeper group holds {mib(int(read(stack, 'keeper/memory.current')))}, its peak {mib(idle)}")

        sampler = Sampler(stack.container)
        sampler.start()
        [(status, answer)] = builds(stack, [largest(0)])
        expect(status == 200 and len(output_bytes(answer, "blob.bin") or b"") == LARGEST,
               f"one build answers a largest result, {mib(LARGEST)}, intact", brief(answer))
        single = int(read(stack, "keeper/memory.peak"))
        print(f"one largest result: the keeper group's peak {mib(single)}")

        # What a holding build may hold beside its output, its home's pages
        # and the rest of its tree, and stay within its bound.
        hold_mib = (bound - LARGEST) // MIB - 128
        expect(hold_mib > 0, "the bound leaves room to hold memory beside a largest result", {"bound": bound})
        results = builds(stack, [largest(hold_mib)] * concurrent)
        time.sleep(1)
        sampler.stop()
        for status, answer in results:
            expect(status == 200 and len(output_bytes(answer, "blob.bin") or b"") == LARGEST,
                   f"a build holding {hold_mib} MiB beside a sibling doing the same answers its largest result intact", brief(answer))

        keeper = int(read(stack, "keeper/memory.peak"))
        container = int(read(stack, "memory.peak") or 0)
        container_events, keeper_events = events(stack, "memory.events"), events(stack, "keeper/memory.events")
        peaks = sorted(sampler.groups.values(), reverse=True)[:concurrent]
        print(f"{concurrent} largest results together: the keeper group's peak {mib(keeper)} (sampled at most {mib(sampler.keeper)}, "
              f"{mib(sampler.keeper_anon)} of it anonymous and {mib(sampler.keeper_file)} file pages); "
              f"the builds' groups peaked at {[mib(peak) for peak in peaks]}, {mib(sampler.together)} together when sampled; "
              f"the container's peak {mib(container)} (sampled at most {mib(sampler.container)})")
        print(f"container events {container_events}; keeper events {keeper_events}")
        print(f"the service's need is {mib(keeper)} of the {mib(headroom)} the limit leaves it: "
              f"{mib(headroom - keeper)} to spare, {keeper / headroom:.0%} used")

        expect(len(peaks) == concurrent and all(CLOSE * bound <= peak <= bound for peak in peaks),
               f"each holding build's group came within {1 - CLOSE:.0%} of its bound and never passed it", sampler.groups)
        expect(container_events.get("oom", 0) == 0 and container_events.get("oom_kill", 0) == 0,
               "the kernel killed nothing for the container's limit", container_events)
        expect(release and [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]] == release
               and not json.loads(subprocess.run(["docker", "inspect", stack.container], capture_output=True, text=True).stdout)[0]["State"]["OOMKilled"],
               "the release and the container were not touched")
        expect(keeper <= headroom, "the service's peak fits in what the limit leaves beside the concurrent builds' bounds",
               {"keeper_peak": keeper, "headroom": headroom})
        expect(stack.pool_processes() == [] and stack.homes() == [], "no process of a build uid and no home is left",
               [stack.pool_processes(), stack.homes()])
    finally:
        stack.down()
        shutil.rmtree(empty, ignore_errors=True)


if __name__ == "__main__":
    given = dict(argument.split("=", 1) for argument in sys.argv[2:] if "=" in argument)
    if len(sys.argv) < 2 or len(given) != len(sys.argv) - 2 or not all(name.startswith("LOCUS_BUILDS_") for name in given):
        sys.exit(__doc__)
    main(sys.argv[1], given)
