#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The setup proof: `cyfr setup`, the command line built from this tree, in
# a project of the shipped docker-compose.yml with the app image built from
# this tree, as the Compose proof brings one up (tests/compose-proof/), its
# pages driven at the 720×720 touch handheld (tests/browser/handheld.mjs)
# in Chromium through the browser harness (tests/browser/harness.sh), each
# screen held to the handheld's checks. The project's tailscale service
# and the engine's join run the Tailscale stand-in
# (tests/compose-proof/tailscale-standin/). Its cases, in order:
#
#   local    Welcome, "Only this device", the email, Start: .env written
#            with the email as the administrator and the home started, the
#            browser moved to http://localhost:<CYFR_PORT>, the home's
#            sign-in page, and the command exited 0, its address gone.
#   refusal  `cyfr setup` again in that project: exit 1 with the sentence
#            of an existing home, which points at `cyfr access`, nothing
#            written and nothing served at the port asked for.
#   tailnet  a second project: "My phone and laptop", the email, Start;
#            the join's link on the page is the waiting join container's
#            own, drawn as a QR code, for the machine `cyfr`; a new name
#            under it joins again as that name, a new link; the approval in
#            the stand-in; the page names the machine, the home is served
#            through Serve at its name, and the Done page shows that
#            ts.net address with its sentence and does not move.
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
STANDIN_IMAGE="${PROOF_RUN_PREFIX:-}cyfr-tailscale-standin:$RUN"
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

# The value at path `$2...` of the JSON `$1`: a string as itself, anything
# else as JSON.
jget() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
value = json.load(sys.stdin)
for step in sys.argv[1:]:
    value = value.get(step) if isinstance(value, dict) else None
print(value if isinstance(value, str) else json.dumps(value))' "${@:2}"
}

# compose for the project `$1`, as its own directory resolves it.
compose_in() {
  local project="$1"
  shift
  docker compose --project-name "$project" --project-directory "$WORK/$project" \
    -f "$WORK/$project/docker-compose.yml" -f "$WORK/$project/docker-compose.override.yml" \
    --profile tailnet "$@"
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

# `cyfr setup --no-pull` `$2...` in the project `$1`, as a person runs it
# there: HOME the run's own, nothing of the caller's environment but PATH
# and how Docker is reached, its output in `$WORK/$1.setup.log`. The
# run's images are built here, so nothing is pulled. Its pid is left in
# SETUP_PID.
setup_start() {
  local project="$1"
  shift
  (
    cd "$WORK/$project" || exit 1
    umask 022
    exec env -i HOME="$WORK/home" PATH="$PATH" LANG=C.UTF-8 TERM=dumb \
      DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
      ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} \
      "$CYFR" setup --no-pull "$@"
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
  printf '%s\n' "CYFR_AUTO_MIGRATE=on" "PROOF_APP_IMAGE=$IMAGE" "PROOF_TAILSCALE_IMAGE=$STANDIN_IMAGE" \
    >>"$WORK/$project/.env.example"
  grep -qx "CYFR_PORT=$port" "$WORK/$project/.env.example" || fail "the template names no CYFR_PORT to set"
}

# The project of the case under way, which the proof's asks are about.
CASE_PROJECT=""

# The join container waiting for approval in CASE_PROJECT, other than the
# container `$1`, within 180 s, as JSON: its id, its approval link and the
# machine name it asks for.
waiting_join() {
  local not="${1:-}" closes=$((SECONDS + 180)) id state link
  while [ "$SECONDS" -lt "$closes" ]; do
    for id in $(docker ps -q --no-trunc --filter "label=com.cyfr.access.project=$CASE_PROJECT"); do
      [ "$id" != "$not" ] || continue
      state="$(docker exec "$id" tailscale status --json 2>/dev/null || true)"
      [ -n "$state" ] || continue
      link="$(jget "$state" AuthURL)"
      if [ "$(jget "$state" BackendState)" = NeedsLogin ] && [[ "$link" == https://* ]]; then
        python3 -I -c 'import json, sys; print(json.dumps({"container": sys.argv[1], "link": sys.argv[2], "hostname": sys.argv[3]}))' \
          "$id" "$link" "$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id" | sed -n 's/^TS_HOSTNAME=//p')"
        return 0
      fi
    done
    sleep 0.5
  done
  printf '{"error":"no join container of %s waited for approval within 180 s"}\n' "$CASE_PROJECT"
}

# The proof's asks: `join` (the waiting join container, not `not`),
# `approve` (the person's approval of `container` in the stand-in) and
# `served` (the home through Serve at `name`, from a device on the
# tailnet).
dispatch() {
  local request op name answer
  request="$(cat "$1")"
  op="$(jget "$request" op)"
  case "$op" in
    join)
      ANSWER="$(waiting_join "$(jget "$request" not | sed 's/^null$//')")"
      ;;
    approve)
      answer="$(docker exec "$(jget "$request" container)" standin approve 2>&1)" ||
        { ANSWER="$(python3 -I -c 'import json, sys; print(json.dumps({"error": sys.argv[1]}))' "$answer")"; return; }
      name="$(printf '%s\n' "$answer" | sed -n 's/^approved \([^ ]*\) .*/\1/p')"
      ANSWER="{\"name\":\"$name\"}"
      ;;
    served)
      name="$(jget "$request" name)"
      ANSWER="$(served "$name")"
      ;;
    *)
      ANSWER="{\"error\":\"no ask named $op\"}"
      ;;
  esac
}

# The home of CASE_PROJECT through Serve at the name `$1`, from a device on
# the tailnet: `standin fetch` of /api/health from a container of the
# stand-in on proof-tailnet, trusting the stand-in's authority, within 60 s,
# as fetch's JSON line.
served() {
  local name="$1" ts answer="" closes=$((SECONDS + 60))
  ts="$(compose_in "$CASE_PROJECT" ps -q tailscale)"
  [ -n "$ts" ] || { echo '{"error":"no tailscale container runs"}'; return; }
  docker exec "$ts" standin ca >"$WORK/$CASE_PROJECT.ca.pem" || { echo '{"error":"the stand-in has no authority"}'; return; }
  while [ "$SECONDS" -lt "$closes" ]; do
    answer="$(docker run --rm ${PROOF_RUN_PREFIX:+--name "$RUN-fetch-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"} --network "${CASE_PROJECT}_proof-tailnet" -v "$WORK/$CASE_PROJECT.ca.pem:/ca.pem:ro" "$STANDIN_IMAGE" \
      standin fetch --ca /ca.pem --connect tailscale:443 "https://$name/api/health" 2>/dev/null | sed -n '/^{/p' | tail -1 || true)"
    if [ -n "$answer" ] && [ "$(jget "$answer" status)" = 200 ]; then
      break
    fi
    sleep 1
  done
  if [ -z "$answer" ]; then
    answer='{"error":"Serve answered nothing"}'
  fi
  printf '%s\n' "$answer"
}

# The proof.mjs case `$1` against the pages at `$2`, the home's port `$3`,
# its asks answered here.
proof_case() {
  playwright_run setup-proof proof.mjs "$@" &
  PROOF_PID=$!
  proof_await dispatch
  [ "$PROOF_STATUS" -eq 0 ] || fail "the $1 case's pages did not hold (proof exit $PROOF_STATUS); $OUT/setup-proof-$1.json says where"
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

step "the command line and the Tailscale stand-in, built from this tree"
mkdir -p "$WORK/bin" "$WORK/home"
(cd "$ROOT/apps/codex" && CGO_ENABLED=0 go build -mod=readonly -o "$CYFR" .) || fail "the command line did not build"
"$ROOT/tests/compose-proof/tailscale-standin/build.sh" image "$STANDIN_IMAGE"
ok "built $CYFR and $STANDIN_IMAGE"

step "local: Only this device, set up from the pages and started"
LOCAL="$RUN-local"
LOCAL_PORT="$(free_port)"
project_new "$LOCAL" "$LOCAL_PORT"
CASE_PROJECT="$LOCAL"
setup_start "$LOCAL"
address="$(setup_address "$LOCAL")"
ok "cyfr setup serves its pages at ${address%%#*}"
proof_case local "$address" "$LOCAL_PORT"
setup_wait 120
[ "$SETUP_STATUS" = 0 ] || fail "cyfr setup exited $SETUP_STATUS: $(tail -n 30 "$WORK/$LOCAL.setup.log")"
[ ! -e "$WORK/$LOCAL/.cyfr/setup.url" ] || fail "cyfr setup left its address behind"
[ "$(env_value "$LOCAL" CYFR_ACCESS)" = local ] || fail ".env says the home is reached as $(env_value "$LOCAL" CYFR_ACCESS)"
[ "$(env_value "$LOCAL" CYFR_PLATFORM_ADMIN_EMAILS)" = operator@example.com ] || fail ".env names the administrators $(env_value "$LOCAL" CYFR_PLATFORM_ADMIN_EMAILS)"
[ "$(stat -c %a "$WORK/$LOCAL/.env")" = 600 ] || fail ".env is not mode 0600"
ok "the home runs at http://localhost:$LOCAL_PORT, .env names operator@example.com, and cyfr setup exited 0"

step "refusal: cyfr setup again where .env exists"
port="$(free_port)"
setup_start "$LOCAL" --port "$port"
setup_wait 30
want='.env says this home is reached as local, and cyfr setup leaves how an existing home is reached alone. Nothing was changed. Run `cyfr access <mode>` to change it'
[ "$SETUP_STATUS" = 1 ] || fail "cyfr setup over an existing .env exited $SETUP_STATUS"
grep -qxF "Error: $want" "$WORK/$LOCAL.setup.log" || fail "cyfr setup over an existing .env said: $(cat "$WORK/$LOCAL.setup.log")"
[ "$(wc -l <"$WORK/$LOCAL.setup.log")" = 1 ] || fail "cyfr setup over an existing .env said more: $(cat "$WORK/$LOCAL.setup.log")"
[ ! -e "$WORK/$LOCAL/.cyfr/setup.url" ] || fail "cyfr setup over an existing .env wrote an address"
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
  fail "something answers at 127.0.0.1:$port after the refusal"
fi
ok "refused with the existing home's sentence, exit 1, nothing written or served"

# The shipped file fixes the stack's subnets, so two of its stacks never
# run side by side: the local home goes before the tailnet one starts.
compose_in "$LOCAL" down --volumes --remove-orphans --timeout 30 >/dev/null 2>&1 ||
  fail "the local home's stack did not go down"

step "tailnet: My phone and laptop, joined from the pages under a new name and started"
TAILNET="$RUN-tailnet"
TAILNET_PORT="$(free_port)"
project_new "$TAILNET" "$TAILNET_PORT"
CASE_PROJECT="$TAILNET"
setup_start "$TAILNET"
address="$(setup_address "$TAILNET")"
proof_case tailnet "$address" "$TAILNET_PORT"
setup_wait 120
[ "$SETUP_STATUS" = 0 ] || fail "cyfr setup exited $SETUP_STATUS: $(tail -n 30 "$WORK/$TAILNET.setup.log")"
[ "$(env_value "$TAILNET" CYFR_ACCESS)" = tailnet ] || fail ".env says the home is reached as $(env_value "$TAILNET" CYFR_ACCESS)"
[ "$(env_value "$TAILNET" CYFR_HOST)" = proofhome.proof.ts.net ] || fail ".env's host is $(env_value "$TAILNET" CYFR_HOST)"
[ "$(env_value "$TAILNET" CYFR_PLATFORM_ADMIN_EMAILS)" = operator@example.com ] || fail ".env names the administrators $(env_value "$TAILNET" CYFR_PLATFORM_ADMIN_EMAILS)"
ok "the home is served at https://proofhome.proof.ts.net, and cyfr setup exited 0"

echo
echo "setup proof: passed; the record is $OUT/setup-proof-local.json and $OUT/setup-proof-tailnet.json"
