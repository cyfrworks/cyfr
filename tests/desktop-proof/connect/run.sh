#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The six-word road against a real CYFR (../README.md): this folder's
# proof.js, launched three times by ../launch.sh.
#
# Usage: bash tests/desktop-proof/connect/run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR
exec bash "$(dirname "$0")/../launch.sh" connect "${1:?usage: run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR}" "${2:?}" "${3:?}" \
  connect remembered changed
