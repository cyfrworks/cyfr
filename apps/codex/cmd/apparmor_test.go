// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/scaffold"
)

// The project's cyfr-locus profile in the scenarios, and an older one a
// machine may hold.
const (
	testAppArmor    = "abi <abi/4.0>,\nprofile cyfr-locus flags=(attach_disconnected) {}\n"
	olderAppArmor   = "abi <abi/4.0>,\nprofile cyfr-locus {}\n"
	loadedSentence  = "Locus runs under the AppArmor profile cyfr-locus, and this machine has not loaded the current one.\n"
	parserCommand   = "apparmor_parser -r -W /etc/apparmor.d/cyfr-locus"
	appArmorRemover = "sudo sh -c 'apparmor_parser -R /etc/apparmor.d/cyfr-locus && rm /etc/apparmor.d/cyfr-locus'"
)

// appArmorProject makes the working directory a folder of the test's own
// that holds the project's profile, and answers the folder.
func appArmorProject(t *testing.T) string {
	t.Helper()
	t.Chdir(t.TempDir())
	writeAppArmor(t, testAppArmor)
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// writeAppArmor writes the working directory's profile.
func writeAppArmor(t *testing.T, profile string) {
	t.Helper()
	if err := os.WriteFile(scaffold.AppArmorProfile, []byte(profile), 0o644); err != nil {
		t.Fatal(err)
	}
}

// installCommand is the root command that installs dir's profile.
func installCommand(dir string) string {
	return "install -m 0644 '" + dir + "/cyfr-locus.apparmor' /etc/apparmor.d/cyfr-locus"
}

// notLoaded is the refusal where nothing may ask: the one command that
// loads dir's profile, then again.
func notLoaded(dir, again string) string {
	return "Locus runs under the AppArmor profile cyfr-locus, which this machine has not loaded, so nothing was started. " +
		"Run `sudo sh -c 'install -m 0644 '\\''" + dir + "/cyfr-locus.apparmor'\\'' /etc/apparmor.d/cyfr-locus && " + parserCommand + "'`, then run `" + again + "` again"
}

// appArmorOn makes the machine the tests stand on, its own seams kept, a
// Linux whose kernel enforces AppArmor and whose /etc/apparmor.d holds
// loaded, none when nil, until t ends.
func appArmorOn(t *testing.T, loaded []byte) {
	t.Helper()
	saved := machine
	t.Cleanup(func() { machine = saved })
	machine.system = func() string { return "linux" }
	machine.appArmor = func() bool { return true }
	machine.appArmorProfile = func() ([]byte, error) {
		if loaded == nil {
			return nil, fs.ErrNotExist
		}
		return loaded, nil
	}
}

func ensure(t *testing.T) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := ensureAppArmor(context.Background(), &out, "cyfr up")
	return out.String(), err
}

// Another system, AppArmor off, the project's profile the one the machine
// keeps, and a project that ships none ask nothing and change nothing, at
// a terminal that would answer yes.
func TestAppArmorLeavesAMachineAlone(t *testing.T) {
	for name, set := range map[string]func(s *standIn){
		"another system":       func(s *standIn) { s.system = "darwin" },
		"AppArmor off":         func(s *standIn) { s.appArmor = false },
		"the profile is there": func(s *standIn) { s.profile = []byte(testAppArmor) },
		"no profile shipped": func(*standIn) {
			if err := os.Remove(scaffold.AppArmorProfile); err != nil {
				t.Fatal(err)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			appArmorProject(t)
			s := standInMachine(t)
			s.appArmor = true
			set(s)
			out, err := ensure(t)
			if err != nil || out != "" || s.applied != nil || s.authenticated != 0 {
				t.Fatalf("err %v, applied %q, sudo asked %d times, out %q", err, s.applied, s.authenticated, out)
			}
		})
	}
}

// At a terminal on Ubuntu 26.04, a machine without the project's profile,
// or with another one, is shown the two commands, asked once, and they run
// through one sudo after its own prompt; the login is forgotten after.
func TestAppArmorLoadsThroughOneSudo(t *testing.T) {
	for name, loaded := range map[string][]byte{"none": nil, "an older one": []byte(olderAppArmor)} {
		t.Run(name, func(t *testing.T) {
			dir := appArmorProject(t)
			s := standInMachine(t)
			s.appArmor, s.profile = true, loaded
			out, err := ensure(t)
			if err != nil {
				t.Fatalf("ensure: %v\n%s", err, out)
			}
			want := []string{installCommand(dir), parserCommand}
			if len(s.applied) != 1 || !slices.Equal(s.applied[0], want) {
				t.Fatalf("applied %q, want one sudo of %q", s.applied, want)
			}
			if s.authenticated != 1 || s.forgotten != 1 {
				t.Errorf("sudo asked %d times and forgot %d times, want once each", s.authenticated, s.forgotten)
			}
			shown := loadedSentence + "These commands load it, as root:\n  " + want[0] + "\n  " + want[1] + "\nLoad it? (yes/no) "
			if !strings.HasPrefix(out, shown) || !strings.HasSuffix(out, passwordSentence) {
				t.Errorf("printed:\n%s\nwant it to begin\n%s\nand end with the password sentence", out, shown)
			}
		})
	}
}

// Answered no, and for an account outside the sudo and admin groups, the
// profile is not loaded and sudo is never asked.
func TestAppArmorDeclinedLoadsNothing(t *testing.T) {
	t.Run("answered no", func(t *testing.T) {
		appArmorProject(t)
		s := standInMachine(t)
		s.appArmor = true
		askInput = strings.NewReader("no\n")
		out, err := ensure(t)
		if want := "The AppArmor profile cyfr-locus was not loaded, so nothing was started. Run `cyfr up` again when you want to go on"; err == nil || err.Error() != want {
			t.Fatalf("answered %v, want %q\n%s", err, want, out)
		}
		if s.applied != nil || s.authenticated != 0 {
			t.Errorf("applied %q, sudo asked %d times", s.applied, s.authenticated)
		}
	})
	t.Run("outside the groups", func(t *testing.T) {
		dir := appArmorProject(t)
		s := standInMachine(t)
		s.appArmor, s.administrator = true, nil
		out, err := ensure(t)
		if err == nil || err.Error() != "Nothing was changed. Run `cyfr up` again once they have" {
			t.Fatalf("answered %v\n%s", err, out)
		}
		if !strings.Contains(out, "  sudo sh -c 'install -m 0644 '\\''"+dir+"/cyfr-locus.apparmor'\\'' /etc/apparmor.d/cyfr-locus &&\n    "+parserCommand+"'\n") {
			t.Errorf("the account was not shown the commands for whoever administers the machine:\n%s", out)
		}
		if s.applied != nil || s.authenticated != 0 || strings.Contains(out, "Load it?") {
			t.Errorf("applied %q, sudo asked %d times, or the question was asked:\n%s", s.applied, s.authenticated, out)
		}
	})
}

// With no terminal, and on another Linux, nothing is asked or run: the
// refusal is one sentence naming the one command that loads the profile.
func TestAppArmorRefusesWhereItCannotAsk(t *testing.T) {
	for name, set := range map[string]func(s *standIn){
		"no terminal":   func(*standIn) { askTerminal = func() bool { return false } },
		"another Linux": func(s *standIn) { s.supported = false },
	} {
		t.Run(name, func(t *testing.T) {
			dir := appArmorProject(t)
			s := standInMachine(t)
			s.appArmor = true
			set(s)
			out, err := ensure(t)
			if want := notLoaded(dir, "cyfr up"); err == nil || err.Error() != want {
				t.Fatalf("answered %v, want %q", err, want)
			}
			if out != "" || s.applied != nil || s.authenticated != 0 {
				t.Errorf("applied %q, sudo asked %d times, printed %q", s.applied, s.authenticated, out)
			}
		})
	}
}

// cyfr init refuses once the project's files are written and before an
// image is pulled.
func TestInitLoadsTheProfileBeforeItPulls(t *testing.T) {
	newInitProject(t)
	dir, _ := os.Getwd()
	writeAppArmor(t, testAppArmor)
	useFakeEngine(t)
	appArmorOn(t, nil)
	// No docker to pull with: a pull is seen in what init prints.
	t.Setenv("PATH", t.TempDir())
	var out bytes.Buffer
	err := initProject(context.Background(), initOptions{}, nil, &out, &out)
	if want := notLoaded(dir, "cyfr init"); err == nil || err.Error() != want {
		t.Fatalf("init answered %v, want %q\n%s", err, want, out.String())
	}
	if strings.Contains(out.String(), "Pulling") {
		t.Errorf("init pulled before the profile was loaded:\n%s", out.String())
	}
	if !fileExists(".env") {
		t.Error("init refused before the project's files were written")
	}
}

// cyfr up refuses before it takes the lock, whose recovery may start the
// stack.
func TestUpLoadsTheProfileBeforeAnythingStarts(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	writeAppArmor(t, testAppArmor)
	appArmorOn(t, nil)
	err := runUp(context.Background(), &bytes.Buffer{})
	if want := notLoaded(s.project, "cyfr up"); err == nil || err.Error() != want {
		t.Fatalf("cyfr up answered %v, want %q", err, want)
	}
	if log := s.log(); log != nil {
		t.Errorf("cyfr up went on past the refusal:\n%s", strings.Join(log, "\n"))
	}
}

// newProfileRelease is a release whose scaffold also writes another
// profile than the project's.
type newProfileRelease struct{ scaffoldRelease }

func (r newProfileRelease) Write(overwriteManaged bool) error {
	if err := r.scaffoldRelease.Write(overwriteManaged); err != nil {
		return err
	}
	return os.WriteFile(scaffold.AppArmorProfile, []byte(testAppArmor), 0o644)
}

// cyfr update reads the profile once the release's files are written, so a
// release's new profile is the one loaded, and refuses before the release
// starts, leaving it in place and stopped for cyfr up.
func TestUpdateLoadsTheReleasesProfileBeforeItStarts(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	writeAppArmor(t, olderAppArmor)
	appArmorOn(t, []byte(olderAppArmor))
	fetch := fetchScaffold
	fetchScaffold = func(v string) (scaffoldRelease, error) {
		r, err := fetch(v)
		return newProfileRelease{r}, err
	}
	out, err := s.run(context.Background())
	want := notLoaded(s.project, "cyfr up") + "\nRelease 0.9.0 is in place and the stack is left stopped; the snapshot of release 0.8.0 is " + s.snapshotDir()
	if err == nil || err.Error() != want {
		t.Fatalf("update answered %v, want %q\n%s", err, want, out)
	}
	log := s.log()
	if !slices.Contains(log, "SCAFFOLD WRITE") || s.hasCall("ENGINE start") || s.hasCall(profiles+"up") {
		t.Errorf("update did not refuse between the write and the start:\n%s", strings.Join(log, "\n"))
	}
}

// cyfr restore puts the snapshot's profile back and refuses before the
// start, the restore declared.
func TestRestoreLoadsTheProfileBeforeItStarts(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	writeAppArmor(t, testAppArmor)
	appArmorOn(t, nil)
	_, err := r.restore(true)
	want := notLoaded(r.project, "cyfr up") + "\nEvery part is back and the restore " + testRestored + " is declared, and the stack is left stopped"
	if err == nil || err.Error() != want {
		t.Fatalf("restore answered %v, want %q", err, want)
	}
	if r.hasCall("ENGINE start") || r.hasCall(profiles+"up") {
		t.Errorf("the restore started the stack:\n%s", strings.Join(r.log(), "\n"))
	}
}

// cyfr access refuses before the lock and the switch that starts the
// stack.
func TestAccessLoadsTheProfileBeforeItSwitches(t *testing.T) {
	s := newAccessProject(t)
	dir, _ := os.Getwd()
	writeAppArmor(t, testAppArmor)
	appArmorOn(t, nil)
	err := runAccess(context.Background(), "public", accessOptions{domain: "cyfr.example.com"}, true, &bytes.Buffer{})
	if want := notLoaded(dir, "cyfr access public"); err == nil || err.Error() != want {
		t.Fatalf("cyfr access answered %v, want %q", err, want)
	}
	if s.locks != 0 || len(s.switches) != 0 {
		t.Errorf("cyfr access took the lock %d times and switched %v", s.locks, s.switches)
	}
}

// The profile is the machine's, shared by every CYFR on it: the uninstall
// leaves it, runs nothing of it as root, and names it and the command that
// removes it, before it asks and at its end.
func TestUninstallLeavesTheAppArmorProfile(t *testing.T) {
	s := newUninstallScenario(t)
	machine.system = func() string { return "linux" }
	machine.appArmorProfile = func() ([]byte, error) { return []byte(testAppArmor), nil }
	out, err := s.run(true)
	if err != nil {
		t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
	}
	if !strings.Contains(out, "It leaves, as they are:\n") || !strings.Contains(out, "\n  this machine's AppArmor profile cyfr-locus, which every CYFR on it shares\n") {
		t.Errorf("the plan does not name the profile:\n%s", out)
	}
	if !strings.HasSuffix(out, "  this machine's AppArmor profile cyfr-locus, which every CYFR on it shares and this command removes:\n    "+appArmorRemover+"\n") {
		t.Errorf("the uninstall did not end naming the profile and its removal:\n%s", out)
	}
	if slices.ContainsFunc(s.root, func(c string) bool { return strings.Contains(c, "apparmor") }) {
		t.Errorf("sudo ran %q", s.root)
	}
}

// cyfr backup holds the project's profile as it holds every managed file.
func TestBackupHoldsTheAppArmorProfile(t *testing.T) {
	appArmorProject(t)
	names, err := managedPresent()
	if err != nil || !slices.Contains(names, filepath.FromSlash(scaffold.AppArmorProfile)) {
		t.Fatalf("cyfr backup holds %v (%v), which lacks %s", names, err, scaffold.AppArmorProfile)
	}
}
