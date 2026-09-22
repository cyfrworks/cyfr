#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Kill poll loops that outlived the job they watch.
#
# A backgrounded `until ... grep ...; sleep` loop that matches only a success
# marker never exits once its job dies, and a session blocked on one looks
# identical to a session doing work. This is the backstop for the loops that
# `await-task.sh` is meant to replace: it reaps only the deadlock shape
# (`until` with `sleep`) and only past an age no honest wait reaches.
set -uo pipefail

THRESHOLD=${REAP_THRESHOLD_SECONDS:-1800}
DRY=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --threshold=*) THRESHOLD="${arg#*=}" ;;
    -h|--help)
      echo "usage: $0 [--dry-run] [--threshold=SECONDS]"; exit 0 ;;
  esac
done

# macOS ps has no `etimes`; it prints `[[dd-]hh:]mm:ss` and silently drops an
# unknown column, so the elapsed field is parsed here rather than compared raw.
elapsed_seconds() {
  local e=$1 days=0 rest secs=0
  case "$e" in *-*) days=${e%%-*}; rest=${e#*-} ;; *) rest=$e ;; esac
  local IFS=:
  # shellcheck disable=SC2086
  set -- $rest
  case $# in
    3) secs=$(( 10#$1 * 3600 + 10#$2 * 60 + 10#$3 )) ;;
    2) secs=$(( 10#$1 * 60 + 10#$2 )) ;;
    1) secs=$(( 10#$1 )) ;;
  esac
  echo $(( 10#$days * 86400 + secs ))
}

# Snapshot first: matching inside a pipeline would put the search pattern in a
# live command line and the scan would find itself.
snapshot=$(ps -Ao pid=,ppid=,etime=,command=)

# This process, its parent, and the shell that invoked them: the only lines a
# scan must never kill. Built from the snapshot so no extra process is spawned.
SELF="$$"
next="$$"
for _ in 1 2 3 4; do
  parent=$(awk -v p="$next" '$1 == p { print $2; exit }' <<< "$snapshot")
  [ -n "${parent:-}" ] && [ "$parent" != "0" ] && [ "$parent" != "1" ] || break
  SELF="$SELF $parent"
  next="$parent"
done

killed=0
# `read` with the default IFS skips ps's right-aligned leading blanks and
# leaves the whole command, spaces intact, in the last field.
while read -r pid ppid etime cmd; do
  [ -n "${pid:-}" ] && [ -n "${cmd:-}" ] || continue

  # Protect this process and its own line only. Excluding by command text
  # instead would spare any orphan whose command line happens to name this
  # script — which is exactly the shell that spawned one.
  case " $SELF " in *" $pid "*) continue ;; esac

  # The deadlock shape: a shell loop that sleeps between checks.
  case "$cmd" in
    *until*) ;;
    *) continue ;;
  esac
  case "$cmd" in
    *sleep*) ;;
    *) continue ;;
  esac
  case "$cmd" in
    *done*) ;;
    *) continue ;;
  esac

  age=$(elapsed_seconds "$etime")
  [ "$age" -ge "$THRESHOLD" ] || continue

  if [ -n "$DRY" ]; then
    echo "would reap pid=$pid age=${age}s: ${cmd:0:120}"
  else
    kill "$pid" 2>/dev/null && killed=$((killed + 1)) \
      && echo "reaped stale waiter pid=$pid age=${age}s: ${cmd:0:120}"
  fi
done <<< "$snapshot"

[ -z "$DRY" ] && [ "$killed" -gt 0 ] && \
  echo "{\"systemMessage\":\"Reaped $killed stale poll loop(s) older than ${THRESHOLD}s\"}"
exit 0
