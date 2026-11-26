#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The builds role's service sits outside the pool's work, and its own memory is bounded by its count.

Every build runs in a cgroup of its own, bounded at a build's bound, which
the keeper sets on every build (Prima.LocusPool; tests/builder-image/memory.py
proves that bound), inside the builds role's group in the pool's work,
`work/rest/builds`, under rest's bound, which the keeper writes from the
machine's memory (Prima.LocusPool). What is not a build runs in the role's
leaf, `service/builds`, outside work: the locus release serving the role
and its builds' relays. No memory bound holds that leaf; what bounds it is
what the service counts.

The service never holds a build's output whole: it reads the build's
archive a relay frame at a time and sends each piece on as an output line
before it reads the next, and what it holds of a build's output is
counted (`Locus.Output`). So the largest
result the wire allows (`Prima.BuilderProtocol.max_output_bytes/0`)
raises the service's memory by no more than its allowance, `allowance/0`,
computed from the role table as stack.py reads it (`Prima.LocusRoles`,
`Locus.Output`'s table): the factor of resident bytes to a byte held times
the bound and the build's keeper read, and the kernel's queues of the
build's relay and of the answer's connection, while a reader takes it.
This measures it, in one container, the kernel's own high-water marks read
after each step:

- idle, once the service answers health;
- one build answering a largest result;
- as many builds as the service runs at once, each holding memory close to
  its bound until it ends and each answering a largest result, together.

It prints every figure, the allowance beside the rise, and fails unless
every build answered its result intact, one largest result raised the
`service/builds` leaf's peak over idle by no more than its allowance, each
build's group stayed within its bound while coming close to it, and the
kernel killed nothing for rest's bound. The concurrency is read from the
running service, and the bound is the one the keeper sets on every build,
so the shipped defaults are what is judged;
settings named after the image are judged in their place, the service's
given to it as .env.locus gives them and the role's processors
(LOCUS_BUILDS_CPU_LIMIT) to compose as .env gives them.

Usage: tests/builder-image/headroom.py IMAGE [LOCUS_BUILDS_NAME=VALUE]...
"""

import json
import os
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stack import (  # noqa: E402
    RELEASE, RELEASE_USER, ROLE, WIRE, Stack, brief, expect, output_bytes, release_eval, tincture,
)
# stack puts tests/, which holds the shared plumbing, on the path.
import imagesuite  # noqa: E402

MIB = 1 << 20
# A little under the wire's bound on a result's outputs, index.html beside it.
LARGEST = WIRE["bounds"]["max_output_bytes"] - 4096
# How close to its bound a holding build must have come for the pair to count.
CLOSE = 0.85
# The builds role's own memory and the release's shared figures
# (Prima.LocusRoles).
MEMORY, SHARED = ROLE["memory"], RELEASE["memory"]
# The settings docker-compose.yml interpolates, which the service never sees.
COMPOSE_SETTINGS = {"LOCUS_BUILDS_CPU_LIMIT"}

# The builds role's leaf, which holds its process and its relays; its group
# in work, which holds each build's; and rest, whose bound is over them.
SERVICE = imagesuite.service_leaf(ROLE)
SPAWNS = imagesuite.work_group(ROLE)
BOUND = imagesuite.bound_group(ROLE)

# One line per sample: `service's memory.current|its anon|its file|rest's memory.current|uid:current:peak,...`.
SAMPLER = r"""
while :; do
  groups=""
  for d in %(spawns)s/keeper-*; do
    [ -d "$d" ] && groups="$groups${d##*keeper-}:$(cat "$d/memory.current" 2>/dev/null):$(cat "$d/memory.peak" 2>/dev/null),"
  done
  printf '%%s|%%s|%%s|%%s\n' "$(cat %(service)s/memory.current)" \
    "$(awk '$1 == "anon" {a = $2} $1 == "file" {f = $2} END {print a "|" f}' %(service)s/memory.stat)" \
    "$(cat %(bound)s/memory.current)" "$groups"
  sleep 0.1
done
""" % {"spawns": SPAWNS, "service": SERVICE, "bound": BOUND}


def allowance():
    """What one largest result may raise the service's group by over idle.

    The factor of resident bytes to a byte held times what the service
    counts and the one keeper read its build's spawn holds, at most its
    copies at once; beside them the kernel's queue of the build's relay and
    the send queue of the connection the result is answered on. A service
    that held the result whole took several times the result itself.
    """
    held = MEMORY["answering"] + SHARED["keeper_read_bytes"] * SHARED["keeper_read_copies"]
    return int(SHARED["byte_cost"] * held) + SHARED["relay_queue_bytes"] + SHARED["socket_queue_bytes"]


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
    return imagesuite.read_output(stack.exec(f"cat {path}"), f"the cgroup file {path}").strip()


def events(stack, path):
    return imagesuite.read_counters(stack.exec(f"cat {path}"), ("oom", "oom_kill"), f"the cgroup events of {path}")


def setting(stack, accessor):
    out = imagesuite.read_output(
        stack.exec(release_eval(f'IO.puts("<<<#{{Locus.Config.{accessor}()}}>>>")'), user=RELEASE_USER),
        f"the release's Locus.Config.{accessor}()")
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
    # Registered for removal at exit as soon as it exists, so a signal
    # before the `try` leaves no directory behind.
    empty = imagesuite.temporary_directory("locus-builds-headroom-")
    stack = Stack("locus-builds-headroom", image, empty)
    try:
        # The role's processors are compose's to read; the rest is the service's.
        for name in COMPOSE_SETTINGS & settings.keys():
            os.environ[name] = settings.pop(name)
        with open(os.path.join(stack.project_dir, ".env.locus"), "w") as out:
            out.writelines(f"{name}={value}\n" for name, value in settings.items())
        stack.up()
        expect(read(stack, f"{SERVICE}/memory.max") == "max", "the builds role's service has no memory bound of its own",
               read(stack, f"{SERVICE}/memory.max"))
        limit = read(stack, f"{BOUND}/memory.max")
        expect(limit.isdigit(), "rest, over the builds, has a memory bound", limit)
        limit = int(limit)
        bound, concurrent = imagesuite.BUILD_CAP_BYTES, setting(stack, "max_concurrent")
        release = [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]]
        print(f"rest's bound is {mib(limit)}; the service runs {concurrent} builds at once, each bounded at {mib(bound)}")
        expect(limit >= concurrent * bound, "rest holds the concurrent builds' bounds on this machine",
               {"limit": limit, "bounds": concurrent * bound})

        time.sleep(3)
        idle = int(read(stack, f"{SERVICE}/memory.peak"))
        print(f"idle: the service leaf holds {mib(int(read(stack, f'{SERVICE}/memory.current')))}, its peak {mib(idle)}")

        sampler = Sampler(stack.container)
        sampler.start()
        [(status, answer)] = builds(stack, [largest(0)])
        expect(status == 200 and len(output_bytes(answer, "blob.bin") or b"") == LARGEST,
               f"one build answers a largest result, {mib(LARGEST)}, intact", brief(answer))
        single = int(read(stack, f"{SERVICE}/memory.peak"))
        allowed = allowance()
        print(f"one largest result: the service leaf's peak {mib(single)}, {mib(single - idle)} over idle "
              f"({single - idle} bytes) of the {allowed} allowed: {SHARED['byte_cost']} x ({MEMORY['answering']} "
              f"answering + {SHARED['keeper_read_copies']} x {SHARED['keeper_read_bytes']} keeper read) + "
              f"{SHARED['relay_queue_bytes']} relay queue + {SHARED['socket_queue_bytes']} send queue")
        expect(single - idle <= allowed,
               f"one largest result raises the service's memory by no more than {mib(allowed)}, "
               "since the service never holds it whole", {"idle": idle, "peak": single, "allowance": allowed})

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

        keeper = int(read(stack, f"{SERVICE}/memory.peak"))
        container = int(read(stack, f"{BOUND}/memory.peak"))
        container_events, keeper_events = events(stack, f"{BOUND}/memory.events"), events(stack, f"{SERVICE}/memory.events")
        peaks = sorted(sampler.groups.values(), reverse=True)[:concurrent]
        print(f"{concurrent} largest results together: the service leaf's peak {mib(keeper)} (sampled at most {mib(sampler.keeper)}, "
              f"{mib(sampler.keeper_anon)} of it anonymous and {mib(sampler.keeper_file)} file pages); "
              f"the builds' groups peaked at {[mib(peak) for peak in peaks]}, {mib(sampler.together)} together when sampled; "
              f"rest's peak {mib(container)} (sampled at most {mib(sampler.container)})")
        print(f"rest's events {container_events}; the service's events {keeper_events}")

        expect(len(peaks) == concurrent and all(CLOSE * bound <= peak <= bound for peak in peaks),
               f"each holding build's group came within {1 - CLOSE:.0%} of its bound and never passed it", sampler.groups)
        expect(imagesuite.no_kills(container_events) and imagesuite.no_kills(keeper_events),
               "the kernel killed nothing for rest's bound or in the service", [container_events, keeper_events])
        expect(release and [p["pid"] for p in stack.processes() if "beam.smp" in p["cmd"]] == release
               and not json.loads(subprocess.run(["docker", "inspect", stack.container], capture_output=True, text=True).stdout)[0]["State"]["OOMKilled"],
               "the release and the container were not touched")
        expect(stack.pool_processes() == [] and stack.homes() == [], "no process of a build uid and no home is left",
               [stack.pool_processes(), stack.homes()])
    finally:
        stack.down()
        imagesuite.remove_directory(empty)


if __name__ == "__main__":
    given = dict(argument.split("=", 1) for argument in sys.argv[2:] if "=" in argument)
    if len(sys.argv) < 2 or len(given) != len(sys.argv) - 2 or not all(name.startswith("LOCUS_BUILDS_") for name in given):
        sys.exit(__doc__)
    main(sys.argv[1], given)
