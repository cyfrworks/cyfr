// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"os"
	"testing"
)

// TestMain runs the package's tests under a home of their own: init and
// the commands that sign in save the CLI's config under ~/.cyfr, and no
// test reads or writes the home of the person running it.
func TestMain(m *testing.M) {
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
