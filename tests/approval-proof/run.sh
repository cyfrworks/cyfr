#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The approval proof (README.md): `cyfr` releases started as the browser
# harness starts homes (tests/browser/harness.sh), home.test and the
# directory dir.test behind the harness's HTTPS front, home.test reaching
# the directory through the identity proof's front
# (tests/identity-proof/front.sh and cells.sh). In Chromium (proof.mjs)
# one person makes her account at the directory's pages and sets home.test
# up by signing in with it, then grants the tincture approval-probe on the
# Components page: a
# dependency's need its publisher provides takes no key, two entries of one
# provider are chosen per edge, each binding is committed with its own
# lifetime, a once binding is used up and an until binding expires, a
# grant opened for a named account is committed, and a revocation refuses
# the next use.
#
# The proof asks the server for its part through the output directory
# (`ask-N.json`), and this script answers each (`answer-N.json`): the
# setup token, her session read from her browser's cookie (harness.sh
# `browser_session`), and the rest through the proof's fixture
# (tests/approval-proof/fixture.exs), which reads a
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
# (tests/browser/lib.mjs `redact`), and approval-proof.png, the page, unless
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-approval-proof-XXXXXX")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../release-boot/release.sh
source "$HERE/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=../identity-proof/front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=../identity-proof/cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""
NAME=approval-probe
APP="tincture:local.$NAME"

# The scratch directory holds the run's authority key, the cells' keys
# and their databases, the setup token and the person's session token, so
# it goes even when
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
  identity_front_stop
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

# The proof's fixture inside the running server, as `bin/cyfr rpc`. A
# command that raises answers nothing, which the proof reads as a failed
# step; what it raised is kept in the scratch directory, not the record.
approval_fixture() {
  cell_fixture "$CELL" "$HERE/fixture.exs" APPROVAL "$@" 2>>"$WORK/fixture.err" || :
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
  version="$(asked "$ask" manifest version)"
  approval_fixture publish "$token" "$dir" "$NAME" "$version"
}

release_build

step "the run's authority, the home home.test and the directory dir.test"
browser_authority
CELL="$WORK/home"
DIR="$WORK/dir"
browser_home "$CELL" home.test
browser_home "$DIR" dir.test
openssl rand -hex 32 | tr -d '\n' >"$WORK/setup-token"
identity_directory dir.test 127.77.0.1
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$CELL" dir.test
identity_env "$CELL" CYFR_REGISTRY_URL dir.test
identity_env "$CELL" CYFR_SETUP_TOKEN "$(cat "$WORK/setup-token")"

step "starting the directory, its front, and home.test on fresh SQLite cells"
server_start "$DIR"
identity_front_start "$DIR"
identity_start "$CELL"

# The person, once she signed in in the browser (`signed_in`).
user_id=""
athanor_id=""
token=""

# Each step the proof asks for (harness.sh `answer_asks`, which removes an
# ask once answered, before its answer appears: a state ask carries the
# digests of the keys the person typed, and none may outlive the read it
# was for).
answer_ask() {
  local ask="$1" op
  op="$(asked "$ask" op)"
  case "$op" in
    setup_token)
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'token': open(sys.argv[1]).read().strip()}))" "$WORK/setup-token")"
      ;;
    signed_in)
      (umask 077 && python3 -c "import json, sys; open(sys.argv[2], 'w').write(json.load(open(sys.argv[1]))['cookie'])" "$ask" "$WORK/cookie")
      session="$(browser_session "$CELL" "$WORK/cookie")"
      rm -f "$WORK/cookie"
      token="$(field "$session" token)"
      user_id="$(field "$session" user_id)"
      athanor_id="$(field "$session" athanor_id)"
      ANSWER="$(python3 -c "import json, sys; p = json.loads(sys.argv[1]); print(json.dumps({'user_id': p['user_id'], 'athanor_id': p['athanor_id'], 'segment': p['segment']}))" "$session")"
      ;;
    person)
      ANSWER="$(python3 -c "import json, sys; print(json.dumps({'user_id': sys.argv[1], 'athanor_id': sys.argv[2]}))" \
        "$user_id" "$athanor_id")"
      ;;
    clock) ANSWER="$(approval_fixture clock)" ;;
    publish) ANSWER="$(publish "$ask")" ;;
    state) ANSWER="$(approval_fixture state "$token" "$APP" "$ask")" ;;
    requested) ANSWER="$(approval_fixture requested "$token" "$ask")" ;;
    derived) ANSWER="$(approval_fixture derived "$token" "$ask")" ;;
    admit) ANSWER="$(approval_fixture admit "$token" "$APP")" ;;
    use) ANSWER="$(approval_fixture use "$token" "$APP" "$ask")" ;;
    thread) ANSWER="$(approval_fixture thread "$token")" ;;
    announce)
      ANSWER="$(approval_fixture announce "$token" "$APP" "$(asked "$ask" thread_id)" "$(asked "$ask" name)")"
      ;;
    account) ANSWER="$(approval_fixture account "$token" "$APP" "$(asked "$ask" name)")" ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the approval proof in Chromium at $VIEWPORT, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run approval-proof proof.mjs /authority/homes.json /out "$VIEWPORT" &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/approval-proof.json and $OUT/approval-proof.md"
exit "$PROOF_STATUS"
