#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/ci/containerd-image-store.sh, run by path
# against shims on PATH, so no daemon is needed and none is touched:
#   docker     answers `docker info --format` as the CLI does over a daemon
#              on the classic or the containerd store, or over none. With
#              no daemon the CLI renders the template over an empty server
#              answer ({{json .DriverStatus}} is null): the runner's CLI 28
#              exits 0, CLI 29 exits 1.
#   systemctl  records each call; a restart brings up the store the case
#              names next.
#   sleep      returns at once, so the wait for a daemon that never comes
#              back is instant.
# The configuration is a scratch file (DOCKER_DAEMON_CONFIG). A docker or
# systemctl call the shims do not model fails the test.
#
# Usage: bash tests/containerd-image-store-test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
switch="$root/scripts/ci/containerd-image-store.sh"
tmp=${TMPDIR:-/tmp}
scratch=$(mktemp -d "${tmp%/}/cyfr-containerd-image-store-test.XXXXXX") || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
trap 'rm -rf "$scratch"' EXIT

command -v jq > /dev/null || { echo "FAIL: jq is not on PATH"; exit 1; }

bin="$scratch/bin"
state="$scratch/state"
config="$scratch/etc/daemon.json"
mkdir -p "$bin"

# The daemon each mode stands for: its version (none when no daemon
# answers), its driver status and the exit of `docker info --format`.
cat > "$bin/docker" << EOF
#!/usr/bin/env bash
state=$(printf '%q' "$state")
EOF
cat >> "$bin/docker" << 'EOF'
case "$(cat "$state/mode")" in
  cli28-down) server= status=null code=0 ;;
  cli29-down) server= status=null code=1 ;;
  classic) server=28.0.4 status='[["Backing Filesystem","extfs"],["Supports d_type","true"]]' code=0 ;;
  containerd) server=28.0.4 status='[["driver-type","io.containerd.snapshotter.v1"]]' code=0 ;;
  *) echo "docker $*" >> "$state/unmodelled"; exit 97 ;;
esac
if [ "$#" -ne 3 ] || [ "$1" != info ] || [ "$2" != --format ]; then
  echo "docker $*" >> "$state/unmodelled"
  exit 97
fi
out=$3
if [ -n "$server" ]; then
  out=${out//'{{if .ServerVersion}}'/}
  out=${out//'{{end}}'/}
else
  out=$(sed -E 's/\{\{if \.ServerVersion\}\}.*\{\{end\}\}//g' <<< "$out")
fi
out=${out//'{{json .DriverStatus}}'/"$status"}
out=${out//'{{.ServerVersion}}'/"$server"}
case "$out" in
  *'{{'* | *'}}'*) echo "docker $*" >> "$state/unmodelled"; exit 97 ;;
esac
printf '%s\n' "$out"
[ -n "$server" ] || echo "Cannot connect to the Docker daemon at unix:///shim.sock. Is the docker daemon running?" >&2
exit "$code"
EOF

cat > "$bin/systemctl" << EOF
#!/usr/bin/env bash
state=$(printf '%q' "$state")
EOF
cat >> "$bin/systemctl" << 'EOF'
echo "$*" >> "$state/systemctl"
if [ "$*" != "restart docker.service" ]; then
  echo "systemctl $*" >> "$state/unmodelled"
  exit 97
fi
[ ! -f "$state/next" ] || mv "$state/next" "$state/mode"
EOF

printf '#!/bin/sh\nexit 0\n' > "$bin/sleep"
chmod +x "$bin/docker" "$bin/systemctl" "$bin/sleep"

failures=0
cases=0
pass() { cases=$((cases + 1)); echo "PASS: $1"; }
fail() {
  cases=$((cases + 1))
  echo "FAIL: $1"
  echo "  exit: $code"
  sed 's/^/  stdout: /' "$scratch/out"
  sed 's/^/  stderr: /' "$scratch/err"
  [ ! -s "$state/systemctl" ] || sed 's/^/  systemctl: /' "$state/systemctl"
  [ ! -f "$config" ] || sed 's/^/  config: /' "$config"
  failures=$((failures + 1))
}

# daemon MODE [NEXT] [CONFIG]: the daemon answers as MODE, a restart
# brings up NEXT, and the configuration file holds CONFIG, or is absent.
daemon() {
  [ ! -s "$state/unmodelled" ] || cp "$state/unmodelled" "$scratch/unmodelled-$cases"
  rm -rf "$state" "${config%/*}"
  mkdir -p "$state"
  echo "$1" > "$state/mode"
  [ -z "${2-}" ] || echo "$2" > "$state/next"
  if [ -n "${3-}" ]; then
    mkdir -p "${config%/*}"
    printf '%s\n' "$3" > "$config"
  fi
}

run() {
  PATH="$bin:$PATH" DOCKER_DAEMON_CONFIG="$config" "$switch" "$@" > "$scratch/out" 2> "$scratch/err"
  code=$?
}

said() { grep -qxF -- "$1" "$scratch/$2"; }
restarts() {
  local n=0
  [ ! -f "$state/systemctl" ] || n=$(grep -c . "$state/systemctl")
  [ "$n" = "$1" ]
}
config_is() { [ -f "$config" ] && [ "$(jq -cS . "$config" 2> /dev/null)" = "$(jq -cS . <<< "$1")" ]; }
check() { if "$@"; then pass "$label"; else fail "$label"; fi; }

no_answer="$switch: the Docker daemon does not answer"
classic="$switch: the Docker daemon uses the classic image store, not the containerd store (io.containerd.snapshotter.v1)"
switched="the Docker daemon uses the containerd image store"

# --- --check ---

label="--check: no daemon, as the runner's CLI 28 answers (null, exit 0), does not answer"
daemon cli28-down
run --check
check eval '[ "$code" = 1 ] && said "$no_answer" err && ! grep -q classic "$scratch/err" && restarts 0'

label="--check: no daemon, as CLI 29 answers (exit 1), does not answer"
daemon cli29-down
run --check
check eval '[ "$code" = 1 ] && said "$no_answer" err && restarts 0'

label="--check: the classic store is refused"
daemon classic
run --check
check eval '[ "$code" = 1 ] && said "$classic" err && restarts 0'

label="--check: the containerd store is accepted"
daemon containerd
run --check
check eval '[ "$code" = 0 ] && said "$switched" out && [ ! -s "$scratch/err" ] && restarts 0'

# --- the switch ---

label="a configuration that is not JSON is refused before the daemon is touched"
daemon classic containerd 'not json'
run
check eval '[ "$code" = 1 ] && said "$switch: $config is not a JSON object" err && restarts 0 &&
  [ "$(cat "$config")" = "not json" ] && [ ! -e "$config.new" ]'

label="the switch sets the store, keeps every other setting and restarts once"
daemon classic containerd '{"log-level": "info", "features": {"containerd-snapshotter": false}}'
run
check eval '[ "$code" = 0 ] && said "$switched" out && restarts 1 && said "restart docker.service" state/systemctl &&
  config_is "{\"log-level\": \"info\", \"features\": {\"containerd-snapshotter\": true}}"'

label="the switch writes the setting alone where there was no configuration"
daemon classic containerd
run
check eval '[ "$code" = 0 ] && said "$switched" out && restarts 1 && config_is "{\"features\": {\"containerd-snapshotter\": true}}"'

label="a daemon already on the containerd store is neither reconfigured nor restarted"
daemon containerd
run
check eval '[ "$code" = 0 ] && said "$switched" out && restarts 0 && [ ! -e "$config" ]'

label="a restart that leaves the classic store fails"
daemon classic
run
check eval '[ "$code" = 1 ] && said "$classic" err && restarts 1'

label="a daemon that does not come back after the restart, as CLI 28 answers, does not answer"
daemon classic cli28-down
run
check eval '[ "$code" = 1 ] && said "$no_answer" err && ! grep -q classic "$scratch/err" && restarts 1'

label="every docker and systemctl call was one the shims model"
daemon containerd
if ! ls "$scratch"/unmodelled-* > /dev/null 2>&1; then pass "$label"; else
  code=-
  : > "$scratch/out"
  cat "$scratch"/unmodelled-* > "$scratch/err"
  fail "$label"
fi

echo "$((cases - failures)) of $cases cases passed"
[ "$failures" -eq 0 ]
