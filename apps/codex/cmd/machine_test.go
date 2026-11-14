// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// standIn is a machine for prepareMachine, a fresh Ubuntu 26.04 unless a
// test says otherwise, run by an administrator whose sudo asks for a
// password, recording what it applied. prompt, when set, is called where
// sudo would show its own password prompt.
type standIn struct {
	supported, running, reachableAfter bool
	reachable, displayManager          bool
	passwordless                       bool
	arch, system                       string
	installed, member, process         []string
	administrator                      []string
	applied                            [][]string
	applyErr, authErr                  error
	authenticated, forgotten           int
	prompt                             func()
}

func standInMachine(t *testing.T) *standIn {
	t.Helper()
	s := &standIn{supported: true, arch: "amd64", system: "linux", administrator: []string{"sudo"}}
	saved, savedTerminal, savedInput, savedSg := machine, askTerminal, askInput, sgProgram
	t.Cleanup(func() { machine, askTerminal, askInput, sgProgram = saved, savedTerminal, savedInput, savedSg })
	// No test reaches the real sg, which would run this test binary again.
	sgProgram = "/bin/false"
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("yes\n")
	machine.supported = func() bool { return s.supported }
	machine.arch = func() string { return s.arch }
	machine.reachable = func() bool { return s.reachable }
	machine.installed = func(pkg string) bool { return slices.Contains(s.installed, pkg) }
	machine.running = func() bool { return s.running }
	machine.displayManager = func() bool { return s.displayManager }
	machine.system = func() string { return s.system }
	machine.groups = func(account string) []string {
		if account == "" {
			return s.process
		}
		return append(slices.Clone(s.member), s.administrator...)
	}
	machine.passwordless = func() bool { return s.passwordless }
	machine.authenticate = func() error {
		s.authenticated++
		if s.prompt != nil {
			s.prompt()
		}
		return s.authErr
	}
	machine.apply = func(commands []string) error {
		s.applied = append(s.applied, commands)
		if slices.ContainsFunc(commands, func(c string) bool { return strings.HasPrefix(c, "usermod") }) {
			s.member = append(s.member, dockerGroup)
		}
		s.reachable = s.reachableAfter
		return s.applyErr
	}
	machine.forget = func() { s.forgotten++ }
	return s
}

// initProjectOnScreen makes the working directory a new project for cyfr
// init, with a compose file and the fake engine, on a machine that can
// show CYFR, at a terminal, whose Docker answers this account.
func initProjectOnScreen(t *testing.T) (*standIn, *fakeStack) {
	t.Helper()
	dir, err := filepath.EvalSymlinks(newInitProject(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	if err := os.WriteFile("docker-compose.yml", []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	engine := useFakeEngine(t)
	s := standInMachine(t)
	s.reachable = true
	return s, engine
}

// fakeSudoRecord marks a run of this test binary as the sudo fakeSudo put
// first on PATH: it appends its arguments, as one line, to the file the
// variable names and runs nothing. -k answers 0, -n 1 (a password is
// needed), -v fakeSudoVerdict's status, and a command 1.
const (
	fakeSudoRecord  = "CYFR_CMD_TEST_FAKE_SUDO"
	fakeSudoVerdict = "CYFR_CMD_TEST_FAKE_SUDO_VERDICT"
)

func runFakeSudo(record string) int {
	f, err := os.OpenFile(record, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return 3
	}
	_, err = f.WriteString(strings.Join(os.Args[1:], " ") + "\n")
	if f.Close() != nil || err != nil {
		return 3
	}
	switch first := append(os.Args[1:], "")[0]; first {
	case "-k":
		return 0
	case "-v":
		if os.Getenv(fakeSudoVerdict) == "0" {
			return 0
		}
	}
	return 1
}

// fakeSudo puts this test binary first on PATH as sudo (runFakeSudo), -v
// answering verdict, and answers the file its calls are recorded in. It
// fails the test unless PATH's sudo is the fake.
func fakeSudo(t *testing.T, verdict string) string {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.Symlink(self, filepath.Join(dir, "sudo")); err != nil {
		t.Fatal(err)
	}
	record := filepath.Join(dir, "calls")
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv(fakeSudoRecord, record)
	t.Setenv(fakeSudoVerdict, verdict)
	if found, err := exec.LookPath("sudo"); err != nil || found != filepath.Join(dir, "sudo") {
		t.Fatalf("PATH's sudo is %q (%v), not the fake", found, err)
	}
	return record
}
