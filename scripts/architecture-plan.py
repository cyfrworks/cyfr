#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Check the implementation plan's file ledger against a repository.

The plan is Markdown with numbered level-two sections ("## 11. ..."). Section
11 holds the target sequence as one backticked line of target IDs joined by
" → " (U+2192), and one "### <ID> — <title>" heading (em dash) per target.
Section 16 holds two ```json blocks: first the write-permission map
{"path": ["TARGET", ...]}, then the N0 move map {"source": "destination"}.
A target's projection is every path whose owner list names it.

  --check                   the ledger parses and fits the tracked tree
  --target ID --range A..B  changed paths outside ID's projection and the
                            directories that projection already occupies
  --disjoint A B            paths both projections hold, integration files aside

Exit 0 when clean, 1 on a finding, 2 on a usage error.
"""

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys

DEFAULT_PLAN = "docs/plans/end-state-architecture.md"
MOVE_TARGET = "N0"

# Every target's integration may write these, so they never decide whether
# two targets can run side by side.
INTEGRATION_ONLY = frozenset({".formatter.exs", "README.md", "integration-guide.md",
                              "apps/cyfr/test/cyfr/docs_drift_test.exs", DEFAULT_PLAN})

SECTION = re.compile(r"^## (\d+)\. ", re.M)
SEQUENCE = re.compile(r"`(\w+(?: → \w+)+)`")
HEADING = re.compile(r"^### (\S+) — ", re.M)
JSON_BLOCK = re.compile(r"^```json\n(.*?)^```", re.M | re.S)


class Plan:
    def __init__(self, text):
        self.findings = []
        self.sequence, self.headings = [], set()
        self.permissions, self.moves = None, None

        bodies = sections(text)
        if "11" not in bodies:
            self.findings.append("the plan has no section 11")
        else:
            lines = SEQUENCE.findall(bodies["11"])
            if len(lines) != 1:
                self.findings.append(f"section 11 has {len(lines)} target sequences; expected one")
            else:
                self.sequence = lines[0].split(" → ")
            self.headings = set(HEADING.findall(bodies["11"]))

        blocks = JSON_BLOCK.findall(bodies.get("16", ""))
        if len(blocks) < 2:
            self.findings.append(
                f"section 16 has {len(blocks)} json blocks; expected the permission map "
                "and the move map"
            )
            return
        self.permissions = self.load(blocks[0], "permission map", list)
        self.moves = self.load(blocks[1], "move map", str)

    def load(self, block, name, kind):
        try:
            value = json.loads(block, object_pairs_hook=unique_keys)
        except ValueError as error:
            self.findings.append(f"malformed {name}: {error}")
            return None
        if not isinstance(value, dict) or not all(
            isinstance(v, kind) and (kind is str or all(isinstance(o, str) for o in v))
            for v in value.values()
        ):
            self.findings.append(f"malformed {name}: expected an object of {kind.__name__} values")
            return None
        return value

    def known(self, target):
        return target in self.sequence or any(target in o for o in self.permissions.values())

    def projection(self, target):
        return {path for path, owners in self.permissions.items() if target in owners}


def unique_keys(pairs):
    # json.loads keeps the last of two equal keys; two ledger rows for one
    # path are a defect, not a merge.
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"duplicate key {key!r}")
        seen[key] = value
    return seen


def sections(text):
    """Each numbered level-two section's body, keyed by its number."""
    marks = list(SECTION.finditer(text))
    ends = [m.start() for m in marks[1:]] + [len(text)]
    return {m.group(1): text[m.end() : end] for m, end in zip(marks, ends)}


def git(repo, *args):
    """The NUL-separated paths a git command prints; a failed command is a usage error."""
    result = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"git {' '.join(args)}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return [path for path in result.stdout.split("\0") if path]


def check(plan, tracked):
    """The findings that fail the ledger, and the future inputs that do not."""
    findings, future = [], []
    if not tracked:
        findings.append("the repository tracks no file; nothing was checked")

    seen = set()
    for target in plan.sequence:
        if target in seen:
            findings.append(f"{target} appears more than once in the sequence")
            continue
        seen.add(target)
        if target not in plan.headings:
            findings.append(f"{target} is in the sequence and has no '### {target} —' section")
        if not plan.projection(target):
            findings.append(f"{target} is in the sequence and owns no path in the permission map")

    if MOVE_TARGET in plan.sequence:
        before = plan.sequence[: plan.sequence.index(MOVE_TARGET)]
    else:
        before = []
        if plan.moves:
            findings.append(f"{MOVE_TARGET} is not in the sequence, so no move can be placed")

    claimed = {}
    for source, destination in plan.moves.items():
        if destination in claimed:
            findings.append(
                f"move destination {destination} is claimed by {claimed[destination]} and {source}"
            )
        claimed.setdefault(destination, source)
        if destination in tracked:
            findings.append(f"move destination {destination} already exists before {MOVE_TARGET}")
        if source not in tracked:
            producers = [o for o in plan.permissions.get(source, []) if o in before]
            if producers:
                future.append(f"future input: {source} (produced by {', '.join(producers)})")
            else:
                findings.append(
                    f"move source {source} does not exist and no target before "
                    f"{MOVE_TARGET} produces it"
                )
    return findings, future


def outside(plan, target, changed):
    """Changed paths neither in the projection nor beside a path it holds."""
    owned = plan.projection(target)
    # Every target may write the integration files, so holding one claims
    # no directory: owning README.md does not make the root the target's.
    directories = {posixpath.dirname(path) for path in owned - INTEGRATION_ONLY}
    return sorted(
        p for p in set(changed) if p not in owned and posixpath.dirname(p) not in directories
    )


def shared(plan, a, b):
    return sorted((plan.projection(a) & plan.projection(b)) - INTEGRATION_ONLY)


def arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=".", help="the repository checkout (default: .)")
    parser.add_argument("--plan", help=f"the plan (default: REPO/{DEFAULT_PLAN})")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="validate the ledger")
    mode.add_argument("--target", metavar="ID", help="list changed paths outside ID's projection")
    mode.add_argument("--disjoint", nargs=2, metavar=("A", "B"), help="compare two projections")
    parser.add_argument("--range", metavar="A..B", help="the commit range for --target")
    args = parser.parse_args(argv)
    if args.target is not None and (not args.range or ".." not in args.range):
        parser.error("--target needs --range A..B")
    if args.target is None and args.range is not None:
        parser.error("--range applies to --target alone")
    return parser, args


def main(argv):
    parser, args = arguments(argv)
    path = args.plan or os.path.join(args.repo, DEFAULT_PLAN)
    try:
        with open(path, encoding="utf-8") as handle:
            plan = Plan(handle.read())
    except OSError as error:
        parser.error(f"cannot read the plan: {error}")

    if args.check:
        findings, future = plan.findings, []
        if plan.permissions is not None and plan.moves is not None:
            more, future = check(plan, set(git(args.repo, "ls-files", "-z")))
            findings = findings + more
        for line in future:
            print(line)
        for line in findings:
            print(f"error: {line}")
        if findings:
            return 1
        print(
            f"ok: {len(plan.permissions)} keys, {len(plan.moves)} moves, "
            f"{len(plan.sequence)} targets, {len(future)} future inputs"
        )
        return 0

    if plan.permissions is None:
        for line in plan.findings:
            print(f"error: {line}")
        return 1

    targets = [args.target] if args.target is not None else args.disjoint
    unknown = [t for t in targets if not plan.known(t)]
    if unknown:
        parser.error(f"unknown target {', '.join(unknown)}")

    if args.target is not None:
        # Without --no-renames a move lists its destination alone, and the
        # deleted source escapes the check.
        changed = git(args.repo, "diff", "--no-renames", "--name-only", "-z", args.range)
        stray = outside(plan, args.target, changed)
        for line in stray:
            print(line)
        if stray:
            return 1
        print(f"ok: {len(changed)} changed paths inside {args.target}'s projection")
        return 0

    common = shared(plan, *args.disjoint)
    for line in common:
        print(line)
    if common:
        return 1
    print(f"disjoint: {args.disjoint[0]} and {args.disjoint[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
