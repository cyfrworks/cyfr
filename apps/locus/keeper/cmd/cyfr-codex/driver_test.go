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
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

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
	// No test sees the host's packs: a test that plants some sets its own.
	brainwire.PacksRoot = "/nonexistent/cyfr/scrolls"
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

// why is what the driver's ending, its last line, tells the holder.
func (s *wireSession) why() any {
	s.t.Helper()
	got := s.until("ending")
	return got[len(got)-1]["why"]
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

func ofType(events []map[string]any, t string) []map[string]any {
	var out []map[string]any
	for _, e := range events {
		if e["t"] == t {
			out = append(out, e)
		}
	}
	return out
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

// A steer Codex answers with an error other than a refusal of the request
// (-32600: "no active turn to steer", "expected active turn id … but
// found …", "thread not found: …" and a malformed input, as Codex 0.169.0
// answers each, measured) may have been taken: the post is refused
// as of a delivery not known, and is never written again as a turn of its
// own, so nothing is said twice.
func TestAPostWhoseSteerMayHaveBeenTakenIsNeverWrittenAgain(t *testing.T) {
	t.Setenv("FAKE_STEER_UNKNOWN", "1")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_first", "trn_1", "slow")
	s.expect("text")
	s.send(map[string]any{"t": "post", "id": "stp_second", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "hello"}}})
	var refused map[string]any
	for e := s.next(); e["t"] != "idle"; e = s.next() {
		if e["t"] == "refused" {
			refused = e
		}
		if e["t"] == "accepted" {
			t.Fatalf("a post whose delivery is not known is not accepted: %v", e)
		}
	}
	if refused["id"] != "stp_second" || refused["reason"] != steerUnknownSentence {
		t.Fatalf("the post is refused as of a delivery not known: %v", refused)
	}
	if strings.Contains(s.output(), "Hello from the fake") {
		t.Fatal("the post was written again as a turn of its own")
	}
}

// A usage limit's error says when it lifts, by the reset of the limit
// Codex reported reached (`account/rateLimits/updated`, which names no
// thread, before the failed turn, as 0.169.0 sent it), in UTC; a limit
// not reached names no time.
func TestAUsageLimitSaysWhenItLifts(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "limited")
	var errs []map[string]any
	for e := s.next(); e["t"] != "idle"; e = s.next() {
		if e["t"] == "error" {
			errs = append(errs, e)
		}
	}
	want := "OpenAI Codex reported a usage or rate limit; it lifts at 11:16 UTC on 24 November 2026."
	if len(errs) != 1 || errs[0]["type"] != "rate_limited" || errs[0]["message"] != want {
		t.Fatalf("one error, a rate limit's, saying when it lifts: %v", errs)
	}
}

// A close during a native turn asks Codex to stop it in its own way,
// `turn/interrupt` naming the turn, before its input closes, so its
// rollout keeps the turn as interrupted (0.169.0 answers one at once and
// ends the turn so, measured).
func TestACloseDuringATurnInterruptsItFirst(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_first", "trn_1", "slow")
	s.expect("text")
	s.end()
	rollouts, _ := filepath.Glob(filepath.Join(s.home, ".codex", "sessions", "*", "*", "*", "rollout-*-"+session+".jsonl"))
	if len(rollouts) != 1 {
		t.Fatalf("the thread has its rollout: %v", rollouts)
	}
	kept, _ := os.ReadFile(rollouts[0])
	if !regexp.MustCompile(`\{"turnId":"[^"]+","type":"fake_interrupted"\}`).Match(kept) {
		t.Fatalf("the close asked Codex to interrupt the turn under way: %s", kept)
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

// Wire version 8's activity: each own tool's start and end carry one
// call, the harness's item id, two commands ending in reverse order each
// ending under its own; a start says what it runs and a patch's end its
// diff, cut between characters to a detail's bound; the reasoning summary
// is thought and never said; and a sub-agent's thread, its words,
// reasoning and command, emits nothing while the session's call of it
// starts and ends.
func TestCodexsActivityIsItsCallsThoughtsAndOwnWords(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	postText(s, "stp_post", "trn_1", "activity")
	got := s.until("idle")
	var seen []string
	details := map[string]any{}
	for _, e := range ofType(got, "own") {
		seen = append(seen, fmt.Sprintf("%v:%v:%v", e["call"], e["name"], e["phase"]))
		details[fmt.Sprintf("%v:%v", e["call"], e["phase"])] = e["detail"]
	}
	want := []string{"cmd_a:commandExecution:start", "cmd_b:commandExecution:start", "cmd_b:commandExecution:end", "cmd_a:commandExecution:end",
		"patch_1:fileChange:start", "patch_1:fileChange:end", "collab_act:collabAgentToolCall:start", "collab_act:collabAgentToolCall:end"}
	if !reflect.DeepEqual(seen, want) {
		t.Fatalf("each own tool starts and ends under its item's id, the commands in the order they ended: %v", seen)
	}
	// The path leaves the bound inside a character of the diff.
	whole := "big.md\n" + strings.Repeat("€", 1000)
	change, _ := details["patch_1:end"].(string)
	if details["cmd_a:start"] != "echo A" || details["cmd_b:start"] != "echo B" || details["patch_1:start"] != "big.md" ||
		details["cmd_a:end"] != nil || len(change) > brainwire.MaxDetailBytes || len(change) < brainwire.MaxDetailBytes-3 ||
		!utf8.ValidString(change) || !strings.HasPrefix(whole, change) {
		t.Fatalf("a start says what it runs, and a patch's end its diff, cut between characters to the bound: %v", details)
	}
	thought := ""
	for _, e := range ofType(got, "thought") {
		thought += e["delta"].(string)
	}
	if thought != "THINK-ONE THINK-TWO" || strings.Contains(fmt.Sprint(ofType(got, "said"), ofType(got, "text")), "THINK") {
		t.Fatalf("the reasoning summary arrives as thought and is never said: %q", thought)
	}
	for _, canary := range []string{"CHILD-THOUGHT", "CHILD-RAN", "CHILD-WORDS", "c41d", "OUTPUT-CANARY"} {
		if strings.Contains(s.output(), canary) {
			t.Fatalf("nothing of the sub-agent's thread, nor a command's output, reaches the wire: %s", canary)
		}
	}
	if said := saidOf(got); said != "The member said its own words." {
		t.Fatalf("the reply holds only the member's own words: %q", said)
	}
}

// The stand-in reasons as Codex 0.169.0 did on the walk at effort high: a
// turn whose thread was never asked for a summary has a reasoning item
// with an empty summary and no summary text, and one asked `summary`
// "auto" streams it. Spoken to directly, since the driver always asks.
func TestTheStandInGivesNoReasoningSummaryUnlessAskedForOne(t *testing.T) {
	deltas := func(summary string) (string, []any) {
		t.Setenv("HOME", t.TempDir())
		t.Setenv("CODEX_HOME", "")
		t.Setenv(fakeEnv, "1")
		cmd := exec.Command(os.Args[0], appServer)
		in, _ := cmd.StdinPipe()
		out, _ := cmd.StdoutPipe()
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
		lines := bufio.NewScanner(out)
		lines.Buffer(make([]byte, 64<<10), 4<<20)
		answer := func(id string) map[string]any {
			for lines.Scan() {
				var m map[string]any
				if json.Unmarshal(lines.Bytes(), &m) == nil && m["id"] == id {
					return m
				}
			}
			t.Fatalf("no answer to %s", id)
			return nil
		}
		_, _ = in.Write(append(initializeLine("1"), '\n'))
		answer("1")
		_, _ = in.Write(append(threadStart("2", "", nil, brainwire.Config{}, accessChoices[0].Native), '\n'))
		thread := answer("2")["result"].(map[string]any)["thread"].(map[string]any)["id"].(string)
		params := map[string]any{"threadId": thread, "input": []any{map[string]any{"type": "text", "text": "activity"}}}
		if summary != "" {
			params["summary"] = summary
		}
		_, _ = in.Write(append(request("3", "turn/start", params), '\n'))
		text := ""
		var completed []any
		for lines.Scan() {
			var m struct {
				Method string `json:"method"`
				Params struct {
					ThreadID string `json:"threadId"`
					Delta    string `json:"delta"`
					Item     struct {
						Type    string `json:"type"`
						Summary []any  `json:"summary"`
					} `json:"item"`
				} `json:"params"`
			}
			_ = json.Unmarshal(lines.Bytes(), &m)
			switch {
			case m.Method == "item/reasoning/summaryTextDelta" && m.Params.ThreadID == thread:
				text += m.Params.Delta
			case m.Method == "item/completed" && m.Params.Item.Type == "reasoning":
				completed = m.Params.Item.Summary
			case m.Method == "turn/completed":
				return text, completed
			}
		}
		t.Fatal("the turn never completed")
		return "", nil
	}
	if text, summary := deltas(""); text != "" || len(summary) != 0 {
		t.Fatalf("a thread never asked for a summary reasons with none: %q %v", text, summary)
	}
	if text, summary := deltas("auto"); text != "THINK-ONE THINK-TWO" || len(summary) != 1 {
		t.Fatalf("a turn asked for a summary streams it: %q %v", text, summary)
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
	if !strings.Contains(s.output(), `"detail":"/bin/bash -lc 'cat secret-of-the-folder'"`) || strings.Contains(s.output(), "FOLDER-CANARY") {
		t.Fatalf("an own tool's start says what it runs, and nothing of its output reaches the wire: %s", s.output())
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
	if signedOutSentence != "OpenAI Codex has no sign-in it can use; sign it in on the program's terminal, with your plan or a key." {
		t.Fatalf("a post with no sign-in says how to sign in, a key in the environment not being one: %q", signedOutSentence)
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
	if e := s.expect("refused"); e["reason"] != signedOutSentence || e["account"] != "signed_out" {
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

// What a start, and a listing with no app-server running, say of the
// account is what Codex's own answer positively says; an answer it does
// not know and a read that failed say nothing, and list.
func TestTheAccountIsSaidOnlyWhereCodexSaysIt(t *testing.T) {
	for _, c := range []struct {
		account string
		says    any
	}{
		{`{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}`, "signed_in"},
		{`{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}`, "signed_in"},
		{`{"account":{"type":"amazonBedrock"},"requiresOpenaiAuth":false}`, "signed_in"},
		{`{"account":{"type":"gcp"},"requiresOpenaiAuth":false}`, "signed_in"},
		{`{"account":false,"requiresOpenaiAuth":true}`, nil},
		{`{"account":"","requiresOpenaiAuth":true}`, nil},
		{`{"account":[],"requiresOpenaiAuth":true}`, nil},
		{`{"account":{},"requiresOpenaiAuth":true}`, nil},
		{`{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}`, nil},
		{`{"account":{"type":"another"},"requiresOpenaiAuth":true}`, nil},
		{`{"account":{"type":"apiKey"}}`, nil},
		{`{"account":{"type":"apiKey"},"requiresOpenaiAuth":"yes"}`, nil},
		{`{"account":{"Type":"apiKey"},"requiresOpenaiAuth":true}`, nil},
		{`{"Account":null,"requiresOpenaiAuth":true}`, nil},
		{`{"requiresOpenaiAuth":false}`, nil},
		{`{"account":null,"requiresOpenaiAuth":false}`, "signed_in"},
		{`{"account":null,"requiresOpenaiAuth":true}`, "signed_out"},
		{`{"account":null}`, nil},
		{`{"requiresOpenaiAuth":true}`, nil},
	} {
		t.Run(c.account, func(t *testing.T) {
			t.Setenv("FAKE_ACCOUNT", c.account)
			s := startDriver(t)
			s.expect("hello")
			s.send(map[string]any{"t": "models", "id": "m1"})
			if got := s.next(); got["account"] != c.says || (got["t"] == "refused") != (c.says == "signed_out") {
				t.Fatalf("a listing says %v of the account, refused only signed out: %v", c.says, got)
			}
			s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{}})
			if got := s.expect("started"); got["account"] != c.says {
				t.Fatalf("a start says %v of the account: %v", c.says, got)
			}
			s.send(map[string]any{"t": "models", "id": "m2"})
			if got := s.expect("models"); got["account"] != nil {
				t.Fatalf("a listing that read no account says none: %v", got)
			}
		})
	}
}

// A listing whose account read failed is refused as that, so the editor
// says it: no list, no sign-out, and nothing said of the account.
func TestAListingWhoseAccountCouldNotBeReadSaysSo(t *testing.T) {
	t.Setenv("FAKE_ACCOUNT", "fail")
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "m1"})
	const unread = "OpenAI Codex did not list its models: its account could not be read."
	if e := s.expect("refused"); e["id"] != "m1" || e["reason"] != unread || e["account"] != nil {
		t.Fatalf("a failed account read is said as that: %v", e)
	}
	s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{}})
	if e := s.expect("started"); e["account"] != nil {
		t.Fatalf("a start whose account read failed says none: %v", e)
	}
}

// A post whose account read failed, or answered a shape not known, is
// refused as each of those: never as signed out, and saying nothing of the
// account.
func TestAnAccountThatCannotBeReadIsNoSignOut(t *testing.T) {
	const unknown = "OpenAI Codex's account answer is not one CYFR knows, so the post was not written; check its sign-in on the program's terminal."
	for account, reason := range map[string]string{
		`fail`:                        "OpenAI Codex's account could not be read, so the post was not written; send it again.",
		`{"account":null}`:            unknown,
		`{"requiresOpenaiAuth":true}`: unknown,
		`{"account":false,"requiresOpenaiAuth":true}`: unknown,
	} {
		t.Run(account, func(t *testing.T) {
			t.Setenv("FAKE_ACCOUNT", account)
			s := startDriver(t)
			startFresh(s, map[string]any{})
			work(s, "stp_work", "trn_1")
			s.send(map[string]any{"t": "post", "id": "stp_post", "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": "hello"}}})
			if e := s.expect("refused"); e["reason"] != reason || e["account"] != nil {
				t.Fatalf("an account that could not be read is said as that, and as no sign-out: %v", e)
			}
		})
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
// thread's start names no model, and the turn's no effort. Every turn asks
// for the reasoning's summary, which Codex otherwise leaves off.
func TestAStartNamingNoModelOrEffortSendsNeither(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_1")
	want := map[string]any{
		"thread": map[string]any{"approvalPolicy": "never", "sandbox": "danger-full-access", "developerInstructions": "be brief",
			"dynamicTools": []any{map[string]any{"type": "function", "name": "files", "description": "Read the athanor's files", "inputSchema": map[string]any{"type": "object"}}}},
		"turn": map[string]any{"threadId": session, "clientUserMessageId": brainwire.PostUUID("stp_post"), "summary": "auto",
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

// A start Codex cannot honour ends the driver before anything starts: the
// harness's own tools, a tool name Codex does not take, its own `mcp` and
// `mcp__…` among them, or one named twice.
func TestAStartCodexCannotHonourEndsTheDriver(t *testing.T) {
	tool := func(name string) []any {
		return []any{map[string]any{"name": name, "description": "", "parameters": map[string]any{}}}
	}
	for name, start := range map[string]map[string]any{
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
	}
}

// A start naming an access the driver does not list, fresh or resuming,
// ends it with 2 before it starts any app-server, writing only its
// ending, `unfit`, and saying why on its standard error. The harness's command names nothing
// here, so a start of it would say it did not start, as the listed
// access's does.
func TestAStartNamingAnAccessCodexDoesNotListEndsTheDriver(t *testing.T) {
	for name, start := range map[string]map[string]any{
		"an empty access":        {"t": "start", "gen": 0, "config": map[string]any{"access": ""}},
		"another sandbox":        {"t": "start", "gen": 0, "config": map[string]any{"access": "workspace-write"}},
		"another driver's":       {"t": "start", "gen": 0, "config": map[string]any{"access": "default"}},
		"a resume of another":    {"t": "start", "gen": 0, "session": "019a0000-0000-7000-8000-00000000aaaa", "config": map[string]any{"access": "default"}},
		"a case it does not use": {"t": "start", "gen": 0, "config": map[string]any{"access": "Full-Access"}},
	} {
		s := startDriverWith(t, t.TempDir(), []string{filepath.Join(t.TempDir(), "no-such-harness")})
		s.expect("hello")
		s.send(start)
		if status := s.end(); status != 2 {
			t.Fatalf("%s: the driver ends with 2: %d", name, status)
		}
		var after []map[string]any
		for e := range s.events {
			after = append(after, e)
		}
		if len(after) != 1 || after[0]["t"] != "ending" || after[0]["why"] != "unfit" {
			t.Fatalf("%s: the driver writes only its ending, unfit, after its hello: %v", name, after)
		}
		if got := s.stderr.String(); got != "cyfr-codex: "+unlistedAccess+"\n" {
			t.Fatalf("%s: the driver says why, and starts nothing: %q", name, got)
		}
	}
	s := startDriverWith(t, t.TempDir(), []string{filepath.Join(t.TempDir(), "no-such-harness")})
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{"access": "full-access"}})
	if status := s.end(); status != 1 || !strings.Contains(s.stderr.String(), "cyfr-codex: the harness did not start") ||
		s.why() != "unrunnable" {
		t.Fatalf("the listed access starts the harness (a positive control): %d %q", status, s.stderr.String())
	}
}

// A start runs its thread in the access it names, or in the first the
// driver lists when it names none, a resume as a fresh start: Codex's own
// sandbox off and asking for nothing.
func TestAStartRunsItsThreadInItsAccess(t *testing.T) {
	t.Setenv("FAKE_NO_REPEAT", "1")
	for name, config := range map[string]map[string]any{
		"absent":      {},
		"full access": {"access": "full-access"},
	} {
		s := startDriver(t)
		session := startFresh(s, config)
		work(s, "stp_work", "trn_1")
		thread := sent(s, "stp_post", "trn_1")["thread"].(map[string]any)
		if thread["sandbox"] != "danger-full-access" || thread["approvalPolicy"] != "never" {
			t.Fatalf("%s: the thread starts outside Codex's sandbox, never asking: %v", name, thread)
		}
		s.end()

		again := startDriverIn(t, s.home)
		again.expect("hello")
		again.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": config, "system": "be brief"})
		again.expect("started")
		work(again, "stp_work_2", "trn_2")
		resumed := sent(again, "stp_post_2", "trn_2")["thread"].(map[string]any)
		if resumed["threadId"] != session || resumed["sandbox"] != "danger-full-access" || resumed["approvalPolicy"] != "never" {
			t.Fatalf("%s: the thread resumes outside Codex's sandbox, never asking: %v", name, resumed)
		}
		again.end()
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
// proof the thread is gone: the driver ends, writes no `gone`, only its
// ending, `refused`, and the thread is there for the next start to resume.
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
	ending := refused.expect("ending")
	if ending["why"] != "refused" {
		t.Fatalf("a resume refused in other words ends saying refused: %v", ending)
	}
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
	if !exists("sessions/*/*/*/rollout-*-"+gone+".jsonl") || !exists("shell_snapshots/"+gone+".*") || !exists("cyfr-instructions/"+gone) || !exists("auth.json") {
		t.Fatal("the thread's rollout, its snapshot, the record of its instructions and the sign-in are in the folder (a positive control)")
	}
	s.send(map[string]any{"t": "forget", "id": "obx_1", "session": gone})
	if e := s.expect("forgot"); e["id"] != "obx_1" || e["session"] != gone {
		t.Fatalf("a forget is answered by its id and the thread: %v", e)
	}
	if exists("sessions/*/*/*/rollout-*-"+gone+".jsonl") || exists("shell_snapshots/"+gone+".*") || exists("cyfr-instructions/"+gone) {
		t.Fatal("the forgotten thread's rollout, the snapshot Codex leaves and the record of its instructions are gone")
	}
	if !exists("sessions/*/*/*/rollout-*-"+kept+".jsonl") || !exists("shell_snapshots/"+kept+".*") || !exists("cyfr-instructions/"+kept) || !exists("auth.json") {
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
	want := []any{
		map[string]any{"id": "fake-sol", "name": "Fake Sol", "efforts": []any{"low", "high"}},
		map[string]any{"id": "fake-mini", "name": "Fake Mini", "efforts": []any{"medium", "high"}},
	}
	if _, flat := listed["efforts"]; flat || !reflect.DeepEqual(listed["models"], want) {
		t.Fatalf("every page of Codex's listing, each model with the efforts it takes and no other's: %v", listed)
	}
	access := []any{map[string]any{"id": "full-access", "name": "Full access, no approvals"}}
	if !reflect.DeepEqual(listed["access"], access) {
		t.Fatalf("the listing's access is the one choice the driver honours: %v", listed["access"])
	}
	started(s, map[string]any{})
	s.send(map[string]any{"t": "models", "id": "m2"})
	if again := s.expect("models"); fmt.Sprint(again["models"]) != fmt.Sprint(listed["models"]) || !reflect.DeepEqual(again["access"], access) {
		t.Fatalf("a running app-server lists the same: %v", again)
	}
}

// A listing with no app-server running reads Codex's account first: the
// one shape Codex answers with no sign-in refuses it in the signed-out
// sentence, and any other answer lists.
func TestAListingOfCodexWithNoSignInIsRefused(t *testing.T) {
	t.Setenv("FAKE_SIGNED_OUT", "1")
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "m1"})
	if refused := s.expect("refused"); refused["id"] != "m1" || refused["reason"] != signedOutSentence {
		t.Fatalf("Codex with no sign-in has its listing refused in the signed-out sentence: %v", refused)
	}

	for result, out := range map[string]bool{
		`{"account":null,"requiresOpenaiAuth":true}`:               true,
		`{"account":null,"requiresOpenaiAuth":false}`:              false,
		`{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}`: false,
		`{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}`:  false,
		`{"requiresOpenaiAuth":true}`:                              false,
		`{"account":null}`:                                         false,
		`{"account":null,"requiresOpenaiAuth":"yes"}`:              false,
	} {
		if (accountOf(rpc{Result: json.RawMessage(result)}) == brainwire.SignedOut) != out {
			t.Errorf("accountOf(%s) signed out is %v", result, !out)
		}
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

// resumedWith resumes `session` in a new process of the driver with the
// instructions `system`.
func resumedWith(t *testing.T, home, session, system string) *wireSession {
	t.Helper()
	s := startDriverIn(t, home)
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": map[string]any{}, "system": system})
	s.expect("started")
	s.expect("usage")
	work(s, "stp_work", "trn_next")
	return s
}

// injectedInto is what every process so far injected into the thread, as
// Codex read it back in the turn of the post `id`.
func injectedInto(s *wireSession, id string) []any {
	s.t.Helper()
	postText(s, id, "trn_next", "history")
	var injected []any
	if err := json.Unmarshal([]byte(saidOf(s.until("idle"))), &injected); err != nil {
		s.t.Fatal(err)
	}
	return injected
}

func instructionsItem(system string) any {
	return map[string]any{"type": "message", "role": "developer", "content": []any{map[string]any{"type": "input_text",
		"text": "Your current instructions, in place of any given earlier in this thread:\n" + system}}}
}

// A resume's developer instructions do not reach the thread's history, so
// instructions that changed since the thread was last handed some are
// injected before the resumed thread's first post, once; unchanged ones
// never are.
func TestAResumeInjectsItsInstructionsOnlyWhenTheyChanged(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_next")
	if got := injectedInto(s, "stp_first"); len(got) != 0 {
		t.Fatalf("a new thread has its instructions from its start, injected with none: %v", got)
	}
	s.end()

	want := []any{}
	for i, next := range []struct {
		system  string
		changed bool
	}{
		{"be brief", false},
		{"be thorough", true},
		{"be thorough", false},
		{"be brief", true},
		{"be brief", false},
	} {
		if next.changed {
			want = append(want, instructionsItem(next.system))
		}
		again := resumedWith(t, s.home, session, next.system)
		for n := 0; n < 2; n++ {
			if got := injectedInto(again, fmt.Sprintf("stp_post_%d_%d", i, n)); !reflect.DeepEqual(got, want) {
				t.Fatalf("resume %d, post %d: the thread holds exactly %v, not %v", i, n, want, got)
			}
		}
		again.end()
	}
}

// A thread with no record of what it was handed, one made before the
// record or one whose record was lost, is handed its instructions once.
func TestAThreadWithNoRecordIsHandedItsInstructionsOnce(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_next")
	injectedInto(s, "stp_first")
	s.end()
	if err := os.RemoveAll(filepath.Join(s.home, ".codex", "cyfr-instructions")); err != nil {
		t.Fatal(err)
	}
	want := []any{instructionsItem("be brief")}
	for i := 0; i < 2; i++ {
		again := resumedWith(t, s.home, session, "be brief")
		if got := injectedInto(again, fmt.Sprintf("stp_post_%d", i)); !reflect.DeepEqual(got, want) {
			t.Fatalf("resume %d: handed once, %v, not %v", i, want, got)
		}
		again.end()
	}
}

// An injection Codex refuses writes no post, and is made again at the next
// resume: nothing is recorded as handed that was not.
func TestARefusedInjectionWritesNoPostAndIsMadeAgain(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", "trn_next")
	injectedInto(s, "stp_first")
	s.end()

	t.Setenv("FAKE_INJECT_FAIL", "1")
	refused := resumedWith(t, s.home, session, "be thorough")
	refused.send(map[string]any{"t": "post", "id": "stp_unwritten", "work": "trn_next", "content": []any{map[string]any{"type": "text", "text": "history"}}})
	if e := refused.expect("refused"); e["id"] != "stp_unwritten" || e["reason"] != "OpenAI Codex did not take its changed instructions, so the post was not written; send it again." {
		t.Fatalf("the post is refused in the driver's words: %v", e)
	}
	refused.end()

	t.Setenv("FAKE_INJECT_FAIL", "")
	again := resumedWith(t, s.home, session, "be thorough")
	if got, want := injectedInto(again, "stp_written"), []any{instructionsItem("be thorough")}; !reflect.DeepEqual(got, want) {
		t.Fatalf("the next resume hands them over: %v, not %v", got, want)
	}
}

// What a thread was last handed is recorded only if the record was written,
// and a stale one never stands for what was handed after it: a record
// Codex's driver cannot rewrite costs a repeated injection, never a skipped
// change.
func TestARecordThatCannotBeRewrittenSkipsNoChange(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes a file of mode 400, so no record here is past writing")
	}
	const brief, thorough = "be brief", "be thorough"
	for _, c := range []struct {
		name         string
		file, folder os.FileMode
		lost         bool
		refused      bool
		want         []string
	}{
		{name: "a read-only record", file: 0o400, folder: 0o700, want: []string{thorough, brief}},
		{name: "a read-only folder", file: 0o600, folder: 0o500, want: []string{thorough, brief}},
		{name: "no record and nowhere to write one", folder: 0o500, lost: true, want: []string{thorough, brief, brief}},
		{name: "a record that can neither go nor change", file: 0o400, folder: 0o500, refused: true, want: []string{}},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := startDriver(t)
			session := startFresh(s, map[string]any{})
			work(s, "stp_work", "trn_next")
			injectedInto(s, "stp_first")
			s.end()

			folder := filepath.Join(s.home, ".codex", "cyfr-instructions")
			record := filepath.Join(folder, session)
			var err error
			if c.lost {
				err = os.Remove(record)
			} else {
				err = os.Chmod(record, c.file)
			}
			if err != nil || os.Chmod(folder, c.folder) != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(folder, 0o700) })

			changed := resumedWith(t, s.home, session, thorough)
			if c.refused {
				changed.send(map[string]any{"t": "post", "id": "stp_b", "work": "trn_next", "content": []any{map[string]any{"type": "text", "text": "history"}}})
				if e := changed.expect("refused"); e["id"] != "stp_b" || e["reason"] != "OpenAI Codex's changed instructions could not be recorded in its folder, so the post was not written; check that the program's folder can be written." {
					t.Fatalf("nothing is injected that a stale record would hide: %v", e)
				}
			} else {
				injectedInto(changed, "stp_b")
			}
			changed.end()

			var got []any
			for i := 0; i < 2; i++ {
				again := resumedWith(t, s.home, session, brief)
				got = injectedInto(again, fmt.Sprintf("stp_a_%d", i))
				again.end()
			}
			want := []any{}
			for _, system := range c.want {
				want = append(want, instructionsItem(system))
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("the last instructions handed are the last the thread was given: %v, not %v", got, want)
			}
		})
	}
}
