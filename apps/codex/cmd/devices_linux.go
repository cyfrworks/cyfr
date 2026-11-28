// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import "golang.org/x/sys/unix"

// hasDevices is whether this machine has both devices a person's computer
// of their own needs, as the keeper uses them (its deviceHeld): the open
// aside, which the keeper makes in its container as the account Docker
// gives it, which this account need not be.
func hasDevices() bool { return devicesAt("/dev/kvm", "/dev/net/tun") }

// devicesAt is whether kvm is the misc character device of KVM (10:232),
// read and written by its group, which is not root's, as a VMM holds it,
// and tun the tun device (10:200), read and written by everyone: both or
// neither, since a VM needs both.
func devicesAt(kvm, tun string) bool {
	return miscDevice(kvm, 232, true) && miscDevice(tun, 200, false)
}

// miscDevice is whether path is the misc character device of minor, read
// and written through its group, which is not root's, where byGroup, and
// by everyone where not.
func miscDevice(path string, minor uint32, byGroup bool) bool {
	var st unix.Stat_t
	if unix.Stat(path, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFCHR || unix.Major(st.Rdev) != 10 || unix.Minor(st.Rdev) != minor {
		return false
	}
	if byGroup {
		return st.Gid != 0 && st.Mode&0o060 == 0o060
	}
	return st.Mode&0o006 == 0o006
}
