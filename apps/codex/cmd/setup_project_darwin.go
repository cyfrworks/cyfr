// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"time"

	"golang.org/x/sys/unix"
)

// exited returns once the child pid has exited, leaving it unreaped: a
// zombie whose number no other process can take. macOS has no waitid to
// ask that by, so its kqueue says when the child exits, and the
// process table, read again each second (sZombie), says whether it had
// already, before it was watched.
func exited(pid int) {
	gone := func() bool {
		p, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
		return err != nil || p.Proc.P_stat == sZombie
	}
	kq, err := unix.Kqueue()
	if err != nil {
		for !gone() {
			time.Sleep(time.Second)
		}
		return
	}
	defer unix.Close(kq)
	watch := []unix.Kevent_t{{Ident: uint64(pid), Filter: unix.EVFILT_PROC, Flags: unix.EV_ADD | unix.EV_ONESHOT, Fflags: unix.NOTE_EXIT}}
	got := make([]unix.Kevent_t, 1)
	second := unix.NsecToTimespec(int64(time.Second))
	for {
		n, err := unix.Kevent(kq, watch, got, &second)
		switch {
		case err == nil && n > 0, err != nil && err != unix.EINTR:
			// The exit, or the child refused as exited already (ESRCH).
			return
		case err == nil:
			watch = nil
		}
		if gone() {
			return
		}
	}
}

// sZombie is a process's state in the process table once it has exited
// and is not yet reaped (SZOMB in macOS's sys/proc.h).
const sZombie = 5
