// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package access

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A `docker run --name` call's container is ended and removed once the
// call ends, however it ended: at its deadline, as when the cyfr reading
// it is gone and the call runs on to its end, and when docker exits by
// itself; a call that names no container removes none.
func TestWatchdogRemovesTheContainerItsCallNamed(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	docker := filepath.Join(dir, "docker")
	script := "#!/bin/sh\necho \"$*\" >> " + log + "\nif [ \"$1\" = run ] && [ \"$2\" = --slow ]; then sleep 30; fi\n"
	if err := os.WriteFile(docker, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name     string
		deadline string
		args     []string
		want     []string
		code     int
	}{
		{"killed at its deadline", "300ms", []string{"run", "--slow", "--name", "reader-1", "image"}, []string{"run --slow --name reader-1 image", "rm --force reader-1"}, watchdogDeadline},
		{"ended by itself", "1m", []string{"run", "--rm", "--name", "reader-2", "image"}, []string{"run --rm --name reader-2 image", "rm --force reader-2"}, 0},
		{"naming none", "1m", []string{"run", "--rm", "image"}, []string{"run --rm image"}, 0},
		{"not a run", "1m", []string{"ps", "--name", "x"}, []string{"ps --name x"}, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			os.Remove(log)
			var out strings.Builder
			code := WatchdogMain(append([]string{"--deadline", c.deadline, "--", docker}, c.args...), nil, &out, &out)
			if code != c.code {
				t.Errorf("the watchdog exited %d, want %d: %s", code, c.code, out.String())
			}
			data, _ := os.ReadFile(log)
			if got := strings.Split(strings.TrimSpace(string(data)), "\n"); strings.Join(got, "|") != strings.Join(c.want, "|") {
				t.Errorf("docker ran %q, want %q", got, c.want)
			}
		})
	}
}
