// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
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

// keptOfMine is a kept-homes root in a fresh directory whose range starts at
// the test's own uid, which owns every folder the test makes there, so a
// home's owner is read without root.
func keptOfMine(t *testing.T, size int) Kept {
	t.Helper()
	me := os.Getuid()
	return Kept{Root: t.TempDir(), First: me, Last: me + size - 1}
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
