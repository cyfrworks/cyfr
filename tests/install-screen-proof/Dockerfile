# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install-and-screen proof's VM host: QEMU/KVM, qemu-img and the cloud
# image tools, all from Ubuntu, so the verification host installs none of
# them. tests/install-screen-proof/prepare.sh builds it, outside any lane,
# as cyfr-install-screen:in-<h>, a hash of this file and guest/, which
# every worktree at those inputs shares; run.sh runs it as root with
# --device /dev/kvm. Its guest/ scripts are what the containers run. Its
# packages are the archive's of the day it was built.
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    cloud-image-utils \
    curl \
    gpgv \
    netcat-openbsd \
    openssh-client \
    openssl \
    python3 \
    qemu-system-x86 \
    qemu-utils \
    seabios \
    ubuntu-cloudimage-keyring \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /case /seed /run/proof

COPY guest/ /proof/
