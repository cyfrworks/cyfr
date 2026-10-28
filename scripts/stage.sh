#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Runs the checks a stage names: scripts/stage.sh [-l LOGDIR] [-n] STAGE [-- PATHS]
#
# The stages are save (after an edit), handoff (before a change is
# reported ready), pull-request (the gate, CI's checks on this host, for
# offline work and reproducing a CI failure: the pull request's run on
# GitHub is the check), release (the gate's close) and nightly. What each
# runs is scripts/stages.tsv, one row per check:
#   stage<TAB>check<TAB>lane<TAB>hold<TAB>when<TAB>command
#   stage    one of the five above
#   check    [a-z0-9-]+, unique within its stage
#   lane     none, which runs directly and admits only reads of seconds
#            (`mix format --check-formatted`, `git grep`); or scoped,
#            proof or exclusive, the scripts/heavy-check.sh lane it queues
#            in (-s, -p or no flag)
#   hold     - for none, else heavy-check's -t in seconds
#   when     always; tests, when the stage's touched tests are not none;
#            or comma-separated path globs with Git's :(glob) meaning,
#            when a path of the changed set matches one. Only save and
#            handoff rows take tests or globs.
#   command  the rest of the line, run as `bash -c` from the worktree's
#            root
# Lines that start with #, and blank lines, are skipped. The whole table
# is read before any row runs, and the rows of a stage run in its order,
# every one of them whatever an earlier one ended with.
#
# The changed set is every path the diff from the base to the working
# tree adds, modifies or deletes, renames as a deletion and an addition,
# and every untracked file that is not ignored. The base is HEAD for save
# and `git merge-base HEAD origin/main` (else main) for handoff; STAGE_BASE
# overrides either. A deleted path selects rows as any other does.
# The touched tests are the changed apps/*/test/**/*_test.exs files that
# exist, and apps/<app>/test/<path>_test.exs for each changed
# apps/<app>/lib/<path>.ex, deleted or not, where that test exists; never a
# deleted path, nothing under apps/cyfr/test/cluster (its suite needs
# -a postgres --only cluster and an object store); sorted, each once.
# PATHS after `--` replace them. A touched path with whitespace is refused.
#
# Each row's command sees STAGE, STAGE_TESTS (the touched tests,
# separated by spaces) and STAGE_LOGDIR, and writes its output to
# $STAGE_LOGDIR/<check>.log. Without -l the log directory is a fresh
# /tmp/cyfr-stage.<stage>.XXXXXX, the name scripts/janitor.sh removes after
# seven days; it is named on stderr.
#
# Stdout is `_START=<pid>` first and `_EXIT=<pid> <status>` last, as the
# other harness scripts frame theirs (scripts/await-task.sh), with one line
# per row between: `<check>: ok <seconds>s`, `<check>: failed <status>
# <seconds>s` or `<check>: skipped (<reason>)`. -n prints `would run
# <check> (<lane>): <command>` or `would skip <check>: <reason>` per row
# and runs nothing.
#
# Exits 0 when every row that ran passed and 1 otherwise; 64 on usage, or
# inside a heavy-check (HEAVY_CHECK_HELD set), since each row queues in
# its own lane; 65 for a table it cannot read, naming the line, or a
# touched path with whitespace, before any row runs; 69 outside a Git
# checkout or without the stage's base; 130, 143 and 129 on INT, TERM and
# HUP, once the running row has stopped. The frame starts after the
# options are read, so a usage refusal writes none.
set -uo pipefail

STAGES='save handoff pull-request release nightly'
usage() { echo "usage: $0 [-l LOGDIR] [-n] save|handoff|pull-request|release|nightly [-- PATHS]"; }

logdir= dry=false stage= explicit=false paths=()
while [ "$#" -gt 0 ]; do
  case $1 in
    -l) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; logdir=$2; shift 2 ;;
    -n) dry=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; explicit=true; paths=("$@"); break ;;
    -*) usage >&2; exit 64 ;;
    *) [ -z "$stage" ] || { usage >&2; exit 64; }; stage=$1; shift ;;
  esac
done
case " $STAGES " in *" $stage "*) [ -n "$stage" ] ;; *) false ;; esac || { usage >&2; exit 64; }
if [ -n "${HEAVY_CHECK_HELD:-}" ]; then
  echo 'stage: each row queues in its own lane: run this outside scripts/heavy-check.sh' >&2
  exit 64
fi

row_pid= finished=false
finish() {
  local status=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [ "$status" = 0 ] && ! $finished; then status=1; fi
  printf '_EXIT=%s %s\n' "$$" "$status"
  exit "$status"
}
on_signal() {
  trap '' INT TERM HUP
  if [ -n "$row_pid" ]; then
    kill -TERM "$row_pid" 2>/dev/null
    wait "$row_pid" 2>/dev/null
  fi
  exit "$1"
}
printf '_START=%s\n' "$$"
trap finish EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
refuse() { echo "stage: $2" >&2; exit "$1"; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(git -C "$here/.." rev-parse --show-toplevel 2>/dev/null) || root=
[ -n "$root" ] || refuse 69 "$here/.. is not inside a git checkout"
cd "$root" || refuse 69 "cannot enter $root"
table=scripts/stages.tsv

# The table, read whole and refused at its first bad line.
declare -A seen=()
rows=()
number=0
while IFS= read -r line || [ -n "$line" ]; do
  number=$((number + 1))
  case $line in '#'*) continue ;; esac
  [ -n "${line//[[:space:]]/}" ] || continue
  tabs=${line//[^$'\t']/}
  [ "${#tabs}" = 5 ] || refuse 65 "$table:$number: a row has six fields separated by single tabs"
  case $line in $'\t'*|*$'\t\t'*|*$'\t') refuse 65 "$table:$number: a field is empty" ;; esac
  IFS=$'\t' read -r r_stage r_check r_lane r_hold r_when r_command <<<"$line"
  case " $STAGES " in *" $r_stage "*) ;; *) refuse 65 "$table:$number: no stage is called '$r_stage'" ;; esac
  [[ $r_check =~ ^[a-z0-9-]+$ ]] || refuse 65 "$table:$number: the check '$r_check' is not [a-z0-9-]+"
  [ -z "${seen[$r_stage/$r_check]+set}" ] || refuse 65 "$table:$number: $r_stage has a second check called $r_check"
  seen[$r_stage/$r_check]=1
  case $r_lane in
    none) [ "$r_hold" = - ] || refuse 65 "$table:$number: a row in the none lane holds nothing: its hold is -" ;;
    scoped|proof|exclusive)
      [[ $r_hold =~ ^[1-9][0-9]{0,5}$ ]] || refuse 65 "$table:$number: the hold '$r_hold' is not seconds" ;;
    *) refuse 65 "$table:$number: no lane is called '$r_lane'" ;;
  esac
  case $r_when in
    always) ;;
    tests) [ "$r_stage" = save ] || [ "$r_stage" = handoff ] || refuse 65 "$table:$number: only save and handoff rows take tests" ;;
    *)
      [[ $r_when =~ ^[^,[:space:]]+(,[^,[:space:]]+)*$ ]] || refuse 65 "$table:$number: '$r_when' is not always, tests or comma-separated globs"
      [ "$r_stage" = save ] || [ "$r_stage" = handoff ] || refuse 65 "$table:$number: only save and handoff rows take globs" ;;
  esac
  [ -n "${r_command//[[:space:]]/}" ] || refuse 65 "$table:$number: the command is empty"
  if [ "$r_lane" = none ]; then
    case $r_command in
      'mix format --check-formatted'|'mix format --check-formatted '*|'git grep '*) ;;
      *) refuse 65 "$table:$number: the none lane runs only mix format --check-formatted and git grep, not: $r_command" ;;
    esac
  fi
  if [ "$r_stage" = "$stage" ]; then rows+=("$number"$'\t'"$line"); fi
done <"$table"

# The changed set and the touched tests, for the stages that read them.
base= changed=() tests=()
if [ "$stage" = save ] || [ "$stage" = handoff ]; then
  if [ -n "${STAGE_BASE:-}" ]; then
    base=$STAGE_BASE
  elif [ "$stage" = save ]; then
    base=HEAD
  else
    base=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null) || base=
  fi
  [ -n "$base" ] && git rev-parse --verify -q "$base^{commit}" >/dev/null ||
    refuse 69 "the base ${base:-of the handoff stage (origin/main or main)} is not a commit here"
  while IFS= read -r -d '' path; do changed+=("$path"); done < <(
    git diff --name-only --no-renames -z "$base" --
    git ls-files -z --others --exclude-standard
  )
fi
if $explicit; then
  tests=(${paths[@]+"${paths[@]}"})
else
  for path in ${changed[@]+"${changed[@]}"}; do
    test_path=
    case $path in
      apps/cyfr/test/cluster/*) ;;
      apps/*/test/*_test.exs) [ -f "$path" ] && test_path=$path ;;
      apps/*/lib/*.ex)
        app=${path#apps/}; app=${app%%/*}
        rel=${path#apps/"$app"/lib/}
        test_path="apps/$app/test/${rel%.ex}_test.exs"
        case $test_path in apps/cyfr/test/cluster/*) test_path= ;; esac
        [ -n "$test_path" ] && [ -f "$test_path" ] || test_path= ;;
    esac
    if [ -n "$test_path" ]; then tests+=("$test_path"); fi
  done
fi
for path in ${tests[@]+"${tests[@]}"}; do
  case $path in *[[:space:]]*) refuse 65 "a touched test path holds whitespace: '$path'" ;; esac
done
if [ "${#tests[@]}" -gt 0 ]; then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | LC_ALL=C sort -u)
fi

# Whether a path of the changed set matches one of the comma-separated
# globs in $1.
matches() {
  local glob specs=()
  IFS=, read -r -a globs <<<"$1"
  for glob in "${globs[@]}"; do specs+=(":(glob)$glob"); done
  { git diff --name-only --no-renames "$base" -- "${specs[@]}"
    git ls-files --others --exclude-standard -- "${specs[@]}"
  } 2>/dev/null | grep -q .
}

if ! $dry; then
  if [ -n "$logdir" ]; then
    mkdir -p "$logdir" && logdir=$(cd "$logdir" && pwd -P) || refuse 64 "cannot use $logdir for the logs"
  else
    logdir=$(mktemp -d "/tmp/cyfr-stage.$stage.XXXXXX") || refuse 69 'cannot make a log directory'
  fi
  echo "stage: $stage logs in $logdir" >&2
fi
export STAGE="$stage" STAGE_TESTS="${tests[*]+${tests[*]}}" STAGE_LOGDIR="$logdir"

failures=0
for row in ${rows[@]+"${rows[@]}"}; do
  line=${row#*$'\t'}
  IFS=$'\t' read -r _ check lane hold when command <<<"$line"
  reason=
  case $when in
    always) ;;
    tests) [ -n "$STAGE_TESTS" ] || reason='no touched test' ;;
    *) matches "$when" || reason="no changed path matches $when" ;;
  esac
  if $dry; then
    if [ -n "$reason" ]; then echo "would skip $check: $reason"; else echo "would run $check ($lane): $command"; fi
    continue
  fi
  if [ -n "$reason" ]; then echo "$check: skipped ($reason)"; continue; fi
  started=$SECONDS
  case $lane in
    none) bash -c "$command" >"$logdir/$check.log" 2>&1 & ;;
    scoped) scripts/heavy-check.sh -s -t "$hold" -- bash -c "$command" >"$logdir/$check.log" 2>&1 & ;;
    proof) scripts/heavy-check.sh -p -t "$hold" -- bash -c "$command" >"$logdir/$check.log" 2>&1 & ;;
    exclusive) scripts/heavy-check.sh -t "$hold" -- bash -c "$command" >"$logdir/$check.log" 2>&1 & ;;
  esac
  row_pid=$!
  status=0
  wait "$row_pid" || status=$?
  row_pid=
  if [ "$status" = 0 ]; then
    echo "$check: ok $((SECONDS - started))s"
  else
    echo "$check: failed $status $((SECONDS - started))s"
    failures=$((failures + 1))
  fi
done

finished=true
[ "$failures" = 0 ]
