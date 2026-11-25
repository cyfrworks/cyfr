// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"testing"

	"github.com/cyfr/codex/internal/access"
)

// With nothing under data/ readable or writable by the person, as the
// server's container leaves it on native Linux once the stack has run,
// cyfr restore run as the person puts every part back through the stack,
// says nothing of sudo, and leaves what it writes of the project the
// person's; the backup that took the snapshot names that restore as it
// is.
func TestRestoreOfStorageTheAccountCannotRead(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.edit(".env", editedEnv)
	r.edit("data/blobs/x", "rewritten")
	r.edit("data/blobs/new", "written after the snapshot")
	r.edit("data/cyfr.db", migratedDatabase)
	closeStorage(t, r.updateScenario)
	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if strings.Contains(out, "sudo") || !strings.Contains(out, "Declared restore "+testRestored+";") {
		t.Errorf("the restore said:\n%s", out)
	}
	shut := standInAsRoot()
	r.storageIs(nil)
	shut()
	for _, name := range []string{".env", "docker-compose.yml", "keeper.seccomp.json", "configuration-guide.md", ".cyfr"} {
		ownedByMe(t, filepath.Join(r.project, name))
	}

	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	closeStorage(t, s)
	out, err = s.backup()
	want := "The snapshot of release 0.8.0 is in " + s.snapshotDir() + "; 'cyfr restore " + s.snapshotDir() + "' puts it back.\n"
	if err != nil || !strings.Contains(out, want) {
		t.Fatalf("cyfr backup answered %v, without %q:\n%s", err, want, out)
	}
}

// Names with spaces, line breaks and leading dashes are cleared and put
// back like any other, and a link in the storage that leads out of it is
// removed as the link it is: what it leads to is never touched.
func TestRestoreClearsOddNamesAndLinksAsThemselves(t *testing.T) {
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "precious"), []byte("precious"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
		s.edit("data/-kept dash", "in the snapshot")
	})
	for _, name := range []string{"data/with space", "data/line\nbreak", "data/-dash", "data/blobs/-rf"} {
		r.edit(name, "written after the snapshot")
	}
	if err := os.Symlink(outside, filepath.Join(r.project, "data", "out")); err != nil {
		t.Fatal(err)
	}
	if out, err := r.restore(true); err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	r.storageIs(map[string]string{"-kept dash": "in the snapshot"})
	if got := read(t, filepath.Join(outside, "precious")); got != "precious" {
		t.Errorf("behind the link: %q", got)
	}
	list := strings.Split(strings.TrimSuffix(read(t, filepath.Join(r.fake, "clear.list")), "\x00"), "\x00")
	for _, want := range []string{"/app/data/with space", "/app/data/line\nbreak", "/app/data/-dash", "/app/data/out", "/app/data/blobs"} {
		if !slices.Contains(list, want) {
			t.Errorf("the clear's list %q lacks %q", list, want)
		}
	}
	for _, p := range list {
		if strings.Contains(p, "cyfr.db") || p == "/app/data" {
			t.Errorf("the clear listed %q", p)
		}
	}
}

// A stream cut short, a snapshot file this account cannot read, fails the
// put-back with the stack stopped and barred; once it reads, the same
// restore puts every part back.
func TestARestoreWhoseStreamIsCutPutsEveryPartBackWhenRunAgain(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.edit("data/blobs/x", "rewritten")
	x := filepath.Join(r.dir, "storage", "blobs", "x")
	if err := os.Chmod(x, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(x, 0o600) })
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "Putting the snapshot back failed") || !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	r.barred()
	if err := os.Chmod(x, 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := r.restore(true); err != nil {
		t.Fatalf("the restore run again: %v\n%s", err, out)
	}
	r.storageIs(nil)
}

// inode is the file's inode number.
func inode(t *testing.T, p string) uint64 {
	t.Helper()
	info, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return info.Sys().(*syscall.Stat_t).Ino
}

// sqlite runs the Python script against the SQLite file db and answers
// what it prints; the test is skipped where no python3 is.
func sqlite(t *testing.T, db, script string) string {
	t.Helper()
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3 to read SQLite with")
	}
	out, err := exec.Command(python, "-I", "-c", "import sqlite3, sys, shutil\ndb = sys.argv[1]\n"+script, db).CombinedOutput()
	if err != nil {
		t.Fatalf("python3: %v\n%s", err, out)
	}
	return string(out)
}

// A mount that is one file is written in place, a mount point not being a
// thing to rename over: one under the storage root, and a database and its
// write-ahead log each on a bind of its own. A log the snapshot does not
// hold is emptied in place, and SQLite then reads the restored database
// alone, not the frames of the log that was there.
func TestRestoreWritesASingleFileMountInPlace(t *testing.T) {
	t.Run("under the storage root", func(t *testing.T) {
		single := filepath.Join(t.TempDir(), "single")
		if err := os.WriteFile(single, []byte("snapshot bytes"), 0o644); err != nil {
			t.Fatal(err)
		}
		r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
			s.addVolume(map[string]any{"type": "bind", "source": single, "target": "/app/data/single"})
			// Its mount point in data/, as the stack's start made it.
			s.edit("data/single", "")
		})
		before := inode(t, single)
		if err := os.WriteFile(single, []byte("written after the snapshot, longer"), 0o644); err != nil {
			t.Fatal(err)
		}
		if out, err := r.restore(true); err != nil {
			t.Fatalf("restore: %v\n%s", err, out)
		}
		if got := read(t, single); got != "snapshot bytes" || inode(t, single) != before {
			t.Errorf("the file mount holds %q (inode %d, was %d)", got, inode(t, single), before)
		}
		if !slices.Contains(r.shortLog(), "STACK write dd of=/app/data/single bs=1M conv=fsync status=none") {
			t.Errorf("the file mount was not written in place:\n%s", strings.Join(r.shortLog(), "\n"))
		}
	})
	t.Run("a database and its log on binds of their own", func(t *testing.T) {
		var db, wal string
		r := newRestoreScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/main.db", "CYFR_STORAGE": "s3"}, func(s *updateScenario) {
			db, wal = filepath.Join(s.project, "data", "cyfr.db"), filepath.Join(s.project, "data", "cyfr.db-wal")
			os.Remove(db)
			sqlite(t, db, "c = sqlite3.connect(db)\nc.execute('pragma journal_mode=wal')\nc.execute('create table t (v text)')\nc.execute(\"insert into t values ('snapshot')\")\nc.commit()\nc.close()")
			if err := os.WriteFile(wal, nil, 0o644); err != nil {
				t.Fatal(err)
			}
			for _, suffix := range []string{"", "-wal"} {
				s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, "data", "cyfr.db"+suffix), "target": "/db/main.db" + suffix})
			}
		})
		if r.snap().parts["database-wal"] {
			t.Fatal("the snapshot holds a log")
		}
		// The cell moves on: another database's committed frames sit in
		// the log, which SQLite would read over the restored file.
		other := filepath.Join(t.TempDir(), "other.db")
		sqlite(t, other, "c = sqlite3.connect(db)\nc.execute('pragma journal_mode=wal')\nc.execute('pragma wal_autocheckpoint=0')\nc.execute('create table t (v text)')\nc.execute(\"insert into t values ('after the snapshot')\")\nc.commit()\nshutil.copyfile(db + '-wal', sys.argv[1] + '.frames')\nc.close()")
		frames, err := os.ReadFile(other + ".frames")
		if err != nil || len(frames) == 0 {
			t.Fatalf("no frames (%v)", err)
		}
		if err := os.WriteFile(wal, frames, 0o644); err != nil {
			t.Fatal(err)
		}
		dbInode, walInode := inode(t, db), inode(t, wal)
		if out, err := r.restore(true); err != nil {
			t.Fatalf("restore: %v\n%s", err, out)
		}
		if info, err := os.Stat(wal); err != nil || info.Size() != 0 || inode(t, wal) != walInode || inode(t, db) != dbInode {
			t.Errorf("the log is %v (%v), inodes %d %d, were %d %d", info, err, inode(t, db), inode(t, wal), dbInode, walInode)
		}
		if got := sqlite(t, db, "c = sqlite3.connect(db)\nprint([r[0] for r in c.execute('select v from t')])"); got != "['snapshot']\n" {
			t.Errorf("SQLite reads the restored database as %s", got)
		}
	})
}

// snap answers the scenario's snapshot, read.
func (r *restoreScenario) snap() *snapshotFiles {
	r.t.Helper()
	snap, err := readSnapshot(r.dir)
	if err != nil {
		r.t.Fatal(err)
	}
	return snap
}

// The real write through the stack, with real docker and the image named
// by CYFR_STACK_READ_IMAGE (skipped without it): a storage root the
// image's user owns, mode 0700, as the stack leaves it, is cleared and
// written from a snapshot the person owns, its odd names and links as
// they are, a link out of it removed and never followed, a file mount
// written in place, the database and its log put back and the old
// shared-memory index removed; the image's entrypoint then hands every
// entry to its user, as the declaration's run does.
func TestTheRealStackWritePutsTheStorageBack(t *testing.T) {
	image := os.Getenv("CYFR_STACK_READ_IMAGE")
	if image == "" || runtime.GOOS != "linux" {
		t.Skip("set CYFR_STACK_READ_IMAGE to an image of cyfr on a Linux machine with docker")
	}
	project := t.TempDir()
	t.Chdir(project)
	data, outside, single := filepath.Join(project, "data"), filepath.Join(project, "outside"), filepath.Join(project, "single")
	for _, dir := range []string{data, outside} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(single, []byte("old single"), 0o644); err != nil {
		t.Fatal(err)
	}
	sh := func(mount, script string) string {
		t.Helper()
		out, err := exec.Command("docker", "run", "--rm", "--pull", "never", "--network", "none", "--entrypoint", "sh", "-v", data+":/d"+mount, "-v", outside+":/outside", image, "-c", script).CombinedOutput()
		if err != nil {
			t.Fatalf("docker run %s: %v\n%s", script, err, out)
		}
		return string(out)
	}
	t.Cleanup(func() { sh("", "rm -rf /d/* /d/.[!.]* /outside/*") })
	sh("", `set -e
mkdir -p /d/blobs /d/components
printf old > /d/blobs/x; printf old > /d/blobs/-rf; printf old > '/d/with space'; printf old > '/d/line
break'
printf 'SQLite format 3\000 old' > /d/cyfr.db; printf oldwal > /d/cyfr.db-wal; printf oldshm > /d/cyfr.db-shm
printf precious > /outside/precious; ln -s /outside /d/out; ln -s /outside/precious /d/precious-link
: > /d/single
chown -R 999:999 /d /outside; chmod -R go-rwx /d; chmod 700 /d`)

	snapshot := filepath.Join(project, "snapshot")
	for name, content := range map[string]string{
		"database": sqliteBytes, "database-wal": "snapshot wal",
		"storage/blobs/x": "blob", "storage/-dash": "dash", "storage/with space/inner": "space",
		"storage/components/acme/c.wasm": "wasm", "storage/single": "new single",
	} {
		p := filepath.Join(snapshot, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("components/acme", filepath.Join(snapshot, "storage", "current")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/outside", filepath.Join(snapshot, "storage", "planted")); err != nil {
		t.Fatal(err)
	}

	e, err := access.Open(project, nil)
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	var out bytes.Buffer
	r := &restorer{updater: updater{ctx: context.Background(), command: "restore", out: &out, errOut: &out, engine: e, config: &stackConfig{
		adapter: "sqlite", storage: "local", image: image, dbPath: "/app/data/cyfr.db", dataPath: "/app/data",
		mounts: []composeMount{{Type: "bind", Source: data, Target: "/app/data"}, {Type: "bind", Source: single, Target: "/app/data/single"},
			{Type: "bind", Source: outside, Target: "/outside"}, {Type: "tmpfs", Target: "/app/tmp"}},
	}}, snap: &snapshotFiles{dir: snapshot, parts: map[string]bool{"database": true, "database-wal": true, "storage": true}}}
	for _, step := range []func() error{r.placeRestoredDatabase, r.planWrite, r.writeStorage, r.writeDatabase} {
		if err := step(); err != nil {
			t.Fatalf("the write through the stack: %v\n%s", err, out.String())
		}
	}
	list := "cd /d && find . -printf '%p %y %m %U|%l\\n' | LC_ALL=C sort && for f in blobs/x ./-dash 'with space/inner' components/acme/c.wasm cyfr.db cyfr.db-wal; do printf '%s=' \"$f\"; cat -- \"$f\"; echo; done && cat /outside/precious && echo"
	got := sh(":ro", list)
	// The storage root and the file mount's mount point keep their owner,
	// the image's user; every entry written is the container's root's.
	want := `. d 700 999|
./-dash f 600 0|
./blobs d 700 0|
./blobs/x f 600 0|
./components d 700 0|
./components/acme d 700 0|
./components/acme/c.wasm f 600 0|
./current l 777 0|components/acme
./cyfr.db f 600 0|
./cyfr.db-wal f 600 0|
./planted l 777 0|/outside
./single f 600 999|
./with space d 700 0|
./with space/inner f 600 0|
blobs/x=blob
./-dash=dash
with space/inner=space
components/acme/c.wasm=wasm
cyfr.db=` + sqliteBytes + `
cyfr.db-wal=snapshot wal
precious
`
	if got != want {
		t.Errorf("the storage holds\n%s\nwant\n%s", got, want)
	}
	if b, err := os.ReadFile(single); err != nil || string(b) != "new single" {
		t.Errorf("the file mount holds %q (%v)", b, err)
	}
	// The image's entrypoint, run as the declaration runs it, hands the
	// storage root to the image's user.
	if o, err := exec.Command("docker", "run", "--rm", "--pull", "never", "--network", "none", "-v", data+":/app/data", image, "true").CombinedOutput(); err != nil {
		t.Fatalf("the entrypoint: %v\n%s", err, o)
	}
	if owners := sh(":ro", "find /d ! -type l -printf '%U\\n' | sort -u"); owners != "999\n" {
		t.Errorf("after the entrypoint the storage is owned by %q", owners)
	}
}

// sqliteRead opens a copy of the SQLite database db, with its write-ahead
// log where one is there, so the read changes nothing of it, and answers
// its integrity check and the rows of its table t, in order.
func sqliteRead(t *testing.T, db string) string {
	t.Helper()
	return sqlite(t, db, "import os, tempfile\nd = tempfile.mkdtemp()\nfor s in ['', '-wal']:\n    if os.path.exists(db + s):\n        shutil.copyfile(db + s, os.path.join(d, 'c.db' + s))\nc = sqlite3.connect(os.path.join(d, 'c.db'))\nprint(c.execute('pragma integrity_check').fetchone()[0], sorted(r[0] for r in c.execute('select v from t')))\nc.close()\nshutil.rmtree(d)")
}

// sqliteWithLog makes db a SQLite database in write-ahead mode whose file
// holds the row inFile and whose log holds the committed row inLog.
func sqliteWithLog(t *testing.T, db, inFile, inLog string) {
	t.Helper()
	for _, suffix := range []string{"", "-wal", "-shm"} {
		os.Remove(db + suffix)
	}
	sqlite(t, db, "c = sqlite3.connect(db)\nc.execute('pragma journal_mode=wal')\nc.execute('pragma wal_autocheckpoint=0')\nc.execute('create table t (v text)')\nc.execute(\"insert into t values ('"+inFile+"')\")\nc.commit()\nc.execute('pragma wal_checkpoint(truncate)')\nshutil.copyfile(db, db + '.file')\nc.execute(\"insert into t values ('"+inLog+"')\")\nc.commit()\nshutil.copyfile(db + '-wal', db + '.frames')\nc.close()\nshutil.move(db + '.file', db)\nshutil.move(db + '.frames', db + '-wal')")
	os.Remove(db + "-shm")
}

// A restore killed at each step of the database's write leaves a
// database SQLite opens whole: the old one with its log until the old log
// goes, then, from the old log's removal to the last rename, under the
// bar alone, a whole file without what a log held; and the same restore
// run again puts the snapshot's database back, every row of its file and
// its log.
func TestARestoreKilledInTheDatabasesSwapRunsAgainToTheSnapshot(t *testing.T) {
	for _, c := range []struct {
		name, kill, step, rows string
	}{
		{"in the staged write", "3 1", "tar -x -f - -C /app/data", "['live file', 'live log']"},
		{"before the staged files' sync", "4 x", "sync -- /app/data/.cyfr.db.restore /app/data/.cyfr.db-wal.restore", "['live file', 'live log']"},
		{"before the old log goes", "5 x", "rm -f -- /app/data/cyfr.db-wal", "['live file', 'live log']"},
		{"before the file's rename", "6 x", "mv -f -T -- /app/data/.cyfr.db.restore /app/data/cyfr.db", "['live file']"},
		{"before the log's rename", "7 x", "mv -f -T -- /app/data/.cyfr.db-wal.restore /app/data/cyfr.db-wal", "['snapshot file']"},
		{"before the folder's sync", "8 x", "sync -- /app/data", "['snapshot file', 'snapshot log']"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
				sqliteWithLog(t, filepath.Join(s.project, "data", "cyfr.db"), "snapshot file", "snapshot log")
			})
			if !r.snap().parts["database-wal"] {
				t.Fatal("the snapshot holds no log")
			}
			db := filepath.Join(r.project, "data", "cyfr.db")
			sqliteWithLog(t, db, "live file", "live log")
			r.edit("data/blobs/new", "written after the snapshot")
			r.answer("write.kill", c.kill)
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), "Putting the snapshot back failed") {
				t.Fatalf("restore answered %v\n%s", err, out)
			}
			var last string
			for _, line := range r.shortLog() {
				if strings.HasPrefix(line, "STACK write ") {
					last = line
				}
			}
			if !strings.HasPrefix(last, "STACK write "+c.step) {
				t.Fatalf("the write killed was %q, want %s", last, c.step)
			}
			r.barred()
			if got := sqliteRead(t, db); got != "ok "+c.rows+"\n" {
				t.Errorf("killed at %s, SQLite reads the database as %s", c.step, got)
			}
			for _, name := range []string{"write.kill", "write.count"} {
				os.Remove(filepath.Join(r.fake, name))
			}
			if out, err := r.restore(true); err != nil {
				t.Fatalf("the restore run again: %v\n%s", err, out)
			}
			if got := sqliteRead(t, db); got != "ok ['snapshot file', 'snapshot log']\n" {
				t.Errorf("after the restore run again SQLite reads the database as %s", got)
			}
		})
	}
}
