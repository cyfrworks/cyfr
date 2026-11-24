// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os/exec"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// screenClocks reads the boot clock and then the monotonic clock: in that
// order a pause between the two never looks like a sleep.
func screenClocks() (boot, monotonic time.Duration, err error) {
	var b, m unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_BOOTTIME, &b); err != nil {
		return 0, 0, err
	}
	if err := unix.ClockGettime(unix.CLOCK_MONOTONIC, &m); err != nil {
		return 0, 0, err
	}
	return time.Duration(b.Nano()), time.Duration(m.Nano()), nil
}

// screenChild makes a child of the screen's shell end with it: a shell
// killed outright leaves no keyboard or suspend watch behind, and no
// suspend watch aimed at its pid once that pid is reused.
func screenChild(c *exec.Cmd) *exec.Cmd {
	c.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	return c
}
