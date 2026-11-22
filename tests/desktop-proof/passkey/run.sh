#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The passkey road against a real CYFR whose account service is another
# origin (../README.md): this folder's proof.js, launched once by
# ../launch.sh.
#
# Usage: bash tests/desktop-proof/passkey/run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR
exec bash "$(dirname "$0")/../launch.sh" passkey "${1:?usage: run.sh APP_PATH HOME_ORIGIN FIXTURE_DIR}" "${2:?}" "${3:?}" passkey
