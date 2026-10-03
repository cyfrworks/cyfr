#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The join proof (README.md): `cyfr` releases started as the browser
# harness starts homes (tests/browser/harness.sh), each a SQLite cell on a
# `.test` name behind the harness's HTTPS front, with the shipped release's
# cookie, CORS and frame settings — the directories dir.test and
# dir2.test, the person's home a.test (enrolling at dir.test), the hub
# h.test (enrolling at dir2.test) and a fresh installation a2.test
# configured for one restore — with the directories reached by the cells
# through fronts of the identity proof's own (tests/identity-proof/front.sh
# and cells.sh, one per directory). proof.mjs drives the browsers; this
# script answers its asks for the homes' part (`ask-N.json`, answered
# `answer-N.json`).
#
# Usage: tests/join-proof/run.sh
# Writes join-proof.json and join-proof.md into PROOF_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the table.
# RELEASE_BOOT_SKIP_BUILD=1 reuses a release a previous run built;
# JOIN_PROOF_FRESHNESS (20) is H's identity_freshness_seconds,
# JOIN_PROOF_CERT_SECONDS (40) A's and A2's device_cert_seconds, and
# JOIN_PROOF_BROWSERS (chromium firefox webkit) the browsers run.
#
# Everything it starts is removed when it ends, whether it succeeds or
# fails: the cells' servers, the directories' front containers, the
# Playwright container, and the scratch directory with the run's authority
# key, every token, cookie and kit line.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-join-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=../identity-proof/front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=../identity-proof/cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
FRESH="${JOIN_PROOF_FRESHNESS:-20}"
CERT_SECONDS="${JOIN_PROOF_CERT_SECONDS:-40}"
JOIN_PROOF_BROWSERS="${JOIN_PROOF_BROWSERS:-chromium firefox webkit}"
PROOF_PID=""
SECRETS="$WORK/secrets"
mkdir -p -m 700 "$SECRETS"

stop_proof_container() {
  local ids
  ids="$(docker ps -q --filter "volume=$OUT" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 5 $ids >/dev/null 2>&1 || true
  fi
}

# The scratch directory holds the run's authority key, the tokens, the
# cookies and the kits, so it goes even when a stop fails; the asks and
# answers that held one go from PROOF_OUT too. `server_stop` ends in
# `fail`, an `exit`, when a listener outlives its stop, so it runs in a
# subshell: the exit ends that subshell, never this trap, and the stop's
# failure still fails the run.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  identity_front_stop
  jobs -p | xargs -r kill 2>/dev/null || true
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  rm -f "$OUT"/ask-* "$OUT"/answer-* "$OUT"/answered-* 2>/dev/null || true
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

json() { python3 -c "import json, sys; print(json.dumps($1))"; }
field() { printf '%s' "$1" | python3 -c "import json, sys; v = json.load(sys.stdin)$2; print(v if not isinstance(v, (dict, list, bool)) and v is not None else json.dumps(v))"; }
now() { date +%s; }

# This proof's own fixture (fixture.exs) inside cell `$1`'s running server.
join_fixture() {
  local cell="$1"
  shift
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"]/\\&/g')\","
  done
  cell_cyfr "$cell" rpc \
    "{answer, _} = Code.eval_file(\"$ROOT/tests/join-proof/fixture.exs\"); IO.puts(answer.([${args%,}]))" |
    sed -n 's/^FIXTURE=//p' | tail -1
}

release_build

step "the run's authority and the homes"
browser_authority
DIR="$WORK/dir"
DIR2="$WORK/dir2"
A="$WORK/a"
H="$WORK/h"
A2="$WORK/a2"
browser_home "$DIR" dir.test
browser_home "$DIR2" dir2.test
browser_home "$A" a.test
browser_home "$H" h.test
browser_home "$A2" a2.test
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/token-a2"

identity_directory dir.test 127.77.0.1
identity_directory dir2.test 127.77.0.2
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_env "$DIR2" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$A" dir.test
identity_reaches_directory "$H" dir2.test "CYFR_IDENTITY_FRESHNESS_SECONDS=$FRESH"
identity_reaches_directory "$A2" dir.test "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-a2")"

step "starting the directories, their fronts, and the homes"
server_start "$DIR"
server_start "$DIR2"
identity_front_start "$DIR"
identity_front_start "$DIR2"
for cell in "$A" "$H" "$A2"; do identity_start "$cell"; done

step "the person at a.test and H's operator, signed in by the release fixture's door"
person="$(server_fixture "$A" person operator@example.com join-person)"
[ -n "$person" ] || fail "the fixture signed nobody in at A"
USER_A="$(field "$person" "['user_id']")"
SEGMENT_A="$(field "$person" "['segment']")"
admin="$(server_fixture "$H" person operator@example.com join-operator)"
[ -n "$admin" ] || fail "the fixture signed nobody in at H"
(umask 077 && field "$admin" "['token']" >"$SECRETS/admin-token")
SEGMENT_H="$(field "$admin" "['segment']")"
# A's certificates live CERT_SECONDS, so a device at H renews at A while
# the proof runs; set as A's platform admin sets it.
answer="$(server_fixture "$A" console "$(field "$person" "['token']")" settings/set \
  "{\"key\":\"device_cert_seconds\",\"value\":\"$CERT_SECONDS\"}")"
printf '%s' "$answer" | grep -q '"ok"' || fail "device_cert_seconds was not set at A: $answer"

USER_A2=""

# A fresh session of the fixture's person at cell `$1`, as its cookie.
cookie_of() {
  local cell="$1" who token
  who="$(server_fixture "$cell" person operator@example.com "$2")"
  token="$(field "$who" "['token']")"
  browser_cookie "$cell" "$token"
}

# H's operator's console call: tool `$1`, arguments `$2`, repeated under
# the confirmation in `$SECRETS/confirmation` when `$3` is `confirmed`.
admin_console() {
  local extra=()
  [ "${3:-}" = confirmed ] && extra=("@$SECRETS/confirmation")
  join_fixture "$H" console "@$SECRETS/admin-token" "$1" "$2" ${extra[@]+"${extra[@]}"}
}

answer_ask() {
  local ask="$1" op answer identifier
  op="$(field "$(cat "$ask")" "['op']")"
  case "$op" in
    a_cookie)
      answer="$(json "{'cookie': '$(cookie_of "$A" join-person)', 'segment': '$SEGMENT_A'}")"
      ;;
    admin_cookie)
      # A session minted now, so the operator's first passkey falls within
      # its first-method window; the console calls run under it too.
      admin="$(server_fixture "$H" person operator@example.com join-operator)"
      (umask 077 && field "$admin" "['token']" >"$SECRETS/admin-token")
      answer="$(json "{'cookie': '$(browser_cookie "$H" "$(cat "$SECRETS/admin-token")")', 'segment': '$SEGMENT_H'}")"
      ;;
    a2_segment)
      answer="$(identity_fixture "$A2" segment "$USER_A2")"
      ;;
    a_head)
      answer="$(identity_fixture "$A" head "$USER_A")"
      ;;
    a2_head)
      USER_A2="$(field "$(identity_fixture "$A2" people)" "['people'][0]['user_id']")"
      answer="$(identity_fixture "$A2" head "$USER_A2")"
      ;;
    h_setup)
      identifier="$(field "$(cat "$ask")" "['identifier']")"
      allowed="$(admin_console door/allow "{\"kind\":\"identifier\",\"value\":\"$identifier\",\"note\":\"join proof\"}")"
      group="$(join_fixture "$H" group "@$SECRETS/admin-token" "Household")"
      pair="$(join_fixture "$H" group "@$SECRETS/admin-token" "Pair")"
      invited_group="$(admin_console member/add "{\"athanor\":\"$(field "$group" "['athanor_id']")\",\"identifier\":\"$identifier\"}")"
      invited_pair="$(admin_console member/add "{\"athanor\":\"$(field "$pair" "['athanor_id']")\",\"identifier\":\"$identifier\"}")"
      directory="$(join_fixture "$H" directory)"
      a_directory="$(join_fixture "$A" directory)"
      answer="$(python3 - "$allowed" "$group" "$pair" "$invited_group" "$invited_pair" "$directory" "$a_directory" <<'PY'
import json, sys
allowed, group, pair, ig, ip, directory, a_directory = (json.loads(a) for a in sys.argv[1:])
print(json.dumps({
    "allowed": "ok" in allowed, "allow_answer": allowed if "ok" not in allowed else None,
    "group": group, "pair": pair,
    "invited_group": "ok" in ig, "invited_pair": "ok" in ip,
    "invite_answers": [a for a in (ig, ip) if "ok" not in a],
    "directory": directory["directory_url"], "a_directory": a_directory["directory_url"],
}))
PY
)"
      ;;
    h_person)
      answer="$(join_fixture "$H" person "$(field "$(cat "$ask")" "['identifier']")")"
      ;;
    h_receipts)
      answer="$(join_fixture "$H" receipts "$(field "$(cat "$ask")" "['identifier']")")"
      ;;
    h_fresh)
      answer="$(identity_fixture "$H" fresh "$(field "$(cat "$ask")" "['identifier']")")"
      ;;
    dir_seen)
      answer="$(identity_front_seen "$(field "$(cat "$ask")" "['directory']")" |
        python3 -c "import json, sys; seen = json.load(sys.stdin)['seen']; print(json.dumps({'paths': [r['path'] for r in seen]}))")"
      ;;
    tables)
      cell="$WORK/$(field "$(cat "$ask")" "['cell']")"
      answer="$(join_fixture "$cell" tables)"
      ;;
    pending_passkey)
      answer="$(join_fixture "$H" pending_passkey "$(field "$(cat "$ask")" "['user_id']")")"
      ;;
    recover_admin)
      # The operator authorizes the person's exact pending registration;
      # the first call opens the confirmation, kept here, and the repeat
      # under it runs once the operator confirmed in their browser.
      user_id="$(field "$(cat "$ask")" "['user_id']")"
      pending="$(join_fixture "$H" pending_passkey "$user_id")"
      args="{\"user_id\":\"$user_id\",\"passkey_id\":\"$(field "$pending" "['passkey_id']")\",\"registration_digest\":\"$(field "$pending" "['registration_digest']")\"}"
      printf '%s' "$args" >"$WORK/recover-args"
      first="$(admin_console passkey/recover_admin "$args")"
      (umask 077 && printf '%s' "$first" | python3 -c "import json, sys; a = json.load(sys.stdin); open(sys.argv[1], 'w').write(a.get('confirmation_required', ''))" "$SECRETS/confirmation")
      answer="$(printf '%s' "$first" | python3 -c "import json, sys; a = json.load(sys.stdin); print(json.dumps({'asked': 'confirmation_required' in a, 'answer': None if 'confirmation_required' in a else a}))")"
      ;;
    recover_admin_repeat)
      answer="$(admin_console passkey/recover_admin "$(cat "$WORK/recover-args")" confirmed)"
      rm -f "$SECRETS/confirmation"
      ;;
    post)
      request="$(cat "$ask")"
      answer="$(join_fixture "$H" post "$(field "$request" "['user_id']")" "$(field "$request" "['athanor_id']")" "$(field "$request" "['text']")")"
      ;;
    read)
      request="$(cat "$ask")"
      answer="$(join_fixture "$H" read "$(field "$request" "['athanor_id']")" "$(field "$request" "['thread_id']")")"
      ;;
    remove)
      request="$(cat "$ask")"
      answer="$(admin_console member/remove "{\"athanor\":\"$(field "$request" "['athanor_id']")\",\"identifier\":\"$(field "$request" "['identifier']")\"}")"
      ;;
    certifications)
      request="$(cat "$ask")"
      cell="$WORK/$(field "$request" "['cell']")"
      user="$USER_A"
      [ "$(field "$request" "['cell']")" = a2 ] && user="$USER_A2"
      answer="$(join_fixture "$cell" certifications "$user")"
      ;;
    carry_actions | confirmations | paired)
      request="$(cat "$ask")"
      answer="$(join_fixture "$WORK/$(field "$request" "['cell']")" "$op" "$(field "$request" "['identifier']")")"
      ;;
    token_a2)
      answer="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/token-a2")"
      ;;
    a_down)
      ( server_stop "$A" ) || :
      if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$(cell_port "$A")/api/health" 2>/dev/null; then
        answer="$(json '{"down": False}')"
      else
        answer="$(json '{"down": True}')"
      fi
      ;;
    directory_fault)
      request="$(cat "$ask")"
      identity_front_fault "$(field "$request" "['directory']")" "$(field "$request" "['mode']")"
      answer="$(json "{'mode': '$(field "$request" "['mode']")', 'at': $(now)}")"
      ;;
    clock)
      answer="$(json "{'at': $(now)}")"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
  [ -n "$answer" ] || answer='{"error":"the fixture answered nothing"}'
  printf '%s\n' "$answer" >"${ask%.json}.answer-part"
}

# Each step the proof asks for, answered once; an ask that carried a
# secret is emptied as soon as it is read.
answer_asks() {
  local ask id
  for ask in "$OUT"/ask-*.json; do
    [ -e "$ask" ] || continue
    id="${ask##*/ask-}"
    id="${id%.json}"
    [ -e "$OUT/answer-$id.json" ] && continue
    [ -e "$OUT/answered-$id" ] && continue
    touch "$OUT/answered-$id"
    answer_ask "$ask"
    if grep -q '"kit"\|"cookie"\|"token"' "$ask"; then : >"$ask"; fi
    mv "${ask%.json}.answer-part" "$OUT/answer-$id.json"
  done
}

step "the join proof in $JOIN_PROOF_BROWSERS, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-* "$OUT"/answered-*
# What the browsers' side reads of this run's settings.
json "{'browsers': '$JOIN_PROOF_BROWSERS'.split(), 'fresh': $FRESH, 'cert_seconds': $CERT_SECONDS}" >"$OUT/join-settings.json"
playwright_run join-proof proof.mjs /authority/homes.json /out &
PROOF_PID=$!
while kill -0 "$PROOF_PID" 2>/dev/null; do
  answer_asks
  sleep 0.2
done
set +e
wait "$PROOF_PID"
status=$?
set -e
PROOF_PID=""
rm -f "$OUT"/answered-*

echo "the record: $OUT/join-proof.json and $OUT/join-proof.md"
exit "$status"
