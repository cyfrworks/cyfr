// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"context"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
)

// standInProgram makes the program's own path the one a person's install
// of it in ~/.local/bin has, which the root sentence names.
func standInProgram(t *testing.T) string {
	t.Helper()
	saved := selfExecutable
	t.Cleanup(func() { selfExecutable = saved })
	const self = "/home/person/.local/bin/cyfr"
	selfExecutable = func() (string, error) { return self, nil }
	return self
}

// Once the stack has run on native Linux the server's container owns
// CYFR's storage, which the person's account may then not read. cyfr
// update and cyfr backup each say, before anything stops or is written,
// that they run as root, with this program's own path, since sudo's PATH
// may not hold ~/.local/bin; nothing is stopped and nothing is written.
func TestUpdateAndBackupSayTheyRunAsRootWhereTheStorageIsClosed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	for _, c := range []struct {
		name string
		env  map[string]string
		// closed is the project path the account is refused.
		closed string
		mode   os.FileMode
		what   string
	}{
		{"the storage root holding the database", nil, "data", 0o000, "the SQLite database /app/data/cyfr.db (on the host %s/data/cyfr.db)"},
		{"the database file", nil, "data/cyfr.db", 0o000, "the SQLite database /app/data/cyfr.db (on the host %s/data/cyfr.db)"},
		{"the storage root of a PostgreSQL cell", map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL}, "data", 0o000, "the storage root /app/data (on the host %s/data)"},
	} {
		for _, command := range []string{"update", "backup"} {
			t.Run(c.name+", cyfr "+command, func(t *testing.T) {
				s := newUpdateScenario(t, shippedCompose(t), c.env)
				self := standInProgram(t)
				closed := filepath.Join(s.project, c.closed)
				if err := os.Chmod(closed, c.mode); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { os.Chmod(closed, 0o755) })
				var out string
				var err error
				if command == "update" {
					out, err = s.run(context.Background())
				} else {
					out, err = s.backup()
				}
				what := strings.ReplaceAll(c.what, "%s", s.project)
				want := "cyfr " + command + " cannot read " + what + " as you: the server's container owns CYFR's storage once the stack has run, so run 'sudo " + self + " " + command + "' in this folder; nothing was changed"
				if err == nil || err.Error() != want {
					t.Fatalf("cyfr %s answered %v, want %q:\n%s", command, err, want, out)
				}
				s.nothingStopped()
				s.noBackups()
				s.composeUnchanged()
				if s.hasCall("SCAFFOLD WRITE") {
					t.Error("scaffold files were written")
				}
			})
		}
	}
}

// projectEntries are the project's entries, links not entered, outside
// the storage root data/, which the image's entrypoint hands to the
// image's user.
func projectEntries(t *testing.T) map[string][2]int {
	t.Helper()
	entries := map[string][2]int{}
	err := filepath.WalkDir(".", func(p string, _ fs.DirEntry, err error) error {
		switch {
		case err != nil:
			return err
		case p == ".":
		case p == "data":
			return filepath.SkipDir
		default:
			entries[p] = [2]int{4242, 4343}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return entries
}

// Run as root through sudo, cyfr update gives every entry of the project
// it leaves, outside the storage root, back to the account that ran sudo:
// .env, docker-compose.yml, the release's scaffold files with their
// directories, backups/ and the whole snapshot; the stand-in makes every
// file root's, so no file of the project is left root's.
func TestUpdateThroughSudoLeavesNoProjectFileRoots(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	changed := chownStandIn(t, "4242", "4343", "")
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("cyfr update answered %v\n%s", err, out)
	}
	want := projectEntries(t)
	for _, p := range []string{".env", "docker-compose.yml", "wit/cyfr/added.wit", "backups/.gitignore", "backups/20261016T120000Z/storage/blobs/x"} {
		if _, ok := want[p]; !ok {
			t.Fatalf("the project lacks %s: %v", p, slices.Sorted(maps.Keys(want)))
		}
	}
	if !maps.Equal(changed, want) {
		t.Errorf("cyfr update gave back %v, want %v", slices.Sorted(maps.Keys(changed)), slices.Sorted(maps.Keys(want)))
	}
}

// Run as root through sudo, cyfr backup gives backups/ and the whole
// snapshot back to the account that ran sudo, with .env,
// docker-compose.yml and the managed scaffold files and their
// directories; a person's own file it does not hold stays as it is.
func TestBackupThroughSudoLeavesNoFileItWroteRoots(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	changed := chownStandIn(t, "4242", "4343", "")
	out, err := s.backup()
	if err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	want := projectEntries(t)
	delete(want, "aqua/crew")
	delete(want, "aqua/crew/mine.md")
	if _, ok := want["backups/20261016T120000Z/snapshot.json"]; !ok {
		t.Fatalf("the project holds no snapshot: %v", slices.Sorted(maps.Keys(want)))
	}
	if !maps.Equal(changed, want) {
		t.Errorf("cyfr backup gave back %v, want %v", slices.Sorted(maps.Keys(changed)), slices.Sorted(maps.Keys(want)))
	}
}

// sudo resets HOME and drops what the person exported: run through it,
// cyfr update and cyfr backup do their whole work from the folder's own
// .env and files, with HOME an empty folder and no CYFR_ variable set,
// and write nothing there.
func TestUpdateAndBackupNeedNothingOfHome(t *testing.T) {
	emptyHome := func(t *testing.T) string {
		t.Helper()
		home := t.TempDir()
		t.Setenv("HOME", home)
		for _, kv := range os.Environ() {
			if name, _, _ := strings.Cut(kv, "="); strings.HasPrefix(name, "CYFR_") {
				t.Setenv(name, "")
				os.Unsetenv(name)
			}
		}
		return home
	}
	untouched := func(t *testing.T, home string) {
		t.Helper()
		if entries, err := os.ReadDir(home); err != nil || len(entries) != 0 {
			t.Errorf("HOME holds %v (error %v)", entries, err)
		}
	}
	t.Run("cyfr update", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		home := emptyHome(t)
		out, err := s.run(context.Background())
		if err != nil {
			t.Fatalf("cyfr update answered %v\n%s", err, out)
		}
		if !s.hasCall("SCAFFOLD WRITE") || !s.hasCall("ENGINE start") {
			t.Errorf("cyfr update did not switch and start:\n%s", strings.Join(s.log(), "\n"))
		}
		untouched(t, home)
	})
	t.Run("cyfr backup", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.backupScaffold()
		home := emptyHome(t)
		out, err := s.backup()
		if err != nil || !strings.Contains(out, "The stack runs again.") {
			t.Fatalf("cyfr backup answered %v\n%s", err, out)
		}
		if _, err := readSnapshot(s.snapshotDir()); err != nil {
			t.Errorf("the snapshot does not read: %v", err)
		}
		untouched(t, home)
	})
	t.Run("the program step", func(t *testing.T) {
		s := newProgramScenario(t, "0.9.0", "0.10.0")
		home := emptyHome(t)
		if out, err := s.run(updateOptions{}); err != nil {
			t.Fatalf("cyfr update answered %v\n%s", err, out)
		}
		s.installed("0.10.0")
		untouched(t, home)
	})
}

// Run as root, the program step's new cyfr takes the owner of the one it
// replaces before it is renamed over it: a person's program in
// ~/.local/bin stays the person's.
func TestTheProgramReplacedAsRootKeepsItsOwner(t *testing.T) {
	s := newProgramScenario(t, "0.9.0", "0.10.0")
	changed := chownStandIn(t, "4242", "4343", "")
	if out, err := s.run(updateOptions{}); err != nil {
		t.Fatalf("cyfr update answered %v\n%s", err, out)
	}
	s.installed("0.10.0")
	if len(changed) != 1 {
		t.Fatalf("the program step changed the owners of %v, want its new program's alone", changed)
	}
	for p, owner := range changed {
		if filepath.Dir(p) != filepath.Dir(s.self) || !strings.HasPrefix(filepath.Base(p), ".cyfr.update-") {
			t.Errorf("the owner changed is %s's, want the new program's beside %s", p, s.self)
		}
		var st syscall.Stat_t
		if err := syscall.Stat(s.self, &st); err != nil {
			t.Fatal(err)
		}
		if want := [2]int{int(st.Uid), int(st.Gid)}; owner != want {
			t.Errorf("the new program is given %v, want the old one's owner %v", owner, want)
		}
	}
}
