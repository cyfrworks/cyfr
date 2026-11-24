// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A run its bound ends is ended whole, what it started with it, and
// answers errOverran, never its own status; a run within its bound answers
// its own.
func TestRunWithinEndsTheWholeTreeAtItsBound(t *testing.T) {
	pids := filepath.Join(t.TempDir(), "pids")
	c := exec.Command("/bin/sh", "-c", "/bin/sleep 60 & echo $! > '"+pids+"'; wait")
	start := time.Now()
	err := runWithin(time.Second, c)
	if !errors.Is(err, errOverran) || err.Error() != "it did not finish within 1s" {
		t.Fatalf("the bounded run answered %v", err)
	}
	if took := time.Since(start); took > boundGrace {
		t.Errorf("the bounded run took %v", took)
	}
	raw, _ := os.ReadFile(pids)
	pid, perr := strconv.Atoi(strings.TrimSpace(string(raw)))
	if perr != nil {
		t.Fatalf("the child's pid %q: %v", raw, perr)
	}
	// The child is gone, or a zombie its parent's end left to init: it
	// takes no signal-able life either way within the grace.
	deadline := time.Now().Add(boundGrace)
	for syscall.Kill(pid, 0) == nil && !zombie(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("the bound left the child %d running", pid)
		}
		time.Sleep(50 * time.Millisecond) // sleep-ok: a bounded wait for the kernel to reap a killed child
	}
	var exit *exec.ExitError
	if err := runWithin(time.Minute, exec.Command("/bin/sh", "-c", "exit 7")); !errors.As(err, &exit) || exit.ExitCode() != 7 {
		t.Errorf("a run within its bound answered %v, want its status 7", err)
	}
}

// zombie is whether process pid has ended and waits to be reaped, where
// /proc says so (Linux); elsewhere none is known as one.
func zombie(pid int) bool {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return false
	}
	fields := strings.Fields(string(raw[strings.LastIndexByte(string(raw), ')')+1:]))
	return len(fields) > 0 && fields[0] == "Z"
}

// The app asked to quit: asked again until it says none runs, answering
// that one ran; one that says none at once did not run; any other status,
// and one still running at the bound, is not closed; one that hangs is
// ended at its own bound.
func TestAskAppToQuitAsksUntilNoneRuns(t *testing.T) {
	savedApp, savedQuit, savedAsk := installedApp, appQuitWithin, appAskWithin
	t.Cleanup(func() { installedApp, appQuitWithin, appAskWithin = savedApp, savedQuit, savedAsk })
	appQuitWithin, appAskWithin = 2*time.Second, time.Second
	for _, c := range []struct {
		name, script string
		ran          bool
		says         string
	}{
		{"none runs", "exit 0", false, ""},
		{"one runs, then ends", "n=$(cat \"$0.n\" 2>/dev/null || echo 0); echo $((n+1)) > \"$0.n\"; [ \"$1\" = --quit ] || exit 9; [ $n -ge 2 ] && exit 0; exit 3", true, ""},
		{"another status", "exit 5", false, "the CYFR app asked to quit ended with status 5"},
		{"still running at the bound", "exit 3", true, "it was still running 2s after it was asked to quit"},
		{"a start that hangs", "exec /bin/sleep 60", false, "the CYFR app could not be asked to quit: it did not finish within 1s"},
	} {
		t.Run(c.name, func(t *testing.T) {
			app := filepath.Join(t.TempDir(), "CYFR")
			if err := os.WriteFile(app, []byte("#!/bin/sh\n"+c.script+"\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			installedApp = func() (string, error) { return app, nil }
			ran, err := askAppToQuit()
			if ran != c.ran || (c.says == "") != (err == nil) || (err != nil && err.Error() != c.says) {
				t.Errorf("askAppToQuit = %v, %v; want %v, %q", ran, err, c.ran, c.says)
			}
		})
	}
}
