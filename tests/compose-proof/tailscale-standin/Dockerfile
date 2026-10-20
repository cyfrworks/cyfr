# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Compose proof's Tailscale stand-in (main.go says what it reproduces,
# and that it certifies no Tailscale binary): BASE, the caddy service's
# image docker-compose.yml pins, with the stand-in installed as
# tailscale, containerboot and standin, and containerboot the command, as
# the tailscale/tailscale image runs it. build.sh builds the program and
# names BASE.
ARG BASE
FROM ${BASE}
ARG STANDIN_UID=10001
COPY --chmod=755 standin /usr/local/bin/standin
RUN ln -s standin /usr/local/bin/tailscale && ln -s standin /usr/local/bin/containerboot \
    && mkdir -p /var/lib/tailscale && chown ${STANDIN_UID}:${STANDIN_UID} /var/lib/tailscale
USER ${STANDIN_UID}:${STANDIN_UID}
CMD ["/usr/local/bin/containerboot"]
