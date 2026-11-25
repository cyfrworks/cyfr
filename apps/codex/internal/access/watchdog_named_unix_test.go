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

// fakeDockerLog makes a docker that logs each of its calls and answers a
// run whose second argument names how it ends: --slow sleeps, --fail
// exits 1; it answers the binary and its log.
func fakeDockerLog(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	docker := filepath.Join(dir, "docker")
	script := "#!/bin/sh\necho \"$*\" >> " + log + "\ncase \"$1 $2\" in\n\"run --slow\") sleep 30;;\n\"run --fail\") exit 1;;\nesac\n"
	if err := os.WriteFile(docker, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return docker, log
}

func loggedCalls(t *testing.T, log string) []string {
	t.Helper()
	data, _ := os.ReadFile(log)
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

// The watchdog removes a call's container only when the call asks for it
// (--remove, Call.RemoveOnEnd) and does not end with status 0: killed at
// its deadline, as when the cyfr reading it is gone, or failed. A call
// that ends with status 0 leaves its container to its own --rm, and one
// that asks for nothing, a detached run named for the tailnet join among
// them, is never removed: its container is meant to outlive the call.
func TestWatchdogRemovesOnlyTheContainerItsCallAsksFor(t *testing.T) {
	docker, log := fakeDockerLog(t)
	for _, c := range []struct {
		name   string
		remove string
		args   []string
		want   []string
		code   int
	}{
		{"asked for, killed at its deadline", "reader-1", []string{"run", "--slow", "--rm", "--name", "reader-1", "image"}, []string{"run --slow --rm --name reader-1 image", "rm --force reader-1"}, watchdogDeadline},
		{"asked for, failed", "reader-2", []string{"run", "--fail", "--rm", "--name", "reader-2", "image"}, []string{"run --fail --rm --name reader-2 image", "rm --force reader-2"}, 1},
		{"asked for, ended with status 0", "reader-3", []string{"run", "--rm", "--name", "reader-3", "image"}, []string{"run --rm --name reader-3 image"}, 0},
		{"a detached run named, asking for nothing", "", []string{"run", "-d", "--rm", "--name", "cyfr-tailnet-join-0123", "image"}, []string{"run -d --rm --name cyfr-tailnet-join-0123 image"}, 0},
		{"a detached run named, asking for nothing, failed", "", []string{"run", "--fail", "-d", "--name", "cyfr-tailnet-join-4567", "image"}, []string{"run --fail -d --name cyfr-tailnet-join-4567 image"}, 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			os.Remove(log)
			args := []string{"--deadline", "1m"}
			if strings.Contains(c.name, "deadline") {
				args = []string{"--deadline", "300ms"}
			}
			if c.remove != "" {
				args = append(args, "--remove", c.remove)
			}
			var out strings.Builder
			code := WatchdogMain(append(append(args, "--", docker), c.args...), nil, &out, &out)
			if code != c.code {
				t.Errorf("the watchdog exited %d, want %d: %s", code, c.code, out.String())
			}
			if got := loggedCalls(t, log); strings.Join(got, "|") != strings.Join(c.want, "|") {
				t.Errorf("docker ran %q, want %q", got, c.want)
			}
		})
	}
}

// The engine passes --remove to the watchdog for a call that asks for it
// and for no other: a detached join's container outlives its call.
func TestTheEngineAsksTheWatchdogToRemoveOnlyWhatACallAsksFor(t *testing.T) {
	h, _ := binaryHome(t, false)
	argv := filepath.Join(t.TempDir(), "argv")
	h.e.docker.(*systemDocker).watchdog = []string{"sh", "-c", `echo "$*" >> "$0"`, argv}
	unlock, err := h.e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if _, err := h.e.Docker().Run(bg, Call{Args: []string{"run", "-d", "--rm", "--name", "join"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.e.Docker().Run(bg, Call{Args: []string{"run", "--rm", "--name", "reader"}, RemoveOnEnd: "reader"}); err != nil {
		t.Fatal(err)
	}
	got := loggedCalls(t, argv)
	if len(got) != 2 || strings.Contains(got[0], "--remove") || !strings.Contains(got[1], "--remove reader --") {
		t.Errorf("the watchdog was started with\n%s", strings.Join(got, "\n"))
	}
}

// With no watchdog (no lock held), the engine itself removes a call's
// container when the call asks for it and does not end with status 0,
// and removes none otherwise.
func TestTheEngineRemovesACallsContainerWithoutAWatchdog(t *testing.T) {
	h, _ := binaryHome(t, false)
	docker, log := fakeDockerLog(t)
	h.e.docker.(*systemDocker).binary = docker
	h.e.Docker().Run(bg, Call{Args: []string{"run", "--fail", "--name", "reader"}, RemoveOnEnd: "reader"})
	h.e.Docker().Run(bg, Call{Args: []string{"run", "--rm", "--name", "clean"}, RemoveOnEnd: "clean"})
	h.e.Docker().Run(bg, Call{Args: []string{"run", "--fail", "-d", "--name", "join"}})
	want := []string{"run --fail --name reader", "rm --force reader", "run --rm --name clean", "run --fail -d --name join"}
	if got := loggedCalls(t, log); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("docker ran %q, want %q", got, want)
	}
}
