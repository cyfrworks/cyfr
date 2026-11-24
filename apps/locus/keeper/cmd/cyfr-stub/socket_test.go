// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/toolsock"
)

// driver is a test listener standing in for the brain driver's socket.
func driver(t *testing.T) (string, *net.UnixListener) {
	t.Helper()
	name := fmt.Sprintf("cyfr-stub-test-%d-%s", os.Getpid(), t.Name())
	l, err := toolsock.Listen(name)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = l.Close() })
	if err := l.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		t.Fatal(err)
	}
	return name, l
}

// held is one request the driver holds, answered when the test says.
func held(t *testing.T, l *net.UnixListener) (toolsock.Request, net.Conn) {
	t.Helper()
	conn, err := toolsock.Accept(l)
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	r, err := toolsock.ReadRequest(conn)
	if err != nil {
		t.Fatalf("read request: %v", err)
	}
	return r, conn
}

// stub is a socket-mode stub on pipes: send writes one message, next reads
// one answer, and closing the input ends serve, whose error comes on done.
type stub struct {
	in   *io.PipeWriter
	out  *bufio.Scanner
	done chan error
}

func startStub(t *testing.T, name string) *stub {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &stub{in: inW, out: bufio.NewScanner(outR), done: make(chan error, 1)}
	go func() {
		err := serveSource(inR, outW, socket(name))
		_ = outW.Close()
		s.done <- err
	}()
	t.Cleanup(func() { _ = inW.Close(); _ = outR.Close() })
	return s
}

func (s *stub) send(t *testing.T, message string) {
	t.Helper()
	if _, err := io.WriteString(s.in, message+"\n"); err != nil {
		t.Fatalf("send: %v", err)
	}
}

func (s *stub) next(t *testing.T) map[string]any {
	t.Helper()
	if !s.out.Scan() {
		t.Fatalf("no answer: %v", s.out.Err())
	}
	var answer map[string]any
	if err := json.Unmarshal(s.out.Bytes(), &answer); err != nil {
		t.Fatalf("a line that is no JSON: %q", s.out.Text())
	}
	return answer
}

func (s *stub) close(t *testing.T) {
	t.Helper()
	_ = s.in.Close()
	if s.out.Scan() {
		t.Fatalf("an answer past the last: %q", s.out.Text())
	}
	if err := <-s.done; err != nil {
		t.Fatalf("serve: %v", err)
	}
}

func TestSocketModeListsWhatTheDriverListsAtEachListing(t *testing.T) {
	name, l := driver(t)
	s := startStub(t, name)
	for _, tools := range [][]toolsock.Tool{
		{{Name: "files", Description: "Read the athanor's files", InputSchema: json.RawMessage(`{"type":"object"}`)}},
		{{Name: "files", Description: "Read the athanor's files", InputSchema: json.RawMessage(`{"type":"object"}`)},
			{Name: "github__create_issue", Description: "Open an issue", InputSchema: json.RawMessage(`{"type":"object","properties":{"title":{"type":"string"}}}`)}},
	} {
		s.send(t, `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`)
		r, conn := held(t, l)
		if r.Op != "list" {
			t.Fatalf("a listing asks the socket for a list: %+v", r)
		}
		if err := toolsock.WriteAnswer(conn, toolsock.Listing{Tools: tools}); err != nil {
			t.Fatal(err)
		}
		listed, _ := json.Marshal(s.next(t)["result"].(map[string]any)["tools"])
		want, _ := json.Marshal(tools)
		var a, b any
		_ = json.Unmarshal(listed, &a)
		_ = json.Unmarshal(want, &b)
		if fmt.Sprint(a) != fmt.Sprint(b) {
			t.Fatalf("listed %s, the driver answered %s", listed, want)
		}
	}
	s.close(t)
}

func TestSocketModePassesACallWholeAndAnswersTheDriversResult(t *testing.T) {
	name, l := driver(t)
	s := startStub(t, name)
	s.send(t, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"files","arguments":{"path":"a.txt","depth":2}}}`)
	r, conn := held(t, l)
	if r.Op != "call" || r.Name != "files" || string(r.Arguments) != `{"path":"a.txt","depth":2}` {
		t.Fatalf("the call as the harness made it: %+v %s", r, r.Arguments)
	}
	if err := toolsock.WriteAnswer(conn, toolsock.Result{Text: "line one", IsError: false}); err != nil {
		t.Fatal(err)
	}
	answer := s.next(t)
	if text, isError := textOf(t, answer); text != "line one" || isError || answer["id"].(float64) != 3 {
		t.Fatalf("the driver's result under the call's id: %v", answer)
	}
	s.send(t, `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"files","arguments":{}}}`)
	_, conn = held(t, l)
	if err := toolsock.WriteAnswer(conn, toolsock.Result{Text: "Denied by the person.", IsError: true}); err != nil {
		t.Fatal(err)
	}
	if text, isError := textOf(t, s.next(t)); text != "Denied by the person." || !isError {
		t.Fatalf("the driver's error as an error: %q %v", text, isError)
	}
	s.close(t)
}

func TestSocketModeAnswersTwoCallsAtOnceEachItsOwn(t *testing.T) {
	name, l := driver(t)
	s := startStub(t, name)
	// One write, so the stub's input takes both whatever it does with the
	// first.
	s.send(t, `{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"files","arguments":{"n":5}}}`+"\n"+
		`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"files","arguments":{"n":6}}}`)
	// Both are held at the driver before either is answered: the second
	// reaches the socket while the first waits.
	first, firstConn := held(t, l)
	second, secondConn := held(t, l)
	conns := map[string]net.Conn{string(first.Arguments): firstConn, string(second.Arguments): secondConn}
	for _, n := range []string{"6", "5"} {
		if err := toolsock.WriteAnswer(conns[`{"n":`+n+`}`], toolsock.Result{Text: "answer " + n}); err != nil {
			t.Fatal(err)
		}
		answer := s.next(t)
		if text, _ := textOf(t, answer); text != "answer "+n || fmt.Sprint(answer["id"]) != n {
			t.Fatalf("call %s answered %v", n, answer)
		}
	}
	s.close(t)
}

func TestSocketModeWithNoDriverAnswersThatCyfrsToolsAreNotReachable(t *testing.T) {
	s := startStub(t, fmt.Sprintf("cyfr-stub-test-%d-none", os.Getpid()))
	s.send(t, `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"files","arguments":{}}}`)
	if text, isError := textOf(t, s.next(t)); !isError || text != unreachable {
		t.Fatalf("a call with no driver: %q %v", text, isError)
	}
	s.send(t, `{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}`)
	answer := s.next(t)
	rpcErr, ok := answer["error"].(map[string]any)
	if !ok || rpcErr["message"] != unreachable {
		t.Fatalf("a listing with no driver: %v", answer)
	}
	s.send(t, `{"jsonrpc":"2.0","id":9,"method":"ping"}`)
	if _, ok := s.next(t)["result"].(map[string]any); !ok {
		t.Fatal("the stub still answers after an unreachable socket")
	}
	if !strings.Contains(unreachable, "CYFR's tools") {
		t.Fatalf("the words name CYFR's tools: %q", unreachable)
	}
	s.close(t)
}
