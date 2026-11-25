// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
)

func TestParseKept(t *testing.T) {
	k, err := ParseKept("/var/lib/locus/kept:40001-49999")
	if err != nil || k != (Kept{Root: "/var/lib/locus/kept", First: 40001, Last: 49999}) {
		t.Fatalf("parsed %+v %v", k, err)
	}
	if !k.Contains(40001) || !k.Contains(49999) || k.Contains(50000) {
		t.Fatalf("kept %+v", k)
	}
	for _, bad := range []string{"", "/k", "k:1-2", "/:1-2", "/k/:1-2", "/k:2-1", "/k:0-2", "/k:1-x", "/k:1-70000"} {
		if _, err := ParseKept(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestKeptValidate(t *testing.T) {
	k := Kept{Root: "/k", First: 10, Last: 20}
	if err := k.Validate("/k/vlt_01a-b_c", 15); err != nil {
		t.Fatal(err)
	}
	for path, uid := range map[string]int{
		"/k/vlt_a":     21,
		"/k/a/b":       15,
		"/other/vlt_a": 15,
		"/k/../k/a":    15,
		"/k/.hidden":   15,
		"/k":           15,
	} {
		if err := k.Validate(path, uid); err == nil {
			t.Errorf("%s as %d accepted", path, uid)
		}
	}
}

// keptOfMine is a kept-homes root in a fresh directory whose range starts at
// the test's own uid, which owns every folder the test makes there, so a
// home's owner is read without root.
func keptOfMine(t *testing.T, size int) Kept {
	t.Helper()
	me := os.Getuid()
	return Kept{Root: t.TempDir(), First: me, Last: me + size - 1}
}

// A home's uid is its folder's owner, read without following a link: a
// folder of a uid of the range is a home, a link to one or a file is none,
// and an absent one is absent. IDs names the homes alone, in byte order.
func TestAKeptHomesUIDIsItsFoldersOwner(t *testing.T) {
	k := keptOfMine(t, 1)
	for _, dir := range []string{"vlt_b", "vlt_a", "Z9"} {
		if err := os.Mkdir(filepath.Join(k.Root, dir), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(k.Root, "a-file"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(k.Root, "vlt_a"), filepath.Join(k.Root, "vlt_link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(k.Root, ".hidden"), 0o700); err != nil {
		t.Fatal(err)
	}
	if uid, err := k.Owner("vlt_a"); err != nil || uid != k.First {
		t.Fatalf("vlt_a's owner: %d %v", uid, err)
	}
	for _, id := range []string{"a-file", "vlt_link"} {
		if _, err := k.Owner(id); !errors.Is(err, ErrNotKeptHome) {
			t.Errorf("%s: %v", id, err)
		}
	}
	if _, err := k.Owner("vlt_absent"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("an absent home: %v", err)
	}
	if ids, err := k.IDs(); err != nil || !reflect.DeepEqual(ids, []string{"Z9", "vlt_a", "vlt_b"}) {
		t.Fatalf("ids %v %v", ids, err)
	}
	// A folder of a uid outside the range is no home.
	other := Kept{Root: k.Root, First: k.First + 1, Last: k.First + 1}
	if _, err := other.Owner("vlt_a"); !errors.Is(err, ErrNotKeptHome) {
		t.Fatalf("a folder of a uid outside the range: %v", err)
	}
	if ids, err := other.IDs(); err != nil || len(ids) != 0 {
		t.Fatalf("ids of a range that owns none: %v %v", ids, err)
	}
	if _, err := (Kept{Root: filepath.Join(k.Root, "absent"), First: 1, Last: 1}).IDs(); err == nil {
		t.Fatal("a root that cannot be read was listed")
	}
}

// A uid is taken by the owner of any entry under the root, a home or not,
// and by any process that holds it, even one whose home's folder is gone;
// a root or a /proc that cannot be read takes them all.
func TestAKeptUIDIsTakenByAFolderOrAProcess(t *testing.T) {
	k := keptOfMine(t, 3)
	proc := t.TempDir()
	if taken, err := k.Taken(proc); err != nil || len(taken) != 0 {
		t.Fatalf("an empty root and /proc: %v %v", taken, err)
	}
	if err := os.WriteFile(filepath.Join(k.Root, "not-a-home.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(proc, "4242"), 0o755); err != nil {
		t.Fatal(err)
	}
	status := "Name:\tsleep\nState:\tS (sleeping)\nUid:\t1\t" + strconv.Itoa(k.First+1) + "\t1\t1\n" +
		"CapInh:\t0\nCapPrm:\t0\nCapEff:\t0\nCapBnd:\t0\nCapAmb:\t0\n"
	if err := os.WriteFile(filepath.Join(proc, "4242", "status"), []byte(status), 0o644); err != nil {
		t.Fatal(err)
	}
	taken, err := k.Taken(proc)
	if want := map[int]bool{k.First: true, k.First + 1: true}; err != nil || !reflect.DeepEqual(taken, want) {
		t.Fatalf("taken %v %v, want %v", taken, err, want)
	}
	if _, err := k.Taken(filepath.Join(proc, "absent")); err == nil {
		t.Fatal("a /proc that cannot be read took nothing")
	}
	if _, err := (Kept{Root: filepath.Join(k.Root, "absent"), First: k.First, Last: k.Last}).Taken(proc); err == nil {
		t.Fatal("a root that cannot be read took nothing")
	}
}
