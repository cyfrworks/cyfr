#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Puts the runner's Docker daemon on the containerd image store, and fails
# unless the daemon then reports that store.
#
# Usage: sudo scripts/ci/containerd-image-store.sh
#        scripts/ci/containerd-image-store.sh --check
#
# A release build loads the image it pushes through a type=docker output,
# and the image carries the build's provenance attestation, which makes it
# an index. Docker's classic image store cannot hold an index: buildx
# refuses the build with "docker exporter does not currently support
# exporting manifest lists". GitHub's runners start on the classic store.
#
# The script sets features.containerd-snapshotter in
# /etc/docker/daemon.json, keeping every other setting there, and restarts
# docker.service, unless the daemon already uses the containerd store.
# The restart stops every container, and the classic store's images are
# not visible on the containerd one, so a job runs this before anything
# pulls, builds or loads an image and before buildx creates its builder.
# --check changes nothing and only reports the store.
# DOCKER_DAEMON_CONFIG names another configuration file, for the script's
# own test (tests/containerd-image-store-test.sh); the workflows set none,
# and sudo resets the environment.
#
# Exit status: 0 the daemon uses the containerd image store, 1 it does
# not, its configuration is unreadable or it did not come back, 64 usage,
# 69 a tool missing.
set -euo pipefail

config=${DOCKER_DAEMON_CONFIG:-/etc/docker/daemon.json}
want=io.containerd.snapshotter.v1

case "${1-}" in
  '') check_only= ;;
  --check) check_only=1 ;;
  *) echo "usage: $0 [--check]" >&2; exit 64 ;;
esac
[ "$#" -le 1 ] || { echo "usage: $0 [--check]" >&2; exit 64; }

tools="docker jq"
[ -n "$check_only" ] || tools="$tools systemctl"
for tool in $tools; do
  command -v "$tool" > /dev/null || { echo "$0: $tool is required" >&2; exit 69; }
done

# The daemon's image store: the driver type `docker info` names, which
# the classic store does not report, or nothing when no daemon answers.
# Without a daemon the CLI renders the template over an empty server
# answer, which Docker 28's CLI does with exit 0, so only an answer
# carrying the server's version is read.
store() {
  local status
  status=$(docker info --format '{{if .ServerVersion}}{{json .DriverStatus}}{{end}}' 2> /dev/null) || return 0
  [ -n "$status" ] || return 0
  jq -r 'first(.[]? | select(.[0] == "driver-type") | .[1]) // "classic"' <<< "$status" 2> /dev/null || return 0
}

if [ -z "$check_only" ] && [ "$(store)" != "$want" ]; then
  settings='{}'
  [ -s "$config" ] && settings=$(cat "$config")
  mkdir -p "${config%/*}"
  # An unreadable configuration fails here, before the daemon is touched.
  jq '.features["containerd-snapshotter"] = true' <<< "$settings" > "$config.new" 2> /dev/null || {
    rm -f "$config.new"
    echo "$0: $config is not a JSON object" >&2
    exit 1
  }
  mv "$config.new" "$config"
  systemctl restart docker.service
  for _ in $(seq 1 30); do
    [ -n "$(store)" ] && break
    sleep 1
  done
fi

found=$(store)
if [ -z "$found" ]; then
  echo "$0: the Docker daemon does not answer" >&2
  exit 1
fi
if [ "$found" != "$want" ]; then
  echo "$0: the Docker daemon uses the $found image store, not the containerd store ($want)" >&2
  exit 1
fi
echo "the Docker daemon uses the containerd image store"
