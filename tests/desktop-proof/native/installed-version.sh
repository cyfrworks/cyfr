#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The cyfr an installed package carries is the release's: its --version's
# first line is exactly "cyfr version VERSION". Release runs it on each
# package it publishes, after the package is installed on its runner.
#
# Usage: bash tests/desktop-proof/native/installed-version.sh CYFR VERSION
set -euo pipefail

[ "$#" -eq 2 ] && [ -n "$2" ] || { echo "usage: bash $0 CYFR VERSION" >&2; exit 64; }
installed=$("$1" --version)
if [ "${installed%%$'\n'*}" != "cyfr version $2" ]; then
  echo "::error::the package's cyfr at $1 says [$installed], not cyfr version $2"
  exit 1
fi
echo "the package's cyfr at $1 is cyfr version $2"
