// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"os"
	"testing"
)

// watchdogChild marks a run of this test binary that a test started as the
// engine's watchdog: one the dispatch below does not take exits at once
// rather than run the suite.
const watchdogChild = "CYFR_CMD_TEST_WATCHDOG_CHILD"

// TestMain runs the package's tests under a home of their own: init and
// the commands that sign in save the CLI's config under ~/.cyfr, and no
// test reads or writes the home of the person running it.
//
// The reach engine runs each docker call through `cyfr internal
// docker-run`, a re-exec of the running binary, which under go test is
// this test binary: run so, it serves the call through the command tree as
// cyfr does, and the command exits with the call's status.
func TestMain(m *testing.M) {
	if len(os.Args) > 2 && os.Args[1] == internalCmd.Name() && os.Args[2] == dockerRunCmd.Name() {
		rootCmd.SetArgs(os.Args[1:])
		_ = rootCmd.Execute()
		os.Exit(2)
	}
	if os.Getenv(watchdogChild) != "" {
		fmt.Fprintln(os.Stderr, "the test binary was run as the watchdog, and the dispatch did not take it")
		os.Exit(99)
	}
	home, err := os.MkdirTemp("", "cyfr-cmd-test-home-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Setenv("HOME", home)
	os.Setenv("USERPROFILE", home)
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}
