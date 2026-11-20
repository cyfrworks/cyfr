#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The two-node suite's files one cell of test.yml's cluster job runs:
#   scripts/ci/cluster-cell.sh a|b
# printed on one line, separated by spaces. Cell a runs the files listed
# below; cell b every other *_test.exs under apps/cyfr/test/cluster of the
# current directory, so a new file of the suite runs in b. A listed file
# the suite does not have, a file listed twice, a name with a blank and a
# cell left with no file each fail with 1; any other argument exits 64.
#
# Cell a's files, chosen from one run's module times so the two cells end
# together: 277 s of the suite's 562 s of cases.
set -euo pipefail

cell_a=(
  apps/cyfr/test/cluster/execution_test.exs
  apps/cyfr/test/cluster/provisioning_test.exs
  apps/cyfr/test/cluster/revocation_test.exs
  apps/cyfr/test/cluster/context_freshness_test.exs
)

case "$#:${1:-}" in
  1:a|1:b) cell=$1 ;;
  *) echo "usage: $0 a|b" >&2; exit 64 ;;
esac

all=$(find apps/cyfr/test/cluster -name '*_test.exs' | LC_ALL=C sort)
if grep -q '[[:blank:]]' <<<"$all"; then echo "a file of the suite has a blank in its name" >&2; exit 1; fi
listed=$(printf '%s\n' "${cell_a[@]}" | LC_ALL=C sort)
twice=$(uniq -d <<<"$listed")
[ -z "$twice" ] || { echo "cell a lists a file twice: $twice" >&2; exit 1; }
absent=$(LC_ALL=C comm -13 <(printf '%s\n' "$all") <(printf '%s\n' "$listed"))
[ -z "$absent" ] || { echo "cell a lists files the suite does not have: $absent" >&2; exit 1; }
case "$cell" in
  a) files=$listed ;;
  b) files=$(LC_ALL=C comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$listed")) ;;
esac
[ -n "$files" ] || { echo "cell $cell has no file to run" >&2; exit 1; }
# shellcheck disable=SC2086 # one word a file: no name holds a blank
echo $files
