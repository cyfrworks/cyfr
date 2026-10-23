# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The setup proof's teardown, sourced by tests/setup-proof/run.sh and by its
# regression (tests/setup-proof/cleanup-test.sh). It reads the run's
# PROOF_PID, SETUP_PID, PROJECTS, STANDIN_IMAGE, IMAGE, WORK and OUT, and
# calls `compose_in`, which run.sh defines, and the browser harness's
# `stop_proof_container` (tests/browser/harness.sh).
#
# What runs goes first, each awaited before what it depends on goes: the
# proof's browser, whose container outlives the shell that started it
# (`stop_proof_container`), then `cyfr setup`, asked to stop as an
# interrupt asks it, so a waiting join is cancelled and a start runs to its
# end under the stack's lock, killed only past 300 s. Then each project
# goes whole, its volumes with it: its join containers (labelled by the
# engine), the stack and the join network; then the stand-in image and the
# scratch directory. The asks and answers go on every exit; the record
# stays. A removal is tried three times, and one that still fails fails the
# run.

# The step `$@`, tried three times, three seconds apart.
cleanup_retry() {
  local attempt
  for attempt in 1 2 3; do
    "$@" >/dev/null 2>&1 && return 0
    [ "$attempt" = 3 ] || sleep 3
  done
  echo "::error::setup proof cleanup: $* failed three times" >&2
  return 1
}

cleanup() {
  local code=$? failed="" project id closes taken=1
  if [ -n "$PROOF_PID" ]; then
    kill "$PROOF_PID" 2>/dev/null || true
  fi
  stop_proof_container
  if [ -n "$PROOF_PID" ]; then
    wait "$PROOF_PID" 2>/dev/null || true
    PROOF_PID=""
  fi
  rm -f "$OUT"/ask-* "$OUT"/answer-*
  if [ -n "$SETUP_PID" ]; then
    kill -TERM "$SETUP_PID" 2>/dev/null || true
    closes=$((SECONDS + 300))
    while kill -0 "$SETUP_PID" 2>/dev/null && [ "$SECONDS" -lt "$closes" ]; do
      sleep 0.2
    done
    if kill -0 "$SETUP_PID" 2>/dev/null; then
      echo "::error::setup proof cleanup: cyfr setup did not stop within 300 s; killed" >&2
      kill -KILL "$SETUP_PID" 2>/dev/null || true
      failed=1
    fi
    wait "$SETUP_PID" 2>/dev/null || true
    SETUP_PID=""
  fi
  for project in ${PROJECTS[@]+"${PROJECTS[@]}"}; do
    if [ "$code" -ne 0 ]; then
      echo "----- $project: the last lines of the stack's logs -----" >&2
      compose_in "$project" logs --no-color --tail 60 cyfr tailscale >&2 2>/dev/null || true
    fi
    for id in $(docker ps -aq --filter "label=com.cyfr.access.project=$project" 2>/dev/null || true); do
      cleanup_retry docker rm --force "$id" || failed=1
    done
    cleanup_retry compose_in "$project" down --volumes --remove-orphans --timeout 30 || failed=1
    if docker network inspect "${project}_tailnet-join" >/dev/null 2>&1; then
      cleanup_retry docker network rm "${project}_tailnet-join" || failed=1
    fi
  done
  if docker image inspect "$STANDIN_IMAGE" >/dev/null 2>&1; then
    cleanup_retry docker image rm --force "$STANDIN_IMAGE" || failed=1
  fi
  # The entrypoint gave data/ to the image's user; it is taken back first.
  if [ ${#PROJECTS[@]} -gt 0 ]; then
    cleanup_retry docker run --rm ${PROOF_RUN_PREFIX:+--name "$RUN-chown-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"} --volume "$WORK:/work" \
      --entrypoint chown "$IMAGE" -R "$(id -u):$(id -g)" /work || {
      failed=1
      taken=""
    }
  fi
  if [ -n "$taken" ]; then
    rm -rf "$WORK" || failed=1
  else
    echo "kept $WORK" >&2
  fi
  if [ -n "$failed" ] && [ "$code" -eq 0 ]; then
    code=1
  fi
  exit "$code"
}
