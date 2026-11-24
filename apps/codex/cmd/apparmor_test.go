// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/apparmor"
)

// A profile a project folder or the machine may hold that is not this
// cyfr's, and what cyfr says and runs.
const (
	olderAppArmor = "abi <abi/4.0>,\nprofile cyfr-locus {}\n"
	olderName     = "cyfr-locus-aaaaaaaaaaaa"
)

var (
	name        = apparmor.ProfileName
	target      = "/etc/apparmor.d/" + name
	notHeld     = "Locus runs under the AppArmor profile " + name + ", which this machine has not loaded.\n"
	loadCommand = "cyfr apparmor-profile | sudo sh -c 'cat > " + target + " && apparmor_parser -r -W " + target + "'"
)

// notLoaded is the refusal where nothing may ask: the one command, then
// again.
func notLoaded(again string) string {
	return "Locus runs under the AppArmor profile " + name + ", which this machine has not loaded, so nothing was changed. " +
		"Run `" + loadCommand + "`, then run `" + again + "` again"
}

// declined is the refusal of a person who answered no.
func declined(again string) string {
	return "The AppArmor profile was not loaded, so nothing was changed. Run `" + again + "` again when you want to go on"
}

// appArmorOn makes the machine the tests stand on, its own seams kept, an
// Ubuntu 26.04 whose kernel enforces AppArmor and holds the profiles named
// loaded, until t ends.
func appArmorOn(t *testing.T, loaded ...string) {
	t.Helper()
	saved := machine
	t.Cleanup(func() { machine = saved })
	machine.system = func() string { return "linux" }
	machine.supported = func() bool { return true }
	machine.appArmor = func() bool { return true }
	machine.appArmorLoaded = func(n string) (bool, bool) { return slices.Contains(loaded, n), true }
}

func ensure(t *testing.T) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := ensureAppArmor(context.Background(), &out, "cyfr up")
	return out.String(), err
}

// Another system, another Linux, AppArmor off, a container that sees no
// host's policy, and a kernel that holds this cyfr's profile by its name
// ask nothing and change nothing, at a terminal that would answer yes: the
// keeper's boot proves what a container runs under.
func TestAppArmorLeavesAMachineAlone(t *testing.T) {
	for name, set := range map[string]func(s *standIn){
		"another system":        func(s *standIn) { s.system = "darwin" },
		"another Linux":         func(s *standIn) { s.supported = false },
		"AppArmor off":          func(s *standIn) { s.appArmor = false },
		"a container":           func(s *standIn) { s.hidden = true },
		"this profile is there": func(s *standIn) { s.loaded = []string{olderName, apparmor.ProfileName} },
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

// At a terminal on Ubuntu 26.04, a kernel that holds no profile of this
// name, an older one's included, is shown the two commands, asked once,
// and they run through one sudo after its own prompt with the profile
// built into cyfr as their input, under its name, whatever a project
// folder holds; the login is forgotten after.
func TestAppArmorLoadsThroughOneSudo(t *testing.T) {
	for name, loaded := range map[string][]string{"none": nil, "an older one": {olderName}} {
		t.Run(name, func(t *testing.T) {
			t.Chdir(t.TempDir())
			if err := os.WriteFile("cyfr-locus.apparmor", []byte(olderAppArmor), 0o644); err != nil {
				t.Fatal(err)
			}
			s := standInMachine(t)
			s.appArmor, s.loaded = true, loaded
			out, err := ensure(t)
			if err != nil {
				t.Fatalf("ensure: %v\n%s", err, out)
			}
			want := []string{"cat > " + target, "apparmor_parser -r -W " + target}
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
	if want := "Loading the AppArmor profile " + name + " failed, so nothing was changed. Fix what is shown above, then run `cyfr up` again"; err == nil || err.Error() != want {
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
		if want := declined("cyfr up"); err == nil || err.Error() != want {
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
// naming the one command that loads the profile, an older one held or not.
func TestAppArmorRefusesWhereItCannotAsk(t *testing.T) {
	s := standInMachine(t)
	s.appArmor, s.loaded = true, []string{olderName}
	askTerminal = func() bool { return false }
	out, err := ensure(t)
	if want := notLoaded("cyfr up"); err == nil || err.Error() != want {
		t.Fatalf("answered %v, want %q", err, want)
	}
	if out != "" || s.applied != nil || s.authenticated != 0 {
		t.Errorf("applied %q, sudo asked %d times, printed %q", s.applied, s.authenticated, out)
	}
}

// What root runs is found by no program of the person's PATH: the real
// loader, through a stand-in sudo that keeps the environment, with an sh, a
// cat and an apparmor_parser planted ahead on PATH, runs none of them, and
// the real cat writes the profile's bytes.
func TestTheLoaderRunsNothingOfThePersonsPATH(t *testing.T) {
	if _, err := os.Stat("/etc/apparmor.d"); err != nil {
		t.Skip("this machine has no /etc/apparmor.d to name the load's file under")
	}
	planted, marks, out := t.TempDir(), t.TempDir(), filepath.Join(t.TempDir(), "profile")
	for _, program := range []string{"sh", "cat", "apparmor_parser"} {
		script := fmt.Sprintf("#!/bin/sh\necho ran > %s/%s\n", marks, program)
		if err := os.WriteFile(filepath.Join(planted, program), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(planted, "sudo"), []byte("#!/bin/sh\nexec \"$@\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", planted+string(os.PathListSeparator)+os.Getenv("PATH"))
	// The load's file, named under /etc/apparmor.d, resolves to one this
	// test may write; the parser, not root here, refuses to load it.
	_ = realMachine.applyInput(appArmorCommands("../.."+out), apparmor.Profile)
	if ran, _ := os.ReadDir(marks); len(ran) != 0 {
		t.Fatalf("root ran programs of the person's PATH: %v", ran)
	}
	if got, err := os.ReadFile(out); err != nil || !bytes.Equal(got, apparmor.Profile) {
		t.Fatalf("the load wrote %d bytes (%v), want the profile's %d", len(got), err, len(apparmor.Profile))
	}
}

// `cyfr apparmor-profile` prints the profile built into cyfr, whole, under
// its name.
func TestAppArmorProfilePrintsTheProfile(t *testing.T) {
	out, err := runCommand(t, context.Background(), "apparmor-profile")
	if err != nil || out != string(apparmor.Profile) || !strings.Contains(out, "profile "+name+" flags=") {
		t.Fatalf("answered %v, printed %d bytes, want the %d of the profile under %s", err, len(out), len(apparmor.Profile), name)
	}
}

// The command cyfr names is the keeper's: one sentence, two modules.
func TestTheLoadCommandIsTheKeepers(t *testing.T) {
	source, err := os.ReadFile("../../locus/keeper/internal/stage/confinement_linux.go")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile("(?m)^const LoadProfile = \"(.*)\"$").FindSubmatch(source)
	if m == nil || string(m[1]) != loadAppArmorFormat || loadAppArmor != loadCommand {
		t.Fatalf("the keeper names %q, cyfr %q", m, loadAppArmorFormat)
	}
}

// cyfr init asks before it writes anything: a person who declines keeps
// the folder as it was, and one who loads it gets .env naming the profile.
func TestInitAsksBeforeItWritesAnything(t *testing.T) {
	dir := newInitProject(t)
	useFakeEngine(t)
	s := standInMachine(t)
	s.appArmor = true
	askInput = strings.NewReader("no\n")
	before, _ := os.ReadDir(dir)
	var out bytes.Buffer
	err := initProject(context.Background(), initOptions{}, nil, &out, &out)
	if want := declined("cyfr init"); err == nil || err.Error() != want {
		t.Fatalf("init answered %v, want %q\n%s", err, want, out.String())
	}
	if after, _ := os.ReadDir(dir); len(after) != len(before) {
		t.Errorf("init declined wrote %v, where the folder held %v", after, before)
	}
}

// A .env init writes names the profile built into this cyfr, whatever it
// named before.
func TestInitNamesTheProfileInEnv(t *testing.T) {
	newInitProject(t)
	if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\nCYFR_PORT=4000\n"+appArmorEnv+"="+olderName+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ensureEnvFileKeys(".env"); err != nil {
		t.Fatal(err)
	}
	if values, _ := access.ReadEnvValues(".env"); values[appArmorEnv] != name {
		t.Fatalf(".env names %q, want %q", values[appArmorEnv], name)
	}
}

// cyfr up refuses before it takes the lock, whose recovery may start the
// stack.
func TestUpLoadsTheProfileBeforeAnythingStarts(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	appArmorOn(t, olderName)
	askTerminal = func() bool { return false }
	err := runUp(context.Background(), &bytes.Buffer{})
	if want := notLoaded("cyfr up"); err == nil || err.Error() != want {
		t.Fatalf("cyfr up answered %v, want %q", err, want)
	}
	if log := s.log(); log != nil {
		t.Errorf("cyfr up went on past the refusal:\n%s", strings.Join(log, "\n"))
	}
}

// cyfr update asks for the release's profile before it changes anything:
// a person who declines keeps the running stack, its release and its .env.
func TestUpdateAsksBeforeItStops(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	appArmorOn(t, olderName)
	machine.groups = func(context.Context, string) []string { return []string{"sudo"} }
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("no\n")
	env, _ := os.ReadFile(".env")
	out, err := s.run(context.Background())
	if want := declined("cyfr update"); err == nil || err.Error() != want {
		t.Fatalf("update answered %v, want %q\n%s", err, want, out)
	}
	if s.hasCall("ENGINE hold") || s.hasCall(profiles+"stop") || s.hasCall("SCAFFOLD WRITE") {
		t.Errorf("update changed the stack before the offer:\n%s", strings.Join(s.log(), "\n"))
	}
	if now, _ := os.ReadFile(".env"); !bytes.Equal(now, env) {
		t.Errorf("update changed .env before the offer:\n%s", now)
	}
}

// An update whose release's profile is loaded names it in .env at the
// switch and, once the stack is up, takes off the machine the profile .env
// named before.
func TestUpdateNamesItsProfileAndRetiresTheOld(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	if err := access.EditEnvFile(".env", map[string]string{appArmorEnv: olderName}, nil); err != nil {
		t.Fatal(err)
	}
	appArmorOn(t, olderName, name)
	var applied [][]string
	machine.passwordless = func() bool { return true }
	machine.apply = func(commands []string) error { applied = append(applied, commands); return nil }
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	if values, _ := access.ReadEnvValues(".env"); values[appArmorEnv] != name {
		t.Errorf(".env names %q after the update, want %q", values[appArmorEnv], name)
	}
	old := "/etc/apparmor.d/" + olderName
	if want := [][]string{{"apparmor_parser -R " + old, "rm " + old}}; !slices.EqualFunc(applied, want, slices.Equal) {
		t.Errorf("root ran %q, want the older profile's removal alone", applied)
	}
}

// cyfr restore refuses before the start, the restore declared.
func TestRestoreLoadsTheProfileBeforeItStarts(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	appArmorOn(t)
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
	appArmorOn(t)
	askTerminal = func() bool { return false }
	err := runAccess(context.Background(), "public", accessOptions{domain: "cyfr.example.com"}, true, &bytes.Buffer{})
	if want := notLoaded("cyfr access public"); err == nil || err.Error() != want {
		t.Fatalf("cyfr access answered %v, want %q", err, want)
	}
	if s.locks != 0 || len(s.switches) != 0 {
		t.Errorf("cyfr access took the lock %d times and switched %v", s.locks, s.switches)
	}
}

// The profile is the machine's, which every CYFR on it may share: the
// uninstall leaves the one .env names, runs nothing of it as root, and
// names it and the command that removes it, before it asks and at its end.
func TestUninstallLeavesTheAppArmorProfile(t *testing.T) {
	s := newUninstallScenario(t)
	if err := os.WriteFile(filepath.Join(s.dir, ".env"), []byte("CYFR_ACCESS=local\n"+appArmorEnv+"="+olderName+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	machine.system = func() string { return "linux" }
	machine.appArmorLoaded = func(n string) (bool, bool) { return n == olderName, true }
	out, err := s.run(true)
	if err != nil {
		t.Fatalf("cyfr uninstall answered %v\n%s", err, out)
	}
	if !strings.Contains(out, "It leaves, as they are:\n") || !strings.Contains(out, "\n  this machine's AppArmor profile "+olderName+", which every CYFR on it may share\n") {
		t.Errorf("the plan does not name the profile:\n%s", out)
	}
	remover := "sudo sh -c 'apparmor_parser -R /etc/apparmor.d/" + olderName + " && rm /etc/apparmor.d/" + olderName + "'"
	if !strings.HasSuffix(out, "  this machine's AppArmor profile "+olderName+", which every CYFR on it may share and this command removes:\n    "+remover+"\n") {
		t.Errorf("the uninstall did not end naming the profile and its removal:\n%s", out)
	}
	if slices.ContainsFunc(s.root, func(c string) bool { return strings.Contains(c, "apparmor") }) {
		t.Errorf("sudo ran %q", s.root)
	}
}
