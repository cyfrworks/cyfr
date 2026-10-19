// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package reach

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// run runs docker: under the watchdog with the lock's descriptor while
// the engine holds the lock, else directly, bounded by deadline either
// way. A cancelled ctx ends the call: the watchdog is asked to kill
// docker, a direct child's process group is killed.
func (s *systemDocker) run(ctx context.Context, bin string, args []string, deadline time.Duration, streams func(*exec.Cmd)) (int, error) {
	lock := s.e.lockFile()
	if lock == nil {
		ctx, cancel := context.WithTimeout(ctx, deadline)
		defer cancel()
		cmd := exec.CommandContext(ctx, bin, args...)
		streams(cmd)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
		cmd.WaitDelay = waitGrace
		err := cmd.Run()
		return exitStatus(err, errors.Is(ctx.Err(), context.DeadlineExceeded))
	}

	argv, err := s.watchdogArgv()
	if err != nil {
		return -1, err
	}
	cmd := exec.Command(argv[0], append(append(argv[1:len(argv):len(argv)], watchdogArgs(deadline, true)...), append([]string{bin}, args...)...)...)
	streams(cmd)
	// The descriptor is fd 3 in the watchdog, outside Go's close-on-exec,
	// so the lock stays held while the watchdog or docker lives.
	cmd.ExtraFiles = []*os.File{lock}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = waitGrace
	if err := cmd.Start(); err != nil {
		return -1, err
	}
	s.e.noteWatchdog(cmd.Process.Pid, time.Now().Add(deadline))
	defer s.e.doneWatchdog(cmd.Process.Pid)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	backstop := time.NewTimer(deadline + waitGrace)
	defer backstop.Stop()
	select {
	case err = <-done:
	case <-ctx.Done():
		cmd.Process.Signal(syscall.SIGTERM)
		err = <-done
		if err == nil {
			err = ctx.Err()
		}
	case <-backstop.C:
		cmd.Process.Kill()
		err = <-done
	}
	if ctx.Err() != nil && !errors.Is(err, ctx.Err()) {
		return -1, errors.Join(ctx.Err(), err)
	}
	return exitStatus(err, false)
}
