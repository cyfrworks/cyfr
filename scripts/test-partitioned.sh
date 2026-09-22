#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run the suite as N operating-system partitions.
#
# Most of this suite is `async: false`, so ExUnit runs it on one scheduler
# however many cores the machine has. Partitions are separate OS processes
# with separate global state, so the synchronous phase runs in parallel
# across them. Each partition gets its own database (config/test.exs keys
# both adapters by MIX_TEST_PARTITION); storage roots and listeners are
# already per-process.
#
#   scripts/test-partitioned.sh                      # 4 partitions, sqlite
#   scripts/test-partitioned.sh -n 8 -a postgres
#   scripts/test-partitioned.sh -n 2 apps/cyfr/test/arca
set -uo pipefail

PARTITIONS=4
ADAPTER=sqlite

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--partitions) PARTITIONS="$2"; shift 2 ;;
    -a|--adapter) ADAPTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '6,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 64 ;;
    *) break ;;
  esac
done
PATHS=("$@")

case "$ADAPTER" in
  sqlite|postgres) ;;
  *) echo "adapter must be sqlite or postgres" >&2; exit 64 ;;
esac

# The plan gives the Postgres run its own build path so the two adapters do
# not invalidate each other's build between runs.
if [ -z "${MIX_BUILD_PATH:-}" ] && [ "$ADAPTER" = postgres ]; then
  export MIX_BUILD_PATH=_build/test_pg
fi
export CYFR_DATABASE="$ADAPTER"
export MIX_ENV=test

cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
per=$(( cores / PARTITIONS )); [ "$per" -lt 2 ] && per=2
export ERL_FLAGS="+S ${per}:${per} +SDcpu ${per} +SDio ${per}"

# Partitions share one build directory, so they must not race to write it.
# One compile up front; each partition then only reads.
echo "==> compiling once ($ADAPTER, ${PARTITIONS} partitions, ${per} schedulers each)"
if ! mix compile --warnings-as-errors; then
  echo "compile failed; not starting partitions" >&2
  exit 1
fi

out_dir=$(mktemp -d "${TMPDIR:-/tmp}/cyfr-partitions.XXXXXX")
trap 'rm -rf "$out_dir"' EXIT

start=$SECONDS
pids=()
for i in $(seq 1 "$PARTITIONS"); do
  MIX_TEST_PARTITION="$i" \
    mix test --partitions "$PARTITIONS" --no-compile "${PATHS[@]}" \
      > "$out_dir/p$i.log" 2>&1 &
  pids+=($!)
done

status=0
for i in $(seq 1 "$PARTITIONS"); do
  wait "${pids[$((i-1))]}" || status=1
done
elapsed=$(( SECONDS - start ))

echo
for i in $(seq 1 "$PARTITIONS"); do
  printf '==> partition %s/%s\n' "$i" "$PARTITIONS"
  grep -E '^(Finished in|Result:|\s+[0-9]+\) test)' "$out_dir/p$i.log" | head -20
  # A partition that died without a Result line is a failure, not a silence.
  if ! grep -qE '^Result:' "$out_dir/p$i.log"; then
    echo "    NO RESULT — partition did not report; last lines:"
    tail -5 "$out_dir/p$i.log" | sed 's/^/    /'
    status=1
  fi
  echo
done

echo "==> ${PARTITIONS} partitions, ${ADAPTER}, ${elapsed}s wall, exit ${status}"
[ "$status" -ne 0 ] && echo "==> logs kept: $(cp -R "$out_dir" "${TMPDIR:-/tmp}/cyfr-partitions-last" && echo "${TMPDIR:-/tmp}/cyfr-partitions-last")"
exit "$status"
