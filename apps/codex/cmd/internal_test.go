// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/reach"
)

// The watchdog the engine re-execs is the binary's own hidden command: run
// as `internal docker-run`, the binary (this test binary, through
// TestMain) exits with the status reach.WatchdogMain answers for the same
// arguments, its arguments passed through unparsed.
func TestInternalDockerRunIsTheWatchdog(t *testing.T) {
	for _, args := range [][]string{nil} {
		want := reach.WatchdogMain(args, strings.NewReader(""), io.Discard, io.Discard)
		cmd := exec.Command(os.Args[0], append([]string{"internal", "docker-run"}, args...)...)
		cmd.Env = append(os.Environ(), watchdogChild+"=1")
		err := cmd.Run()
		got := 0
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			got = exit.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Errorf("`internal docker-run %s` exits %d, WatchdogMain answers %d", strings.Join(args, " "), got, want)
		}
	}
}
