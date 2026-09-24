#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# Run isolated OS partitions: scripts/test-partitioned.sh [-n N] [-a sqlite|postgres] [paths and Mix arguments]
set -uo pipefail

PARTITIONS=4
ADAPTER=sqlite
usage() { echo "usage: $0 [-n N] [-a sqlite|postgres] [--] [test paths and Mix arguments]"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--partitions|-a|--adapter)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 64; }
      case "$1" in -n|--partitions) PARTITIONS=$2 ;; *) ADAPTER=$2 ;; esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case "$PARTITIONS" in ''|*[!0-9]*|0*) echo 'partitions must be a positive decimal integer' >&2; exit 64 ;; esac
# Bound arithmetic and accidental process explosions, before a shell integer conversion.
[ "${#PARTITIONS}" -le 4 ] && [ "$PARTITIONS" -le 1024 ] || { echo 'at most 1024 partitions are supported' >&2; exit 64; }
case "$ADAPTER" in sqlite|postgres) ;; *) echo 'adapter must be sqlite or postgres' >&2; exit 64 ;; esac

cluster=false
previous=
for argument in "$@"; do
  case "$argument" in test/cluster|test/cluster/*|*/test/cluster|*/test/cluster/*|--only=cluster|--only=cluster:*|--include=cluster|--include=cluster:*) cluster=true ;; esac
  case "$previous:$argument" in --only:cluster|--only:cluster:*|--include:cluster|--include:cluster:*) cluster=true ;; esac
  previous=$argument
done
if [ "$cluster" = true ] && { [ "$PARTITIONS" -ne 1 ] || [ "$ADAPTER" != postgres ]; }; then
  echo 'the cluster suite requires -n 1 -a postgres' >&2; exit 64
fi

script_dir=$(cd "$(dirname "$0")" && pwd) || exit 1
helper="$script_dir/test-partition-env.exs"
checkout=$(pwd -P)
if [ -z "${MIX_BUILD_PATH:-}" ] && [ "$ADAPTER" = postgres ]; then export MIX_BUILD_PATH=_build/test_pg; fi
export CYFR_DATABASE="$ADAPTER" MIX_ENV=test CYFR_TEST_PARTITION_ENV_LIBRARY=0
cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
per=$(( cores / PARTITIONS )); [ "$per" -lt 2 ] && per=2
# Dirty I/O schedulers are threads that block inside the SQLite driver while
# a writer waits out a busy quantum; scaling them down with the partition
# count lets waiters crowd out the holder they wait for. They stay wide.
export ERL_FLAGS="+S ${per}:${per} +SDcpu ${per} +SDio 16"
umask 077
# UNIX socket paths have a small fixed ceiling on macOS. Do not nest under
# the inherited TMPDIR (which may already consume most of that ceiling), and
# canonicalize /tmp's symlink so storage paths have one spelling.
out_dir=$(mktemp -d /tmp/cyfr-t.XXXXXX) || exit 1
out_dir=$(cd "$out_dir" && pwd -P) || exit 1
pids=()
# Each background job and its descendants have a process group. This also
# covers Mix's children when cancellation arrives while waiting or compiling.
set -m

load_partition_env() {
  local i=$1 expected_root="$out_dir/p$1" expected_database url_path
  [ -s "$out_dir/p$i.env" ] || { echo "partition $i environment is missing or empty" >&2; return 1; }
  # A missing assignment must never inherit the caller's database or another
  # partition's identity. Source failures are fatal even without errexit.
  unset MIX_TEST_PARTITION CYFR_TEST_RUN_ROOT CYFR_DATABASE_URL CYFR_CLUSTER_DATABASE_URL TMPDIR TMP TEMP
  if ! source "$out_dir/p$i.env" >/dev/null 2>&1; then
    echo "partition $i environment could not be loaded" >&2; return 1
  fi
  export CYFR_DATABASE="$ADAPTER" MIX_ENV=test CYFR_TEST_PARTITION_ENV_LIBRARY=0
  if [ "${MIX_TEST_PARTITION:-}" != "$i" ] ||
     [ "${CYFR_TEST_RUN_ROOT:-}" != "$expected_root" ] ||
     [ "${TMPDIR:-}" != "$expected_root/tmp" ] ||
     [ "${TMP:-}" != "$expected_root/tmp" ] ||
     [ "${TEMP:-}" != "$expected_root/tmp" ] ||
     [ ! -d "$expected_root/tmp" ] ||
     [ "$(cd "$expected_root/tmp" && pwd -P)" != "$expected_root/tmp" ]; then
    echo "partition $i resource identity is invalid" >&2; return 1
  fi
  if [ "$ADAPTER" = postgres ]; then
    [ -s "$expected_root/database-name" ] || { echo "partition $i database identity is missing" >&2; return 1; }
    expected_database=$(cat "$expected_root/database-name") || return 1
    if ! printf '%s\n' "$expected_database" | LC_ALL=C grep -Eq "^[a-zA-Z0-9_]+_[a-f0-9]{32}_p${i}$"; then
      echo "partition $i database identity is invalid" >&2; return 1
    fi
    [ "${#expected_database}" -le 63 ] || return 1
    [ -n "${CYFR_DATABASE_URL:-}" ] &&
      [ "${CYFR_DATABASE_URL:-}" = "${CYFR_CLUSTER_DATABASE_URL:-}" ] || {
        echo "partition $i connection identity is missing or inconsistent" >&2; return 1;
      }
    case "$CYFR_DATABASE_URL" in postgres://*|postgresql://*) ;; *) return 1 ;; esac
    url_path=${CYFR_DATABASE_URL%%\?*}
    [ "${url_path##*/}" = "$expected_database" ] || {
      echo "partition $i connection names a different database" >&2; return 1;
    }
  elif [ -n "${CYFR_DATABASE_URL:-}${CYFR_CLUSTER_DATABASE_URL:-}" ]; then
    echo "SQLite partition $i inherited a PostgreSQL connection" >&2; return 1
  fi
}

valid_receipt() {
  local resource="$out_dir/p$1"
  [ -s "$resource/database-created" ] &&
    [ ! -e "$resource/database-create-pending" ] &&
    cmp -s "$resource/database-created" "$resource/database-name"
}

stop_children() {
  local pid attempts=0
  for pid in ${pids[@]+"${pids[@]}"}; do kill -TERM -- "-$pid" 2>/dev/null || :; done
  while [ "$attempts" -lt 30 ]; do
    local live=false
    for pid in ${pids[@]+"${pids[@]}"}; do kill -0 -- "-$pid" 2>/dev/null && live=true; done
    [ "$live" = false ] && break
    sleep 0.1
    attempts=$((attempts + 1))
  done
  for pid in ${pids[@]+"${pids[@]}"}; do
    kill -KILL -- "-$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  done
  pids=()
}

finish() {
  local result=$? i
  trap - EXIT
  trap '' INT TERM
  stop_children
  for ((i=1; i<=PARTITIONS; i++)); do
    if [ -f "$out_dir/p$i/database-created" ]; then
      if ! (
        load_partition_env "$i" || exit 1
        valid_receipt "$i" || exit 1
        mix run --no-start --no-compile "$helper" drop || exit 1
        [ ! -e "$out_dir/p$i/database-created" ] && [ ! -e "$out_dir/p$i/database-create-pending" ]
      ) >"$out_dir/cleanup-p$i.log" 2>&1; then
        echo "partition $i database cleanup failed; see $out_dir/cleanup-p$i.log" >&2
        result=1
      fi
    fi
    if [ -f "$out_dir/p$i/database-create-pending" ]; then
      echo "partition $i database creation has an uncertain outcome; inspect $out_dir/p$i/database-name; no unreceipted database was dropped" >&2
      result=1
    fi
    rm -f "$out_dir/p$i.env" || result=1
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$out_dir" || { echo "temporary resource cleanup failed: $out_dir" >&2; result=1; }
  fi
  if [ "$result" -ne 0 ]; then echo "==> logs and disposable resources kept: $out_dir" >&2; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! elixir "$helper" prepare "$out_dir" "$checkout" "$PARTITIONS" "$ADAPTER" "$cluster"; then exit 1; fi
# Validate every output before even compiling. A successful helper exit alone
# is insufficient: a disabled or broken helper might have done nothing.
for ((i=1; i<=PARTITIONS; i++)); do
  (load_partition_env "$i") || exit 1
done

echo "==> compiling once ($ADAPTER, $PARTITIONS partitions, $per schedulers each)"
(load_partition_env 1 || exit 1; exec mix compile --warnings-as-errors) >"$out_dir/compile.log" 2>&1 &
pids=($!)
if ! wait "${pids[0]}"; then echo "compile failed; see $out_dir/compile.log" >&2; exit 1; fi
stop_children

run_partition() {
  local i=$1
  shift
  load_partition_env "$i" || return 1
  if [ "$ADAPTER" = postgres ]; then
    mix run --no-start --no-compile "$helper" create || return 1
    valid_receipt "$i" || { echo "partition $i creation has no valid ownership receipt" >&2; return 1; }
  fi
  # "$@" handles an empty argument list even under Bash 3.2 + nounset.
  mix test --partitions "$PARTITIONS" --no-compile "$@"
}
start=$SECONDS
for ((i=1; i<=PARTITIONS; i++)); do
  run_partition "$i" "$@" >"$out_dir/p$i.log" 2>&1 &
  pids[${#pids[@]}]=$!
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
for ((i=1; i<=PARTITIONS; i++)); do
  printf '==> partition %s/%s\n' "$i" "$PARTITIONS"
  grep -E '^(Finished in|Result:|[[:space:]]+[0-9]+\) test)' "$out_dir/p$i.log" | head -20 || :
  if ! grep -q '^Result:' "$out_dir/p$i.log"; then
    echo '    NO RESULT — partition did not report'
    status=1
  fi
done
echo "==> $PARTITIONS partitions, $ADAPTER, $((SECONDS - start))s wall, exit $status"
exit "$status"
