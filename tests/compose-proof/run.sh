#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof: the shipped docker-compose.yml brought up as a project
# of its own, with the app image built from this tree as the publication
# job builds it (Dockerfile), and what the shipped file promises held on
# the running stack. Its cases:
#
#   bind   cyfr binds its endpoint to its fixed address on the default
#          network (CYFR_BIND_ADDRESS, the role table's endpoint_address)
#          and its host API to its fixed address on the runtime's network,
#          each to that address alone; Docker publishes the host's loopback
#          port to the endpoint, which answers readiness and liveness from
#          the host and through Caddy; and no Locus network reaches the
#          endpoint, while the runtime's network reaches the host API.
#
# The project is the run's own: a unique name, the containers named from
# it, host ports Docker picks on the loopback, a scratch directory holding
# the environment `cyfr init` writes, and `down -v` of that project alone
# when the run ends, however it ends. Nothing of a deployed stack on the
# same host is touched.
#
# Usage: tests/compose-proof/run.sh --case bind
# COMPOSE_PROOF_SKIP_BUILD=1 reuses the image a previous run built
# (cyfr:compose-proof); COMPOSE_PROOF_KEEP=1 keeps the scratch directory.
set -euo pipefail

usage() {
  echo "usage: $0 --case bind" >&2
  exit 2
}

CASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --case)
      CASE="${2:-}"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ "$CASE" = bind ] || usage

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="cyfr:compose-proof"
RUN="cyfr-compose-proof-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-compose-proof-XXXXXX")"
PORT=4000

compose() {
  docker compose --project-name "$RUN" --project-directory "$WORK" \
    -f "$ROOT/docker-compose.yml" -f "$HERE/compose.yml" --profile tls "$@"
}

# The project goes whole, its volumes with it, however the run ends; a
# failed run prints the containers' last lines first.
cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "----- the last lines of the project's logs -----" >&2
    compose logs --no-color --tail 60 cyfr caddy >&2 2>/dev/null || true
  fi
  compose down --volumes --remove-orphans --timeout 30 >/dev/null 2>&1 || true
  if [ "${COMPOSE_PROOF_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    # The entrypoint gave the data and template directories to the image's
    # user; they are taken back before the scratch directory goes.
    docker run --rm --volume "$WORK:/work" --entrypoint chown "$IMAGE" -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

step() { echo; echo "==> $*"; }
ok() { echo "ok: $*"; }
fail() {
  echo "::error::$*" >&2
  exit 1
}

# A field of the role table's vector file (tests/fixtures/locus_roles.json).
table() {
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["release"][sys.argv[2]])' \
    "$ROOT/tests/fixtures/locus_roles.json" "$1"
}

# The addresses the listeners of container `$1` bound on port `$2`, from
# the container's own /proc/net/tcp: one per listening socket, dotted.
listening() {
  docker exec "$1" cat /proc/net/tcp | python3 -I -c '
import sys
port = int(sys.argv[1])
for line in sys.stdin.read().splitlines()[1:]:
    local, state = line.split()[1], line.split()[3]
    address, hex_port = local.split(":")
    if int(hex_port, 16) == port and state == "0A":
        print(".".join(str(int(address[i:i + 2], 16)) for i in (6, 4, 2, 0)))
' "$2"
}

# `curl` from a container of the app image on the project's network `$1`,
# outside cyfr: the status it answers, `refused` where the connection
# failed at once (curl's exit 7: nothing listens at that address, which the
# network reaches), or `error <exit> <message>` for anything else, a
# timeout among them.
from_network() {
  local network="$1" url="$2" out code
  out="$(docker run --rm --network "${RUN}_${network}" --entrypoint curl "$IMAGE" \
    -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>&1)" && { echo "$out"; return; }
  code=$?
  case "$code" in
    7) echo refused ;;
    *) echo "error $code $out" ;;
  esac
}

if [ "${COMPOSE_PROOF_SKIP_BUILD:-}" != 1 ]; then
  step "building the app image from this tree as the publication job does"
  docker build -f "$ROOT/Dockerfile" --build-arg "APT_REFRESH=$(date -u +%F)" -t "$IMAGE" "$ROOT" \
    >"$WORK/build.log" 2>&1 || {
    tail -n 60 "$WORK/build.log" >&2
    fail "the app image did not build"
  }
  ok "built $IMAGE"
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "the image $IMAGE is not built"

step "the project's scratch directory: the environment cyfr init writes"
mkdir -p "$WORK/data" "$WORK/aqua"
cp "$ROOT/apps/locus/keeper/seccomp/keeper.json" "$WORK/keeper.seccomp.json"
{
  echo "CYFR_PORT=$PORT"
  echo "CYFR_HOST=localhost"
  echo "CYFR_BEHIND_PROXY=true"
  echo "CYFR_AUTO_MIGRATE=true"
  echo "CYFR_CORS_ALLOWED_ORIGINS="
  echo "CYFR_SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
  echo "CYFR_LOCUS_BACKENDS_KEY=$(openssl rand -hex 32)"
  echo "CYFR_LOCUS_RUNTIME_ROOT=$(openssl rand -hex 32)"
  echo "LOCUS_RUNTIME_KEY=$(openssl rand -hex 32)"
  echo "LOCUS_RUNTIME_SERVICE_ID=wrk_locus"
  echo "CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100"
  echo "CYFR_LOCUS_BUILDS_KEY=$(openssl rand -hex 32)"
  echo "CYFR_GITHUB_CLIENT_ID=Ov23lib66tiIwXkgUpwm"
  echo "CYFR_PLATFORM_ADMIN_EMAILS=operator@example.com"
  echo "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends"
  echo "COMPOSE_PROOF_IMAGE=$IMAGE"
  echo "COMPOSE_PROOF_CADDYFILE=$HERE/Caddyfile"
} >"$WORK/.env"
ok "wrote $WORK/.env"

step "the stack's promises, read from the shipped file"
endpoint_address="$(table endpoint_address)"
endpoint_network="$(table endpoint_network)"
config="$(compose config --format json)"
read -r host_api_address host_api_port runtime_network <<<"$(printf '%s' "$config" | python3 -I -c '
import json, sys
cyfr = json.load(sys.stdin)["services"]["cyfr"]
env = cyfr["environment"]
fixed = [(name, net["ipv4_address"]) for name, net in cyfr["networks"].items() if net and net.get("ipv4_address")]
runtime = [name for name, address in fixed if address == env["CYFR_HOST_API_BIND"]]
print(env["CYFR_HOST_API_BIND"], env["CYFR_HOST_API_PORT"], runtime[0])
')"
bind_address="$(printf '%s' "$config" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["cyfr"]["environment"]["CYFR_BIND_ADDRESS"])')"
[ "$bind_address" = "$endpoint_address" ] ||
  fail "compose binds the endpoint to $bind_address, not the table's $endpoint_address"
ok "the endpoint binds $endpoint_address on the $endpoint_network network, the host API $host_api_address:$host_api_port on $runtime_network"

step "the island networks exist before cyfr joins them, with IPv6"
# The plain ones, the builds and backends islands' (the runtime's carries
# its own subnet), as they do in a deployment whose island started first,
# or whose cyfr was recreated beside running islands, and with IPv6 on, as
# the image suites' overlays and a dual-stack deployment have them: Docker's
# port mapping must still land on the default network's address. Docker
# maps a published port to the container's address on an IPv6-enabled
# network ahead of an IPv4-only one, whatever the gateway priority, so the
# shipped default network is dual-stack and cyfr's gw_priority on it
# decides; without both, the port answers nothing here.
for network in $(printf '%s' "$config" | python3 -I -c '
import json, sys
project = json.load(sys.stdin)
cyfr = project["services"]["cyfr"]
print(" ".join(name for name in cyfr["networks"]
               if name != sys.argv[1] and not (project["networks"].get(name) or {}).get("ipam")))' "$endpoint_network"); do
  docker network create --ipv6 --label "com.docker.compose.project=$RUN" --label "com.docker.compose.network=$network" \
    --label "com.docker.compose.version=$(docker compose version --short)" "${RUN}_${network}" >/dev/null
  ok "created ${RUN}_${network} first, with IPv6"
done

step "up: cyfr and caddy, as a project of this run's own"
compose up --detach --no-build cyfr caddy
cyfr_id="$(compose ps --quiet cyfr)"
caddy_id="$(compose ps --quiet caddy)"
[ -n "$cyfr_id" ] && [ -n "$caddy_id" ] || fail "compose started no cyfr and caddy"
for _ in $(seq 1 180); do
  health="$(docker inspect --format '{{.State.Health.Status}}' "$cyfr_id")"
  [ "$health" = healthy ] && break
  sleep 1
done
[ "$health" = healthy ] || fail "cyfr is $health after 180 s: the image's probe of CYFR_BIND_ADDRESS never passed"
ok "cyfr is healthy: the image's probe reached the bound address"

step "cyfr holds its two fixed addresses"
got_endpoint="$(docker inspect "$cyfr_id" --format "{{(index .NetworkSettings.Networks \"${RUN}_${endpoint_network}\").IPAddress}}")"
got_host_api="$(docker inspect "$cyfr_id" --format "{{(index .NetworkSettings.Networks \"${RUN}_${runtime_network}\").IPAddress}}")"
[ "$got_endpoint" = "$endpoint_address" ] || fail "cyfr's $endpoint_network address is $got_endpoint, not $endpoint_address"
[ "$got_host_api" = "$host_api_address" ] || fail "cyfr's $runtime_network address is $got_host_api, not $host_api_address"
ok "cyfr is $got_endpoint on $endpoint_network and $got_host_api on $runtime_network"

step "each listener binds its fixed address alone"
bound="$(listening "$cyfr_id" "$PORT")"
[ "$bound" = "$endpoint_address" ] || fail "the endpoint listens on '$bound', not on $endpoint_address alone"
ok "the endpoint listens on $bound alone"
bound="$(listening "$cyfr_id" "$host_api_port")"
[ "$bound" = "$host_api_address" ] || fail "the host API listens on '$bound', not on $host_api_address alone"
ok "the host API listens on $bound alone"

step "Docker publishes the host's loopback port to the endpoint"
published="$(compose port cyfr "$PORT")"
ports="$(docker inspect "$cyfr_id" --format '{{json .NetworkSettings.Ports}}')"
echo "ports: $ports"
printf '%s' "$ports" | python3 -I -c '
import json, sys
ports, port, published = json.load(sys.stdin), sys.argv[1], sys.argv[2]
bindings = ports.get(f"{port}/tcp") or []
host_ip, host_port = published.rsplit(":", 1)
assert any(b["HostIp"] == host_ip == "127.0.0.1" and b["HostPort"] == host_port for b in bindings), (bindings, published)
' "$PORT" "$published" || fail "the endpoint's port is not published on the loopback as $published: $ports"
curl -fsS -m 10 "http://$published/api/health/ready" >"$WORK/ready.json" || fail "GET http://$published/api/health/ready did not answer 200"
ok "GET http://$published/api/health/ready -> 200 $(cat "$WORK/ready.json")"
curl -fsS -m 10 "http://$published/api/health" >"$WORK/health.json" || fail "GET http://$published/api/health did not answer 200"
ok "GET http://$published/api/health -> 200 $(cat "$WORK/health.json")"

step "through Caddy"
front="$(compose port caddy 80)"
answered=""
for _ in $(seq 1 30); do
  if curl -fsS -m 5 "http://$front/api/health/ready" >"$WORK/caddy-ready.json" 2>/dev/null; then
    answered=1
    break
  fi
  sleep 1
done
[ -n "$answered" ] || fail "GET http://$front/api/health/ready through Caddy did not answer 200"
ok "GET http://$front/api/health/ready through Caddy -> 200 $(cat "$WORK/caddy-ready.json")"

step "no Locus network reaches the endpoint; the runtime's network reaches the host API"
for network in $(printf '%s' "$config" | python3 -I -c '
import json, sys
cyfr = json.load(sys.stdin)["services"]["cyfr"]
print(" ".join(name for name in cyfr["networks"] if name != sys.argv[1]))' "$endpoint_network"); do
  answer="$(from_network "$network" "http://cyfr:$PORT/api/health")"
  [ "$answer" = refused ] || fail "the endpoint answered '$answer' to a container on the $network network"
  ok "the endpoint refuses a container on the $network network"
done
answer="$(from_network "$runtime_network" "http://$host_api_address:$host_api_port/")"
case "$answer" in
  [0-9][0-9][0-9]) ok "the host API answers $answer to a container on the $runtime_network network" ;;
  *) fail "the host API answered '$answer' to a container on the $runtime_network network" ;;
esac

echo
echo "compose proof: bind passed"
