#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/security-scan.sh, run against a fake scanner
# for each exit class, and for scripts/npm-audit-report.mjs, run against a
# fake npm for each audit outcome. The adapter's own classifier is what runs
# here; nothing in this file reimplements it.
#
# Usage: bash tests/security-scan-test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
wrapper="$root/scripts/security-scan.sh"
adapter="$root/scripts/npm-audit-report.mjs"
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

# A missing node is a failed run, never a skipped adapter.
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed; the npm adapter cases cannot run"
  exit 1
fi

mkdir -p "$scratch/bin" "$scratch/package"
export SCAN_ARGS="$scratch/scanner-args" NPM_ARGS="$scratch/npm-args"

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

# The fake npm answers `npm audit` as FAKE_NPM_MODE says and records the
# arguments the adapter passed it.
cat > "$scratch/bin/npm" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$NPM_ARGS"
clean='{
  "auditReportVersion": 2,
  "vulnerabilities": {},
  "metadata": {
    "vulnerabilities": {"info": 0, "low": 0, "moderate": 0, "high": 0, "critical": 0, "total": 0},
    "dependencies": {"prod": 69, "dev": 0, "optional": 0, "peer": 0, "peerOptional": 0, "total": 68}
  }
}'
advisory='{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "example-package": {
      "name": "example-package",
      "severity": "high",
      "isDirect": true,
      "via": [{"source": 1000001, "name": "example-package", "title": "Example advisory", "severity": "high", "range": "<1.2.3"}],
      "effects": [],
      "range": "<1.2.3",
      "nodes": ["node_modules/example-package"],
      "fixAvailable": true
    }
  },
  "metadata": {
    "vulnerabilities": {"info": 0, "low": 0, "moderate": 2, "high": 1, "critical": 0, "total": 3},
    "dependencies": {"prod": 69, "dev": 0, "optional": 0, "peer": 0, "peerOptional": 0, "total": 68}
  }
}'
case "$FAKE_NPM_MODE" in
  clean) printf '%s\n' "$clean"; exit 0 ;;
  advisory) printf '%s\n' "$advisory"; exit 1 ;;
  envelope)
    printf '%s\n' '{"error":{"code":"ENOTFOUND","summary":"request to https://registry.npmjs.org/-/npm/v1/security/advisories/bulk failed","detail":""}}'
    echo "npm error code ENOTFOUND" >&2
    exit 1 ;;
  invalid) echo "npm error audit endpoint returned an error"; exit 1 ;;
  truncated) printf '%s' "$advisory" | head -c 200; exit 1 ;;
  unexpected) printf '%s\n' "$clean"; exit 2 ;;
esac
echo "fake npm: unknown FAKE_NPM_MODE '$FAKE_NPM_MODE'" >&2
exit 99
FAKE

chmod +x "$scratch/bin/scanner" "$scratch/bin/npm"

run_wrapper() {
  rm -f "$SCAN_ARGS"
  bash "$wrapper" "$@" >"$scratch/out" 2>"$scratch/err"
  code=$?
}

run_adapter() {
  rm -f "$NPM_ARGS"
  (cd "$scratch/package" && NPM_AUDIT_BIN="$1" FAKE_NPM_MODE="$2" node "$adapter") \
    >"$scratch/out" 2>"$scratch/err"
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

# --- scripts/npm-audit-report.mjs ---

run_adapter "$scratch/bin/npm" clean
if [ "$code" -eq 0 ] && has_out "critical 0, high 0, moderate 0, low 0, info 0, total 0" &&
  has_out '"auditReportVersion": 2' &&
  [ "$(printf 'audit\n--json\n--audit-level=high\n')" = "$(cat "$NPM_ARGS")" ]; then
  pass "adapter accepts a clean report (npm exit 0) and runs npm audit --json --audit-level=high"
else
  fail "adapter accepts a clean report (npm exit 0) and runs npm audit --json --audit-level=high"
fi

run_adapter "$scratch/bin/npm" advisory
if [ "$code" -eq 0 ] && has_out "critical 0, high 1, moderate 2, low 0, info 0, total 3" &&
  has_out '"title": "Example advisory"'; then
  pass "adapter reports an advisory report (npm exit 1) with its counts and passes"
else
  fail "adapter reports an advisory report (npm exit 1) with its counts and passes"
fi

run_adapter "$scratch/bin/npm" envelope
if [ "$code" -ne 0 ] && has_err "npm-audit-report:" && has_err "ENOTFOUND"; then
  pass "adapter fails an error envelope (npm exit 1, ENOTFOUND)"
else
  fail "adapter fails an error envelope (npm exit 1, ENOTFOUND)"
fi

run_adapter "$scratch/bin/npm" invalid
if [ "$code" -ne 0 ] && has_err "invalid or incomplete JSON"; then
  pass "adapter fails invalid JSON"
else
  fail "adapter fails invalid JSON"
fi

run_adapter "$scratch/bin/npm" truncated
if [ "$code" -ne 0 ] && has_err "invalid or incomplete JSON"; then
  pass "adapter fails truncated JSON"
else
  fail "adapter fails truncated JSON"
fi

run_adapter "$scratch/bin/npm" unexpected
if [ "$code" -ne 0 ] && has_err "exited 2"; then
  pass "adapter fails an unexpected npm exit (2) even with a valid report"
else
  fail "adapter fails an unexpected npm exit (2) even with a valid report"
fi

run_adapter "$scratch/bin/absent-npm" clean
if [ "$code" -ne 0 ] && has_err "could not run $scratch/bin/absent-npm"; then
  pass "adapter fails when npm is missing"
else
  fail "adapter fails when npm is missing"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
