#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run one check on the verification host:
#   scripts/heavy-check.sh [-t HOLD] [--] command [args]
#   scripts/heavy-check.sh --status
#
# It needs Bash 4.1 or later and flock(1) (util-linux), and places checks
# with taskset(1), also util-linux. macOS ships Bash 3.2: install a current
# one beside flock (brew install bash flock); it has no taskset, so its
# checks are counted and not placed (below).
#
# The host's checks queue here and nowhere else. The machine's cores are
# cut into four equal quarters (scripts/lib/quarters.sh), and a check takes
# one: named test paths in one partition, a compile, dialyzer, credo, a
# self-test, a proof, an image suite or build, a release boot, the
# janitor. Four run side by side, each on a quarter of its own. The
# command's own grammar decides what fits one quarter: it sees
# HEAVY_CHECK_HELD and refuses what does not. Nothing here takes the whole
# machine: what needs it is the pull request's run on GitHub.
# Each quarter is a lock file, LOCK.quarter<i>, held exclusively by the
# check on it.
#
# The order. A check arrives when its ticket is numbered, and arrival
# order is the order of the numbers. When a quarter is free, the waiter
# served is the first to arrive whose worktree holds no quarter; when
# every waiter's worktree holds one, the first to arrive. A check's
# worktree is the Git top level of the directory it was started from,
# else that directory, physical (`pwd -P`). So a worktree is never given
# a second quarter while another worktree's check waits, and a worktree
# alone on the host takes every free quarter. Given the same arrivals and
# the same ends, the order is the same: there is no priority and no
# clock.
#
# What the order reads is the kernel's locks and the live waiters'
# tickets, and nothing else. A quarter is held exactly while its lock,
# LOCK.quarter<i>, is held. A worktree holds a quarter exactly while a
# shared lock on its own file, LOCK.tree.<id>, is held: a holder keeps one
# beside its quarter's lock, and the question is asked by trying the
# exclusive lock without waiting. The holders' records (below) are for
# people, --status and the janitor: the order never reads one.
#
# A ticket is numbered, and a quarter is taken or given back by the rule,
# under one lock, LOCK.admission; the load record's line is appended
# under that file's own lock. Each such step runs in a child process
# outside the check's process group, with no terminal, that holds the
# lock for file operations only: a check stopped or killed at any point,
# alone or with its whole process group, never holds one. A stop aimed at
# such a child's own pid holds its lock until it is continued. Admission
# has one commit point, the removal of the ticket: a check whose step
# ended any other way than by its own success is admitted if its ticket
# is gone and not if it is there, and then gives back what the step took.
# On its way out a check gives its quarter back before it does anything
# that can wait. A stopped or dead waiter holds no one back. A holder
# stopped after it took its quarter keeps it until it is continued or
# ends; --status shows it held and stopped.
#
# Inside a check, a check runs its command in place, on its parent's
# quarter.
#
# HOLD (default 2700 s) bounds how long the command may keep its quarter:
# at the deadline it is stopped and the exit is 124. A repeat recipe
# therefore takes a quarter once per repetition, and the checks queued
# behind it run in between. A check waits for a quarter as long as it
# takes: every holder's run is bounded by its own hold.
# HUP, INT and TERM stop the command, or the wait, and exit 129, 130 and
# 143. Otherwise the exit is the command's own.
#
# Placement. The command runs under `taskset -c` on its quarter's
# processors, and every process it starts inherits them. Where taskset
# cannot place a process, or the host has fewer than four whole cores,
# quarters are counted and not placed: the command runs where the system
# puts it, and the running line and the holder's record and --status line
# say so. HEAVY_CHECK_CPU_ROOT (default /sys/devices/system/cpu) names the
# processor directory read.
#
# The command's environment gains HEAVY_CHECK_HELD=1, HEAVY_CHECK_CPUS
# (its processors, in the form docker's --cpuset-cpus takes) when it is
# placed, and loses one its caller set when it is not, and gains
# CONTAIN_REGISTRY, and PROOF_RUN_PREFIX when the caller set none: the
# prefix scripts/lib/run-names.sh gives the worktree holding the caller's
# working directory, else the checkout this script lives in, with this
# script's pid. It also gets the count n of its processors (placed) or a
# quarter of the machine's, at least 1 (not placed), as CYFR_TEST_CORES=n,
# CARGO_BUILD_JOBS=n and `+S n:n` after the caller's own ERL_FLAGS, so
# every BEAM, cargo build and Node runner it starts is bounded by it.
#
# The command runs contained (scripts/lib/contain.sh) as the leader of a
# session of its own, without the lock descriptors, and every session
# started under it is listed in a registry this script owns. Before its
# quarter is handed on, the command's session and every session in the
# registry are stopped, within HEAVY_CHECK_GRACE (default 300 s) plus
# 15 s each. If this script is killed outright, the watchdog keeps the
# quarter until the same sessions are stopped. A process that outlives
# KILL turns a 0 into 1: this script waits up to 60 s more for it, its last
# stderr line names any that remain, and the watchdog then keeps the
# quarter for up to HEAVY_CHECK_GRACE plus 15 s more while it stops them
# again.
#
# Each holder writes a record, one line, for example
#   pid=41237 quarter=2 cpus=2,3,10,11 since=2026-10-28T21:14:03+0000 hold=2700s group=41251 watchdog=41250 checkout=/home/x/cyfr command=mix dialyzer
# in LOCK.quarter<i>.holder, where cpus is its processors or `unplaced`,
# checkout its worktree, group the command's process group and watchdog
# its watchdog's pid; each waiter's ticket holds pid=, queued=, tree=, checkout=
# and command= the same way (the grammar is at field() below). A record is
# written whole under another name and renamed into place, so a reader
# finds the one before or the new one, never part of one.
# scripts/janitor.sh reads the pid, group and watchdog of every holder
# record beside the lock. A run is finished when no
# process is left in its group and its watchdog has exited. The record is
# removed at the exit only when the registry ended empty and the run is
# finished, both checked; otherwise it stays until its quarter's next
# holder replaces it, which happens only once the watchdog has released
# it, so a record names its run until the run is finished.
#
# Every check that queued appends, as it exits, one line to the record of
# the host's load, /var/tmp/cyfr/heavy-check.log (on disk; the folder is
# made this user's alone, and one that is a symlink or another user's is
# refused, so that check writes no line and says so): `end=<time>
# quarter=<i or -> waited=<s> ran=<s> exit=<status> checkout=<worktree>
# command=<words>`, waited from its arrival to its start or exit and ran
# from its start, the worktree and the words as the records show them. A
# check queued once its ticket or its holder record is on disk. The line
# is appended holding the file's lock, waited for as long as it takes.
# HEAVY_CHECK_RECORDS names another file: it is the seam of this script's
# own tests and of nothing else.
#
# --status prints, and exits 0: a `held quarter=<i> pid=<pid> cpus=...`
# line for each holder whose run is not finished, with `state=stopped`
# after its pid while that pid is stopped, then a `waiting <i> pid=...`
# line for each live waiter in arrival order, or the word `idle` when
# there are neither.
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
# A queued check says `queued, <i> of <m> waiting, behind:` with the
# records of the runs that hold quarters, if any, as soon as it waits, and
# again every 60 seconds with its place then, its place being the one it
# would be served in now; a check that starts says `running (quarter <i>,
# processors <list>)`, or `not placed: <why>` in place of the processors.
# A `NAME=value` word of the command is shown as `NAME=…` there, in the
# records and in --status, a URL's userinfo in any word as `[redacted]`,
# and a tab or newline in a word as \t or \n. A check that takes every
# quarter in turn and can write no holder's record says so, naming the
# records, and exits 69.
set -uo pipefail

HOLD=2700; STATUS=false
asked=false
usage() { echo "usage: $0 [-t HOLD_SECONDS] [--] command [args] | $0 --status"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status) STATUS=true; shift ;;
    -t)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      HOLD=$2 asked=true
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
case "$HOLD" in ''|*[!0-9]*|0*) echo 'the hold is positive decimal seconds' >&2; exit 64 ;; esac
[ "${#HOLD}" -le 6 ] || { echo 'the hold is at most 999999 seconds' >&2; exit 64; }

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

# The process state of pid $1 in $STATE: empty when there is no such
# process. It starts no process where /proc answers, since the queue is
# read once for every ticket.
state_into() {
  local s
  STATE=
  if [ -r "/proc/$1/stat" ]; then
    read -r s 2>/dev/null <"/proc/$1/stat" || return 0
    s=${s##*) }
    STATE=${s%% *}
  else
    s=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
    STATE=${s// /}
  fi
}
alive() {
  state_into "$1"
  case "$STATE" in ''|Z*|X*|x*) return 1 ;; esac
}
# Whether pid $1 is stopped: state T (or t, traced).
stopped() {
  state_into "$1"
  case "$STATE" in T*|t*) return 0 ;; esac
  return 1
}
pid_ok() { case "${1:-}" in ''|0*|*[!0-9]*) return 1 ;; esac; }
# A path for a record: a backslash, a space, a tab and a newline in it are
# written \\, \s, \t and \n, so it is one word. Two paths are the same
# worktree exactly when their written forms are equal.
encoded() {
  local v=${1//\\/\\\\}
  v=${v// /\\s}
  v=${v//$'\t'/\\t}
  printf '%s' "${v//$'\n'/\\n}"
}
# The grammar of a record line, a holder's, a ticket's or the load
# record's: `name=value` fields in a fixed order, one space between them,
# command= last. No value before command= holds a space (checkout= is
# encoded), so the first ` command=` on the line begins the command, which
# is the rest of the line whatever it holds, and each other field is the
# one word after its name before that point.
# field NAME LINE: the value of that field, empty when the line has none;
# field_into leaves it in $FIELD.
field_into() {
  local line=" $2"
  case "$1" in
    command) FIELD=${line#* command=}; [ "$FIELD" != "$line" ] || FIELD= ;;
    *) line=${line%% command=*}; FIELD=${line#* "$1"=}; [ "$FIELD" != "$line" ] || FIELD=; FIELD=${FIELD%% *} ;;
  esac
}
field() {
  field_into "$@"
  printf '%s' "$FIELD"
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
# The records of the runs that hold quarters and are not finished, for
# the queued lines: what a person reads, never what the order reads.
holders() {
  local i file
  for i in 1 2 3 4; do
    file="$LOCK.quarter$i.holder"
    [ -s "$file" ] && run_live "$file" && head -n 1 "$file"
  done
}
# Seconds since a record's time stamp.
since_seconds() {
  local t
  t=$(date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' "$1" +%s 2>/dev/null) || { echo 0; return; }
  echo $(( $(date +%s) - t ))
}
# The tickets, $LOCK.arrival.<number>.<pid>, as `number pid` lines in
# arrival order.
tickets() {
  local f k n pid
  for f in "$LOCK".arrival.*; do
    k=${f##*.arrival.}
    n=${k%%.*} pid=${k#*.}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "${#n}" -le 15 ] && pid_ok "$pid" || continue
    echo "$((10#$n)) $pid"
  done | sort -n
}
# Whether something holds the lock of ticket file $1. The file is opened
# for reading, so a ticket removed meanwhile is not made again.
ticket_locked() {
  [ -e "$1" ] || return 1
  ! { flock -n -x 9; } 9<"$1" 2>/dev/null
}
# Whether the ticket `$1 $2` is a live waiter's: locked, by an owner that
# runs and is not stopped.
waits() {
  ticket_locked "$LOCK.arrival.$1.$2" && alive "$2" && ! stopped "$2"
}

status() {
  local line i file n=0 any=false k pid state
  for i in 1 2 3 4; do
    file="$LOCK.quarter$i.holder"
    [ -s "$file" ] && run_live "$file" || continue
    line=$(head -n 1 "$file")
    any=true
    pid=$(field pid "$line") state=
    if pid_ok "$pid" && stopped "$pid"; then state=' state=stopped'; fi
    printf 'held quarter=%s pid=%s%s cpus=%s since=%s elapsed=%ss hold=%s checkout=%s command=%s\n' \
      "$(field quarter "$line")" "$pid" "$state" "$(field cpus "$line")" "$(field since "$line")" \
      "$(since_seconds "$(field since "$line")")" "$(field hold "$line")" \
      "$(field checkout "$line")" "$(field command "$line")"
  done
  while read -r k pid; do
    waits "$k" "$pid" || continue
    line=$(head -n 1 "$LOCK.arrival.$k.$pid" 2>/dev/null) || continue
    n=$((n + 1))
    any=true
    printf 'waiting %s pid=%s queued=%s waited=%ss checkout=%s command=%s\n' \
      "$n" "$(field pid "$line")" "$(field queued "$line")" \
      "$(since_seconds "$(field queued "$line")")" "$(field checkout "$line")" "$(field command "$line")"
  done < <(tickets)
  $any || echo idle
}

if $STATUS; then
  command -v flock >/dev/null 2>&1 || { echo 'flock is required (util-linux; on macOS: brew install flock)' >&2; exit 69; }
  status
  exit 0
fi

# A check started by a check already holds its quarter through its
# parent, runs on its parent's processors, and the parent's deadline
# covers it. It writes no line: the parent's frame the run.
case "${HEAVY_CHECK_HELD:-}" in
  '') ;;
  1) exec "$@" ;;
  *) echo 'HEAVY_CHECK_HELD is not what this script sets' >&2; exit 64 ;;
esac

queued_at=$SECONDS
ran_at=
record=
wrote_record=false
owner=false
cmd=
survivors=
run_group= run_watchdog=
finished=false
ticket= held_quarter= step= step_before= since= want_place= tree_id=
# The worktree the check counts against in the queue's order, and its
# written form.
worktree=$(pwd -P)
if top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" 2>/dev/null && pwd -P); then
  worktree=$top
fi
checkout=$(encoded "$worktree")
command_text=$(redacted "$@")

# Every exit after this point passes here, and only here is `_EXIT=`
# written. In order: the command is stopped if it still runs, every
# session in the registry is swept, survivors are waited for, then the
# registry goes; the quarter and the worktree's lock are given back, and
# the holder's record goes when nothing of the run is left; and only then
# the load record's line, which can wait. A 0 that is not the main
# path's own end is the status of whatever ran last before a signal Bash
# dies of, so it is reported as 1.
on_exit() {
  local status=$? p left waited queued=false i f
  trap '' HUP INT TERM
  trap - EXIT
  exec 1>&"$saved_out" 2>&"$saved_err"
  # A locked step still under way is stopped with all it started. What it
  # put on disk says whether this check queued and whether it was admitted
  # (the commit point: its ticket gone, and its record naming its quarter).
  if [ "$step" = starting ]; then
    step=
    [ "${!:-}" = "$step_before" ] || step=$!
  fi
  if [ -n "$step" ]; then kill -KILL -- "-$step" 2>/dev/null; wait "$step" 2>/dev/null; step=; fi
  for f in "$LOCK".arrival.*."$$"; do [ ! -e "$f" ] || queued=true; done
  if [ -z "$held_quarter" ] && [ -n "$since" ]; then
    i=$(own_record)
    if [ -n "$i" ] && $queued; then
      rm -f "$LOCK.quarter$i.holder"
    elif [ -n "$i" ]; then
      held_quarter=$i record="$LOCK.quarter$i.holder" wrote_record=true
    fi
  fi
  [ -z "$held_quarter" ] || queued=true
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
  rm -f "$LOCK.arriving.$$" "$LOCK".arrival.*."$$" "$LOCK".quarter?.writing."$$" "$LOCK.place.$$"
  if $owner; then rm -f "$CONTAIN_REGISTRY"; fi
  # The quarter first, then the worktree's lock, so that the worktree never
  # reads as holding nothing while it holds a quarter; the watchdog's own
  # hold on both ends when it exits, which run_finished has waited for.
  f=false
  if $wrote_record && [ -z "$survivors" ] && run_finished; then f=true; fi
  give_back
  if $f; then rm -f "$record"; fi
  if $queued; then log_run "$status"; fi
  if [ -n "$ran_at" ]; then
    say "exit $status after $((SECONDS - ran_at))s (queued $((ran_at - queued_at))s)"
  fi
  if [ -n "$survivors" ]; then say "still alive after KILL and 60s: $survivors"; fi
  printf '\n_EXIT=%s %s\n' "$$" "$status"
  exit "$status"
}
# The quarter of the holder record that names this check and the start of
# its take, if there is one.
own_record() {
  local i line
  for i in 1 2 3 4; do
    line=$(head -n 1 "$LOCK.quarter$i.holder" 2>/dev/null) || continue
    [ "$(field pid "$line")" = "$$" ] && [ "$(field since "$line")" = "$since" ] || continue
    echo "$i"
    return
  done
}
# Closes every descriptor of a quarter's lock and of the worktree's lock
# this check has, the quarter's first.
give_back() {
  local fd
  exec 7>&- 8>&-
  for fd in ${quarter_fd[@]+"${quarter_fd[@]}"} ${tree_fd:-}; do eval "exec $fd>&-"; done
  quarter_fd=() tree_fd=
}
# log_run STATUS: this check's line in the record of the host's load (the
# header's), appended in a locked child; this check holds nothing by now.
log_run() {
  local file=${HEAVY_CHECK_RECORDS:-} dir=/var/tmp/cyfr waited ran entry
  if [ -z "$file" ]; then
    mkdir -p -m 700 "$dir" 2>/dev/null
    if [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ]; then
      say "no line in the record of the host's load: $dir is not a folder of this user's own"
      return 0
    fi
    file=$dir/heavy-check.log
  fi
  if [ -n "$ran_at" ]; then waited=$((ran_at - queued_at)) ran=$((SECONDS - ran_at)); else waited=$((SECONDS - queued_at)) ran=0; fi
  entry="end=$(date '+%Y-%m-%dT%H:%M:%S%z') quarter=${held_quarter:--} waited=$waited ran=$ran exit=$1 checkout=$checkout command=$command_text"
  locked "$file" append_line "$entry" ||
    say "no line in the record of the host's load: $file cannot be written"
}
append_line() { printf '%s\n' "$1" >&"$lock_fd"; }
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
# The worktree's name among the locks: its path's checksum and length.
tree_id=$(printf '%s' "$worktree" | cksum) || { echo 'cksum is required' >&2; exit 69; }
tree_id=${tree_id// /-}

# The time a stopped check has to stop what it started and clean up
# before this script stops what remains.
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
# The processors of quarter $1, or `unplaced`.
cpus_for() { if $placed; then echo "${QUARTER[$1]}"; else echo unplaced; fi; }

# locked FILE COMMAND...: the command in a child process that holds the
# lock of FILE while it runs, on the descriptor $lock_fd; its status. The
# child is started as a job of its own, outside this check's process
# group, with no terminal on its streams, and this check never holds the
# lock's descriptor: a stop of the check or of its whole group (a
# suspended foreground run), or a terminal that stops background writers,
# leaves the child to finish and release the lock, and a kill of the child
# releases it. The child does file operations only.
locked() {
  local file=$1 s=0
  shift
  # A signal can end this check between the child's start and the next
  # line: the exit then finds the child as the newest job, if there is one.
  step_before=${!:-} step=starting
  set -m
  ( trap - EXIT HUP INT TERM
    exec {lock_fd}>>"$file" && flock -x "$lock_fd" || exit 1
    "$@" ) </dev/null >/dev/null 2>&1 &
  step=$!
  set +m
  wait "$step" || s=$?
  step=
  return "$s"
}

# The queue. A check arrives by its ticket, a file that carries its pid,
# arrival time, worktree and command: written whole and locked under
# $LOCK.arriving.<pid>, then renamed under the queue's lock to
# $LOCK.arrival.<number>.<pid>, the number one more than the highest any
# ticket there has. A number can come again once the tickets above it have
# gone; that is harmless, because numbers are only ever compared between
# tickets present together, and a new ticket's is above every one present
# when it is given. The check holds its ticket's lock until it leaves the
# queue. A waiter whose pid has exited is skipped at once; its ticket is
# removed by the next scan that finds nothing holding its lock. A stopped
# waiter's ticket stays and holds no one back.
number_ticket() {
  local n pid last=0
  while read -r n pid; do last=$n; done < <(tickets)
  mv -f "$LOCK.arriving.$$" "$LOCK.arrival.$((last + 1)).$$"
}
publish_ticket() {
  # A ticket under this pid is an earlier process's, killed while it waited.
  rm -f "$LOCK".arrival.*."$$"
  exec {ticket_fd}>"$LOCK.arriving.$$" || exit 1
  flock -n -x "$ticket_fd" || exit 1
  printf 'pid=%s queued=%s tree=%s checkout=%s command=%s\n' "$$" \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$tree_id" "$checkout" "$command_text" >&"$ticket_fd" || exit 1
  # Whatever the step's end, the ticket on disk is the arrival.
  locked "$LOCK.admission" number_ticket || :
  ticket=$(tickets | sed -n "s/ $$\$//p")
  [ -n "$ticket" ] || exit 1
}
# Whether a check of the worktree $1 holds a quarter: something holds a
# lock on the worktree's file. Asked only under the queue's lock (locked),
# since the question is itself a lock, taken for an instant.
tree_holds() {
  [ -e "$LOCK.tree.$1" ] || return 1
  ! { flock -n -x 9; } 9<"$LOCK.tree.$1" 2>/dev/null
}
# How many live waiters would be served before this one ($ahead) and how
# many wait in all ($waiting), this one included: those of worktrees that
# hold no quarter, in arrival order, then the rest, in arrival order (the
# header's order). Run under the queue's lock: it reads the tickets and
# asks the kernel which worktrees hold a quarter, and no record. A ticket
# nothing locks is removed; a stopped or exited owner holds no one back.
places() {
  local f n pid line mine=0 theirs tree
  local -A holding=()
  ahead=0 waiting=0
  if tree_holds "$tree_id"; then mine=1; fi
  for f in "$LOCK".arriving.*; do
    [ ! -e "$f" ] || ticket_locked "$f" || rm -f "$f"
  done
  for f in "$LOCK".place.*; do
    [ ! -e "$f" ] || alive "${f##*.}" || rm -f "$f"
  done
  while read -r n pid; do
    if [ "$pid" != "$$" ]; then
      f="$LOCK.arrival.$n.$pid"
      if ! ticket_locked "$f"; then rm -f "$f"; continue; fi
      if ! alive "$pid" || stopped "$pid"; then continue; fi
      IFS= read -r line 2>/dev/null <"$f" || continue
      field_into tree "$line"
      tree=$FIELD
      [ -n "$tree" ] || continue
      if [ -z "${holding[$tree]+set}" ]; then
        holding[$tree]=0
        if tree_holds "$tree"; then holding[$tree]=1; fi
      fi
      theirs=${holding[$tree]}
      if [ "$theirs" -lt "$mine" ] || { [ "$theirs" = "$mine" ] && [ "$n" -lt "$ticket" ]; }; then
        ahead=$((ahead + 1))
      fi
    fi
    waiting=$((waiting + 1))
  done < <(tickets)
}
# This check's place, for its queued line, when it has asked for it.
tell_place() {
  [ -z "$want_place" ] || echo "$ahead $waiting" > "$LOCK.place.$$"
}

# The locks: descriptor 7 holds the quarter taken and 8 the worktree's.
record_for() { echo "$LOCK.quarter$1.holder"; }
# The record, whole, under a name no reader looks at, then renamed into
# place.
write_record() {
  local new="$LOCK.quarter$held_quarter.writing.$$"
  [ ! -d "$record" ] &&
    printf 'pid=%s quarter=%s cpus=%s since=%s hold=%ss group=%s watchdog=%s checkout=%s command=%s\n' \
      "$$" "$held_quarter" "$cpus" "$since" "$HOLD" "${1:-}" "${2:-}" "$checkout" "$command_text" > "$new" &&
    mv -f "$new" "$record" || { rm -f "$new"; return 1; }
}
# Run under the queue's lock (locked), so that the order is decided and
# the quarter taken in one step. It takes a free quarter's lock on the
# descriptors the check opened and, holding it, reads the tickets and asks
# which worktrees hold a quarter: a quarter that frees after that is
# another quarter, for the next to be served. If the rule serves another
# waiter first it gives the quarter back. Else it takes the worktree's
# lock, shared, writes the record, and removes the ticket, which is the
# commit: before it this check is not admitted, whatever it holds, and
# after it this check is admitted. It gives the quarter back and tries the
# next if the record was not written. With no quarter free it reads the
# queue only when the check wants its place. Exits 10 + i when it took
# quarter i; 2 when it took all four in turn and could write no record; 1
# otherwise, holding nothing.
take_quarter() {
  local i unwritable=0 ranked=false
  for ((i=1; i<=4; i++)); do
    flock -n -x "${quarter_fd[$i]}" || continue
    if ! $ranked; then
      places
      ranked=true
      if [ "$ahead" != 0 ] || ! flock -n -s "$tree_fd"; then
        flock -u "${quarter_fd[$i]}"
        tell_place
        exit 1
      fi
    fi
    record=$(record_for "$i") cpus=$(cpus_for "$i") held_quarter=$i
    # What a holder killed as it wrote its record left of it.
    rm -f "$LOCK.quarter$i".writing.*
    if write_record 2>/dev/null; then
      rm -f "$LOCK.arrival.$ticket.$$"
      exit $((10 + i))
    fi
    unwritable=$((unwritable + 1))
    flock -u "${quarter_fd[$i]}"
  done
  if $ranked; then flock -u "$tree_fd"; elif [ -n "$want_place" ]; then places; fi
  tell_place
  [ "$unwritable" != 4 ] || exit 2
  exit 1
}
# Opens the descriptors and takes a quarter in a locked child; returns 0
# or 1, and keeps the descriptor of the quarter it took as 7 and of the
# worktree's lock as 8. Closing the rest also gives back what a child that
# ended any other way, killed included, took and could not give back.
admit() {
  local i fd s=0
  for ((i=1; i<=4; i++)); do
    exec {fd}>>"$LOCK.quarter$i" || exit 1
    quarter_fd[$i]=$fd
  done
  exec {tree_fd}>>"$LOCK.tree.$tree_id" || exit 1
  since=$(date '+%Y-%m-%dT%H:%M:%S%z')
  locked "$LOCK.admission" take_quarter || s=$?
  case "$s" in
    1[1-4]) held_quarter=$((s - 10)) s=0 ;;
    2)
      say "no quarter's record can be written: $LOCK.quarter1.holder to $LOCK.quarter4.holder"
      exit 69 ;;
    1) ;;
    *)
      # The step ended some other way, so the disk decides. Its ticket
      # there: this check is not admitted, and a record of its own goes
      # with what it took. Its ticket gone: it is admitted, and its own
      # record, written before the ticket was removed and so always there,
      # says which of its four descriptors holds its quarter. This names a
      # descriptor; it orders nothing.
      i=$(own_record)
      if [ -e "$LOCK.arrival.$ticket.$$" ]; then
        [ -z "$i" ] || rm -f "$LOCK.quarter$i.holder"
        s=1
      else
        [ -n "$i" ] || exit 1
        held_quarter=$i s=0
      fi ;;
  esac
  if [ "$s" = 0 ]; then exec 7>&"${quarter_fd[$held_quarter]}" 8>&"$tree_fd" || exit 1; fi
  for i in "${quarter_fd[@]}" "$tree_fd"; do eval "exec $i>&-"; done
  quarter_fd=() tree_fd=
  return "$s"
}

said_at=
# The queued line, when the check first waits and every REPEAT seconds
# after, with its place then and the holders' records.
announce() {
  local held
  [ -n "$want_place" ] || return 0
  read -r ahead waiting 2>/dev/null <"$LOCK.place.$$" || return 0
  said_at=$SECONDS
  held=$(holders)
  say "queued, $((ahead + 1)) of $waiting waiting, behind:"
  [ -z "$held" ] || printf '%s\n' "$held" | sed 's/^/==> heavy-check:   /' >&2
}

ahead=0 waiting=1
quarter_fd=() tree_fd=
publish_ticket
while :; do
  # The take reads this check's place when its queued line is due.
  want_place=
  if [ -z "$said_at" ] || [ $((SECONDS - said_at)) -ge "$REPEAT" ]; then want_place=1; fi
  if admit; then break; fi
  announce
  sleep 0.5
done
record=$(record_for "$held_quarter") cpus=$(cpus_for "$held_quarter")
wrote_record=true
exec {ticket_fd}>&-
ticket=

ran_at=$SECONDS
if $placed; then where="processors $cpus"; else where="not placed: $unplaced"; fi
say "running (quarter $held_quarter, $where) after $((ran_at - queued_at))s queued: $command_text"

# The outermost check owns the registry. One started by a wrapper that
# already keeps a registry appends to that one and leaves it to its owner.
if [ -z "${CONTAIN_REGISTRY:-}" ]; then
  contain_registry_create || { echo 'cannot create the containment registry' >&2; exit 1; }
  owner=true
fi

# The server refuses a CYFR_ name it does not declare, so what this script
# hands the command is named outside that prefix, or inside the test
# harness's part of it.
export HEAVY_CHECK_HELD=1
if $placed; then export HEAVY_CHECK_CPUS="$cpus"; else unset HEAVY_CHECK_CPUS; fi
if [ -z "${PROOF_RUN_PREFIX:-}" ]; then
  prefix=$(run_names_prefix "$worktree" 2>/dev/null) || prefix=$(run_names_prefix "$here" 2>/dev/null) || prefix=
  if [ -n "$prefix" ]; then export PROOF_RUN_PREFIX="$prefix"; fi
fi
if $placed; then
  share=$(quarters_count "$cpus")
else
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
  share=$(( cores / 4 )); [ "$share" -ge 1 ] || share=1
fi
export CYFR_TEST_CORES="$share" CARGO_BUILD_JOBS="$share"
export ERL_FLAGS="${ERL_FLAGS:+$ERL_FLAGS }+S $share:$share"

# The command never holds the lock descriptor, so nothing it leaves
# behind can keep the quarter. The watchdog holds it instead, so a check
# killed outright keeps its quarter until its command's sessions are gone.
# The command does not hold the saved streams either, so its descriptors
# are its caller's.
CONTAIN_CLOSE_FDS="7 8 $saved_out $saved_err"
CONTAIN_HOLD_FDS="7 8"
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
