// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package cmd

import (
	"errors"
	"os/exec"
	"time"
)

// screenClocks has nothing to read: the screen runs on Linux alone.
func screenClocks() (boot, monotonic time.Duration, err error) {
	return 0, 0, errors.New("the screen runs on Linux alone")
}

// screenChild is the child as it is: the screen runs on Linux alone.
func screenChild(c *exec.Cmd) *exec.Cmd { return c }

// screenExec starts nothing: the screen runs on Linux alone.
func screenExec([]string) error { return errors.New("the screen runs on Linux alone") }
