// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "golang.org/x/sys/unix"

// exited returns once the child pid has exited, leaving it unreaped: a
// zombie whose number no other process can take.
func exited(pid int) {
	var info unix.Siginfo
	for unix.Waitid(unix.P_PID, pid, &info, unix.WEXITED|unix.WNOWAIT, nil) == unix.EINTR {
	}
}
