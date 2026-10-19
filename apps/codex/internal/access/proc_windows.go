// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package access

import (
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// createNewProcessGroup keeps a console's ^C from reaching a docker child
// in the middle of a stop or a start: cyfr decides when each step ends.
const createNewProcessGroup = 0x00000200

func ownGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup}
}

func killGroup(cmd *exec.Cmd) { cmd.Process.Kill() }

// processAlive reports whether process pid has not exited.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	h, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	ev, err := windows.WaitForSingleObject(h, 0)
	return err == nil && ev == uint32(windows.WAIT_TIMEOUT)
}
