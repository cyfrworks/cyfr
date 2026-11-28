// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// usable is whether path, read apart from the reader under test, is a
// character device of the misc major and minor whose mode and group a VMM
// opens it through: by its group, which is not root's, where byGroup, and
// by everyone where not.
func usable(path string, minor uint64, byGroup bool) bool {
	info, err := os.Stat(path)
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	st := info.Sys().(*syscall.Stat_t)
	if (st.Rdev>>8)&0xfff != 10 || (st.Rdev&0xff)|((st.Rdev>>12)&0xfff00) != minor {
		return false
	}
	if byGroup {
		return st.Gid != 0 && info.Mode().Perm()&0o060 == 0o060
	}
	return info.Mode().Perm()&0o006 == 0o006
}

// A machine has the devices where /dev/kvm is KVM's misc device, read and
// written by its group, which is not root's, and /dev/net/tun the tun
// device, read and written by everyone: both or neither. Each row on this
// machine's own nodes, a row skipped where it lacks one of them.
func TestTheDevicesAreBothOrNeither(t *testing.T) {
	kvm, tun := "/dev/kvm", "/dev/net/tun"
	missing := filepath.Join(t.TempDir(), "absent")
	kvmHere, tunHere := usable(kvm, 232, true), usable(tun, 200, false)
	for name, c := range map[string]struct {
		kvm, tun   string
		needs, has bool
	}{
		"both here":                {kvm, tun, kvmHere && tunHere, true},
		"KVM here, no tun":         {kvm, missing, kvmHere, false},
		"tun here, no KVM":         {missing, tun, tunHere, false},
		"neither":                  {missing, missing, true, false},
		"the tun device for both":  {tun, tun, tunHere, false},
		"/dev/null at both places": {"/dev/null", "/dev/null", true, false},
	} {
		t.Run(name, func(t *testing.T) {
			if !c.needs {
				t.Skip("this machine lacks a device the row reads")
			}
			if got := devicesAt(c.kvm, c.tun); got != c.has {
				t.Errorf("KVM at %s and tun at %s read as the devices: %t, want %t", c.kvm, c.tun, got, c.has)
			}
		})
	}
}

// A device is read by its numbers, its kind, and the mode and group a VMM
// opens it through: the tun device, read and written by everyone, is no
// device read through a group not root's; KVM's, read and written by its
// group alone, is none read by everyone; a misc device of another minor, a
// character device of another major, a file, a folder and nothing are
// none.
func TestADeviceIsReadByItsNumbersModeAndGroup(t *testing.T) {
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		path    string
		minor   uint32
		byGroup bool
	}{
		"/dev/null, 1:3":  {"/dev/null", 3, false},
		"a file":          {file, 232, true},
		"a folder":        {t.TempDir(), 232, true},
		"nothing":         {filepath.Join(t.TempDir(), "absent"), 200, false},
		"tun, minor 201":  {"/dev/net/tun", 201, false},
		"tun by a group":  {"/dev/net/tun", 200, true},
		"KVM, minor 233":  {"/dev/kvm", 233, true},
		"KVM by everyone": {"/dev/kvm", 232, false},
	} {
		t.Run(name, func(t *testing.T) {
			if name == "KVM by everyone" && (!usable("/dev/kvm", 232, true) || usable("/dev/kvm", 232, false)) {
				t.Skip("this machine's /dev/kvm is not read and written by its group alone")
			}
			if miscDevice(c.path, c.minor, c.byGroup) {
				t.Errorf("%s reads as the misc device of minor %d (by its group: %t)", c.path, c.minor, c.byGroup)
			}
		})
	}
	if usable("/dev/net/tun", 200, false) && !miscDevice("/dev/net/tun", 200, false) {
		t.Error("this machine's tun device, read and written by everyone, does not read as one")
	}
	if usable("/dev/kvm", 232, true) && !miscDevice("/dev/kvm", 232, true) {
		t.Error("this machine's KVM device, read and written by its group, which is not root's, does not read as one")
	}
}
