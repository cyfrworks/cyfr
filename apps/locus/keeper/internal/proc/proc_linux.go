// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package proc starts a process for a package that waits for its end, and
// hears that end from whoever reaps it. The keeper is a subreaper, and its
// reaper takes every child of its process that has exited, so a package's
// own wait there would find its child already taken: the keeper hands such
// a package its own start (package serve's startTool), whose reaper gives
// each end to the process it started, as it does for every child it starts.
// A process that reaps no child but the ones it waits for, a check or a
// test, hands it Own.
package proc

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Process is a started process.
type Process interface {
	Pid() int
	// Done closes once the process has exited and been reaped.
	Done() <-chan struct{}
	// Status is its end once Done has closed, or why it is not known: a
	// wait not its start's took it.
	Status() (unix.WaitStatus, error)
	// Kill sends SIGKILL to the process, or with group to the process group
	// it leads, unless it has been reaped: then its pid and its group's id
	// may be another's.
	Kill(group bool)
}

// Start forks and executes argv0 with argv, env, files and dir, as sys
// says, as syscall.ForkExec does.
type Start func(argv0 string, argv, env []string, files []uintptr, dir string, sys *syscall.SysProcAttr) (Process, error)

// Own is the Start of a process whose children are its own to reap: each
// is waited for by its pid alone.
func Own(argv0 string, argv, env []string, files []uintptr, dir string, sys *syscall.SysProcAttr) (Process, error) {
	pid, err := syscall.ForkExec(argv0, argv, &syscall.ProcAttr{Dir: dir, Env: env, Files: files, Sys: sys})
	if err != nil {
		return nil, err
	}
	p := &own{pid: pid, done: make(chan struct{})}
	go p.wait()
	return p, nil
}

type own struct {
	pid int
	// mu is held across the reap and every kill, so no kill reaches a pid
	// once it is reaped.
	mu     sync.Mutex
	done   chan struct{}
	status unix.WaitStatus
	err    error
}

// wait waits until the process can be reaped, without reaping it, and then
// reaps it under p.mu.
func (p *own) wait() {
	var info unix.Siginfo
	for unix.Waitid(unix.P_PID, p.pid, &info, unix.WEXITED|unix.WNOWAIT, nil) == unix.EINTR {
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for {
		_, err := unix.Wait4(p.pid, &p.status, 0, nil)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			p.err = fmt.Errorf("its end was taken by another wait: %w", err)
		}
		break
	}
	close(p.done)
}

func (p *own) Pid() int                         { return p.pid }
func (p *own) Done() <-chan struct{}            { return p.done }
func (p *own) Status() (unix.WaitStatus, error) { return p.status, p.err }

func (p *own) Kill(group bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	select {
	case <-p.done:
		return
	default:
	}
	pid := p.pid
	if group {
		pid = -pid
	}
	_ = unix.Kill(pid, unix.SIGKILL)
}

// ErrDeadline is a Run past its deadline, whose group was killed.
var ErrDeadline = errors.New("it passed its deadline and its group was killed")

// Run runs argv0 with argv and env from "/" through start, with no input
// and its output and its errors to out (none where nil), as sys says,
// which makes it lead a process group of its own (Setpgid or Setsid), to
// its end. Past deadline
// the group is killed whole while its leader is not yet reaped, so the
// group's id can still be no other's, and Run answers ErrDeadline. Once the
// leader has ended, its output is waited for outputWait at most: a process
// it left outside its group may hold it open. An end other than exit 0 is
// an error that says it.
func Run(start Start, argv0 string, argv, env []string, sys *syscall.SysProcAttr, out io.Writer, deadline, outputWait time.Duration) error {
	null, err := os.Open(os.DevNull)
	if err != nil {
		return err
	}
	defer null.Close()
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	defer r.Close()
	p, err := start(argv0, argv, env, []uintptr{null.Fd(), w.Fd(), w.Fd()}, "/", sys)
	_ = w.Close()
	if err != nil {
		return err
	}
	if out == nil {
		out = io.Discard
	}
	copied := make(chan struct{})
	go func() {
		defer close(copied)
		_, _ = io.Copy(out, r)
	}()
	timer := time.NewTimer(deadline)
	defer timer.Stop()
	passed := false
	select {
	case <-p.Done():
	case <-timer.C:
		p.Kill(true)
		passed = true
		<-p.Done()
	}
	// r was never handed to a child, so the runtime polls it, and closing
	// it ends the copy's read.
	select {
	case <-copied:
	case <-time.After(outputWait):
		_ = r.Close()
		<-copied
	}
	if passed {
		return ErrDeadline
	}
	ws, err := p.Status()
	if err != nil {
		return err
	}
	return Ended(ws)
}

// Ended is nil for an exit 0, and an error that says any other end.
func Ended(ws unix.WaitStatus) error {
	switch {
	case ws.Exited() && ws.ExitStatus() == 0:
		return nil
	case ws.Signaled():
		return fmt.Errorf("signal: %s", ws.Signal())
	default:
		return fmt.Errorf("exit status %d", ws.ExitStatus())
	}
}
