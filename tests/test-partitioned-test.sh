#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runner="$root/scripts/test-partitioned.sh"
scratch=$(mktemp -d /tmp/cyfr-runner-test.XXXXXX)
real_elixir=$(command -v elixir)
export REAL_ELIXIR="$real_elixir"
cleanup() {
  if [ -f "$scratch/trace/prepared" ]; then
    while IFS= read -r directory; do
      case "$directory" in /tmp/cyfr-t.*|/private/tmp/cyfr-t.*) rm -rf "$directory" ;; esac
    done < "$scratch/trace/prepared"
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/bin" "$scratch/tmp" "$scratch/trace"
export TMPDIR="$scratch/tmp" TRACE="$scratch/trace"
export PATH="$scratch/bin:$PATH"
export ERL_FLAGS='+S 2:2 +SDcpu 2 +SDio 2'
cat > "$scratch/bin/mix" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$1 ${!#}" >> "$TRACE/mix-calls"
[ "${MIX_OS_CONCURRENCY_LOCK:-}" = 0 ] || printf '%s\n' "$1 ${!#}" >> "$TRACE/mix-calls-with-build-lock"
case "$1" in
  compile)
    case "${CORRUPT_AFTER_COMPILE:-}" in
      missing) rm "$(dirname "$CYFR_TEST_RUN_ROOT")/p1.env" ;;
      empty) : > "$(dirname "$CYFR_TEST_RUN_ROOT")/p1.env" ;;
      source) printf '\nreturn 1\n' >> "$(dirname "$CYFR_TEST_RUN_ROOT")/p1.env" ;;
    esac
    exit 0 ;;
  run)
    case "${!#}" in
      create)
        [ "${NOOP_CREATE:-0}" != 1 ] || exit 0
        cat "$CYFR_TEST_RUN_ROOT/database-name" > "$CYFR_TEST_RUN_ROOT/database-created"
        if [ "${BAD_RECEIPT:-0}" = 1 ]; then echo wrong > "$CYFR_TEST_RUN_ROOT/database-created"; fi
        if [ "${PENDING_CREATE:-0}" = 1 ]; then touch "$CYFR_TEST_RUN_ROOT/database-create-pending"; fi ;;

      drop)
        [ "${NOOP_DROP:-0}" != 1 ] || exit 0
        echo "$CYFR_DATABASE_URL" >> "$TRACE/dropped"
        [ "${FAIL_CLEANUP:-0}" != 1 ] || exit 9
        rm "$CYFR_TEST_RUN_ROOT/database-created" ;;
    esac ;;
  test)
    key="$(basename "$(dirname "$CYFR_TEST_RUN_ROOT")")-p$MIX_TEST_PARTITION"
    printf '%s\n' "$TMPDIR" "$CYFR_TEST_RUN_ROOT" "${CYFR_DATABASE_URL:-}" "${CYFR_CLUSTER_DATABASE_URL:-}" "$@" > "$TRACE/$key"
    if [ "${WAIT_CHILD:-0}" = 1 ]; then
      sleep 1000 &
      echo "$!" > "$TRACE/sleeper"
      touch "$TRACE/ready"
      wait
    fi
    if [ "${FAIL_CHILD:-0}" = 1 ]; then
      echo FIRST-FAILURE-LINE
      for ((i=0;i<100;i++)); do echo "failure detail $i"; done
      echo LAST-FAILURE-LINE
      exit 7
    fi
    echo 'Result: 1 test, 0 failures' ;;
  *) exit 88 ;;
esac
FAKE
cat > "$scratch/bin/elixir" <<'FAKE_ELIXIR'
#!/usr/bin/env bash
set -eu
if [ "${2:-}" = prepare ]; then
  printf '%s\n' "$3" >> "$TRACE/prepared"
  [ "${NOOP_PREPARE:-0}" != 1 ] || exit 0
  "$REAL_ELIXIR" "$@"
  case "${CORRUPT_PREPARE:-}" in
    missing) rm "$3/p1.env" ;;
    empty) : > "$3/p1.env" ;;
    source) printf '\nreturn 1\n' >> "$3/p1.env" ;;
    partial) printf "export MIX_TEST_PARTITION='1'\n" > "$3/p1.env" ;;
  esac
  exit 0
fi
exec "$REAL_ELIXIR" "$@"
FAKE_ELIXIR
chmod +x "$scratch/bin/mix" "$scratch/bin/elixir"
fail() { echo "FAIL: $*" >&2; exit 1; }
refuses() { if bash "$runner" "$@" >"$scratch/refusal" 2>&1; then fail "accepted $*"; fi; }
refuses -n
refuses -a
refuses -n 0
refuses -n nope
refuses -a other
refuses -n 2 -a postgres -- --only cluster
refuses -n 2 -a postgres apps/cyfr/test/cluster
refuses -n 2 -a postgres test/cluster
refuses -n 1 -a sqlite -- --include cluster
CYFR_DATABASE_URL=bad refuses -n 1 -a postgres
CYFR_TEST_CORES=0 refuses -n 1
CYFR_TEST_CORES=many refuses -n 1

# A caller's share of the cores sizes the partitions in place of the machine's.
CYFR_TEST_CORES=6 bash "$runner" -n 2 >"$scratch/share" 2>&1 || fail 'a run on a share of the cores failed'
grep -q '^==> compiling once (sqlite, 2 partitions, 3 schedulers each)$' "$scratch/share" || fail 'a share of the cores did not size the partitions'
rm -f "$TRACE"/cyfr-t.*-p*

# /bin/bash is Bash 3.2 on macOS; this specifically exercises empty "$@".
/bin/bash "$runner" -n 2 >"$scratch/success" 2>&1
[ "$(find "$TRACE" -name 'cyfr-t.*-p*' -type f | wc -l | tr -d ' ')" = 2 ] || fail 'missing empty-argument partitions'
for trace in "$TRACE"/cyfr-t.*-p*; do
  [ ! -e "$(sed -n '2p' "$trace")" ] || fail 'successful resources survived cleanup'
done

export CYFR_DATABASE_URL='postgres://u:do-not-print@host/base?ssl=true'
bash "$runner" -n 2 -a postgres >"$scratch/a" 2>&1 &
a=$!
bash "$runner" -n 2 -a postgres >"$scratch/b" 2>&1 &
b=$!
wait "$a"; wait "$b"
[ "$(sort -u "$TRACE/dropped" | wc -l | tr -d ' ')" = 4 ] || fail 'simultaneous runs reused databases'
if grep -q 'do-not-print' "$scratch/a" "$scratch/b"; then fail 'credentials printed'; fi
if grep -q '/base?' "$TRACE/dropped"; then fail 'base database dropped'; fi
CYFR_CLUSTER_DATABASE_URL='postgres://u:p@host/cluster_base' bash "$runner" -n 1 -a postgres -- --only cluster >"$scratch/cluster" 2>&1
cluster_trace=$(grep -l '^cluster$' "$TRACE"/*)
[ "$(sed -n '3p' "$cluster_trace")" = "$(sed -n '4p' "$cluster_trace")" ] || fail 'cluster peers use different database'

FAIL_CHILD=1 refuses -n 1
logdir=$(sed -n 's/^==> logs and disposable resources kept: //p' "$scratch/refusal")
[ -f "$logdir/p1.log" ] || fail 'failure log lost'
grep -q FIRST-FAILURE-LINE "$logdir/p1.log"
grep -q LAST-FAILURE-LINE "$logdir/p1.log"
FAIL_CHILD=1 refuses -n 1
second=$(sed -n 's/^==> logs and disposable resources kept: //p' "$scratch/refusal")
[ "$logdir" != "$second" ] || fail 'failure logs reused'
FAIL_CLEANUP=1 refuses -n 1 -a postgres
grep -q 'database cleanup failed' "$scratch/refusal"


# No helper/no-op/source failure may fall back to the caller's environment.
for mode in missing empty source partial; do
  before=$(wc -l < "$TRACE/mix-calls")
  CORRUPT_PREPARE="$mode" refuses -n 1 -a postgres
  [ "$(wc -l < "$TRACE/mix-calls")" = "$before" ] || fail "mix ran with $mode prepare output"
done
before=$(wc -l < "$TRACE/mix-calls")
NOOP_PREPARE=1 refuses -n 1 -a postgres
[ "$(wc -l < "$TRACE/mix-calls")" = "$before" ] || fail 'mix ran after no-op prepare'
for mode in missing empty source; do
  before=$(grep -c '^test ' "$TRACE/mix-calls")
  CORRUPT_AFTER_COMPILE="$mode" refuses -n 1 -a postgres
  [ "$(grep -c '^test ' "$TRACE/mix-calls")" = "$before" ] || fail "tests ran after $mode environment corruption"
done
before=$(grep -c '^test ' "$TRACE/mix-calls")
NOOP_CREATE=1 refuses -n 1 -a postgres
BAD_RECEIPT=1 refuses -n 1 -a postgres
PENDING_CREATE=1 refuses -n 1 -a postgres
[ "$(grep -c '^test ' "$TRACE/mix-calls")" = "$before" ] || fail 'tests ran without valid ownership receipt'
NOOP_DROP=1 refuses -n 1 -a postgres
noop_dir=$(sed -n 's/^==> logs and disposable resources kept: //p' "$scratch/refusal")
[ -s "$noop_dir/p1/database-created" ] || fail 'no-op cleanup erased ownership evidence'

# An inherited library switch cannot disable operational helper execution.
CYFR_TEST_PARTITION_ENV_LIBRARY=1 bash "$runner" -n 1 -a postgres >"$scratch/library" 2>&1
if grep -q '/base?' "$TRACE/dropped"; then fail 'library switch exposed base database'; fi

# The parent may use a long TMPDIR with a trailing slash; socket fixtures
# still need a short canonical path, with no doubled separator.
long_tmp="$scratch/$(printf '%090d' 0)/tmp/"
mkdir -p "$long_tmp"
TMPDIR="$long_tmp" bash "$runner" -n 1 >"$scratch/long" 2>&1
for trace in "$TRACE"/cyfr-t.*-p*; do
  tmp=$(sed -n '1p' "$trace")
  [ "${#tmp}" -lt 50 ] || fail 'partition temp path leaves no room for UNIX socket names'
  case "$tmp" in *//*) fail 'noncanonical doubled path separator' ;; esac
done

WAIT_CHILD=1 bash "$runner" -n 1 -a postgres >"$scratch/cancel" 2>&1 &
cancel=$!
for ((i=0;i<200;i++)); do [ -f "$TRACE/ready" ] && break; sleep 0.05; done
[ -f "$TRACE/ready" ] || fail 'child never started'
kill -TERM "$cancel"
if wait "$cancel"; then fail 'cancellation succeeded'; fi
sleeper=$(cat "$TRACE/sleeper")
if kill -0 "$sleeper" 2>/dev/null; then fail 'cancelled child survived'; fi
cancel_dir=$(sed -n 's/^==> logs and disposable resources kept: //p' "$scratch/cancel")
[ ! -f "$cancel_dir/p1/database-created" ] || fail 'cancelled run database was not cleaned'

# Mix splits test files per application and refuses a partition the named
# paths give no file. Here apps/one's paths hold two test files (a helper
# and a dot-directory's file are not tests) and apps/two's one, so four
# partitions run as two: the first with both applications' paths, the
# second with apps/one's alone, and the last two not at all. An option, its
# value and a missing path reach every started partition unchanged.
tree="$scratch/tree"
mkdir -p "$tree/apps/one/test/deep" "$tree/apps/one/test/.hidden" "$tree/apps/two/test" "$tree/apps/three/test"
touch "$tree/apps/one/test/a_test.exs" "$tree/apps/one/test/deep/b_test.exs" "$tree/apps/one/test/test_helper.exs" \
  "$tree/apps/one/test/.hidden/c_test.exs" "$tree/apps/two/test/only_test.exs" "$tree/apps/three/test/test_helper.exs"
(cd "$tree" && bash "$runner" -n 4 -- --warnings-as-errors --only sparse apps/one/test ./apps/two/test/only_test.exs:12 \
  apps/one/test/deep/b_test.exs:3 apps/two/missing_test.exs) >"$scratch/sparse" 2>&1 || fail 'sparse partitions failed'
partitions_with() { grep -lxF -- "$1" "$TRACE"/cyfr-t.*-p* 2>/dev/null | sed 's/.*-p//' | sort | tr '\n' ' '; }
[ "$(partitions_with apps/one/test)" = '1 2 ' ] || fail "apps/one reached partitions $(partitions_with apps/one/test)"
[ "$(partitions_with apps/one/test/deep/b_test.exs:3)" = '1 2 ' ] || fail 'a named file of apps/one missed its partitions'
[ "$(partitions_with ./apps/two/test/only_test.exs:12)" = '1 ' ] || fail 'apps/two reached a partition its one file does not fall to'
[ "$(partitions_with apps/two/missing_test.exs)" = '1 2 ' ] || fail 'a missing path did not pass through'
[ "$(partitions_with sparse)" = '1 2 ' ] || fail 'an option value did not pass through'
for n in 3 4; do
  grep -A1 -x "==> partition $n/4" "$scratch/sparse" | grep -q 'not started' || fail "partition $n's account does not say it was not started"
done
grep -q '^==> 4 partitions (2 not started: ' "$scratch/sparse" || fail 'the run does not count the partitions it did not start'
grep -q 'exit 0$' "$scratch/sparse" || fail 'a run with partitions not started did not pass'

# A named path that holds no test file is every partition's, so Mix says
# so as it would.
(cd "$tree" && bash "$runner" -n 2 -- apps/three/test) >"$scratch/empty-app" 2>&1 || fail 'the empty-application run failed'
[ "$(partitions_with apps/three/test)" = '1 2 ' ] || fail 'a path with no test file was withheld from a partition'
# Every Mix process of a run has Mix's build lock off.
[ -s "$TRACE/mix-calls" ] || fail 'no Mix call was traced'
[ ! -e "$TRACE/mix-calls-with-build-lock" ] || fail "Mix ran with its build lock on: $(sort -u "$TRACE/mix-calls-with-build-lock" | tr '\n' ' ')"
echo 'partition runner tests passed'
