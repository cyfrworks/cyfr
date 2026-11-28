// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/version"
)

// The app's Update CYFR page offers the newest release as cyfr update
// would go to it, by the app's own cyfr: once the road's elevation, all
// the transaction asks before the app closes, is given, asking nothing,
// and given back. Its yes names the release shown.
func TestThePageOffersTheNewestReleaseTheRunGoesTo(t *testing.T) {
	a := newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
	device := t.TempDir()
	p := windowOffer(context.Background(), device, "/home/ada/cyfr")
	if p.App != "0.9.0" || p.Target != "0.10.0" || p.Step != "app" || p.Terminal != "" || p.Dir != device ||
		!reflect.DeepEqual(p.Args, []string{"update", "--version", "0.10.0"}) {
		t.Fatalf("offered %+v", p)
	}
	if !slices.Contains(p.Says, "Your CYFR in /home/ada/cyfr keeps running its release until you update it too: this page offers that once the app has opened again.") {
		t.Fatalf("the page does not say what becomes of this computer's own CYFR: %q", p.Says)
	}
	if !reflect.DeepEqual(a.log, []string{"elevate cyfr update --version 0.10.0, asking nothing"}) || a.road.released != 1 {
		t.Fatalf("the road was asked %q, its elevation given back %d times", a.log, a.road.released)
	}
	if ran, _ := os.ReadFile(a.ran); len(ran) != 0 {
		t.Fatalf("the offer ran %s", ran)
	}
}

// Where the transaction would refuse before the app closes, the page says
// so and offers no yes, but the line to run in a terminal instead, with
// the release, whether or not this cyfr has a terminal: the run has none.
func TestThePageSaysWhatTheRunWouldRefuseAndTheLineToRunInstead(t *testing.T) {
	for _, noTerminal := range []bool{true, false} {
		a := newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
		a.machine.noTerminal = noTerminal
		a.road.elevateErr = errors.New("sudo needs your password and there is no terminal for it to ask at, so nothing was changed. Run `cyfr update --version 0.10.0` at a terminal")
		p := windowOffer(context.Background(), t.TempDir(), "")
		terminal := "cyfr update --version 0.10.0"
		if runtime.GOOS == "darwin" {
			terminal = "sudo " + terminal
		}
		if p.Step != "" || p.Target != "0.10.0" || p.Terminal != terminal || p.Says[len(p.Says)-1] != a.road.elevateErr.Error() || p.Args != nil ||
			!reflect.DeepEqual(a.log, []string{"elevate cyfr update --version 0.10.0, asking nothing"}) {
			t.Fatalf("with no terminal %v: offered %+v, the road asked %q", noTerminal, p, a.log)
		}
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
// shows it in its folder (--offer); its yes makes it there only as read
// for that offer (--confirmed with its confirmation). A CYFR on its
// release, an answer with no confirmation and one whose check is refused,
// are said, with no yes.
func TestThePageOffersThisComputersOwnCYFRsChangeAsThisReleaseShowsIt(t *testing.T) {
	newAppScenario(t, "0.10.0", "0.10.0", "0.10.0")
	project := t.TempDir()
	log := standInSelf(t, "echo 'Verifying the manifest of release 0.10.0...'\nprintf '%s\\n' '{\"change\":\"\\nThis CYFR is on release 0.9.0; this cyfr is release 0.10.0.\\nUpdating it stops the stack, snapshots it into backups/, switches these images to release 0.10.0 and starts it:\\n  cyfr: a → b\\n\",\"confirmation\":\"c0ffee\"}'\n")
	p := windowOffer(context.Background(), t.TempDir(), project)
	if p.Step != "stack" || p.Target != "0.10.0" || p.Dir != project ||
		!reflect.DeepEqual(p.Args, []string{"update", "--version", "0.10.0", "--confirmed", "c0ffee"}) {
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
	standInSelf(t, "printf '%s\\n' '{\"change\":\"a change\"}'\n")
	if p := windowOffer(context.Background(), t.TempDir(), project); p.Step != "" ||
		!slices.Contains(p.Says, "Your CYFR in "+project+" could not be checked for its update: its answer could not be read.") {
		t.Fatalf("a change with no confirmation is offered %+v", p)
	}
	standInSelf(t, "echo 'Error: cyfr update needs docker on PATH to update the stack; nothing was changed' >&2\nexit 1\n")
	if p := windowOffer(context.Background(), t.TempDir(), project); p.Step != "" ||
		!slices.Contains(p.Says, "Your CYFR in "+project+" could not be checked for its update: cyfr update needs docker on PATH to update the stack; nothing was changed") {
		t.Fatalf("a refused check is offered %+v", p)
	}
}

// The page for a CYFR on this release whose update would first give the
// devices, as --offer answers it (updater.change), starts at the change's
// own first line, which says there is nothing to switch, then what giving
// them removes, with its yes: it says nothing of an earlier release.
func TestThePageForAnUpdateOnItsReleaseSaysNoEarlierRelease(t *testing.T) {
	newAppScenario(t, "0.10.0", "0.10.0", "0.10.0")
	project := t.TempDir()
	first := "This CYFR is on release 0.10.0 already, so there is nothing to switch; cyfr update writes this machine's devices to .env, starts it and waits for every service of its stack."
	line, _ := json.Marshal(shownChange{Change: first + "\n" + devicesSignInAgain + "\n", Confirmation: "c0ffee", OnRelease: true})
	standInSelf(t, "printf '%s\\n' '"+strings.ReplaceAll(string(line), "'", `'\''`)+"'\n")
	p := windowOffer(context.Background(), t.TempDir(), project)
	if p.Step != "stack" || !reflect.DeepEqual(p.Args, []string{"update", "--version", "0.10.0", "--confirmed", "c0ffee"}) {
		t.Fatalf("offered %+v", p)
	}
	at := slices.Index(p.Says, "Your CYFR in "+project+": "+first)
	if at < 0 || at+1 >= len(p.Says) || p.Says[at+1] != devicesSignInAgain {
		t.Errorf("the page does not start the change at its own first line, then what giving the devices removes: %q", p.Says)
	}
	for _, said := range p.Says {
		if strings.Contains(said, "still runs the release it ran before this app was updated") {
			t.Errorf("the page says the CYFR runs an earlier release, above a change that says it is on release 0.10.0 already: %q", said)
		}
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

// theRecord makes the update's record in a home of the test's own and
// answers it open for writing, as the run Update CYFR starts has it for
// its output.
func theRecord(t *testing.T) *os.File {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	if err := os.MkdirAll(filepath.Dir(windowRecord()), 0o700); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(windowRecord(), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

// The app's own update from Update CYFR, whose output is the record,
// updates the app alone, wherever it runs: in a folder that holds a CYFR
// the program it hands over to calls no Docker and says the app's
// release, and the app is opened again with --updated. The same update
// at a terminal reopens it plainly and goes on to the folder's CYFR.
func TestTheAppsUpdateFromItsWindowUpdatesTheAppAlone(t *testing.T) {
	a := newAppScenario(t, "1.0.0", "1.1.0", "1.0.0")
	a.theAppsOwn()
	a.road.ran = true
	record := theRecord(t)
	if err := runUpdate(a.ctx, record, record, updateOptions{version: "1.1.0"}); err != nil {
		t.Fatalf("cyfr update answered %v:\n%s", err, read(t, record.Name()))
	}
	a.steps("fetch 1.1.0", "elevate cyfr update --version 1.1.0", "quit", "replace installer 1.1.0", "finish", "reopen --updated")

	// The program handed over to, at the new release, with the record its
	// output, in this folder, which holds a compose file.
	a.handed, a.manifests = nil, nil
	version.Version = "1.1.0"
	if err := runUpdate(a.ctx, record, record, updateOptions{continueAs: "1.1.0"}); err != nil {
		t.Fatalf("the handover answered %v", err)
	}
	if said := read(t, record.Name()); !strings.HasSuffix(said, "The CYFR app is release 1.1.0; Update CYFR offers your CYFR's own update, where this computer has one, now that the app has opened again.\n") {
		t.Fatalf("the handover said %q", said)
	}
	a.untouched()

	if _, err := a.run(updateOptions{continueAs: "1.1.0"}); err == nil || len(a.manifests) != 1 {
		t.Fatalf("at a terminal the handover answered %v and reached the stack for %v", err, a.manifests)
	}
	b := newAppScenario(t, "1.0.0", "1.1.0", "1.0.0")
	b.theAppsOwn()
	b.road.ran = true
	if _, err := b.run(updateOptions{version: "1.1.0", yes: true}); err != nil || b.log[len(b.log)-1] != "reopen" {
		t.Fatalf("at a terminal the app was reopened as %q (%v)", b.log, err)
	}
}

// Update CYFR's second yes, the stack's (--confirmed), and its offer
// touch the CYFR in the folder alone, at this program's release: the app
// and the program are never fetched, closed or replaced, a release other
// than this program's is refused with nothing changed, and the confirmed
// change holds cyfr update's lock, refused while another update holds it.
func TestTheStacksYesNeverTouchesTheApp(t *testing.T) {
	a := newAppScenario(t, "0.10.0", "0.11.0", "0.11.0")
	a.theAppsOwn()
	for _, o := range []updateOptions{{version: "0.10.0", confirmed: "c0ffee"}, {version: "0.10.0", offer: true}} {
		a.manifests = nil
		if _, err := a.run(o); err == nil || !reflect.DeepEqual(a.manifests, []string{"0.10.0"}) || len(a.log) != 0 || len(a.fetched) != 0 {
			t.Fatalf("%+v answered %v, the road took %q, the stack's update was asked %v", o, err, a.log, a.manifests)
		}
	}
	a.manifests = nil
	for _, o := range []updateOptions{{version: "0.11.0", confirmed: "c0ffee"}, {confirmed: "c0ffee"}, {version: "0.11.0", offer: true}} {
		if _, err := a.run(o); err == nil || !strings.HasPrefix(err.Error(), "This cyfr is release 0.10.0, not release "+o.version+", which the CYFR app's Update CYFR named; nothing was changed") {
			t.Fatalf("%+v answered %v", o, err)
		}
	}
	a.untouched()
	if len(a.log) != 0 {
		t.Fatalf("the road took %q", a.log)
	}
	unlock, err := lockUpdate()
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if _, err := a.run(updateOptions{version: "0.10.0", confirmed: "c0ffee"}); !errors.Is(err, errUpdateRuns) || len(a.manifests) != 0 {
		t.Fatalf("a confirmed change while another update runs answered %v, the stack's update asked %v", err, a.manifests)
	}
}
