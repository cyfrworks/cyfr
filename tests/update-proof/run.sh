#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The update proof: an install made by an older release, as a person makes
# one, updated by `cyfr update` as that person (no sudo) to a release
# built from this tree, and read for what a person relies on. The host's
# nightly runs it on main's head (scripts/stages.tsv, scripts/nightly.sh).
#
# The old side (tests/update-proof/choose.sh) is the newest published
# release whose schema is this tree's, when one is; otherwise the schema's
# base, the oldest commit of HEAD's first-parent line with HEAD's schema,
# built here from a worktree of it as release.yml builds a release, since
# there is no upgrade path between schemas and every install on this
# schema was made at or after that commit. The log's first line names the
# old side and why. A published release is installed by its own install
# script (cosign-verified) and `cyfr init`, which pull its published
# images; the base by its own command line (a development build, as the
# Compose proof's old side is) from its own scaffold, its images built by
# its own scripts/image.sh and tagged as a release under the next patch's
# pre-release <run>.1. The new side is this tree's images and scaffold
# under <run>.2, and this tree's command line built with the releaseproof
# tag (tests/lib/candidate-release.sh, which the Compose proof's update
# cases use too), run with `--continue-as`, as the program step hands
# over to it; its pulls of the candidate's images by digest are answered
# from the image store (the containerd store), every other pull reaching
# its registry.
#
# The install is the shipped stack as `cyfr init` lays it down, nothing
# overlaid, in local access, with what a person sets in .env: a port of the
# run's own (CYFR_PORT, never 4000), builds on, a host of their own added
# to the private egress list, and the account directory and both
# registries at an address nothing answers, so nothing of the run reaches
# an outside service (the release fixture's people are cached here alone,
# tests/release-boot/fixture.exs `person`). Before the update the old
# release holds a person signed in, a message in their thread, a program
# whose home is kept with a file in it, and a build made through the
# builds role. The update's report is followed as a person follows it:
# each .env line it names gets the edit it says, then `cyfr up`. Then:
#
#   - every service the new file declares is healthy (running where it has
#     no health check) with no restart, the project holds no container of
#     a service the new file does not declare and no network it does not
#     use, and cyfr runs the new release's image, which the compose file
#     names by its digest;
#   - the person is still signed in by the session from before the update
#     and their message is served; the program, started again, finds its file
#     in its kept home under the uid it had; a build runs;
#   - the update's snapshot says it is complete, every file of it is the
#     person's, and its database copy passes PRAGMA integrity_check and
#     holds the person's row;
#   - the update's own sentences: it says it updated to the new release,
#     names the snapshot it took, and each service and network it says it
#     removed is gone, and it printed no FATAL line.
#
# The stack's fixed names and subnets: the shipped file names its
# containers (cyfr, cyfr-locus, ...) and fixes its networks' subnets, and
# an overlay cannot follow the update's switch of the file, so the run
# holds them, as a person's install does. Before the old release's first
# `cyfr up` it looks: a container of a name either release's file fixes,
# or a network holding a subnet either fixes, ends the run with 69 (not
# run), naming what holds it, before anything starts. It holds them from
# that `cyfr up` until its teardown and prints how long as `held: <n>s`.
# Everything else is the run's own: the project, its networks and volumes
# (named from the project, which its folder names), the folder
# /var/tmp/cyfr/<RUN> and the release tags (<repository>:<version>, the
# version carrying RUN). The teardown takes it all down on every exit: the
# project's containers, networks and volumes by the project's label, the
# release tags, the base worktree, and the folder, whose data/ the
# server's container owns and gives back through a container of the app
# image first. A run killed past its trap leaves what the next run's start
# sweeps, by the label of a project whose run's process is gone.
#
# What this cannot show: the program step that downloads and replaces the
# command line, the signature check of a candidate's manifest (it has
# none), and an update across an AppArmor profile the host has not loaded,
# which the update offers to load through sudo.
#
# Usage: tests/update-proof/run.sh
# Every name the run gives Docker begins with PROOF_RUN_PREFIX, which
# scripts/heavy-check.sh sets. Needs docker on the containerd image store,
# git, go, gh (the published releases), cosign, curl, python3 and openssl.
# Exits 0 when every check passed, 1 when one failed or the run broke,
# 69 without a prerequisite or with the fixed names held, 130 and 143 on
# INT and TERM.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=scripts/lib/run-names.sh
. "$ROOT/scripts/lib/run-names.sh"
# shellcheck source=tests/update-proof/choose.sh
. "$HERE/choose.sh"
# shellcheck source=tests/lib/candidate-release.sh
. "$ROOT/tests/lib/candidate-release.sh"

for name in $(compgen -e); do
  case "$name" in COMPOSE_*) unset "$name" ;; esac
done
RUN="${PROOF_RUN_PREFIX:-$(run_names_prefix "$ROOT")}update-proof-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TMP_ROOT="$(run_names_root)"
WORK="$TMP_ROOT/$RUN"
PROOF="$WORK/proof"
RELEASES="$PROOF/releases"
BASE_TREE="$PROOF/base"
OLD_CYFR="$PROOF/bin/cyfr-old"
NEW_CYFR="$PROOF/bin/cyfr-new"
REAL_DOCKER="$(command -v docker)"
RELEASE_IMAGES=()
PROJECT=""
HELD_AT=""
cyfr_id=""
OLD_KIND="" OLD_REF="" OLD_TREE=""
OLD_VERSION="" NEW_VERSION="" OLD_SERVES=""
NEW_DIGEST="" NEW_LOCUS_DIGEST=""
APP_IMAGE=""
PERSON="" TOKEN="" THREAD="" MARK=""

step() { echo; echo "==> $*"; }
ok() { echo "ok: $*"; }
fail() {
  echo "::error::$*" >&2
  exit 1
}
missing() {
  echo "not run: $*" >&2
  exit 69
}

for tool in git go gh cosign curl python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || missing "$tool is not on PATH"
done
"$ROOT/scripts/ci/containerd-image-store.sh" --check >/dev/null 2>&1 ||
  missing "the Docker daemon is not on the containerd image store (scripts/ci/containerd-image-store.sh)"

# ---------------------------------------------------------------------------
# The teardown, and the sweep of what a killed run left
# ---------------------------------------------------------------------------

# Runs the command after `$1`, its description, until it succeeds, at most
# three times; a third failure is named and fails the run.
removal() {
  local what="$1" attempt err=""
  shift
  for attempt in 1 2 3; do
    if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
    [ "$attempt" = 3 ] || sleep 3
  done
  echo "::error::update proof teardown: $what failed three times: ${err:0:600}" >&2
  return 1
}

# What the project `$1` holds on the daemon, by its label: containers,
# then networks, then volumes, each removed.
project_gone() {
  local project="$1" id failed=""
  for id in $(docker ps -aq --filter "label=com.docker.compose.project=$project"); do
    removal "docker rm --force $id" docker rm --force --volumes "$id" || failed=1
  done
  for id in $(docker network ls -q --filter "label=com.docker.compose.project=$project"); do
    removal "docker network rm $id" docker network rm "$id" || failed=1
  done
  for id in $(docker volume ls -q --filter "label=com.docker.compose.project=$project"); do
    removal "docker volume rm $id" docker volume rm "$id" || failed=1
  done
  [ -z "$failed" ]
}

# The folder `$1` given back to this user through a container of the image
# `$2` (data/ is the server's), then removed.
folder_gone() {
  [ -d "$1" ] || return 0
  removal "taking $1 back from the image's user" docker run --rm --name "$RUN-chown-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" \
    --network none --user 0 --volume "$1:/work" --entrypoint chown "$2" -R "$(id -u):$(id -g)" /work || return 1
  removal "removing $1" rm -rf "$1"
}

cleanup() {
  local code=$? failed="" made id
  trap '' INT TERM
  if [ "$code" -ne 0 ] && [ -n "$PROJECT" ]; then
    echo "----- the project's containers -----" >&2
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}} {{.Status}}' >&2 || true
    for id in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=cyfr"); do
      echo "----- the last lines of cyfr's log -----" >&2
      docker logs --tail 120 "$id" 2>&1 | cut -c1-400 >&2 || true
    done
  fi
  if [ -n "$PROJECT" ]; then project_gone "$PROJECT" || failed=1; fi
  if [ -n "$HELD_AT" ]; then
    echo "held: $((SECONDS - HELD_AT))s"
    echo "the fixed names and subnets were held from the old release's first start to the teardown's end"
  fi
  if [ -n "$APP_IMAGE" ]; then folder_gone "$WORK" "$APP_IMAGE" || failed=1; fi
  for made in ${RELEASE_IMAGES[@]+"${RELEASE_IMAGES[@]}"}; do
    removal "docker image rm $made" docker image rm "$made" || failed=1
  done
  if [ -n "$OLD_TREE" ]; then
    git -C "$ROOT" worktree remove --force "$BASE_TREE" >/dev/null 2>&1 || true
    git -C "$ROOT" worktree prune
  fi
  [ ! -d "$WORK" ] || removal "removing $WORK" rm -rf "$WORK" || failed=1
  if [ -n "$failed" ] && [ "$code" -eq 0 ]; then code=1; fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# What a run killed before its teardown left: a folder under the run root
# named for a run whose pid is gone, its project's containers, networks and
# volumes by the project's label, its release tags, and the folder itself.
sweep_dead_runs() {
  local dir run base pid project name
  for dir in "$TMP_ROOT"/*update-proof-*; do
    [ -d "$dir" ] && [ -O "$dir" ] && [ "$dir" != "$WORK" ] || continue
    run=${dir##*/} base=${dir##*/}
    if [[ $base =~ $RUN_NAMES_PATTERN ]]; then base=${base:${#BASH_REMATCH[0]}}; fi
    [[ $base =~ ^update-proof-([0-9]+)-[0-9a-f]{8}$ ]] || continue
    pid=${BASH_REMATCH[1]}
    ! ps -p "$pid" >/dev/null 2>&1 || continue
    project="$(project_name "$run")"
    if project_gone "$project"; then
      while IFS= read -r name; do
        [[ $name == *"-$run".[12] ]] || continue
        docker image rm "$name" >/dev/null 2>&1 || echo "::warning::update proof: could not remove the tag $name" >&2
      done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter 'reference=ghcr.io/cyfrworks/*')
      if folder_gone "$dir" "$(fallback_image)"; then
        echo "removed $dir and its project $project, left by the run $pid, which is gone"
      fi
    else
      echo "::warning::update proof: could not remove the project $project, left by the run $pid" >&2
    fi
  done
  git -C "$ROOT" worktree prune
}

# The compose project a folder named `$1` makes: compose's own
# normalization of the folder's name.
project_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# An image that runs chown, for a sweep before this run has built one: the
# newest local app image of scripts/image.sh's.
fallback_image() {
  docker image ls --format '{{.Repository}}:{{.Tag}}' --filter 'reference=cyfr:in-*' | head -n 1
}

# ---------------------------------------------------------------------------
# The install
# ---------------------------------------------------------------------------

# The command line `$1` in the install's folder, as a person runs it: HOME
# the run's own, nothing of the caller's environment but PATH (with the
# run's docker first) and how Docker is reached; output in
# $PROOF/logs/$2.log, the status the command's.
cli() {
  local cyfr="$1" log="$PROOF/logs/$2.log"
  shift 2
  printf '$ cyfr %s\n' "$*" >"$log"
  (
    cd "$WORK" || exit 1
    umask 022
    exec env -i HOME="$PROOF/home" PATH="$PROOF/shim:$PATH" LANG=C.UTF-8 TERM=dumb \
      DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
      ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} \
      "$cyfr" "$@"
  ) </dev/null >>"$log" 2>&1
}
cli_ok() {
  local status=0
  cli "$@" || status=$?
  [ "$status" -eq 0 ] || fail "cyfr ${*:3} exited $status: $(tail -n 30 "$PROOF/logs/$2.log")"
}

# The run's docker, first on the command line's PATH: a `docker pull REF`
# whose REF is a line of $PROOF/candidate-pulls (the candidate's images by
# digest, on no registry) answers from the image store; every other call
# is the real docker's.
shim_install() {
  mkdir -p "$PROOF/shim"
  cat >"$PROOF/shim/docker" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 2 ] && [ "\$1" = pull ] && grep -qxF -- "\$2" "$PROOF/candidate-pulls"; then
  "$REAL_DOCKER" image inspect "\$2" >/dev/null || exit 1
  echo "docker (the proof's): \$2 is in the image store by that digest"
  exit 0
fi
exec "$REAL_DOCKER" "\$@"
SH
  chmod +x "$PROOF/shim/docker"
}

compose() {
  docker compose --project-directory "$WORK" "$@"
}

# The value .env's last assignment of `$1` holds, or nothing.
env_value() {
  NAME="$1" awk 'index($0, ENVIRON["NAME"] "=") == 1 { value = substr($0, length(ENVIRON["NAME"]) + 2) } END { print value }' "$WORK/.env"
}

# Sets `$1` to `$2` in .env as a person edits it: the first assignment
# rewritten in place and any later one removed, or the line added at the
# end. Written over the file, so it keeps its mode.
env_set() {
  NAME="$1" VALUE="$2" awk '
    BEGIN { name = ENVIRON["NAME"]; line = name "=" ENVIRON["VALUE"] }
    index($0, name "=") == 1 { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }
  ' "$WORK/.env" >"$PROOF/env.part"
  cat "$PROOF/env.part" >"$WORK/.env"
  rm -f "$PROOF/env.part"
}

# The container names and subnets the compose file `$1` fixes, one per
# line: `name NAME` and `subnet CIDR`.
fixed_names() {
  docker compose -f "$1" --project-directory "$(dirname "$1")" --profile '*' config --format json --no-interpolate 2>/dev/null |
    python3 -I -c '
import json, sys
project = json.load(sys.stdin)
for service in project["services"].values():
    if service.get("container_name"):
        print("name", service["container_name"])
for network in project.get("networks", {}).values():
    for config in (network.get("ipam") or {}).get("config") or []:
        if config.get("subnet"):
            print("subnet", config["subnet"])'
}

# Each network on the daemon and its subnets, one line each; a network
# removed between the listing and its reading is passed over.
network_subnets() {
  local id
  for id in $(docker network ls -q); do
    docker network inspect --format '{{.Name}}{{range .IPAM.Config}} {{.Subnet}}{{end}}' "$id" 2>/dev/null || true
  done
}

# Nothing on the daemon holds a name or subnet either compose file fixes:
# otherwise the run ends here with 69, naming the holder.
names_free() {
  local kind value holder
  while read -r kind value; do
    case "$kind" in
      name)
        holder="$(docker ps -a --filter "name=^/${value}\$" --format '{{.Names}} ({{.Label "com.docker.compose.project"}}, {{.Status}})')"
        [ -z "$holder" ] || missing "the container name $value, which the stack fixes, is held by the container $holder"
        ;;
      subnet)
        holder="$(network_subnets | awk -v s="$value" '{ for (i = 2; i <= NF; i++) if ($i == s) print $1 }' | head -n 1)"
        [ -z "$holder" ] || missing "the subnet $value, which the stack fixes, is held by the network $holder"
        ;;
    esac
  done < <(sort -u "$@")
  ok "no container holds a name the stack fixes, and no network a subnet it fixes"
}

# Every service of the running project healthy (running where it has no
# health check), within 180 s: cyfr's container in cyfr_id.
stack_healthy() {
  local closes=$((SECONDS + 180)) states=""
  while [ "$SECONDS" -lt "$closes" ]; do
    states="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
      --format '{{.Label "com.docker.compose.service"}}={{.State}}/{{.Status}}' | sort)"
    if [ -n "$states" ] && ! grep -v -E '=running/.*\(healthy\)$|=running/Up [^()]*$' <<<"$states" | grep -q .; then
      cyfr_id="$(compose ps -q cyfr)"
      [ -n "$cyfr_id" ] || fail "the project has no cyfr container"
      return 0
    fi
    sleep 2
  done
  fail "the project's services are not all healthy after 180 s: $(tr '\n' ' ' <<<"$states")"
}

# One command of the release fixture of the tree `$1` in the running cyfr,
# each further argument an Elixir string: its one JSON answer, or nothing
# when it raised.
fixture() {
  local tree="$1" args="" arg
  shift
  # Written as the server's user, whatever mode the tree's copy has.
  docker exec -i -u app "$cyfr_id" sh -c 'cat >/tmp/fixture.exs' <"$tree/tests/release-boot/fixture.exs" || return 0
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"#]/\\&/g')\","
  done
  docker exec -u app "$cyfr_id" /app/bin/cyfr rpc "{answer, _} = Code.eval_file(\"/tmp/fixture.exs\"); IO.puts(answer.([${args%,}]))" |
    sed -n 's/^FIXTURE=//p' | tail -n 1 || true
}

# The value at path `$2...` of the JSON `$1`: a string as itself, anything
# else as JSON, null for a step that is not there.
jget() {
  printf '%s' "${1:-null}" | python3 -I -c '
import json, sys
value = json.load(sys.stdin)
for step in sys.argv[1:]:
    if isinstance(value, list):
        value = value[int(step)] if -len(value) <= int(step) < len(value) else None
    else:
        value = value.get(step) if isinstance(value, dict) else None
print(value if isinstance(value, str) else json.dumps(value))' "${@:2}"
}

# ---------------------------------------------------------------------------
# The person's things: a program with a kept home, a build
# ---------------------------------------------------------------------------

# The person's athanor reads filled (Sanctum.Provisioning.status/1, the
# product's own readiness) within 120 s, under the session TOKEN.
fill_ready() {
  local fill
  fill="$(docker exec -u app "$cyfr_id" /app/bin/cyfr rpc "{:ok, ctx} = Sanctum.Caller.establish({:session, \"$TOKEN\"})
    deadline = System.monotonic_time(:millisecond) + 120_000
    settle = fn settle ->
      case Sanctum.Provisioning.status(ctx) do
        :filling ->
          if System.monotonic_time(:millisecond) < deadline,
            do: (Process.sleep(250); settle.(settle)),
            else: :filling
        other -> other
      end
    end
    IO.puts(\"FILL=#{settle.(settle)}\")
    # arca:unscoped-ok: the proof reads why its own person's fill failed.
    IO.puts(\"WHY=#{inspect(Arca.Repo.get(Arca.Schemas.Athanor, ctx.athanor_id).provisioning_failure)}\")")"
  [ "$(sed -n 's/^FILL=//p' <<<"$fill")" = ready ] ||
    fail "the person's athanor reads '$(sed -n 's/^FILL=//p' <<<"$fill")', not ready, within 120 s: $(sed -n 's/^WHY=//p' <<<"$fill" | cut -c1-600)"
}

# The fixture's command `$3...` of the tree `$2` asked again, 2 s apart,
# until it answers ok or `$1` seconds pass: the components projection and
# a program's first call after a start answer unavailable for a while.
until_ok() {
  local seconds="$1" tree="$2" closes answer=""
  shift 2
  closes=$((SECONDS + seconds))
  while :; do
    answer="$(fixture "$tree" "$@")"
    if [ "$(jget "${answer:-null}" ok)" != null ]; then
      printf '%s\n' "$answer"
      return 0
    fi
    [ "$SECONDS" -lt "$closes" ] || break
    sleep 2
  done
  fail "${3:-the call} did not answer ok within $seconds s: ${answer:-nothing}"
}

# The program's tool `$1` called through the console, its answer's text
# read as JSON.
program_call() {
  local answer
  answer="$(until_ok 120 "$2" console "$TOKEN" "update-proof-kept:$1" "$3")" || exit 1
  jget "$answer" ok content 0 text
}

# A stdio MCP server in node, which the Locus image has, holding two tools
# that write and read the file `mark` in its home and answer the uid, the
# home and the file's bytes. No backslash, so each quoting layer passes it.
# shellcheck disable=SC2016
PROGRAM_COMMAND='node -e '\''const fs=require("fs"),NL=String.fromCharCode(10);let b="";const s=m=>process.stdout.write(JSON.stringify(m)+NL);process.stdin.on("data",c=>{b+=c;let i;while((i=b.indexOf(NL))>=0){const l=b.slice(0,i).trim();b=b.slice(i+1);if(!l)continue;const m=JSON.parse(l);if(m.id==null)continue;const r=x=>s({jsonrpc:"2.0",id:m.id,result:x});if(m.method==="initialize")r({protocolVersion:"2025-03-26",capabilities:{tools:{}},serverInfo:{name:"kept",version:"0"}});else if(m.method==="tools/list")r({tools:["write","read"].map(n=>({name:n,description:n,inputSchema:{type:"object"}}))});else if(m.method==="tools/call"){const f=process.env.HOME+"/mark";if(m.params.name==="write")fs.writeFileSync(f,String(m.params.arguments.mark));let t=null;try{t=fs.readFileSync(f,"utf8")}catch(e){}r({content:[{type:"text",text:JSON.stringify({uid:process.getuid(),home:process.env.HOME,mark:t})}]})}else s({jsonrpc:"2.0",id:m.id,error:{code:-32601,message:"unknown"}})}})'\'
PROGRAM_UID="" PROGRAM_HOME=""

# The person's program, its home kept, made through the console as Prism
# makes one (a definition the person's device confirms), and the file
# written into its home.
program_make() {
  local args made said
  fill_ready
  args="$(python3 -I -c 'import json, sys; print(json.dumps({"action": "create", "name": "update-proof-kept", "config": {"transport": "program", "mark": "mcp", "home": "kept", "console": True, "command": sys.argv[1], "env": {}}}))' "$PROGRAM_COMMAND")"
  made="$(until_ok 60 "$OLD_TREE" confirmed "$TOKEN" mcp_servers "$args")" || exit 1
  [ "$(jget "$made" ok home)" = kept ] || fail "the program was not made with its home kept: $made"
  said="$(program_call write "$OLD_TREE" "{\"mark\":\"$MARK\"}")" || exit 1
  PROGRAM_UID="$(jget "$said" uid)" PROGRAM_HOME="$(jget "$said" home)"
  [ "$(jget "$said" mark)" = "$MARK" ] || fail "the program did not write $MARK into its home: $said"
  [[ $PROGRAM_UID =~ ^[0-9]+$ ]] && [ "$PROGRAM_UID" -ne 0 ] || fail "the program runs under no uid of its own: $said"
  ok "the program update-proof-kept wrote $MARK into its kept home $PROGRAM_HOME as uid $PROGRAM_UID"
}

# The program started again by the new release finds its file in its home
# under the uid it had.
program_reopened() {
  local said
  said="$(program_call read "$ROOT" '{}')" || exit 1
  [ "$(jget "$said" mark)" = "$MARK" ] && [ "$(jget "$said" uid)" = "$PROGRAM_UID" ] && [ "$(jget "$said" home)" = "$PROGRAM_HOME" ] ||
    fail "after the update the program's kept home is not what it was ($PROGRAM_HOME, uid $PROGRAM_UID, $MARK): $said"
  ok "the program, started again by release $NEW_VERSION, reads $MARK in $PROGRAM_HOME as uid $PROGRAM_UID"
}

# A build through the builds role, as `cyfr new tincture --template vite`
# and `cyfr build compile` make one: the component made once, by the old
# release, then compiled by the release `$1` names, the fixture of the
# tree `$2`.
BUILD_REF="tincture:local.update-proof-build:0.1.0"
build_runs() {
  local tree="$2" started id status closes
  if [ "$tree" = "$OLD_TREE" ]; then
    fill_ready
    until_ok 60 "$tree" console "$TOKEN" component/create '{"type":"tincture","name":"update-proof-build","template":"vite"}' >/dev/null || exit 1
  fi
  started="$(until_ok 60 "$tree" console "$TOKEN" build/compile "{\"reference\":\"$BUILD_REF\",\"async\":true}")" || exit 1
  id="$(jget "$started" ok build_id)"
  [ -n "$id" ] && [ "$id" != null ] || fail "the build of $BUILD_REF did not start: $started"
  closes=$((SECONDS + 300))
  while :; do
    status="$(jget "$(fixture "$tree" console "$TOKEN" build/status "{\"build_id\":\"$id\"}")" ok status)"
    case "$status" in
      compiled) break ;;
      failed) fail "$1's build of $BUILD_REF failed: $(fixture "$tree" console "$TOKEN" build/status "{\"build_id\":\"$id\"}")" ;;
    esac
    [ "$SECONDS" -lt "$closes" ] || fail "$1's build of $BUILD_REF reads '$status' after 300 s"
    sleep 3
  done
  ok "$1 built $BUILD_REF through the builds role ($id)"
}

# ---------------------------------------------------------------------------
# The readings after the update
# ---------------------------------------------------------------------------

# The update's report followed as a person follows it: each .env line it
# names as naming a service the release no longer runs gets the edit the
# report says (that service's name replaced by the host it gives, the rest
# of the line kept), then `cyfr up`. A report with an edit and no closing
# sentence, or a closing sentence with no edit, is no sane report.
follow_report() {
  local edits closing named
  edits="$(sed -nE 's/^  ([A-Z0-9_]+), line ([0-9]+), names ([a-z0-9-]+): put ([a-z0-9.-]+) in place of \3 in (its URL|that line), keeping .*$/\2 \1 \3 \4/p' "$PROOF/logs/update.log")"
  closing="$(grep -c -E "^Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach " "$PROOF/logs/update.log" || true)"
  named="$(grep -E '^  [A-Z0-9_]+, line [0-9]+, names [a-z0-9-]+: ' "$PROOF/logs/update.log" || true)"
  if [ "$(grep -c . <<<"$named")" != "$(grep -c . <<<"$edits")" ]; then
    fail "the update names .env lines whose advice is no edit a person can follow: $(grep -vE ': put [a-z0-9.-]+ in place of [a-z0-9-]+ in (its URL|that line), keeping ' <<<"$named" | head -n 3)"
  fi
  if [ -z "$edits" ]; then
    [ "$closing" = 0 ] || fail "the update says CYFR cannot reach a host until lines are changed, and names no line to change"
    ok "the update names no .env line to change"
    return 0
  fi
  [ "$closing" = 1 ] || fail "the update names .env lines to change and does not say what cannot work until they are"
  local at key host put line
  while read -r at key host put; do
    line="$(sed -n "${at}p" "$WORK/.env")"
    [[ $line == "$key="* ]] || fail "the update names line $at of .env as $key, and that line is: ${line%%=*}"
    grep -qE "(^|[^a-z0-9-])$host([^a-z0-9-]|$)" <<<"${line#*=}" || fail "the update says line $at ($key) names $host, and it does not"
    python3 -I - "$WORK/.env" "$at" "$host" "$put" <<'PY' || fail "line $at of .env could not be edited"
import re, sys
path, at, host, put = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
lines = open(path).read().split("\n")
key, value = lines[at - 1].split("=", 1)
lines[at - 1] = key + "=" + re.sub(r"(?<![a-z0-9-])" + re.escape(host) + r"(?![a-z0-9-])", put, value)
with open(path, "r+") as f:
    f.truncate(0)
    f.write("\n".join(lines))
PY
    ok "followed the report: $key (line $at), $put in place of $host"
  done <<<"$edits"
  cli_ok "$NEW_CYFR" up-after-edits up
}

# What the update left running: the project's services against the new
# file, its networks, its images, and the update's own sentences.
update_readings() {
  local services networks used containers name image want running restarts removed
  services="$(compose config --services | sort)"
  containers="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.service"}}' | sort)"
  for name in $containers; do
    grep -qxF "$name" <<<"$services" || fail "after the update the project holds a container of $name, a service release $NEW_VERSION does not declare: $(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$name" --format '{{.Names}} {{.Status}}')"
  done
  stack_healthy
  for name in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"); do
    restarts="$(docker inspect --format '{{.Name}} {{.RestartCount}}' "$name")"
    [ "${restarts##* }" = 0 ] || fail "after the update ${restarts% *} restarted ${restarts##* } times"
  done
  ok "release $NEW_VERSION runs $(tr '\n' ' ' <<<"$containers")every one healthy or running, none restarted, none of a service it does not declare"
  used="$(compose config --format json | python3 -I -c '
import json, sys
project = json.load(sys.stdin)
print("\n".join(sorted({n for s in project["services"].values() for n in (s.get("networks") or {})})))')"
  networks="$(docker network ls --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.network"}}' | sort)"
  for name in $networks; do
    grep -qxF "$name" <<<"$used" || fail "after the update the project holds the network $name, which release $NEW_VERSION's services do not use"
  done
  ok "the project's networks are $(tr '\n' ' ' <<<"$networks")alone"
  image="$(compose config --format json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["cyfr"]["image"])')"
  [ "$image" = "ghcr.io/cyfrworks/cyfr:$NEW_VERSION@$NEW_DIGEST" ] || fail "docker-compose.yml names $image for cyfr, not ghcr.io/cyfrworks/cyfr:$NEW_VERSION@$NEW_DIGEST"
  want="$(docker image inspect --format '{{.Id}}' "ghcr.io/cyfrworks/cyfr:$NEW_VERSION")"
  running="$(docker inspect --format '{{.Image}}' "$cyfr_id")"
  [ "$running" = "$want" ] || fail "cyfr runs the image $running, not release $NEW_VERSION's $want"
  ok "cyfr runs release $NEW_VERSION's image, which docker-compose.yml names by its digest"

  grep -qxF "Updated to release $NEW_VERSION." "$PROOF/logs/update.log" || fail "the update never says it updated to release $NEW_VERSION"
  ! grep -q 'FATAL' "$PROOF/logs/update.log" || fail "the update printed a FATAL line: $(grep FATAL "$PROOF/logs/update.log" | head -n 3)"
  removed="$(sed -nE "s/^Removed this project's containers of services release [^ ]+ does not run: (.*)\.$/\1/p" "$PROOF/logs/update.log" | tr -d ',')"
  for name in $removed; do
    grep -qw -- "$name" <<<"$before_services" || fail "the update says it removed the container of $name, which the old release never ran"
    ! grep -qxF "$name" <<<"$containers" || fail "the update says it removed the container of $name, which is still there"
  done
  removed="$(sed -nE "s/^Removed this project's networks release [^ ]+ does not use: (.*)\.$/\1/p" "$PROOF/logs/update.log" | tr -d ',')"
  for name in $removed; do
    ! grep -qxF "$name" <<<"$networks" || fail "the update says it removed the network $name, which is still there"
  done
  ok "the update's sentences hold: it updated to $NEW_VERSION, and what it says it removed is gone"

  # The session the person signed in with before the update: a person
  # stays signed in across it, and every call below is made under it.
  signed_in="$(docker exec -u app "$cyfr_id" /app/bin/cyfr rpc "case Sanctum.Caller.establish({:session, \"$TOKEN\"}) do
      {:ok, ctx} -> IO.puts(\"PERSON=#{ctx.user_id}\")
      other -> IO.puts(\"PERSON=#{inspect(other)}\")
    end" | sed -n 's/^PERSON=//p')"
  [ "$signed_in" = "$PERSON" ] || fail "after the update the person's session opens as '$signed_in', not $PERSON"
  thread_answer="$(fixture "$ROOT" thread_read "$PERSON" "$THREAD")"
  grep -qF "$MARK" <<<"$(jget "$thread_answer" contents)" || fail "release $NEW_VERSION does not serve the person's message $MARK: '$thread_answer'"
  ok "the person $PERSON is still signed in by the session from before the update, and their message $MARK is served"
}

# The update's snapshot: complete, every file the person's, and its
# database copy whole, holding the person.
snapshot_readings() {
  local snapshot others copy
  snapshot="$(sed -nE 's/^Taking a snapshot into (.*)\.\.\.$/\1/p' "$PROOF/logs/update.log" | tail -n 1)"
  [ -n "$snapshot" ] && [ -f "$snapshot/snapshot.json" ] || fail "the update names no snapshot that holds a snapshot.json: '$snapshot'"
  [ "$(jget "$(cat "$snapshot/snapshot.json")" complete)" = true ] || fail "the snapshot $snapshot does not say complete"
  others="$(find "$snapshot" ! -user "$(id -u)" | head -n 5)"
  [ -z "$others" ] || fail "the snapshot holds files that are not the person's: $others"
  copy="$PROOF/snapshot-db"
  mkdir -p "$copy"
  cp "$snapshot/database" "$copy/database" || fail "the snapshot holds no database"
  [ ! -f "$snapshot/database-wal" ] || cp "$snapshot/database-wal" "$copy/database-wal"
  python3 -I - "$copy/database" "$PERSON" <<'PY' || fail "the snapshot's database is not whole or does not hold the person $PERSON"
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "integrity_check"
assert db.execute("SELECT count(*) FROM users WHERE id = ?", (sys.argv[2],)).fetchone()[0] == 1, "the person"
PY
  ok "the snapshot $snapshot is complete and the person's, its database passes integrity_check and holds the person"
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

mkdir -m 700 "$WORK"
# A person's usual umask, where the queue's is 077: what the run lays
# down for the install (the scaffold's aqua/ and guides among it) is
# readable by the server's user, as a person's install is.
umask 022
mkdir -p "$PROOF/logs" "$PROOF/home" "$PROOF/bin" "$RELEASES"
: >"$PROOF/candidate-pulls"

published=$(gh release list --repo cyfrworks/cyfr --exclude-drafts --limit 50 --json tagName,publishedAt \
  -q 'sort_by(.publishedAt) | reverse | .[].tagName') || missing "gh cannot list the published releases"
# shellcheck disable=SC2086
choice="$(old_side "$ROOT" HEAD $published)" || fail "the old side could not be chosen"
read -r OLD_KIND OLD_REF <<<"$(head -n 1 <<<"$choice")"
echo "update proof: $(sed -n 2p <<<"$choice")"

sweep_dead_runs
shim_install

TREE_VERSION="$(sed -n 's/^ *version: "\([^"]*\)",$/\1/p' "$ROOT/apps/prima/mix.exs" | head -n 1)"
versions="$(candidate_versions "$TREE_VERSION" "$RUN")" || exit 1
read -r OLD_VERSION NEW_VERSION <<<"$versions"

step "the new release $NEW_VERSION, made from this tree"
APP_IMAGE="$(cd "$ROOT" && scripts/image.sh --undated app)" || fail "this tree's app image did not build"
locus_image="$(cd "$ROOT" && scripts/image.sh --undated locus)" || fail "this tree's Locus image did not build"
release_build "ghcr.io/cyfrworks/cyfr:$NEW_VERSION" <<DOCKERFILE
FROM $APP_IMAGE
LABEL org.opencontainers.image.version=$NEW_VERSION
DOCKERFILE
release_tag "ghcr.io/cyfrworks/cyfr-locus:$NEW_VERSION" "$locus_image"
NEW_DIGEST="$(store_digest "ghcr.io/cyfrworks/cyfr:$NEW_VERSION")" || exit 1
NEW_LOCUS_DIGEST="$(store_digest "ghcr.io/cyfrworks/cyfr-locus:$NEW_VERSION")" || exit 1
mkdir -p "$RELEASES/$NEW_VERSION"
"$ROOT/scripts/scaffold-tarball.sh" "$RELEASES/$NEW_VERSION/cyfr-scaffold.tar.gz" "$NEW_VERSION" "$NEW_DIGEST" "$NEW_LOCUS_DIGEST" \
  >"$PROOF/logs/scaffold-new.log" 2>&1 || fail "the new release's scaffold did not build: $(tail -n 20 "$PROOF/logs/scaffold-new.log")"
schema="$(release_schema "ghcr.io/cyfrworks/cyfr:$NEW_VERSION")" || exit 1
[ "$schema" = "$(schema_of "$ROOT" HEAD)" ] || fail "the new release's image answers the schema $schema, not this tree's $(schema_of "$ROOT" HEAD)"
release_manifest "$RELEASES/$NEW_VERSION" "$NEW_VERSION" "$NEW_DIGEST" "$NEW_LOCUS_DIGEST" \
  "$(pinned_digest caddy "$ROOT/docker-compose.yml")" "$(pinned_digest tailscale/tailscale "$ROOT/docker-compose.yml")" "$schema"
release_cli "$ROOT/apps/codex" "$NEW_VERSION" "$RELEASES" "$NEW_CYFR"
printf '%s\n' "ghcr.io/cyfrworks/cyfr@$NEW_DIGEST" "ghcr.io/cyfrworks/cyfr-locus@$NEW_LOCUS_DIGEST" >"$PROOF/candidate-pulls"
ok "release $NEW_VERSION: cyfr ${NEW_DIGEST:7:12}, Locus ${NEW_LOCUS_DIGEST:7:12}, schema ${schema:0:12}"

if [ "$OLD_KIND" = release ]; then
  OLD_VERSION="$OLD_REF" OLD_SERVES="$OLD_REF"
  step "the old side, published release $OLD_VERSION, installed by its own install script"
  OLD_TREE="$PROOF/old-tree"
  git -C "$ROOT" worktree add -q --detach "$OLD_TREE" "refs/tags/$OLD_VERSION" || fail "no worktree of $OLD_VERSION"
  BASE_TREE="$OLD_TREE"
  mkdir -p "$RELEASES/$OLD_VERSION"
  gh release download "$OLD_VERSION" --repo cyfrworks/cyfr --dir "$RELEASES/$OLD_VERSION" \
    --pattern cyfr-scaffold.tar.gz --pattern install.sh || fail "release $OLD_VERSION's scaffold and install script did not download"
  env HOME="$PROOF/home" CYFR_VERSION="$OLD_VERSION" CYFR_INSTALL_DIR="$PROOF/bin/old" sh "$RELEASES/$OLD_VERSION/install.sh" \
    </dev/null >"$PROOF/logs/install.log" 2>&1 || fail "release $OLD_VERSION's install script failed: $(tail -n 20 "$PROOF/logs/install.log")"
  mv "$PROOF/bin/old/cyfr" "$OLD_CYFR"
  ok "installed $("$OLD_CYFR" --version 2>/dev/null | head -n 1)"
  tar -xzf "$RELEASES/$OLD_VERSION/cyfr-scaffold.tar.gz" -C "$PROOF" docker-compose.yml 2>/dev/null ||
    tar -xzf "$RELEASES/$OLD_VERSION/cyfr-scaffold.tar.gz" -C "$PROOF" ./docker-compose.yml || fail "release $OLD_VERSION's scaffold holds no docker-compose.yml"
  mv "$PROOF/docker-compose.yml" "$PROOF/old-compose.yml"
else
  step "the old side, $OLD_REF, built here as a release"
  OLD_TREE="$BASE_TREE"
  git -C "$ROOT" worktree add -q --detach "$OLD_TREE" "$OLD_REF" || fail "no worktree of $OLD_REF"
  old_app="$(cd "$OLD_TREE" && scripts/image.sh --undated app)" || fail "the old side's app image did not build"
  old_locus="$(cd "$OLD_TREE" && scripts/image.sh --undated locus)" || fail "the old side's Locus image did not build"
  release_tag "ghcr.io/cyfrworks/cyfr:$OLD_VERSION" "$old_app"
  release_tag "ghcr.io/cyfrworks/cyfr-locus:$OLD_VERSION" "$old_locus"
  old_digest="$(store_digest "ghcr.io/cyfrworks/cyfr:$OLD_VERSION")" || exit 1
  old_locus_digest="$(store_digest "ghcr.io/cyfrworks/cyfr-locus:$OLD_VERSION")" || exit 1
  [ "$(release_schema "ghcr.io/cyfrworks/cyfr:$OLD_VERSION")" = "$schema" ] ||
    fail "the old side's image answers another schema than the new release's"
  # The update reads the scaffold of the release the old image answers it
  # is (its tree's version) for what that release's .env.example shipped.
  OLD_SERVES="$(sed -n 's/^ *version: "\([^"]*\)",$/\1/p' "$OLD_TREE/apps/prima/mix.exs" | head -n 1)"
  mkdir -p "$RELEASES/$OLD_SERVES"
  (cd "$OLD_TREE" && scripts/scaffold-tarball.sh "$RELEASES/$OLD_SERVES/cyfr-scaffold.tar.gz" "$OLD_VERSION" "$old_digest" "$old_locus_digest") \
    >"$PROOF/logs/scaffold-old.log" 2>&1 || fail "the old side's scaffold did not build: $(tail -n 20 "$PROOF/logs/scaffold-old.log")"
  (cd "$OLD_TREE/apps/codex" && CGO_ENABLED=0 go build -mod=readonly -o "$OLD_CYFR" .) || fail "the old side's command line did not build"
  tar -xzf "$RELEASES/$OLD_SERVES/cyfr-scaffold.tar.gz" -C "$WORK" || fail "the old side's scaffold did not extract"
  cp "$WORK/docker-compose.yml" "$PROOF/old-compose.yml"
  ok "release $OLD_VERSION from ${OLD_REF:0:12} (its image answers $OLD_SERVES): cyfr ${old_digest:7:12}, Locus ${old_locus_digest:7:12}"
fi
cp "$ROOT/docker-compose.yml" "$PROOF/new-compose.yml"
fixed_names "$PROOF/old-compose.yml" >"$PROOF/fixed-old"
fixed_names "$PROOF/new-compose.yml" >"$PROOF/fixed-new"
grep -q '^name ' "$PROOF/fixed-new" || fail "no container name read from the new release's compose file"

step "the install, made with the old release's cyfr init, as a person makes it"
if [ "$OLD_KIND" = release ]; then
  cli_ok "$OLD_CYFR" init init --no-interactive
else
  # The base's images are in the image store alone, under its release tags.
  cli_ok "$OLD_CYFR" init init --no-interactive --no-pull
fi
port="$(run_names_free_port)" || fail "no free port for the install"
env_set CYFR_PORT "$port"
env_set CYFR_REGISTRY_URL 127.0.0.1:9
env_set CYFR_OCI_REGISTRY_URL 127.0.0.1:9
env_set CYFR_DIRECTORY_URL http://127.0.0.1:9
[ -n "$(env_value CYFR_LOCUS_BUILDS_KEY)" ] || env_set CYFR_LOCUS_BUILDS_KEY "$(openssl rand -hex 32)"
egress="$(env_value CYFR_PRIVATE_EGRESS_TARGETS)"
env_set CYFR_PRIVATE_EGRESS_TARGETS "${egress:+$egress,}fixture.test"
PROJECT="$(compose config --format json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["name"])')"
ok "the install's .env: port $port, builds on, the egress list the person's own ($(env_value CYFR_PRIVATE_EGRESS_TARGETS)); the project $PROJECT"

names_free "$PROOF/fixed-old" "$PROOF/fixed-new"
HELD_AT=$SECONDS
step "the old release up, holding the person's data"
cli_ok "$OLD_CYFR" up-old up
stack_healthy
before_services="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.service"}}' | sort | tr '\n' ' ')"
signed_in="$(fixture "$OLD_TREE" person update-proof)"
PERSON="$(jget "$signed_in" user_id)"
[ -n "$PERSON" ] && [ "$PERSON" != null ] || fail "the release fixture made nobody: '$signed_in'"
TOKEN="$(jget "$signed_in" token)"
MARK="update-proof-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
written="$(fixture "$OLD_TREE" thread "$PERSON" "$MARK")"
THREAD="$(jget "$written" thread_id)"
[ -n "$THREAD" ] && [ "$THREAD" != null ] || fail "the person's message was not written: '$written'"
ok "release $OLD_VERSION runs $before_services; the person $PERSON wrote $MARK"
program_make
build_runs "release $OLD_VERSION" "$OLD_TREE"

step "cyfr update to $NEW_VERSION, as the person"
update_status=0
cli "$NEW_CYFR" update update --continue-as "$NEW_VERSION" --yes || update_status=$?
cat "$PROOF/logs/update.log"
[ "$update_status" -eq 0 ] || fail "cyfr update exited $update_status"
follow_report
update_readings
program_reopened
build_runs "release $NEW_VERSION" "$ROOT"
snapshot_readings
ok "every reading of the update from $OLD_VERSION to $NEW_VERSION held"
