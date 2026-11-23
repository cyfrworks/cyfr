// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package desktop is the cyfr side of the CYFR app: the private messages
// between the app's main process and the cyfr program it starts
// (tests/fixtures/desktop-process.json), and the service that program runs,
// the chooser pages and the device's pages on literal loopback.
package desktop

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/signal"
	"slices"
	"sync"
	"syscall"
)

// Version is the one version of the messages: every message carries it,
// and a message without it or with another is refused.
const Version = 1

// MaxLine bounds one message line in either direction.
const MaxLine = 64 << 10

// The messages cyfr sends the app's main process.
const (
	// Ready names the first page: the chooser, its run token in the
	// fragment.
	TypeReady = "ready"
	// Home names the CYFR selected, the account service approved for it and
	// how to reach it, as a numbered attempt; main answers the attempt it
	// holds current, home-ready or home-failed, with its number.
	TypeHome = "home"
	// Opened says cyfr committed the CYFR home proposed: main holds it as
	// selected from then on, and until then takes cyfr's next proposal.
	TypeOpened = "opened"
	// Locked says the device locked, naming the CYFR cyfr holds committed,
	// if any, as home names one: main's lock waits for it, and main keeps
	// to that CYFR, or none, from then on.
	TypeLocked = "locked"
	// PickFolder asks main for a folder (reserved: nothing sends it yet).
	TypePickFolder = "pick-folder"
)

// The messages the app's main process sends cyfr.
const (
	TypeHomeReady = "home-ready"
	// HomeFailed says main could not make what it keeps that CYFR's own:
	// the attempt it numbers opens nothing. It is no lock.
	TypeHomeFailed = "home-failed"
	TypeLock       = "lock"
	// Leave locks and lets go of the CYFR committed: main sends it once it
	// cleared what it kept of that CYFR, and cyfr's locked then names none.
	TypeLeave        = "leave"
	TypeShutdown     = "shutdown"
	TypeFolderPicked = "folder-picked"
)

// fields is each message's fields beyond version and type, those that may
// be absent marked optional.
var fields = map[string]struct{ required, optional []string }{
	TypeReady:        {required: []string{"url"}},
	TypeHome:         {required: []string{"home", "account", "attempt"}, optional: []string{"proxy", "resolver"}},
	TypeOpened:       {required: []string{"home"}},
	TypeLocked:       {optional: []string{"home", "account", "proxy", "resolver"}},
	TypePickFolder:   {required: []string{"id", "suggested"}},
	TypeHomeReady:    {required: []string{"home", "attempt"}},
	TypeHomeFailed:   {required: []string{"home", "attempt"}},
	TypeLock:         {},
	TypeLeave:        {},
	TypeShutdown:     {},
	TypeFolderPicked: {required: []string{"id", "path"}},
}

var fromMain = []string{TypeHomeReady, TypeHomeFailed, TypeLock, TypeLeave, TypeShutdown, TypeFolderPicked}

// Message is one message in either direction. Path is a folder-picked
// answer's folder, nil when the person cancelled. Attempt is a proposal's
// number, from 1.
type Message struct {
	Type      string
	URL       string
	Home      string
	Account   string
	Attempt   uint64
	Proxy     string
	Resolver  string
	ID        string
	Suggested string
	Path      *string
}

// Refusal is why a line is not a message this side reads.
type Refusal struct{ Reason string }

func (r *Refusal) Error() string { return "not a message from the app: " + r.Reason }

// ErrRefused matches every *Refusal.
var ErrRefused = errors.New("not a message from the app")

func (r *Refusal) Is(target error) bool { return target == ErrRefused }

func refuse(reason string) error { return &Refusal{Reason: reason} }

// ReadFromMain reads one line main sent: a JSON object of exactly its
// type's fields, version 1, of a type main sends.
func ReadFromMain(line []byte) (Message, error) {
	if len(line) > MaxLine {
		return Message{}, refuse("size")
	}
	var m map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(line))
	if dec.Decode(&m) != nil || m == nil || dec.Decode(new(json.RawMessage)) != io.EOF {
		return Message{}, refuse("shape")
	}
	v, ok := m["version"]
	if !ok {
		return Message{}, refuse("version")
	}
	if string(v) != "1" {
		return Message{}, refuse("version")
	}
	var typ string
	if json.Unmarshal(m["type"], &typ) != nil || !slices.Contains(fromMain, typ) {
		return Message{}, refuse("type")
	}
	want := fields[typ]
	if len(m) != 2+len(want.required) {
		return Message{}, refuse("fields")
	}
	msg := Message{Type: typ}
	for _, f := range want.required {
		raw, ok := m[f]
		if !ok {
			return Message{}, refuse("fields")
		}
		if f == "path" && string(raw) == "null" {
			continue
		}
		if f == "attempt" {
			if json.Unmarshal(raw, &msg.Attempt) != nil || msg.Attempt == 0 {
				return Message{}, refuse("fields")
			}
			continue
		}
		var s string
		if json.Unmarshal(raw, &s) != nil || s == "" {
			return Message{}, refuse("fields")
		}
		switch f {
		case "home":
			msg.Home = s
		case "id":
			msg.ID = s
		case "path":
			msg.Path = &s
		}
	}
	return msg, nil
}

// object is m as its line carries it.
func (m Message) object() (map[string]any, error) {
	want, ok := fields[m.Type]
	if !ok || slices.Contains(fromMain, m.Type) {
		return nil, fmt.Errorf("cyfr does not send %q", m.Type)
	}
	values := map[string]string{"url": m.URL, "home": m.Home, "account": m.Account, "proxy": m.Proxy,
		"resolver": m.Resolver, "id": m.ID, "suggested": m.Suggested}
	o := map[string]any{"version": Version, "type": m.Type}
	for _, f := range want.required {
		if f == "attempt" {
			if m.Attempt == 0 {
				return nil, fmt.Errorf("%s needs %s", m.Type, f)
			}
			o[f] = m.Attempt
			continue
		}
		if values[f] == "" {
			return nil, fmt.Errorf("%s needs %s", m.Type, f)
		}
		o[f] = values[f]
	}
	for _, f := range want.optional {
		if values[f] != "" {
			o[f] = values[f]
		}
	}
	return o, nil
}

// Writer sends cyfr's messages to main, one line each, whole, in the
// order they were given, by one writer of its own: Queue gives it a line
// and returns at once, so nothing that tells main waits on main reading
// its pipe. Once a write fails (main has gone, or its pipe ended), every
// later line is dropped: main's end is heard on its own pipe to cyfr.
type Writer struct {
	w io.Writer

	mu     sync.Mutex
	queue  [][]byte
	failed bool
	wake   chan struct{}
}

// NewWriter writes to w, main's end of the private pipe. A write to a pipe
// main closed is an error then, not the end of this process: SIGPIPE is
// ignored, so a lock goes on to end its sessions at the CYFR when main
// has gone.
func NewWriter(w io.Writer) *Writer {
	signal.Ignore(syscall.SIGPIPE)
	wr := &Writer{w: w, wake: make(chan struct{}, 1)}
	go wr.write()
	return wr
}

// Queue gives m to be written after every line given before it and
// returns at once; it refuses what is not one of cyfr's messages.
func (w *Writer) Queue(m Message) error {
	line, err := encode(m)
	if err != nil {
		return err
	}
	w.mu.Lock()
	w.queue = append(w.queue, line)
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
	return nil
}

// write writes what was given, in order, for as long as the process runs.
func (w *Writer) write() {
	for range w.wake {
		w.mu.Lock()
		lines := w.queue
		w.queue = nil
		w.mu.Unlock()
		for _, line := range lines {
			if !w.failed {
				_, err := w.w.Write(append(line, '\n'))
				w.failed = err != nil
			}
		}
	}
}

// encode is m as one line, refused where it is not one of cyfr's messages.
func encode(m Message) ([]byte, error) {
	o, err := m.object()
	if err != nil {
		return nil, err
	}
	return json.Marshal(o)
}
