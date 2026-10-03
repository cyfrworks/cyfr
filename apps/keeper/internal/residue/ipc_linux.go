// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package residue

import (
	"errors"
	"fmt"

	"golang.org/x/sys/unix"
)

// RemoveIPC removes System V IPC objects with IPC_RMID, which their owner or
// creator may do. An object already gone is removed. A shared memory segment
// still attached elsewhere is destroyed once its last attachment ends and
// can no longer be found by its key.
func RemoveIPC(objs []IPC) error {
	var errs []error
	for _, o := range objs {
		var errno unix.Errno
		switch o.Kind {
		case "shm":
			_, _, errno = unix.Syscall(unix.SYS_SHMCTL, uintptr(o.ID), unix.IPC_RMID, 0)
		case "sem":
			_, _, errno = unix.Syscall6(unix.SYS_SEMCTL, uintptr(o.ID), 0, unix.IPC_RMID, 0, 0, 0)
		case "msg":
			_, _, errno = unix.Syscall(unix.SYS_MSGCTL, uintptr(o.ID), unix.IPC_RMID, 0)
		default:
			errs = append(errs, fmt.Errorf("unknown IPC kind %q", o.Kind))
			continue
		}
		if errno != 0 && !errors.Is(errno, unix.EINVAL) && !errors.Is(errno, unix.EIDRM) {
			errs = append(errs, fmt.Errorf("%s %d: %w", o.Kind, o.ID, errno))
		}
	}
	return errors.Join(errs...)
}
