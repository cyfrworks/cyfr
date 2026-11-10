#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run one check on the verification host:
#   scripts/heavy-check.sh [-q 1|4] [-t HOLD] [-w QUEUE] [--] command [args]
#   scripts/heavy-check.sh --status
#
# It needs Bash 4.1 or later and flock(1) (util-linux), and places checks
# with taskset(1), also util-linux. macOS ships Bash 3.2: install a current
# one beside flock (brew install bash flock); it has no taskset, so its
# checks are counted and not placed (below).
#
# The host's checks queue here and nowhere else. The machine's cores are
# cut into four equal quarters (scripts/lib/quarters.sh), and a check takes
# one or all four:
#   4  (default) a gate, a close, a full or multi-partition suite, go test
#      -race, a harness self-test that needs the machine, the load check,
#      a timing measurement or the compose proof, whose shipped compose
#      file publishes a fixed port. It sizes itself to the whole machine,
#      or its tests carry timing bounds, so it runs alone.
#   1  (-q 1) named test paths in one partition, a compile, dialyzer,
#      credo, a light self-test, a browser, release or install proof, an
#      image suite or build, a release boot, the janitor. Four run side by
#      side, each on a quarter of its own. The command's own grammar
#      decides what fits one quarter: it sees HEAVY_CHECK_HELD and refuses
#      what does not.
# Any other count is refused with 64, two included: no check takes half
# the machine.
# The machine is the lock file itself, held exclusively by a check on four
# quarters and shared by a check on one, which also holds one of the four
# quarter locks beside it exclusively. A check takes every quarter it asks
# for at once or none: one that finds too few gives back what it took and
# waits again.
# One arrival queue serves every check. A check arrives at the instant its
# ticket's clock is read, immediately before the ticket appears, and
# arrival order is the order of those instants: the order in which the
# tickets are published, with two exceptions. A check stopped between the
# clock's reading and its ticket's appearing keeps its earlier arrival, so
# a check that published meanwhile can run after it; and two checks whose
# tickets appear in the same instant may each see no earlier ticket, and
# the locks decide between them. A check starts only when no check that
# arrived before it still waits, a stopped or dead waiter apart, and
# enough quarters are free; it never waits for a check that arrived after
# it, and never starts past one that arrived before it, whatever either
# asks for. There is no lock over admission: a check never waits on
# another waiter's admission, only on earlier tickets and on the locks.
# A holder stopped after it took its quarters keeps them until it is
# continued or ends; --status shows it held and stopped.
#
# Inside a check, a check runs its command in place when it asks for no
# more quarters than its parent holds: any under a check on four, -q 1
# under a check on one. More is refused with 64.
#
# HOLD (default 2700 s) bounds how long the command may keep the host:
# at the deadline it is stopped and the exit is 124. A repeat recipe
# therefore takes the host once per repetition, and the checks queued
# behind it run in between. QUEUE (default 14400 s, longer than every hold
# in scripts/stages.tsv, so a stage's row queued behind any one other row
# still runs) bounds the wait for the host: at the deadline the command
# has not run and the exit is 75, and no check starts after it, not even
# one stopped while it waited.
# HUP, INT and TERM stop the command and exit 129, 130 and 143. Otherwise
# the exit is the command's own.
#
# Placement. The command runs under `taskset -c` on its quarter's
# processors, or on every online processor when it holds all four (on a
# host whose whole cores do not divide by four, the cores past the four
# quarters are the whole machine's), and every process it starts inherits
# them. Where taskset cannot place a process, or the host has fewer than
# four whole cores, quarters are counted and not placed: the command runs
# where the system puts it, and the running line and the holder's record
# and --status line say so. HEAVY_CHECK_CPU_ROOT (default
# /sys/devices/system/cpu) names the processor directory read.
#
# The command's environment gains HEAVY_CHECK_HELD (the quarters it holds,
# 1 or 4), HEAVY_CHECK_CPUS (its processors, in the form docker's
# --cpuset-cpus takes) when it is placed, and loses one its caller set when
# it is not, and gains CONTAIN_REGISTRY, and PROOF_RUN_PREFIX when the
# caller set none: the prefix scripts/lib/run-names.sh gives the worktree
# holding the caller's working directory, else the checkout this script
# lives in, with this script's pid. A command on one quarter also gets the
# count n of its processors (placed) or a quarter of the machine's, at
# least 1 (not placed), as CYFR_TEST_CORES=n, CARGO_BUILD_JOBS=n and
# `+S n:n` after the caller's own ERL_FLAGS, so every BEAM, cargo build and
# Node runner it starts is bounded by it.
#
# The command runs contained (scripts/lib/contain.sh) as the leader of a
# session of its own, without the lock descriptors, and every session
# started under it is listed in a registry this script owns. Before its
# quarters are handed on, the command's session and every session in the
# registry are stopped, within HEAVY_CHECK_GRACE (default 300 s) plus
# 15 s each. If this script is killed outright, the watchdog keeps the
# quarters until the same sessions are stopped. A process that outlives
# KILL turns a 0 into 1: this script waits up to 60 s more for it, its last
# stderr line names any that remain, and the watchdog then keeps the
# quarters for up to HEAVY_CHECK_GRACE plus 15 s more while it stops them
# again.
#
# Each holder writes a record, one line, for example
#   pid=41237 quarters=1 cpus=2,3,10,11 since=2026-10-28T21:14:03+0000 hold=2700s group=41251 watchdog=41250 checkout=/home/x/cyfr command=mix dialyzer
# in LOCK.holder on four quarters and LOCK.quarter<i>.holder on quarter i,
# where cpus is its processors or `unplaced`, group the command's process
# group and watchdog its watchdog's pid; each waiter's ticket holds pid=,
# quarters=, queued=, checkout= and command= the same way.
# scripts/janitor.sh reads the pid, group and watchdog of every
# LOCK.holder and LOCK.*.holder. A run is finished when no process is left
# in its group and its watchdog has exited. The record is removed at the
# exit only when the registry ended empty and the run is finished, both
# checked; otherwise it stays until its quarters' next holder replaces it,
# which happens only once the watchdog has released them, so a record
# names its run until the run is finished.
#
# --status prints, and exits 0: a `held quarters=<n> pid=<pid> cpus=...`
# line for each holder whose run is not finished, with `state=stopped`
# after its pid while that pid is stopped, then a `waiting <i>
# quarters=<n> pid=...` line for each live waiter in queue order, or the
# word `idle` when there are neither.
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
# A queued check says `queued (<n> quarter[s]) <i> of <m> waiting,
# behind:` with the records of the runs that hold quarters, if any, as
# soon as it waits, and again every 60 seconds with its place then; a
# check that starts says `running (<n> quarter[s], processors <list>)`,
# or `not placed: <why>` in place of the processors. A `NAME=value` word
# of the command is shown as `NAME=…` there, in the records and in
# --status, a URL's userinfo in any word as `[redacted]`, and a tab or
# newline in a word as \t or \n.
set -uo pipefail

QUARTERS=4; HOLD=2700; QUEUE=14400; STATUS=false
asked=false
usage() { echo "usage: $0 [-q 1|4] [-t HOLD_SECONDS] [-w QUEUE_SECONDS] [--] command [args] | $0 --status"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status) STATUS=true; shift ;;
    -q|-t|-w)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      case "$1" in -q) QUARTERS=$2 asked=true ;; -t) HOLD=$2 ;; *) QUEUE=$2 ;; esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; exit 64 ;;
    *) break ;;
  esac
done
if $STATUS; then
  [ "$#" -eq 0 ] && ! $asked || { usage >&2; exit 64; }
else
  [ "$#" -ge 1 ] || { usage >&2; exit 64; }
fi
case "$QUARTERS" in
  1|4) ;;
  *) echo "a check takes 1 or 4 quarters, not '$QUARTERS'" >&2; exit 64 ;;
esac
for n in "$HOLD" "$QUEUE"; do
  case "$n" in ''|*[!0-9]*|0*) echo 'deadlines are positive decimal seconds' >&2; exit 64 ;; esac
  [ "${#n}" -le 6 ] || { echo 'a deadline is at most 999999 seconds' >&2; exit 64; }
done

say() { echo "==> heavy-check: $*" >&2; }

LOCK=${HEAVY_CHECK_LOCK:-/tmp/cyfr-heavy-check.lock}
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
holder_files() { printf '%s\n' "$LOCK.holder" "$LOCK".quarter{1,2,3,4}.holder; }
# The records of the runs that hold quarters and are not finished.
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
# A ticket's key, <ns>.<pid>: the time it was published and its owner.
ticket_key_ok() {
  case "$1" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  case "$1" in *[!0-9.]*|*.*.*) return 1 ;; esac
}
# Whether ticket key $1 was published before ticket key $2.
earlier() {
  local t1=${1%.*} p1=${1#*.} t2=${2%.*} p2=${2#*.}
  [ "$t1" -lt "$t2" ] || { [ "$t1" = "$t2" ] && [ "$p1" -lt "$p2" ]; }
}
# The tickets of the live waiters, in queue order: locked by an owner that
# runs and is not stopped.
live_tickets() {
  local f k line pid
  for f in "$LOCK".wait.*; do
    k=${f##*.wait.}
    ticket_key_ok "$k" || continue
    echo "$k"
  done | sort -t. -k1,1n -k2,2n | while IFS= read -r k; do
    f="$LOCK.wait.$k"
    if flock -n -x "$f" true 2>/dev/null; then continue; fi
    line=$(head -n 1 "$f" 2>/dev/null) || continue
    pid=$(field pid "$line")
    pid_ok "$pid" && alive "$pid" && ! stopped "$pid" || continue
    echo "$k"
  done
}

status() {
  local line file n=0 any=false k pid state
  while IFS= read -r file; do
    [ -s "$file" ] && run_live "$file" || continue
    line=$(head -n 1 "$file")
    any=true
    pid=$(field pid "$line") state=
    if pid_ok "$pid" && stopped "$pid"; then state=' state=stopped'; fi
    printf 'held quarters=%s pid=%s%s cpus=%s since=%s elapsed=%ss hold=%s checkout=%s command=%s\n' \
      "$(field quarters "$line")" "$pid" "$state" "$(field cpus "$line")" "$(field since "$line")" \
      "$(since_seconds "$(field since "$line")")" "$(field hold "$line")" \
      "$(field checkout "$line")" "$(field command "$line")"
  done < <(holder_files)
  while IFS= read -r k; do
    line=$(head -n 1 "$LOCK.wait.$k" 2>/dev/null) || continue
    n=$((n + 1))
    any=true
    printf 'waiting %s quarters=%s pid=%s queued=%s waited=%ss checkout=%s command=%s\n' \
      "$n" "$(field quarters "$line")" "$(field pid "$line")" "$(field queued "$line")" \
      "$(since_seconds "$(field queued "$line")")" "$(field checkout "$line")" "$(field command "$line")"
  done < <(live_tickets)
  $any || echo idle
}

if $STATUS; then
  command -v flock >/dev/null 2>&1 || { echo 'flock is required (util-linux; on macOS: brew install flock)' >&2; exit 69; }
  status
  exit 0
fi

# A check started by a check already holds its quarters through its
# parent, runs on its parent's processors, and the parent's deadline
# covers it. It writes no line: the parent's frame the run.
case "${HEAVY_CHECK_HELD:-}" in
  '') ;;
  1|4)
    [ "$QUARTERS" -le "$HEAVY_CHECK_HELD" ] ||
      { echo "a check on $QUARTERS quarters cannot start inside a check on $HEAVY_CHECK_HELD" >&2; exit 64; }
    exec "$@" ;;
  *) echo 'HEAVY_CHECK_HELD is not a count of quarters this script set' >&2; exit 64 ;;
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
cmd=
survivors=
run_group= run_watchdog=
finished=false
ticket=
checkout=$(pwd -P)
command_text=$(redacted "$@")

# Every exit after this point passes here, and only here is `_EXIT=`
# written. In order: the command is stopped if it still runs, every
# session in the registry is swept, survivors are waited for, then the
# registry goes, and the holder's record when nothing of the run is left,
# and the quarters are released by the exit itself. A 0 that is not the main
# path's own end is the status of whatever ran last before a signal Bash
# dies of, so it is reported as 1.
on_exit() {
  local status=$? p left waited
  trap '' HUP INT TERM
  trap - EXIT
  exec 1>&"$saved_out" 2>&"$saved_err"
  if [ "$status" = 0 ] && ! $finished; then status=1; fi
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
  rm -f "$LOCK.ticket.$$" "$LOCK".wait.*."$$"
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
# not within 5 s, such as a stopped one, still holds the quarters.
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
# shellcheck source=lib/quarters.sh
. "$here/lib/quarters.sh" || { echo "cannot load $here/lib/quarters.sh" >&2; exit 69; }
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

# Placement: the quarters' processors, when taskset can place a process on
# them, or why the quarters are counted and not placed.
placed=false unplaced=
if ! quarters_cut "${HEAVY_CHECK_CPU_ROOT:-/sys/devices/system/cpu}"; then
  unplaced=$QUARTERS_WHY
elif ! { command -v taskset >/dev/null 2>&1 && taskset -c -- "$QUARTERS_ALL" true >/dev/null 2>&1; }; then
  unplaced="taskset cannot place a process on $QUARTERS_ALL here"
else
  placed=true
fi
# The processors of quarter $1, or of the whole machine for 0, or
# `unplaced`.
cpus_for() {
  if ! $placed; then echo unplaced
  elif [ "$1" = 0 ]; then echo "$QUARTERS_ALL"
  else echo "${QUARTER[$1]}"
  fi
}
quarters_words() { if [ "$1" = 1 ]; then echo '1 quarter'; else echo "$1 quarters"; fi; }

# Whether the queue deadline has passed.
expired() { [ $(( $(now_ms) - queued_ms )) -ge $(( QUEUE * 1000 )) ]; }

gave_up() {
  say "queue deadline after $((SECONDS - queued_at))s: the check did not run"
  holders | sed 's/^/==> heavy-check:   still held by /' >&2
  exit 75
}

# The queue. A check arrives by publishing its ticket, $LOCK.wait.<ns>.<pid>,
# a file that carries its pid, quarters, arrival and command. It is written
# whole and locked under a temporary name, then a child process reads the
# clock and renames it into place under that time in nanoseconds and the
# check's pid, so a stop of the check itself does not delay its
# publication; a stop of the child between the reading and the rename
# keeps the earlier time (the header's exception). Arrival order is the
# (time, pid) order of the tickets: no counter, and no lock over
# admission. The check holds its ticket's lock until it leaves the queue,
# and the publishing child holds it while it runs. A waiter whose pid has
# exited is skipped at once; its ticket is removed by the next scan that
# finds nothing holding its lock. A stopped waiter's ticket stays and
# holds no one back.
now_ns() {
  local t
  if [ "${BASH_VERSINFO[0]}" -ge 5 ]; then
    t=${EPOCHREALTIME/[.,]/}
    echo "$(( 10#$t ))000"
  else
    t=$(date +%s%N 2>/dev/null) || t=
    case "$t" in ''|*[!0-9]*) t="$(date +%s)000000000" ;; esac
    echo "$t"
  fi
}
publish_ticket() {
  exec {ticket_fd}>"$LOCK.ticket.$$" || exit 1
  flock -n -x "$ticket_fd" || exit 1
  printf 'pid=%s quarters=%s queued=%s checkout=%s command=%s\n' "$$" "$QUARTERS" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$checkout" "$command_text" >&"$ticket_fd" || exit 1
  ticket=$(t=$(now_ns) && mv -f "$LOCK.ticket.$$" "$LOCK.wait.$t.$$" && echo "$t.$$") || exit 1
}
release_ticket() {
  rm -f "$LOCK.wait.$ticket"
  exec {ticket_fd}>&-
  ticket=
}
# How many live waiters arrived before this one ($ahead) and how many wait
# in all ($waiting), this one included. A ticket nothing locks is removed;
# a stopped or exited owner holds no one back.
places() {
  local f k line pid
  ahead=0 waiting=0
  for f in "$LOCK".wait.*; do
    k=${f##*.wait.}
    ticket_key_ok "$k" || continue
    if [ "$k" != "$ticket" ]; then
      if flock -n -x "$f" true 2>/dev/null; then rm -f "$f"; continue; fi
      line=$(head -n 1 "$f" 2>/dev/null) || continue
      pid=$(field pid "$line")
      if pid_ok "$pid" && { ! alive "$pid" || stopped "$pid"; }; then continue; fi
      if earlier "$k" "$ticket"; then ahead=$((ahead + 1)); fi
    fi
    waiting=$((waiting + 1))
  done
}

# The locks. Descriptors: 9 the machine (exclusive on four quarters,
# shared on one), 7 the quarter held on one.
record_for() { if [ "$1" = 0 ]; then echo "$LOCK.holder"; else echo "$LOCK.quarter$1.holder"; fi; }
write_record() {
  printf 'pid=%s quarters=%s cpus=%s since=%s hold=%ss group=%s watchdog=%s checkout=%s command=%s\n' \
    "$$" "$QUARTERS" "$cpus" "$since" "$HOLD" "${1:-}" "${2:-}" "$checkout" "$command_text" > "$record"
}
# Run in a child process, so that a check stopped meanwhile either holds
# its quarters with its record written or holds nothing: it takes the
# locks on the descriptors the check opened, then reads the queue
# deadline and writes the record, and on every path that does not end
# with the quarters taken it gives back what it took before it exits,
# since the check, stopped, may not close its descriptors for as long as
# it stays stopped. Exits 10 when it took the four quarters, 10 + i when
# it took quarter i; 1 when too few are free or the record was not
# written; 2 when the deadline has passed.
take_quarters() {
  local i held=0 taken=9 s=0
  if [ "$QUARTERS" = 4 ]; then
    flock -n -x 9 || exit 1
  else
    flock -n -s 9 || exit 1
    for ((i=1; i<=4; i++)); do
      if flock -n -x "${quarter_fd[$i]}"; then held=$i; break; fi
    done
    [ "$held" != 0 ] || { flock -u 9; exit 1; }
    taken="9 ${quarter_fd[$held]}"
  fi
  if expired; then
    s=2
  else
    record=$(record_for "$held") cpus=$(cpus_for "$held")
    write_record || s=1
  fi
  if [ "$s" != 0 ]; then
    for i in $taken; do flock -u "$i"; done
    exit "$s"
  fi
  exit $((10 + held))
}
# Opens the descriptors and takes the quarters in a child; returns 0, 1 or
# 2, and keeps the descriptors only when it took the quarters, the one it
# holds as 7 on one quarter. Closing the rest also gives back what a child
# that ended any other way, killed included, took and could not give back.
admit() {
  local i fd s=0
  exec 9>>"$LOCK" || exit 1
  if [ "$QUARTERS" = 1 ]; then
    for ((i=1; i<=4; i++)); do
      exec {fd}>>"$LOCK.quarter$i" || exit 1
      quarter_fd[$i]=$fd
    done
  fi
  since=$(date '+%Y-%m-%dT%H:%M:%S%z')
  ( take_quarters ) || s=$?
  case "$s" in
    1[0-4]) held_quarter=$((s - 10)) s=0 ;;
    1|2) ;;
    *) s=1 ;;
  esac
  if [ "$s" = 0 ] && [ "$held_quarter" != 0 ]; then
    exec 7>&"${quarter_fd[$held_quarter]}" || exit 1
  fi
  for i in "${quarter_fd[@]}"; do eval "exec $i>&-"; done
  quarter_fd=()
  if [ "$s" != 0 ]; then exec 7>&- 9>&-; fi
  return "$s"
}

said_at=
# The queued line, when the check first waits and every REPEAT seconds
# after, with its place then and the holders' records.
announce() {
  local held
  [ -z "$said_at" ] || [ $((SECONDS - said_at)) -ge "$REPEAT" ] || return 0
  said_at=$SECONDS
  held=$(holders)
  say "queued ($(quarters_words "$QUARTERS")) $((ahead + 1)) of $waiting waiting, behind:"
  [ -z "$held" ] || printf '%s\n' "$held" | sed 's/^/==> heavy-check:   /' >&2
}

ahead=0 waiting=1 held_quarter= since=
quarter_fd=()
publish_ticket
while :; do
  places
  if [ "$ahead" = 0 ]; then
    s=0
    admit || s=$?
    [ "$s" != 0 ] || break
    [ "$s" != 2 ] || gave_up
  fi
  announce
  expired && gave_up
  sleep 0.5
done
record=$(record_for "$held_quarter") cpus=$(cpus_for "$held_quarter")
wrote_record=true
release_ticket

ran_at=$SECONDS
if $placed; then where="processors $cpus"; else where="not placed: $unplaced"; fi
say "running ($(quarters_words "$QUARTERS"), $where) after $((ran_at - queued_at))s queued: $command_text"

# The outermost check owns the registry. One started by a wrapper that
# already keeps a registry appends to that one and leaves it to its owner.
if [ -z "${CONTAIN_REGISTRY:-}" ]; then
  contain_registry_create || { echo 'cannot create the containment registry' >&2; exit 1; }
  owner=true
fi

# The server refuses a CYFR_ name it does not declare, so what this script
# hands the command is named outside that prefix, or inside the test
# harness's part of it.
export HEAVY_CHECK_HELD="$QUARTERS"
if $placed; then export HEAVY_CHECK_CPUS="$cpus"; else unset HEAVY_CHECK_CPUS; fi
if [ -z "${PROOF_RUN_PREFIX:-}" ]; then
  prefix=$(run_names_prefix "$checkout" 2>/dev/null) || prefix=$(run_names_prefix "$here" 2>/dev/null) || prefix=
  if [ -n "$prefix" ]; then export PROOF_RUN_PREFIX="$prefix"; fi
fi
if [ "$QUARTERS" = 1 ]; then
  if $placed; then
    share=$(quarters_count "$cpus")
  else
    cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
    share=$(( cores / 4 )); [ "$share" -ge 1 ] || share=1
  fi
  export CYFR_TEST_CORES="$share" CARGO_BUILD_JOBS="$share"
  export ERL_FLAGS="${ERL_FLAGS:+$ERL_FLAGS }+S $share:$share"
fi

# The command never holds the lock descriptors, so nothing it leaves
# behind can keep the quarters. The watchdog holds them instead, so a
# check killed outright keeps its quarters until its command's sessions
# are gone.
# The command does not hold the saved streams either, so its descriptors
# are its caller's.
CONTAIN_CLOSE_FDS="7 9 $saved_out $saved_err"
CONTAIN_HOLD_FDS="7 9"
export -n CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS
if $placed; then
  contain_start -g "$GRACE" taskset -c -- "$cpus" "$@"
else
  contain_start -g "$GRACE" "$@"
fi
status=$?
[ "$status" = 0 ] || exit "$status"
cmd=$CONTAIN_PID
run_group=$CONTAIN_PID run_watchdog=${CONTAIN_WATCHDOG:-}
write_record "$run_group" "$run_watchdog"

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
