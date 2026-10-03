#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/security-scan.sh, run against a fake scanner
# for each exit class. The wrapper itself is what runs here; nothing in this
# file reimplements its exit policy.
#
# Usage: bash tests/security-scan-test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
wrapper="$root/scripts/security-scan.sh"
tmp=${TMPDIR:-/tmp}
scratch=$(mktemp -d "${tmp%/}/cyfr-security-scan-test.XXXXXX") || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
trap 'rm -rf "$scratch"' EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  echo "  exit: $code"
  sed 's/^/  stdout: /' "$scratch/out"
  sed 's/^/  stderr: /' "$scratch/err"
  failures=$((failures + 1))
}

mkdir -p "$scratch/bin"
export SCAN_ARGS="$scratch/scanner-args"

# The fake scanner exits with its first argument and records every argument
# it received, one per line.
cat > "$scratch/bin/scanner" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SCAN_ARGS"
case "$1" in
  0) echo "No vulnerabilities found." ;;
  3) echo "Vulnerability #1: GO-0000-0000" ;;
  2) echo "panic: ForEachElement called on type containing *types.TypeParam" >&2 ;;
  *) echo "scanner: internal error" >&2 ;;
esac
exit "$1"
FAKE

chmod +x "$scratch/bin/scanner"

run_wrapper() {
  rm -f "$SCAN_ARGS"
  bash "$wrapper" "$@" >"$scratch/out" 2>"$scratch/err"
  code=$?
}

has_out() { grep -qF -- "$1" "$scratch/out"; }
has_err() { grep -qF -- "$1" "$scratch/err"; }

# --- scripts/security-scan.sh ---

run_wrapper "$scratch/bin/scanner" 0 "two words" './...'
if [ "$code" -eq 0 ] && has_out "No vulnerabilities found." && ! has_err "security-scan:" &&
  [ "$(printf '0\ntwo words\n./...\n')" = "$(cat "$SCAN_ARGS")" ]; then
  pass "wrapper passes a clean scan (exit 0) with its arguments unchanged"
else
  fail "wrapper passes a clean scan (exit 0) with its arguments unchanged"
fi

run_wrapper "$scratch/bin/scanner" 3 ./...
if [ "$code" -eq 3 ] && has_out "GO-0000-0000" && has_err "security-scan: $scratch/bin/scanner exited 3"; then
  pass "wrapper fails a scan with findings (exit 3)"
else
  fail "wrapper fails a scan with findings (exit 3)"
fi

run_wrapper "$scratch/bin/scanner" 2 ./...
if [ "$code" -eq 2 ] && has_err "panic:" && has_err "security-scan: $scratch/bin/scanner exited 2"; then
  pass "wrapper fails a scanner panic (exit 2)"
else
  fail "wrapper fails a scanner panic (exit 2)"
fi

run_wrapper "$scratch/bin/scanner" 7 ./...
if [ "$code" -eq 7 ] && has_err "security-scan: $scratch/bin/scanner exited 7"; then
  pass "wrapper fails an unexpected scanner exit (exit 7)"
else
  fail "wrapper fails an unexpected scanner exit (exit 7)"
fi

run_wrapper "$scratch/bin/absent-scanner" ./...
if [ "$code" -ne 0 ] && has_err "security-scan: $scratch/bin/absent-scanner exited $code"; then
  pass "wrapper fails a missing scanner executable (exit $code)"
else
  fail "wrapper fails a missing scanner executable"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
