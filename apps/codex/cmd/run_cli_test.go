// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// runCommand runs the command line with args, as given, under ctx.
func runCommand(t *testing.T, ctx context.Context, args ...string) (string, error) {
	t.Helper()
	// Cobra keeps a flag's value from one execution to the next; each run
	// here is a process of its own.
	reset := func() {
		flagJSON, flagURL, flagContext, flagNoInteractive, flagToken = false, "", "", false, ""
		rootCmd.SetArgs(nil)
	}
	reset()
	t.Cleanup(reset)
	var forget func(c *cobra.Command)
	forget = func(c *cobra.Command) {
		c.SetContext(nil)
		for _, sub := range c.Commands() {
			sub.Flags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
			forget(sub)
		}
	}
	forget(rootCmd)
	rootCmd.SetArgs(args)
	var err error
	out := captureStdout(t, func() { err = Execute(ctx) })
	return out, err
}
