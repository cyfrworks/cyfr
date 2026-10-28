#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The source development stack: docker-compose.dev.yml as `docker compose
# config` resolves it over docker-compose.yml (tests/dev-stack/compose_shape.py),
# and scripts/dev-stack.sh at its command boundary.
#
# The override: the runtime, backends and builds services and their
# guards are the shipped ones field by field, but for the image built from
# the tree under a local tag, the runtime's listener on the host's
# loopback alone and its calls to its network's gateway, each guard's
# fixed address and the control plane it refuses at its network's
# gateway, and the keeper's profile at its tracked path. Its host ports,
# subnets and names are apart from what the checks on a host reserve,
# read from their sources; a source that moves a reservation onto the
# stack fails as a dev declaration that moves onto one does.
#
# The script, with docker, mix, git and curl stubbed (the stubbed docker
# resolves with the real compose, the stubbed mix runs the real task from
# this checkout's build): provisions .env on its first run and keeps it
# after, hands compose the services' keys and the server CYFR's settings
# in their environments alone, refuses what disagrees and an occupied
# Prism address naming its holder, and on every exit (the server's own,
# a failed start, Ctrl-C, SIGTERM) stops the server's whole process group
# and removes the containers. Its check secures its bearer and cleans up
# after a failed read. The scaffold ships neither file. Each mutation
# fails; an equivalent respelling holds.
#
# Needs docker's compose plugin (no daemon), python3, ss and a build of the
# checkout (_build/$MIX_ENV, or DEV_STACK_BUILD). SHOW=1 prints why each
# mutation fails; DEV_STACK_SCRIPT runs the boundary cases against another
# script. Usage: bash tests/dev-stack/compose-test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-dev-stack-compose.XXXXXX")" || exit 1
holders=()
trap 'for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$scratch"' EXIT
SHAPE="$ROOT/tests/dev-stack/compose_shape.py"
REAL_DOCKER="$(command -v docker)"

failures=0
cases=0
pass() { cases=$((cases + 1)); echo "PASS: $1"; }
failed() {
  cases=$((cases + 1)) failures=$((failures + 1))
  echo "FAIL: $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/  /'
}

# project DIR OVERRIDE: a project directory holding the shipped compose
# file, OVERRIDE as docker-compose.dev.yml and an empty .env.
project() {
  rm -rf "$1" && mkdir -p "$1"
  cp "$ROOT/docker-compose.yml" "$1/"
  cp "$2" "$1/docker-compose.dev.yml"
  : >"$1/.env"
}

# resolve DIR FILE... : the stack's services from those files, as the
# script resolves them, in an environment holding nothing of the caller's.
resolve() {
  local dir="$1" files=()
  shift
  for f in "$@"; do files+=(-f "$f"); done
  (cd "$dir" && env -i PATH="$PATH" HOME="$HOME" "$REAL_DOCKER" compose --env-file /dev/null \
    --profile locus-builds "${files[@]}" config --format json locus-runtime locus-backends locus-builds)
}

# sources DIR: the files the checks reserve ports and names in, copied, so
# a case may move a reservation.
sources() {
  rm -rf "$1" && mkdir -p "$1/config"
  cp "$ROOT/config/test.exs" "$1/config/"
  cp -r "$ROOT/tests" "$ROOT/scripts" "$ROOT/.github" "$1/"
}

# checks DIR [SOURCES]: the override in DIR held to the shipped file and
# kept apart from the reservations in SOURCES (the checkout's by default).
checks() {
  local dir="$1" sources="${2:-$ROOT}"
  resolve "$dir" docker-compose.yml >"$dir/base.json" 2>"$dir/err" || { cat "$dir/err"; return 1; }
  resolve "$dir" docker-compose.yml docker-compose.dev.yml >"$dir/dev.json" 2>"$dir/err" || { cat "$dir/err"; return 1; }
  (cd "$dir" && env -i PATH="$PATH" HOME="$HOME" "$REAL_DOCKER" compose --env-file /dev/null --profile '*' \
    -f docker-compose.yml config --format json) >"$dir/shipped.json" 2>"$dir/err" || { cat "$dir/err"; return 1; }
  local out status=0
  out="$(python3 -I "$SHAPE" shape "$dir/base.json" "$dir/dev.json" "$ROOT")" || status=1
  out="$out$(python3 -I "$SHAPE" apart "$dir/dev.json" "$dir/shipped.json" "$sources")" || status=1
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
expect_checks pass "the override is the shipped stack's shape, apart from every check's reservations" "$scratch/real"

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
mutate wildcard "the runtime published on every interface" 's/"127\.0\.0\.1:([0-9]+):4200"/"0.0.0.0:\1:4200"/'
mutate nohost "the runtime published with no host address" 's/"127\.0\.0\.1:([0-9]+):4200"/"\1:4200"/'
mutate testport "the runtime on the test suite's first worker probe" 's/"127\.0\.0\.1:[0-9]+:4200"/"127.0.0.1:4200:4200"/'
mutate releaseport "the host API on the release boot's port" 's|(LOCUS_RUNTIME_HOST_API_URL=http://[0-9.]+:)[0-9]+|\14399|'
mutate hstsport "Prism on the HSTS proof's port" 's/^x-prism: 127\.0\.0\.1:[0-9]+$/x-prism: 127.0.0.1:4123/'
mutate prismwild "Prism on every interface" 's/^x-prism: 127\.0\.0\.1:/x-prism: 0.0.0.0:/'
mutate sameport "the host API on the runtime's port" 's|(LOCUS_RUNTIME_HOST_API_URL=http://[0-9.]+:)[0-9]+|\14700|'
mutate published "a published image tag" '0,/image: cyfr-locus:dev/s||image: ghcr.io/cyfrworks/cyfr-locus:latest|'
mutate guardimage "a guard on the published image" '/^  locus-builds-guard:$/,/container_name:/s|image: cyfr-locus:dev|image: ghcr.io/cyfrworks/cyfr-locus:latest|'
mutate pulled "an image compose may pull" '0,/pull_policy: build/{/pull_policy: build/d}'
mutate callback "the runtime's callbacks to the shipped cyfr service" 's|LOCUS_RUNTIME_HOST_API_URL=http://[0-9.]+:|LOCUS_RUNTIME_HOST_API_URL=http://cyfr:|'
mutate loopback "the runtime's callbacks to its own loopback" 's|LOCUS_RUNTIME_HOST_API_URL=http://[0-9.]+:|LOCUS_RUNTIME_HOST_API_URL=http://127.0.0.1:|'
mutate gateway "another gateway than the callbacks name" 's/gateway: 172\.16\.240\.1$/gateway: 172.16.240.126/'
mutate serviceid "the shipped service id, which CYFR does not dispatch to" 's/LOCUS_RUNTIME_SERVICE_ID=wrk_local/LOCUS_RUNTIME_SERVICE_ID=wrk_locus/'
mutate joined "the security options joined to the shipped ones" 's/security_opt: !override/security_opt:/'
mutate seccomp "the keeper's profile dropped" '/seccomp=\.\/apps/d'
mutate noprofile "a profile the checkout does not hold" 's|seccomp=\./apps/locus/keeper/seccomp/keeper\.json|seccomp=./keeper.seccomp.json|'
mutate nnp "no-new-privileges dropped" '/- no-new-privileges:true/d'
mutate capability "a capability added to the backends service" 's/^(    container_name: cyfr-dev-locus-backends)$/\1\n    cap_add: [NET_ADMIN]/'
mutate writable "a writable root for the builder" 's/^(    container_name: cyfr-dev-locus-builds)$/\1\n    read_only: false/'
mutate hostnet "the backends service on the host's network" 's/^(    container_name: cyfr-dev-locus-backends)$/\1\n    network_mode: host/'
mutate guardless "the builder outside its guard's namespace" 's/^(    container_name: cyfr-dev-locus-builds)$/\1\n    network_mode: bridge/'
mutate shippedplane "a guard refusing the shipped control plane, not the host" 's/CYFR_GUARD_CONTROL_PLANE=172\.16\.241\.1/CYFR_GUARD_CONTROL_PLANE=172.16.230.2/'
mutate noplane "a guard's control plane left as shipped" '/CYFR_GUARD_CONTROL_PLANE=172\.16\.242\.1/d'
mutate inrange "a guard's address inside its network's ip_range" 's/ipv4_address: 172\.16\.241\.2/ipv4_address: 172.16.241.200/'
mutate shippedsubnet "a dev network on the shipped runtime subnet" 's/172\.16\.241\./172.16.231./g'
mutate pool "a dev network in Docker's address pools" 's/172\.16\.242\./172.18.242./g'
mutate twice "two dev networks on one subnet" 's/172\.16\.242\./172.16.241./g'
mutate unnamed "the checkout directory's project name" '/^name: cyfr-dev$/d'
mutate container "the shipped container name" 's/container_name: cyfr-dev-locus-runtime/container_name: cyfr-locus-runtime/'

# move NAME WHAT FILE SED_EXPRESSION: a check's own reservation moved onto
# the stack, which must fail.
move() {
  local dir="$scratch/s-$1"
  project "$dir" "$override"
  sources "$dir.sources"
  sed -E -i "$4" "$dir.sources/$3"
  if cmp -s "$ROOT/$3" "$dir.sources/$3"; then
    failed "$2 (the edit changed nothing)"
    return
  fi
  expect_checks fail "$2" "$dir" "$dir.sources"
}
move suite "the test suite's endpoint moved onto the runtime's port" config/test.exs 's/port: 4002\]/port: 4700]/'
move boot "the release boot's host API moved onto the host API's port" tests/release-boot/release.sh 's/RELEASE_BOOT_HOST_API_PORT:-4398/RELEASE_BOOT_HOST_API_PORT:-4701/'
move browser "the browser harness moved onto Prism's address" tests/browser/harness.sh 's/BROWSER_HOMES_PORT:-4410/BROWSER_HOMES_PORT:-4000/'
move named "a proof naming the stack's container" tests/compose-proof/run.sh '1a # docker logs cyfr-dev-locus-builds'
move unread "a reservation the check can no longer read" tests/proxy-hsts/run.sh 's/TLS_PORT=4123/TLS_LISTENER=4123/'
dir="$scratch/s-shipped"
project "$dir" "$override"
sed -i 's|- subnet: 172\.16\.234\.0/24|- subnet: 172.16.241.0/24|' "$dir/docker-compose.yml"
expect_checks fail "the shipped edge network moved onto a dev subnet" "$dir"

# scripts/dev-stack.sh at its command boundary: docker, mix, git and curl
# stubbed on PATH, each recording what it is handed. What the script must
# hand on comes from the resolved override, with Prism's, the runtime's and
# the host API's ports moved to ones free here, so a dev stack running on
# this host does not hold them: the server's settings
# (compose_shape.py settings), and the key the documented derivation
# gives for the runtime's id (.env.example: the root's HMAC of
# `cyfr-locus/v1/runtime\n<id>`).
free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
read -r prism_port runtime_port host_api_port < <(echo "$(free_port) $(free_port) $(free_port)")
variant="$scratch/variant.yml"
python3 -I - "$override" "$variant" "$prism_port" "$runtime_port" "$host_api_port" <<'PY'
import re, sys
src, dst, prism, runtime, host_api = sys.argv[1:]
text = open(src).read()
for pattern, value in [
    (r"(?m)^(x-prism: 127\.0\.0\.1:)\d+$", r"\g<1>" + prism),
    (r'"127\.0\.0\.1:\d+:4200"', '"127.0.0.1:%s:4200"' % runtime),
    (r"(LOCUS_RUNTIME_HOST_API_URL=http://[\d.]+:)\d+", r"\g<1>" + host_api),
]:
    text, n = re.subn(pattern, value, text)
    if n != 1:
        sys.exit("the override's port declaration %s is not where the test moves it" % pattern)
open(dst, "w").write(text)
PY
[ -s "$variant" ] || { failed "the override's ports could not be moved for the boundary cases"; exit 1; }
project "$scratch/variant" "$variant"
resolve "$scratch/variant" docker-compose.yml docker-compose.dev.yml >"$scratch/variant/dev.json"
want_settings="$(python3 -I "$SHAPE" settings "$scratch/variant/dev.json" | sort)"
want_id="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["services"]["locus-runtime"]["environment"]["LOCUS_RUNTIME_SERVICE_ID"])' "$scratch/variant/dev.json")"
derived() { printf 'cyfr-locus/v1/runtime\n%s' "$want_id" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" 2>/dev/null | sed 's/^.*= //'; }
example_id="$(sed -n 's/^CYFR_GITHUB_CLIENT_ID=//p' "$ROOT/.env.example")"

build="${DEV_STACK_BUILD:-$ROOT/${MIX_BUILD_PATH:-_build/${MIX_ENV:-dev}}}"
ebins=""
for dir in "$build"/lib/*/ebin; do ebins="$ebins -pa $dir"; done
[ -f "$build/lib/cyfr/ebin/Elixir.Mix.Tasks.Cyfr.Locus.DevStack.beam" ] ||
  failed "no build of mix cyfr.locus.dev_stack under $build: compile the checkout first"

stubs="$scratch/bin"
mkdir -p "$stubs"
cat >"$stubs/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s|LOCUS_RUNTIME_KEY=%s|CYFR_LOCUS_BACKENDS_KEY=%s|CYFR_LOCUS_BUILDS_KEY=%s\n' "$*" \
  "${LOCUS_RUNTIME_KEY-unset}" "${CYFR_LOCUS_BACKENDS_KEY-unset}" "${CYFR_LOCUS_BUILDS_KEY-unset}" >>"$STUB_LOG/docker.calls"
case " $* " in
  *" config --format json "*) exec "$REAL_DOCKER" "$@" ;;
  *" up "*) exit "${STUB_UP_STATUS:-0}" ;;
  *" logs "*) echo "stub: the runtime's last log line" ;;
esac
exit 0
STUB
cat >"$stubs/git" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "config user.email" ] || { echo "the stub answers git config user.email alone" >&2; exit 99; }
[ -n "${STUB_GIT_EMAIL:-}" ] || exit 1
echo "$STUB_GIT_EMAIL"
STUB
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
    [ -z "${STUB_SERVER_STATUS:-}" ] || exit "$STUB_SERVER_STATUS"
    (trap '' TERM; exec sleep 300) &
    echo "$!" >"$STUB_LOG/watcher.pid"
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
chmod +x "$stubs/docker" "$stubs/git" "$stubs/mix" "$stubs/curl"

token="dev-stack-test-token-$(openssl rand -hex 6)"
root_a="$(printf 'ab%.0s' {1..32})"
key_b="$(printf 'b1%.0s' {1..32})"
key_c="$(printf 'c2%.0s' {1..32})"
complete="CYFR_GITHUB_CLIENT_ID=$example_id
CYFR_PLATFORM_ADMIN_EMAILS=dev@example.test
CYFR_LOCUS_RUNTIME_ROOT=$root_a
CYFR_LOCUS_BACKENDS_KEY=$key_b
CYFR_LOCUS_BUILDS_KEY=$key_c
"
compose_prefix="compose --env-file /dev/null --profile locus-builds -f docker-compose.yml -f docker-compose.dev.yml"
services="locus-runtime locus-backends locus-builds"
unset_keys="LOCUS_RUNTIME_KEY=unset|CYFR_LOCUS_BACKENDS_KEY=unset|CYFR_LOCUS_BUILDS_KEY=unset"

# prepare SCRIPT NAME ENV_TEXT MODE: a project of its own holding SCRIPT,
# the shipped and the variant compose files, .env.example, and .env as
# ENV_TEXT at MODE (none for no file). Sets $case_dir.
prepare() {
  case_dir="$scratch/case-$2"
  rm -rf "$case_dir" && mkdir -p "$case_dir/scripts" "$case_dir/tmp" "$case_dir/log"
  cp "$1" "$case_dir/scripts/dev-stack.sh"
  cp "$ROOT/docker-compose.yml" "$ROOT/.env.example" "$case_dir/"
  cp "$variant" "$case_dir/docker-compose.dev.yml"
  if [ "$4" != none ]; then
    printf '%s' "$3" >"$case_dir/.env"
    chmod "$4" "$case_dir/.env"
    cp -p "$case_dir/.env" "$case_dir/env.before"
  fi
}

# The script's environment: PATH, HOME, the stubs' settings and the
# given variables alone, every signal at its default as a shell starts a
# command.
launch() {
  (cd "$case_dir" && exec env -i PATH="$stubs:$PATH" HOME="$HOME" LC_ALL=C.UTF-8 TMPDIR="$case_dir/tmp" \
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
  prepare "$1" "$2" "$3" "$4"
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
  launch STUB_GIT_EMAIL=dev@example.test &
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
calls() { record docker.calls | while IFS= read -r line; do printf '%s\n' "${line/#"$compose_prefix" /compose }"; done; }
up_call() { echo "compose up --detach --build --wait $services|LOCUS_RUNTIME_KEY=$(derived "$1")|CYFR_LOCUS_BACKENDS_KEY=$2|CYFR_LOCUS_BUILDS_KEY=$3"; }
# The whole run of docker: the resolution, the leftovers removed, the
# start with the keys, and the removal on the way out.
full_run() {
  printf '%s\n' "compose config --format json $services|$unset_keys" "compose down --remove-orphans|$unset_keys" \
    "$(up_call "$1" "$2" "$3")" "compose down --remove-orphans|$unset_keys"
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

# Each case prints why it fails, nothing when it holds.
case_provision() {
  stack "$1" provision "" none "" STUB_GIT_EMAIL=dev@example.test STUB_SERVER_STATUS=0
  status_is 0
  [ "$(mode_of "$case_dir/.env")" = 0o600 ] || echo ".env is $(mode_of "$case_dir/.env"), not 0o600"
  local root backends builds
  root="$(sed -n 's/^CYFR_LOCUS_RUNTIME_ROOT=//p' "$case_dir/.env")"
  backends="$(sed -n 's/^CYFR_LOCUS_BACKENDS_KEY=//p' "$case_dir/.env")"
  # The builds key, which a boot refuses without its URL, is the run's
  # alone: the builder's and the server's, never .env's.
  builds="$(record docker.calls | sed -n 's/^.* up .*|CYFR_LOCUS_BUILDS_KEY=//p')"
  [ "$(cat "$case_dir/.env")" = "CYFR_GITHUB_CLIENT_ID=$example_id
CYFR_PLATFORM_ADMIN_EMAILS=dev@example.test
CYFR_LOCUS_RUNTIME_ROOT=$root
CYFR_LOCUS_BACKENDS_KEY=$backends" ] || echo ".env holds $(printf '%q' "$(cat "$case_dir/.env")")"
  for key in "$root" "$backends" "$builds"; do
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || echo "a minted key is $(printf '%q' "$key"), not 64 hexadecimal digits"
  done
  [ "$(printf '%s\n' "$root" "$backends" "$builds" | sort -u | wc -l)" = 3 ] || echo "the minted keys are not three"
  grep -qxF "dev-stack: .env is mode 0600 and now sets CYFR_GITHUB_CLIENT_ID, CYFR_PLATFORM_ADMIN_EMAILS, CYFR_LOCUS_RUNTIME_ROOT, CYFR_LOCUS_BACKENDS_KEY." "$case_dir/out" ||
    echo "the run did not say what it wrote: $(cat "$case_dir/out")"
  [ "$(calls)" = "$(full_run "$root" "$backends" "$builds")" ] || echo "docker was handed: $(calls)"
  [ "$(server_settings)" = "$(printf '%s\n' "$want_settings" "CYFR_LOCUS_BUILDS_KEY=$builds" | sort)" ] ||
    echo "the server's settings: $(server_settings)"
  record server.env | grep -qE "^(LOCUS_RUNTIME_KEY|CYFR_LOCUS_(RUNTIME_ROOT|BACKENDS_KEY))=" &&
    echo "a key reached the server's environment"
  grep -qxF "dev-stack: CYFR starts at http://localhost:$prism_port and reloads as its files change." "$case_dir/out" ||
    echo "the run did not print Prism's address: $(cat "$case_dir/out")"
  for key in "$root" "$backends" "$builds" "$(derived "$root")"; do
    if grep -qF "$key" "$case_dir/out" "$case_dir/err"; then echo "a key reached the output"; fi
  done
  nothing_left
}
case_retained() {
  local text
  for text in "$complete" "${complete/CYFR_LOCUS_RUNTIME_ROOT=/CYFR_LOCUS_RUNTIME_ROOT = }" \
    "${complete/$root_a/$root_a # the stack\'s root}"; do
    stack "$1" retained "$text" 0644 "" STUB_GIT_EMAIL=other@example.test STUB_SERVER_STATUS=0
    status_is 0
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo ".env changed from $(printf '%q' "$text") to $(printf '%q' "$(cat "$case_dir/.env")")"
    [ "$(calls)" = "$(full_run "$root_a" "$key_b" "$key_c")" ] || echo "on $(printf '%q' "$text") docker was handed: $(calls)"
    if grep -qF "$(derived "$root_a")" "$case_dir/out" "$case_dir/err"; then echo "the key reached the output"; fi
  done
}
case_no_email() {
  stack "$1" no-email "" none "" STUB_SERVER_STATUS=0
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run went on with no admin email"
  grep -qF "dev-stack: CYFR_PLATFORM_ADMIN_EMAILS is set in neither .env nor the environment" "$case_dir/err" &&
    grep -qF "Add the line CYFR_PLATFORM_ADMIN_EMAILS=<your email> to .env" "$case_dir/err" ||
    echo "the refusal does not name the line to add: $(cat "$case_dir/err")"
  [ ! -s "$case_dir/.env" ] || echo ".env gained $(cat "$case_dir/.env") on the refusal"
  [ "$(calls)" = "compose config --format json $services|$unset_keys" ] || echo "docker was handed: $(calls)"
  [ -z "$(record server.env)" ] || echo "the server started without an admin email"
}
case_refused() {
  local line name
  for line in "CYFR_LOCUS_RUNTIME_WORKERS = wrk_elsewhere=http://127.0.0.1:4999" "CYFR_HOST_API_BIND=0.0.0.0 # all of them" \
    "CYFR_HOST_API_URL=http://cyfr:4300" "CYFR_PORT=4000" "CYFR_LOCUS_BACKENDS_URL=http://locus-backends:4101"; do
    name="${line%%[ =]*}"
    stack "$1" refused "$complete$line"$'\n' 0644 "" STUB_GIT_EMAIL=dev@example.test STUB_SERVER_STATUS=0
    [ "$(cat "$case_dir/status")" != 0 ] || echo "the run accepted $line"
    grep -qF "dev-stack: $name is " "$case_dir/err" || echo "the refusal does not name $name: $(cat "$case_dir/err")"
    [ "$(calls)" = "compose config --format json $services|$unset_keys" ] || echo "docker ran past a disagreeing $name: $(calls)"
    [ -z "$(record server.env)" ] || echo "the server started though $name disagreed"
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo ".env changed on a refusal of $name"
  done
  stack "$1" empty-override "$complete" 0644 "" STUB_GIT_EMAIL=dev@example.test CYFR_LOCUS_BACKENDS_KEY=
  grep -qF "CYFR_LOCUS_BACKENDS_KEY is set empty in the environment" "$case_dir/err" || echo "the empty override's refusal: $(cat "$case_dir/err")"
  [ "$(calls | cut -d'|' -f1)" = "compose config --format json $services" ] || echo "docker ran under an empty key override: $(calls)"
}
case_release_root() {
  local sentence="dev-stack: RELEASE_ROOT is set, and it names a release: the dev stack runs CYFR from the checkout, which reads the .env at its root. Unset RELEASE_ROOT and run again."
  local command
  mkdir -p "$scratch/release"
  printf '%s' "$complete" >"$scratch/release/.env"
  for command in "" check; do
    stack "$1" release-root $'CYFR_PLATFORM_ADMIN_EMAILS=dev@example.test\n' 0644 "$command" \
      RELEASE_ROOT="$scratch/release" CYFR_TOKEN="$token" STUB_GIT_EMAIL=dev@example.test STUB_SERVER_STATUS=0
    [ "$(cat "$case_dir/status")" != 0 ] || echo "${command:-the loop} exited 0 under RELEASE_ROOT"
    [ "$(tail -n 1 "$case_dir/err")" = "$sentence" ] || echo "${command:-the loop} did not end on the RELEASE_ROOT refusal: $(cat "$case_dir/err")"
    cmp -s "$case_dir/.env" "$case_dir/env.before" || echo "${command:-the loop} changed .env under RELEASE_ROOT: $(cat "$case_dir/.env")"
    [ "$(calls)" = "compose config --format json $services|$unset_keys" ] || echo "${command:-the loop} ran docker under RELEASE_ROOT: $(calls)"
    [ -z "$(record server.env)$(record curl.actions)" ] || echo "${command:-the loop} served or ran a component under RELEASE_ROOT"
  done
}
case_prism_held() {
  python3 -I -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(120)' "$prism_port" &
  local holder=$!
  holders+=("$holder")
  for _ in $(seq 1 50); do ss -Hltn "sport = :$prism_port" | grep -q . && break; sleep 0.1; done
  stack "$1" prism-held "$complete" 0600 "" STUB_GIT_EMAIL=dev@example.test STUB_SERVER_STATUS=0
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run went on with Prism's address held"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: 127.0.0.1:$prism_port, Prism's address, is held by python3 (pid $holder). Stop it and run again." ] ||
    echo "the refusal does not name the holder: $(cat "$case_dir/err")"
  [ "$(calls)" = "compose config --format json $services|$unset_keys" ] || echo "docker ran with Prism's address held: $(calls)"
  [ -z "$(record server.env)" ] || echo "the server started with Prism's address held"
}
case_start_fails() {
  stack "$1" start-fails "$complete" 0600 "" STUB_GIT_EMAIL=dev@example.test STUB_UP_STATUS=1 STUB_SERVER_STATUS=0
  [ "$(cat "$case_dir/status")" != 0 ] || echo "the run exited 0 though the containers did not start"
  [ "$(calls)" = "$(printf '%s\n' "compose config --format json $services|$unset_keys" "compose down --remove-orphans|$unset_keys" \
    "$(up_call "$root_a" "$key_b" "$key_c")" "compose logs --tail 30|$unset_keys" "compose down --remove-orphans|$unset_keys")" ] ||
    echo "after a failed start docker was handed: $(calls)"
  grep -qF "stub: the runtime's last log line" "$case_dir/err" || echo "the failed start did not show the containers' logs: $(cat "$case_dir/err")"
  [ -z "$(record server.env)" ] || echo "the server started though the containers did not"
  if grep -qF "CYFR starts at" "$case_dir/out"; then echo "the run printed its address after a failed start"; fi
  nothing_left
}
case_server_ends() {
  stack "$1" server-ends "$complete" 0600 "" STUB_GIT_EMAIL=dev@example.test STUB_SERVER_STATUS=3
  status_is 3
  [ "$(calls)" = "$(full_run "$root_a" "$key_b" "$key_c")" ] || echo "after the server ended docker was handed: $(calls)"
  nothing_left
}
case_interrupted() {
  local signal want
  for signal in INT TERM HUP; do
    case "$signal" in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
    signalled "$1" "signal-$signal" "$signal"
    status_is "$want"
    [ "$(record server.events)" = $'started\nstopped' ] || echo "on $signal the server was not stopped: $(record server.events)"
    [ "$(calls)" = "$(full_run "$root_a" "$key_b" "$key_c")" ] || echo "on $signal docker was handed: $(calls)"
    nothing_left
  done
}
case_check() {
  stack "$1" check "$complete" 0644 check CYFR_TOKEN="$token"
  status_is 0
  [ "$(record curl.actions | awk '{print $1, $2}' | sort -u)" = "delete http://127.0.0.1:$prism_port/mcp
read_text http://127.0.0.1:$prism_port/mcp
write_text http://127.0.0.1:$prism_port/mcp" ] || echo "the check ran: $(record curl.actions)"
  [ "$(record curl.headers | sort -u)" = "file=0o600 dir=0o700 bearer=ok" ] || echo "the bearer's header file: $(record curl.headers)"
  if grep -qF "$token" "$case_dir/log/curl.calls" "$case_dir/out" "$case_dir/err"; then echo "the token reached curl's arguments or the output"; fi
  [ "$(calls)" = "compose config --format json $services|$unset_keys" ] || echo "the check ran docker: $(calls)"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "the check left a file in the athanor: $(cat "$case_dir/log/store.json")"
  nothing_left
}
case_failed_read() {
  stack "$1" failed-read "$complete" 0600 check CYFR_TOKEN="$token" STUB_FAIL=read_text
  [ "$(cat "$case_dir/status")" != 0 ] || echo "check exited 0 though its read failed"
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "after the failed read the check ran: $(record curl.actions)"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: refused: stub read_text failure" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "the failed read left its file: $(cat "$case_dir/log/store.json")"
  nothing_left

  stack "$1" failed-delete "$complete" 0600 check CYFR_TOKEN="$token" STUB_FAIL=read_text,delete
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "with the delete failing too the check ran: $(record curl.actions)"
  local left
  left="$(record curl.actions | awk 'NR == 1 {print $3}')"
  grep -qF "dev-stack: $left is left in the athanor's storage" "$case_dir/err" || echo "the check did not name the file it left: $(cat "$case_dir/err")"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: refused: stub read_text failure" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
}
case_failed_parse() {
  stack "$1" failed-parse "$complete" 0600 check CYFR_TOKEN="$token" STUB_READ_RESULT='[]'
  [ "$(cat "$case_dir/status")" != 0 ] || echo "check exited 0 though its read answered no content"
  [ "$(record curl.actions | awk '{print $1}')" = $'write_text\nread_text\ndelete' ] || echo "after a read with no content the check ran: $(record curl.actions)"
  [ "$(tail -n 1 "$case_dir/err")" = "dev-stack: read_text: the run answered no content: []" ] || echo "the check did not end with the read's failure: $(cat "$case_dir/err")"
  [ "$(cat "$case_dir/log/store.json")" = "{}" ] || echo "a read with no content left its file: $(cat "$case_dir/log/store.json")"
  nothing_left
}
BOUNDARY_CASES="case_provision case_retained case_no_email case_refused case_release_root case_prism_held case_start_fails case_server_ends case_interrupted case_check case_failed_read case_failed_parse"

# boundary SCRIPT [CASE...]: the failures of SCRIPT under each case.
boundary() {
  local script="$1" c
  shift
  for c in ${@:-$BOUNDARY_CASES}; do "$c" "$script" | sed "s/^/$c: /"; done
}

script="${DEV_STACK_SCRIPT:-$ROOT/scripts/dev-stack.sh}"
for c in $BOUNDARY_CASES; do
  out="$(boundary "$script" "$c")"
  if [ -z "$out" ]; then pass "scripts/dev-stack.sh: ${c#case_}"; else failed "scripts/dev-stack.sh: ${c#case_}" "$out"; fi
done

# respell NAME WHAT SED_EXPRESSION: an equivalent spelling, which holds.
respell() {
  sed -E "$3" "$script" >"$scratch/r-$1.sh"
  if cmp -s "$script" "$scratch/r-$1.sh"; then failed "$2 (the edit changed nothing)"; return; fi
  out="$(boundary "$scratch/r-$1.sh")"
  if [ -z "$out" ]; then pass "$2 holds"; else failed "$2 fails" "$out"; fi
}
respell spelled "the signals spelled by name" 's/kill -TERM "\$SERVER"/kill -s TERM "$SERVER"/; s/^trap .exit 130. INT$/trap "exit 130" SIGINT/'
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
break_script noterm "the server left running" case_interrupted 's/^    kill -TERM "\$SERVER" 2>\/dev\/null \|\| true$/    true/'
break_script nogroup "the server's process group left behind" "case_interrupted case_server_ends" '/kill -KILL -- "-\$SERVER"/d'
break_script noprism "Prism's address not checked" case_prism_held '/^  free "\$port" "Prism.s address"$/d'
break_script keysout "the keys in the server's environment" case_provision 's/^  \(export "\$\{server\[@\]\}" &&$/  (export "${server[@]}" "${keys[@]}" \&\&/'
break_script persisted "the server's settings written into .env" case_provision 's/^  free "\$port" "Prism.s address"$/  printf "%s\\n" "${server[@]}" >>.env\n&/'
break_script noemail "the admin email not handed on" case_provision 's/"\$\(git config user\.email 2>\/dev\/null \|\| true\)"/""/'
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
