// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package home

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// Make makes a home 0700 with its tmp directory as the calling uid, is done
// for a home already the uid's, and refuses one that is not; Measure counts
// the blocks allocated under it.
func TestMakeAndMeasureAHome(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "vlt_a")
	uid := os.Getuid()
	if err := Make(path, uid); err != nil {
		t.Fatal(err)
	}
	if err := CheckKeptHome(path, uid); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Join(path, "tmp")); err != nil || !info.IsDir() {
		t.Fatalf("tmp: %v", err)
	}
	empty, err := Measure(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "data"), make([]byte, 1<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	full, err := Measure(path)
	if err != nil || full < empty+1<<20 {
		t.Fatalf("measured %d after %d with a MiB written: %v", full, empty, err)
	}
	if err := os.RemoveAll(filepath.Join(path, "tmp")); err != nil {
		t.Fatal(err)
	}
	if err := Make(path, uid); err != nil {
		t.Fatalf("making a made home again: %v", err)
	}
	if _, err := os.Stat(filepath.Join(path, "tmp")); err != nil {
		t.Fatalf("tmp was not made again: %v", err)
	}
	if err := Make(path, uid+1); !errors.Is(err, ErrNotKeptHome) {
		t.Fatalf("another uid's home: %v", err)
	}
	if err := CheckKeptHome(filepath.Join(root, "absent"), uid); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("an absent home: %v", err)
	}
	if err := (HelperSpec{Op: "rm", Path: path, UID: uid}).Validate(); err == nil {
		t.Fatal("an unknown op was accepted")
	}
	if err := (HelperSpec{Op: OpMake, Path: "/", UID: uid}).Validate(); err == nil {
		t.Fatal("a root path was accepted")
	}
}

// A measure that cannot walk the whole home answers an error, never the
// bytes it counted before it stopped: past its entry bound, or at a
// directory it cannot read.
func TestAMeasureThatStopsShortIsAFailure(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "vlt_short")
	if err := Make(path, os.Getuid()); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a", "b", "c", "d"} {
		if err := os.WriteFile(filepath.Join(path, name), make([]byte, 4096), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	saved := maxMeasured
	maxMeasured = 3
	t.Cleanup(func() { maxMeasured = saved })
	if bytes, err := Measure(path); !errors.Is(err, ErrUnmeasured) || bytes != 0 {
		t.Fatalf("a walk past its bound answered %d, %v", bytes, err)
	}
	maxMeasured = saved

	if os.Getuid() == 0 {
		t.Skip("root reads a 0000 directory; the unreadable case needs another uid")
	}
	locked := filepath.Join(path, "locked")
	if err := os.Mkdir(locked, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(locked, "big"), make([]byte, 1<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o700) })
	if bytes, err := Measure(path); err == nil || bytes != 0 {
		t.Fatalf("a walk at an unreadable directory answered %d, %v", bytes, err)
	}
}
