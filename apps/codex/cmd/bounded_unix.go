// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"errors"
	"fmt"
	"os/exec"
	"syscall"
	"time"
)

// runWithin runs cmd to its end, or for at most within: a process group of
// its own holds it and all it starts, so a terminal's ^C, which reaches
// this cyfr, does not cut it short. A bound is the limit, its slack
// already in it: at the bound the whole group is killed (SIGKILL), so
// nothing of it does any more work, and runWithin returns only once no
// process of the group is left; it then answers errOverran, never the
// run's own status. A run that ends within its bound leaves nothing of its
// group running either: what it left behind is killed the same way. A
// process that left the group (a new session of its own) is beyond it.
func runWithin(within time.Duration, cmd *exec.Cmd) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = boundGrace
	if err := cmd.Start(); err != nil {
		return err
	}
	group := cmd.Process.Pid
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	bound := time.NewTimer(within)
	defer bound.Stop()
	select {
	case err := <-done:
		if gerr := endGroup(group, nil); gerr != nil {
			return errors.Join(err, gerr)
		}
		return err
	case <-bound.C:
	}
	gerr := endGroup(group, done)
	return errors.Join(fmt.Errorf("%w %v", errOverran, within), gerr)
}

// endGroup kills process group group and waits until none of it is left,
// answering an error where some of it still is boundGrace later. done,
// when not nil, is the leader's end, which is waited for too.
func endGroup(group int, done <-chan error) error {
	if groupGone(group) && done == nil {
		return nil
	}
	_ = syscall.Kill(-group, syscall.SIGKILL)
	if waitGroupGone(group, done, boundGrace) {
		return nil
	}
	return fmt.Errorf("the process group %d was still running %v after it was killed", group, boundGrace)
}

// waitGroupGone waits at most within for the leader's end (done, when not
// nil) and for no process of group to be left.
func waitGroupGone(group int, done <-chan error, within time.Duration) bool {
	deadline := time.Now().Add(within)
	for {
		if done != nil {
			select {
			case <-done:
				done = nil
			default:
			}
		}
		if done == nil && groupGone(group) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond) // sleep-ok: the pace of asking the kernel whether a group it was asked to end is gone
	}
}

// groupGone is whether no process of group is left: one the kernel will
// not signal for this cyfr (EPERM) is still there.
func groupGone(group int) bool {
	return errors.Is(syscall.Kill(-group, 0), syscall.ESRCH)
}
