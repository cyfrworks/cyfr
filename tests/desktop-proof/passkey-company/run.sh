#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The passkey road against the CYFR its home file names (../README.md):
# this folder's proof.js, launched once by ../launch.sh.
#
# Usage: bash tests/desktop-proof/passkey-company/run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR
exec bash "$(dirname "$0")/../launch.sh" passkey-company "${1:?usage: run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR}" "${2:?}" "${3:?}" passkey
