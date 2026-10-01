#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The identity proof (README.md): `cyfr` releases started as the browser
# harness starts homes (tests/browser/harness.sh), each a SQLite cell on a
# `.test` name behind the harness's HTTPS front — the directory dir.test,
# the person's home a.test, the relying home b.test, and three empty
# installations, c.test, c2.test and c3.test, each configured for one
# restore under its own token — with the directory reached by the cells
# through a front of this proof's own (front.sh, cells.sh). proof.mjs
# drives Chromium through enrollment, two printed kits, a rotation, the
# restores and what each home sees; this script answers its asks for the
# homes' part (`ask-N.json`, answered `answer-N.json`): cells stopped,
# copied, killed and started again, the directory broken on purpose,
# restores posted at a phase, and what a home holds.
#
# Usage: tests/identity-proof/run.sh
# Writes identity-proof.json and identity-proof.md into PROOF_OUT (default:
# the scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the
# table. Set RELEASE_BOOT_SKIP_BUILD=1 to reuse a release a previous run
# built; IDENTITY_PROOF_FRESHNESS (20) is B's identity_freshness_seconds
# and IDENTITY_PROOF_REAUTH (20) the restored person's first-method window
# on C, in seconds.
#
# Everything it starts is removed when it ends, whether it succeeds or
# fails: the cells' servers, the directory's front container, the
# Playwright container, and the scratch directory with the run's authority
# key, every token and every kit line.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-identity-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
FRESH="${IDENTITY_PROOF_FRESHNESS:-20}"
REAUTH="${IDENTITY_PROOF_REAUTH:-20}"
# How far past a bound an observation may fall: B is asked every two
# seconds, and each ask is an rpc of its own.
SLACK=6
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

# The scratch directory holds the run's authority key, the tokens and the
# kits, so it goes even when a stop fails; the asks and answers that held
# a kit or a token go from PROOF_OUT too. `server_stop` ends in `fail`, an
# `exit`, when a listener outlives its stop, so it runs in a subshell: the
# exit ends that subshell, never this trap before the removals below.
cleanup() {
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  identity_front_stop
  jobs -p | xargs -r kill 2>/dev/null || true
  ( server_stop ) || :
  rm -f "$OUT"/ask-* "$OUT"/answer-* 2>/dev/null || true
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

json() { python3 -c "import json, sys; print(json.dumps($1))"; }
field() { printf '%s' "$1" | python3 -c "import json, sys; v = json.load(sys.stdin)$2; print(v if not isinstance(v, (dict, list, bool)) and v is not None else json.dumps(v))"; }
now() { date +%s; }

release_build

step "the run's authority and the homes"
browser_authority
DIR="$WORK/dir"
A="$WORK/a"
B="$WORK/b"
C="$WORK/c"
C2="$WORK/c2"
C3="$WORK/c3"
THIEF="$WORK/thief"
browser_home "$DIR" dir.test
browser_home "$A" a.test
browser_home "$B" b.test
browser_home "$C" c.test
browser_home "$C2" c2.test
browser_home "$C3" c3.test

for cell in c c2 c3; do
  openssl rand -hex 32 | tr -d '\n' >"$SECRETS/token-$cell"
done

identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$A"
identity_reaches_directory "$B" "CYFR_IDENTITY_FRESHNESS_SECONDS=$FRESH"
# C holds one athanor no person owns under a cap of one, so the restored
# person's own is refused until the cap goes: the restore stops at minted.
identity_reaches_directory "$C" "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-c")" \
  "CYFR_REAUTH_SECONDS=$REAUTH" "CYFR_MAX_ATHANORS=1"
identity_reaches_directory "$C2" "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-c2")"
identity_reaches_directory "$C3" "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-c3")"

step "starting the directory, its front, and the homes"
server_start "$DIR"
identity_front_start "$DIR"
for cell in "$A" "$B" "$C" "$C2" "$C3"; do identity_start "$cell"; done
identity_fixture "$C" placeholder_athanor >/dev/null

step "the person at a.test, signed in by the release fixture's door"
person="$(server_fixture "$A" person operator@example.com identity-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
USER_A="$(field "$person" "['user_id']")"
SEGMENT_A="$(field "$person" "['segment']")"
COOKIE_A="$(browser_cookie "$A" "$(field "$person" "['token']")")"
browser_picker_layout "$A" "$(field "$person" "['token']")"

IDENTIFIER=""
MOVED_AT=0
B_VERIFIED_AT=0

# The kit an ask carries, written where only this run reads it.
kit_file() {
  local ask="$1" name="$2"
  (umask 077 && python3 -c "import json, sys; k = json.load(open(sys.argv[1]))['kit']; json.dump({'identifier': k['identifier'], 'directory_url': k['directory_url'], 'recovery_secret': k['recovery_secret']}, open(sys.argv[2], 'w'))" "$ask" "$SECRETS/$name")
  printf '%s' "$SECRETS/$name"
}

# The restore attempts of cell `$1`, the last one's field `$2`.
last_restore() { field "$(identity_fixture "$1" restores)" "['restores'][-1]['$2']"; }

restored_user() { field "$(identity_fixture "$1" people)" "['people'][0]['user_id']"; }

# B's view, polled every two seconds from now until it names `$1`, or
# `$2` seconds pass; prints the epoch second it did, or nothing.
watch_b() {
  local target="$1" limit="$2" until answer
  until=$(($(now) + limit))
  while [ "$(now)" -le "$until" ]; do
    answer="$(identity_fixture "$B" fresh "$IDENTIFIER")"
    if [ "$(field "$answer" ".get('key_epoch')")" = "$target" ]; then
      now
      return 0
    fi
    sleep 2
  done
}

# B reads the head live and caches it, its answer in `$WORK/resolved.json`.
# Never run in a command substitution: B_VERIFIED_AT is this shell's.
b_resolve() {
  identity_fixture "$B" resolve "$IDENTIFIER" "@$WORK/genesis.json" >"$WORK/resolved.json"
  B_VERIFIED_AT="$(now)"
}

# Restore posted to cell `$1` with its own token and the kit file `$2`;
# prints `{status, phase, error}` of the answer.
post_restore() {
  local cell="$1" kit="$2" name status
  name="$(basename "$cell")"
  status="$(identity_restore_post "$cell" /restore "$SECRETS/token-$name" "$kit" "$WORK/answer.json")"
  python3 - "$status" "$WORK/answer.json" <<'PY'
import json, sys
status = int(sys.argv[1])
try:
    body = json.load(open(sys.argv[2]))
except Exception:
    body = {}
print(json.dumps({"status": status, "phase": body.get("status"), "error": body.get("error")}))
PY
}

answer_ask() {
  local ask="$1" op answer kit started observed target
  op="$(field "$(cat "$ask")" "['op']")"
  case "$op" in
    a_head)
      answer="$(identity_fixture "$A" head "$USER_A")"
      ;;
    b_resolve)
      genesis="$(identity_fixture "$A" genesis "$USER_A")"
      IDENTIFIER="$(field "$genesis" "['identifier']")"
      printf '%s' "$genesis" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['genesis']))" >"$WORK/genesis.json"
      b_resolve
      answer="$(cat "$WORK/resolved.json")"
      ;;
    preserve_a)
      # The thief's copy: A stopped, copied whole, and both started again.
      server_stop "$A"
      identity_preserved "$A" "$THIEF" thief.test 4480
      identity_start "$A"
      identity_start "$THIEF"
      answer="$(json '{"preserved": True}')"
      ;;
    c_first_sign_in)
      # The operator's own address: a door that would admit them first anywhere else.
      answer="$(identity_fixture "$C" first_sign_in operator@example.com first-door)"
      ;;
    token)
      answer="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/token-$(field "$(cat "$ask")" "['cell']")")"
      ;;
    c_claims)
      kit="$(kit_file "$ask" kit-2.json)"
      # Another cell's token, an identity the directory never saw, and a
      # seed that is no kit of this identity.
      other="$(identity_restore_post "$C" /restore "$SECRETS/token-c2" "$kit" "$WORK/answer.json")"
      python3 - "$kit" "$SECRETS/unknown.json" "$SECRETS/wrong-seed.json" <<'PY'
import base64, json, os, sys
kit = json.load(open(sys.argv[1]))
seed = base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
unknown = dict(kit, identifier="per_" + os.urandom(32).hex())
json.dump(unknown, open(sys.argv[2], "w"))
json.dump(dict(kit, recovery_secret=seed), open(sys.argv[3], "w"))
PY
      unknown="$(identity_restore_post "$C" /restore "$SECRETS/token-c" "$SECRETS/unknown.json" "$WORK/answer.json")"
      wrong="$(identity_restore_post "$C" /restore "$SECRETS/token-c" "$SECRETS/wrong-seed.json" "$WORK/answer.json")"
      attempts="$(identity_fixture "$C" restores | python3 -c "import json, sys; print(len(json.load(sys.stdin)['restores']))")"
      answer="$(json "{'other_token': $other, 'unknown_kit': $unknown, 'wrong_seed': $wrong, 'attempts': $attempts}")"
      ;;
    c_phases)
      kit="$(kit_file "$ask" kit-2.json)"
      log_before="$(identity_fixture "$DIR" log "$IDENTIFIER")"
      # submitted: the directory's reply lost, a thief rotating at the same
      # moment on the copy of A.
      identity_front_fault drop-recover
      identity_fixture "$THIEF" thief_rotate "$USER_A" >"$WORK/thief-1.json" &
      thief_pid=$!
      submitted="$(post_restore "$C" "$kit")"
      wait "$thief_pid" || true
      MOVED_AT="$(now)"
      submitted_phase="$(last_restore "$C" phase)"
      head="$(field "$(identity_fixture "$DIR" log "$IDENTIFIER")" "['head']")"
      # B watched from the move on, in the background.
      (watch_b "$head" $((FRESH + 60)) >"$WORK/observed-c") &
      identity_kill "$C"
      identity_start "$C"
      replay="$(identity_fixture "$C" replay_recover)"
      thief_2="$(identity_fixture "$THIEF" thief_rotate "$USER_A")"
      # accepted: the recovery answered, the head it must read again unread.
      identity_front_fault block-reads-after-recover
      accepted="$(post_restore "$C" "$kit")"
      identity_front_fault none
      accepted_phase="$(last_restore "$C" phase)"
      accepted_entry="$(last_restore "$C" entry_hash)"
      identity_kill "$C"
      identity_start "$C"
      # minted: the person minted, their athanor refused by the cap.
      minted="$(post_restore "$C" "$kit")"
      minted_phase="$(last_restore "$C" phase)"
      identity_kill "$C"
      identity_env "$C" CYFR_MAX_ATHANORS
      identity_start "$C"
      log="$(identity_fixture "$DIR" log "$IDENTIFIER")"
      final_head="$(field "$log" "['head']")"
      answer="$(python3 - "$submitted" "$submitted_phase" "$accepted" "$accepted_phase" "$accepted_entry" \
        "$minted" "$minted_phase" "$replay" "$log" "$WORK/thief-1.json" "$thief_2" "$final_head" \
        "$log_before" <<'PY'
import json, sys
(submitted, submitted_phase, accepted, accepted_phase, accepted_entry, minted, minted_phase,
 replay, log, thief_file, thief_2, final_head, log_before) = sys.argv[1:]
def at(answer, phase, **more):
    answer = json.loads(answer)
    answer["phase"] = phase
    answer.update(more)
    return answer
try:
    thief_1 = json.load(open(thief_file))
except Exception:
    thief_1 = {}
log = json.loads(log)
before = json.loads(log_before).get("kinds", [])
replay = json.loads(replay)
thief_2 = json.loads(thief_2)
print(json.dumps({
    "submitted": at(submitted, submitted_phase),
    "accepted": at(accepted, accepted_phase, entry_hash=accepted_entry),
    "minted": at(minted, minted_phase),
    "replay": replay,
    # The recoveries this restore added to the log: the added kit's entry
    # before it is a recovery too.
    "recoveries": log.get("kinds", []).count("recover") - before.count("recover"),
    "log": log.get("kinds"),
    "thief": {
        "first": thief_1,
        "won": bool(thief_1.get("accepted")) and thief_1.get("accepted") == final_head,
        "later": thief_2,
        "later_refused": "refused" in thief_2,
    },
}))
PY
)"
      ;;
    b_observes)
      cell="$(field "$(cat "$ask")" "['cell']")"
      case "$cell" in
        c) started="$MOVED_AT" ;;
        *) started="$B_VERIFIED_AT" ;;
      esac
      for _ in $(seq 1 $((FRESH + 90))); do
        [ -s "$WORK/observed-$cell" ] && break
        sleep 1
      done
      observed="$(cat "$WORK/observed-$cell" 2>/dev/null || true)"
      if [ -n "$observed" ]; then
        answer="$(json "{'observed': True, 'seconds': $((observed - started)), 'bound': $FRESH, 'slack': $SLACK}")"
      else
        answer="$(json "{'observed': False, 'bound': $FRESH}")"
      fi
      ;;
    c_window)
      user="$(restored_user "$C")"
      answer="$(identity_fixture "$C" segment "$user" |
        python3 -c "import json, sys; a = json.load(sys.stdin); a['waited'] = int(sys.argv[1]); print(json.dumps(a))" $((REAUTH + 5)))"
      ;;
    c_link_ticket)
      (umask 077 && python3 -c "import json, sys; open(sys.argv[2], 'w').write(json.load(open(sys.argv[1]))['cookie'])" "$ask" "$SECRETS/cookie")
      answer="$(identity_fixture "$C" link_ticket "@$SECRETS/cookie" "github|https://github.com|restored-door")"
      rm -f "$SECRETS/cookie"
      ;;
    people)
      answer="$(identity_fixture "$WORK/$(field "$(cat "$ask")" "['cell']")" people)"
      ;;
    a_down)
      server_stop "$THIEF"
      server_stop "$A"
      answer="$(json '{"down": True}')"
      ;;
    c2_accepted)
      kit="$(kit_file "$ask" kit-1.json)"
      identity_front_fault block-reads-after-recover
      accepted="$(post_restore "$C2" "$kit")"
      identity_front_fault none
      phase="$(last_restore "$C2" phase)"
      server_stop "$C2"
      answer="$(printf '%s' "$accepted" | python3 -c "import json, sys; a = json.load(sys.stdin); a['attempt_phase'] = sys.argv[1]; print(json.dumps(a))" "$phase")"
      ;;
    front_mark)
      b_resolve
      answer="$(identity_front_seen | python3 -c "import json, sys; print(json.dumps({'mark': len(json.load(sys.stdin)['seen'])}))")"
      ;;
    front_since)
      mark="$(field "$(cat "$ask")" "['mark']")"
      a_port="$(cell_port "$A")"
      if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$a_port/api/health" 2>/dev/null; then a_up=True; else a_up=False; fi
      answer="$(identity_front_seen | python3 -c "
import json, sys
seen = json.load(sys.stdin)['seen'][int(sys.argv[1]):]
print(json.dumps({'directory_only': bool(seen) and all(r['path'].startswith('/directory/v1/') for r in seen), 'requests': len(seen), 'a_answers': $a_up}))" "$mark")"
      head="$(field "$(identity_fixture "$C3" head "$(restored_user "$C3")")" "['head']")"
      (watch_b "$head" $((FRESH + 60)) >"$WORK/observed-c3") &
      ;;
    c2_resume)
      identity_start "$C2"
      resumed="$(post_restore "$C2" "$SECRETS/kit-1.json")"
      restores="$(identity_fixture "$C2" restores)"
      people="$(identity_fixture "$C2" people)"
      answer="$(python3 - "$resumed" "$restores" "$people" <<'PY'
import json, sys
resumed, restores, people = (json.loads(a) for a in sys.argv[1:])
last = restores["restores"][-1]
resumed.update({"phase": last["phase"], "staged": last["staged"], "people": len(people["people"])})
print(json.dumps(resumed))
PY
)"
      ;;
    directory_down)
      b_resolve
      within_verify="$(cat "$WORK/resolved.json")"
      identity_front_fault down
      within="$(identity_fixture "$B" fresh "$IDENTIFIER")"
      wait_s=$((B_VERIFIED_AT + FRESH + 3 - $(now)))
      [ "$wait_s" -gt 0 ] && sleep "$wait_s"
      past="$(identity_fixture "$B" fresh "$IDENTIFIER")"
      identity_front_fault none
      answer="$(python3 -c "import json, sys; print(json.dumps({'verified': json.loads(sys.argv[1]), 'within': json.loads(sys.argv[2]), 'past': json.loads(sys.argv[3]), 'bound': $FRESH}))" "$within_verify" "$within" "$past")"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
  [ -n "$answer" ] || answer='{"error":"the fixture answered nothing"}'
  printf '%s\n' "$answer" >"${ask%.json}.answer-part"
}

# Each step the proof asks for, answered once; an ask that carried a kit
# is emptied as soon as it is read.
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
    if grep -q '"kit"\|"cookie"' "$ask"; then : >"$ask"; fi
    mv "${ask%.json}.answer-part" "$OUT/answer-$id.json"
  done
}

step "the identity proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-* "$OUT"/answered-*
playwright_run identity-proof proof.mjs /authority/homes.json "$SEGMENT_A" "$COOKIE_A" /out &
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

echo "the record: $OUT/identity-proof.json and $OUT/identity-proof.md"
exit "$status"
