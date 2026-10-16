#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for scripts/security-scan.sh, run against a fake scanner
# for each exit class. The wrapper itself is what runs here; nothing in this
# file reimplements its exit policy.
#
# It also holds the exception rule for .trivyignore.yaml and enforces it on
# the committed file: every entry names its owner in a `# owner: @handle`
# comment, carries an `expired_at` date that has not yet arrived and is
# scoped by `paths`. The file's grammar is closed, so an entry written in a
# shape this check does not read is refused rather than passed over.
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

# --- .trivyignore.yaml ---

# check_ignorefile FILE TODAY: print one line per refusal and exit 1 if
# there is any. TODAY is YYYY-MM-DD; an entry expires on its expired_at
# date, as Trivy stops honouring it from that date's first instant (UTC).
check_ignorefile() {
  awk -v today="$2" '
    function refuse(msg) { print FILENAME ":" NR ": " msg; bad = 1 }
    function close_entry() {
      if (id == "") return
      if (!owner) print FILENAME ":" start ": " id ": no `# owner: @handle` comment"
      if (date == "") print FILENAME ":" start ": " id ": no expired_at date"
      else if (date <= today) print FILENAME ":" start ": " id ": expired_at " date " has arrived (today " today ")"
      if (!paths) print FILENAME ":" start ": " id ": no paths; an exception is scoped to where it was observed"
      if (!owner || date == "" || date <= today || !paths) bad = 1
      id = ""
    }
    /^[ \t]*$/ { next }
    /^(vulnerabilities|misconfigurations|secrets|licenses):[ \t]*$/ {
      close_entry(); section = 1; field = ""; next
    }
    /^  - id: [^ \t]+[ \t]*$/ && section {
      close_entry(); id = $3; start = NR; owner = 0; date = ""; paths = 0; field = ""; next
    }
    /^    # owner: @[A-Za-z0-9][A-Za-z0-9_.\/-]*[ \t]*$/ && id != "" {
      if (owner) refuse(id ": a second owner comment")
      owner = 1; next
    }
    /^[ \t]*#/ { next }
    /^    expired_at: / && id != "" {
      if (date != "") refuse(id ": a second expired_at")
      if ($2 !~ /^[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]$/ || NF != 2)
        refuse(id ": expired_at is not a YYYY-MM-DD date")
      date = $2; field = ""; next
    }
    /^    paths:[ \t]*$/ && id != "" { field = "paths"; next }
    /^    statement: [^ \t]/ && id != "" { field = ""; next }
    /^      - "[^"]+"[ \t]*$/ && field == "paths" { paths = 1; next }
    { refuse("a line this check does not read: " $0) }
    END { close_entry(); exit bad }
  ' "$1"
}

run_check() {
  check_ignorefile "$1" "${2:-$(date -u +%F)}" >"$scratch/out" 2>"$scratch/err"
  code=$?
}

entry() {
  # entry ID [owner] [date]: one well-formed entry, with the owner comment
  # or the date left out when that argument is "-".
  printf '  - id: %s\n' "$1"
  [ "${2:--}" = - ] || printf '    # owner: %s\n' "$2"
  [ "${3:--}" = - ] || printf '    expired_at: %s\n' "$3"
  printf '    paths:\n      - "Dockerfile"\n    statement: planted.\n'
}

planted="$scratch/trivyignore.yaml"

run_check "$root/.trivyignore.yaml"
if [ "$code" -eq 0 ] && [ ! -s "$scratch/out" ]; then
  pass "the committed .trivyignore.yaml has an owner, a future date and paths on every entry"
else
  fail "the committed .trivyignore.yaml has an owner, a future date and paths on every entry"
fi

{ echo "misconfigurations:"; entry DS-0001 @someone 2099-01-01; entry DS-0002 @org/team 2099-12-31; } >"$planted"
run_check "$planted" 2026-10-16
if [ "$code" -eq 0 ] && [ ! -s "$scratch/out" ]; then
  pass "ignorefile check admits well-formed entries"
else
  fail "ignorefile check admits well-formed entries"
fi

{ echo "vulnerabilities:"; entry CVE-1 @someone 2099-01-01; entry CVE-2 - 2099-01-01; } >"$planted"
run_check "$planted" 2026-10-16
if [ "$code" -eq 1 ] && has_out ": CVE-2: no \`# owner: @handle\` comment" && [ "$(wc -l <"$scratch/out")" -eq 1 ]; then
  pass "ignorefile check refuses an entry without an owner"
else
  fail "ignorefile check refuses an entry without an owner"
fi

{ echo "vulnerabilities:"; entry CVE-1 @someone -; entry CVE-2 @someone 2099-01-01; } >"$planted"
run_check "$planted" 2026-10-16
if [ "$code" -eq 1 ] && has_out ": CVE-1: no expired_at date" && [ "$(wc -l <"$scratch/out")" -eq 1 ]; then
  pass "ignorefile check refuses an entry without a date"
else
  fail "ignorefile check refuses an entry without a date"
fi

{ echo "misconfigurations:"; entry DS-1 @someone 2026-10-15; entry DS-2 @someone 2026-10-16; entry DS-3 @someone 2026-10-17; } >"$planted"
run_check "$planted" 2026-10-16
if [ "$code" -eq 1 ] && has_out ": DS-1: expired_at 2026-10-15 has arrived" &&
  has_out ": DS-2: expired_at 2026-10-16 has arrived" && [ "$(wc -l <"$scratch/out")" -eq 2 ]; then
  pass "ignorefile check refuses an entry past or at its date"
else
  fail "ignorefile check refuses an entry past or at its date"
fi

{ echo "vulnerabilities:"; entry CVE-1 @someone 2099-01-01 | sed '/paths:/,/"Dockerfile"/d'; } >"$planted"
run_check "$planted" 2026-10-16
if [ "$code" -eq 1 ] && has_out ": CVE-1: no paths" && [ "$(wc -l <"$scratch/out")" -eq 1 ]; then
  pass "ignorefile check refuses an entry without paths"
else
  fail "ignorefile check refuses an entry without paths"
fi

{ echo "vulnerabilities:"; entry CVE-1 @someone 2099-01-01; echo "  - {id: CVE-2, statement: flow style}"; } >"$planted"
run_check "$planted" 2026-10-16
if [ "$code" -eq 1 ] && has_out "a line this check does not read:   - {id: CVE-2" && [ "$(wc -l <"$scratch/out")" -eq 1 ]; then
  pass "ignorefile check refuses an entry it cannot read"
else
  fail "ignorefile check refuses an entry it cannot read"
fi

{ echo "vulnerabilities:"; entry CVE-1 @someone 2099-1-1; } >"$planted"
run_check "$planted" 2026-10-16
if [ "$code" -eq 1 ] && has_out ": CVE-1: expired_at is not a YYYY-MM-DD date"; then
  pass "ignorefile check refuses a date it cannot compare"
else
  fail "ignorefile check refuses a date it cannot compare"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
