// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// plantPacks makes a packs folder as the keeper binds one: two packs, and
// what is no pack (a file, a link, a dot name).
func plantPacks(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "packs")
	for _, dir := range []string{"pstack/.claude-plugin", "taste-skill/skills/taste-skill", ".hidden"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []string{"pstack/.claude-plugin/plugin.json", "taste-skill/skills/taste-skill/SKILL.md", "README"} {
		if err := os.WriteFile(filepath.Join(root, file), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(root, "linked")); err != nil {
		t.Fatal(err)
	}
	return root
}

// treeOf is every path under root with its mode and content.
func treeOf(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		b, _ := os.ReadFile(p)
		out[rel] = info.Mode().String() + " " + string(b)
		return nil
	})
	return out
}

// Each pack folder in the space is a `--plugin-dir` of the harness, in
// name order, at a start and at a resume; a file, a link and a dot name
// are not. Nothing under the packs or the home's own skills changes.
func TestEachPackFolderIsAPluginDirAtAStartAndAResume(t *testing.T) {
	root := plantPacks(t)
	was := brainwire.PacksRoot
	brainwire.PacksRoot = root
	t.Cleanup(func() { brainwire.PacksRoot = was })
	before := treeOf(t, root)
	s := startDriver(t)
	s.expect("hello")
	session := started(s, map[string]any{})
	work(s, "stp_work", []any{})
	argv, _ := modesOf(t, s, "stp_post")
	plugins := strs("--plugin-dir", filepath.Join(root, "pstack"), "--plugin-dir", filepath.Join(root, "taste-skill"))
	want := append(append(strs(baseArgv...), plugins...), strs("--session-id", session, "--permission-mode", "default")...)
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("the harness starts with each pack's folder:\n%v\nnot\n%v", want, argv)
	}
	s.end()

	s = startDriverIn(t, s.home)
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": map[string]any{}, "system": "be brief"})
	s.expect("started")
	work(s, "stp_work_2", []any{})
	argv, _ = modesOf(t, s, "stp_post_2")
	want = append(append(strs(baseArgv...), plugins...), strs("--resume", session, "--permission-mode", "default")...)
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("the harness resumes with each pack's folder:\n%v\nnot\n%v", want, argv)
	}
	s.end()
	if !reflect.DeepEqual(treeOf(t, root), before) {
		t.Fatal("nothing under the packs changes")
	}
	if _, err := os.Lstat(filepath.Join(s.home, ".claude", "skills")); !os.IsNotExist(err) {
		t.Fatalf("nothing is written in the program's own skills: %v", err)
	}
}

// With no packs folder the start is main's: no plugin folder is named.
func TestAStartWithNoPacksFolderNamesNoPluginDir(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	session := started(s, map[string]any{})
	work(s, "stp_work", []any{})
	argv, _ := modesOf(t, s, "stp_post")
	want := append(strs(baseArgv...), strs("--session-id", session, "--permission-mode", "default")...)
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("the harness starts as on main:\n%v\nnot\n%v", want, argv)
	}
	s.end()
}
