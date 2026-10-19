#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The real-tailnet run, by hand: the tailscale image docker-compose.yml
# pins, enrolled in a real tailnet, holds what CYFR relies on it for and
# what the Compose proof's stand-in (tests/compose-proof/tailscale-standin/)
# only reproduces. A pass writes that image's exact reference, tag and
# digest, into tests/tailnet-real/verified-image, which the CI guard
# (guard.sh) holds docker-compose.yml to; this run is reported apart from
# CI and never runs there.
#
# What it needs, none of it committed:
#   TAILNET_REAL_AUTH_KEY_FILE  a file holding a reusable, ephemeral auth key
#                               of the tailnet (so every node the run makes
#                               leaves the tailnet when it goes), for a
#                               tailnet with MagicDNS and HTTPS certificates
#                               on. The key reaches each node on its
#                               standard input alone, as the reach engine
#                               passes one, and is printed nowhere.
#   TAILNET_REAL_SHARED_LOGIN   optional: the login of another account the
#                               run's machine is shared with during the
#                               run: the run waits, telling the operator
#                               what to do, for a request from that account
#                               through Serve. Unset, the sharing check is
#                               skipped and the run says so at its end:
#                               sharing is Tailscale's feature, not CYFR's,
#                               and one account is what a person has.
#
# The run, against a stand-in upstream answering as cyfr (the stand-in's
# echo) and a second node of the same key as the tailnet's device, through
# that node's userspace HTTP proxy:
#
#   enrollment  the machine joins with the key: Running, its DNSName in the
#               tailnet's MagicDNS suffix (with the trailing dot), its node
#               id within CYFR's grammar (1 to 128 of [A-Za-z0-9._-]), its
#               name its certificate domain; the device reaches
#               https://<name>/ with the certificate a public authority
#               issued for the name
#   serve       under `{}` the machine refuses 443 while it answers the
#               device on its PeerAPI; under the engine's configuration a
#               forged GET /probe?q=1 answers 200 and the upstream gets it
#               with the client's Host, the device's tailnet address as
#               X-Forwarded-For, https as X-Forwarded-Proto, the name as
#               X-Forwarded-Host, no Forwarded, and of the identity headers
#               serve.go deletes or sets exactly the device's own, none of
#               the forged ones (none at all for a tagged device); back to
#               `{}` Serve closes; and the container started again with no
#               serve file serves nothing of what the state held
#   load        userspace networking under load: every one of 200 requests
#               through Serve, eight at a time, answers 200
#   node id     the id is the same across a restart of the container on the
#               same state, and another after the machine leaves and joins
#               again
#   sharing     with TAILNET_REAL_SHARED_LOGIN set, a request from that
#               account reaches the upstream through Serve, with that
#               account's identity headers
#   rejoin      `tailscale logout` leaves the tailnet (NeedsLogin), and the
#               key joins it again as a new node, which Serve serves once its
#               configuration names it
#
# A probe's answer is read as `standin fetch` names it, so a failed probe
# is never a closed Serve: Serve is closed only where the machine itself
# refused the device's tunnel to 443 at its tailnet address and, in the
# same ask, answered the device on its PeerAPI there through the same
# proxy (`serve_closed`). What Serve sends the upstream is held whole
# (`identity_projection`): the method, path, query and Host, the
# forwarding headers, and every identity header the pinned serve.go
# deletes or sets, each with the value the device's identity gives it,
# none for a tagged device. The predicates are
# tests/tailnet-real/predicates-test.sh's, on canned answers.
#
# Usage: TAILNET_REAL_AUTH_KEY_FILE=… [TAILNET_REAL_SHARED_LOGIN=…] tests/tailnet-real/run.sh
# Needs docker with a daemon that reaches the internet, go and python3.
# Everything it makes is named for the run and removed when it ends, its
# nodes logged out first. Sourced, it defines its predicates and runs
# nothing.
step() { printf '\n=== %s\n' "$*"; }
ok() { printf 'ok    %s\n' "$*"; }
fail() {
  echo "::error::$*" >&2
  exit 1
}

jget() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
value = json.load(sys.stdin)
for step in sys.argv[1:]:
    if isinstance(value, list):
        value = value[int(step)] if -len(value) <= int(step) < len(value) else None
    else:
        value = value.get(step) if isinstance(value, dict) else None
print(value if isinstance(value, str) else json.dumps(value))' "${@:2}"
}

# Whether a Serve port is closed, from the device's two answers of one ask
# (`standin fetch` JSON): `$1` its PeerAPI control, which must be an answer
# of the machine's, any status, and `$2` the Serve port, which the machine
# itself must have refused (error refused, which fetch gives only for a
# refusal at the address and port it asked for). A probe that failed at
# TLS, at DNS, at the device's proxy or anywhere else is no closed Serve.
# On failure, says why on stdout.
serve_closed() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys
def parsed(text):
    try:
        value = json.loads(text)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}
control, target = parsed(sys.argv[1]), parsed(sys.argv[2])
if not isinstance(control.get("status"), int):
    sys.exit(print(f"the machine's PeerAPI did not answer the device: {sys.argv[1] or 'nothing'}") or 1)
if target.get("error") != "refused":
    sys.exit(print(f"the Serve port was not refused by the machine: {sys.argv[2] or 'nothing'}") or 1)
PY
}

# Whether what Serve sent the upstream for the device's forged request
# GET /probe?q=1 to `$4` is the pinned image's projection, from the
# device's answer `$1` (`standin fetch` JSON, its body the echo's), the
# machine's `tailscale status --json` `$2` and the device's address `$3`:
# a 200; GET, /probe, q=1 and the Host `$4`; X-Forwarded-For the device's
# address, -Proto https and -Host `$4`, each alone, and no Forwarded; and,
# of Tailscale-User-Login, -Name, -Profile-Pic, Tailscale-Funnel-Request,
# Tailscale-Headers-Info and Tailscale-App-Capabilities, for a device of a
# user exactly the first two Q-encoded as serve.go encodes them
# (encTailscaleHeaderValue), its profile picture URL and the headers-info
# link, from the user the machine's status names for the device, and for a
# tagged device none. On failure, says what differs on stdout.
identity_projection() {
  python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
UPPER = "0123456789ABCDEF"
def q_encoded(v):
    # mime.QEncoding.Encode("utf-8", v), as Go writes it.
    if not any((c < " " or c > "~") and c != "\t" for c in v):
        return v
    out, length, word = [], 0, "=?utf-8?q?"
    for ch in v:
        b = ch.encode("utf-8")
        n = 1 if len(b) == 1 and " " <= ch <= "~" and ch not in "=?_" else 3 * len(b)
        if length + n > 75 - len("=?UTF-8?q?") - len("?="):
            word += "?= =?utf-8?q?"
            length = 0
        for x in b:
            c = chr(x)
            word += "_" if c == " " else c if "!" <= c <= "~" and c not in "=?_" else "=" + UPPER[x >> 4] + UPPER[x & 15]
        length += n
    return word + "?="
FORWARDING = ["X-Forwarded-For", "X-Forwarded-Proto", "X-Forwarded-Host", "Forwarded"]
IDENTITY = ["Tailscale-User-Login", "Tailscale-User-Name", "Tailscale-User-Profile-Pic",
            "Tailscale-Funnel-Request", "Tailscale-Headers-Info", "Tailscale-App-Capabilities"]
problems = []
try:
    answer, status = json.loads(sys.argv[1]), json.loads(sys.argv[2])
except ValueError as error:
    sys.exit(print(f"no answer or status to read: {error}") or 1)
device_ip, name = sys.argv[3], sys.argv[4]
if answer.get("status") != 200:
    sys.exit(print(f"Serve answered {answer.get('status', answer.get('error'))}, not 200: {sys.argv[1]}") or 1)
try:
    seen = json.loads(answer.get("body") or "")
except ValueError:
    sys.exit(print(f"the upstream's answer is not the echo's: {answer.get('body')!r}") or 1)
for key, want in (("method", "GET"), ("path", "/probe"), ("query", "q=1"), ("host", name)):
    if seen.get(key) != want:
        problems.append(f"{key} reached the upstream as {seen.get(key)!r}, not {want!r}")
peers = [p for p in (status.get("Peer") or {}).values() if device_ip in (p.get("TailscaleIPs") or [])]
if len(peers) != 1:
    sys.exit(print(f"the machine's status names {len(peers)} peers at {device_ip}, not one") or 1)
peer = peers[0]
want = {"X-Forwarded-For": [device_ip], "X-Forwarded-Proto": ["https"], "X-Forwarded-Host": [name]}
if not peer.get("Tags"):
    user = (status.get("User") or {}).get(str(peer.get("UserID")))
    if not user:
        sys.exit(print(f"the machine's status names no user {peer.get('UserID')} for the device") or 1)
    want.update({
        "Tailscale-User-Login": [q_encoded(user.get("LoginName", ""))],
        "Tailscale-User-Name": [q_encoded(user.get("DisplayName", ""))],
        "Tailscale-User-Profile-Pic": [user.get("ProfilePicURL", "")],
        "Tailscale-Headers-Info": ["https://tailscale.com/s/serve-headers"],
    })
headers = seen.get("headers") or {}
got = {k: headers[k] for k in FORWARDING + IDENTITY if k in headers}
if got != want:
    problems.append(f"the forwarding and identity headers reached the upstream as {json.dumps(got, sort_keys=True)}, not {json.dumps(want, sort_keys=True)}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}

# The forged request the identity probe sends: every forwarding and
# identity header a client could squat, each with an attacker's value.
FORGED_HEADERS=(
  --header "X-Forwarded-For: 203.0.113.9" --header "X-Forwarded-Proto: http"
  --header "X-Forwarded-Host: evil.example" --header "Forwarded: for=198.51.100.1"
  --header "Tailscale-User-Login: admin@evil.example" --header "Tailscale-User-Name: Forged"
  --header "Tailscale-User-Profile-Pic: https://evil.example/p.png" --header "Tailscale-Funnel-Request: ?1"
  --header "Tailscale-Headers-Info: https://evil.example/info" --header 'Tailscale-App-Capabilities: {"evil.example/cap":[{}]}'
)

# Sourced (tests/tailnet-real/predicates-test.sh), the script defines the
# functions above and runs nothing.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="cyfr-tailnet-real-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-tailnet-real-XXXXXX")"
STANDIN="cyfr-tailscale-standin:$RUN"
UPSTREAM_PORT=4123
LOAD_REQUESTS=200
LOAD_PARALLEL=8
SHARING_WAIT=600
JOIN_ENV=(-e TS_USERSPACE=true -e TS_STATE_DIR=/var/lib/tailscale -e TS_AUTH_ONCE=true
  -e TS_ACCEPT_DNS=false -e TS_SOCKET=/var/run/tailscale/tailscaled.sock)


key_file="${TAILNET_REAL_AUTH_KEY_FILE:-}"
shared_login="${TAILNET_REAL_SHARED_LOGIN:-}"
[ -n "$key_file" ] && [ -r "$key_file" ] && [ -s "$key_file" ] ||
  fail "TAILNET_REAL_AUTH_KEY_FILE names no readable auth key file: the run needs a reusable, ephemeral key of a real tailnet"
if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then fail "no Docker daemon this user can reach"; fi

# The tailscale service's image, as docker-compose.yml names it.
IMAGE="$(awk '
  /^  tailscale:[[:space:]]*$/ { in_service = 1; next }
  in_service && /^  [^ #]/ { exit }
  in_service && /^    image:/ { sub(/^    image:[[:space:]]*/, ""); print; exit }
' "$ROOT/docker-compose.yml")"
[[ "$IMAGE" =~ ^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] ||
  fail "docker-compose.yml's tailscale image '$IMAGE' is not a reference by tag and digest"

NODES=()
cleanup() {
  local code=$? node ids
  for node in ${NODES[@]+"${NODES[@]}"}; do
    docker exec "$node" tailscale logout >/dev/null 2>&1 || true
  done
  ids="$(docker ps -aq --filter "name=^$RUN-" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker rm -f -v $ids >/dev/null 2>&1 || true
  docker network rm "$RUN-net" >/dev/null 2>&1 || true
  ids="$(docker volume ls -q --filter "name=^$RUN-" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker volume rm -f $ids >/dev/null 2>&1 || true
  docker image rm -f "$STANDIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


# `tailscale status --json` of container `$1` once BackendState is `$2`,
# within `$3` seconds.
await_state() {
  local closes=$((SECONDS + $3)) out=""
  while [ "$SECONDS" -lt "$closes" ]; do
    out="$(docker exec "$1" tailscale status --json 2>/dev/null || true)"
    if [ -n "$out" ] && [ "$(jget "$out" BackendState)" = "$2" ]; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 1
  done
  fail "$1 is not $2 within $3 s: ${out:-no status}"
}

# A node: container `$RUN-$1` of the pinned image on the run's network,
# its state on the volume `$RUN-$2`, joining with the key on its standard
# input as the reach engine passes one, and `$3...` further `docker run`
# arguments. Its client stays attached in the background, its output in
# `$WORK/$1.log`, until the run removes the container.
node() {
  local name="$RUN-$1" volume="$RUN-$2" log="$WORK/$1.log" closes=$((SECONDS + 60))
  shift 2
  docker run -i --name "$name" --network "$RUN-net" -v "$volume:/var/lib/tailscale" "${JOIN_ENV[@]}" "$@" "$IMAGE" \
    sh -c 'IFS= read -r TS_AUTHKEY && export TS_AUTHKEY && exec containerboot' <"$key_file" >"$log" 2>&1 &
  NODES+=("$name")
  until [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ]; do
    [ "$SECONDS" -lt "$closes" ] || fail "the node $name did not start: $(tail -n 5 "$log")"
    sleep 1
  done
}

# The machine's PeerAPI URL on its IPv4 tailnet address, from its status
# `$1`: the control every Serve-closed ask makes beside the Serve port.
peer_api() {
  python3 -I -c '
import json, re, sys
urls = [u for u in (json.loads(sys.argv[1]).get("Self") or {}).get("PeerAPIURL") or []
        if re.fullmatch(r"http://\d+\.\d+\.\d+\.\d+:\d+", u)]
sys.exit(print(urls[0]) if urls else 1)' "$1"
}

# Whether Serve is closed for https://`$1`/ now: the device's ask of the
# machine's PeerAPI `$2` and of the Serve port at the PeerAPI's own
# address, through the same proxy (`serve_closed`); says why not on
# stdout. The tunnel names the address, so the refusal fetch reads is the
# machine's at that address and port, never a name the proxy resolved.
closed_now() {
  local address="${2#http://}"
  address="${address%:*}"
  serve_closed "$(device "$2/")" "$(device --connect "$address:443" "https://$1/")"
}

# Serve closed for https://`$1`/ at each of five asks two seconds apart,
# the machine answering its PeerAPI `$2` at each: what a configuration
# Serve must not apply leaves.
serves_nothing() {
  local i why
  for i in 1 2 3 4 5; do
    why="$(closed_now "$1" "$2")" || { echo "$why"; return 1; }
    [ "$i" -eq 5 ] || sleep 2
  done
}

serve_file() {
  printf '%s' "$2" >"$1.tmp"
  mv "$1.tmp" "$1"
}

# A request from the tailnet's device: `standin fetch` through its
# userspace HTTP proxy, trusting the system's public authorities, with
# `$@`.
device() {
  docker run --rm --network "$RUN-net" "$STANDIN" standin fetch --proxy "http://$RUN-device:1055" "$@" || true
}

step "the pinned image, the stand-in's echo and the run's network"
docker pull -q "$IMAGE" >/dev/null || fail "the pinned image $IMAGE could not be pulled"
"$ROOT/tests/compose-proof/tailscale-standin/build.sh" image "$STANDIN"
docker network create "$RUN-net" >/dev/null
docker run -d --name "$RUN-upstream" --network "$RUN-net" --network-alias cyfr "$STANDIN" \
  standin echo --listen ":$UPSTREAM_PORT" >/dev/null
mkdir -p "$WORK/serve"
serve_file "$WORK/serve/serve.json" '{}'
# The engine's serve configuration, on the echo's port; ${TS_CERT_DOMAIN}
# is containerboot's to replace.
# shellcheck disable=SC2016
CONFIG='{"TCP":{"443":{"HTTPS":true}},"Web":{"${TS_CERT_DOMAIN}:443":{"Handlers":{"/":{"Proxy":"http://cyfr:'"$UPSTREAM_PORT"'"}}}}}'
ok "$IMAGE, the echo answering as cyfr:$UPSTREAM_PORT"

step "enrollment: the machine joins with the key, and the device beside it"
host="cyfr-verify-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
node machine machine-state -e "TS_HOSTNAME=$host" -e TS_SERVE_CONFIG=/serve/serve.json -v "$WORK/serve:/serve:ro"
node device device-state -e "TS_HOSTNAME=$host-device" -e TS_OUTBOUND_HTTP_PROXY_LISTEN=0.0.0.0:1055
status="$(await_state "$RUN-machine" Running 180)"
device_status="$(await_state "$RUN-device" Running 180)"
name="$(jget "$status" Self DNSName)"
id="$(jget "$status" Self ID)"
suffix="$(jget "$status" CurrentTailnet MagicDNSSuffix)"
[[ "$name" == *".$suffix." ]] && [[ "$suffix" == *.ts.net ]] || fail "the machine's DNSName '$name' is not in the tailnet's MagicDNS suffix '$suffix' with the dot"
name="${name%.}"
[[ "$id" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || fail "the machine's node id '$id' is outside CYFR's grammar"
[ "$(jget "$status" CertDomains 0)" = "$name" ] || fail "the machine's certificate domains are $(jget "$status" CertDomains), not $name: HTTPS certificates must be on for the tailnet"
device_ip="$(jget "$device_status" Self TailscaleIPs 0)"
peerapi="$(peer_api "$status")" || fail "the machine's status names no PeerAPI URL on an IPv4 address: $(jget "$status" Self PeerAPIURL)"
ok "the machine is $name ($id), its certificate domain its name, its PeerAPI $peerapi; the device is $device_ip"

step "serve: nothing under {}, the engine's configuration forwards as Serve does"
why="$(serves_nothing "$name" "$peerapi")" || fail "under {}, Serve is not closed for https://$name/: $why"
ok "under {}, the machine refuses https://$name/ and answers its PeerAPI"
serve_file "$WORK/serve/serve.json" "$CONFIG"
closes=$((SECONDS + 120))
until [ "$(jget "$(device "https://$name/probe")" status)" = 200 ]; do
  [ "$SECONDS" -lt "$closes" ] || fail "under the configuration, https://$name/ did not answer 200 within 120 s"
  sleep 2
done
answer="$(device "${FORGED_HEADERS[@]}" "https://$name/probe?q=1")"
machine_status="$(docker exec "$RUN-machine" tailscale status --json)"
why="$(identity_projection "$answer" "$machine_status" "$device_ip" "$name")" ||
  fail "what Serve sent the upstream is not the pinned image's: $why"
ok "Serve answers 200, keeps GET /probe?q=1 and the Host, sets X-Forwarded-For to $device_ip, -Proto and -Host, drops Forwarded, and sends exactly the device's own identity headers, none of the forged ones"
serve_file "$WORK/serve/serve.json" '{}'
closes=$((SECONDS + 60))
until why="$(closed_now "$name" "$peerapi")"; do
  [ "$SECONDS" -lt "$closes" ] || fail "after {}, Serve is not closed for https://$name/: $why"
  sleep 2
done
ok "{} closes Serve: the machine refuses https://$name/ and answers its PeerAPI"

step "node id: the same across a restart; no serve file serves nothing the state held"
serve_file "$WORK/serve/serve.json" "$CONFIG"
closes=$((SECONDS + 120))
until [ "$(jget "$(device "https://$name/")" status)" = 200 ]; do
  [ "$SECONDS" -lt "$closes" ] || fail "the configuration did not serve again within 120 s"
  sleep 2
done
docker rm -f "$RUN-machine" >/dev/null
rm -f "$WORK/serve/serve.json"
docker run -d --name "$RUN-machine" --network "$RUN-net" -v "$RUN-machine-state:/var/lib/tailscale" \
  -v "$WORK/serve:/serve:ro" "${JOIN_ENV[@]}" -e TS_SERVE_CONFIG=/serve/serve.json "$IMAGE" >/dev/null
status="$(await_state "$RUN-machine" Running 180)"
[ "$(jget "$status" Self ID)" = "$id" ] || fail "the restarted machine is $(jget "$status" Self ID), not $id"
peerapi="$(peer_api "$status")" || fail "the restarted machine's status names no PeerAPI URL on an IPv4 address"
why="$(serves_nothing "$name" "$peerapi")" || fail "started again with no serve file, Serve is not closed for https://$name/: $why"
ok "the restarted machine keeps its id $id, and with no serve file serves nothing"

step "load: $LOAD_REQUESTS requests through Serve, $LOAD_PARALLEL at a time"
serve_file "$WORK/serve/serve.json" "$CONFIG"
closes=$((SECONDS + 120))
until [ "$(jget "$(device "https://$name/")" status)" = 200 ]; do
  [ "$SECONDS" -lt "$closes" ] || fail "the configuration did not serve again within 120 s"
  sleep 2
done
docker run --rm --network "$RUN-net" --entrypoint sh "$STANDIN" -c '
  n=0 failed=0
  while [ "$n" -lt "$1" ]; do
    i=0
    while [ "$i" -lt "$2" ]; do
      standin fetch --proxy "$3" "$4" | grep -q "\"status\":200" || echo fail &
      i=$((i + 1))
    done
    wait
    n=$((n + $2))
  done' sh "$LOAD_REQUESTS" "$LOAD_PARALLEL" "http://$RUN-device:1055" "https://$name/load" >"$WORK/load.out"
[ ! -s "$WORK/load.out" ] || fail "$(grep -c fail "$WORK/load.out") of $LOAD_REQUESTS requests through Serve did not answer 200"
ok "$LOAD_REQUESTS of $LOAD_REQUESTS answered 200"

if [ -n "$shared_login" ]; then
  step "sharing: a request from $shared_login through Serve"
  echo "Share $name with $shared_login on the Machines page of the admin console, then open https://$name/shared from a device of that account. Waiting up to $SHARING_WAIT s."
  closes=$((SECONDS + SHARING_WAIT))
  until docker logs "$RUN-upstream" 2>&1 | python3 -I -c '
import json, sys
login = sys.argv[1]
for line in sys.stdin:
    try:
        seen = json.loads(line)
    except ValueError:
        continue
    if seen.get("path") == "/shared" and seen.get("headers", {}).get("Tailscale-User-Login") == [login]:
        sys.exit(0)
sys.exit(1)' "$shared_login"; do
    [ "$SECONDS" -lt "$closes" ] || fail "no request from $shared_login reached https://$name/shared within $SHARING_WAIT s"
    sleep 5
  done
  ok "a request from $shared_login reached the upstream through Serve, as $shared_login"
fi

step "rejoin: the machine leaves the tailnet and joins again as a new node"
docker exec "$RUN-machine" tailscale logout >/dev/null || fail "tailscale logout failed"
await_state "$RUN-machine" NeedsLogin 120 >/dev/null
docker rm -f "$RUN-machine" >/dev/null
node machine2 machine2-state -e "TS_HOSTNAME=$host" -e TS_SERVE_CONFIG=/serve/serve.json -v "$WORK/serve:/serve:ro"
status="$(await_state "$RUN-machine2" Running 180)"
id2="$(jget "$status" Self ID)"
name2="$(jget "$status" Self DNSName)"
name2="${name2%.}"
[ "$id2" != "$id" ] || fail "the machine joined again as the same node, $id"
[[ "$id2" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || fail "the new node id '$id2' is outside CYFR's grammar"
closes=$((SECONDS + 180))
until [ "$(jget "$(device "https://$name2/")" status)" = 200 ]; do
  [ "$SECONDS" -lt "$closes" ] || fail "the new node $name2 was not served within 180 s"
  sleep 2
done
ok "after leaving, the machine joined again as $name2 ($id2), and Serve serves it"

step "every check held: $IMAGE is verified"
printf '%s\n' "$IMAGE" >"$ROOT/tests/tailnet-real/verified-image"
echo "wrote tests/tailnet-real/verified-image: $IMAGE"
[ -n "$shared_login" ] || echo "the sharing check was skipped: TAILNET_REAL_SHARED_LOGIN is unset"
