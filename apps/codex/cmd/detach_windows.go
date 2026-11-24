// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"syscall"

	"golang.org/x/sys/windows"
)

// detachedFromApp starts a process out of the job the app's processes are
// in, which ends them all as the app ends, in a process group of its own
// and with no window: an update the app's window asked for outlives the
// app it closes. A job that forbids leaving it refuses the start.
func detachedFromApp() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_BREAKAWAY_FROM_JOB | windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_NO_WINDOW,
		HideWindow:    true,
	}
}
