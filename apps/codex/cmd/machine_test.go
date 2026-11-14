// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
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

// standInMachine stands s in for the machine until t ends. It fails at
// once unless no sh, rm, sudo or docker can be found: PATH is one empty
// folder of the test's, where a test puts its own stand-ins (fakeSudo).
func standInMachine(t *testing.T) *standIn {
	t.Helper()
	t.Setenv("PATH", t.TempDir())
	for _, program := range []string{"sh", "rm", "sudo", "docker"} {
		if found, err := exec.LookPath(program); err == nil {
			t.Fatalf("%s is reachable at %s: no test of the machine may run it", program, found)
		}
	}
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
// on PATH: it appends its arguments, as one line, to the file the variable
// names and runs nothing. -k answers 0, -n 1 (a password is needed), -v
// fakeSudoVerdict's status, and a command 1.
const (
	fakeSudoRecord  = "CYFR_CMD_TEST_FAKE_SUDO"
	fakeSudoVerdict = "CYFR_CMD_TEST_FAKE_SUDO_VERDICT"
)

// fakeSgRecord marks a run of this test binary as the sg sgStandIn names:
// it writes its arguments, one a line, to the file the variable names,
// runs nothing, and exits with fakeSgStatus.
const (
	fakeSgRecord = "CYFR_CMD_TEST_FAKE_SG"
	fakeSgStatus = "CYFR_CMD_TEST_FAKE_SG_STATUS"
)

// runStandIn is this test binary run as the stand-in its name says, sudo
// or sg, when the test that started it set that stand-in's record; ok is
// false for any other run.
func runStandIn() (status int, ok bool) {
	switch name := filepath.Base(os.Args[0]); {
	case name == "sudo" && os.Getenv(fakeSudoRecord) != "":
		return runFakeSudo(os.Getenv(fakeSudoRecord)), true
	case name == "sg" && os.Getenv(fakeSgRecord) != "":
		var lines strings.Builder
		for _, a := range os.Args[1:] {
			lines.WriteString(a + "\n")
		}
		if os.WriteFile(os.Getenv(fakeSgRecord), []byte(lines.String()), 0o600) != nil {
			return 3, true
		}
		status, err := strconv.Atoi(os.Getenv(fakeSgStatus))
		if err != nil {
			return 3, true
		}
		return status, true
	}
	return 0, false
}

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

// standInLink makes path a link to this test binary, which runStandIn
// then runs as the program path names.
func standInLink(t *testing.T, path string) {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(self, path); err != nil {
		t.Fatal(err)
	}
}

// fakeSudo puts this test binary in standInMachine's PATH folder as sudo
// (runFakeSudo), -v answering verdict, and answers the file its calls are
// recorded in. It fails the test unless PATH's sudo is the fake.
func fakeSudo(t *testing.T, verdict string) string {
	t.Helper()
	dir := os.Getenv("PATH")
	standInLink(t, filepath.Join(dir, "sudo"))
	record := filepath.Join(t.TempDir(), "calls")
	t.Setenv(fakeSudoRecord, record)
	t.Setenv(fakeSudoVerdict, verdict)
	if found, err := exec.LookPath("sudo"); err != nil || found != filepath.Join(dir, "sudo") {
		t.Fatalf("PATH's sudo is %q (%v), not the fake", found, err)
	}
	return record
}
