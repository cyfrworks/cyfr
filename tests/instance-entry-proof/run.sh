#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The instance-entry proof (README.md): a `cyfr` release started as the
# browser harness starts a home (tests/browser/harness.sh), home.test behind
# the harness's HTTPS front, its platform administrator signed in. In
# Chromium (proof.mjs) the administrator offers the instance's own entries
# from the Settings page, Ana signs in for the first time and is offered
# them, her claims meet the person cap, a narrowing and a revocation
# refuse her, Bea is denied at the door, and the administrator cannot
# enter Ana's athanor.
#
# The proof asks the server for its part through the output directory
# (`ask-N.json`), and this script answers each (`answer-N.json`): a
# person's sign-in through the release fixture's door
# (tests/release-boot/fixture.exs `person`), and the claims and reads of
# the proof's own fixture (tests/instance-entry-proof/fixture.exs), which
# answers bounded facts and never material.
#
# The harness runs no execution engine and no model, so no run is started:
# an admission is the loader's answer, and a claim is the resolver's, not
# a request sent anywhere (README.md).
#
# Usage: tests/instance-entry-proof/run.sh
# VAULT_PROOF_VIEWPORT is desktop (1280x900, the default) or 720x720.
# Writes instance-entry-proof.json and instance-entry-proof.md into
# PROOF_OUT (default: the scratch directory, kept with RELEASE_BOOT_KEEP=1).
# The release is the one a previous build left (RELEASE_BOOT_SKIP_BUILD=1,
# which this proof requires).
set -euo pipefail

# Every argument and environment check runs before WORK is made, so a
# refused start leaves nothing behind.
VIEWPORT="${VAULT_PROOF_VIEWPORT:-desktop}"
case "$VIEWPORT" in
  desktop | 720x720) ;;
  *)
    echo "::error::VAULT_PROOF_VIEWPORT is desktop or 720x720, not '$VIEWPORT'" >&2
    exit 1
    ;;
esac
[ "${RELEASE_BOOT_SKIP_BUILD:-}" = 1 ] || {
  echo "::error::build the release first and run with RELEASE_BOOT_SKIP_BUILD=1 (README.md)" >&2
  exit 1
}

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-instance-entry-proof-XXXXXX")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../release-boot/release.sh
source "$HERE/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""

stop_proof_container() {
  local ids
  ids="$(docker ps -q --filter "volume=$OUT" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 5 $ids >/dev/null 2>&1 || true
  fi
}

# The scratch directory holds the run's authority key, the cell's keys
# and its database, and each person's session token, so it goes even when
# a stop fails. `server_stop` ends in `fail`, an `exit`, when a listener
# outlives its stop, and an exit inside this trap would end it before the
# removal, so the stop runs in a subshell, whose exit ends only that
# subshell; the stop's failure still fails the run. The questions and
# answers carry the run's session cookies, so they go first; the record
# stays.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  rm -f "$OUT"/ask-* "$OUT"/answer-*
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

field() { printf '%s' "$1" | python3 -c "import json, sys; print(json.load(sys.stdin)['$2'])"; }
asked() { python3 -c "import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }

# The proof's fixture inside the running server, as `bin/cyfr rpc`. A
# command that raises answers nothing, which the proof reads as a failed
# step; what it raised is kept in the scratch directory, not the record.
entry_fixture() {
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"]/\\&/g')\","
  done
  cell_cyfr "$CELL" rpc \
    "{answer, _} = Code.eval_file(\"$HERE/fixture.exs\"); IO.puts(answer.([${args%,}]))" \
    2>>"$WORK/fixture.err" | sed -n 's/^ENTRY=//p' | tail -1 || :
}

# A person signed in through the release fixture's door, and the browser
# cookie of their session: what the proof opens their pages with. The
# session's token stays in the scratch directory, where the fixture's
# commands for that person take it from (`token_of`).
sign_in() {
  local email="$1" sub="$2" person token cookie
  person="$(server_fixture "$CELL" person "$email" "$sub" 2>>"$WORK/fixture.err")" || person=""
  [ -n "$person" ] || {
    printf '{"error":"%s was not signed in"}\n' "$email"
    return
  }
  token="$(field "$person" token)"
  (umask 077 && printf '%s' "$token" >"$WORK/token-$(field "$person" user_id)")
  cookie="$(browser_cookie "$CELL" "$token")"
  python3 -c "import json, sys; p = json.loads(sys.argv[1]); print(json.dumps({'user_id': p['user_id'], 'athanor_id': p['athanor_id'], 'segment': p['segment'], 'cookie': sys.argv[2]}))" \
    "$person" "$cookie"
}

# The session token of the person the proof names by `user_id`.
token_of() {
  token_of_user "$(asked "$1" user_id)"
}

# The session token of the person whose id is `$1`.
token_of_user() {
  local user_id="$1"
  [[ "$user_id" =~ ^[A-Za-z0-9_-]+$ ]] && [ -f "$WORK/token-$user_id" ] || {
    printf 'no-session'
    return
  }
  cat "$WORK/token-$user_id"
}

release_build

step "the run's authority and the home home.test"
browser_authority
CELL="$WORK/home"
browser_home "$CELL" home.test

step "starting home.test on a fresh SQLite cell"
server_start "$CELL"

step "the platform administrator, signed in"
admin="$(server_fixture "$CELL" person operator@example.com instance-entry-proof-admin)"
[ -n "$admin" ] || fail "the fixture signed the administrator in"
admin_segment="$(field "$admin" segment)"
admin_token="$(field "$admin" token)"
admin_cookie="$(browser_cookie "$CELL" "$admin_token")"

# Each step the proof asks for, answered once.
answer_asks() {
  local ask id op answer
  for ask in "$OUT"/ask-*.json; do
    [ -e "$ask" ] || continue
    id="${ask##*/ask-}"
    id="${id%.json}"
    [ -e "$OUT/answer-$id.json" ] && continue
    op="$(asked "$ask" op)"
    case "$op" in
      sign_in) answer="$(sign_in "$(asked "$ask" email)" "instance-entry-proof-$(asked "$ask" name)")" ;;
      clock) answer="$(entry_fixture clock)" ;;
      admin)
        answer="$(python3 -c "import json, sys; p = json.loads(sys.argv[1]); print(json.dumps({'user_id': p['user_id'], 'athanor_id': p['athanor_id']}))" "$admin")"
        ;;
      state)
        # A person not yet signed in is asked for as "".
        ana_token=-
        ana_id="$(asked "$ask" ana)"
        [ -n "$ana_id" ] && ana_token="$(token_of_user "$ana_id")"
        bea_id="$(asked "$ask" bea)"
        [ -n "$bea_id" ] || bea_id=-
        answer="$(entry_fixture state "$ana_token" "$bea_id" \
          "$(python3 -c "import json, sys; print(json.dumps(json.load(open(sys.argv[1]))['payloads']))" "$ask")")"
        ;;
      requested_digest)
        answer="$(entry_fixture requested_digest "$(asked "$ask" provider)" "$(asked "$ask" field)" \
          "$(python3 -c "import json, sys; print(json.dumps(json.load(open(sys.argv[1]))['destination']))" "$ask")")"
        ;;
      derived_head)
        answer="$(entry_fixture derived_head "$(token_of "$ask")" "$(asked "$ask" entry_id)" \
          "$(asked "$ask" provider)" "$(asked "$ask" field)" \
          "$(python3 -c "import json, sys; print(json.dumps(json.load(open(sys.argv[1]))['destination']))" "$ask")")"
        ;;
      admit) answer="$(entry_fixture admit "$(token_of "$ask")")" ;;
      claim)
        answer="$(entry_fixture claim "$(token_of "$ask")" "$(asked "$ask" entry_id)" \
          "$(asked "$ask" count)" "$(asked "$ask" url)" "$(asked "$ask" method)")"
        ;;
      row_binding) answer="$(entry_fixture row_binding "$(token_of "$ask")" "$(asked "$ask" entry_id)")" ;;
      focus) answer="$(entry_fixture focus "$admin_token" "$(asked "$ask" athanor_id)")" ;;
      *) fail "the proof asked for '$op', which this script does not do" ;;
    esac
    [ -n "$answer" ] || answer='{"error":"the fixture answered nothing"}'
    # An ask is removed once answered, before its answer appears: a state
    # ask carries the digests of the payloads the cards typed, and none may
    # outlive the read it was for.
    rm -f "$ask"
    printf '%s\n' "$answer" >"$OUT/answer-$id.part"
    mv "$OUT/answer-$id.part" "$OUT/answer-$id.json"
  done
}

step "the instance-entry proof in Chromium at $VIEWPORT, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run instance-entry-proof proof.mjs /authority/homes.json "$admin_segment" "$admin_cookie" /out \
  "$VIEWPORT" &
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

echo "the record: $OUT/instance-entry-proof.json and $OUT/instance-entry-proof.md"
exit "$status"
