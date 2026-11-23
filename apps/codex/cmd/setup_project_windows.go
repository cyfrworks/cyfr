// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "os/exec"

// workGroup leaves setup's work as it starts: Windows has no sg, and the
// work is the process started.
func workGroup(*exec.Cmd) {}

// killWorkGroup kills setup's work.
func killWorkGroup(cmd *exec.Cmd) { _ = cmd.Process.Kill() }
