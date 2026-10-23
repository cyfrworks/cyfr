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
  local result=$? directory
  if [ -n "${report_cancel:-}" ]; then
    kill -TERM "$report_cancel" 2>/dev/null || :
    wait "$report_cancel" 2>/dev/null || :
  fi
  if [ -n "${CYFR_RUNNER_TEST_EVIDENCE:-}" ]; then
    mkdir -p "$CYFR_RUNNER_TEST_EVIDENCE"
    cp -R "$scratch/." "$CYFR_RUNNER_TEST_EVIDENCE/"
  fi
  # A nested runner never sweeps the registry it was given; the test that
  # gave it stops what it lists.
  if [ -s "$scratch/nested-registry" ]; then
    (. "$root/scripts/lib/contain.sh" && CONTAIN_REGISTRY="$scratch/nested-registry" contain_sweep_registry 5) || result=1
  fi
  if [ -f "$scratch/trace/prepared" ]; then
    while IFS= read -r directory; do
      case "$directory" in /tmp/cyfr-t.*|/private/tmp/cyfr-t.*)
        rm -rf "$directory"
        # The test ends by showing that no run directory it made remains.
        if [ -e "$directory" ]; then
          echo "FAIL: the run directory $directory remains" >&2
          result=1
        fi
        if [ -n "${CYFR_RUNNER_TEST_EVIDENCE:-}" ]; then
          printf '%s\t%s\n' "$directory" "$([ ! -e "$directory" ] && echo absent || echo present)" >> "$CYFR_RUNNER_TEST_EVIDENCE/cleanup.tsv"
        fi ;;
      esac
    done < "$scratch/trace/prepared"
  fi
  rm -rf "$scratch"
  return "$result"
}
trap cleanup EXIT
mkdir -p "$scratch/bin" "$scratch/tmp" "$scratch/trace" "$scratch/work"
export TMPDIR="$scratch/tmp" TRACE="$scratch/trace"
real_path=$PATH
export PATH="$scratch/bin:$PATH"
# The runner seeds and merges the failures record of the checkout it runs
# in, so every run here is in a scratch directory, never this checkout.
cd "$scratch/work"
# Each runner starts as an outermost wrapper; the test's own processes stay
# in the session and registry of the check that runs this file.
clean=(env -u HEAVY_CHECK_HELD -u CONTAIN_REGISTRY -u CONTAIN_CLOSE_FDS -u CONTAIN_HOLD_FDS)
export ERL_FLAGS='+S 2:2 +SDcpu 2 +SDio 2'
cat > "$scratch/bin/mix" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$1 ${!#}" >> "$TRACE/mix-calls"
printf '%s\t%s\n' "$1" "${ERL_FLAGS:-}" >> "$TRACE/erl-flags"
printf '%s\t%s\n' "$1" "${MIX_BUILD_PATH-unset}" >> "$TRACE/build-paths"
[ "${MIX_OS_CONCURRENCY_LOCK:-}" = 0 ] || printf '%s\n' "$1 ${!#}" >> "$TRACE/mix-calls-with-build-lock"
# The assignment: `mix run --no-start --no-compile HELPER assign DIR COUNT
# TABLE REQUIRED FAILED WHOLE_SPLIT -- NAMES...` writes DIR/assign/p1..pCOUNT,
# each the partition's units, NUL-terminated. This one deals the named paths
# round robin, or one unit to every partition when none is named.
if [ "$1" = run ] && [ "${5:-}" = assign ]; then
  dir=$6 count=$7
  shift 12
  if [ "$#" -eq 0 ]; then for ((p=1; p<=count; p++)); do set -- "$@" "stub_${p}_test.exs"; done; fi
  mkdir -p "$dir/assign"
  for ((p=1; p<=count; p++)); do : > "$dir/assign/p$p"; done
  p=0
  for unit in "$@"; do printf '%s\0' "$unit" >> "$dir/assign/p$((p % count + 1))"; p=$((p + 1)); done
  exit 0
fi
case "$1" in
  compile)
    if [ "${DIAGNOSTIC_PHASE:-}" = compile ]; then
      cat "$DIAGNOSTIC_INPUT"
      for ((i=0;i<150;i++)); do echo .; done
      echo 'Compilation failed due to warnings while using the --warnings-as-errors option'
      exit "${DIAGNOSTIC_EXIT:-7}"
    fi
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
        if [ "${HANG_DROP:-0}" = 1 ]; then
          trap '' TERM
          echo "$$" >> "$TRACE/drop-leaders"
          while :; do sleep 1; done
        fi
        [ "${NOOP_DROP:-0}" != 1 ] || exit 0
        if [ "${TERM_RESISTANT:-0}" = 1 ]; then
          # A drop must never run beside a partition still using the database.
          saw=none
          while read -r leader; do
            state=$(cat "/proc/$leader/stat" 2>/dev/null) || continue
            case "${state##*) }" in Z*|X*) ;; *) saw=alive ;; esac
          done < "$TRACE/resistant-leaders"
          echo "$saw" >> "$TRACE/drop-saw"
        fi
        echo "$CYFR_DATABASE_URL" >> "$TRACE/dropped"
        [ "${FAIL_CLEANUP:-0}" != 1 ] || exit 9
        rm "$CYFR_TEST_RUN_ROOT/database-created" ;;
    esac ;;
  test)
    key="$(basename "$(dirname "$CYFR_TEST_RUN_ROOT")")-p$MIX_TEST_PARTITION"
    printf '%s\n' "$TMPDIR" "$CYFR_TEST_RUN_ROOT" "${CYFR_DATABASE_URL:-}" "${CYFR_CLUSTER_DATABASE_URL:-}" "$@" > "$TRACE/$key"
    if [ "${COVER_EXPORTS:-0}" = 1 ]; then
      # Mix's export under --cover: apps/<app>/cover/<name>.coverdata for
      # each application the partition ran, then the result.
      name= previous=
      for argument in "$@"; do
        if [ "$previous" = --export-coverage ]; then name=$argument; fi
        previous=$argument
      done
      for app in one two; do
        mkdir -p "apps/$app/cover"
        echo "$MIX_TEST_PARTITION" > "apps/$app/cover/$name.coverdata"
      done
      if [ "${COVER_FAIL:-}" = "$MIX_TEST_PARTITION" ]; then echo 'Result: 1 test, 1 failure'; exit 2; fi
    fi
    if [ "${DIAGNOSTIC_PHASE:-}" = test ]; then
      cat "$DIAGNOSTIC_INPUT"
      for ((i=0;i<150;i++)); do echo .; done
      case "${DIAGNOSTIC_RESULT:-success}" in
        success) echo 'Result: 1 test, 0 failures' ;;
        assertion) echo 'Result: 1 test, 1 failure' ;;
        none) : ;;
      esac
      if [ "${DIAGNOSTIC_EXIT:-7}" != 0 ]; then
        echo 'ERROR! Test suite aborted after successful test execution due to warnings while using the --warnings-as-errors option'
      fi
      [ "${DIAGNOSTIC_LATE:-0}" != 1 ] || echo 'warning: OLD_TAIL_PAYLOAD_SENTINEL'
      if [ "${DIAGNOSTIC_MULTI:-0}" = 1 ] && [ "$MIX_TEST_PARTITION" = 2 ]; then exit 2; fi
      exit "${DIAGNOSTIC_EXIT:-7}"
    fi
    if [ "${RECORD_AND_WAIT:-0}" = 1 ]; then
      "$REAL_ELIXIR" -e 'File.write!(Path.join(System.fetch_env!("CYFR_TEST_RUN_ROOT"), "failures"), :erlang.term_to_binary({1, %{{StubTest, :"test stub"} => "/stub_test.exs"}}))'
      touch "$TRACE/recorded-$MIX_TEST_PARTITION"
      while [ ! -e "$TRACE/release" ]; do sleep 0.1; done
      echo 'Result: 1 test, 1 failure'
      exit 2
    fi
    if [ "${TERM_RESISTANT:-0}" = 1 ]; then
      trap '' TERM
      echo "$$" >> "$TRACE/resistant-leaders"
      while :; do sleep 1; done
    fi
    if [ "${GRANDCHILD:-0}" = 1 ]; then
      # A grandchild in a process group of its own.
      set -m
      sleep 1000 &
      echo "$!" >> "$TRACE/grandchildren"
      set +m
      wait
    fi
    if [ -n "${EMPTY_RUN:-}" ]; then
      case "$EMPTY_RUN" in
        stale) echo 'No stale tests' ;;
        *) echo 'There are no tests to run' ;;
      esac
      case "$EMPTY_RUN" in
        crash) echo '** (RuntimeError) the suite did not load' ;;
        paths) echo 'Paths given to "mix test" did not match any directory/file: apps/gone_test.exs' ;;
        only) echo 'The --only option was given to "mix test" but no test was executed' ;;
      esac
      exit 0
    fi
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
    echo 'Result: 1 test, 0 failures'
    date +%s >> "$TRACE/tests-ended" ;;
  test.coverage)
    # Mix's merge: it reads every export under apps/*/cover/ and prints its
    # table, exiting 3 as Mix does below its threshold.
    ls apps/*/cover/*.coverdata > "$TRACE/coverage-merged"
    printf '| Percentage | Module     |\n|------------|------------|\n|     61.25%% | Total      |\n'
    exit 3 ;;
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
  case "${DIAGNOSTIC_INFRA:-}" in
    roster) mkdir "$3/warning-source-roster" ;;
    summary) mkdir "$3/warning-summary" ;;
  esac
  exit 0
fi
exec "$REAL_ELIXIR" "$@"
FAKE_ELIXIR
chmod +x "$scratch/bin/mix" "$scratch/bin/elixir"
fail() { echo "FAIL: $*" >&2; exit 1; }
refuses() { if "${clean[@]}" bash "$runner" "$@" >"$scratch/refusal" 2>&1; then fail "accepted $*"; fi; }
status_of() { if "$@" >"$scratch/status" 2>&1; then echo 0; else echo "$?"; fi; }
# Whether child PID $1 exits within $2 seconds; an exited child that is not
# yet waited for is a zombie, which kill -0 still finds.
exits_within() {
  local i state
  for ((i=0; i<$2*10; i++)); do
    if [ -r "/proc/$1/stat" ]; then
      read -r state 2>/dev/null <"/proc/$1/stat" || return 0
      state=${state##*) }
    else
      state=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
      state=${state// /}
    fi
    case "$state" in ''|Z*|X*) return 0 ;; esac
    sleep 0.1
  done
  return 1
}
# stop_runner PID SIGNAL BOUND OUT: signals the runner and fails with a
# reason unless it exits within BOUND seconds with the signal's status,
# which its terminal line, the last line of OUT, repeats. The runner traps
# HUP, INT and TERM; any other signal kills it once its EXIT trap has
# written 1.
stop_runner() {
  local pid=$1 signal=$2 bound=$3 out=$4 expected
  case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; *) expected=1 ;; esac
  kill -"$signal" "$pid"
  if ! exits_within "$pid" "$bound"; then
    kill -KILL "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
    fail "the runner did not end within ${bound}s of $signal"
  fi
  if wait "$pid"; then stop_status=0; else stop_status=$?; fi
  case "$signal" in
    HUP|INT|TERM) [ "$stop_status" = "$expected" ] ;;
    *) [ "$stop_status" != 0 ] ;;
  esac || fail "$signal ended the run with $stop_status"
  [ "$(tail -n 1 "$out")" = "_EXIT=$pid $expected" ] || fail "$signal left the terminal line $(tail -n 1 "$out")"
}
# Waits up to a minute for FILE to exist.
await_file() {
  local i
  for ((i=0; i<600; i++)); do [ -e "$1" ] && return 0; sleep 0.1; done
  fail "$1 never appeared"
}
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
# A shard that is not I/N of whole numbers from 1, I at most N and N at
# most 32, is refused with 64 before Mix runs.
mix_calls() { grep -c '' "$TRACE/mix-calls" 2>/dev/null || :; }
before=$(mix_calls)
[ "$(status_of "${clean[@]}" bash "$runner" -n 4 --shard)" = 64 ] || fail 'a --shard without a value was not refused with 64'
for shard in '' 0/4 5/4 1/0 4 1/ /4 a/b 01/4 1/04 1/33 1/4/2 ' 1/4' -1/4 1.0/4; do
  [ "$(status_of "${clean[@]}" bash "$runner" -n 4 --shard "$shard")" = 64 ] || fail "--shard '$shard' was not refused with 64"
done
[ "$(mix_calls)" = "$before" ] || fail 'Mix ran for a refused shard'
# A shard that holds none of the partitions says so and passes, running
# nothing, inside the terminal lines.
"${clean[@]}" bash "$runner" -n 2 --shard 3/4 >"$scratch/shard-none" 2>&1 || fail 'a shard holding no partition failed'
grep -qx '==> shard 3/4 holds none of the 2 partitions: nothing to run' "$scratch/shard-none" || fail 'a shard holding no partition did not say so'
[ "$(head -n 1 "$scratch/shard-none")" = "_START=$(sed -n 's/^_EXIT=\([0-9]*\) 0$/\1/p' "$scratch/shard-none")" ] ||
  fail "a shard holding no partition was not framed by its terminal lines: $(tr '\n' ' ' < "$scratch/shard-none")"
[ "$(mix_calls)" = "$before" ] || fail 'Mix ran for a shard holding no partition'
# A shard sizes its partitions to the cores it has: two of eight here.
rm -f "$TRACE"/cyfr-t.*-p*
CYFR_TEST_CORES=8 "${clean[@]}" bash "$runner" -n 8 --shard 2/4 >"$scratch/shard-share" 2>&1 || fail 'a sharded run on a share of the cores failed'
grep -qx '==> compiling once (sqlite, shard 2/4: partitions 2 6 of 8, 4 schedulers each)' "$scratch/shard-share" ||
  fail "a shard did not size its own partitions: $(grep '^==> compiling' "$scratch/shard-share")"
[ "$(find "$TRACE" -name 'cyfr-t.*-p*' -type f | sed 's/.*-p//' | sort -n | tr '\n' ' ')" = '2 6 ' ] ||
  fail "shard 2/4 of 8 ran partitions $(find "$TRACE" -name 'cyfr-t.*-p*' -type f | sed 's/.*-p//' | sort -n | tr '\n' ' ')"
rm -f "$TRACE"/cyfr-t.*-p*

# A caller's share of the cores sizes the partitions in place of the machine's.
CYFR_TEST_CORES=6 "${clean[@]}" bash "$runner" -n 2 >"$scratch/share" 2>&1 || fail 'a run on a share of the cores failed'
grep -q '^==> compiling once (sqlite, 2 partitions, 3 schedulers each)$' "$scratch/share" || fail 'a share of the cores did not size the partitions'
rm -f "$TRACE"/cyfr-t.*-p*

# /bin/bash is Bash 3.2 on macOS; this specifically exercises empty "$@".
"${clean[@]}" /bin/bash "$runner" -n 2 >"$scratch/success" 2>&1
[ "$(find "$TRACE" -name 'cyfr-t.*-p*' -type f | wc -l | tr -d ' ')" = 2 ] || fail 'missing empty-argument partitions'
for trace in "$TRACE"/cyfr-t.*-p*; do
  [ ! -e "$(sed -n '2p' "$trace")" ] || fail 'successful resources survived cleanup'
done

export CYFR_DATABASE_URL='postgres://u:do-not-print@host/base?ssl=true'
"${clean[@]}" bash "$runner" -n 2 -a postgres >"$scratch/a" 2>&1 &
a=$!
"${clean[@]}" bash "$runner" -n 2 -a postgres >"$scratch/b" 2>&1 &
b=$!
wait "$a"; wait "$b"
[ "$(sort -u "$TRACE/dropped" | wc -l | tr -d ' ')" = 4 ] || fail 'simultaneous runs reused databases'
if grep -q 'do-not-print' "$scratch/a" "$scratch/b"; then fail 'credentials printed'; fi
if grep -q '/base?' "$TRACE/dropped"; then fail 'base database dropped'; fi
CYFR_CLUSTER_DATABASE_URL='postgres://u:p@host/cluster_base' "${clean[@]}" bash "$runner" -n 1 -a postgres -- --only cluster >"$scratch/cluster" 2>&1
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
CYFR_TEST_PARTITION_ENV_LIBRARY=1 "${clean[@]}" bash "$runner" -n 1 -a postgres >"$scratch/library" 2>&1
if grep -q '/base?' "$TRACE/dropped"; then fail 'library switch exposed base database'; fi

# The parent may use a long TMPDIR with a trailing slash; socket fixtures
# still need a short canonical path, with no doubled separator.
long_tmp="$scratch/$(printf '%090d' 0)/tmp/"
mkdir -p "$long_tmp"
TMPDIR="$long_tmp" "${clean[@]}" bash "$runner" -n 1 >"$scratch/long" 2>&1
for trace in "$TRACE"/cyfr-t.*-p*; do
  tmp=$(sed -n '1p' "$trace")
  [ "${#tmp}" -lt 50 ] || fail 'partition temp path leaves no room for UNIX socket names'
  case "$tmp" in *//*) fail 'noncanonical doubled path separator' ;; esac
done

WAIT_CHILD=1 "${clean[@]}" bash "$runner" -n 1 -a postgres >"$scratch/cancel" 2>&1 &
cancel=$!
for ((i=0;i<200;i++)); do [ -f "$TRACE/ready" ] && break; sleep 0.05; done
[ -f "$TRACE/ready" ] || fail 'child never started'
stop_runner "$cancel" TERM 120 "$scratch/cancel"
sleeper=$(cat "$TRACE/sleeper")
if kill -0 "$sleeper" 2>/dev/null; then fail 'cancelled child survived'; fi
cancel_dir=$(sed -n 's/^==> logs and disposable resources kept: //p' "$scratch/cancel")
[ -n "$cancel_dir" ] || fail 'a cancelled run did not name the directory it kept'
[ ! -f "$cancel_dir/p1/database-created" ] || fail 'cancelled run database was not cleaned'

# More than one partition: each started partition is given every Mix
# argument but the paths, then its own units; a partition left with none
# is not started. The stub deals two named paths to partitions 1 and 2.
tree="$scratch/tree"
mkdir -p "$tree/apps/one/test" "$tree/apps/two/test"
touch "$tree/apps/one/test/a_test.exs" "$tree/apps/two/test/only_test.exs"
(cd "$tree" && "${clean[@]}" bash "$runner" -n 4 -- --warnings-as-errors --only sparse apps/one/test ./apps/two/test/only_test.exs) \
  >"$scratch/sparse" 2>&1 || fail 'sparse partitions failed'
partitions_with() { grep -lxF -- "$1" "$TRACE"/cyfr-t.*-p* 2>/dev/null | sed 's/.*-p//' | sort | tr '\n' ' '; }
[ "$(partitions_with apps/one/test)" = '1 ' ] || fail "apps/one reached partitions $(partitions_with apps/one/test)"
[ "$(partitions_with ./apps/two/test/only_test.exs)" = '2 ' ] || fail 'a named file missed its partition'
[ "$(partitions_with sparse)" = '1 2 ' ] || fail 'an option value did not reach every started partition'
for n in 3 4; do
  grep -A1 -x "==> partition $n/4" "$scratch/sparse" | grep -q 'not started' || fail "partition $n's account does not say it was not started"
done
grep -q '^==> 4 partitions (2 not started: ' "$scratch/sparse" || fail 'the run does not count the partitions it did not start'
grep -q 'exit 0$' "$scratch/sparse" || fail 'a run with partitions not started did not pass'
# Every Mix process of a run has Mix's build lock off.
[ -s "$TRACE/mix-calls" ] || fail 'no Mix call was traced'
[ ! -e "$TRACE/mix-calls-with-build-lock" ] || fail "Mix ran with its build lock on: $(sort -u "$TRACE/mix-calls-with-build-lock" | tr '\n' ' ')"

# The failure report through the public runner, against fixtures whose git
# indexes are tracked. A case's diagnostic payloads (the SENTINEL lines)
# come early in the partition's output, before the failure tail the report
# prints raw: the checks read what the report projects from them (the
# location, the header counts) and hold that no payload is printed.
real_git=$(command -v git)
real_awk=$(command -v awk)
export REAL_GIT="$real_git" REAL_AWK="$real_awk"
standalone="$scratch/standalone\\identity"
umbrella="$scratch/umbrella"
mkdir -p "$standalone/lib" "$standalone/test" "$umbrella/apps/one/lib" \
  "$umbrella/apps/one/test" "$umbrella/apps/two/test" "$umbrella/test" "$scratch/cases"
touch "$standalone/lib/probe.ex" "$standalone/test/probe_test.exs" \
  "$standalone/test/test_helper.exs" "$standalone/test/mistyped_tests.exs"
touch "$umbrella/apps/one/lib/unique.ex" "$umbrella/apps/one/test/unique_test.exs" \
  "$umbrella/apps/one/test/test_helper.exs" "$umbrella/apps/two/test/test_helper.exs" \
  "$umbrella/apps/one/test/collision_test.exs" "$umbrella/test/collision_test.exs" \
  "$umbrella/apps/one/test/counts_test.exs" "$umbrella/apps/one/test/space SENTINEL.exs" \
  "$umbrella/apps/one/test/unicode_é_SENTINEL.exs" "$umbrella/apps/one/lib/not_source_SENTINEL.txt"
for fixture in "$standalone" "$umbrella"; do
  "$REAL_GIT" -C "$fixture" init -q
  "$REAL_GIT" -C "$fixture" add -- .
  "$REAL_GIT" -C "$fixture" ls-files --stage > "$fixture/index-receipt"
done
touch "$umbrella/apps/one/test/untracked_SENTINEL.exs"
cat > "$scratch/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -eu
echo acquired >> "$TRACE/roster-calls"
if [ "${DIAGNOSTIC_GIT:-}" = wait ]; then
  sleep 1000 &
  echo "$!" > "$TRACE/diagnostic-sleeper"
  touch "$TRACE/diagnostic-ready"
  wait
fi
if [ "${DIAGNOSTIC_GIT:-}" = partial ]; then
  printf 'test/probe_test.exs\nGIT_STDOUT_PAYLOAD_SENTINEL\n'
  echo GIT_STDERR_PAYLOAD_SENTINEL >&2
  exit 23
fi
exec "$REAL_GIT" "$@"
FAKE_GIT
cat > "$scratch/bin/awk" <<'FAKE_AWK'
#!/usr/bin/env bash
set -eu
echo projected >> "$TRACE/projection-calls"
if [ "${DIAGNOSTIC_AWK:-}" = wait ]; then
  sleep 1000 &
  echo "$!" > "$TRACE/diagnostic-sleeper"
  touch "$TRACE/diagnostic-ready"
  wait
fi
if [ "${DIAGNOSTIC_AWK:-}" = fail ]; then
  echo PARTIAL_AWK_STDOUT_PAYLOAD_SENTINEL
  echo AWK_STDERR_PAYLOAD_SENTINEL >&2
  exit 9
fi
exec "$REAL_AWK" "$@"
FAKE_AWK
chmod +x "$scratch/bin/git" "$scratch/bin/awk"

# A genuine missing-command PATH retains the preparation VM and shell tools,
# without a git executable. All links and fixtures belong to this test.
mkdir "$scratch/no-git-bin"
for tool in bash sh env dirname basename mktemp nproc sysctl grep head tail sed sort wc tr cat rm \
  sleep cmp find mkdir awk readlink uname cut expr getconf cp date \
  setsid pgrep pkill ps mkfifo chmod flock; do
  executable=$(command -v "$tool" || :)
  [ -z "$executable" ] || ln -s "$executable" "$scratch/no-git-bin/$tool"
done
ln -s "$scratch/bin/elixir" "$scratch/no-git-bin/elixir"
ln -s "$scratch/bin/mix" "$scratch/no-git-bin/mix"

contains() { grep -qF -- "$1" "$account" || fail "$case_name missing $1"; }
lacks() { if grep -qF -- "$1" "$account"; then fail "$case_name published $1"; fi; }
header() { printf 'warning: HEADER_PAYLOAD_SENTINEL\n'; }
footer() { printf '    └─ %s\n' "$1"; }
report_case() {
  case_name="$adapter-$1"
  local fixture=$2 expected=${3:-1} phase=${4:-test} parts=${5:-1} result
  shift 5
  account="$scratch/cases/$case_name.out"
  printf '%s\n' "adapter=$adapter phase=$phase partitions=$parts expected=$expected" > "$scratch/cases/$case_name.command"
  cp "$scratch/diagnostic-input" "$scratch/cases/$case_name.input"
  if (cd "$fixture" && DIAGNOSTIC_PHASE="$phase" DIAGNOSTIC_INPUT="$scratch/diagnostic-input" \
      "${clean[@]}" bash "$runner" -n "$parts" -a "$adapter" -- --warnings-as-errors "$@") >"$account" 2>&1; then
    result=0
  else
    result=$?
  fi
  printf '%s\n' "$result" > "$scratch/cases/$case_name.exit"
  [ "$result" = "$expected" ] || fail "$case_name exit $result instead of $expected"
  if [ "${DIAGNOSTIC_LATE:-0}" != 1 ]; then
    lacks SENTINEL
  fi
  lacks do-not-print
  local kept
  kept=$(sed -n 's/^==> logs and disposable resources kept: //p' "$account")
  if [ -n "$kept" ]; then
    for file in "$kept"/*.log "$kept"/warning-source-roster "$kept"/warning-summary; do
      [ ! -f "$file" ] || cp "$file" "$scratch/cases/$case_name-$(basename "$file")"
    done
    for ((i=1;i<=parts;i++)); do
      [ ! -e "$kept/p$i.env" ] || fail "$case_name kept environment"
      [ ! -e "$kept/p$i/database-created" ] || fail "$case_name retained created database"
    done
  fi
  echo "$case_name passed (exit $result)"
}

export DIAGNOSTIC_EXIT=7
for adapter in sqlite postgres; do
  { header; footer 'test/probe_test.exs:4:5: CONTEXT_PAYLOAD_SENTINEL'; echo SOURCE_PAYLOAD_SENTINEL; } > "$scratch/diagnostic-input"
  report_case early-wae "$standalone" 1 test 1
  contains 'Result: 1 test, 0 failures'
  contains 'partition exited 7'
  contains 'location: test/probe_test.exs:4:5'
  contains 'headers=1 emitted=1'
  contains 'ERROR! Test suite aborted'
  before=$(grep -c '^test ' "$TRACE/mix-calls")
  report_case failed-compile "$standalone" 1 compile 1
  contains 'compile failed; see'
  contains 'location: test/probe_test.exs:4:5'
  [ "$(grep -c '^test ' "$TRACE/mix-calls")" = "$before" ] || fail 'tests ran after failed compile'
  { echo '  1) test ordinary assertion (ProbeTest)'; echo '     test/probe_test.exs:4'; echo '     Assertion with == failed'; } > "$scratch/diagnostic-input"
  DIAGNOSTIC_RESULT=assertion report_case assertion "$standalone" 1 test 1
  contains 'Assertion with == failed'
  contains 'headers=0 emitted=0'
  DIAGNOSTIC_RESULT=none report_case no-result "$standalone" 1 test 1
  contains 'NO RESULT'
  DIAGNOSTIC_EXIT=0 DIAGNOSTIC_RESULT=none report_case zero-no-result "$standalone" 1 test 1
  contains 'NO RESULT'
  lacks 'warning evidence:'
  { header; footer 'test/probe_test.exs:4:5'; } > "$scratch/diagnostic-input"
  before=$(wc -l < "$TRACE/roster-calls")
  DIAGNOSTIC_EXIT=0 report_case success-no-scan "$standalone" 0 test 1
  lacks 'warning evidence:'
  [ "$(wc -l < "$TRACE/roster-calls")" = "$before" ] || fail 'successful run acquired roster'

  # The runner's location window: a location this many lines below its
  # header is the header's, one further is not.
  window=512
  for predecessors in $((window-1)) $window $((window+1)); do
    { header; for ((i=0;i<predecessors;i++)); do printf '\033[2K\n'; done; footer 'test/probe_test.exs:4:5'; } > "$scratch/diagnostic-input"
    report_case "control-window-$((predecessors+1))" "$standalone" 1 test 1
    contains "control-lines=$predecessors"
    if [ "$predecessors" = $((window-1)) ]; then contains 'location: test/probe_test.exs:4:5'; else lacks 'location: test/probe_test.exs'; contains 'location: unavailable or outside source allowlist'; fi
  done
  for predecessors in $((window-1)) $window; do
    { header; for ((i=0;i<predecessors;i++)); do
        case "$((i%4))" in 0) printf '\033[2K\n' ;; 1) echo ;; 2) printf '%1100s\n' X ;; 3) echo CONTINUATION_PAYLOAD_SENTINEL ;; esac
      done; footer 'test/probe_test.exs:4:5'; } > "$scratch/diagnostic-input"
    report_case "mixed-window-$((predecessors+1))" "$standalone" 1 test 1
    contains "oversized-lines=$((window/4))"
    contains "control-lines=$((window/4))"
    if [ "$predecessors" = $((window-1)) ]; then contains 'location: test/probe_test.exs:4:5'; else lacks 'location: test/probe_test.exs'; fi
  done
  # A type warning as Elixir 1.20 prints it: the inferred type of each
  # value it names, one struct field to a line, then its source and its
  # footer, ninety-odd lines below the header.
  {
    printf '     warning: the following pattern will never match: HEADER_PAYLOAD_SENTINEL\n\n'
    printf '         {:ok, plan} = Probe.plan(ctx, PATTERN_PAYLOAD_SENTINEL)\n\n'
    printf '     where "ctx" was given the type:\n\n         # type: dynamic(%%{\n'
    for ((i=0;i<80;i++)); do printf '           field_%d_TYPE_PAYLOAD_SENTINEL: term(),\n' "$i"; done
    printf '         })\n         # from: test/probe_test.exs:3:7\n         publish!(ctx)\n\n'
    printf '     type warning found at:\n     │\n   4 │   {:ok, plan} = SOURCE_PAYLOAD_SENTINEL\n     │               ~\n     │\n'
    footer 'test/probe_test.exs:4:15: ProbeTest."test CONTEXT_PAYLOAD_SENTINEL"/1'
  } > "$scratch/diagnostic-input"
  report_case type-warning "$standalone" 1 test 1
  contains 'headers=1 emitted=1'
  contains 'location: test/probe_test.exs:4:15'
  lacks 'location: test/probe_test.exs:3:7'
  # A header that follows the run's progress marks on their line is a
  # header, and the location below it is its own, not the one above's.
  { header; footer 'test/probe_test.exs:4:5'; printf '.*?.'; header; footer 'test/probe_test.exs:9:3'; } > "$scratch/diagnostic-input"
  report_case progress-header "$standalone" 1 test 1
  contains 'headers=2 emitted=2'
  [ "$(grep -c '^      location:' "$account")" = 2 ] || fail 'a header after progress marks lent its location to the one above'
  grep -A1 'log line 3; diagnostic header' "$account" | grep -qF 'location: test/probe_test.exs:9:3' || fail 'progress-marked header lost its location'
  { printf '%1100s' '' | tr ' ' .; header; footer 'test/probe_test.exs:4:5'; } > "$scratch/diagnostic-input"
  report_case progress-header-long "$standalone" 1 test 1
  contains 'headers=1 emitted=1 omitted=0 oversized-lines=0'
  contains 'location: test/probe_test.exs:4:5'
  { echo '..17:00:00 [warning] LOGGER_PAYLOAD_SENTINEL'; echo '..  4 │ warning: SOURCE_PAYLOAD_SENTINEL'; echo '.x warning: TEXT_PAYLOAD_SENTINEL'; } > "$scratch/diagnostic-input"
  report_case progress-unsupported "$standalone" 1 test 1
  contains 'headers=0 emitted=0'
  for predecessors in 0 $((window+1)); do
    { header; for ((i=0;i<predecessors;i++)); do printf '\033[2K\n'; done; header; footer 'test/probe_test.exs:4:5'; } > "$scratch/diagnostic-input"
    report_case "new-header-$predecessors" "$standalone" 1 test 1
    contains 'headers=2 emitted=2'
    contains 'location: test/probe_test.exs:4:5'
  done

  for spelling in lib/unique.ex ./lib/unique.ex apps/one/lib/unique.ex "$umbrella/apps/one/lib/unique.ex"; do
    { header; footer "$spelling:3:5"; } > "$scratch/diagnostic-input"
    report_case "unique-lib-$(echo "$spelling" | tr '/.' '__')" "$umbrella" 1 test 1
    contains 'location: apps/one/lib/unique.ex:3:5'
  done
  { header; footer 'test/unique_test.exs:2:1'; } > "$scratch/diagnostic-input"
  report_case unique-test "$umbrella" 1 test 1
  contains 'location: apps/one/test/unique_test.exs:2:1'
  for spelling in test/test_helper.exs test/collision_test.exs "$umbrella/lib/unique.ex" \
      ././lib/unique.ex ../apps/one/lib/unique.ex apps/one/test/untracked_SENTINEL.exs \
      'apps/one/test/space SENTINEL.exs' 'apps/one/test/unicode_é_SENTINEL.exs' \
      apps/one/lib/not_source_SENTINEL.txt /tmp/EXTERNAL_PAYLOAD_SENTINEL.exs; do
    { echo '==> one'; header; footer "$spelling:3:5"; } > "$scratch/diagnostic-input"
    report_case "withheld-$(echo "$spelling" | tr '/. ' '___')" "$umbrella" 1 test 1
    contains 'location: unavailable or outside source allowlist'
    lacks '      location: apps/'
    lacks '      location: test/'
  done
  for spelling in apps/one/test/collision_test.exs "$umbrella/apps/two/test/test_helper.exs" "$umbrella/test/collision_test.exs"; do
    { header; footer "$spelling:4:5"; } > "$scratch/diagnostic-input"
    report_case "canonical-$(echo "$spelling" | tr '/.' '__')" "$umbrella" 1 test 1
    contains "location: ${spelling#"$umbrella"/}:4:5"
  done
  { header; footer "$standalone/test/probe_test.exs:4:5"; } > "$scratch/diagnostic-input"
  report_case literal-checkout "$standalone" 1 test 1
  contains 'location: test/probe_test.exs:4:5'
  { header; for position in 0:5 99999999:5 3:0 3:99999999 3:-1; do footer "lib/unique.ex:$position"; done; } > "$scratch/diagnostic-input"
  report_case invalid-positions "$umbrella" 1 test 1
  contains 'location: unavailable or outside source allowlist'
  {
    header
    for ((i=1;i<=6;i++)); do footer "test/counts_test.exs:$i:5"; done
    footer 'apps/one/test/counts_test.exs:5:5'
    footer "$umbrella/apps/one/test/counts_test.exs:6:5"
    footer 'test/test_helper.exs:7:5'; footer 'test/collision_test.exs:7:5'
    footer 'apps/one/test/untracked_SENTINEL.exs:7:5'; footer 'lib/unique.ex:0:5'
  } > "$scratch/diagnostic-input"
  report_case omissions "$umbrella" 1 test 1
  contains 'additional locations omitted: 2'
  [ "$(grep -c '^      location:' "$account")" = 4 ] || fail 'location cap changed'
  lacks 'additional locations omitted: 3'
  {
    for ((j=0;j<41;j++)); do header; for ((i=1;i<=6;i++)); do footer "test/counts_test.exs:$i:5"; done; done
  } > "$scratch/diagnostic-input"
  report_case header-cap "$umbrella" 1 test 1
  contains 'headers=41 emitted=40 omitted=1'
  [ "$(grep -c '^    warning evidence: log line' "$account")" = 40 ] || fail 'header cap changed'
  [ "$(grep -c '^      additional locations omitted: 2$' "$account")" = 40 ] || fail 'omitted headers contributed locations'
  {
    printf 'warning: %1100s\n' X
    printf '\033[33mwarning:\033[0m HEADER_PAYLOAD_SENTINEL\n'
    footer 'test/probe_test.exs:4:5'
  } > "$scratch/diagnostic-input"
  report_case sgr-oversized "$standalone" 1 test 1
  contains 'headers=1 emitted=1'; contains 'oversized-lines=1'
  contains 'location: test/probe_test.exs:4:5'
  { echo '17:00:00 [warning] LOGGER_PAYLOAD_SENTINEL'; echo '  4 │ warning: SOURCE_PAYLOAD_SENTINEL'; echo 'error: ERROR_PAYLOAD_SENTINEL'; echo 'src/probe.erl:3:5: Warning: ERLANG_PAYLOAD_SENTINEL'; } > "$scratch/diagnostic-input"
  report_case unsupported "$standalone" 1 test 1
  contains 'headers=0 emitted=0'
  {
    echo 'warning: the following files do not match any of the configured `:test_load_filters` / `:test_ignore_filters`:'
    echo; echo test/counts_test.exs; echo test/test_helper.exs
  } > "$scratch/diagnostic-input"
  report_case misnamed "$umbrella" 1 test 1
  contains 'test-loader file classification'; contains 'location: apps/one/test/counts_test.exs'
  lacks 'location: apps/one/test/test_helper'

  { header; footer 'test/probe_test.exs:4:5'; } > "$scratch/diagnostic-input"
  DIAGNOSTIC_GIT=partial report_case partial-roster "$standalone" 1 test 1
  contains 'warning evidence: source roster unavailable'
  contains 'location: unavailable or outside source allowlist'
  lacks 'location: test/probe_test.exs'
  PATH="$scratch/no-git-bin:$(dirname "$(command -v erl)")" report_case missing-git "$standalone" 1 test 1
  contains 'warning evidence: source roster unavailable'
  contains 'location: unavailable or outside source allowlist'
  DIAGNOSTIC_AWK=fail report_case failed-projection "$standalone" 1 test 1
  contains 'warning evidence: unavailable'; lacks 'warning evidence: log line'
  DIAGNOSTIC_INFRA=roster report_case failed-roster-file "$standalone" 1 test 1
  contains 'warning evidence: unavailable'; lacks 'warning evidence: log line'
  DIAGNOSTIC_INFRA=summary report_case failed-summary-file "$standalone" 1 test 1
  contains 'warning evidence: unavailable'; lacks 'warning evidence: log line'
  DIAGNOSTIC_LATE=1 report_case existing-tail-exposure "$standalone" 1 test 1
  contains 'OLD_TAIL_PAYLOAD_SENTINEL'

  before=$(wc -l < "$TRACE/roster-calls")
  DIAGNOSTIC_MULTI=1 report_case multiple-exits "$umbrella" 1 test 4 apps/one/test/unique_test.exs apps/one/test/counts_test.exs
  contains 'partition exited 7'; contains 'partition exited 2'
  contains '4 partitions (2 not started:'
  [ "$(wc -l < "$TRACE/roster-calls")" = "$((before+1))" ] || fail 'roster was acquired more than once'
  [ "$(grep -c '^    warning evidence summary:' "$account")" = 2 ] || fail 'unstarted partitions were scanned'
  before=$(wc -l < "$TRACE/roster-calls")
  DIAGNOSTIC_GIT=partial report_case failed-roster-no-retry "$umbrella" 1 test 4 apps/one/test/unique_test.exs apps/one/test/counts_test.exs
  [ "$(wc -l < "$TRACE/roster-calls")" = "$((before+1))" ] || fail 'failed roster was retried'
  [ "$(grep -c '^    warning evidence: source roster unavailable$' "$account")" = 2 ] || fail 'failed roster notice missing'
  for dependency in git awk; do
    rm -f "$TRACE/diagnostic-ready" "$TRACE/diagnostic-sleeper"
    account="$scratch/cases/$adapter-cancel-$dependency.out"
    (cd "$standalone" && DIAGNOSTIC_GIT="$([ "$dependency" = git ] && echo wait || echo normal)" \
      DIAGNOSTIC_AWK="$([ "$dependency" = awk ] && echo wait || echo normal)" \
      DIAGNOSTIC_PHASE=test DIAGNOSTIC_INPUT="$scratch/diagnostic-input" \
      exec "${clean[@]}" bash "$runner" -n 1 -a "$adapter" -- --warnings-as-errors) >"$account" 2>&1 &
    report_cancel=$!
    for ((i=0;i<200;i++)); do [ -f "$TRACE/diagnostic-ready" ] && break; sleep 0.05; done
    [ -f "$TRACE/diagnostic-ready" ] || fail "$dependency reporting dependency never started"
    stop_runner "$report_cancel" TERM 60 "$account"
    report_cancel=
    result=$stop_status
    printf '%s\n' "$result" > "$scratch/cases/$adapter-cancel-$dependency.exit"
    sleeper=$(cat "$TRACE/diagnostic-sleeper")
    for ((i=0;i<50;i++)); do kill -0 "$sleeper" 2>/dev/null || break; sleep 0.02; done
    if kill -0 "$sleeper" 2>/dev/null; then fail "cancelled $dependency descendant survived"; fi
    kept=$(sed -n 's/^==> logs and disposable resources kept: //p' "$account")
    [ -n "$kept" ] || fail "$dependency cancellation did not name the directory it kept"
    [ ! -e "$kept/p1/database-created" ] || fail "$dependency cancellation retained database"
    [ ! -e "$kept/p1.env" ] || fail "$dependency cancellation retained environment"
    echo "$adapter-cancel-$dependency passed (exit $result)"
  done
done
# --- --cover: one Total line, the run's own status, the exports removed ---
# Each partition exports under the run's name, ahead of the other Mix
# arguments; the merge reads exactly those exports and its exit 3 (a figure
# below Mix's threshold) changes nothing; a failing test still fails the
# run with the figure printed; another run's export stops the merge and is
# left alone; and no export of the run remains once it ends.
cover_exports() { (cd "$scratch/work" && find apps -name '*.coverdata' 2>/dev/null | sort); }
cover_run() { ls "$TRACE"/cyfr-t.*-p1 | sed 's|.*/||; s|-p1$||'; }
rm -f "$TRACE"/cyfr-t.*-p*
COVER_EXPORTS=1 "${clean[@]}" bash "$runner" -n 2 --cover >"$scratch/cover" 2>&1 || fail "a --cover run failed: $(cat "$scratch/cover")"
run=$(cover_run)
for i in 1 2; do
  [ "$(sed -n '5,9p' "$TRACE/$run-p$i" | tr '\n' ' ')" = "test --no-compile --cover --export-coverage $run-p$i " ] ||
    fail "partition $i was not given its export ahead of the rest: $(sed -n '5,$p' "$TRACE/$run-p$i" | tr '\n' ' ')"
done
[ "$(sort "$TRACE/coverage-merged" | tr '\n' ' ')" = "apps/one/cover/$run-p1.coverdata apps/one/cover/$run-p2.coverdata apps/two/cover/$run-p1.coverdata apps/two/cover/$run-p2.coverdata " ] ||
  fail "the merge read $(tr '\n' ' ' < "$TRACE/coverage-merged")"
grep -qx '==> coverage: 61.25% of lines in total (4 exports merged)' "$scratch/cover" || fail "no Total line: $(cat "$scratch/cover")"
[ -z "$(cover_exports)" ] || fail "a --cover run left its exports: $(cover_exports)"
[ ! -e "$scratch/work/apps/one/cover" ] || fail 'a --cover run left an empty cover directory'
rm -f "$TRACE"/cyfr-t.*-p* "$TRACE/coverage-merged"
[ "$(COVER_EXPORTS=1 COVER_FAIL=2 status_of "${clean[@]}" bash "$runner" -n 2 --cover)" = 1 ] || fail "a failing test under --cover did not fail the run: $(cat "$scratch/status")"
grep -qx '==> coverage: 61.25% of lines in total (4 exports merged)' "$scratch/status" || fail "a failing run printed no Total line: $(cat "$scratch/status")"
[ -z "$(cover_exports)" ] || fail "a failing --cover run left its exports: $(cover_exports)"
rm -f "$TRACE"/cyfr-t.*-p* "$TRACE/coverage-merged"
mkdir -p "$scratch/work/apps/three/cover"
echo other > "$scratch/work/apps/three/cover/other.coverdata"
[ "$(COVER_EXPORTS=1 status_of "${clean[@]}" bash "$runner" -n 2 --cover)" = 0 ] || fail "a run beside another's export failed: $(cat "$scratch/status")"
grep -qx '==> coverage not merged: apps/\*/cover/ holds exports of another run: apps/three/cover/other.coverdata' "$scratch/status" ||
  fail "another run's export did not stop the merge: $(cat "$scratch/status")"
[ ! -e "$TRACE/coverage-merged" ] || fail "the merge ran beside another run's export"
[ "$(cover_exports)" = apps/three/cover/other.coverdata ] || fail "the run removed another's export or left its own: $(cover_exports)"
rm -rf "$scratch/work/apps/three" "$TRACE"/cyfr-t.*-p*
[ "$(status_of "${clean[@]}" bash "$runner" -n 1 --cover -- --cover)" = 64 ] || fail 'Mix --cover beside the runner'"'"'s was not refused'
[ "$(status_of "${clean[@]}" bash "$runner" -n 1 --cover -- --export-coverage mine)" = 64 ] || fail 'Mix --export-coverage beside the runner'"'"'s was not refused'
echo 'cover: one Total line, a failing test still fails, exports removed, another run'"'"'s left alone'
# --- containment, the terminal lines and admission -------------------------

# lines_of OUT ARGS...: the runner in the background, so its pid is known.
lines_of() {
  local out=$1
  shift
  "${clean[@]}" bash "$runner" "$@" >"$out" 2>"$out.err" &
  lines_pid=$!
  if wait "$lines_pid"; then lines_status=0; else lines_status=$?; fi
}
lines_of "$scratch/lines" -n 1
[ "$(head -n 1 "$scratch/lines")" = "_START=$lines_pid" ] || fail 'stdout does not begin with _START=<pid>'
[ "$(tail -n 1 "$scratch/lines")" = "_EXIT=$lines_pid 0" ] || fail 'stdout does not end with _EXIT=<pid> 0'
[ "$(grep -cE '^_(START|EXIT)=' "$scratch/lines")" = 2 ] || fail 'a run wrote more than two terminal lines'
FAIL_CLEANUP=1 lines_of "$scratch/lines" -n 1 -a postgres
[ "$lines_status" = 1 ] || fail "a run whose cleanup failed exited $lines_status"
grep -q '^==> 1 partitions, postgres, .*, exit 0$' "$scratch/lines" || fail 'the summary does not report the status before cleanup'
[ "$(tail -n 1 "$scratch/lines")" = "_EXIT=$lines_pid 1" ] || fail 'the terminal line does not carry the status cleanup set'
lines_of "$scratch/lines" -n 2 -a postgres -- --only cluster
{ [ "$lines_status" = 64 ] && [ "$(head -n 1 "$scratch/lines")" = "_START=$lines_pid" ] &&
  [ "$(tail -n 1 "$scratch/lines")" = "_EXIT=$lines_pid 64" ]; } || fail 'a refusal after the options lacks its terminal lines'
lines_of "$scratch/lines" -n 0
{ [ "$lines_status" = 64 ] && [ ! -s "$scratch/lines" ]; } || fail 'an invalid -n wrote terminal lines'
for mode in exclusive scoped; do
  "${clean[@]}" HEAVY_CHECK_HELD=$mode bash "$runner" -n 1 >"$scratch/held" 2>&1 || fail "a run held $mode failed"
  if grep -qE '_(START|EXIT)=' "$scratch/held"; then fail "terminal lines written under HEAVY_CHECK_HELD=$mode"; fi
done

# Scoped admission: a resolved count above one is refused before anything
# is prepared.
scoped() { status_of "${clean[@]}" HEAVY_CHECK_HELD=scoped bash "$runner" "$@"; }
before=$(cat "$TRACE/prepared" "$TRACE/mix-calls" | wc -l)
[ "$(scoped -n 4)" = 64 ] || fail 'a scoped run took four partitions'
[ "$(scoped -n 1 -n 4)" = 64 ] || fail 'a scoped run took the last -n of four'
[ "$(scoped -a sqlite -n 4)" = 64 ] || fail 'a scoped run took four partitions after -a'
[ "$(scoped)" = 64 ] || fail 'a scoped run took the default count'
[ "$(cat "$TRACE/prepared" "$TRACE/mix-calls" | wc -l)" = "$before" ] || fail 'a refused scoped run prepared or reached Mix'
[ "$(scoped -a sqlite -n 1)" = 0 ] || fail 'a scoped run refused one partition'
[ "$(scoped -n 4 -n 1)" = 0 ] || fail 'a scoped run refused a last -n of one'

# --stale cannot be merged across partitions; the slot bound; a missing path.
before=$(grep -c '^compile ' "$TRACE/mix-calls")
[ "$(status_of "${clean[@]}" bash "$runner" -n 2 -- --stale)" = 64 ] || fail '--stale ran in two partitions'
[ "$(status_of "${clean[@]}" bash "$runner" -n 33)" = 64 ] || fail 'thirty-three partitions were admitted'
for parts in 1 2; do
  [ "$(status_of "${clean[@]}" bash "$runner" -n "$parts" -- --seed 0 apps/no/such_test.exs:3)" = 64 ] ||
    fail "a missing path was not refused with $parts partitions"
  grep -q 'no such test path: apps/no/such_test.exs:3' "$scratch/status" || fail 'the refusal does not name the path'
done
[ "$(grep -c '^compile ' "$TRACE/mix-calls")" = "$before" ] || fail 'a refused run compiled'
[ "$(status_of "${clean[@]}" bash "$runner" -n 1 -- --stale)" = 0 ] || fail '--stale in one partition was refused'

# A zero exit without Result: is a failure, unless Mix said the --failed or
# --stale selection is empty and nothing that means otherwise.
[ "$(EMPTY_RUN=1 status_of "${clean[@]}" bash "$runner" -n 1 -- --failed)" = 0 ] || fail 'a valid empty rerun failed'
grep -q 'no test to run: the --failed or --stale selection is empty' "$scratch/status" || fail 'the empty rerun was not named'
[ "$(EMPTY_RUN=1 status_of "${clean[@]}" bash "$runner" -n 1)" = 1 ] || fail 'an empty run without --failed passed'
grep -q 'NO RESULT' "$scratch/status" || fail 'an empty run without --failed was not called NO RESULT'
[ "$(EMPTY_RUN=crash status_of "${clean[@]}" bash "$runner" -n 1 -- --failed)" = 1 ] || fail 'an empty rerun that raised passed'
[ "$(EMPTY_RUN=paths status_of "${clean[@]}" bash "$runner" -n 1 -- --failed)" = 1 ] || fail 'an empty rerun whose paths matched nothing passed'
[ "$(EMPTY_RUN=only status_of "${clean[@]}" bash "$runner" -n 1 -- --failed)" = 1 ] || fail 'an empty rerun whose --only ran nothing passed'
[ "$(EMPTY_RUN=stale status_of "${clean[@]}" bash "$runner" -n 1 -- --stale)" = 0 ] || fail 'an empty --stale run failed'
grep -q 'no test to run: the --failed or --stale selection is empty' "$scratch/status" || fail 'the empty --stale run was not named'
[ "$(EMPTY_RUN=stale status_of "${clean[@]}" bash "$runner" -n 1)" = 1 ] || fail 'No stale tests without --stale passed'

# Mix filters a whole run by its lines, so with more than one partition a
# path with a line beside one without is refused; one partition passes them.
mkdir -p apps/mixed/test
touch apps/mixed/test/a_test.exs apps/mixed/test/b_test.exs
[ "$(status_of "${clean[@]}" bash "$runner" -n 2 -- apps/mixed/test/a_test.exs apps/mixed/test/b_test.exs:3)" = 64 ] ||
  fail 'paths with and without a line were split'
grep -q 'paths with a line and paths without one cannot be split' "$scratch/status" || fail 'the mixed paths refusal does not say why'
[ "$(status_of "${clean[@]}" bash "$runner" -n 1 -- apps/mixed/test/a_test.exs apps/mixed/test/b_test.exs:3)" = 0 ] ||
  fail 'one partition refused paths with and without a line'

# The compile takes every core of the run's share; a partition its part.
: > "$TRACE/erl-flags"
CYFR_TEST_CORES=6 "${clean[@]}" bash "$runner" -n 2 >"$scratch/flags" 2>&1 || fail 'the scheduler run failed'
[ "$(grep -c '^compile	+S 6:6 +SDcpu 6 +SDio 16 ' "$TRACE/erl-flags")" = 1 ] || fail "the compile did not see six cores: $(grep '^compile' "$TRACE/erl-flags")"
[ "$(grep -c '^test	+S 3:3 +SDcpu 3 +SDio 16 ' "$TRACE/erl-flags")" = 2 ] || fail "a partition did not see its share: $(grep '^test' "$TRACE/erl-flags")"

# A partition's grandchild in a process group of its own dies with the run,
# on TERM, INT, HUP and an untrapped USR1. A background command of a shell
# without job control starts with INT ignored, a nohup one with HUP, and
# Bash cannot trap a signal ignored at its start, so the runner starts with
# their defaults restored.
await_lines() {
  local i
  for ((i=0; i<600; i++)); do
    [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -ge "$2" ] && return 0
    sleep 0.1
  done
  fail "$1 never reached $2 lines"
}
for signal in TERM INT HUP USR1; do
  : > "$TRACE/grandchildren"
  GRANDCHILD=1 "${clean[@]}" perl -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec @ARGV or die' bash "$runner" -n 2 >"$scratch/cancel-$signal" 2>&1 &
  cancel=$!
  await_lines "$TRACE/grandchildren" 2
  stop_runner "$cancel" "$signal" 60 "$scratch/cancel-$signal"
  while read -r grandchild; do
    if kill -0 "$grandchild" 2>/dev/null; then fail "a partition's grandchild outlived $signal"; fi
  done < "$TRACE/grandchildren"
done

# The runner SIGKILLed: its watchdogs stop every partition, its directory
# is kept, and the next run names it.
: > "$TRACE/grandchildren"
GRANDCHILD=1 "${clean[@]}" bash "$runner" -n 2 >"$scratch/killed" 2>&1 &
killed=$!
await_lines "$TRACE/grandchildren" 2
killed_dir=$(tail -n 1 "$TRACE/prepared")
kill -KILL "$killed"
wait "$killed" 2>/dev/null || :
for ((i=0; i<300; i++)); do
  live=false
  while read -r grandchild; do kill -0 "$grandchild" 2>/dev/null && live=true; done < "$TRACE/grandchildren"
  [ "$live" = true ] || break
  sleep 0.1
done
[ "$live" = false ] || fail 'a partition outlived its SIGKILLed runner'
[ -e "$killed_dir/p1.env" ] || fail 'the killed run did not keep its directory'
"${clean[@]}" bash "$runner" -n 1 >"$scratch/after-kill" 2>&1 || fail 'the run after a killed one failed'
grep -qF "a stopped run kept its directory and its partitions' disposable database URLs: $killed_dir" "$scratch/after-kill" ||
  fail 'the next run did not name the killed run'

# Eight TERM-resistant partition leaders are stopped together: within the
# GRACE_S + 15 s that `contain_stop_all 30` returns in (scripts/lib/contain.sh),
# not one after another (8 x 30 s).
: > "$TRACE/resistant-leaders"
TERM_RESISTANT=1 "${clean[@]}" bash "$runner" -n 8 >"$scratch/resistant" 2>&1 &
resistant=$!
await_lines "$TRACE/resistant-leaders" 8
sent=$SECONDS
stop_runner "$resistant" TERM 60 "$scratch/resistant"
took=$((SECONDS - sent))
[ "$took" -le 50 ] || fail "stopping eight resistant partitions took ${took}s"
while read -r leader; do
  if kill -0 "$leader" 2>/dev/null; then fail 'a TERM-resistant partition leader survived'; fi
done < "$TRACE/resistant-leaders"
echo "eight resistant partitions stopped in ${took}s"

# Nested, as under heavy-check or the gate, the runner owns no registry and
# sweeps none, so its own stop is all that ends its partitions: every
# leader is dead when it exits, and on PostgreSQL before any drop runs.
alive() {
  local state
  state=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  case "${state##*) }" in Z*|X*) return 1 ;; esac
}
(umask 077 && : > "$scratch/nested-registry")
for adapter in sqlite postgres; do
  : > "$TRACE/resistant-leaders"
  : > "$TRACE/drop-saw"
  TERM_RESISTANT=1 env -u HEAVY_CHECK_HELD -u CONTAIN_CLOSE_FDS -u CONTAIN_HOLD_FDS CONTAIN_REGISTRY="$scratch/nested-registry" \
    bash "$runner" -n 2 -a "$adapter" >"$scratch/nested-$adapter" 2>&1 &
  nested=$!
  await_lines "$TRACE/resistant-leaders" 2
  stop_runner "$nested" TERM 60 "$scratch/nested-$adapter"
  if [ "$adapter" = postgres ]; then
    [ "$(sort -u "$TRACE/drop-saw")" = none ] && [ "$(wc -l < "$TRACE/drop-saw")" = 2 ] ||
      fail "a drop ran beside a live partition: $(tr '\n' ' ' < "$TRACE/drop-saw")"
  fi
  while read -r leader; do
    if alive "$leader"; then fail "a partition leader outlived its nested $adapter runner"; fi
  done < "$TRACE/resistant-leaders"
done
[ -s "$scratch/nested-registry" ] || fail 'the nested runner did not register its sessions'

# Eight hanging drops are stopped together, within 70 s (45 + 10 + 15) of
# the partitions' end, and every environment file goes.
: > "$TRACE/drop-leaders"
: > "$TRACE/tests-ended"
if HANG_DROP=1 "${clean[@]}" bash "$runner" -n 8 -a postgres >"$scratch/hung-drops" 2>&1; then fail 'a run whose drops hung passed'; else result=$?; fi
took=$(( $(date +%s) - $(sort -n "$TRACE/tests-ended" | tail -n 1) ))
[ "$result" = 1 ] || fail "the hung drops ended the run with $result"
[ "$(wc -l < "$TRACE/drop-leaders")" = 8 ] || fail 'not every drop started'
[ "$took" -le 75 ] || fail "eight hung drops took ${took}s after the partitions ended"
while read -r leader; do
  if kill -0 "$leader" 2>/dev/null; then fail 'a hung drop survived'; fi
done < "$TRACE/drop-leaders"
hung_dir=$(sed -n 's/^==> logs and disposable resources kept: //p' "$scratch/hung-drops")
[ -d "$hung_dir" ] || fail 'the hung drops kept no directory'
for ((i=1; i<=8; i++)); do
  [ ! -e "$hung_dir/p$i.env" ] || fail "partition $i's environment survived its hung drop"
done
echo "eight hung drops stopped ${took}s after the partitions ended"

# The build path: PostgreSQL's own without an explicit one, Mix's
# default for SQLite, and an explicit one kept on both.
for adapter in sqlite postgres; do
  case "$adapter" in sqlite) expected=unset ;; postgres) expected=_build/test_pg ;; esac
  : > "$TRACE/build-paths"
  "${clean[@]}" -u MIX_BUILD_PATH bash "$runner" -n 1 -a "$adapter" >"$scratch/build-path" 2>&1 || fail "the $adapter build-path run failed"
  [ "$(cut -f2 "$TRACE/build-paths" | sort -u)" = "$expected" ] || fail "$adapter ran Mix with $(cut -f2 "$TRACE/build-paths" | sort -u | tr '\n' ' ')"
  : > "$TRACE/build-paths"
  "${clean[@]}" MIX_BUILD_PATH=_build/custom bash "$runner" -n 1 -a "$adapter" >"$scratch/build-path" 2>&1 || fail "the explicit $adapter build-path run failed"
  [ "$(cut -f2 "$TRACE/build-paths" | sort -u)" = _build/custom ] || fail "$adapter replaced an explicit build path: $(cut -f2 "$TRACE/build-paths" | sort -u | tr '\n' ' ')"
done

# A stopped run does not merge: its partitions never reached their ends,
# so the canonical record stays as it was, and the runner says so.
canonical="$scratch/work/_build/test/test_failures"
record_sum() { cksum < "$canonical" 2>/dev/null || echo absent; }
before=$(record_sum)
rm -f "$TRACE/release" "$TRACE/recorded-1"
RECORD_AND_WAIT=1 "${clean[@]}" bash "$runner" -n 1 >"$scratch/stopped" 2>&1 &
stopped=$!
await_file "$TRACE/recorded-1"
stop_runner "$stopped" TERM 60 "$scratch/stopped"
[ "$(record_sum)" = "$before" ] || fail 'a stopped run merged its failures record'
grep -qx '==> the failures record was left unmerged: the run stopped before its partitions ended' "$scratch/stopped" ||
  fail 'a stopped run did not say its failures record was left unmerged'

# The test's lock holder takes the record's lock itself and becomes the
# sleep that holds it, so stopping it frees the lock and leaves nothing.
hold_record_lock() {
  bash -c 'exec 9>>"$1" && flock 9 && touch "$TRACE/locked" && exec sleep 120' hold "$canonical.lock" &
  holder=$!
  await_file "$TRACE/locked"
}
release_record_lock() {
  kill "$holder" 2>/dev/null || :
  wait "$holder" 2>/dev/null || :
}
# Once nothing else may hold the record's lock, it is free.
record_lock_free() { flock -n "$canonical.lock" true || fail "the record's lock is still held: $1"; }

# The run waits for the record's lock: held, the seed waits, and the run
# ends only once it is released.
rm -f "$TRACE/locked"
mkdir -p "$(dirname "$canonical")"
hold_record_lock
"${clean[@]}" bash "$runner" -n 1 >"$scratch/lock-wait" 2>&1 &
lock_wait=$!
for ((i=0; i<600; i++)); do pgrep -f "flock -w 60 $canonical.lock elixir" >/dev/null && break; sleep 0.1; done
pgrep -f "flock -w 60 $canonical.lock elixir" >/dev/null || fail 'the seed never waited on the record lock'
sleep 1
alive "$lock_wait" || fail 'the run did not wait for the record lock'
release_record_lock
if wait "$lock_wait"; then :; else fail "the run that waited for the record lock failed: $(tail -n 3 "$scratch/lock-wait")"; fi
record_lock_free 'after the run that waited for it'

# A merge stopped part-way leaves the canonical record whole, and the
# runner says the merge did not complete. The merge waits on the record's
# lock, held here; stopped, it leaves nothing waiting for the lock.
rm -f "$TRACE/release" "$TRACE/recorded-1" "$TRACE/locked"
mkdir -p "$(dirname "$canonical")"
RECORD_AND_WAIT=1 "${clean[@]}" bash "$runner" -n 1 >"$scratch/unmerged" 2>&1 &
unmerged=$!
await_file "$TRACE/recorded-1"
unmerged_dir=$(tail -n 1 "$TRACE/prepared")
hold_record_lock
touch "$TRACE/release"
for ((i=0; i<600; i++)); do pgrep -f "failures-merge $unmerged_dir" >/dev/null && break; sleep 0.1; done
pgrep -f "failures-merge $unmerged_dir" >/dev/null || fail 'the merge never started'
sleep 1
stop_runner "$unmerged" TERM 60 "$scratch/unmerged"
if pgrep -f -- "$canonical.lock" >/dev/null; then fail "a stopped merge left a process waiting for the record lock: $(pgrep -af -- "$canonical.lock")"; fi
release_record_lock
record_lock_free "the test's holder left it held"
[ "$(record_sum)" = "$before" ] || fail 'a stopped merge changed the failures record'
grep -qx '==> the failures record merge did not complete; the canonical record was left as it was' "$scratch/unmerged" ||
  fail 'a stopped merge was not reported'
if grep -q 'left unmerged' "$scratch/unmerged"; then fail 'a started merge was reported as never started'; fi

# --- real Mix: the failures record and the split ----------------------------
# A two-application umbrella with no dependencies, its failures record
# configured as config/test.exs configures CYFR's, run through a `mix` that
# records each partition's arguments and runs the real one.
toy="$scratch/toy"
mkdir -p "$toy/config" "$scratch/realbin"
cat > "$toy/mix.exs" <<'TOY'
defmodule Toy.MixProject do
  use Mix.Project
  def project, do: [apps_path: "apps", apps: [:one, :two], version: "0.1.0", deps: []]
end
TOY
cat > "$toy/config/config.exs" <<'TOY'
import Config

umbrella_root = Path.expand("..", __DIR__)

config :ex_unit,
  failures_manifest_path:
    if(System.get_env("CYFR_TEST_RUN_ROOT"),
      do: Path.join(System.get_env("CYFR_TEST_RUN_ROOT"), "failures"),
      else:
        Path.join(
          Path.expand(System.get_env("MIX_BUILD_PATH") || "_build/test", umbrella_root),
          "test_failures"
        )
    )
TOY
for app in one two; do
  mkdir -p "$toy/apps/$app/lib" "$toy/apps/$app/test"
  module=One
  [ "$app" = one ] || module=Two
  ignore=
  [ "$app" = one ] || ignore=', test_ignore_filters: [&String.starts_with?(&1, "test/cluster/support/")]'
  cat > "$toy/apps/$app/mix.exs" <<TOY
defmodule $module.MixProject do
  use Mix.Project
  def project, do: [app: :$app, version: "0.1.0", build_path: "../../_build", config_path: "../../config/config.exs", deps_path: "../../deps", lockfile: "../../mix.lock", elixirc_paths: ["lib"]$ignore]
end
TOY
  echo "defmodule $module do end" > "$toy/apps/$app/lib/$app.ex"
  echo 'ExUnit.start()' > "$toy/apps/$app/test/test_helper.exs"
done
# A and B fail until their files exist; C, D and E pass.
for test in a:one b:two; do
  name=${test%%:*} app=${test#*:}
  printf 'defmodule %sTest do\n  use ExUnit.Case\n  test "%s", do: assert(File.exists?(Path.expand("../../../fix_%s", __DIR__)))\nend\n' \
    "$(printf '%s' "$name" | tr a-z A-Z)" "$name" "$name" > "$toy/apps/$app/test/${name}_test.exs"
done
printf 'defmodule CTest do\n  use ExUnit.Case\n  test "c", do: assert(true)\nend\n' > "$toy/apps/one/test/c_test.exs"
printf 'defmodule DTest do\n  use ExUnit.Case\n  test "d", do: assert(true)\nend\n' > "$toy/apps/one/test/d_test.exs"
mkdir -p "$toy/apps/two/test/sub" "$toy/apps/two/test/cluster/support"
printf 'defmodule ETest do\n  use ExUnit.Case\n  test "e", do: assert(true)\nend\n' > "$toy/apps/two/test/sub/e_test.exs"
# The copy of CYFR's cluster support: under a test path, matched by no load
# filter, ignored by the application's ignore filter, so never a test and
# never misnamed.
printf 'raise "support loaded as a test"\n' > "$toy/apps/two/test/cluster/support/peer.exs"
real_mix=$(PATH=$real_path command -v mix)
toy_trace="$scratch/toy-trace"
cat > "$scratch/realbin/mix" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = test ]; then printf '%s\n' "\${MIX_TEST_PARTITION:-?} \${*:2}" >> "$toy_trace"; fi
exec "$real_mix" "\$@"
SHIM
chmod +x "$scratch/realbin/mix"
weights="$scratch/weights.tsv"
printf '# the toy umbrella\n10\tapps/one/test/a_test.exs\n9\tapps/two/test/b_test.exs\n1\tapps/one/test/c_test.exs\n1\tapps/one/test/d_test.exs\n1\tapps/two/test/sub/e_test.exs\n' > "$weights"

# toy_run OUT ARGS...: the runner in the toy umbrella; sets toy_status.
toy_run() {
  local out=$1
  shift
  : > "$toy_trace"
  if (cd "$toy" && PATH="$scratch/realbin:$real_path" "${clean[@]}" -u MIX_BUILD_PATH bash "$runner" "$@") >"$out" 2>&1; then
    toy_status=0
  else
    toy_status=$?
  fi
  # The real elixir records nothing in $TRACE/prepared; the run's own
  # account names the directory it kept, which cleanup then removes.
  sed -n 's/^==> logs and disposable resources kept: //p' "$out" >> "$TRACE/prepared"
  printf '%s\n' "toy $* -> $toy_status"
}
# The canonical record's test names, sorted: "a b", or "-" when empty.
toy_record() {
  (cd "$toy" && PATH=$real_path elixir -e '
    {1, record} = "_build/test/test_failures" |> File.read!() |> :erlang.binary_to_term()
    names = record |> Map.keys() |> Enum.map(fn {_, name} -> String.trim_leading(to_string(name), "test ") end)
    IO.puts(if names == [], do: "-", else: names |> Enum.sort() |> Enum.join(" "))')
}
# The test files partition $1 was given, sorted, space-separated.
toy_files() {
  grep "^$1 " "$toy_trace" | tr ' ' '\n' | grep '_test\.exs' | sed 's|.*/||' | sort | tr '\n' ' ' || :
}

export CYFR_TEST_WEIGHTS="$weights"
toy_run "$scratch/toy-1" -n 2 -- --warnings-as-errors
[ "$toy_status" = 1 ] || fail 'the toy run with two failing tests passed'
[ "$(toy_record)" = 'a b' ] || fail "the record after the first run is $(toy_record)"
[ "$(toy_files 1)" = 'a_test.exs d_test.exs ' ] || fail "partition 1 had $(toy_files 1)"
[ "$(toy_files 2)" = 'b_test.exs c_test.exs e_test.exs ' ] || fail "partition 2 had $(toy_files 2)"
toy_run "$scratch/toy-2" -n 2 -- --warnings-as-errors --failed
[ "$toy_status" = 1 ] || fail 'the rerun of two failing tests passed'
{ [ "$(toy_files 1)" = 'a_test.exs ' ] && [ "$(toy_files 2)" = 'b_test.exs ' ]; } || fail "--failed assigned $(toy_files 1)/ $(toy_files 2)"
[ "$(grep -c '^Result: 0/1 passed' "$scratch/toy-2")" = 2 ] || fail 'the rerun did not run A and B'
[ "$(toy_record)" = 'a b' ] || fail "the record after the rerun is $(toy_record)"
touch "$toy/fix_a"
toy_run "$scratch/toy-3" -n 2 -- --warnings-as-errors --failed
[ "$toy_status" = 1 ] || fail 'the rerun with B failing passed'
{ [ "$(toy_files 1)" = 'a_test.exs ' ] && [ "$(toy_files 2)" = 'b_test.exs ' ]; } || fail 'the rerun after fixing A did not run A and B'
[ "$(toy_record)" = b ] || fail "the record after fixing A is $(toy_record)"
touch "$toy/fix_b"
toy_run "$scratch/toy-4" -n 2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail 'the rerun after fixing B failed'
{ [ "$(toy_files 1)" = 'b_test.exs ' ] && [ "$(toy_files 2)" = '' ]; } || fail "the rerun after fixing B ran $(toy_files 1)/ $(toy_files 2)"
[ "$(toy_record)" = - ] || fail "the record after fixing B is $(toy_record)"
toy_run "$scratch/toy-5" -n 2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail 'the empty rerun failed'
grep -qx '==> no partition started: the failures record names no test' "$scratch/toy-5" || fail 'the empty rerun was not named'
grep -q '^==> 2 partitions (2 not started: ' "$scratch/toy-5" || fail 'the empty rerun did not count its partitions as not started'
[ ! -s "$toy_trace" ] || fail 'the empty rerun started a partition'
toy_run "$scratch/toy-6" -n 1 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail 'the empty one-partition rerun failed'
grep -q 'There are no tests to run' "$scratch/toy-6" || grep -q 'no test to run' "$scratch/toy-6" || fail 'the one-partition rerun ran tests'
[ "$(cat "$toy_trace")" = '1 --no-compile --warnings-as-errors --failed' ] || fail "one partition was given $(cat "$toy_trace")"
toy_run "$scratch/toy-7" -n 2 -- --only nosuchtag
[ "$toy_status" = 1 ] || fail '--only selecting nothing passed'
grep -qx '==> the --only or --name-pattern selection ran no test' "$scratch/toy-7" || fail 'the empty --only selection was not named'

# The split: every file once, the same twice, the heaviest first, nothing
# of the ignored support; one partition passes its arguments through.
toy_run "$scratch/toy-8" -n 2 -- --warnings-as-errors
[ "$toy_status" = 0 ] || fail 'the passing toy run failed'
first=$(cat "$toy_trace")
[ "$(toy_files 1)$(toy_files 2)" = 'a_test.exs d_test.exs b_test.exs c_test.exs e_test.exs ' ] || fail 'the split is not the weighted one'
[ "$(grep -o '[a-z_/]*_test\.exs' "$toy_trace" | sort | uniq -d)" = '' ] || fail 'a file was assigned twice'
if grep -q 'cluster/support' "$toy_trace"; then fail 'an ignored file was assigned'; fi
toy_run "$scratch/toy-9" -n 2 -- --warnings-as-errors
[ "$(cat "$toy_trace")" = "$first" ] || fail 'the same inputs were split differently'
toy_run "$scratch/toy-10" -n 1 -- --warnings-as-errors --seed 0 apps/one/test
[ "$(cat "$toy_trace")" = '1 --no-compile --warnings-as-errors --seed 0 apps/one/test' ] || fail "one partition was given $(cat "$toy_trace")"
# A directory and a file outside it, and a file inside it: each file once.
toy_run "$scratch/toy-11" -n 2 -- --warnings-as-errors apps/one/test apps/two/test/b_test.exs apps/one/test/c_test.exs
[ "$toy_status" = 0 ] || fail 'the directory-and-files run failed'
[ "$(toy_files 1)$(toy_files 2)" = 'a_test.exs d_test.exs b_test.exs c_test.exs ' ] || fail "a directory and files were split as $(toy_files 1)/ $(toy_files 2)"
toy_run "$scratch/toy-12" -n 2 -- apps/one/lib
[ "$toy_status" = 1 ] && grep -qx '==> no test file in the named paths' "$scratch/toy-12" || fail 'a path without a test file did not fail'
# A ./ name and an absolute one with a line are the units their relative
# spellings make.
toy_run "$scratch/toy-paths" -n 2 -- --warnings-as-errors ./apps/one/test/c_test.exs:3 "$toy/apps/one/test/d_test.exs:3"
[ "$toy_status" = 0 ] || fail "the ./ and absolute names failed with $toy_status"
[ "$(sort "$toy_trace")" = "1 --no-compile --warnings-as-errors apps/one/test/c_test.exs:3
2 --no-compile --warnings-as-errors apps/one/test/d_test.exs:3" ] || fail "the ./ and absolute names were given as $(sort "$toy_trace")"
# The table: absent, equal weights in path order; named but missing, or
# malformed, refused.
unset CYFR_TEST_WEIGHTS
toy_run "$scratch/toy-13" -n 2 -- --warnings-as-errors
[ "$(toy_files 1)" = 'a_test.exs d_test.exs e_test.exs ' ] || fail "equal weights gave partition 1 $(toy_files 1)"
[ "$(toy_files 2)" = 'b_test.exs c_test.exs ' ] || fail "equal weights gave partition 2 $(toy_files 2)"
CYFR_TEST_WEIGHTS="$scratch/absent.tsv" toy_run "$scratch/toy-14" -n 2
[ "$toy_status" = 64 ] || fail 'a missing named table was not refused'
printf '10 apps/one/test/a_test.exs\n' > "$scratch/malformed.tsv"
CYFR_TEST_WEIGHTS="$scratch/malformed.tsv" toy_run "$scratch/toy-15" -n 2
[ "$toy_status" = 64 ] || fail 'a malformed table was not refused'
# A misnamed file under test/ warns, and fails under --warnings-as-errors.
touch "$toy/apps/one/test/oops_tests.exs"
toy_run "$scratch/toy-16" -n 2
[ "$toy_status" = 0 ] && grep -q '^==> test files that neither the load nor the ignore filters classify:' "$scratch/toy-16" ||
  fail 'a misnamed file did not warn'
toy_run "$scratch/toy-17" -n 2 -- --warnings-as-errors
[ "$toy_status" = 1 ] && grep -qx '==> refused under --warnings-as-errors, as Mix refuses them' "$scratch/toy-17" ||
  fail 'a misnamed file passed under --warnings-as-errors'
rm "$toy/apps/one/test/oops_tests.exs"
# A record of :all (a suite that failed to load) reruns the whole suite:
# --failed is dropped, since Mix would read the record per application in
# one VM and run the first application's files alone, and with more than
# one partition every file is assigned.
toy_all() { (cd "$toy" && PATH=$real_path elixir -e 'File.write!("_build/test/test_failures", :erlang.term_to_binary({1, :all}))'); }
toy_all
toy_run "$scratch/toy-all" -n 2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail "the rerun of an :all record failed with $toy_status"
[ "$(toy_files 1)$(toy_files 2)" = 'a_test.exs d_test.exs e_test.exs b_test.exs c_test.exs ' ] || fail "an :all record assigned $(toy_files 1)/ $(toy_files 2)"
if grep -q -- '--failed' "$toy_trace"; then fail "an :all record kept --failed: $(cat "$toy_trace")"; fi
toy_all
toy_run "$scratch/toy-all-1" -n 1 -- --warnings-as-errors --failed
[ "$(cat "$toy_trace")" = '1 --no-compile --warnings-as-errors' ] || fail "one partition was given $(cat "$toy_trace")"
[ "$toy_status" = 0 ] && [ "$(toy_record)" = - ] || fail "one partition's rerun of an :all record left $(toy_record) with $toy_status"
# --- shards: one split, its partitions run once between the shards ---------
# With the table, four partitions are A; B; C and E; D. Shard 1 of 2 runs
# partitions 1 and 3, shard 2 runs 2 and 4, each with the arguments the
# unsharded run gives it, and accounts for no other.
export CYFR_TEST_WEIGHTS="$weights"
rm -f "$toy/fix_a" "$toy/fix_b"
toy_run "$scratch/toy-whole" -n 4 -- --warnings-as-errors
[ "$toy_status" = 1 ] || fail 'the unsharded run with two failing tests passed'
whole=$(sort "$toy_trace")
toy_shard_files() { printf '%s|%s|%s|%s' "$(toy_files 1)" "$(toy_files 2)" "$(toy_files 3)" "$(toy_files 4)"; }
[ "$(toy_shard_files)" = 'a_test.exs |b_test.exs |c_test.exs e_test.exs |d_test.exs ' ] || fail "four partitions were $(toy_shard_files)"
toy_run "$scratch/toy-shard-1" -n 4 --shard 1/2 -- --warnings-as-errors
[ "$toy_status" = 1 ] || fail 'shard 1/2 passed with A failing'
[ "$(toy_shard_files)" = 'a_test.exs ||c_test.exs e_test.exs |' ] || fail "shard 1/2 ran $(toy_shard_files)"
shards=$(cat "$toy_trace")
toy_run "$scratch/toy-shard-2" -n 4 --shard 2/2 -- --warnings-as-errors
[ "$toy_status" = 1 ] || fail 'shard 2/2 passed with B failing'
[ "$(toy_shard_files)" = '|b_test.exs ||d_test.exs ' ] || fail "shard 2/2 ran $(toy_shard_files)"
[ "$(printf '%s\n%s\n' "$shards" "$(cat "$toy_trace")" | sort)" = "$whole" ] ||
  fail 'the shards did not run the unsharded partitions, each once'
grep -qx '==> 4 partitions, shard 2/2'"'"'s 2, sqlite, [0-9]*s wall, exit 1' "$scratch/toy-shard-2" ||
  fail "shard 2/2's summary: $(grep '^==> 4 partitions' "$scratch/toy-shard-2")"
if grep -qxE '==> partition (1|3)/4' "$scratch/toy-shard-2"; then fail "shard 2/2 accounted for shard 1's partitions"; fi
[ "$(toy_record)" = 'a b' ] || fail "the record after both shards is $(toy_record)"
# --failed in a shard reruns the recorded failures among its own files and
# leaves the other shard's in the record. B alone recorded stays shard 2's:
# narrowed before the split it would fall to partition 1, shard 1's.
touch "$toy/fix_a"
toy_run "$scratch/toy-shard-failed-1" -n 4 --shard 1/2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail 'the shard 1/2 rerun after fixing A failed'
[ "$(toy_shard_files)" = 'a_test.exs |||' ] || fail "the shard 1/2 rerun ran $(toy_shard_files)"
[ "$(toy_record)" = b ] || fail "the record after shard 1's rerun is $(toy_record)"
toy_run "$scratch/toy-shard-failed-none" -n 4 --shard 1/2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail 'a shard with no recorded failure of its own failed'
[ ! -s "$toy_trace" ] || fail "a shard with no recorded failure of its own ran $(cat "$toy_trace")"
grep -qx '==> shard 1/2: no test file falls to its partitions, so nothing ran' "$scratch/toy-shard-failed-none" ||
  fail 'a shard with nothing to rerun did not say so'
toy_run "$scratch/toy-shard-failed-2" -n 4 --shard 2/2 -- --warnings-as-errors --failed
[ "$toy_status" = 1 ] || fail 'the shard 2/2 rerun with B failing passed'
[ "$(toy_shard_files)" = '|b_test.exs ||' ] || fail "the shard 2/2 rerun ran $(toy_shard_files)"
touch "$toy/fix_b"
toy_run "$scratch/toy-shard-failed-3" -n 4 --shard 2/2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail 'the shard 2/2 rerun after fixing B failed'
[ "$(toy_record)" = - ] || fail "the record after both shards' reruns is $(toy_record)"
toy_run "$scratch/toy-shard-failed-empty" -n 4 --shard 2/2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] && grep -qx '==> no partition started: the failures record names no test' "$scratch/toy-shard-failed-empty" ||
  fail 'a shard rerun of an empty record did not pass saying so'
# A record of :all (the whole suite's rerun) is settled by no shard: shard
# 1's --failed reruns its own files and passes, and shard 2 still owes and
# reruns its own, B among them, as does every shard until a whole run.
rm -f "$toy/fix_b"
toy_raw_record() { (cd "$toy" && PATH=$real_path elixir -e 'IO.inspect("_build/test/test_failures" |> File.read!() |> :erlang.binary_to_term())'); }
toy_all
toy_run "$scratch/toy-shard-all-1" -n 4 --shard 1/2 -- --warnings-as-errors --failed
[ "$toy_status" = 0 ] || fail "shard 1/2's rerun of an :all record failed with $toy_status"
[ "$(toy_shard_files)" = 'a_test.exs ||c_test.exs e_test.exs |' ] || fail "shard 1/2's rerun of an :all record ran $(toy_shard_files)"
[ "$(toy_raw_record)" = '{1, :all}' ] || fail "shard 1/2's rerun settled the :all record as $(toy_raw_record)"
grep -qxF "==> the failures record stays :all, the whole suite's rerun still owed: this run had shard 1/2" "$scratch/toy-shard-all-1" ||
  fail "shard 1/2's rerun did not say why the record stays :all"
toy_run "$scratch/toy-shard-all-2" -n 4 --shard 2/2 -- --warnings-as-errors --failed
[ "$toy_status" = 1 ] || fail "shard 2/2 did not rerun its broken B after shard 1 under an :all record: $toy_status"
[ "$(toy_shard_files)" = '|b_test.exs ||d_test.exs ' ] || fail "shard 2/2's rerun of an :all record ran $(toy_shard_files)"
[ "$(toy_raw_record)" = '{1, :all}' ] || fail "shard 2/2's rerun settled the :all record as $(toy_raw_record)"
# A whole run settles it into what failed.
toy_run "$scratch/toy-shard-all-whole" -n 4 -- --warnings-as-errors --failed
[ "$toy_status" = 1 ] && [ "$(toy_record)" = b ] || fail "a whole rerun of an :all record left $(toy_raw_record) with $toy_status"
# Any other run of an :all record leaves it owed and says why: Mix's own
# --partitions, a --dry-run and a run --max-failures cuts short each leave
# files unrun, on one partition or several. A whole rerun still runs B.
for extra in '--partitions 2' --dry-run '--max-failures 1 --seed 0'; do
  for n in 1 2; do
    toy_all
    # shellcheck disable=SC2086
    toy_run "$scratch/toy-all-partial" -n "$n" -- --warnings-as-errors --failed $extra
    [ "$(toy_raw_record)" = '{1, :all}' ] || fail "a -n $n run with $extra settled the :all record as $(toy_raw_record)"
    grep -qxF "==> the failures record stays :all, the whole suite's rerun still owed: this run had Mix's ${extra%% *}" "$scratch/toy-all-partial" ||
      fail "a -n $n run with $extra did not say why the record stays :all"
  done
done
toy_run "$scratch/toy-all-after" -n 1 -- --warnings-as-errors --failed
[ "$toy_status" = 1 ] && [ "$(toy_record)" = b ] || fail "the whole rerun after partial runs left $(toy_raw_record) with $toy_status"
# Mix's --profile-require loads the files without running their tests,
# so a run with it is partial too: with the first application holding no
# test file, it keeps the :all record and says why, and the rerun after it
# still runs the broken B. Last: it removes the first application's tests.
rm "$toy/apps/one/test/a_test.exs" "$toy/apps/one/test/c_test.exs" "$toy/apps/one/test/d_test.exs"
toy_all
toy_run "$scratch/toy-all-profile" -n 1 -- --warnings-as-errors --failed --profile-require time
[ "$(toy_raw_record)" = '{1, :all}' ] || fail "a run with --profile-require settled the :all record as $(toy_raw_record)"
grep -qxF "==> the failures record stays :all, the whole suite's rerun still owed: this run had Mix's --profile-require" "$scratch/toy-all-profile" ||
  fail 'a run with --profile-require did not say why the record stays :all'
toy_run "$scratch/toy-all-profile-after" -n 1 -- --warnings-as-errors --failed
[ "$toy_status" = 1 ] && [ "$(toy_record)" = b ] || fail "the rerun after --profile-require left $(toy_raw_record) with $toy_status"
echo 'partition runner tests passed'
