#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The source development stack: docker-compose.dev.yml as `docker compose
# config` resolves it over docker-compose.yml with each slot's values
# (tests/dev-stack/compose_shape.py), and scripts/dev-stack.sh at its
# command boundary.
#
# The override: the runtime, backends and builds services and their
# guards are the shipped ones field by field, but for the project and
# container names (cyfr-dev-<seed>), the shared image it never builds or
# pulls, the runtime's listener on the host's loopback alone and its calls
# to its network's gateway, each guard's fixed address and the control
# plane it refuses at its network's gateway, and the keeper's profile at
# its tracked path. Slot 0 keeps Prism on 127.0.0.1:4000, and every slot's
# host ports and subnets are apart from what the checks on a host reserve,
# read from their sources, and from every other slot's; a source that
# moves a reservation onto a slot fails as a dev declaration that moves
# onto one does.
#
# The script, with docker, mix, curl and scripts/image.sh stubbed (the
# stubbed docker resolves with the real compose and lists the networks a
# case names, the stubbed mix runs the real task from this checkout's
# build), in case directories that are git repositories of their own, so
# each has a seed: it provisions .env on its first run and keeps it after,
# hands compose the services' keys and the server CYFR's settings in their
# environments alone, takes the slot its worktree remembers or the first
# free one (passing slots another loop claims, whose ports something holds
# or whose subnets a network overlaps, and refusing when none is free),
# lets a second worktree's loop run beside the first, refuses what
# disagrees, and on every exit (the server's own, a failed start, Ctrl-C,
# SIGTERM) stops the server's whole process group and removes the
# containers. Before them it starts the local cyfr.run every worktree
# shares, from a checkout of the test's own in the shape of cyfr.run's two
# compose files, under
# its fixed project and its own env file alone, and never stops it; it
# refuses with the machine's command when the names do not resolve to
# 127.0.0.1 (the stubbed mix's resolver reads a hosts table of the test's,
# never the machine's), when the authority is not in the operating
# system's trust store (a trusted one is a root that store already
# holds), when port 443 cannot be published, and when a database's people
# were made at a local cyfr.run that is gone. Its check secures its
# bearer and cleans up after a failed read. The scaffold ships neither
# file. Each mutation fails; an equivalent respelling holds.
#
# Needs docker's compose plugin (no daemon), git, python3, ss, flock and a
# build of the checkout (_build/$MIX_ENV, or DEV_STACK_BUILD). The boundary
# cases take the slots whose ports this host leaves free. SHOW=1 prints why
# each mutation fails; DEV_STACK_SCRIPT runs the boundary cases against
# another script, and DEV_STACK_CASES (case_* names) runs those boundary
# cases alone after the static checks, with no mutation of the script.
# Usage: bash tests/dev-stack/compose-test.sh
set -uo pipefail

# One copy runs on a host at a time. The boundary cases stand the script's
# real listeners on the host's slots, each case with claims of its own, so
# two copies would take the same slots and fail on each other's ports. The
# lock is flock's on a file every copy on the host names: the kernel
# releases it when its holder ends, however it ends, and no process this
# test starts keeps it (flock -o). A copy waits for another up to 300 s,
# and then fails with 75. A dev loop started on the host while the cases
# run can still take a slot they chose: the lock is this test's alone.
if [ "${1:-}" != --locked ]; then
  lock=/tmp/cyfr-dev-stack-test.lock
  flock -o -n -E 75 "$lock" bash "$0" --locked
  status=$?
  if [ "$status" = 75 ]; then
    echo "compose-test: another copy of this test holds $lock; waiting up to 300 s for it to end" >&2
    flock -o -w 300 -E 75 "$lock" bash "$0" --locked
    status=$?
    [ "$status" != 75 ] || echo "compose-test: the other copy still held $lock after 300 s" >&2
  fi
  exit "$status"
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# The boundary cases, defined below; DEV_STACK_CASES names some of them.
BOUNDARY_CASES="case_provision case_retained case_refused case_release_root case_port_held case_network_overlap case_remembered case_all_taken case_start_fails case_image_fails case_image_build_fails case_claim_named case_claim_unverified case_server_ends case_interrupted case_check case_failed_read case_failed_parse case_project_env case_server_child case_blank_root case_locked case_two_checkouts case_down_orphan case_new_database case_same_stack case_stack_reset case_cyfr_run_absent case_stack_env case_unresolved case_untrusted case_port_443 case_mixed_address case_missing_bind case_volume_replaced case_new_commit case_export_symlink case_export_cleanup"
for c in ${DEV_STACK_CASES:-}; do
  case " $BOUNDARY_CASES " in
    *" $c "*) ;;
    *) echo "compose-test: DEV_STACK_CASES names $c, which is not a boundary case: $BOUNDARY_CASES" >&2; exit 64 ;;
  esac
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-dev-stack-compose.XXXXXX")" || exit 1
holders=()
trap 'for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$scratch"' EXIT
SHAPE="$ROOT/tests/dev-stack/compose_shape.py"
REAL_DOCKER="$(command -v docker)"
# shellcheck source=../../scripts/lib/run-names.sh
. "$ROOT/scripts/lib/run-names.sh"
SLOTS="$(seq 0 19)"
# The image the static checks resolve with, and the stubbed scripts/image.sh
# names.
stub_image="cyfr-locus:in-0123456789abcdef0123"

failures=0
cases=0
pass() { cases=$((cases + 1)); echo "PASS: $1"; }
failed() {
  cases=$((cases + 1)) failures=$((failures + 1))
  echo "FAIL: $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/  /'
}

# slot_env K: slot K's values, from the script that owns the rule.
slot_env() { bash "$ROOT/scripts/dev-stack.sh" slot "$1"; }

# project DIR OVERRIDE: a project directory holding the shipped compose
# file, OVERRIDE as docker-compose.dev.yml and an empty .env.
project() {
  rm -rf "$1" && mkdir -p "$1"
  cp "$ROOT/docker-compose.yml" "$1/"
  cp "$2" "$1/docker-compose.dev.yml"
  : >"$1/.env"
}

# resolve DIR SLOT PROJECT FILE... : the stack's services from those
# files with slot SLOT's values, the project PROJECT and the stub image, as
# the script resolves them, in an environment holding nothing else of the
# caller's.
resolve() {
  local dir="$1" slot="$2" project="$3" files=()
  shift 3
  for f in "$@"; do files+=(-f "$f"); done
  # shellcheck disable=SC2046
  (cd "$dir" && env -i PATH="$PATH" HOME="$HOME" $(slot_env "$slot") DEV_STACK_PROJECT="$project" \
    DEV_STACK_IMAGE="$stub_image" "$REAL_DOCKER" compose --env-file /dev/null \
    --profile locus-builds "${files[@]}" config --format json locus-runtime locus-backends locus-builds)
}

# sources DIR: the files the checks reserve ports and names in, copied, so
# a case may move a reservation.
sources() {
  rm -rf "$1" && mkdir -p "$1/config"
  cp "$ROOT/config/test.exs" "$1/config/"
  cp -r "$ROOT/tests" "$ROOT/scripts" "$ROOT/.github" "$1/"
}

check_project="cyfr-dev-$(run_names_seed "$ROOT")"
# checks DIR [SOURCES [SLOTS]]: the override in DIR held to the shipped
# file at slot 0, and each of SLOTS (0 and 19 by default) kept apart from
# the reservations in SOURCES (the checkout's by default) and from each
# other.
checks() {
  local dir="$1" sources="${2:-$ROOT}" slots="${3:-0 19}" k jsons=()
  (cd "$dir" && env -i PATH="$PATH" HOME="$HOME" "$REAL_DOCKER" compose --env-file /dev/null --profile locus-builds \
    -f docker-compose.yml config --format json locus-runtime locus-backends locus-builds) >"$dir/base.json" 2>"$dir/err" ||
    { cat "$dir/err"; return 1; }
  for k in $slots; do
    resolve "$dir" "$k" "$check_project" docker-compose.yml docker-compose.dev.yml >"$dir/slot-$k.json" 2>"$dir/err" ||
      { cat "$dir/err"; return 1; }
    jsons+=("$dir/slot-$k.json")
  done
  (cd "$dir" && env -i PATH="$PATH" HOME="$HOME" "$REAL_DOCKER" compose --env-file /dev/null --profile '*' \
    -f docker-compose.yml config --format json) >"$dir/shipped.json" 2>"$dir/err" || { cat "$dir/err"; return 1; }
  local out status=0
  out="$(python3 -I "$SHAPE" shape "$dir/base.json" "$dir/slot-0.json" "$ROOT" "$check_project" "$stub_image")" || status=1
  out="$out$(python3 -I "$SHAPE" apart "$dir/shipped.json" "$sources" "${jsons[@]}")" || status=1
  printf '%s' "$out"
  return "$status"
}

expect_checks() {
  local want="$1" what="$2" out code
  shift 2
  out="$(checks "$@" 2>&1)"
  code=$?
  if { [ "$want" = pass ] && [ "$code" -eq 0 ]; } || { [ "$want" = fail ] && [ "$code" -ne 0 ] && [ -n "$out" ]; }; then
    pass "$what"
    [ -z "${SHOW:-}" ] || printf "%s\n" "$out" | sed "s/^/    /"
  else
    failed "$what (exit $code)" "$out"
  fi
}

override="$ROOT/docker-compose.dev.yml"
project "$scratch/real" "$override"
expect_checks pass "the override is the shipped stack's shape, and every slot is apart from every check's reservations and from each other" \
  "$scratch/real" "$ROOT" "$SLOTS"

# The slot rule: slot 0 keeps the shipped-style addresses, a lone loop's
# localhost:4000; slot 19 is the last; there is no slot 20.
want0="DEV_STACK_SLOT=0
DEV_STACK_PRISM_PORT=4000
DEV_STACK_PROXY_PORT=4001
DEV_STACK_RUNTIME_PORT=4700
DEV_STACK_HOST_API_PORT=4701
DEV_STACK_RUNTIME_NET=172.16.100
DEV_STACK_BACKENDS_NET=172.16.101
DEV_STACK_BUILDS_NET=172.16.102"
want19="DEV_STACK_SLOT=19
DEV_STACK_PRISM_PORT=4190
DEV_STACK_PROXY_PORT=4191
DEV_STACK_RUNTIME_PORT=4890
DEV_STACK_HOST_API_PORT=4891
DEV_STACK_RUNTIME_NET=172.16.157
DEV_STACK_BACKENDS_NET=172.16.158
DEV_STACK_BUILDS_NET=172.16.159"
if [ "$(slot_env 0)" = "$want0" ] && [ "$(slot_env 19)" = "$want19" ] && ! slot_env 20 >/dev/null 2>&1; then
  pass "slot 0 is Prism on 4000 and 172.16.100-102, slot 19 the last, and there is no slot 20"
else
  failed "the slot rule" "$(slot_env 0; slot_env 19; slot_env 20 2>&1)"
fi

# mutate NAME WHAT SED_EXPRESSION: the override edited, which must fail.
mutate() {
  local dir="$scratch/m-$1"
  sed -E "$3" "$override" >"$scratch/m-$1.yml"
  if cmp -s "$override" "$scratch/m-$1.yml"; then
    failed "$2 (the edit changed nothing)"
    return
  fi
  project "$dir" "$scratch/m-$1.yml"
  expect_checks fail "$2" "$dir"
}
mutate wildcard "the runtime published on every interface" 's/"127\.0\.0\.1:(\$\{DEV_STACK_RUNTIME_PORT[^}]*\}):4200"/"0.0.0.0:\1:4200"/'
mutate nohost "the runtime published with no host address" 's/"127\.0\.0\.1:(\$\{DEV_STACK_RUNTIME_PORT[^}]*\}):4200"/"\1:4200"/'
mutate testport "the runtime on the test suite's endpoint" 's/"127\.0\.0\.1:\$\{DEV_STACK_RUNTIME_PORT[^}]*\}:4200"/"127.0.0.1:4002:4200"/'
mutate hstsapi "the host API on the HSTS proof's port" 's|(LOCUS_RUNTIME_HOST_API_URL=http://.*\}\.1:)\$\{DEV_STACK_HOST_API_PORT[^}]*\}|\14123|'
mutate hstsport "Prism on the HSTS proof's port" 's/^x-prism: 127\.0\.0\.1:.*$/x-prism: 127.0.0.1:4123/'
mutate prismwild "Prism on every interface" 's/^x-prism: 127\.0\.0\.1:/x-prism: 0.0.0.0:/'
mutate proxyfixed "Prism's proxy on one port in every slot" 's/^x-prism-proxy: .*$/x-prism-proxy: 4501/'
mutate sameport "the host API on the runtime's port" 's|(LOCUS_RUNTIME_HOST_API_URL=http://.*\}\.1:)\$\{DEV_STACK_HOST_API_PORT[^}]*\}|\1${DEV_STACK_RUNTIME_PORT}|'
mutate published "a published image tag" '0,/image: \$\{DEV_STACK_IMAGE[^}]*\}/s||image: ghcr.io/cyfrworks/cyfr-locus:latest|'
mutate guardimage "a guard on the published image" '/^  locus-builds-guard:$/,/container_name:/s|image: \$\{DEV_STACK_IMAGE\}|image: ghcr.io/cyfrworks/cyfr-locus:latest|'
mutate pulled "an image compose may pull" '0,/pull_policy: never/{/pull_policy: never/d}'
mutate built "an image compose builds" '0,/pull_policy: never/s//pull_policy: build/'
mutate callback "the runtime's callbacks to the shipped cyfr service" 's|LOCUS_RUNTIME_HOST_API_URL=http://.*\}\.1:|LOCUS_RUNTIME_HOST_API_URL=http://cyfr:|'
mutate loopback "the runtime's callbacks to its own loopback" 's|LOCUS_RUNTIME_HOST_API_URL=http://.*\}\.1:|LOCUS_RUNTIME_HOST_API_URL=http://127.0.0.1:|'
mutate gateway "another gateway than the callbacks name" 's/gateway: \$\{DEV_STACK_RUNTIME_NET\}\.1$/gateway: ${DEV_STACK_RUNTIME_NET}.126/'
mutate serviceid "the shipped service id, which CYFR does not dispatch to" 's/LOCUS_RUNTIME_SERVICE_ID=wrk_local/LOCUS_RUNTIME_SERVICE_ID=wrk_locus/'
mutate joined "the security options joined to the shipped ones" 's/security_opt: !override/security_opt:/'
mutate seccomp "the keeper's profile dropped" '/seccomp=\.\/apps/d'
mutate noprofile "a profile the checkout does not hold" 's|seccomp=\./apps/locus/keeper/seccomp/keeper\.json|seccomp=./keeper.seccomp.json|'
mutate nnp "no-new-privileges dropped" '/- no-new-privileges:true/d'
mutate capability "a capability added to the backends service" 's/^(    container_name: \$\{DEV_STACK_PROJECT\}-locus-backends)$/\1\n    cap_add: [NET_ADMIN]/'
mutate writable "a writable root for the builder" 's/^(    container_name: \$\{DEV_STACK_PROJECT\}-locus-builds)$/\1\n    read_only: false/'
mutate hostnet "the backends service on the host's network" 's/^(    container_name: \$\{DEV_STACK_PROJECT\}-locus-backends)$/\1\n    network_mode: host/'
mutate guardless "the builder outside its guard's namespace" 's/^(    container_name: \$\{DEV_STACK_PROJECT\}-locus-builds)$/\1\n    network_mode: bridge/'
mutate shippedplane "a guard refusing the shipped control plane, not the host" 's/CYFR_GUARD_CONTROL_PLANE=\$\{DEV_STACK_BACKENDS_NET[^}]*\}\.1/CYFR_GUARD_CONTROL_PLANE=172.16.230.2/'
mutate noplane "a guard's control plane left as shipped" '/CYFR_GUARD_CONTROL_PLANE=\$\{DEV_STACK_BUILDS_NET/d'
mutate inrange "a guard's address inside its network's ip_range" 's/ipv4_address: \$\{DEV_STACK_BACKENDS_NET\}\.2/ipv4_address: ${DEV_STACK_BACKENDS_NET}.200/'
mutate shippedsubnet "a dev network on the shipped runtime subnet" 's/\$\{DEV_STACK_BACKENDS_NET[^}]*\}/172.16.231/g'
mutate pool "a dev network in Docker's address pools" 's/\$\{DEV_STACK_BUILDS_NET[^}]*\}/172.18.242/g'
mutate twice "two dev networks on one subnet" 's/\$\{DEV_STACK_BUILDS_NET[^}]*\}/${DEV_STACK_BACKENDS_NET}/g'
mutate onesubnet "one subnet in every slot" 's/\$\{DEV_STACK_RUNTIME_NET[^}]*\}/172.16.99/g'
mutate unnamed "the checkout directory's project name" '/^name: /d'
mutate seedless "one project for every worktree" 's/^name: .*$/name: cyfr-dev/'
mutate container "the shipped container name" 's/container_name: \$\{DEV_STACK_PROJECT\}-locus-runtime/container_name: cyfr-locus-runtime/'

# move NAME WHAT FILE SED_EXPRESSION: a check's own reservation moved onto
# a slot, which must fail.
move() {
  local dir="$scratch/s-$1"
  project "$dir" "$override"
  sources "$dir.sources"
  sed -E -i "$4" "$dir.sources/$3"
  if cmp -s "$ROOT/$3" "$dir.sources/$3"; then
    failed "$2 (the edit changed nothing)"
    return
  fi
  expect_checks fail "$2" "$dir" "$dir.sources" "$SLOTS"
}
move suite "the test suite's endpoint moved onto slot 0's runtime port" config/test.exs 's/port: 4002\]/port: 4700]/'
move hsts "the HSTS proof moved onto slot 13's Prism address" tests/proxy-hsts/run.sh 's/TLS_PORT=4123/TLS_PORT=4130/'
move named "a proof naming a loop's container" tests/compose-proof/run.sh '1a # docker logs cyfr-dev-0123456789-locus-builds'
move unread "a reservation the check can no longer read" tests/proxy-hsts/run.sh 's/TLS_PORT=4123/TLS_LISTENER=4123/'
dir="$scratch/s-shipped"
project "$dir" "$override"
sed -i 's|- subnet: 172\.16\.234\.0/24|- subnet: 172.16.101.0/24|' "$dir/docker-compose.yml"
expect_checks fail "the shipped edge network moved onto slot 0's backends subnet" "$dir"

# scripts/dev-stack.sh at its command boundary: docker, mix, curl and
# scripts/image.sh stubbed, each recording what it is handed, in case
# directories that are git repositories of their own. What the script must
# hand on comes from the override resolved with the slot the case takes,
# the case's project and the stub image: the server's settings
# (compose_shape.py settings), and the key the documented derivation gives
# for the runtime's id (.env.example: the root's HMAC of
# `cyfr-locus/v1/runtime\n<id>`). The slots a case may take are those
# whose ports this host leaves free; a loop running on the host keeps its
# own.
want_id=wrk_local
derived() { printf 'cyfr-locus/v1/runtime\n%s' "$want_id" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" 2>/dev/null | sed 's/^.*= //'; }
# value K NAME: slot K's NAME.
value() { slot_env "$1" | sed -n "s/^$2=//p"; }
# host_free K: nothing on this host listens on slot K's ports.
host_free() {
  python3 -I -c '
import socket, sys
for listener in sys.argv[1:]:
    address, port = listener.rsplit(":", 1)
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((address, int(port)))
    except OSError:
        sys.exit(1)
    s.close()' "127.0.0.1:$(value "$1" DEV_STACK_PRISM_PORT)" "127.0.0.1:$(value "$1" DEV_STACK_PROXY_PORT)" \
    "127.0.0.1:$(value "$1" DEV_STACK_RUNTIME_PORT)" "127.0.0.1:$(value "$1" DEV_STACK_HOST_API_PORT)"
}
# free_after K: the first slot from K on whose ports are free here.
free_after() {
  local k
  for k in $(seq "$1" 19); do host_free "$k" && { echo "$k"; return 0; }; done
  return 1
}
slot_a="$(free_after 0)" && slot_b="$(free_after $((slot_a + 1)))" && slot_c="$(free_after $((slot_b + 1)))" ||
  { failed "three slots with free ports on this host"; echo "$((cases - failures))/$cases passed"; exit 1; }

build="${DEV_STACK_BUILD:-$ROOT/${MIX_BUILD_PATH:-_build/${MIX_ENV:-dev}}}"
ebins=""
for dir in "$build"/lib/*/ebin; do ebins="$ebins -pa $dir"; done
[ -f "$build/lib/cyfr/ebin/Elixir.Mix.Tasks.Cyfr.Locus.DevStack.beam" ] ||
  failed "no build of mix cyfr.locus.dev_stack under $build: compile the checkout first"

stubs="$scratch/bin"
mkdir -p "$stubs"
cat >"$stubs/docker" <<'STUB'
#!/usr/bin/env bash
# One record a call: a script handed to `sh -c` keeps to its line.
args="$*"
printf '%s|LOCUS_RUNTIME_KEY=%s|CYFR_LOCUS_BACKENDS_KEY=%s|CYFR_LOCUS_BUILDS_KEY=%s|slot=%s\n' "${args//$'\n'/ }" \
  "${LOCUS_RUNTIME_KEY-unset}" "${CYFR_LOCUS_BACKENDS_KEY-unset}" "${CYFR_LOCUS_BUILDS_KEY-unset}" \
  "${DEV_STACK_SLOT-unset}" >>"$STUB_LOG/docker.calls"
env | sed -n 's/^\(COMPOSE_[A-Z_]*\)=.*/\1/p' | sort | tr '\n' ' ' >>"$STUB_LOG/docker.env"
echo >>"$STUB_LOG/docker.env"
# What of the local cyfr.run's settings a call of its compose under its env
# file saw in the environment; the call that only lists the names its
# files interpolate reads no value.
case " $* " in
  *" --env-file /dev/null -p cyfr-run-dev "*) ;;
  *" -p cyfr-run-dev "*) env | sed -n 's/^\(DOMAIN\|ADMIN_TOKEN\|CYFR_LOCAL_HTTPS_PORT\)=.*/\1/p' >>"$STUB_LOG/stack.seen" ;;
esac
case " $* " in
  *" config "*) exec "$REAL_DOCKER" "$@" ;;
  *" -p cyfr-run-dev "*" cp "*) cp "$STUB_ROOT" "${@: -1}" ;;
  *" -p cyfr-run-dev "*" up "*)
    [ -z "${STUB_STACK_UP_OUTPUT:-}" ] || echo "$STUB_STACK_UP_OUTPUT" >&2
    exit "${STUB_STACK_UP_STATUS:-0}"
    ;;
  *" -p cyfr-run-dev "*" exec -T -u postgres postgres "*) echo "$STUB_STACK_ID" ;;
  # The question an earlier loop asked of the volume: when it was made,
  # which a volume replaced within the same second answers alike.
  " volume inspect "*) echo "$STUB_VOLUME_MADE" ;;
  # The server's image the stack's compose built, the same id until a build.
  " image inspect --format {{.Id}} cyfr-run-dev-cyfrrun ") echo "${STUB_STACK_IMAGE-sha256:stub-cyfrrun}" ;;
  " network ls -q ") [ -z "${STUB_NETWORKS:-}" ] || echo stub-networks ;;
  " network inspect "*) printf '%s\n' "${STUB_NETWORKS:-}" ;;
  *" up "*)
    # The slot's claim as the start finds it.
    cat "$XDG_RUNTIME_DIR/cyfr-dev-slot.$DEV_STACK_SLOT.lock" >"$STUB_LOG/claim.at-up" 2>/dev/null
    # Held inside the start until the test releases it, when it asks.
    if [ -n "${STUB_UP_HOLD:-}" ]; then
      touch "$STUB_LOG/up.held"
      for _ in $(seq 1 600); do [ -e "$STUB_LOG/up.release" ] && break; sleep 0.1; done
    fi
    exit "${STUB_UP_STATUS:-0}"
    ;;
  *" logs "*) echo "stub: the runtime's last log line" ;;
esac
exit 0
STUB
cat >"$stubs/image.sh" <<'STUB'
#!/usr/bin/env bash
# Fails every call with STUB_IMAGE_STATUS, or only the build (the call
# that names a use) with STUB_IMAGE_BUILD_STATUS.
printf '%s\n' "$*" >>"$STUB_LOG/image.calls"
[ -z "${STUB_IMAGE_STATUS:-}" ] || { echo "image: stub lookup failure" >&2; exit "$STUB_IMAGE_STATUS"; }
case " $* " in
  *" --for "*) [ -z "${STUB_IMAGE_BUILD_STATUS:-}" ] || { echo "image: stub build failure" >&2; exit "$STUB_IMAGE_BUILD_STATUS"; } ;;
esac
echo "$STUB_IMAGE"
STUB
# A BASH_ENV for the script: it writes its pid to $STOP_MARK and stops,
# once, when its function claim first probes a port, the claim already
# taken.
cat >"$scratch/claim-stop" <<'HOOK'
set -T
trap 'if [[ ${FUNCNAME[0]:-} == claim && $BASH_COMMAND == *held* && ! -e $STOP_MARK ]]; then echo $$ >"$STOP_MARK"; kill -STOP $$; fi' DEBUG
HOOK
cat >"$stubs/mix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG/mix.calls"
case "${1:-}" in
  cyfr.locus.dev_stack) ;;
  phx.server)
    # The server: its environment recorded, then serving until TERM, with
    # an asset watcher in its process group that ignores TERM; or ending
    # at once with STUB_SERVER_STATUS.
    env | sort >"$STUB_LOG/server.env"
    if [ -n "${STUB_SERVER_CHILD:-}" ]; then
      # A child listener in the server's group, which TERM does not stop.
      python3 -I -c 'import signal, socket, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(); time.sleep(300)' &
      echo "$!" >"$STUB_LOG/watcher.pid"
    fi
    [ -z "${STUB_SERVER_STATUS:-}" ] || exit "$STUB_SERVER_STATUS"
    (trap '' TERM; exec sleep 300) &
    echo "$!" >>"$STUB_LOG/watcher.pid"
    trap 'echo stopped >>"$STUB_LOG/server.events"; exit 0' TERM
    echo "$$" >"$STUB_LOG/server.pid"
    echo started >>"$STUB_LOG/server.events"
    while :; do sleep 0.1; done
    ;;
  *) echo "the stub runs cyfr.locus.dev_stack and phx.server alone, not ${1:-nothing}" >&2; exit 99 ;;
esac
shift
# shellcheck disable=SC2086
exec elixir $STUB_EBINS -e '
Mix.start()
try do
  Mix.Tasks.Cyfr.Locus.DevStack.run(System.argv())
rescue
  e in Mix.Error ->
    IO.puts(:stderr, "** (Mix) " <> Exception.message(e))
    System.halt(if is_integer(e.mix), do: e.mix, else: 1)
end' -- "$@"
STUB
cat >"$stubs/curl" <<'STUB'
#!/usr/bin/env python3
# The server's /mcp for the check: records the arguments, the header
# file's modes and content, and each action; answers each run completed,
# or refused where STUB_FAIL names its action. STUB_READ_RESULT stands for
# the read's result.
import json, os, sys
log = os.environ["STUB_LOG"]
args = sys.argv[1:]
with open(os.path.join(log, "curl.calls"), "a") as f:
    f.write(" ".join(args) + "\n")
header = "no header file"
for i, a in enumerate(args):
    if a == "-H" and args[i + 1].startswith("@"):
        path = args[i + 1][1:]
        modes = (oct(os.stat(path).st_mode & 0o777), oct(os.stat(os.path.dirname(path)).st_mode & 0o777))
        right = open(path).read() == "authorization: Bearer %s\n" % os.environ["STUB_TOKEN"]
        header = "file=%s dir=%s bearer=%s" % (modes[0], modes[1], "ok" if right else "wrong")
with open(os.path.join(log, "curl.headers"), "a") as f:
    f.write(header + "\n")
url = next(a for a in args if a.startswith("http"))
body = json.loads(args[args.index("-d") + 1])
given = body["params"]["arguments"]["input"]
action = given["action"]
with open(os.path.join(log, "curl.actions"), "a") as f:
    f.write("%s %s %s\n" % (action, url, given.get("path")))
store = os.path.join(log, "store.json")
files = json.load(open(store)) if os.path.exists(store) else {}
if action in os.environ.get("STUB_FAIL", "").split(","):
    print(json.dumps({"jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "stub %s failure" % action}}))
    sys.exit(0)
if action == "write_text":
    files[given["path"]] = given["content"]
    result = {"path": given["path"]}
elif action == "read_text":
    result = {"path": given["path"], "content": files.get(given["path"])}
    if "STUB_READ_RESULT" in os.environ:
        result = json.loads(os.environ["STUB_READ_RESULT"])
else:
    files.pop(given["path"], None)
    result = {"deleted": given["path"]}
json.dump(files, open(store, "w"))
run = {"status": "completed", "execution_id": "exec_stub", "result": result}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": json.dumps(run)}]}}))
STUB
chmod +x "$stubs/docker" "$stubs/mix" "$stubs/curl" "$stubs/image.sh"

# The local cyfr.run's checkout as the loop reads it, beside every case's
# checkout, where the loop looks by default: cyfr.run's
# docker-compose.prod.yml and docker-compose.local.yml in shape, with the
# names they interpolate, and a .env of the checkout's own that the loop
# never reads.
fake_run="$scratch/cyfr.run"
mkdir -p "$fake_run"
cat >"$fake_run/docker-compose.prod.yml" <<'YAML'
services:
  caddy:
    image: caddy:2-alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    environment:
      DOMAIN: "${DOMAIN:-cyfr.run}"
  cyfrrun:
    build:
      context: .
    environment:
      DOMAIN: "${DOMAIN:-cyfr.run}"
      ADMIN_TOKEN: "${ADMIN_TOKEN}"
      DATABASE_URL: "${DATABASE_URL}"
YAML
cat >"$fake_run/docker-compose.local.yml" <<'YAML'
services:
  caddy:
    ports: !override
      - "127.0.0.1:${CYFR_LOCAL_HTTPS_PORT:-18443}:443"
  cyfrrun:
    environment:
      DATABASE_URL: "postgres://cyfrrun:cyfrrun@postgres:5432/cyfrrun?sslmode=disable"
  postgres:
    image: postgres:16-alpine
    volumes:
      - postgres-data:/var/lib/postgresql/data
volumes:
  postgres-data:
YAML
printf '{$DOMAIN} {\n}\n' >"$fake_run/Caddyfile"
# commit_run DIR: DIR's files committed, as a cyfr.run checkout holds them.
commit_run() {
  git -C "$1" add -A -- . ':!.env' && git -C "$1" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -q -m "the local stack" && git -C "$1" rev-parse HEAD
}
git init -q "$fake_run"
fake_commit="$(commit_run "$fake_run")"
# Its .env, untracked, which no export holds and no image reaches.
printf 'DOMAIN=cyfr.run\nADMIN_TOKEN=the-checkouts-own\n' >"$fake_run/.env"
fake_listing() { (cd "$fake_run" && find . -printf '%p %m %s %T@\n' | sort && sha256sum ./*); }
fake_before="$(fake_listing)"
# The id the stubbed docker answers for the local cyfr.run's PostgreSQL
# volume, and the making it answers for that volume.
stack_id="$(printf '5a%.0s' {1..16})"
made_at="2026-11-12T08:00:00Z"
# The stubbed mix's resolver: a hosts table of the test's own, never the
# machine's hosts file, mapping both names to 127.0.0.1, or neither.
resolving="$scratch/resolving.inetrc"
unresolving="$scratch/unresolving.inetrc"
printf '{lookup, [file]}.\n{hosts_file, "/dev/null"}.\n{host, {127,0,0,1}, ["cyfr.test", "registry.cyfr.test"]}.\n' >"$resolving"
printf '{lookup, [file]}.\n{hosts_file, "/dev/null"}.\n' >"$unresolving"
mixed="$scratch/mixed.inetrc"
printf '{lookup, [file]}.\n{hosts_file, "/dev/null"}.\n{host, {127,0,0,1}, ["cyfr.test", "registry.cyfr.test"]}.\n{host, {203,0,113,9}, ["cyfr.test", "registry.cyfr.test"]}.\n' >"$mixed"
# The authority the stubbed docker copies out: a root the operating
# system's store holds, or one it does not.
trusted_root="$scratch/trusted-root.crt"
untrusted_root="$scratch/untrusted-root.crt"
elixir -e '
[trusted, untrusted] = System.argv()
pem = &:public_key.pem_encode([{:Certificate, &1, :not_encrypted}])
[{:cert, der, _} | _] = :public_key.cacerts_get()
File.write!(trusted, pem.(der))
%{cert: other} = :public_key.pkix_test_root_cert(~c"CYFR dev stack test", [])
File.write!(untrusted, pem.(other))' -- "$trusted_root" "$untrusted_root" ||
  failed "a root of the operating system's trust store, and one of none"


run_dir=""
token="dev-stack-test-token-$(openssl rand -hex 6)"
root_a="$(printf 'ab%.0s' {1..32})"
setup_a="$(printf '5e%.0s' {1..32})"
key_b="$(printf 'b1%.0s' {1..32})"
key_c="$(printf 'c2%.0s' {1..32})"
complete="CYFR_SETUP_TOKEN=$setup_a
CYFR_LOCUS_RUNTIME_ROOT=$root_a
CYFR_LOCUS_BACKENDS_KEY=$key_b
CYFR_LOCUS_BUILDS_KEY=$key_c
"
services="locus-runtime locus-backends locus-builds"
unset_keys="LOCUS_RUNTIME_KEY=unset|CYFR_LOCUS_BACKENDS_KEY=unset|CYFR_LOCUS_BUILDS_KEY=unset"

# Every slot's settings, as the task derives them from the slot's
# declarations and the local cyfr.run's apex scripts/dev-stack.sh hands
# it: the registry, OCI registry and account service are the local
# cyfr.run's, never cyfr.run.
every="$scratch/every-slot"
project "$every" "$override"
printf '%s' "$complete" >"$every/.env"
cp "$ROOT/.env.example" "$every/"
jsons=()
for k in $SLOTS; do
  resolve "$every" "$k" "$check_project" docker-compose.yml docker-compose.dev.yml >"$every/slot-$k.json" 2>/dev/null
  jsons+=("$every/slot-$k.json")
done
# shellcheck disable=SC2086
every_out="$(cd "$every" && env -i PATH="$PATH" HOME="$HOME" ERL_INETRC="$resolving" elixir $ebins -e '
Mix.start()
[root | jsons] = System.argv()
for json <- jsons do
  IO.puts("slot " <> json)
  Mix.Tasks.Cyfr.Locus.DevStack.run(["settings", json, "cyfr.test", root])
end' -- "$trusted_root" "${jsons[@]}" 2>&1)"
every_bad="$(printf '%s\n' "$every_out" | python3 -I -c '
import sys
slots, current, bad = {}, None, []
want = {"CYFR_REGISTRY_URL": "cyfr.test", "CYFR_OCI_REGISTRY_URL": "registry.cyfr.test", "CYFR_DIRECTORY_URL": "https://cyfr.test"}
for line in sys.stdin.read().splitlines():
    if line.startswith("slot "):
        current = line[5:]
        slots[current] = {}
    elif current and line.startswith("server ") and "=" in line:
        name, _, value = line[7:].partition("=")
        slots[current][name] = value
if len(slots) != 20:
    bad.append("the task answered %d slots, not 20" % len(slots))
for slot, server in slots.items():
    for name, value in want.items():
        if server.get(name) != value:
            bad.append("%s: %s is %r" % (slot, name, server.get(name)))
    if not server.get("CYFR_PRIVATE_EGRESS_TARGETS", "").endswith(",cyfr.test,registry.cyfr.test"):
        bad.append("%s: the private egress targets are %r" % (slot, server.get("CYFR_PRIVATE_EGRESS_TARGETS")))
    for name, value in server.items():
        if "cyfr.run" in value:
            bad.append("%s: %s names cyfr.run" % (slot, name))
print("\n".join(bad))')"
if [ -z "$every_bad" ]; then
  pass "every slot's registry, OCI registry and account service are the local cyfr.run's, never cyfr.run"
else
  failed "every slot's registry, OCI registry and account service" "$every_bad$(printf '\n%s' "$every_out" | tail -n 5)"
fi

# prepare SCRIPT NAME ENV_TEXT MODE [SLOT]: a git repository of its own
# holding SCRIPT and the run-names library, the shipped and the real
# override compose files, .env.example, .env as ENV_TEXT at MODE (none for
# no file), and SLOT remembered when given. Sets $case_dir and
# $case_project.
prepare() {
  case_dir="$scratch/case-$2"
  rm -rf "$case_dir" &&
    mkdir -p "$case_dir/scripts/lib" "$case_dir/tmp" "$case_dir/log" "$case_dir/run"
  git init -q "$case_dir"
  cp "$1" "$case_dir/scripts/dev-stack.sh"
  cp "$ROOT/scripts/lib/run-names.sh" "$case_dir/scripts/lib/"
  cp "$stubs/image.sh" "$case_dir/scripts/image.sh"
  cp "$ROOT/docker-compose.yml" "$ROOT/docker-compose.dev.yml" "$ROOT/.env.example" "$case_dir/"
  if [ "$4" != none ]; then
    printf '%s' "$3" >"$case_dir/.env"
    chmod "$4" "$case_dir/.env"
    cp -p "$case_dir/.env" "$case_dir/env.before"
  fi
  if [ -n "${5:-}" ]; then mkdir -p "$case_dir/data" && echo "$5" >"$case_dir/data/dev-stack.slot"; fi
  case_project="cyfr-dev-$(run_names_seed "$case_dir")"
}

# The script's environment: PATH, HOME, the machine's dev-stack directory
# under the case's, the stubs' settings and the given variables alone,
# every signal at its default as a shell starts a command.
launch() {
  (cd "$case_dir" && exec env -i PATH="$stubs:$PATH" HOME="$HOME" LC_ALL=C.UTF-8 TMPDIR="$case_dir/tmp" \
    XDG_RUNTIME_DIR="${run_dir:-$case_dir/run}" XDG_STATE_HOME="$case_dir/state" DEV_STACK_GRACE=1 \
    STUB_IMAGE="$stub_image" STUB_LOG="$case_dir/log" STUB_EBINS="$ebins" STUB_TOKEN="$token" \
    REAL_DOCKER="$REAL_DOCKER" ERL_INETRC="$resolving" STUB_ROOT="$trusted_root" STUB_VOLUME_MADE="$made_at" \
    STUB_STACK_ID="$stack_id" "$@" \
    python3 -I -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' bash scripts/dev-stack.sh $command >"$case_dir/out" 2>"$case_dir/err")
}

# stack SCRIPT NAME ENV_TEXT MODE COMMAND [VAR=VALUE...]: SCRIPT run to its
# end. Leaves $case_dir with the stubs' records, out, err, env.before and
# status.
stack() {
  prepare "$1" "$2" "$3" "$4" "${STACK_SLOT:-}"
  command="$5"
  shift 5
  launch "$@"
  echo "$?" >"$case_dir/status"
}

# signalled SCRIPT NAME SIGNAL: the loop run on a complete .env until its
# server serves, then sent SIGNAL. Fails when it does not end within 60 s.
signalled() {
  prepare "$1" "$2" "$complete" 0600
  command=""
  launch &
  local runner=$! pid i
  for i in $(seq 1 600); do
    [ -s "$case_dir/log/server.pid" ] && break
    kill -0 "$runner" 2>/dev/null || break
    sleep 0.1
  done
  pid="$(pgrep -f -n "^bash scripts/dev-stack.sh" -P "$runner" 2>/dev/null || true)"
  [ -n "$pid" ] || pid="$(ps -o pid= --ppid "$runner" | tr -d ' ' | head -n 1)"
  [ -n "$pid" ] && kill -s "$3" "$pid" 2>/dev/null
  for i in $(seq 1 600); do
    kill -0 "$runner" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$runner" 2>/dev/null; then
    kill -KILL "$runner"
    echo "timeout" >"$case_dir/status"
  else
    wait "$runner"
    echo "$?" >"$case_dir/status"
  fi
}

record() { cat "$case_dir/log/$1" 2>/dev/null; }
mode_of() { python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
status_is() { [ "$(cat "$case_dir/status")" = "$1" ] || echo "the run exited $(cat "$case_dir/status"), not $1: $(tail -n 3 "$case_dir/err")"; }
# The worktree's stack's docker calls, each compose call as `compose
# ARGS`, which the script makes with the case's project and its own files
# alone.
calls() {
  local acting="compose --env-file /dev/null -p $case_project --profile locus-builds -f docker-compose.yml -f docker-compose.dev.yml "
  record docker.calls | while IFS= read -r line; do
    case "$line" in *" -p cyfr-run-dev "* | "volume inspect "* | "image inspect "*) continue ;; esac
    printf '%s\n' "${line/#"$acting"/compose }"
  done
}
# The local cyfr.run's docker calls, without the keys: `names ARGS` for
# its compose reading the names its files interpolate, `stack ARGS` for
# its compose under its env file, each from the export of COMMIT (the
# fake checkout's by default) as its project directory, and the script
# that reads its id as `stack exec ... sh -c ID`.
machine="state/cyfr-dev-stack"
stack_calls() {
  local export="$case_dir/$machine/cyfr-run/${1:-$fake_commit}"
  local files="-p cyfr-run-dev --project-directory $export -f $export/docker-compose.prod.yml -f $export/docker-compose.local.yml "
  local names="compose --env-file /dev/null $files" acting="compose --env-file $case_dir/$machine/cyfr-run.env $files"
  record docker.calls | while IFS= read -r line; do
    line="${line%%|*}"
    case "$line" in
      "$acting"exec\ -T\ -u\ postgres\ postgres\ sh\ -c\ *) echo "stack exec -T -u postgres postgres sh -c ID" ;;
      "$names"*) printf 'names %s\n' "${line#"$names"}" ;;
      "$acting"*) printf 'stack %s\n' "${line#"$acting"}" ;;
      *" -p cyfr-run-dev "* | "volume inspect "* | "image inspect "*) printf '%s\n' "$line" ;;
    esac
  done
}
# A start of the local cyfr.run: its names read, its declarations
# resolved, the server's image looked at, its start (with a build and the
# built image's id read, unless KEPT says the commit's image is the one
# recorded), its authority copied out and its id read.
started_stack() {
  local inspect="image inspect --format {{.Id}} cyfr-run-dev-cyfrrun"
  printf '%s\n' "names config --variables" "stack config --format json" "$inspect"
  if [ "${1:-}" = kept ]; then
    echo "stack up --detach --wait"
  else
    printf '%s\n' "stack up --detach --build --wait" "$inspect"
  fi
  printf '%s\n' "stack cp caddy:/data/caddy/pki/authorities/local/root.crt $case_dir/$machine/cyfr-run-root.crt" \
    "stack exec -T -u postgres postgres sh -c ID"
}
# The expected calls: the leftovers removed at slot R (remembered, else 0),
# the networks listed, the declarations at slot K, the start with the keys,
# and the removal on the way out.
leftovers() { echo "compose down --remove-orphans|$unset_keys|slot=$1"; }
listed() { echo "network ls -q|$unset_keys|slot=unset"; }
declared() { echo "compose config --format json $services|$unset_keys|slot=$1"; }
up_call() {
  echo "compose up --detach --no-build --wait $services|LOCUS_RUNTIME_KEY=$(derived "$2")|CYFR_LOCUS_BACKENDS_KEY=$3|CYFR_LOCUS_BUILDS_KEY=$4|slot=$1"
}
removed() { echo "compose down --remove-orphans|$unset_keys|slot=$1"; }
# full_run K ROOT BACKENDS BUILDS [R]: the whole run of docker at slot K.
full_run() {
  printf '%s\n' "$(leftovers "${5:-0}")" "$(listed)" "$(declared "$1")" "$(up_call "$1" "$2" "$3" "$4")" "$(removed "$1")"
}
# The run's image.sh calls: the tag for the declarations, then the image
# with the run's pid as its use (the pid its slot's claim recorded at the
# start).
claim_of() { cat "${run_dir:-$case_dir/run}/cyfr-dev-slot.$1.lock" 2>/dev/null; }
image_calls() { printf '%s\n' "--undated --tag-only locus" "--undated --for $(record claim.at-up | sed -n 's/^pid //p') locus"; }
# want_settings K: the server's settings at slot K, from the override as
# the case's project resolves it, and the local cyfr.run's: the registry,
# OCI registry and account service, whatever .env says, and the two names
# the private egress names beside the backends guard's address.
want_settings() {
  resolve "$case_dir" "$1" "$case_project" docker-compose.yml docker-compose.dev.yml >"$case_dir/want.json" &&
    { python3 -I "$SHAPE" settings "$case_dir/want.json" | sed "s/^CYFR_PRIVATE_EGRESS_TARGETS=.*$/&,cyfr.test,registry.cyfr.test/"
      printf '%s\n' CYFR_REGISTRY_URL=cyfr.test CYFR_OCI_REGISTRY_URL=registry.cyfr.test \
        CYFR_DIRECTORY_URL=https://cyfr.test; } | sort
}
server_settings() { record server.env | grep -E '^(CYFR|LOCUS)_' | sort; }
# Nothing of the run is left: no server, no watcher, no private
# directory; the local cyfr.run's checkout is as it was, and nothing
# stopped the local cyfr.run.
nothing_left() {
  local pid
  for pid in $(record server.pid) $(record watcher.pid); do
    if kill -0 "$pid" 2>/dev/null; then echo "process $pid of the server is left running"; kill -KILL "$pid"; fi
  done
  [ -z "$(ls -A "$case_dir/tmp")" ] || echo "the run left $(ls -A "$case_dir/tmp") behind"
  [ "$(fake_listing)" = "$fake_before" ] || echo "the run changed the cyfr.run checkout: $(diff <(printf '%s\n' "$fake_before") <(fake_listing))"
  if stack_calls | grep -qE '^stack (down|stop|kill|rm)'; then echo "the run stopped the local cyfr.run: $(stack_calls)"; fi
}
remembers() { [ "$(cat "$case_dir/data/dev-stack.slot" 2>/dev/null)" = "$1" ] || echo "the worktree remembers slot $(cat "$case_dir/data/dev-stack.slot" 2>/dev/null), not $1"; }

# Each case prints why it fails, nothing when it holds.
case_provision() {
  stack "$1" provision "" none "" STUB_SERVER_STATUS=0
  status_is 0
  [ "$(mode_of "$case_dir/.env")" = 0o600 ] || echo ".env is $(mode_of "$case_dir/.env"), not 0o600"
  local setup root backends builds port
  port="$(value "$slot_a" DEV_STACK_PRISM_PORT)"
  setup="$(sed -n 's/^CYFR_SETUP_TOKEN=//p' "$case_dir/.env")"
  root="$(sed -n 's/^CYFR_LOCUS_RUNTIME_ROOT=//p' "$case_dir/.env")"
  backends="$(sed -n 's/^CYFR_LOCUS_BACKENDS_KEY=//p' "$case_dir/.env")"
  # The builds key, which a boot refuses without its URL, is the run's
  # alone: the builder's and the server's, never .env's.
  builds="$(record docker.calls | sed -n 's/^.* up .*|CYFR_LOCUS_BUILDS_KEY=\([0-9a-f]*\)|.*$/\1/p')"
  [ "$(cat "$case_dir/.env")" = "CYFR_SETUP_TOKEN=$setup
CYFR_LOCUS_RUNTIME_ROOT=$root
CYFR_LOCUS_BACKENDS_KEY=$backends" ] || echo ".env holds $(printf '%q' "$(cat "$case_dir/.env")")"
  for key in "$setup" "$root" "$backends" "$builds"; do
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || echo "a minted key is $(printf '%q' "$key"), not 64 lowercase hexadecimal digits"
  done
  [ "$(printf '%s\n' "$setup" "$root" "$backends" "$builds" | sort -u | wc -l)" = 4 ] || echo "the minted keys are not four"
  # The one secret printed: the setup link, as `cyfr init` prints it.
  grep -qxF "dev-stack: set up its first person, who administers it, at http://localhost:$port/setup#$setup" "$case_dir/out" ||
    echo "the run did not print the setup link: $(cat "$case_dir/out")"
  grep -qxF "dev-stack: .env is mode 0600 and now sets CYFR_SETUP_TOKEN, CYFR_LOCUS_RUNTIME_ROOT, CYFR_LOCUS_BACKENDS_KEY." "$case_dir/out" ||
    echo "the run did not say what it wrote: $(cat "$case_dir/out")"
  [ "$(calls)" = "$(full_run "$slot_a" "$root" "$backends" "$builds")" ] || echo "docker was handed: $(calls)"
  [ "$(stack_calls)" = "$(started_stack)" ] || echo "the local cyfr.run's docker calls: $(stack_calls)"
  [ "$(record docker.calls | head -n 7 | cut -d'|' -f1)" = "$(record docker.calls | grep -E -e ' -p cyfr-run-dev ' -e '^image inspect ' | cut -d'|' -f1)" ] ||
    echo "the local cyfr.run did not start before the worktree's stack: $(record docker.calls | cut -d'|' -f1)"
  # The export holds the commit's tracked files and the loop's marker,
  # and nothing else.
  local export="$case_dir/$machine/cyfr-run/$fake_commit"
  [ "$(cd "$export" 2>/dev/null && find . -type f | LC_ALL=C sort)" = $'./.cyfr-dev-stack-export\n./Caddyfile\n./docker-compose.local.yml\n./docker-compose.prod.yml' ] ||
    echo "the export of $fake_commit holds: $(cd "$export" 2>/dev/null && find . | sort | tr '\n' ' ')"
  grep -qxF "dev-stack: starting the local cyfr.run from $fake_run's commit $fake_commit, its committed HEAD (an uncommitted change there is not in it, and a new commit rebuilds it at the next start), unless it runs already; its first start builds it." "$case_dir/out" ||
    echo "the run did not name the commit it runs: $(cat "$case_dir/out")"
  grep -qxF "dev-stack: its registry is cyfr.test, its OCI registry registry.cyfr.test and its account service https://cyfr.test: the local cyfr.run." "$case_dir/out" ||
    echo "the run did not print the server's registry: $(cat "$case_dir/out")"
  grep -qxF "dev-stack: its admin pages are at https://cyfr.test/admin; its first administrator is made once at https://cyfr.test/admin/bootstrap?token=<ADMIN_TOKEN>, the token in $case_dir/$machine/cyfr-run.env." "$case_dir/out" ||
    echo "the run did not print the admin pages: $(cat "$case_dir/out")"
  [ "$(record image.calls)" = "$(image_calls "$slot_a")" ] || echo "image.sh was handed: $(record image.calls)"
  [ "$(record claim.at-up | sed -n 's/^checkout //p')" = "$case_dir" ] || echo "the claim did not name the loop at its start: $(record claim.at-up)"
  [ ! -s "$case_dir/run/cyfr-dev-slot.$slot_a.lock" ] || echo "the loop left its claim's record: $(claim_of "$slot_a")"
  [ "$(server_settings)" = "$(printf '%s\n' "$(want_settings "$slot_a")" "CYFR_LOCUS_BUILDS_KEY=$builds" | sort)" ] ||
    echo "the server's settings: $(server_settings)"
  record server.env | grep -qE "^(LOCUS_RUNTIME_KEY|CYFR_LOCUS_(RUNTIME_ROOT|BACKENDS_KEY)|DEV_STACK_(SLOT|PROJECT|IMAGE|[A-Z_]*_(PORT|NET)))=" &&
    echo "a key or a slot's value reached the server's environment"
  grep -qxF "dev-stack: CYFR starts at http://localhost:$port and reloads as its files change." "$case_dir/out" ||
    echo "the run did not print Prism's address: $(cat "$case_dir/out")"
  for key in "$root" "$backends" "$builds" "$(derived "$root")"; do
    if grep -qF "$key" "$case_dir/out" "$case_dir/err"; then echo "a key reached the output"; fi
  done
  remembers "$slot_a"
  nothing_left
}
case_retained() {
  local text
  for text in "$complete" "${complete/CYFR_LOCUS_RUNTIME_ROOT=/CYFR_LOCUS_RUNTIME_ROOT = }" \
    "${complete/$root_a/$root_a # the stack\'s root}"; do
    stack "$1" retained "$text" 0644 "" STUB_SERVER_STATUS=0
    status_is 0
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo ".env changed from $(printf '%q' "$text") to $(printf '%q' "$(cat "$case_dir/.env")")"
    [ "$(calls)" = "$(full_run "$slot_a" "$root_a" "$key_b" "$key_c")" ] || echo "on $(printf '%q' "$text") docker was handed: $(calls)"
    if grep -qF "$(derived "$root_a")" "$case_dir/out" "$case_dir/err"; then echo "the key reached the output"; fi
    if grep -qF "$setup_a" "$case_dir/out" "$case_dir/err"; then echo "a run that wrote no setup token printed it"; fi
  done
  # The registry, OCI registry and account service .env names give way to
  # the local cyfr.run's: no dev person, pull or publish reaches cyfr.run.
  stack "$1" retained-registry "${complete}CYFR_REGISTRY_URL=cyfr.run"$'\n'"CYFR_OCI_REGISTRY_URL=registry.cyfr.run"$'\n'"CYFR_DIRECTORY_URL=https://cyfr.run"$'\n' 0600 "" STUB_SERVER_STATUS=0
  status_is 0
  [ "$(record server.env | grep -E '^CYFR_(OCI_)?(REGISTRY|DIRECTORY)_URL=' | sort)" = $'CYFR_DIRECTORY_URL=https://cyfr.test\nCYFR_OCI_REGISTRY_URL=registry.cyfr.test\nCYFR_REGISTRY_URL=cyfr.test' ] ||
    echo "the server's registry, OCI registry and account service: $(record server.env | grep -E '^CYFR_(OCI_)?(REGISTRY|DIRECTORY)_URL=')"
  nothing_left
}
# A setting .env holds that disagrees with the slot the loop takes is
# refused by name, before any container starts or image builds.
case_refused() {
  local line name
  for line in "CYFR_LOCUS_RUNTIME_WORKERS = wrk_elsewhere=http://127.0.0.1:4999" "CYFR_HOST_API_BIND=0.0.0.0 # all of them" \
    "CYFR_HOST_API_URL=http://cyfr:4300" "CYFR_PORT=4999" "CYFR_PROXY_PORT=4999" "CYFR_LOCUS_BACKENDS_URL=http://locus-backends:4101"; do
    name="${line%%[ =]*}"
    stack "$1" refused "$complete$line"$'\n' 0644 "" STUB_SERVER_STATUS=0
    [ "$(cat "$case_dir/status")" != 0 ] || echo "the run accepted $line"
    grep -qF "dev-stack: $name is " "$case_dir/err" || echo "the refusal does not name $name: $(cat "$case_dir/err")"
    [ "$(calls)" = "$(printf '%s\n' "$(leftovers 0)" "$(listed)" "$(declared "$slot_a")")" ] || echo "docker ran past a disagreeing $name: $(calls)"
    [ "$(record image.calls)" = "--undated --tag-only locus" ] || echo "the image was built past a disagreeing $name: $(record image.calls)"
    [ -z "$(record server.env)" ] || echo "the server started though $name disagreed"
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo ".env changed on a refusal of $name"
  done
  stack "$1" empty-override "$complete" 0644 "" CYFR_LOCUS_BACKENDS_KEY=
  grep -qF "CYFR_LOCUS_BACKENDS_KEY is set empty in the environment" "$case_dir/err" || echo "the empty override's refusal: $(cat "$case_dir/err")"
  calls | grep -q " up " && echo "docker started the stack under an empty key override: $(calls)"
}
case_release_root() {
  local sentence="dev-stack: RELEASE_ROOT is set, and it names a release: the dev stack runs CYFR from the checkout, which reads the .env at its root. Unset RELEASE_ROOT and run again."
  local command
  mkdir -p "$scratch/release"
  printf '%s' "$complete" >"$scratch/release/.env"
  for command in "" check; do
    STACK_SLOT="$slot_a" stack "$1" release-root "CYFR_SETUP_TOKEN=$setup_a"$'\n' 0644 "$command" \
      RELEASE_ROOT="$scratch/release" CYFR_TOKEN="$token" STUB_SERVER_STATUS=0
    [ "$(cat "$case_dir/status")" != 0 ] || echo "${command:-the loop} exited 0 under RELEASE_ROOT"
    [ "$(tail -n 1 "$case_dir/err")" = "$sentence" ] || echo "${command:-the loop} did not end on the RELEASE_ROOT refusal: $(cat "$case_dir/err")"
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo "${command:-the loop} changed .env under RELEASE_ROOT: $(cat "$case_dir/.env")"
    calls | grep -q " up " && echo "${command:-the loop} started the stack under RELEASE_ROOT: $(calls)"
    [ -z "$(record server.env)$(record curl.actions)" ] || echo "${command:-the loop} served or ran a component under RELEASE_ROOT"
  done
}
# hold PORT: a listener on 127.0.0.1:PORT until the case ends. Sets $holder.
hold() {
  python3 -I -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(120)' "$1" >/dev/null 2>&1 &
  holder=$!
  holders+=("$holder")
  for _ in $(seq 1 50); do ss -Hltn "sport = :$1" | grep -q . && break; sleep 0.1; done
}
# A slot whose Prism port something else holds is passed: the loop takes
# the next free slot, says why, prints that slot's address and remembers it.
case_port_held() {
  local port
  port="$(value "$slot_a" DEV_STACK_PRISM_PORT)"
  hold "$port"
  STACK_SLOT="$slot_a" stack "$1" port-held "$complete" 0600 "" STUB_SERVER_STATUS=0
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  status_is 0
  grep -qxF "dev-stack: slot $slot_a is taken (127.0.0.1:$port, held by python3 (pid $holder)), so this worktree's loop takes slot $slot_b." "$case_dir/out" ||
    echo "the run did not say why it passed slot $slot_a: $(cat "$case_dir/out")"
  grep -qxF "dev-stack: CYFR starts at http://localhost:$(value "$slot_b" DEV_STACK_PRISM_PORT) and reloads as its files change." "$case_dir/out" ||
    echo "the run did not print slot $slot_b's address: $(cat "$case_dir/out")"
  [ "$(calls)" = "$(full_run "$slot_b" "$root_a" "$key_b" "$key_c" "$slot_a")" ] || echo "docker was handed: $(calls)"
  remembers "$slot_b"
}
# A slot one of whose subnets a Docker network overlaps is passed.
case_network_overlap() {
  local net
  net="$(value "$slot_a" DEV_STACK_BUILDS_NET)"
  STACK_SLOT="$slot_a" stack "$1" network-overlap "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_NETWORKS="someones_net $net.64/26"
  status_is 0
  grep -qxF "dev-stack: slot $slot_a is taken (the network someones_net ($net.64/26)), so this worktree's loop takes slot $slot_b." "$case_dir/out" ||
    echo "the run did not say which network holds slot $slot_a: $(cat "$case_dir/out")"
  [ "$(calls | sed -n 4p)" = "$(declared "$slot_b")" ] || echo "the loop did not take slot $slot_b: $(calls)"
}
# claim_slot K CHECKOUT: slot K claimed by another loop of the host, in
# $run_dir, until the case ends, its record naming CHECKOUT and the live
# process that holds the claim, with its start time. Sets $claimer.
claim_slot() {
  local file="$run_dir/cyfr-dev-slot.$1.lock"
  : >"$file"
  flock "$file" sleep 120 >/dev/null 2>&1 &
  claimer=$!
  holders+=("$claimer")
  for _ in $(seq 1 50); do flock -n "$file" true || break; sleep 0.1; done
  printf 'pid %s\nstarted %s\ncheckout %s\n' "$claimer" "$(lstart "$claimer")" "$2" >"$file"
}
lstart() { ps -o lstart= -p "$1" | sed 's/^ *//; s/ *$//'; }
# A claim whose record names a live process that is not its holder, as a
# pid reused since a killed loop wrote it, names no one: here slot 0's
# record in the form a loop wrote before records carried a start time,
# and slot 1's with a start time its pid does not have.
case_claim_unverified() {
  local k other file0 file1
  run_dir="$scratch/case-unverified-run"
  rm -rf "$run_dir" && mkdir -p "$run_dir"
  for k in $SLOTS; do claim_slot "$k" "/worktree/$k"; done
  sleep 120 >/dev/null 2>&1 &
  other=$!
  holders+=("$other")
  file0="$run_dir/cyfr-dev-slot.0.lock" file1="$run_dir/cyfr-dev-slot.1.lock"
  printf 'pid %s\ncheckout /previous/worktree\n' "$other" >"$file0"
  printf 'pid %s\nstarted Thu Jan  1 00:00:00 1970\ncheckout /previous/worktree\n' "$other" >"$file1"
  stack "$1" unverified "$complete" 0600 "" STUB_SERVER_STATUS=0
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on with every slot taken"
  case "$(tail -n 1 "$case_dir/err")" in
    "dev-stack: every slot is taken: slot 0: a loop whose record cannot be verified ($file0); slot 1: a loop whose record cannot be verified ($file1); slot 2: the loop of /worktree/2 (pid "*) ;;
    *) echo "the refusal names a process that does not hold the claim: $(tail -n 1 "$case_dir/err" | cut -c1-300)" ;;
  esac
  kill "$other" 2>/dev/null
  run_dir=""
}
# The slot a worktree remembers is reused while it is free; when another
# loop claims it, the loop takes the first free slot and says whose it is.
case_remembered() {
  run_dir="$scratch/case-remembered-run"
  rm -rf "$run_dir" && mkdir -p "$run_dir"
  STACK_SLOT="$slot_b" stack "$1" remembered "$complete" 0600 "" STUB_SERVER_STATUS=0
  status_is 0
  [ "$(calls | sed -n 3p)" = "$(declared "$slot_b")" ] || echo "the remembered slot $slot_b was not reused: $(calls)"
  grep -qF "is taken" "$case_dir/out" && echo "the run said a slot was taken: $(cat "$case_dir/out")"
  claim_slot "$slot_b" /the/other/worktree
  STACK_SLOT="$slot_b" stack "$1" remembered-taken "$complete" 0600 "" STUB_SERVER_STATUS=0
  status_is 0
  grep -qxF "dev-stack: slot $slot_b is taken (the loop of /the/other/worktree (pid $claimer)), so this worktree's loop takes slot $slot_a." "$case_dir/out" ||
    echo "the run did not name the remembered slot's loop: $(cat "$case_dir/out")"
  [ "$(calls | sed -n 3p)" = "$(declared "$slot_a")" ] || echo "the loop did not take the first free slot: $(calls)"
  remembers "$slot_a"
  run_dir=""
}
# With every slot taken the loop refuses, naming each slot's holder, and
# starts nothing.
case_all_taken() {
  local k want=()
  run_dir="$scratch/case-all-run"
  rm -rf "$run_dir" && mkdir -p "$run_dir"
  for k in $SLOTS; do
    claim_slot "$k" "/worktree/$k"
    want+=("slot $k: the loop of /worktree/$k (pid $claimer)")
  done
  stack "$1" all-taken "$complete" 0600 "" STUB_SERVER_STATUS=0
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run went on with every slot taken"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: every slot is taken: $(printf '%s; ' "${want[@]}" | sed 's/; $//')." ] ||
    echo "the refusal does not name every slot's holder: $(tail -n 1 "$case_dir/err")"
  [ "$(calls)" = "$(printf '%s\n' "$(leftovers 0)" "$(listed)")" ] || echo "docker ran with every slot taken: $(calls)"
  [ -z "$(record server.env)" ] || echo "the server started with every slot taken"
  run_dir=""
}
case_start_fails() {
  stack "$1" start-fails "$complete" 0600 "" STUB_UP_STATUS=1 STUB_SERVER_STATUS=0
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run exited 0 though the containers did not start"
  [ "$(calls)" = "$(printf '%s\n' "$(leftovers 0)" "$(listed)" "$(declared "$slot_a")" \
    "$(up_call "$slot_a" "$root_a" "$key_b" "$key_c")" "compose logs --tail 30|$unset_keys|slot=$slot_a" "$(removed "$slot_a")")" ] ||
    echo "after a failed start docker was handed: $(calls)"
  grep -qF "stub: the runtime's last log line" "$case_dir/err" || echo "the failed start did not show the containers' logs: $(cat "$case_dir/err")"
  [ -z "$(record server.env)" ] || echo "the server started though the containers did not"
  if grep -qF "CYFR starts at" "$case_dir/out"; then echo "the run printed its address after a failed start"; fi
  nothing_left
}
case_image_fails() {
  stack "$1" image-fails "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_IMAGE_STATUS=1
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run exited 0 though the image did not build"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: scripts/image.sh gave no Locus image for this tree; its output ends above." ] ||
    echo "the run did not end on the image's failure: $(cat "$case_dir/err")"
  calls | grep -q " up " && echo "the stack started without an image: $(calls)"
}
# A build that fails ends the start before any container: the slot's
# claim and the private directory go with it.
case_image_build_fails() {
  stack "$1" image-build-fails "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_IMAGE_BUILD_STATUS=1
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run exited 0 though the image did not build"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: scripts/image.sh gave no Locus image for this tree; its output ends above." ] ||
    echo "the run did not end on the build's failure: $(cat "$case_dir/err")"
  [ "$(record image.calls | sed -E 's/--for [0-9]+/--for PID/')" = $'--undated --tag-only locus\n--undated --for PID locus' ] ||
    echo "image.sh was handed: $(record image.calls)"
  calls | grep -q " up " && echo "the stack started without an image: $(calls)"
  flock -n "$case_dir/run/cyfr-dev-slot.$slot_a.lock" true || echo "the failed start kept slot $slot_a's claim"
  [ -z "$(record server.env)" ] || echo "the server started without an image"
  nothing_left
}
# A start that finds a slot's claim held names the loop that holds it,
# even one stopped the instant after it took the claim, before it looked
# at the slot: here every other slot is claimed too.
case_claim_named() {
  local first pid k runner
  run_dir="$scratch/case-named-run"
  rm -rf "$run_dir" && mkdir -p "$run_dir"
  prepare "$1" named-first "$complete" 0600
  first="$case_dir"
  command=""
  launch BASH_ENV="$scratch/claim-stop" STOP_MARK="$first/stopped" STUB_SERVER_STATUS=0 &
  runner=$!
  for _ in $(seq 1 300); do [ -s "$first/stopped" ] && break; sleep 0.1; done
  pid="$(cat "$first/stopped" 2>/dev/null)"
  [ -n "$pid" ] || { echo "the first loop never took a claim"; kill "$runner" 2>/dev/null; run_dir=""; return; }
  for k in $(seq 1 19); do claim_slot "$k" "/worktree/$k"; done
  stack "$1" named-second "$complete" 0600 "" STUB_SERVER_STATUS=0
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the second loop went on with every slot taken"
  case "$(tail -n 1 "$case_dir/err")" in
    "dev-stack: every slot is taken: slot 0: the loop of $first (pid $pid); slot 1: "*) ;;
    *) echo "the refusal does not name the loop that holds slot 0: $(tail -n 1 "$case_dir/err" | cut -c1-200)" ;;
  esac
  kill -CONT "$pid" 2>/dev/null
  wait "$runner"
  run_dir=""
}
case_server_ends() {
  stack "$1" server-ends "$complete" 0600 "" STUB_SERVER_STATUS=3
  status_is 3
  [ "$(calls)" = "$(full_run "$slot_a" "$root_a" "$key_b" "$key_c")" ] || echo "after the server ended docker was handed: $(calls)"
  nothing_left
}
case_interrupted() {
  local signal want
  for signal in INT TERM HUP; do
    case "$signal" in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
    signalled "$1" "signal-$signal" "$signal"
    status_is "$want"
    [ "$(record server.events)" = $'started\nstopped' ] || echo "on $signal the server was not stopped: $(record server.events)"
    host_free "$slot_a" || echo "on $signal slot $slot_a's ports are still held"
    [ "$(calls)" = "$(full_run "$slot_a" "$root_a" "$key_b" "$key_c")" ] || echo "on $signal docker was handed: $(calls)"
    nothing_left
  done
}
case_check() {
  STACK_SLOT="$slot_b" stack "$1" check "$complete" 0644 check CYFR_TOKEN="$token"
  status_is 0
  local mcp="http://127.0.0.1:$(value "$slot_b" DEV_STACK_PRISM_PORT)/mcp"
  [ "$(record curl.actions | awk '{print $1, $2}' | sort -u)" = "delete $mcp
read_text $mcp
write_text $mcp" ] || echo "the check ran: $(record curl.actions)"
  [ "$(record curl.headers | sort -u)" = "file=0o600 dir=0o700 bearer=ok" ] || echo "the bearer's header file: $(record curl.headers)"
  if grep -qF "$token" "$case_dir/log/curl.calls" "$case_dir/out" "$case_dir/err"; then echo "the token reached curl's arguments or the output"; fi
  [ "$(calls)" = "$(declared "$slot_b")" ] || echo "the check ran docker: $(calls)"
  [ -z "$(stack_calls)" ] || echo "the check touched the local cyfr.run: $(stack_calls)"
  [ "$(record image.calls)" = "--undated --tag-only locus" ] || echo "the check asked for an image: $(record image.calls)"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "the check left a file in the athanor: $(cat "$case_dir/log/store.json")"
  nothing_left
  stack "$1" check-nothing "$complete" 0644 check CYFR_TOKEN="$token"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the check went on in a worktree whose loop never started"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: no loop has started in this worktree, so it has no slot; scripts/dev-stack.sh starts one." ] ||
    echo "the check did not say no loop started: $(cat "$case_dir/err")"
}
case_failed_read() {
  STACK_SLOT="$slot_a" stack "$1" failed-read "$complete" 0600 check CYFR_TOKEN="$token" STUB_FAIL=read_text
  [ "$(cat "$case_dir/status")" != 0 ] || echo "check exited 0 though its read failed"
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "after the failed read the check ran: $(record curl.actions)"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: refused: stub read_text failure" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "the failed read left its file: $(cat "$case_dir/log/store.json")"
  nothing_left

  STACK_SLOT="$slot_a" stack "$1" failed-delete "$complete" 0600 check CYFR_TOKEN="$token" STUB_FAIL=read_text,delete
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "with the delete failing too the check ran: $(record curl.actions)"
  local left
  left="$(record curl.actions | awk 'NR == 1 {print $3}')"
  grep -qF "dev-stack: $left is left in the athanor's storage" "$case_dir/err" || echo "the check did not name the file it left: $(cat "$case_dir/err")"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: refused: stub read_text failure" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
}
case_failed_parse() {
  STACK_SLOT="$slot_a" stack "$1" failed-parse "$complete" 0600 check CYFR_TOKEN="$token" STUB_READ_RESULT='[]'
  [ "$(cat "$case_dir/status")" != 0 ] || echo "check exited 0 though its read answered no content"
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "after a read with no content the check ran: $(record curl.actions)"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: the run answered no content: []" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "a read with no content left its file: $(cat "$case_dir/log/store.json")"
  nothing_left
}
case_project_env() {
  stack "$1" project-env "$complete" 0600 "" STUB_SERVER_STATUS=0 \
    COMPOSE_PROJECT_NAME=dev-stack-neighbour COMPOSE_FILE=neighbour.yml COMPOSE_PROFILES=public
  status_is 0
  [ "$(calls)" = "$(full_run "$slot_a" "$root_a" "$key_b" "$key_c")" ] || echo "with a neighbour's COMPOSE_* docker was handed: $(calls)"
  [ -z "$(record docker.env | tr -d ' \n')" ] || echo "docker saw the caller's $(record docker.env | sort -u | tr '\n' ' ')"
  nothing_left
}
case_server_child() {
  stack "$1" server-child "$complete" 0600 "" STUB_SERVER_STATUS=3 STUB_SERVER_CHILD=1
  status_is 3
  [ -s "$case_dir/log/watcher.pid" ] || echo "the server left no child to look for"
  [ "$(calls)" = "$(full_run "$slot_a" "$root_a" "$key_b" "$key_c")" ] || echo "after the server ended docker was handed: $(calls)"
  nothing_left
}
case_blank_root() {
  stack "$1" blank-root "" none "" STUB_SERVER_STATUS=0 CYFR_LOCUS_RUNTIME_ROOT=" "
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run went on with a root of one space"
  grep -qF "dev-stack: CYFR_LOCUS_RUNTIME_ROOT holds only whitespace" "$case_dir/err" || echo "the refusal: $(cat "$case_dir/err")"
  [ ! -s "$case_dir/.env" ] || echo ".env gained $(cat "$case_dir/.env" | sed 's/=.*/=…/' | tr '\n' ' ') on the refusal"
  calls | grep -q " up " && echo "docker started the stack past a blank root: $(calls)"
}
case_locked() {
  local command holder lock
  for command in "" down; do
    prepare "$1" locked "$complete" 0600
    lock="$case_dir/run/$case_project.dev-stack.lock"
    printf 'pid 4242\ncheckout /elsewhere\n' >"$lock"
    flock "$lock" sleep 60 >/dev/null 2>&1 &
    holder=$!
    holders+=("$holder")
    for _ in $(seq 1 50); do flock -n "$lock" true || break; sleep 0.1; done
    launch STUB_SERVER_STATUS=0
    echo "$?" >"$case_dir/status"
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    [ "$(cat "$case_dir/status")" != 0 ] || echo "${command:-the loop} went on while another run held the worktree's stack"
    [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: another run of this worktree's dev stack (pid 4242, checkout /elsewhere) holds $lock; stop it, or wait for it to end." ] ||
      echo "${command:-the loop} did not name the holder: $(cat "$case_dir/err")"
    [ -z "$(record docker.calls)" ] || echo "${command:-the loop} ran docker while another run held the worktree's stack: $(record docker.calls)"
    [ ! -e "$case_dir/.env" ] || cmp -s "$case_dir/.env" "$case_dir/env.before" || echo "${command:-the loop} changed .env while refused"
  done
}
# The loops of two worktrees on one host: the first held inside its
# start; the second takes the next slot and runs, and its `down` removes
# only its own project's containers; the first's are untouched.
case_two_checkouts() {
  local first second runner
  run_dir="$scratch/case-two-run"
  rm -rf "$run_dir" && mkdir -p "$run_dir"
  prepare "$1" two-first "$complete" 0600
  first="$case_dir"
  local first_project="$case_project"
  command=""
  launch STUB_SERVER_STATUS=0 STUB_UP_HOLD=1 &
  runner=$!
  for _ in $(seq 1 600); do [ -e "$first/log/up.held" ] && break; kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
  [ -e "$first/log/up.held" ] || echo "the first worktree's loop never reached its start"
  prepare "$1" two-second "$complete" 0600 "$slot_a"
  second="$case_dir"
  [ "$case_project" != "$first_project" ] || echo "the two worktrees have one project, $case_project"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$second/status"
  status_is 0
  grep -qxF "dev-stack: slot $slot_a is taken (the loop of $first (pid $(claim_of "$slot_a" | sed -n 's/^pid //p'))), so this worktree's loop takes slot $slot_b." "$second/out" ||
    echo "the second worktree's loop did not name the first's: $(cat "$second/out")"
  [ "$(calls)" = "$(full_run "$slot_b" "$root_a" "$key_b" "$key_c" "$slot_a")" ] || echo "the second worktree's loop handed docker: $(calls)"
  command=down
  launch
  echo "$?" >"$second/status"
  status_is 0
  [ "$(calls | tail -n 1)" = "$(removed "$slot_b")" ] || echo "the second worktree's down handed docker: $(calls | tail -n 1)"
  [ "$(stack_calls | grep -c '^stack up ')" = 1 ] && ! stack_calls | grep -qE '^stack (down|stop|kill|rm)' ||
    echo "the second worktree's run and down touched the local cyfr.run beyond its start: $(stack_calls)"
  case_dir="$first" case_project="$first_project"
  [ "$(calls)" = "$(printf '%s\n' "$(leftovers 0)" "$(listed)" "$(declared "$slot_a")" "$(up_call "$slot_a" "$root_a" "$key_b" "$key_c")")" ] ||
    echo "the first worktree's containers saw: $(calls)"
  touch "$first/log/up.release"
  wait "$runner"
  echo "$?" >"$first/status"
  status_is 0
  run_dir=""
}
# recorded_server [START]: a process group of its own standing for a
# killed run's server, recorded in the lock as the run records its server,
# with START as its start time (its own by default). Sets $orphan.
recorded_server() {
  python3 -I -c 'import os, time; os.setpgid(0, 0); time.sleep(120)' >/dev/null 2>&1 &
  orphan=$!
  disown "$orphan"
  holders+=("$orphan")
  sleep 0.2
  printf 'pid 4242\ncheckout /elsewhere\nserver %s %s\n' "$orphan" "${1:-$(ps -o lstart= -p "$orphan")}" \
    >"$case_dir/run/$case_project.dev-stack.lock"
}
# dead_group GROUP: no process is left in GROUP, waited for up to 5 s.
dead_group() {
  for _ in $(seq 1 50); do kill -0 -- "-$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
case_down_orphan() {
  local pid
  prepare "$1" down-orphan "$complete" 0600 "$slot_b"
  recorded_server
  pid="$orphan"
  command=down
  launch
  echo "$?" >"$case_dir/status"
  status_is 0
  sleep 0.2
  if kill -0 "$pid" 2>/dev/null; then echo "down left the killed run's server $pid running"; kill -KILL "$pid"; fi
  [ "$(calls)" = "$(removed "$slot_b")" ] || echo "down handed docker: $(calls)"
  [ ! -s "$case_dir/run/$case_project.dev-stack.lock" ] || echo "down left the record: $(cat "$case_dir/run/$case_project.dev-stack.lock")"

  # A start refuses while the killed run's server still serves, and keeps
  # its record, so the worktree's next down stops it.
  prepare "$1" start-orphan "$complete" 0600
  recorded_server
  pid="$orphan"
  command=""
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$case_dir/status"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "a start went on beside the server a killed run left"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: the server a killed run of this worktree left still runs (process group $pid); \`scripts/dev-stack.sh down\` stops it." ] ||
    echo "the start did not name the killed run's server: $(cat "$case_dir/err")"
  [ -z "$(record docker.calls)" ] || echo "a start beside a killed run's server ran docker: $(record docker.calls)"
  command=down
  launch
  echo "$?" >"$case_dir/status"
  status_is 0
  if ! dead_group "$pid"; then echo "after a refused start, down left the killed run's server $pid running"; kill -KILL -- "-$pid" 2>/dev/null; fi

  # A down that fails at the image lookup has stopped the server already,
  # and a second down finds nothing left to stop.
  prepare "$1" down-lookup "$complete" 0600
  recorded_server
  pid="$orphan"
  command=down
  launch STUB_IMAGE_STATUS=1
  echo "$?" >"$case_dir/status"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "down exited 0 though the image lookup failed"
  launch
  echo "$?" >"$case_dir/status"
  status_is 0
  if ! dead_group "$pid"; then echo "after a down whose lookup failed, a second down left the killed run's server $pid running"; kill -KILL -- "-$pid" 2>/dev/null; fi

  # A record whose group is now some other process's stops nothing.
  prepare "$1" down-stale "$complete" 0600
  recorded_server "Thu Jan  1 00:00:00 1970"
  pid="$orphan"
  command=down
  launch
  echo "$?" >"$case_dir/status"
  status_is 0
  kill -0 "$pid" 2>/dev/null || echo "down stopped process group $pid, which the record's start time does not match"
  kill -KILL "$pid" 2>/dev/null
}

# bound_record TEXT: the worktree's record of the id of the local cyfr.run
# its database's people were made at.
bound_record() { mkdir -p "$case_dir/data/dev-stack" && printf '%s\n' "$1" >"$case_dir/data/dev-stack/cyfr-run.id"; }
delete_sentence="delete the dev database and start again: rm -f data/cyfr.db* (or the file CYFR_DATABASE_PATH names; under PostgreSQL, drop the database CYFR_DATABASE_URL names)"
# other_sentence RECORDED: the refusal of a database made at another local
# cyfr.run than the running one.
other_sentence() {
  echo "dev-stack: This database's people were made at another local cyfr.run than the running one (data/dev-stack/cyfr-run.id records $1; the running one is $stack_id), and their accounts are there alone. If that one was reset (\`docker compose -p cyfr-run-dev down -v\`), it is gone for good: $delete_sentence. If this database is the newer one and the running cyfr.run an older copy of the volume cyfr-run-dev_postgres-data put back since, put back the copy this database was made at, or $delete_sentence."
}
# A new database records the id of the local cyfr.run it is made at,
# whatever an earlier record named.
case_new_database() {
  prepare "$1" new-database "$complete" 0600
  command=""
  bound_record "$(printf '0b%.0s' {1..16})"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$case_dir/status"
  status_is 0
  [ "$(cat "$case_dir/data/dev-stack/cyfr-run.id")" = "$stack_id" ] ||
    echo "a new database recorded $(cat "$case_dir/data/dev-stack/cyfr-run.id"), not the running local cyfr.run's $stack_id"
  nothing_left
}
# A database that is not new runs at whatever slot is free while the local
# cyfr.run it was made at runs.
case_same_stack() {
  prepare "$1" same-stack "$complete" 0600 "$slot_b"
  command=""
  mkdir -p "$case_dir/data" && : >"$case_dir/data/cyfr.db"
  bound_record "$stack_id"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$case_dir/status"
  status_is 0
  [ "$(calls | sed -n 3p)" = "$(declared "$slot_b")" ] || echo "the remembered slot $slot_b was not taken: $(calls)"
  [ "$(cat "$case_dir/data/dev-stack/cyfr-run.id")" = "$stack_id" ] || echo "the record changed: $(cat "$case_dir/data/dev-stack/cyfr-run.id")"
  nothing_left
}
# A database that is not new, made at another local cyfr.run, or with no
# record at all, refuses with the ways out before any slot is taken, and
# leaves the local cyfr.run running.
case_stack_reset() {
  local recorded want
  for recorded in "$(printf '0b%.0s' {1..16})" ""; do
    prepare "$1" stack-reset "$complete" 0600
    command=""
    mkdir -p "$case_dir/data" && : >"$case_dir/data/cyfr.db"
    if [ -n "$recorded" ]; then
      bound_record "$recorded"
      want="$(other_sentence "$recorded")"
    else
      want="dev-stack: This database's people were made before the loop recorded the local cyfr.run that holds their accounts (data/dev-stack/cyfr-run.id is absent), beside the stand-in an earlier loop ran, and no local cyfr.run holds them: $delete_sentence."
    fi
    launch STUB_SERVER_STATUS=0
    echo "$?" >"$case_dir/status"
    [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on though its database's local cyfr.run is not the running one"
    [ "$(tail -n 1 "$case_dir/err")" = "$want" ] || echo "the refusal does not name the ways out: $(tail -n 1 "$case_dir/err")"
    [ "$(calls)" = "$(leftovers 0)" ] || echo "docker ran past the refusal: $(calls)"
    [ "$(stack_calls)" = "$(started_stack)" ] || echo "the local cyfr.run's docker calls: $(stack_calls)"
    [ ! -e "$case_dir/data/dev-stack.slot" ] || echo "the loop remembered slot $(cat "$case_dir/data/dev-stack.slot")"
    nothing_left
  done
}
# A volume removed and made again within one second keeps its making's
# time: a database bound by that time is refused once the volume is
# another, since the binding is the id inside the volume.
case_volume_replaced() {
  prepare "$1" volume-replaced "$complete" 0600
  command=""
  mkdir -p "$case_dir/data" && : >"$case_dir/data/cyfr.db"
  bound_record "$made_at"
  # The record a loop bound by the volume's making kept, which such a loop
  # accepts once the replaced volume answers the same time.
  printf '%s\n' "$made_at" >"$case_dir/data/dev-stack/cyfr-run.made"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$case_dir/status"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "a retained database was accepted after its volume was replaced with an identical CreatedAt"
  [ "$(tail -n 1 "$case_dir/err")" = "$(other_sentence "$made_at")" ] || echo "the refusal: $(tail -n 1 "$case_dir/err")"
  nothing_left
}
# A commit that lacks a file the stack binds refuses before Docker could
# make a directory for it, and nothing lands in the checkout.
case_missing_bind() {
  local other="$scratch/missing-bind-cyfr.run" before
  rm -rf "$other" && cp -r "$fake_run" "$other"
  git -C "$other" rm -q Caddyfile
  commit_run "$other" >/dev/null
  before="$(cd "$other" && find . -printf '%p %m %s %T@\n' | sort)"
  stack "$1" missing-bind "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$other"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "a commit with no Caddyfile for the caddy service to bind was accepted"
  case "$(tail -n 1 "$case_dir/err")" in
    "dev-stack: the local stack of $other's commit "*" is not the one the loop runs: its caddy service binds Caddyfile, which the commit does not hold.") ;;
    *) echo "the refusal does not name the missing bind: $(tail -n 1 "$case_dir/err")" ;;
  esac
  record docker.calls | grep -q " up " && echo "docker started the stack with a bind source missing: $(stack_calls)"
  [ "$(cd "$other" && find . -printf '%p %m %s %T@\n' | sort)" = "$before" ] || echo "the run changed the checkout"
  nothing_left
}
# A new commit in the checkout is exported and run at the next start, and
# the export of the commit before it goes.
case_new_commit() {
  local other="$scratch/new-commit-cyfr.run" second
  rm -rf "$other" && cp -r "$fake_run" "$other"
  stack "$1" new-commit "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$other"
  status_is 0
  printf '# a later commit\n' >>"$other/Caddyfile"
  # An uncommitted change is not in the stack.
  printf 'uncommitted\n' >"$other/uncommitted.txt"
  second="$(git -C "$other" add Caddyfile && git -C "$other" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m later && git -C "$other" rev-parse HEAD)"
  rm -rf "$case_dir/log" && mkdir -p "$case_dir/log"
  launch STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$other"
  echo "$?" >"$case_dir/status"
  status_is 0
  [ "$(stack_calls "$second")" = "$(started_stack)" ] || echo "the second start did not run the new commit's export: $(stack_calls "$second")"
  [ "$(ls -A "$case_dir/$machine/cyfr-run")" = "$second" ] || echo "the exports left: $(ls -A "$case_dir/$machine/cyfr-run" | tr '\n' ' ')"
  grep -qx '# a later commit' "$case_dir/$machine/cyfr-run/$second/Caddyfile" || echo "the export is not the new commit's"
  [ ! -e "$case_dir/$machine/cyfr-run/$second/uncommitted.txt" ] || echo "an uncommitted file reached the export"
  nothing_left
}
# link_commit NAME TARGET...: a copy of the fake checkout whose commit
# holds each NAME as a symbolic link to its TARGET, in place of its file,
# beside an untracked local-Caddyfile; sets $other and $commit.
link_commit() {
  other="$scratch/link-cyfr.run"
  rm -rf "$other" && cp -r "$fake_run" "$other"
  while [ "$#" -ge 2 ]; do
    rm -f "$other/$1" && ln -s "$2" "$other/$1" && git -C "$other" add "$1"
    shift 2
  done
  git -C "$other" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m links
  commit="$(git -C "$other" rev-parse HEAD)"
  printf '# untracked-only\n{$DOMAIN} {\n}\n' >"$other/local-Caddyfile"
}
# A commit holding a symbolic link whose real path leaves the export (an
# absolute one, a relative one that climbs out, one to a link that leaves)
# refuses, naming the link, before Docker starts, and leaves no export;
# so does a bind the commit's compose files name outside the export. A
# link that stays inside the export is the commit's own.
case_export_symlink() {
  local named want
  for named in "abs" "climb" "chain"; do
    case "$named" in
      abs) link_commit Caddyfile "$scratch/link-cyfr.run/local-Caddyfile" && want="Caddyfile -> $other/local-Caddyfile" ;;
      climb) link_commit Caddyfile ../local-Caddyfile && want="Caddyfile -> ../local-Caddyfile" ;;
      chain) link_commit inner "$scratch/link-cyfr.run/local-Caddyfile" Caddyfile inner && want="Caddyfile -> inner" ;;
    esac
    stack "$1" export-symlink "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$other"
    [ "$(cat "$case_dir/status")" != 0 ] || echo "$named: the loop accepted a commit whose link leaves the export"
    [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: $other's commit $commit holds a symbolic link that leaves it, $want; the local cyfr.run runs the commit's own files alone." ] ||
      echo "$named: the refusal does not name the link: $(tail -n 1 "$case_dir/err")"
    [ -z "$(ls -A "$case_dir/$machine/cyfr-run" 2>/dev/null)" ] || echo "$named: the refused export was left: $(ls -A "$case_dir/$machine/cyfr-run")"
    record docker.calls | grep -q " up " && echo "$named: Docker started with a link out of the export"
    nothing_left
  done
  # A bind the compose files name outside the export.
  link_commit
  sed -i "s|- ./Caddyfile:/etc/caddy/Caddyfile:ro|- $other/local-Caddyfile:/etc/caddy/Caddyfile:ro|" "$other/docker-compose.prod.yml"
  commit="$(commit_run "$other")"
  stack "$1" export-bind-outside "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$other"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: the local stack of $other's commit $commit is not the one the loop runs: its caddy service binds $other/local-Caddyfile, which is outside the export." ] ||
    echo "a bind outside the export: $(tail -n 1 "$case_dir/err")"
  record docker.calls | grep -q " up " && echo "Docker started with a bind outside the export"
  # A link inside the export is accepted, and its bind reads the commit's file.
  link_commit
  mkdir -p "$other/conf" && git -C "$other" mv Caddyfile conf/Caddyfile && ln -s conf/Caddyfile "$other/Caddyfile"
  commit="$(commit_run "$other")"
  stack "$1" export-link-inside "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$other"
  status_is 0
  [ "$(readlink -f "$case_dir/$machine/cyfr-run/$commit/Caddyfile")" = "$case_dir/$machine/cyfr-run/$commit/conf/Caddyfile" ] ||
    echo "the inside link does not resolve in the export: $(readlink -f "$case_dir/$machine/cyfr-run/$commit/Caddyfile")"
  nothing_left
}
# The loop removes only the exports it made, by their names: a directory
# that is not named for a commit, or is named for one but holds no
# marker, is left alone and named; an earlier export of the loop's goes.
# A directory at the running commit's name without the marker refuses.
case_export_cleanup() {
  local runs other_commit="$(printf 'ab%.0s' {1..20})" made="$(printf 'cd%.0s' {1..20})"
  prepare "$1" export-cleanup "$complete" 0600
  command=""
  runs="$case_dir/$machine/cyfr-run"
  mkdir -p "$runs/not-an-export" "$runs/$other_commit" "$runs/$made"
  printf 'keep\n' >"$runs/not-an-export/sentinel"
  printf 'keep\n' >"$runs/$other_commit/sentinel"
  : >"$runs/$made/.cyfr-dev-stack-export"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$case_dir/status"
  status_is 0
  [ -f "$runs/not-an-export/sentinel" ] || echo "the cleanup deleted a directory not named for a commit"
  [ -f "$runs/$other_commit/sentinel" ] || echo "the cleanup deleted a commit-named directory with no marker"
  [ ! -e "$runs/$made" ] || echo "the cleanup kept an earlier export of the loop's"
  [ -f "$runs/$fake_commit/.cyfr-dev-stack-export" ] || echo "the running export holds no marker"
  grep -qxF "dev-stack: left alone in $case_dir/$machine/cyfr-run, since the loop did not make them: $other_commit not-an-export." "$case_dir/out" ||
    echo "the run did not name what it left alone: $(grep 'left alone' "$case_dir/out")"
  nothing_left
  prepare "$1" export-unmarked "$complete" 0600
  mkdir -p "$case_dir/$machine/cyfr-run/$fake_commit" && printf 'keep\n' >"$case_dir/$machine/cyfr-run/$fake_commit/sentinel"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$case_dir/status"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop ran from a directory at its commit's name that it did not make"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: $case_dir/$machine/cyfr-run/$fake_commit is not an export the loop made (it holds no .cyfr-dev-stack-export); move it away, and the next start exports the commit there." ] ||
    echo "the refusal: $(tail -n 1 "$case_dir/err")"
  [ -f "$case_dir/$machine/cyfr-run/$fake_commit/sentinel" ] || echo "the refusal touched the directory"
}
# A name the hosts table maps to loopback and to another address refuses,
# naming the other address.
case_mixed_address() {
  stack "$1" mixed-address "$complete" 0600 "" STUB_SERVER_STATUS=0 ERL_INETRC="$mixed"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on with a name that also resolves to 203.0.113.9"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: cyfr.test resolves to 203.0.113.9, which is not 127.0.0.1, and both names must resolve to 127.0.0.1 alone on this machine, where the local cyfr.run answers. Map both once: echo '127.0.0.1 cyfr.test registry.cyfr.test' | sudo tee -a /etc/hosts" ] ||
    echo "the refusal: $(tail -n 1 "$case_dir/err")"
  calls | grep -q " up " && echo "the worktree's stack started with a name that resolves elsewhere: $(calls)"
  nothing_left
}
# A cyfr.run checkout that is not where the loop looks refuses, naming
# where it looked and how to name another, before anything is started.
case_cyfr_run_absent() {
  stack "$1" cyfr-run-absent "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$scratch/no-cyfr.run"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on with no cyfr.run checkout"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: the local cyfr.run is built from a cyfr.run checkout's committed HEAD, and $scratch/no-cyfr.run holds none (no commit with docker-compose.prod.yml and docker-compose.local.yml); clone https://github.com/cyfrworks/cyfr.run.git there, or name another checkout with DEV_STACK_CYFR_RUN=<path>." ] ||
    echo "the refusal does not say where it looked: $(tail -n 1 "$case_dir/err")"
  [ -z "$(record docker.calls)" ] || echo "docker ran with no cyfr.run checkout: $(record docker.calls)"
  [ -z "$(record server.env)" ] || echo "the server started with no cyfr.run checkout"
  # Another checkout, named by the setting, is the one built.
  rm -rf "$scratch/other-cyfr.run" && cp -r "$fake_run" "$scratch/other-cyfr.run"
  stack "$1" cyfr-run-named "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$scratch/other-cyfr.run"
  status_is 0
  [ "$(stack_calls)" = "$(started_stack)" ] || echo "the named checkout's commit was not the one started: $(record docker.calls | cut -d'|' -f1)"
  # A directory with files but no commit is no checkout.
  rm -rf "$scratch/uncommitted-cyfr.run" && mkdir -p "$scratch/uncommitted-cyfr.run" &&
    cp "$fake_run"/docker-compose.*.yml "$scratch/uncommitted-cyfr.run/"
  stack "$1" cyfr-run-uncommitted "$complete" 0600 "" STUB_SERVER_STATUS=0 DEV_STACK_CYFR_RUN="$scratch/uncommitted-cyfr.run"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on from a directory with no commit"
  [ -z "$(record docker.calls)" ] || echo "docker ran from a directory with no commit: $(record docker.calls)"
}
# The local cyfr.run's settings come from its env file alone: the
# caller's DOMAIN, ADMIN_TOKEN and port reach none of its compose calls,
# and neither does its checkout's .env. The env file and the authority's
# copy live in the machine's dev-stack directory, mode 0700, the file
# 0600, the token minted once and kept, and never printed.
case_stack_env() {
  local token_one token_two env_file
  stack "$1" stack-env "$complete" 0600 "" STUB_SERVER_STATUS=0 DOMAIN=cyfr.run ADMIN_TOKEN=from-the-caller CYFR_LOCAL_HTTPS_PORT=18443
  status_is 0
  [ -z "$(record stack.seen)" ] || echo "the local cyfr.run's compose saw the caller's $(record stack.seen | sort -u | tr '\n' ' ')"
  env_file="$case_dir/$machine/cyfr-run.env"
  [ "$(mode_of "$case_dir/$machine")" = 0o700 ] || echo "the machine's dev-stack directory is $(mode_of "$case_dir/$machine"), not 0o700"
  [ "$(mode_of "$env_file")" = 0o600 ] || echo "the local cyfr.run's env file is $(mode_of "$env_file"), not 0o600"
  token_one="$(sed -n 's/^ADMIN_TOKEN=//p' "$env_file")"
  [ "$(sed '/^ADMIN_TOKEN=/d' "$env_file")" = $'DOMAIN=cyfr.test\nCYFR_LOCAL_HTTPS_PORT=443' ] || echo "the env file holds $(sed 's/^ADMIN_TOKEN=.*/ADMIN_TOKEN=…/' "$env_file")"
  [[ "$token_one" =~ ^[0-9a-f]{64}$ ]] || echo "the minted ADMIN_TOKEN is not 64 lowercase hexadecimal digits"
  if grep -qF "$token_one" "$case_dir/out" "$case_dir/err"; then echo "the ADMIN_TOKEN reached the output"; fi
  cmp -s "$trusted_root" "$case_dir/$machine/cyfr-run-root.crt" || echo "the authority's copy is not the local cyfr.run's"
  # A second run, the case's machine directory kept, keeps the token.
  rm -rf "$case_dir/log" && mkdir -p "$case_dir/log"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$case_dir/status"
  status_is 0
  token_two="$(sed -n 's/^ADMIN_TOKEN=//p' "$env_file")"
  [ "$token_two" = "$token_one" ] || echo "a second run minted another ADMIN_TOKEN"
  # The first start built the server's image and recorded it; the second,
  # at the same commit with that image still there, builds nothing, so
  # compose recreates no container of the stack the other loops share.
  [ "$(cat "$case_dir/$machine/cyfr-run.image" 2>/dev/null)" = "$fake_commit sha256:stub-cyfrrun" ] ||
    echo "the built image was recorded as $(cat "$case_dir/$machine/cyfr-run.image" 2>&1)"
  [ "$(stack_calls)" = "$(started_stack kept)" ] || echo "a second start of the same commit built the server again: $(stack_calls)"
  # An image gone since (another id, or none) is built again.
  rm -rf "$case_dir/log" && mkdir -p "$case_dir/log"
  launch STUB_SERVER_STATUS=0 STUB_STACK_IMAGE=sha256:another
  echo "$?" >"$case_dir/status"
  status_is 0
  [ "$(stack_calls)" = "$(started_stack)" ] || echo "a start whose recorded image is gone did not build it: $(stack_calls)"
  nothing_left
}
# Names that do not resolve to 127.0.0.1 refuse with the hosts entry,
# before the worktree's containers start.
case_unresolved() {
  stack "$1" unresolved "$complete" 0600 "" STUB_SERVER_STATUS=0 ERL_INETRC="$unresolving"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on with names that do not resolve"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: cyfr.test does not resolve to 127.0.0.1, and both names must resolve to 127.0.0.1 alone on this machine, where the local cyfr.run answers. Map both once: echo '127.0.0.1 cyfr.test registry.cyfr.test' | sudo tee -a /etc/hosts" ] ||
    echo "the refusal does not name the hosts entry: $(tail -n 1 "$case_dir/err")"
  calls | grep -q " up " && echo "the worktree's stack started with names that do not resolve: $(calls)"
  [ -z "$(record server.env)" ] || echo "the server started with names that do not resolve"
  nothing_left
}
# An authority the operating system does not trust refuses, naming the
# command that trusts it.
case_untrusted() {
  stack "$1" untrusted "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_ROOT="$untrusted_root"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on with an authority the machine does not trust"
  case "$(tail -n 1 "$case_dir/err")" in
    "dev-stack: The local cyfr.run's certificate authority ($case_dir/$machine/cyfr-run-root.crt) is not in this machine's trust store, which the server's TLS reads. Trust it once: sudo "*"$case_dir/$machine/cyfr-run-root.crt"*) ;;
    *) echo "the refusal does not name the trust command: $(tail -n 1 "$case_dir/err")" ;;
  esac
  calls | grep -q " up " && echo "the worktree's stack started with an untrusted authority: $(calls)"
  nothing_left
}
# A start of the local cyfr.run that cannot publish 127.0.0.1:443 refuses
# with what to run, or to stop, on the machine.
case_port_443() {
  stack "$1" port-443-rootless "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_STACK_UP_STATUS=1 \
    STUB_STACK_UP_OUTPUT="Error response from daemon: driver failed programming external connectivity on endpoint cyfr-run-dev-caddy-1: error while calling RootlessKit PortManager.AddPort(): cannot expose privileged port 443, you can add 'net.ipv4.ip_unprivileged_port_start=443' to /etc/sysctl.conf"
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the loop went on though 443 could not be published"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: Docker cannot publish the local cyfr.run on 127.0.0.1:443 without privileges here (rootless Docker). Allow it once on this machine: echo net.ipv4.ip_unprivileged_port_start=443 | sudo tee /etc/sysctl.d/90-cyfr-dev.conf && sudo sysctl --system" ] ||
    echo "the rootless refusal: $(tail -n 1 "$case_dir/err")"
  grep -qF "cannot expose privileged port 443" "$case_dir/err" || echo "docker's own error did not reach the output"
  [ -z "$(calls)" ] || echo "the worktree's stack ran past the failed start: $(calls)"
  stack "$1" port-443-held "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_STACK_UP_STATUS=1 \
    STUB_STACK_UP_OUTPUT="Error response from daemon: failed to set up container networking: Bind for 127.0.0.1:443 failed: port is already allocated"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: Something else holds 127.0.0.1:443, where the local cyfr.run answers; stop it, then start again. \`ss -ltnp 'sport = :443'\` (\`lsof -nP -iTCP:443 -sTCP:LISTEN\` on macOS) names it." ] ||
    echo "the held refusal: $(tail -n 1 "$case_dir/err")"
  stack "$1" port-443-other "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_STACK_UP_STATUS=1 STUB_STACK_UP_OUTPUT="failed to solve: the build broke"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: the local cyfr.run did not start; docker's output ends above." ] ||
    echo "the other refusal: $(tail -n 1 "$case_dir/err")"
  nothing_left
}

# boundary SCRIPT [CASE...]: the failures of SCRIPT under each case.
boundary() {
  local script="$1" c
  shift
  for c in ${@:-$BOUNDARY_CASES}; do "$c" "$script" | sed "s/^/$c: /"; done
}

script="${DEV_STACK_SCRIPT:-$ROOT/scripts/dev-stack.sh}"
for c in ${DEV_STACK_CASES:-$BOUNDARY_CASES}; do
  out="$(boundary "$script" "$c")"
  if [ -z "$out" ]; then pass "scripts/dev-stack.sh: ${c#case_}"; else failed "scripts/dev-stack.sh: ${c#case_}" "$out"; fi
done
if [ -n "${DEV_STACK_CASES:-}" ]; then
  echo "$((cases - failures))/$cases passed"
  [ "$failures" -eq 0 ]
  exit
fi

# respell NAME WHAT CASES SED_EXPRESSION: an equivalent spelling, which
# CASES, the ones that run the respelled lines, hold to.
respell() {
  sed -E "$4" "$script" >"$scratch/r-$1.sh"
  if cmp -s "$script" "$scratch/r-$1.sh"; then failed "$2 (the edit changed nothing)"; return; fi
  out="$(boundary "$scratch/r-$1.sh" "$3")"
  if [ -z "$out" ]; then pass "$2 holds"; else failed "$2 fails" "$out"; fi
}
respell spelled "the signals spelled by name" "case_interrupted case_server_child case_down_orphan" 's/kill -TERM "\$1"/kill -s TERM "$1"/; s/^trap .exit 130. INT$/trap "exit 130" SIGINT/'
# break NAME WHAT CASES SED_EXPRESSION: the script broken, which CASES catch.
break_script() {
  sed -E "$4" "$script" >"$scratch/b-$1.sh"
  if cmp -s "$script" "$scratch/b-$1.sh"; then failed "$2 (the edit changed nothing)"; return; fi
  out="$(boundary "$scratch/b-$1.sh" "$3")"
  if [ -n "$out" ]; then
    pass "$2 fails"
    [ -z "${SHOW:-}" ] || printf '%s\n' "$out" | sed 's/^/    /'
  else
    failed "$2 passed"
  fi
}
break_script nodown "the containers left on the way out" "case_start_fails case_server_ends case_interrupted" '/^    compose down --remove-orphans >\/dev\/null 2>&1 \|\|$/,/^      echo "dev-stack: the containers could not be removed/d'
break_script noexit "no cleanup on the way out" "case_start_fails case_server_ends case_interrupted" '/^trap finish EXIT$/d'
break_script noterm "the server left running" case_interrupted 's/^  kill -TERM "\$1" 2>\/dev\/null \|\| true$/  true/'
break_script nogroup "the server's process group left behind" "case_interrupted case_server_child" '/kill -KILL -- "-\$1"/d'
break_script noports "a slot taken whatever holds its ports" case_port_held 's/^    if who="\$\(held "\$\{listener%:\*\}" "\$\{listener##\*:\}"\)"; then$/    if false; then/'
break_script nonets "a slot taken whatever network overlaps it" case_network_overlap 's/^  who="\$\(overlaps "\$2" "\$k"\)"$/  who=""/'
break_script noclaim "a slot taken whatever loop claims it" "case_remembered case_two_checkouts" 's/^  if ! flock -n "\$fd"; then$/  if false; then/'
break_script forgetful "the slot taken never remembered" case_remembered '/^      mkdir -p "\$\(dirname "\$REMEMBERED"\)" && printf/d'
break_script oneproject "one project for every worktree" case_two_checkouts 's/^PROJECT="cyfr-dev-\$\(run_names_seed "\$ROOT"\)" \|\|$/PROJECT="cyfr-dev" ||/'
break_script noleftovers "a killed run's containers left before the slot is chosen" case_provision '/^  compose down --remove-orphans >\/dev\/null 2>&1 \|\| true$/d'
break_script buildfirst "the image built before the settings are agreed" case_refused 's/^  image --tag-only$/  image --for "$$"/'
break_script keysout "the keys in the server's environment" case_provision 's/^  \(exec \{LOCK_FD\}>&- \{CLAIM_FD\}>&- && export "\$\{server\[@\]\}" &&$/  (exec {LOCK_FD}>\&- {CLAIM_FD}>\&- \&\& export "${server[@]}" "${keys[@]}" \&\&/'
break_script persisted "the server's settings written into .env" case_provision 's/^  STARTED=1$/  printf "%s\\n" "${server[@]}" >>.env\n&/'
break_script nolink "the setup link not printed" case_provision '/^  \[ -z "\$setup" \] \|\| echo /d'
break_script nocompose "the caller's COMPOSE_* left to compose" case_project_env '/^  case "\$name" in COMPOSE_\*\) unset "\$name" ;; esac$/d'
break_script forget "the server's group forgotten once it ends" case_server_child 's/^  wait "\$SERVER" && status=0 \|\| status=\$\?$/&\n  SERVER=""/'
break_script endedgroup "an ended server's group left behind" case_server_child '/^    kill -KILL -- "-\$SERVER" 2>\/dev\/null \|\| true$/d'
break_script nolock "a run that takes no lock" case_locked '/^  lock$/d'
break_script noorphan "down leaving a killed run's server" case_down_orphan '/^    stop "\$left"$/d'
break_script anygroup "a recorded group stopped whatever process holds it now" case_down_orphan 's/^  \[ "\$\(started "\$pgid"\)" = "\$started" \] && echo "\$pgid"$/  echo "$pgid"/'
break_script argv "the bearer on curl's command line" case_check 's|-H @"\$PRIVATE/authorization"|-H "authorization: Bearer $CYFR_TOKEN"|'
break_script discard "no delete after a failed read" "case_failed_read case_failed_parse" '/^    discard "\$path"$/d'
break_script keep "the private directory kept" "case_check case_provision" 's/^  \[ -z "\$PRIVATE" \] \|\| rm -rf "\$PRIVATE"$/  true/'
break_script stackdown "the local cyfr.run stopped on the way out" "case_provision case_server_ends" 's/^  if \[ -n "\$STARTED" \]; then$/  [ -z "$STACK_NAMES" ] || stack_compose down >\/dev\/null 2>\&1 || true\n&/'
break_script stackcaller "the caller's environment left to the local cyfr.run's compose" case_stack_env 's/^  for name in \$STACK_NAMES; do unset\+=\(-u "\$name"\); done$/  :/'
break_script stackfile "the local cyfr.run's env file not handed to its compose" case_provision 's/--env-file "\$env_file" -p "\$STACK"/--env-file \/dev\/null -p "$STACK"/'
break_script noexport "the local cyfr.run run from the checkout itself" "case_provision case_new_commit" 's|^  STACK_DIR="\$MACHINE/cyfr-run/\$1"$|  STACK_DIR="$CYFR_RUN"|'
break_script nobind "a bind source the commit lacks left to Docker" case_missing_bind 's/^        if not os\.path\.exists\(source\):$/        if False:/'
break_script oldexports "the exports of earlier commits kept" case_new_commit '/^  drop_exports "\$commit"$/d'
break_script anyexport "everything beside the running export removed" case_export_cleanup 's/^    if \[\[ "\$name" =~ \^\(\[0-9a-f\]\{40\}\|\[0-9a-f\]\{64\}\)\$ \]\] && \[ -d "\$MACHINE\/cyfr-run\/\$name" \] &&$/    if true \&\& [ -d "$MACHINE\/cyfr-run\/$name" ] \&\&/; s/^      \[ ! -L "\$MACHINE\/cyfr-run\/\$name" \] && \[ -f "\$MACHINE\/cyfr-run\/\$name\/\$EXPORTED" \]; then$/      true; then/; s|^      rm -rf "\$\{MACHINE:\?\}/cyfr-run/\$\{BASH_REMATCH\[1\]\}"$|      rm -rf "$MACHINE/cyfr-run/$name"|'
break_script outlinks "a link out of the export kept" case_export_symlink 's/^            if real != root and not real.startswith\(root \+ os.sep\):$/            if False:/'
break_script outbinds "a bind outside the export left to Docker" case_export_symlink 's/^        if real != inside and not real.startswith\(inside \+ os.sep\):$/        if False:/'
break_script createdat "a database bound by its volume's making" "case_volume_replaced case_same_stack" 's/^  \[\[ "\$STACK_ID" =~ \^\[0-9a-f\]\{32\}\$ \]\] \|\| die .*$/  STACK_ID="$(docker volume inspect --format "{{.CreatedAt}}" cyfr-run-dev_postgres-data)"/'
break_script alwaysbuild "the server's image built on every start" case_stack_env 's/^  \[ "\$\(cat "\$STACK_IMAGE" 2>\/dev\/null\)" = "\$commit \$\(docker image inspect --format .\{\{\.Id\}\}. "\$image" 2>\/dev\/null\)" \] \|\|$/  false ||/'
break_script remint "the ADMIN_TOKEN minted afresh on every start" case_stack_env 's/^  \[ ! -f "\$STACK_ENV" \] \|\| token=.*$/  :/'
break_script nocheckout "no refusal of an absent cyfr.run checkout" case_cyfr_run_absent 's/^    die "the local cyfr.run is built from a cyfr.run checkout.s committed HEAD.*$/    true/'
break_script unbound "a database taken whatever local cyfr.run it was made at" "case_stack_reset case_volume_replaced" 's/^      \[ "\$recorded" = "\$STACK_ID" \] \|\|$/      true ||/'
break_script unrecorded "a new database's local cyfr.run not recorded" case_new_database 's/^      mkdir -p "\$\(dirname "\$BOUND"\)" && printf .*$/      :/'

# ships_neither TARBALL: the scaffold holds the shipped compose file and
# neither the override nor the script that starts it.
ships_neither() {
  local listing
  listing="$(tar -tzf "$1")" || return 1
  grep -qxF docker-compose.yml <<<"$listing" || { echo "no docker-compose.yml in the scaffold"; return 1; }
  if grep -E '(^|/)(docker-compose\.dev\.yml|dev-stack\.sh)$' <<<"$listing"; then return 1; fi
  return 0
}
if out="$(bash "$ROOT/scripts/scaffold-tarball.sh" "$scratch/scaffold.tar.gz" 2>&1)" && out="$(ships_neither "$scratch/scaffold.tar.gz" 2>&1)"; then
  pass "the scaffold ships docker-compose.yml and neither docker-compose.dev.yml nor scripts/dev-stack.sh"
else
  failed "the scaffold" "$out"
fi
mkdir -p "$scratch/planted/scripts"
(cd "$scratch/planted" && touch docker-compose.yml docker-compose.dev.yml scripts/dev-stack.sh &&
  tar czf ../planted-override.tar.gz docker-compose.yml docker-compose.dev.yml &&
  tar czf ../planted-script.tar.gz docker-compose.yml scripts/dev-stack.sh)
for planted in override script; do
  if ships_neither "$scratch/planted-$planted.tar.gz" >/dev/null 2>&1; then
    failed "a scaffold shipping the $planted passed"
  else
    pass "a scaffold shipping the $planted fails"
  fi
done

echo "$((cases - failures))/$cases passed"
[ "$failures" -eq 0 ]
