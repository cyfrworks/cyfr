#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Runs the checks a stage names: scripts/stage.sh [-l LOGDIR] [-n] STAGE [-- PATHS]
#
# The stages are save (after an edit), handoff (before a change is
# reported ready), pull-request (the gate, CI's checks on this host, for
# offline work and reproducing a CI failure: the pull request's run on
# GitHub is the check), release (the gate's close, which
# `scripts/release.sh --gate` runs for a HEAD with no run on GitHub) and
# nightly (the janitor and the proofs no workflow runs, which
# scripts/nightly.sh runs once a day from a timer on the host, on main's
# head, and reports to GitHub). What each runs is scripts/stages.tsv, one
# row per check:
#   stage<TAB>check<TAB>quarters<TAB>hold<TAB>folder<TAB>when<TAB>command
#   stage    one of the five above
#   check    [a-z0-9-]+, unique within its stage
#   quarters 1 or 4, the quarters of the machine it takes, heavy-check's -q
#   hold     heavy-check's -t in seconds. A row waits for the host as long
#            as heavy-check's default queue deadline, which is longer than
#            every hold here (tests/heavy-check-test.sh holds the two
#            together), so a row queued behind any one other row still runs
#   folder   the build folder the command compiles into or reads, which
#            another row of the stage may use too: dev (Mix's default
#            _build/dev), dev_pg, test or test_pg, the _build folder of
#            that name; or - for a row that uses none of them
#   when     always; tests, when the stage's touched tests are not none;
#            or comma-separated path globs with Git's :(glob) meaning,
#            when a path of the changed set matches one. Only save and
#            handoff rows take tests or globs.
#   command  the rest of the line, run as `bash -c` from the worktree's
#            root
# Lines that start with #, and blank lines, are skipped. The whole table
# is read, and every row's when decided on the changed set as the stage
# found it, before any row runs. The rows of one folder run one after
# another in the table's order; every other row runs beside them, each
# queued for its own quarters when the stage starts, so a stage can hold
# every quarter at once. Every row runs whatever an earlier one ended
# with. When the rows that run name two folders or more, the stage first
# compiles the dependencies into each of those folders in turn, in the
# order the table first names them, on one quarter (`mix deps.loadpaths`
# under the folder's build path, adapter and MIX_ENV, logged in deps.log),
# and starts no row that names a folder before it ends: a dependency's own
# compile writes under deps/, which every folder shares (erlex's generated
# parser), so two cold builds started together race there. Warm, it finds
# nothing to do. No check is called deps.
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
# seven days; it is named on stderr. The name carries no PROOF_RUN_PREFIX:
# logs outlive the run that wrote them, and the janitor finds them by this
# name alone (its rule 5), as it finds the gate's /tmp/cyfr-gate.*.
#
# Stdout is `_START=<pid>` first and `_EXIT=<pid> <status>` last, as the
# other harness scripts frame theirs (scripts/await-task.sh), with one line
# per row between, in the table's order, each printed once its row and
# every row before it have ended: `<check>: ok <seconds>s`, `<check>:
# failed <status> <seconds>s`, `<check>: not run <status> <seconds>s` or
# `<check>: skipped (<reason>) <seconds>s`, the seconds from the row's
# start, its wait for the host included. Not run is a status of 69, a
# prerequisite the check names is missing, or 75, heavy-check's queue
# deadline passed before it started; it counts as failed. The dependency
# compile, when there is one, says `deps: ...` first, alike. -n prints
# `would compile deps (1 quarter): <folders>` when it would, then `would
# run <check> (<n> quarter[s]): <command>` or `would skip <check>:
# <reason>` per row, and runs nothing.
#
# Exits 0 when every row that ran passed and 1 otherwise; 64 on usage, or
# inside a heavy-check (HEAVY_CHECK_HELD set), since each row queues for
# its own quarters; 65 for a table that is missing or unreadable, or a line of
# it that is not a row, naming it, or a
# touched path with whitespace, before any row runs; 69 outside a Git
# checkout, without the stage's base, or when Git cannot list the changed
# paths a row's globs match; 130, 143 and 129 on INT, TERM and HUP, once
# every running row has stopped, and no row starts after the signal.
# Every exit is framed, a usage refusal's included. It needs Bash 5.1 or
# later (wait -n -p).
set -uo pipefail

# Each running heavy-check's pid, and the row index (or deps) it runs.
declare -A running=()
finished=false
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
  local pid
  for pid in "${!running[@]}"; do kill -TERM "$pid" 2>/dev/null; done
  for pid in "${!running[@]}"; do wait "$pid" 2>/dev/null; done
  exit "$1"
}
printf '_START=%s\n' "$$"
trap finish EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
refuse() { echo "stage: $2" >&2; exit "$1"; }

# Whether $1 names a stage, whole.
is_stage() { case $1 in save|handoff|pull-request|release|nightly) return 0 ;; *) return 1 ;; esac; }
usage() { echo "usage: $0 [-l LOGDIR] [-n] save|handoff|pull-request|release|nightly [-- PATHS]"; }

logdir= dry=false stage= explicit=false paths=()
while [ "$#" -gt 0 ]; do
  case $1 in
    -l) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; logdir=$2; shift 2 ;;
    -n) dry=true; shift ;;
    -h|--help) usage; finished=true; exit 0 ;;
    --) shift; explicit=true; paths=("$@"); break ;;
    -*) usage >&2; exit 64 ;;
    *) [ -z "$stage" ] || { usage >&2; exit 64; }; stage=$1; shift ;;
  esac
done
is_stage "$stage" || { usage >&2; exit 64; }
[ -z "${HEAVY_CHECK_HELD:-}" ] || refuse 64 'each row queues for its own quarters: run this outside scripts/heavy-check.sh'

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(git -C "$here/.." rev-parse --show-toplevel 2>/dev/null) || root=
[ -n "$root" ] || refuse 69 "$here/.. is not inside a git checkout"
cd "$root" || refuse 69 "cannot enter $root"
table=scripts/stages.tsv
[ -f "$table" ] && [ -r "$table" ] || refuse 65 "$table: there is no stage table to read"

# The table, read whole and refused at its first bad line.
declare -A seen=()
rows=()
number=0
while IFS= read -r line || [ -n "$line" ]; do
  number=$((number + 1))
  case $line in '#'*) continue ;; esac
  [ -n "${line//[[:space:]]/}" ] || continue
  tabs=${line//[^$'\t']/}
  [ "${#tabs}" = 6 ] || refuse 65 "$table:$number: a row has seven fields separated by single tabs"
  case $line in $'\t'*|*$'\t\t'*|*$'\t') refuse 65 "$table:$number: a field is empty" ;; esac
  IFS=$'\t' read -r r_stage r_check r_quarters r_hold r_folder r_when r_command <<<"$line"
  is_stage "$r_stage" || refuse 65 "$table:$number: no stage is called '$r_stage'"
  [[ $r_check =~ ^[a-z0-9-]+$ ]] || refuse 65 "$table:$number: the check '$r_check' is not [a-z0-9-]+"
  [ "$r_check" != deps ] || refuse 65 "$table:$number: no check is called deps, the stage's name for its dependency compile"
  [ -z "${seen[$r_stage/$r_check]+set}" ] || refuse 65 "$table:$number: $r_stage has a second check called $r_check"
  seen[$r_stage/$r_check]=1
  case $r_quarters in
    1|4) ;;
    *) refuse 65 "$table:$number: a row takes 1 or 4 quarters, not '$r_quarters'" ;;
  esac
  [[ $r_hold =~ ^[1-9][0-9]{0,5}$ ]] || refuse 65 "$table:$number: the hold '$r_hold' is not seconds"
  case $r_folder in
    dev | dev_pg | test | test_pg | -) ;;
    *) refuse 65 "$table:$number: the folder '$r_folder' is not dev, dev_pg, test, test_pg or -" ;;
  esac
  case $r_when in
    always) ;;
    tests) [ "$r_stage" = save ] || [ "$r_stage" = handoff ] || refuse 65 "$table:$number: only save and handoff rows take tests" ;;
    *)
      [[ $r_when =~ ^[^,[:space:]]+(,[^,[:space:]]+)*$ ]] || refuse 65 "$table:$number: '$r_when' is not always, tests or comma-separated globs"
      [ "$r_stage" = save ] || [ "$r_stage" = handoff ] || refuse 65 "$table:$number: only save and handoff rows take globs" ;;
  esac
  [ -n "${r_command//[[:space:]]/}" ] || refuse 65 "$table:$number: the command is empty"
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
# globs in $1. Both listings are read whole: a reader that stops at the
# first path ends the second listing with SIGPIPE, which pipefail reports
# as no match.
matches() {
  local glob globs specs=() found
  IFS=, read -r -a globs <<<"$1"
  for glob in "${globs[@]}"; do specs+=(":(glob)$glob"); done
  found=$(git diff --name-only --no-renames "$base" -- "${specs[@]}" &&
    git ls-files --others --exclude-standard -- "${specs[@]}") ||
    refuse 69 "cannot list the changed paths that match $1"
  [ -n "$found" ]
}

# Each row's reason to be skipped, empty for a row that runs.
reasons=()
for row in ${rows[@]+"${rows[@]}"}; do
  IFS=$'\t' read -r _ _ _ _ _ _ when _ <<<"$row"
  reason=
  case $when in
    always) ;;
    tests) [ -n "${tests[*]+${tests[*]}}" ] || reason='no touched test' ;;
    *) matches "$when" || reason="no changed path matches $when" ;;
  esac
  reasons+=("$reason")
done

# The folders the rows that run name, in the order the table first names
# them, and, for two or more, the dependency compile into each in turn.
folders=() deps_command=
for i in ${rows[@]+"${!rows[@]}"}; do
  [ -z "${reasons[$i]}" ] || continue
  IFS=$'\t' read -r _ _ _ _ _ folder _ <<<"${rows[$i]}"
  [ "$folder" = - ] || [[ " ${folders[*]+${folders[*]}} " == *" $folder "* ]] || folders+=("$folder")
done
if [ "${#folders[@]}" -ge 2 ]; then
  deps_command='s=0'
  for folder in "${folders[@]}"; do
    case $folder in
      dev) build='CYFR_DATABASE=sqlite MIX_ENV=dev' ;;
      dev_pg) build='MIX_BUILD_PATH=_build/dev_pg CYFR_DATABASE=postgres MIX_ENV=dev' ;;
      test) build='MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test' ;;
      test_pg) build='MIX_BUILD_PATH=_build/test_pg CYFR_DATABASE=postgres MIX_ENV=test' ;;
    esac
    deps_command+="; echo '==> $folder'; env $build mix deps.loadpaths || s=1"
  done
  deps_command+='; exit $s'
fi

if $dry; then
  [ -z "$deps_command" ] || echo "would compile deps (1 quarter): ${folders[*]}"
  for i in ${rows[@]+"${!rows[@]}"}; do
    IFS=$'\t' read -r _ _ check quarters _ _ _ command <<<"${rows[$i]}"
    reason=${reasons[$i]}
    if [ -n "$reason" ]; then echo "would skip $check: $reason"
    elif [ "$quarters" = 1 ]; then echo "would run $check (1 quarter): $command"
    else echo "would run $check ($quarters quarters): $command"; fi
  done
  finished=true
  exit 0
fi

if [ -n "$logdir" ]; then
  mkdir -p "$logdir" && logdir=$(cd "$logdir" && pwd -P) || refuse 64 "cannot use $logdir for the logs"
else
  logdir=$(mktemp -d "/tmp/cyfr-stage.$stage.XXXXXX") || refuse 69 'cannot make a log directory'
fi
echo "stage: $stage logs in $logdir" >&2
export STAGE="$stage" STAGE_TESTS="${tests[*]+${tests[*]}}" STAGE_LOGDIR="$logdir"

# A row's summary line: result CHECK STATUS SECONDS.
result() {
  case $2 in
    0) echo "$1: ok $3s" ;;
    69 | 75) echo "$1: not run $2 $3s" ;;
    *) echo "$1: failed $2 $3s" ;;
  esac
}
# launch ENTRY QUARTERS HOLD LOG COMMAND: COMMAND queued for the host in
# the background, its heavy-check's pid recorded with ENTRY.
launch() {
  scripts/heavy-check.sh -q "$2" -t "$3" -- bash -c "$5" >"$4" 2>&1 &
  running[$!]=$1
}
began=() lines=()
declare -A lane=()
start_row() { # INDEX
  local check quarters hold command
  IFS=$'\t' read -r _ _ check quarters hold _ _ command <<<"${rows[$1]}"
  began[$1]=$SECONDS
  launch "$1" "$quarters" "$hold" "$logdir/$check.log" "$command"
}
next_in() { # FOLDER: starts the folder's next row, when one is left
  local left=${lane[$1]-}
  [ -n "$left" ] || return 0
  lane[$1]=${left#* }
  start_row "${left%% *}"
}
printed=0 deps_line=
deps_waits=false
flush() { # prints every line whose row, and every row before it, has ended
  if $deps_waits; then
    [ -n "$deps_line" ] || return 0
    echo "$deps_line"
    deps_waits=false
  fi
  while [ "$printed" -lt "${#rows[@]}" ] && [ -n "${lines[$printed]+set}" ]; do
    echo "${lines[$printed]}"
    printed=$((printed + 1))
  done
}

for i in ${rows[@]+"${!rows[@]}"}; do
  IFS=$'\t' read -r _ _ check _ _ folder _ <<<"${rows[$i]}"
  if [ -n "${reasons[$i]}" ]; then
    lines[$i]="$check: skipped (${reasons[$i]}) 0s"
  elif [ "$folder" != - ]; then
    lane[$folder]+="$i "
  fi
done
if [ -n "$deps_command" ]; then
  deps_waits=true deps_began=$SECONDS
  launch deps 1 1800 "$logdir/deps.log" "$deps_command"
else
  for folder in ${folders[@]+"${folders[@]}"}; do next_in "$folder"; done
fi
for i in ${rows[@]+"${!rows[@]}"}; do
  IFS=$'\t' read -r _ _ _ _ _ folder _ <<<"${rows[$i]}"
  if [ -z "${reasons[$i]}" ] && [ "$folder" = - ]; then start_row "$i"; fi
done

failures=0
flush
while [ "${#running[@]}" -gt 0 ]; do
  pid=
  wait -n -p pid
  status=$?
  [ -n "$pid" ] && [ -n "${running[$pid]+set}" ] || continue
  entry=${running[$pid]}
  unset "running[$pid]"
  [ "$status" = 0 ] || failures=$((failures + 1))
  if [ "$entry" = deps ]; then
    deps_line=$(result deps "$status" $((SECONDS - deps_began)))
    for folder in "${folders[@]}"; do next_in "$folder"; done
  else
    IFS=$'\t' read -r _ _ check _ _ folder _ <<<"${rows[$entry]}"
    lines[$entry]=$(result "$check" "$status" $((SECONDS - began[entry])))
    [ "$folder" = - ] || next_in "$folder"
  fi
  flush
done

finished=true
[ "$failures" = 0 ]
