// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"

	"github.com/cyfr/codex/internal/reach"
	"github.com/spf13/cobra"
)

func init() {
	internalCmd.AddCommand(dockerRunCmd)
	rootCmd.AddCommand(internalCmd)
}

// internalCmd holds the commands cyfr runs of itself and no person runs.
var internalCmd = &cobra.Command{
	Use:    "internal",
	Short:  "Commands cyfr runs of itself",
	Hidden: true,
}

// dockerRunCmd is the watchdog the reach engine starts each docker call
// through (reach.WatchdogMain): it holds the lock's descriptor it
// inherited and ends the call at its deadline. Its arguments are the
// engine's, passed through unparsed, and its exit status is the call's, so
// it ends the process itself rather than answer Execute.
var dockerRunCmd = &cobra.Command{
	Use:                "docker-run",
	Short:              "Run one docker call to its deadline, holding the stack's lock",
	Hidden:             true,
	DisableFlagParsing: true,
	Run: func(cmd *cobra.Command, args []string) {
		os.Exit(reach.WatchdogMain(args, os.Stdin, os.Stdout, os.Stderr))
	},
}
