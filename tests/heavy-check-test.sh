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
scratch=$(mktemp -d /tmp/cyfr-heavy-test.XXXXXX)
unset HEAVY_CHECK_HELD CONTAIN_REGISTRY CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS CONTAIN_FD_BASE CYFR_TEST_CORES
# A check started under a check gets its parent's prefix, processors and
# count; every check here starts as an outermost one with none of them.
unset PROOF_RUN_PREFIX ERL_FLAGS CARGO_BUILD_JOBS HEAVY_CHECK_REPEAT HEAVY_CHECK_CPUS HEAVY_CHECK_CPU_ROOT
unset AWAIT_PID AWAIT_POLL_SECONDS AWAIT_QUEUE_SECONDS
# The checks' registries and watchdog pipes are made here, so a case can
# see that none is left.
mkdir "$scratch/tmp"
export TMPDIR="$scratch/tmp"
export HEAVY_CHECK_LOCK="$scratch/lock" HEAVY_CHECK_GRACE=1
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
host_free() { until_true 30 flock -n "$HEAVY_CHECK_LOCK" true; }
registries() { find "$TMPDIR" -maxdepth 1 -name 'contain-registry.*' | wc -l | tr -d ' '; }
# A check killed outright, or one whose survivors outlived KILL, leaves
# its registry file and its holder record, which stays until its run is
# finished (its pid, group and watchdog gone) and its quarters' next holder
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
  for f in "$scratch/lock.holder" "$scratch"/lock.quarter{1,2,3,4}.holder; do
    [ -e "$f" ] || continue
    until_true 30 run_finished "$f" || fail "a holder record names a run that is not finished: $(cat "$f")"
    rm -f "$f"
  done
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
  [ "$(status_of "${hc[@]}" -w soon -- true)" = 64 ] || fail 'accepted a non-numeric queue deadline'
  [ "$(status_of "${hc[@]}" -x -- true)" = 64 ] || fail 'accepted an unknown option'
  [ ! -s "$scratch/out" ] || fail 'a usage error wrote a terminal line'
  # One quarter or four: two, any other count and the removed -s and -p are
  # refused before the start line, and the command never runs.
  for q in 2 0 3 5 01 04 x '' ' 1' '1 '; do
    [ "$(status_of "${hc[@]}" -q "$q" -- touch "$scratch/usage-ran")" = 64 ] || fail "accepted -q '$q'"
    [ ! -s "$scratch/out" ] || fail "a refused -q '$q' wrote a terminal line"
  done
  has_line "^a check takes 1 or 4 quarters, not '1 '\$" "$scratch/err" || fail "did not say why: $(cat "$scratch/err")"
  [ "$(status_of "${hc[@]}" -q)" = 64 ] || fail 'accepted -q without a count'
  [ "$(status_of "${hc[@]}" -s -- touch "$scratch/usage-ran")" = 64 ] || fail 'accepted the removed -s'
  [ "$(status_of "${hc[@]}" -p -- touch "$scratch/usage-ran")" = 64 ] || fail 'accepted the removed -p'
  [ "$(status_of "${hc[@]}" --status -q 1)" = 64 ] || fail '--status took a count'
  [ ! -e "$scratch/usage-ran" ] || fail 'a refused command ran'
}

t_admission() {
  # The command's own grammar decides what fits one quarter; the check
  # reads none of it.
  [ "$(status_of "${hc[@]}" -q 1 -- true scripts/test-partitioned.sh -n 4)" = 0 ] || fail 'did not run the command as given'
  ran "$scratch/err" || fail 'did not run as an outermost check'
  local q
  for q in 1 4; do
    [ "$(status_of "${hc[@]}" -q "$q" -- sh -c 'echo "$HEAVY_CHECK_HELD"')" = 0 ] || fail "the stub on $q failed"
    [ "$(body "$scratch/out")" = "$q" ] || fail "a command on $q saw HEAVY_CHECK_HELD=$(body "$scratch/out")"
  done
  [ "$(status_of "${hc[@]}" -- sh -c 'echo "$HEAVY_CHECK_HELD"')" = 0 ] && [ "$(body "$scratch/out")" = 4 ] ||
    fail "a check without -q held $(body "$scratch/out"), not four quarters"
}

# A check inside a check runs in place, on its parent's processors, when it
# asks for no more quarters than its parent holds; more is refused, framed
# by the parent alone, and so is a count no check of this script set.
t_nested() {
  local inner held
  # A nested check that queued would wait behind its own parent: -w 5 ends
  # that wait, and runs nothing in place.
  [ "$(status_of "${hc[@]}" -- bash "$check" -w 5 -- sh -c 'exit 5')" = 5 ] || fail 'a nested check did not run under its parent'
  framed "$scratch/out" 5 || fail "a nested check wrote lines of its own: $(tr '\n' '|' < "$scratch/out")"
  [ "$(status_of "${hc[@]}" -q 4 -- bash "$check" -w 5 -q 1 -- sh -c 'echo "$HEAVY_CHECK_HELD"; exit 6')" = 6 ] || fail 'one quarter inside four did not run'
  framed "$scratch/out" 6 || fail "one quarter inside four wrote lines of its own: $(tr '\n' '|' < "$scratch/out")"
  [ "$(body "$scratch/out")" = 4 ] || fail "one quarter inside four ran as $(body "$scratch/out"), not in place"
  [ "$(status_of "${hc[@]}" -q 1 -- bash "$check" -w 5 -q 1 -- sh -c "$(probe_cpus "$scratch/nested")")" = 0 ] || fail 'one quarter inside one did not run'
  framed "$scratch/out" 0 || fail "one quarter inside one wrote lines of its own: $(tr '\n' '|' < "$scratch/out")"
  [ "$(cat "$scratch/nested/told")" = "${Q[1]}" ] && [ "$(cpus "$(cat "$scratch/nested/mask")")" = "${Q[1]}" ] &&
    [ "$(cpus "$(cat "$scratch/nested/child")")" = "${Q[1]}" ] && [ "$(cat "$scratch/nested/count")" = 1 ] ||
    fail "one quarter inside one did not keep its parent's quarter: $(cat "$scratch/nested"/*)"
  for inner in '' '-q 4'; do
    [ "$(status_of "${hc[@]}" -q 1 -- bash "$check" $inner -- touch "$scratch/nested-ran")" = 64 ] || fail "four quarters ($inner) started inside one"
    framed "$scratch/out" 64 || fail 'the refused nested check was not framed by its parent alone'
    has_line '^a check on 4 quarters cannot start inside a check on 1$' "$scratch/err" || fail "did not say why: $(cat "$scratch/err")"
  done
  for held in exclusive scoped proof 2 0 x; do
    [ "$(status_of "${clean[@]}" HEAVY_CHECK_HELD="$held" bash "$check" -q 1 -- touch "$scratch/nested-ran")" = 64 ] || fail "ran under HEAVY_CHECK_HELD=$held"
    [ ! -s "$scratch/out" ] || fail "a check refused under HEAVY_CHECK_HELD=$held wrote a terminal line"
  done
  [ ! -e "$scratch/nested-ran" ] || fail 'a refused nested command ran'
}

# --- the command's own result ----------------------------------------------
t_result() {
  [ "$(status_of "${hc[@]}" -- sh -c 'echo said; exit 7')" = 7 ] || fail "lost the command's status"
  framed "$scratch/out" 7 || fail "the run was not framed: $(tr '\n' '|' < "$scratch/out")"
  [ "$(body "$scratch/out")" = said ] || fail "lost the command's output"
  has_line "^==> heavy-check: running \\(4 quarters, processors $ALL4\\) after [0-9]+s queued: sh -c echo said; exit 7\$" "$scratch/err" || fail "did not say it started: $(cat "$scratch/err")"
  has_line '^==> heavy-check: exit 7 after [0-9]+s \(queued [0-9]+s\)$' "$scratch/err" || fail 'did not say how it ended'
  [ ! -e "$scratch/lock.holder" ] || fail 'left its holder record'
  status_of "${hc[@]}" -- sh -c 'echo "$HEAVY_CHECK_HELD ${CYFR_TEST_CORES:-whole}"' >/dev/null
  [ "$(body "$scratch/out")" = '4 whole' ] || fail "a check on four quarters was given a count: $(body "$scratch/out")"
  status_of "${hc[@]}" -q 1 -- sh -c 'echo "$HEAVY_CHECK_HELD ${CYFR_TEST_CORES:-whole}"' >/dev/null
  [ "$(body "$scratch/out")" = '1 1' ] || fail "a check on one quarter was not given its quarter's count: $(body "$scratch/out")"
  has_line "^==> heavy-check: running \\(1 quarter, processors ${Q[1]}\\) after " "$scratch/err" || fail "did not say its quarter: $(cat "$scratch/err")"
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
  "${hc[@]}" -q 1 -- env 2>/dev/null > "$scratch/env-raw"
  body "$scratch/env-raw" | sed 's/=.*//' > "$scratch/env-inside"
  added=$(grep -vxF -f "$scratch/env-before" "$scratch/env-inside" | LC_ALL=C sort | tr '\n' ' ')
  [ "$added" = 'CARGO_BUILD_JOBS CONTAIN_REGISTRY CYFR_TEST_CORES ERL_FLAGS HEAVY_CHECK_CPUS HEAVY_CHECK_HELD PROOF_RUN_PREFIX ' ] || fail "a check on one quarter added: $added"
  "${hc[@]}" -- env 2>/dev/null > "$scratch/env-raw"
  body "$scratch/env-raw" | sed 's/=.*//' > "$scratch/env-inside"
  added=$(grep -vxF -f "$scratch/env-before" "$scratch/env-inside" | LC_ALL=C sort | tr '\n' ' ')
  [ "$added" = 'CONTAIN_REGISTRY HEAVY_CHECK_CPUS HEAVY_CHECK_HELD PROOF_RUN_PREFIX ' ] || fail "a check on four quarters added: $added"
}

# The command's descriptors are its caller's: the lock descriptors and the
# script's own copies of its streams are closed in it, and a caller's 5, 6
# and 12 reach it unshadowed.
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
  # On one quarter the check holds a quarter lock too, and the command
  # holds neither it nor the machine's.
  "${hc[@]}" -q 1 -- "${p[@]}" "$scratch/fds-quarter" 5>"$scratch/five" 6>"$scratch/six" 12</dev/null >"$scratch/fd.out" 2>"$scratch/fd.err" ||
    fail "the probe on one quarter failed: $(tail -n 2 "$scratch/fd.err")"
  [ "$(cat "$scratch/fds-quarter")" = "$(cat "$scratch/fds-direct")" ] ||
    fail "a command on one quarter holds descriptors its caller did not give it: $(tr '\n' '|' < "$scratch/fds-quarter")"
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
  [ "$(status_of "${clean[@]}" -u HEAVY_CHECK_CPU_ROOT bash "$check" -q 1 -- sh -c "$(probe_cpus "$scratch/host")")" = 0 ] || fail "the probe failed: $(cat "$scratch/err")"
  if has_line '^==> heavy-check: running \(1 quarter, processors ' "$scratch/err"; then
    [ "$(cpus "$(cat "$scratch/host/mask")")" = "$(quarters_cpus_of "$(cat "$scratch/host/told")")" ] &&
      [ "$(cpus "$(cat "$scratch/host/child")")" = "$(quarters_cpus_of "$(cat "$scratch/host/told")")" ] ||
      fail "told $(cat "$scratch/host/told"), it runs on $(cat "$scratch/host/mask") and its child on $(cat "$scratch/host/child")"
    [ "$(cat "$scratch/host/count")" = "$(quarters_count "$(cat "$scratch/host/told")")" ] || fail "told $(cat "$scratch/host/told"), its count is $(cat "$scratch/host/count")"
    echo "  this host's first quarter: $(cat "$scratch/host/told")"
  else
    has_line '^==> heavy-check: running \(1 quarter, not placed: ' "$scratch/err" || fail "the running line: $(cat "$scratch/err")"
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
      env "$@" HEAVY_CHECK_CPUS=stale "${hc[@]}" -q 1 -- sh -c "$(probe_cpus "$scratch/un$i"); $hold $scratch/release-un$i" >/dev/null 2>"$scratch/un$i.err" &
      pids+=("$!"); started+=("$!")
      [ "$i" = 5 ] || until_true 10 test -s "$scratch/un$i/child" || fail "$kind: unplaced check $i did not start beside the others"
    done
    until_true 10 has_line '^==> heavy-check: queued \(1 quarter\) 1 of 1 waiting' "$scratch/un5.err" || fail "$kind: a fifth unplaced check did not wait"
    has_line "^==> heavy-check: running \\(1 quarter, not placed: $why\\) after " "$scratch/un1.err" || fail "$kind: the running line: $(cat "$scratch/un1.err")"
    [ "$(cat "$scratch/un1/told")" = unset ] || fail "$kind: an unplaced check was told $(cat "$scratch/un1/told")"
    [ "$(cpus "$(cat "$scratch/un1/mask")")" = "$(cpus "$mine")" ] && [ "$(cpus "$(cat "$scratch/un1/child")")" = "$(cpus "$mine")" ] ||
      fail "$kind: an unplaced check runs on $(cat "$scratch/un1/mask"), not its caller's $mine"
    [ "$(cat "$scratch/un1/count")" = "$count" ] || fail "$kind: an unplaced check's count is $(cat "$scratch/un1/count"), not $count"
    has_line '^pid=[0-9]+ quarters=1 cpus=unplaced since=' "$scratch/lock.quarter1.holder" || fail "$kind: the record: $(cat "$scratch/lock.quarter1.holder")"
    "${hc[@]}" --status >"$scratch/un.status"
    [ "$(grep -c '^held quarters=1 pid=[0-9]* cpus=unplaced since=' "$scratch/un.status")" = 4 ] || fail "$kind: --status: $(cat "$scratch/un.status")"
    touch "$scratch/release-un2"
    until_true 10 test -s "$scratch/un5/child" || fail "$kind: the fifth unplaced check never started"
    touch "$scratch"/release-un{1,3,4,5}
    for i in "${pids[@]}"; do wait "$i"; done
  done
}

# --- four quarters: one whole-machine check at a time --------------------------
t_whole() {
  local a b
  "${hc[@]}" -- sh -c "echo a-start >> $scratch/order; $hold $scratch/release-a; echo a-end >> $scratch/order" >/dev/null 2>"$scratch/a.err" &
  a=$!; started+=("$a")
  until_true 10 test -s "$scratch/lock.holder" || fail 'the holder left no record'
  "${hc[@]}" -- sh -c "echo b >> $scratch/order" >/dev/null 2>"$scratch/b.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 1 of 1 waiting, behind:$' "$scratch/b.err" || fail 'a queued check did not say so'
  has_line "^==> heavy-check:   pid=$a quarters=4 cpus=$ALL4 since=[0-9T:+-]+ hold=2700s group=[0-9]+ watchdog=[0-9]+ checkout=$(pwd -P) command=sh -c " "$scratch/b.err" ||
    fail "a queued check did not name the holder: $(cat "$scratch/b.err")"
  [ "$(cat "$scratch/order")" = a-start ] || fail 'a second whole-machine check ran beside the first'
  touch "$scratch/release-a"; wait "$a"; wait "$b"
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'a-start a-end b ' ] || fail "whole-machine checks overlapped: $(tr '\n' ' ' < "$scratch/order")"
  has_line '^==> heavy-check: running \(4 quarters, ' "$scratch/b.err" || fail 'the queued check did not say when it started'
}

# A NAME=value word of the command never reaches another check or a file.
t_redaction() {
  local a b
  # The hold script reads only its first argument; the URLs ride along.
  "${hc[@]}" -- env CYFR_DATABASE_URL=postgres://u:secret@h/db "$hold" "$scratch/release-r" \
    --url=postgres://u:secret2@h/db https://secret3@h/x postgres://u:pa@secret4@h/db >/dev/null 2>"$scratch/r1.err" &
  a=$!; started+=("$a")
  until_true 10 test -s "$scratch/lock.holder" || fail 'the holder left no record'
  ! grep -q secret "$scratch/lock.holder" || fail "the holder's record carries the value: $(cat "$scratch/lock.holder")"
  has_line '^pid=[0-9]+ .* command=env CYFR_DATABASE_URL=… .* --url=postgres://\[redacted\]@h/db https://\[redacted\]@h/x postgres://\[redacted\]@h/db$' "$scratch/lock.holder" ||
    fail "the record lost the name or the URLs' shape: $(cat "$scratch/lock.holder")"
  "${hc[@]}" -- true >/dev/null 2>"$scratch/r2.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 1 of 1 waiting, behind:$' "$scratch/r2.err" || fail 'the second check did not queue'
  has_line '^==> heavy-check:   pid=[0-9]+ .*command=env CYFR_DATABASE_URL=… .* --url=postgres://\[redacted\]@h/db ' "$scratch/r2.err" || fail 'the queued check did not name the holder'
  touch "$scratch/release-r"; wait "$a"; wait "$b"
  ! grep -q secret "$scratch/r1.err" "$scratch/r2.err" || fail "the value reached a check's stderr"
}

# --- a check killed outright: its record names its run until the run ends ---
# The killed check's record names its command's group and its watchdog,
# which still run, so a check that queues behind the watchdog names it,
# and runs once the watchdog has stopped the command, here a leader that
# ignores TERM under a grace long enough to queue behind it. The record
# stays until that next holder replaces it.
t_killed_holder() {
  local k n leader record
  "${clean[@]}" HEAVY_CHECK_GRACE=30 bash "$check" -- "$scratch/stubborn" "$scratch/kh.pid" >/dev/null 2>"$scratch/kh1.err" &
  k=$!; started+=("$k")
  until_true 10 test -s "$scratch/kh.pid" || fail 'the command did not start'
  leader=$(cat "$scratch/kh.pid")
  until_true 10 has_line " group=$leader watchdog=[0-9]+ " "$scratch/lock.holder" || fail "the record does not name the command's group: $(cat "$scratch/lock.holder")"
  kill -KILL "$k"
  wait "$k" 2>/dev/null || :
  record=$(cat "$scratch/lock.holder")
  "${hc[@]}" -- touch "$scratch/after-killed" >/dev/null 2>"$scratch/kh2.err" &
  n=$!; started+=("$n")
  until_true 10 has_line "^==> heavy-check:   pid=$k quarters=4 .* group=$leader watchdog=[0-9]+ " "$scratch/kh2.err" ||
    fail "did not queue naming the killed check's run: $(cat "$scratch/kh2.err")"
  [ "$(cat "$scratch/lock.holder")" = "$record" ] || fail "the killed check's record changed while its run lived"
  [ ! -e "$scratch/after-killed" ] || fail "ran beside the killed check's command"
  kill -KILL "$leader"
  wait "$n" || fail 'the queued check failed'
  [ -e "$scratch/after-killed" ] || fail "did not run after the killed check's watchdog let the host go"
  forget_killed
}

# hold_quarters TAG: four checks on one quarter each that hold every
# quarter until release-TAG<n> appears; their pids in $quarter_holders, and
# each one's processors in TAG<n>.cpus.
hold_quarters() {
  local n
  quarter_holders=()
  for n in 1 2 3 4; do
    "${hc[@]}" -q 1 -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/$1$n.cpus.new && mv $scratch/$1$n.cpus.new $scratch/$1$n.cpus; $hold $scratch/release-$1$n" >/dev/null 2>&1 &
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
  "${clean[@]}" HEAVY_CHECK_GRACE=30 bash "$check" -q 1 -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/kq0.cpus; exec $scratch/stubborn $scratch/kq.pid" >/dev/null 2>"$scratch/kq1.err" &
  k=$!; started+=("$k")
  until_true 10 test -s "$scratch/kq.pid" || fail 'the command did not start'
  leader=$(cat "$scratch/kq.pid")
  kq=$(quarter_of "$(cat "$scratch/kq0.cpus")")
  [ "$kq" = 1 ] || fail "the first check took quarter $kq"
  until_true 10 has_line " group=$leader watchdog=[0-9]+ " "$scratch/lock.quarter1.holder" || fail "the record does not name the command's group: $(cat "$scratch/lock.quarter1.holder" 2>/dev/null)"
  quarter_holders=()
  for i in 2 3 4; do
    "${hc[@]}" -q 1 -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/kq$i.cpus.new && mv $scratch/kq$i.cpus.new $scratch/kq$i.cpus; $hold $scratch/release-kq; echo kq$i >> $scratch/order" >/dev/null 2>&1 &
    quarter_holders+=("$!"); started+=("$!")
    until_true 10 test -s "$scratch/kq$i.cpus" || fail "holder $i did not start"
  done
  kill -KILL "$k"
  wait "$k" 2>/dev/null || :
  record=$(cat "$scratch/lock.quarter1.holder")
  "${hc[@]}" -q 1 -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/kq5.cpus" >/dev/null 2>"$scratch/kq2.err" &
  n=$!; started+=("$n")
  until_true 10 has_line "^==> heavy-check:   pid=$k quarters=1 cpus=${Q[1]} .* group=$leader watchdog=[0-9]+ " "$scratch/kq2.err" ||
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

# --- one quarter each: four side by side on four quarters, the fifth waits -----
# Each check on one quarter is told a quarter no other holds, and it and
# its child run on exactly those processors; a fifth waits, and runs on the
# quarter that frees.
t_quarters() {
  local i pids=() seen=' ' c
  rm -rf "$scratch"/sq*
  for i in 1 2 3 4 5; do
    "${hc[@]}" -q 1 -- sh -c "$(probe_cpus "$scratch/sq$i"); $hold $scratch/release-s$i" >/dev/null 2>"$scratch/s$i.err" &
    pids+=("$!"); started+=("$!")
    [ "$i" = 5 ] || until_true 10 test -s "$scratch/sq$i/child" || fail "check $i did not start beside the others"
  done
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\) 1 of 1 waiting' "$scratch/s5.err" || fail 'a fifth check on one quarter was not queued'
  [ ! -e "$scratch/sq5" ] || fail 'a fifth check on one quarter started'
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

# Four quarters: the check and its child run on every processor, as told.
t_placement() {
  rm -rf "$scratch/pl"
  [ "$(status_of "${hc[@]}" -- sh -c "$(probe_cpus "$scratch/pl")")" = 0 ] || fail "the probe failed: $(cat "$scratch/err")"
  [ "$(cat "$scratch/pl/told")" = "$ALL4" ] || fail "a check on four quarters was told $(cat "$scratch/pl/told"), not $ALL4"
  [ "$(cpus "$(cat "$scratch/pl/mask")")" = "$(quarters_cpus_of "$ALL4")" ] && [ "$(cpus "$(cat "$scratch/pl/child")")" = "$(quarters_cpus_of "$ALL4")" ] ||
    fail "a check on four quarters runs on $(cat "$scratch/pl/mask") and its child on $(cat "$scratch/pl/child")"
  [ "$(cat "$scratch/pl/count")" = unset ] || fail "a check on four quarters was given a count: $(cat "$scratch/pl/count")"
  # Placement replaces the caller's: one placed narrower still runs on the
  # quarter it was given.
  rm -rf "$scratch/pl"
  [ "$(status_of taskset -c "${Q[4]}" "${hc[@]}" -q 1 -- sh -c "$(probe_cpus "$scratch/pl")")" = 0 ] || fail "the narrowed probe failed: $(cat "$scratch/err")"
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
    rm -f "$scratch"/release-* "$scratch/order" "$scratch"/so*.cpus
    hold_quarters so
    "${hc[@]}" -q 1 -- sh -c "echo A >> $scratch/order; $hold $scratch/release-w" >/dev/null 2>"$scratch/soA.err" &
    a=$!; started+=("$a")
    until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/soA.err" || fail "round $round: the first waiter did not queue"
    sleep 0.5
    "${hc[@]}" -q 1 -- sh -c "echo B >> $scratch/order; $hold $scratch/release-w" >/dev/null 2>"$scratch/soB.err" &
    b=$!; started+=("$b")
    until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/soB.err" || fail "round $round: the second waiter did not queue"
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
  "${hc[@]}" -q 1 -- true >/dev/null 2>"$scratch/stA.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/stA.err" || fail 'the first waiter did not queue'
  kill -KILL "$a"; wait "$a" 2>/dev/null || :
  [ -n "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'the killed waiter left no ticket to step over'
  "${hc[@]}" -q 1 -- sh -c "echo B >> $scratch/order" >/dev/null 2>"$scratch/stB.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/stB.err" || fail 'the second waiter did not queue'
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
  "${hc[@]}" -q 1 -- sh -c "echo A >> $scratch/order" >/dev/null 2>"$scratch/ssA.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/ssA.err" || fail 'the first waiter did not queue'
  kill -STOP "$a"
  until_true 5 is_stopped "$a" || fail 'the first waiter was not stopped'
  "${hc[@]}" -q 1 -- sh -c "echo B >> $scratch/order" >/dev/null 2>"$scratch/ssB.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/ssB.err" || fail 'the second waiter did not queue'
  touch "$scratch/release-ss1"
  until_true 10 has_line '^B$' "$scratch/order" || fail 'a stopped waiter held back a later one'
  kill -CONT "$a"
  touch "$scratch"/release-ss{2,3,4}
  for p in "${quarter_holders[@]}" "$a" "$b"; do wait "$p"; done
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'B A ' ] || fail "the continued waiter did not run after: $(tr '\n' ' ' < "$scratch/order")"
}

# --- all or none --------------------------------------------------------------
# A check that finds no quarter free holds nothing while it waits: stopped
# in the queue behind four holders, it keeps no share of the machine, so
# once they end a check on four quarters that arrived after it runs. And
# a take interrupted after it took a quarter, its child killed before the
# record, leaves nothing taken: stopped as soon as it goes on, the check
# holds nothing, so a check on four quarters runs; continued, it takes a
# quarter afresh, the first again, and the other three stay free.
# The take's child stops itself once, at $STOP_CMD in $STOP_FN, writing its
# pid to $STOP_MARK.pid first; once it has, the check stops itself at the
# start of the next queued line it says, creating $STOP_MARK.check.
t_all_or_none() {
  local x y child s p
  rm -f "$scratch/order" "$scratch"/stopped-mark*
  hold_quarters an
  "${hc[@]}" -q 1 -- sh -c "echo X >> $scratch/order" >/dev/null 2>"$scratch/anX.err" &
  x=$!; started+=("$x")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/anX.err" || fail 'the check did not queue behind four holders'
  kill -STOP "$x"
  until_true 5 is_stopped "$x" || fail 'the waiter did not stop'
  # A take it had under way ends on its own: every child it has left has
  # exited, unreaped while it is stopped.
  until_true 5 sh -c "! ps -o stat= --ppid $x | grep -qv '^Z'" || fail "the stopped waiter's take did not end: $(ps -o pid=,stat=,args= --ppid "$x")"
  touch "$scratch"/release-an{1,2,3,4}
  for p in "${quarter_holders[@]}"; do wait "$p"; done
  [ "$(status_of "${hc[@]}" -w 10 -- sh -c "echo Y >> $scratch/order")" = 0 ] ||
    fail "a check on four quarters behind a waiter that found none free exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
  kill -CONT "$x"
  wait "$x" || fail 'the continued waiter failed'
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'Y X ' ] || fail "the order was $(tr '\n' ' ' < "$scratch/order")"
  # Interrupted: the take's child dies holding the machine's share and
  # quarter 1.
  rm -f "$scratch/order" "$scratch/an.cpus"
  cat > "$scratch/kill-at" <<'KILLAT'
set -T
trap 'if [[ ! -e $STOP_MARK && ${FUNCNAME[0]:-} == "$STOP_FN" && $BASH_COMMAND == $STOP_CMD ]]; then echo $BASHPID > "$STOP_MARK.pid"; : > "$STOP_MARK"; kill -STOP $BASHPID; elif [[ -e $STOP_MARK && ! -e $STOP_MARK.check && ${FUNCNAME[0]:-} == announce ]]; then : > "$STOP_MARK.check"; kill -STOP $$; fi' DEBUG
KILLAT
  "${clean[@]}" BASH_ENV="$scratch/kill-at" STOP_MARK="$scratch/stopped-mark" STOP_FN=take_quarters STOP_CMD='write_record*' \
    bash "$check" -q 1 -- sh -c "echo \"\$HEAVY_CHECK_CPUS\" > $scratch/an.cpus; $hold $scratch/release-an" >/dev/null 2>"$scratch/anI.err" &
  y=$!; started+=("$y")
  until_true 10 test -e "$scratch/stopped-mark" || fail 'the take did not reach the point after its quarter'
  child=$(cat "$scratch/stopped-mark.pid")
  until_true 5 is_stopped "$child" || fail 'the take did not stop'
  flock -n "$scratch/lock.quarter1" true && fail 'the stopped take did not hold quarter 1'
  kill -KILL "$child"
  until_true 10 test -e "$scratch/stopped-mark.check" || fail "the check did not go on after its take was killed: $(cat "$scratch/anI.err")"
  until_true 5 is_stopped "$y" || fail 'the check did not stop after its take was killed'
  [ "$(status_of "${hc[@]}" -w 5 -- sh -c "echo Y >> $scratch/order")" = 0 ] ||
    fail "a check on four quarters behind one stopped after its take was killed exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
  kill -CONT "$y"
  until_true 10 test -s "$scratch/an.cpus" || fail "the check did not run after its take was killed: $(cat "$scratch/anI.err")"
  [ "$(cat "$scratch/an.cpus")" = "${Q[1]}" ] || fail "the check ran on $(cat "$scratch/an.cpus"), not quarter 1 afresh"
  for s in 2 3 4; do flock -n "$scratch/lock.quarter$s" true || fail "quarter $s was held after the killed take"; done
  touch "$scratch/release-an"
  wait "$y" || fail 'the check whose take was killed failed'
}

# A take that does not end with its quarters gives back what it took
# before its child exits, so its check, stopped meanwhile, holds nothing:
# the take found no quarter free (four holders, which then end), or its
# queue deadline passed after it took (the child held until then), or its
# record could not be written (a directory in its place). Each time a
# check that needs what the stopped one took runs at once, and the
# stopped one, continued, goes on as its take said: it runs once the
# quarters are free, gives up at its deadline with 75, or runs once the
# record can be written.
t_stopped_take() {
  local how size flag x y s want p
  for how in none:1 expired:1 expired:4 record:1 record:4; do
    size=${how#*:} how=${how%:*}
    flag=$(size_flag "$size")
    rm -f "$scratch/order" "$scratch/stopped-mark" "$scratch/until"
    set -- STOP_FN=take_quarters
    case $how in
      none)
        hold_quarters sf$size
        set -- "$@" STOP_CMD='\[ "$held" != 0 \]' ;;
      expired) set -- "$@" STOP_CMD=expired STOP_UNTIL="$scratch/until" ;;
      record)
        if [ "$size" = 4 ]; then mkdir "$scratch/lock.holder"; else mkdir "$scratch/lock.quarter1.holder"; fi
        set -- "$@" STOP_CMD='write_record*' ;;
    esac
    # shellcheck disable=SC2086
    "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark" "$@" \
      bash "$check" $flag $( [ "$how" != expired ] || echo -w 1 ) -- sh -c "echo X >> $scratch/order" >"$scratch/sf.out" 2>"$scratch/sf.err" &
    x=$!; started+=("$x")
    until_true 10 test -e "$scratch/stopped-mark" || fail "$how on $size: the take did not reach its hook: $(cat "$scratch/sf.err")"
    until_true 5 is_stopped "$x" || fail "$how on $size: the check did not stop"
    if [ "$how" = expired ]; then sleep 1.5; touch "$scratch/until"; fi
    until_true 5 sh -c "! ps -o stat= --ppid $x | grep -qv '^Z'" || fail "$how on $size: the stopped check's take did not end"
    if [ "$how" = none ]; then
      touch "$scratch/release-sf${size}"{1,2,3,4}
      for p in "${quarter_holders[@]}"; do wait "$p"; done
    fi
    # What the stopped check took, the machine whole or shared and a
    # quarter, is what this one needs.
    if [ "$how" = record ] && [ "$size" = 4 ]; then y=(-q 1); else y=(); fi
    [ "$(status_of "${hc[@]}" ${y[@]+"${y[@]}"} -w 5 -- sh -c "echo Y >> $scratch/order")" = 0 ] ||
      fail "$how on $size: a check behind a stopped one whose take ended exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
    [ "$how" != record ] || rmdir "$scratch/lock.holder" "$scratch/lock.quarter1.holder" 2>/dev/null || :
    kill -CONT "$x"
    s=0; wait "$x" || s=$?
    case $how in expired) want=75 ;; *) want=0 ;; esac
    [ "$s" = "$want" ] || fail "$how on $size: the continued check exited $s, not $want: $(cat "$scratch/sf.err")"
    case $how in
      expired) [ "$(tr '\n' ' ' < "$scratch/order")" = 'Y ' ] || fail "$how on $size: the order was $(tr '\n' ' ' < "$scratch/order")" ;;
      *) [ "$(tr '\n' ' ' < "$scratch/order")" = 'Y X ' ] || fail "$how on $size: the order was $(tr '\n' ' ' < "$scratch/order")" ;;
    esac
  done
}

# --- the order of arrival across sizes ----------------------------------------
# No check starts past one that arrived before it, whatever either asks
# for: with three quarters held, a check on four queues and a later one on
# one waits though a quarter is free; the four run alone once the holders
# end; then the two on one quarter that queued next run together, and a
# check on four behind them waits for both, and one on one behind that
# waits for it, though quarters are free.
t_precedence() {
  local pids=() n p
  rm -f "$scratch/order"
  for n in 1 2 3; do
    "${hc[@]}" -q 1 -- sh -c "echo h$n >> $scratch/order; $hold $scratch/release-h" >/dev/null 2>&1 &
    pids+=("$!"); started+=("$!")
    until_true 10 started_in_order "h$n" || fail "holder $n did not start"
  done
  "${hc[@]}" -- sh -c "echo A >> $scratch/order; $hold $scratch/release-A" >/dev/null 2>"$scratch/pA.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 1 of 1 waiting' "$scratch/pA.err" || fail 'a check on four quarters did not queue behind three'
  for n in B C; do
    "${hc[@]}" -q 1 -- sh -c "echo $n >> $scratch/order; $hold $scratch/release-BC; echo $n-end >> $scratch/order" >/dev/null 2>"$scratch/p$n.err" &
    pids+=("$!"); started+=("$!")
    until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/p$n.err" || fail "$n did not queue behind the check on four"
  done
  "${hc[@]}" -- sh -c "echo D >> $scratch/order; $hold $scratch/release-D" >/dev/null 2>"$scratch/pD.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 4 of 4 waiting' "$scratch/pD.err" || fail "D did not queue fourth: $(cat "$scratch/pD.err")"
  "${hc[@]}" -q 1 -- sh -c "echo E >> $scratch/order" >/dev/null 2>"$scratch/pE.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\) 5 of 5 waiting' "$scratch/pE.err" || fail "E did not queue fifth: $(cat "$scratch/pE.err")"
  not_started B || fail 'a check on one quarter started past an earlier check on four'
  touch "$scratch/release-h"
  until_true 10 started_in_order A || fail 'the check on four did not start once the holders ended'
  not_started B || fail 'a check on one quarter started beside a check on four'
  touch "$scratch/release-A"
  until_true 10 started_in_order B && until_true 10 started_in_order C || fail 'B and C did not run together after A'
  not_started D || fail 'a check on four started beside checks on one'
  not_started E || fail 'a check on one quarter started past an earlier check on four'
  touch "$scratch/release-BC"
  until_true 10 started_in_order D || fail 'D did not start once B and C ended'
  not_started E || fail 'a check on one quarter started beside a check on four'
  touch "$scratch/release-D"
  for p in "${pids[@]}"; do wait "$p"; done
  in_order h3 A B-end D E && in_order A C-end D ||
    fail "the checks ran out of arrival order: $(tr '\n' ' ' < "$scratch/order")"
}
started_in_order() { has_line "^$1\$" "$scratch/order"; }
not_started() { sleep 1; ! has_line "^$1\$" "$scratch/order"; }
# The line numbers of the order file's words must rise in the order given.
in_order() {
  local word last=0 n
  for word in "$@"; do
    n=$(grep -nx "$word" "$scratch/order" | head -n 1 | cut -d: -f1)
    [ -n "$n" ] && [ "$n" -gt "$last" ] || return 1
    last=$n
  done
}

# A waiter stopped while it queued and continued after its queue deadline
# exits 75 and runs nothing, though its quarters are free by then.
size_flag() { [ "$1" = 4 ] || echo "-q $1"; }
t_expired_waiter() {
  local size flag h w s
  for size in 4 1; do
    flag=$(size_flag "$size")
    rm -f "$scratch"/release-* "$scratch/ew-ran"
    "${hc[@]}" -- "$hold" "$scratch/release-ew" >/dev/null 2>&1 &
    h=$!; started+=("$h")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    "${hc[@]}" $flag -w 2 -- touch "$scratch/ew-ran" >"$scratch/ew.out" 2>"$scratch/ew.err" &
    w=$!; started+=("$w")
    until_true 10 has_line "^==> heavy-check: queued \\($(quarters_words "$size")\\)" "$scratch/ew.err" || fail "the waiter on $size did not queue"
    kill -STOP "$w"
    until_true 5 is_stopped "$w" || fail "the waiter on $size did not stop"
    alive "$w" || fail "the waiter on $size gave up before it was stopped"
    touch "$scratch/release-ew"; wait "$h"
    sleep 3
    kill -CONT "$w"
    s=0; wait "$w" || s=$?
    [ "$s" = 75 ] || fail "a waiter on $size continued after its queue deadline exited $s"
    [ ! -e "$scratch/ew-ran" ] || fail "a waiter on $size ran after its queue deadline"
    framed "$scratch/ew.out" 75 "$w" || fail "not framed by pid $w: $(tr '\n' '|' < "$scratch/ew.out")"
    has_line '^==> heavy-check: queue deadline after ' "$scratch/ew.err" || fail 'the queue deadline was not reported'
  done
}
quarters_words() { if [ "$1" = 1 ]; then echo '1 quarter'; else echo "$1 quarters"; fi; }

# A check stopped in its first-in-line test keeps no one waiting: a later
# check starts at once, without queuing, the stopped one keeps its ticket,
# and once continued it runs too.
t_admission_stopped() {
  local size flag a s t
  for size in 4 1; do
    flag=$(size_flag "$size")
    rm -f "$scratch/order" "$scratch/stopped-mark"
    "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_FN=places STOP_CMD='ahead=0 waiting=0' STOP_MARK="$scratch/stopped-mark" \
      bash "$check" $flag -- sh -c "echo stopped >> $scratch/order" >/dev/null 2>"$scratch/as1.err" &
    a=$!; started+=("$a")
    until_true 10 test -e "$scratch/stopped-mark" || fail "the check on $size did not reach its first-in-line test"
    until_true 5 is_stopped "$a" || fail "the check on $size did not stop"
    t=$SECONDS
    [ "$(status_of "${hc[@]}" $flag -w 10 -- sh -c "echo later >> $scratch/order")" = 0 ] ||
      fail "a later check on $size behind one stopped in admission exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
    [ $((SECONDS - t)) -le 3 ] || fail "a later check on $size waited $((SECONDS - t))s behind one stopped in admission"
    has_line "^==> heavy-check: running \\($(quarters_words "$size"), " <(grep '^==> heavy-check: ' "$scratch/err" | sed -n 1p) ||
      fail "the later check on $size did not start at once: $(grep '^==> heavy-check: ' "$scratch/err")"
    [ "$(cat "$scratch/order")" = later ] || fail "the later check on $size did not run: $(cat "$scratch/order" 2>/dev/null)"
    [ -n "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail "the stopped check on $size lost its ticket"
    kill -CONT "$a"
    s=0; wait "$a" || s=$?
    [ "$s" = 0 ] || fail "the continued check on $size exited $s"
    [ "$(tr '\n' ' ' < "$scratch/order")" = 'later stopped ' ] || fail "the continued check on $size did not run after: $(tr '\n' ' ' < "$scratch/order")"
  done
}

# Arrival is a ticket's publication: a check stopped as it publishes
# arrives when it is continued, after the checks that published meanwhile,
# which keep their order. (On b1dfc572c it is stopped as it writes the
# ticket counter, and resumed writes it back.)
t_ticket_order() {
  local h a c d p
  rm -f "$scratch/order" "$scratch/stopped-mark"
  "${hc[@]}" -- "$hold" "$scratch/release-to" >/dev/null 2>&1 &
  h=$!; started+=("$h")
  until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
  "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark" \
    STOP_FN=publish_ticket STOP_CMD='ticket=*' STOP_FN2=take_ticket STOP_CMD2='*LOCK.seq*' \
    bash "$check" -- sh -c "echo A >> $scratch/order" >/dev/null 2>"$scratch/toA.err" &
  a=$!; started+=("$a")
  until_true 10 test -e "$scratch/stopped-mark" || fail 'the first check did not reach its publication'
  until_true 5 is_stopped "$a" || fail 'the first check did not stop'
  "${hc[@]}" -- sh -c "echo C >> $scratch/order" >/dev/null 2>"$scratch/toC.err" &
  c=$!; started+=("$c")
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 1 of 1 waiting' "$scratch/toC.err" || fail "the second check did not queue first: $(cat "$scratch/toC.err")"
  "${hc[@]}" -q 1 -- sh -c "echo D >> $scratch/order" >/dev/null 2>"$scratch/toD.err" &
  d=$!; started+=("$d")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\) 2 of 2 waiting' "$scratch/toD.err" || fail "the third check did not queue second: $(cat "$scratch/toD.err")"
  kill -CONT "$a"
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 3 of 3 waiting' "$scratch/toA.err" ||
    fail "the continued check did not arrive last: $(cat "$scratch/toA.err")"
  touch "$scratch/release-to"
  for p in "$h" "$c" "$d" "$a"; do wait "$p" || fail "check $p failed"; done
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'C D A ' ] || fail "the checks ran out of arrival order: $(tr '\n' ' ' < "$scratch/order")"
}

# Admission never waits on another waiter: with one check stopped in its
# first-in-line test and another stopped about to take its quarters (on
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
  [ "$(status_of "${hc[@]}" -w 10 -- sh -c "echo C >> $scratch/order")" = 0 ] || fail "the third check exited: $(cat "$scratch/err")"
  has_line '^==> heavy-check: running \(4 quarters, ' <(grep '^==> heavy-check: ' "$scratch/err" | sed -n 1p) ||
    fail "the third check did not start at once: $(grep '^==> heavy-check: ' "$scratch/err")"
  [ "$(cat "$scratch/order")" = C ] || fail "the third check did not run alone: $(tr '\n' ' ' < "$scratch/order")"
  kill -CONT "$a" "$b"
  for p in "$a" "$b"; do wait "$p" || fail "a continued check $p failed"; done
  [ "$(sort "$scratch/order" | tr '\n' ' ')" = 'A B C ' ] || fail "the continued checks did not both run: $(tr '\n' ' ' < "$scratch/order")"
}

# A holder stopped just after it took its quarters, before it wrote its
# record, keeps them: --status shows it held and stopped, a later check
# queues behind it naming it and keeps its own deadline, and the holder
# runs once continued.
t_stopped_holder() {
  local size flag a s
  for size in 4 1; do
    flag=$(size_flag "$size")
    rm -f "$scratch/order" "$scratch/stopped-mark" "$scratch/sh-ran"
    "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_MARK="$scratch/stopped-mark" \
      STOP_FN=take_quarters STOP_CMD='write_record*' \
      bash "$check" $flag -- sh -c "echo held >> $scratch/order" >/dev/null 2>"$scratch/shA.err" &
    a=$!; started+=("$a")
    until_true 10 test -e "$scratch/stopped-mark" || fail "the check on $size did not reach its take"
    until_true 5 is_stopped "$a" || fail "the check on $size did not stop"
    until_true 5 sh -c "'$check' --status | grep -q '^held quarters=$size pid=$a state=stopped cpus='" ||
      fail "--status with the holder on $size stopped: $("${hc[@]}" --status)"
    [ "$(status_of "${hc[@]}" -w 2 -- touch "$scratch/sh-ran")" = 75 ] || fail "a check behind the stopped holder on $size exited $(tail -n 1 "$scratch/out")"
    [ ! -e "$scratch/sh-ran" ] || fail "a check ran beside the stopped holder on $size"
    has_line "^==> heavy-check:   pid=$a quarters=$size " "$scratch/err" || fail "the queued check did not name the stopped holder on $size: $(cat "$scratch/err")"
    kill -CONT "$a"
    s=0; wait "$a" || s=$?
    [ "$s" = 0 ] || fail "the continued holder on $size exited $s"
    [ "$(cat "$scratch/order")" = held ] || fail "the continued holder on $size did not run"
  done
}

# --- waiters outside the queue: a killed or stopped waiter holds back no one -----
t_waiters_skipped() {
  local size flag h a b p
  for size in 4 1; do
    flag=$(size_flag "$size")
    rm -f "$scratch/order" "$scratch"/release-*
    "${hc[@]}" -- "$hold" "$scratch/release-h" >/dev/null 2>&1 &
    h=$!; started+=("$h")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    # A waiter killed outright leaves its ticket, which no longer counts.
    "${hc[@]}" $flag -- sh -c "echo killed >> $scratch/order" >/dev/null 2>"$scratch/wk.err" &
    a=$!; started+=("$a")
    until_true 10 has_line "^==> heavy-check: queued \\($(quarters_words "$size")\\)" "$scratch/wk.err" || fail "the waiter on $size did not queue"
    kill -KILL "$a"; wait "$a" 2>/dev/null || :
    "${hc[@]}" $flag -- sh -c "echo later >> $scratch/order" >/dev/null 2>"$scratch/wl.err" &
    b=$!; started+=("$b")
    until_true 10 has_line "^==> heavy-check: queued \\($(quarters_words "$size")\\) 1 of 1 waiting" "$scratch/wl.err" ||
      fail "a killed waiter on $size still counted ahead: $(cat "$scratch/wl.err")"
    touch "$scratch/release-h"
    wait "$h"; wait "$b"
    [ "$(cat "$scratch/order")" = later ] || fail "a killed waiter on $size held back a later one: $(tr '\n' ' ' < "$scratch/order")"
    # A stopped waiter: a later one passes it, and it runs once continued.
    rm -f "$scratch/order" "$scratch"/release-*
    "${hc[@]}" -- "$hold" "$scratch/release-h" >/dev/null 2>&1 &
    h=$!; started+=("$h")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    "${hc[@]}" $flag -- sh -c "echo stopped >> $scratch/order" >/dev/null 2>"$scratch/ws.err" &
    a=$!; started+=("$a")
    until_true 10 has_line "^==> heavy-check: queued \\($(quarters_words "$size")\\)" "$scratch/ws.err" || fail "the waiter on $size did not queue"
    kill -STOP "$a"
    until_true 5 is_stopped "$a" || fail "the waiter on $size was not stopped"
    "${hc[@]}" $flag -- sh -c "echo later >> $scratch/order" >/dev/null 2>"$scratch/wl.err" &
    b=$!; started+=("$b")
    until_true 10 has_line "^==> heavy-check: queued \\($(quarters_words "$size")\\) 1 of 1 waiting" "$scratch/wl.err" ||
      fail "a stopped waiter on $size still counted ahead: $(cat "$scratch/wl.err")"
    touch "$scratch/release-h"
    wait "$h"; wait "$b"
    [ "$(cat "$scratch/order")" = later ] || fail "a stopped waiter on $size held back a later one: $(tr '\n' ' ' < "$scratch/order")"
    kill -CONT "$a"; wait "$a"
    [ "$(tr '\n' ' ' < "$scratch/order")" = 'later stopped ' ] || fail "the continued waiter on $size did not run after: $(tr '\n' ' ' < "$scratch/order")"
  done
}

# --- the run record: the command's group and its watchdog ------------------------
t_run_record() {
  local size flag file cpus a line group watchdog
  for size in 4 1; do
    flag=$(size_flag "$size")
    case $size in 4) file=lock.holder cpus=$ALL4 ;; 1) file=lock.quarter1.holder cpus=${Q[1]} ;; esac
    # Each command writes its pid whole under a name of its own: a file
    # left by the run before, or one read while it is written, would stand
    # for this command's pid.
    rm -f "$scratch"/release-* "$scratch/rr.pid"
    "${hc[@]}" $flag -- sh -c "echo \$\$ > $scratch/rr.pid.new && mv $scratch/rr.pid.new $scratch/rr.pid; $hold $scratch/release-rr" >/dev/null 2>&1 &
    a=$!; started+=("$a")
    until_true 10 test -s "$scratch/rr.pid" || fail "the command on $size did not start"
    until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/$file" || fail "the record on $size names no watchdog: $(cat "$scratch/$file" 2>/dev/null)"
    line=$(cat "$scratch/$file")
    group=$(sed -n 's/.* group=\([0-9]*\) .*/\1/p' <<<"$line")
    watchdog=$(sed -n 's/.* watchdog=\([0-9]*\) .*/\1/p' <<<"$line")
    [ "$group" = "$(cat "$scratch/rr.pid")" ] || fail "the record on $size names the group $group, not the command's $(cat "$scratch/rr.pid")"
    [ "$(ps -o pgid= -p "$(cat "$scratch/rr.pid")" | tr -d ' ')" = "$group" ] || fail "the command on $size does not lead the group its record names"
    alive "$watchdog" || fail "the record on $size names the watchdog $watchdog, which is not running"
    tr '\0' ' ' < "/proc/$watchdog/cmdline" | grep -q '__contain_watchdog' || fail "the record on $size names $watchdog, not a watchdog"
    has_line "^pid=$a quarters=$size cpus=$cpus since=[0-9T:+-]+ hold=2700s group=$group watchdog=$watchdog checkout=$(pwd -P) command=sh -c " "$scratch/$file" ||
      fail "the record on $size is not in the documented form: $line"
    touch "$scratch/release-rr"; wait "$a"
    [ ! -e "$scratch/$file" ] || fail "a finished run on $size left its record"
    until_true 10 dead "$watchdog" || fail "the watchdog on $size outlived its run"
  done
}
# A command that ends while its watchdog lives, here a stopped one, leaves
# a run that is not finished: its record stays, its quarters stay held and
# --status shows it held, until the watchdog exits.
t_record_watchdog() {
  local size flag file lock a s line watchdog
  for size in 4 1; do
    flag=$(size_flag "$size")
    case $size in
      4) file=lock.holder lock=lock ;;
      1) file=lock.quarter1.holder lock=lock.quarter1 ;;
    esac
    rm -f "$scratch"/release-*
    "${hc[@]}" $flag -- "$hold" "$scratch/release-rw" >/dev/null 2>"$scratch/rw.err" &
    a=$!; started+=("$a")
    until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/$file" || fail "the record on $size names no watchdog: $(cat "$scratch/$file" 2>/dev/null)"
    line=$(cat "$scratch/$file")
    watchdog=$(sed -n 's/.* watchdog=\([0-9]*\) .*/\1/p' <<<"$line")
    kill -STOP "$watchdog"
    touch "$scratch/release-rw"
    s=0; wait "$a" || s=$?
    [ "$s" = 0 ] || { kill -CONT "$watchdog"; fail "the check on $size exited $s"; }
    [ "$(cat "$scratch/$file" 2>/dev/null)" = "$line" ] || { kill -CONT "$watchdog"; fail "the record on $size went while its watchdog lived"; }
    flock -n "$scratch/$lock" true && { kill -CONT "$watchdog"; fail "$lock was free while the watchdog on $size lived"; }
    flock -n "$scratch/lock" true && { kill -CONT "$watchdog"; fail "the machine was free while the watchdog on $size lived"; }
    "${hc[@]}" --status >"$scratch/rw.status" 2>&1
    has_line "^held quarters=$size pid=$a " "$scratch/rw.status" || { kill -CONT "$watchdog"; fail "--status with the watchdog on $size alive: $(cat "$scratch/rw.status")"; }
    kill -CONT "$watchdog"
    until_true 10 dead "$watchdog" || fail "the watchdog on $size did not exit once continued"
    [ "$(status_of "${hc[@]}" --status)" = 0 ] && [ "$(cat "$scratch/out")" = idle ] || fail "the host was not idle once the watchdog on $size exited: $(cat "$scratch/out")"
    forget_killed
  done
}

# --- the environment ---------------------------------------------------------------
t_environment() {
  local p seed share
  # A caller's prefix passes unchanged.
  PROOF_RUN_PREFIX=mine- "${hc[@]}" -q 1 -- sh -c 'echo "$PROOF_RUN_PREFIX"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = mine- ] || fail "a caller's PROOF_RUN_PREFIX became $(body "$scratch/out")"
  # An absent one becomes the caller's worktree's prefix, with this check's pid.
  . "$root/scripts/lib/run-names.sh"
  seed=$(run_names_seed "$root")
  (cd "$root" && "${hc[@]}" -q 1 -- sh -c 'echo "$PROOF_RUN_PREFIX"') >"$scratch/out" 2>/dev/null
  p=$(sed -n 's/^_START=//p' "$scratch/out")
  [ "$(body "$scratch/out")" = "cyfr-$seed-$p-" ] || fail "the injected prefix is $(body "$scratch/out"), not cyfr-$seed-$p-"
  [[ "$(body "$scratch/out")" =~ $RUN_NAMES_PATTERN ]] || fail 'the injected prefix does not match RUN_NAMES_PATTERN'
  # Outside a worktree, the checkout the script lives in names it.
  (cd "$scratch" && "${hc[@]}" -- sh -c 'echo "$PROOF_RUN_PREFIX"') >"$scratch/out" 2>/dev/null
  p=$(sed -n 's/^_START=//p' "$scratch/out")
  [ "$(body "$scratch/out")" = "cyfr-$seed-$p-" ] || fail "outside a worktree the prefix is $(body "$scratch/out"), not the script's checkout's"
  # A caller's ERL_FLAGS keeps its words, the quarter's +S after them; the
  # count is the quarter's processors, one each here.
  ERL_FLAGS='+sbwt none -kernel inet_dist_use_interface {127,0,0,1}' "${hc[@]}" -q 1 -- sh -c 'echo "$ERL_FLAGS|$CYFR_TEST_CORES|$CARGO_BUILD_JOBS"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = "+sbwt none -kernel inet_dist_use_interface {127,0,0,1} +S 1:1|1|1" ] ||
    fail "the environment on one quarter was $(body "$scratch/out")"
  "${hc[@]}" -- sh -c 'echo "${ERL_FLAGS-unset}|${CYFR_TEST_CORES-unset}|${CARGO_BUILD_JOBS-unset}"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = 'unset|unset|unset' ] || fail "a check on four quarters was given a count: $(body "$scratch/out")"
  # A caller's HEAVY_CHECK_CPUS is replaced by the check's own.
  HEAVY_CHECK_CPUS=stale "${hc[@]}" -q 1 -- sh -c 'echo "$HEAVY_CHECK_CPUS"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = "${Q[1]}" ] || fail "a caller's HEAVY_CHECK_CPUS became $(body "$scratch/out")"
}

# --- status ----------------------------------------------------------------------
t_status() {
  local a b gone
  [ "$(status_of "${hc[@]}" --status)" = 0 ] || fail '--status failed on an idle host'
  [ "$(cat "$scratch/out")" = idle ] || fail "an idle host's status was: $(cat "$scratch/out")"
  [ ! -s "$scratch/err" ] || fail "--status wrote to stderr: $(cat "$scratch/err")"
  [ "$(status_of "${hc[@]}" --status -- true)" = 64 ] || fail '--status took a command'
  # A record whose run has finished is never shown: here one naming a pid
  # that has exited and neither group nor watchdog, as a stub.
  gone=$(gone_pid)
  printf 'pid=%s quarters=1 cpus=%s since=2026-10-28T21:02:41+0000 hold=3600s group= watchdog= checkout=/nowhere command=gone\n' "$gone" "${Q[2]}" > "$scratch/lock.quarter2.holder"
  "${hc[@]}" -- "$hold" "$scratch/release-st" >/dev/null 2>&1 &
  a=$!; started+=("$a")
  until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/lock.holder" || fail 'the holder did not start'
  "${hc[@]}" -q 1 -- true >/dev/null 2>"$scratch/stw.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\)' "$scratch/stw.err" || fail 'the waiter did not queue'
  [ "$(status_of "${hc[@]}" --status)" = 0 ] || fail '--status failed'
  [ "$(wc -l < "$scratch/out" | tr -d ' ')" = 2 ] || fail "--status did not print one holder and one waiter: $(cat "$scratch/out")"
  has_line "^held quarters=4 pid=$a cpus=$ALL4 since=[0-9T:+-]+ elapsed=[0-9]+s hold=2700s checkout=$(pwd -P) command=$hold $scratch/release-st\$" <(sed -n 1p "$scratch/out") ||
    fail "the holder line: $(sed -n 1p "$scratch/out")"
  has_line "^waiting 1 quarters=1 pid=$b queued=[0-9T:+-]+ waited=[0-9]+s checkout=$(pwd -P) command=true\$" <(sed -n 2p "$scratch/out") ||
    fail "the waiter line: $(sed -n 2p "$scratch/out")"
  if grep -q "pid=$gone" "$scratch/out"; then fail 'a dead holder was shown'; fi
  touch "$scratch/release-st"; wait "$a"; wait "$b"
  rm -f "$scratch/lock.quarter2.holder"
  [ "$(status_of "${hc[@]}" --status)" = 0 ] && [ "$(cat "$scratch/out")" = idle ] || fail "the host was not idle after: $(cat "$scratch/out")"
}

# --- a queued check repeats its place ------------------------------------------------
t_queued_repeat() {
  local h a b w s=0
  "${hc[@]}" -- "$hold" "$scratch/release-qr" >/dev/null 2>&1 &
  h=$!; started+=("$h")
  until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
  HEAVY_CHECK_REPEAT=1 "${hc[@]}" -- true >"$scratch/qa.out" 2>"$scratch/qa.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 1 of 1 waiting, behind:$' "$scratch/qa.err" || fail 'the first waiter did not queue'
  # Its output and its queued lines in one file, as a task's output is kept.
  HEAVY_CHECK_REPEAT=1 "${hc[@]}" -q 1 -- true >"$scratch/qb.out" 2>&1 &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(1 quarter\) 2 of 2 waiting, behind:$' "$scratch/qb.out" || fail 'the second waiter did not say its place'
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\) 1 of 2 waiting, behind:$' "$scratch/qa.err" || fail 'the first waiter did not repeat its place'
  [ "$(grep -c '^==> heavy-check: queued' "$scratch/qa.err")" -ge 2 ] || fail 'the queued line was not repeated'
  # The waiter keeps a run deadline from running while the lines repeat.
  AWAIT_POLL_SECONDS=1 AWAIT_PID=$b bash "$await" "$scratch/qb.out" '' 2 >"$scratch/await.out" 2>"$scratch/await.err" &
  w=$!; started+=("$w")
  sleep 4
  alive "$w" || fail "the waiter ended while the check was queued: $(cat "$scratch/await.err")"
  touch "$scratch/release-qr"
  wait "$h"; wait "$a"; wait "$b"
  wait "$w" || s=$?
  [ "$s" = 0 ] || fail "the waiter answered $s: $(cat "$scratch/await.err")"
}

# --- the queue deadline on one quarter -------------------------------------------
t_queue_quarter() {
  local q p s=0
  hold_quarters qp
  "${hc[@]}" -q 1 -w 1 -- touch "$scratch/ran-anyway" >"$scratch/out" 2>"$scratch/err" &
  p=$!; started+=("$p")
  wait "$p" || s=$?
  [ "$s" = 75 ] || fail "a check that never got a quarter exited $s"
  [ ! -e "$scratch/ran-anyway" ] || fail 'a check on one quarter ran past its queue deadline'
  has_line '^==> heavy-check: queue deadline after ' "$scratch/err" || fail 'the queue deadline was not reported'
  [ "$(grep -cE '^==> heavy-check:   still held by pid=[0-9]+ quarters=1 cpus=' "$scratch/err")" = 4 ] || fail "the deadline did not name the four holders: $(cat "$scratch/err")"
  framed "$scratch/out" 75 "$p" || fail "the queue path was not framed by pid $p"
  touch "$scratch"/release-qp{1,2,3,4}
  for q in "${quarter_holders[@]}"; do wait "$q"; done
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
  [ "$(status_of "${hc[@]}" -w 1 -- true)" = 0 ] || fail 'the host was not free after a stopped check'
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

# --- the queue deadline --------------------------------------------------------
t_queue() {
  local q p s=0
  "${hc[@]}" -- "$hold" "$scratch/release-q" >/dev/null 2>&1 &
  q=$!; started+=("$q")
  until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
  "${hc[@]}" -w 1 -- touch "$scratch/ran-anyway" >"$scratch/out" 2>"$scratch/err" &
  p=$!; started+=("$p")
  wait "$p" || s=$?
  [ "$s" = 75 ] || fail "a check that never got the host exited $s"
  [ ! -e "$scratch/ran-anyway" ] || fail 'a check ran past its queue deadline'
  has_line '^==> heavy-check: queue deadline after ' "$scratch/err" || fail 'the queue deadline was not reported'
  framed "$scratch/out" 75 "$p" || fail "the queue path was not framed by pid $p"
  [ -s "$scratch/lock.holder" ] || fail "a check that gave up removed the holder's record"
  touch "$scratch/release-q"; wait "$q"
}

# --- the default queue deadline outlasts every stage row's hold ----------------
# scripts/stage.sh queues each row with its hold alone (-t), so a row queued
# behind another waits heavy-check's default queue deadline: one at or under
# a row's hold would let a row behind that one give up unrun, exit 75.
# await-task.sh's default queue deadline is the same, so an await does not
# give up on a check that still waits.
default_queue() {
  sed -n 's/^QUARTERS=4; HOLD=[0-9]*; QUEUE=\([1-9][0-9]*\); STATUS=false$/\1/p' "$check"
}
# unheld TABLE: each row of TABLE whose hold the default does not outlast.
unheld() {
  local queue
  queue=$(default_queue)
  [ "$(printf '%s\n' "$queue" | grep -c .)" = 1 ] || { echo "no one QUEUE default in $check"; return; }
  awk -F'\t' -v queue="$queue" '!/^#/ && NF == 7 && $4 + 0 >= queue + 0 { print $1 "/" $2 " holds " $4 }' "$1"
}
t_queue_default() {
  local left awaits
  left=$(unheld "$root/scripts/stages.tsv")
  [ -z "$left" ] || fail "the default queue deadline does not outlast: $left"
  awaits=$(sed -n 's/^queue_deadline=${AWAIT_QUEUE_SECONDS:-\([1-9][0-9]*\)}$/\1/p' "$await")
  [ -n "$awaits" ] && [ "$awaits" = "$(default_queue)" ] ||
    fail "await-task's default queue deadline is '$awaits', not heavy-check's $(default_queue)"
  # The control: a row that holds as long as the default is caught.
  { cat "$root/scripts/stages.tsv"; printf 'release\tlong\t4\t14400\t-\talways\ttrue\n'; } >"$scratch/stages.tsv"
  [ "$(unheld "$scratch/stages.tsv")" = 'release/long holds 14400' ] || fail "a row holding the default was not caught: $(unheld "$scratch/stages.tsv")"
}

# --- a stage's rows side by side on this queue ----------------------------------
# scripts/stage.sh queues every row that names no folder when the stage
# starts: two of them hold a quarter each at once, each told its own
# processors, and a stage stopped while they run stops both and gives every
# quarter back (the loop below the cases checks that none is left held).
t_stage_side_by_side() {
  local repo=$scratch/stage-repo s=0 one two runner held
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
  [ "$("${hc[@]}" --status | grep -c '^held quarters=1 ')" = 2 ] || fail "the queue showed: $("${hc[@]}" --status | tr '\n' '|')"
  held=$(pgrep -f '^sleep 612[12]$' | tr '\n' ' ')
  s=0
  kill -TERM "$runner"
  until_true 10 eval '! kill -0 "$runner"' || fail 'the stage was still running 10 s after TERM'
  wait "$runner" || s=$?
  [ "$s" = 143 ] || fail "the stopped stage exited $s, not 143"
  for one in $held; do dead "$one" || fail "a row's command outlived the stopped stage"; done
  [ "$("${hc[@]}" --status)" = idle ] || fail "the queue still showed: $("${hc[@]}" --status | tr '\n' '|')"
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
  [ ! -e "$scratch/lock.holder" ] || fail 'left its holder record'
  [ "$(registries)" = 0 ] || fail 'left its registry'
  [ "$(status_of "${hc[@]}" -w 1 -- true)" = 0 ] || fail 'the host was not free after an interrupted check'
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
  [ ! -e "$scratch/lock.holder" ] || fail 'left its holder record'
}

# --- stopping a check on one quarter: TERM and the hold deadline ---------------
# Either stops the command and its child, removes the quarter's record and
# gives the quarter back before the check exits, while the other quarters'
# holder runs on.
t_quarter_stop() {
  local how i s o
  "${hc[@]}" -q 1 -- "$hold" "$scratch/release-qs" >/dev/null 2>&1 &
  o=$!; started+=("$o")
  until_true 10 test -s "$scratch/lock.quarter1.holder" || fail 'the other holder did not start'
  for how in term hold; do
    rm -f "$scratch/qs.pid" "$scratch/qs.out" "$scratch/qs.err"
    case $how in
      term) "${hc[@]}" -q 1 -- sh -c "sleep 120 & echo \$! > $scratch/qs.pid; wait" >"$scratch/qs.out" 2>"$scratch/qs.err" & ;;
      hold) "${hc[@]}" -q 1 -t 1 -- sh -c "sleep 120 & echo \$! > $scratch/qs.pid; wait" >"$scratch/qs.out" 2>"$scratch/qs.err" & ;;
    esac
    i=$!; started+=("$i")
    until_true 10 test -s "$scratch/qs.pid" || fail "$how: the check did not start"
    has_line "^==> heavy-check: running \\(1 quarter, processors ${Q[2]}\\) " "$scratch/qs.err" || fail "$how: not on quarter 2: $(cat "$scratch/qs.err")"
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
# signal_queued MODE SIGNAL STATUS [LAUNCHER...]
signal_queued() {
  local mode=$1 sig=$2 want=$3 i q s=0 holders=() n; shift 3
  if [ "$mode" = 1 ]; then
    for n in 1 2 3 4; do
      "${hc[@]}" -q 1 -- sh -c "touch $scratch/sq$n.started; $hold $scratch/release-sq" >/dev/null 2>&1 &
      holders+=("$!"); started+=("$!")
      until_true 10 test -e "$scratch/sq$n.started" || fail "quarter holder $n did not start"
    done
    set -- "$@" "${hc[@]}" -q 1
  else
    "${hc[@]}" -- "$hold" "$scratch/release-sq" >/dev/null 2>&1 &
    holders+=("$!"); started+=("$!")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    set -- "$@" "${hc[@]}"
  fi
  # The three signals' cases of one mode share these files, and a background
  # job truncates its redirections in the child, after this shell has gone
  # on: the previous case's queued line and start line would be read as
  # this check's.
  rm -f "$scratch/q.out" "$scratch/q.err"
  "$@" -- touch "$scratch/queued-ran" >"$scratch/q.out" 2>"$scratch/q.err" &
  q=$!; started+=("$q")
  until_true 10 has_line "^==> heavy-check: queued \\($(quarters_words "$mode")\\)" "$scratch/q.err" || fail 'the check did not queue'
  [ "$(head -n 1 "$scratch/q.out")" = "_START=$q" ] ||
    fail "a queued check had not written its start line: $(head -n 1 "$scratch/q.out")"
  kill "-$sig" "$q"
  until_true 2 dead "$q" || fail "a queued check given $sig was still running 2s later"
  wait "$q" || s=$?
  [ "$s" = "$want" ] || fail "a queued check given $sig exited $s"
  framed "$scratch/q.out" "$want" "$q" || fail "not framed by pid $q: $(tr '\n' '|' < "$scratch/q.out")"
  [ ! -e "$scratch/queued-ran" ] || fail 'the interrupted check ran its command'
  touch "$scratch/release-sq"
  for i in "${holders[@]}"; do wait "$i"; done
  rm -f "$scratch"/sq*.started "$scratch/release-sq"
}
t_term_queued() { signal_queued 4 TERM 143; }
t_int_queued() { signal_queued 4 INT 130 "${with_int[@]}"; }
t_hup_queued() { signal_queued 4 HUP 129 "${with_hup[@]}"; }
t_term_queued_quarter() { signal_queued 1 TERM 143; }
t_int_queued_quarter() { signal_queued 1 INT 130 "${with_int[@]}"; }
t_hup_queued_quarter() { signal_queued 1 HUP 129 "${with_hup[@]}"; }

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
  [ ! -e "$scratch/lock.holder" ] || fail 'a refused start left its holder record'
  [ "$(registries)" = 0 ] || fail 'a refused start left its registry'
}

# --- what a command leaves behind is gone before the next check starts ----------
# leftover NAME COMMAND
leftover() {
  [ "$(status_of "${hc[@]}" -- sh -c "$2")" = 0 ] || fail "the $1 command failed"
  ran "$scratch/err" || fail 'did not run as an outermost check'
  [ "$(status_of "${hc[@]}" -w 5 -- "$probe" "$scratch/$1.state" "$scratch/$1.pid")" = 0 ] || fail "a command's leftover process kept the host"
  [ "$(cat "$scratch/$1.state")" = dead ] || fail "the $1 leftover was alive when the next check started"
  until_true 5 dead "$(cat "$scratch/$1.pid")" || fail "the $1 leftover survived"
}
t_leftover() {
  leftover orphan "sleep 30 >/dev/null 2>&1 & echo \$! > $scratch/orphan.pid"
  leftover grouped-orphan "exec bash -c 'set -m; sleep 30 >/dev/null 2>&1 & echo \$! > $scratch/grouped-orphan.pid'"
}

# --- heavy-check killed outright: its command dies before the host moves on ------
t_sigkill() {
  local k n s=0
  "${hc[@]}" -- sh -c "sleep 120 & echo \$! > $scratch/k-grandchild.pid; echo \$\$ > $scratch/k-command.pid; wait" >/dev/null 2>"$scratch/k1.err" &
  k=$!; started+=("$k")
  until_true 10 test -s "$scratch/k-grandchild.pid" -a -s "$scratch/k-command.pid" || fail 'the command did not start'
  "${hc[@]}" -- "$probe" "$scratch/k.state" "$scratch/k-command.pid" "$scratch/k-grandchild.pid" >/dev/null 2>"$scratch/k2.err" &
  n=$!; started+=("$n")
  until_true 10 has_line '^==> heavy-check: queued \(4 quarters\)' "$scratch/k2.err" || fail 'the next check did not queue'
  kill -KILL "$k"
  wait "$k" 2>/dev/null || :
  wait "$n" || s=$?
  [ "$s" = 0 ] || fail "the next check exited $s"
  [ "$(tr '\n' ' ' < "$scratch/k.state")" = 'dead dead ' ] || fail "the next check started beside the killed check's command: $(tr '\n' ' ' < "$scratch/k.state")"
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
  [ ! -e "$scratch/lock.holder" ] || fail "a finished run left its record: $(cat "$scratch/lock.holder")"
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
  has_line "^pid=[0-9]+ quarters=4 " "$scratch/lock.holder" || fail 'a run whose survivor outlived KILL removed its record'
  kill "$v"; wait "$v" 2>/dev/null || :
  forget_killed
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
  [ "$(AWAIT_QUEUE_SECONDS=x await "$scratch/task")" = 64 ] || fail 'accepted a non-numeric queue deadline'
  [ "$(AWAIT_QUEUE_SECONDS=0 await "$scratch/task")" = 64 ] || fail 'accepted a zero queue deadline'
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
  printf '%s\n' "_START=$$" '==> heavy-check: queued (4 quarters) 1 of 1 waiting, behind:' > "$scratch/task"
  (sleep 3; printf '%s\n' '==> heavy-check: running (4 quarters, processors 0) after 3s queued: x' '' "_EXIT=$$ 0" >> "$scratch/task") &
  w=$!; started+=("$w")
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 1)" = 0 ] || fail 'the run deadline ran out while the check was queued'
  wait "$w"
  printf '%s\n' "_START=$$" '==> heavy-check: queued (4 quarters) 1 of 1 waiting, behind:' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_QUEUE_SECONDS=2 await "$scratch/task" '' 600)" = 2 ] || fail 'a check that never left the queue was awaited past the queue deadline'
  has_line '^QUEUE DEADLINE after 2s' "$scratch/err" || fail 'the queue deadline was not named'
  printf '%s\n' "_START=$$" '==> heavy-check: queued (4 quarters) 1 of 1 waiting, behind:' '==> heavy-check: running (4 quarters, processors 0) after 9s queued: x' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 2)" = 2 ] || fail 'a running check was awaited past its deadline'
  has_line '^DEADLINE after 2s' "$scratch/err" || fail 'the run deadline was not named'
}

cases=(
  usage admission nested result frame roster fds fd_base elsewhere cut host unplaced
  whole redaction killed_holder killed_quarter quarters placement quarter_order quarter_stale quarter_stopped
  all_or_none stopped_take precedence expired_waiter admission_stopped ticket_order admission_two_stopped stopped_holder
  waiters_skipped run_record record_watchdog environment status queued_repeat queue_quarter
  hold hold_frame queue queue_default stage_side_by_side term int hup usr1 quarter_stop term_queued int_queued hup_queued
  term_queued_quarter int_queued_quarter hup_queued_quarter refusals
  leftover sigkill nested_session registry_nested survivor survivor_remains
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
  # Every case leaves the host and every quarter free, and no record,
  # registry or ticket behind.
  host_free || fail 'the scratch lock was still held after the case'
  for q in 1 2 3 4; do flock -n "$scratch/lock.quarter$q" true 2>/dev/null || [ ! -e "$scratch/lock.quarter$q" ] || fail "quarter $q was still held after the case"; done
  [ ! -e "$scratch/lock.holder" ] || fail 'a holder record was left'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.quarter*.holder')" ] || fail "a quarter's holder record was left"
  [ "$(registries)" = 0 ] || fail 'a registry was left'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'a ticket was left'
done
echo 'heavy check tests passed'
