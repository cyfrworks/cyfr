# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""The nightly stage's two reports, from what its suite rows left in the
stage's log directory (scripts/stages.tsv):

    python3 -I scripts/lib/nightly.py flakes LOGDIR
    python3 -I scripts/lib/nightly.py weights LOGDIR

flakes compares each adapter's two whole-suite invocations, the rows
<adapter>-1 and <adapter>-2, and prints one line per test that failed in
either: its verdict, the adapter, the app, the test and the runs it failed
in. Its evidence is what the partition runner leaves: each row's log (the
runner's output: `==> partition i/N` blocks, a `partition exited N` line
for a partition that did not exit 0, the run directory it kept, and the
heavy-check frame's `_EXIT=` line), and, in that run directory, each
partition's assigned files (assign/p<i>) and its log (p<i>.log, where Mix
heads each umbrella app's part with `==> <app>`, lists its failures as
`N) test NAME (MODULE)` with the test's file under it, named from the
umbrella's root as the assignment names it, and ends it with the app's
`Result:` line). A partition completed when it exited 0, or 2
(`mix test`'s status for test failures alone), and every app with an
assigned file has its `Result:` line. A test passed in an invocation only
when the partition that ran its file completed and the test is not among
its app's failures there. The verdicts:
    failing   it failed in both invocations;
    flaky     it failed in one and passed in the other;
    unknown   anything else: a partition that did not complete proves
              nothing about its tests, and an app whose `Result:` line
              shows exclusions in one invocation and not in the other
              makes every test of its unknown, since an exclusion count
              cannot be attributed to a test.

weights applies CONTRIBUTING.md's recipe to the two SQLite rows' timings
(timings-1 and timings-2): each file's larger `elixir
scripts/test-timings.exs weights` value, sorted by path in byte order
under the tracked table's header. It writes LOGDIR/test-partition-
weights.tsv, never the tracked table, and prints how many rows differ
from scripts/test-partition-weights.tsv.
"""

import os
import re
import subprocess
import sys

ADAPTERS = ("sqlite", "postgres")
HEADER = re.compile(r"^\s+\d+\) test (.+) \((.+)\)$")
FILE = re.compile(r"^\s+(\S+_test\.exs):\d+")
EXCLUDED = re.compile(r", (\d+) excluded")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()
    except OSError:
        return None


class Invocation:
    """One suite row: each partition's files, completion, failures and exclusions."""

    def __init__(self, logdir, row):
        self.row = row
        self.partitions = []
        lines = read(os.path.join(logdir, row + ".log")) or []
        run_dir, exits, current = None, {}, None
        for line in lines:
            m = re.match(r"^==> partition (\d+)/\d+$", line)
            if m:
                current = int(m.group(1))
                exits.setdefault(current, 0)
                continue
            m = re.match(r"^\s+partition exited (\d+)", line)
            if m and current is not None:
                exits[current] = int(m.group(1))
                continue
            m = re.match(r"^==> logs and disposable resources kept: (.+)$", line)
            if m:
                run_dir = m.group(1).strip()
        for index, exit_status in sorted(exits.items()):
            self.partitions.append(partition(run_dir, index, exit_status))

    def failures(self):
        """Each failed test, (app, NAME (MODULE)), with the file it was in."""
        found = {}
        for part in self.partitions:
            found.update(part["failures"])
        return found

    def holding(self, path):
        return next((part for part in self.partitions if path in part["files"]), None)


def partition(run_dir, index, exit_status):
    files, failures, results, exclusions = set(), {}, set(), {}
    log = None
    if run_dir:
        try:
            with open(os.path.join(run_dir, "assign", "p%d" % index), "rb") as handle:
                files = {f.decode("utf-8", "surrogateescape") for f in handle.read().split(b"\0") if f}
        except OSError:
            files = set()
        log = read(os.path.join(run_dir, "p%d.log" % index))
    app, pending = None, None
    for line in log or []:
        m = re.match(r"^==> (\S+)$", line)
        if m:
            app, pending = m.group(1), None
            continue
        m = HEADER.match(line)
        if m and app:
            pending = (app, "%s (%s)" % (m.group(1), m.group(2)))
            failures[pending] = None
            continue
        m = FILE.match(line)
        if m and pending:
            failures[pending] = m.group(1)
            pending = None
            continue
        if line.startswith("Result:") and app:
            results.add(app)
            m = EXCLUDED.search(line)
            exclusions[app] = bool(m and int(m.group(1)) > 0)
    apps = {f.split("/")[1] for f in files if f.startswith("apps/") and f.count("/") >= 2}
    complete = bool(log is not None and files and exit_status in (0, 2) and apps <= results)
    return {"files": files, "failures": failures, "complete": complete, "exclusions": exclusions}


def verdict(test, path, failed, other):
    """failing, flaky or unknown for a test the run failed did fail."""
    if test in other.failures():
        return "failing"
    app = test[0]
    here, there = failed.holding(path) if path else None, other.holding(path) if path else None
    if not here or not there or not there["complete"]:
        return "unknown"
    if here["exclusions"].get(app, False) != there["exclusions"].get(app, False):
        return "unknown"
    return "flaky"


def flakes(logdir):
    lines = []
    for adapter in ADAPTERS:
        first, second = (Invocation(logdir, "%s-%d" % (adapter, n)) for n in (1, 2))
        seen = set()
        for failed, other in ((first, second), (second, first)):
            for test, path in sorted(failed.failures().items(), key=lambda kv: kv[0]):
                if test in seen:
                    continue
                seen.add(test)
                runs = [run.row for run in (first, second) if test in run.failures()]
                lines.append("%s\t%s\t%s\t%s\tfailed in %s" % (
                    verdict(test, path, failed, other), adapter, test[0], test[1], " and ".join(runs)))
    print("\n".join(sorted(lines)) if lines else "no test failed in a nightly suite run")


def weights(logdir, root="."):
    merged = {}
    for n in (1, 2):
        out = subprocess.run(["elixir", "scripts/test-timings.exs", "weights", os.path.join(logdir, "timings-%d" % n)],
                             cwd=root, check=True, capture_output=True, text=True).stdout
        for line in out.splitlines():
            seconds, _, path = line.partition("\t")
            if path and (path not in merged or float(seconds) > merged[path][0]):
                merged[path] = (float(seconds), seconds)
    tracked_lines = read(os.path.join(root, "scripts", "test-partition-weights.tsv")) or []
    header = [line for line in tracked_lines if line.startswith("#")]
    tracked = {}
    for line in tracked_lines:
        if line and not line.startswith("#"):
            seconds, _, path = line.partition("\t")
            tracked[path] = seconds
    rows = ["%s\t%s" % (merged[path][1], path) for path in sorted(merged, key=lambda p: p.encode())]
    with open(os.path.join(logdir, "test-partition-weights.tsv"), "w") as handle:
        handle.write("\n".join(header + rows) + "\n")
    regenerated = {row.split("\t")[1]: row.split("\t")[0] for row in rows}
    differ = sum(1 for path in set(tracked) | set(regenerated) if tracked.get(path) != regenerated.get(path))
    print("%d rows differ from scripts/test-partition-weights.tsv" % differ)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("flakes", "weights"):
        sys.exit("usage: python3 -I scripts/lib/nightly.py flakes|weights LOGDIR")
    (flakes if sys.argv[1] == "flakes" else weights)(sys.argv[2])
