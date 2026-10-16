#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# The per-commit gate: scripts/commit-gate.sh [-l LOGDIR] [-n N] [--close] [-- PostgreSQL test paths]
#
# Runs the checks a commit must pass as concurrent legs, one log per step
# under LOGDIR, and frames its stdout with `_START=<pid>` first and
# `_EXIT=<pid> <status>` last, both carrying the gate's own pid, which
# scripts/await-task.sh waits for. Under scripts/heavy-check.sh
# (HEAVY_CHECK_HELD set) heavy-check writes those lines and the gate
# writes neither; a scoped check (`heavy-check.sh -s`) is refused with 64,
# because the gate sizes itself to the whole host. Legs:
#   static    SQLite test compile and forced dev compile (warnings as
#             errors, so every Boundary declaration is checked), format,
#             credo, ops.gen.cli --check, cyfr.gen.configuration_guide
#             --check, the console's JavaScript tests, CI's built-SDK and
#             built-toolkit checks (their scripts read from test.yml), the
#             release-boot names test, the canary's own checks, the image
#             suites' shared plumbing (tests/imagesuite_test.py) and the
#             two Python self-checks (worker_auth.py and the backends
#             harness.py; none needs a database or an image), dialyzer,
#             the Boundary plants, then the full SQLite suite in N
#             partitions, with its merged line coverage reported
#   postgres  PostgreSQL test compile, then in two partitions the given
#             test paths or, with none given, the selection: the storage
#             set (apps/arca/test, apps/cyfr/test/arca) and every tracked
#             apps/*/test test file outside it that tags a test for one
#             adapter or branches on the adapter (PG_PATTERN below), each
#             path once. Its summary counts the paths handed to the runner
#             as `pg_selection=<n>`, the report says so, and
#             postgres.pg_selection.txt lists them. With --close the whole
#             suite in N partitions instead, started once the SQLite
#             suite's partitions have exited (four pools across the
#             adapter jobs)
#   cluster   with --close only, after every other leg: the real-member
#             suite alone on its own database
#   vocab     the CI vocabulary job's own script, read from test.yml
#   islands   prima, arca and sanctum compiled and tested from a copy that
#             holds only what CI gives them, once the SQLite suite's
#             partitions have exited; locus with --close
# Every gate forces the test rebuild on both adapters. Each leg discards
# the caller's MIX_BUILD_PATH: static builds its MIX_ENV=test steps in
# _build/test and its MIX_ENV=dev steps in Mix's default, postgres and
# cluster build in _build/test_pg, and an island builds inside its copy.
# Not part of this gate, so a closing record names each with its own
# result: the model catalysts' tests, the seed guests' builds and stamps,
# the partition scripts' own tests, the image suites, the S3 suite, the
# release boots, the browser harness and its proofs, the seed and
# configuration guards, the Go checks, the license and security scanners,
# and the benchmark.
# Without -n a suite runs in eight partitions on a host of sixteen cores
# or more (two schedulers each) and in four on a smaller one. A PostgreSQL
# partition holds twenty connections, so the server allows twenty times
# the count and the cluster suite's besides: 400 on the verification host.
# -l names a log directory that does not exist yet or is empty; anything
# else is refused with 64 before any leg starts. A relative LOGDIR
# resolves against the caller's directory. Without -l the gate makes a
# fresh one.
# Every step runs in a session of its own (scripts/lib/contain.sh) under a
# deadline, several times what it takes on a quiet host: a step that
# reaches it is stopped with everything it started, recorded as
# `name=124`, and fails its leg, so a stalled check ends the gate instead
# of keeping the host. GATE_STEP_DEADLINE=SECONDS (positive, at most six
# decimal digits, as the containment library takes) gives every step that
# one deadline. Each leg is this script run in a session of its own, so a
# gate that is killed outright still has its legs and their steps stopped
# by their watchdogs. Stopping the gate (INT, TERM, HUP) stops its legs,
# each leg its steps first, and the gate exits 130, 143 or 129. Its exit
# line says 0 only when the whole run completed and passed; a gate ended
# by any other signal reports 1.
set -uo pipefail

usage() { echo "usage: $0 [-l LOGDIR] [-n N] [--close] [-- PostgreSQL test paths]"; }

# Test files that run on one adapter only or assert per adapter: an
# adapter tag, an adapter predicate, or a read of the configured adapter.
PG_PATTERN='@(module|describe)?tag :(postgres|sqlite)\b|(^|[^_a-z])(postgres|sqlite)\?\(\)|@sqlite\?|Arca\.Repo\.adapter\(\)|Arca\.Test\.Adapter\.|__adapter__|compile_env\(:arca, *:adapter|repo_adapter\(\)'

# The postgres leg's default selection, one path a line, read from the
# tracked files of the current directory's repository: the storage set,
# then the matching files outside it, so no file is named twice. macOS git
# grep -E ignores \b, so there the pattern runs as PCRE, which reads it the
# same way.
pg_selection() {
  local s=0 mode=-E
  [ "$(uname -s)" != Darwin ] || mode=-P
  printf '%s\n' apps/arca/test apps/cyfr/test/arca
  git grep -l "$mode" "$PG_PATTERN" -- ':(glob)apps/*/test/**/*_test.exs' \
    ':(exclude,glob)apps/arca/test/**' ':(exclude,glob)apps/cyfr/test/arca/**' || s=$?
  # git grep answers 1 when nothing matches.
  [ "$s" -le 1 ]
}

deadline_for() {
  if [ -n "${GATE_STEP_DEADLINE:-}" ]; then echo "$GATE_STEP_DEADLINE"; return; fi
  case "$1" in
    fossils|format|credo|opsgen|confguide|js_suite|sdk_bundle|toolkit_bundle|boot_names|canary_checks|imagesuite_checks|worker_auth_check|backends_check|island_compile|island_test) echo 600 ;;
    compile_*|boundary_plants) echo 1200 ;;
    # A first run builds the PLT.
    dialyzer) echo 2400 ;;
    *) echo 1800 ;;
  esac
}

# The steps of a leg, for the deadline of a leg that waits on it.
STATIC_STEPS='compile_sqlite_test compile_sqlite_dev format credo opsgen confguide js_suite sdk_bundle toolkit_bundle boot_names canary_checks imagesuite_checks worker_auth_check backends_check dialyzer boundary_plants sqlite_suite'
steps_of() {
  case "$1" in
    static) echo "$STATIC_STEPS" ;;
    postgres) if $CLOSE; then echo 'compile_pg_test pg_suite'; else echo 'compile_pg_test pg_tests'; fi ;;
  esac
}

# The first status contain_start refused a step with: the leg exits with
# it, and so does the gate.
REFUSED=

# One step: its command runs in a session of its own with its own log
# under its deadline, and its status is appended to the leg's summary as
# `name=status`; a process that outlived the stop fails the step and is
# named there as `name_survivors=pid,...`. Nothing here echoes the
# command: the cluster step's environment holds a database password.
step() {
  local leg=$1 name=$2 log status=0 secs
  shift 2
  log="$LOGDIR/$leg.$name.log"
  secs=$(deadline_for "$name")
  if contain_start -g 180 "$@" >"$log" 2>&1 </dev/null; then
    contain_wait "$CONTAIN_PID" "$secs" 180 || status=$?
    if [ "$status" -eq 124 ]; then
      echo "==> $leg.$name stopped at its ${secs}s deadline" | tee -a "$log" >&2
    fi
    if [ -n "$CONTAIN_SURVIVORS" ]; then
      echo "==> $leg.$name left $CONTAIN_SURVIVORS after KILL" | tee -a "$log" >&2
      echo "${name}_survivors=${CONTAIN_SURVIVORS// /,}" >> "$LOGDIR/$leg.summary"
      [ "$status" -ne 0 ] || status=1
    fi
  else
    status=$?
    [ -n "$REFUSED" ] || REFUSED=$status
    echo "==> $leg.$name could not start: $(tail -n 1 "$log")" >&2
  fi
  echo "$name=$status" >> "$LOGDIR/$leg.summary"
  return "$status"
}

leg_static() {
  # Both test builds are forced on every gate. A module stores the
  # signatures it infers from the remote functions it calls, and Mix
  # recompiles it only when a compile-time or export dependency changes,
  # so an incremental build keeps a caller's stale signatures: the gate
  # would then fail on a type warning that is not the commit's, or pass
  # without one the commit has.
  step static compile_sqlite_test env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test mix compile --force --warnings-as-errors || return
  # Forced: incremental state can keep a Boundary declaration the tree no
  # longer has, and a plain compile only warns. Mix takes MIX_BUILD_PATH
  # as given, with no environment suffix, so the dev steps run on Mix's
  # default, _build/dev, and never share a directory with the test build.
  step static compile_sqlite_dev env CYFR_DATABASE=sqlite MIX_ENV=dev mix compile --force --warnings-as-errors || return
  step static format mix format --check-formatted || return
  step static credo mix credo --strict || return
  step static opsgen mix ops.gen.cli --check || return
  step static confguide mix cyfr.gen.configuration_guide --check || return
  step static js_suite apps/cyfr/assets/test/run.sh || return
  # Each rebuilds its bundle into the checkout and fails when the tracked
  # file is not the build, as CI's test job runs it.
  local sdk="$LOGDIR/static.sdk_bundle.sh" toolkit="$LOGDIR/static.toolkit_bundle.sh"
  if ! ci_step "The built SDK is its source's" > "$sdk" ||
    ! ci_step "The built toolkit is its source's" > "$toolkit"; then
    echo "ci_steps=1" >> "$LOGDIR/static.summary"
    return 1
  fi
  step static sdk_bundle env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test bash "$sdk" || return
  step static toolkit_bundle env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test bash "$toolkit" || return
  step static boot_names bash tests/release-boot/names-test.sh || return
  step static canary_checks python3 -I tests/locus-runtime-image/canary_test.py || return
  step static imagesuite_checks python3 -I tests/imagesuite_test.py || return
  # The image suites' own protocol code against the vectors, with no image.
  step static worker_auth_check python3 -I tests/locus-runtime-image/worker_auth.py --self-check || return
  step static backends_check python3 -I tests/locus-backends-image/harness.py --self-check || return
  step static dialyzer mix dialyzer || return
  # The Boundary plants: each writes a forbidden edge into a copy of the tree
  # and force-compiles it, so they run once here and never in the partitions.
  step static boundary_plants env MIX_BUILD_PATH=_build/test CYFR_DATABASE=sqlite MIX_ENV=test mix test apps/cyfr/test/cyfr/boundaries_test.exs --only boundary_plant || return
  # --cover: the suite's line coverage, merged across the partitions and
  # reported as one line; the figure never fails the step.
  step static sqlite_suite env MIX_BUILD_PATH=_build/test scripts/test-partitioned.sh -n "$PARTS" -a sqlite --cover -- --warnings-as-errors || return
}

leg_postgres() {
  export MIX_BUILD_PATH=_build/test_pg
  # Forced for the stale inferred signatures leg_static names.
  step postgres compile_pg_test env CYFR_DATABASE=postgres MIX_ENV=test mix compile --force --warnings-as-errors || return
  if $CLOSE; then
    # One adapter's suite has the host at a time: the PostgreSQL suite's
    # partitions start once the SQLite suite's have exited.
    await_leg postgres static || return
    step postgres pg_suite scripts/test-partitioned.sh -n "$PARTS" -a postgres -- --warnings-as-errors || return
  else
    local list="$LOGDIR/postgres.pg_selection.txt" paths=() p
    if [ "${#PG_PATHS[@]}" -gt 0 ]; then
      printf '%s\n' "${PG_PATHS[@]}" > "$list"
    elif ! pg_selection > "$list"; then
      echo '==> postgres: the PostgreSQL selection could not be read (git grep)' >&2
      echo 'pg_selection_read=1' >> "$LOGDIR/postgres.summary"
      return 1
    fi
    while IFS= read -r p; do paths+=("$p"); done < "$list"
    echo "pg_selection=${#paths[@]}" >> "$LOGDIR/postgres.summary"
    step postgres pg_tests scripts/test-partitioned.sh -n 2 -a postgres -- --warnings-as-errors "${paths[@]}" || return
  fi
}

# The script of test.yml's step named $1, as CI runs it, on stdout: read
# from the workflow, so the gate's copy and CI's cannot drift.
ci_step() {
  python3 - .github/workflows/test.yml "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for s in job.get("steps", []):
        if s.get("name") == sys.argv[2]:
            print("set -e"); print(s["run"]); sys.exit(0)
sys.exit(f"step {sys.argv[2]!r} not found in test.yml")
PY
}

# The vocabulary job's script is CI's. macOS git grep -E ignores \b, so
# there the patterns run as PCRE, which reads them the same way.
leg_vocab() {
  local script="$LOGDIR/vocab.sh"
  ci_step "Tier A/B fossil patterns must be absent" > "$script" || return 1
  if [ "$(uname -s)" = Darwin ]; then sed -i '' 's/git grep -InE/git grep -InP/' "$script"; fi
  step vocab fossils bash "$script"
}

# One phase of an island, in the island's directory, under its deadline.
island_phase() {
  local name=$1 phase=$2 status=0
  shift 2
  if contain_start -g 180 env CYFR_DATABASE=sqlite MIX_OS_CONCURRENCY_LOCK=0 "$@" >>"$ISLAND_LOG" 2>&1 </dev/null; then
    contain_wait "$CONTAIN_PID" "$(deadline_for "island_$phase")" 180 || status=$?
    if [ "$status" -eq 124 ]; then
      echo "==> islands.$name stopped at its deadline" | tee -a "$ISLAND_LOG" >&2
    fi
    if [ -n "$CONTAIN_SURVIVORS" ]; then
      echo "==> islands.$name left $CONTAIN_SURVIVORS after KILL" | tee -a "$ISLAND_LOG" >&2
      echo "${name}_survivors=${CONTAIN_SURVIVORS// /,}" >> "$LOGDIR/islands.summary"
      [ "$status" -ne 0 ] || status=1
    fi
  else
    status=$?
    # The leg reads this back and exits with the refusal, as a refused
    # step makes it.
    echo "${name}_refused=$status" >> "$LOGDIR/islands.summary"
    echo "==> islands.$name could not start its $phase phase: $(tail -n 1 "$ISLAND_LOG")" >&2
  fi
  return "$status"
}

# An island is an application compiled and tested from a copy holding only
# what CI copies for it (the copy lists are test.yml's), deps linked in.
# Its build directory is the copy's own and one Mix process at a time
# uses it, so Mix's build lock excludes no one there, and it is off: Mix
# through 1.20.4 can wait forever on a lock it holds itself, the second
# time a fresh lock directory is taken. It runs as a subshell of the
# islands leg and starts its phases' sessions itself, so it stops them on
# TERM, which the leg sends it when the leg is stopped.
island() {
  local name=$1 a status=0
  shift
  ISLAND_COPY=
  trap 'trap "" INT TERM; contain_stop_all 180 >/dev/null; [ -z "$ISLAND_COPY" ] || rm -rf "$ISLAND_COPY"; exit 143' TERM INT
  ISLAND_COPY=$(mktemp -d "$LOGDIR/island_${name}.XXXX") || return 1
  mkdir -p "$ISLAND_COPY/apps" "$ISLAND_COPY/config" "$ISLAND_COPY/tests" "$ISLAND_COPY/seed"
  cp mix.lock "$ISLAND_COPY/"; ln -s "$ROOT/deps" "$ISLAND_COPY/deps"; ln -s "$ROOT/_tools" "$ISLAND_COPY/_tools"
  [ -d wit ] && cp -R wit "$ISLAND_COPY/"
  for a in "$@"; do
    case "$a" in
      apps/*) cp -R "$a" "$ISLAND_COPY/apps/" ;;
      config/*) cp "$a" "$ISLAND_COPY/config/" ;;
      tests/*) cp -R "$a" "$ISLAND_COPY/tests/" ;;
      seed/*) cp -R "$a" "$ISLAND_COPY/seed/" ;;
    esac
  done
  ISLAND_LOG="$LOGDIR/islands.$name.log"
  : > "$ISLAND_LOG"
  if cd "$ISLAND_COPY/apps/$name"; then
    island_phase "$name" compile mix compile --warnings-as-errors &&
      island_phase "$name" test mix test
    status=$?
  else
    status=1
  fi
  cd "$ROOT" || :
  echo "$name=$status" >> "$LOGDIR/islands.summary"
  rm -rf "$ISLAND_COPY"
  return "$status"
}

ISLAND_PIDS=()
# Stops the island subshells: each stops its own sessions on TERM, within
# the step grace plus 15 s.
stop_islands() {
  local p n=0 live
  for p in ${ISLAND_PIDS[@]+"${ISLAND_PIDS[@]}"}; do kill -TERM "$p" 2>/dev/null || :; done
  while [ "$n" -lt 2000 ]; do
    live=
    for p in ${ISLAND_PIDS[@]+"${ISLAND_PIDS[@]}"}; do if leg_alive "$p"; then live=1; fi; done
    [ -n "$live" ] || break
    sleep 0.1
    n=$((n + 1))
  done
  for p in ${ISLAND_PIDS[@]+"${ISLAND_PIDS[@]}"}; do
    kill -KILL "$p" 2>/dev/null || :
    wait "$p" 2>/dev/null || :
  done
  ISLAND_PIDS=()
}

# Runs the islands named, one argument word list each, concurrently.
run_islands() {
  local status=0 p spec
  ISLAND_PIDS=()
  for spec in "$@"; do
    # The function runs as the asynchronous subshell itself, so its pid is
    # the one its trap is on.
    # shellcheck disable=SC2086
    island $spec &
    ISLAND_PIDS+=("$!")
  done
  for p in "${ISLAND_PIDS[@]}"; do wait "$p" || status=1; done
  ISLAND_PIDS=()
  return "$status"
}

leg_islands() {
  local status=0
  # The islands run their own SQLite suites: they start once the static
  # leg's partitions have exited, so no two SQLite suites share the
  # machine's I/O. Run concurrently, the control-plane and athanor tests
  # of the suite and of the arca island answered `:database_error` on the
  # SQLite writer's wait on one gate in three.
  await_leg islands static || return
  # Under --close the PostgreSQL suite's partitions follow the SQLite
  # suite's; the islands' own SQLite writers waited out its I/O too.
  if $CLOSE; then await_leg islands postgres || return; fi
  run_islands 'prima apps/prima tests/fixtures seed/components' \
    'arca apps/prima apps/arca config/database_choice.exs' \
    'sanctum apps/prima apps/arca apps/sanctum config/database_choice.exs' || status=1
  if $CLOSE; then
    run_islands 'locus apps/prima apps/locus tests/fixtures config/locus_runtime.exs' || status=1
  fi
  # An island runs in a subshell of the leg, so its refused start comes
  # back through the summary.
  [ -n "$REFUSED" ] || REFUSED=$(sed -n 's/^[a-z_]*_refused=//p' "$LOGDIR/islands.summary" 2>/dev/null | head -n 1)
  return $status
}

# The cluster suite runs alone: real members on their own database, after
# every other leg's pools have exited.
leg_cluster() {
  export MIX_BUILD_PATH=_build/test_pg
  step cluster cluster env CYFR_DATABASE_URL=postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test \
    CYFR_CLUSTER_DATABASE_URL=postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test \
    CYFR_SECRET_KEY_BASE="${CYFR_SECRET_KEY_BASE:-JspnK9M8XQE1HFBRZWuzJqK8ZX8ITp5vPQ6MJv2RmFfKpGr2fEhAgSf3UqBT5xTk}" \
    scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors --only cluster apps/cyfr/test/cluster
}

# Whether process $1 exists and has not exited. A leg is the gate's child,
# not its peer's, so a dead leg stays a zombie until the gate reaps it.
leg_alive() {
  local s
  case ${1:-} in ''|0*|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  s=${s//[[:space:]]/}
  case $s in ''|Z*|X*) return 1 ;; esac
  return 0
}

# A leg that must follow another waits for the marker the other leaves
# when it ends, whatever its status. It watches the other leg's pid, which
# the gate gives it: a leg that ended without leaving its marker fails the
# waiting one within a second or two, and so does a wait longer than the
# sum of the other leg's step deadlines.
await_leg() {
  local leg=$1 other=$2 pid limit=0 name start=$SECONDS
  case $other in
    static) pid=$PEER_STATIC ;;
    postgres) pid=$PEER_POSTGRES ;;
  esac
  for name in $(steps_of "$other"); do limit=$((limit + $(deadline_for "$name"))); done
  until [ -e "$LOGDIR/$other.done" ]; do
    if ! leg_alive "$pid"; then
      [ ! -e "$LOGDIR/$other.done" ] || return 0
      echo "==> $leg: the $other leg ended without its marker" >&2
      echo "await_$other=1" >> "$LOGDIR/$leg.summary"
      return 1
    fi
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      echo "==> $leg: the $other leg did not end within ${limit}s" >&2
      echo "await_$other=124" >> "$LOGDIR/$leg.summary"
      return 1
    fi
    sleep 1
  done
}

# Sourced (tests/commit-gate-test.sh reads pg_selection), the script
# defines its functions and runs nothing.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")" || exit 1
ROOT=$(dirname "$(dirname "$SELF")")
. "$ROOT/scripts/lib/contain.sh" || exit 69

# --- a leg: "$SELF" --leg NAME, started by the gate ------------------------
# It takes the gate's parsed options and its peers' pids from the
# environment, prepares nothing and writes no terminal line. Stopped, it
# stops its own steps first.
if [ "${1:-}" = --leg ]; then
  leg=${2:-}
  case "$leg" in static|postgres|vocab|islands|cluster) ;; *) echo "unknown leg: $leg" >&2; exit 64 ;; esac
  LOGDIR=${GATE_LEG_LOGDIR:-}; PARTS=${GATE_LEG_PARTS:-}; CLOSE=${GATE_LEG_CLOSE:-}
  PEER_STATIC=${GATE_LEG_PEER_STATIC:-}; PEER_POSTGRES=${GATE_LEG_PEER_POSTGRES:-}
  PG_PATHS=()
  if [ -n "${GATE_LEG_PG_PATHS:-}" ]; then
    while IFS= read -r p; do PG_PATHS+=("$p"); done <<<"$GATE_LEG_PG_PATHS"
  fi
  unset GATE_LEG_LOGDIR GATE_LEG_PARTS GATE_LEG_CLOSE GATE_LEG_PEER_STATIC GATE_LEG_PEER_POSTGRES GATE_LEG_PG_PATHS
  case "$CLOSE" in true|false) ;; *) echo 'a leg runs only under the gate' >&2; exit 64 ;; esac
  [ -d "$LOGDIR" ] || { echo 'a leg runs only under the gate' >&2; exit 64; }
  cd "$ROOT" || exit 1
  unset MIX_BUILD_PATH
  # The gate stops a leg with TERM, through contain_stop_all. A leg starts
  # as an asynchronous child with SIGINT ignored, so it cannot trap INT.
  leg_signal() {
    trap '' TERM
    stop_islands
    contain_stop_all 180 >/dev/null || :
    exit 143
  }
  trap leg_signal TERM
  "leg_$leg"; s=$?
  : > "$LOGDIR/$leg.done"
  if [ -n "$REFUSED" ]; then exit "$REFUSED"; fi
  [ "$s" -eq 0 ] || exit 1
  exit 0
fi

# --- the gate ----------------------------------------------------------------
LOGDIR=""; PARTS=""; CLOSE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -l) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; LOGDIR=$2; shift 2 ;;
    -n) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; PARTS=$2; shift 2 ;;
    --close) CLOSE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
PG_PATHS=("$@")

if [ "${HEAVY_CHECK_HELD:-}" = scoped ]; then
  echo 'the commit gate takes the whole host: run it under scripts/heavy-check.sh without -s' >&2
  exit 64
fi

# The terminal lines are heavy-check's when it runs the gate.
TERMINAL=false
[ -n "${HEAVY_CHECK_HELD:-}" ] || TERMINAL=true
STARTED=false
OWNER=false
# Set only by the last line of a run that passed. Bash runs the EXIT trap
# for a signal the gate does not trap (USR1, say) with $? at 0 and then
# dies of it, so 0 is reported only for a run that reached its end with 0.
COMPLETED=false
# Every exit path after option parsing: whatever still runs is stopped,
# the registry swept and removed when this gate made it, and the
# `_EXIT=` line written last.
gate_exit() {
  local s=$?
  trap - EXIT
  trap '' INT TERM HUP
  [ "$s" -ne 0 ] || $COMPLETED || s=1
  contain_stop_all 240 || { [ "$s" -ne 0 ] || s=1; }
  if $OWNER; then
    contain_sweep_registry 240 || { [ "$s" -ne 0 ] || s=1; }
    rm -f "$CONTAIN_REGISTRY"
  fi
  if $STARTED; then printf '\n_EXIT=%s %s\n' "$$" "$s"; fi
  exit "$s"
}
gate_signal() {
  trap '' INT TERM HUP
  echo '==> gate interrupted, stopping its legs' >&2
  contain_stop_all 240 >/dev/null || :
  exit "$1"
}
trap gate_exit EXIT
trap 'gate_signal 130' INT
trap 'gate_signal 143' TERM
trap 'gate_signal 129' HUP
if $TERMINAL; then echo "_START=$$"; STARTED=true; fi

case "${GATE_STEP_DEADLINE:-1}" in
  ''|*[!0-9]*|0*|???????*) echo 'GATE_STEP_DEADLINE must be positive decimal seconds, at most six digits' >&2; exit 64 ;;
esac

# A log directory holds this run's logs alone, so the verdict reads
# nothing an earlier run left.
refuse_logdir() { echo "the log directory $LOGDIR $1: -l takes a new or empty directory" >&2; exit 64; }
if [ -n "$LOGDIR" ]; then
  if [ -e "$LOGDIR" ] && [ ! -d "$LOGDIR" ]; then
    refuse_logdir 'is not a directory'
  elif [ -d "$LOGDIR" ]; then
    entries=$(ls -A -- "$LOGDIR" 2>/dev/null) || refuse_logdir 'cannot be read'
    [ -z "$entries" ] || refuse_logdir 'is not empty'
    [ -w "$LOGDIR" ] && [ -x "$LOGDIR" ] || refuse_logdir 'is not writable'
  else
    mkdir -p -- "$LOGDIR" 2>/dev/null || refuse_logdir 'cannot be created'
  fi
else
  LOGDIR=$(mktemp -d /tmp/cyfr-gate.XXXXXX) || exit 1
fi
LOGDIR=$(cd "$LOGDIR" && pwd -P) || exit 1

if [ -z "$PARTS" ]; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
  if [ "$cores" -ge 16 ]; then PARTS=8; else PARTS=4; fi
fi

cd "$ROOT" || exit 1
# Run directly, the gate is the outermost wrapper and owns the registry of
# every session started under it; under heavy-check it appends to
# heavy-check's.
if [ -z "${CONTAIN_REGISTRY:-}" ]; then
  contain_registry_create || exit 1
  OWNER=true
fi

# The pinned validator the dev and test configurations name
# (`_tools/wasm-tools`), before any leg compiles or tests.
s=0
if contain_start -g 30 scripts/wasm-tools.sh install _tools >/dev/null </dev/null; then
  contain_wait "$CONTAIN_PID" 300 30 || s=$?
else
  s=$?
  echo '==> the pinned wasm-tools install could not start' >&2
  exit "$s"
fi
if [ "$s" -ne 0 ]; then
  echo "==> the pinned wasm-tools could not be installed (scripts/wasm-tools.sh): $s" >&2
  [ "$s" -eq 124 ] && exit 124
  exit 1
fi
start=$SECONDS
echo "==> commit gate at $(git rev-parse --short HEAD) ($(uname -s)), logs in $LOGDIR"

export GATE_LEG_LOGDIR="$LOGDIR" GATE_LEG_PARTS="$PARTS" GATE_LEG_CLOSE="$CLOSE"
GATE_LEG_PG_PATHS=$(printf '%s\n' ${PG_PATHS[@]+"${PG_PATHS[@]}"})
export GATE_LEG_PG_PATHS
# Each leg leads a session of its own under a watchdog with the leg
# grace, which outlasts a leg's stop of its current step.
start_leg() {
  local s=0
  contain_start -g 240 "$SELF" --leg "$1" </dev/null || s=$?
  if [ "$s" -ne 0 ]; then
    echo "==> the $1 leg could not start" >&2
    exit "$s"
  fi
  eval "pid_$1=\$CONTAIN_PID"
}
# The islands compile from deps the static leg's compile has already
# fetched; nothing else is shared, so the four legs run at once.
start_leg static
export GATE_LEG_PEER_STATIC="$pid_static"
start_leg postgres
export GATE_LEG_PEER_POSTGRES="$pid_postgres"
start_leg vocab
start_leg islands

status=0
# A leg's exit status is 0, 1, or the status contain_start refused one of
# its steps with, which the gate keeps.
leg_result() {
  local leg=$1 s=0 pid_var="pid_$1" r
  contain_wait "${!pid_var}" 0 240 || s=$?
  if [ -n "$CONTAIN_SURVIVORS" ]; then
    echo "==> the $leg leg left $CONTAIN_SURVIVORS after KILL" >&2
    [ "$s" -ne 0 ] || s=1
  fi
  if [ "$s" -eq 0 ]; then
    r=ok
  else
    r=FAILED
    case "$s:$status" in
      64:0|64:1|69:0|69:1|69:64) status=$s ;;
      *) [ "$status" -ne 0 ] || status=1 ;;
    esac
  fi
  printf '==> %-9s %-7s %s\n' "$leg" "$r" "$(tr '\n' ' ' < "$LOGDIR/$leg.summary" 2>/dev/null)"
}
for leg in static postgres vocab islands; do leg_result "$leg"; done
if $CLOSE; then
  start_leg cluster
  leg_result cluster
fi
for leg in static postgres cluster islands; do
  [ -f "$LOGDIR/$leg.summary" ] || continue
  while IFS='=' read -r name _; do
    case "$leg.$name" in
      postgres.pg_selection)
        printf '    postgres.pg_selection: %s paths handed to the runner, listed in postgres.pg_selection.txt\n' \
          "$(sed -n 's/^pg_selection=//p' "$LOGDIR/postgres.summary")"
        continue ;;
      static.sqlite_suite|postgres.pg_tests|postgres.pg_suite|cluster.cluster) f="$LOGDIR/$leg.$name.log" ;;
      islands.*_survivors) continue ;;
      islands.*) f="$LOGDIR/islands.$name.log" ;;
      *) continue ;;
    esac
    [ -f "$f" ] || continue
    printf '    %s: %s\n' "$leg.$name" "$(grep -E '^(Result:|==> [0-9]+ partitions|==> coverage)' "$f" | tr '\n' ' ')"
  done < "$LOGDIR/$leg.summary"
done
if [ "$status" -eq 0 ]; then verdict=passed; else verdict=FAILED; fi
echo "==> gate $verdict in $((SECONDS - start))s, logs in $LOGDIR"
[ "$status" -ne 0 ] || COMPLETED=true
exit "$status"
