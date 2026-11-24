// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"net"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/toolsock"
)

// The tool socket: the driver is the one listener of toolsock's name in
// its space while its program runs, from before the program starts until
// it is closed. Each connection's one request is read in a goroutine of its
// own and handed to the loop (the driver's Inbox), so everything a request
// changes is the loop's; a connection held for an ask is answered by the
// `answer` command, with no clock of the driver's. A request handed in for
// a socket since closed is closed unanswered.

// requestWait bounds a connection's one request, and socketWrite an
// answer's write: the stub writes its request at once and reads its answer.
const (
	requestWait = 10 * time.Second
	socketWrite = 5 * time.Second
)

// closedSentence answers a call CYFR held when its session closed.
const closedSentence = "CYFR closed the session before this call was answered."

type toolSocket struct {
	l    *net.UnixListener
	quit chan struct{}
	held map[string]net.Conn
}

// listen binds the socket and accepts its connections until it is closed.
func (d *driver) listen() error {
	l, err := toolsock.Listen(d.socketName)
	if err != nil {
		return err
	}
	s := &toolSocket{l: l, quit: make(chan struct{}), held: map[string]net.Conn{}}
	d.sock = s
	go func() {
		for {
			conn, err := toolsock.Accept(l)
			if err != nil {
				return
			}
			go func() {
				_ = conn.SetReadDeadline(time.Now().Add(requestWait))
				r, err := toolsock.ReadRequest(conn)
				if err != nil {
					_ = conn.Close()
					return
				}
				handed := func() error { return d.socketRequest(s, conn, r) }
				select {
				case d.inbox <- handed:
				case <-s.quit:
					_ = conn.Close()
				}
			}()
		}
	}()
	return nil
}

func reply(conn net.Conn, answer any) error {
	_ = conn.SetWriteDeadline(time.Now().Add(socketWrite))
	return toolsock.WriteAnswer(conn, answer)
}

// socketRequest answers a listing with the start's tools, and shows a call
// as an ask, holding its connection; a call CYFR cannot show is answered an
// error at once, which the program reads.
func (d *driver) socketRequest(s *toolSocket, conn net.Conn, r toolsock.Request) error {
	if s != d.sock {
		_ = conn.Close()
		return nil
	}
	if r.Op == "list" {
		tools := make([]toolsock.Tool, 0, len(d.tools))
		for _, t := range d.tools {
			tools = append(tools, toolsock.Tool{Name: t.Name, Description: t.Description, InputSchema: t.Parameters})
		}
		_ = reply(conn, toolsock.Listing{Tools: tools})
		d.listed = true
		if st := d.starting; st != nil && st.stage == stageListing {
			return d.started(st)
		}
		return nil
	}
	arguments := r.Arguments
	// MCP's arguments are optional: none is an empty object.
	if len(arguments) == 0 || string(arguments) == "null" {
		arguments = json.RawMessage(`{}`)
	}
	refuse := func(text string) error {
		_ = reply(conn, toolsock.Result{Text: text, IsError: true})
		return nil
	}
	switch {
	case !d.running() || d.signedOut:
		return refuse("CYFR runs no call before its session has started.")
	case !isObject(arguments):
		return refuse("CYFR takes a call's arguments as one object.")
	}
	ask := brainwire.NewUUID()
	work := ""
	if d.turn != nil {
		work = d.turn.work
	}
	e := brainwire.NewEvent("ask").Set("gen", d.gen).SetOptional("work", work).
		Set("ask", ask).Set("name", r.Name).Set("arguments", arguments)
	if line, err := brainwire.EncodeEvent(e); err != nil || len(line) >= brainwire.MaxLineBytes {
		return refuse("This call's arguments are past what CYFR takes in one call; make it smaller.")
	}
	s.held[ask] = conn
	return d.c.Emit(e)
}

// answerAsk writes CYFR's answer to the call held as `ask`, and says
// whether a call was held under it and took the answer.
func (d *driver) answerAsk(ask, content string, isError bool) (held, written bool) {
	if d.sock == nil {
		return false, false
	}
	conn, ok := d.sock.held[ask]
	if !ok {
		return false, false
	}
	delete(d.sock.held, ask)
	return true, reply(conn, toolsock.Result{Text: content, IsError: isError}) == nil
}

// closeSocket stops accepting, answers every call still held an error and
// closes the listener: no request reaches a closed session's loop.
func (d *driver) closeSocket() {
	s := d.sock
	if s == nil {
		return
	}
	d.sock = nil
	close(s.quit)
	_ = s.l.Close()
	for _, conn := range s.held {
		_ = reply(conn, toolsock.Result{Text: closedSentence, IsError: true})
	}
}

func isObject(raw json.RawMessage) bool {
	var m map[string]json.RawMessage
	return json.Unmarshal(raw, &m) == nil && m != nil
}
