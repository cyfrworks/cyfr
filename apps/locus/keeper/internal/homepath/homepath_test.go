// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package homepath

import (
	"os"
	"path/filepath"
	"testing"
)

// A way down follows no link: a linked folder at any step, or a link at
// its end, is refused, and nothing is made, read, written or removed
// through it.
func TestAWayDownFollowsNoLink(t *testing.T) {
	for _, linked := range []string{"a", "a/b", "a/b/file"} {
		t.Run(linked, func(t *testing.T) {
			home, elsewhere := t.TempDir(), t.TempDir()
			target := filepath.Join(elsewhere, "target")
			if linked == "a/b/file" {
				if err := os.WriteFile(target, []byte("kept"), 0o600); err != nil {
					t.Fatal(err)
				}
			} else if err := os.MkdirAll(filepath.Join(target, "b"), 0o700); err != nil {
				t.Fatal(err)
			} else if err := os.WriteFile(filepath.Join(target, "b", "file"), []byte("kept"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Dir(filepath.Join(home, linked)), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, filepath.Join(home, linked)); err != nil {
				t.Fatal(err)
			}
			p := Path{home, "a/b/file"}
			if _, err := ReadFile(p); !Refused(err) {
				t.Fatalf("a read through a link is refused: %v", err)
			}
			if err := WriteFile(p, []byte("x")); !Refused(err) {
				t.Fatalf("a write through a link is refused: %v", err)
			}
			if _, err := Present(p); !Refused(err) {
				t.Fatalf("a look through a link is refused: %v", err)
			}
			if err := RemoveAll(p); !Refused(err) {
				t.Fatalf("a removal through a link is refused: %v", err)
			}
			if _, err := Walk(home, "a/b/c", true); !Refused(err) && linked != "a/b/file" {
				t.Fatalf("a folder made through a link is refused: %v", err)
			}
			kept := target
			if linked != "a/b/file" {
				kept = filepath.Join(target, "b", "file")
			}
			if b, err := os.ReadFile(kept); err != nil || string(b) != "kept" {
				t.Fatalf("the link's target is left as it was: %q %v", b, err)
			}
			if entries, _ := os.ReadDir(filepath.Join(target, "b")); linked != "a/b/file" && len(entries) != 1 {
				t.Fatalf("nothing is made through the link: %v", entries)
			}
		})
	}
}

// Folders are made 0700 on the way down; a file is written and read
// back; a tree is removed whole, a link inside it removed itself and its
// target left; a missing way is absent, and its removal no error.
func TestAWayDownMakesReadsAndRemoves(t *testing.T) {
	home, elsewhere := t.TempDir(), t.TempDir()
	p := Path{home, "a/b/file"}
	if err := WriteFile(p, []byte("one")); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Lstat(filepath.Join(home, "a", "b")); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("folders are made 0700: %v %v", info, err)
	}
	if b, err := ReadFile(p); err != nil || string(b) != "one" {
		t.Fatalf("the file reads back: %q %v", b, err)
	}
	outside := filepath.Join(elsewhere, "outside")
	_ = os.WriteFile(outside, []byte("kept"), 0o600)
	_ = os.Symlink(outside, filepath.Join(home, "a", "b", "link"))
	if err := RemoveAll(Path{home, "a"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(home, "a")); !os.IsNotExist(err) {
		t.Fatalf("the tree is removed: %v", err)
	}
	if b, err := os.ReadFile(outside); err != nil || string(b) != "kept" {
		t.Fatalf("a link inside is removed, its target left: %q %v", b, err)
	}
	if ok, err := Present(p); ok || err != nil {
		t.Fatalf("a missing way is absent: %v %v", ok, err)
	}
	if err := RemoveAll(p); err != nil {
		t.Fatalf("removing what is not there is no error: %v", err)
	}
	if _, err := ReadFile(p); !Absent(err) {
		t.Fatalf("a missing file reads as absent: %v", err)
	}
}
