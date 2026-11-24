// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"log/syslog"
	"os"
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

// screenExec becomes the program args name, with args, in this process: the
// launcher's own child, whose end the launcher sees as the app's.
func screenExec(args []string) error {
	return syscall.Exec(args[0], args, os.Environ())
}

// screenEndParent ends this process's parent by the kernel, after first,
// where the parent is program: the parent is named by a pidfd, which no
// later process takes, and checked to be this process's parent still as it
// is read, so neither another process nor a parent that went is ended.
func screenEndParent(program string, first func()) error {
	parent := os.Getppid()
	fd, err := unix.PidfdOpen(parent, 0)
	if err != nil {
		return fmt.Errorf("its parent could not be named: %w", err)
	}
	defer unix.Close(fd)
	if os.Getppid() != parent {
		return errors.New("its parent ended")
	}
	exe, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", parent))
	if err != nil {
		return fmt.Errorf("its parent's program could not be read: %w", err)
	}
	if exe != program {
		return fmt.Errorf("its parent is %s, not the installed app", exe)
	}
	first()
	return unix.PidfdSendSignal(fd, unix.SIGKILL, nil, 0)
}

// screenSay says line on this process's standard error and in the
// system's log as cyfr-screen, the name the screen's session logs under
// (cmd/screen/session.sh).
func screenSay(line string) {
	fmt.Fprintln(os.Stderr, line)
	if l, err := syslog.New(syslog.LOG_ERR|syslog.LOG_USER, "cyfr-screen"); err == nil {
		_ = l.Err(line)
		_ = l.Close()
	}
}
