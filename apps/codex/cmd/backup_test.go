// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// backup runs `cyfr backup` in the scenario's project, and fails if the
// lock is still held afterwards.
func (s *updateScenario) backup() (string, error) {
	s.t.Helper()
	var out bytes.Buffer
	err := runBackup(context.Background(), &out, &out)
	if holder := s.engine.held(); holder != "" {
		s.t.Errorf("the lock is still held, by %s", holder)
	}
	return out.String(), err
}

// sqliteDatabase is a database file as restore recognises SQLite's: its
// header first.
const sqliteDatabase = "SQLite format 3\x00 the scenario's database"

// backupScaffold gives the scenario a SQLite database restore recognises,
// managed scaffold files beside its own, and a person's own AQUA crew
// member, which is no managed file.
func (s *updateScenario) backupScaffold() {
	s.edit("data/cyfr.db", sqliteDatabase)
	s.edit("wit/cyfr/a.wit", "package cyfr:a;\n")
	s.edit("aqua/aqua.md", "# soul\n")
	s.edit("aqua/crew/mine.md", "# the person's own\n")
}

// at answers the index of the first log line starting with prefix, -1 when
// none does.
func at(log []string, prefix string) int {
	return slices.IndexFunc(log, func(line string) bool { return strings.HasPrefix(line, prefix) })
}

// A running CYFR is stopped as cyfr update stops it, snapshotted into
// backups/<timestamp>/ in the update's layout with the managed scaffold
// files it holds, snapshot.json last, which cyfr restore reads, and
// started again; no release is fetched and docker-compose.yml is not
// written.
func TestBackupTakesTheUpdatesSnapshotAndStartsTheStackAgain(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	out, err := s.backup()
	if err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	dir := s.snapshotDir()
	for name, content := range map[string]string{
		"database":                        sqliteDatabase,
		"database-wal":                    "sqlite-wal",
		".env":                            scenarioEnv,
		"storage/components/acme/c.wasm":  "component-bytes",
		"storage/blobs/x":                 "blob",
		"compose":                         string(s.compose),
		"scaffold/keeper.seccomp.json":    oldScaffold["keeper.seccomp.json"],
		"scaffold/configuration-guide.md": oldScaffold["configuration-guide.md"],
		"scaffold/wit/cyfr/a.wit":         "package cyfr:a;\n",
		"scaffold/aqua/aqua.md":           "# soul\n",
	} {
		path := filepath.Join(dir, name)
		info, statErr := os.Lstat(path)
		if data, err := os.ReadFile(path); err != nil || string(data) != content || statErr != nil || info.Mode().Perm() != 0600 {
			t.Errorf("%s holds %q (error %v), mode %v, want %q at 0600", name, data, err, info, content)
		}
	}
	if _, err := os.Lstat(filepath.Join(dir, "scaffold", "aqua", "crew", "mine.md")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the snapshot holds the person's own crew member as a scaffold file (%v)", err)
	}
	var snapshot map[string]any
	data, err := os.ReadFile(filepath.Join(dir, "snapshot.json"))
	if err != nil || json.Unmarshal(data, &snapshot) != nil {
		t.Fatalf("snapshot.json: %s (error %v)", data, err)
	}
	want := map[string]any{
		"version":         "0.8.0",
		"taken_at":        "2026-10-16T12:00:00Z",
		"parts":           []any{"database", "database-wal", "storage", "scaffold", "keyring", ".env", "compose"},
		"storage_adapter": "local",
		"scaffold":        []any{"aqua/aqua.md", "configuration-guide.md", "keeper.seccomp.json", "wit/cyfr/a.wit"},
		"complete":        true,
	}
	if !reflect.DeepEqual(snapshot, want) {
		t.Errorf("snapshot.json is %v, want %v", snapshot, want)
	}
	if _, err := readSnapshot(dir); err != nil {
		t.Errorf("cyfr restore refuses the backup: %v", err)
	}

	log := s.log()
	stopped, read, started := at(log, profiles+"stop caddy"), at(log, profiles+"run --rm --no-deps -T cyfr bin/cyfr eval"), at(log, "ENGINE start backup")
	if stopped < 0 || read < stopped || started < read {
		t.Errorf("cyfr backup did not stop the stack, read its release offline and start it again, in that order:\n%s", strings.Join(log, "\n"))
	}
	if s.scaffold != 0 || s.hasCall("SCAFFOLD") {
		t.Error("cyfr backup fetched a release's scaffold")
	}
	s.composeUnchanged()
	for _, line := range []string{"stopped caddy in ", "stopped cyfr in ", "The snapshot of release 0.8.0 is in " + dir + "; 'cyfr restore " + dir + "' puts it back.\n", "The stack runs again.\n"} {
		if !strings.Contains(out, line) {
			t.Errorf("cyfr backup's output lacks %q:\n%s", line, out)
		}
	}
}

// A stopped CYFR is snapshotted and stays stopped: nothing is stopped or
// started.
func TestBackupOfAStoppedCYFRLeavesItStopped(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	s.answer("ps.out", "")
	out, err := s.backup()
	if err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	s.nothingStopped()
	if _, err := readSnapshot(s.snapshotDir()); err != nil {
		t.Errorf("cyfr restore refuses the backup: %v", err)
	}
	if !strings.HasSuffix(out, "The stack was not running, so it stays stopped.\n") {
		t.Errorf("cyfr backup ended\n%s", out)
	}
}

// A snapshot that fails starts the running stack again and says so; no
// snapshot.json is written.
func TestBackupThatFailsStartsTheStackAgain(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.edit("backups", "a file where backups/ goes")
	out, err := s.backup()
	if err == nil || !strings.HasPrefix(err.Error(), "The snapshot failed: ") || !strings.HasSuffix(err.Error(), ".\nThe stack was started again") {
		t.Fatalf("a failed snapshot answered %v\n%s", err, out)
	}
	if !s.hasCall("ENGINE start backup") {
		t.Errorf("the stack was not started again:\n%s", strings.Join(s.log(), "\n"))
	}
}

// A live slot of a server outside the stack after the stop, which may
// write the database, refuses the snapshot and starts the stack again.
func TestBackupRefusesWhileAnotherServerHoldsASlot(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("eval.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[{"node":"cyfr@other","owner":"o2","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
	out, err := s.backup()
	if err == nil || !strings.Contains(err.Error(), "A slot is still live") || !strings.Contains(err.Error(), "cyfr@other (release 0.8.0)") || !strings.HasSuffix(err.Error(), "The stack was started again") {
		t.Fatalf("cyfr backup with another server's slot answered %v\n%s", err, out)
	}
	if _, err := os.Lstat(filepath.Join(s.snapshotDir(), "snapshot.json")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("a snapshot was written (%v)", err)
	}
}

// A directory without docker-compose.yml is refused before the lock, with
// nothing run.
func TestBackupRefusesADirectoryWithoutCYFR(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	if err := os.Remove(filepath.Join(s.project, "docker-compose.yml")); err != nil {
		t.Fatal(err)
	}
	_, err := s.backup()
	if err == nil || err.Error() != "There is no CYFR in this directory to back up, so nothing was done: it holds no docker-compose.yml. Run 'cyfr backup' in CYFR's directory" {
		t.Fatalf("cyfr backup answered %v", err)
	}
	if log := s.log(); len(log) != 0 {
		t.Errorf("cyfr backup ran:\n%s", strings.Join(log, "\n"))
	}
	s.noBackups()
}
