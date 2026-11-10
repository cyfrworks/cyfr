#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The load check:
#   tests/load-check/run.sh [-n] [-s SUBJECT,...] [-c CONDITION,...] [-r ROUNDS] [-o OUTDIR]
#
# Runs each subject of its table on quarters of this host's cores, busy,
# beside a copy of itself and on the whole machine, and reports what
# passed; README.md says what it measures and what its answer decides. It
# runs only in scripts/heavy-check.sh's exclusive lane
# (HEAVY_CHECK_HELD=exclusive) and refuses with 64 in any other. -n prints
# the plan, each run's processors and the expected time, and runs nothing,
# in any lane. -s picks subjects (all), -c conditions (busy,pair,whole,alone),
# -r rounds (1), -o a new or empty directory for the report (a fresh
# /tmp/cyfr-evidence.load-check.XXXXXX).
#
# Quarters: the online processors (LOAD_CHECK_CPU_ROOT, default
# /sys/devices/system/cpu) group into whole cores, one per
# thread_siblings_list, ordered by their lowest processor; the first 4k of
# them, k the cores divided by four, make four quarters of k cores in that
# order. Every command runs under `taskset -c` on its processors.
#
# The table, tests/load-check/subjects.tsv (LOAD_CHECK_SUBJECTS names
# another): nine fields separated by single tabs; # lines and blank lines
# are skipped and a bad line is refused with 65.
#   kind      prep (prepares each scratch worktree, in order), warm, load
#             (a step of the busy load), image (the busy load's image
#             build) or subject
#   name      [a-z0-9-]+, unique within its kind
#   quarters  a subject's 1, 2 or 4 (4: listed, not measured), else -
#   with      a subject's further conditions, pair and whole,
#             comma-separated, else -
#   warm      a subject's warm row, else -: run once in each worktree that
#             runs the subject, before its first run, unmeasured
#   expect    the seconds a run takes on its quarters busy, for the plan; a
#             whole run is planned at half of it
#   deadline  the seconds after which a run, a prep, a warm or a load step
#             is stopped
#   needs     - or a command run by bash from the checkout's root before
#             any work: 0 when the row's prerequisite holds, else it says
#             why not
#   command   run by bash from the scratch worktree's root
#
# Each round runs every chosen condition a subject has, in this order:
# busy (its quarters, the busy load on every other quarter), pair (copy a
# on quarters 1 to q, copy b on q+1 to 2q, from another worktree), whole
# (all four quarters, nothing beside it); then alone (its quarters, the
# others idle) when busy or pair failed in that round, or when neither is
# chosen. A run's status is passed, failed, deadline (stopped at its
# deadline), skipped (it exited 69, or 77 as the proxy HSTS proof does for
# a missing prerequisite) or void (a run that passed while the busy load
# did not hold, or with a process or a container outside its processors).
# A skip ends the subject's runs, but for the alone run that decides a
# failure seen before it.
#
# Each command's environment loses MIX_BUILD_PATH, MIX_DEPS_PATH,
# CYFR_TEST_CORES, CARGO_BUILD_JOBS and ERL_FLAGS, keeps HEAVY_CHECK_HELD
# (a heavy-check inside it runs in place), and gains PROOF_RUN_PREFIX
# (scripts/lib/run-names.sh's prefix for its worktree with this script's
# pid), HEAVY_CHECK_CPUS (its processors, as docker's --cpuset-cpus takes
# them), LOAD_CHECK_OUT (an empty directory of the run's own) and
# LOAD_CHECK_PARTS (the partitions scripts/commit-gate.sh runs on that
# many processors; tests/load-check/run-test.sh holds the two rules
# together).
#
# The report, in OUTDIR: report.tsv (one line per run), skips.tsv,
# masks.tsv (processes and containers outside their processors),
# docker.tsv, prep.tsv, warm.tsv, plan.txt, and report.txt, the summary it
# prints last. Exits 0 when every measured subject held; 1 when one failed
# (FAILS BUSY: it failed busy or beside its copy and passed alone), a run
# was void, a prep failed or the clean-up left something; 69 when nothing
# failed but a subject was skipped; before any work, 64 on usage or
# outside the exclusive lane, 65 for a bad table, and 69 without Bash 5,
# taskset, four whole cores, git, python3 or pgrep, or when a prep, load or
# image row's precondition fails; 130, 143 and 129 on INT, TERM and HUP.
#
# Every command runs contained (scripts/lib/contain.sh) under a leader
# that, stopped, passes the signal to its process group and waits for it
# to empty, within LOAD_CHECK_GRACE seconds (120). On every exit path the
# check stops all it started, removes the Docker objects named under its
# prefixes, then its worktrees and the $TMPDIR entries named under its
# prefixes; when a process outlived its stop or a container could not be
# removed it keeps those worktrees and entries, which the process or the
# container may still hold, and names each. What it leaves makes the exit
# 1. A worktree that a load check that is gone left is removed at the next
# one's start.
set -uo pipefail

usage() { echo "usage: $0 [-n] [-s SUBJECT,...] [-c CONDITION,...] [-r ROUNDS] [-o OUTDIR]"; }
refuse() { echo "load check: $2" >&2; exit "$1"; }

DRY=false ROUNDS=1 PICK= OUT= CHOSEN=busy,pair,whole,alone
while [ "$#" -gt 0 ]; do
  case $1 in
    -n) DRY=true; shift ;;
    -s|-r|-o|-c)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 64; }
      case $1 in -s) PICK="${PICK:+$PICK,}$2" ;; -r) ROUNDS=$2 ;; -c) CHOSEN=$2 ;; *) OUT=$2 ;; esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
case $ROUNDS in ''|0*|*[!0-9]*) refuse 64 'the rounds are a positive whole number' ;; esac
[ "${#ROUNDS}" -le 2 ] || refuse 64 'at most 99 rounds'
declare -A CHOICE=()
IFS=, read -r -a conds <<<"$CHOSEN"
for c in "${conds[@]}"; do
  case $c in busy|pair|whole|alone) CHOICE[$c]=1 ;; *) refuse 64 "no condition is called '$c': busy, pair, whole or alone" ;; esac
done
chosen() { [ -n "${CHOICE[$1]:-}" ]; }
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

# The partitions scripts/commit-gate.sh runs on $1 processors.
gate_parts() { if [ "$1" -ge 16 ]; then echo 8; else echo 4; fi; }

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
S_NAME=() S_Q=() S_PAIR=() S_WHOLE=() S_WARM=() S_EXPECT=() S_DEADLINE=() S_NEEDS=() S_CMD=()
P_NAME=() P_EXPECT=() P_DEADLINE=() P_NEEDS=() P_CMD=()
L_NAME=() L_DEADLINE=() L_NEEDS=() L_CMD=()
I_NAME=() I_DEADLINE=() I_NEEDS=() I_CMD=()
declare -A row_seen=() WARM_EXPECT=() WARM_DEADLINE=() WARM_CMD=()
number=0
while IFS= read -r line || [ -n "$line" ]; do
  number=$((number + 1))
  case $line in '#'*) continue ;; esac
  [ -n "${line//[[:space:]]/}" ] || continue
  tabs=${line//[^$'\t']/}
  [ "${#tabs}" = 8 ] || refuse 65 "$TABLE:$number: a row has nine fields separated by single tabs"
  case $line in $'\t'*|*$'\t\t'*|*$'\t') refuse 65 "$TABLE:$number: a field is empty" ;; esac
  IFS=$'\t' read -r kind name quarters with warm expect deadline needs command <<<"$line"
  case $kind in prep|warm|load|image|subject) ;; *) refuse 65 "$TABLE:$number: no kind is called '$kind'" ;; esac
  [[ $name =~ ^[a-z0-9-]+$ ]] || refuse 65 "$TABLE:$number: the name '$name' is not [a-z0-9-]+"
  [ -z "${row_seen[$kind/$name]+set}" ] || refuse 65 "$TABLE:$number: a second $kind is called $name"
  row_seen[$kind/$name]=$number
  if [ "$kind" = subject ]; then
    case $quarters in 1|2|4) ;; *) refuse 65 "$TABLE:$number: a subject takes 1, 2 or 4 quarters, not '$quarters'" ;; esac
    case $with in -|pair|whole|pair,whole|whole,pair) ;; *) refuse 65 "$TABLE:$number: with is pair, whole, both or -, not '$with'" ;; esac
    [[ $warm =~ ^(-|[a-z0-9-]+)$ ]] || refuse 65 "$TABLE:$number: the warm row '$warm' is not a name"
  elif [ "$quarters" != - ] || [ "$with" != - ] || [ "$warm" != - ]; then
    refuse 65 "$TABLE:$number: only a subject takes quarters, conditions and a warm row"
  fi
  [[ $expect =~ ^[1-9][0-9]{0,5}$ ]] && [[ $deadline =~ ^[1-9][0-9]{0,5}$ ]] ||
    refuse 65 "$TABLE:$number: expect and deadline are positive seconds"
  case $kind in
    subject)
      S_NAME+=("$name") S_Q+=("$quarters") S_WARM+=("$warm") S_EXPECT+=("$expect") S_DEADLINE+=("$deadline") S_NEEDS+=("$needs") S_CMD+=("$command")
      case ,$with, in *,pair,*) S_PAIR+=(1) ;; *) S_PAIR+=('') ;; esac
      case ,$with, in *,whole,*) S_WHOLE+=(1) ;; *) S_WHOLE+=('') ;; esac ;;
    prep) P_NAME+=("$name") P_EXPECT+=("$expect") P_DEADLINE+=("$deadline") P_NEEDS+=("$needs") P_CMD+=("$command") ;;
    warm) WARM_EXPECT[$name]=$expect WARM_DEADLINE[$name]=$deadline WARM_CMD[$name]=$command ;;
    load) L_NAME+=("$name") L_DEADLINE+=("$deadline") L_NEEDS+=("$needs") L_CMD+=("$command") ;;
    image) I_NAME+=("$name") I_DEADLINE+=("$deadline") I_NEEDS+=("$needs") I_CMD+=("$command") ;;
  esac
done <"$TABLE"
[ "${#S_NAME[@]}" -gt 0 ] && [ "${#L_NAME[@]}" -gt 0 ] || refuse 65 "$TABLE: the table needs a subject row and a load row"
for i in "${!S_NAME[@]}"; do
  [ "${S_WARM[$i]}" = - ] || [ -n "${WARM_CMD[${S_WARM[$i]}]+set}" ] ||
    refuse 65 "$TABLE: the subject ${S_NAME[$i]} names the warm row ${S_WARM[$i]}, which the table lacks"
done

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

# The conditions subject $1 runs, as chosen, in their order; alone stands
# for the alone run after a failure, or on its own when neither busy nor
# pair is chosen.
conditions() {
  local c=()
  if chosen busy; then c+=(busy); fi
  if chosen pair && [ -n "${S_PAIR[$1]}" ]; then c+=(pair); fi
  if chosen whole && [ -n "${S_WHOLE[$1]}" ]; then c+=(whole); fi
  if chosen alone; then c+=(alone); fi
  echo "${c[*]}"
}
# Whether subject $1 runs alone only after a failed busy or pair run.
alone_decides() { chosen busy || { chosen pair && [ -n "${S_PAIR[$1]}" ]; }; }

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
  [ -n "$(conditions "$i")" ] || continue
  if needs_hold "${S_NEEDS[$i]}"; then MEASURED+=("$i"); else SKIP[$i]=$REASON; fi
done
PAIRED=false WORKERS=0
declare -A WARMS=()
for i in "${MEASURED[@]}"; do
  if chosen pair && [ -n "${S_PAIR[$i]}" ]; then PAIRED=true; fi
  if chosen busy && [ $((4 - S_Q[i])) -gt "$WORKERS" ]; then WORKERS=$((4 - S_Q[i])); fi
  [ "${S_WARM[$i]}" = - ] || WARMS[${S_WARM[$i]}]=1
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
  if [ "$WORKERS" -gt 0 ]; then
    for i in "${!L_NAME[@]}"; do [ -n "$REFUSAL" ] || needs_hold "${L_NEEDS[$i]}" || REFUSAL="the load row ${L_NAME[$i]}: $REASON"; done
    for i in "${!I_NAME[@]}"; do [ -n "$REFUSAL" ] || needs_hold "${I_NEEDS[$i]}" || REFUSAL="the image row ${I_NAME[$i]}: $REASON"; done
  fi
fi

# --- the plan ----------------------------------------------------------------

# Seconds as 1h02m, 4m10s or 9s.
human() {
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}
plan() {
  local i q c prep=0 warm=0 total=0 t w names
  echo "load check of $ROOT at $(git -C "$ROOT" rev-parse --short HEAD), $ROUNDS round(s) of ${CHOSEN//,/ }"
  echo "processors: $ALL; ${#CORES[@]} whole cores, $PER in each quarter"
  for q in 1 2 3 4; do echo "quarter $q: ${QUARTER[$q]}"; done
  echo "outside every quarter: ${LEFT:-none}"
  for i in "${!P_NAME[@]}"; do prep=$((prep + P_EXPECT[i])); done
  for w in "${!WARMS[@]}"; do warm=$((warm + WARM_EXPECT[$w])); done
  if [ "${#ROLES[@]}" -gt 0 ]; then
    echo "scratch worktrees: ${ROLES[*]}, in ${LOAD_CHECK_WORKTREES:-$(dirname "$ROOT")}, prepared cold by ${P_NAME[*]:-nothing}: about $(human "$prep") for a, then as long for the others side by side"
    names=$(printf '%s\n' "${!WARMS[@]}" | sort | paste -sd' ' -)
    echo "warmed: ${names:-nothing}, about $(human "$warm")"
    if [ "$WORKERS" -gt 0 ]; then
      echo "busy load: on each quarter a subject leaves, ${L_NAME[*]} in a loop; on the last of them, ${I_NAME[*]:-no image build} in a loop besides"
    fi
    total=$((2 * prep + warm))
  fi
  for i in "${SEL[@]}"; do
    q=${S_Q[$i]}
    if [ "$q" = 4 ]; then echo "subject ${S_NAME[$i]}: not measured: it takes all four quarters"; continue; fi
    if [ -n "${SKIP[$i]+set}" ]; then echo "subject ${S_NAME[$i]}: skipped: ${SKIP[$i]}"; continue; fi
    case " ${MEASURED[*]} " in *" $i "*) ;; *) echo "subject ${S_NAME[$i]}: none of its conditions is chosen"; continue ;; esac
    t=0
    printf 'subject %s: %s quarter(s), warm %s;' "${S_NAME[$i]}" "$q" "${S_WARM[$i]}"
    for c in $(conditions "$i"); do
      case $c in
        busy) printf ' busy %s, load %s;' "$(span 1 "$q")" "$(span $((q + 1)) 4)"; t=$((t + S_EXPECT[i])) ;;
        pair) printf ' pair a %s b %s;' "$(span 1 "$q")" "$(span $((q + 1)) $((2 * q)))"; t=$((t + S_EXPECT[i])) ;;
        whole) printf ' whole %s;' "$(span 1 4)"; t=$((t + S_EXPECT[i] / 2)) ;;
        alone)
          if alone_decides "$i"; then printf ' alone %s after a failure;' "$(span 1 "$q")"
          else printf ' alone %s;' "$(span 1 "$q")"; t=$((t + S_EXPECT[i])); fi ;;
      esac
    done
    t=$((t * ROUNDS))
    total=$((total + t))
    printf ' about %s\n' "$(human "$t")"
  done
  echo "expected: about $(human "$total") for ${#MEASURED[@]} measured subject(s), ${#SKIP[@]} skipped, ${#OUTSIDE[@]} not measured, besides an alone run after each failure"
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

declare -A WT=() PREFIX_OF=() WARMED=()
PREFIXES=("$OWN_PREFIX")
MADE=()
REGISTRY_OWNED=false
FINISHED=false
# What the clean-up could not do, and what may still hold the worktrees.
CLEANUP_FAILED=
HELD=

# A leader: started contained, it runs its command in the background from
# the directory it is given and waits for it; stopped, it passes the
# signal to its process group, waits until nothing else of the group is
# left, and exits 128 + the signal. A worker runs its steps in a loop the
# same way, each stopped at its deadline (124), and writes `begin NAME
# TIME` and `end NAME TIME STATUS` to its status file around each.
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
# PROCESSORS, as LABEL<TAB>PID<TAB>NAME<TAB>ALLOWED.
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
    want, todo = cpus(want), [int(pid)]
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
        allowed = fields.get("Cpus_allowed_list", "").strip()
        if cpus(allowed) != want:
            print(f"{label}\t{p}\t{fields.get('Name', '').strip()}\t{allowed}")
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
# Survivors $2 of what $1 names: recorded, and they keep the worktrees.
survived() {
  CLEANUP_FAILED="$CLEANUP_FAILED survivors of $1: $2;"
  HELD="${HELD:+$HELD; }processes $2 of $1 outlived their stop"
}

# The jobs of the current step, each a contained, placed command.
J_LABEL=() J_PID=() J_CPUS=() J_START=() J_DUE=() J_END=() J_STATUS=() J_NOTE=() J_LOG=() J_DEADLINE=() J_PREFIX=()
# The busy load's workers.
W_PID=() W_CPUS=() W_FILE=() W_LABEL=()
CONTEXT= W_NOTE= BUSY_VOID= DOCKER_SEEN=
reset_jobs() { J_LABEL=() J_PID=() J_CPUS=() J_START=() J_DUE=() J_END=() J_STATUS=() J_NOTE=() J_LOG=() J_DEADLINE=() J_PREFIX=(); }

# launch LABEL ROLE PROCESSORS LOG OUTDIR DEADLINE COMMAND: starts COMMAND
# in ROLE's worktree as a job.
launch() {
  local k=${#J_PID[@]} role=$2
  mkdir -p "$5" || return 1
  J_LABEL[$k]=$1 J_CPUS[$k]=$3 J_LOG[$k]=$4 J_NOTE[$k]= J_END[$k]= J_STATUS[$k]= J_DEADLINE[$k]= J_PREFIX[$k]=${PREFIX_OF[$role]}
  J_START[$k]=$(now)
  J_DUE[$k]=$((SECONDS + $6))
  if ! contain_start -g "$GRACE" taskset -c "$3" \
      env -u MIX_BUILD_PATH -u MIX_DEPS_PATH -u CYFR_TEST_CORES -u CARGO_BUILD_JOBS -u ERL_FLAGS \
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" HEAVY_CHECK_CPUS="$3" LOAD_CHECK_OUT="$5" LOAD_CHECK_PARTS="$(gate_parts "$(count "$3")")" \
      "$BASH" -c "$LEADER" load-check-run "${WT[$role]}" "$7" >"$4" 2>&1 </dev/null; then
    J_PID[$k]=
    J_END[$k]=${J_START[$k]} J_STATUS[$k]=1 J_NOTE[$k]='could not start'
    return 1
  fi
  J_PID[$k]=$CONTAIN_PID
}

# Every live job's and worker's processes against their processors, and
# every container named under a live job's prefix: one with a cpuset must
# have the job's processors, one without runs on any processor.
sample() {
  local args=() i label pid name allowed k
  for i in "${!J_PID[@]}"; do
    [ -z "${J_END[$i]}" ] && [ -n "${J_PID[$i]}" ] && args+=("j$i:${J_PID[$i]}:${J_CPUS[$i]}")
  done
  for i in "${!W_PID[@]}"; do [ -n "${W_PID[$i]}" ] && args+=("w$i:${W_PID[$i]}:${W_CPUS[$i]}"); done
  [ "${#args[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r label pid name allowed; do
    k=${label#?}
    case $label in
      j*)
        case " ${J_NOTE[$k]} " in *" $pid "*) continue ;; esac
        J_NOTE[$k]="${J_NOTE[$k]:+${J_NOTE[$k]} }outside $pid $name ($allowed)"
        printf '%s\t%s\tprocess\t%s\t%s\t%s\t%s\n' "$CONTEXT" "${J_LABEL[$k]}" "$pid" "$name" "$allowed" "${J_CPUS[$k]}" >>"$OUT/masks.tsv" ;;
      w*)
        case " $W_NOTE " in *" $pid "*) continue ;; esac
        W_NOTE="${W_NOTE:+$W_NOTE }outside ${W_LABEL[$k]} $pid $name ($allowed)"
        printf '%s\t%s\tprocess\t%s\t%s\t%s\t%s\n' "$CONTEXT" "${W_LABEL[$k]}" "$pid" "$name" "$allowed" "${W_CPUS[$k]}" >>"$OUT/masks.tsv" ;;
    esac
  done < <(python3 -I -c "$SAMPLER" "${args[@]}" 2>/dev/null)
  $DOCKER_OK || return 0
  while IFS= read -r name; do
    for i in "${!J_PID[@]}"; do
      [ -z "${J_END[$i]}" ] || continue
      case $name in "${J_PREFIX[$i]}"*) ;; *) continue ;; esac
      case " $DOCKER_SEEN " in *" $name "*) continue ;; esac
      DOCKER_SEEN="$DOCKER_SEEN $name"
      allowed=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$name" 2>/dev/null) || allowed='?'
      printf '%s\t%s\t%s\t%s\n' "$CONTEXT" "${J_LABEL[$i]}" "$name" "${allowed:-any processor}" >>"$OUT/docker.tsv"
      if [ -n "$allowed" ] && [ "$(cpus_of "$allowed" 2>/dev/null)" != "$(cpus_of "${J_CPUS[$i]}")" ]; then
        J_NOTE[$i]="${J_NOTE[$i]:+${J_NOTE[$i]} }outside container $name ($allowed)"
        printf '%s\t%s\tcontainer\t-\t%s\t%s\t%s\n' "$CONTEXT" "${J_LABEL[$i]}" "$name" "$allowed" "${J_CPUS[$i]}" >>"$OUT/masks.tsv"
      fi
    done
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
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
        [ -z "$CONTAIN_SURVIVORS" ] || survived "${J_LABEL[$i]}" "$CONTAIN_SURVIVORS"
      elif [ "$SECONDS" -ge "${J_DUE[$i]}" ]; then
        say "${J_LABEL[$i]} reached its deadline: stopping it"
        contain_stop "${J_PID[$i]}" "$GRACE" || survived "${J_LABEL[$i]}" "$CONTAIN_SURVIVORS"
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
  local q=$1 dir=$2 k n=0 i rows=() irows=() wt
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
      PROOF_RUN_PREFIX="${PREFIX_OF[$role]}" HEAVY_CHECK_CPUS="${QUARTER[$quarter]}" LOAD_CHECK_OUT="$base.out" LOAD_CHECK_PARTS="$(gate_parts "$(count "${QUARTER[$quarter]}")")" \
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
  contain_stop_all "$GRACE" || survived 'the busy load' "$CONTAIN_SURVIVORS"
  W_PID=()
}

# Writes the current jobs to report.tsv under subject $1, round $2 and
# condition $3 and says how each ended; sets SKIPPED when one skipped and
# FAILED when a busy or pair run failed.
record() {
  local i status note why
  for i in "${!J_PID[@]}"; do
    note=${J_NOTE[$i]}
    case ${J_STATUS[$i]} in
      0) status=passed ;;
      69|77)
        status=skipped
        why=$(sed '/^[[:space:]]*$/d; /^_EXIT=/d' "${J_LOG[$i]}" 2>/dev/null | grep -i missing | tail -n 1)
        [ -n "$why" ] || why=$(sed '/^[[:space:]]*$/d; /^_EXIT=/d' "${J_LOG[$i]}" 2>/dev/null | tail -n 1)
        note="exited ${J_STATUS[$i]}: ${why:-a missing prerequisite}"
        SKIPPED=$note ;;
      *) status=failed ;;
    esac
    [ -z "${J_DEADLINE[$i]}" ] || { status=deadline; note="${note:+$note; }stopped at its deadline"; }
    if [ "$3" = busy ] && [ -n "$BUSY_VOID" ]; then note="${note:+$note; }$BUSY_VOID"; fi
    if [ "$status" = passed ]; then
      if [ "$3" = busy ] && [ -n "$BUSY_VOID" ]; then status=void; fi
      case $note in *outside*) status=void ;; esac
    fi
    case $3/$status in busy/failed|busy/deadline|pair/failed|pair/deadline) FAILED=1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${J_LABEL[$i]##* }" "${J_CPUS[$i]}" \
      "$status" "${J_STATUS[$i]}" "$(seconds "${J_START[$i]}" "${J_END[$i]}")" "${J_START[$i]}" "${J_END[$i]}" \
      "${note:--}" "${J_LOG[$i]}" >>"$OUT/report.tsv"
    say "$1 round $2 $3 ${J_LABEL[$i]##* }: $status after $(seconds "${J_START[$i]}" "${J_END[$i]}")s${note:+ ($note)}"
  done
}

# run_condition SUBJECT ROUND CONDITION
run_condition() {
  local i=$1 r=$2 c=$3 q=${S_Q[$1]} name=${S_NAME[$1]} dir
  dir="$OUT/$name/r$r-$c"
  mkdir -p "$dir" || return 1
  CONTEXT="$name"$'\t'"$r"$'\t'"$c"
  reset_jobs
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
  if [ "$c" = pair ]; then
    launch "$name b" b "$(span $((q + 1)) $((2 * q)))" "$dir/b.log" "$dir/b" "${S_DEADLINE[$i]}" "${S_CMD[$i]}"
  fi
  watch_jobs
  if [ "$c" = busy ]; then
    busy_held "${J_START[0]}" "${J_END[0]}" || :
    stop_busy
  fi
  record "$name" "$r" "$c"
}

# Warms subject $1's worktrees with its warm row, each worktree once:
# unplaced, a's and b's side by side.
warm_subject() {
  local i=$1 w=${S_WARM[$1]} role roles=(a)
  [ "$w" != - ] || return 0
  if chosen pair && [ -n "${S_PAIR[$i]}" ]; then roles+=(b); fi
  reset_jobs
  CONTEXT="warm"$'\t'"-"$'\t'"$w"
  for role in "${roles[@]}"; do
    [ -z "${WARMED[$role/$w]:-}" ] || continue
    WARMED[$role/$w]=1
    launch "warm-$w $role" "$role" "$ALL" "$OUT/warm-$w-$role.log" "$OUT/warm-$w-$role" "${WARM_DEADLINE[$w]}" "${WARM_CMD[$w]}"
  done
  [ "${#J_PID[@]}" -gt 0 ] || return 0
  watch_jobs
  for i in "${!J_PID[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "${J_LABEL[$i]}" "${J_STATUS[$i]}" "$(seconds "${J_START[$i]}" "${J_END[$i]}")" "${J_LOG[$i]}" >>"$OUT/warm.tsv"
    say "${J_LABEL[$i]}: exit ${J_STATUS[$i]} after $(seconds "${J_START[$i]}" "${J_END[$i]}")s"
  done
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
    esac || {
      CLEANUP_FAILED="$CLEANUP_FAILED the listing of Docker's ${kind}s;"
      [ "$kind" != container ] || HELD="${HELD:+$HELD; }Docker's containers could not be listed"
      continue
    }
    while IFS= read -r name; do
      [ -n "$name" ] && ours "$name" || continue
      case $kind in
        container) docker rm -f -v "$name" ;;
        network) docker network rm "$name" ;;
        volume) docker volume rm -f "$name" ;;
        image) docker image rm -f "$name" ;;
      esac >/dev/null 2>&1 && continue
      CLEANUP_FAILED="$CLEANUP_FAILED the $kind $name;"
      [ "$kind" != container ] || HELD="${HELD:+$HELD; }the container $name could not be removed"
    done <<<"$names"
  done
}
cleanup() {
  local p f path kept=()
  contain_stop_all "$GRACE" || survived 'the run' "$CONTAIN_SURVIVORS"
  if $REGISTRY_OWNED; then
    contain_sweep_registry "$GRACE" || survived 'the registry' "$CONTAIN_SURVIVORS"
  fi
  docker_sweep
  for path in "${MADE[@]}"; do [ ! -e "$path" ] || kept+=("$path"); done
  for p in "${PREFIXES[@]}"; do
    for f in "${TMPDIR:-/tmp}/$p"*; do [ ! -e "$f" ] || kept+=("$f"); done
  done
  for path in ${kept[@]+"${kept[@]}"}; do
    if [ -n "$HELD" ]; then
      echo "load check: kept $path: $HELD" >&2
      CLEANUP_FAILED="$CLEANUP_FAILED kept $path;"
    elif [ "${path#"$WT_ROOT"/}" != "$path" ]; then
      remove_worktree "$path"
    else
      rm -rf -- "$path" 2>/dev/null || CLEANUP_FAILED="$CLEANUP_FAILED $path;"
    fi
  done
  if $REGISTRY_OWNED; then rm -f "$CONTAIN_REGISTRY"; fi
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
  [ -n "$prep_command" ] || prep_command=true deadline=60
  printf 'worktree\tstatus\texit\tseconds\tlog\n' >"$OUT/prep.tsv"
  for wave in a rest; do
    reset_jobs
    CONTEXT="prep"$'\t'"-"$'\t'"$wave"
    for role in "${ROLES[@]}"; do
      { [ "$wave" = a ] && [ "$role" = a ]; } || { [ "$wave" = rest ] && [ "$role" != a ]; } || continue
      launch "prep $role" "$role" "$ALL" "$OUT/prep-$role.log" "$OUT/prep-$role" "$deadline" "$prep_command"
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

: >"$OUT/warm.tsv"
for i in "${MEASURED[@]}"; do
  SKIPPED=
  warm_subject "$i"
  for ((r = 1; r <= ROUNDS; r++)); do
    FAILED=
    for c in $(conditions "$i"); do
      [ "$c" != alone ] || continue
      run_condition "$i" "$r" "$c"
      [ -z "$SKIPPED" ] || break
    done
    if chosen alone && { [ -n "$FAILED" ] || ! alone_decides "$i"; } && { [ -z "$SKIPPED" ] || [ -n "$FAILED" ]; }; then
      run_condition "$i" "$r" alone
    fi
    if [ -n "$SKIPPED" ]; then printf '%s\tskipped: %s\n' "${S_NAME[$i]}" "$SKIPPED" >>"$OUT/skips.tsv"; break; fi
  done
done

# The summary: report.txt, printed, and the exit it implies.
names=()
for i in "${SEL[@]}"; do names+=("${S_NAME[$i]}:${S_Q[$i]}"); done
status=0
python3 -I - "$OUT" "${names[@]}" <<'PY' || status=$?
import csv, os, statistics, sys

out, subjects = sys.argv[1], [a.rsplit(":", 1) for a in sys.argv[2:]]


def table(name):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [line.rstrip("\n").split("\t") for line in f]


with open(os.path.join(out, "report.tsv")) as f:
    rows = list(csv.DictReader(f, delimiter="\t"))
skips = {}
for name, reason in table("skips.tsv"):
    skips.setdefault(name, reason)
lines, fails_busy, fails_other, undecided, skipped, outside, holds = [], [], [], [], [], [], []


def median(runs):
    passed = [float(r["seconds"]) for r in runs if r["status"] == "passed"]
    return statistics.median(passed) if passed else None


for name, quarters in subjects:
    runs = [r for r in rows if r["subject"] == name]
    by = {c: [r for r in runs if r["condition"] == c] for c in ("busy", "pair", "whole", "alone")}
    bad = lambda c: [r for r in by[c] if r["status"] in ("failed", "deadline")]
    if bad("busy") or bad("pair"):
        if by["alone"] and all(r["status"] == "passed" for r in by["alone"]):
            verdict = "FAILS BUSY"
            fails_busy.append(name)
        elif bad("alone"):
            verdict = "fails alone"
            fails_other.append(name)
        else:
            verdict = "fails busy; alone not decided" + (f" ({skips[name]})" if name in skips else "")
            fails_other.append(name)
    elif bad("alone"):
        verdict = "fails alone"
        fails_other.append(name)
    elif bad("whole"):
        verdict = "fails on the whole machine"
        fails_other.append(name)
    elif name in skips:
        verdict = skips[name]
        (outside if verdict.startswith("not measured") else skipped).append(name)
    elif any(r["status"] == "void" for r in runs):
        verdict = "not decided: a run was void"
        undecided.append(name)
    elif runs:
        verdict = "holds"
        holds.append(name)
    else:
        continue
    if not runs:
        lines.append(f"{name}: {verdict}")
        continue
    lines.append(f"{name} ({quarters} quarter{'s' if quarters != '1' else ''}): {verdict}")
    for c, group in by.items():
        if not group:
            continue
        passed = sum(r["status"] == "passed" for r in group)
        m = median(group)
        text = f"  {c} {passed}/{len(group)} passed, median {'n/a' if m is None else f'{m:.1f}s'}"
        if c == "whole":
            b = median(by["busy"])
            text += "; busy/whole " + ("n/a" if b is None or m is None or m == 0 else f"{b / m:.2f}")
        lines.append(text)
        for r in group:
            if r["status"] != "passed":
                lines.append(f"    round {r['round']} {r['copy']}: {r['status']} (exit {r['exit']}) after {r['seconds']}s: {r['note']}; {r['log']}")
prep = table("prep.tsv")[1:]
if prep:
    lines.append("cold preparation: " + ", ".join(f"{p[0]} {p[1]} after {p[3]}s" for p in prep))
warm = table("warm.tsv")
if warm:
    lines.append("warmed: " + ", ".join(f"{w[0]} exit {w[1]} after {w[2]}s" for w in warm))
masks = table("masks.tsv")
lines.append(f"placement: {len(masks)} process(es) or container(s) outside their processors" + (f", listed in {out}/masks.tsv" if masks else ""))
docker = table("docker.tsv")
host = [f"{d[4]} ({d[5]})" for d in docker if d[0] == "host"]
started = [d for d in docker if d[0] != "host"]
anywhere = sum(d[5] == "any processor" for d in started)
lines.append("not placed by this check: the host's containers " + (", ".join(host) if host else "(none ran)") +
             f"; {len(started)} container(s) its runs started, {anywhere} of them on any processor (docker.tsv)")
summary = [f"holds: {len(holds)}"]
if fails_busy:
    summary.append("FAILS BUSY: " + " ".join(fails_busy))
if fails_other:
    summary.append("fails: " + " ".join(fails_other))
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
