#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The setup proof in the app (app.sh) removes only what it made, and says
# when it could not, against a stand-in docker that records every call:
#   taken    the client's name is taken (run answers a conflict): the run
#            fails saying so, and no removal is sent, by name or otherwise
#   kept     the client made, its setup failed and its removal refused: the
#            run fails naming the container left, and keeps its scratch
#            directory for a retry, starting no cleanup container
# Usage: tests/setup-proof/app-cleanup-test.sh
# It needs node and npm's install of apps/codex/desktop (app.sh packs its
# proof before it makes anything), and python3.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-setup-app-cleanup-test.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/bin"
: >"$BASE/app.deb"
cat >"$BASE/bin/docker" <<'STANDIN'
#!/bin/sh
# Every call is recorded; the case says what run and rm answer.
echo "$*" >>"$STANDIN_CALLS"
case "$STANDIN_CASE $1" in
  "taken run") case " $* " in *"-client "*)
    echo "docker: Error response from daemon: Conflict. The container name is already in use by container \"0123\"." >&2; exit 125;; esac ;;
  "kept run") case " $* " in *"-client "*) echo c0ffee1234; exit 0;; esac ;;
  "kept exec") exit 1 ;;
  "kept rm") echo "Error response from daemon: cannot remove container" >&2; exit 1 ;;
esac
exit 0
STANDIN
chmod +x "$BASE/bin/docker"

failures=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
run_case() {
  mkdir -p "$BASE/$1/tmp" "$BASE/$1/out"; : >"$BASE/$1/calls"
  set +e
  PATH="$BASE/bin:$PATH" STANDIN_CASE=$1 STANDIN_CALLS="$BASE/$1/calls" TMPDIR="$BASE/$1/tmp" PROOF_RUN_PREFIX= \
    SETUP_PROOF_OUT="$BASE/$1/out" bash "$HERE/app.sh" "$BASE/app.deb" cyfr:none >"$BASE/$1/log" 2>&1
  status=$?
  set -e
}

run_case taken
check "taken: the run fails saying the client's name could not be taken" \
  '[ "$status" != 0 ] && grep -q "^FAIL the client .*-client could not be made" "$BASE/taken/log"'
check "taken: no removal is sent" '! grep -qE "^(rm|container rm|compose)( |$)|down" "$BASE/taken/calls"'
check "taken: the scratch directory is gone" '[ -z "$(ls -A "$BASE/taken/tmp")" ]'

run_case kept
check "kept: the client is removed by the id its create returned" 'grep -qx "rm -f c0ffee1234" "$BASE/kept/calls"'
check "kept: the run fails naming the container left" \
  '[ "$status" != 0 ] && grep -q "^FAIL cleanup: could not remove the client container c0ffee1234;" "$BASE/kept/log"'
check "kept: its scratch directory stays for a retry, and no cleanup container starts" \
  '[ -n "$(ls -A "$BASE/kept/tmp")" ] && ! grep -q -- "-clean " "$BASE/kept/calls"'
# What the kept case left is this test's own: its scratch holds no root's file.
[ "$failures" = 0 ] || { echo "--- taken"; cat "$BASE/taken/log" "$BASE/taken/calls"; echo "--- kept"; cat "$BASE/kept/log" "$BASE/kept/calls"; }
exit "$((failures > 0))"
