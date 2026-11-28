// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"testing"

	"github.com/spf13/cobra"
)

// testLinkPublic is a tunnel key's public half, the private name vectors'
// first row's, testPrivate the private address it names on port 4000,
// and testLinkLine the .env line cyfr init writes for it.
const (
	testLinkKey    = "privkey:b09562be8a0bfee65eaeef5555dad1576019560663ae4616a0cef7b3c5e8c872,psk:6a681bf4064665498645f666e39f9c3917071baecf8685b0923468fd769c47bc"
	testLinkPublic = "6b6b937aca103230d149eb148efbcfb59e6d1f05bb04dc648ac3e92339eae74a"
	testPrivateAt  = "http://h-xeypbemm44chehc5.localhost:"
	testPrivate    = testPrivateAt + "4000"
	testLinkLine   = "CYFR_LINK_PUBLIC=" + testLinkPublic + "\n"
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
