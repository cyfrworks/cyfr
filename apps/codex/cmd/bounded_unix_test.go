// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// A run its bound ends is ended whole before runWithin answers, a child
// that ignores SIGTERM among them, which never finishes its work after the
// answer; the answer is errOverran, never the run's own status. A run
// within its bound answers its own, and what it left running in its group
// is ended before the answer too.
func TestRunWithinEndsTheWholeTreeAtItsBound(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "finished")
	c := exec.Command("/bin/sh", "-c", "(trap '' TERM; /bin/sleep 2; printf finished > \"$1\") & wait", "probe", marker)
	start := time.Now()
	err := runWithin(200*time.Millisecond, c)
	if !errors.Is(err, errOverran) || err.Error() != "it did not finish within 200ms" {
		t.Fatalf("the bounded run answered %v", err)
	}
	if took := time.Since(start); took > 2*boundGrace {
		t.Errorf("the bounded run took %v", took)
	}
	time.Sleep(3 * time.Second) // sleep-ok: longer than the child's own work, which a bound that ended it never finishes
	if _, err := os.Stat(marker); err == nil {
		t.Error("a child finished its work after the bound answered")
	}

	left := filepath.Join(t.TempDir(), "left")
	var exit *exec.ExitError
	if err := runWithin(time.Minute, exec.Command("/bin/sh", "-c", "(/bin/sleep 2; printf left > \"$1\") & exit 7", "probe", left)); !errors.As(err, &exit) || exit.ExitCode() != 7 {
		t.Errorf("a run within its bound answered %v, want its status 7", err)
	}
	time.Sleep(3 * time.Second) // sleep-ok: longer than the work the run left behind, which its end ended
	if _, err := os.Stat(left); err == nil {
		t.Error("what a run left running in its group finished after it answered")
	}
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
