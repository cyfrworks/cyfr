// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// The order a kept session ends by, one definition for the keeper, which
// ends a spawn's group, and a space's init, which ends what its command
// left: the leader alone is asked first and has until the deadline to end
// what it started; once it has ended, its children of the moment the end
// began are asked, each once, and waited for; then theirs, held as each
// level is asked, in turn, so a program behind a shell, or behind two, is
// asked as a leader is and ends what it started before that is asked;
// then whatever is left is asked once. Every process is asked through a
// pidfd held from before its level was asked, so no pid reaped and given
// to another process is ever signalled, and none is asked twice. Ender
// holds what the order needs of where it runs.

// Ender is what ending by levels needs of where it runs: how the
// processes are listed (Procs), how a place for a held pidfd is taken and
// given back (Reserve, Unreserve), and how a level's exit is waited for
// (Poll, Probe, PollInterval).
type Ender struct {
	Procs        func() ([]int, error)
	Reserve      func() bool
	Unreserve    func(n int)
	Poll         func([]unix.PollFd, int) (int, error)
	Probe        func(fd int) error
	PollInterval time.Duration
}

// Held is a process held by a pidfd.
type Held struct{ Pid, Fd int }

// Release closes the pidfds held and gives back their places.
func (e Ender) Release(held []Held) {
	for _, h := range held {
		_ = unix.Close(h.Fd)
	}
	e.Unreserve(len(held))
}

// Children holds, each by a pidfd, the processes whose parent is one of
// parents, as they stand now, and counts those it could not hold. It keeps
// a pidfd only when, after it was opened, the parent read is one of
// parents and the process still runs, so the pidfd names that process and
// no other that took its pid since; a caller that can reap a parent makes
// sure none of parents is reaped during the scan. It holds nothing past
// the deadline, and answers Procs's error when the processes could not be
// listed.
func (e Ender) Children(parents []int, deadline time.Time) (held []Held, unheld int, err error) {
	if len(parents) == 0 {
		return nil, 0, nil
	}
	pids, err := e.Procs()
	if err != nil {
		return nil, 1, err
	}
	isParent := func(pid int) bool {
		for _, p := range parents {
			if p == pid {
				return true
			}
		}
		return false
	}
	mayBeChild := func(pid int) bool {
		parent := ParentOf(pid)
		return isParent(parent) || parent == 0
	}
	for _, pid := range pids {
		if isParent(pid) {
			continue
		}
		if !time.Now().Before(deadline) {
			e.Release(held)
			return nil, unheld + 1, nil
		}
		if !e.Reserve() {
			if mayBeChild(pid) {
				unheld++
			}
			continue
		}
		fd, err := unix.PidfdOpen(pid, 0)
		if err != nil {
			e.Unreserve(1)
			if !errors.Is(err, unix.ESRCH) && mayBeChild(pid) {
				unheld++
			}
			continue
		}
		parent := ParentOf(pid)
		running := unix.PidfdSendSignal(fd, 0, nil, 0)
		if running == nil && isParent(parent) {
			held = append(held, Held{Pid: pid, Fd: fd})
			continue
		}
		_ = unix.Close(fd)
		e.Unreserve(1)
		if !errors.Is(running, unix.ESRCH) && (isParent(parent) || parent == 0) {
			unheld++
		}
	}
	return held, unheld, nil
}

// InTurn asks level by level, by deadline, beginning with level, which it
// releases with every level after it: before a level is asked the children
// its processes have then are held, the next level; each process of the
// level is sent SIGTERM once and the level is waited for until every one
// has exited or the deadline; then the next, until a level is empty.
func (e Ender) InTurn(level []Held, deadline time.Time) {
	for len(level) > 0 && time.Now().Before(deadline) {
		pids := make([]int, 0, len(level))
		for _, h := range level {
			pids = append(pids, h.Pid)
		}
		next, _, _ := e.Children(pids, deadline)
		fds := make([]int, 0, len(level))
		for _, h := range level {
			if !time.Now().Before(deadline) {
				break
			}
			_ = unix.PidfdSendSignal(h.Fd, unix.SIGTERM, nil, 0)
			fds = append(fds, h.Fd)
		}
		e.AwaitExits(fds, deadline)
		e.Release(level)
		level = next
	}
	e.Release(level)
}

// AwaitExits waits until every process the pidfds name has exited, or until
// the deadline. Each pidfd turns readable at its process's exit; a wait that
// cannot poll waits all the same, asking each pidfd on PollInterval whether
// its process is still there.
func (e Ender) AwaitExits(fds []int, deadline time.Time) {
	waiting := make([]unix.PollFd, 0, len(fds))
	for _, fd := range fds {
		waiting = append(waiting, unix.PollFd{Fd: int32(fd), Events: unix.POLLIN})
	}
	for len(waiting) > 0 {
		left := time.Until(deadline)
		if left <= 0 {
			return
		}
		n, err := e.Poll(waiting, int(min(left, time.Hour).Milliseconds())+1)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			e.probeExits(waiting, deadline)
			return
		}
		if n == 0 {
			continue
		}
		still := waiting[:0]
		for _, p := range waiting {
			if p.Revents == 0 {
				still = append(still, p)
			}
		}
		waiting = still
	}
}

// probeExits waits until no process the pidfds name is still there, asking
// each with signal 0 on PollInterval, or until the deadline. Only ESRCH
// proves a process gone; any other answer keeps the wait.
func (e Ender) probeExits(waiting []unix.PollFd, deadline time.Time) {
	for len(waiting) > 0 && time.Now().Before(deadline) {
		still := waiting[:0]
		for _, p := range waiting {
			if !errors.Is(e.Probe(int(p.Fd)), unix.ESRCH) {
				still = append(still, p)
			}
		}
		waiting = still
		if len(waiting) > 0 {
			time.Sleep(min(e.PollInterval, time.Until(deadline)))
		}
	}
}

// ParentOf is the parent pid /proc gives pid, 0 when it is unreadable.
func ParentOf(pid int) int {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0
	}
	// The command name may hold spaces and parentheses; the fields after
	// the last ')' are the state and then the parent's pid.
	fields := strings.Fields(string(stat[bytes.LastIndexByte(stat, ')')+1:]))
	if len(fields) < 2 {
		return 0
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0
	}
	return ppid
}
