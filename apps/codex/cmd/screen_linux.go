// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os/exec"
	"syscall"
)

// screenChild makes a child of the screen's shell end with it: a shell
// killed outright leaves no keyboard, idle watch or Chrome behind, and no
// idle watch aimed at its pid once that pid is reused.
func screenChild(c *exec.Cmd) *exec.Cmd {
	c.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	return c
}
