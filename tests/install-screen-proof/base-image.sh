# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The guests' base, sourced by tests/install-screen-proof/fetch-base.sh and
# lib.sh: Ubuntu 26.04's official cloud image of one release, held to the
# release's signed SHA256SUMS and to this sum, and the directory on disk
# that holds it, keyed by the sum.
#
# The cache is ${CYFR_PROOF_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cyfr/install-screen-proof},
# never RAM-backed: fetch-base.sh refuses a tmpfs. BASE_DIR, its
# subdirectory named by the pinned sum, holds the image, SHA256SUMS and
# SHA256SUMS.gpg once fetch-base.sh has verified them; a run mounts it
# read-only and verifies them again, with no network, before any guest
# boots from it.

# Read by the files that source this one.
# shellcheck disable=SC2034
CLOUD_RELEASE=https://cloud-images.ubuntu.com/releases/resolute/release-20261016
# shellcheck disable=SC2034
CLOUD_IMAGE=ubuntu-26.04-server-cloudimg-amd64.img
CLOUD_IMAGE_SHA256=5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5

BASE_CACHE=${CYFR_PROOF_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cyfr/install-screen-proof}
# shellcheck disable=SC2034
BASE_DIR=$BASE_CACHE/$CLOUD_IMAGE_SHA256
