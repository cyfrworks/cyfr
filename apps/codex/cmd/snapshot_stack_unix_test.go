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
// the stack has run, with the archive the container would stream of it
// written first for the stand-in (tar.out); permissions come back at the
// test's end.
func closeStorage(t *testing.T, s *updateScenario) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	var archive bytes.Buffer
	binds := []composeMount{{Type: "bind", Source: filepath.Join(s.project, "data"), Target: "/app/data"}}
	if err := standInTar(&archive, binds, "/app/data", []string{"."}, false); err != nil {
		t.Fatal(err)
	}
	s.answer("tar.out", archive.String())
	data := filepath.Join(s.project, "data")
	var dirs []string
	filepath.WalkDir(data, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			dirs = append(dirs, p)
		} else if err == nil && d.Type().IsRegular() {
			os.Chmod(p, 0)
		}
		return nil
	})
	slices.Reverse(dirs)
	for _, d := range dirs {
		if err := os.Chmod(d, 0); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		slices.Reverse(dirs)
		for _, d := range dirs {
			os.Chmod(d, 0o755)
		}
		filepath.WalkDir(data, func(p string, d fs.DirEntry, err error) error {
			if err == nil && d.Type().IsRegular() {
				os.Chmod(p, 0o644)
			}
			return nil
		})
	})
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
printf 'SQLite format 3\000 db' > /d/cyfr.db; printf wal > /d/cyfr.db-wal; printf shm > /d/cyfr.db-shm
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
		reads: []composeMount{{Type: "bind", Source: data, Target: "/app/data"}},
	}}
	began := time.Now()
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
	ownedByMe(t, snapshot)
}
