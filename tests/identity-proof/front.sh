# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The directories' fronts for the cells, sourced after tests/release-boot/
# release.sh and tests/browser/harness.sh (by run.sh, and by a proof that
# reuses it, as tests/join-proof/ does). Each directory a proof runs is
# declared once, by its name and the front address the cells reach it at
# (`identity_directory`), each on a loopback address of its own that
# nothing else on the host uses (127.77.0.1, 127.77.0.2, …). Each front is
# one container of the pinned Playwright image, `cyfr-identity-front-
# <run>-<name>`, running front.mjs on the host network as root, so it may
# listen on port 443 of that address. It presents the certificate the
# run's authority issued for the directory's name and forwards to the
# directory cell. Cells reach it by name through their ERL_INETRC
# (cells.sh), so no DNS, /etc/hosts or other system configuration is read
# or changed.
#
# The browsers never use a front: they reach every home, the
# directories' included, through the harness's own proxy.

# Each declared directory: its front address, and its control port.
declare -A IDENTITY_FRONTS=()
declare -A IDENTITY_FRONT_CONTROLS=()
# Each started front's container, by directory.
declare -A IDENTITY_FRONT_NAMES=()

# Declare the directory `$1` (its hostname), reached at the front address
# `$2` (a loopback address of this run's own), its control listener on
# port `$3` (9443) of the same address. Every directory is declared
# before any cell that reaches one is configured (cells.sh).
identity_directory() {
  local host="$1" address="$2" control="${3:-9443}"
  [[ "$host" == *.test ]] || fail "a directory's name is a .test name, not '$host'"
  [[ "$address" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "a front's address is a loopback address, not '$address'"
  IDENTITY_FRONTS[$host]="$address"
  IDENTITY_FRONT_CONTROLS[$host]="$control"
}

# The control listener of directory `$1`'s front.
identity_front_control() {
  local host="$1"
  [ -n "${IDENTITY_FRONTS[$host]:-}" ] || fail "no directory $host is declared"
  printf 'http://%s:%s' "${IDENTITY_FRONTS[$host]}" "${IDENTITY_FRONT_CONTROLS[$host]}"
}

# Start the front of the directory cell `$1`, answering as its hostname
# (the run's authority issued its certificate when the cell became a home,
# `browser_home`), at the address its directory was declared at. The
# container is named for this run and that directory, and removed by
# `identity_front_stop`.
identity_front_start() {
  local cell="$1" host port name control
  host="$(sed -n 's/^CYFR_HOST=//p' "$cell/.env" | tail -1)"
  port="$(cell_port "$cell")"
  [ -n "${IDENTITY_FRONTS[$host]:-}" ] || fail "no directory $host is declared: identity_directory comes first"
  [ -f "$BROWSER_AUTHORITY/$host.pem" ] || fail "no certificate for $host: make $cell a home first"
  name="cyfr-identity-front-$$-${host//./-}"
  control="$(identity_front_control "$host")"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --network host -u 0 \
    -v "$BROWSER_AUTHORITY:/authority:ro" -v "$ROOT/tests/identity-proof:/front:ro" \
    "$PLAYWRIGHT_IMAGE" \
    node /front/front.mjs "${IDENTITY_FRONTS[$host]}:443" "${IDENTITY_FRONT_CONTROLS[$host]}" "$host" \
    "/authority/$host.pem" "/authority/$host.key" "$port" >/dev/null ||
    fail "the front of $host did not start"
  IDENTITY_FRONT_NAMES[$host]="$name"
  for _ in $(seq 1 60); do
    if curl -fsS -m 2 -o /dev/null "$control/health" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2 || true
  fail "the front of $host did not answer on $control"
}

# Break directory `$1` on purpose (front.mjs): `$2` is none, down,
# drop-recover or block-reads-after-recover.
identity_front_fault() {
  local host="$1" mode="$2" answer
  answer="$(curl -fsS -m 5 -X POST -H 'content-type: application/json' \
    --data "{\"mode\":\"$mode\"}" "$(identity_front_control "$host")/fault")" ||
    fail "the front of $host took no fault '$mode'"
  printf '%s' "$answer" | grep -q "\"$mode\"" || fail "the front of $host answered '$answer' to '$mode'"
}

# Every request that reached directory `$1`'s front, as JSON.
identity_front_seen() {
  curl -fsS -m 5 "$(identity_front_control "$1")/seen"
}

# Every front this run started, removed.
identity_front_stop() {
  local host
  for host in "${!IDENTITY_FRONT_NAMES[@]}"; do
    docker rm -f "${IDENTITY_FRONT_NAMES[$host]}" >/dev/null 2>&1 || true
    unset "IDENTITY_FRONT_NAMES[$host]"
  done
}
