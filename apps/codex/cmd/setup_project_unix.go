//go:build unix

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os/exec"
	"syscall"
)

// workGroup starts setup's work as the leader of a process group of its
// own, which sg, where it comes first, and the work share.
func workGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killWorkGroup kills setup's work and everything in its process group.
func killWorkGroup(cmd *exec.Cmd) {
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
