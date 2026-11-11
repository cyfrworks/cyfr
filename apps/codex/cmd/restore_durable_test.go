// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

// writeDurable replaces a file and makes the rename durable on every
// platform the CLI ships for, Windows among them, where a directory handle
// cannot be flushed: it answers no error, the file holds the new bytes,
// and no temporary file is left beside it.
func TestWriteDurable_ReplacesTheFileOnEveryPlatform(t *testing.T) {
	dir := t.TempDir()
	name := filepath.Join(dir, ".env")
	if err := os.WriteFile(name, []byte("OLD=1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeDurable(name, []byte("NEW=1\n"), 0600); err != nil {
		t.Fatalf("writeDurable: %v", err)
	}
	if got, err := os.ReadFile(name); err != nil || string(got) != "NEW=1\n" {
		t.Fatalf("the file holds %q (%v)", got, err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("the directory holds %v (%v), want the file alone", entries, err)
	}
}
