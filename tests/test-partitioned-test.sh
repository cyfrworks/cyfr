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
  if [ -f "$scratch/trace/prepared" ]; then
    while IFS= read -r directory; do
      case "$directory" in /tmp/cyfr-t.*|/private/tmp/cyfr-t.*)
        rm -rf "$directory"
        if [ -n "${CYFR_RUNNER_TEST_EVIDENCE:-}" ]; then
          [ ! -e "$directory" ] || result=1
          printf '%s\t%s\n' "$directory" "$([ ! -e "$directory" ] && echo absent || echo present)" >> "$CYFR_RUNNER_TEST_EVIDENCE/cleanup.tsv"
        fi ;;
      esac
    done < "$scratch/trace/prepared"
  fi
  rm -rf "$scratch"
  return "$result"
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
        [ "${NOOP_DROP:-0}" != 1 ] || exit 0
        echo "$CYFR_DATABASE_URL" >> "$TRACE/dropped"
        [ "${FAIL_CLEANUP:-0}" != 1 ] || exit 9
        rm "$CYFR_TEST_RUN_ROOT/database-created" ;;
    esac ;;
  test)
    key="$(basename "$(dirname "$CYFR_TEST_RUN_ROOT")")-p$MIX_TEST_PARTITION"
    printf '%s\n' "$TMPDIR" "$CYFR_TEST_RUN_ROOT" "${CYFR_DATABASE_URL:-}" "${CYFR_CLUSTER_DATABASE_URL:-}" "$@" > "$TRACE/$key"
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

# Report through the public runner with actual tracked fixture indexes. The
# early diagnostic payloads lie beyond the existing failure tail; these checks
# concern the added projection, not the raw tail's pre-existing exposure.
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
for tool in bash sh dirname basename mktemp nproc sysctl grep head tail sed sort wc tr cat rm \
  sleep cmp find mkdir awk readlink uname cut expr getconf cp; do
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
      bash "$runner" -n "$parts" -a "$adapter" -- --warnings-as-errors "$@") >"$account" 2>&1; then
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
      exec bash "$runner" -n 1 -a "$adapter" -- --warnings-as-errors) >"$account" 2>&1 &
    report_cancel=$!
    for ((i=0;i<200;i++)); do [ -f "$TRACE/diagnostic-ready" ] && break; sleep 0.05; done
    [ -f "$TRACE/diagnostic-ready" ] || fail "$dependency reporting dependency never started"
    kill -TERM "$report_cancel"
    if wait "$report_cancel"; then result=0; else result=$?; fi
    report_cancel=
    [ "$result" = 143 ] || fail "$dependency reporting cancellation exited $result"
    printf '%s\n' "$result" > "$scratch/cases/$adapter-cancel-$dependency.exit"
    sleeper=$(cat "$TRACE/diagnostic-sleeper")
    for ((i=0;i<50;i++)); do kill -0 "$sleeper" 2>/dev/null || break; sleep 0.02; done
    if kill -0 "$sleeper" 2>/dev/null; then fail "cancelled $dependency descendant survived"; fi
    kept=$(sed -n 's/^==> logs and disposable resources kept: //p' "$account")
    [ ! -e "$kept/p1/database-created" ] || fail "$dependency cancellation retained database"
    [ ! -e "$kept/p1.env" ] || fail "$dependency cancellation retained environment"
    echo "$adapter-cancel-$dependency passed (exit $result)"
  done
done
echo 'partition runner tests passed'
