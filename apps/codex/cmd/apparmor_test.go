// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/apparmor"
)

// An older profile a machine may hold, and what cyfr says and runs.
const (
	olderAppArmor   = "abi <abi/4.0>,\nprofile cyfr-locus {}\n"
	notHeld         = "Locus runs under the AppArmor profile cyfr-locus, and this machine does not hold this cyfr's.\n"
	appArmorRemover = "sudo sh -c 'apparmor_parser -R /etc/apparmor.d/cyfr-locus && rm /etc/apparmor.d/cyfr-locus'"
	loadCommand     = "cyfr apparmor-profile | sudo sh -c 'cat > /etc/apparmor.d/cyfr-locus && apparmor_parser -r -W /etc/apparmor.d/cyfr-locus'"
)

// notLoaded is the refusal where nothing may ask: the one command, then
// again.
func notLoaded(again string) string {
	return "Locus runs under the AppArmor profile cyfr-locus, which this machine does not hold as this cyfr has it, so nothing was started. " +
		"Run `" + loadCommand + "`, then run `" + again + "` again"
}

// appArmorOn makes the machine the tests stand on, its own seams kept, an
// Ubuntu 26.04 whose kernel enforces AppArmor and whose /etc/apparmor.d
// holds loaded, none when nil, until t ends.
func appArmorOn(t *testing.T, loaded []byte) {
	t.Helper()
	saved := machine
	t.Cleanup(func() { machine = saved })
	machine.system = func() string { return "linux" }
	machine.supported = func() bool { return true }
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

// Another system, another Linux or a container whose host cyfr cannot see,
// AppArmor off, and a machine that holds this cyfr's profile ask nothing
// and change nothing, at a terminal that would answer yes: the keeper's
// boot proves what is enforced.
func TestAppArmorLeavesAMachineAlone(t *testing.T) {
	for name, set := range map[string]func(s *standIn){
		"another system":       func(s *standIn) { s.system = "darwin" },
		"another Linux":        func(s *standIn) { s.supported = false },
		"AppArmor off":         func(s *standIn) { s.appArmor = false },
		"the profile is there": func(s *standIn) { s.profile = apparmor.Profile },
	} {
		t.Run(name, func(t *testing.T) {
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

// At a terminal on Ubuntu 26.04, a machine without this cyfr's profile, or
// with another one, is shown the two commands, asked once, and they run
// through one sudo after its own prompt with the profile built into cyfr as
// their input, whatever a project folder holds; the login is forgotten
// after.
func TestAppArmorLoadsThroughOneSudo(t *testing.T) {
	for name, loaded := range map[string][]byte{"none": nil, "an older one": []byte(olderAppArmor)} {
		t.Run(name, func(t *testing.T) {
			t.Chdir(t.TempDir())
			if err := os.WriteFile("cyfr-locus.apparmor", []byte(olderAppArmor), 0o644); err != nil {
				t.Fatal(err)
			}
			s := standInMachine(t)
			s.appArmor, s.profile = true, loaded
			out, err := ensure(t)
			if err != nil {
				t.Fatalf("ensure: %v\n%s", err, out)
			}
			want := []string{"cat > /etc/apparmor.d/cyfr-locus", "apparmor_parser -r -W /etc/apparmor.d/cyfr-locus"}
			if len(s.applied) != 1 || !slices.Equal(s.applied[0], want) || !bytes.Equal(s.input[0], apparmor.Profile) {
				t.Fatalf("applied %q with %d bytes, want one sudo of %q with the profile built into cyfr", s.applied, len(s.input), want)
			}
			if s.authenticated != 1 || s.forgotten != 1 {
				t.Errorf("sudo asked %d times and forgot %d times, want once each", s.authenticated, s.forgotten)
			}
			shown := notHeld + "These commands load it, as root, the profile built into this cyfr as their input:\n  " + want[0] + "\n  " + want[1] + "\nLoad it? (yes/no) "
			if !strings.HasPrefix(out, shown) || !strings.HasSuffix(out, passwordSentence) {
				t.Errorf("printed:\n%s\nwant it to begin\n%s\nand end with the password sentence", out, shown)
			}
		})
	}
}

// A load root refuses, a profile the parser rejects among them, is said to
// the person, and nothing starts.
func TestAppArmorSaysALoadThatFailed(t *testing.T) {
	s := standInMachine(t)
	s.appArmor, s.applyErr = true, fs.ErrPermission
	out, err := ensure(t)
	if want := "Loading the AppArmor profile cyfr-locus failed, so nothing was started. Fix what is shown above, then run `cyfr up` again"; err == nil || err.Error() != want {
		t.Fatalf("answered %v, want %q\n%s", err, want, out)
	}
}

// Answered no, and for an account outside the sudo and admin groups, the
// profile is not loaded and sudo is never asked.
func TestAppArmorDeclinedLoadsNothing(t *testing.T) {
	t.Run("answered no", func(t *testing.T) {
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
		s := standInMachine(t)
		s.appArmor, s.administrator = true, nil
		out, err := ensure(t)
		if err == nil || err.Error() != "Nothing was changed. Run `cyfr up` again once they have" {
			t.Fatalf("answered %v\n%s", err, out)
		}
		if !strings.Contains(out, "\n  "+loadCommand+"\n") {
			t.Errorf("the account was not shown the one command for whoever administers the machine:\n%s", out)
		}
		if s.applied != nil || s.authenticated != 0 || strings.Contains(out, "Load it?") {
			t.Errorf("applied %q, sudo asked %d times, or the question was asked:\n%s", s.applied, s.authenticated, out)
		}
	})
}

// With no terminal, nothing is asked or run: the refusal is one sentence
// naming the one command that loads the profile.
func TestAppArmorRefusesWhereItCannotAsk(t *testing.T) {
	s := standInMachine(t)
	s.appArmor = true
	askTerminal = func() bool { return false }
	out, err := ensure(t)
	if want := notLoaded("cyfr up"); err == nil || err.Error() != want {
		t.Fatalf("answered %v, want %q", err, want)
	}
	if out != "" || s.applied != nil || s.authenticated != 0 {
		t.Errorf("applied %q, sudo asked %d times, printed %q", s.applied, s.authenticated, out)
	}
}

// `cyfr apparmor-profile` prints the profile built into cyfr, whole.
func TestAppArmorProfilePrintsTheProfile(t *testing.T) {
	out, err := runCommand(t, context.Background(), "apparmor-profile")
	if err != nil || out != string(apparmor.Profile) {
		t.Fatalf("answered %v, printed %d bytes, want the %d of the profile", err, len(out), len(apparmor.Profile))
	}
}

// The command cyfr names is the keeper's: one sentence, two modules.
func TestTheLoadCommandIsTheKeepers(t *testing.T) {
	source, err := os.ReadFile("../../locus/keeper/internal/stage/confinement_linux.go")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile("(?m)^const LoadProfile = \"(.*)\"$").FindSubmatch(source)
	if m == nil || string(m[1]) != loadAppArmor || loadAppArmor != loadCommand {
		t.Fatalf("the keeper names %q, cyfr %q", m, loadAppArmor)
	}
}

// cyfr init refuses once the project's files are written and before an
// image is pulled.
func TestInitLoadsTheProfileBeforeItPulls(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	appArmorOn(t, nil)
	askTerminal = func() bool { return false }
	// No docker to pull with: a pull is seen in what init prints.
	t.Setenv("PATH", t.TempDir())
	var out bytes.Buffer
	err := initProject(context.Background(), initOptions{}, nil, &out, &out)
	if want := notLoaded("cyfr init"); err == nil || err.Error() != want {
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
	appArmorOn(t, nil)
	askTerminal = func() bool { return false }
	err := runUp(context.Background(), &bytes.Buffer{})
	if want := notLoaded("cyfr up"); err == nil || err.Error() != want {
		t.Fatalf("cyfr up answered %v, want %q", err, want)
	}
	if log := s.log(); log != nil {
		t.Errorf("cyfr up went on past the refusal:\n%s", strings.Join(log, "\n"))
	}
}

// cyfr update refuses after the release's files are written and before the
// release starts, leaving it in place and stopped for cyfr up.
func TestUpdateLoadsTheReleasesProfileBeforeItStarts(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	appArmorOn(t, []byte(olderAppArmor))
	askTerminal = func() bool { return false }
	out, err := s.run(context.Background())
	want := notLoaded("cyfr up") + "\nRelease 0.9.0 is in place and the stack is left stopped; the snapshot of release 0.8.0 is " + s.snapshotDir()
	if err == nil || err.Error() != want {
		t.Fatalf("update answered %v, want %q\n%s", err, want, out)
	}
	log := s.log()
	if !slices.Contains(log, "SCAFFOLD WRITE") || s.hasCall("ENGINE start") || s.hasCall(profiles+"up") {
		t.Errorf("update did not refuse between the write and the start:\n%s", strings.Join(log, "\n"))
	}
}

// cyfr restore refuses before the start, the restore declared.
func TestRestoreLoadsTheProfileBeforeItStarts(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	appArmorOn(t, nil)
	askTerminal = func() bool { return false }
	_, err := r.restore(true)
	want := notLoaded("cyfr up") + "\nEvery part is back and the restore " + testRestored + " is declared, and the stack is left stopped"
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
	appArmorOn(t, nil)
	askTerminal = func() bool { return false }
	err := runAccess(context.Background(), "public", accessOptions{domain: "cyfr.example.com"}, true, &bytes.Buffer{})
	if want := notLoaded("cyfr access public"); err == nil || err.Error() != want {
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
	machine.appArmorProfile = func() ([]byte, error) { return apparmor.Profile, nil }
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
