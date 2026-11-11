#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The host's nightly: scripts/nightly.sh [-l LOGDIR]
#
# Runs `scripts/stage.sh nightly` in this checkout, which the timer's unit
# has moved to main's head (CONTRIBUTING.md), then reports what the stage
# did by triggering .github/workflows/host-nightly.yml through gh. That
# workflow's run fails unless the stage exited 0, so a red night is a
# failed run, which GitHub tells the account that triggered it of.
#
# The report is whatever the stage did, a stage that died early or was
# stopped included: the commit tested (HEAD, or `<HEAD> with changes`
# when the tree differs from it), the stage's exit status, its row lines
# (`<check>: ok|failed <n>|not run <n> <seconds>s`, nothing else of its
# output; a nightly row is never skipped) and the log directory's path on
# this host. Only those reach GitHub, whose runs are public; the logs stay
# here.
#
# The log directory is LOGDIR, else a fresh /tmp/cyfr-stage.nightly.XXXXXX,
# which scripts/janitor.sh removes after seven days (its rule 5); it is
# named on stderr when the stage starts, and holds the stage's stdout as
# stage.out and its stderr as stage.err beside each row's log. Stdout is the
# stage's own, framed by its pid, written once the stage has ended; this
# script's own lines go to stderr.
#
# INT, TERM and HUP stop the stage, which is sent TERM since a background
# command starts with INT ignored; its exit is reported, and this script
# exits 130, 143 or 129. Otherwise it exits 0 when the stage passed and the
# report reached GitHub, the stage's status when the stage did not pass,
# and 1 when the stage passed but the report did not reach GitHub, so the
# unit shows failed whenever the night was not green and reported; 64 on
# usage. Nothing is retried: each proof runs once a night, and a report
# that never reached GitHub is the workflow's watchdog's to find.
set -uo pipefail

usage() { echo "usage: $0 [-l LOGDIR]"; }
logdir=
case $# in
  0) ;;
  2) [ "$1" = -l ] || { usage >&2; exit 64; }; logdir=$2 ;;
  *) usage >&2; exit 64 ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P) && cd "$root" || exit 1
if [ -n "$logdir" ]; then
  mkdir -p "$logdir" && logdir=$(cd "$logdir" && pwd -P) || { echo "nightly: cannot use $logdir for the logs" >&2; exit 64; }
else
  logdir=$(mktemp -d /tmp/cyfr-stage.nightly.XXXXXX) || { echo 'nightly: cannot make a log directory' >&2; exit 1; }
fi
commit=$(git rev-parse HEAD 2>/dev/null) || commit=unknown
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then commit="$commit with changes"; fi

stage_pid= stopped=
on_signal() {
  trap '' INT TERM HUP
  stopped=$1
  if [ -n "$stage_pid" ]; then kill -TERM "$stage_pid" 2>/dev/null; fi
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

echo "nightly: logs in $logdir" >&2
scripts/stage.sh -l "$logdir" nightly >"$logdir/stage.out" 2>"$logdir/stage.err" &
stage_pid=$!
wait "$stage_pid"
status=$?
if [ -n "$stopped" ]; then
  # The signal ended the wait above early; this one returns once the stage
  # has stopped, or 127 when the first had already reaped it.
  wait "$stage_pid"
  again=$?
  [ "$again" = 127 ] || status=$again
fi
cat "$logdir/stage.out"

rows=$(grep -E '^[a-z0-9-]+: (ok|failed [0-9]+|not run [0-9]+) [0-9]+s$' "$logdir/stage.out")
reported=0
gh workflow run host-nightly.yml -f commit="$commit" -f status="$status" -f summary="$rows" -f logs="$logdir" >&2 ||
  reported=$?
if [ "$reported" = 0 ]; then
  echo "nightly: reported status $status for $commit" >&2
else
  echo "nightly: the report of status $status for $commit did not reach GitHub (gh exited $reported)" >&2
fi

if [ -n "$stopped" ]; then exit "$stopped"; fi
[ "$status" = 0 ] || exit "$status"
[ "$reported" = 0 ] || exit 1
exit 0
