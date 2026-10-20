// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"os"
	"syscall"
)

// continueAs replaces this process with the program at path run with
// args, its environment, its terminal and its process id kept, so the one
// `cyfr update` goes on as the new program. It returns only on failure;
// no lock is held at the handover, and every descriptor Go opens is closed
// on exec.
func continueAs(path string, args []string) (int, error) {
	return 0, syscall.Exec(path, args, os.Environ())
}
