// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import "os/exec"

// workGroup starts setup's work as it is, and answers its wait and kill:
// Windows has no sg, the work is the process started, and its kill goes
// by the process's handle, which names it until it is reaped.
func workGroup(cmd *exec.Cmd) (wait func() error, kill func(), err error) {
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	return cmd.Wait, func() { _ = cmd.Process.Kill() }, nil
}
