// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"fmt"
	"os/exec"
	"syscall"
	"time"
)

// runWithin runs cmd to its end, or for at most within: a process group of
// its own holds it and all it starts, so a terminal's ^C, which reaches
// this cyfr, does not cut it short, and at the bound the whole group is
// ended, SIGTERM first and SIGKILL boundGrace later. A run the bound ended
// answers errOverran, never its own status.
func runWithin(within time.Duration, cmd *exec.Cmd) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = boundGrace
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	bound := time.NewTimer(within)
	defer bound.Stop()
	select {
	case err := <-done:
		return err
	case <-bound.C:
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(boundGrace):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
	}
	return fmt.Errorf("%w %v", errOverran, within)
}
