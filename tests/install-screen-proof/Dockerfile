# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The install-and-screen proof's VM host: QEMU/KVM, qemu-img and the cloud
# image tools, all from Ubuntu, so the verification host installs none of
# them. tests/install-screen-proof/run.sh builds it as
# ${PROOF_RUN_PREFIX}qemu:proof and runs it as root with --device /dev/kvm;
# its guest/ scripts are what the containers run.
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

# APT_REFRESH busts this layer's cache, so the packages are the archive's
# of that day rather than whatever day the cache was filled.
ARG APT_REFRESH=0
RUN echo "apt refresh ${APT_REFRESH}" && apt-get update \
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
