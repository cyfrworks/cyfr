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

// expect is the next event, of type t.
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
	if hello["v"] != float64(brainwire.Version) || hello["driver"] != "cyfr-claude-code" || len(hello["boot"].(string)) != 32 {
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
	startFresh(s, map[string]any{"model": "fake-opus", "effort": "high", "access": "default", "harness_tools": []any{"Read", "Grep"}})
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
	want := "Hello from the fake harness: model=fake-opus effort=high permission=default tools=Read,Grep"
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

// startDriverHolding is a driver whose harness's folder holds the
// person's own MCP servers by these names, as Claude Code's own
// configuration names them (`~/.claude.json`).
func startDriverHolding(t *testing.T, names ...string) *wireSession {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv(fakeEnv, "1")
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	servers := map[string]any{}
	for _, name := range names {
		servers[name] = map[string]any{"type": "stdio", "command": "their-server"}
	}
	config, _ := json.Marshal(map[string]any{"mcpServers": servers})
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), config, 0o600); err != nil {
		t.Fatal(err)
	}
	return startDriverIn(t, home)
}

// theirsRan posts `theirs`, under which the harness calls each server of
// the person's own it holds, and answers what it said and the own tools
// the wire showed; no call of theirs is CYFR's ask.
func theirsRan(t *testing.T, s *wireSession, id string) (string, []string) {
	t.Helper()
	postText(s, id, "theirs")
	var said string
	var own []string
	// Read one event at a time: an ask held for CYFR would keep the turn
	// from its idle.
	for e := s.next(); e["t"] != "idle"; e = s.next() {
		switch e["t"] {
		case "ask":
			t.Fatalf("a call of a server of the person's own is the program's, never CYFR's ask: %v", e)
		case "own":
			own = append(own, fmt.Sprintf("%v:%v", e["name"], e["phase"]))
		case "said":
			said = e["text"].(string)
		}
	}
	return said, own
}

// A server the person set up in Claude Code itself stays beside CYFR's:
// the harness holds it, its call is allowed with the model's own input
// and shown as the program's own tool by name, and CYFR's tool is still
// CYFR's ask. Servers whose tools Claude Code names `mcp__cyfr__…`
// (`cyfr__extra`, `cyfr_`) are theirs all the same.
func TestAServerOfThePersonsOwnStaysBesideCYFRsAndItsCallIsTheProgramsOwn(t *testing.T) {
	s := startDriverHolding(t, "mine", "cyfr__extra", "cyfr_")
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{filesTool})
	said, own := theirsRan(t, s, "stp_theirs")
	if want := "their servers ran: mcp__cyfr___theirs:allow:0 mcp__cyfr__extra__theirs:allow:0 mcp__mine__theirs:allow:0 beside cyfr-2"; said != want {
		t.Fatalf("each server of the person's own runs, allowed with its own input, beside CYFR's:\n%q\nnot\n%q", want, said)
	}
	if want := "[mcp__cyfr___theirs:start mcp__cyfr___theirs:end mcp__cyfr__extra__theirs:start mcp__cyfr__extra__theirs:end mcp__mine__theirs:start mcp__mine__theirs:end]"; fmt.Sprint(own) != want {
		t.Fatalf("each call of theirs is shown as the program's own tool by name: %v", own)
	}
	postText(s, "stp_read", "read it")
	var ask map[string]any
	for _, e := range s.until("ask") {
		ask = e
	}
	if ask["name"] != "files" {
		t.Fatalf("CYFR's tool is still CYFR's ask, by its own name: %v", ask)
	}
}

// A server of the person's own named `cyfr` keeps its name and its tools:
// CYFR's server takes the first name of `cyfr`, `cyfr-2`, `cyfr-3`… that
// none of theirs is or begins with followed by `_`, since Claude Code
// lets a server the driver sets replace one of theirs of that name.
func TestAServerOfThePersonsNamedCyfrKeepsItsNameAndCYFRsTakesAnother(t *testing.T) {
	s := startDriverHolding(t, "cyfr", "cyfr-2__extra")
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{filesTool})
	said, _ := theirsRan(t, s, "stp_theirs")
	if want := "their servers ran: mcp__cyfr__theirs:allow:0 mcp__cyfr-2__extra__theirs:allow:0 beside cyfr-3"; said != want {
		t.Fatalf("the person's servers keep their names and CYFR's takes another:\n%q\nnot\n%q", want, said)
	}
	postText(s, "stp_read", "read it")
	var ask map[string]any
	for _, e := range s.until("ask") {
		ask = e
	}
	if ask["name"] != "files" {
		t.Fatalf("CYFR's tool under its other name is CYFR's ask, by its own name: %v", ask)
	}
	s.send(map[string]any{"t": "answer", "id": "stp_answer", "ask": ask["ask"], "content": "three lines", "is_error": false})
	s.expect("accepted")
	s.until("idle")
}

// A start whose harness does not list its MCP servers, its status read
// refused or answered with no list, ends before anything is set: no name
// for CYFR's server is known not to replace one of the person's, and a
// server of theirs named `cyfr` would be replaced for the process's life.
// It proves the driver's exit, with no `started`, and its reason on its
// own standard error, which the box keeps; what the person reads of a
// start that failed is the holder's.
func TestAStartWhoseServersAreNotListedEndsBeforeAnythingIsSet(t *testing.T) {
	for _, status := range []string{"error", "unlisted"} {
		t.Run(status, func(t *testing.T) {
			t.Setenv("FAKE_STATUS", status)
			s := startDriverHolding(t, "cyfr")
			s.expect("hello")
			s.send(map[string]any{"t": "start", "gen": 3, "config": map[string]any{}, "system": "be brief"})
			select {
			case code := <-s.done:
				if code != 1 || strings.Contains(s.output(), `"started"`) {
					t.Fatalf("the start ends the driver with 1 and no started: %d %s", code, s.output())
				}
			case <-time.After(20 * time.Second):
				t.Fatal("a start with no listing of the servers went on")
			}
			if !strings.Contains(s.stderr.String(), "Claude Code did not list its MCP servers") {
				t.Fatalf("the driver says why on its standard error: %q", s.stderr.String())
			}
			if s.why() != "servers_unlisted" {
				t.Fatalf("the holder is told servers_unlisted: %s", s.output())
			}
		})
	}
}

// A tool named with CYFR's prefix whose server is not CYFR's as the harness
// names it, by name or by source (one of the person's that started after
// the listing), is the harness's own: no ask reaches CYFR, the call is
// allowed with the model's own input untouched, and it is shown as the
// harness's own tool, start and end, from its permission.
func TestALateServerNamedAsCYFRsIsTheProgramsOwnByItsPermission(t *testing.T) {
	for name, server := range map[string]string{
		"another server": `{"name": "cyfr__late", "source": "user"}`,
		"another source": `{"name": "cyfr", "source": "user"}`,
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("FAKE_LATE_SERVER", server)
			s := startDriver(t)
			startFresh(s, map[string]any{})
			work(s, "stp_work", []any{filesTool})
			postText(s, "stp_late", "arrived")
			var said string
			var own []string
			// One event at a time: an ask held for CYFR would keep the turn
			// from its idle.
			for e := s.next(); e["t"] != "idle"; e = s.next() {
				switch e["t"] {
				case "ask":
					t.Fatalf("a call of a server that is not CYFR's never reaches CYFR: %v", e)
				case "own":
					own = append(own, fmt.Sprintf("%v:%v", e["name"], e["phase"]))
				case "said":
					said = e["text"].(string)
				}
			}
			if want := `{"behavior":"allow","updatedInput":{"query":"theirs"}}`; said != want {
				t.Fatalf("the call is allowed with the model's own input untouched:\n%s\nnot\n%s", want, said)
			}
			if want := "[mcp__cyfr__late:start mcp__cyfr__late:end]"; fmt.Sprint(own) != want {
				t.Fatalf("the call is shown as the harness's own tool, start and end: %v", own)
			}
		})
	}
}

// A call of the harness's own that its turn ended without a result for is
// done with that turn: the driver forgets it, as Aqua settles every own
// tool still running at the turn's idle, so a later turn's call under the
// same id is shown starting and ending on its own.
func TestAnOwnCallItsTurnEndedWithoutIsForgottenWithTheTurn(t *testing.T) {
	t.Setenv("FAKE_LATE_SERVER", `{"name": "cyfr__late", "source": "user"}`)
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{filesTool})
	owns := func(post, words string) []string {
		postText(s, post, words)
		var own []string
		for e := s.next(); e["t"] != "idle"; e = s.next() {
			if e["t"] == "own" {
				own = append(own, fmt.Sprintf("%v:%v", e["name"], e["phase"]))
			}
		}
		return own
	}
	if got := owns("stp_unended", "unended"); fmt.Sprint(got) != "[mcp__cyfr__late:start]" {
		t.Fatalf("the call is shown started, its turn ending with no result for it: %v", got)
	}
	if got := owns("stp_again", "arrived"); fmt.Sprint(got) != "[mcp__cyfr__late:start mcp__cyfr__late:end]" {
		t.Fatalf("the next turn's call under the same id is shown started and ended on its own: %v", got)
	}
}

// A start the harness does not answer within answerWait ends the driver,
// saying why on its standard error; a work whose tools it does not start
// within it is refused in the driver's words, each work at its own bound.
// Neither waits on the holder's clock alone. It proves the driver's exit
// and its reason; what the person reads of a start that failed is the
// holder's.
func TestAnAnswerTheHarnessDoesNotGiveInTimeEndsTheWait(t *testing.T) {
	was := answerWait
	answerWait = 300 * time.Millisecond
	t.Cleanup(func() { answerWait = was })
	t.Run("start", func(t *testing.T) {
		t.Setenv("FAKE_SILENT", "initialize")
		s := startDriver(t)
		s.expect("hello")
		s.send(map[string]any{"t": "start", "gen": 3, "config": map[string]any{}, "system": "be brief"})
		select {
		case code := <-s.done:
			if code != 1 || !strings.Contains(s.stderr.String(), "Claude Code did not answer its start in time") {
				t.Fatalf("the driver ends with 1, saying why on its standard error: %d %q", code, s.stderr.String())
			}
			if s.why() != "unanswered" {
				t.Fatalf("the holder is told unanswered: %s", s.output())
			}
		case <-time.After(20 * time.Second):
			t.Fatal("a start the harness never answered went on")
		}
	})
	t.Run("each work's tools", func(t *testing.T) {
		t.Setenv("FAKE_SILENT", "later tools")
		s := startDriver(t)
		startFresh(s, map[string]any{})
		s.send(map[string]any{"t": "work", "id": "stp_first", "work": "trn_1", "tools": []any{filesTool}})
		s.send(map[string]any{"t": "work", "id": "stp_second", "work": "trn_1", "tools": []any{filesTool}})
		if e := s.expect("accepted"); e["id"] != "stp_first" {
			t.Fatalf("the answered work is accepted: %v", e)
		}
		if e := s.expect("refused"); e["id"] != "stp_second" || e["reason"] != toolsLateSentence() {
			t.Fatalf("the work its harness did not answer is refused at its own bound: %v", e)
		}
	})
	t.Run("tools", func(t *testing.T) {
		t.Setenv("FAKE_SILENT", "tools")
		s := startDriver(t)
		startFresh(s, map[string]any{})
		s.send(map[string]any{"t": "work", "id": "stp_work", "work": "trn_1", "tools": []any{filesTool}})
		if e := s.expect("refused"); e["id"] != "stp_work" || e["reason"] != toolsLateSentence() {
			t.Fatalf("the work is refused in the driver's words: %v", e)
		}
	})
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

// A turn the harness ended in its model's error is typed by what its result
// says, its HTTP status before the message's own type, which 2.1.323 gave
// a 529 as `server_error`: an overload, a refusal the model kept to, a rate
// limit, with when it lifts when the harness said so in its
// `rate_limit_event`. One error each, in the driver's words.
func TestATurnsErrorIsTypedByWhatItsResultSays(t *testing.T) {
	for words, want := range map[string][2]string{
		"overloaded": {"overloaded", "Claude Code reported its provider overloaded; ask again later."},
		"refusing":   {"invalid_request", refusalSentence},
		"limited":    {"rate_limited", "Claude Code reported a rate limit; it lifts at 11:16 UTC on 24 November 2026."},
		"poisoned":   {"invalid_request", unsendableSentence},
	} {
		t.Run(words, func(t *testing.T) {
			s := startDriver(t)
			startFresh(s, map[string]any{})
			work(s, "stp_work", []any{})
			postText(s, "stp_post", words)
			var errs []string
			for e := s.next(); e["t"] != "idle"; e = s.next() {
				if e["t"] == "error" {
					errs = append(errs, fmt.Sprintf("%v: %v", e["type"], e["message"]))
				}
			}
			if fmt.Sprint(errs) != fmt.Sprintf("[%s: %s]", want[0], want[1]) || strings.Contains(s.output(), "HARNESS-WORDS") {
				t.Fatalf("one error, %s, in the driver's words: %v", want[0], errs)
			}
		})
	}
}

// A turn the model's API refused for a message of the session's own
// history ends that session: the driver says so, removes that session's
// transcript and no other file, and ends, so the next start of the session
// answers gone and the thread starts over from its posts. An error of any
// other kind removes nothing, and the session goes on.
func TestASessionTheAPIRefusesIsRemovedAndItsNextStartIsGone(t *testing.T) {
	// refused posts `poisoned` in a new session, after files of others the
	// driver must leave, and answers the session once its driver ended.
	refused := func(t *testing.T) (*wireSession, string, []string) {
		s := startDriver(t)
		session := startFresh(s, map[string]any{})
		project := filepath.Join(s.home, ".claude", "projects", "-fake")
		kept := []string{filepath.Join(project, "0b9d3a1e-5c2f-4e8a-9d61-7a3b2c1d0e4f.jsonl"), filepath.Join(s.home, ".claude", ".credentials.json")}
		for _, name := range kept {
			if err := os.WriteFile(name, []byte("{}\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		work(s, "stp_work", []any{})
		postText(s, "stp_post", "poisoned")
		var errs []string
		for e := s.next(); e["t"] != "idle"; e = s.next() {
			if e["t"] == "error" {
				errs = append(errs, fmt.Sprint(e["message"]))
			}
		}
		if fmt.Sprint(errs) != "["+unsendableSentence+"]" {
			t.Fatalf("the turn says the session could not go on: %v", errs)
		}
		select {
		case <-s.done:
		case <-time.After(20 * time.Second):
			t.Fatal("the driver of a session that cannot go on did not end")
		}
		return s, session, kept
	}
	t.Run("the refused session's transcript is removed, and no other file", func(t *testing.T) {
		s, session, kept := refused(t)
		if _, err := os.Stat(filepath.Join(s.home, ".claude", "projects", "-fake", session+".jsonl")); !os.IsNotExist(err) {
			t.Fatalf("the session's transcript is removed: %v", err)
		}
		for _, name := range kept {
			if _, err := os.Stat(name); err != nil {
				t.Fatalf("another session's transcript and the sign-in stay: %s %v", name, err)
			}
		}
	})
	t.Run("its next start is gone", func(t *testing.T) {
		s, session, _ := refused(t)
		again := startDriverIn(t, s.home)
		again.expect("hello")
		again.send(map[string]any{"t": "start", "gen": 4, "session": session, "config": map[string]any{}})
		again.expect("gone")
	})
	t.Run("any other error removes nothing", func(t *testing.T) {
		s := startDriver(t)
		session := startFresh(s, map[string]any{})
		work(s, "stp_work", []any{})
		postText(s, "stp_post", "overloaded")
		s.until("idle")
		postText(s, "stp_again", "hello")
		s.until("idle")
		if _, err := os.Stat(filepath.Join(s.home, ".claude", "projects", "-fake", session+".jsonl")); err != nil {
			t.Fatalf("an error of another kind removes nothing, and the session goes on: %v", err)
		}
	})
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

// A post written while the harness's turn runs is taken at once, and one
// result that answers it and the post before it names both: the harness's
// plural field, never its singular, which names the first alone.
func TestAResultAnsweringTwoPostsNamesBothAndAPostDuringATurnIsTakenAtOnce(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_first", "together")
	postText(s, "stp_second", "and this")
	got := s.until("idle")
	idle := got[len(got)-1]
	if !reflect.DeepEqual(idle["answered"], []any{"stp_first", "stp_second"}) || idle["stop"] != "end_turn" {
		t.Fatalf("the result answers both posts: %v", idle)
	}
}

// A subagent's lines, those of a tool use's own session, are not the
// member's reply: none of its text is streamed or said, and its tools are
// not the member's.
func TestASubagentsLinesAreNotTheReply(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "subagent")
	var said []string
	for _, e := range s.until("idle") {
		switch e["t"] {
		case "said":
			said = append(said, e["text"].(string))
		case "own":
			t.Fatalf("a subagent's tool is not the member's: %v", e)
		}
	}
	if !reflect.DeepEqual(said, []string{"the main reply"}) || strings.Contains(s.output(), "SUBAGENT-WORDS") {
		t.Fatalf("only the main session's reply is said: %q", said)
	}
}

// A message whose text is split by a call of CYFR's is said once, its
// text whole around the call.
func TestAMessagesTextAroundACallIsSaidWhole(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "around")
	var said []string
	for _, e := range s.until("idle") {
		if e["t"] == "said" {
			said = append(said, e["text"].(string))
		}
	}
	if !reflect.DeepEqual(said, []string{"before the call, after it"}) {
		t.Fatalf("the message's text is said whole: %q", said)
	}
}

// A line of the harness's that is no JSON, of a type the driver does not
// read, or an event that does not read, is passed over: the turn goes on
// and ends as any other.
func TestALineTheDriverCannotReadIsPassedOver(t *testing.T) {
	s := startDriver(t)
	startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	postText(s, "stp_post", "noise")
	got := s.until("idle")
	var said []string
	for _, e := range got {
		if e["t"] == "said" {
			said = append(said, e["text"].(string))
		}
	}
	if idle := got[len(got)-1]; !reflect.DeepEqual(said, []string{"still here"}) || !reflect.DeepEqual(idle["answered"], []any{"stp_post"}) {
		t.Fatalf("the turn goes on past what does not read: %q %v", said, idle)
	}
}

// A fresh session's context, the thread so far, reaches the harness in the
// post's own line, before the post's content.
func TestAPostsContextComesBeforeItsContentInOneLine(t *testing.T) {
	s := startDriver(t)
	session := startFresh(s, map[string]any{})
	work(s, "stp_work", []any{})
	s.send(map[string]any{"t": "post", "id": "stp_post", "work": "trn_1",
		"context": []any{map[string]any{"type": "text", "text": "Earlier: a post."}},
		"content": []any{map[string]any{"type": "text", "text": "hello"}}})
	if e := s.expect("accepted"); e["id"] != "stp_post" {
		t.Fatalf("the post is accepted: %v", e)
	}
	s.until("idle")
	raw, err := os.ReadFile(filepath.Join(s.home, ".claude", "projects", "-fake", session+".jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var lines []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatal(err)
		}
		lines = append(lines, entry)
	}
	want := []map[string]any{{"type": "user", "uuid": brainwire.PostUUID("stp_post"), "message": map[string]any{"role": "user", "content": []any{
		map[string]any{"type": "text", "text": "Earlier: a post."},
		map[string]any{"type": "text", "text": "hello"}}}}}
	if !reflect.DeepEqual(lines, want) {
		t.Fatalf("the context and then the content, in the post's one line: %v", lines)
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
	// Each within one argument, the tools together past one line to the
	// harness: a quote is two bytes in the work and four in the line that
	// sets them, each tool there a string of its own JSON.
	quoted := []any{}
	for i := 0; i < 5; i++ {
		quoted = append(quoted, map[string]any{"name": fmt.Sprintf("quoted%d", i), "description": strings.Repeat(`"`, 60000), "parameters": map[string]any{}})
	}
	s.send(map[string]any{"t": "work", "id": "w2", "work": "trn_1", "tools": quoted})
	if e := s.expect("refused"); !strings.Contains(e["reason"].(string), "as one line to the harness") {
		t.Fatalf("tools past one line to the harness are refused: %v", e)
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
	if why := s.why(); why != "ended" {
		t.Fatalf("the holder is told ended: %v", why)
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
	if why := s.why(); why != "broken" {
		t.Fatalf("the holder is told broken: %v", why)
	}
}

func TestModelsAreListedWithOrWithoutAStart(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "m1"})
	listed := s.expect("models")
	want := []any{
		map[string]any{"id": "default", "name": "Default", "efforts": []any{"low", "high"}},
		map[string]any{"id": "fake-opus", "name": "Fake Opus", "efforts": []any{"low", "medium", "high", "max"}},
		map[string]any{"id": "fake-haiku", "name": "Fake Haiku", "efforts": []any{}},
	}
	if _, flat := listed["efforts"]; flat || !reflect.DeepEqual(listed["models"], want) {
		t.Fatalf("the harness's listing, each model with the efforts it takes and no other's: %v", listed)
	}
	access := []any{map[string]any{"id": "default", "name": "Default mode"}}
	if !reflect.DeepEqual(listed["access"], access) {
		t.Fatalf("the listing's access is the one choice the driver honours: %v", listed["access"])
	}
	s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{}})
	s.expect("started")
	s.send(map[string]any{"t": "models", "id": "m2"})
	if again := s.expect("models"); fmt.Sprint(again["models"]) != fmt.Sprint(listed["models"]) || !reflect.DeepEqual(again["access"], access) {
		t.Fatalf("a running harness's listing is its start's: %v", again)
	}
}

// What a start, and a listing with no harness running, say of the
// account is what the harness's own answer positively says: signed out
// only on the one shape it answers with no sign-in, which alone refuses a
// listing; signed in only where it names a plan, a token source, a key
// source or another provider; and nothing for any other answer, which
// lists.
func TestTheAccountIsSaidOnlyWhereTheHarnessSaysIt(t *testing.T) {
	for _, c := range []struct {
		account string
		says    any
	}{
		{`{"subscriptionType":"max","apiProvider":"firstParty"}`, "signed_in"},
		{`{"apiProvider":"vertex"}`, "signed_in"},
		{`{"subscriptionType":"max"}`, nil},
		{`{"apiProvider":"somewhere"}`, nil},
		{`{"apiProvider":"none"}`, nil},
		{`{"subscriptionType":"max","tokenSource":7,"apiProvider":"firstParty"}`, nil},
		{`{"subscriptionType":"max","apiKeySource":null,"apiProvider":"firstParty"}`, nil},
		{`{"tokenSource":"none","apiKeySource":null,"apiProvider":"firstParty"}`, nil},
		{`{"tokenSource":"none","subscriptionType":null,"apiProvider":"firstParty"}`, nil},
		{`{"TokenSource":"none","apiProvider":"firstParty"}`, nil},
		{`false`, nil},
		{`{"tokenSource":"claude.ai","apiProvider":"firstParty"}`, "signed_in"},
		{`{"tokenSource":"none","apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty"}`, "signed_in"},
		{`{"tokenSource":"none","apiProvider":"bedrock"}`, "signed_in"},
		{`{"tokenSource":"none","subscriptionType":"pro","apiProvider":"firstParty"}`, "signed_in"},
		{`{"tokenSource":"none","apiProvider":"firstParty"}`, "signed_out"},
		{`{"apiKeySource":"none","tokenSource":"none","apiProvider":"firstParty"}`, nil},
		{`{"subscriptionType":"","apiProvider":"firstParty"}`, nil},
		{`{"apiProvider":"firstParty"}`, nil},
		{`{"tokenSource":"none"}`, nil},
		{`{"tokenSource":7}`, nil},
		{`{}`, nil},
		{`null`, nil},
		{``, nil},
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
			// A running harness's listing reads no account, so it says none.
			s.send(map[string]any{"t": "models", "id": "m2"})
			if got := s.expect("models"); got["account"] != nil {
				t.Fatalf("a listing that read no account says none: %v", got)
			}
		})
	}
}

// A listing with no harness running is refused in the signed-out
// sentence only on the one shape a harness with no sign-in answers; any
// other `account`, an unknown or absent one among them, lists.
func TestAListingOfAHarnessWithNoSignInIsRefused(t *testing.T) {
	for _, c := range []struct {
		account string
		out     bool
	}{
		{`{"tokenSource":"none","apiProvider":"firstParty"}`, true},
		{`{"tokenSource":"none","apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty"}`, false},
		{`{"tokenSource":"claude.ai","apiProvider":"firstParty"}`, false},
		{`{"tokenSource":"none","apiProvider":"bedrock"}`, false},
		{`{"tokenSource":"none"}`, false},
		{`{"apiProvider":"firstParty"}`, false},
		{`null`, false},
		{``, false},
	} {
		t.Run(c.account, func(t *testing.T) {
			s := startDriver(t)
			t.Setenv("FAKE_ACCOUNT", c.account)
			s.expect("hello")
			s.send(map[string]any{"t": "models", "id": "m1"})
			if !c.out {
				if listed := s.expect("models"); len(listed["models"].([]any)) != 3 {
					t.Fatalf("the harness's listing: %v", listed)
				}
				return
			}
			refused := s.expect("refused")
			if refused["id"] != "m1" || refused["reason"] != signedOutSentence {
				t.Fatalf("a harness with no sign-in has its listing refused in the signed-out sentence: %v", refused)
			}
		})
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
	if err := os.WriteFile(transcript, []byte(`{"type":"user","text":"the session"}`+"\n"), 0o600); err != nil {
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
		filepath.Join(config, "projects", "-home-a", gone+".jsonl"):                    `{"type":"user","text":"the forgotten session"}`,
		filepath.Join(config, "projects", "-home-a", gone, "subagents", "agent.jsonl"): `{"type":"user","text":"its subagent"}`,
		filepath.Join(config, "projects", "-home-b", gone+".jsonl"):                    `{"type":"user","text":"the same session from another folder"}`,
		filepath.Join(config, "session-env", gone, "env"):                              "its environment",
		filepath.Join(config, "session-env", kept, "env"):                              "another session's environment",
		filepath.Join(config, "projects", "-home-a", kept+".jsonl"):                    `{"type":"user","text":"another session"}`,
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

// A session's plan files go with its transcript: the ones its slug names,
// in the harness's plans folder and in the folder its plan-mode reminders
// name, a subagent's among them; another session's, a file whose name
// only begins with the slug, and the sign-in stay. A plans folder or a
// transcript that cannot be read may hide one: forget refuses, and both
// are there until it can look.
func TestForgetRemovesTheSessionsPlanFiles(t *testing.T) {
	s := startDriver(t)
	config := filepath.Join(s.home, ".claude")
	plans := filepath.Join(config, "plans")
	moved := filepath.Join(s.home, "work", ".plans")
	gone := "6b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	kept := "7b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	entry := func(slug string, fields map[string]any) string {
		fields["slug"] = slug
		line, _ := json.Marshal(fields)
		return string(line) + "\n"
	}
	transcript := filepath.Join(config, "projects", "-home-a", gone+".jsonl")
	files := map[string]string{
		transcript: "\n" + entry("brave-otter", map[string]any{"type": "user", "uuid": "u1"}) +
			entry("brave-otter", map[string]any{"type": "attachment", "attachment": map[string]any{"type": "plan_mode", "planFilePath": filepath.Join(moved, "brave-otter.md")}}),
		filepath.Join(config, "projects", "-home-a", kept+".jsonl"): entry("calm-fox", map[string]any{"type": "user"}),
		filepath.Join(plans, "brave-otter.md"):                      "the forgotten session's plan",
		filepath.Join(plans, "brave-otter-agent-a1b2.md"):           "its subagent's plan",
		filepath.Join(moved, "brave-otter.md"):                      "its plan where the project's settings put plans",
		filepath.Join(plans, "calm-fox.md"):                         "another session's plan",
		filepath.Join(plans, "brave-otterish.md"):                   "a plan whose slug only begins so",
		filepath.Join(config, ".credentials.json"):                  "the sign-in",
	}
	for path, body := range files {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	removed := map[string]bool{
		transcript:                             true,
		filepath.Join(plans, "brave-otter.md"): true,
		filepath.Join(plans, "brave-otter-agent-a1b2.md"): true,
		filepath.Join(moved, "brave-otter.md"):            true,
	}
	present := func(path string) bool {
		_, err := os.Stat(path)
		return err == nil
	}
	s.expect("hello")
	if os.Geteuid() != 0 {
		for i, unreadable := range []string{plans, moved, transcript} {
			if err := os.Chmod(unreadable, 0); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(unreadable, 0o700) })
			id := fmt.Sprintf("obx_%d", i+1)
			s.send(map[string]any{"t": "forget", "id": id, "session": gone})
			if e := s.expect("refused"); e["id"] != id {
				t.Fatalf("%s past inspection is no proof the plan files are gone: %v", unreadable, e)
			}
			if err := os.Chmod(unreadable, 0o700); err != nil {
				t.Fatal(err)
			}
			for path := range files {
				if !present(path) {
					t.Fatalf("a refused forget removes nothing: %s", path)
				}
			}
		}
	}
	s.send(map[string]any{"t": "forget", "id": "obx_4", "session": gone})
	if e := s.expect("forgot"); e["id"] != "obx_4" {
		t.Fatalf("the session and its plan files are forgotten: %v", e)
	}
	for path := range files {
		if present(path) == removed[path] {
			t.Fatalf("only the forgotten session's transcript and plan files go: %s (present %v)", path, present(path))
		}
	}
}

// forgetIn answers a forget of `session` in `home`, by the driver's own
// forget, with no harness run.
func forgetIn(t *testing.T, home, session string) string {
	t.Helper()
	var out, errs bytes.Buffer
	d := newDriver([]string{"unused"}, brainwire.NewConn(driverName, &out, &errs), home).(*driver)
	if err := d.forget("obx_tie", session); err != nil {
		t.Fatal(err)
	}
	var e map[string]any
	if err := json.Unmarshal(out.Bytes(), &e); err != nil {
		t.Fatal(err)
	}
	return e["t"].(string)
}

func writeAll(t *testing.T, files map[string]string) {
	t.Helper()
	for path, body := range files {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// #10196's second finding: a tie that does not read is no proof of
// absence. A transcript line that is no entry, an attachment that is no
// object, a planFilePath that is no string, in the session's transcript or
// its helper's: forget refuses and removes nothing.
func TestForgetRefusesAPlanTieThatDoesNotRead(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	session := "6b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	slug := `{"type":"user","slug":"brave-otter"}` + "\n"
	for name, broken := range map[string]string{
		"a truncated line":                          `{"type":"attachment","slug":"brave-otter","attachment":{"type":"plan_mode","planFilePath":`,
		"an attachment that is no object":           `{"type":"system","slug":"brave-otter","attachment":"plan_mode"}` + "\n",
		"a planFilePath that is no string":          `{"type":"attachment","slug":"brave-otter","attachment":{"type":"plan_mode","planFilePath":42}}` + "\n",
		"a null line":                               "null\n",
		"a null planFilePath":                       `{"type":"attachment","slug":"brave-otter","attachment":{"type":"plan_mode","planFilePath":null}}` + "\n",
		"a null slug":                               `{"type":"user","slug":null}` + "\n",
		"a null attachment on an attachment record": `{"type":"attachment","slug":"brave-otter","attachment":null}` + "\n",
		"an attachment record with no attachment":   `{"type":"attachment","slug":"brave-otter"}` + "\n",
	} {
		for _, where := range []string{"session", "helper"} {
			home := t.TempDir()
			project := filepath.Join(home, ".claude", "projects", "-work")
			files := map[string]string{
				filepath.Join(project, session+".jsonl"):                             slug,
				filepath.Join(home, "work", ".plans", "brave-otter.md"):              "the session's plan",
				filepath.Join(project, session, "subagents", "agent-a1234567.jsonl"): slug,
			}
			if where == "session" {
				files[filepath.Join(project, session+".jsonl")] += broken
			} else {
				files[filepath.Join(project, session, "subagents", "agent-a1234567.jsonl")] += broken
			}
			writeAll(t, files)
			if got := forgetIn(t, home, session); got != "refused" {
				t.Fatalf("%s in the %s's transcript: forget answers %s", name, where, got)
			}
			for path := range files {
				if _, err := os.Stat(path); err != nil {
					t.Fatalf("%s in the %s's transcript: a refused forget removes nothing: %v", name, where, err)
				}
			}
		}
	}
}

// #10222's first finding: only a regular file or a folder among the
// session's paths is the session's own. A helper's transcript, or the
// session's own, that is a link (here to a file naming another session's
// slug), and a plan file the slug names that is a link, each refuse the
// forget, which removes nothing: another session's plan and the link's
// target stay.
func TestForgetRefusesALinkAmongTheSessionsPaths(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	session := "6b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	for _, link := range []string{"the helper's transcript", "the session's transcript", "the plan file"} {
		home := t.TempDir()
		project := filepath.Join(home, ".claude", "projects", "-work")
		transcript := filepath.Join(project, session+".jsonl")
		helper := filepath.Join(project, session, "subagents", "agent-a1234567.jsonl")
		plans := filepath.Join(home, ".claude", "plans")
		other := filepath.Join(home, "elsewhere", "other.jsonl")
		target := filepath.Join(home, "elsewhere", "own-session.md")
		files := map[string]string{
			other:                                    `{"type":"user","slug":"other-session"}` + "\n",
			filepath.Join(plans, "other-session.md"): "another session's plan",
			target:                                   "what the link stands for",
			helper:                                   `{"type":"user","slug":"own-session"}` + "\n",
			transcript:                               `{"type":"user","slug":"own-session"}` + "\n",
			filepath.Join(plans, "own-session.md"):   "the session's plan",
		}
		linked := map[string]string{"the helper's transcript": helper, "the session's transcript": transcript, "the plan file": filepath.Join(plans, "own-session.md")}[link]
		delete(files, linked)
		writeAll(t, files)
		points := other
		if link == "the plan file" {
			points = target
		}
		if err := os.MkdirAll(filepath.Dir(linked), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(points, linked); err != nil {
			t.Fatal(err)
		}
		if got := forgetIn(t, home, session); got != "refused" {
			t.Fatalf("%s a link: forget answers %s", link, got)
		}
		for path := range files {
			if _, err := os.Stat(path); err != nil {
				t.Fatalf("%s a link: a refused forget removes nothing: %v", link, err)
			}
		}
		if _, err := os.Lstat(linked); err != nil {
			t.Fatalf("%s a link: the link stays: %v", link, err)
		}
	}
}

// #10196's third finding: a helper's transcript can hold the only tie to
// a plan file, in a folder the project's settings moved. Forget reads it
// before the session's folder goes, and removes the helper's plan; a
// helper's transcript that cannot be read refuses.
func TestForgetReadsTheHelpersTranscriptsForTheirPlanFiles(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	session := "6b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	home := t.TempDir()
	project := filepath.Join(home, ".claude", "projects", "-work")
	helper := filepath.Join(project, session, "subagents", "agent-a1234567.jsonl")
	plan := filepath.Join(home, "work", ".plans", "brave-otter-agent-a1234567.md")
	attachment, _ := json.Marshal(map[string]any{"type": "attachment", "slug": "brave-otter", "attachment": map[string]any{"type": "plan_mode", "planFilePath": plan}})
	writeAll(t, map[string]string{
		filepath.Join(project, session+".jsonl"): `{"type":"user","slug":"brave-otter"}` + "\n",
		helper:                                   string(attachment) + "\n",
		plan:                                     "the helper's plan",
	})
	if os.Geteuid() != 0 {
		if err := os.Chmod(helper, 0); err != nil {
			t.Fatal(err)
		}
		if got := forgetIn(t, home, session); got != "refused" {
			t.Fatalf("a helper's transcript that cannot be read refuses: %s", got)
		}
		if err := os.Chmod(helper, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if got := forgetIn(t, home, session); got != "forgot" {
		t.Fatalf("the session is forgotten: %s", got)
	}
	if _, err := os.Stat(plan); !os.IsNotExist(err) {
		t.Fatalf("the helper's plan goes with the session: %v", err)
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

// A harness that does not start says why on the driver's standard error
// alone: its command's path may name the folder, and the refusal of a
// listing, and the start's end, carry none of it to the wire.
func TestALaunchThatFailsNamesNoFolderOnTheWire(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	s := startDriverWith(t, home, []string{filepath.Join(home, "FOLDER-CANARY", "no-such-claude")})
	s.expect("hello")
	s.send(map[string]any{"t": "models", "id": "m1"})
	if e := s.expect("refused"); e["id"] != "m1" || e["reason"] != "Claude Code did not list its models: it did not start." {
		t.Fatalf("a listing whose harness did not start is refused in the driver's words: %v", e)
	}
	s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{}})
	if status := s.end(); status != 1 {
		t.Fatalf("a start whose harness did not start ends the driver: %d", status)
	}
	if strings.Contains(s.output(), "FOLDER-CANARY") {
		t.Fatalf("nothing of the harness's command reaches the wire: %s", s.output())
	}
	if n := strings.Count(s.stderr.String(), "FOLDER-CANARY/no-such-"); n != 4 {
		t.Fatalf("each launch's detail, the command and the system's words on it, is on the driver's standard error (a positive control for the check above): %d in %q", n, s.stderr.String())
	}
}

// modesOf is the fake's answer to "modes": its whole command line and the
// driver's two whole answers, to its own Write and Bash.
func modesOf(t *testing.T, s *wireSession, id string) (argv []any, answers []any) {
	t.Helper()
	postText(s, id, "modes")
	var got struct {
		Argv    []any `json:"argv"`
		Answers []any `json:"answers"`
	}
	said := ""
	for _, e := range s.until("idle") {
		if e["t"] == "ask" {
			t.Fatalf("the harness's own tools are never CYFR's to ask about: %v", e)
		}
		if e["t"] == "said" {
			said = e["text"].(string)
		}
	}
	if err := json.Unmarshal([]byte(said), &got); err != nil {
		t.Fatalf("the fake said its command line and answers: %q", said)
	}
	return got.Argv, got.Answers
}

func permissionAnswer(id string, response map[string]any) any {
	return map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": id, "response": response}}
}

func strs(xs ...string) []any {
	out := make([]any, len(xs))
	for i, x := range xs {
		out[i] = x
	}
	return out
}

// A start runs Claude Code in the access it names, or in the first the
// driver lists when it names none, a resume as a fresh start: Default
// mode, the harness's default permission mode, its own tools allowed.
// Both are seen whole: the harness's command line and the driver's
// answers.
func TestAStartRunsInItsAccessAndAllowsTheHarnessesOwnTools(t *testing.T) {
	write := map[string]any{"file_path": "/work/new.txt", "content": "x"}
	bash := map[string]any{"command": "touch new.txt"}
	allowed := []any{
		permissionAnswer("ask-1", map[string]any{"behavior": "allow", "updatedInput": write}),
		permissionAnswer("ask-2", map[string]any{"behavior": "allow", "updatedInput": bash}),
	}
	for name, config := range map[string]map[string]any{
		"absent":  {"model": "fake-opus"},
		"default": {"model": "fake-opus", "access": "default"},
	} {
		s := startDriver(t)
		session := startFresh(s, config)
		work(s, "stp_work", []any{})
		argv, answers := modesOf(t, s, "stp_post")
		want := append(strs(baseArgv...), strs("--session-id", session, "--model", "fake-opus", "--permission-mode", "default")...)
		if !reflect.DeepEqual(argv, want) {
			t.Fatalf("%s: the harness starts with exactly\n%v\nnot\n%v", name, want, argv)
		}
		if !reflect.DeepEqual(answers, allowed) {
			t.Fatalf("%s: the driver allows the harness's own tools exactly\n%v\nnot\n%v", name, allowed, answers)
		}
		s.end()

		again := startDriverIn(t, s.home)
		again.expect("hello")
		again.send(map[string]any{"t": "start", "gen": 3, "session": session, "config": config})
		again.expect("started")
		work(again, "stp_work_2", []any{})
		argv, answers = modesOf(t, again, "stp_post_2")
		want = append(strs(baseArgv...), strs("--resume", session, "--model", "fake-opus", "--permission-mode", "default")...)
		if !reflect.DeepEqual(argv, want) || !reflect.DeepEqual(answers, allowed) {
			t.Fatalf("%s: a resume starts and answers as the fresh start did: %v %v", name, argv, answers)
		}
		again.end()
	}
}

// A start naming an access the driver does not list, fresh or resuming,
// ends it with 2 before it starts any harness, writing only its ending,
// `unfit`, and saying why on its standard error. The harness's command names nothing here, so
// a start of it would say it did not start, as the listed access's does.
func TestAStartNamingAnAccessTheDriverDoesNotListEndsIt(t *testing.T) {
	session := "3b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
	for name, start := range map[string]map[string]any{
		"an empty access":        {"t": "start", "gen": 0, "config": map[string]any{"access": ""}},
		"another mode":           {"t": "start", "gen": 0, "config": map[string]any{"access": "bypassPermissions"}},
		"another driver's":       {"t": "start", "gen": 0, "config": map[string]any{"access": "full-access"}},
		"a resume of another":    {"t": "start", "gen": 0, "session": session, "config": map[string]any{"access": "plan"}},
		"a case it does not use": {"t": "start", "gen": 0, "config": map[string]any{"access": "Default"}},
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
		if got := s.stderr.String(); got != "cyfr-claude-code: "+unlistedAccess+"\n" {
			t.Fatalf("%s: the driver says why, and starts nothing: %q", name, got)
		}
	}
	s := startDriverWith(t, t.TempDir(), []string{filepath.Join(t.TempDir(), "no-such-harness")})
	s.expect("hello")
	s.send(map[string]any{"t": "start", "gen": 0, "config": map[string]any{"access": "default"}})
	if status := s.end(); status != 1 || !strings.Contains(s.stderr.String(), "cyfr-claude-code: the harness did not start") {
		t.Fatalf("the listed access starts the harness (a positive control): %d %q", status, s.stderr.String())
	}
	if s.why() != "unrunnable" {
		t.Fatalf("a harness that could not be run tells the holder unrunnable: %s", s.output())
	}
}

// Claude Code replays the system prompt a session was first started with
// unless its snapshot is off, so every start, a resume's too, turns it off
// and carries the instructions of that start.
func TestEveryStartHandsOverItsOwnInstructions(t *testing.T) {
	s := startDriver(t)
	s.expect("hello")
	session := ""
	for i, system := range []string{"be brief", "be thorough", "be thorough"} {
		if i > 0 {
			s.end()
			s = startDriverIn(t, s.home)
			s.expect("hello")
		}
		start := map[string]any{"t": "start", "gen": 3, "config": map[string]any{}, "system": system}
		if session != "" {
			start["session"] = session
		}
		s.send(start)
		session = s.expect("started")["session"].(string)
		work(s, "stp_work", []any{})
		postText(s, fmt.Sprintf("stp_post_%d", i), "handed")
		var got map[string]any
		for _, e := range s.until("idle") {
			if e["t"] == "said" {
				if err := json.Unmarshal([]byte(e["text"].(string)), &got); err != nil {
					t.Fatal(err)
				}
			}
		}
		want := map[string]any{"subtype": "initialize", "systemPromptSnapshot": false, "appendSystemPrompt": system}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("start %d initializes with exactly %v, not %v", i, want, got)
		}
	}
}
