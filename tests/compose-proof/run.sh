#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof: the shipped docker-compose.yml brought up as a project
# of its own by the `cyfr` command line built from this tree, with the app
# image built from this tree as the publication job builds it
# (Dockerfile), and what the shipped file and the command line promise
# held on the running stack. The project's tailscale service runs the
# Tailscale stand-in (tests/compose-proof/tailscale-standin/, which
# certifies no Tailscale binary; tests/tailnet-real/run.sh is the real
# tailnet's run). Its cases:
#
#   bind   in each reach mode, switched with the stack stopped (`cyfr down`,
#          `cyfr reach <mode>`, `cyfr up`): cyfr binds its loopback listener
#          to its fixed address on the default network (CYFR_BIND_ADDRESS,
#          the role table's endpoint_address) alone, its proxy listener to
#          its fixed address on the edge network alone in tailnet and
#          public and nowhere in local, and its host API to its fixed
#          address on the runtime's network. Docker publishes the host's
#          loopback port to the loopback listener alone, which answers
#          readiness and liveness there, and answers nothing to a container
#          on the edge network, to one on Docker's default bridge, or at
#          the host's non-loopback address; the proxy listener answers a
#          container on the edge network in tailnet and public, and
#          readiness answers through the mode's proxy (Caddy; Serve at the
#          node's name). The ports each mode publishes are the shipped
#          file's, as `docker compose config` resolves it alone and as
#          `docker port` reads the running project. No Locus network
#          reaches the loopback listener, while the runtime's network
#          reaches the host API.
#
#   modes  one project switched with `cyfr reach`, running, through every
#          ordered pair of the three modes: after each switch the whole
#          head is in .env and the running cyfr, a tailnet node id the one
#          the tailnet state holds, the head's proxy alone runs with the
#          shipped file's capabilities and options, the old one stopped
#          and removed, and cyfr is healthy at the head's address; in
#          tailnet Serve holds exactly the engine's configuration. In
#          public and tailnet a forged X-Forwarded-For and
#          Tailscale-User-Login, on both listeners and through the mode's
#          proxy, change neither the answer nor the client address cyfr
#          resolves (Sanctum.ClientIp, read from a probe in the running
#          node), which is the peer on the loopback listener and on the
#          proxy listener from an untrusted peer, and the client the proxy
#          names through it; and through the proxy an anonymous MCP
#          request is refused 401 with the auth error and a page request
#          sent to /login, with every forged forwarding and identity
#          header as without. In tailnet the
#          endpoint's HSTS is on the proxy listener's success, error and
#          refusal answers for the node's name and on none for a loopback
#          Host or on the loopback listener; in public the endpoint sends
#          none on its proxy listener, and an answer through Caddy carries
#          the shipped site's one value. At the ts.net name the origin is
#          the home's, MCP admits that origin and refuses another, the
#          LiveView socket upgrades for it and not another, and the
#          session cookie is the fixture person's: / sends to /login
#          without it and to that person's chat with it. Before the
#          switches: COMPOSE_PROFILES=public,tailnet in the command line's
#          environment starts neither proxy for a local home with builds
#          off, and the same key in .env, an incoherent .env and one with
#          no mode are each refused by `cyfr up` with the sentence the
#          vectors hold, nothing started. The predicates are
#          predicates.sh's, held to canned objects by predicates-test.sh.
#
#   interrupt
#          the real command line killed or failed mid-switch, each run
#          recovered by `cyfr reach --resume` exactly as the sentence it
#          printed says, to one coherent head, a receipt, and no journal or
#          materialized configuration left: killed after acceptance, before
#          its stop ran; killed alone while a docker child of its start is
#          paused, the next command refused while the orphan holds the
#          lock; a stop that fails, leaving the operation uncertain and
#          resumable; a start that fails, then a stop that fails, leaving it
#          uncertain with the target's materialized configuration kept.
#          Then the tailnet join's two instructions followed as
#          printed: HTTPS off for the tailnet, then `cyfr reach tailnet`
#          once it is on; tailnet_active, then `cyfr reach local` and `cyfr
#          reach tailnet --new-node`. A docker on PATH before the real one
#          (the run's own) pauses or fails the calls the case names, and
#          runs every other.
#
#   restore-identity
#          a home serving node A snapshotted with the stack stopped, as
#          `cyfr update` lays a snapshot out (an update needs a signed
#          release manifest, which a build of this tree has not); then
#          switched to local and joined as node B; then `cyfr restore` of
#          A: .env names A while the state volume holds B, so Serve stays
#          off (the node refuses 443 while it answers its PeerAPI), the
#          start answers tailnet_node_mismatch, the home answers on this
#          machine alone, and `cyfr reach tailnet` previews exactly A's
#          head to B's. The restore keeps the state volume (B) and the
#          project's .cyfr/, and removes join.json. The snapshot is the
#          proof's own, so that a snapshot holds neither the tailnet state
#          nor the reach state is apps/codex/cmd/update_test.go's
#          TestSnapshotsHoldNeitherTheTailnetStateNorTheReachState. The
#          restore alone runs as root, in a container of a pinned docker
#          CLI image with the host's docker and the project directory at
#          its own path, since a non-root person's restore cannot put back
#          a storage root the container's entrypoint has handed to the
#          image's user (a defect outside this proof); every other
#          CYFR command runs as the person.
#
#   shutdown
#          `docker compose stop cyfr` ends within the stop_grace_period
#          the shipped file gives cyfr, and cyfr exits on its own, never by
#          the SIGKILL that ends the grace, while it holds an SSE stream and
#          a running task. The stream is a signed-in person's MCP
#          `subscriptions/listen`, held open through the published loopback
#          port. The task is a tool call the console makes for that person
#          through the gate (tests/release-boot/fixture.exs `console`) to an
#          HTTP MCP server the person created over /mcp, its upstream round
#          trip a task under Emissary's task supervisor. The run serves that
#          server from a container of the app image on the project's
#          default network, and it holds every `tools/call` unanswered, so
#          the call is still running when the stop begins.
#          The held call and the held stream are the running work this
#          case measures a stop under; no execution or thread turn runs
#          here: both need the Locus runtime, which this project does not
#          start, and a turn a provider key besides. The case prints the
#          stop's wall time, the grace, the container's exit and how the
#          stream and the call ended.
#
#   restore
#          The restore's bar on the built image, as `cyfr restore` raises
#          and lifts it (tests/fixtures/restore_barrier.json, the bar's one
#          definition): with the stack stopped, the cyfr container removed
#          and the bar in .env, a start of the cyfr service is refused at
#          the entrypoint with the fixture's exit, and the declaration the
#          restore runs, `docker compose run --rm --no-deps -T -e <bar>= cyfr
#          bin/cyfr eval <declaration>`, boots past the release's
#          configuration and answers the restore's id.
#
# The project is the run's own: its directory is named for the run, which
# makes the compose project the command line derives from it one no other
# stack on this host has; it holds a copy of docker-compose.yml, the
# overlay as its docker-compose.override.yml, and the .env `cyfr init`
# writes, with the run's own settings beside it, and the shipped Caddyfile
# as proof.Caddyfile with its site address made plain HTTP, so Caddy serves
# the proof's port 80 with no certificate to trust while its reverse_proxy
# block and the header handling under test are byte for byte the shipped
# ones (`proof_caddyfile`). With an http:// address Caddy obtains no
# certificate, so the global options' email stays as shipped. The run fails
# before any case when the copy differs from the shipped file other than
# by exactly this diff:
#
#   -{$CYFR_HOST:localhost} {
#   +http://{$CYFR_HOST:localhost} {
#
# The containers are named
# from the project, host ports are ones Docker picks on the loopback, and
# the project goes whole, its volumes, the engine's join network and join
# containers and the run's stand-in image with it, when the run ends,
# however it ends (tests/compose-proof/cleanup.sh: a removal that fails
# three times fails the run, naming the project). Nothing of a deployed
# stack on the same host is touched.
#
# Usage: tests/compose-proof/run.sh --case bind|modes|interrupt|restore-identity|shutdown|restore
# COMPOSE_PROOF_IMAGE names the app image (default cyfr:compose-proof);
# COMPOSE_PROOF_SKIP_BUILD=1 reuses that image as a previous run or build
# left it; COMPOSE_PROOF_KEEP=1 keeps the scratch directory. Needs docker,
# go (the command line and the stand-in are built here), python3 and
# curl. test.yml's locus-backends-image job runs every case on the app
# image it builds, tagged cyfr:compose-proof.
set -euo pipefail

CASES="bind|modes|interrupt|restore-identity|shutdown|restore"
usage() {
  echo "usage: $0 --case $CASES" >&2
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
case "$CASE" in bind | modes | interrupt | restore-identity | shutdown | restore) ;; *) usage ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="${COMPOSE_PROOF_IMAGE:-cyfr:compose-proof}"
# The proof's own compose calls read no COMPOSE_* setting of the caller's
# but its own knobs; the command line's environment is built apart
# (`cyfr_cli`).
for name in $(compgen -e); do
  case "$name" in COMPOSE_PROOF_*) ;; COMPOSE_*) unset "$name" ;; esac
done
RUN="cyfr-compose-proof-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
WORK="${TMPDIR:-/tmp}/$RUN"
mkdir -m 700 "$WORK"
STANDIN_IMAGE="cyfr-tailscale-standin:$RUN"
# The shutdown case's MCP upstream, a container of the run's own.
UPSTREAM=""
CYFR="$WORK/bin/cyfr"
# The command line's PATH: the interrupt case puts its docker first.
CLI_PATH="$PATH"
REAL_DOCKER="$(command -v docker)"
cyfr_id=""
# The signed-in person's athanor (sign_in).
SEGMENT=""

compose() {
  docker compose --project-name "$RUN" --project-directory "$WORK" \
    -f "$WORK/docker-compose.yml" -f "$WORK/docker-compose.override.yml" \
    --profile public --profile tailnet --profile locus-builds "$@"
}

# shellcheck source=tests/compose-proof/cleanup.sh
. "$HERE/cleanup.sh"
# shellcheck source=tests/compose-proof/predicates.sh
. "$HERE/predicates.sh"
trap cleanup EXIT

step() { echo; echo "==> $*"; }
ok() { echo "ok: $*"; }
fail() {
  echo "::error::$*" >&2
  exit 1
}

# A field of the restore's bar (tests/fixtures/restore_barrier.json).
barrier() {
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$ROOT/tests/fixtures/restore_barrier.json" "$1"
}

# A field of the role table's vector file (tests/fixtures/locus_roles.json).
table() {
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["release"][sys.argv[2]])' \
    "$ROOT/tests/fixtures/locus_roles.json" "$1"
}

# The value at path `$2...` of the JSON `$1`: a string as itself, anything
# else as JSON, null for a step that is not there.
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

# The value .env's last assignment of `$1` holds, or nothing.
env_value() {
  NAME="$1" awk 'index($0, ENVIRON["NAME"] "=") == 1 { value = substr($0, length(ENVIRON["NAME"]) + 2) } END { print value }' "$WORK/.env"
}

# Sets `$1` to `$2` in .env as a person edits it: the first assignment
# rewritten in place and any later one removed, or the line added at the
# end; with no `$2`, every assignment of `$1` removed.
env_set() {
  if [ $# -ge 2 ]; then
    NAME="$1" VALUE="$2" awk '
      BEGIN { name = ENVIRON["NAME"]; line = name "=" ENVIRON["VALUE"] }
      index($0, name "=") == 1 { if (!done) print line; done = 1; next }
      { print }
      END { if (!done) print line }
    ' "$WORK/.env" >"$WORK/.env.part"
  else
    NAME="$1" awk 'index($0, ENVIRON["NAME"] "=") != 1' "$WORK/.env" >"$WORK/.env.part"
  fi
  # Written over the file, not renamed onto it, so .env keeps its mode.
  cat "$WORK/.env.part" >"$WORK/.env"
  rm -f "$WORK/.env.part"
}

# The command line in the project directory, as a person runs it there:
# HOME the run's own, nothing of the caller's environment but PATH
# (CLI_PATH) and how Docker is reached, then `$@`'s leading NAME=value
# words. Its process writes its pid to CLI_PIDFILE, when set, and execs
# the command line, so that pid is the command line's own.
CLI_PIDFILE=""
cyfr_cli() {
  local -a words=()
  while [ $# -gt 0 ] && [[ "$1" == [A-Z]*=* ]]; do
    words+=("$1")
    shift
  done
  (
    cd "$WORK" || exit 1
    [ -z "$CLI_PIDFILE" ] || echo "$BASHPID" >"$CLI_PIDFILE"
    # A person's usual umask, where the host runner's is 077: what the
    # command line makes, data/ among it, has the modes a person's
    # install has, and the entrypoint gives data/ to the image's user.
    umask 022
    exec env -i HOME="$WORK/home" PATH="$CLI_PATH" LANG=C.UTF-8 TERM=dumb \
      DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
      ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} \
      ${words[@]+"${words[@]}"} "$CYFR" "$@"
  )
}

# The docker CLI image the restore-identity case runs `cyfr restore` in, as
# root (docker:29.8.1-cli).
ROOT_CLI_IMAGE="docker:29.8.1-cli@sha256:018edbc908e08fcc9dbf029c812c34251e9b4719e6f71ca0e5eae2a987d014ca"

# The command line's run `$2...` as root, in a container of ROOT_CLI_IMAGE
# with the host's docker at the image's default socket and the project
# directory at its own path, its output in `$WORK/$1.log`; its status is
# the run's. Everything it leaves in the project but data/, which is the
# image's user's, goes back to the person, so the steps after it run as the
# person again.
cli_run_root() {
  local log="$WORK/$1.log" endpoint status=0
  shift
  endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
  case "$endpoint" in
    unix://*) ;;
    *) fail "the host's docker is at $endpoint, not a socket a container can mount" ;;
  esac
  printf '$ cyfr %s (as root)\n' "$*" >"$log"
  docker run --rm -v "${endpoint#unix://}:/var/run/docker.sock" -v "$WORK:$WORK" -w "$WORK" \
    -e HOME="$WORK/home" -e LANG=C.UTF-8 -e TERM=dumb --entrypoint "$CYFR" "$ROOT_CLI_IMAGE" "$@" \
    </dev/null >>"$log" 2>&1 || status=$?
  docker run --rm --user 0 -v "$WORK:$WORK" --entrypoint sh "$IMAGE" -c \
    'find "$1" -mindepth 1 -maxdepth 1 ! -name data -exec chown -R "$2" {} +' sh "$WORK" "$(id -u):$(id -g)" ||
    fail "what the restore left in the project could not be given back to the person"
  return "$status"
}

# The command line's run `$2...` with its output in `$WORK/$1.log` and its
# pid in `$WORK/$1.pid`; its status is the run's.
cli_run() {
  local log="$WORK/$1.log"
  local CLI_PIDFILE="$WORK/$1.pid"
  shift
  rm -f "$CLI_PIDFILE"
  printf '$ cyfr %s\n' "$*" >"$log"
  cyfr_cli "$@" </dev/null >>"$log" 2>&1
}

# The pid of the command line run `$1` started, once it is written,
# within 30 s.
cli_pid() {
  local closes=$((SECONDS + 30))
  until [ -s "$WORK/$1.pid" ]; do
    [ "$SECONDS" -lt "$closes" ] || fail "the command line run $1 wrote no pid"
    sleep 0.1
  done
  cat "$WORK/$1.pid"
}

# As cli_run, failing the case, with the output's last lines, unless the
# command line exits 0.
cli_ok() {
  local name="$1" status=0
  cli_run "$@" || status=$?
  [ "$status" -eq 0 ] || fail "cyfr ${*:2} exited $status: $(tail -n 30 "$WORK/$name.log")"
}

# The refusal `$1`'s sentence (the refusals or boot vectors, the one
# definition the command line renders from) is in the file `$2`, its slots
# filled by `$3...`'s name=value words where given and anything elsewhere,
# space runs read as one. Prints the slots it read and each `cyfr ...`
# command the sentence's own words name, in order, as JSON; fails when no
# variant is there.
# shellcheck disable=SC2016
SENTENCE_PY='
import json, re, sys
vectors, code, path = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
given = dict(a.split("=", 1) for a in sys.argv[4:])
text = re.sub(r"\s+", " ", open(path, errors="replace").read())
templates = [v["template"] for r in vectors["refusals"] if r["code"] == code for v in r["variants"]]
templates += [v["refusal"]["sentence"] for v in vectors["boot"] if "refusal" in v and v["refusal"]["code"] == code]
for template in templates:
    template = re.sub(r"\s+", " ", template)
    pattern, slots = "", []
    for part in re.split(r"(\{[a-z_]+\})", template):
        if re.fullmatch(r"\{[a-z_]+\}", part):
            slot = part[1:-1]
            if slot in given:
                pattern += re.escape(given[slot])
            elif slot in slots:
                pattern += "(?P=%s)" % slot
            else:
                slots.append(slot)
                pattern += "(?P<%s>.+?)" % slot
        else:
            pattern += re.escape(part)
    match = re.search(pattern, text)
    if match:
        commands = re.findall(r"`(cyfr [^`{}]*)`", template)
        print(json.dumps({"slots": match.groupdict(), "commands": commands}))
        sys.exit(0)
sys.exit(1)'
sentence() {
  python3 -I -c "$SENTENCE_PY" "$ROOT/tests/fixtures/reach_modes.json" "$@"
}

# The sentence of refusal `$1` rendered from its one variant whose fixed
# fields and slots `$2...` (name=value) name exactly, as the command line
# renders it.
render() {
  python3 -I -c '
import json, re, sys
vectors, code = json.load(open(sys.argv[1])), sys.argv[2]
given = dict(a.split("=", 1) for a in sys.argv[3:])
for r in vectors["refusals"]:
    if r["code"] != code:
        continue
    for v in r["variants"]:
        rest = {k: x for k, x in given.items() if k not in v["fixed"]}
        if sorted(v["slots"]) == sorted(rest) and all(given.get(k) == x for k, x in v["fixed"].items()):
            print(re.sub(r"\{([a-z_]+)\}", lambda m: given[m.group(1)], v["template"]))
            sys.exit(0)
sys.exit(1)' "$ROOT/tests/fixtures/reach_modes.json" "$@" || fail "no variant of $1 is filled by $*"
}

# The value `$2...` answers, as an expected value: the run fails, naming
# `$1`, when the command fails or answers nothing, since an empty pattern
# or operand matches anything.
expected() {
  local what="$1" value
  shift
  value="$("$@")" || fail "no $what: $* failed"
  [ -n "$value" ] || fail "no $what: $* answered nothing"
  printf '%s\n' "$value"
}

# The vectors' boot sentence of the vector named `$1`.
boot_sentence() {
  python3 -I -c '
import json, sys
for v in json.load(open(sys.argv[1]))["boot"]:
    if v["name"] == sys.argv[2]:
        print(v["refusal"]["sentence"]); break
else:
    sys.exit(1)' "$ROOT/tests/fixtures/reach_modes.json" "$1"
}

# The project's services with a running container, sorted, one line.
# A docker ps that fails answers that, never the empty list.
running() {
  local out
  out="$(docker ps --filter "label=com.docker.compose.project=$RUN" --format '{{.Label "com.docker.compose.service"}}')" ||
    { echo "(docker ps failed)"; return 1; }
  printf '%s\n' "$out" | sort | tr '\n' ' ' | sed 's/ $//'
}

# Whether the project has a container of service `$1`, running or not.
has_container() {
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$RUN" --filter "label=com.docker.compose.service=$1")" ||
    fail "docker ps failed, so whether the project has a $1 container is unknown"
  [ -n "$ids" ]
}

# cyfr's container once Docker reports it healthy, within 180 s, in
# cyfr_id.
await_healthy() {
  local id="" health="" closes=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$closes" ]; do
    id="$(compose ps -q cyfr 2>/dev/null || true)"
    if [ -n "$id" ]; then
      health="$(docker inspect --format '{{.State.Health.Status}}' "$id" 2>/dev/null || true)"
      if [ "$health" = healthy ]; then
        cyfr_id="$id"
        return 0
      fi
    fi
    sleep 1
  done
  fail "cyfr is ${health:-not running} after 180 s"
}

# `bin/cyfr rpc` of `$1` inside the running cyfr, as the image's user.
cyfr_rpc() {
  docker exec -u app "$cyfr_id" /app/bin/cyfr rpc "$1"
}

# One command of the release proofs' fixture (tests/release-boot/fixture.exs)
# in the running cyfr, each argument an Elixir string with `\`, `"` and `#`
# escaped: its one JSON answer, or nothing when it raised.
cyfr_fixture() {
  local args="" arg
  docker cp "$ROOT/tests/release-boot/fixture.exs" "$cyfr_id:/tmp/fixture.exs" >/dev/null
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"#]/\\&/g')\","
  done
  cyfr_rpc "{answer, _} = Code.eval_file(\"/tmp/fixture.exs\"); IO.puts(answer.([${args%,}]))" |
    sed -n 's/^FIXTURE=//p' | tail -1
}

# A JSON-RPC request's body as a person's MCP client sends it to /mcp:
# method `$1`, params `$2` with the request metadata the protocol version
# `$3` asks for.
mcp_body() {
  python3 -I -c '
import json, sys
method, params, version = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
params["_meta"] = {
    "io.modelcontextprotocol/protocolVersion": version,
    "io.modelcontextprotocol/clientInfo": {"name": "compose-proof", "version": "0"},
    "io.modelcontextprotocol/clientCapabilities": {},
}
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))' "$@"
}

# POST the body `$3` to /mcp at `$1` as the method `$2` (and, for a
# tools/call, the tool `$4`), with the person's session from the run's
# header file, so the session rides no command line; further arguments go
# to curl.
mcp_post() {
  local base="$1" method="$2" body="$3" name="${4:-}"
  shift 4
  local headers=(-H @"$WORK/session.headers" -H 'content-type: application/json'
    -H 'accept: application/json, text/event-stream'
    -H "mcp-protocol-version: $MCP_VERSION" -H "mcp-method: $method")
  [ -z "$name" ] || headers+=(-H "mcp-name: $name")
  curl -sS "${headers[@]}" --data-binary "$body" "$@" "$base/mcp"
}

# Seconds from the instant `$1` to `$2` (`date +%s.%N`), to the millisecond.
seconds() { python3 -I -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.3f}")' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Clients on the stack's networks
# ---------------------------------------------------------------------------

# `curl` `$2...` from a container of the app image on the network `$1`
# (`bridge` is Docker's default bridge; anything else is the project's
# network of that name), outside cyfr. Prints `IP=<its address>`, then
# what it was asked, then the status line `STATUS=` and the status, or
# `refused` where the connection failed at once (curl's exit 7: nothing
# listens at that address), or `error <exit>` for anything else, a timeout
# among them. The container goes when it ends, so no network it is on
# outlives the request.
from_network() {
  local network="$1"
  shift
  [ "$network" = bridge ] || network="${RUN}_${network}"
  docker run --rm --network "$network" --entrypoint sh "$IMAGE" -c '
    echo "IP=$(hostname -i | cut -d" " -f1)"
    out="$(curl -sS -o /tmp/body -D /tmp/head -w "%{http_code}" --max-time 5 "$@" 2>&1)"; code=$?
    cat /tmp/head 2>/dev/null; echo; cat /tmp/body 2>/dev/null; echo
    case $code in 0) echo "STATUS=$out" ;; 7) echo "STATUS=refused" ;; *) echo "STATUS=error $code" ;; esac' sh "$@"
}

# The STATUS= of a from_network answer `$1`.
status_of() { printf '%s\n' "$1" | sed -n 's/^STATUS=//p' | tail -1; }
ip_of() { printf '%s\n' "$1" | sed -n 's/^IP=//p' | head -1; }

# The stand-in's authority, which a tailnet client trusts in place of the
# public one a real tailnet's certificates chain to.
standin_ca() {
  local ts
  ts="$(compose ps -q tailscale)"
  [ -n "$ts" ] || fail "no tailscale container runs"
  docker exec "$ts" standin ca >"$WORK/standin-ca.pem" || fail "the stand-in has no authority"
}

# One request from a device on the tailnet, through Serve: `standin fetch`
# `$@` from a container of the stand-in's image on proof-tailnet, trusting
# the stand-in's authority, to the tailscale service's port 443. Prints
# `IP=<its address>`, then fetch's JSON line.
tailnet_fetch() {
  docker run --rm --network "${RUN}_proof-tailnet" -v "$WORK/standin-ca.pem:/ca.pem:ro" "$STANDIN_IMAGE" \
    sh -c 'echo "IP=$(hostname -i | cut -d" " -f1)"; exec standin fetch --ca /ca.pem --connect tailscale:443 "$@"' sh "$@" || true
}
fetched() { printf '%s\n' "$1" | sed -n '/^{/p' | tail -1; }

# The address cyfr's loopback listener is published on.
published() { compose port cyfr "$(env_value CYFR_PORT)"; }

# proof.Caddyfile: the shipped Caddyfile with its one site address given
# the http:// scheme, then held to differ from the shipped file by exactly
# the diff this file's header shows, line for line, before any case runs.
proof_caddyfile() {
  local diff
  python3 -I - "$ROOT/Caddyfile" "$WORK/proof.Caddyfile" <<'PY' || fail "the shipped Caddyfile has no one site address to serve over plain HTTP"
import re, sys
lines = open(sys.argv[1]).read().splitlines(keepends=True)
sites = [i for i, line in enumerate(lines) if re.fullmatch(r"(?!#)\S.* \{\n", line)]
if len(sites) != 1 or lines[sites[0]].startswith("http://"):
    sys.exit(1)
lines[sites[0]] = "http://" + lines[sites[0]]
open(sys.argv[2], "w").write("".join(lines))
PY
  # Readable by caddy's root, which holds no capability to read past a
  # file's mode, as a checkout's Caddyfile is.
  chmod 644 "$WORK/proof.Caddyfile"
  diff="$(python3 -I - "$HERE/run.sh" "$ROOT/Caddyfile" "$WORK/proof.Caddyfile" <<'PY'
import difflib, re, sys
header = []
for line in open(sys.argv[1]).read().splitlines()[1:]:
    if not line.startswith("#"):
        break
    header.append(line)
shown = [l[4:] for l in header if re.match(r"#   [-+](?![-+]{2} )", l)]
shipped = open(sys.argv[2]).read().splitlines()
made = open(sys.argv[3]).read().splitlines()
actual = [l for l in difflib.unified_diff(shipped, made, lineterm="", n=0)
          if l[:1] in "-+" and not l.startswith(("---", "+++"))]
print("\n".join(actual))
sys.exit(0 if shown and actual == shown else 1)
PY
)" || fail "proof.Caddyfile differs from the shipped Caddyfile other than by the diff this file's header shows: $(printf '%s' "$diff" | tr '\n' ';')"
  ok "proof.Caddyfile is the shipped Caddyfile but for: $(printf '%s' "$diff" | tr '\n' ';')"
}

# The proxy listener's port: what compose passes caddy as CYFR_PROXY_PORT,
# .env's or the default, which cyfr reads the same way.
proxy_port() {
  compose config --format json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["caddy"]["environment"]["CYFR_PROXY_PORT"])'
}

# ---------------------------------------------------------------------------
# The client address cyfr resolves
# ---------------------------------------------------------------------------

# A probe in the running node: for each request carrying x-proof-mark,
# the address Sanctum.ClientIp resolves for it, recorded as the endpoint's
# telemetry reports the request. Attached again after every start of
# cyfr, whose node it lives in.
probe_attach() {
  local answer
  answer="$(cyfr_rpc '
    if :ets.whereis(:compose_proof_client_ips) == :undefined do
      parent = self()
      spawn(fn ->
        :ets.new(:compose_proof_client_ips, [:named_table, :public, :bag])
        send(parent, :ready)
        Process.sleep(:infinity)
      end)
      receive do
        :ready -> :ok
      after
        5_000 -> raise "the probe table was not made"
      end
    end
    :telemetry.detach("compose-proof-client-ip")
    :ok = :telemetry.attach("compose-proof-client-ip", [:phoenix, :endpoint, :stop], fn _event, _measure, %{conn: conn}, _ ->
      case Plug.Conn.get_req_header(conn, "x-proof-mark") do
        [mark | _] -> :ets.insert(:compose_proof_client_ips, {mark, Sanctum.ClientIp.resolve(conn)})
        [] -> :ok
      end
    end, nil)
    IO.puts("PROBE=ok")' | sed -n 's/^PROBE=//p')"
  [ "$answer" = ok ] || fail "the client-address probe could not be attached to the running node"
}

# The addresses cyfr resolved for the requests marked `$1`, comma-separated.
resolved() {
  cyfr_rpc "IO.puts(\"IPS=\" <> Enum.join(for({_, ip} <- :ets.lookup(:compose_proof_client_ips, \"$1\"), do: ip), \",\"))" |
    sed -n 's/^IPS=//p' | tail -1
}

# A fresh mark for one request, unique without a counter, as each mark is
# taken in a command substitution, a subshell whose count would not last.
mark() { printf 'm%s' "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; }

# The value the endpoint sends as Strict-Transport-Security, from its one
# spelling, as tests/proxy-hsts/run.sh reads it.
HSTS="$(sed -n 's/.*"strict-transport-security", "\([^"]*\)".*/\1/p' "$ROOT/apps/cyfr/lib/cyfr_web/plugs/api_security_headers.ex")"
[ -n "$HSTS" ] && [ "$(printf '%s\n' "$HSTS" | wc -l)" -eq 1 ] || fail "no single strict-transport-security value in api_security_headers.ex"

# The Strict-Transport-Security values a response carries, one per line:
# of fetch's JSON answer `$1` (hsts_of), or of the header lines in the
# text `$1` (hsts_in, as curl dumps them).
hsts_of() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
for value in json.load(sys.stdin).get("headers", {}).get("Strict-Transport-Security", []):
    print(value)'
}
hsts_in() {
  printf '%s\n' "$1" | python3 -I -c '
import sys
for line in sys.stdin.read().replace("\r", "").splitlines():
    name, _, value = line.partition(":")
    if name.strip().lower() == "strict-transport-security":
        print(value.strip())'
}

# ---------------------------------------------------------------------------
# The stack's modes
# ---------------------------------------------------------------------------

# The tailnet's auth key the command line reads from a file: the
# stand-in logs a fresh volume in with any key (tests/tailnet-real/run.sh
# is a real tailnet's).
AUTH_KEY_FILE="$WORK/tailnet-auth-key"

# The join container the engine started for this project, once it waits
# for approval (NeedsLogin with a link), within 120 s.
await_join() {
  local join="" closes=$((SECONDS + 120)) state=""
  while [ "$SECONDS" -lt "$closes" ]; do
    join="$(docker ps -q --filter "label=com.cyfr.reach.project=$RUN" | head -1)"
    if [ -n "$join" ]; then
      state="$(docker exec "$join" tailscale status --json 2>/dev/null || true)"
      if [ -n "$state" ] && [ "$(jget "$state" BackendState)" = NeedsLogin ] &&
        [[ "$(jget "$state" AuthURL)" == https://* ]]; then
        printf '%s\n' "$join"
        return 0
      fi
    fi
    sleep 0.5
  done
  fail "no join container of the project waited for approval within 120 s"
}

# `cyfr reach tailnet` with `$1`'s arguments, approved by a person in the
# stand-in as `$2...` (`standin approve`'s and, before it, `standin
# tailnet --https off` when `$2` is `https-off`), its output in
# `$WORK/<log>.log`; the command line's status is the answer's.
tailnet_join() {
  local log="$1" args="$2" https="" join status=0
  shift 2
  if [ "${1:-}" = https-off ]; then
    https=off
    shift
  fi
  # shellcheck disable=SC2086
  cli_run "$log" reach tailnet $args &
  local pid=$!
  join="$(await_join)"
  # The approval link the command line printed is the one the machine waits at.
  local link
  link="$(jget "$(docker exec "$join" tailscale status --json)" AuthURL)"
  [ -z "$https" ] || docker exec "$join" standin tailnet --https off
  docker exec "$join" standin approve "$@" >/dev/null
  wait "$pid" || status=$?
  grep -qF -- "$link" "$WORK/$log.log" || fail "cyfr reach tailnet did not print the approval link $link: $(tail -n 20 "$WORK/$log.log")"
  return "$status"
}

# The tailnet machine's name, read from the tailnet state apart from
# .env: its Self.DNSName without the trailing dot. A case that does not
# fix the name a join gives expects the head at this one.
node_name() {
  local name
  name="$(jget "$(docker exec "$(compose ps -q tailscale)" tailscale status --json)" Self DNSName)"
  [[ "$name" == ?*. ]] || fail "the tailnet state names no machine: ${name:-nothing}"
  printf '%s\n' "${name%.}"
}

# The project's whole head, checked (predicates.sh `head_holds`): mode
# `$1` at host `$2` (a fixed fixture's name, or the state's, never .env's),
# every reach setting in .env and the running cyfr the head's, a tailnet
# head's node id and name the ones the tailnet state holds, the head's
# proxy alone running beside cyfr with the shipped file's capabilities and
# options (`capabilities_hold`), the other proxy without a container, and
# cyfr healthy.
expect_head() {
  local mode="$1" host="$2" want profiles node="" dns_name="" public_url="" head why proxy id state
  [ -n "$host" ] || fail "no host to expect the $mode home at"
  case "$mode" in
    local) want=cyfr profiles='[]' ;;
    public) want="caddy cyfr" profiles='["public"]' public_url="https://$host" ;;
    tailnet)
      want="cyfr tailscale" profiles='["tailnet"]' public_url="https://$host"
      # The node id and name the tailnet state holds, read apart from .env.
      state="$(docker exec "$(compose ps -q tailscale)" tailscale status --json)"
      node="$(jget "$state" Self ID)"
      dns_name="$(jget "$state" Self DNSName)"
      [ -n "$node" ] && [ "$node" != null ] || fail "the tailnet state names no node"
      ;;
    *) fail "no head of a mode '$mode'" ;;
  esac
  await_healthy
  # The whole head: no case changes the port cyfr init writes (the shipped
  # default), gives an email, or turns builds on.
  head="$(python3 -I -c '
import json, sys
mode, host, url, node, profiles = sys.argv[1:6]
head = {"mode": mode, "host": host, "port": 4000, "profiles": json.loads(profiles)}
if url:
    head["public_url"] = url
if node:
    head["node_id"] = node
print(json.dumps(head))' "$mode" "$host" "$public_url" "$node" "$profiles")"
  why="$(head_holds "$head" "$WORK/.env" "$(docker inspect -f '{{json .Config.Env}}' "$cyfr_id")" "$(running)" "$node" "$dns_name")" ||
    fail "the project does not run the $mode head at $host: $why"
  for proxy in caddy tailscale; do
    case " $want " in
      *" $proxy "*)
        id="$(compose ps -q "$proxy")"
        why="$(capabilities_hold "$proxy" "$(docker inspect -f '{{json .HostConfig}}' "$id")" "$(docker exec "$id" cat /proc/1/status)")" ||
          fail "the $proxy proxy runs with other privileges than the shipped file's: $why"
        ;;
      *) ! has_container "$proxy" || fail "in $mode the project still has a $proxy container: stopped, but not removed" ;;
    esac
  done
  ok "the home is $mode at $host: the whole head in .env and the running cyfr, '$want' runs$([ "$mode" = local ] || echo ", its proxy with the shipped file's capabilities"), cyfr is healthy, and no other proxy has a container"
}

# The tailscale container's serve configuration, compact.
serving() { docker exec "$(compose ps -q tailscale)" standin serving; }

# Serve is open for the node `$1`, forwarding to cyfr's proxy listener,
# within 60 s: the engine opens it once the node is validated.
expect_serve_open() {
  local name="$1" port closes=$((SECONDS + 60)) config="" why=""
  port="$(proxy_port)"
  while [ "$SECONDS" -lt "$closes" ]; do
    config="$(serving 2>/dev/null || true)"
    if why="$(serve_config_holds "$config" "$name" "$port")"; then
      ok "Serve holds exactly the engine's configuration for $name, forwarding to cyfr:$port"
      return 0
    fi
    sleep 0.5
  done
  fail "Serve does not hold the engine's configuration for $name within 60 s: $why"
}

# Serve closed for the node `$1`: through the tailnet's path, the node
# answers the control, its PeerAPI at the port its status names, and
# itself refuses 443; a probe that failed otherwise is no closed Serve.
expect_serve_closed() {
  local name="$1" status port control target
  status="$(docker exec "$(compose ps -q tailscale)" tailscale status --json)"
  port="$(jget "$status" Self PeerAPIURL 0)"
  port="${port##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || fail "the node's status names no PeerAPI URL: $status"
  control="$(fetched "$(docker run --rm --network "${RUN}_proof-tailnet" "$STANDIN_IMAGE" \
    standin fetch --connect "tailscale:$port" "http://$name/" || true)")"
  [[ "$(jget "$control" status)" =~ ^[0-9]{3}$ ]] || fail "the node's PeerAPI did not answer through the tailnet: ${control:-nothing}"
  target="$(fetched "$(tailnet_fetch "https://$name/api/health")")"
  [ "$(jget "$target" error)" = refused ] || fail "through Serve, https://$name/ was not refused by the node: ${target:-nothing}"
}

# ---------------------------------------------------------------------------
# The project
# ---------------------------------------------------------------------------

project_new() {
  step "the command line and the Tailscale stand-in, built from this tree"
  mkdir -p "$WORK/bin" "$WORK/home"
  # -mod=readonly: the build reads go.mod and go.sum as they are.
  (cd "$ROOT/apps/codex" && CGO_ENABLED=0 go build -mod=readonly -o "$CYFR" .) || fail "the command line did not build"
  "$HERE/tailscale-standin/build.sh" image "$STANDIN_IMAGE"
  ok "built $CYFR and $STANDIN_IMAGE"

  step "the project's directory: the shipped file, the overlay, and the .env cyfr init writes"
  cp "$ROOT/docker-compose.yml" "$WORK/docker-compose.yml"
  cp "$HERE/compose.yml" "$WORK/docker-compose.override.yml"
  cp "$ROOT/apps/locus/keeper/seccomp/keeper.json" "$WORK/keeper.seccomp.json"
  cp "$ROOT/.env.example" "$WORK/.env.example"
  cli_ok init init --no-interactive --no-pull --reach local
  [ -f "$WORK/.env" ] || fail "cyfr init wrote no .env"
  # The run's own settings: its images, migration, its operator, the
  # private host the shutdown case's upstream is, and builds off as an
  # operator turns them off, both empty. With operators named, the setup
  # link's capability init minted is deleted, as its refusal says to.
  env_set CYFR_SETUP_TOKEN
  env_set CYFR_AUTO_MIGRATE true
  env_set CYFR_PLATFORM_ADMIN_EMAILS operator@example.com
  env_set CYFR_LOCUS_BUILDS_URL ""
  env_set CYFR_LOCUS_BUILDS_KEY ""
  if [ "$CASE" = shutdown ]; then
    env_set CYFR_PRIVATE_EGRESS_TARGETS "locus-backends,$UPSTREAM_HOST"
  fi
  env_set PROOF_APP_IMAGE "$IMAGE"
  env_set PROOF_TAILSCALE_IMAGE "$STANDIN_IMAGE"
  (umask 077 && printf 'tskey-auth-proof%s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" >"$AUTH_KEY_FILE")
  ok "wrote $WORK/.env: CYFR_REACH=$(env_value CYFR_REACH), builds off"
  # Once the project resolves, so a refused copy leaves a project its
  # teardown can take down.
  proof_caddyfile
}

# The island networks exist before cyfr joins them, with IPv6: the plain
# ones, the builds and backends islands' (the runtime's carries its own
# subnet), as they do in a deployment whose island started first, or whose
# cyfr was recreated beside running islands, and with IPv6 on, as the image
# suites' overlays and a dual-stack deployment have them: Docker's port
# mapping must still land on the default network's address. Docker maps a
# published port to the container's address on an IPv6-enabled network
# ahead of an IPv4-only one, whatever the gateway priority, so the shipped
# default network is dual-stack and cyfr's gw_priority on it decides;
# without both, the port answers nothing here.
islands_first() {
  local network
  for network in $(compose config --format json | python3 -I -c '
import json, sys
project = json.load(sys.stdin)
cyfr = project["services"]["cyfr"]
print(" ".join(name for name in cyfr["networks"]
               if name != sys.argv[1] and not (project["networks"].get(name) or {}).get("ipam")))' "$(table endpoint_network)"); do
    docker network inspect "${RUN}_${network}" >/dev/null 2>&1 && continue
    docker network create --ipv6 --label "com.docker.compose.project=$RUN" --label "com.docker.compose.network=$network" \
      --label "com.docker.compose.version=$(docker compose version --short)" "${RUN}_${network}" >/dev/null
    ok "created ${RUN}_${network} first, with IPv6"
  done
}

# ---------------------------------------------------------------------------
# bind
# ---------------------------------------------------------------------------

# The host's own non-loopback IPv4 address, on an interface that is no
# Docker bridge, or nothing.
host_address() {
  ip -4 -o addr show scope global 2>/dev/null |
    awk '$2 !~ /^(docker|br-|veth)/ { split($4, a, "/"); print a[1]; exit }'
}

# The ports the shipped file publishes in mode `$1`, as `docker compose
# config` resolves docker-compose.yml alone with the mode's profile:
# `service host_ip:published:target/protocol` lines, sorted.
shipped_ports() {
  local profile=()
  case "$1" in public | tailnet) profile=(--profile "$1") ;; esac
  (cd "$WORK" && docker compose --project-name "$RUN-shipped" -f "$WORK/docker-compose.yml" ${profile[@]+"${profile[@]}"} config --format json) |
    python3 -I -c '
import json, sys
for name, s in sorted(json.load(sys.stdin)["services"].items()):
    for p in s.get("ports", []):
        print("%s %s:%s:%s/%s" % (name, p.get("host_ip", ""), p.get("published", ""), p["target"], p.get("protocol", "tcp")))' | sort
}

bind_checks() {
  local mode="$1" config endpoint_address endpoint_network proxy_address host_api_address host_api_port runtime_network
  local port pport bound answer network gateway address front hostip
  config="$(compose config --format json)"
  endpoint_address="$(expected "endpoint address in the role table" table endpoint_address)" || exit 1
  endpoint_network="$(expected "endpoint network in the role table" table endpoint_network)" || exit 1
  read -r proxy_address host_api_address host_api_port runtime_network <<<"$(printf '%s' "$config" | python3 -I -c '
import json, sys
cyfr = json.load(sys.stdin)["services"]["cyfr"]
env = cyfr["environment"]
fixed = [(name, net["ipv4_address"]) for name, net in cyfr["networks"].items() if net and net.get("ipv4_address")]
runtime = [name for name, address in fixed if address == env["CYFR_HOST_API_BIND"]]
edge = [address for name, address in fixed if name == "edge"]
assert edge and edge[0] == env["CYFR_PROXY_BIND_ADDRESS"], (edge, env["CYFR_PROXY_BIND_ADDRESS"])
print(env["CYFR_PROXY_BIND_ADDRESS"], env["CYFR_HOST_API_BIND"], env["CYFR_HOST_API_PORT"], runtime[0])
')" || fail "compose does not bind cyfr's proxy listener to its edge address"
  [ "$(printf '%s' "$config" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["cyfr"]["environment"]["CYFR_BIND_ADDRESS"])')" = "$endpoint_address" ] ||
    fail "compose binds the loopback listener elsewhere than the table's $endpoint_address"
  port="$(env_value CYFR_PORT)"
  pport="$(proxy_port)"

  step "$mode: cyfr holds its fixed addresses"
  for pair in "$endpoint_network=$endpoint_address" "edge=$proxy_address" "$runtime_network=$host_api_address"; do
    address="$(docker inspect "$cyfr_id" --format "{{(index .NetworkSettings.Networks \"${RUN}_${pair%%=*}\").IPAddress}}")"
    [ "$address" = "${pair#*=}" ] || fail "cyfr's ${pair%%=*} address is $address, not ${pair#*=}"
  done
  ok "cyfr is $endpoint_address on $endpoint_network, $proxy_address on edge and $host_api_address on $runtime_network"

  step "$mode: each listener binds its fixed address alone"
  bound="$(listening "$cyfr_id" "$port")"
  [ "$bound" = "$endpoint_address" ] || fail "the loopback listener listens on '$bound', not on $endpoint_address alone"
  ok "the loopback listener listens on $bound:$port alone"
  bound="$(listening "$cyfr_id" "$pport")"
  if [ "$mode" = local ]; then
    [ -z "$bound" ] || fail "in local a proxy listener listens on $bound:$pport"
    ok "in local no proxy listener listens on port $pport"
  else
    [ "$bound" = "$proxy_address" ] || fail "the proxy listener listens on '$bound', not on $proxy_address alone"
    ok "the proxy listener listens on $bound:$pport alone"
  fi
  bound="$(listening "$cyfr_id" "$host_api_port")"
  [ "$bound" = "$host_api_address" ] || fail "the host API listens on '$bound', not on $host_api_address alone"
  ok "the host API listens on $bound alone"

  step "$mode: the ports published, by docker port, and the shipped file's"
  printf '%s\n' "$(docker inspect "$cyfr_id" --format '{{json .NetworkSettings.Ports}}')" | python3 -I -c '
import json, sys
ports, port, published = json.load(sys.stdin), sys.argv[1], sys.argv[2]
bound = {k: v for k, v in ports.items() if v}
host_ip, host_port = published.rsplit(":", 1)
assert list(bound) == [f"{port}/tcp"], bound
assert all(b["HostIp"] == "127.0.0.1" for b in bound[f"{port}/tcp"]), bound
assert any(b["HostPort"] == host_port for b in bound[f"{port}/tcp"]), (bound, published)
' "$port" "$(published)" || fail "cyfr publishes other than its loopback listener on the host's loopback: $(docker port "$cyfr_id")"
  for id in $(docker ps -q --no-trunc --filter "label=com.docker.compose.project=$RUN"); do
    [ "$id" = "$cyfr_id" ] && continue
    service="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id")"
    answer="$(docker port "$id" || true)"
    case "$service" in
      caddy)
        [ "$(printf '%s\n' "$answer" | sed 's/:[0-9]*$//')" = "80/tcp -> 127.0.0.1" ] ||
          fail "caddy publishes '$answer', not the overlay's loopback port 80 alone"
        ;;
      *) [ -z "$answer" ] || fail "$service publishes $answer" ;;
    esac
  done
  ok "docker port: cyfr publishes $port on 127.0.0.1 alone$([ "$mode" = public ] && echo ", caddy port 80 on 127.0.0.1")$([ "$mode" = tailnet ] && echo ", tailscale nothing")"
  answer="$(shipped_ports "$mode")"
  case "$mode" in
    public) expected="$(printf '%s\n' "caddy :443:443/tcp" "caddy :443:443/udp" "caddy :80:80/tcp" "cyfr 127.0.0.1:$port:$port/tcp" | sort)" ;;
    *) expected="cyfr 127.0.0.1:$port:$port/tcp" ;;
  esac
  [ "$answer" = "$expected" ] || fail "the shipped file publishes in $mode: $(printf '%s' "$answer" | tr '\n' ';'), not $(printf '%s' "$expected" | tr '\n' ';')"
  ok "the shipped file publishes in $mode: $(printf '%s' "$answer" | tr '\n' ';')"

  step "$mode: the loopback listener answers the host's loopback, and nothing else"
  curl -fsS -m 10 "http://$(published)/api/health/ready" >"$WORK/ready.json" || fail "GET http://$(published)/api/health/ready did not answer 200"
  ok "GET http://$(published)/api/health/ready -> 200 $(cat "$WORK/ready.json")"
  curl -fsS -m 10 "http://$(published)/api/health" >"$WORK/health.json" || fail "GET http://$(published)/api/health did not answer 200"
  ok "GET http://$(published)/api/health -> 200 $(cat "$WORK/health.json")"
  answer="$(from_network edge "http://$endpoint_address:$port/api/health")"
  case "$(status_of "$answer")" in refused | "error 28") ;; *) fail "the loopback listener answered '$(status_of "$answer")' to a container on the edge network" ;; esac
  answer="$(from_network edge "http://cyfr:$port/api/health")"
  [ "$(status_of "$answer")" = refused ] || fail "cyfr's edge address answered '$(status_of "$answer")' on the loopback listener's port"
  ok "a container on the edge network reaches no loopback listener, at its address or at cyfr's edge address"
  gateway="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | awk '{print $1}')"
  answer="$(from_network bridge "http://$endpoint_address:$port/api/health")"
  case "$(status_of "$answer")" in refused | "error 28") ;; *) fail "the loopback listener answered '$(status_of "$answer")' to a container on Docker's default bridge" ;; esac
  answer="$(from_network bridge "http://$gateway:$(published | sed 's/.*://')/api/health")"
  case "$(status_of "$answer")" in refused | "error 28") ;; *) fail "the published port answered '$(status_of "$answer")' at the bridge's gateway $gateway" ;; esac
  ok "a container on Docker's default bridge reaches it neither at its address nor at the published port"
  hostip="$(host_address)"
  if [ -n "$hostip" ]; then
    answer="$(curl -sS -o /dev/null -w '%{http_code}' -m 5 "http://$hostip:$(published | sed 's/.*://')/api/health" 2>&1)" && status=0 || status=$?
    [ "$status" -eq 7 ] || fail "the published port answered '$answer' (curl $status) at the host's address $hostip"
    ok "the host's address $hostip refuses the published port"
  else
    fail "this host has no non-loopback IPv4 address outside Docker's bridges to ask"
  fi

  step "$mode: the proxy listener, from the edge network, and through the proxy"
  answer="$(from_network edge "http://cyfr:$pport/api/health")"
  if [ "$mode" = local ]; then
    [ "$(status_of "$answer")" = refused ] || fail "in local the proxy listener's port answered '$(status_of "$answer")' from the edge network"
    ok "in local nothing answers the edge network on port $pport"
  else
    [ "$(status_of "$answer")" = 200 ] || fail "the proxy listener answered '$(status_of "$answer")' to the edge network, not 200"
    ok "the proxy listener answers the edge network: 200"
  fi
  case "$mode" in
    public)
      # The shipped site answers its host's name alone.
      front="$(compose port caddy 80)"
      curl -fsS -m 10 -H "host: $(env_value CYFR_HOST)" "http://$front/api/health/ready" >"$WORK/caddy-ready.json" ||
        fail "GET http://$front/api/health/ready as $(env_value CYFR_HOST) through Caddy did not answer 200"
      ok "GET http://$front/api/health/ready as $(env_value CYFR_HOST) through Caddy -> 200 $(cat "$WORK/caddy-ready.json")"
      ;;
    tailnet)
      standin_ca
      answer="$(fetched "$(tailnet_fetch "https://$(env_value CYFR_HOST)/api/health/ready")")"
      [ "$(jget "$answer" status)" = 200 ] || fail "readiness through Serve at $(env_value CYFR_HOST) answered: $answer"
      ok "GET https://$(env_value CYFR_HOST)/api/health/ready through Serve -> 200"
      ;;
  esac

  step "$mode: no Locus network reaches the loopback listener; the runtime's network reaches the host API"
  for network in $(printf '%s' "$config" | python3 -I -c '
import json, sys
cyfr = json.load(sys.stdin)["services"]["cyfr"]
print(" ".join(name for name in cyfr["networks"] if name not in (sys.argv[1], "edge")))' "$endpoint_network"); do
    answer="$(from_network "$network" "http://cyfr:$port/api/health")"
    [ "$(status_of "$answer")" = refused ] || fail "the loopback listener answered '$(status_of "$answer")' to a container on the $network network"
    ok "the loopback listener refuses a container on the $network network"
  done
  answer="$(from_network "$runtime_network" "http://$host_api_address:$host_api_port/")"
  case "$(status_of "$answer")" in
    [0-9][0-9][0-9]) ok "the host API answers $(status_of "$answer") to a container on the $runtime_network network" ;;
    *) fail "the host API answered '$(status_of "$answer")' to a container on the $runtime_network network" ;;
  esac
}

bind_case() {
  local mode name
  for mode in local tailnet public; do
    step "bind: $mode, switched with the stack stopped, then cyfr up"
    case "$mode" in
      local) ;;
      tailnet)
        cli_ok down down
        cli_ok reach-tailnet reach tailnet --tailscale-auth-key-file "$AUTH_KEY_FILE" --yes
        ;;
      public)
        cli_ok down down
        cli_ok reach-public reach public --domain proof-home.example --yes
        ;;
    esac
    islands_first
    cli_ok "up-$mode" up
    case "$mode" in
      local) expect_head local localhost ;;
      tailnet)
        name="$(node_name)"
        [[ "$name" == *.proof.ts.net ]] || fail "the joined node's name is ${name:-none}"
        expect_head tailnet "$name"
        expect_serve_open "$name"
        ;;
      public) expect_head public proof-home.example ;;
    esac
    bind_checks "$mode"
  done
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

# The person modes signs in, and the MCP protocol version /mcp speaks.
sign_in() {
  local signed_in token
  signed_in="$(cyfr_fixture person operator@example.com compose-proof-modes)"
  token="$(jget "$signed_in" token)"
  [ -n "$token" ] && [ "$token" != null ] || fail "the release fixture signed nobody in: '$signed_in'"
  # The person's athanor, by the route segment its pages are under.
  SEGMENT="$(jget "$signed_in" segment)"
  [ -n "$SEGMENT" ] && [ "$SEGMENT" != null ] || fail "the release fixture named no athanor for the person: '$signed_in'"
  (umask 077 && printf '%s\n' "$token" >"$WORK/session.token" && printf 'authorization: Bearer %s\n' "$token" >"$WORK/session.headers")
  MCP_VERSION="$(cyfr_rpc 'IO.puts("VERSION=" <> Prima.MCP.Protocol.version())' | sed -n 's/^VERSION=//p')"
  [ -n "$MCP_VERSION" ] || fail "cyfr named no MCP protocol version"
  docker cp "$ROOT/tests/browser/session.exs" "$cyfr_id:/tmp/session.exs" >/dev/null
  COOKIE="$(cyfr_rpc "{answer, _} = Code.eval_file(\"/tmp/session.exs\"); IO.puts(answer.([\"$token\"]))" | sed -n 's/^COOKIE=//p' | tail -1)"
  [ -n "$COOKIE" ] || fail "the release minted no session cookie"
  (umask 077 && printf 'cookie: _cyfr_key=%s\n' "$COOKIE" >"$WORK/cookie.headers")
  ok "operator@example.com is signed in; /mcp speaks $MCP_VERSION"
}

# Forged forwarding and identity headers change neither the answer nor
# the address cyfr resolves, for the probe `$2` (a request that takes a
# mark and extra headers) on the path named `$1`: the address is not the
# forged one, and the same with the forged headers as without.
FORGED_FOR=203.0.113.9
forged() {
  local what="$1" ask="$2" plain forged_answer m1 m2 got
  m1="$(mark)" m2="$(mark)"
  plain="$("$ask" "$m1")"
  forged_answer="$("$ask" "$m2" "X-Forwarded-For: $FORGED_FOR" "Tailscale-User-Login: admin@evil.example" "Tailscale-User-Name: Forged")"
  same_answer "$what" "$plain" "$forged_answer"
  got="$(resolved "$m2")"
  [ -n "$got" ] || fail "$what: cyfr recorded no client address for the request"
  [ "$got" != "$FORGED_FOR" ] || fail "$what: cyfr resolved the forged X-Forwarded-For $FORGED_FOR"
  [ "$(resolved "$m1")" = "$got" ] || fail "$what: the address cyfr resolved changed with forged headers: $(resolved "$m1") and $got"
  ok "$what: forged X-Forwarded-For and Tailscale-User-* change nothing; cyfr resolves the peer, $got"
}

# The probe answers `$2` and `$3` of `$1` are both the person's tools/list
# answered (200), and the same: a probe that failed is no answer.
same_answer() {
  local what="$1" a b
  a="$(answer_of "$2")" || fail "$what: the plain probe got no answer: $(printf '%s' "$2" | tail -n 5)"
  b="$(answer_of "$3")" || fail "$what: the forged probe got no answer: $(printf '%s' "$3" | tail -n 5)"
  [ "${a%% *}" = 200 ] || fail "$what: the plain request answered ${a%% *}, not 200"
  [ "$a" = "$b" ] || fail "$what: forged headers changed the answer from $a to $b"
}

# A request's answer as the authority it got: the status and a digest of
# the body.
answer_of() {
  printf '%s\n' "$1" | python3 -I -c '
import hashlib, json, sys
text = sys.stdin.read().replace("\r", "")
lines = text.splitlines()
status = [l[len("STATUS="):] for l in lines if l.startswith("STATUS=")]
if not status:
    answer = json.loads([l for l in lines if l.startswith("{")][-1])
    print(answer.get("status", answer.get("error")), hashlib.sha256(answer.get("body", "").encode()).hexdigest()[:16])
    sys.exit(0)
body = text.split("\n\n", 1)[1].rsplit("STATUS=", 1)[0] if "\n\n" in text else ""
print(status[-1], hashlib.sha256(body.strip().encode()).hexdigest()[:16])'
}

# The MCP request every authority probe sends: the person's tools/list.
mcp_list_body() { mcp_body tools/list '{}' "$MCP_VERSION"; }

# Probes, each `$1` the mark and `$2...` extra headers.
probe_loopback() {
  local m="$1" args=() h
  shift
  for h in "$@"; do args+=(-H "$h"); done
  curl -sS -o "$WORK/probe.body" -D "$WORK/probe.head" -w 'STATUS=%{http_code}' -m 10 \
    -H "x-proof-mark: $m" -H @"$WORK/session.headers" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -H "mcp-protocol-version: $MCP_VERSION" -H 'mcp-method: tools/list' \
    ${args[@]+"${args[@]}"} --data-binary "$(mcp_list_body)" "http://$(published)/mcp" >"$WORK/probe.status" || true
  printf '%s\n\n%s\n%s\n' "$(cat "$WORK/probe.head")" "$(cat "$WORK/probe.body")" "$(cat "$WORK/probe.status")"
}
probe_edge() {
  local m="$1" args=() h
  shift
  for h in "$@"; do args+=(-H "$h"); done
  from_network edge -H "x-proof-mark: $m" -H "authorization: Bearer $(cat "$WORK/session.token")" -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' -H "mcp-protocol-version: $MCP_VERSION" -H 'mcp-method: tools/list' \
    ${args[@]+"${args[@]}"} --data-binary "$(mcp_list_body)" "http://cyfr:$PROBE_PORT/mcp"
}
probe_caddy() {
  local m="$1" args=() h
  shift
  for h in "$@"; do args+=(-H "$h"); done
  from_network edge -H "x-proof-mark: $m" -H "host: $(env_value CYFR_HOST)" -H "authorization: Bearer $(cat "$WORK/session.token")" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "mcp-protocol-version: $MCP_VERSION" \
    -H 'mcp-method: tools/list' ${args[@]+"${args[@]}"} --data-binary "$(mcp_list_body)" "http://caddy:80/mcp"
}
probe_serve() {
  local m="$1" args=() h
  shift
  for h in "$@"; do args+=(--header "$h"); done
  tailnet_fetch --method POST --header "x-proof-mark: $m" --header "authorization: Bearer $(cat "$WORK/session.token")" \
    --header 'content-type: application/json' --header 'accept: application/json, text/event-stream' \
    --header "mcp-protocol-version: $MCP_VERSION" --header 'mcp-method: tools/list' --body "$(mcp_list_body)" \
    ${args[@]+"${args[@]}"} "https://$(env_value CYFR_HOST)/mcp"
}

# The forged-header checks of mode `$1`, on both listeners and through its
# proxy.
forged_checks() {
  local mode="$1"
  probe_attach
  PROBE_PORT="$(proxy_port)"
  forged "$mode, the loopback listener" probe_loopback
  # Each probe from a container runs a container of its own, whose address
  # its answer names (IP=).
  forged_peer "$mode, the proxy listener from an untrusted peer on edge" probe_edge
  case "$mode" in
    public)
      forged_peer "$mode, through Caddy" probe_caddy
      anonymous_pairs "$mode, through Caddy" anonymous_caddy
      ;;
    tailnet)
      forged_peer "$mode, through Serve" probe_serve
      anonymous_pairs "$mode, through Serve" anonymous_serve
      ;;
  esac
}

# Every forwarding and identity header a client could squat, each with an
# attacker's value: the identity headers the pinned serve.go deletes or
# sets, and the forwarding headers a proxy replaces.
FORGED_IDENTITY=(
  "X-Forwarded-For: 203.0.113.9" "X-Forwarded-Proto: https" "X-Forwarded-Host: evil.example"
  "Forwarded: for=198.51.100.1" "Tailscale-User-Login: operator@example.com" "Tailscale-User-Name: Operator"
  "Tailscale-User-Profile-Pic: https://evil.example/p.png" "Tailscale-Funnel-Request: ?1"
  "Tailscale-Headers-Info: https://evil.example/info" 'Tailscale-App-Capabilities: {"evil.example/cap":[{}]}'
)

# Anonymous requests through mode `$1`'s proxy, the probe `$2` (`$2 mcp|page
# REQUEST [header...]`, REQUEST the JSON-RPC body of an mcp request):
# MCP's subscriptions/listen, which opens a stream to an authenticated
# caller alone (tools/list is discovery, which an anonymous caller is
# answered), and the home's root page, each with no credential, and each
# again with every header FORGED_IDENTITY names, the person's own login
# among them; each, with the headers and without, must be refused exactly
# as the home refuses an anonymous request of its kind (predicates.sh
# `anonymous_refused`: the page to /login, MCP's 401 with the auth error
# for that request), so no forged identity header authenticates anyone.
anonymous_pairs() {
  local what="$1" ask="$2" kind request plain forged_answer why
  for kind in mcp page; do
    request=""
    [ "$kind" != mcp ] || request="$(mcp_body subscriptions/listen '{}' "$MCP_VERSION")"
    plain="$("$ask" "$kind" "$request")"
    forged_answer="$("$ask" "$kind" "$request" "${FORGED_IDENTITY[@]}")"
    why="$(anonymous_refused "$kind" "$plain" "$forged_answer" "$request")" || fail "$what, an anonymous $kind request: $why"
  done
  ok "$what: an anonymous MCP request is refused 401 with the auth error and a page request sent to /login, with forged identity headers as without"
}
anonymous_caddy() {
  local kind="$1" request="$2" args=() h
  shift 2
  for h in "$@"; do args+=(-H "$h"); done
  case "$kind" in
    mcp)
      from_network edge -H "host: $(env_value CYFR_HOST)" -H 'content-type: application/json' \
        -H 'accept: application/json, text/event-stream' -H "mcp-protocol-version: $MCP_VERSION" -H 'mcp-method: subscriptions/listen' \
        ${args[@]+"${args[@]}"} --data-binary "$request" "http://caddy:80/mcp"
      ;;
    page) from_network edge -H "host: $(env_value CYFR_HOST)" ${args[@]+"${args[@]}"} "http://caddy:80/" ;;
  esac
}
anonymous_serve() {
  local kind="$1" request="$2" args=() h
  shift 2
  for h in "$@"; do args+=(--header "$h"); done
  case "$kind" in
    mcp)
      tailnet_fetch --method POST --header 'content-type: application/json' --header 'accept: application/json, text/event-stream' \
        --header "mcp-protocol-version: $MCP_VERSION" --header 'mcp-method: subscriptions/listen' --body "$request" \
        ${args[@]+"${args[@]}"} "https://$(env_value CYFR_HOST)/mcp"
      ;;
    page) tailnet_fetch ${args[@]+"${args[@]}"} "https://$(env_value CYFR_HOST)/" ;;
  esac
}

# As forged, the address cyfr must resolve the client's own, which the
# probe's answer names (IP=).
forged_peer() {
  local what="$1" ask="$2" m1 m2 plain forged_answer got client plain_client
  m1="$(mark)" m2="$(mark)"
  plain="$("$ask" "$m1")"
  forged_answer="$("$ask" "$m2" "X-Forwarded-For: $FORGED_FOR" "Tailscale-User-Login: admin@evil.example" "Tailscale-User-Name: Forged")"
  client="$(expected "client address of the forged probe" ip_of "$forged_answer")" || exit 1
  plain_client="$(expected "client address of the plain probe" ip_of "$plain")" || exit 1
  same_answer "$what" "$plain" "$forged_answer"
  got="$(resolved "$m2")"
  [ "$got" = "$client" ] || fail "$what: cyfr resolved '${got:-nothing}', not the client's $client"
  [ "$(resolved "$m1")" = "$plain_client" ] || fail "$what: cyfr resolved '$(resolved "$m1")' for the plain request, not its client $plain_client"
  ok "$what: forged X-Forwarded-For and Tailscale-User-* change nothing; cyfr resolves the client, $got"
}

# Tailnet's HSTS: the endpoint's value on the proxy listener's answers for
# the node's name, success, error and refusal alike, and none for a
# loopback Host or on the loopback listener.
hsts_checks() {
  local name answer values
  name="$(env_value CYFR_HOST)"
  for path in /api/health /proof-no-such-route; do
    answer="$(fetched "$(tailnet_fetch "https://$name$path")")"
    values="$(hsts_of "$answer")"
    [ "$values" = "$HSTS" ] || fail "through Serve, $name$path ($(jget "$answer" status)) carries Strict-Transport-Security '${values:-none}', not the endpoint's '$HSTS' once"
    ok "through Serve, $path answers $(jget "$answer" status) with the endpoint's HSTS"
  done
  # A credential cyfr refuses before it reads the request: 401, with its
  # challenge.
  answer="$(fetched "$(tailnet_fetch --method POST --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' --header "mcp-protocol-version: $MCP_VERSION" \
    --header 'authorization: Bearer proof-refused-credential' \
    --header 'mcp-method: tools/list' --body "$(mcp_list_body)" "https://$name/mcp")")"
  [ "$(jget "$answer" status)" = 401 ] || fail "a POST /mcp with a refused credential through Serve answered $(jget "$answer" status), not 401"
  [ "$(hsts_of "$answer")" = "$HSTS" ] || fail "the refusal through Serve carries Strict-Transport-Security '$(hsts_of "$answer")'"
  ok "through Serve, a refused POST /mcp answers 401 with the endpoint's HSTS"
  for host in localhost 127.0.0.1 LocalHost; do
    answer="$(fetched "$(tailnet_fetch --host "$host" "https://$name/api/health")")"
    [ "$(jget "$answer" status)" = 200 ] || fail "through Serve with Host $host, /api/health answered '${answer:-nothing}', not 200"
    [ -z "$(hsts_of "$answer")" ] || fail "through Serve with Host $host, the answer carries Strict-Transport-Security"
  done
  ok "through Serve with a loopback Host (localhost, 127.0.0.1, LocalHost), 200 and no HSTS"
  answer="$(from_network edge -H "host: $name" "http://cyfr:$(proxy_port)/api/health")"
  [ "$(hsts_in "$answer")" = "$HSTS" ] || fail "the proxy listener from edge, as $name, carries Strict-Transport-Security '$(hsts_in "$answer")'"
  answer="$(from_network edge -H "host: localhost" "http://cyfr:$(proxy_port)/api/health")"
  [ "$(status_of "$answer")" = 200 ] || fail "the proxy listener from edge, as localhost, answered '$(status_of "$answer")', not 200"
  [ -z "$(hsts_in "$answer")" ] || fail "the proxy listener from edge, as localhost, carries Strict-Transport-Security"
  ok "the proxy listener itself: HSTS for $name, 200 and none for localhost"
  local code
  for host in "$name" localhost; do
    rm -f "$WORK/lo.head"
    code="$(curl -sS -o /dev/null -D "$WORK/lo.head" -w '%{http_code}' -m 10 -H "host: $host" "http://$(published)/api/health")" ||
      fail "the loopback listener, as $host, gave no answer"
    [ "$code" = 200 ] || fail "the loopback listener, as $host, answered $code, not 200"
    [ -z "$(hsts_in "$(cat "$WORK/lo.head")")" ] || fail "the loopback listener, as $host, carries Strict-Transport-Security"
  done
  ok "the loopback listener answers 200 with no HSTS, as $name or localhost"
}

# The home at its ts.net name: the origin, MCP, the LiveView socket and
# the session cookie.
tsnet_checks() {
  local name origin answer signed unsigned key why
  name="$(env_value CYFR_HOST)"
  origin="$(cyfr_rpc 'IO.puts("ORIGIN=" <> Sanctum.origin())' | sed -n 's/^ORIGIN=//p' | tail -1)"
  [ "$origin" = "https://$name" ] || fail "Sanctum.origin() is '$origin', not https://$name"
  ok "the home's origin is https://$name"
  answer="$(fetched "$(probe_serve "$(mark)" "origin: https://$name")")"
  [ "$(jget "$answer" status)" = 200 ] || fail "MCP at https://$name refused its own origin: $answer"
  answer="$(fetched "$(probe_serve "$(mark)" "origin: https://evil.example")")"
  [ "$(jget "$answer" status)" = 403 ] || fail "MCP at https://$name admitted the origin https://evil.example: $(jget "$answer" status)"
  ok "MCP at https://$name admits its own origin (200) and refuses another (403)"
  key="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | python3 -I -c 'import base64, sys; print(base64.b64encode(bytes.fromhex(sys.stdin.read().strip())).decode())')"
  for o in "https://$name=101" "https://evil.example=403"; do
    answer="$(fetched "$(tailnet_fetch --header "origin: ${o%=*}" --header 'connection: Upgrade' --header 'upgrade: websocket' \
      --header 'sec-websocket-version: 13' --header "sec-websocket-key: $key" "https://$name/live/websocket?vsn=2.0.0")")"
    [ "$(jget "$answer" status)" = "${o##*=}" ] || fail "the LiveView socket at https://$name with Origin ${o%=*} answered $(jget "$answer" status), not ${o##*=}"
  done
  ok "the LiveView socket at https://$name upgrades for its own origin (101) and refuses another (403)"
  unsigned="$(fetched "$(tailnet_fetch "https://$name/")")"
  signed="$(fetched "$(tailnet_fetch --header "cookie: _cyfr_key=$COOKIE" "https://$name/")")"
  why="$(cookie_holds "$unsigned" "$signed" "$SEGMENT")" || fail "at https://$name the session cookie is not the fixture person's: $why"
  ok "the session cookie is honoured at https://$name: without it / sends to /login, with it to $SEGMENT's chat"
}

# `cyfr up` refused before anything starts: the stack is down, the
# command line answers non-zero with refusal `$2` (its slots `$3...`),
# and still nothing of the project runs. `$1` names the case.
refused_before_start() {
  local what="$1" code="$2" status=0
  shift 2
  cli_run "refused-up" up || status=$?
  [ "$status" -ne 0 ] || fail "$what: cyfr up started the stack"
  sentence "$code" "$WORK/refused-up.log" "$@" >/dev/null ||
    fail "$what: cyfr up did not say $code's sentence: $(tail -n 10 "$WORK/refused-up.log")"
  [ -z "$(running)" ] || fail "$what: the project runs '$(running)' after the refusal"
  ok "$what: cyfr up refuses with $code's sentence, and nothing runs"
}

modes_case() {
  local m sentence_text name
  step "modes: a local home, builds off, up"
  cli_ok up-local up
  expect_head local localhost
  sign_in

  step "modes: COMPOSE_PROFILES=public,tailnet in the command line's environment starts neither proxy"
  cli_ok down down
  [ -z "$(running)" ] || fail "cyfr down left '$(running)' running"
  cli_ok up-profiles COMPOSE_PROFILES=public,tailnet up
  expect_head local localhost
  ok "with COMPOSE_PROFILES=public,tailnet in its environment, cyfr up started cyfr alone"

  step "modes: what cyfr up refuses before anything starts"
  cli_ok down down
  env_set COMPOSE_PROFILES public,tailnet
  refused_before_start "COMPOSE_PROFILES in .env" compose_env_refused key=COMPOSE_PROFILES
  env_set COMPOSE_PROFILES
  env_set CYFR_HOST cyfr.example.com
  refused_before_start "a local .env naming another host" reach_local_mismatch key=CYFR_HOST value=cyfr.example.com
  sentence_text="$(expected "boot sentence 'local with a host'" boot_sentence 'local with a host')" || exit 1
  grep -qF -- "$sentence_text" "$WORK/refused-up.log" || fail "cyfr up's sentence is not the boot's own"
  env_set CYFR_HOST localhost
  cp "$WORK/.env" "$WORK/.env.with-mode"
  env_set CYFR_REACH
  refused_before_start "a .env with no mode" reach_missing
  sentence_text="$(expected "boot sentence 'a release with the mode unset'" boot_sentence 'a release with the mode unset')" || exit 1
  grep -qF -- "$sentence_text" "$WORK/refused-up.log" || fail "cyfr up's sentence is not the boot's own"
  cp "$WORK/.env.with-mode" "$WORK/.env"

  step "modes: up again, then every ordered pair of the three modes, running"
  cli_ok up-again up
  expect_head local localhost
  # local -> public -> tailnet -> local -> tailnet -> public -> local
  for m in public tailnet local tailnet public local; do
    step "modes: switch to $m"
    case "$m" in
      local) cli_ok "to-$m" reach local --yes ;;
      public) cli_ok "to-$m" reach public --domain proof-home.example --yes ;;
      tailnet)
        if [ -z "${JOINED:-}" ]; then
          tailnet_join "to-$m" "--yes" || fail "cyfr reach tailnet, approved, exited non-zero: $(tail -n 20 "$WORK/to-$m.log")"
          JOINED="$(env_value CYFR_TAILNET_NODE_ID)"
        else
          cli_ok "to-$m" reach tailnet --yes
          [ "$(env_value CYFR_TAILNET_NODE_ID)" = "$JOINED" ] ||
            fail "the second switch to tailnet named the node $(env_value CYFR_TAILNET_NODE_ID), not the machine already joined, $JOINED"
        fi
        ;;
    esac
    case "$m" in
      local)
        expect_head local localhost
        ;;
      public)
        expect_head public proof-home.example
        forged_checks public
        answer="$(from_network edge -H "host: proof-home.example" "http://cyfr:$(proxy_port)/api/health")"
        [ "$(status_of "$answer")" = 200 ] && [ -z "$(hsts_in "$answer")" ] ||
          fail "in public the proxy listener as proof-home.example answered '$(status_of "$answer")' with Strict-Transport-Security '$(hsts_in "$answer")'"
        answer="$(from_network edge -H "host: proof-home.example" "http://caddy:80/api/health")"
        [ "$(hsts_in "$answer")" = "$HSTS" ] || fail "through Caddy the answer carries Strict-Transport-Security '$(hsts_in "$answer" | tr '\n' ';')', not the shipped site's '$HSTS' once"
        ok "in public the endpoint sends no HSTS of its own, and through Caddy the answer carries the shipped site's one value"
        ;;
      tailnet)
        name="$(node_name)"
        expect_head tailnet "$name"
        expect_serve_open "$name"
        standin_ca
        forged_checks tailnet
        hsts_checks
        tsnet_checks
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# interrupt
# ---------------------------------------------------------------------------

FAULTS="$WORK/faults"

# A docker on the command line's PATH ahead of the real one: it runs every
# call as the real one does, except that while $FAULTS/pause-up exists the
# first compose call that starts services (`up`) stops itself before it
# runs, writing its pid to $FAULTS/paused, and $FAULTS/pause-stop does the
# same for the first call that stops or removes them (`stop`, `rm`,
# `down`, `kill`, through compose or not); while $FAULTS/fail-stop
# exists every such call fails without running; and $FAULTS/fail-up makes
# the first such `up` fail once it has run, every stop after it failing.
shim_install() {
  mkdir -p "$WORK/shim" "$FAULTS"
  cat >"$WORK/shim/docker" <<SH
#!/usr/bin/env bash
stops() { printf '%s\n' "\$@" | grep -qxE 'stop|rm|down|kill'; }
pause() {
  mv "$FAULTS/pause-\$1" "$FAULTS/pausing.\$\$" 2>/dev/null || return 0
  echo "\$\$" >"$FAULTS/paused"
  kill -STOP "\$\$"
}
if [ "\${1:-}" = compose ] && printf '%s\n' "\$@" | grep -qx up; then
  pause up
  if mv "$FAULTS/fail-up" "$FAULTS/failing.\$\$" 2>/dev/null; then
    "$REAL_DOCKER" "\$@"
    : >"$FAULTS/fail-stop"
    echo "docker (the proof's): this up fails once it has run, as the run asked" >&2
    exit 1
  fi
fi
if stops "\$@"; then
  pause stop
  if [ -e "$FAULTS/fail-stop" ]; then
    echo "docker (the proof's): this call fails, as the run asked" >&2
    exit 1
  fi
fi
exec "$REAL_DOCKER" "\$@"
SH
  chmod +x "$WORK/shim/docker"
  CLI_PATH="$WORK/shim:$PATH"
}

# The paused docker call's pid, once it has stopped itself, within 120 s.
await_paused() {
  local closes=$((SECONDS + 120)) pid
  while [ "$SECONDS" -lt "$closes" ]; do
    pid="$(cat "$FAULTS/paused" 2>/dev/null || true)"
    if [ -n "$pid" ] && [ "$(ps -o stat= -p "$pid" 2>/dev/null | cut -c1)" = T ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.2
  done
  fail "no docker call paused within 120 s"
}

# The journal's field `$1`, or nothing when no operation is unfinished.
journal() {
  [ -f "$WORK/.cyfr/journal.json" ] || return 0
  jget "$(cat "$WORK/.cyfr/journal.json")" "$1"
}

# An uncertain operation's journal holds both its heads, and every
# materialized file it names is in the project: `$1` `some` when it must
# name one, `any` when it may name none (a stop that failed before
# anything was started from a materialized file).
uncertain_kept() {
  python3 -I - "$WORK" "$1" <<'PY' || fail "the uncertain journal does not keep what recovery reads: $(cat "$WORK/.cyfr/journal.json")"
import json, os, sys
work, need = sys.argv[1], sys.argv[2]
j = json.load(open(os.path.join(work, ".cyfr", "journal.json")))
files = j.get("files") or []
assert j.get("old_head") and j.get("new_head"), "heads"
assert need == "any" or files, "no file named"
assert all(os.path.isfile(os.path.join(work, f)) for f in files), files
PY
}

# Converged: no journal, no materialized configuration, the receipt of
# request `$1`, and one coherent head running, `$2` or `$3`'s.
converged() {
  local id="$1" mode
  [ ! -e "$WORK/.cyfr/journal.json" ] || fail "an operation is still unfinished: $(cat "$WORK/.cyfr/journal.json")"
  ! compgen -G "$WORK/.cyfr/compose.resolved.*" >/dev/null || fail "materialized configurations are left: $(ls "$WORK/.cyfr")"
  [ -f "$WORK/.cyfr/receipts/$id.json" ] || fail "no receipt of the request $id"
  [ "$(jget "$(cat "$WORK/.cyfr/receipts/$id.json")" state)" = completed ] ||
    fail "the request $id's receipt is $(cat "$WORK/.cyfr/receipts/$id.json")"
  mode="$(env_value CYFR_REACH)"
  case "$mode" in
    "$2" | "$3") ;;
    *) fail ".env's head is $mode, neither $2 nor $3" ;;
  esac
  case "$mode" in
    local) expect_head local localhost ;;
    public) expect_head public proof-home.example ;;
    tailnet) expect_head tailnet "$(node_name)" ;;
  esac
  ok "converged on $mode: a receipt ($(jget "$(cat "$WORK/.cyfr/receipts/$id.json")" outcome)), no journal and no materialized configuration"
}

# Runs, as the sentence `$1` (a refusal code) printed in `$2` says, the
# first `$3` `cyfr ...` commands it names, in turn: the steps it gives, where
# what follows is for another outcome ("if it reports the same, ..."). A
# command that switches gets `--yes`, standing for the person's confirming
# its preview; a join is approved in the stand-in as a new node,
# cyfr-1.proof.ts.net. Each must exit 0.
as_printed() {
  local code="$1" file="$2" count="$3" found cmd n=0
  found="$(sentence "$code" "$file")" || fail "$file holds no $code sentence: $(tail -n 10 "$file")"
  while IFS= read -r cmd; do
    [ "$n" -lt "$count" ] || break
    n=$((n + 1))
    # shellcheck disable=SC2086
    set -- ${cmd#cyfr }
    case "$1 ${2:-}" in "reach local" | "reach tailnet" | "reach public") set -- "$@" --yes ;; esac
    step "as the $code sentence says: cyfr $*"
    if [ "$1 ${2:-}" = "reach tailnet" ] && printf '%s\n' "$@" | grep -qx -- --new-node; then
      shift 2
      tailnet_join "printed-$n" "$*" --name cyfr-1.proof.ts.net || fail "cyfr $cmd, approved, exited non-zero: $(tail -n 20 "$WORK/printed-$n.log")"
    else
      cli_ok "printed-$n" "$@"
    fi
  done < <(jget "$found" commands | python3 -I -c 'import json, sys; print("\n".join(json.load(sys.stdin)))')
  [ "$n" -eq "$count" ] || fail "the $code sentence names $n commands, not the $count it gives as steps"
}

interrupt_case() {
  local cli job pid id status
  shim_install
  cli_ok up-local up
  expect_head local localhost

  step "interrupt: the command line killed after acceptance, before its stop runs"
  : >"$FAULTS/pause-stop"
  cli_run kill-accepted reach public --domain proof-home.example --yes &
  job=$!
  cli="$(cli_pid kill-accepted)"
  pid="$(await_paused)"
  [ "$(journal phase)" = accepted ] || fail "the paused stop's operation is in phase '$(journal phase)', not accepted"
  id="$(journal request_id)"
  # The command line, then the stop it started, so the stop never runs.
  kill -KILL "$cli"
  kill -KILL "$pid"
  wait "$job" 2>/dev/null || true
  rm -f "$FAULTS/paused"
  cli_run status-killed reach status || fail "cyfr reach status failed: $(tail -n 10 "$WORK/status-killed.log")"
  # shellcheck disable=SC2016
  grep -qF -- '`cyfr reach --resume`' "$WORK/status-killed.log" ||
    fail "cyfr reach status names no \`cyfr reach --resume\` for the interrupted change: $(tail -n 20 "$WORK/status-killed.log")"
  step "interrupt: cyfr reach --resume, as cyfr reach status says"
  cli_ok resume-killed reach --resume
  converged "$id" local public

  step "interrupt: the command line killed alone while a docker child of its start is paused"
  [ "$(env_value CYFR_REACH)" = local ] || cli_ok back-local reach local --yes
  : >"$FAULTS/pause-up"
  cli_run kill-start reach public --domain proof-home.example --yes &
  job=$!
  cli="$(cli_pid kill-start)"
  pid="$(await_paused)"
  id="$(journal request_id)"
  [ -n "$id" ] || fail "no operation is unfinished while its start is paused"
  [ "$(env_value CYFR_REACH)" = public ] || fail "the start paused before .env was committed to public"
  # The command line alone: the paused docker call and the watchdog that
  # started it hold the lock on.
  kill -KILL "$cli"
  wait "$job" 2>/dev/null || true
  status=0
  cli_run busy reach --resume || status=$?
  [ "$status" -ne 0 ] || fail "cyfr reach --resume took the lock while the orphaned docker call held it"
  sentence reach_busy "$WORK/busy.log" >/dev/null || fail "the next command did not say reach_busy: $(tail -n 10 "$WORK/busy.log")"
  ok "while the orphan holds the lock, the next command is refused with reach_busy"
  kill -CONT "$pid"
  local closes=$((SECONDS + 180))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$SECONDS" -lt "$closes" ] || fail "the released docker call did not end within 180 s"
    sleep 0.5
  done
  rm -f "$FAULTS/paused"
  as_printed reach_busy "$WORK/busy.log" 1
  converged "$id" local public

  step "interrupt: a stop that fails leaves the change uncertain and resumable"
  [ "$(env_value CYFR_REACH)" = public ] || cli_ok to-public reach public --domain proof-home.example --yes
  : >"$FAULTS/fail-stop"
  status=0
  cli_run uncertain reach local --yes || status=$?
  [ "$status" -ne 0 ] || fail "a switch whose stop failed exited 0"
  sentence reach_uncertain "$WORK/uncertain.log" >/dev/null || fail "the failed stop did not say reach_uncertain: $(tail -n 10 "$WORK/uncertain.log")"
  [ "$(journal phase)" = uncertain ] || fail "the failed stop's operation is in phase '$(journal phase)', not uncertain"
  id="$(journal request_id)"
  [ ! -e "$WORK/.cyfr/receipts/$id.json" ] || fail "an uncertain operation wrote its receipt"
  uncertain_kept any
  ok "uncertain: the journal stays unfinished, with its two heads and every materialized file it names, and no receipt"
  rm -f "$FAULTS/fail-stop"
  as_printed reach_uncertain "$WORK/uncertain.log" 1
  converged "$id" public local

  step "interrupt: a start that fails, then a rollback whose stop fails, leaves the change uncertain with its configuration"
  [ "$(env_value CYFR_REACH)" = public ] || cli_ok to-public-again reach public --domain proof-home.example --yes
  : >"$FAULTS/fail-up"
  status=0
  cli_run rollback-uncertain reach local --yes || status=$?
  [ "$status" -ne 0 ] || fail "a switch whose start and rollback stop failed exited 0"
  [ ! -e "$FAULTS/fail-up" ] || fail "the switch ran no compose up"
  sentence reach_uncertain "$WORK/rollback-uncertain.log" >/dev/null ||
    fail "the rollback's failed stop did not say reach_uncertain: $(tail -n 10 "$WORK/rollback-uncertain.log")"
  [ "$(journal phase)" = uncertain ] || fail "the rollback's operation is in phase '$(journal phase)', not uncertain"
  id="$(journal request_id)"
  [ ! -e "$WORK/.cyfr/receipts/$id.json" ] || fail "an uncertain rollback wrote its receipt"
  uncertain_kept some
  ok "uncertain rollback: the journal stays unfinished, with its two heads and the target's materialized configuration, and no receipt"
  rm -f "$FAULTS/fail-stop"
  as_printed reach_uncertain "$WORK/rollback-uncertain.log" 1
  converged "$id" public local

  step "interrupt: a join with HTTPS off for the tailnet, then its instruction"
  [ "$(env_value CYFR_REACH)" = local ] || cli_ok to-local reach local --yes
  status=0
  tailnet_join https-off "--new-node --yes" https-off || status=$?
  [ "$status" -ne 0 ] || fail "a join with HTTPS off switched the home"
  sentence tailnet_https_off "$WORK/https-off.log" name=cyfr.proof.ts.net >/dev/null ||
    fail "the join did not say tailnet_https_off for cyfr.proof.ts.net: $(tail -n 10 "$WORK/https-off.log")"
  expect_head local localhost
  # The console's HTTPS switch, in the tailnet the stand-in keeps on the
  # machine's volume.
  local enrolled first_id
  enrolled="$(jget "$(docker run --rm -v "${RUN}_tailscale_state:/var/lib/tailscale" "$STANDIN_IMAGE" standin state)" id)"
  [ -n "$enrolled" ] && [ "$enrolled" != null ] || fail "the stand-in's state names no machine"
  docker run --rm -v "${RUN}_tailscale_state:/var/lib/tailscale" "$STANDIN_IMAGE" standin tailnet --https on
  as_printed tailnet_https_off "$WORK/https-off.log" 1
  expect_head tailnet cyfr.proof.ts.net
  [ "$(env_value CYFR_TAILNET_NODE_ID)" = "$enrolled" ] ||
    fail "following tailnet_https_off enrolled another machine ($(env_value CYFR_TAILNET_NODE_ID)), where it says it uses this one ($enrolled) as it is"
  expect_serve_open cyfr.proof.ts.net
  first_id="$enrolled"

  step "interrupt: tailnet_active, then its instruction"
  status=0
  cli_run active reach tailnet --new-node --yes || status=$?
  [ "$status" -ne 0 ] || fail "a join while the tailnet is active ran"
  sentence tailnet_active "$WORK/active.log" name=cyfr.proof.ts.net >/dev/null ||
    fail "the join did not say tailnet_active: $(tail -n 10 "$WORK/active.log")"
  as_printed tailnet_active "$WORK/active.log" 2
  expect_head tailnet cyfr-1.proof.ts.net
  [ "$(env_value CYFR_TAILNET_NODE_ID)" != "$first_id" ] || fail "the new node kept the old node's id $first_id"
  expect_serve_open cyfr-1.proof.ts.net
  ok "the home moved to a new node, cyfr-1.proof.ts.net, as tailnet_active's instructions say"
}

# ---------------------------------------------------------------------------
# restore-identity
# ---------------------------------------------------------------------------

# A snapshot of the stopped stack into backups/<UTC timestamp>/, laid out
# as `cyfr update` lays one out for a SQLite cell on local storage
# (apps/codex/cmd/update.go takeSnapshot): the database file, the storage
# root without it, an empty scaffold part, the keyring, .env and the
# compose file, snapshot.json last. The data directory is the image's
# user's, so its parts are copied by a container of the image. Answers
# the snapshot's directory.
snapshot_take() {
  local stamp dir version
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$WORK/backups/$stamp"
  mkdir -p "$WORK/backups"
  mkdir -m 700 "$dir"
  docker run --rm --user 0 --entrypoint sh -v "$WORK:/work" "$IMAGE" -c '
    set -e
    d="/work/backups/$1"
    cp /work/data/cyfr.db "$d/database"
    if [ -s /work/data/cyfr.db-wal ]; then cp /work/data/cyfr.db-wal "$d/database-wal"; fi
    mkdir "$d/storage"
    (cd /work/data && tar -cf - --exclude=./cyfr.db --exclude=./cyfr.db-wal --exclude=./cyfr.db-shm .) | (cd "$d/storage" && tar -xf -)
    chown -R "$2" "$d"' sh "$stamp" "$(id -u):$(id -g)" || fail "the snapshot's parts could not be copied"
  mkdir -m 700 "$dir/scaffold"
  (umask 077 && printf "CYFR_SECRET_KEY_BASE='%s'\n" "$(env_value CYFR_SECRET_KEY_BASE)" >"$dir/keyring")
  cp "$WORK/.env" "$dir/.env"
  cp "$WORK/docker-compose.yml" "$dir/compose"
  version="$(sed -n 's/^ *version: "\([0-9][0-9.]*\)",$/\1/p' "$ROOT/apps/prima/mix.exs")"
  python3 -I - "$dir" "$version" <<'PY'
import datetime, json, os, sys
d, version = sys.argv[1], sys.argv[2]
parts = [p for p in ["database", "database-wal", "storage", "scaffold", "keyring", ".env", "compose"] if os.path.exists(os.path.join(d, p))]
manifest = {"version": version, "taken_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "parts": parts, "storage_adapter": "local", "scaffold": [], "complete": True}
with open(os.path.join(d, "snapshot.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
  printf '%s\n' "$dir"
}

restore_identity_case() {
  local snapshot a_id b_id status answer mismatch
  step "restore-identity: a home serving node A"
  cli_ok down-first down
  cli_ok join-a reach tailnet --tailscale-auth-key-file "$AUTH_KEY_FILE" --yes
  cli_ok up-a up
  expect_head tailnet cyfr.proof.ts.net
  expect_serve_open cyfr.proof.ts.net
  a_id="$(env_value CYFR_TAILNET_NODE_ID)"

  step "restore-identity: the snapshot of A, taken with the stack stopped"
  cli_ok down-a down
  snapshot="$(snapshot_take)"
  ok "snapshot $snapshot: $(python3 -I -c 'import json, sys; print(",".join(json.load(open(sys.argv[1]))["parts"]))' "$snapshot/snapshot.json")"

  step "restore-identity: switched to local, then joined as node B"
  cli_ok to-local reach local --yes
  tailnet_join join-b "--new-node --yes" --name cyfr-1.proof.ts.net || fail "joining B failed: $(tail -n 20 "$WORK/join-b.log")"
  cli_ok up-b up
  expect_head tailnet cyfr-1.proof.ts.net
  b_id="$(env_value CYFR_TAILNET_NODE_ID)"
  [ "$b_id" != "$a_id" ] || fail "node B has A's id"
  local receipts
  receipts="$(find "$WORK/.cyfr/receipts" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
  [ -n "$receipts" ] || fail "the switches to B left no receipt"

  step "restore-identity: cyfr restore of A"
  status=0
  cli_run_root restore restore "$snapshot" || status=$?
  # Exit 3: the home started, on this machine only.
  [ "$status" -eq 3 ] || fail "cyfr restore exited $status, not 3, the start that leaves the home on this machine only: $(tail -n 20 "$WORK/restore.log")"
  mismatch="$(expected "tailnet_node_mismatch sentence" render tailnet_node_mismatch node=cyfr-1.proof.ts.net env=cyfr.proof.ts.net)" || exit 1
  grep -qF -- "$mismatch" "$WORK/restore.log" ||
    fail "the restore's start did not say tailnet_node_mismatch's sentence for B and A: $(tail -n 20 "$WORK/restore.log")"
  [ "$(env_value CYFR_HOST)" = cyfr.proof.ts.net ] && [ "$(env_value CYFR_TAILNET_NODE_ID)" = "$a_id" ] ||
    fail "after the restore .env names $(env_value CYFR_HOST) ($(env_value CYFR_TAILNET_NODE_ID)), not A"
  await_healthy
  [ "$(serving)" = "{}" ] || fail "Serve is open after the mismatch: $(serving)"
  standin_ca
  expect_serve_closed cyfr-1.proof.ts.net
  curl -fsS -m 10 "http://$(published)/api/health/ready" >/dev/null || fail "the mismatched home does not answer on this machine"
  ok "tailnet_node_mismatch: Serve stays closed (the node refuses 443 and answers its PeerAPI), and the home answers on this machine alone"
  [ "$(jget "$(docker exec "$(compose ps -q tailscale)" tailscale status --json)" Self ID)" = "$b_id" ] ||
    fail "the state volume no longer holds node B"
  [ ! -e "$WORK/.cyfr/join.json" ] || fail "the restore left join.json: $(cat "$WORK/.cyfr/join.json")"
  for receipt in $receipts; do
    [ -f "$WORK/.cyfr/receipts/$receipt" ] || fail "the restore took the project's .cyfr/receipts/$receipt with it"
  done
  ok "the restore kept the state volume (B) and the project's .cyfr/ (its receipts), and no join.json is left"

  step "restore-identity: cyfr reach tailnet previews A's address to B's"
  cp "$WORK/.env" "$WORK/.env.restored"
  # With no terminal and no --yes, it shows the preview and changes nothing.
  status=0
  cli_run preview reach tailnet || status=$?
  [ "$status" -ne 0 ] || fail "cyfr reach tailnet with no terminal and no --yes made the change: $(tail -n 20 "$WORK/preview.log")"
  # The whole preview: A's head as .env holds it, the transition, and B's
  # head, the node the state holds (predicates.sh `preview_holds`).
  local old_head new_head why
  old_head="{\"mode\":\"tailnet\",\"host\":\"cyfr.proof.ts.net\",\"port\":4000,\"public_url\":\"https://cyfr.proof.ts.net\",\"node_id\":\"$a_id\",\"profiles\":[\"tailnet\"]}"
  new_head="{\"mode\":\"tailnet\",\"host\":\"cyfr-1.proof.ts.net\",\"port\":4000,\"public_url\":\"https://cyfr-1.proof.ts.net\",\"node_id\":\"$b_id\",\"profiles\":[\"tailnet\"]}"
  # The state holds B by design, as the mismatch above showed.
  why="$(head_holds "$old_head" "$WORK/.env" "$(docker inspect -f '{{json .Config.Env}}' "$cyfr_id")" "$(running)" -)" ||
    fail "before the preview the home does not hold A's head: $why"
  why="$(preview_holds "$WORK/preview.log" "$old_head" "$new_head")" || fail "cyfr reach tailnet's preview is not A's head to B's: $why"
  cmp -s "$WORK/.env" "$WORK/.env.restored" || fail "the declined preview changed .env"
  ok "cyfr reach tailnet previews exactly A's head to B's (https://cyfr.proof.ts.net -> https://cyfr-1.proof.ts.net), and, unconfirmed, changes nothing"
}

# ---------------------------------------------------------------------------
# shutdown
# ---------------------------------------------------------------------------

# The shutdown case's MCP upstream, the alias it answers at on the
# project's default network, and the server name the person gives it.
UPSTREAM_HOST="shutdown-upstream"
UPSTREAM_SERVER="upstream"

# The upstream itself, Erlang evaluated by the app image's own runtime
# (`erl` with the release's clean boot), so the run needs no other image:
# a plain HTTP/1.1 listener on 8080 that answers `tools/list` with one tool,
# `hold`, and `initialize` for a client that speaks the older revision,
# accepts notifications, and takes a `tools/call` without ever answering
# it, printing `held tools/call` once it has the whole request.
read -r -d '' UPSTREAM_ERL <<'ERL' || true
{ok, L} = gen_tcp:listen(8080, [binary, {packet, http_bin}, {active, false}, {reuseaddr, true}]),
io:format("listening~n"),
Reply = fun(S, Status, Body) ->
  gen_tcp:send(S, [<<"HTTP/1.1 ">>, Status, <<"\r\ncontent-type: application/json\r\ncontent-length: ">>,
                   integer_to_binary(iolist_size(Body)), <<"\r\n\r\n">>, Body])
end,
Answer = fun(S, Id, Result) ->
  Reply(S, <<"200 OK">>, json:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => Result}))
end,
Serve = fun Serve(S, Len) ->
  case gen_tcp:recv(S, 0) of
    {ok, {http_request, _, _, _}} -> Serve(S, 0);
    {ok, {http_header, _, 'Content-Length', _, V}} -> Serve(S, binary_to_integer(V));
    {ok, {http_header, _, _, _, _}} -> Serve(S, Len);
    {ok, http_eoh} when Len =:= 0 -> Reply(S, <<"405 Method Not Allowed">>, <<>>), Serve(S, 0);
    {ok, http_eoh} ->
      ok = inet:setopts(S, [{packet, raw}]),
      {ok, Raw} = gen_tcp:recv(S, Len),
      ok = inet:setopts(S, [{packet, http_bin}]),
      Msg = json:decode(Raw),
      Id = maps:get(<<"id">>, Msg, null),
      case maps:get(<<"method">>, Msg, null) of
        <<"tools/call">> ->
          io:format("held tools/call~n"),
          receive after infinity -> ok end;
        _ when Id =:= null ->
          Reply(S, <<"202 Accepted">>, <<>>), Serve(S, 0);
        <<"tools/list">> ->
          Answer(S, Id, #{<<"tools">> => [#{<<"name">> => <<"hold">>,
                                            <<"description">> => <<"Never answers">>,
                                            <<"inputSchema">> => #{<<"type">> => <<"object">>}}]}),
          Serve(S, 0);
        <<"initialize">> ->
          Params = maps:get(<<"params">>, Msg, #{}),
          Answer(S, Id, #{<<"protocolVersion">> => maps:get(<<"protocolVersion">>, Params, null),
                          <<"capabilities">> => #{<<"tools">> => #{}},
                          <<"serverInfo">> => #{<<"name">> => <<"hold">>, <<"version">> => <<"1">>}}),
          Serve(S, 0);
        _ ->
          Reply(S, <<"200 OK">>, json:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                                              <<"error">> => #{<<"code">> => -32601, <<"message">> => <<"Method not found">>}})),
          Serve(S, 0)
      end;
    _ -> gen_tcp:close(S)
  end
end,
Accept = fun Accept() ->
  {ok, S} = gen_tcp:accept(L),
  P = spawn(fun() -> receive go -> Serve(S, 0) end end),
  ok = gen_tcp:controlling_process(S, P),
  P ! go,
  Accept()
end,
Accept().
ERL

shutdown_case() {
  local base config grace signed_in token answer stream_ready task_held
  local started stopped stop_s exit_code oom stream_end stream_code task_end task_code tasks
  base="http://$(published)"
  config="$(compose config --format json)"

  step "the grace the shipped file gives cyfr"
  # Compose writes the period as a Go duration ("40s", "1m30s").
  grace="$(printf '%s' "$config" | python3 -I -c '
import json, re, sys
period = json.load(sys.stdin)["services"]["cyfr"].get("stop_grace_period") or "10s"
units = {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9}
parts = re.findall(r"(\d+(?:\.\d+)?)(ms|us|ns|h|m|s)", period)
assert parts and "".join(n + u for n, u in parts) == period, period
print(f"{sum(float(n) * units[u] for n, u in parts):g}")')"
  ok "cyfr's stop_grace_period is ${grace} s"

  step "a person signed in on cyfr, as the release proofs sign one in"
  signed_in="$(cyfr_fixture person operator@example.com compose-proof-shutdown)"
  token="$(printf '%s' "$signed_in" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["token"])')" ||
    fail "the release fixture signed nobody in: '$signed_in'"
  (umask 077 && printf 'authorization: Bearer %s\n' "$token" >"$WORK/session.headers")
  MCP_VERSION="$(cyfr_rpc 'IO.puts("VERSION=" <> Prima.MCP.Protocol.version())' | sed -n 's/^VERSION=//p')"
  [ -n "$MCP_VERSION" ] || fail "cyfr named no MCP protocol version"
  ok "operator@example.com is signed in; /mcp speaks $MCP_VERSION"

  step "the MCP upstream, on the project's default network"
  UPSTREAM="${RUN}-upstream"
  docker run --detach --name "$UPSTREAM" --user app \
    --network "${RUN}_$(table endpoint_network)" --network-alias "$UPSTREAM_HOST" --entrypoint sh "$IMAGE" -c '
      erts=$(ls -d /app/erts-*) release=$(ls -d /app/releases/*/ | head -1)
      exec "$erts/bin/erl" -boot "${release}start_clean" -boot_var RELEASE_LIB /app/lib -noshell -eval "$0"' \
    "$UPSTREAM_ERL" >/dev/null
  for _ in $(seq 1 30); do
    docker logs "$UPSTREAM" 2>/dev/null | grep -qx listening && break
    sleep 1
  done
  docker logs "$UPSTREAM" 2>/dev/null | grep -qx listening || fail "the upstream never listened: $(docker logs "$UPSTREAM" 2>&1 | tail -5)"
  ok "$UPSTREAM listens at http://$UPSTREAM_HOST:8080"

  step "an SSE stream held open: the person's subscriptions/listen, through the published port"
  (
    code=0
    mcp_post "$base" subscriptions/listen \
      "$(mcp_body subscriptions/listen '{"notifications": {"toolsListChanged": true}}' "$MCP_VERSION")" "" \
      -N --max-time 600 -o "$WORK/stream.out" 2>"$WORK/stream.err" || code=$?
    echo "$code $(date +%s.%N)" >"$WORK/stream.end"
  ) &
  stream_ready=""
  for _ in $(seq 1 30); do
    grep -q 'notifications/subscriptions/acknowledged' "$WORK/stream.out" 2>/dev/null && stream_ready=1 && break
    [ ! -e "$WORK/stream.end" ] || break
    sleep 1
  done
  [ -n "$stream_ready" ] ||
    fail "the stream was not acknowledged: $(head -c 600 "$WORK/stream.out" 2>/dev/null) $(cat "$WORK/stream.err" 2>/dev/null)"
  ok "the stream is open and acknowledged"

  step "the person adds the upstream as an HTTP MCP server, over /mcp"
  answer="$(mcp_post "$base" tools/call "$(mcp_body tools/call "{\"name\": \"mcp_servers\", \"arguments\": {
      \"action\": \"create\", \"name\": \"$UPSTREAM_SERVER\", \"config\": {\"transport\": \"http\",
      \"url\": \"http://$UPSTREAM_HOST:8080/mcp\", \"console\": true, \"timeout_ms\": 110000}}}" "$MCP_VERSION")" \
    mcp_servers --max-time 60)"
  printf '%s' "$answer" | python3 -I -c '
import json, sys
text = json.load(sys.stdin)["result"]["content"][0]["text"]
created = json.loads(text)
assert created["status"] == "ready" and created["tool_names"] == ["hold"], created' ||
    fail "mcp_servers create did not answer a ready server with the tool hold: ${answer:0:600}"
  ok "the server $UPSTREAM_SERVER is ready with its one tool, hold"

  step "a running task: the console's call of $UPSTREAM_SERVER:hold, which the upstream holds"
  (
    code=0
    cyfr_rpc "{answer, _} = Code.eval_file(\"/tmp/fixture.exs\"); IO.puts(answer.([\"console\", \"$token\", \"$UPSTREAM_SERVER:hold\", \"{}\"]))" \
      >"$WORK/task.out" 2>&1 || code=$?
    echo "$code $(date +%s.%N)" >"$WORK/task.end"
  ) &
  task_held=""
  for _ in $(seq 1 60); do
    docker logs "$UPSTREAM" 2>/dev/null | grep -qx 'held tools/call' && task_held=1 && break
    [ ! -e "$WORK/task.end" ] || break
    sleep 1
  done
  [ -n "$task_held" ] || fail "the call never reached the upstream: $(head -c 600 "$WORK/task.out" 2>/dev/null)"
  # A proxied server's call runs under Emissary's task supervisor, not the
  # gate's (Sanctum.Gate.TaskSupervisor).
  tasks="$(cyfr_rpc 'IO.puts("TASKS=#{length(Task.Supervisor.children(Emissary.TaskSupervisor))}")' |
    sed -n 's/^TASKS=//p')"
  [ "${tasks:-0}" -ge 1 ] || fail "cyfr runs no call: Emissary's task supervisor holds '${tasks:-}'"
  ok "the upstream holds the call; cyfr runs it as $tasks task(s) under Emissary's task supervisor"

  step "docker compose stop cyfr, timed"
  [ ! -e "$WORK/stream.end" ] || fail "the stream ended before the stop: $(cat "$WORK/stream.end")"
  [ ! -e "$WORK/task.end" ] || fail "the call ended before the stop: $(head -c 600 "$WORK/task.out")"
  started="$(date +%s.%N)"
  compose stop cyfr >"$WORK/stop.log" 2>&1 || fail "docker compose stop cyfr failed: $(cat "$WORK/stop.log")"
  stopped="$(date +%s.%N)"
  stop_s="$(seconds "$started" "$stopped")"
  read -r exit_code oom <<<"$(docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}}' "$cyfr_id")"
  for _ in $(seq 1 30); do
    [ -e "$WORK/stream.end" ] && [ -e "$WORK/task.end" ] && break
    sleep 1
  done
  read -r stream_code stream_end <<<"$(cat "$WORK/stream.end" 2>/dev/null || echo "- $stopped")"
  read -r task_code task_end <<<"$(cat "$WORK/task.end" 2>/dev/null || echo "- $stopped")"

  echo "stop: ${stop_s} s against a grace of ${grace} s; cyfr exited ${exit_code}, OOMKilled ${oom}"
  if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$stream_end" "$stopped"; then
    echo "stream: ended $(seconds "$started" "$stream_end") s into the stop, before the stop returned (curl exit $stream_code)"
  else
    echo "stream: still open when the stop returned; ended $(seconds "$started" "$stream_end") s into it (curl exit $stream_code)"
  fi
  # The rpc's last line, whatever ended it, with the session taken out.
  answer="$(tail -n 1 "$WORK/task.out" | head -c 300)"
  echo "call: ended $(seconds "$started" "$task_end") s into the stop (rpc exit $task_code): ${answer//$token/[session]}"

  [ "$oom" = false ] || fail "cyfr was killed for memory during the stop"
  [ "$exit_code" != 137 ] || fail "cyfr exited 137: the grace's SIGKILL ended it after ${stop_s} s"
  python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$stop_s" "$grace" ||
    fail "the stop took ${stop_s} s, past cyfr's grace of ${grace} s"
  ok "cyfr stopped in ${stop_s} s of its ${grace} s grace and exited ${exit_code} on its own"
}

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------

restore_case() {
  local name barred_exit expr prefix snapshot container exit_code logs out restore_id
  name="$(barrier name)"
  barred_exit="$(barrier barred_exit)"
  expr="$(barrier declare_expr)"
  prefix="$(barrier declared_prefix)"
  snapshot="/srv/cyfr/backups/20261018T000000Z"

  step "the stack stopped and its cyfr container removed, as cyfr restore leaves it before a part lands"
  compose stop cyfr >"$WORK/stop.log" 2>&1 || fail "docker compose stop failed: $(cat "$WORK/stop.log")"
  compose rm --force cyfr >"$WORK/rm.log" 2>&1 || fail "docker compose rm cyfr failed: $(cat "$WORK/rm.log")"
  ok "stopped; no cyfr container is left to start with its old environment"

  step "the bar in .env: $name"
  printf "%s='%s'\n" "$name" "$snapshot" >>"$WORK/.env"
  ok "$name='$snapshot'"

  step "a start of the cyfr service while barred is refused at the entrypoint"
  # The container compose creates from .env as it now stands, started
  # once: its restart policy is set to none first, so the exit read is the
  # refusal's, not a restart's.
  compose up --no-start --no-deps cyfr >"$WORK/up.log" 2>&1 || fail "docker compose up --no-start cyfr failed: $(cat "$WORK/up.log")"
  container="$(compose ps --all --quiet cyfr)"
  [ -n "$container" ] || fail "compose created no cyfr container"
  docker update --restart no "$container" >/dev/null
  docker start "$container" >/dev/null
  exit_code="$(timeout 60 docker wait "$container")" || exit_code="none within 60 s"
  logs="$(docker logs "$container" 2>&1 | tail -n 20)"
  compose rm --stop --force cyfr >"$WORK/rm.log" 2>&1 || fail "docker compose rm cyfr failed: $(cat "$WORK/rm.log")"
  [ "$exit_code" = "$barred_exit" ] || fail "the barred cyfr container exited $exit_code, not $barred_exit: $logs"
  case "$logs" in
    *"has not been declared"*"cyfr restore $snapshot"*) ;;
    *) fail "the barred cyfr container's refusal does not name the restore: $logs" ;;
  esac
  ok "exit $barred_exit: $(printf '%s\n' "$logs" | grep -m1 'has not been declared')"

  step "the declaration, as cyfr restore runs it: the bar set empty in a one-off cyfr container"
  out="$(compose run --rm --no-deps -T -e "$name=" cyfr bin/cyfr eval "$expr" 2>&1)" ||
    fail "the declaration failed: $(printf '%s\n' "$out" | tail -n 20)"
  restore_id="$(printf '%s\n' "$out" | sed -n "s/^$prefix//p" | tail -n 1)"
  case "$restore_id" in
    rst_?*) ;;
    *) fail "the declaration printed no restore id: $(printf '%s\n' "$out" | tail -n 20)" ;;
  esac
  ok "declared: $prefix$restore_id"
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

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

project_new

case "$CASE" in
  bind)
    bind_case
    ;;
  modes)
    modes_case
    ;;
  interrupt)
    interrupt_case
    ;;
  restore-identity)
    restore_identity_case
    ;;
  shutdown | restore)
    step "up: a local home, as a project of this run's own"
    cli_ok up-local up
    expect_head local localhost
    if [ "$CASE" = shutdown ]; then shutdown_case; else restore_case; fi
    ;;
esac

echo
echo "compose proof: $CASE passed"
