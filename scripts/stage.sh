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
# nightly (the janitor and the host's proofs, which
# scripts/nightly.sh runs once a day from a timer on the host, on main's
# head, and reports to GitHub). What each runs is scripts/stages.tsv, one
# row per check:
#   stage<TAB>check<TAB>quarters<TAB>hold<TAB>folder<TAB>when<TAB>command
#   stage    one of the five above
#   check    [a-z0-9-]+, unique within its stage
#   quarters 1 or 4, the quarters of the machine it takes, heavy-check's -q
#   hold     the seconds the command may run before it is stopped. A row
#            of no folder is heavy-check's -t; the rows of one folder
#            share a ticket whose -t is the sum of their holds and 60 s
#            each for a stop. A ticket waits for the host as long as
#            heavy-check's default queue deadline, which is longer than
#            every ticket's hold here (tests/heavy-check-test.sh holds the
#            two together), so a ticket queued behind any one other still
#            runs
#   folder   the build folder the command compiles into or reads, which
#            another row of the stage may use too: dev (Mix's default
#            _build/dev), dev_pg, test or test_pg, the _build folder of
#            that name; or - for a row that uses none of them
#   when     always; tests, when the stage's touched tests are not none;
#            or comma-separated path globs with Git's :(glob) meaning,
#            when a path of the changed set matches one and no glob of the
#            row written !GLOB. Only save and handoff rows take tests or
#            globs.
#   command  the rest of the line, run as `bash -c` from the worktree's
#            root
# Lines that start with #, and blank lines, are skipped. The whole table
# is read, and every row's when decided on the changed set as the stage
# found it, before any row runs. In save and handoff the rows of one
# folder that run take one heavy-check ticket, on the most quarters one of
# them takes, and run under it one after another in the table's order
# (scripts/lib/stage-chain.sh), and every other row runs beside them on a
# ticket of its own; every ticket queues when the stage starts, so a stage
# can hold every quarter at once. Every other stage runs its rows one
# after another in the table's order, each on a ticket of its own. Every
# row runs whatever an earlier one ended with. When the save or handoff
# rows that
# run name two folders or more, the stage first compiles the dependencies
# into each of those folders in turn, in the order the table first names
# them, on one quarter (`mix deps.loadpaths` under the folder's build path,
# adapter and MIX_ENV, logged in deps.log), and starts no row that names a
# folder before it ends: a dependency's own compile writes under deps/,
# which every folder shares (erlex's generated parser), so two cold builds
# started together race there. Warm, it finds nothing to do. When it
# fails, no row that names a folder starts: each reads `not run 69`, and
# the rows of no folder still run. No check is called deps. The stage
# clears MIX_ENV and MIX_BUILD_PATH before any of it, so a row's build
# folder is what its own command sets, never the caller's.
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
# Handoff's take, besides, the test files that name what the change
# defines or reads: for each changed apps/*/lib/**.ex and
# apps/*/test/support/**.ex or .exs, deleted or not, each module and
# protocol it declares (defmodule, defprotocol) and each defimpl's protocol
# and for: targets, which a test file names by its whole dotted name or as
# Parent.{..., Rest};
# for a changed apps/<app>/test/test_helper.exs, every test file of the app;
# and for any other changed path but a test, the test files that hold its
# basename. Each name's test files join, the names with the fewest first,
# while the seconds they add (scripts/test-partition-weights.tsv, a file it
# lacks weighing its median) stay within SELECT_BUDGET below; each name
# left out is named with its count of test files, as left to the pull
# request's run, on stderr and at the top of the log of every row that
# runs $STAGE_TESTS. Out of its reach: a module a macro defines, and a test
# that reaches a changed module only through another it names (a facade).
# Save's stay the changed tests and their lib mirrors.
# PATHS after `--` replace them. A touched path with whitespace is refused.
#
# A row whose command is scripts/test-partitioned.sh, its options, then
# test paths to its end (words that start apps/, or $STAGE_TESTS) runs
# those paths' tests. When two such rows of one folder run with the same
# options, a touched test that one names by $STAGE_TESTS and the other
# names, itself or by a directory that holds it, runs once, in the other:
# the first sees STAGE_TESTS without it and its log names the row it runs
# in, and with no touched test left it is skipped (`every touched test
# runs in <checks>`).
#
# Each row's command sees STAGE, STAGE_TESTS (the touched tests,
# separated by spaces) and STAGE_LOGDIR, and writes its output to
# $STAGE_LOGDIR/<check>.log. A folder's ticket writes heavy-check's own
# lines to <folder>.queue.log and each of its rows' ends to
# <folder>.results. Without -l the log directory is a fresh
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
# start, its wait for the host included: a folder's first row starts when
# its ticket queues and each next one when the one before it ends. Not
# run is a status of 69, a prerequisite the check names is missing, or
# 75, heavy-check's queue deadline passed before it started; it counts as
# failed. A folder's ticket that ends with any status but 0 fails the
# stage whatever its rows read, and says `<folder> ticket: failed
# <status> <seconds>s` (or not run) after every row's line, the seconds
# from when it queued; a row of the folder it left without a line reads
# that status, 1 for a ticket that ended 0. A ticket whose stage is gone
# starts no more rows (scripts/lib/stage-chain.sh). The dependency
# compile, when there is one, says `deps: ...` first, alike. -n prints
# `would compile deps (1 quarter): <folders>` when it would, then `would
# run <check> (<n> quarter[s]): <command>` or `would skip <check>:
# <reason>` per row, and runs nothing.
#
# Exits 0 when every row that ran passed and 1 otherwise; 64 on usage, or
# inside a heavy-check (HEAVY_CHECK_HELD set), since the stage queues its
# own tickets; 65 for a table that is missing or unreadable, or a line of
# it that is not a row, naming it, or a
# touched path with whitespace, before any row runs; 69 outside a Git
# checkout, without the stage's base, when Git cannot list the changed
# paths a row's globs match, or when handoff's tests cannot be selected
# (python3 runs the selection); 130, 143 and 129 on INT, TERM and HUP, once
# every running row has stopped, and no row starts after the signal: each
# row that had not ended reads `failed <status>`, printed with the rest
# before the frame.
# Every exit is framed, a usage refusal's included. It needs Bash 5.1 or
# later (wait -n -p).
set -uo pipefail

# Each running heavy-check's pid, and the row index (or deps) it runs.
declare -A running=()
finished=false launched=false
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
  local pid folder i
  for pid in "${!running[@]}"; do kill -TERM "$pid" 2>/dev/null; done
  for pid in "${!running[@]}"; do wait "$pid" 2>/dev/null; done
  # Every row the signal left without a line reads its status as failed.
  if $launched; then
    for folder in "${!chain_read[@]}"; do collect "$folder"; done
    if $deps_waits && [ -z "$deps_line" ]; then deps_line=$(result deps "$1" $((SECONDS - deps_began))); fi
    for i in "${!rows[@]}"; do unfinished "$i" "$1"; done
    flush
    if [ "${#tickets[@]}" -gt 0 ]; then printf '%s\n' "${tickets[@]}"; fi
  fi
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
[ -z "${HEAVY_CHECK_HELD:-}" ] || refuse 64 'the stage queues its own tickets: run this outside scripts/heavy-check.sh'
# A caller's MIX_ENV or MIX_BUILD_PATH would move a lane's rows into
# another folder, or two lanes into one.
unset MIX_ENV MIX_BUILD_PATH

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
      [ "$r_stage" = save ] || [ "$r_stage" = handoff ] || refuse 65 "$table:$number: only save and handoff rows take globs"
      [[ ,$r_when, =~ ,[^!,] ]] || refuse 65 "$table:$number: '$r_when' excludes paths and names none" ;;
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
# Handoff's touched tests take, besides, the tests that name what the
# change defines or reads (the header's rule), within SELECT_BUDGET.
# The budget trades the consumers handoff runs against the time every
# slice's handoff holds two quarters for: 300 s was the smallest of 100,
# 200, 300 and 600 that, replayed over the 2026-11-16 to 11-18 pull
# requests that went red on GitHub, selected each failing test, and at it
# the median handoff of the 40 pull requests before it added about 220 s.
SELECT_BUDGET=300
left_out=()
if [ "$stage" = handoff ] && ! $explicit; then
  # The changed paths and the touched tests reach the selection as
  # NUL-separated streams on fds 3 and 4, and its records come back NUL-
  # separated, so no path is read as an option or split at a tab.
  records=()
  mapfile -d '' -t records < <(python3 -I - "$base" "$SELECT_BUDGET" scripts/test-partition-weights.tsv \
    3< <(printf '%s\0' ${changed[@]+"${changed[@]}"}) 4< <(printf '%s\0' ${tests[@]+"${tests[@]}"}) <<'PY'
import os, re, subprocess, sys

base, budget, table = sys.argv[1], float(sys.argv[2]), sys.argv[3]
def paths(fd):
    with os.fdopen(fd, "rb") as stream:
        return [os.fsdecode(p) for p in stream.read().split(b"\0") if p]
changed, touched = paths(3), set(paths(4))

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, check=True).stdout.decode("utf-8", "replace")

def cluster(path): return path.startswith("apps/cyfr/test/cluster/")
def is_test(path): return re.fullmatch(r"apps/[^/]+/test/.*_test\.exs", path, re.S) is not None
def is_source(path):
    return not is_test(path) and re.fullmatch(r"apps/[^/]+/(lib/.*\.ex|test/support/.*\.exs?)", path, re.S) is not None

suite = sorted(os.fsdecode(p) for p in subprocess.run(
    ["git", "ls-files", "-co", "--exclude-standard", "-z", "--", ":(glob)apps/*/test/**/*_test.exs"],
    capture_output=True, check=True).stdout.split(b"\0") if p)
suite = [p for p in suite if not cluster(p) and os.path.isfile(p)]
text = {p: open(p, encoding="utf-8", errors="replace").read() for p in suite}

# A module is named by its whole dotted name, never as the prefix of a
# longer one, or as Parent.{..., Rest, ...}.
NAME = re.compile(r"(?<![\w.:@])[A-Z]\w*(?:\.[A-Z]\w*)*")
MULTI = re.compile(r"(?<![\w.])([A-Z]\w*(?:\.[A-Z]\w*)*)\.\{([^}]*)\}")
named = {}
for p, t in text.items():
    names = set(NAME.findall(t))
    for parent, inner in MULTI.findall(t):
        names |= {parent + "." + q.strip() for q in inner.split(",") if re.fullmatch(r"[A-Z]\w*(?:\.[A-Z]\w*)*", q.strip())}
    for n in names:
        named.setdefault(n, set()).add(p)

# What a source defines: each defmodule and defprotocol, nested by
# indentation, and for each defimpl its protocol and its for: targets.
DECLARE = re.compile(r"^([ \t]*)(defmodule|defprotocol|defimpl)[ \t]+([A-Z][\w.]*)(?![\w.])(.*)$", re.M)
TARGETS = re.compile(r"\bfor:\s*(\[[^\]]*\]|[A-Z][\w.]*)")
def defined(source):
    found, stack = [], []
    for m in DECLARE.finditer(source):
        indent, kind, name, rest = len(m.group(1)), m.group(2), m.group(3), m.group(4)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if kind == "defimpl":
            found.append(name)
            target = TARGETS.search(rest)
            if target:
                found += re.findall(r"[A-Z][\w.]*", target.group(1))
            continue
        full = stack[-1][1] + "." + name if stack and indent > 0 else name
        stack.append((indent, full))
        found.append(full)
    return list(dict.fromkeys(found))

consumers = []
for path in changed:
    if is_test(path) or cluster(path):
        continue
    if is_source(path):
        source = open(path, encoding="utf-8", errors="replace").read() if os.path.isfile(path) else git("show", f"{base}:{path}")
        consumers += [(m, named.get(m, set())) for m in defined(source)]
        continue
    helper = re.fullmatch(r"apps/([^/]+)/test/test_helper\.exs", path)
    if helper:
        consumers.append((path, {p for p in suite if p.startswith(f"apps/{helper.group(1)}/test/")}))
        continue
    base_name = path.rsplit("/", 1)[-1]
    consumers.append((path, {p for p, t in text.items() if base_name in t}))

weights = {}
if os.path.isfile(table):
    for line in open(table):
        if line.strip() and not line.startswith("#"):
            seconds, p = line.rstrip("\n").split("\t")
            weights[p] = float(seconds)
ordered = sorted(weights.values())
n = len(ordered)
median = 1.0 if n == 0 else ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2

out = sys.stdout.buffer
# Fewest consumers first, so a narrow name is never crowded out by a wide
# one; each cost is summed in path order, so the budget's edge is the same
# on every run.
selected, spent = set(touched), 0.0
for name, files in sorted(consumers, key=lambda c: (len(c[1]), c[0])):
    new = files - selected
    if not new:
        continue
    cost = sum(weights.get(p, median) for p in sorted(new))
    if spent + cost > budget:
        out.write(b"left\0" + os.fsencode(name) + b"\0" + str(len(files)).encode() + b"\0")
        continue
    spent += cost
    selected |= new
for p in sorted(selected - touched):
    out.write(b"test\0" + os.fsencode(p) + b"\0")
PY
  )
  wait "$!" || refuse 69 "cannot select the tests the change can break"
  k=0
  while [ "$k" -lt "${#records[@]}" ]; do
    case ${records[k]} in
      test) tests+=("${records[k + 1]}"); k=$((k + 2)) ;;
      left) left_out+=("==> stage: ${records[k + 1]} (${records[k + 2]} test files) left to the pull request's run"); k=$((k + 3)) ;;
      *) refuse 69 "the test selection answered '${records[k]}'" ;;
    esac
  done
  if [ "${#left_out[@]}" -gt 0 ]; then printf '%s\n' "${left_out[@]}" >&2; fi
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
  for glob in "${globs[@]}"; do
    case $glob in
      '!'*) specs+=(":(exclude,glob)${glob#!}") ;;
      *) specs+=(":(glob)$glob") ;;
    esac
  done
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

# Each row's lane: in save and handoff its folder, - for one that runs
# beside every other; in every other stage the one lane of the stage.
lanes=()
for i in ${rows[@]+"${!rows[@]}"}; do
  IFS=$'\t' read -r _ _ _ _ _ folder _ <<<"${rows[$i]}"
  case $stage in save | handoff) lanes+=("$folder") ;; *) lanes+=(stage) ;; esac
done

# Each row's STAGE_TESTS, and what its log says first. A touched test that
# a test row of a folder names by $STAGE_TESTS alone and another test row
# of the folder, with the same options, names runs in the other (the
# header's rule).
runner() { # INDEX: sets r_options and r_paths for a test row, else returns 1
  local command words k
  IFS=$'\t' read -r _ _ _ _ _ _ _ command <<<"${rows[$1]}"
  read -r -a words <<<"$command"
  [ "${words[0]-}" = scripts/test-partitioned.sh ] || return 1
  k=${#words[@]}
  while [ "$k" -gt 1 ]; do
    case ${words[k - 1]} in apps/* | '$STAGE_TESTS') k=$((k - 1)) ;; *) break ;; esac
  done
  [ "$k" -lt "${#words[@]}" ] || return 1
  r_options="${words[*]:0:k}" r_paths=("${words[@]:k}")
}
row_tests=() notes=()
for i in ${rows[@]+"${!rows[@]}"}; do
  row_tests[$i]=${tests[*]+${tests[*]}} notes[$i]=
  if [ "${#left_out[@]}" -gt 0 ] && runner "$i" && [[ " ${r_paths[*]} " == *' $STAGE_TESTS '* ]]; then
    notes[$i]=$(printf '%s\n' "${left_out[@]}")$'\n'
  fi
  [ "${lanes[$i]}" != - ] && [ "${lanes[$i]}" != stage ] && [ -z "${reasons[$i]}" ] &&
    runner "$i" && [ "${r_paths[*]}" = '$STAGE_TESTS' ] || continue
  options=$r_options kept=() elsewhere=()
  for test_path in ${tests[@]+"${tests[@]}"}; do
    in=
    for j in "${!rows[@]}"; do
      [ "$j" != "$i" ] && [ "${lanes[$j]}" = "${lanes[$i]}" ] && [ -z "${reasons[$j]}" ] &&
        runner "$j" && [ "$r_options" = "$options" ] || continue
      for named in "${r_paths[@]}"; do
        named=${named%/}
        if [ "$test_path" = "$named" ] || [[ $test_path == "$named"/* ]]; then in=$j; break 2; fi
      done
    done
    if [ -z "$in" ]; then kept+=("$test_path"); continue; fi
    IFS=$'\t' read -r _ _ check _ <<<"${rows[$in]}"
    notes[$i]+="==> stage: $test_path runs in $check"$'\n'
    [[ " ${elsewhere[*]-} " == *" $check "* ]] || elsewhere+=("$check")
  done
  row_tests[$i]=${kept[*]-}
  [ "${#kept[@]}" -gt 0 ] || [ "${#elsewhere[@]}" = 0 ] || reasons[$i]="every touched test runs in ${elsewhere[*]}"
done
# The lanes the rows that run name, in the order the table first names
# them, and, for two folders or more, the dependency compile into each in
# turn.
folders=() deps_command=
for i in ${rows[@]+"${!rows[@]}"}; do
  [ -z "${reasons[$i]}" ] || continue
  folder=${lanes[$i]}
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
# launch ENTRY QUARTERS HOLD LOG COMMAND...: COMMAND queued for the host in
# the background, its heavy-check's pid recorded with ENTRY, its output
# added to LOG, which the caller starts.
launch() {
  local entry=$1 quarters=$2 hold=$3 log=$4
  shift 4
  scripts/heavy-check.sh -q "$quarters" -t "$hold" -- "$@" >>"$log" 2>&1 &
  running[$!]=$entry
}
began=() lines=()
declare -A lane=() chain_began=() chain_last=() chain_read=()
tickets=()
start_row() { # INDEX: the row on a ticket of its own
  local check quarters hold command
  IFS=$'\t' read -r _ _ check quarters hold _ _ command <<<"${rows[$1]}"
  began[$1]=$SECONDS
  printf '%s' "${notes[$1]}" >"$logdir/$check.log"
  launch "$1" "$quarters" "$hold" "$logdir/$check.log" bash -c "$command"
}
# start_lane FOLDER: the stage lane's next row on a ticket of its own, or
# every row of a build folder on one ticket.
chains=0
start_lane() {
  local folder=$1 left=${lane[$1]-} i check quarters hold command most=1 total=0 args=()
  [ -n "$left" ] || return 0
  if [ "$folder" = stage ]; then
    lane[$folder]=${left#* }
    start_row "${left%% *}"
    return 0
  fi
  for i in $left; do
    IFS=$'\t' read -r _ _ check quarters hold _ _ command <<<"${rows[$i]}"
    [ "$quarters" -le "$most" ] || most=$quarters
    total=$((total + hold + 60))
    printf '%s' "${notes[$i]}" >"$logdir/$check.log"
    args+=("$i" "$check" "$hold" "${row_tests[$i]}" "$command")
  done
  : >"$logdir/$folder.results"
  chain_began[$folder]=$EPOCHSECONDS chain_last[$folder]=$EPOCHSECONDS chain_read[$folder]=0
  : >"$logdir/$folder.queue.log"
  launch "chain $folder" "$most" "$total" "$logdir/$folder.queue.log" \
    bash scripts/lib/stage-chain.sh "$$" "$logdir/$folder.results" "${args[@]}"
  chains=$((chains + 1))
  tick
}
# collect FOLDER: the lines of the folder's rows that have ended since the
# last look. A line still being written is left for the next.
collect() {
  local folder=$1 n=0 index status ended check
  [ -f "$logdir/$folder.results" ] || return 0
  while read -r index status ended; do
    n=$((n + 1))
    [ "$n" -gt "${chain_read[$folder]}" ] || continue
    [[ " ${lane[$folder]} " == *" $index "* ]] && [ -z "${lines[$index]+set}" ] &&
      [[ $status =~ ^[0-9]+$ ]] && [[ $ended =~ ^[0-9]+$ ]] || continue
    IFS=$'\t' read -r _ _ check _ <<<"${rows[$index]}"
    lines[$index]=$(result "$check" "$status" $((ended - chain_last[$folder])))
    chain_last[$folder]=$ended
    [ "$status" = 0 ] || failures=$((failures + 1))
  done <"$logdir/$folder.results"
  chain_read[$folder]=$n
}
# unfinished INDEX STATUS: a row that has no line yet reads STATUS, as
# failed or not run, and fails the stage; its seconds run from its start,
# which for a folder's row is the end of the row before it.
unfinished() {
  local check folder=${lanes[$1]} since=0
  [ -z "${lines[$1]+set}" ] || return 0
  IFS=$'\t' read -r _ _ check _ <<<"${rows[$1]}"
  if [ -n "${chain_last[$folder]+set}" ]; then
    since=$((EPOCHSECONDS - chain_last[$folder]))
    chain_last[$folder]=$EPOCHSECONDS
  elif [ -n "${began[$1]+set}" ]; then
    since=$((SECONDS - began[$1]))
  fi
  lines[$1]=$(result "$check" "$2" "$since")
  failures=$((failures + 1))
}
# A folder's rows report while its ticket runs: the stage looks every two
# seconds while a ticket runs.
ticking=false tick_pid=
tick() {
  ! $ticking || return 0
  sleep 2 &
  tick_pid=$! ticking=true
  running[$tick_pid]=tick
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
  IFS=$'\t' read -r _ _ check _ _ _ _ <<<"${rows[$i]}"
  if [ -n "${reasons[$i]}" ]; then
    lines[$i]="$check: skipped (${reasons[$i]}) 0s"
  elif [ "${lanes[$i]}" != - ]; then
    lane[${lanes[$i]}]+="$i "
  fi
done
failures=0 launched=true
if [ -n "$deps_command" ]; then
  deps_waits=true deps_began=$SECONDS
  : >"$logdir/deps.log"
  launch deps 1 1800 "$logdir/deps.log" bash -c "$deps_command"
else
  for folder in ${folders[@]+"${folders[@]}"}; do start_lane "$folder"; done
fi
for i in ${rows[@]+"${!rows[@]}"}; do
  if [ -z "${reasons[$i]}" ] && [ "${lanes[$i]}" = - ]; then start_row "$i"; fi
done

flush
while [ "${#running[@]}" -gt 0 ]; do
  pid=
  wait -n -p pid
  status=$?
  [ -n "$pid" ] && [ -n "${running[$pid]+set}" ] || continue
  entry=${running[$pid]}
  unset "running[$pid]"
  case $entry in
    tick) ticking=false ;;
    deps)
      [ "$status" = 0 ] || failures=$((failures + 1))
      deps_line=$(result deps "$status" $((SECONDS - deps_began)))
      if [ "$status" = 0 ]; then
        for folder in "${folders[@]}"; do start_lane "$folder"; done
      else
        # A row of a folder would compile what the failed compile left there,
        # beside the other folders' rows: none starts.
        for folder in "${folders[@]}"; do
          for i in ${lane[$folder]}; do
            IFS=$'\t' read -r _ _ check _ _ _ _ <<<"${rows[$i]}"
            lines[$i]="$check: not run 69 0s"
            failures=$((failures + 1))
          done
          lane[$folder]=
        done
      fi ;;
    'chain '*)
      # A ticket that ended red fails the stage whatever its rows read, and
      # the rows it left without a line read its status.
      folder=${entry#chain }
      chains=$((chains - 1))
      collect "$folder"
      if [ "$status" != 0 ]; then
        tickets+=("$(result "$folder ticket" "$status" $((EPOCHSECONDS - chain_began[$folder])))")
        failures=$((failures + 1))
      else
        status=1
      fi
      for i in ${lane[$folder]}; do unfinished "$i" "$status"; done ;;
    *)
      [ "$status" = 0 ] || failures=$((failures + 1))
      IFS=$'\t' read -r _ _ check _ _ _ _ <<<"${rows[$entry]}"
      lines[$entry]=$(result "$check" "$status" $((SECONDS - began[entry])))
      [ "${lanes[$entry]}" = - ] || start_lane "${lanes[$entry]}" ;;
  esac
  for folder in "${!chain_read[@]}"; do collect "$folder"; done
  if [ "$chains" -gt 0 ]; then tick; elif $ticking; then kill "$tick_pid" 2>/dev/null; fi
  flush
done

if [ "${#tickets[@]}" -gt 0 ]; then printf '%s\n' "${tickets[@]}"; fi
finished=true
[ "$failures" = 0 ]
