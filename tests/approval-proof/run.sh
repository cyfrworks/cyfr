#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The approval proof (README.md): a `cyfr` release started as the browser
# harness starts a home (tests/browser/harness.sh), home.test behind the
# harness's HTTPS front, one person signed in. In Chromium (proof.mjs) the
# person grants the tincture approval-probe on the Components page: a
# dependency's need its publisher provides takes no key, two entries of one
# provider are chosen per edge, each binding is committed with its own
# lifetime, a once binding is used up and an until binding expires, a
# grant opened for a named account is committed, and a revocation refuses
# the next use.
#
# The proof asks the server for its part through the output directory
# (`ask-N.json`), and this script answers each (`answer-N.json`) through
# the proof's fixture (tests/approval-proof/fixture.exs), which reads a
# question's own file by path and answers bounded facts, never material.
# The tincture the proof describes is written here into the scratch
# directory and installed through the release's own path.
#
# The harness runs no execution engine and no model, so no run is started
# and no request is sent: an admission is the loader's answer, a use is
# the use path's decision, and the named-account prompt is raised by the
# event a turn would announce, with no turn (README.md).
#
# Usage: tests/approval-proof/run.sh
# VAULT_PROOF_VIEWPORT is desktop (1280x900, the default) or 720x720.
# Writes approval-proof.json and approval-proof.md into PROOF_OUT
# (default: the scratch directory, kept with RELEASE_BOOT_KEEP=1). The
# release is the one a previous build left (RELEASE_BOOT_SKIP_BUILD=1,
# which this proof requires).
# A failed run also leaves approval-proof-frames.json, the page's last
# socket frames with every value the proof knows to be secret replaced
# (tests/grant-proof/redact.mjs), and approval-proof.png, the page, unless
# the page could then show a key the person typed, when the record says
# the screenshot was withheld. Records and browser-process diagnostics use
# the same rule, including the typed keys' and typed payloads' digests.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-approval-proof-XXXXXX")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../release-boot/release.sh
source "$HERE/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""
NAME=approval-probe
APP="tincture:local.$NAME"

stop_proof_container() {
  local ids
  ids="$(docker ps -q --filter "volume=$OUT" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 5 $ids >/dev/null 2>&1 || true
  fi
}

# The scratch directory holds the run's authority key, the cell's keys
# and its database, and the person's session token, so it goes even when
# a stop fails. `server_stop` ends in `fail`, an `exit`, when a listener
# outlives its stop, and an exit inside this trap would end it before the
# removal, so the stop runs in a subshell, whose exit ends only that
# subshell; the stop's failure still fails the run. The questions carry
# digests of the keys the person typed, and their answers stand beside
# them, so both go on every exit, a kept or outside PROOF_OUT included;
# the record and a failed run's two artifacts stay.
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
approval_fixture() {
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"]/\\&/g')\","
  done
  cell_cyfr "$CELL" rpc \
    "{answer, _} = Code.eval_file(\"$HERE/fixture.exs\"); IO.puts(answer.([${args%,}]))" \
    2>>"$WORK/fixture.err" | sed -n 's/^APPROVAL=//p' | tail -1 || :
}

# The tincture the proof describes, written into the scratch directory as
# a locally built tincture's tree, then installed through the release's
# own path (fixture.exs `publish`).
publish() {
  local ask="$1" dir="$WORK/tincture/$NAME" version
  mkdir -p "$dir"
  python3 -c "
import json, sys
ask = json.load(open(sys.argv[1]))
with open(sys.argv[2] + '/cyfr-manifest.json', 'w') as out:
    json.dump(ask['manifest'], out, indent=2)
with open(sys.argv[2] + '/index.html', 'w') as out:
    out.write(ask['index'])
" "$ask" "$dir"
  version="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['manifest']['version'])" "$ask")"
  approval_fixture publish "$token" "$dir" "$NAME" "$version"
}

release_build

step "the run's authority and the home home.test"
browser_authority
CELL="$WORK/home"
browser_home "$CELL" home.test

step "starting home.test on a fresh SQLite cell"
server_start "$CELL"

step "one person, signed in"
person="$(server_fixture "$CELL" person operator@example.com approval-proof)"
[ -n "$person" ] || fail "the fixture signed nobody in"
user_id="$(field "$person" user_id)"
athanor_id="$(field "$person" athanor_id)"
segment="$(field "$person" segment)"
token="$(field "$person" token)"
cookie="$(browser_cookie "$CELL" "$token")"

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
      person)
        answer="$(python3 -c "import json, sys; print(json.dumps({'user_id': sys.argv[1], 'athanor_id': sys.argv[2]}))" \
          "$user_id" "$athanor_id")"
        ;;
      clock) answer="$(approval_fixture clock)" ;;
      publish) answer="$(publish "$ask")" ;;
      state) answer="$(approval_fixture state "$token" "$APP" "$ask")" ;;
      requested) answer="$(approval_fixture requested "$token" "$ask")" ;;
      derived) answer="$(approval_fixture derived "$token" "$ask")" ;;
      admit) answer="$(approval_fixture admit "$token" "$APP")" ;;
      use) answer="$(approval_fixture use "$token" "$APP" "$ask")" ;;
      thread) answer="$(approval_fixture thread "$token")" ;;
      announce)
        answer="$(approval_fixture announce "$token" "$APP" "$(asked "$ask" thread_id)" "$(asked "$ask" name)")"
        ;;
      account) answer="$(approval_fixture account "$token" "$APP" "$(asked "$ask" name)")" ;;
      *) fail "the proof asked for '$op', which this script does not do" ;;
    esac
    [ -n "$answer" ] || answer='{"error":"the fixture answered nothing"}'
    # An ask is removed once answered, before its answer appears: a state
    # ask carries the digests of the keys the person typed, and none may
    # outlive the read it was for.
    rm -f "$ask"
    printf '%s\n' "$answer" >"$OUT/answer-$id.part"
    mv "$OUT/answer-$id.part" "$OUT/answer-$id.json"
  done
}

step "the approval proof in Chromium at $VIEWPORT, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run approval-proof proof.mjs /authority/homes.json "$segment" "$cookie" /out "$VIEWPORT" &
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

echo "the record: $OUT/approval-proof.json and $OUT/approval-proof.md"
exit "$status"
