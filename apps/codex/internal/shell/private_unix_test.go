// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package shell

import (
	"os"
	"path/filepath"
	"testing"
)

// An existing device folder that other accounts could write in is made
// this account's alone before anything is read or kept there, and one that
// is a link is refused.
func TestDeviceDirKeepsAnExistingFolderPrivate(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".cyfr", "device")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o777); err != nil {
		t.Fatal(err)
	}
	got, err := DeviceDir()
	if err != nil || got != dir {
		t.Fatalf("DeviceDir = %q, %v", got, err)
	}
	if info, err := os.Stat(dir); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("the folder others could write in is %v (%v)", info.Mode(), err)
	}

	elsewhere := t.TempDir()
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, dir); err != nil {
		t.Fatal(err)
	}
	if _, err := DeviceDir(); err == nil {
		t.Fatal("a link in the device folder's place was used")
	}
}
