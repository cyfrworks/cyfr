// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"os"
	"syscall"
)

func ownedByRoot(info os.FileInfo) bool { return ownedBy(info, 0) }

func ownedBy(info os.FileInfo, uid int) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == uid
}

// makeFIFO makes the FIFO path, the account's alone.
func makeFIFO(path string) error { return syscall.Mkfifo(path, 0o600) }

// The flags the plan's FIFO is opened with: without following a link, and
// for its unblocking reader, without waiting for a writer.
const (
	openNoFollow = syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	openNonBlock = syscall.O_NONBLOCK
)
