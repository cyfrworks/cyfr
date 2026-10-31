# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Sourced by tests/setup-proof/run.sh and held by cleanup-test.sh.

# logs_hold_no TOKEN WHAT COMMAND...: fail unless COMMAND's output, every
# byte of it, is readable, says something and does not hold TOKEN. The
# output goes to a file before it is searched: a `grep -q` on a pipe stops
# reading at its match, the writer then dies of SIGPIPE, and under pipefail
# the pipeline's failure reads as no match. WORK holds the file and `fail`
# ends the run.
logs_hold_no() {
  local token="$1" what="$2" file
  shift 2
  file="$(mktemp "$WORK/logs.XXXXXX")"
  "$@" >"$file" 2>&1 || fail "$what: the logs could not be read"
  [ -s "$file" ] || fail "$what: the logs are empty"
  if grep -qF -- "$token" "$file"; then
    fail "$what: the logs hold the setup token"
  fi
  rm -f "$file"
}
