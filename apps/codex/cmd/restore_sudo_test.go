// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !windows

package cmd

import (
	"errors"
	"io/fs"
	"maps"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// chownStandIn makes this process root, run through sudo for 4242:4343
// unless sudo is false, with every file root's; it records each owner
// change, and refuses the one for refused.
func chownStandIn(t *testing.T, sudo bool, refused string) map[string][2]int {
	t.Helper()
	savedEuid, savedChown, savedOwner := restoreEuid, restoreChown, restoreOwner
	t.Cleanup(func() { restoreEuid, restoreChown, restoreOwner = savedEuid, savedChown, savedOwner })
	if sudo {
		t.Setenv("SUDO_UID", "4242")
		t.Setenv("SUDO_GID", "4343")
	} else {
		t.Setenv("SUDO_UID", "")
		t.Setenv("SUDO_GID", "")
	}
	restoreEuid = func() int { return 0 }
	restoreOwner = func(string) (int, error) { return 0, nil }
	changed := map[string][2]int{}
	restoreChown = func(path string, uid, gid int) error {
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
	changed := chownStandIn(t, true, "")
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
			want[p] = [2]int{4242, 4343}
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
	changed = chownStandIn(t, false, "")
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
	changed := chownStandIn(t, true, ".env")
	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Warning: .env is still root's (operation not permitted); give it back with: sudo chown 4242:4343 .env\n") {
		t.Errorf("the restore printed:\n%s", out)
	}
	if _, ok := changed["docker-compose.yml"]; !ok {
		t.Errorf("the other files were not given back: %v", changed)
	}
}
