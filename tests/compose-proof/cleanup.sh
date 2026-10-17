# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof's teardown, sourced by tests/compose-proof/run.sh and
# by its stand-in cases (tests/compose-proof/cleanup-test.sh). It reads the
# run's RUN, WORK, IMAGE and UPSTREAM, and calls `compose` and `docker`,
# which the caller defines or finds.
#
# A step that removes what the run made is tried up to three times,
# COMPOSE_PROOF_CLEANUP_PAUSE seconds apart (default 5). A step that still
# fails is named on stderr with the project it leaves behind, and the run
# exits non-zero even when every case passed: a run that leaves its
# project on the host does not pass.

# Runs the command after `$1`, the step's description, until it succeeds,
# at most three times. Answers 1 after the third failure, its last error
# printed.
cleanup_step() {
  local what="$1" attempt err=""
  shift
  for attempt in 1 2 3; do
    if err="$("$@" 2>&1 >/dev/null)"; then
      return 0
    fi
    [ "$attempt" = 3 ] || sleep "${COMPOSE_PROOF_CLEANUP_PAUSE:-5}"
  done
  echo "::error::compose proof cleanup: $what failed three times, leaving the project $RUN on this host: ${err:0:600}" >&2
  return 1
}

# The project goes whole, its volumes with it, however the run ends; a
# failed run prints the containers' last lines first.
cleanup() {
  local code=$? failed=""
  if [ "$code" -ne 0 ]; then
    echo "----- the last lines of the project's logs -----" >&2
    compose logs --no-color --tail 60 cyfr caddy >&2 2>/dev/null || true
  fi
  # The shutdown case's clients and its upstream go first: the upstream
  # holds a place on the project's network, which `down` removes.
  local job
  for job in $(jobs -p); do
    pkill -P "$job" 2>/dev/null || true
    kill "$job" 2>/dev/null || true
  done
  if [ -n "$UPSTREAM" ]; then
    cleanup_step "docker rm --force $UPSTREAM" docker rm --force "$UPSTREAM" || failed=1
  fi
  cleanup_step "docker compose down --volumes" compose down --volumes --remove-orphans --timeout 30 || failed=1
  if [ "${COMPOSE_PROOF_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    # The entrypoint gave the data and template directories to the image's
    # user; they are taken back before the scratch directory goes.
    cleanup_step "taking $WORK back from the image's user" \
      docker run --rm --volume "$WORK:/work" --entrypoint chown "$IMAGE" -R "$(id -u):$(id -g)" /work || failed=1
    cleanup_step "removing $WORK" rm -rf "$WORK" || failed=1
  fi
  if [ -n "$failed" ] && [ "$code" -eq 0 ]; then
    code=1
  fi
  exit "$code"
}
