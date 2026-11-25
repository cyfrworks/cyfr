// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// plantPacks makes a packs folder as the keeper binds one: two packs with
// skills, one without, and what is no pack (a file, a link, a dot name).
func plantPacks(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "packs")
	for _, dir := range []string{"pstack/skills/how", "taste-skill/skills/taste-skill", "agents-only/agents", ".hidden/skills/x"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []string{"pstack/skills/how/SKILL.md", "taste-skill/skills/taste-skill/SKILL.md", "README"} {
		if err := os.WriteFile(filepath.Join(root, file), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.MkdirAll(filepath.Join(outside, "skills", "o"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "linked")); err != nil {
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

// rootsOf is the extra roots the running app-server keeps and every
// method it was asked, in order.
func rootsOf(t *testing.T, s *wireSession, turn, id string) ([]any, []any) {
	t.Helper()
	work(s, "stp_work_"+id, turn)
	postText(s, id, turn, "roots")
	var got struct {
		Roots   []any `json:"roots"`
		Methods []any `json:"methods"`
	}
	if err := json.Unmarshal([]byte(saidOf(s.until("idle"))), &got); err != nil {
		t.Fatal(err)
	}
	return got.Roots, got.Methods
}

// Each pack in the space that has a `skills/` folder is an extra root,
// named after `initialize` and before the thread starts, and again before
// it resumes in a later process; a pack without one, a file, a link and a
// dot name are not. Nothing under the packs or the home changes.
func TestEachPacksSkillsFolderIsAnExtraRootBeforeTheThreadStartsOrResumes(t *testing.T) {
	t.Setenv("FAKE_NO_REPEAT", "1")
	root := plantPacks(t)
	was := brainwire.PacksRoot
	brainwire.PacksRoot = root
	t.Cleanup(func() { brainwire.PacksRoot = was })
	before := treeOf(t, root)
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	want := []any{filepath.Join(root, "pstack", "skills"), filepath.Join(root, "taste-skill", "skills")}
	roots, methods := rootsOf(t, s, "trn_1", "stp_post")
	if !reflect.DeepEqual(roots, want) || !reflect.DeepEqual(methods, []any{"initialize", "initialized", "account/read", "skills/extraRoots/set", "thread/start", "turn/start"}) {
		t.Fatalf("each pack's skills folder is named before the thread starts:\n%v\n%v", roots, methods)
	}
	s.end()

	s = startDriverIn(t, s.home)
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": map[string]any{}, "system": "be brief"})
	s.expect("started")
	roots, methods = rootsOf(t, s, "trn_2", "stp_post_2")
	if !reflect.DeepEqual(roots, want) || !reflect.DeepEqual(methods, []any{"initialize", "initialized", "account/read", "skills/extraRoots/set", "thread/resume", "turn/start"}) {
		t.Fatalf("each pack's skills folder is named before the thread resumes:\n%v\n%v", roots, methods)
	}
	s.end()
	if !reflect.DeepEqual(treeOf(t, root), before) {
		t.Fatal("nothing under the packs changes")
	}
	if _, err := os.Lstat(filepath.Join(s.home, ".codex", "config.toml")); !os.IsNotExist(err) {
		t.Fatalf("no configuration is written: %v", err)
	}
}

// With no packs folder the start is main's: no root is named.
func TestAStartWithNoPacksFolderNamesNoRoot(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	roots, methods := rootsOf(t, s, "trn_1", "stp_post")
	if roots != nil || !reflect.DeepEqual(methods, []any{"initialize", "initialized", "account/read", "thread/start", "turn/start"}) {
		t.Fatalf("a start with no packs asks nothing of skills: %v %v", roots, methods)
	}
	s.end()
}

// Codex refusing the roots ends the start, refused.
func TestCodexRefusingThePacksRootsEndsTheStart(t *testing.T) {
	root := plantPacks(t)
	was := brainwire.PacksRoot
	brainwire.PacksRoot = root
	t.Cleanup(func() { brainwire.PacksRoot = was })
	t.Setenv("FAKE_ROOTS_REFUSE", "1")
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 3, "config": map[string]any{}, "system": "be brief"})
	if why := s.why(); why != "refused" {
		t.Fatalf("a refused root ends the start, refused: %v", why)
	}
}
