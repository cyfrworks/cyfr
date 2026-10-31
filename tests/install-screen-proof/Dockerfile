# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install-and-screen proof's VM host: QEMU/KVM, qemu-img and the cloud
# image tools, all from Ubuntu, so the verification host installs none of
# them. tests/install-screen-proof/prepare.sh builds it, outside any lane,
# as cyfr-install-screen:in-<h>, a hash of this file and guest/, which
# every worktree at those inputs shares. Its guest/ scripts are what the
# containers run, as the unprivileged PROOF_UID: QEMU needs no root, only
# /dev/kvm, which run.sh passes with --device and --group-add of the
# device's own gid, read from the host at run time. A volume new at /disk
# takes that directory's owner. Its packages are the archive's of the day
# it was built.
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
ARG PROOF_UID=10001

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
  && mkdir -p /case /disk /seed /run/proof \
  && chown "${PROOF_UID}:${PROOF_UID}" /case /disk /seed /run/proof

COPY guest/ /proof/

# The user has no passwd entry, so no home of its own.
ENV HOME=/tmp
USER ${PROOF_UID}:${PROOF_UID}
