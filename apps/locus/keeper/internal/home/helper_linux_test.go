// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package home

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// runHelper applies spec as the helper does, answering its exit status.
func runHelper(t *testing.T, spec HelperSpec) int {
	t.Helper()
	if err := spec.Validate(); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := run(spec, &out); err != nil {
		t.Log(err)
		return ExitFailed
	}
	return ExitDone
}

// diskHome is the home id on a disk named for athanor under a fresh root.
// The helper's work runs as the disk's own uid, never root, so as root the
// test is the keeper's real-kernel run's, which runs every helper as a
// kept uid (package serve); the runner's own user runs it here.
func diskHome(t *testing.T, athanor, id string) (root, path string) {
	t.Helper()
	if os.Getuid() == 0 {
		t.Skip("the helper runs as a disk's uid, not root: package serve runs it so as root")
	}
	root = t.TempDir()
	return root, (Kept{Root: root}).HomePath(athanor, id)
}

// Make makes, as the calling uid, a home's disk, the disk's homes' folder
// and work folder, the home and its tmp directory, each 0700; it is done
// for a home already the uid's, makes a second home beside the first and
// keeps the work folder whatever mode a session gave it, and refuses a disk,
// a home or a work folder that is a link, a file or another uid's; Measure
// counts the blocks allocated under a home.
func TestMakeAndMeasureAHome(t *testing.T) {
	root, path := diskHome(t, "ath_a", "vlt_a")
	k := Kept{Root: root}
	uid := os.Getuid()
	if err := Make(path, uid); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{k.DiskPath("ath_a"), filepath.Dir(path), path} {
		if err := CheckKeptHome(dir, uid); err != nil {
			t.Fatal(err)
		}
	}
	if err := CheckKeptHome(k.WorkOf("ath_a"), uid); err != nil {
		t.Fatalf("a new work folder: %v", err)
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
	if err := os.Chmod(k.WorkOf("ath_a"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Make(path, uid); err != nil {
		t.Fatalf("making a made home again: %v", err)
	}
	if _, err := os.Stat(filepath.Join(path, "tmp")); err != nil {
		t.Fatalf("tmp was not made again: %v", err)
	}
	second := k.HomePath("ath_a", "vlt_b")
	if err := Make(second, uid); err != nil {
		t.Fatalf("a second home on the disk: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(path, "data")); err != nil || len(data) != 1<<20 {
		t.Fatalf("the first home after the second's make: %d bytes, %v", len(data), err)
	}
	if err := Make(path, uid+1); !errors.Is(err, ErrNotKeptHome) {
		t.Fatalf("another uid's home: %v", err)
	}
	if err := CheckKeptHome(filepath.Join(root, "absent"), uid); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("an absent home: %v", err)
	}

	// A disk that is a link to another, and a work folder that is a file,
	// are never used.
	if err := os.Symlink(k.DiskPath("ath_a"), k.DiskPath("ath_b")); err != nil {
		t.Fatal(err)
	}
	if err := Make(k.HomePath("ath_b", "vlt_c"), uid); !errors.Is(err, ErrNotKeptHome) {
		t.Fatalf("a disk that is a link: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(k.DiskPath("ath_c"), ProgramsDir), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(k.WorkOf("ath_c"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Make(k.HomePath("ath_c", "vlt_d"), uid); !errors.Is(err, ErrNotKeptHome) {
		t.Fatalf("a work folder that is a file: %v", err)
	}
}

// A helper's spec names a known op and a home on a disk, never a disk's
// work folder, a disk itself or a path outside one.
func TestAHelpersSpecNamesAHomeOnADisk(t *testing.T) {
	_, path := diskHome(t, "ath_a", "vlt_a")
	uid := os.Getuid()
	for _, op := range []string{OpMake, OpMeasure, OpReset, OpRemove} {
		if err := (HelperSpec{Op: op, Path: path, UID: uid}).Validate(); err != nil {
			t.Errorf("%s of a home: %v", op, err)
		}
	}
	if err := (HelperSpec{Op: "rm", Path: path, UID: uid}).Validate(); err == nil {
		t.Fatal("an unknown op was accepted")
	}
	disk := filepath.Dir(filepath.Dir(path))
	for _, bad := range []string{"/", disk, filepath.Join(disk, WorkDir), filepath.Join(disk, ProgramsDir), filepath.Join(filepath.Dir(disk), "vlt_a"),
		filepath.Join(disk, ProgramsDir, "vlt_a", "x"), filepath.Join(disk, ProgramsDir, ".."), "/" + Person("a") + "/programs/vlt_a"} {
		if err := (HelperSpec{Op: OpMake, Path: bad, UID: uid}).Validate(); err == nil {
			t.Errorf("path %q was accepted", bad)
		}
	}
	if err := (HelperSpec{Op: OpMake, Path: path, UID: 0}).Validate(); err == nil {
		t.Fatal("uid 0 was accepted")
	}
}

// A reset empties one home and a removal takes it, as the helper does
// them: the disk's other home and its work folder keep what they hold, and
// a measure of a home not made is zero.
func TestAResetOrRemovalTouchesOneHome(t *testing.T) {
	root, path := diskHome(t, "ath_a", "vlt_a")
	k := Kept{Root: root}
	uid := os.Getuid()
	other := k.HomePath("ath_a", "vlt_b")
	for _, p := range []string{path, other} {
		if err := Make(p, uid); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(p, "signin"), []byte(p), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	tool := filepath.Join(k.WorkOf("ath_a"), "tool")
	if err := os.WriteFile(tool, []byte("tool"), 0o700); err != nil {
		t.Fatal(err)
	}
	if code := runHelper(t, HelperSpec{Op: OpReset, Path: path, UID: uid}); code != ExitDone {
		t.Fatalf("reset exited %d", code)
	}
	if entries, err := os.ReadDir(path); err != nil || len(entries) != 1 || entries[0].Name() != "tmp" {
		t.Fatalf("the reset home holds %v, %v", entries, err)
	}
	if code := runHelper(t, HelperSpec{Op: OpRemove, Path: path, UID: uid}); code != ExitDone {
		t.Fatalf("remove exited %d", code)
	}
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the removed home: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(other, "signin")); err != nil || string(data) != other {
		t.Fatalf("the other home: %q %v", data, err)
	}
	if data, err := os.ReadFile(tool); err != nil || string(data) != "tool" {
		t.Fatalf("the work folder: %q %v", data, err)
	}
	if code := runHelper(t, HelperSpec{Op: OpRemove, Path: path, UID: uid}); code != ExitDone {
		t.Fatalf("removing a home not made exited %d", code)
	}
	var measured bytes.Buffer
	if err := run(HelperSpec{Op: OpMeasure, Path: path, UID: uid}, &measured); err != nil || measured.String() != "0" {
		t.Fatalf("measuring a home not made: %q %v", measured.String(), err)
	}
}

// A measure that cannot walk the whole home answers an error, never the
// bytes it counted before it stopped: past its entry bound, or at a
// directory it cannot read.
func TestAMeasureThatStopsShortIsAFailure(t *testing.T) {
	_, path := diskHome(t, "ath_a", "vlt_short")
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
