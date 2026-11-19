#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""Carry a red run to someone who acts, through one issue per kind of red:

    python3 -I scripts/ci/reds.py test-run|nightly|watchdog

The workflows run it with the facts of the run in the environment and
nothing else; it reads and writes run, job and issue records through gh's
API and never runs anything a run made. Each issue has a fixed title, and
the open issue of that title, the oldest when there are two, is the one
written to; a closed one is never reopened, so the next red opens another.

test-run (.github/workflows/rerun.yml, when a run of the Test workflow
completes): RUN_ID, RUN_ATTEMPT, CONCLUSION, EVENT, HEAD_BRANCH, HEAD_SHA
and RUN_URL, the run's own record. It acts on a pull request's run and on a
push run on main, and leaves every other run alone:
  failure on attempt 1  its failed jobs are rerun, once;
  success on attempt 2  when attempt 1 had failed jobs, a flake: a comment
                        on FLAKES naming the run, the commit, those jobs and
                        the failing tests their logs name (ExUnit's numbered
                        failure lines, the harnesses' FAIL lines);
  failure on attempt 2  no further rerun; on main, a comment on RED_TWICE
                        naming the run and its failed jobs (a second red on
                        main opens a regression job); on a pull request
                        nothing: the red stands for its author.
A cancelled run, any other conclusion, and every attempt after the second,
which only a person starts and reads, are left alone.

nightly (.github/workflows/host-nightly.yml's report): OUTCOME, the outcome
of the step that checks the host's report, and the report's COMMIT, STATUS,
SUMMARY and LOGS, with RUN_URL. A failed check comments on NIGHTLY with the
commit, the exit, the rows that did not pass and the host's log folder; a
passed one closes NIGHTLY with a comment.

watchdog (the same workflow's watchdog): OUTCOME and RUN_URL. A failed
check comments on SILENT; a passed one closes it.

Text a run carries (job names, log lines, the host's rows) reaches an issue
only inside an indented code block, where GitHub renders no mention, link
or markup: a pull request from a fork names its own jobs and prints its own
logs.

Exit 0 when every action was taken, 1 when gh could not read or write, 64
for a usage error or a missing or malformed fact.
"""
import json
import os
import re
import subprocess
import sys

FLAKES = "Flaky tests"
RED_TWICE = "Test is red twice on main"
NIGHTLY = "Host nightly is red"
SILENT = "Host nightly sent no report"

OK, ERROR, USAGE = 0, 1, 64
# A job that ended red: what a rerun of failed jobs reruns.
FAILED_JOB = {"failure", "timed_out"}
# The failing tests a job's log names, after the runner's timestamp.
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ?")
TEST_LINE = re.compile(r"^\s*(\d+\) (?:(?:test|doctest|property) .*\(\S+\)|\S+: failure on setup_all callback.*))\s*$"
                       r"|^\s*(FAIL: .+?)\s*$")
# What one comment names of one job's log, and of one line.
MOST_TESTS, LONGEST = 30, 300


class Unreadable(Exception):
    pass


def gh(*args):
    done = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if done.returncode != 0:
        raise Unreadable(f"gh api {' '.join(args[:3])}: {(done.stderr or done.stdout).strip()}")
    return done.stdout


def pages(url):
    """Every item of a paginated listing: gh prints one JSON document a page."""
    text, items, decoder, i = gh("--paginate", url), [], json.JSONDecoder(), 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i == len(text):
            return items
        page, i = decoder.raw_decode(text, i)
        items.extend(page.get("jobs", []) if isinstance(page, dict) else page)


def block(lines):
    """Lines as an indented code block; a carriage return ends a line."""
    out = []
    for line in lines:
        out += ["    " + part[:LONGEST] for part in str(line).replace("\r", "\n").split("\n")]
    return "\n".join(out)


def open_issue(title):
    issues = [i for i in pages("repos/{owner}/{repo}/issues?state=open&per_page=100")
              if i.get("title") == title and "pull_request" not in i]
    return min((i["number"] for i in issues), default=None)


def report(title, body):
    """Comment on the open issue of TITLE, or open it with BODY.

    Two runs that both found none open both open one. Issue numbers rise in
    the order issues are made, so the later of the two, reading the open
    issues again, finds the earlier one older than its own: it moves its
    text there as a comment and closes its own, and both reports end in
    one issue."""
    number = open_issue(title)
    if number is None:
        made = json.loads(gh("-X", "POST", "repos/{owner}/{repo}/issues", "-f", f"title={title}", "-f", f"body={body}"))
        mine, oldest = made.get("number"), open_issue(title)
        if oldest is None or oldest == mine:
            print(f"reds: opened #{mine}, {title}")
            return
        gh("-X", "POST", f"repos/{{owner}}/{{repo}}/issues/{oldest}/comments", "-f", f"body={body}")
        gh("-X", "PATCH", f"repos/{{owner}}/{{repo}}/issues/{mine}", "-f", "state=closed", "-f", "state_reason=not_planned")
        print(f"reds: opened #{mine} beside the older #{oldest}, moved its text there and closed it, {title}")
    else:
        gh("-X", "POST", f"repos/{{owner}}/{{repo}}/issues/{number}/comments", "-f", f"body={body}")
        print(f"reds: commented on #{number}, {title}")


def close(title, body):
    """Close the open issue of TITLE with a comment; none open is nothing to do."""
    number = open_issue(title)
    if number is None:
        print(f"reds: none open, {title}")
        return
    gh("-X", "POST", f"repos/{{owner}}/{{repo}}/issues/{number}/comments", "-f", f"body={body}")
    gh("-X", "PATCH", f"repos/{{owner}}/{{repo}}/issues/{number}", "-f", "state=closed", "-f", "state_reason=completed")
    print(f"reds: closed #{number}, {title}")


def facts(*names, pattern=None):
    values = {n: os.environ.get(n, "") for n in names}
    for n, v in values.items():
        if pattern and n in pattern and not re.fullmatch(pattern[n], v):
            raise ValueError(f"{n} is {v!r}")
    return values


def failed_jobs(run_id, attempt):
    jobs = pages(f"repos/{{owner}}/{{repo}}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    return [j for j in jobs if j.get("conclusion") in FAILED_JOB]


def failing_tests(job_id):
    """The failing tests the job's log names, in order and once each, or None
    when the log cannot be read."""
    try:
        text = gh(f"repos/{{owner}}/{{repo}}/actions/jobs/{job_id}/logs")
    except Unreadable:
        return None
    seen = []
    for line in text.splitlines():
        m = TEST_LINE.match(STAMP.sub("", line))
        name = m and (m[1] or m[2])
        if name and name not in seen:
            seen.append(name)
    return seen


def test_run():
    f = facts("RUN_ID", "RUN_ATTEMPT", "CONCLUSION", "EVENT", "HEAD_BRANCH", "HEAD_SHA", "RUN_URL",
              pattern={"RUN_ID": r"[1-9][0-9]*", "RUN_ATTEMPT": r"[1-9][0-9]*", "HEAD_SHA": r"[0-9a-f]{40}"})
    run_id, attempt, conclusion = f["RUN_ID"], int(f["RUN_ATTEMPT"]), f["CONCLUSION"]
    on_main = f["EVENT"] == "push" and f["HEAD_BRANCH"] == "main"
    where = "on main" if on_main else "for a pull request"
    said = f"run {run_id}, attempt {attempt}, {conclusion or 'no conclusion'} {where}"
    if not on_main and f["EVENT"] != "pull_request":
        print(f"reds: left alone, a {f['EVENT'] or 'run with no event'} run {run_id} is neither a pull request's nor a push on main")
    elif attempt > 2:
        print(f"reds: {said}: left alone, an attempt after the second is a person's to read")
    elif conclusion == "failure" and attempt == 1:
        gh("-X", "POST", f"repos/{{owner}}/{{repo}}/actions/runs/{run_id}/rerun-failed-jobs")
        print(f"reds: {said}: its failed jobs rerun once")
    elif conclusion == "success" and attempt == 2:
        jobs = failed_jobs(run_id, 1)
        if not jobs:
            print(f"reds: {said}: attempt 1 failed no job, no flake to record")
            return
        lines = []
        for j in jobs:
            tests = failing_tests(j["id"])
            lines.append(j.get("name") or f"job {j['id']}")
            if tests is None:
                lines.append("    (its log could not be read)")
            elif not tests:
                lines.append("    (its log names no failing test)")
            else:
                lines += ["    " + t for t in tests[:MOST_TESTS]]
                if len(tests) > MOST_TESTS:
                    lines.append(f"    and {len(tests) - MOST_TESTS} more")
        report(FLAKES, f"A flake {where}: [run {run_id}]({f['RUN_URL']}) of commit {f['HEAD_SHA']} failed on "
                       f"attempt 1 and passed on attempt 2, nothing changed. "
                       f"The jobs that failed, and the failing tests their logs name:\n\n" + block(lines))
    elif conclusion == "failure" and on_main:
        jobs = failed_jobs(run_id, 2)
        report(RED_TWICE, f"[Run {run_id}]({f['RUN_URL']}) of commit {f['HEAD_SHA']} on main failed again on attempt 2, "
                          f"and is not rerun: open a regression job. Its failed jobs:\n\n"
                          + block([j.get("name") or f"job {j['id']}" for j in jobs] or ["(none listed)"]))
    elif conclusion == "failure":
        print(f"reds: {said}: not rerun again, the red stands for its author")
    else:
        print(f"reds: {said}: left alone")


def nightly():
    f = facts("OUTCOME", "COMMIT", "STATUS", "SUMMARY", "LOGS", "RUN_URL", pattern={"OUTCOME": r"success|failure"})
    if f["OUTCOME"] == "success":
        close(NIGHTLY, f"The host's [nightly]({f['RUN_URL']}) of {f['COMMIT']} exited 0.")
        return
    rows = [r for r in f["SUMMARY"].replace("\r", "\n").split("\n") if r.strip() and not re.search(r": ok [0-9]+s$", r)]
    report(NIGHTLY, f"The host's [nightly report]({f['RUN_URL']}) failed:\n\n" + block(
        [f"commit: {f['COMMIT']}", f"exit: {f['STATUS']}", f"logs on the host: {f['LOGS']}", "rows that did not pass:"]
        + (["  " + r for r in rows] or ["  none named"])))


def watchdog():
    f = facts("OUTCOME", "RUN_URL", pattern={"OUTCOME": r"success|failure"})
    if f["OUTCOME"] == "success":
        close(SILENT, f"A report from the host's nightly arrived ([watchdog]({f['RUN_URL']})).")
    else:
        report(SILENT, f"No report from the host's nightly completed within 26 hours ([watchdog]({f['RUN_URL']})): "
                       "the host is off, its timer did not run, or scripts/nightly.sh could not reach GitHub "
                       "(systemctl --user status cyfr-nightly on the host).")


def main(argv):
    command = {"test-run": test_run, "nightly": nightly, "watchdog": watchdog}.get(argv[0] if len(argv) == 1 else "")
    if command is None:
        print("usage: scripts/ci/reds.py test-run|nightly|watchdog", file=sys.stderr)
        return USAGE
    try:
        command()
    except ValueError as e:
        print(f"reds: a fact is malformed: {e}", file=sys.stderr)
        return USAGE
    except Unreadable as e:
        print(f"reds: {e}", file=sys.stderr)
        return ERROR
    return OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
