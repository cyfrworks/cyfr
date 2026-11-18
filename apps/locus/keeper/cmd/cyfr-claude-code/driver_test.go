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
		os.Exit(fakeClaude())
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
// the fake harness its harness.
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
	t.Setenv(fakeEnv, "1")
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	return startDriverIn(t, home)
}

func startDriverIn(t *testing.T, home string) *wireSession {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &wireSession{t: t, in: inW, events: make(chan map[string]any, 1024), done: make(chan int, 1), stderr: &lockedBuffer{}, home: home}
	c := brainwire.NewConn(driverName, outW, s.stderr)
	d := newDriver([]string{os.Args[0]}, c, home)
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

// expect is the next event, of type t.
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

// startFresh reads the driver's hello and starts a new session.
func startFresh(s *wireSession, config map[string]any) string {
	s.t.Helper()
	s.expect("hello")
	return started(s, config)
}

// started starts a new session in a driver whose hello was read.
func started(s *wireSession, config map[string]any) string {
	s.t.Helper()
	s.send(map[string]any{"t": "start", "gen": 3, "config": config, "system": "be brief"})
	started := s.expect("started")
	if started["fresh"] != true || len(started["held"].([]any)) != 0 || !brainwire.IsUUID(started["session"].(string)) {
		s.t.Fatalf("a fresh start answers a new session holding nothing: %v", started)
	}
	return started["session"].(string)
}

func work(s *wireSession, id string, tools []any) {
	s.t.Helper()
	s.send(map[string]any{"t": "work", "id": id, "work": "trn_1", "tools": tools})
	if e := s.expect("accepted"); e["id"] != id {
		s.t.Fatalf("the work is accepted by its id: %v", e)
	}
}

func postText(s *wireSession, id, text string) {
	s.t.Helper()
	s.send(map[string]any{"t": "post", "id": id, "work": "trn_1", "content": []any{map[string]any{"type": "text", "text": text}}})
	if e := s.expect("accepted"); e["id"] != id {
		s.t.Fatalf("the post is accepted by its id: %v", e)
	}
}

var filesTool = map[string]any{"name": "files", "description": "Read the athanor's files", "parameters": map[string]any{"type": "object"}}

func TestHelloFirstAndAnEmptyInputEndsIt(t *testing.T) {
	s := startDriver(t)
	hello := s.expect("hello")
	if hello["v"] != float64(1) || hello["driver"] != "cyfr-claude-code" || len(hello["boot"].(string)) != 32 {
		t.Fatalf("hello names the version, the driver and a fresh boot: %v", hello)
	}
	if status := s.end(); status != 0 {
		t.Fatalf("an input that ends ends the driver with 0: %d", status)
	}
	other := startDriver(t)
	if other.expect("hello")["boot"] == hello["boot"] {
		t.Fatal("each driver process has a boot of its own")
	}
}

// The probe's first result counted 2 input tokens in `usage` and 1,185 in
// `model_usage_since_last_result`: the side requests are in the latter
// alone, and the main requests in both. Each model's four counts are
// carried as the harness gives them, none added to another, and `usage` is
// never added to them; a result with no per-model usage says so, and one
// whose counts do not all read says which models did.
func TestAResultsUsageIsEachModelsOnceAndUnknownStaysUnknown(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{"model": "fake-opus"})
	work(s, "stp_work", []any{filesTool})
	usageOf := func(post, words string) map[string]any {
		postText(s, post, words)
		for _, e := range s.until("idle") {
			if e["t"] == "usage" {
				return e
			}
		}
		t.Fatalf("%s: a result is counted", post)
		return nil
	}
	counts := func(input, output, read, write float64) map[string]any {
		return map[string]any{"input_tokens": input, "output_tokens": output, "cache_read_tokens": read, "cache_write_tokens": write}
	}
	complete := usageOf("stp_post_1", "hello")
	want := []any{
		map[string]any{"model": "fake-haiku", "counts": counts(1173, 40, 0, 0)},
		map[string]any{"model": "fake-opus", "counts": counts(12, 3, 5, 2)},
	}
	if complete["accounting"] != "complete" || !reflect.DeepEqual(complete["models"], want) {
		t.Fatalf("every model's counts, the main requests' counted once: %v", complete)
	}
	unknown := usageOf("stp_post_2", "uncounted")
	if _, named := unknown["models"]; unknown["accounting"] != "unavailable" || named {
		t.Fatalf("a result with no usage is unavailable, never zeros: %v", unknown)
	}
	partial := usageOf("stp_post_3", "partial")
	if partial["accounting"] != "partial" || !reflect.DeepEqual(partial["models"], want[1:]) {
		t.Fatalf("a model whose counts do not read is left out, and the accounting says partial: %v", partial)
	}
}

func TestATurnStreamsSaysCountsAndGoesIdleNamingThePost(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{"model": "fake-opus", "effort": "high", "permission_mode": "plan", "harness_tools": []any{"Read", "Grep"}})
	work(s, "stp_work", []any{filesTool})
	postText(s, "stp_post", "hello")
	got := s.until("idle")
	var text, said string
	var usage, idle map[string]any
	for _, e := range got {
		if e["gen"] != float64(3) || e["work"] != "trn_1" {
			t.Fatalf("every event of the turn names its gen and its work: %v", e)
		}
		switch e["t"] {
		case "text":
			text += e["delta"].(string)
			if e["message"] != "msg_fake_1" {
				t.Fatalf("a delta names its native message: %v", e)
			}
		case "said":
			said = e["text"].(string)
		case "usage":
			usage = e
		case "idle":
			idle = e
		}
	}
	want := "Hello from the fake harness: model=fake-opus effort=high permission=plan tools=Read,Grep"
	if text != want || said != want {
		t.Fatalf("the reply streams and is said whole, with the start's flags: %q %q", text, said)
	}
	if usage["result"] != "result-uuid-1" || usage["accounting"] != "complete" || len(usage["models"].([]any)) != 2 {
		t.Fatalf("usage names the native result and its models' counts: %v", usage)
	}
	if idle["stop"] != "end_turn" || fmt.Sprint(idle["answered"]) != "[stp_post]" {
		t.Fatalf("idle names the post the result answered: %v", idle)
	}
	if strings.Contains(s.output(), stderrCanary) {
		t.Fatal("nothing of the harness's standard error reaches the wire")
	}
	if !strings.Contains(s.stderr.String(), stderrCanary) {
		t.Fatal("the harness's standard error is the driver's (a positive control for the check above)")
	}
	if status := s.end(); status != 0 {
		t.Fatalf("closing the input ends driver and harness: %d", status)
	}
}

func TestAnAskIsHeldAndAnsweredThroughTheStubsInput(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{filesTool})
	postText(s, "stp_post", "read it")
	var ask map[string]any
	for _, e := range s.until("ask") {
		if e["t"] == "ask" {
			ask = e
		}
	}
	arguments := ask["arguments"].(map[string]any)
	if ask["name"] != "files" || ask["work"] != "trn_1" || arguments["path"] != "notes.txt" || len(arguments) != 3 {
		t.Fatalf("an ask names CYFR's tool as CYFR names it, with the call's arguments: %v", ask)
	}
	if !strings.Contains(s.output(), `"count":12345678901234567890`) {
		t.Fatal("a call's numbers are passed on as the model wrote them")
	}
	// The tools are not set again while the ask is held.
	s.send(map[string]any{"t": "work", "id": "stp_again", "work": "trn_1", "tools": []any{}})
	if e := s.expect("refused"); e["id"] != "stp_again" {
		t.Fatalf("a work while an ask is held is refused: %v", e)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask["ask"], "content": "three lines", "is_error": false})
	s.expect("accepted")
	var said string
	for _, e := range s.until("idle") {
		if e["t"] == "said" {
			said = e["text"].(string)
		}
	}
	if said != "The file says: three lines" {
		t.Fatalf("the harness reads CYFR's answer as the tool's result: %q", said)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_twice", "ask": ask["ask"], "content": "again", "is_error": false})
	if e := s.expect("refused"); e["id"] != "stp_twice" {
		t.Fatalf("an ask is answered once: %v", e)
	}
}

func TestAnErrorAnswerIsTheToolsError(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{filesTool})
	postText(s, "stp_post", "read it")
	var ask map[string]any
	for _, e := range s.until("ask") {
		ask = e
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask["ask"], "content": "not allowed", "is_error": true})
	s.expect("accepted")
	var said string
	for _, e := range s.until("idle") {
		if e["t"] == "said" {
			said = e["text"].(string)
		}
	}
	if said != "CYFR refused: not allowed" {
		t.Fatalf("a refusal reaches the harness as the call's error: %q", said)
	}
}

func TestTheHarnessesOwnToolRunsInItsBoxShownByNameOnly(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "own")
	got := s.until("idle")
	var own []string
	for _, e := range got {
		if e["t"] == "own" {
			own = append(own, fmt.Sprintf("%v:%v", e["name"], e["phase"]))
		}
		if e["t"] == "ask" {
			t.Fatalf("the harness's own tool is not CYFR's to ask about: %v", e)
		}
	}
	if fmt.Sprint(own) != "[Bash:start Bash:end]" {
		t.Fatalf("an own tool is shown starting and ending by name: %v", own)
	}
	for _, words := range []string{"secret-of-the-folder", "FOLDER-CANARY"} {
		if strings.Contains(s.output(), words) {
			t.Fatalf("nothing of an own tool's input or result reaches the wire: %s", words)
		}
	}
}

func TestTheHarnessesErrorIsTypedInTheDriversWords(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "rate")
	got := s.until("idle")
	var errorsSeen int
	for _, e := range got {
		switch e["t"] {
		case "error":
			errorsSeen++
			if e["type"] != "rate_limited" || e["message"] != errorSentence("rate_limited") {
				t.Fatalf("an errored message is its type in the driver's words: %v", e)
			}
		case "said", "text":
			t.Fatalf("none of an errored message's text is passed on: %v", e)
		case "idle":
			if e["stop"] != "error" {
				t.Fatalf("the turn ends in error: %v", e)
			}
		}
	}
	if errorsSeen != 1 || strings.Contains(s.output(), "HARNESS-WORDS") {
		t.Fatalf("one error, and none of the harness's words: %d", errorsSeen)
	}
}

func TestALateResultNamesNoWork(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "late")
	first := s.until("idle")
	if first[len(first)-1]["work"] != "trn_1" {
		t.Fatalf("the post's turn names its work: %v", first)
	}
	late := s.until("idle")
	for _, e := range late {
		if _, ok := e["work"]; ok {
			t.Fatalf("a native turn no post started names no work: %v", e)
		}
	}
	if idle := late[len(late)-1]; len(idle["answered"].([]any)) != 0 {
		t.Fatalf("a late result answers no post: %v", idle)
	}
}

func TestTextPastOneLineIsCutToFit(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "big")
	for _, e := range s.until("idle") {
		if e["t"] == "said" {
			text := e["text"].(string)
			if !strings.HasSuffix(text, "…[CYFR cut this text to fit one line of the wire.]") || len(text) >= brainwire.MaxLineBytes {
				t.Fatalf("a message past one line is cut with a note: %d bytes", len(text))
			}
		}
	}
	for _, line := range strings.Split(s.output(), "\n") {
		if len(line) > brainwire.MaxLineBytes {
			t.Fatalf("no line is past the wire's bound: %d", len(line))
		}
	}
}

func TestAnotherControlRequestIsRefusedToTheHarness(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "other")
	var said string
	for _, e := range s.until("idle") {
		if e["t"] == "said" {
			said = e["text"].(string)
		}
	}
	if said != "the driver answered error" {
		t.Fatalf("a control request the driver does not answer is refused: %q", said)
	}
}

func TestDeliveriesBeforeAStartAndToolsPastTheirBoundsAreRefused(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "work", "id": "w0", "work": "trn_1", "tools": []any{}})
	s.expect("refused")
	s.send(map[string]any{"t": "post", "id": "p0", "work": "trn_1", "content": []any{}})
	s.expect("refused")
	s.send(map[string]any{"t": "answer", "id": "a0", "ask": "ask-1", "content": "", "is_error": false})
	s.expect("refused")
	s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{}})
	s.expect("started")
	big := map[string]any{"name": "huge", "description": strings.Repeat("d", maxToolArgBytes), "parameters": map[string]any{}}
	s.send(map[string]any{"t": "work", "id": "w1", "work": "trn_1", "tools": []any{big}})
	if e := s.expect("refused"); !strings.Contains(e["reason"].(string), "huge") {
		t.Fatalf("a tool past one argument is refused by name: %v", e)
	}
}

func TestToolsTheHarnessCannotStartRefuseTheWork(t *testing.T) {
	t.Setenv("FAKE_TOOLS_FAIL", "1")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	s.send(map[string]any{"t": "work", "id": "w1", "work": "trn_1", "tools": []any{filesTool}})
	if e := s.expect("refused"); e["id"] != "w1" {
		t.Fatalf("a work whose tools did not start is refused: %v", e)
	}
}

func TestAResumeOfASessionTheFolderDoesNotHoldIsGoneThenAFreshStartRuns(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 1, "session": "0b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30", "config": map[string]any{}})
	s.expect("gone")
	s.send(map[string]any{"t": "start", "gen": 2, "config": map[string]any{}})
	if e := s.expect("started"); e["fresh"] != true {
		t.Fatalf("after gone, a fresh start runs in the same driver: %v", e)
	}
	s.send(map[string]any{"t": "start", "gen": 9, "session": "not-a-uuid", "config": map[string]any{}})
	if s.end() != 2 {
		t.Fatal("a second start while a harness runs breaks the protocol")
	}
}

func TestAResumeNamesThePendingPostsItsTranscriptHolds(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_held", "hello")
	s.until("idle")
	s.end()

	again := startDriverIn(t, s.home)
	again.expect("hello")
	again.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": map[string]any{}, "pending": []any{"stp_held", "stp_never"}})
	started := again.expect("started")
	if started["fresh"] != false || started["session"] != session || fmt.Sprint(started["held"]) != "[stp_held]" {
		t.Fatalf("a resume names the posts the transcript holds, and only those: %v", started)
	}
	// What a resumed harness writes before a post is asked of it: nothing.
	again.send(map[string]any{"t": "work", "id": "w2", "work": "trn_2", "tools": []any{}})
	if e := again.next(); e["t"] != "accepted" {
		t.Fatalf("the resumed session repeats nothing before its next work: %v", e)
	}
}

func TestTheHarnessesEndEndsTheDriver(t *testing.T) {
	t.Setenv("FAKE_EXIT_ON", "die")
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "die now")
	select {
	case status := <-s.done:
		if status != 3 {
			t.Fatalf("the driver ends with the harness's status: %d", status)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the driver outlived its harness")
	}
}

func TestACommandTheWireDoesNotReadEndsTheDriver(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	if _, err := s.in.Write([]byte(`{"t":"start","gen":0,"config":{"bypass":true}}` + "\n")); err != nil {
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
	if fmt.Sprint(listed["models"]) != "[map[id:default name:Default] map[id:fake-opus name:Fake Opus] map[id:fake-haiku name:Fake Haiku]]" ||
		fmt.Sprint(listed["efforts"]) != "[low high medium max]" {
		t.Fatalf("the harness's listing, with the efforts any model takes: %v", listed)
	}
	s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{}})
	s.expect("started")
	s.send(map[string]any{"t": "models", "id": "m2"})
	if again := s.expect("models"); fmt.Sprint(again["models"]) != fmt.Sprint(listed["models"]) {
		t.Fatalf("a running harness's listing is its start's: %v", again)
	}
}

// A folder that cannot be looked into may hold the transcript: forget
// says it could not look, and the transcript is there when the folder
// opens again; once it can be looked into, the transcript goes.
func TestForgetRefusesWhereItCannotLook(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a folder of mode 000, so no folder here is unreadable")
	}
	s := startDriver(t)
	config := filepath.Join(s.home, ".claude")
	projects := filepath.Join(config, "projects")
	project := filepath.Join(projects, "-home-a")
	session := "3b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	transcript := filepath.Join(project, session+".jsonl")
	if err := os.MkdirAll(project, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(transcript, []byte("the session"), 0o600); err != nil {
		t.Fatal(err)
	}
	s.expect("hello")
	for i, folder := range []string{project, projects} {
		if err := os.Chmod(folder, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(folder, 0o700) })
		id := fmt.Sprintf("obx_%d", i+1)
		s.send(map[string]any{"t": "forget", "id": id, "session": session})
		if e := s.expect("refused"); e["id"] != id {
			t.Fatalf("a folder that cannot be read is no proof the transcript is gone: %v", e)
		}
		if err := os.Chmod(folder, 0o700); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(transcript); err != nil {
			t.Fatalf("the transcript is still there: %v", err)
		}
	}
	s.send(map[string]any{"t": "forget", "id": "obx_3", "session": session})
	s.expect("forgot")
	if _, err := os.Stat(transcript); !os.IsNotExist(err) {
		t.Fatalf("a folder that can be read again gives its transcript up: %v", err)
	}
}

// #8321's seventh finding: a project folder past inspection takes nothing
// from what the other inspections found. The readable transcript's
// pending post is still held while another project cannot be read, and
// that failure is kept beside it, for forget to refuse on.
func TestAnUnreadableProjectLeavesTheHeldPostsAReadableTranscriptHolds(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a folder of mode 000, so no folder here is unreadable")
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	home := t.TempDir()
	projects := filepath.Join(home, ".claude", "projects")
	session := "5b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	line, _ := json.Marshal(map[string]any{"type": "user", "uuid": brainwire.PostUUID("stp_post_1")})
	if err := os.MkdirAll(filepath.Join(projects, "-home-a"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(projects, "-home-a", session+".jsonl"), append(line, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	pending := []string{"stp_post_1", "stp_never"}
	if got := heldPosts(home, session, pending); fmt.Sprint(got) != "[stp_post_1]" {
		t.Fatalf("the transcript holds the post: %v", got)
	}
	other := filepath.Join(projects, "-home-b")
	if err := os.MkdirAll(other, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(other, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(other, 0o700) })
	if got := heldPosts(home, session, pending); fmt.Sprint(got) != "[stp_post_1]" {
		t.Fatalf("another project past inspection leaves the post held: %v", got)
	}
	if found, failed := transcripts(home, session); len(found) != 1 || len(failed) == 0 {
		t.Fatalf("what the scan found and what it could not inspect, both kept: %v %v", found, failed)
	}
}

func TestForgetRemovesThatTranscriptAndNothingElse(t *testing.T) {
	s := startDriver(t)
	config := filepath.Join(s.home, ".claude")
	gone := "1b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	kept := "2b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	files := map[string]string{
		filepath.Join(config, "projects", "-home-a", gone+".jsonl"):                    "the forgotten session",
		filepath.Join(config, "projects", "-home-a", gone, "subagents", "agent.jsonl"): "its subagent",
		filepath.Join(config, "projects", "-home-b", gone+".jsonl"):                    "the same session from another folder",
		filepath.Join(config, "session-env", gone, "env"):                              "its environment",
		filepath.Join(config, "session-env", kept, "env"):                              "another session's environment",
		filepath.Join(config, "projects", "-home-a", kept+".jsonl"):                    "another session",
		filepath.Join(config, ".credentials.json"):                                     "the sign-in",
		filepath.Join(s.home, ".claude.json"):                                          "the harness's own settings",
	}
	for path, body := range files {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	s.expect("hello")
	s.send(map[string]any{"t": "forget", "id": "obx_1", "session": gone})
	if e := s.expect("forgot"); e["id"] != "obx_1" || e["session"] != gone {
		t.Fatalf("a forget is answered by its id and session: %v", e)
	}
	for path := range files {
		_, err := os.Stat(path)
		removed := strings.Contains(path, gone)
		if removed != os.IsNotExist(err) {
			t.Fatalf("only the forgotten session's transcript goes: %s (%v)", path, err)
		}
	}
	for _, folder := range []string{filepath.Join(config, "projects", "-home-a", gone), filepath.Join(config, "session-env", gone)} {
		if _, err := os.Stat(folder); !os.IsNotExist(err) {
			t.Fatalf("the session's own folders go with its transcript: %s", folder)
		}
	}
	s.send(map[string]any{"t": "forget", "id": "obx_2", "session": gone})
	s.expect("forgot")
	s.send(map[string]any{"t": "forget", "id": "obx_3", "session": "../../.credentials"})
	s.expect("refused")
	running := started(s, map[string]any{})
	s.send(map[string]any{"t": "forget", "id": "obx_4", "session": running})
	if e := s.expect("refused"); e["id"] != "obx_4" {
		t.Fatalf("the session the harness runs is not forgotten: %v", e)
	}
	if _, err := os.Stat(filepath.Join(config, ".credentials.json")); err != nil {
		t.Fatal("the sign-in survives every forget")
	}
}

// openPTY opens a pseudo-terminal pair: the driver's input is its other end.
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
		cmd := exec.Command(os.Args[0], echo, "--model", "unchanged words")
		cmd.Env = append(os.Environ(), driverMainEnv+"=1")
		cmd.Stdin = stdin
		var out bytes.Buffer
		cmd.Stdout = &out
		if err := cmd.Run(); err != nil {
			t.Fatal(err)
		}
		return out.String()
	}
	if got := run(slave); got != "--model unchanged words\n" {
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
