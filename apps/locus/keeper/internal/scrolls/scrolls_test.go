// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package scrolls

import (
	"os"
	"path/filepath"
	"sort"
	"testing"

	"golang.org/x/sys/unix"
)

const (
	bootA = "0123456789abcdef0123456789abcdef"
	bootB = "fedcba9876543210fedcba9876543210"
	bootC = "00000000000000000000000000000000"
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

func TestAStartsSetIsWrittenWholeAndTheNextReplacesIt(t *testing.T) {
	home := t.TempDir()
	f, err := Open(home, bootA)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Put("research", `Find "it" out`, "Step one.\n"); err != nil {
		t.Fatal(err)
	}
	if err := f.Put("Caps_name-2", "", "Body"); err != nil {
		t.Fatal(err)
	}
	names, err := f.Start()
	if err != nil || len(names) != 2 || names[0] != "research" || names[1] != "Caps_name-2" {
		t.Fatalf("names %v, %v", names, err)
	}
	dir := filepath.Join(home, ".cyfr", "scrolls", bootA)
	if f.Path() != dir || f.Root() != filepath.Join(dir, "skills") {
		t.Fatalf("paths %s %s", f.Path(), f.Root())
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
	if names, _ := f.Start(); len(names) != 1 || names[0] != "web" {
		t.Fatalf("names %v", names)
	}
	if got := tree(t, filepath.Join(dir, "skills")); !equal(got, []string{"web", "web/SKILL.md"}) {
		t.Fatalf("second set %v", got)
	}
	// A start handed no scroll has no folder.
	if names, err := f.Start(); names != nil || err != nil {
		t.Fatalf("empty start %v %v", names, err)
	}
	if _, err := os.Lstat(dir); !os.IsNotExist(err) {
		t.Fatalf("folder of an empty set: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	if got := tree(t, filepath.Join(home, ".cyfr", "scrolls")); len(got) != 0 {
		t.Fatalf("left at the end %v", got)
	}
}

func TestANameOfAnotherGrammarIsRefused(t *testing.T) {
	f, err := Open(t.TempDir(), bootA)
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

func TestASweepRemovesADeadBootsFolderAndKeepsALiveOnes(t *testing.T) {
	home := t.TempDir()
	place := filepath.Join(home, ".cyfr", "scrolls")
	live, err := Open(home, bootB)
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close()
	if err := live.Put("research", "", "live"); err != nil {
		t.Fatal(err)
	}
	// A killed driver's: its folder and its lock, which nobody holds; and a
	// folder whose lock is gone.
	for _, p := range []string{bootC + "/skills/x", "11111111111111111111111111111111/skills/y"} {
		if err := os.MkdirAll(filepath.Join(place, p), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(place, bootC+".lock"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	// What is not a boot's is never touched.
	if err := os.MkdirAll(filepath.Join(place, "mine"), 0o700); err != nil {
		t.Fatal(err)
	}
	f, err := Open(home, bootA)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	want := []string{bootA + ".lock", bootB, bootB + "/.claude-plugin", bootB + "/.claude-plugin/plugin.json", bootB + "/skills",
		bootB + "/skills/research", bootB + "/skills/research/SKILL.md", bootB + ".lock", "mine"}
	sort.Strings(want)
	if got := tree(t, place); !equal(got, want) {
		t.Fatalf("after the sweep %v", got)
	}
}

func TestTheLockIsHeldAndNotInherited(t *testing.T) {
	home := t.TempDir()
	f, err := Open(home, bootA)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	other, err := os.OpenFile(filepath.Join(home, ".cyfr", "scrolls", bootA+".lock"), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if err := unix.Flock(int(other.Fd()), unix.LOCK_EX|unix.LOCK_NB); err == nil {
		t.Fatal("the lock was not held")
	}
	flags, err := unix.FcntlInt(f.lock.Fd(), unix.F_GETFD, 0)
	if err != nil || flags&unix.FD_CLOEXEC == 0 {
		t.Fatalf("the lock passes to a program: %v %v", flags, err)
	}
	if _, err := Open(home, bootA); err == nil {
		t.Fatal("a second holder of one boot")
	}
}

func TestALinkOnTheWayIsRefused(t *testing.T) {
	home := t.TempDir()
	elsewhere := t.TempDir()
	if err := os.Symlink(elsewhere, filepath.Join(home, ".cyfr")); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(home, bootA); err == nil {
		t.Fatal("a folder opened through a link")
	}
	if got := tree(t, elsewhere); len(got) != 0 {
		t.Fatalf("written through the link %v", got)
	}
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
