// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/toolsock"
)

func TestMain(m *testing.M) {
	if os.Getenv(fakeEnv) != "" {
		os.Exit(fakeACP())
	}
	os.Exit(m.Run())
}

// lockedBuffer is the driver's standard error, read by the test.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// steerless is a profile of the tests' own: Antigravity's, but taking no
// message mid-turn and no instructions for one process.
var steerless = func() *profile {
	p := *antigravity
	p.name, p.title, p.steers = "cyfr-steerless", "Steerless", false
	p.appends = nil
	return &p
}()

var sockets atomic.Int64

// wireSession is one driver under test, speaking the wire over pipes with
// the fake program its harness.
type wireSession struct {
	t      *testing.T
	in     *io.PipeWriter
	events chan map[string]any
	raw    []string
	rawMu  sync.Mutex
	done   chan int
	stderr *lockedBuffer
	home   string
	d      *driver
}

func startDriver(t *testing.T) *wireSession {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GEMINI_HOME", "")
	t.Setenv(fakeEnv, "1")
	return startDriverWith(t, antigravity, home)
}

// startDriverWith runs a driver of the profile p in `home`, its tool
// socket a name of its own, as each space's is its own, each of `set`
// applied to it before it serves.
func startDriverWith(t *testing.T, p *profile, home string, set ...func(*driver)) *wireSession {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &wireSession{t: t, in: inW, events: make(chan map[string]any, 1024), done: make(chan int, 1), stderr: &lockedBuffer{}, home: home}
	c := brainwire.NewConn(p.name, outW, s.stderr)
	s.d = newDriver(p, []string{os.Args[0]}, c, home)
	s.d.socketName = fmt.Sprintf("cyfr-acp-test-%d-%d", os.Getpid(), sockets.Add(1))
	for _, f := range set {
		f(s.d)
	}
	stop := make(chan os.Signal)
	go func() {
		status := brainwire.Serve(c, s.d, inR, stop)
		_ = outW.Close()
		s.done <- status
	}()
	go func() {
		defer close(s.events)
		scanner := bufio.NewScanner(outR)
		scanner.Buffer(make([]byte, 64<<10), 2*brainwire.MaxLineBytes)
		for scanner.Scan() {
			line := append([]byte(nil), scanner.Bytes()...)
			s.rawMu.Lock()
			s.raw = append(s.raw, string(line))
			s.rawMu.Unlock()
			if _, _, err := brainwire.ReadLine(line, brainwire.Events); err != nil {
				t.Errorf("the driver wrote a line the wire does not read (%v): %.200s", err, line)
				continue
			}
			var e map[string]any
			_ = json.Unmarshal(line, &e)
			s.events <- e
		}
	}()
	t.Cleanup(func() { s.in.Close() })
	return s
}

func (s *wireSession) send(command map[string]any) {
	s.t.Helper()
	line, err := json.Marshal(command)
	if err != nil {
		s.t.Fatal(err)
	}
	if _, _, err := brainwire.ReadLine(line, brainwire.Commands); err != nil {
		s.t.Fatalf("a test command the wire does not read (%v): %s", err, line)
	}
	if _, err := s.in.Write(append(line, '\n')); err != nil {
		s.t.Fatal(err)
	}
}

func (s *wireSession) next() map[string]any {
	s.t.Helper()
	select {
	case e, ok := <-s.events:
		if !ok {
			s.t.Fatalf("the driver ended: %s", s.stderr.String())
		}
		return e
	case <-time.After(20 * time.Second):
		s.t.Fatal("no event in time")
	}
	return nil
}

func (s *wireSession) expect(t string) map[string]any {
	s.t.Helper()
	e := s.next()
	if e["t"] != t {
		s.t.Fatalf("expected %s, got %v", t, e)
	}
	return e
}

// until gathers events up to and including the first of type t.
func (s *wireSession) until(t string) []map[string]any {
	s.t.Helper()
	var got []map[string]any
	for {
		e := s.next()
		got = append(got, e)
		if e["t"] == t {
			return got
		}
	}
}

func (s *wireSession) end() int {
	s.t.Helper()
	_ = s.in.Close()
	return s.exit()
}

// exit is the driver's status once it has ended by itself.
func (s *wireSession) exit() int {
	s.t.Helper()
	select {
	case status := <-s.done:
		return status
	case <-time.After(20 * time.Second):
		s.t.Fatal("the driver did not end")
	}
	return -1
}

func (s *wireSession) output() string {
	s.rawMu.Lock()
	defer s.rawMu.Unlock()
	return strings.Join(s.raw, "\n")
}

var filesTool = map[string]any{"name": "files", "description": "Read the athanor's files", "parameters": map[string]any{"type": "object"}}
var notesTool = map[string]any{"name": "notes", "description": "Keep notes", "parameters": map[string]any{"type": "object"}}

func startCommand(session string, config map[string]any, tools ...any) map[string]any {
	command := map[string]any{"t": "start", "gen": 3, "config": config, "system": "be brief", "tools": tools}
	if session != "" {
		command["session"] = session
	}
	return command
}

// startFresh reads the driver's hello and starts a new session with CYFR's
// files tool.
func startFresh(s *wireSession, config map[string]any) string {
	s.t.Helper()
	s.expect("hello")
	s.send(startCommand("", config, filesTool))
	started := s.expect("started")
	if started["fresh"] != true || len(started["held"].([]any)) != 0 || started["account"] != "signed_in" || !brainwire.IsUUID(started["session"].(string)) {
		s.t.Fatalf("a fresh start answers a new session holding nothing, signed in: %v", started)
	}
	return started["session"].(string)
}

func resumed(s *wireSession, session string, tools ...any) map[string]any {
	s.t.Helper()
	s.expect("hello")
	s.send(startCommand(session, map[string]any{}, tools...))
	return s.next()
}

func postText(s *wireSession, id, turn, text string) {
	s.t.Helper()
	s.send(map[string]any{"t": "post", "id": id, "work": turn, "content": []any{map[string]any{"type": "text", "text": text}}})
	if e := s.expect("accepted"); e["id"] != id {
		s.t.Fatalf("the post is accepted by its id: %v", e)
	}
}

func saidOf(events []map[string]any) string {
	said := ""
	for _, e := range events {
		if e["t"] == "said" {
			said += e["text"].(string)
		}
	}
	return said
}

func ofType(events []map[string]any, t string) []map[string]any {
	var out []map[string]any
	for _, e := range events {
		if e["t"] == t {
			out = append(out, e)
		}
	}
	return out
}

// sessionGiven is what the fake says the session and the prompt were given
// (its "params" turn).
func sessionGiven(s *wireSession, id string) map[string]any {
	s.t.Helper()
	postText(s, id, "trn_p", "params")
	var given map[string]any
	if err := json.Unmarshal([]byte(saidOf(s.until("idle"))), &given); err != nil {
		s.t.Fatalf("the fake's params reply reads: %v", err)
	}
	return given
}

func TestHelloNamesTheProgramsDriverAndAnUnknownNameIsRefused(t *testing.T) {
	s := startDriver(t)
	hello := s.expect("hello")
	if hello["v"] != float64(brainwire.Version) || hello["driver"] != "cyfr-antigravity" || len(hello["boot"].(string)) != 32 {
		t.Fatalf("hello names the version, the profile's driver and a fresh boot: %v", hello)
	}
	if status := s.end(); status != 0 {
		t.Fatalf("an input that ends ends the driver with 0: %d", status)
	}
	if status := run("cyfr-acp", []string{"agy"}); status != 2 {
		t.Fatalf("a name no profile has ends with 2: %d", status)
	}
}

// A new session names CYFR's server, the stub on the socket, and the
// instructions in Antigravity's own place; a resume in a second process
// names the same server again, and the stub's listing there is that
// start's tools, a set changed since.
func TestASessionNamesTheSocketsServerAndAResumeListsTheNewSet(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	given := sessionGiven(s, "stp_params")
	opened := given["session"].(map[string]any)
	server := []any{map[string]any{"name": "cyfr", "command": defaultStub, "args": []any{"--socket", s.d.socketName}, "env": []any{}}}
	cwd, _ := os.Getwd()
	if !reflect.DeepEqual(opened["mcpServers"], server) || opened["cwd"] != cwd ||
		!reflect.DeepEqual(opened["_meta"], map[string]any{"antigravity": map[string]any{"systemPrompt": map[string]any{"append": "be brief"}}}) {
		t.Fatalf("session/new names CYFR's server alone, the working folder and the instructions' place: %v", opened)
	}
	prompt := given["prompt"].(map[string]any)
	if len(prompt["prompt"].([]any)) != 1 {
		t.Fatalf("instructions in their own place lead no prompt: %v", prompt)
	}
	postText(s, "stp_tools", "trn_1", "tools")
	if said := saidOf(s.until("idle")); said != "listed files" {
		t.Fatalf("the stub lists the start's tools: %q", said)
	}
	s.end()

	r := startDriverWith(t, antigravity, s.home)
	if e := resumed(r, session, filesTool, notesTool); e["t"] != "started" || e["fresh"] != false || e["session"] != session ||
		len(e["held"].([]any)) != 0 || e["account"] != "signed_in" {
		t.Fatalf("a resume goes on with the session, holding none: %v", e)
	}
	again := sessionGiven(r, "stp_params_2")["session"].(map[string]any)
	server[0].(map[string]any)["args"] = []any{"--socket", r.d.socketName}
	if !reflect.DeepEqual(again["mcpServers"], server) || again["sessionId"] != session {
		t.Fatalf("session/resume names CYFR's server again: %v", again)
	}
	postText(r, "stp_tools_2", "trn_2", "tools")
	if said := saidOf(r.until("idle")); said != "listed files,notes" {
		t.Fatalf("the resumed process's stub lists the resume's changed set: %q", said)
	}
}

// A resume the program answers as of a missing session is loaded; only the
// load's not-found answer is `gone`. A load that succeeds goes on with the
// session, its replay dropped; a load or resume failing otherwise ends the
// driver.
func TestOnlyTheLoadsNotFoundIsGone(t *testing.T) {
	t.Run("gone", func(t *testing.T) {
		s := startDriver(t)
		if e := resumed(s, "8f0e6c0a-0d7e-4b8e-9c1e-6b8b6f0a1d2e", filesTool); e["t"] != "gone" {
			t.Fatalf("a session the folder lacks is gone: %v", e)
		}
		startFresh2 := func() {
			s.send(startCommand("", map[string]any{}, filesTool))
			if e := s.expect("started"); e["fresh"] != true {
				t.Fatalf("a fresh start runs after gone: %v", e)
			}
		}
		startFresh2()
	})
	t.Run("a load goes on", func(t *testing.T) {
		s := startDriver(t)
		session := startFresh(s, map[string]any{})
		s.end()
		t.Setenv("FAKE_RESUME_MISSING", "1")
		r := startDriverWith(t, antigravity, s.home)
		if e := resumed(r, session, filesTool); e["t"] != "started" || e["fresh"] != false || e["session"] != session {
			t.Fatalf("a load goes on with the session: %v", e)
		}
		postText(r, "stp_after_load", "trn_1", "hello")
		got := r.until("idle")
		if saidOf(got) != "ok" || strings.Contains(r.output(), "REPLAYED") || len(ofType(got, "own")) != 0 {
			t.Fatalf("nothing of the load's replay reaches the wire: %v", got)
		}
	})
	for _, env := range []string{"FAKE_RESUME_OTHER", "FAKE_LOAD_OTHER"} {
		t.Run(env, func(t *testing.T) {
			t.Setenv("FAKE_RESUME_MISSING", "1")
			t.Setenv(env, "1")
			s := startDriver(t)
			s.expect("hello")
			s.send(startCommand("8f0e6c0a-0d7e-4b8e-9c1e-6b8b6f0a1d2e", map[string]any{}, filesTool))
			if status := s.exit(); status != 1 || strings.Contains(s.output(), `"gone"`) ||
				!strings.Contains(s.stderr.String(), "Antigravity refused to start the session") {
				t.Fatalf("another failure is no gone and ends the driver with its words: %d %q", status, s.stderr.String())
			}
		})
	}
}

// A post becomes a prompt carrying its uuid in `_meta`, the turn streams
// and is said whole, its usage named by this process's boot and the
// prompt, and `idle` names the post.
func TestAPostIsAPromptWithItsUUIDAndIdleNamesIt(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	given := sessionGiven(s, "stp_post")
	meta := given["prompt"].(map[string]any)["_meta"]
	if !reflect.DeepEqual(meta, map[string]any{"cyfr": map[string]any{"post": brainwire.PostUUID("stp_post")}}) {
		t.Fatalf("the prompt carries the post's uuid: %v", meta)
	}
	postText(s, "stp_hello", "trn_1", "hello")
	got := s.until("idle")
	text := ""
	for _, e := range got {
		if e["gen"] != float64(3) || e["work"] != "trn_1" {
			t.Fatalf("every event of the turn names its gen and its work: %v", e)
		}
		if e["t"] == "text" {
			text += e["delta"].(string)
		}
	}
	if text != "ok" || saidOf(got) != "ok" {
		t.Fatalf("the reply streams and is said whole: %q %q", text, saidOf(got))
	}
	idle := got[len(got)-1]
	if idle["stop"] != "end_turn" || fmt.Sprint(idle["answered"]) != "[stp_hello]" {
		t.Fatalf("idle names the post its prompt carried: %v", idle)
	}
	for _, canary := range []string{stderrCanary, "FAKE-TIER-CANARY", s.home} {
		if strings.Contains(s.output(), canary) {
			t.Fatalf("nothing of the program's standard error, its tier or its folder reaches the wire: %s", canary)
		}
	}
	if !strings.Contains(s.stderr.String(), stderrCanary) {
		t.Fatal("the program's standard error is the driver's (a positive control for the check above)")
	}
}

// A post while a prompt runs is a second prompt, `accepted` once the
// program answered the earlier one; the turn's one idle names both posts.
func TestASteerTheProgramConfirmsIsAcceptedAndIdleNamesBoth(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_first", "trn_1", "slow")
	if e := s.expect("text"); e["delta"] != "Starting. " {
		t.Fatalf("the turn's first part streams: %v", e)
	}
	postText(s, "stp_second", "trn_1", "the steer")
	got := s.until("idle")
	if saidOf(got) != "Starting. Read the steer: the steer" || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first stp_second]" ||
		got[len(got)-1]["stop"] != "end_turn" {
		t.Fatalf("one native turn, its idle naming both posts: %v", got)
	}
	if usages := ofType(got, "usage"); len(usages) != 1 || usages[0]["accounting"] != "partial" {
		t.Fatalf("the earlier prompt's bare answer carries no usage; the later's does: %v", usages)
	}
}

// A steer the program refuses is `refused`, and the turn's idle names only
// the post it took.
func TestASteerTheProgramRefusesIsRefused(t *testing.T) {
	t.Setenv("FAKE_STEER_FAIL", "1")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_first", "trn_1", "slow")
	s.expect("text")
	s.send(map[string]any{"t": "post", "id": "stp_second", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "the steer"}}})
	got := s.until("idle")
	refused := ofType(got, "refused")
	if len(refused) != 1 || refused[0]["id"] != "stp_second" || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first]" {
		t.Fatalf("the refused steer is not among the turn's posts: %v", got)
	}
}

// A profile that takes no message mid-turn answers a post then `later` at
// once and writes nothing, and its instructions lead the session's first
// prompt alone.
func TestAPostMidTurnWithoutASteerIsLaterAndWritesNothing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GEMINI_HOME", "")
	t.Setenv(fakeEnv, "1")
	s := startDriverWith(t, steerless, home)
	if e := s.expect("hello"); e["driver"] != "cyfr-steerless" {
		t.Fatalf("hello names the profile's driver: %v", e)
	}
	s.send(startCommand("", map[string]any{}, filesTool))
	s.expect("started")
	first := sessionGiven(s, "stp_params")
	if first["session"].(map[string]any)["_meta"] != nil {
		t.Fatalf("a profile with no place for instructions names none: %v", first)
	}
	blocks := first["prompt"].(map[string]any)["prompt"].([]any)
	if len(blocks) != 2 || blocks[0].(map[string]any)["text"] != replacingWords+"be brief" {
		t.Fatalf("the instructions lead the first prompt: %v", blocks)
	}
	postText(s, "stp_first", "trn_1", "slow")
	s.expect("text")
	s.send(map[string]any{"t": "post", "id": "stp_second", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "the steer"}}})
	if e := s.expect("later"); e["id"] != "stp_second" {
		t.Fatalf("a post mid-turn is later: %v", e)
	}
	got := s.until("idle")
	if saidOf(got) != "Starting. no steer came" || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first]" {
		t.Fatalf("nothing of the later post was written: %v", got)
	}
	again := sessionGiven(s, "stp_params_2")["prompt"].(map[string]any)["prompt"].([]any)
	if len(again) != 1 {
		t.Fatalf("handed instructions lead no later prompt: %v", again)
	}
}

// A call of CYFR's tool through the socket is an ask, held until its
// answer, and the answer is the call's result; the permission question
// before it is answered allow and stands in for nothing.
func TestAnAskIsHeldUntilItsAnswerAndAPermissionIsNoAnswer(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_read", "trn_1", "read it")
	var ask map[string]any
	for _, e := range s.until("ask") {
		if e["t"] == "own" {
			t.Fatalf("CYFR's call is no own tool: %v", e)
		}
		ask = e
	}
	if ask["name"] != "files" || !brainwire.IsUUID(ask["ask"].(string)) || ask["work"] != "trn_1" || ask["gen"] != float64(3) ||
		!strings.Contains(s.output(), `"arguments":{"path":"notes.txt","count":12345678901234567890}`) {
		t.Fatalf("an ask names CYFR's tool and the call's arguments whole: %v", ask)
	}
	select {
	case e := <-s.events:
		t.Fatalf("nothing more comes while the ask is held: %v", e)
	case <-time.After(300 * time.Millisecond): // sleep-ok: a held call shows nothing until its answer
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask["ask"], "content": "three lines", "is_error": false})
	if e := s.expect("accepted"); e["id"] != "stp_answer" {
		t.Fatalf("the answer is accepted: %v", e)
	}
	got := s.until("idle")
	if said := saidOf(got); said != `permission selected allow; the tool answered "three lines", error false` {
		t.Fatalf("the permission is allowed and the answer reaches the program as the call's result: %q", said)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_again", "ask": ask["ask"], "content": "x", "is_error": false})
	if e := s.expect("refused"); e["id"] != "stp_again" {
		t.Fatalf("an answer naming no held ask is refused: %v", e)
	}
}

// Two drivers of one home at once, each its own socket as two spaces have,
// each program's call asked under the same JSON-RPC id: each answer
// reaches its own session alone.
func TestTwoDriversAtOnceEachAnswerTheirOwnSession(t *testing.T) {
	a := startDriver(t)
	b := startDriverWith(t, antigravity, a.home)
	startFresh(a, map[string]any{})
	startFresh(b, map[string]any{})
	postText(a, "stp_a", "trn_a", "read")
	postText(b, "stp_b", "trn_b", "read")
	lastAsk := func(s *wireSession) map[string]any {
		got := s.until("ask")
		return got[len(got)-1]
	}
	askA, askB := lastAsk(a), lastAsk(b)
	a.send(map[string]any{"t": "answer", "id": "stp_cross", "ask": askB["ask"], "content": "x", "is_error": false})
	if e := a.expect("refused"); e["id"] != "stp_cross" {
		t.Fatalf("one driver holds no ask of another's: %v", e)
	}
	b.send(map[string]any{"t": "answer", "id": "stp_answer_b", "ask": askB["ask"], "content": "for b", "is_error": false})
	b.expect("accepted")
	a.send(map[string]any{"t": "answer", "id": "stp_answer_a", "ask": askA["ask"], "content": "for a", "is_error": true})
	a.expect("accepted")
	if said := saidOf(a.until("idle")); said != `permission selected allow; the tool answered "for a", error true` {
		t.Fatalf("the first session's call gets its own answer: %q", said)
	}
	if said := saidOf(b.until("idle")); said != `permission selected allow; the tool answered "for b", error false` {
		t.Fatalf("the second session's call gets its own answer: %q", said)
	}
}

// A stub that never lists CYFR's tools fails the start, saying so on the
// driver's standard error, at the listing's bound.
func TestAStubThatNeverListsFailsTheStart(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GEMINI_HOME", "")
	t.Setenv(fakeEnv, "1")
	t.Setenv("FAKE_NO_LIST", "1")
	s := startDriverWith(t, antigravity, home, func(d *driver) { d.listWait = 300 * time.Millisecond })
	s.expect("hello")
	s.send(startCommand("", map[string]any{}, filesTool))
	if status := s.exit(); status != 1 || strings.Contains(s.output(), `"started"`) ||
		!strings.Contains(s.stderr.String(), "CYFR's tools did not reach Antigravity") {
		t.Fatalf("no listing ends the driver with its words: %d %q", status, s.stderr.String())
	}
}

// The program's own tools are `own`, by kind, or by title where the kind
// is other, each started and ended once; CYFR's own calls are not, by
// their title or by their server's name.
func TestOwnToolsAreOwnAndCYFRsCallsAreNot(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_own", "trn_1", "own")
	var seen []string
	for _, e := range ofType(s.until("idle"), "own") {
		seen = append(seen, e["name"].(string)+":"+e["phase"].(string))
	}
	want := []string{"read:start", "read:end", "execute:start", "execute:end", "Run mine_tool:start", "Run mine_tool:end",
		"Run broken_tool:start", "Run broken_tool:end"}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("own tools by name, CYFR's left out: %v", seen)
	}
}

// Usage: counts that read are partial, since the program's title request
// is in none; a missing count is partial naming none; no usage is
// unavailable; the result ids differ across two processes.
func TestUsageIsPartialOrUnavailableAndItsIDsDifferAcrossProcesses(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	usageOf := func(s *wireSession, id, words string) map[string]any {
		postText(s, id, "trn_u", words)
		usages := ofType(s.until("idle"), "usage")
		if len(usages) != 1 {
			t.Fatalf("one usage a native turn: %v", usages)
		}
		return usages[0]
	}
	complete := usageOf(s, "stp_1", "hello")
	if complete["accounting"] != "partial" || !reflect.DeepEqual(complete["models"], []any{map[string]any{"model": "fake-neon",
		"counts": map[string]any{"input_tokens": float64(100), "output_tokens": float64(20), "cache_read_tokens": float64(30), "cache_write_tokens": float64(0)}}}) {
		t.Fatalf("the prompt's counts under the session's model, partial: %v", complete)
	}
	if missing := usageOf(s, "stp_2", "missing"); missing["accounting"] != "partial" || len(missing["models"].([]any)) != 0 {
		t.Fatalf("a missing count is partial naming no counts: %v", missing)
	}
	if none := usageOf(s, "stp_3", "nousage"); none["accounting"] != "unavailable" || none["models"] != nil {
		t.Fatalf("no usage is unavailable, never zeros: %v", none)
	}
	first := complete["result"].(string)
	s.end()
	r := startDriverWith(t, antigravity, s.home)
	resumed(r, session, filesTool)
	if again := usageOf(r, "stp_1", "hello"); again["result"] == first || !strings.HasPrefix(first, s.d.c.Boot+"-") {
		t.Fatalf("a result is named by its process's boot and prompt, never again: %v %v", first, again["result"])
	}
}

// Each stop reason maps as the wire takes it; a refusal and a cancel no
// Stop sent are errors in the driver's words, and a prompt's JSON-RPC error
// is typed by its shape alone, never in the program's words.
func TestEachStopReasonAndErrorMaps(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	cases := []struct{ words, stop, kind string }{
		{"stop:end_turn", "end_turn", ""},
		{"stop:max_tokens", "limit", ""},
		{"stop:max_turn_requests", "limit", ""},
		{"stop:refusal", "error", "invalid_request"},
		{"stop:cancelled", "error", "provider_error"},
		{"rpcerr:-32000:Authentication required", "error", "authentication"},
		{"rpcerr:-32603:RESOURCE_EXHAUSTED: Quota exceeded", "error", "rate_limited"},
		{"rpcerr:-32603:Internal error", "error", "provider_error"},
	}
	for i, c := range cases {
		postText(s, fmt.Sprintf("stp_%d", i), "trn_1", c.words)
		got := s.until("idle")
		errs := ofType(got, "error")
		if got[len(got)-1]["stop"] != c.stop || (c.kind == "") != (len(errs) == 0) || (c.kind != "" && errs[0]["type"] != c.kind) {
			t.Fatalf("%s: stop %s, error %q: %v", c.words, c.stop, c.kind, got)
		}
	}
	if strings.Contains(s.output(), "HARNESS-WORDS") {
		t.Fatal("no error carries the program's words")
	}
}

// Signed out is the one -32000 shape: the start is `started` signed out,
// the process kept, and each post and listing refused so; another
// failure, even in words naming a sign-in, is no sign-out.
func TestOnlyTheSignedOutCodeReadsSignedOut(t *testing.T) {
	t.Run("signed out", func(t *testing.T) {
		t.Setenv("FAKE_SIGNED_OUT", "1")
		s := startDriver(t)
		s.expect("hello")
		s.send(startCommand("", map[string]any{}, filesTool))
		e := s.expect("started")
		if e["account"] != "signed_out" || e["fresh"] != true || !brainwire.IsUUID(e["session"].(string)) {
			t.Fatalf("a signed-out start says so: %v", e)
		}
		s.send(map[string]any{"t": "post", "id": "stp_post", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "hello"}}})
		if e := s.expect("refused"); e["account"] != "signed_out" || e["reason"] != antigravity.signedOutSentence {
			t.Fatalf("a post is refused as signed out: %v", e)
		}
		s.send(map[string]any{"t": "models", "id": "mdl_1"})
		if e := s.expect("refused"); e["account"] != "signed_out" {
			t.Fatalf("a listing is refused as signed out: %v", e)
		}
		s.end()
		l := startDriverWith(t, antigravity, s.home)
		l.expect("hello")
		l.send(map[string]any{"t": "models", "id": "mdl_2"})
		if e := l.expect("refused"); e["account"] != "signed_out" || e["reason"] != antigravity.signedOutSentence {
			t.Fatalf("a listing of its own is refused as signed out: %v", e)
		}
	})
	t.Run("another failure", func(t *testing.T) {
		t.Setenv("FAKE_NEW_FAIL", "1")
		s := startDriver(t)
		s.expect("hello")
		s.send(startCommand("", map[string]any{}, filesTool))
		if status := s.exit(); status != 1 || strings.Contains(s.output(), "signed_out") {
			t.Fatalf("another failure ends the driver and says nothing of the account: %d %s", status, s.output())
		}
	})
}

// A forget removes the session's files and the driver's record of its
// instructions, and leaves another session's files and the program's
// index; the session running and a name that is no session are refused.
func TestForgetRemovesTheNamedFilesAndLeavesTheRest(t *testing.T) {
	t.Setenv("FAKE_NO_APPEND", "1")
	s := startDriver(t)
	first := startFresh(s, map[string]any{})
	postText(s, "stp_1", "trn_1", "hello")
	s.until("idle")
	second := func() string {
		s.end()
		o := startDriverWith(t, antigravity, s.home)
		id := startFresh(o, map[string]any{})
		o.send(map[string]any{"t": "forget", "id": "obx_running", "session": id})
		if e := o.expect("refused"); e["id"] != "obx_running" {
			t.Fatalf("the session running is not forgotten: %v", e)
		}
		o.send(map[string]any{"t": "forget", "id": "obx_bad", "session": "not-a-session"})
		if e := o.expect("refused"); e["id"] != "obx_bad" {
			t.Fatalf("a name that is no session is refused: %v", e)
		}
		o.end()
		return id
	}()
	cli := filepath.Join(s.home, ".gemini", "antigravity-cli")
	named := func(id string) []string {
		return []string{filepath.Join(cli, "brain", id), filepath.Join(cli, agySessionDatabases, id+".db"),
			filepath.Join(cli, "annotations", id+".pbtxt"), instructionsFile(s.home, id)}
	}
	for _, name := range named(first) {
		if _, err := os.Stat(name); err != nil {
			t.Fatalf("the session's files are there before the forget: %v", err)
		}
	}
	f := startDriverWith(t, antigravity, s.home)
	f.expect("hello")
	f.send(map[string]any{"t": "forget", "id": "obx_1", "session": first})
	if e := f.expect("forgot"); e["id"] != "obx_1" || e["session"] != first {
		t.Fatalf("the forget is answered: %v", e)
	}
	for _, name := range named(first) {
		if _, err := os.Lstat(name); !brainwire.Absent(err) {
			t.Fatalf("the forgotten session's file is gone: %s %v", name, err)
		}
	}
	for _, name := range append(named(second)[:3], filepath.Join(cli, agySummaryIndex)) {
		if _, err := os.Stat(name); err != nil {
			t.Fatalf("another session's files and the program's index stay: %v", err)
		}
	}
}

// A Stop while a prompt runs cancels it in ACP's way before the program is
// asked to end with a TERM.
func TestAStopCancelsBeforeTheTerminate(t *testing.T) {
	t.Setenv("FAKE_HOLD", "1")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_slow", "trn_1", "slow")
	s.expect("text")
	s.end()
	log, _ := os.ReadFile(filepath.Join(s.home, "fake-acp.log"))
	if string(log) != "cancel\nterm\n" {
		t.Fatalf("the cancel comes first, then the TERM: %q", log)
	}
}

// An initialize below the profile's version, or lacking a resume or a
// load, is refused with the driver's words before any session.
func TestAnInitializeThatDoesNotQualifyIsRefused(t *testing.T) {
	for env, words := range map[string]string{
		"FAKE_VERSION=1.4.9": "Antigravity 1.4.9 is older than 1.5.0",
		"FAKE_NO_RESUME=1":   "does not offer both to resume and to load a session",
		"FAKE_NO_LOAD=1":     "does not offer both to resume and to load a session",
	} {
		t.Run(env, func(t *testing.T) {
			name, value, _ := strings.Cut(env, "=")
			t.Setenv(name, value)
			s := startDriver(t)
			s.expect("hello")
			s.send(startCommand("", map[string]any{}, filesTool))
			if status := s.exit(); status != 1 || !strings.Contains(s.stderr.String(), words) || strings.Contains(s.output(), `"started"`) {
				t.Fatalf("the start is refused with its words: %d %q", status, s.stderr.String())
			}
		})
	}
}

// Updates of kinds the driver does not use, another session's text and a
// request it has no handler for change nothing on the wire; the request is
// answered method-not-found.
func TestAnUnknownUpdateIsDroppedAndAnUnknownRequestRefused(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_strange", "trn_1", "strange")
	got := s.until("idle")
	for _, e := range got {
		if e["t"] != "text" && e["t"] != "said" && e["t"] != "usage" && e["t"] != "idle" {
			t.Fatalf("nothing but the reply's events: %v", e)
		}
	}
	if saidOf(got) != "fs answered -32601" {
		t.Fatalf("the request is answered method-not-found: %q", saidOf(got))
	}
	for _, canary := range []string{"PLAN-CANARY", "NEW-KIND-CANARY", "THOUGHT-CANARY", "USER-CANARY", "OTHER-SESSION-CANARY"} {
		if strings.Contains(s.output(), canary) {
			t.Fatalf("a dropped update reached the wire: %s", canary)
		}
	}
}

// A start's model and effort are set as the session's config options, and
// its access's mode where the session's differs; a model or effort the
// session does not offer, the harness's own tools and an access not listed
// each end the driver.
func TestAStartSetsItsConfigOptionsAndRefusesWhatIsNotOffered(t *testing.T) {
	t.Setenv("FAKE_MODE", "plan")
	s := startDriver(t)
	startFresh(s, map[string]any{"model": "fake-flash", "effort": "low", "access": "full-access"})
	set := sessionGiven(s, "stp_params")["set"]
	want := []any{map[string]any{"configId": "model", "value": "fake-flash"}, map[string]any{"configId": "thought_level", "value": "low"},
		map[string]any{"configId": "mode", "value": "default"}}
	if !reflect.DeepEqual(set, want) {
		t.Fatalf("the model, the effort and the access's mode are set in order: %v", set)
	}
	postText(s, "stp_1", "trn_1", "hello")
	if usages := ofType(s.until("idle"), "usage"); usages[0]["models"].([]any)[0].(map[string]any)["model"] != "fake-flash" {
		t.Fatalf("usage is counted under the model set: %v", usages)
	}
	for name, config := range map[string]map[string]any{
		"model":         {"model": "fake-none"},
		"effort":        {"effort": "max"},
		"harness tools": {"harness_tools": []any{"Read"}},
		"access":        {"access": "read-only"},
	} {
		t.Run(name, func(t *testing.T) {
			s := startDriver(t)
			s.expect("hello")
			s.send(startCommand("", config, filesTool))
			if status := s.exit(); status != 2 || strings.Contains(s.output(), `"started"`) {
				t.Fatalf("a start the program cannot honour ends the driver with 2: %d %q", status, s.stderr.String())
			}
		})
	}
}

// Models are listed from the running session, or from a listing session
// of the driver's own, which is forgotten after; each model's efforts are
// those it has a variant of, in the effort option's order.
func TestModelsAreListedWithOrWithoutASessionAndTheListingForgotten(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "mdl_1"})
	listing := s.expect("models")
	want := []any{map[string]any{"id": "fake-neon", "name": "Fake-neon", "efforts": []any{"low", "high", "xhigh"}},
		map[string]any{"id": "fake-flash", "name": "Fake-flash", "efforts": []any{}}}
	if !reflect.DeepEqual(listing["models"], want) || listing["account"] != "signed_in" ||
		!reflect.DeepEqual(listing["access"], []any{map[string]any{"id": "full-access", "name": "Full access, no approvals"}}) {
		t.Fatalf("the listing names each model, its efforts and the access: %v", listing)
	}
	databases, _ := filepath.Glob(filepath.Join(s.home, ".gemini", "antigravity-cli", agySessionDatabases, "*.db"))
	brains, _ := filepath.Glob(filepath.Join(s.home, ".gemini", "antigravity-cli", "brain", "*"))
	if len(databases)+len(brains) != 0 {
		t.Fatalf("the listing session is forgotten: %v %v", databases, brains)
	}
	if _, err := os.Stat(listingRecord(s.home)); !brainwire.Absent(err) {
		t.Fatalf("no listing is left to forget: %v", err)
	}
	s.send(startCommand("", map[string]any{}, filesTool))
	s.expect("started")
	s.send(map[string]any{"t": "models", "id": "mdl_2"})
	if again := s.expect("models"); !reflect.DeepEqual(again["models"], want) {
		t.Fatalf("the running session lists the same: %v", again)
	}
}

// Each message of a prompt's is said whole under its own messageId when
// the next begins, and the last at the prompt's answer.
func TestEachMessageIsSaidUnderItsOwnID(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_twice", "trn_1", "twice")
	var said []string
	for _, e := range ofType(s.until("idle"), "said") {
		said = append(said, e["message"].(string)+"="+e["text"].(string))
	}
	if !reflect.DeepEqual(said, []string{"m1=One.", "m2=Two."}) {
		t.Fatalf("each message is said under its id: %v", said)
	}
}

// A post during the running prompt while CYFR holds a call of its tools is
// `later` at once and writes nothing, even where the program steers: its
// confirmation could wait on the ask's answer, which the holder writes only
// after the post's. The ask's answer written next is accepted and reaches
// the program.
func TestAPostWhileAnAskIsHeldIsLater(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_read", "trn_1", "read it")
	got := s.until("ask")
	ask := got[len(got)-1]
	s.send(map[string]any{"t": "post", "id": "stp_mid", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "hello"}}})
	if e := s.expect("later"); e["id"] != "stp_mid" {
		t.Fatalf("a post while an ask is held is later: %v", e)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask["ask"], "content": "three lines", "is_error": false})
	if e := s.expect("accepted"); e["id"] != "stp_answer" {
		t.Fatalf("the ask's answer is accepted next: %v", e)
	}
	got = s.until("idle")
	if said := saidOf(got); said != `permission selected allow; the tool answered "three lines", error false` ||
		fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_read]" {
		t.Fatalf("the answer reaches the program and nothing of the later post was written: %q %v", said, got[len(got)-1])
	}
}

// askDirectly calls CYFR's tool on the driver's socket as the stub does,
// and hands back its result once answered.
func askDirectly(s *wireSession, arguments string) chan toolsock.Result {
	answered := make(chan toolsock.Result, 1)
	go func() {
		var result toolsock.Result
		if err := toolsock.Ask(s.d.socketName, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(arguments)}, &result); err != nil {
			result = toolsock.Result{Text: "ask failed: " + err.Error()}
		}
		answered <- result
	}()
	return answered
}

// A call still held when the session closes is answered an error, and its
// connection closed.
func TestAHeldCallIsAnsweredAnErrorOnClose(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	answered := askDirectly(s, `{"path":"notes.txt"}`)
	s.expect("ask")
	s.end()
	select {
	case result := <-answered:
		if result.Text != closedSentence || !result.IsError {
			t.Fatalf("the held call is answered an error: %v", result)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the held call was never answered")
	}
}

// A call whose arguments are no object, or whose ask would pass one line
// of the wire, is answered an error at once, and no ask is shown.
func TestACallCYFRCannotShowIsAnsweredAnErrorAtOnce(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	big, _ := json.Marshal(map[string]any{"text": strings.Repeat("x", brainwire.MaxLineBytes)})
	for arguments, words := range map[string]string{
		`[1,2]`:     "CYFR takes a call's arguments as one object.",
		string(big): "This call's arguments are past what CYFR takes in one call; make it smaller.",
	} {
		select {
		case result := <-askDirectly(s, arguments):
			if result.Text != words || !result.IsError {
				t.Fatalf("the call is answered an error in the driver's words: %v", result)
			}
		case <-time.After(20 * time.Second):
			t.Fatal("the call was held")
		}
	}
	postText(s, "stp_after", "trn_1", "hello")
	if asks := ofType(s.until("idle"), "ask"); len(asks) != 0 || strings.Contains(s.output(), `"t":"ask"`) {
		t.Fatalf("no ask is shown: %v", asks)
	}
}
