#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Two CYFRs in one app window, on the passkey road (../README.md, the pair
# shape): this folder's proof.js, launched three times by ../launch.sh.
#
# Usage: bash tests/desktop-proof/pair/run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR
exec bash "$(dirname "$0")/../launch.sh" pair "${1:?usage: run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR}" "${2:?}" "${3:?}" \
  pair selected resumed
