#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# Run isolated OS partitions: scripts/test-partitioned.sh [-n N] [-a sqlite|postgres] [paths and Mix arguments]
#
# One partition hands its Mix arguments to `mix test` unchanged. More than
# one gives each partition an explicit list of the test files the named
# paths hold (all of the suite's when none is named), as `mix test` would
# load them: largest first, each to the partition with the smallest running
# total of weights from scripts/test-partition-weights.tsv (CYFR_TEST_WEIGHTS
# names another table; a file the table lacks weighs its median). A
# partition left with no file is not started.
#
# Stdout begins `_START=<pid>` and ends `_EXIT=<pid> <status>`, unless the
# heavy-check that runs it (HEAVY_CHECK_HELD) writes them. The status is 0
# passed, 1 a check failed, 64 usage, 69 a missing prerequisite, 130 INT,
# 143 TERM. Every child runs contained (scripts/lib/contain.sh), so none
# outlives the run, even when the runner itself is killed.
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
case "$ADAPTER" in sqlite|postgres) ;; *) echo 'adapter must be sqlite or postgres' >&2; exit 64 ;; esac

held=${HEAVY_CHECK_HELD:-}
[ -n "$held" ] || echo "_START=$$"

out_dir=
registry_owned=false
finishing=false
started=()
# none: no partition started; pending: started, not yet merged; running;
# done; failed.
merge_state=none
weights_table=
weights_required=false
group_status=()
group_pid=()

# Stops every child, drops the partitions' databases, and writes the
# terminal line with the status the runner exits with. A run stopped before
# its failures records were merged leaves the canonical record as it was:
# its partitions never reached their ends, so they have nothing to add.
finish() {
  local result=$? i drops=
  trap - EXIT
  trap '' INT TERM
  finishing=true
  if declare -F contain_stop_all >/dev/null; then
    # The partitions first, all at once; the drops depend on them.
    if ! contain_stop_all 30; then
      echo "==> processes survived KILL: $CONTAIN_SURVIVORS" >&2
      result=1
    fi
    case "$merge_state" in
      pending) echo '==> the failures record was left unmerged: the run stopped before its partitions ended' >&2 ;;
      running)
        echo '==> the failures record merge did not complete; the canonical record was left as it was' >&2
        [ "$result" != 0 ] || result=1 ;;
    esac
    if [ -n "$out_dir" ]; then
      for ((i=1; i<=PARTITIONS; i++)); do
        if [ -f "$out_dir/p$i/database-created" ]; then drops="$drops $i"; fi
      done
      if [ -n "$drops" ]; then
        # shellcheck disable=SC2086
        if ! group_wait 45 10 drop_partition $drops; then
          echo "==> a database cleanup left processes that survived KILL: $CONTAIN_SURVIVORS" >&2
          result=1
        fi
        for i in $drops; do
          if [ "${group_status[$i]}" != 0 ]; then
            echo "partition $i database cleanup failed; see $out_dir/cleanup-p$i.log" >&2
            result=1
          fi
        done
      fi
    fi
  fi
  if [ -n "$out_dir" ]; then
    for ((i=1; i<=PARTITIONS; i++)); do
      if [ -f "$out_dir/p$i/database-create-pending" ]; then
        echo "partition $i database creation has an uncertain outcome; inspect $out_dir/p$i/database-name; no unreceipted database was dropped" >&2
        result=1
      fi
      # The disposable database URL goes whatever its drop did.
      rm -f "$out_dir/p$i.env" || result=1
    done
    if [ "$result" -eq 0 ]; then
      rm -rf "$out_dir" || { echo "temporary resource cleanup failed: $out_dir" >&2; result=1; }
    fi
    if [ "$result" -ne 0 ]; then echo "==> logs and disposable resources kept: $out_dir" >&2; fi
  fi
  if [ "$registry_owned" = true ]; then
    if ! contain_sweep_registry 30; then
      echo "==> processes survived KILL: $CONTAIN_SURVIVORS" >&2
      result=1
    fi
    rm -f "$CONTAIN_REGISTRY"
  fi
  # The newline keeps the line whole after output that ended without one.
  [ -n "$held" ] || printf '\n_EXIT=%s %s\n' "$$" "$result"
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

script_dir=$(cd "$(dirname "$0")" && pwd) || exit 1
# shellcheck source=lib/contain.sh
. "$script_dir/lib/contain.sh" || exit 69
helper="$script_dir/test-partition-env.exs"
checkout=$(pwd -P) || exit 1

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
# The cores this run may size itself to: the machine's, or the share a
# caller that runs several at once gives it (scripts/heavy-check.sh -s).
if [ -n "${CYFR_TEST_CORES:-}" ]; then
  case "$CYFR_TEST_CORES" in *[!0-9]*|0*) echo 'CYFR_TEST_CORES must be a positive decimal integer' >&2; exit 64 ;; esac
  [ "${#CYFR_TEST_CORES}" -le 4 ] || { echo 'CYFR_TEST_CORES is at most 9999' >&2; exit 64; }
  cores=$CYFR_TEST_CORES
else
  cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
fi
# Each partition holds one of containment's 64 watchdog slots while it
# runs, and its database drop another once the partitions' are free.
if [ "${#PARTITIONS}" -gt 2 ] || [ "$PARTITIONS" -gt 32 ]; then
  echo 'at most 32 partitions are supported' >&2; exit 64
fi
if [ "$held" = scoped ] && [ "$PARTITIONS" -gt 1 ]; then
  echo 'a scoped check runs one partition: -n 1' >&2; exit 64
fi

# The Mix arguments: which are test paths, and the options the runner
# reads. A switch Mix gives a value takes the next argument (Mix's own
# grammar: `mix help test`); after a bare `--` every argument is a path.
args=("$@")
path_index=()
failed=false
stale=false
selects=false
warnings_as_errors=false
value_switches=' --export-coverage --max-cases --max-failures --max-requires --include --exclude --seed --name-pattern -n --only --timeout --formatter --slowest --slowest-modules --partitions --profile-require --exit-status --repeat-until-failure '
expect_value=false
paths_only=false
for ((j=0; j<${#args[@]}; j++)); do
  argument=${args[$j]}
  if [ "$expect_value" = true ]; then expect_value=false; continue; fi
  if [ "$paths_only" = false ]; then
    switch=
    case "$argument" in
      --) paths_only=true; continue ;;
      -*=*) switch=${argument%%=*} ;;
      -?*) switch=$argument
        case "$value_switches" in *" $argument "*) expect_value=true ;; esac ;;
    esac
    if [ -n "$switch" ]; then
      case "$switch" in
        --failed) failed=true ;;
        --stale) stale=true ;;
        --only|--name-pattern|-n) selects=true ;;
        --warnings-as-errors) warnings_as_errors=true ;;
      esac
      continue
    fi
  fi
  path_index[${#path_index[@]}]=$j
done
if [ "$stale" = true ] && [ "$PARTITIONS" -gt 1 ]; then
  echo '--stale runs one partition: its manifest cannot be merged across partitions' >&2; exit 64
fi
line_suffix='^(.+):[0-9]+$'
for j in ${path_index[@]+"${path_index[@]}"}; do
  path=${args[$j]}
  while [[ $path =~ $line_suffix ]]; do path=${BASH_REMATCH[1]}; done
  [ -e "$path" ] || { echo "no such test path: ${args[$j]}" >&2; exit 64; }
done
if [ "$PARTITIONS" -gt 1 ]; then
  if [ -n "${CYFR_TEST_WEIGHTS+set}" ]; then
    [ -n "$CYFR_TEST_WEIGHTS" ] || { echo 'CYFR_TEST_WEIGHTS names no file' >&2; exit 64; }
    weights_table=$CYFR_TEST_WEIGHTS
    weights_required=true
  else
    weights_table="$script_dir/test-partition-weights.tsv"
  fi
fi

if [ -z "${MIX_BUILD_PATH:-}" ] && [ "$ADAPTER" = postgres ]; then export MIX_BUILD_PATH=_build/test_pg; fi
export CYFR_DATABASE="$ADAPTER" MIX_ENV=test CYFR_TEST_PARTITION_ENV_LIBRARY=0
# Mix keeps its build lock under TMPDIR, and every Mix process here runs
# under a partition's own, so the lock excludes no one. It is off because
# Mix through 1.20.4 can take it into a wait that never ends: the second
# take in a fresh lock directory, on the port the first one had, reads its
# own port back as the holder's and waits for itself to let go.
export MIX_OS_CONCURRENCY_LOCK=0
per=$(( cores / PARTITIONS )); [ "$per" -lt 2 ] && per=2
compile_cores=$cores; [ "$compile_cores" -le 1024 ] || compile_cores=1024
# Dirty I/O schedulers are threads that block inside the SQLite driver while
# a writer waits out a busy quantum; scaling them down with the partition
# count lets waiters crowd out the holder they wait for. They stay wide.
# No scheduler busy-waits: on a loaded host, a partition's idle scheduler
# threads spinning for work compete with the one that has it, and pinned to
# two CPUs beside six busy loops a partition's throughput fell as low as
# 1.5% of what it had on them unloaded (about 63% with busy-wait off). A
# runner VM outside a release makes the same choice (`Locus.Runtime.Release`).
# The compile runs alone and takes every core; a partition takes its share.
erl_common='+SDio 16 +sbwt none +sbwtdcpu none +sbwtdio none'
partition_flags="+S ${per}:${per} +SDcpu ${per} $erl_common"
compile_flags="+S ${compile_cores}:${compile_cores} +SDcpu ${compile_cores} $erl_common"
export ERL_FLAGS="$partition_flags"
umask 077

if [ -z "${CONTAIN_REGISTRY:-}" ]; then
  contain_registry_create || exit 1
  registry_owned=true
fi

# --- the contained commands ------------------------------------------------
# Each runs as `bash -c` in a session of its own (contain_start takes an
# executable, never a function), with these definitions and the run's
# variables, and opens its own log.

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

check_weights() { exec elixir "$helper" weights "$weights_table" "$weights_required"; }
prepare_run() { exec elixir "$helper" prepare "$out_dir" "$checkout" "$PARTITIONS" "$ADAPTER" "$cluster"; }
seed_failures() { exec elixir "$helper" failures-seed "$out_dir" "$PARTITIONS"; }
merge_records() { exec elixir "$helper" failures-merge "$out_dir" "$PARTITIONS" "$@"; }
# The pinned validator the dev and test configurations name
# (`_tools/wasm-tools`), which the suite's applications check as they start.
install_tools() { exec "$script_dir/wasm-tools.sh" install "$script_dir/../_tools" >/dev/null; }
compile_build() {
  exec >"$out_dir/compile.log" 2>&1
  load_partition_env 1 || exit 1
  export ERL_FLAGS="$compile_flags"
  exec mix compile --warnings-as-errors
}
assign_files() {
  exec >"$out_dir/assign.log" 2>&1
  load_partition_env 1 || exit 1
  exec mix run --no-start --no-compile "$helper" assign "$out_dir" "$PARTITIONS" \
    "$weights_table" "$weights_required" "$failed" -- "$@"
}
create_partition() {
  exec >>"$out_dir/p$1.log" 2>&1
  load_partition_env "$1" || exit 1
  mix run --no-start --no-compile "$helper" create || exit 1
  valid_receipt "$1" || { echo "partition $1 creation has no valid ownership receipt"; exit 1; }
}
run_partition() {
  local i=$1
  shift
  exec >>"$out_dir/p$i.log" 2>&1
  load_partition_env "$i" || exit 1
  export ERL_FLAGS="$partition_flags"
  # "$@" handles an empty argument list even under Bash 3.2 + nounset.
  exec mix test --no-compile "$@"
}
drop_partition() {
  exec >"$out_dir/cleanup-p$1.log" 2>&1
  load_partition_env "$1" || exit 1
  valid_receipt "$1" || exit 1
  mix run --no-start --no-compile "$helper" drop || exit 1
  [ ! -e "$out_dir/p$1/database-created" ] && [ ! -e "$out_dir/p$1/database-create-pending" ]
}
read_roster() { exec git -C "$checkout" ls-files >"$1" 2>/dev/null; }
project_warnings() {
  # ENVIRON preserves literal checkout bytes instead of AWK -v escapes.
  export LC_ALL=C CYFR_WARNING_CHECKOUT="$checkout"
  exec awk "$1" "$2" "$3" >"$4" 2>/dev/null
}

# Starts FUNCTION ARGS... contained, with stop grace GRACE: contained GRACE
# FUNCTION ARGS... sets CONTAIN_PID. A refusal of contain_start ends the
# run with its status (69: no setsid or perl), except during cleanup.
contained() {
  local grace=$1 status=0
  shift
  contain_start -g "$grace" "$BASH" -c "set -uo pipefail
$(declare -p out_dir checkout helper script_dir ADAPTER PARTITIONS cluster failed \
  partition_flags compile_flags weights_table weights_required)
$(declare -f load_partition_env valid_receipt "$1")
$1 \"\$@\"" "$1" "${@:2}" || status=$?
  if [ "$status" != 0 ]; then
    [ "$finishing" = true ] || exit "$status"
    return "$status"
  fi
}

# contained_wait DEADLINE GRACE LABEL FUNCTION ARGS...: runs it contained
# and returns its status; 124 when it was stopped at DEADLINE seconds, and
# 1 when anything of it survived KILL.
contained_wait() {
  local deadline=$1 grace=$2 label=$3 status=0
  shift 3
  contained "$grace" "$@" || return
  contain_wait "$CONTAIN_PID" "$deadline" "$grace" || status=$?
  if [ "$status" = 124 ]; then echo "$label did not end within ${deadline}s and was stopped" >&2; fi
  if [ -n "$CONTAIN_SURVIVORS" ]; then
    echo "$label left processes that survived KILL: $CONTAIN_SURVIVORS" >&2
    [ "$status" != 0 ] || status=1
  fi
  return "$status"
}

# Whether a process exists and has not exited; a zombie has exited.
leader_alive() {
  local s
  if read -r s 2>/dev/null <"/proc/$1/stat"; then
    s=${s##*) }
    case $s in Z*|X*|x*) return 1 ;; esac
    return 0
  fi
  s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case ${s// /} in ''|Z*|X*) return 1 ;; esac
}

# group_wait DEADLINE GRACE FUNCTION I...: runs FUNCTION I for every I at
# once, contained, and sets group_status[I]. The deadline is the group's,
# not each one's: the stragglers are stopped together at DEADLINE seconds
# (status 124), so the group ends within DEADLINE + GRACE + 15 s however
# many it holds. Returns 1 when anything survived KILL.
group_wait() {
  local deadline=$1 grace=$2 fn=$3 i end live
  shift 3
  for i in "$@"; do
    group_pid[$i]=
    if contained "$grace" "$fn" "$i"; then group_pid[$i]=$CONTAIN_PID; else group_status[$i]=$?; fi
  done
  end=$((SECONDS + deadline))
  while :; do
    live=false
    for i in "$@"; do
      if [ -n "${group_pid[$i]}" ] && leader_alive "${group_pid[$i]}"; then live=true; fi
    done
    [ "$live" = true ] && [ "$SECONDS" -lt "$end" ] || break
    sleep 0.1
  done
  for i in "$@"; do
    [ -n "${group_pid[$i]}" ] || continue
    if leader_alive "${group_pid[$i]}"; then
      group_status[$i]=124
    else
      wait "${group_pid[$i]}"
      group_status[$i]=$?
    fi
  done
  contain_stop_all "$grace"
}

# Folds every started partition's failures record into the canonical one,
# which the helper replaces whole, by a rename.
merge_failures() {
  local i list=
  merge_state=running
  for ((i=1; i<=PARTITIONS; i++)); do
    if [ "${started[$i]:-false}" = true ]; then list="$list $i"; fi
  done
  # shellcheck disable=SC2086
  if ! contained_wait 120 30 'the failures record merge' merge_records $list; then
    merge_state=failed
    echo 'the failures record could not be merged; `--failed` may rerun the wrong tests' >&2
    return 1
  fi
  merge_state=done
}

# --- the run -----------------------------------------------------------------

if [ "$PARTITIONS" -gt 1 ]; then
  status=0
  contained_wait 120 30 'the weights table check' check_weights || status=$?
  case "$status" in 0) ;; 64) exit 64 ;; *) echo 'the weights table could not be checked' >&2; exit 1 ;; esac
fi

# A run its runner could not clean up (SIGKILLed) keeps its directory and
# the disposable database URLs in its p*.env files; a finished run removes
# those files whatever its result.
name_stopped_runs() {
  local directory pid
  for directory in /tmp/cyfr-t.*; do
    [ -d "$directory" ] && [ -O "$directory" ] || continue
    set -- "$directory"/p*.env
    [ -e "$1" ] || continue
    pid=$(cat "$directory/runner-pid" 2>/dev/null) || pid=
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
    echo "==> a stopped run kept its directory and its partitions' disposable database URLs: $directory" >&2
  done
}
name_stopped_runs

# UNIX socket paths have a small fixed ceiling on macOS. Do not nest under
# the inherited TMPDIR (which may already consume most of that ceiling), and
# canonicalize /tmp's symlink so storage paths have one spelling.
out_dir=$(mktemp -d /tmp/cyfr-t.XXXXXX) || exit 1
out_dir=$(cd "$out_dir" && pwd -P) || exit 1
printf '%s\n' "$$" >"$out_dir/runner-pid" || exit 1

contained_wait 120 30 'the partition preparation' prepare_run || exit 1
# Validate every output before even compiling. A successful helper exit alone
# is insufficient: a disabled or broken helper might have done nothing.
for ((i=1; i<=PARTITIONS; i++)); do
  (load_partition_env "$i") || exit 1
done
contained_wait 120 30 'the failures record seed' seed_failures ||
  { echo 'the failures record could not be seeded' >&2; exit 1; }

# Diagnostic publication is best effort and cannot change the primary result.
# The private roster is acquired once; partial failed acquisition is discarded.
warning_roster_state=uninitialized
warning_program=$(cat <<'AWK'
BEGIN {
  checkout = ENVIRON["CYFR_WARNING_CHECKOUT"]
  # How many lines below its header a diagnostic names its location. A
  # type warning prints the inferred type of each value it names first,
  # a struct one field to a line, so its footer can fall a hundred lines
  # down.
  window = 512
}
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
  if (active && ++distance > window) flush()
  # ExUnit writes its progress marks (".", "*", "?") to stdout and ends no
  # line with them, and the compiler writes a diagnostic to stderr, so a
  # header can follow a run of marks on their line. The run is not counted
  # against the bound and is read past only to find a header.
  marks = match(raw, /^[.*?]+/) ? RLENGTH : 0
  if (length(raw) - marks > 1024) {
    oversized++
    next
  }
  # Strip only ANSI SGR color, not arbitrary terminal controls.
  gsub(/\033\[[0-9;]*m/, "", raw)
  if (raw ~ /[\001-\010\013-\037\177]/) { controls++; next }
  header = raw
  sub(/^[.*?]+/, "", header)
  if (header ~ /^ *warning:($| )/) {
    flush()
    headers++
    active = 1
    header_line = FNR
    distance = 0
    kind = "diagnostic header"
    if (header == "warning: the following files do not match any of the configured `:test_load_filters` / `:test_ignore_filters`:") kind = "test-loader file classification"
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
AWK
)
report_warning_evidence() {
  local log=$1 roster="$out_dir/warning-source-roster" summary="$out_dir/warning-summary"
  if [ "$warning_roster_state" = uninitialized ]; then
    if ! { : >"$roster"; } 2>/dev/null; then
      warning_roster_state=failed
    elif contained_wait 120 10 'the source roster' read_roster "$roster" 2>/dev/null; then
      warning_roster_state=available
    elif { : >"$roster"; } 2>/dev/null; then
      warning_roster_state=unavailable
    else
      warning_roster_state=failed
    fi
  fi
  if [ "$warning_roster_state" = failed ]; then
    echo '    warning evidence: unavailable'
    return 0
  fi
  if [ "$warning_roster_state" = unavailable ]; then
    echo '    warning evidence: source roster unavailable'
  fi
  # Buffer output so a failed projection publishes no partial diagnostic text.
  if contained_wait 120 10 'the warning projection' project_warnings "$warning_program" "$roster" "$log" "$summary" 2>/dev/null; then
    cat "$summary" 2>/dev/null || echo '    warning evidence: unavailable'
  else
    echo '    warning evidence: unavailable'
  fi
  return 0
}

contained_wait 300 30 'the wasm-tools install' install_tools ||
  { echo "the pinned wasm-tools could not be installed (scripts/wasm-tools.sh)" >&2; exit 1; }

echo "==> compiling once ($ADAPTER, $PARTITIONS partitions, $per schedulers each)"
if ! contained_wait 1800 30 'the compile' compile_build; then
  echo "compile failed; see $out_dir/compile.log" >&2
  report_warning_evidence "$out_dir/compile.log"
  exit 1
fi

# Each partition's Mix arguments: all of them with one partition; with
# more, every argument but the paths, then the partition's own files.
selection=run
if [ "$PARTITIONS" -gt 1 ]; then
  names=()
  for j in ${path_index[@]+"${path_index[@]}"}; do names[${#names[@]}]=${args[$j]}; done
  status=0
  contained_wait 600 30 'the test file assignment' assign_files ${names[@]+"${names[@]}"} || status=$?
  case "$status" in
    0|2|3|4) ;;
    *) echo "the test files could not be assigned; see $out_dir/assign.log" >&2; exit 1 ;;
  esac
  # Explicit file lists bypass Mix's own check of the files under a test
  # path that neither filter classifies, so it is made here.
  if [ -s "$out_dir/assign/misnamed" ]; then
    echo '==> test files that neither the load nor the ignore filters classify:'
    report_warning_evidence "$out_dir/assign.log"
    if [ "$warnings_as_errors" = true ]; then
      echo '==> refused under --warnings-as-errors, as Mix refuses them'
      exit 1
    fi
  fi
  case "$status" in
    2) echo '==> no test file in the named paths'; exit 1 ;;
    3) selection=empty ;;
    4)
      echo '==> named paths outside every umbrella application:'
      sed 's/^/    /' "$out_dir/assign/outside"
      exit 1 ;;
  esac
  # A failures record of :all reruns the whole suite: Mix would read it per
  # application in one VM and run only the first application's files.
  record_all=false
  [ ! -e "$out_dir/assign/record-all" ] || record_all=true
  rest=()
  for ((j=0; j<${#args[@]}; j++)); do
    case " ${path_index[*]-} " in *" $j "*) continue ;; esac
    if [ "$record_all" = true ] && [ "${args[$j]}" = --failed ]; then continue; fi
    rest[${#rest[@]}]=${args[$j]}
  done
fi

skipped=0
for ((i=1; i<=PARTITIONS; i++)); do
  started[$i]=false
  if [ "$selection" = empty ]; then
    skipped=$((skipped + 1))
  elif [ "$PARTITIONS" -gt 1 ] && [ ! -s "$out_dir/assign/p$i" ]; then
    skipped=$((skipped + 1))
  else
    started[$i]=true
  fi
done

if [ "$ADAPTER" = postgres ]; then
  creates=
  for ((i=1; i<=PARTITIONS; i++)); do
    if [ "${started[$i]}" = true ]; then creates="$creates $i"; fi
  done
  if [ -n "$creates" ]; then
    # shellcheck disable=SC2086
    group_wait 120 30 create_partition $creates || exit 1
    for i in $creates; do
      if [ "${group_status[$i]}" != 0 ]; then
        echo "partition $i database creation failed; see $out_dir/p$i.log" >&2
        exit 1
      fi
    done
  fi
fi

start=$SECONDS
partition_pid=()
merge_state=pending
for ((i=1; i<=PARTITIONS; i++)); do
  [ "${started[$i]}" = true ] || continue
  if [ "$PARTITIONS" -gt 1 ]; then
    part_args=(${rest[@]+"${rest[@]}"})
    while IFS= read -r -d '' unit; do part_args[${#part_args[@]}]=$unit; done <"$out_dir/assign/p$i"
  else
    part_args=(${args[@]+"${args[@]}"})
  fi
  contained 30 run_partition "$i" ${part_args[@]+"${part_args[@]}"}
  partition_pid[$i]=$CONTAIN_PID
done
status=0
exits=()
for ((i=1; i<=PARTITIONS; i++)); do
  [ "${started[$i]}" = true ] || continue
  exits[$i]=0
  contain_wait "${partition_pid[$i]}" 0 30 || exits[$i]=$?
  [ "${exits[$i]}" = 0 ] || status=1
  if [ -n "$CONTAIN_SURVIVORS" ]; then
    echo "==> partition $i left processes that survived KILL: $CONTAIN_SURVIVORS" >&2
    status=1
  fi
done
merge_failures || status=1

# A partition with no Result line ran an empty --failed or --stale
# selection only when Mix said so and said nothing that means otherwise.
empty_selection() {
  { [ "$failed" = true ] || [ "$stale" = true ]; } &&
    grep -qxE 'There are no tests to run|No stale tests' "$1" &&
    ! grep -qE 'Paths given to "mix test" did not match|The --only option was given|\*\* \(' "$1"
}

ran_test=false
any_started=false
if [ "$selection" = empty ]; then echo '==> no partition started: the failures record names no test'; fi
for ((i=1; i<=PARTITIONS; i++)); do
  printf '==> partition %s/%s\n' "$i" "$PARTITIONS"
  if [ "${started[$i]}" != true ]; then
    echo '    not started: no test file falls to it'
    continue
  fi
  any_started=true
  grep -E '^(Finished in|Result:|[[:space:]]+[0-9]+\) test)' "$out_dir/p$i.log" | head -20 || :
  if grep '^Result:' "$out_dir/p$i.log" | grep -qv '^Result: 0 tests'; then ran_test=true; fi
  if ! grep -q '^Result:' "$out_dir/p$i.log"; then
    if [ "${exits[$i]}" = 0 ] && empty_selection "$out_dir/p$i.log"; then
      echo '    no test to run: the --failed or --stale selection is empty'
    else
      echo '    NO RESULT — partition did not report'
      status=1
    fi
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
# In an umbrella Mix only says so, and exits 0, when --only or
# --name-pattern selected nothing.
if [ "$selects" = true ] && [ "$any_started" = true ] && [ "$ran_test" = false ]; then
  echo '==> the --only or --name-pattern selection ran no test'
  status=1
fi
if [ "$skipped" -gt 0 ]; then
  echo "==> $PARTITIONS partitions ($skipped not started: no test file falls to them), $ADAPTER, $((SECONDS - start))s wall, exit $status"
else
  echo "==> $PARTITIONS partitions, $ADAPTER, $((SECONDS - start))s wall, exit $status"
fi
exit "$status"
