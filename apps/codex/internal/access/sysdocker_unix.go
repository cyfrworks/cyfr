// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package access

import (
	"context"
	"errors"
	"fmt"
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
	// The watchdog starts docker only when told to go ahead, a byte on
	// this pipe written once the holder record names it: a holder killed
	// before that leaves a watchdog that reads the pipe's end and exits,
	// never a docker child holding the lock under a record that does not
	// name it. Both ends are close-on-exec, so no other child keeps the
	// write end open past this process.
	ahead, goAhead, err := os.Pipe()
	if err != nil {
		return -1, fmt.Errorf("access: start the docker watchdog: %w", err)
	}
	defer goAhead.Close()
	// The descriptors are fd 3 and 4 in the watchdog, outside Go's
	// close-on-exec, so the lock stays held while the watchdog or docker
	// lives.
	cmd.ExtraFiles = []*os.File{lock, ahead}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = waitGrace
	err = cmd.Start()
	ahead.Close()
	if err != nil {
		return -1, err
	}
	recorded := s.e.noteWatchdog(cmd.Process.Pid, time.Now().Add(deadline))
	defer s.e.doneWatchdog(cmd.Process.Pid)
	if recorded == nil {
		// A watchdog that has died does not read it; its exit answers below.
		goAhead.Write([]byte{1})
	}
	// Unrecorded, the watchdog reads the pipe's end and exits, docker not
	// run.
	goAhead.Close()
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
	if recorded != nil {
		return -1, recorded
	}
	if ctx.Err() != nil && !errors.Is(err, ctx.Err()) {
		return -1, errors.Join(ctx.Err(), err)
	}
	return exitStatus(err, false)
}
