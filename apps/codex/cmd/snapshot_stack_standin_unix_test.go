// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"fmt"
	"os"
	"syscall"
)

// standInID is the file's identity as find's '%D %i' writes it.
func standInID(info os.FileInfo, _ string) string {
	st := info.Sys().(*syscall.Stat_t)
	return fmt.Sprintf("%d %d", st.Dev, st.Ino)
}
