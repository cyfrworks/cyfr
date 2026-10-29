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
# containers. Its check secures its bearer and cleans up after a failed
# read. The scaffold ships neither file. Each mutation fails; an
# equivalent respelling holds.
#
# Needs docker's compose plugin (no daemon), git, python3, ss and a build
# of the checkout (_build/$MIX_ENV, or DEV_STACK_BUILD). The boundary cases
# take the slots whose ports this host leaves free. SHOW=1 prints why each
# mutation fails; DEV_STACK_SCRIPT runs the boundary cases against another
# script, and DEV_STACK_CASES (case_* names) runs those boundary cases alone
# after the static checks, with no mutation of the script. Usage: bash
# tests/dev-stack/compose-test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# The boundary cases, defined below; DEV_STACK_CASES names some of them.
BOUNDARY_CASES="case_provision case_retained case_refused case_release_root case_port_held case_network_overlap case_remembered case_all_taken case_start_fails case_image_fails case_image_build_fails case_claim_named case_claim_unverified case_server_ends case_interrupted case_check case_failed_read case_failed_parse case_project_env case_server_child case_blank_root case_locked case_two_checkouts case_down_orphan"
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
example_id="$(sed -n 's/^CYFR_GITHUB_CLIENT_ID=//p' "$ROOT/.env.example")"
# value K NAME: slot K's NAME.
value() { slot_env "$1" | sed -n "s/^$2=//p"; }
# host_free K: nothing on this host listens on slot K's ports.
host_free() {
  python3 -I -c '
import socket, sys
for port in sys.argv[1:]:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", int(port)))
    except OSError:
        sys.exit(1)
    s.close()' "$(value "$1" DEV_STACK_PRISM_PORT)" "$(value "$1" DEV_STACK_PROXY_PORT)" \
    "$(value "$1" DEV_STACK_RUNTIME_PORT)" "$(value "$1" DEV_STACK_HOST_API_PORT)"
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
printf '%s|LOCUS_RUNTIME_KEY=%s|CYFR_LOCUS_BACKENDS_KEY=%s|CYFR_LOCUS_BUILDS_KEY=%s|slot=%s\n' "$*" \
  "${LOCUS_RUNTIME_KEY-unset}" "${CYFR_LOCUS_BACKENDS_KEY-unset}" "${CYFR_LOCUS_BUILDS_KEY-unset}" \
  "${DEV_STACK_SLOT-unset}" >>"$STUB_LOG/docker.calls"
env | sed -n 's/^\(COMPOSE_[A-Z_]*\)=.*/\1/p' | sort | tr '\n' ' ' >>"$STUB_LOG/docker.env"
echo >>"$STUB_LOG/docker.env"
case " $* " in
  *" config "*) exec "$REAL_DOCKER" "$@" ;;
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

run_dir=""
token="dev-stack-test-token-$(openssl rand -hex 6)"
root_a="$(printf 'ab%.0s' {1..32})"
setup_a="$(printf '5e%.0s' {1..32})"
key_b="$(printf 'b1%.0s' {1..32})"
key_c="$(printf 'c2%.0s' {1..32})"
complete="CYFR_GITHUB_CLIENT_ID=$example_id
CYFR_SETUP_TOKEN=$setup_a
CYFR_LOCUS_RUNTIME_ROOT=$root_a
CYFR_LOCUS_BACKENDS_KEY=$key_b
CYFR_LOCUS_BUILDS_KEY=$key_c
"
services="locus-runtime locus-backends locus-builds"
unset_keys="LOCUS_RUNTIME_KEY=unset|CYFR_LOCUS_BACKENDS_KEY=unset|CYFR_LOCUS_BUILDS_KEY=unset"

# prepare SCRIPT NAME ENV_TEXT MODE [SLOT]: a git repository of its own
# holding SCRIPT and the run-names library, the shipped and the real
# override compose files, .env.example, .env as ENV_TEXT at MODE (none for
# no file), and SLOT remembered when given. Sets $case_dir and
# $case_project.
prepare() {
  case_dir="$scratch/case-$2"
  rm -rf "$case_dir" && mkdir -p "$case_dir/scripts/lib" "$case_dir/tmp" "$case_dir/log" "$case_dir/run"
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

# The script's environment: PATH, HOME, the stubs' settings and the
# given variables alone, every signal at its default as a shell starts a
# command.
launch() {
  (cd "$case_dir" && exec env -i PATH="$stubs:$PATH" HOME="$HOME" LC_ALL=C.UTF-8 TMPDIR="$case_dir/tmp" \
    XDG_RUNTIME_DIR="${run_dir:-$case_dir/run}" DEV_STACK_GRACE=1 STUB_IMAGE="$stub_image" \
    STUB_LOG="$case_dir/log" STUB_EBINS="$ebins" STUB_TOKEN="$token" REAL_DOCKER="$REAL_DOCKER" "$@" \
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
# The stack's docker calls, each compose call as `compose ARGS`, which the
# script makes with the case's project and its own files alone.
calls() {
  local acting="compose --env-file /dev/null -p $case_project --profile locus-builds -f docker-compose.yml -f docker-compose.dev.yml "
  record docker.calls | while IFS= read -r line; do printf '%s\n' "${line/#"$acting"/compose }"; done
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
# the case's project resolves it.
want_settings() {
  resolve "$case_dir" "$1" "$case_project" docker-compose.yml docker-compose.dev.yml >"$case_dir/want.json" &&
    python3 -I "$SHAPE" settings "$case_dir/want.json" | sort
}
server_settings() { record server.env | grep -E '^(CYFR|LOCUS)_' | sort; }
# Nothing of the run is left: no server, no watcher, no private directory.
nothing_left() {
  local pid
  for pid in $(record server.pid) $(record watcher.pid); do
    if kill -0 "$pid" 2>/dev/null; then echo "process $pid of the server is left running"; kill -KILL "$pid"; fi
  done
  [ -z "$(ls -A "$case_dir/tmp")" ] || echo "the run left $(ls -A "$case_dir/tmp") behind"
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
  [ "$(cat "$case_dir/.env")" = "CYFR_GITHUB_CLIENT_ID=$example_id
CYFR_SETUP_TOKEN=$setup
CYFR_LOCUS_RUNTIME_ROOT=$root
CYFR_LOCUS_BACKENDS_KEY=$backends" ] || echo ".env holds $(printf '%q' "$(cat "$case_dir/.env")")"
  for key in "$setup" "$root" "$backends" "$builds"; do
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || echo "a minted key is $(printf '%q' "$key"), not 64 lowercase hexadecimal digits"
  done
  [ "$(printf '%s\n' "$setup" "$root" "$backends" "$builds" | sort -u | wc -l)" = 4 ] || echo "the minted keys are not four"
  # The one secret printed: the setup link, as `cyfr init` prints it.
  grep -qxF "dev-stack: set up its first person, who administers it, at http://localhost:$port/setup#$setup" "$case_dir/out" ||
    echo "the run did not print the setup link: $(cat "$case_dir/out")"
  grep -qxF "dev-stack: .env is mode 0600 and now sets CYFR_GITHUB_CLIENT_ID, CYFR_SETUP_TOKEN, CYFR_LOCUS_RUNTIME_ROOT, CYFR_LOCUS_BACKENDS_KEY." "$case_dir/out" ||
    echo "the run did not say what it wrote: $(cat "$case_dir/out")"
  [ "$(calls)" = "$(full_run "$slot_a" "$root" "$backends" "$builds")" ] || echo "docker was handed: $(calls)"
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
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(120)' "$1" &
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
  stack "$1" network-overlap "$complete" 0600 "" STUB_SERVER_STATUS=0 STUB_NETWORKS="someones_net $net.64/26"
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
  flock "$file" sleep 120 &
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
  sleep 120 &
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
    flock "$lock" sleep 60 &
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
    [ -z "$(calls)" ] || echo "${command:-the loop} ran docker while another run held the worktree's stack: $(calls)"
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
  prepare "$1" two-second "$complete" 0600
  second="$case_dir"
  [ "$case_project" != "$first_project" ] || echo "the two worktrees have one project, $case_project"
  launch STUB_SERVER_STATUS=0
  echo "$?" >"$second/status"
  status_is 0
  grep -qxF "dev-stack: slot $slot_a is taken (the loop of $first (pid $(claim_of "$slot_a" | sed -n 's/^pid //p'))), so this worktree's loop takes slot $slot_b." "$second/out" ||
    echo "the second worktree's loop did not name the first's: $(cat "$second/out")"
  [ "$(calls)" = "$(full_run "$slot_b" "$root_a" "$key_b" "$key_c")" ] || echo "the second worktree's loop handed docker: $(calls)"
  command=down
  launch
  echo "$?" >"$second/status"
  status_is 0
  [ "$(calls | tail -n 1)" = "$(removed "$slot_b")" ] || echo "the second worktree's down handed docker: $(calls | tail -n 1)"
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
  [ -z "$(calls)" ] || echo "a start beside a killed run's server ran docker: $(calls)"
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
break_script noports "a slot taken whatever holds its ports" case_port_held 's/^    if who="\$\(held "\$port"\)"; then$/    if false; then/'
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
