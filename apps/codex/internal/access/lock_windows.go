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

// unlockExclusive lets go of the lock lockExclusive took, before its
// handle closes: a lock a closed handle or an exited process still holds
// is released by the kernel some time later ("the time it takes for the
// operating system to unlock these locks depends upon available system
// resources", LockFileEx's documentation), during which the next taker is
// refused, so a holder that ends in order unlocks itself. No child holds
// the handle on Windows (the docker watchdog is Unix's), so nothing else
// loses the lock here.
func unlockExclusive(f *os.File) {
	var ol windows.Overlapped
	windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, &ol)
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
