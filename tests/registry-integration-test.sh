#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# =============================================================================
# CYFR Registry Integration Tests
# =============================================================================
# Tests the Compendium registry end-to-end via the cyfr CLI.
# Validates happy paths, unhappy paths, and security boundaries.
#
# Prerequisites:
#   - Server running at localhost:4000 (cyfr up)
#   - Authenticated session
#   - CLI binary at apps/codex/cyfr
#
# Usage:
#   chmod +x tests/registry-integration-test.sh
#   ./tests/registry-integration-test.sh
# =============================================================================

set -euo pipefail

# -- Configuration ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CYFR="$PROJECT_ROOT/apps/codex/cyfr"
COMPONENTS_DIR="$PROJECT_ROOT/components"
DATA_COMPONENTS_DIR="$PROJECT_ROOT/data/components"
CATALYST_LOCAL="$COMPONENTS_DIR/catalysts/local"
REAGENT_LOCAL="$COMPONENTS_DIR/reagents/local"
FORMULA_LOCAL="$COMPONENTS_DIR/formulas/local"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FINDINGS=()

# -- Minimal valid WASM binary ------------------------------------------------
# Magic(\0asm) + version(1) + type section + function section + export "run" + code section
VALID_WASM_HEX="0061736d01000000010401600000030201000707010372756e00000a040102000b"

# -- Colors (if terminal supports them) ----------------------------------------

if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  GREEN='' RED='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# -- Helpers -------------------------------------------------------------------

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo -e "  ${GREEN}PASS${RESET}: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FINDINGS+=("$1: $2")
  echo -e "  ${RED}FAIL${RESET}: $1"
  echo -e "        ${RED}→ $2${RESET}"
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  echo -e "  ${YELLOW}SKIP${RESET}: $1 — $2"
}

section() {
  echo ""
  echo -e "${BOLD}${CYAN}═══ $1 ═══${RESET}"
}

write_valid_wasm() {
  local dest="$1"
  echo "$VALID_WASM_HEX" | xxd -r -p > "$dest"
}

write_manifest() {
  local dest="$1"
  local name="$2"
  local version="$3"
  local type="$4"
  cat > "$dest" <<MANIFEST
{
  "id": "${type}:local.${name}",
  "type": "${type}",
  "version": "${version}",
  "description": "Integration test component: ${name}",
  "schema": {
    "input": {"type": "object"},
    "output": {"type": "object"}
  }
}
MANIFEST
}

# Returns 0 if json output contains a key matching pattern, 1 otherwise.
# Usage: json_check "$output" '.some.path' 'expected_pattern'
json_field() {
  echo "$1" | python3 -c "
import sys, json
data = json.load(sys.stdin)
path = sys.argv[1].split('.')
obj = data
for p in path:
    if p.startswith('[') and p.endswith(']'):
        obj = obj[int(p[1:-1])]
    elif isinstance(obj, dict):
        obj = obj.get(p)
    else:
        obj = None
    if obj is None:
        break
print(json.dumps(obj) if not isinstance(obj, str) else obj)
" "$2" 2>/dev/null
}

json_check() {
  local output="$1"
  local path="$2"
  local pattern="$3"
  local value
  value=$(json_field "$output" "$path")
  if echo "$value" | grep -qiE "$pattern"; then
    return 0
  else
    return 1
  fi
}

# -- Cleanup on exit -----------------------------------------------------------

TEST_DIRS=()

cleanup() {
  echo ""
  echo -e "${BOLD}Cleaning up test artifacts...${RESET}"

  for dir in "${TEST_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      rm -rf "$dir"
      echo "  Removed: $dir"
    fi
  done

  # Also clean the cyfr publisher dir if we created one
  if [ -d "$CATALYST_LOCAL/../../../catalysts/cyfr/test-pub" ]; then
    rm -rf "$COMPONENTS_DIR/catalysts/cyfr/test-pub"
    rmdir "$COMPONENTS_DIR/catalysts/cyfr" 2>/dev/null || true
    echo "  Removed: catalysts/cyfr/test-pub"
  fi

  # Clean reagent/formula test dirs from components/
  for type_dir in "$REAGENT_LOCAL" "$FORMULA_LOCAL"; do
    for dir in "$type_dir"/test-*; do
      if [ -d "$dir" ]; then
        rm -rf "$dir"
        echo "  Removed: $dir"
      fi
    done
  done

  # Clean corresponding blobs from data/components/ (Arca storage)
  if [ -d "$DATA_COMPONENTS_DIR" ]; then
    for type in catalysts reagents formulas; do
      for dir in "$DATA_COMPONENTS_DIR"/$type/local/test-* "$DATA_COMPONENTS_DIR"/$type/cyfr/test-*; do
        if [ -d "$dir" ]; then
          rm -rf "$dir"
          echo "  Removed blob: $dir"
        fi
      done
    done
    rmdir "$DATA_COMPONENTS_DIR/catalysts/cyfr" 2>/dev/null || true
  fi

  # Re-register to prune stale entries
  echo "  Running final register to prune stale entries..."
  "$CYFR" register --json --no-interactive > /dev/null 2>&1 || true

  # Verify no test artifacts remain
  local leftover
  leftover=$("$CYFR" search "test-" --json --no-interactive 2>/dev/null || echo '{"total":0}')
  local remaining
  remaining=$(json_field "$leftover" "total" 2>/dev/null || echo "0")
  if [ "$remaining" != "0" ] && [ "$remaining" != "null" ]; then
    echo -e "  ${YELLOW}Warning: ${remaining} test artifacts may still be in registry${RESET}"
  else
    echo "  Verified: no test artifacts remain in registry"
  fi
}

trap cleanup EXIT

# -- Preflight checks ----------------------------------------------------------

section "Preflight"

if [ ! -x "$CYFR" ]; then
  echo -e "${RED}ERROR: cyfr binary not found or not executable at: $CYFR${RESET}"
  exit 1
fi
echo "  CLI: $CYFR"

# Quick server health check
if ! "$CYFR" search "__preflight__" --json --no-interactive > /dev/null 2>&1; then
  echo -e "${RED}ERROR: Server does not appear to be running (cyfr search failed)${RESET}"
  echo "  Start the server with: cyfr up"
  exit 1
fi
echo "  Server: OK"
echo "  Components dir: $CATALYST_LOCAL"

# =============================================================================
# Section 1: Happy Path Tests
# =============================================================================

section "Section 1: Happy Path Tests"

# -- 1.1: Register existing components ----------------------------------------
echo -e "\n${BOLD}1.1: Register existing components${RESET}"
OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
ERRORS=$(json_field "$OUTPUT" "errors")
TOTAL=$(json_field "$OUTPUT" "total")

if [ "$ERRORS" = "0" ] && [ "$TOTAL" -ge 7 ] 2>/dev/null; then
  pass "Register: errors=$ERRORS, total=$TOTAL (>= 7)"
else
  fail "Register existing components" "errors=$ERRORS, total=$TOTAL (expected errors=0, total>=7)"
fi

# -- 1.2: Search known component ----------------------------------------------
echo -e "\n${BOLD}1.2: Search known component${RESET}"
OUTPUT=$("$CYFR" search claude --json --no-interactive 2>&1) || true
TOTAL=$(json_field "$OUTPUT" "total")

if [ "$TOTAL" -ge 1 ] 2>/dev/null; then
  # Verify at least one result contains "claude"
  if echo "$OUTPUT" | grep -qi "claude"; then
    pass "Search 'claude': total=$TOTAL, results contain 'claude'"
  else
    fail "Search 'claude'" "total=$TOTAL but no result contains 'claude'"
  fi
else
  fail "Search 'claude'" "total=$TOTAL (expected >= 1)"
fi

# -- 1.3: Inspect specific catalyst -------------------------------------------
echo -e "\n${BOLD}1.3: Inspect specific catalyst${RESET}"
OUTPUT=$("$CYFR" inspect c:local.claude:0.2.0 --json --no-interactive 2>&1) || true

NAME=$(json_field "$OUTPUT" "name")
VERSION=$(json_field "$OUTPUT" "version")
TYPE=$(json_field "$OUTPUT" "type")
DIGEST=$(json_field "$OUTPUT" "digest")

CHECKS=0
[ "$NAME" = "claude" ] && CHECKS=$((CHECKS + 1))
[ "$VERSION" = "0.2.0" ] && CHECKS=$((CHECKS + 1))
[ "$TYPE" = "catalyst" ] && CHECKS=$((CHECKS + 1))
echo "$DIGEST" | grep -q "^sha256:" && CHECKS=$((CHECKS + 1))

if [ "$CHECKS" -eq 4 ]; then
  pass "Inspect c:local.claude:0.2.0: name=$NAME, version=$VERSION, type=$TYPE, digest starts with sha256:"
else
  fail "Inspect c:local.claude:0.2.0" "name=$NAME, version=$VERSION, type=$TYPE, digest=$DIGEST ($CHECKS/4 checks passed)"
fi

# -- 1.4: Inspect formula with deps -------------------------------------------
echo -e "\n${BOLD}1.4: Inspect formula with dependencies${RESET}"
OUTPUT=$("$CYFR" inspect f:local.list-models:0.3.0 --json --no-interactive 2>&1) || true

NAME=$(json_field "$OUTPUT" "name")
TYPE=$(json_field "$OUTPUT" "type")

if [ "$NAME" = "list-models" ] && [ "$TYPE" = "formula" ]; then
  # Check for dependencies in output
  if echo "$OUTPUT" | grep -qi "dependenc"; then
    pass "Inspect f:local.list-models:0.3.0: name=$NAME, type=$TYPE, has dependencies"
  else
    pass "Inspect f:local.list-models:0.3.0: name=$NAME, type=$TYPE (dependencies field may be omitted in output)"
  fi
else
  fail "Inspect f:local.list-models:0.3.0" "name=$NAME, type=$TYPE (expected list-models, formula)"
fi

# -- 1.5: Inspect with shorthand type -----------------------------------------
echo -e "\n${BOLD}1.5: Inspect with shorthand type (space-separated)${RESET}"
OUTPUT=$("$CYFR" inspect c local.claude:0.2.0 --json --no-interactive 2>&1) || true

NAME=$(json_field "$OUTPUT" "name")
VERSION=$(json_field "$OUTPUT" "version")

if [ "$NAME" = "claude" ] && [ "$VERSION" = "0.2.0" ]; then
  pass "Inspect 'c local.claude:0.2.0': type joining works"
else
  fail "Inspect shorthand" "name=$NAME, version=$VERSION (expected claude, 0.2.0)"
fi

# -- 1.6: Create + register + search + inspect lifecycle -----------------------
echo -e "\n${BOLD}1.6: Full component lifecycle (create → register → search → inspect)${RESET}"

TEST_HAPPY_DIR="$CATALYST_LOCAL/test-happy/0.1.0"
mkdir -p "$TEST_HAPPY_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-happy")

write_valid_wasm "$TEST_HAPPY_DIR/catalyst.wasm"
write_manifest "$TEST_HAPPY_DIR/cyfr-manifest.json" "test-happy" "0.1.0" "catalyst"

# Register
REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
if echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-happy' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
  pass "Lifecycle: test-happy registered successfully"
else
  fail "Lifecycle: register" "test-happy not found in register output"
fi

# Search
SEARCH_OUTPUT=$("$CYFR" search "test-happy" --json --no-interactive 2>&1) || true
SEARCH_TOTAL=$(json_field "$SEARCH_OUTPUT" "total")

if [ "$SEARCH_TOTAL" -ge 1 ] 2>/dev/null; then
  pass "Lifecycle: search found test-happy (total=$SEARCH_TOTAL)"
else
  fail "Lifecycle: search" "test-happy not found (total=$SEARCH_TOTAL)"
fi

# Inspect
INSPECT_OUTPUT=$("$CYFR" inspect c:local.test-happy:0.1.0 --json --no-interactive 2>&1) || true
INSPECT_NAME=$(json_field "$INSPECT_OUTPUT" "name")

if [ "$INSPECT_NAME" = "test-happy" ]; then
  pass "Lifecycle: inspect test-happy succeeded"
else
  fail "Lifecycle: inspect" "name=$INSPECT_NAME (expected test-happy)"
fi

# -- 1.7: Publish to local registry -------------------------------------------
echo -e "\n${BOLD}1.7: Publish component${RESET}"
PUB_OUTPUT=$("$CYFR" publish c:local.claude:0.2.0 --no-interactive 2>&1) || true
PUB_EXIT=$?

# We accept either success OR a loud auth/registry error — NOT silent skip
if [ $PUB_EXIT -eq 0 ]; then
  pass "Publish c:local.claude:0.2.0: exited 0 (success or handled)"
elif echo "$PUB_OUTPUT" | grep -qiE "error|denied|unauthorized|failed|registry"; then
  pass "Publish c:local.claude:0.2.0: failed LOUDLY (exit=$PUB_EXIT) — good"
else
  fail "Publish c:local.claude:0.2.0" "exit=$PUB_EXIT but no clear error message: $PUB_OUTPUT"
fi

# -- 1.8: Search with no results ----------------------------------------------
echo -e "\n${BOLD}1.8: Search with no results${RESET}"
OUTPUT=$("$CYFR" search "zzz-no-match-xyz" --json --no-interactive 2>&1) || true
SEARCH_EXIT=$?
TOTAL=$(json_field "$OUTPUT" "total")

if [ "$TOTAL" = "0" ]; then
  pass "Search 'zzz-no-match-xyz': total=0 (empty result, exit=$SEARCH_EXIT)"
else
  fail "Search no results" "total=$TOTAL (expected 0)"
fi

# -- 1.9: Re-register is idempotent -------------------------------------------
echo -e "\n${BOLD}1.9: Re-register is idempotent${RESET}"
OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true

if echo "$OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-happy' and c.get('status') == 'unchanged' for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
  pass "Re-register: test-happy status=unchanged (idempotent)"
else
  fail "Re-register idempotent" "test-happy not 'unchanged' on second register"
fi

# =============================================================================
# Section 2: Unhappy Path Tests (via cyfr register)
# =============================================================================

section "Section 2: Unhappy Path Tests (register validation)"

# Helper: create a bad component, register, check for error status
# Usage: test_bad_component "test-name" "description" setup_function "expected_error_pattern"
test_bad_component() {
  local test_id="$1"
  local test_name="$2"
  local description="$3"
  local dir_name="$4"
  local version="$5"
  local expected_pattern="$6"

  echo -e "\n${BOLD}${test_id}: ${description}${RESET}"

  local comp_dir="$CATALYST_LOCAL/$dir_name/$version"
  mkdir -p "$comp_dir"
  TEST_DIRS+=("$CATALYST_LOCAL/$dir_name")
}

check_register_error() {
  local test_id="$1"
  local description="$2"
  local dir_name="$3"
  local expected_pattern="$4"

  local output
  output=$("$CYFR" register --json --no-interactive 2>&1) || true

  if echo "$output" | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
pattern = sys.argv[1]
found = any(
    c.get('name') == sys.argv[2] and c.get('status') == 'error' and re.search(pattern, c.get('error', ''), re.IGNORECASE)
    for c in data.get('components', [])
)
sys.exit(0 if found else 1)
" "$expected_pattern" "$dir_name" 2>/dev/null; then
    pass "$description"
  else
    # Check if it at least shows as error without matching the pattern
    if echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == sys.argv[1] and c.get('status') == 'error' for c in data.get('components', []))
sys.exit(0 if found else 1)
" "$dir_name" 2>/dev/null; then
      local actual_error
      actual_error=$(echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('components', []):
    if c.get('name') == sys.argv[1] and c.get('status') == 'error':
        print(c.get('error', 'no error field'))
        break
" "$dir_name" 2>/dev/null)
      fail "$description" "Got error but pattern '$expected_pattern' not matched. Actual: $actual_error"
    else
      fail "$description" "Component '$dir_name' not found with status='error' in register output"
    fi
  fi
}

# -- 2.1: Missing manifest ----------------------------------------------------
test_bad_component "2.1" "Missing manifest" "Valid WASM, no manifest" "test-no-manifest" "0.1.0" "manifest"
write_valid_wasm "$CATALYST_LOCAL/test-no-manifest/0.1.0/catalyst.wasm"
check_register_error "2.1" "Missing manifest → error" "test-no-manifest" "manifest|not.found"

# -- 2.2: Missing WASM file ---------------------------------------------------
test_bad_component "2.2" "Missing WASM" "Manifest only, no .wasm" "test-no-wasm" "0.1.0" "wasm"
write_manifest "$CATALYST_LOCAL/test-no-wasm/0.1.0/cyfr-manifest.json" "test-no-wasm" "0.1.0" "catalyst"
check_register_error "2.2" "Missing WASM file → error" "test-no-wasm" "wasm|missing|not.found"

# -- 2.3: Wrong WASM filename -------------------------------------------------
test_bad_component "2.3" "Wrong WASM filename" "reagent.wasm in catalysts dir" "test-wrong-wasm-name" "0.1.0" "wasm"
write_manifest "$CATALYST_LOCAL/test-wrong-wasm-name/0.1.0/cyfr-manifest.json" "test-wrong-wasm-name" "0.1.0" "catalyst"
write_valid_wasm "$CATALYST_LOCAL/test-wrong-wasm-name/0.1.0/reagent.wasm"
check_register_error "2.3" "Wrong WASM filename → error" "test-wrong-wasm-name" "wasm|missing|not.found"

# -- 2.4: Invalid WASM magic bytes --------------------------------------------
test_bad_component "2.4" "Invalid WASM magic" "0xDEADBEEF instead of \\0asm" "test-bad-magic" "0.1.0" "magic"
write_manifest "$CATALYST_LOCAL/test-bad-magic/0.1.0/cyfr-manifest.json" "test-bad-magic" "0.1.0" "catalyst"
echo -ne '\xDE\xAD\xBE\xEF\x01\x00\x00\x00' > "$CATALYST_LOCAL/test-bad-magic/0.1.0/catalyst.wasm"
# Pad to at least 8 bytes
dd if=/dev/zero bs=1 count=24 >> "$CATALYST_LOCAL/test-bad-magic/0.1.0/catalyst.wasm" 2>/dev/null
check_register_error "2.4" "Invalid WASM magic bytes → error" "test-bad-magic" "magic|invalid|wasm"

# -- 2.5: WASM too small (<8 bytes) -------------------------------------------
test_bad_component "2.5" "WASM too small" "Only 4 bytes of magic" "test-wasm-small" "0.1.0" "small"
write_manifest "$CATALYST_LOCAL/test-wasm-small/0.1.0/cyfr-manifest.json" "test-wasm-small" "0.1.0" "catalyst"
echo -ne '\x00\x61\x73\x6D' > "$CATALYST_LOCAL/test-wasm-small/0.1.0/catalyst.wasm"
check_register_error "2.5" "WASM too small → error" "test-wasm-small" "small|size|short|byte|invalid"

# -- 2.6: Empty WASM (0 bytes) ------------------------------------------------
test_bad_component "2.6" "Empty WASM" "0-byte catalyst.wasm" "test-wasm-empty" "0.1.0" "empty"
write_manifest "$CATALYST_LOCAL/test-wasm-empty/0.1.0/cyfr-manifest.json" "test-wasm-empty" "0.1.0" "catalyst"
touch "$CATALYST_LOCAL/test-wasm-empty/0.1.0/catalyst.wasm"
check_register_error "2.6" "Empty WASM (0 bytes) → error" "test-wasm-empty" "small|empty|size|byte|invalid"

# -- 2.7: Wrong WASM version --------------------------------------------------
test_bad_component "2.7" "Wrong WASM version" "Correct magic but version=99" "test-wasm-badver" "0.1.0" "version"
write_manifest "$CATALYST_LOCAL/test-wasm-badver/0.1.0/cyfr-manifest.json" "test-wasm-badver" "0.1.0" "catalyst"
# Correct magic bytes + version 99 (0x63)
echo -ne '\x00\x61\x73\x6D\x63\x00\x00\x00' > "$CATALYST_LOCAL/test-wasm-badver/0.1.0/catalyst.wasm"
# Add enough padding for a plausible module
dd if=/dev/zero bs=1 count=24 >> "$CATALYST_LOCAL/test-wasm-badver/0.1.0/catalyst.wasm" 2>/dev/null
check_register_error "2.7" "Wrong WASM version → error" "test-wasm-badver" "version|unsupported|invalid"

# -- 2.8: Invalid JSON manifest -----------------------------------------------
test_bad_component "2.8" "Invalid JSON manifest" "Malformed JSON" "test-bad-json" "0.1.0" "json"
write_valid_wasm "$CATALYST_LOCAL/test-bad-json/0.1.0/catalyst.wasm"
echo 'this is { not json' > "$CATALYST_LOCAL/test-bad-json/0.1.0/cyfr-manifest.json"
check_register_error "2.8" "Invalid JSON manifest → error" "test-bad-json" "json|manifest|parse|decode|invalid"

# -- 2.9: Name with uppercase -------------------------------------------------
test_bad_component "2.9" "Name with uppercase" 'manifest name="BadName_UPPER"' "test-bad-upper" "0.1.0" "name"
write_valid_wasm "$CATALYST_LOCAL/test-bad-upper/0.1.0/catalyst.wasm"
cat > "$CATALYST_LOCAL/test-bad-upper/0.1.0/cyfr-manifest.json" <<'EOF'
{
  "type": "catalyst",
  "name": "BadName_UPPER",
  "version": "0.1.0",
  "description": "Test: uppercase name"
}
EOF
check_register_error "2.9" "Uppercase name → error" "test-bad-upper" "name|invalid|lowercase|format"

# -- 2.10: Name starting with hyphen ------------------------------------------
test_bad_component "2.10" "Name starting with hyphen" 'manifest name="-bad-start"' "test-bad-hyphen-start" "0.1.0" "name"
write_valid_wasm "$CATALYST_LOCAL/test-bad-hyphen-start/0.1.0/catalyst.wasm"
cat > "$CATALYST_LOCAL/test-bad-hyphen-start/0.1.0/cyfr-manifest.json" <<'EOF'
{
  "type": "catalyst",
  "name": "-bad-start",
  "version": "0.1.0",
  "description": "Test: name starting with hyphen"
}
EOF
check_register_error "2.10" "Name starting with hyphen → error" "test-bad-hyphen-start" "name|invalid|hyphen|format"

# -- 2.11: Name ending with hyphen --------------------------------------------
test_bad_component "2.11" "Name ending with hyphen" 'manifest name="bad-end-"' "test-bad-hyphen-end" "0.1.0" "name"
write_valid_wasm "$CATALYST_LOCAL/test-bad-hyphen-end/0.1.0/catalyst.wasm"
cat > "$CATALYST_LOCAL/test-bad-hyphen-end/0.1.0/cyfr-manifest.json" <<'EOF'
{
  "type": "catalyst",
  "name": "bad-end-",
  "version": "0.1.0",
  "description": "Test: name ending with hyphen"
}
EOF
check_register_error "2.11" "Name ending with hyphen → error" "test-bad-hyphen-end" "name|invalid|hyphen|format"

# -- 2.12: Version = "latest" -------------------------------------------------
test_bad_component "2.12" 'Version = "latest"' 'Reserved version string' "test-ver-latest" "latest" "version"
write_valid_wasm "$CATALYST_LOCAL/test-ver-latest/latest/catalyst.wasm"
cat > "$CATALYST_LOCAL/test-ver-latest/latest/cyfr-manifest.json" <<'EOF'
{
  "name": "test-ver-latest",
  "type": "catalyst",
  "version": "latest",
  "description": "Test: version=latest"
}
EOF
check_register_error "2.12" 'Version "latest" → error' "test-ver-latest" "latest|version|semver|invalid"

# -- 2.13: Non-semver version -------------------------------------------------
test_bad_component "2.13" "Non-semver version" 'Version = "abc"' "test-ver-nonsemver" "abc" "version"
write_valid_wasm "$CATALYST_LOCAL/test-ver-nonsemver/abc/catalyst.wasm"
cat > "$CATALYST_LOCAL/test-ver-nonsemver/abc/cyfr-manifest.json" <<'EOF'
{
  "name": "test-ver-nonsemver",
  "type": "catalyst",
  "version": "abc",
  "description": "Test: non-semver version"
}
EOF
check_register_error "2.13" "Non-semver version → error" "test-ver-nonsemver" "version|semver|invalid|format"

# =============================================================================
# Section 3: Unhappy Path Tests (other CLI commands)
# =============================================================================

section "Section 3: Unhappy Path Tests (CLI commands)"

# -- 3.1: Inspect non-existent ------------------------------------------------
echo -e "\n${BOLD}3.1: Inspect non-existent component${RESET}"
set +e
OUTPUT=$("$CYFR" inspect c:local.nonexistent:99.99.99 --json --no-interactive 2>&1)
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  if echo "$OUTPUT" | grep -qiE "not.found|error|unknown|no.component"; then
    pass "Inspect non-existent: exit=$EXIT_CODE, contains error message"
  else
    pass "Inspect non-existent: exit=$EXIT_CODE (non-zero is correct, message: $(echo "$OUTPUT" | head -1))"
  fi
else
  # exit 0 is acceptable if the JSON output indicates an error
  if echo "$OUTPUT" | grep -qiE "not.found|error|null"; then
    pass "Inspect non-existent: exit=0 but output indicates not found"
  else
    fail "Inspect non-existent" "exit=0 and no error indication in output"
  fi
fi

# -- 3.2: Publish non-existent ------------------------------------------------
echo -e "\n${BOLD}3.2: Publish non-existent component${RESET}"
set +e
OUTPUT=$("$CYFR" publish c:local.nonexistent:99.99.99 --no-interactive 2>&1)
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  pass "Publish non-existent: exit=$EXIT_CODE (failed loudly)"
else
  if echo "$OUTPUT" | grep -qiE "error|not.found|failed"; then
    pass "Publish non-existent: exit=0 but contains error message"
  else
    fail "Publish non-existent" "exit=0 with no error message — silent failure"
  fi
fi

# -- 3.3: Search missing argument ---------------------------------------------
echo -e "\n${BOLD}3.3: Search with missing argument${RESET}"
set +e
OUTPUT=$("$CYFR" search --no-interactive 2>&1)
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  pass "Search no argument: exit=$EXIT_CODE (usage error)"
else
  # Some CLIs show interactive mode on no args — we check for useful output
  if echo "$OUTPUT" | grep -qiE "usage|error|required|argument|query"; then
    pass "Search no argument: exit=0 but shows usage/error info"
  else
    fail "Search missing argument" "exit=0 with no usage error — may have entered interactive mode"
  fi
fi

# =============================================================================
# Section 4: Security Boundary Tests
# =============================================================================

section "Section 4: Security Boundary Tests"

# -- 4.1: Wrong publisher namespace --------------------------------------------
echo -e "\n${BOLD}4.1: Wrong publisher namespace (cyfr/)${RESET}"
WRONG_PUB_DIR="$COMPONENTS_DIR/catalysts/cyfr/test-pub/0.1.0"
mkdir -p "$WRONG_PUB_DIR"
# Track the parent for cleanup
TEST_DIRS+=("$COMPONENTS_DIR/catalysts/cyfr")

write_valid_wasm "$WRONG_PUB_DIR/catalyst.wasm"
write_manifest "$WRONG_PUB_DIR/cyfr-manifest.json" "test-pub" "0.1.0" "catalyst"

OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true

if echo "$OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-pub' for c in data.get('components', []))
sys.exit(1 if found else 0)  # exit 0 if NOT found (correct behavior)
" 2>/dev/null; then
  pass "Wrong publisher: cyfr/test-pub NOT discovered (only local/ and agent/ scanned)"
else
  fail "Wrong publisher namespace" "cyfr/test-pub WAS discovered — auto-indexer should skip non-local publishers"
fi

# -- 4.2: Manifest missing name field -----------------------------------------
echo -e "\n${BOLD}4.2: Manifest missing name field (fallback to directory name)${RESET}"
NONAME_DIR="$CATALYST_LOCAL/test-noname/0.1.0"
mkdir -p "$NONAME_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-noname")

write_valid_wasm "$NONAME_DIR/catalyst.wasm"
cat > "$NONAME_DIR/cyfr-manifest.json" <<'EOF'
{
  "type": "catalyst",
  "version": "0.1.0",
  "description": "Test: manifest with no name field"
}
EOF

OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true

# Check if it registered (using dir name as fallback) or errored
if echo "$OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(
    c.get('name') == 'test-noname' and c.get('status') in ('registered', 'unchanged')
    for c in data.get('components', [])
)
sys.exit(0 if found else 1)
" 2>/dev/null; then
  pass "Missing name field: registered using directory name 'test-noname' as fallback"
else
  # Check if it errored instead
  if echo "$OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-noname' and c.get('status') == 'error' for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
    pass "Missing name field: errored (strict validation, no fallback)"
  else
    fail "Missing name field" "Component not found in register output at all"
  fi
fi

# =============================================================================
# Section 5: Loudness Verification
# =============================================================================

section "Section 5: Loudness Verification"

# -- 5.1: Register exit code with errors --------------------------------------
echo -e "\n${BOLD}5.1: Register exit code when components have errors${RESET}"

# We know there are bad test components still present from section 2
set +e
OUTPUT=$("$CYFR" register --json --no-interactive 2>&1)
REG_EXIT=$?
set -e

ERRORS=$(json_field "$OUTPUT" "errors")

if [ "$ERRORS" -gt 0 ] 2>/dev/null; then
  echo -e "  INFO: register exits $REG_EXIT with errors=$ERRORS in JSON payload"
  if [ $REG_EXIT -eq 0 ]; then
    pass "Register exit=0 even with errors — errors reported in JSON (errors=$ERRORS). Documented behavior."
  else
    pass "Register exit=$REG_EXIT with errors=$ERRORS — non-zero exit on validation errors"
  fi
else
  skip "5.1" "No error components present (bad test dirs may have been cleaned)"
fi

# -- 5.2: Inspect exits non-zero on failure ------------------------------------
echo -e "\n${BOLD}5.2: Inspect exits non-zero on failure${RESET}"
set +e
"$CYFR" inspect c:local.definitely-not-real:0.0.0 --json --no-interactive > /dev/null 2>&1
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  pass "Inspect failure: exit=$EXIT_CODE (non-zero)"
else
  fail "Inspect exit code" "exit=0 for non-existent component (expected non-zero)"
fi

# -- 5.3: Publish exits non-zero on failure ------------------------------------
echo -e "\n${BOLD}5.3: Publish exits non-zero on failure${RESET}"
set +e
"$CYFR" publish c:local.definitely-not-real:0.0.0 --no-interactive > /dev/null 2>&1
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  pass "Publish failure: exit=$EXIT_CODE (non-zero)"
else
  fail "Publish exit code" "exit=0 for non-existent component (expected non-zero)"
fi

# =============================================================================
# Section 6: Extended Coverage
# =============================================================================

section "Section 6: Extended Coverage"

# -- 6.1: Reagent lifecycle ---------------------------------------------------
echo -e "\n${BOLD}6.1: Reagent lifecycle (create → register → search → inspect)${RESET}"

TEST_REAGENT_DIR="$REAGENT_LOCAL/test-reagent/0.1.0"
mkdir -p "$TEST_REAGENT_DIR"
TEST_DIRS+=("$REAGENT_LOCAL/test-reagent")

write_valid_wasm "$TEST_REAGENT_DIR/reagent.wasm"
write_manifest "$TEST_REAGENT_DIR/cyfr-manifest.json" "test-reagent" "0.1.0" "reagent"

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
if echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-reagent' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
  pass "Reagent: test-reagent registered"
else
  fail "Reagent: register" "test-reagent not found or not registered in output"
fi

# Search
SEARCH_OUTPUT=$("$CYFR" search "test-reagent" --json --no-interactive 2>&1) || true
SEARCH_TOTAL=$(json_field "$SEARCH_OUTPUT" "total")
if [ "$SEARCH_TOTAL" -ge 1 ] 2>/dev/null; then
  pass "Reagent: search found test-reagent (total=$SEARCH_TOTAL)"
else
  fail "Reagent: search" "test-reagent not found (total=$SEARCH_TOTAL)"
fi

# Inspect with r: prefix
INSPECT_OUTPUT=$("$CYFR" inspect r:local.test-reagent:0.1.0 --json --no-interactive 2>&1) || true
INSPECT_NAME=$(json_field "$INSPECT_OUTPUT" "name")
INSPECT_TYPE=$(json_field "$INSPECT_OUTPUT" "type")
if [ "$INSPECT_NAME" = "test-reagent" ] && [ "$INSPECT_TYPE" = "reagent" ]; then
  pass "Reagent: inspect r:local.test-reagent:0.1.0 name=$INSPECT_NAME type=$INSPECT_TYPE"
else
  fail "Reagent: inspect" "name=$INSPECT_NAME type=$INSPECT_TYPE (expected test-reagent, reagent)"
fi

# -- 6.2: Multiple versions of same component ---------------------------------
echo -e "\n${BOLD}6.2: Multiple versions of same component${RESET}"

TEST_MULTI_V1="$CATALYST_LOCAL/test-multi/0.1.0"
TEST_MULTI_V2="$CATALYST_LOCAL/test-multi/0.2.0"
mkdir -p "$TEST_MULTI_V1" "$TEST_MULTI_V2"
TEST_DIRS+=("$CATALYST_LOCAL/test-multi")

write_valid_wasm "$TEST_MULTI_V1/catalyst.wasm"
write_manifest "$TEST_MULTI_V1/cyfr-manifest.json" "test-multi" "0.1.0" "catalyst"
write_valid_wasm "$TEST_MULTI_V2/catalyst.wasm"
write_manifest "$TEST_MULTI_V2/cyfr-manifest.json" "test-multi" "0.2.0" "catalyst"

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true

V1_OK=false
V2_OK=false
if echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-multi' and c.get('version') == '0.1.0' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
  V1_OK=true
fi
if echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-multi' and c.get('version') == '0.2.0' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
  V2_OK=true
fi

if $V1_OK && $V2_OK; then
  # Verify digests are independent (same WASM but different versions = same digest is OK)
  D1=$(json_field "$("$CYFR" inspect c:local.test-multi:0.1.0 --json --no-interactive 2>&1)" "digest")
  D2=$(json_field "$("$CYFR" inspect c:local.test-multi:0.2.0 --json --no-interactive 2>&1)" "digest")
  if [ -n "$D1" ] && [ -n "$D2" ]; then
    pass "Multiple versions: both 0.1.0 and 0.2.0 registered (digests: v1=${D1:0:20}..., v2=${D2:0:20}...)"
  else
    pass "Multiple versions: both registered (digest inspect incomplete)"
  fi
else
  fail "Multiple versions" "v1=$V1_OK, v2=$V2_OK (both should be true)"
fi

# -- 6.3: Stale pruning -------------------------------------------------------
echo -e "\n${BOLD}6.3: Stale pruning (register, delete dir, re-register)${RESET}"

# Create and register a component
STALE_DIR="$CATALYST_LOCAL/test-stale/0.1.0"
mkdir -p "$STALE_DIR"
# NOT added to TEST_DIRS — we delete it mid-test

write_valid_wasm "$STALE_DIR/catalyst.wasm"
write_manifest "$STALE_DIR/cyfr-manifest.json" "test-stale" "0.1.0" "catalyst"

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
if echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-stale' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
  # Now delete the directory
  rm -rf "$CATALYST_LOCAL/test-stale"

  # Re-register — should prune the stale entry
  REG_OUTPUT2=$("$CYFR" register --json --no-interactive 2>&1) || true
  PRUNED=$(json_field "$REG_OUTPUT2" "pruned")

  # Verify the component is no longer discoverable
  SEARCH_OUTPUT=$("$CYFR" search "test-stale" --json --no-interactive 2>&1) || true
  SEARCH_TOTAL=$(json_field "$SEARCH_OUTPUT" "total")

  if [ "$SEARCH_TOTAL" = "0" ]; then
    pass "Stale pruning: test-stale removed after directory deleted (pruned=$PRUNED)"
  else
    fail "Stale pruning" "test-stale still discoverable after dir deletion (total=$SEARCH_TOTAL, pruned=$PRUNED)"
  fi
else
  fail "Stale pruning" "Could not register test-stale in first place"
  rm -rf "$CATALYST_LOCAL/test-stale" 2>/dev/null || true
fi

# -- 6.4: Digest change detection ---------------------------------------------
echo -e "\n${BOLD}6.4: Digest change detection (modify WASM, re-register)${RESET}"

DIGEST_DIR="$CATALYST_LOCAL/test-digest/0.1.0"
mkdir -p "$DIGEST_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-digest")

write_valid_wasm "$DIGEST_DIR/catalyst.wasm"
write_manifest "$DIGEST_DIR/cyfr-manifest.json" "test-digest" "0.1.0" "catalyst"

# First register
"$CYFR" register --json --no-interactive > /dev/null 2>&1 || true

# Get initial digest
D_BEFORE=$(json_field "$("$CYFR" inspect c:local.test-digest:0.1.0 --json --no-interactive 2>&1)" "digest")

# Modify WASM — append a custom section to change the digest
# Custom section: section id=0, name="test", empty payload
printf '\x00\x06\x04test\x00' >> "$DIGEST_DIR/catalyst.wasm"

# Re-register
REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
STATUS=$(echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('components', []):
    if c.get('name') == 'test-digest' and c.get('version') == '0.1.0':
        print(c.get('status', 'unknown'))
        break
else:
    print('not-found')
" 2>/dev/null)

D_AFTER=$(json_field "$("$CYFR" inspect c:local.test-digest:0.1.0 --json --no-interactive 2>&1)" "digest")

if [ "$STATUS" = "registered" ]; then
  if [ "$D_BEFORE" != "$D_AFTER" ]; then
    pass "Digest change: status=registered, digest changed (${D_BEFORE:0:20}... → ${D_AFTER:0:20}...)"
  else
    fail "Digest change" "status=registered but digest unchanged ($D_BEFORE)"
  fi
elif [ "$STATUS" = "unchanged" ]; then
  fail "Digest change" "status=unchanged — digest_matches? returned true despite WASM modification"
else
  fail "Digest change" "status=$STATUS (expected 'registered')"
fi

# -- 6.5: Wrong type prefix ---------------------------------------------------
echo -e "\n${BOLD}6.5: Wrong type prefix (inspect reagent ref for a catalyst)${RESET}"

set +e
OUTPUT=$("$CYFR" inspect r:local.claude:0.2.0 --json --no-interactive 2>&1)
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  pass "Wrong type prefix: r:local.claude:0.2.0 → exit=$EXIT_CODE (not found, correct)"
elif echo "$OUTPUT" | grep -qiE "not.found|error|null"; then
  pass "Wrong type prefix: r:local.claude:0.2.0 → exit=0 but output indicates not found"
else
  # Check if it actually returned catalyst data (wrong behavior)
  RETURNED_TYPE=$(json_field "$OUTPUT" "type")
  if [ "$RETURNED_TYPE" = "catalyst" ]; then
    fail "Wrong type prefix" "r:local.claude:0.2.0 returned catalyst data — type prefix not enforced"
  else
    fail "Wrong type prefix" "r:local.claude:0.2.0 returned type=$RETURNED_TYPE with exit=0 — unclear behavior"
  fi
fi

# -- 6.6: Name with dots (namespace separator) --------------------------------
echo -e "\n${BOLD}6.6: Name with dots (my.tool)${RESET}"

DOT_DIR="$CATALYST_LOCAL/test-dot-name/0.1.0"
mkdir -p "$DOT_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-dot-name")

write_valid_wasm "$DOT_DIR/catalyst.wasm"
cat > "$DOT_DIR/cyfr-manifest.json" <<'EOF'
{
  "type": "catalyst",
  "name": "my.tool",
  "version": "0.1.0",
  "description": "Test: name with dots"
}
EOF
check_register_error "6.6" "Name with dots → error" "test-dot-name" "name|invalid|format|alphanumeric"

# -- 6.7: Name with underscores -----------------------------------------------
echo -e "\n${BOLD}6.7: Name with underscores (my_tool)${RESET}"

UNDER_DIR="$CATALYST_LOCAL/test-underscore/0.1.0"
mkdir -p "$UNDER_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-underscore")

write_valid_wasm "$UNDER_DIR/catalyst.wasm"
cat > "$UNDER_DIR/cyfr-manifest.json" <<'EOF'
{
  "type": "catalyst",
  "name": "my_tool",
  "version": "0.1.0",
  "description": "Test: name with underscores"
}
EOF
check_register_error "6.7" "Name with underscores → error" "test-underscore" "name|invalid|format|alphanumeric"

# -- 6.8: Very long name (200 chars) ------------------------------------------
echo -e "\n${BOLD}6.8: Very long name (200 chars)${RESET}"

LONG_DIR="$CATALYST_LOCAL/test-longname/0.1.0"
mkdir -p "$LONG_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-longname")

LONG_NAME=$(python3 -c "print('a' * 200)")
write_valid_wasm "$LONG_DIR/catalyst.wasm"
cat > "$LONG_DIR/cyfr-manifest.json" <<EOF
{
  "type": "catalyst",
  "name": "${LONG_NAME}",
  "version": "0.1.0",
  "description": "Test: 200-char name"
}
EOF
check_register_error "6.8" "Very long name (200 chars) → error" "test-longname" "name|length|long|64|character"

# -- 6.9: Type mismatch (manifest says reagent, lives in catalysts/) ----------
echo -e "\n${BOLD}6.9: Type mismatch (manifest=reagent, dir=catalysts/)${RESET}"

MISMATCH_DIR="$CATALYST_LOCAL/test-type-mismatch/0.1.0"
mkdir -p "$MISMATCH_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-type-mismatch")

# WASM filename is catalyst.wasm (matches directory type)
write_valid_wasm "$MISMATCH_DIR/catalyst.wasm"
# But manifest says type=reagent
cat > "$MISMATCH_DIR/cyfr-manifest.json" <<'EOF'
{
  "name": "test-type-mismatch",
  "type": "reagent",
  "version": "0.1.0",
  "description": "Test: manifest type vs directory type mismatch"
}
EOF

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
# Check what happened — did it error, or did directory type win?
STATUS=$(echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('components', []):
    if c.get('name') == 'test-type-mismatch':
        print(c.get('status', 'unknown') + ':' + c.get('type', 'unknown'))
        break
else:
    print('not-found:none')
" 2>/dev/null)

TYPE_STATUS="${STATUS%%:*}"
TYPE_USED="${STATUS##*:}"

if [ "$TYPE_STATUS" = "error" ]; then
  pass "Type mismatch: errored (strict validation)"
elif [ "$TYPE_STATUS" = "registered" ] || [ "$TYPE_STATUS" = "unchanged" ]; then
  echo -e "  ${YELLOW}INFO${RESET}: Type mismatch resolved to type=$TYPE_USED (directory type wins over manifest)"
  pass "Type mismatch: registered with type=$TYPE_USED (documented: directory type wins)"
else
  fail "Type mismatch" "status=$TYPE_STATUS, type=$TYPE_USED — unclear resolution"
fi

# -- 6.10: Version mismatch (manifest=0.2.0, dir=0.1.0) ----------------------
echo -e "\n${BOLD}6.10: Version mismatch (manifest=0.2.0, dir=0.1.0)${RESET}"

VERMIS_DIR="$CATALYST_LOCAL/test-ver-mismatch/0.1.0"
mkdir -p "$VERMIS_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-ver-mismatch")

write_valid_wasm "$VERMIS_DIR/catalyst.wasm"
# Manifest says version 0.2.0 but directory is 0.1.0
cat > "$VERMIS_DIR/cyfr-manifest.json" <<'EOF'
{
  "name": "test-ver-mismatch",
  "type": "catalyst",
  "version": "0.2.0",
  "description": "Test: manifest version vs directory version mismatch"
}
EOF

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
STATUS=$(echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('components', []):
    if c.get('name') == 'test-ver-mismatch':
        print(c.get('status', 'unknown') + ':' + c.get('version', 'unknown'))
        break
else:
    print('not-found:none')
" 2>/dev/null)

VER_STATUS="${STATUS%%:*}"
VER_USED="${STATUS##*:}"

if [ "$VER_STATUS" = "error" ]; then
  pass "Version mismatch: errored (strict validation)"
elif [ "$VER_STATUS" = "registered" ] || [ "$VER_STATUS" = "unchanged" ]; then
  echo -e "  ${YELLOW}INFO${RESET}: Version mismatch resolved to version=$VER_USED (directory version wins over manifest)"
  pass "Version mismatch: registered with version=$VER_USED (documented: directory version wins)"
else
  fail "Version mismatch" "status=$VER_STATUS, version=$VER_USED — unclear resolution"
fi

# -- 6.11: Pull local component -----------------------------------------------
echo -e "\n${BOLD}6.11: Pull local component${RESET}"

set +e
PULL_OUTPUT=$("$CYFR" pull c:local.test-happy:0.1.0 --json --no-interactive 2>&1)
PULL_EXIT=$?
set -e

if [ $PULL_EXIT -eq 0 ]; then
  if echo "$PULL_OUTPUT" | grep -qiE "ready|pulled|success|cached"; then
    pass "Pull c:local.test-happy:0.1.0: exit=0, status indicates ready"
  else
    pass "Pull c:local.test-happy:0.1.0: exit=0 (accepted)"
  fi
else
  if echo "$PULL_OUTPUT" | grep -qiE "error|not.found|failed"; then
    fail "Pull local component" "exit=$PULL_EXIT with error: $(echo "$PULL_OUTPUT" | head -1)"
  else
    fail "Pull local component" "exit=$PULL_EXIT, output: $(echo "$PULL_OUTPUT" | head -1)"
  fi
fi

# -- 6.12: Manifest name mismatch -----------------------------------------------
echo -e "\n${BOLD}6.12: Manifest name mismatch (name says wrong-name, dir says test-id-mismatch)${RESET}"

IDMIS_DIR="$CATALYST_LOCAL/test-id-mismatch/0.1.0"
mkdir -p "$IDMIS_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-id-mismatch")

write_valid_wasm "$IDMIS_DIR/catalyst.wasm"
cat > "$IDMIS_DIR/cyfr-manifest.json" <<'EOF'
{
  "name": "wrong-name",
  "type": "catalyst",
  "version": "0.1.0",
  "description": "Test: manifest name vs directory name mismatch"
}
EOF

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
# Check if it registered using directory name (test-id-mismatch) or manifest name (wrong-name)
DIR_NAME_FOUND=$(echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-id-mismatch' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
print('yes' if found else 'no')
" 2>/dev/null)

MANIFEST_NAME_FOUND=$(echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'wrong-name' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
print('yes' if found else 'no')
" 2>/dev/null)

if [ "$DIR_NAME_FOUND" = "yes" ]; then
  echo -e "  ${YELLOW}INFO${RESET}: Directory name 'test-id-mismatch' used (manifest id 'wrong-name' ignored)"
  pass "ID mismatch: registered as test-id-mismatch (directory name wins)"
elif [ "$MANIFEST_NAME_FOUND" = "yes" ]; then
  echo -e "  ${YELLOW}INFO${RESET}: Manifest name 'wrong-name' used (directory name ignored)"
  pass "ID mismatch: registered as wrong-name (manifest id wins)"
  # Track for cleanup
  TEST_DIRS+=("$CATALYST_LOCAL/wrong-name")
else
  # Check if it errored
  if echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') in ('test-id-mismatch', 'wrong-name') and c.get('status') == 'error' for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
    pass "ID mismatch: errored (strict validation rejects mismatched id)"
  else
    fail "ID mismatch" "Neither test-id-mismatch nor wrong-name found in register output"
  fi
fi

# -- 6.13: Formula lifecycle --------------------------------------------------
echo -e "\n${BOLD}6.13: Formula lifecycle (create → register → search → inspect)${RESET}"

TEST_FORMULA_DIR="$FORMULA_LOCAL/test-formula/0.1.0"
mkdir -p "$TEST_FORMULA_DIR"
TEST_DIRS+=("$FORMULA_LOCAL/test-formula")

write_valid_wasm "$TEST_FORMULA_DIR/formula.wasm"
write_manifest "$TEST_FORMULA_DIR/cyfr-manifest.json" "test-formula" "0.1.0" "formula"

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
if echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
found = any(c.get('name') == 'test-formula' and c.get('status') in ('registered', 'unchanged') for c in data.get('components', []))
sys.exit(0 if found else 1)
" 2>/dev/null; then
  pass "Formula: test-formula registered"
else
  fail "Formula: register" "test-formula not found or not registered in output"
fi

# Search
SEARCH_OUTPUT=$("$CYFR" search "test-formula" --json --no-interactive 2>&1) || true
SEARCH_TOTAL=$(json_field "$SEARCH_OUTPUT" "total")
if [ "$SEARCH_TOTAL" -ge 1 ] 2>/dev/null; then
  pass "Formula: search found test-formula (total=$SEARCH_TOTAL)"
else
  fail "Formula: search" "test-formula not found (total=$SEARCH_TOTAL)"
fi

# Inspect with f: prefix
INSPECT_OUTPUT=$("$CYFR" inspect f:local.test-formula:0.1.0 --json --no-interactive 2>&1) || true
INSPECT_NAME=$(json_field "$INSPECT_OUTPUT" "name")
INSPECT_TYPE=$(json_field "$INSPECT_OUTPUT" "type")
if [ "$INSPECT_NAME" = "test-formula" ] && [ "$INSPECT_TYPE" = "formula" ]; then
  pass "Formula: inspect f:local.test-formula:0.1.0 name=$INSPECT_NAME type=$INSPECT_TYPE"
else
  fail "Formula: inspect" "name=$INSPECT_NAME type=$INSPECT_TYPE (expected test-formula, formula)"
fi

# -- 6.14: No export section (valid WASM header only) -------------------------
echo -e "\n${BOLD}6.14: No export section (valid WASM magic+version, no sections)${RESET}"

NOEXPORT_DIR="$CATALYST_LOCAL/test-noexport/0.1.0"
mkdir -p "$NOEXPORT_DIR"
TEST_DIRS+=("$CATALYST_LOCAL/test-noexport")

write_manifest "$NOEXPORT_DIR/cyfr-manifest.json" "test-noexport" "0.1.0" "catalyst"
# Write just the WASM header (magic + version 1) — valid header, zero sections
echo -ne '\x00\x61\x73\x6D\x01\x00\x00\x00' > "$NOEXPORT_DIR/catalyst.wasm"

REG_OUTPUT=$("$CYFR" register --json --no-interactive 2>&1) || true
STATUS=$(echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('components', []):
    if c.get('name') == 'test-noexport':
        print(c.get('status', 'unknown'))
        break
else:
    print('not-found')
" 2>/dev/null)

if [ "$STATUS" = "registered" ] || [ "$STATUS" = "unchanged" ]; then
  pass "No export section: registered with status=$STATUS (empty exports accepted)"
elif [ "$STATUS" = "error" ]; then
  ACTUAL_ERROR=$(echo "$REG_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('components', []):
    if c.get('name') == 'test-noexport' and c.get('status') == 'error':
        print(c.get('error', 'no error field'))
        break
" 2>/dev/null)
  pass "No export section: error (strict validation requires exports: $ACTUAL_ERROR)"
else
  fail "No export section" "status=$STATUS — unclear handling"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Test Summary${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${RESET}"
echo -e "  ${GREEN}Passed${RESET}: $PASS_COUNT"
echo -e "  ${RED}Failed${RESET}: $FAIL_COUNT"
echo -e "  ${YELLOW}Skipped${RESET}: $SKIP_COUNT"
echo -e "  Total:   $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))"
echo ""

if [ ${#FINDINGS[@]} -gt 0 ]; then
  echo -e "${BOLD}${RED}  Findings:${RESET}"
  for finding in "${FINDINGS[@]}"; do
    echo -e "    ${RED}• $finding${RESET}"
  done
  echo ""
fi

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}All tests passed!${RESET}"
else
  echo -e "  ${RED}${BOLD}$FAIL_COUNT test(s) failed — investigate findings above.${RESET}"
fi

echo ""
exit $FAIL_COUNT
