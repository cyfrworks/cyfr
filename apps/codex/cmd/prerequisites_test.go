// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/install"
	"github.com/cyfr/codex/internal/install/fake"
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

// TestInitInstallsThroughOneEntryAndContinues agrees, runs the root entry
// once with the agreed plan on its input, shows its actions, hands the
// rest of the run to the continued init, offers newgrp before `cyfr up`,
// and forgets sudo's login.
func TestInitInstallsThroughOneEntryAndContinues(t *testing.T) {
	dir := newInitProject(t)
	p := install.Load()
	m := fake.New(p)
	planFile := filepath.Join(t.TempDir(), "plan.json")
	entry := "cat \"$1\" >" + shQuote(planFile) + "; " +
		"echo " + shQuote(event(t, install.Event{Event: install.EventStart, Action: &install.Action{Kind: install.AptUpdate}})) + "; " +
		"echo " + shQuote(event(t, install.Event{Event: install.EventContinue})) + "; " +
		"echo 'the continued init ran'; exit 0"
	s := standInMachine(t, m, entry)
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("yes\n")
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{noPull: true, continuation: []string{"--no-pull=true"}}, &out, &out)
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
	want := install.Decide(p, m.Facts(install.Account{Name: "alice", UID: 1000}, false)).Actions
	if !slices.EqualFunc(plan.Actions, want, func(a, b install.Action) bool {
		return a.Kind == b.Kind && slices.Equal(a.Packages, b.Packages) && a.Account == b.Account
	}) ||
		plan.Account != "alice" || plan.UID != 1000 || plan.Continue == nil || plan.Continue.Dir != dir || !slices.Equal(plan.Continue.Args, []string{"--no-pull=true"}) || !plan.Continue.Terminal {
		t.Fatalf("the entry was sent %+v", plan)
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
	}{
		"a held dpkg lock": {"cat \"$1\" >/dev/null; echo " + shQuote(lock) + "; exit 4", false,
			"A package installation is still running after 60 seconds. Nothing was installed. Let it finish, then run `cyfr init` again.", 1},
		"a lock after packages": {"cat \"$1\" >/dev/null; echo " + shQuote(lock) + "; exit 4", true,
			"A package installation is still running after 60 seconds. CYFR installed docker.io and docker-compose-v2 and started the Docker service. Let it finish, then run `cyfr init` again.", 1},
		// sudo refusing never opens the plan's FIFO.
		"sudo refused": {"echo 'Sorry, user alice may not run sudo' >&2; exit 1", false,
			"This account cannot run sudo, so CYFR cannot install docker.io, docker-compose-v2, the running Docker service and alice's membership of the docker group. Nothing was installed. Run `cyfr init` from an account that can install software.", 1},
		"no sudo": {"", false,
			"This account cannot run sudo, so CYFR cannot install", 1},
		"the continuation failed": {"cat \"$1\" >/dev/null; echo " + shQuote(event(t, install.Event{Event: install.EventContinue})) + "; exit 7", true,
			"the updated cyfr exited with status 7", 7},
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
				return m.Facts(install.Account{Name: "alice", UID: 1000}, false), nil
			}
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
	s := standInMachine(t, m, "cat \"$1\" >/dev/null; env >"+shQuote(envFile)+"; exit 0")
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

// TestOpenPlanTakesOnlyTheCallersPrivateFIFO opens the FIFO cyfr init
// makes, and refuses a regular file, a FIFO in a directory others can
// enter, another account's, and a link to a FIFO.
func TestOpenPlanTakesOnlyTheCallersPrivateFIFO(t *testing.T) {
	_, uid := me(t)
	saved := planWait
	t.Cleanup(func() { planWait = saved })
	planWait = 2 * time.Second
	// feed writes to the FIFO path, as cyfr init does, so an open that
	// should have been refused completes rather than waits.
	feed := func(path string) {
		go func() {
			if f, err := os.OpenFile(path, os.O_WRONLY, 0); err == nil {
				_, _ = f.Write([]byte("{}\n"))
				_ = f.Close()
			}
		}()
	}
	dir, err := os.MkdirTemp(t.TempDir(), "plan-")
	if err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "plan")
	if err := makeFIFO(fifo); err != nil {
		t.Fatal(err)
	}
	feed(fifo)
	f, err := openPlan(fifo, uid)
	if err != nil {
		t.Fatalf("the caller's FIFO: %v", err)
	}
	if raw, _ := io.ReadAll(f); string(raw) != "{}\n" {
		t.Errorf("read %q from the FIFO", raw)
	}
	_ = f.Close()

	feed(fifo)
	if f, err := openPlan(fifo, uid+1); err == nil {
		_ = f.Close()
		t.Error("another account's FIFO was opened")
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(fifo, link); err != nil {
		t.Fatal(err)
	}
	if f, err := openPlan(link, uid); err == nil {
		_ = f.Close()
		t.Error("a link to the FIFO was opened")
	}
	regular := filepath.Join(dir, "regular")
	if err := os.WriteFile(regular, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := openPlan(regular, uid); err == nil {
		t.Error("a regular file was opened")
	}
	open := t.TempDir()
	if err := os.Chmod(open, 0o755); err != nil {
		t.Fatal(err)
	}
	shared := filepath.Join(open, "plan")
	if err := makeFIFO(shared); err != nil {
		t.Fatal(err)
	}
	feed(shared)
	if f, err := openPlan(shared, uid); err == nil {
		_ = f.Close()
		t.Error("a FIFO in a directory others can enter was opened")
	}

	// No writer ever comes: the wait ends at its bound.
	alone := filepath.Join(dir, "alone")
	if err := makeFIFO(alone); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if f, err := openPlan(alone, uid); err == nil || time.Since(start) > 10*time.Second {
		if f != nil {
			_ = f.Close()
		}
		t.Errorf("a FIFO with no writer: %v after %s", err, time.Since(start))
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
	var out, errOut bytes.Buffer
	status := installApply(context.Background(), m.Host(), strings.NewReader(plan), strings.NewReader(""), &out, &errOut)
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
		if ev.Event == install.EventContinue {
			break
		}
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

// TestInstallApplyAppliesThenContinuesAsTheAccount runs the plan, reports
// each action, then continues init as the account in its directory
// through sudo -u with a fresh environment, its status the entry's.
func TestInstallApplyAppliesThenContinuesAsTheAccount(t *testing.T) {
	name, uid := me(t)
	if uid == 0 {
		t.Skip("the plan's account is the test's, which must not be root")
	}
	p := install.Load()
	m := fake.New(p)
	dir := t.TempDir()
	record := filepath.Join(t.TempDir(), "continued")
	script := filepath.Join(t.TempDir(), "sudo")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n{ pwd; printf '%s\\n' \"$@\"; env; } >"+shQuote(record)+"\necho 'init continued'\nexit 5\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	saved := continueProgram
	t.Cleanup(func() { continueProgram = saved })
	continueProgram = script
	d := install.Decide(p, m.Facts(install.Account{Name: name, UID: uid}, false))
	body, _ := json.Marshal(install.Plan{Version: install.PlanVersion, Account: name, UID: uid, Actions: d.Actions,
		Continue: &install.Continuation{Dir: dir, Args: []string{"--access=local"}}})

	status, events, rest := installApplyRun(t, m, string(body))
	if status != 5 || rest != "init continued\n" {
		t.Fatalf("status %d, output after the events %q", status, rest)
	}
	var started []install.Kind
	for _, ev := range events {
		if ev.Event == install.EventStart {
			started = append(started, ev.Action.Kind)
		}
	}
	if !slices.Equal(started, []install.Kind{install.AptUpdate, install.AptInstall, install.DockerEnable, install.GroupAdd}) || events[len(events)-1].Event != install.EventContinue {
		t.Fatalf("events %+v", events)
	}
	if !slices.Contains(m.Members, name) {
		t.Errorf("the group lists %v", m.Members)
	}
	raw, _ := os.ReadFile(record)
	lines := strings.Split(string(raw), "\n")
	wantArgs := []string{dir, "-n", "-k", "-u", name, "-H", "--", p.InstallPath, "init", "--access=local", "--no-interactive"}
	if !slices.Equal(lines[:len(wantArgs)], wantArgs) {
		t.Errorf("the continuation ran in and with %q, want %q", lines[:len(wantArgs)], wantArgs)
	}
	for _, line := range lines[len(wantArgs):] {
		if strings.HasPrefix(line, "SUDO_") || strings.HasPrefix(line, "HOME=") {
			t.Errorf("the continuation's environment carries %q", line)
		}
	}
}

// TestInstallApplyRefusesBeforeChangingAnything refuses a plan it does
// not take, and a continuation into a directory not the account's, and
// runs nothing.
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
	if uid == 0 {
		return
	}
	t.Run("a directory that is not the account's", func(t *testing.T) {
		m := fake.New(p)
		saved := continueProgram
		t.Cleanup(func() { continueProgram = saved })
		continueProgram = "/bin/false"
		d := install.Decide(p, m.Facts(install.Account{Name: name, UID: uid}, false))
		body, _ := json.Marshal(install.Plan{Version: 1, Account: name, UID: uid, Actions: d.Actions,
			Continue: &install.Continuation{Dir: "/", Args: nil}})
		status, events, _ := installApplyRun(t, m, string(body))
		if status != applyRefused || len(events) != 1 || events[0].Failure == nil || events[0].Failure.Kind != "invalid" || len(m.Ran) != 0 {
			t.Fatalf("status %d, events %+v, ran %v", status, events, m.Ran)
		}
	})
}
