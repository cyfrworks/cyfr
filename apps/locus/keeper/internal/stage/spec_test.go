// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package stage

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/pool"
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
		Reach:    pool.ReachRouted,
		Cgroup:   "/keeper-20007",
	}
}

func TestEnvironIsBuiltFromNothing(t *testing.T) {
	got := validSpec().Environ()
	want := []string{
		"HOME=/var/lib/locus/homes/20007-0123456789abcdef0123456789abcdef",
		"LOGNAME=cyfr-b007",
		"PATH=" + Path,
		"TMPDIR=/tmp",
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
		"the keeper's cgroup":  func(s *Spec) { s.Cgroup = "/service/keeper" },
		"the root cgroup":      func(s *Spec) { s.Cgroup = "/" },
		"no cgroup":            func(s *Spec) { s.Cgroup = "" },
		"no reach":             func(s *Spec) { s.Reach = "" },
		"an unknown reach":     func(s *Spec) { s.Reach = "netns" },
	}
	for name, mutate := range cases {
		s := validSpec()
		mutate(&s)
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// keptHome and keptWork are a home and its disk's work folder under the
// shipped kept-homes root.
const (
	keptRoot = "/var/lib/locus/kept"
	keptDisk = keptRoot + "/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	keptHome = keptDisk + "/programs/vlt_01a-b"
	keptWork = keptDisk + "/work"
)

// A kept program's PATH is CYFR's drivers, then what it installs in its
// own home, then what the person installs for every program in /work, then
// the system's, and npm installs and XDG_BIN_HOME land in /work; its own
// variables may name another prefix.
func TestKeptEnvironPutsTheHomeAfterCyfrsDrivers(t *testing.T) {
	kept := validSpec()
	kept.Kept, kept.Home, kept.Work, kept.User = true, keptHome, keptWork, "40001"
	got := kept.Environ()
	want := []string{
		"HOME=" + keptHome,
		"LOGNAME=40001",
		"PATH=/opt/cyfr/bin:" + keptHome + "/.local/bin:/work/.local/bin:" + Path,
		"TMPDIR=/tmp",
		"USER=40001",
		"API_KEY=k",
		"NODE_ENV=production",
		"NPM_CONFIG_PREFIX=/work/.local",
		"XDG_BIN_HOME=/work/.local/bin",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("environ\n got %q\nwant %q", got, want)
	}
	kept.Env = map[string]string{"NPM_CONFIG_PREFIX": "/elsewhere"}
	if got := kept.Environ(); !reflect.DeepEqual(got[len(got)-2:], []string{"NPM_CONFIG_PREFIX=/elsewhere",
		"XDG_BIN_HOME=/work/.local/bin"}) {
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

// A kept spawn's home is on a disk directly under the kept-homes root,
// named by an id, with that disk's work folder, and its group is named for
// its spawn; a pooled spawn's group may not be a spawn's, nor a kept
// spawn's another uid's, and only a kept spawn has a work folder.
func TestKeptSpecValidation(t *testing.T) {
	kept := validSpec()
	kept.UID, kept.GID, kept.User = 40001, 40001, "40001"
	kept.HomeRoot, kept.Home, kept.Work, kept.Kept, kept.KeptRoot = keptRoot, keptHome, keptWork, true, keptRoot
	kept.Cgroup = "/keeper-s-0123456789abcdef0123456789abcdef"
	if err := kept.Validate(); err != nil {
		t.Fatal(err)
	}
	kept.Cgroup = "/keeper-40001"
	if err := kept.Validate(); err != nil {
		t.Fatalf("a kept spawn in its uid's group: %v", err)
	}
	for name, mutate := range map[string]func(*Spec){
		"a home below another":                  func(s *Spec) { s.Home = keptHome + "/b" },
		"a home elsewhere":                      func(s *Spec) { s.Home = "/var/lib/locus/homes/vlt_a" },
		"a home of the layout before the disks": func(s *Spec) { s.Home = keptRoot + "/vlt_01a-b" },
		"another disk's work folder": func(s *Spec) {
			s.Work = keptRoot + "/fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210/work"
		},
		"no work folder":              func(s *Spec) { s.Work = "" },
		"no kept root to cover":       func(s *Spec) { s.KeptRoot = "" },
		"another kept root":           func(s *Spec) { s.KeptRoot = "/opt/kept" },
		"a kept root not clean":       func(s *Spec) { s.KeptRoot, s.HomeRoot = keptRoot+"/", keptRoot+"/" },
		"the disk as its home":        func(s *Spec) { s.Home = keptDisk },
		"the work folder as its home": func(s *Spec) { s.Home = keptWork },
		"another uid's group":         func(s *Spec) { s.Cgroup = "/keeper-40002" },
		"a malformed group":           func(s *Spec) { s.Cgroup = "/keeper-s-xyz" },
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
	worked := validSpec()
	worked.Work = keptWork
	if err := worked.Validate(); err == nil {
		t.Fatal("a pooled spawn with a work folder was accepted")
	}
}

// A role's spec is its run folder under the run root, a routed space with
// its channel, its whole environment as the keeper built it, the keeper's
// own limits, and its role's leaf; a spawn's group may be in a role's.
func TestRoleSpecValidation(t *testing.T) {
	role := Spec{
		UID: 10011, GID: 10011, User: "locus-runtime", Role: "runtime",
		HomeRoot: "/run/locus", Home: "/run/locus/runtime",
		Argv:    []string{"/app/bin/locus", "start"},
		Env:     map[string]string{"HOME": "/run/locus/runtime", "PATH": "/usr/bin:/bin", "LOCUS_RUNTIME_KEY": "k", "KEEPER_CHANNEL": "socket:[1]"},
		Control: true, Reach: pool.ReachRouted, Cgroup: "/service/runtime",
	}
	if err := role.Validate(); err != nil {
		t.Fatal(err)
	}
	if got, want := role.Environ(), []string{"HOME=/run/locus/runtime", "KEEPER_CHANNEL=socket:[1]", "LOCUS_RUNTIME_KEY=k", "PATH=/usr/bin:/bin"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("a role's environ %q, want %q", got, want)
	}
	if role.SearchPath() != "/usr/bin:/bin" {
		t.Fatalf("a role's PATH %q", role.SearchPath())
	}
	for name, mutate := range map[string]func(*Spec){
		"another role's folder": func(s *Spec) { s.Home = "/run/locus/builds" },
		"a relative run root":   func(s *Spec) { s.HomeRoot, s.Home = "run", "run/runtime" },
		"a malformed role":      func(s *Spec) { s.Role, s.Home, s.Cgroup = "Run", "/run/locus/Run", "/service/Run" },
		"a relay space":         func(s *Spec) { s.Reach = pool.ReachRelay },
		"no channel":            func(s *Spec) { s.Control = false },
		"a terminal":            func(s *Spec) { s.Terminal = true },
		"a kept home":           func(s *Spec) { s.Kept = true },
		"limits of its own":     func(s *Spec) { s.Limits = protocol.Ceilings },
		"another role's leaf":   func(s *Spec) { s.Cgroup = "/service/builds" },
		"a spawn's group":       func(s *Spec) { s.Cgroup = "/work/runtime/keeper-10011" },
		"a malformed variable":  func(s *Spec) { s.Env = map[string]string{"A=B": "c"} },
		"a NUL in a value":      func(s *Spec) { s.Env = map[string]string{"A": "b\x00"} },
		"no command":            func(s *Spec) { s.Argv = nil },
		"root":                  func(s *Spec) { s.UID = 0 },
	} {
		s := role
		mutate(&s)
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	inRole := validSpec()
	inRole.Cgroup = "/work/rest/builds/keeper-20007"
	if err := inRole.Validate(); err != nil {
		t.Fatalf("a spawn in its role's group: %v", err)
	}
	inRole.Cgroup = "/work/rest/builds/keeper-20008"
	if err := inRole.Validate(); err == nil {
		t.Fatal("a spawn in another uid's group of its role was accepted")
	}
	inRole.Cgroup = "/other/keeper-20007"
	if err := inRole.Validate(); err == nil {
		t.Fatal("a spawn in a group that is no role's was accepted")
	}
}

// A spawn's packs name a pack generation, .packs/<64 hex>/<64 hex>, by a
// clean absolute path; a role's space binds none.
func TestPacksSpecValidation(t *testing.T) {
	gen := "/var/lib/locus/kept/.packs/" + strings.Repeat("a", 64) + "/" + strings.Repeat("b", 64)
	s := validSpec()
	s.Packs = gen
	if err := s.Validate(); err != nil {
		t.Fatalf("a spawn naming a generation: %v", err)
	}
	for _, p := range []string{
		"relative/.packs/" + strings.Repeat("a", 64) + "/" + strings.Repeat("b", 64),
		gen + "/",
		"/var/lib/locus/kept/.packs/" + strings.Repeat("a", 64) + "/../" + strings.Repeat("b", 64),
		"/var/lib/locus/kept/packs/" + strings.Repeat("a", 64) + "/" + strings.Repeat("b", 64),
		"/var/lib/locus/kept/.packs/" + strings.Repeat("a", 63) + "/" + strings.Repeat("b", 64),
		"/etc",
	} {
		s := validSpec()
		s.Packs = p
		if err := s.Validate(); err == nil {
			t.Errorf("packs %q passed", p)
		}
	}
}

// A person's machine's space holds its VMM: a relay space whose home is its
// folder, given its device, and nothing a spawn's channels give.
func TestMachineSpecValidation(t *testing.T) {
	machine := Spec{
		UID: 30201, GID: 993, User: "locus-machine",
		HomeRoot: "/run/locus/machines", Home: "/run/locus/machines/30201-0123456789abcdef0123456789abcdef",
		Argv:    []string{"/usr/lib/cyfr/guest/firecracker", "--api-sock", "/run/locus/machines/30201-0123456789abcdef0123456789abcdef/api.sock"},
		Limits:  protocol.Limits{Nofile: 256, Nproc: 64, Fsize: 1 << 20},
		Reach:   pool.ReachRelay,
		Cgroup:  "/keeper-30201",
		Machine: "/var/lib/locus/guest/" + strings.Repeat("a", 64) + ".sqfs",
	}
	if err := machine.Validate(); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*Spec){
		"a relative device":        func(s *Spec) { s.Machine = "guest/a.sqfs" },
		"an unclean device":        func(s *Spec) { s.Machine = "/var/lib/locus/guest/../kept/a.sqfs" },
		"a device of another kind": func(s *Spec) { s.Machine = "/var/lib/locus/kept/a" },
		"a routed space":           func(s *Spec) { s.Reach = pool.ReachRouted },
		"a control channel":        func(s *Spec) { s.Control = true },
		"a terminal":               func(s *Spec) { s.Terminal = true },
		"a kept home":              func(s *Spec) { s.Kept = true },
		"root's group":             func(s *Spec) { s.GID = 0 },
		"another uid's folder":     func(s *Spec) { s.UID, s.Cgroup = 30202, "/keeper-30202" },
	} {
		s := machine
		mutate(&s)
		if err := s.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
