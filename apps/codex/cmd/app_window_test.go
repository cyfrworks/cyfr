// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/desktop"
)

// The app's Update CYFR page offers the newest release as cyfr update
// would go to it, by the app's own cyfr in the device's folder, which
// holds no CYFR, so the app's update calls no Docker: once the road's
// elevation, all the transaction asks before the app closes, is given,
// and given back. Its yes names the release shown.
func TestThePageOffersTheNewestReleaseTheRunGoesTo(t *testing.T) {
	a := newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
	a.machine.noTerminal = true
	device := t.TempDir()
	p := windowOffer(context.Background(), device, "/home/ada/cyfr")
	if p.App != "0.9.0" || p.Target != "0.10.0" || p.Step != "app" || p.Terminal != "" || p.Dir != device ||
		!reflect.DeepEqual(p.Args, []string{"update", "--version", "0.10.0"}) ||
		!strings.HasPrefix(p.Header, "Updating the CYFR app to release 0.10.0, as asked in the app at ") {
		t.Fatalf("offered %+v", p)
	}
	if !slices.Contains(p.Says, "Your CYFR in /home/ada/cyfr keeps running its release until you update it too: this page offers that once the app has opened again.") {
		t.Fatalf("the page does not say what becomes of this computer's own CYFR: %q", p.Says)
	}
	if !reflect.DeepEqual(a.log, []string{"elevate cyfr update --version 0.10.0"}) || a.road.released != 1 {
		t.Fatalf("the road was asked %q, its elevation given back %d times", a.log, a.road.released)
	}
	if ran, _ := os.ReadFile(a.ran); len(ran) != 0 {
		t.Fatalf("the offer ran %s", ran)
	}
}

// Where the transaction would refuse before the app closes, the page says
// so and offers no yes, but the line to run in a terminal instead, with
// the release; where this cyfr has a terminal, sudo's would ask on it, so
// nothing is asked and the run refuses instead.
func TestThePageSaysWhatTheRunWouldRefuseAndTheLineToRunInstead(t *testing.T) {
	a := newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
	a.machine.noTerminal = true
	a.road.elevateErr = errors.New("sudo needs your password and there is no terminal for it to ask at, so nothing was changed. Run `cyfr update --version 0.10.0` at a terminal")
	p := windowOffer(context.Background(), t.TempDir(), "")
	terminal := "cyfr update --version 0.10.0"
	if runtime.GOOS == "darwin" {
		terminal = "sudo " + terminal
	}
	if p.Step != "" || p.Target != "0.10.0" || p.Terminal != terminal || p.Says[len(p.Says)-1] != a.road.elevateErr.Error() || p.Args != nil {
		t.Fatalf("offered %+v", p)
	}

	b := newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
	b.road.elevateErr = errors.New("asked on a terminal")
	if p := windowOffer(context.Background(), t.TempDir(), ""); p.Step != "app" || len(b.log) != 0 {
		t.Fatalf("with a terminal the road was asked %q, offering %+v", b.log, p)
	}
}

// The newest release already, one newer than the newest, none published,
// a newest that cannot be read and a development build: each in its
// sentence, no yes, and nothing asked of the road.
func TestThePageSaysWhyThereIsNothingToUpdate(t *testing.T) {
	for name, c := range map[string]struct {
		current, latest string
		latestErr       error
		says            string
	}{
		"newest":      {"0.10.0", "0.10.0", nil, "This CYFR app is release 0.10.0, the newest."},
		"past newest": {"0.11.0-alpha.1", "0.10.0", nil, "This CYFR app is release 0.11.0-alpha.1, newer than the newest release, 0.10.0, so it stays."},
		"unreadable":  {"0.9.0", "", errors.New("dial tcp: no route to host"), "The newest release of CYFR could not be read (dial tcp: no route to host). Nothing was changed; try again later."},
		"development": {"dev", "0.10.0", nil, "This CYFR app is a development build (dev), which is not updated."},
	} {
		t.Run(name, func(t *testing.T) {
			a := newAppScenario(t, c.current, c.latest, c.current)
			a.machine.noTerminal = true
			a.latestErr = c.latestErr
			p := windowOffer(context.Background(), t.TempDir(), "")
			if p.Step != "" || p.Terminal != "" || !reflect.DeepEqual(p.Says, []string{c.says}) || len(a.log) != 0 {
				t.Fatalf("offered %+v, the road asked %q", p, a.log)
			}
		})
	}
}

// A Homebrew install's page offers the release its tap names, by brew.
func TestTheCaskInstallsPageOffersTheUpdateByBrew(t *testing.T) {
	a := newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
	a.machine.noTerminal = true
	caskInstalled = func() bool { return true }
	p := windowOffer(context.Background(), t.TempDir(), "")
	if p.Step != "app" || !slices.Contains(p.Says, "Homebrew replaces it, as it installed it.") || len(a.log) != 0 {
		t.Fatalf("offered %+v, the system's road asked %q", p, a.log)
	}
}

// standInSelf makes the app's own cyfr a script that records each run's
// folder and arguments in log and answers as script says.
func standInSelf(t *testing.T, script string) (log string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the stand-in cyfr is a shell script")
	}
	dir := t.TempDir()
	log = filepath.Join(dir, "log")
	self := filepath.Join(dir, "cyfr")
	if err := os.WriteFile(self, []byte("#!/bin/sh\necho \"$PWD|$*\" >> '"+log+"'\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	selfExecutable = func() (string, error) { return self, nil }
	return log
}

// With this app on the newest release and this computer's own CYFR open,
// the page offers that CYFR's change, as this release's own cyfr update
// shows it in its folder (--offer); its yes makes it there only as shown
// (--confirmed with the change's digest). A CYFR on its release, and one
// whose check is refused, are said, with no yes.
func TestThePageOffersThisComputersOwnCYFRsChangeAsThisReleaseShowsIt(t *testing.T) {
	const change = "\nThis CYFR is on release 0.9.0; this cyfr is release 0.10.0.\nUpdating it stops the stack, snapshots it into backups/, switches these images to release 0.10.0 and starts it:\n  cyfr: a → b\n"
	a := newAppScenario(t, "0.10.0", "0.10.0", "0.10.0")
	a.machine.noTerminal = true
	project := t.TempDir()
	log := standInSelf(t, "echo 'Verifying the manifest of release 0.10.0...'\nprintf '%s\\n' '{\"change\":\"\\nThis CYFR is on release 0.9.0; this cyfr is release 0.10.0.\\nUpdating it stops the stack, snapshots it into backups/, switches these images to release 0.10.0 and starts it:\\n  cyfr: a → b\\n\"}'\n")
	p := windowOffer(context.Background(), t.TempDir(), project)
	if p.Step != "stack" || p.Target != "0.10.0" || p.Dir != project ||
		!reflect.DeepEqual(p.Args, []string{"update", "--version", "0.10.0", "--confirmed", changeDigest(change)}) ||
		!strings.HasPrefix(p.Header, "Updating your CYFR in "+project+" to release 0.10.0, as asked in the app at ") {
		t.Fatalf("offered %+v", p)
	}
	for _, line := range []string{"This CYFR app is release 0.10.0, the newest.",
		"Your CYFR in " + project + " still runs the release it ran before this app was updated, as it does after a cyfr update answered no. Updating it to release 0.10.0:",
		"This CYFR is on release 0.9.0; this cyfr is release 0.10.0.", "cyfr: a → b"} {
		if !slices.Contains(p.Says, line) {
			t.Errorf("the page does not say %q: %q", line, p.Says)
		}
	}
	if ran := read(t, log); ran != project+"|update --version 0.10.0 --offer\n" {
		t.Fatalf("the app's cyfr ran %q", ran)
	}

	standInSelf(t, "printf '%s\\n' '{\"current\":\"This CYFR is on release 0.10.0 already, so there is nothing to update.\"}'\n")
	if p := windowOffer(context.Background(), t.TempDir(), project); p.Step != "" ||
		!slices.Contains(p.Says, "Your CYFR in "+project+": This CYFR is on release 0.10.0 already, so there is nothing to update.") {
		t.Fatalf("a CYFR on its release is offered %+v", p)
	}
	standInSelf(t, "echo 'Error: cyfr update needs docker on PATH to update the stack; nothing was changed' >&2\nexit 1\n")
	if p := windowOffer(context.Background(), t.TempDir(), project); p.Step != "" ||
		!slices.Contains(p.Says, "Your CYFR in "+project+" could not be checked for its update: cyfr update needs docker on PATH to update the stack; nothing was changed") {
		t.Fatalf("a refused check is offered %+v", p)
	}
}

// The run a yes starts is the app's own cyfr with the plan's arguments in
// its folder, its output the record, in a session of its own, so the
// app's end does not end it.
func TestTheRunStartsApartFromTheAppItsOutputTheRecord(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the session is read from /proc")
	}
	newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
	standInSelf(t, "read -r _ _ _ _ _ sid _ < /proc/$$/stat\necho \"session $sid pid $$\"\n")
	dir := t.TempDir()
	record, err := os.CreateTemp(t.TempDir(), "update.log")
	if err != nil {
		t.Fatal(err)
	}
	wait, err := beginWindowUpdate(desktop.UpdatePlan{Dir: dir, Args: []string{"update", "--version", "0.10.0"}}, record)
	record.Close()
	if err != nil || wait() != nil {
		t.Fatalf("the run answered %v", err)
	}
	said := read(t, record.Name())
	if f := strings.Fields(said); len(f) != 4 || f[0] != "session" || f[2] != "pid" || f[1] != f[3] {
		t.Fatalf("the run said %q: not the leader of a session of its own", said)
	}
	if ran := read(t, filepath.Join(filepath.Dir(must(selfExecutable())), "log")); ran != dir+"|update --version 0.10.0\n" {
		t.Fatalf("the app's cyfr ran %q", ran)
	}
}

// An update runs while it holds cyfr update's lock.
func TestAnUpdateRunsWhileItHoldsItsLock(t *testing.T) {
	saved := updateLockPath
	t.Cleanup(func() { updateLockPath = saved })
	updateLockPath = filepath.Join(t.TempDir(), "update.lock")
	if windowUpdateRuns("") {
		t.Fatal("an update runs with no lock")
	}
	unlock, err := lockUpdate()
	if err != nil {
		t.Fatal(err)
	}
	if !windowUpdateRuns("") {
		t.Fatal("an update holding its lock does not run")
	}
	unlock()
	if windowUpdateRuns("") {
		t.Fatal("an update runs once its lock is let go")
	}
}

func must(path string, err error) string {
	if err != nil {
		panic(err)
	}
	return path
}
