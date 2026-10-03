#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Await a backgrounded check to a terminal state, and report which one.
#
# A wait that matches only the success marker deadlocks when the job dies:
# nothing will ever write the marker, and silence reads exactly like work in
# progress. This ends on the success marker, on the job's death, or on its
# own deadline, and never on nothing.
#
# A check started through scripts/heavy-check.sh may first queue for the
# host. The deadline is for the check's run: while the output shows it
# queued and not yet running, the queue deadline (AWAIT_QUEUE_SECONDS,
# default 7200) is the one that counts.
set -uo pipefail

usage() {
  echo "usage: $0 <output-file> [success-regex] [deadline-seconds]" >&2
  echo "  exit 0: success marker found   1: job died   2: deadline (run or queue)" >&2
}

[ $# -ge 1 ] || { usage; exit 64; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

file=$1
# The markers a finished suite prints, and the exit line the runner appends.
success=${2:-'^Result:|_EXIT=[0-9]+'}
deadline=${3:-2400}
poll=${AWAIT_POLL_SECONDS:-10}
queue_deadline=${AWAIT_QUEUE_SECONDS:-7200}
queued='^==> heavy-check: queued'
running='^==> heavy-check: running'

# The harness writes these when a background task ends without finishing its
# own output: a stop, a crash, or any non-zero exit.
died='\[killed\]|\[exited with code [0-9]+\]'

start=$SECONDS
queue_start=$SECONDS
while :; do
  if [ -s "$file" ]; then
    # Success is checked first: a job that printed its result and then exited
    # carries both markers, and the result is the answer.
    if grep -qE "$success" "$file"; then
      grep -E "$success" "$file"
      exit 0
    fi
    if grep -qE "$died" "$file"; then
      echo "DIED before reporting: $file" >&2
      tail -5 "$file" >&2
      exit 1
    fi
  fi

  if [ -s "$file" ] && grep -qE "$queued" "$file" && ! grep -qE "$running" "$file"; then
    if [ $((SECONDS - queue_start)) -ge "$queue_deadline" ]; then
      echo "QUEUE DEADLINE after ${queue_deadline}s, the check never started: $file" >&2
      tail -5 "$file" >&2
      exit 2
    fi
    # The run's clock starts when the queue ends.
    start=$SECONDS
  elif [ $((SECONDS - start)) -ge "$deadline" ]; then
    echo "DEADLINE after ${deadline}s with no terminal marker: $file" >&2
    [ -s "$file" ] && tail -5 "$file" >&2
    exit 2
  fi

  sleep "$poll"
done
