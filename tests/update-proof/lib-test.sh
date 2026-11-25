#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The update proof's readings and teardown (tests/update-proof/lib.sh) on
# stand-ins: for each, what a broken update or a failed teardown shows it,
# which it must answer red, beside what a sound one shows, which it must
# pass. docker is a function of this file's, so nothing reaches a daemon.
#
# Usage: bash tests/update-proof/lib-test.sh
# Exits 0 when every case held, 1 otherwise.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=tests/update-proof/lib.sh
. "$HERE/lib.sh"

S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
UPDATE_PROOF_PAUSE=0
failures=0
# passes WHAT COMMAND...: the reading passes. red WHAT COMMAND...: it is red.
passes() {
  local what="$1" out
  shift
  if out="$("$@" 2>&1)"; then echo "ok: $what"; else echo "FAIL: $what: answered red: $out"; failures=$((failures + 1)); fi
}
red() {
  local what="$1" out
  shift
  if out="$("$@" 2>&1)"; then echo "FAIL: $what: passed"; failures=$((failures + 1)); else echo "ok: $what (red: ${out:0:160})"; fi
}

# 1. Every declared service has a container, running and healthy.
declared=$'cyfr\nlocus\nlocus-guard'
healthy=$'cyfr=running/Up 2 minutes (healthy)\nlocus=running/Up 2 minutes (healthy)\nlocus-guard=running/Up 2 minutes (healthy)'
passes "every declared service running healthy passes" all_running "$declared" "$healthy"
red "a declared service with no container is red" all_running "$declared" 'cyfr=running/Up 2 minutes (healthy)'
red "a declared service that exited is red" all_running "$declared" $'cyfr=running/Up 2 minutes (healthy)\nlocus=exited/Exited (0) 1 minute ago\nlocus-guard=running/Up 2 minutes (healthy)'
red "a declared service still starting is red" all_running "$declared" $'cyfr=running/Up 9 seconds (health: starting)\nlocus=running/Up 2 minutes (healthy)\nlocus-guard=running/Up 2 minutes (healthy)'
red "a container of a service the file does not declare is red" undeclared "$declared" "$healthy"$'\nlocus-builds=exited/Exited (0) 1 minute ago'

# 2. The egress advice: there, naming the replacement, and followed it
# leaves exactly the expected setting.
check_value() { [ "$1" = "$2" ] || { echo "'$1', not '$2'"; return 1; }; }
retired=$'locus-backends\nlocus-backends-guard\nlocus-builds\nlocus-builds-guard\nlocus-runtime'
passes "the three-container start's egress line must become locus,fixture.test" \
  check_value "$(expected_egress locus-backends,fixture.test "$retired" locus)" locus,fixture.test
passes "an egress line naming no retired service stays as it is" \
  check_value "$(expected_egress locus,fixture.test "$retired" locus)" locus,fixture.test
report() { printf '%s\n' "$@" >"$S/update.log"; }
closing="Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach locus."
advice='  CYFR_PRIVATE_EGRESS_TARGETS, line 35, names locus-backends: put locus in place of locus-backends in that line, keeping the rest of it as it is'
report "$advice" "$closing" 'Updated to release 9.9.9.'
passes "the advice that names the replacement, with its closing sentence, passes" report_sane "$S/update.log" locus-backends,fixture.test locus,fixture.test
report 'Updated to release 9.9.9.'
red "no advice where the egress line names a retired service is red" report_sane "$S/update.log" locus-backends,fixture.test locus,fixture.test
report '  CYFR_PRIVATE_EGRESS_TARGETS, line 35, names locus-backends: put nowhere in place of locus-backends in that line, keeping the rest of it as it is' \
  "Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach nowhere."
red "advice naming another replacement is red" report_sane "$S/update.log" locus-backends,fixture.test locus,fixture.test
report '  CYFR_PRIVATE_EGRESS_TARGETS, line 35, names locus-backends: put locus in place of locus-backends in that line, keeping only the first item' "$closing"
red "advice that keeps less than the rest of the line is red" report_sane "$S/update.log" locus-backends,fixture.test locus,fixture.test
report "$advice" "Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach elsewhere."
red "a closing sentence that names another host is red" report_sane "$S/update.log" locus-backends,fixture.test locus,fixture.test
report '  CYFR_PRIVATE_EGRESS_TARGETS, line 35, names locus-backends: write locus there' "$closing"
red "the old 'write locus there' advice is red" report_sane "$S/update.log" locus-backends,fixture.test locus,fixture.test
report 'Updated to release 9.9.9.'
passes "no advice where the egress line names no retired service passes" report_sane "$S/update.log" locus,fixture.test locus,fixture.test
report "$advice" "$closing"
red "advice where the egress line names no retired service is red" report_sane "$S/update.log" locus,fixture.test locus,fixture.test

# 3. The removal sentences against the proof's own inventories.
before_services=$'cyfr\nlocus-backends\nlocus-backends-guard\nlocus-runtime'
after_services=$'cyfr\nlocus\nlocus-guard'
report "Removed this project's containers of services release 9.9.9 does not run: locus-backends, locus-backends-guard, locus-runtime." \
  "Removed this project's networks release 9.9.9 does not use: locus-backends, locus-runtime."
passes "removal sentences that name what was there and is gone pass" \
  removed_as_said "Removed this project's containers of services" "$S/update.log" "$before_services" "$after_services" "containers of"
passes "the network sentence that names what was there and is gone passes" \
  removed_as_said "Removed this project's networks" "$S/update.log" $'default\nlocus-backends\nlocus-runtime' $'default\nlocus' networks
report "Removed this project's networks release 9.9.9 does not use: locus-backends, never-existed."
red "a removal sentence naming a network that never existed is red" \
  removed_as_said "Removed this project's networks" "$S/update.log" $'default\nlocus-backends\nlocus-runtime' $'default\nlocus' networks
report 'Updated to release 9.9.9.'
red "no removal sentence where containers were removed is red" \
  removed_as_said "Removed this project's containers of services" "$S/update.log" "$before_services" "$after_services" "containers of"
report "Removed this project's containers of services release 9.9.9 does not run: locus-backends."
red "a removal sentence naming fewer than were removed is red" \
  removed_as_said "Removed this project's containers of services" "$S/update.log" "$before_services" "$after_services" "containers of"

# 4. The message read under the person's session, its exact words.
passes "the session's person reading exactly the message passes" thread_as_said '{"user_id":"usr_1","contents":["m1"]}' usr_1 m1
red "a session that opens as someone else is red" thread_as_said '{"user_id":"usr_2","contents":["m1"]}' usr_1 m1
red "a thread that holds the message among others is red" thread_as_said '{"user_id":"usr_1","contents":["m1","more"]}' usr_1 m1
red "a session that reads nothing is red" thread_as_said '{"user_id":"usr_1","contents":[]}' usr_1 m1

# 5. The kept home's owners from the filesystem.
home=/var/lib/locus/kept/mcp_1
passes "a home and marker owned by the program's uid pass" kept_home "{\"uid\":40001,\"home\":\"$home\",\"home_owner\":40001,\"mark\":\"m1\",\"mark_owner\":40001}" "$home" m1 40001
red "a home owned by root that 40001 can still read is red" kept_home "{\"uid\":40001,\"home\":\"$home\",\"home_owner\":0,\"mark\":\"m1\",\"mark_owner\":40001}" "$home" m1 40001
red "a marker owned by root is red" kept_home "{\"uid\":40001,\"home\":\"$home\",\"home_owner\":40001,\"mark\":\"m1\",\"mark_owner\":0}" "$home" m1 40001
red "a program under another uid is red" kept_home "{\"uid\":40002,\"home\":\"$home\",\"home_owner\":40002,\"mark\":\"m1\",\"mark_owner\":40002}" "$home" m1 40001

# 6. The second build is a build of its own.
passes "another build, compiled, passes" another_build build_1 build_2 compiled
red "the first build's record answered again is red" another_build build_1 build_1 compiled
red "a second build not compiled is red" another_build build_1 build_2 failed

# 7. The snapshot holds every part its manifest lists.
snap="$S/snapshot"
mkdir -p "$snap/scaffold" "$snap/storage"
printf 'x' >"$snap/database"
printf 'x' >"$snap/keyring"
printf 'A=1\n' >"$snap/.env"
printf 'services: {}\n' >"$snap/compose"
: >"$snap/scaffold/guide.md"
: >"$snap/storage/file"
printf '{"parts":["database","storage","scaffold","keyring",".env","compose"],"complete":true}\n' >"$snap/snapshot.json"
passes "a snapshot holding every listed part passes" snapshot_parts "$snap"
rm "$snap/.env"
red "a snapshot missing its .env is red" snapshot_parts "$snap"
: >"$snap/.env"
red "a snapshot with an empty .env is red" snapshot_parts "$snap"
printf 'A=1\n' >"$snap/.env"
rm "$snap/storage/file"
red "a snapshot with an empty storage folder is red" snapshot_parts "$snap"

# 8. Who holds what the stack fixes, by overlap, and a start that fails
# looked at once more.
printf 'name cyfr\nsubnet 172.16.231.0/24\n' >"$S/fixed"
held() { [ -n "$(holders "$S/fixed" "$1" "$2" proj)" ]; }
red_if_held() { ! held "$@"; }
red "a network of 172.16.230.0/23 holds 172.16.231.0/24" red_if_held "" "other_net 172.16.230.0/23"
red "a network of 172.16.231.0/24 holds it" red_if_held "" "other_net 172.16.231.0/24"
red "another project's container named cyfr holds the name" red_if_held "cyfr other Up 1 minute" ""
passes "a network of 172.16.232.0/24 does not hold it" red_if_held "" "other_net 172.16.232.0/24"
passes "the project's own network and container are its own" red_if_held "cyfr proj Up 1 minute" "proj_locus 172.16.231.0/24"
start_case() { # HOLDER: a start that fails with HOLDER (or none) there now
  (
    cli() { return 1; }
    fixed_holders() { printf '%s' "$HOLDER"; }
    missing() { echo "not run: $*"; exit 69; }
    fail() { echo "red: $*"; exit 1; }
    PROOF=$S
    start cyfr up-old up
  )
}
status_of() { local s=0; "$@" >/dev/null 2>&1 || s=$?; [ "$s" = "$want" ] || { echo "exited $s, not $want"; return 1; }; }
want=69 HOLDER="the subnet 172.16.231.0/24 is held by the network other" passes "a failed start with a holder there now is not run" status_of start_case
want=1 HOLDER="" passes "a failed start with no holder there is red" status_of start_case

# 9. The teardown: a listing that fails is nothing gone, the tags go
# before the folder, the folder stays until both are known gone, and a
# failed teardown is red.
docker() {
  echo "$*" >>"$S/calls"
  case "$*" in
    "ps -aq --filter"*) [ -z "${FAIL_LIST:-}" ] || return 1 ;;
    "network ls"* | "volume ls"*) [ -z "${FAIL_LIST:-}" ] || return 1 ;;
    "image inspect"*) return 0 ;;
    "image rm"*)
      [ ! -d "$S/run" ] || echo "the folder was there when $* ran" >>"$S/calls"
      [ -z "${FAIL_TAG:-}" ] || return 1
      ;;
  esac
  return 0
}
gone_case() { FAIL_LIST=1 project_gone proj; }
red "a project whose listings fail is not gone" gone_case
torn_case() { # the teardown of a folder, with FAIL_TAG or FAIL_LIST as set
  : >"$S/calls"
  mkdir -p "$S/run"
  teardown proj "$S/run" app:image "" tag:1 tag:2
}
FAIL_TAG=1 red "a teardown whose tag removal fails is red" torn_case
kept_case() { [ -d "$S/run" ] || { echo "the folder went"; return 1; }; }
passes "and keeps the folder for the next run's sweep" kept_case
FAIL_LIST=1 red "a teardown whose listings fail is red" torn_case
passes "and keeps the folder" kept_case
passes "a teardown that removes everything passes" torn_case
order_case() {
  local tags project
  [ ! -d "$S/run" ] || { echo "the folder stayed"; return 1; }
  grep -qxF "the folder was there when image rm tag:2 ran" "$S/calls" || { echo "the tags went after the folder: $(tr '\n' ';' <"$S/calls")"; return 1; }
  tags="$(grep -n '^image rm' "$S/calls" | head -n 1 | cut -d: -f1)"
  project="$(grep -n '^ps -aq' "$S/calls" | head -n 1 | cut -d: -f1)"
  [ -n "$tags" ] && [ -n "$project" ] && [ "$project" -lt "$tags" ] || { echo "the calls ran as: $(tr '\n' ';' <"$S/calls")"; return 1; }
}
passes "it removes the project, then the tags, then the folder" order_case
passes "a run that passed, its teardown failed, is red" check_value "$(exit_status 0 1)" 1
passes "a run that did not run, its teardown failed, is red, not not run" check_value "$(exit_status 69 1)" 1
passes "a run that did not run, its teardown done, is not run" check_value "$(exit_status 69 0)" 69
passes "a run that failed keeps its own status" check_value "$(exit_status 3 1)" 3

[ "$failures" = 0 ] || { echo "$failures case(s) failed"; exit 1; }
echo "every case held"
