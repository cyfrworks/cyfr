// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/install"
	"github.com/cyfr/codex/internal/install/fake"
	"github.com/cyfr/codex/internal/version"
)

// standInMachine makes cyfr init see m as alice, a process without the
// docker group, and run the root entry as entry (a shell script),
// recording each interactive flag the entry was asked for and each time
// sudo's login was forgotten.
type standIn struct {
	m          *fake.Machine
	entryCalls []bool
	forgotten  int
}

func standInMachine(t *testing.T, m *fake.Machine, entry string) *standIn {
	t.Helper()
	s := &standIn{m: m}
	observe, entryOf, forget := machine.observe, machine.entry, machine.forget
	t.Cleanup(func() { machine.observe, machine.entry, machine.forget = observe, entryOf, forget })
	machine.observe = func(context.Context, install.Policy) (install.Facts, error) {
		return m.Facts(install.Account{Name: "alice", UID: 1000}, false), nil
	}
	machine.entry = func(_ install.Policy, root, interactive bool) ([]string, error) {
		s.entryCalls = append(s.entryCalls, interactive)
		if entry == "" {
			return nil, errNoSudo
		}
		// sh -c's $0 is --plan and $1 the plan's FIFO.
		return []string{"/bin/sh", "-c", entry}, nil
	}
	machine.forget = func() { s.forgotten++ }
	return s
}

// event is one line of the root entry's output.
func event(t *testing.T, ev install.Event) string {
	t.Helper()
	line, err := json.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	return string(line)
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// TestInitAsksNothingOfAMachineThatHasEverything prepares a project on a
// machine that has Docker and the group: nothing is shown or asked, and
// nothing runs as root.
func TestInitAsksNothingOfAMachineThatHasEverything(t *testing.T) {
	newInitProject(t)
	p := install.Load()
	m := fake.New(p)
	m.Packages = map[string]string{"docker.io": "installed", "docker-compose-v2": "installed", "apparmor": "installed"}
	m.Service, m.Enabled, m.Members = "active", true, []string{"alice"}
	s := standInMachine(t, m, "")
	machine.observe = func(context.Context, install.Policy) (install.Facts, error) {
		return m.Facts(install.Account{Name: "alice", UID: 1000}, true), nil
	}
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("3\n")
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "Install these requirements") || len(s.entryCalls) != 0 || s.forgotten != 0 || len(m.Ran) != 0 {
		t.Fatalf("a satisfied machine was asked or changed (entry %v, forgotten %d, ran %v):\n%s", s.entryCalls, s.forgotten, m.Ran, out.String())
	}
	if !fileExists(".env") {
		t.Fatal("init did not prepare the project")
	}
}

// TestInitDeclinedOrUnagreedChangesNothing shows the exact commands, and
// a person who answers no, or a run with no terminal and no --yes, gets
// the sentence saying so, with nothing run as root and nothing written.
func TestInitDeclinedOrUnagreedChangesNothing(t *testing.T) {
	p := install.Load()
	for name, c := range map[string]struct {
		terminal bool
		input    string
		want     string
	}{
		"declined":    {true, "no\n", "You chose not to install docker.io, docker-compose-v2, the running Docker service and alice's membership of the docker group. Nothing was installed. Run `cyfr init` again when you want to continue."},
		"no terminal": {false, "", "Installing docker.io, docker-compose-v2, the running Docker service and alice's membership of the docker group needs your agreement in a terminal. Nothing was installed."},
	} {
		t.Run(name, func(t *testing.T) {
			newInitProject(t)
			s := standInMachine(t, fake.New(p), "exit 99")
			askTerminal = func() bool { return c.terminal }
			askInput = strings.NewReader(c.input)
			var out bytes.Buffer
			err := runInit(context.Background(), initOptions{noPull: true}, &out, &out)
			if err == nil || !strings.HasPrefix(err.Error(), c.want) {
				t.Fatalf("runInit = %v, want %q", err, c.want)
			}
			for _, line := range []string{"  apt-get update\n", "  apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends docker.io docker-compose-v2\n", "  systemctl enable --now docker.service\n", "  usermod -aG docker alice\n", "Members of the docker group control Docker"} {
				if !strings.Contains(out.String(), line) {
					t.Errorf("the preview lacks %q:\n%s", line, out.String())
				}
			}
			if len(s.entryCalls) != 0 || s.forgotten != 0 {
				t.Errorf("the root entry ran (%v) or sudo was touched (%d)", s.entryCalls, s.forgotten)
			}
			nothingWritten(t, ".env.example")
		})
	}
}

// sgStandIn records the sg cyfr init continues through: its arguments, its
// directory and whether its standard input is the process's, and answers
// status after printing a line.
func sgStandIn(t *testing.T, status int) string {
	t.Helper()
	record := filepath.Join(t.TempDir(), "sg")
	script := filepath.Join(t.TempDir(), "sg.sh")
	body := "#!/bin/sh\n{ pwd; printf '%s\\n' \"$@\"; } >" + shQuote(record) + "\necho 'the continued init ran'\nexit " + strconv.Itoa(status) + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	saved := sgProgram
	t.Cleanup(func() { sgProgram = saved })
	sgProgram = script
	return record
}

// TestInitInstallsThroughOneEntryAndContinues agrees, runs the root entry
// once with the agreed plan on its input, shows its actions, then goes on
// as this same program's init through sg docker, in this directory with
// the person's flags quoted for sh, offers newgrp before `cyfr up`, and
// forgets sudo's login.
func TestInitInstallsThroughOneEntryAndContinues(t *testing.T) {
	dir := newInitProject(t)
	p := install.Load()
	m := fake.New(p)
	planFile := filepath.Join(t.TempDir(), "plan.json")
	entry := "cat >" + shQuote(planFile) + "; " +
		"echo " + shQuote(event(t, install.Event{Event: install.EventStart, Action: &install.Action{Kind: install.AptUpdate}})) + "; exit 0"
	s := standInMachine(t, m, entry)
	calls := 0
	machine.observe = func(context.Context, install.Policy) (install.Facts, error) {
		calls++
		if calls > 1 { // the entry added alice to the group
			m.Members = []string{"alice"}
		}
		return m.Facts(install.Account{Name: "alice", UID: 1000}, false), nil
	}
	record := sgStandIn(t, 0)
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("yes\n")
	var out bytes.Buffer
	args := []string{"--no-pull=true", "--hostname=it's $HOME"}
	err := runInit(context.Background(), initOptions{noPull: true, continuation: args}, &out, &out)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.entryCalls) != 1 || !s.entryCalls[0] || s.forgotten != 1 {
		t.Fatalf("entry calls %v, forgotten %d", s.entryCalls, s.forgotten)
	}
	var plan install.Plan
	raw, _ := os.ReadFile(planFile)
	if err := json.Unmarshal(raw, &plan); err != nil {
		t.Fatalf("the entry read %q: %v", raw, err)
	}
	want := install.Decide(p, fake.New(p).Facts(install.Account{Name: "alice", UID: 1000}, false)).Actions
	if !slices.EqualFunc(plan.Actions, want, func(a, b install.Action) bool {
		return a.Kind == b.Kind && slices.Equal(a.Packages, b.Packages) && a.Account == b.Account
	}) || plan.Account != "alice" || plan.UID != 1000 {
		t.Fatalf("the entry was sent %+v", plan)
	}
	self, _ := os.Executable()
	got, _ := os.ReadFile(record)
	wantSg := strings.Join([]string{dir, "docker", "-c", shellQuote(append([]string{self, "init"}, args...))}, "\n") + "\n"
	if string(got) != wantSg {
		t.Errorf("sg ran in and with\n%s\nwant\n%s", got, wantSg)
	}
	text := out.String()
	for _, line := range []string{"→ apt-get update\n", "the continued init ran\n", "Run `newgrp docker` here, or log out and in again, before `cyfr up`."} {
		if !strings.Contains(text, line) {
			t.Errorf("the output lacks %q:\n%s", line, text)
		}
	}
	// The continued init prepared the project; this process did not.
	nothingWritten(t, ".env.example")
}

// TestShellQuoteReadsBackWordForWord runs shellQuote's line through sh, as
// sg does: every word comes back as it was, nothing expanded or run.
func TestShellQuoteReadsBackWordForWord(t *testing.T) {
	words := []string{"/usr/local/bin/cyfr", "init", "--hostname=it's", "--domain=$HOME", "a b", ";touch injected", "`id`", "", "--x=\\'\"'"}
	out, err := exec.Command("/bin/sh", "-c", shellQuote(append([]string{"printf", "%s\\n"}, words...))).Output()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n"); !slices.Equal(got, words) {
		t.Errorf("sh read back %q, want %q", got, words)
	}
}

// TestInitWordsWhatTheEntryLeftFromWhatItObserves reports the entry's
// failure with what the machine shows was completed, and forgets sudo's
// login on every way out: a lock, sudo refusing, a continuation's own
// failure.
func TestInitWordsWhatTheEntryLeftFromWhatItObserves(t *testing.T) {
	p := install.Load()
	lock := event(t, install.Event{Event: install.EventFailed, Failure: install.Fail(install.LockError{Lock: install.LockDpkg})})
	for name, c := range map[string]struct {
		entry   string
		install bool // the machine shows docker.io installed afterwards
		want    string
		status  int
		joined  bool // and alice in the docker group
	}{
		"a held dpkg lock": {"cat >/dev/null; echo " + shQuote(lock) + "; exit 4", false,
			"A package installation is still running after 60 seconds. Nothing was installed. Let it finish, then run `cyfr init` again.", 1, false},
		"a lock after packages": {"cat >/dev/null; echo " + shQuote(lock) + "; exit 4", true,
			"A package installation is still running after 60 seconds. CYFR installed docker.io and docker-compose-v2 and started the Docker service. Let it finish, then run `cyfr init` again.", 1, false},
		"sudo refused": {"echo 'Sorry, user alice may not run sudo' >&2; exit 1", false,
			"This account cannot run sudo, so CYFR cannot install docker.io, docker-compose-v2, the running Docker service and alice's membership of the docker group. Nothing was installed. Run `cyfr init` from an account that can install software.", 1, false},
		"no sudo": {"", false,
			"This account cannot run sudo, so CYFR cannot install", 1, false},
		"the continuation failed": {"cat >/dev/null; echo " + shQuote(event(t, install.Event{Event: install.EventStart, Action: &install.Action{Kind: install.GroupAdd, Account: "alice"}})) + "; exit 0", true,
			"the updated cyfr exited with status 7", 7, true},
	} {
		t.Run(name, func(t *testing.T) {
			newInitProject(t)
			m := fake.New(p)
			s := standInMachine(t, m, c.entry)
			calls := 0
			machine.observe = func(context.Context, install.Policy) (install.Facts, error) {
				calls++
				if calls > 1 && c.install {
					m.Packages["docker.io"], m.Packages["docker-compose-v2"] = "installed", "installed"
					m.Service, m.Enabled = "active", true
				}
				if calls > 1 && c.joined {
					m.Members = []string{"alice"}
				}
				return m.Facts(install.Account{Name: "alice", UID: 1000}, false), nil
			}
			sgStandIn(t, 7)
			askTerminal = func() bool { return false }
			var out bytes.Buffer
			err := runInit(context.Background(), initOptions{noPull: true, yes: true}, &out, &out)
			if err == nil || !strings.HasPrefix(err.Error(), c.want) || ExitStatus(err) != c.status {
				t.Fatalf("runInit = %v (status %d), want %q (status %d)", err, ExitStatus(err), c.want, c.status)
			}
			if len(s.entryCalls) != 1 || s.entryCalls[0] {
				t.Errorf("--yes without a terminal asked the entry for %v, want one non-interactive sudo", s.entryCalls)
			}
			if c.entry != "" && s.forgotten != 1 {
				t.Errorf("sudo's login was forgotten %d times", s.forgotten)
			}
		})
	}
}

// TestRootRunsTheEntryWithoutTheOuterSudosAccount runs `sudo cyfr init`'s
// entry as root itself, without the SUDO_ variables that name the account
// sudo was run from, so the entry takes root for the plan's account.
func TestRootRunsTheEntryWithoutTheOuterSudosAccount(t *testing.T) {
	newInitProject(t)
	p := install.Load()
	m := fake.New(p)
	envFile := filepath.Join(t.TempDir(), "env")
	s := standInMachine(t, m, "cat >/dev/null; env >"+shQuote(envFile)+"; exit 0")
	machine.observe = func(context.Context, install.Policy) (install.Facts, error) {
		return m.Facts(install.Account{Name: "root", UID: 0, Root: true}, true), nil
	}
	t.Setenv("SUDO_UID", "1000")
	t.Setenv("SUDO_USER", "alice")
	askTerminal = func() bool { return false }
	var out bytes.Buffer
	_ = runInit(context.Background(), initOptions{noPull: true, yes: true}, &out, &out)
	if len(s.entryCalls) != 1 {
		t.Fatalf("entry calls %v:\n%s", s.entryCalls, out.String())
	}
	raw, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "SUDO_") {
		t.Errorf("root's entry ran with the outer sudo's variables:\n%s", raw)
	}
}

// TestRootEntryArgvIsExact holds the argv a person's sudo sees: sudo -k
// (no cached login, even if init is killed), -n only without a terminal,
// then the installed program's fixed entry; root runs this program itself.
func TestRootEntryArgvIsExact(t *testing.T) {
	saved := entryChecks
	t.Cleanup(func() { entryChecks = saved })
	entryChecks.sudo = func() (string, error) { return "/usr/bin/sudo", nil }
	entryChecks.installed = func(install.Policy) error { return nil }
	p := install.Load()
	for _, c := range []struct {
		interactive bool
		want        []string
	}{
		{true, []string{"/usr/bin/sudo", "-k", "--", "/usr/local/bin/cyfr", "internal", "install-apply"}},
		{false, []string{"/usr/bin/sudo", "-k", "-n", "--", "/usr/local/bin/cyfr", "internal", "install-apply"}},
	} {
		argv, err := rootEntry(p, false, c.interactive)
		if err != nil || !slices.Equal(argv, c.want) {
			t.Errorf("interactive=%t: %q, %v; want %q", c.interactive, argv, err, c.want)
		}
	}
	self, _ := os.Executable()
	if argv, err := rootEntry(p, true, false); err != nil || !slices.Equal(argv, []string{self, "internal", "install-apply"}) {
		t.Errorf("root: %q, %v", argv, err)
	}
	entryChecks.sudo = func() (string, error) { return "", errors.New("not found") }
	if _, err := rootEntry(p, false, true); !errors.Is(err, errNoSudo) {
		t.Errorf("no sudo: %v", err)
	}
}

// TestInitUnderSudoRefusesWhereItWouldInstall refuses `sudo cyfr init`
// that would install requirements, before anything is shown, run or
// written, and leaves one on a machine that has everything to go on.
func TestInitUnderSudoRefusesWhereItWouldInstall(t *testing.T) {
	newInitProject(t)
	p := install.Load()
	m := fake.New(p)
	s := standInMachine(t, m, "exit 99")
	machine.observe = func(context.Context, install.Policy) (install.Facts, error) {
		return m.Facts(install.Account{Name: "root", UID: 0, Root: true, SudoUser: "alice"}, true), nil
	}
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("yes\n")
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{noPull: true}, &out, &out)
	want := "`sudo cyfr init` would install docker.io, docker-compose-v2 and the running Docker service and set CYFR up for root, not for alice. Nothing was changed. Run `cyfr init` without sudo: it asks for the administrator password itself when it needs one."
	if err == nil || err.Error() != want {
		t.Fatalf("runInit = %v\nwant %s", err, want)
	}
	if len(s.entryCalls) != 0 || strings.Contains(out.String(), "Install these requirements") {
		t.Errorf("it asked or elevated: entry %v\n%s", s.entryCalls, out.String())
	}
	nothingWritten(t, ".env.example")

	// A machine that has everything: init goes on as it always has.
	m.Packages = map[string]string{"docker.io": "installed", "docker-compose-v2": "installed", "apparmor": "installed"}
	m.Service, m.Enabled = "active", true
	askInput = strings.NewReader("3\n")
	if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
		t.Fatalf("a satisfied machine under sudo: %v", err)
	}
}

// TestInitNamesWhySudoRanNothing words a sudo that wanted a password
// nobody could type, or refused the one typed, by that cause.
func TestInitNamesWhySudoRanNothing(t *testing.T) {
	p := install.Load()
	for name, c := range map[string]struct {
		entry    string
		terminal bool
		want     string
	}{
		"no terminal for the password": {"echo 'sudo: interactive authentication is required' >&2; exit 1", false,
			"sudo needs this account's password, and without a terminal there is nowhere to type it, so CYFR cannot install"},
		"the password refused": {"echo 'sudo: Authentication failed, try again.' >&2; echo 'sudo: maximum 3 incorrect authentication attempts' >&2; exit 1", true,
			"sudo did not accept the password, so CYFR cannot install"},
		"not allowed": {"echo \"sudo: I'm sorry alice. I'm afraid I can't do that\" >&2; exit 1", true,
			"This account cannot run sudo, so CYFR cannot install"},
	} {
		t.Run(name, func(t *testing.T) {
			newInitProject(t)
			standInMachine(t, fake.New(p), c.entry)
			askTerminal = func() bool { return c.terminal }
			askInput = strings.NewReader("yes\n")
			var out, errOut bytes.Buffer
			err := runInit(context.Background(), initOptions{noPull: true, yes: true}, &out, &errOut)
			if err == nil || !strings.HasPrefix(err.Error(), c.want) {
				t.Fatalf("runInit = %v, want %q", err, c.want)
			}
		})
	}
}

// TestInstallCommandNamesAPreRelease gives the install script's command
// with CYFR_VERSION for a pre-release, which the script installs only
// when named.
func TestInstallCommandNamesAPreRelease(t *testing.T) {
	saved := version.Version
	t.Cleanup(func() { version.Version = saved })
	version.Version = "0.6.0-alpha.5"
	if got := installCommand(); got != "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=0.6.0-alpha.5 sh" {
		t.Errorf("pre-release: %s", got)
	}
	version.Version = "0.6.0"
	if got := installCommand(); got != "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh" {
		t.Errorf("release: %s", got)
	}
}

// TestRootEntryRefusesAProgramTheAccountCouldChange refuses to run, as
// root, a program at the install path that is missing or that the
// account itself could rewrite.
func TestRootEntryRefusesAProgramTheAccountCouldChange(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("run as root, every file is root's")
	}
	p := install.Load()
	if _, err := os.Stat("/usr/bin/sudo"); err != nil {
		t.Skip("no sudo here")
	}
	p.InstallPath = filepath.Join(t.TempDir(), "cyfr")
	if _, err := rootEntry(p, false, true); err == nil || !strings.Contains(err.Error(), "there is no") {
		t.Errorf("a missing program: %v", err)
	}
	if err := os.WriteFile(p.InstallPath, []byte("#!/bin/sh\necho cyfr version dev\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := rootEntry(p, false, true); err == nil || !strings.Contains(err.Error(), "not a program only root can change") {
		t.Errorf("the account's own program: %v", err)
	}
	argv, err := rootEntry(p, true, false)
	if self, _ := os.Executable(); err != nil || argv[0] != self {
		t.Errorf("root's entry = %v, %v", argv, err)
	}
}

// installApplyRun runs the root entry in this process as root through
// sudo for the account running the test, over m.
func installApplyRun(t *testing.T, m *fake.Machine, plan string) (int, []install.Event, string) {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("SUDO_UID", u.Uid)
	t.Setenv("SUDO_USER", u.Username)
	saved := effectiveUID
	t.Cleanup(func() { effectiveUID = saved })
	effectiveUID = func() int { return 0 }
	var out bytes.Buffer
	status := installApply(context.Background(), m.Host(), strings.NewReader(plan), &out)
	var events []install.Event
	rest := out.String()
	for rest != "" {
		line, tail, _ := strings.Cut(rest, "\n")
		var ev install.Event
		if json.Unmarshal([]byte(line), &ev) != nil {
			break
		}
		events = append(events, ev)
		rest = tail
	}
	return status, events, rest
}

func me(t *testing.T) (string, int) {
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	uid, _ := strconv.Atoi(u.Uid)
	return u.Username, uid
}

// TestInstallApplyAppliesAndEnds runs the plan, reports each action as
// it starts and ends, and ends there: the root entry runs nothing as the
// account.
func TestInstallApplyAppliesAndEnds(t *testing.T) {
	name, uid := me(t)
	if uid == 0 {
		t.Skip("the plan's account is the test's, which must not be root")
	}
	p := install.Load()
	m := fake.New(p)
	d := install.Decide(p, m.Facts(install.Account{Name: name, UID: uid}, false))
	body, _ := json.Marshal(install.Plan{Version: install.PlanVersion, Account: name, UID: uid, Actions: d.Actions})
	status, events, rest := installApplyRun(t, m, string(body))
	if status != 0 || rest != "" {
		t.Fatalf("status %d, output after the events %q", status, rest)
	}
	var started, done []install.Kind
	for _, ev := range events {
		switch ev.Event {
		case install.EventStart:
			started = append(started, ev.Action.Kind)
		case install.EventDone:
			done = append(done, ev.Action.Kind)
		default:
			t.Errorf("event %+v", ev)
		}
	}
	all := []install.Kind{install.AptUpdate, install.AptInstall, install.DockerEnable, install.GroupAdd}
	if !slices.Equal(started, all) || !slices.Equal(done, all) || !slices.Contains(m.Members, name) {
		t.Fatalf("started %v, done %v, members %v", started, done, m.Members)
	}
}

// TestInstallApplyRefusesBeforeChangingAnything refuses a plan it does
// not take, and runs nothing.
func TestInstallApplyRefusesBeforeChangingAnything(t *testing.T) {
	name, uid := me(t)
	p := install.Load()
	for label, plan := range map[string]install.Plan{
		"a package outside the policy": {Version: 1, Account: name, UID: uid, Actions: []install.Action{{Kind: install.AptUpdate}, {Kind: install.AptInstall, Packages: []string{"openssh-server"}}}},
		"another account":              {Version: 1, Account: name + "x", UID: uid + 1, Actions: []install.Action{{Kind: install.DockerEnable}}},
	} {
		t.Run(label, func(t *testing.T) {
			m := fake.New(p)
			body, _ := json.Marshal(plan)
			status, events, _ := installApplyRun(t, m, string(body))
			if status != applyRefused || len(events) != 1 || events[0].Event != install.EventFailed || events[0].Failure.Kind != "invalid" || len(m.Ran) != 0 {
				t.Fatalf("status %d, events %+v, ran %v", status, events, m.Ran)
			}
		})
	}

}
