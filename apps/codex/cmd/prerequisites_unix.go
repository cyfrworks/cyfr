// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"os"
	"os/exec"
	"syscall"
)

func ownedByRoot(info os.FileInfo) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && st.Uid == 0
}

// exitStatus is the status a shell gives a child that ended: its exit
// code, or 128 and the signal that ended it.
func exitStatus(exit *exec.ExitError) int {
	if ws, ok := exit.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return exit.ExitCode()
}
