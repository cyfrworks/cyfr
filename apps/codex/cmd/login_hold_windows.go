// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"

	"github.com/cyfr/codex/internal/shell"
)

// holdShell is not reached on Windows, where cyfr login holds no device.
func holdShell(device, *shell.Server, string, string, <-chan struct{}) error {
	return errors.New("cyfr login holds a device on Linux and macOS")
}

// endShell has no shell of cyfr login's to end on Windows.
func endShell(string) error { return errors.New("no shell of cyfr login runs on Windows") }
