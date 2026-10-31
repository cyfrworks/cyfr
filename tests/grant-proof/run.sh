#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The grant proof (README.md): a `cyfr` release started as the browser
# harness starts a home (tests/browser/harness.sh), home.test behind the
# harness's HTTPS front, one person signed in, and their tincture
# grant-probe published. In Chromium (proof.mjs) the person grants it on
# the console's Components page, narrowed and admitting interactive alone;
# the command line previews the same decisions; a version asking to run
# in the background is shown and asked again; a version that only rewords
# its need's reason asks nothing; a version that lets one more class reach
# the host the person kept is asked again, the new flow ticked and granted
# under the digest the command line previews; a key a second person shares
# with everyone is picked for the tincture's need on the grant prompt and
# the tincture's attached request carries it; and a revocation is measured
# at admission.
#
# The proof asks the server for its part through the output directory
# (`ask-N.json`), and this script answers each (`answer-N.json`) through
# the proof's fixture (tests/grant-proof/fixture.exs) and the command line
# (`cyfr call`, built from apps/codex).
#
# The harness runs no execution engine and no model, so the steps that
# need one are the suite's (README.md).
#
# Usage: tests/grant-proof/run.sh
# Writes grant-proof.json and grant-proof.md into PROOF_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1). The release is the one
# a previous build left (RELEASE_BOOT_SKIP_BUILD=1, which this proof
# requires): build it as release.sh's `release_build` does, without
# fetching dependencies.
# A failed run also leaves prism-grant.png and prism-grant-frames.json: the
# page, and its last socket frames with every value the proof knows to be
# secret replaced (tests/browser/lib.mjs `redact`).
# The record, grant-proof.json and grant-proof.md, is written under the
# same rule.
set -euo pipefail

# Every argument and environment check runs before WORK is made, so a
# refused start leaves nothing behind.
[ "${RELEASE_BOOT_SKIP_BUILD:-}" = 1 ] || {
  echo "::error::build the release first and run with RELEASE_BOOT_SKIP_BUILD=1 (README.md)" >&2
  exit 1
}

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-grant-proof-XXXXXX")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../release-boot/release.sh
source "$HERE/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""
NAME=grant-probe
REF="tincture:local.$NAME"

# The scratch directory holds the run's authority key, so it goes even
# when a stop fails. `server_stop` ends in `fail`, an `exit`, when a
# listener outlives its stop, and an exit inside this trap would end it
# before the removal, so the stop runs in a subshell, whose exit ends only
# that subshell; the stop's failure still fails the run.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  # The questions and answers carry the command line's preview, its proof
  # among them, and the command line's own errors beside them, so they go
  # on every exit, a kept or outside PROOF_OUT included; the record stays.
  rm -f "$OUT"/ask-* "$OUT"/answer-* "$OUT"/cli-*.err
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

# The proof's fixture inside the running server, as `bin/cyfr rpc`.
grant_fixture() {
  cell_fixture "$CELL" "$HERE/fixture.exs" GRANT "$@"
}

step "the head predicates, on heads alone"
node --test "$HERE/heads-test.mjs" || fail "the head predicates failed their own tests (heads-test.mjs)"

release_build

step "the command line, built from apps/codex"
# -mod=readonly: the build reads go.mod and go.sum as they are and never
# rewrites them.
(cd "$ROOT/apps/codex" && go build -mod=readonly -o "$WORK/cyfr" .) || fail "the CLI did not build"

step "the run's authority and the home home.test"
browser_authority
CELL="$WORK/home"
browser_home "$CELL" home.test

step "starting home.test on a fresh SQLite cell"
server_start "$CELL"
PORT_HOME="$(cell_port "$CELL")"

step "one person, signed in"
person="$(server_fixture "$CELL" person operator@example.com grant-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
user_id="$(field "$person" user_id)"
segment="$(field "$person" segment)"
token="$(field "$person" token)"
cookie="$(browser_cookie "$CELL" "$token")"
browser_picker_layout "$CELL" "$token"

step "grant-probe 1.0.0, asking for two hosts, a folder and a key it can go without"
published="$(grant_fixture publish "$user_id" "$HERE/tinctures/$NAME" "$NAME" 1.0.0 base)"
printf '%s' "$published" | grep -q '"version":"1.0.0"' || fail "grant-probe was not published: $published"
filed="$(grant_fixture file "$user_id" data/probe/notes/today.md)"
printf '%s' "$filed" | grep -q 'data/probe/notes' || fail "the probe's folder was not written: $filed"

# The destination a question names, as JSON.
destination() {
  python3 -c "import json, sys; print(json.dumps(json.load(open(sys.argv[1]))['destination']))" "$1"
}

# Each step the proof asks for (harness.sh `answer_asks`).
answer_ask() {
  local ask="$1" id="$2" op decisions
  op="$(asked "$ask" op)"
  case "$op" in
    head) ANSWER="$(grant_fixture head "$user_id" "$REF")" ;;
    plan) ANSWER="$(grant_fixture plan "$token" "$REF")" ;;
    admit) ANSWER="$(grant_fixture admit "$user_id" "$REF")" ;;
    publish)
      ANSWER="$(grant_fixture publish "$user_id" "$HERE/tinctures/$NAME" "$NAME" "$(asked "$ask" version)" "$(asked "$ask" variant)")"
      ;;
    revoke)
      ANSWER="$(grant_fixture revoke "$user_id" "$token" "$(asked "$ask" profile_id)" "$REF")"
      ;;
    owner)
      # The owner of the shared key: a second person, signed in once the
      # door admits newcomers (fixture.exs `door`), through the release
      # fixture's door as the first person was.
      opened="$(grant_fixture door "$token")"
      printf '%s' "$opened" | grep -q '"door":"\*"' || fail "the door did not open to newcomers: $opened"
      owner="$(server_fixture "$CELL" person owner@example.com grant-proof-owner Olive)"
      [ -n "$owner" ] || fail "the fixture signed the owner in"
      ANSWER="$(python3 -c "import json, sys; p = json.loads(sys.argv[1]); print(json.dumps({'user_id': p['user_id'], 'athanor_id': p['athanor_id']}))" "$owner")"
      ;;
    share)
      ANSWER="$(grant_fixture share "$(asked "$ask" owner)" "$(destination "$ask")")"
      ;;
    me)
      ANSWER="$(python3 -c "import json, sys; p = json.loads(sys.argv[1]); print(json.dumps({'user_id': p['user_id'], 'athanor_id': p['athanor_id']}))" "$person")"
      ;;
    requested) ANSWER="$(grant_fixture requested "$(destination "$ask")")" ;;
    clock) ANSWER="$(grant_fixture clock)" ;;
    shared) ANSWER="$(grant_fixture shared "$user_id" "$REF" "$(asked "$ask" share_id)")" ;;
    attach)
      ANSWER="$(grant_fixture attach "$token" "$REF" "$(asked "$ask" owner)" "$(asked "$ask" entry_id)" \
        "$(asked "$ask" url)" "$(asked "$ask" method)")"
      ;;
    cli_preview)
      # The command line's preview of exactly the decisions the proof
      # names, over /mcp with the person's session as its credential.
      decisions="$(python3 -c "import json, sys; print(json.dumps({'action': 'preview', 'decisions': json.load(open(sys.argv[1]))['decisions']}))" "$ask")"
      ANSWER="$(CYFR_TOKEN="$token" HOME="$WORK/cli-home" "$WORK/cyfr" call profile "$decisions" \
        --url "http://127.0.0.1:$PORT_HOME" --json 2>"$OUT/cli-$id.err" || true)"
      [ -n "$ANSWER" ] || ANSWER="{\"error\":$(python3 -c "import json, sys; print(json.dumps(open(sys.argv[1]).read()))" "$OUT/cli-$id.err")}"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the grant proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT" "$WORK/cli-home"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run grant-proof proof.mjs /authority/homes.json "$segment" "$cookie" /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/grant-proof.json and $OUT/grant-proof.md"
exit "$PROOF_STATUS"
