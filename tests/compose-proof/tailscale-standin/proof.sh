#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Tailscale stand-in's own proof (main.go): it does what the Compose
# proof relies on it for, as tailscale/tailscale v1.104.1 does, and breaking
# any of that (`standin mutations`) fails this proof. No CYFR runs: the
# upstream is the stand-in's echo, answering as cyfr on a network of this
# run's own, and the client is its fetch. It does not certify a Tailscale
# binary; tests/tailnet-real/run.sh asserts the same against the pinned
# image on a real tailnet.
#
#   unit       go vet, gofmt and go test of the module, and the tests fail
#              under every mutation
#   image      the image build.sh builds, run as CYFR's reach engine runs
#              the pinned image:
#                a join container (no TS_SERVE_CONFIG, its own deadline in
#                `timeout -s TERM <seconds> containerboot`) waits in
#                NeedsLogin with an approval link and is unhealthy; approved,
#                it is Running with its name (DNSName with the dot), a node
#                id and the name as its certificate domain; unapproved, it
#                ends at its deadline;
#                an auth key on standard input logs a fresh volume in, and
#                the key is in no argument, no environment and no state;
#                the serve container (TS_SERVE_CONFIG) serves nothing under
#                `{}`, serves HTTPS for the name under the engine's
#                configuration, keeps the client's Host, sets
#                X-Forwarded-For to the client's address and -Proto and
#                -Host replacing the client's, drops Forwarded, deletes the
#                client's Tailscale-User-Login, -Name and -Profile-Pic and
#                sets its own, sets none for a tagged peer, passes another
#                Tailscale-User-* header, presents no certificate for
#                another name, passes the upstream's own status, skips an
#                empty file, applies no HTTPS while the tailnet has HTTPS
#                off, and, started again with no file, serves nothing the
#                state held
#   mutations  each mutation's program, mounted over the image's, fails the
#              image checks, naming the check
#
# Usage: tests/compose-proof/tailscale-standin/proof.sh
# Needs go, docker with a daemon it can reach, and python3; without one it
# names it and exits 77, which is neither a pass nor a failure. Every
# container, network, volume and image it makes is named for this run and
# removed when it ends, however it ends.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="cyfr-standin-proof-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
IMAGE="cyfr-tailscale-standin:$RUN"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-standin-proof-XXXXXX")"
# The port the echo answers as cyfr on, as the engine's configuration
# names cyfr's proxy listener port.
UPSTREAM_PORT=4123
NAME=cyfr.proof.ts.net
# The engine's serve configuration for a node, here on the echo's port;
# ${TS_CERT_DOMAIN} is containerboot's to replace.
# shellcheck disable=SC2016
CONFIG='{"TCP":{"443":{"HTTPS":true}},"Web":{"${TS_CERT_DOMAIN}:443":{"Handlers":{"/":{"Proxy":"http://cyfr:'"$UPSTREAM_PORT"'"}}}}}'
JOIN_ENV=(-e TS_USERSPACE=true -e TS_STATE_DIR=/var/lib/tailscale -e TS_AUTH_ONCE=true
  -e TS_ACCEPT_DNS=false -e TS_SOCKET=/var/run/tailscale/tailscaled.sock)

missing() {
  echo "missing prerequisite: $*" >&2
  echo "the stand-in's proof did not run (exit 77); this is not a pass" >&2
  exit 77
}
command -v go >/dev/null 2>&1 || missing "go (the stand-in is built from its module)"
command -v python3 >/dev/null 2>&1 || missing "python3"
command -v docker >/dev/null 2>&1 || missing "docker"
docker info >/dev/null 2>&1 || missing "a Docker daemon this user can reach (docker info failed)"

# Every container, network and volume whose name begins `$1`, removed.
discard() {
  local ids
  ids="$(docker ps -aq --filter "name=^$1" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker rm -f -v $ids >/dev/null 2>&1 || true
  ids="$(docker network ls -q --filter "name=^$1" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker network rm $ids >/dev/null 2>&1 || true
  ids="$(docker volume ls -q --filter "name=^$1" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker volume rm -f $ids >/dev/null 2>&1 || true
}

cleanup() {
  local code=$?
  discard "$RUN-"
  docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step() { printf '\n=== %s\n' "$*"; }
ok() { printf 'ok    %s\n' "$*"; }
# A failed check: the message on stderr, and the check's status 1. Inside
# `checks` it ends the run of checks (errexit), which is how a mutation's
# run reports the check it broke.
nope() {
  echo "::error::$*" >&2
  return 1
}

# The value at path `$2...` of the JSON `$1`: a string as itself, anything
# else as JSON.
jget() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
value = json.load(sys.stdin)
for step in sys.argv[1:]:
    value = value[int(step)] if isinstance(value, list) else value.get(step) if isinstance(value, dict) else None
print(value if isinstance(value, str) else json.dumps(value))' "${@:2}"
}

# `tailscale status --json` of container `$1`, once it says BackendState
# `$2`, within `$3` seconds (default 30).
await_status() {
  local container="$1" state="$2" closes=$((SECONDS + ${3:-30})) out=""
  while [ "$SECONDS" -lt "$closes" ]; do
    out="$(docker exec "$container" tailscale status --json 2>/dev/null)" || out=""
    if [ -n "$out" ] && [ "$(jget "$out" BackendState)" = "$state" ]; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 0.2
  done
  nope "$container is not $state within ${3:-30} s: ${out:-no status}"
}

# The serve configuration container `$1`'s tailscaled holds, once it
# matches the Python predicate `$2` over `c` (the parsed configuration),
# within 15 s.
await_serving() {
  local container="$1" predicate="$2" closes=$((SECONDS + 15)) out=""
  while [ "$SECONDS" -lt "$closes" ]; do
    out="$(docker exec "$container" standin serving 2>/dev/null)" || out=""
    if [ -n "$out" ] && printf '%s' "$out" | python3 -I -c "import json, sys; c = json.load(sys.stdin); sys.exit(0 if ($predicate) else 1)"; then
      return 0
    fi
    sleep 0.2
  done
  nope "$container's serve configuration is not ($predicate) within 15 s: ${out:-none}"
}

# Container `$1` is gone within `$2` seconds.
await_gone() {
  local closes=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$closes" ]; do
    docker inspect "$1" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  nope "$1 still runs after $2 s"
}

# Container `$1`'s serve configuration stays as the Python predicate `$2`
# says through two seconds, ten of containerboot's reads: what a change it
# must skip leaves.
stays_serving() {
  local container="$1" predicate="$2" until=$((SECONDS + 2)) out
  while [ "$SECONDS" -le "$until" ]; do
    out="$(docker exec "$container" standin serving)"
    printf '%s' "$out" | python3 -I -c "import json, sys; c = json.load(sys.stdin); sys.exit(0 if ($predicate) else 1)" ||
      nope "$container's serve configuration changed to $out, where it is ($predicate)"
    sleep 0.2
  done
}

# Writes the serve file `$1` as the engine writes it: whole, then renamed
# into place.
serve_file() {
  printf '%s' "$2" >"$1.tmp"
  mv "$1.tmp" "$1"
}

# The image checks, on resources named `$RUN-$1`, with the program `$2`
# mounted over the image's when given. The upstream and the client run the
# image's own program. Ends at the first check that fails.
checks() {
  local p="$RUN-$1" bin="${2:-}" status id key state ts_ip client_ip answer serve_dir
  local -a mount=()
  [ -z "$bin" ] || mount=(-v "$bin:/usr/local/bin/standin:ro")
  docker network create "$p-net" >/dev/null
  docker network create --internal "$p-join" >/dev/null
  docker volume create "$p-a" >/dev/null
  docker volume create "$p-b" >/dev/null
  docker volume create "$p-c" >/dev/null

  docker run -d --name "$p-up" --network "$p-net" --network-alias cyfr "$IMAGE" \
    standin echo --listen ":$UPSTREAM_PORT" >/dev/null
  docker run -d --name "$p-client" --network "$p-net" "$IMAGE" sleep 3600 >/dev/null
  client_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$p-net\").IPAddress}}" "$p-client")"
  local closes=$((SECONDS + 30))
  until docker exec "$p-client" standin fetch "http://cyfr:$UPSTREAM_PORT/" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$closes" ] || nope "the echo never answered as cyfr:$UPSTREAM_PORT"
    sleep 0.2
  done

  # A join, as the engine starts one for a person's approval.
  docker run -d --rm --name "$p-join1" --network "$p-join" -v "$p-a:/var/lib/tailscale" \
    "${JOIN_ENV[@]}" -e TS_HOSTNAME=cyfr ${mount[@]+"${mount[@]}"} "$IMAGE" \
    timeout -s TERM 60 containerboot >/dev/null
  status="$(await_status "$p-join1" NeedsLogin)"
  [[ "$(jget "$status" AuthURL)" == https://login.proof.ts.net/a/* ]] ||
    nope "a machine waiting for approval offers no approval link: $status"
  [ "$(jget "$status" Self ID)" = "" ] || nope "a machine waiting for approval has a node id: $status"
  ! docker exec "$p-join1" tailscale status >/dev/null 2>&1 ||
    nope "the healthcheck (tailscale status) passes on a machine that is not logged in"
  docker exec "$p-join1" standin approve >/dev/null
  status="$(await_status "$p-join1" Running)"
  [ "$(jget "$status" Self DNSName)" = "$NAME." ] || nope "the approved machine's DNSName is not $NAME.: $status"
  id="$(jget "$status" Self ID)"
  [[ "$id" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || nope "the approved machine's node id '$id' is outside CYFR's grammar"
  [ "$(jget "$status" CertDomains)" = "[\"$NAME\"]" ] || nope "the approved machine's certificate domains are not [$NAME]: $status"
  docker exec "$p-join1" tailscale status >/dev/null || nope "the healthcheck fails on a Running machine"
  ok "a join waits in NeedsLogin with its link, and approved is Running as $NAME ($id), its name its certificate domain"
  docker stop -t 5 "$p-join1" >/dev/null
  await_gone "$p-join1" 15

  docker run -d --rm --name "$p-join3" --network "$p-join" -v "$p-c:/var/lib/tailscale" \
    "${JOIN_ENV[@]}" -e TS_HOSTNAME=cyfr ${mount[@]+"${mount[@]}"} "$IMAGE" \
    timeout -s TERM 3 containerboot >/dev/null
  await_gone "$p-join3" 20
  ok "a join nobody approves ends at its own deadline"

  # A join with an auth key on standard input, as the engine passes one.
  key="tskey-auth-proof$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  (printf '%s\n' "$key" | docker run -i --rm --name "$p-join2" --network "$p-join" \
    -v "$p-b:/var/lib/tailscale" "${JOIN_ENV[@]}" -e TS_HOSTNAME=cyfr ${mount[@]+"${mount[@]}"} "$IMAGE" \
    timeout -s TERM 30 sh -c 'IFS= read -r TS_AUTHKEY && export TS_AUTHKEY && exec containerboot' \
    >"$WORK/$1-join2.log" 2>&1) &
  status="$(await_status "$p-join2" Running)"
  [ "$(jget "$status" Self DNSName)" = "$NAME." ] || nope "the auth key logged the machine in as another name: $status"
  if docker inspect "$p-join2" | grep -qF -- "$key"; then nope "the auth key is in the join container's configuration"; fi
  state="$(docker exec "$p-join2" standin state)"
  if printf '%s' "$state" | grep -qF -- "$key"; then nope "the auth key is in the machine's state"; fi
  [ "$(jget "$state" auth_key_sha256)" = "$(printf '%s' "$key" | sha256sum | cut -c1-64)" ] ||
    nope "the machine did not log in with the key it was given on standard input"
  ok "an auth key on standard input logs a fresh volume in, and is in no argument, environment or state"
  docker stop -t 5 "$p-join2" >/dev/null
  await_gone "$p-join2" 15
  wait

  # The serve container on node A's volume, the file `{}` as the engine
  # writes it before every start.
  serve_dir="$WORK/$1-serve"
  mkdir -p "$serve_dir"
  serve_file "$serve_dir/serve.json" '{}'
  docker run -d --name "$p-ts" --network "$p-net" -v "$p-a:/var/lib/tailscale" -v "$serve_dir:/serve:ro" \
    "${JOIN_ENV[@]}" -e TS_SERVE_CONFIG=/serve/serve.json ${mount[@]+"${mount[@]}"} "$IMAGE" >/dev/null
  status="$(await_status "$p-ts" Running)"
  [ "$(jget "$status" Self ID)" = "$id" ] || nope "the serve container is not the node the volume holds: $status"
  ts_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$p-net\").IPAddress}}" "$p-ts")"
  docker exec "$p-ts" standin ca >"$WORK/$1-ca.pem"
  docker cp "$WORK/$1-ca.pem" "$p-client:/ca.pem"
  serve() { docker exec "$p-client" standin fetch --ca /ca.pem --connect "$ts_ip:443" "$@" || true; }
  await_serving "$p-ts" 'c == {}'
  answer="$(serve "https://$NAME/")"
  [ "$(jget "$answer" error)" = refused ] || nope "under {}, Serve answers: $answer"
  ok "under {}, nothing listens"

  serve_file "$serve_dir/serve.json" "$CONFIG"
  await_serving "$p-ts" "'$NAME:443' in c.get('Web', {})"
  answer="$(serve --header "X-Forwarded-For: 203.0.113.9" --header "X-Forwarded-Proto: http" \
    --header "X-Forwarded-Host: evil.example" --header "Forwarded: for=198.51.100.1" \
    --header "Tailscale-User-Login: admin@evil.example" --header "Tailscale-User-Name: Forged" \
    --header "Tailscale-User-Profile-Pic: https://evil.example/p.png" \
    --header "Tailscale-Funnel-Request: ?1" --header "Tailscale-App-Capabilities: {}" \
    --header "Tailscale-User-Other: passes" "https://$NAME/probe?q=1")"
  [ "$(jget "$answer" status)" = 200 ] || nope "under the configuration, Serve answers: $answer"
  local seen
  seen="$(jget "$answer" body)"
  [ "$(jget "$seen" host)" = "$NAME" ] || nope "Host reached the upstream as $(jget "$seen" host), not the client's $NAME"
  [ "$(jget "$seen" path)" = /probe ] && [ "$(jget "$seen" query)" = q=1 ] || nope "the path reached the upstream as $(jget "$seen" path)?$(jget "$seen" query)"
  [ "$(jget "$seen" headers X-Forwarded-For)" = "[\"$client_ip\"]" ] ||
    nope "X-Forwarded-For reached the upstream as $(jget "$seen" headers X-Forwarded-For), not the client's $client_ip alone"
  [ "$(jget "$seen" headers X-Forwarded-Proto)" = '["https"]' ] ||
    nope "X-Forwarded-Proto reached the upstream as $(jget "$seen" headers X-Forwarded-Proto), not https alone"
  [ "$(jget "$seen" headers X-Forwarded-Host)" = "[\"$NAME\"]" ] ||
    nope "X-Forwarded-Host reached the upstream as $(jget "$seen" headers X-Forwarded-Host), not $NAME alone"
  [ "$(jget "$seen" headers Forwarded)" = null ] || nope "the client's Forwarded reached the upstream"
  [ "$(jget "$seen" headers Tailscale-User-Login)" = '["person@proof.example"]' ] &&
    [ "$(jget "$seen" headers Tailscale-User-Name)" = '["Proof Person"]' ] ||
    nope "the identity headers reached the upstream as $(jget "$seen" headers Tailscale-User-Login) $(jget "$seen" headers Tailscale-User-Name), not the peer's"
  [ "$(jget "$seen" headers Tailscale-Funnel-Request)" = null ] || nope "the client's Tailscale-Funnel-Request reached the upstream"
  [ "$(jget "$seen" headers Tailscale-App-Capabilities)" = null ] || nope "the client's Tailscale-App-Capabilities reached the upstream"
  [ "$(jget "$seen" headers Tailscale-User-Other)" = '["passes"]' ] || nope "a Tailscale-User-* header serve.go does not delete did not pass"
  ok "Serve keeps Host, replaces X-Forwarded-For ($client_ip), -Proto and -Host, drops Forwarded, and sets the peer's identity in place of the client's"

  answer="$(serve --host localhost "https://$NAME/")"
  seen="$(jget "$answer" body)"
  [ "$(jget "$seen" host)" = localhost ] && [ "$(jget "$seen" headers X-Forwarded-Host)" = '["localhost"]' ] ||
    nope "a Host other than the server name reached the upstream as $(jget "$seen" host)"
  ok "a Host other than the server name reaches the upstream as sent"

  docker exec "$p-ts" standin user --tagged
  answer="$(serve --header "Tailscale-User-Login: admin@evil.example" --header "Tailscale-User-Name: Forged" "https://$NAME/")"
  seen="$(jget "$answer" body)"
  [ "$(jget "$seen" headers Tailscale-User-Login)" = null ] && [ "$(jget "$seen" headers Tailscale-User-Name)" = null ] &&
    [ "$(jget "$seen" headers Tailscale-Headers-Info)" = null ] ||
    nope "a tagged peer's request reached the upstream with identity headers: $(jget "$seen" headers)"
  docker exec "$p-ts" standin user --login person@proof.example --name "Proof Person"
  ok "a tagged peer's request carries no identity header, the client's deleted"

  answer="$(serve "https://other.proof.ts.net/")"
  [ "$(jget "$answer" error)" = failed ] || nope "a server name with no web handler was answered: $answer"
  answer="$(serve "https://$NAME/status/404")"
  [ "$(jget "$answer" status)" = 404 ] || nope "the upstream's 404 reached the client as: $answer"
  ok "no certificate for another name, and the upstream's own status passes"

  serve_file "$serve_dir/serve.json" ''
  stays_serving "$p-ts" "'$NAME:443' in c.get('Web', {})"
  ok "an empty serve file is skipped"

  serve_file "$serve_dir/serve.json" '{}'
  await_serving "$p-ts" 'c == {}'
  answer="$(serve "https://$NAME/")"
  [ "$(jget "$answer" error)" = refused ] || nope "after {}, Serve still answers: $answer"
  ok "{} closes Serve"

  docker exec "$p-ts" standin tailnet --https off
  status="$(await_status "$p-ts" Running)"
  [ "$(jget "$status" CertDomains)" = null ] || nope "with HTTPS off, the certificate domains are $(jget "$status" CertDomains)"
  serve_file "$serve_dir/serve.json" "$CONFIG"
  stays_serving "$p-ts" 'c == {}'
  answer="$(serve "https://$NAME/")"
  [ "$(jget "$answer" error)" = refused ] || nope "with HTTPS off, Serve answers: $answer"
  docker exec "$p-ts" standin tailnet --https on
  await_serving "$p-ts" "'$NAME:443' in c.get('Web', {})"
  answer="$(serve "https://$NAME/")"
  [ "$(jget "$answer" status)" = 200 ] || nope "once HTTPS is on, Serve answers: $answer"
  ok "no HTTPS is applied while the tailnet has HTTPS off, and it is once HTTPS is on"

  # Started again with no file at all, the node's held configuration
  # serves nothing: containerboot unsets it.
  docker rm -f "$p-ts" >/dev/null
  rm -f "$serve_dir/serve.json"
  docker run -d --name "$p-ts2" --network "$p-net" -v "$p-a:/var/lib/tailscale" -v "$serve_dir:/serve:ro" \
    "${JOIN_ENV[@]}" -e TS_SERVE_CONFIG=/serve/serve.json ${mount[@]+"${mount[@]}"} "$IMAGE" >/dev/null
  await_status "$p-ts2" Running >/dev/null
  ts_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$p-net\").IPAddress}}" "$p-ts2")"
  stays_serving "$p-ts2" 'c == {}'
  answer="$(docker exec "$p-client" standin fetch --ca /ca.pem --connect "$ts_ip:443" "https://$NAME/" || true)"
  [ "$(jget "$answer" error)" = refused ] || nope "started again with no serve file, the configuration the state held answers: $answer"
  ok "started again with no serve file, nothing the state held is served"
}

step "unit: go vet, gofmt and go test of the module"
(cd "$HERE" && go vet ./... && test -z "$(gofmt -l .)" && go test -count=1 ./...) || { nope "the stand-in's module does not pass"; exit 1; }
ok "the module passes"
mapfile -t MUTATIONS < <(cd "$HERE" && go run . mutations)
[ "${#MUTATIONS[@]}" -gt 0 ] || { nope "the stand-in names no mutation"; exit 1; }
package="$(cd "$HERE" && go list .)"
for m in "${MUTATIONS[@]}"; do
  if (cd "$HERE" && go test -count=1 -ldflags "-X $package.mutation=$m" ./... >"$WORK/unit-$m.log" 2>&1); then
    nope "the unit tests pass under the mutation $m"
    exit 1
  fi
  ok "the unit tests fail under $m: $(grep -m1 -E '_test\.go:[0-9]+:' "$WORK/unit-$m.log" | sed 's/^ *//')"
done

step "image: the stand-in as the Compose proof builds it"
"$HERE/build.sh" image "$IMAGE"
ok "built $IMAGE"
checks image
discard "$RUN-image-"

step "mutations: each one's program in the image fails the image checks"
for m in "${MUTATIONS[@]}"; do
  "$HERE/build.sh" binary "$WORK/standin-$m" "$m"
  # Its own shell, with errexit on, so the first check that fails ends the
  # run, as it does above; a condition would switch errexit off inside it.
  set +e
  (
    set -e
    checks "m-$m" "$WORK/standin-$m"
  ) >"$WORK/m-$m.log" 2>&1
  code=$?
  set -e
  discard "$RUN-m-$m-"
  if [ "$code" -eq 0 ]; then
    cat "$WORK/m-$m.log" >&2
    nope "the image checks pass under the mutation $m"
    exit 1
  fi
  ok "the image checks fail under $m: $(grep -m1 '^::error::' "$WORK/m-$m.log" | sed 's/^::error:://')"
done

step "the stand-in holds, and every mutation of it fails its proof"
