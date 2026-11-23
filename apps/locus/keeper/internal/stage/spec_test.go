// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package stage

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/protocol"
)

func validSpec() Spec {
	return Spec{
		UID:      20007,
		GID:      20007,
		User:     "cyfr-b007",
		HomeRoot: "/var/lib/locus/homes",
		Home:     "/var/lib/locus/homes/20007-0123456789abcdef0123456789abcdef",
		Argv:     []string{"/bin/sh", "-c", "npx -y pkg"},
		Env:      map[string]string{"NODE_ENV": "production", "API_KEY": "k"},
		Limits:   protocol.Ceilings,
		Cgroup:   "/keeper-20007",
	}
}

func TestEnvironIsBuiltFromNothing(t *testing.T) {
	got := validSpec().Environ()
	want := []string{
		"HOME=/var/lib/locus/homes/20007-0123456789abcdef0123456789abcdef",
		"LOGNAME=cyfr-b007",
		"PATH=" + Path,
		"TMPDIR=/var/lib/locus/homes/20007-0123456789abcdef0123456789abcdef/tmp",
		"USER=cyfr-b007",
		"API_KEY=k",
		"NODE_ENV=production",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environ\n got %q\nwant %q", got, want)
	}
}

func TestValidSpecPasses(t *testing.T) {
	if err := validSpec().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestSpecValidationRefusals(t *testing.T) {
	cases := map[string]func(*Spec){
		"root uid":             func(s *Spec) { s.UID = 0 },
		"root gid":             func(s *Spec) { s.GID = 0 },
		"no user":              func(s *Spec) { s.User = "" },
		"user with newline":    func(s *Spec) { s.User = "a\nb" },
		"home for another uid": func(s *Spec) { s.UID = 20008 },
		"home outside root":    func(s *Spec) { s.Home = "/tmp/20007-0123456789abcdef0123456789abcdef" },
		"reserved env":         func(s *Spec) { s.Env = map[string]string{"HOME": "/"} },
		"no argv":              func(s *Spec) { s.Argv = nil },
		"nofile above ceiling": func(s *Spec) { s.Limits.Nofile = 4096 },
		"zero nproc":           func(s *Spec) { s.Limits.Nproc = 0 },
		"core dumps":           func(s *Spec) { s.Limits.Core = 1 },
		"fsize above ceiling":  func(s *Spec) { s.Limits.Fsize = 1 << 30 },
		"another uid's cgroup": func(s *Spec) { s.Cgroup = "/keeper-20008" },
		"the keeper's cgroup":  func(s *Spec) { s.Cgroup = "/keeper" },
		"the root cgroup":      func(s *Spec) { s.Cgroup = "/" },
		"no cgroup":            func(s *Spec) { s.Cgroup = "" },
	}
	for name, mutate := range cases {
		s := validSpec()
		mutate(&s)
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// A kept program's PATH is CYFR's drivers, then what the person installs
// in the home, then the system's, and npm installs and XDG_BIN_HOME land
// on it; its own variables may name another prefix.
func TestKeptEnvironPutsTheHomeAfterCyfrsDrivers(t *testing.T) {
	kept := validSpec()
	kept.Kept, kept.Home, kept.User = true, "/var/lib/locus/kept/vlt_01a-b", "40001"
	got := kept.Environ()
	want := []string{
		"HOME=/var/lib/locus/kept/vlt_01a-b",
		"LOGNAME=40001",
		"PATH=/opt/cyfr/bin:/var/lib/locus/kept/vlt_01a-b/.local/bin:" + Path,
		"TMPDIR=/var/lib/locus/kept/vlt_01a-b/tmp",
		"USER=40001",
		"API_KEY=k",
		"NODE_ENV=production",
		"NPM_CONFIG_PREFIX=/var/lib/locus/kept/vlt_01a-b/.local",
		"XDG_BIN_HOME=/var/lib/locus/kept/vlt_01a-b/.local/bin",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environ\n got %q\nwant %q", got, want)
	}
	kept.Env = map[string]string{"NPM_CONFIG_PREFIX": "/elsewhere"}
	if got := kept.Environ(); !reflect.DeepEqual(got[len(got)-2:], []string{"NPM_CONFIG_PREFIX=/elsewhere",
		"XDG_BIN_HOME=/var/lib/locus/kept/vlt_01a-b/.local/bin"}) {
		t.Fatalf("a row's own prefix: %q", got)
	}
}

func TestLookPathUsesTheSpawnsPath(t *testing.T) {
	pooled := validSpec()
	if got, err := pooled.LookPath("./relative/tool"); err != nil || got != "./relative/tool" {
		t.Fatalf("a name with a slash was rewritten: %q %v", got, err)
	}
	system, err := pooled.LookPath("sh")
	if err != nil || !strings.HasSuffix(system, "/sh") || !strings.HasPrefix(system, "/") {
		t.Fatalf("sh resolved to %q %v", system, err)
	}
	if _, err := pooled.LookPath("cyfr-locus-no-such-command"); err == nil {
		t.Fatal("a missing command resolved")
	}
	// What a person installs in a kept home is found before the system's,
	// and never for a pooled spawn.
	kept := validSpec()
	kept.Kept, kept.Home = true, t.TempDir()
	bin := filepath.Join(kept.Home, ".local", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sh", "their-tool"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for name, want := range map[string]string{"sh": filepath.Join(bin, "sh"), "their-tool": filepath.Join(bin, "their-tool")} {
		if got, err := kept.LookPath(name); err != nil || got != want {
			t.Errorf("a kept spawn's %s resolved to %q %v, want %q", name, got, err, want)
		}
	}
	pooled.Home = kept.Home
	if got, err := pooled.LookPath("sh"); err != nil || got != system {
		t.Errorf("a pooled spawn's sh resolved to %q %v, want %q", got, err, system)
	}
	if _, err := pooled.LookPath("their-tool"); err == nil {
		t.Error("a pooled spawn found a tool of the home's")
	}
}

// A kept spawn's home is directly under the kept-homes root, named by an
// id, and its group is named for its spawn; a pooled spawn's group may not
// be a spawn's, nor a kept spawn's another uid's.
func TestKeptSpecValidation(t *testing.T) {
	kept := validSpec()
	kept.UID, kept.GID, kept.User = 40001, 40001, "40001"
	kept.HomeRoot, kept.Home, kept.Kept = "/var/lib/locus/kept", "/var/lib/locus/kept/vlt_01a-b", true
	kept.Cgroup = "/keeper-s-0123456789abcdef0123456789abcdef"
	if err := kept.Validate(); err != nil {
		t.Fatal(err)
	}
	kept.Cgroup = "/keeper-40001"
	if err := kept.Validate(); err != nil {
		t.Fatalf("a kept spawn in its uid's group: %v", err)
	}
	for name, mutate := range map[string]func(*Spec){
		"a home below another": func(s *Spec) { s.Home = "/var/lib/locus/kept/a/b" },
		"a home elsewhere":     func(s *Spec) { s.Home = "/var/lib/locus/homes/vlt_a" },
		"another uid's group":  func(s *Spec) { s.Cgroup = "/keeper-40002" },
		"a malformed group":    func(s *Spec) { s.Cgroup = "/keeper-s-xyz" },
	} {
		s := kept
		s.Cgroup = "/keeper-s-0123456789abcdef0123456789abcdef"
		mutate(&s)
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// A kept spawn's file size may be unlimited; a pooled spawn's may not.
	unbounded := kept
	unbounded.Limits.Fsize = protocol.Unlimited
	if err := unbounded.Validate(); err != nil {
		t.Fatalf("a kept spawn with no file-size limit: %v", err)
	}
	scratch := validSpec()
	scratch.Limits.Fsize = protocol.Unlimited
	if err := scratch.Validate(); err == nil {
		t.Fatal("a pooled spawn with no file-size limit was accepted")
	}
	pooled := validSpec()
	pooled.Cgroup = "/keeper-s-0123456789abcdef0123456789abcdef"
	if err := pooled.Validate(); err == nil {
		t.Fatal("a pooled spawn in a spawn's group was accepted")
	}
}
