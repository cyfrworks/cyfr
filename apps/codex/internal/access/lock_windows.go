// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package access

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// lockExclusive takes LockFileEx(LOCKFILE_EXCLUSIVE_LOCK |
// LOCKFILE_FAIL_IMMEDIATELY) on f's first byte, reporting busy while
// another handle holds it. The lock belongs to the handle, which the
// kernel closes with the process that opened it.
func lockExclusive(f *os.File) (busy bool, err error) {
	var ol windows.Overlapped
	err = windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ol)
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) || errors.Is(err, windows.ERROR_IO_PENDING) {
		return true, nil
	}
	return false, err
}

// replaceFile renames from over to, written through to the disk before
// it returns: Windows has no directory to sync.
func replaceFile(from, to string) error {
	f, err := windows.UTF16PtrFromString(from)
	if err != nil {
		return err
	}
	t, err := windows.UTF16PtrFromString(to)
	if err != nil {
		return err
	}
	if err := windows.MoveFileEx(f, t, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH); err != nil {
		return &os.LinkError{Op: "rename", Old: from, New: to, Err: err}
	}
	return nil
}

// syncDir is nothing on Windows: replaceFile writes the rename through,
// and a directory handle cannot be flushed.
func syncDir(string) error { return nil }
