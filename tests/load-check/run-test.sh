#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# tests/load-check/run.sh against stub subjects: bash tests/load-check/run-test.sh.
# A toy repository holds a copy of the load check, the scripts it reads and
# a stand-in release boot. Its quarters are four of the processors this
# test may use, one core of one thread each, read from a stand-in topology;
# docker is a stand-in on PATH that keeps its containers, cpusets and
# databases in files; every stub sleeps a second or two and records what
# it saw. Each check is shown failing on a copy of the load check (or of
# the file it reads) with the thing it checks taken out (`mutant`). It
# needs four processors, git, python3, taskset and pgrep, and no Docker,
# database or build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-load-check-test.XXXXXX")
S=$(cd "$S" && pwd -P)
TOKEN=lcstub-$$
# Made-up passwords: no output or log of the check may hold the first, and
# none of the check's own lines the second, which a stub prints.
SECRET=sentinel$$x$RANDOM
SECRET2=quoted$$y$RANDOM
cleanup() {
  pkill -f "$TOKEN" 2>/dev/null || :
  rm -rf "$S"
}
trap cleanup EXIT
unset HEAVY_CHECK_HELD HEAVY_CHECK_CPUS CONTAIN_REGISTRY CONTAIN_CLOSE_FDS CONTAIN_HOLD_FDS CONTAIN_FD_BASE PROOF_RUN_PREFIX
unset CYFR_TEST_CORES CARGO_BUILD_JOBS ERL_FLAGS MIX_BUILD_PATH MIX_DEPS_PATH
unset LOAD_CHECK_SUBJECTS LOAD_CHECK_CPU_ROOT LOAD_CHECK_WORKTREES LOAD_CHECK_SAMPLE LOAD_CHECK_GRACE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$S"
mkdir "$S/tmp" "$S/wt" "$S/probe" "$S/out" "$S/bin" "$S/notaskset" "$S/docker"
export TMPDIR="$S/tmp"
# A heavy-check a subject starts queues here if it queues at all.
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

printf '#!/bin/sh\nexit 127\n' >"$S/notaskset/taskset"
# The stand-in docker: `run` records a container and its cpuset, or, when
# it runs psql, creates or drops a database, refusing to while
# refuse-create or refuse-drop is there; `rm` refuses a container whose
# name holds `stuck`.
cat >"$S/bin/docker" <<'EOF'
#!/usr/bin/env bash
d=$DOCKER_STUB
touch "$d/containers" "$d/cpusets" "$d/networks" "$d/volumes" "$d/images" "$d/databases"
echo "$*" >>"$d/calls"
drop() { grep -vxF -- "$2" "$d/$1" >"$d/$1.new" || :; mv "$d/$1.new" "$d/$1"; }
case "$1 ${2:-}" in
  'version '*) echo stub ;;
  'run '*)
    name= cpus= sql=
    while [ "$#" -gt 0 ]; do
      case $1 in --name) name=$2; shift ;; --cpuset-cpus) cpus=$2; shift ;; -c) sql=$2; shift ;; esac
      shift
    done
    if [ -n "$sql" ]; then
      db=${sql#*\"}; db=${db%%\"*}
      case $sql in
        CREATE*)
          [ ! -e "$d/refuse-create" ] || { echo 'ERROR: permission denied to create database' >&2; exit 1; }
          ! grep -qxF "$db" "$d/databases" || exit 1; echo "$db" >>"$d/databases"; echo "$db" >>"$d/created" ;;
        DROP*)
          [ ! -e "$d/refuse-drop" ] || { echo 'ERROR: must be owner of database' >&2; exit 1; }
          drop databases "$db" ;;
      esac
    else
      echo "$name" >>"$d/containers"; echo "$name $cpus" >>"$d/cpusets"
    fi ;;
  'ps '*) cat "$d/containers" ;;
  'inspect '*) awk -v n="${@: -1}" '$1 == n { print $2; exit }' "$d/cpusets" ;;
  'network ls') cat "$d/networks" ;;
  'volume ls') cat "$d/volumes" ;;
  'image ls') cat "$d/images" ;;
  'rm '*) case ${@: -1} in *stuck*) exit 1 ;; esac; drop containers "${@: -1}" ;;
  'network rm') drop networks "${@: -1}" ;;
  'volume rm') drop volumes "${@: -1}" ;;
  'image rm') drop images "${@: -1}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$S/notaskset/taskset" "$S/bin/docker"

# The toy repository: the load check and what it reads, committed, and a
# release boot that fails, as boot.sh's own check does, on a database it
# was handed before, and a release build that fails.
repo="$S/repo"
mkdir -p "$repo/scripts/lib" "$repo/tests/load-check" "$repo/tests/release-boot"
cp "$ROOT/scripts/lib/contain.sh" "$ROOT/scripts/lib/run-names.sh" "$repo/scripts/lib/"
cp "$ROOT/scripts/heavy-check.sh" "$repo/scripts/"
cp "$ROOT/tests/load-check/run.sh" "$ROOT/tests/load-check/needs.sh" "$ROOT/tests/load-check/fresh-database.sh" "$repo/tests/load-check/"
cat >"$repo/tests/release-boot/boot.sh" <<'EOF'
#!/usr/bin/env bash
PG_IMAGE="postgres:stub"
db=${CYFR_DATABASE_URL##*/}; db=${db%%\?*}
grep -qxF "$db" "$DOCKER_STUB/databases" || { echo "no database $db"; exit 1; }
if grep -qxF "$db" "$LOAD_PROBE/boot-used" 2>/dev/null; then echo "the database $db is not fresh"; exit 1; fi
echo "$db" >>"$LOAD_PROBE/boot-used"
sleep 1
EOF
chmod +x "$repo/tests/release-boot/boot.sh"
printf '%s\n' 'release_build() { echo "the $ADAPTER release did not build" >&2; exit 1; }' >"$repo/tests/release-boot/release.sh"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm toy
HEAD=$(git -C "$repo" rev-parse HEAD)

row() { local IFS=$'\t'; echo "$*"; }
table="$S/subjects.tsv"
in_busy='case $LOAD_CHECK_OUT in */r1-busy/*)'
{
  row prep mark - - - 1 30 - 'git rev-parse HEAD >"$LOAD_PROBE/prep-${PWD##*-}.head"; pwd -P >"$LOAD_PROBE/prep-${PWD##*-}.cwd"'
  row warm w - - - 1 30 - 'echo warmed >>"$LOAD_PROBE/warm-${PWD##*-}"'
  row load spin - - - 1 30 - 'grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; if [ -e "$LOAD_PROBE/fail-load" ]; then sleep 0.2; exit 3; fi; exec -a "$LOAD_TEST_TOKEN" sleep 1'
  row image img - - - 1 30 - 'grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; exec -a "$LOAD_TEST_TOKEN" sleep 1'
  row subject probe 1 pair w 2 30 - 'for v in nproc:$(nproc) cpus:$HEAVY_CHECK_CPUS parts:$LOAD_CHECK_PARTS held:${HEAVY_CHECK_HELD-unset} build:${MIX_BUILD_PATH-unset} cwd:$(pwd -P); do echo "${v#*:}" >"$LOAD_CHECK_OUT/${v%%:*}"; done; grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; sh -c "grep Cpus_allowed_list /proc/self/status" >"$LOAD_CHECK_OUT/child-mask"; scripts/heavy-check.sh -- sleep 1 >"$LOAD_CHECK_OUT/nested" 2>&1'
  row subject two 2 pair,whole w 2 30 - 'grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; sleep $((4 / $(nproc)))'
  row subject flaky 1 - - 2 30 - 'for i in 1 2 3 4 5 6; do if pgrep -f "$LOAD_TEST_TOKEN" >/dev/null; then exit 1; fi; sleep 0.2; done'
  row subject late 1 pair - 2 30 - "$in_busy exit 1 ;; */r1-pair/*) echo 'missing prerequisite: a widget'; exit 69 ;; esac; sleep 0.5"
  row subject nap 1 - - 2 30 - 'sleep 2'
  row subject escape 1 - - 2 30 - 'taskset -c "$LOAD_TEST_ALL" sleep 2'
  row subject boxed 1 - - 2 30 - 'docker run -d --name "${PROOF_RUN_PREFIX}box" ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"} stub; sleep 1.5'
  row subject misplaced 1 - - 2 30 - 'docker run -d --name "${PROOF_RUN_PREFIX}wrongbox" --cpuset-cpus "$LOAD_TEST_ALL" stub; sleep 1.5'
  row subject needy 1 - - 2 30 "echo 'no widget here'; exit 1" 'touch "$LOAD_PROBE/needy-ran"'
  row subject absent 1 - - 2 30 - 'echo "absent: the widget is missing" >&2; exit 69'
  row subject noprereq 1 - - 2 30 - 'echo "missing prerequisite: curl" >&2; echo "the proof did not run (exit 77); this is not a pass" >&2; exit 77'
  row subject slow 1 - - 2 2 - 'exec -a "$LOAD_TEST_TOKEN" sleep 8'
  row subject long 1 - - 2 120 - 'docker run -d --name "${PROOF_RUN_PREFIX}box" stub; echo "${PROOF_RUN_PREFIX}net" >>"$DOCKER_STUB/networks"; echo "${PROOF_RUN_PREFIX}vol" >>"$DOCKER_STUB/volumes"; echo "${PROOF_RUN_PREFIX}img:latest" >>"$DOCKER_STUB/images"; mkdir -p "$TMPDIR/${PROOF_RUN_PREFIX}scratch"; grep Cpus_allowed_list /proc/self/status >"$LOAD_CHECK_OUT/mask"; '"$in_busy"' exec -a "$LOAD_TEST_TOKEN" sleep 60 ;; esac; sleep 1.5'
  row subject stuck 1 - - 2 30 - 'docker run -d --name "${PROOF_RUN_PREFIX}stuck" stub; mkdir -p "$TMPDIR/${PROOF_RUN_PREFIX}held"; sleep 1.5'
  row subject whole 4 - - 2 30 - 'touch "$LOAD_PROBE/whole-ran"'
  row subject voidskip 1 pair - 2 30 - "case \$LOAD_CHECK_OUT in */r1-pair/*) echo 'missing prerequisite: a widget'; exit 69 ;; esac; sleep 1"
  row subject warmed 1 - release-sqlite 2 30 - 'touch "$LOAD_PROBE/warmed-ran"'
  row subject warmed2 1 - release-sqlite 2 30 - 'touch "$LOAD_PROBE/warmed-ran"'
  row subject leaky 1 - - 2 30 - 'echo "missing prerequisite: a server at postgres://review:$LOAD_TEST_SECRET@db.example:5432/base" >&2; exit 69'
  # The release warm row, read from the real table.
  awk -F'\t' '$1 == "warm" && $2 == "release-sqlite"' "$ROOT/tests/load-check/subjects.tsv"
  # The release boot's own row, read from the real table, without its warm.
  awk -F'\t' -v OFS='\t' '$1 == "subject" && $2 == "release-boot-postgres" { $5 = "-"; print }' "$ROOT/tests/load-check/subjects.tsv"
} >"$table"
grep -q '^subject	release-boot-postgres	' "$table" && grep -q '^warm	release-sqlite	' "$table" ||
  fail 'the real table has no release-boot-postgres subject or release-sqlite warm row'

fresh() {
  pkill -f "$TOKEN" 2>/dev/null || :
  rm -rf "$S/probe" "$S/docker" "$S/wt" "$TMPDIR"
  mkdir "$S/probe" "$S/docker" "$S/wt" "$TMPDIR"
  git -C "$repo" worktree prune
  printf 'cyfr-postgres\ncyfr-0123456789-1-box\n' >"$S/docker/containers"
  printf 'cyfr-0123456789-1-net\n' >"$S/docker/networks"
  : >"$S/docker/volumes"
  printf 'cyfr-locus:in-0123\n' >"$S/docker/images"
  printf 'base\n' >"$S/docker/databases"
}
# env_of NAME: the environment every load check here runs in.
lc_env=()
set_env() {
  lc_env=(HEAVY_CHECK_HELD=exclusive LOAD_CHECK_CPU_ROOT="$S/cpu" LOAD_CHECK_WORKTREES="$S/wt" LOAD_CHECK_SUBJECTS="$table"
    LOAD_CHECK_SAMPLE=1 LOAD_CHECK_GRACE=10 PATH="$S/bin:$PATH" LOAD_TEST_TOKEN="$TOKEN" LOAD_TEST_ALL="$ALL4"
    LOAD_PROBE="$S/probe" DOCKER_STUB="$S/docker" LOAD_CHECK_BOOT_DATABASE_URL=postgres://u:p@localhost:5432/base
    LOAD_TEST_SECRET="$SECRET2")
}
set_env
# lc NAME [VAR=VALUE...] [-- ARGS]: the toy load check (or mutant NAME's),
# its report in $S/out/NAME, its output in $S/NAME.out and .err, its status
# in $rc.
lc() {
  local script=$repo/tests/load-check/run.sh name=$1 vars=()
  shift
  case $name in mutant-*) script=$repo/tests/load-check/$name.sh ;; esac
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "$#" = 0 ] || shift
  rc=0
  env "${lc_env[@]}" "${vars[@]}" "$script" -o "$S/out/$name" "$@" >"$S/$name.out" 2>"$S/$name.err" || rc=$?
}
# mutant NAME OLD NEW [FILE [COPY]]: a copy of the load check (or of FILE,
# as COPY, else $S/mutant-NAME) with OLD, which it holds once, replaced by
# NEW.
mutant() {
  local src=${4:-$repo/tests/load-check/run.sh} dst=$repo/tests/load-check/mutant-$1.sh
  [ -z "${4:-}" ] || dst=${5:-$S/mutant-$1}
  python3 -I - "$src" "$dst" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src).read()
if text.count(old) != 1:
    sys.exit(f"mutant: {src} does not hold this once: {old}")
open(dst, "w").write(text.replace(old, new))
PY
  chmod +x "$dst"
}
said() { grep -qxF -- "$2" "$S/$1.out" || { echo "$1 did not say: $2"; return 1; }; }
# mask FILE PROCESSORS: the Cpus_allowed_list FILE recorded names PROCESSORS.
mask() {
  local got
  got=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "$1" 2>/dev/null)
  [ -n "$got" ] && [ "$(norm "$got")" = "$(norm "$2")" ] || { echo "$1 allows '$got', not $2"; return 1; }
}

# --- the checks, each a function a control runs against a mutant ----------

no_work() {
  [ -z "$(ls -A "$S/wt")" ] && [ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || { echo 'a worktree was made'; return 1; }
  [ ! -e "$S/out/$1" ] || { echo 'the report directory was made'; return 1; }
  [ -z "$(ls -A "$S/probe")" ] || { echo "a row ran: $(ls "$S/probe")"; return 1; }
}
# placed NAME: each copy and a process it started saw its processors alone,
# and was told them as HEAVY_CHECK_CPUS, with the gate's partitions.
placed() {
  local o=$S/out/$1 c
  for c in busy pair; do
    mask "$o/probe/r1-$c/a/mask" "${Q[1]}" && mask "$o/probe/r1-$c/a/child-mask" "${Q[1]}" &&
      mask "$o/two/r1-$c/a/mask" "${Q[1]},${Q[2]}" || return 1
    [ "$(cat "$o/probe/r1-$c/a/nproc")" = 1 ] && [ "$(norm "$(cat "$o/probe/r1-$c/a/cpus")")" = "${Q[1]}" ] &&
      [ "$(cat "$o/probe/r1-$c/a/parts")" = 4 ] || { echo "probe $c was told other processors"; return 1; }
  done
  mask "$o/probe/r1-pair/b/mask" "${Q[2]}" && mask "$o/probe/r1-pair/b/child-mask" "${Q[2]}" || return 1
  [ "$(norm "$(cat "$o/probe/r1-pair/b/cpus")")" = "${Q[2]}" ] || { echo 'copy b was told other processors'; return 1; }
  mask "$o/two/r1-pair/b/mask" "${Q[3]},${Q[4]}" && mask "$o/two/r1-whole/a/mask" "$ALL4"
}
# busy_placed NAME: each worker ran on its own quarter, never the subject's.
busy_placed() {
  local o=$S/out/$1
  mask "$o/probe/r1-busy/load-w1.out/mask" "${Q[2]}" && mask "$o/probe/r1-busy/load-w2.out/mask" "${Q[3]}" &&
    mask "$o/probe/r1-busy/load-w3.out/mask" "${Q[4]}" && mask "$o/probe/r1-busy/image-w3.out/mask" "${Q[4]}" &&
    mask "$o/two/r1-busy/load-w1.out/mask" "${Q[3]}" && mask "$o/two/r1-busy/load-w2.out/mask" "${Q[4]}"
}
# busy_gone NAME: no load step began more than 2 s after its busy run
# ended, and nothing of the load is left.
busy_gone() {
  python3 -I - "$S/out/$1" <<'PY' || return 1
import csv, glob, os, sys
out = sys.argv[1]
with open(os.path.join(out, "report.tsv")) as f:
    rows = [r for r in csv.DictReader(f, delimiter="\t") if r["condition"] == "busy"]
if not rows:
    sys.exit("no busy run")
for r in rows:
    for path in glob.glob(os.path.join(out, r["subject"], f"r{r['round']}-busy", "*.status")):
        begins = [float(l.split()[2]) for l in open(path) if l.startswith("begin ")]
        if not begins or max(begins) > float(r["ended"]) + 2:
            sys.exit(f"{path}: a step began after its run ended")
PY
  ! pgrep -f "$TOKEN" >/dev/null || { echo 'a stub still runs'; return 1; }
}
# own_trees NAME: each worktree its own at the toy HEAD, each copy in its
# own one, the caller's MIX_BUILD_PATH unseen, a heavy-check inside a copy
# run in place so the pair ran side by side, the warm row once in a and
# once in b, and no worktree left.
own_trees() {
  local o=$S/out/$1 role
  for role in a b w1 w2 w3; do
    [ "$(cat "$S/probe/prep-$role.head" 2>/dev/null)" = "$HEAD" ] || { echo "worktree $role is not at $HEAD"; return 1; }
  done
  [ "$(cat "$S"/probe/prep-*.cwd | sort -u | wc -l)" = 5 ] || { echo 'the worktrees are not five directories'; return 1; }
  case $(cat "$o/probe/r1-pair/a/cwd")/$(cat "$o/probe/r1-pair/b/cwd") in
    "$S/wt/"*-load-check-a/"$S/wt/"*-load-check-b) ;; *) echo 'a copy ran outside its worktree'; return 1 ;;
  esac
  [ "$(cat "$o/probe/r1-busy/a/build")" = unset ] || { echo 'a copy saw the caller'"'"'s MIX_BUILD_PATH'; return 1; }
  [ "$(cat "$o/probe/r1-pair/b/held")" = exclusive ] || { echo 'a copy lost HEAVY_CHECK_HELD'; return 1; }
  python3 -I - "$o/report.tsv" <<'PY' || return 1
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1]), delimiter="\t") if r["subject"] == "probe"]
busy = next(float(r["seconds"]) for r in rows if r["condition"] == "busy")
pair = [r for r in rows if r["condition"] == "pair"]
if len(pair) != 2 or max(float(r["seconds"]) for r in pair) > busy + 0.5:
    sys.exit("the copies of the pair queued for each other")
PY
  [ "$(cat "$S/probe/warm-a" 2>/dev/null)" = warmed ] && [ "$(cat "$S/probe/warm-b" 2>/dev/null)" = warmed ] &&
    [ ! -e "$S/probe/warm-w1" ] || { echo 'the warm row ran other than once in a and once in b'; return 1; }
  [ -z "$(ls -A "$S/wt")" ] && [ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || { echo 'a worktree is left'; return 1; }
}
# ratio NAME: two's busy/whole is the quotient of its medians.
ratio() {
  python3 -I - "$S/out/$1/report.tsv" "$S/$1.out" <<'PY'
import csv, re, statistics, sys
rows = [r for r in csv.DictReader(open(sys.argv[1]), delimiter="\t") if r["subject"] == "two" and r["status"] == "passed"]
med = lambda c: statistics.median(float(r["seconds"]) for r in rows if r["condition"] == c)
want = f"{med('busy') / med('whole'):.2f}"
got = re.findall(r"^  whole \d+/\d+ passed, median [\d.]+s; busy/whole ([\d.]+)$", open(sys.argv[2]).read(), re.M)
if got != [want]:
    sys.exit(f"busy/whole is {got}, the medians give {want}")
PY
}

# --- the cases ---------------------------------------------------------------

begin 'a refused run starts no work: outside the exclusive lane, without taskset, on three cores, with a busy load that cannot run'
fresh
lc lane HEAVY_CHECK_HELD= -- -s probe
[ "$rc" = 64 ] && grep -q 'takes the whole host' "$S/lane.err" && no_work lane || fail "unheld: $rc $(cat "$S/lane.err")"
lc scoped HEAVY_CHECK_HELD=scoped -- -s probe
[ "$rc" = 64 ] && no_work scoped || fail "scoped: $rc $(cat "$S/scoped.err")"
lc notaskset PATH="$S/notaskset:$S/bin:$PATH" -- -s probe
[ "$rc" = 69 ] && grep -q 'taskset (util-linux) is required' "$S/notaskset.err" && no_work notaskset || fail "no taskset: $rc $(cat "$S/notaskset.err")"
lc three LOAD_CHECK_CPU_ROOT="$S/cpu3" -- -s probe
[ "$rc" = 69 ] && grep -q 'this host has 3 whole cores' "$S/three.err" && no_work three || fail "three cores: $rc $(cat "$S/three.err")"
sed 's/^load\tspin\t-\t-\t-\t1\t30\t-\t/load\tspin\t-\t-\t-\t1\t30\techo no load here; exit 1\t/' "$table" >"$S/noload.tsv"
lc noload LOAD_CHECK_SUBJECTS="$S/noload.tsv" -- -s probe
[ "$rc" = 69 ] && grep -qF 'the load row spin: no load here' "$S/noload.err" && no_work noload || fail "no load: $rc $(cat "$S/noload.err")"
mutant lane 'if ! $DRY && [ "${HEAVY_CHECK_HELD:-}" != exclusive ]; then' 'if false; then'
lc mutant-lane HEAVY_CHECK_HELD= -- -s nap -c alone
! no_work mutant-lane >/dev/null || fail 'no_work passed a run that did work'

begin 'each run sees exactly its processors and is told them, the load runs on the other quarters and stops with its run, each worktree is its own'
fresh
gone=$(sh -c 'echo $$')
until_true 5 test ! -e "/proc/$gone"
git -C "$repo" worktree add -q --detach "$S/wt/cyfr-0123456789-$gone-load-check-a" HEAD
lc place MIX_BUILD_PATH=/elsewhere/_build -- -s probe,two
[ "$rc" = 0 ] || fail "the run exited $rc: $(tail -n 5 "$S/place.err")"
grep -qF "removed $S/wt/cyfr-0123456789-$gone-load-check-a, which load check $gone left" "$S/place.err" || fail 'the gone run'"'"'s worktree was kept'
placed place || fail "$(placed place)"
busy_placed place || fail "$(busy_placed place)"
busy_gone place || fail "$(busy_gone place)"
own_trees place || fail "$(own_trees place)"
ratio place || fail "$(ratio place 2>&1)"
said place 'verdict: holds: 2' && ! awk -F'\t' '$3 == "alone"' "$S/out/place/report.tsv" | grep -q . || fail "$(cat "$S/place.out")"
mutant place 'taskset -c "$3" \' 'taskset -c "$ALL" \'
fresh; lc mutant-place -- -s probe,two
! placed mutant-place >/dev/null || fail 'placed passed copies run on every processor'
mutant busy-place 'taskset -c "${QUARTER[$quarter]}" \' 'taskset -c "$ALL" \'
fresh; lc mutant-busy-place -- -s probe,two -c busy
! busy_placed mutant-busy-place >/dev/null || fail 'busy_placed passed workers run on every processor'
mutant busy-stop '    busy_held "${J_START[0]}" "${J_END[0]}" || :
    stop_busy' '    busy_held "${J_START[0]}" "${J_END[0]}" || :'
fresh; lc mutant-busy-stop -- -s probe,two -c busy,pair
! busy_gone mutant-busy-stop >/dev/null 2>&1 || fail 'busy_gone passed workers that went on after their run'
launch_env='env -u MIX_BUILD_PATH -u MIX_DEPS_PATH -u CYFR_TEST_CORES -u CARGO_BUILD_JOBS -u ERL_FLAGS \
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" HEAVY_CHECK_CPUS="$3"'
mutant env "$launch_env" 'env PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" HEAVY_CHECK_CPUS="$3"'
fresh; lc mutant-env MIX_BUILD_PATH=/elsewhere/_build -- -s probe,two
! own_trees mutant-env >/dev/null 2>&1 || fail 'own_trees passed a copy that saw the caller'"'"'s MIX_BUILD_PATH'
mutant queued "$launch_env" "${launch_env/env -u MIX_BUILD_PATH/env -u HEAVY_CHECK_HELD -u MIX_BUILD_PATH}"
fresh; lc mutant-queued -- -s probe,two
! own_trees mutant-queued >/dev/null 2>&1 || fail 'own_trees passed a pair whose heavy-checks queued'
mutant warm '    WARMED[$role/$w]=1
' ''
fresh; lc mutant-warm -- -s probe,two
! own_trees mutant-warm >/dev/null 2>&1 || fail 'own_trees passed a warm row run twice in one worktree'
mutant sweep 'if remove_worktree "$path"; then say' 'if false; then say'
fresh; git -C "$repo" worktree add -q --detach "$S/wt/cyfr-0123456789-$gone-load-check-a" HEAD
lc mutant-sweep -- -s nap -c alone
[ -d "$S/wt/cyfr-0123456789-$gone-load-check-a" ] || fail 'the sweep control removed the gone run'"'"'s worktree'
mutant ratio 'f"{b / m:.2f}"' 'f"{m / b:.2f}"'
fresh; lc mutant-ratio -- -s two -c busy,whole
! ratio mutant-ratio 2>/dev/null || fail 'ratio passed an inverted busy/whole'

begin 'a subject that fails busy runs alone, and passing there is named FAILS BUSY with exit 1; a later skip keeps the failure'
fresh
lc busy -- -s flaky,late
[ "$rc" = 1 ] && said busy 'flaky (1 quarter): FAILS BUSY' && said busy 'late (1 quarter): FAILS BUSY' &&
  said busy 'verdict: holds: 0; FAILS BUSY: flaky late' || fail "the run exited $rc: $(cat "$S/busy.out")"
[ "$(awk -F'\t' '$1 == "late" { printf "%s:%s ", $3, $6 }' "$S/out/busy/report.tsv")" = 'busy:failed pair:skipped pair:skipped alone:passed ' ] ||
  fail "late's runs: $(grep late "$S/out/busy/report.tsv")"
mutant no-busy 'if [ "$c" = busy ] && ! start_busy "$q" "$dir"; then' 'if false; then'
fresh; lc mutant-no-busy -- -s flaky
! said mutant-no-busy 'flaky (1 quarter): FAILS BUSY' >/dev/null || fail 'without a busy load the stub still failed'
mutant skip-first '    if bad("busy") or bad("pair"):' '    if name in skips:
        verdict = skips[name]
        skipped.append(name)
    elif bad("busy") or bad("pair"):'
fresh; lc mutant-skip-first -- -s late
! said mutant-skip-first 'late (1 quarter): FAILS BUSY' >/dev/null && [ "$rc" = 69 ] || fail 'the skip-first control still named the failure'

begin 'a run that passes while its load step fails, or with a process or a container outside its processors, is void and named'
fresh
touch "$S/probe/fail-load"
lc void -- -s nap,voidskip -c busy,pair
[ "$rc" = 1 ] && said void 'nap (1 quarter): not decided: a run was void' &&
  said void 'voidskip (1 quarter): not decided: a run was void' || fail "the run exited $rc: $(cat "$S/void.out")"
[ "$(awk -F'\t' '$1 == "voidskip" { printf "%s:%s ", $3, $6 }' "$S/out/void/report.tsv")" = 'busy:void pair:skipped pair:skipped ' ] ||
  fail "voidskip's runs: $(grep voidskip "$S/out/void/report.tsv")"
mutant skip-before-void '    elif any(r["status"] == "void" for r in runs):' '    elif name in skips:
        verdict = skips[name]
        skipped.append(name)
    elif any(r["status"] == "void" for r in runs):'
fresh; touch "$S/probe/fail-load"; lc mutant-skip-before-void -- -s voidskip -c busy,pair
! said mutant-skip-before-void 'voidskip (1 quarter): not decided: a run was void' >/dev/null && [ "$rc" = 69 ] ||
  fail 'the skip-before-void control still kept the void run'
fresh
touch "$S/probe/fail-load"
awk -F'\t' '$1 == "nap" && $6 == "void" && index($11, "the busy load'"'"'s load-w1 on quarter 2: spin exited 3 while the subject ran")' "$S/out/void/report.tsv" | grep -q . ||
  fail "the void run: $(cat "$S/out/void/report.tsv")"
mutant held 'busy_held "${J_START[0]}" "${J_END[0]}" || :' ':'
lc mutant-held -- -s nap -c busy
! said mutant-held 'nap (1 quarter): not decided: a run was void' >/dev/null || fail 'the load control still voided the run'
fresh
lc outside -- -s escape,boxed,misplaced -c alone
said outside 'escape (1 quarter): not decided: a run was void' && said outside 'boxed (1 quarter): holds' &&
  said outside 'misplaced (1 quarter): not decided: a run was void' || fail "$(cat "$S/outside.out")"
line=$(awk -F'\t' -v q="${Q[1]}" '$1 == "escape" && $5 == "process" && $7 == "sleep" && $9 == q { print $8; exit }' "$S/out/outside/masks.tsv")
[ -n "$line" ] && [ "$(norm "$line")" = "$ALL4" ] || fail "masks.tsv names no escaped process: $(cat "$S/out/outside/masks.tsv")"
awk -F'\t' '$1 == "misplaced" && $5 == "container" && $7 ~ /wrongbox$/' "$S/out/outside/masks.tsv" | grep -q . &&
  ! awk -F'\t' '$1 == "boxed"' "$S/out/outside/masks.tsv" | grep -q . || fail "masks.tsv: $(cat "$S/out/outside/masks.tsv")"
mutant sample 'if [ "$SECONDS" -ge "$next" ]; then sample; next=$((SECONDS + SAMPLE)); fi' ':'
fresh; lc mutant-sample -- -s escape,misplaced -c alone
said mutant-sample 'escape (1 quarter): holds' >/dev/null && said mutant-sample 'misplaced (1 quarter): holds' >/dev/null ||
  fail 'without sampling an escape was still seen'
mutant container '      if [ -n "$allowed" ] && [ "$(cpus_of "$allowed" 2>/dev/null)" != "$(cpus_of "${J_CPUS[$i]}")" ]; then' '      if false; then'
fresh; lc mutant-container -- -s misplaced -c alone
said mutant-container 'misplaced (1 quarter): holds' >/dev/null || fail 'without the container check the misplaced container was still seen'

begin 'a subject without its prerequisite, by its precondition or by exit 69 or 77, is skipped with the reason, and the run exits 69'
fresh
lc skip -- -s needy,absent,noprereq,whole
[ "$rc" = 69 ] || fail "the run exited $rc: $(tail -n 5 "$S/skip.err")"
said skip 'needy: skipped: no widget here' && said skip 'absent (1 quarter): skipped: exited 69: absent: the widget is missing' &&
  said skip 'noprereq (1 quarter): skipped: exited 77: missing prerequisite: curl' && said skip 'whole: not measured: it takes all four quarters' &&
  said skip 'verdict: holds: 0; skipped: needy absent noprereq; not measured: whole' || fail "$(cat "$S/skip.out")"
[ ! -e "$S/probe/needy-ran" ] && [ ! -e "$S/probe/whole-ran" ] || fail 'a skipped subject ran'
mutant needs '  [ "$1" != - ] || return 0
  out=' '  return 0
  out='
fresh; lc mutant-needs -- -s needy -c alone
[ -e "$S/probe/needy-ran" ] || fail 'the precondition control still skipped'
mutant seventy-seven '      69|77)' '      69)'
fresh; lc mutant-seventy-seven -- -s noprereq
! said mutant-seventy-seven 'noprereq (1 quarter): skipped: exited 77: missing prerequisite: curl' >/dev/null && [ "$rc" = 1 ] ||
  fail 'the exit 77 control still skipped'

begin 'a run that reaches its deadline is stopped with what it started and fails'
fresh
lc deadline -- -s slow -c alone
[ "$rc" = 1 ] && said deadline 'slow (1 quarter): fails alone' &&
  [ "$(awk -F'\t' '$1 == "slow" && $6 == "deadline" && $8 < 6' "$S/out/deadline/report.tsv" | wc -l)" = 1 ] ||
  fail "the run exited $rc: $(cat "$S/out/deadline/report.tsv")"
! pgrep -f "$TOKEN" >/dev/null || fail 'a stub outlived its deadline'
mutant deadline 'elif [ "$SECONDS" -ge "${J_DUE[$i]}" ]; then' 'elif false; then'
fresh; lc mutant-deadline -- -s slow -c alone
! awk -F'\t' '$6 == "deadline"' "$S/out/mutant-deadline/report.tsv" | grep -q . || fail 'the deadline control still stopped the run'

begin 'each PostgreSQL release boot is handed a fresh database, which is dropped after it'
fresh
lc boot -- -s release-boot-postgres -c busy,pair
[ "$rc" = 0 ] && said boot 'release-boot-postgres (1 quarter): holds' || fail "the run exited $rc: $(cat "$S/boot.out")"
[ "$(sort -u "$S/probe/boot-used" | grep -c '^cyfr_load_check_')" = 3 ] && [ "$(wc -l <"$S/probe/boot-used")" = 3 ] ||
  fail "the boots were handed: $(cat "$S/probe/boot-used")"
[ "$(cat "$S/docker/databases")" = base ] && [ "$(wc -l <"$S/docker/created")" = 3 ] || fail "databases left: $(cat "$S/docker/databases")"
awk -F'\t' -v OFS='\t' '$2 == "release-boot-postgres" { $9 = "CYFR_DATABASE_URL=\"$LOAD_CHECK_BOOT_DATABASE_URL\" tests/release-boot/boot.sh postgres" } { print }' "$table" >"$S/shared.tsv"
fresh; lc shared LOAD_CHECK_SUBJECTS="$S/shared.tsv" -- -s release-boot-postgres -c busy,pair
! said shared 'release-boot-postgres (1 quarter): holds' >/dev/null || fail 'one database for every run still held'

begin 'TERM stops every run and worker, then removes what the run and its subjects made'
# term NAME SCRIPT: the long subject, stopped once its busy run is under way.
term() {
  rc=0
  env "${lc_env[@]}" "$2" -s long -c busy -o "$S/out/$1" >"$S/$1.out" 2>"$S/$1.err" &
  pid=$!
  until_true 60 test -s "$S/out/$1/long/r1-busy/a/mask" && until_true 10 test -s "$S/out/$1/long/r1-busy/load-w1.out/mask" ||
    fail "the busy run did not start: $(tail -n 5 "$S/$1.err")"
  until_true 10 awk -F'\t' '$4 == "long a" && $6 == "any processor" { f = 1 } END { exit !f }' "$S/out/$1/docker.tsv" || fail 'the container was not recorded'
  kill -TERM "$pid"
  wait "$pid" || rc=$?
}
fresh
term term "$repo/tests/load-check/run.sh"
[ "$rc" = 143 ] || fail "TERM ended the run with $rc: $(tail -n 5 "$S/term.err")"
! pgrep -f "$TOKEN" >/dev/null || fail 'a stub outlived TERM'
[ -z "$(ls -A "$S/wt")" ] && [ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || fail "worktrees are left: $(ls "$S/wt")"
! grep -qE "^cyfr-[0-9a-f]{10}-$pid-" "$S"/docker/containers "$S"/docker/networks "$S"/docker/volumes "$S"/docker/images || fail 'a Docker object of the run is left'
grep -qx cyfr-postgres "$S/docker/containers" && grep -qx cyfr-0123456789-1-box "$S/docker/containers" &&
  grep -qx cyfr-0123456789-1-net "$S/docker/networks" && grep -qx cyfr-locus:in-0123 "$S/docker/images" || fail 'an object that is not the run'"'"'s was removed'
! ls "$TMPDIR" | grep -qE "^cyfr-[0-9a-f]{10}-$pid-" || fail "a scratch entry of the run is left: $(ls "$TMPDIR")"
mutant cleanup '  if [ "$s" = 0 ] && ! $FINISHED; then s=1; fi
  cleanup' '  if [ "$s" = 0 ] && ! $FINISHED; then s=1; fi'
fresh; term mutant-cleanup "$repo/tests/load-check/mutant-cleanup.sh"
[ -n "$(ls -A "$S/wt")" ] || fail 'the clean-up control removed its worktrees'

begin 'a container that cannot be removed keeps the worktrees and scratch entries it may hold, each named, and the exit is 1'
fresh
lc stuck -- -s stuck -c alone
[ "$rc" = 1 ] || fail "the run exited $rc"
for f in "$S"/wt/*-load-check-a "$TMPDIR"/cyfr-*-held; do
  [ -e "$f" ] && grep -qF "kept $f: the container " "$S/stuck.err" || fail "$f was not kept and named: $(cat "$S/stuck.err")"
done
mutant keep '    if [ -n "$HELD" ]; then' '    if false; then'
fresh; lc mutant-keep -- -s stuck -c alone
[ -z "$(ls -A "$S/wt")" ] || fail 'the keep control still kept the worktrees'

begin 'a warm row that fails leaves every subject naming it void, named, with exit 1, and its scratch directory is removed'
fresh
lc warm -- -s warmed,warmed2 -c alone
[ "$rc" = 1 ] && said warm 'warmed (1 quarter): not decided: the warm row release-sqlite failed in worktree a (exit 1)' &&
  said warm 'warmed2 (1 quarter): not decided: the warm row release-sqlite failed in worktree a (exit 1)' || fail "the run exited $rc: $(cat "$S/warm.out")"
[ ! -e "$S/probe/warmed-ran" ] && [ "$(wc -l <"$S/out/warm/warm.tsv")" = 1 ] || fail 'a subject ran on a failed warm, or the warm ran twice'
[ -z "$(ls -A "$TMPDIR")" ] || fail "the warm left: $(ls -A "$TMPDIR")"
mutant warm-failed '      [ "${J_STATUS[$i]}" = 0 ] ||
        WARM_FAILED' '      true ||
        WARM_FAILED'
fresh; lc mutant-warm-failed -- -s warmed -c alone
! said mutant-warm-failed 'warmed (1 quarter): not decided: the warm row release-sqlite failed in worktree a (exit 1)' >/dev/null && [ "$rc" = 0 ] ||
  fail 'the warm control still voided the subject'
sed 's#^\(warm\trelease-sqlite\t.*\t\)ADAPTER=sqlite WORK=[^ ]* \(.*\)$#\1ADAPTER=sqlite WORK=$(mktemp -d) \&\& . tests/release-boot/release.sh \&\& release_build; s=$?; rm -rf "$WORK"; exit $s#' "$table" >"$S/oldwarm.tsv"
grep -q 'WORK=$(mktemp -d) &&' "$S/oldwarm.tsv" || fail 'the old warm row was not written'
fresh; lc oldwarm LOAD_CHECK_SUBJECTS="$S/oldwarm.tsv" -- -s warmed -c alone
[ -n "$(ls -A "$TMPDIR")" ] || fail 'the old warm row left nothing behind'

begin 'no message, report or log of the check holds a password a URL carried'
fresh
url="postgres://review:$SECRET@localhost:5432/base"
helper() { # NAME [SCRIPT]: the database helper on url, with the stand-in docker
  rc=0
  env PATH="$S/bin:$PATH" DOCKER_STUB="$S/docker" "${2:-$repo/tests/load-check/fresh-database.sh}" "$url" true >"$S/$1.out" 2>"$S/$1.err" || rc=$?
}
touch "$S/docker/refuse-create"; helper create
[ "$rc" = 1 ] && grep -qE '^fresh database: could not create cyfr_load_check_[0-9]+_[0-9a-f]{8} on postgres://localhost:5432$' "$S/create.err" ||
  fail "the refused create: $rc $(cat "$S/create.err")"
rm "$S/docker/refuse-create"; touch "$S/docker/refuse-drop"; helper drop
[ "$rc" = 1 ] && grep -qE '^fresh database: could not drop cyfr_load_check_[0-9]+_[0-9a-f]{8} on postgres://localhost:5432$' "$S/drop.err" ||
  fail "the refused drop: $rc $(cat "$S/drop.err")"
rm "$S/docker/refuse-drop"; touch "$S/docker/refuse-create"
lc leak LOAD_CHECK_BOOT_DATABASE_URL="$url" -- -s release-boot-postgres,leaky -c busy,alone
[ "$rc" = 1 ] && said leak 'leaky (1 quarter): skipped: exited 69: missing prerequisite: a server at postgres://[redacted]@db.example:5432/base' ||
  fail "the run exited $rc: $(cat "$S/leak.out")"
! grep -rqF "$SECRET" "$S/out/leak" "$S/leak.out" "$S/leak.err" "$S/create.out" "$S/create.err" "$S/drop.out" "$S/drop.err" ||
  fail "the password is in: $(grep -rlF "$SECRET" "$S/out/leak" "$S/leak.out" "$S/leak.err" "$S"/create.* "$S"/drop.*)"
! grep -qF "$SECRET2" "$S/leak.out" "$S/leak.err" "$S/out/leak/report.tsv" "$S/out/leak/report.txt" "$S/out/leak/skips.tsv" ||
  fail 'a password a subject printed is in the check'"'"'s own lines'
grep -qF "$SECRET2" "$S/out/leak/leaky/r1-busy/a.log" || fail 'the stub did not print its password'
mutant leak 'server=$(printf' 'server=${base%/*} || server=$(printf' "$ROOT/tests/load-check/fresh-database.sh" "$repo/tests/load-check/mutant-leak.sh"
fresh; touch "$S/docker/refuse-create"; helper mutant-leak "$repo/tests/load-check/mutant-leak.sh"
grep -qF "$SECRET" "$S/mutant-leak.err" || fail 'the helper control did not print the password'
mutant redact '        note="exited ${J_STATUS[$i]}: $(redact "${why:-a missing prerequisite}")"' '        note="exited ${J_STATUS[$i]}: ${why:-a missing prerequisite}"'
fresh; lc mutant-redact -- -s leaky -c alone
grep -qF "$SECRET2" "$S/mutant-redact.out" || fail 'the note control did not print the password'

begin 'the partitions a run is told are the commit gate'"'"'s, and every container the browser harness and the install proof start is placed'
# gate_rule SCRIPT N: what the gate's own lines pick on N processors;
# load_rule N: what the load check's gate_parts picks.
gate_rule() {
  local block n=$2
  block=$(awk '/^if \[ -z "\$PARTS" \]; then$/ { on = 1 } on { print } on && /^fi$/ { exit }' "$1")
  [ -n "$block" ] || return 1
  (PARTS= && sysctl() { return 1; } && nproc() { echo "$n"; } && eval "$block" && echo "$PARTS")
}
load_rule() { (eval "$(sed -n '/^gate_parts() {/p' "$ROOT/tests/load-check/run.sh")" && gate_parts "$1"); }
parity() {
  local n
  for n in $(seq 1 64); do
    [ "$(gate_rule "$1" "$n")" = "$(load_rule "$n")" ] || { echo "on $n processors the gate picks '$(gate_rule "$1" "$n")', the load check $(load_rule "$n")"; return 1; }
  done
}
parity "$ROOT/scripts/commit-gate.sh" || fail "$(parity "$ROOT/scripts/commit-gate.sh")"
mutant gate 'if [ "$cores" -ge 16 ]; then PARTS=8; else PARTS=4; fi' 'if [ "$cores" -ge 12 ]; then PARTS=8; else PARTS=4; fi' "$ROOT/scripts/commit-gate.sh"
! parity "$S/mutant-gate" >/dev/null || fail 'parity passed a gate that picks otherwise'
# placed_containers FILE...: every docker run and docker create in FILE
# passes the processors it is given.
placed_containers() {
  python3 -I - "$@" <<'PY'
import re, sys
for path in sys.argv[1:]:
    text = re.sub(r"\\\n\s*", " ", open(path).read())
    for line in text.splitlines():
        if line.lstrip().startswith("#") or not re.search(r"\bdocker (run|create)\b", line):
            continue
        if '${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"}' not in line:
            sys.exit(f"{path}: a container is not placed: {line.strip()[:120]}")
PY
}
placed_containers "$ROOT/tests/browser/harness.sh" "$ROOT/tests/install-screen-proof/lib.sh" ||
  fail "$(placed_containers "$ROOT/tests/browser/harness.sh" "$ROOT/tests/install-screen-proof/lib.sh" 2>&1)"
mutant unplaced '  docker create --init --name "$GUEST" ${HEAVY_CHECK_CPUS:+--cpuset-cpus "$HEAVY_CHECK_CPUS"}' '  docker create --init --name "$GUEST"' "$ROOT/tests/install-screen-proof/lib.sh"
! placed_containers "$S/mutant-unplaced" 2>/dev/null || fail 'placed_containers passed an unplaced guest'

begin 'the dry run prints the chosen runs with their processors and the time, runs nothing, and keeps a core'"'"'s threads in one quarter'
fresh
lc dry HEAVY_CHECK_HELD= LOAD_CHECK_CPU_ROOT="$S/smt16" -- -n -s probe,two,needy,whole
[ "$rc" = 0 ] && no_work dry || fail "the dry run exited $rc: $(cat "$S/dry.err")"
for line in 'quarter 1: 0,1,8,9' 'quarter 4: 6,7,14,15' 'warmed: w, about 1s' \
  'subject probe: 1 quarter(s), warm w; busy 0,1,8,9, load 2,3,4,5,6,7,10,11,12,13,14,15; pair a 0,1,8,9 b 2,3,10,11; alone 0,1,8,9 after a failure; about 4s' \
  'subject two: 2 quarter(s), warm w; busy 0,1,2,3,8,9,10,11, load 4,5,6,7,12,13,14,15; pair a 0,1,2,3,8,9,10,11 b 4,5,6,7,12,13,14,15; whole 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15; alone 0,1,2,3,8,9,10,11 after a failure; about 5s' \
  'subject needy: skipped: no widget here' 'subject whole: not measured: it takes all four quarters' \
  'expected: about 12s for 2 measured subject(s), 1 skipped, 1 not measured, besides an alone run after each failure'; do
  said dry "$line" || fail "$(cat "$S/dry.out")"
done
lc pick HEAVY_CHECK_HELD= LOAD_CHECK_CPU_ROOT="$S/smt16" -- -n -s probe,two -c whole -r 2
said pick 'subject probe: none of its conditions is chosen' &&
  said pick 'subject two: 2 quarter(s), warm w; whole 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15; about 2s' || fail "$(cat "$S/pick.out")"
mutant siblings '  key=${sib// /,}' '  sib=$cpu key=$cpu'
lc mutant-siblings HEAVY_CHECK_HELD= LOAD_CHECK_CPU_ROOT="$S/smt16" -- -n -s probe
! said mutant-siblings 'quarter 1: 0,1,8,9' >/dev/null || fail 'the siblings control still kept a core in one quarter'

echo 'load check self-test: every case passed'
