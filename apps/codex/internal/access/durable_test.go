// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"os"
	"path/filepath"
	"testing"
)

// ReplaceFile then SyncDir is a durable rename on every platform, Windows
// among them, where SyncDir needs no directory handle since ReplaceFile
// writes the rename through.
func TestReplaceFileThenSyncDirIsADurableRename(t *testing.T) {
	dir := t.TempDir()
	from, to := filepath.Join(dir, "staged"), filepath.Join(dir, "docker-compose.yml")
	for name, data := range map[string]string{from: "new", to: "old"} {
		if err := os.WriteFile(name, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := ReplaceFile(from, to); err != nil {
		t.Fatalf("ReplaceFile: %v", err)
	}
	if err := SyncDir(dir); err != nil {
		t.Fatalf("SyncDir: %v", err)
	}
	if got, err := os.ReadFile(to); err != nil || string(got) != "new" {
		t.Fatalf("the file holds %q (%v)", got, err)
	}
	if _, err := os.Stat(from); !os.IsNotExist(err) {
		t.Fatalf("the staged file is still there: %v", err)
	}
}
