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
	"regexp"
	"slices"
	"strconv"
	"sync"
	"syscall"
)

// Version is the one version of the messages: every message carries it,
// and a message without it or with another is refused.
const Version = 2

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
	// Opened says cyfr committed the CYFR home proposed, naming it and its
	// attempt: main holds it as selected from then on, and until then
	// takes cyfr's next proposal.
	TypeOpened = "opened"
	// Locked says the device locked, naming the CYFR cyfr holds committed,
	// if any, as home names one: main's lock waits for it, and main keeps
	// to that CYFR, or none, from then on.
	TypeLocked = "locked"
	// Ending says the box's screen shell is ending: its last lock says it
	// in place of locked, and the shell says nothing after it. main closes
	// its windows at once and ends, opening nothing more for it.
	TypeEnding = "ending"
	// Left answers main's leave of the same id once cyfr let go of the
	// CYFR committed, every session of the device's there ended: it is the
	// one answer that ends a departure, and a locked is none.
	TypeLeft = "left"
)

// The messages the app's main process sends cyfr.
const (
	TypeHomeReady = "home-ready"
	// HomeFailed says main could not make what it keeps that CYFR's own:
	// the attempt it numbers opens nothing. It is no lock.
	TypeHomeFailed = "home-failed"
	TypeLock       = "lock"
	// Leave locks and lets go of the CYFR committed, numbered by main as
	// one departure of the run: main sends it once it cleared what it kept
	// of that CYFR, and cyfr answers left with its id, after the locked
	// its lock says, which then names none.
	TypeLeave    = "leave"
	TypeShutdown = "shutdown"
	// FolderPicked is main's answer to the person's pick of a folder (the
	// chooser's Change…): the folder, absolute, or none where the person
	// cancelled or the pick ended unanswered, with the epoch and the pick
	// the chooser asked it for, as its address named them. Main sends one
	// for each pick and none otherwise; the page that asked never names a
	// folder.
	TypeFolderPicked = "folder-picked"
)

// fields is each message's fields beyond version and type, those that may
// be absent marked optional.
var fields = map[string]struct{ required, optional []string }{
	TypeReady:        {required: []string{"url"}},
	TypeHome:         {required: []string{"home", "account", "attempt"}, optional: []string{"proxy", "resolver", "road"}},
	TypeOpened:       {required: []string{"home", "attempt"}},
	TypeLocked:       {optional: []string{"home", "account", "proxy", "resolver"}},
	TypeEnding:       {},
	TypeLeft:         {required: []string{"id"}},
	TypeHomeReady:    {required: []string{"home", "attempt"}},
	TypeHomeFailed:   {required: []string{"home", "attempt"}},
	TypeLock:         {},
	TypeLeave:        {required: []string{"id"}},
	TypeShutdown:     {},
	TypeFolderPicked: {required: []string{"path", "epoch", "pick"}},
}

var fromMain = []string{TypeHomeReady, TypeHomeFailed, TypeLock, TypeLeave, TypeShutdown, TypeFolderPicked}

// Message is one message in either direction. Path is a folder-picked
// answer's folder, nil when none was picked. Attempt is a proposal's
// number, from 1, and ID a departure's (leave and left), from 1.
type Message struct {
	Type     string
	URL      string
	Home     string
	Account  string
	Attempt  uint64
	ID       uint64
	Proxy    string
	Resolver string
	// Road is RoadDevice where the CYFR opens at the device's pages on
	// either road: one just set up, whose first person is made there.
	Road string
	Path *string
	// Epoch and Pick are what the chooser showed as it asked for the pick
	// a folder-picked answers: the time since a lock, and the picks
	// answered before it. cyfr takes only the answer to the pick asked
	// for now.
	Epoch, Pick uint64
}

// maxWhole is the largest whole number both sides read exactly, a
// JavaScript number's.
const maxWhole = 1<<53 - 1

// RoadDevice is home's road for a CYFR that opens at the device's pages.
const RoadDevice = "device"

// absolute is whether a folder-picked folder is spelled from a root, on
// any system the app runs on: /, a drive's letter, colon and separator, or
// a share's two backslashes (process.js absolute).
var absolute = regexp.MustCompile(`^(/|\\\\|[A-Za-z]:[\\/])`).MatchString

// Refusal is why a line is not a message this side reads.
type Refusal struct{ Reason string }

func (r *Refusal) Error() string { return "not a message from the app: " + r.Reason }

// ErrRefused matches every *Refusal.
var ErrRefused = errors.New("not a message from the app")

func (r *Refusal) Is(target error) bool { return target == ErrRefused }

func refuse(reason string) error { return &Refusal{Reason: reason} }

// ReadFromMain reads one line main sent: a JSON object of exactly its
// type's fields, of this Version, of a type main sends.
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
	if string(v) != strconv.Itoa(Version) {
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
		if f == "attempt" || f == "id" {
			n := &msg.Attempt
			if f == "id" {
				n = &msg.ID
			}
			if string(raw) == "null" || json.Unmarshal(raw, n) != nil || *n == 0 || *n > maxWhole {
				return Message{}, refuse("fields")
			}
			continue
		}
		if f == "epoch" || f == "pick" {
			n := &msg.Epoch
			if f == "pick" {
				n = &msg.Pick
			}
			// null is no number: JSON leaves a number it decodes as it was.
			if string(raw) == "null" || json.Unmarshal(raw, n) != nil || *n > maxWhole {
				return Message{}, refuse("fields")
			}
			continue
		}
		var s string
		if json.Unmarshal(raw, &s) != nil || s == "" || f == "path" && !absolute(s) {
			return Message{}, refuse("fields")
		}
		switch f {
		case "home":
			msg.Home = s
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
		"resolver": m.Resolver, "road": m.Road}
	o := map[string]any{"version": Version, "type": m.Type}
	for _, f := range want.required {
		if f == "attempt" || f == "id" {
			n := m.Attempt
			if f == "id" {
				n = m.ID
			}
			if n == 0 {
				return nil, fmt.Errorf("%s needs %s", m.Type, f)
			}
			o[f] = n
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
// later line is dropped and gone is called, once: what made the writer
// ends, as the app it talks to has.
type Writer struct {
	w    io.Writer
	gone func()

	mu     sync.Mutex
	queue  [][]byte
	failed bool
	wake   chan struct{}
}

// NewWriter writes to w, main's end of the private pipe, calling gone (nil
// calls nothing) at the first write that fails. A write to a pipe main
// closed is an error then, not the end of this process: SIGPIPE is
// ignored, so a lock goes on to end its sessions at the CYFR when main
// has gone.
func NewWriter(w io.Writer, gone func()) *Writer {
	signal.Ignore(syscall.SIGPIPE)
	wr := &Writer{w: w, gone: gone, wake: make(chan struct{}, 1)}
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
				if w.failed = err != nil; w.failed && w.gone != nil {
					w.gone()
				}
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
