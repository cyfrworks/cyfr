#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run one check on the verification host: scripts/heavy-check.sh [-s] [-t HOLD] [-w QUEUE] [--] command [args]
#
# It needs Bash 4.1 or later and flock(1) (util-linux). macOS ships Bash
# 3.2: install a current one beside flock (brew install bash flock).
#
# The host's checks queue here and nowhere else.
#   exclusive  (default) a gate, a full suite, an image suite or a proof.
#              It sizes itself to the whole machine and its tests carry
#              timing bounds, so it runs alone.
#   scoped     (-s) named test paths in one partition. Up to three run
#              side by side, each on a third of the cores, and never
#              beside an exclusive check. The command's own grammar
#              decides what fits a scoped slot: it sees
#              HEAVY_CHECK_HELD=scoped and refuses what does not.
# Scoped checks take slots in the order they arrived: a free slot goes to
# a scoped check only when no scoped check that queued before it is still
# waiting for one, a stopped one (Ctrl-Z, SIGSTOP) apart. A queued
# exclusive check goes ahead of scoped runs that arrive after it.
#
# HOLD (default 2700 s) bounds how long the command may keep the host:
# at the deadline it is stopped and the exit is 124. A repeat recipe
# therefore takes the host once per repetition, and the checks queued
# behind it run in between. QUEUE (default 7200 s) bounds the wait for
# the host: at the deadline the command has not run and the exit is 75.
# HUP, INT and TERM stop the command and exit 129, 130 and 143. Otherwise
# the exit is the command's own.
#
# The command runs contained (scripts/lib/contain.sh) as the leader of a
# session of its own, without the lock descriptors, and every session
# started under it is listed in a registry this script owns. Before the
# host is handed on, the command's session and every session in the
# registry are stopped, within HEAVY_CHECK_GRACE (default 300 s) plus
# 15 s each. If this script is killed outright, the watchdog keeps the
# host until the same sessions are stopped. A process that outlives KILL
# turns a 0 into 1: this script waits up to 60 s more for it, its last
# stderr line names any that remain, and the watchdog then keeps the host
# for up to HEAVY_CHECK_GRACE plus 15 s more while it stops them again.
#
# Stdout carries two lines that frame the run, after option parsing:
# `_START=<pid>` first and `_EXIT=<pid> <status>` last, on its own line,
# where pid is this script's. scripts/await-task.sh reads them. A check
# started inside a check runs its command in place and writes neither.
# The line says 0 only when the command's own 0 was the end of the run:
# an exit any other way, such as a signal Bash dies of after the EXIT
# trap, says 128 + the signal's number where it is known, else 1.
#
# Lines beginning `==> heavy-check:` on stderr say what the check is
# queued behind, when it starts and how it ended; scripts/await-task.sh
# reads them so a wait's deadline does not run while the check is queued.
# A `NAME=value` word of the command is shown as `NAME=…` there and in the
# holder's record, and a URL's userinfo in any word as `[redacted]`.
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

# A check started by a check already holds the host through its parent,
# and the parent's deadline covers it. It writes no line: the parent's
# frame the run.
case "${HEAVY_CHECK_HELD:-}" in
  '') ;;
  exclusive) exec "$@" ;;
  scoped)
    [ "$MODE" = scoped ] || { echo 'an exclusive check cannot start inside a scoped one' >&2; exit 64; }
    exec "$@" ;;
  *) echo 'HEAVY_CHECK_HELD is not a mode this script set' >&2; exit 64 ;;
esac

queued_at=$SECONDS
ran_at=
record=
wrote_record=false
owner=false
queue_pid=
cmd=
survivors=
finished=false
ticket=

# The command's words for a line another check reads or a kept file: a
# NAME=value word, such as a database URL handed through env, is shown as
# NAME=…, and the userinfo of a URL in any other word, such as
# --url=postgres://user:secret@host, as scheme://[redacted]@, up to the
# last @ before the host, so neither value leaves this check.
redacted() {
  local word name out=
  for word in "$@"; do
    case "$word" in
      [A-Za-z_]*=*)
        name=${word%%=*}
        case "$name" in *[!A-Za-z0-9_]*) ;; *) word="$name=…" ;; esac ;;
    esac
    out="$out${out:+ }$word"
  done
  printf '%s' "$out" | sed -E 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/[:space:]]*@#\1[redacted]@#g'
}

alive() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    read -r s 2>/dev/null <"/proc/$1/stat" || return 1
    s=${s##*) }
  else
    s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
    s=${s// /}
  fi
  case "$s" in ''|Z*|X*|x*) return 1 ;; esac
}

# Every exit after this point passes here, and only here is `_EXIT=`
# written. In order: the command is stopped if it still runs, every
# session in the registry is swept, survivors are waited for, then the
# registry and the holder's record go, and the host is released by the
# exit itself. A 0 that is not the main path's own end is the status of
# whatever ran last before a signal Bash dies of, so it is reported as 1.
on_exit() {
  local status=$? p left waited
  trap '' HUP INT TERM
  trap - EXIT
  exec 1>&"$saved_out" 2>&"$saved_err"
  if [ "$status" = 0 ] && ! $finished; then status=1; fi
  if [ -n "$queue_pid" ]; then kill -TERM "$queue_pid" 2>/dev/null || :; fi
  if [ -n "$cmd" ]; then
    contain_stop "$cmd" "$GRACE" || :
    survivors="$survivors $CONTAIN_SURVIVORS"
    cmd=
  fi
  if $owner; then
    contain_sweep_registry "$GRACE" || :
    survivors="$survivors $CONTAIN_SURVIVORS"
  fi
  survivors=$(echo $survivors)
  if [ -n "$survivors" ]; then
    [ "$status" != 0 ] || status=1
    say "outlived KILL: $survivors; waiting up to 60s before the host is handed on"
    waited=0
    while :; do
      left=
      for p in $survivors; do alive "$p" && left="$left $p"; done
      survivors=${left# }
      [ -n "$survivors" ] && [ "$waited" -lt 600 ] || break
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
  if [ -n "$ticket" ]; then rm -f "$LOCK.wait.$ticket"; fi
  if $owner; then rm -f "$CONTAIN_REGISTRY"; fi
  if $wrote_record; then rm -f "$record"; fi
  if [ -n "$ran_at" ]; then
    say "exit $status after $((SECONDS - ran_at))s (queued $((ran_at - queued_at))s)"
  fi
  if [ -n "$survivors" ]; then say "still alive after KILL and 60s: $survivors"; fi
  printf '\n_EXIT=%s %s\n' "$$" "$status"
  exit "$status"
}
on_signal() {
  trap '' HUP INT TERM
  exec 1>&"$saved_out" 2>&"$saved_err"
  if [ -n "$cmd" ]; then say "interrupted: stopping the command"; else say 'interrupted'; fi
  exit "$1"
}

# A trap runs under whatever redirection the interrupted command had, such
# as the library's `2>/dev/null` around its waits, so the traps write
# through these copies of the streams this script was given. Bash places
# them at 10 or above, clear of the caller's own low descriptors, and the
# command never holds them.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "heavy-check needs Bash 4.1 or later, this is $BASH_VERSION (on macOS: brew install bash)" >&2
  exit 69
fi
exec {saved_out}>&1 {saved_err}>&2
printf '_START=%s\n' "$$"
trap on_exit EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

here=${BASH_SOURCE[0]%/*}
[ "$here" != "${BASH_SOURCE[0]}" ] || here=.
# shellcheck source=lib/contain.sh
. "$here/lib/contain.sh" || { echo "cannot load $here/lib/contain.sh" >&2; exit 69; }
command -v flock >/dev/null 2>&1 || { echo 'flock is required (util-linux; on macOS: brew install flock)' >&2; exit 69; }

LOCK=${HEAVY_CHECK_LOCK:-/tmp/cyfr-heavy-check.lock}
SLOTS=3
# Above the gate's own stop of its legs (255 s at most), so a stopped
# gate cleans up before this script stops what remains.
GRACE=${HEAVY_CHECK_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*) echo 'HEAVY_CHECK_GRACE is decimal seconds' >&2; exit 64 ;; esac
[ "${#GRACE}" -le 6 ] || { echo 'HEAVY_CHECK_GRACE is at most 999999 seconds' >&2; exit 64; }
# The library's watchdog pipes start at CONTAIN_FD_BASE and would replace
# a saved stream placed there. A base the library refuses is left to it.
fd_base=${CONTAIN_FD_BASE:-20}
case "$fd_base" in ''|*[!0-9]*) ;; *)
  if [ "${#fd_base}" -le 4 ] && [ "$((10#$fd_base))" -ge 10 ] &&
    { [ "$saved_out" -ge "$((10#$fd_base))" ] || [ "$saved_err" -ge "$((10#$fd_base))" ]; }; then
    echo "no descriptor is free below CONTAIN_FD_BASE ($fd_base) for this script's own streams" >&2
    exit 64
  fi ;;
esac
umask 077

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
# The wait runs in the background and is waited for by pid, because Bash
# defers a trapped INT or TERM until a foreground command ends.
take() {
  local fd=$1 how=$2 status=0
  if flock -n "$how" "$fd"; then return 0; fi
  announce
  flock -w "$(queue_left)" "$how" "$fd" &
  queue_pid=$!
  wait "$queue_pid" || status=$?
  queue_pid=
  [ "$status" = 0 ] || gave_up
}

# The scoped queue. Each scoped check takes the next ticket from
# $LOCK.seq and holds a lock on its own file $LOCK.wait.<ticket>, which
# names its pid, while it waits for a slot; it tries the slots only when
# no earlier ticket's file is still locked by a live owner that is not
# stopped. A waiter that dies loses its lock with it, so the next scan
# removes its file and nothing waits on a pid that may be reused.
# $LOCK.queue serializes taking a ticket and scanning, so a file is never
# seen before its owner has locked it and written its pid. Its holder can
# itself be stopped, so it is waited for as the host is, bounded by the
# queue deadline and answering a signal at once.
queue_lock() {
  local status=0
  exec {queue_fd}>>"$LOCK.queue" || exit 1
  if flock -n -x "$queue_fd"; then return 0; fi
  flock -w "$(queue_left)" -x "$queue_fd" &
  queue_pid=$!
  wait "$queue_pid" || status=$?
  queue_pid=
  [ "$status" = 0 ] || { announce; gave_up; }
}
queue_unlock() { exec {queue_fd}>&-; }
take_ticket() {
  local last
  queue_lock
  last=$(cat "$LOCK.seq" 2>/dev/null) || :
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  ticket=$((last + 1))
  printf '%s\n' "$ticket" > "$LOCK.seq" || exit 1
  exec {ticket_fd}>"$LOCK.wait.$ticket" || exit 1
  flock -n -x "$ticket_fd" || exit 1
  printf '%s\n' "$$" >&"$ticket_fd" || exit 1
  queue_unlock
}
# Whether pid $1 is stopped: state T (or t, traced) in its stat.
stopped() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    read -r s 2>/dev/null <"/proc/$1/stat" || return 1
    s=${s##*) }
  else
    s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
    s=${s// /}
  fi
  case "$s" in T*|t*) return 0 ;; esac
  return 1
}
release_ticket() {
  rm -f "$LOCK.wait.$ticket"
  exec {ticket_fd}>&-
  ticket=
}
# A locked earlier ticket holds this one back while its owner lives and
# is not stopped; the scan ends at the first that does.
first_in_line() {
  local f k owner first=0
  queue_lock
  for f in "$LOCK".wait.*; do
    k=${f##*.wait.}
    case "$k" in ''|*[!0-9]*) continue ;; esac
    [ "$k" -lt "$ticket" ] || continue
    if flock -n -x "$f" true 2>/dev/null; then rm -f "$f"; continue; fi
    owner=
    read -r owner 2>/dev/null <"$f" || :
    case "$owner" in
      ''|*[!0-9]*) ;;
      *) if ! alive "$owner" || stopped "$owner"; then continue; fi ;;
    esac
    first=1
    break
  done
  queue_unlock
  return "$first"
}

if [ "$MODE" = scoped ]; then
  take_ticket
  slot=
  while :; do
    if first_in_line; then
      for ((i=1; i<=SLOTS; i++)); do
        exec 7>"$LOCK.slot$i" || exit 1
        if flock -n -x 7; then slot=$i; break; fi
        exec 7>&-
      done
      [ -n "$slot" ] && break
    fi
    announce
    [ "$(queue_left)" -gt 0 ] || gave_up
    sleep 0.5
  done
  release_ticket
  record="$LOCK.slot$slot.holder"
else
  record="$LOCK.holder"
fi
exec 8>"$LOCK.turnstile" || exit 1
exec 9>>"$LOCK" || exit 1
take 8 -x
if [ "$MODE" = scoped ]; then take 9 -s; else take 9 -x; fi
flock -u 8

ran_at=$SECONDS
wrote_record=true
printf 'pid=%s mode=%s since=%s hold=%ss command=%s\n' "$$" "$MODE" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$HOLD" "$(redacted "$@")" > "$record"
say "running ($MODE) after $((ran_at - queued_at))s queued: $(redacted "$@")"

# The outermost check owns the registry. One started by a wrapper that
# already keeps a registry appends to that one and leaves it to its owner.
if [ -z "${CONTAIN_REGISTRY:-}" ]; then
  contain_registry_create || { echo 'cannot create the containment registry' >&2; exit 1; }
  owner=true
fi

# The server refuses a CYFR_ name it does not declare, so what this script
# hands the command is named outside that prefix, or inside the test
# harness's part of it.
export HEAVY_CHECK_HELD="$MODE"
if [ "$MODE" = scoped ]; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
  share=$(( cores / SLOTS )); [ "$share" -lt 2 ] && share=2
  export CYFR_TEST_CORES="$share"
fi

# The command never holds the lock descriptors, so nothing it leaves
# behind can keep the host. The watchdog holds them instead, so a check
# killed outright keeps the host until its command's sessions are gone.
# The command does not hold the saved streams either, so its descriptors
# are its caller's.
CONTAIN_CLOSE_FDS="7 8 9 $saved_out $saved_err"
CONTAIN_HOLD_FDS="7 8 9"
export -n CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS
contain_start -g "$GRACE" "$@"
status=$?
[ "$status" = 0 ] || exit "$status"
cmd=$CONTAIN_PID

contain_wait "$cmd" "$HOLD" "$GRACE"
status=$?
cmd=
survivors="$survivors $CONTAIN_SURVIVORS"
# A command that exits 124 by itself before its hold is not reported as
# stopped.
if [ "$status" = 124 ] && [ $((SECONDS - ran_at)) -ge "$HOLD" ]; then
  say "hold deadline after ${HOLD}s: the command was stopped"
fi
[ "$status" != 0 ] || finished=true
exit "$status"
