// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package stage

import (
	"reflect"
	"strings"
	"testing"

	"github.com/cyfr/spawn/internal/protocol"
)

func validSpec() Spec {
	return Spec{
		UID:      20007,
		GID:      20007,
		User:     "cyfr-b007",
		HomeRoot: "/var/lib/cyfr-bridge/homes",
		Home:     "/var/lib/cyfr-bridge/homes/20007-0123456789abcdef0123456789abcdef",
		Argv:     []string{"/bin/sh", "-c", "npx -y pkg"},
		Env:      map[string]string{"NODE_ENV": "production", "API_KEY": "k"},
		Limits:   protocol.Ceilings,
	}
}

func TestEnvironIsBuiltFromNothing(t *testing.T) {
	got := validSpec().Environ()
	want := []string{
		"HOME=/var/lib/cyfr-bridge/homes/20007-0123456789abcdef0123456789abcdef",
		"LOGNAME=cyfr-b007",
		"PATH=" + Path,
		"TMPDIR=/var/lib/cyfr-bridge/homes/20007-0123456789abcdef0123456789abcdef/tmp",
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
	}
	for name, mutate := range cases {
		s := validSpec()
		mutate(&s)
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestLookPathUsesOnlyTheFixedPath(t *testing.T) {
	if got, err := LookPath("./relative/tool"); err != nil || got != "./relative/tool" {
		t.Fatalf("a name with a slash was rewritten: %q %v", got, err)
	}
	got, err := LookPath("sh")
	if err != nil || !strings.HasSuffix(got, "/sh") || !strings.HasPrefix(got, "/") {
		t.Fatalf("sh resolved to %q %v", got, err)
	}
	if _, err := LookPath("cyfr-spawn-no-such-command"); err == nil {
		t.Fatal("a missing command resolved")
	}
}
