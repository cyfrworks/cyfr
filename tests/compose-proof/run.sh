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
#          start, and a turn a provider key besides. The case prints the stop's wall time, the
#          grace, the container's exit and how the stream and the call
#          ended.
#
# The project is the run's own: a unique name, the containers named from
# it, host ports Docker picks on the loopback, a scratch directory holding
# the environment `cyfr init` writes, and `down -v` of that project alone
# when the run ends, however it ends. Nothing of a deployed stack on the
# same host is touched.
#
# Usage: tests/compose-proof/run.sh --case bind|shutdown
# COMPOSE_PROOF_SKIP_BUILD=1 reuses the image a previous run built
# (cyfr:compose-proof); COMPOSE_PROOF_KEEP=1 keeps the scratch directory.
set -euo pipefail

usage() {
  echo "usage: $0 --case bind|shutdown" >&2
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
case "$CASE" in bind | shutdown) ;; *) usage ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="cyfr:compose-proof"
RUN="cyfr-compose-proof-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-compose-proof-XXXXXX")"
PORT=4000
# The shutdown case's MCP upstream, a container of the run's own.
UPSTREAM=""

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
  # The shutdown case's clients and its upstream go first: the upstream
  # holds a place on the project's network, which `down` removes.
  local job
  for job in $(jobs -p); do
    pkill -P "$job" 2>/dev/null || true
    kill "$job" 2>/dev/null || true
  done
  [ -z "$UPSTREAM" ] || docker rm --force "$UPSTREAM" >/dev/null 2>&1 || true
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

# `bin/cyfr rpc` of `$1` inside the running cyfr, as the image's user.
cyfr_rpc() {
  docker exec -u app "$cyfr_id" /app/bin/cyfr rpc "$1"
}

# One command of the release proofs' fixture (tests/release-boot/fixture.exs)
# in the running cyfr, each argument an Elixir string with `\`, `"` and `#`
# escaped: its one JSON answer, or nothing when it raised.
cyfr_fixture() {
  local args="" arg
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

shutdown_case() {
  local base config grace signed_in token answer stream_ready task_held
  local started stopped stop_s exit_code oom stream_end stream_code task_end task_code tasks
  base="http://$(compose port cyfr "$PORT")"
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
  docker cp "$ROOT/tests/release-boot/fixture.exs" "$cyfr_id:/tmp/fixture.exs" >/dev/null
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
    --network "${RUN}_${endpoint_network}" --network-alias "$UPSTREAM_HOST" --entrypoint sh "$IMAGE" -c '
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
  # The shutdown case's upstream is a private host cyfr reaches as the
  # operator names one.
  if [ "$CASE" = shutdown ]; then
    echo "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends,$UPSTREAM_HOST"
  else
    echo "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends"
  fi
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

if [ "$CASE" = shutdown ]; then
  shutdown_case
  echo
  echo "compose proof: shutdown passed"
  exit 0
fi

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
