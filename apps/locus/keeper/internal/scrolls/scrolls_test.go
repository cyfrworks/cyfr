// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package scrolls

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func tree(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err == nil && p != root {
			rel, _ := filepath.Rel(root, p)
			out = append(out, rel)
		}
		return nil
	})
	sort.Strings(out)
	return out
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// The folder is the session's own: in its TMPDIR, 0700 and named for the
// driver alone, two drivers never sharing one, and nothing in the home.
func TestTheFolderIsTheSessionsOwnAndGoesAtTheEnd(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	a, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	b, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(a.Path()) != tmp || a.Path() == b.Path() || !strings.HasPrefix(filepath.Base(a.Path()), "cyfr-scrolls-") {
		t.Fatalf("each driver has a folder of its own in TMPDIR: %s %s", a.Path(), b.Path())
	}
	if info, err := os.Stat(a.Path()); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("the folder is 0700: %v %v", info, err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(a.Path()); !os.IsNotExist(err) {
		t.Fatalf("the folder goes at the driver's end: %v", err)
	}
	if got := tree(t, b.Path()); !equal(got, []string{".claude-plugin", ".claude-plugin/plugin.json", "skills"}) {
		t.Fatalf("another driver's folder is untouched: %v", got)
	}
	b.Close()
}

func TestAStartsSetIsWrittenWholeAndTheNextReplacesIt(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	f, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := f.Put("research", `Find "it" out`, "Step one.\n"); err != nil {
		t.Fatal(err)
	}
	if err := f.Put("Caps_name-2", "", "Body"); err != nil {
		t.Fatal(err)
	}
	if err := f.Put("gone", "", "Body"); err != nil {
		t.Fatal(err)
	}
	if err := f.TakeBack("gone"); err != nil {
		t.Fatal(err)
	}
	names, err := f.Start()
	if err != nil || !equal(names, []string{"research", "Caps_name-2"}) {
		t.Fatalf("names %v, %v", names, err)
	}
	dir := f.Path()
	if f.Root() != filepath.Join(dir, "skills") {
		t.Fatalf("root %s", f.Root())
	}
	want := []string{".claude-plugin", ".claude-plugin/plugin.json", "skills", "skills/Caps_name-2", "skills/Caps_name-2/SKILL.md", "skills/research", "skills/research/SKILL.md"}
	if got := tree(t, dir); !equal(got, want) {
		t.Fatalf("tree %v", got)
	}
	if got := read(t, filepath.Join(dir, "skills/research/SKILL.md")); got != "---\nname: \"research\"\ndescription: \"Find \\\"it\\\" out\"\n---\n\nStep one.\n" {
		t.Fatalf("manifest %q", got)
	}
	if got := read(t, filepath.Join(dir, ".claude-plugin/plugin.json")); got != `{"description":"The athanor's scrolls, placed by CYFR for this start.","name":"cyfr","version":"0.0.0"}` {
		t.Fatalf("plugin %q", got)
	}
	// What a turn added to the folder is gone at the next start's set.
	if err := os.WriteFile(filepath.Join(dir, "skills", "planted"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := f.Put("web", "Web", "W"); err != nil {
		t.Fatal(err)
	}
	if names, _ := f.Start(); !equal(names, []string{"web"}) {
		t.Fatalf("names %v", names)
	}
	if got := tree(t, filepath.Join(dir, "skills")); !equal(got, []string{"web", "web/SKILL.md"}) {
		t.Fatalf("second set %v", got)
	}
	// A start handed no scroll has none.
	if names, err := f.Start(); names != nil || err != nil {
		t.Fatalf("empty start %v %v", names, err)
	}
	if got := tree(t, filepath.Join(dir, "skills")); len(got) != 0 {
		t.Fatalf("an empty set's skills: %v", got)
	}
}

func TestANameOfAnotherGrammarIsRefused(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	f, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, name := range []string{"", "..", "a/b", "-lead", "sp ace", ".hidden"} {
		if err := f.Put(name, "", "b"); err == nil {
			t.Fatalf("%q placed", name)
		}
	}
}

// A link a turn planted in the folder is never written through.
func TestALinkInTheFolderIsNotFollowed(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	f, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	elsewhere := t.TempDir()
	if err := f.Put("first", "", "b"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(f.Root(), "linked")); err != nil {
		t.Fatal(err)
	}
	if err := f.Put("linked", "", "b"); err == nil {
		t.Fatal("a scroll was written through a link")
	}
	if got := tree(t, elsewhere); len(got) != 0 {
		t.Fatalf("written through the link %v", got)
	}
}
