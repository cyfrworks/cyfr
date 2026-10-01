#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# HSTS behind the shipped proxy. The repository's Caddyfile, unmodified and
# mounted where docker-compose.yml mounts it, runs in the Caddy image the
# compose file's caddy service names, in front of a stub upstream that
# answers as cyfr:$CYFR_PORT on a private Docker network of this run's own.
# The stub sends a Strict-Transport-Security value of its own, as an
# upstream that set one would. The proof asserts:
#
#   loads     the file loads with CADDY_ACME_EMAIL empty, as compose passes
#             it by default, and unset, registering no email either way, and
#             registers the email when one is given
#   proxied   behind a TLS host, a response over HTTPS carries
#             Strict-Transport-Security once, with the endpoint's own value,
#             read from CyfrWeb.Plugs.ApiSecurityHeaders, the one spelling of
#             it; the upstream answers on a port other than the default
#   upstream  the upstream's own header (X-Upstream) passes through
#   redirect  plain HTTP on the host answers a redirect to https
#   error     with the upstream gone, Caddy's own 502 over HTTPS carries the
#             same header once
#   loopback  CYFR_HOST=localhost with an empty email, compose's defaults:
#             the file loads, serves TLS from Caddy's local CA and redirects
#             plain HTTP, and no response over TLS carries the header, the
#             upstream's own included
#   deep      CYFR_HOST=a.b.localhost, a .localhost name below the first
#             label, gets no header over TLS, asked as itself and in mixed
#             case
#
# No host takes its certificate from ACME, and every HTTPS request trusts
# its proxy's local CA root alone. localhost and every .localhost name are
# local CA names of Caddy's own. For the TLS host cyfr.test the proof adds
# the `local_certs` global option without changing the file: Caddy
# substitutes {$CADDY_ACME_EMAIL} into the file's text before it parses it,
# so a value that closes the email's quote, puts `local_certs` on a line of
# its own and opens a comment on the next turns the file's closing quote
# into that comment.
#
# Usage: tests/proxy-hsts/run.sh
# Needs docker with a daemon it can reach, the compose file's Caddy image
# (pulled when absent), and curl. Without one it names the missing
# prerequisite and exits 77: the proof did not run, which is neither a pass
# nor a failure. A failed assertion exits 1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TLS_HOST=cyfr.test
# Not the endpoint's default, so the proxy must read CYFR_PORT to reach it.
TLS_PORT=4123
LOOPBACK_HOST=localhost
LOOPBACK_PORT=4000
DEEP_HOST=a.b.localhost
# The same name as a client may spell it; Caddy matches hosts in any case.
DEEP_HOST_MIXED=A.b.LocalHost
# The upstream's own value, unlike the endpoint's: the proxy must replace it.
STUB_HSTS="max-age=1"
TLS_EMAIL="$(printf 'proxy-hsts@example.com"\n\tlocal_certs\n\t#')"
GIVEN_EMAIL=proxy-hsts@example.com
SKIPPED=77
READY_TIMEOUT=60

step() { printf '\n=== %s\n' "$*"; }
pass() { printf 'ok    %s\n' "$*"; }

fail() {
  echo "::error::$*" >&2
  exit 1
}

missing() {
  echo "missing prerequisite: $*" >&2
  echo "the proxy HSTS proof did not run (exit $SKIPPED); this is not a pass" >&2
  exit "$SKIPPED"
}

[ $# -eq 0 ] || {
  echo "usage: $0" >&2
  exit 2
}

command -v docker >/dev/null 2>&1 || missing "docker (the proof runs Caddy in a container)"
docker info >/dev/null 2>&1 || missing "a Docker daemon this user can reach (docker info failed)"
command -v curl >/dev/null 2>&1 || missing "curl"

# The image docker-compose.yml's caddy service names: the first `image:` key
# inside that service.
IMAGE="$(awk '
  /^  caddy:[[:space:]]*$/ { in_caddy = 1; next }
  in_caddy && /^  [^ #]/ { exit }
  in_caddy && /^    image:/ { print $2; exit }
' "$ROOT/docker-compose.yml")"
[ -n "$IMAGE" ] || fail "docker-compose.yml's caddy service names no image"

# The endpoint's value, from its one spelling.
PLUG="$ROOT/apps/cyfr/lib/cyfr_web/plugs/api_security_headers.ex"
EXPECTED="$(sed -n 's/.*"strict-transport-security", "\([^"]*\)".*/\1/p' "$PLUG")"
if [ -z "$EXPECTED" ] || [ "$(printf '%s\n' "$EXPECTED" | wc -l)" -ne 1 ]; then
  fail "no single strict-transport-security value in $PLUG"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull --quiet "$IMAGE" >/dev/null || missing "the image $IMAGE (absent here, and the pull failed)"
fi

RUN="cyfr-proxy-hsts-$$"
NET="$RUN"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-proxy-hsts-XXXXXX")"
CONTAINERS=()

# The containers' anonymous volumes (the image's /data and /config) go with
# them (`-v`).
cleanup() {
  if [ "${#CONTAINERS[@]}" -gt 0 ]; then
    docker rm -f -v "${CONTAINERS[@]}" >/dev/null 2>&1 || true
  fi
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The proxy the steps below ask, set by start_proxy: its container, the
# host it serves, its published ports and its local CA root.
PROXY=""
HOST=""
HTTP_PORT=""
HTTPS_PORT=""
CA_ROOT=""

fail_with_logs() {
  if [ -n "$PROXY" ]; then
    echo "--- the proxy's log (last 40 lines)" >&2
    docker logs --tail 40 "$PROXY" >&2 2>&1 || true
  fi
  fail "$*"
}

# The shipped Caddyfile adapted to JSON with the environment `$2…` (docker
# `-e` arguments); `$1` names the case. Fails when Caddy refuses the file or
# warns that it is not formatted as `caddy fmt` formats it.
adapt() {
  local name="$1"
  shift
  if ! docker run --rm -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" "$@" "$IMAGE" \
    caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile \
    >"$WORK/$name.json" 2>"$WORK/$name.log"; then
    cat "$WORK/$name.log" >&2
    fail "Caddy refused the shipped Caddyfile ($name)"
  fi
  if grep -q 'not formatted' "$WORK/$name.log"; then
    fail "the shipped Caddyfile is not formatted as caddy fmt formats it"
  fi
}

# A stub upstream, `$1`, answering as cyfr:`$2` on the run's network;
# returns once it answers on that port, so a proxy started after it that
# answers anything but 200 does so for a reason of its own.
start_stub() {
  CONTAINERS+=("$1")
  docker run -d --name "$1" --network "$NET" --network-alias cyfr "$IMAGE" \
    caddy respond --listen ":$2" \
    --header "X-Upstream: stub" --header "Strict-Transport-Security: $STUB_HSTS" ok >/dev/null
  local deadline=$((SECONDS + READY_TIMEOUT))
  until docker exec "$1" wget -q -O /dev/null "http://127.0.0.1:$2/" 2>/dev/null; do
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] ||
      fail "the stub upstream $1 exited before it answered"
    [ "$SECONDS" -lt "$deadline" ] || fail "the stub upstream $1 did not answer within ${READY_TIMEOUT}s"
    sleep 0.2
  done
}

# The shipped Caddyfile in proxy `$1` for host `$2`, proxying to cyfr:`$3`,
# with CADDY_ACME_EMAIL `$4`; returns once it answers over TLS verified
# against its local CA root, whatever the status.
start_proxy() {
  PROXY="$1" HOST="$2"
  CONTAINERS+=("$PROXY")
  docker run -d --name "$PROXY" --network "$NET" \
    -p 127.0.0.1::80 -p 127.0.0.1::443 \
    -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -e "CYFR_HOST=$HOST" \
    -e "CYFR_PORT=$3" \
    -e "CADDY_ACME_EMAIL=$4" \
    "$IMAGE" >/dev/null

  HTTP_PORT="$(docker port "$PROXY" 80/tcp 2>/dev/null | sed -n '1s/.*://p')" || true
  HTTPS_PORT="$(docker port "$PROXY" 443/tcp 2>/dev/null | sed -n '1s/.*://p')" || true
  if [ -z "$HTTP_PORT" ] || [ -z "$HTTPS_PORT" ]; then
    fail_with_logs "the proxy published no ports"
  fi

  CA_ROOT="$WORK/$PROXY-root.crt"
  local deadline=$((SECONDS + READY_TIMEOUT))
  # curl's status is 000 when no TLS answer verified against the root came.
  until docker exec "$PROXY" cat /data/caddy/pki/authorities/local/root.crt >"$CA_ROOT" 2>/dev/null &&
    [ -s "$CA_ROOT" ] &&
    [ "$(https_get "$PROXY-ready" / 2>/dev/null || true)" != 000 ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$PROXY" 2>/dev/null)" = true ] ||
      fail_with_logs "the proxy exited before it answered"
    [ "$SECONDS" -lt "$deadline" ] ||
      fail_with_logs "no answer over HTTPS from Caddy's local CA within ${READY_TIMEOUT}s"
    sleep 0.5
  done
}

# The values of header `$2` (lowercase) in the headers curl saved as `$1`,
# one per line.
header_values() {
  [ -f "$WORK/$1.headers" ] || return 0
  awk -v name="$2" '
    { sub(/\r$/, "") }
    index(tolower($0), name ":") == 1 {
      value = substr($0, length(name) + 2)
      sub(/^[ \t]+/, "", value)
      print value
    }
  ' "$WORK/$1.headers"
}

# GET path `$2` over HTTPS from the current proxy as its host, trusting only
# its local CA root; saves the headers as `$1` and prints the status. `$3`,
# when given, is the Host header's name, sent as written.
https_get() {
  local host_header=()
  [ -z "${3:-}" ] || host_header=(-H "Host: $3:$HTTPS_PORT")
  curl -sS --max-time 10 --cacert "$CA_ROOT" \
    --resolve "$HOST:$HTTPS_PORT:127.0.0.1" ${host_header[@]+"${host_header[@]}"} \
    -D "$WORK/$1.headers" -o "$WORK/$1.body" -w '%{http_code}' \
    "https://$HOST:$HTTPS_PORT$2"
}

# The response saved as `$1`, answered 200 with status `$2`, carries no
# Strict-Transport-Security, and the upstream's own reached it neither. `$3`
# names the response.
assert_no_hsts() {
  local count
  [ "$2" = 200 ] || fail_with_logs "$3 answered ${2:-nothing}, not 200"
  count="$(hsts_count "$1")"
  [ "$count" = 0 ] ||
    fail "$3 carries Strict-Transport-Security $count times: $(header_values "$1" strict-transport-security)"
  pass "$3: no strict-transport-security, the upstream's own dropped too"
}

# GET path `$2` over plain HTTP from the current proxy as its host; saves
# the headers as `$1` and prints the status.
http_get() {
  curl -sS --max-time 10 --resolve "$HOST:$HTTP_PORT:127.0.0.1" \
    -D "$WORK/$1.headers" -o /dev/null -w '%{http_code}' \
    "http://$HOST:$HTTP_PORT$2"
}

# The number of Strict-Transport-Security headers in the response saved as
# `$1`.
hsts_count() { header_values "$1" strict-transport-security | grep -c '' || true; }

# The response saved as `$1` carries Strict-Transport-Security exactly once,
# with the endpoint's value. `$2` names the response.
assert_hsts() {
  local values count
  values="$(header_values "$1" strict-transport-security)"
  count="$(hsts_count "$1")"
  [ "$count" = 1 ] ||
    fail "$2 carries Strict-Transport-Security $count times, not once: ${values:-none}"
  [ "$values" = "$EXPECTED" ] ||
    fail "$2 carries Strict-Transport-Security '$values', not the endpoint's '$EXPECTED'"
  pass "$2: strict-transport-security: $values (once, the endpoint's value)"
}

# The upstream's own X-Upstream reached the response saved as `$1`.
assert_upstream() {
  local upstream
  upstream="$(header_values "$1" x-upstream)"
  [ "$upstream" = stub ] || fail "$2: X-Upstream did not pass through unchanged: ${upstream:-none}"
  pass "$2: x-upstream: $upstream"
}

# Plain HTTP on the current proxy's host answers a redirect to the same
# path over https.
assert_redirect() {
  local status location
  status="$(http_get "$PROXY-http" '/probe?q=1')" || true
  location="$(header_values "$PROXY-http" location)"
  case "$status" in
    301 | 302 | 307 | 308) ;;
    *) fail "plain HTTP on $HOST answered ${status:-nothing}, not a redirect" ;;
  esac
  [ "$location" = "https://$HOST/probe?q=1" ] ||
    fail "plain HTTP on $HOST redirected to '${location:-nowhere}', not https://$HOST/probe?q=1"
  pass "HTTP $status on $HOST to $location"
}

step "loads: the shipped Caddyfile in $IMAGE, CADDY_ACME_EMAIL empty, unset and given"
adapt email-empty -e "CYFR_HOST=$TLS_HOST" -e CADDY_ACME_EMAIL=
! grep -q '"email"' "$WORK/email-empty.json" || fail "an empty CADDY_ACME_EMAIL registered an email"
pass "CADDY_ACME_EMAIL empty: the file loads and registers no email"
adapt email-unset -e "CYFR_HOST=$TLS_HOST"
! grep -q '"email"' "$WORK/email-unset.json" || fail "an unset CADDY_ACME_EMAIL registered an email"
pass "CADDY_ACME_EMAIL unset: the file loads and registers no email"
adapt email-given -e "CYFR_HOST=$TLS_HOST" -e "CADDY_ACME_EMAIL=$GIVEN_EMAIL"
grep -q "\"email\":\"$GIVEN_EMAIL\"" "$WORK/email-given.json" ||
  fail "a given CADDY_ACME_EMAIL was not registered"
pass "CADDY_ACME_EMAIL given: the file loads and registers $GIVEN_EMAIL"

docker network create "$NET" >/dev/null

step "the TLS host $TLS_HOST, proxying to a stub answering as cyfr:$TLS_PORT"
start_stub "$RUN-stub-tls" "$TLS_PORT"
start_proxy "$RUN-caddy-tls" "$TLS_HOST" "$TLS_PORT" "$TLS_EMAIL"
pass "TLS for $TLS_HOST verified against Caddy's local CA root, no ACME"

step "proxied: a response from the upstream over HTTPS"
status="$(https_get proxied '/probe?q=1')" || true
[ "$status" = 200 ] || fail_with_logs "the proxied request answered ${status:-nothing}, not 200"
pass "the proxied request reached the upstream on cyfr:$TLS_PORT, not the default port"
assert_hsts proxied "the proxied 200"

step "upstream: the upstream's own headers"
assert_upstream proxied "the proxied 200"

step "redirect: plain HTTP on $TLS_HOST"
assert_redirect

step "error: Caddy's own response with the upstream gone"
docker rm -f -v "$RUN-stub-tls" >/dev/null
status="$(https_get gone /)" || true
[ "$status" = 502 ] || fail_with_logs "with the upstream gone the proxy answered ${status:-nothing}, not 502"
assert_hsts gone "Caddy's 502"
docker rm -f -v "$RUN-caddy-tls" >/dev/null

step "loopback: CYFR_HOST=$LOOPBACK_HOST, CADDY_ACME_EMAIL empty, a stub answering as cyfr:$LOOPBACK_PORT"
start_stub "$RUN-stub-loopback" "$LOOPBACK_PORT"
start_proxy "$RUN-caddy-loopback" "$LOOPBACK_HOST" "$LOOPBACK_PORT" ""
pass "the file loads with CADDY_ACME_EMAIL empty, and TLS for $LOOPBACK_HOST is verified against Caddy's local CA root"
status="$(https_get loopback '/probe?q=1')" || true
assert_no_hsts loopback "$status" "$LOOPBACK_HOST over TLS"
assert_upstream loopback "the loopback 200"
assert_redirect
docker rm -f -v "$RUN-caddy-loopback" >/dev/null

step "deep: CYFR_HOST=$DEEP_HOST, the same stub"
start_proxy "$RUN-caddy-deep" "$DEEP_HOST" "$LOOPBACK_PORT" ""
pass "TLS for $DEEP_HOST verified against Caddy's local CA root"
status="$(https_get deep '/probe?q=1')" || true
assert_no_hsts deep "$status" "$DEEP_HOST over TLS"
assert_upstream deep "the $DEEP_HOST 200"
status="$(https_get deep-mixed '/probe?q=1' "$DEEP_HOST_MIXED")" || true
assert_no_hsts deep-mixed "$status" "$DEEP_HOST over TLS, asked as Host: $DEEP_HOST_MIXED"

step "ip: CYFR_HOST=127.0.0.1, asked from inside the proxy's container"
# An IP literal carries no server name, so Caddy picks its certificate by
# the address the request arrived on: only a request made inside the
# container reaches it as 127.0.0.1. busybox wget prints the response's
# headers to stderr.
IP_PROXY="$RUN-caddy-ip"
CONTAINERS+=("$IP_PROXY")
docker run -d --name "$IP_PROXY" --network "$NET" \
  -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e CYFR_HOST=127.0.0.1 -e "CYFR_PORT=$LOOPBACK_PORT" -e CADDY_ACME_EMAIL= \
  "$IMAGE" >/dev/null
deadline=$((SECONDS + READY_TIMEOUT))
until docker exec "$IP_PROXY" wget -S -q --no-check-certificate -O /dev/null \
  "https://127.0.0.1/probe?q=1" 2>"$WORK/ip.headers"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$IP_PROXY" 2>/dev/null)" = true ] ||
    { PROXY="$IP_PROXY" fail_with_logs "the proxy for 127.0.0.1 exited before it answered"; }
  [ "$SECONDS" -lt "$deadline" ] ||
    { PROXY="$IP_PROXY" fail_with_logs "no answer over HTTPS for 127.0.0.1 within ${READY_TIMEOUT}s"; }
  sleep 0.5
done
grep -q ' 200 ' "$WORK/ip.headers" || fail "127.0.0.1 over TLS answered no 200: $(head -1 "$WORK/ip.headers")"
grep -qi '^ *x-upstream: stub' "$WORK/ip.headers" || fail "127.0.0.1 over TLS did not reach the upstream"
! grep -qi '^ *strict-transport-security:' "$WORK/ip.headers" ||
  fail "127.0.0.1 over TLS carries Strict-Transport-Security"
pass "127.0.0.1 over TLS: no strict-transport-security, the upstream's own dropped too"
docker rm -f -v "$IP_PROXY" >/dev/null

# ::1 cannot be asked the same way (busybox's TLS client resets an IPv6
# connection there), so its branch is held in the adapted configuration:
# the HSTS matcher Caddy loaded names it beside 127.0.0.1.
adapt ip-matcher -e "CYFR_HOST=$TLS_HOST"
grep -qF '127\\.0\\.0\\.1' "$WORK/ip-matcher.json" ||
  fail "the loaded HSTS matcher does not name 127.0.0.1"
grep -q '::1' "$WORK/ip-matcher.json" || fail "the loaded HSTS matcher does not name ::1"
pass "the loaded HSTS matcher names 127.0.0.1 and ::1"

step "HSTS behind the shipped proxy: every assertion held"
