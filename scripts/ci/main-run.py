#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Read the push runs on main that cover a commit, once, after a merge:

    python3 -I scripts/ci/main-run.py [-n] [COMMIT]

COMMIT is a commit on origin's main, origin/main's head by default, after
fetching main from origin. For each workflow the commit's tree runs on a
push to main, the run that covers it is the push run on main whose head is
the commit or its nearest descendant: a waiting push run gives way to a
newer push's, so a merge's run is often a later commit's. A cancelled run
covers nothing while another run does. One line per workflow says what its
covering run shows:

  green                      the run passed
  running                    the run is queued or in progress
  no run yet                 no run covers the commit, and none of its
                             push's runs has been made
  not run                    the commit's push, or a later one, made runs
                             and this workflow's path filter left it out
  red, rerun started         the run failed on its first attempt, and its
                             failed jobs were rerun (a cancelled run is
                             rerun whole)
  red twice                  the run failed on a rerun, which is never
                             rerun again: the caller opens a regression job

A run already on a later attempt is never rerun, so a second read of the
same state starts nothing; -n reads and starts nothing, saying what a read
would rerun. Nothing here waits: a caller reads again later.

Exit status, the most urgent line's: 0 every workflow green or not run;
2 one still running or with no run yet; 3 a rerun started (with -n, one
due); 4 one red twice; 1 when git or gh could not be read or a rerun could
not be started; 64 for a usage error or a commit not on origin's main.
"""
import json
import subprocess
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone

import yaml

GREEN, ERROR, WAIT, RERUN, RED_TWICE, USAGE = 0, 1, 2, 3, 4, 64
# The exit status is the most urgent line's.
URGENCY = [GREEN, WAIT, RERUN, ERROR, RED_TWICE]
PASSED = {"success", "skipped", "neutral"}


class Unreadable(Exception):
    pass


def run(*argv, cwd=None):
    done = subprocess.run(argv, capture_output=True, text=True, cwd=cwd)
    if done.returncode != 0:
        raise Unreadable(f"{' '.join(argv[:3])}: {(done.stderr or done.stdout).strip()}")
    return done.stdout


def git(*args):
    return run("git", *args)


def on_push_to_main(spec):
    """Whether a workflow's triggers include a push to main."""
    on = spec.get(True, spec.get("on")) if isinstance(spec, dict) else None
    if on == "push" or (isinstance(on, list) and "push" in on):
        return True
    if not isinstance(on, dict) or "push" not in on:
        return False
    push = on["push"] or {}
    branches, ignored = push.get("branches"), push.get("branches-ignore")
    if branches is None and ignored is None:
        # Tags alone run on no branch push.
        return "tags" not in push and "tags-ignore" not in push
    if branches is not None:
        return "main" in branches
    return "main" not in ignored


def workflows(commit):
    """(path, name) of each workflow the commit's tree runs on a push to main."""
    out = []
    for path in git("ls-tree", "--name-only", commit, ".github/workflows/").split():
        if not path.endswith((".yml", ".yaml")):
            continue
        spec = yaml.safe_load(git("show", f"{commit}:{path}"))
        if on_push_to_main(spec):
            out.append((path, (spec.get("name") if isinstance(spec, dict) else None) or path))
    return out


def push_runs(root, since):
    """Every push run on main made since `since`, of every workflow."""
    query = urllib.parse.urlencode({"branch": "main", "event": "push", "created": f">={since}", "per_page": 100})
    text = run("gh", "api", "--paginate", f"repos/{{owner}}/{{repo}}/actions/runs?{query}", cwd=root)
    # --paginate prints one JSON document per page.
    runs, decoder, i = [], json.JSONDecoder(), 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i == len(text):
            return runs
        page, i = decoder.raw_decode(text, i)
        runs.extend(page.get("workflow_runs", []))


def main(argv):
    dry = False
    args = list(argv)
    if args[:1] == ["-n"]:
        dry, args = True, args[1:]
    if len(args) > 1 or (args and args[0].startswith("-")):
        print("usage: scripts/ci/main-run.py [-n] [COMMIT]", file=sys.stderr)
        return USAGE
    try:
        root = git("rev-parse", "--show-toplevel").strip()
        git("fetch", "-q", "origin", "main")
        main_head = git("rev-parse", "refs/remotes/origin/main^{commit}").strip()
        try:
            commit = git("rev-parse", "--verify", "-q", f"{args[0] if args else main_head}^{{commit}}").strip()
        except Unreadable:
            print(f"main-run: {args[0]} names no commit", file=sys.stderr)
            return USAGE
        if subprocess.run(["git", "merge-base", "--is-ancestor", commit, main_head]).returncode != 0:
            print(f"main-run: {commit} is not on origin's main", file=sys.stderr)
            return USAGE
        # The commit and every later commit on main that holds it.
        covered = {commit, *git("rev-list", "--ancestry-path", f"{commit}..{main_head}").split()}
        made = datetime.fromisoformat(git("show", "-s", "--format=%cI", commit).strip())
        since = (made - timedelta(hours=1)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        flows = workflows(commit)
        runs = [r for r in push_runs(root, since) if r.get("head_sha") in covered]
    except Unreadable as e:
        print(f"main-run: {e}", file=sys.stderr)
        return ERROR

    distance = {}

    def later(sha):
        if sha not in distance:
            distance[sha] = int(git("rev-list", "--count", f"{commit}..{sha}"))
        return distance[sha]

    def nearest(candidates):
        return min(candidates, key=lambda r: (later(r["head_sha"]), -int(r["id"])))

    def where(r):
        n = later(r["head_sha"])
        at = "the commit" if n == 0 else f"{n} commit{'s' if n > 1 else ''} later"
        return f"run {r['id']} on {r['head_sha'][:9]} ({at}), attempt {r.get('run_attempt', 1)}: {r.get('html_url', '')}"

    def rerun(r, endpoint):
        if dry:
            return RERUN, "would rerun"
        try:
            run("gh", "api", "-X", "POST", f"repos/{{owner}}/{{repo}}/actions/runs/{r['id']}/{endpoint}", cwd=root)
        except Unreadable as e:
            return ERROR, f"its rerun could not be started ({e})"
        return RERUN, "rerun started"

    print(f"main-run: the push runs on main covering {commit[:9]}" + (" (-n: nothing is rerun)" if dry else ""))
    status = GREEN
    for path, name in flows:
        mine = [r for r in runs if r.get("path") == path]
        live = [r for r in mine if r.get("conclusion") != "cancelled"]
        if live:
            r = nearest(live)
            if r.get("status") != "completed":
                code, line = WAIT, f"running, {where(r)}"
            elif r.get("conclusion") in PASSED:
                code, line = GREEN, f"green, {where(r)}"
            elif int(r.get("run_attempt", 1)) > 1:
                code, line = RED_TWICE, f"red twice ({r.get('conclusion')}), {where(r)}: open a regression job"
            else:
                code, said = rerun(r, "rerun-failed-jobs")
                line = f"red ({r.get('conclusion')}), {said}, {where(r)}"
        elif mine:
            # Only cancelled runs cover it: none of them proves the tree.
            r = nearest(mine)
            if int(r.get("run_attempt", 1)) > 1:
                code, line = RED_TWICE, f"red twice (cancelled on its rerun), {where(r)}: open a regression job"
            else:
                code, said = rerun(r, "rerun")
                line = f"red (cancelled, and no run covers it), {said}, {where(r)}"
        elif runs:
            code, line = GREEN, "not run: its path filter left out the commit and every later push"
        else:
            code, line = WAIT, "no run yet"
        print(f"{name}: {line}")
        if URGENCY.index(code) > URGENCY.index(status):
            status = code
    return status


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Unreadable as e:
        print(f"main-run: {e}", file=sys.stderr)
        sys.exit(ERROR)
