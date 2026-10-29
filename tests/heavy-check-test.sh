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
# A check started under a check gets its parent's prefix and slot share;
# every check here starts as an outermost one with neither.
unset PROOF_RUN_PREFIX ERL_FLAGS CARGO_BUILD_JOBS HEAVY_CHECK_REPEAT
unset AWAIT_PID AWAIT_POLL_SECONDS AWAIT_QUEUE_SECONDS
# The checks' registries and watchdog pipes are made here, so a case can
# see that none is left.
mkdir "$scratch/tmp"
export TMPDIR="$scratch/tmp"
export HEAVY_CHECK_LOCK="$scratch/lock" HEAVY_CHECK_GRACE=1
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
# its registry file and its lane's holder record, which stays until its
# run is finished (its pid, group and watchdog gone) and the lane's next
# holder replaces it; nothing else.
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
  for f in "$scratch/lock.holder" "$scratch/lock.proof.holder" "$scratch"/lock.slot[0-9].holder; do
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
# A BASH_ENV for a check: it stops itself, once, the first time its function
# $STOP_FN runs a command matching the pattern $STOP_CMD, and creates
# $STOP_MARK as it does.
cat > "$scratch/stop-at" <<'STOPAT'
set -T
trap 'if [[ ${FUNCNAME[0]:-} == "$STOP_FN" && $BASH_COMMAND == $STOP_CMD && ! -e $STOP_MARK ]]; then : > "$STOP_MARK"; kill -STOP $$; fi' DEBUG
STOPAT
chmod +x "$scratch/hold" "$scratch/probe" "$scratch/stubborn"
hold="$scratch/hold"
probe="$scratch/probe"

# --- usage and admission ---------------------------------------------------
t_usage() {
  [ "$(status_of "${hc[@]}")" = 64 ] || fail 'ran with no command'
  [ "$(status_of "${hc[@]}" -t 0 -- true)" = 64 ] || fail 'accepted a zero hold'
  [ "$(status_of "${hc[@]}" -w soon -- true)" = 64 ] || fail 'accepted a non-numeric queue deadline'
  [ "$(status_of "${hc[@]}" -x -- true)" = 64 ] || fail 'accepted an unknown option'
  [ ! -s "$scratch/out" ] || fail 'a usage error wrote a terminal line'
}

t_admission() {
  # The command's own grammar decides what fits a scoped slot; the check
  # reads none of it.
  [ "$(status_of "${hc[@]}" -s -- true scripts/test-partitioned.sh -n 4)" = 0 ] || fail 'did not run the command as given'
  ran "$scratch/err" || fail 'did not run as an outermost check'
  [ "$(status_of "${hc[@]}" -s -- sh -c 'echo "$HEAVY_CHECK_HELD"')" = 0 ] || fail 'the scoped stub failed'
  [ "$(body "$scratch/out")" = scoped ] || fail "a scoped command saw HEAVY_CHECK_HELD=$(body "$scratch/out")"
}

t_nested() {
  [ "$(status_of "${hc[@]}" -- bash "$check" -- sh -c 'exit 5')" = 5 ] || fail 'a nested check did not run under its parent'
  framed "$scratch/out" 5 || fail "a nested check wrote lines of its own: $(tr '\n' '|' < "$scratch/out")"
  [ "$(status_of "${hc[@]}" -s -- bash "$check" -s -- true)" = 0 ] || fail 'a scoped check inside a scoped check did not run'
  [ "$(status_of "${hc[@]}" -s -- bash "$check" -- true)" = 64 ] || fail 'an exclusive check started inside a scoped one'
  framed "$scratch/out" 64 || fail 'the refused nested check was not framed by its parent alone'
  [ "$(status_of "${hc[@]}" -s -- bash "$check" -p -- true)" = 64 ] || fail 'a proof started inside a scoped check'
  [ "$(status_of "${hc[@]}" -p -- bash "$check" -- true)" = 64 ] || fail 'an exclusive check started inside a proof'
  framed "$scratch/out" 64 || fail 'the refused nested check was not framed by its proof alone'
  [ "$(status_of "${hc[@]}" -p -- bash "$check" -p -- sh -c 'exit 6')" = 6 ] || fail 'a proof inside a proof did not run in place'
  framed "$scratch/out" 6 || fail "a proof inside a proof wrote lines of its own: $(tr '\n' '|' < "$scratch/out")"
  [ "$(status_of "${hc[@]}" -p -- bash "$check" -s -- sh -c 'echo "$HEAVY_CHECK_HELD"')" = 0 ] || fail 'a scoped check inside a proof did not run'
  [ "$(body "$scratch/out")" = proof ] || fail "a scoped check inside a proof ran as $(body "$scratch/out"), not in place"
}

# --- the command's own result ----------------------------------------------
t_result() {
  [ "$(status_of "${hc[@]}" -- sh -c 'echo said; exit 7')" = 7 ] || fail "lost the command's status"
  framed "$scratch/out" 7 || fail "the run was not framed: $(tr '\n' '|' < "$scratch/out")"
  [ "$(body "$scratch/out")" = said ] || fail "lost the command's output"
  has_line '^==> heavy-check: running \(exclusive\) after [0-9]+s queued' "$scratch/err" || fail 'did not say it started'
  has_line '^==> heavy-check: exit 7 after [0-9]+s \(queued [0-9]+s\)$' "$scratch/err" || fail 'did not say how it ended'
  [ ! -e "$scratch/lock.holder" ] || fail 'left its holder record'
  status_of "${hc[@]}" -- sh -c 'echo "$HEAVY_CHECK_HELD ${CYFR_TEST_CORES:-whole}"' >/dev/null
  [ "$(body "$scratch/out")" = 'exclusive whole' ] || fail 'an exclusive check was given a share of the cores'
  status_of "${hc[@]}" -s -- sh -c 'echo "$HEAVY_CHECK_HELD ${CYFR_TEST_CORES:-whole}"' >/dev/null
  case "$(body "$scratch/out")" in 'scoped '[1-9]*) ;; *) fail 'a scoped check was not given its share of the cores' ;; esac
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
  "${hc[@]}" -s -- env 2>/dev/null > "$scratch/env-raw"
  body "$scratch/env-raw" | sed 's/=.*//' > "$scratch/env-inside"
  added=$(grep -vxF -f "$scratch/env-before" "$scratch/env-inside" | LC_ALL=C sort | tr '\n' ' ')
  [ "$added" = 'CARGO_BUILD_JOBS CONTAIN_REGISTRY CYFR_TEST_CORES ERL_FLAGS HEAVY_CHECK_HELD PROOF_RUN_PREFIX ' ] || fail "a scoped check added: $added"
  local mode
  for mode in exclusive proof; do
    if [ "$mode" = proof ]; then "${hc[@]}" -p -- env 2>/dev/null > "$scratch/env-raw"; else "${hc[@]}" -- env 2>/dev/null > "$scratch/env-raw"; fi
    body "$scratch/env-raw" | sed 's/=.*//' > "$scratch/env-inside"
    added=$(grep -vxF -f "$scratch/env-before" "$scratch/env-inside" | LC_ALL=C sort | tr '\n' ' ')
    [ "$added" = 'CONTAIN_REGISTRY HEAVY_CHECK_HELD PROOF_RUN_PREFIX ' ] || fail "a $mode check added: $added"
  done
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

# --- one exclusive check at a time -------------------------------------------
t_exclusive() {
  local a b
  "${hc[@]}" -- sh -c "echo a-start >> $scratch/order; $hold $scratch/release-a; echo a-end >> $scratch/order" >/dev/null 2>"$scratch/a.err" &
  a=$!; started+=("$a")
  until_true 10 test -s "$scratch/lock.holder" || fail 'the holder left no record'
  "${hc[@]}" -- sh -c "echo b >> $scratch/order" >/dev/null 2>"$scratch/b.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\) 1 of 1 waiting, behind:$' "$scratch/b.err" || fail 'a queued check did not say so'
  has_line "^==> heavy-check:   pid=$a mode=exclusive since=[0-9T:+-]+ hold=2700s group=[0-9]+ watchdog=[0-9]+ checkout=$(pwd -P) command=sh -c " "$scratch/b.err" ||
    fail "a queued check did not name the holder: $(cat "$scratch/b.err")"
  [ "$(cat "$scratch/order")" = a-start ] || fail 'a second exclusive check ran beside the first'
  touch "$scratch/release-a"; wait "$a"; wait "$b"
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'a-start a-end b ' ] || fail "exclusive checks overlapped: $(tr '\n' ' ' < "$scratch/order")"
  has_line '^==> heavy-check: running \(exclusive\) after ' "$scratch/b.err" || fail 'the queued check did not say when it started'
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
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\) 1 of 1 waiting, behind:$' "$scratch/r2.err" || fail 'the second check did not queue'
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
  until_true 10 has_line "^==> heavy-check:   pid=$k mode=exclusive .* group=$leader watchdog=[0-9]+ " "$scratch/kh2.err" ||
    fail "did not queue naming the killed check's run: $(cat "$scratch/kh2.err")"
  [ "$(cat "$scratch/lock.holder")" = "$record" ] || fail "the killed check's record changed while its run lived"
  [ ! -e "$scratch/after-killed" ] || fail "ran beside the killed check's command"
  kill -KILL "$leader"
  wait "$n" || fail 'the queued check failed'
  [ -e "$scratch/after-killed" ] || fail "did not run after the killed check's watchdog let the host go"
  forget_killed
}

# --- scoped runs: three side by side, the fourth waits ------------------------
t_scoped() {
  local i pids=()
  for i in 1 2 3 4; do
    "${hc[@]}" -s -- sh -c "touch $scratch/s$i.started; $hold $scratch/release-s" >/dev/null 2>"$scratch/s$i.err" &
    pids+=("$!"); started+=("$!")
    [ "$i" = 4 ] || until_true 10 test -e "$scratch/s$i.started" || fail "scoped run $i did not start beside the others"
  done
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/s4.err" || fail 'a fourth scoped run was not queued'
  [ ! -e "$scratch/s4.started" ] || fail 'a fourth scoped run started'
  touch "$scratch/release-s"
  until_true 10 test -e "$scratch/s4.started" || fail 'the fourth scoped run never started'
  for i in "${pids[@]}"; do wait "$i"; done
}

# --- scoped waiters take slots in the order they queued -----------------------
# hold_slots TAG: three scoped checks that hold every slot until
# release-TAG<n> appears; their pids in $slot_holders.
hold_slots() {
  local n
  slot_holders=()
  for n in 1 2 3; do
    "${hc[@]}" -s -- sh -c "touch $scratch/$1$n.started; $hold $scratch/release-$1$n" >/dev/null 2>&1 &
    slot_holders+=("$!"); started+=("$!")
    until_true 10 test -e "$scratch/$1$n.started" || fail "slot holder $n did not start"
  done
}
# A waiter that polls first is not the one that queued first: every round
# frees one slot to two waiters queued in order, and the earlier one runs.
# The second arrives half a second after the first and the slot frees at a
# random moment after that, so a queue that served whoever polled next
# would give the second the slot in most rounds.
t_scoped_order() {
  local round a b p
  for round in 1 2 3 4 5 6 7 8; do
    rm -f "$scratch"/release-* "$scratch/order" "$scratch"/so*.started
    hold_slots so
    "${hc[@]}" -s -- sh -c "echo A >> $scratch/order; $hold $scratch/release-w" >/dev/null 2>"$scratch/soA.err" &
    a=$!; started+=("$a")
    until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/soA.err" || fail "round $round: the first waiter did not queue"
    sleep 0.5
    "${hc[@]}" -s -- sh -c "echo B >> $scratch/order; $hold $scratch/release-w" >/dev/null 2>"$scratch/soB.err" &
    b=$!; started+=("$b")
    until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/soB.err" || fail "round $round: the second waiter did not queue"
    sleep "0.$((RANDOM % 10))"
    touch "$scratch/release-so$(( (round - 1) % 3 + 1 ))"
    until_true 10 test -s "$scratch/order" || fail "round $round: no waiter ran after a slot freed"
    [ "$(cat "$scratch/order")" = A ] || fail "round $round: the later waiter took the slot: $(tr '\n' ' ' < "$scratch/order")"
    touch "$scratch/release-w" "$scratch/release-so1" "$scratch/release-so2" "$scratch/release-so3"
    for p in "${slot_holders[@]}" "$a" "$b"; do wait "$p"; done
    [ "$(tr '\n' ' ' < "$scratch/order")" = 'A B ' ] || fail "round $round: the waiters did not both run in order: $(tr '\n' ' ' < "$scratch/order")"
  done
}
# A waiter killed outright leaves its ticket's file, which no longer holds
# anyone back.
t_scoped_stale() {
  local a b p
  rm -f "$scratch/order"
  hold_slots st
  "${hc[@]}" -s -- true >/dev/null 2>"$scratch/stA.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/stA.err" || fail 'the first waiter did not queue'
  kill -KILL "$a"; wait "$a" 2>/dev/null || :
  [ -n "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'the killed waiter left no ticket to step over'
  "${hc[@]}" -s -- sh -c "echo B >> $scratch/order" >/dev/null 2>"$scratch/stB.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/stB.err" || fail 'the second waiter did not queue'
  touch "$scratch/release-st1"
  until_true 10 has_line '^B$' "$scratch/order" || fail "a dead waiter's ticket kept a later one waiting"
  touch "$scratch/release-st2" "$scratch/release-st3"
  for p in "${slot_holders[@]}" "$b"; do wait "$p"; done
}

# A stopped waiter holds back no one: a later waiter takes the slot that
# frees, and the stopped one runs once it is continued.
t_scoped_stopped() {
  local a b p n
  rm -f "$scratch/order"
  hold_slots ss
  "${hc[@]}" -s -- sh -c "echo A >> $scratch/order" >/dev/null 2>"$scratch/ssA.err" &
  a=$!; started+=("$a")
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/ssA.err" || fail 'the first waiter did not queue'
  # Stopped between scans: a waiter stopped inside one holds the admission
  # lock, which the admission_stopped case covers.
  for n in $(seq 50); do
    kill -STOP "$a"
    flock -n "$scratch/lock.queue" true && break
    kill -CONT "$a"; sleep 0.1
  done
  until_true 5 sh -c "sed 's/.*) //' /proc/$a/stat | grep -q '^T'" || fail 'the first waiter was not stopped'
  "${hc[@]}" -s -- sh -c "echo B >> $scratch/order" >/dev/null 2>"$scratch/ssB.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/ssB.err" || fail 'the second waiter did not queue'
  touch "$scratch/release-ss1"
  until_true 10 has_line '^B$' "$scratch/order" || fail 'a stopped waiter held back a later one'
  kill -CONT "$a"
  touch "$scratch/release-ss2" "$scratch/release-ss3"
  for p in "${slot_holders[@]}" "$a" "$b"; do wait "$p"; done
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'B A ' ] || fail "the continued waiter did not run after: $(tr '\n' ' ' < "$scratch/order")"
}

# A wait for the admission lock, here behind a holder that runs and never
# lets go, keeps the queue deadline and answers TERM at once.
t_queue_lock() {
  local f q s t
  flock "$scratch/lock.queue" "$hold" "$scratch/release-ql" &
  f=$!; started+=("$f")
  until_true 10 sh -c "! flock -n '$scratch/lock.queue' true" || fail 'the queue lock was not taken'
  echo "$f" > "$scratch/lock.queue.owner"
  t=$SECONDS
  [ "$(status_of "${hc[@]}" -s -w 1 -- touch "$scratch/ql-ran")" = 75 ] || fail 'a check waiting on the queue lock past its deadline did not exit 75'
  [ $((SECONDS - t)) -le 3 ] || fail "the queue deadline answered only after $((SECONDS - t))s"
  framed "$scratch/out" 75 || fail "the queue deadline was not framed: $(tr '\n' '|' < "$scratch/out")"
  has_line '^==> heavy-check: queue deadline after ' "$scratch/err" || fail 'the queue deadline was not reported'
  "${hc[@]}" -s -- touch "$scratch/ql-ran" >"$scratch/ql.out" 2>"$scratch/ql.err" &
  q=$!; started+=("$q")
  until_true 10 pgrep -P "$q" -x flock >/dev/null || fail 'the second check did not wait for the queue lock'
  kill -TERM "$q"
  until_true 2 dead "$q" || fail 'a check waiting on the queue lock given TERM was still running 2s later'
  s=0; wait "$q" || s=$?
  [ "$s" = 143 ] || fail "a check waiting on the queue lock given TERM exited $s"
  framed "$scratch/ql.out" 143 "$q" || fail "not framed by pid $q: $(tr '\n' '|' < "$scratch/ql.out")"
  [ ! -e "$scratch/ql-ran" ] || fail 'a check that never had the queue lock ran'
  touch "$scratch/release-ql"; wait "$f"
}

# A waiter stopped while it queued and continued after its queue deadline
# exits 75 and runs nothing, though its lane is free by then.
t_expired_waiter() {
  local lane flag h w n s
  for lane in exclusive proof scoped; do
    flag=$(lane_flag "$lane")
    rm -f "$scratch"/release-* "$scratch/ew-ran"
    "${hc[@]}" -- "$hold" "$scratch/release-ew" >/dev/null 2>&1 &
    h=$!; started+=("$h")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    "${hc[@]}" $flag -w 2 -- touch "$scratch/ew-ran" >"$scratch/ew.out" 2>"$scratch/ew.err" &
    w=$!; started+=("$w")
    until_true 10 has_line "^==> heavy-check: queued \\($lane\\)" "$scratch/ew.err" || fail "the $lane waiter did not queue"
    # Stopped outside the admission lock, as a waiter between its scans.
    for n in $(seq 50); do
      kill -STOP "$w"
      until_true 5 is_stopped "$w" || fail "the $lane waiter did not stop"
      flock -n "$scratch/lock.queue" true && break
      kill -CONT "$w"; sleep 0.05
    done
    alive "$w" || fail "the $lane waiter gave up before it was stopped"
    touch "$scratch/release-ew"; wait "$h"
    sleep 3
    kill -CONT "$w"
    s=0; wait "$w" || s=$?
    [ "$s" = 75 ] || fail "a $lane waiter continued after its queue deadline exited $s"
    [ ! -e "$scratch/ew-ran" ] || fail "a $lane waiter ran after its queue deadline"
    framed "$scratch/ew.out" 75 "$w" || fail "not framed by pid $w: $(tr '\n' '|' < "$scratch/ew.out")"
    has_line '^==> heavy-check: queue deadline after ' "$scratch/ew.err" || fail 'the queue deadline was not reported'
  done
}

# A check stopped while it holds the admission lock, here in its
# first-in-line test, keeps no one waiting past ADMIT_STEP (1 s): a later
# check passes it and runs, the stopped one keeps its ticket, and once
# continued it runs too.
t_admission_stopped() {
  local lane flag a s t
  for lane in exclusive proof scoped; do
    flag=$(lane_flag "$lane")
    rm -f "$scratch/order" "$scratch/stopped-mark"
    "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_FN=places STOP_CMD='ahead=0 waiting=0' STOP_MARK="$scratch/stopped-mark" \
      bash "$check" $flag -- sh -c "echo stopped >> $scratch/order" >/dev/null 2>"$scratch/as1.err" &
    a=$!; started+=("$a")
    until_true 10 test -e "$scratch/stopped-mark" || fail "the $lane check did not reach its first-in-line test"
    until_true 5 is_stopped "$a" || fail "the $lane check did not stop"
    ! flock -n "$scratch/lock.queue" true || fail "the stopped $lane check does not hold the admission lock"
    t=$SECONDS
    [ "$(status_of "${hc[@]}" $flag -w 10 -- sh -c "echo later >> $scratch/order")" = 0 ] ||
      fail "a later $lane check behind one stopped in admission exited $(tail -n 1 "$scratch/out"): $(cat "$scratch/err")"
    [ $((SECONDS - t)) -le 3 ] || fail "a later $lane check waited $((SECONDS - t))s behind one stopped in admission"
    # It said it queued, in the one form, before it ran: the stopped check
    # is no waiter ahead of it and no lane's holder.
    grep '^==> heavy-check: ' "$scratch/err" | sed -n 1,2p > "$scratch/as2.lines"
    has_line "^==> heavy-check: queued \\($lane\\) 1 of 1 waiting, behind:\$" <(sed -n 1p "$scratch/as2.lines") &&
      has_line "^==> heavy-check: running \\($lane\\) after [0-9]+s queued: " <(sed -n 2p "$scratch/as2.lines") ||
      fail "the later $lane check's lines: $(grep '^==> heavy-check: ' "$scratch/err")"
    [ "$(cat "$scratch/order")" = later ] || fail "the later $lane check did not run: $(cat "$scratch/order" 2>/dev/null)"
    [ -n "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail "the stopped $lane check lost its ticket"
    kill -CONT "$a"
    s=0; wait "$a" || s=$?
    [ "$s" = 0 ] || fail "the continued $lane check exited $s"
    [ "$(tr '\n' ' ' < "$scratch/order")" = 'later stopped ' ] || fail "the continued $lane check did not run after: $(tr '\n' ' ' < "$scratch/order")"
  done
}

# A check stopped in admission after it found room, and passed while it was
# stopped, gives back the lane it then takes: here a scoped check that saw
# no proof running is passed by a proof, which takes the one scoped place
# beside it (PROOF_SCOPED), so the continued scoped check waits for the
# proof to end.
t_admission_undo() {
  local s1 a b
  [ "$(sed -n 's/^PROOF_SCOPED=//p' "$check")" = 1 ] || return 0
  rm -f "$scratch/order" "$scratch/stopped-mark"
  "${hc[@]}" -s -- sh -c "echo s1 >> $scratch/order; $hold $scratch/release-u1" >/dev/null 2>&1 &
  s1=$!; started+=("$s1")
  until_true 10 has_line '^s1$' "$scratch/order" || fail 'the scoped holder did not start'
  "${clean[@]}" BASH_ENV="$scratch/stop-at" STOP_FN=take_lane STOP_CMD='*LOCK.slot$i*' STOP_MARK="$scratch/stopped-mark" \
    bash "$check" -s -- sh -c "echo scoped >> $scratch/order" >/dev/null 2>"$scratch/au.err" &
  a=$!; started+=("$a")
  until_true 10 test -e "$scratch/stopped-mark" || fail 'the scoped check did not reach its slots'
  until_true 5 is_stopped "$a" || fail 'the scoped check did not stop'
  "${hc[@]}" -p -w 10 -- sh -c "echo proof+ >> $scratch/order; $hold $scratch/release-u2; echo proof- >> $scratch/order" >/dev/null 2>&1 &
  b=$!; started+=("$b")
  until_true 5 has_line '^proof\+$' "$scratch/order" || fail 'the proof waited for a check stopped in admission'
  kill -CONT "$a"
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/au.err" || fail 'the passed scoped check did not queue again'
  ! has_line '^scoped$' "$scratch/order" || fail "a passed scoped check kept the lane it took beside the proof: $(tr '\n' ' ' < "$scratch/order")"
  touch "$scratch/release-u2"; wait "$b"
  wait "$a" || fail 'the continued scoped check failed'
  [ "$(tr '\n' ' ' < "$scratch/order")" = 's1 proof+ proof- scoped ' ] || fail "the order was: $(tr '\n' ' ' < "$scratch/order")"
  touch "$scratch/release-u1"; wait "$s1"
}

# A holder of the admission lock that runs but never lets go is passed
# after ADMIT_STALL (10 s), the whole bound on a wait for the lock.
t_admission_stall() {
  local f t e
  rm -f "$scratch/stall-ran"
  flock "$scratch/lock.queue" "$hold" "$scratch/release-as" &
  f=$!; started+=("$f")
  until_true 10 sh -c "! flock -n '$scratch/lock.queue' true" || fail 'the admission lock was not taken'
  echo "$f" > "$scratch/lock.queue.owner"
  t=$SECONDS
  [ "$(status_of "${hc[@]}" -s -w 30 -- touch "$scratch/stall-ran")" = 0 ] || fail "a check behind a holder that never lets go exited: $(cat "$scratch/err")"
  e=$((SECONDS - t))
  [ -e "$scratch/stall-ran" ] || fail 'the check did not run'
  [ "$e" -ge 9 ] && [ "$e" -le 14 ] || fail "passed a holder that never lets go after ${e}s, not ADMIT_STALL"
  touch "$scratch/release-as"; wait "$f"
}

# --- scoped and exclusive never together; a queued exclusive goes first -------
t_precedence() {
  local pids=()
  "${hc[@]}" -s -- sh -c "echo s1 >> $scratch/order; $hold $scratch/release-1" >/dev/null 2>&1 &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^s1$' "$scratch/order" || fail 'the scoped run did not start'
  "${hc[@]}" -- sh -c "echo e >> $scratch/order; $hold $scratch/release-2" >/dev/null 2>"$scratch/e.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\)' "$scratch/e.err" || fail 'an exclusive check did not queue behind a scoped run'
  "${hc[@]}" -s -- sh -c "echo s2 >> $scratch/order" >/dev/null 2>"$scratch/s2.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/s2.err" || fail 'a later scoped run did not queue behind the exclusive check'
  [ "$(cat "$scratch/order")" = s1 ] || fail 'an exclusive check or a later scoped run started beside a scoped one'
  touch "$scratch/release-1"
  until_true 10 has_line '^e$' "$scratch/order" || fail 'the exclusive check never started'
  sleep 0.5
  [ "$(tr '\n' ' ' < "$scratch/order")" = 's1 e ' ] || fail "a scoped run started beside the exclusive check: $(tr '\n' ' ' < "$scratch/order")"
  touch "$scratch/release-2"
  local p; for p in "${pids[@]}"; do wait "$p"; done
  [ "$(tr '\n' ' ' < "$scratch/order")" = 's1 e s2 ' ] || fail 'the queued exclusive check did not go first'
}


# --- the lanes, under either measured PROOF_SCOPED ------------------------------
# variant V: a copy of the script with PROOF_SCOPED=V beside its libraries;
# its command line in $vc.
variant() {
  local d="$scratch/ps$1"
  if [ ! -e "$d/heavy-check.sh" ]; then
    mkdir -p "$d/lib"
    sed "s/^PROOF_SCOPED=[01]\$/PROOF_SCOPED=$1/" "$check" > "$d/heavy-check.sh"
    grep -qx "PROOF_SCOPED=$1" "$d/heavy-check.sh" || fail "the copy does not set PROOF_SCOPED=$1"
    cp "$root/scripts/lib/contain.sh" "$root/scripts/lib/run-names.sh" "$d/lib/"
  fi
  vc=("${clean[@]}" bash "$d/heavy-check.sh")
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

# Three scoped run and a proof queues, then two more scoped queue. With
# PROOF_SCOPED=1 the proof starts once two scoped have ended and runs beside
# the third; with 0 it starts once all three have ended and runs alone.
# Either way the two later scoped wait until the proof has started: no
# starvation and no deadlock.
proof_among_scoped() {
  local v=$1 n pids=()
  variant "$v"
  rm -f "$scratch/order" "$scratch"/release-*
  for n in 1 2 3; do
    "${vc[@]}" -s -- sh -c "echo s$n >> $scratch/order; $hold $scratch/release-s$n; echo s$n-end >> $scratch/order" >/dev/null 2>&1 &
    pids+=("$!"); started+=("$!")
    until_true 10 started_in_order "s$n" || fail "PROOF_SCOPED=$v: scoped $n did not start"
  done
  "${vc[@]}" -p -- sh -c "echo p >> $scratch/order; $hold $scratch/release-p; echo p-end >> $scratch/order" >/dev/null 2>"$scratch/pp.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(proof\) 1 of 1 waiting, behind:$' "$scratch/pp.err" || fail "PROOF_SCOPED=$v: the proof did not queue"
  for n in 1 2; do
    "${vc[@]}" -s -- sh -c "echo l$n >> $scratch/order; $hold $scratch/release-l" >/dev/null 2>"$scratch/pl$n.err" &
    pids+=("$!"); started+=("$!")
    until_true 10 has_line "^==> heavy-check: queued \\(scoped\\) $((n + 1)) of $((n + 1)) waiting, behind:\$" "$scratch/pl$n.err" ||
      fail "PROOF_SCOPED=$v: later scoped $n did not queue behind the proof: $(cat "$scratch/pl$n.err")"
  done
  touch "$scratch/release-s1"
  until_true 10 started_in_order s1-end || fail "PROOF_SCOPED=$v: scoped 1 did not end"
  not_started p || fail "PROOF_SCOPED=$v: the proof started beside two scoped checks"
  not_started l1 || fail "PROOF_SCOPED=$v: a later scoped check passed the queued proof"
  touch "$scratch/release-s2"
  if [ "$v" = 1 ]; then
    until_true 10 started_in_order p || fail 'PROOF_SCOPED=1: the proof did not start beside one scoped check'
    not_started l1 || fail 'PROOF_SCOPED=1: a later scoped check started beside the proof and its scoped check'
    touch "$scratch/release-s3"
    until_true 10 started_in_order l1 || fail 'PROOF_SCOPED=1: the next scoped check did not start beside the proof'
    not_started l2 || fail 'PROOF_SCOPED=1: two scoped checks ran beside the proof'
    touch "$scratch/release-p"
    until_true 10 started_in_order l2 || fail 'PROOF_SCOPED=1: the last scoped check did not start once the proof ended'
  else
    until_true 10 started_in_order s2-end || fail 'PROOF_SCOPED=0: scoped 2 did not end'
    not_started p || fail 'PROOF_SCOPED=0: the proof started beside a scoped check'
    touch "$scratch/release-s3"
    until_true 10 started_in_order p || fail 'PROOF_SCOPED=0: the proof did not start once the scoped checks ended'
    not_started l1 || fail 'PROOF_SCOPED=0: a scoped check started beside the proof'
    touch "$scratch/release-p"
    until_true 10 started_in_order l1 && until_true 10 started_in_order l2 || fail 'PROOF_SCOPED=0: the later scoped checks did not start once the proof ended'
  fi
  in_order p l1 || fail "PROOF_SCOPED=$v: a later scoped check started before the proof: $(tr '\n' ' ' < "$scratch/order")"
  in_order p l2 || fail "PROOF_SCOPED=$v: a later scoped check started before the proof: $(tr '\n' ' ' < "$scratch/order")"
  touch "$scratch/release-l"
  for n in "${pids[@]}"; do wait "$n"; done
}
t_proof_among_scoped() { proof_among_scoped 1; proof_among_scoped 0; }

# A second proof waits for the first, and an exclusive check waits for the
# proof and for the proof that queued before it.
proof_queue() {
  local v=$1 pids=() p
  variant "$v"
  rm -f "$scratch/order" "$scratch"/release-*
  "${vc[@]}" -p -- sh -c "echo a >> $scratch/order; $hold $scratch/release-a" >/dev/null 2>&1 &
  pids+=("$!"); started+=("$!")
  until_true 10 started_in_order a || fail "PROOF_SCOPED=$v: the first proof did not start"
  "${vc[@]}" -p -- sh -c "echo b >> $scratch/order; $hold $scratch/release-b" >/dev/null 2>"$scratch/pb.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(proof\) 1 of 1 waiting, behind:$' "$scratch/pb.err" || fail "PROOF_SCOPED=$v: the second proof did not queue"
  has_line '^==> heavy-check:   pid=[0-9]+ mode=proof ' "$scratch/pb.err" || fail "PROOF_SCOPED=$v: the second proof did not name the first"
  "${vc[@]}" -- sh -c "echo e >> $scratch/order" >/dev/null 2>"$scratch/pe.err" &
  pids+=("$!"); started+=("$!")
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\) 2 of 2 waiting, behind:$' "$scratch/pe.err" || fail "PROOF_SCOPED=$v: the exclusive check did not queue behind the proofs"
  not_started b || fail "PROOF_SCOPED=$v: two proofs ran together"
  touch "$scratch/release-a"
  until_true 10 started_in_order b || fail "PROOF_SCOPED=$v: the second proof did not start after the first"
  not_started e || fail "PROOF_SCOPED=$v: an exclusive check started beside a proof"
  touch "$scratch/release-b"
  for p in "${pids[@]}"; do wait "$p"; done
  [ "$(tr '\n' ' ' < "$scratch/order")" = 'a b e ' ] || fail "PROOF_SCOPED=$v: the order was $(tr '\n' ' ' < "$scratch/order")"
}
t_proof_queue() { proof_queue 1; proof_queue 0; }

# --- waiters outside the queue: a killed or stopped waiter holds back no one -----
lane_flag() { case $1 in exclusive) ;; proof) echo -p ;; scoped) echo -s ;; esac; }
t_waiters_skipped() {
  local lane flag h a b p
  for lane in exclusive proof scoped; do
    flag=$(lane_flag "$lane")
    rm -f "$scratch/order" "$scratch"/release-*
    "${hc[@]}" -- "$hold" "$scratch/release-h" >/dev/null 2>&1 &
    h=$!; started+=("$h")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    # A waiter killed outright leaves its ticket, which no longer counts.
    "${hc[@]}" $flag -- sh -c "echo killed >> $scratch/order" >/dev/null 2>"$scratch/wk.err" &
    a=$!; started+=("$a")
    until_true 10 has_line "^==> heavy-check: queued \\($lane\\)" "$scratch/wk.err" || fail "the $lane waiter did not queue"
    kill -KILL "$a"; wait "$a" 2>/dev/null || :
    "${hc[@]}" $flag -- sh -c "echo later >> $scratch/order" >/dev/null 2>"$scratch/wl.err" &
    b=$!; started+=("$b")
    until_true 10 has_line "^==> heavy-check: queued \\($lane\\) 1 of 1 waiting" "$scratch/wl.err" ||
      fail "a killed $lane waiter still counted ahead: $(cat "$scratch/wl.err")"
    touch "$scratch/release-h"
    wait "$h"; wait "$b"
    [ "$(cat "$scratch/order")" = later ] || fail "a killed $lane waiter held back a later one: $(tr '\n' ' ' < "$scratch/order")"
    # A stopped waiter: a later one passes it, and it runs once continued.
    rm -f "$scratch/order" "$scratch"/release-*
    "${hc[@]}" -- "$hold" "$scratch/release-h" >/dev/null 2>&1 &
    h=$!; started+=("$h")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    "${hc[@]}" $flag -- sh -c "echo stopped >> $scratch/order" >/dev/null 2>"$scratch/ws.err" &
    a=$!; started+=("$a")
    until_true 10 has_line "^==> heavy-check: queued \\($lane\\)" "$scratch/ws.err" || fail "the $lane waiter did not queue"
    for p in $(seq 50); do
      kill -STOP "$a"
      flock -n "$scratch/lock.queue" true && break
      kill -CONT "$a"; sleep 0.1
    done
    until_true 5 sh -c "sed 's/.*) //' /proc/$a/stat | grep -q '^T'" || fail "the $lane waiter was not stopped"
    "${hc[@]}" $flag -- sh -c "echo later >> $scratch/order" >/dev/null 2>"$scratch/wl.err" &
    b=$!; started+=("$b")
    until_true 10 has_line "^==> heavy-check: queued \\($lane\\) 1 of 1 waiting" "$scratch/wl.err" ||
      fail "a stopped $lane waiter still counted ahead: $(cat "$scratch/wl.err")"
    touch "$scratch/release-h"
    wait "$h"; wait "$b"
    [ "$(cat "$scratch/order")" = later ] || fail "a stopped $lane waiter held back a later one: $(tr '\n' ' ' < "$scratch/order")"
    kill -CONT "$a"; wait "$a"
    [ "$(tr '\n' ' ' < "$scratch/order")" = 'later stopped ' ] || fail "the continued $lane waiter did not run after: $(tr '\n' ' ' < "$scratch/order")"
  done
}

# --- the run record: the command's group and its watchdog ------------------------
t_run_record() {
  local lane flag file a line group watchdog
  for lane in exclusive proof scoped; do
    flag=$(lane_flag "$lane")
    case $lane in exclusive) file=lock.holder ;; proof) file=lock.proof.holder ;; scoped) file=lock.slot1.holder ;; esac
    rm -f "$scratch"/release-*
    "${hc[@]}" $flag -- sh -c "echo \$\$ > $scratch/rr.pid; $hold $scratch/release-rr" >/dev/null 2>&1 &
    a=$!; started+=("$a")
    until_true 10 test -s "$scratch/rr.pid" || fail "the $lane command did not start"
    until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/$file" || fail "the $lane record names no watchdog: $(cat "$scratch/$file" 2>/dev/null)"
    line=$(cat "$scratch/$file")
    group=$(sed -n 's/.* group=\([0-9]*\) .*/\1/p' <<<"$line")
    watchdog=$(sed -n 's/.* watchdog=\([0-9]*\) .*/\1/p' <<<"$line")
    [ "$group" = "$(cat "$scratch/rr.pid")" ] || fail "the $lane record's group is $group, not the command's $(cat "$scratch/rr.pid")"
    [ "$(ps -o pgid= -p "$(cat "$scratch/rr.pid")" | tr -d ' ')" = "$group" ] || fail "the $lane command does not lead the group its record names"
    alive "$watchdog" || fail "the $lane record's watchdog $watchdog is not running"
    tr '\0' ' ' < "/proc/$watchdog/cmdline" | grep -q '__contain_watchdog' || fail "the $lane record's watchdog $watchdog is not a watchdog"
    has_line "^pid=$a mode=$lane since=[0-9T:+-]+ hold=2700s group=$group watchdog=$watchdog checkout=$(pwd -P) command=sh -c " "$scratch/$file" ||
      fail "the $lane record is not in the documented form: $line"
    touch "$scratch/release-rr"; wait "$a"
    [ ! -e "$scratch/$file" ] || fail "a finished $lane run left its record"
    until_true 10 dead "$watchdog" || fail "the $lane watchdog outlived its run"
  done
}
# A command that ends while its watchdog lives, here a stopped one, leaves
# a run that is not finished: its record stays, its lane stays held and
# --status shows it held, until the watchdog exits.
t_record_watchdog() {
  local lane flag file lock a s line watchdog
  for lane in exclusive proof scoped; do
    flag=$(lane_flag "$lane")
    case $lane in
      exclusive) file=lock.holder lock=lock ;;
      proof) file=lock.proof.holder lock=lock.proof ;;
      scoped) file=lock.slot1.holder lock=lock.slot1 ;;
    esac
    rm -f "$scratch"/release-*
    "${hc[@]}" $flag -- "$hold" "$scratch/release-rw" >/dev/null 2>"$scratch/rw.err" &
    a=$!; started+=("$a")
    until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/$file" || fail "the $lane record names no watchdog: $(cat "$scratch/$file" 2>/dev/null)"
    line=$(cat "$scratch/$file")
    watchdog=$(sed -n 's/.* watchdog=\([0-9]*\) .*/\1/p' <<<"$line")
    kill -STOP "$watchdog"
    touch "$scratch/release-rw"
    s=0; wait "$a" || s=$?
    [ "$s" = 0 ] || { kill -CONT "$watchdog"; fail "the $lane check exited $s"; }
    [ "$(cat "$scratch/$file" 2>/dev/null)" = "$line" ] || { kill -CONT "$watchdog"; fail "the $lane record went while its watchdog lived"; }
    flock -n "$scratch/$lock" true && { kill -CONT "$watchdog"; fail "the $lane lane was free while its watchdog lived"; }
    "${hc[@]}" --status >"$scratch/rw.status" 2>&1
    has_line "^held $lane pid=$a " "$scratch/rw.status" || { kill -CONT "$watchdog"; fail "--status with the $lane watchdog alive: $(cat "$scratch/rw.status")"; }
    kill -CONT "$watchdog"
    until_true 10 dead "$watchdog" || fail "the $lane watchdog did not exit once continued"
    [ "$(status_of "${hc[@]}" --status)" = 0 ] && [ "$(cat "$scratch/out")" = idle ] || fail "the host was not idle once the $lane watchdog exited: $(cat "$scratch/out")"
    forget_killed
  done
}

# --- the environment ---------------------------------------------------------------
t_environment() {
  local p seed share
  # A caller's prefix passes unchanged.
  PROOF_RUN_PREFIX=mine- "${hc[@]}" -s -- sh -c 'echo "$PROOF_RUN_PREFIX"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = mine- ] || fail "a caller's PROOF_RUN_PREFIX became $(body "$scratch/out")"
  # An absent one becomes the caller's worktree's prefix, with this check's pid.
  . "$root/scripts/lib/run-names.sh"
  seed=$(run_names_seed "$root")
  (cd "$root" && "${hc[@]}" -s -- sh -c 'echo "$PROOF_RUN_PREFIX"') >"$scratch/out" 2>/dev/null
  p=$(sed -n 's/^_START=//p' "$scratch/out")
  [ "$(body "$scratch/out")" = "cyfr-$seed-$p-" ] || fail "the injected prefix is $(body "$scratch/out"), not cyfr-$seed-$p-"
  [[ "$(body "$scratch/out")" =~ $RUN_NAMES_PATTERN ]] || fail 'the injected prefix does not match RUN_NAMES_PATTERN'
  # Outside a worktree, the checkout the script lives in names it.
  (cd "$scratch" && "${hc[@]}" -- sh -c 'echo "$PROOF_RUN_PREFIX"') >"$scratch/out" 2>/dev/null
  p=$(sed -n 's/^_START=//p' "$scratch/out")
  [ "$(body "$scratch/out")" = "cyfr-$seed-$p-" ] || fail "outside a worktree the prefix is $(body "$scratch/out"), not the script's checkout's"
  # A caller's ERL_FLAGS keeps its words, the slot's +S after them.
  ERL_FLAGS='+sbwt none -kernel inet_dist_use_interface {127,0,0,1}' "${hc[@]}" -s -- sh -c 'echo "$ERL_FLAGS|$CYFR_TEST_CORES|$CARGO_BUILD_JOBS"' >"$scratch/out" 2>/dev/null
  share=$(body "$scratch/out" | cut -d'|' -f2)
  case $share in ''|*[!0-9]*) fail "no share: $(body "$scratch/out")" ;; esac
  [ "$(body "$scratch/out")" = "+sbwt none -kernel inet_dist_use_interface {127,0,0,1} +S $share:$share|$share|$share" ] ||
    fail "the scoped environment was $(body "$scratch/out")"
  "${hc[@]}" -p -- sh -c 'echo "${ERL_FLAGS-unset}|${CYFR_TEST_CORES-unset}|${CARGO_BUILD_JOBS-unset}"' >"$scratch/out" 2>/dev/null
  [ "$(body "$scratch/out")" = 'unset|unset|unset' ] || fail "a proof was given a share of the cores: $(body "$scratch/out")"
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
  printf 'pid=%s mode=proof since=2026-10-28T21:02:41+0000 hold=3600s group= watchdog= checkout=/nowhere command=gone\n' "$gone" > "$scratch/lock.proof.holder"
  "${hc[@]}" -- "$hold" "$scratch/release-st" >/dev/null 2>&1 &
  a=$!; started+=("$a")
  until_true 10 has_line ' watchdog=[0-9]+ ' "$scratch/lock.holder" || fail 'the holder did not start'
  "${hc[@]}" -s -- true >/dev/null 2>"$scratch/stw.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/stw.err" || fail 'the waiter did not queue'
  [ "$(status_of "${hc[@]}" --status)" = 0 ] || fail '--status failed'
  [ "$(wc -l < "$scratch/out" | tr -d ' ')" = 2 ] || fail "--status did not print one holder and one waiter: $(cat "$scratch/out")"
  has_line "^held exclusive pid=$a since=[0-9T:+-]+ elapsed=[0-9]+s hold=2700s checkout=$(pwd -P) command=$hold $scratch/release-st\$" <(sed -n 1p "$scratch/out") ||
    fail "the holder line: $(sed -n 1p "$scratch/out")"
  has_line "^waiting 1 scoped pid=$b queued=[0-9T:+-]+ waited=[0-9]+s checkout=$(pwd -P) command=true\$" <(sed -n 2p "$scratch/out") ||
    fail "the waiter line: $(sed -n 2p "$scratch/out")"
  if grep -q "pid=$gone" "$scratch/out"; then fail 'a dead holder was shown'; fi
  touch "$scratch/release-st"; wait "$a"; wait "$b"
  rm -f "$scratch/lock.proof.holder"
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
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\) 1 of 1 waiting, behind:$' "$scratch/qa.err" || fail 'the first waiter did not queue'
  # Its output and its queued lines in one file, as a task's output is kept.
  HEAVY_CHECK_REPEAT=1 "${hc[@]}" -s -- true >"$scratch/qb.out" 2>&1 &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(scoped\) 2 of 2 waiting, behind:$' "$scratch/qb.out" || fail 'the second waiter did not say its place'
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\) 1 of 2 waiting, behind:$' "$scratch/qa.err" || fail 'the first waiter did not repeat its place'
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

# --- the proof lane's deadline and signals while queued --------------------------
t_queue_proof() {
  local q p s=0
  "${hc[@]}" -p -- "$hold" "$scratch/release-qp" >/dev/null 2>&1 &
  q=$!; started+=("$q")
  until_true 10 test -s "$scratch/lock.proof.holder" || fail 'the proof did not start'
  "${hc[@]}" -p -w 1 -- touch "$scratch/ran-anyway" >"$scratch/out" 2>"$scratch/err" &
  p=$!; started+=("$p")
  wait "$p" || s=$?
  [ "$s" = 75 ] || fail "a proof that never got its lane exited $s"
  [ ! -e "$scratch/ran-anyway" ] || fail 'a proof ran past its queue deadline'
  has_line '^==> heavy-check: queue deadline after ' "$scratch/err" || fail 'the queue deadline was not reported'
  has_line '^==> heavy-check:   still held by pid=[0-9]+ mode=proof ' "$scratch/err" || fail 'the deadline did not name the holder'
  framed "$scratch/out" 75 "$p" || fail "the queue path was not framed by pid $p"
  touch "$scratch/release-qp"; wait "$q"
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

# --- stopping a queued check: the wait for the host does not defer it ----------
# signal_queued MODE SIGNAL STATUS [LAUNCHER...]
signal_queued() {
  local mode=$1 sig=$2 want=$3 i q s=0 holders=() n; shift 3
  if [ "$mode" = proof ]; then
    "${hc[@]}" -p -- "$hold" "$scratch/release-sq" >/dev/null 2>&1 &
    holders+=("$!"); started+=("$!")
    until_true 10 test -s "$scratch/lock.proof.holder" || fail 'the proof holder did not start'
    set -- "$@" "${hc[@]}" -p
  elif [ "$mode" = scoped ]; then
    for n in 1 2 3; do
      "${hc[@]}" -s -- sh -c "touch $scratch/sq$n.started; $hold $scratch/release-sq" >/dev/null 2>&1 &
      holders+=("$!"); started+=("$!")
      until_true 10 test -e "$scratch/sq$n.started" || fail "scoped holder $n did not start"
    done
    set -- "$@" "${hc[@]}" -s
  else
    "${hc[@]}" -- "$hold" "$scratch/release-sq" >/dev/null 2>&1 &
    holders+=("$!"); started+=("$!")
    until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
    set -- "$@" "${hc[@]}"
  fi
  "$@" -- touch "$scratch/queued-ran" >"$scratch/q.out" 2>"$scratch/q.err" &
  q=$!; started+=("$q")
  until_true 10 has_line "^==> heavy-check: queued \\($mode\\)" "$scratch/q.err" || fail 'the check did not queue'
  [ "$(head -n 1 "$scratch/q.out")" = "_START=$q" ] || fail 'a queued check had not written its start line'
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
t_term_queued() { signal_queued exclusive TERM 143; }
t_int_queued() { signal_queued exclusive INT 130 "${with_int[@]}"; }
t_hup_queued() { signal_queued exclusive HUP 129 "${with_hup[@]}"; }
t_term_queued_scoped() { signal_queued scoped TERM 143; }
t_term_queued_proof() { signal_queued proof TERM 143; }
t_int_queued_proof() { signal_queued proof INT 130 "${with_int[@]}"; }
t_hup_queued_proof() { signal_queued proof HUP 129 "${with_hup[@]}"; }

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
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\)' "$scratch/k2.err" || fail 'the next check did not queue'
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
  cp "$root/scripts/lib/run-names.sh" "$scratch/stub/lib/"
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
  has_line "^pid=[0-9]+ mode=exclusive " "$scratch/lock.holder" || fail 'a run whose survivor outlived KILL removed its record'
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
  printf '%s\n' "_START=$$" '==> heavy-check: queued (exclusive) behind:' > "$scratch/task"
  (sleep 3; printf '%s\n' '==> heavy-check: running (exclusive) after 3s queued: x' '' "_EXIT=$$ 0" >> "$scratch/task") &
  w=$!; started+=("$w")
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 1)" = 0 ] || fail 'the run deadline ran out while the check was queued'
  wait "$w"
  printf '%s\n' "_START=$$" '==> heavy-check: queued (exclusive) behind:' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 AWAIT_QUEUE_SECONDS=2 await "$scratch/task" '' 600)" = 2 ] || fail 'a check that never left the queue was awaited past the queue deadline'
  has_line '^QUEUE DEADLINE after 2s' "$scratch/err" || fail 'the queue deadline was not named'
  printf '%s\n' "_START=$$" '==> heavy-check: queued (exclusive) behind:' '==> heavy-check: running (exclusive) after 9s queued: x' > "$scratch/task"
  [ "$(AWAIT_POLL_SECONDS=1 await "$scratch/task" '' 2)" = 2 ] || fail 'a running check was awaited past its deadline'
  has_line '^DEADLINE after 2s' "$scratch/err" || fail 'the run deadline was not named'
}

cases=(
  usage admission nested result frame roster fds fd_base elsewhere
  exclusive redaction killed_holder scoped scoped_order scoped_stale scoped_stopped queue_lock
  expired_waiter admission_stopped admission_undo admission_stall precedence
  proof_among_scoped proof_queue waiters_skipped run_record record_watchdog environment status queued_repeat queue_proof
  hold hold_frame queue term int hup usr1 term_queued int_queued hup_queued term_queued_scoped
  term_queued_proof int_queued_proof hup_queued_proof refusals
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
  # Every case leaves the host free, and no record or registry behind.
  host_free || fail 'the scratch lock was still held after the case'
  [ ! -e "$scratch/lock.holder" ] || fail 'a holder record was left'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.slot*.holder')" ] || fail 'a scoped holder record was left'
  [ ! -e "$scratch/lock.proof.holder" ] || fail 'a proof holder record was left'
  [ "$(registries)" = 0 ] || fail 'a registry was left'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'a scoped ticket was left'
done
echo 'heavy check tests passed'
