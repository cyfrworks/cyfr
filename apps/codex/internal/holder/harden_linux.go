// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package holder

import (
	"errors"

	"golang.org/x/sys/unix"
)

// HardenProcess keeps an opened key out of crash dumps and away from other
// processes of the same user: it lowers the core-dump limit to zero, hard
// limit included, and marks the process not dumpable, which also refuses
// ptrace attachment and the process's /proc memory to unprivileged
// processes. It is best effort and stops neither root nor the kernel.
func HardenProcess() error {
	return errors.Join(
		unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{}),
		unix.Prctl(unix.PR_SET_DUMPABLE, 0, 0, 0, 0),
	)
}
