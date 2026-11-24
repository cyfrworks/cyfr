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
)

// The scrolls handed before a start, `scroll` by `scroll`.
func handScrolls(s *wireSession, names ...string) []map[string]any {
	s.t.Helper()
	var answers []map[string]any
	for i, name := range names {
		s.send(map[string]any{"t": "scroll", "id": "scr_" + name, "name": name,
			"description": "The " + name + " procedure", "body": "Do " + name + ".\n"})
		answer := s.next()
		if answer["id"] != "scr_"+name {
			s.t.Fatalf("scroll %d is answered by its id: %v", i, answer)
		}
		answers = append(answers, answer)
	}
	return answers
}

func plantFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

// tree is every file under root with its content.
func tree(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			b, _ := os.ReadFile(p)
			rel, _ := filepath.Rel(root, p)
			out[rel] = string(b)
		}
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

// A start's scrolls are written into the driver's own folder, named to
// Codex for that process alone before the thread starts; a scroll named
// like a skill Codex has, the person's or one built in, is yielded. The
// person's skills are untouched, nothing is written where Codex keeps its
// own, and the folder goes at the driver's end.
func TestAStartsScrollsAreAnExtraRootAndOnesNamedLikeCodexsOwnYield(t *testing.T) {
	s := startDriver(t)
	codexSkills := filepath.Join(s.home, ".codex", "skills")
	agentsSkills := filepath.Join(s.home, ".agents", "skills")
	plantFile(t, filepath.Join(codexSkills, "own-skill", "SKILL.md"), "the person's own")
	plantFile(t, filepath.Join(agentsSkills, "research", "SKILL.md"), "the person's research")
	before := map[string]map[string]string{"codex": tree(t, codexSkills), "agents": tree(t, agentsSkills)}
	s.expect("hello")
	answers := handScrolls(s, "research", "imagegen", "web")
	got := []any{answers[0]["t"], answers[0]["why"], answers[1]["t"], answers[1]["why"], answers[2]["t"], answers[2]["as"]}
	if !reflect.DeepEqual(got, []any{"yielded", "own", "yielded", "own", "placed", "web"}) {
		t.Fatalf("a scroll named like one of Codex's skills yields and another is placed by its name: %v", answers)
	}
	started(s, map[string]any{})
	roots, methods := rootsOf(t, s, "trn_1", "stp_post")
	place := filepath.Join(s.home, ".cyfr", "scrolls")
	if len(roots) != 1 || filepath.Dir(filepath.Dir(roots[0].(string))) != place || filepath.Base(roots[0].(string)) != "skills" {
		t.Fatalf("the start names the driver's folder as its one extra root: %v", roots)
	}
	want := []any{"initialize", "initialized", "skills/list", "account/read", "skills/extraRoots/set", "thread/start", "turn/start"}
	if !reflect.DeepEqual(methods, want) {
		t.Fatalf("one process lists, is given the root, then starts the thread:\n%v\nnot\n%v", want, methods)
	}
	placed := tree(t, roots[0].(string))
	if !reflect.DeepEqual(placed, map[string]string{"web/SKILL.md": "---\nname: \"web\"\ndescription: \"The web procedure\"\n---\n\nDo web.\n"}) {
		t.Fatalf("the folder holds the placed scroll alone: %v", placed)
	}
	after := map[string]map[string]string{"codex": tree(t, codexSkills), "agents": tree(t, agentsSkills)}
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("Codex's own skills places are untouched: %v %v", before, after)
	}
	s.end()
	if entries, err := os.ReadDir(place); err != nil || len(entries) != 0 {
		t.Fatalf("the folder and its lock go at the driver's end: %v %v", entries, err)
	}
}

// A resume is given the start's folder before the thread resumes; a start
// handed no scroll lists nothing and names no root.
func TestAResumeIsGivenTheRootAndAStartWithNoScrollNamesNone(t *testing.T) {
	t.Setenv("FAKE_NO_REPEAT", "1")
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	_, methods := rootsOf(t, s, "trn_1", "stp_post")
	if !reflect.DeepEqual(methods, []any{"initialize", "initialized", "account/read", "thread/start", "turn/start"}) {
		t.Fatalf("a start with no scroll asks nothing of skills: %v", methods)
	}
	s.end()

	s = startDriverIn(t, s.home)
	s.expect("hello")
	handScrolls(s, "web")
	s.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": map[string]any{}, "system": "be brief"})
	s.expect("started")
	roots, methods := rootsOf(t, s, "trn_2", "stp_post_2")
	want := []any{"initialize", "initialized", "skills/list", "account/read", "skills/extraRoots/set", "thread/resume", "turn/start"}
	if len(roots) != 1 || !reflect.DeepEqual(methods, want) {
		t.Fatalf("a resume is given the root before it resumes: %v %v", roots, methods)
	}
	s.end()
}

// A listing that does not answer yields every scroll and names no root.
func TestAListingThatDoesNotAnswerYieldsEveryScroll(t *testing.T) {
	t.Setenv("FAKE_SKILLS_FAIL", "1")
	s := startDriver(t)
	s.expect("hello")
	for _, answer := range handScrolls(s, "research", "web") {
		if answer["t"] != "yielded" || answer["why"] != "unread" {
			t.Fatalf("every scroll yields, its listing unread: %v", answer)
		}
	}
	started(s, map[string]any{})
	roots, methods := rootsOf(t, s, "trn_1", "stp_post")
	if roots != nil || !reflect.DeepEqual(methods, []any{"initialize", "initialized", "skills/list", "account/read", "thread/start", "turn/start"}) {
		t.Fatalf("no root is named: %v %v", roots, methods)
	}
	if _, err := os.Lstat(filepath.Join(s.home, ".cyfr")); !os.IsNotExist(err) {
		t.Fatalf("nothing is written: %v", err)
	}
	s.end()
}

// A scroll the driver cannot write is refused in the driver's words.
func TestAScrollTheDriverCannotWriteIsRefused(t *testing.T) {
	s := startDriver(t)
	plantFile(t, filepath.Join(s.home, ".cyfr"), "a file where the folder would be")
	s.expect("hello")
	if answer := handScrolls(s, "web")[0]; answer["t"] != "refused" || answer["reason"] != unplacedSentence {
		t.Fatalf("an unwritable folder refuses the scroll: %v", answer)
	}
	s.end()
}
