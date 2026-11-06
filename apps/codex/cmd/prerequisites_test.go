// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// sgStandIn records the sg cyfr init continues through and answers status.
func sgStandIn(t *testing.T, status string) string {
	t.Helper()
	record := filepath.Join(t.TempDir(), "sg")
	script := filepath.Join(t.TempDir(), "sg.sh")
	body := "#!/bin/sh\nprintf '%s\\n' \"$@\" >'" + record + "'\nexit " + status + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	sgProgram = script
	return record
}

func prepare(t *testing.T) (bool, string, error) {
	t.Helper()
	var out bytes.Buffer
	continued, err := prepareMachine(context.Background(), []string{"--no-pull"}, &out, &out)
	return continued, out.String(), err
}

// No terminal, another system, and a Docker this account reaches ask
// nothing and change nothing.
func TestInitLeavesAMachineAlone(t *testing.T) {
	for name, set := range map[string]func(s *standIn){
		"no terminal":    func(*standIn) { askTerminal = func() bool { return false } },
		"another system": func(s *standIn) { s.supported = false },
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			set(s)
			continued, out, err := prepare(t)
			if continued || err != nil || out != "" || s.applied != nil {
				t.Fatalf("continued %t, err %v, applied %v, out %q", continued, err, s.applied, out)
			}
		})
	}
}

// A fresh machine shows the plain commands, asks once, runs them all
// through one sudo, forgets the login and goes on through sg docker with
// the flags given.
func TestInitInstallsThroughOneSudoAndContinues(t *testing.T) {
	s := standInMachine(t)
	record := sgStandIn(t, "0")
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	continued, out, err := prepare(t)
	if !continued || err != nil {
		t.Fatalf("continued %t, err %v\n%s", continued, err, out)
	}
	want := []string{
		"apt-get update",
		"apt-get install -y --no-install-recommends docker.io docker-compose-v2 apparmor",
		"systemctl enable --now docker",
		"usermod -aG docker " + u.Username,
	}
	if len(s.applied) != 1 || !slices.Equal(s.applied[0], want) {
		t.Fatalf("applied %q, want one %q", s.applied, want)
	}
	if s.forgotten != 1 {
		t.Errorf("sudo's login was forgotten %d times", s.forgotten)
	}
	for _, c := range want {
		if !strings.Contains(out, "\n  "+c+"\n") {
			t.Errorf("the preview lacks %q:\n%s", c, out)
		}
	}
	if !strings.Contains(out, "Install these requirements? (yes/no)") {
		t.Errorf("output:\n%s", out)
	}
	self, _ := os.Executable()
	sg, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(sg), "docker\n-c\n"+shellQuote([]string{self, "init", "--no-pull"})+"\n"; got != want {
		t.Errorf("sg ran %q, want %q", got, want)
	}
}

// Only what is missing is run.
func TestInitRunsOnlyWhatIsMissing(t *testing.T) {
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		set  func(s *standIn)
		want []string
	}{
		"one package missing": {func(s *standIn) {
			s.installed, s.running, s.member = []string{"docker.io", "apparmor"}, true, []string{"docker"}
		}, []string{"apt-get update", "apt-get install -y --no-install-recommends docker-compose-v2"}},
		"the service stopped": {func(s *standIn) {
			s.installed, s.member = dockerPackages, []string{"docker"}
		}, []string{"systemctl enable --now docker"}},
		"the group": {func(s *standIn) {
			s.installed, s.running = dockerPackages, true
		}, []string{"usermod -aG docker " + u.Username}},
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			sgStandIn(t, "0")
			c.set(s)
			if _, out, err := prepare(t); err != nil || len(s.applied) != 1 || !slices.Equal(s.applied[0], c.want) {
				t.Fatalf("applied %q, want %q, err %v\n%s", s.applied, c.want, err, out)
			}
		})
	}
}

// A machine that has everything, in a terminal older than the group, asks
// nothing and goes on through sg.
func TestInitContinuesInATerminalOlderThanTheGroup(t *testing.T) {
	s := standInMachine(t)
	s.installed, s.running, s.member = dockerPackages, true, []string{"docker"}
	record := sgStandIn(t, "0")
	continued, _, err := prepare(t)
	if !continued || err != nil || s.applied != nil || s.forgotten != 0 {
		t.Fatalf("continued %t, err %v, applied %v, forgotten %d", continued, err, s.applied, s.forgotten)
	}
	if _, err := os.Stat(record); err != nil {
		t.Errorf("sg did not run: %v", err)
	}
}

// Installing and reaching Docker needs no continuation, and a process that
// has the group and still cannot reach Docker goes on as it is: a
// continuation would land here again, and again.
func TestInitNeedsNoContinuation(t *testing.T) {
	t.Run("Docker answers after the install", func(t *testing.T) {
		s := standInMachine(t)
		s.reachableAfter = true
		if continued, _, err := prepare(t); continued || err != nil || len(s.applied) != 1 {
			t.Fatalf("continued %t, err %v, applied %v", continued, err, s.applied)
		}
	})
	t.Run("the process has the group", func(t *testing.T) {
		s := standInMachine(t)
		s.installed, s.running, s.member, s.process = dockerPackages, true, []string{"docker"}, []string{"docker"}
		if continued, _, err := prepare(t); continued || err != nil || s.applied != nil {
			t.Fatalf("continued %t, err %v, applied %v", continued, err, s.applied)
		}
	})
}

// A daemon that stops right after a successful start leaves a process that
// has the group where it was, and sg would give it nothing: init goes on.
func TestInitDoesNotRepeatSgWithTheSameGroup(t *testing.T) {
	s := standInMachine(t)
	s.installed = dockerPackages
	s.member, s.process = []string{"docker"}, []string{"docker"}
	sgStandIn(t, "0")
	for attempt := 1; attempt <= 2; attempt++ {
		askInput = strings.NewReader("yes\n")
		continued, out, err := prepare(t)
		if err != nil {
			t.Fatalf("attempt %d: %v\n%s", attempt, err, out)
		}
		if continued {
			t.Errorf("attempt %d went through sg with the group it has; applied %q", attempt, s.applied)
		}
	}
}

// The real apply and forget: sudo -k follows a failed install.
func TestInitForgetsTheLoginWithTheRealSudo(t *testing.T) {
	production := machine
	standInMachine(t)
	machine.apply, machine.forget = production.apply, production.forget
	dir := t.TempDir()
	record := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >>'" + record + "'\n[ \"$1\" = -k ] && exit 0\nexit 1\n"
	if err := os.WriteFile(filepath.Join(dir, "sudo"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	if continued, _, err := prepare(t); continued || err == nil {
		t.Fatalf("continued = %t, err = %v", continued, err)
	}
	got, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(got)), "\n")
	if len(lines) != 2 || !strings.HasPrefix(lines[0], "sh -c apt-get update && ") || lines[1] != "-k" {
		t.Fatalf("sudo ran %q", lines)
	}
}

// Declining changes nothing, says so with the next step, and ends init as
// no failure.
func TestInitDeclined(t *testing.T) {
	s := standInMachine(t)
	askInput = strings.NewReader("no\n")
	ended, out, err := prepare(t)
	if !ended || err != nil || !strings.HasSuffix(out, "[no]: Nothing was installed. Run cyfr init again when you want to continue.\n") {
		t.Fatalf("ended %t, err = %v:\n%s", ended, err, out)
	}
	if s.applied != nil || s.forgotten != 0 {
		t.Errorf("applied %v, forgotten %d", s.applied, s.forgotten)
	}
}

// A failed install forgets the login and gives its one line; apt's own
// words are already on the terminal.
func TestInitInstallFails(t *testing.T) {
	s := standInMachine(t)
	s.applyErr = errors.New("exit status 100")
	continued, _, err := prepare(t)
	if continued || err == nil || err.Error() != "Installing the requirements failed. Fix what is shown above, then run `cyfr init` again" {
		t.Fatalf("continued %t, err %v", continued, err)
	}
	if s.forgotten != 1 {
		t.Errorf("sudo's login was forgotten %d times", s.forgotten)
	}
}

// A continued init's status is init's.
func TestInitAnswersTheContinuationsStatus(t *testing.T) {
	s := standInMachine(t)
	s.installed, s.running, s.member = dockerPackages, true, []string{"docker"}
	sgStandIn(t, "7")
	if _, _, err := prepare(t); ExitStatus(err) != 7 {
		t.Fatalf("err = %v, status %d", err, ExitStatus(err))
	}
}

// cyfr up in a terminal older than the group runs itself again through sg.
func TestUpContinuesInATerminalOlderThanTheGroup(t *testing.T) {
	s := standInMachine(t)
	s.member = []string{"docker"}
	record := sgStandIn(t, "0")
	continued, err := upWithGroup(nil, &bytes.Buffer{}, &bytes.Buffer{})
	if !continued || err != nil {
		t.Fatalf("continued %t, err %v", continued, err)
	}
	self, _ := os.Executable()
	sg, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(sg), "docker\n-c\n"+shellQuote([]string{self, "up"})+"\n"; got != want {
		t.Errorf("sg ran %q, want %q", got, want)
	}
}

// cyfr up carries on as it is when sg has nothing to give it.
func TestUpNeedsNoContinuation(t *testing.T) {
	for name, set := range map[string]func(*standIn){
		"another system":     func(s *standIn) { s.supported = false },
		"not in the group":   func(s *standIn) { s.member = nil },
		"the process has it": func(s *standIn) { s.process = []string{"docker"} },
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			s.member = []string{"docker"}
			set(s)
			record := sgStandIn(t, "0")
			if continued, err := upWithGroup(nil, &bytes.Buffer{}, &bytes.Buffer{}); continued || err != nil {
				t.Fatalf("continued %t, err %v", continued, err)
			}
			if _, err := os.Stat(record); err == nil {
				t.Error("sg ran")
			}
		})
	}
}

// TestShellQuoteReadsBackWordForWord runs shellQuote's line through sh, as
// sg does: every word comes back as it was, nothing expanded or run.
func TestShellQuoteReadsBackWordForWord(t *testing.T) {
	words := []string{"/usr/local/bin/cyfr", "init", "--hostname=it's", "--domain=$HOME", "a b", ";touch x"}
	out, err := exec.Command("/bin/sh", "-c", shellQuote(append([]string{"printf", "%s\\n"}, words...))).Output()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n"); !slices.Equal(got, words) {
		t.Errorf("sh read back %q, want %q", got, words)
	}
}
