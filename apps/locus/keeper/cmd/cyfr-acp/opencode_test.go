// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// OpenCode's profile against the stand-in speaking as `opencode acp` 2.4.1
// does (fake_test.go, FAKE_OPENCODE).

func startOpenCode(t *testing.T, home string) *wireSession {
	t.Helper()
	if home == "" {
		home = t.TempDir()
	}
	t.Setenv("HOME", home)
	t.Setenv(fakeEnv, "1")
	t.Setenv("FAKE_OPENCODE", "1")
	return startDriverWith(t, opencode, home)
}

// freshOpenCode reads the driver's hello and starts a new session with
// CYFR's files tool.
func freshOpenCode(s *wireSession, config map[string]any) string {
	s.t.Helper()
	if e := s.expect("hello"); e["driver"] != "cyfr-opencode" {
		s.t.Fatalf("hello names OpenCode's driver: %v", e)
	}
	s.send(startCommand("", config, filesTool))
	started := s.expect("started")
	if started["fresh"] != true || started["account"] != "signed_in" {
		s.t.Fatalf("a fresh start answers a new session, signed in: %v", started)
	}
	return started["session"].(string)
}

func openCodeStore(home string) string {
	held, _ := os.ReadFile(filepath.Join(home, ".local", "share", "opencode", "fake.db"))
	return string(held)
}

// A session id of OpenCode's own form is taken and named on the wire, and
// goes on in a second process whose resume answer does not name it; an id
// of another form is gone without the program being asked, and one the
// program lacks is gone on its load's not-found answer alone.
func TestOpenCodeSessionsAreOfItsOwnForm(t *testing.T) {
	s := startOpenCode(t, "")
	session := freshOpenCode(s, map[string]any{})
	if !strings.HasPrefix(session, "ses_") || brainwire.IsUUID(session) {
		t.Fatalf("the session is OpenCode's own id: %q", session)
	}
	postText(s, "stp_1", "trn_1", "hello")
	s.until("idle")
	s.end()

	r := startOpenCode(t, s.home)
	if e := resumed(r, session, filesTool); e["t"] != "started" || e["session"] != session || e["fresh"] != false {
		t.Fatalf("the session goes on in a second process: %v", e)
	}
	r.end()

	g := startOpenCode(t, s.home)
	if e := resumed(g, brainwire.NewUUID(), filesTool); e["t"] != "gone" {
		t.Fatalf("a UUID is no session of OpenCode's: %v", e)
	}
	g.end()
	l := startOpenCode(t, s.home)
	if e := resumed(l, "ses_"+strings.Repeat("a", 26), filesTool); e["t"] != "gone" {
		t.Fatalf("a session the program lacks is gone: %v", e)
	}
}

// A post mid-turn is OpenCode's steer request: taken, it is accepted and
// the turn's idle names it; while no turn runs it is later; refused, it is
// refused; and a turn answered before its steer ends once the steer is.
func TestOpenCodeSteerIsItsOwnRequest(t *testing.T) {
	steerOf := func(t *testing.T, env string) []map[string]any {
		if env != "" {
			t.Setenv(env, "1")
		}
		s := startOpenCode(t, "")
		freshOpenCode(s, map[string]any{})
		postText(s, "stp_first", "trn_1", "slow")
		if e := s.expect("text"); e["delta"] != "Starting. " {
			t.Fatalf("the turn's first part streams: %v", e)
		}
		s.send(map[string]any{"t": "post", "id": "stp_second", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "the steer"}}})
		return s.until("idle")
	}
	t.Run("taken", func(t *testing.T) {
		got := steerOf(t, "")
		if len(ofType(got, "accepted")) != 1 || saidOf(got) != "Starting. Read the steer: the steer" ||
			fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first stp_second]" {
			t.Fatalf("the steer is accepted into the turn its idle names: %v", got)
		}
	})
	t.Run("answered after the turn", func(t *testing.T) {
		got := steerOf(t, "FAKE_CONFIRM_LATE")
		accepted := -1
		for i, e := range got {
			if e["t"] == "accepted" && e["id"] == "stp_second" {
				accepted = i
			}
		}
		if accepted < 0 || accepted > len(got)-2 || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first stp_second]" {
			t.Fatalf("the turn ends once its steer is answered, naming it: %v", got)
		}
	})
	t.Run("no turn", func(t *testing.T) {
		got := steerOf(t, "FAKE_STEER_NO_TURN")
		if later := ofType(got, "later"); len(later) != 1 || later[0]["id"] != "stp_second" ||
			fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first]" {
			t.Fatalf("a steer the program takes no turn for is later: %v", got)
		}
	})
	t.Run("refused", func(t *testing.T) {
		got := steerOf(t, "FAKE_STEER_FAIL")
		if refused := ofType(got, "refused"); len(refused) != 1 || refused[0]["id"] != "stp_second" ||
			fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first]" || strings.Contains(fmt.Sprint(refused), "HARNESS-WORDS") {
			t.Fatalf("a refused steer is refused in the driver's words: %v", got)
		}
	})
}

// A forget is OpenCode's own delete, proved by its load's not-found answer:
// the session leaves the program's store and another stays; a delete the
// program refuses, or one after which it still has the session, is a forget
// that failed.
func TestOpenCodeForgetIsItsDeleteProvedByItsLoad(t *testing.T) {
	s := startOpenCode(t, "")
	first := freshOpenCode(s, map[string]any{})
	postText(s, "stp_1", "trn_1", "hello")
	s.until("idle")
	s.end()
	o := startOpenCode(t, s.home)
	second := freshOpenCode(o, map[string]any{})
	o.send(map[string]any{"t": "forget", "id": "obx_uuid", "session": brainwire.NewUUID()})
	if e := o.expect("refused"); e["id"] != "obx_uuid" {
		t.Fatalf("a UUID names no session of OpenCode's: %v", e)
	}
	o.end()

	for _, env := range []string{"FAKE_DELETE_FAIL", "FAKE_DELETE_KEEPS"} {
		t.Setenv(env, "1")
		f := startOpenCode(t, s.home)
		f.expect("hello")
		f.send(map[string]any{"t": "forget", "id": "obx_fail", "session": first})
		if e := f.expect("refused"); e["id"] != "obx_fail" || strings.Contains(fmt.Sprint(e), "HARNESS-WORDS") || !strings.Contains(openCodeStore(s.home), first) {
			t.Fatalf("%s: a forget the program did not prove is refused in the driver's words: %v", env, e)
		}
		f.end()
		os.Unsetenv(env)
	}

	f := startOpenCode(t, s.home)
	f.expect("hello")
	f.send(map[string]any{"t": "forget", "id": "obx_1", "session": first})
	if e := f.expect("forgot"); e["id"] != "obx_1" || e["session"] != first {
		t.Fatalf("the forget is answered: %v", e)
	}
	if store := openCodeStore(s.home); strings.Contains(store, first) || !strings.Contains(store, second) {
		t.Fatalf("the forgotten session left the program's store and another stayed: %q", store)
	}
	if _, err := os.Lstat(instructionsFile(s.home, first)); !brainwire.Absent(err) {
		t.Fatalf("the driver's own record of the session went with it: %v", err)
	}
}

// A prompt's usage sums its output with its thoughts, names no cache
// writes as 0, and is partial.
func TestOpenCodeUsageSumsItsThoughtsAndIsPartial(t *testing.T) {
	s := startOpenCode(t, "")
	freshOpenCode(s, map[string]any{})
	postText(s, "stp_1", "trn_1", "hello")
	usages := ofType(s.until("idle"), "usage")
	want := []any{map[string]any{"model": "opencode/big-pickle",
		"counts": map[string]any{"input_tokens": float64(100), "output_tokens": float64(25), "cache_read_tokens": float64(30), "cache_write_tokens": float64(0)}}}
	if len(usages) != 1 || usages[0]["accounting"] != "partial" || !reflect.DeepEqual(usages[0]["models"], want) {
		t.Fatalf("the prompt's counts, output with thoughts, partial: %v", usages)
	}
}

// Each model is listed with the efforts OpenCode offers once it is
// selected, read in a listing session of the driver's own, also while a
// session runs, whose model the listing leaves; the listing session is
// deleted from the program's store.
func TestOpenCodeEffortsAreReadBySelectingEachModel(t *testing.T) {
	s := startOpenCode(t, "")
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "mdl_1"})
	listing := s.expect("models")
	want := []any{map[string]any{"id": "opencode/big-pickle", "name": "Opencode/big-pickle", "efforts": []any{}},
		map[string]any{"id": "probe/think", "name": "Probe/think", "efforts": []any{"low", "high"}}}
	if !reflect.DeepEqual(listing["models"], want) || listing["account"] != "signed_in" {
		t.Fatalf("each model with the efforts its selection offers: %v", listing)
	}
	if store := strings.TrimSpace(openCodeStore(s.home)); store != "" {
		t.Fatalf("the listing session is deleted: %q", store)
	}
	s.send(startCommand("", map[string]any{"model": "probe/think", "effort": "high"}, filesTool))
	s.expect("started")
	s.send(map[string]any{"t": "models", "id": "mdl_2"})
	if again := s.expect("models"); !reflect.DeepEqual(again["models"], want) {
		t.Fatalf("a running session lists the same: %v", again)
	}
	given := sessionGiven(s, "stp_params")
	if fmt.Sprint(given["set"]) != "[map[configId:model value:probe/think] map[configId:effort value:high]]" {
		t.Fatalf("the running session's model and effort are the start's alone: %v", given["set"])
	}
}

// A call of CYFR's from inside OpenCode's own `execute` is an ask whose
// answer is the call's result, and `execute` itself is shown as the
// program's own tool, by its name.
func TestOpenCodeCallsInsideItsExecuteAreAsks(t *testing.T) {
	s := startOpenCode(t, "")
	freshOpenCode(s, map[string]any{})
	postText(s, "stp_1", "trn_1", "execute")
	var ask map[string]any
	before := s.until("ask")
	ask = before[len(before)-1]
	if own := ofType(before, "own"); len(own) != 1 || own[0]["name"] != "execute" || own[0]["phase"] != "start" {
		t.Fatalf("execute is shown running before CYFR's call in it: %v", before)
	}
	if ask["name"] != "files" {
		t.Fatalf("CYFR's call is an ask: %v", ask)
	}
	s.send(map[string]any{"t": "answer", "id": "ans_1", "ask": ask["ask"], "content": "the notes", "is_error": false})
	got := s.until("idle")
	if saidOf(got) != `the tool answered "the notes", error false` {
		t.Fatalf("the answer is the call's result: %v", got)
	}
	if own := ofType(got, "own"); len(own) != 1 || own[0]["name"] != "execute" || own[0]["phase"] != "end" {
		t.Fatalf("execute ends as the program's own: %v", got)
	}
}

// OpenCode's notices that it retries its provider are not work: nothing of
// them reaches the wire, so CYFR's silence clock runs through them.
func TestOpenCodeRetryNoticesAreNotWork(t *testing.T) {
	s := startOpenCode(t, "")
	freshOpenCode(s, map[string]any{})
	postText(s, "stp_1", "trn_1", "retry")
	got := s.until("idle")
	for _, e := range got {
		switch e["t"] {
		case "text", "said", "usage", "idle":
		default:
			t.Fatalf("a retry notice wrote an event: %v", e)
		}
	}
	if strings.Contains(s.output(), "RETRY-CANARY") || saidOf(got) != "reached it" {
		t.Fatalf("nothing of a retry notice reaches the wire: %v", got)
	}
}
