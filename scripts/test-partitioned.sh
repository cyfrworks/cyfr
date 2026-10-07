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
# Mix keeps its build lock under TMPDIR, and every Mix process here runs
# under a partition's own, so the lock excludes no one. It is off because
# Mix through 1.20.4 can take it into a wait that never ends: the second
# take in a fresh lock directory, on the port the first one had, reads its
# own port back as the holder's and waits for itself to let go.
export MIX_OS_CONCURRENCY_LOCK=0
# The cores this run may size itself to: the machine's, or the share a
# caller that runs several at once gives it (scripts/heavy-check.sh -s).
if [ -n "${CYFR_TEST_CORES:-}" ]; then
  case "$CYFR_TEST_CORES" in *[!0-9]*|0*) echo 'CYFR_TEST_CORES must be a positive decimal integer' >&2; exit 64 ;; esac
  [ "${#CYFR_TEST_CORES}" -le 4 ] || { echo 'CYFR_TEST_CORES is at most 9999' >&2; exit 64; }
  cores=$CYFR_TEST_CORES
else
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
fi
per=$(( cores / PARTITIONS )); [ "$per" -lt 2 ] && per=2
# Dirty I/O schedulers are threads that block inside the SQLite driver while
# a writer waits out a busy quantum; scaling them down with the partition
# count lets waiters crowd out the holder they wait for. They stay wide.
# No scheduler busy-waits: on a loaded host, a partition's idle scheduler
# threads spinning for work compete with the one that has it, and pinned to
# two CPUs beside six busy loops a partition's throughput fell as low as
# 1.5% of what it had on them unloaded (about 63% with busy-wait off). A
# runner VM outside a release makes the same choice (`Opus.Release`).
export ERL_FLAGS="+S ${per}:${per} +SDcpu ${per} +SDio 16 +sbwt none +sbwtdcpu none +sbwtdio none"
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

# Diagnostic publication is best effort and cannot change the primary result.
# The private roster is acquired once; partial failed acquisition is discarded.
warning_roster_state=uninitialized
report_warning_evidence() {
  local diagnostic_pid log=$1 roster="$out_dir/warning-source-roster" summary="$out_dir/warning-summary"
  if [ "$warning_roster_state" = uninitialized ]; then
    if ! { : >"$roster"; } 2>/dev/null; then
      warning_roster_state=failed
    else
      git -C "$checkout" ls-files 2>/dev/null >"$roster" &
      diagnostic_pid=$!
      pids[${#pids[@]}]=$diagnostic_pid
      if wait "$diagnostic_pid"; then
        warning_roster_state=available
      elif { : >"$roster"; } 2>/dev/null; then
        warning_roster_state=unavailable
      else
        warning_roster_state=failed
      fi
    fi
  fi
  if [ "$warning_roster_state" = failed ]; then
    echo '    warning evidence: unavailable'
    return 0
  fi
  if [ "$warning_roster_state" = unavailable ]; then
    echo '    warning evidence: source roster unavailable'
  fi
  # ENVIRON preserves literal checkout bytes instead of AWK -v escapes.
  # Buffer output so a failed projection publishes no partial diagnostic text.
  { LC_ALL=C CYFR_WARNING_CHECKOUT="$checkout" awk '
BEGIN { checkout = ENVIRON["CYFR_WARNING_CHECKOUT"] }
function safe_source(path) {
  return path != "" && path !~ /^\/|^\.\// &&
    path !~ /(^|\/)\.\.?($|\/)/ && path !~ /[^A-Za-z0-9_.\/-]/ &&
    path ~ /\.(ex|exs|erl|hrl)$/
}
function spelling(key, canonical) {
  if (key in mapped) {
    if (mapped[key] != canonical) ambiguous[key] = 1
  } else mapped[key] = canonical
}
function tracked(path, alias) {
  if (!safe_source(path) || path in source) return
  source[path] = 1
  spelling(path, path)
  if (path ~ /^apps\/[^/]+\/(lib|test)\//) {
    alias = path
    sub(/^apps\/[^/]+\//, "", alias)
    spelling(alias, path)
  }
}
function normalize(path, prefix) {
  if (path ~ /^\.\//) path = substr(path, 3)
  prefix = checkout "/"
  if (index(path, prefix) == 1) {
    path = substr(path, length(prefix) + 1)
    return safe_source(path) && path in source ? path : ""
  }
  if (!safe_source(path) || path in ambiguous) return ""
  return (path in mapped) ? mapped[path] : ""
}
function flush(key) {
  if (!active) return
  if (emitted < 40) {
    printf "    warning evidence: log line %d; %s (message omitted)\n", header_line, kind
    for (j = 1; j <= locations; j++) printf "      location: %s\n", location[j]
    if (locations == 0) print "      location: unavailable or outside source allowlist"
    if (location_omitted) printf "      additional locations omitted: %d\n", location_omitted
    emitted++
  } else omitted++
  active = 0
  locations = 0
  location_omitted = 0
  for (key in location) delete location[key]
  for (key in seen) delete seen[key]
}
function add_location(raw, path, rest, n, a, pos) {
  if (kind == "test-loader file classification") {
    path = normalize(raw)
    pos = path
  } else {
    n = split(raw, a, ":")
    if (n < 2 || a[2] !~ /^[1-9][0-9]*$/ || length(a[2]) > 7) return
    path = normalize(a[1])
    pos = path ":" a[2]
    if (a[3] ~ /^[+-]?[0-9]+$/) {
      if (a[3] !~ /^[1-9][0-9]*$/ || length(a[3]) > 7) return
      pos = pos ":" a[3]
    }
  }
  if (!path || pos in seen) return
  seen[pos] = 1
  if (locations < 4) location[++locations] = pos
  else location_omitted++
}
FILENAME == ARGV[1] { tracked($0); next }
{
  raw = $0
  # Every physical line consumes the window, including rejected input.
  if (active && ++distance > 32) flush()
  if (length(raw) > 1024) {
    oversized++
    next
  }
  # Strip only ANSI SGR color, not arbitrary terminal controls.
  gsub(/\033\[[0-9;]*m/, "", raw)
  if (raw ~ /[\001-\010\013-\037\177]/) { controls++; next }
  if (raw ~ /^ *warning:($| )/) {
    flush()
    headers++
    active = 1
    header_line = FNR
    distance = 0
    kind = "diagnostic header"
    if (raw == "warning: the following files do not match any of the configured `:test_load_filters` / `:test_ignore_filters`:") kind = "test-loader file classification"
    next
  }
  if (!active) next
  if (raw ~ /^[ \t]*└─ /) {
    sub(/^[ \t]*└─ /, "", raw)
    add_location(raw)
  } else if (raw ~ /^  [A-Za-z0-9_.\/-]+:[1-9][0-9]*:/) {
    sub(/^  /, "", raw)
    add_location(raw)
  } else if (kind == "test-loader file classification" && raw ~ /^[A-Za-z0-9_.\/-]+\.(exs?|erl|hrl)$/) {
    add_location(raw)
  }
}
END {
  flush()
  printf "    warning evidence summary: headers=%d emitted=%d omitted=%d oversized-lines=%d control-lines=%d\n", headers, emitted, omitted, oversized, controls
}
' "$roster" "$log" >"$summary"; } 2>/dev/null &
  diagnostic_pid=$!
  pids[${#pids[@]}]=$diagnostic_pid
  if wait "$diagnostic_pid"; then
    cat "$summary" 2>/dev/null || echo '    warning evidence: unavailable'
  else
    echo '    warning evidence: unavailable'
  fi
  return 0
}

echo "==> compiling once ($ADAPTER, $PARTITIONS partitions, $per schedulers each)"
(load_partition_env 1 || exit 1; exec mix compile --warnings-as-errors) >"$out_dir/compile.log" 2>&1 &
pids=($!)
if ! wait "${pids[0]}"; then
  echo "compile failed; see $out_dir/compile.log" >&2
  report_warning_evidence "$out_dir/compile.log"
  exit 1
fi
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

# Mix splits test files among partitions per umbrella application, round
# robin over each application's sorted files, and refuses a partition to
# which the paths named for an application give no file: that partition
# exits 1 with no test failed. So every existing path under apps/<app>/ is
# counted with its application's test files (`*_test.exs` under a
# directory, a named file as it is), and a partition is given only the
# paths of the applications with at least as many files as its number. A
# partition left with none of the named paths is not started. Any other
# argument (an option, its value, a missing path, a path outside an
# application) reaches every started partition unchanged, and so does an
# application's path that holds no test file, so a mistyped path still
# fails as it would.
args=("$@")
arg_app=()
app_names=()
app_counts=()
line_suffix='^(.+):[0-9]+$'
for ((j=0; j<${#args[@]}; j++)); do
  arg_app[$j]=
  path=${args[$j]}
  case "$path" in -*) continue ;; esac
  while [[ $path =~ $line_suffix ]]; do path=${BASH_REMATCH[1]}; done
  path=${path#./}
  case "$path" in "$checkout"/*) path=${path#"$checkout"/} ;; esac
  case "$path" in apps/*/?*) ;; *) continue ;; esac
  [ -e "$path" ] || continue
  app=${path#apps/}
  app=${app%%/*}
  arg_app[$j]=$app
  # Mix's wildcard skips dot-entries; a named file counts whatever its name.
  if [ -d "$path" ]; then
    find "$path" -mindepth 1 -name '.*' -prune -o -type f -name '*_test.exs' -print
  else
    printf '%s\n' "$path"
  fi >>"$out_dir/files-$app"
done
for ((j=0; j<${#args[@]}; j++)); do
  [ -n "${arg_app[$j]}" ] || continue
  known=false
  for ((k=0; k<${#app_names[@]}; k++)); do
    [ "${app_names[$k]}" = "${arg_app[$j]}" ] && known=true
  done
  [ "$known" = true ] && continue
  app_names[${#app_names[@]}]=${arg_app[$j]}
  app_counts[${#app_counts[@]}]=$(sort -u "$out_dir/files-${arg_app[$j]}" | wc -l | tr -d ' ')
done
app_count() {
  local k
  for ((k=0; k<${#app_names[@]}; k++)); do
    if [ "${app_names[$k]}" = "$1" ]; then echo "${app_counts[$k]}"; return; fi
  done
}
# Fills part_args with partition $1's arguments; fails when paths were
# named and none of them is its.
partition_args() {
  local i=$1 j count named=false own=false
  part_args=()
  for ((j=0; j<${#args[@]}; j++)); do
    if [ -n "${arg_app[$j]}" ]; then
      named=true
      count=$(app_count "${arg_app[$j]}")
      if [ "$count" -ne 0 ] && [ "$count" -lt "$i" ]; then continue; fi
      own=true
    fi
    part_args[${#part_args[@]}]=${args[$j]}
  done
  [ "$named" = false ] || [ "$own" = true ]
}

start=$SECONDS
started=()
partition_pid=()
skipped=0
for ((i=1; i<=PARTITIONS; i++)); do
  if ! partition_args "$i"; then
    started[$i]=false
    skipped=$((skipped + 1))
    continue
  fi
  started[$i]=true
  run_partition "$i" ${part_args[@]+"${part_args[@]}"} >"$out_dir/p$i.log" 2>&1 &
  partition_pid[$i]=$!
  pids[${#pids[@]}]=$!
done
status=0
exits=()
for ((i=1; i<=PARTITIONS; i++)); do
  [ "${started[$i]}" = true ] || continue
  if wait "${partition_pid[$i]}"; then exits[$i]=0; else exits[$i]=$?; status=1; fi
done
for ((i=1; i<=PARTITIONS; i++)); do
  printf '==> partition %s/%s\n' "$i" "$PARTITIONS"
  if [ "${started[$i]}" != true ]; then
    echo '    not started: no test file of the named paths falls to it'
    continue
  fi
  grep -E '^(Finished in|Result:|[[:space:]]+[0-9]+\) test)' "$out_dir/p$i.log" | head -20 || :
  if ! grep -q '^Result:' "$out_dir/p$i.log"; then
    echo '    NO RESULT — partition did not report'
    status=1
  fi
  # A partition that ended non-zero says why here, since its log stays on
  # the machine that ran it: every line of its last hundred that is not a
  # progress dot, a result or a routine log line.
  if [ "${exits[$i]}" != 0 ]; then
    printf '    partition exited %s; its account:\n' "${exits[$i]}"
    report_warning_evidence "$out_dir/p$i.log"
    # The ownership watch's verdict and each new line it kept, wherever
    # they fell in the log.
    grep -nE 'OwnershipError line\(s\) were logged|^-- NEW' "$out_dir/p$i.log" | sed 's/^/    | /' || :
    grep -nE -A3 '^-- NEW' "$out_dir/p$i.log" | grep -vE '^--$' | sed 's/^/    | /' || :
    # Each failure's own block: the test, its file and line, the assertion
    # and its stack, which the tail below may not reach when logged lines
    # follow it. Without this a failure on a runner whose log is gone can
    # be named but not read.
    grep -nE -A30 '^[[:space:]]+[0-9]+\) test' "$out_dir/p$i.log" \
      | grep -vE '^--$|^[0-9]+-[[:space:]]*$' | head -n 240 | sed 's/^/    | /' || :
    tail -n 100 "$out_dir/p$i.log" \
      | grep -vE '^[[:space:]]*$|^\.+$|^Result:|^Finished in|\[(info|debug)\]' \
      | tail -n 40 | sed 's/^/    | /' || :
  fi
done
if [ "$skipped" -gt 0 ]; then
  echo "==> $PARTITIONS partitions ($skipped not started: no test file of the named paths falls to them), $ADAPTER, $((SECONDS - start))s wall, exit $status"
else
  echo "==> $PARTITIONS partitions, $ADAPTER, $((SECONDS - start))s wall, exit $status"
fi
exit "$status"
