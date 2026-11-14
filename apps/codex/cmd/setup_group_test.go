// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// cyfr setup in a terminal older than the account's docker group runs
// itself again through sg with the flags given, before it serves anything,
// so the pages' run reaches Docker; that run's status is cyfr setup's.
func TestSetupContinuesInATerminalOlderThanTheGroup(t *testing.T) {
	for _, status := range []string{"0", "3"} {
		t.Run("status "+status, func(t *testing.T) {
			s := standInMachine(t)
			s.member = []string{"docker"}
			record := sgStandIn(t, status)
			t.Chdir(t.TempDir())
			continued, err := setupWithGroup([]string{"--no-open=true"}, &bytes.Buffer{}, &bytes.Buffer{})
			answered := "0"
			if err != nil {
				answered = strconv.Itoa(ExitStatus(err))
			}
			if !continued || answered != status {
				t.Fatalf("continued %t, err %v, want the status %s", continued, err, status)
			}
			self, _ := os.Executable()
			sg, err := os.ReadFile(record)
			if err != nil {
				t.Fatal(err)
			}
			if got, want := string(sg), "docker\n-c\n"+shellQuote([]string{self, "setup", "--no-open=true"})+"\n"; got != want {
				t.Errorf("sg ran %q, want %q", got, want)
			}
			nothingWritten(t)
		})
	}
}

// cyfr setup carries on as it is when Docker already answers this
// account, a rootless Docker or a group the account holds already among
// them, and when sg has nothing to give it or there is no sg.
func TestSetupNeedsNoContinuation(t *testing.T) {
	for name, set := range map[string]func(*standIn){
		"Docker answers":     func(s *standIn) { s.reachable = true },
		"another system":     func(s *standIn) { s.supported = false },
		"not in the group":   func(s *standIn) { s.member = nil },
		"the process has it": func(s *standIn) { s.process = []string{"docker"} },
		"no sg":              func(*standIn) { sgProgram = filepath.Join(os.TempDir(), "no-such-sg") },
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			s.member = []string{"docker"}
			record := sgStandIn(t, "0")
			set(s)
			if continued, err := setupWithGroup(nil, &bytes.Buffer{}, &bytes.Buffer{}); continued || err != nil {
				t.Fatalf("continued %t, err %v", continued, err)
			}
			if _, err := os.Stat(record); err == nil {
				t.Error("sg ran")
			}
		})
	}
}
