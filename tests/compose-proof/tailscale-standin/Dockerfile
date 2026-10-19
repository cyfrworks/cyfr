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
COPY standin /usr/local/bin/standin
RUN ln -s standin /usr/local/bin/tailscale && ln -s standin /usr/local/bin/containerboot
CMD ["/usr/local/bin/containerboot"]
