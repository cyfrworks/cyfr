// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"testing"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// Cursor's profile against the stand-in speaking as `agent acp`
// 2026.11.22-e9042b2 does (cursor_fake_test.go, FAKE_CURSOR).

func startCursor(t *testing.T, home string) *wireSession {
	t.Helper()
	if home == "" {
		home = t.TempDir()
	}
	t.Setenv("HOME", home)
	t.Setenv("CURSOR_CONFIG_DIR", "")
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv(fakeEnv, "1")
	t.Setenv("FAKE_CURSOR", "1")
	return startDriverWith(t, cursor, home)
}

func freshCursor(s *wireSession) string {
	s.t.Helper()
	if e := s.expect("hello"); e["driver"] != "cyfr-cursor" {
		s.t.Fatalf("hello names Cursor's driver: %v", e)
	}
	s.send(startCommand("", map[string]any{}, filesTool))
	started := s.expect("started")
	if started["fresh"] != true || started["account"] != "signed_in" || !brainwire.IsUUID(started["session"].(string)) {
		s.t.Fatalf("a fresh start answers a new session, signed in: %v", started)
	}
	return started["session"].(string)
}

func cursorLog(home string) []string {
	held, _ := os.ReadFile(filepath.Join(home, "fake-acp.log"))
	return strings.Fields(strings.ReplaceAll(string(held), "\n", " | "))
}

func countOf(home, word string) int {
	held, _ := os.ReadFile(filepath.Join(home, "fake-acp.log"))
	n := 0
	for _, line := range strings.Split(string(held), "\n") {
		if line == word || strings.HasPrefix(line, word+" ") {
			n++
		}
	}
	return n
}

func sessionFolder(home, session string) string {
	return filepath.Join(home, ".cursor", "acp-sessions", session)
}

// Cursor names no version and offers no resume: a start goes on with a
// session by its load in a second process, its replay never passed on, and
// a session the folder lacks, or no UUID, is gone.
func TestCursorGoesOnWithASessionByItsLoad(t *testing.T) {
	s := startCursor(t, "")
	session := freshCursor(s)
	postText(s, "stp_1", "trn_1", "hello")
	s.until("idle")
	s.end()

	r := startCursor(t, s.home)
	if e := resumed(r, session, filesTool); e["t"] != "started" || e["session"] != session || e["fresh"] != false {
		t.Fatalf("the session goes on in a second process: %v", e)
	}
	postText(r, "stp_2", "trn_2", "hello")
	if got := r.until("idle"); strings.Contains(fmt.Sprint(got), "REPLAYED") {
		t.Fatalf("a load's replay is never passed on: %v", got)
	}
	r.end()
	if countOf(s.home, "load") != 1 {
		t.Fatalf("the second process loaded the session: %v", cursorLog(s.home))
	}
	for _, missing := range []string{brainwire.NewUUID(), "ses_" + strings.Repeat("a", 26)} {
		g := startCursor(t, s.home)
		if e := resumed(g, missing, filesTool); e["t"] != "gone" {
			t.Fatalf("%s is gone: %v", missing, e)
		}
		g.end()
	}
}

// The tools' listing is checked at the first turn: the start answers
// without it, and a turn that ends with none listed ends with an error.
func TestCursorsToolsAreCheckedAtTheFirstTurn(t *testing.T) {
	t.Run("listed", func(t *testing.T) {
		s := startCursor(t, "")
		freshCursor(s)
		postText(s, "stp_1", "trn_1", "hello")
		if got := s.until("idle"); len(ofType(got, "error")) != 0 || got[len(got)-1]["stop"] != "end_turn" {
			t.Fatalf("a turn whose tools were listed ends as it ended: %v", got)
		}
	})
	t.Run("not listed", func(t *testing.T) {
		t.Setenv("FAKE_NO_LIST", "1")
		s := startCursor(t, "")
		freshCursor(s)
		postText(s, "stp_1", "trn_1", "hello")
		got := s.until("idle")
		errs := ofType(got, "error")
		if len(errs) != 1 || errs[0]["message"] != "CYFR's tools did not reach Cursor: its server for them listed none in the turn." ||
			got[len(got)-1]["stop"] != "error" {
			t.Fatalf("a turn with no listing ends with the error: %v", got)
		}
	})
}

// The name of CYFR's server is read once, when a session is made, beside
// the person's own, and kept: a start that goes on with the session takes
// it with no listing, even once the person has a server of that name; a
// lost record is listed for again.
func TestCursorNamesItsServerOnceWhenASessionIsMade(t *testing.T) {
	t.Setenv("FAKE_SERVERS", "cyfr,a: b,notes")
	s := startCursor(t, "")
	session := freshCursor(s)
	s.end()
	if countOf(s.home, "list") != 1 || countOf(s.home, "servers cyfr-2") != 1 {
		t.Fatalf("one listing, and CYFR's server takes a name none of the person's has: %v", cursorLog(s.home))
	}
	t.Setenv("FAKE_SERVERS", "cyfr,cyfr-2,notes")
	r := startCursor(t, s.home)
	if e := resumed(r, session, filesTool); e["t"] != "started" {
		t.Fatalf("the session goes on: %v", e)
	}
	r.end()
	if countOf(s.home, "list") != 1 || countOf(s.home, "servers cyfr-2") != 2 {
		t.Fatalf("a start that goes on takes the kept name with no listing: %v", cursorLog(s.home))
	}
	if err := os.Remove(filepath.Join(s.home, ".cache", "cyfr-acp", "servers", session)); err != nil {
		t.Fatal(err)
	}
	l := startCursor(t, s.home)
	if e := resumed(l, session, filesTool); e["t"] != "started" {
		t.Fatalf("the session goes on: %v", e)
	}
	l.end()
	if countOf(s.home, "list") != 2 || countOf(s.home, "servers cyfr-3") != 1 {
		t.Fatalf("a lost record is listed for again: %v", cursorLog(s.home))
	}
}

// Every text before each ": " of a line of `agent mcp list`, and the whole
// line, is a name taken: a name holding ": " is never read as free.
func TestCursorsListingErrsTowardTakenNames(t *testing.T) {
	names, ok := cursorServers([]byte("a: b: ready\ncyfr: Error: Connection failed\nweb: not loaded (needs approval)\r\n"))
	sort.Strings(names)
	want := []string{"a", "a: b", "a: b: ready", "cyfr", "cyfr: Error", "cyfr: Error: Connection failed", "web", "web: not loaded (needs approval)"}
	if !ok || !reflect.DeepEqual(names, want) {
		t.Fatalf("names: %q %v", names, ok)
	}
	if serverFor(names) != "cyfr-2" {
		t.Fatalf("CYFR's server takes the first free name: %s", serverFor(names))
	}
	if names, ok := cursorServers([]byte(cursorNone + "\n")); !ok || len(names) != 0 {
		t.Fatalf("no server configured: %v %v", names, ok)
	}
	if _, ok := cursorServers([]byte("\n")); ok {
		t.Fatal("nothing printed is no listing")
	}
}

// A turn whose whole output is one chunk of Cursor's failure form is an
// error of its type, in CYFR's words; a turn that said or did anything
// before or after it ends as it ended, Cursor's words its answer.
func TestCursorsFailedTurnIsAnErrorOnlyWhenItIsAllTheTurnSaid(t *testing.T) {
	turn := func(t *testing.T, words string) []map[string]any {
		s := startCursor(t, "")
		freshCursor(s)
		postText(s, "stp_1", "trn_1", words)
		return s.until("idle")
	}
	for words, want := range map[string][2]string{
		"fail":      {"provider_error", "Cursor could not reach its service; ask again once the network is back."},
		"unauth":    {"authentication", "Cursor's sign-in was refused; sign it in again on the program's terminal, opened with the word `login`."},
		"signin":    {"authentication", "Cursor's sign-in was refused; sign it in again on the program's terminal, opened with the word `login`."},
		"exhausted": {"rate_limited", "Cursor reported a usage or rate limit; ask again later."},
	} {
		t.Run(words, func(t *testing.T) {
			got := turn(t, words)
			errs := ofType(got, "error")
			if len(errs) != 1 || errs[0]["type"] != want[0] || errs[0]["message"] != want[1] || got[len(got)-1]["stop"] != "error" ||
				len(ofType(got, "text")) != 0 || len(ofType(got, "said")) != 0 {
				t.Fatalf("an error of its type in CYFR's words, and no text: %v", got)
			}
		})
	}
	for words, said := range map[string]string{
		"saidfirst":    "Looking. \n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh",
		"thoughtfirst": "\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh",
		"callfirst":    "\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh",
		"failthen":     "\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh and more",
		"lookalike":    "\n\nError: a plain sentence of the model's",
		"imagefirst":   "\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh",
		"emptyfirst":   "\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh",
	} {
		t.Run(words, func(t *testing.T) {
			got := turn(t, words)
			if len(ofType(got, "error")) != 0 || got[len(got)-1]["stop"] != "end_turn" || saidOf(got) != said {
				t.Fatalf("the turn ends as it ended, its words its answer: %v", got)
			}
		})
	}
}

// The form read as a failure is exactly Cursor's: its blank lines, `Error: `,
// a type or a bracketed code, a message; or its sentences. A model's
// answer of exactly that form is read as one, the stated lack.
func TestCursorsFailureFormIsExact(t *testing.T) {
	for text, kind := range map[string]string{
		"\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh": "provider_error",
		"\n\nError: [unauthenticated] Backend rejected authentication.":                               "authentication",
		"\n\nError: ConnectError: [internal] x":                                                       "provider_error",
		"\n\nError: ConnectError: [resource_exhausted] x":                                             "rate_limited",
		"\n\nError: Error: x":                    "provider_error",
		"\n\nUpgrade your plan to continue":      "rate_limited",
		"\n\nAdd a payment method to continue":   "provider_error",
		"\n\nPlease sign in to continue":         "authentication",
		"Error: RetriableError: [unavailable] x": "",
		"\n\nError: [unavailable] x\nmore":       "",
		"\n\nError: a sentence":                  "",
		"\n\nError: ":                            "",
		"\n\nPlease sign in to continue.":        "",
	} {
		if got, _ := cursorFailure(text); got != kind {
			t.Fatalf("%q reads %q, not %q", text, got, kind)
		}
	}
}

// A call of CYFR's tools, announced first with no input as Cursor does, is
// an ask and not the program's own; a call of a person's server is theirs.
func TestCursorsCallIsAnAskAndAPersonsIsTheirOwn(t *testing.T) {
	s := startCursor(t, "")
	freshCursor(s)
	postText(s, "stp_1", "trn_1", "call")
	ask := s.expect("ask")
	if ask["name"] != "files" || fmt.Sprint(ask["arguments"]) != "map[path:notes.txt]" {
		t.Fatalf("the call is an ask with its arguments whole: %v", ask)
	}
	s.send(map[string]any{"t": "answer", "id": "ans_1", "ask": ask["ask"], "content": "notes", "is_error": false})
	got := s.until("idle")
	if len(ofType(got, "own")) != 0 || saidOf(got) != "the tool answered notes" {
		t.Fatalf("CYFR's call is no call of the program's own, and its answer reached it: %v", got)
	}
	postText(s, "stp_2", "trn_2", "theirs")
	got = s.until("idle")
	own := ofType(got, "own")
	if len(own) != 2 || own[0]["name"] != "mcp:notes/echo" || own[0]["phase"] != "start" || own[1]["phase"] != "end" {
		t.Fatalf("a person's server's call is theirs, named by its server and tool: %v", got)
	}
}

// A post mid-turn is answered later: Cursor's second prompt would cancel
// the running one. Usage is unavailable.
func TestCursorTakesNoMessageMidTurnAndReportsNoUsage(t *testing.T) {
	s := startCursor(t, "")
	freshCursor(s)
	postText(s, "stp_1", "trn_1", "slow")
	s.expect("text")
	s.send(map[string]any{"t": "post", "id": "stp_2", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "more"}}})
	got := s.until("idle")
	usage := ofType(got, "usage")
	if later := ofType(got, "later"); len(later) != 1 || later[0]["id"] != "stp_2" || saidOf(got) != "Starting. no second prompt came" ||
		len(usage) != 1 || usage[0]["accounting"] != "unavailable" {
		t.Fatalf("the post mid-turn is later and the turn goes on, its usage unavailable: %v", got)
	}
}

// A forget removes the session's folder and its records, leaves another
// session's, and is confirmed by the program's load answering it lacks the
// session; a load that still finds it is a forget that failed.
func TestCursorForgetRemovesTheSessionsFolderAndItsLoadConfirms(t *testing.T) {
	s := startCursor(t, "")
	first := freshCursor(s)
	postText(s, "stp_1", "trn_1", "hello")
	s.until("idle")
	s.end()
	o := startCursor(t, s.home)
	o.expect("hello")
	o.send(startCommand("", map[string]any{}, filesTool))
	other := o.expect("started")["session"].(string)
	o.end()

	f := startCursor(t, s.home)
	f.expect("hello")
	f.send(map[string]any{"t": "forget", "id": "fgt_1", "session": first})
	if e := f.next(); e["t"] != "forgot" || e["session"] != first {
		t.Fatalf("the session is forgotten: %v", e)
	}
	f.end()
	for _, gone := range []string{sessionFolder(s.home, first), filepath.Join(s.home, ".cache", "cyfr-acp", "servers", first)} {
		if _, err := os.Lstat(gone); !os.IsNotExist(err) {
			t.Fatalf("%s is gone: %v", gone, err)
		}
	}
	if _, err := os.Stat(filepath.Join(sessionFolder(s.home, other), "store.db")); err != nil {
		t.Fatalf("another session stays: %v", err)
	}
	if countOf(s.home, "load "+first) != 1 {
		t.Fatalf("its load confirmed the forget: %v", cursorLog(s.home))
	}

	for env, label := range map[string]string{"FAKE_LOAD_STILL": "a load that still finds the session", "FAKE_LOAD_ERROR": "a load that fails another way"} {
		t.Run(label, func(t *testing.T) {
			t.Setenv(env, "1")
			k := startCursor(t, s.home)
			k.expect("hello")
			k.send(map[string]any{"t": "forget", "id": "fgt_2", "session": other})
			if e := k.next(); e["t"] != "refused" || !strings.Contains(fmt.Sprint(e["reason"]), "did not show the session gone") ||
				strings.Contains(fmt.Sprint(e), "HARNESS-WORDS") {
				t.Fatalf("%s fails the forget, in the driver's words: %v", label, e)
			}
		})
	}
}

// Signed out, Cursor's load says nothing of the session: a forget stands on
// its folder removed and read absent, and the load's signed-out answer
// undoes nothing already proved.
func TestCursorForgetWhileSignedOutStandsOnTheFoldersAbsence(t *testing.T) {
	s := startCursor(t, "")
	session := freshCursor(s)
	s.end()
	t.Setenv("FAKE_SIGNED_OUT", "1")
	f := startCursor(t, s.home)
	f.expect("hello")
	f.send(map[string]any{"t": "forget", "id": "fgt_1", "session": session})
	if e := f.next(); e["t"] != "forgot" || e["session"] != session {
		t.Fatalf("the session is forgotten: %v", e)
	}
	if _, err := os.Lstat(sessionFolder(s.home, session)); !os.IsNotExist(err) || countOf(s.home, "load "+session) != 1 {
		t.Fatalf("its folder is gone and its load was asked: %v %v", err, cursorLog(s.home))
	}
}

// Signed out is -32000 alone, the start answering signed out.
func TestCursorSignedOutIsItsOneShape(t *testing.T) {
	t.Setenv("FAKE_SIGNED_OUT", "1")
	s := startCursor(t, "")
	s.expect("hello")
	s.send(startCommand("", map[string]any{}, filesTool))
	if e := s.expect("started"); e["account"] != "signed_out" {
		t.Fatalf("signed out: %v", e)
	}
	s.send(map[string]any{"t": "post", "id": "stp_1", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "hi"}}})
	if e := s.next(); e["t"] != "refused" || !strings.Contains(fmt.Sprint(e["reason"]), "opened with the word `login`") {
		t.Fatalf("a post is refused as signed out: %v", e)
	}
}

// Cursor, initialized with its parameterized picker, lists its base
// models, each with its own efforts as cursor/list_available_models gives
// them, a thinking switch beside an effort being none, with a session
// running or none; the listing's session is removed.
func TestCursorListsEachModelWithItsOwnEfforts(t *testing.T) {
	want := "[map[efforts:[] id:default name:Auto] map[efforts:[low medium high xhigh max] id:claude-opus-5-5 name:Claude Opus 5.5] " +
		"map[efforts:[low medium high] id:claude-opus-5 name:Claude Opus 5]]"
	s := startCursor(t, "")
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "mdl_1"})
	if e := s.expect("models"); fmt.Sprint(e["models"]) != want {
		t.Fatalf("each base model with its own efforts: %v", e["models"])
	}
	entries, _ := os.ReadDir(filepath.Join(s.home, ".cursor", "acp-sessions"))
	if len(entries) != 0 {
		t.Fatalf("the listing's session is removed: %v", entries)
	}

	s = startCursor(t, "")
	freshCursor(s)
	s.send(map[string]any{"t": "models", "id": "mdl_2"})
	if e := s.expect("models"); fmt.Sprint(e["models"]) != want {
		t.Fatalf("listed alike while a session runs: %v", e["models"])
	}
}

// A start sets the model, then its effort, each as that model offers it;
// an effort the model does not offer ends the driver unfit before
// anything runs.
func TestCursorsStartSetsTheModelThenItsEffort(t *testing.T) {
	s := startCursor(t, "")
	s.expect("hello")
	s.send(startCommand("", map[string]any{"model": "claude-opus-5", "effort": "high"}, filesTool))
	if started := s.expect("started"); started["fresh"] != true {
		t.Fatalf("it starts: %v", started)
	}
	var sets []string
	for _, line := range strings.Split(strings.TrimSpace(readLog(s.home)), "\n") {
		if strings.HasPrefix(line, "set ") {
			sets = append(sets, line)
		}
	}
	if !reflect.DeepEqual(sets, []string{"set model claude-opus-5", "set effort high"}) {
		t.Fatalf("the model, then its effort, and no thinking switch: %v", sets)
	}

	s = startCursor(t, "")
	s.expect("hello")
	s.send(startCommand("", map[string]any{"model": "claude-opus-5", "effort": "max"}, filesTool))
	if why := s.why(); why != "unfit" {
		t.Fatalf("an effort the model lacks is unfit: %v", why)
	}
	if status := s.exit(); status != 2 || strings.Contains(s.output(), `"started"`) {
		t.Fatalf("it ends the driver with 2 before anything starts: %d %q", status, s.stderr.String())
	}
}

func readLog(home string) string {
	held, _ := os.ReadFile(filepath.Join(home, "fake-acp.log"))
	return string(held)
}

// A load is what Cursor offers to go on with a session: without it the
// start is refused.
func TestCursorWithoutALoadIsRefused(t *testing.T) {
	t.Setenv("FAKE_NO_LOAD", "1")
	s := startCursor(t, "")
	s.expect("hello")
	s.send(startCommand("", map[string]any{}, filesTool))
	if status := s.exit(); status != 1 || !strings.Contains(s.stderr.String(), "does not offer to load a session") {
		t.Fatalf("refused: %d %s", status, s.stderr.String())
	}
	if s.why() != "unsupported" {
		t.Fatalf("the holder is told unsupported alone: %s", s.output())
	}
}

// Cursor does not end when its input does: Stop's terminate ends it.
func TestCursorEndsAtItsTerminate(t *testing.T) {
	t.Setenv("FAKE_HOLD", "1")
	s := startCursor(t, "")
	freshCursor(s)
	s.end()
	if countOf(s.home, "term") != 1 {
		t.Fatalf("the terminate ended it: %v", cursorLog(s.home))
	}
}

// A call of CYFR's is something the turn did: a failure chunk after it is
// the turn's answer, not Cursor's failure.
func TestCursorsTurnThatCalledCYFRIsNoFailure(t *testing.T) {
	s := startCursor(t, "")
	freshCursor(s)
	postText(s, "stp_1", "trn_1", "askfirst")
	ask := s.expect("ask")
	s.send(map[string]any{"t": "answer", "id": "ans_1", "ask": ask["ask"], "content": "x", "is_error": false})
	got := s.until("idle")
	if len(ofType(got, "error")) != 0 || got[len(got)-1]["stop"] != "end_turn" ||
		saidOf(got) != "\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh" {
		t.Fatalf("the turn ends as it ended, its words its answer: %v", got)
	}
}

// A sessions folder CYFR will not walk, one CURSOR_CONFIG_DIR or
// XDG_CONFIG_HOME names outside the program's folder or through a link, is
// judged before Cursor is asked for anything: the start, a listing and a
// forget are each refused with the one sentence, no session is made, and a
// session already there stays. One inside the program's folder is where
// the forget removes the session.
func TestCursorsFolderCYFRWillNotWalkRefusesEverything(t *testing.T) {
	const sentence = "Cursor keeps its sessions in a folder CURSOR_CONFIG_DIR or XDG_CONFIG_HOME names outside the program's own folder or through a link, which CYFR does not reach; name a folder inside the program's own, or none, in the program's settings."
	for label, c := range map[string]struct {
		variable string
		value    func(home, outside string) string
	}{
		"CURSOR_CONFIG_DIR through a link": {"CURSOR_CONFIG_DIR", func(home, outside string) string { return linkedOut(t, home, outside, "cfg") }},
		"CURSOR_CONFIG_DIR outside":        {"CURSOR_CONFIG_DIR", func(_, outside string) string { return outside }},
		"XDG_CONFIG_HOME through a link":   {"XDG_CONFIG_HOME", func(home, outside string) string { return linkedOut(t, home, outside, "xdg") }},
		"XDG_CONFIG_HOME outside":          {"XDG_CONFIG_HOME", func(_, outside string) string { return outside }},
	} {
		t.Run(label, func(t *testing.T) {
			home, outside := t.TempDir(), t.TempDir()
			value := c.value(home, outside)
			session := brainwire.NewUUID()
			planted := filepath.Join(value, "acp-sessions", session)
			if c.variable == "XDG_CONFIG_HOME" {
				planted = filepath.Join(value, "cursor", "acp-sessions", session)
			}
			if err := os.MkdirAll(planted, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(planted, "store.db"), []byte("x"), 0o600); err != nil {
				t.Fatal(err)
			}
			opened := func() *wireSession {
				s := startCursor(t, home)
				t.Setenv(c.variable, value)
				s.expect("hello")
				return s
			}
			st := opened()
			st.send(startCommand("", map[string]any{}, filesTool))
			if why := st.why(); why != "unrunnable" || !strings.Contains(st.stderr.String(), sentence) {
				t.Fatalf("the start is refused with the sentence: %v %s", why, st.stderr.String())
			}
			m := opened()
			m.send(map[string]any{"t": "models", "id": "mdl_1"})
			if e := m.next(); e["t"] != "refused" || e["reason"] != sentence {
				t.Fatalf("a listing is refused with the sentence: %v", e)
			}
			m.end()
			f := opened()
			f.send(map[string]any{"t": "forget", "id": "fgt_1", "session": session})
			if e := f.next(); e["t"] != "refused" || e["reason"] != sentence {
				t.Fatalf("a forget is refused with the sentence: %v", e)
			}
			f.end()
			sessions, _ := filepath.Glob(filepath.Join(filepath.Dir(planted), "*"))
			if len(sessions) != 1 || countOf(home, "servers") != 0 || countOf(home, "load") != 0 {
				t.Fatalf("no session was made or asked for, and the one there stays: %v %v", sessions, cursorLog(home))
			}
		})
	}
	t.Run("inside", func(t *testing.T) {
		home := t.TempDir()
		s := startCursor(t, home)
		t.Setenv("CURSOR_CONFIG_DIR", filepath.Join(home, "cfg"))
		session := freshCursor(s)
		s.end()
		f := startCursor(t, home)
		t.Setenv("CURSOR_CONFIG_DIR", filepath.Join(home, "cfg"))
		f.expect("hello")
		f.send(map[string]any{"t": "forget", "id": "fgt_1", "session": session})
		if e := f.next(); e["t"] != "forgot" {
			t.Fatalf("a folder inside the program's own is where the forget removes the session: %v", e)
		}
		if _, err := os.Lstat(filepath.Join(home, "cfg", "acp-sessions", session)); !os.IsNotExist(err) {
			t.Fatalf("the session's folder is gone: %v", err)
		}
	})
}

// linkedOut is a link in home named `name` to a folder of its own in
// outside, as a configuration folder reached through a link would be.
func linkedOut(t *testing.T, home, outside, name string) string {
	t.Helper()
	target := filepath.Join(outside, name)
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(home, name)); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(home, name)
}

// A record of the server's name is read only when it is a regular file of
// the user's own, reached through no link, within its bound, holding a
// name the driver gives; anything else is no record, and the name is
// listed for again, the start never held by it. A record is written anew,
// never through a name another file shares.
func TestCursorsServerRecordIsReadCarefullyAndWrittenWhole(t *testing.T) {
	for label, plant := range map[string]func(t *testing.T, record string){
		"a fifo": func(t *testing.T, record string) {
			if err := syscall.Mkfifo(record, 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"a file past its bound": func(t *testing.T, record string) {
			if err := os.WriteFile(record, []byte("cyfr-2"+strings.Repeat(" ", 1<<20)), 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"a name the driver never gives": func(t *testing.T, record string) {
			if err := os.WriteFile(record, []byte("cyfr-1"), 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"a link": func(t *testing.T, record string) {
			target := record + "-target"
			if err := os.WriteFile(target, []byte("cyfr-2"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, record); err != nil {
				t.Fatal(err)
			}
		},
		"a folder": func(t *testing.T, record string) {
			if err := os.Mkdir(record, 0o700); err != nil {
				t.Fatal(err)
			}
		},
		"a file another name shares": func(t *testing.T, record string) {
			shared := filepath.Join(filepath.Dir(record), "..", "shared")
			if err := os.WriteFile(shared, []byte("cyfr-1"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Link(shared, record); err != nil {
				t.Fatal(err)
			}
		},
	} {
		t.Run(label, func(t *testing.T) {
			s := startCursor(t, "")
			session := freshCursor(s)
			s.end()
			record := filepath.Join(s.home, ".cache", "cyfr-acp", "servers", session)
			if err := os.RemoveAll(record); err != nil {
				t.Fatal(err)
			}
			plant(t, record)
			r := startCursor(t, s.home)
			if e := resumed(r, session, filesTool); e["t"] != "started" {
				t.Fatalf("the session goes on: %v", e)
			}
			r.end()
			if countOf(s.home, "list") != 2 {
				t.Fatalf("the name is listed for again: %v", cursorLog(s.home))
			}
			if shared, err := os.ReadFile(filepath.Join(s.home, ".cache", "cyfr-acp", "shared")); err == nil && string(shared) != "cyfr-1" {
				t.Fatalf("a file another name shares is never written: %q", shared)
			}
			if label != "a folder" {
				if held, err := os.ReadFile(record); err != nil || string(held) != "cyfr" {
					t.Fatalf("the record is written anew: %q %v", held, err)
				}
			}
		})
	}
}

// Antigravity's and OpenCode's forgets look at no record of Cursor's: a
// file where one would sit changes nothing of theirs.
func TestOtherProgramsForgetsLookAtNoServerRecord(t *testing.T) {
	plant := func(t *testing.T, home string) {
		if err := os.MkdirAll(filepath.Join(home, ".cache", "cyfr-acp"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(home, ".cache", "cyfr-acp", "servers"), []byte("an unrelated file"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Run("Antigravity", func(t *testing.T) {
		s := startDriver(t)
		session := startFresh(s, map[string]any{})
		s.end()
		plant(t, s.home)
		f := startDriverWith(t, antigravity, s.home)
		f.expect("hello")
		f.send(map[string]any{"t": "forget", "id": "fgt_1", "session": session})
		if e := f.next(); e["t"] != "forgot" {
			t.Fatalf("the forget stands: %v", e)
		}
	})
	t.Run("OpenCode", func(t *testing.T) {
		s := startOpenCode(t, "")
		session := freshOpenCode(s, map[string]any{})
		s.end()
		plant(t, s.home)
		f := startOpenCode(t, s.home)
		f.expect("hello")
		f.send(map[string]any{"t": "forget", "id": "fgt_1", "session": session})
		if e := f.next(); e["t"] != "forgot" {
			t.Fatalf("the forget stands: %v", e)
		}
	})
}

// Where the program names a call's server, a call of another server's with
// the same arguments is the person's own and is shown, and only the call
// of the server the driver named its own is CYFR's.
func TestCursorsCallOfAnotherServerWithTheSameArgumentsIsTheirs(t *testing.T) {
	s := startCursor(t, "")
	freshCursor(s)
	postText(s, "stp_1", "trn_1", "samecall")
	ask := s.expect("ask")
	if err := os.WriteFile(filepath.Join(s.home, "go-on"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	s.send(map[string]any{"t": "answer", "id": "ans_1", "ask": ask["ask"], "content": "x", "is_error": false})
	got := s.until("idle")
	own := ofType(got, "own")
	if len(own) != 2 || own[0]["name"] != "mcp:notes/files" || own[0]["phase"] != "start" || own[1]["name"] != "mcp:notes/files" ||
		own[1]["phase"] != "end" || saidOf(got) != "the tool answered x" {
		t.Fatalf("the person's call is shown as theirs, and CYFR's is none of the program's own: %v", got)
	}
}
