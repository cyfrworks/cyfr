# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The directory's front for the cells, sourced after tests/release-boot/
# release.sh and tests/browser/harness.sh (by run.sh, and by a proof that
# reuses it, as tests/join-proof/ does): one container of the pinned
# Playwright image per run, `cyfr-identity-front-<run>`, running
# front.mjs on the host network as root, so it may listen on port 443 of
# the proof's own loopback address (IDENTITY_FRONT_ADDRESS, 127.77.0.1),
# which nothing else on the host uses. It presents the certificate the
# run's authority issued for the directory's name and forwards to the
# directory cell. Cells reach it by name through their ERL_INETRC
# (cells.sh), so no DNS, /etc/hosts or other system configuration is read
# or changed.
#
# The browsers never use it: they reach every home, the directory's
# included, through the harness's own proxy.

IDENTITY_FRONT_ADDRESS="${IDENTITY_FRONT_ADDRESS:-127.77.0.1}"
IDENTITY_FRONT_CONTROL_PORT="${IDENTITY_FRONT_CONTROL_PORT:-9443}"
IDENTITY_FRONT_NAME=""

# Start the front for the directory cell `$1`, answering as its hostname
# (the run's authority issued its certificate when the cell became a home,
# `browser_home`). The container is named for this run and removed by
# `identity_front_stop`.
identity_front_start() {
  local cell="$1" host port
  host="$(sed -n 's/^CYFR_HOST=//p' "$cell/.env" | tail -1)"
  port="$(cell_port "$cell")"
  [ -f "$BROWSER_AUTHORITY/$host.pem" ] || fail "no certificate for $host: make $cell a home first"
  IDENTITY_FRONT_NAME="cyfr-identity-front-$$"
  docker rm -f "$IDENTITY_FRONT_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$IDENTITY_FRONT_NAME" --network host -u 0 \
    -v "$BROWSER_AUTHORITY:/authority:ro" -v "$ROOT/tests/identity-proof:/front:ro" \
    "$PLAYWRIGHT_IMAGE" \
    node /front/front.mjs "$IDENTITY_FRONT_ADDRESS:443" "$IDENTITY_FRONT_CONTROL_PORT" "$host" \
    "/authority/$host.pem" "/authority/$host.key" "$port" >/dev/null ||
    fail "the directory's front did not start"
  for _ in $(seq 1 60); do
    if curl -fsS -m 2 -o /dev/null "http://$IDENTITY_FRONT_ADDRESS:$IDENTITY_FRONT_CONTROL_PORT/health" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  docker logs "$IDENTITY_FRONT_NAME" >&2 || true
  fail "the directory's front did not answer on $IDENTITY_FRONT_ADDRESS:$IDENTITY_FRONT_CONTROL_PORT"
}

# Break the directory on purpose (front.mjs): none, down, drop-recover or
# block-reads-after-recover.
identity_front_fault() {
  local answer
  answer="$(curl -fsS -m 5 -X POST -H 'content-type: application/json' \
    --data "{\"mode\":\"$1\"}" "http://$IDENTITY_FRONT_ADDRESS:$IDENTITY_FRONT_CONTROL_PORT/fault")" ||
    fail "the directory's front took no fault '$1'"
  printf '%s' "$answer" | grep -q "\"$1\"" || fail "the directory's front answered '$answer' to '$1'"
}

# Every request that reached the front, as JSON.
identity_front_seen() {
  curl -fsS -m 5 "http://$IDENTITY_FRONT_ADDRESS:$IDENTITY_FRONT_CONTROL_PORT/seen"
}

identity_front_stop() {
  if [ -n "$IDENTITY_FRONT_NAME" ]; then
    docker rm -f "$IDENTITY_FRONT_NAME" >/dev/null 2>&1 || true
    IDENTITY_FRONT_NAME=""
  fi
}
