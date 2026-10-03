#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# The per-commit gate: scripts/commit-gate.sh [-l LOGDIR] [-n N] [--close] [-- PostgreSQL test paths]
#
# Runs the checks a commit must pass as concurrent legs, one log per leg
# under LOGDIR, and ends with one `_EXIT=<status>` line on stdout, which
# scripts/await-task.sh waits for. Legs:
#   static    SQLite test compile and forced dev compile (warnings as
#             errors, so every Boundary declaration is checked), format,
#             credo, ops.gen.cli --check, cyfr.gen.configuration_guide
#             --check, dialyzer, then the full SQLite suite in N partitions
#   postgres  PostgreSQL test compile, then the given test paths (default:
#             the storage set) in one partition; with --close the whole
#             suite in N partitions, started once the SQLite suite's
#             partitions have exited (four pools across the adapter jobs)
#   cluster   with --close only, after every other leg: the real-member
#             suite alone on its own database
#   vocab     the CI vocabulary job's own script, read from test.yml
#   islands   prima, arca and sanctum compiled and tested from a copy that
#             holds only what CI gives them, once the SQLite suite's
#             partitions have exited; opus and locus with --close
# With --close the static leg also forces the test rebuild on both
# adapters. Image suites, the S3 suite, the Go checks, the security
# scanners and the benchmark are not part of this gate: a closing record
# names each of those with its own result.
# Without -n a suite runs in eight partitions on a host of sixteen cores
# or more (two schedulers each) and in four on a smaller one. A PostgreSQL
# partition holds twenty connections, so the server allows twenty times
# the count and the cluster suite's besides: 400 on the verification host.
# Every step has a deadline, several times what it takes on a quiet host: a
# step that reaches it is stopped, recorded as `name=124`, and fails its
# leg, so a stalled check ends the gate instead of keeping the host.
# GATE_STEP_DEADLINE=SECONDS gives every step that one deadline.
# Stopping the gate (INT, TERM) stops its legs.
set -uo pipefail

LOGDIR=""; PARTS=""; CLOSE=false
usage() { echo "usage: $0 [-l LOGDIR] [-n N] [--close] [-- PostgreSQL test paths]"; }
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
if [ -z "$PARTS" ]; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
  if [ "$cores" -ge 16 ]; then PARTS=8; else PARTS=4; fi
fi
[ "${#PG_PATHS[@]}" -eq 0 ] && PG_PATHS=(apps/arca/test apps/cyfr/test/arca)

ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
cd "$ROOT" || exit 1
[ -n "$LOGDIR" ] || LOGDIR=$(mktemp -d /tmp/cyfr-gate.XXXXXX)
mkdir -p "$LOGDIR"
# A log directory used before starts without the last run's markers and
# summaries: a leg waits on the one, and the verdict is read from the other.
rm -f "$LOGDIR"/*.done "$LOGDIR"/*.pid "$LOGDIR"/*.summary
start=$SECONDS
echo "==> commit gate at $(git rev-parse --short HEAD) ($(uname -s)), logs in $LOGDIR"

case "${GATE_STEP_DEADLINE:-1}" in ''|*[!0-9]*|0*) echo 'GATE_STEP_DEADLINE must be positive decimal seconds' >&2; exit 64 ;; esac
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
[ -n "$TIMEOUT_BIN" ] || echo '==> no timeout(1) on this host: the steps run without deadlines' >&2

deadline_for() {
  if [ -n "${GATE_STEP_DEADLINE:-}" ]; then echo "$GATE_STEP_DEADLINE"; return; fi
  case "$1" in
    fossils|format|credo|opsgen|confguide|island_compile|island_test) echo 600 ;;
    compile_*|boundary_plants) echo 1200 ;;
    # A first run builds the PLT.
    dialyzer) echo 2400 ;;
    *) echo 1800 ;;
  esac
}

# The command stays in its leg's process group, so stopping the gate still
# reaches it; at the deadline it is asked to stop, and ended a minute later
# if it has not.
bounded() {
  local secs=$1; shift
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" --foreground -k 60 "$secs" "$@"; else "$@"; fi
}

# One step: its command runs with its own log under its deadline, and its
# status is appended to the leg's summary as `name=status`.
step() {
  local leg=$1 name=$2; shift 2
  local log="$LOGDIR/$leg.$name.log" status secs
  secs=$(deadline_for "$name")
  ( bounded "$secs" "$@" ) > "$log" 2>&1; status=$?
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    echo "==> $leg.$name stopped at its ${secs}s deadline" | tee -a "$log" >&2
  fi
  echo "$name=$status" >> "$LOGDIR/$leg.summary"
  return $status
}

leg_static() {
  step static compile_sqlite_test env CYFR_DATABASE=sqlite MIX_ENV=test mix compile --warnings-as-errors || return 1
  # Forced: incremental state can keep a Boundary declaration the tree no
  # longer has, and a plain compile only warns.
  step static compile_sqlite_dev env CYFR_DATABASE=sqlite MIX_ENV=dev mix compile --force --warnings-as-errors || return 1
  if $CLOSE; then
    step static compile_sqlite_force env CYFR_DATABASE=sqlite MIX_ENV=test mix compile --warnings-as-errors --force || return 1
  fi
  step static format mix format --check-formatted || return 1
  step static credo mix credo --only=warning || return 1
  step static opsgen mix ops.gen.cli --check || return 1
  step static confguide mix cyfr.gen.configuration_guide --check || return 1
  step static dialyzer mix dialyzer || return 1
  # The Boundary plants: each writes a forbidden edge into a copy of the tree
  # and force-compiles it, so they run once here and never in the partitions.
  step static boundary_plants env CYFR_DATABASE=sqlite MIX_ENV=test mix test apps/cyfr/test/cyfr/boundaries_test.exs --only boundary_plant || return 1
  step static sqlite_suite scripts/test-partitioned.sh -n "$PARTS" -a sqlite -- --warnings-as-errors || return 1
}

leg_postgres() {
  export MIX_BUILD_PATH=_build/test_pg
  step postgres compile_pg_test env CYFR_DATABASE=postgres MIX_ENV=test mix compile --warnings-as-errors || return 1
  if $CLOSE; then
    step postgres compile_pg_force env CYFR_DATABASE=postgres MIX_ENV=test mix compile --warnings-as-errors --force || return 1
    # One adapter's suite has the host at a time: the PostgreSQL suite's
    # partitions start once the SQLite suite's have exited.
    await_leg postgres static || return 1
    step postgres pg_suite scripts/test-partitioned.sh -n "$PARTS" -a postgres -- --warnings-as-errors || return 1
  else
    step postgres pg_tests scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors "${PG_PATHS[@]}" || return 1
  fi
}

# The vocabulary job's script is CI's, read from the workflow so the two
# cannot drift. macOS git grep -E ignores \b, so there the patterns run
# as PCRE, which reads them the same way.
leg_vocab() {
  local script="$LOGDIR/vocab.sh"
  python3 - .github/workflows/test.yml > "$script" <<'PY' || return 1
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for s in job.get("steps", []):
        if s.get("name") == "Tier A/B fossil patterns must be absent":
            print("set -e"); print(s["run"]); sys.exit(0)
sys.exit("vocabulary step not found in test.yml")
PY
  if [ "$(uname -s)" = Darwin ]; then sed -i '' 's/git grep -InE/git grep -InP/' "$script"; fi
  step vocab fossils bash "$script"
}

# An island is an application compiled and tested from a copy holding only
# what CI copies for it (the copy lists are test.yml's), deps linked in.
# Its build directory is the copy's own and one Mix process at a time
# uses it, so Mix's build lock excludes no one there, and it is off: Mix
# through 1.20.4 can wait forever on a lock it holds itself, the second
# time a fresh lock directory is taken.
island() {
  local name=$1; shift
  local isl log
  isl=$(mktemp -d "$LOGDIR/island_${name}.XXXX") || return 1
  mkdir -p "$isl/apps" "$isl/config" "$isl/tests" "$isl/seed"
  cp mix.lock "$isl/"; ln -s "$ROOT/deps" "$isl/deps"; [ -d wit ] && cp -R wit "$isl/"
  local a
  for a in "$@"; do
    case "$a" in
      apps/*) cp -R "$a" "$isl/apps/" ;;
      config/*) cp "$a" "$isl/config/" ;;
      tests/*) cp -R "$a" "$isl/tests/" ;;
      seed/*) cp -R "$a" "$isl/seed/" ;;
    esac
  done
  log="$LOGDIR/islands.$name.log"
  ( cd "$isl/apps/$name" &&
      bounded "$(deadline_for island_compile)" env CYFR_DATABASE=sqlite MIX_OS_CONCURRENCY_LOCK=0 mix compile --warnings-as-errors &&
      bounded "$(deadline_for island_test)" env CYFR_DATABASE=sqlite MIX_OS_CONCURRENCY_LOCK=0 mix test ) > "$log" 2>&1
  local status=$?
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    echo "==> islands.$name stopped at its deadline" | tee -a "$log" >&2
  fi
  echo "$name=$status" >> "$LOGDIR/islands.summary"
  rm -rf "$isl"
  return $status
}

leg_islands() {
  local status=0
  # The islands run their own SQLite suites: they start once the static
  # leg's partitions have exited, so no two SQLite suites share the
  # machine's I/O. Run concurrently, the control-plane and athanor tests
  # of the suite and of the arca island answered `:database_error` on the
  # SQLite writer's wait on one gate in three.
  await_leg islands static || return 1
  # Under --close the PostgreSQL suite's partitions follow the SQLite
  # suite's; the islands' own SQLite writers waited out its I/O too.
  if $CLOSE; then await_leg islands postgres || return 1; fi
  island prima apps/prima tests/fixtures seed/components & local p1=$!
  island arca apps/prima apps/arca config/database_choice.exs & local p2=$!
  island sanctum apps/prima apps/arca apps/sanctum config/database_choice.exs & local p3=$!
  wait $p1 || status=1; wait $p2 || status=1; wait $p3 || status=1
  if $CLOSE; then
    island opus apps/prima apps/opus tests/fixtures & local p4=$!
    island locus apps/prima apps/locus tests/fixtures config/locus_runtime.exs & local p5=$!
    wait $p4 || status=1; wait $p5 || status=1
  fi
  return $status
}

# The cluster suite runs alone: real members on their own database, after
# every other leg's pools have exited.
leg_cluster() {
  step cluster cluster env CYFR_DATABASE_URL=postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test \
    CYFR_CLUSTER_DATABASE_URL=postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test \
    CYFR_SECRET_KEY_BASE="${CYFR_SECRET_KEY_BASE:-JspnK9M8XQE1HFBRZWuzJqK8ZX8ITp5vPQ6MJv2RmFfKpGr2fEhAgSf3UqBT5xTk}" \
    MIX_BUILD_PATH=_build/test_pg \
    scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors --only cluster apps/cyfr/test/cluster
}

# A leg that must follow another waits for the marker the other leaves
# when it ends, whatever its status. The other's steps are bounded, so the
# marker comes; a leg that was ended without leaving one is noticed by its
# process being gone, and the waiting leg fails instead of waiting on.
await_leg() {
  local leg=$1 other=$2 pid
  until [ -e "$LOGDIR/$other.done" ]; do
    pid=$(cat "$LOGDIR/$other.pid" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && [ ! -e "$LOGDIR/$other.done" ]; then
      echo "==> $leg: the $other leg ended without its marker" >&2
      echo "await_$other=1" >> "$LOGDIR/$leg.summary"
      return 1
    fi
    sleep 2
  done
}

# Stopping the gate stops its legs: each runs in its own process group,
# and the trap ends every group before the gate exits.
leg_pids=()
on_signal() {
  echo "==> gate interrupted, stopping its legs" >&2
  for pid in "${leg_pids[@]}"; do kill -TERM -- "-$pid" 2>/dev/null; done
  for pid in "${leg_pids[@]}"; do wait "$pid" 2>/dev/null; done
  echo "_EXIT=130"
  exit 130
}
trap on_signal INT TERM

# The islands compile from deps the static leg's compile has already
# fetched; nothing else is shared, so the four legs run at once.
run_leg() {
  local leg=$1
  # The inner shell becomes `sh` and reports its parent: the leg's own
  # shell, which is what `await_leg` watches.
  ( (exec sh -c 'echo "$PPID"') > "$LOGDIR/$leg.pid"; "leg_$leg"; s=$?; : > "$LOGDIR/$leg.done"; exit "$s" )
}
# Job control puts each background leg in a process group of its own,
# which is what the trap kills.
set -m
( run_leg static ) & pid_static=$!
( run_leg postgres ) & pid_postgres=$!
( run_leg vocab ) & pid_vocab=$!
( run_leg islands ) & pid_islands=$!
leg_pids=("$pid_static" "$pid_postgres" "$pid_vocab" "$pid_islands")

status=0
for leg in static postgres vocab islands; do
  pid_var="pid_$leg"
  if wait "${!pid_var}"; then r=ok; else r=FAILED; status=1; fi
  printf '==> %-9s %-7s %s\n' "$leg" "$r" "$(tr '\n' ' ' < "$LOGDIR/$leg.summary" 2>/dev/null)"
done
if $CLOSE; then
  ( run_leg cluster ) & pid_cluster=$!
  leg_pids=("$pid_cluster")
  if wait "$pid_cluster"; then r=ok; else r=FAILED; status=1; fi
  printf '==> %-9s %-7s %s\n' cluster "$r" "$(tr '\n' ' ' < "$LOGDIR/cluster.summary" 2>/dev/null)"
fi
for f in "$LOGDIR"/static.sqlite_suite.log "$LOGDIR"/postgres.pg_tests.log "$LOGDIR"/postgres.pg_suite.log "$LOGDIR"/cluster.cluster.log "$LOGDIR"/islands.*.log; do
  [ -f "$f" ] || continue
  printf '    %s: %s\n' "$(basename "$f" .log)" "$(grep -E '^(Result:|==> [0-9]+ partitions)' "$f" | tr '\n' ' ')"
done
if [ "$status" -eq 0 ]; then verdict=passed; else verdict=FAILED; fi
echo "==> gate $verdict in $((SECONDS - start))s, logs in $LOGDIR"
echo "_EXIT=$status"
exit "$status"
