// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package access

import (
	"errors"
	"os"
	"syscall"
)

// lockExclusive takes flock(LOCK_EX|LOCK_NB) on f, reporting busy while
// another open file description holds it. The lock lives on the open
// file description, so every process that inherited the descriptor keeps
// it until the last one closes it.
func lockExclusive(f *os.File) (busy bool, err error) {
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return true, nil
	}
	return false, err
}

// replaceFile renames from over to.
func replaceFile(from, to string) error { return os.Rename(from, to) }

// syncDir makes a rename or a removal in dir durable.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	return errors.Join(d.Sync(), d.Close())
}
