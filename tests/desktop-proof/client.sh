#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The client of a real-CYFR proof (home.sh), run as root inside its
# ubuntu:24.04 container: the candidate package installed as a person
# installs it, with a display and a session bus to run under; the user
# `proof`; the run's authority (/fixture/authority.pem) trusted by the
# system, which cyfr reads, and by that user's NSS store, which the app's
# engine reads; and, where the script has a proof entry, its bundle
# (/fixture/proof.asar) in place of the installed app.asar. Nothing else
# is configured, and the container has no Docker.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends /deb/cyfr-desktop.deb xvfb xauth dbus-x11 libnss3-tools \
  ca-certificates >/dev/null
cp /fixture/authority.pem /usr/local/share/ca-certificates/cyfr-proof.crt
update-ca-certificates >/dev/null
useradd -m proof
su proof -c 'mkdir -p ~/.pki/nssdb && certutil -d sql:$HOME/.pki/nssdb -N --empty-password &&
  certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "cyfr proof run" -i /fixture/authority.pem'
if [ -f /fixture/proof.asar ]; then
  install -m 0644 /fixture/proof.asar /opt/cyfr/resources/app.asar
fi
