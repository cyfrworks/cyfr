// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// standInApp makes the installed CYFR app a stand-in at a path of its own
// (runStandIn, as CYFR) that records how it was started, and answers the
// record's file; display is whether this machine has a display.
func standInApp(t *testing.T, display bool) string {
	t.Helper()
	app := filepath.Join(t.TempDir(), "CYFR")
	standInLink(t, app)
	record := filepath.Join(t.TempDir(), "started")
	t.Setenv(fakeRecord, record)
	was, wasDisplay := installedApp, hasDisplay
	installedApp = func() string { return app }
	hasDisplay = func() bool { return display }
	t.Cleanup(func() { installedApp, hasDisplay = was, wasDisplay })
	return record
}

// cyfr setup starts the installed app with the working directory as the
// folder it suggests, says so, and returns without waiting for it.
func TestSetupOpensTheAppWithTheWorkingDirectory(t *testing.T) {
	record := standInApp(t, true)
	dir := t.TempDir()
	t.Chdir(dir)
	out, err := runCommand(t, t.Context(), "setup")
	if err != nil {
		t.Fatalf("cyfr setup answered %v\n%s", err, out)
	}
	if want := "Opened the CYFR app, with " + dir + " to set CYFR up in under Or set up CYFR on this computer. An app that was open already is shown as it was.\n"; out != want {
		t.Errorf("cyfr setup printed %q, want %q", out, want)
	}
	var started []byte
	for closes := time.Now().Add(10 * time.Second); ; {
		if started, err = os.ReadFile(record); err == nil && strings.HasSuffix(string(started), "\n") {
			break
		}
		if time.Now().After(closes) {
			t.Fatalf("the app was not started within 10 s (%v)", err)
		}
		time.Sleep(20 * time.Millisecond) // sleep-ok: a bounded wait for a program this test does not hold to write its record
	}
	if got, want := strings.Fields(string(started)), []string{"--setup-project=" + dir}; len(got) != 2 || filepath.Base(got[0]) != "CYFR" || got[1] != want[0] {
		t.Errorf("the app was started as %q, want CYFR %s", started, want[0])
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("cyfr setup wrote %d entries in the working directory, want none", len(entries))
	}
}

// Without the app installed, or without a display, cyfr setup refuses and
// starts nothing.
func TestSetupRefusesWithoutTheAppOrADisplay(t *testing.T) {
	for _, c := range []struct {
		name    string
		app     bool
		display bool
		want    string
	}{
		{"no app", false, true, "cyfr setup opens the CYFR app, which is not installed here. Run cyfr init at a terminal."},
		{"no app, no display", false, false, "cyfr setup opens the CYFR app, which is not installed here. Run cyfr init at a terminal."},
		{"no display", true, false, "This machine has no display for the CYFR app. Run cyfr init here instead."},
	} {
		t.Run(c.name, func(t *testing.T) {
			record := standInApp(t, c.display)
			if !c.app {
				missing := filepath.Join(t.TempDir(), "CYFR")
				installedApp = func() string { return missing }
			}
			t.Chdir(t.TempDir())
			out, err := runCommand(t, t.Context(), "setup")
			if err == nil || err.Error() != c.want {
				t.Fatalf("cyfr setup answered %v (%q), want %q", err, out, c.want)
			}
			if _, err := os.Stat(record); !os.IsNotExist(err) {
				t.Errorf("cyfr setup started the app (%v)", err)
			}
		})
	}
}

// The installed app is where each system's installer puts it.
func TestInstalledAppIsTheInstallersPath(t *testing.T) {
	t.Setenv("LOCALAPPDATA", `C:\Users\ada\AppData\Local`)
	got := installedApp()
	want := map[string]string{
		"darwin":  "/Applications/CYFR.app/Contents/MacOS/CYFR",
		"windows": filepath.Join(`C:\Users\ada\AppData\Local`, "Programs", "cyfr-desktop", "CYFR.exe"),
	}[runtime.GOOS]
	if want == "" {
		want = "/opt/cyfr/CYFR"
	}
	if got != want {
		t.Errorf("the installed app is %q, want %q", got, want)
	}
}
