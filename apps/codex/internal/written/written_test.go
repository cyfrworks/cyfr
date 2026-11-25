// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package written

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// A write is recorded once, at the real path it landed on, the links of
// its directory resolved (macOS's /var among them) and the entry itself
// not: a directory made is marked so; nothing is recorded while no run
// records.
func TestARunRecordsTheRealPathOfEachWrite(t *testing.T) {
	dir := t.TempDir()
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "interfaces"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("interfaces", filepath.Join(dir, "wit")); err != nil {
		t.Skipf("this system makes no symbolic link here: %v", err)
	}
	File(filepath.Join(dir, "before"))
	s := Begin()
	File(filepath.Join(dir, "wit", "added.wit"))
	Dir(filepath.Join(dir, "made"))
	File(filepath.Join(dir, "interfaces", "added.wit"))
	File(filepath.Join(dir, "wit"))
	s.End()
	File(filepath.Join(dir, "after"))
	want := []Entry{
		{Path: filepath.Join(real, "interfaces", "added.wit")},
		{Path: filepath.Join(real, "made"), Made: true},
		{Path: filepath.Join(real, "wit")},
	}
	if got := s.Entries(); !slices.Equal(got, want) {
		t.Errorf("the run recorded %v, want %v", got, want)
	}
}
