#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Run a security scanner and pass only when it exits 0.
#
# Usage: scripts/security-scan.sh <command> [args...]
#
# The command runs unchanged, with its arguments as given. Every nonzero exit
# fails with the command's own code: a finding, a scanner panic, any other
# tool failure and a missing executable alike, because a scan that did not
# complete is not clean coverage. No exit code is waived or reclassified here.
set -uo pipefail

if [ $# -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 64
fi

"$@"
code=$?
if [ "$code" -ne 0 ]; then
  echo "security-scan: $1 exited $code" >&2
fi
exit "$code"
