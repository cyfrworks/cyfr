#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Await a backgrounded check to a terminal state, and report which one:
#   scripts/await-task.sh <output-file> [success-regex] [deadline-seconds]
#
# A wait that matches only the success marker deadlocks when the job dies:
# nothing will ever write the marker, and silence reads exactly like work in
# progress. This ends on the job's terminal line, on the job's death, or on
# its own deadline, and never on nothing.
#
# The terminal line. scripts/heavy-check.sh, scripts/test-partitioned.sh
# and scripts/commit-gate.sh frame their output with `_START=<pid>` first
# and `_EXIT=<pid> <status>` last, each at the start of a line, where pid is
# the writer's own. With no success-regex, or an empty one, the answer is
# the one `_EXIT=<P> <n>` line that follows `_START=<P>`, P being the
# producer:
#   - with AWAIT_PID set, P is AWAIT_PID: the pid of the script itself
#     (`script ... & AWAIT_PID=$!`, or `env ... script`, which execs it),
#     never of a subshell around it;
#   - without it, P is the pid on the file's first `_START=` line, the
#     outermost producer's, so the caller gives a fresh file.
# A line with another pid (a nested child's, or a previous run's in a
# reused file), a bare `_EXIT=<n>`, and an `_EXIT=` before its `_START=`
# never count. `Result:` is never a terminal marker.
#
# Death. When P is gone (a zombie is gone) and no `_EXIT=<P>` line follows
# its `_START=<P>`, or the file holds a harness death marker
# (`[killed]`, `[exited with code N]`) without the line, the job died. A
# producer that wrote its line and then exited is answered, never reported
# dead: liveness is sampled before the file is read.
#
# With a success-regex, a match is the answer and exits 0; a death without
# one (the death marker, or AWAIT_PID gone) exits 3.
#
# Exit statuses:
#   0   the line says 0 (or the success-regex matched)
#   1   the line says anything else
#   3   the job died without the line
#   2   deadline, of the run or of the queue
#   64  usage, including a deadline, AWAIT_POLL_SECONDS,
#       AWAIT_QUEUE_SECONDS or AWAIT_PID that is not positive decimal
# The answering line is printed on stdout.
#
# A check started through scripts/heavy-check.sh may first queue for the
# host. The deadline (default 2400 s) is for the check's run: while the
# output shows it queued and not yet running, the queue deadline
# (AWAIT_QUEUE_SECONDS, default 7200) is the one that counts.
# AWAIT_POLL_SECONDS (default 10) is the interval between reads. An
# AWAIT_PID that is set but empty counts as unset.
set -uo pipefail

usage() {
  echo "usage: $0 <output-file> [success-regex] [deadline-seconds]" >&2
  echo "  exit 0: the terminal line says 0 (or the regex matched)   1: it says anything else" >&2
  echo "       3: the job died without it   2: deadline (run or queue)   64: usage" >&2
  echo "  without a regex, the answer is _EXIT=<P> <n> after _START=<P>: P is AWAIT_PID, or" >&2
  echo "  the file's first _START= pid, so give a fresh file" >&2
}

[ $# -ge 1 ] && [ $# -le 3 ] || { usage; exit 64; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# Positive decimal, at most six digits.
seconds_ok() {
  case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ "${#1}" -le 6 ]
}

file=$1
pattern=${2:-}
deadline=${3:-2400}
poll=${AWAIT_POLL_SECONDS:-10}
queue_deadline=${AWAIT_QUEUE_SECONDS:-7200}
producer=${AWAIT_PID:-}
seconds_ok "$deadline" || { echo "the deadline is positive decimal seconds: $deadline" >&2; usage; exit 64; }
seconds_ok "$poll" || { echo "AWAIT_POLL_SECONDS is positive decimal seconds: $poll" >&2; exit 64; }
seconds_ok "$queue_deadline" || { echo "AWAIT_QUEUE_SECONDS is positive decimal seconds: $queue_deadline" >&2; exit 64; }
case "$producer" in
  '') ;;
  *[!0-9]*|0*) echo "AWAIT_PID is a positive decimal pid: $producer" >&2; exit 64 ;;
  *) [ "${#producer}" -le 10 ] || { echo "AWAIT_PID is a positive decimal pid: $producer" >&2; exit 64; } ;;
esac

queued='^==> heavy-check: queued'
running='^==> heavy-check: running'
# The harness writes these when a background task ends without finishing its
# own output: a stop, a crash, or any non-zero exit.
died='\[killed\]|\[exited with code [0-9]+\]'

# Whether a process exists and has not exited; a zombie has exited.
alive() {
  local s
  if [ -d /proc/self ]; then
    read -r s 2>/dev/null <"/proc/$1/stat" || return 1
    s=${s##*) }
  else
    s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
    s=${s// /}
  fi
  case "$s" in ''|Z*|X*|x*) return 1 ;; esac
}

# Prints the answering line of producer $1: the first `_EXIT=$1 <n>` after
# the last `_START=$1`. Fails when there is none.
terminal_line() {
  awk -v p="$1" '
    $0 == "_START=" p { started = 1; line = ""; next }
    started && line == "" && $0 ~ ("^_EXIT=" p " [0-9]+$") { line = $0 }
    END { if (line == "") exit 1; print line }
  ' "$file"
}

died() {
  echo "DIED before reporting: $file" >&2
  [ -s "$file" ] && tail -5 "$file" >&2
  exit 3
}

start=$SECONDS
queue_start=$SECONDS
while :; do
  # Sampled before the file is read, so a producer that writes its line
  # and exits in between is answered.
  pid=$producer
  if [ -z "$pattern" ] && [ -z "$pid" ] && [ -s "$file" ]; then
    pid=$(sed -n 's/^_START=\([0-9][0-9]*\)$/\1/p' "$file" | head -n 1)
  fi
  gone=false
  if [ -n "$pid" ] && ! alive "$pid"; then gone=true; fi

  if [ -s "$file" ]; then
    if [ -n "$pattern" ]; then
      if grep -qE -- "$pattern" "$file"; then
        grep -E -- "$pattern" "$file"
        exit 0
      fi
    elif [ -n "$pid" ] && line=$(terminal_line "$pid"); then
      echo "$line"
      case "$line" in *' 0') exit 0 ;; *) exit 1 ;; esac
    fi
    if grep -qE "$died" "$file"; then died; fi
  fi
  if $gone; then died; fi

  if [ -s "$file" ] && grep -qE "$queued" "$file" && ! grep -qE "$running" "$file"; then
    if [ $((SECONDS - queue_start)) -ge "$queue_deadline" ]; then
      echo "QUEUE DEADLINE after ${queue_deadline}s, the check never started: $file" >&2
      tail -5 "$file" >&2
      exit 2
    fi
    # The run's clock starts when the queue ends.
    start=$SECONDS
  elif [ $((SECONDS - start)) -ge "$deadline" ]; then
    echo "DEADLINE after ${deadline}s with no terminal line: $file" >&2
    [ -s "$file" ] && tail -5 "$file" >&2
    exit 2
  fi

  sleep "$poll"
done
