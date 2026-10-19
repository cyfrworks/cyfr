// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package reach

import (
	"os/exec"
	"syscall"
)

// ownGroup starts cmd as the leader of a process group of its own.
func ownGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killGroup kills cmd's process group: docker and the compose plugin it
// runs. SIGKILL, never SIGTERM: a `docker attach` that is asked to stop
// takes its container down with it.
func killGroup(cmd *exec.Cmd) {
	syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
