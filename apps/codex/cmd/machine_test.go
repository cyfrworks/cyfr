// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// standIn is a machine for prepareMachine, a fresh Ubuntu 26.04 unless a
// test says otherwise, recording what it applied.
type standIn struct {
	supported, running, reachableAfter bool
	reachable, displayManager          bool
	arch                               string
	installed, member, process         []string
	applied                            [][]string
	applyErr                           error
	forgotten                          int
}

func standInMachine(t *testing.T) *standIn {
	t.Helper()
	s := &standIn{supported: true, arch: "amd64"}
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
	machine.groups = func(account string) []string {
		if account == "" {
			return s.process
		}
		return s.member
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
