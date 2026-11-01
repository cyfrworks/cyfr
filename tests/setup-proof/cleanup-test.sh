#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The setup proof's teardown (tests/setup-proof/cleanup.sh) on a run that
# fails while its browser and its `cyfr setup` still run: a driver sources
# the browser harness and the teardown as run.sh does, starts a proof job
# whose `docker start --attach` holds a container mounting OUT, as
# `playwright_run` holds the browser's, and a stand-in for `cyfr setup` that
# stops on SIGTERM, then fails. The teardown passes when, by its return,
# the container is stopped, the proof job and the stand-in have ended, the
# stand-in having been asked to stop, and the scratch directory is gone.
#
# Usage: tests/setup-proof/cleanup-test.sh
# Env: SETUP_PROOF_IMAGE, an image with `sleep` (default cyfr:setup-proof),
# which is never pulled.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TEARDOWN="$HERE/cleanup.sh"
IMAGE="${SETUP_PROOF_IMAGE:-cyfr:setup-proof}"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-setup-cleanup-test.XXXXXX")"
CONTAINER="${PROOF_RUN_PREFIX:-}cyfr-setup-cleanup-test-$$-${BASE##*.}"
LABEL="com.cyfr.setup-cleanup-test"
DRIVER_PID=""
mkdir -p "$BASE/work/out" "$BASE/control"

# The test's own net, apart from the teardown under test: the container it
# made, by name and label, and any process it started.
finish() {
  local code=$? pid
  trap - EXIT
  [ -z "$DRIVER_PID" ] || kill "$DRIVER_PID" 2>/dev/null || true
  for pid in $(cat "$BASE/control/"*.pid 2>/dev/null || true); do
    kill -KILL "$pid" 2>/dev/null || true
  done
  if [ "$(docker inspect --format "{{index .Config.Labels \"$LABEL\"}}" "$CONTAINER" 2>/dev/null || true)" = "$CONTAINER" ]; then
    docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
  fi
  rm -rf "$BASE"
  exit "$code"
}
trap finish EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "::error::the image $IMAGE is not here; set SETUP_PROOF_IMAGE to one with sleep" >&2
  exit 1
}
docker create --pull=never --name "$CONTAINER" --label "$LABEL=$CONTAINER" --network none \
  --mount "type=bind,source=$BASE/work/out,target=/out" --entrypoint sleep "$IMAGE" 300 >/dev/null

# The driver: run.sh's state and teardown, a proof job attached to the
# container, a setup that stops on SIGTERM, then a failure.
bash -s -- "$ROOT" "$TEARDOWN" "$BASE" "$CONTAINER" <<'DRIVER' &
set -euo pipefail
ROOT="$1"
TEARDOWN="$2"
BASE="$3"
CONTAINER="$4"
WORK="$BASE/work"
OUT="$WORK/out"
CONTROL="$BASE/control"
PROJECTS=()
PROOF_PID=""
SETUP_PID=""
STANDIN_IMAGE="cyfr-setup-cleanup-test-never-built:$CONTAINER"
IMAGE="cyfr-setup-cleanup-test-never-used:$CONTAINER"
compose_in() { echo "no project is made here" >&2; return 1; }
# shellcheck source=tests/browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=tests/setup-proof/cleanup.sh
. "$TEARDOWN"
trap cleanup EXIT

proof_job() {
  docker start --attach "$CONTAINER" >/dev/null 2>&1 &
  echo "$!" >"$CONTROL/client.pid"
  wait "$!"
}
proof_job &
PROOF_PID=$!
echo "$PROOF_PID" >"$CONTROL/proof.pid"
bash -c 'trap "echo stopped >\"$1\"; exit 0" TERM; while :; do sleep 0.1; done' setup "$CONTROL/setup.stopped" &
SETUP_PID=$!
echo "$SETUP_PID" >"$CONTROL/setup.pid"
closes=$((SECONDS + 30))
until [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" = true ]; do
  [ "$SECONDS" -lt "$closes" ] || exit 25
  sleep 0.1
done
echo "ready" >"$CONTROL/ready"
exit 23
DRIVER
DRIVER_PID=$!
status=0
wait "$DRIVER_PID" || status=$?
DRIVER_PID=""
[ -e "$BASE/control/ready" ] || {
  echo "::error::the driver never had its browser container running (exit $status)" >&2
  exit 1
}

failures=()
[ "$status" = 23 ] || failures+=("the teardown exited $status, not the run's own 23")
[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo gone)" != true ] ||
  failures+=("the proof's browser container $CONTAINER still runs")
for job in proof setup; do
  pid="$(cat "$BASE/control/$job.pid")"
  if kill -0 "$pid" 2>/dev/null; then
    failures+=("the $job process $pid outlived the teardown")
  fi
done
# The attached client ends as its container stops, a moment after.
client="$(cat "$BASE/control/client.pid")"
closes=$((SECONDS + 5))
while kill -0 "$client" 2>/dev/null && [ "$SECONDS" -lt "$closes" ]; do
  sleep 0.1
done
if kill -0 "$client" 2>/dev/null; then
  failures+=("the proof job's docker client $client outlived its container")
fi
[ -e "$BASE/control/setup.stopped" ] || failures+=("cyfr setup's stand-in was never asked to stop")
[ ! -e "$BASE/work" ] || failures+=("the scratch directory is left")

if [ ${#failures[@]} -gt 0 ]; then
  for failure in "${failures[@]}"; do
    echo "FAIL: $failure"
  done
  exit 1
fi
echo "setup proof teardown: the browser's container stopped, the proof job and cyfr setup ended, the scratch gone"
