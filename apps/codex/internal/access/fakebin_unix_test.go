// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package access

import (
	"os"
	"path/filepath"
	"syscall"
)

// ownGroupNow reports whether this process leads its own process group.
func ownGroupNow() bool { return syscall.Getpgrp() == os.Getpid() }

// lockFDIsLock reports whether descriptor 3 is the project's lock file.
func lockFDIsLock(dir string) bool {
	var fd, lock syscall.Stat_t
	if syscall.Fstat(3, &fd) != nil || syscall.Stat(filepath.Join(dir, stateDir, lockFile), &lock) != nil {
		return false
	}
	return fd.Dev == lock.Dev && fd.Ino == lock.Ino
}
