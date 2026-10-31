#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The QEMU container's command (tests/install-screen-proof/Dockerfile):
#   guest-boot.sh NAME MEMORY_MIB DISK_SIZE CPUS IMAGE
# run.sh copies /seed/password and /seed/authorized_key in before the
# container starts. From them this makes the guest's NoCloud seed, and the
# seed does three things only: cloud-init creates the one account `proof`,
# a member of sudo whose password is set and unlocked, so sudo asks for it,
# with no sudoers rule of its own (no `sudo:` key, and no default user,
# whose rule is NOPASSWD); SSH takes that account's key and no password;
# the virtio NIC takes DHCP. No package and no command. Then a fresh qcow2
# overlay as /disk/NAME.qcow2 of /base/IMAGE, the verified base the host's
# cache holds, mounted read-only, and QEMU replaces this
# shell: KVM with the host's CPU model, a virtio disk, the virtio display,
# a USB tablet, the serial console in /case/serial.log, QMP at
# /run/proof/qmp.sock (its pid in /run/proof/qemu.pid), and user
# networking that forwards the container's loopback port 2222 to the
# guest's SSH, which run.sh reaches through docker exec.
set -eu
name=$1 memory=$2 disk_size=$3 cpus=$4 image=$5
run=/run/proof
mkdir -p "$run" /case
{
  echo "container user: $(id)"
  echo "container /dev/kvm: $(ls -l /dev/kvm)"
  qemu-system-x86_64 --version | head -n 1
} >/case/container.txt 2>&1

umask 077
hash=$(openssl passwd -6 -stdin </seed/password)
key=$(cat /seed/authorized_key)
cat >"$run/user-data" <<EOF
#cloud-config
users:
  - name: proof
    gecos: CYFR proof
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    passwd: "$hash"
    ssh_authorized_keys:
      - "$key"
chpasswd:
  expire: false
ssh_pwauth: false
EOF
cat >"$run/meta-data" <<EOF
instance-id: $name
local-hostname: cyfr-proof
EOF
cat >"$run/network-config" <<'EOF'
version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: true
EOF
cloud-localds --network-config="$run/network-config" "$run/seed.img" "$run/user-data" "$run/meta-data"
qemu-img create -q -f qcow2 -F qcow2 -b "/base/$image" "/disk/$name.qcow2" "$disk_size"

umask 022
# exec keeps this shell's pid, which is then QEMU's.
echo "$$" >"$run/qemu.pid"
exec qemu-system-x86_64 \
  -name "guest=$name" \
  -machine q35 -accel kvm -cpu host -smp "$cpus" -m "$memory" \
  -display none -vga none -monitor none \
  -device virtio-vga \
  -device qemu-xhci -device usb-tablet \
  -drive "if=none,id=root,file=/disk/$name.qcow2,format=qcow2" \
  -device virtio-blk-pci,drive=root,bootindex=0 \
  -drive "if=none,id=seed,file=$run/seed.img,format=raw,readonly=on" \
  -device virtio-blk-pci,drive=seed \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0,romfile= \
  -serial file:/case/serial.log \
  -qmp "unix:$run/qmp.sock,server=on,wait=off"
