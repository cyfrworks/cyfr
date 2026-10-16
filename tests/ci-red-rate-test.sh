#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/ci/red-rate.sh, run against a canned `gh`:
# a script on PATH that answers `run list` and `run view ID --attempt A
# --json jobs` from JSON files of one case, refusing any other spelling,
# an attempt it has no file for, or a filter other than the one the case
# expects. So the cases show what the script asks gh as well as what it
# prints.
#
# Usage: bash tests/ci-red-rate-test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
red_rate="$root/scripts/ci/red-rate.sh"
tmp=${TMPDIR:-/tmp}
scratch=$(mktemp -d "${tmp%/}/cyfr-red-rate-test.XXXXXX") || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
trap 'rm -rf "$scratch"' EXIT

failures=0
cases=0
pass() { cases=$((cases + 1)); echo "PASS: $1"; }
fail() {
  cases=$((cases + 1))
  echo "FAIL: $1"
  echo "  exit: $code"
  sed 's/^/  stdout: /' "$scratch/out"
  sed 's/^/  stderr: /' "$scratch/err"
  failures=$((failures + 1))
}
check() { if "$@"; then pass "$label"; else fail "$label"; fi; }

# --- the canned gh -----------------------------------------------------------

mkdir -p "$scratch/bin"
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
# Canned gh. GH_CANNED is the case's directory: list.json answers
# `run list`, view-ID-A.json answers `run view ID --attempt A --json jobs`.
# GH_EXPECT_WORKFLOW, GH_EXPECT_BRANCH and GH_EXPECT_LIMIT are the filter
# `run list` must carry. Every call is appended to GH_CANNED/calls.
set -uo pipefail
printf '%s\n' "$*" >> "$GH_CANNED/calls"
[ "${1:-}" = run ] || { echo "canned gh: not a run command: $*" >&2; exit 2; }
case "${2:-}" in
  list)
    shift 2
    workflow=; branch=; limit=; json=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --workflow) workflow=${2:-}; shift 2 ;;
        --branch) branch=${2:-}; shift 2 ;;
        --limit) limit=${2:-}; shift 2 ;;
        --json) json=${2:-}; shift 2 ;;
        *) echo "canned gh: run list does not take: $1" >&2; exit 2 ;;
      esac
    done
    [ "$workflow" = "$GH_EXPECT_WORKFLOW" ] && [ "$branch" = "$GH_EXPECT_BRANCH" ] && [ "$limit" = "$GH_EXPECT_LIMIT" ] ||
      { echo "canned gh: run list filtered --workflow '$workflow' --branch '$branch' --limit '$limit'" >&2; exit 2; }
    for field in databaseId attempt status; do
      case ",$json," in *",$field,"*) ;; *) echo "canned gh: run list --json lacks $field" >&2; exit 2 ;; esac
    done
    [ -f "$GH_CANNED/list.json" ] || { echo "canned gh: HTTP 502: the list is unavailable" >&2; exit 1; }
    cat "$GH_CANNED/list.json" ;;
  view)
    shift 2
    id=; attempt=; json=
    case "${1:-}" in ''|-*) ;; *) id=$1; shift ;; esac
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --attempt|-a) attempt=${2:-}; shift 2 ;;
        --json) json=${2:-}; shift 2 ;;
        *) echo "canned gh: run view does not take: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$id" ] && [ -n "$attempt" ] && [ "$json" = jobs ] ||
      { echo "canned gh: run view wants ID --attempt A --json jobs, got: id='$id' attempt='$attempt' json='$json'" >&2; exit 2; }
    [ -f "$GH_CANNED/view-$id-$attempt.json" ] ||
      { echo "canned gh: HTTP 404: run $id has no attempt $attempt" >&2; exit 1; }
    cat "$GH_CANNED/view-$id-$attempt.json" ;;
  *) echo "canned gh: not a run subcommand: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$scratch/bin/gh"

# A case directory with the canned answers; `run` executes the script
# against it with the filter the case expects.
case_dir=
new_case() {
  case_dir="$scratch/case-$((++cases_made))"
  mkdir -p "$case_dir"
  : > "$case_dir/calls"
}
cases_made=0
run() {
  PATH="$scratch/bin:$PATH" GH_CANNED="$case_dir" \
    GH_EXPECT_WORKFLOW="${expect_workflow:-test.yml}" GH_EXPECT_BRANCH="${expect_branch:-main}" \
    GH_EXPECT_LIMIT="${expect_limit:-30}" \
    bash "$red_rate" "$@" > "$scratch/out" 2> "$scratch/err"
  code=$?
}
has_err() { grep -qF -- "$1" "$scratch/err"; }
asked() { grep -qxF -- "$1" "$case_dir/calls"; }
not_asked() { ! grep -qF -- "$1" "$case_dir/calls"; }
stdout_is() { [ "$code" -eq 0 ] && diff -u <(printf '%s' "$1") "$scratch/out" > "$scratch/diff" || { cat "$scratch/diff" 2>/dev/null; return 1; }; }
failed_with() { [ "$code" -eq 1 ] && has_err "$1" && [ ! -s "$scratch/out" ]; }

# A job record of one attempt. job ID CONCLUSION NAME
job() { printf '{"databaseId":%s,"conclusion":%s,"status":"completed","name":"%s"}' "$1" "$([ "$2" = null ] && echo null || printf '"%s"' "$2")" "$3"; }
jobs() { local IFS=,; printf '{"jobs":[%s]}' "$*"; }
S='Elixir Tests (sqlite)'
B='Browser harness'
T='Static checks'

# Four runs on main, newest first, as `gh run list` lists them:
#   101  two attempts: the SQLite tests failed first, then every job was
#        re-run and passed;
#   102  three attempts: the SQLite tests failed, were re-run alone and
#        failed again, then were re-run alone and passed; the second
#        attempt's list also repeats the browser job under its first
#        attempt's id, as a job that did not run again;
#   103  cancelled on its first attempt, with the static job skipped;
#   104  still in progress: not counted.
# Two conclusions a completed run can carry beside success, failure and
# cancelled appear too: a timed-out job and one left without a conclusion.
main_case() {
  new_case
  cat > "$case_dir/list.json" <<'JSON'
[{"databaseId":104,"attempt":1,"status":"in_progress","conclusion":null},
 {"databaseId":103,"attempt":1,"status":"completed","conclusion":"cancelled"},
 {"databaseId":102,"attempt":3,"status":"completed","conclusion":"success"},
 {"databaseId":101,"attempt":2,"status":"completed","conclusion":"success"}]
JSON
  jobs "$(job 1 failure "$S")" "$(job 2 success "$B")" "$(job 3 success "$T")" > "$case_dir/view-101-1.json"
  jobs "$(job 11 success "$S")" "$(job 12 success "$B")" "$(job 13 success "$T")" > "$case_dir/view-101-2.json"
  jobs "$(job 21 timed_out "$S")" "$(job 22 success "$B")" "$(job 23 null "$T")" > "$case_dir/view-102-1.json"
  jobs "$(job 31 failure "$S")" "$(job 22 success "$B")" > "$case_dir/view-102-2.json"
  jobs "$(job 41 success "$S")" > "$case_dir/view-102-3.json"
  jobs "$(job 51 cancelled "$S")" "$(job 52 cancelled "$B")" "$(job 53 skipped "$T")" > "$case_dir/view-103-1.json"
}

expected_main=$(cat <<'OUT'
job	first_pass	first_fail	first_cancelled	reruns	rerun_pass	rerun_fail	rerun_cancelled
Browser harness	2	0	1	1	1	0	0
Elixir Tests (sqlite)	0	2	1	3	2	1	0
Static checks	1	1	0	1	1	0	0
# runs: 4 listed, 3 completed and counted, 1 not completed and left out: 104
OUT
)

label="first-attempt failures stay counted after a later success; a rerun counts only the jobs that ran again; cancellation and in-progress runs are kept apart"
main_case
expect_limit=4 run -n 4
check stdout_is "$expected_main"$'\n'

asked_every_attempt() {
  local call
  asked "run list --workflow test.yml --branch main --limit 4 --json databaseId,attempt,status,conclusion" || return 1
  for call in "101 --attempt 1" "101 --attempt 2" "102 --attempt 1" "102 --attempt 2" "102 --attempt 3" "103 --attempt 1"; do
    asked "run view $call --json jobs" || { echo "  not asked: run view $call --json jobs"; return 1; }
  done
}
label="the script reads the list with the filter it was given and every attempt of every completed run"
check asked_every_attempt
label="a run in progress is never asked for its jobs"
check not_asked "run view 104"

label="the defaults reach gh: 30 runs of test.yml on main"
main_case
run
check stdout_is "$expected_main"$'\n'

label="another branch, workflow and count reach gh as given"
main_case
expect_workflow=release.yml expect_branch=release expect_limit=7 run -w release.yml -b release -n 7
check stdout_is "$expected_main"$'\n'

label="a run view that fails ends the script with no counts and gh's error"
main_case
rm "$case_dir/view-102-3.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 102 --attempt 3 failed"
label="  ...and the canned gh said why"
check has_err "HTTP 404: run 102 has no attempt 3"

label="a run list that fails ends the script with no counts"
new_case
run
check failed_with "red-rate: gh run list failed"

label="a run list that is not a list of runs is refused"
new_case
printf 'rate limited\n' > "$case_dir/list.json"
run
check failed_with "answered something other than a list of runs"

label="a run view without a job list is refused"
main_case
printf '{"message":"Not Found"}\n' > "$case_dir/view-101-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 101 --attempt 1 answered no job list"

label="an empty list prints the header and the count"
new_case
printf '[]\n' > "$case_dir/list.json"
run
check stdout_is $'job\tfirst_pass\tfirst_fail\tfirst_cancelled\treruns\trerun_pass\trerun_fail\trerun_cancelled\n# runs: 0 listed, 0 completed and counted\n'

usage() { [ "$code" -eq 64 ] && has_err "usage:" && [ ! -s "$scratch/out" ] && [ ! -s "$case_dir/calls" ]; }
label="a count that is not a positive number is a usage error before gh is asked"
new_case
run -n 0
check usage
label="a flag the script does not know is a usage error before gh is asked"
new_case
run --runs 3
check usage
label="a flag without its value is a usage error before gh is asked"
new_case
run -b
check usage

# Malformed but valid JSON must not produce success-shaped counts.
label="a JSON object is not a run list"
new_case
printf '{}\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="a run without an id, a status or an attempt count is refused"
new_case
printf '[{"attempt":1,"status":"completed","conclusion":"success"}]\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="a completed run with zero attempts is refused"
new_case
printf '[{"databaseId":101,"attempt":0,"status":"completed","conclusion":"success"}]\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="a JSON object is not a job list"
main_case
printf '{"jobs":{}}\n' > "$case_dir/view-101-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 101 --attempt 1 answered no job list"

label="an empty job list for a completed attempt is refused"
main_case
printf '{"jobs":[]}\n' > "$case_dir/view-102-2.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 102 --attempt 2 answered no job list"

label="a job without a name or a numeric id is refused"
main_case
printf '{"jobs":[{"conclusion":"success","name":"Static checks"}]}\n' > "$case_dir/view-103-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 103 --attempt 1 answered no job list"

# Review controls: a malformed reader response must never produce counts.
label="an attempt view that is not an object is refused"
main_case
printf '[]\n' > "$case_dir/view-101-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 101 --attempt 1 answered no job list"

label="a run missing attempt is refused"
new_case
printf '[{"databaseId":101,"status":"completed","conclusion":"success"}]\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="a run conclusion that is a number is refused"
main_case
printf '[{"databaseId":101,"attempt":1,"status":"completed","conclusion":42}]\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="a job conclusion that is a number is refused"
main_case
printf '{"jobs":[{"databaseId":1,"name":"Static checks","conclusion":42}]}\n' > "$case_dir/view-101-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 101 --attempt 1 answered no job list"

label="a job conclusion that is a boolean is refused"
main_case
printf '{"jobs":[{"databaseId":1,"name":"Static checks","conclusion":false}]}\n' > "$case_dir/view-101-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 101 --attempt 1 answered no job list"

label="a fractional attempt count is refused"
main_case
printf '[{"databaseId":101,"attempt":1.5,"status":"completed","conclusion":"success"}]\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="an empty run-list response is refused"
new_case
: > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="an empty attempt response is refused"
main_case
: > "$case_dir/view-101-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 101 --attempt 1 answered no job list"

label="a null job conclusion is a fail, as a job left without one"
main_case
printf '{"jobs":[{"databaseId":1,"name":"Static checks","conclusion":null}]}\n' > "$case_dir/view-103-1.json"
expect_limit=4 run -n 4
check stdout_is $'job\tfirst_pass\tfirst_fail\tfirst_cancelled\treruns\trerun_pass\trerun_fail\trerun_cancelled\nBrowser harness\t2\t0\t0\t1\t1\t0\t0\nElixir Tests (sqlite)\t0\t2\t0\t3\t2\t1\t0\nStatic checks\t1\t2\t0\t1\t1\t0\t0\n# runs: 4 listed, 3 completed and counted, 1 not completed and left out: 104\n'

label="multiple run-list JSON documents are refused"
new_case
printf '[]\n[]\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="a malformed first run-list document is not hidden by the last"
new_case
printf '{}\n[]\n' > "$case_dir/list.json"
run
check failed_with "red-rate: gh run list answered something other than a list of runs"

label="multiple attempt JSON documents are refused"
main_case
printf '{"jobs":[{"databaseId":1,"name":"Static checks","conclusion":"success"}]}\n{"jobs":[{"databaseId":1,"name":"Static checks","conclusion":"success"}]}\n' > "$case_dir/view-101-1.json"
expect_limit=4 run -n 4
check failed_with "red-rate: gh run view 101 --attempt 1 answered no job list"

echo "$cases cases, $failures failures"
[ "$failures" -eq 0 ]
