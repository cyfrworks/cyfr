// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

// maxCDPMessage bounds one message from Chrome; a longer one is skipped
// whole, and the command it answered fails at its deadline.
const maxCDPMessage = 256 << 20

// errDetached fails what was under way in a window Chrome closed.
var errDetached = errors.New("the window was closed")

// cdpError is Chrome's refusal of a command.
type cdpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *cdpError) Error() string { return e.Message }

// cdp speaks the Chrome DevTools Protocol over Chrome's debugging pipe:
// each message one JSON object ended by a NUL byte. Commands to a window
// name its flattened session; events of the browser itself go to
// onTarget, a window's to the watches of its session.
type cdp struct {
	w   io.Writer
	wmu sync.Mutex

	mu      sync.Mutex
	next    int64
	calls   map[int64]*pending
	watches map[*watch]bool
	// err is set once the pipe is gone; every call fails with it after.
	err error

	onTarget func(method string, params json.RawMessage)
}

type pending struct {
	session string
	reply   chan cdpReply
}

type cdpReply struct {
	result json.RawMessage
	err    error
}

func newCDP(w io.Writer, r io.Reader, onTarget func(string, json.RawMessage)) *cdp {
	c := &cdp{w: w, calls: map[int64]*pending{}, watches: map[*watch]bool{}, onTarget: onTarget}
	go c.read(r)
	return c
}

// call sends one command and decodes its result into result, which may
// be nil.
func (c *cdp) call(ctx context.Context, session, method string, params, result any) error {
	c.mu.Lock()
	if c.err != nil {
		c.mu.Unlock()
		return c.err
	}
	c.next++
	id := c.next
	p := &pending{session: session, reply: make(chan cdpReply, 1)}
	c.calls[id] = p
	c.mu.Unlock()

	message := struct {
		ID        int64  `json:"id"`
		Method    string `json:"method"`
		Params    any    `json:"params,omitempty"`
		SessionID string `json:"sessionId,omitempty"`
	}{id, method, params, session}
	data, err := json.Marshal(message)
	if err == nil {
		c.wmu.Lock()
		_, err = c.w.Write(append(data, 0))
		c.wmu.Unlock()
	}
	if err != nil {
		c.forget(id)
		return err
	}
	select {
	case r := <-p.reply:
		if r.err != nil || result == nil {
			return r.err
		}
		return json.Unmarshal(r.result, result)
	case <-ctx.Done():
		c.forget(id)
		return ctx.Err()
	}
}

func (c *cdp) forget(id int64) {
	c.mu.Lock()
	delete(c.calls, id)
	c.mu.Unlock()
}

func (c *cdp) read(r io.Reader) {
	in := bufio.NewReaderSize(r, 64<<10)
	for {
		message, err := readMessage(in)
		if err != nil {
			c.fail(fmt.Errorf("the browser's pipe closed: %w", err))
			return
		}
		if message != nil {
			c.dispatch(message)
		}
	}
}

// readMessage reads up to the next NUL: the message, or nil for one past
// maxCDPMessage, which is skipped.
func readMessage(in *bufio.Reader) ([]byte, error) {
	var message []byte
	over := false
	for {
		part, err := in.ReadSlice(0)
		if !over && len(message)+len(part) > maxCDPMessage+1 {
			over, message = true, nil
		}
		if !over {
			message = append(message, part...)
		}
		switch {
		case err == nil && over:
			return nil, nil
		case err == nil:
			return message[:len(message)-1], nil
		case !errors.Is(err, bufio.ErrBufferFull):
			return nil, err
		}
	}
}

func (c *cdp) dispatch(data []byte) {
	var m struct {
		ID        int64           `json:"id"`
		Result    json.RawMessage `json:"result"`
		Error     *cdpError       `json:"error"`
		Method    string          `json:"method"`
		Params    json.RawMessage `json:"params"`
		SessionID string          `json:"sessionId"`
	}
	if json.Unmarshal(data, &m) != nil {
		return
	}
	if m.ID != 0 {
		c.mu.Lock()
		p := c.calls[m.ID]
		delete(c.calls, m.ID)
		c.mu.Unlock()
		if p != nil {
			if m.Error != nil {
				p.reply <- cdpReply{err: m.Error}
			} else {
				p.reply <- cdpReply{result: m.Result}
			}
		}
		return
	}
	if m.SessionID == "" {
		if m.Method == "Target.detachedFromTarget" {
			var detached struct {
				SessionID string `json:"sessionId"`
			}
			if json.Unmarshal(m.Params, &detached) == nil {
				c.detach(detached.SessionID)
			}
		}
		if c.onTarget != nil {
			c.onTarget(m.Method, m.Params)
		}
		return
	}
	c.mu.Lock()
	for w := range c.watches {
		if w.session == m.SessionID && w.match(m.Method, m.Params) {
			w.push(cdpEvent{m.Method, m.Params})
		}
	}
	c.mu.Unlock()
}

// detach fails every command and watch of a session Chrome ended.
func (c *cdp) detach(session string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for id, p := range c.calls {
		if p.session == session {
			delete(c.calls, id)
			p.reply <- cdpReply{err: errDetached}
		}
	}
	for w := range c.watches {
		if w.session == session {
			delete(c.watches, w)
			w.end(errDetached)
		}
	}
}

func (c *cdp) fail(err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.err = err
	for id, p := range c.calls {
		delete(c.calls, id)
		p.reply <- cdpReply{err: err}
	}
	for w := range c.watches {
		delete(c.watches, w)
		w.end(err)
	}
}

// watch holds the events of one session that match, from the moment it
// is made, so an event that arrives before its waiter looks is not lost.
type watch struct {
	session string
	match   func(method string, params json.RawMessage) bool

	mu     sync.Mutex
	events []cdpEvent
	err    error
	signal chan struct{}
}

func (c *cdp) watch(session string, match func(string, json.RawMessage) bool) *watch {
	w := &watch{session: session, match: match, signal: make(chan struct{}, 1)}
	c.mu.Lock()
	if c.err != nil {
		w.end(c.err)
	} else {
		c.watches[w] = true
	}
	c.mu.Unlock()
	return w
}

func (c *cdp) unwatch(w *watch) {
	c.mu.Lock()
	delete(c.watches, w)
	c.mu.Unlock()
}

// cdpEvent is one event of a window's session.
type cdpEvent struct {
	method string
	params json.RawMessage
}

func (w *watch) push(event cdpEvent) {
	w.mu.Lock()
	w.events = append(w.events, event)
	w.mu.Unlock()
	w.wake()
}

func (w *watch) end(err error) {
	w.mu.Lock()
	w.err = err
	w.mu.Unlock()
	w.wake()
}

func (w *watch) wake() {
	select {
	case w.signal <- struct{}{}:
	default:
	}
}

// drain takes every event the watch holds now.
func (w *watch) drain() []cdpEvent {
	w.mu.Lock()
	defer w.mu.Unlock()
	events := w.events
	w.events = nil
	return events
}

// next answers the next matching event, the error that ended the
// session, or ctx's error.
func (w *watch) next(ctx context.Context) (cdpEvent, error) {
	for {
		w.mu.Lock()
		if len(w.events) > 0 {
			event := w.events[0]
			w.events = w.events[1:]
			w.mu.Unlock()
			return event, nil
		}
		err := w.err
		w.mu.Unlock()
		if err != nil {
			return cdpEvent{}, err
		}
		select {
		case <-w.signal:
		case <-ctx.Done():
			return cdpEvent{}, ctx.Err()
		}
	}
}
