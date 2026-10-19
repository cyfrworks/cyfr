// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// asCyfr marks a run of this test binary that a test started as cyfr
// itself: it runs main, and exits as main exits.
const asCyfr = "CYFR_MAIN_TEST_AS_CYFR"

func TestMain(m *testing.M) {
	if os.Getenv(asCyfr) != "" {
		main()
	}
	os.Exit(m.Run())
}

// The cyfr process exits with the status cmd.Run answers for its command
// line: 0 for a command that succeeds, and a command's failure's own
// status (cmd.ExitStatus) for one that fails, 1 for a usage refusal.
func TestMainExitsWithTheCommandsStatus(t *testing.T) {
	for _, c := range []struct {
		args   []string
		status int
		stderr string
	}{
		{[]string{"--version"}, 0, ""},
		{[]string{"reach", "tls"}, 1, `Error: cyfr reach takes local, tailnet or public; "tls" is none of them`},
	} {
		process := exec.Command(os.Args[0], c.args...)
		process.Dir = t.TempDir()
		process.Env = append(os.Environ(), asCyfr+"=1", "HOME="+t.TempDir(), "USERPROFILE="+t.TempDir())
		var stderr strings.Builder
		process.Stderr = &stderr
		err := process.Run()
		status := 0
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			status = exit.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		if status != c.status || !strings.Contains(stderr.String(), c.stderr) {
			t.Errorf("cyfr %s exited %d, printing %q; want %d and %q", strings.Join(c.args, " "), status, stderr.String(), c.status, c.stderr)
		}
	}
}
