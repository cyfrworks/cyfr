// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package scaffold

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// plantLink makes link a symbolic link to target, skipping the test on a
// system that makes none for this account (Windows without the privilege
// or developer mode): there no person's install holds such a link either.
func plantLink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("this system makes no symbolic link here: %v", err)
	}
}

// refusal is what Write and Check answer for wit/ as a link they do not
// follow.
const refusal = "wit is a link cyfr does not write through: make wit a real folder, or a relative link to a folder inside the install"

// linkedRelease writes in wit/ and at the project's root.
func linkedRelease() *Release {
	return &Release{entries: []entry{
		{name: "configuration-guide.md", mode: 0o644, data: []byte("# Configuration\n")},
		{name: "wit", dir: true},
		{name: "wit/cyfr", dir: true},
		{name: "wit/cyfr/added.wit", mode: 0o644, data: []byte("package cyfr:added;\n")},
	}}
}

func listTree(t *testing.T, dir string) []string {
	t.Helper()
	var names []string
	err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p != dir {
			rel, _ := filepath.Rel(dir, p)
			names = append(names, filepath.ToSlash(rel))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return names
}

// A folder the scaffold writes in that is a link leading outside the
// project refuses, for init and update alike, before any file is written:
// none outside the project, none in it. A file already reached through
// that link refuses rather than being skipped. Both an absolute and a
// relative link refuse.
func TestWriteRefusesAFolderLinkedOutside(t *testing.T) {
	for _, c := range []struct {
		name      string
		overwrite bool
		relative  bool
		existing  bool
	}{
		{"init", false, false, false},
		{"update", true, false, false},
		{"init, relative link", false, true, false},
		{"init, a file there already", false, false, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			parent := t.TempDir()
			project, outside := filepath.Join(parent, "project"), filepath.Join(parent, "outside")
			for _, d := range []string{project, outside} {
				if err := os.Mkdir(d, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			t.Chdir(project)
			target := outside
			if c.relative {
				target = filepath.Join("..", "outside")
			}
			plantLink(t, target, "wit")
			var before []string
			if c.existing {
				if err := os.MkdirAll(filepath.Join(outside, "cyfr"), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(outside, "cyfr", "added.wit"), []byte("theirs\n"), 0o644); err != nil {
					t.Fatal(err)
				}
				before = listTree(t, outside)
			}
			err := linkedRelease().Write(c.overwrite)
			if !errors.Is(err, ErrLinkNotFollowed) || err.Error() != refusal {
				t.Fatalf("Write answered %v", err)
			}
			if got := listTree(t, outside); !slices.Equal(got, before) {
				t.Errorf("written outside the project: %v", got)
			}
			if got := listTree(t, project); !slices.Equal(got, []string{"wit"}) {
				t.Errorf("the project holds %v after the refusal", got)
			}
			if got, _ := os.ReadFile(filepath.Join(outside, "cyfr", "added.wit")); c.existing && string(got) != "theirs\n" {
				t.Errorf("the file outside reads %q", got)
			}
			if err := linkedRelease().Check(); !errors.Is(err, ErrLinkNotFollowed) {
				t.Errorf("Check answered %v", err)
			}
		})
	}
}

// A link that stays inside the project is followed: the release writes
// through it into the folder it names, and nothing refuses.
func TestWriteFollowsAFolderLinkThatStaysInside(t *testing.T) {
	for _, overwrite := range []bool{false, true} {
		t.Chdir(t.TempDir())
		if err := os.Mkdir("interfaces", 0o755); err != nil {
			t.Fatal(err)
		}
		plantLink(t, "interfaces", "wit")
		if err := linkedRelease().Check(); err != nil {
			t.Fatalf("Check: %v", err)
		}
		if err := linkedRelease().Write(overwrite); err != nil {
			t.Fatalf("Write(%v): %v", overwrite, err)
		}
		if got, err := os.ReadFile(filepath.Join("interfaces", "cyfr", "added.wit")); err != nil || string(got) != "package cyfr:added;\n" {
			t.Errorf("Write(%v) left interfaces/cyfr/added.wit %q (%v)", overwrite, got, err)
		}
		if got, err := os.ReadFile("configuration-guide.md"); err != nil || string(got) != "# Configuration\n" {
			t.Errorf("Write(%v) left the guide %q (%v)", overwrite, got, err)
		}
		if info, err := os.Lstat("wit"); err != nil || info.Mode()&os.ModeSymlink == 0 {
			t.Errorf("wit is no longer the link (%v)", err)
		}
	}
}

// An absolute link, even to a folder inside the project, and a loop of
// links inside it are refused as links the root does not follow, before
// anything is written; the refusal's advice works: wit made a relative
// link to a folder inside, the write goes through.
func TestWriteRefusesALinkTheRootDoesNotFollow(t *testing.T) {
	for _, c := range []string{"absolute link to a folder inside", "loop inside"} {
		t.Run(c, func(t *testing.T) {
			project := t.TempDir()
			t.Chdir(project)
			if err := os.Mkdir("interfaces", 0o755); err != nil {
				t.Fatal(err)
			}
			if c == "loop inside" {
				plantLink(t, "alias", "wit")
				plantLink(t, "wit", "alias")
			} else {
				plantLink(t, filepath.Join(project, "interfaces"), "wit")
			}
			if err := linkedRelease().Check(); err == nil || err.Error() != refusal {
				t.Fatalf("Check answered %v", err)
			}
			if err := linkedRelease().Write(true); err == nil || err.Error() != refusal {
				t.Fatalf("Write answered %v", err)
			}
			if got := listTree(t, "interfaces"); len(got) != 0 {
				t.Errorf("written before the refusal: %v", got)
			}
			if _, err := os.Lstat("configuration-guide.md"); err == nil {
				t.Error("the guide was written before the refusal")
			}
			if err := os.Remove("wit"); err != nil {
				t.Fatal(err)
			}
			plantLink(t, "interfaces", "wit")
			if err := linkedRelease().Write(true); err != nil {
				t.Fatalf("Write through a relative link inside: %v", err)
			}
			if got, err := os.ReadFile(filepath.Join("interfaces", "cyfr", "added.wit")); err != nil || string(got) != "package cyfr:added;\n" {
				t.Errorf("interfaces/cyfr/added.wit is %q (%v)", got, err)
			}
		})
	}
}
