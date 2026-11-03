// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/cyfr/codex/internal/config"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// withContexts writes a config of contexts, current naming one, under a
// home of the test's own, and answers its path.
func withContexts(t *testing.T, current string, contexts map[string]*config.Context) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CYFR_TOKEN", "")
	for _, v := range []string{sessionEnv, sessionHomeEnv, shellPIDEnv, shellPagesEnv} {
		t.Setenv(v, "")
	}
	cfg := &config.Config{CurrentContext: current, Contexts: contexts}
	path := filepath.Join(home, ".cyfr", "config.json")
	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("writing the config: %v", err)
	}
	return path
}

// runCommand runs the command line with args, as given, under ctx.
func runCommand(t *testing.T, ctx context.Context, args ...string) (string, error) {
	t.Helper()
	// Cobra keeps a flag's value from one execution to the next; each run
	// here is a process of its own.
	reset := func() {
		flagJSON, flagURL, flagContext, flagNoInteractive, flagToken = false, "", "", false, ""
		flagLoginSetup, flagLoginJoin, flagLoginInvitation, flagLoginName, flagLoginPIN = false, false, "", "", false
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
