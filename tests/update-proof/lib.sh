# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The update proof's readings and teardown (tests/update-proof/run.sh),
# sourced by it and by their stand-in cases (tests/update-proof/lib-test.sh).
# A reading takes what the run read as its arguments: it answers 0, or 1
# with the reason on stdout, which the run fails with. The teardown's
# functions call `docker`, which the stand-in cases define.

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
# The stack's fixed names and subnets
# ---------------------------------------------------------------------------

# Who holds what the stack fixes: `$1` holds its `name NAME` and `subnet
# CIDR` lines, `$2` the daemon's containers (`NAME PROJECT STATUS`, one a
# line) and `$3` its networks (`NAME CIDR...`). A container of the fixed
# name and a network whose subnet overlaps a fixed one hold it, as Docker
# refuses an overlapping pool; what the project `$4` holds is its own.
# Prints one sentence per holder.
holders() {
  python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import ipaddress, sys
fixed, containers, networks, project = open(sys.argv[1]).read().split("\n"), sys.argv[2], sys.argv[3], sys.argv[4]
names = {l.split()[1] for l in fixed if l.startswith("name ")}
subnets = [ipaddress.ip_network(l.split()[1], strict=False) for l in fixed if l.startswith("subnet ")]
for line in containers.splitlines():
    parts = line.split(" ", 2)
    if len(parts) >= 2 and parts[0] in names and parts[1] != project:
        print(f"the container name {parts[0]}, which the stack fixes, is held by the container {line}")
for line in networks.splitlines():
    parts = line.split()
    if not parts or (project and parts[0].startswith(project + "_")):
        continue
    for cidr in parts[1:]:
        try:
            held = ipaddress.ip_network(cidr, strict=False)
        except ValueError:
            continue
        for subnet in subnets:
            if held.version == subnet.version and held.overlaps(subnet):
                print(f"the subnet {subnet}, which the stack fixes, is held by the network {parts[0]} ({cidr})")
PY
}

# ---------------------------------------------------------------------------
# The services after the update
# ---------------------------------------------------------------------------

# Every container of the project is of a declared service: `$1` the
# declared services, `$2` the project's containers as `SERVICE=STATE/STATUS`.
undeclared() {
  local line service
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    service=${line%%=*}
    grep -qxF -- "$service" <<<"$1" || { echo "the project holds a container of $service, a service the file does not declare: $line"; return 1; }
  done <<<"$2"
}

# Every declared service (`$1`) has a container (`$2`, as above) that runs,
# healthy where it has a health check.
all_running() {
  local service state
  while IFS= read -r service; do
    [ -n "$service" ] || continue
    state="$(grep -E "^$service=" <<<"$2" | head -n 1)"
    [ -n "$state" ] || { echo "the declared service $service has no container"; return 1; }
    grep -qE '=running/(.*\(healthy\)|Up [^()]*)$' <<<"$state" || { echo "the declared service $service is not running healthy: $state"; return 1; }
  done <<<"$1"
}

# What the update says it removed, the names of the sentence starting
# `$1` in the log `$2`, is exactly what `$3` (before) held and `$4`
# (after) does not, as sorted names one a line; `$5` names the kind.
removed_as_said() {
  local said gone
  said="$(sed -nE "s/^$1 release [^ ]+ does not (run|use): (.*)\.$/\2/p" "$2" | tr ',' '\n' | sed 's/^ *//' | grep . | sort -u)"
  gone="$(comm -23 <(grep . <<<"$3" | sort -u) <(grep . <<<"$4" | sort -u))"
  [ "$said" = "$gone" ] || { echo "the update says it removed the $5 '$(tr '\n' ' ' <<<"$said")', and what was there before and is gone after is '$(tr '\n' ' ' <<<"$gone")'"; return 1; }
}

# ---------------------------------------------------------------------------
# The report's .env advice
# ---------------------------------------------------------------------------

# The value the egress setting `$1` (a comma list) must hold once the
# update's advice is followed: each item naming a service of `$2` (the
# services the update retires, one a line) replaced by `$3`, the host the
# new release ships for the setting, the rest kept in its place.
expected_egress() {
  local item out=()
  IFS=',' read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    if grep -qxF -- "$item" <<<"$2"; then out+=("$3"); else out+=("$item"); fi
  done
  (IFS=','; printf '%s\n' "${out[*]}")
}

# The advice the log `$1` gives for .env lines, one `LINE KEY HOST PUT` a
# line, each in the one form a person can follow: the host named, what
# to put in its place, and the rest of the line kept.
report_edits() {
  sed -nE 's/^  ([A-Z0-9_]+), line ([0-9]+), names ([a-z0-9-]+): put ([a-z0-9.-]+) in place of \3 in (its URL, keeping the rest of the line as it is|that line, keeping the rest of it as it is)$/\2 \1 \3 \4/p' "$1"
}

# The report in the log `$1` is sane: every line it names comes with an
# edit a person can follow, and it says what cannot work until they are
# made exactly when it names one; and for the egress setting, whose value
# before the update was `$2` and must become `$3`, the advice is there and
# names each retired host and its replacement when they differ, and is
# not when they are the same.
report_sane() {
  local named edits closing egress want
  named="$(grep -E '^  [A-Z0-9_]+, line [0-9]+, names [a-z0-9-]+: ' "$1" || true)"
  edits="$(report_edits "$1")"
  if [ "$(grep -c . <<<"$named")" != "$(grep -c . <<<"$edits")" ]; then
    echo "the update names .env lines whose advice is no edit a person can follow: $(grep -vE ': put [a-z0-9.-]+ in place of [a-z0-9-]+ in (its URL, keeping the rest of the line as it is|that line, keeping the rest of it as it is)$' <<<"$named" | head -n 3)"
    return 1
  fi
  closing="$(grep -c -E "^Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach " "$1" || true)"
  if [ -n "$edits" ] && [ "$closing" != 1 ]; then echo "the update names .env lines to change and does not say what cannot work until they are"; return 1; fi
  if [ -z "$edits" ] && [ "$closing" != 0 ]; then echo "the update says CYFR cannot reach a host until lines are changed, and names no line to change"; return 1; fi
  egress="$(awk '$2 == "CYFR_PRIVATE_EGRESS_TARGETS" { print $3 " " $4 }' <<<"$edits" | sort -u)"
  want="$(python3 -I -c '
import sys
before, after = sys.argv[1].split(","), sys.argv[2].split(",")
print("\n".join(sorted({b + " " + a for b, a in zip(before, after) if b != a})))' "$2" "$3")"
  [ "$egress" = "$want" ] || { echo "for CYFR_PRIVATE_EGRESS_TARGETS ($2, to become $3) the update advises '$(tr '\n' ';' <<<"$egress")', not '$(tr '\n' ';' <<<"$want")'"; return 1; }
  if [ -n "$want" ]; then
    grep -E "^Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach " "$1" | grep -qwF -- "$(cut -d ' ' -f 2 <<<"$want" | head -n 1)" ||
      { echo "the update's closing sentence does not name $(cut -d ' ' -f 2 <<<"$want" | head -n 1), which CYFR cannot reach until the egress line is changed"; return 1; }
  fi
}

# ---------------------------------------------------------------------------
# The person's things
# ---------------------------------------------------------------------------

# The program's answer `$1` (its uid, home, the owners of its home and of
# the marker as the filesystem gives them, and the marker's bytes) holds
# the home `$2`, the marker `$3` and the uid `$4` throughout.
kept_home() {
  local field
  [ "$(jget "$1" home)" = "$2" ] || { echo "the program's home is $(jget "$1" home), not $2"; return 1; }
  [ "$(jget "$1" mark)" = "$3" ] || { echo "the program's home holds '$(jget "$1" mark)', not $3"; return 1; }
  for field in uid home_owner mark_owner; do
    [ "$(jget "$1" "$field")" = "$4" ] || { echo "the program's $field is $(jget "$1" "$field"), not $4"; return 1; }
  done
}

# The fixture's read of the thread under the person's session (`$1`,
# session_thread_read) is that person's (`$2`) and reads exactly the one
# message `$3`.
thread_as_said() {
  [ "$(jget "$1" user_id)" = "$2" ] || { echo "the person's session opens as '$(jget "$1" user_id)', not $2: $1"; return 1; }
  [ "$(jget "$1" contents)" = "$(python3 -I -c 'import json, sys; print(json.dumps([sys.argv[1]]))' "$3")" ] ||
    { echo "under the person's session their thread reads $(jget "$1" contents), not exactly [\"$3\"]"; return 1; }
}

# The build after the update (`$2`, its status `$3`) is another than the
# one before it (`$1`), and compiled.
another_build() {
  [ -n "$2" ] && [ "$2" != null ] && [ "$2" != "$1" ] || { echo "the build after the update is '$2', not a build of its own (the first was $1)"; return 1; }
  [ "$3" = compiled ] || { echo "the build $2 after the update reads '$3', not compiled"; return 1; }
}

# The snapshot folder `$1` holds every part its manifest lists, each there
# and not empty: a file of some bytes, a folder holding something.
snapshot_parts() {
  local part path
  for part in $(python3 -I -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))["parts"]))' "$1/snapshot.json"); do
    path="$1/$part"
    if [ -d "$path" ]; then
      [ -n "$(ls -A "$path")" ] || { echo "the snapshot's part $part is an empty folder"; return 1; }
    else
      [ -s "$path" ] || { echo "the snapshot's part $part, which its manifest lists, is missing or empty"; return 1; }
    fi
  done
}

# A start, the command line's run `cli $@`, that fails is looked at once
# more: a holder of a name or subnet the stack fixes there now
# (fixed_holders) ends the run with 69 (missing), naming it; otherwise the
# failure is red (fail). The caller defines the four.
start() {
  local status=0 held
  cli "$@" || status=$?
  [ "$status" -ne 0 ] || return 0
  held="$(fixed_holders)" || held=""
  [ -z "$held" ] || missing "cyfr ${*:3} failed while $(head -n 1 <<<"$held")"
  fail "cyfr ${*:3} exited $status: $(tail -n 30 "$PROOF/logs/$2.log" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# The teardown
# ---------------------------------------------------------------------------

# The run's exit status once its teardown is done: the run's own `$1`, but
# a teardown that failed (`$2` not 0) is red, never passed or not run.
exit_status() {
  if [ "$2" -ne 0 ] && { [ "$1" -eq 0 ] || [ "$1" -eq 69 ]; }; then echo 1; else echo "$1"; fi
}

# Runs the command after `$1`, its description, until it succeeds, at most
# three times, 3 s apart (UPDATE_PROOF_PAUSE); a third failure is named.
removal() {
  local what="$1" attempt err=""
  shift
  for attempt in 1 2 3; do
    if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
    [ "$attempt" = 3 ] || sleep "${UPDATE_PROOF_PAUSE:-3}"
  done
  echo "::error::update proof teardown: $what failed three times: ${err:0:600}" >&2
  return 1
}

# What the project `$1` holds on the daemon, by its label: containers,
# then networks, then volumes, each removed. A listing that fails is
# nothing known gone.
project_gone() {
  local project="$1" id ids kind failed=""
  for kind in container network volume; do
    case "$kind" in
      container) ids="$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ;;
      network) ids="$(docker network ls -q --filter "label=com.docker.compose.project=$project")" ;;
      volume) ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$project")" ;;
    esac || { echo "::error::update proof teardown: the project $project's ${kind}s could not be listed" >&2; return 1; }
    for id in $ids; do
      case "$kind" in
        container) removal "docker rm --force $id" docker rm --force --volumes "$id" || failed=1 ;;
        network) removal "docker network rm $id" docker network rm "$id" || failed=1 ;;
        volume) removal "docker volume rm $id" docker volume rm "$id" || failed=1 ;;
      esac
    done
  done
  [ -z "$failed" ]
}

# The release tags `$@` removed; one not there is gone already.
tags_gone() {
  local made failed=""
  for made in "$@"; do
    docker image inspect "$made" >/dev/null 2>&1 || continue
    removal "docker image rm $made" docker image rm "$made" || failed=1
  done
  [ -z "$failed" ]
}

# The folder `$1` given back to this user through a container of the image
# `$2` (data/ is the server's), then removed.
folder_gone() {
  [ -d "$1" ] || return 0
  if [ -e "$1/data" ]; then
    removal "taking $1 back from the image's user" docker run --rm --name "${RUN:-update-proof}-chown-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" \
      --network none --user 0 --volume "$1:/work" --entrypoint chown "$2" -R "$(id -u):$(id -g)" /work || return 1
  fi
  removal "removing $1" rm -rf "$1"
}

# The run's teardown, in the order of what depends on what: the project
# (`$1`, when set), then the release tags (`$5...`), then the run's
# worktree `$4` (of the checkout ROOT), and only once all of those are
# known gone, the run folder `$2`, given back through the app image `$3`. A step that fails keeps the
# folder, which names the run for the next run's sweep, and says so.
# Answers 1 when anything is left.
teardown() {
  local project="$1" folder="$2" image="$3" tree="$4" failed=""
  shift 4
  if [ -n "$project" ]; then project_gone "$project" || failed=1; fi
  tags_gone "$@" || failed=1
  if [ -n "$tree" ] && [ -d "$tree" ]; then
    git -C "$ROOT" worktree remove --force "$tree" >/dev/null 2>&1 || removal "removing the worktree $tree" rm -rf "$tree" || failed=1
    git -C "$ROOT" worktree prune || true
  fi
  if [ -n "$failed" ]; then
    echo "::error::update proof teardown: $folder is kept, since what the run made is not known gone; the next run's start sweeps it" >&2
    return 1
  fi
  folder_gone "$folder" "$image"
}
