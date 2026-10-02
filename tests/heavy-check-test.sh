#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# scripts/heavy-check.sh, the queue-aware wait of scripts/await-task.sh and
# the step deadlines of scripts/commit-gate.sh, against commands that stand
# in for checks.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
check="$root/scripts/heavy-check.sh"
await="$root/scripts/await-task.sh"
gate="$root/scripts/commit-gate.sh"
scratch=$(mktemp -d /tmp/cyfr-heavy-test.XXXXXX)
started=()
# A check is asked to stop, so it stops its command, before anything is
# ended outright.
cleanup() {
  local pid
  for pid in ${started[@]+"${started[@]}"}; do kill -TERM "$pid" 2>/dev/null || :; done
  sleep 0.5
  for pid in ${started[@]+"${started[@]}"}; do kill -KILL "$pid" 2>/dev/null || :; done
  rm -rf "$scratch"
}
trap cleanup EXIT
# Holds until its release file appears, and never past a minute or past the
# scratch directory, so a failed run leaves nothing waiting.
cat > "$scratch/hold" <<'HOLD'
#!/bin/sh
n=0
until [ -e "$1" ] || [ ! -d "$(dirname "$1")" ] || [ "$n" -ge 600 ]; do sleep 0.1; n=$((n + 1)); done
HOLD
chmod +x "$scratch/hold"
hold="$scratch/hold"
export HEAVY_CHECK_LOCK="$scratch/lock" HEAVY_CHECK_GRACE=1
unset HEAVY_CHECK_HELD CYFR_TEST_CORES GATE_STEP_DEADLINE
fail() { echo "FAIL: $*" >&2; exit 1; }
# A bounded wait on an observable condition: `until_true 10 test -e file`.
until_true() {
  local limit=$(( $1 * 10 )) n=0; shift
  until "$@" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
dead() { ! kill -0 "$1" 2>/dev/null; }
status_of() { local s=0; "$@" >"$scratch/out" 2>"$scratch/err" || s=$?; echo "$s"; }
has_line() { grep -qE -- "$1" "$2"; }

# --- usage ---------------------------------------------------------------
[ "$(status_of bash "$check")" = 64 ] || fail 'ran with no command'
[ "$(status_of bash "$check" -t 0 -- true)" = 64 ] || fail 'accepted a zero hold'
[ "$(status_of bash "$check" -w soon -- true)" = 64 ] || fail 'accepted a non-numeric queue deadline'
[ "$(status_of bash "$check" -x -- true)" = 64 ] || fail 'accepted an unknown option'
[ "$(status_of bash "$check" -s -- scripts/commit-gate.sh)" = 64 ] || fail 'ran the gate as a scoped check'
[ "$(status_of bash "$check" -s -- true scripts/test-partitioned.sh -n 4 -a sqlite)" = 64 ] || fail 'ran four partitions as a scoped check'
[ "$(status_of bash "$check" -s -- true scripts/test-partitioned.sh -a sqlite apps/x)" = 64 ] || fail 'ran the default partition count as a scoped check'
[ "$(status_of bash "$check" -s -- true scripts/test-partitioned.sh)" = 64 ] || fail 'ran the bare runner as a scoped check'
[ "$(status_of bash "$check" -s -- true scripts/test-partitioned.sh -n 1 -a sqlite apps/x)" = 0 ] || fail 'refused a one-partition scoped run'
[ "$(status_of bash "$check" -s -- head -n 4 /dev/null)" = 0 ] || fail "read another command's -n as a partition count"

# --- the command's own result ---------------------------------------------
[ "$(status_of bash "$check" -- sh -c 'echo said; exit 7')" = 7 ] || fail "lost the command's status"
[ "$(cat "$scratch/out")" = said ] || fail "lost the command's output"
has_line '^==> heavy-check: running \(exclusive\) after [0-9]+s queued' "$scratch/err" || fail 'did not say it started'
has_line '^==> heavy-check: exit 7 after ' "$scratch/err" || fail 'did not say how it ended'
[ ! -e "$scratch/lock.holder" ] || fail 'left its holder record'
bash "$check" -- sh -c 'echo "$HEAVY_CHECK_HELD ${CYFR_TEST_CORES:-whole}"' >"$scratch/out" 2>/dev/null
[ "$(cat "$scratch/out")" = 'exclusive whole' ] || fail 'an exclusive check was given a share of the cores'
bash "$check" -s -- sh -c 'echo "$HEAVY_CHECK_HELD ${CYFR_TEST_CORES:-whole}"' >"$scratch/out" 2>/dev/null
case "$(cat "$scratch/out")" in 'scoped '[1-9]*) ;; *) fail 'a scoped check was not given its share of the cores' ;; esac
# The server refuses a CYFR_ name it does not declare: the names a check
# adds to its command's environment stay outside the prefix or inside the
# test harness's part of it.
env | sed 's/=.*//' > "$scratch/env-before"
bash "$check" -s -- env 2>/dev/null | sed 's/=.*//' > "$scratch/env-inside"
added=$(grep -vxF -f "$scratch/env-before" "$scratch/env-inside" | LC_ALL=C sort | tr '\n' ' ')
[ "$added" = 'CYFR_TEST_CORES HEAVY_CHECK_HELD ' ] || fail "a check added these names to its command's environment: $added"

# --- one exclusive check at a time -----------------------------------------
bash "$check" -- sh -c "echo a-start >> $scratch/order; $hold $scratch/release-a; echo a-end >> $scratch/order" 2>"$scratch/a.err" &
a=$!; started+=("$a")
until_true 10 test -s "$scratch/lock.holder" || fail 'the holder left no record'
bash "$check" -- sh -c "echo b >> $scratch/order" 2>"$scratch/b.err" &
b=$!; started+=("$b")
until_true 10 has_line '^==> heavy-check: queued \(exclusive\) behind:' "$scratch/b.err" || fail 'a queued check did not say so'
has_line "^==> heavy-check:   pid=$a mode=exclusive since=.* hold=2700s command=sh -c " "$scratch/b.err" || fail 'a queued check did not name the holder'
[ "$(cat "$scratch/order")" = a-start ] || fail 'a second exclusive check ran beside the first'
touch "$scratch/release-a"; wait "$a"; wait "$b"
[ "$(tr '\n' ' ' < "$scratch/order")" = 'a-start a-end b ' ] || fail "exclusive checks overlapped: $(tr '\n' ' ' < "$scratch/order")"
has_line '^==> heavy-check: running \(exclusive\) after ' "$scratch/b.err" || fail 'the queued check did not say when it started'

# --- a caller that takes the lock file with flock directly ------------------
flock "$scratch/lock" "$hold" "$scratch/release-f" &
f=$!; started+=("$f")
until_true 10 sh -c "! flock -n '$scratch/lock' true" || fail 'the direct flock never took the lock'
bash "$check" -- touch "$scratch/after-flock" 2>"$scratch/f.err" &
c=$!; started+=("$c")
until_true 10 has_line 'behind a holder that left no record' "$scratch/f.err" || fail 'did not queue behind a direct flock'
[ ! -e "$scratch/after-flock" ] || fail 'ran beside a direct flock'
touch "$scratch/release-f"; wait "$f"; wait "$c"
[ -e "$scratch/after-flock" ] || fail 'did not run after the direct flock ended'

# --- scoped runs: three side by side, the fourth waits ----------------------
rm -f "$scratch"/release-*
for i in 1 2 3 4; do
  bash "$check" -s -- sh -c "touch $scratch/s$i.started; $hold $scratch/release-s" 2>"$scratch/s$i.err" &
  started+=("$!")
  [ "$i" = 4 ] || until_true 10 test -e "$scratch/s$i.started" || fail "scoped run $i did not start beside the others"
done
until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/s4.err" || fail 'a fourth scoped run was not queued'
[ ! -e "$scratch/s4.started" ] || fail 'a fourth scoped run started'
touch "$scratch/release-s"
until_true 10 test -e "$scratch/s4.started" || fail 'the fourth scoped run never started'
wait

# --- scoped and exclusive never together; a queued exclusive goes first -----
rm -f "$scratch"/release-* "$scratch/order"
bash "$check" -s -- sh -c "echo s1 >> $scratch/order; $hold $scratch/release-1" 2>/dev/null &
started+=("$!")
until_true 10 has_line '^s1$' "$scratch/order" || fail 'the scoped run did not start'
bash "$check" -- sh -c "echo e >> $scratch/order; $hold $scratch/release-2" 2>"$scratch/e.err" &
started+=("$!")
until_true 10 has_line '^==> heavy-check: queued \(exclusive\)' "$scratch/e.err" || fail 'an exclusive check did not queue behind a scoped run'
bash "$check" -s -- sh -c "echo s2 >> $scratch/order" 2>"$scratch/s2.err" &
started+=("$!")
until_true 10 has_line '^==> heavy-check: queued \(scoped\)' "$scratch/s2.err" || fail 'a later scoped run did not queue behind the exclusive check'
[ "$(cat "$scratch/order")" = s1 ] || fail 'an exclusive check or a later scoped run started beside a scoped one'
touch "$scratch/release-1"
until_true 10 has_line '^e$' "$scratch/order" || fail 'the exclusive check never started'
sleep 0.5
[ "$(tr '\n' ' ' < "$scratch/order")" = 's1 e ' ] || fail "a scoped run started beside the exclusive check: $(tr '\n' ' ' < "$scratch/order")"
touch "$scratch/release-2"; wait
[ "$(tr '\n' ' ' < "$scratch/order")" = 's1 e s2 ' ] || fail 'the queued exclusive check did not go first'

# --- the hold deadline -------------------------------------------------------
[ "$(status_of bash "$check" -t 1 -- sh -c "sleep 120 & echo \$! > $scratch/held; wait")" = 124 ] || fail 'a check past its hold was not stopped with 124'
has_line '^==> heavy-check: hold deadline after 1s' "$scratch/err" || fail 'the hold deadline was not reported'
until_true 5 dead "$(cat "$scratch/held")" || fail "a stopped check's child survived"
[ "$(status_of bash "$check" -t 1 -- sh -c "trap '' TERM; echo \$\$ > $scratch/stubborn; while :; do sleep 1; done")" = 124 ] || fail 'a check that ignores TERM was not stopped'
until_true 5 dead "$(cat "$scratch/stubborn")" || fail 'a check that ignores TERM survived its grace'
if command -v setsid >/dev/null 2>&1 && command -v pkill >/dev/null 2>&1; then
  [ "$(status_of bash "$check" -t 1 -- bash -c "set -m; sleep 120 & echo \$! > $scratch/grouped; wait")" = 124 ] || fail 'a check with a group of its own was not stopped'
  until_true 5 dead "$(cat "$scratch/grouped")" || fail 'a process in a group of its own survived the deadline'
fi
[ "$(status_of bash "$check" -w 1 -- true)" = 0 ] || fail 'the host was not free after a stopped check'

# --- the queue deadline ------------------------------------------------------
rm -f "$scratch"/release-*
bash "$check" -- "$hold" "$scratch/release-q" 2>/dev/null &
q=$!; started+=("$q")
until_true 10 test -s "$scratch/lock.holder" || fail 'the holder did not start'
[ "$(status_of bash "$check" -w 1 -- touch "$scratch/ran-anyway")" = 75 ] || fail 'a check that never got the host did not exit 75'
[ ! -e "$scratch/ran-anyway" ] || fail 'a check ran past its queue deadline'
has_line '^==> heavy-check: queue deadline after ' "$scratch/err" || fail 'the queue deadline was not reported'
[ -s "$scratch/lock.holder" ] || fail "a check that gave up removed the holder's record"
touch "$scratch/release-q"; wait "$q"

# --- stopping the check stops its command and frees the host ----------------
bash "$check" -- sh -c "sleep 120 & echo \$! > $scratch/interrupted; wait" 2>/dev/null &
i=$!; started+=("$i")
until_true 10 test -s "$scratch/interrupted" || fail 'the check to interrupt did not start'
kill -TERM "$i"
s=0; wait "$i" || s=$?
[ "$s" = 143 ] || fail "an interrupted check exited $s"
until_true 5 dead "$(cat "$scratch/interrupted")" || fail "an interrupted check's child survived"
[ ! -e "$scratch/lock.holder" ] || fail 'an interrupted check left its holder record'
[ "$(status_of bash "$check" -w 1 -- true)" = 0 ] || fail 'the host was not free after an interrupted check'

# --- what a command leaves behind cannot keep the host ----------------------
bash "$check" -- sh -c "sleep 30 >/dev/null 2>&1 & echo \$! > $scratch/orphan" 2>/dev/null
[ "$(status_of bash "$check" -w 1 -- true)" = 0 ] || fail "a command's leftover process kept the host"
kill "$(cat "$scratch/orphan")" 2>/dev/null || :

# --- a check inside a check ---------------------------------------------------
[ "$(status_of bash "$check" -- bash "$check" -- sh -c 'exit 5')" = 5 ] || fail 'a nested check did not run under its parent'
[ "$(status_of bash "$check" -s -- bash "$check" -s -- true)" = 0 ] || fail 'a scoped check inside a scoped check did not run'
[ "$(status_of bash "$check" -s -- bash "$check" -- true)" = 64 ] || fail 'an exclusive check started inside a scoped one'

# --- await-task.sh: the run deadline does not count the queue ---------------
export AWAIT_POLL_SECONDS=1
printf '%s\n' '==> heavy-check: queued (exclusive) behind:' > "$scratch/task"
(sleep 3; printf '%s\n' '==> heavy-check: running (exclusive) after 3s queued: x' '_EXIT=0' >> "$scratch/task") &
started+=("$!")
[ "$(status_of bash "$await" "$scratch/task" '_EXIT=[0-9]+' 1)" = 0 ] || fail 'the run deadline ran out while the check was queued'
printf '%s\n' '==> heavy-check: queued (exclusive) behind:' > "$scratch/task"
[ "$(AWAIT_QUEUE_SECONDS=2 status_of bash "$await" "$scratch/task" '_EXIT=[0-9]+' 600)" = 2 ] || fail 'a check that never left the queue was awaited past the queue deadline'
has_line '^QUEUE DEADLINE after 2s' "$scratch/err" || fail 'the queue deadline was not named'
printf '%s\n' '==> heavy-check: queued (exclusive) behind:' '==> heavy-check: running (exclusive) after 9s queued: x' > "$scratch/task"
[ "$(status_of bash "$await" "$scratch/task" '_EXIT=[0-9]+' 2)" = 2 ] || fail 'a running check was awaited past its deadline'
has_line '^DEADLINE after 2s' "$scratch/err" || fail 'the run deadline was not named'
printf '%s\n' 'no result yet' '[exited with code 75]' > "$scratch/task"
[ "$(status_of bash "$await" "$scratch/task" '_EXIT=[0-9]+' 600)" = 1 ] || fail 'a check that gave up its queue was not reported dead'

# --- commit-gate.sh: a stalled step ends at its deadline ---------------------
[ "$(GATE_STEP_DEADLINE=0 status_of bash "$gate" -l "$scratch/refused")" = 64 ] || fail 'the gate accepted a zero step deadline'
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  mkdir -p "$scratch/bin" "$scratch/trace"
  cat > "$scratch/bin/mix" <<'FAKE'
#!/usr/bin/env bash
# Stands in for Mix: every step passes at once, except the arca island's
# tests, which wait as a stalled build would.
case "$1" in
  run)
    case "${!#}" in
      create) cat "$CYFR_TEST_RUN_ROOT/database-name" > "$CYFR_TEST_RUN_ROOT/database-created" ;;
      drop) rm "$CYFR_TEST_RUN_ROOT/database-created" ;;
    esac ;;
  test)
    case "$PWD" in
      */island_arca.*/apps/arca) echo "$$" > "$TRACE/stalled"; exec sleep 120 ;;
    esac
    echo 'Result: 1 passed' ;;
esac
case "$PWD" in
  */island_*) [ "${MIX_OS_CONCURRENCY_LOCK:-}" = 0 ] || echo "$PWD $1" >> "$TRACE/island-with-build-lock" ;;
esac
exit 0
FAKE
  chmod +x "$scratch/bin/mix"
  s=0
  (cd "$root" && TRACE="$scratch/trace" PATH="$scratch/bin:$PATH" GATE_STEP_DEADLINE=20 \
    CYFR_DATABASE_URL='postgres://u:p@host/base' bash "$gate" -l "$scratch/gate") >"$scratch/gate.out" 2>"$scratch/gate.err" || s=$?
  [ "$s" = 1 ] || fail "a gate with a stalled island exited $s"
  has_line '^_EXIT=1$' "$scratch/gate.out" || fail 'the gate did not print its exit line'
  has_line '^arca=124$' "$scratch/gate/islands.summary" || fail "the stalled island was not recorded at its deadline: $(tr '\n' ' ' < "$scratch/gate/islands.summary")"
  has_line '^prima=0$' "$scratch/gate/islands.summary" || fail 'the prima island did not pass beside the stalled one'
  has_line '^sanctum=0$' "$scratch/gate/islands.summary" || fail 'the sanctum island did not pass beside the stalled one'
  has_line '^==> islands.arca stopped at its deadline$' "$scratch/gate.err" || fail 'the stalled island was not reported'
  has_line '^sqlite_suite=0$' "$scratch/gate/static.summary" || fail "the bounded SQLite suite did not pass: $(tr '\n' ' ' < "$scratch/gate/static.summary")"
  has_line '^pg_tests=0$' "$scratch/gate/postgres.summary" || fail "the bounded PostgreSQL tests did not pass: $(tr '\n' ' ' < "$scratch/gate/postgres.summary")"
  has_line '^==> islands +FAILED ' "$scratch/gate.out" || fail 'the islands leg was not reported failed'
  has_line '^==> static +ok ' "$scratch/gate.out" || fail 'the static leg was not reported passed'
  dead "$(cat "$scratch/trace/stalled")" || fail 'the stalled step survived its deadline'
  [ -z "$(find "$scratch/gate" -maxdepth 1 -name 'island_*')" ] || fail "the stalled island's copy was left behind"
  [ ! -e "$scratch/trace/island-with-build-lock" ] || fail "an island's Mix ran with its build lock on: $(tr '\n' ' ' < "$scratch/trace/island-with-build-lock")"
else
  echo 'SKIPPED: the gate deadline test needs timeout(1)'
fi
echo 'heavy check tests passed'
