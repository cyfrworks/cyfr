// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"net"
	"testing"
)

// A command that reaches no CYFR names the address it tried and how to
// name another, rather than a transport error: nothing listens at a port
// this test held and let go.
func TestUnreachableCYFRIsNamedByItsAddress(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := "http://" + l.Addr().String()
	l.Close()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CYFR_TOKEN", "")
	t.Cleanup(func() {
		flagJSON, flagURL, flagContext, flagNoInteractive, flagToken = false, "", "", false, ""
		rootCmd.SetArgs(nil)
	})
	rootCmd.SetArgs([]string{"whoami", "--url", address})
	err = Execute(t.Context())
	want := "CYFR could not be reached at " + address + ". Check that it is running there, or name the CYFR this command line uses: cyfr context add <name> <address> (or --url for one command)."
	if err == nil || err.Error() != want {
		t.Errorf("cyfr whoami at a closed port answered %v, want %q", err, want)
	}
}
