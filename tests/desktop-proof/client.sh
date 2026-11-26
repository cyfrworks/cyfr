#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The client of a real-CYFR proof (home.sh), run as root inside an
# ubuntu:24.04 container, in three parts:
#   fetch    the candidate package's dependencies and the packages a proof
#            runs under (a display, a session bus, NSS's tools, the
#            system's trust), fetched from the archive into apt's cache: a
#            fresh index and nothing installed, so that home.sh may try it
#            again when the archive answers wrongly
#   install  the candidate package (/deb/cyfr-desktop.deb) installed as a
#            person installs it, with apt, with those packages, which the
#            cache already holds (apt's --no-download refuses a package
#            named by its path)
#   proof    in a container of one proof's own, started from what install
#            left: the user `proof`; the run's authority
#            (/fixture/authority.pem) trusted by the system, which cyfr
#            reads, and by that user's NSS store, which the app's engine
#            reads; and, where the script has a proof entry, its bundle
#            (/fixture/proof.asar) in place of the installed app.asar
# Nothing else is configured, and the container has no Docker.
#
# Usage: bash client.sh fetch|install|proof
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
packages=(/deb/cyfr-desktop.deb xvfb xauth dbus-x11 libnss3-tools ca-certificates)
case "${1:-}" in
  fetch)
    # An index any part of which fails to fetch fails the update, and the
    # fetches that failed are named last, where home.sh's tail shows them.
    if ! apt-get update -qq --error-on=any >/tmp/fetch.log 2>&1 ||
      ! apt-get install -y -qq --no-install-recommends --download-only "${packages[@]}" >>/tmp/fetch.log 2>&1; then
      cat /tmp/fetch.log
      echo "the archive's answer that failed:"
      grep -E '^(Err:|E:|W:)' /tmp/fetch.log | sed 's/^/  /'
      exit 1
    fi
    ;;
  install)
    apt-get install -y -qq --no-install-recommends "${packages[@]}" >/dev/null
    ;;
  proof)
    cp /fixture/authority.pem /usr/local/share/ca-certificates/cyfr-proof.crt
    update-ca-certificates >/dev/null
    useradd -m proof
    su proof -c 'mkdir -p ~/.pki/nssdb && certutil -d sql:$HOME/.pki/nssdb -N --empty-password &&
      certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "cyfr proof run" -i /fixture/authority.pem'
    if [ -f /fixture/proof.asar ]; then
      install -m 0644 /fixture/proof.asar /opt/cyfr/resources/app.asar
    fi
    ;;
  *)
    echo "usage: bash client.sh fetch|install|proof" >&2
    exit 64
    ;;
esac
