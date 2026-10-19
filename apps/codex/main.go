// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"os"

	"github.com/cyfr/codex/cmd"
)

func main() {
	// The one place a command's failure ends the process: cmd.Main runs
	// the command under the signals that cancel it and answers its status
	// (cmd.ExitStatus).
	os.Exit(cmd.Main())
}
