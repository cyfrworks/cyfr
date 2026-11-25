// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
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

func argvValue(argv []any, flag string) (string, bool) {
	for i, a := range argv {
		if a == flag && i+1 < len(argv) {
			return argv[i+1].(string), true
		}
	}
	return "", false
}

// A start's scrolls are written into the driver's own folder in its
// session's /tmp as a plugin named `cyfr`, which that start's process
// alone is handed with `--plugin-dir`; each is placed as Claude Code is
// seen to list it, `cyfr:<name>`. A skill of the person's own, named like
// a scroll, is untouched; nothing is written in the home, and the folder
// is gone at the driver's end.
func TestAStartsScrollsArePlacedAsAPluginForThatProcessAndGoAtTheEnd(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	s := startDriver(t)
	own := filepath.Join(s.home, ".claude", "skills", "research", "SKILL.md")
	plantFile(t, own, "---\nname: research\ndescription: the person's\n---\nTheirs.\n")
	s.expect("hello")
	answers := handScrolls(s, "research", "Caps_name")
	for i, as := range []string{"cyfr:research", "cyfr:Caps_name"} {
		if answers[i]["t"] != "placed" || answers[i]["as"] != as {
			t.Fatalf("a placed scroll is named as Claude Code lists it: %v", answers[i])
		}
	}
	session := started(s, map[string]any{})
	work(s, "stp_work", []any{})
	argv, _ := modesOf(t, s, "stp_post")
	dir, ok := argvValue(argv, "--plugin-dir")
	if !ok || filepath.Dir(dir) != tmp || !strings.HasPrefix(filepath.Base(dir), "cyfr-scrolls-") {
		t.Fatalf("the start names the driver's folder in its /tmp with --plugin-dir: %v", argv)
	}
	want := append(strs(baseArgv...), strs("--plugin-dir", dir, "--session-id", session, "--permission-mode", "default")...)
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("the harness starts with exactly\n%v\nnot\n%v", want, argv)
	}
	body, err := os.ReadFile(filepath.Join(dir, "skills", "research", "SKILL.md"))
	if err != nil || string(body) != "---\nname: \"research\"\ndescription: \"The research procedure\"\n---\n\nDo research.\n" {
		t.Fatalf("the scroll is its own name, description and body: %q %v", body, err)
	}
	if plugin, err := os.ReadFile(filepath.Join(dir, ".claude-plugin", "plugin.json")); err != nil || !strings.Contains(string(plugin), `"name":"cyfr"`) {
		t.Fatalf("the folder is a plugin named cyfr: %q %v", plugin, err)
	}
	if _, err := os.Lstat(filepath.Join(s.home, ".cyfr")); !os.IsNotExist(err) {
		t.Fatalf("nothing is written in the home: %v", err)
	}
	s.end()
	if _, err := os.Lstat(dir); !os.IsNotExist(err) {
		t.Fatalf("the folder goes at the driver's end: %v", err)
	}
	if got, _ := os.ReadFile(own); string(got) != "---\nname: research\ndescription: the person's\n---\nTheirs.\n" {
		t.Fatalf("the person's own skill is untouched: %q", got)
	}
}

// A person's own always wins a name: a skill or a command of theirs listed
// under the very name a scroll would be, `cyfr:<name>`, yields that scroll
// (own), and the others are placed.
func TestASkillOfThePersonsUnderAScrollsListedNameYieldsIt(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	s := startDriver(t)
	plantFile(t, filepath.Join(s.home, ".claude", "skills", "cyfr:research", "SKILL.md"), "---\ndescription: theirs\n---\nTheirs.\n")
	plantFile(t, filepath.Join(s.home, ".claude", "commands", "cyfr", "web.md"), "Theirs.\n")
	s.expect("hello")
	answers := handScrolls(s, "research", "web", "notes")
	got := []any{answers[0]["t"], answers[0]["why"], answers[1]["t"], answers[1]["why"], answers[2]["t"], answers[2]["as"]}
	if !reflect.DeepEqual(got, []any{"yielded", "own", "yielded", "own", "placed", "cyfr:notes"}) {
		t.Fatalf("the person's names yield their scrolls and the rest are placed: %v", answers)
	}
	started(s, map[string]any{})
	work(s, "stp_work", []any{})
	argv, _ := modesOf(t, s, "stp_post")
	dir, _ := argvValue(argv, "--plugin-dir")
	if entries, err := os.ReadDir(filepath.Join(dir, "skills")); err != nil || len(entries) != 1 || entries[0].Name() != "notes" {
		t.Fatalf("a yielded scroll is taken back from the folder: %v %v", entries, err)
	}
	s.end()
}

// Not knowing is not none: a listing that answers no list, or none in its
// bound, yields that scroll and the rest of the start's (unread); a name
// past what the wire carries yields quietly.
func TestAListingThatDoesNotSayYieldsEveryScrollAndALongNameYieldsQuietly(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	for name, env := range map[string]string{"no list": "unlisted", "no answer": "silent"} {
		t.Setenv("FAKE_SKILLS", env)
		was := skillsWait
		skillsWait = 2 * time.Second
		s := startDriver(t)
		s.expect("hello")
		for _, answer := range handScrolls(s, "research", "web") {
			if answer["t"] != "yielded" || answer["why"] != "unread" {
				t.Fatalf("%s: every scroll yields, unread: %v", name, answer)
			}
		}
		skillsWait = was
		s.end()
	}
	t.Setenv("FAKE_SKILLS", "")
	s := startDriver(t)
	s.expect("hello")
	long := strings.Repeat("n", 252)
	if answer := handScrolls(s, long)[0]; answer["t"] != "yielded" || answer["why"] != nil {
		t.Fatalf("a name past the wire's bound as listed yields quietly: %v", answer)
	}
	s.end()
}

// A plugin of the person's own named cyfr, recorded or in its folder,
// switched on or off, and a place the driver cannot read, each yield every
// scroll of the start: nothing is placed and no folder is named. What the
// driver reads there goes nowhere.
func TestAPluginOfThePersonsNamedCyfrOrAnUnreadablePlaceYieldsEveryScroll(t *testing.T) {
	secret := "PLUGIN-RECORD-CANARY"
	whys := map[string]string{"recorded": "own", "in its folder": "own", "a record that does not read": "unread", "a record that is a link": "unread",
		"a record of no plugins": "unread", "a configuration folder outside the home": "unread", "a configuration folder through a link": "unread"}
	for name, plant := range map[string]func(home string){
		"recorded": func(home string) {
			plantFile(t, filepath.Join(home, ".claude", "plugins", "installed_plugins.json"),
				`{"version":2,"plugins":{"other@market":[],"cyfr@market":[{"scope":"user","installPath":"`+secret+`"}]}}`)
		},
		"in its folder": func(home string) {
			plantFile(t, filepath.Join(home, ".claude", "plugins", "cache", "market", "Cyfr", "1.0.0", "README"), secret)
		},
		"a record that does not read": func(home string) {
			plantFile(t, filepath.Join(home, ".claude", "plugins", "installed_plugins.json"), "{"+secret)
		},
		"a record of no plugins": func(home string) {
			plantFile(t, filepath.Join(home, ".claude", "plugins", "installed_plugins.json"), `{"version":2,"plugins":null,"x":"`+secret+`"}`)
		},
		"a configuration folder outside the home": func(home string) {
			t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
		},
		"a configuration folder through a link": func(home string) {
			outside := t.TempDir()
			if err := os.Symlink(outside, filepath.Join(home, "linked")); err != nil {
				t.Fatal(err)
			}
			t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "linked"))
		},
		"a record that is a link": func(home string) {
			target := filepath.Join(t.TempDir(), "record.json")
			plantFile(t, target, `{"plugins":{}}`)
			if err := os.MkdirAll(filepath.Join(home, ".claude", "plugins"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, filepath.Join(home, ".claude", "plugins", "installed_plugins.json")); err != nil {
				t.Fatal(err)
			}
		},
	} {
		tmp := t.TempDir()
		t.Setenv("TMPDIR", tmp)
		s := startDriver(t)
		plant(s.home)
		s.expect("hello")
		for _, answer := range handScrolls(s, "research", "web") {
			if answer["t"] != "yielded" || answer["why"] != whys[name] {
				t.Fatalf("%s: every scroll yields, saying why: %v", name, answer)
			}
		}
		started(s, map[string]any{})
		work(s, "stp_work", []any{})
		argv, _ := modesOf(t, s, "stp_post")
		if _, ok := argvValue(argv, "--plugin-dir"); ok {
			t.Fatalf("%s: no folder is named: %v", name, argv)
		}
		if entries, _ := os.ReadDir(tmp); len(entries) != 0 {
			t.Fatalf("%s: nothing is written: %v", name, entries)
		}
		s.end()
		if strings.Contains(s.output(), secret) || strings.Contains(s.stderr.String(), secret) {
			t.Fatalf("%s: nothing the driver read leaves it", name)
		}
	}
	// A plugin of another name places the scrolls (a positive control).
	s := startDriver(t)
	plantFile(t, filepath.Join(s.home, ".claude", "plugins", "installed_plugins.json"), `{"plugins":{"cyfr-tools@market":[]}}`)
	plantFile(t, filepath.Join(s.home, ".claude", "plugins", "cache", "market", "cyfr-tools", "1.0.0", "README"), "x")
	s.expect("hello")
	if answer := handScrolls(s, "research")[0]; answer["t"] != "placed" {
		t.Fatalf("another plugin's name yields nothing: %v", answer)
	}
	s.end()
}

// A scroll the driver cannot write is refused in the driver's words, and
// a scroll while the harness runs ends the driver.
func TestAScrollTheDriverCannotWriteIsRefusedAndOneWhileTheHarnessRunsEndsIt(t *testing.T) {
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "absent"))
	s := startDriver(t)
	s.expect("hello")
	answer := handScrolls(s, "research")[0]
	if answer["t"] != "refused" || answer["reason"] != unplacedSentence {
		t.Fatalf("an unwritable folder refuses the scroll: %v", answer)
	}
	s.end()

	t.Setenv("TMPDIR", t.TempDir())
	s = startDriver(t)
	s.expect("hello")
	if answer := handScrolls(s, "-lead")[0]; answer["t"] != "refused" {
		t.Fatalf("a name of another grammar is refused: %v", answer)
	}
	started(s, map[string]any{})
	s.send(map[string]any{"t": "scroll", "id": "scr_late", "name": "late", "description": "", "body": ""})
	if s.why() != "broken" {
		t.Fatalf("a scroll while the harness runs ends the driver: %s", s.output())
	}
}
