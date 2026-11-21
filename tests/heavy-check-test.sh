#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/heavy-check.sh and scripts/await-task.sh against commands that
# stand in for checks: bash tests/heavy-check-test.sh [CASE...], every case
# when none is named. Each case announces itself and leaves the scratch
# lock free behind it, so a case also runs alone.
#
# Every check a case starts runs under a clean environment (`hc` below), so
# it behaves as an outermost check with a lock of its own, even when this
# file itself runs under a check; the `running` line each case asserts is
# the control that it did not run its command in place.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
check="$root/scripts/heavy-check.sh"
await="$root/scripts/await-task.sh"
contain_lib="$root/scripts/lib/contain.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-heavy-test.XXXXXX")
unset HEAVY_CHECK_HELD CONTAIN_REGISTRY CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS CONTAIN_FD_BASE CYFR_TEST_CORES
# A check started under a check gets its parent's prefix, processors and
# count; every check here starts as an outermost one with none of them.
unset PROOF_RUN_PREFIX ERL_FLAGS CARGO_BUILD_JOBS HEAVY_CHECK_REPEAT HEAVY_CHECK_CPUS HEAVY_CHECK_CPU_ROOT
unset AWAIT_PID AWAIT_POLL_SECONDS
# The checks' registries and watchdog pipes are made here, so a case can
# see that none is left.
mkdir "$scratch/tmp"
export TMPDIR="$scratch/tmp"
export HEAVY_CHECK_LOCK="$scratch/lock" HEAVY_CHECK_GRACE=1 HEAVY_CHECK_RECORDS="$scratch/records"
# shellcheck source=../scripts/lib/quarters.sh
. "$root/scripts/lib/quarters.sh"
# topology DIR CORE...: a stand-in sysfs processor directory, each CORE a
# list of thread siblings.
topology() {
  local dir=$1 core cpu all=()
  shift
  mkdir -p "$dir"
  for core in "$@"; do
    for cpu in $(quarters_cpus_of "$core"); do
      mkdir -p "$dir/cpu$cpu/topology"; echo "$core" >"$dir/cpu$cpu/topology/thread_siblings_list"; all+=("$cpu")
    done
  done
  quarters_list "${all[@]}" >"$dir/online"
}
# Every check here is placed on four one-thread cores, the first four
# processors this test may use, so a case sees the same quarters on any
# host with four; t_host reads the host's own.
mine=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status)
read -r -a pick <<<"$(quarters_cpus_of "$mine")"
[ "${#pick[@]}" -ge 4 ] || { echo "the test needs four processors and may use ${#pick[@]} ($mine)" >&2; exit 69; }
Q=('' "${pick[0]}" "${pick[1]}" "${pick[2]}" "${pick[3]}")
ALL4=$(quarters_list "${Q[@]:1}")
topology "$scratch/cpu" "${Q[@]:1}"
export HEAVY_CHECK_CPU_ROOT="$scratch/cpu"
# The processors a Cpus_allowed_list line or a list names, one space apart.
cpus() { quarters_cpus_of "$(sed 's/^Cpus_allowed_list:[[:space:]]*//' <<<"$1")"; }
# probe_cpus DIR: a command for a check that writes, under DIR, what it
# was told and the processors it and a child of it may run on.
probe_cpus() {
  printf '%s' "mkdir -p $1; echo \"\${HEAVY_CHECK_CPUS-unset}\" >$1/told; echo \"\${CYFR_TEST_CORES-unset}\" >$1/count; grep Cpus_allowed_list /proc/self/status >$1/mask; sh -c 'grep Cpus_allowed_list /proc/self/status' >$1/child"
}
clean=(env -u HEAVY_CHECK_HELD -u CONTAIN_REGISTRY -u CONTAIN_CLOSE_FDS -u CONTAIN_HOLD_FDS)
# The directory a check started from here records as its checkout: the
# working directory, physical.
worktree=$(pwd -P)
hc=("${clean[@]}" bash "$check")
# A signal ignored on entry cannot be trapped: a command started in the
# background ignores INT, and one started under nohup ignores HUP, unless
# the signal is reset first.
defaulted=(python3 -I -c 'import os, signal, sys; signal.signal(getattr(signal, "SIG" + sys.argv[1]), signal.SIG_DFL); os.execvp(sys.argv[2], sys.argv[2:])')
with_int=("${defaulted[@]}" INT)
with_hup=("${defaulted[@]}" HUP)
with_usr1=("${defaulted[@]}" USR1)

started=()
# A check is asked to stop, so it stops its command, before anything is
# ended outright. Only a pid that is still this shell's child is signalled,
# and a pid a case recorded in a *.pid file only while it still runs one
# of this file's commands, so a reused pid is never touched.
ours() {
  local s
  read -r s 2>/dev/null <"/proc/$1/stat" || return 1
  s=${s##*) }
  set -- $s
  [ "${2:-}" = "$$" ]
}
cleanup() {
  local pid f n=0
  # A stopped check answers TERM only once it is continued.
  for pid in ${started[@]+"${started[@]}"}; do ours "$pid" && kill -CONT "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null || :; done
  for pid in ${started[@]+"${started[@]}"}; do
    while ours "$pid" && alive "$pid" && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
    ! ours "$pid" || kill -KILL "$pid" 2>/dev/null || :
  done
  for f in "$scratch"/*.pid; do
    [ -s "$f" ] || continue
    pid=$(cat "$f")
    case $pid in ''|0*|*[!0-9]*) continue ;; esac
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
      *sleep*|*"$scratch"*) kill -KILL "$pid" 2>/dev/null || : ;;
    esac
  done
  rm -rf "$scratch"
}
trap 'cleanup 2>/dev/null' EXIT

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
# A bounded wait on an observable condition: `until_true 10 test -e file`.
until_true() {
  local limit=$(( $1 * 10 )) n=0; shift
  until "$@" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
# A process that exists and has not exited; a zombie has exited.
alive() {
  local s
  # An empty pid makes /proc/$1/stat read the host's /proc/stat.
  case ${1:-} in ''|0*|*[!0-9]*) return 1 ;; esac
  read -r s 2>/dev/null <"/proc/$1/stat" || return 1
  s=${s##*) }
  case $s in Z*|X*) return 1 ;; esac
}
dead() { ! alive "$1"; }
is_stopped() {
  local s
  read -r s 2>/dev/null <"/proc/$1/stat" || return 1
  s=${s##*) }
  case $s in T*|t*) ;; *) return 1 ;; esac
}
status_of() { local s=0; "$@" >"$scratch/out" 2>"$scratch/err" || s=$?; echo "$s"; }
has_line() { grep -qE -- "$1" "$2"; }
ran() { has_line '^==> heavy-check: running ' "$1"; }
# The run's stdout is framed by its writer's pid: `_START=<pid>` first,
# `_EXIT=<pid> <status>` last, each exactly once. The writer puts a newline
# before `_EXIT=`, which is an empty line when the command's output ended
# with one.
framed() {
  local file=$1 status=$2 pid=${3:-} first
  first=$(head -n 1 "$file")
  [ -n "$pid" ] || pid=${first#_START=}
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  [ "$first" = "_START=$pid" ] &&
    [ "$(tail -n 1 "$file")" = "_EXIT=$pid $status" ] &&
    [ "$(grep -c '^_START=' "$file")" = 1 ] &&
    [ "$(grep -c '_EXIT=' "$file")" = 1 ]
}
# What the command wrote between the frame's lines, without the newline the
# writer put before `_EXIT=`.
body() { sed '1d' "$1" | sed '$d' | sed '${/^$/d;}'; }
# Every quarter is free: no check holds one, and none waits to.
quarters_free() {
  local q
  for q in 1 2 3 4; do [ ! -e "$HEAVY_CHECK_LOCK.quarter$q" ] || flock -n "$HEAVY_CHECK_LOCK.quarter$q" true || return 1; done
}
host_free() { until_true 30 quarters_free; }
registries() { find "$TMPDIR" -maxdepth 1 -name 'contain-registry.*' | wc -l | tr -d ' '; }
# A check killed outright, or one whose survivors outlived KILL, leaves
# its registry file and its holder record, which stays until its run is
# finished (its pid, group and watchdog gone) and its quarter's next holder
# replaces it; nothing else.
run_finished() {
  local line pid group watchdog
  line=$(head -n 1 "$1")
  pid=$(sed -n 's/^pid=\([0-9]*\) .*/\1/p' <<<"$line")
  group=$(sed -n 's/.* group=\([0-9]*\) .*/\1/p' <<<"$line")
  watchdog=$(sed -n 's/.* watchdog=\([0-9]*\) .*/\1/p' <<<"$line")
  dead "$pid" || return 1
  [ -z "$group" ] || ! kill -0 -- "-$group" 2>/dev/null || return 1
  [ -z "$watchdog" ] || dead "$watchdog"
}
forget_killed() {
  local f
  find "$TMPDIR" -maxdepth 1 -name 'contain-registry.*' -delete
  for f in "$scratch"/lock.quarter{1,2,3,4}.holder; do
    [ -e "$f" ] || continue
    until_true 30 run_finished "$f" || fail "a holder record names a run that is not finished: $(cat "$f")"
    rm -f "$f"
  done
  rm -f "$scratch"/lock.quarter?.holder.*.new
}
# A pid that belonged to a process that has exited.
gone_pid() { local p; sh -c 'exit 0' & p=$!; wait "$p" || :; echo "$p"; }

# Holds until its release file appears, and never past a minute or past the
# scratch directory, so a failed run leaves nothing waiting.
cat > "$scratch/hold" <<'HOLD'
#!/bin/sh
n=0
until [ -e "$1" ] || [ ! -d "$(dirname "$1")" ] || [ "$n" -ge 600 ]; do sleep 0.1; n=$((n + 1)); done
HOLD
# probe OUT PIDFILE...: writes `alive` or `dead` for each pid, as seen when
# it runs.
cat > "$scratch/probe" <<'PROBE'
#!/bin/sh
out=$1; shift
for f in "$@"; do
  p=$(cat "$f")
  if [ -r "/proc/$p/stat" ] && ! sed 's/.*) //' "/proc/$p/stat" | grep -q '^[ZX]'; then
    echo alive
  else
    echo dead
  fi
done > "$out"
PROBE
# A leader that ignores TERM and records its pid, which is its session.
cat > "$scratch/stubborn" <<'STUBBORN'
#!/bin/sh
trap '' TERM
echo $$ > "$1"
while :; do sleep 0.2; done
STUBBORN
# fdprobe OUT: writes each open descriptor and what it names, opening none
# of its own until the list is taken.
cat > "$scratch/fdprobe" <<'FDPROBE'
import os, sys
fds = []
for fd in range(1024):
    try:
        os.fstat(fd)
    except OSError:
        continue
    fds.append("%d %s" % (fd, os.readlink("/proc/self/fd/%d" % fd)))
with open(sys.argv[1], "w") as out:
    out.write("\n".join(fds) + "\n")
FDPROBE
# A BASH_ENV for a check: the check stops, once, the first time its
# function $STOP_FN (or $STOP_FN2) runs a command matching the pattern
# $STOP_CMD (or $STOP_CMD2), and $STOP_MARK is created as it does. In a
# child process of the check, the check stops and the child goes on; with
# $STOP_UNTIL set, the child then waits for that file to appear. The second
# pair names the same moment in b1dfc572c's script, where these cases were
# shown failing.
cat > "$scratch/stop-at" <<'STOPAT'
set -T
trap 'if [[ ! -e $STOP_MARK ]] && { [[ ${FUNCNAME[0]:-} == "$STOP_FN" && $BASH_COMMAND == $STOP_CMD ]] || [[ -n ${STOP_FN2:-} && ${FUNCNAME[0]:-} == "$STOP_FN2" && $BASH_COMMAND == $STOP_CMD2 ]]; }; then : > "$STOP_MARK"; kill -STOP $$; while [[ -n ${STOP_UNTIL:-} && ! -e $STOP_UNTIL ]]; do sleep 0.05; done; fi' DEBUG
STOPAT
chmod +x "$scratch/hold" "$scratch/probe" "$scratch/stubborn"
hold="$scratch/hold"
probe="$scratch/probe"

# --- usage and admission ---------------------------------------------------
t_usage() {
  local q
  [ "$(status_of "${hc[@]}")" = 64 ] || fail 'ran with no command'
  [ "$(status_of "${hc[@]}" -t 0 -- true)" = 64 ] || fail 'accepted a zero hold'
  [ "$(status_of "${hc[@]}" -x -- true)" = 64 ] || fail 'accepted an unknown option'
  [ ! -s "$scratch/out" ] || fail 'a usage error wrote a terminal line'
  # A check takes one quarter: no count is taken, nor a queue deadline, and
  # the removed -s and -p are refused, before the start line, and the
  # command never runs.
  for q in 1 4 2 ''; do
    [ "$(status_of "${hc[@]}" -q "$q" -- touch "$scratch/usage-ran")" = 64 ] || fail "accepted -q '$q'"
    [ ! -s "$scratch/out" ] || fail "a refused -q '$q' wrote a terminal line"
  done
  [ "$(status_of "${hc[@]}" -w 10 -- touch "$scratch/usage-ran")" = 64 ] || fail 'accepted a queue deadline'
  [ "$(status_of "${hc[@]}" -s -- touch "$scratch/usage-ran")" = 64 ] || fail 'accepted the removed -s'
  [ "$(status_of "${hc[@]}" -p -- touch "$scratch/usage-ran")" = 64 ] || fail 'accepted the removed -p'
  [ "$(status_of "${hc[@]}" --status -t 5)" = 64 ] || fail '--status took a hold'
  [ ! -e "$scratch/usage-ran" ] || fail 'a refused command ran'
}

t_admission() {
  # The command's own grammar decides what fits one quarter; the check
  # reads none of it.
  [ "$(status_of "${hc[@]}" -- true scripts/test-partitioned.sh -n 4)" = 0 ] || fail 'did not run the command as given'
  ran "$scratch/err" || fail 'did not run as an outermost check'
  [ "$(status_of "${hc[@]}" -- sh -c 'echo "$HEAVY_CHECK_HELD"')" = 0 ] && [ "$(body "$scratch/out")" = 1 ] ||
    fail "a check held $(body "$scratch/out"), not one quarter"
}

# A check inside a check runs in place, on its parent's processors, framed
# by the parent alone; a HEAVY_CHECK_HELD this script never sets is
# refused.
t_nested() {
  local held
  [ "$(status_of "${hc[@]}" -- bash "$check" -- sh -c 'exit 5')" = 5 ] || fail 'a nested check did not run under its parent'
  framed "$scratch/out" 5 || fail "a nested check wrote lines of its own: $(tr '\n' '|' < "$scratch/out")"
  [ "$(status_of "${hc[@]}" -- bash "$check" -- sh -c "$(probe_cpus "$scratch/nested")")" = 0 ] || fail 'a nested check did not run'
  framed "$scratch/out" 0 || fail "a nested check wrote lines of its own: $(tr '\n' '|' < "$scratch/out")"
  [ "$(cat "$scratch/nested/told")" = "${Q[1]}" ] && [ "$(cpus "$(cat "$scratch/nested/mask")")" = "${Q[1]}" ] &&
    [ "$(cpus "$(cat "$scratch/nested/child")")" = "${Q[1]}" ] && [ "$(cat "$scratch/nested/count")" = 1 ] ||
    fail "a nested check did not keep its parent's quarter: $(cat "$scratch/nested"/*)"
  for held in 4 exclusive scoped proof 2 0 x; do
    [ "$(status_of "${clean[@]}" HEAVY_CHECK_HELD="$held" bash "$check" -- touch "$scratch/nested-ran")" = 64 ] || fail "ran under HEAVY_CHECK_HELD=$held"
    [ ! -s "$scratch/out" ] || fail "a check refused under HEAVY_CHECK_HELD=$held wrote a terminal line"
  done
  [ ! -e "$scratch/nested-ran" ] || fail 'a refused nested command ran'
}

# --- the command's own result ----------------------------------------------
t_result() {
  [ "$(status_of "${hc[@]}" -- sh -c 'echo said; exit 7')" = 7 ] || fail "lost the command's status"
  framed "$scratch/out" 7 || fail "the run was not framed: $(tr '\n' '|' < "$scratch/out")"
  [ "$(body "$scratch/out")" = said ] || fail "lost the command's output"
  has_line "^==> heavy-check: running \\(quarter 1, processors ${Q[1]}\\) after [0-9]+s queued: sh -c echo said; exit 7\$" "$scratch/err" || fail "did not say it started: $(cat "$scratch/err")"
  has_line '^==> heavy-check: exit 7 after [0-9]+s \(queued [0-9]+s\)$' "$scratch/err" || fail 'did not say how it ended'
  [ ! -e "$scratch/lock.quarter1.holder" ] || fail 'left its holder record'
  status_of "${hc[@]}" -- sh -c 'echo "$HEAVY_CHECK_HELD ${CYFR_TEST_CORES:-whole}"' >/dev/null
  [ "$(body "$scratch/out")" = '1 1' ] || fail "a check was not given its quarter's count: $(body "$scratch/out")"
}

# The frame carries the check's own pid, the one its starter knows, and a
# command whose last write ends without a newline does not glue onto it.
# A passing run's line says 0: the success path is checked, not assumed.
t_frame() {
  local p s=0
  "${hc[@]}" -- true >"$scratch/pass.out" 2>"$scratch/pass.err" &
  p=$!; started+=("$p")
  wait "$p" || s=$?
  [ "$s" = 0 ] || fail "a passing check exited $s"
  ran "$scratch/pass.err" || fail 'the passing check did not run as an outermost check'
  framed "$scratch/pass.out" 0 "$p" || fail "a passing check was not framed by _EXIT=$p 0: $(tr '\n' '|' < "$scratch/pass.out")"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p status_of bash "$await" "$scratch/pass.out" '' 10)" = 0 ] || fail 'the waiter did not answer a passing check 0'
  s=0
  "${hc[@]}" -- sh -c 'printf unterminated; exit 3' >"$scratch/frame.out" 2>"$scratch/frame.err" &
  p=$!; started+=("$p")
  wait "$p" || s=$?
  [ "$s" = 3 ] || fail "exited $s"
  framed "$scratch/frame.out" 3 "$p" || fail "not framed by pid $p: $(tr '\n' '|' < "$scratch/frame.out")"
  # Byte for byte: the newline before `_EXIT=` ends the command's last line.
  [ "$(od -An -c "$scratch/frame.out")" = "$(printf '_START=%s\nunterminated\n_EXIT=%s 3\n' "$p" "$p" | od -An -c)" ] ||
    fail "the frame was not exact: $(tr '\n' '|' < "$scratch/frame.out")"
}

# The server refuses a CYFR_ name it does not declare: the names a check
# adds to its command's environment are exactly these.
t_roster() {
  env | sed 's/=.*//' > "$scratch/env-before"
  "${hc[@]}" -- env 2>/dev/null > "$scratch/env-raw"
  body "$scratch/env-raw" | sed 's/=.*//' > "$scratch/env-inside"
  added=$(grep -vxF -f "$scratch/env-before" "$scratch/env-inside" | LC_ALL=C sort | tr '\n' ' ')
  [ "$added" = 'CARGO_BUILD_JOBS CONTAIN_REGISTRY CYFR_TEST_CORES ERL_FLAGS HEAVY_CHECK_CPUS HEAVY_CHECK_HELD PROOF_RUN_PREFIX ' ] || fail "a check added: $added"
}

# The command's descriptors are its caller's: the quarter's lock descriptor
# and the script's own copies of its streams are closed in it, and a
# caller's 5, 6 and 12 reach it unshadowed.
t_fds() {
  local p=(python3 -I "$scratch/fdprobe")
  "${p[@]}" "$scratch/fds-direct" 5>"$scratch/five" 6>"$scratch/six" 12</dev/null >"$scratch/fd.out" 2>"$scratch/fd.err" ||
    fail 'the probe failed on its own'
  "${hc[@]}" -- "${p[@]}" "$scratch/fds-checked" 5>"$scratch/five" 6>"$scratch/six" 12</dev/null >"$scratch/fd.out" 2>"$scratch/fd.err" ||
    fail "the checked probe failed: $(tail -n 2 "$scratch/fd.err")"
  ran "$scratch/fd.err" || fail 'did not run as an outermost check'
  has_line "^5 $scratch/five\$" "$scratch/fds-direct" || fail "the control did not see the caller's 5: $(tr '\n' '|' < "$scratch/fds-direct")"
  [ "$(cat "$scratch/fds-checked")" = "$(cat "$scratch/fds-direct")" ] ||
    fail "the command's descriptors differ from its caller's: $(tr '\n' '|' < "$scratch/fds-checked") against $(tr '\n' '|' < "$scratch/fds-direct")"
}

# The library's watchdog pipes start at CONTAIN_FD_BASE: a caller that
# leaves no descriptor free below it is refused before the command runs.
t_fd_base() {
  [ "$(status_of "${hc[@]}" -- touch "$scratch/fd-base-ran" 10</dev/null 11</dev/null 12</dev/null 13</dev/null 14</dev/null \
    15</dev/null 16</dev/null 17</dev/null 18</dev/null 19</dev/null)" = 64 ] || fail 'ran with its streams saved in the watchdog range'
  framed "$scratch/out" 64 || fail "the refusal was not framed: $(tr '\n' '|' < "$scratch/out")"
  has_line '^no descriptor is free below CONTAIN_FD_BASE \(20\)' "$scratch/err" || fail 'did not say why'
  [ ! -e "$scratch/fd-base-ran" ] || fail 'the refused command ran'
}

# The library is found beside the script, wherever it is started from.
t_elsewhere() {
  local s=0
  (cd / && "${hc[@]}" -- true) >"$scratch/out" 2>"$scratch/err" || s=$?
  [ "$s" = 0 ] || fail "started from / it exited $s: $(tail -n 2 "$scratch/err")"
  ran "$scratch/err" || fail 'did not run'
}

# --- the quarters ---------------------------------------------------------------
# scripts/lib/quarters.sh: whole cores, a core's threads in one quarter,
# in the order of their lowest processor; a core with a thread offline is
# no whole core; the cores past four equal quarters are left over; fewer
# than four whole cores, or no processor directory, cut no quarters.
t_cut() {
  local smt=() c
  for c in 0 1 2 3 4 5 6 7; do smt+=("$c,$((c + 8))"); done
  topology "$scratch/smt16" "${smt[@]}"
  quarters_cut "$scratch/smt16" || fail "no quarters from 8 cores of two threads: $QUARTERS_WHY"
  [ "${QUARTER[*]}" = '0,1,8,9 2,3,10,11 4,5,12,13 6,7,14,15' ] || fail "the quarters of 8 cores of two threads: ${QUARTER[*]}"
  [ "$QUARTERS_ALL" = 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 ] && [ -z "$QUARTERS_LEFT" ] || fail "all $QUARTERS_ALL, left $QUARTERS_LEFT"
  # Siblings written as a range and listed in any order, ten cores.
  topology "$scratch/ten" 9,19 0-1 2-3 4-5 6-7 8,18 10-11 12-13 14-15 16-17
  quarters_cut "$scratch/ten" || fail "no quarters from ten cores: $QUARTERS_WHY"
  [ "${QUARTER[*]}" = '0,1,2,3 4,5,6,7 8,9,18,19 10,11,12,13' ] || fail "the quarters of ten cores: ${QUARTER[*]}"
  [ "$QUARTERS_LEFT" = 14,15,16,17 ] || fail "ten cores left $QUARTERS_LEFT"
  # A core whose sibling is offline is no whole core.
  topology "$scratch/offline" 0,4 1,5 2,6 3,7 8,9
  echo 0-8 >"$scratch/offline/online"
  quarters_cut "$scratch/offline" || fail "no quarters from four whole cores and a half: $QUARTERS_WHY"
  [ "${QUARTER[*]}" = '0,4 1,5 2,6 3,7' ] && [ -z "$QUARTERS_LEFT" ] || fail "a half core was used: ${QUARTER[*]} left $QUARTERS_LEFT"
  topology "$scratch/three" 0 1 2
  ! quarters_cut "$scratch/three" || fail "three cores cut quarters: ${QUARTER[*]}"
  [ "$QUARTERS_WHY" = 'this host has 3 whole cores, and four quarters need four' ] || fail "three cores: $QUARTERS_WHY"
  ! quarters_cut "$scratch/none" || fail 'no processor directory cut quarters'
  [ "$QUARTERS_WHY" = "cannot read the online processors in $scratch/none/online" ] || fail "no directory: $QUARTERS_WHY"
}

# The host's own processors: placed, a check on one quarter runs on what
# it is told and is told its count; not placed, it says so and is told no
# processors.
t_host() {
  rm -rf "$scratch/host"
  [ "$(status_of "${clean[@]}" -u HEAVY_CHECK_CPU_ROOT bash "$check" -- sh -c "$(probe_cpus "$scratch/host")")" = 0 ] || fail "the probe failed: $(cat "$scratch/err")"
  if has_line '^==> heavy-check: running \(quarter [1-4], processors ' "$scratch/err"; then
    [ "$(cpus "$(cat "$scratch/host/mask")")" = "$(quarters_cpus_of "$(cat "$scratch/host/told")")" ] &&
      [ "$(cpus "$(cat "$scratch/host/child")")" = "$(quarters_cpus_of "$(cat "$scratch/host/told")")" ] ||
      fail "told $(cat "$scratch/host/told"), it runs on $(cat "$scratch/host/mask") and its child on $(cat "$scratch/host/child")"
    [ "$(cat "$scratch/host/count")" = "$(quarters_count "$(cat "$scratch/host/told")")" ] || fail "told $(cat "$scratch/host/told"), its count is $(cat "$scratch/host/count")"
    echo "  this host's first quarter: $(cat "$scratch/host/told")"
  else
    has_line '^==> heavy-check: running \(quarter [1-4], not placed: ' "$scratch/err" || fail "the running line: $(cat "$scratch/err")"
    [ "$(cat "$scratch/host/told")" = unset ] || fail "an unplaced check was told $(cat "$scratch/host/told")"
    echo "  this host is not placed: $(sed -n 's/.*not placed: \(.*\)) after.*/\1/p' "$scratch/err")"
  fi
}

# A host where taskset cannot place a process, or with fewer than four
# whole cores: quarters are counted and not placed. The running line,
# the record and --status say so, the command runs on the processors its
# caller had, is told no processors, a caller's included, and is given a
# quarter of the machine's count; four such checks hold every quarter and
# a fifth waits.
t_unplaced() {
  local why kind i pids=() count
  mkdir -p "$scratch/notaskset"
  printf '#!/bin/sh\nexit 1\n' >"$scratch/notaskset/taskset"
  chmod +x "$scratch/notaskset/taskset"
  topology "$scratch/cpu3" "${Q[1]}" "${Q[2]}" "${Q[3]}"
  count=$(( $(nproc) / 4 )); [ "$count" -ge 1 ] || count=1
  for kind in cores taskset; do
    case $kind in
      cores) set -- HEAVY_CHECK_CPU_ROOT="$scratch/cpu3"; why='this host has 3 whole cores, and four quarters need four' ;;
      taskset) set -- PATH="$scratch/notaskset:$PATH"; why="taskset cannot place a process on $ALL4 here" ;;
    esac
    rm -rf "$scratch"/un* "$scratch"/release-*
    pids=()
    for i in 1 2 3 4 5; do
      env "$@" HEAVY_CHECK_CPUS=stale "${hc[@]}" -- sh -c "$(probe_cpus "$scratch/un$i"); $hold $scratch/release-un$i" >/dev/null 2>"$scratch/un$i.err" &
      pids+=("$!"); started+=("$!")
      [ "$i" = 5 ] || until_true 10 test -s "$scratch/un$i/child" || fail "$kind: unplaced check $i did not start beside the others"
    done
    until_true 10 has_line '^==> heavy-check: queued, 1 of 1 waiting' "$scratch/un5.err" || fail "$kind: a fifth unplaced check did not wait"
    has_line "^==> heavy-check: running \\(quarter 1, not placed: $why\\) after " "$scratch/un1.err" || fail "$kind: the running line: $(cat "$scratch/un1.err")"
    [ "$(cat "$scratch/un1/told")" = unset ] || fail "$kind: an unplaced check was told $(cat "$scratch/un1/told")"
    [ "$(cpus "$(cat "$scratch/un1/mask")")" = "$(cpus "$mine")" ] && [ "$(cpus "$(cat "$scratch/un1/child")")" = "$(cpus "$mine")" ] ||
      fail "$kind: an unplaced check runs on $(cat "$scratch/un1/mask"), not its caller's $mine"
    [ "$(cat "$scratch/un1/count")" = "$count" ] || fail "$kind: an unplaced check's count is $(cat "$scratch/un1/count"), not $count"
    has_line '^pid=[0-9]+ quarter=1 cpus=unplaced since=' "$scratch/lock.quarter1.holder" || fail "$kind: the record: $(cat "$scratch/lock.quarter1.holder")"
    "${hc[@]}" --status >"$scratch/un.status"
    [ "$(grep -c '^held quarter=[1-4] pid=[0-9]* cpus=unplaced since=' "$scratch/un.status")" = 4 ] || fail "$kind: --status: $(cat "$scratch/un.status")"
    touch "$scratch/release-un2"
    until_true 10 test -s "$scratch/un5/child" || fail "$kind: the fifth unplaced check never started"
    touch "$scratch"/release-un{1,3,4,5}
    for i in "${pids[@]}"; do wait "$i"; done
  done
}

# A NAME=value word of the command never reaches another check or a file.
t_redaction() {
  local a b p
  # The hold script reads only its first argument; the URLs ride along.
  "${hc[@]}" -- env CYFR_DATABASE_URL=postgres://u:secret@h/db "$hold" "$scratch/release-r" \
    --url=postgres://u:secret2@h/db https://secret3@h/x postgres://u:pa@secret4@h/db >/dev/null 2>"$scratch/r1.err" &
  a=$!; started+=("$a")
  until_true 10 test -s "$scratch/lock.quarter1.holder" || fail 'the holder left no record'
  ! grep -q secret "$scratch/lock.quarter1.holder" || fail "the holder's record carries the value: $(cat "$scratch/lock.quarter1.holder")"
  has_line '^pid=[0-9]+ .* command=env CYFR_DATABASE_URL=… .* --url=postgres://\[redacted\]@h/db https://\[redacted\]@h/x postgres://\[redacted\]@h/db$' "$scratch/lock.quarter1.holder" ||
    fail "the record lost the name or the URLs' shape: $(cat "$scratch/lock.quarter1.holder")"
  hold_others rd 3
  "${hc[@]}" -- true >/dev/null 2>"$scratch/r2.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued, 1 of 1 waiting, behind:$' "$scratch/r2.err" || fail 'the second check did not queue'
  has_line '^==> heavy-check:   pid=[0-9]+ .*command=env CYFR_DATABASE_URL=… .* --url=postgres://\[redacted\]@h/db ' "$scratch/r2.err" || fail 'the queued check did not name the holder'
  touch "$scratch/release-r" "$scratch"/release-rd{1,2,3}
  for p in "$a" "${quarter_holders[@]}" "$b"; do wait "$p"; done
  ! grep -q secret "$scratch/r1.err" "$scratch/r2.err" "$scratch/records" || fail "the value reached a check's stderr or the record of the host's load"
}

# hold_quarters TAG: four checks that hold every quarter until
# release-TAG<n> appears.
hold_quarters() { hold_others "$1" 4; }
# hold_others TAG N: N more checks that each hold a quarter until
# release-TAG<n> appears; their pids in $quarter_holders, and each one's
# processors in TAG<n>.cpus.
hold_others() {
  local n
  quarter_holders=()
  # A case that uses a tag again must not read its earlier holders' files
  # as these holders having started.
  rm -f "$scratch/$1"[0-9].cpus
  for ((n = 1; n <= $2; n++)); do
    "${hc[@]}" -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/$1$n.cpus.new && mv $scratch/$1$n.cpus.new $scratch/$1$n.cpus; $hold $scratch/release-$1$n" >/dev/null 2>&1 &
    quarter_holders+=("$!"); started+=("$!")
    until_true 10 test -s "$scratch/$1$n.cpus" || fail "quarter holder $n did not start"
  done
}
# The quarter whose processors are $1.
quarter_of() { local q; for q in 1 2 3 4; do [ "${Q[$q]}" != "$1" ] || { echo "$q"; return; }; done; echo none; }

# A check on one quarter killed outright keeps its quarter, and only it,
# until its command's sessions are gone: the other three holders keep
# theirs and run on, a fifth check waits naming the killed run, and it
# runs on the killed check's quarter once the watchdog has stopped the
# command.
t_killed_quarter() {
  local k n i leader record kq p
  rm -f "$scratch"/kq*.cpus
  "${clean[@]}" HEAVY_CHECK_GRACE=30 bash "$check" -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/kq0.cpus; exec $scratch/stubborn $scratch/kq.pid" >/dev/null 2>"$scratch/kq1.err" &
  k=$!; started+=("$k")
  until_true 10 test -s "$scratch/kq.pid" || fail 'the command did not start'
  leader=$(cat "$scratch/kq.pid")
  kq=$(quarter_of "$(cat "$scratch/kq0.cpus")")
  [ "$kq" = 1 ] || fail "the first check took quarter $kq"
  until_true 10 has_line " group=$leader watchdog=[0-9]+ " "$scratch/lock.quarter1.holder" || fail "the record does not name the command's group: $(cat "$scratch/lock.quarter1.holder" 2>/dev/null)"
  quarter_holders=()
  for i in 2 3 4; do
    "${hc[@]}" -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/kq$i.cpus.new && mv $scratch/kq$i.cpus.new $scratch/kq$i.cpus; $hold $scratch/release-kq; echo kq$i >> $scratch/order" >/dev/null 2>&1 &
    quarter_holders+=("$!"); started+=("$!")
    until_true 10 test -s "$scratch/kq$i.cpus" || fail "holder $i did not start"
  done
  kill -KILL "$k"
  wait "$k" 2>/dev/null || :
  record=$(cat "$scratch/lock.quarter1.holder")
  "${hc[@]}" -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/kq5.cpus" >/dev/null 2>"$scratch/kq2.err" &
  n=$!; started+=("$n")
  until_true 10 has_line "^==> heavy-check:   pid=$k quarter=1 cpus=${Q[1]} .* group=$leader watchdog=[0-9]+ " "$scratch/kq2.err" ||
    fail "did not queue naming the killed check's run: $(cat "$scratch/kq2.err")"
  sleep 1
  [ ! -e "$scratch/kq5.cpus" ] || fail "ran beside the killed check's command, on $(cat "$scratch/kq5.cpus")"
  [ "$(cat "$scratch/lock.quarter1.holder")" = "$record" ] || fail "the killed check's record changed while its run lived"
  for p in "${quarter_holders[@]}"; do alive "$p" || fail "an unrelated holder $p ended"; done
  for i in 2 3 4; do flock -n "$scratch/lock.quarter$i" true && fail "quarter $i was free while its holder ran"; done
  [ ! -e "$scratch/order" ] || fail "an unrelated holder's command ended: $(cat "$scratch/order")"
  kill -KILL "$leader"
  wait "$n" || fail 'the queued check failed'
  [ "$(cat "$scratch/kq5.cpus")" = "${Q[1]}" ] || fail "the fifth check ran on $(cat "$scratch/kq5.cpus"), not the killed check's quarter ${Q[1]}"
  touch "$scratch/release-kq"
  for p in "${quarter_holders[@]}"; do wait "$p"; done
  forget_killed
}

# --- four side by side on four quarters, the fifth waits ----------------------
# Each check is told a quarter no other holds, and it and
# its child run on exactly those processors; a fifth waits, and runs on the
# quarter that frees.
t_quarters() {
  local i pids=() seen=' ' c
  rm -rf "$scratch"/sq*
  for i in 1 2 3 4 5; do
    "${hc[@]}" -- sh -c "$(probe_cpus "$scratch/sq$i"); $hold $scratch/release-s$i" >/dev/null 2>"$scratch/s$i.err" &
    pids+=("$!"); started+=("$!")
    [ "$i" = 5 ] || until_true 10 test -s "$scratch/sq$i/child" || fail "check $i did not start beside the others"
  done
  until_true 10 has_line '^==> heavy-check: queued, 1 of 1 waiting' "$scratch/s5.err" || fail 'a fifth check was not queued'
  [ ! -e "$scratch/sq5" ] || fail 'a fifth check started'
  for i in 1 2 3 4; do
    c=$(cat "$scratch/sq$i/told")
    [ "$(quarter_of "$c")" != none ] || fail "check $i was told $c, no quarter"
    case $seen in *" $c "*) fail "two checks were told quarter $c" ;; esac
    seen="$seen$c "
    [ "$(cpus "$(cat "$scratch/sq$i/mask")")" = "$(quarters_cpus_of "$c")" ] || fail "check $i runs on $(cat "$scratch/sq$i/mask"), not its quarter $c"
    [ "$(cpus "$(cat "$scratch/sq$i/child")")" = "$(quarters_cpus_of "$c")" ] || fail "check $i's child runs on $(cat "$scratch/sq$i/child"), not its quarter $c"
    [ "$(cat "$scratch/sq$i/count")" = "$(quarters_count "$c")" ] || fail "check $i was given the count $(cat "$scratch/sq$i/count") for $c"
  done
  touch "$scratch/release-s3"
  until_true 10 test -s "$scratch/sq5/child" || fail 'the fifth check never started'
  [ "$(cat "$scratch/sq5/told")" = "$(cat "$scratch/sq3/told")" ] || fail "the fifth check was told $(cat "$scratch/sq5/told"), not the freed $(cat "$scratch/sq3/told")"
  touch "$scratch/release-s1" "$scratch/release-s2" "$scratch/release-s4" "$scratch/release-s5"
  for i in "${pids[@]}"; do wait "$i"; done
}

# Placement replaces the caller's: a check started narrower still runs on
# the quarter it was given.
t_placement() {
  rm -rf "$scratch/pl"
  [ "$(status_of taskset -c "${Q[4]}" "${hc[@]}" -- sh -c "$(probe_cpus "$scratch/pl")")" = 0 ] || fail "the narrowed probe failed: $(cat "$scratch/err")"
  [ "$(cpus "$(cat "$scratch/pl/mask")")" = "${Q[1]}" ] || fail "a check started on ${Q[4]} runs on $(cat "$scratch/pl/mask"), not quarter 1"
}

# --- waiters take quarters in the order they queued --------------------------
# A waiter that polls first is not the one that queued first: every round
# frees one quarter to two waiters queued in order, and the earlier one
# runs. The second arrives half a second after the first and the quarter
# frees at a random moment after that, so a queue that served whoever
# polled next would give the second the quarter in most rounds.
t_quarter_order() {
  local round a b p
  for round in 1 2 3 4 5 6 7 8; do
    rm -f "$scratch"/release-* "$scratch/order" "$scratch"/so*.cpus "$scratch"/so[AB].err
    hold_quarters so
    "${hc[@]}" -- sh -c "echo A >> $scratch/order; $hold $scratch/release-w" >/dev/null 2>"$scratch/soA.err" &
    a=$!; started+=("$a")
    until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/soA.err" || fail "round $round: the first waiter did not queue"
    sleep 0.5
    "${hc[@]}" -- sh -c "echo B >> $scratch/order; $hold $scratch/release-w" >/dev/null 2>"$scratch/soB.err" &
    b=$!; started+=("$b")
    until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/soB.err" || fail "round $round: the second waiter did not queue"
    sleep "0.$((RANDOM % 10))"
    touch "$scratch/release-so$(( (round - 1) % 4 + 1 ))"
    until_true 10 test -s "$scratch/order" || fail "round $round: no waiter ran after a quarter freed"
    [ "$(cat "$scratch/order")" = A ] || fail "round $round: the later waiter took the quarter: $(tr '\n' ' ' < "$scratch/order")"
    touch "$scratch/release-w" "$scratch"/release-so{1,2,3,4}
    for p in "${quarter_holders[@]}" "$a" "$b"; do wait "$p"; done
    [ "$(tr '\n' ' ' < "$scratch/order")" = 'A B ' ] || fail "round $round: the waiters did not both run in order: $(tr '\n' ' ' < "$scratch/order")"
  done
}
# A waiter killed outright leaves its ticket's file, which no longer holds
# anyone back.
t_quarter_stale() {
  local a b p
  rm -f "$scratch/order"
  hold_quarters st
  "${hc[@]}" -- true >/dev/null 2>"$scratch/stA.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/stA.err" || fail 'the first waiter did not queue'
  kill -KILL "$a"; wait "$a" 2>/dev/null || :
  [ -n "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'the killed waiter left no ticket to step over'
  "${hc[@]}" -- sh -c "echo B >> $scratch/order" >/dev/null 2>"$scratch/stB.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/stB.err" || fail 'the second waiter did not queue'
  touch "$scratch/release-st1"
  until_true 10 has_line '^B$' "$scratch/order" || fail "a dead waiter's ticket kept a later one waiting"
  touch "$scratch"/release-st{2,3,4}
  for p in "${quarter_holders[@]}" "$b"; do wait "$p"; done
}

# A stopped waiter holds back no one: a later waiter takes the quarter that
# frees, and the stopped one runs once it is continued.
t_quarter_stopped() {
  local a b p
  rm -f "$scratch/order"
  hold_quarters ss
  "${hc[@]}" -- sh -c "echo A >> $scratch/order" >/dev/null 2>"$scratch/ssA.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/ssA.err" || fail 'the first waiter did not queue'
  kill -STOP "$a"
  until_true 5 is_stopped "$a" || fail 'the first waiter was not stopped'
  "${hc[@]}" -- sh -c "echo B >> $scratch/order" >/dev/null 2>"$scratch/ssB.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/ssB.err" || fail 'the second waiter did not queue'
  touch "$scratch/release-ss1"
  until_true 10 has_line '^B$' "$scratch/order" || fail 'a stopped waiter held back a later one'
  kill -CONT "$a"
  touch "$scratch"/release-ss{2,3,4}
  for p in "${quarter_holders[@]}" "$a" "$b"; do wait "$p"; done
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'B A ' ] || fail "the continued waiter did not run after: $(tr '\n' ' ' < "$scratch/order")"
}

# --- a waiter holds nothing ---------------------------------------------------
# A check that finds no quarter free holds nothing while it waits: stopped
# in the queue behind four holders, it keeps no quarter, so once they end
# a check that arrived after it runs. And a take interrupted after it took
# a quarter, its child killed before the record, leaves nothing taken:
# stopped as soon as it goes on, the check holds nothing, so another check
# runs; continued, it takes a quarter afresh, the first again, and the
# other three stay free.
# The take's child stops itself once, at $STOP_CMD in $STOP_FN, writing its
# pid to $STOP_MARK.pid first; once it has, the check stops itself at the
# start of the next queued line it says, creating $STOP_MARK.check.
t_all_or_none() {
  local x y child s p
  rm -f "$scratch/order" "$scratch"/stopped-mark*
  hold_quarters an
  "${hc[@]}" -- sh -c "echo X >> $scratch/order" >/dev/null 2>"$scratch/anX.err" &
  x=$!; started+=("$x")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/anX.err" || fail 'the check did not queue behind four holders'
  kill -STOP "$x"
  until_true 5 is_stopped "$x" || fail 'the waiter did not stop'
  # A take it had under way ends on its own: every child it has left has
  # exited, unreaped while it is stopped.
  until_true 5 sh -c "! ps -o stat= --ppid $x | grep -qv '^Z'" || fail "the stopped waiter's take did not end: $(ps -o pid=,stat=,args= --ppid "$x")"
  touch "$scratch"/release-an{1,2,3,4}
  for p in "${quarter_holders[@]}"; do wait "$p"; done
  [ "$(status_of timeout 20 "${hc[@]}" -- sh -c "echo Y >> $scratch/order")" = 0 ] ||
    fail "a check behind a waiter that found no quarter free exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
  kill -CONT "$x"
  wait "$x" || fail 'the continued waiter failed'
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'Y X ' ] || fail "the order was $(tr '\n' ' ' < "$scratch/order")"
  # Interrupted: the take's child dies holding quarter 1.
  rm -f "$scratch/order" "$scratch/an.cpus"
  cat > "$scratch/kill-at" <<'KILLAT'
set -T
trap 'if [[ ! -e $STOP_MARK && ${FUNCNAME[0]:-} == "$STOP_FN" && $BASH_COMMAND == $STOP_CMD ]]; then echo $BASHPID > "$STOP_MARK.pid"; : > "$STOP_MARK"; kill -STOP $BASHPID; elif [[ -e $STOP_MARK && ! -e $STOP_MARK.check && ${FUNCNAME[0]:-} == announce ]]; then : > "$STOP_MARK.check"; kill -STOP $$; fi' DEBUG
KILLAT
  "${clean[@]}" BASH_ENV="$scratch/kill-at" STOP_MARK="$scratch/stopped-mark" STOP_FN=take_quarter STOP_CMD='write_record*' \
    bash "$check" -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/an.cpus; $hold $scratch/release-an" >/dev/null 2>"$scratch/anI.err" &
  y=$!; started+=("$y")
  until_true 10 test -e "$scratch/stopped-mark" || fail 'the take did not reach the point after its quarter'
  child=$(cat "$scratch/stopped-mark.pid")
  until_true 5 is_stopped "$child" || fail 'the take did not stop'
  flock -n "$scratch/lock.quarter1" true && fail 'the stopped take did not hold quarter 1'
  kill -KILL "$child"
  until_true 10 test -e "$scratch/stopped-mark.check" || fail "the check did not go on after its take was killed: $(cat "$scratch/anI.err")"
  until_true 5 is_stopped "$y" || fail 'the check did not stop after its take was killed'
  [ "$(status_of timeout 20 "${hc[@]}" -- sh -c "echo Y >> $scratch/order")" = 0 ] ||
    fail "a check behind one stopped after its take was killed exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
  kill -CONT "$y"
  until_true 10 test -s "$scratch/an.cpus" || fail "the check did not run after its take was killed: $(cat "$scratch/anI.err")"
  [ "$(cat "$scratch/an.cpus")" = "${Q[1]}" ] || fail "the check ran on $(cat "$scratch/an.cpus"), not quarter 1 afresh"
  for s in 2 3 4; do flock -n "$scratch/lock.quarter$s" true || fail "quarter $s was held after the killed take"; done
  touch "$scratch/release-an"
  wait "$y" || fail 'the check whose take was killed failed'
}

# A take that does not end with a quarter gives back what it took before
# its child exits, so its check, stopped meanwhile, holds nothing: the
# take found no quarter free (four holders, which then end), or quarter
# 1's record could not be written (a directory in its place), so the take
# gave quarter 1 back and went on. Each time a check that needs what the
# stopped one took runs at once, and the stopped one, continued, runs.
t_stopped_take() {
  local how x s p
  for how in none record; do
    rm -f "$scratch/order" "$scratch/stopped-mark"
    set -- STOP_FN=take_quarter
    case $how in
      none)
        hold_quarters sf
        set -- "$@" STOP_CMD='exit 1' ;;
      record)
        mkdir "$scratch/lock.quarter1.holder"
        set -- "$@" STOP_CMD='flock -u*' ;;
    esac
    "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark" "$@" \
      bash "$check" -- sh -c "echo X >> $scratch/order" >"$scratch/sf.out" 2>"$scratch/sf.err" &
    x=$!; started+=("$x")
    until_true 10 test -e "$scratch/stopped-mark" || fail "$how: the take did not reach its hook: $(cat "$scratch/sf.err")"
    until_true 5 is_stopped "$x" || fail "$how: the check did not stop"
    until_true 5 sh -c "! ps -o stat= --ppid $x | grep -qv '^Z'" || fail "$how: the stopped check's take did not end"
    if [ "$how" = none ]; then
      touch "$scratch"/release-sf{1,2,3,4}
      for p in "${quarter_holders[@]}"; do wait "$p"; done
    fi
    # What the stopped check took is what this one needs.
    [ "$(status_of timeout 20 "${hc[@]}" -- sh -c "echo Y >> $scratch/order")" = 0 ] ||
      fail "$how: a check behind a stopped one whose take ended exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
    [ "$how" != record ] || rmdir "$scratch/lock.quarter1.holder"
    kill -CONT "$x"
    s=0; wait "$x" || s=$?
    [ "$s" = 0 ] || fail "$how: the continued check exited $s: $(cat "$scratch/sf.err")"
    [ "$(tr '\n' ' ' < "$scratch/order")" = 'Y X ' ] || fail "$how: the order was $(tr '\n' ' ' < "$scratch/order")"
  done
}

# A check stopped in its first-in-line test keeps no one waiting: a later
# check starts at once, without queuing, the stopped one keeps its ticket,
# and once continued it runs too.
t_admission_stopped() {
  local a s t
  rm -f "$scratch/order" "$scratch/stopped-mark"
  "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_FN=places STOP_CMD='ahead=0 waiting=0' STOP_MARK="$scratch/stopped-mark" \
    bash "$check" -- sh -c "echo stopped >> $scratch/order" >/dev/null 2>"$scratch/as1.err" &
  a=$!; started+=("$a")
  until_true 10 test -e "$scratch/stopped-mark" || fail 'the check did not reach its first-in-line test'
  until_true 5 is_stopped "$a" || fail 'the check did not stop'
  t=$SECONDS
  [ "$(status_of timeout 20 "${hc[@]}" -- sh -c "echo later >> $scratch/order")" = 0 ] ||
    fail "a later check behind one stopped in admission exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
  [ $((SECONDS - t)) -le 3 ] || fail "a later check waited $((SECONDS - t))s behind one stopped in admission"
  has_line '^==> heavy-check: running \(quarter ' <(grep '^==> heavy-check: ' "$scratch/err" | sed -n 1p) ||
    fail "the later check did not start at once: $(grep '^==> heavy-check: ' "$scratch/err")"
  [ "$(cat "$scratch/order")" = later ] || fail "the later check did not run: $(cat "$scratch/order" 2>/dev/null)"
  [ -n "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'the stopped check lost its ticket'
  kill -CONT "$a"
  s=0; wait "$a" || s=$?
  [ "$s" = 0 ] || fail "the continued check exited $s"
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'later stopped ' ] || fail "the continued check did not run after: $(tr '\n' ' ' < "$scratch/order")"
}

# Arrival is a ticket's publication: a check stopped as it publishes
# arrives when it is continued, after the checks that published meanwhile,
# which keep their order. (On b1dfc572c it is stopped as it writes the
# ticket counter, and resumed writes it back.)
t_ticket_order() {
  local a c d p
  rm -f "$scratch/order" "$scratch/stopped-mark"
  hold_quarters to
  "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark" \
    STOP_FN=publish_ticket STOP_CMD='ticket=*' STOP_FN2=take_ticket STOP_CMD2='*LOCK.seq*' \
    bash "$check" -- sh -c "echo A >> $scratch/order" >/dev/null 2>"$scratch/toA.err" &
  a=$!; started+=("$a")
  until_true 10 test -e "$scratch/stopped-mark" || fail 'the first check did not reach its publication'
  until_true 5 is_stopped "$a" || fail 'the first check did not stop'
  "${hc[@]}" -- sh -c "echo C >> $scratch/order" >/dev/null 2>"$scratch/toC.err" &
  c=$!; started+=("$c")
  until_true 10 has_line '^==> heavy-check: queued, 1 of 1 waiting' "$scratch/toC.err" || fail "the second check did not queue first: $(cat "$scratch/toC.err")"
  "${hc[@]}" -- sh -c "echo D >> $scratch/order" >/dev/null 2>"$scratch/toD.err" &
  d=$!; started+=("$d")
  until_true 10 has_line '^==> heavy-check: queued, 2 of 2 waiting' "$scratch/toD.err" || fail "the third check did not queue second: $(cat "$scratch/toD.err")"
  kill -CONT "$a"
  until_true 10 has_line '^==> heavy-check: queued, 3 of 3 waiting' "$scratch/toA.err" ||
    fail "the continued check did not arrive last: $(cat "$scratch/toA.err")"
  # One quarter frees: the three take it in turn.
  touch "$scratch/release-to1"
  for p in "$c" "$d" "$a"; do wait "$p" || fail "check $p failed"; done
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'C D A ' ] || fail "the checks ran out of arrival order: $(tr '\n' ' ' < "$scratch/order")"
  touch "$scratch"/release-to{2,3,4}
  for p in "${quarter_holders[@]}"; do wait "$p"; done
}

# Admission never waits on another waiter: with one check stopped in its
# first-in-line test and another stopped about to take its quarter (on
# b1dfc572c, one holding the admission lock and one about to replace it),
# a third starts at once, without queuing, and the two run once continued.
t_admission_two_stopped() {
  local a b c p
  rm -f "$scratch/order" "$scratch"/stopped-mark*
  "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark-a" STOP_FN=places STOP_CMD='ahead=0 waiting=0' \
    bash "$check" -- sh -c "echo A >> $scratch/order" >/dev/null 2>"$scratch/tsA.err" &
  a=$!; started+=("$a")
  until_true 10 test -e "$scratch/stopped-mark-a" || fail 'the first check did not reach its first-in-line test'
  until_true 5 is_stopped "$a" || fail 'the first check did not stop'
  "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark-b" \
    STOP_FN=admit STOP_CMD='since=*' STOP_FN2=queue_lock STOP_CMD2='mv -f *' \
    bash "$check" -- sh -c "echo B >> $scratch/order" >/dev/null 2>"$scratch/tsB.err" &
  b=$!; started+=("$b")
  until_true 10 test -e "$scratch/stopped-mark-b" || fail 'the second check did not reach its take'
  until_true 5 is_stopped "$b" || fail 'the second check did not stop'
  [ "$(status_of timeout 20 "${hc[@]}" -- sh -c "echo C >> $scratch/order")" = 0 ] || fail "the third check exited: $(cat "$scratch/err")"
  has_line '^==> heavy-check: running \(quarter ' <(grep '^==> heavy-check: ' "$scratch/err" | sed -n 1p) ||
    fail "the third check did not start at once: $(grep '^==> heavy-check: ' "$scratch/err")"
  [ "$(cat "$scratch/order")" = C ] || fail "the third check did not run alone: $(tr '\n' ' ' < "$scratch/order")"
  kill -CONT "$a" "$b"
  for p in "$a" "$b"; do wait "$p" || fail "a continued check $p failed"; done
  [ "$(sort "$scratch/order" | tr '\n' ' ')" = 'A B C ' ] || fail "the continued checks did not both run: $(tr '\n' ' ' < "$scratch/order")"
}

# A holder stopped just after it took its quarter, before it wrote its
# record, keeps it: with the other three held, --status shows it held and
# stopped, a later check queues behind it naming it, and the holder runs
# once continued, then the later one.
t_stopped_holder() {
  local a b s p
  rm -f "$scratch/order" "$scratch/stopped-mark"
  hold_others sh 3
  "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark" \
    STOP_FN=take_quarter STOP_CMD='write_record*' \
    bash "$check" -- sh -c "echo held >> $scratch/order" >/dev/null 2>"$scratch/shA.err" &
  a=$!; started+=("$a")
  until_true 10 test -e "$scratch/stopped-mark" || fail 'the check did not reach its take'
  until_true 5 is_stopped "$a" || fail 'the check did not stop'
  until_true 5 sh -c "'$check' --status | grep -q '^held quarter=4 pid=$a state=stopped cpus='" ||
    fail "--status with the holder stopped: $("${hc[@]}" --status)"
  "${hc[@]}" -- sh -c "echo later >> $scratch/order" >/dev/null 2>"$scratch/shB.err" &
  b=$!; started+=("$b")
  until_true 10 has_line "^==> heavy-check:   pid=$a quarter=4 " "$scratch/shB.err" || fail "the queued check did not name the stopped holder: $(cat "$scratch/shB.err")"
  [ ! -e "$scratch/order" ] || fail "a check ran beside the stopped holder: $(cat "$scratch/order")"
  kill -CONT "$a"
  s=0; wait "$a" || s=$?
  [ "$s" = 0 ] || fail "the continued holder exited $s"
  wait "$b" || fail 'the queued check failed'
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'held later ' ] || fail "the order was $(tr '\n' ' ' < "$scratch/order")"
  touch "$scratch"/release-sh{1,2,3}
  for p in "${quarter_holders[@]}"; do wait "$p"; done
}

# --- waiters outside the queue: a killed or stopped waiter holds back no one -----
t_waiters_skipped() {
  local a b p
  rm -f "$scratch/order" "$scratch"/release-*
  hold_quarters wk
  # A waiter killed outright leaves its ticket, which no longer counts.
  "${hc[@]}" -- sh -c "echo killed >> $scratch/order" >/dev/null 2>"$scratch/wk.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/wk.err" || fail 'the waiter did not queue'
  kill -KILL "$a"; wait "$a" 2>/dev/null || :
  "${hc[@]}" -- sh -c "echo later >> $scratch/order" >/dev/null 2>"$scratch/wl.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued, 1 of 1 waiting' "$scratch/wl.err" ||
    fail "a killed waiter still counted ahead: $(cat "$scratch/wl.err")"
  touch "$scratch"/release-wk{1,2,3,4}
  for p in "${quarter_holders[@]}" "$b"; do wait "$p"; done
  [ "$(cat "$scratch/order")" = later ] || fail "a killed waiter held back a later one: $(tr '\n' ' ' < "$scratch/order")"
  # A stopped waiter: a later one passes it, and it runs once continued.
  rm -f "$scratch/order" "$scratch"/release-*
  hold_quarters ws
  "${hc[@]}" -- sh -c "echo stopped >> $scratch/order" >/dev/null 2>"$scratch/ws.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/ws.err" || fail 'the waiter did not queue'
  kill -STOP "$a"
  until_true 5 is_stopped "$a" || fail 'the waiter was not stopped'
  rm -f "$scratch/wl.err"
  "${hc[@]}" -- sh -c "echo later >> $scratch/order" >/dev/null 2>"$scratch/wl.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued, 1 of 1 waiting' "$scratch/wl.err" ||
    fail "a stopped waiter still counted ahead: $(cat "$scratch/wl.err")"
  touch "$scratch"/release-ws{1,2,3,4}
  for p in "${quarter_holders[@]}" "$b"; do wait "$p"; done
  [ "$(cat "$scratch/order")" = later ] || fail "a stopped waiter held back a later one: $(tr '\n' ' ' < "$scratch/order")"
  kill -CONT "$a"; wait "$a"
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'later stopped ' ] || fail "the continued waiter did not run after: $(tr '\n' ' ' < "$scratch/order")"
}

# --- the run record: the command's group and its watchdog ------------------------
t_run_record() {
  local file=lock.quarter1.holder a line group watchdog
  # The command writes its pid whole under a name of its own: a file read
  # while it is written would stand for this command's pid.
  rm -f "$scratch"/release-* "$scratch/rr.pid"
  "${hc[@]}" -- sh -c "echo \$\$ > $scratch/rr.pid.new && mv $scratch/rr.pid.new $scratch/rr.pid; $hold $scratch/release-rr" >/dev/null 2>&1 &
  a=$!; started+=("$a")
  until_true 10 test -s "$scratch/rr.pid" || fail 'the command did not start'
  until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/$file" || fail "the record names no watchdog: $(cat "$scratch/$file" 2>/dev/null)"
  line=$(cat "$scratch/$file")
  group=$(sed -n 's/.* group=\([0-9]*\) .*/\1/p' <<<"$line")
  watchdog=$(sed -n 's/.* watchdog=\([0-9]*\) .*/\1/p' <<<"$line")
  [ "$group" = "$(cat "$scratch/rr.pid")" ] || fail "the record names the group $group, not the command's $(cat "$scratch/rr.pid")"
  [ "$(ps -o pgid= -p "$(cat "$scratch/rr.pid")" | tr -d ' ')" = "$group" ] || fail 'the command does not lead the group its record names'
  alive "$watchdog" || fail "the record names the watchdog $watchdog, which is not running"
  tr '\0' ' ' < "/proc/$watchdog/cmdline" | grep -q '__contain_watchdog' || fail "the record names $watchdog, not a watchdog"
  has_line "^pid=$a quarter=1 cpus=${Q[1]} since=[0-9T:+-]+ hold=2700s group=$group watchdog=$watchdog checkout=$worktree command=sh -c " "$scratch/$file" ||
    fail "the record is not in the documented form: $line"
  touch "$scratch/release-rr"; wait "$a"
  [ ! -e "$scratch/$file" ] || fail 'a finished run left its record'
  until_true 10 dead "$watchdog" || fail 'the watchdog outlived its run'
}
# A command that ends while its watchdog lives, here a stopped one, leaves
# a run that is not finished: its record stays, its quarter stays held and
# --status shows it held, until the watchdog exits.
t_record_watchdog() {
  local file=lock.quarter1.holder lock=lock.quarter1 a s line watchdog
  rm -f "$scratch"/release-*
  "${hc[@]}" -- "$hold" "$scratch/release-rw" >/dev/null 2>"$scratch/rw.err" &
  a=$!; started+=("$a")
  until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/$file" || fail "the record names no watchdog: $(cat "$scratch/$file" 2>/dev/null)"
  line=$(cat "$scratch/$file")
  watchdog=$(sed -n 's/.* watchdog=\([0-9]*\) .*/\1/p' <<<"$line")
  kill -STOP "$watchdog"
  touch "$scratch/release-rw"
  s=0; wait "$a" || s=$?
  [ "$s" = 0 ] || { kill -CONT "$watchdog"; fail "the check exited $s"; }
  [ "$(cat "$scratch/$file" 2>/dev/null)" = "$line" ] || { kill -CONT "$watchdog"; fail 'the record went while its watchdog lived'; }
  flock -n "$scratch/$lock" true && { kill -CONT "$watchdog"; fail "$lock was free while the watchdog lived"; }
  "${hc[@]}" --status >"$scratch/rw.status" 2>&1
  has_line "^held quarter=1 pid=$a " "$scratch/rw.status" || { kill -CONT "$watchdog"; fail "--status with the watchdog alive: $(cat "$scratch/rw.status")"; }
  kill -CONT "$watchdog"
  until_true 10 dead "$watchdog" || fail 'the watchdog did not exit once continued'
  [ "$(status_of "${hc[@]}" --status)" = 0 ] && [ "$(cat "$scratch/out")" = idle ] || fail "the host was not idle once the watchdog exited: $(cat "$scratch/out")"
  forget_killed
}

# --- the environment ---------------------------------------------------------------
t_environment() {
  local p seed share
  # A caller's prefix passes unchanged.
  PROOF_RUN_PREFIX=mine- "${hc[@]}" -- sh -c 'echo "$PROOF_RUN_PREFIX"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = mine- ] || fail "a caller's PROOF_RUN_PREFIX became $(body "$scratch/out")"
  # An absent one becomes the caller's worktree's prefix, with this check's pid.
  . "$root/scripts/lib/run-names.sh"
  seed=$(run_names_seed "$root")
  (cd "$root" && "${hc[@]}" -- sh -c 'echo "$PROOF_RUN_PREFIX"') >"$scratch/out" 2>/dev/null
  p=$(sed -n 's/^_START=//p' "$scratch/out")
  [ "$(body "$scratch/out")" = "cyfr-$seed-$p-" ] || fail "the injected prefix is $(body "$scratch/out"), not cyfr-$seed-$p-"
  [[ "$(body "$scratch/out")" =~ $RUN_NAMES_PATTERN ]] || fail 'the injected prefix does not match RUN_NAMES_PATTERN'
  # Outside a worktree, the checkout the script lives in names it.
  (cd "$scratch" && "${hc[@]}" -- sh -c 'echo "$PROOF_RUN_PREFIX"') >"$scratch/out" 2>/dev/null
  p=$(sed -n 's/^_START=//p' "$scratch/out")
  [ "$(body "$scratch/out")" = "cyfr-$seed-$p-" ] || fail "outside a worktree the prefix is $(body "$scratch/out"), not the script's checkout's"
  # A caller's ERL_FLAGS keeps its words, the quarter's +S after them; the
  # count is the quarter's processors, one each here.
  ERL_FLAGS='+sbwt none -kernel inet_dist_use_interface {127,0,0,1}' "${hc[@]}" -- sh -c 'echo "$ERL_FLAGS|$CYFR_TEST_CORES|$CARGO_BUILD_JOBS"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = "+sbwt none -kernel inet_dist_use_interface {127,0,0,1} +S 1:1|1|1" ] ||
    fail "the environment was $(body "$scratch/out")"
  # A command gets the folder on disk as TMPDIR when its caller set none,
  # and keeps a caller's own.
  (env -u TMPDIR "${hc[@]}" -- sh -c 'echo "$TMPDIR"') >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = /var/tmp/cyfr ] || fail "a check with no TMPDIR was given $(body "$scratch/out")"
  [ -d /var/tmp/cyfr ] && [ ! -L /var/tmp/cyfr ] && [ -O /var/tmp/cyfr ] || fail '/var/tmp/cyfr is not a folder of this user'"'"'s own'
  "${hc[@]}" -- sh -c 'echo "$TMPDIR"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = "$TMPDIR" ] || fail "a caller's TMPDIR became $(body "$scratch/out")"
  # A caller's HEAVY_CHECK_CPUS is replaced by the check's own.
  HEAVY_CHECK_CPUS=stale "${hc[@]}" -- sh -c 'echo "$HEAVY_CHECK_CPUS"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = "${Q[1]}" ] || fail "a caller's HEAVY_CHECK_CPUS became $(body "$scratch/out")"
}

# --- status ----------------------------------------------------------------------
t_status() {
  local a b gone p
  [ "$(status_of "${hc[@]}" --status)" = 0 ] || fail '--status failed on an idle host'
  [ "$(cat "$scratch/out")" = idle ] || fail "an idle host's status was: $(cat "$scratch/out")"
  [ ! -s "$scratch/err" ] || fail "--status wrote to stderr: $(cat "$scratch/err")"
  [ "$(status_of "${hc[@]}" --status -- true)" = 64 ] || fail '--status took a command'
  # A record whose run has finished is never shown: here one naming a pid
  # that has exited and neither group nor watchdog, as a stub.
  gone=$(gone_pid)
  printf 'pid=%s quarter=4 cpus=%s since=2026-10-28T21:02:41+0000 hold=3600s group= watchdog= checkout=/nowhere command=gone\n' "$gone" "${Q[4]}" > "$scratch/lock.quarter4.holder"
  "${hc[@]}" -- "$hold" "$scratch/release-st" >/dev/null 2>&1 &
  a=$!; started+=("$a")
  until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/lock.quarter1.holder" || fail 'the holder did not start'
  [ "$(status_of "${hc[@]}" --status)" = 0 ] || fail '--status failed'
  [ "$(wc -l < "$scratch/out" | tr -d ' ')" = 1 ] || fail "--status did not print the one live holder: $(cat "$scratch/out")"
  has_line "^held quarter=1 pid=$a cpus=${Q[1]} since=[0-9T:+-]+ elapsed=[0-9]+s hold=2700s checkout=$worktree command=$hold $scratch/release-st\$" "$scratch/out" ||
    fail "the holder line: $(cat "$scratch/out")"
  if grep -q "pid=$gone" "$scratch/out"; then fail 'a dead holder was shown'; fi
  hold_others sto 3
  "${hc[@]}" -- true >/dev/null 2>"$scratch/stw.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/stw.err" || fail 'the waiter did not queue'
  [ "$(status_of "${hc[@]}" --status)" = 0 ] || fail '--status failed'
  [ "$(grep -c '^held ' "$scratch/out")" = 4 ] || fail "--status did not print four holders: $(cat "$scratch/out")"
  has_line "^waiting 1 pid=$b queued=[0-9T:+-]+ waited=[0-9]+s checkout=$worktree command=true\$" <(sed -n 5p "$scratch/out") ||
    fail "the waiter line: $(sed -n 5p "$scratch/out")"
  touch "$scratch/release-st" "$scratch"/release-sto{1,2,3}
  for p in "$a" "${quarter_holders[@]}" "$b"; do wait "$p"; done
  [ "$(status_of "${hc[@]}" --status)" = 0 ] && [ "$(cat "$scratch/out")" = idle ] || fail "the host was not idle after: $(cat "$scratch/out")"
}

# --- a queued check repeats its place ------------------------------------------------
t_queued_repeat() {
  local a b w s=0 p
  hold_quarters qr
  HEAVY_CHECK_REPEAT=1 "${hc[@]}" -- true >"$scratch/qa.out" 2>"$scratch/qa.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued, 1 of 1 waiting, behind:$' "$scratch/qa.err" || fail 'the first waiter did not queue'
  # Its output and its queued lines in one file, as a task's output is kept.
  HEAVY_CHECK_REPEAT=1 "${hc[@]}" -- true >"$scratch/qb.out" 2>&1 &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued, 2 of 2 waiting, behind:$' "$scratch/qb.out" || fail 'the second waiter did not say its place'
  until_true 10 has_line '^==> heavy-check: queued, 1 of 2 waiting, behind:$' "$scratch/qa.err" || fail 'the first waiter did not repeat its place'
  [ "$(grep -c '^==> heavy-check: queued' "$scratch/qa.err")" -ge 2 ] || fail 'the queued line was not repeated'
  # The waiter keeps a run deadline from running while the lines repeat.
  AWAIT_POLL_SECONDS=1 AWAIT_PID=$b bash "$await" "$scratch/qb.out" '' 2 >"$scratch/await.out" 2>"$scratch/await.err" &
  w=$!; started+=("$w")
  sleep 4  # sleep-ok: the window in which a run deadline of 2 s would have ended the wait
  alive "$w" || fail "the waiter ended while the check was queued: $(cat "$scratch/await.err")"
  touch "$scratch"/release-qr{1,2,3,4}
  for p in "${quarter_holders[@]}" "$a" "$b"; do wait "$p"; done
  wait "$w" || s=$?
  [ "$s" = 0 ] || fail "the waiter answered $s: $(cat "$scratch/await.err")"
}

# --- the hold deadline: what the command started is dead when the status is in
t_hold() {
  [ "$(status_of "${hc[@]}" -t 1 -- sh -c "sleep 120 & echo \$! > $scratch/held.pid; wait")" = 124 ] || fail 'a check past its hold was not stopped with 124'
  dead "$(cat "$scratch/held.pid")" || fail "a stopped check's child was alive when it exited"
  has_line '^==> heavy-check: hold deadline after 1s' "$scratch/err" || fail 'the hold deadline was not reported'
  framed "$scratch/out" 124 || fail 'the deadline path was not framed'
  [ "$(status_of "${hc[@]}" -t 1 -- "$scratch/stubborn" "$scratch/stubborn.pid")" = 124 ] || fail 'a check that ignores TERM was not stopped'
  dead "$(cat "$scratch/stubborn.pid")" || fail 'a command that ignores TERM survived its grace'
  [ "$(status_of "${hc[@]}" -t 1 -- bash -c "set -m; sleep 120 & echo \$! > $scratch/grouped.pid; wait")" = 124 ] || fail 'a check with a group of its own was not stopped'
  dead "$(cat "$scratch/grouped.pid")" || fail 'a process in a group of its own survived the deadline'
  [ "$(status_of timeout 20 "${hc[@]}" -- true)" = 0 ] || fail 'the host was not free after a stopped check'
  # A command's own 124 is not a deadline.
  [ "$(status_of "${hc[@]}" -t 100 -- sh -c 'exit 124')" = 124 ] || fail "lost the command's own 124"
  ! has_line 'hold deadline' "$scratch/err" || fail 'a command that exited 124 by itself was reported as stopped'
  has_line '^==> heavy-check: exit 124 after ' "$scratch/err" || fail 'did not say how it ended'
}

t_hold_frame() {
  local p s=0
  "${hc[@]}" -t 1 -- sleep 120 >"$scratch/hf.out" 2>/dev/null &
  p=$!; started+=("$p")
  wait "$p" || s=$?
  [ "$s" = 124 ] || fail "exited $s"
  framed "$scratch/hf.out" 124 "$p" || fail "not framed by pid $p"
}

# --- a stage's rows side by side on this queue ----------------------------------
# scripts/stage.sh queues every row that names no folder when the stage
# starts: two of them hold a quarter each at once, each told its own
# processors, and a stage stopped while they run stops both and gives every
# quarter back (the loop below the cases checks that none is left held). The
# rows of one folder hold one quarter between them, one after another, and a
# stage stopped while one runs stops it and gives the quarter back. A ticket
# killed after its rows passed fails the stage, and a ticket whose stage is
# killed starts no more rows.
t_stage_side_by_side() {
  local repo=$scratch/stage-repo s=0 one two runner held ticket nested
  rm -rf "$repo" "$scratch"/stage-logs*
  mkdir -p "$repo/scripts/lib"
  git init -q -b main "$repo"
  cp "$root/scripts/stage.sh" "$check" "$repo/scripts/"
  cp "$root"/scripts/lib/*.sh "$repo/scripts/lib/"
  rows() { printf 'handoff\t%s\t1\t60\t-\talways\t%s\n' "$@" >"$repo/scripts/stages.tsv"; }
  # Each row records its processors and waits, at most 10 s, for the other's.
  meets() { printf 'echo "$HEAVY_CHECK_CPUS" >"$STAGE_LOGDIR/%s.cpus"; for _ in $(seq 100); do [ -e "$STAGE_LOGDIR/%s.cpus" ] && exit 0; sleep 0.1; done; exit 1' "$1" "$2"; }
  rows one "$(meets one two)" two "$(meets two one)"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=test -c user.email=test@invalid commit -q -m 'the stage runner and a table'
  (cd "$repo" && STAGE_BASE=HEAD "${clean[@]}" bash scripts/stage.sh -l "$scratch/stage-logs" handoff) >"$scratch/stage.out" 2>&1 || s=$?
  [ "$s" = 0 ] || fail "the stage exited $s: $(tr '\n' '|' <"$scratch/stage.out")"
  one=$(cat "$scratch/stage-logs/one.cpus") two=$(cat "$scratch/stage-logs/two.cpus")
  [ "$one" != "$two" ] || fail "the two rows were both told $one"
  for held in "$one" "$two"; do
    case " ${Q[*]:1} " in *" $held "*) ;; *) fail "a row was told '$held', not one quarter's processors" ;; esac
  done
  rows slow-one 'exec sleep 6121' slow-two 'exec sleep 6122'
  (cd "$repo" && STAGE_BASE=HEAD exec "${clean[@]}" bash scripts/stage.sh -l "$scratch/stage-logs-2" handoff) >"$scratch/stage2.out" 2>&1 &
  runner=$!; started+=("$runner")
  until_true 10 pgrep -f '^sleep 6121$' >/dev/null && until_true 10 pgrep -f '^sleep 6122$' >/dev/null ||
    fail 'the two rows never ran side by side'
  [ "$("${hc[@]}" --status | grep -c '^held quarter=')" = 2 ] || fail "the queue showed: $("${hc[@]}" --status | tr '\n' '|')"
  held=$(pgrep -f '^sleep 612[12]$' | tr '\n' ' ')
  s=0
  kill -TERM "$runner"
  until_true 10 eval '! kill -0 "$runner"' || fail 'the stage was still running 10 s after TERM'
  wait "$runner" || s=$?
  [ "$s" = 143 ] || fail "the stopped stage exited $s, not 143"
  for one in $held; do dead "$one" || fail "a row's command outlived the stopped stage"; done
  [ "$("${hc[@]}" --status)" = idle ] || fail "the queue still showed: $("${hc[@]}" --status | tr '\n' '|')"
  printf 'handoff\t%s\t1\t60\tdev\talways\techo "$HEAVY_CHECK_CPUS" >"$STAGE_LOGDIR/%s.cpus"%s\n' \
    first first '' second second '; exec sleep 6123' >"$repo/scripts/stages.tsv"
  (cd "$repo" && STAGE_BASE=HEAD exec "${clean[@]}" bash scripts/stage.sh -l "$scratch/stage-logs-3" handoff) >"$scratch/stage3.out" 2>&1 &
  runner=$!; started+=("$runner")
  until_true 10 pgrep -f '^sleep 6123$' >/dev/null || fail "the folder's second row never ran: $(tr '\n' '|' <"$scratch/stage3.out")"
  [ "$("${hc[@]}" --status | grep -c '^held quarter=')" = 1 ] ||
    fail "the folder's rows did not hold one quarter between them: $("${hc[@]}" --status | tr '\n' '|')"
  one=$(cat "$scratch/stage-logs-3/first.cpus") two=$(cat "$scratch/stage-logs-3/second.cpus")
  [ "$one" = "$two" ] || fail "the folder's rows were told $one and $two"
  case " ${Q[*]:1} " in *" $one "*) ;; *) fail "the folder's rows were told '$one', not one quarter's processors" ;; esac
  held=$(pgrep -f '^sleep 6123$' | tr '\n' ' ')
  s=0
  kill -TERM "$runner"
  until_true 10 eval '! kill -0 "$runner"' || fail 'the stage was still running 10 s after TERM'
  wait "$runner" || s=$?
  [ "$s" = 143 ] || fail "the stopped stage exited $s, not 143"
  for one in $held; do dead "$one" || fail "a folder's row outlived the stopped stage"; done
  [ "$("${hc[@]}" --status)" = idle ] || fail "the queue still showed: $("${hc[@]}" --status | tr '\n' '|')"
  # The row passes and leaves a session of its own that takes 6 s to stop,
  # so the ticket is still stopping it when it is killed.
  printf 'handoff\tfirst\t1\t60\tdev\talways\t%s\n' \
    '. scripts/lib/contain.sh; contain_start bash -c '"'"'trap "sleep 6; exit 0" TERM; echo $$ >"$STAGE_LOGDIR/nested.pid"; while :; do sleep 0.2; done'"'"'; for _ in $(seq 100); do [ -s "$STAGE_LOGDIR/nested.pid" ] && exit 0; sleep 0.05; done; exit 1' \
    >"$repo/scripts/stages.tsv"
  (cd "$repo" && STAGE_BASE=HEAD exec "${clean[@]}" bash scripts/stage.sh -l "$scratch/stage-logs-4" handoff) >"$scratch/stage4.out" 2>"$scratch/stage4.err" &
  runner=$!; started+=("$runner")
  until_true 20 grep -q '^0 0 ' "$scratch/stage-logs-4/dev.results" || fail "the row never passed: $(tr '\n' '|' <"$scratch/stage4.out")"
  ticket=$(sed -n 's/^_START=//p' "$scratch/stage-logs-4/dev.queue.log") nested=$(cat "$scratch/stage-logs-4/nested.pid")
  kill -0 "$ticket" || fail 'the ticket had already ended'
  kill -KILL "$ticket"
  s=0; wait "$runner" || s=$?
  [ "$s" = 1 ] || fail "a stage whose ticket was killed after its row passed exited $s: $(tr '\n' '|' <"$scratch/stage4.out")"
  grep -qx 'first: ok [0-9]*s' "$scratch/stage4.out" && grep -qx 'dev ticket: failed 137 [0-9]*s' "$scratch/stage4.out" ||
    fail "the summary: $(tr '\n' '|' <"$scratch/stage4.out")"
  until_true 30 dead "$nested" || fail "the killed ticket's session outlived its watchdog"
  until_true 30 eval '[ "$("${hc[@]}" --status)" = idle ]' || fail "the queue still showed: $("${hc[@]}" --status | tr '\n' '|')"
  forget_killed
  # The stage is killed while the first row runs: the row ends as it
  # would, and the second never starts.
  printf 'handoff\t%s\t1\t60\tdev\talways\t%s\n' \
    first 'echo $$ >"$STAGE_LOGDIR/first.pid"; for _ in $(seq 300); do [ -e "$STAGE_LOGDIR/go" ] && exit 0; sleep 0.1; done; exit 1' \
    second 'touch "$STAGE_LOGDIR/second.ran"' >"$repo/scripts/stages.tsv"
  (cd "$repo" && STAGE_BASE=HEAD exec "${clean[@]}" bash scripts/stage.sh -l "$scratch/stage-logs-5" handoff) >"$scratch/stage5.out" 2>"$scratch/stage5.err" &
  runner=$!; started+=("$runner")
  until_true 20 test -s "$scratch/stage-logs-5/first.pid" || fail "the first row never started: $(tr '\n' '|' <"$scratch/stage5.out")"
  ticket=$(sed -n 's/^_START=//p' "$scratch/stage-logs-5/dev.queue.log")
  kill -KILL "$runner"
  wait "$runner" 2>/dev/null || :
  touch "$scratch/stage-logs-5/go"
  until_true 30 dead "$ticket" || fail 'the ticket outlived its stage by more than its row'
  [ ! -e "$scratch/stage-logs-5/second.ran" ] || fail 'a row started after its stage was killed'
  grep -q "is gone: second and the rows after it do not start" "$scratch/stage-logs-5/dev.queue.log" ||
    fail "the ticket's log: $(tr '\n' '|' <"$scratch/stage-logs-5/dev.queue.log")"
  until_true 30 eval '[ "$("${hc[@]}" --status)" = idle ]' || fail "the queue still showed: $("${hc[@]}" --status | tr '\n' '|')"
}

# --- stopping the check stops its command and frees the host ------------------
# signal_running SIGNAL STATUS [LAUNCHER...]
signal_running() {
  local sig=$1 want=$2 i s=0; shift 2
  # The TERM and INT cases share the pid file: a stale one would be taken
  # for this check's start.
  rm -f "$scratch/interrupted.pid"
  "$@" "${hc[@]}" -- sh -c "sleep 120 & echo \$! > $scratch/interrupted.pid; wait" >"$scratch/sig.out" 2>"$scratch/sig.err" &
  i=$!; started+=("$i")
  until_true 10 test -s "$scratch/interrupted.pid" || fail 'the check to interrupt did not start'
  ran "$scratch/sig.err" || fail 'did not run as an outermost check'
  kill "-$sig" "$i"
  wait "$i" || s=$?
  [ "$s" = "$want" ] || fail "a check given $sig exited $s"
  dead "$(cat "$scratch/interrupted.pid")" || fail "the command's child was alive when the check exited"
  framed "$scratch/sig.out" "$want" "$i" || fail "not framed by pid $i: $(tr '\n' '|' < "$scratch/sig.out")"
  has_line '^==> heavy-check: interrupted: stopping the command$' "$scratch/sig.err" || fail 'did not say it was interrupted'
  [ ! -e "$scratch/lock.quarter1.holder" ] || fail 'left its holder record'
  [ "$(registries)" = 0 ] || fail 'left its registry'
  [ "$(status_of timeout 20 "${hc[@]}" -- true)" = 0 ] || fail 'the host was not free after an interrupted check'
}
t_term() { signal_running TERM 143; }
t_int() { signal_running INT 130 "${with_int[@]}"; }
t_hup() { signal_running HUP 129 "${with_hup[@]}"; }

# A signal Bash dies of after the EXIT trap leaves the trap a 0 that is not
# the command's: the line is not 0, the command is stopped and the host is
# freed.
t_usr1() {
  local i s=0
  "${with_usr1[@]}" "${hc[@]}" -- sh -c "sleep 120 & echo \$! > $scratch/usr1.pid; wait" >"$scratch/u.out" 2>"$scratch/u.err" &
  i=$!; started+=("$i")
  until_true 10 test -s "$scratch/usr1.pid" || fail 'the check to signal did not start'
  ran "$scratch/u.err" || fail 'did not run as an outermost check'
  kill -USR1 "$i"
  wait "$i" || s=$?
  [ "$s" != 0 ] || fail 'a check given USR1 exited 0'
  dead "$(cat "$scratch/usr1.pid")" || fail "the command's child was alive when the check exited"
  framed "$scratch/u.out" 1 "$i" || fail "not framed by pid $i with 1: $(tr '\n' '|' < "$scratch/u.out")"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$i status_of bash "$await" "$scratch/u.out" '' 10)" = 1 ] || fail 'the waiter did not answer 1'
  [ ! -e "$scratch/lock.quarter1.holder" ] || fail 'left its holder record'
}

# --- stopping a check beside another: TERM and the hold deadline ---------------
# Either stops the command and its child, removes the quarter's record and
# gives the quarter back before the check exits, while the other quarters'
# holder runs on.
t_quarter_stop() {
  local how i s o
  "${hc[@]}" -- "$hold" "$scratch/release-qs" >/dev/null 2>&1 &
  o=$!; started+=("$o")
  until_true 10 test -s "$scratch/lock.quarter1.holder" || fail 'the other holder did not start'
  for how in term hold; do
    rm -f "$scratch/qs.pid" "$scratch/qs.out" "$scratch/qs.err"
    case $how in
      term) "${hc[@]}" -- sh -c "sleep 120 & echo \$! > $scratch/qs.pid; wait" >"$scratch/qs.out" 2>"$scratch/qs.err" & ;;
      hold) "${hc[@]}" -t 1 -- sh -c "sleep 120 & echo \$! > $scratch/qs.pid; wait" >"$scratch/qs.out" 2>"$scratch/qs.err" & ;;
    esac
    i=$!; started+=("$i")
    until_true 10 test -s "$scratch/qs.pid" || fail "$how: the check did not start"
    has_line "^==> heavy-check: running \\(quarter 2, processors ${Q[2]}\\) " "$scratch/qs.err" || fail "$how: not on quarter 2: $(cat "$scratch/qs.err")"
    flock -n "$scratch/lock.quarter2" true && fail "$how: quarter 2 was free while its check ran"
    [ "$how" = hold ] || kill -TERM "$i"
    s=0; wait "$i" || s=$?
    case $how in term) [ "$s" = 143 ] ;; hold) [ "$s" = 124 ] ;; esac || fail "$how: the check exited $s"
    dead "$(cat "$scratch/qs.pid")" || fail "$how: the command's child was alive when the check exited"
    framed "$scratch/qs.out" "$s" "$i" || fail "$how: not framed by pid $i: $(tr '\n' '|' < "$scratch/qs.out")"
    [ ! -e "$scratch/lock.quarter2.holder" ] || fail "$how: left its record"
    flock -n "$scratch/lock.quarter2" true || fail "$how: quarter 2 was held after the check exited"
    alive "$o" && flock -n "$scratch/lock.quarter1" true && fail "$how: the other holder lost quarter 1"
    alive "$o" || fail "$how: the other holder ended"
  done
  touch "$scratch/release-qs"; wait "$o"
}

# --- stopping a queued check: the wait for the host does not defer it ----------
# signal_queued SIGNAL STATUS [LAUNCHER...]
signal_queued() {
  local sig=$1 want=$2 i q s=0 p; shift 2
  hold_quarters sq
  # The three signals' cases share these files, and a background job
  # truncates its redirections in the child, after this shell has gone on:
  # the previous case's queued line and start line would be read as this
  # check's.
  rm -f "$scratch/q.out" "$scratch/q.err"
  "$@" "${hc[@]}" -- touch "$scratch/queued-ran" >"$scratch/q.out" 2>"$scratch/q.err" &
  q=$!; started+=("$q")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/q.err" || fail 'the check did not queue'
  [ "$(head -n 1 "$scratch/q.out")" = "_START=$q" ] ||
    fail "a queued check had not written its start line: $(head -n 1 "$scratch/q.out")"
  kill "-$sig" "$q"
  until_true 2 dead "$q" || fail "a queued check given $sig was still running 2s later"
  wait "$q" || s=$?
  [ "$s" = "$want" ] || fail "a queued check given $sig exited $s"
  framed "$scratch/q.out" "$want" "$q" || fail "not framed by pid $q: $(tr '\n' '|' < "$scratch/q.out")"
  [ ! -e "$scratch/queued-ran" ] || fail 'the interrupted check ran its command'
  touch "$scratch"/release-sq{1,2,3,4}
  for p in "${quarter_holders[@]}"; do wait "$p"; done
}
t_term_queued() { signal_queued TERM 143; }
t_int_queued() { signal_queued INT 130 "${with_int[@]}"; }
t_hup_queued() { signal_queued HUP 129 "${with_hup[@]}"; }

# --- refusals after the start line are framed too -------------------------------
t_refusals() {
  mkdir -p "$scratch/empty"
  [ "$(status_of "${clean[@]}" PATH="$scratch/empty" "$BASH" "$check" -- true)" = 69 ] || fail 'ran without flock'
  framed "$scratch/out" 69 || fail "the missing flock was not framed: $(tr '\n' '|' < "$scratch/out")"
  has_line '^flock is required' "$scratch/err" || fail 'did not name flock'
  [ "$(HEAVY_CHECK_GRACE=x status_of "${hc[@]}" -- true)" = 64 ] || fail 'accepted a non-numeric grace'
  framed "$scratch/out" 64 || fail 'the bad grace was not framed'
  # contain_start refuses a descriptor base below 10: the command never runs,
  # and the record and registry go with the check.
  [ "$(CONTAIN_FD_BASE=5 status_of "${hc[@]}" -- touch "$scratch/refused-ran")" = 64 ] || fail 'a refused start did not exit 64'
  framed "$scratch/out" 64 || fail 'the refused start was not framed'
  [ ! -e "$scratch/refused-ran" ] || fail 'the refused command ran'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.quarter*.holder')" ] || fail 'a refused start left its holder record'
  [ "$(registries)" = 0 ] || fail 'a refused start left its registry'
}

# --- what a command leaves behind is gone before the next check starts ----------
# leftover NAME COMMAND
leftover() {
  [ "$(status_of "${hc[@]}" -- sh -c "$2")" = 0 ] || fail "the $1 command failed"
  ran "$scratch/err" || fail 'did not run as an outermost check'
  [ "$(status_of timeout 20 "${hc[@]}" -- "$probe" "$scratch/$1.state" "$scratch/$1.pid")" = 0 ] || fail "a command's leftover process kept its quarter"
  [ "$(cat "$scratch/$1.state")" = dead ] || fail "the $1 leftover was alive when the next check started"
  until_true 5 dead "$(cat "$scratch/$1.pid")" || fail "the $1 leftover survived"
}
t_leftover() {
  leftover orphan "sleep 30 >/dev/null 2>&1 & echo \$! > $scratch/orphan.pid"
  leftover grouped-orphan "exec bash -c 'set -m; sleep 30 >/dev/null 2>&1 & echo \$! > $scratch/grouped-orphan.pid'"
}

# --- heavy-check killed outright: its command dies before the host moves on ------
t_sigkill() {
  local k n s=0 p
  hold_others sk 3
  "${hc[@]}" -- sh -c "sleep 120 & echo \$! > $scratch/k-grandchild.pid; echo \$\$ > $scratch/k-command.pid; wait" >/dev/null 2>"$scratch/k1.err" &
  k=$!; started+=("$k")
  until_true 10 test -s "$scratch/k-grandchild.pid" -a -s "$scratch/k-command.pid" || fail 'the command did not start'
  "${hc[@]}" -- "$probe" "$scratch/k.state" "$scratch/k-command.pid" "$scratch/k-grandchild.pid" >/dev/null 2>"$scratch/k2.err" &
  n=$!; started+=("$n")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/k2.err" || fail 'the next check did not queue'
  kill -KILL "$k"
  wait "$k" 2>/dev/null || :
  wait "$n" || s=$?
  [ "$s" = 0 ] || fail "the next check exited $s"
  [ "$(tr '\n' ' ' < "$scratch/k.state")" = 'dead dead ' ] || fail "the next check started beside the killed check's command: $(tr '\n' ' ' < "$scratch/k.state")"
  touch "$scratch"/release-sk{1,2,3}
  for p in "${quarter_holders[@]}"; do wait "$p"; done
  forget_killed
}

# --- a session the command started of its own is swept at handover ---------------
t_nested_session() {
  cat > "$scratch/leg" <<LEG
#!/usr/bin/env bash
set -eu
. "$contain_lib"
echo \$\$ > "$scratch/leg-caller"
# Its own watchdog would wait 120 s for this leader, which ignores TERM.
contain_start -g 120 "$scratch/stubborn" "$scratch/nested.pid"
until [ -s "$scratch/nested.pid" ]; do sleep 0.1; done
LEG
  chmod +x "$scratch/leg"
  [ "$(status_of "${hc[@]}" -- "$scratch/leg")" = 0 ] || fail "the leg's check failed: $(tail -n 3 "$scratch/err")"
  dead "$(cat "$scratch/nested.pid")" || fail 'a session the command started was alive when the check exited'
  until_true 20 sh -c "! pgrep -f '__contain_watchdog .* $(cat "$scratch/leg-caller")\$' >/dev/null" || fail "the leg's watchdog did not end"
}

# --- a check whose starter keeps a registry appends to it and never sweeps ------
t_registry_nested() {
  local other s=0
  : > "$scratch/outer-registry"
  setsid sleep 60 & other=$!
  echo "$other" > "$scratch/other.pid"
  echo "$other" >> "$scratch/outer-registry"
  env -u HEAVY_CHECK_HELD -u CONTAIN_CLOSE_FDS -u CONTAIN_HOLD_FDS CONTAIN_REGISTRY="$scratch/outer-registry" \
    bash "$check" -- sh -c "echo \$\$ > $scratch/registered.pid" >"$scratch/out" 2>"$scratch/err" || s=$?
  [ "$s" = 0 ] || fail "exited $s"
  ran "$scratch/err" || fail 'did not run'
  [ -f "$scratch/outer-registry" ] || fail "a nested check removed its starter's registry"
  grep -qx "$(cat "$scratch/registered.pid")" "$scratch/outer-registry" || fail "the command's session was not appended"
  alive "$other" || fail "a nested check swept its starter's registry"
  [ "$(registries)" = 0 ] || fail 'a nested check made a registry of its own'
  kill "$other"; wait "$other" 2>/dev/null || :
}

# --- a process that outlives KILL ------------------------------------------------
# No real process outlives KILL, so a stub library beside a copy of the
# script reports one: the pid in STUB_SURVIVOR.
survivor_stub() {
  mkdir -p "$scratch/stub/lib"
  cp "$check" "$scratch/stub/heavy-check.sh"
  cp "$root/scripts/lib/run-names.sh" "$root/scripts/lib/quarters.sh" "$scratch/stub/lib/"
  cat > "$scratch/stub/lib/contain.sh" <<'STUB'
CONTAIN_SURVIVORS=
contain_registry_create() { CONTAIN_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/contain-registry.XXXXXX"); export CONTAIN_REGISTRY; }
contain_start() { [ "$1" != -g ] || shift 2; "$@" & CONTAIN_PID=$!; CONTAIN_WATCHDOG=; }
contain_wait() { local s=0; wait "$1" || s=$?; CONTAIN_SURVIVORS=$STUB_SURVIVOR; return "$s"; }
contain_stop() { CONTAIN_SURVIVORS=$STUB_SURVIVOR; }
contain_sweep_registry() { CONTAIN_SURVIVORS=; }
STUB
}
t_survivor() {
  local v s=0 t0
  survivor_stub
  sleep 3 & v=$!
  echo "$v" > "$scratch/survivor.pid"
  t0=$SECONDS
  STUB_SURVIVOR=$v "${clean[@]}" bash "$scratch/stub/heavy-check.sh" -- true >"$scratch/out" 2>"$scratch/err" || s=$?
  [ "$s" = 1 ] || fail "a clean exit with a survivor exited $s"
  dead "$v" || fail 'the host was handed on while the survivor lived'
  [ $((SECONDS - t0)) -ge 1 ] || fail 'did not wait for the survivor'
  framed "$scratch/out" 1 || fail 'not framed'
  has_line "^==> heavy-check: outlived KILL: $v; waiting up to 60s" "$scratch/err" || fail 'did not name the survivor'
  has_line '^==> heavy-check: exit 1 after ' <(tail -n 1 "$scratch/err") || fail "the exit line was not last: $(tail -n 1 "$scratch/err")"
  [ "$(registries)" = 0 ] || fail 'left its registry'
  # The survivor ended within the wait, so the run is finished and its
  # record goes.
  [ ! -e "$scratch/lock.quarter1.holder" ] || fail "a finished run left its record: $(cat "$scratch/lock.quarter1.holder")"
  wait "$v" || :
}
t_survivor_remains() {
  local v s=0
  survivor_stub
  sleep 120 & v=$!
  echo "$v" > "$scratch/survivor.pid"
  STUB_SURVIVOR=$v "${clean[@]}" bash "$scratch/stub/heavy-check.sh" -- sh -c 'exit 3' >"$scratch/out" 2>"$scratch/err" || s=$?
  [ "$s" = 3 ] || fail "a failed command with a survivor exited $s"
  framed "$scratch/out" 3 || fail 'not framed'
  [ "$(tail -n 1 "$scratch/err")" = "==> heavy-check: still alive after KILL and 60s: $v" ] || fail "the last line did not name the survivor: $(tail -n 1 "$scratch/err")"
  has_line "^pid=[0-9]+ quarter=1 " "$scratch/lock.quarter1.holder" || fail 'a run whose survivor outlived KILL removed its record'
  kill "$v"; wait "$v" 2>/dev/null || :
  forget_killed
}

# A check killed as it writes its record the second time, with the
# command's group, leaves the record it wrote when it took the quarter, whole, which names
# no group. The watchdog still stops the command and frees the quarter;
# that record names nothing the cleanup can wait on once its pid is gone.
t_killed_record() {
  local p file=lock.quarter1.holder
  cat > "$scratch/record-write" <<'RECORDWRITE'
printf() {
  if [[ ${FUNCNAME[1]:-} == write_record && -n ${7:-} ]]; then
    echo "$BASHPID" > "$RECORD_MARK"
    kill -STOP "$BASHPID"
  fi
  builtin printf "$@"
}
RECORDWRITE
  rm -f "$scratch/record.mark" "$scratch/record-next"
  BASH_ENV="$scratch/record-write" RECORD_MARK="$scratch/record.mark" \
    "${hc[@]}" -- sleep 120 >"$scratch/record.task" 2>&1 &
  p=$!; started+=("$p")
  until_true 10 test -s "$scratch/record.mark" || fail 'the producer did not reach the record rewrite'
  [ "$(cat "$scratch/record.mark")" = "$p" ] || fail 'stopped a process other than the producer'
  until_true 10 is_stopped "$p" || fail 'the producer did not stop inside the rewrite'
  has_line "^pid=$p quarter=1 cpus=${Q[1]} since=[0-9T:+-]+ hold=2700s group= watchdog= checkout=$worktree command=sleep 120\$" "$scratch/$file" ||
    fail "the interrupted rewrite did not leave the record before it, whole: $(cat "$scratch/$file" 2>/dev/null)"
  kill -KILL "$p"; wait "$p" 2>/dev/null || :
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/record.task" '' 60)" = 3 ] || fail 'the interrupted writer was not reported dead'
  host_free || fail 'the interrupted writer kept its quarter'
  [ "$(status_of "${hc[@]}" --status)" = 0 ] && [ "$(cat "$scratch/out")" = idle ] || fail "a dead writer's record was shown as held"
  # The record neither blocks admission nor names a live run.
  [ "$(status_of timeout 20 "${hc[@]}" -- touch "$scratch/record-next")" = 0 ] || fail "a dead writer's record blocked the next check"
  [ -e "$scratch/record-next" ] || fail 'the next check did not run'
  forget_killed
}

# --- the record of the host's load ------------------------------------------------
# Every check that queued appends one line as it exits: its end, its
# quarter, its wait and its run, its status, its directory and its words,
# redacted; a check stopped while it waited, quarter - and ran 0.
t_record_line() {
  local q p s=0
  : >"$scratch/records"
  [ "$(status_of "${hc[@]}" -- sh -c 'exit 3')" = 3 ] || fail 'the check did not exit 3'
  [ "$(wc -l <"$scratch/records" | tr -d ' ')" = 1 ] || fail "the record holds: $(cat "$scratch/records")"
  has_line "^end=[0-9T:+-]+ quarter=1 waited=[0-9]+ ran=[0-9]+ exit=3 checkout=$worktree command=sh -c exit 3\$" "$scratch/records" ||
    fail "the line is not in the documented form: $(cat "$scratch/records")"
  : >"$scratch/records"
  hold_quarters rl
  # The cases before this one left their own queued lines in q.err: read as
  # this check's, they would have it stopped before its traps exist.
  rm -f "$scratch/q.out" "$scratch/q.err"
  "${hc[@]}" -- env CYFR_DATABASE_URL=postgres://u:secret@h/db true >"$scratch/q.out" 2>"$scratch/q.err" &
  q=$!; started+=("$q")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/q.err" || fail 'the check did not queue'
  kill -TERM "$q"; wait "$q" || s=$?
  [ "$s" = 143 ] || fail "the queued check exited $s"
  has_line "^end=[0-9T:+-]+ quarter=- waited=[0-9]+ ran=0 exit=143 checkout=$worktree command=env CYFR_DATABASE_URL=… true\$" "$scratch/records" ||
    fail "the line of a check stopped in the queue: $(cat "$scratch/records")"
  touch "$scratch"/release-rl{1,2,3,4}
  for p in "${quarter_holders[@]}"; do wait "$p"; done
  [ "$(grep -c 'quarter=[1-4] ' "$scratch/records")" = 4 ] && ! grep -q secret "$scratch/records" ||
    fail "the record after the holders: $(cat "$scratch/records")"
  # A nested check runs in place and writes no line of its own.
  : >"$scratch/records"
  [ "$(status_of "${hc[@]}" -- bash "$check" -- true)" = 0 ] && [ "$(wc -l <"$scratch/records" | tr -d ' ')" = 1 ] ||
    fail "a nested check wrote a line of its own: $(cat "$scratch/records")"
}
# One line for every check that queued, whatever it is. A check given TERM
# as its ticket appears leaves its line; a directory whose path holds a
# newline leaves one line; and a command longer than one append can carry
# leaves one line, under 4096 bytes, its words cut and marked.
t_record_always() {
  local p s=0 long
  : >"$scratch/records"
  rm -f "$scratch/published" "$scratch/ra.ran"
  cat > "$scratch/term-at-publish" <<'TERMAT'
mv() {
  command mv "$@" || return
  if [[ $* == *.ticket.* ]]; then : > "$PUBLISH_MARK"; kill -TERM "$$"; fi
}
TERMAT
  "${clean[@]}" BASH_ENV="$scratch/term-at-publish" PUBLISH_MARK="$scratch/published" bash "$check" -- touch "$scratch/ra.ran" >"$scratch/ra.out" 2>"$scratch/ra.err" &
  p=$!; started+=("$p")
  wait "$p" || s=$?
  [ "$s" = 143 ] && [ -e "$scratch/published" ] && [ ! -e "$scratch/ra.ran" ] || fail "a check given TERM as it arrived exited $s: $(cat "$scratch/ra.err")"
  has_line "^end=[0-9T:+-]+ quarter=- waited=[0-9]+ ran=0 exit=143 checkout=$worktree command=touch " "$scratch/records" ||
    fail "a check given TERM as its ticket appeared left no line: $(cat "$scratch/records")"
  : >"$scratch/records"
  mkdir -p "$scratch/"$'line\nbreak  dir'
  (cd "$scratch/"$'line\nbreak  dir' && "${hc[@]}" -- true) >/dev/null 2>"$scratch/ra.err" || fail "the check in a folder with a newline failed: $(cat "$scratch/ra.err")"
  [ "$(wc -l <"$scratch/records" | tr -d ' ')" = 1 ] && grep -qF "exit=0 checkout=$scratch/line\\nbreak  dir command=true" "$scratch/records" ||
    fail "the line of a directory with a newline in its path: $(cat "$scratch/records")"
  : >"$scratch/records"
  printf -v long '%06000d' 0
  [ "$(status_of "${hc[@]}" -- true "$long" tail)" = 0 ] || fail "the check with a long command failed: $(tail -n 2 "$scratch/err")"
  [ "$(wc -l <"$scratch/records" | tr -d ' ')" = 1 ] && [ "$(wc -c <"$scratch/records" | tr -d ' ')" -lt 4096 ] ||
    fail "a long command's line is $(wc -l <"$scratch/records") lines, $(wc -c <"$scratch/records") bytes"
  has_line "^end=[0-9T:+-]+ quarter=1 waited=[0-9]+ ran=[0-9]+ exit=0 checkout=$worktree command=true 0+ \\[cut\\]\$" "$scratch/records" ||
    fail "a long command's line is not cut and marked: $(cut -c1-120 "$scratch/records")"
}

# A check removes its record before its quarter is free, never after: once
# the quarter is free the record there is the next holder's. A1, on
# quarter 1 with the other three held, is held as it goes to remove its
# record: quarter 1 is still locked and B1 waits. Let go, A1 ends, and B1
# runs on quarter 1 with its own record in place.
t_record_before_quarter() {
  local a b p
  cat > "$scratch/remove-gate" <<'REMOVEGATE'
rm() {
  if [[ ${FUNCNAME[1]:-} == on_exit && $* == *.quarter1.holder && ! -e $GATE_MARK ]]; then
    echo "$BASHPID" > "$GATE_MARK"
    until [[ -e $GATE_OPEN || ! -d ${GATE_OPEN%/*} ]]; do sleep 0.05; done
  fi
  command rm "$@"
}
REMOVEGATE
  rm -f "$scratch/rb.mark" "$scratch/rb.open"
  BASH_ENV="$scratch/remove-gate" GATE_MARK="$scratch/rb.mark" GATE_OPEN="$scratch/rb.open" \
    "${hc[@]}" -- "$hold" "$scratch/release-rbA" >/dev/null 2>"$scratch/rbA.err" &
  a=$!; started+=("$a")
  until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/lock.quarter1.holder" || fail "A1 did not start on quarter 1: $(cat "$scratch/rbA.err")"
  hold_others rb 3
  touch "$scratch/release-rbA"
  until_true 10 test -s "$scratch/rb.mark" || fail "A1 did not reach its record's removal: $(cat "$scratch/rbA.err")"
  "${hc[@]}" -- "$hold" "$scratch/release-rbB" >/dev/null 2>"$scratch/rbB.err" &
  b=$!; started+=("$b")
  until_true 10 eval 'has_line "^==> heavy-check: (queued,|running )" "$scratch/rbB.err"' || fail 'B1 neither queued nor ran'
  ! flock -n "$scratch/lock.quarter1" true || { touch "$scratch/rb.open"; fail 'the quarter was free while its record was still there to remove'; }
  ! ran "$scratch/rbB.err" || { touch "$scratch/rb.open"; fail 'B1 ran before A1 removed its record'; }
  touch "$scratch/rb.open"
  wait "$a" || fail 'A1 failed'
  until_true 10 has_line "^pid=$b quarter=1 .* watchdog=[0-9]+ " "$scratch/lock.quarter1.holder" ||
    fail "B1's record on quarter 1 is not in place: $(cat "$scratch/lock.quarter1.holder" 2>/dev/null)"
  touch "$scratch/release-rbB" "$scratch"/release-rb{1,2,3}
  for p in "$b" "${quarter_holders[@]}"; do wait "$p"; done
}

# A holder's record is whole at every moment: held as it writes its record
# the second time, with the command's group, the check still shows the
# record it wrote when it took its quarter, and --status shows it held.
t_record_whole() {
  local a
  cat > "$scratch/record-gate" <<'RECORDGATE'
printf() {
  if [[ ${FUNCNAME[1]:-} == write_record && -n ${7:-} && ! -e $GATE_MARK ]]; then
    echo "$BASHPID" > "$GATE_MARK"
    until [[ -e $GATE_OPEN || ! -d ${GATE_OPEN%/*} ]]; do sleep 0.05; done
  fi
  builtin printf "$@"
}
RECORDGATE
  rm -f "$scratch/rw.mark" "$scratch/rw.open"
  BASH_ENV="$scratch/record-gate" GATE_MARK="$scratch/rw.mark" GATE_OPEN="$scratch/rw.open" \
    "${hc[@]}" -- "$hold" "$scratch/release-rw" >/dev/null 2>"$scratch/rw.err" &
  a=$!; started+=("$a")
  until_true 10 test -s "$scratch/rw.mark" || fail "the holder did not reach its second write: $(cat "$scratch/rw.err")"
  has_line "^pid=$a quarter=1 cpus=${Q[1]} since=[0-9T:+-]+ hold=2700s group= watchdog= checkout=$worktree command=" "$scratch/lock.quarter1.holder" ||
    fail "a record being written again was not the one before, whole: $(cat "$scratch/lock.quarter1.holder" 2>/dev/null)"
  [ "$(status_of "${hc[@]}" --status)" = 0 ] && has_line "^held quarter=1 pid=$a " "$scratch/out" || fail "--status while the record was written: $(cat "$scratch/out")"
  touch "$scratch/rw.open"
  until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/lock.quarter1.holder" || fail 'the second record did not take its place'
  touch "$scratch/release-rw"; wait "$a" || fail 'the holder failed'
}

# A command's own words cannot move a record's fields: a waiter whose
# command carries `command=label`, started from a directory with a space
# in its name, shows its directory and its words where they belong.
t_record_grammar() {
  local w p line
  hold_quarters rg
  mkdir -p "$scratch/a dir"
  (cd "$scratch/a dir" && exec "${hc[@]}" -- true command=label 'a  b') >/dev/null 2>"$scratch/rg.err" &
  w=$!; started+=("$w")
  until_true 10 has_line '^==> heavy-check: queued, ' "$scratch/rg.err" || fail 'the waiter did not queue'
  line=$("${hc[@]}" --status | grep '^waiting 1 ')
  [[ $line == "waiting 1 pid=$w queued="*" checkout=$scratch/a dir command=true command=… a  b" ]] || fail "the waiter with command= among its words: $line"
  touch "$scratch"/release-rg{1,2,3,4}
  for p in "${quarter_holders[@]}" "$w"; do wait "$p"; done
}

# --- what is told its processors passes them on -----------------------------------
# Every container the browser harness and the install proof start is
# given the processors its check was told, HEAVY_CHECK_CPUS: a container
# does not inherit its starter's. placed_containers FILE...: every docker
# run and docker create in FILE passes them.
placed_containers() {
  python3 -I - "$@" <<'PLACED'
import re, sys
for path in sys.argv[1:]:
    text = re.sub(r"\\\n\s*", " ", open(path).read())
    for line in text.splitlines():
        if line.lstrip().startswith("#") or not re.search(r"\bdocker (run|create)\b", line):
            continue
        if '${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"}' not in line:
            sys.exit(f"{path}: a container is not placed: {line.strip()[:120]}")
PLACED
}
t_placed_containers() {
  local lib="$root/tests/install-screen-proof/lib.sh" why
  local placed='docker create --init --name "$GUEST" ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"}'
  why=$(placed_containers "$root/tests/browser/harness.sh" "$lib" 2>&1) || fail "$why"
  # The control: the same file with one container's processors taken out.
  grep -qF -- "$placed" "$lib" || fail "the control's line is not in $lib"
  python3 -I -c 'import sys; sys.stdout.write(open(sys.argv[1]).read().replace(sys.argv[2], "docker create --init --name \"$GUEST\""))' "$lib" "$placed" > "$scratch/unplaced.sh"
  ! placed_containers "$scratch/unplaced.sh" 2>/dev/null || fail 'an unplaced guest passed'
}

# --- await-task.sh -------------------------------------------------------------------
# await FILE [REGEX [DEADLINE]]: the waiter's status; its stdout in $scratch/out.
await() { status_of bash "$await" "$@"; }

t_await_result() {
  local p
  "${hc[@]}" -- sh -c 'echo "Result: 1 passed"; sleep 2; exit 1' >"$scratch/task" 2>&1 &
  p=$!; started+=("$p")
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task" '' 60)" = 1 ] || fail 'a producer that printed Result: and then failed was not answered 1'
  [ "$(cat "$scratch/out")" = "_EXIT=$p 1" ] || fail "answered with: $(cat "$scratch/out")"
  wait "$p" || :
}

t_await_died() {
  local p
  rm -f "$scratch/task"
  "${hc[@]}" -- sleep 120 >"$scratch/task" 2>&1 &
  p=$!; started+=("$p")
  until_true 10 has_line '^==> heavy-check: running' "$scratch/task" || fail 'the producer did not start'
  kill -KILL "$p"; wait "$p" 2>/dev/null || :
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task" '' 60)" = 3 ] || fail 'a producer killed before its line was not reported dead'
  host_free || fail "the killed producer's command kept the host"
  forget_killed
  sh -c 'echo partial' >"$scratch/task" &
  p=$!; wait "$p"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task" '' 60)" = 3 ] || fail 'a producer that wrote no line was not reported dead'
}

t_await_line() {
  local p
  sh -c 'echo "_START=$$"; echo; echo "_EXIT=$$ 0"' >"$scratch/task" &
  p=$!; wait "$p"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task")" = 0 ] || fail 'a line from a producer that has exited was not the answer'
  [ "$(cat "$scratch/out")" = "_EXIT=$p 0" ] || fail "answered with: $(cat "$scratch/out")"
  # Without AWAIT_PID the producer is the file's first _START=.
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task")" = 0 ] || fail 'the first _START= did not name the producer'
}

t_await_nested() {
  printf '%s\n' _START=100 _START=200 '_EXIT=200 0' '_EXIT=100 1' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=100 await "$scratch/task" '' 5)" = 1 ] || fail "a nested child's 0 was taken for the outer 1"
  [ "$(cat "$scratch/out")" = '_EXIT=100 1' ] || fail "answered with: $(cat "$scratch/out")"
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 5)" = 1 ] || fail "without AWAIT_PID a nested child's 0 was taken for the outer 1"
}

t_await_bare() {
  local d
  d=$(gone_pid)
  printf '%s\n' "_START=$d" _START=200 _EXIT=0 _EXIT=1 > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$d await "$scratch/task" '' 5)" = 3 ] || fail 'a bare _EXIT= was taken as an answer'
  printf '%s\n' _START=1001 '_EXIT=1001 0' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$d await "$scratch/task" '' 5)" = 3 ] || fail "another producer's line was taken as an answer"
  printf '%s\n' "_EXIT=$d 0" "_START=$d" > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$d await "$scratch/task" '' 5)" = 3 ] || fail 'an _EXIT= before its _START= was taken as an answer'
  printf '%s\n' "_START=$d" > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 5)" = 3 ] || fail "the file's producer was gone and it was not reported dead"
}

reused() { printf '%s\n' _START=111 '_EXIT=111 0' > "$scratch/task"; }
t_await_reused() {
  local p
  reused
  "${hc[@]}" -- sh -c 'sleep 1; exit 1' >>"$scratch/task" 2>&1 &
  p=$!; started+=("$p")
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task" '' 60)" = 1 ] || fail "a reused file's old 0 answered a new run"
  wait "$p" || :
  reused
  "${hc[@]}" -- sleep 120 >>"$scratch/task" 2>&1 &
  p=$!; started+=("$p")
  until_true 10 has_line "^_START=$p\$" "$scratch/task" || fail 'the producer did not start'
  kill -KILL "$p"; wait "$p" 2>/dev/null || :
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task" '' 60)" = 3 ] || fail "a reused file's old 0 answered a run that died"
  host_free || fail "the killed producer's command kept the host"
  forget_killed
  reused
  sh -c 'exit 0' & p=$!; wait "$p"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task" '' 60)" = 3 ] || fail "a reused file's old 0 answered a run that wrote nothing"
}

t_await_explicit() {
  local d
  d=$(gone_pid)
  printf '%s\n' 'no result yet' '[exited with code 75]' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" 'Result:' 600)" = 3 ] || fail 'a death marker with an explicit pattern was not 3'
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 600)" = 3 ] || fail 'a death marker without a line was not 3'
  printf '%s\n' 'no result yet' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$d await "$scratch/task" 'Result:' 600)" = 3 ] || fail 'a gone AWAIT_PID with an explicit pattern was not 3'
  printf '%s\n' 'Result: 1 passed' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$d await "$scratch/task" 'Result:' 600)" = 0 ] || fail 'a match from a gone producer was not the answer'
  [ "$(cat "$scratch/out")" = 'Result: 1 passed' ] || fail "answered with: $(cat "$scratch/out")"
}

t_await_statuses() {
  local n
  for n in 124 75 143 2; do
    printf '%s\n' "_START=$$" '' "_EXIT=$$ $n" > "$scratch/task"
    [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 5)" = 1 ] || fail "a line saying $n was not answered 1"
  done
}

t_await_usage() {
  printf '%s\n' "_START=$$" '' "_EXIT=$$ 0" > "$scratch/task"
  [ "$(await "$scratch/task" '' soon)" = 64 ] || fail 'accepted the deadline soon'
  [ "$(await "$scratch/task" '' 0)" = 64 ] || fail 'accepted a zero deadline'
  [ "$(AWAIT_POLL_SECONDS=0 await "$scratch/task")" = 64 ] || fail 'accepted a zero poll'
  [ "$(AWAIT_POLL_SECONDS=x await "$scratch/task")" = 64 ] || fail 'accepted a non-numeric poll'
  [ "$(AWAIT_PID=abc await "$scratch/task")" = 64 ] || fail 'accepted a non-numeric AWAIT_PID'
  [ "$(AWAIT_PID=0 await "$scratch/task")" = 64 ] || fail 'accepted a zero AWAIT_PID'
  [ "$(await)" = 64 ] || fail 'accepted no file'
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID='' await "$scratch/task")" = 0 ] || fail 'an empty AWAIT_PID was not taken as unset'
  [ "$(await -h)" = 0 ] || fail 'no help'
  has_line '3: the job died without it' "$scratch/err" || fail 'the usage text does not state the exit table'
}

# A zombie producer is gone: its parent never reaps it.
t_await_zombie() {
  local parent p t0
  python3 -I -c '
import os, sys, time
pid = os.fork()
if pid == 0:
    os.execvp("sh", ["sh", "-c", "echo _START=$$ > \"$0\"", sys.argv[1]])
print(pid, flush=True)
time.sleep(60)
' "$scratch/task" > "$scratch/zombie" &
  parent=$!
  echo "$parent" > "$scratch/zombie-parent.pid"
  until_true 10 test -s "$scratch/zombie" || fail 'the parent did not start the producer'
  p=$(cat "$scratch/zombie")
  until_true 10 has_line "^_START=$p\$" "$scratch/task" || fail 'the producer did not write its start'
  t0=$SECONDS
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_PID=$p await "$scratch/task" '' 30)" = 3 ] || fail 'a zombie producer was not reported dead'
  [ $((SECONDS - t0)) -le 3 ] || fail "a zombie producer was reported dead only after $((SECONDS - t0))s"
  kill "$parent"; wait "$parent" 2>/dev/null || :
}

t_await_queue() {
  local w
  printf '%s\n' "_START=$$" '==> heavy-check: queued, 1 of 1 waiting, behind:' > "$scratch/task"
  (sleep 3; printf '%s\n' '==> heavy-check: running (quarter 1, processors 0) after 3s queued: x' '' "_EXIT=$$ 0" >> "$scratch/task") &  # sleep-ok: the check stays queued past the run deadline of 1 s
  w=$!; started+=("$w")
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 1)" = 0 ] || fail 'the run deadline ran out while the check was queued'
  wait "$w"
  printf '%s\n' "_START=$$" '==> heavy-check: queued, 1 of 1 waiting, behind:' '==> heavy-check: running (quarter 1, processors 0) after 9s queued: x' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 2)" = 2 ] || fail 'a running check was awaited past its deadline'
  has_line '^DEADLINE after 2s' "$scratch/err" || fail 'the run deadline was not named'
}

cases=(
  usage admission nested result frame roster fds fd_base elsewhere cut host unplaced
  redaction killed_quarter quarters placement quarter_order quarter_stale quarter_stopped
  all_or_none stopped_take admission_stopped ticket_order admission_two_stopped stopped_holder
  waiters_skipped run_record record_watchdog environment status queued_repeat
  hold hold_frame stage_side_by_side term int hup usr1 quarter_stop term_queued int_queued hup_queued
  refusals leftover sigkill nested_session registry_nested survivor survivor_remains killed_record record_line record_always record_whole record_grammar
  record_before_quarter
  placed_containers
  await_result await_died await_line await_nested await_bare await_reused await_explicit
  await_statuses await_usage await_zombie await_queue
)
[ "$#" -eq 0 ] || cases=("$@")
for c in "${cases[@]}"; do
  declare -F "t_$c" >/dev/null || { case_name=$c; fail 'no such case'; }
  case_name=$c
  echo "case $c"
  rm -f "$scratch"/release-* "$scratch/order"
  started=()
  "t_$c"
  # Every case leaves every quarter free, and no record, registry or
  # ticket behind.
  host_free || fail 'a quarter was still held after the case'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.quarter*.holder')" ] || fail "a quarter's holder record was left"
  [ "$(registries)" = 0 ] || fail 'a registry was left'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'a ticket was left'
done
echo 'heavy check tests passed'
