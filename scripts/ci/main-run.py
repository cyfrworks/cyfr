#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Read the push runs on main that cover a commit, once, after a merge:

    python3 -I scripts/ci/main-run.py [-n] [COMMIT]

COMMIT is a commit on origin's main, origin/main's head by default, after
fetching main from origin. The script reads every push run on main GitHub
made for the commit and for each commit of main that contains it (its
descendants that origin/main's head holds, on every line, since a push can
leave main's first-parent line), asking for each commit's runs by its sha.
For each workflow with such a run, the run that covers the commit is the
one on the earliest of those commits, in git's topological order (every
commit after its parents; between two lines that both descend from the
commit, git's order decides), that holds a run of it: a waiting push run
gives way to a newer push's, so a merge's run is often a later commit's. A cancelled run covers nothing
while another run does. It decides nothing about runs GitHub did not make:
a workflow with no such run is not listed, so a run that was due and never
made is not detected. One line per workflow:

  green               the run passed
  running             the run is queued or in progress
  red, rerun started  the run failed on its first attempt, and its failed
                      jobs were rerun
  red twice           the run failed on a rerun, which is never rerun
                      again, or only cancelled runs cover the commit,
                      which a rerun of failed jobs is not documented to
                      restart: the caller opens a regression job

With no run at all on those commits it says no run yet. A run already on a
later attempt is never rerun, so a second read of the same state starts
nothing; -n reads and starts nothing, saying what a read would rerun.
Nothing here waits: a caller reads again later.

Exit status, the most urgent line's: 0 every run green; 2 one still
running, or no run yet; 3 a rerun started (with -n, one due); 4 one red
twice; 1 when git or gh could not be read, a commit's runs could not all
be read, or a rerun could not be started; 64 for a usage error or a commit
not on origin's main.
"""
import json
import subprocess
import sys

GREEN, ERROR, WAIT, RERUN, RED_TWICE, USAGE = 0, 1, 2, 3, 4, 64
# The exit status is the most urgent line's.
URGENCY = [GREEN, WAIT, RERUN, ERROR, RED_TWICE]
# A whole run's own conclusion; every other conclusion is red.
PASSED = {"success", "skipped", "neutral"}


class Unreadable(Exception):
    pass


def run(*argv, cwd=None):
    done = subprocess.run(argv, capture_output=True, text=True, cwd=cwd)
    if done.returncode != 0:
        raise Unreadable(f"{' '.join(argv[:3])}: {(done.stderr or done.stdout).strip()}")
    return done.stdout


def runs_of(root, sha):
    """Every push run on main GitHub made for one commit, or Unreadable."""
    url = f"repos/{{owner}}/{{repo}}/actions/runs?branch=main&event=push&head_sha={sha}&per_page=100"
    text = run("gh", "api", "--paginate", url, cwd=root)
    # --paginate prints one JSON document per page; each states the total.
    runs, totals, decoder, i = [], set(), json.JSONDecoder(), 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i == len(text):
            break
        page, i = decoder.raw_decode(text, i)
        runs.extend(page.get("workflow_runs", []))
        totals.add(page.get("total_count"))
    if totals != {len(runs)}:
        raise Unreadable(f"the runs of {sha[:9]} were not all read: {len(runs)} of {sorted(totals, key=str)}")
    return runs


def main(argv):
    dry = argv[:1] == ["-n"]
    args = argv[1:] if dry else argv
    if len(args) > 1 or (args and args[0].startswith("-")):
        print("usage: scripts/ci/main-run.py [-n] [COMMIT]", file=sys.stderr)
        return USAGE
    root = run("git", "rev-parse", "--show-toplevel").strip()
    run("git", "fetch", "-q", "origin", "main")
    head = run("git", "rev-parse", "refs/remotes/origin/main^{commit}").strip()
    try:
        commit = run("git", "rev-parse", "--verify", "-q", f"{args[0] if args else head}^{{commit}}").strip()
    except Unreadable:
        print(f"main-run: {args[0]} names no commit", file=sys.stderr)
        return USAGE
    if subprocess.run(["git", "merge-base", "--is-ancestor", commit, head]).returncode != 0:
        print(f"main-run: {commit} is not on origin's main", file=sys.stderr)
        return USAGE
    # The commit, then each commit of main that contains it, nearest first in
    # topological order: a push run's head is one of these.
    line = [commit] + run("git", "rev-list", "--reverse", "--topo-order", "--ancestry-path", f"{commit}..{head}").split()
    later = {sha: n for n, sha in enumerate(line)}
    runs = [r for sha in line for r in runs_of(root, sha) if r.get("head_sha") == sha]

    print(f"main-run: the push runs on main covering {commit[:9]}" + (" (-n: nothing is rerun)" if dry else ""))
    if not runs:
        print("no run yet")
        return WAIT

    def where(r):
        n = later[r["head_sha"]]
        at = "the commit" if n == 0 else f"{n} commit{'s' if n > 1 else ''} later on main"
        return f"run {r['id']} on {r['head_sha'][:9]} ({at}), attempt {r.get('run_attempt', 1)}: {r.get('html_url', '')}"

    status = GREEN
    flows = {}
    for r in runs:
        flows.setdefault(r["path"], []).append(r)
    for mine in sorted(flows.values(), key=lambda rs: rs[0].get("name") or rs[0]["path"]):
        live = [r for r in mine if r.get("conclusion") != "cancelled"]
        r = min(live or mine, key=lambda r: (later[r["head_sha"]], -int(r["id"])))
        if not live:
            code, said = RED_TWICE, f"red (cancelled, and nothing newer covers it), nothing started, {where(r)}: open a regression job"
        elif r.get("status") != "completed":
            code, said = WAIT, f"running, {where(r)}"
        elif r.get("conclusion") in PASSED:
            code, said = GREEN, f"green, {where(r)}"
        elif int(r.get("run_attempt", 1)) > 1:
            code, said = RED_TWICE, f"red twice ({r.get('conclusion')}), {where(r)}: open a regression job"
        elif dry:
            code, said = RERUN, f"red ({r.get('conclusion')}), would rerun, {where(r)}"
        else:
            try:
                run("gh", "api", "-X", "POST", f"repos/{{owner}}/{{repo}}/actions/runs/{r['id']}/rerun-failed-jobs", cwd=root)
                code, said = RERUN, f"red ({r.get('conclusion')}), rerun started, {where(r)}"
            except Unreadable as e:
                code, said = ERROR, f"red ({r.get('conclusion')}), its rerun could not be started ({e}), {where(r)}"
        print(f"{r.get('name') or r['path']}: {said}")
        if URGENCY.index(code) > URGENCY.index(status):
            status = code
    return status


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Unreadable as e:
        print(f"main-run: {e}", file=sys.stderr)
        sys.exit(ERROR)
