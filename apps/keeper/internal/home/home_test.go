// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"os"
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
