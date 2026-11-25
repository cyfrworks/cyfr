// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
)

// closeStorage makes everything under the scenario's data/ unreadable to
// this account, as the server's container leaves it on native Linux once
// the stack has run. The stand-in, which plays the container's root,
// reads it with its permissions given back for each read alone
// (standInAsRoot); they come back for good at the test's end.
func closeStorage(t *testing.T, s *updateScenario) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	data := filepath.Join(s.project, "data")
	var dirs, files []string
	filepath.WalkDir(data, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			dirs = append(dirs, p)
		} else if err == nil && d.Type().IsRegular() {
			files = append(files, p)
		}
		return nil
	})
	open := func() {
		for _, d := range dirs {
			os.Chmod(d, 0o755)
		}
		for _, f := range files {
			os.Chmod(f, 0o644)
		}
	}
	shut := func() {
		for _, f := range files {
			os.Chmod(f, 0)
		}
		for i := len(dirs) - 1; i >= 0; i-- {
			os.Chmod(dirs[i], 0)
		}
	}
	shut()
	saved := standInAsRoot
	standInAsRoot = func() func() { open(); return shut }
	t.Cleanup(func() { standInAsRoot = saved; open() })
}

// ownedByMe fails unless every entry under dir is this account's.
func ownedByMe(t *testing.T, dir string) {
	t.Helper()
	filepath.WalkDir(dir, func(p string, _ fs.DirEntry, err error) error {
		if err != nil {
			t.Errorf("%s: %v", p, err)
			return nil
		}
		info, err := os.Lstat(p)
		if err != nil {
			t.Error(err)
			return nil
		}
		if st, ok := info.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
			t.Errorf("%s is uid %d's, not this account's", p, st.Uid)
		}
		return nil
	})
}

// With nothing under data/ readable by the person, as the server's
// container leaves it on native Linux, cyfr update snapshots through the
// stack, stops, switches and starts the release, the snapshot whole and
// the person's; so does cyfr backup.
func TestUpdateAndBackupOfStorageTheAccountCannotRead(t *testing.T) {
	t.Run("cyfr update", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.backupScaffold()
		closeStorage(t, s)
		out, err := s.run(context.Background())
		if err != nil {
			t.Fatalf("cyfr update answered %v\n%s", err, out)
		}
		if !s.hasCall("SCAFFOLD WRITE") || !s.hasCall("ENGINE start update") || !strings.Contains(out, "Updated to release 0.9.0.") {
			t.Errorf("cyfr update did not switch and start:\n%s", out)
		}
		snapshotWhole(t, s)
	})
	t.Run("cyfr backup", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.backupScaffold()
		closeStorage(t, s)
		out, err := s.backup()
		if err != nil || !strings.Contains(out, "The stack runs again.") {
			t.Fatalf("cyfr backup answered %v\n%s", err, out)
		}
		snapshotWhole(t, s)
	})
}

// snapshotWhole fails unless the scenario's snapshot holds its database,
// its write-ahead log and its storage as the scenario wrote them, its link
// a link, every entry the person's, and reads as a snapshot.
func snapshotWhole(t *testing.T, s *updateScenario) {
	t.Helper()
	dir := s.snapshotDir()
	for name, content := range map[string]string{
		"database":                       sqliteDatabase,
		"database-wal":                   "sqlite-wal",
		"storage/components/acme/c.wasm": "component-bytes",
		"storage/blobs/x":                "blob",
	} {
		info, statErr := os.Lstat(filepath.Join(dir, name))
		if data, err := os.ReadFile(filepath.Join(dir, name)); err != nil || string(data) != content || statErr != nil || info.Mode().Perm() != 0600 {
			t.Errorf("%s holds %q (error %v), mode %v, want %q at 0600", name, data, err, info, content)
		}
	}
	if link, err := os.Readlink(filepath.Join(dir, "storage", "current")); err != nil || link != "components/acme" {
		t.Errorf("storage/current is %q (error %v), want the link to components/acme", link, err)
	}
	for _, name := range []string{"storage/cyfr.db", "storage/cyfr.db-wal", "storage/cyfr.db-shm"} {
		if _, err := os.Lstat(filepath.Join(dir, name)); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("the snapshot's storage holds %s (%v)", name, err)
		}
	}
	if _, err := readSnapshot(dir); err != nil {
		t.Errorf("cyfr restore refuses the snapshot: %v", err)
	}
	ownedByMe(t, dir)
}

// The real read through the stack, with real docker and the image named
// by CYFR_STACK_READ_IMAGE (skipped without it): a storage root the image's
// user owns, mode 0700, as the stack leaves it, of some hundreds of
// megabytes, is snapshotted whole and the person's, and nothing under it
// changes owner, mode or any of its times; the copy's time is logged.
func TestTheRealStackReadChangesNothingUnderData(t *testing.T) {
	image := os.Getenv("CYFR_STACK_READ_IMAGE")
	if image == "" || runtime.GOOS != "linux" {
		t.Skip("set CYFR_STACK_READ_IMAGE to an image of cyfr on a Linux machine with docker")
	}
	project := t.TempDir()
	t.Chdir(project)
	data := filepath.Join(project, "data")
	if err := os.Mkdir(data, 0o755); err != nil {
		t.Fatal(err)
	}
	sh := func(mount, script string) string {
		t.Helper()
		out, err := exec.Command("docker", "run", "--rm", "--pull", "never", "--network", "none", "--entrypoint", "sh", "-v", data+":/d"+mount, image, "-c", script).CombinedOutput()
		if err != nil {
			t.Fatalf("docker run %s: %v\n%s", script, err, out)
		}
		return string(out)
	}
	t.Cleanup(func() { sh("", "rm -rf /d/* /d/.[!.]*") })
	megabytes := 400
	sh("", fmt.Sprintf(`set -e
mkdir -p /d/components/acme /d/blobs
i=0; while [ $i -lt %d ]; do head -c 1048576 /dev/urandom > /d/blobs/b$i; i=$((i+1)); done
printf 'SQLite format 3\000 db' > /d/cyfr.db; printf wal > /d/active-wal; ln -s active-wal /d/cyfr.db-wal; printf shm > /d/cyfr.db-shm
printf dash > /d/-dash; printf space > '/d/with space'
printf wasm > /d/components/acme/c.wasm; ln -s components/acme /d/current
chown -R 999:999 /d; chmod -R go-rwx /d; chmod 700 /d`, megabytes))
	list := "find /d -printf '%p %U %G %m %A@ %T@ %C@\\n' | sort"
	before := sh(":ro", list)

	e, err := access.Open(project, nil)
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	snapshot := filepath.Join(project, "snapshot")
	if err := os.Mkdir(snapshot, 0o700); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	u := &updater{ctx: context.Background(), command: "backup", out: &out, errOut: &out, engine: e, config: &stackConfig{
		adapter: "sqlite", storage: "local", image: image, dbPath: "/app/data/cyfr.db", dataPath: "/app/data",
		mounts: []composeMount{{Type: "bind", Source: data, Target: "/app/data"}, {Type: "tmpfs", Target: "/app/tmp"}},
	}}
	began := time.Now()
	if err := u.placeDatabase(); err != nil {
		t.Fatalf("placing the database: %v\n%s", err, out.String())
	}
	parts, err := u.readThroughStack(snapshot)
	took := time.Since(began)
	if err != nil {
		t.Fatalf("the read through the stack: %v\n%s", err, out.String())
	}
	t.Logf("read %d MB of storage through the stack in %v", megabytes, took.Round(time.Millisecond))
	if !slices.Equal(parts, []string{"database", "database-wal", "storage"}) {
		t.Errorf("the read wrote %v", parts)
	}
	if after := sh(":ro", list); after != before {
		t.Errorf("the read changed the storage:\nbefore\n%s\nafter\n%s", before, after)
	}
	var files int
	var bytesRead int64
	filepath.WalkDir(filepath.Join(snapshot, "storage", "blobs"), func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			info, _ := d.Info()
			files, bytesRead = files+1, bytesRead+info.Size()
		}
		return nil
	})
	if files != megabytes || bytesRead != int64(megabytes)<<20 {
		t.Errorf("the snapshot holds %d blobs of %d bytes, want %d of 1 MiB", files, bytesRead, megabytes)
	}
	if link, err := os.Readlink(filepath.Join(snapshot, "storage", "current")); err != nil || link != "components/acme" {
		t.Errorf("storage/current is %q (%v)", link, err)
	}
	for name, want := range map[string]string{"database-wal": "wal", "storage/active-wal": "wal", "storage/-dash": "dash", "storage/with space": "space"} {
		if got, err := os.ReadFile(filepath.Join(snapshot, name)); err != nil || string(got) != want {
			t.Errorf("%s holds %q (%v), want %q", name, got, err, want)
		}
	}
	for _, name := range []string{"storage/cyfr.db", "storage/cyfr.db-wal", "storage/cyfr.db-shm"} {
		if _, err := os.Lstat(filepath.Join(snapshot, name)); err == nil {
			t.Errorf("the snapshot's storage holds %s", name)
		}
	}
	ownedByMe(t, snapshot)
}

// main is what main's host copy holds of a snapshot: each of names under
// the snapshot directory as content ("" for a directory, "-> target" for
// a link), and the snapshot's every other entry absent.
func snapshotIs(t *testing.T, s *updateScenario, want map[string]string) {
	t.Helper()
	dir := s.snapshotDir()
	got := map[string]string{}
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		rel, _ := filepath.Rel(dir, p)
		top, _, _ := strings.Cut(filepath.ToSlash(rel), "/")
		if err != nil || p == dir || top == "scaffold" || top == "snapshot.json" || top == "keyring" || top == ".env" || top == "compose" {
			return nil
		}
		switch {
		case d.IsDir():
			got[filepath.ToSlash(rel)] = ""
		case d.Type()&fs.ModeSymlink != 0:
			link, _ := os.Readlink(p)
			got[filepath.ToSlash(rel)] = "-> " + link
		default:
			data, _ := os.ReadFile(p)
			got[filepath.ToSlash(rel)] = string(data)
		}
		return nil
	})
	if !maps.Equal(got, want) {
		t.Errorf("the snapshot holds\n%v\nwant main's\n%v", got, want)
	}
}

// mainStorage is what main's copy of the scenario's storage holds, with
// extra entries besides.
func mainStorage(extra map[string]string) map[string]string {
	want := map[string]string{
		"storage": "", "storage/blobs": "", "storage/blobs/x": "blob", "storage/components": "",
		"storage/components/acme": "", "storage/components/acme/c.wasm": "component-bytes", "storage/current": "-> components/acme",
	}
	maps.Copy(want, extra)
	return want
}

// A database the service opens through a link (current.db) is backed up
// as the server reads it, the file the link leads to and the write-ahead
// log beside that file, and the link stays in the storage as a link; as
// main's copy holds it.
func TestTheSnapshotReadsADatabaseThroughALinkAsTheServerDoes(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/app/data/current.db"})
	s.backupScaffold()
	if err := os.Symlink("cyfr.db", "data/current.db"); err != nil {
		t.Fatal(err)
	}
	if out, err := s.backup(); err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	snapshotIs(t, s, mainStorage(map[string]string{"database": sqliteDatabase, "database-wal": "sqlite-wal", "storage/current.db": "-> cyfr.db"}))
}

// One host directory bound at /db for the database and at /app/data for
// the storage holds the database's files once: they are left out of the
// storage by which files they are, not by how the path is spelled.
func TestTheSnapshotLeavesTheDatabaseOutOfTheStorageWhereverItIsMounted(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/cyfr.db"})
	s.backupScaffold()
	s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, "data"), "target": "/db"})
	if out, err := s.backup(); err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	snapshotIs(t, s, mainStorage(map[string]string{"database": sqliteDatabase, "database-wal": "sqlite-wal"}))
}

// The project's .cyfr linked to a folder inside data/ is still the access
// engine's state, which no snapshot holds.
func TestTheSnapshotLeavesTheAccessStateOutWhereverItLies(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	if err := os.Mkdir("data/local-state", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("data/local-state", ".cyfr"); err != nil {
		t.Fatal(err)
	}
	s.edit("data/local-state/marker", "fixture")
	if out, err := s.backup(); err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	snapshotIs(t, s, mainStorage(map[string]string{"database": sqliteDatabase, "database-wal": "sqlite-wal"}))

	// A part of .cyfr bound on its own under the storage root is the
	// engine's state too.
	s = newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	s.edit(".cyfr/sub/state", "fixture")
	// Its mount point in data/, as the stack's start made it.
	if err := os.Mkdir(filepath.Join(s.project, "data", "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, ".cyfr", "sub"), "target": "/app/data/sub"})
	if out, err := s.backup(); err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	snapshotIs(t, s, mainStorage(map[string]string{"database": sqliteDatabase, "database-wal": "sqlite-wal"}))
}

// A write-ahead log is never lost quietly: on a file bind of its own, and
// through a link, it is read; one the read cannot read fails the backup
// before it reports success; only one that is absent or empty is left out.
func TestTheSnapshotNeverLosesAWriteAheadLog(t *testing.T) {
	t.Run("on a bind of its own", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/main.db", "CYFR_STORAGE": "s3"})
		s.backupScaffold()
		for _, suffix := range []string{"", "-wal"} {
			s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, "data", "cyfr.db"+suffix), "target": "/db/main.db" + suffix})
		}
		if out, err := s.backup(); err != nil {
			t.Fatalf("cyfr backup answered %v\n%s", err, out)
		}
		snapshotIs(t, s, map[string]string{"database": sqliteDatabase, "database-wal": "sqlite-wal"})
	})
	t.Run("through a link", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.backupScaffold()
		if err := os.Rename("data/cyfr.db-wal", "data/active-wal"); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink("active-wal", "data/cyfr.db-wal"); err != nil {
			t.Fatal(err)
		}
		if out, err := s.backup(); err != nil {
			t.Fatalf("cyfr backup answered %v\n%s", err, out)
		}
		snapshotIs(t, s, mainStorage(map[string]string{"database": sqliteDatabase, "database-wal": "sqlite-wal", "storage/active-wal": "sqlite-wal"}))
	})
	t.Run("that the read cannot read", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("root reads any file")
		}
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.backupScaffold()
		wal := filepath.Join(s.project, "data", "cyfr.db-wal")
		if err := os.Chmod(wal, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(wal, 0o644) })
		out, err := s.backup()
		if err == nil || !strings.Contains(err.Error(), "The snapshot failed") || strings.Contains(out, "The snapshot of release") {
			t.Fatalf("cyfr backup answered %v:\n%s", err, out)
		}
	})
	t.Run("absent, for a database of its own", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/app/data/quiet.db", "CYFR_STORAGE": "s3"})
		s.backupScaffold()
		s.edit("data/quiet.db", sqliteDatabase)
		if out, err := s.backup(); err != nil {
			t.Fatalf("cyfr backup answered %v\n%s", err, out)
		}
		snapshotIs(t, s, map[string]string{"database": sqliteDatabase})
	})
	t.Run("empty", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.backupScaffold()
		s.edit("data/cyfr.db-wal", "")
		if out, err := s.backup(); err != nil {
			t.Fatalf("cyfr backup answered %v\n%s", err, out)
		}
		snapshotIs(t, s, mainStorage(map[string]string{"database": sqliteDatabase}))
	})
}

// A database name that begins with '-' is passed to realpath and to tar
// as an operand, after '--', and backed up.
func TestTheSnapshotReadsADatabaseWhoseNameBeginsWithADash(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/-2026.db", "CYFR_STORAGE": "s3"})
	s.backupScaffold()
	s.edit("db/-2026.db", sqliteDatabase)
	s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, "db"), "target": "/db"})
	if out, err := s.backup(); err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	snapshotIs(t, s, map[string]string{"database": sqliteDatabase})
	reads := s.stackReads()
	if !slices.ContainsFunc(reads, func(l string) bool { return strings.HasSuffix(l, " -e -- /db/-2026.db") }) ||
		!slices.ContainsFunc(reads, func(l string) bool { return strings.HasSuffix(l, " -cf - -- db/-2026.db") }) {
		t.Errorf("the name was not passed after --:\n%s", strings.Join(reads, "\n"))
	}
}

// A database that is not there as the service sees it, or not a regular
// file, is refused before anything stops.
func TestADatabaseThatIsNotThereIsRefusedBeforeTheStop(t *testing.T) {
	for _, c := range []struct{ name, setup, says string }{
		{"absent", "", "The SQLite database /app/data/gone.db is not there as the cyfr service sees it"},
		{"a directory", "dir", "The SQLite database /app/data/gone.db (/app/data/gone.db as the cyfr service sees it) is not a regular file"},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/app/data/gone.db"})
			if c.setup == "dir" {
				if err := os.Mkdir("data/gone.db", 0o755); err != nil {
					t.Fatal(err)
				}
			}
			out, err := s.backup()
			if err == nil || !strings.Contains(err.Error(), c.says) || !strings.Contains(err.Error(), "nothing was changed") {
				t.Fatalf("cyfr backup answered %v:\n%s", err, out)
			}
			s.nothingStopped()
			s.noBackups()
		})
	}
}
