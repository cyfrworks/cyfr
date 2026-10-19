// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package reach

import (
	"os/exec"
	"syscall"
)

// createNewProcessGroup keeps a console's ^C from reaching a docker child
// in the middle of a stop or a start: cyfr decides when each step ends.
const createNewProcessGroup = 0x00000200

func ownGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewProcessGroup}
}

func killGroup(cmd *exec.Cmd) { cmd.Process.Kill() }
