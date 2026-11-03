// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package cmd

import "os/exec"

// screenChild is the child as it is: the screen runs on Linux alone.
func screenChild(c *exec.Cmd) *exec.Cmd { return c }
