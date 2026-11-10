#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# tests/load-check/run.sh against stub subjects: bash tests/load-check/run-test.sh.
# A toy repository holds a copy of the load check and the libraries it
# sources. Its quarters are four of the processors this test may use, one
# core of one thread each, read from a stand-in topology; docker is a
# stand-in on PATH that keeps its objects in files; every stub sleeps a
# second or two and records what it saw. Each check is shown failing on a
# copy of the load check with the thing it checks taken out (`mutant`).
# It needs four processors, git, python3, taskset and pgrep, and no Docker,
# database or build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-load-check-test.XXXXXX")
S=$(cd "$S" && pwd -P)
TOKEN=lcstub-$$
cleanup() {
  pkill -f "$TOKEN" 2>/dev/null || :
  rm -rf "$S"
}
trap cleanup EXIT
unset HEAVY_CHECK_HELD CONTAIN_REGISTRY CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS CONTAIN_FD_BASE PROOF_RUN_PREFIX
unset CYFR_TEST_CORES CARGO_BUILD_JOBS ERL_FLAGS MIX_BUILD_PATH MIX_DEPS_PATH
unset LOAD_CHECK_SUBJECTS LOAD_CHECK_CPU_ROOT LOAD_CHECK_WORKTREES LOAD_CHECK_SAMPLE LOAD_CHECK_GRACE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$S"
mkdir "$S/tmp" "$S/wt" "$S/probe" "$S/out" "$S/bin" "$S/notaskset" "$S/docker"
export TMPDIR="$S/tmp"
# A heavy-check a subject starts queues here if it queues at all, never in
# the host's own queue.
export HEAVY_CHECK_LOCK="$S/hc.lock"

case_name=
fail() { echo "FAIL: $case_name: $*" >&2; exit 1; }
begin() { case_name=$1; echo "case $case_name"; }
until_true() {
  local limit=$(( $1 * 10 )) n=0
  shift
  until "$@" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt "$limit" ] || return 1
    sleep 0.1
  done
}
# The processors a list such as 0-3,8 names, comma-separated and sorted.
norm() { python3 -I -c '
import sys
out = set()
for part in sys.argv[1].strip().split(","):
    if "-" in part:
        a, b = part.split("-"); out.update(range(int(a), int(b) + 1))
    elif part:
        out.add(int(part))
print(",".join(map(str, sorted(out))))' "$1"; }

# Four processors this test may use, one quarter each.
mine=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status)
read -r -a pick <<<"$(norm "$mine" | tr ',' ' ')"
[ "${#pick[@]}" -ge 4 ] || fail "the test needs four processors and may use ${#pick[@]} ($mine)"
Q=('' "${pick[0]}" "${pick[1]}" "${pick[2]}" "${pick[3]}")
ALL4=$(norm "${Q[1]},${Q[2]},${Q[3]},${Q[4]}")
# topology DIR CORE...: a stand-in sysfs, each CORE a siblings list.
topology() {
  local dir=$1 core cpu
  shift
  mkdir -p "$dir"
  norm "$(IFS=,; echo "$*")" >"$dir/online"
  for core in "$@"; do
    for cpu in ${core//,/ }; do mkdir -p "$dir/cpu$cpu/topology"; echo "$core" >"$dir/cpu$cpu/topology/thread_siblings_list"; done
  done
}
topology "$S/cpu" "${Q[1]}" "${Q[2]}" "${Q[3]}" "${Q[4]}"
topology "$S/cpu3" "${Q[1]}" "${Q[2]}" "${Q[3]}"
smt=(); for c in 0 1 2 3 4 5 6 7; do smt+=("$c,$((c + 8))"); done
topology "$S/smt16" "${smt[@]}"
odd=(); for c in 0 1 2 3 4 5 6 7 8; do odd+=("$c,$((c + 9))"); done
topology "$S/smt18" "${odd[@]}"

# A taskset that is not there, and a docker that keeps its objects in
# files under $S/docker.
printf '#!/bin/sh\nexit 127\n' >"$S/notaskset/taskset"
cat >"$S/bin/docker" <<'EOF'
#!/usr/bin/env bash
d=$DOCKER_STUB
touch "$d/containers" "$d/networks" "$d/volumes" "$d/images"
echo "$*" >>"$d/calls"
drop() { grep -vxF -- "$2" "$d/$1" >"$d/$1.new" || :; mv "$d/$1.new" "$d/$1"; }
case "$1 ${2:-}" in
  'version '*) echo stub ;;
  'ps '*) cat "$d/containers" ;;
  'inspect '*) echo ;;
  'network ls') cat "$d/networks" ;;
  'volume ls') cat "$d/volumes" ;;
  'image ls') cat "$d/images" ;;
  'rm '*) drop containers "${@: -1}" ;;
  'network rm') drop networks "${@: -1}" ;;
  'volume rm') drop volumes "${@: -1}" ;;
  'image rm') drop images "${@: -1}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$S/notaskset/taskset" "$S/bin/docker"

# The toy repository: the load check and what it sources, committed.
repo="$S/repo"
mkdir -p "$repo/scripts/lib" "$repo/tests/load-check"
cp "$ROOT/scripts/lib/contain.sh" "$ROOT/scripts/lib/run-names.sh" "$repo/scripts/lib/"
cp "$ROOT/scripts/heavy-check.sh" "$repo/scripts/"
cp "$ROOT/tests/load-check/run.sh" "$ROOT/tests/load-check/needs.sh" "$repo/tests/load-check/"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm toy
HEAD=$(git -C "$repo" rev-parse HEAD)

# A row of a stub table: its eight fields.
row() { local IFS=$'\t'; echo "$*"; }
base_rows() {
  row prep mark - - 1 30 - 'git rev-parse HEAD >"$LOAD_PROBE/prep-${PWD##*-}.head"; pwd -P >"$LOAD_PROBE/prep-${PWD##*-}.cwd"'
  row load spin - - 1 30 - 'grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; if [ -e "$LOAD_PROBE/fail-load" ]; then sleep 0.2; exit 3; fi; exec -a "$LOAD_TEST_TOKEN" sleep 1'
  row image img - - 1 30 - 'grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; exec -a "$LOAD_TEST_TOKEN" sleep 1'
}
table="$S/subjects.tsv"
{
  base_rows
  row subject probe 1 pair 2 30 - 'nproc >"$LOAD_CHECK_OUT/nproc"; grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; sh -c "grep Cpus_allowed_list /proc/self/status" >"$LOAD_CHECK_OUT/child-mask"; pwd -P >"$LOAD_CHECK_OUT/cwd"; echo "${MIX_BUILD_PATH-unset}" >"$LOAD_CHECK_OUT/build-path"; echo "${HEAVY_CHECK_HELD-unset}" >"$LOAD_CHECK_OUT/held"; scripts/heavy-check.sh -- sleep 1 >"$LOAD_CHECK_OUT/nested" 2>&1'
  row subject two 2 pair 2 30 - 'grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; sleep $((4 / $(nproc)))'
  row subject flaky 1 - 2 30 - 'for i in 1 2 3 4 5 6; do if pgrep -f "$LOAD_TEST_TOKEN" >/dev/null; then exit 1; fi; sleep 0.2; done'
  row subject slower 1 - 2 30 - 'sleep 0.5; if pgrep -f "$LOAD_TEST_TOKEN" >/dev/null; then sleep 2; else sleep 1; fi'
  row subject nap 1 - 2 30 - 'sleep 2'
  row subject needy 1 - 2 30 "echo 'no widget here'; exit 1" 'touch "$LOAD_PROBE/needy-ran"'
  row subject absent 1 - 2 30 - 'echo "absent: the widget is missing" >&2; exit 69'
  row subject escape 1 - 2 30 - 'taskset -c "$LOAD_TEST_ALL" sleep 2'
  row subject slow 1 - 2 2 - 'exec -a "$LOAD_TEST_TOKEN" sleep 8'
  row subject long 1 - 2 120 - 'echo "${PROOF_RUN_PREFIX}box" >>"$DOCKER_STUB/containers"; echo "${PROOF_RUN_PREFIX}net" >>"$DOCKER_STUB/networks"; echo "${PROOF_RUN_PREFIX}vol" >>"$DOCKER_STUB/volumes"; echo "${PROOF_RUN_PREFIX}img:latest" >>"$DOCKER_STUB/images"; mkdir -p "$TMPDIR/${PROOF_RUN_PREFIX}scratch"; grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; case $LOAD_CHECK_OUT in */r1-busy/*) exec -a "$LOAD_TEST_TOKEN" sleep 60 ;; esac; sleep 1.5'
  row subject whole 4 - 2 30 - 'touch "$LOAD_PROBE/whole-ran"'
} >"$table"

# Every case starts from no worktree, probe or Docker object but the
# host's own, which no run may touch.
fresh() {
  pkill -f "$TOKEN" 2>/dev/null || :
  rm -rf "$S/probe" "$S/docker" "$S/wt"
  mkdir "$S/probe" "$S/docker" "$S/wt"
  git -C "$repo" worktree prune
  printf 'cyfr-postgres\ncyfr-0123456789-1-box\n' >"$S/docker/containers"
  printf 'cyfr-0123456789-1-net\n' >"$S/docker/networks"
  : >"$S/docker/volumes"
  printf 'cyfr-locus:in-0123\n' >"$S/docker/images"
}
# lc NAME [VAR=VALUE...] [-- ARGS]: the toy repository's load check (or
# mutant NAME's), its output in $S/NAME.out and .err, its status in $rc.
lc() {
  local script=$repo/tests/load-check/run.sh name=$1 vars=()
  shift
  case $name in mutant-*) script=$repo/tests/load-check/$name.sh ;; esac
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "$#" = 0 ] || shift
  rc=0
  env HEAVY_CHECK_HELD=exclusive LOAD_CHECK_CPU_ROOT="$S/cpu" LOAD_CHECK_WORKTREES="$S/wt" LOAD_CHECK_SUBJECTS="$table" \
    LOAD_CHECK_SAMPLE=1 LOAD_CHECK_GRACE=10 PATH="$S/bin:$PATH" LOAD_TEST_TOKEN="$TOKEN" LOAD_TEST_ALL="$ALL4" \
    LOAD_PROBE="$S/probe" DOCKER_STUB="$S/docker" "${vars[@]}" "$script" "$@" >"$S/$name.out" 2>"$S/$name.err" || rc=$?
}
# mutant NAME OLD NEW: a copy of the load check with OLD, which it holds
# once, replaced by NEW.
mutant() {
  python3 -I - "$repo/tests/load-check/run.sh" "$repo/tests/load-check/mutant-$1.sh" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src).read()
if text.count(old) != 1:
    sys.exit(f"mutant: the load check does not hold this once: {old}")
open(dst, "w").write(text.replace(old, new))
PY
  chmod +x "$repo/tests/load-check/mutant-$1.sh"
}

# --- the checks, each a function a control runs against a mutant ----------

# no_work OUT: the refused run made no worktree or report and ran nothing.
no_work() {
  [ -z "$(ls -A "$S/wt")" ] || { echo "a worktree was made: $(ls "$S/wt")"; return 1; }
  [ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || { echo 'git lists a worktree'; return 1; }
  [ ! -e "$1" ] || { echo "the report directory $1 was made"; return 1; }
  [ -z "$(ls -A "$S/probe")" ] || { echo "a row ran: $(ls "$S/probe")"; return 1; }
}
# mask FILE PROCESSORS: the processors FILE's Cpus_allowed_list names are
# PROCESSORS.
mask() {
  local got
  got=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "$1" 2>/dev/null)
  [ -n "$got" ] && [ "$(norm "$got")" = "$(norm "$2")" ] || { echo "$1 allows '$got', not $2"; return 1; }
}
# placed OUT: every copy, and a process it started, saw its quarters alone.
placed() {
  local o=$1 c
  mask "$o/probe/r0-warm-up/a/mask" "${Q[1]}" || return 1
  mask "$o/probe/r0-warm-up/b/mask" "${Q[2]}" || return 1
  for c in alone busy pair; do
    mask "$o/probe/r1-$c/a/mask" "${Q[1]}" || return 1
    mask "$o/probe/r1-$c/a/child-mask" "${Q[1]}" || return 1
    [ "$(cat "$o/probe/r1-$c/a/nproc")" = 1 ] || { echo "probe $c saw $(cat "$o/probe/r1-$c/a/nproc") processors"; return 1; }
    mask "$o/two/r1-$c/a/mask" "${Q[1]},${Q[2]}" || return 1
  done
  mask "$o/probe/r1-pair/b/mask" "${Q[2]}" || return 1
  mask "$o/probe/r1-pair/b/child-mask" "${Q[2]}" || return 1
  mask "$o/two/r0-warm-up/b/mask" "${Q[3]},${Q[4]}" || return 1
  mask "$o/two/r1-pair/b/mask" "${Q[3]},${Q[4]}" || return 1
  mask "$o/two/r1-whole/a/mask" "$ALL4" || return 1
}
# busy_placed OUT: each worker ran on its own quarter, never the subject's.
busy_placed() {
  local o=$1
  mask "$o/probe/r1-busy/load-w1.out/mask" "${Q[2]}" || return 1
  mask "$o/probe/r1-busy/load-w2.out/mask" "${Q[3]}" || return 1
  mask "$o/probe/r1-busy/load-w3.out/mask" "${Q[4]}" || return 1
  mask "$o/probe/r1-busy/image-w3.out/mask" "${Q[4]}" || return 1
  mask "$o/two/r1-busy/load-w1.out/mask" "${Q[3]}" || return 1
  mask "$o/two/r1-busy/load-w2.out/mask" "${Q[4]}" || return 1
  mask "$o/two/r1-busy/image-w2.out/mask" "${Q[4]}" || return 1
}
# busy_gone OUT: no load step began more than 5 s after its busy run ended,
# and nothing of the load is left.
busy_gone() {
  python3 -I - "$1" <<'PY' || return 1
import csv, glob, os, sys
out = sys.argv[1]
with open(os.path.join(out, "report.tsv")) as f:
    rows = [r for r in csv.DictReader(f, delimiter="\t") if r["condition"] == "busy"]
if not rows:
    sys.exit("no busy run was recorded")
for r in rows:
    files = glob.glob(os.path.join(out, r["subject"], f"r{r['round']}-busy", "*.status"))
    if not files:
        sys.exit(f"{r['subject']} round {r['round']}: no worker status")
    for path in files:
        begins = [float(l.split()[2]) for l in open(path) if l.startswith("begin ")]
        if not begins or max(begins) > float(r["ended"]) + 5:
            sys.exit(f"{path}: a step began {max(begins) - float(r['ended']):.1f}s after the run ended")
PY
  ! pgrep -f "$TOKEN" >/dev/null || { echo "a stub still runs: $(pgrep -af "$TOKEN")"; return 1; }
}
# own_trees OUT: each worktree was its own, at the toy HEAD, a subject's
# copy ran in its own one, the caller's MIX_BUILD_PATH did not reach it,
# and none is left.
own_trees() {
  local o=$1 role cwds
  for role in a b w1 w2 w3; do
    [ "$(cat "$S/probe/prep-$role.head" 2>/dev/null)" = "$HEAD" ] || { echo "worktree $role is not at $HEAD"; return 1; }
  done
  cwds=$(cat "$S"/probe/prep-*.cwd | sort -u | wc -l)
  [ "$cwds" = 5 ] || { echo "the five worktrees are $cwds directories"; return 1; }
  case $(cat "$o/probe/r1-pair/a/cwd") in "$S/wt/"*-load-check-a) ;; *) echo "copy a ran in $(cat "$o/probe/r1-pair/a/cwd")"; return 1 ;; esac
  case $(cat "$o/probe/r1-pair/b/cwd") in "$S/wt/"*-load-check-b) ;; *) echo "copy b ran in $(cat "$o/probe/r1-pair/b/cwd")"; return 1 ;; esac
  [ "$(cat "$o/probe/r1-alone/a/build-path")" = unset ] || { echo "the copy saw MIX_BUILD_PATH=$(cat "$o/probe/r1-alone/a/build-path")"; return 1; }
  [ -z "$(ls -A "$S/wt")" ] || { echo "worktrees are left: $(ls "$S/wt")"; return 1; }
  [ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || { echo 'git still lists a worktree'; return 1; }
}
# side_by_side OUT: the two copies of a pair ran at once, a heavy-check
# each started ran in place, and neither copy took longer than alone.
side_by_side() {
  local o=$1 c
  for c in r1-alone/a r1-pair/a r1-pair/b; do
    [ "$(cat "$o/probe/$c/held")" = exclusive ] || { echo "probe $c saw HEAVY_CHECK_HELD=$(cat "$o/probe/$c/held")"; return 1; }
  done
  python3 -I - "$o/report.tsv" <<'PY' || return 1
import csv, sys
with open(sys.argv[1]) as f:
    rows = [r for r in csv.DictReader(f, delimiter="\t") if r["subject"] == "probe" and r["round"] == "1"]
alone = next(float(r["seconds"]) for r in rows if r["condition"] == "alone")
pair = [r for r in rows if r["condition"] == "pair"]
if len(pair) != 2:
    sys.exit(f"the pair has {len(pair)} copies")
if max(float(r["started"]) for r in pair) >= min(float(r["ended"]) for r in pair):
    sys.exit("the copies of the pair did not overlap")
if max(float(r["seconds"]) for r in pair) > alone + 0.5:
    sys.exit(f"a copy of the pair took {max(float(r['seconds']) for r in pair)}s, alone {alone}s: the pair queued")
PY
}
# verdict NAME TEXT: the summary of run NAME holds the line TEXT.
said() { grep -qxF -- "$2" "$S/$1.out" || { echo "$1 did not say: $2"; return 1; }; }
# ratio NAME SUBJECT CONDITION: the ratio the summary gives for CONDITION
# is the medians' quotient from report.tsv: CONDITION's over alone's, or,
# for whole, alone's over whole's.
ratio() {
  python3 -I - "$S/out/$1/report.tsv" "$S/$1.out" "$2" "$3" <<'PY'
import csv, re, statistics, sys
report, out, subject, condition = sys.argv[1:5]
with open(report) as f:
    rows = [r for r in csv.DictReader(f, delimiter="\t") if r["subject"] == subject and r["status"] == "passed"]
med = lambda c: statistics.median(float(r["seconds"]) for r in rows if r["condition"] == c)
want = med("alone") / med("whole") if condition == "whole" else med(condition) / med("alone")
label = "two quarters/whole machine" if condition == "whole" else f"{condition}/alone"
with open(out) as f:
    lines = f.read().splitlines()
head = next(i for i, l in enumerate(lines) if l.startswith(f"{subject} ("))
section = []
for line in lines[head + 1:]:
    if not line.startswith(" "):
        break
    section.append(line)
pattern = rf"  {condition} \d+/\d+ passed, median [\d.]+s; {re.escape(label)} ([\d.]+)$"
got = [m.group(1) for m in (re.match(pattern, l) for l in section) if m]
if got != [f"{want:.2f}"]:
    sys.exit(f"{subject}: {label} is {got or 'missing'}, the medians give {want:.2f}")
PY
}

# --- the cases ---------------------------------------------------------------

begin 'a refused run starts no work: outside the exclusive lane, without taskset, on three cores, with a busy load that cannot run'
fresh
lc lane HEAVY_CHECK_HELD= -- -o "$S/out/lane"
[ "$rc" = 64 ] && grep -q 'takes the whole host' "$S/lane.err" || fail "unheld: $rc $(cat "$S/lane.err")"
no_work "$S/out/lane" || fail "unheld: $(no_work "$S/out/lane")"
lc scoped HEAVY_CHECK_HELD=scoped -- -o "$S/out/scoped"
[ "$rc" = 64 ] && no_work "$S/out/scoped" || fail "scoped: $rc $(cat "$S/scoped.err")"
lc notaskset PATH="$S/notaskset:$S/bin:$PATH" -- -o "$S/out/notaskset"
[ "$rc" = 69 ] && grep -q 'taskset (util-linux) is required' "$S/notaskset.err" || fail "no taskset: $rc $(cat "$S/notaskset.err")"
no_work "$S/out/notaskset" || fail "no taskset: $(no_work "$S/out/notaskset")"
lc three LOAD_CHECK_CPU_ROOT="$S/cpu3" -- -o "$S/out/three"
[ "$rc" = 69 ] && grep -q 'this host has 3 whole cores' "$S/three.err" || fail "three cores: $rc $(cat "$S/three.err")"
no_work "$S/out/three" || fail "three cores: $(no_work "$S/out/three")"
sed 's/^load\tspin\t-\t-\t1\t30\t-\t/load\tspin\t-\t-\t1\t30\techo no load here; exit 1\t/' "$table" >"$S/noload.tsv"
lc noload LOAD_CHECK_SUBJECTS="$S/noload.tsv" -- -s probe -o "$S/out/noload"
[ "$rc" = 69 ] && grep -qF 'the load row spin: no load here' "$S/noload.err" || fail "no load: $rc $(cat "$S/noload.err")"
no_work "$S/out/noload" || fail "no load: $(no_work "$S/out/noload")"
# The control: without its lane check the same run does work, and no_work
# says so.
mutant lane 'if ! $DRY && [ "${HEAVY_CHECK_HELD:-}" != exclusive ]; then' 'if false; then'
lc mutant-lane HEAVY_CHECK_HELD= -- -s probe -r 1 -o "$S/out/mutant-lane"
! no_work "$S/out/mutant-lane" >/dev/null 2>&1 || fail 'no_work passed a run that did work'

begin 'each run sees exactly its quarters, the busy load runs on the others alone and stops with its run, and each worktree is its own'
fresh
gone=$(sh -c 'echo $$')
until_true 5 test ! -e "/proc/$gone"
git -C "$repo" worktree add -q --detach "$S/wt/cyfr-0123456789-$gone-load-check-a" HEAD
lc place MIX_BUILD_PATH=/elsewhere/_build -- -s probe,two -r 1 -o "$S/out/place"
[ "$rc" = 0 ] || fail "the run exited $rc: $(tail -n 5 "$S/place.err")"
grep -qF "removed $S/wt/cyfr-0123456789-$gone-load-check-a, which load check $gone left" "$S/place.err" ||
  fail "the gone run's worktree was not removed: $(head -n 3 "$S/place.err")"
placed "$S/out/place" || fail "$(placed "$S/out/place")"
busy_placed "$S/out/place" || fail "$(busy_placed "$S/out/place")"
busy_gone "$S/out/place" || fail "$(busy_gone "$S/out/place")"
own_trees "$S/out/place" || fail "$(own_trees "$S/out/place")"
side_by_side "$S/out/place" || fail "$(side_by_side "$S/out/place")"
said place 'probe (1 quarter): holds' && said place 'two (2 quarters): holds' && said place 'verdict: holds: 2' || fail "$(cat "$S/place.out")"
ratio place two whole || fail "$(ratio place two whole 2>&1)"
ratio place two pair || fail "$(ratio place two pair 2>&1)"
# The controls: each check fails on a load check without what it checks.
mutant place 'taskset -c "$3" \' 'taskset -c "$ALL" \'
fresh; lc mutant-place -- -s probe,two -r 1 -o "$S/out/mutant-place"
! placed "$S/out/mutant-place" >/dev/null 2>&1 || fail 'placed passed copies run on every processor'
mutant busy-place 'taskset -c "${QUARTER[$quarter]}" \' 'taskset -c "$ALL" \'
fresh; lc mutant-busy-place -- -s probe,two -r 1 -o "$S/out/mutant-busy-place"
! busy_placed "$S/out/mutant-busy-place" >/dev/null 2>&1 || fail 'busy_placed passed workers run on every processor'
mutant busy-stop '    busy_held "$t0" "$t1" || :
    stop_busy' '    busy_held "$t0" "$t1" || :'
fresh; lc mutant-busy-stop -- -s probe,two -r 1 -o "$S/out/mutant-busy-stop"
! busy_gone "$S/out/mutant-busy-stop" >/dev/null 2>&1 || fail 'busy_gone passed workers that went on after their run'
mutant env 'env -u MIX_BUILD_PATH -u MIX_DEPS_PATH -u CYFR_TEST_CORES -u CARGO_BUILD_JOBS -u ERL_FLAGS \
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" LOAD_CHECK_OUT="$5"' 'env PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" LOAD_CHECK_OUT="$5"'
fresh; lc mutant-env MIX_BUILD_PATH=/elsewhere/_build -- -s probe,two -r 1 -o "$S/out/mutant-env"
! own_trees "$S/out/mutant-env" >/dev/null 2>&1 || fail 'own_trees passed a copy that saw the caller'"'"'s MIX_BUILD_PATH'
mutant queued 'env -u MIX_BUILD_PATH -u MIX_DEPS_PATH -u CYFR_TEST_CORES -u CARGO_BUILD_JOBS -u ERL_FLAGS \
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" LOAD_CHECK_OUT="$5"' 'env -u HEAVY_CHECK_HELD -u MIX_BUILD_PATH -u MIX_DEPS_PATH -u CYFR_TEST_CORES -u CARGO_BUILD_JOBS -u ERL_FLAGS \
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" LOAD_CHECK_OUT="$5"'
fresh; lc mutant-queued -- -s probe -r 1 -o "$S/out/mutant-queued"
! side_by_side "$S/out/mutant-queued" >/dev/null 2>&1 || fail 'side_by_side passed a pair whose heavy-checks queued'
mutant sweep 'if remove_worktree "$path"; then say' 'if false; then say'
fresh
git -C "$repo" worktree add -q --detach "$S/wt/cyfr-0123456789-$gone-load-check-a" HEAD
lc mutant-sweep -- -s probe -r 1 -o "$S/out/mutant-sweep"
[ -d "$S/wt/cyfr-0123456789-$gone-load-check-a" ] || fail 'the sweep control removed the gone run'"'"'s worktree'

begin 'a subject that fails only when busy is named and makes the exit 1, and each ratio is the quotient of the medians'
fresh
lc busy -- -s flaky,slower -r 2 -o "$S/out/busy"
[ "$rc" = 1 ] || fail "the run exited $rc: $(tail -n 5 "$S/busy.err")"
said busy 'flaky (1 quarter): FAILS BUSY' && said busy 'slower (1 quarter): holds' && said busy 'verdict: holds: 1; FAILS BUSY: flaky' ||
  fail "$(cat "$S/busy.out")"
ratio busy slower busy || fail "$(ratio busy slower busy 2>&1)"
mutant no-busy 'if [ "$c" = busy ] && ! start_busy "$q" "$dir"; then' 'if false; then'
fresh; lc mutant-no-busy -- -s flaky,slower -r 2 -o "$S/out/mutant-no-busy"
[ "$rc" = 0 ] && ! said mutant-no-busy 'flaky (1 quarter): FAILS BUSY' >/dev/null 2>&1 || fail "without a busy load the stub still failed: $rc"
mutant ratio 'text += f"; {c}/alone {ratio(m, alone)}"' 'text += f"; {c}/alone {ratio(alone, m)}"'
fresh; lc mutant-ratio -- -s slower -r 2 -o "$S/out/mutant-ratio"
! ratio mutant-ratio slower busy 2>/dev/null || fail 'ratio passed a summary that inverted busy/alone'

begin 'a busy run whose load step fails is void and names the worker, and the run exits 1'
fresh
touch "$S/probe/fail-load"
lc void -- -s nap -r 1 -o "$S/out/void"
[ "$rc" = 1 ] && said void 'nap (1 quarter): not decided: a run was void' || fail "the run exited $rc: $(cat "$S/void.out")"
awk -F'\t' -v q="${Q[1]}" '$1 == "nap" && $3 == "busy" && $5 == q && $6 == "void" && index($11, "the busy load'"'"'s load-w1 on quarter 2: spin exited 3 while the subject ran")' "$S/out/void/report.tsv" | grep -q . ||
  fail "the void run: $(grep busy "$S/out/void/report.tsv")"
mutant held 'busy_held "$t0" "$t1" || :' ':'
fresh; touch "$S/probe/fail-load"
lc mutant-held -- -s nap -r 1 -o "$S/out/mutant-held"
! said mutant-held 'nap (1 quarter): not decided: a run was void' >/dev/null 2>&1 || fail 'the void control still voided the run'

begin 'a process outside its processors is named and voids its run'
fresh
lc escape -- -s escape -r 1 -o "$S/out/escape"
[ "$rc" = 1 ] && said escape 'escape (1 quarter): not decided: a run was void' || fail "the run exited $rc: $(cat "$S/escape.out")"
line=$(awk -F'\t' -v q="${Q[1]}" '$1 == "escape" && $3 == "alone" && $4 == "escape a" && $6 == "sleep" && $8 == q { print $7; exit }' "$S/out/escape/masks.tsv")
[ -n "$line" ] && [ "$(norm "$line")" = "$ALL4" ] || fail "masks.tsv: $(cat "$S/out/escape/masks.tsv")"
grep -q 'outside .* sleep' "$S/out/escape/report.tsv" || fail "the void run names no process: $(cat "$S/out/escape/report.tsv")"
mutant sample 'if [ "$SECONDS" -ge "$next" ]; then sample; next=$((SECONDS + SAMPLE)); fi' ':'
fresh; lc mutant-sample -- -s escape -r 1 -o "$S/out/mutant-sample"
! grep -q sleep "$S/out/mutant-sample/masks.tsv" && said mutant-sample 'escape (1 quarter): holds' >/dev/null ||
  fail 'without sampling the escape was still seen'

begin 'a subject without its prerequisite is skipped with the reason and never passes, and the run exits 69'
fresh
lc skip -- -s needy,absent,whole -r 1 -o "$S/out/skip"
[ "$rc" = 69 ] || fail "the run exited $rc: $(tail -n 5 "$S/skip.err")"
said skip 'needy: skipped: no widget here' && said skip 'absent: skipped: exited 69: absent: the widget is missing' &&
  said skip 'whole: not measured: it takes all four quarters' && said skip 'verdict: holds: 0; skipped: needy absent; not measured: whole' ||
  fail "$(cat "$S/skip.out")"
[ ! -e "$S/probe/needy-ran" ] && [ ! -e "$S/probe/whole-ran" ] || fail 'a skipped subject ran'
! awk -F'\t' '($1 == "needy" || $1 == "absent") && $6 == "passed"' "$S/out/skip/report.tsv" | grep -q . || fail 'a skipped subject has a passed run'
mutant needs '  [ "$1" != - ] || return 0
  out=' '  return 0
  out='
fresh; lc mutant-needs -- -s needy -r 1 -o "$S/out/mutant-needs"
! said mutant-needs 'needy: skipped: no widget here' >/dev/null && [ -e "$S/probe/needy-ran" ] || fail 'the needs control still skipped'

begin 'a run that reaches its deadline is stopped with what it started and fails'
fresh
lc deadline -- -s slow -r 1 -o "$S/out/deadline"
[ "$rc" = 1 ] && said deadline 'slow (1 quarter): fails alone' || fail "the run exited $rc: $(cat "$S/deadline.out")"
[ "$(awk -F'\t' '$1 == "slow" && $6 == "deadline" && $8 < 6' "$S/out/deadline/report.tsv" | wc -l)" = 3 ] ||
  fail "report.tsv: $(grep slow "$S/out/deadline/report.tsv")"
! pgrep -f "$TOKEN" >/dev/null 2>&1 || fail "a stub outlived its deadline: $(pgrep -af "$TOKEN")"
mutant deadline 'elif [ "$SECONDS" -ge "${J_DUE[$i]}" ]; then' 'elif false; then'
fresh; lc mutant-deadline -- -s slow -r 1 -o "$S/out/mutant-deadline"
! awk -F'\t' '$6 == "deadline"' "$S/out/mutant-deadline/report.tsv" | grep -q . || fail 'the deadline control still stopped the run'

begin 'TERM stops every run and worker, then removes what the run and its subjects made'
fresh
rc=0
env HEAVY_CHECK_HELD=exclusive LOAD_CHECK_CPU_ROOT="$S/cpu" LOAD_CHECK_WORKTREES="$S/wt" LOAD_CHECK_SUBJECTS="$table" \
  LOAD_CHECK_SAMPLE=1 LOAD_CHECK_GRACE=10 PATH="$S/bin:$PATH" LOAD_TEST_TOKEN="$TOKEN" LOAD_PROBE="$S/probe" DOCKER_STUB="$S/docker" \
  "$repo/tests/load-check/run.sh" -s long -r 1 -o "$S/out/term" >"$S/term.out" 2>"$S/term.err" &
pid=$!
until_true 60 test -s "$S/out/term/long/r1-busy/a/mask" && until_true 10 test -s "$S/out/term/long/r1-busy/load-w1.out/mask" ||
  fail "the busy run did not start: $(tail -n 5 "$S/term.err")"
until_true 10 awk -F'\t' '$4 == "long a" && $6 == "any processor" { found = 1 } END { exit !found }' "$S/out/term/docker.tsv" || fail "the run's container was not recorded: $(cat "$S/out/term/docker.tsv")"
kill -TERM "$pid"
wait "$pid" || rc=$?
[ "$rc" = 143 ] || fail "TERM ended the run with $rc: $(tail -n 5 "$S/term.err")"
! pgrep -f "$TOKEN" >/dev/null 2>&1 || fail "a stub outlived TERM: $(pgrep -af "$TOKEN")"
[ -z "$(ls -A "$S/wt")" ] && [ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || fail "worktrees are left: $(ls "$S/wt")"
! grep -qE "^cyfr-[0-9a-f]{10}-$pid-" "$S"/docker/containers "$S"/docker/networks "$S"/docker/volumes "$S"/docker/images ||
  fail "a Docker object of the run is left: $(cat "$S"/docker/*s)"
grep -qx cyfr-postgres "$S/docker/containers" && grep -qx cyfr-0123456789-1-box "$S/docker/containers" &&
  grep -qx cyfr-0123456789-1-net "$S/docker/networks" && grep -qx cyfr-locus:in-0123 "$S/docker/images" ||
  fail "a Docker object that is not the run's was removed: $(cat "$S"/docker/*s)"
! ls "$TMPDIR" | grep -qE "^cyfr-[0-9a-f]{10}-$pid-" || fail "a scratch entry of the run is left: $(ls "$TMPDIR")"
[ -s "$S/out/term/report.tsv" ] || fail 'the report was not kept'
mutant cleanup '  trap - EXIT
  if [ "$s" = 0 ] && ! $FINISHED; then s=1; fi
  cleanup' '  trap - EXIT
  if [ "$s" = 0 ] && ! $FINISHED; then s=1; fi'
fresh
env HEAVY_CHECK_HELD=exclusive LOAD_CHECK_CPU_ROOT="$S/cpu" LOAD_CHECK_WORKTREES="$S/wt" LOAD_CHECK_SUBJECTS="$table" \
  LOAD_CHECK_SAMPLE=1 LOAD_CHECK_GRACE=10 PATH="$S/bin:$PATH" LOAD_TEST_TOKEN="$TOKEN" LOAD_PROBE="$S/probe" DOCKER_STUB="$S/docker" \
  "$repo/tests/load-check/mutant-cleanup.sh" -s long -r 1 -o "$S/out/mutant-cleanup" >"$S/mutant-cleanup.out" 2>"$S/mutant-cleanup.err" &
pid=$!
until_true 60 test -s "$S/out/mutant-cleanup/long/r1-busy/a/mask" || fail 'the cleanup control did not start its busy run'
kill -TERM "$pid"
wait "$pid" || :
[ -n "$(ls -A "$S/wt")" ] || fail 'the cleanup control removed its worktrees'

begin 'the dry run prints the plan with every run'"'"'s processors and runs nothing, a core'"'"'s threads in one quarter'
fresh
lc dry HEAVY_CHECK_HELD= LOAD_CHECK_CPU_ROOT="$S/smt16" -- -n -r 1 -s probe,two,needy,whole -o "$S/out/dry"
[ "$rc" = 0 ] || fail "the dry run exited $rc: $(cat "$S/dry.err")"
no_work "$S/out/dry" || fail "the dry run: $(no_work "$S/out/dry")"
for line in 'quarter 1: 0,1,8,9' 'quarter 2: 2,3,10,11' 'quarter 3: 4,5,12,13' 'quarter 4: 6,7,14,15' 'outside every quarter: none' \
  'subject probe: 1 quarter(s), 4 runs of about 2s, 8s: warm-up a 0,1,8,9 b 2,3,10,11; alone 0,1,8,9; busy 0,1,8,9, load 2,3,4,5,6,7,10,11,12,13,14,15; pair a 0,1,8,9 b 2,3,10,11' \
  'subject two: 2 quarter(s), 5 runs of about 2s, 10s: warm-up a 0,1,2,3,8,9,10,11 b 4,5,6,7,12,13,14,15; alone 0,1,2,3,8,9,10,11; busy 0,1,2,3,8,9,10,11, load 4,5,6,7,12,13,14,15; pair a 0,1,2,3,8,9,10,11 b 4,5,6,7,12,13,14,15; whole 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15' \
  'subject needy: skipped: no widget here' 'subject whole: not measured: it takes all four quarters' \
  'expected: about 20s for 2 measured subject(s), 1 skipped, 1 not measured'; do
  said dry "$line" || fail "$(cat "$S/dry.out")"
done
lc odd HEAVY_CHECK_HELD= LOAD_CHECK_CPU_ROOT="$S/smt18" -- -n -s probe
said odd 'quarter 4: 6,7,15,16' && said odd 'outside every quarter: 8,17' || fail "$(cat "$S/odd.out")"
mutant siblings '  key=${sib// /,}' '  sib=$cpu key=$cpu'
lc mutant-siblings HEAVY_CHECK_HELD= LOAD_CHECK_CPU_ROOT="$S/smt16" -- -n -s probe
! said mutant-siblings 'quarter 1: 0,1,8,9' >/dev/null 2>&1 || fail 'the siblings control still kept a core in one quarter'

echo 'load check self-test: every case passed'
