// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
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
	installedApp = func() (string, error) { return app, nil }
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
	if want := "Opening the CYFR app for " + dir + ".\n"; out != want {
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
				installedApp = func() (string, error) { return missing, nil }
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

// setupFolders is tests/fixtures/setup-folders.json: per system, the
// folder forms the app takes and those it refuses.
type setupFolders struct {
	Systems map[string]struct {
		Taken   []string `json:"taken"`
		Refused []string `json:"refused"`
	} `json:"systems"`
}

// The folders the app takes are those this system calls absolute, and the
// ones it refuses are relative or hold a . or .. after their volume, which
// filepath.Abs never answers: the launcher hands over only forms the app
// takes (the app's policy test reads the same file).
func TestSetupFolderFormsAreTheSystems(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "setup-folders.json"))
	if err != nil {
		t.Fatal(err)
	}
	var all setupFolders
	if err := json.Unmarshal(raw, &all); err != nil {
		t.Fatal(err)
	}
	forms, ok := all.Systems[runtime.GOOS]
	if !ok || len(forms.Taken) == 0 || len(forms.Refused) == 0 {
		t.Fatalf("setup-folders.json has no forms for %s", runtime.GOOS)
	}
	unresolved := func(dir string) bool {
		rest := dir[len(filepath.VolumeName(dir)):]
		return !slices.ContainsFunc(strings.FieldsFunc(rest, func(r rune) bool { return os.IsPathSeparator(uint8(r)) }),
			func(s string) bool { return s == "." || s == ".." })
	}
	for _, dir := range forms.Taken {
		if !filepath.IsAbs(dir) || !unresolved(dir) {
			t.Errorf("%q is taken, but this system does not call it absolute with nothing to resolve", dir)
		}
	}
	for _, dir := range forms.Refused {
		if filepath.IsAbs(dir) && unresolved(dir) {
			t.Errorf("%q is refused, but this system calls it absolute with nothing to resolve", dir)
		}
	}
	if here, err := filepath.Abs("."); err != nil || !filepath.IsAbs(here) || !unresolved(here) {
		t.Errorf("the working directory is %q (%v), not a form the app takes", here, err)
	}
}
