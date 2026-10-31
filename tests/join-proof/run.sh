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
# and cells.sh, one per directory), and the cyfr.run stand-in
# (tests/registry-stand-in/standin.py) as the homes' registry, naming
# dir.test as the directory of every name it holds. A's person is set up
# in the browser through A's two screens; H's operator is the release
# fixture's. proof.mjs drives the browsers; this script answers its asks
# for the homes' part (`ask-N.json`, answered `answer-N.json`).
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
# fails: the cells' servers, the stand-in, the directories' front
# containers, the Playwright container, and the scratch directory with the
# run's authority key, every token, cookie and recovery code.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-join-proof-XXXXXX")"
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
# The cyfr.run stand-in: a loopback address of the identity proofs' block
# (the fronts hold 127.77.0.1 to .3) and the port it picks free.
STANDIN_ADDRESS=127.77.0.4
STANDIN_PORT=""
STANDIN_PID=""

# The scratch directory holds the run's authority key, the tokens, the
# cookies, the recovery codes and the stand-in's state, so it goes even
# when a stop fails; the asks and answers that held one go from PROOF_OUT
# too. `server_stop` ends in `fail`, an `exit`, when a listener outlives
# its stop, so it runs in a subshell: the exit ends that subshell, never
# this trap, and the stop's failure still fails the run.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  identity_front_stop
  jobs -p | xargs -r kill 2>/dev/null || true
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  standin_stop
  rm -f "$OUT"/ask-* "$OUT"/answer-* 2>/dev/null || true
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

json() { python3 -c "import json, sys; print(json.dumps($1))"; }
now() { date +%s; }

# The stand-in on STANDIN_ADDRESS, at the port it picks and writes to its
# ready file, left in STANDIN_PORT, answering every name with dir.test as
# its directory: its state in `$WORK/cyfr-run.json` and its log in
# `$WORK/cyfr-run.log`. A stand-in that ends, or writes no port within
# 30 s, fails the run.
standin_start() {
  local ready="$WORK/cyfr-run.ready" closes=$((SECONDS + 30))
  python3 -I "$ROOT/tests/registry-stand-in/standin.py" --address "$STANDIN_ADDRESS" --port 0 \
    --state "$WORK/cyfr-run.json" --ready-file "$ready" --directory https://dir.test \
    </dev/null >"$WORK/cyfr-run.log" 2>&1 &
  STANDIN_PID=$!
  until [ -s "$ready" ]; do
    case "$(ps -o stat= -p "$STANDIN_PID" 2>/dev/null)" in
      '' | Z*)
        tail -n 20 "$WORK/cyfr-run.log" >&2 || true
        fail "the cyfr.run stand-in ended before it served on $STANDIN_ADDRESS"
        ;;
    esac
    [ "$SECONDS" -lt "$closes" ] || fail "the cyfr.run stand-in wrote no port within 30 s"
    sleep 0.1
  done
  STANDIN_PORT="$(tr -d '\n' <"$ready")"
  [[ "$STANDIN_PORT" =~ ^[0-9]+$ ]] || fail "the cyfr.run stand-in wrote no port: '$STANDIN_PORT'"
}

# The stand-in stopped by SIGTERM, which it takes, and waited for.
standin_stop() {
  [ -n "$STANDIN_PID" ] || return 0
  kill "$STANDIN_PID" 2>/dev/null || true
  wait "$STANDIN_PID" 2>/dev/null || true
  STANDIN_PID=""
}

# This proof's own fixture (fixture.exs) inside cell `$1`'s running server.
join_fixture() {
  local cell="$1"
  shift
  cell_fixture "$cell" "$ROOT/tests/join-proof/fixture.exs" FIXTURE "$@"
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
# A's setup token, the one A's person is set up under in the browser.
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/setup-a"

identity_directory dir.test 127.77.0.1
identity_directory dir2.test 127.77.0.2
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_env "$DIR2" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$A" dir.test
identity_reaches_directory "$H" dir2.test "CYFR_IDENTITY_FRESHNESS_SECONDS=$FRESH"
identity_reaches_directory "$A2" dir.test "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-a2")"

step "the cyfr.run stand-in, the homes' registry"
standin_start
echo "the stand-in answers at http://$STANDIN_ADDRESS:$STANDIN_PORT"
for cell in "$A" "$H" "$A2"; do
  identity_env "$cell" CYFR_REGISTRY_URL "$STANDIN_ADDRESS:$STANDIN_PORT"
  identity_env "$cell" CYFR_PRIVATE_EGRESS_TARGETS "$(cell_value "$cell" CYFR_PRIVATE_EGRESS_TARGETS),$STANDIN_ADDRESS"
done
identity_env "$A" CYFR_SETUP_TOKEN "$(cat "$SECRETS/setup-a")"

step "starting the directories, their fronts, and the homes"
server_start "$DIR"
server_start "$DIR2"
identity_front_start "$DIR"
identity_front_start "$DIR2"
for cell in "$A" "$H" "$A2"; do identity_start "$cell"; done

step "H's operator, signed in by the release fixture"
admin="$(server_fixture "$H" person operator@example.com join-operator)"
[ -n "$admin" ] || fail "the fixture signed nobody in at H"
(umask 077 && field "$admin" token >"$SECRETS/admin-token")
SEGMENT_H="$(field "$admin" segment)"

# A's person, whom the browser sets up (`a_person`).
USER_A=""
SEGMENT_A=""
USER_A2=""

# A fresh session of the fixture's person at cell `$1`, as its cookie.
cookie_of() {
  local cell="$1" who token
  who="$(server_fixture "$cell" person operator@example.com "$2")"
  token="$(field "$who" token)"
  browser_cookie "$cell" "$token"
}

# H's operator's console call: tool `$1`, arguments `$2`, repeated under
# the confirmation in `$SECRETS/confirmation` when `$3` is `confirmed`.
admin_console() {
  local extra=()
  [ "${3:-}" = confirmed ] && extra=("@$SECRETS/confirmation")
  join_fixture "$H" console "@$SECRETS/admin-token" "$1" "$2" ${extra[@]+"${extra[@]}"}
}

# Each step the proof asks for (harness.sh `answer_asks`, which removes
# each ask, one that carried a recovery code, a cookie or a token among
# them, before its answer appears).
answer_ask() {
  local ask="$1" op identifier
  op="$(asked "$ask" op)"
  case "$op" in
    setup_token)
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/setup-a")"
      ;;
    a_person)
      # A's one person, whom the browser set up. The release fixture's
      # door (the GitHub identity join-person) is linked to them, so it
      # signs them in where a browser holds no passkey (`a_cookie`); A's
      # certificates live CERT_SECONDS, so a device at H renews at A while
      # the proof runs, set under that sign-in as A's platform admin sets
      # it.
      people="$(identity_fixture "$A" people)"
      USER_A="$(field "$people" people 0 user_id)"
      linked="$(join_fixture "$A" door "$USER_A" join-person)"
      person="$(server_fixture "$A" person operator@example.com join-person)"
      [ "$(field "$person" user_id)" = "$USER_A" ] ||
        fail "the release fixture's door signed in '$(field "$person" user_id)' at A, not the person set up there, $USER_A"
      SEGMENT_A="$(field "$person" segment)"
      answer="$(server_fixture "$A" console "$(field "$person" token)" settings/set \
        "{\"key\":\"device_cert_seconds\",\"value\":\"$CERT_SECONDS\"}")"
      printf '%s' "$answer" | grep -q '"ok"' || fail "device_cert_seconds was not set at A: $answer"
      ANSWER="$(python3 - "$people" "$linked" "$SEGMENT_A" <<'PY'
import json, sys
people, linked = (json.loads(a) for a in sys.argv[1:3])
first = people["people"][0]
print(json.dumps({"people": len(people["people"]), "user_id": first["user_id"], "admission": first["admission"],
                  "door_linked": linked.get("linked"), "segment": sys.argv[3]}))
PY
)"
      ;;
    a_cookie)
      ANSWER="$(json "{'cookie': '$(cookie_of "$A" join-person)', 'segment': '$SEGMENT_A'}")"
      ;;
    admin_cookie)
      # A session minted now, so the operator's first passkey falls within
      # its first-method window; the console calls run under it too.
      admin="$(server_fixture "$H" person operator@example.com join-operator)"
      (umask 077 && field "$admin" token >"$SECRETS/admin-token")
      ANSWER="$(json "{'cookie': '$(browser_cookie "$H" "$(cat "$SECRETS/admin-token")")', 'segment': '$SEGMENT_H'}")"
      ;;
    a2_segment)
      ANSWER="$(identity_fixture "$A2" segment "$USER_A2")"
      ;;
    a_head)
      ANSWER="$(identity_fixture "$A" head "$USER_A")"
      ;;
    a2_head)
      USER_A2="$(field "$(identity_fixture "$A2" people)" people 0 user_id)"
      ANSWER="$(identity_fixture "$A2" head "$USER_A2")"
      ;;
    h_setup)
      identifier="$(asked "$ask" identifier)"
      allowed="$(admin_console door/allow "{\"value\":\"$identifier\",\"note\":\"join proof\"}")"
      group="$(join_fixture "$H" group "@$SECRETS/admin-token" "Household")"
      pair="$(join_fixture "$H" group "@$SECRETS/admin-token" "Pair")"
      invited_group="$(admin_console member/add "{\"athanor\":\"$(field "$group" athanor_id)\",\"identifier\":\"$identifier\"}")"
      invited_pair="$(admin_console member/add "{\"athanor\":\"$(field "$pair" athanor_id)\",\"identifier\":\"$identifier\"}")"
      directory="$(join_fixture "$H" directory)"
      a_directory="$(join_fixture "$A" directory)"
      ANSWER="$(python3 - "$allowed" "$group" "$pair" "$invited_group" "$invited_pair" "$directory" "$a_directory" <<'PY'
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
      ANSWER="$(join_fixture "$H" person "$(asked "$ask" identifier)")"
      ;;
    h_invitation)
      # An invitation H's operator makes for a group of its own, Garden,
      # for the person who already has a name; its link carries the code.
      garden="$(join_fixture "$H" group "@$SECRETS/admin-token" "Garden")"
      invitation="$(admin_console invitation/create "{\"athanor_id\":\"$(field "$garden" athanor_id)\"}")"
      ANSWER="$(python3 - "$garden" "$invitation" <<'PY'
import json, sys
garden, invitation = (json.loads(a) for a in sys.argv[1:])
made = invitation.get("ok") or {}
print(json.dumps({"athanor_id": garden["athanor_id"], "link": made.get("invitation_url"),
                  "answer": None if made else invitation}))
PY
)"
      ;;
    h_door)
      # H's door entries naming the identifier.
      identifier="$(asked "$ask" identifier)"
      ANSWER="$(admin_console door/list '{}' | python3 -c "
import json, sys
listed = json.load(sys.stdin).get('ok') or {}
entries = [e for e in listed.get('entries', []) if e.get('value') == sys.argv[1]]
print(json.dumps({'entries': [{k: e.get(k) for k in ('kind', 'value', 'effect', 'status', 'note', 'added_by')} for e in entries]}))
" "$identifier")"
      ;;
    h_receipts)
      ANSWER="$(join_fixture "$H" receipts "$(asked "$ask" identifier)")"
      ;;
    h_fresh)
      ANSWER="$(identity_fixture "$H" fresh "$(asked "$ask" identifier)")"
      ;;
    dir_seen)
      ANSWER="$(identity_front_seen "$(asked "$ask" directory)" |
        python3 -c "import json, sys; seen = json.load(sys.stdin)['seen']; print(json.dumps({'paths': [r['path'] for r in seen]}))")"
      ;;
    tables)
      cell="$WORK/$(asked "$ask" cell)"
      ANSWER="$(join_fixture "$cell" tables)"
      ;;
    pending_passkey)
      ANSWER="$(join_fixture "$H" pending_passkey "$(asked "$ask" user_id)")"
      ;;
    recover_admin)
      # The operator authorizes the person's exact pending registration;
      # the first call opens the confirmation, kept here, and the repeat
      # under it runs once the operator confirmed in their browser.
      user_id="$(asked "$ask" user_id)"
      pending="$(join_fixture "$H" pending_passkey "$user_id")"
      args="{\"user_id\":\"$user_id\",\"passkey_id\":\"$(field "$pending" passkey_id)\",\"registration_digest\":\"$(field "$pending" registration_digest)\"}"
      printf '%s' "$args" >"$WORK/recover-args"
      first="$(admin_console passkey/recover_admin "$args")"
      (umask 077 && printf '%s' "$first" | python3 -c "import json, sys; a = json.load(sys.stdin); open(sys.argv[1], 'w').write(a.get('confirmation_required', ''))" "$SECRETS/confirmation")
      ANSWER="$(printf '%s' "$first" | python3 -c "import json, sys; a = json.load(sys.stdin); print(json.dumps({'asked': 'confirmation_required' in a, 'answer': None if 'confirmation_required' in a else a}))")"
      ;;
    recover_admin_repeat)
      ANSWER="$(admin_console passkey/recover_admin "$(cat "$WORK/recover-args")" confirmed)"
      rm -f "$SECRETS/confirmation"
      ;;
    post)
      ANSWER="$(join_fixture "$H" post "$(asked "$ask" user_id)" "$(asked "$ask" athanor_id)" "$(asked "$ask" text)")"
      ;;
    read)
      ANSWER="$(join_fixture "$H" read "$(asked "$ask" athanor_id)" "$(asked "$ask" thread_id)")"
      ;;
    remove)
      ANSWER="$(admin_console member/remove "{\"athanor\":\"$(asked "$ask" athanor_id)\",\"identifier\":\"$(asked "$ask" identifier)\"}")"
      ;;
    certifications)
      cell="$WORK/$(asked "$ask" cell)"
      user="$USER_A"
      [ "$(asked "$ask" cell)" = a2 ] && user="$USER_A2"
      ANSWER="$(join_fixture "$cell" certifications "$user")"
      ;;
    carry_actions | confirmations | paired)
      ANSWER="$(join_fixture "$WORK/$(asked "$ask" cell)" "$op" "$(asked "$ask" identifier)")"
      ;;
    token_a2)
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/token-a2")"
      ;;
    a_down)
      ( server_stop "$A" ) || :
      if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$(cell_port "$A")/api/health" 2>/dev/null; then
        ANSWER="$(json '{"down": False}')"
      else
        ANSWER="$(json '{"down": True}')"
      fi
      ;;
    directory_fault)
      identity_front_fault "$(asked "$ask" directory)" "$(asked "$ask" mode)"
      ANSWER="$(json "{'mode': '$(asked "$ask" mode)', 'at': $(now)}")"
      ;;
    clock)
      ANSWER="$(json "{'at': $(now)}")"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the join proof in $JOIN_PROOF_BROWSERS, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
# What the browsers' side reads of this run's settings.
json "{'browsers': '$JOIN_PROOF_BROWSERS'.split(), 'fresh': $FRESH, 'cert_seconds': $CERT_SECONDS}" >"$OUT/join-settings.json"
playwright_run join-proof proof.mjs /authority/homes.json /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/join-proof.json and $OUT/join-proof.md"
exit "$PROOF_STATUS"
