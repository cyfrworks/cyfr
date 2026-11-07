// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"testing"

	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

// runCLI runs the cyfr command line with args against srv, with a
// credential and no config file of the person's, and answers what it
// printed and the error main maps to its exit code.
func runCLI(t *testing.T, srv *cliServer, args ...string) (string, error) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CYFR_TOKEN", "cyfr-test-session")
	t.Cleanup(func() {
		flagJSON, flagURL, flagContext, flagNoInteractive, flagToken = false, "", "", false, ""
		rootCmd.SetArgs(nil)
	})

	// Cobra hands a command the context of its first execution and keeps
	// it unless it is nil; each run here is a process of its own, under its
	// own test's context.
	var forget func(c *cobra.Command)
	forget = func(c *cobra.Command) {
		c.SetContext(nil)
		for _, sub := range c.Commands() {
			forget(sub)
		}
	}
	forget(rootCmd)

	rootCmd.SetArgs(append(args, "--url", srv.URL))
	var err error
	out := captureStdout(t, func() { err = Execute(t.Context()) })
	return out, err
}

// exitsOne is whether main exits 1 for err: an error that is not the
// person's own Ctrl-C.
func exitsOne(err error) bool { return err != nil && !errors.Is(err, prompt.ErrAborted) }

func (s *cliServer) call(i int) (string, map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	name, _ := s.requests[i]["name"].(string)
	args, _ := s.requests[i]["arguments"].(map[string]any)
	return name, args
}

func (s *cliServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.requests)
}
