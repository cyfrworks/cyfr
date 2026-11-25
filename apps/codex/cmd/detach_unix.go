// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import "syscall"

// detachedFromApp starts a process in a session of its own, so nothing
// that ends the app's (its group, its terminal) ends it: an update the
// app's window asked for outlives the app it closes.
func detachedFromApp() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setsid: true} }
