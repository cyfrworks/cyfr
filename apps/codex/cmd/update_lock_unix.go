// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"errors"
	"os"
	"syscall"
)

// updateLockPath is the lock one cyfr update at a time holds on this
// computer, in its shared temporary folder, which every account may write
// and none may take from another (the sticky bit): an account opens one
// another made for reading, which is all a lock needs. A variable so
// tests stand in for it.
var updateLockPath = "/var/tmp/cyfr-update.lock"

// takeLock takes f's lock, refusing at once where another holds it.
func takeLock(f *os.File) (held bool, err error) {
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return true, nil
	}
	return false, err
}
