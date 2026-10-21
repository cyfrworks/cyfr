#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Each directory a guide's per-athanor storage diagram draws directly under
an athanor's tree is a tenant root.

Usage: python3 -I scripts/ci/storage-diagrams.py [--layout FILE] GUIDE...
       python3 -I scripts/ci/storage-diagrams.py [--layout FILE] --roster

The roster is Arca.Storage.tenant_roots/0, read from the source that builds
it (FILE, by default apps/arca/lib/arca/storage.ex): the root of every
`@layout` row whose class the `@tenant_roots` comprehension selects.
`--roster` prints it, one root a line.

A diagram line is a box-drawing branch (`├──` or `└──`) and a name; its
parent is the nearest line above it, in the same fenced block, whose branch
sits further left. An athanor's tree is a node under `athanors/`, or a node
spelled `athanors/<id>/` itself. Every node drawn directly under one must be
`<root>/` for a tenant root. A source whose `@layout` or comprehension this
cannot read, or guides that draw no athanor's tree with anything under it,
fail too: the check would check nothing.
"""

import re
import sys

LAYOUT = "apps/arca/lib/arca/storage.ex"
BRANCH = re.compile(r"^(?P<lead>[ │|]*)(?P<branch>[├└]──)[─ ]*(?P<name>(?:<[^>]*>|[^\s#<])+)")
ATHANOR = re.compile(r"(?:^|/)athanors/[^/]+/$")


def die(message):
    print(f"::error::{message}")
    sys.exit(1)


def roster(path):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    layout = re.search(r"^  @layout \[\n(.*?)^  \]$", text, re.M | re.S)
    selects = re.search(
        r"@tenant_roots for \{root, class, [^}]*\} <- @layout,\s*class in \[([^\]]*)\],\s*do: root",
        text,
    )
    if layout is None or selects is None:
        die(f"{path}: no @layout table or no @tenant_roots comprehension over it to read the tenant roots from")
    classes = re.findall(r":([a-z_]+)", selects.group(1))
    rows = re.findall(r'^\s*\{"([a-z_]+)", :([a-z_]+),', layout.group(1), re.M)
    roots = [root for root, cls in rows if cls in classes]
    if not classes or not roots:
        die(f"{path}: the @layout table yields no tenant root")
    return roots


def phantoms(path, roots):
    """The diagram lines under an athanor's tree in PATH that name no tenant
    root, and how many athanor trees drew anything."""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    bad, trees, stack, drawn = [], 0, [], set()
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            stack = []
            continue
        m = BRANCH.match(line)
        if m is None:
            continue
        col, name = len(m["lead"]), m["name"]
        while stack and stack[-1][0] >= col:
            stack.pop()
        parent = stack[-1] if stack else None
        if parent is not None and parent[2]:
            if parent[3] not in drawn:
                drawn.add(parent[3])
                trees += 1
            if not (name.endswith("/") and name[:-1] in roots):
                bad.append(f"{path}:{n}:{line}")
        athanor = name.endswith("/") and (
            ATHANOR.search(name) is not None or (parent is not None and parent[1] == "athanors/")
        )
        stack.append((col, name, athanor, n))
    return bad, trees


def main(argv):
    layout = LAYOUT
    if len(argv) >= 2 and argv[0] == "--layout":
        layout, argv = argv[1], argv[2:]
    roots = roster(layout)
    if argv == ["--roster"]:
        print("\n".join(roots))
        return 0
    if not argv or argv[0].startswith("-"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 64
    bad, trees = [], 0
    for path in argv:
        b, t = phantoms(path, roots)
        bad += b
        trees += t
    if trees == 0:
        die(f"no guide draws an athanor's storage tree: the check would check nothing ({' '.join(argv)})")
    if bad:
        print(f"::error::guide tree diagrams name a scope that is not a tenant root ({', '.join(roots)}; Arca.Storage.tenant_roots/0)")
        print("\n".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
