// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package shell

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// privateFolder holds dir to this account alone: a folder, not a link,
// that this account owns, whose mode it sets to 0700 when another account
// could reach into it. One owned by another account is refused.
func privateFolder(dir string) error {
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("it is not a folder")
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(st.Uid) != os.Geteuid() {
		return fmt.Errorf("another account owns it")
	}
	if info.Mode().Perm() != 0o700 {
		return os.Chmod(dir, 0o700)
	}
	return nil
}
