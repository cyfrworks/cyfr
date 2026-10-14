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
  for pid in ${started[@]+"${started[@]}"}; do ours "$pid" && kill -TERM "$pid" 2>/dev/null || :; done
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
# A check killed outright leaves its registry file and, when it had the
# host, its holder record, which names a dead pid and so is never shown;
# nothing else.
forget_killed() {
  local pid
  find "$TMPDIR" -maxdepth 1 -name 'contain-registry.*' -delete
  if [ -e "$scratch/lock.holder" ]; then
    pid=$(sed -n 's/^pid=\([0-9]*\) .*/\1/p' "$scratch/lock.holder")
    dead "$pid" || fail "a holder record names a live check: $(cat "$scratch/lock.holder")"
    rm -f "$scratch/lock.holder"
  fi
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
  [ "$added" = 'CONTAIN_REGISTRY CYFR_TEST_CORES HEAVY_CHECK_HELD ' ] || fail "a scoped check added: $added"
  "${hc[@]}" -- env 2>/dev/null > "$scratch/env-raw"
  body "$scratch/env-raw" | sed 's/=.*//' > "$scratch/env-inside"
  added=$(grep -vxF -f "$scratch/env-before" "$scratch/env-inside" | LC_ALL=C sort | tr '\n' ' ')
  [ "$added" = 'CONTAIN_REGISTRY HEAVY_CHECK_HELD ' ] || fail "an exclusive check added: $added"
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
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\) behind:' "$scratch/b.err" || fail 'a queued check did not say so'
  has_line "^==> heavy-check:   pid=$a mode=exclusive since=.* hold=2700s command=sh -c " "$scratch/b.err" || fail 'a queued check did not name the holder'
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
    --url=postgres://u:secret2@h/db https://secret3@h/x >/dev/null 2>"$scratch/r1.err" &
  a=$!; started+=("$a")
  until_true 10 test -s "$scratch/lock.holder" || fail 'the holder left no record'
  ! grep -q secret "$scratch/lock.holder" || fail "the holder's record carries the value: $(cat "$scratch/lock.holder")"
  has_line '^pid=[0-9]+ .* command=env CYFR_DATABASE_URL=… .* --url=postgres://\[redacted\]@h/db https://\[redacted\]@h/x$' "$scratch/lock.holder" ||
    fail "the record lost the name or the URLs' shape: $(cat "$scratch/lock.holder")"
  "${hc[@]}" -- true >/dev/null 2>"$scratch/r2.err" &
  b=$!; started+=("$b")
  until_true 10 has_line '^==> heavy-check: queued \(exclusive\) behind:' "$scratch/r2.err" || fail 'the second check did not queue'
  has_line '^==> heavy-check:   pid=[0-9]+ .*command=env CYFR_DATABASE_URL=… .* --url=postgres://\[redacted\]@h/db ' "$scratch/r2.err" || fail 'the queued check did not name the holder'
  touch "$scratch/release-r"; wait "$a"; wait "$b"
  ! grep -q secret "$scratch/r1.err" "$scratch/r2.err" || fail "the value reached a check's stderr"
}

# --- a caller that takes the lock file with flock directly -------------------
t_flock_direct() {
  local f c
  flock "$scratch/lock" "$hold" "$scratch/release-f" &
  f=$!; started+=("$f")
  until_true 10 sh -c "! flock -n '$scratch/lock' true" || fail 'the direct flock never took the lock'
  "${hc[@]}" -- touch "$scratch/after-flock" >/dev/null 2>"$scratch/f.err" &
  c=$!; started+=("$c")
  until_true 10 has_line 'behind a holder that left no record' "$scratch/f.err" || fail 'did not queue behind a direct flock'
  [ ! -e "$scratch/after-flock" ] || fail 'ran beside a direct flock'
  touch "$scratch/release-f"; wait "$f"; wait "$c"
  [ -e "$scratch/after-flock" ] || fail 'did not run after the direct flock ended'
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
  if [ "$mode" = scoped ]; then
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
  cat > "$scratch/stub/lib/contain.sh" <<'STUB'
CONTAIN_SURVIVORS=
contain_registry_create() { CONTAIN_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/contain-registry.XXXXXX"); export CONTAIN_REGISTRY; }
contain_start() { [ "$1" != -g ] || shift 2; "$@" & CONTAIN_PID=$!; }
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
  kill "$v"; wait "$v" 2>/dev/null || :
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
  exclusive redaction flock_direct scoped scoped_order scoped_stale precedence
  hold hold_frame queue term int hup usr1 term_queued int_queued hup_queued term_queued_scoped refusals
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
  [ "$(registries)" = 0 ] || fail 'a registry was left'
  [ -z "$(find "$scratch" -maxdepth 1 -name 'lock.wait.*')" ] || fail 'a scoped ticket was left'
done
echo 'heavy check tests passed'
