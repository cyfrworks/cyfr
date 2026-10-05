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
# its need's reason asks nothing; and a revocation is measured at
# admission.
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
# secret replaced (redact.mjs).
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-grant-proof-XXXXXX")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../release-boot/release.sh
source "$HERE/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""
NAME=grant-probe
REF="tincture:local.$NAME"

stop_proof_container() {
  local ids
  ids="$(docker ps -q --filter "volume=$OUT" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 5 $ids >/dev/null 2>&1 || true
  fi
}

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

field() { printf '%s' "$1" | python3 -c "import json, sys; print(json.load(sys.stdin)['$2'])"; }

# The proof's fixture inside the running server, as `bin/cyfr rpc`.
grant_fixture() {
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"]/\\&/g')\","
  done
  cell_cyfr "$CELL" rpc \
    "{answer, _} = Code.eval_file(\"$HERE/fixture.exs\"); IO.puts(answer.([${args%,}]))" \
    | sed -n 's/^GRANT=//p' | tail -1
}

release_build

step "the command line, built from apps/codex"
(cd "$ROOT/apps/codex" && GOFLAGS=-mod=mod go build -o "$WORK/cyfr" .) || fail "the CLI did not build"

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

# Each step the proof asks for, answered once.
answer_asks() {
  local ask id op answer decisions
  for ask in "$OUT"/ask-*.json; do
    [ -e "$ask" ] || continue
    id="${ask##*/ask-}"
    id="${id%.json}"
    [ -e "$OUT/answer-$id.json" ] && continue
    op="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['op'])" "$ask")"
    case "$op" in
      head) answer="$(grant_fixture head "$user_id" "$REF")" ;;
      plan) answer="$(grant_fixture plan "$token" "$REF")" ;;
      admit) answer="$(grant_fixture admit "$user_id" "$REF")" ;;
      publish)
        version="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['version'])" "$ask")"
        variant="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['variant'])" "$ask")"
        answer="$(grant_fixture publish "$user_id" "$HERE/tinctures/$NAME" "$NAME" "$version" "$variant")"
        ;;
      revoke)
        profile_id="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['profile_id'])" "$ask")"
        answer="$(grant_fixture revoke "$user_id" "$token" "$profile_id" "$REF")"
        ;;
      cli_preview)
        # The command line's preview of exactly the decisions the proof
        # names, over /mcp with the person's session as its credential.
        decisions="$(python3 -c "import json, sys; print(json.dumps({'action': 'preview', 'decisions': json.load(open(sys.argv[1]))['decisions']}))" "$ask")"
        answer="$(CYFR_TOKEN="$token" HOME="$WORK/cli-home" "$WORK/cyfr" call profile "$decisions" \
          --url "http://127.0.0.1:$PORT_HOME" --json 2>"$OUT/cli-$id.err" || true)"
        [ -n "$answer" ] || answer="{\"error\":$(python3 -c "import json, sys; print(json.dumps(open(sys.argv[1]).read()))" "$OUT/cli-$id.err")}"
        ;;
      *) fail "the proof asked for '$op', which this script does not do" ;;
    esac
    [ -n "$answer" ] || answer='{"error":"the fixture answered nothing"}'
    printf '%s\n' "$answer" >"$OUT/answer-$id.part"
    mv "$OUT/answer-$id.part" "$OUT/answer-$id.json"
  done
}

step "the grant proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT" "$WORK/cli-home"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run grant-proof proof.mjs /authority/homes.json "$segment" "$cookie" /out &
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

echo "the record: $OUT/grant-proof.json and $OUT/grant-proof.md"
exit "$status"
