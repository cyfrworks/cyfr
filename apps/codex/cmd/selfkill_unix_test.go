// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"os"
	"syscall"
)

// killSelf ends this process with SIGKILL, as a cyfr that dies where it
// stands: nothing of its own runs after it.
func killSelf() { syscall.Kill(os.Getpid(), syscall.SIGKILL) }
