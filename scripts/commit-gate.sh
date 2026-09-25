#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# The per-commit gate: scripts/commit-gate.sh [-l LOGDIR] [-n N] [--close] [-- PostgreSQL test paths]
#
# Runs the checks a commit must pass as concurrent legs, one log per leg
# under LOGDIR, and ends with one `_EXIT=<status>` line on stdout, which
# scripts/await-task.sh waits for. Legs:
#   static    SQLite test compile (warnings as errors), credo, ops.gen.cli
#             --check, dialyzer, then the full SQLite suite in N partitions
#   postgres  PostgreSQL test compile, then the given test paths (default:
#             the storage set) in one partition; with --close the whole
#             suite in N partitions and the cluster suite
#   vocab     the CI vocabulary job's own script, read from test.yml
#   islands   prima, arca and sanctum compiled and tested from a copy that
#             holds only what CI gives them; opus and locus with --close
# With --close the static leg also forces a rebuild on both adapters and
# compiles the SQLite dev target. Image suites and the benchmark are not
# part of this gate.
set -uo pipefail

LOGDIR=""; PARTS=4; CLOSE=false
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
[ "${#PG_PATHS[@]}" -eq 0 ] && PG_PATHS=(apps/arca/test apps/cyfr/test/arca)

ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
cd "$ROOT" || exit 1
[ -n "$LOGDIR" ] || LOGDIR=$(mktemp -d /tmp/cyfr-gate.XXXXXX)
mkdir -p "$LOGDIR"
start=$SECONDS
echo "==> commit gate at $(git rev-parse --short HEAD) ($(uname -s)), logs in $LOGDIR"

# One step: its command runs with its own log, and its status is appended
# to the leg's summary as `name=status`.
step() {
  local leg=$1 name=$2; shift 2
  local log="$LOGDIR/$leg.$name.log" status
  ( "$@" ) > "$log" 2>&1; status=$?
  echo "$name=$status" >> "$LOGDIR/$leg.summary"
  return $status
}

leg_static() {
  step static compile_sqlite_test env CYFR_DATABASE=sqlite MIX_ENV=test mix compile --warnings-as-errors || return 1
  if $CLOSE; then
    step static compile_sqlite_dev env CYFR_DATABASE=sqlite mix compile --warnings-as-errors || return 1
    step static compile_sqlite_force env CYFR_DATABASE=sqlite MIX_ENV=test mix compile --warnings-as-errors --force || return 1
  fi
  step static credo mix credo --only=warning || return 1
  step static opsgen mix ops.gen.cli --check || return 1
  step static dialyzer mix dialyzer || return 1
  step static sqlite_suite scripts/test-partitioned.sh -n "$PARTS" -a sqlite -- --warnings-as-errors || return 1
}

leg_postgres() {
  export MIX_BUILD_PATH=_build/test_pg
  step postgres compile_pg_test env CYFR_DATABASE=postgres MIX_ENV=test mix compile --warnings-as-errors || return 1
  if $CLOSE; then
    step postgres compile_pg_force env CYFR_DATABASE=postgres MIX_ENV=test mix compile --warnings-as-errors --force || return 1
    step postgres pg_suite scripts/test-partitioned.sh -n "$PARTS" -a postgres -- --warnings-as-errors || return 1
    step postgres cluster env CYFR_DATABASE_URL=postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test \
      CYFR_CLUSTER_DATABASE_URL=postgres://cyfr:cyfr@localhost:5432/cyfr_cluster_test \
      CYFR_SECRET_KEY_BASE="${CYFR_SECRET_KEY_BASE:-JspnK9M8XQE1HFBRZWuzJqK8ZX8ITp5vPQ6MJv2RmFfKpGr2fEhAgSf3UqBT5xTk}" \
      scripts/test-partitioned.sh -n 1 -a postgres -- --warnings-as-errors --only cluster apps/cyfr/test/cluster || return 1
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
  ( cd "$isl/apps/$name" && CYFR_DATABASE=sqlite mix compile --warnings-as-errors && CYFR_DATABASE=sqlite mix test ) > "$log" 2>&1
  local status=$?
  echo "$name=$status" >> "$LOGDIR/islands.summary"
  rm -rf "$isl"
  return $status
}

leg_islands() {
  local status=0
  island prima apps/prima tests/fixtures seed/components & local p1=$!
  island arca apps/prima apps/arca config/database_choice.exs & local p2=$!
  island sanctum apps/prima apps/arca apps/sanctum config/database_choice.exs & local p3=$!
  wait $p1 || status=1; wait $p2 || status=1; wait $p3 || status=1
  if $CLOSE; then
    island opus apps/prima apps/opus tests/fixtures & local p4=$!
    island locus apps/prima apps/locus tests/fixtures & local p5=$!
    wait $p4 || status=1; wait $p5 || status=1
  fi
  return $status
}

# The islands compile from deps the static leg's compile has already
# fetched; nothing else is shared, so the four legs run at once.
leg_static & pid_static=$!
leg_postgres & pid_postgres=$!
leg_vocab & pid_vocab=$!
leg_islands & pid_islands=$!

status=0
for leg in static postgres vocab islands; do
  pid_var="pid_$leg"
  if wait "${!pid_var}"; then r=ok; else r=FAILED; status=1; fi
  printf '==> %-9s %-7s %s\n' "$leg" "$r" "$(tr '\n' ' ' < "$LOGDIR/$leg.summary" 2>/dev/null)"
done
for f in "$LOGDIR"/static.sqlite_suite.log "$LOGDIR"/postgres.pg_tests.log "$LOGDIR"/postgres.pg_suite.log "$LOGDIR"/postgres.cluster.log "$LOGDIR"/islands.*.log; do
  [ -f "$f" ] || continue
  printf '    %s: %s\n' "$(basename "$f" .log)" "$(grep -E '^(Result:|==> [0-9]+ partitions)' "$f" | tr '\n' ' ')"
done
if [ "$status" -eq 0 ]; then verdict=passed; else verdict=FAILED; fi
echo "==> gate $verdict in $((SECONDS - start))s, logs in $LOGDIR"
echo "_EXIT=$status"
exit "$status"
