// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package toolsock

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"testing"
	"time"
)

func listen(t *testing.T) (string, *net.UnixListener) {
	t.Helper()
	name := fmt.Sprintf("toolsock-test-%d-%s", os.Getpid(), t.Name())
	l, err := Listen(name)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = l.Close() })
	if err := l.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		t.Fatal(err)
	}
	return name, l
}

// serveOne answers the listener's next connection with answer, and sends
// the request it read, or the error reading it, on the channels.
func serveOne(l *net.UnixListener, answer any) (<-chan Request, <-chan error) {
	requests, errs := make(chan Request, 1), make(chan error, 1)
	go func() {
		conn, err := Accept(l)
		if err != nil {
			errs <- err
			return
		}
		r, err := ReadRequest(conn)
		if err != nil {
			_ = conn.Close()
			errs <- err
			return
		}
		requests <- r
		errs <- WriteAnswer(conn, answer)
	}()
	return requests, errs
}

func TestAListAndACallCrossTheSocket(t *testing.T) {
	name, l := listen(t)
	tools := []Tool{{Name: "files", Description: "Read the athanor's files", InputSchema: json.RawMessage(`{"type":"object"}`)}}
	requests, errs := serveOne(l, Listing{Tools: tools})
	var listing Listing
	if err := Ask(name, Request{Op: "list"}, &listing); err != nil {
		t.Fatalf("ask list: %v", err)
	}
	if r := <-requests; r.Op != "list" {
		t.Fatalf("the list as asked: %+v", r)
	}
	if err := <-errs; err != nil {
		t.Fatal(err)
	}
	if len(listing.Tools) != 1 || listing.Tools[0].Name != "files" || listing.Tools[0].Description != "Read the athanor's files" ||
		string(listing.Tools[0].InputSchema) != `{"type":"object"}` {
		t.Fatalf("the listing as answered: %+v", listing)
	}

	requests, errs = serveOne(l, Result{Text: "denied", IsError: true})
	var result Result
	if err := Ask(name, Request{Op: "call", Name: "files", Arguments: json.RawMessage(`{"path":"a.txt"}`)}, &result); err != nil {
		t.Fatalf("ask call: %v", err)
	}
	if r := <-requests; r.Op != "call" || r.Name != "files" || string(r.Arguments) != `{"path":"a.txt"}` {
		t.Fatalf("the call as asked: %+v %s", r, r.Arguments)
	}
	if err := <-errs; err != nil {
		t.Fatal(err)
	}
	if result != (Result{Text: "denied", IsError: true}) {
		t.Fatalf("the result as answered: %+v", result)
	}
}

func TestARequestOfNoKindIsRefused(t *testing.T) {
	name, l := listen(t)
	for _, r := range []Request{{Op: "run"}, {Op: "call"}, {}} {
		_, errs := serveOne(l, Result{})
		var result Result
		if err := Ask(name, r, &result); err == nil {
			t.Fatalf("%+v: the asker sees the connection close unanswered", r)
		}
		if err := <-errs; err == nil {
			t.Fatalf("%+v: refused expected", r)
		}
	}
}

func TestASecondListenerOfOneNameFails(t *testing.T) {
	name, _ := listen(t)
	if second, err := Listen(name); err == nil {
		_ = second.Close()
		t.Fatal("a second listener of one name in one space")
	}
}
