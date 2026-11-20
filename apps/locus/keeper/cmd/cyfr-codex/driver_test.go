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
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"golang.org/x/sys/unix"
)

const driverMainEnv = "CYFR_DRIVER_MAIN"

func TestMain(m *testing.M) {
	switch {
	case os.Getenv(fakeEnv) != "":
		os.Exit(fakeCodex())
	case os.Getenv(driverMainEnv) != "":
		os.Exit(run(os.Args[1:]))
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

// wireSession is one driver under test, speaking the wire over pipes with
// the fake app-server its harness.
type wireSession struct {
	t      *testing.T
	in     *io.PipeWriter
	events chan map[string]any
	raw    []string
	rawMu  sync.Mutex
	done   chan int
	stderr *lockedBuffer
	home   string
}

func startDriver(t *testing.T) *wireSession {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	t.Setenv(fakeEnv, "1")
	return startDriverIn(t, home)
}

func startDriverIn(t *testing.T, home string) *wireSession {
	t.Helper()
	return startDriverWith(t, home, []string{os.Args[0]})
}

// startDriverWith runs the driver with `command` its harness's.
func startDriverWith(t *testing.T, home string, command []string) *wireSession {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &wireSession{t: t, in: inW, events: make(chan map[string]any, 1024), done: make(chan int, 1), stderr: &lockedBuffer{}, home: home}
	c := brainwire.NewConn(driverName, outW, s.stderr)
	d := newDriver(command, c, home)
	stop := make(chan os.Signal)
	go func() {
		status := brainwire.Serve(c, d, inR, stop)
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
			s.t.Fatal("the driver ended")
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

// startFresh reads the driver's hello and starts a new thread with CYFR's
// files tool.
func startFresh(s *wireSession, config map[string]any) string {
	s.t.Helper()
	s.expect("hello")
	return started(s, config)
}

func started(s *wireSession, config map[string]any) string {
	s.t.Helper()
	s.send(map[string]any{"t": "start", "gen": 3, "config": config, "system": "be brief", "tools": []any{filesTool}})
	started := s.expect("started")
	if started["fresh"] != true || len(started["held"].([]any)) != 0 || !brainwire.IsUUID(started["session"].(string)) {
		s.t.Fatalf("a fresh start answers a new thread holding nothing: %v", started)
	}
	return started["session"].(string)
}

func work(s *wireSession, id, turn string) {
	s.t.Helper()
	s.send(map[string]any{"t": "work", "id": id, "work": turn, "tools": []any{filesTool}})
	if e := s.expect("accepted"); e["id"] != id {
		s.t.Fatalf("the work is accepted by its id: %v", e)
	}
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
			said = e["text"].(string)
		}
	}
	return said
}

func TestHelloFirstAndAnEmptyInputEndsIt(t *testing.T) {
	s := startDriver(t)
	hello := s.expect("hello")
	if hello["v"] != float64(brainwire.Version) || hello["driver"] != "cyfr-codex" || len(hello["boot"].(string)) != 32 {
		t.Fatalf("hello names the version, the driver and a fresh boot: %v", hello)
	}
	if status := s.end(); status != 0 {
		t.Fatalf("an input that ends ends the driver with 0: %d", status)
	}
}

func TestATurnStreamsSaysCountsAndGoesIdleNamingThePost(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{"model": "fake-opus-of-codex", "effort": "high"})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "hello")
	got := s.until("idle")
	var text string
	var usage, idle map[string]any
	for _, e := range got {
		if e["gen"] != float64(3) || e["work"] != "trn_1" {
			t.Fatalf("every event of the turn names its gen and its work: %v", e)
		}
		switch e["t"] {
		case "text":
			text += e["delta"].(string)
		case "usage":
			usage = e
		case "idle":
			idle = e
		}
	}
	want := `Hello from the fake Codex: policy never/danger-full-access, tools files, model fake-opus-of-codex, effort high, instructions "be brief"`
	if text != want || saidOf(got) != want {
		t.Fatalf("the reply streams and is said whole; the thread runs in the box's policy with the start's tools, model and prompt and the effort per turn: %q %q", text, saidOf(got))
	}
	if usage["total"] != session || usage["accounting"] != "complete" ||
		!reflect.DeepEqual(usage["models"], []any{map[string]any{"model": "fake-opus-of-codex", "counts": map[string]any{
			"input_tokens": float64(10), "output_tokens": float64(len(want) % 97), "cache_read_tokens": float64(3), "cache_write_tokens": float64(1)}}}) {
		t.Fatalf("usage is the thread's total, its counts by the wire's names, under the thread's model: %v", usage)
	}
	if idle["stop"] != "end_turn" || fmt.Sprint(idle["answered"]) != "[stp_post]" {
		t.Fatalf("idle names the post Codex named in the turn: %v", idle)
	}
	for _, canary := range []string{stderrCanary, "FAKE-ACCOUNT-CANARY", "FAKE-SIGNIN-CANARY"} {
		if strings.Contains(s.output(), canary) {
			t.Fatalf("nothing of the harness's standard error, its account or its sign-in reaches the wire: %s", canary)
		}
	}
	if !strings.Contains(s.stderr.String(), stderrCanary) {
		t.Fatal("the harness's standard error is the driver's (a positive control for the check above)")
	}
	if status := s.end(); status != 0 {
		t.Fatalf("closing the input ends driver and harness: %d", status)
	}
}

func TestAPostDuringATurnIsSteeredIntoItAndTheTurnNamesBoth(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_first", "trn_1", "slow")
	if e := s.expect("text"); e["message"] != "msg_cut" {
		t.Fatalf("the turn's first part streams: %v", e)
	}
	postText(s, "stp_second", "trn_1", "the steer")
	got := s.until("idle")
	if saidOf(got) != "Read the steer: the steer" || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_first stp_second]" {
		t.Fatalf("a post during a turn is added to it, and its idle names both posts: %v", got)
	}
}

// A post whose steer Codex refuses, since the turn it named ended, was not
// taken, and starts a turn of its own: it is written once, and accepted
// only once Codex took it.
func TestAPostWhoseSteerIsRefusedStartsATurn(t *testing.T) {
	t.Setenv("FAKE_STEER_REFUSE", "1")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_first", "trn_1", "slow")
	s.expect("text")
	postText(s, "stp_second", "trn_1", "hello")
	var idles []map[string]any
	for len(idles) < 2 {
		for _, e := range s.until("idle") {
			if e["t"] == "idle" {
				idles = append(idles, e)
			}
		}
	}
	answered := fmt.Sprint(idles[0]["answered"]) + fmt.Sprint(idles[1]["answered"])
	if answered != "[stp_first][stp_second]" && answered != "[stp_second][stp_first]" {
		t.Fatalf("each post is answered by a turn of its own: %v", idles)
	}
}

func TestAnAskIsHeldAndAnsweredByItsRequestsID(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "read it")
	var ask map[string]any
	for _, e := range s.until("ask") {
		ask = e
	}
	arguments := ask["arguments"].(map[string]any)
	if ask["name"] != "files" || ask["ask"] != "call_read" || ask["work"] != "trn_1" || arguments["path"] != "notes.txt" || len(arguments) != 3 {
		t.Fatalf("an ask names CYFR's tool, Codex's call id and the call's arguments: %v", ask)
	}
	if !strings.Contains(s.output(), `"count":12345678901234567890`) {
		t.Fatal("a call's numbers are passed on as the model wrote them")
	}
	// A work while the call is held writes nothing to Codex, so it ends
	// nothing Codex holds.
	work(s, "stp_again", "trn_1")
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": "call_read", "content": "three lines", "is_error": false})
	s.expect("accepted")
	if said := saidOf(s.until("idle")); said != `The tool answered "three lines", success true` {
		t.Fatalf("Codex reads CYFR's answer as the call's result: %q", said)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_twice", "ask": "call_read", "content": "again", "is_error": false})
	if e := s.expect("refused"); e["id"] != "stp_twice" {
		t.Fatalf("an ask is answered once: %v", e)
	}
	postText(s, "stp_post_2", "trn_1", "read it")
	s.until("ask")
	s.send(map[string]any{"t": "answer", "id": "stp_refusal", "ask": "call_read", "content": "not allowed", "is_error": true})
	s.expect("accepted")
	if said := saidOf(s.until("idle")); said != `The tool answered "not allowed", success false` {
		t.Fatalf("a refusal reaches Codex as a call CYFR did not run: %q", said)
	}
}

func TestACallOfAnotherThreadIsRefusedToCodexAndNotAsked(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "stranger")
	got := s.until("idle")
	for _, e := range got {
		if e["t"] == "ask" {
			t.Fatalf("a call of a thread not the session's is no ask: %v", e)
		}
	}
	if said := saidOf(got); said != "the stranger's call ran false" {
		t.Fatalf("Codex is told CYFR ran no such call: %q", said)
	}
}

func TestTheHarnessesOwnToolRunsInItsBoxShownByNameOnly(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "own")
	var own []string
	for _, e := range s.until("idle") {
		if e["t"] == "own" {
			own = append(own, fmt.Sprintf("%v:%v", e["name"], e["phase"]))
		}
	}
	if fmt.Sprint(own) != "[commandExecution:start commandExecution:end]" {
		t.Fatalf("an own tool is shown starting and ending by name: %v", own)
	}
	for _, words := range []string{"secret-of-the-folder", "FOLDER-CANARY"} {
		if strings.Contains(s.output(), words) {
			t.Fatalf("nothing of an own tool's command or output reaches the wire: %s", words)
		}
	}
}

func TestAFailedTurnIsTypedInTheDriversWords(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "fail")
	got := s.until("idle")
	errorsSeen := 0
	for _, e := range got {
		if e["t"] == "error" {
			errorsSeen++
			if e["type"] != "authentication" || e["message"] != errorSentence("authentication") || e["work"] != "trn_1" {
				t.Fatalf("a failed turn is its type in the driver's words: %v", e)
			}
		}
	}
	if errorsSeen != 1 || got[len(got)-1]["stop"] != "error" || strings.Contains(s.output(), "HARNESS-WORDS") {
		t.Fatalf("one error, the turn ended in error, and none of the harness's words: %v", got)
	}
}

// An account's error says the account or key Codex used was refused, never
// which, since a refused key in its environment types the same as a
// sign-in that is gone, and is worded as the Claude Code driver words it;
// a post with neither says that instead.
func TestAnAccountsErrorNamesTheSignInAndAKey(t *testing.T) {
	if errorSentence("authentication") != "The account or key OpenAI Codex used was refused; check its sign-in on the program's terminal, or a key in its settings." {
		t.Fatalf("an account's error is said in the driver's words: %q", errorSentence("authentication"))
	}
	if signedOutSentence != "OpenAI Codex has no sign-in or key it can use; sign it in on the program's terminal, or set a key in its settings." {
		t.Fatalf("a post with no sign-in and no key says so: %q", signedOutSentence)
	}
}

func TestALateTurnNamesNoWork(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "late")
	if first := s.until("idle"); first[len(first)-1]["work"] != "trn_1" {
		t.Fatalf("the post's turn names its work: %v", first)
	}
	late := s.until("idle")
	for _, e := range late {
		if _, ok := e["work"]; ok {
			t.Fatalf("a native turn no post started names no work: %v", e)
		}
	}
	if idle := late[len(late)-1]; len(idle["answered"].([]any)) != 0 || saidOf(late) != "a turn of my own" {
		t.Fatalf("a late turn answers no post: %v", late)
	}
}

// A total is the thread's as Codex gives it: one whose counts do not all
// read says so and names none, one with no total says it is unavailable,
// never zeros, and a reroute names the model the thread runs on now.
func TestUsageIsTheThreadsTotalAndUnknownStaysUnknown(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "counts")
	var usage []map[string]any
	for _, e := range s.until("idle") {
		if e["t"] == "usage" {
			usage = append(usage, e)
		}
	}
	if len(usage) != 3 {
		t.Fatalf("each total Codex sends is passed on once: %v", usage)
	}
	if usage[0]["accounting"] != "partial" || fmt.Sprint(usage[0]["models"]) != "[]" {
		t.Fatalf("a total missing a count is partial and gives no counts: %v", usage[0])
	}
	if _, named := usage[1]["models"]; usage[1]["accounting"] != "unavailable" || named {
		t.Fatalf("no total is unavailable, never zeros: %v", usage[1])
	}
	whole := usage[2]["models"].([]any)[0].(map[string]any)
	if usage[2]["accounting"] != "complete" || usage[2]["total"] != session || whole["model"] != "fake-mini" {
		t.Fatalf("a whole total names the model the thread was rerouted to: %v", usage[2])
	}
}

func TestAnotherRequestIsRefusedAnApprovalAllowedAndTheTimeAnswered(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "other")
	if said := saidOf(s.until("idle")); said != "input refused true, approval accept, time true" {
		t.Fatalf("a question for the user is refused, an approval allowed, the clock answered: %q", said)
	}
}

func TestTextPastOneLineIsCutToFit(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "big")
	if said := saidOf(s.until("idle")); !strings.HasSuffix(said, brainwire.TextCutNote) {
		t.Fatalf("a message past one line is cut with a note: %d bytes", len(said))
	}
	for _, line := range strings.Split(s.output(), "\n") {
		if len(line) > brainwire.MaxLineBytes {
			t.Fatalf("no line is past the wire's bound: %d", len(line))
		}
	}
}

// Signed out, a post is not written: it is refused in the driver's words,
// and once the person has signed in on the terminal, the next is taken.
func TestAPostWhileSignedOutIsRefusedUntilASignIn(t *testing.T) {
	t.Setenv("FAKE_SIGNED_OUT", "1")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	s.send(map[string]any{"t": "post", "id": "stp_post", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "hello"}}})
	if e := s.expect("refused"); e["reason"] != signedOutSentence {
		t.Fatalf("a post while signed out is refused, saying so: %v", e)
	}
	if err := os.WriteFile(filepath.Join(s.home, ".codex", "auth.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	postText(s, "stp_post_2", "trn_1", "hello")
	if idle := s.until("idle"); fmt.Sprint(idle[len(idle)-1]["answered"]) != "[stp_post_2]" {
		t.Fatalf("after the sign-in the post is a turn: %v", idle)
	}
}

func TestDeliveriesBeforeAStartAreRefused(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	for _, command := range []map[string]any{
		{"t": "work", "id": "w0", "work": "trn_1", "tools": []any{}},
		{"t": "post", "id": "p0", "work": "trn_1", "content": []any{}},
		{"t": "answer", "id": "a0", "ask": "call_1", "content": "", "is_error": false},
	} {
		s.send(command)
		if e := s.expect("refused"); e["id"] != command["id"] {
			t.Fatalf("a delivery before a start is refused: %v", e)
		}
	}
}

// A block Codex does not take, a PDF's, is one line of text in its place,
// an image it takes is its data URL, and the post is written with the
// rest, in its order.
func TestABlockCodexDoesNotTakeIsNamedAndThePostWritten(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	started(s, map[string]any{})
	work(s, "w1", "trn_1")
	s.send(map[string]any{"t": "post", "id": "p1", "work": "trn_1", "content": []any{
		map[string]any{"type": "document", "media_type": "application/pdf", "data": "JVBERi0="},
		map[string]any{"type": "image", "media_type": "image/png", "data": "iVBORw0KGgo="},
		map[string]any{"type": "text", "text": "echo what you were given"},
	}})
	if e := s.expect("accepted"); e["id"] != "p1" {
		t.Fatalf("the post is written: %v", e)
	}
	want, _ := json.Marshal([]any{
		map[string]any{"type": "text", "text": "A file of type application/pdf was attached; OpenAI Codex takes text and images, so it is not handed over.", "text_elements": []any{}},
		map[string]any{"type": "image", "url": "data:image/png;base64,iVBORw0KGgo="},
		map[string]any{"type": "text", "text": "echo what you were given", "text_elements": []any{}},
	})
	if said := saidOf(s.until("idle")); said != string(want) {
		t.Fatalf("Codex is given a line in the document's place, the image, then the post's text: %q", said)
	}
}

// A post's context, the thread so far, reaches Codex in the post's own
// turn, before the post's content.
func TestAPostsContextComesBeforeItsContentInOneTurn(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	s.send(map[string]any{"t": "post", "id": "stp_post", "work": "trn_1",
		"context": []any{map[string]any{"type": "text", "text": "Earlier: a post."}},
		"content": []any{map[string]any{"type": "text", "text": "echo what you were given"}}})
	if e := s.expect("accepted"); e["id"] != "stp_post" {
		t.Fatalf("the post is accepted: %v", e)
	}
	got := s.until("idle")
	want, _ := json.Marshal([]any{
		map[string]any{"type": "text", "text": "Earlier: a post.", "text_elements": []any{}},
		map[string]any{"type": "text", "text": "echo what you were given", "text_elements": []any{}},
	})
	if said := saidOf(got); said != string(want) || fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_post]" {
		t.Fatalf("the context and then the content, in the post's one turn: %q %v", said, got[len(got)-1])
	}
}

// sent posts `params` and answers what Codex read: the thread's start or
// resume and the post's turn's start.
func sent(s *wireSession, id, turn string) map[string]any {
	s.t.Helper()
	postText(s, id, turn, "params")
	var read map[string]any
	if err := json.Unmarshal([]byte(saidOf(s.until("idle"))), &read); err != nil {
		s.t.Fatal(err)
	}
	return read
}

// A start that names no model and no effort leaves both to Codex: the
// thread's start names no model, and the turn's no effort.
func TestAStartNamingNoModelOrEffortSendsNeither(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	want := map[string]any{
		"thread": map[string]any{"approvalPolicy": "never", "sandbox": "danger-full-access", "developerInstructions": "be brief",
			"dynamicTools": []any{map[string]any{"type": "function", "name": "files", "description": "Read the athanor's files", "inputSchema": map[string]any{"type": "object"}}}},
		"turn": map[string]any{"threadId": session, "clientUserMessageId": brainwire.PostUUID("stp_post"),
			"input": []any{map[string]any{"type": "text", "text": "params", "text_elements": []any{}}}},
	}
	if got := sent(s, "stp_post", "trn_1"); !reflect.DeepEqual(got, want) {
		t.Fatalf("no model and no effort are sent: %v", got)
	}
}

// Two calls of CYFR's tools Codex holds at once are two asks, and each
// answer, in whatever order, reaches Codex under its own call's request.
func TestTwoCallsHeldAtOnceAreEachAnsweredUnderTheirOwnRequest(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "pair")
	asks := []map[string]any{s.next(), s.next()}
	ask := func(call, path string) map[string]any {
		return map[string]any{"t": "ask", "gen": float64(3), "work": "trn_1", "ask": call, "name": "files", "arguments": map[string]any{"path": path}}
	}
	if want := []map[string]any{ask("call_a", "a.txt"), ask("call_b", "b.txt")}; !reflect.DeepEqual(asks, want) {
		t.Fatalf("two calls held at once are two asks: %v", asks)
	}
	for _, answer := range []map[string]any{
		{"t": "answer", "id": "stp_b", "ask": "call_b", "content": "for b", "is_error": true},
		{"t": "answer", "id": "stp_a", "ask": "call_a", "content": "for a", "is_error": false},
	} {
		s.send(answer)
		if e := s.expect("accepted"); e["id"] != answer["id"] {
			t.Fatalf("each answer is taken: %v", e)
		}
	}
	got := s.until("idle")
	if said := saidOf(got); said != `call_a answered "for a", success true; call_b answered "for b", success false` ||
		fmt.Sprint(got[len(got)-1]["answered"]) != "[stp_post]" {
		t.Fatalf("each answer reaches Codex under its own call's request, a refusal as a call not run: %q", said)
	}
}

// Two messages of one turn are each said under its own id, in the order
// Codex wrote them.
func TestTwoMessagesOfATurnAreSaidEachUnderItsOwnID(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "twice")
	var got []map[string]any
	for _, e := range s.until("idle") {
		if e["t"] == "text" || e["t"] == "said" {
			got = append(got, e)
		}
	}
	event := func(kind, message, member, value string) map[string]any {
		return map[string]any{"t": kind, "gen": float64(3), "work": "trn_1", "message": message, member: value}
	}
	want := []map[string]any{
		event("text", "msg_one", "delta", "On"), event("text", "msg_one", "delta", "e."), event("said", "msg_one", "text", "One."),
		event("text", "msg_two", "delta", "Tw"), event("text", "msg_two", "delta", "o."), event("said", "msg_two", "text", "Two."),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("each message streams and is said under its own id, in order: %v", got)
	}
}

// A line of Codex's that is no JSON, or JSON cut short, is passed over:
// the turn goes on and ends as any other.
func TestALineTheDriverCannotReadIsPassedOver(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "noise")
	got := s.until("idle")
	text := ""
	var said []string
	for _, e := range got {
		switch e["t"] {
		case "text":
			text += e["delta"].(string)
		case "said":
			said = append(said, e["text"].(string))
		}
	}
	idle := map[string]any{"t": "idle", "gen": float64(3), "work": "trn_1", "answered": []any{"stp_post"}, "stop": "end_turn"}
	if text != "still here" || !reflect.DeepEqual(said, []string{"still here"}) || !reflect.DeepEqual(got[len(got)-1], idle) {
		t.Fatalf("the turn goes on past what does not read: %q %q %v", text, said, got[len(got)-1])
	}
}

// A start Codex cannot honour ends the driver before anything starts: a
// read-only one, since Codex's read-only sandbox cannot start in the box,
// a permission mode, the harness's own tools, a tool name Codex does not
// take, its own `mcp` and `mcp__…` among them, or one named twice.
func TestAStartCodexCannotHonourEndsTheDriver(t *testing.T) {
	tool := func(name string) []any {
		return []any{map[string]any{"name": name, "description": "", "parameters": map[string]any{}}}
	}
	for name, start := range map[string]map[string]any{
		"read-only":           {"t": "start", "gen": 0, "config": map[string]any{"read_only": true}},
		"read-only resumed":   {"t": "start", "gen": 0, "session": "019a0000-0000-7000-8000-00000000aaaa", "config": map[string]any{"read_only": true}},
		"a permission mode":   {"t": "start", "gen": 0, "config": map[string]any{"permission_mode": "plan"}},
		"the harness's tools": {"t": "start", "gen": 0, "config": map[string]any{"harness_tools": []any{}}},
		"a tool name":         {"t": "start", "gen": 0, "config": map[string]any{}, "tools": tool("files.read")},
		"the name mcp":        {"t": "start", "gen": 0, "config": map[string]any{}, "tools": tool("mcp")},
		"a name under mcp__":  {"t": "start", "gen": 0, "config": map[string]any{}, "tools": tool("mcp__files")},
		"a tool named twice":  {"t": "start", "gen": 0, "config": map[string]any{}, "tools": []any{filesTool, filesTool}},
	} {
		s := startDriver(t)
		s.expect("hello")
		s.send(start)
		select {
		case status := <-s.done:
			if status != 2 {
				t.Fatalf("%s ends the driver with 2: %d", name, status)
			}
		case <-time.After(20 * time.Second):
			t.Fatalf("%s: the driver did not end", name)
		}
		if matches, _ := filepath.Glob(filepath.Join(s.home, ".codex", "sessions", "*", "*", "*", "*")); len(matches) != 0 {
			t.Fatalf("%s: no thread was started: %v", name, matches)
		}
		if strings.HasPrefix(name, "read-only") && !strings.Contains(s.stderr.String(), "cyfr-codex: Codex cannot run read-only inside CYFR, so nothing ran.\n") {
			t.Fatalf("%s: the driver says why in words a person reads: %q", name, s.stderr.String())
		}
	}
}

// A start whose read_only is false starts the thread exactly as one with
// no read_only: never asking, outside any sandbox of Codex's own.
func TestAStartWhoseReadOnlyIsFalseRunsAsBefore(t *testing.T) {
	for _, config := range []map[string]any{{}, {"read_only": false}} {
		s := startDriver(t)
		startFresh(s, config)
		work(s, "stp_work", "trn_1")
		postText(s, "stp_post", "trn_1", "hello")
		if said := saidOf(s.until("idle")); !strings.Contains(said, "policy never/danger-full-access,") {
			t.Fatalf("%v: the thread never asks and runs outside Codex's sandbox: %q", config, said)
		}
		s.end()
	}
}

func TestAResumeOfAThreadCodexHoldsNoRolloutOfIsGoneThenAFreshStartRuns(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 1, "session": "019a0000-0000-7000-8000-00000000aaaa", "config": map[string]any{}})
	s.expect("gone")
	s.send(map[string]any{"t": "start", "gen": 2, "config": map[string]any{}})
	if e := s.expect("started"); e["fresh"] != true {
		t.Fatalf("after gone, a fresh start runs in the same driver: %v", e)
	}
	s.send(map[string]any{"t": "start", "gen": 9, "config": map[string]any{}})
	if s.end() != 2 {
		t.Fatal("a second start while a harness runs breaks the protocol")
	}
}

// A thread whose rollout is empty, as a program ended before the
// thread's first turn started leaves it, cannot be resumed: it is gone,
// and a fresh start runs in the same driver.
func TestAResumeOfAThreadWhoseRolloutIsEmptyIsGoneThenAFreshStartRuns(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	s.end()
	rollouts, _ := filepath.Glob(filepath.Join(s.home, ".codex", "sessions", "*", "*", "*", "rollout-*-"+session+".jsonl"))
	if len(rollouts) != 1 {
		t.Fatalf("the thread has its rollout: %v", rollouts)
	}
	if err := os.Truncate(rollouts[0], 0); err != nil {
		t.Fatal(err)
	}

	again := startDriverIn(t, s.home)
	again.expect("hello")
	again.send(map[string]any{"t": "start", "gen": 2, "session": session, "config": map[string]any{}})
	again.expect("gone")
	again.send(map[string]any{"t": "start", "gen": 3, "config": map[string]any{}})
	if e := again.expect("started"); e["fresh"] != true || e["session"] == session {
		t.Fatalf("after gone, a fresh thread starts in the same driver: %v", e)
	}
}

// A session that is no thread id of Codex's, a lowercase uuid, has no
// transcript: it is gone, and no harness starts for it.
func TestAResumeOfASessionThatIsNoThreadIDIsGoneAndStartsNothing(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 1, "session": "019A0000-0000-7000-8000-00000000AAAA", "config": map[string]any{}})
	s.expect("gone")
	codex := filepath.Join(s.home, ".codex")
	if _, err := os.Stat(codex); !os.IsNotExist(err) || strings.Contains(s.stderr.String(), stderrCanary) {
		t.Fatalf("no harness started: %v %q", err, s.stderr.String())
	}
	started(s, map[string]any{})
	s.end()
	if _, err := os.Stat(codex); err != nil || !strings.Contains(s.stderr.String(), stderrCanary) {
		t.Fatalf("a harness that started leaves both signs (a positive control for the check above): %v %q", err, s.stderr.String())
	}
}

// A resume Codex refuses in words other than a missing rollout's is no
// proof the thread is gone: the driver ends, writes no `gone`, and the
// thread is there for the next start to resume.
func TestAResumeCodexRefusesOtherwiseEndsTheDriverAndLeavesTheThread(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "hello")
	s.until("idle")
	s.end()

	t.Setenv("FAKE_RESUME_FAIL", "1")
	refused := startDriverIn(t, s.home)
	refused.expect("hello")
	refused.send(map[string]any{"t": "start", "gen": 4, "session": session, "config": map[string]any{}})
	select {
	case e, ok := <-refused.events:
		if ok {
			t.Fatalf("a resume refused in other words writes no gone, nor anything else: %v", e)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the driver did not end")
	}
	if status := <-refused.done; status != 1 || !strings.Contains(refused.stderr.String(), "cyfr-codex: OpenAI Codex refused to start the session\n") {
		t.Fatalf("the driver ends with 1, saying why: %d %q", status, refused.stderr.String())
	}

	t.Setenv("FAKE_RESUME_FAIL", "")
	again := startDriverIn(t, s.home)
	again.expect("hello")
	again.send(map[string]any{"t": "start", "gen": 5, "session": session, "config": map[string]any{}})
	if e := again.expect("started"); e["fresh"] != false || e["session"] != session {
		t.Fatalf("the thread is left for the next start to resume: %v", e)
	}
}

// A resumed thread repeats its last total, naming the turn before it,
// which no work started in this process: its usage names no work. Then it
// repeats nothing more. It runs under the box's policy, as a new thread
// does, with the start's system prompt.
func TestAResumeNamesThePendingPostsItsRolloutHoldsAndRepeatsOnlyItsTotal(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_held", "trn_1", "hello")
	s.until("idle")
	s.end()

	again := startDriverIn(t, s.home)
	again.expect("hello")
	again.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": map[string]any{}, "system": "be brief", "pending": []any{"stp_held", "stp_never"}})
	started := again.expect("started")
	if started["fresh"] != false || started["session"] != session || fmt.Sprint(started["held"]) != "[stp_held]" {
		t.Fatalf("a resume names the posts the rollout holds, and only those: %v", started)
	}
	if e := again.expect("usage"); e["total"] != session {
		t.Fatalf("the resumed thread's total, sent again: %v", e)
	} else if _, named := e["work"]; named {
		t.Fatalf("the repeated total names no work: %v", e)
	}
	again.send(map[string]any{"t": "work", "id": "w2", "work": "trn_2", "tools": []any{}})
	if e := again.next(); e["t"] != "accepted" {
		t.Fatalf("the resumed thread repeats nothing else before its next work: %v", e)
	}
	resumed := map[string]any{"threadId": session, "approvalPolicy": "never", "sandbox": "danger-full-access", "excludeTurns": true, "developerInstructions": "be brief"}
	if got := sent(again, "stp_after", "trn_2")["thread"]; !reflect.DeepEqual(got, resumed) {
		t.Fatalf("the thread resumes under the box's policy with the start's system prompt: %v", got)
	}
}

// As #8321's seventh finding asked of the first driver: a folder past
// inspection takes nothing from what the other inspections found.
func TestAnUnreadableFolderLeavesTheHeldPostsAReadableRolloutHolds(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a folder of mode 000, so no folder here is unreadable")
	}
	t.Setenv("CODEX_HOME", "")
	home := t.TempDir()
	thread := "019a0000-0000-7000-8000-00000000bbbb"
	day := filepath.Join(home, ".codex", "sessions", "2026", "11", "18")
	line, _ := json.Marshal(map[string]any{"type": "event_msg", "payload": map[string]any{"type": "item_completed",
		"item": map[string]any{"type": "UserMessage", "client_id": brainwire.PostUUID("stp_post_1")}}})
	if err := os.MkdirAll(day, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(day, "rollout-2026-11-18T10-00-00-"+thread+".jsonl"), append(line, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	pending := []string{"stp_post_1", "stp_never"}
	if got, _ := heldPosts(home, thread, pending); fmt.Sprint(got) != "[stp_post_1]" {
		t.Fatalf("the rollout holds the post: %v", got)
	}
	other := filepath.Join(home, ".codex", "sessions", "2026", "11", "17")
	if err := os.MkdirAll(other, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(other, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(other, 0o700) })
	if got, failed := heldPosts(home, thread, pending); fmt.Sprint(got) != "[stp_post_1]" || len(failed) == 0 {
		t.Fatalf("another folder past inspection leaves the post held, and its failure is kept beside it: %v %v", got, failed)
	}
}

func TestForgetRemovesThatThreadAndNothingElse(t *testing.T) {
	s := startDriver(t)
	gone := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "hello")
	s.until("idle")
	kept := ""
	codex := filepath.Join(s.home, ".codex")
	s.end()

	s = startDriverIn(t, s.home)
	kept = startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_2")
	postText(s, "stp_post_2", "trn_2", "hello")
	s.until("idle")
	exists := func(pattern string) bool {
		matches, _ := filepath.Glob(filepath.Join(codex, pattern))
		return len(matches) > 0
	}
	if !exists("sessions/*/*/*/rollout-*-"+gone+".jsonl") || !exists("shell_snapshots/"+gone+".*") || !exists("auth.json") {
		t.Fatal("the thread's rollout, its snapshot and the sign-in are in the folder (a positive control)")
	}
	s.send(map[string]any{"t": "forget", "id": "obx_1", "session": gone})
	if e := s.expect("forgot"); e["id"] != "obx_1" || e["session"] != gone {
		t.Fatalf("a forget is answered by its id and the thread: %v", e)
	}
	if exists("sessions/*/*/*/rollout-*-"+gone+".jsonl") || exists("shell_snapshots/"+gone+".*") {
		t.Fatal("the forgotten thread's rollout and the snapshot Codex leaves are gone")
	}
	if !exists("sessions/*/*/*/rollout-*-"+kept+".jsonl") || !exists("shell_snapshots/"+kept+".*") || !exists("auth.json") {
		t.Fatal("another thread and the sign-in stay")
	}
	s.send(map[string]any{"t": "forget", "id": "obx_2", "session": gone})
	if e := s.expect("forgot"); e["id"] != "obx_2" {
		t.Fatalf("a thread Codex holds no rollout of, with nothing of it left, is proved absent: %v", e)
	}
	s.send(map[string]any{"t": "forget", "id": "obx_3", "session": "../../auth"})
	s.expect("refused")
	s.send(map[string]any{"t": "forget", "id": "obx_4", "session": kept})
	if e := s.expect("refused"); e["id"] != "obx_4" || !exists("sessions/*/*/*/rollout-*-"+kept+".jsonl") {
		t.Fatalf("the thread Codex runs is not forgotten: deleting it would end it: %v", e)
	}
}

// A removal Codex refuses, and a folder that cannot be looked into, are no
// proof the thread is gone: forget says so, and the thread is there.
func TestForgetRefusesWhatCodexWouldNotRemoveOrItCannotLookAt(t *testing.T) {
	s := startDriver(t)
	thread := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "hello")
	s.until("idle")
	s.end()
	rollouts, _ := filepath.Glob(filepath.Join(s.home, ".codex", "sessions", "*", "*", "*", "rollout-*-"+thread+".jsonl"))
	if len(rollouts) != 1 {
		t.Fatalf("one rollout: %v", rollouts)
	}

	t.Setenv("FAKE_DELETE_FAIL", "1")
	s = startDriverIn(t, s.home)
	s.expect("hello")
	s.send(map[string]any{"t": "forget", "id": "obx_1", "session": thread})
	if e := s.expect("refused"); e["id"] != "obx_1" {
		t.Fatalf("a removal Codex refuses is refused: %v", e)
	}
	if _, err := os.Stat(rollouts[0]); err != nil {
		t.Fatalf("the rollout is still there: %v", err)
	}
	s.end()

	if os.Geteuid() == 0 {
		t.Skip("root reads a folder of mode 000, so no folder here is unreadable")
	}
	t.Setenv("FAKE_DELETE_FAIL", "")
	other := filepath.Join(s.home, ".codex", "sessions", "2026", "11", "17")
	if err := os.MkdirAll(other, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(other, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(other, 0o700) })
	s = startDriverIn(t, s.home)
	s.expect("hello")
	s.send(map[string]any{"t": "forget", "id": "obx_2", "session": thread})
	if e := s.expect("refused"); e["id"] != "obx_2" {
		t.Fatalf("a folder that cannot be read is no proof the thread is gone: %v", e)
	}
	if err := os.Chmod(other, 0o700); err != nil {
		t.Fatal(err)
	}
	s.send(map[string]any{"t": "forget", "id": "obx_3", "session": thread})
	s.expect("forgot")
}

func TestTheHarnessesEndEndsTheDriver(t *testing.T) {
	t.Setenv("FAKE_EXIT_ON", "die")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	s.send(map[string]any{"t": "post", "id": "stp_post", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "die now"}}})
	select {
	case status := <-s.done:
		if status != 3 {
			t.Fatalf("the driver ends with the harness's status: %d", status)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the driver outlived its harness")
	}
	if strings.Contains(s.output(), `"accepted"`+`,"id":"stp_post"`) {
		t.Fatal("a post whose turn Codex never answered is not accepted")
	}
}

func TestACommandTheWireDoesNotReadEndsTheDriver(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	if _, err := s.in.Write([]byte(`{"t":"start","gen":0,"config":{"sandbox":"danger-full-access"}}` + "\n")); err != nil {
		t.Fatal(err)
	}
	if status := <-s.done; status != 2 {
		t.Fatalf("an unreadable command ends the driver with 2: %d", status)
	}
}

func TestModelsAreListedWithOrWithoutAStart(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "m1"})
	listed := s.expect("models")
	if fmt.Sprint(listed["models"]) != "[map[id:fake-sol name:Fake Sol] map[id:fake-mini name:Fake Mini]]" ||
		fmt.Sprint(listed["efforts"]) != "[low high medium]" {
		t.Fatalf("every page of Codex's listing, with the efforts any model takes: %v", listed)
	}
	started(s, map[string]any{})
	s.send(map[string]any{"t": "models", "id": "m2"})
	if again := s.expect("models"); fmt.Sprint(again["models"]) != fmt.Sprint(listed["models"]) {
		t.Fatalf("a running app-server lists the same: %v", again)
	}
}

func openPTY(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Skipf("no pseudo-terminal here: %v", err)
	}
	if err := unix.IoctlSetPointerInt(int(master.Fd()), unix.TIOCSPTLCK, 0); err != nil {
		t.Fatal(err)
	}
	n, err := unix.IoctlGetInt(int(master.Fd()), unix.TIOCGPTN)
	if err != nil {
		t.Fatal(err)
	}
	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { master.Close(); slave.Close() })
	return master, slave
}

func TestOnATerminalTheHarnessRunsUnchanged(t *testing.T) {
	_, slave := openPTY(t)
	echo, err := exec.LookPath("echo")
	if err != nil {
		t.Skip("no echo here")
	}
	run := func(stdin *os.File) string {
		cmd := exec.Command(os.Args[0], echo, "login", "--device-auth")
		cmd.Env = append(os.Environ(), driverMainEnv+"=1")
		cmd.Stdin = stdin
		var out bytes.Buffer
		cmd.Stdout = &out
		if err := cmd.Run(); err != nil {
			t.Fatal(err)
		}
		return out.String()
	}
	if got := run(slave); got != "login --device-auth\n" {
		t.Fatalf("on a terminal the harness's command runs as given: %q", got)
	}
	null, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer null.Close()
	if got := run(null); !strings.HasPrefix(got, `{"t":"hello"`) {
		t.Fatalf("off a terminal it speaks the wire (a positive control): %q", got)
	}
}

// A harness that does not start says why on the driver's standard error
// alone: its command's path may name the folder, and the refusal of a
// listing or a removal, and the start's end, carry none of it to the wire.
func TestALaunchThatFailsNamesNoFolderOnTheWire(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	s := startDriverWith(t, home, []string{filepath.Join(home, "FOLDER-CANARY", "no-such-codex")})
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "m1"})
	if e := s.expect("refused"); e["id"] != "m1" || e["reason"] != "OpenAI Codex did not list its models: it did not start." {
		t.Fatalf("a listing whose app-server did not start is refused in the driver's words: %v", e)
	}
	s.send(map[string]any{"t": "forget", "id": "obx_1", "session": "019a0000-0000-7000-8000-000000000001"})
	if e := s.expect("refused"); e["id"] != "obx_1" || e["reason"] != "OpenAI Codex could not be asked to remove the session's thread: it did not start." {
		t.Fatalf("a removal whose app-server did not start is refused in the driver's words: %v", e)
	}
	s.send(map[string]any{"t": "start", "gen": 1, "config": map[string]any{}})
	if status := s.end(); status != 1 {
		t.Fatalf("a start whose harness did not start ends the driver: %d", status)
	}
	if strings.Contains(s.output(), "FOLDER-CANARY") {
		t.Fatalf("nothing of the harness's command reaches the wire: %s", s.output())
	}
	if n := strings.Count(s.stderr.String(), "FOLDER-CANARY/no-such-"); n != 6 {
		t.Fatalf("each launch's detail, the command and the system's words on it, is on the driver's standard error (a positive control for the check above): %d in %q", n, s.stderr.String())
	}
}

// Whether a thread's total holds its sub-agents' counts is not established:
// from the first sign of a sub-agent, a line of another thread's or the
// session's own call of one, the session's usage is partial, its total's
// counts carried all the same, for as long as the session runs.
func TestUsageIsPartialOnceASubAgentWorks(t *testing.T) {
	for _, sign := range []string{"child", "agent"} {
		t.Run(sign, func(t *testing.T) {
			s := startDriver(t)
			session := startFresh(s, map[string]any{})
			work(s, "stp_work", "trn_1")
			turn := func(id, words string) []string {
				postText(s, id, "trn_1", words)
				var accountings []string
				for _, e := range s.until("idle") {
					if e["t"] != "usage" {
						continue
					}
					if e["total"] != session || len(e["models"].([]any)) != 1 {
						t.Fatalf("the session's usage is its own thread's total, its counts carried: %v", e)
					}
					accountings = append(accountings, fmt.Sprint(e["accounting"]))
				}
				return accountings
			}
			if got := turn("stp_first", "hello"); fmt.Sprint(got) != "[complete]" {
				t.Fatalf("before any sub-agent the total is complete: %v", got)
			}
			if got := turn("stp_second", sign); fmt.Sprint(got) != "[partial]" {
				t.Fatalf("a sub-agent's work makes the session's total partial: %v", got)
			}
			if got := turn("stp_third", "hello"); fmt.Sprint(got) != "[partial]" {
				t.Fatalf("and it stays partial while the session runs: %v", got)
			}
			if strings.Contains(s.output(), "c41d") {
				t.Fatal("nothing of the sub-agent's thread reaches the wire")
			}
		})
	}
}

// A resumed thread's first total is partial: it may end a stretch a
// sub-agent worked in whose total's event never committed, and nothing the
// driver saw outlives its process. That first total is the one a resume
// repeats, naming no work, or, when Codex repeats none, the first new one;
// the totals after it are complete again while no sub-agent works.
func TestTheFirstTotalAfterAResumeIsPartial(t *testing.T) {
	for _, repeated := range []bool{true, false} {
		t.Run(map[bool]string{true: "repeated", false: "new"}[repeated], func(t *testing.T) {
			s := startDriver(t)
			session := startFresh(s, map[string]any{})
			work(s, "stp_work", "trn_1")
			postText(s, "stp_first", "trn_1", "child")
			s.until("idle")
			s.end()
			if !repeated {
				t.Setenv("FAKE_NO_REPEAT", "1")
			}
			again := startDriverIn(t, s.home)
			again.expect("hello")
			again.send(map[string]any{"t": "start", "gen": 4, "session": session, "config": map[string]any{}})
			if e := again.expect("started"); e["fresh"] != false || e["session"] != session {
				t.Fatalf("the thread resumes: %v", e)
			}
			var got []string
			if repeated {
				e := again.expect("usage")
				if _, named := e["work"]; named || e["total"] != session {
					t.Fatalf("the repeated total is the thread's and names no work: %v", e)
				}
				got = append(got, fmt.Sprint(e["accounting"]))
			}
			work(again, "stp_work_2", "trn_2")
			for _, id := range []string{"stp_second", "stp_third"} {
				postText(again, id, "trn_2", "hello")
				for _, e := range again.until("idle") {
					if e["t"] == "usage" {
						got = append(got, fmt.Sprint(e["accounting"]))
					}
				}
			}
			want := map[bool]string{true: "[partial complete complete]", false: "[partial complete]"}[repeated]
			if fmt.Sprint(got) != want {
				t.Fatalf("a resumed thread's first total is partial, the rest complete: %v, want %s", got, want)
			}
		})
	}
}

// The resumed thread's first usable total, one that carries counts, is the
// partial one: a usage before it that carries none, no total or a total
// missing a count, leaves the next total partial.
func TestAnUnreadableTotalLeavesTheResumedThreadsFirstUsableOnePartial(t *testing.T) {
	for _, first := range []string{"none", "missing"} {
		t.Run(first, func(t *testing.T) {
			s := startDriver(t)
			session := startFresh(s, map[string]any{})
			work(s, "stp_work", "trn_1")
			postText(s, "stp_first", "trn_1", "hello")
			s.until("idle")
			s.end()
			t.Setenv("FAKE_NO_REPEAT", "1")
			again := startDriverIn(t, s.home)
			again.expect("hello")
			again.send(map[string]any{"t": "start", "gen": 4, "session": session, "config": map[string]any{}})
			again.expect("started")
			work(again, "stp_work_2", "trn_2")
			accountings := func(id, words string) string {
				postText(again, id, "trn_2", words)
				var got []string
				for _, e := range again.until("idle") {
					if e["t"] == "usage" {
						models, _ := e["models"].([]any)
						got = append(got, fmt.Sprintf("%v/%d", e["accounting"], len(models)))
					}
				}
				return fmt.Sprint(got)
			}
			want := map[string]string{"none": "[unavailable/0 partial/1]", "missing": "[partial/0 partial/1]"}[first]
			if got := accountings("stp_second", first); got != want {
				t.Fatalf("a total with no counts leaves the first usable one partial: %s, want %s", got, want)
			}
			if got := accountings("stp_third", "hello"); got != "[complete/1]" {
				t.Fatalf("the totals after the first usable one are complete: %s", got)
			}
		})
	}
}
