// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"fmt"
	"io/fs"
	"syscall"
)

// fileOwner is a file's owner and group, as uid:gid.
func fileOwner(info fs.FileInfo) string {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return fmt.Sprintf("%d:%d", st.Uid, st.Gid)
	}
	return "?"
}
