// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/scaffold"
)

// standInProgram makes the program's own path self, as a person's install
// of it in ~/.local/bin has it, which the root sentence names.
func standInProgram(t *testing.T, self string) {
	t.Helper()
	saved := selfExecutable
	t.Cleanup(func() { selfExecutable = saved })
	selfExecutable = func() (string, error) { return self, nil }
}

// closeInProject takes every permission off the project path rel, given
// back at the test's end.
func closeInProject(t *testing.T, s *updateScenario, rel string) {
	t.Helper()
	closed := filepath.Join(s.project, rel)
	if err := os.Chmod(closed, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(closed, 0o755) })
}

// Once the stack has run on native Linux the server's container owns
// CYFR's storage, which the person's account may then not read. cyfr
// update and cyfr backup each say, before anything stops or is written,
// that they run as root, with this program's own path, since sudo's PATH
// may not hold ~/.local/bin, quoted for a shell where it needs it.
func TestUpdateAndBackupSayTheyRunAsRootWhereTheStorageIsClosed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	for _, c := range []struct {
		name   string
		env    map[string]string
		closed string
		what   string
		self   string
		shown  string
	}{
		{"the storage root holding the database", nil, "data", "the SQLite database /app/data/cyfr.db (on the host %s/data/cyfr.db)", "/home/person/.local/bin/cyfr", "/home/person/.local/bin/cyfr"},
		{"the database file", nil, "data/cyfr.db", "the SQLite database /app/data/cyfr.db (on the host %s/data/cyfr.db)", "/home/person/.local/bin/cyfr", "/home/person/.local/bin/cyfr"},
		{"the storage root of a PostgreSQL cell", map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL}, "data", "the storage root /app/data (on the host %s/data)", "/home/person/.local/bin/cyfr", "/home/person/.local/bin/cyfr"},
		{"a program whose path holds a space", nil, "data", "the SQLite database /app/data/cyfr.db (on the host %s/data/cyfr.db)", "/home/a person/.local/bin/cyfr", "'/home/a person/.local/bin/cyfr'"},
	} {
		for _, command := range []string{"update", "backup"} {
			t.Run(c.name+", cyfr "+command, func(t *testing.T) {
				s := newUpdateScenario(t, shippedCompose(t), c.env)
				standInProgram(t, c.self)
				closeInProject(t, s, c.closed)
				var out string
				var err error
				if command == "update" {
					out, err = s.run(context.Background())
				} else {
					out, err = s.backup()
				}
				what := strings.ReplaceAll(c.what, "%s", s.project)
				want := "cyfr " + command + " cannot read " + what + " as you: the server's container owns CYFR's storage once the stack has run, so nothing was changed; run it as root in this folder: sudo " + c.shown + " " + command
				if err == nil || err.Error() != want {
					t.Fatalf("cyfr %s answered %v, want %q:\n%s", command, err, want, out)
				}
				if s.engine.locks != 0 {
					t.Errorf("cyfr %s took the stack's lock before it refused", command)
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

// tree is every entry under the working directory, links not entered, by
// its path: its mode, and a file's bytes or a link's target; a directory
// this account may not enter is its mode alone.
func tree(t *testing.T) map[string]string {
	t.Helper()
	entries := map[string]string{}
	err := filepath.WalkDir(".", func(p string, d fs.DirEntry, err error) error {
		info, lerr := os.Lstat(p)
		if lerr != nil {
			return lerr
		}
		entry := info.Mode().String()
		switch {
		case err != nil && d != nil && d.IsDir():
			entries[p] = entry
			return filepath.SkipDir
		case err != nil:
			return err
		case info.Mode()&fs.ModeSymlink != 0:
			target, _ := os.Readlink(p)
			entry += " -> " + target
		case info.Mode().IsRegular():
			data, rerr := os.ReadFile(p)
			if rerr != nil {
				entry += " (closed)"
			} else {
				entry += " " + string(data)
			}
		}
		entries[p] = entry
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return entries
}

// With the real engine and its real lock, a closed database in a folder
// with no .cyfr/ yet: cyfr update and cyfr backup refuse before the lock
// and before recovery, and the folder is left as it was, byte for byte.
func TestTheRootRefusalWritesNothingWithTheRealLock(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	for _, command := range []string{"update", "backup"} {
		t.Run("cyfr "+command, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			standInProgram(t, "/home/person/.local/bin/cyfr")
			openEngine = func(dir string) (stackEngine, error) { return access.Open(dir, nil) }
			if _, err := os.Lstat(filepath.Join(s.project, ".cyfr")); !errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("the project holds .cyfr already (%v)", err)
			}
			closeInProject(t, s, "data/cyfr.db")
			before := tree(t)
			var out string
			var err error
			if command == "update" {
				out, err = s.run(context.Background())
			} else {
				out, err = s.backup()
			}
			if err == nil || !strings.Contains(err.Error(), "run it as root in this folder: sudo /home/person/.local/bin/cyfr "+command) {
				t.Fatalf("cyfr %s answered %v:\n%s", command, err, out)
			}
			if after := tree(t); !maps.Equal(after, before) {
				t.Errorf("the folder changed:\nbefore %v\nafter  %v", before, after)
			}
		})
	}
}

// releaseTarball is a real scaffold release of files, each a regular
// file unless its name ends in "/".
func releaseTarball(t *testing.T, files map[string]string) *scaffold.Release {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, name := range slices.Sorted(maps.Keys(files)) {
		h := &tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(files[name]))}
		if strings.HasSuffix(name, "/") {
			h = &tar.Header{Name: name, Typeflag: tar.TypeDir, Mode: 0o755}
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			if _, err := tw.Write([]byte(files[name])); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := errors.Join(tw.Close(), gz.Close()); err != nil {
		t.Fatal(err)
	}
	r, err := scaffold.Parse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// realScaffold is the scenario's scaffold whose files are a real
// release's, written by the scaffold's own writer.
type realScaffold struct {
	fakeScaffold
	real *scaffold.Release
}

func (r realScaffold) Managed() []string { return r.real.Managed() }
func (r realScaffold) Check() error      { return r.real.Check() }
func (r realScaffold) Write(overwriteManaged bool) error {
	r.s.logLine("SCAFFOLD WRITE")
	return r.real.Write(overwriteManaged)
}

// sudo makes this process root run through sudo for 4242:4343.
func sudo(t *testing.T) map[string][2]int { return chownStandIn(t, "4242", "4343", "") }

// givenBack is paths, each given back to 4242:4343.
func givenBack(paths ...string) map[string][2]int {
	want := map[string][2]int{}
	for _, p := range paths {
		want[p] = [2]int{4242, 4343}
	}
	return want
}

// entriesUnder are the entries under the project directory dir, dir
// itself among them, links not entered.
func entriesUnder(t *testing.T, dir string) []string {
	t.Helper()
	var paths []string
	if err := filepath.WalkDir(dir, func(p string, _ fs.DirEntry, err error) error {
		if err == nil {
			paths = append(paths, p)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return paths
}

// Run as root through sudo, cyfr update gives back exactly what it wrote,
// at the real path each write landed on: the release's scaffold files,
// those beyond its managed ones it creates (the Caddyfile, .env.example)
// among them, a WIT file written through wit, a link to interfaces inside
// the folder, as interfaces/cyfr/added.wit, .env, docker-compose.yml, the
// engine's state it made, backups/ and the whole snapshot. wit, the
// folder it links to, and the storage root are not given back.
func TestUpdateThroughSudoGivesBackWhatItWrote(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	if err := os.Mkdir("interfaces", 0o755); err != nil {
		t.Fatal(err)
	}
	plantFolderLink(t, "interfaces", "wit")
	real := releaseTarball(t, map[string]string{
		"keeper.seccomp.json":    newScaffold[0].content,
		"configuration-guide.md": newScaffold[1].content,
		"wit/":                   "",
		"wit/cyfr/added.wit":     newScaffold[2].content,
		"Caddyfile":              "{$CYFR_HOST} {\n}\n",
		".env.example":           "CYFR_PORT=4000\n",
	})
	fetchScaffold = func(v string) (scaffoldRelease, error) {
		s.scaffold++
		return realScaffold{fakeScaffold{s, v}, real}, nil
	}
	changed := sudo(t)
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("cyfr update answered %v\n%s", err, out)
	}
	want := givenBack(".env", "docker-compose.yml", "keeper.seccomp.json", "configuration-guide.md",
		"interfaces/cyfr/added.wit", "Caddyfile", ".env.example", "backups/.gitignore")
	for _, dir := range []string{"interfaces/cyfr", ".cyfr", "backups"} {
		maps.Copy(want, givenBack(entriesUnder(t, dir)...))
	}
	if _, ok := want["backups/20261016T120000Z/storage/blobs/x"]; !ok {
		t.Fatalf("the snapshot is not whole: %v", slices.Sorted(maps.Keys(want)))
	}
	if !maps.Equal(changed, want) {
		t.Errorf("cyfr update gave back %v, want %v", slices.Sorted(maps.Keys(changed)), slices.Sorted(maps.Keys(want)))
	}
}

// Run as root through sudo, cyfr backup gives back backups/, the whole
// snapshot and the engine's state it made; .env, docker-compose.yml and
// the scaffold files it only read are not given back.
func TestBackupThroughSudoGivesBackOnlyWhatItWrote(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	changed := sudo(t)
	out, err := s.backup()
	if err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	want := givenBack(append(entriesUnder(t, "backups"), entriesUnder(t, ".cyfr")...)...)
	if _, ok := want["backups/20261016T120000Z/snapshot.json"]; !ok {
		t.Fatalf("the project holds no snapshot: %v", slices.Sorted(maps.Keys(want)))
	}
	if !maps.Equal(changed, want) {
		t.Errorf("cyfr backup gave back %v, want %v", slices.Sorted(maps.Keys(changed)), slices.Sorted(maps.Keys(want)))
	}
}

// cyfr update --offer, run through sudo, writes nothing and gives nothing
// back.
func TestUpdateOfferThroughSudoGivesNothingBack(t *testing.T) {
	newUpdateScenario(t, shippedCompose(t), nil)
	changed := sudo(t)
	var out bytes.Buffer
	if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil {
		t.Fatalf("cyfr update --offer answered %v\n%s", err, out.String())
	}
	if len(changed) != 0 {
		t.Errorf("cyfr update --offer gave back %v", changed)
	}
}

// A restore that ends at the lock another command holds has written
// nothing and gives nothing back: a folder at a scaffold file's name, and
// what it holds, keep their owners.
func TestARestoreRefusedAtTheLockGivesNothingBack(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	if err := os.Remove("configuration-guide.md"); err != nil {
		t.Fatal(err)
	}
	r.edit("configuration-guide.md/notes.md", "the person's own\n")
	r.engine.holder = "update"
	changed := sudo(t)
	var out bytes.Buffer
	err := runRestore(context.Background(), r.dir, true, &out, &out)
	if err == nil || !strings.Contains(err.Error(), "Another cyfr command holds CYFR's lock (`update`)") {
		t.Fatalf("restore answered %v, not the held lock:\n%s", err, out.String())
	}
	if len(changed) != 0 {
		t.Errorf("the refused restore gave back %v", changed)
	}
}

// Run as root, cyfr update and cyfr backup refuse, by name and before
// anything stops or is written, a backups/ that is a link out of the
// folder: a snapshot is never written through it.
func TestARunAsRootRefusesBackupsLinkedOutOfTheFolder(t *testing.T) {
	for _, command := range []string{"update", "backup"} {
		t.Run("cyfr "+command, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			sibling := t.TempDir()
			plantFolderLink(t, sibling, "backups")
			changed := sudo(t)
			var out string
			var err error
			if command == "update" {
				out, err = s.run(context.Background())
			} else {
				out, err = s.backup()
			}
			want := fmt.Sprintf("backups is a link to %s, outside this folder, and cyfr %s run as root writes nothing through a link out of the folder; nothing was changed. Make backups a folder of its own here, then run it again", sibling, command)
			if err == nil || err.Error() != want {
				t.Fatalf("cyfr %s answered %v, want %q:\n%s", command, err, want, out)
			}
			if entries, err := os.ReadDir(sibling); err != nil || len(entries) != 0 {
				t.Errorf("the sibling folder holds %v (error %v)", entries, err)
			}
			if s.engine.locks != 0 {
				t.Errorf("cyfr %s took the stack's lock", command)
			}
			s.nothingStopped()
			s.composeUnchanged()
			if len(changed) != 0 {
				t.Errorf("cyfr %s gave back %v", command, changed)
			}
		})
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
// ~/.local/bin stays the person's. Paths compare in their real spelling,
// as the update names the program it installs (resolvedPath).
func TestTheProgramReplacedAsRootKeepsItsOwner(t *testing.T) {
	s := newProgramScenario(t, "0.9.0", "0.10.0")
	changed := sudo(t)
	if out, err := s.run(updateOptions{}); err != nil {
		t.Fatalf("cyfr update answered %v\n%s", err, out)
	}
	s.installed("0.10.0")
	if len(changed) != 1 {
		t.Fatalf("the program step changed the owners of %v, want its new program's alone", changed)
	}
	dir := filepath.Dir(resolvedPath(t, s.self))
	var st syscall.Stat_t
	if err := syscall.Stat(s.self, &st); err != nil {
		t.Fatal(err)
	}
	for p, owner := range changed {
		if filepath.Dir(p) != dir || !strings.HasPrefix(filepath.Base(p), ".cyfr.update-") {
			t.Errorf("the owner changed is %s's, want the new program's in %s", p, dir)
		}
		if want := [2]int{int(st.Uid), int(st.Gid)}; owner != want {
			t.Errorf("the new program is given %v, want the old one's owner %v", owner, want)
		}
	}
}
