#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The rows of one build folder, run by scripts/stage.sh under one
# heavy-check ticket:
#   scripts/lib/stage-chain.sh OWNER RESULTS [INDEX CHECK HOLD TESTS COMMAND]...
#
# Runs each row in the order given, whatever the one before it ended
# with, while OWNER, the stage's pid, still runs the chain: it is the
# parent of the heavy-check that holds the ticket, or the chain's own
# parent where the ticket runs its command in place. Once OWNER is gone
# the heavy-check has another parent, so a pid reused since never passes
# for it, and no row starts: the chain says so on stderr and exits 1. A
# row already running when OWNER goes runs to its end, as a row on a
# ticket of its own does. Each row runs COMMAND as `bash -c` from the
# current directory, contained (scripts/lib/contain.sh) and stopped at
# HOLD seconds, with STAGE_TESTS set to TESTS, its output appended to
# $STAGE_LOGDIR/CHECK.log. When a row ends it appends `INDEX STATUS EPOCH` to RESULTS, EPOCH the second it
# ended, which scripts/stage.sh reads while the chain still runs. A row
# stopped at its hold reads 124 and says so in its log; a row a process of
# which outlives KILL reads 1 for a 0 and names it. INT, TERM and HUP stop
# the running row and exit 130, 143 and 129, and no row starts after them.
# Exits 0 once every row has ended, whatever they ended with; 1 when OWNER
# is gone; 64 on usage, 69 without contain.sh.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[ "$#" -ge 2 ] && [[ $1 =~ ^[1-9][0-9]*$ ]] && [ $((($# - 2) % 5)) = 0 ] || {
  echo "usage: $0 OWNER RESULTS [INDEX CHECK HOLD TESTS COMMAND]..." >&2
  exit 64
}
owner=$1 results=$2
shift 2
# shellcheck source=contain.sh
. "$here/contain.sh" || exit 69

stop() {
  trap '' INT TERM HUP
  contain_stop_all 30 || :
  exit "$1"
}
trap 'stop 130' INT
trap 'stop 143' TERM
trap 'stop 129' HUP

parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
owned() {
  local up
  up=$(parent_of "$$")
  [ -n "$up" ] && { [ "$up" = "$owner" ] || [ "$(parent_of "$up")" = "$owner" ]; }
}

while [ "$#" -gt 0 ]; do
  if ! owned; then
    echo "==> stage: the stage $owner that queued this ticket is gone: $2 and the rows after it do not start" >&2
    exit 1
  fi
  index=$1 check=$2 hold=$3 log="$STAGE_LOGDIR/$2.log"
  export STAGE_TESTS=$4
  command=$5
  shift 5
  began=$SECONDS
  status=0
  contain_start bash -c "$command" >>"$log" 2>&1 </dev/null || status=$?
  if [ "$status" = 0 ]; then
    contain_wait "$CONTAIN_PID" "$hold" 30 2>>"$log"
    status=$?
    if [ "$status" = 124 ] && [ $((SECONDS - began)) -ge "$hold" ]; then
      echo "==> stage: hold deadline after ${hold}s: the command was stopped" >>"$log"
    fi
    if [ -n "$CONTAIN_SURVIVORS" ]; then
      echo "==> stage: processes survived KILL: $CONTAIN_SURVIVORS" >>"$log"
      [ "$status" != 0 ] || status=1
    fi
  fi
  printf '%s %s %s\n' "$index" "$status" "$EPOCHSECONDS" >>"$results"
done
exit 0
