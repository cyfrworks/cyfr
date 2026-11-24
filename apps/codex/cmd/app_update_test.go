// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/release"
)

// roadStandIn is the installed app's road, its closing and its reopening,
// each step recorded in log as it is taken: fetch, elevate, quit, replace,
// reopen. Each step answers its error; replace leaves the app answering
// becomes (the stand-in machine's app), and box makes the road one that
// stops and starts the box's screen.
type roadStandIn struct {
	s                                *appScenario
	fetchErr, elevateErr, replaceErr error
	quitErr                          error
	ran                              bool
	becomes                          string
	box                              bool
	released                         int
	interruptAfterFetch              bool
}

// appScenario is programScenario on a machine with the CYFR app installed
// at release app, its road roadStandIn, the folder holding a compose file
// whose stack update is recorded (manifests) and never reached by a
// refusal, and a docker on PATH (on Unix) that records any call.
type appScenario struct {
	*programScenario
	road      *roadStandIn
	log       []string
	manifests []string
	docker    string
	cancel    context.CancelFunc
	ctx       context.Context
}

// standInRoad is roadStandIn as an appRoad.
type standInRoad struct{ r *roadStandIn }

func (a standInRoad) fetch(_ context.Context, _ io.Writer, _, target string) (*staged, error) {
	r := a.r
	r.s.log = append(r.s.log, "fetch "+target)
	if r.interruptAfterFetch {
		r.s.cancel()
	}
	if r.fetchErr != nil {
		return nil, r.fetchErr
	}
	return &staged{file: "installer " + target, sum: "sum"}, nil
}

func (a standInRoad) elevate(_ io.Writer, again string) (func(), error) {
	r := a.r
	r.s.log = append(r.s.log, "elevate "+again)
	if r.elevateErr != nil {
		return nil, r.elevateErr
	}
	return func() { r.released++ }, nil
}

func (a standInRoad) replace(_ io.Writer, s *staged, older bool) error {
	r := a.r
	entry := "replace " + s.file
	if older {
		entry += " older"
	}
	r.s.log = append(r.s.log, entry)
	if r.replaceErr != nil {
		return r.replaceErr
	}
	r.s.machine.app = r.becomes
	return nil
}

func (a standInRoad) closesTheBox() ([]string, []string) {
	if !a.r.box {
		return nil, nil
	}
	return []string{"stop the screen"}, []string{"start the screen"}
}

func newAppScenario(t *testing.T, current, latest, app string) *appScenario {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	a := &appScenario{programScenario: newProgramScenario(t, current, latest), ctx: ctx, cancel: cancel}
	a.machine.installed, a.machine.app = []string{appPackage}, app
	a.road = &roadStandIn{s: a, becomes: latest}
	saved, savedQuit, savedReopen, savedCyfr, savedManifest := appRoadHere, quitApp, reopenApp, appCyfr, fetchManifest
	t.Cleanup(func() {
		appRoadHere, quitApp, reopenApp, appCyfr, fetchManifest = saved, savedQuit, savedReopen, savedCyfr, savedManifest
	})
	appRoadHere = func() appRoad { return standInRoad{a.road} }
	quitApp = func() (bool, error) {
		a.log = append(a.log, "quit")
		return a.road.ran, a.road.quitErr
	}
	reopenApp = func() error {
		a.log = append(a.log, "reopen")
		return nil
	}
	// The app's own cyfr is elsewhere, unless a test makes it this one.
	elsewhere := filepath.Join(t.TempDir(), "cyfr")
	appCyfr = func() (string, error) { return elsewhere, nil }
	savedBinary := fetchBinary
	fetchBinary = func(ctx context.Context, v, goos, goarch string) ([]byte, error) {
		a.log = append(a.log, "the program "+v)
		return savedBinary(ctx, v, goos, goarch)
	}
	reached := errors.New("the stack's update began")
	fetchManifest = func(_ context.Context, v string) (*release.Manifest, error) {
		a.manifests = append(a.manifests, v)
		return nil, reached
	}
	if err := os.WriteFile("docker-compose.yml", []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		a.docker = filepath.Join(t.TempDir(), "docker-calls")
		script := "#!/bin/sh\necho \"docker $*\" >> '" + a.docker + "'\n"
		if err := os.WriteFile(filepath.Join(os.Getenv("PATH"), "docker"), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return a
}

// theAppsOwn makes this program the cyfr the installed app carries.
func (a *appScenario) theAppsOwn() {
	self := a.self
	appCyfr = func() (string, error) { return self, nil }
}

func (a *appScenario) run(o updateOptions) (string, error) {
	return a.runContext(a.ctx, o)
}

// untouched fails unless the stack's update was never reached and docker
// never called.
func (a *appScenario) untouched() {
	a.t.Helper()
	if len(a.manifests) != 0 {
		a.t.Errorf("the stack's update was reached, for %v", a.manifests)
	}
	if a.docker != "" {
		if got := read(a.t, a.docker); got != "<absent>" {
			a.t.Errorf("docker was called: %q", got)
		}
	}
	if len(a.handed) != 0 {
		a.t.Errorf("cyfr update handed over: %v", a.handed)
	}
}

// steps fails unless the road's steps were taken in exactly this order.
func (a *appScenario) steps(want ...string) {
	a.t.Helper()
	if !slices.Equal(a.log, want) {
		a.t.Errorf("the update took the steps %q, want %q", a.log, want)
	}
}

// The installed app is updated by its road whichever cyfr runs: from the
// app's own cyfr, the installer verified, then the elevation, then the app
// closed, then replaced, then opened again, and the update handed to the
// app's own cyfr, now the new release's, for the stack in this folder. The
// cyfr inside the app is never rewritten by cyfr update itself.
func TestUpdateBringsTheInstalledAppByItsRoad(t *testing.T) {
	a := newAppScenario(t, "1.0.0", "1.1.0", "1.0.0")
	a.theAppsOwn()
	a.road.ran = true
	out, err := a.run(updateOptions{yes: true})
	if err != nil {
		t.Fatalf("cyfr update answered %v:\n%s", err, out)
	}
	a.steps("fetch 1.1.0", "elevate cyfr update", "quit", "replace installer 1.1.0", "reopen")
	self := resolvedPath(t, a.self)
	if want := []string{self, self, "update", "--continue-as", "1.1.0", "--yes"}; len(a.handed) != 1 || !slices.Equal(a.handed[0], want) {
		t.Errorf("cyfr update handed over %v, want once as %v", a.handed, want)
	}
	if len(a.fetched) != 0 || read(t, a.self) != "old cyfr" {
		t.Errorf("the app's own cyfr was fetched %v or rewritten: %q", a.fetched, read(t, a.self))
	}
	if a.road.released != 1 {
		t.Errorf("the elevation was let go %d times, want once", a.road.released)
	}
	for _, line := range []string{"Updating the CYFR app from 1.0.0 to 1.1.0...", "The CYFR app is release 1.1.0."} {
		if !strings.Contains(out, line) {
			t.Errorf("the update did not say %q:\n%s", line, out)
		}
	}
	if strings.Contains(out, "Updating cyfr from") {
		t.Errorf("the update spoke of the app's own cyfr apart from the app:\n%s", out)
	}
}

// A standalone cyfr first on PATH beside the installed app: both are
// verified before anything changes, the app goes by its road, then the
// standalone cyfr replaces itself, and the person reads one line naming
// both; the app that was not running is not opened.
func TestUpdateBringsTheAppAndAStandaloneCyfr(t *testing.T) {
	a := newAppScenario(t, "1.0.0", "1.1.0", "1.0.0")
	out, err := a.run(updateOptions{})
	if err != nil {
		t.Fatalf("cyfr update answered %v:\n%s", err, out)
	}
	a.steps("the program 1.1.0", "fetch 1.1.0", "elevate cyfr update", "quit", "replace installer 1.1.0")
	a.installed("1.1.0")
	self := resolvedPath(t, a.self)
	if want := "The CYFR app and this cyfr, " + self + ", are release 1.1.0.\n"; !strings.Contains(out, want) {
		t.Errorf("the update did not say %q:\n%s", want, out)
	}
}

// Each refusal leaves a working app at its release and the folder's CYFR
// untouched, with no Docker call and the stack's update never reached:
// one before the close closes nothing, and none takes a later step.
func TestUpdateOfTheAppRefusesAtEachStep(t *testing.T) {
	unverified := errors.New("The CYFR app of release 1.1.0 did not verify (it did not); nothing was changed and CYFR runs as it did")
	for _, c := range []struct {
		name  string
		set   func(a *appScenario)
		steps []string
		says  string
	}{
		{"the installer does not verify", func(a *appScenario) { a.road.fetchErr = unverified },
			[]string{"the program 1.1.0", "fetch 1.1.0"}, "did not verify"},
		{"interrupted before the close", func(a *appScenario) { a.road.interruptAfterFetch = true },
			[]string{"the program 1.1.0", "fetch 1.1.0"}, "interrupted before the CYFR app was closed; nothing was changed"},
		{"the elevation is refused", func(a *appScenario) {
			a.road.elevateErr = errors.New("The password was not accepted, so nothing was changed and CYFR runs as it did")
		}, []string{"the program 1.1.0", "fetch 1.1.0", "elevate cyfr update"}, "The password was not accepted"},
		{"the app does not close", func(a *appScenario) { a.road.quitErr = errors.New("it was still running") },
			[]string{"the program 1.1.0", "fetch 1.1.0", "elevate cyfr update", "quit"}, "The CYFR app could not be closed (it was still running); nothing was replaced"},
		{"the installer fails", func(a *appScenario) {
			a.road.ran, a.road.replaceErr = true, errors.New("apt could not install the CYFR app's package (exit status 100)")
		}, []string{"the program 1.1.0", "fetch 1.1.0", "elevate cyfr update", "quit", "replace installer 1.1.0", "reopen"},
			"apt could not install the CYFR app's package (exit status 100); the CYFR app is release 1.0.0, and your CYFR was not touched"},
		{"another release installed", func(a *appScenario) { a.road.becomes = "1.0.5" },
			[]string{"the program 1.1.0", "fetch 1.1.0", "elevate cyfr update", "quit", "replace installer 1.1.0"},
			"The installer finished, but the CYFR app is release 1.0.5, not 1.1.0; your CYFR was not touched"},
		{"no release answered", func(a *appScenario) { a.road.becomes = "" },
			[]string{"the program 1.1.0", "fetch 1.1.0", "elevate cyfr update", "quit", "replace installer 1.1.0"},
			"The installer finished, but the CYFR app's own cyfr answers no release, not 1.1.0; your CYFR was not touched"},
	} {
		t.Run(c.name, func(t *testing.T) {
			a := newAppScenario(t, "1.0.0", "1.1.0", "1.0.0")
			c.set(a)
			out, err := a.run(updateOptions{yes: true})
			if err == nil || !strings.Contains(err.Error(), c.says) {
				t.Errorf("cyfr update answered %v, want %q:\n%s", err, c.says, out)
			}
			a.steps(c.steps...)
			a.untouched()
			if got := read(t, a.self); got != "old cyfr" {
				t.Errorf("the standalone cyfr holds %q, want the old one", got)
			}
		})
	}
}

// A replacement that fails is never taken for one that succeeded, nor an
// answer that fails for the new release: the update from the app's own
// cyfr stops before the stack as well.
func TestUpdateFromTheAppsOwnCyfrStopsOnAFailedReplacement(t *testing.T) {
	a := newAppScenario(t, "1.0.0", "1.1.0", "1.0.0")
	a.theAppsOwn()
	a.road.replaceErr = errors.New("Windows Installer could not install the CYFR app (exit status 1603)")
	if _, err := a.run(updateOptions{yes: true}); err == nil || !strings.Contains(err.Error(), "exit status 1603") {
		t.Errorf("cyfr update answered %v", err)
	}
	a.untouched()
}

// An app at the release already takes no step of its road: the standalone
// cyfr alone is replaced; and with both at the release the update goes on
// to the stack in this process. An app whose own cyfr answers no release
// is not taken for the release: it is installed again.
func TestUpdateLeavesAnAppAtTheReleaseAlone(t *testing.T) {
	a := newAppScenario(t, "1.0.0", "1.1.0", "1.1.0")
	if out, err := a.run(updateOptions{}); err != nil {
		t.Fatalf("cyfr update answered %v:\n%s", err, out)
	}
	a.steps("the program 1.1.0")
	a.installed("1.1.0")

	a = newAppScenario(t, "1.1.0", "1.1.0", "1.1.0")
	a.theAppsOwn()
	out, err := a.run(updateOptions{})
	if err == nil || !strings.Contains(err.Error(), "the stack's update began") || !strings.Contains(out, "cyfr 1.1.0 is the newest release.") {
		t.Errorf("cyfr update answered %v:\n%s", err, out)
	}
	a.steps()
	if !slices.Equal(a.manifests, []string{"1.1.0"}) || len(a.handed) != 0 {
		t.Errorf("the stack's update was asked %v, handed over %v", a.manifests, a.handed)
	}

	a = newAppScenario(t, "1.1.0", "1.1.0", "")
	a.theAppsOwn()
	if _, err := a.run(updateOptions{}); err == nil || !strings.Contains(err.Error(), "the stack's update began") {
		t.Errorf("cyfr update answered %v", err)
	}
	a.steps("fetch 1.1.0", "elevate cyfr update", "quit", "replace installer 1.1.0")
}

// --version of an older release tells the road it is older, and names
// itself in the command to try again; consecutive pre-releases are a
// newer release.
func TestUpdateOfTheAppToAnExactRelease(t *testing.T) {
	a := newAppScenario(t, "1.1.0", "1.1.0", "1.1.0")
	a.theAppsOwn()
	a.road.becomes = "1.0.0"
	if _, err := a.run(updateOptions{version: "1.0.0"}); err != nil && !strings.Contains(err.Error(), "the stack's update began") {
		t.Fatalf("cyfr update answered %v", err)
	}
	a.steps("fetch 1.0.0", "elevate cyfr update --version 1.0.0", "quit", "replace installer 1.0.0 older")

	a = newAppScenario(t, "0.6.0-alpha.1", "0.6.0-alpha.1", "0.6.0-alpha.1")
	a.theAppsOwn()
	a.road.becomes = "0.6.0-alpha.2"
	if _, err := a.run(updateOptions{version: "0.6.0-alpha.2"}); err != nil {
		t.Fatalf("cyfr update answered %v", err)
	}
	a.steps("fetch 0.6.0-alpha.2", "elevate cyfr update --version 0.6.0-alpha.2", "quit", "replace installer 0.6.0-alpha.2")
}

// On the box's own screen the launcher would start the old app again as
// soon as it ended, so the screen's service is stopped first, as root,
// and started again once the installer is done, whatever it answered; the
// app is not asked to quit. A stop that fails replaces nothing and starts
// the screen again.
func TestUpdateOnTheBoxStopsItsScreenAroundTheInstaller(t *testing.T) {
	for _, c := range []struct {
		name       string
		stopErr    error
		replaceErr error
		applied    [][]string
		steps      []string
	}{
		{"a working installer", nil, nil, nil, []string{"fetch 1.1.0", "elevate cyfr update", "replace installer 1.1.0"}},
		{"a failing installer", nil, errors.New("apt could not install"), nil, []string{"fetch 1.1.0", "elevate cyfr update", "replace installer 1.1.0"}},
		{"a stop that fails", errors.New("refused"), nil, nil, []string{"fetch 1.1.0", "elevate cyfr update"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			a := newAppScenario(t, "1.0.0", "1.1.0", "1.0.0")
			a.theAppsOwn()
			a.road.box, a.road.replaceErr = true, c.replaceErr
			machine.screenService = func() (bool, bool) { return true, true }
			stopped := false
			machine.apply = func(commands []string) error {
				a.machine.applied = append(a.machine.applied, commands)
				if strings.Contains(commands[0], "stop the screen") {
					stopped = true
					return c.stopErr
				}
				return nil
			}
			_, err := a.run(updateOptions{yes: true})
			if (c.stopErr == nil && c.replaceErr == nil) != (err == nil) {
				t.Errorf("cyfr update answered %v", err)
			}
			a.steps(c.steps...)
			if !stopped {
				t.Error("the screen was not stopped")
			}
			var ran []string
			for _, commands := range a.machine.applied {
				if len(commands) != 1 || !strings.HasPrefix(commands[0], "timeout --kill-after=10s 30s 'sh' '-c' ") {
					t.Errorf("a root command was not bounded: %q", commands)
					continue
				}
				ran = append(ran, strings.TrimSuffix(strings.TrimPrefix(commands[0], "timeout --kill-after=10s 30s 'sh' '-c' '"), "'"))
			}
			if want := []string{"stop the screen", "start the screen"}; !slices.Equal(ran, want) {
				t.Errorf("as root the update ran %q, want %q", ran, want)
			}
		})
	}
}

// A standalone cyfr inside an app's bundle wherever it lies, the bundle
// as this system's packaging lays it out, is the app's: cyfr update
// refuses before any download rather than rewrite it, which would break
// the bundle's signature, as it did on macOS and Windows.
func TestUpdateNeverRewritesTheCyfrInsideAnAppsBundle(t *testing.T) {
	bundle, self := appBundleLayout(t, t.TempDir())
	saved := fetchBinary
	t.Cleanup(func() { fetchBinary = saved })
	fetched := 0
	fetchBinary = func(context.Context, string, string, string) ([]byte, error) {
		fetched++
		return []byte("new cyfr"), nil
	}
	_, err := fetchSelf(context.Background(), io.Discard, self, "1.1.0", false)
	want := "This cyfr, " + self + ", is the one inside the CYFR app at " + bundle + ", which cyfr update does not rewrite; nothing was changed."
	if err == nil || !strings.HasPrefix(err.Error(), want) {
		t.Errorf("cyfr update answered %v, want %q", err, want)
	}
	if fetched != 0 || read(t, self) != "the app's cyfr" {
		t.Errorf("the bundle's cyfr was fetched %d times or rewritten: %q", fetched, read(t, self))
	}
}

// writeFile writes body at path, making its folders.
func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}
