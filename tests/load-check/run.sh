#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The load check: tests/load-check/run.sh [-n] [-s SUBJECT[,SUBJECT...]] [-r ROUNDS] [-o OUTDIR]
#
# Whether each check still passes, and how much slower it runs, on a
# quarter of this host's cores while the other quarters are busy, and
# beside a second copy of itself (README.md says what its answer decides).
# It takes the whole machine, so it runs only under scripts/heavy-check.sh's
# exclusive lane (HEAVY_CHECK_HELD=exclusive), for example
#   scripts/heavy-check.sh -t 43200 -- tests/load-check/run.sh
# and refuses with 64 anywhere else. -n prints the plan, the quarters each
# run takes and the time expected, and runs nothing, in any lane or none.
# -s picks the subjects by name (all by default), -r the rounds (3), -o
# a new or empty directory for the report and the logs (by default a fresh
# /tmp/cyfr-evidence.load-check.XXXXXX, which scripts/janitor.sh removes
# after seven days).
#
# The quarters. The host's online processors (LOAD_CHECK_CPU_ROOT, default
# /sys/devices/system/cpu: its `online` list and each processor's
# topology/thread_siblings_list) group into whole cores, one core per
# siblings list, ordered by their lowest processor. The first 4k cores, k
# the cores divided by four and rounded down, are cut in that order into
# four quarters of k cores, both threads of a core always in one quarter;
# cores left over run nothing of the check's. Every command runs under
# `taskset -c` on the processors it is given, which every process it
# starts inherits, so nproc, the Erlang runtime and cargo size themselves
# to them.
#
# The table, tests/load-check/subjects.tsv (LOAD_CHECK_SUBJECTS names
# another), is one row per line of eight fields separated by single tabs:
#   kind  name  quarters  pair  expect  deadline  needs  command
# kind is prep (a step that prepares every scratch worktree, in table
# order), load (a step of the busy load), image (the busy load's image
# build) or subject; name is [a-z0-9-]+ and unique within its kind;
# quarters is a subject's 1, 2 or 4, where 4 means it takes the whole
# machine and is not measured, and `-` for every other kind; pair is
# `pair` for a subject that also runs beside a second copy of itself, else
# `-`; expect is the seconds one run takes on its quarters, for the plan;
# deadline is the seconds after which a run is stopped; needs is `-` or a
# command run by bash from the checkout's root before any work, which
# exits 0 when the row's prerequisite holds and otherwise prints why not;
# command is run by bash from the scratch worktree's root. Lines that
# start with # and blank lines are skipped. A bad line is refused with 65,
# naming it.
#
# The scratch worktrees are detached checkouts of the checkout's HEAD
# (uncommitted changes are not measured), under LOAD_CHECK_WORKTREES
# (default the checkout's parent directory), each with its own sources,
# _build and deps: a runs the subjects, b the second copy of a paired
# subject, and w1 to w3 the busy load, one for each quarter a subject
# leaves. Every prep row runs in each, cold, with the whole machine: a's
# first, then the others side by side; their times are reported as what
# the worktrees cost to build cold. A subject whose precondition fails is
# skipped with its reason before any work, and so is one that exits 69
# (a missing prerequisite) in any run; a skipped subject never counts as
# passed.
#
# The runs. Each subject runs once unmeasured to warm its worktrees (a,
# and b beside it for a paired subject), then ROUNDS rounds of these runs,
# in an order turned by one each round:
#   alone   on quarters 1 to q (q its quarters), the others idle
#   busy    on quarters 1 to q, the busy load on every other quarter
#   pair    a paired subject: a on quarters 1 to q, b on q+1 to 2q
#   whole   a subject of two quarters: on all four, as it runs today
# The busy load is one worker for each quarter the subject leaves, in a
# worktree of its own, running the load rows in a loop, and on the last
# of those quarters a second worker running the image rows in a loop (a
# cold image build, which the Docker daemon runs on any processor); each
# step is stopped at its row's deadline, which counts as the step
# failing. The subject starts once every worker has begun, and the
# workers stop when it ends. A busy run counts as passed only when every
# worker still ran when the subject ended and no load step failed while
# it ran; otherwise it is void, naming the worker.
#
# Placement is checked while each run goes, every LOAD_CHECK_SAMPLE
# seconds (5): every process descended from a run's or a worker's leader
# must be allowed exactly the processors it was given (Cpus_allowed_list).
# A process outside them is named, and its run counts as void rather than
# passed. Docker containers named under a run's prefix are recorded with
# their cpuset, and the host's other containers at the start: what Docker
# runs, the host's services and the agents' own processes are the
# placement this check does not hold.
#
# The report, in OUTDIR: report.tsv, one line per run (subject, round,
# condition, copy, processors, status, exit, seconds, started and ended as
# Unix times, note, log), where the
# status is passed, failed, deadline (stopped at the row's deadline),
# skipped or void; skips.tsv, masks.tsv (processes outside their
# processors), docker.tsv, prep.tsv, plan.txt and report.txt, the summary
# it prints last. The summary gives, per subject and condition, the runs
# passed and the median seconds of the passed runs, and two ratios kept
# apart: busy against alone (each condition's median over the alone
# median; pair counts both copies' runs), and, for a subject of two
# quarters, two quarters against the whole machine (the alone median over
# the whole median). A ratio with no passed run on either side is n/a.
#
# Exits 0 when every selected subject was measured and every one of its
# runs passed, and its clean-up was clean; 1 when a subject failed busy or
# beside its second copy while it passed alone (named "fails busy"), when
# any other run failed or was void, when preparation failed, or when the
# clean-up left something; 69 when nothing failed but a subject was
# skipped; 64 on usage or outside the exclusive lane; 65 for a bad table;
# 69 without Bash 5, taskset, four whole cores, git, python3 or pgrep, or
# when a precondition of a prep, load or image row fails, before any work;
# 130, 143 and 129 on INT, TERM and HUP.
#
# Every command runs contained (scripts/lib/contain.sh) under a leader
# that, stopped, passes the signal to its process group and waits for it
# to empty, so a subject's own clean-up runs; a stop gives it
# LOAD_CHECK_GRACE seconds (120) before the session is killed. On every exit path, a signal
# and a deadline included, the check stops every run and worker it started,
# then removes the Docker containers, networks, volumes and image tags,
# and the $TMPDIR entries, named under its run prefixes, then its
# worktrees; anything it cannot remove is named on stderr and makes the
# exit 1. The prefixes are scripts/lib/run-names.sh's for each worktree
# with this script's pid, each run's PROOF_RUN_PREFIX, so scripts/janitor.sh
# knows what a killed run left; a worktree a load check that is gone left
# is removed at the next one's start. Each command's environment loses
# MIX_BUILD_PATH, MIX_DEPS_PATH, CYFR_TEST_CORES, CARGO_BUILD_JOBS and
# ERL_FLAGS, so it builds in its own worktree and sizes itself to its
# processors; it keeps HEAVY_CHECK_HELD, so a heavy-check inside it runs in
# place; and it gains PROOF_RUN_PREFIX, LOAD_CHECK_OUT (an empty directory
# of the run's own) and LOAD_CHECK_PARTS (the partitions the commit gate
# runs on that many processors: eight on sixteen or more, else four, as
# scripts/commit-gate.sh picks them).
set -uo pipefail

usage() { echo "usage: $0 [-n] [-s SUBJECT[,SUBJECT...]] [-r ROUNDS] [-o OUTDIR]"; }
refuse() { echo "load check: $2" >&2; exit "$1"; }

DRY=false ROUNDS=3 PICK= OUT=
while [ "$#" -gt 0 ]; do
  case $1 in
    -n) DRY=true; shift ;;
    -s|-r|-o)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 64; }
      case $1 in -s) PICK="${PICK:+$PICK,}$2" ;; -r) ROUNDS=$2 ;; *) OUT=$2 ;; esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
case $ROUNDS in ''|0*|*[!0-9]*) refuse 64 'the rounds are a positive whole number' ;; esac
[ "${#ROUNDS}" -le 2 ] || refuse 64 'at most 99 rounds'
if ! $DRY && [ "${HEAVY_CHECK_HELD:-}" != exclusive ]; then
  refuse 64 'it takes the whole host: run it under scripts/heavy-check.sh without -s or -p (or with -n for the plan alone)'
fi
[ "${BASH_VERSINFO[0]}" -ge 5 ] || refuse 69 "it needs Bash 5 or later, this is $BASH_VERSION"
{ command -v taskset && taskset -p "$$"; } >/dev/null 2>&1 ||
  refuse 69 'taskset (util-linux) is required to place what it runs, and none works here'

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) && ROOT=$(cd "$ROOT" && pwd -P) ||
  refuse 69 "$HERE is not inside a git checkout"
# shellcheck source=../../scripts/lib/contain.sh
. "$ROOT/scripts/lib/contain.sh" || refuse 69 'cannot load scripts/lib/contain.sh'
# shellcheck source=../../scripts/lib/run-names.sh
. "$ROOT/scripts/lib/run-names.sh" || refuse 69 'cannot load scripts/lib/run-names.sh'
for tool in git python3 pgrep; do
  command -v "$tool" >/dev/null 2>&1 || refuse 69 "$tool is required"
done

GRACE=${LOAD_CHECK_GRACE:-120}
SAMPLE=${LOAD_CHECK_SAMPLE:-5}
for n in "$GRACE" "$SAMPLE"; do
  case $n in ''|0*|*[!0-9]*) refuse 64 'LOAD_CHECK_GRACE and LOAD_CHECK_SAMPLE are positive whole seconds' ;; esac
done

# --- the quarters ------------------------------------------------------------

# The processors a list such as 0-3,8 names, sorted and once each, one
# space apart; 1 for a list that is not one.
cpus_of() {
  local part a b out=() IFS=,
  for part in $1; do
    case $part in
      ''|*[!0-9-]*|-*|*-|*-*-*) return 1 ;;
      *-*)
        a=$((10#${part%-*})) b=$((10#${part#*-}))
        [ "$a" -le "$b" ] || return 1
        while [ "$a" -le "$b" ]; do out+=("$a"); a=$((a + 1)); done ;;
      *) out+=("$((10#$part))") ;;
    esac
  done
  [ "${#out[@]}" -gt 0 ] || return 1
  printf '%s\n' "${out[@]}" | sort -nu | paste -sd' ' -
}
# The comma list of the processors in comma lists $@, sorted.
joined() { printf '%s\n' "$@" | tr ', ' '\n\n' | sed '/^$/d' | sort -nu | paste -sd, -; }
# How many processors comma list $1 holds.
count() { local IFS=,; set -- $1; echo "$#"; }

CPU_ROOT=${LOAD_CHECK_CPU_ROOT:-/sys/devices/system/cpu}
online=
read -r online 2>/dev/null <"$CPU_ROOT/online" && online=$(cpus_of "$online") ||
  refuse 69 "cannot read the online processors in $CPU_ROOT/online"
CORES=() seen=' '
for cpu in $online; do
  sib=
  read -r sib 2>/dev/null <"$CPU_ROOT/cpu$cpu/topology/thread_siblings_list" && sib=$(cpus_of "$sib") ||
    refuse 69 "cannot read processor $cpu's thread siblings in $CPU_ROOT/cpu$cpu/topology"
  key=${sib// /,}
  case $seen in *" $key "*) continue ;; esac
  seen="$seen$key "
  whole=true
  for c in $sib; do case " $online " in *" $c "*) ;; *) whole=false ;; esac; done
  if $whole; then CORES+=("$key"); fi
done
PER=$(( ${#CORES[@]} / 4 ))
[ "$PER" -ge 1 ] || refuse 69 "this host has ${#CORES[@]} whole cores, and the check needs four, one for each quarter"
QUARTER=()
for q in 1 2 3 4; do QUARTER[$q]=$(joined "${CORES[@]:$(( (q - 1) * PER )):$PER}"); done
LEFT=$(joined "${CORES[@]:$(( 4 * PER ))}")
ALL=$(joined ${online// /,})
# The processors of quarters $1 to $2.
span() { local q lists=(); for ((q = $1; q <= $2; q++)); do lists+=("${QUARTER[$q]}"); done; joined "${lists[@]}"; }

# --- the table ---------------------------------------------------------------

TABLE=${LOAD_CHECK_SUBJECTS:-$HERE/subjects.tsv}
[ -f "$TABLE" ] && [ -r "$TABLE" ] || refuse 65 "$TABLE: there is no table to read"
S_NAME=() S_Q=() S_PAIR=() S_EXPECT=() S_DEADLINE=() S_NEEDS=() S_CMD=()
P_NAME=() P_EXPECT=() P_DEADLINE=() P_NEEDS=() P_CMD=()
L_NAME=() L_DEADLINE=() L_NEEDS=() L_CMD=()
I_NAME=() I_DEADLINE=() I_NEEDS=() I_CMD=()
declare -A row_seen=()
number=0
while IFS= read -r line || [ -n "$line" ]; do
  number=$((number + 1))
  case $line in '#'*) continue ;; esac
  [ -n "${line//[[:space:]]/}" ] || continue
  tabs=${line//[^$'\t']/}
  [ "${#tabs}" = 7 ] || refuse 65 "$TABLE:$number: a row has eight fields separated by single tabs"
  case $line in $'\t'*|*$'\t\t'*|*$'\t') refuse 65 "$TABLE:$number: a field is empty" ;; esac
  IFS=$'\t' read -r kind name quarters pair expect deadline needs command <<<"$line"
  case $kind in prep|load|image|subject) ;; *) refuse 65 "$TABLE:$number: no kind is called '$kind'" ;; esac
  [[ $name =~ ^[a-z0-9-]+$ ]] || refuse 65 "$TABLE:$number: the name '$name' is not [a-z0-9-]+"
  [ -z "${row_seen[$kind/$name]+set}" ] || refuse 65 "$TABLE:$number: a second $kind is called $name"
  row_seen[$kind/$name]=1
  if [ "$kind" = subject ]; then
    case $quarters in 1|2|4) ;; *) refuse 65 "$TABLE:$number: a subject takes 1, 2 or 4 quarters, not '$quarters'" ;; esac
    case $pair in pair|-) ;; *) refuse 65 "$TABLE:$number: pair is 'pair' or '-', not '$pair'" ;; esac
  elif [ "$quarters" != - ] || [ "$pair" != - ]; then
    refuse 65 "$TABLE:$number: only a subject takes quarters and a pair"
  fi
  [[ $expect =~ ^[1-9][0-9]{0,5}$ ]] && [[ $deadline =~ ^[1-9][0-9]{0,5}$ ]] ||
    refuse 65 "$TABLE:$number: expect and deadline are positive seconds"
  case $kind in
    subject) S_NAME+=("$name") S_Q+=("$quarters") S_PAIR+=("$pair") S_EXPECT+=("$expect") S_DEADLINE+=("$deadline") S_NEEDS+=("$needs") S_CMD+=("$command") ;;
    prep) P_NAME+=("$name") P_EXPECT+=("$expect") P_DEADLINE+=("$deadline") P_NEEDS+=("$needs") P_CMD+=("$command") ;;
    load) L_NAME+=("$name") L_DEADLINE+=("$deadline") L_NEEDS+=("$needs") L_CMD+=("$command") ;;
    image) I_NAME+=("$name") I_DEADLINE+=("$deadline") I_NEEDS+=("$needs") I_CMD+=("$command") ;;
  esac
done <"$TABLE"
[ "${#S_NAME[@]}" -gt 0 ] && [ "${#L_NAME[@]}" -gt 0 ] || refuse 65 "$TABLE: the table needs a subject row and a load row"

SEL=()
if [ -n "$PICK" ]; then
  IFS=, read -r -a picks <<<"$PICK"
  for p in "${picks[@]}"; do
    found=
    for i in "${!S_NAME[@]}"; do [ "${S_NAME[$i]}" != "$p" ] || found=$i; done
    [ -n "$found" ] || refuse 64 "no subject is called '$p'; the subjects are ${S_NAME[*]}"
    case " ${SEL[*]} " in *" $found "*) ;; *) SEL+=("$found") ;; esac
  done
else
  SEL=("${!S_NAME[@]}")
fi

# Whether needs command $1 holds, run from the checkout's root; when it
# does not, REASON says why.
needs_hold() {
  local out s=0
  REASON=
  [ "$1" != - ] || return 0
  out=$(cd "$ROOT" && timeout 120 "$BASH" -c "$1" </dev/null 2>&1) || s=$?
  [ "$s" != 0 ] || return 0
  REASON=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | head -n 1)
  [ -n "$REASON" ] || REASON="its precondition exited $s"
  return 1
}

SKIP=() MEASURED=() OUTSIDE=()
for i in "${SEL[@]}"; do
  if [ "${S_Q[$i]}" = 4 ]; then OUTSIDE+=("$i"); continue; fi
  if needs_hold "${S_NEEDS[$i]}"; then MEASURED+=("$i"); else SKIP[$i]=$REASON; fi
done
PAIRED=false WORKERS=0
for i in "${MEASURED[@]}"; do
  [ "${S_PAIR[$i]}" != pair ] || PAIRED=true
  [ $((4 - S_Q[i])) -le "$WORKERS" ] || WORKERS=$((4 - S_Q[i]))
done
ROLES=()
if [ "${#MEASURED[@]}" -gt 0 ]; then
  ROLES=(a)
  if $PAIRED; then ROLES+=(b); fi
  for ((k = 1; k <= WORKERS; k++)); do ROLES+=("w$k"); done
fi
REFUSAL=
if [ "${#MEASURED[@]}" -gt 0 ]; then
  for i in "${!P_NAME[@]}"; do needs_hold "${P_NEEDS[$i]}" || { REFUSAL="the prep row ${P_NAME[$i]}: $REASON"; break; }; done
  for i in "${!L_NAME[@]}"; do [ -n "$REFUSAL" ] || needs_hold "${L_NEEDS[$i]}" || REFUSAL="the load row ${L_NAME[$i]}: $REASON"; done
  for i in "${!I_NAME[@]}"; do [ -n "$REFUSAL" ] || needs_hold "${I_NEEDS[$i]}" || REFUSAL="the image row ${I_NAME[$i]}: $REASON"; done
fi

# --- the plan ----------------------------------------------------------------

# Seconds as 1h02m, 4m10s or 9s.
human() {
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}
# The conditions of subject $1, in round 1's order.
conditions() {
  local c=(alone busy)
  [ "${S_PAIR[$1]}" != pair ] || c+=(pair)
  [ "${S_Q[$1]}" != 2 ] || c+=(whole)
  echo "${c[*]}"
}
plan() {
  local i q c prep=0 total=0 runs t conds
  echo "load check of $ROOT at $(git -C "$ROOT" rev-parse --short HEAD), $ROUNDS round(s)"
  echo "processors: $ALL; ${#CORES[@]} whole cores, $PER in each quarter"
  for q in 1 2 3 4; do echo "quarter $q: ${QUARTER[$q]}"; done
  echo "outside every quarter: ${LEFT:-none}"
  for i in "${!P_NAME[@]}"; do prep=$((prep + P_EXPECT[i])); done
  if [ "${#ROLES[@]}" -gt 0 ]; then
    echo "scratch worktrees: ${ROLES[*]}, in ${LOAD_CHECK_WORKTREES:-$(dirname "$ROOT")}, each prepared cold by ${P_NAME[*]:-nothing}: about $(human "$prep") for a, then as long again for the others side by side"
    echo "busy load: on each quarter a subject leaves, ${L_NAME[*]} in a loop; on the last of them, ${I_NAME[*]:-no image build} in a loop besides"
    total=$((2 * prep))
  fi
  for i in "${SEL[@]}"; do
    q=${S_Q[$i]}
    if [ "$q" = 4 ]; then echo "subject ${S_NAME[$i]}: not measured: it takes all four quarters"; continue; fi
    if [ -n "${SKIP[$i]+set}" ]; then echo "subject ${S_NAME[$i]}: skipped: ${SKIP[$i]}"; continue; fi
    conds=$(conditions "$i")
    set -- $conds
    runs=$((1 + ROUNDS * $#))
    t=$((runs * S_EXPECT[i]))
    total=$((total + t))
    printf 'subject %s: %s quarter(s), %s runs of about %s, %s:' "${S_NAME[$i]}" "$q" "$runs" "$(human "${S_EXPECT[$i]}")" "$(human "$t")"
    printf ' warm-up a %s' "$(span 1 "$q")"
    [ "${S_PAIR[$i]}" != pair ] || printf ' b %s' "$(span $((q + 1)) $((2 * q)))"
    for c in $conds; do
      case $c in
        alone) printf '; alone %s' "$(span 1 "$q")" ;;
        busy) printf '; busy %s, load %s' "$(span 1 "$q")" "$(span $((q + 1)) 4)" ;;
        pair) printf '; pair a %s b %s' "$(span 1 "$q")" "$(span $((q + 1)) $((2 * q)))" ;;
        whole) printf '; whole %s' "$(span 1 4)" ;;
      esac
    done
    printf '\n'
  done
  echo "expected: about $(human "$total") for ${#MEASURED[@]} measured subject(s), ${#SKIP[@]} skipped, ${#OUTSIDE[@]} not measured"
  if [ -n "$REFUSAL" ]; then echo "refused: $REFUSAL"; fi
}

if $DRY; then
  plan
  [ -z "$REFUSAL" ] || exit 69
  exit 0
fi
[ -z "$REFUSAL" ] || refuse 69 "$REFUSAL"

# --- the run -----------------------------------------------------------------

if [ -n "$OUT" ]; then
  mkdir -p "$OUT" 2>/dev/null && OUT=$(cd "$OUT" && pwd -P) || refuse 64 "cannot use $OUT for the report"
  [ -z "$(ls -A "$OUT")" ] || refuse 64 "$OUT is not empty"
else
  OUT=$(mktemp -d /tmp/cyfr-evidence.load-check.XXXXXX) || refuse 69 'cannot make a report directory'
fi
REV=$(git -C "$ROOT" rev-parse HEAD) || refuse 69 'the checkout has no HEAD'
OWN_PREFIX=$(run_names_prefix "$ROOT") || refuse 69 'cannot name the run (scripts/lib/run-names.sh)'
WT_ROOT=${LOAD_CHECK_WORKTREES:-$(dirname "$ROOT")}
WT_ROOT=$(cd "$WT_ROOT" 2>/dev/null && pwd -P) || refuse 64 "cannot use $WT_ROOT for the scratch worktrees"
DOCKER_OK=false
if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then DOCKER_OK=true; fi

declare -A WT=() PREFIX_OF=()
PREFIXES=("$OWN_PREFIX")
MADE=()
REGISTRY_OWNED=false
FINISHED=false
CLEANUP_FAILED=

# A leader: started contained, it runs its command in the background from
# the directory it is given and waits for it; stopped, it passes the
# signal to its process group, waits until nothing else of the group is
# left, and exits 128 + the signal. A worker runs its steps in a loop the
# same way and writes `begin NAME TIME` and `end NAME TIME STATUS` to its
# status file around each.
read -r -d '' PRELUDE <<'EOF'
lc_busy() {
  local f line pid rest
  for f in /proc/[0-9]*/stat; do
    read -r line 2>/dev/null <"$f" || continue
    pid=${line%% *}
    [ "$pid" != "$$" ] || continue
    rest=${line##*) }
    set -- $rest
    [ "${3:-}" = "$$" ] || continue
    case ${1:-} in Z|X) continue ;; esac
    return 0
  done
  return 1
}
lc_stop() {
  trap '' INT TERM HUP
  kill -s "$1" -- "-$$" 2>/dev/null
  while lc_busy; do sleep 0.2; done
  exit "$2"
}
trap 'lc_stop TERM 143' TERM
trap 'lc_stop INT 130' INT
trap 'lc_stop HUP 129' HUP
cd "$1" || exit 1
EOF
read -r -d '' LEADER <<'EOF'
"$BASH" -c "$2" </dev/null &
wait "$!"
EOF
LEADER="$PRELUDE"$'\n'"$LEADER"
read -r -d '' WORKER <<'EOF'
lc_alive() {
  local line
  read -r line 2>/dev/null <"/proc/$1/stat" || return 1
  case ${line##*) } in Z*|X*) return 1 ;; esac
}
lc_status=$2
shift 2
lc_rows=("$@")
while :; do
  for ((lc_i = 0; lc_i < ${#lc_rows[@]}; lc_i += 3)); do
    printf 'begin %s %s\n' "${lc_rows[lc_i]}" "${EPOCHREALTIME/,/.}" >>"$lc_status"
    echo "==> load check: ${lc_rows[lc_i]}"
    "$BASH" -c "${lc_rows[lc_i + 2]}" </dev/null &
    lc_c=$!
    lc_due=$((SECONDS + lc_rows[lc_i + 1]))
    while lc_alive "$lc_c" && [ "$SECONDS" -lt "$lc_due" ]; do sleep 0.5; done
    if lc_alive "$lc_c"; then
      echo "==> load check: ${lc_rows[lc_i]} reached its deadline: stopping it"
      kill -TERM "$lc_c" 2>/dev/null
      wait "$lc_c"
      lc_s=124
    else
      wait "$lc_c"
      lc_s=$?
    fi
    printf 'end %s %s %s\n' "${lc_rows[lc_i]}" "${EPOCHREALTIME/,/.}" "$lc_s" >>"$lc_status"
  done
done
EOF
WORKER="$PRELUDE"$'\n'"$WORKER"
# Prints, for each LABEL:PID:PROCESSORS argument, every process descended
# from PID, PID included, that is allowed other processors than
# PROCESSORS, as LABEL<TAB>PID<TAB>NAME<TAB>ALLOWED, and then
# `checked<TAB>LABEL<TAB>N`, N the processes it read.
read -r -d '' SAMPLER <<'EOF'
import os, sys
def cpus(text):
    out = set()
    for part in text.strip().split(","):
        if "-" in part:
            a, b = part.split("-")
            out.update(range(int(a), int(b) + 1))
        elif part:
            out.add(int(part))
    return out
children = {}
for entry in os.listdir("/proc"):
    if entry.isdigit():
        try:
            with open(f"/proc/{entry}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        children.setdefault(int(stat[stat.rfind(")") + 2:].split()[1]), []).append(int(entry))
for arg in sys.argv[1:]:
    label, pid, want = arg.split(":", 2)
    want, todo, seen = cpus(want), [int(pid)], 0
    while todo:
        p = todo.pop()
        todo.extend(children.get(p, []))
        try:
            with open(f"/proc/{p}/status") as f:
                fields = dict(l.split(":", 1) for l in f.read().splitlines() if ":" in l)
        except OSError:
            continue
        if fields.get("State", "").strip().startswith(("Z", "X")):
            continue
        seen += 1
        allowed = fields.get("Cpus_allowed_list", "").strip()
        if cpus(allowed) != want:
            print(f"{label}\t{p}\t{fields.get('Name', '').strip()}\t{allowed}")
    print(f"checked\t{label}\t{seen}")
EOF

now() { printf '%s' "${EPOCHREALTIME/,/.}"; }
seconds() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
# Whether pid $1 runs: it exists and has not exited.
leader_alive() {
  local line rest
  read -r line 2>/dev/null <"/proc/$1/stat" || return 1
  rest=${line##*) }
  case $rest in Z*|X*) return 1 ;; esac
}
say() { echo "==> load check: $*" >&2; }

# The jobs of the current step, each a contained, placed command: its
# label, leader, processors, start, deadline (SECONDS), end, status, note.
J_LABEL=() J_PID=() J_CPUS=() J_START=() J_DUE=() J_END=() J_STATUS=() J_NOTE=() J_LOG=() J_DEADLINE=()
# The busy load's workers: leader, processors, status file.
W_PID=() W_CPUS=() W_FILE=() W_LABEL=()
CONTEXT=

# launch LABEL WORKTREE PROCESSORS LOG OUTDIR DEADLINE COMMAND: starts it as
# a job.
launch() {
  local k=${#J_PID[@]} parts=4 role=$2
  [ "$(count "$3")" -lt 16 ] || parts=8
  mkdir -p "$5" || return 1
  J_LABEL[$k]=$1 J_CPUS[$k]=$3 J_LOG[$k]=$4 J_NOTE[$k]= J_END[$k]= J_STATUS[$k]= J_DEADLINE[$k]=
  J_START[$k]=$(now)
  J_DUE[$k]=$((SECONDS + $6))
  if ! contain_start -g "$GRACE" taskset -c "$3" \
      env -u MIX_BUILD_PATH -u MIX_DEPS_PATH -u CYFR_TEST_CORES -u CARGO_BUILD_JOBS -u ERL_FLAGS \
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" LOAD_CHECK_OUT="$5" LOAD_CHECK_PARTS="$parts" \
      "$BASH" -c "$LEADER" load-check-run "${WT[$role]}" "$7" >"$4" 2>&1 </dev/null; then
    J_PID[$k]=
    J_END[$k]=${J_START[$k]} J_STATUS[$k]=1 J_NOTE[$k]='could not start'
    return 1
  fi
  J_PID[$k]=$CONTAIN_PID
}

# Every live job's and worker's processes against their processors, and
# the containers named under their prefixes.
sample() {
  local args=() i label pid name allowed k
  for i in "${!J_PID[@]}"; do
    [ -z "${J_END[$i]}" ] && [ -n "${J_PID[$i]}" ] && args+=("j$i:${J_PID[$i]}:${J_CPUS[$i]}")
  done
  for i in "${!W_PID[@]}"; do [ -n "${W_PID[$i]}" ] && args+=("w$i:${W_PID[$i]}:${W_CPUS[$i]}"); done
  [ "${#args[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r label pid name allowed; do
    [ "$label" != checked ] || continue
    k=${label#?}
    case $label in
      j*)
        case " ${J_NOTE[$k]} " in *" $pid "*) continue ;; esac
        J_NOTE[$k]="${J_NOTE[$k]:+${J_NOTE[$k]} }outside $pid $name ($allowed)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$CONTEXT" "${J_LABEL[$k]}" "$pid" "$name" "$allowed" "${J_CPUS[$k]}" >>"$OUT/masks.tsv" ;;
      w*)
        case " ${W_NOTE:-} " in *" $pid "*) continue ;; esac
        W_NOTE="${W_NOTE:+$W_NOTE }outside ${W_LABEL[$k]} $pid $name ($allowed)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$CONTEXT" "${W_LABEL[$k]}" "$pid" "$name" "$allowed" "${W_CPUS[$k]}" >>"$OUT/masks.tsv" ;;
    esac
  done < <(python3 -I -c "$SAMPLER" "${args[@]}" 2>/dev/null)
  if $DOCKER_OK; then
    while IFS= read -r name; do
      for i in "${!J_PID[@]}"; do
        [ -z "${J_END[$i]}" ] || continue
        case $name in "${J_PREFIX[$i]}"*) ;; *) continue ;; esac
        case " ${DOCKER_SEEN:-} " in *" $name "*) continue ;; esac
        DOCKER_SEEN="${DOCKER_SEEN:-} $name"
        allowed=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$name" 2>/dev/null) || allowed='?'
        printf '%s\t%s\t%s\t%s\n' "$CONTEXT" "${J_LABEL[$i]}" "$name" "${allowed:-any processor}" >>"$OUT/docker.tsv"
      done
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
  fi
}

# Waits for every job to end or reach its deadline, sampling as it goes.
watch_jobs() {
  local i going next=$((SECONDS + SAMPLE)) t
  while :; do
    going=false
    for i in "${!J_PID[@]}"; do
      [ -z "${J_END[$i]}" ] || continue
      if ! leader_alive "${J_PID[$i]}"; then
        t=$(now)
        J_STATUS[$i]=0
        contain_wait "${J_PID[$i]}" 0 "$GRACE" || J_STATUS[$i]=$?
        J_END[$i]=$t
        if [ -n "$CONTAIN_SURVIVORS" ]; then
          J_NOTE[$i]="${J_NOTE[$i]:+${J_NOTE[$i]} }survivors $CONTAIN_SURVIVORS"
          CLEANUP_FAILED="$CLEANUP_FAILED survivors of ${J_LABEL[$i]}: $CONTAIN_SURVIVORS;"
        fi
      elif [ "$SECONDS" -ge "${J_DUE[$i]}" ]; then
        say "${J_LABEL[$i]} reached its deadline: stopping it"
        contain_stop "${J_PID[$i]}" "$GRACE" || CLEANUP_FAILED="$CLEANUP_FAILED survivors of ${J_LABEL[$i]}: $CONTAIN_SURVIVORS;"
        J_END[$i]=$(now) J_STATUS[$i]=124 J_DEADLINE[$i]=1
      else
        going=true
      fi
    done
    $going || break
    if [ "$SECONDS" -ge "$next" ]; then sample; next=$((SECONDS + SAMPLE)); fi
    sleep 0.2
  done
}

# start_busy Q DIR: a worker on each quarter after Q, the image worker on
# the last; 0 once every worker has begun, else 1 with BUSY_VOID set.
start_busy() {
  local q=$1 dir=$2 k n=0 i rows=() irows=() file wt
  W_PID=() W_CPUS=() W_FILE=() W_LABEL=() W_NOTE= BUSY_VOID=
  for i in "${!L_NAME[@]}"; do rows+=("${L_NAME[$i]}" "${L_DEADLINE[$i]}" "${L_CMD[$i]}"); done
  for i in "${!I_NAME[@]}"; do irows+=("${I_NAME[$i]}" "${I_DEADLINE[$i]}" "${I_CMD[$i]}"); done
  for ((k = q + 1; k <= 4; k++)); do
    n=$((n + 1)) wt=w$n
    start_worker "$wt" "$k" "$dir/load-$wt" "${rows[@]}" || return 1
  done
  if [ "${#irows[@]}" -gt 0 ]; then start_worker "$wt" 4 "$dir/image-$wt" "${irows[@]}" || return 1; fi
  for ((i = 0; i < 600; i++)); do
    n=0
    for k in "${!W_FILE[@]}"; do grep -q '^begin ' "${W_FILE[$k]}" 2>/dev/null && n=$((n + 1)); done
    [ "$n" -lt "${#W_FILE[@]}" ] || return 0
    for k in "${!W_PID[@]}"; do
      leader_alive "${W_PID[$k]}" || { BUSY_VOID="the busy load's ${W_LABEL[$k]} ended before it began"; return 1; }
    done
    sleep 0.1
  done
  BUSY_VOID='the busy load did not begin within 60s'
  return 1
}
# start_worker ROLE QUARTER BASE NAME DEADLINE COMMAND...: BASE.log and
# BASE.status.
start_worker() {
  local role=$1 quarter=$2 base=$3 k=${#W_PID[@]}
  shift 3
  : >"$base.status"
  mkdir -p "$base.out" || return 1
  W_LABEL[$k]="${base##*/} on quarter $quarter" W_CPUS[$k]=${QUARTER[$quarter]} W_FILE[$k]=$base.status W_PID[$k]=
  if ! contain_start -g "$GRACE" taskset -c "${QUARTER[$quarter]}" \
      env -u MIX_BUILD_PATH -u MIX_DEPS_PATH -u CYFR_TEST_CORES -u CARGO_BUILD_JOBS -u ERL_FLAGS \
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" LOAD_CHECK_OUT="$base.out" LOAD_CHECK_PARTS=4 \
      "$BASH" -c "$WORKER" load-check-worker "${WT[$role]}" "$base.status" "$@" >"$base.log" 2>&1 </dev/null; then
    BUSY_VOID="the busy load's ${W_LABEL[$k]} could not start"
    return 1
  fi
  W_PID[$k]=$CONTAIN_PID
}
# busy_held START END: whether every worker ran from START to END with no
# step failing in between; BUSY_VOID says why not.
busy_held() {
  local k bad
  [ -z "$BUSY_VOID" ] || return 1
  [ -z "$W_NOTE" ] || { BUSY_VOID=$W_NOTE; return 1; }
  for k in "${!W_PID[@]}"; do
    leader_alive "${W_PID[$k]}" || { BUSY_VOID="the busy load's ${W_LABEL[$k]} ended while the subject ran"; return 1; }
    bad=$(awk -v a="$1" -v b="$2" '$1 == "end" && $4 != 0 && $3 >= a && $3 <= b { print $2 " exited " $4; exit }' "${W_FILE[$k]}")
    [ -z "$bad" ] || { BUSY_VOID="the busy load's ${W_LABEL[$k]}: $bad while the subject ran"; return 1; }
  done
}
# Stops every worker at once: the jobs have ended, so the workers are the
# only sessions of this shell still running.
stop_busy() {
  [ "${#W_PID[@]}" -gt 0 ] || return 0
  if ! contain_stop_all "$GRACE"; then
    CLEANUP_FAILED="$CLEANUP_FAILED the busy load left $CONTAIN_SURVIVORS;"
  fi
  W_PID=()
}

# Writes the current jobs to report.tsv under subject $1, round $2 and
# condition $3, and says how each ended; sets SKIPPED when one exited 69.
record() {
  local i status note last
  for i in "${!J_PID[@]}"; do
    note=${J_NOTE[$i]}
    case ${J_STATUS[$i]} in
      0) status=passed ;;
      69)
        status=skipped
        last=$(sed '/^[[:space:]]*$/d' "${J_LOG[$i]}" 2>/dev/null | grep -v '^_EXIT=' | tail -n 1)
        note="exited 69: ${last:-a missing prerequisite}"
        SKIPPED=$note ;;
      *) status=failed ;;
    esac
    [ -z "${J_DEADLINE[$i]}" ] || { status=deadline; note="${note:+$note; }stopped at its deadline"; }
    if [ "$status" = passed ]; then
      if [ "$3" = busy ] && [ -n "$BUSY_VOID" ]; then status=void note="${note:+$note; }$BUSY_VOID"; fi
      case $note in *outside*) status=void ;; esac
    elif [ "$3" = busy ] && [ -n "$BUSY_VOID" ]; then
      note="${note:+$note; }$BUSY_VOID"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${J_LABEL[$i]##* }" "${J_CPUS[$i]}" \
      "$status" "${J_STATUS[$i]}" "$(seconds "${J_START[$i]}" "${J_END[$i]}")" "${J_START[$i]}" "${J_END[$i]}" \
      "${note:--}" "${J_LOG[$i]}" >>"$OUT/report.tsv"
    say "$1 round $2 $3 ${J_LABEL[$i]##* }: $status after $(seconds "${J_START[$i]}" "${J_END[$i]}")s${note:+ ($note)}"
  done
}

# run_condition SUBJECT ROUND CONDITION
run_condition() {
  local i=$1 r=$2 c=$3 q=${S_Q[$1]} name=${S_NAME[$1]} dir t0 t1 k
  dir="$OUT/$name/r$r-$c"
  mkdir -p "$dir" || return 1
  CONTEXT="$name"$'\t'"$r"$'\t'"$c"
  J_LABEL=() J_PID=() J_CPUS=() J_START=() J_DUE=() J_END=() J_STATUS=() J_NOTE=() J_LOG=() J_DEADLINE=() J_PREFIX=()
  BUSY_VOID= W_NOTE= DOCKER_SEEN=
  if [ "$c" = busy ] && ! start_busy "$q" "$dir"; then
    stop_busy
    printf '%s\t%s\t%s\ta\t%s\tvoid\t-\t0.0\t%s\t%s\t%s\t-\n' "$name" "$r" "$c" "$(span 1 "$q")" "$(now)" "$(now)" "$BUSY_VOID" >>"$OUT/report.tsv"
    say "$name round $r busy: void ($BUSY_VOID)"
    return 0
  fi
  case $c in
    whole) launch "$name a" a "$(span 1 4)" "$dir/a.log" "$dir/a" "${S_DEADLINE[$i]}" "${S_CMD[$i]}" ;;
    *) launch "$name a" a "$(span 1 "$q")" "$dir/a.log" "$dir/a" "${S_DEADLINE[$i]}" "${S_CMD[$i]}" ;;
  esac
  J_PREFIX[0]=${PREFIX_OF[a]}
  if [ "$c" = pair ] || { [ "$c" = warm-up ] && [ "${S_PAIR[$i]}" = pair ]; }; then
    launch "$name b" b "$(span $((q + 1)) $((2 * q)))" "$dir/b.log" "$dir/b" "${S_DEADLINE[$i]}" "${S_CMD[$i]}"
    J_PREFIX[1]=${PREFIX_OF[b]}
  fi
  watch_jobs
  if [ "$c" = busy ]; then
    t0=${J_START[0]} t1=${J_END[0]}
    busy_held "$t0" "$t1" || :
    stop_busy
  fi
  record "$name" "$r" "$c"
}

# --- clean-up ----------------------------------------------------------------

# Whether name $1 is one of this run's.
ours() { local p; for p in "${PREFIXES[@]}"; do case $1 in "$p"*) return 0 ;; esac; done; return 1; }
remove_worktree() {
  git -C "$ROOT" worktree remove --force --force "$1" >/dev/null 2>&1 || :
  if [ -e "$1" ]; then rm -rf -- "$1" 2>/dev/null || :; fi
  git -C "$ROOT" worktree prune >/dev/null 2>&1 || :
  [ ! -e "$1" ] || { CLEANUP_FAILED="$CLEANUP_FAILED the worktree $1;"; return 1; }
}
docker_sweep() {
  local kind names name
  $DOCKER_OK || return 0
  for kind in container network volume image; do
    case $kind in
      container) names=$(docker ps -a --format '{{.Names}}' 2>/dev/null) ;;
      network) names=$(docker network ls --format '{{.Name}}' 2>/dev/null) ;;
      volume) names=$(docker volume ls --format '{{.Name}}' 2>/dev/null) ;;
      image) names=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null) ;;
    esac || { CLEANUP_FAILED="$CLEANUP_FAILED the listing of Docker's ${kind}s;"; return 1; }
    while IFS= read -r name; do
      [ -n "$name" ] && ours "$name" || continue
      case $kind in
        container) docker rm -f -v "$name" ;;
        network) docker network rm "$name" ;;
        volume) docker volume rm -f "$name" ;;
        image) docker image rm -f "$name" ;;
      esac >/dev/null 2>&1 || CLEANUP_FAILED="$CLEANUP_FAILED the $kind $name;"
    done <<<"$names"
  done
}
cleanup() {
  local p f path
  if ! contain_stop_all "$GRACE"; then CLEANUP_FAILED="$CLEANUP_FAILED survivors $CONTAIN_SURVIVORS;"; fi
  docker_sweep
  for path in "${MADE[@]}"; do remove_worktree "$path"; done
  for p in "${PREFIXES[@]}"; do
    for f in "${TMPDIR:-/tmp}/$p"*; do
      [ -e "$f" ] || continue
      rm -rf -- "$f" 2>/dev/null || CLEANUP_FAILED="$CLEANUP_FAILED $f;"
    done
  done
  if $REGISTRY_OWNED; then
    contain_sweep_registry "$GRACE" || CLEANUP_FAILED="$CLEANUP_FAILED survivors $CONTAIN_SURVIVORS;"
    rm -f "$CONTAIN_REGISTRY"
  fi
}
on_exit() {
  local s=$?
  trap '' INT TERM HUP
  trap - EXIT
  if [ "$s" = 0 ] && ! $FINISHED; then s=1; fi
  cleanup
  if [ -n "$CLEANUP_FAILED" ]; then
    echo "load check: the clean-up left:$CLEANUP_FAILED" >&2
    [ ! -d "$OUT" ] || echo "clean-up left:$CLEANUP_FAILED" >>"$OUT/report.txt"
    [ "$s" != 0 ] && [ "$s" != 69 ] || s=1
  fi
  exit "$s"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -z "${CONTAIN_REGISTRY:-}" ]; then
  contain_registry_create || exit 1
  REGISTRY_OWNED=true
fi

# Worktrees a load check that is gone left: its pid names no process.
while IFS= read -r path; do
  [[ ${path##*/} =~ ^cyfr-[0-9a-f]{10}-([0-9]+)-load-check-[a-z0-9]+$ ]] || continue
  [ "${BASH_REMATCH[1]}" != "$$" ] && [ ! -e "/proc/${BASH_REMATCH[1]}" ] || continue
  if remove_worktree "$path"; then say "removed $path, which load check ${BASH_REMATCH[1]} left"; fi
done < <(git -C "$ROOT" worktree list --porcelain | sed -n 's/^worktree //p')

plan | tee "$OUT/plan.txt"
printf 'subject\tround\tcondition\tcopy\tprocessors\tstatus\texit\tseconds\tstarted\tended\tnote\tlog\n' >"$OUT/report.tsv"
: >"$OUT/skips.tsv"
: >"$OUT/masks.tsv"
: >"$OUT/docker.tsv"
for i in "${SEL[@]}"; do
  if [ "${S_Q[$i]}" = 4 ]; then printf '%s\tnot measured: it takes all four quarters\n' "${S_NAME[$i]}" >>"$OUT/skips.tsv"; fi
  if [ -n "${SKIP[$i]+set}" ]; then printf '%s\tskipped: %s\n' "${S_NAME[$i]}" "${SKIP[$i]}" >>"$OUT/skips.tsv"; fi
done
if $DOCKER_OK; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    allowed=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$name" 2>/dev/null) || allowed='?'
    printf 'host\t-\t-\t-\t%s\t%s\n' "$name" "${allowed:-any processor}" >>"$OUT/docker.tsv"
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
fi

# The worktrees, then their cold preparation: a's first, the others side
# by side.
if [ "${#ROLES[@]}" -gt 0 ]; then
  for role in "${ROLES[@]}"; do
    path="$WT_ROOT/${OWN_PREFIX}load-check-$role"
    git -C "$ROOT" worktree add --detach "$path" "$REV" >"$OUT/worktree-$role.log" 2>&1 ||
      { say "cannot make the worktree $path: $(tail -n 1 "$OUT/worktree-$role.log")"; exit 1; }
    MADE+=("$path")
    path=$(cd "$path" && pwd -P)
    WT[$role]=$path
    PREFIX_OF[$role]=$(run_names_prefix "$path") || { say "cannot name the worktree $path"; exit 1; }
    PREFIXES+=("${PREFIX_OF[$role]}")
  done
  prep_command=
  deadline=0
  for i in "${!P_NAME[@]}"; do
    prep_command="$prep_command${prep_command:+$'\n'}echo '==> load check: prep ${P_NAME[$i]}' && { ${P_CMD[$i]}; } || exit"
    deadline=$((deadline + P_DEADLINE[i]))
  done
  [ -n "$prep_command" ] || prep_command=true
  printf 'worktree\tstatus\texit\tseconds\tlog\n' >"$OUT/prep.tsv"
  for wave in a rest; do
    J_LABEL=() J_PID=() J_CPUS=() J_START=() J_DUE=() J_END=() J_STATUS=() J_NOTE=() J_LOG=() J_DEADLINE=() J_PREFIX=()
    CONTEXT="prep"$'\t'"-"$'\t'"$wave"
    for role in "${ROLES[@]}"; do
      { [ "$wave" = a ] && [ "$role" = a ]; } || { [ "$wave" = rest ] && [ "$role" != a ]; } || continue
      launch "prep $role" "$role" "$ALL" "$OUT/prep-$role.log" "$OUT/prep-$role" "$deadline" "$prep_command"
      J_PREFIX[${#J_PID[@]}-1]=${PREFIX_OF[$role]}
    done
    [ "${#J_PID[@]}" -gt 0 ] || continue
    say "preparing ${J_LABEL[*]}"
    watch_jobs
    failed=
    for i in "${!J_PID[@]}"; do
      status=passed
      [ "${J_STATUS[$i]}" = 0 ] || { status=failed; failed="$failed ${J_LABEL[$i]#prep }"; }
      printf '%s\t%s\t%s\t%s\t%s\n' "${J_LABEL[$i]#prep }" "$status" "${J_STATUS[$i]}" "$(seconds "${J_START[$i]}" "${J_END[$i]}")" "${J_LOG[$i]}" >>"$OUT/prep.tsv"
      say "${J_LABEL[$i]}: $status after $(seconds "${J_START[$i]}" "${J_END[$i]}")s"
    done
    if [ -n "$failed" ]; then
      echo "preparation failed in the worktree(s)$failed: see $OUT/prep-*.log" | tee "$OUT/report.txt"
      exit 1
    fi
  done
fi

for i in "${MEASURED[@]}"; do
  SKIPPED=
  run_condition "$i" 0 warm-up
  if [ -n "$SKIPPED" ]; then printf '%s\tskipped: %s\n' "${S_NAME[$i]}" "$SKIPPED" >>"$OUT/skips.tsv"; continue; fi
  read -r -a conds <<<"$(conditions "$i")"
  for ((r = 1; r <= ROUNDS; r++)); do
    for ((k = 0; k < ${#conds[@]}; k++)); do
      run_condition "$i" "$r" "${conds[$(( (k + r - 1) % ${#conds[@]} ))]}"
      if [ -n "$SKIPPED" ]; then printf '%s\tskipped: %s\n' "${S_NAME[$i]}" "$SKIPPED" >>"$OUT/skips.tsv"; break 2; fi
    done
  done
done

# The summary: report.txt, printed, and the exit it implies.
names=()
for i in "${SEL[@]}"; do names+=("${S_NAME[$i]}:${S_Q[$i]}"); done
status=0
python3 -I - "$OUT" "${names[@]}" <<'PY' || status=$?
import csv, os, statistics, sys

out, subjects = sys.argv[1], [a.rsplit(":", 1) for a in sys.argv[2:]]
with open(os.path.join(out, "report.tsv")) as f:
    rows = list(csv.DictReader(f, delimiter="\t"))
skips = {}
with open(os.path.join(out, "skips.tsv")) as f:
    for line in f:
        name, reason = line.rstrip("\n").split("\t", 1)
        skips.setdefault(name, reason)
lines, fails_busy, fails_other, undecided, skipped, outside, holds = [], [], [], [], [], [], []


def median(runs):
    passed = [float(r["seconds"]) for r in runs if r["status"] == "passed"]
    return statistics.median(passed) if passed else None


def ratio(top, bottom):
    return "n/a" if top is None or bottom is None or bottom == 0 else f"{top / bottom:.2f}"


for name, quarters in subjects:
    if name in skips:
        lines.append(f"{name}: {skips[name]}")
        (outside if skips[name].startswith("not measured") else skipped).append(name)
        continue
    runs = [r for r in rows if r["subject"] == name and r["condition"] != "warm-up"]
    by = {c: [r for r in runs if r["condition"] == c] for c in ("alone", "busy", "pair", "whole")}
    warm = [r for r in rows if r["subject"] == name and r["condition"] == "warm-up"]
    alone = median(by["alone"])
    bad = lambda c: [r for r in by[c] if r["status"] in ("failed", "deadline")]
    void = [r for r in runs if r["status"] == "void"]
    if bad("alone"):
        verdict = "fails alone"
        fails_other.append(name)
    elif bad("busy") or bad("pair"):
        verdict = "FAILS BUSY"
        fails_busy.append(name)
    elif void:
        verdict = "not decided: a run was void"
        undecided.append(name)
    elif bad("whole"):
        verdict = "fails on the whole machine"
        fails_other.append(name)
    else:
        verdict = "holds"
        holds.append(name)
    lines.append(f"{name} ({quarters} quarter{'s' if quarters != '1' else ''}): {verdict}")
    for r in warm:
        lines.append(f"  warm-up {r['copy']}: {r['status']} after {r['seconds']}s")
    for c, group in by.items():
        if not group:
            continue
        passed = sum(r["status"] == "passed" for r in group)
        m = median(group)
        text = f"  {c} {passed}/{len(group)} passed, median {'n/a' if m is None else f'{m:.1f}s'}"
        if c in ("busy", "pair"):
            text += f"; {c}/alone {ratio(m, alone)}"
        if c == "whole":
            text += f"; two quarters/whole machine {ratio(alone, m)}"
        lines.append(text)
        for r in group:
            if r["status"] != "passed":
                lines.append(f"    round {r['round']} {r['copy']}: {r['status']} (exit {r['exit']}) after {r['seconds']}s: {r['note']}; {r['log']}")
if os.path.exists(os.path.join(out, "prep.tsv")):
    with open(os.path.join(out, "prep.tsv")) as f:
        prep = [l.rstrip("\n").split("\t") for l in f][1:]
    lines.append("cold preparation: " + ", ".join(f"{p[0]} {p[1]} after {p[3]}s" for p in prep))
with open(os.path.join(out, "masks.tsv")) as f:
    masks = sum(1 for _ in f)
lines.append(f"placement: {masks} process(es) outside their processors" + (f", listed in {out}/masks.tsv" if masks else ""))
with open(os.path.join(out, "docker.tsv")) as f:
    docker = [l.rstrip("\n").split("\t") for l in f]
host = [f"{d[4]} ({d[5]})" for d in docker if d[0] == "host"]
started = [d for d in docker if d[0] != "host"]
anywhere = sum(d[5] == "any processor" for d in started)
lines.append("not placed by this check: the host's containers " + (", ".join(host) if host else "(none ran)") +
             f"; {len(started)} container(s) its runs started, {anywhere} of them on any processor (docker.tsv)")
summary = [f"holds: {len(holds)}"]
if fails_busy:
    summary.append("FAILS BUSY: " + " ".join(fails_busy))
if fails_other:
    summary.append("fails alone or whole: " + " ".join(fails_other))
if undecided:
    summary.append("not decided: " + " ".join(undecided))
if skipped:
    summary.append("skipped: " + " ".join(skipped))
if outside:
    summary.append("not measured: " + " ".join(outside))
lines.append("verdict: " + "; ".join(summary))
text = "\n".join(lines) + "\n"
with open(os.path.join(out, "report.txt"), "a") as f:
    f.write(text)
sys.stdout.write(text)
sys.exit(1 if fails_busy or fails_other or undecided else 69 if skipped else 0)
PY
echo "load check: report in $OUT" >&2
FINISHED=true
exit "$status"
