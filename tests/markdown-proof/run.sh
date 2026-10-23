#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The console's markdown hook in Chromium, after its sanitizer
# (tests/markdown-proof/README.md): markdown.mjs in the browser harness's
# Playwright image (tests/browser/harness.sh `playwright_run`), with the
# console's assets mounted read-only. No release and no server: the page
# and the hook's modules are answered by the experiment itself.
#
# Usage: tests/markdown-proof/run.sh
# Writes markdown.json into MARKDOWN_OUT (default: a scratch directory,
# removed when the run ends).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-markdown-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT="${MARKDOWN_OUT:-$WORK/out}"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"

playwright_run markdown-proof markdown.mjs
