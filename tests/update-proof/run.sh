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
# each .env line it names gets the edit it says, then `cyfr up`. The
# readings are tests/update-proof/lib.sh's, each held to stand-ins by
# tests/update-proof/lib-test.sh. Then:
#
#   - every service the new file declares (under every profile but the
#     access proxies', public and tailnet, which a local install never
#     starts) has a container, running, healthy where it has a health
#     check, none restarted; the project holds no container of a service
#     the file does not declare and no network it does not use; and cyfr
#     runs the new release's image, which the compose file names by its
#     digest;
#   - the report's advice: every line it names comes with an edit a person
#     can follow, and the egress line, when it names a service the update
#     retires, gets advice naming the host the new release ships for it,
#     and followed holds exactly what it must (the three-container start's
#     locus-backends,fixture.test becomes locus,fixture.test); a line that
#     names none gets no advice and stays as it was;
#   - the update's sentences: it updated to the new release, printed no
#     FATAL line, and the containers and networks it says it removed are
#     exactly what the proof's inventory before the update held and the
#     one after does not;
#   - the person is still signed in by the session from before the update,
#     under which their thread reads exactly their one message; the
#     program, started again, finds its file in its kept home, the home
#     and the file owned by the uid it ran as before; a build of its own
#     (not the first one's record) compiles;
#   - the update's snapshot says it is complete, holds every part its
#     manifest lists, each there and not empty, every file of it is the
#     person's, and its database copy passes PRAGMA integrity_check and
#     holds the person's row.
#
# The stack's fixed names and subnets: the shipped file names its
# containers (cyfr, cyfr-locus, ...) and fixes its networks' subnets, and
# an overlay cannot follow the update's switch of the file, so the run
# holds them, as a person's install does. Before the old release's first
# `cyfr up` it looks: another project's container of a name either
# release's file fixes, or a network whose subnet overlaps one either
# fixes (Docker refuses an overlapping pool), ends the run with 69 (not
# run), naming what holds it, before anything starts; and a start that
# fails later is looked at once more, ending 69 when a holder is there
# then and red when none is. It holds them from that `cyfr up` until its
# teardown and prints how long as `held: <n>s`.
# Everything else is the run's own: the project, its networks and volumes
# (named from the project, which its folder names), the folder
# /var/tmp/cyfr/<RUN> and the release tags (<repository>:<version>, the
# version carrying RUN). The teardown takes it all down on every exit, in
# the order of what depends on what: the project's containers, networks
# and volumes by the project's label (a listing that fails is nothing
# known gone), the release tags, the old side's worktree, and only once
# those are known gone the folder, whose data/ the server's container owns
# and gives back through a container of the app image first. A teardown
# that fails keeps the folder, says so and is red, whatever the run came
# to. A run killed past its trap leaves its folder, from which the next
# run's start sweeps its project by the project's label and its tags by
# their version.
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
# shellcheck source=tests/update-proof/lib.sh
. "$HERE/lib.sh"

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

cleanup() {
  local code=$? id torn
  trap '' INT TERM
  if [ "$code" -ne 0 ] && [ -n "$PROJECT" ]; then
    echo "----- the project's containers -----" >&2
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}} {{.Status}}' >&2 || true
    for id in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=cyfr" 2>/dev/null); do
      echo "----- the last lines of cyfr's log -----" >&2
      docker logs --tail 120 "$id" 2>&1 | cut -c1-400 >&2 || true
    done
  fi
  torn=0
  teardown "$PROJECT" "$WORK" "$APP_IMAGE" "$OLD_TREE" ${RELEASE_IMAGES[@]+"${RELEASE_IMAGES[@]}"} || torn=$?
  code="$(exit_status "$code" "$torn")"
  if [ -n "$HELD_AT" ]; then
    echo "held: $((SECONDS - HELD_AT))s"
    echo "the fixed names and subnets were held from the old release's first start to the teardown's end"
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# What a run killed before its teardown left: a folder under the run root
# named for a run whose pid is gone, its project's containers, networks and
# volumes by the project's label, its release tags, and the folder itself.
sweep_dead_runs() {
  local dir run base pid project tags
  for dir in "$TMP_ROOT"/*update-proof-*; do
    [ -d "$dir" ] && [ -O "$dir" ] && [ "$dir" != "$WORK" ] || continue
    run=${dir##*/} base=${dir##*/}
    if [[ $base =~ $RUN_NAMES_PATTERN ]]; then base=${base:${#BASH_REMATCH[0]}}; fi
    [[ $base =~ ^update-proof-([0-9]+)-[0-9a-f]{8}$ ]] || continue
    pid=${BASH_REMATCH[1]}
    ! ps -p "$pid" >/dev/null 2>&1 || continue
    project="$(project_name "$run")"
    tags="$(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter 'reference=ghcr.io/cyfrworks/*' | grep -F -- "-$run." || true)"
    # shellcheck disable=SC2086
    if teardown "$project" "$dir" "$(fallback_image)" "" $tags; then
      echo "removed $dir and its project $project, left by the run $pid, which is gone"
    else
      echo "::warning::update proof: could not remove what the run $pid left ($dir, the project $project)" >&2
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

# Who holds a name or subnet either compose file fixes, the project's own
# aside (holders, tests/update-proof/lib.sh).
fixed_holders() {
  holders <(sort -u "$PROOF/fixed-old" "$PROOF/fixed-new") \
    "$(docker ps -a --format '{{.Names}} {{.Label "com.docker.compose.project"}} {{.Status}}')" "$(network_subnets)" "$PROJECT"
}

# Nothing holds a name or subnet the stack fixes: otherwise the run ends
# here with 69, naming the holder.
names_free() {
  local held
  held="$(fixed_holders)" || fail "who holds the stack's fixed names and subnets could not be read"
  [ -z "$held" ] || missing "$(head -n 1 <<<"$held")"
  ok "no container holds a name the stack fixes, and no network a subnet it fixes"
}

# The project's containers, `SERVICE=STATE/STATUS` one a line, sorted.
states() {
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.Label "com.docker.compose.service"}}={{.State}}/{{.Status}}' | sort
}

# Every service the compose file `$1` declares under the profiles a local
# install runs has a container, running, healthy where it has a health
# check, within 180 s, and the project holds none of a service it does not
# declare: cyfr's container in cyfr_id. A local install runs every profile
# of the file but the access proxies' (public, tailnet), which builds on
# (the old releases' locus-builds) makes true of this one.
stack_healthy() {
  local closes=$((SECONDS + 180)) declared now why profiles=() profile
  for profile in $(docker compose -f "$1" --project-directory "$WORK" config --profiles); do
    case "$profile" in public | tailnet) ;; *) profiles+=(--profile "$profile") ;; esac
  done
  declared="$(compose ${profiles[@]+"${profiles[@]}"} config --services | sort)"
  now="$(states)" || fail "the project's containers could not be listed"
  why="$(undeclared "$declared" "$now")" || fail "$why"
  while :; do
    now="$(states)" || fail "the project's containers could not be listed"
    if why="$(all_running "$declared" "$now")"; then break; fi
    [ "$SECONDS" -lt "$closes" ] || fail "after 180 s $why: $(tr '\n' ' ' <<<"$now")"
    sleep 2
  done
  cyfr_id="$(compose ps -q cyfr)"
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
# that write and read the file `mark` in its home and answer the uid it
# runs as, the home, the owners of the home and of the file as the
# filesystem gives them, and the file's bytes. No backslash, so each
# quoting layer passes it.
# shellcheck disable=SC2016
PROGRAM_COMMAND='node -e '\''const fs=require("fs"),NL=String.fromCharCode(10);let b="";const s=m=>process.stdout.write(JSON.stringify(m)+NL);process.stdin.on("data",c=>{b+=c;let i;while((i=b.indexOf(NL))>=0){const l=b.slice(0,i).trim();b=b.slice(i+1);if(!l)continue;const m=JSON.parse(l);if(m.id==null)continue;const r=x=>s({jsonrpc:"2.0",id:m.id,result:x});if(m.method==="initialize")r({protocolVersion:"2025-03-26",capabilities:{tools:{}},serverInfo:{name:"kept",version:"0"}});else if(m.method==="tools/list")r({tools:["write","read"].map(n=>({name:n,description:n,inputSchema:{type:"object"}}))});else if(m.method==="tools/call"){const h=process.env.HOME,f=h+"/mark";if(m.params.name==="write")fs.writeFileSync(f,String(m.params.arguments.mark));let t=null,o=null;try{t=fs.readFileSync(f,"utf8");o=fs.statSync(f).uid}catch(e){}r({content:[{type:"text",text:JSON.stringify({uid:process.getuid(),home:h,home_owner:fs.statSync(h).uid,mark:t,mark_owner:o})}]})}else s({jsonrpc:"2.0",id:m.id,error:{code:-32601,message:"unknown"}})}})'\'
PROGRAM_UID="" PROGRAM_HOME=""

# The person's program, its home kept, made through the console as Prism
# makes one (a definition the person's device confirms), and the file
# written into its home.
program_make() {
  local args made said why
  fill_ready
  args="$(python3 -I -c 'import json, sys; print(json.dumps({"action": "create", "name": "update-proof-kept", "config": {"transport": "program", "mark": "mcp", "home": "kept", "console": True, "command": sys.argv[1], "env": {}}}))' "$PROGRAM_COMMAND")"
  made="$(until_ok 60 "$OLD_TREE" confirmed "$TOKEN" mcp_servers "$args")" || exit 1
  [ "$(jget "$made" ok home)" = kept ] || fail "the program was not made with its home kept: $made"
  said="$(program_call write "$OLD_TREE" "{\"mark\":\"$MARK\"}")" || exit 1
  PROGRAM_UID="$(jget "$said" uid)" PROGRAM_HOME="$(jget "$said" home)"
  [[ $PROGRAM_UID =~ ^[0-9]+$ ]] && [ "$PROGRAM_UID" -ne 0 ] || fail "the program runs under no uid of its own: $said"
  why="$(kept_home "$said" "$PROGRAM_HOME" "$MARK" "$PROGRAM_UID")" || fail "before the update, $why"
  ok "the program update-proof-kept wrote $MARK into its kept home $PROGRAM_HOME, home and file owned by uid $PROGRAM_UID, its own"
}

# The program started again by the new release finds its file in its home
# under the uid it had.
program_reopened() {
  local said why
  said="$(program_call read "$ROOT" '{}')" || exit 1
  why="$(kept_home "$said" "$PROGRAM_HOME" "$MARK" "$PROGRAM_UID")" || fail "after the update, $why"
  ok "the program, started again by release $NEW_VERSION, reads $MARK in $PROGRAM_HOME, home and file owned by uid $PROGRAM_UID as before"
}

# A build through the builds role, as `cyfr new tincture --template vite`
# and `cyfr build compile` make one: the component made once, by the old
# release, then compiled by the release `$1` names, the fixture of the
# tree `$2`.
BUILD_REF="tincture:local.update-proof-build:0.1.0"
FIRST_BUILD=""
build_runs() {
  local tree="$2" started id status closes why
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
  if [ -z "$FIRST_BUILD" ]; then
    FIRST_BUILD="$id"
  else
    why="$(another_build "$FIRST_BUILD" "$id" "$status")" || fail "$why"
  fi
  ok "$1 built $BUILD_REF through the builds role ($id)"
}

# ---------------------------------------------------------------------------
# The readings after the update
# ---------------------------------------------------------------------------

# The update's report read and followed as a person follows it: it is sane
# (report_sane, tests/update-proof/lib.sh), knowing what the egress line
# must become (EGRESS_BEFORE to EGRESS_WANT); each .env line it names gets
# the edit it says (that service's name replaced by the host it gives,
# the rest of the line kept), then `cyfr up`; and the egress line then
# holds exactly what it must.
follow_report() {
  local edits why at key host put line
  why="$(report_sane "$PROOF/logs/update.log" "$EGRESS_BEFORE" "$EGRESS_WANT")" || fail "$why"
  edits="$(report_edits "$PROOF/logs/update.log")"
  if [ -z "$edits" ]; then
    ok "the update names no .env line to change"
  else
    while read -r at key host put; do
      line="$(sed -n "${at}p" "$WORK/.env")"
      [[ $line == "$key="* ]] || fail "the update names line $at of .env as $key, and that line is: ${line%%=*}"
      grep -qE "(^|[^a-z0-9-])$host([^a-z0-9-]|$)" <<<"${line#*=}" || fail "the update says line $at ($key) names $host, and it does not"
      python3 -I -c "$ENV_EDIT" "$WORK/.env" "$at" "$host" "$put" || fail "line $at of .env could not be edited"
      ok "followed the report: $key (line $at), $put in place of $host"
    done <<<"$edits"
    start "$NEW_CYFR" up-after-edits up
  fi
  [ "$(env_value CYFR_PRIVATE_EGRESS_TARGETS)" = "$EGRESS_WANT" ] ||
    fail "after the report was followed the egress line holds $(env_value CYFR_PRIVATE_EGRESS_TARGETS), not $EGRESS_WANT"
  ok "the egress line holds $EGRESS_WANT, as it must"
}
# The edit of one .env line: the host named replaced by what to put, each
# where it stands as a whole name, the rest of the line kept.
ENV_EDIT='import re, sys
path, at, host, put = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
lines = open(path).read().split("\n")
key, value = lines[at - 1].split("=", 1)
lines[at - 1] = key + "=" + re.sub(r"(?<![a-z0-9-])" + re.escape(host) + r"(?![a-z0-9-])", put, value)
with open(path, "r+") as f:
    f.truncate(0)
    f.write("\n".join(lines))
'

# What the project's networks are, one a line, sorted.
project_networks() {
  docker network ls --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.network"}}' | sort
}

# The services the compose file `$1` declares under every profile, one a
# line, sorted.
services_of() {
  docker compose -f "$1" --project-directory "$WORK" --profile '*' config --services | sort
}

# What the update left running: the project's services against the new
# file, its networks, its images, the update's own sentences against the
# proof's inventories, and the person's message through their session.
update_readings() {
  local networks used containers name image want running restarts why answer
  stack_healthy "$PROOF/new-compose.yml"
  containers="$(states | cut -d= -f1)"
  for name in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"); do
    restarts="$(docker inspect --format '{{.Name}} {{.RestartCount}}' "$name")"
    [ "${restarts##* }" = 0 ] || fail "after the update ${restarts% *} restarted ${restarts##* } times"
  done
  ok "release $NEW_VERSION runs $(tr '\n' ' ' <<<"$containers")each declared service healthy or running, none restarted, none of a service it does not declare"
  used="$(compose config --format json | python3 -I -c '
import json, sys
project = json.load(sys.stdin)
print("\n".join(sorted({n for s in project["services"].values() for n in (s.get("networks") or {})})))')"
  networks="$(project_networks)" || fail "the project's networks could not be listed"
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
  why="$(removed_as_said "Removed this project's containers of services" "$PROOF/logs/update.log" "$BEFORE_SERVICES" "$containers" "containers of")" || fail "$why"
  why="$(removed_as_said "Removed this project's networks" "$PROOF/logs/update.log" "$BEFORE_NETWORKS" "$networks" networks)" || fail "$why"
  ok "the update's sentences hold: it updated to $NEW_VERSION, and what it says it removed is what was there before and is gone after"

  # The session the person signed in with before the update: a person
  # stays signed in across it, and the message is read under it.
  answer="$(fixture "$ROOT" session_thread_read "$TOKEN" "$THREAD")"
  why="$(thread_as_said "$answer" "$PERSON" "$MARK")" || fail "after the update $why"
  ok "the person $PERSON is still signed in by the session from before the update, under which their thread reads exactly [$MARK]"
}

# The update's snapshot: complete, every file the person's, and its
# database copy whole, holding the person.
snapshot_readings() {
  local snapshot others copy why
  snapshot="$(sed -nE 's/^Taking a snapshot into (.*)\.\.\.$/\1/p' "$PROOF/logs/update.log" | tail -n 1)"
  [ -n "$snapshot" ] && [ -f "$snapshot/snapshot.json" ] || fail "the update names no snapshot that holds a snapshot.json: '$snapshot'"
  [ "$(jget "$(cat "$snapshot/snapshot.json")" complete)" = true ] || fail "the snapshot $snapshot does not say complete"
  why="$(snapshot_parts "$snapshot")" || fail "$why"
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
  ok "the snapshot $snapshot holds every part its manifest lists ($(jget "$(cat "$snapshot/snapshot.json")" parts)), every file the person's, its database passes integrity_check and holds the person"
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
# What the egress line must become: each service the update retires (one
# the old file runs and the new one does not) replaced by the host the new
# release ships for the setting.
EGRESS_BEFORE="$(env_value CYFR_PRIVATE_EGRESS_TARGETS)"
retired="$(comm -23 <(services_of "$PROOF/old-compose.yml") <(services_of "$PROOF/new-compose.yml"))"
shipped="$(NAME=CYFR_PRIVATE_EGRESS_TARGETS awk 'index($0, ENVIRON["NAME"] "=") == 1 { print substr($0, length(ENVIRON["NAME"]) + 2) }' "$ROOT/.env.example" | tail -n 1)"
[ -n "$shipped" ] || fail "release $NEW_VERSION's .env.example ships no CYFR_PRIVATE_EGRESS_TARGETS"
EGRESS_WANT="$(expected_egress "$EGRESS_BEFORE" "$retired" "$shipped")"
PROJECT="$(compose config --format json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["name"])')"
ok "the install's .env: port $port, builds on, the egress list the person's own ($EGRESS_BEFORE, which the update's advice must make $EGRESS_WANT); the project $PROJECT"

names_free "$PROOF/fixed-old" "$PROOF/fixed-new"
HELD_AT=$SECONDS
step "the old release up, holding the person's data"
start "$OLD_CYFR" up-old up
stack_healthy "$PROOF/old-compose.yml"
signed_in="$(fixture "$OLD_TREE" person update-proof)"
PERSON="$(jget "$signed_in" user_id)"
[ -n "$PERSON" ] && [ "$PERSON" != null ] || fail "the release fixture made nobody: '$signed_in'"
TOKEN="$(jget "$signed_in" token)"
MARK="update-proof-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
written="$(fixture "$OLD_TREE" thread "$PERSON" "$MARK")"
THREAD="$(jget "$written" thread_id)"
[ -n "$THREAD" ] && [ "$THREAD" != null ] || fail "the person's message was not written: '$written'"
ok "release $OLD_VERSION runs $(states | cut -d= -f1 | tr '\n' ' ')and the person $PERSON wrote $MARK"
program_make
build_runs "release $OLD_VERSION" "$OLD_TREE"

step "cyfr update to $NEW_VERSION, as the person"
BEFORE_SERVICES="$(states | cut -d= -f1)" || fail "the project's containers could not be listed"
BEFORE_NETWORKS="$(project_networks)" || fail "the project's networks could not be listed"
start "$NEW_CYFR" update update --continue-as "$NEW_VERSION" --yes
cat "$PROOF/logs/update.log"
follow_report
update_readings
program_reopened
build_runs "release $NEW_VERSION" "$ROOT"
snapshot_readings
ok "every reading of the update from $OLD_VERSION to $NEW_VERSION held"
