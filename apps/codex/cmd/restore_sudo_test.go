// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"bytes"
	"errors"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// chownStandIn makes this process root, run through sudo for uid and gid
// (unset when both are ""), with every file that exists root's; it records each owner
// change by the entry's path in the project, and refuses the one for
// refused.
func chownStandIn(t *testing.T, uid, gid, refused string) map[string][2]int {
	t.Helper()
	savedEuid, savedChown, savedOwner := restoreEuid, restoreChownAt, restoreOwnerAt
	t.Cleanup(func() { restoreEuid, restoreChownAt, restoreOwnerAt = savedEuid, savedChown, savedOwner })
	t.Setenv("SUDO_UID", uid)
	t.Setenv("SUDO_GID", gid)
	restoreEuid = func() int { return 0 }
	// The entry is read as it is, and root's whatever owns it.
	restoreOwnerAt = func(dirfd int, name, path string) (int, error) {
		_, err := savedOwner(dirfd, name, path)
		return 0, err
	}
	changed := map[string][2]int{}
	restoreChownAt = func(_ int, _, path string, uid, gid int) error {
		if path == refused {
			return errors.New("operation not permitted")
		}
		changed[path] = [2]int{uid, gid}
		return nil
	}
	return changed
}

// Run through sudo, the restore gives .env, docker-compose.yml, the
// scaffold files with their directories and the engine's state back to
// the account that ran sudo, and nothing of the storage root or the
// database; root's own login, with no sudo account, changes no owner.
func TestRestoreGivesTheProjectBackToTheSudoAccount(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	changed := chownStandIn(t, "4242", "4343", "")
	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	snap, err := readSnapshot(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][2]int{".env": {4242, 4343}, "docker-compose.yml": {4242, 4343}}
	for _, name := range snap.manifest.Scaffold {
		for p := name; p != "."; p = filepath.Dir(p) {
			// The put-back removes a scaffold file the update made.
			if _, err := os.Lstat(p); err == nil {
				want[p] = [2]int{4242, 4343}
			}
		}
	}
	filepath.WalkDir(".cyfr", func(p string, _ fs.DirEntry, err error) error {
		if err == nil {
			want[p] = [2]int{4242, 4343}
		}
		return nil
	})
	if _, ok := want[".cyfr"]; !ok {
		t.Fatalf("the project has no .cyfr: %v", slices.Sorted(maps.Keys(want)))
	}
	if !maps.Equal(changed, want) {
		t.Errorf("the restore gave back %v, want %v", changed, want)
	}
	for p := range changed {
		if strings.HasPrefix(p, "data") {
			t.Errorf("the restore gave back %s, under the storage root", p)
		}
	}

	r = newRestoreScenario(t, shippedCompose(t), nil, nil)
	changed = chownStandIn(t, "", "", "")
	if out, err := r.restore(true); err != nil {
		t.Fatalf("restore as root: %v\n%s", err, out)
	}
	if len(changed) != 0 {
		t.Errorf("root's own restore gave back %v", changed)
	}
}

// An owner the restore cannot give back is said with the command that
// does, and the restore's outcome stands.
func TestRestoreSaysAnOwnerItCannotGiveBack(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	changed := chownStandIn(t, "4242", "4343", ".env")
	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Warning: .env is still root's (operation not permitted); give it back with: sudo chown -h 4242:4343 .env\n") {
		t.Errorf("the restore printed:\n%s", out)
	}
	if _, ok := changed["docker-compose.yml"]; !ok {
		t.Errorf("the other files were not given back: %v", changed)
	}
}

// Nothing is given back through a link at any level of a path: with wit a
// link out of the project, neither wit/cyfr nor wit/cyfr/added.wit, both
// outside, changes owner, and each is said; wit itself, the link in the
// project, is changed without being followed.
func TestRestoreGivesNothingBackThroughALink(t *testing.T) {
	t.Chdir(t.TempDir())
	outside := t.TempDir()
	if err := os.MkdirAll(filepath.Join(outside, "cyfr"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "cyfr", "added.wit"), []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, "wit"); err != nil {
		t.Fatal(err)
	}
	changed := chownStandIn(t, "4242", "4343", "")
	var out bytes.Buffer
	returnToSudoAccount(&snapshotFiles{manifest: snapshotManifest{Scaffold: []string{"wit/cyfr/added.wit"}}}, &out)
	if want := map[string][2]int{"wit": {4242, 4343}}; !maps.Equal(changed, want) {
		t.Errorf("the restore gave back %v, want %v", changed, want)
	}
	want := "Warning: wit/cyfr/added.wit was not given back to the account that ran sudo: its path crosses a link, which nothing is written or given back through.\n" +
		"Warning: wit/cyfr was not given back to the account that ran sudo: its path crosses a link, which nothing is written or given back through.\n"
	if out.String() != want {
		t.Errorf("the restore said:\n%s\nwant:\n%s", out.String(), want)
	}
}

// SUDO_UID and SUDO_GID are decimal digits alone; anything else is
// refused in words, and nothing changes owner.
func TestRestoreRefusesASudoAccountNotInSudosForm(t *testing.T) {
	for _, ids := range [][2]string{{"+4242", "+4343"}, {" 4242", "4343"}, {"4242", "0x10"}, {"4242", ""}, {"4242a", "4343"}, {"-1", "4343"}} {
		t.Run(ids[0]+":"+ids[1], func(t *testing.T) {
			t.Chdir(t.TempDir())
			if err := os.WriteFile(".env", nil, 0o600); err != nil {
				t.Fatal(err)
			}
			changed := chownStandIn(t, ids[0], ids[1], "")
			var out bytes.Buffer
			returnToSudoAccount(&snapshotFiles{}, &out)
			want := "Warning: SUDO_UID and SUDO_GID must each be a plain decimal number, and they are \"" + ids[0] + "\" and \"" + ids[1] + "\", so nothing the restore wrote was given back to the account that ran sudo.\n"
			if out.String() != want || len(changed) != 0 {
				t.Errorf("the restore said %q and gave back %v; want %q and nothing", out.String(), changed, want)
			}
		})
	}
}

// linkOutOfProject makes the working directory a new project whose wit is
// a link to a directory outside it holding cyfr/added.wit, and answers
// that file's path.
func linkOutOfProject(t *testing.T) string {
	t.Helper()
	t.Chdir(t.TempDir())
	outside := t.TempDir()
	if err := os.MkdirAll(filepath.Join(outside, "cyfr"), 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(outside, "cyfr", "added.wit")
	if err := os.WriteFile(file, []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, "wit"); err != nil {
		t.Fatal(err)
	}
	return file
}

// The scaffold's put-back writes and removes nothing through a link at
// any level of a file's path: with wit a link out of the project, putting
// wit/cyfr/added.wit back, or removing it, is refused, naming it, and
// nothing behind the link changes.
func TestScaffoldPutBackWritesNothingThroughALink(t *testing.T) {
	for name, held := range map[string]bool{"put back": true, "removed": false} {
		t.Run(name, func(t *testing.T) {
			outside := linkOutOfProject(t)
			snapshot := t.TempDir()
			if held {
				if err := os.MkdirAll(filepath.Join(snapshot, "scaffold", "wit", "cyfr"), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(snapshot, "scaffold", "wit", "cyfr", "added.wit"), []byte("snapshot"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			err := putScaffoldBack(snapshot, []string{"wit/cyfr/added.wit"})
			verb := "remove"
			if held {
				verb = "put"
			}
			want := verb + " wit/cyfr/added.wit"
			if held {
				want += " back"
			}
			want += ": crosses a link, which nothing is written or given back through"
			if err == nil || err.Error() != want {
				t.Fatalf("the put-back answered %v, want %q", err, want)
			}
			if got, _ := os.ReadFile(outside); string(got) != "outside" {
				t.Errorf("the file behind the link holds %q", got)
			}
			if entries, _ := os.ReadDir(filepath.Dir(outside)); len(entries) != 1 {
				t.Errorf("the directory behind the link holds %v", entries)
			}
		})
	}
}
