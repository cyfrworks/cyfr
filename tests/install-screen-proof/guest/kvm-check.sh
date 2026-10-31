#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The proof's first step, before any guest exists: QEMU inside the
# container creates a KVM machine, its CPUs held stopped (-S), and answers
# query-kvm on QMP over stdio before it quits. Prints the container's
# user, its /dev/kvm and QEMU's version first. A QEMU that cannot open
# /dev/kvm prints why and exits non-zero.
set -eu
echo "container user: $(id)"
echo "container /dev/kvm: $(ls -l /dev/kvm)"
qemu-system-x86_64 --version | head -n 1
printf '%s\n' '{"execute": "qmp_capabilities"}' '{"execute": "query-kvm"}' '{"execute": "quit"}' |
  timeout 60 qemu-system-x86_64 -accel kvm -machine q35 -cpu host -nodefaults -display none -S -qmp stdio
