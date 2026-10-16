#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# How red the branch is, per job: scripts/ci/red-rate.sh [-n RUNS] [-b BRANCH] [-w WORKFLOW]
#
# On demand only: nothing schedules it. It reads the last RUNS (default 30)
# runs of WORKFLOW (default test.yml) on BRANCH (default main) with
#   gh run list --workflow WORKFLOW --branch BRANCH --limit RUNS --json ...
# and every attempt of each completed run with
#   gh run view ID --attempt A --json jobs
# then prints a header and one tab-separated row per job name, sorted:
#   job  first_pass  first_fail  first_cancelled  reruns  rerun_pass  rerun_fail  rerun_cancelled
# first_*: the job's conclusion on the run's first attempt, the one the
# push itself produced. pass is `success`, cancelled is `cancelled`, and
# every other conclusion a completed run can carry (`failure`,
# `timed_out`, `startup_failure`, `action_required`, a job left without
# one) is a fail; a `skipped` job is counted nowhere. A later attempt
# never changes the first attempt's counts.
# reruns: how many times the job ran again on a later attempt of a run,
# a job of a later attempt being one whose id no earlier attempt had, so
# a re-run of the failed jobs alone counts only those; rerun_*: those
# runs' conclusions, classed as above.
# Runs not yet completed are left out of every count and named on the
# `# runs:` line that ends the output.
#
# A gh call that fails ends the script with exit 1 and gh's own stderr;
# nothing is counted from a partial answer. Usage errors exit 64.
set -euo pipefail

RUNS=30; BRANCH=main; WORKFLOW=test.yml
usage() { echo "usage: $0 [-n RUNS] [-b BRANCH] [-w WORKFLOW]" >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|-b|-w)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      case "$1" in -n) RUNS=$2 ;; -b) BRANCH=$2 ;; -w) WORKFLOW=$2 ;; esac
      shift 2 ;;
    -h|--help) usage; exit 64 ;;
    *) usage; exit 64 ;;
  esac
done
case "$RUNS" in ''|*[!0-9]*|0*) echo 'red-rate: RUNS is a positive decimal count' >&2; usage; exit 64 ;; esac
[ -n "$BRANCH" ] && [ -n "$WORKFLOW" ] || { usage; exit 64; }
for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "red-rate: $tool is required" >&2; exit 69; }
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/cyfr-red-rate.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

# One line per run: id, attempt count, status, conclusion.
gh run list --workflow "$WORKFLOW" --branch "$BRANCH" --limit "$RUNS" \
  --json databaseId,attempt,status,conclusion > "$scratch/runs.json" ||
  { echo "red-rate: gh run list failed" >&2; exit 1; }
# The answer is an array of runs, each with a numeric id, a status and an
# attempt count of one or more; anything else (an object, a run without
# them, a completed run with no attempt) is refused rather than counted as
# nothing.
jq -r '
  if type != "array" then error("not an array of runs") else .[] end
  | if type != "object" or (.databaseId | type) != "number" or (.status | type) != "string"
       or (.attempt | type) != "number" or .attempt < 1
    then error("a run without a numeric id, a status and an attempt count of 1 or more: \(.)")
    else [.databaseId, .attempt, .status, (.conclusion // "")] | @tsv end' \
  "$scratch/runs.json" > "$scratch/runs.tsv" ||
  { echo 'red-rate: gh run list answered something other than a list of runs' >&2; exit 1; }

listed=0; counted=0; pending=()
: > "$scratch/jobs.tsv"
while IFS=$'\t' read -r id attempts status _conclusion; do
  listed=$((listed + 1))
  if [ "$status" != completed ]; then pending+=("$id"); continue; fi
  counted=$((counted + 1))
  for ((a = 1; a <= attempts; a++)); do
    gh run view "$id" --attempt "$a" --json jobs > "$scratch/attempt.json" ||
      { echo "red-rate: gh run view $id --attempt $a failed" >&2; exit 1; }
    # The answer holds a non-empty array of jobs, each with a name and a
    # numeric id (a completed attempt ran at least one job); anything else
    # is refused. One row per job: run, attempt, job id, conclusion, name,
    # the name last, as it may hold anything but a newline.
    jq -r --arg run "$id" --arg attempt "$a" '
      if (.jobs | type) != "array" or .jobs == [] then error("no job list") else .jobs[] end
      | if type != "object" or (.name | type) != "string" or (.databaseId | type) != "number"
        then error("a job without a name and a numeric id: \(.)")
        else [$run, $attempt, (.databaseId | tostring), (.conclusion // "unfinished"), .name] | @tsv end' \
      "$scratch/attempt.json" >> "$scratch/jobs.tsv" ||
      { echo "red-rate: gh run view $id --attempt $a answered no job list" >&2; exit 1; }
  done
done < "$scratch/runs.tsv"

printf 'job\tfirst_pass\tfirst_fail\tfirst_cancelled\treruns\trerun_pass\trerun_fail\trerun_cancelled\n'
LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3n "$scratch/jobs.tsv" |
  awk -F '\t' '
    function class(c) { return c == "success" ? "pass" : c == "cancelled" ? "cancelled" : "fail" }
    {
      run = $1; attempt = $2 + 0; id = $3; conclusion = $4; name = $5
      if (conclusion == "skipped") next
      if (attempt == 1) { first[name, class(conclusion)]++; seen[run, id] = 1; names[name] = 1; next }
      # A job of a later attempt whose id an earlier attempt already had
      # was not run again.
      if ((run, id) in seen) next
      seen[run, id] = 1; names[name] = 1
      reruns[name]++; rerun[name, class(conclusion)]++
    }
    END {
      for (name in names)
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", name,
          first[name, "pass"], first[name, "fail"], first[name, "cancelled"],
          reruns[name], rerun[name, "pass"], rerun[name, "fail"], rerun[name, "cancelled"]
    }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1
if [ "${#pending[@]}" -gt 0 ]; then
  printf '# runs: %d listed, %d completed and counted, %d not completed and left out: %s\n' \
    "$listed" "$counted" "${#pending[@]}" "${pending[*]}"
else
  printf '# runs: %d listed, %d completed and counted\n' "$listed" "$counted"
fi
