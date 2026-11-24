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
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
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
	if own := ofType(got, "own"); len(own) != 0 || strings.Contains(s.output(), `"t":"own"`) {
		t.Fatalf("CYFR's call, matched to its socket call, is no own tool: %v", own)
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

// The program's own tools are `own`, by their ACP kind, or an MCP call by
// its server and tool in a fixed form, never by a title, which may carry a
// folder's path. A call is CYFR's only by the driver's own record of a
// call on its socket: one titled as CYFR's, or a person's server named
// cyfr, is shown as the program's own.
func TestOwnToolsAreOwnAndCYFRsCallsAreNot(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_own", "trn_1", "own")
	var seen []string
	for _, e := range ofType(s.until("idle"), "own") {
		seen = append(seen, e["name"].(string)+":"+e["phase"].(string))
	}
	var want []string
	for _, name := range []string{"read", "mcp:mine/reverse_text", "other", "other", "mcp:cyfr/files", "execute", "other", "other"} {
		want = append(want, name+":start", name+":end")
	}
	if !reflect.DeepEqual(seen, want) || strings.Contains(s.output(), "/home/x") || strings.Contains(s.output(), "Run m") {
		t.Fatalf("each own tool by its kind or its server and tool, none hidden by its title or its server's name: %v", seen)
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
	if records, err := os.ReadDir(filepath.Join(s.home, listingRecords)); len(records) != 0 || (err != nil && !brainwire.Absent(err)) {
		t.Fatalf("no listing is left to forget: %v %v", records, err)
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

// A steer written before a call of CYFR's reaches the socket, and confirmed
// only after: the ask is on the wire at once, before the post's answer, so
// neither waits on the other; the confirmation then comes, and the ask's
// answer reaches the program.
func TestAnAskAfterASteerIsShownBeforeTheSteersAnswer(t *testing.T) {
	t.Setenv("FAKE_CONFIRM_LATE", "1")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_first", "trn_1", "callsteer")
	s.expect("text")
	s.send(map[string]any{"t": "post", "id": "stp_steer", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "the steer"}}})
	ask := s.expect("ask")
	if e := s.expect("accepted"); e["id"] != "stp_steer" {
		t.Fatalf("the steer is confirmed after the ask: %v", e)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask["ask"], "content": "for a", "is_error": false})
	s.expect("accepted")
	got := s.until("idle")
	if saidOf(got) != `Starting. Read the steer: the steer; the tool answered "for a"` || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first stp_steer]" {
		t.Fatalf("the answer reaches the program and the turn names both posts: %v", got)
	}
}

// A steer while a call of the program's is open, before it reaches the
// socket: Antigravity answers the earlier prompt at once with the counts
// so far, which are counted, and the turn goes on with the call.
func TestASteerWhileACallIsOpenCountsTheEarlierPrompt(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_first", "trn_1", "callsteer")
	s.expect("text")
	s.send(map[string]any{"t": "post", "id": "stp_steer", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "the steer"}}})
	before := s.until("ask")
	ask := before[len(before)-1]
	usages := ofType(before, "usage")
	if accepted := ofType(before, "accepted"); len(accepted) != 1 || accepted[0]["id"] != "stp_steer" || len(usages) != 1 ||
		!reflect.DeepEqual(usages[0]["models"], []any{map[string]any{"model": "fake-neon", "counts": map[string]any{
			"input_tokens": float64(98), "output_tokens": float64(9), "cache_read_tokens": float64(3), "cache_write_tokens": float64(0)}}}) {
		t.Fatalf("the steer is accepted and the earlier prompt's counts so far are counted: %v", before)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask["ask"], "content": "for a", "is_error": false})
	s.expect("accepted")
	got := s.until("idle")
	later := ofType(got, "usage")
	if len(later) != 1 || later[0]["result"] == usages[0]["result"] || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first stp_steer]" ||
		saidOf(got) != `Starting. Read the steer: the steer; the tool answered "for a"` {
		t.Fatalf("the turn goes on to the later prompt's own counts: %v", got)
	}
}

// A forget follows no link: a folder on the way to a session's file, from
// the program's folder down, or the file itself, that is a link refuses
// the forget, and nothing is removed through it.
func TestForgetFollowsNoLink(t *testing.T) {
	session := "5f0e6c0a-0d7e-4b8e-9c1e-6b8b6f0a1d2e"
	for _, linked := range []string{".gemini", ".gemini/antigravity-cli/brain", ".gemini/antigravity-cli/annotations/" + session + ".pbtxt"} {
		t.Run(linked, func(t *testing.T) {
			s := startDriver(t)
			elsewhere := t.TempDir()
			real := filepath.Join(elsewhere, "real")
			cli := filepath.Join(s.home, ".gemini", "antigravity-cli")
			if linked == ".gemini" {
				cli = filepath.Join(real, "antigravity-cli")
			}
			for _, dir := range []string{filepath.Join(cli, "brain", session), filepath.Join(cli, agySessionDatabases), filepath.Join(cli, "annotations")} {
				_ = os.MkdirAll(dir, 0o700)
			}
			kept := []string{filepath.Join(cli, "brain", session, "transcript.jsonl"), filepath.Join(cli, agySessionDatabases, session+".db"),
				filepath.Join(cli, "annotations", session+".pbtxt")}
			for _, f := range kept {
				_ = os.WriteFile(f, []byte("FAKE"), 0o600)
			}
			target := filepath.Join(s.home, linked)
			switch linked {
			case ".gemini":
			case ".gemini/antigravity-cli/brain":
				real = filepath.Join(elsewhere, "brain")
				_ = os.Rename(filepath.Join(cli, "brain"), real)
				kept[0] = filepath.Join(real, session, "transcript.jsonl")
			default:
				real = filepath.Join(elsewhere, "secret")
				_ = os.Rename(kept[2], real)
				kept[2] = real
			}
			if err := os.Symlink(real, target); err != nil {
				t.Fatal(err)
			}
			s.expect("hello")
			s.send(map[string]any{"t": "forget", "id": "obx_1", "session": session})
			if e := s.expect("refused"); e["id"] != "obx_1" || !strings.Contains(e["reason"].(string), "link") {
				t.Fatalf("a link on the way refuses the forget: %v", e)
			}
			for _, f := range kept {
				if _, err := os.Stat(f); err != nil {
					t.Fatalf("nothing is removed through a link: %v", err)
				}
			}
		})
	}
}

// Two listings of one home keep a record each, each holding its record's
// kernel lock for its life: a listing removes its own session; another
// listing's record whose lock is held is a live listing, left alone with
// its session; an interrupted one's, its holder gone and so its lock
// released, is removed with its session.
func TestAListingRemovesOnlyItsOwnSession(t *testing.T) {
	s := startDriver(t)
	cli := filepath.Join(s.home, ".gemini", "antigravity-cli")
	made := func(id string) string {
		_ = os.MkdirAll(filepath.Join(cli, "brain", id), 0o700)
		_ = os.MkdirAll(filepath.Join(cli, agySessionDatabases), 0o700)
		db := filepath.Join(cli, agySessionDatabases, id+".db")
		_ = os.WriteFile(db, []byte("FAKE"), 0o600)
		return db
	}
	live, dead := "11111111-0d7e-4b8e-9c1e-6b8b6f0a1d2e", "22222222-0d7e-4b8e-9c1e-6b8b6f0a1d2e"
	liveDB, deadDB := made(live), made(dead)
	_ = os.MkdirAll(filepath.Join(s.home, listingRecords), 0o700)
	record := func(name, session string, hold bool) {
		f, err := os.OpenFile(filepath.Join(filepath.Join(s.home, listingRecords), name), os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
			t.Fatal(err)
		}
		_, _ = f.WriteString(session)
		if hold {
			t.Cleanup(func() { f.Close() })
			return
		}
		// Its holder ends: the kernel releases the lock.
		f.Close()
	}
	record("live-listing", live, true)
	record("dead-listing", dead, false)
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "mdl_1"})
	s.expect("models")
	if _, err := os.Stat(liveDB); err != nil {
		t.Fatalf("a live listing keeps its session: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Join(s.home, listingRecords), "live-listing")); err != nil {
		t.Fatalf("a live listing keeps its record: %v", err)
	}
	if _, err := os.Lstat(deadDB); !brainwire.Absent(err) {
		t.Fatalf("an interrupted listing's session is removed: %v", err)
	}
	records, _ := os.ReadDir(filepath.Join(s.home, listingRecords))
	databases, _ := filepath.Glob(filepath.Join(cli, agySessionDatabases, "*.db"))
	if len(records) != 1 || len(databases) != 1 {
		t.Fatalf("the listing's own session and record are gone, the live one's alone stay: %v %v", records, databases)
	}
}

// A session/new answer naming no session id CYFR can name is no sign-in:
// the start ends with its words, and a listing is refused saying nothing
// of the account.
func TestASessionWithNoIDIsNotSignedIn(t *testing.T) {
	t.Setenv("FAKE_BAD_SESSION", "1")
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "mdl_1"})
	if e := s.expect("refused"); e["id"] != "mdl_1" || e["account"] != nil {
		t.Fatalf("the listing is refused, saying nothing of the account: %v", e)
	}
	s.send(startCommand("", map[string]any{}, filesTool))
	if status := s.exit(); status != 1 || strings.Contains(s.output(), "signed_in") || !strings.Contains(s.stderr.String(), "started no session") {
		t.Fatalf("the start ends with its words: %d %q", status, s.stderr.String())
	}
}

// A listing the driver could not hand its client does not qualify the
// start: its tools did not reach the program.
func TestAListingNotHandedDoesNotStart(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GEMINI_HOME", "")
	t.Setenv(fakeEnv, "1")
	t.Setenv("FAKE_NO_LIST", "1")
	s := startDriverWith(t, antigravity, home, func(d *driver) { d.listWait = 300 * time.Millisecond })
	s.expect("hello")
	// A listing past what the socket holds, which a client that never reads
	// cannot be handed.
	big := map[string]any{"name": "big", "description": strings.Repeat("d", 900_000), "parameters": map[string]any{"type": "object"}}
	s.send(startCommand("", map[string]any{}, big))
	var conn net.Conn
	for deadline := time.Now().Add(10 * time.Second); conn == nil && time.Now().Before(deadline); {
		if c, err := net.Dial("unix", "@"+s.d.socketName); err == nil {
			conn = c
		}
	}
	if conn == nil {
		t.Fatal("the socket was never bound")
	}
	defer conn.Close()
	_, _ = conn.Write([]byte(`{"op":"list"}` + "\n"))
	if status := s.exit(); status != 1 || strings.Contains(s.output(), `"started"`) {
		t.Fatalf("the start ends without its tools reaching the program: %d %q", status, s.stderr.String())
	}
}

// A call whose kind is none the program gives a call of a stub server's is
// shown as the program's own while it runs, its start at once, its end
// when it ends: the program's own command, and a person's server named
// cyfr through the program's own call_mcp_tool.
func TestAnOwnToolIsShownWhileItRuns(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_running", "trn_1", "running")
	var seen []string
	for _, e := range s.until("idle") {
		switch e["t"] {
		case "own":
			seen = append(seen, e["name"].(string)+":"+e["phase"].(string))
		case "text":
			if e["delta"] == "running. " {
				seen = append(seen, "text")
			}
		}
	}
	want := []string{"execute:start", "mcp:cyfr/files:start", "text", "execute:end", "mcp:cyfr/files:end"}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("each own tool starts while it runs and ends when it ends: %v", seen)
	}
}

// A .cache that is a link takes nothing of the driver's elsewhere: a
// listing makes no record through it, and a forget removes no record of
// the instructions through it.
func TestALinkedCacheIsNeverFollowed(t *testing.T) {
	s := startDriver(t)
	elsewhere := t.TempDir()
	if err := os.Symlink(elsewhere, filepath.Join(s.home, ".cache")); err != nil {
		t.Fatal(err)
	}
	session := "5f0e6c0a-0d7e-4b8e-9c1e-6b8b6f0a1d2e"
	record := filepath.Join(elsewhere, "cyfr-acp", "instructions", session)
	_ = os.MkdirAll(filepath.Dir(record), 0o700)
	_ = os.WriteFile(record, []byte("kept"), 0o600)
	s.expect("hello")
	s.send(map[string]any{"t": "forget", "id": "obx_1", "session": session})
	if e := s.expect("refused"); !strings.Contains(e["reason"].(string), "link") {
		t.Fatalf("a forget through a link is refused: %v", e)
	}
	if _, err := os.Stat(record); err != nil {
		t.Fatalf("nothing is removed through the link: %v", err)
	}
	s.send(map[string]any{"t": "models", "id": "mdl_1"})
	if e := s.expect("refused"); e["id"] != "mdl_1" {
		t.Fatalf("a listing whose records would go through a link is refused: %v", e)
	}
	entries, _ := os.ReadDir(filepath.Join(elsewhere, "cyfr-acp"))
	if len(entries) != 1 || entries[0].Name() != "instructions" {
		t.Fatalf("no listing record or folder is made through the link: %v", entries)
	}
}

// A listing record that is a link is never opened: its target's session id
// is never trusted, and nothing is removed by it.
func TestALinkedListingRecordIsNeverOpened(t *testing.T) {
	s := startDriver(t)
	cli := filepath.Join(s.home, ".gemini", "antigravity-cli")
	victim := "33333333-0d7e-4b8e-9c1e-6b8b6f0a1d2e"
	_ = os.MkdirAll(filepath.Join(cli, agySessionDatabases), 0o700)
	db := filepath.Join(cli, agySessionDatabases, victim+".db")
	_ = os.WriteFile(db, []byte("FAKE"), 0o600)
	target := filepath.Join(t.TempDir(), "named")
	_ = os.WriteFile(target, []byte(victim), 0o600)
	_ = os.MkdirAll(filepath.Join(s.home, listingRecords), 0o700)
	link := filepath.Join(filepath.Join(s.home, listingRecords), "linked")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "mdl_1"})
	s.expect("models")
	if _, err := os.Stat(db); err != nil {
		t.Fatalf("no session is removed by a linked record: %v", err)
	}
	if b, err := os.ReadFile(target); err != nil || string(b) != victim {
		t.Fatalf("the link's target is left as it was: %q %v", b, err)
	}
	if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the link is left: %v %v", info, err)
	}
}

// inLoop runs f in the driver's own loop, as its socket's requests are run,
// and answers what f answers: a look at what the driver holds.
func inLoop[T any](s *wireSession, f func(d *driver) T) T {
	answered := make(chan T, 1)
	s.d.inbox <- func() error {
		answered <- f(s.d)
		return nil
	}
	return <-answered
}

// held is how many tool calls and socket calls the driver holds, and the
// decoded arguments among them.
func held(d *driver) [3]int {
	arguments := len(d.unclaimed)
	for _, call := range d.own {
		arguments += len(call.arguments)
	}
	return [3]int{len(d.own), len(d.unclaimed), arguments}
}

// What the driver holds of a turn's tool calls does not grow through it: a
// call is dropped when it ends, a call of CYFR's keeps no arguments once
// matched, and the turn's end drops the rest.
func TestNothingOfATurnsCallsIsHeldAfterThem(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_many", "trn_1", "many")
	for e := s.next(); e["t"] != "text" || e["delta"] != "calls done. "; e = s.next() {
	}
	if sizes := inLoop(s, held); sizes != [3]int{} {
		t.Fatalf("no ended call is held mid-turn: %v", sizes)
	}
	s.until("idle")
	postText(s, "stp_read", "trn_2", "read it")
	ask := s.until("ask")
	if sizes := inLoop(s, held); sizes != [3]int{1, 0, 0} {
		t.Fatalf("a matched call is held by its id alone until it ends: %v", sizes)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask[len(ask)-1]["ask"], "content": "x", "is_error": false})
	s.until("idle")
	if sizes := inLoop(s, held); sizes != [3]int{} {
		t.Fatalf("nothing is held after the turn: %v", sizes)
	}
}

// A call still open when the session closes is shown as the program's own
// before the driver ends: one shown running ends, and one of a stub
// server's kind, never matched, is shown start and end.
func TestAHeldCallIsShownAtAStop(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	postText(s, "stp_hang", "trn_1", "hang")
	var seen []string
	for e := s.next(); e["t"] != "text" || e["delta"] != "hanging. "; e = s.next() {
		if e["t"] == "own" {
			seen = append(seen, e["name"].(string)+":"+e["phase"].(string))
		}
	}
	_ = s.in.Close()
	for e := range s.events {
		if e["t"] == "own" {
			seen = append(seen, e["name"].(string)+":"+e["phase"].(string))
		}
	}
	s.exit()
	if want := []string{"execute:start", "execute:end", "other:start", "other:end"}; !reflect.DeepEqual(seen, want) {
		t.Fatalf("every call that ran is shown before the driver ends: %v", seen)
	}
}
