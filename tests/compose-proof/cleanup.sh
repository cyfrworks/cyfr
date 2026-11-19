# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof's teardown, sourced by tests/compose-proof/run.sh and
# by its stand-in cases (tests/compose-proof/cleanup-test.sh). It reads the
# run's RUN, WORK, IMAGE, UPSTREAM, STANDIN_IMAGE and RELEASE_IMAGES, and calls `compose`
# and `docker`, which the caller defines or finds.
#
# sweep_dead_runs, which run.sh calls at its start, removes what an earlier
# run killed before its teardown left of its own.
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

# The network `$1` removed, or already gone.
network_gone() {
  docker network inspect "$1" >/dev/null 2>&1 || return 0
  docker network rm "$1"
}

# The project goes whole, its volumes with it, however the run ends; a
# failed run prints the containers' last lines first.
cleanup() {
  local code=$? failed="" paused id
  if [ "$code" -ne 0 ]; then
    echo "----- the last lines of the project's logs -----" >&2
    compose logs --no-color --tail 60 cyfr caddy tailscale >&2 2>/dev/null || true
  fi
  # A docker call the interrupt case paused ends first, so nothing it
  # would still do lands after the teardown.
  paused="$(cat "$WORK/faults/paused" 2>/dev/null || true)"
  if [ -n "$paused" ]; then
    kill -KILL "$paused" 2>/dev/null || true
  fi
  # The cases' clients, the command lines they run and the shutdown case's
  # upstream go next: the upstream holds a place on the project's
  # network, which `down` removes.
  local job
  for job in $(jobs -p); do
    pkill -P "$job" 2>/dev/null || true
    kill "$job" 2>/dev/null || true
  done
  if [ -n "$UPSTREAM" ]; then
    cleanup_step "docker rm --force $UPSTREAM" docker rm --force "$UPSTREAM" || failed=1
  fi
  # The access engine's join containers carry the project in a label of
  # their own, outside compose's.
  for id in $(docker ps -aq --filter "label=com.cyfr.access.project=$RUN" 2>/dev/null || true); do
    cleanup_step "docker rm --force $id (a join container)" docker rm --force "$id" || failed=1
  done
  cleanup_step "docker compose down --volumes" compose down --volumes --remove-orphans --timeout 30 || failed=1
  cleanup_step "docker network rm ${RUN}_tailnet-join" network_gone "${RUN}_tailnet-join" || failed=1
  if [ -n "${STANDIN_IMAGE:-}" ]; then
    cleanup_step "docker image rm $STANDIN_IMAGE" docker image rm --force "$STANDIN_IMAGE" || failed=1
  fi
  # The update cases' release tags and the images built for them, once no
  # container of the project holds one.
  local made
  for made in ${RELEASE_IMAGES[@]+"${RELEASE_IMAGES[@]}"}; do
    cleanup_step "docker image rm $made" docker image rm "$made" || failed=1
  done
  if [ "${COMPOSE_PROOF_KEEP:-}" = 1 ]; then
    : >"$WORK/kept"
    echo "kept $WORK"
  else
    # The entrypoint gave the data and template directories to the image's
    # user; they are taken back before the scratch directory goes.
    cleanup_step "taking $WORK back from the image's user" \
      docker run --rm ${PROOF_RUN_PREFIX:+--name "$RUN-chown-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"} --volume "$WORK:/work" \
      --entrypoint chown "$IMAGE" -R "$(id -u):$(id -g)" /work || failed=1
    cleanup_step "removing $WORK" rm -rf "$WORK" || failed=1
  fi
  if [ -n "$failed" ] && [ "$code" -eq 0 ]; then
    code=1
  fi
  exit "$code"
}

# What an earlier run of this proof left when it was killed before its
# teardown: its scratch directory and its update cases' release tags, each
# named after its RUN, which carries the pid of the run.sh that made it. A
# run whose pid lives keeps both, and so does a scratch directory holding
# `kept`, which the teardown writes when COMPOSE_PROOF_KEEP=1 keeps it, or
# one another user owns. A directory goes once the image's user has given
# its data back, as the teardown takes its own; a tag goes without force,
# so one a container still uses stays. The run's containers, networks,
# volumes and stand-in image are scripts/janitor.sh's (rule 1), named under
# the run prefix. A removal that fails is named on stderr and the run goes
# on: an earlier run's leftovers do not fail this one.
sweep_dead_runs() {
  local dir name pid
  local scratch_name='^(cyfr-[0-9a-f]{10}-[0-9]+-)?cyfr-compose-proof-([0-9]+)-[0-9a-f]{8}$'
  local release_tag='^ghcr\.io/cyfrworks/cyfr(-locus)?:[0-9]+\.[0-9]+\.[0-9]+-(cyfr-[0-9a-f]{10}-[0-9]+-)?cyfr-compose-proof-([0-9]+)-[0-9a-f]{8}\.[12]$'
  for dir in "${TMPDIR:-/tmp}"/*cyfr-compose-proof-*; do
    [ -d "$dir" ] && [ -O "$dir" ] && [ "$dir" != "$WORK" ] || continue
    [[ ${dir##*/} =~ $scratch_name ]] || continue
    pid=${BASH_REMATCH[2]}
    ! ps -p "$pid" >/dev/null 2>&1 || continue
    [ ! -e "$dir/kept" ] || continue
    if docker run --rm ${PROOF_RUN_PREFIX:+--name "$RUN-sweep-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"} --volume "$dir:/work" \
      --entrypoint chown "$IMAGE" -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 && rm -rf "$dir"; then
      echo "removed $dir, left by the run $pid, which is gone"
    else
      echo "::warning::compose proof: could not remove $dir, left by the run $pid" >&2
    fi
  done
  while IFS= read -r name; do
    [[ $name =~ $release_tag ]] || continue
    pid=${BASH_REMATCH[3]}
    ! ps -p "$pid" >/dev/null 2>&1 || continue
    if docker image rm "$name" >/dev/null 2>&1; then
      echo "removed the tag $name, left by the run $pid, which is gone"
    else
      echo "::warning::compose proof: could not remove the tag $name, left by the run $pid" >&2
    fi
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
}
