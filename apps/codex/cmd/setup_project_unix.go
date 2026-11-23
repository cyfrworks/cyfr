//go:build unix

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os/exec"
	"sync"
	"syscall"
)

// workGroup starts setup's work as the leader of a process group of its
// own, which sg, where it comes first, and the work share, and answers its
// wait and kill. kill signals the group only while its leader has not
// been reaped, so the group's number is still the work's: wait learns of
// the leader's exit without reaping it (exited), marks it reaped under
// the lock kill takes, and only then reaps it.
func workGroup(cmd *exec.Cmd) (wait func() error, kill func(), err error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	pid := cmd.Process.Pid
	var mu sync.Mutex
	reaped := false
	wait = func() error {
		exited(pid)
		mu.Lock()
		reaped = true
		mu.Unlock()
		return cmd.Wait()
	}
	kill = func() {
		mu.Lock()
		defer mu.Unlock()
		if !reaped {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	}
	return wait, kill, nil
}
