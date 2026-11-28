// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

// A device is the machine's where its path is a character device of the
// misc major and the minor asked for: a misc device of another minor, a
// character device of another major, a file and nothing are not.
func TestHasDeviceReadsTheMiscNumbers(t *testing.T) {
	if hasDevice("/dev/null", 3) {
		t.Error("/dev/null, character device 1:3, reads as the misc device of minor 3")
	}
	if hasDevice(filepath.Join(t.TempDir(), "kvm"), 232) {
		t.Error("a path that names nothing reads as a device")
	}
	if hasDevice(t.TempDir(), 232) {
		t.Error("a folder reads as a device")
	}
	// A misc device this machine has, whichever it is: the reader is the
	// one the real machine answers with.
	for _, path := range []string{"/dev/net/tun", "/dev/fuse", "/dev/kvm", "/dev/autofs", "/dev/uinput"} {
		var st unix.Stat_t
		if unix.Stat(path, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFCHR || unix.Major(st.Rdev) != 10 {
			continue
		}
		minor := unix.Minor(st.Rdev)
		if !hasDevice(path, minor) {
			t.Errorf("%s, misc device 10:%d, does not read as minor %d", path, minor, minor)
		}
		if hasDevice(path, minor+1) {
			t.Errorf("%s, misc device 10:%d, reads as minor %d", path, minor, minor+1)
		}
		return
	}
	t.Skip("this machine has none of the misc devices the test reads")
}
