#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run one check on the verification host: scripts/heavy-check.sh [-s] [-t HOLD] [-w QUEUE] [--] command [args]
#
# The host's checks queue here and nowhere else.
#   exclusive  (default) a gate, a full suite, an image suite or a proof.
#              It sizes itself to the whole machine and its tests carry
#              timing bounds, so it runs alone.
#   scoped     (-s) named test paths in one partition. Up to three run
#              side by side, each on a third of the cores, and never
#              beside an exclusive check.
# A queued exclusive check goes ahead of scoped runs that arrive after it.
#
# HOLD (default 2700 s) bounds how long the command may keep the host:
# at the deadline it is stopped and the exit is 124. A repeat recipe
# therefore takes the host once per repetition, and the checks queued
# behind it run in between. QUEUE (default 7200 s) bounds the wait for
# the host: at the deadline the command has not run and the exit is 75.
# Otherwise the exit is the command's own.
#
# Lines beginning `==> heavy-check:` on stderr say what the check is
# queued behind, when it starts and how it ended; scripts/await-task.sh
# reads them so a wait's deadline does not run while the check is queued.
set -uo pipefail

MODE=exclusive; HOLD=2700; QUEUE=7200
usage() { echo "usage: $0 [-s] [-t HOLD_SECONDS] [-w QUEUE_SECONDS] [--] command [args]"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s|--scoped) MODE=scoped; shift ;;
    -t|-w)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      case "$1" in -t) HOLD=$2 ;; *) QUEUE=$2 ;; esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; exit 64 ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] || { usage >&2; exit 64; }
for n in "$HOLD" "$QUEUE"; do
  case "$n" in ''|*[!0-9]*|0*) echo 'deadlines are positive decimal seconds' >&2; exit 64 ;; esac
  [ "${#n}" -le 6 ] || { echo 'a deadline is at most 999999 seconds' >&2; exit 64; }
done

say() { echo "==> heavy-check: $*" >&2; }

# A scoped slot is a third of the host. A gate or a suite wider than one
# partition takes all of it, whatever flag it was started with.
if [ "$MODE" = scoped ]; then
  one_partition() { echo 'a scoped run is one partition: scripts/test-partitioned.sh -n 1 ... paths' >&2; exit 64; }
  runner=false; count_next=false
  for argument in "$@"; do
    case "$argument" in
      */commit-gate.sh|commit-gate.sh) echo 'the gate is an exclusive check: drop -s' >&2; exit 64 ;;
    esac
    if $count_next; then
      [ "$argument" = 1 ] || one_partition
      count_next=false; runner=false
    elif $runner; then
      case "$argument" in -n|--partitions) count_next=true ;; *) one_partition ;; esac
    else
      case "$argument" in */test-partitioned.sh|test-partitioned.sh) runner=true ;; esac
    fi
  done
  # Named last, the runner takes its default count.
  if $runner; then one_partition; fi
fi

# A check started by a check already holds the host through its parent,
# and the parent's deadline covers it.
case "${HEAVY_CHECK_HELD:-}" in
  '') ;;
  exclusive) exec "$@" ;;
  scoped)
    [ "$MODE" = scoped ] || { echo 'an exclusive check cannot start inside a scoped one' >&2; exit 64; }
    exec "$@" ;;
  *) echo 'HEAVY_CHECK_HELD is not a mode this script set' >&2; exit 64 ;;
esac

command -v flock >/dev/null 2>&1 || { echo 'flock is required (util-linux; on macOS: brew install flock)' >&2; exit 69; }

LOCK=${HEAVY_CHECK_LOCK:-/tmp/cyfr-heavy-check.lock}
SLOTS=3
GRACE=${HEAVY_CHECK_GRACE:-30}
case "$GRACE" in ''|*[!0-9]*) echo 'HEAVY_CHECK_GRACE is decimal seconds' >&2; exit 64 ;; esac
umask 077
queued_at=$SECONDS
record=
child=

# The holder's record: who, since when, for how long at most, running what.
holders() {
  local file pid
  for file in "$LOCK.holder" "$LOCK".slot[0-9].holder; do
    [ -s "$file" ] || continue
    pid=$(sed -n 's/^pid=\([0-9]*\) .*/\1/p' "$file")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && cat "$file"
  done
}

queue_left() {
  local left=$(( QUEUE - (SECONDS - queued_at) ))
  [ "$left" -gt 0 ] || left=0
  echo "$left"
}

gave_up() {
  say "queue deadline after $((SECONDS - queued_at))s: the check did not run"
  holders | sed 's/^/==> heavy-check:   still held by /' >&2
  exit 75
}

announced=false
announce() {
  $announced && return
  announced=true
  local held
  held=$(holders)
  if [ -n "$held" ]; then
    say "queued ($MODE) behind:"
    printf '%s\n' "$held" | sed 's/^/==> heavy-check:   /' >&2
  else
    say "queued ($MODE) behind a holder that left no record (lslocks names it)"
  fi
}

# Descriptors: 7 a scoped slot, 8 the turnstile, 9 the host. The turnstile
# is what puts a queued exclusive check ahead of later scoped runs: every
# check passes it on the way in, and an exclusive one keeps it until it
# has the host. The host's file is the one `flock <lock> command` takes,
# so a caller that still uses flock directly is excluded like any other.
take() {
  local fd=$1 how=$2
  if flock -n "$how" "$fd"; then return 0; fi
  announce
  flock -w "$(queue_left)" "$how" "$fd" || gave_up
}

if [ "$MODE" = scoped ]; then
  slot=
  while [ -z "$slot" ]; do
    for ((i=1; i<=SLOTS; i++)); do
      exec 7>"$LOCK.slot$i" || exit 1
      if flock -n -x 7; then slot=$i; break; fi
      exec 7>&-
    done
    [ -n "$slot" ] && break
    announce
    [ "$(queue_left)" -gt 0 ] || gave_up
    sleep 1
  done
  record="$LOCK.slot$slot.holder"
else
  record="$LOCK.holder"
fi
exec 8>"$LOCK.turnstile" || exit 1
exec 9>>"$LOCK" || exit 1
take 8 -x
if [ "$MODE" = scoped ]; then take 9 -s; else take 9 -x; fi
flock -u 8

cleanup_record() { [ -n "$record" ] && rm -f "$record"; }
stop_child() {
  [ -n "$child" ] || return 0
  kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || :
  local waited=0
  while kill -0 -- "-$child" 2>/dev/null && [ "$waited" -lt $((GRACE * 5)) ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  # What ignored the request is ended, including a group of its own that
  # a descendant made, which shares the command's session.
  if command -v pkill >/dev/null 2>&1 && [ "$own_session" = true ]; then pkill -KILL -s "$child" 2>/dev/null || :; fi
  kill -KILL -- "-$child" 2>/dev/null || :
}
on_signal() {
  local status=$1
  trap '' INT TERM
  say "interrupted: stopping the command"
  stop_child
  wait "$child" 2>/dev/null
  cleanup_record
  exit "$status"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap cleanup_record EXIT

ran_at=$SECONDS
printf 'pid=%s mode=%s since=%s hold=%ss command=%s\n' "$$" "$MODE" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$HOLD" "$*" > "$record"
say "running ($MODE) after $((ran_at - queued_at))s queued: $*"

# The server refuses a CYFR_ name it does not declare, so what this script
# hands the command is named outside that prefix, or inside the test
# harness's part of it.
export HEAVY_CHECK_HELD="$MODE"
if [ "$MODE" = scoped ]; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
  share=$(( cores / SLOTS )); [ "$share" -lt 2 ] && share=2
  export CYFR_TEST_CORES="$share"
fi

# The command runs with the lock descriptors closed, so nothing it leaves
# behind can keep the host, and as the leader of its own session, so every
# process it starts can be found when the deadline comes.
own_session=false
if command -v setsid >/dev/null 2>&1; then
  own_session=true
  setsid "$@" 7>&- 8>&- 9>&- <&0 &
else
  set -m
  "$@" 7>&- 8>&- 9>&- <&0 &
fi
child=$!

expired=false
while kill -0 "$child" 2>/dev/null; do
  if [ $((SECONDS - ran_at)) -ge "$HOLD" ]; then
    expired=true
    say "hold deadline after ${HOLD}s: stopping the command"
    stop_child
    break
  fi
  sleep 0.2
done
wait "$child" 2>/dev/null; status=$?
$expired && status=124
child=
say "exit $status after $((SECONDS - ran_at))s (queued $((ran_at - queued_at))s)"
exit "$status"
