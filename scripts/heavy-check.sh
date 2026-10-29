#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run one check on the verification host:
#   scripts/heavy-check.sh [-s | -p] [-t HOLD] [-w QUEUE] [--] command [args]
#   scripts/heavy-check.sh --status
#
# It needs Bash 4.1 or later and flock(1) (util-linux). macOS ships Bash
# 3.2: install a current one beside flock (brew install bash flock).
#
# The host's checks queue here and nowhere else, in three lanes.
#   exclusive  (default) a gate, a close, a full or multi-partition suite,
#              a timing measurement or a shell harness self-test. It
#              sizes itself to the whole machine and its tests carry
#              timing bounds, so it runs alone.
#   proof      (-p) a browser or release proof, a release boot, an image
#              suite, the compose and setup proofs, an image build. One
#              runs at a time, beside at most PROOF_SCOPED scoped checks,
#              never beside an exclusive one.
#   scoped     (-s) named test paths in one partition, a compile,
#              dialyzer, credo or a light self-test. Up to three run side
#              by side, at most PROOF_SCOPED of them while a proof runs,
#              each on a third of the cores. The command's own grammar
#              decides what fits its lane: it sees HEAVY_CHECK_HELD and
#              refuses what does not.
# One arrival queue serves every lane. A check starts only when no check
# that queued before it still waits, a stopped or dead waiter apart, and
# its lane has room; it never waits for a check that queued after it. The
# first-in-line test and the taking of the lane's locks happen under one
# lock, so two checks never both see the same room. A check stopped while
# it holds that lock delays the others by 1 s at most, and any holder that
# keeps it delays them by 10 s at most: then it is passed, and it gives
# back any lane it took beside the check that passed it (ADMIT_STEP,
# ADMIT_STALL below).
#
# Inside a check, a check runs its command in place: any under an
# exclusive one; -p and -s under a proof; -s under a scoped one. Any other
# is refused with 64.
#
# HOLD (default 2700 s) bounds how long the command may keep the host:
# at the deadline it is stopped and the exit is 124. A repeat recipe
# therefore takes the host once per repetition, and the checks queued
# behind it run in between. QUEUE (default 7200 s) bounds the wait for
# the host: at the deadline the command has not run and the exit is 75,
# and no check starts after it, not even one stopped while it waited.
# HUP, INT and TERM stop the command and exit 129, 130 and 143. Otherwise
# the exit is the command's own.
#
# The command's environment gains HEAVY_CHECK_HELD (its lane) and
# CONTAIN_REGISTRY, and PROOF_RUN_PREFIX when the caller set none: the
# prefix scripts/lib/run-names.sh gives the worktree holding the caller's
# working directory, else the checkout this script lives in, with this
# script's pid. A scoped command also gets its slot's share n of the cores
# (cores / 3, at least 2) as CYFR_TEST_CORES=n, CARGO_BUILD_JOBS=n and
# `+S n:n` after the caller's own ERL_FLAGS, so every BEAM, cargo build
# and Node runner it starts is bounded by it.
#
# The command runs contained (scripts/lib/contain.sh) as the leader of a
# session of its own, without the lock descriptors, and every session
# started under it is listed in a registry this script owns. Before the
# host is handed on, the command's session and every session in the
# registry are stopped, within HEAVY_CHECK_GRACE (default 300 s) plus
# 15 s each. If this script is killed outright, the watchdog keeps the
# lane until the same sessions are stopped. A process that outlives KILL
# turns a 0 into 1: this script waits up to 60 s more for it, its last
# stderr line names any that remain, and the watchdog then keeps the lane
# for up to HEAVY_CHECK_GRACE plus 15 s more while it stops them again.
#
# Each holder writes its lane's record, one line, for example
#   pid=41237 mode=scoped since=2026-10-28T21:14:03+0000 hold=2700s group=41251 watchdog=41250 checkout=/home/x/cyfr command=mix dialyzer
# where group is the command's process group and watchdog its watchdog's
# pid; each waiter's ticket holds pid=, mode=, queued=, checkout= and
# command= the same way. A run is finished when no process is left in its
# group and its watchdog has exited. The record is removed at the exit
# only when the registry ended empty and the run is finished, both checked;
# otherwise it stays until the lane's next holder replaces it, which
# happens only once the watchdog has released the lane, so a record names
# its run until the run is finished.
#
# --status prints, and exits 0: a `held` line for each holder whose run is
# not finished, then a `waiting <n>` line for each live waiter in queue
# order, or the word `idle` when there are neither.
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
# A queued check says `queued (<mode>) <n> of <m> waiting, behind:` with
# the records of the runs that hold a lane, if any, as soon as it waits,
# whether for its lane or for the admission lock, and again every 60
# seconds with its place then. A `NAME=value` word of the command is shown as `NAME=…`
# there, in the records and in --status, a URL's userinfo in any word as
# `[redacted]`, and a tab or newline in a word as \t or \n.
set -uo pipefail

# 1 when the load check holds every timing bound with a scoped slot beside
# a proof (docs/plans/verification-flow.md, D4), else 0.
PROOF_SCOPED=1

MODE=exclusive; HOLD=2700; QUEUE=7200; STATUS=false
usage() { echo "usage: $0 [-s | -p] [-t HOLD_SECONDS] [-w QUEUE_SECONDS] [--] command [args] | $0 --status"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s) MODE=scoped; shift ;;
    -p) MODE=proof; shift ;;
    --status) STATUS=true; shift ;;
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
if $STATUS; then
  [ "$#" -eq 0 ] && [ "$MODE" = exclusive ] || { usage >&2; exit 64; }
else
  [ "$#" -ge 1 ] || { usage >&2; exit 64; }
fi
for n in "$HOLD" "$QUEUE"; do
  case "$n" in ''|*[!0-9]*|0*) echo 'deadlines are positive decimal seconds' >&2; exit 64 ;; esac
  [ "${#n}" -le 6 ] || { echo 'a deadline is at most 999999 seconds' >&2; exit 64; }
done

say() { echo "==> heavy-check: $*" >&2; }

LOCK=${HEAVY_CHECK_LOCK:-/tmp/cyfr-heavy-check.lock}
SLOTS=3
# How often a queued check repeats its place in the queue.
REPEAT=${HEAVY_CHECK_REPEAT:-60}
case "$REPEAT" in ''|*[!0-9]*|0*) echo 'HEAVY_CHECK_REPEAT is positive decimal seconds' >&2; exit 64 ;; esac

# The command's words for a line another check reads or a kept file: a
# NAME=value word, such as a database URL handed through env, is shown as
# NAME=…, and the userinfo of a URL in any other word, such as
# --url=postgres://user:secret@host, as scheme://[redacted]@, up to the
# last @ before the host, so neither value leaves this check. A tab or a
# newline inside a word is written as \t or \n, so a record is one line.
redacted() {
  local word name out=
  for word in "$@"; do
    case "$word" in
      [A-Za-z_]*=*)
        name=${word%%=*}
        case "$name" in *[!A-Za-z0-9_]*) ;; *) word="$name=…" ;; esac ;;
    esac
    word=${word//$'\t'/\\t}
    word=${word//$'\n'/\\n}
    out="$out${out:+ }$word"
  done
  printf '%s' "$out" | sed -E 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/[:space:]]*@#\1[redacted]@#g'
}

# The process state of pid $1: empty when there is no such process.
state_of() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    read -r s 2>/dev/null <"/proc/$1/stat" || return 0
    s=${s##*) }
    printf '%s' "${s%% *}"
  else
    s=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
    printf '%s' "${s// /}"
  fi
}
alive() {
  case "$(state_of "$1")" in ''|Z*|X*|x*) return 1 ;; esac
}
# Whether pid $1 is stopped: state T (or t, traced).
stopped() {
  case "$(state_of "$1")" in T*|t*) return 0 ;; esac
  return 1
}
pid_ok() { case "${1:-}" in ''|0*|*[!0-9]*) return 1 ;; esac; }
# The value of field $1 in record line $2; checkout= and command= may hold
# spaces, so command= is the rest of the line and checkout= runs up to it.
field() {
  local line=$2 v
  case "$1" in
    command) v=${line#* command=}; [ "$v" != "$line" ] || v= ;;
    checkout) v=${line#* checkout=}; [ "$v" != "$line" ] || v=; v=${v% command=*} ;;
    *) v=" $line"; v=${v#* "$1"=}; [ "$v" != " $line" ] || v=; v=${v%% *} ;;
  esac
  printf '%s' "$v"
}
# Whether the run a holder record names is unfinished: its heavy-check,
# a process of its group or its watchdog still runs.
run_live() {
  local line pid group watchdog
  line=$(head -n 1 "$1" 2>/dev/null) || return 1
  pid=$(field pid "$line"); group=$(field group "$line"); watchdog=$(field watchdog "$line")
  if pid_ok "$pid" && alive "$pid"; then return 0; fi
  if pid_ok "$group" && kill -0 -- "-$group" 2>/dev/null; then return 0; fi
  if pid_ok "$watchdog" && alive "$watchdog"; then return 0; fi
  return 1
}
holder_files() { printf '%s\n' "$LOCK.holder" "$LOCK.proof.holder" "$LOCK".slot[0-9].holder; }
# The records of the runs that hold a lane and are not finished.
holders() {
  local file
  while IFS= read -r file; do
    [ -s "$file" ] && run_live "$file" && head -n 1 "$file"
  done < <(holder_files)
}
# Seconds since a record's time stamp.
since_seconds() {
  local t
  t=$(date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' "$1" +%s 2>/dev/null) || { echo 0; return; }
  echo $(( $(date +%s) - t ))
}
# The tickets of the live waiters, in queue order: locked by an owner that
# runs and is not stopped.
live_tickets() {
  local f k line pid
  for f in "$LOCK".wait.*; do
    k=${f##*.wait.}
    case "$k" in ''|*[!0-9]*) continue ;; esac
    echo "$k"
  done | sort -n | while IFS= read -r k; do
    f="$LOCK.wait.$k"
    if flock -n -x "$f" true 2>/dev/null; then continue; fi
    line=$(head -n 1 "$f" 2>/dev/null) || continue
    pid=$(field pid "$line")
    pid_ok "$pid" && alive "$pid" && ! stopped "$pid" || continue
    echo "$k"
  done
}

status() {
  local line file n=0 any=false k
  while IFS= read -r file; do
    [ -s "$file" ] && run_live "$file" || continue
    line=$(head -n 1 "$file")
    any=true
    printf 'held %s pid=%s since=%s elapsed=%ss hold=%s checkout=%s command=%s\n' \
      "$(field mode "$line")" "$(field pid "$line")" "$(field since "$line")" \
      "$(since_seconds "$(field since "$line")")" "$(field hold "$line")" \
      "$(field checkout "$line")" "$(field command "$line")"
  done < <(holder_files)
  while IFS= read -r k; do
    line=$(head -n 1 "$LOCK.wait.$k" 2>/dev/null) || continue
    n=$((n + 1))
    any=true
    printf 'waiting %s %s pid=%s queued=%s waited=%ss checkout=%s command=%s\n' \
      "$n" "$(field mode "$line")" "$(field pid "$line")" "$(field queued "$line")" \
      "$(since_seconds "$(field queued "$line")")" "$(field checkout "$line")" "$(field command "$line")"
  done < <(live_tickets)
  $any || echo idle
}

if $STATUS; then
  command -v flock >/dev/null 2>&1 || { echo 'flock is required (util-linux; on macOS: brew install flock)' >&2; exit 69; }
  status
  exit 0
fi

# A check started by a check already holds the host through its parent,
# and the parent's deadline covers it. It writes no line: the parent's
# frame the run.
case "${HEAVY_CHECK_HELD:-}" in
  '') ;;
  exclusive) exec "$@" ;;
  proof)
    [ "$MODE" != exclusive ] || { echo 'an exclusive check cannot start inside a proof' >&2; exit 64; }
    exec "$@" ;;
  scoped)
    [ "$MODE" = scoped ] || { echo "a $MODE check cannot start inside a scoped one" >&2; exit 64; }
    exec "$@" ;;
  *) echo 'HEAVY_CHECK_HELD is not a mode this script set' >&2; exit 64 ;;
esac

# The queue deadline counts in milliseconds where Bash has EPOCHREALTIME
# (5.0 and later), else in whole seconds.
now_ms() {
  local t
  if [ "${BASH_VERSINFO[0]}" -ge 5 ]; then
    t=${EPOCHREALTIME/[.,]/}
    echo $(( 10#$t / 1000 ))
  else
    echo $(( SECONDS * 1000 ))
  fi
}
queued_at=$SECONDS
queued_ms=$(now_ms)
ran_at=
record=
wrote_record=false
owner=false
queue_pid=
cmd=
survivors=
run_group= run_watchdog=
finished=false
ticket=
checkout=$(pwd -P)

# Every exit after this point passes here, and only here is `_EXIT=`
# written. In order: the command is stopped if it still runs, every
# session in the registry is swept, survivors are waited for, then the
# registry goes, and the holder's record when nothing of the run is left,
# and the lane is released by the exit itself. A 0 that is not the main
# path's own end is the status of whatever ran last before a signal Bash
# dies of, so it is reported as 1.
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
  rm -f "$LOCK.ticket.$$" "$LOCK.queue.$$"
  if $owner; then rm -f "$CONTAIN_REGISTRY"; fi
  if $wrote_record && [ -z "$survivors" ] && run_finished; then rm -f "$record"; fi
  if [ -n "$ran_at" ]; then
    say "exit $status after $((SECONDS - ran_at))s (queued $((ran_at - queued_at))s)"
  fi
  if [ -n "$survivors" ]; then say "still alive after KILL and 60s: $survivors"; fi
  printf '\n_EXIT=%s %s\n' "$$" "$status"
  exit "$status"
}
# Whether this check's run is finished: no process is left in its group and
# its watchdog has exited. A retired watchdog exits at once; one that has
# not within 5 s, such as a stopped one, still holds the lane.
run_finished() {
  local n=0
  if pid_ok "$run_group" && kill -0 -- "-$run_group" 2>/dev/null; then return 1; fi
  pid_ok "$run_watchdog" || return 0
  while alive "$run_watchdog"; do
    [ "$n" -lt 50 ] || return 1
    sleep 0.1
    n=$((n + 1))
  done
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
# shellcheck source=lib/run-names.sh
. "$here/lib/run-names.sh" || { echo "cannot load $here/lib/run-names.sh" >&2; exit 69; }
command -v flock >/dev/null 2>&1 || { echo 'flock is required (util-linux; on macOS: brew install flock)' >&2; exit 69; }

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

# Whether the queue deadline has passed.
expired() { [ $(( $(now_ms) - queued_ms )) -ge $(( QUEUE * 1000 )) ]; }
# Whole seconds left before it, rounded up, at least 0.
queue_left() {
  local left=$(( QUEUE * 1000 - ($(now_ms) - queued_ms) ))
  [ "$left" -gt 0 ] || left=0
  echo $(( (left + 999) / 1000 ))
}

gave_up() {
  say "queue deadline after $((SECONDS - queued_at))s: the check did not run"
  holders | sed 's/^/==> heavy-check:   still held by /' >&2
  exit 75
}

# The queue. Each check holds a lock on its ticket's file, which carries
# its pid, lane, arrival and command, from before the file appears as
# $LOCK.wait.<ticket> until it leaves the queue, so a ticket no owner locks
# is a dead waiter's. The ticket is the next number after $LOCK.seq, or
# the first free one after it.
#
# $LOCK.queue, the admission lock, serializes taking a ticket, the
# first-in-line test and the taking of the lane's locks, so two checks
# never both see the same room. Its holder writes its pid to
# $LOCK.queue.owner and keeps the lock for a few milliseconds. A check
# waits for it in steps of ADMIT_STEP seconds, in the background so that
# a signal is answered at once (Bash defers a trapped INT or TERM until a
# foreground command ends), and bounded by the queue deadline. After a
# step, a holder that is stopped or gone, or one that this check has seen
# keep the lock for ADMIT_STALL seconds, is bypassed: the check puts a new
# file in the place of $LOCK.queue and locks that. A check stopped in
# admission therefore delays the others by ADMIT_STEP seconds at most, and
# any holder, such as one stopped before it wrote its pid, ADMIT_STALL. The
# bypassed holder keeps its ticket and its place. Before it keeps a lane it
# took, it checks that its lock is still the one at $LOCK.queue
# (queue_held); if not, it gives the lane back and tries again, so a lane
# taken beside another admission is never kept.
ADMIT_STEP=1
ADMIT_STALL=10
queue_held() { [ "/dev/fd/$queue_fd" -ef "$LOCK.queue" ]; }
queue_owner() { head -n 1 "$LOCK.queue.owner" 2>/dev/null || :; }
# A local here must not shadow a global that on_exit reads (owner, cmd,
# ticket and the rest): an exit inside the function runs on_exit in its
# scope.
queue_lock() {
  local status named seen= seen_at= step
  while :; do
    exec {queue_fd}>>"$LOCK.queue" || exit 1
    status=0
    if ! flock -n -x "$queue_fd"; then
      if [ -z "$seen_at" ]; then seen=$(queue_owner) seen_at=$SECONDS; fi
      places
      announce
      step=$(queue_left)
      [ "$step" -le "$ADMIT_STEP" ] || step=$ADMIT_STEP
      [ "$step" -gt 0 ] || gave_up
      flock -w "$step" -x "$queue_fd" &
      queue_pid=$!
      wait "$queue_pid" || status=$?
      queue_pid=
    fi
    if [ "$status" = 0 ]; then
      if queue_held; then
        printf '%s\n' "$$" > "$LOCK.queue.owner" || exit 1
        return 0
      fi
    else
      expired && gave_up
      named=$(queue_owner)
      if [ "$named" != "$seen" ]; then seen=$named seen_at=$SECONDS; fi
      if ! pid_ok "$named" || [ "$named" = "$$" ] || ! alive "$named" || stopped "$named" ||
        [ $((SECONDS - seen_at)) -ge "$ADMIT_STALL" ]; then
        if queue_held; then
          : > "$LOCK.queue.$$" && mv -f "$LOCK.queue.$$" "$LOCK.queue" || exit 1
        fi
        seen= seen_at=$SECONDS
      fi
    fi
    exec {queue_fd}>&-
  done
}
queue_unlock() { exec {queue_fd}>&-; }
take_ticket() {
  local last n=0
  exec {ticket_fd}>"$LOCK.ticket.$$" || exit 1
  flock -n -x "$ticket_fd" || exit 1
  printf 'pid=%s mode=%s queued=%s checkout=%s command=%s\n' "$$" "$MODE" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$checkout" "$(redacted "$@")" >&"$ticket_fd" || exit 1
  queue_lock
  last=$(cat "$LOCK.seq" 2>/dev/null) || :
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  ticket=$((last + 1))
  until ln "$LOCK.ticket.$$" "$LOCK.wait.$ticket" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 1000 ] || { echo "cannot take a ticket in $LOCK.wait.*" >&2; exit 1; }
    [ ! -e "$LOCK.wait.$ticket" ] || ticket=$((ticket + 1))
  done
  printf '%s\n' "$ticket" > "$LOCK.seq" || exit 1
  queue_unlock
  rm -f "$LOCK.ticket.$$"
}
release_ticket() {
  rm -f "$LOCK.wait.$ticket"
  exec {ticket_fd}>&-
  ticket=
}
# How many live waiters queued before this one ($ahead) and how many wait
# in all ($waiting), this one included; a check that has no ticket yet
# counts as the last. A stopped owner holds no one back. With `prune`,
# under the queue lock, a ticket no owner locks is removed.
places() {
  local f k line pid
  ahead=0 waiting=0
  for f in "$LOCK".wait.*; do
    k=${f##*.wait.}
    case "$k" in ''|*[!0-9]*) continue ;; esac
    if [ "$k" != "$ticket" ]; then
      if flock -n -x "$f" true 2>/dev/null; then
        [ "${1:-}" != prune ] || rm -f "$f"
        continue
      fi
      line=$(head -n 1 "$f" 2>/dev/null) || continue
      pid=$(field pid "$line")
      if pid_ok "$pid" && { ! alive "$pid" || stopped "$pid"; }; then continue; fi
    fi
    waiting=$((waiting + 1))
    [ -n "$ticket" ] && [ "$k" -ge "$ticket" ] || ahead=$((ahead + 1))
  done
  [ -n "$ticket" ] || waiting=$((waiting + 1))
}
# Under the queue lock: whether the lane has room, taking its locks when it
# has. Descriptors: 9 the host (exclusive alone, shared by the other
# lanes), 8 the proof lane, 7 a scoped slot. The room the other lanes
# leave is read by trying their locks without keeping them.
slots_taken() {
  local i n=0
  for ((i=1; i<=SLOTS; i++)); do
    flock -n -x "$LOCK.slot$i" true 2>/dev/null || n=$((n + 1))
  done
  echo "$n"
}
proof_running() { ! flock -n -x "$LOCK.proof" true 2>/dev/null; }
take_lane() {
  local i
  exec 9>>"$LOCK" || exit 1
  case "$MODE" in
    exclusive)
      flock -n -x 9 && return 0 ;;
    proof)
      if flock -n -s 9; then
        exec 8>>"$LOCK.proof" || exit 1
        if flock -n -x 8; then
          [ "$(slots_taken)" -gt "$PROOF_SCOPED" ] || return 0
        fi
        exec 8>&-
      fi ;;
    scoped)
      if flock -n -s 9; then
        if ! proof_running || [ "$(slots_taken)" -lt "$PROOF_SCOPED" ]; then
          for ((i=1; i<=SLOTS; i++)); do
            exec 7>>"$LOCK.slot$i" || exit 1
            if flock -n -x 7; then slot=$i; return 0; fi
            exec 7>&-
          done
        fi
      fi ;;
  esac
  drop_lane
  return 1
}
drop_lane() { exec 7>&- 8>&- 9>&-; slot=; }

said_at=
# The queued line, when the check first waits and every REPEAT seconds
# after, with its place then and the holders' records.
announce() {
  local held
  [ -z "$said_at" ] || [ $((SECONDS - said_at)) -ge "$REPEAT" ] || return 0
  said_at=$SECONDS
  held=$(holders)
  say "queued ($MODE) $((ahead + 1)) of $waiting waiting, behind:"
  [ -z "$held" ] || printf '%s\n' "$held" | sed 's/^/==> heavy-check:   /' >&2
}

ahead=0 waiting=1 slot=
take_ticket "$@"
# A lane is kept only while the admission lock is still this check's and
# before the queue deadline, which a check stopped while it waited may
# have passed.
while :; do
  queue_lock
  places prune
  if [ "$ahead" = 0 ] && take_lane; then
    if ! queue_held; then
      drop_lane
    elif expired; then
      drop_lane
      gave_up
    else
      queue_unlock
      break
    fi
  fi
  queue_unlock
  announce
  expired && gave_up
  sleep 0.5
done
release_ticket
case "$MODE" in
  exclusive) record="$LOCK.holder" ;;
  proof) record="$LOCK.proof.holder" ;;
  scoped) record="$LOCK.slot$slot.holder" ;;
esac

ran_at=$SECONDS
since=$(date '+%Y-%m-%dT%H:%M:%S%z')
write_record() {
  printf 'pid=%s mode=%s since=%s hold=%ss group=%s watchdog=%s checkout=%s command=%s\n' \
    "$$" "$MODE" "$since" "$HOLD" "${1:-}" "${2:-}" "$checkout" "$(redacted "${@:3}")" > "$record"
}
wrote_record=true
write_record '' '' "$@"
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
if [ -z "${PROOF_RUN_PREFIX:-}" ]; then
  prefix=$(run_names_prefix "$checkout" 2>/dev/null) || prefix=$(run_names_prefix "$here" 2>/dev/null) || prefix=
  if [ -n "$prefix" ]; then export PROOF_RUN_PREFIX="$prefix"; fi
fi
if [ "$MODE" = scoped ]; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
  share=$(( cores / SLOTS )); [ "$share" -lt 2 ] && share=2
  export CYFR_TEST_CORES="$share" CARGO_BUILD_JOBS="$share"
  export ERL_FLAGS="${ERL_FLAGS:+$ERL_FLAGS }+S $share:$share"
fi

# The command never holds the lock descriptors, so nothing it leaves
# behind can keep the lane. The watchdog holds them instead, so a check
# killed outright keeps its lane until its command's sessions are gone.
# The command does not hold the saved streams either, so its descriptors
# are its caller's.
CONTAIN_CLOSE_FDS="7 8 9 $saved_out $saved_err"
CONTAIN_HOLD_FDS="7 8 9"
export -n CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS
contain_start -g "$GRACE" "$@"
status=$?
[ "$status" = 0 ] || exit "$status"
cmd=$CONTAIN_PID
run_group=$CONTAIN_PID run_watchdog=${CONTAIN_WATCHDOG:-}
write_record "$run_group" "$run_watchdog" "$@"

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
