// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestNewNameIsNamedForTheUidWith128RandomBits(t *testing.T) {
	a, err := NewName(20007)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewName(20007)
	if !regexp.MustCompile(`^20007-[0-9a-f]{32}$`).MatchString(a) || a == b {
		t.Fatalf("names %q %q", a, b)
	}
	if err := Validate("/homes", "/homes/"+a, 20007); err != nil {
		t.Fatalf("a fresh name does not validate: %v", err)
	}
}

func TestValidateRefusesHomesOutsideTheRootOrNamedForAnotherUid(t *testing.T) {
	name := "20007-0123456789abcdef0123456789abcdef"
	for _, c := range []struct{ root, home string }{
		{"/homes", "/homes/../etc/" + name},
		{"/homes", "/homes/sub/" + name},
		{"/homes", "/other/" + name},
		{"/homes", "/homes/20008-0123456789abcdef0123456789abcdef"},
		{"/homes", "/homes/20007-0123"},
		{"/homes", "/homes/020007-0123456789abcdef0123456789abcdef"},
		{"/homes", "/homes"},
		{"homes", "homes/" + name},
		{"/homes/", "/homes/" + name},
	} {
		if err := Validate(c.root, c.home, 20007); err == nil {
			t.Errorf("%s under %s accepted", c.home, c.root)
		}
	}
}

func TestRemoveDeletesATreeTheOwnerMadeUnwritable(t *testing.T) {
	root := t.TempDir()
	h := filepath.Join(root, "home")
	deep := filepath.Join(h, "a", "b")
	if err := os.MkdirAll(deep, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(deep, "f"), []byte("x"), 0o000); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/", filepath.Join(h, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(deep, 0o000); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(h, "a"), 0o500); err != nil {
		t.Fatal(err)
	}

	if err := Remove(h, os.Getuid()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(h); !os.IsNotExist(err) {
		t.Fatalf("home still present: %v", err)
	}
	if err := Remove(h, os.Getuid()); err != nil {
		t.Fatalf("removing an absent home: %v", err)
	}
}

func TestRemoveNeedsNoReadPermissionOnTheRoot(t *testing.T) {
	root := t.TempDir()
	h := filepath.Join(root, "home")
	if err := os.MkdirAll(filepath.Join(h, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o300); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(root, 0o700)

	if err := Remove(h, os.Getuid()); err != nil {
		t.Fatalf("removing a home under a write-and-search-only root: %v", err)
	}
	if _, err := os.Lstat(h); !os.IsNotExist(err) {
		t.Fatalf("home still present: %v", err)
	}
}

func TestRemoveRefusesAHomeOwnedByAnotherUidOrNotADirectory(t *testing.T) {
	root := t.TempDir()
	if err := Remove(root, os.Getuid()+1); err == nil {
		t.Error("a directory owned by another uid was removed")
	}
	file := filepath.Join(root, "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Remove(file, os.Getuid()); err == nil {
		t.Error("a regular file was accepted as a home")
	}
}

func TestCheckRootWantsSticky1733OwnedByRoot(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := CheckRoot(dir); err == nil {
		t.Error("a 0755 root was accepted")
	}
	if err := os.Chmod(dir, os.ModeSticky|0o733); err != nil {
		t.Fatal(err)
	}
	err := CheckRoot(dir)
	if os.Getuid() == 0 && err != nil {
		t.Errorf("a root-owned 1733 root was refused: %v", err)
	}
	if os.Getuid() != 0 && err == nil {
		t.Error("a root not owned by uid 0 was accepted")
	}
}
