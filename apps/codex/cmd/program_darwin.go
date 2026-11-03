// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"path/filepath"

	"golang.org/x/sys/unix"
)

// sameProgram is whether process pid runs the program at path, as the
// kernel names it: the first 16 bytes of its file's name, the most macOS
// keeps of it (p_comm).
func sameProgram(pid int, path string) bool {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return false
	}
	comm := unix.ByteSliceToString(info.Proc.P_comm[:])
	name := filepath.Base(path)
	if len(name) > len(info.Proc.P_comm)-1 {
		name = name[:len(info.Proc.P_comm)-1]
	}
	return comm != "" && comm == name
}
