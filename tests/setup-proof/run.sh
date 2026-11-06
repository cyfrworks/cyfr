#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The setup proof: `cyfr setup`, the command line built from this tree, in
# a project of the shipped docker-compose.yml with the app image built from
# this tree, as the Compose proof brings one up (tests/compose-proof/), its
# pages driven at the 720×720 touch handheld (tests/browser/handheld.mjs)
# in Chromium through the browser harness (tests/browser/harness.sh), each
# screen held to the handheld's checks. Its cases, in order:
#
#   local    Welcome, whose one button, Set up CYFR, starts it with no
#            question: .env written, reached from this device, and CYFR
#            started, the browser moved to the setup link
#            http://localhost:<CYFR_PORT>/setup#<token>, a name typed on
#            its first screen, which says cyfr.run did not answer, a
#            passkey from a virtual authenticator making the first person,
#            and the second screen saying "cyfr.run did not answer. Try
#            again." with no recovery code and no way into CYFR, since
#            CYFR's directory and registry are `.invalid` names
#            (compose.yml); the same link in another browser then closed,
#            and the command exited 0, its address gone.
#   again    `cyfr setup` again in that project: exit 0 with the next
#            step of the CYFR whose first person the pages made, `cyfr
#            open` (its log holds the set-up line after the boot's
#            not-set-up line), nothing written and nothing served at the
#            port asked for.
#
# Usage: tests/setup-proof/run.sh
# Env: SETUP_PROOF_IMAGE (default cyfr:setup-proof), built from this tree
# unless SETUP_PROOF_SKIP_BUILD=1; SETUP_PROOF_OUT, where the record
# (setup-proof.json) and each screen's screenshot are written (default: a
# scratch directory, removed when the run ends).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
for name in $(compgen -e); do
  case "$name" in COMPOSE_*) unset "$name" ;; esac
done
RUN="${PROOF_RUN_PREFIX:-}cyfr-setup-proof-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
WORK="${TMPDIR:-/tmp}/$RUN"
mkdir -m 700 "$WORK"
OUT="${SETUP_PROOF_OUT:-$WORK/out}"
mkdir -p "$OUT"
IMAGE="${SETUP_PROOF_IMAGE:-cyfr:setup-proof}"
CYFR="$WORK/bin/cyfr"
# The run's projects, each a directory under WORK named as its compose
# project, and the `cyfr setup` of the case under way.
PROJECTS=()
SETUP_PID=""
PROOF_PID=""

step() { echo; echo "==> $*"; }
ok() { echo "ok: $*"; }
fail() {
  echo "::error::$*" >&2
  exit 1
}

# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"

# compose for the project `$1`, as its own directory resolves it.
compose_in() {
  local project="$1"
  shift
  docker compose --project-name "$project" --project-directory "$WORK/$project" \
    -f "$WORK/$project/docker-compose.yml" -f "$WORK/$project/docker-compose.override.yml" "$@"
}

# The value .env's last assignment of `$2` holds in the project `$1`.
env_value() {
  NAME="$2" awk 'index($0, ENVIRON["NAME"] "=") == 1 { value = substr($0, length(ENVIRON["NAME"]) + 2) } END { print value }' "$WORK/$1/.env"
}

# A loopback port nothing listens on now.
free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# shellcheck source=tests/setup-proof/cleanup.sh
. "$HERE/cleanup.sh"
trap cleanup EXIT

# `cyfr setup --no-pull --no-open` `$2...` in the project `$1`, as a
# device's launcher runs it there, this proof being the launcher that
# opens the pages: HOME the run's own, nothing of the caller's environment
# but PATH and how Docker is reached, so no display, its output in
# `$WORK/$1.setup.log`. The run's images are built here, so nothing is
# pulled. Its pid is left in SETUP_PID.
setup_start() {
  local project="$1"
  shift
  (
    cd "$WORK/$project" || exit 1
    umask 022
    exec env -i HOME="$WORK/home" PATH="$PATH" LANG=C.UTF-8 TERM=dumb \
      DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
      ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} \
      "$CYFR" setup --no-pull --no-open "$@"
  ) </dev/null >"$WORK/$project.setup.log" 2>&1 &
  SETUP_PID=$!
}

# The address `cyfr setup` wrote in the project `$1`, once written, within
# 30 s.
setup_address() {
  local file="$WORK/$1/.cyfr/setup.url" closes=$((SECONDS + 30))
  until [ -s "$file" ]; do
    kill -0 "$SETUP_PID" 2>/dev/null || fail "cyfr setup ended before it served its pages: $(tail -n 20 "$WORK/$1.setup.log")"
    [ "$SECONDS" -lt "$closes" ] || fail "cyfr setup wrote no address within 30 s"
    sleep 0.1
  done
  [ "$(stat -c %a "$file")" = 600 ] || fail "$file is not mode 0600"
  grep -qxF "Setup is at $(cat "$file")" "$WORK/$1.setup.log" || fail "cyfr setup did not print the address it wrote"
  cat "$file"
}

# `cyfr setup`'s exit status, once it ends within `$1` s, in
# SETUP_STATUS. It runs in this shell, never a subshell, which could not
# wait for it.
SETUP_STATUS=""
setup_wait() {
  local closes=$((SECONDS + $1))
  while kill -0 "$SETUP_PID" 2>/dev/null; do
    [ "$SECONDS" -lt "$closes" ] || fail "cyfr setup did not stop within $1 s"
    sleep 0.2
  done
  SETUP_STATUS=0
  wait "$SETUP_PID" || SETUP_STATUS=$?
  SETUP_PID=""
}

# A new project `$1`: the shipped compose file and the overlay, the
# deployment files a release's scaffold lays down, and the template `cyfr
# setup` writes .env from, with the run's settings in it: its port, its
# images, migration on and builds off.
project_new() {
  local project="$1" port="$2"
  mkdir -p "$WORK/$project"
  PROJECTS+=("$project")
  cp "$ROOT/docker-compose.yml" "$WORK/$project/docker-compose.yml"
  cp "$HERE/compose.yml" "$WORK/$project/docker-compose.override.yml"
  cp "$ROOT/Caddyfile" "$WORK/$project/Caddyfile"
  cp "$ROOT/apps/locus/keeper/seccomp/keeper.json" "$WORK/$project/keeper.seccomp.json"
  sed -e "s|^CYFR_PORT=.*|CYFR_PORT=$port|" -e 's|^CYFR_LOCUS_BUILDS_URL=.*|CYFR_LOCUS_BUILDS_URL=|' \
    "$ROOT/.env.example" >"$WORK/$project/.env.example"
  printf '%s\n' "CYFR_AUTO_MIGRATE=on" "PROOF_APP_IMAGE=$IMAGE" >>"$WORK/$project/.env.example"
  grep -qx "CYFR_PORT=$port" "$WORK/$project/.env.example" || fail "the template names no CYFR_PORT to set"
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

if [ "${SETUP_PROOF_SKIP_BUILD:-}" != 1 ]; then
  step "building the app image from this tree as the publication job does"
  docker build -f "$ROOT/Dockerfile" --build-arg "APT_REFRESH=$(date -u +%F)" -t "$IMAGE" "$ROOT" \
    >"$WORK/build.log" 2>&1 || {
    tail -n 60 "$WORK/build.log" >&2
    fail "the app image did not build"
  }
  ok "built $IMAGE"
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "the image $IMAGE is not built"

step "the command line, built from this tree"
mkdir -p "$WORK/bin" "$WORK/home"
(cd "$ROOT/apps/codex" && CGO_ENABLED=0 go build -mod=readonly -o "$CYFR" .) || fail "the command line did not build"
ok "built $CYFR"

step "local: Set up CYFR, set up from the pages and started"
LOCAL="$RUN-local"
LOCAL_PORT="$(free_port)"
project_new "$LOCAL" "$LOCAL_PORT"
setup_start "$LOCAL"
address="$(setup_address "$LOCAL")"
ok "cyfr setup serves its pages at ${address%%#*}"
# The proof asks nothing of this run: `true` answers no ask.
playwright_run setup-proof proof.mjs "$address" "$LOCAL_PORT" &
PROOF_PID=$!
proof_await true
[ "$PROOF_STATUS" -eq 0 ] || fail "the pages did not hold (proof exit $PROOF_STATUS); $OUT/setup-proof.json says where"
setup_wait 120
[ "$SETUP_STATUS" = 0 ] || fail "cyfr setup exited $SETUP_STATUS: $(tail -n 30 "$WORK/$LOCAL.setup.log")"
[ ! -e "$WORK/$LOCAL/.cyfr/setup.url" ] || fail "cyfr setup left its address behind"
[ "$(env_value "$LOCAL" CYFR_ACCESS)" = local ] || fail ".env says CYFR is reached as $(env_value "$LOCAL" CYFR_ACCESS)"
[ "$(stat -c %a "$WORK/$LOCAL/.env")" = 600 ] || fail ".env is not mode 0600"
token="$(env_value "$LOCAL" CYFR_SETUP_TOKEN)"
[[ "$token" =~ ^[0-9a-f]{64}$ ]] || fail ".env holds no setup token of 64 lowercase hexadecimal characters"
if compose_in "$LOCAL" logs --no-color cyfr 2>&1 | grep -qF "$token"; then
  fail "the cyfr service's log records the setup token"
fi
ok "CYFR runs at http://localhost:$LOCAL_PORT, its first person made, and cyfr setup exited 0"

step "again: cyfr setup where .env exists says the next step"
port="$(free_port)"
cp "$WORK/$LOCAL/.env" "$WORK/$LOCAL.env.before"
setup_start "$LOCAL" --port "$port"
setup_wait 30
[ "$SETUP_STATUS" = 0 ] || fail "cyfr setup over an existing .env exited $SETUP_STATUS: $(cat "$WORK/$LOCAL.setup.log")"
first="$(cat "$WORK/$LOCAL.setup.log")"
[ "$first" = "CYFR is set up and has its first person. cyfr open opens it." ] ||
  fail "cyfr setup over an existing .env said: $first"
cmp -s "$WORK/$LOCAL/.env" "$WORK/$LOCAL.env.before" || fail "cyfr setup over an existing .env changed .env"
[ ! -e "$WORK/$LOCAL/.cyfr/setup.url" ] || fail "cyfr setup over an existing .env wrote an address"
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
  fail "something answers at 127.0.0.1:$port after cyfr setup said the next step"
fi
ok "said the next step ($first), exit 0, nothing written or served"

echo
echo "setup proof: passed; the record is $OUT/setup-proof.json"
