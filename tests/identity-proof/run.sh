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
# through a front of this proof's own (front.sh, cells.sh), and the
# cyfr.run stand-in (tests/registry-stand-in/standin.py) as every home's
# registry, naming dir.test as the directory of every name it holds.
# proof.mjs drives Chromium through A's setup, its two screens and their
# recovery code, a second recovery code, a rotation, the restores and what
# each home sees; this script answers its asks for the homes' part
# (`ask-N.json`, answered `answer-N.json`): cells stopped, copied, killed
# and started again, the directory broken on purpose, restores posted at a
# phase, and what a home and the stand-in hold.
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
# fails: the cells' servers, the stand-in, the directory's front
# container, the Playwright container, and the scratch directory with the
# run's authority key, every token and every recovery code.
set -euo pipefail

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-identity-proof-XXXXXX")"
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
# The cyfr.run stand-in: a loopback address of the identity proofs' block
# (the fronts hold 127.77.0.1 to .3) and the port it picks free.
STANDIN_ADDRESS=127.77.0.4
STANDIN_PORT=""
STANDIN_PID=""

# The scratch directory holds the run's authority key, the tokens and the
# recovery codes, so it goes even when a stop fails; the asks and answers
# that held a recovery code or a token go from PROOF_OUT too.
# `server_stop` ends in `fail`, an `exit`, when a listener outlives its
# stop, so it runs in a subshell: the exit ends that subshell, never this
# trap before the removals below, and the stop's failure still fails the
# run.
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
cell_pick_port THIEF_PORT

for cell in c c2 c3; do
  openssl rand -hex 32 | tr -d '\n' >"$SECRETS/token-$cell"
done
# A's setup token, the one A's first person is set up under.
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/token-a"

identity_directory dir.test 127.77.0.1
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$A" dir.test
identity_reaches_directory "$B" dir.test "CYFR_IDENTITY_FRESHNESS_SECONDS=$FRESH"
identity_reaches_directory "$C" dir.test "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-c")" \
  "CYFR_REAUTH_SECONDS=$REAUTH"
identity_reaches_directory "$C2" dir.test "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-c2")"
identity_reaches_directory "$C3" dir.test "CYFR_RESTORE_TOKEN=$(cat "$SECRETS/token-c3")"

step "the cyfr.run stand-in, every home's registry"
standin_start
echo "the stand-in answers at http://$STANDIN_ADDRESS:$STANDIN_PORT"
for cell in "$A" "$B" "$C" "$C2" "$C3"; do
  identity_env "$cell" CYFR_REGISTRY_URL "$STANDIN_ADDRESS:$STANDIN_PORT"
  identity_env "$cell" CYFR_PRIVATE_EGRESS_TARGETS "$(cell_value "$cell" CYFR_PRIVATE_EGRESS_TARGETS),$STANDIN_ADDRESS"
done
identity_env "$A" CYFR_SETUP_TOKEN "$(cat "$SECRETS/token-a")"

step "starting the directory, its front, and the homes"
server_start "$DIR"
identity_front_start "$DIR"
for cell in "$A" "$B" "$C" "$C2" "$C3"; do identity_start "$cell"; done

# A's person, whom the browser sets up (`a_person`).
USER_A=""
IDENTIFIER=""
MOVED_AT=0
B_VERIFIED_AT=0

# The recovery code an ask carries (proof.mjs, lib.mjs `readCode`), as
# the restore ingress takes it, `{"recovery_code": code}`, written where
# only this run reads it.
code_file() {
  local ask="$1" name="$2"
  (umask 077 && python3 -c "import json, sys; json.dump({'recovery_code': json.load(open(sys.argv[1]))['code']['code']}, open(sys.argv[2], 'w'))" "$ask" "$SECRETS/$name")
  printf '%s' "$SECRETS/$name"
}

# The restore attempts of cell `$1`, the last one's field `$2`.
last_restore() { field "$(identity_fixture "$1" restores)" restores -1 "$2"; }

restored_user() { field "$(identity_fixture "$1" people)" people 0 user_id; }

# B's view, polled every two seconds from now until it names `$1`, or
# `$2` seconds pass; prints the epoch second it did, or nothing.
watch_b() {
  local target="$1" limit="$2" until answer
  until=$(($(now) + limit))
  while [ "$(now)" -le "$until" ]; do
    answer="$(identity_fixture "$B" fresh "$IDENTIFIER")"
    if [ "$(field "$answer" key_epoch 2>/dev/null)" = "$target" ]; then
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

# Restore posted to cell `$1` with its own token and the recovery code's
# file `$2` (`code_file`); prints `{status, phase, error}` of the answer.
post_restore() {
  local cell="$1" code="$2" name status
  name="$(basename "$cell")"
  status="$(identity_restore_post "$cell" /restore "$SECRETS/token-$name" "$code" "$WORK/answer.json")"
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

# Each step the proof asks for (harness.sh `answer_asks`, which removes
# each ask, one that carried a recovery code or a cookie among them,
# before its answer appears).
answer_ask() {
  local ask="$1" op code started observed target
  op="$(asked "$ask" op)"
  case "$op" in
    a_person)
      # A's one person, whom the browser set up, and their athanor's route
      # segment.
      people="$(identity_fixture "$A" people)"
      USER_A="$(field "$people" people 0 user_id)"
      ANSWER="$(python3 - "$people" "$(identity_fixture "$A" segment "$USER_A")" <<'PY'
import json, sys
people, segment = (json.loads(a) for a in sys.argv[1:])
first = people["people"][0]
print(json.dumps({"people": len(people["people"]), "user_id": first["user_id"], "admission": first["admission"],
                  "segment": segment["segment"]}))
PY
)"
      ;;
    a_head)
      ANSWER="$(identity_fixture "$A" head "$USER_A")"
      ;;
    handle_answer)
      # The stand-in's answer for the name, who its state says holds it,
      # and the directory A's genesis and enrollment attempt name.
      name="$(asked "$ask" name)"
      status="$(curl -sS -m 10 -o "$WORK/handle.json" -w '%{http_code}' \
        "http://$STANDIN_ADDRESS:$STANDIN_PORT/v1/handles/$name")" || status=0
      ANSWER="$(python3 - "$status" "$WORK/handle.json" "$(identity_fixture "$A" genesis "$USER_A")" "$WORK/cyfr-run.json" "$name" <<'PY'
import json, sys
status, body, genesis, state, name = sys.argv[1:]
try:
    answer = json.load(open(body))
except Exception:
    answer = None
genesis = json.loads(genesis)
print(json.dumps({"status": int(status), "answer": answer, "held_by": json.load(open(state))["names"].get(name),
                  "genesis_directory": genesis["genesis"].get("directory"), "attempt_directory": genesis["directory_url"]}))
PY
)"
      ;;
    b_resolve)
      genesis="$(identity_fixture "$A" genesis "$USER_A")"
      IDENTIFIER="$(field "$genesis" identifier)"
      printf '%s' "$genesis" | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['genesis']))" >"$WORK/genesis.json"
      b_resolve
      ANSWER="$(cat "$WORK/resolved.json")"
      ;;
    preserve_a)
      # The thief's copy: A stopped, copied whole, and both started again.
      server_stop "$A"
      identity_preserved "$A" "$THIEF" thief.test "$THIEF_PORT"
      identity_start "$A"
      identity_start "$THIEF"
      ANSWER="$(json '{"preserved": True}')"
      ;;
    c_setup)
      # Setup: the admission that would make anywhere else's first person.
      ANSWER="$(identity_fixture "$C" setup)"
      ;;
    token)
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$SECRETS/token-$(asked "$ask" cell)")"
      ;;
    c_claims)
      code="$(code_file "$ask" code-2.json)"
      # Another cell's token; a recovery code of an identity the directory
      # never saw; a code of this identity whose secret holds no recovery
      # key of it; and this identity's code with one symbol changed. Each
      # forged code is composed here as Prima.RecoveryCode composes one, the
      # one place outside Prima that does; proof.mjs holds each refusal to
      # its reason, so a code composed wrongly is refused as not_a_code and
      # fails the step.
      other="$(identity_restore_post "$C" /restore "$SECRETS/token-c2" "$code" "$WORK/answer.json")"
      python3 - "$ask" "$SECRETS/unknown.json" "$SECRETS/wrong-secret.json" "$SECRETS/typo.json" <<'PY'
import hashlib, json, os, sys
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
def recovery_code(identifier, secret):
    digest = bytes.fromhex(identifier[4:])
    check = hashlib.sha256(b"cyfr-recovery-code/v1" + b"\0" + digest + secret).digest()[:6]
    n = int.from_bytes(digest + secret + check, "big")
    symbols = "".join(ALPHABET[(n >> (5 * (111 - i))) & 31] for i in range(112))
    return "CYFR-" + "-".join(symbols[i:i + 8] for i in range(0, 112, 8))
held = json.load(open(sys.argv[1]))["code"]
identifier, code = held["identifier"], held["code"]
json.dump({"recovery_code": recovery_code("per_" + os.urandom(32).hex(), os.urandom(32))}, open(sys.argv[2], "w"))
json.dump({"recovery_code": recovery_code(identifier, os.urandom(32))}, open(sys.argv[3], "w"))
json.dump({"recovery_code": code[:-1] + ("1" if code[-1] == "0" else "0")}, open(sys.argv[4], "w"))
PY
      unknown="$(post_restore "$C" "$SECRETS/unknown.json")"
      wrong="$(post_restore "$C" "$SECRETS/wrong-secret.json")"
      typo="$(post_restore "$C" "$SECRETS/typo.json")"
      attempts="$(identity_fixture "$C" restores | python3 -c "import json, sys; print(len(json.load(sys.stdin)['restores']))")"
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'other_token': int(sys.argv[1]), 'unknown_identity': json.loads(sys.argv[2]), 'wrong_secret': json.loads(sys.argv[3]), 'typo': json.loads(sys.argv[4]), 'attempts': int(sys.argv[5])}))" \
        "$other" "$unknown" "$wrong" "$typo" "$attempts")"
      ;;
    c_phases)
      code="$(code_file "$ask" code-2.json)"
      log_before="$(identity_fixture "$DIR" log "$IDENTIFIER")"
      # submitted: the directory's reply lost, a thief rotating at the same
      # moment on the copy of A.
      identity_front_fault dir.test drop-recover
      identity_fixture "$THIEF" thief_rotate "$USER_A" >"$WORK/thief-1.json" &
      thief_pid=$!
      submitted="$(post_restore "$C" "$code")"
      wait "$thief_pid" || true
      MOVED_AT="$(now)"
      submitted_phase="$(last_restore "$C" phase)"
      head="$(field "$(identity_fixture "$DIR" log "$IDENTIFIER")" head)"
      # B watched from the move on, in the background.
      (watch_b "$head" $((FRESH + 60)) >"$WORK/observed-c") &
      identity_kill "$C"
      identity_start "$C"
      replay="$(identity_fixture "$C" replay_recover)"
      thief_2="$(identity_fixture "$THIEF" thief_rotate "$USER_A")"
      # accepted: the recovery answered, the head it must read again unread.
      identity_front_fault dir.test block-reads-after-recover
      accepted="$(post_restore "$C" "$code")"
      identity_front_fault dir.test none
      accepted_phase="$(last_restore "$C" phase)"
      accepted_entry="$(last_restore "$C" entry_hash)"
      identity_kill "$C"
      identity_start "$C"
      log="$(identity_fixture "$DIR" log "$IDENTIFIER")"
      final_head="$(field "$log" head)"
      ANSWER="$(python3 - "$submitted" "$submitted_phase" "$accepted" "$accepted_phase" "$accepted_entry" \
        "$replay" "$log" "$WORK/thief-1.json" "$thief_2" "$final_head" \
        "$log_before" <<'PY'
import json, sys
(submitted, submitted_phase, accepted, accepted_phase, accepted_entry,
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
    "replay": replay,
    # The recoveries this restore added to the log: the added recovery
    # code's entry before it is a recovery too.
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
      cell="$(asked "$ask" cell)"
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
        ANSWER="$(json "{'observed': True, 'seconds': $((observed - started)), 'bound': $FRESH, 'slack': $SLACK}")"
      else
        ANSWER="$(json "{'observed': False, 'bound': $FRESH}")"
      fi
      ;;
    c_window)
      user="$(restored_user "$C")"
      ANSWER="$(identity_fixture "$C" segment "$user" |
        python3 -c "import json, sys; a = json.load(sys.stdin); a['waited'] = int(sys.argv[1]); print(json.dumps(a))" $((REAUTH + 5)))"
      ;;
    c_link_ticket)
      (umask 077 && python3 -c "import json, sys; open(sys.argv[2], 'w').write(json.load(open(sys.argv[1]))['cookie'])" "$ask" "$SECRETS/cookie")
      ANSWER="$(identity_fixture "$C" link_ticket "@$SECRETS/cookie" "github|https://github.com|restored-door")"
      rm -f "$SECRETS/cookie"
      ;;
    people)
      ANSWER="$(identity_fixture "$WORK/$(asked "$ask" cell)" people)"
      ;;
    a_down)
      server_stop "$THIEF"
      server_stop "$A"
      ANSWER="$(json '{"down": True}')"
      ;;
    c2_accepted)
      code="$(code_file "$ask" code-1.json)"
      identity_front_fault dir.test block-reads-after-recover
      accepted="$(post_restore "$C2" "$code")"
      identity_front_fault dir.test none
      phase="$(last_restore "$C2" phase)"
      server_stop "$C2"
      ANSWER="$(printf '%s' "$accepted" | python3 -c "import json, sys; a = json.load(sys.stdin); a['attempt_phase'] = sys.argv[1]; print(json.dumps(a))" "$phase")"
      ;;
    front_mark)
      b_resolve
      ANSWER="$(identity_front_seen dir.test | python3 -c "import json, sys; print(json.dumps({'mark': len(json.load(sys.stdin)['seen'])}))")"
      ;;
    front_since)
      mark="$(asked "$ask" mark)"
      a_port="$(cell_port "$A")"
      if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$a_port/api/health" 2>/dev/null; then a_up=True; else a_up=False; fi
      ANSWER="$(identity_front_seen dir.test | python3 -c "
import json, sys
seen = json.load(sys.stdin)['seen'][int(sys.argv[1]):]
print(json.dumps({'directory_only': bool(seen) and all(r['path'].startswith('/directory/v1/') for r in seen), 'requests': len(seen), 'a_answers': $a_up}))" "$mark")"
      head="$(field "$(identity_fixture "$C3" head "$(restored_user "$C3")")" head)"
      (watch_b "$head" $((FRESH + 60)) >"$WORK/observed-c3") &
      ;;
    c2_resume)
      identity_start "$C2"
      resumed="$(post_restore "$C2" "$SECRETS/code-1.json")"
      restores="$(identity_fixture "$C2" restores)"
      people="$(identity_fixture "$C2" people)"
      ANSWER="$(python3 - "$resumed" "$restores" "$people" <<'PY'
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
      identity_front_fault dir.test down
      within="$(identity_fixture "$B" fresh "$IDENTIFIER")"
      wait_s=$((B_VERIFIED_AT + FRESH + 3 - $(now)))
      [ "$wait_s" -gt 0 ] && sleep "$wait_s"
      past="$(identity_fixture "$B" fresh "$IDENTIFIER")"
      identity_front_fault dir.test none
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'verified': json.loads(sys.argv[1]), 'within': json.loads(sys.argv[2]), 'past': json.loads(sys.argv[3]), 'bound': $FRESH}))" "$within_verify" "$within" "$past")"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the identity proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run identity-proof proof.mjs /authority/homes.json /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/identity-proof.json and $OUT/identity-proof.md"
exit "$PROOF_STATUS"
