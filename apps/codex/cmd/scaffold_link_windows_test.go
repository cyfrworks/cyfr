// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// The removal update's rollback makes of a managed file the snapshot does
// not hold removes nothing through a folder linked outside the project,
// and removes through one that stays inside it.
func TestRollbackRemovesNoScaffoldFileThroughAFolderLinkedOutside(t *testing.T) {
	t.Chdir(t.TempDir())
	outside := outsideWit(t)
	if err := removeProjectFile("wit/cyfr/added.wit"); err == nil {
		t.Error("the removal went through the link")
	}
	if _, err := os.Stat(filepath.Join(outside, "cyfr", "added.wit")); err != nil {
		t.Errorf("the file outside is gone (%v)", err)
	}

	t.Chdir(t.TempDir())
	if err := os.MkdirAll(filepath.Join("interfaces", "cyfr"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("interfaces", "cyfr", "added.wit"), []byte("ours\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	plantFolderLink(t, "interfaces", "wit")
	if err := removeProjectFile("wit/cyfr/added.wit"); err != nil {
		t.Fatalf("removeProjectFile through a link inside the project: %v", err)
	}
	if _, err := os.Lstat(filepath.Join("interfaces", "cyfr", "added.wit")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("interfaces/cyfr/added.wit is still there (%v)", err)
	}
}
