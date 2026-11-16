#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The rows of one build folder, run by scripts/stage.sh under one
# heavy-check ticket:
#   scripts/lib/stage-chain.sh RESULTS [INDEX CHECK HOLD TESTS COMMAND]...
#
# Runs each row in the order given, whatever the one before it ended
# with: COMMAND as `bash -c` from the current directory, contained
# (scripts/lib/contain.sh) and stopped at HOLD seconds, with STAGE_TESTS
# set to TESTS, its output appended to $STAGE_LOGDIR/CHECK.log. When a row
# ends it appends `INDEX STATUS EPOCH` to RESULTS, EPOCH the second it
# ended, which scripts/stage.sh reads while the chain still runs. A row
# stopped at its hold reads 124 and says so in its log; a row a process of
# which outlives KILL reads 1 for a 0 and names it. INT, TERM and HUP stop
# the running row and exit 130, 143 and 129, and no row starts after them.
# Exits 0 once every row has ended, whatever they ended with; 64 on usage,
# 69 without contain.sh.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[ "$#" -ge 1 ] && [ $((($# - 1) % 5)) = 0 ] || {
  echo "usage: $0 RESULTS [INDEX CHECK HOLD TESTS COMMAND]..." >&2
  exit 64
}
results=$1
shift
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

while [ "$#" -gt 0 ]; do
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
