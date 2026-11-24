// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// updateLockPath is the lock one cyfr update at a time holds for this
// account, whose CYFR app the MSI installs for it alone, in its own
// temporary folder. A variable so tests stand in for it.
var updateLockPath = filepath.Join(os.TempDir(), "cyfr-update.lock")

// takeLock takes f's lock, refusing at once where another holds it.
func takeLock(f *os.File) (held bool, err error) {
	var ol windows.Overlapped
	err = windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ol)
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
		return true, nil
	}
	return false, err
}
